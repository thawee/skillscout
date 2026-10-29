import Foundation
import Testing

/// Fixtures sit under the real home's agent folders by path only. Nothing here writes there: the planners are pure,
/// and every name is a fresh UUID so no real skill or link can match.
private func root(_ url: URL) -> SkillRoot { SkillRoot.all.first { $0.url == url }! }
private let library = SkillRoot.all.first { $0.kind == .managed }!
private let shared = SkillRoot.all.first { $0.kind == .shared }!

private func copy(in root: SkillRoot, _ relative: String, hash: String, resolved: URL? = nil) -> SkillCopy {
  let folder = root.url.appending(path: relative)
  return SkillCopy(folder: folder, resolved: resolved ?? folder, root: root, pluginName: nil,
    isSymlink: resolved != nil, contentHash: hash, created: .distantPast)
}

/// Conflicts count only the agents installed on this Mac, so tests pin every agent to stay the same on any machine.
struct AllAgents: SuiteTrait, TestTrait, TestScoping {
  var isRecursive: Bool { true }

  func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
    try await SkillVersions.$agents.withValue(Set(Tool.allCases)) { try await function() }
  }
}

extension Trait where Self == AllAgents {
  static var allAgents: Self { AllAgents() }
}

private func uniqueName() -> String { "versions-" + UUID().uuidString.lowercased() }

private func temporaryFolder() throws -> URL {
  let folder = FileManager.default.temporaryDirectory.appending(path: "skillscout-versions-\(UUID().uuidString)")
    .standardizedFileURL.resolvingSymlinksInPath()
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  return folder
}

private func writeSkill(_ folder: URL, name: String, tools: String? = nil, body: String) throws {
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let supported = tools.map { "supported_tools: \($0)\n" } ?? ""
  try Data("---\nname: \(name)\ndescription: Fixture\n\(supported)---\n\(body)\n".utf8).write(to: folder.appending(path: "SKILL.md"))
}

