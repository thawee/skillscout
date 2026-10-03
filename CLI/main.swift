import Foundation

// Read the app's settings: enabled tools, lookback window and AI engine.
UserDefaults.standard.addSuite(named: "com.thawee.skillscout")

struct Arguments {
  var command: String?
  var positional: [String] = []
  private var flags: Set<String> = []
  private var options: [String: String] = [:]

  private static let valued: Set<String> = ["days", "tool", "to", "from", "sort", "engine", "model"]

  init(_ raw: [String]) throws {
    var queue = raw[...]
    while let argument = queue.popFirst() {
      if argument == "-h" {
        flags.insert("help")
      } else if argument.hasPrefix("--") {
        var name = String(argument.dropFirst(2))
        var value: String?
        if let equals = name.firstIndex(of: "=") {
          value = String(name[name.index(after: equals)...])
          name = String(name[..<equals])
        }
        if Self.valued.contains(name) {
          guard let value = value ?? queue.popFirst() else { throw CLIError(message: "--\(name) needs a value.", usage: true) }
          options[name] = value
        } else {
          flags.insert(name)
        }
      } else if command == nil {
        command = argument
      } else {
        positional.append(argument)
      }
    }

    if let days = options["days"], (Int(days) ?? 0) < 1 {
      throw CLIError(message: "--days needs a whole number of days, like --days 30.", usage: true)
    }
  }

  func flag(_ name: String) -> Bool { flags.contains(name) }
  func option(_ name: String) -> String? { options[name] }
  var json: Bool { flag("json") }

  var days: Int {
    if let days = options["days"].flatMap(Int.init) { return days }
    let saved = UserDefaults.standard.integer(forKey: "lookbackDays")
    return saved > 0 ? saved : 60
  }

  func check(allowed: [String]) throws {
    let known = Set(allowed + ["help", "no-color", "version"])
    if let unknown = (flags.union(options.keys)).subtracting(known).sorted().first {
      throw CLIError(message: "\(command.map { "\($0) doesn't take" } ?? "Unknown option") --\(unknown).", usage: true)
    }
  }

  func single(_ what: String) throws -> String {
    guard let value = positional.first else { throw CLIError(message: "Tell me which \(what), like: skillscout-mod \(command ?? "") release-notes", usage: true) }
    guard positional.count == 1 else { throw CLIError(message: "Pass one \(what) at a time.", usage: true) }
    return value
  }

  func two(_ first: String, _ second: String, example: String) throws -> (String, String) {
    guard positional.count == 2 else {
      throw CLIError(message: "Pass the \(first) and the \(second), like: skillscout-mod \(command ?? "") \(example)", usage: true)
    }
    return (positional[0], positional[1])
  }

  func tool(_ option: String) throws -> Tool? {
    guard let value = options[option] else { return nil }
    guard let tool = Tool(argument: value) else {
      throw CLIError(message: "\(value) isn't a tool I know. Use one of: \(Tool.allCases.map(\.rawValue).joined(separator: ", ")).", usage: true)
    }
    return tool
  }

  func choice(_ option: String, from choices: [String], default fallback: String) throws -> String {
    guard let value = options[option] else { return fallback }
    guard choices.contains(value) else {
      throw CLIError(message: "--\(option) takes \(choices.joined(separator: " or ")).", usage: true)
    }
    return value
  }

  func engine() throws -> AIEngine {
    var engine = AIEngine.current
    if let name = options["engine"] {
      guard let kind = AIEngineKind(rawValue: name.lowercased()) else {
        throw CLIError(message: "--engine takes codex or claude.", usage: true)
      }
      let saved = UserDefaults.standard.string(forKey: kind.modelKey).flatMap { $0.isEmpty ? nil : $0 }
      engine = AIEngine(kind: kind, model: saved ?? kind.defaultModel)
    }
    if let model = options["model"] {
      engine = AIEngine(kind: engine.kind, model: model)
    }
    return engine
  }
}

enum Command: String, CaseIterable {
  case list, show, usage, tools, similar, add, rename, merge, uninstall, suggest, explain, install, update

