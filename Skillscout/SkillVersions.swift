import Foundation

/// Which copy each agent gets. `defaults` is today's preferred source; `byTool` overrides it per agent.
struct SourcePreferences: Codable, Hashable, Sendable {
  var defaults: [Skill.ID: String] = [:]
  var byTool: [Skill.ID: [Tool: String]] = [:]
  /// Agents that skillsets leave without the skill, since none of its versions suits them.
  var skipped: [Skill.ID: Set<Tool>] = [:]
  /// The version each project uses for a skill with versions, by the project's standardized folder path.
  var byProject: [String: [Skill.ID: String]] = [:]

  func path(for id: Skill.ID, tool: Tool?) -> String? {
    tool.flatMap { byTool[id]?[$0] } ?? defaults[id]
  }

  /// The project review's pick. A version stays with that project, since `defaults` would decide it for every agent
  /// and project without a choice of its own; copies with the same content still share the preferred source.
  mutating func choose(_ path: String, for skill: Skill, in project: RegisteredProject) {
    if SkillVersions.versions(of: skill).count > 1 {
      byProject[project.path, default: [:]][skill.id] = path
    } else {
      defaults[skill.id] = path
    }
  }

  /// Saved paths follow folders that moved.
  mutating func relocate(_ folders: [String: String]) {
    defaults = defaults.mapValues { SkillInstaller.relocatedPath($0, folders: folders) }
    byTool = byTool.mapValues { $0.mapValues { SkillInstaller.relocatedPath($0, folders: folders) } }
    byProject = byProject.mapValues { $0.mapValues { SkillInstaller.relocatedPath($0, folders: folders) } }
  }

  /// A renamed skill keeps its choices; a merged one drops them, since the kept skill has its own.
  mutating func move(_ oldID: Skill.ID, to newID: Skill.ID, folders: [String: String], keep: Bool) {
    let oldDefault = defaults.removeValue(forKey: oldID)
    let oldByTool = byTool.removeValue(forKey: oldID)
    let oldSkipped = skipped.removeValue(forKey: oldID)
    let oldByProject = byProject.compactMapValues { $0[oldID] }
    for project in oldByProject.keys {
      byProject[project]?[oldID] = nil
      if byProject[project]?.isEmpty == true { byProject[project] = nil }
    }
    guard keep else { return }
    skipped[newID] = oldSkipped
    if let oldDefault { defaults[newID] = SkillInstaller.relocatedPath(oldDefault, folders: folders) }
    if let oldByTool { byTool[newID] = oldByTool.mapValues { SkillInstaller.relocatedPath($0, folders: folders) } }
    for (project, path) in oldByProject { byProject[project, default: [:]][newID] = SkillInstaller.relocatedPath(path, folders: folders) }
  }
}

/// A copy a plan would create.
struct PlannedCopy: Hashable, Sendable {
  let skillID: Skill.ID
  let folder: URL
  let contentHash: String
  let readBy: Set<Tool>
}

extension PlannedCopy {
  /// The agents that read `folder` come from the skills root it is in.
  init(skillID: Skill.ID, folder: URL, contentHash: String) {
    self.init(skillID: skillID, folder: folder, contentHash: contentHash, readBy: SkillRoot.containing(folder)?.readBy ?? [])
  }
}

/// Which version each agent gets, as indexes into `SkillVersions.versions(of:)`.
struct VersionChoice: Hashable, Sendable {
  var own: [Tool: Int] = [:]
  var skipped: Set<Tool> = []
  /// The shared preferred source's version, for agents with neither.
  var fallback: Int?
}

/// The version an agent ends up with, and the agents whose skills folders decide it.
struct Resolution: Hashable, Sendable {
  let version: Int?
  let follows: [Tool]
}

struct VersionConflict: Hashable, Sendable {
  let skillID: Skill.ID
  let tool: Tool
  let folders: [URL]
}

enum SkillVersions {
  /// The agents that can see a conflict. One with no home folder reads nothing, so by default only installed agents
  /// count; tests set every agent so they don't depend on the machine.
  @TaskLocal static var agents: Set<Tool>?

