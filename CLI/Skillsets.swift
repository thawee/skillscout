import Foundation

extension Commands {
  static func skillset(_ args: Arguments) async throws {
    guard let action = args.positional.first else {
      throw CLIError(message: "Pick an action: list, show, apply, unassign, version, export or import.", usage: true)
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
    case "version": try await skillsetVersion(try one(rest, "skill", example: "version review --to cursor --use 2"), args: args)
    case "export": try skillsetExport(try one(rest, "skillset", example: "export Engineer --output engineer.json"), args: args)
    case "import": try skillsetImport(try one(rest, "file", example: "import engineer.json"))
    default: throw CLIError(message: "There's no skillset \(action) action. Use list, show, apply, unassign, version, export or import.", usage: true)
    }
  }

  private static func one(_ values: [String], _ what: String, example: String) throws -> String {
    guard values.count == 1 else {
      throw CLIError(message: "Pass one \(what), like: quartermaster skillset \(example)", usage: true)
    }
    return values[0]
  }

  private static func find(_ name: String, in state: SkillsetState) throws -> Skillset {
    if let skillset = state.skillsets.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
      return skillset
    }
    let names = state.skillsets.map(\.name).sorted()
    throw CLIError(message: names.isEmpty
      ? "There are no skillsets yet. Create one in the app or with quartermaster skillset import."
      : "There's no skillset called \(name). Use one of: \(names.formatted(.list(type: .or))).")
  }

  /// The app keeps its state in memory and saves over the file, so changes wait until it's closed.
  static func refuseWhileAppRuns() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", "Quartermaster"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus == 0 {
      throw CLIError(message: "Quartermaster is open, and it would save over this change. Quit the app and run this again, or make the change in the app.")
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
      print("No skillsets yet. Create one in the app, or import one with quartermaster skillset import <file>.")
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
      print(Terminal.warn("Changes pending for \(assignment.tool.name). Run quartermaster skillset apply \(set.name) --to \(assignment.tool.rawValue)."))
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
    let plan = SkillInstaller.skillsetPlans(tools: [tool], assignments: proposed, entries: state.entries,
      skills: skills, preferences: state.sourcePreferences)[tool] ?? SkillsetPlan()

    print(Terminal.bold("\(assign ? "Apply" : "Unassign") \(set.name) \(assign ? "to" : "from") \(tool.name)"))
    print("Add \(plan.additions.count) · Keep \(plan.kept) existing · Remove up to \(plan.removals.count)"
      + (plan.skipped.isEmpty ? "" : " · Skip \(plan.skipped.count)"))
    var flagged = false
    for skill in plan.additions {
      let source = SkillInstaller.skillsetSource(skill, for: tool, preferences: state.sourcePreferences)
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
    for skill in plan.skipped { print(Terminal.dim("  skip \(skill), set to skip \(tool.name)")) }
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
      skills: skills, preferences: state.sourcePreferences) { updated in
      state.entries = updated
      return (try? state.save()) != nil
    }
    state.issues[tool.rawValue] = result.issues
    try state.save()
    for note in result.notes { print(Terminal.dim(note)) }
    for issue in result.issues { print(Terminal.warn(issue)) }
    print(result.issues.isEmpty ? "Done." : "Done, with \(plural(result.issues.count, "item")) to retry.")
  }

  /// Lists a skill's versions and the one each agent gets, or with --to and --use, saves one agent's version or skip.
  private static func skillsetVersion(_ name: String, args: Arguments) async throws {
    let library = await Library.load(days: args.days, readChats: false)
    let skill = try library.skill(named: name)
    let versions = SkillVersions.versions(of: skill)
    var state = try SkillsetState.load()
    let tool = try args.tool("to")
    guard (tool == nil) == (args.option("use") == nil) else {
      throw CLIError(message: "Pass --to <tool> and --use <number, none or skip> together.", usage: true)
    }
    guard let tool, let use = args.option("use") else {
      printVersions(skill, versions: versions, preferences: state.sourcePreferences, skills: library.skills)
      return
    }
    guard versions.count > 1 else {
      throw CLIError(message: "\(skill.name) has one version, so every agent gets it.")
    }
    var preferences = state.sourcePreferences
    var choices = preferences.byTool[skill.id] ?? [:]
    var skipped = preferences.skipped[skill.id] ?? []
    choices[tool] = nil
    skipped.remove(tool)
    switch use {
    case "none": break
    case "skip": skipped.insert(tool)
    default:
      guard let number = Int(use), versions.indices.contains(number - 1) else {
        throw CLIError(message: "--use takes a version number from 1 to \(versions.count), none or skip.", usage: true)
      }
      choices[tool] = versions[number - 1][0].resolved.path
    }
    preferences.byTool[skill.id] = choices.isEmpty ? nil : choices
    preferences.skipped[skill.id] = skipped.isEmpty ? nil : skipped
    let choice = SkillVersions.savedChoice(for: skill, preferences: preferences)
    if use != "none", let leaders = SkillVersions.resolve(choice)[tool]?.follows, !leaders.isEmpty {
      throw CLIError(message: "Nothing changed, since \(tool.name) reads the skills folder of \(leaders.map(\.name).formatted()) and gets its version. Choose for \(leaders[0].name) instead.")
    }
    let problems = SkillVersions.choiceProblems(for: skill, choice: choice, skills: library.skills)
    if !problems.isEmpty {
      throw CLIError(message: "Nothing changed, since \(Set(problems.values.joined()).sorted().joined(separator: " ")) Choose another version or skip that agent.")
    }
    try refuseWhileAppRuns()
    state.sourcePreferences = preferences
    try state.save()
    switch use {
    case "none": print("\(tool.name) has no saved version of \(skill.name).")
    case "skip": print("Skillsets skip \(skill.name) for \(tool.name).")
    default: print("\(tool.name) gets version \(use), \(SkillVersions.titles(for: skill)[Int(use)! - 1]).")
    }
  }

  private static func printVersions(_ skill: Skill, versions: [[SkillCopy]], preferences: SourcePreferences, skills: [Skill]) {
    guard versions.count > 1 else {
      print("\(skill.name) has \(versions.isEmpty ? "no copy agents can add" : "one version"), so there's nothing to choose.")
      return
    }
    let titles = SkillVersions.titles(for: skill)
    print(Terminal.bold("\(skill.name) has \(versions.count) versions"))
    for (index, version) in versions.enumerated() {
      print("  \(index + 1). \(titles[index])  \(Terminal.dim("\(version[0].sourceLabel) · \(Paths.abbreviate(version[0].resolved))"))")
    }
    let tools = Tool.enabled
    let saved = SkillVersions.savedChoice(for: skill, preferences: preferences)
    let resolved = SkillVersions.resolve(saved)
    let suggested = SkillVersions.suggestedChoice(for: skill, tools: tools, skills: skills, keeping: saved)
    for tool in tools {
      let version = resolved[tool]?.version
      let label: String
      if let leaders = resolved[tool]?.follows, !leaders.isEmpty {
        label = version.map { "version \($0 + 1), same as \(leaders.map(\.name).formatted())" }
          ?? Terminal.warn("reads \(leaders.map(\.name).formatted()), which get different versions")
      } else if saved.skipped.contains(tool) {
        label = "skipped"
      } else if let own = saved.own[tool] {
        label = "version \(own + 1)"
      } else if let version {
        label = "version \(version + 1), the preferred source"
      } else {
        label = suggested.own[tool].map { Terminal.dim("not chosen, version \($0 + 1) suggested") } ?? Terminal.warn("not chosen")
      }
      print("  \(Terminal.tint(tool.name, tool))  \(label)")
    }
    for problem in Set(SkillVersions.choiceProblems(for: skill, choice: saved, skills: skills).values.joined()).sorted() {
      print("  \(Terminal.warn(problem))")
    }
    print(Terminal.dim("Choose with: quartermaster skillset version \(skill.name) --to <tool> --use <number, none or skip>"))
  }

  private static func skillsetExport(_ name: String, args: Arguments) throws {
    let state = try SkillsetState.load()
    let set = try find(name, in: state)
    let export = SkillsetFile.export(set, skills: SkillScanner.scan(), preferences: state.sourcePreferences)
    let data = try export.file.encoded()
    defer {
      // Notes go to standard error, so a file written to standard output stays valid JSON.
      for note in export.unwritten { FileHandle.standardError.write(Data((Terminal.warn("Not in the file: \(note)") + "\n").utf8)) }
    }
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
    let installed = SkillScanner.scan()
    let unmatched = file.applyVersionChoices(to: &state.sourcePreferences, skills: installed)
    try state.save()
    print("Imported \(name) with \(plural(file.skills.count, "skill")). It isn't assigned to a tool yet.")
    for note in unmatched { print(Terminal.warn(note)) }
    for difference in file.versionDifferences(among: installed, preferences: state.sourcePreferences) { print(Terminal.warn(difference)) }
    let missing = file.missing(among: installed)
    guard !missing.isEmpty else { return }
    print()
    print(Terminal.warn("\(plural(missing.count, "skill")) \(missing.count == 1 ? "isn't" : "aren't") on this Mac yet:"))
    for member in missing { print("  \(member.name)") }
    let sources = Array(Set(missing.compactMap(\.source))).sorted()
    if !sources.isEmpty {
      print()
      print("Add their repositories to the Library, then apply the skillset:")
      for source in sources { print("  quartermaster install \(source) --no-link") }
    }
  }
}
