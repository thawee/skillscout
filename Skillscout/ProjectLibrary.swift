import Foundation

struct ProjectDirectoryIdentity: Codable, Hashable, Sendable {
  let device: UInt64
  let inode: UInt64

  static func read(at url: URL) throws -> Self {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory,
          let device = attributes[.systemNumber] as? NSNumber,
          let inode = attributes[.systemFileNumber] as? NSNumber else {
      throw ProjectLibrary.Failure.notDirectory(url.path)
    }
    return Self(device: device.uint64Value, inode: inode.uint64Value)
  }
}

struct RegisteredProject: Identifiable, Codable, Hashable, Sendable {
  var id = UUID()
  let path: String
  let directoryIdentity: ProjectDirectoryIdentity

  var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
  var name: String { url.lastPathComponent }
}

enum ProjectFolderStatus: Equatable, Sendable {
  case available
  case missing
  case replaced
  case unreadable(String)
}

struct ProjectSkillRoot: Hashable, Sendable {
  let relativePath: String
  let readBy: Set<Tool>

  func url(in project: RegisteredProject) -> URL { project.url.appending(path: relativePath) }

  static let shared = Self(relativePath: ".agents/skills", readBy: Set(Tool.allCases).subtracting([.claude]))
  static let claude = Self(relativePath: ".claude/skills", readBy: [.claude, .cursor, .copilot, .opencode, .amp])

  static let all: [Self] = [
    shared,
    claude,
    Self(relativePath: ".cursor/skills", readBy: [.cursor]),
    Self(relativePath: ".codex/skills", readBy: [.cursor]),
    Self(relativePath: ".github/skills", readBy: [.copilot]),
    Self(relativePath: ".gemini/skills", readBy: [.gemini]),
    Self(relativePath: ".agent/skills", readBy: [.antigravity, .droid]),
    Self(relativePath: ".opencode/skills", readBy: [.opencode]),
    Self(relativePath: ".factory/skills", readBy: [.droid]),
    Self(relativePath: ".pi/skills", readBy: [.pi]),
  ]
}

enum ProjectSkillTarget: String, Codable, CaseIterable, Identifiable, Sendable {
  case shared, claude

  var id: String { rawValue }
  var root: ProjectSkillRoot {
    switch self {
    case .shared: .shared
    case .claude: .claude
    }
  }
  var relativePath: String { root.relativePath }
  var readBy: Set<Tool> { root.readBy }
  func url(in project: RegisteredProject) -> URL { root.url(in: project) }
}

struct ProjectSkillCopy: Identifiable, Hashable, Sendable {
  let folder: URL
  let resolved: URL
  let root: ProjectSkillRoot
  let isSymlink: Bool
  let contentHash: String

  var id: String { folder.path }
  var skillFile: URL { folder.appending(path: "SKILL.md") }
}

struct ProjectSkillRow: Identifiable, Sendable {
  let name: String
  let description: String
  let localCopies: [ProjectSkillCopy]
  let globalSkill: Skill?

  var id: String { name }
  var localTools: Set<Tool> { Set(localCopies.flatMap(\.root.readBy)) }
  var globalTools: Set<Tool> { globalSkill?.availableIn ?? [] }
  var availableIn: Set<Tool> { localTools.union(globalTools) }
}

enum ProjectSkillScope: String, CaseIterable, Identifiable, Sendable {
  case availableHere, projectOnly

  var id: String { rawValue }
}

struct ProjectSkillFilter: Equatable, Sendable {
  var tool: Tool? = nil
  var scope: ProjectSkillScope = .availableHere

  func matches(_ row: ProjectSkillRow) -> Bool {
    let readers: Set<Tool>
    switch scope {
    case .availableHere: readers = row.availableIn
    case .projectOnly: readers = row.localTools
    }
    return tool.map(readers.contains) ?? !readers.isEmpty
  }
}

struct ProjectInventoryIssue: Identifiable, Equatable, Sendable {
  enum Kind: Sendable { case missingSkillFile, unreadable }
  let path: String
  let kind: Kind
  let message: String

  var id: String { path }
}

struct ProjectRootInventory: Sendable {
  let root: ProjectSkillRoot
  let status: ProjectFolderStatus
}

struct ProjectInventory: Sendable {
  let project: RegisteredProject
  let status: ProjectFolderStatus
  let roots: [ProjectRootInventory]
  let skills: [ProjectSkillRow]
  let issues: [ProjectInventoryIssue]
}

struct ProjectSkillsetAssignment: Codable, Hashable, Sendable {
  let projectID: UUID
  let skillsetID: UUID
  let target: ProjectSkillTarget
  var members: Set<Skill.ID>
  var individualSkillID: Skill.ID? = nil
}

enum ProjectPlanIntent: Codable, Hashable, Sendable {
  case reconcile
  case removeSkill(Skill.ID)
}

struct ProjectSkillEntry: Codable, Hashable, Sendable {
  let projectID: UUID
  let skillID: Skill.ID
  let target: ProjectSkillTarget
  let path: String
  let sourcePath: String
  let sourceFingerprint: String
  let installedFingerprint: String
  let directoryIdentity: ProjectDirectoryIdentity
}

struct ProjectPendingStep: Codable, Hashable, Sendable {
  enum Operation: String, Codable, Sendable { case install, replace, remove }
  enum Phase: String, Codable, Sendable { case prepared, staged, displaced, promoted, completed }

  let skillID: Skill.ID
  let operation: Operation
  var phase: Phase
  let destinationPath: String
  let sourcePath: String?
  let stagePath: String?
  var stageIdentity: ProjectDirectoryIdentity?
  let expectedFingerprint: String?
  let previousReceipt: ProjectSkillEntry?
  var newReceipt: ProjectSkillEntry?
  var trashPath: String?
}

