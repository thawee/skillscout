import Foundation
import Testing

@Suite struct SkillDetailInspectionTests {
  @Test func supportingFilesRefreshWithoutChangingMarkdown() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let text = "---\nname: demo\ndescription: Fixture\n---\nBody\n"
    try text.write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    let root = SkillRoot(label: "Fixture", url: folder.deletingLastPathComponent(), kind: .managed, owner: nil, readBy: [.codex])
    let copy = SkillCopy(folder: folder, resolved: folder, root: root, pluginName: nil, isSymlink: false, contentHash: "unchanged", created: .distantPast)
    let skill = Skill(name: "demo", description: "Fixture", copies: [copy])
    let inspector = SkillDetailInspector()
    let before = try await inspector.inspect(SkillDetailRequest(skill: skill, installationSource: copy, revision: 0))
    try "sudo echo changed\n".write(to: folder.appending(path: "check.sh"), atomically: true, encoding: .utf8)
    let after = try await inspector.inspect(SkillDetailRequest(skill: skill, installationSource: copy, revision: 1))
    #expect(before.content == after.content)
    #expect(before.review?.findings.isEmpty == true)
    #expect(after.review?.findings.contains { $0.path == "check.sh" && $0.highRisk } == true)
    #expect(before.request != after.request)
  }

  @Test func personalLintUsesEditableCopyInsteadOfDisplayedPlugin() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func copy(_ name: String, kind: SkillRoot.Kind, text: String) throws -> SkillCopy {
      let directory = folder.appending(path: name)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try text.write(to: directory.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
      let root = SkillRoot(label: "Fixture", url: folder, kind: kind, owner: nil, readBy: [.codex])
      return SkillCopy(folder: directory, resolved: directory, root: root, pluginName: nil, isSymlink: false, contentHash: name, created: .distantPast)
    }
    let plugin = try copy("plugin", kind: .plugin, text: "---\nname: plugin\ndescription: Plugin fixture\n---\n")
    let personal = try copy("personal", kind: .user, text: "Missing frontmatter")
    let skill = Skill(name: "demo", description: "", copies: [plugin, personal])
    let result = try await SkillDetailInspector().inspect(SkillDetailRequest(skill: skill, installationSource: nil, revision: 0))
    #expect(result.description == "Plugin fixture")
    #expect(result.problems == SkillLint.problems(for: skill))
    #expect(!result.problems.isEmpty)
    let selected = try await SkillDetailInspector().inspect(SkillDetailRequest(skill: skill, installationSource: plugin, revision: 0))
    #expect(selected.problems.isEmpty)
  }
}
