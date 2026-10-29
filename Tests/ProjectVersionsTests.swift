import Foundation
import Testing

/// A made-up project and Library under a temporary folder. Home copies sit at real home paths by path only, so
/// nothing reads or writes the real home.
private final class ProjectVersionFixture {
  let root: URL
  let project: RegisteredProject
  let other: RegisteredProject
  var state: ProjectState

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(path: "skillscout-project-versions-\(UUID().uuidString)")
      .standardizedFileURL.resolvingSymlinksInPath()
    for name in ["project", "other"] {
      try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
    }
    project = try ProjectLibrary.register(root.appending(path: "project"), projects: [])
    other = try ProjectLibrary.register(root.appending(path: "other"), projects: [project])
    state = ProjectState(projects: [project, other])
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  static func text(_ name: String, _ body: String) -> String { "---\nname: \(name)\ndescription: Fixture\n---\n\(body)\n" }

  @discardableResult
  func write(_ name: String, _ body: String, at folder: URL) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(Self.text(name, body).utf8).write(to: folder.appending(path: "SKILL.md"))
    return folder
  }

  /// A Library copy with its real content hash, so it compares with the copies a project scan finds.
  func library(_ name: String, _ body: String, repo: String = "acme") throws -> SkillCopy {
    let folder = try write(name, body, at: root.appending(path: "library/\(repo)/\(name)"))
    let libraryRoot = SkillRoot(label: "Fixture", url: root.appending(path: "library"), kind: .managed, owner: nil, readBy: [])
    return SkillCopy(folder: folder, resolved: folder, root: libraryRoot, pluginName: nil, isSymlink: false,
      contentHash: shortHash(Self.text(name, body)), created: .distantPast)
  }

  func direct(_ ids: Set<Skill.ID>, skills: [Skill], in project: RegisteredProject? = nil, target: ProjectSkillTarget = .shared,
              preferences: SourcePreferences = SourcePreferences()) -> ProjectSkillPlan {
    SkillInstaller.projectSkillsPlan(project: project ?? self.project, state: state, skills: skills, skillIDs: ids,
      target: target, preferences: preferences)
  }

  func apply(_ plan: ProjectSkillPlan) throws {
    _ = try SkillInstaller.applyProjectPlan(plan, state: &state, persist: { _ in }, trash: { $0 })
  }
}

private func uniqueName() -> String { "project-versions-" + UUID().uuidString.lowercased() }

@Suite(.allAgents) struct ProjectVersionTests {
  @Test func aHandMadeCursorCopyLeavesOutADifferentVersionAndTheRestApplies() throws {
    let fixture = try ProjectVersionFixture()
    let (name, clean) = (uniqueName(), uniqueName())
    let cursorFolder = fixture.project.url.appending(path: ".cursor/skills")
    try fixture.write(name, "Hand made for Cursor.", at: cursorFolder.appending(path: name))
    let skills = [Skill(name: name, description: "", copies: [try fixture.library(name, "From the Library.")]),
                  Skill(name: clean, description: "", copies: [try fixture.library(clean, "Unrelated.")])]

    let plan = fixture.direct([name, clean], skills: skills)

    #expect(plan.leftOut == ["\(name): Cursor would see two versions (Cursor also reads \(Paths.abbreviate(cursorFolder)))."])
    #expect(plan.issues.isEmpty)
    #expect(plan.changes.map(\.skillID) == [clean])
    #expect(plan.canApply)
    try fixture.apply(plan)
    let shared = fixture.project.url.appending(path: ".agents/skills")
    #expect(FileManager.default.fileExists(atPath: shared.appending(path: "\(clean)/SKILL.md").path))
    #expect(!FileManager.default.fileExists(atPath: shared.appending(path: name).path))
  }

  @Test func theSameContentInACursorFolderIsAllowed() throws {
    let fixture = try ProjectVersionFixture()
    let name = uniqueName()
    try fixture.write(name, "Same everywhere.", at: fixture.project.url.appending(path: ".cursor/skills/\(name)"))
    let skill = Skill(name: name, description: "", copies: [try fixture.library(name, "Same everywhere.")])

    let plan = fixture.direct([name], skills: [skill])

    #expect(plan.issues.isEmpty)
    #expect(plan.leftOut.isEmpty)
    #expect(plan.warnings.isEmpty)
    #expect(plan.changes.map(\.skillID) == [name])
  }

