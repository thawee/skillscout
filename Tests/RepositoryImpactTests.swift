import Foundation
import Testing

struct RepositoryImpactTests {
  @Test func nestedFilesWithArchiveNameRemainTracked() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try skill(root)
    let support = root.appending(path: "support")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let file = support.appending(path: RepositoryLibrary.upstreamMarkerName)
    try Data("Original supporting file".utf8).write(to: file)
    let before = try SkillInstaller.projectFingerprint(root)
    try Data("Local edits".utf8).write(to: file)
    #expect(try SkillInstaller.projectFingerprint(root) != before)
  }

  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "repository-impact-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func skill(_ folder: URL, text: String = "Original") throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "---\nname: fixture\ndescription: Made-up fixture\n---\n\(text)\n"
      .write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
  }

  @Test func linkedReadersComeFromThisSourceRatherThanOtherSameNameCopies() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = root.appending(path: "repository"), source = repository.appending(path: "fixture")
    let unrelated = root.appending(path: "repository-other/fixture")
    try skill(source)
    try skill(unrelated, text: "Different source")
    let link = root.appending(path: "codex/fixture")
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    let libraryRoot = SkillRoot(label: "Library", url: repository, kind: .managed, owner: nil, readBy: [])
    let linkedRoot = SkillRoot(label: "Codex", url: link.deletingLastPathComponent(), kind: .user, owner: .codex, readBy: [.codex])
    let otherRoot = SkillRoot(label: "Claude", url: unrelated.deletingLastPathComponent(), kind: .user, owner: .claude, readBy: [.claude])
    let copies = [
      SkillCopy(folder: source, resolved: source, root: libraryRoot, pluginName: nil, isSymlink: false, contentHash: "one", created: .distantPast),
      SkillCopy(folder: link, resolved: source, root: linkedRoot, pluginName: nil, isSymlink: true, contentHash: "one", created: .distantPast),
      SkillCopy(folder: unrelated, resolved: unrelated, root: otherRoot, pluginName: nil, isSymlink: false, contentHash: "two", created: .distantPast),
    ]
    let skills = [Skill(name: "fixture", description: "Fixture", copies: copies)]
    let impact = RepositoryUpdateImpact.inspect(repository: repository, changedPaths: ["fixture/SKILL.md"],
      skills: skills, skillsets: [Skillset(name: "Example", skills: ["fixture"])], projectState: ProjectState())
    #expect(impact.linked.count == 1)
    #expect(impact.linked.first?.tools == [.codex])
    #expect(impact.linked.first?.willChange == true)
    #expect(impact.otherCopies.first?.tools == [.claude])
    #expect(impact.otherCopies.first?.willChange == false)
    #expect(impact.skillsetNames == ["Example"])
    let unaffected = RepositoryUpdateImpact.inspect(repository: repository, changedPaths: ["README.md"],
      skills: skills, skillsets: [], projectState: ProjectState())
    #expect(unaffected.linked.first?.willChange == false)
  }

  @Test func projectImpactUsesReceiptSourceAndPreservesLocalCopies() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = root.appending(path: "repository"), source = repository.appending(path: "fixture")
    let result = root.appending(path: "result"), next = result.appending(path: "fixture")
    let workspace = root.appending(path: "workspace")
    try skill(source)
    try skill(next, text: "Updated")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let project = RegisteredProject(path: workspace.path, directoryIdentity: try .read(at: workspace))
    let destination = workspace.appending(path: ".agents/skills/fixture")
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: destination)
    let fingerprint = try SkillInstaller.projectFingerprint(destination)
    let entry = ProjectSkillEntry(projectID: project.id, skillID: "fixture", target: .shared, path: destination.path,
      sourcePath: source.path, sourceFingerprint: fingerprint, installedFingerprint: fingerprint,
      directoryIdentity: try .read(at: destination))
    let state = ProjectState(projects: [project], entries: [entry])
    let impact = RepositoryUpdateImpact.inspect(repository: repository, result: result, skills: [], skillsets: [], projectState: state)
    #expect(impact.projects.first?.state == .updateAvailable)
    #expect(try String(contentsOf: destination.appending(path: "SKILL.md"), encoding: .utf8).contains("Original"))
    let unrelated = RepositoryUpdateImpact.inspect(repository: root.appending(path: "repository-other"), result: result,
      skills: [], skillsets: [], projectState: state)
    #expect(unrelated.projects.isEmpty)
    try skill(destination, text: "Personal changes")
    let modified = RepositoryUpdateImpact.inspect(repository: repository, result: result, skills: [], skillsets: [], projectState: state)
    #expect(modified.projects.first?.state == .modified)
    #expect(try String(contentsOf: destination.appending(path: "SKILL.md"), encoding: .utf8).contains("Personal changes"))
  }

  @Test func upstreamArchiveIsNotPartOfPortableSkillContent() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source")
    try skill(source)
    let before = try SkillInstaller.projectFingerprint(source)
    try Data("Made-up archive metadata".utf8).write(to: source.appending(path: RepositoryLibrary.upstreamMarkerName))
    #expect(try SkillInstaller.projectFingerprint(source) == before)
    let workspace = root.appending(path: "workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let project = try ProjectLibrary.register(workspace, projects: [])
    let sourceRoot = SkillRoot(label: "Fixture", url: root, kind: .managed, owner: nil, readBy: [])
    let copy = SkillCopy(folder: source, resolved: source, root: sourceRoot, pluginName: nil,
      isSymlink: false, contentHash: "fixture", created: .distantPast)
    let item = Skill(name: "fixture", description: "Fixture", copies: [copy])
    var state = ProjectState(projects: [project])
    let plan = SkillInstaller.projectSkillsPlan(project: project, state: state, skills: [item],
      skillIDs: [item.id], target: .shared)
    _ = try SkillInstaller.applyProjectPlan(plan, state: &state, persist: { _ in })
    let destination = ProjectSkillTarget.shared.url(in: project).appending(path: "fixture")
    #expect(FileManager.default.fileExists(atPath: destination.appending(path: "SKILL.md").path))
    #expect(!FileManager.default.fileExists(atPath: destination.appending(path: RepositoryLibrary.upstreamMarkerName).path))
  }
}
