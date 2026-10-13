import AppKit
import SwiftUI
import Observation
import Vision

enum SelectionCheckFailure: Error { case failed(String) }

func selectionCheck(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw SelectionCheckFailure.failed(message) }
  print("PASS: \(message)")
}

@MainActor @Observable final class SelectionFixture {
  var tool: Tool?
  var scope = "available"
  var project = "one"
  var empty = "unavailable"
  var enabled = true
  var projectChanges = 0
  var applied = 0
  var actions: [String] = []
  var bounds: [String: CGRect] = [:]
}

struct SelectionBoundsKey: PreferenceKey {
  static let defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, next in next })
  }
}

extension View {
  func selectionBounds(_ name: String) -> some View {
    background(GeometryReader { geometry in
      Color.clear.preference(key: SelectionBoundsKey.self,
        value: [name: geometry.frame(in: .named("selection-fixture"))])
    })
  }
}

struct SelectionFixtureView: View {
  @Bindable var fixture: SelectionFixture
  let home: URL

  private var projects: [ChoiceOption<String>] {
    [
      ChoiceOption(value: "one", title: "demo", detail: home.appending(path: "workspaces/one/demo").path, symbol: "folder"),
      ChoiceOption(value: "two", title: "demo", detail: home.appending(path: "workspaces/two/demo").path, symbol: "folder"),
      ChoiceOption(value: "archive", title: "Archive", detail: home.appending(path: "workspaces/archive").path, symbol: "archivebox"),
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Selection controls").font(.title2.weight(.semibold))
      AgentChoices(tools: Tool.allCases, selection: $fixture.tool).selectionBounds("Agent")
      ChoiceChips(title: "Show", options: [
        ChoiceOption(value: "available", title: "Available here"),
        ChoiceOption(value: "project", title: "Project only"),
      ], selection: $fixture.scope).selectionBounds("Show")
      SearchChoice(title: "Project", options: projects, selection: $fixture.project).selectionBounds("Project")
      SearchChoice<String>(title: "Empty", options: [], selection: $fixture.empty).selectionBounds("Empty")
      ChoiceAction(title: "Add to skillset", options: projects) { fixture.actions.append($0) }.selectionBounds("Add to skillset")
      Spacer(minLength: 0)
      HStack {
        Text("Selected: \(fixture.project)").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Apply") { fixture.applied += 1 }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .coordinateSpace(name: "selection-fixture")
    .onPreferenceChange(SelectionBoundsKey.self) { fixture.bounds = $0 }
    .disabled(!fixture.enabled)
    .onChange(of: fixture.project) { fixture.projectChanges += 1 }
  }
}

@main enum SelectionCheck {
  @MainActor static func main() {
    let home = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    guard !FileManager.default.fileExists(atPath: home.path) else {
      fatalError("Selection checks require a new made-up home")
    }
    setenv("HOME", home.path, 1)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let host = NSHostingController(rootView: AnyView(EmptyView()))
    host.sizingOptions = []
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 640),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Skillscout selection checks"
    window.contentViewController = host
    resize(window, width: 620, height: 640)
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

  @MainActor static func recognized(_ window: NSWindow) throws -> [VNRecognizedTextObservation] {
    guard let content = window.contentView?.superview,
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(content.bounds.width * 3), pixelsHigh: Int(content.bounds.height * 3),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
      throw SelectionCheckFailure.failed("Cannot inspect native window text")
    }
    bitmap.size = content.bounds.size
    content.cacheDisplay(in: content.bounds, to: bitmap)
    guard let cgImage = bitmap.cgImage else { throw SelectionCheckFailure.failed("Cannot inspect native window image") }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.customWords = Tool.allCases.map(\.shortName) + ["All agents", "demo", "Archive", "Available here", "Project only"]
    request.recognitionLanguages = ["en-US"]
    request.minimumTextHeight = 0.005
    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
    return request.results ?? []
  }

  @MainActor static func textFrame(_ title: String, window: NSWindow, region: CGRect? = nil, exact: Bool = false) throws -> CGRect? {
    guard let content = window.contentView?.superview else { return nil }
    for observation in try recognized(window) {
      let agentLabel = Tool.allCases.contains { $0.shortName == title }
      let pattern = title.lowercased().map { character in
        character == "i" || character == "l" ? "[il1]" : NSRegularExpression.escapedPattern(for: String(character))
      }.joined()
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
      let rect = CGRect(x: box.boundingBox.minX * content.bounds.width,
        y: box.boundingBox.minY * content.bounds.height,
        width: box.boundingBox.width * content.bounds.width,
        height: box.boundingBox.height * content.bounds.height)
      if region == nil || region!.contains(CGPoint(x: rect.midX, y: rect.midY)) { return rect }
    }
    return nil
  }

  @MainActor static func mouse(_ point: CGPoint, window: NSWindow) async throws {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
        throw SelectionCheckFailure.failed("Cannot create native mouse event")
      }
      NSApp.postEvent(event, atStart: false)
    }
    try await settle()
  }

  @MainActor static func nativeRegion(_ title: String, fixture: SelectionFixture, window: NSWindow) -> CGRect? {
    guard let bounds = fixture.bounds[title], let content = window.contentView else { return nil }
    return CGRect(x: bounds.minX, y: content.bounds.height - bounds.maxY, width: bounds.width, height: bounds.height)
  }

  @MainActor static func press(_ identifier: String, fixture: SelectionFixture, window: NSWindow) async throws {
    if let element = find(identifier), element.accessibilityPerformPress() {
      try await settle()
      return
    }
    let parts = identifier.split(separator: ".", maxSplits: 2).map(String.init)
    guard parts.count >= 2 else { throw SelectionCheckFailure.failed("Invalid native control identifier") }
    let title = parts[1]
    if parts[0] == "search-choice" {
      guard let region = nativeRegion(title, fixture: fixture, window: window) else {
        throw SelectionCheckFailure.failed("Missing rendered bounds for \(title)")
      }
      try await mouse(CGPoint(x: region.midX, y: region.minY + 15), window: window)
    } else {
      let target = parts[0] == "choice-result" ? popup(title, excluding: window) : window
      guard let target else { throw SelectionCheckFailure.failed("Missing native result popover") }
      let label = parts.count == 3 ? parts[2] : title
      let region = target == window ? nativeRegion(title, fixture: fixture, window: window) : nil
      guard let frame = try textFrame(label, window: target, region: region, exact: parts[0] == "choice-result") else {
        let text = try recognized(target).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ")
        throw SelectionCheckFailure.failed("Cannot locate rendered \(identifier); observed text: \(text)")
      }
      try await mouse(CGPoint(x: frame.midX, y: frame.midY), window: target)
    }
  }

  @MainActor static func query(_ text: String) async throws {
    guard let window = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) else {
      throw SelectionCheckFailure.failed("Search has no native popover")
    }
    if let frame = try textFrame("Search", window: window) {
      try await mouse(CGPoint(x: frame.midX, y: frame.midY), window: window)
    } else {
      throw SelectionCheckFailure.failed("Cannot locate the visible native search field")
    }
    print("INFO: search key window \(String(describing: NSApp.keyWindow.map { type(of: $0) })); responder \(String(describing: NSApp.keyWindow?.firstResponder.map { type(of: $0) }))")
    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
      editor.selectAll(nil)
      editor.insertText(text, replacementRange: editor.selectedRange())
    } else {
      for character in text {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
          characters: String(character), charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0) else {
          throw SelectionCheckFailure.failed("Cannot create native text-input event")
        }
        NSApp.sendEvent(event)
      }
    }
    try await settle()
  }

  @MainActor static func key(_ characters: String, code: UInt16) async throws {
    print("INFO: key \(code); responder \(String(describing: NSApp.keyWindow?.firstResponder.map { type(of: $0) }))")
    guard let window = NSApp.keyWindow,
      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
      throw SelectionCheckFailure.failed("No key window for native keyboard input")
    }
    NSApp.sendEvent(event)
    try await settle()
  }

  @MainActor static func snapshot(_ name: String, output: URL, window: NSWindow) throws {
    guard let content = window.contentView?.superview,
      let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
      throw SelectionCheckFailure.failed("Cannot render \(name)")
    }
    content.cacheDisplay(in: content.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw SelectionCheckFailure.failed("Cannot encode \(name)")
    }
    try png.write(to: output.appending(path: name + ".png"))
    let manifest = output.appending(path: "render-manifest.json")
    let previous = (try? Data(contentsOf: manifest)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    try JSONEncoder().encode(previous + [name]).write(to: manifest)
    print("PASS: rendered \(name)")
  }

  @MainActor static func popup(_ title: String, excluding main: NSWindow? = nil) -> NSWindow? {
    let accessible = NSApp.windows.first { window in
      window.isVisible && elements(in: [window]).contains { $0.accessibilityIdentifier() == "choice-search.\(title)" }
    }
    return accessible ?? NSApp.windows.first { $0.isVisible && $0 != main && String(describing: type(of: $0)).contains("Popover") }
  }

  @MainActor static func resultCount(_ title: String, window: NSWindow) throws -> Int {
    let buttons = elements(in: [window]).filter {
      $0.accessibilityIdentifier()?.hasPrefix("choice-result.\(title).") == true && $0.accessibilityRole() == .button
    }
    if !buttons.isEmpty { return buttons.count }
    return try recognized(window).filter {
      $0.topCandidates(10).contains { candidate in
        guard !candidate.string.contains("/") else { return false }
        let words = candidate.string.lowercased().split(whereSeparator: { !$0.isLetter })
        return words.contains("demo") || words.contains("archive")
      }
    }.count
  }

  @MainActor static func run(home: URL, output: URL, host: NSHostingController<AnyView>, window: NSWindow) async throws {
    let fixture = SelectionFixture()
    func press(_ identifier: String) async throws {
      try await Self.press(identifier, fixture: fixture, window: window)
    }
    NSApp.appearance = NSAppearance(named: .darkAqua)
    host.rootView = AnyView(SelectionFixtureView(fixture: fixture, home: home))
    try await settle()
    try snapshot("selection-controls", output: output, window: window)
    resize(window, width: 330, height: 720)
    try await settle()
    let narrowElements = elements(in: [window])
    let agentButtons = narrowElements.filter {
      $0.accessibilityIdentifier()?.hasPrefix("choice.Agent.") == true && $0.accessibilityRole() == .button
    }
    var frames = agentButtons.map { $0.accessibilityFrame() }
    if agentButtons.isEmpty {
      print("INFO: native AX tree has no SwiftUI button children; using rendered text frames and native mouse events. \(diagnostic(narrowElements))")
      guard let region = nativeRegion("Agent", fixture: fixture, window: window) else {
        throw SelectionCheckFailure.failed("Missing rendered agent bounds")
      }
      frames = try (["All agents"] + Tool.allCases.map(\.shortName)).compactMap {
        try textFrame($0, window: window, region: region)
      }
      let observed = try recognized(window).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ")
      try selectionCheck(frames.count == Tool.allCases.count + 1, "all ten agents and All agents are visible at narrow width (observed \(frames.count)); \(observed)")
      try selectionCheck(frames.allSatisfy { !$0.isEmpty && window.contentView!.bounds.contains($0) }, "every narrow agent chip has a visible text frame inside the window")
    } else {
      try selectionCheck(agentButtons.count == Tool.allCases.count + 1, "all ten agents and All agents are exposed as native buttons at narrow width (observed \(agentButtons.count))")
      try selectionCheck(frames.allSatisfy { !$0.isEmpty && window.frame.contains($0) }, "every narrow agent chip has a visible frame inside the window")
    }
    try selectionCheck(Set(frames.map(\.minY)).count > 1, "narrow agent choices wrap onto multiple visible rows")
    for tool in Tool.allCases {
      try await press("choice.Agent.\(tool.shortName)")
      try selectionCheck(fixture.tool == tool, "visible \(tool.shortName) chip responds to its native button press")
    }
    try await press("choice.Agent.Codex")
    try selectionCheck(fixture.tool == .codex, "native agent chip press changes the binding")
    try await press("choice.Show.Project only")
    try selectionCheck(fixture.scope == "project", "native scope chip press changes the binding")
    try snapshot("selection-controls-narrow", output: output, window: window)
    try await press("choice.Agent.All agents")
    try selectionCheck(fixture.tool == nil, "All agents clears the selected tool through its visible chip")
    NSApp.appearance = NSAppearance(named: .aqua)
    try await settle()
    try snapshot("selection-controls-narrow-light", output: output, window: window)
    resize(window, width: 620, height: 640)
    try await settle()
    try snapshot("selection-controls-light", output: output, window: window)

    try await press("search-choice.Project")
    guard let projectPopup = popup("Project") else { throw SelectionCheckFailure.failed("SearchChoice did not open a native popover") }
    try selectionCheck(true, "SearchChoice opens a real searchable native popover")
    let initialCount = try resultCount("Project", window: projectPopup)
    try selectionCheck(initialCount == 3, "same-name projects are shown as separate choices alongside Archive (observed \(initialCount))")
    try snapshot("selection-project-popover-light", output: output, window: projectPopup)
    try await query("two/demo")
    let filteredCount = try resultCount("Project", window: projectPopup)
    try selectionCheck(filteredCount == 1, "search matches the secondary project path and disambiguates duplicate titles (observed \(filteredCount))")
    try selectionCheck(fixture.project == "one" && fixture.projectChanges == 0, "filtering out the selected option preserves the binding")
    try snapshot("selection-project-path-search-light", output: output, window: projectPopup)
    try await press("choice-result.Project.demo")
    try selectionCheck(fixture.project == "two" && fixture.projectChanges == 1, "native result press selects the matching project exactly once")
    try selectionCheck(popup("Project") == nil, "choosing a result dismisses the native popover")
    let triggerTitle = find("search-choice.Project")?.accessibilityValue() as? String
    let triggerFrame = try textFrame("demo", window: window, region: nativeRegion("Project", fixture: fixture, window: window))
    try selectionCheck(triggerTitle == "demo" || triggerFrame != nil, "search trigger reflects the chosen project")

    NSApp.appearance = NSAppearance(named: .darkAqua)
    try await press("search-choice.Project")
    guard let noMatchPopup = popup("Project") else { throw SelectionCheckFailure.failed("Missing no-match popover") }
    try await query("no-such-project")
    let noMatchCount = try resultCount("Project", window: noMatchPopup)
    try selectionCheck(noMatchCount == 0, "unmatched query shows no selectable result")
    try snapshot("selection-project-no-matches", output: output, window: noMatchPopup)
    try await key("\r", code: 36)
    try selectionCheck(fixture.project == "two" && fixture.projectChanges == 1 && fixture.applied == 0, "Return with no match changes nothing and does not invoke outer Apply")
    try await key("\u{1b}", code: 53)
    try selectionCheck(popup("Project") == nil, "Escape dismisses the search popover")

    try await press("search-choice.Project")
    guard let keyboardPopup = popup("Project") else { throw SelectionCheckFailure.failed("Missing keyboard popover") }
    try snapshot("selection-project-popover", output: output, window: keyboardPopup)
    try await key("\u{f701}", code: 125)
    try await key("\r", code: 36)
    try selectionCheck(fixture.project == "archive" && fixture.projectChanges == 2, "Down Arrow and Return choose the next result through native keyboard events (selected \(fixture.project), changes \(fixture.projectChanges), applied \(fixture.applied))")
    try selectionCheck(fixture.applied == 0 && popup("Project") == nil, "result Return closes the popover without firing the outer default Apply button")

    try await press("search-choice.Empty")
    guard let emptyPopup = popup("Empty") else { throw SelectionCheckFailure.failed("Missing empty-choice popover") }
    let emptyCount = try resultCount("Empty", window: emptyPopup)
    try selectionCheck(emptyCount == 0, "empty options show no selectable result")
    try snapshot("selection-empty-options", output: output, window: emptyPopup)
    try await key("\r", code: 36)
    try selectionCheck(fixture.empty == "unavailable" && fixture.applied == 0, "Return with an empty options list preserves its unavailable selection")
    try await key("\u{1b}", code: 53)

    try await press("choice-action.Add to skillset")
    try await query("two/demo")
    try await press("choice-result.Add to skillset.demo")
    try selectionCheck(fixture.actions == ["two"], "ChoiceAction invokes its closure exactly once through native result selection")
    try selectionCheck(popup("Add to skillset") == nil, "ChoiceAction dismisses after selection")
    try await press("search-choice.Project")
    fixture.enabled = false
    try await settle()
    try selectionCheck(popup("Project") == nil, "disabling an open SearchChoice dismisses its popover")
    try await key("\r", code: 36)
    try selectionCheck(fixture.project == "archive" && fixture.projectChanges == 2 && fixture.applied == 0, "disabled host prevents selection writes and outer Apply")
    fixture.enabled = true
    try await settle()
    try await press("choice-action.Add to skillset")
    fixture.enabled = false
    try await settle()
    try selectionCheck(popup("Add to skillset") == nil && fixture.actions == ["two"], "disabling an open ChoiceAction dismisses it without executing the action")
    fixture.enabled = true
    try await settle()
    try snapshot("selection-controls-chosen", output: output, window: window)
  }
}