  @Test func anExistingProjectConflictIsReportedWithoutBlockingAnotherSkill() throws {
    let fixture = try ProjectVersionFixture()
    let (conflicted, added) = (uniqueName(), uniqueName())
    try fixture.write(conflicted, "Cursor's own.", at: fixture.project.url.appending(path: ".cursor/skills/\(conflicted)"))
    try fixture.write(conflicted, "Shared.", at: fixture.project.url.appending(path: ".agents/skills/\(conflicted)"))
    let skill = Skill(name: added, description: "", copies: [try fixture.library(added, "Unrelated.")])

    let plan = fixture.direct([added], skills: [skill])

    #expect(plan.canApply)
    #expect(plan.changes.map(\.skillID) == [added])
    let folders = [".agents/skills", ".cursor/skills"].map { Paths.abbreviate(fixture.project.url.appending(path: $0)) }
    #expect(plan.warnings == ["\(conflicted): Cursor already sees two versions (\(folders.joined(separator: ", ")))."])
    try fixture.apply(plan)
    #expect(FileManager.default.fileExists(atPath: fixture.project.url.appending(path: ".agents/skills/\(added)/SKILL.md").path))
  }

  @Test func aSkillWithVersionsAndNoProjectChoiceAsksEvenWithAPreferredSource() throws {
    let fixture = try ProjectVersionFixture()
    let name = uniqueName()
    let first = try fixture.library(name, "First version.", repo: "one")
    let second = try fixture.library(name, "Second version.", repo: "two")
    let skill = Skill(name: name, description: "", copies: [first, second])

    for preferences in [SourcePreferences(), SourcePreferences(defaults: [name: first.resolved.path])] {
      let plan = fixture.direct([name], skills: [skill], preferences: preferences)
      #expect(plan.changes.isEmpty)
      #expect(plan.issues == ["\(name): It has 2 versions. Choose the version this project uses before applying."])
    }
    let chosen = fixture.direct([name], skills: [skill],
      preferences: SourcePreferences(byProject: [fixture.project.path: [name: second.resolved.path]]))
    #expect(chosen.issues.isEmpty)
    #expect(chosen.changes.map(\.sourcePath) == [second.resolved.path])
  }

  @Test func aDifferentHomeCopyWarnsEveryReaderAndThePlanStillApplies() throws {
    let fixture = try ProjectVersionFixture()
    let name = uniqueName()
    let source = try fixture.library(name, "Project version.")
    let claudeHome = SkillRoot.all.first { $0.url == Tool.claude.skillsFolder }!
    let home = SkillCopy(folder: claudeHome.url.appending(path: name), resolved: claudeHome.url.appending(path: name),
      root: claudeHome, pluginName: nil, isSymlink: false, contentHash: "home-version", created: .distantPast)
    let skill = Skill(name: name, description: "", copies: [source, home])
    let preferences = SourcePreferences(byProject: [fixture.project.path: [name: source.resolved.path]])

    let plan = fixture.direct([name], skills: [skill], target: .claude, preferences: preferences)

    let folder = Paths.abbreviate(claudeHome.url)
    #expect(plan.issues.isEmpty)
    #expect(plan.warnings == [
      "\(name): Cursor also reads a different copy in \(folder). Which copy Cursor uses is up to Cursor.",
      "\(name): Claude Code also reads a different copy in \(folder). Claude Code uses its personal copy over the project's.",
      "\(name): OpenCode also reads a different copy in \(folder). Which copy OpenCode uses is up to OpenCode.",
    ])
    try fixture.apply(plan)
    #expect(FileManager.default.fileExists(atPath: fixture.project.url.appending(path: ".claude/skills/\(name)/SKILL.md").path))
  }

  @Test func aSameContentHomeCopyOrADifferentPluginCopyGivesNoWarning() throws {
    let fixture = try ProjectVersionFixture()
    let name = uniqueName()
    let source = try fixture.library(name, "Project version.")
    func copy(in root: SkillRoot, hash: String) -> SkillCopy {
      let folder = root.url.appending(path: name)
      return SkillCopy(folder: folder, resolved: folder, root: root, pluginName: root.kind == .plugin ? "fixture" : nil,
        isSymlink: false, contentHash: hash, created: .distantPast)
    }
    let claudeHome = SkillRoot.all.first { $0.url == Tool.claude.skillsFolder }!
    let claudePlugin = SkillRoot.all.first { $0.kind == .plugin && $0.owner == .claude }!
    let skill = Skill(name: name, description: "", copies: [
      source, copy(in: claudeHome, hash: source.contentHash), copy(in: claudePlugin, hash: "plugin-version")])
    let preferences = SourcePreferences(byProject: [fixture.project.path: [name: source.resolved.path]])

    let plan = fixture.direct([name], skills: [skill], target: .claude, preferences: preferences)

    #expect(plan.issues.isEmpty)
    #expect(plan.warnings.isEmpty)
    #expect(plan.changes.map(\.skillID) == [name])
  }

  @Test func onlyClaudeCodeSaysItsPersonalCopyWins() {
    #expect(Tool.allCases.filter(\.personalOverridesProject) == [.claude])
  }
}

