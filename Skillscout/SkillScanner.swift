import Foundation

enum SkillScanner {
  static func scan() -> [Skill] {
    let disabledClaudePlugins = claudeDisabledPlugins()
    var copiesByName: [String: [SkillCopy]] = [:]
    var descriptions: [String: String] = [:]

    for root in SkillRoot.all {
      var copiesInRoot: [String: [SkillCopy]] = [:]
      var newestInRoot: [String: (copy: SkillCopy, modified: Date)] = [:]

      for folder in skillFolders(in: root) {
        let file = folder.appending(path: "SKILL.md")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }

        let plugin = pluginInfo(for: folder, in: root)
        if root.owner == .claude, let plugin, disabledClaudePlugins.contains("\(plugin.name)@\(plugin.marketplace)") {
          continue
        }

        let meta = Frontmatter.parse(text)
        let name = meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
        let isSymlink = (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
        let resolved = folder.resolvingSymlinksInPath()
        let copy = SkillCopy(
          folder: folder,
          resolved: resolved,
          root: root,
          pluginName: plugin?.name,
          isSymlink: isSymlink,
          contentHash: shortHash(text),
          created: (try? resolved.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
        )
        if root.kind == .managed {
          copiesInRoot[name, default: []].append(copy)
        } else {
          let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
          if let existing = newestInRoot[name], existing.modified >= modified { continue }
          newestInRoot[name] = (copy, modified)
        }
        if descriptions[name] == nil, let description = meta["description"], !description.isEmpty {
          descriptions[name] = description
        }
      }

      for (name, entries) in copiesInRoot {
        copiesByName[name, default: []].append(contentsOf: entries.sorted { $0.folder.path < $1.folder.path })
      }
      for (name, entry) in newestInRoot {
        copiesByName[name, default: []].append(entry.copy)
      }
    }

    return copiesByName
      .map { name, copies in
        Skill(name: name, description: descriptions[name] ?? "", copies: copies)
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private static func skillFolders(in root: SkillRoot) -> [URL] {
    let fm = FileManager.default

    if root.kind != .plugin && root.kind != .managed {
      let entries = (try? fm.contentsOfDirectory(at: root.url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
      return entries.filter { fm.fileExists(atPath: $0.appending(path: "SKILL.md").path) }
    }

    guard let enumerator = fm.enumerator(at: root.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
      return []
    }
    var folders: [URL] = []
    for case let url as URL in enumerator {
      if url.lastPathComponent == "node_modules" {
        enumerator.skipDescendants()
      } else if url.lastPathComponent == "SKILL.md" {
        folders.append(url.deletingLastPathComponent())
      }
    }
    return folders
  }

  private static func pluginInfo(for folder: URL, in root: SkillRoot) -> (name: String, marketplace: String)? {
    guard root.kind == .plugin else { return nil }
    let relative = Array(folder.pathComponents.dropFirst(root.url.pathComponents.count))
    let isLocal = root.url.lastPathComponent == "local"
    let depth = isLocal ? 1 : 3
    guard relative.count > depth else { return nil }

    let pluginFolder = relative.prefix(depth).reduce(root.url) { $0.appending(path: $1) }
    let manifestName = [".cursor-plugin", ".claude-plugin", ".codex-plugin"]
      .lazy
      .compactMap { try? Data(contentsOf: pluginFolder.appending(path: "\($0)/plugin.json")) }
      .compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
      .compactMap { $0["name"] as? String }
      .first
    let folderName = isLocal ? relative[0] : relative[1]
    return (manifestName ?? folderName, isLocal ? "local" : relative[0])
  }

  private static func claudeDisabledPlugins() -> Set<String> {
    guard
      let data = try? Data(contentsOf: Paths.at(".claude/settings.json")),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let enabled = json["enabledPlugins"] as? [String: Bool]
    else { return [] }
    return Set(enabled.filter { !$0.value }.map(\.key))
  }
}

enum Frontmatter {
  static func parse(_ text: String) -> [String: String] {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }

    var result: [String: String] = [:]
    var index = 1
    while index < lines.count {
      let line = lines[index]
      if line.trimmingCharacters(in: .whitespaces) == "---" { break }
      index += 1

      guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces)
      var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

      if value.isEmpty || ["|", ">", "|-", ">-", "|+", ">+"].contains(value) {
        var parts: [String] = []
        while index < lines.count, lines[index].isEmpty || lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") {
          parts.append(lines[index].trimmingCharacters(in: .whitespaces))
          index += 1
        }
        value = parts.filter { !$0.isEmpty }.joined(separator: " ")
      }
      result[key] = unquote(value)
    }
    return result
  }

  /// The text after the frontmatter, or all of it when there's none.
  static func body(of text: String) -> String {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    guard let end = closingLine(lines) else { return text }
    return lines[(end + 1)...].joined(separator: "\n")
  }

  /// The text with `name` as the frontmatter name. Without frontmatter, the folder name is the skill name,
  /// so the text stays as it is.
  static func setting(name: String, in text: String) -> String {
    var lines = text.components(separatedBy: "\n")
    guard let end = closingLine(lines) else { return text }
    let ending = lines[0].hasSuffix("\r") ? "\r" : ""
    if let start = lines[1..<end].firstIndex(where: { $0.hasPrefix("name:") }) {
      var next = start + 1
      while next < end, lines[next].hasPrefix(" ") || lines[next].hasPrefix("\t") { next += 1 }
      lines.replaceSubrange(start..<next, with: ["name: \(name)\(ending)"])
    } else {
      lines.insert("name: \(name)\(ending)", at: 1)
    }
    return lines.joined(separator: "\n")
  }

  /// The index of the line that closes the frontmatter.
  private static func closingLine(_ lines: [String]) -> Int? {
    guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return nil }
    return lines.dropFirst().firstIndex { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }
  }

  private static func unquote(_ value: String) -> String {
    guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
    return String(value.dropFirst().dropLast())
  }
}
