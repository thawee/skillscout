import Foundation

private func plural(_ count: Int, _ word: String) -> String {
  "\(count.formatted()) \(word)\(count == 1 ? "" : "s")"
}

private func bold(_ text: String) -> String { Terminal.bold(text) }
private func dim(_ text: String) -> String { Terminal.dim(text) }

enum Commands {
  static func summary(_ args: Arguments) async throws {
    let library = await Library.load(days: args.days, readChats: true)
    let skills = library.listed(includePlugins: false)
    let used = library.listed(includePlugins: true)
      .filter { library.chats($0) > 0 }
      .sorted { (-library.chats($0), $0.name) < (-library.chats($1), $1.name) }
    let missing = skills.filter { !$0.missing(from: library.tools).isEmpty }
    let unused = skills.filter { library.chats($0) == 0 }

    if args.json {
      struct Summary: Encodable {
        let days: Int
        let tools: [String]
        let skills: Int
        let messages: Int
        let mostUsed: [String: Int]
        let missingSomewhere: [String]
        let unused: [String]
      }
      try printJSON(Summary(
        days: library.days,
        tools: library.tools.map(\.rawValue),
        skills: skills.count,
        messages: library.prompts.count,
        mostUsed: Dictionary(uniqueKeysWithValues: used.prefix(10).map { ($0.name, library.chats($0)) }),
        missingSomewhere: missing.map(\.name),
        unused: unused.map(\.name)
      ))
      return
    }

    let tools = library.tools.map { Terminal.tint($0.name, $0) }.joined(separator: dim(", "))
    print("\(bold("\(plural(skills.count, "skill"))")) across \(tools)")
    print(dim("\(plural(library.prompts.count, "message")) in the last \(library.days) days"))
    print()

    if !used.isEmpty {
      print(bold("Most used"))
      let top = Array(used.prefix(5))
      let width = top.map(\.name.count).max() ?? 0
      for skill in top {
        print("  \(Terminal.pad(skill.name, width))  \(Terminal.padLeft("\(library.chats(skill))", 4)) \(dim(library.chats(skill) == 1 ? "chat" : "chats"))")
      }
      print()
    }

    print("\(Terminal.pad("Missing somewhere", 18)) \(Terminal.padLeft("\(missing.count)", 4))  \(dim("skillscout-thawee list --missing"))")
    print("\(Terminal.pad("Unused", 18)) \(Terminal.padLeft("\(unused.count)", 4))  \(dim("skillscout-thawee list --unused"))")
    print()
    print(dim("Run skillscout-thawee help to see every command."))
  }

  static func list(_ args: Arguments) async throws {
    let sort = SkillSort(rawValue: try args.choice("sort", from: SkillSort.allCases.map(\.rawValue), default: "name")) ?? .name
    let onlyTool = try args.tool("tool")
    let library = await Library.load(days: args.days, readChats: true)

    var skills = library.listed(includePlugins: args.flag("plugins"))
    if let onlyTool { skills = skills.filter { $0.availableIn.contains(onlyTool) } }
    if args.flag("missing") { skills = skills.filter { $0.isPersonal && !$0.missing(from: library.tools).isEmpty } }
    if args.flag("unused") { skills = skills.filter { library.chats($0) == 0 } }
    skills.sort { sort.inOrder($0, $1) { library.usage[$0.id] } }

    if args.json {
      try printJSON(skills.map { SkillJSON($0, in: library) })
      return
    }
    guard !skills.isEmpty else {
      print("No skills match.")
      return
    }

    let nameWidth = min(max(skills.map(\.name.count).max() ?? 0, 5), 32)
    let descriptionWidth = Terminal.width - nameWidth - 9 - library.tools.count * 3
    let codes = library.tools.map { Terminal.tint(Terminal.pad($0.code, 3), $0) }.joined()
    print("\(bold(Terminal.pad("SKILL", nameWidth)))  \(bold("CHATS"))  \(codes)\(descriptionWidth >= 20 ? bold("DESCRIPTION") : "")")

    for skill in skills {
      let chats = library.chats(skill)
      let marks = library.tools.map { tool in
        skill.availableIn.contains(tool) ? Terminal.tint(Terminal.pad("●", 3), tool) : dim(Terminal.pad("·", 3))
      }.joined()
      let count = chats > 0 ? Terminal.padLeft("\(chats)", 5) : dim(Terminal.padLeft("–", 5))
      let description = descriptionWidth >= 20 ? dim(Terminal.truncate(skill.description, descriptionWidth)) : ""
      print("\(Terminal.pad(Terminal.truncate(skill.name, nameWidth), nameWidth))  \(count)  \(marks)\(description)")
    }

    if Terminal.isTTY {
      let legend = library.tools.map { "\(Terminal.tint($0.code, $0)) \(dim($0.name))" }.joined(separator: "  ")
      print()
      print("\(dim("\(plural(skills.count, "skill")), chats from the last \(library.days) days."))  \(legend)")
    }
  }