@Suite(.allAgents) struct ProjectVersionScopeTests {
  @Test func aProjectsVersionChoiceStaysInThatProject() throws {
    let fixture = try ProjectVersionFixture()
    let name = uniqueName()
    let first = try fixture.library(name, "First version.", repo: "one")
    let second = try fixture.library(name, "Second version.", repo: "two")
    let skill = Skill(name: name, description: "", copies: [first, second])
    var preferences = SourcePreferences()

    preferences.choose(second.resolved.path, for: skill, in: fixture.project)

    #expect(fixture.direct([name], skills: [skill], preferences: preferences).changes.map(\.sourcePath) == [second.resolved.path])
    let elsewhere = fixture.direct([name], skills: [skill], in: fixture.other, preferences: preferences)
    #expect(elsewhere.changes.isEmpty)
    #expect(elsewhere.issues == ["\(name): It has 2 versions. Choose the version this project uses before applying."])
    #expect(SkillInstaller.skillsetSource(skill, for: .codex, preferences: preferences) == nil)
    let assignment = SkillsetAssignment(skillsetID: UUID(), tool: .codex, members: [name])
    let global = SkillInstaller.skillsetPlans(tools: [.codex], assignments: [assignment], entries: [], skills: [skill],
      preferences: preferences)[.codex]
    #expect(global?.additions.isEmpty == true)
  }

  @Test func aSameContentPickStaysThePreferredSource() throws {
    let fixture = try ProjectVersionFixture()
    let name = uniqueName()
    let first = try fixture.library(name, "Same.", repo: "one")
    let second = try fixture.library(name, "Same.", repo: "two")
    let skill = Skill(name: name, description: "", copies: [first, second])
    var preferences = SourcePreferences()

    preferences.choose(second.resolved.path, for: skill, in: fixture.project)

    #expect(preferences.defaults == [name: second.resolved.path])
    #expect(preferences.byProject.isEmpty)
  }

  @Test func projectChoicesSaveAndFollowRenamesAndMoves() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "skillscout-project-state-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "state.json")
    var state = SkillsetState()
    state.sourcePreferences.byProject = ["/made-up/project": ["old": "/made-up/library/a/old"]]
    try state.save(to: file)
    var loaded = try SkillsetState.load(from: file).sourcePreferences
    #expect(loaded.byProject == ["/made-up/project": ["old": "/made-up/library/a/old"]])

    loaded.move("old", to: "new", folders: ["/made-up/library/a/old": "/made-up/library/a/new"], keep: true)
    #expect(loaded.byProject == ["/made-up/project": ["new": "/made-up/library/a/new"]])
    loaded.relocate(["/made-up/library/a": "/made-up/library/b"])
    #expect(loaded.byProject == ["/made-up/project": ["new": "/made-up/library/b/new"]])
    loaded.move("new", to: "kept", folders: [:], keep: false)
    #expect(loaded.byProject.isEmpty)
  }
}

@Suite(.allAgents) struct SkillsetFileVersionTests {
  private func copy(_ path: String, hash: String) -> SkillCopy {
    let folder = URL(fileURLWithPath: path)
    let root = SkillRoot(label: "Fixture", url: folder.deletingLastPathComponent(), kind: .managed, owner: nil, readBy: [])
    return SkillCopy(folder: folder, resolved: folder, root: root, pluginName: nil, isSymlink: false, contentHash: hash, created: .distantPast)
  }

