// Captures the real Skillscout window for the README and the banner, in light and dark.
// It builds a demo home folder with made-up skills first, so no real chats end up in a screenshot.
// scripts/screenshot.sh compiles it with the app's sources, in place of SkillscoutApp.swift.

import AppKit
import SwiftUI

let output = URL(filePath: CommandLine.arguments[1])
let demoHome = URL(filePath: CommandLine.arguments[2])
let windowSize = CGSize(width: 1180, height: 760)

struct DemoSkill {
  let name: String
  let description: String
  /// The folder under the home that holds the skill.
  let folder: String
  var links: [String] = []
  var chats: [Tool: Int] = [:]
  var projects: [String] = []
  var hoursAgo: Double = 0
}

let skills = [
  DemoSkill(
    name: "writing-style",
    description: "Write docs, READMEs, blog posts and emails in my voice: short sentences, a friendly tone and real examples. Use for any writing task, or when a draft sounds generated.",
    folder: ".agents/skills", links: [".claude/skills", ".config/agents/skills"],
    chats: [.cursor: 38, .claude: 17, .codex: 9], projects: ["blog", "docs-site", "mac-notes-app"], hoursAgo: 2
  ),
  DemoSkill(
    name: "commit-and-push",
    description: "Commit the current work with a clear message and push it to the current branch. Never force push, never skip hooks.",
    folder: ".agents/skills", links: [".claude/skills", ".config/agents/skills"],
    chats: [.cursor: 22, .claude: 11, .codex: 5, .amp: 3], projects: ["api-server", "blog", "landing-page"], hoursAgo: 5
  ),
  DemoSkill(
    name: "code-review",
    description: "Review the current diff for bugs, missing tests and unclear names before I commit, and list the fixes by severity.",
    folder: ".agents/skills", links: [".claude/skills"],
    chats: [.claude: 14, .cursor: 9, .opencode: 4], projects: ["api-server", "mac-notes-app"], hoursAgo: 26
  ),
  DemoSkill(
    name: "cloudflare-deploy",
    description: "Deploy the project to Cloudflare Workers with wrangler, then tail the logs and check the live URL.",
    folder: ".agents/skills", links: [".claude/skills"],
    chats: [.codex: 11, .cursor: 7], projects: ["landing-page", "blog"], hoursAgo: 70
  ),
  DemoSkill(
    name: "release-notes",
    description: "Turn the commits since the last tag into release notes, grouped into features and fixes, in plain language.",
    folder: ".agents/skills",
    chats: [.cursor: 8, .gemini: 4], projects: ["mac-notes-app", "api-server"], hoursAgo: 96
  ),
  DemoSkill(
    name: "test-first",
    description: "Reproduce a bug with a failing test first, then fix it and show both test runs.",
    folder: ".agents/skills", links: [".claude/skills"],
    chats: [.claude: 6, .pi: 3], projects: ["api-server"], hoursAgo: 150
  ),
  DemoSkill(
    name: "astro-blog-post",
    description: "Create a new post in an Astro content collection with frontmatter, a slug and the draft flag set.",
    folder: ".agents/skills",
    chats: [.cursor: 7], projects: ["blog"], hoursAgo: 200
  ),
  DemoSkill(
    name: "sql-migration",
    description: "Write a reversible Postgres migration, run it locally, and update the schema notes.",
    folder: ".agents/skills",
    chats: [.codex: 3, .droid: 1], projects: ["api-server"], hoursAgo: 360
  ),
  DemoSkill(
    name: "swiftui-previews",
    description: "Add SwiftUI previews with realistic sample data for the views I'm working on.",
    folder: ".cursor/skills",
    chats: [.cursor: 3], projects: ["mac-notes-app"], hoursAgo: 290
  ),
  DemoSkill(
    name: "stripe-webhooks",
    description: "Add a Stripe webhook handler with signature checks, and test it locally with the Stripe CLI.",
    folder: ".codex/skills",
    chats: [.codex: 2], projects: ["api-server"], hoursAgo: 480
  ),
  DemoSkill(
    name: "perf-audit",
    description: "Measure Core Web Vitals for a page and list the three fixes with the biggest impact.",
    folder: ".agents/skills"
  ),
  DemoSkill(
    name: "pdf-invoices",
    description: "Generate PDF invoices from a JSON order, with the company details and VAT lines.",
    folder: ".claude/skills"
  ),
  DemoSkill(
    name: "tailwind-cleanup",
    description: "Sort and dedupe Tailwind classes, and pull repeated patterns into components.",
    folder: ".agents/skills"
  ),
]