  static func show(_ args: Arguments) async throws {
    let name = try args.single("skill")
    let library = await Library.load(days: args.days, readChats: true)
    let skill = try library.skill(named: name)

    if args.json {
      try printJSON(SkillJSON(skill, in: library))
      return
    }

    print(bold(skill.name))
    if !skill.description.isEmpty { print(Terminal.wrap(skill.description)) }
    print()

    print(bold("Available in"))
    let toolWidth = library.tools.map(\.name.count).max() ?? 0
    for tool in library.tools {
      let label = Terminal.pad(tool.name, toolWidth)
      if let provider = skill.provider(for: tool) {
        let source = provider.root.kind == .plugin ? "from the \(provider.sourceLabel)" : Paths.abbreviate(provider.root.url)
        print("  \(Terminal.tint("●", tool)) \(label)  \(dim(source))")
      } else if skill.isBuiltInOnly {
        print("  \(dim("·")) \(label)  \(dim("built into \(skill.primary.root.owner?.name ?? "another tool")"))")
      } else {
        print("  \(dim("·")) \(label)  \(Terminal.warn("missing"))  \(dim("skillscout-thawee add \(skill.name) --to \(tool.rawValue)"))")
      }
    }
    print()

    print(bold("Usage in the last \(library.days) days"))
    if let usage = library.usage[skill.id] {
      print("  Used in \(plural(usage.chats, "chat")), most recently \(Terminal.ago(min(usage.lastUsed, .now)))")
      let perTool = Tool.allCases.compactMap { tool in usage.byTool[tool].map { "\(Terminal.tint(tool.name, tool)) \($0)" } }
      print("  \(perTool.joined(separator: dim(", ")))")
      if !usage.topProjects.isEmpty { print("  Mostly in \(Terminal.list(usage.topProjects))") }
    } else {
      print(dim("  No chat used it."))
    }
    print()

    print(bold("Where it lives"))
    let created = skill.created(usage: library.usage[skill.id])
    if created != .distantPast {
      print("  Created \(created.formatted(.dateTime.day().month(.wide).year()))")
    }
    let sourceWidth = skill.copies.map(\.sourceLabel.count).max() ?? 0
    for copy in skill.copies {
      let path = copy.isSymlink ? "\(Paths.abbreviate(copy.folder)) → \(Paths.abbreviate(copy.resolved))" : Paths.abbreviate(copy.folder)
      print("  \(Terminal.pad(copy.sourceLabel, sourceWidth))  \(path)")
    }
    if skill.copiesDiffer {
      print(Terminal.warn("  These copies have different content, so editing one won't update the others."))
    }
  }