@Suite(.allAgents) struct SkillVersionConflictTests {
  @Test func aClaudeVersionAndAGenericOneBlockTheAgentThatReadsBoth() {
    let name = uniqueName()
    let claudeVersion = copy(in: library, "acme/claude/\(name)", hash: "aaaa")
    let generic = copy(in: library, "acme/generic/\(name)", hash: "bbbb")
    let installed = copy(in: root(Tool.claude.skillsFolder), name, hash: "aaaa", resolved: claudeVersion.folder)
    let skill = Skill(name: name, description: "", copies: [claudeVersion, generic, installed])
    let assignment = SkillsetAssignment(skillsetID: UUID(), tool: .codex, members: [name])
    let preferences = SourcePreferences(byTool: [name: [.codex: generic.resolved.path]])

    let plan = SkillInstaller.skillsetPlans(tools: [.codex], assignments: [assignment], entries: [], skills: [skill],
      preferences: preferences)[.codex]

    #expect(plan?.additions.isEmpty == true)
    let issue = plan?.issueDetails.first { $0.skillID == name }
    #expect(issue?.message == "\(name): Cursor would see two versions (Cursor also reads ~/.claude/skills).")
    if case .versionConflict(let tool, _) = issue?.reason { #expect(tool == .cursor) } else { Issue.record("no version conflict") }
  }

  @Test func theSameContentOnClaudeAndCursorIsAllowed() {
    let name = uniqueName()
    let source = copy(in: library, "acme/\(name)", hash: "aaaa")
    let skill = Skill(name: name, description: "", copies: [source])
    let id = UUID()
    let assignments = [Tool.claude, .cursor].map { SkillsetAssignment(skillsetID: id, tool: $0, members: [name]) }

    let plans = SkillInstaller.skillsetPlans(tools: [.claude, .cursor], assignments: assignments, entries: [], skills: [skill])

    #expect(plans[.claude]?.additions.map(\.id) == [name])
    #expect(plans[.cursor]?.additions.map(\.id) == [name])
    #expect(plans.values.allSatisfy { $0.issues.isEmpty })
    let planned = [Tool.claude, .cursor].map { PlannedCopy(skillID: name, folder: $0.skillsFolder.appending(path: name), contentHash: "aaaa") }
    #expect(SkillVersions.conflicts(skills: [skill], adding: planned, removing: []).isEmpty)
  }

  @Test func anExistingConflictIsReportedForEveryReaderWithoutBlockingOtherSkills() {
    let name = uniqueName()
    let generic = copy(in: shared, name, hash: "gggg")
    let claudeVersion = copy(in: root(Tool.claude.skillsFolder), name, hash: "cccc")
    let skill = Skill(name: name, description: "", copies: [generic, claudeVersion])

    let existing = SkillVersions.conflicts(skills: [skill], adding: [], removing: [])
    #expect(Set(existing.map(\.tool)) == [.cursor, .opencode])
    #expect(existing.allSatisfy { Set($0.folders) == [generic.folder, claudeVersion.folder] })

    let other = uniqueName()
    let unrelated = Skill(name: other, description: "", copies: [copy(in: library, "acme/\(other)", hash: "oooo")])
    let assignment = SkillsetAssignment(skillsetID: UUID(), tool: .amp, members: [name, other])
    let plan = SkillInstaller.skillsetPlans(tools: [.amp], assignments: [assignment], entries: [], skills: [skill, unrelated],
      preferences: SourcePreferences(byTool: [name: [.amp: generic.resolved.path]]))[.amp]
    #expect(plan?.additions.map(\.id).sorted() == [name, other].sorted())
    #expect(plan?.issues.contains("\(name): Cursor already sees two versions (~/.agents/skills, ~/.claude/skills).") == true)

    let third = PlannedCopy(skillID: name, folder: Tool.cursor.skillsFolder.appending(path: name), contentHash: "tttt")
    #expect(SkillVersions.newConflicts(skills: [skill], adding: [third], removing: []).map(\.tool) == [.cursor])
  }

  @Test func removingOneVersionClearsTheConflict() {
    let name = uniqueName()
    let generic = copy(in: shared, name, hash: "gggg")
    let claudeVersion = copy(in: root(Tool.claude.skillsFolder), name, hash: "cccc")
    let skill = Skill(name: name, description: "", copies: [generic, claudeVersion])
    #expect(SkillVersions.conflicts(skills: [skill], adding: [], removing: [SkillVersions.key(claudeVersion.folder)]).isEmpty)
  }

  @Test func aVersionedSkillWithoutAChoiceAsksForOne() {
    let name = uniqueName()
    let claudeVersion = copy(in: library, "acme/claude/\(name)", hash: "aaaa")
    let generic = copy(in: library, "acme/generic/\(name)", hash: "bbbb")
    let skill = Skill(name: name, description: "", copies: [claudeVersion, generic])
    #expect(SkillVersions.versions(of: skill).count == 2)
    #expect(SkillInstaller.skillsetSource(skill, for: .codex) == nil)
    let preferences = SourcePreferences(byTool: [name: [.codex: generic.resolved.path]])
    #expect(SkillInstaller.skillsetSource(skill, for: .codex, preferences: preferences) == generic)
    #expect(SkillInstaller.skillsetSource(skill, for: .claude, preferences: preferences) == nil)

    let assignment = SkillsetAssignment(skillsetID: UUID(), tool: .claude, members: [name])
    let plan = SkillInstaller.skillsetPlans(tools: [.claude], assignments: [assignment], entries: [], skills: [skill],
      preferences: preferences)[.claude]
    #expect(plan?.additions.isEmpty == true)
    if case .chooseVersions = plan?.issueDetails.first?.reason {} else { Issue.record("expected chooseVersions") }
  }

  @Test func theDeepestRootHoldsAFolder() {
    #expect(SkillRoot.containing(Paths.at(".codex/skills/.system/demo"))?.kind == .builtIn)
    #expect(SkillRoot.containing(Paths.at(".codex/skills/demo"))?.readBy == [.codex, .cursor])
    #expect(SkillRoot.containing(URL(fileURLWithPath: "/made-up/demo")) == nil)
  }
}

@Suite(.allAgents) struct SkillVersionSuggestionTests {
  @Test func supportedToolsNameTheAgents() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let name = uniqueName()
    try writeSkill(folder.appending(path: name), name: name, tools: "[codex, \"gemini\"]", body: "Codex text.")
    let version = SkillCopy(folder: folder.appending(path: name), resolved: folder.appending(path: name), root: library,
      pluginName: nil, isSymlink: false, contentHash: "aaaa", created: .distantPast)
    #expect(SkillVersions.suggestedTools(for: [version]) == [.codex, .gemini])
  }