let explanation = """
  Writing Style makes the agent write the way you do: short sentences, a friendly tone, and real examples instead of \
  placeholders. The agent loads it for docs, READMEs, blog posts and emails, and when you ask it to rewrite a draft \
  that sounds generated. It needs no account, API key or extra tool, and it works on plain Markdown files.
  """

let draft = """
  ---
  name: pr-description
  description: Write a pull request description from the current branch. Use when the user asks for a PR description, PR body or pull request text.
  ---

  # PR description

  1. Run `git log main..HEAD --oneline` and `git diff main...HEAD --stat` to see what changed.
  2. Read the diff of the files that changed the most.
  3. Write the description:
     - A one-line summary.
     - What changed, in 3 to 6 bullets.
     - Why, in one short paragraph.
     - How to test it, as numbered steps.
  4. Put migrations, new environment variables and breaking changes at the top.

  Keep it under 200 words.

  """

func ideas() -> [Suggestion] {
  func examples(_ items: [(Tool, String, String, Double)]) -> [Prompt] {
    items.map { tool, project, text, days in
      Prompt(id: shortHash(text), tool: tool, project: project, date: .now.addingTimeInterval(-days * 86_400), text: text)
    }
  }
  return [
    Suggestion(
      name: "pr-description", title: "Write PR descriptions",
      summary: "Write a pull request description from the current branch: what changed, why, and how to test it.",
      why: "You ask for a PR description at the end of almost every branch, in four projects.",
      examples: examples([
        (.cursor, "api-server", "write a PR description for this branch, include how to test it", 1),
        (.claude, "mac-notes-app", "can you write the pull request text for these changes? short, with a testing section", 3),
        (.cursor, "blog", "summarize this branch as a PR description", 4),
        (.codex, "api-server", "PR description please: what changed and why", 6),
        (.claude, "api-server", "draft the PR body for the auth refactor, mention the migration", 9),
        (.cursor, "landing-page", "write the PR description, keep it under 200 words", 11),
        (.cursor, "mac-notes-app", "PR text for the sync fix, with steps to reproduce the old bug", 15),
        (.codex, "blog", "write a pull request description for the RSS changes", 18),
        (.claude, "api-server", "give me a PR description I can paste into GitHub", 23),
      ]),
      createdAt: .now.addingTimeInterval(-7200), draft: draft
    ),
    Suggestion(
      name: "broken-links", title: "Check links before deploying",
      summary: "Build the site and report broken internal and external links before a deploy.",
      why: "Before most deploys of the blog and the docs site, you asked the agent to look for broken links.",
      examples: examples([
        (.cursor, "blog", "check the built site for broken links before I deploy", 2),
        (.cursor, "docs-site", "any broken links in the docs? check internal and external ones", 5),
        (.gemini, "blog", "crawl dist and list broken links", 8),
        (.cursor, "docs-site", "find dead links in the build output", 13),
        (.cursor, "blog", "run a link check on the new posts", 19),
        (.gemini, "docs-site", "check links again, some external ones changed", 26),
      ]),
      createdAt: .now.addingTimeInterval(-7200)
    ),
    Suggestion(
      name: "bump-version", title: "Bump the version and tag it",
      summary: "Bump the version, update CHANGELOG.md and create a git tag for the release.",
      why: "You repeat the same three release steps by hand in the Mac app and the API server.",
      examples: examples([
        (.claude, "mac-notes-app", "bump the version to 1.4, update the changelog and tag it", 4),
        (.codex, "api-server", "new patch release: bump version, changelog, git tag", 10),
        (.claude, "mac-notes-app", "release 1.4.1, same steps as last time", 17),
        (.codex, "api-server", "tag v2.3.0 and add the changelog entry", 24),
        (.claude, "mac-notes-app", "bump build number and marketing version, then tag", 33),
      ]),
      createdAt: .now.addingTimeInterval(-7200)
    ),
    Suggestion(
      name: "seed-data", title: "Seed realistic test data",
      summary: "Fill the local database with realistic users, orders and dates for testing.",
      why: "You asked for realistic seed data four times while building the API server.",
      examples: examples([
        (.opencode, "api-server", "seed the local db with 50 realistic users and orders", 3),
        (.cursor, "api-server", "I need test data with real looking names and dates spread over a year", 12),
        (.opencode, "api-server", "reset the database and seed it again with realistic data", 20),
        (.cursor, "api-server", "add seed orders with different statuses and currencies", 29),
      ]),
      createdAt: .now.addingTimeInterval(-7200)
    ),
  ]
}