  static func usage(_ args: Arguments) async throws {
    let library = await Library.load(days: args.days, readChats: true)
    let used = library.listed(includePlugins: true)
      .filter { library.chats($0) > 0 }
      .sorted { (-library.chats($0), $0.name) < (-library.chats($1), $1.name) }

    if args.json {
      try printJSON(used.map { SkillJSON($0, in: library) })
      return
    }
    guard !used.isEmpty else {
      print("No chat used a skill in the last \(library.days) days.")
      return
    }

    let nameWidth = min(used.map(\.name.count).max() ?? 0, 32)
    let lastUsed = used.map { Terminal.ago(min(library.usage[$0.id]?.lastUsed ?? .now, .now)) }
    let dateWidth = max(lastUsed.map(\.count).max() ?? 0, 9)
    print("\(bold(Terminal.pad("SKILL", nameWidth)))  \(bold("CHATS"))  \(bold(Terminal.pad("LAST USED", dateWidth)))  \(bold("TOOLS"))")

    for (skill, date) in zip(used, lastUsed) {
      guard let usage = library.usage[skill.id] else { continue }
      let tools = Tool.allCases.compactMap { tool in usage.byTool[tool].map { Terminal.tint("\(tool.name) \($0)", tool) } }
      print("\(Terminal.pad(Terminal.truncate(skill.name, nameWidth), nameWidth))  \(Terminal.padLeft("\(usage.chats)", 5))  \(dim(Terminal.pad(date, dateWidth)))  \(tools.joined(separator: dim(", ")))")
    }

    if Terminal.isTTY {
      print()
      print(dim("A use is a chat where the agent read the skill, or where you attached it yourself."))
    }
  }

  static func tools(_ args: Arguments) async throws {
    let library = await Library.load(days: args.days, readChats: true)
    let enabled = Set(library.tools)
    let personal = library.skills.filter(\.isPersonal)

    struct Row: Encodable {
      let id: String
      let name: String
      let installed: Bool
      let enabled: Bool
      let skills: Int
      let messages: Int?
      let skillsFolder: String
    }
    let rows = Tool.allCases.map { tool in
      Row(
        id: tool.rawValue,
        name: tool.name,
        installed: tool.isInstalled,
        enabled: enabled.contains(tool),
        skills: personal.count(where: { $0.availableIn.contains(tool) }),
        messages: enabled.contains(tool) ? library.prompts.count(where: { $0.tool == tool }) : nil,
        skillsFolder: tool.skillsFolder.path
      )
    }

    if args.json {
      try printJSON(rows)
      return
    }

    let nameWidth = Tool.allCases.map(\.name.count).max() ?? 0
    print("\(bold(Terminal.pad("TOOL", nameWidth)))  \(bold(Terminal.pad("STATUS", 13)))  \(bold("SKILLS"))  \(bold("MESSAGES"))  \(bold("SKILL FOLDER"))")
    for (tool, row) in zip(Tool.allCases, rows) {
      let status = row.enabled ? "on" : row.installed ? "off" : "not installed"
      let messages = row.messages.map { Terminal.padLeft($0.formatted(), 8) } ?? dim(Terminal.padLeft("–", 8))
      let name = row.enabled ? Terminal.tint(Terminal.pad(tool.name, nameWidth), tool) : dim(Terminal.pad(tool.name, nameWidth))
      let statusText = row.enabled ? Terminal.pad(status, 13) : dim(Terminal.pad(status, 13))
      print("\(name)  \(statusText)  \(Terminal.padLeft("\(row.skills)", 6))  \(messages)  \(dim(Paths.abbreviate(tool.skillsFolder)))")
    }

    if Terminal.isTTY {
      print()
      print(dim("Messages cover the last \(library.days) days. Turn tools on or off in the Skillscout app's settings."))
    }
  }

