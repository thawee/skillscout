import Foundation
import Testing

@Suite struct ProjectTests {
  private func fixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "skillscout-project-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeSkill(_ name: String, in folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "---\nname: \(name)\ndescription: Project fixture\n---\nFixture body\n".write(
      to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
  }

  private func globalSkill(_ name: String, in folder: URL, readers: Set<Tool>) -> Skill {
    let root = SkillRoot(label: "Fixture", url: folder.deletingLastPathComponent(),
      kind: readers.isEmpty ? .managed : .user, owner: readers.first, readBy: readers)
    return Skill(name: name, description: "Global fixture", copies: [SkillCopy(folder: folder, resolved: folder,
      root: root, pluginName: nil, isSymlink: false, contentHash: "fixture", created: .distantPast)])
  }

  @Test func canonicalRegistrationReusesAliasesAndKeepsSameBasenamesDistinct() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appending(path: "one/project"), second = root.appending(path: "two/project")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let project = try ProjectLibrary.register(first, projects: [])
    let alias = root.appending(path: "alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
    #expect(try ProjectLibrary.register(alias, projects: [project]) == project)
    #expect(try ProjectLibrary.register(first.appending(path: "../project"), projects: [project]) == project)
    let other = try ProjectLibrary.register(second, projects: [project])
    #expect(other.name == project.name)
    #expect(other.id != project.id && other.path != project.path)
  }

  @Test func registrationRejectsGlobalHomeRootAndFiles() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: ProjectLibrary.Failure.self) { try ProjectLibrary.register(Paths.home, projects: []) }
    #expect(throws: ProjectLibrary.Failure.self) { try ProjectLibrary.register(URL(fileURLWithPath: "/"), projects: []) }
    let file = root.appending(path: "file")
    try "fixture".write(to: file, atomically: true, encoding: .utf8)
    #expect(throws: ProjectLibrary.Failure.self) { try ProjectLibrary.register(file, projects: []) }
  }

  @Test func replacementAndMissingProjectDoNotScanNewContent() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "project")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let project = try ProjectLibrary.register(folder, projects: [])
    try FileManager.default.moveItem(at: folder, to: root.appending(path: "original"))
    #expect(ProjectLibrary.status(of: project) == .missing)
    try writeSkill("new", in: folder.appending(path: ".agents/skills/new"))
    #expect(ProjectLibrary.status(of: project) == .replaced)
    #expect(ProjectLibrary.inventory(project: project, globalSkills: []).skills.isEmpty)
    #expect(throws: ProjectLibrary.Failure.self) { try ProjectLibrary.register(folder, projects: [project]) }
  }

  @Test func nativeRootReadersMatchDocumentedProjectLocations() {
    let expected: [String: Set<Tool>] = [
      ".agents/skills": [.codex, .cursor, .copilot, .gemini, .antigravity, .opencode, .droid, .pi, .amp],
      ".claude/skills": [.claude, .cursor, .copilot, .opencode, .amp],
      ".cursor/skills": [.cursor], ".codex/skills": [.cursor], ".github/skills": [.copilot],
      ".gemini/skills": [.gemini], ".agent/skills": [.antigravity, .droid],
      ".opencode/skills": [.opencode], ".factory/skills": [.droid], ".pi/skills": [.pi],
    ]
    #expect(Dictionary(uniqueKeysWithValues: ProjectSkillRoot.all.map { ($0.relativePath, $0.readBy) }) == expected)
    #expect(ProjectSkillTarget.shared.relativePath == ".agents/skills")
    #expect(ProjectSkillTarget.claude.readBy == expected[".claude/skills"])
  }

  @Test func inventorySeparatesGlobalAvailabilityAndPreservesSameNameLocalCopies() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try ProjectLibrary.register(root, projects: [])
    try writeSkill("same", in: root.appending(path: ".agents/skills/first"))
    try writeSkill("same", in: root.appending(path: ".agents/skills/second"))
    try writeSkill("same", in: root.appending(path: ".claude/skills/third"))
    try writeSkill("library-source", in: root.appending(path: ".cursor/skills/local"))
    let globals = [globalSkill("same", in: root.appending(path: "global/same"), readers: [.claude]),
      globalSkill("global-only", in: root.appending(path: "global/only"), readers: [.codex]),
      globalSkill("library-source", in: root.appending(path: "library/source"), readers: []),
      globalSkill("library-only", in: root.appending(path: "library/only"), readers: [])]
    let inventory = ProjectLibrary.inventory(project: project, globalSkills: globals)
    #expect(inventory.status == .available)
    #expect(inventory.skills.map(\.name) == ["global-only", "library-source", "same"])
    let same = try #require(inventory.skills.first { $0.name == "same" })
    #expect(same.localCopies.count == 3)
    #expect(same.localTools == Set(Tool.allCases))
    #expect(same.globalTools == [.claude])
    #expect(same.description == "Project fixture")
    #expect(inventory.skills.first { $0.name == "global-only" }?.localCopies.isEmpty == true)
    #expect(inventory.skills.first { $0.name == "library-source" }?.globalSkill != nil)
    #expect(globals.count == 4 && globals.allSatisfy { $0.copies.count == 1 })
    #expect(globals.first { $0.name == "same" }?.availableIn == [.claude])
  }

  @Test func scannerStaysAtRegisteredRootAndReportsBrokenSkillsAndRoots() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try ProjectLibrary.register(root, projects: [])
    try writeSkill("nested", in: root.appending(path: "child/.agents/skills/nested"))
    try writeSkill("deep", in: root.appending(path: ".agents/skills/group/deep"))
    let invalid = root.appending(path: ".agents/skills/invalid")
    try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
    try Data([0xff, 0xfe, 0x00]).write(to: invalid.appending(path: "SKILL.md"))
    try FileManager.default.createDirectory(at: root.appending(path: ".claude"), withIntermediateDirectories: true)
    try "not a folder".write(to: root.appending(path: ".claude/skills"), atomically: true, encoding: .utf8)
    let inventory = ProjectLibrary.inventory(project: project, globalSkills: [])
    #expect(inventory.skills.isEmpty)
    #expect(inventory.issues.contains { $0.path.hasSuffix("group/SKILL.md") && $0.kind == .missingSkillFile })
    #expect(inventory.issues.contains { $0.path.hasSuffix("invalid/SKILL.md") && $0.kind == .unreadable })
    #expect(inventory.issues.contains { $0.path.hasSuffix(".claude/skills") && $0.kind == .unreadable })
    #expect(inventory.roots.first { $0.root.relativePath == ".cursor/skills" }?.status == .missing)
  }

  @Test func filtersMatchAgentAndScopeOnTheSameSource() {
    let folder = URL(fileURLWithPath: "/fixture/project/.claude/skills/mixed")
    let copy = ProjectSkillCopy(folder: folder, resolved: folder, root: .claude, isSymlink: false, contentHash: "fixture")
    let mixed = ProjectSkillRow(name: "mixed", description: "Fixture", localCopies: [copy],
      globalSkill: globalSkill("mixed", in: URL(fileURLWithPath: "/fixture/global/mixed"), readers: [.codex]))
    #expect(ProjectSkillFilter().matches(mixed))
    #expect(ProjectSkillFilter(tool: .codex).matches(mixed))
    #expect(ProjectSkillFilter(tool: .claude).matches(mixed))
    #expect(!ProjectSkillFilter(tool: .codex, scope: .projectOnly).matches(mixed))
    #expect(ProjectSkillFilter(tool: .claude, scope: .projectOnly).matches(mixed))
    #expect(!ProjectSkillFilter(tool: .pi).matches(mixed))
  }

  @Test func scopeFiltersRequireAvailabilityAndPreserveDualSourceRows() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try ProjectLibrary.register(root, projects: [])
    try writeSkill("mixed", in: root.appending(path: ".claude/skills/mixed"))
    try writeSkill("project-only", in: root.appending(path: ".agents/skills/project-only"))
    let inventory = ProjectLibrary.inventory(project: project, globalSkills: [
      globalSkill("mixed", in: root.appending(path: "global/mixed"), readers: [.codex]),
      globalSkill("global-only", in: root.appending(path: "global/only"), readers: [.codex]),
    ])
    #expect(ProjectSkillFilter().tool == nil)
    #expect(ProjectSkillFilter().scope == .availableHere)
    #expect(inventory.skills.filter(ProjectSkillFilter(scope: .projectOnly).matches).map(\.name) == ["mixed", "project-only"])
    #expect(inventory.skills.filter(ProjectSkillFilter().matches).map(\.name) == ["global-only", "mixed", "project-only"])
    #expect(inventory.skills.filter(ProjectSkillFilter(tool: .codex, scope: .projectOnly).matches).map(\.name) == ["project-only"])
    let mixed = try #require(inventory.skills.first { $0.name == "mixed" })
    let projectOnly = try #require(inventory.skills.first { $0.name == "project-only" })
    let globalOnly = try #require(inventory.skills.first { $0.name == "global-only" })
    #expect(inventory.skills.count { $0.name == "mixed" } == 1)
    #expect(!mixed.localCopies.isEmpty && !mixed.globalTools.isEmpty)
    #expect(ProjectSkillFilter().matches(projectOnly))
    #expect(!ProjectSkillFilter(scope: .projectOnly).matches(globalOnly))
  }

  @Test func symlinkedRootsAndCopiesAreReadWithoutChangingThem() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let projectFolder = root.appending(path: "project")
    try FileManager.default.createDirectory(at: projectFolder.appending(path: ".agents"), withIntermediateDirectories: true)
    let externalRoot = root.appending(path: "external")
    try writeSkill("external", in: externalRoot.appending(path: "one"))
    let linkedRoot = projectFolder.appending(path: ".agents/skills")
    try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: externalRoot)
    let separateCopy = root.appending(path: "separate")
    try writeSkill("linked", in: separateCopy)
    try FileManager.default.createSymbolicLink(at: externalRoot.appending(path: "link"), withDestinationURL: separateCopy)
    let project = try ProjectLibrary.register(projectFolder, projects: [])
    let inventory = ProjectLibrary.inventory(project: project, globalSkills: [])
    #expect(inventory.skills.map(\.name) == ["external", "linked"])
    #expect(inventory.skills.first { $0.name == "linked" }?.localCopies.first?.isSymlink == true)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linkedRoot.path) == externalRoot.path)
  }

  @Test func projectStateDecodesMissingFieldsAndRoundTripsReceiptsAndPendingJournal() throws {
    #expect(try JSONDecoder().decode(ProjectState.self, from: Data("{}".utf8)) == ProjectState())
    #expect(try JSONDecoder().decode(ProjectState.self, from: Data("{\"projects\":[],\"pending\":null}".utf8)) == ProjectState())
    let identity = ProjectDirectoryIdentity(device: 1, inode: 2)
    let project = RegisteredProject(path: "/fixture/project", directoryIdentity: identity)
    let assignment = ProjectSkillsetAssignment(projectID: project.id, skillsetID: UUID(), target: .shared, members: ["fixture"])
    let receipt = ProjectSkillEntry(projectID: project.id, skillID: "fixture", target: .shared,
      path: "/fixture/project/.agents/skills/fixture", sourcePath: "/fixture/source", sourceFingerprint: "source",
      installedFingerprint: "installed", directoryIdentity: identity)
    let step = ProjectPendingStep(skillID: receipt.skillID, operation: .replace, phase: .staged, destinationPath: receipt.path,
      sourcePath: receipt.sourcePath, stagePath: "/fixture/project/.agents/skills/.stage", stageIdentity: identity,
      expectedFingerprint: "next", previousReceipt: receipt, newReceipt: nil, trashPath: nil)
    let journal = ProjectPendingJournal(projectID: project.id, target: .shared,
      previousAssignments: [], proposedAssignments: [assignment], steps: [step])
    let state = ProjectState(projects: [project], assignments: [assignment], entries: [receipt], pending: journal)
    #expect(try JSONDecoder().decode(ProjectState.self, from: JSONEncoder().encode(state)) == state)
    #expect(assignment.individualSkillID == nil)
    #expect(journal.intent == nil)
    let legacyData = try JSONEncoder().encode(state)
    var legacy = try #require(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
    var assignments = try #require(legacy["assignments"] as? [[String: Any]])
    assignments[0].removeValue(forKey: "individualSkillID")
    legacy["assignments"] = assignments
    var pending = try #require(legacy["pending"] as? [String: Any])
    pending.removeValue(forKey: "intent")
    legacy["pending"] = pending
    #expect(try JSONDecoder().decode(ProjectState.self, from: JSONSerialization.data(withJSONObject: legacy)) == state)
    let direct = ProjectSkillsetAssignment(projectID: project.id, skillsetID: UUID(), target: .shared,
      members: ["fixture"], individualSkillID: "fixture")
    var targeted = journal
    targeted.intent = .removeSkill("fixture")
    let updated = ProjectState(projects: [project], assignments: [direct], entries: [receipt], pending: targeted)
    #expect(try JSONDecoder().decode(ProjectState.self, from: JSONEncoder().encode(updated)) == updated)
  }
}