  @Test func aPathSegmentNamesTheAgent() {
    let name = uniqueName()
    #expect(SkillVersions.suggestedTools(for: [copy(in: library, "acme/claude/\(name)", hash: "a")]) == [.claude])
    #expect(SkillVersions.suggestedTools(for: [copy(in: library, "acme/.claude/skills/\(name)", hash: "a")]) == [.claude])
    // The repository folder is not a hint, even when it is named after an agent.
    #expect(SkillVersions.suggestedTools(for: [copy(in: library, "codex/generic/\(name)", hash: "a")]) == nil)
  }

  @Test func installsSayWhoAVersionIsForWhenNothingElseDoes() {
    let name = uniqueName()
    let managed = copy(in: library, "acme/generic/\(name)", hash: "a")
    let link = copy(in: root(Tool.codex.skillsFolder), name, hash: "a", resolved: managed.folder)
    #expect(SkillVersions.suggestedTools(for: [managed, link]) == [.codex, .cursor])
  }

  @Test func toolsClaimedByTwoVersionsStayUnassigned() throws {
    let name = uniqueName()
    let generic = copy(in: shared, name, hash: "gggg")
    let claudeVersion = copy(in: root(Tool.claude.skillsFolder), name, hash: "cccc")
    let skill = Skill(name: name, description: "", copies: [generic, claudeVersion])
    let versions = SkillVersions.versions(of: skill)
    let g = try #require(versions.firstIndex { $0.first?.contentHash == "gggg" })
    let c = try #require(versions.firstIndex { $0.first?.contentHash == "cccc" })

    let choice = SkillVersions.suggestedChoice(for: skill, tools: [.claude, .codex, .cursor, .opencode], skills: [skill])
    #expect(choice.own == [.claude: c, .codex: g])
    #expect(SkillVersions.choiceProblems(for: skill, choice: choice, skills: [skill]).isEmpty)
  }

  @Test func theOnlyVersionWithoutAHintTakesTheRest() throws {
    let name = uniqueName()
    let claudeVersion = copy(in: library, "acme/claude/\(name)", hash: "aaaa")
    let rest = copy(in: library, "acme/generic/\(name)", hash: "rrrr")
    let skill = Skill(name: name, description: "", copies: [claudeVersion, rest])
    let versions = SkillVersions.versions(of: skill)
    let a = try #require(versions.firstIndex { $0.first?.contentHash == "aaaa" })
    let r = try #require(versions.firstIndex { $0.first?.contentHash == "rrrr" })

    // Cursor reads Claude Code's folder, so it follows Claude Code, and the generic version for Codex would give
    // Cursor two. The weaker fill goes, so the suggestion never opens with a problem.
    let choice = SkillVersions.suggestedChoice(for: skill, tools: [.claude, .codex, .cursor], skills: [skill])
    #expect(choice.own == [.claude: a])
    #expect(SkillVersions.choiceProblems(for: skill, choice: choice, skills: [skill]).isEmpty)
    let resolved = SkillVersions.resolve(choice, tools: [.claude, .codex, .cursor])
    #expect(resolved[.cursor] == Resolution(version: a, follows: [.claude]))
    #expect(resolved[.codex] == Resolution(version: nil, follows: []))
  }

  @Test func aPreferredSourceThatGivesAnAgentTwoVersionsIsNotPrefilled() throws {
    let name = uniqueName()
    let generic = copy(in: library, "acme/generic/\(name)", hash: "gggg")
    let claudeVersion = copy(in: root(Tool.claude.skillsFolder), name, hash: "cccc")
    let skill = Skill(name: name, description: "", copies: [generic, claudeVersion])
    let c = try #require(SkillVersions.versions(of: skill).firstIndex { $0.first?.contentHash == "cccc" })
    let saved = SkillVersions.savedChoice(for: skill, preferences: SourcePreferences(defaults: [name: generic.resolved.path]))
    #expect(!SkillVersions.choiceProblems(for: skill, choice: saved, skills: [skill]).isEmpty)

    let choice = SkillVersions.suggestedChoice(for: skill, tools: [.claude, .codex, .cursor], skills: [skill], keeping: saved)
    #expect(SkillVersions.choiceProblems(for: skill, choice: choice, skills: [skill]).isEmpty)
    #expect(choice.own[.claude] == c && choice.skipped == [.codex])
  }

