import Foundation

/// Something a plugin runs on your Mac without being asked: a hook, a server, a monitor or an executable.
struct PluginRunItem: Hashable, Sendable {
  enum Kind: String, Sendable, CaseIterable {
    case hook = "Hook"
    case mcpServer = "MCP server"
    case lspServer = "Language server"
    case monitor = "Monitor"
    case executable = "Executable"
  }

  let kind: Kind
  /// The hook event or the server, monitor or file name.
  let name: String
  /// The command, URL or MCP tool it runs. Environment values and URL credentials are never included.
  let detail: String

  /// For a hook, the event without its matcher.
  var event: String { name.components(separatedBy: " (").first ?? name }
}

/// A plugin installed for an agent, read from its folder and manifest. Skillscout never changes plugins.
struct InstalledPlugin: Identifiable, Hashable, Sendable {
  let tool: Tool
  let name: String
  let marketplace: String?
  let version: String?
  let description: String
  let folder: URL
  /// Whether the agent has the plugin turned on, when Skillscout can tell.
  let enabled: Bool?
  let skills: [String]
  let runs: [PluginRunItem]

  var id: String { "\(tool.rawValue):\(marketplace ?? "local"):\(name)" }
}

enum PluginScanner {
  static func scan() -> [InstalledPlugin] {
    (claudePlugins() + cachedPlugins(.codex, root: Paths.at(".codex/plugins/cache"), manifest: ".codex-plugin", depth: 2)
      + cachedPlugins(.cursor, root: Paths.at(".cursor/plugins/cache"), manifest: ".cursor-plugin", depth: 2)
      + cachedPlugins(.cursor, root: Paths.at(".cursor/plugins/local"), manifest: ".cursor-plugin", depth: 0))
      .sorted { ($0.tool.rawValue, $0.name.lowercased()) < ($1.tool.rawValue, $1.name.lowercased()) }
  }

  // MARK: - Agents

  /// Claude Code lists its plugins in `installed_plugins.json`. A plugin without its own `plugin.json` takes its
  /// components from its marketplace entry.
  static func claudePlugins(home: URL = Paths.home) -> [InstalledPlugin] {
    let base = home.appending(path: ".claude/plugins")
    guard let installed = json(base.appending(path: "installed_plugins.json"))?["plugins"] as? [String: Any] else { return [] }
    let settings = json(home.appending(path: ".claude/settings.json"))?["enabledPlugins"] as? [String: Bool] ?? [:]
    let marketplaces = json(base.appending(path: "known_marketplaces.json")) ?? [:]
    return installed.keys.sorted().compactMap { key in
      guard let entries = installed[key] as? [[String: Any]],
            let entry = entries.last, let path = entry["installPath"] as? String else { return nil }
      let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
      let name = parts[0]
      let marketplace = parts.count > 1 ? parts[1] : nil
      let folder = URL(fileURLWithPath: path)
      let ownManifest = json(folder.appending(path: ".claude-plugin/plugin.json"))
      let marketplaceFolder = marketplace.map { name in
        ((marketplaces[name] as? [String: Any])?["installLocation"] as? String).map { URL(fileURLWithPath: $0) }
          ?? base.appending(path: "marketplaces/\(name)")
      }
      let listing = marketplaceFolder.flatMap { marketplaceEntry(name, in: $0.appending(path: ".claude-plugin/marketplace.json")) }
      // Without its own plugin.json, the marketplace entry is the manifest. With one, a strict entry adds its components.
      let manifest = ownManifest ?? listing ?? [:]
      let extra = ownManifest != nil && listing?["strict"] as? Bool != false ? listing : nil
      let defaultEnabled = listing?["defaultEnabled"] as? Bool ?? manifest["defaultEnabled"] as? Bool ?? true
      return plugin(tool: .claude, name: manifest["name"] as? String ?? name, marketplace: marketplace,
                    version: entry["version"] as? String ?? manifest["version"] as? String, folder: folder,
                    manifest: manifest, entry: extra, enabled: settings[key] ?? defaultEnabled)
    }
  }

