import Foundation

struct RepositoryUpdateImpact: Sendable {
  struct Installation: Identifiable, Sendable {
    let skillID: Skill.ID
    let path: String
    let tools: [Tool]
    let willChange: Bool?

    var id: String { path }
  }

  enum ProjectCopyState: String, Sendable {
    case separateReview = "Review separately"
    case unchanged = "Already matches"
    case updateAvailable = "Separate update available"
    case modified = "Local edits preserved"
    case unavailable = "Copy unavailable"
    case sourceRemoved = "Source removed; copy preserved"
  }

  struct ProjectCopy: Identifiable, Sendable {
    let projectName: String
    let projectPath: String
    let skillID: Skill.ID
    let path: String
    let tools: [Tool]
    let state: ProjectCopyState

    var id: String { path }
  }

  let linked: [Installation]
  let otherCopies: [Installation]
  let projects: [ProjectCopy]
  let skillsetNames: [String]

  static func inspect(repository: URL, changedPaths: Set<String>? = nil, result: URL? = nil,
                      skills: [Skill], skillsets: [Skillset], projectState: ProjectState) -> Self {
    let root = repository.standardizedFileURL.resolvingSymlinksInPath()
    func relative(_ url: URL) -> String? {
      let path = url.standardizedFileURL.resolvingSymlinksInPath().path
      if path == root.path { return "" }
      guard path.hasPrefix(root.path + "/") else { return nil }
      return String(path.dropFirst(root.path.count + 1))
    }
    func supplyingFolder(_ copy: SkillCopy) -> String? {
      relative(copy.resolved) ?? relative(copy.folder.appending(path: "SKILL.md").resolvingSymlinksInPath().deletingLastPathComponent())
    }
    func changed(_ folder: String) -> Bool? {
      changedPaths.map { paths in
        folder.isEmpty ? !paths.isEmpty : paths.contains { $0.hasPrefix(folder + "/") }
      }
    }
    let relatedSkills = skills.filter { skill in skill.copies.contains { supplyingFolder($0) != nil } }
    let relatedIDs = Set(relatedSkills.map(\.id))
    var linked: [String: Installation] = [:]
    var other: [String: Installation] = [:]
    for skill in relatedSkills {
      for copy in skill.copies where !copy.root.readBy.isEmpty {
        let tools = Tool.allCases.filter(copy.root.readBy.contains)
        let path = copy.folder.standardizedFileURL.path
        if let folder = supplyingFolder(copy) {
          linked[path] = Installation(skillID: skill.id, path: path, tools: tools, willChange: changed(folder))
        } else {
          other[path] = Installation(skillID: skill.id, path: path, tools: tools, willChange: false)
        }
      }
    }
    let registered = Dictionary(uniqueKeysWithValues: projectState.projects.map { ($0.id, $0) })
    let projects = projectState.entries.compactMap { entry -> ProjectCopy? in
      guard let folder = relative(URL(fileURLWithPath: entry.sourcePath)) else { return nil }
      let project = registered[entry.projectID]
      let destination = URL(fileURLWithPath: entry.path)
      let state: ProjectCopyState
      if !FileManager.default.fileExists(atPath: destination.path) {
        state = .unavailable
      } else if !SkillInstaller.projectEntryUnchanged(entry) {
        state = .modified
      } else if let result {
        let source = folder.isEmpty ? result : result.appending(path: folder)
        if !FileManager.default.fileExists(atPath: source.appending(path: "SKILL.md").path) {
          state = .sourceRemoved
        } else if let fingerprint = try? SkillInstaller.projectFingerprint(source, requirePortableLinks: true) {
          state = fingerprint == entry.installedFingerprint ? .unchanged : .updateAvailable
        } else {
          state = .separateReview
        }
      } else {
        state = .separateReview
      }
      return ProjectCopy(projectName: project?.name ?? "Unregistered project", projectPath: project?.path ?? entry.path,
        skillID: entry.skillID, path: entry.path, tools: Tool.allCases.filter(entry.target.readBy.contains), state: state)
    }.sorted { ($0.projectPath, $0.skillID, $0.path) < ($1.projectPath, $1.skillID, $1.path) }
    return Self(linked: linked.values.sorted { $0.path < $1.path },
      otherCopies: other.values.sorted { $0.path < $1.path }, projects: projects,
      skillsetNames: skillsets.filter { !$0.skills.isDisjoint(with: relatedIDs) }.map(\.name).sorted())
  }
}