  var synopsis: String {
    switch self {
    case .list: "list [options]"
    case .show: "show <skill> [options]"
    case .usage: "usage [options]"
    case .tools: "tools [options]"
    case .similar: "similar [options]"
    case .add: "add <skill> --to <tool> | --all"
    case .rename: "rename <skill> <new-name>"
    case .merge: "merge <skill> <other> [options]"
    case .uninstall: "uninstall <skill> [--from <tool>]"
    case .suggest: "suggest [options]"
    case .explain: "explain <skill> [options]"
    case .install: "install <url_or_path> [--to <tool>]"
    case .update: "update <skill | repository>"
    }
  }

  var summary: String {
    switch self {
    case .list: "List your skills and the tools that load them"
    case .show: "Where a skill lives, which tools see it, and its usage"
    case .usage: "Rank skills by how many chats used them"
    case .tools: "The agent tools Skillscout knows about"
    case .similar: "Pairs of skills that read alike"
    case .add: "Add a skill to another tool"
    case .rename: "Give a skill a new name"
    case .merge: "Merge another skill into this one with AI"
    case .uninstall: "Move a skill to the Trash"
    case .suggest: "Ask AI for skill ideas based on requests you repeat"
    case .explain: "Ask AI what a skill does"
    case .install: "Install a skill from GitHub or a local path"
    case .update: "Review and apply changes to a Library repository"
    }
  }

  var details: String {
    switch self {
    case .list:
      "Lists the skills your tools load. Each row shows how many chats used the skill, then a column per tool: a dot means that tool can't see it."
    case .show:
      "Shows which tools load a skill and from which folder, how often you used it, and every copy on disk."
    case .usage:
      "Ranks skills by the number of chats that used them. A use is a chat where the agent read the skill's SKILL.md, or where you attached or invoked the skill yourself."
    case .tools:
      "Lists the agent tools Skillscout knows, whether they're on, and where each one keeps its skills. Turn tools on or off in the app's settings."
    case .similar:
      "Compares the words your skills use, on your Mac and without AI, and lists the pairs that read alike, so you can merge them. Pairs you dismissed in the app stay hidden."
    case .rename:
      "Renames a skill's folders and links in your skills folders, and the name in its SKILL.md. Folders that links point to outside your skills folders keep their name, and plugin copies keep the old name. Chats that used the old name still count."
    case .merge:
      "Asks AI to write one SKILL.md from two skills, and makes it the SKILL.md of the first one. The old SKILL.md and the other skill go to the Trash, and the first skill gets linked wherever the other one was, so no tool loses it. The other skill's files come along, unless the first one has a file at the same path."
    case .add:
      "Makes a skill available in another tool. Skillscout links the skill folder into that tool's skills folder, so an edit shows up everywhere. Plugin skills get copied instead, since plugin updates replace their folders. A skill from a downloaded repository with scripts or high-risk commands is listed first and needs a yes, or --yes without a terminal."
    case .uninstall:
      "Moves every copy of a skill in your skills folders to the Trash, so you can put it back from there. A link goes on its own, and the folder it points to stays. Plugin and built-in copies stay too, since their tools manage them."
    case .suggest:
      "Sends your recent messages to the Codex or Claude Code CLI and asks for skill ideas: requests you keep typing that a skill could handle. The run isn't saved to your chat history."
    case .explain:
      "Asks AI what a skill does, when the agent uses it, and what it needs to work. If the app already explained this skill, you get that answer right away."
    case .install:
      "Installs a skill from a GitHub URL or a local path into the Library, then links it to your tools. If the skill's SKILL.md specifies supported tools, it will only be linked to them, otherwise you can specify --to <tool>. If the download has scripts or high-risk commands, they're listed first and linking needs a yes, or --yes without a terminal."
    case .update:
      "Downloads a Library repository again, or copies its local folder again, and lists the added, changed and removed files, with the scripts and high-risk commands in them. The Library copy is replaced only after a yes, or --yes without a terminal, and the old copy goes to the Trash. Pass a skill from the repository or the repository's name."
    }
  }