  /// Codex and Cursor keep plugins in `<marketplace>/<plugin>/<version>` folders, or directly under `local`.
  /// Only the newest version of each plugin counts.
  static func cachedPlugins(_ tool: Tool, root: URL, manifest manifestFolder: String, depth: Int) -> [InstalledPlugin] {
    let fm = FileManager.default
    func children(_ url: URL) -> [URL] {
      ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }
    var folders: [(folder: URL, marketplace: String?)] = []
    if depth == 0 {
      folders = children(root).map { ($0, nil) }
    } else {
      for marketplace in children(root) {
        for plugin in children(marketplace) {
          let newest = children(plugin).max { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
          if let newest { folders.append((newest, marketplace.lastPathComponent)) }
        }
      }
    }
    return folders.compactMap { folder, marketplace in
      guard let manifest = json(folder.appending(path: "\(manifestFolder)/plugin.json")) else { return nil }
      return plugin(tool: tool, name: manifest["name"] as? String ?? folder.deletingLastPathComponent().lastPathComponent,
                    marketplace: marketplace, version: manifest["version"] as? String ?? (depth == 0 ? nil : folder.lastPathComponent),
                    folder: folder, manifest: manifest, enabled: nil)
    }
  }

  // MARK: - Components

  /// `entry` is a marketplace entry whose components add to the plugin's own manifest. Its hooks replace the
  /// manifest's for the same event, and its servers replace ones with the same name.
  static func plugin(tool: Tool, name: String, marketplace: String?, version: String?, folder: URL,
                     manifest: [String: Any], entry: [String: Any]? = nil, enabled: Bool?) -> InstalledPlugin {
    var items = runs(in: folder, manifest: manifest)
    var skillNames = skills(in: folder, manifest: manifest)
    if let entry {
      let added = runs(in: folder, manifest: entry, includeDefaults: false)
      let events = Set(added.filter { $0.kind == .hook }.map(\.event))
      items.removeAll { item in
        item.kind == .hook ? events.contains(item.event) : added.contains { $0.kind == item.kind && $0.name == item.name }
      }
      items += added
      skillNames = Array(Set(skillNames + skills(in: folder, manifest: entry))).sorted()
    }
    return InstalledPlugin(tool: tool, name: name, marketplace: marketplace, version: version,
                           description: manifest["description"] as? String ?? entry?["description"] as? String ?? "",
                           folder: folder, enabled: enabled, skills: skillNames, runs: items)
  }

  /// `includeDefaults: false` reads only what the manifest declares, not the plugin's default files.
  static func runs(in folder: URL, manifest: [String: Any], includeDefaults: Bool = true) -> [PluginRunItem] {
    var items: [PluginRunItem] = []

    // Hooks: the default file, then the manifest's paths and inline objects.
    var hookMaps: [[String: Any]] = []
    if includeDefaults, let file = json(folder.appending(path: "hooks/hooks.json")) { hookMaps.append(unwrapHooks(file)) }
    for value in list(manifest["hooks"]) {
      if let path = value as? String, let file = json(resolve(path, in: folder)) { hookMaps.append(unwrapHooks(file)) }
      if let inline = value as? [String: Any] { hookMaps.append(unwrapHooks(inline)) }
    }
    for map in hookMaps {
      for event in map.keys.sorted() {
        for matcher in (map[event] as? [[String: Any]]) ?? [] {
          for handler in (matcher["hooks"] as? [[String: Any]]) ?? [] {
            var name = event
            if let pattern = matcher["matcher"] as? String, !pattern.isEmpty { name += " (\(pattern))" }
            items.append(PluginRunItem(kind: .hook, name: name, detail: handlerDetail(handler)))
          }
        }
      }
    }

    // MCP and language servers: the default file, then the manifest's paths and inline maps.
    for (kind, defaultFile, key) in [(PluginRunItem.Kind.mcpServer, ".mcp.json", "mcpServers"), (.lspServer, ".lsp.json", "lspServers")] {
      var servers: [(String, [String: Any])] = []
      func add(_ map: [String: Any]) {
        let inner = map[key] as? [String: Any] ?? map
        for name in inner.keys.sorted() {
          guard let config = inner[name] as? [String: Any] else { continue }
          servers.removeAll { $0.0 == name }
          servers.append((name, config))
        }
      }
      if includeDefaults, let file = json(folder.appending(path: defaultFile)) { add(file) }
      for value in list(manifest[key]) {
        if let path = value as? String {
          if path.hasSuffix(".mcpb") || path.hasSuffix(".dxt") {
            servers.append(((path as NSString).lastPathComponent, ["bundle": path]))
          } else if let file = json(resolve(path, in: folder)) {
            add(file)
          }
        }
        if let inline = value as? [String: Any] { add(inline) }
      }
      items += servers.map { PluginRunItem(kind: kind, name: $0.0, detail: serverDetail($0.1)) }
    }

    // Monitors run as background processes.
    let experimental = manifest["experimental"] as? [String: Any]
    var monitors = includeDefaults ? jsonArray(folder.appending(path: "monitors/monitors.json")) ?? [] : []
    for value in [experimental?["monitors"], manifest["monitors"]].compactMap({ $0 }) {
      if let path = value as? String, let file = jsonArray(resolve(path, in: folder)) { monitors = file }
      if let inline = value as? [[String: Any]] { monitors = inline }
    }
    items += monitors.map { PluginRunItem(kind: .monitor, name: $0["name"] as? String ?? "monitor", detail: $0["command"] as? String ?? "") }

    // Files in bin/ are on the agent's PATH while the plugin is on.
    let bin = folder.appending(path: "bin")
    let executables = includeDefaults
      ? ((try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted() : []
    items += executables.map { PluginRunItem(kind: .executable, name: $0, detail: "bin/\($0)") }
    return items
  }

  /// Skill names from the default `skills/` folder, the manifest's `skills` paths, or a `SKILL.md` at the root.
  static func skills(in folder: URL, manifest: [String: Any]) -> [String] {
    let fm = FileManager.default
    var roots = [folder.appending(path: "skills")]
    roots += list(manifest["skills"]).compactMap { $0 as? String }.map { $0 == "." ? folder : resolve($0, in: folder) }
    var names = Set<String>()
    for root in roots {
      if fm.fileExists(atPath: root.appending(path: "SKILL.md").path) {
        names.insert(skillName(root))
        continue
      }
      for entry in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
      where fm.fileExists(atPath: entry.appending(path: "SKILL.md").path) {
        names.insert(skillName(entry))
      }
    }
    if names.isEmpty, fm.fileExists(atPath: folder.appending(path: "SKILL.md").path) { names.insert(skillName(folder)) }
    return names.sorted()
  }

  // MARK: - Helpers

  private static func skillName(_ folder: URL) -> String {
    let text = (try? String(contentsOf: folder.appending(path: "SKILL.md"), encoding: .utf8)) ?? ""
    return Frontmatter.parse(text)["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
  }

  /// A hooks file wraps its events in a "hooks" key, beside keys like "description"; Claude Code's inline form
  /// doesn't wrap them, Codex's does. Event values are arrays, so a "hooks" dictionary is always the wrapper.
  private static func unwrapHooks(_ object: [String: Any]) -> [String: Any] {
    object["hooks"] as? [String: Any] ?? object
  }

  private static func handlerDetail(_ handler: [String: Any]) -> String {
    if let command = handler["command"] as? String {
      let args = (handler["args"] as? [String]) ?? []
      return ([command] + args).joined(separator: " ")
    }
    if let tool = handler["tool"] as? String {
      return "MCP tool \(tool)" + ((handler["server"] as? String).map { " on \($0)" } ?? "")
    }
    if let url = handler["url"] as? String { return SkillInstaller.redactedSource(url) }
    return handler["type"] as? String ?? "unknown handler"
  }

  private static func serverDetail(_ config: [String: Any]) -> String {
    if let bundle = config["bundle"] as? String { return "Bundle \(bundle)" }
    if let command = config["command"] as? String {
      let args = (config["args"] as? [String]) ?? []
      return ([command] + args).joined(separator: " ")
    }
    if let url = config["url"] as? String { return SkillInstaller.redactedSource(url) }
    return config["type"] as? String ?? "unknown server"
  }

  private static func list(_ value: Any?) -> [Any] {
    if let array = value as? [Any] { return array }
    return value.map { [$0] } ?? []
  }

  /// A manifest path relative to the plugin, kept inside it.
  private static func resolve(_ path: String, in folder: URL) -> URL {
    let url = folder.appending(path: path).standardizedFileURL
    return url.path.hasPrefix(folder.standardizedFileURL.path + "/") ? url : folder.appending(path: ".invalid-path")
  }

  private static func json(_ url: URL) -> [String: Any]? {
    (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
  }

  private static func jsonArray(_ url: URL) -> [[String: Any]]? {
    (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
  }

  private static func marketplaceEntry(_ name: String, in file: URL) -> [String: Any]? {
    (json(file)?["plugins"] as? [[String: Any]])?.first { $0["name"] as? String == name }
  }
}
