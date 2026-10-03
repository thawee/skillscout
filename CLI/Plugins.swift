import Foundation

extension Commands {
  static func plugins(_ args: Arguments) throws {
    let tools = Set(Tool.enabled)
    let plugins = PluginScanner.scan().filter { tools.contains($0.tool) }
    if args.json {
      struct Run: Encodable { let kind: String; let name: String; let detail: String }
      struct Row: Encodable {
        let tool: String; let name: String; let marketplace: String?; let version: String?
        let enabled: Bool?; let path: String; let skills: [String]; let runs: [Run]
      }
      try printJSON(plugins.map { p in
        Row(tool: p.tool.rawValue, name: p.name, marketplace: p.marketplace, version: p.version, enabled: p.enabled,
            path: p.folder.path, skills: p.skills, runs: p.runs.map { Run(kind: $0.kind.rawValue, name: $0.name, detail: $0.detail) })
      })
      return
    }
    guard !plugins.isEmpty else {
      print("No plugins in the tools you use.")
      return
    }
    for plugin in plugins {
      let state = plugin.enabled.map { $0 ? "" : Terminal.warn(" (off)") } ?? ""
      let origin = [plugin.marketplace, plugin.version].compactMap { $0 }.joined(separator: " ")
      print("\(Terminal.bold(plugin.name))\(state)  \(Terminal.tint(plugin.tool.name, plugin.tool))  \(Terminal.dim(origin))")
      if !plugin.skills.isEmpty { print("  \(plural(plugin.skills.count, "skill")): \(plugin.skills.joined(separator: ", "))") }
      for run in plugin.runs {
        print("  \(Terminal.warn(run.kind.rawValue))  \(run.name)")
        print("    \(Terminal.dim(run.detail))")
      }
    }
  }
}
