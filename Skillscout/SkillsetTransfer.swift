import Foundation

/// The result of bringing one tool's skillset entries in line with its assignments.
struct SkillsetReconcileResult {
  var issues: [String] = []
  var notes: [String] = []
  var trashed: [URL] = []
  /// True when a receipt couldn't be saved, so the run stopped before changing more.
  var stopped = false
}

extension SkillInstaller {
  /// Saves receipts after each change, rolling back a newly added entry if its receipt cannot be saved.
  static func reconcileSkillsets(tool: Tool, assignments: [SkillsetAssignment], entries: inout [SkillsetEntry],
                                 skills: [Skill], preferences: SourcePreferences,
                                 persist: ([SkillsetEntry]) -> Bool) -> SkillsetReconcileResult {
    let plan = skillsetPlans(tools: [tool], assignments: assignments, entries: entries, skills: skills, preferences: preferences)[tool] ?? SkillsetPlan()
    var result = SkillsetReconcileResult(issues: plan.issues)
    for skill in plan.additions {
      do {
        let previousEntries = entries
        let entry = try addForSkillset(skill, to: tool, preferences: preferences)
        // Replace an old receipt if an externally removed entry was recreated.
        entries.removeAll { $0.path == entry.path }
        entries.append(entry)
        guard persist(entries) else {
          result.issues.append("Stopped: ownership could not be saved.")
          result.stopped = true
          do {
            let rollback = try removeSkillsetEntry(entry, entries: entries, skills: skills)
            result.trashed += rollback.trashed
            if let note = rollback.note {
              result.issues.append("\(note) Ownership for \(entry.path) remains unsaved; retry after saving is available.")
            } else {
              entries = previousEntries
              // The callback also updates the caller's in-memory receipts, even when saving fails.
              _ = persist(entries)
            }
          } catch {
            result.issues.append("Couldn't roll back \(entry.path): \(error.localizedDescription) Its ownership remains unsaved; retry after saving is available.")
          }
          return result
        }
      } catch {
        result.issues.append("\(skill.name): \(error.localizedDescription)")
      }
    }
    for entry in plan.removals {
      do {
        let removal = try removeSkillsetEntry(entry, entries: entries, skills: skills)
        result.trashed += removal.trashed
        if let note = removal.note { result.notes.append(note) }
        entries.removeAll { $0 == entry }
        guard persist(entries) else {
          result.issues.append("Stopped: ownership could not be saved.")
          result.stopped = true
          return result
        }
      } catch {
        result.issues.append("\(entry.skillID): \(error.localizedDescription)")
      }
    }
    return result
  }
}

/// The skillset part of the app's `state.json`, for the command line tool. Saving rewrites only these keys
/// and keeps everything else in the file as it was.
struct SkillsetState {
  var skillsets: [Skillset] = []
  var assignments: [SkillsetAssignment] = []
  var entries: [SkillsetEntry] = []
  var issues: [String: [String]] = [:]
  var sourcePreferences = SourcePreferences()

  private struct Stored: Codable {
    var skillsets: [Skillset]?
    var skillsetAssignments: [SkillsetAssignment]?
    var skillsetEntries: [SkillsetEntry]?
    var skillsetIssues: [String: [String]]?
    var preferredSources: [Skill.ID: String]?
    var agentSources: [Skill.ID: [Tool: String]]?
    var skippedAgents: [Skill.ID: Set<Tool>]?
    var projectSources: [String: [Skill.ID: String]]?
  }

  static func load(from file: URL = Paths.stateFile) throws -> SkillsetState {
    guard FileManager.default.fileExists(atPath: file.path) else { return SkillsetState() }
    let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file))
    return SkillsetState(skillsets: stored.skillsets ?? [], assignments: stored.skillsetAssignments ?? [],
      entries: stored.skillsetEntries ?? [], issues: stored.skillsetIssues ?? [:],
      sourcePreferences: SourcePreferences(defaults: stored.preferredSources ?? [:], byTool: stored.agentSources ?? [:],
        skipped: stored.skippedAgents ?? [:], byProject: stored.projectSources ?? [:]))
  }

  func save(to file: URL = Paths.stateFile) throws {
    var object: [String: Any] = [:]
    if FileManager.default.fileExists(atPath: file.path) {
      guard let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
        throw CocoaError(.fileReadCorruptFile)
      }
      object = existing
    }
    let stored = Stored(skillsets: skillsets, skillsetAssignments: assignments, skillsetEntries: entries,
      skillsetIssues: issues, preferredSources: sourcePreferences.defaults, agentSources: sourcePreferences.byTool,
      skippedAgents: sourcePreferences.skipped, projectSources: sourcePreferences.byProject)
    guard let updates = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any] else {
      throw CocoaError(.coderInvalidValue)
    }
    object.merge(updates) { _, new in new }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
  }
}

