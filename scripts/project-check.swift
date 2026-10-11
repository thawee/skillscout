import AppKit
import SwiftUI
import Observation

enum ProjectCheckFailure: Error { case failed(String) }

func projectCheck(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw ProjectCheckFailure.failed(message) }
  print("PASS: \(message)")
}

func projectFixtureSkill(_ folder: URL, name: String, body: String = "Fixture instructions") throws {
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  try "---\nname: \(name)\ndescription: Made-up project skill\n---\n\(body)\n".write(
    to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
}

@MainActor @Observable final class ProjectFilterFixture {
  var filter = ProjectSkillFilter()
  var selection: String? = "mixed-demo"
  var search = ""
}

struct ProjectFilterFixtureView: View {
  let project: RegisteredProject
  @Bindable var fixture: ProjectFilterFixture

  var body: some View {
    HStack(spacing: 0) {
      ProjectSkillListView(project: project, selection: $fixture.selection, filter: $fixture.filter, search: fixture.search)
        .frame(width: 300)
      Divider()
      ProjectDetailView(project: project, skillID: fixture.selection, filter: fixture.filter)
    }
  }
}

@main
enum ProjectCheck {
  @MainActor static func main() {
    let home = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    guard !FileManager.default.fileExists(atPath: home.path) else {
      fatalError("Project checks require a new made-up home")
    }
    setenv("HOME", home.path, 1)
    UserDefaults.standard.set(Tool.allCases.map(\.rawValue), forKey: "tools")
    UserDefaults.standard.set(false, forKey: "autoAnalyze")
    UserDefaults.standard.set(60, forKey: "lookbackDays")
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let host = NSHostingController(rootView: AnyView(EmptyView()))
    host.sceneBridgingOptions = [.toolbars, .title]
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 760),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.contentViewController = host
    window.center()
    _ = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
      object: nil, queue: .main) { _ in
      MainActor.assumeIsolated {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task {
          do {
            try await run(home: home, output: output, host: host, window: window)
            try "All functional checks passed.\n".write(to: output.appending(path: "result.txt"), atomically: true, encoding: .utf8)
          } catch {
            try? "FAILED: \(error)\n".write(to: output.appending(path: "result.txt"), atomically: true, encoding: .utf8)
            print("FAILED: \(error)")
          }
          NSApp.terminate(nil)
        }
      }
    }
    app.run()
  }

  @MainActor static func render(_ scenes: [(String, AnyView)], output: URL,
    host: NSHostingController<AnyView>, window: NSWindow) async throws {
    let manifest = output.appending(path: "render-manifest.json")
    let previous = (try? Data(contentsOf: manifest)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    try JSONEncoder().encode(previous + scenes.map { $0.0 }).write(to: manifest)
    for (name, view) in scenes {
      NSApp.appearance = NSAppearance(named: name.hasSuffix("-light") ? .aqua : .darkAqua)
      host.rootView = AnyView(view.id(name))
      window.setContentSize(CGSize(width: name.contains("narrow") ? 820 : name.contains("short") ? 900 : 1180, height: name.contains("short") ? 600 : 760))
      window.makeKeyAndOrderFront(nil)
      NSApp.activate()
      try await Task.sleep(for: .seconds(1))
      if name.contains("short") {
        func tables(_ view: NSView) -> [NSTableView] {
          if let table = view as? NSTableView { return [table] }
          return view.subviews.flatMap(tables)
        }
        let content = window.contentView!
        guard let list = tables(content).max(by: {
          $0.convert($0.bounds, to: content).minX < $1.convert($1.bounds, to: content).minX
        }), let scroll = list.enclosingScrollView else {
          throw ProjectCheckFailure.failed("Short window has no skill list")
        }
        try projectCheck(content.bounds.height <= 610, "\(name) keeps the requested short window height")
        try projectCheck(scroll.contentView.bounds.height >= 180, "\(name) leaves usable space for skill rows")
      }
      let content = window.contentView!.superview!
      let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
      content.cacheDisplay(in: content.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])!.write(to: output.appending(path: name + ".png"))
      print("PASS: rendered \(name)")
    }
  }

  @MainActor static func run(home: URL, output: URL,
    host: NSHostingController<AnyView>, window: NSWindow) async throws {
    let fm = FileManager.default
    try fm.createDirectory(at: output, withIntermediateDirectories: true)
    let firstFolder = home.appending(path: "workspaces/one/demo")
    let secondFolder = home.appending(path: "workspaces/two/demo")
    let childFolder = firstFolder.appending(path: "child")
    for folder in [firstFolder, secondFolder, childFolder] {
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let local = firstFolder.appending(path: ".agents/skills/local-demo")
    try projectFixtureSkill(local, name: "local-demo")
    try projectFixtureSkill(firstFolder.appending(path: ".claude/skills/claude-demo"), name: "claude-demo")
    let mixedLocal = firstFolder.appending(path: ".claude/skills/mixed-demo")
    try projectFixtureSkill(mixedLocal, name: "mixed-demo")
    let mixedGlobal = Paths.at(".codex/skills/mixed-demo")
    try projectFixtureSkill(mixedGlobal, name: "mixed-demo")
    try projectFixtureSkill(childFolder.appending(path: ".agents/skills/nested-demo"), name: "nested-demo")
    let global = Paths.at(".agents/skills/global-demo")
    try projectFixtureSkill(global, name: "global-demo")
    let globalBytes = try Data(contentsOf: global.appending(path: "SKILL.md"))
    for name in ["portable-demo", "overlap-demo", "editable-demo", "existing-demo", "direct-demo"] {
      try projectFixtureSkill(Paths.at(".config/skillscout/drafts/" + name), name: name)
    }
    let support = Paths.at(".config/skillscout/drafts/portable-demo/tools/verify.sh")
    try fm.createDirectory(at: support.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\nprintf 'fixture\\n'\n".write(to: support, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path)
    let existing = firstFolder.appending(path: ".agents/skills/existing-demo")
    try fm.copyItem(at: Paths.at(".config/skillscout/drafts/existing-demo"), to: existing)

    func chat(_ id: String, cwd: String?, skill: URL, daysAgo: Int = 0) throws {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let date = formatter.string(from: Date().addingTimeInterval(-Double(daysAgo) * 86400))
      var metadata: [String: Any] = ["id": id]
      if let cwd { metadata["cwd"] = cwd }
      let lines: [[String: Any]] = [
        ["type": "session_meta", "payload": metadata],
        ["type": "response_item", "timestamp": date, "payload": ["type": "function_call", "name": "exec_command", "arguments": "cat \(skill.appending(path: "SKILL.md").path)"]],
      ]
      let file = Paths.at(".codex/sessions/" + id + ".jsonl")
      try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      let text = try lines.map { String(data: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)! }.joined(separator: "\n")
      try (text + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    try chat("first", cwd: firstFolder.path, skill: local)
    try chat("second", cwd: secondFolder.path, skill: global)
    try chat("nested", cwd: childFolder.path, skill: global)
    try chat("unknown", cwd: nil, skill: global)
    try chat("older", cwd: firstFolder.path, skill: global, daysAgo: 14)
    try chat("mixed-codex", cwd: firstFolder.path, skill: mixedGlobal)
    let claudeFile = Paths.at(".claude/projects/demo/mixed-claude.jsonl")
    try fm.createDirectory(at: claudeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    let claudeChat: [String: Any] = ["type": "assistant", "cwd": firstFolder.path,
      "sessionId": "mixed-claude", "timestamp": ISO8601DateFormatter().string(from: Date()),
      "message": ["content": [["type": "tool_use", "name": "Read", "input": ["file_path": mixedLocal.appending(path: "SKILL.md").path]]]]]
    var claudeData = try JSONSerialization.data(withJSONObject: claudeChat, options: [.withoutEscapingSlashes])
    claudeData.append(0x0A)
    try claudeData.write(to: claudeFile)

    let store = AppStore()
    await store.start()
    guard let first = store.registerProject(firstFolder), let second = store.registerProject(secondFolder),
          let child = store.registerProject(childFolder) else { throw ProjectCheckFailure.failed("Register fixtures: \(store.errorMessage ?? "unknown error")") }
    try projectCheck(store.registerProject(firstFolder)?.id == first.id, "registering the same folder reuses its identity")
    await store.refreshProjectInventories()
    for _ in 0..<100 {
      if [first.id, second.id, child.id].allSatisfy({ store.projectInventories[$0] != nil }) { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    try projectCheck(first.id != second.id && first.name == second.name, "same-name projects have distinct identities")
    try projectCheck(store.projectInventories[first.id]?.skills.contains { $0.name == "local-demo" && !$0.localCopies.isEmpty } == true, "local skills appear in project inventory")
    try projectCheck(store.projectInventories[first.id]?.skills.contains { $0.name == "global-demo" && $0.localCopies.isEmpty && !$0.globalTools.isEmpty } == true, "global availability is shown separately")
    try projectCheck(!store.skills.contains { $0.name == "local-demo" }, "project-local skills stay outside global inventory")
    try projectCheck(store.projectUsage(first)["local-demo"]?.chats == 1, "recorded project usage resolves local skill paths")
    try projectCheck(store.projectUsage(first)["global-demo"]?.chats == 1, "parent excludes nested and unknown project histories")
    try projectCheck(store.projectUsage(second)["global-demo"]?.chats == 1, "same-name project chat stays separate")
    try projectCheck(store.projectUsage(child)["global-demo"]?.chats == 1, "nested registered project owns its own history")
    try projectCheck(store.projectUsage(first)["mixed-demo"]?.chats == 2, "all-agent project counts include Codex and Claude chats")
    try projectCheck(store.projectUsage(first, tool: .codex)["mixed-demo"]?.chats == 1, "Codex filter counts only Codex project chats")
    try projectCheck(store.projectUsage(first, tool: .claude)["mixed-demo"]?.chats == 1, "Claude filter counts only Claude project chats")
    let cursorFolder = String(secondFolder.path.drop { $0 == "/" }.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    let cursorChat = Paths.at(".cursor/projects/\(cursorFolder)/agent-transcripts/cursor-second.jsonl")
    try fm.createDirectory(at: cursorChat.deletingLastPathComponent(), withIntermediateDirectories: true)
    let cursorLine: [String: Any] = ["role": "assistant", "message": ["content": [["type": "tool_use", "name": "Read", "input": ["path": global.appending(path: "SKILL.md").path]]]]]
    var cursorData = try JSONSerialization.data(withJSONObject: cursorLine, options: [.withoutEscapingSlashes])
    cursorData.append(0x0A)
    try cursorData.write(to: cursorChat)
    await store.refreshPrompts()
    let cursorWasEnabled = store.tools.contains(.cursor)
    store.setTool(.cursor, enabled: true)
    try projectCheck(store.projectUsage(second, tool: .cursor)["global-demo"]?.chats == 1 && store.projectUsage(first, tool: .cursor)["global-demo"] == nil,
      "a Cursor chat counts for the project its folder name spells")
    store.setTool(.cursor, enabled: cursorWasEnabled)
    try fm.removeItem(at: Paths.at(".cursor/projects/\(cursorFolder)"))
    await store.refreshPrompts()
    let mixedRow = store.projectInventories[first.id]!.skills.first { $0.name == "mixed-demo" }!
    try projectCheck(!ProjectSkillFilter(tool: .codex, scope: .projectOnly).matches(mixedRow), "Codex project filter does not borrow global availability")
    try projectCheck(ProjectSkillFilter(tool: .claude, scope: .projectOnly).matches(mixedRow), "Claude project filter finds its project copy")
    try projectCheck(ProjectSkillFilter(tool: .claude, scope: .availableHere).matches(mixedRow), "available-here scope includes the selected agent project copy")
    store.setUsageScope(UsageScope(days: 7))
    try projectCheck(store.projectUsage(first)["global-demo"] == nil, "project counts respect the selected period")
    store.setTool(.codex, enabled: false)
    try projectCheck(store.projectUsage(first, tool: .codex).isEmpty, "selected disabled agent has zero project counts")
    try projectCheck(store.projectUsage(first)["mixed-demo"]?.chats == 1, "all-agent project counts keep enabled Claude history")
    try projectCheck(ProjectSkillFilter(tool: .codex, scope: .availableHere).matches(mixedRow), "disabled history leaves agent skill availability visible")
    store.setTool(.codex, enabled: true)
    store.setUsageScope(UsageScope())

    let base = Skillset(name: "Project essentials", skills: ["portable-demo", "overlap-demo", "editable-demo", "existing-demo"])
    let overlap = Skillset(name: "Shared checks", skills: ["overlap-demo"])
    store.skillsets = [base, overlap]
    guard let initial = store.projectPlan(first, skillsetID: base.id, target: .shared) else { throw ProjectCheckFailure.failed("Missing preview") }
    try projectCheck(initial.canApply, "project application preview permits compatible sources")
    try projectCheck(!fm.fileExists(atPath: firstFolder.appending(path: ".agents/skills/portable-demo").path), "preview makes no project writes")
    var trashed: [URL] = []
    defer { for url in trashed { try? fm.removeItem(at: url) } }
    trashed += await store.applyProjectPlan(initial)
    try projectCheck(store.projectState.pending == nil, "successful application clears the recovery journal")
    let installed = firstFolder.appending(path: ".agents/skills/portable-demo")
    try projectCheck(fm.fileExists(atPath: installed.appending(path: "tools/verify.sh").path), "project copies include supporting scripts")
    try projectCheck((try? fm.destinationOfSymbolicLink(atPath: installed.path)) == nil, "project installations are portable copies")
    try projectCheck(!store.projectState.entries.contains { $0.skillID == "existing-demo" }, "identical existing installation is kept without ownership")
    guard let shared = store.projectPlan(first, skillsetID: overlap.id, target: .shared) else { throw ProjectCheckFailure.failed("Missing overlap preview") }
    trashed += await store.applyProjectPlan(shared)
    try projectCheck(store.projectState.assignments.count == 2, "project supports overlapping applied skillsets")

    let scenes: [(String, AnyView)] = [
      ("projects", AnyView(ContentView(sidebar: .projects).environment(store))),
      ("projects-light", AnyView(ContentView(sidebar: .projects).environment(store))),
      ("projects-narrow", AnyView(ContentView(sidebar: .projects).environment(store))),
      ("workspace-library", AnyView(ContentView(sidebar: .library, skill: "portable-demo").environment(store))),
      ("workspace-global", AnyView(ContentView(sidebar: .global, skill: "mixed-demo", globalTool: .codex).environment(store))),
      ("workspace-global-light", AnyView(ContentView(sidebar: .global, skill: "mixed-demo", globalTool: .codex).environment(store))),
      ("workspace-global-narrow", AnyView(ContentView(sidebar: .global, skill: "mixed-demo", globalTool: .codex).environment(store))),
      ("workspace-global-all-short", AnyView(ContentView(sidebar: .global, skill: "global-demo").environment(store))),
      ("workspace-global-agent-short", AnyView(ContentView(sidebar: .global, skill: "mixed-demo", globalTool: .codex).environment(store))),
      ("project-overview", AnyView(ContentView(sidebar: .project(first.id)).environment(store))),
      ("project-overview-light", AnyView(ContentView(sidebar: .project(first.id)).environment(store))),
      ("project-overview-narrow", AnyView(ContentView(sidebar: .project(first.id)).environment(store))),
      ("project-local-skill", AnyView(ProjectDetailView(project: first, skillID: "local-demo").environment(store))),
      ("project-apply", AnyView(ProjectApplySheet(project: second, request: ProjectApplyRequest(skillsetID: base.id)).environment(store))),
      ("project-apply-light", AnyView(ProjectApplySheet(project: second, request: ProjectApplyRequest(skillsetID: base.id)).environment(store))),
    ]
    try await render(scenes, output: output, host: host, window: window)
    let templatesBeforeDirectAdd = store.skillsets
    let directRequest = SkillAddPresentation(skillIDs: ["direct-demo"], destination: .project(first.id), tool: .claude)
    try await render([("project-add-individual", AnyView(SkillAddFlowSheet(request: directRequest).environment(store)))],
      output: output, host: host, window: window)
    let continueKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
      characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    _ = window.performKeyEquivalent(with: continueKey)
    try await Task.sleep(for: .milliseconds(500))
    _ = window.performKeyEquivalent(with: continueKey)
    for _ in 0..<100 {
      if store.projectState.assignments.contains(where: { $0.projectID == first.id && $0.individualSkillID == "direct-demo" }) { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    let directCopy = firstFolder.appending(path: ".claude/skills/direct-demo")
    try projectCheck(fm.fileExists(atPath: directCopy.appending(path: "SKILL.md").path),
      "native Add skills Continue and Apply copies the individual skill into the current project")
    try projectCheck(store.projectState.assignments.contains { $0.projectID == first.id && $0.target == .claude && $0.individualSkillID == "direct-demo" },
      "individual addition defaults the selected Claude agent to its supported project group")
    try projectCheck(store.skillsets == templatesBeforeDirectAdd, "individual project addition creates no central skillset")
    let directRestored = AppStore()
    await directRestored.start()
    try projectCheck(directRestored.projectState.assignments.contains { $0.projectID == first.id && $0.individualSkillID == "direct-demo" },
      "individual project assignments survive app restart")
    let directRemovalRequest = ProjectApplyRequest(target: .claude, removeSkillID: "direct-demo")
    try await render([("project-remove-individual", AnyView(ProjectApplySheet(project: first, request: directRemovalRequest).environment(store)))],
      output: output, host: host, window: window)
    guard let directRemoval = store.projectRemoveSkillPlan(first, skillID: "direct-demo", target: .claude) else {
      throw ProjectCheckFailure.failed("Missing individual removal preview")
    }
    try projectCheck(directRemoval.changes.count == 1 && directRemoval.changes.allSatisfy { $0.skillID == "direct-demo" && $0.kind == .remove && $0.destinationPath.hasPrefix(firstFolder.path + "/") },
      "individual removal preview targets only the project copy")
    trashed += await store.applyProjectPlan(directRemoval)
    try projectCheck(!fm.fileExists(atPath: directCopy.path), "individual removal trashes its unchanged owned project copy")
    try projectCheck(fm.fileExists(atPath: Paths.at(".config/skillscout/drafts/direct-demo/SKILL.md").path),
      "individual project removal preserves its reusable Library source")
    try projectCheck(store.skillsets == templatesBeforeDirectAdd, "individual project removal preserves central skillset membership")
    let fixture = ProjectFilterFixture()
    let filterView = AnyView(ProjectFilterFixtureView(project: first, fixture: fixture).environment(store))
    host.rootView = filterView
    try await Task.sleep(for: .milliseconds(300))
    fixture.filter = ProjectSkillFilter(tool: .codex, scope: .projectOnly)
    try await Task.sleep(for: .milliseconds(300))
    try projectCheck(fixture.selection == nil, "changing the actual filter binding clears a hidden skill selection")
    try await render([("project-filter-codex-project-narrow", filterView)], output: output, host: host, window: window)
    fixture.filter = ProjectSkillFilter(tool: .claude, scope: .projectOnly)
    fixture.selection = "mixed-demo"
    try await render([("project-filter-claude-project-light", filterView)], output: output, host: host, window: window)
    fixture.filter = ProjectSkillFilter(tool: .codex, scope: .availableHere)
    try await render([("project-filter-codex-available-here", filterView)], output: output, host: host, window: window)
    store.setTool(.codex, enabled: false)
    try await render([("project-filter-disabled-history", filterView)], output: output, host: host, window: window)
    store.setTool(.codex, enabled: true)
    fixture.filter = ProjectSkillFilter(tool: .claude, scope: .projectOnly)
    fixture.search = "global-demo"
    try await render([("project-filter-empty", filterView)], output: output, host: host, window: window)
    fixture.search = ""
    fixture.filter = ProjectSkillFilter()
    fixture.selection = "local-demo"
    try await Task.sleep(for: .milliseconds(300))
    fixture.search = "claude-demo"
    try await Task.sleep(for: .milliseconds(300))
    try projectCheck(fixture.selection == nil, "changing the actual search binding clears a hidden skill selection")
    host.rootView = AnyView(ProjectApplySheet(project: second, request: ProjectApplyRequest(skillsetID: base.id)).environment(store))
    try await Task.sleep(for: .milliseconds(500))
    let applyKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
      characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    _ = window.performKeyEquivalent(with: applyKey)
    try await Task.sleep(for: .milliseconds(700))
    try projectCheck(store.projectState.assignments.contains { $0.projectID == second.id && $0.skillsetID == base.id },
      "native Apply keyboard action installs the reviewed project skillset")
    guard let removeSecond = store.projectPlan(second, skillsetID: base.id, target: .shared, unassign: true) else {
      throw ProjectCheckFailure.failed("Missing second-project unassign preview")
    }
    trashed += await store.applyProjectPlan(removeSecond)

    let editable = firstFolder.appending(path: ".agents/skills/editable-demo/SKILL.md")
    try "User changed these instructions\n".write(to: editable, atomically: true, encoding: .utf8)
    guard let unassign = store.projectPlan(first, skillsetID: base.id, target: .shared, unassign: true) else { throw ProjectCheckFailure.failed("Missing unassign preview") }
    trashed += await store.applyProjectPlan(unassign)
    try projectCheck(!fm.fileExists(atPath: installed.path), "unassign removes unchanged owned copies")
    try projectCheck(!trashed.isEmpty && trashed.allSatisfy { fm.fileExists(atPath: $0.path) }, "owned copies move to real macOS Trash")
    try projectCheck(fm.fileExists(atPath: editable.path), "unassign preserves modified owned content")
    try projectCheck(fm.fileExists(atPath: existing.path), "unassign preserves preexisting unowned content")
    try projectCheck(fm.fileExists(atPath: firstFolder.appending(path: ".agents/skills/overlap-demo").path), "overlapping assignment retains its shared member")

    store.skillsets.removeAll { $0.id == overlap.id }
    try projectCheck(store.projectState.assignments.contains { $0.skillsetID == overlap.id }, "deleted skillset retains its project snapshot")
    guard let removeDeleted = store.projectPlan(first, skillsetID: overlap.id, target: .shared, unassign: true) else { throw ProjectCheckFailure.failed("Deleted assignment cannot be unassigned") }
    trashed += await store.applyProjectPlan(removeDeleted)
    try projectCheck(!fm.fileExists(atPath: firstFolder.appending(path: ".agents/skills/overlap-demo").path), "deleted skillset can be explicitly unassigned")
    let globalAfter = try Data(contentsOf: global.appending(path: "SKILL.md"))
    try projectCheck(globalAfter == globalBytes, "project actions preserve global skill files")
    guard let claudePlan = store.projectPlan(first, skillsetID: base.id, target: .claude) else {
      throw ProjectCheckFailure.failed("Missing Claude target preview")
    }
    trashed += await store.applyProjectPlan(claudePlan)
    try projectCheck(store.projectState.assignments.contains { $0.projectID == first.id && $0.target == .claude },
      "Claude project target has its own applied assignment")
    try projectCheck(store.saveState(), "project state saves successfully")
    let restored = AppStore()
    await restored.start()
    try projectCheck(restored.projectState.projects == store.projectState.projects, "project registration survives restart")
    try projectCheck(restored.projectState.assignments == store.projectState.assignments, "project assignments survive restart")
    let partialStage = firstFolder.appending(path: ".agents/skills/.skillscout-stage-" + UUID().uuidString)
    try fm.createDirectory(at: partialStage, withIntermediateDirectories: true)
    try "Interrupted copy data\n".write(to: partialStage.appending(path: "partial.txt"), atomically: true, encoding: .utf8)
    let partial = ProjectPendingStep(skillID: "portable-demo", operation: .install, phase: .prepared,
      destinationPath: installed.path, sourcePath: Paths.at(".config/skillscout/drafts/portable-demo").path,
      stagePath: partialStage.path, stageIdentity: try ProjectDirectoryIdentity.read(at: partialStage),
      expectedFingerprint: try SkillInstaller.projectFingerprint(Paths.at(".config/skillscout/drafts/portable-demo")),
      previousReceipt: nil)
    restored.projectState.pending = ProjectPendingJournal(projectID: first.id, target: .shared,
      previousAssignments: restored.projectState.assignments.filter { $0.projectID == first.id && $0.target == .shared },
      proposedAssignments: [ProjectSkillsetAssignment(projectID: first.id, skillsetID: base.id, target: .shared, members: ["portable-demo"])],
      steps: [partial])
    try projectCheck(restored.saveState(), "pending project recovery state persists")
    restored.recoverProjects()
    try projectCheck(restored.projectState.pending != nil, "ambiguous partial staging remains protected")
    try await render([("project-recovery", AnyView(ContentView(sidebar: .project(first.id)).environment(restored)))],
      output: output, host: host, window: window)
    restored.abandonProjectRecovery()
    try projectCheck(restored.projectState.pending == nil, "explicit stop recovery permits project management again")
    try projectCheck(fm.fileExists(atPath: partialStage.appending(path: "partial.txt").path), "stopping recovery preserves partial copied files")

    let watched = secondFolder.appending(path: ".pi/skills/watched-demo")
    try projectFixtureSkill(watched, name: "watched-demo")
    try await Task.sleep(for: .seconds(4))
    try projectCheck(restored.projectInventories[second.id]?.skills.contains { $0.name == "watched-demo" } == true, "native file watcher discovers a new project skill root")
    try projectCheck(restored.forgetProject(second.id), "project registration can be forgotten")
    try projectCheck(fm.fileExists(atPath: watched.appending(path: "SKILL.md").path), "forgetting a project preserves every local file")
    try fm.moveItem(at: childFolder, to: firstFolder.appending(path: "moved-child"))
    await restored.refreshProjectInventories()
    try projectCheck(restored.projectInventories[child.id]?.status == .missing, "missing project status clears its old inventory")
    restored.projectState.pending = ProjectPendingJournal(projectID: child.id, target: .shared,
      previousAssignments: [], proposedAssignments: [], steps: [])
    try projectCheck(restored.saveState(), "missing-project recovery state persists")
    try await render([("project-missing", AnyView(ContentView(sidebar: .project(child.id)).environment(restored)))], output: output, host: host, window: window)
    restored.abandonProjectRecovery()
    try projectCheck(restored.projectState.pending == nil, "stopping recovery also works when the project folder is missing")
  }
}