struct ProjectPendingJournal: Codable, Hashable, Sendable {
  var id = UUID()
  let projectID: UUID
  let target: ProjectSkillTarget
  let previousAssignments: [ProjectSkillsetAssignment]
  let proposedAssignments: [ProjectSkillsetAssignment]
  var steps: [ProjectPendingStep]
  var intent: ProjectPlanIntent? = nil
}

struct ProjectState: Codable, Equatable, Sendable {
  var projects: [RegisteredProject] = []
  var assignments: [ProjectSkillsetAssignment] = []
  var entries: [ProjectSkillEntry] = []
  var pending: ProjectPendingJournal?

  init(projects: [RegisteredProject] = [], assignments: [ProjectSkillsetAssignment] = [],
       entries: [ProjectSkillEntry] = [], pending: ProjectPendingJournal? = nil) {
    self.projects = projects
    self.assignments = assignments
    self.entries = entries
    self.pending = pending
  }

  private enum CodingKeys: String, CodingKey { case projects, assignments, entries, pending }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    projects = try container.decodeIfPresent([RegisteredProject].self, forKey: .projects) ?? []
    assignments = try container.decodeIfPresent([ProjectSkillsetAssignment].self, forKey: .assignments) ?? []
    entries = try container.decodeIfPresent([ProjectSkillEntry].self, forKey: .entries) ?? []
    pending = try container.decodeIfPresent(ProjectPendingJournal.self, forKey: .pending)
  }
}

enum ProjectLibrary {
  enum Failure: Error, LocalizedError {
    case notDirectory(String)
    case invalidRegistration(String)
    case globalFolder(String)

    var errorDescription: String? {
      switch self {
      case .notDirectory(let path): "Not a project directory: \(path)"
      case .invalidRegistration(let path): "The registered project folder changed: \(path). Register it again."
      case .globalFolder(let path): "Choose a project folder below your home folder or another project location: \(path)"
      }
    }
  }

  static func register(_ folder: URL, projects: [RegisteredProject]) throws -> RegisteredProject {
    let url = folder.standardizedFileURL.resolvingSymlinksInPath()
    guard url.path != "/", url.path != Paths.home.resolvingSymlinksInPath().path else {
      throw Failure.globalFolder(url.path)
    }
    let identity = try ProjectDirectoryIdentity.read(at: url)
    if let existing = projects.first(where: { $0.path == url.path }) {
      guard existing.directoryIdentity == identity else { throw Failure.invalidRegistration(url.path) }
      return existing
    }
    return RegisteredProject(path: url.path, directoryIdentity: identity)
  }

  static func status(of project: RegisteredProject) -> ProjectFolderStatus {
    guard project.url.standardizedFileURL.resolvingSymlinksInPath().path == project.path else { return .replaced }
    do {
      let identity = try ProjectDirectoryIdentity.read(at: project.url)
      return identity == project.directoryIdentity ? .available : .replaced
    } catch is Failure {
      return .replaced
    } catch let error as NSError {
      if isMissing(error) { return .missing }
      return .unreadable(error.localizedDescription)
    }
  }

  static func inventory(project: RegisteredProject, globalSkills: [Skill]) -> ProjectInventory {
    let status = status(of: project)
    guard status == .available else {
      return ProjectInventory(project: project, status: status, roots: [], skills: [], issues: [])
    }
    let fm = FileManager.default
    var copies: [String: [ProjectSkillCopy]] = [:]
    var descriptions: [String: String] = [:]
    var roots: [ProjectRootInventory] = []
    var issues: [ProjectInventoryIssue] = []
    for root in ProjectSkillRoot.all {
      let url = root.url(in: project)
      let folders: [URL]
      do {
        folders = try fm.contentsOfDirectory(at: url.resolvingSymlinksInPath(), includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles]).map { url.appending(path: $0.lastPathComponent) }
        roots.append(ProjectRootInventory(root: root, status: .available))
      } catch let error as NSError {
        let missing = isMissing(error)
        roots.append(ProjectRootInventory(root: root, status: missing ? .missing : .unreadable(error.localizedDescription)))
        if !missing { issues.append(ProjectInventoryIssue(path: url.path, kind: .unreadable, message: error.localizedDescription)) }
        continue
      }
      for folder in folders.sorted(by: { $0.path < $1.path }) {
        do {
          let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
          if values.isDirectory != true && values.isSymbolicLink != true { continue }
          let file = folder.appending(path: "SKILL.md")
          let text = try String(contentsOf: file, encoding: .utf8)
          let metadata = Frontmatter.parse(text)
          let name = metadata["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
          copies[name, default: []].append(ProjectSkillCopy(folder: folder, resolved: folder.resolvingSymlinksInPath(),
            root: root, isSymlink: values.isSymbolicLink ?? false, contentHash: shortHash(text)))
          if descriptions[name] == nil, let description = metadata["description"], !description.isEmpty {
            descriptions[name] = description
          }
        } catch let error as NSError {
          let missing = isMissing(error)
          issues.append(ProjectInventoryIssue(path: folder.appending(path: "SKILL.md").path,
            kind: missing ? .missingSkillFile : .unreadable, message: error.localizedDescription))
        }
      }
    }
    let globals = Dictionary(globalSkills.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    let names = Set(copies.keys).union(globalSkills.filter { !$0.availableIn.isEmpty }.map(\.name))
    let rows = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { name in
      ProjectSkillRow(name: name, description: descriptions[name] ?? globals[name]?.description ?? "",
        localCopies: copies[name] ?? [], globalSkill: globals[name])
    }
    return ProjectInventory(project: project, status: status, roots: roots, skills: rows, issues: issues)
  }

  private static func isMissing(_ error: NSError) -> Bool {
    error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
  }
}
