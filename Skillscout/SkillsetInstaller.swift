import CryptoKit
import Foundation

struct SkillsetIssue: Identifiable {
  enum Reason {
    case missingSource
    case chooseSource
    case differentContent(URL)
    case builtIn
    case destination(URL)
    /// The skill has versions and nothing says which one this agent gets.
    case chooseVersions
    /// Applying would make `tool` see the versions in `folders`.
    case versionConflict(tool: Tool, folders: [URL])
    /// `tool` already sees the versions in `folders`. Only changing those copies fixes it.
    case existingVersions(tool: Tool, folders: [URL])
  }
  let skillID: Skill.ID
  let reason: Reason
  let message: String
  /// A skill can have several issues for one agent, such as a kept copy and the versions it already sees.
  var id: String { skillID + "\n" + message }
}

struct SkillsetPlan {
  var additions: [Skill] = []
  var removals: [SkillsetEntry] = []
  var kept = 0
  /// Members this agent is set to go without.
  var skipped: [Skill.ID] = []
  var issues: [String] = []
  var issueDetails: [SkillsetIssue] = []

  mutating func addIssue(_ id: Skill.ID, reason: SkillsetIssue.Reason, message: String) {
    issues.append(message)
    issueDetails.append(SkillsetIssue(skillID: id, reason: reason, message: message))
  }
}

extension SkillInstaller {
  private static func entryPath(_ url: URL) -> String {
    url.deletingLastPathComponent().resolvingSymlinksInPath().path + "/" + url.lastPathComponent
  }

  /// The copy `tool` gets. A skill with versions follows `SkillVersions.resolve`, and gets nil when nothing decides
  /// this agent's version, so the plan asks instead of picking one. Otherwise it's the saved choice, else the only
  /// candidate.
  static func skillsetSource(_ skill: Skill, for tool: Tool?, preferences: SourcePreferences = SourcePreferences()) -> SkillCopy? {
    let versions = SkillVersions.versions(of: skill)
    // A saved choice whose copy moved or went away no longer applies.
    let saved = [tool.flatMap { preferences.byTool[skill.id]?[$0] }, preferences.defaults[skill.id]].compactMap { $0 }
    if versions.count > 1, let tool {
      guard let index = SkillVersions.resolve(SkillVersions.savedChoice(for: skill, preferences: preferences))[tool]?.version else { return nil }
      return versions[index].first { saved.contains($0.resolved.path) } ?? versions[index][0]
    }
    if let chosen = saved.lazy.compactMap({ path in installableSources(for: skill).first { $0.resolved.path == path } }).first { return chosen }
    return versions.count > 1 ? nil : defaultSource(for: skill)
  }

  /// Plans for every tool in `tools`, checked together so no agent ends up reading two versions of a skill,
  /// including agents outside this change that read the same folders.
  static func skillsetPlans(tools: [Tool], assignments: [SkillsetAssignment], entries: [SkillsetEntry], skills: [Skill],
                            preferences: SourcePreferences = SourcePreferences()) -> [Tool: SkillsetPlan] {
    var plans = Dictionary(uniqueKeysWithValues: tools.map { tool in
      (tool, skillsetPlan(tool: tool, assignments: assignments, entries: entries, skills: skills, preferences: preferences))
    })
    let removing = Set(plans.values.flatMap(\.removals).map { SkillVersions.key(URL(fileURLWithPath: $0.path)) })
    let involved = Set(tools.flatMap { tool in assignments.filter { $0.tool == tool }.flatMap(\.members) })
    for skill in skills where involved.contains(skill.id) {
      let additions = tools.compactMap { tool -> (Tool, PlannedCopy)? in
        guard plans[tool]?.additions.contains(where: { $0.id == skill.id }) == true,
              let source = skillsetSource(skill, for: tool, preferences: preferences) else { return nil }
        return (tool, PlannedCopy(skillID: skill.id, folder: tool.skillsFolder.appending(path: slug(skill.name)), contentHash: source.contentHash))
      }
      let fresh = SkillVersions.newConflicts(skills: [skill], adding: additions.map(\.1), removing: removing)
      // Dropping every planned copy the agent reads leaves it with what it reads today, so one pass is enough.
      for conflict in fresh {
        for (tool, planned) in additions where planned.readBy.contains(conflict.tool) {
          guard plans[tool]?.additions.contains(where: { $0.id == skill.id }) == true else { continue }
          plans[tool]?.additions.removeAll { $0.id == skill.id }
          plans[tool]?.addIssue(skill.id, reason: .versionConflict(tool: conflict.tool, folders: conflict.folders),
            message: SkillVersions.message(conflict, adding: additions.map(\.1)))
        }
      }
      let existing = SkillVersions.conflicts(skills: [skill], adding: [], removing: [])
      for conflict in existing where !fresh.contains(where: { $0.tool == conflict.tool }) {
        for tool in tools where assignments.contains(where: { $0.tool == tool && $0.members.contains(skill.id) }) {
          plans[tool]?.addIssue(skill.id, reason: .existingVersions(tool: conflict.tool, folders: conflict.folders),
            message: SkillVersions.message(conflict))
        }
      }
    }
    return plans
  }

