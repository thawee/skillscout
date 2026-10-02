import Foundation
import SQLite3

/// Parsers for Gemini CLI, Droid, Pi, Amp and OpenCode chats.
extension PromptLibrary {
  func piActivity(in data: Data, file: TranscriptFile) -> ([Prompt], [SkillUse]) {
    let project = Self.projectName(Self.json(Self.firstLine(data))?["cwd"])
    var prompts: [Prompt] = []
    var uses: [SkillUse] = []

    for line in Self.lines(containing: #""type":"message""#, in: data) {
      guard let object = Self.json(line),
            let message = object["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]]
      else { continue }
      let date = isoDate(object["timestamp"]) ?? file.modified

      switch message["role"] as? String {
      case "user":
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        uses += text.matches(of: /<skill name="[^"]*" location="([^"]+)">/).map {
          SkillUse(tool: .pi, chat: file.chat, project: project, date: date, folder: Self.folder(of: String($0.1)))
        }
        let request = text.replacing(/<skill [^>]*>[\s\S]*?<\/skill>/, with: "")
        append(&prompts, tool: .pi, project: project, date: date, text: request, key: file.chat)
      case "assistant":
        for item in content where item["type"] as? String == "toolCall" {
          uses += Self.skillReferences(tool: item["name"] as? String, input: item["arguments"]).map {
            SkillUse(tool: .pi, chat: file.chat, project: project, date: date, folder: $0)
          }
        }
      default:
        continue
      }
    }
    return (prompts, uses)
  }

  func geminiActivity(in data: Data, file: TranscriptFile) -> ([Prompt], [SkillUse]) {
    guard let chat = Self.json(data), let messages = chat["messages"] as? [[String: Any]] else { return ([], []) }
    let id = chat["sessionId"] as? String ?? file.chat
    var prompts: [Prompt] = []
    var uses: [SkillUse] = []

    for message in messages {
      let date = isoDate(message["timestamp"]) ?? file.modified
      switch message["type"] as? String {
      case "user":
        let parts = (message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
        let text = message["content"] as? String ?? parts?.joined(separator: "\n") ?? ""
        guard !text.hasPrefix("/") else { continue }
        append(&prompts, tool: .gemini, project: file.project, date: date, text: text, key: id)
      case "gemini":
        for call in message["toolCalls"] as? [[String: Any]] ?? [] {
          uses += Self.skillReferences(tool: call["name"] as? String, input: call["args"]).map {
            SkillUse(tool: .gemini, chat: id, project: file.project, date: date, folder: $0)
          }
        }
      default:
        continue
      }
    }
    return (prompts, uses)
  }

  func droidActivity(in data: Data, file: TranscriptFile) -> ([Prompt], [SkillUse]) {
    let meta = Self.json(Self.firstLine(data)) ?? [:]
    let parent = meta["parent"] as? String
    let chat = parent ?? meta["id"] as? String ?? file.chat
    let project = Self.projectName(meta["cwd"])
    var prompts: [Prompt] = []
    var uses: [SkillUse] = []

    for line in Self.lines(containing: #""type":"message""#, in: data) {
      guard let object = Self.json(line), let message = object["message"] as? [String: Any] else { continue }
      let content = message["content"] as? [[String: Any]] ?? []
      let date = isoDate(object["timestamp"]) ?? file.modified

      switch message["role"] as? String {
      case "user" where parent == nil:
        let text = message["content"] as? String ?? content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.hasPrefix("<") else { continue }
        append(&prompts, tool: .droid, project: project, date: date, text: text, key: chat)
      case "assistant":
        for item in content where item["type"] as? String == "tool_use" {
          uses += Self.skillReferences(tool: item["name"] as? String, input: item["input"]).map {
            SkillUse(tool: .droid, chat: chat, project: project, date: date, folder: $0)
          }
        }
      default:
        continue
      }
    }
    return (prompts, uses)
  }

  func ampActivity(in data: Data, file: TranscriptFile) -> ([Prompt], [SkillUse]) {
    guard let thread = Self.json(data), let messages = thread["messages"] as? [[String: Any]] else { return ([], []) }
    let chat = thread["id"] as? String ?? file.chat
    let trees = ((thread["env"] as? [String: Any])?["initial"] as? [String: Any])?["trees"] as? [[String: Any]]
    let project = (trees?.first?["uri"] as? String).flatMap(URL.init(string:))?.lastPathComponent ?? "Unknown"
    var date = (thread["created"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? file.modified
    var prompts: [Prompt] = []
    var uses: [SkillUse] = []

    for message in messages {
      if let sent = (message["meta"] as? [String: Any])?["sentAt"] as? Double {
        date = Date(timeIntervalSince1970: sent / 1000)
      }
      let content = message["content"] as? [[String: Any]] ?? []

      switch message["role"] as? String {
      case "user":
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        append(&prompts, tool: .amp, project: project, date: date, text: text, key: chat)
      case "assistant":
        for item in content where item["type"] as? String == "tool_use" {
          uses += Self.skillReferences(tool: item["name"] as? String, input: item["input"]).map {
            SkillUse(tool: .amp, chat: chat, project: project, date: date, folder: $0)
          }
        }
      default:
        continue
      }
    }
    return (prompts, uses)
  }

  // MARK: - OpenCode

  /// OpenCode keeps chats in SQLite. Size and date cover the write-ahead log, where fresh messages land first.
  func openCodeDatabase() -> (url: URL, size: Int, modified: Date)? {
    let url = Paths.at(".local/share/opencode/opencode.db")
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
    guard let values = try? url.resourceValues(forKeys: keys), let modified = values.contentModificationDate else { return nil }
    let log = try? URL(fileURLWithPath: url.path + "-wal").resourceValues(forKeys: keys)
    return (url, (values.fileSize ?? 0) + (log?.fileSize ?? 0), max(modified, log?.contentModificationDate ?? .distantPast))
  }

  func openCodeActivity(in url: URL, since cutoff: Date) -> ([Prompt], [SkillUse]) {
    var database: OpaquePointer?
    defer { sqlite3_close(database) }
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return ([], []) }
    sqlite3_busy_timeout(database, 2000)

    let sql = """
      SELECT s.id, s.parent_id, s.directory, m.time_created, json_extract(m.data, '$.role'), p.data
      FROM part p
      JOIN message m ON m.id = p.message_id
      JOIN session s ON s.id = m.session_id
      WHERE m.time_created >= ? AND json_extract(p.data, '$.type') IN ('text', 'tool')
      ORDER BY m.time_created
      """
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return ([], []) }
    sqlite3_bind_int64(statement, 1, Int64(cutoff.timeIntervalSince1970 * 1000))

    func text(_ column: Int32) -> String? {
      sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    var prompts: [Prompt] = []
    var uses: [SkillUse] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let session = text(0), let part = text(5).flatMap({ Self.json(Data($0.utf8)) }) else { continue }
      let parent = text(1)
      let chat = parent ?? session
      let project = Self.projectName(text(2))
      let date = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000)

      if part["type"] as? String == "text" {
        guard text(4) == "user", parent == nil, part["synthetic"] as? Bool != true, let body = part["text"] as? String else { continue }
        append(&prompts, tool: .opencode, project: project, date: date, text: body, key: chat)
      } else {
        let input = (part["state"] as? [String: Any])?["input"]
        uses += Self.skillReferences(tool: part["tool"] as? String, input: input).map {
          SkillUse(tool: .opencode, chat: chat, project: project, date: date, folder: $0)
        }
      }
    }
    return (prompts, uses)
  }

  // MARK: - Antigravity

  func antigravityActivity(in data: Data, file: TranscriptFile) -> ([Prompt], [SkillUse]) {
    var prompts: [Prompt] = []
    var uses: [SkillUse] = []
    let project = file.project.isEmpty ? "Unknown" : file.project

    for line in Self.lines(containing: #""step_index""#, in: data) {
      guard let object = Self.json(line) else { continue }
      let date = isoDate(object["created_at"]) ?? file.modified

      if object["type"] as? String == "USER_INPUT", let text = object["content"] as? String {
        let cleanText = text.replacingOccurrences(of: "<USER_REQUEST>\n", with: "")
                            .replacingOccurrences(of: "\n</USER_REQUEST>", with: "")
        append(&prompts, tool: .antigravity, project: project, date: date, text: cleanText, key: file.chat)
      }

      if let toolCalls = object["tool_calls"] as? [[String: Any]] {
        for call in toolCalls {
          if call["name"] as? String == "default_api:view_file", let args = call["arguments"] as? [String: Any], let path = args["AbsolutePath"] as? String, path.hasSuffix("/SKILL.md") {
            uses.append(SkillUse(tool: .antigravity, chat: file.chat, project: project, date: date, folder: Self.folder(of: path)))
          }
        }
      }
    }
    return (prompts, uses)
  }

  // MARK: - GitHub Copilot

  func copilotDatabase() -> (url: URL, size: Int, modified: Date)? {
    let url = Paths.at(".copilot/session-store.db")
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
    guard let values = try? url.resourceValues(forKeys: keys), let modified = values.contentModificationDate else { return nil }
    let log = try? URL(fileURLWithPath: url.path + "-wal").resourceValues(forKeys: keys)
    return (url, (values.fileSize ?? 0) + (log?.fileSize ?? 0), max(modified, log?.contentModificationDate ?? .distantPast))
  }

  func copilotActivity(in url: URL, since cutoff: Date) -> ([Prompt], [SkillUse]) {
    var database: OpaquePointer?
    defer { sqlite3_close(database) }
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return ([], []) }
    sqlite3_busy_timeout(database, 2000)

    let sql = """
      SELECT s.id, s.cwd, t.timestamp, t.user_message, t.assistant_response
      FROM turns t
      JOIN sessions s ON s.id = t.session_id
      WHERE t.timestamp >= datetime(?, 'unixepoch')
      ORDER BY t.timestamp
      """
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return ([], []) }
    sqlite3_bind_int64(statement, 1, Int64(cutoff.timeIntervalSince1970))

    func text(_ column: Int32) -> String? {
      sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    var prompts: [Prompt] = []
    var uses: [SkillUse] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let session = text(0), let userMessage = text(3) else { continue }
      let project = Self.projectName(text(1))
      let date = isoDate(text(2)) ?? Date()

      append(&prompts, tool: .copilot, project: project, date: date, text: userMessage, key: session)

      let paths = Self.readSkillPaths(in: userMessage) + Self.readSkillPaths(in: text(4) ?? "")
      for folder in paths.map({ Self.folder(of: $0) }) {
        uses.append(SkillUse(tool: .copilot, chat: session, project: project, date: date, folder: folder))
      }
    }
    return (prompts, uses)
  }
}