  var options: [(flag: String, help: String)] {
    let days = ("--days <n>", "How many days of chats to read (default: the app's setting, or 60)")
    let json = ("--json", "Print JSON")
    let engine = [
      ("--engine <name>", "codex or claude (default: the app's setting)"),
      ("--model <name>", "The model to use"),
    ]
    switch self {
    case .list:
      return [
        ("--tool <tool>", "Only skills this tool loads"),
        ("--missing", "Only skills missing from at least one tool"),
        ("--unused", "Only skills no chat used"),
        ("--plugins", "Include plugin and built-in skills"),
        ("--sort <order>", "newest, name or use (default: name)"),
        days, json,
      ]
    case .show, .usage, .tools:
      return [days, json]
    case .similar:
      return [json]
    case .rename:
      return []
    case .merge:
      return [("--dry-run", "Print the merged SKILL.md and change nothing")] + engine
    case .add:
      return [
        ("--to <tool>", "The tool to add it to"),
        ("--all", "Add it to every tool you use that's missing it"),
        ("--yes", "Add a flagged skill without asking"),
      ]
    case .uninstall:
      return [("--from <tool>", "Only the copy in this tool's skills folder, and the links to it")]
    case .suggest:
      return engine + [days, json]
    case .explain:
      return [("--fresh", "Ask again, even if the app saved an explanation")] + engine + [json]
    case .install:
      return [
        ("--to <tool>", "The tool to link it to (overrides SKILL.md frontmatter)"),
        ("--yes", "Link a flagged download without asking"),
      ]
    case .update:
      return [("--yes", "Apply the changes without asking")]
    }
  }

  var optionNames: [String] {
    options.map { String($0.flag.dropFirst(2).prefix { $0 != " " }) }
  }

  func run(_ args: Arguments) async throws {
    switch self {
    case .list: try await Commands.list(args)
    case .show: try await Commands.show(args)
    case .usage: try await Commands.usage(args)
    case .tools: try await Commands.tools(args)
    case .similar: try await Commands.similar(args)
    case .add: try await Commands.add(args)
    case .rename: try await Commands.rename(args)
    case .merge: try await Commands.merge(args)
    case .uninstall: try await Commands.uninstall(args)
    case .suggest: try await Commands.suggest(args)
    case .explain: try await Commands.explain(args)
    case .install: try await Commands.install(args)
    case .update: try await Commands.update(args)
    }
  }
}

func printHelp(_ command: Command?) {
  let bold = Terminal.bold
  guard let command else {
    print(Terminal.wrap("Skillscout finds the skills your coding agents load, shows which tools can use each one, and counts how often you use them."))
    print()
    print("\(bold("Usage:")) skillscout-mod [command] [options]")
    print()
    print(bold("Commands:"))
    for command in Command.allCases {
      let name = command.synopsis.split(separator: " ").prefix { !$0.hasPrefix("[") && !$0.hasPrefix("-") }.joined(separator: " ")
      print("  \(Terminal.pad(name, 17)) \(command.summary)")
    }
    print()
    print("Run skillscout-mod with no command for a summary.")
    print("Run skillscout-mod help <command> to see its options.")
    print()
    print("\(bold("Tools:")) \(Tool.allCases.map(\.rawValue).joined(separator: ", "))")
    return
  }

  print("\(bold("Usage:")) skillscout-mod \(command.synopsis)")
  print()
  print(Terminal.wrap(command.details))
  print()
  print(bold("Options:"))
  for option in command.options {
    print("  \(Terminal.pad(option.flag, 17)) \(option.help)")
  }
}

var version: String {
  Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
}

do {
  let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
  if args.flag("no-color") { Terminal.colors = false }

  if args.flag("version") {
    print("skillscout-mod \(version)")
  } else if args.command == "help" {
    let name = args.positional.first
    guard let command = name.map(Command.init(rawValue:)) ?? .some(nil) else {
      throw CLIError(message: "There's no \(name ?? "") command.", usage: true)
    }
    printHelp(command)
  } else if let name = args.command {
    guard let command = Command(rawValue: name) else { throw CLIError(message: "There's no \(name) command.", usage: true) }
    if args.flag("help") {
      printHelp(command)
    } else {
      try args.check(allowed: command.optionNames)
      try await command.run(args)
    }
  } else if args.flag("help") {
    printHelp(nil)
  } else {
    try args.check(allowed: ["days", "json"])
    try await Commands.summary(args)
  }
} catch {
  Terminal.clearStatus()
  let usage = (error as? CLIError)?.usage == true
  Terminal.note("skillscout-mod: \(error.localizedDescription)")
  if usage { Terminal.note("Run skillscout-mod help for usage.") }
  exit(usage ? 2 : 1)
}