/// A home folder where all eight tools look installed and every skill has a SKILL.md.
func buildDemoHome() throws {
  let fm = FileManager.default
  try? fm.removeItem(at: demoHome)
  for folder in Tool.allCases.flatMap(\.homeFolders) {
    try fm.createDirectory(at: demoHome.appending(path: folder), withIntermediateDirectories: true)
  }
  for skill in skills {
    let folder = demoHome.appending(path: skill.folder).appending(path: skill.name)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let title = skill.name.split(separator: "-").map(\.capitalized).joined(separator: " ")
    let body = "---\nname: \(skill.name)\ndescription: \(skill.description)\n---\n\n# \(title)\n\n\(skill.description)\n"
    try body.write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    for link in skill.links {
      let parent = demoHome.appending(path: link)
      try fm.createDirectory(at: parent, withIntermediateDirectories: true)
      try fm.createSymbolicLink(at: parent.appending(path: skill.name), withDestinationURL: folder)
    }
  }

  // A made-up Library repository, so the sidebar shows a Source.
  for (name, description) in librarySkills {
    let folder = demoHome.appending(path: ".config/skillscout/skills/team-skills/\(name)")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try "---\nname: \(name)\ndescription: \(description)\n---\n\n\(description)\n"
      .write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
  }

  // A made-up Claude Code plugin, so the sidebar shows Plugins.
  let plugin = demoHome.appending(path: ".claude/plugins/cache/team-market/format-on-save/1.2.0")
  try fm.createDirectory(at: plugin.appending(path: ".claude-plugin"), withIntermediateDirectories: true)
  try #"{"name":"format-on-save","description":"Formats files after every edit","hooks":{"PostToolUse":[{"matcher":"Write|Edit","hooks":[{"type":"command","command":"./scripts/format.sh"}]}]}}"#
    .write(to: plugin.appending(path: ".claude-plugin/plugin.json"), atomically: true, encoding: .utf8)
  try #"{"version":2,"plugins":{"format-on-save@team-market":[{"installPath":"\#(plugin.path)","version":"1.2.0"}]}}"#
    .write(to: demoHome.appending(path: ".claude/plugins/installed_plugins.json"), atomically: true, encoding: .utf8)
}

let librarySkills = [
  ("pdf-forms", "Fill and check PDF forms from a JSON file, and flag the fields that are still empty."),
  ("release-checklist", "Walk through the release checklist: version bump, changelog, tag and the release notes."),
]

/// The status panel counts, spread across the tools like a week of real use.
func demoPrompts() -> [Prompt] {
  let counts: [(Tool, Int)] = [(.cursor, 1184), (.claude, 412), (.codex, 377), (.gemini, 61), (.opencode, 44), (.droid, 23), (.pi, 31), (.amp, 17)]
  return counts.flatMap { tool, count in
    (0..<count).map { index in
      Prompt(id: "\(tool.rawValue)-\(index)", tool: tool, project: "demo", date: .now.addingTimeInterval(-Double(index) * 2400), text: "demo")
    }
  }
}