/// A skillset saved to share or move to another Mac: its name, its skills, and where each Library skill came from.
struct SkillsetFile: Codable, Equatable {
  /// The version an agent uses, found again by its content, since versions can come from different repositories.
  struct AgentVersion: Codable, Hashable {
    /// The repository URL, as in `Member.source`; nil when the copy is in no repository.
    var source: String?
    /// The folder of the copy relative to that repository.
    var path: String?
    /// `SkillCopy.contentHash` of the chosen version.
    var contentHash: String
  }

  struct Member: Codable, Equatable {
    let name: String
    /// The Git repository a Library skill was added from, without credentials. Nil for personal skills and
    /// local folders, whose paths mean nothing on another Mac.
    let source: String?
    let ref: RepositoryRef?
    let commit: String?
    /// Tool argument string to the version that agent uses, for a skill with versions.
    var agents: [String: AgentVersion]?
    /// Tool argument strings of the agents that go without the skill.
    var skippedAgents: [String]?

    init(name: String, source: String?, ref: RepositoryRef? = nil, commit: String? = nil,
         agents: [String: AgentVersion]? = nil, skippedAgents: [String]? = nil) {
      self.name = name
      self.source = source
      self.ref = ref
      self.commit = commit
      self.agents = agents
      self.skippedAgents = skippedAgents
    }
  }

  /// Where a copy lives in a Library repository: the repository's address, nil for a local folder, and the copy's
  /// folder relative to it.
  typealias Location = (source: String?, path: String)

  var format = "skillscout-skillset"
  var version = 1
  let name: String
  let skills: [Member]

  init(name: String, skills: [Member]) {
    self.name = name
    self.skills = skills
  }

