import CryptoKit
import Foundation

/// The files in a skill or repository folder, and the scripts and lines worth reading before an agent follows it.
/// The checks are a heuristic: an empty review doesn't mean the folder is safe.
struct SkillReview: Sendable {
  struct File: Hashable, Sendable {
    let path: String
    let size: Int
    let isScript: Bool
  }

  struct Finding: Hashable, Sendable {
    let path: String
    let line: Int
    let reason: String
    let text: String
    let highRisk: Bool
  }

  let files: [File]
  let findings: [Finding]

  var scripts: [File] { files.filter(\.isScript) }
  /// Scripts or high-risk lines, which are worth a look before adding the skill to an agent.
  var needsReview: Bool { !scripts.isEmpty || findings.contains(where: \.highRisk) }

  /// A one-line summary, such as "2 scripts, 1 high-risk line".
  var summary: String {
    var parts: [String] = []
    let high = findings.count(where: \.highRisk)
    if !scripts.isEmpty { parts.append(scripts.count == 1 ? "1 script" : "\(scripts.count) scripts") }
    if high > 0 { parts.append(high == 1 ? "1 high-risk line" : "\(high) high-risk lines") }
    let other = findings.count - high
    if other > 0 { parts.append(other == 1 ? "1 command to note" : "\(other) commands to note") }
    return parts.isEmpty ? "No scripts or flagged commands" : parts.joined(separator: ", ")
  }

  /// The review limited to some files, such as the ones an update adds or changes.
  func limited(to paths: Set<String>) -> SkillReview {
    SkillReview(files: files.filter { paths.contains($0.path) }, findings: findings.filter { paths.contains($0.path) })
  }

  static let scriptExtensions: Set<String> = ["sh", "bash", "zsh", "fish", "py", "js", "mjs", "cjs", "ts", "rb", "pl", "php", "ps1", "command", "applescript", "scpt"]
  private static let skippedNames: Set<String> = [".git", "node_modules", ".DS_Store", ".skillscout-local-source"]
  private static let maxScannedSize = 512 * 1024

  private static let rules: [(pattern: String, reason: String, highRisk: Bool)] = [
    (#"\b(curl|wget)\b[^|\n]*\|\s*(sudo\s+)?(ba|z|fi)?sh\b"#, "Downloads and runs a script", true),
    (#"\bbase64\s+(-d|-D|--decode)\b"#, "Decodes hidden content", true),
    (#"(^|[\s;&|`(])sudo\s"#, "Runs with administrator rights", true),
    (#"\brm\s+-[a-zA-Z]*[rf][a-zA-Z]*\s+(/|~|\$HOME)(\s|/|$)"#, "Deletes from the home or root folder", true),
    (#"\beval\b"#, "Runs generated code", false),
    (#"\bchmod\s+(\+x|[0-7]*7[0-7]{0,2})\b"#, "Makes a file executable", false),
    (#"\b(curl|wget)\s"#, "Downloads from the network", false),
  ]

  private static let compiledRules: [(NSRegularExpression, String, Bool)] = rules.compactMap { rule in
    (try? NSRegularExpression(pattern: rule.pattern)).map { ($0, rule.reason, rule.highRisk) }
  }

  static func inspect(_ folder: URL) -> SkillReview {
    var files: [File] = []
    var findings: [Finding] = []
    for (url, path) in regularFiles(in: folder) {
      if isLink(url) {
        files.append(File(path: path, size: 0, isScript: false))
        continue
      }
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isExecutableKey])
      let size = values?.fileSize ?? 0
      let isScript = scriptExtensions.contains(url.pathExtension.lowercased()) || values?.isExecutable == true
      files.append(File(path: path, size: size, isScript: isScript))
      guard size <= maxScannedSize, let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      for (index, line) in text.components(separatedBy: .newlines).enumerated() {
        let range = NSRange(line.startIndex..., in: line)
        // One finding per line: the first rule that matches, high-risk rules first.
        if let rule = compiledRules.first(where: { $0.0.firstMatch(in: line, range: range) != nil }) {
          let trimmed = line.trimmingCharacters(in: .whitespaces)
          findings.append(Finding(path: path, line: index + 1, reason: rule.1,
                                  text: String(trimmed.prefix(160)), highRisk: rule.2))
        }
      }
    }
    return SkillReview(files: files.sorted { $0.path < $1.path }, findings: findings)
  }

  /// A content hash for each file, keyed by its path relative to the folder.
  static func fingerprints(_ folder: URL) -> [String: String] {
    var result: [String: String] = [:]
    for (url, path) in regularFiles(in: folder) {
      let data = isLink(url)
        ? (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)).map { Data("link:\($0)".utf8) }
        : try? Data(contentsOf: url)
      guard let data else { continue }
      result[path] = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    return result
  }

  private static func isLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
  }

  /// Regular files under the folder with their relative paths, skipping Git data, dependencies and Skillscout markers.
  /// Symbolic links are listed but not followed.
  private static func regularFiles(in folder: URL) -> [(URL, String)] {
    // Resolve the folder itself, since an installed skill is often a link, then list it by relative path.
    let base = folder.resolvingSymlinksInPath()
    guard let enumerator = FileManager.default.enumerator(atPath: base.path) else { return [] }
    var result: [(URL, String)] = []
    while let path = enumerator.nextObject() as? String {
      if skippedNames.contains((path as NSString).lastPathComponent) {
        enumerator.skipDescendants()
        continue
      }
      let type = enumerator.fileAttributes?[.type] as? FileAttributeType
      guard type == .typeRegular || type == .typeSymbolicLink else { continue }
      result.append((base.appending(path: path), path))
    }
    return result
  }
}