  @Test func readersOfTheClaudeFolderFollowClaude() throws {
    let name = uniqueName()
    let claudeVersion = copy(in: library, "acme/claude/\(name)", hash: "aaaa")
    let rest = copy(in: library, "acme/generic/\(name)", hash: "rrrr")
    let skill = Skill(name: name, description: "", copies: [claudeVersion, rest])
    let a = try #require(SkillVersions.versions(of: skill).firstIndex { $0.first?.contentHash == "aaaa" })
    let resolved = SkillVersions.resolve(VersionChoice(own: [.claude: a]))
    for tool in Tool.allCases where SkillVersions.reads(tool, .claude) {
      #expect(resolved[tool]?.version == a && resolved[tool]?.follows.contains(.claude) == true)
    }
    #expect(Tool.allCases.contains { SkillVersions.reads($0, .claude) })
    // A follower's own choice can't pull it away from the folder it reads.
    let r = 1 - a
    #expect(SkillVersions.resolve(VersionChoice(own: [.claude: a, .cursor: r]))[.cursor]?.version == a)
  }

  @Test func titlesSayWhatTellsVersionsApart() throws {
    let name = uniqueName()
    let claudeVersion = copy(in: library, "acme/claude/\(name)", hash: "aaaa")
    let rest = copy(in: library, "acme/generic/\(name)", hash: "rrrr")
    let skill = Skill(name: name, description: "", copies: [claudeVersion, rest])
    let versions = SkillVersions.versions(of: skill)
    let titles = SkillVersions.titles(for: skill)
    let a = try #require(versions.firstIndex { $0.first?.contentHash == "aaaa" })
    #expect(titles[a] == "For Claude Code")
    #expect(titles[1 - a] == "generic")
  }

  @Test func aCopyInAnAgentsFolderIsTitledByThatAgent() throws {
    let name = uniqueName()
    let amp = SkillRoot(label: "Amp", url: Paths.at(".config/agents/skills"), kind: .user, owner: .amp, readBy: [.amp])
    let codex = SkillRoot(label: "Codex", url: Paths.at(".codex/skills"), kind: .user, owner: .codex, readBy: [.codex, .cursor])
    let skill = Skill(name: name, description: "", copies: [copy(in: amp, name, hash: "aaaa"), copy(in: codex, name, hash: "cccc")])
    let titles = Set(SkillVersions.titles(for: skill))
    #expect(titles == ["Amp copy", "Codex copy"])
  }
}

@Suite(.allAgents) struct SourcePreferencesStateTests {
  @Test func anOldStateLoadsItsSourcesAsDefaults() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "state.json")
    try JSONSerialization.data(withJSONObject: ["preferredSources": ["review": "/made-up/review"], "suggestions": []]).write(to: file)

    var state = try SkillsetState.load(from: file)
    #expect(state.sourcePreferences == SourcePreferences(defaults: ["review": "/made-up/review"]))

    state.sourcePreferences.byTool["review"] = [.cursor: "/made-up/cursor-review"]
    try state.save(to: file)
    let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect((saved["agentSources"] as? [String: [String: String]])?["review"] == ["cursor": "/made-up/cursor-review"])
    #expect((saved["preferredSources"] as? [String: String]) == ["review": "/made-up/review"])
    #expect(saved["suggestions"] != nil)
    #expect(try SkillsetState.load(from: file).sourcePreferences == state.sourcePreferences)

    state.sourcePreferences.skipped["review"] = [.codex]
    try state.save(to: file)
    let skipping = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect((skipping["skippedAgents"] as? [String: [String]])?["review"] == ["codex"])
    #expect(try SkillsetState.load(from: file).sourcePreferences.skipped == ["review": [.codex]])
  }
}

