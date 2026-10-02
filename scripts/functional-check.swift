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

  @MainActor
  static func run(home: URL, output: URL, host: NSHostingController<AnyView>, window: NSWindow) async throws {
    let fm = FileManager.default
    try fm.createDirectory(at: output, withIntermediateDirectories: true)
    let previousSupport = home.appending(path: "Library/Application Support/Skillscout Thawee")
    let originalSupport = home.appending(path: "Library/Application Support/Skillscout")
    try fm.createDirectory(at: previousSupport, withIntermediateDirectories: true)
    try fm.createDirectory(at: originalSupport, withIntermediateDirectories: true)
    try "previous fork".write(to: previousSupport.appending(path: "migration-check.txt"), atomically: true, encoding: .utf8)
    try "original".write(to: originalSupport.appending(path: "migration-check.txt"), atomically: true, encoding: .utf8)
    let migratedMarker = try String(contentsOf: Paths.appSupport.appending(path: "migration-check.txt"), encoding: .utf8)
    try check(migratedMarker == "previous fork", "renamed app migrates existing fork data first")
    for folder in Tool.allCases.flatMap(\.homeFolders) {
      try fm.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true)
    }
    let prefix = "functional-" + UUID().uuidString.lowercased()
    let source = home.appending(path: "fixtures/\(prefix)")
    try writeSkill(source, name: prefix, tools: "['claude', \"codex\"]")
    let destination = try await SkillInstaller.install(source: source.path)
    try check(fm.fileExists(atPath: Tool.codex.skillsFolder.appending(path: prefix).path), "frontmatter links Codex")
    try check(fm.fileExists(atPath: Tool.claude.skillsFolder.appending(path: prefix).path), "frontmatter links Claude")
    try check(!fm.fileExists(atPath: Tool.amp.skillsFolder.appending(path: prefix).path), "frontmatter excludes other tools")
    let installed = SkillScanner.scan().first { $0.name == prefix }!
    try check(installed.primary.root.kind == .managed, "managed copy is the primary source")
    try check(installed.availableIn.contains(.codex), "scanner recognizes installed links")

    let unlinkedName = prefix + "-unlinked"
    let unlinkedSource = home.appending(path: "fixtures/\(unlinkedName)")
    try writeSkill(unlinkedSource.appending(path: "category/demo"), name: unlinkedName)
    _ = try await SkillInstaller.install(source: unlinkedSource.path, explicitTools: [])
    let unlinked = SkillScanner.scan().first { $0.name == unlinkedName }!
    try check(unlinked.availableIn.isEmpty, "unlinked repository has no agent availability")
    let visible = SkillScanner.scan().filter { $0.isVisible(in: [.codex], includePlugins: false) }
    try check(visible.contains { $0.id == unlinkedName }, "unlinked managed skills stay visible in the library")
    try check(visible.count { $0.managedRepos.contains(unlinkedName) } == 1, "source count includes unlinked nested skills")

    let hiddenName = prefix + "-hidden"
    let hiddenSource = home.appending(path: "fixtures/\(hiddenName)")
    try writeSkill(hiddenSource.appending(path: ".claude/skills/\(hiddenName)"), name: hiddenName)
    _ = try await SkillInstaller.install(source: hiddenSource.path, explicitTools: [])
    try check(SkillScanner.scan().contains { $0.name == hiddenName && $0.isManaged },
      "managed repositories include hidden Claude skill folders")

    let explicit = home.appending(path: "fixtures/\(prefix)-explicit")
    try writeSkill(explicit, name: prefix + "-explicit", tools: "[claude]")
    _ = try await SkillInstaller.install(source: explicit.path, explicitTools: [.copilot])
    try check(fm.fileExists(atPath: Tool.copilot.skillsFolder.appending(path: prefix + "-explicit").path), "explicit target overrides frontmatter")
    let defaultSource = home.appending(path: "fixtures/\(prefix)-default")
    try writeSkill(defaultSource, name: prefix + "-default")
    _ = try await SkillInstaller.install(source: defaultSource.path)
    try check(Tool.allCases.allSatisfy { fm.fileExists(atPath: $0.skillsFolder.appending(path: prefix + "-default").path) }, "default installation links all enabled tools")

    let localName = prefix + "-local"
    try writeSkill(Tool.cursor.skillsFolder.appending(path: localName), name: localName)
    let local = SkillScanner.scan().first { $0.name == localName }!
    _ = try SkillInstaller.moveToCentral(local)
    try check(fm.fileExists(atPath: Tool.cursor.skillsFolder.appending(path: localName).appending(path: "SKILL.md").path), "moving to the library preserves the original agent link")

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
    let libraryOnlyName = prefix + "-discover-library"
    let libraryOnlySource = home.appending(path: "fixtures/\(libraryOnlyName)")
    try writeSkill(libraryOnlySource, name: libraryOnlyName)
    let libraryOnlyPath = try await store.addRepoToLibrary(source: libraryOnlySource.path)
    let libraryOnlySkill = store.skills.first { $0.name == libraryOnlyName }
    try check(fm.fileExists(atPath: libraryOnlyPath.appending(path: "SKILL.md").path)
      && libraryOnlySkill?.isManaged == true && libraryOnlySkill?.availableIn.isEmpty == true,
      "Discover adds a repository to Library without making its skill available to tools")
    try check(Tool.allCases.allSatisfy { !fm.fileExists(atPath: $0.skillsFolder.appending(path: libraryOnlyName).path) },
      "Discover leaves every AI tool folder untouched")
    await store.add(libraryOnlySkill!, to: .codex)
    try check(fm.fileExists(atPath: Tool.codex.skillsFolder.appending(path: libraryOnlyName).path)
      && store.skills.first(where: { $0.name == libraryOnlyName })?.availableIn.contains(.codex) == true,
      "a library skill can be added to an AI tool afterward")
    let sourceMarker = libraryOnlyPath.appending(path: ".skillscout-local-source")
    try home.appending(path: "fixtures/missing-source").path
      .write(to: sourceMarker, atomically: true, encoding: .utf8)
    do {
      _ = try await store.redownloadRepo(name: libraryOnlyName)
      throw CheckFailure.failed("missing re-download source should fail")
    } catch SkillInstaller.InstallFailure.notFound {}
    let libraryLink = Tool.codex.skillsFolder.appending(path: libraryOnlyName)
    try check(fm.fileExists(atPath: libraryOnlyPath.appending(path: "SKILL.md").path)
      && fm.fileExists(atPath: libraryLink.appending(path: "SKILL.md").path),
      "failed re-download preserves repository and agent link")
    try libraryOnlySource.path.write(to: sourceMarker, atomically: true, encoding: .utf8)
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
    try check(store.skillsetPreview(duplicateSet, to: .cursor, assigned: true).issues.contains { $0.contains("choose a source") },
      "skillset preview requires a choice for ambiguous sources")
    let chosen = duplicate.copies.first { $0.sourceLabel.contains(repoB.lastPathComponent) }!
    try check(store.setPreferredSource(chosen, for: duplicate), "source preference is saved")
    try check(store.skillsetPreview(duplicateSet, to: .cursor, assigned: true).additions.map(\.name) == [duplicateName],
      "chosen source enables skillset application")
    await store.add(duplicate, to: .amp, from: chosen)
    try check(Tool.amp.skillsFolder.appending(path: chosen.resolved.lastPathComponent).resolvingSymlinksInPath().path == chosen.resolved.path,
      "Add to tool uses the selected repository copy")
    try CustomRegistry.shared.add(repoURL: "https://github.com/android/skills")
    await store.loadRegistry()
    try check(store.errorMessage == nil && !store.registrySkills.isEmpty, "Discover loads the bundled registry")
    try check(Set(store.registrySkills.map(\.repo)).isSuperset(of: [
      "https://github.com/android/skills",
      "https://github.com/anthropics/skills",
      "https://github.com/vercel-labs/agent-skills",
      "https://github.com/Graphify-Labs/graphify",
      "https://github.com/humanlayer/skills",
      "https://github.com/cursor/plugins",
      "https://github.com/nextlevelbuilder/ui-ux-pro-max-skill",
      "https://github.com/tt-a1i/archify",
      "https://github.com/addyosmani/agent-skills",
    ]), "Discover includes verified default skill sources")
    try check(store.registrySkills.first { $0.repo == "https://github.com/Graphify-Labs/graphify" }?.manualInstall != nil,
      "Graphify shows manual installation instead of a broken Library import")
    try check(store.registrySkills.filter { $0.repo == "https://github.com/android/skills" }.count == 1
      && store.registrySkills.first { $0.repo == "https://github.com/android/skills" }?.author == "Android",
      "bundled sources take precedence over duplicate custom entries")
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
    let localLibrary = try await store.addRepoToLibrary(source: localSource.path)
    try check(fm.fileExists(atPath: localLibrary.appending(path: "nested/SKILL.md").path)
      && fm.fileExists(atPath: localLibrary.appending(path: ".skillscout-local-source").path),
      "Add to Library copies local skills and remembers their source")
    let localSkill = store.skills.first { $0.name == localSkillName }!
    await store.add(localSkill, to: .codex)
    let localSkillFile = localSource.appending(path: "nested/SKILL.md")
    var updatedLocalSkill = try String(contentsOf: localSkillFile, encoding: .utf8)
    updatedLocalSkill += "\nUpdated in the source folder.\n"
    try updatedLocalSkill.write(to: localSkillFile, atomically: true, encoding: .utf8)
    _ = try await store.redownloadRepo(name: SkillInstaller.repoName(for: localSource.path))
    let refreshedLocalSkill = try String(contentsOf: localLibrary.appending(path: "nested/SKILL.md"), encoding: .utf8)
    try check(refreshedLocalSkill.contains("Updated in the source folder.")
      && Tool.codex.skillsFolder.appending(path: "nested/SKILL.md").resolvingSymlinksInPath().path == localLibrary.appending(path: "nested/SKILL.md").path,
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
    let discoverAvailable = RegistrySkill(name: "Made-up repository", description: "Made-up skills for UI verification",
      repo: "https://example.invalid/made-up-repository", tools: nil, author: "Demo")
    let discoverInLibrary = RegistrySkill(name: libraryOnlyName, description: "Made-up library repository",
      repo: libraryOnlySource.path, tools: nil, author: "Custom")
    let pendingLocalSource = home.appending(path: "fixtures/pending-local-folder")
    try writeSkill(pendingLocalSource, name: "pending-local-skill")
    let discoverLocalAvailable = RegistrySkill(name: "Pending local folder", description: "Made-up local skills for UI verification",
      repo: pendingLocalSource.path, tools: nil, author: "Custom")
    let manualSource = store.registrySkills.first { $0.repo == "https://github.com/Graphify-Labs/graphify" }!
    let scenes: [(String, AnyView)] = [
      ("library", AnyView(ContentView(skill: prefix).environment(store))),
      ("library-light", AnyView(ContentView(skill: prefix).environment(store))),
      ("discover", AnyView(ContentView(sidebar: .discover).environment(store))),
      ("discover-available", AnyView(DiscoverDetail(skill: discoverAvailable).environment(store))),
      ("discover-manual", AnyView(DiscoverDetail(skill: manualSource).environment(store))),
      ("discover-local-available", AnyView(DiscoverDetail(skill: discoverLocalAvailable).environment(store))),
      ("discover-in-library", AnyView(DiscoverDetail(skill: discoverInLibrary).environment(store))),
      ("discover-in-library-light", AnyView(DiscoverDetail(skill: discoverInLibrary).environment(store))),
      ("unlinked-source", AnyView(ContentView(sidebar: .repo(unlinkedName), skill: unlinkedName).environment(store))),
      ("skillset", AnyView(ContentView(sidebar: .skillset(store.skillsets[0].id)).environment(store))),
      ("assignment-manager", AnyView(SkillsetAssignmentsSheet(skillsetID: store.skillsets[0].id).environment(store))),
      ("assignment-manager-light", AnyView(SkillsetAssignmentsSheet(skillsetID: store.skillsets[0].id).environment(store))),
      ("skillset-editor", AnyView(SkillsetEditor(skillset: store.skillsets[0]).environment(store))),
      ("skillset-preview", AnyView(SkillsetPreview(skillsetID: store.skillsets[0].id, tool: .amp, assigned: true).environment(store))),
      ("tool-skillsets", AnyView(ContentView(sidebar: .tool(.amp)).environment(store))),
      ("suggestions", AnyView(ContentView(sidebar: .suggestions).environment(store))),
      ("settings", AnyView(SettingsView().environment(store))),
    ]
    for (name, view) in scenes {
      NSApp.appearance = NSAppearance(named: name.hasSuffix("-light") ? .aqua : .darkAqua)
      host.rootView = AnyView(view.id(name))
      window.setContentSize(CGSize(width: 1180, height: 760))
      try await Task.sleep(for: .seconds(1))
      let content = window.contentView!.superview!
      let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
      content.cacheDisplay(in: content.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])!.write(to: output.appending(path: "\(name).png"))
      print("PASS: rendered \(name)")
    }

    // A same-name independent copy must survive repository removal.
    try writeSkill(Tool.amp.skillsFolder.appending(path: prefix), name: prefix)
    var trashed = try SkillInstaller.removeRepo(name: destination.lastPathComponent)
    trashed += redownloadTrash
    trashed += skillsetTrash
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
      && bulkRemoval.message(tools: [.amp]).contains("1 selected skill has no removable copies"),
      "bulk uninstall confirmation counts removable and protected selections")
    trashed += try SkillInstaller.remove(bulkRemoval.copies)
    try check(bulkNames.allSatisfy { !fm.fileExists(atPath: Tool.amp.skillsFolder.appending(path: $0).path) },
      "bulk uninstall moves every selected user skill to Trash")
    // Clean up only the exact paths returned for this run's made-up artifacts.
    for item in trashed {
      try fm.removeItem(at: item)
    }
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
    let repo = Paths.at(".config/skillscout/skills/\(base)")
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
    trashed += await store.applySkillset(id: a.id, to: .amp, assigned: false)
    try check(fm.fileExists(atPath: Tool.amp.skillsFolder.appending(path: common).path), "unassigning keeps overlapping skills")
    try check(!fm.fileExists(atPath: Tool.amp.skillsFolder.appending(path: alpha).path), "unassigning removes only no-longer-needed owned links")
    try check(fm.fileExists(atPath: Tool.amp.skillsFolder.appending(path: manual).path), "unassigning preserves personal folders")
    let restored = AppStore()
    await restored.start()
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
