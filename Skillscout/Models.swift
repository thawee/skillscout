import CryptoKit
import Foundation

enum Paths {
  /// `$HOME` when set, so the CLI behaves like other command-line tools and demos can run against a fake home.
  static let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.homeDirectoryForCurrentUser

  static func at(_ relative: String) -> URL {
    home.appending(path: relative)
  }

  private static let homePaths = [home.path, home.resolvingSymlinksInPath().path]

  static func abbreviate(_ url: URL) -> String {
    let path = url.path
    guard let homePath = homePaths.first(where: { path.hasPrefix($0 + "/") }) else { return path }
    return "~" + path.dropFirst(homePath.count)
  }

  /// Quartermaster's own folder. Before the rename it was ~/.config/skillscout, which
  /// `SkillInstaller.moveConfigFolder` moves here.
  static let configFolder = at(".config/quartermaster")
  static let libraryFolder = configFolder.appending(path: "skills")
  static let draftsFolder = configFolder.appending(path: "drafts")

  /// Quartermaster's own storage. Only the Library view shows these folders, so everywhere else names them instead.
  private static let libraryStorage: [(paths: [String], name: String)] = [
    (libraryFolder, "Library"), (draftsFolder, "Library drafts"),
  ].map { url, name in
    ([url.path, url.resolvingSymlinksInPath().path], name)
  }

  /// "Library · repo/skill" for a path in Quartermaster's storage, nil for any other path.
  static func libraryLocation(_ url: URL) -> String? {
    let path = url.path
    for storage in libraryStorage {
      for root in storage.paths {
        if path == root { return storage.name }
        if path.hasPrefix(root + "/") { return "\(storage.name) · \(path.dropFirst(root.count + 1))" }
      }
    }
    return nil
  }

  /// Files that mark a top-level Library folder as a downloaded or added repository. A skill moved into the
  /// Library has none of them, so it stays yours to edit.
  static let repositoryMarkers = [".skillscout-repository.json", ".skillscout-upstream.json", ".skillscout-local-source", ".git"]

  /// The Library repository a path is in, or nil for a path outside the Library or in a skill moved there.
  static func libraryRepo(_ url: URL) -> String? {
    let path = url.path
    guard let root = libraryStorage[0].paths.first(where: { path.hasPrefix($0 + "/") }),
          let name = path.dropFirst(root.count + 1).split(separator: "/").first.map(String.init) else { return nil }
    let folder = URL(fileURLWithPath: root).appending(path: name)
    let isRepository = repositoryMarkers.contains { (try? FileManager.default.attributesOfItem(atPath: folder.appending(path: $0).path)) != nil }
    return isRepository ? name : nil
  }

  /// A path for people to read: the Library by name, any other folder abbreviated.
  static func describe(_ url: URL) -> String { libraryLocation(url) ?? abbreviate(url) }

