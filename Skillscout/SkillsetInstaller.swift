import CryptoKit
import Foundation

struct SkillsetPlan {
  var additions: [Skill] = []
  var removals: [SkillsetEntry] = []
  var kept = 0
  var issues: [String] = []
}

extension SkillInstaller {
  private static func entryPath(_ url: URL) -> String {
    url.deletingLastPathComponent().resolvingSymlinksInPath().path + "/" + url.lastPathComponent
  }

  static func skillsetSource(_ skill: Skill, preferredSources: [Skill.ID: String] = [:]) -> SkillCopy? {
    let sources = installableSources(for: skill)
    if let path = preferredSources[skill.id] {
      return sources.first { $0.resolved.path == path }
    }
    return defaultSource(for: skill)
  }

  static func skillsetPlan(tool: Tool, assignments: [SkillsetAssignment], entries: [SkillsetEntry], skills: [Skill], preferredSources: [Skill.ID: String] = [:]) -> SkillsetPlan {
    let desired = assignments.filter { $0.tool == tool }.reduce(into: Set<Skill.ID>()) { $0.formUnion($1.members) }
    var plan = SkillsetPlan()
    plan.removals = entries.filter { $0.tool == tool && !desired.contains($0.skillID) }
    for id in desired.sorted() {
      guard let skill = skills.first(where: { $0.id == id }) else {
        plan.issues.append("\(id): source is missing. Restore it or remove it from the skillset.")
        continue
      }
      let source = skillsetSource(skill, preferredSources: preferredSources)
      if source == nil && installableSources(for: skill).count > 1 {
        plan.issues.append("\(id): choose a source in the skillset editor before applying.")
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
          plan.issues.append("\(id): \(tool.name) already has different content. Its existing installation will be kept.")
        } else {
          plan.kept += 1
        }
      } else if source == nil {
        plan.issues.append("\(id): built into another tool and cannot be installed here.")
      } else {
        let name = slug(skill.name)
        let destination = tool.skillsFolder.appending(path: name)
        if name.isEmpty || (try? FileManager.default.attributesOfItem(atPath: destination.path)) != nil {
          plan.issues.append("\(id): the destination already exists or its name is invalid. Nothing will be overwritten.")
        } else {
          plan.additions.append(skill)
        }
      }
    }
    return plan
  }

  static func addForSkillset(_ skill: Skill, to tool: Tool, preferredSources: [Skill.ID: String] = [:]) throws -> SkillsetEntry {
    guard let source = skillsetSource(skill, preferredSources: preferredSources) else {
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
    let unchanged: Bool
    if let destination = entry.linkDestination {
      unchanged = (try? fm.destinationOfSymbolicLink(atPath: folder.path)) == destination
    } else {
      let isLink = (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
      unchanged = !isLink && entry.fingerprint != nil && (try? skillsetFingerprint(folder)) == entry.fingerprint
    }
    guard unchanged else { return ("Kept \(entry.skillID): its installation was changed outside Skillscout.", []) }
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