  /// One tool's plan on its own. Apply and preview go through `skillsetPlans`, which adds the version check.
  private static func skillsetPlan(tool: Tool, assignments: [SkillsetAssignment], entries: [SkillsetEntry], skills: [Skill],
                                   preferences: SourcePreferences) -> SkillsetPlan {
    var desired = assignments.filter { $0.tool == tool }.reduce(into: Set<Skill.ID>()) { $0.formUnion($1.members) }
    var plan = SkillsetPlan()
    plan.skipped = desired.filter { preferences.skipped[$0]?.contains(tool) == true }.sorted()
    desired.subtract(plan.skipped)
    plan.removals = entries.filter { $0.tool == tool && !desired.contains($0.skillID) }
    for id in desired.sorted() {
      guard let skill = skills.first(where: { $0.id == id }) else {
        plan.addIssue(id, reason: .missingSource, message: "\(id): source is missing. Restore it or remove it from the skillset.")
        continue
      }
      let source = skillsetSource(skill, for: tool, preferences: preferences)
      let versioned = SkillVersions.versions(of: skill).count > 1
      if source == nil && !versioned && installableSources(for: skill).count > 1 {
        plan.addIssue(id, reason: .chooseSource, message: "\(id): choose a source before applying.")
        continue
      }
      let providers = skill.copies.filter { $0.root.readBy.contains(tool) }
      // A link owned by another tool can disappear when that tool is unassigned.
      // Only a direct owned entry or an independent installation satisfies this assignment.
      let provider = providers.first { copy in
        !entries.contains { entry in
          entry.tool != tool && (entryPath(URL(fileURLWithPath: entry.path)) == entryPath(copy.folder)
            || (entry.linkDestination == nil && copy.resolved.path == URL(fileURLWithPath: entry.path).resolvingSymlinksInPath().path))
        }
      }
      if let provider {
        if let source, provider.contentHash != source.contentHash {
          plan.addIssue(id, reason: .differentContent(provider.folder), message: "\(id): \(tool.name) already has different content. Its existing installation will be kept.")
        } else {
          plan.kept += 1
        }
      } else if source == nil && versioned {
        plan.addIssue(id, reason: .chooseVersions,
          message: "\(id): has \(SkillVersions.versions(of: skill).count) versions. Choose which one \(tool.name) gets before applying.")
      } else if source == nil {
        plan.addIssue(id, reason: .builtIn, message: "\(id): built into another tool and cannot be installed here.")
      } else {
        let name = slug(skill.name)
        let destination = tool.skillsFolder.appending(path: name)
        if name.isEmpty || (try? FileManager.default.attributesOfItem(atPath: destination.path)) != nil {
          plan.addIssue(id, reason: .destination(destination), message: "\(id): the destination already exists or its name is invalid. Nothing will be overwritten.")
        } else {
          plan.additions.append(skill)
        }
      }
    }
    return plan
  }