  @Test func perAgentVersionsFromTwoRepositoriesAndSkipsRoundTrip() throws {
    let name = uniqueName()
    let one = copy("/made-up/a/one/skills/\(name)", hash: "aaaa")
    let two = copy("/made-up/a/two/\(name)", hash: "bbbb")
    let places: [String: SkillsetFile.Location] = [one.resolved.path: ("https://example.invalid/one", "skills/\(name)"),
      two.resolved.path: ("https://example.invalid/two.git", name)]
    let skill = Skill(name: name, description: "", copies: [one, two])
    let preferences = SourcePreferences(byTool: [name: [.claude: one.resolved.path, .codex: two.resolved.path]],
      skipped: [name: [.gemini]])

    let export = SkillsetFile.export(Skillset(name: "Fixture", skills: [name]), skills: [skill], preferences: preferences) { places[$0.resolved.path] }

    #expect(export.unwritten.isEmpty)
    let member = try #require(SkillsetFile.decode(export.file.encoded()).skills.first)
    #expect(member.agents == [
      "claude": .init(source: "https://example.invalid/one", path: "skills/\(name)", contentHash: "aaaa"),
      "codex": .init(source: "https://example.invalid/two.git", path: name, contentHash: "bbbb"),
    ])
    #expect(member.skippedAgents == ["gemini"])

    let elsewhere = copy("/other-mac/stray/\(name)", hash: "bbbb")
    let localOne = copy("/other-mac/one/skills/\(name)", hash: "aaaa")
    let localTwo = copy("/other-mac/two/\(name)", hash: "bbbb")
    let localPlaces: [String: SkillsetFile.Location] = [localOne.resolved.path: ("https://example.invalid/one", "skills/\(name)"),
      localTwo.resolved.path: ("https://example.invalid/two", name)]
    let local = Skill(name: name, description: "", copies: [elsewhere, localOne, localTwo])
    var imported = SourcePreferences()
    let unmatched = try SkillsetFile.decode(export.file.encoded()).applyVersionChoices(to: &imported, skills: [local]) { localPlaces[$0.resolved.path] }

    #expect(unmatched.isEmpty)
    #expect(imported.byTool == [name: [.claude: localOne.resolved.path, .codex: localTwo.resolved.path]])
    #expect(imported.skipped == [name: [.gemini]])
  }

  @Test func aSkillWithoutVersionsWritesNoAgentFields() throws {
    let name = uniqueName()
    let only = copy("/made-up/a/one/\(name)", hash: "aaaa")
    let preferences = SourcePreferences(byTool: [name: [.claude: only.resolved.path]])
    let export = SkillsetFile.export(Skillset(name: "Fixture", skills: [name]), skills: [Skill(name: name, description: "", copies: [only])],
      preferences: preferences) { _ in ("https://example.invalid/one", name) }
    #expect(export.file.skills[0].agents == nil && export.file.skills[0].skippedAgents == nil)
    #expect(!String(decoding: try export.file.encoded(), as: UTF8.self).contains("agents"))
  }

  @Test func anOldFileWithoutAgentFieldsStillLoads() throws {
    let legacy = Data("{\"format\":\"skillscout-skillset\",\"version\":1,\"name\":\"Fixture\",\"skills\":[{\"name\":\"fixture\",\"source\":null}]}".utf8)
    let member = try SkillsetFile.decode(legacy).skills[0]
    #expect(member.agents == nil && member.skippedAgents == nil)
    var preferences = SourcePreferences()
    #expect(try SkillsetFile.decode(legacy).applyVersionChoices(to: &preferences, skills: []).isEmpty)
    #expect(preferences == SourcePreferences())
  }

  @Test func anUnmatchedVersionIsReportedNotApplied() {
    let name = uniqueName()
    let local = Skill(name: name, description: "", copies: [copy("/other-mac/a/\(name)", hash: "aaaa"), copy("/other-mac/b/\(name)", hash: "bbbb")])
    let file = SkillsetFile(name: "Fixture", skills: [.init(name: name, source: nil,
      agents: ["claude": .init(source: "https://example.invalid/one", path: name, contentHash: "cccc"), "nonsense": .init(contentHash: "aaaa")])])
    var preferences = SourcePreferences()

    let unmatched = file.applyVersionChoices(to: &preferences, skills: [local]) { _ in nil }

    #expect(unmatched == ["\(name) for Claude Code: no copy on this Mac has the chosen version, so it wasn't applied.",
      "\(name): unknown agent nonsense, so its version wasn't applied."])
    #expect(preferences == SourcePreferences())
  }

  @Test func exportReportsAChoiceItCouldNotWrite() throws {
    let name = uniqueName()
    let library = copy("/made-up/a/one/\(name)", hash: "aaaa")
    let personal = copy("/made-up/home/.claude/skills/\(name)", hash: "bbbb")
    let skill = Skill(name: name, description: "", copies: [library, personal])
    let preferences = SourcePreferences(byTool: [name: [.claude: personal.resolved.path, .codex: library.resolved.path]])

    let export = SkillsetFile.export(Skillset(name: "Fixture", skills: [name]), skills: [skill], preferences: preferences) {
      $0.resolved.path == library.resolved.path ? ("https://example.invalid/one", name) : nil
    }

    #expect(export.unwritten == ["\(name) for Claude Code: its version is in no Library repository (\(Paths.abbreviate(personal.resolved))), so the file doesn't record it."])
    #expect(export.file.skills[0].agents?.keys.sorted() == ["codex"])
  }
}