  static func similar(_ args: Arguments) async throws {
    let library = await Library.load(days: args.days, readChats: false)
    let listed = Set(library.listed(includePlugins: false).map(\.id))
    let pairs = SkillSimilarity.pairs(in: library.skills, dismissed: Set(AppState.load().dismissedPairs ?? []))
      .filter { listed.contains($0.first) && listed.contains($0.second) }

    if args.json {
      struct Pair: Encodable {
        let skills: [String]
        let score: Double
        let sharedWords: [String]
      }
      try printJSON(pairs.map { Pair(skills: [$0.first, $0.second], score: ($0.score * 100).rounded() / 100, sharedWords: $0.sharedWords) })
      return
    }
    guard !pairs.isEmpty else {
      print("No two skills read alike.")
      return
    }

    let names = pairs.map { "\($0.first) + \($0.second)" }
    let width = min(names.map(\.count).max() ?? 0, 60)
    print("\(bold(Terminal.pad("SKILLS", width)))  \(bold("ALIKE"))  \(bold("BOTH MENTION"))")
    for (pair, name) in zip(pairs, names) {
      let score = Terminal.padLeft("\(Int((pair.score * 100).rounded()))%", 5)
      print("\(Terminal.pad(Terminal.truncate(name, width), width))  \(score)  \(dim(pair.sharedWords.joined(separator: ", ")))")
    }
    if Terminal.isTTY {
      print()
      print(dim("Merge two with skillscout-thawee merge <skill> <other>, or in the app's Similar skills."))
    }
  }

  static func add(_ args: Arguments) async throws {
    let name = try args.single("skill")
    let library = await Library.load(days: args.days, readChats: false)
    let skill = try library.skill(named: name)

    let targets: [Tool]
    if args.flag("all") {
      targets = skill.missing(from: library.tools)
    } else if let tool = try args.tool("to") {
      targets = [tool]
    } else {
      throw CLIError(message: "Pick where to add it: --to <tool>, or --all for every tool that's missing it.", usage: true)
    }

    var covered = skill.availableIn
    var added = 0
    for tool in targets {
      if covered.contains(tool) {
        if let provider = skill.provider(for: tool), !args.flag("all") {
          print("\(skill.name) already works in \(tool.name). It loads it from \(Paths.abbreviate(provider.root.url)).")
        }
        continue
      }
      let destination = try SkillInstaller.add(skill, to: tool)
      covered.formUnion(SkillRoot.all.first { $0.url == tool.skillsFolder }?.readBy ?? [tool])
      let verb = skill.isPluginOnly ? "Copied" : "Linked"
      print("\(verb) \(skill.name) into \(Paths.abbreviate(destination.deletingLastPathComponent())) for \(Terminal.tint(tool.name, tool))")
      added += 1
    }
    if args.flag("all"), added == 0 {
      print("\(skill.name) already works in every tool you use.")
    }
  }

  static func uninstall(_ args: Arguments) async throws {
    let name = try args.single("skill")
    let library = await Library.load(days: args.days, readChats: false)
    let skill = try library.skill(named: name)

    var removed = skill.removableCopies
    if let tool = try args.tool("from") {
      guard let copy = removed.first(where: { $0.root.url == tool.skillsFolder }) else {
        let source = skill.provider(for: tool).map { provider in
          " \(tool.name) loads it from \(provider.root.kind == .plugin ? "the \(provider.sourceLabel)" : Paths.abbreviate(provider.root.url))."
        }
        throw CLIError(message: "\(skill.name) isn't in \(Paths.abbreviate(tool.skillsFolder)).\(source ?? "")")
      }
      removed = skill.copiesGoing(with: copy)
    }
    guard !removed.isEmpty else {
      throw CLIError(message: skill.isBuiltInOnly
        ? "\(skill.name) is built into \(skill.primary.root.owner?.name ?? "its tool"), so it stays."
        : "\(skill.name) comes from the \(skill.primary.sourceLabel), so uninstall the plugin to remove it.")
    }

    try SkillInstaller.remove(removed)
    for copy in removed {
      print("Moved \(copy.isSymlink ? "the link " : "")\(Paths.abbreviate(copy.folder)) to the Trash")
    }
    let targets = skill.linkTargetsKept(removed).map(Paths.abbreviate)
    if !targets.isEmpty {
      print(dim("\(Terminal.list(targets)) \(targets.count == 1 ? "stays where it is" : "stay where they are")."))
    }

    let losing = library.tools.filter(skill.toolsLosing(removed).contains)
    if losing.isEmpty {
      print("Your tools still load \(skill.name) from another folder.")
    } else if losing == library.tools.filter(skill.availableIn.contains) {
      print("None of your tools load \(skill.name) anymore.")
    } else {
      print("\(Terminal.list(losing.map { Terminal.tint($0.name, $0) })) no longer \(losing.count == 1 ? "loads" : "load") it.")
    }
  }