  static var countedAgents: Set<Tool> { agents ?? Set(Tool.allCases.filter(\.isInstalled)) }

  /// Distinct-content groups among a skill's installable copies; >1 means the skill has versions.
  static func versions(of skill: Skill) -> [[SkillCopy]] {
    var groups: [[SkillCopy]] = []
    for copy in SkillInstaller.installableSources(for: skill) {
      if let index = groups.firstIndex(where: { $0[0].contentHash == copy.contentHash }) {
        groups[index].append(copy)
      } else {
        groups.append([copy])
      }
    }
    return groups
  }

  /// Conflicts each agent would have after adding `adding` and removing the folders in `removing`.
  /// `removing` holds `key(_:)` values.
  static func conflicts(skills: [Skill], adding: [PlannedCopy], removing: Set<String>) -> [VersionConflict] {
    conflicts(existing: existing(skills), adding: adding, removing: removing)
  }

  /// The same check over copies that carry their own readers, such as a project's skill folders.
  static func conflicts(existing: [PlannedCopy], adding: [PlannedCopy], removing: Set<String>) -> [VersionConflict] {
    let seen = visible(existing: existing, adding: adding, removing: removing)
    let agents = countedAgents
    return seen.keys.sorted().flatMap { id in
      Tool.allCases.filter(agents.contains).compactMap { tool in
        guard let versions = seen[id]?[tool], versions.count > 1 else { return nil }
        return VersionConflict(skillID: id, tool: tool, folders: versions.values.sorted { $0.path < $1.path })
      }
    }
  }

  /// The conflicts a change would create: an agent that saw one version now sees two, or sees a version it didn't.
  static func newConflicts(skills: [Skill], adding: [PlannedCopy], removing: Set<String>) -> [VersionConflict] {
    newConflicts(existing: existing(skills), adding: adding, removing: removing)
  }

  static func newConflicts(existing: [PlannedCopy], adding: [PlannedCopy], removing: Set<String>) -> [VersionConflict] {
    let before = visible(existing: existing, adding: [], removing: [])
    let after = visible(existing: existing, adding: adding, removing: removing)
    return conflicts(existing: existing, adding: adding, removing: removing).filter { conflict in
      let earlier = Set(before[conflict.skillID]?[conflict.tool].map { Array($0.keys) } ?? [])
      let later = Set(after[conflict.skillID]?[conflict.tool].map { Array($0.keys) } ?? [])
      return earlier.count <= 1 || !later.isSubset(of: earlier)
    }
  }

  private static func existing(_ skills: [Skill]) -> [PlannedCopy] {
    skills.flatMap { skill in
      skill.copies.map { PlannedCopy(skillID: skill.id, folder: $0.folder, contentHash: $0.contentHash, readBy: $0.root.readBy) }
    }
  }

  /// Skill, then agent, then content hash, to one folder holding that content. An existing copy stands for its
  /// content ahead of a planned one, so a planned duplicate of what an agent already reads never looks new.
  private static func visible(existing: [PlannedCopy], adding: [PlannedCopy], removing: Set<String>) -> [Skill.ID: [Tool: [String: URL]]] {
    var copies: [Skill.ID: [String: PlannedCopy]] = [:]
    for copy in existing where !removing.contains(key(copy.folder)) {
      copies[copy.skillID, default: [:]][key(copy.folder)] = copy
    }
    var planned: Set<String> = []
    for copy in adding {
      copies[copy.skillID, default: [:]][key(copy.folder)] = copy
      planned.insert(key(copy.folder))
    }
    return copies.mapValues { byFolder in
      let ordered = byFolder.sorted { a, b in
        let (plannedA, plannedB) = (planned.contains(a.key), planned.contains(b.key))
        return plannedA == plannedB ? a.key < b.key : !plannedA
      }.map(\.value)
      var result: [Tool: [String: URL]] = [:]
      for copy in ordered {
        for tool in copy.readBy where result[tool]?[copy.contentHash] == nil {
          result[tool, default: [:]][copy.contentHash] = copy.folder
        }
      }
      return result
    }
  }