  static func addForSkillset(_ skill: Skill, to tool: Tool, preferences: SourcePreferences = SourcePreferences()) throws -> SkillsetEntry {
    guard let source = skillsetSource(skill, for: tool, preferences: preferences) else {
      if installableSources(for: skill).isEmpty { throw Failure.builtIn(skill.name) }
      throw InstallFailure.sourceChoiceRequired(skill.name)
    }
    let name = slug(skill.name)
    guard !name.isEmpty else { throw InstallFailure.invalidSkill }
    let fm = FileManager.default
    let folder = tool.skillsFolder.appending(path: name)
    guard (try? fm.attributesOfItem(atPath: folder.path)) == nil else { throw Failure.alreadyExists(folder) }
    try fm.createDirectory(at: tool.skillsFolder, withIntermediateDirectories: true)
    if source.root.kind == .plugin {
      try fm.copyItem(at: source.resolved, to: folder)
      return SkillsetEntry(skillID: skill.id, tool: tool, path: folder.path, linkDestination: nil,
        fingerprint: try skillsetFingerprint(folder))
    }
    try fm.createSymbolicLink(at: folder, withDestinationURL: source.resolved)
    return SkillsetEntry(skillID: skill.id, tool: tool, path: folder.path,
      linkDestination: try fm.destinationOfSymbolicLink(atPath: folder.path), fingerprint: nil)
  }

  /// Returns a note if the entry was preserved, and exact Trash paths for removed test artifacts.
  static func removeSkillsetEntry(_ entry: SkillsetEntry, entries: [SkillsetEntry], skills: [Skill]) throws -> (note: String?, trashed: [URL]) {
    let fm = FileManager.default
    let folder = URL(fileURLWithPath: entry.path)
    // Persisted receipts must never authorize operations outside this tool's skill folder.
    guard folder.deletingLastPathComponent().resolvingSymlinksInPath().path == entry.tool.skillsFolder.resolvingSymlinksInPath().path else {
      throw Failure.managed(folder)
    }
    guard (try? fm.attributesOfItem(atPath: folder.path)) != nil else { return (nil, []) }
    guard skillsetEntryIsUnchanged(entry) else { return ("Kept \(entry.skillID): its installation was changed outside Quartermaster.", []) }
    let referenced = skills.flatMap(\.copies).contains { copy in
      guard copy.isSymlink,
            !entries.contains(where: { entryPath(URL(fileURLWithPath: $0.path)) == entryPath(copy.folder) }),
            let destination = try? fm.destinationOfSymbolicLink(atPath: copy.folder.path) else { return false }
      let target = URL(fileURLWithPath: destination, relativeTo: copy.folder.deletingLastPathComponent()).standardizedFileURL
      return entryPath(target) == entryPath(folder)
        || (entry.linkDestination == nil && copy.resolved.path == folder.resolvingSymlinksInPath().path)
    }
    if referenced { return ("Kept \(entry.skillID): another installation links to this copy.", []) }
    var result: NSURL?
    try fm.trashItem(at: folder, resultingItemURL: &result)
    return (nil, result.map { [$0 as URL] } ?? [])
  }

  /// An existing receipt still matches an installation in its tool's skills folder.
  static func skillsetEntryIsUnchanged(_ entry: SkillsetEntry) -> Bool {
    let fm = FileManager.default
    let folder = URL(fileURLWithPath: entry.path)
    guard folder.deletingLastPathComponent().resolvingSymlinksInPath().path == entry.tool.skillsFolder.resolvingSymlinksInPath().path,
          (try? fm.attributesOfItem(atPath: folder.path)) != nil else { return false }
    if let destination = entry.linkDestination {
      return (try? fm.destinationOfSymbolicLink(atPath: folder.path)) == destination
    } else {
      let isLink = (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
      return !isLink && entry.fingerprint != nil && (try? skillsetFingerprint(folder)) == entry.fingerprint
    }
  }

  /// Include supporting files so editing a copied plugin's script also protects it from removal.
  static func skillsetFingerprint(_ folder: URL) throws -> String {
    let fm = FileManager.default
    var enumerationError: Error?
    guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      errorHandler: { _, error in enumerationError = error; return false }) else { throw CocoaError(.fileReadUnknown) }
    let urls = enumerator.allObjects.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
    if let enumerationError { throw enumerationError }
    var hash = SHA256()
    for url in urls {
      let relative = String(url.path.dropFirst(folder.path.count))
      hash.update(data: Data(relative.utf8))
      hash.update(data: Data([0]))
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true {
        hash.update(data: Data((try fm.destinationOfSymbolicLink(atPath: url.path)).utf8))
      } else if values.isRegularFile == true {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty { hash.update(data: chunk) }
      }
      hash.update(data: Data([0]))
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
