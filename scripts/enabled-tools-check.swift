import AppKit
import SwiftUI
import Vision
import Observation

@MainActor @Observable final class EnabledToolsFixture {
  var filter = ProjectSkillFilter(tool: .gemini)
  var skill: String?
}

enum EnabledToolsFailure: Error { case failed(String) }

func enabledToolsCheck(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  guard try condition() else { throw EnabledToolsFailure.failed(message) }
  print("PASS: \(message)")
}

@main enum EnabledToolsCheck {
  @MainActor static func main() {
    let home = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    guard !FileManager.default.fileExists(atPath: home.path) else { fatalError("A new made-up home is required") }
    setenv("HOME", home.path, 1)
    UserDefaults.standard.set(Tool.allCases.map(\.rawValue), forKey: "tools")
    UserDefaults.standard.set(false, forKey: "autoAnalyze")
    UserDefaults.standard.set(60, forKey: "lookbackDays")
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let host = NSHostingController(rootView: AnyView(EmptyView()))
    host.sizingOptions = []
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 820, height: 800),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Skillscout enabled tool checks"
    window.contentViewController = host
    window.center()
    _ = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
      object: nil, queue: .main) { _ in
      MainActor.assumeIsolated {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task {
          do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            if CommandLine.arguments.contains("--global-counts-only") {
              try await runGlobalCounts(output: output, host: host, window: window)
            } else if CommandLine.arguments.contains("--skillset-scope-only") {
              try await runSkillsetScope(output: output, host: host, window: window)
            } else if CommandLine.arguments.contains("--manage-only") {
              try await runManage(home: home, output: output, host: host, window: window)
            } else if CommandLine.arguments.contains("--system-only") {
              try await runSystem(output: output, host: host, window: window)
            } else if CommandLine.arguments.contains("--providers-only") {
              try await runProviders(output: output, host: host, window: window)
            } else {
              try await run(home: home, output: output, host: host, window: window)
            }
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

  @MainActor static func elements(in windows: [NSWindow]? = nil) -> [any NSAccessibilityProtocol] {
    var pending: [Any] = windows ?? NSApp.windows.filter(\.isVisible)
    var seen: Set<ObjectIdentifier> = []
    var result: [any NSAccessibilityProtocol] = []
    var rawTypes = 0
    while let object = pending.popLast(), seen.count < 3000 {
      guard seen.insert(ObjectIdentifier(object as AnyObject)).inserted else { continue }
      guard let element = object as? any NSAccessibilityProtocol else {
        if rawTypes < 10 { print("INFO: raw accessibility child type \(type(of: object))") }
        rawTypes += 1
        continue
      }
      result.append(element)
      pending.append(contentsOf: element.accessibilityChildren() ?? [])
    }
    return result
  }

  @MainActor static func find(_ identifier: String) -> (any NSAccessibilityProtocol)? {
    let matches = elements().filter { $0.accessibilityIdentifier() == identifier }
    return matches.first { $0.accessibilityRole() == .button } ?? matches.first
  }

  @MainActor static func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }

  @MainActor static func resize(_ window: NSWindow, width: CGFloat, height: CGFloat) {
    let size = CGSize(width: width, height: height)
    window.contentMinSize = size
    window.contentMaxSize = size
    window.setContentSize(size)
  }

  @MainActor static func diagnostic(_ elements: [any NSAccessibilityProtocol]) -> String {
    elements.prefix(120).map {
      "id=\($0.accessibilityIdentifier() ?? "nil") role=\($0.accessibilityRole()?.rawValue ?? "nil") label=\($0.accessibilityLabel() ?? "nil") frame=\($0.accessibilityFrame())"
    }.joined(separator: "; ")
  }

  @MainActor static func recognized(_ window: NSWindow, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> [VNRecognizedTextObservation] {
    guard let content = window.contentView?.superview,
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(content.bounds.width * 3), pixelsHigh: Int(content.bounds.height * 3),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
      throw EnabledToolsFailure.failed("Cannot inspect native window text")
    }
    bitmap.size = content.bounds.size
    content.cacheDisplay(in: content.bounds, to: bitmap)
    guard let cgImage = bitmap.cgImage else { throw EnabledToolsFailure.failed("Cannot inspect native window image") }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.customWords = Tool.allCases.map(\.shortName) + ["All agents", "demo", "Archive", "Available here", "Project only"]
    request.recognitionLanguages = ["en-US"]
    request.minimumTextHeight = 0.005
    request.regionOfInterest = region
    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
    return request.results ?? []
  }

  @MainActor static func textFrame(_ title: String, window: NSWindow, region: CGRect? = nil, exact: Bool = false) throws -> CGRect? {
    guard let content = window.contentView?.superview else { return nil }
    let agentLabel = Tool.allCases.contains { $0.shortName == title }
    let pattern = title.lowercased().map { character in
      character == "i" || character == "l" ? "[il1]" : NSRegularExpression.escapedPattern(for: String(character))
    }.joined()
    var recognitionRegions = [CGRect(x: 0, y: 0, width: 1, height: 1)]
    if agentLabel && title.count <= 2 {
      recognitionRegions += stride(from: 0.0, through: 0.8, by: 0.2).flatMap { x in
        stride(from: 0.0, through: 0.8, by: 0.1).map { y in
          CGRect(x: x, y: y, width: min(0.25, 1 - x), height: 0.2)
        }
      }
    }
    for recognitionRegion in recognitionRegions {
      for observation in try recognized(window, region: recognitionRegion) {
        guard let candidate = observation.topCandidates(10).first(where: {
          $0.string.range(of: title, options: .caseInsensitive) != nil ||
            (agentLabel && $0.string.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil)
        }) else { continue }
        guard let range = candidate.string.range(of: title, options: .caseInsensitive) ??
          (agentLabel ? candidate.string.range(of: pattern, options: [.regularExpression, .caseInsensitive]) : nil) else { continue }
        if exact && candidate.string.trimmingCharacters(in: .letters.inverted).lowercased() != title.lowercased() { continue }
        let before = candidate.string[..<range.lowerBound].last
        let after = candidate.string[range.upperBound...].first
        guard before?.isLetter != true, after?.isLetter != true,
          let box = try candidate.boundingBox(for: range) else { continue }
        let rect = CGRect(x: (recognitionRegion.minX + box.boundingBox.minX * recognitionRegion.width) * content.bounds.width,
          y: (recognitionRegion.minY + box.boundingBox.minY * recognitionRegion.height) * content.bounds.height,
          width: box.boundingBox.width * recognitionRegion.width * content.bounds.width,
          height: box.boundingBox.height * recognitionRegion.height * content.bounds.height)
        if region == nil || region!.contains(CGPoint(x: rect.midX, y: rect.midY)) { return rect }
      }
    }
    return nil
  }

  @MainActor static func mouse(_ point: CGPoint, window: NSWindow) async throws {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
        throw EnabledToolsFailure.failed("Cannot create native mouse event")
      }
      NSApp.postEvent(event, atStart: false)
    }
    try await settle()
  }

  @MainActor static func snapshot(_ name: String, output: URL, window: NSWindow) throws {
    guard let content = window.contentView?.superview,
      let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
      throw EnabledToolsFailure.failed("Cannot render \(name)")
    }
    content.cacheDisplay(in: content.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw EnabledToolsFailure.failed("Cannot encode \(name)")
    }
    try png.write(to: output.appending(path: name + ".png"))
    let manifest = output.appending(path: "render-manifest.json")
    let previous = (try? Data(contentsOf: manifest)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    try JSONEncoder().encode(previous + [name]).write(to: manifest)
    print("PASS: rendered \(name)")
  }

  @MainActor static func press(_ identifier: String, title: String, window: NSWindow) async throws {
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    try await settle()
    if let element = find(identifier), element.accessibilityPerformPress() {
      try await settle()
      return
    }
    var frame = try textFrame(title, window: window)
    if frame == nil, let outer = outerScrollView(window), let document = outer.documentView {
      let maximum = max(0, document.bounds.height - outer.contentView.bounds.height)
      for offset in stride(from: CGFloat(0), through: maximum, by: CGFloat(150)) {
        outer.contentView.scroll(to: CGPoint(x: 0, y: document.isFlipped ? offset : maximum - offset))
        outer.reflectScrolledClipView(outer.contentView)
        try await settle()
        frame = try textFrame(title, window: window)
        if frame != nil { break }
      }
    }
    guard let frame else {
      let observed = try recognized(window).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
      throw EnabledToolsFailure.failed("Missing native control \(title). Visible text \(observed)")
    }
    try await mouse(CGPoint(x: frame.midX, y: frame.midY), window: window)
  }

  @MainActor static func outerScrollView(_ window: NSWindow) -> NSScrollView? {
    func scrollViews(_ view: NSView) -> [NSScrollView] {
      var result = view.subviews.flatMap(scrollViews)
      if let scroll = view as? NSScrollView { result.append(scroll) }
      return result
    }
    return window.contentView.map(scrollViews)?.filter {
      ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height
    }.max { $0.frame.height < $1.frame.height }
  }

  @MainActor static func waitFor(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<40 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw EnabledToolsFailure.failed(message)
  }


  static func writeSkill(_ folder: URL, name: String) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "---\nname: \(name)\ndescription: Made-up enabled tools fixture\n---\nFixture instructions\n"
      .write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
  }

  static func writeChat(_ file: URL, project: String, date: Date, skill: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = formatter.string(from: date)
    let entries: [[String: Any]] = [
      ["type": "session_meta", "payload": ["cwd": "/fixture/\(project)"]],
      ["type": "response_item", "timestamp": timestamp, "payload": ["type": "message", "role": "user", "content": [["text": "Check the made-up usage fixture"]]]],
      ["type": "response_item", "timestamp": timestamp, "payload": ["type": "function_call", "arguments": "cat \(skill.appending(path: "SKILL.md").path)"]]
    ]
    var data = Data()
    for entry in entries {
      data.append(try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]))
      data.append(0x0A)
    }
    try data.write(to: file)
  }

  @MainActor static func visible(_ window: NSWindow) throws -> String {
    try recognized(window).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
  }

  @MainActor static func show(_ view: AnyView, name: String, width: CGFloat = 820, height: CGFloat = 800,
    output: URL, host: NSHostingController<AnyView>, window: NSWindow) async throws -> String {
    resize(window, width: width, height: height)
    host.rootView = AnyView(view.id(name))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    try await settle()
    try await settle()
    try snapshot(name, output: output, window: window)
    let text = try visible(window)
    print("INFO: visible \(name) \(text)")
    return text
  }

  @MainActor static func run(home: URL, output: URL, host: NSHostingController<AnyView>, window: NSWindow) async throws {
    let shared = Paths.at(".agents/skills/enabled-shared")
    let disabled = Tool.gemini.skillsFolder.appending(path: "disabled-only")
    let source = Paths.at(".config/skillscout/skills/library-source/library-only")
    let scopeFavored = Tool.codex.skillsFolder.appending(path: "scope-favored")
    try writeSkill(shared, name: "enabled-shared")
    try writeSkill(disabled, name: "disabled-only")
    try writeSkill(source, name: "library-only")
    try writeSkill(scopeFavored, name: "scope-favored")
    let recent = Date().addingTimeInterval(-86_400)
    let older = Date().addingTimeInterval(-21 * 86_400)
    for (name, project, date, skill) in [
      ("shared-recent", "FixtureAlpha", recent, shared),
      ("shared-older-one", "FixtureBeta", older, shared),
      ("shared-older-two", "FixtureBeta", older, shared),
      ("favored-one", "FixtureAlpha", recent, scopeFavored),
      ("favored-two", "FixtureAlpha", recent, scopeFavored)
    ] {
      try writeChat(Paths.at(".codex/sessions/\(name).jsonl"), project: project, date: date, skill: skill)
    }
    let store = AppStore()
    store.tools = [.codex, .gemini]
    await store.refreshSkills()
    await store.refreshPrompts()
    let sharedSkill = try require(store.skills.first { $0.name == "enabled-shared" }, "shared fixture scanned")
    let disabledSkill = try require(store.skills.first { $0.name == "disabled-only" }, "disabled fixture scanned")
    let librarySkill = try require(store.skills.first { $0.name == "library-only" }, "Library fixture scanned")
    let allReaders = sharedSkill.availableIn
    try enabledToolsCheck(allReaders.contains(.codex) && allReaders.contains(.gemini), "shared source records enabled and disabled readers")
    let global = AnyView(ContentView(sidebar: .global, globalTool: .gemini).environment(store))
    _ = try await show(global, name: "global-selected", width: 1180, output: output, host: host, window: window)
    store.setTool(.gemini, enabled: false)
    try await settle()
    let afterDisable = try visible(window)
    try snapshot("global-filter-cleared", output: output, window: window)
    try enabledToolsCheck(afterDisable.contains("enabled-shared"), "Global clears a disabled agent filter and shows enabled shared skills")
    try enabledToolsCheck(!afterDisable.contains("disabled-only"), "Global excludes a disabled-only skill")
    try enabledToolsCheck(!afterDisable.contains("library-only"), "Global excludes Library-only sources")
    let libraryFrame = try require(try textFrame("Library", window: window, region: CGRect(x: 0, y: 0, width: 230, height: (window.contentView?.superview?.bounds.height ?? 800) * 0.9)), "Library sidebar row found")
    let globalFrame = try require(try textFrame("Global", window: window, region: CGRect(x: 0, y: 0, width: 230, height: (window.contentView?.superview?.bounds.height ?? 800) * 0.9)), "Global sidebar row found")
    let projectFrame = try require(try textFrame("Projects", window: window, region: CGRect(x: 0, y: 0, width: 230, height: (window.contentView?.superview?.bounds.height ?? 800) * 0.9)), "Projects sidebar row found")
    print("INFO: sidebar frames Library \(libraryFrame) Global \(globalFrame) Projects \(projectFrame)")
    try enabledToolsCheck(libraryFrame.midY > globalFrame.midY && globalFrame.midY > projectFrame.midY, "sidebar places Library and Global above Projects")
    store.setUsageScope(UsageScope(project: "FixtureAlpha", days: 7))
    try enabledToolsCheck(store.usage[sharedSkill.id]?.chats == 1 && store.usage["scope-favored"]?.chats == 2,
      "fixture shared scope excludes the other project's older chats and reverses usage ranking")
    for tool in [Tool?.none, Tool?.some(.codex)] {
      let name = tool == nil ? "global-unfiltered-history" : "global-agent-unfiltered-history"
      let text = try await show(AnyView(ContentView(sidebar: .global, skill: sharedSkill.id, globalTool: tool).environment(store)),
        name: name, width: 1450, height: 1200, output: output, host: host, window: window)
      let header = try recognized(window, region: CGRect(x: 230 / 1450, y: 0.55, width: 400 / 1450, height: 0.4))
        .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
      try enabledToolsCheck(header.range(of: #"\b(Project|Period)\b"#, options: .regularExpression) == nil
        && find("search-choice.Project") == nil && find("choice.Period.All history") == nil,
        "\(name) omits Project and Period controls from its list and detail")
      try enabledToolsCheck(text.contains("Recorded use in the last 60 days") && text.contains("Used in 3 chats in the last 60 days"),
        "\(name) shows all loaded chats and the matching loaded-history description")
      let windowHeight = window.contentView?.superview?.bounds.height ?? 1200
      let sortFrame = try require(try textFrame("Use", window: window,
        region: CGRect(x: 230, y: windowHeight - 380, width: 201, height: 330)), "Global Use sort chip found")
      try await mouse(CGPoint(x: sortFrame.midX, y: sortFrame.midY), window: window)
      try snapshot(name + "-use-sort", output: output, window: window)
      let listRegion = CGRect(x: 230, y: 0, width: 201, height: window.contentView?.superview?.bounds.height ?? 1200)
      let sharedFrame = try require(try textFrame("enabled-shared", window: window, region: listRegion), "Global shared row found")
      let favoredFrame = try require(try textFrame("scope-favored", window: window, region: listRegion), "Global scope-favored row found")
      try enabledToolsCheck(sharedFrame.midY > favoredFrame.midY,
        "\(name) Use sorting follows all loaded chats despite restrictive stored scope")
    }
    store.setUsageScope(UsageScope(project: "FixtureBeta", days: 7))
    try await settle()
    try enabledToolsCheck(store.usage[sharedSkill.id] == nil && (try visible(window)).contains("Used in 3 chats in the last 60 days"),
      "Global detail stays unchanged when another view changes the shared project and period")
    let dashboard = try await show(AnyView(ReportsView(openSimilar: { _ in }).environment(store)), name: "dashboard-usage-controls",
      width: 1000, height: 1200, output: output, host: host, window: window)
    try enabledToolsCheck(dashboard.contains("Period") && dashboard.contains("Project"),
      "Dashboard retains Project and Period usage filters")
    try enabledToolsCheck(store.usageReport(scope: UsageScope(project: "FixtureBeta")).chats == 2
      && store.usageReport(scope: UsageScope(project: "FixtureBeta", days: 7)).chats == 0,
      "Dashboard report data respects project and period filters")
    try enabledToolsCheck(store.usageScope == UsageScope(project: "FixtureBeta", days: 7), "Dashboard filters preserve the shared usage scope")
    let sharedRow = try await show(AnyView(SkillRow(skill: sharedSkill).padding().environment(store)), name: "shared-row", width: 340, height: 160, output: output, host: host, window: window)
    try enabledToolsCheck(sharedRow.contains("Codex") && !sharedRow.contains("Gemini"), "normal badges show only enabled readers")
    let disabledRow = try await show(AnyView(SkillRow(skill: disabledSkill).padding().environment(store)), name: "disabled-only-row", width: 360, height: 170, output: output, host: host, window: window)
    try enabledToolsCheck(!disabledRow.contains("Codex") && !disabledRow.contains("Gemini") && disabledSkill.availableIn.intersection(store.tools).isEmpty, "disabled-only row has no enabled tool badges; exact availability caption verified in its render")
    let removal = try require(Removal.from(.codex, skills: [sharedSkill], selectedCount: 1), "shared removal fixture exists")
    let projected = removal.message(enabledTools: store.tools)
    try enabledToolsCheck(projected.contains("Codex") && projected.contains("disabled tools") && !projected.contains("Gemini"), "removal presentation discloses disabled shared readers without naming them")
    try enabledToolsCheck(removal.message().contains("Gemini") && removal.affectedTools == Tool.allCases.filter(allReaders.contains), "removal keeps its full operation impact and default message")
    let add = AnyView(SkillAddSheet(skillIDs: [librarySkill.id], initialTool: .codex).environment(store))
    let addText = try await show(add, name: "add-enabled", width: 680, height: 640, output: output, host: host, window: window)
    try enabledToolsCheck(addText.contains("Codex") && !addText.contains("Gemini"), "Add skills choices use enabled tools")
    try enabledToolsCheck(addText.contains("disabled tools"), "Add review discloses disabled readers of a shared destination")
    store.setTool(.codex, enabled: false)
    try await settle()
    let noAdd = try visible(window)
    try snapshot("add-cleared-after-settings", output: output, window: window)
    try enabledToolsCheck(noAdd.contains("Enable a tool in Settings") && !noAdd.contains("Affected agents"), "Add clears its selected target after Settings disables it")
    store.setTool(.codex, enabled: true)
    let projectFolder = home.appending(path: "FixtureProject")
    try writeSkill(projectFolder.appending(path: ".agents/skills/project-shared"), name: "project-shared")
    try writeSkill(projectFolder.appending(path: ".gemini/skills/project-disabled"), name: "project-disabled")
    let project = try require(store.registerProject(projectFolder), "made-up project registered")
    await store.refreshProjectInventories()
    let fixture = EnabledToolsFixture()
    let binding = Binding(get: { fixture.filter }, set: { fixture.filter = $0 })
    let selection = Binding(get: { fixture.skill }, set: { fixture.skill = $0 })
    _ = try await show(AnyView(ProjectSkillListView(project: project, selection: selection, filter: binding).environment(store)), name: "project-enabled", width: 460, output: output, host: host, window: window)
    try enabledToolsCheck(fixture.filter.tool == nil, "Project clears an initially disabled agent filter")
    let projectText = try visible(window)
    try enabledToolsCheck(projectText.contains("project-shared") && !projectText.contains("project-disabled"), "Project rows require an enabled reader")
    let apply = AnyView(ProjectApplySheet(project: project, request: ProjectApplyRequest(skillIDs: [librarySkill.id])).environment(store))
    let projectReview = try await show(apply, name: "project-review-enabled", width: 700, height: 700, output: output, host: host, window: window)
    try enabledToolsCheck(projectReview.contains("Codex") && projectReview.contains("disabled tools") && !projectReview.contains("Claude and"), "Project review projects badges and discloses full shared-folder effects")
    let staleUnassign = try await show(AnyView(ProjectApplySheet(project: project, request: ProjectApplyRequest(skillsetID: UUID(), target: .claude, unassign: true)).environment(store)), name: "project-disabled-unassign", width: 700, height: 700, output: output, host: host, window: window)
    try enabledToolsCheck(staleUnassign.contains("Enable a tool in Settings") && !staleUnassign.contains("Codex"), "disabled initial unassign target stays blocked without choosing another group")
    let staleRemove = try await show(AnyView(ProjectApplySheet(project: project, request: ProjectApplyRequest(target: .claude, removeSkillID: "project-shared")).environment(store)), name: "project-disabled-remove", width: 700, height: 700, output: output, host: host, window: window)
    try enabledToolsCheck(staleRemove.contains("Enable a tool in Settings") && !staleRemove.contains("Codex"), "disabled initial removal target stays blocked without choosing another group")
    _ = try await show(apply, name: "project-review-live", width: 700, height: 700, output: output, host: host, window: window)
    store.setTool(.codex, enabled: false)
    try await settle()
    try enabledToolsCheck(try visible(window).contains("Enable a tool in Settings"), "Project invalidates a preview when its target becomes disabled")
    try snapshot("project-review-disabled", output: output, window: window)
    store.setTool(.codex, enabled: true)
    let skillset = Skillset(name: "Fixture set", skills: [librarySkill.id])
    store.skillsets = [skillset]
    store.skillsetAssignments = [SkillsetAssignment(skillsetID: skillset.id, tool: .gemini, members: skillset.skills)]
    let assignment = try await show(AnyView(SkillsetAssignmentsSheet(skillsetID: skillset.id).environment(store)), name: "assignments-enabled", width: 620, height: 560, output: output, host: host, window: window)
    try enabledToolsCheck(assignment.contains("Codex") && assignment.contains("disabled tools are retained") && !assignment.contains("Gemini"), "assignment UI offers enabled tools and explains retained disabled assignments")
    try enabledToolsCheck(store.skillsetAssignments.first?.tool == .gemini && store.skillsetAssignments.first?.members == skillset.skills, "Settings changes retain disabled assignments")
    let examples = [Prompt(id: "enabled-evidence", tool: .codex, project: "Fixture", date: Date(), text: "Enabled request evidence"),
      Prompt(id: "disabled-evidence", tool: .gemini, project: "Fixture", date: Date(), text: "Disabled request evidence")]
    let idea = Suggestion(name: "fixture-idea", title: "Fixture idea", summary: "Fixture summary", why: "Fixture reason", examples: examples, createdAt: Date(), draft: "Fixture draft", savedTo: source.path, savedSkillID: librarySkill.id)
    let suggestion = try await show(AnyView(SuggestionDetail(suggestion: idea).environment(store)), name: "suggestion-enabled", width: 820, height: 1000, output: output, host: host, window: window)
    try enabledToolsCheck(suggestion.contains("Codex") && !suggestion.contains("Gemini") && !suggestion.contains("Disabled request evidence"), "saved suggestions and request evidence display enabled tools only")
    try enabledToolsCheck(idea.examples.count == 2, "saved evidence remains intact")
    let settings = try await show(AnyView(SettingsView().environment(store)), name: "settings-all-tools", width: 480, height: 1200, output: output, host: host, window: window)
    try enabledToolsCheck(settings.contains("Gemini") && settings.contains("Codex") && settings.contains("Claude"), "Settings keeps disabled tool toggles and AI engines available")
    let codexToggleRow = try require(try textFrame("Codex", window: window, exact: true), "Codex Settings row found")
    try await mouse(CGPoint(x: (window.contentView?.bounds.width ?? 480) - 43, y: codexToggleRow.midY), window: window)
    try enabledToolsCheck(!store.tools.contains(.codex), "native Settings toggle disables a selected skill tool")
    store.tools = []
    let noProject = try await show(AnyView(ProjectSkillListView(project: project, selection: selection, filter: binding).environment(store)), name: "project-no-tools", width: 460, output: output, host: host, window: window)
    try enabledToolsCheck(noProject.contains("No enabled tools") && noProject.contains("Open Settings"), "Project with no enabled tools explains Settings recovery")
    let noGlobal = try await show(AnyView(ContentView(sidebar: .global).environment(store)), name: "global-no-tools", width: 1180, output: output, host: host, window: window)
    try enabledToolsCheck(noGlobal.contains("No enabled tools") && noGlobal.contains("Open Settings"), "Global with no enabled tools explains Settings recovery")
    try enabledToolsCheck(!noGlobal.contains("enabled-shared") && !noGlobal.contains("disabled-only"), "Global with no enabled tools shows no installed skill rows")
    try enabledToolsCheck(sharedSkill.availableIn == allReaders && store.skillsetAssignments.count == 1, "presentation filters preserve reader metadata and assignment records")
  }

  @MainActor static func runGlobalCounts(output: URL, host: NSHostingController<AnyView>, window: NSWindow) async throws {
    func contains(_ text: String, _ expected: String) -> Bool {
      let pattern = expected.map { character in
        if character == "i" || character == "l" { return "[il1]" }
        if character == "0" { return "[0o]" }
        return NSRegularExpression.escapedPattern(for: String(character))
      }.joined()
      return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    UserDefaults.standard.set(false, forKey: "showSystemSkills")
    UserDefaults.standard.set("all", forKey: "skillSource")
    UserDefaults.standard.set("name", forKey: "skillSort")
    for (path, name) in [
      (".agents/skills/count-shared", "count-shared"),
      (".codex/skills/count-duplicate", "count-duplicate"),
      (".gemini/skills/count-duplicate", "count-duplicate"),
      (".codex/skills/count-personal", "count-personal"),
      (".codex/skills/.system/count-system", "count-system"),
      (".codex/skills/.system/count-mixed", "count-mixed"),
      (".gemini/skills/count-mixed", "count-mixed"),
      (".pi/agent/skills/count-disabled", "count-disabled"),
      (".config/skillscout/skills/fixture/count-library", "count-library"),
      (".config/skillscout/drafts/count-draft", "count-draft")
    ] { try writeSkill(Paths.at(path), name: name) }
    let provider = Paths.at(".codex/plugins/cache/fixture/count-provider/1.0")
    let manifest = provider.appending(path: ".codex-plugin/plugin.json")
    try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"name":"count-provider","version":"1.0"}"#.utf8).write(to: manifest)
    try writeSkill(provider.appending(path: "skills/count-plugin"), name: "count-plugin")
    let store = AppStore()
    store.tools = [.codex, .gemini, .claude, .amp]
    await store.refreshSkills()
    let duplicate = try require(store.skill("count-duplicate"), "duplicate identity fixture scanned")
    try enabledToolsCheck(duplicate.copies.count == 2 && store.skill("count-library")?.availableIn.isEmpty == true
      && store.skill("count-draft")?.availableIn.isEmpty == true, "fixture contains duplicate copies and readerless library and draft skills")
    let global = AnyView(ContentView(sidebar: .global).environment(store))
    let union = try await show(global, name: "global-counts-union", width: 1280, height: 1000, output: output, host: host, window: window)
    try enabledToolsCheck(contains(union, "5 skills available globally") && contains(union, "1 system skill"),
      "all enabled scope counts five unique ordinary identities and one system identity while systems are hidden")
    let headerRegion = CGRect(x: 230 / 1280.0, y: 0.6, width: 220 / 1280.0, height: 0.35)
    let header = try recognized(window, region: headerRegion).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    for (title, count) in [("All enabled agents", 5), ("Codex", 4), ("Gemini", 3), ("Claude", 0), ("Amp", 0)] {
      let digits = count == 0 ? "[0o]" : String(count)
      let pattern = NSRegularExpression.escapedPattern(for: title) + #"\s+"# + digits + #"\b"#
      try enabledToolsCheck(header.range(of: pattern, options: .regularExpression) != nil, "rendered \(title) chip shows \(count) ordinary skills")
    }
    try enabledToolsCheck(!union.contains("count-disabled") && !union.contains("count-library") && !union.contains("count-draft")
      && !header.contains("Pi"), "Global excludes disabled-only and readerless skills and disabled tool choices")
    try await press("choice.Agent.Codex", title: "Codex", window: window)
    let codex = try visible(window)
    try snapshot("global-counts-codex", output: output, window: window)
    try enabledToolsCheck(contains(codex, "4 skills available globally") && contains(codex, "2 system skills")
      && !codex.contains("count-mixed"), "real Codex selection classifies the mixed identity as system and hides it")
    try await press("choice.Show.Plugin", title: "Plugin", window: window)
    try await press("show-system-skills", title: "Show system skills", window: window)
    let contentHeight = window.contentView?.superview?.bounds.height ?? 1000
    let useFrame = try require(try textFrame("Use", window: window,
      region: CGRect(x: 230, y: contentHeight - 420, width: 201, height: 380)), "Global Use sort control found in its header")
    try await mouse(CGPoint(x: useFrame.midX, y: useFrame.midY), window: window)
    store.usageScope = UsageScope(project: "No fixture chats", days: 7)
    func searchField(in view: NSView) -> NSSearchField? {
      if let field = view as? NSSearchField { return field }
      return view.subviews.lazy.compactMap { searchField(in: $0) }.first
    }
    let searchRoots = [window.contentView?.superview].compactMap { $0 }
      + (window.toolbar?.items.compactMap(\.view) ?? [])
    let field = try require(searchRoots.lazy.compactMap { searchField(in: $0) }.first, "native toolbar search field found")
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    field.selectText(nil)
    try await settle()
    let editor = try require(field.currentEditor() as? NSTextView, "native search editor focused")
    editor.insertText("count-plugin", replacementRange: editor.selectedRange())
    try await settle()
    let filtered = try visible(window)
    try snapshot("global-counts-filtered", output: output, window: window)
    try enabledToolsCheck(contains(filtered, "4 skills available globally") && contains(filtered, "2 system skills")
      && filtered.contains("count-plugin") && !filtered.contains("count-personal"),
      "source search sort usage scope and system toggle leave inventory totals unchanged while filtering rows")
    editor.selectAll(nil)
    editor.insertText("", replacementRange: editor.selectedRange())
    try await settle()
    try await press("choice.Show.All skills", title: "All skills", window: window)
    try await press("choice.Agent.Gemini", title: "Gemini", window: window)
    let gemini = try visible(window)
    try snapshot("global-counts-gemini", output: output, window: window)
    try enabledToolsCheck(contains(gemini, "3 skills available globally") && contains(gemini, "0 system skills")
      && gemini.contains("count-mixed"), "real Gemini selection counts the mixed identity as ordinary and shows zero systems")
    store.setTool(.gemini, enabled: false)
    try await settle()
    let disabled = try visible(window)
    try snapshot("global-counts-settings-change", output: output, window: window)
    try enabledToolsCheck(contains(disabled, "4 skills available globally") && contains(disabled, "2 system skills")
      && !disabled.contains("Gemini"), "Settings disabling the selected reader clears its selection and recomputes the unique union")
    store.setTool(.codex, enabled: false)
    try await settle()
    let zero = try visible(window)
    try enabledToolsCheck(contains(zero, "0 skills available globally") && contains(zero, "0 system skills")
      && !zero.contains("Codex"), "remaining zero-count tools display empty inventory totals without stale selected readers")
    let narrow = AnyView(VStack(alignment: .leading, spacing: 28) {
      AgentChoices(tools: [.codex, .gemini, .claude, .amp], allTitle: "All enabled agents", selection: .constant(.codex),
        counts: [.codex: 4, .gemini: 3, .claude: 0, .amp: 0], allCount: 5)
      AgentChoices(title: "Default agent", tools: [.codex, .gemini], selection: .constant(nil))
    }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    let narrowText = try await show(narrow, name: "global-counts-narrow-and-default", width: 260, height: 500,
      output: output, host: host, window: window)
    try enabledToolsCheck(narrowText.contains("All enabled agents") && narrowText.contains("Claude") && narrowText.contains("Amp"),
      "counted agent choices wrap at narrow width and retain all tool labels")
    let defaultFrame = try require(try textFrame("Default agent", window: window), "default agent group found below counted choices")
    let height = window.contentView?.superview?.bounds.height ?? 500
    let defaultText = try recognized(window, region: CGRect(x: 0, y: 0, width: 1, height: defaultFrame.minY / height))
      .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    try enabledToolsCheck(defaultText.contains("Codex") && defaultText.contains("Gemini")
      && defaultText.range(of: #"\b(Codex|Gemini)\s+[0-9]+\b"#, options: .regularExpression) == nil,
      "default AgentChoices outside Global renders tool names without counts")
  }

  @MainActor static func runSkillsetScope(output: URL, host: NSHostingController<AnyView>, window: NSWindow) async throws {
    UserDefaults.standard.set("name", forKey: "skillSort")
    UserDefaults.standard.set("all", forKey: "skillSource")
    let totalFolder = Tool.codex.skillsFolder.appending(path: "zz-total")
    let recentFolder = Tool.codex.skillsFolder.appending(path: "aa-recent")
    try writeSkill(totalFolder, name: "zz-total")
    try writeSkill(recentFolder, name: "aa-recent")
    try writeSkill(Paths.at(".config/skillscout/skills/fixture/library-only"), name: "library-only")
    let linkedSource = Paths.at(".config/skillscout/skills/fixture/library-linked")
    try writeSkill(linkedSource, name: "library-linked")
    try FileManager.default.createSymbolicLink(at: Tool.codex.skillsFolder.appending(path: "library-linked"), withDestinationURL: linkedSource)
    try writeSkill(Paths.at(".config/skillscout/skills/fixture/library-twin"), name: "library-twin")
    try writeSkill(Paths.at(".config/skillscout/skills/repo-fixture/repo-skill"), name: "repo-skill")
    try "{}".write(to: Paths.at(".config/skillscout/skills/repo-fixture/.skillscout-repository.json"), atomically: true, encoding: .utf8)
    try writeSkill(Tool.codex.skillsFolder.appending(path: "library-twin"), name: "library-twin")
    let recent = Date().addingTimeInterval(-86_400)
    let older = Date().addingTimeInterval(-21 * 86_400)
    for (name, project, date, skill) in [
      ("total-recent", "FixtureAlpha", recent, totalFolder),
      ("total-old-one", "FixtureBeta", older, totalFolder),
      ("total-old-two", "FixtureBeta", older, totalFolder),
      ("recent-one", "FixtureAlpha", recent, recentFolder),
      ("recent-two", "FixtureAlpha", recent, recentFolder)
    ] {
      try writeChat(Paths.at(".codex/sessions/\(name).jsonl"), project: project, date: date, skill: skill)
    }
    let store = AppStore()
    store.tools = [.codex, .gemini]
    await store.refreshSkills()
    await store.refreshPrompts()
    let total = try require(store.skills.first { $0.name == "zz-total" }, "skillset total-history source scanned")
    let other = try require(store.skills.first { $0.name == "aa-recent" }, "skillset recent source scanned")
    let skillset = Skillset(name: "Scope fixture", skills: [total.id, other.id])
    store.skillsets = [skillset]
    store.setUsageScope(UsageScope(project: "FixtureAlpha", days: 7))
    try enabledToolsCheck(store.usage[total.id]?.chats == 1 && store.usage[other.id]?.chats == 2,
      "stored project and period reverse the all-history ranking")
    let text = try await show(AnyView(ContentView(sidebar: .skillset(skillset.id), skill: total.id, globalTool: .gemini).environment(store)),
      name: "skillset-all-loaded-history", width: 1450, height: 1200, output: output, host: host, window: window)
    try enabledToolsCheck(text.contains("Scope fixture") && text.contains("Edit") && text.contains("Add skills"), "Skillsets retains membership and destination actions")
    let header = try recognized(window, region: CGRect(x: 230 / 1450, y: 0.55, width: 400 / 1450, height: 0.4))
      .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    try enabledToolsCheck(header.range(of: #"\b(Project|Period)\b"#, options: .regularExpression) == nil
      && find("search-choice.Project") == nil && find("choice.Period.All history") == nil, "Skillsets list and detail omit Project and Period controls")
    try enabledToolsCheck(text.contains("Recorded use in the last 60 days") && text.contains("Used in 3 chats in the last 60 days"),
      "Skillsets ignores saved scope and stale Global agent for counts and labels")
    let height = window.contentView?.superview?.bounds.height ?? 1200
    let sortFrame = try require(try textFrame("Use", window: window, region: CGRect(x: 230, y: height - 380, width: 201, height: 330)), "Skillsets Use sort chip found")
    try await mouse(CGPoint(x: sortFrame.midX, y: sortFrame.midY), window: window)
    try snapshot("skillset-use-sort", output: output, window: window)
    let listRegion = CGRect(x: 230, y: 0, width: 201, height: height)
    let totalFrame = try require(try textFrame(total.name, window: window, region: listRegion), "Skillsets total row found")
    let recentFrame = try require(try textFrame(other.name, window: window, region: listRegion), "Skillsets recent row found")
    try enabledToolsCheck(totalFrame.midY > recentFrame.midY, "real Use sort orders members by all loaded history")
    store.setUsageScope(UsageScope(project: "FixtureBeta", days: 7))
    try await settle()
    try snapshot("skillset-after-scope-change", output: output, window: window)
    try enabledToolsCheck(store.usage[total.id] == nil && (try visible(window)).contains("Used in 3 chats in the last 60 days"),
      "Skillsets stays unchanged when another view changes saved filters")
    let standalone = try await show(AnyView(SkillDetail(skill: total, context: .skillset(skillset.id)).environment(store)),
      name: "skillset-standalone-detail", output: output, host: host, window: window)
    try enabledToolsCheck(standalone.contains("Used in 3 chats in the last 60 days") && find("search-choice.Project") == nil,
      "standalone Skillsets detail uses full history without an override")
    try enabledToolsCheck(standalone.contains("Member of \(skillset.name)") && !standalone.contains("Explain with AI") && !standalone.contains("Add skills"),
      "Skillsets detail leads with membership and omits installation and AI actions")
    let activity = try await show(AnyView(SkillDetail(skill: total, context: .activity).environment(store)),
      name: "activity-detail", height: 1200, output: output, host: host, window: window)
    try enabledToolsCheck(activity.contains("Usage") && activity.contains("Show SKILL.md") && !activity.contains("Explain with AI")
      && !activity.contains("Add skills") && !activity.contains("Rename") && !activity.contains("Skillsets"),
      "Chat activity detail leads with usage and hides editing, AI and membership")
    let stored = try require(store.skills.first { $0.name == "library-only" }, "Library fixture still scanned")
    let storedOutside = try await show(AnyView(SkillDetail(skill: stored, context: .activity).environment(store)),
      name: "library-storage-outside", height: 1200, output: output, host: host, window: window)
    try enabledToolsCheck(storedOutside.contains("Stored in Library") && !storedOutside.contains(".config/skillscout") && !storedOutside.contains("Open in editor"),
      "outside Library, Library storage is named, not shown, and its SKILL.md is read-only")
    let storedInside = try await show(AnyView(SkillDetail(skill: stored, context: .library).environment(store)),
      name: "library-storage-inside", height: 1200, output: output, host: host, window: window)
    try enabledToolsCheck(storedInside.contains(".config/skillscout") && storedInside.contains("Open in editor"),
      "Library shows its storage folder and opens SKILL.md")
    try enabledToolsCheck(storedInside.contains("Edit Open in editor"), "Library offers Edit for a skill moved into it")
    let repoSkill = try require(store.skills.first { $0.name == "repo-skill" }, "Library repository fixture scanned")
    let repoInside = try await show(AnyView(SkillDetail(skill: repoSkill, context: .library).environment(store)),
      name: "library-repository-inside", height: 1200, output: output, host: host, window: window)
    try enabledToolsCheck(repoInside.contains("Open in editor") && !repoInside.contains("Edit Open in editor") && !repoInside.contains("Rename"),
      "Library hides Edit and Rename for a repository skill, as its menu does")
    let linked = try require(store.skills.first { $0.name == "library-linked" }, "Library-linked fixture scanned")
    for (context, name) in [(SkillListContext.global(.codex), "library-linked-global"), (.skillset(skillset.id), "library-linked-skillset")] {
      let text = try await show(AnyView(SkillDetail(skill: linked, context: context).environment(store).environment(\.openInLibrary, { _ in })),
        name: name, height: 1400, output: output, host: host, window: window)
      try enabledToolsCheck(text.contains("Agents load this skill from Library") && text.contains("fixture/library-linked")
        && !text.contains(".config/skillscout") && !text.contains("Open in editor") && text.contains("Open in Library"),
        "\(name) names the Library behind the agent link and offers Open in Library instead of the stored file")
    }
    let preselected = try await show(AnyView(SkillAddFlowSheet(request: SkillAddPresentation(skillIDs: [total.id], destination: .global)).environment(store)),
      name: "add-flow-preselected", width: 700, height: 640, output: output, host: host, window: window)
    try enabledToolsCheck(preselected.contains("Selected skill") && preselected.contains(total.name) && preselected.contains("Change skills")
      && !preselected.contains("Find a skill"), "Add skills opened from a selection shows that selection instead of asking again")
    let unselected = try await show(AnyView(SkillAddFlowSheet(request: SkillAddPresentation(skillIDs: [], destination: .global)).environment(store)),
      name: "add-flow-empty", width: 700, height: 640, output: output, host: host, window: window)
    try enabledToolsCheck(unselected.contains("Find a skill"), "Add skills opened without a selection lists skills to choose")
    let twin = try require(store.skills.first { $0.name == "library-twin" }, "Library twin fixture scanned")
    let twinText = try await show(AnyView(SkillDetail(skill: twin, context: .global(.codex)).environment(store)),
      name: "library-twin-global", height: 1400, output: output, host: host, window: window)
    try enabledToolsCheck(twinText.contains("Codex") && !twinText.contains("Agents load this skill from Library") && !twinText.contains(".config/skillscout"),
      "an agent's own copy of a Library skill is not described as loading from Library")
    let global = try await show(AnyView(ContentView(sidebar: .global, skill: total.id, globalTool: .codex).environment(store)),
      name: "skillset-global-regression", width: 1450, height: 1200, output: output, host: host, window: window)
    try enabledToolsCheck(global.contains("Used in 3 chats in the last 60 days") && find("search-choice.Project") == nil,
      "Global retains its full-history usage behavior")
    let dashboard = try await show(AnyView(ReportsView(openSimilar: { _ in }).environment(store)),
      name: "skillset-dashboard-filters", width: 1000, height: 900, output: output, host: host, window: window)
    try enabledToolsCheck(dashboard.contains("Project") && dashboard.contains("Period"), "Dashboard retains usage analysis controls")
    try enabledToolsCheck(store.usageScope == UsageScope(project: "FixtureBeta", days: 7) && store.skillsets.first?.skills == [total.id, other.id]
      && store.skillsetAssignments.isEmpty && store.projectState.assignments.isEmpty, "Skillsets viewing preserves saved analysis scope membership and assignment state")
  }

  @MainActor static func runManage(home: URL, output: URL, host: NSHostingController<AnyView>, window: NSWindow) async throws {
    try writeSkill(Paths.at(".agents/skills/manage-source"), name: "manage-source")
    try writeSkill(Paths.at(".agents/skills/manage-second"), name: "manage-second")
    let store = AppStore()
    store.tools = [.codex]
    await store.refreshSkills()
    let source = try require(store.skills.first { $0.name == "manage-source" }, "manager skill source scanned")
    let second = try require(store.skills.first { $0.name == "manage-second" }, "manager second source scanned")
    let assigned = Skillset(name: "Assigned fixture", skills: [source.id])
    let unassigned = Skillset(name: "Unassigned fixture", skills: [second.id])
    store.skillsets = [assigned, unassigned]
    let folder = home.appending(path: "FixtureProject")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let project = try require(store.registerProject(folder), "manager made-up project registered")
    await store.refreshProjectInventories()
    let plan = try require(store.projectPlan(project, skillsetID: assigned.id, target: .shared), "initial project assignment planned")
    try enabledToolsCheck(plan.canApply, "initial project assignment can apply")
    _ = await store.applyProjectPlan(plan)
    let assignment = try require(store.projectState.assignments.first { $0.projectID == project.id && $0.skillsetID == assigned.id }, "initial project skillset assigned")
    try enabledToolsCheck(assignment.target == .shared, "fixture assignment uses the Codex-readable project destination")
    let installed = folder.appending(path: ".agents/skills/manage-source/SKILL.md")
    let original = try Data(contentsOf: installed)
    let fixture = EnabledToolsFixture()
    fixture.filter = ProjectSkillFilter(tool: .codex)
    let filter = Binding(get: { fixture.filter }, set: { fixture.filter = $0 })
    let selection = Binding(get: { fixture.skill }, set: { fixture.skill = $0 })
    let view = AnyView(ProjectSkillListView(project: project, selection: selection, filter: filter).environment(store))
    let header = try await show(view, name: "project-manage-header", width: 460, height: 850, output: output, host: host, window: window)
    try enabledToolsCheck(header.contains("Manage") && header.contains(project.name) && header.contains("Add skills"), "project header offers the Global-style Manage control")
    try await press("project-manage-skillsets", title: "Manage", window: window)
    try await waitFor("project Manage opens the shared assignment screen") { window.attachedSheet != nil }
    let manager = try require(window.attachedSheet, "project manager sheet attached")
    try await settle()
    try snapshot("project-manage-screen", output: output, window: manager)
    let text = try visible(manager)
    try enabledToolsCheck(text.contains(project.name) && text.contains("Assigned fixture") && text.contains("Unassigned fixture") && text.contains("Not assigned"), "same manager screen lists applied and available project skillsets")
    try enabledToolsCheck(text.contains("Codex") && !text.contains("Compatible agents"), "manager respects the project agent context")
    try await press("project-skillset-apply-" + unassigned.id.uuidString, title: "Apply", window: manager)
    try await waitFor("project Apply opens its review") { manager.attachedSheet != nil }
    let apply = try require(manager.attachedSheet, "project Apply review attached")
    try await settle()
    try snapshot("project-manage-apply-review", output: output, window: apply)
    let applyText = try visible(apply)
    try enabledToolsCheck(applyText.contains("Add skills to project") && applyText.contains(project.name) && applyText.contains("Affected agents") && applyText.contains("Codex"), "Apply reviews the selected project's affected readers")
    try await press("manage-review-cancel", title: "Cancel", window: apply)
    try await waitFor("cancel returns to the shared project manager") { manager.attachedSheet == nil }
    try enabledToolsCheck(store.projectState.assignments.count == 1, "opening and cancelling Apply does not assign a new skillset")
    store.setSkillMembership([second.id], in: assigned.id, included: true)
    try await settle()
    try enabledToolsCheck((try visible(manager)).contains("Changes pending"), "membership edits show pending changes in the shared manager")
    try await press("project-skillset-apply-" + assigned.id.uuidString, title: "Apply changes", window: manager)
    try await waitFor("project Apply changes opens its review") { manager.attachedSheet != nil }
    let update = try require(manager.attachedSheet, "project update review attached")
    try await settle()
    try snapshot("project-manage-update-review", output: output, window: update)
    try enabledToolsCheck((try visible(update)).contains(second.name), "Apply changes reviews the newly added member")
    try await press("manage-review-cancel", title: "Cancel", window: update)
    try await waitFor("update cancel returns to manager") { manager.attachedSheet == nil }
    try await press("project-skillset-unassign-" + assigned.id.uuidString, title: "Unassign", window: manager)
    try await waitFor("project Unassign opens its review") { manager.attachedSheet != nil }
    let unapply = try require(manager.attachedSheet, "project Unassign review attached")
    try await settle()
    try snapshot("project-manage-unassign-review", output: output, window: unapply)
    let unapplyText = try visible(unapply)
    try enabledToolsCheck(unapplyText.contains("Unassign project skillset") && unapplyText.contains("Assigned fixture") && unapplyText.contains("Unassign and apply changes"), "Unassign uses the existing reviewed project removal flow")
    try await press("manage-review-cancel", title: "Cancel", window: unapply)
    try await waitFor("unassign cancel returns to manager") { manager.attachedSheet == nil }
    try await press("manage-done", title: "Done", window: manager)
    try await waitFor("Done closes project Manage") { window.attachedSheet == nil }
    let overview = try await show(AnyView(ProjectDetailView(project: project).environment(store)), name: "project-manage-overview", output: output, host: host, window: window)
    try enabledToolsCheck(overview.contains("Applied skillsets") && overview.contains("Assigned fixture") && !overview.contains("Preview update") && !overview.contains("Unassign"), "overview retains assignment information without duplicate management actions")
    let global = try await show(AnyView(ToolSkillsetsView(tool: .codex).environment(store)), name: "global-manage-header", width: 700, height: 200, output: output, host: host, window: window)
    try enabledToolsCheck(global.contains("Manage"), "Global keeps its existing Manage control")
    try await press("global-manage", title: "Manage", window: window)
    try await waitFor("Global Manage still opens the shared screen") { window.attachedSheet != nil }
    let globalManager = try require(window.attachedSheet, "Global manager sheet attached")
    try await settle()
    try snapshot("global-manage-screen", output: output, window: globalManager)
    let globalText = try visible(globalManager)
    try enabledToolsCheck(globalText.contains("Skillsets for Codex") && globalText.contains("Assigned fixture") && !globalText.contains(project.name), "Global manager retains its tool scope")
    try await press("manage-done", title: "Done", window: globalManager)
    try await waitFor("Global Done closes its screen") { window.attachedSheet == nil }
    try enabledToolsCheck(try Data(contentsOf: installed) == original, "all review and cancel interactions preserve project skill files")
    try enabledToolsCheck(store.projectState.assignments.first?.members == [source.id] && store.skillsetAssignments.isEmpty, "cancelled project previews preserve assignment snapshots and Global state")
  }

  @MainActor static func runSystem(output: URL, host: NSHostingController<AnyView>, window: NSWindow) async throws {
    UserDefaults.standard.set(false, forKey: "showSystemSkills")
    UserDefaults.standard.set("all", forKey: "skillSource")
    UserDefaults.standard.set("name", forKey: "skillSort")
    try writeSkill(Paths.at(".codex/skills/.system/system-codex"), name: "system-codex")
    try writeSkill(Paths.at(".cursor/skills-cursor/system-cursor"), name: "system-cursor")
    try writeSkill(Paths.at(".codex/skills/system-personal"), name: "system-personal")
    try writeSkill(Paths.at(".codex/skills/.system/mixed-fixture"), name: "mixed-fixture")
    try writeSkill(Paths.at(".gemini/skills/mixed-fixture"), name: "mixed-fixture")
    let provider = Paths.at(".codex/plugins/cache/fixture/work-pets/1.0")
    let manifest = provider.appending(path: ".codex-plugin/plugin.json")
    try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"name":"work-pets","version":"1.0"}"#.utf8).write(to: manifest)
    try writeSkill(provider.appending(path: "skills/pets"), name: "pets")
    let store = AppStore()
    store.tools = [.codex, .cursor, .gemini]
    await store.refreshSkills()
    let codexSystem = try require(store.skills.first { $0.name == "system-codex" }, "Codex system fixture scanned")
    let pets = try require(store.skills.first { $0.name == "pets" }, "plugin pets fixture scanned")
    try enabledToolsCheck(codexSystem.isSystemOnly(in: [.codex]) && !pets.isSystemOnly(in: [.codex]), "source classification separates system and plugin skills")
    let regular = store.usageReport(scope: UsageScope(), includeSystemSkills: false)
    try enabledToolsCheck(Set(regular.skills.map(\.name)) == ["system-personal", "pets", "mixed-fixture"], "normal Dashboard totals exclude systems and retain plugin and mixed sources")
    try enabledToolsCheck(store.usageReport(scope: UsageScope()).skills.count == 5, "historical report default retains system metadata")
    let global = AnyView(ContentView(sidebar: .global).environment(store))
    let hidden = try await show(global, name: "system-default-hidden", width: 1280, height: 900, output: output, host: host, window: window)
    try enabledToolsCheck(hidden.contains("Show system skills") && hidden.contains("system-personal") && hidden.contains("pets") && hidden.contains("mixed-fixture"), "default Global keeps personal plugin and mixed-source skills")
    try enabledToolsCheck(!hidden.contains("system-codex") && !hidden.contains("system-cursor"), "default Global hides tool system rows")
    try await press("show-system-skills", title: "Show system skills", window: window)
    let shown = try visible(window)
    try snapshot("system-toggle-shown", output: output, window: window)
    try enabledToolsCheck(UserDefaults.standard.bool(forKey: "showSystemSkills") && shown.contains("system-codex") && shown.contains("system-cursor"), "real toggle reveals systems and persists its preference")
    try enabledToolsCheck(shown.contains("Managed by") && shown.contains("system skills"), "shown system rows identify owners with a separate system count")
    let codex = AnyView(ContentView(sidebar: .global, globalTool: .codex).environment(store))
    let codexText = try await show(codex, name: "system-codex-scope", width: 1280, height: 900, output: output, host: host, window: window)
    try enabledToolsCheck(codexText.contains("system-codex") && codexText.contains("mixed-fixture") && !codexText.contains("system-cursor"), "agent view limits shown systems to its readable sources")
    try await press("show-system-skills", title: "Show system skills", window: window)
    let codexHidden = try visible(window)
    try snapshot("system-codex-hidden", output: output, window: window)
    try enabledToolsCheck(!codexHidden.contains("system-codex") && !codexHidden.contains("mixed-fixture") && codexHidden.contains("pets") && codexHidden.contains("system-personal"), "agent default hides mixed identity when only its system copy is readable")
    let detail = try await show(AnyView(SkillDetail(skill: codexSystem, context: .global(.codex)).environment(store)),
      name: "system-detail", output: output, host: host, window: window)
    try enabledToolsCheck(detail.contains("System") && detail.contains("Managed by Codex") && detail.contains("cannot be removed individually"), "system details name the owner and explain protected management")
    try enabledToolsCheck(Removal.from(.codex, skills: [codexSystem], selectedCount: 1) == nil, "system copies never gain a removal action")
    UserDefaults.standard.set("builtIn", forKey: "skillSource")
    let restored = try await show(AnyView(ContentView(sidebar: .global).environment(store)), name: "system-stale-filter-restored", width: 1280, height: 900, output: output, host: host, window: window)
    try enabledToolsCheck(restored.contains("pets") && UserDefaults.standard.string(forKey: "skillSource") == "all", "hidden systems normalize a stale built-in source preference")
  }

  @MainActor static func runProviders(output: URL, host: NSHostingController<AnyView>, window: NSWindow) async throws {
    let providerFolder = Paths.at(".codex/plugins/cache/fixture/work-pets/1.0")
    let manifest = providerFolder.appending(path: ".codex-plugin/plugin.json")
    try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"name":"work-pets","version":"1.0","description":"Made-up provider fixture"}"#.utf8).write(to: manifest)
    let petsFolder = providerFolder.appending(path: "skills/pets")
    let siblingFolder = providerFolder.appending(path: "skills/create-pet")
    try writeSkill(petsFolder, name: "pets")
    try writeSkill(siblingFolder, name: "create-pet")
    let unrelatedFolder = Paths.at(".codex/plugins/cache/fixture/unrelated-provider/1.0")
    let unrelatedManifest = unrelatedFolder.appending(path: ".codex-plugin/plugin.json")
    try FileManager.default.createDirectory(at: unrelatedManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"name":"unrelated-provider","version":"1.0"}"#.utf8).write(to: unrelatedManifest)
    try writeSkill(unrelatedFolder.appending(path: "skills/pets"), name: "pets")
    let builtInFolder = Paths.at(".codex/skills/.system/built-in-fixture")
    try writeSkill(builtInFolder, name: "built-in-fixture")
    let protectedFiles = [manifest, unrelatedManifest, petsFolder.appending(path: "SKILL.md"),
      siblingFolder.appending(path: "SKILL.md"), builtInFolder.appending(path: "SKILL.md")]
    let protectedContents = try protectedFiles.map { try Data(contentsOf: $0) }
    let store = AppStore()
    store.tools = [.codex]
    await store.refreshSkills()
    let plugin = try require(store.plugins.first { $0.name == "work-pets" }, "made-up Codex plugin scanned")
    let scannedPets = try require(store.skills.first { $0.copies.contains { $0.folder.standardizedFileURL.path == petsFolder.standardizedFileURL.path } }, "plugin pets skill scanned by physical source")
    let pets = Skill(name: scannedPets.name, description: scannedPets.description,
      copies: scannedPets.copies.filter { $0.folder.standardizedFileURL.path == petsFolder.standardizedFileURL.path })
    try enabledToolsCheck(!pets.isPersonal && Removal.from(.codex, skills: [pets], selectedCount: 1) == nil,
      "plugin-only skill has no independent removal plan")
    let detail = AnyView(SkillDetail(skill: pets, context: .global(.codex)).environment(store))
    let text = try await show(detail, name: "global-plugin-provider", output: output, host: host, window: window)
    try enabledToolsCheck(text.contains("Provided by work-pets") && text.contains("View plugin") && text.contains("cannot be removed individually"),
      "Global plugin availability names its supplying plugin and explains individual removal protection")
    try enabledToolsCheck(!text.contains("Provided by unrelated-provider"), "provider matching uses the copy path rather than a same-name skill")
    try await press("provider-view-missing", title: "View plugin", window: window)
    try await waitFor("View plugin opens its detail sheet") { window.attachedSheet != nil }
    let sheet = try require(window.attachedSheet, "plugin detail sheet attached")
    try await settle()
    let providerText = try visible(sheet)
    try snapshot("global-provider-sheet", output: output, window: sheet)
    try enabledToolsCheck(providerText.contains(plugin.name) && providerText.contains("create-pet") && providerText.contains("pets"),
      "real View plugin button opens the correct provider with both sibling skills")
    try enabledToolsCheck(providerText.contains("Skillscout only reads plugins") && providerText.contains("turn them off in Codex"),
      "plugin detail gives read-only management guidance in the original tool")
    try await press("provider-close-missing", title: "Close", window: sheet)
    try await waitFor("Close returns to the skill detail") { window.attachedSheet == nil }
    try enabledToolsCheck((try visible(window)).contains("View plugin"), "closing the provider sheet preserves the Global skill detail")
    let personalFolder = Tool.codex.skillsFolder.appending(path: "pets-personal")
    try writeSkill(personalFolder, name: pets.name)
    await store.refreshSkills()
    let scannedMixed = try require(store.skills.first { $0.name == pets.name }, "mixed personal and plugin skill scanned")
    let mixed = Skill(name: scannedMixed.name, description: scannedMixed.description,
      copies: scannedMixed.copies.filter { $0.folder.standardizedFileURL.path == petsFolder.standardizedFileURL.path || $0.folder.standardizedFileURL.path == personalFolder.standardizedFileURL.path })
    try enabledToolsCheck(mixed.copies.contains { $0.folder.standardizedFileURL.path == personalFolder.standardizedFileURL.path } && mixed.copies.contains { $0.folder.standardizedFileURL.path == petsFolder.standardizedFileURL.path },
      "mixed fixture retains both physical copies")
    let removal = try require(Removal.from(.codex, skills: [mixed], selectedCount: 1), "mixed skill retains its personal removal plan")
    let mixedText = try await show(AnyView(SkillDetail(skill: mixed, context: .global(.codex)).environment(store)),
      name: "global-mixed-provider", output: output, host: host, window: window)
    try enabledToolsCheck(mixedText.contains(removal.actionLabel.replacingOccurrences(of: "…", with: "")) && mixedText.contains("View plugin")
      && mixedText.contains("cannot be removed individually"), "mixed skill shows personal removal alongside its protected plugin provider")
    let builtIn = try require(store.skills.first { $0.name == "built-in-fixture" }, "built-in fixture scanned")
    let builtInText = try await show(AnyView(SkillDetail(skill: builtIn, context: .global(.codex)).environment(store)),
      name: "global-built-in-provider", output: output, host: host, window: window)
    try enabledToolsCheck(builtInText.lowercased().contains("built-in skills cannot be removed individually") && !builtInText.contains("View plugin"),
      "built-in-only skill explains protection without a plugin action")
    let otherContext = try await show(AnyView(SkillDetail(skill: pets, context: .global(.gemini)).environment(store)),
      name: "global-other-agent-provider", output: output, host: host, window: window)
    try enabledToolsCheck(!otherContext.contains("Provided by") && !otherContext.contains("View plugin"),
      "selected Global agent limits provider actions")
    let crossProvider = Paths.at(".claude/plugins/cache/fixture/cursor-reader/1.0")
    let crossManifest = crossProvider.appending(path: ".claude-plugin/plugin.json")
    try FileManager.default.createDirectory(at: crossManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"name":"cursor-reader","version":"1.0"}"#.utf8).write(to: crossManifest)
    let crossSkillFolder = crossProvider.appending(path: "skills/cross-reader")
    try writeSkill(crossSkillFolder, name: "cross-reader")
    let installed: [String: Any] = ["plugins": ["cursor-reader@fixture": [["installPath": crossProvider.path]]]]
    try JSONSerialization.data(withJSONObject: installed).write(to: Paths.at(".claude/plugins/installed_plugins.json"))
    store.tools = [.claude, .codex, .cursor]
    await store.refreshSkills()
    let crossSkill = try require(store.skills.first { $0.copies.contains { $0.folder.standardizedFileURL.path == crossSkillFolder.standardizedFileURL.path } }, "cross-tool plugin skill scanned")
    let crossText = try await show(AnyView(SkillDetail(skill: crossSkill, context: .global(.cursor)).environment(store)),
      name: "global-cross-tool-provider", output: output, host: host, window: window)
    try enabledToolsCheck(crossText.contains("Provided by cursor-reader") && crossText.contains("View plugin"),
      "Cursor-readable Claude plugin keeps its actual provider action")
    store.tools = [.codex]
    _ = try await show(detail, name: "global-provider-before-disable", output: output, host: host, window: window)
    try await press("provider-view-missing", title: "View plugin", window: window)
    try await waitFor("provider sheet reopens for a live Settings change") { window.attachedSheet != nil }
    store.setTool(.codex, enabled: false)
    try await waitFor("disabling the owning tool closes its provider sheet") { window.attachedSheet == nil }
    let disabledText = try await show(detail, name: "global-disabled-provider", output: output, host: host, window: window)
    try enabledToolsCheck(!disabledText.contains("Provided by") && !disabledText.contains("View plugin"),
      "disabled tools have no provider badge or action")
    for (file, original) in zip(protectedFiles, protectedContents) {
      try enabledToolsCheck(try Data(contentsOf: file) == original, "provider inspection leaves \(file.lastPathComponent) intact")
    }
    try enabledToolsCheck(FileManager.default.fileExists(atPath: personalFolder.appending(path: "SKILL.md").path)
      && store.removal == nil, "provider viewing never removes or schedules removal of a personal copy")
  }

  static func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw EnabledToolsFailure.failed(message) }
    print("PASS: \(message)")
    return value
  }
}