  /// A folder's path with its parent resolved, so a link and the path a receipt recorded compare equal.
  static func key(_ folder: URL) -> String {
    folder.deletingLastPathComponent().resolvingSymlinksInPath().path + "/" + folder.lastPathComponent
  }

  /// "foo: Cursor would see two versions (Cursor also reads ~/.claude/skills)." With nothing planned, the conflict
  /// is one that already exists.
  static func message(_ conflict: VersionConflict, adding: [PlannedCopy] = []) -> String {
    let planned = Set(adding.map { key($0.folder) })
    let own = key(conflict.tool.skillsFolder)
    func parents(_ folders: [URL]) -> String {
      folders.map { Paths.abbreviate($0.deletingLastPathComponent()) }
        .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")
    }
    let count = conflict.folders.count == 2 ? "two" : "\(conflict.folders.count)"
    let name = conflict.tool.name
    if planned.isEmpty { return "\(conflict.skillID): \(name) already sees \(count) versions (\(parents(conflict.folders)))." }
    let others = conflict.folders.filter { !planned.contains(key($0)) && key($0.deletingLastPathComponent()) != own }
    let reason = others.isEmpty ? "from \(parents(conflict.folders))" : "\(name) also reads \(parents(others))"
    return "\(conflict.skillID): \(name) would see \(count) versions (\(reason))."
  }

  /// What says which agents a version is for, strongest first: its `supported_tools`, the folders it sits in, then the
  /// agents that read its current installations.
  private static func claims(_ version: [SkillCopy]) -> [Set<Tool>] {
    let supported = version.lazy.compactMap { supportedTools(in: $0.resolved) }.first { !$0.isEmpty } ?? []
    let named = version.reduce(into: Set<Tool>()) { $0.formUnion(pathTools($1)) }
    let readers = version.filter { $0.root.kind != .managed && $0.root.kind != .drafts }
      .reduce(into: Set<Tool>()) { $0.formUnion($1.root.readBy) }
    return [supported, named, readers]
  }

  static func suggestedTools(for version: [SkillCopy]) -> Set<Tool>? {
    claims(version).first { !$0.isEmpty }
  }

  /// Prefill for the picker, on top of `keeping`. Each other agent in `tools` takes the version its strongest claim
  /// names, when only one version claims it that strongly, or else the one version nothing claims. While an agent
  /// would read two versions, the weakest fill involved goes, after the agents left to the fallback, so the prefill
  /// opens without a problem of its own making. With a fallback, an agent without a fill would get the fallback, so
  /// it's skipped instead.
  static func suggestedChoice(for skill: Skill, tools: [Tool], skills: [Skill], keeping: VersionChoice = VersionChoice()) -> VersionChoice {
    let claims = versions(of: skill).map(claims)
    let unclaimed = claims.indices.filter { claims[$0].allSatisfy(\.isEmpty) }
    var fills: [(tool: Tool, version: Int, strength: Int)] = []
    for tool in tools where keeping.own[tool] == nil && !keeping.skipped.contains(tool) {
      if let strength = (0..<3).first(where: { level in claims.contains { $0[level].contains(tool) } }) {
        let claimants = claims.indices.filter { claims[$0][strength].contains(tool) }
        if claimants.count == 1 { fills.append((tool, claimants[0], strength)) }
      } else if unclaimed.count == 1 {
        fills.append((tool, unclaimed[0], 3))
      }
    }
    var choice = keeping
    for fill in fills { choice.own[fill.tool] = fill.version }
    let unfilled = choice.fallback == nil ? [] : tools.filter { choice.own[$0] == nil && !choice.skipped.contains($0) }
    var weakest = unfilled + fills.indices.sorted { (fills[$0].strength, $0) > (fills[$1].strength, $1) }.map { fills[$0].tool }
    while true {
      let problems = choiceProblems(for: skill, choice: choice, skills: skills)
      guard !problems.isEmpty, let index = weakest.firstIndex(where: { problems[$0] != nil }) else { return choice }
      let tool = weakest.remove(at: index)
      choice.own[tool] = nil
      if choice.fallback != nil { choice.skipped.insert(tool) }
    }
  }

