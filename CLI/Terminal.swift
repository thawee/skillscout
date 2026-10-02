import Foundation

enum Terminal {
  static let isTTY = isatty(STDOUT_FILENO) == 1
  nonisolated(unsafe) static var colors = isTTY && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

  static var width: Int {
    var size = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
    return Int(ProcessInfo.processInfo.environment["COLUMNS"] ?? "") ?? 100
  }

  static func style(_ text: String, _ code: String) -> String {
    colors ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
  }

  static func bold(_ text: String) -> String { style(text, "1") }
  static func dim(_ text: String) -> String { style(text, "2") }
  static func tint(_ text: String, _ tool: Tool) -> String { style(text, "38;5;\(tool.ansiColor)") }
  static func warn(_ text: String) -> String { style(text, "33") }

  /// A one-line progress note on stderr, replaced by the next one and cleared before output.
  static func status(_ message: String) {
    guard isatty(STDERR_FILENO) == 1 else { return }
    FileHandle.standardError.write(Data("\r\u{1B}[2K\(dim(message))".utf8))
  }

  static func clearStatus() {
    guard isatty(STDERR_FILENO) == 1 else { return }
    FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
  }

  static func note(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
  }

  /// Pads before styling, since escape codes would count as characters.
  static func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
  }

  static func padLeft(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
  }

  static func truncate(_ text: String, _ width: Int) -> String {
    guard width > 1 else { return "" }
    let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
    return line.count <= width ? line : line.prefix(width - 1) + "…"
  }

  static func wrap(_ text: String, indent: String = "", width: Int = min(Terminal.width, 100)) -> String {
    var lines: [String] = []
    var line = ""
    for word in text.split(whereSeparator: \.isWhitespace) {
      if !line.isEmpty, indent.count + line.count + word.count + 1 > width {
        lines.append(indent + line)
        line = ""
      }
      line += line.isEmpty ? String(word) : " \(word)"
    }
    if !line.isEmpty { lines.append(indent + line) }
    return lines.joined(separator: "\n")
  }

  static func ago(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: .now)
  }

  static func list(_ items: [String]) -> String {
    items.formatted(.list(type: .and))
  }
}

extension Tool {
  var ansiColor: Int {
    switch self {
    case .cursor: 99
    case .claude: 208
    case .codex: 37
    case .copilot: 161
    case .gemini: 33
    case .antigravity: 93
    case .opencode: 35
    case .droid: 130
    case .pi: 135
    case .amp: 205
    }
  }

  /// Column heading in `skillscout list`.
  var code: String {
    switch self {
    case .cursor: "Cu"
    case .claude: "Cl"
    case .codex: "Co"
    case .copilot: "Cp"
    case .gemini: "Ge"
    case .antigravity: "An"
    case .opencode: "Op"
    case .droid: "Dr"
    case .pi: "Pi"
    case .amp: "Am"
    }
  }

}
