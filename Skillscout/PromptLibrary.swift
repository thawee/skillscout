import CryptoKit
import Foundation

actor PromptLibrary {
  static let marker = "SKILLSCOUT_TASK"

  private static let cursorNotices = [
    "Perform any necessary follow-up actions in response to the subagent completion",
    "Briefly inform the user about the task result",
  ]

  enum Source { case cursorChat, cursorSubagent, codex, claude, gemini, antigravity, droid, pi, amp }

  struct TranscriptFile {
    let url: URL
    let source: Source
    let chat: String
    let project: String
    let size: Int
    let modified: Date
  }

  struct ParsedFile: Codable {
    let size: Int
    let modified: Date
    var prompts: [Prompt] = []
    var uses: [SkillUse] = []
  }

  private struct CacheFile: Codable {
    var version: Int
    var files: [String: ParsedFile]
  }

  /// Bump when a parser changes, so cached results from the old one get parsed again.
  private static let cacheVersion = 2
  private let cacheFile = Paths.appSupport.appending(path: "chats-cache.json")
  private var cache: [String: ParsedFile] = [:]
  private var cacheLoaded = false

  private let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private let plainISOFormatter = ISO8601DateFormatter()

  private let cursorFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEEE, MMM d, yyyy, h:mm a"
    return formatter
  }()

  func load(lookbackDays: Int) -> (prompts: [Prompt], uses: [SkillUse]) {
    let cutoff = Date().addingTimeInterval(-Double(lookbackDays) * 86_400)
    var prompts: [Prompt] = []
    var uses: [SkillUse] = []
    var livePaths = Set<String>()
    var changed = false
    loadCache()

    for file in transcriptFiles(since: cutoff) {
      livePaths.insert(file.url.path)
      var parsed = cache[file.url.path]
      if parsed?.size != file.size || parsed?.modified != file.modified {
        parsed = parse(file)
        cache[file.url.path] = parsed
        changed = true
      }
      prompts += parsed?.prompts ?? []
      uses += parsed?.uses ?? []
    }

    if let database = openCodeDatabase() {
      let key = "\(database.url.path)#\(lookbackDays)"
      livePaths.insert(key)
      var parsed = cache[key]
      if parsed?.size != database.size || parsed?.modified != database.modified {
        parsed = ParsedFile(size: database.size, modified: database.modified)
        (parsed!.prompts, parsed!.uses) = openCodeActivity(in: database.url, since: cutoff)
        cache[key] = parsed
        changed = true
      }
      prompts += parsed?.prompts ?? []
      uses += parsed?.uses ?? []
    }

    if let database = copilotDatabase() {
      let key = "\(database.url.path)#\(lookbackDays)"
      livePaths.insert(key)
      var parsed = cache[key]
      if parsed?.size != database.size || parsed?.modified != database.modified {
        parsed = ParsedFile(size: database.size, modified: database.modified)
        (parsed!.prompts, parsed!.uses) = copilotActivity(in: database.url, since: cutoff)
        cache[key] = parsed
        changed = true
      }
      prompts += parsed?.prompts ?? []
      uses += parsed?.uses ?? []
    }
    // The app and the CLI share this cache with different windows, so keep anything from the last 180 days.
    let keepSince = Date().addingTimeInterval(-Double(max(lookbackDays, 180)) * 86_400)
    let kept = cache.filter { livePaths.contains($0.key) || $0.value.modified >= keepSince }
    if changed || kept.count != cache.count {
      cache = kept
      saveCache()
    }
    prompts += claudePrompts()

    var seen = Set<String>()
    return (
      prompts.filter { $0.date >= cutoff && seen.insert($0.id).inserted }.sorted { $0.date > $1.date },
      uses.filter { $0.date >= cutoff }
    )
  }

  private func loadCache() {
    guard !cacheLoaded else { return }
    cacheLoaded = true
    guard let data = try? Data(contentsOf: cacheFile),
          let saved = try? JSONDecoder().decode(CacheFile.self, from: data),
          saved.version == Self.cacheVersion
    else { return }
    cache = saved.files
  }

  private func saveCache() {
    guard let data = try? JSONEncoder().encode(CacheFile(version: Self.cacheVersion, files: cache)) else { return }
    try? data.write(to: cacheFile, options: .atomic)
  }

  // MARK: - Finding files

  private func transcriptFiles(since cutoff: Date) -> [TranscriptFile] {
    let fm = FileManager.default
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
    var files: [TranscriptFile] = []

    func add(_ url: URL, _ source: Source, chat: String, project: String = "", fileExtension: String = "jsonl") {
      guard url.pathExtension == fileExtension,
            let values = try? url.resourceValues(forKeys: keys),
            let modified = values.contentModificationDate,
            modified >= cutoff
      else { return }
      files.append(TranscriptFile(url: url, source: source, chat: chat, project: project, size: values.fileSize ?? 0, modified: modified))
    }

    func contents(_ url: URL) -> [URL] {
      (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))) ?? []
    }

    let temporaryPrefixes = ["var-folders-", "private-var-folders-", "tmp-", "private-tmp-"]
    for project in contents(Paths.at(".cursor/projects")) where !temporaryPrefixes.contains(where: project.lastPathComponent.hasPrefix) {
      let name = cursorProjectName(project.lastPathComponent)
      for chat in contents(project.appending(path: "agent-transcripts")) {
        if chat.pathExtension == "jsonl" {
          add(chat, .cursorChat, chat: chat.deletingPathExtension().lastPathComponent, project: name)
          continue
        }
        for file in contents(chat) {
          add(file, .cursorChat, chat: chat.lastPathComponent, project: name)
        }
        for file in contents(chat.appending(path: "subagents")) {
          add(file, .cursorSubagent, chat: chat.lastPathComponent, project: name)
        }
      }
    }

    for folder in [".codex/sessions", ".codex/archived_sessions", ".claude/projects"] {
      guard let enumerator = fm.enumerator(at: Paths.at(folder), includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { continue }
      for case let url as URL in enumerator {
        add(url, folder.hasPrefix(".claude") ? .claude : .codex, chat: url.deletingPathExtension().lastPathComponent)
      }
    }

    for (folder, source) in [(".pi/agent/sessions", Source.pi), (".factory/sessions", Source.droid)] {
      for project in contents(Paths.at(folder)) {
        for file in contents(project) {
          add(file, source, chat: file.deletingPathExtension().lastPathComponent)
        }
      }
    }

    let hashedGeminiProjects = geminiProjectHashes()
    for project in contents(Paths.at(".gemini/tmp")) {
      let root = try? String(contentsOf: project.appending(path: ".project_root"), encoding: .utf8)
      let name = root.map { Self.projectName($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        ?? hashedGeminiProjects[project.lastPathComponent] ?? "Unknown"
      for file in contents(project.appending(path: "chats")) {
        add(file, .gemini, chat: file.deletingPathExtension().lastPathComponent, project: name, fileExtension: "json")
      }
    }

    for file in contents(Paths.at(".local/share/amp/threads")) {
      add(file, .amp, chat: file.deletingPathExtension().lastPathComponent, fileExtension: "json")
    }

    for project in contents(Paths.at(".gemini/antigravity-cli/brain")) {
      let file = project.appending(path: ".system_generated/logs/transcript.jsonl")
      add(file, .antigravity, chat: project.lastPathComponent)
    }

    return files
  }

  /// Older Gemini CLI versions name each project folder after the SHA-256 of its path.
  private func geminiProjectHashes() -> [String: String] {
    let known = (try? Data(contentsOf: Paths.at(".gemini/projects.json"))).flatMap { Self.json($0)?["projects"] as? [String: Any] }
    let paths = (known.map { Array($0.keys) } ?? []) + [Paths.home.path]
    return Dictionary(paths.map { path in
      (SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined(), Self.projectName(path))
    }, uniquingKeysWith: { first, _ in first })
  }

  private func cursorProjectName(_ folder: String) -> String {
    let prefix = "Users-\(Paths.home.lastPathComponent)-"
    if folder.hasPrefix(prefix) { return String(folder.dropFirst(prefix.count)) }
    if folder.allSatisfy(\.isNumber) || folder == "empty-window" { return "No folder" }
    return folder
  }

  // MARK: - Parsing

  private func parse(_ file: TranscriptFile) -> ParsedFile {
    var parsed = ParsedFile(size: file.size, modified: file.modified)
    guard let data = try? Data(contentsOf: file.url, options: .alwaysMapped) else { return parsed }

    switch file.source {
    case .cursorChat:
      parsed.prompts = cursorPrompts(in: data, file: file)
      parsed.uses = cursorUses(in: data, file: file)
    case .cursorSubagent:
      parsed.uses = cursorUses(in: data, file: file)
    case .codex:
      (parsed.prompts, parsed.uses) = codexActivity(in: data, file: file)
    case .claude:
      parsed.uses = claudeUses(in: data, file: file)
    case .gemini:
      (parsed.prompts, parsed.uses) = geminiActivity(in: data, file: file)
    case .antigravity:
      (parsed.prompts, parsed.uses) = antigravityActivity(in: data, file: file)
    case .droid:
      (parsed.prompts, parsed.uses) = droidActivity(in: data, file: file)
    case .pi:
      (parsed.prompts, parsed.uses) = piActivity(in: data, file: file)
    case .amp:
      (parsed.prompts, parsed.uses) = ampActivity(in: data, file: file)
    }
    return parsed
  }

  private func cursorPrompts(in data: Data, file: TranscriptFile) -> [Prompt] {
    var prompts: [Prompt] = []
    var seenInChat = Set<String>()

    for (index, line) in Self.lines(containing: #""role":"user""#, in: data).enumerated() {
      guard let object = Self.json(line),
            let message = object["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]]
      else { continue }

      let raw = content
        .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        .joined(separator: "\n")
      guard let text = Self.tag("user_query", in: raw) ?? (raw.hasPrefix("<") ? nil : raw),
            !Self.cursorNotices.contains(where: text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix),
            seenInChat.insert(text).inserted
      else { continue }
      let stamp = Self.tag("timestamp", in: raw)
      let date = stamp.flatMap(cursorDate(from:)) ?? file.modified
      let key = stamp.map { "\(file.project)#\($0)" } ?? "\(file.url.path)#\(index)"
      append(&prompts, tool: .cursor, project: file.project, date: date, text: text, key: key)
    }
    return prompts
  }

  private func cursorUses(in data: Data, file: TranscriptFile) -> [SkillUse] {
    var paths: [String] = []
    for line in Self.lines(containing: "SKILL.md", in: data) {
      guard Self.contains(line, #""name":"Read""#) || Self.contains(line, "<manually_attached_skills>"),
            let object = Self.json(line),
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]]
      else { continue }
      let role = object["role"] as? String

      for item in content {
        if role == "assistant", item["type"] as? String == "tool_use", item["name"] as? String == "Read",
           let path = (item["input"] as? [String: Any])?["path"] as? String, path.hasSuffix("/SKILL.md") {
          paths.append(path)
        } else if role == "user", let text = item["text"] as? String, text.contains("<manually_attached_skills>") {
          paths += text.matches(of: /Skill Name: [^\n]*\nPath: ([^\n]+\/SKILL\.md)/).map { String($0.1) }
        }
      }
    }
    return paths.map {
      SkillUse(tool: .cursor, chat: file.chat, project: file.project, date: file.modified, folder: Self.folder(of: $0))
    }
  }

  private func codexActivity(in data: Data, file: TranscriptFile) -> ([Prompt], [SkillUse]) {
    let firstLine = data.firstIndex(of: 0x0A).map { data[data.startIndex..<$0] } ?? data
    let meta = (Self.json(Data(firstLine))?["payload"] as? [String: Any]) ?? [:]
    let isChildThread = meta["parent_thread_id"] != nil || meta["source"] is [String: Any]
    if isChildThread || meta["source"] as? String == "exec" || meta["thread_source"] as? String == "subagent" {
      return ([], [])
    }
    let project = (meta["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown"

    var prompts: [Prompt] = []
    for line in Self.lines(containing: #""role":"user""#, in: data) {
      guard let object = Self.json(line),
            object["type"] as? String == "response_item",
            let payload = object["payload"] as? [String: Any],
            payload["type"] as? String == "message",
            let content = payload["content"] as? [[String: Any]]
      else { continue }

      let date = (object["timestamp"] as? String).flatMap(isoFormatter.date(from:)) ?? file.modified
      for item in content {
        guard let raw = item["text"] as? String, let text = Self.codexRequest(from: raw) else { continue }
        append(&prompts, tool: .codex, project: project, date: date, text: text, key: "\(date.timeIntervalSince1970)")
      }
    }

    var uses: [SkillUse] = []
    for line in Self.lines(containing: "SKILL.md", in: data) {
      guard Self.contains(line, #""type":"response_item""#),
            Self.contains(line, #"_call""#) || Self.contains(line, "<skill>"),
            let object = Self.json(line),
            object["type"] as? String == "response_item",
            let payload = object["payload"] as? [String: Any]
      else { continue }

      var paths: [String] = []
      switch payload["type"] as? String {
      case "message" where payload["role"] as? String == "user":
        for item in payload["content"] as? [[String: Any]] ?? [] {
          guard let text = item["text"] as? String else { continue }
          paths += text.matches(of: /<skill>\s*<name>[^<]*<\/name>\s*<path>([^<]+)<\/path>/).map { String($0.1) }
        }
      case "function_call", "custom_tool_call", "local_shell_call":
        let shellCommand = ((payload["action"] as? [String: Any])?["command"] as? [String])?.joined(separator: " ")
        let command = payload["arguments"] as? String ?? payload["input"] as? String ?? shellCommand ?? ""
        paths += Self.readSkillPaths(in: command)
      default:
        continue
      }

      let date = (object["timestamp"] as? String).flatMap(isoFormatter.date(from:)) ?? file.modified
      uses += paths.map { SkillUse(tool: .codex, chat: file.chat, project: project, date: date, folder: Self.folder(of: $0)) }
    }
    return (prompts, uses)
  }

  private func claudePrompts() -> [Prompt] {
    guard let content = try? String(contentsOf: Paths.at(".claude/history.jsonl"), encoding: .utf8) else { return [] }
    var prompts: [Prompt] = []

    for line in content.split(separator: "\n") {
      guard let object = Self.json(Data(line.utf8)),
            let text = object["display"] as? String,
            !text.hasPrefix("/"),
            let milliseconds = object["timestamp"] as? Double
      else { continue }
      let project = (object["project"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown"
      let date = Date(timeIntervalSince1970: milliseconds / 1000)
      append(&prompts, tool: .claude, project: project, date: date, text: text, key: "\(milliseconds)")
    }
    return prompts
  }

  private func claudeUses(in data: Data, file: TranscriptFile) -> [SkillUse] {
    var uses: [SkillUse] = []
    for needle in [#""name":"Skill""#, "SKILL.md", "<command-name>/"] {
      for line in Self.lines(containing: needle, in: data) {
        guard let object = Self.json(line), let message = object["message"] as? [String: Any] else { continue }

        var folders: [String] = []
        switch object["type"] as? String {
        case "assistant":
          for item in message["content"] as? [[String: Any]] ?? [] where item["type"] as? String == "tool_use" {
            folders += Self.skillReferences(tool: item["name"] as? String, input: item["input"])
          }
        case "user":
          let parts = (message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
          let text = message["content"] as? String ?? parts?.joined(separator: "\n") ?? ""
          if let command = Self.tag("command-name", in: text), command.hasPrefix("/") {
            folders.append(Self.skillName(String(command.dropFirst())))
          }
        default:
          continue
        }

        let date = (object["timestamp"] as? String).flatMap(isoFormatter.date(from:)) ?? file.modified
        let chat = object["sessionId"] as? String ?? file.chat
        let project = (object["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown"
        uses += folders.filter { !$0.isEmpty }.map { SkillUse(tool: .claude, chat: chat, project: project, date: date, folder: $0) }
      }
    }
    return uses
  }

  func append(_ prompts: inout [Prompt], tool: Tool, project: String, date: Date, text raw: String, key: String) {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count >= 20, !text.contains(Self.marker) else { return }
    let id = shortHash("\(tool.rawValue)|\(key)|\(text)")
    prompts.append(Prompt(id: id, tool: tool, project: project, date: date, text: String(text.prefix(2000))))
  }

  // MARK: - Helpers

  func isoDate(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    return isoFormatter.date(from: string) ?? plainISOFormatter.date(from: string)
  }

  private static let skillTools: Set<String> = ["skill", "load_skill", "activate_skill", "use_skill"]
  private static let readTools: Set<String> = ["read", "read_file", "readfile", "view", "view_file"]

  /// Skills a tool call loads: a skill tool names one, a read tool opens its SKILL.md, or a shell command prints it.
  /// Returns skill folders, or bare names when the tool only logs the name.
  static func skillReferences(tool: String?, input: Any?) -> [String] {
    let tool = tool?.lowercased() ?? ""
    let input = input as? [String: Any] ?? [:]

    if skillTools.contains(tool) {
      let name = (input["name"] ?? input["skill"] ?? input["skill_name"] ?? input["command"]) as? String
      return name.map { [skillName($0)] }?.filter { !$0.isEmpty } ?? []
    }
    if readTools.contains(tool) {
      let path = ["path", "file_path", "filePath", "absolute_path"].lazy.compactMap { input[$0] as? String }.first
      guard let path, path.hasSuffix("/SKILL.md") else { return [] }
      return [folder(of: path)]
    }
    let command = (input["command"] ?? input["cmd"]) as? String
    return command.map { readSkillPaths(in: $0).map(folder(of:)) } ?? []
  }

  static func firstLine(_ data: Data) -> Data {
    Data(data.firstIndex(of: 0x0A).map { data[data.startIndex..<$0] } ?? data)
  }

  static func projectName(_ path: Any?) -> String {
    (path as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown"
  }

  private nonisolated(unsafe) static let commandSeparator = /&&|\|\||\\n|[;|\n]/
  private nonisolated(unsafe) static let readCommand = /(?:^|[\s"'({])(?:cat|sed|head|tail|nl|less|bat)\s/
  private nonisolated(unsafe) static let skillFilePath = /[^\s'"`\\(){}=,]*\/[A-Za-z0-9._-]+\/SKILL\.md/

  /// Skill files read by `cat`, `sed`, `head` and friends, ignoring commands like `wc` or `cmp` that only touch them.
  static func readSkillPaths(in command: String) -> [String] {
    guard command.contains("SKILL.md") else { return [] }
    return command.split(separator: commandSeparator).flatMap { segment -> [String] in
      guard segment.contains("SKILL.md"), segment.contains(readCommand), !segment.contains("sed -i") else { return [] }
      return segment.matches(of: skillFilePath).map { String($0.output) }
    }
  }

  static func folder(of skillFile: String) -> String {
    var path = skillFile
    if path.hasPrefix("~/") {
      path = Paths.home.path + path.dropFirst(1)
    } else if path.hasPrefix("$HOME/") {
      path = Paths.home.path + path.dropFirst(5)
    }
    return (path as NSString).deletingLastPathComponent
  }

  static func skillName(_ reference: String) -> String {
    String(reference.split(separator: ":").last ?? "")
  }

  static func tag(_ name: String, in raw: String) -> String? {
    guard let start = raw.range(of: "<\(name)>"),
          let end = raw.range(of: "</\(name)>", range: start.upperBound..<raw.endIndex)
    else { return nil }
    return String(raw[start.upperBound..<end.lowerBound])
  }

  private func cursorDate(from stamp: String) -> Date? {
    guard let zoneStart = stamp.range(of: " (UTC") else { return nil }

    let offset = stamp[zoneStart.upperBound...].dropLast()
    let sign: Double = offset.hasPrefix("-") ? -1 : 1
    let parts = offset.dropFirst().split(separator: ":").compactMap { Double($0) }
    let seconds = sign * ((parts.first ?? 0) * 3600 + (parts.dropFirst().first ?? 0) * 60)
    cursorFormatter.timeZone = TimeZone(secondsFromGMT: Int(seconds))
    return cursorFormatter.date(from: String(stamp[..<zoneStart.lowerBound]))
  }

  private static func codexRequest(from raw: String) -> String? {
    if let request = raw.range(of: "## My request for Codex:") {
      return String(raw[request.upperBound...])
    }
    if raw.hasPrefix("<") || raw.hasPrefix("# AGENTS.md") || raw.hasPrefix("# Context from my IDE") {
      return nil
    }
    return raw
  }

  static func json(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  static func contains(_ line: Data, _ needle: String) -> Bool {
    let needle = Array(needle.utf8)
    return line.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return false }
      return memmem(base, buffer.count, needle, needle.count) != nil
    }
  }

  static func lines(containing needle: String, in data: Data) -> [Data] {
    let needle = Array(needle.utf8)
    var lines: [Data] = []

    data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
      guard let base = buffer.baseAddress else { return }
      let count = buffer.count
      var offset = 0

      while offset < count, let hit = memmem(base + offset, count - offset, needle, needle.count) {
        let position = base.distance(to: UnsafeRawPointer(hit))
        var start = position
        while start > 0, buffer[start - 1] != 0x0A { start -= 1 }
        var end = position
        while end < count, buffer[end] != 0x0A { end += 1 }
        lines.append(Data(buffer[start..<end]))
        offset = end + 1
      }
    }
    return lines
  }
}
