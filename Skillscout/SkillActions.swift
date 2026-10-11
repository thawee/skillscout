import Foundation

struct UsageScope: Equatable, Sendable {
  var project: String?
  var days: Int?

  func filter(_ uses: [SkillUse], now: Date = Date()) -> [SkillUse] {
    let cutoff = days.map { now.addingTimeInterval(-Double($0) * 86_400) }
    return uses.filter { use in
      (project == nil || use.project == project) && (cutoff.map { use.date >= $0 } ?? true)
    }
  }

  static func projectLabel(_ project: String) -> String {
    if project.isEmpty { return "Unknown project" }
    return project.hasPrefix("/") ? Paths.abbreviate(URL(fileURLWithPath: project)) : project
  }

  func description(loadedDays: Int) -> String {
    let period = "the last \(days ?? loadedDays) days"
    return project.map { "\(period) in \(Self.projectLabel($0))" } ?? period
  }
}

extension SkillAliases {
  static func resolve(_ identity: Skill.ID, among skills: [Skill], aliases: [String: String]) -> Skill? {
    var name = identity
    var visited: Set<String> = []
    while visited.insert(name).inserted {
      if let skill = skills.first(where: { $0.id == name }) { return skill }
      guard let next = aliases[name] else { return nil }
      name = next
    }
    return nil
  }
}

extension Suggestion {
  func savedSkill(among skills: [Skill], aliases: [String: String]) -> Skill? {
    if let savedTo, let skill = skills.first(where: { skill in
      skill.copies.contains { $0.folder.path == savedTo || $0.resolved.path == savedTo }
    }) { return skill }
    if let savedSkillID { return SkillAliases.resolve(savedSkillID, among: skills, aliases: aliases) }
    guard let savedTo else { return nil }
    return SkillAliases.resolve(URL(fileURLWithPath: savedTo).lastPathComponent, among: skills, aliases: aliases)
  }
}

extension InstalledPlugin {
  func skillCopy(named name: String, among skills: [Skill]) -> (skill: Skill, copy: SkillCopy)? {
    let ancestor = folder.resolvingSymlinksInPath().path + "/"
    for skill in skills {
      if let copy = skill.copies.first(where: {
        $0.root.kind == .plugin && $0.root.owner == tool && $0.resolved.path.hasPrefix(ancestor)
          && (skill.name == name || $0.folder.lastPathComponent == name)
      }) { return (skill, copy) }
    }
    return nil
  }
}

struct SkillAddRequest: Identifiable, Sendable {
  let skillID: Skill.ID
  let sourcePath: String
  let tool: Tool
  let reviewedFingerprint: String

  var id: String { "\(skillID)|\(tool.rawValue)" }
}

enum SkillAddOutcome: Sendable {
  case available(URL)
  case added(URL)
  case kept(URL)
  case conflict(SkillInstaller.AddConflict)
  case failed(String)

  var completed: Bool {
    switch self {
    case .available, .added, .kept: true
    case .conflict, .failed: false
    }
  }

  var becameAvailable: Bool {
    switch self {
    case .available, .added: true
    case .kept, .conflict, .failed: false
    }
  }

  var message: String {
    switch self {
    case .available: "Already available from this source"
    case .added: "Added successfully"
    case .kept: "Skipped. Existing installation kept"
    case .conflict(let conflict): "Existing installation kept at \(Paths.abbreviate(conflict.destination))"
    case .failed(let message): message
    }
  }
}

struct SkillAddResult: Identifiable, Sendable {
  let request: SkillAddRequest
  let outcome: SkillAddOutcome
  var id: String { request.id }

  func matches(_ other: SkillAddRequest) -> Bool {
    request.id == other.id && request.sourcePath == other.sourcePath
      && request.reviewedFingerprint == other.reviewedFingerprint
  }
}


enum SkillContents {
  static func read(_ relativePath: String, from source: URL) throws -> String {
    let components = relativePath.split(separator: "/")
    guard !relativePath.hasPrefix("/"), !components.contains("..") else { throw CocoaError(.fileReadNoPermission) }
    var file = source.resolvingSymlinksInPath()
    for component in components {
      file.append(path: String(component))
      if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: file.path) {
        return "Symbolic link to \(target). Contents are not followed."
      }
    }
    return try String(contentsOf: file, encoding: .utf8)
  }
}

enum SkillDestination: Hashable, Sendable {
  case global
  case project(UUID)
}

struct SkillAddPresentation: Identifiable, Sendable {
  let id = UUID()
  var skillIDs: [Skill.ID] = []
  var destination: SkillDestination = .global
  var skillsetID: UUID?
  var sources: [Skill.ID: String] = [:]
  var tool: Tool?
  var excludedTools: Set<Tool> = []
}