@Suite(.allAgents) struct RepositoryLinkTests {
  @Test func twoVersionsLinkByTheirSupportedTools() throws {
    let repo = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: repo) }
    let name = uniqueName()
    try writeSkill(repo.appending(path: "claude/\(name)"), name: name, tools: "[claude]", body: "Claude text.")
    try writeSkill(repo.appending(path: "generic/\(name)"), name: name, tools: "[copilot, gemini]", body: "Generic text.")

    let first = SkillInstaller.linkPlan(in: repo, explicitTools: nil, skills: [])
    let second = SkillInstaller.linkPlan(in: repo, explicitTools: nil, skills: [])
    #expect(first.links == second.links && first.skipped == second.skipped)
    #expect(first.skipped.isEmpty)
    let byTool = Dictionary(uniqueKeysWithValues: first.links.map { ($0.tool, $0.target.deletingLastPathComponent().lastPathComponent) })
    #expect(byTool == [.claude: "claude", .copilot: "generic", .gemini: "generic"])
    #expect(first.links.allSatisfy { $0.link == $0.tool.skillsFolder.appending(path: name) })
  }

  @Test func aToolTwoVersionsClaimIsSkippedAndReported() throws {
    let repo = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: repo) }
    let name = uniqueName()
    try writeSkill(repo.appending(path: "a/\(name)"), name: name, tools: "[copilot, gemini]", body: "One.")
    try writeSkill(repo.appending(path: "b/\(name)"), name: name, tools: "[gemini, droid]", body: "Two.")

    let plan = SkillInstaller.linkPlan(in: repo, explicitTools: nil, skills: [])
    #expect(Set(plan.links.map(\.tool)) == [.copilot, .droid])
    #expect(plan.skipped.count == 1)
    #expect(plan.skipped.first?.contains(name) == true && plan.skipped.first?.contains("Gemini CLI") == true)
  }

  @Test func versionsForTwoAgentsAnotherAgentReadsAreBothSkipped() throws {
    let repo = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: repo) }
    let name = uniqueName()
    try writeSkill(repo.appending(path: "claude/\(name)"), name: name, tools: "[claude]", body: "Claude text.")
    try writeSkill(repo.appending(path: "codex/\(name)"), name: name, tools: "[codex]", body: "Codex text.")

    let plan = SkillInstaller.linkPlan(in: repo, explicitTools: nil, skills: [])
    #expect(plan.links.isEmpty)
    #expect(plan.skipped.contains { $0.contains(name) && $0.contains("Cursor") })
  }

  @Test func versionsWithoutSupportedToolsAreNotLinked() throws {
    let repo = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: repo) }
    let name = uniqueName()
    try writeSkill(repo.appending(path: "a/\(name)"), name: name, body: "One.")
    try writeSkill(repo.appending(path: "b/\(name)"), name: name, body: "Two.")

    let plan = SkillInstaller.linkPlan(in: repo, explicitTools: [.amp], skills: [])
    #expect(plan.links.isEmpty)
    #expect(plan.skipped.count == 1 && plan.skipped.first?.contains("Amp") == true)
  }
}

@Suite(.allAgents) struct SingleAddVersionTests {
  @Test func theDestinationIsNamedAfterTheSkill() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let name = uniqueName()
    let source = folder.appending(path: "some-other-folder")
    try writeSkill(source, name: name, body: "Text.")
    let copy = SkillCopy(folder: source, resolved: source, root: library, pluginName: nil, isSymlink: false,
      contentHash: "aaaa", created: .distantPast)
    let skill = Skill(name: name, description: "", copies: [copy])

    guard case .ready(let destination) = try SkillInstaller.addPreview(skill, to: .amp, from: copy) else {
      Issue.record("expected a ready add"); return
    }
    #expect(destination == Tool.amp.skillsFolder.appending(path: SkillInstaller.slug(name)))
  }

  @Test func anAddThatGivesAnAgentTwoVersionsIsRefused() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let name = uniqueName()
    let source = folder.appending(path: name)
    try writeSkill(source, name: name, body: "Generic text.")
    let generic = SkillCopy(folder: source, resolved: source, root: library, pluginName: nil, isSymlink: false,
      contentHash: "gggg", created: .distantPast)
    let claudeVersion = copy(in: root(Tool.claude.skillsFolder), name, hash: "cccc")
    let skill = Skill(name: name, description: "", copies: [generic, claudeVersion])

    guard case .versionConflict(let message) = try SkillInstaller.addPreview(skill, to: .codex, from: generic) else {
      Issue.record("expected a refused add"); return
    }
    #expect(message == "\(name): Cursor would see two versions (Cursor also reads ~/.claude/skills).")
    #expect(throws: (any Error).self) { try SkillInstaller.add(skill, to: .codex, from: generic) }
  }
}

