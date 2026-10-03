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
  /// Adds and removes a tool's skillset entries to match the assignments, saving the receipts after every change
  /// with `persist`, so a failure never leaves an entry Skillscout doesn't know it owns.
  static func reconcileSkillsets(tool: Tool, assignments: [SkillsetAssignment], entries: inout [SkillsetEntry],
                                 skills: [Skill], preferredSources: [Skill.ID: String],
                                 persist: ([SkillsetEntry]) -> Bool) -> SkillsetReconcileResult {
    let plan = skillsetPlan(tool: tool, assignments: assignments, entries: entries, skills: skills, preferredSources: preferredSources)
    var result = SkillsetReconcileResult(issues: plan.issues)
    for skill in plan.additions {
      do {
        let entry = try addForSkillset(skill, to: tool, preferredSources: preferredSources)
        // Replace an old receipt if an externally removed entry was recreated.
        entries.removeAll { $0.path == entry.path }
        entries.append(entry)
        guard persist(entries) else {
          result.issues.append("Stopped: ownership could not be saved.")
          result.stopped = true
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
  var preferredSources: [Skill.ID: String] = [:]

  private struct Stored: Codable {
    var skillsets: [Skillset]?
    var skillsetAssignments: [SkillsetAssignment]?
    var skillsetEntries: [SkillsetEntry]?
    var skillsetIssues: [String: [String]]?
    var preferredSources: [Skill.ID: String]?
  }

  static func load(from file: URL = Paths.stateFile) throws -> SkillsetState {
    guard FileManager.default.fileExists(atPath: file.path) else { return SkillsetState() }
    let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file))
    return SkillsetState(skillsets: stored.skillsets ?? [], assignments: stored.skillsetAssignments ?? [],
      entries: stored.skillsetEntries ?? [], issues: stored.skillsetIssues ?? [:],
      preferredSources: stored.preferredSources ?? [:])
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
      skillsetIssues: issues, preferredSources: preferredSources)
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
  struct Member: Codable, Equatable {
    let name: String
    /// The Git repository a Library skill was added from, without credentials. Nil for personal skills and
    /// local folders, whose paths mean nothing on another Mac.
    let source: String?
  }

  var format = "skillscout-skillset"
  var version = 1
  let name: String
  let skills: [Member]

  init(name: String, skills: [Member]) {
    self.name = name
    self.skills = skills
  }

  init(_ skillset: Skillset, skills: [Skill], preferredSources: [Skill.ID: String]) {
    name = skillset.name
    self.skills = skillset.skills.sorted().map { id in
      let source = skills.first { $0.id == id }
        .flatMap { SkillInstaller.skillsetSource($0, preferredSources: preferredSources) ?? $0.copies.first(where: SkillInstaller.isFromLibrary) }
        .flatMap { copy -> String? in
          guard SkillInstaller.isFromLibrary(copy), let repo = SkillInstaller.libraryRepo(of: copy) else { return nil }
          guard let source = try? SkillInstaller.repoSource(name: repo), !source.hasPrefix("/") else { return nil }
          return SkillInstaller.redactedSource(source)
        }
      return Member(name: id, source: source)
    }
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
      case .notASkillset: "This file isn't a Skillscout skillset."
      case .newerVersion(let version): "This skillset was saved by a newer Skillscout (format \(version)). Update Skillscout Mod to import it."
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

  /// Members missing on this Mac, with the source to add for each one when the file has it.
  func missing(among skills: [Skill]) -> [Member] {
    let present = Set(skills.map(\.id))
    return self.skills.filter { !present.contains($0.name) }
  }
}