  /// The saved choice, as indexes into `versions(of:)`. A saved path that no longer holds a version is dropped.
  static func savedChoice(for skill: Skill, preferences: SourcePreferences) -> VersionChoice {
    let versions = versions(of: skill)
    func index(_ path: String?) -> Int? { path.flatMap { path in versions.firstIndex { $0.contains { $0.resolved.path == path } } } }
    return VersionChoice(own: (preferences.byTool[skill.id] ?? [:]).compactMapValues(index),
      skipped: preferences.skipped[skill.id] ?? [], fallback: index(preferences.defaults[skill.id]))
  }

  /// What each agent in `tools` ends up with. An agent that reads the skills folder of an agent placed before it
  /// with a version takes that version, so Cursor follows Claude Code; when those agents disagree it gets none, and
  /// `choiceProblems` says why. Every other agent gets its own choice, else the fallback, unless it's skipped.
  static func resolve(_ choice: VersionChoice, tools: [Tool] = Tool.allCases) -> [Tool: Resolution] {
    var result: [Tool: Resolution] = [:]
    for tool in leaderOrder(tools) {
      let leaders = tools.filter { result[$0]?.version != nil && reads(tool, $0) }
      if leaders.isEmpty {
        result[tool] = Resolution(version: choice.skipped.contains(tool) ? nil : choice.own[tool] ?? choice.fallback, follows: [])
      } else {
        let found = Set(leaders.compactMap { result[$0]?.version })
        result[tool] = Resolution(version: found.count == 1 ? found.first : nil, follows: leaders)
      }
    }
    return result
  }

  /// `tools`, each after the agents whose skills folders it reads, unless they read its folder too.
  private static func leaderOrder(_ tools: [Tool]) -> [Tool] {
    var rest = tools
    var ordered: [Tool] = []
    while !rest.isEmpty {
      let next = rest.firstIndex { tool in !rest.contains { reads(tool, $0) && !reads($0, tool) } } ?? 0
      ordered.append(rest.remove(at: next))
    }
    return ordered
  }

  /// Whether `tool` reads `other`'s skills folder.
  static func reads(_ tool: Tool, _ other: Tool) -> Bool {
    tool != other && SkillRoot.containing(other.skillsFolder)?.readBy.contains(tool) == true
  }

  /// The versions each agent already reads, as indexes into `versions(of:)`. Applying a skillset keeps them.
  static func installedVersions(of skill: Skill) -> [Tool: Set<Int>] {
    var result: [Tool: Set<Int>] = [:]
    for (index, version) in versions(of: skill).enumerated() {
      for tool in version.flatMap(\.root.readBy) { result[tool, default: []].insert(index) }
    }
    return result
  }

  /// Why a choice would leave an agent reading two versions, by agent: the agent that would see them, and the agents
  /// whose copies cause it, since only their rows can fix it. Like applying, each agent that reads no copy yet gets
  /// its version in its own skills folder, and an agent that already reads one keeps it.
  static func choiceProblems(for skill: Skill, choice: VersionChoice, skills: [Skill]) -> [Tool: [String]] {
    let versions = versions(of: skill)
    let name = SkillInstaller.slug(skill.name)
    let installed = installedVersions(of: skill)
    let chosen = resolve(choice).compactMapValues { $0.version.flatMap { versions.indices.contains($0) ? $0 : nil } }
      .filter { installed[$0.key] == nil }
    let planned = chosen.map { tool, index in
      PlannedCopy(skillID: skill.id, folder: tool.skillsFolder.appending(path: name), contentHash: versions[index][0].contentHash)
    }
    var result: [Tool: [String]] = [:]
    for conflict in newConflicts(skills: skills, adding: planned, removing: []) {
      let text = message(conflict, adding: planned)
      let causes = Set(conflict.folders.map(key))
      let owners = chosen.keys.filter { causes.contains(key($0.skillsFolder.appending(path: name))) }
      for tool in Set(owners + [conflict.tool]) where result[tool]?.contains(text) != true {
        result[tool, default: []].append(text)
      }
    }
    return result
  }

