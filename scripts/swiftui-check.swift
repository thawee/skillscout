import AppKit
import SwiftUI
import Vision

@MainActor @Observable
final class DetailFixture {
  let skill: Skill
  var source: SkillCopy
  init(skill: Skill) { self.skill = skill; source = skill.primary }
}

struct DetailFixtureView: View {
  let fixture: DetailFixture
  var body: some View {
    SkillDetail(skill: fixture.skill, installationSource: fixture.source, context: .discovery)
  }
}

@main enum SwiftUICheck {
  enum Failure: Error { case failed(String) }
  @MainActor static var captureOutput: URL?
  @MainActor static var captures: [String] = []

  @MainActor static func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure.failed(message) }
    print("PASS: \(message)")
  }

  @MainActor static func elements(_ window: NSWindow) -> [any NSAccessibilityProtocol] {
    var pending: [Any] = [window] + (window.contentView.map { [$0] } ?? [])
    var seen: Set<ObjectIdentifier> = []
    var result: [any NSAccessibilityProtocol] = []
    while let object = pending.popLast(), seen.count < 3000 {
      guard seen.insert(ObjectIdentifier(object as AnyObject)).inserted,
            let element = object as? any NSAccessibilityProtocol else { continue }
      result.append(element)
      pending.append(contentsOf: element.accessibilityChildren() ?? [])
      if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
    }
    return result
  }

  @MainActor static func text(_ window: NSWindow) -> String {
    let labels = elements(window).map { ($0.accessibilityLabel() ?? "") + " " + (($0.accessibilityValue() as? String) ?? "") }.joined(separator: " ")
    guard let view = window.contentView?.superview,
          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return labels }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    if let output = captureOutput, let data = bitmap.representation(using: .png, properties: [:]) {
      let name = "swiftui-capture-\(captures.count + 1)"
      captures.append(name)
      try? data.write(to: output.appending(path: name + ".png"))
      try? JSONEncoder().encode(captures).write(to: output.appending(path: "render-manifest.json"))
    }
    guard let image = bitmap.cgImage else { return labels }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let visible = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
    print("NATIVE TEXT: \(visible)")
    print("NATIVE FRAME: window=\(window.frame), content=\(window.contentView?.frame ?? .zero), elements=\(elements(window).count)")
    return labels + " " + visible
  }

  @MainActor static func waitForText(_ expected: String, in window: NSWindow) async throws -> String {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
      try await Task.sleep(for: .milliseconds(300))
      let visible = text(window)
      if visible.contains(expected) { return visible }
    }
    throw Failure.failed("Selected detail did not finish loading: \(expected)")
  }

  @MainActor static func main() {
    let home = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    captureOutput = output
    precondition(!FileManager.default.fileExists(atPath: home.path))
    setenv("HOME", home.path, 1)
    UserDefaults.standard.set([Tool.codex.rawValue], forKey: "tools")
    UserDefaults.standard.set(false, forKey: "autoAnalyze")
    UserDefaults.standard.set(60, forKey: "lookbackDays")
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let host = NSHostingController(rootView: AnyView(EmptyView()))
    host.sizingOptions = []
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 760),
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
            try await run(home: home, host: host, window: window)
            try "All functional checks passed.\n".write(to: output.appending(path: "result.txt"), atomically: true, encoding: .utf8)
          } catch {
            print("FAILED: \(error)")
            try? "FAILED: \(error)\n".write(to: output.appending(path: "result.txt"), atomically: true, encoding: .utf8)
          }
          NSApp.terminate(nil)
        }
      }
    }
    app.run()
  }

  @MainActor static func run(home: URL, host: NSHostingController<AnyView>, window: NSWindow) async throws {
    let fm = FileManager.default
    let folder = home.appending(path: ".config/skillscout/skills/detail-fixture/demo")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let markdown = "---\nname: demo\ndescription: FIRST DETAIL FIXTURE\n---\nFirst body\n"
    try markdown.write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    let root = SkillRoot(label: "Fixture", url: folder.deletingLastPathComponent(), kind: .managed, owner: nil, readBy: [.codex])
    let first = SkillCopy(folder: folder, resolved: folder, root: root, pluginName: nil, isSymlink: false, contentHash: "first", created: .distantPast)
    let other = home.appending(path: ".config/skillscout/skills/detail-fixture/second")
    try fm.createDirectory(at: other, withIntermediateDirectories: true)
    try "---\nname: second\ndescription: SECOND DETAIL FIXTURE\n---\nSecond body\n".write(to: other.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    let second = SkillCopy(folder: other, resolved: other, root: root, pluginName: nil, isSymlink: false, contentHash: "second", created: .distantPast)
    let store = AppStore()
    let fixture = DetailFixture(skill: Skill(name: "demo", description: "", copies: [first, second]))
    host.rootView = AnyView(DetailFixtureView(fixture: fixture).environment(store))
    let size = CGSize(width: 1100, height: 760)
    window.contentMinSize = size
    window.contentMaxSize = size
    window.setContentSize(size)
    window.center()
    try await Task.sleep(for: .milliseconds(300))
    try check(text(window).contains("FIRST DETAIL FIXTURE"), "native selected detail loads first source")
    try "sudo echo changed\n".write(to: folder.appending(path: "support.sh"), atomically: true, encoding: .utf8)
    await store.refreshSkills()
    try await Task.sleep(for: .milliseconds(300))
    try check(text(window).contains("Runs with administrator rights") && text(window).contains("support.sh"),
      "native detail refresh reveals changed supporting script with unchanged markdown")
    try check(try String(contentsOf: folder.appending(path: "SKILL.md"), encoding: .utf8) == markdown,
      "supporting-file fixture keeps markdown unchanged")
    let scripts = folder.appending(path: "scripts")
    try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
    let slowText = String(repeating: "# fixture line\n", count: 200)
    for index in 0..<1000 {
      try slowText.write(to: scripts.appending(path: "\(index).sh"), atomically: false, encoding: .utf8)
    }
    store.reportInspectionRevision += 1
    try await Task.sleep(for: .milliseconds(10))
    fixture.source = second
    let selected = try await waitForText("SECOND DETAIL FIXTURE", in: window)
    try check(selected.contains("SECOND DETAIL FIXTURE") && !selected.contains("FIRST DETAIL FIXTURE") && !selected.contains("support.sh"),
      "superseded slow native detail never replaces selected source")
    store.reportInspectionRevision += 1
    host.rootView = AnyView(EmptyView())
    try await Task.sleep(for: .milliseconds(50))
    fixture.source = first
    host.rootView = AnyView(DetailFixtureView(fixture: fixture).environment(store))
    fixture.source = second
    let returned = try await waitForText("SECOND DETAIL FIXTURE", in: window)
    try check(!returned.contains("FIRST DETAIL FIXTURE"),
      "canceling native detail and returning preserves selected source")
  }
}
