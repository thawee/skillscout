import Foundation

extension Commands {
  static func skillset(_ args: Arguments) async throws {
    guard let action = args.positional.first else {
      throw CLIError(message: "Pick an action: list, show, apply, unassign, export or import.", usage: true)
    }
    if args.json && action != "list" {
      throw CLIError(message: "Only skillset list prints JSON. export already writes it.", usage: true)
    }
    let rest = Array(args.positional.dropFirst())
    switch action {
    case "list": try skillsetList(args)
    case "show": try skillsetShow(try one(rest, "skillset", example: "show Engineer"))
    case "apply": try skillsetApply(try one(rest, "skillset", example: "apply Engineer --to claude"), args: args, assign: true)
    case "unassign": try skillsetApply(try one(rest, "skillset", example: "unassign Engineer --from claude"), args: args, assign: false)
    case "export": try skillsetExport(try one(rest, "skillset", example: "export Engineer --output engineer.json"), args: args)
    case "import": try skillsetImport(try one(rest, "file", example: "import engineer.json"))
    default: throw CLIError(message: "There's no skillset \(action) action. Use list, show, apply, unassign, export or import.", usage: true)
    }
  }

  private static func one(_ values: [String], _ what: String, example: String) throws -> String {
    guard values.count == 1 else {
      throw CLIError(message: "Pass one \(what), like: skillscout-mod skillset \(example)", usage: true)
    }
    return values[0]
  }

