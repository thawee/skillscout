import CryptoKit
import Foundation
import SQLite3
import Testing

@Suite struct ProjectUsageTests {
  private let date = Date(timeIntervalSince1970: 1_700_000_000)
  private let folder = "/fixture/skills/demo"

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "skillscout-project-usage-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func parse(_ source: PromptLibrary.Source, _ objects: [[String: Any]], project: String = "", projectPath: String? = nil) async throws -> PromptLibrary.ParsedFile {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "chat.jsonl")
    let lines = try objects.map { try JSONSerialization.data(withJSONObject: $0, options: [.withoutEscapingSlashes]) }
    var data = Data()
    for line in lines { data.append(line); data.append(0x0A) }
    try data.write(to: url)
    let file = PromptLibrary.TranscriptFile(url: url, source: source, chat: "same-chat", project: project,
      size: data.count, modified: date, projectPath: projectPath)
    return await PromptLibrary().parse(file)
  }

  private func call(_ type: String = "tool_use") -> [String: Any] {
    ["type": type, "name": "Read", "input": ["path": folder + "/SKILL.md"]]
  }

  @Test func legacyUsageAndCacheDecodeWithoutProjectPath() throws {
    let data = Data(#"{"tool":"codex","chat":"same-chat","project":"demo","date":0,"folder":"demo"}"#.utf8)
    let use = try JSONDecoder().decode(SkillUse.self, from: data)
    #expect(use.projectPath == nil)
    #expect(use.project == "demo")
    let legacyCache = Data(#"{"size":10,"modified":0,"prompts":[],"uses":[{"tool":"codex","chat":"same-chat","project":"demo","date":0,"folder":"demo"}]}"#.utf8)
    #expect(try JSONDecoder().decode(PromptLibrary.ParsedFile.self, from: legacyCache).uses == [use])
    #expect(try JSONDecoder().decode(SkillUse.self, from: JSONEncoder().encode(use)) == use)
  }

  @Test func identicalChatIDsInSameNamedProjectsStayDistinct() {
    let first = SkillUse(tool: .codex, chat: "same", project: "demo", date: date, folder: folder, projectPath: "/fixture/one/demo")
    let second = SkillUse(tool: .codex, chat: "same", project: "demo", date: date, folder: folder, projectPath: "/fixture/two/demo")
    #expect(Set([RecordedChat(first), RecordedChat(second)]).count == 2)
    #expect(RecordedChat(first) == RecordedChat(first))
    #expect(SkillUse(tool: .codex, chat: "legacy", project: "demo", date: date, folder: folder).projectPath == nil)
  }

  @Test func pathsRequireAbsoluteLocalDirectories() {
    for value in ["demo", "../demo", "./demo", "~/demo", "$HOME/demo", "Unknown", "", "https://example.com/demo", "file://remote.example/demo", "file:demo"] {
      #expect(PromptLibrary.projectPath(value) == nil, "Accepted ambiguous path \(value)")
    }
    #expect(PromptLibrary.projectPath(nil) == nil)
    #expect(PromptLibrary.projectPath("/fixture/one/../demo/") == "/fixture/demo")
    #expect(PromptLibrary.projectPath("file:///fixture/a%20project") == "/fixture/a project")
    #expect(PromptLibrary.projectPath("file://localhost/fixture/demo") == "/fixture/demo")
  }

  @Test func pathsResolveExistingDirectoryLinks() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appending(path: "actual")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let link = directory.appending(path: "linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(PromptLibrary.projectPath(link.path) == target.resolvingSymlinksInPath().path)
  }

  @Test func codexRetainsCWDAndExistingPromptBehavior() async throws {
    let result = try await parse(.codex, [
      ["type": "session_meta", "payload": ["cwd": "/fixture/one/../demo", "source": "cli"]],
      ["type": "response_item", "payload": ["type": "function_call", "arguments": "cat \(folder)/SKILL.md"]],
      ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["text": "Please implement project-local skill management."]]]],
    ])
    #expect(result.uses.count == 1)
    #expect(result.uses.first?.projectPath == "/fixture/demo")
    #expect(result.uses.first?.project == "demo")
    #expect(result.uses.first?.folder == folder)
    #expect(result.prompts.first?.project == "demo")
    #expect(result.prompts.count == 1)
    let child = try await parse(.codex, [
      ["type": "session_meta", "payload": ["cwd": "/fixture/demo", "parent_thread_id": "parent"]],
      ["type": "response_item", "payload": ["type": "function_call", "arguments": "cat \(folder)/SKILL.md"]],
    ])
    #expect(child.uses.isEmpty)
  }

  @Test func claudeRetainsWorkingDirectoryForEachUse() async throws {
    let result = try await parse(.claude, [
      ["type": "assistant", "cwd": "/fixture/one/demo", "sessionId": "same", "message": ["content": [call()]]],
      ["type": "assistant", "cwd": "/fixture/two/demo", "sessionId": "same", "message": ["content": [call()]]],
    ])
    #expect(result.uses.map(\.projectPath) == ["/fixture/one/demo", "/fixture/two/demo"])
    #expect(Set(result.uses.map(RecordedChat.init)).count == 2)
    #expect(result.uses.allSatisfy { $0.project == "demo" && $0.chat == "same" })
  }

  @Test func piSupportsCurrentAndInitialWorkingDirectory() async throws {
    for key in ["cwd", "initialcwd"] {
      let result = try await parse(.pi, [
        ["type": "session", key: "/fixture/demo"],
        ["type": "message", "message": ["role": "assistant", "content": [["type": "toolCall", "name": "Read", "arguments": ["path": folder + "/SKILL.md"]]]]],
        ["type": "message", "message": ["role": "user", "content": [["text": "<skill name=\"demo\" location=\"\(folder)/SKILL.md\">Skill text</skill>\nPlease review this project carefully."]]]],
      ])
      #expect(result.uses.count == 2)
      #expect(result.uses.allSatisfy { $0.projectPath == "/fixture/demo" && $0.project == "demo" })
      #expect(result.prompts.first?.text == "Please review this project carefully.")
    }
  }

  @Test func droidChildUsageKeepsParentIdentityAndCWD() async throws {
    let result = try await parse(.droid, [
      ["type": "session", "cwd": "/fixture/demo", "id": "child", "parent": "parent"],
      ["type": "message", "message": ["role": "assistant", "content": [call()]]],
      ["type": "message", "message": ["role": "user", "content": "This child prompt must remain excluded."]],
    ])
    #expect(result.uses.first?.projectPath == "/fixture/demo")
    #expect(result.uses.first?.chat == "parent")
    #expect(result.prompts.isEmpty)
  }

  @Test func ampKeepsFirstTreeLocalPath() async throws {
    for uri in ["file:///fixture/a%20project", "/fixture/a project"] {
      let result = try await parse(.amp, [[
        "id": "thread", "env": ["initial": ["trees": [["uri": uri], ["uri": "file:///fixture/second"]]]],
        "messages": [["role": "assistant", "content": [call()]]],
      ]])
      #expect(result.uses.first?.projectPath == "/fixture/a project")
      #expect(result.uses.first?.project == "a project")
      #expect(result.uses.first?.chat == "thread")
    }
  }

  @Test func relativeEngineMetadataDoesNotInventPaths() async throws {
    let cases: [(PromptLibrary.Source, [[String: Any]])] = [
      (.codex, [["type": "session_meta", "payload": ["cwd": "demo"]], ["type": "response_item", "payload": ["type": "function_call", "arguments": "cat \(folder)/SKILL.md"]]]),
      (.claude, [["type": "assistant", "cwd": "demo", "message": ["content": [call()]]]]),
      (.pi, [["type": "session", "cwd": "demo"], ["type": "message", "message": ["role": "assistant", "content": [["type": "toolCall", "name": "Read", "arguments": ["path": folder + "/SKILL.md"]]]]]]),
      (.droid, [["type": "session", "cwd": "demo"], ["type": "message", "message": ["role": "assistant", "content": [call()]]]]),
      (.amp, [["env": ["initial": ["trees": [["uri": "demo"]]]], "messages": [["role": "assistant", "content": [call()]]]]]),
    ]
    for (source, objects) in cases {
      let result = try await parse(source, objects)
      #expect(result.uses.count == 1)
      #expect(result.uses.first?.projectPath == nil)
    }
  }

  @Test func cursorLabelsAndAntigravityBrainIDsDoNotBecomePaths() async throws {
    let cursor = try await parse(.cursorChat, [["role": "assistant", "message": ["content": [call()]]]], project: "Users-fixture-demo")
    #expect(cursor.uses.count == 1)
    #expect(cursor.uses.first?.project == "Users-fixture-demo")
    #expect(cursor.uses.first?.projectPath == nil)
    let antigravity = try await parse(.antigravity, [["step_index": 1, "tool_calls": [["name": "default_api:view_file", "arguments": ["AbsolutePath": folder + "/SKILL.md"]]]]])
    #expect(antigravity.uses.count == 1)
    #expect(antigravity.uses.first?.projectPath == nil)
  }

  @Test func geminiProjectRootsKeepPathsFromRegistryAndRootFiles() async throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let gemini = home.appending(path: ".gemini")
    try FileManager.default.createDirectory(at: gemini, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["projects": ["/fixture/one/demo": "one", "/fixture/two/demo": "two"]]).write(to: gemini.appending(path: "projects.json"))
    let library = PromptLibrary()
    let hashes = await library.geminiProjectHashes(in: home)
    let hash = SHA256.hash(data: Data("/fixture/one/demo".utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(hashes[hash] == "/fixture/one/demo")
    let project = gemini.appending(path: "tmp/" + hash)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    #expect(await library.geminiProjectRoot(in: project, hashedProjects: hashes) == "/fixture/one/demo")
    try " /fixture/two/demo\n".write(to: project.appending(path: ".project_root"), atomically: true, encoding: .utf8)
    let root = await library.geminiProjectRoot(in: project, hashedProjects: hashes)
    #expect(root == "/fixture/two/demo")
    let object: [String: Any] = ["sessionId": "gemini-chat", "messages": [["type": "gemini", "toolCalls": [["name": "activate_skill", "args": ["name": "demo"]]]]]]
    let result = try await parse(.gemini, [object], project: PromptLibrary.projectName(root), projectPath: PromptLibrary.projectPath(root))
    #expect(result.uses.first?.projectPath == "/fixture/two/demo")
    #expect(result.projectPath == "/fixture/two/demo")
    #expect(try JSONDecoder().decode(PromptLibrary.ParsedFile.self, from: JSONEncoder().encode(result)).projectPath == "/fixture/two/demo")
    #expect(result.uses.first?.project == "demo")
    let unknown = try await parse(.gemini, [object], project: "Unknown")
    #expect(unknown.uses.first?.projectPath == nil)
  }

  @Test func databaseEnginesRetainAbsolutePathsAndRejectRelativeMetadata() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "sessions.db")
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    let sql = """
      CREATE TABLE session(id TEXT, parent_id TEXT, directory TEXT);
      CREATE TABLE message(id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
      CREATE TABLE part(message_id TEXT, data TEXT);
      CREATE TABLE sessions(id TEXT, cwd TEXT);
      CREATE TABLE turns(session_id TEXT, timestamp TEXT, user_message TEXT, assistant_response TEXT);
      INSERT INTO session VALUES('absolute', NULL, '/fixture/demo'), ('relative', NULL, 'demo');
      INSERT INTO message VALUES('one', 'absolute', 1700000000000, '{"role":"assistant"}'), ('two', 'relative', 1700000000000, '{"role":"assistant"}');
      INSERT INTO part VALUES('one', '{"type":"tool","tool":"skill","state":{"input":{"name":"demo"}}}'), ('two', '{"type":"tool","tool":"skill","state":{"input":{"name":"demo"}}}');
      INSERT INTO sessions VALUES('absolute', '/fixture/demo'), ('relative', 'demo');
      INSERT INTO turns VALUES('absolute', '2023-11-14T22:13:20Z', 'Please review this implementation carefully.', 'cat /fixture/skills/demo/SKILL.md'), ('relative', '2023-11-14T22:13:20Z', 'Please review this implementation carefully.', 'cat /fixture/skills/demo/SKILL.md');
      """
    #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    let library = PromptLibrary()
    let openCode = await library.openCodeActivity(in: url, since: .distantPast)
    let copilot = await library.copilotActivity(in: url, since: .distantPast)
    for uses in [openCode.1, copilot.1] {
      #expect(uses.count == 2)
      #expect(uses.first { $0.chat == "absolute" }?.projectPath == "/fixture/demo")
      #expect(uses.first { $0.chat == "relative" }?.projectPath == nil)
      #expect(uses.allSatisfy { $0.project == "demo" && ($0.folder == "demo" || $0.folder == folder) })
    }
    #expect(copilot.0.count == 2)
  }
}
