import Foundation
import Testing

@Suite struct SkillsDirectoryTests {
  private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "skillscout-skills-directory-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  @Test func searchResultsKeepRelevanceOrderAndSkipIncompleteOrRepeatedOnes() throws {
    let reply = """
    {"query":"swiftui","skills":[
      {"id":"expo/skills/expo-ui-swiftui","source":"expo/skills","skillId":"expo-ui-swiftui","name":"Expo UI SwiftUI","installs":12853},
      {"id":"broken","name":"No source"},
      {"id":"avdlee/swiftui-agent-skill/swiftui-expert-skill","source":"avdlee/swiftui-agent-skill","skillId":"swiftui-expert-skill","name":"swiftui-expert-skill","installs":34507},
      {"id":"made/up/new","source":"made/up","skillId":"new","name":"new"},
      {"id":"expo/skills/expo-ui-swiftui","source":"expo/skills","skillId":"expo-ui-swiftui","name":"Expo UI SwiftUI","installs":12853}
    ],"count":5}
    """
    let results = try SkillsDirectory.results(from: Data(reply.utf8))
    #expect(results.map(\.skillId) == ["expo-ui-swiftui", "swiftui-expert-skill", "new"])
    #expect(results[1].repositoryAddress == "https://github.com/avdlee/swiftui-agent-skill")
    #expect(results[0].pageURL?.absoluteString == "https://skills.sh/expo/skills/expo-ui-swiftui")
    #expect(results[2].installs == nil)
    #expect(throws: (any Error).self) { try SkillsDirectory.results(from: Data("{}".utf8)) }
  }

  @Test func searchURLEncodesTheQuery() throws {
    let url = try #require(SkillsDirectory.searchURL("swift ui&x"))
    #expect(url.absoluteString == "https://skills.sh/api/search?q=swift%20ui%26x&limit=50")
  }

  @Test func githubAddressAcceptsOnlyOwnerAndRepo() {
    #expect(SkillsDirectory.githubAddress("vercel-labs/agent-skills") == "https://github.com/vercel-labs/agent-skills")
    #expect(SkillsDirectory.githubAddress("owner/repo/skill") == nil)
    #expect(SkillsDirectory.githubAddress("owner/..") == nil)
    #expect(SkillsDirectory.githubAddress("owner/re po") == nil)
    #expect(SkillsDirectory.githubAddress("https://example.com") == nil)
    #expect(SkillsDirectory.githubAddress("solo") == nil)
  }

  @Test func lockEntriesMapToRepositoryAddresses() throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "project/skills-lock.json")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lock = """
    {"version":3,"skills":{
      "grill-me":{"source":"mattpocock/skills","sourceType":"github","sourceUrl":"https://github.com/mattpocock/skills.git","skillFolderHash":"abc"},
      "short":{"source":"owner/repo","sourceType":"github"},
      "lab":{"source":"group/repo","sourceType":"gitlab","sourceUrl":"https://gitlab.com/group/repo.git"},
      "mine":{"source":"../shared/mine","sourceType":"local"},
      "site":{"source":"example.com","sourceType":"well-known","sourceUrl":"https://example.com/.well-known/skills/site"},
      "bad":{"sourceType":"github"},
      "odd":"text"
    }}
    """
    try lock.write(to: file, atomically: true, encoding: .utf8)
    let entries = SkillsLock.entries(in: file)
    #expect(Set(entries.keys) == ["grill-me", "short", "lab", "mine", "site"])
    #expect(entries["grill-me"]?.repositoryAddress == "https://github.com/mattpocock/skills.git")
    #expect(entries["short"]?.repositoryAddress == "https://github.com/owner/repo")
    #expect(entries["lab"]?.repositoryAddress == "https://gitlab.com/group/repo.git")
    #expect(entries["mine"]?.repositoryAddress == root.appending(path: "shared/mine").standardizedFileURL.path)
    #expect(entries["site"]?.repositoryAddress == nil)
    #expect(entries["grill-me"]?.label == "mattpocock/skills")
  }

  @Test func missingOrBrokenLocksHaveNoEntries() throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    #expect(SkillsLock.entries(in: root.appending(path: "missing.json")).isEmpty)
    let broken = root.appending(path: "broken.json")
    try "{not json".write(to: broken, atomically: true, encoding: .utf8)
    #expect(SkillsLock.entries(in: broken).isEmpty)
  }

  @Test func globalLockFollowsXDGStateHome() {
    let home = URL(fileURLWithPath: "/Users/someone")
    #expect(SkillsLock.globalFile(environment: [:], home: home).path == "/Users/someone/.agents/.skill-lock.json")
    #expect(SkillsLock.globalFile(environment: ["XDG_STATE_HOME": "/tmp/state"], home: home).path == "/tmp/state/skills/.skill-lock.json")
    #expect(SkillsLock.globalFile(environment: ["XDG_STATE_HOME": ""], home: home).path == "/Users/someone/.agents/.skill-lock.json")
  }

  @Test func skillsMatchByNameOrInstallFolderAndOnlyWhenPersonal() {
    let entry = SkillsLockEntry(name: "grill-me", source: "mattpocock/skills", sourceType: "github", sourceURL: nil)
    func skill(_ name: String, folder: String, kind: SkillRoot.Kind) -> Skill {
      let url = URL(fileURLWithPath: "/fixture/.agents/skills/\(folder)")
      let root = SkillRoot(label: "Test", url: url.deletingLastPathComponent(), kind: kind, owner: nil, readBy: [.codex])
      return Skill(name: name, description: "", copies: [SkillCopy(folder: url, resolved: url, root: root, pluginName: nil,
                                                                  isSymlink: false, contentHash: name, created: .distantPast)])
    }
    let entries = ["grill-me": entry]
    #expect(SkillsLock.entry(for: skill("grill-me", folder: "anything", kind: .shared), in: entries) == entry)
    #expect(SkillsLock.entry(for: skill("Grill Me", folder: "grill-me", kind: .user), in: entries) == entry)
    #expect(SkillsLock.entry(for: skill("grill-me", folder: "grill-me", kind: .plugin), in: entries) == nil)
    #expect(SkillsLock.entry(for: skill("other", folder: "other", kind: .shared), in: entries) == nil)
  }
}
