import Foundation

enum AIEngineKind: String, CaseIterable, Identifiable, Sendable {
  case codex, claude

  var id: String { rawValue }

  var name: String {
    switch self {
    case .codex: "Codex CLI"
    case .claude: "Claude Code CLI"
    }
  }

  var executable: String {
    switch self {
    case .codex: "codex"
    case .claude: "claude"
    }
  }

  var defaultModel: String {
    switch self {
    case .codex: "gpt-5.6-terra"
    case .claude: "sonnet"
    }
  }

  var modelKey: String { "\(rawValue)Model" }
}

struct AIEngine: Sendable {
  let kind: AIEngineKind
  let model: String

  enum Failure: LocalizedError {
    case notInstalled(String)
    case failed(String, String)

    var errorDescription: String? {
      switch self {
      case .notInstalled(let name): "Couldn't find the \(name) command. Install it or pick another engine in Settings."
      case .failed(let name, let detail): "\(name) failed:\n\(detail)"
      }
    }
  }

  static var current: AIEngine {
    let defaults = UserDefaults.standard
    let kind = AIEngineKind(rawValue: defaults.string(forKey: "engine") ?? "") ?? .codex
    let model = defaults.string(forKey: kind.modelKey).flatMap { $0.isEmpty ? nil : $0 } ?? kind.defaultModel
    return AIEngine(kind: kind, model: model)
  }

  func run(_ prompt: String) async throws -> String {
    let environment = await ShellEnvironment.shared.environment()
    guard let executable = ShellEnvironment.find(kind.executable, in: environment["PATH"] ?? "") else {
      throw Failure.notInstalled(kind.executable)
    }

    let fm = FileManager.default
    let work = fm.temporaryDirectory.appending(path: "skillscout-\(UUID().uuidString)")
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }

    let input = work.appending(path: "prompt.txt")
    let output = work.appending(path: "stdout.txt")
    let errors = work.appending(path: "stderr.txt")
    let lastMessage = work.appending(path: "last-message.txt")
    try "\(PromptLibrary.marker)\n\n\(prompt)".write(to: input, atomically: true, encoding: .utf8)
    fm.createFile(atPath: output.path, contents: nil)
    fm.createFile(atPath: errors.path, contents: nil)

    let process = Process()
    process.executableURL = executable
    process.environment = environment
    process.currentDirectoryURL = work
    process.standardInput = try FileHandle(forReadingFrom: input)
    process.standardOutput = try FileHandle(forWritingTo: output)
    process.standardError = try FileHandle(forWritingTo: errors)

    switch kind {
    case .codex:
      process.arguments = [
        "exec", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only",
        "-m", model, "-c", "model_reasoning_effort=medium", "-o", lastMessage.path, "-",
      ]
    case .claude:
      process.arguments = ["-p", "--no-session-persistence", "--tools", "", "--model", model]
    }

    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }

    let stdout = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
    guard status == 0 else {
      let stderr = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
      let detail = (stderr + "\n" + stdout)
        .split(separator: "\n")
        .filter { !$0.hasPrefix("hook:") }
        .suffix(3)
        .joined(separator: "\n")
      throw Failure.failed(kind.name, detail)
    }
    if kind == .codex, let message = try? String(contentsOf: lastMessage, encoding: .utf8) {
      return message
    }
    return stdout
  }
}

actor ShellEnvironment {
  static let shared = ShellEnvironment()

  private var cached: [String: String]?

  func environment() -> [String: String] {
    if let cached { return cached }
    var environment = ProcessInfo.processInfo.environment
    let fallback = ["/opt/homebrew/bin", "/usr/local/bin", Paths.at(".local/bin").path, "/usr/bin", "/bin"]
    let path = [loginShellPath()].compactMap { $0 } + fallback
    environment["PATH"] = path.joined(separator: ":")
    cached = environment
    return environment
  }

  func loginShellPath() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
    process.arguments = ["-lic", "echo \"__PATH__$PATH\""]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
      .components(separatedBy: "\n")
      .first { $0.hasPrefix("__PATH__") }
      .map { String($0.dropFirst("__PATH__".count)) }
  }

  static func find(_ name: String, in path: String) -> URL? {
    path.split(separator: ":")
      .map { URL(fileURLWithPath: String($0)).appending(path: name) }
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }
}