  static let appSupport: URL = {
    let url = at("Library/Application Support/Quartermaster")
    if !FileManager.default.fileExists(atPath: url.path) {
      let previousNames = ["Skillscout Mod", "Skillscout Thawee", "Skillscout"]
      for previous in previousNames.map({ at("Library/Application Support/" + $0) }) {
        guard FileManager.default.fileExists(atPath: previous.path) else { continue }
        if (try? FileManager.default.copyItem(at: previous, to: url)) != nil { break }
      }
    }
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  static let stateFile = appSupport.appending(path: "state.json")
}

func shortHash(_ string: String) -> String {
  SHA256.hash(data: Data(string.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
}

enum Tool: String, CaseIterable, Codable, Identifiable, Sendable {
  case cursor, claude, codex, copilot, gemini, antigravity, opencode, droid, pi, amp

  var id: String { rawValue }

  var name: String {
    switch self {
    case .cursor: "Cursor"
    case .claude: "Claude Code"
    case .codex: "Codex"
    case .copilot: "GitHub Copilot"
    case .gemini: "Gemini CLI"
    case .antigravity: "Antigravity"
    case .opencode: "OpenCode"
    case .droid: "Droid"
    case .pi: "Pi"
    case .amp: "Amp"
    }
  }

  var skillsFolder: URL {
    switch self {
    case .cursor: Paths.at(".cursor/skills")
    case .claude: Paths.at(".claude/skills")
    case .codex: Paths.at(".codex/skills")
    case .copilot: Paths.at(".copilot/skills")
    case .gemini: Paths.at(".gemini/skills")
    case .antigravity: Paths.at(".gemini/antigravity/skills")
    case .opencode: Paths.at(".config/opencode/skills")
    case .droid: Paths.at(".factory/skills")
    case .pi: Paths.at(".pi/agent/skills")
    case .amp: Paths.at(".config/agents/skills")
    }
  }

  /// Whether a skill in the agent's home folder wins over a project skill with the same name. Claude Code documents
  /// "personal over project" (code.claude.com/docs/en/skills); the others don't say which copy they use.
  var personalOverridesProject: Bool {
    switch self {
    case .claude: true
    case .cursor, .codex, .copilot, .gemini, .antigravity, .opencode, .droid, .pi, .amp: false
    }
  }

  /// Folders the tool creates the first time it runs.
  var homeFolders: [String] {
    switch self {
    case .cursor: [".cursor"]
    case .claude: [".claude"]
    case .codex: [".codex"]
    case .copilot: [".copilot"]
    case .gemini: [".gemini"]
    case .antigravity: [".gemini/antigravity"]
    case .opencode: [".config/opencode", ".local/share/opencode"]
    case .droid: [".factory"]
    case .pi: [".pi/agent"]
    case .amp: [".config/amp", ".local/share/amp"]
    }
  }

  var isInstalled: Bool {
    homeFolders.contains { FileManager.default.fileExists(atPath: Paths.at($0).path) }
  }

  static var installed: [Tool] {
    let found = allCases.filter(\.isInstalled)
    return found.isEmpty ? [.cursor, .claude, .codex] : found
  }

  /// The tools picked in Settings, or the installed ones until you pick.
  static var enabled: [Tool] {
    UserDefaults.standard.stringArray(forKey: "tools")?.compactMap(Tool.init(rawValue:)) ?? installed
  }

  /// Accepts `claude`, `claude-code`, `"Claude Code"`, `gemini`, `gemini-cli` and so on.
  init?(argument: String) {
    let key = argument.lowercased().replacingOccurrences(of: " ", with: "-")
    let match = Tool.allCases.first { tool in
      [tool.rawValue, tool.name.lowercased().replacingOccurrences(of: " ", with: "-")].contains(key)
    }
    guard let match else { return nil }
    self = match
  }
}

/// Lets `[Tool: String]` save as a JSON object keyed by the raw value instead of a flat array.
extension Tool: CodingKeyRepresentable {}

struct SkillRoot: Sendable, Hashable {
  enum Kind: Sendable { case shared, user, builtIn, plugin, managed, drafts }

  let label: String
  let url: URL
  let kind: Kind
  let owner: Tool?
  let readBy: Set<Tool>

  static let all: [SkillRoot] = [
    SkillRoot(label: "Shared", url: Paths.at(".agents/skills"), kind: .shared, owner: nil, readBy: [.cursor, .codex, .copilot, .gemini, .antigravity, .opencode, .droid, .pi]),
    SkillRoot(label: "Library", url: Paths.libraryFolder, kind: .managed, owner: nil, readBy: []),
    SkillRoot(label: "Library drafts", url: Paths.draftsFolder, kind: .drafts, owner: nil, readBy: []),
    SkillRoot(label: "Cursor", url: Paths.at(".cursor/skills"), kind: .user, owner: .cursor, readBy: [.cursor]),
    SkillRoot(label: "Claude Code", url: Paths.at(".claude/skills"), kind: .user, owner: .claude, readBy: [.claude, .cursor, .opencode]),
    SkillRoot(label: "Codex", url: Paths.at(".codex/skills"), kind: .user, owner: .codex, readBy: [.codex, .cursor]),
    SkillRoot(label: "GitHub Copilot", url: Paths.at(".copilot/skills"), kind: .user, owner: .copilot, readBy: [.copilot]),
    SkillRoot(label: "Gemini CLI", url: Paths.at(".gemini/skills"), kind: .user, owner: .gemini, readBy: [.gemini]),
    SkillRoot(label: "Antigravity", url: Paths.at(".gemini/antigravity/skills"), kind: .user, owner: .antigravity, readBy: [.antigravity]),
    SkillRoot(label: "OpenCode", url: Paths.at(".config/opencode/skills"), kind: .user, owner: .opencode, readBy: [.opencode]),
    SkillRoot(label: "Droid", url: Paths.at(".factory/skills"), kind: .user, owner: .droid, readBy: [.droid]),
    SkillRoot(label: "Pi", url: Paths.at(".pi/agent/skills"), kind: .user, owner: .pi, readBy: [.pi]),
    SkillRoot(label: "Amp", url: Paths.at(".config/agents/skills"), kind: .user, owner: .amp, readBy: [.amp]),
    SkillRoot(label: "Cursor built-in", url: Paths.at(".cursor/skills-cursor"), kind: .builtIn, owner: .cursor, readBy: [.cursor]),
    SkillRoot(label: "Codex built-in", url: Paths.at(".codex/skills/.system"), kind: .builtIn, owner: .codex, readBy: [.codex]),
    SkillRoot(label: "Cursor plugin", url: Paths.at(".cursor/plugins/cache"), kind: .plugin, owner: .cursor, readBy: [.cursor]),
    SkillRoot(label: "Cursor plugin", url: Paths.at(".cursor/plugins/local"), kind: .plugin, owner: .cursor, readBy: [.cursor]),
    SkillRoot(label: "Claude Code plugin", url: Paths.at(".claude/plugins/cache"), kind: .plugin, owner: .claude, readBy: [.claude, .cursor]),
    SkillRoot(label: "Codex plugin", url: Paths.at(".codex/plugins/cache"), kind: .plugin, owner: .codex, readBy: [.codex]),
  ]
}

struct SkillCopy: Identifiable, Sendable, Hashable {
  let folder: URL
  let resolved: URL
  let root: SkillRoot
  let pluginName: String?
  let isSymlink: Bool
  let contentHash: String
  let created: Date

  var id: String { folder.path }

  /// The files live in Skillscout's storage, directly or through a link.
  var isInLibraryStorage: Bool { Paths.libraryLocation(resolved) != nil }

  /// Where the files live, for pickers. Nil for Library storage, which pickers name by source label alone.
  var visiblePath: String? { isInLibraryStorage ? nil : Paths.abbreviate(resolved) }

  var sourceLabel: String {
    if root.kind == .managed, let repo = Paths.libraryRepo(resolved) { return "From \(repo)" }
    guard let pluginName, let owner = root.owner else { return root.label }
    return "\(pluginName) plugin for \(owner.name)"
  }
}

struct Skill: Identifiable, Sendable, Hashable {
  let name: String
  let description: String
  let copies: [SkillCopy]

  var id: String { name }

  var availableIn: Set<Tool> { Set(copies.flatMap(\.root.readBy)) }

  func missing(from tools: [Tool]) -> [Tool] { tools.filter { !availableIn.contains($0) } }

  var primary: SkillCopy { copies[0] }

  var skillFile: URL { primary.resolved.appending(path: "SKILL.md") }

  var copiesDiffer: Bool { Set(copies.map(\.contentHash)).count > 1 }

  /// When the oldest copy's folder was created, so linking a skill into another tool doesn't make it look new.
  var folderCreated: Date { copies.map(\.created).min() ?? .distantPast }

  /// Copying a skill folder somewhere new resets its creation date, but a chat that used it
  /// proves it existed earlier.
  func created(usage: SkillUsage?) -> Date { min(folderCreated, usage?.firstUsed ?? .distantFuture) }

  /// The copies in your own skills folders. Plugins and tools manage the others.
  var removableCopies: [SkillCopy] { copies.filter { $0.root.kind == .user || $0.root.kind == .shared || $0.root.kind == .managed || $0.root.kind == .drafts } }

  var isPersonal: Bool { !removableCopies.isEmpty }

  var isManaged: Bool { copies.contains { $0.root.kind == .managed } }

  var isInLibrary: Bool { copies.contains { [.managed, .drafts, .shared].contains($0.root.kind) } }

  var isInstalledInAnyTool: Bool { !availableIn.isEmpty }

  var isLibraryOnly: Bool {
    (isManaged || copies.contains { $0.root.kind == .drafts }) && !isInstalledInAnyTool
  }

  var isOutsideLibrary: Bool {
    isPersonal && !copies.contains { $0.root.kind == .managed || $0.root.kind == .shared || $0.root.kind == .drafts }
  }

  /// Installed library skills remain visible before they are linked to an enabled agent.
  func isVisible(in tools: Set<Tool>, includePlugins: Bool) -> Bool {
    (includePlugins || isPersonal) && (isManaged || copies.contains { $0.root.kind == .drafts } || !availableIn.isDisjoint(with: tools))
  }

  /// Removing a folder takes the links to it along, since they'd point to nothing.
  func copiesGoing(with copy: SkillCopy) -> [SkillCopy] {
    guard !copy.isSymlink else { return [copy] }
    return [copy] + removableCopies.filter { $0 != copy && $0.isSymlink && $0.resolved == copy.resolved }
  }

  func copiesRemoving(from tool: Tool) -> [SkillCopy] {
    var seen = Set<String>()
    return removableCopies.filter { $0.root.readBy.contains(tool) }
      .flatMap { copiesGoing(with: $0) }
      .filter { seen.insert($0.folder.standardizedFileURL.path).inserted }
      .sorted {
        let firstDepth = $0.folder.pathComponents.count
        let secondDepth = $1.folder.pathComponents.count
        return firstDepth == secondDepth ? $0.folder.path < $1.folder.path : firstDepth > secondDepth
      }
  }

  /// The tools that stop loading the skill once `removed` are gone.
  func toolsLosing(_ removed: [SkillCopy]) -> Set<Tool> {
    availableIn.subtracting(copies.filter { !removed.contains($0) }.flatMap(\.root.readBy))
  }

  /// The folders that `removed` links to and that stay, because they're not among the copies removed.
  func linkTargetsKept(_ removed: [SkillCopy]) -> [URL] {
    let removedFolders = Set(removed.filter { !$0.isSymlink }.map(\.resolved))
    var seen = Set<URL>()
    return removed.filter(\.isSymlink).map(\.resolved).filter { !removedFolders.contains($0) && seen.insert($0).inserted }
  }

  var isBuiltInOnly: Bool { copies.allSatisfy { $0.root.kind == .builtIn } }

  func isSystemOnly(in tools: Set<Tool>) -> Bool {
    let sources = copies.filter { !$0.root.readBy.isDisjoint(with: tools) }
    return !sources.isEmpty && sources.allSatisfy { $0.root.kind == .builtIn }
  }

  func systemOwners(in tools: Set<Tool>) -> [Tool] {
    let owners = Set(copies.filter {
      $0.root.kind == .builtIn && !$0.root.readBy.isDisjoint(with: tools)
    }.compactMap(\.root.owner))
    return Tool.allCases.filter { owners.contains($0) }
  }

  var isPluginOnly: Bool { copies.allSatisfy { $0.root.kind == .plugin } }

  func provider(for tool: Tool) -> SkillCopy? {
    copies.first { $0.root.readBy.contains(tool) }
  }

  var managedRepos: [String] {
    let repos = copies.filter { $0.root.kind == .managed }.compactMap { Paths.libraryRepo($0.folder) ?? Paths.libraryRepo($0.resolved) }
    return Array(Set(repos))
  }
}

enum SkillSort: String, CaseIterable, Sendable {
  case newest, name, use

  /// Whether `a` comes before `b`. Ties go by name.
  func inOrder(_ a: Skill, _ b: Skill, usage: (Skill) -> SkillUsage?) -> Bool {
    switch self {
    case .newest:
      (b.created(usage: usage(b)), a.name.lowercased()) < (a.created(usage: usage(a)), b.name.lowercased())
    case .name:
      a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    case .use:
      (-(usage(a)?.chats ?? 0), a.name.lowercased()) < (-(usage(b)?.chats ?? 0), b.name.lowercased())
    }
  }
}

struct Prompt: Codable, Identifiable, Hashable, Sendable {
  let id: String
  let tool: Tool
  let project: String
  let date: Date
  let text: String
}

struct SkillUse: Codable, Hashable, Sendable {
  let tool: Tool
  let chat: String
  let project: String
  let date: Date
  /// The skill folder path, or only the skill name when the tool logs just that.
  let folder: String
  let projectPath: String?

  init(tool: Tool, chat: String, project: String, date: Date, folder: String, projectPath: String? = nil) {
    self.tool = tool
    self.chat = chat
    self.project = project
    self.date = date
    self.folder = folder
    self.projectPath = projectPath
  }
}

struct RecordedChat: Hashable, Sendable {
  let tool: Tool
  let project: String
  let chat: String
  let projectPath: String?

  init(_ use: SkillUse) {
    tool = use.tool
    project = use.project
    chat = use.chat
    projectPath = use.projectPath
  }
}

struct RecordedSkillChat: Hashable, Sendable {
  let skill: Skill.ID
  let chat: RecordedChat
}

struct SkillUseResolver: Sendable {
  private var byFolder: [String: Skill.ID] = [:]
  private var byName: [String: Skill.ID] = [:]

  init(skills: [Skill], aliases: [String: String] = [:]) {
    for skill in skills {
      for copy in skill.copies {
        byFolder[copy.folder.path] = skill.id
        byFolder[copy.resolved.path] = skill.id
        byName[copy.folder.lastPathComponent] = byName[copy.folder.lastPathComponent] ?? skill.id
      }
    }
    for skill in skills {
      byName[skill.name] = skill.id
    }
    for (old, new) in aliases where byName[old] == nil {
      var name = new
      for _ in 0..<10 {
        guard byName[name] == nil, let next = aliases[name] else { break }
        name = next
      }
      byName[old] = byName[name]
    }
  }

  func skillID(for use: SkillUse) -> Skill.ID? {
    byFolder[use.folder] ?? byName[(use.folder as NSString).lastPathComponent]
  }
}

struct SkillUsage: Sendable {
  var chats = 0
  var byTool: [Tool: Int] = [:]
  var projects: [String: Int] = [:]
  var firstUsed = Date.distantFuture
  var lastUsed = Date.distantPast

  var topProjects: [String] {
    projects.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(3).map(\.key)
  }

  /// `aliases` maps old skill names to new ones, so a chat that used a skill before a rename or a merge still counts.
  static func tally(_ uses: [SkillUse], skills: [Skill], aliases: [String: String] = [:]) -> [Skill.ID: SkillUsage] {
    let resolver = SkillUseResolver(skills: skills, aliases: aliases)
    var usage: [Skill.ID: SkillUsage] = [:]
    var counted = Set<RecordedSkillChat>()
    for use in uses {
      guard let id = resolver.skillID(for: use) else { continue }
      var entry = usage[id] ?? SkillUsage()
      entry.firstUsed = min(entry.firstUsed, use.date)
      entry.lastUsed = max(entry.lastUsed, use.date)
      if counted.insert(RecordedSkillChat(skill: id, chat: RecordedChat(use))).inserted {
        entry.chats += 1
        entry.byTool[use.tool, default: 0] += 1
        entry.projects[use.project, default: 0] += 1
      }
      usage[id] = entry
    }
    return usage
  }
}

/// The names skills had before you renamed or merged them, and the names they go by now.
enum SkillAliases {
  static let file = Paths.appSupport.appending(path: "aliases.json")

  static func load() -> [String: String] {
    (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
  }

  static func record(_ old: String, as new: String) {
    var aliases = load()
    aliases[old] = new
    aliases[new] = nil
    if let data = try? JSONEncoder().encode(aliases) { try? data.write(to: file, options: .atomic) }
  }
}

struct Suggestion: Codable, Identifiable, Hashable, Sendable {
  var id = UUID()
  var name: String
  var title: String
  var summary: String
  var why: String
  var examples: [Prompt]
  var createdAt: Date
  var draft: String?
  var savedTo: String?
  var savedSkillID: Skill.ID?

  var tools: [Tool] { Tool.allCases.filter { tool in examples.contains { $0.tool == tool } } }

  var projects: [String] { Array(Set(examples.map(\.project))).sorted() }
}

struct Skillset: Identifiable, Codable, Hashable, Sendable {
  var id = UUID()
  var name: String
  var skills: Set<String> = []
}

struct SkillsetAssignment: Codable, Hashable, Sendable {
  let skillsetID: UUID
  let tool: Tool
  var members: Set<Skill.ID>
}

/// A receipt for an entry created by applying skillsets, never for an existing installation.
struct SkillsetEntry: Codable, Hashable, Sendable {
  let skillID: Skill.ID
  let tool: Tool
  let path: String
  let linkDestination: String?
  let fingerprint: String?
}