@MainActor
func fill(_ store: AppStore) {
  store.usage = Dictionary(uniqueKeysWithValues: skills.filter { !$0.chats.isEmpty }.map { skill in
    let total = skill.chats.values.reduce(0, +)
    let projects = Dictionary(uniqueKeysWithValues: skill.projects.enumerated().map { ($1, total - $0 * 5) })
    return (skill.name, SkillUsage(chats: total, byTool: skill.chats, projects: projects, lastUsed: .now.addingTimeInterval(-skill.hoursAgo * 3600)))
  })
  let prompts = demoPrompts()
  store.prompts = prompts
  store.analyzedIDs = Set(prompts.dropFirst(23).map(\.id))
  store.lastAnalysis = .now.addingTimeInterval(-2 * 3600)
  store.suggestions = ideas()
  if let skill = store.skill("writing-style") {
    store.explanations[skill.primary.contentHash] = explanation
  }
  store.skillsets = [
    Skillset(name: "Writing", skills: ["writing-style", "release-notes", "astro-blog-post"]),
    Skillset(name: "Shipping", skills: ["commit-and-push", "code-review", "release-checklist", "cloudflare-deploy"]),
  ]
}

@main
enum Screenshot {
  @MainActor
  static func main() {
    try! buildDemoHome()
    setenv("HOME", demoHome.path, 1)
    UserDefaults.standard.set(SkillSort.use.rawValue, forKey: "skillSort")
    UserDefaults.standard.set(false, forKey: "autoAnalyze")
    UserDefaults.standard.removeObject(forKey: "tools")

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let store = AppStore()
    let host = NSHostingController(rootView: AnyView(EmptyView()))
    host.sceneBridgingOptions = [.toolbars, .title]
    let window = ActiveWindow(
      contentRect: CGRect(origin: .zero, size: windowSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.contentViewController = host
    window.toolbarStyle = .unified
    window.setContentSize(windowSize)
    window.center()

    _ = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Task { await capture(store, host: host, window: window) }
      }
    }
    app.run()
  }
}

/// Draws as the active window even when another app is frontmost, which is the case
/// when this runs from a terminal: macOS doesn't let it take focus.
final class ActiveWindow: NSWindow {
  override var isKeyWindow: Bool { true }
  override var isMainWindow: Bool { true }
  @objc(_hasActiveAppearance) func hasActiveAppearance() -> Bool { true }
  @objc(_hasActiveAppearanceIgnoringKeyFocus) func hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
  @objc(_hasKeyAppearance) func hasKeyAppearance() -> Bool { true }
  @objc(_hasMainAppearance) func hasMainAppearance() -> Bool { true }
}

@MainActor
func capture(_ store: AppStore, host: NSHostingController<AnyView>, window: NSWindow) async {
  await store.start()
  fill(store)
  let scenes: [(String, AnyView)] = [
    ("", AnyView(ContentView(skill: "writing-style").id("skills").environment(store))),
    ("-suggestions", AnyView(ContentView(sidebar: .suggestions, suggestion: store.suggestions.first?.id).id("suggestions").environment(store))),
  ]

  for (suffix, view) in scenes {
    host.rootView = view
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      NSApp.appearance = NSAppearance(named: appearance)
      try? await Task.sleep(for: .seconds(1.5))
      write(framed(snapshot(window)), to: output.appending(path: "screenshot\(suffix)-\(name).png"))
    }
  }
  NSApp.terminate(nil)
}

@MainActor
func snapshot(_ window: NSWindow) -> CGImage {
  let view = window.contentView!.superview!
  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
  view.cacheDisplay(in: view.bounds, to: rep)
  return rep.cgImage!
}

/// Rounds the corners like a window and adds a soft shadow on a transparent margin.
func framed(_ image: CGImage) -> CGImage {
  let scale: CGFloat = 2
  let margin = 48 * scale
  let radius = 12 * scale
  let size = CGSize(width: CGFloat(image.width) + 2 * margin, height: CGFloat(image.height) + 2 * margin)
  let context = CGContext(
    data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  let rect = CGRect(x: margin, y: margin, width: CGFloat(image.width), height: CGFloat(image.height))
  let window = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

  context.saveGState()
  context.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 36 * scale, color: CGColor(gray: 0, alpha: 0.32))
  context.addPath(window)
  context.setFillColor(CGColor(gray: 0.5, alpha: 1))
  context.fillPath()
  context.restoreGState()

  context.addPath(window)
  context.clip()
  context.draw(image, in: rect)
  context.resetClip()
  context.addPath(window)
  context.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
  context.setLineWidth(1)
  context.strokePath()
  return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
  let rep = NSBitmapImageRep(cgImage: image)
  try! rep.representation(using: .png, properties: [:])!.write(to: url)
  print(url.path)
}