  static func rename(_ args: Arguments) async throws {
    let (name, newName) = try args.two("skill", "new name", example: "release-notes changelog")
    let library = await Library.load(days: args.days, readChats: false)
    let skill = try library.skill(named: name)
    guard skill.isPersonal else { throw leftAlone(skill) }

    try SkillInstaller.rename(skill, to: newName, among: library.skills)
    print("Renamed \(skill.name) to \(bold(newName)) in \(Terminal.list(skill.removableCopies.map { Paths.abbreviate($0.root.url) }))")
    let targets = skill.linkTargetsKept(skill.removableCopies).map(Paths.abbreviate)
    if !targets.isEmpty {
      print(dim("\(Terminal.list(targets)), where the links point, \(targets.count == 1 ? "keeps its" : "keep their") folder name."))
    }
    if let plugin = skill.copies.first(where: { $0.root.kind == .plugin }) {
      print(dim("The copy from the \(plugin.sourceLabel) keeps the old name."))
    }
  }

  static func merge(_ args: Arguments) async throws {
    let (keptName, mergedName) = try args.two("skill to keep", "skill to merge into it", example: "writing-style email-style")
    let engine = try args.engine()
    let library = await Library.load(days: args.days, readChats: false)
    let kept = try library.skill(named: keptName)
    let merged = try library.skill(named: mergedName)
    for skill in [kept, merged] where !skill.isPersonal { throw leftAlone(skill) }
    let plan = try SkillInstaller.planMerge(merged, into: kept)

    Terminal.status("Asking \(engine.kind.name) to merge \(merged.name) into \(kept.name)…")
    let markdown = try await Analyzer.mergeSkills(plan, engine: engine)
    Terminal.clearStatus()
    if args.flag("dry-run") {
      print(markdown, terminator: "")
      Terminal.note("Nothing changed. Run it again without --dry-run to merge.")
      return
    }

    try SkillInstaller.merge(plan, markdown: markdown)
    print("Wrote the merged SKILL.md into \(Terminal.list(plan.folders.map(Paths.abbreviate)))")
    if !plan.copiedFiles.isEmpty {
      print("Copied \(plural(plan.copiedFiles.count, "file")) from \(merged.name)")
    }
    if !plan.skippedFiles.isEmpty {
      print(dim("\(plural(plan.skippedFiles.count, "file")) from \(merged.name) stayed out, because \(kept.name) has files at the same paths."))
    }
    print("Moved \(merged.name) to the Trash from \(Terminal.list(merged.removableCopies.map { Paths.abbreviate($0.root.url) }))")
    for link in plan.links {
      print("Linked \(kept.name) into \(Paths.abbreviate(link.deletingLastPathComponent()))")
    }
    print(dim("The old SKILL.md is in the Trash too."))
  }

  /// The error for a skill that a plugin or a tool manages.
  private static func leftAlone(_ skill: Skill) -> CLIError {
    let owner = skill.isBuiltInOnly ? skill.primary.root.owner?.name ?? "its tool" : "the \(skill.primary.sourceLabel)"
    return CLIError(message: "\(skill.name) belongs to \(owner), so Skillscout leaves it alone.")
  }

