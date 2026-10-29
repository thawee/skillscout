import Foundation
import Testing

/// `SkillInstaller.moveConfigFolder` against a made-up home, never the real one.
@Suite struct ConfigFolderMoveTests {
  private let fm = FileManager.default

  private func home() throws -> URL {
    // The real path, under /private: a move must keep it as written, like a home under /private/tmp.
    let real = realpath(fm.temporaryDirectory.path, nil)!
    defer { free(real) }
    let folder = URL(fileURLWithPath: String(cString: real)).appending(path: "quartermaster-move-" + UUID().uuidString)
    try fm.createDirectory(at: folder.appending(path: ".config"), withIntermediateDirectories: true)
    try fm.createDirectory(at: folder.appending(path: ".claude/skills"), withIntermediateDirectories: true)
    return folder
  }

  private func skill(_ folder: URL) throws {
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try "---\nname: \(folder.lastPathComponent)\n---\n".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
  }

  private func move(_ home: URL) {
    SkillInstaller.moveConfigFolder(home: home, stateFile: home.appending(path: "state.json"), roots: [home.appending(path: ".claude/skills")])
  }

  private func link(_ url: URL) -> String? { try? fm.destinationOfSymbolicLink(atPath: url.path) }

  @Test func movesTheLibraryRelinksAgentsAndRewritesSavedPaths() throws {
    let home = try home()
    defer { try? fm.removeItem(at: home) }
    let old = home.appending(path: ".config/skillscout"), new = home.appending(path: ".config/quartermaster")
    try skill(old.appending(path: "skills/acme/review"))
    try "[]".write(to: old.appending(path: "custom-registry.json"), atomically: true, encoding: .utf8)
    let agentLink = home.appending(path: ".claude/skills/review")
    try fm.createSymbolicLink(atPath: agentLink.path, withDestinationPath: old.appending(path: "skills/acme/review").path)
    let relative = home.appending(path: ".claude/skills/relative")
    try fm.createSymbolicLink(atPath: relative.path, withDestinationPath: "../../.config/skillscout/skills/acme/review")
    let elsewhere = home.appending(path: ".claude/skills/mine")
    try fm.createSymbolicLink(atPath: elsewhere.path, withDestinationPath: "/somewhere/else/skillscout/mine")
    // A sibling folder whose name starts the same way stays as it is.
    let sibling = old.path + "-old/x"
    let state: [String: Any] = [
      "preferredSources": ["review": old.appending(path: "skills/acme/review").path, "other": sibling],
      "skillsetEntries": [["path": agentLink.path, "linkDestination": old.appending(path: "skills/acme/review").path]],
      "lastAnalysis": 12.5,
    ]
    try JSONSerialization.data(withJSONObject: state).write(to: home.appending(path: "state.json"))

    move(home)

    #expect(link(old) == new.path)
    #expect(link(new) == nil)
    #expect(fm.fileExists(atPath: new.appending(path: "skills/acme/review/SKILL.md").path))
    #expect(fm.fileExists(atPath: new.appending(path: "custom-registry.json").path))
    #expect(link(agentLink) == new.appending(path: "skills/acme/review").path)
    #expect(link(relative) == new.appending(path: "skills/acme/review").path)
    #expect(link(elsewhere) == "/somewhere/else/skillscout/mine")
    #expect(try fm.contentsOfDirectory(atPath: home.appending(path: ".claude/skills").path).sorted() == ["mine", "relative", "review"])
    let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: home.appending(path: "state.json"))) as? [String: Any])
    let sources = try #require(saved["preferredSources"] as? [String: String])
    #expect(sources["review"] == new.appending(path: "skills/acme/review").path)
    #expect(sources["other"] == sibling)
    let entries = try #require(saved["skillsetEntries"] as? [[String: String]])
    #expect(entries.first?["linkDestination"] == new.appending(path: "skills/acme/review").path)
    #expect(entries.first?["path"] == agentLink.path)
    #expect(saved["lastAnalysis"] as? Double == 12.5)

    // A second run changes nothing, and a link an older copy made after the move follows it too.
    let late = home.appending(path: ".claude/skills/late")
    try skill(new.appending(path: "skills/acme/late"))
    try fm.createSymbolicLink(atPath: late.path, withDestinationPath: old.appending(path: "skills/acme/late").path)
    move(home)
    #expect(link(old) == new.path)
    #expect(link(agentLink) == new.appending(path: "skills/acme/review").path)
    #expect(link(late) == new.appending(path: "skills/acme/late").path)
  }

  @Test func leavesAFilledNewFolderAndAMissingOldOneAlone() throws {
    let home = try home()
    defer { try? fm.removeItem(at: home) }
    let old = home.appending(path: ".config/skillscout"), new = home.appending(path: ".config/quartermaster")
    move(home)
    #expect(!fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path))

    try skill(old.appending(path: "skills/a"))
    try skill(new.appending(path: "skills/b"))
    let agentLink = home.appending(path: ".claude/skills/a")
    try fm.createSymbolicLink(atPath: agentLink.path, withDestinationPath: old.appending(path: "skills/a").path)
    move(home)
    #expect(link(old) == nil && fm.fileExists(atPath: old.appending(path: "skills/a/SKILL.md").path))
    #expect(fm.fileExists(atPath: new.appending(path: "skills/b/SKILL.md").path))
    #expect(link(agentLink) == old.appending(path: "skills/a").path)
  }

  @Test func anEmptyNewFolderGivesWay() throws {
    let home = try home()
    defer { try? fm.removeItem(at: home) }
    let old = home.appending(path: ".config/skillscout"), new = home.appending(path: ".config/quartermaster")
    try skill(old.appending(path: "skills/a"))
    try fm.createDirectory(at: new, withIntermediateDirectories: true)
    move(home)
    #expect(link(old) == new.path)
    #expect(fm.fileExists(atPath: new.appending(path: "skills/a/SKILL.md").path))
  }

  @Test func theUsersOwnLinkIsFollowedNotMoved() throws {
    let home = try home()
    defer { try? fm.removeItem(at: home) }
    let old = home.appending(path: ".config/skillscout"), new = home.appending(path: ".config/quartermaster")
    let dotfiles = home.appending(path: "dotfiles/skillscout")
    try skill(dotfiles.appending(path: "skills/a"))
    try fm.createSymbolicLink(atPath: old.path, withDestinationPath: dotfiles.path)
    let agentLink = home.appending(path: ".claude/skills/a")
    try fm.createSymbolicLink(atPath: agentLink.path, withDestinationPath: old.appending(path: "skills/a").path)
    move(home)
    #expect(link(old) == dotfiles.path)
    #expect(link(new) == dotfiles.path)
    #expect(link(agentLink) == old.appending(path: "skills/a").path)
    #expect(fm.fileExists(atPath: new.appending(path: "skills/a/SKILL.md").path))
  }

  @Test func whenTheMoveFailsTheNewPathLinksToTheOldFolder() throws {
    let home = try home()
    let old = home.appending(path: ".config/skillscout"), new = home.appending(path: ".config/quartermaster")
    defer {
      try? fm.setAttributes([.immutable: false], ofItemAtPath: old.path)
      try? fm.removeItem(at: home)
    }
    try skill(old.appending(path: "skills/a"))
    let agentLink = home.appending(path: ".claude/skills/a")
    try fm.createSymbolicLink(atPath: agentLink.path, withDestinationPath: old.appending(path: "skills/a").path)
    // A locked folder can't be renamed.
    try fm.setAttributes([.immutable: true], ofItemAtPath: old.path)
    move(home)
    #expect(link(old) == nil)
    #expect(link(new) == old.path)
    #expect(fm.fileExists(atPath: new.appending(path: "skills/a/SKILL.md").path))
    #expect(link(agentLink) == old.appending(path: "skills/a").path)
  }
}