  /// A name for each version that tells it apart: the agents it claims to be for, else the folders that differ
  /// between the versions, else where it comes from.
  static func titles(for skill: Skill) -> [String] {
    let versions = versions(of: skill)
    let folders = versions.map { Array($0[0].resolved.standardizedFileURL.pathComponents.dropLast()) }
    let common = folders.first.map { first in (0..<first.count).first { index in folders.contains { $0.count <= index || $0[index] != first[index] } } ?? first.count } ?? 0
    let differing = folders.map { $0.dropFirst(common).joined(separator: "/") }
    let named = versions.map { version in
      claims(version).prefix(2).first { !$0.isEmpty }.map { tools in
        "For " + Tool.allCases.filter(tools.contains).map(\.name).formatted()
      }
    }
    let rootCopies: [String?] = versions.map { version in
      let copy = version[0]
      let direct = copy.root.kind != .managed && !copy.isSymlink
        && copy.folder.deletingLastPathComponent().standardizedFileURL.path == copy.root.url.standardizedFileURL.path
      return direct ? "\(copy.root.label) copy" : nil
    }
    return versions.indices.map { index in
      let place = rootCopies[index].flatMap { label in rootCopies.filter { $0 == label }.count == 1 ? label : nil }
        ?? (differing[index].isEmpty ? versions[index][0].sourceLabel : differing[index])
      guard let name = named[index] else { return place }
      return named.filter { $0 == name }.count > 1 ? "\(name) (\(place))" : name
    }
  }

  /// The numbered version title of `copy`, when `skill` has versions.
  static func title(of copy: SkillCopy, in skill: Skill) -> String? {
    let versions = versions(of: skill)
    guard versions.count > 1, let index = versions.firstIndex(where: { $0[0].contentHash == copy.contentHash }) else { return nil }
    return "\(index + 1). \(titles(for: skill)[index])"
  }

  /// The agents a skill folder's `supported_tools` frontmatter lists, or nil when it lists none.
  static func supportedTools(in folder: URL) -> Set<Tool>? {
    let markdown = (try? String(contentsOf: folder.appending(path: "SKILL.md"), encoding: .utf8)) ?? ""
    return supportedTools(Frontmatter.parse(markdown))
  }

  static func supportedTools(_ frontmatter: [String: String]) -> Set<Tool>? {
    guard let supported = frontmatter["supported_tools"] else { return nil }
    let names = supported.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "").split(separator: ",")
      .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'"))) }
    return Set(names.compactMap { Tool(argument: $0) })
  }

  /// Agents named by the folders between a copy's root (or Library repository) and the skill folder itself,
  /// such as `claude/foo` or `.claude/skills/foo`. Plugin caches are skipped: their folders are vendor names.
  private static func pathTools(_ copy: SkillCopy) -> Set<Tool> {
    let (root, folder) = SkillRoot.containing(copy.resolved).map { ($0, copy.resolved) } ?? (copy.root, copy.folder)
    guard root.kind != .plugin else { return [] }
    let base = root.url.standardizedFileURL.pathComponents
    var parts = folder.standardizedFileURL.pathComponents
    guard parts.starts(with: base) else { return [] }
    parts = Array(parts.dropFirst(base.count).dropLast())
    if root.kind == .managed { parts = Array(parts.dropFirst()) }
    return Set(parts.compactMap { Tool(argument: $0.hasPrefix(".") ? String($0.dropFirst()) : $0) })
  }
}

extension SkillRoot {
  /// The deepest root holding `url`, so `~/.codex/skills/.system` wins over `~/.codex/skills`.
  static func containing(_ url: URL) -> SkillRoot? {
    let path = url.standardizedFileURL.path
    return all.filter { path == $0.url.path || path.hasPrefix($0.url.path + "/") }.max { $0.url.path.count < $1.url.path.count }
  }
}