  static func suggest(_ args: Arguments) async throws {
    let engine = try args.engine()
    let library = await Library.load(days: args.days, readChats: true)
    guard !library.prompts.isEmpty else {
      throw CLIError(message: "There are no messages from the last \(library.days) days to look at.")
    }

    let count = min(library.prompts.count, Analyzer.maxMessages)
    Terminal.status("Asking \(engine.kind.name) to look for repeated requests in \(plural(count, "message"))…")
    let suggestions = try await Analyzer.findSuggestions(
      prompts: library.prompts,
      skills: library.skills,
      dismissed: AppState.load().dismissed ?? [],
      engine: engine
    )
    Terminal.clearStatus()

    if args.json {
      struct Example: Encodable {
        let tool: String
        let project: String
        let date: Date
        let text: String
      }
      struct Idea: Encodable {
        let name: String
        let title: String
        let summary: String
        let why: String
        let times: Int
        let projects: [String]
        let tools: [String]
        let examples: [Example]
      }
      try printJSON(suggestions.map { suggestion in
        Idea(
          name: suggestion.name,
          title: suggestion.title,
          summary: suggestion.summary,
          why: suggestion.why,
          times: suggestion.examples.count,
          projects: suggestion.projects,
          tools: suggestion.tools.map(\.rawValue),
          examples: suggestion.examples.map { Example(tool: $0.tool.rawValue, project: $0.project, date: $0.date, text: $0.text) }
        )
      })
      return
    }
    guard !suggestions.isEmpty else {
      print("No repeated requests stood out. Try again after a few more days of chats.")
      return
    }

    let width = min(Terminal.width, 100)
    for (index, suggestion) in suggestions.enumerated() {
      print("\(bold("\(index + 1). \(suggestion.title)"))  \(dim(suggestion.name))")
      print(Terminal.wrap(suggestion.summary, indent: "   "))
      let tools = suggestion.tools.map { Terminal.tint($0.name, $0) }
      print("   \(dim("You asked \(plural(suggestion.examples.count, "time")) in \(plural(suggestion.projects.count, "project")), in")) \(Terminal.list(tools))")
      print(dim(Terminal.wrap("Why: \(suggestion.why)", indent: "   ")))
      for example in suggestion.examples.prefix(3) {
        print("   \(dim("›")) \(Terminal.truncate(example.text, width - 5))")
      }
      print()
    }
    if Terminal.isTTY {
      print(dim("Open Skillscout to turn any of these into a SKILL.md and save it."))
    }
  }

  static func explain(_ args: Arguments) async throws {
    let name = try args.single("skill")
    let library = await Library.load(days: args.days, readChats: false)
    let skill = try library.skill(named: name)

    var explanation = args.flag("fresh") ? nil : AppState.load().explanations?[skill.primary.contentHash]
    if explanation == nil {
      let engine = try args.engine()
      let text = try String(contentsOf: skill.skillFile, encoding: .utf8)
      Terminal.status("Asking \(engine.kind.name) to read \(skill.name)…")
      explanation = try await Analyzer.explain(name: skill.name, skillText: text, engine: engine)
      Terminal.clearStatus()
    }

    if args.json {
      try printJSON(["name": skill.name, "explanation": explanation ?? ""])
      return
    }
    print(bold(skill.name))
    print(Terminal.wrap(explanation ?? ""))
  }

  static func install(_ args: Arguments) async throws {
    let source = try args.single("skill url or path")
    var explicit: [Tool]? = nil
    if let tool = try args.tool("to") {
      explicit = [tool]
    }

    Terminal.status("Installing \(source)...")
    do {
      let destination = try await SkillInstaller.install(source: source, explicitTools: explicit)
      Terminal.clearStatus()
      print("Installed to \(Paths.abbreviate(destination))")
    } catch {
      Terminal.clearStatus()
      throw error
    }
  }

  static func update(_ args: Arguments) async throws {
    let query = try args.single("skill")
    let library = await Library.load(days: 1, readChats: false)
    guard let skill = library.skills.first(where: { $0.name.localizedCaseInsensitiveCompare(query) == .orderedSame }) else {
      throw CLIError(message: "Couldn't find a skill named \(query).")
    }
    guard let managed = skill.copies.first(where: { $0.root.kind == .managed }) else {
      throw CLIError(message: "\(skill.name) is not a managed skill, so it can't be updated via git pull.")
    }

    Terminal.status("Updating \(skill.name)...")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", managed.resolved.path, "pull"]
    try process.run()
    process.waitUntilExit()
    Terminal.clearStatus()

    guard process.terminationStatus == 0 else {
      throw CLIError(message: "Failed to update \(skill.name) (git pull returned \(process.terminationStatus)).")
    }
    print("Updated \(skill.name).")
  }
}