  /// The file for a skillset, and every per-agent version choice it couldn't write, for the user to read.
  static func export(_ skillset: Skillset, skills: [Skill], preferences: SourcePreferences,
                     locate: (SkillCopy) -> Location? = SkillsetFile.libraryLocation(of:)) -> (file: SkillsetFile, unwritten: [String]) {
    var unwritten: [String] = []
    let members = skillset.skills.sorted().map { id in
      let skill = skills.first { $0.id == id }
      let copy = skill.flatMap { SkillInstaller.skillsetSource($0, for: nil, preferences: preferences) ?? $0.copies.first(where: SkillInstaller.isFromLibrary) }
      var member: Member
      if let copy, SkillInstaller.isFromLibrary(copy), let repo = SkillInstaller.libraryRepo(of: copy),
         let source = try? SkillInstaller.repoSource(name: repo), !source.hasPrefix("/") {
        let snapshot = try? RepositoryLibrary.snapshot(in: SkillInstaller.managedRepoFolder(repo))
        member = Member(name: id, source: SkillInstaller.redactedSource(source), ref: snapshot?.ref, commit: snapshot?.commit)
      } else {
        member = Member(name: id, source: nil)
      }
      guard let skill, SkillVersions.versions(of: skill).count > 1 else { return member }
      var agents: [String: AgentVersion] = [:]
      for (tool, path) in (preferences.byTool[id] ?? [:]).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
        let chosen = SkillInstaller.installableSources(for: skill).first { $0.resolved.path == path }
        guard let chosen else {
          unwritten.append("\(id) for \(tool.name): its chosen version is no longer installed, so the file doesn't record it.")
          continue
        }
        let version = SkillVersions.versions(of: skill).first { $0[0].contentHash == chosen.contentHash } ?? [chosen]
        guard let location = ([chosen] + version).lazy.compactMap(locate).first else {
          unwritten.append("\(id) for \(tool.name): its version is in no Library repository (\(Paths.abbreviate(chosen.resolved))), so the file doesn't record it.")
          continue
        }
        agents[tool.rawValue] = AgentVersion(source: location.source, path: location.path, contentHash: chosen.contentHash)
      }
      let skipped = Tool.allCases.filter { preferences.skipped[id]?.contains($0) == true }.map(\.rawValue)
      member.agents = agents.isEmpty ? nil : agents
      member.skippedAgents = skipped.isEmpty ? nil : skipped
      return member
    }
    return (SkillsetFile(name: skillset.name, skills: members), unwritten)
  }

  static func libraryLocation(of copy: SkillCopy) -> Location? {
    guard let repo = SkillInstaller.libraryRepo(of: copy) else { return nil }
    let base = SkillInstaller.managedRepoFolder(repo).resolvingSymlinksInPath().standardizedFileURL.pathComponents
    let parts = copy.resolved.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    guard parts.starts(with: base) else { return nil }
    let source = (try? SkillInstaller.repoSource(name: repo)).flatMap { $0.hasPrefix("/") ? nil : SkillInstaller.redactedSource($0) }
    return (source, parts.dropFirst(base.count).joined(separator: "/"))
  }

  /// Sets each member's per-agent versions from the local copy with the same content, preferring the one at the same
  /// repository and path. Returns the choices it couldn't apply; nothing is guessed.
  func applyVersionChoices(to preferences: inout SourcePreferences, skills: [Skill],
                           locate: (SkillCopy) -> Location? = SkillsetFile.libraryLocation(of:)) -> [String] {
    var unmatched: [String] = []
    for member in self.skills where member.agents != nil || member.skippedAgents != nil {
      guard let skill = skills.first(where: { $0.id == member.name }) else {
        unmatched.append("\(member.name): not on this Mac, so its agent versions weren't applied.")
        continue
      }
      let sources = SkillInstaller.installableSources(for: skill)
      for (argument, version) in (member.agents ?? [:]).sorted(by: { $0.key < $1.key }) {
        guard let tool = Tool(argument: argument) else {
          unmatched.append("\(member.name): unknown agent \(argument), so its version wasn't applied.")
          continue
        }
        let candidates = sources.filter { $0.contentHash == version.contentHash }
        let sameRepository: (SkillCopy) -> Bool = { copy in
          guard let location = locate(copy) else { return version.source == nil && version.path == nil }
          return Self.sameRepository(location.source, version.source) && location.path == version.path
        }
        guard let copy = candidates.first(where: sameRepository) ?? candidates.first else {
          unmatched.append("\(member.name) for \(tool.name): no copy on this Mac has the chosen version, so it wasn't applied.")
          continue
        }
        preferences.byTool[skill.id, default: [:]][tool] = copy.resolved.path
        preferences.skipped[skill.id]?.remove(tool)
      }
      for argument in member.skippedAgents ?? [] {
        guard let tool = Tool(argument: argument) else {
          unmatched.append("\(member.name): unknown agent \(argument), so its skip wasn't applied.")
          continue
        }
        preferences.skipped[skill.id, default: []].insert(tool)
        preferences.byTool[skill.id]?[tool] = nil
      }
      if preferences.byTool[skill.id]?.isEmpty == true { preferences.byTool[skill.id] = nil }
      if preferences.skipped[skill.id]?.isEmpty == true { preferences.skipped[skill.id] = nil }
    }
    return unmatched
  }

  private static func sameRepository(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return a == b }
    guard let first = try? RepositorySource(address: a), let second = try? RepositorySource(address: b) else { return a == b }
    return RepositoryID(source: first) == RepositoryID(source: second)
  }

  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  enum ReadFailure: LocalizedError {
    case notASkillset, newerVersion(Int), emptyName

    var errorDescription: String? {
      switch self {
      case .notASkillset: "This file isn't a Quartermaster skillset."
      case .newerVersion(let version): "This skillset was saved by a newer Quartermaster (format \(version)). Update Quartermaster to import it."
      case .emptyName: "This skillset has no name."
      }
    }
  }

  static func decode(_ data: Data) throws -> SkillsetFile {
    guard let file = try? JSONDecoder().decode(SkillsetFile.self, from: data), file.format == "skillscout-skillset" else {
      throw ReadFailure.notASkillset
    }
    guard file.version <= 1 else { throw ReadFailure.newerVersion(file.version) }
    guard !file.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ReadFailure.emptyName }
    return file
  }

  /// A skillset name not used yet: the file's name, or the name with a number after it.
  static func availableName(_ name: String, among skillsets: [Skillset]) -> String {
    let taken = Set(skillsets.map { $0.name.lowercased() })
    guard taken.contains(name.lowercased()) else { return name }
    var number = 2
    while taken.contains("\(name) \(number)".lowercased()) { number += 1 }
    return "\(name) \(number)"
  }

  func versionDifferences(among skills: [Skill], preferences: SourcePreferences = SourcePreferences()) -> [String] {
    self.skills.compactMap { member in
      guard let expected = member.commit, let address = member.source,
            let source = try? RepositorySource(address: address),
            let skill = skills.first(where: { $0.id == member.name }) else { return nil }
      let copy = SkillInstaller.skillsetSource(skill, for: nil, preferences: preferences)
        ?? skill.copies.first(where: SkillInstaller.isFromLibrary)
      guard let copy, let repo = SkillInstaller.libraryRepo(of: copy),
            let snapshot = try? RepositoryLibrary.snapshot(in: SkillInstaller.managedRepoFolder(repo)),
            RepositoryID(source: snapshot.source) == RepositoryID(source: source), snapshot.commit != expected else { return nil }
      return "\(member.name): this skillset requests \(expected.prefix(12)); the Library has \((snapshot.commit ?? "unknown").prefix(12)). The Library version was kept."
    }
  }

  /// Members missing on this Mac, with the source to add for each one when the file has it.
  func missing(among skills: [Skill]) -> [Member] {
    let present = Set(skills.map(\.id))
    return self.skills.filter { !present.contains($0.name) }
  }
}
