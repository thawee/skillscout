import AppKit
import SwiftUI
import Vision

enum RepositoryNativeFailure: Error { case failed(String) }

func repositoryNativeCheck(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  guard try condition() else { throw RepositoryNativeFailure.failed(message) }
  print("PASS: \(message)")
}

@main enum RepositoryUpdateCheck {
  @MainActor static func main() {
    let home = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    guard !FileManager.default.fileExists(atPath: home.path) else { fatalError("A new made-up home is required") }
    setenv("HOME", home.path, 1)
    UserDefaults.standard.set(Tool.allCases.map(\.rawValue), forKey: "tools")
    UserDefaults.standard.set(false, forKey: "autoAnalyze")
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let host = NSHostingController(rootView: AnyView(EmptyView()))
    host.sizingOptions = []
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 820, height: 800),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Quartermaster repository update checks"
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
            if CommandLine.arguments.contains("--cancel-only") {
              try await runCancellation(home: home, output: output, host: host, window: window)
            } else if CommandLine.arguments.contains("--states-only") {
              try await renderStates(home: home, output: output, store: AppStore(), host: host, window: window)
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
      throw RepositoryNativeFailure.failed("Cannot inspect native window text")
    }
    bitmap.size = content.bounds.size
    content.cacheDisplay(in: content.bounds, to: bitmap)
    guard let cgImage = bitmap.cgImage else { throw RepositoryNativeFailure.failed("Cannot inspect native window image") }
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
        throw RepositoryNativeFailure.failed("Cannot create native mouse event")
      }
      NSApp.postEvent(event, atStart: false)
    }
    try await settle()
  }

  @MainActor static func snapshot(_ name: String, output: URL, window: NSWindow) throws {
    guard let content = window.contentView?.superview,
      let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
      throw RepositoryNativeFailure.failed("Cannot render \(name)")
    }
    content.cacheDisplay(in: content.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw RepositoryNativeFailure.failed("Cannot encode \(name)")
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
      let observed = try recognized(window).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ")
      throw RepositoryNativeFailure.failed("Missing native control \(title). Visible text \(observed)")
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
    throw RepositoryNativeFailure.failed(message)
  }

  static func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

  static func skillText(_ body: String, name: String = "native-fixture") -> String {
    "---\nname: \(name)\ndescription: Made-up repository update fixture\n---\n\(body)\n"
  }

  static func write(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  static func stages(_ update: RepoUpdate) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: update.repositoryFolder.deletingLastPathComponent(),
      includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix(".\(update.name)-resolved-") }
  }

  static func cleanFixtureTrash(name: String, source: RepositorySource) throws {
    let username = NSUserName()
    let trash = URL(fileURLWithPath: "/Users/\(username)/.Trash")
    guard let candidates = try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else {
      print("INFO: Trash cannot be listed; fixture backup cleanup needs Finder for \(name)")
      return
    }
    for item in candidates where item.lastPathComponent.hasPrefix(".\(name)-backup-") {
      guard let snapshot = try RepositoryLibrary.snapshot(in: item), snapshot.source == source else {
        throw RepositoryNativeFailure.failed("The fixture Trash backup has an unexpected source")
      }
      try FileManager.default.removeItem(at: item)
      print("PASS: removed only the verified UUID fixture backup from Trash")
    }
  }

  @MainActor static func inspectFinalContents(_ expected: String, window: NSWindow) async throws {
    let outer = outerScrollView(window)
    for offset in stride(from: CGFloat(0), through: CGFloat(750), by: CGFloat(150)) {
      if try textFrame(expected, window: window) != nil {
        try repositoryNativeCheck(true, "native file panel displays \(expected)")
        return
      }
      if let outer, let document = outer.documentView {
        let maximum = max(0, document.bounds.height - outer.contentView.bounds.height)
        outer.contentView.scroll(to: CGPoint(x: 0, y: document.isFlipped ? min(offset + 150, maximum) : max(0, maximum - offset - 150)))
        outer.reflectScrolledClipView(outer.contentView)
      }
      try await settle()
    }
    throw RepositoryNativeFailure.failed("Final contents did not visibly show \(expected)")
  }

  @MainActor static func editMerge(_ text: String, window: NSWindow) async throws {
    func editors(_ view: NSView) -> [NSTextView] {
      (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors)
    }
    guard let content = window.contentView,
      let editor = editors(content).first(where: { $0.isEditable && $0.isSelectable }) else {
      throw RepositoryNativeFailure.failed("The native PlainTextEditor was not found")
    }
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(editor)
    editor.selectAll(nil)
    editor.insertText(text, replacementRange: editor.selectedRange())
    try await settle()
    try repositoryNativeCheck(editor.string == text, "native merge editor accepts literal complete-file text")
  }

  @MainActor static func renderStates(home: URL, output: URL, store: AppStore,
    host: NSHostingController<AnyView>, window: NSWindow) async throws {
    let fm = FileManager.default
    for scenario in ["clean", "local-preserved", "binary", "deleted", "missing-base", "mode-change"] {
      let source = home.appending(path: "fixtures/state-\(scenario)-\(UUID().uuidString.lowercased())")
      let skillPath = "fixture/SKILL.md"
      try write(skillText("BASE state instructions"), source.appending(path: skillPath))
      try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.appending(path: skillPath).path)
      if scenario == "binary" { try Data([0, 0xff, 1]).write(to: source.appending(path: "fixture/payload.bin")) }
      if scenario == "deleted" { try write("BASE optional file\n", source.appending(path: "fixture/deleted.txt")) }
      let preview = try await RepositoryLibrary.preview(source: .local(source.path))
      let repository = try SkillInstaller.importRepository(preview: preview, consumePreview: true)
      switch scenario {
      case "clean":
        try write(skillText("INCOMING clean state instructions"), source.appending(path: skillPath))
      case "local-preserved":
        try write(skillText("MINE preserved state instructions"), repository.appending(path: skillPath))
        try write("INCOMING unrelated note\n", source.appending(path: "z-upstream-note.txt"))
      case "binary":
        try Data([0, 0xff, 2]).write(to: repository.appending(path: "fixture/payload.bin"))
        try Data([0, 0xff, 3]).write(to: source.appending(path: "fixture/payload.bin"))
      case "deleted":
        try write("MINE retained optional file\n", repository.appending(path: "fixture/deleted.txt"))
        try fm.removeItem(at: source.appending(path: "fixture/deleted.txt"))
      case "missing-base":
        var snapshot = try RepositoryLibrary.snapshot(in: repository)!
        snapshot.upstreamArchiveDigest = nil
        try JSONEncoder().encode(snapshot).write(to: repository.appending(path: RepositoryLibrary.markerName))
        try fm.removeItem(at: repository.appending(path: RepositoryLibrary.upstreamMarkerName))
        try write(skillText("MINE legacy state instructions"), repository.appending(path: skillPath))
        try write(skillText("INCOMING legacy state instructions"), source.appending(path: skillPath))
      case "mode-change":
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repository.appending(path: skillPath).path)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.appending(path: skillPath).path)
      default: break
      }
      let update = try await SkillInstaller.prepareRepoUpdate(name: repository.lastPathComponent)
      defer { SkillInstaller.discardRepoUpdate(update) }
      switch scenario {
      case "clean":
        try repositoryNativeCheck(!update.hasLocalEdits && update.files.contains { $0.path == skillPath && $0.status == .incoming },
          "clean rendered state has only an incoming change")
      case "local-preserved":
        try repositoryNativeCheck(update.files.contains { $0.path == skillPath && $0.status == .local },
          "local-preserved rendered state retains the local skill automatically")
      case "binary":
        try repositoryNativeCheck(update.files.contains { $0.path == "fixture/payload.bin" && $0.status == .conflict && !$0.canMerge && $0.localText == nil && $0.incomingText == nil },
          "binary rendered state requires a choice and disables text merging")
      case "deleted":
        try repositoryNativeCheck(update.files.contains { $0.path == "fixture/deleted.txt" && $0.status == .conflict && $0.localExists && !$0.incomingExists },
          "deleted rendered state distinguishes the retained local file from incoming absence")
      case "missing-base":
        try repositoryNativeCheck(update.files.contains { $0.path == skillPath && $0.status == .conflict && $0.baseText == nil },
          "missing-base rendered state has no invented ancestor contents")
      case "mode-change":
        try repositoryNativeCheck(update.files.contains {
          $0.path == skillPath && $0.status == .conflict &&
            $0.reason?.contains("Base: 0644; Mine: 0755; Incoming: 0600") == true
        }, "mode-change rendered state compares actual Base, Mine, and Incoming permissions")
      default: break
      }
      store.pendingRepoUpdate = update
      host.rootView = AnyView(RepoUpdateSheet(update: update).id(update.id).environment(store))
      for width in [CGFloat(820), CGFloat(640)] {
        resize(window, width: width, height: width == 820 ? 800 : 720)
        try await settle()
        if let outer = outerScrollView(window), let document = outer.documentView {
          outer.contentView.scroll(to: CGPoint(x: 0, y: document.isFlipped ? 0 : max(0, document.bounds.height - outer.contentView.bounds.height)))
          outer.reflectScrolledClipView(outer.contentView)
          try await settle()
        }
        try snapshot("repository-state-\(scenario)-\(Int(width))", output: output, window: window)
        if scenario == "deleted" {
          try await inspectFinalContents("Deleted or absent in the incoming version.", window: window)
          try snapshot("repository-state-deleted-incoming-\(Int(width))", output: output, window: window)
        }
        if scenario == "binary" || scenario == "missing-base" {
          try await inspectFinalContents("Base text is unavailable.", window: window)
        }
        if scenario == "mode-change" {
          try repositoryNativeCheck(try textFrame("Base: 0644", window: window) != nil &&
            textFrame("Mine: 0755", window: window) != nil && textFrame("Incoming: 0600", window: window) != nil,
            "native permission values are visible at \(Int(width)) width")
        }
      }
      store.pendingRepoUpdate = nil
      host.rootView = AnyView(EmptyView())
      try await settle()
      SkillInstaller.discardRepoUpdate(update)
    }
  }

  @MainActor static func runCancellation(home: URL, output: URL,
    host: NSHostingController<AnyView>, window: NSWindow) async throws {
    let fm = FileManager.default
    let source = home.appending(path: "fixtures/cancellation-\(UUID().uuidString.lowercased())")
    let path = "fixture/SKILL.md"
    let mine = skillText("MINE cancellation instructions")
    try write(skillText("BASE cancellation instructions"), source.appending(path: path))
    let preview = try await RepositoryLibrary.preview(source: .local(source.path))
    let repository = try SkillInstaller.importRepository(preview: preview, consumePreview: true)
    try write(mine, repository.appending(path: path))
    try write(skillText("INCOMING cancellation instructions"), source.appending(path: path))
    let update = try await SkillInstaller.prepareRepoUpdate(name: repository.lastPathComponent)
    let store = AppStore()
    store.pendingRepoUpdate = update
    host.rootView = AnyView(RepoUpdateSheet(update: update).id(update.id).environment(store))
    resize(window, width: 820, height: 800)
    try await settle()
    try snapshot("repository-cancel-choices", output: output, window: window)
    try await press("repo-update.keep-mine", title: "Keep mine", window: window)
    try repositoryNativeCheck(try textFrame("Keep your Library version", window: window) != nil,
      "fresh cancellation process visibly accepts the native Keep mine choice")
    try snapshot("repository-cancel-selected", output: output, window: window)
    try await press("repo-update.review", title: "Review choices", window: window)
    try await waitFor("Cancellation final review did not materialize", { !stages(update).isEmpty })
    try repositoryNativeCheck(try text(stages(update).first!.appending(path: path)) == mine,
      "cancellation final review contains the exact selected local contents")
    try snapshot("repository-cancel-review", output: output, window: window)
    try await press("cancel", title: "Cancel", window: window)
    try await waitFor("Cancel did not release pending review", { store.pendingRepoUpdate == nil })
    try repositoryNativeCheck(stages(update).isEmpty && !fm.fileExists(atPath: update.staged.path),
      "native Cancel removes both incoming and resolved stages")
    try repositoryNativeCheck(try text(repository.appending(path: path)) == mine,
      "native Cancel preserves the installed local edits")
  }

  @MainActor static func run(home: URL, output: URL, host: NSHostingController<AnyView>, window: NSWindow) async throws {
    let fm = FileManager.default
    let prefix = "native-update-" + UUID().uuidString.lowercased()
    let remote = home.appending(path: "fixtures/" + prefix)
    let path = "fixture/SKILL.md"
    let original = skillText("BASE instructions")
    let mine = skillText("MINE instructions")
    let incoming = skillText("INCOMING instructions")
    let merged = skillText("MERGED instructions with both choices")
    try write(original, remote.appending(path: path))
    _ = try await RepositoryGit.run(["init", "-b", "main", remote.path])
    _ = try await RepositoryGit.run(["-C", remote.path, "add", "."])
    _ = try await RepositoryGit.run(["-C", remote.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Made-up base"])
    let source = RepositorySource.git(remote.absoluteString)
    let preview = try await RepositoryLibrary.preview(source: source)
    let repository = try SkillInstaller.importRepository(preview: preview, consumePreview: true)
    defer { try? cleanFixtureTrash(name: repository.lastPathComponent, source: source) }
    try JSONEncoder().encode(["repositoryName": repository.lastPathComponent, "source": source.address]).write(to: output.appending(path: "trash-fixture.json"))
    let sourceSkill = repository.appending(path: "fixture")
    let linked = Tool.codex.skillsFolder.appending(path: "native-fixture")
    try fm.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: linked, withDestinationURL: sourceSkill)
    let independent = Tool.claude.skillsFolder.appending(path: "native-fixture")
    try fm.createDirectory(at: independent.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.copyItem(at: sourceSkill, to: independent)
    let workspace = home.appending(path: "workspaces/demo-project")
    try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
    let project = RegisteredProject(path: workspace.path, directoryIdentity: try .read(at: workspace))
    let projectCopy = workspace.appending(path: ".agents/skills/native-fixture")
    try fm.createDirectory(at: projectCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.copyItem(at: sourceSkill, to: projectCopy)
    let fingerprint = try SkillInstaller.projectFingerprint(projectCopy)
    let receipt = ProjectSkillEntry(projectID: project.id, skillID: "native-fixture", target: .shared,
      path: projectCopy.path, sourcePath: sourceSkill.path, sourceFingerprint: fingerprint,
      installedFingerprint: fingerprint, directoryIdentity: try .read(at: projectCopy))
    let store = AppStore()
    store.projectState = ProjectState(projects: [project], entries: [receipt])
    store.skillsets = [Skillset(name: "Demo collection", skills: ["native-fixture"])]
    await store.refreshSkills()
    try write(mine, repository.appending(path: path))
    try write("Local notes must survive.\n", repository.appending(path: "local-notes.txt"))
    try write(incoming, remote.appending(path: path))
    try write(skillText("NEW instructions", name: "native-new"), remote.appending(path: "new/SKILL.md"))
    _ = try await RepositoryGit.run(["-C", remote.path, "add", "."])
    _ = try await RepositoryGit.run(["-C", remote.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Made-up conflicting update"])
    let update = try await SkillInstaller.prepareRepoUpdate(name: repository.lastPathComponent)
    host.rootView = AnyView(VStack(alignment: .leading) {
      RepositoryUpdateImpactView(update: update).environment(store)
      Spacer(minLength: 0)
    }.padding(20))
    resize(window, width: 640, height: 900)
    try await settle()
    try snapshot("repository-impact-all-badges-narrow", output: output, window: window)
    let projectedReaders = ProjectSkillTarget.shared.readBy
    for tool in Tool.allCases where projectedReaders.contains(tool) {
      try repositoryNativeCheck(try textFrame(tool.shortName, window: window) != nil,
        "impact displays the full \(tool.shortName) badge at narrow width")
    }
    store.pendingRepoUpdate = update
    try repositoryNativeCheck(update.files.first(where: { $0.path == path })?.status == .conflict,
      "fixture has an actual local and incoming conflict")
    NSApp.appearance = NSAppearance(named: .darkAqua)
    host.rootView = AnyView(RepoUpdateSheet(update: update).id(update.id).environment(store))
    resize(window, width: 820, height: 800)
    try await settle()
    try snapshot("repository-choices-dark", output: output, window: window)
    for title in ["Keep mine", "Use Incoming", "Merge"] {
      try repositoryNativeCheck(try textFrame(title, window: window) != nil,
        "\(title) is visible before scrolling at normal width")
    }
    try await press("repo-update.review", title: "Review choices", window: window)
    try repositoryNativeCheck(stages(update).isEmpty, "unresolved native Review action cannot stage or apply a result")
    resize(window, width: 640, height: 720)
    try await settle()
    try snapshot("repository-choices-narrow-dark", output: output, window: window)
    for title in ["Keep mine", "Use Incoming", "Merge"] {
      try repositoryNativeCheck(try textFrame(title, window: window) != nil,
        "\(title) is visible before scrolling at narrow width")
    }
    NSApp.appearance = NSAppearance(named: .aqua)
    try await settle()
    try snapshot("repository-choices-narrow-light", output: output, window: window)
    resize(window, width: 820, height: 800)
    try await settle()
    try await press("repo-update.keep-mine", title: "Keep mine", window: window)
    try await press("repo-update.review", title: "Review choices", window: window)
    try await waitFor("Keep mine review did not materialize", { !stages(update).isEmpty })
    let firstStage = stages(update).first!
    try repositoryNativeCheck(try text(firstStage.appending(path: path)) == mine,
      "native Keep mine produces the exact reviewed local contents")
    try repositoryNativeCheck(try text(repository.appending(path: path)) == mine, "Review preserves the installed Library")
    try snapshot("repository-final-keep-mine", output: output, window: window)
    try await press("repo-update.back", title: "Back to choices", window: window)
    try repositoryNativeCheck(!fm.fileExists(atPath: firstStage.path), "Back removes the previous final result")
    try await press("repo-update.use-incoming", title: "Use Incoming", window: window)
    try await press("repo-update.review", title: "Review choices", window: window)
    try await waitFor("Incoming review did not materialize", { !stages(update).isEmpty })
    let incomingStage = stages(update).first!
    try repositoryNativeCheck(try text(incomingStage.appending(path: path)) == incoming,
      "native Use incoming rebuilds final review from incoming bytes")
    try snapshot("repository-final-incoming", output: output, window: window)
    try await press("repo-update.back", title: "Back to choices", window: window)
    try repositoryNativeCheck(!fm.fileExists(atPath: incomingStage.path), "changing choices invalidates the earlier reviewed stage")
    try await press("repo-update.merge", title: "Merge", window: window)
    try await waitFor("Native merge sheet did not open", { window.attachedSheet != nil })
    let mergeWindow = window.attachedSheet!
    try await settle()
    try snapshot("repository-merge-editor", output: output, window: mergeWindow)
    try await editMerge("<<<<<<< Mine\nUnresolved local text\n=======\nUnresolved incoming text\n>>>>>>> Incoming\n", window: mergeWindow)
    try await press("repo-update.save-merge", title: "Save merge", window: mergeWindow)
    try repositoryNativeCheck(window.attachedSheet === mergeWindow,
      "native merge editor refuses Save while conflict markers remain")
    try await editMerge(merged, window: mergeWindow)
    try await press("repo-update.save-merge", title: "Save merge", window: mergeWindow)
    try await waitFor("Save merge did not close the native editor", { window.attachedSheet == nil })
    try await press("repo-update.review", title: "Review choices", window: window)
    try await waitFor("Merged review did not materialize", { !stages(update).isEmpty })
    let mergedStage = stages(update).first!
    try repositoryNativeCheck(try text(mergedStage.appending(path: path)) == merged, "manual merge final review contains literal edited bytes")
    try repositoryNativeCheck(try text(mergedStage.appending(path: "local-notes.txt")) == "Local notes must survive.\n",
      "automatic local-only file preservation appears in the final result")
    try repositoryNativeCheck(fm.fileExists(atPath: mergedStage.appending(path: "new/SKILL.md").path), "new upstream skill appears in final review")
    try await inspectFinalContents("MERGED instructions", window: window)
    try snapshot("repository-final-merged-light", output: output, window: window)
    resize(window, width: 640, height: 720)
    try await settle()
    try snapshot("repository-final-narrow-light", output: output, window: window)
    resize(window, width: 820, height: 800)
    try await settle()
    let impact = RepositoryUpdateImpact.inspect(repository: repository, changedPaths: [path], result: mergedStage,
      skills: store.skills, skillsets: store.skillsets, projectState: store.projectState)
    try repositoryNativeCheck(impact.linked.contains(where: { $0.tools.contains(.codex) && $0.willChange == true }),
      "impact identifies the actual linked Codex installation")
    try repositoryNativeCheck(impact.otherCopies.contains(where: { $0.tools.contains(.claude) && $0.willChange == false }),
      "impact distinguishes the independent Claude copy")
    try repositoryNativeCheck(impact.projects.first?.state == .updateAvailable, "impact marks the existing project copy for a separate update")
    try await press("repo-update.apply", title: "Apply update", window: window)
    try await waitFor("Native Apply did not finish", { store.pendingRepoUpdate == nil && !store.isApplyingRepositoryUpdate })
    try repositoryNativeCheck(store.errorMessage == nil, "native Apply completes without a store error")
    try repositoryNativeCheck(try text(repository.appending(path: path)) == merged, "native Apply installs the exact reviewed merge")
    try repositoryNativeCheck(try text(linked.appending(path: "SKILL.md")) == merged, "linked agent reads the applied merged Library contents")
    try repositoryNativeCheck(try text(independent.appending(path: "SKILL.md")) == original, "independent agent copy retains its exact original bytes")
    try repositoryNativeCheck(try text(projectCopy.appending(path: "SKILL.md")) == original, "project copy retains its exact original bytes")
    try repositoryNativeCheck(!fm.fileExists(atPath: Tool.codex.skillsFolder.appending(path: "native-new").path),
      "new upstream skill creates no new agent link")
    try repositoryNativeCheck(stages(update).isEmpty && !fm.fileExists(atPath: update.staged.path), "successful Apply cleans original and resolved staging")

    host.rootView = AnyView(EmptyView())
    try await settle()
    try write(skillText("MINE second conflict"), repository.appending(path: path))
    try write(skillText("INCOMING second conflict"), remote.appending(path: path))
    _ = try await RepositoryGit.run(["-C", remote.path, "add", "."])
    _ = try await RepositoryGit.run(["-C", remote.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Made-up cancellation update"])
    let cancelled = try await SkillInstaller.prepareRepoUpdate(name: repository.lastPathComponent)
    let cancelSanity = try SkillInstaller.resolveRepoUpdate(cancelled, resolutions: [path: .keepMine])
    try repositoryNativeCheck(try text(cancelSanity.staged.appending(path: path)) == skillText("MINE second conflict"),
      "second update resolves Keep mine against the advanced upstream baseline")
    SkillInstaller.discardRepoUpdate(cancelSanity)
    SkillInstaller.discardRepoUpdate(cancelled)
  }
}