  private static func find(_ name: String, in state: SkillsetState) throws -> Skillset {
    if let skillset = state.skillsets.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
      return skillset
    }
    let names = state.skillsets.map(\.name).sorted()
    throw CLIError(message: names.isEmpty
      ? "There are no skillsets yet. Create one in the app or with skillscout-mod skillset import."
      : "There's no skillset called \(name). Use one of: \(names.formatted(.list(type: .or))).")
  }

  /// The app keeps its state in memory and saves over the file, so changes wait until it's closed.
  private static func refuseWhileAppRuns() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", "Skillscout Mod"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus == 0 {
      throw CLIError(message: "Skillscout Mod is open, and it would save over this change. Quit the app and run this again, or make the change in the app.")
    }
  }

  private static func skillsetList(_ args: Arguments) throws {
    let state = try SkillsetState.load()
    if args.json {
      struct Row: Encodable { let name: String; let skills: [String]; let tools: [String] }
      try printJSON(state.skillsets.map { set in
        Row(name: set.name, skills: set.skills.sorted(),
            tools: state.assignments.filter { $0.skillsetID == set.id }.map(\.tool.rawValue).sorted())
      })
      return
    }
    guard !state.skillsets.isEmpty else {
      print("No skillsets yet. Create one in the app, or import one with skillscout-mod skillset import <file>.")
      return
    }
    let width = min(state.skillsets.map(\.name.count).max() ?? 0, 32)
    for set in state.skillsets.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
      let assignments = state.assignments.filter { $0.skillsetID == set.id }.sorted { $0.tool.rawValue < $1.tool.rawValue }
      let tools = assignments.map { a in Terminal.tint(a.tool.name, a.tool) + (a.members != set.skills ? Terminal.warn(" (changes pending)") : "") }
      print("\(Terminal.bold(Terminal.pad(set.name, width)))  \(Terminal.padLeft(plural(set.skills.count, "skill"), 9))  \(tools.isEmpty ? Terminal.dim("not assigned") : tools.joined(separator: Terminal.dim(", ")))")
    }
  }

  private static func skillsetShow(_ name: String) throws {
    let state = try SkillsetState.load()
    let set = try find(name, in: state)
    let skills = SkillScanner.scan()
    let assignments = state.assignments.filter { $0.skillsetID == set.id }.sorted { $0.tool.rawValue < $1.tool.rawValue }
    print(Terminal.bold(set.name))
    print(assignments.isEmpty ? Terminal.dim("Not assigned to a tool.")
      : "Assigned to \(assignments.map { Terminal.tint($0.tool.name, $0.tool) }.joined(separator: Terminal.dim(", ")))")
    print()
    for id in set.skills.sorted() {
      guard let skill = skills.first(where: { $0.id == id }) else {
        print("  \(Terminal.warn("missing"))  \(id)")
        continue
      }
      let marks = assignments.map { $0.tool }.map { tool in
        skill.availableIn.contains(tool) ? Terminal.tint("●", tool) : Terminal.dim("·")
      }.joined(separator: " ")
      print("  \(marks.isEmpty ? "" : marks + "  ")\(skill.name)")
    }
    for assignment in assignments where assignment.members != set.skills {
      print()
      print(Terminal.warn("Changes pending for \(assignment.tool.name). Run skillscout-mod skillset apply \(set.name) --to \(assignment.tool.rawValue)."))
    }
    for (tool, issues) in state.issues.sorted(by: { $0.key < $1.key }) where !issues.isEmpty && assignments.contains(where: { $0.tool.rawValue == tool }) {
      print()
      print(Terminal.warn("Unresolved for \(tool):"))
      for issue in issues { print("  \(issue)") }
    }
  }

  private static func skillsetApply(_ name: String, args: Arguments, assign: Bool) throws {
    var state = try SkillsetState.load()
    let set = try find(name, in: state)
    guard let tool = try args.tool(assign ? "to" : "from") else {
      throw CLIError(message: assign ? "Pick the tool: --to <tool>." : "Pick the tool: --from <tool>.", usage: true)
    }
    var proposed = state.assignments.filter { !($0.skillsetID == set.id && $0.tool == tool) }
    if assign { proposed.append(SkillsetAssignment(skillsetID: set.id, tool: tool, members: set.skills)) }
    let skills = SkillScanner.scan()
    let plan = SkillInstaller.skillsetPlan(tool: tool, assignments: proposed, entries: state.entries,
      skills: skills, preferredSources: state.preferredSources)

    print(Terminal.bold("\(assign ? "Apply" : "Unassign") \(set.name) \(assign ? "to" : "from") \(tool.name)"))
    print("Add \(plan.additions.count) · Keep \(plan.kept) existing · Remove up to \(plan.removals.count)")
    var flagged = false
    for skill in plan.additions {
      let source = SkillInstaller.skillsetSource(skill, preferredSources: state.preferredSources)
      let review = source.flatMap { SkillInstaller.isFromLibrary($0) ? SkillReview.inspect($0.resolved) : nil }
      if let review, review.needsReview {
        flagged = true
        print("  + \(skill.name)  \(Terminal.warn(review.summary.lowercased()))")
        printReview(review)
      } else {
        print("  + \(skill.name)")
      }
    }
    for entry in plan.removals { print("  - \(entry.skillID)") }
    for issue in plan.issues { print("  \(Terminal.warn(issue))") }
    let current = state.assignments.first { $0.skillsetID == set.id && $0.tool == tool }
    let settled = assign ? current?.members == set.skills : current == nil
    if plan.additions.isEmpty && plan.removals.isEmpty && settled {
      print("Nothing to change.")
      return
    }
    print("Other assigned skillsets keep the skills they need. Existing personal installations and modified copies stay.")
    if flagged { print(Terminal.warn("Some skills come from downloaded repositories and have scripts or high-risk commands.")) }
    try refuseWhileAppRuns()
    guard try confirm(assign ? "Apply it?" : "Unassign it?", args) else {
      print("Nothing changed.")
      return
    }

    state.assignments = proposed
    try state.save()
    var entries = state.entries
    let result = SkillInstaller.reconcileSkillsets(tool: tool, assignments: proposed, entries: &entries,
      skills: skills, preferredSources: state.preferredSources) { updated in
      state.entries = updated
      return (try? state.save()) != nil
    }
    state.issues[tool.rawValue] = result.issues
    try state.save()
    for note in result.notes { print(Terminal.dim(note)) }
    for issue in result.issues { print(Terminal.warn(issue)) }
    print(result.issues.isEmpty ? "Done." : "Done, with \(plural(result.issues.count, "item")) to retry.")
  }

  private static func skillsetExport(_ name: String, args: Arguments) throws {
    let state = try SkillsetState.load()
    let set = try find(name, in: state)
    let data = try SkillsetFile(set, skills: SkillScanner.scan(), preferredSources: state.preferredSources).encoded()
    if let output = args.option("output") {
      let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
      try (data + Data("\n".utf8)).write(to: url, options: .atomic)
      print("Saved \(set.name) to \(Paths.abbreviate(url))")
    } else {
      FileHandle.standardOutput.write(data)
      print()
    }
  }

  private static func skillsetImport(_ path: String) throws {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let file = try SkillsetFile.decode(Data(contentsOf: url))
    try refuseWhileAppRuns()
    var state = try SkillsetState.load()
    let name = SkillsetFile.availableName(file.name, among: state.skillsets)
    state.skillsets.append(Skillset(name: name, skills: Set(file.skills.map(\.name))))
    try state.save()
    print("Imported \(name) with \(plural(file.skills.count, "skill")). It isn't assigned to a tool yet.")
    let missing = file.missing(among: SkillScanner.scan())
    guard !missing.isEmpty else { return }
    print()
    print(Terminal.warn("\(plural(missing.count, "skill")) \(missing.count == 1 ? "isn't" : "aren't") on this Mac yet:"))
    for member in missing { print("  \(member.name)") }
    let sources = Array(Set(missing.compactMap(\.source))).sorted()
    if !sources.isEmpty {
      print()
      print("Add their repositories to the Library, then apply the skillset:")
      for source in sources { print("  skillscout-mod install \(source) --no-link") }
    }
  }
}