@Suite(.allAgents) struct VersionChoiceTests {
  private func fixture() throws -> (skill: Skill, a: Int, r: Int, paths: (String, String)) {
    let name = uniqueName()
    let claudeVersion = copy(in: library, "acme/claude/\(name)", hash: "aaaa")
    let rest = copy(in: library, "acme/generic/\(name)", hash: "rrrr")
    let skill = Skill(name: name, description: "", copies: [claudeVersion, rest])
    let versions = SkillVersions.versions(of: skill)
    let a = try #require(versions.firstIndex { $0.first?.contentHash == "aaaa" })
    let r = try #require(versions.firstIndex { $0.first?.contentHash == "rrrr" })
    return (skill, a, r, (claudeVersion.resolved.path, rest.resolved.path))
  }

  @Test func versionsForTwoFoldersOneAgentReadsAreAProblemForThatAgentAndTheAgentsThatCauseIt() throws {
    let (skill, a, r, _) = try fixture()
    let problems = SkillVersions.choiceProblems(for: skill, choice: VersionChoice(own: [.claude: a, .codex: r]), skills: [skill])
    let reason = ["\(skill.id): Cursor would see two versions (from ~/.claude/skills, ~/.codex/skills)."]
    #expect(problems == [.cursor: reason, .claude: reason, .codex: reason])
  }

  @Test func oneVersionForEveryReaderIsFine() throws {
    let (skill, a, r, _) = try fixture()
    #expect(SkillVersions.choiceProblems(for: skill, choice: VersionChoice(own: [.claude: a, .codex: a, .amp: r]), skills: [skill]).isEmpty)
  }

  @Test func anAgentsOwnChoiceComesBeforeTheSharedOneAndAStaleChoiceFallsBack() throws {
    let (skill, a, r, paths) = try fixture()
    let preferences = SourcePreferences(defaults: [skill.id: paths.0],
      byTool: [skill.id: [.codex: paths.1, .claude: "/gone/\(skill.id)"]])
    let saved = SkillVersions.savedChoice(for: skill, preferences: preferences)
    #expect(saved == VersionChoice(own: [.codex: r], fallback: a))
    let resolved = SkillVersions.resolve(saved)
    #expect(resolved[.claude]?.version == a && resolved[.amp]?.version == a && resolved[.codex]?.version == r)
    #expect(SkillVersions.savedChoice(for: skill, preferences: SourcePreferences()) == VersionChoice())
  }

  @Test func aSkippedAgentIsReportedAsSkippedNotAsAnIssue() throws {
    let (skill, _, _, paths) = try fixture()
    let preferences = SourcePreferences(byTool: [skill.id: [.claude: paths.0]], skipped: [skill.id: [.codex]])
    #expect(SkillVersions.resolve(SkillVersions.savedChoice(for: skill, preferences: preferences))[.codex]?.version == nil)
    let assignment = SkillsetAssignment(skillsetID: UUID(), tool: .codex, members: [skill.id])
    let plan = try #require(SkillInstaller.skillsetPlans(tools: [.codex], assignments: [assignment], entries: [], skills: [skill],
      preferences: preferences)[.codex])
    #expect(plan.skipped == [skill.id])
    #expect(plan.additions.isEmpty && plan.issueDetails.isEmpty)
  }

  @Test func onlyTheGivenAgentsCountForConflicts() {
    let name = uniqueName()
    let generic = copy(in: shared, name, hash: "gggg")
    let claudeVersion = copy(in: root(Tool.claude.skillsFolder), name, hash: "cccc")
    let skill = Skill(name: name, description: "", copies: [generic, claudeVersion])
    #expect(!SkillVersions.conflicts(skills: [skill], adding: [], removing: []).isEmpty)
    SkillVersions.$agents.withValue([.claude, .codex]) {
      #expect(SkillVersions.conflicts(skills: [skill], adding: [], removing: []).isEmpty)
    }
  }
}
