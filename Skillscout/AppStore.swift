import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
  var skills: [Skill] = []
  var prompts: [Prompt] = []
  var usage: [Skill.ID: SkillUsage] = [:]
  /// The tools you use, in `Tool.allCases` order. Skillscout ignores the others.
  var tools: [Tool] = Tool.enabled
  var suggestions: [Suggestion] = []
  var skillsets: [Skillset] = []
  var skillsetAssignments: [SkillsetAssignment] = []
  var skillsetEntries: [SkillsetEntry] = []
  var skillsetIssues: [String: [String]] = [:]
  var skillsetNotes: [String: [String]] = [:]
  var preferredSources: [Skill.ID: String] = [:]
  var isManagingSkillsets = false
  var registrySkills: [RegistrySkill] = []
  var explanations: [String: String] = [:]
  var dismissed: [String] = []
  /// Pairs of your skills that read alike, most alike first.
  var similar: [SimilarPair] = []
  /// The pairs you said aren't alike, by `SimilarPair.id`.
  var dismissedPairs: [String] = []
  /// Merged SKILL.md drafts, by `MergePlan.id`.
  var mergeDrafts: [String: String] = [:]
  var analyzedIDs: Set<String> = []
  var lastAnalysis: Date?

  var isLoadingPrompts = false
  var isAnalyzing = false
  var busy: Set<String> = []
  var errorMessage: String?
  var pendingRepoUpdate: RepoUpdate?
  var pendingReviewedAdd: PendingReviewedAdd?
  var addConflict: SkillInstaller.AddConflict?
  var searchRequests = 0
  /// Copies waiting for you to confirm, before they go to the Trash.
  var removal: Removal?
  /// The skill whose new name you're typing.
  var renaming: Skill?
  var editing: Skill?
  /// A skill to select once it has a new name, or once a merge made it.
  var revealRequest: Skill.ID?

  @ObservationIgnored private let library = PromptLibrary()
  @ObservationIgnored private var allPrompts: [Prompt] = []
  @ObservationIgnored private var uses: [SkillUse] = []
  @ObservationIgnored private var watcher: FileWatcher?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var skillsDirty = false
  @ObservationIgnored private var promptsDirty = false
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  @ObservationIgnored private var lastAutoAttempt: Date?

  private let stateFile = Paths.stateFile

  var newPromptCount: Int {
    prompts.count(where: { !analyzedIDs.contains($0.id) })
  }

  var managedRepos: [String] {
    var repos: Set<String> = []
    for skill in skills {
      for repo in skill.managedRepos {
        repos.insert(repo)
      }
    }
    return Array(repos).sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
  }

  var registeredLocalSources: [RegistrySkill] {
    registrySkills.filter { source in
      guard source.repo.hasPrefix("/") else { return false }
      let repo = SkillInstaller.repoName(for: source.repo)
      let marker = Paths.at(".config/skillscout/skills/\(repo)/.skillscout-local-source")
      return (try? String(contentsOf: marker, encoding: .utf8)) != source.repo
    }
  }

  func loadRegistry() async {
    do {
      var allSkills = try await Registry.shared.fetch()
      let defaultRepos = Set(allSkills.map(\.repo))
      allSkills.append(contentsOf: CustomRegistry.shared.fetch().filter { !defaultRepos.contains($0.repo) })
      registrySkills = allSkills
    } catch {
      errorMessage = "Failed to load skills from the registry: \(error.localizedDescription)"
    }
  }

  func skill(_ id: Skill.ID?) -> Skill? {
    skills.first { $0.id == id }
  }

  func preferredSource(for skill: Skill) -> SkillCopy? {
    let candidates = SkillInstaller.installableSources(for: skill)
    if let path = preferredSources[skill.id] {
      return candidates.first { $0.resolved.path == path }
    }
    return SkillInstaller.defaultSource(for: skill)
  }

  @discardableResult
  func setPreferredSource(_ source: SkillCopy, for skill: Skill) -> Bool {
    guard SkillInstaller.installableSources(for: skill).contains(where: { $0.resolved.path == source.resolved.path }) else { return false }
    let previous = preferredSources[skill.id]
    preferredSources[skill.id] = source.resolved.path
    guard saveState() else {
      preferredSources[skill.id] = previous
      return false
    }
    return true
  }

  func suggestion(_ id: Suggestion.ID?) -> Suggestion? {
    suggestions.first { $0.id == id }
  }

  // MARK: - Loading

  func start() async {
    guard !started else { return }
    started = true
    UserDefaults.standard.register(defaults: ["lookbackDays": 60, "autoAnalyze": true, "autoThreshold": 40])
    loadState()
    await refreshSkills()
    await refreshPrompts()

    let folders = [".agents", ".config/agents", ".config/skillscout/skills", ".gemini/antigravity-cli"] + Tool.allCases.flatMap(\.homeFolders)
    let paths = folders.map { Paths.at($0).path }.filter { FileManager.default.fileExists(atPath: $0) }
    watcher = FileWatcher(paths: paths) { [weak self] changed in
      Task { @MainActor in self?.handle(changed) }
    }
  }

  func setTool(_ tool: Tool, enabled: Bool) {
    tools = Tool.allCases.filter { $0 == tool ? enabled : tools.contains($0) }
    UserDefaults.standard.set(tools.map(\.rawValue), forKey: "tools")
    applyTools()
  }

  func refreshSkills() async {
    let dismissed = Set(dismissedPairs)
    (skills, similar) = await Task.detached {
      let skills = SkillScanner.scan()
      return (skills, SkillSimilarity.pairs(in: skills, dismissed: dismissed))
    }.value
    applyTools()
  }

  func refreshPrompts() async {
    isLoadingPrompts = true
    (allPrompts, uses) = await library.load(lookbackDays: UserDefaults.standard.integer(forKey: "lookbackDays"))
    applyTools()
    isLoadingPrompts = false
    await maybeAnalyzeAutomatically()
  }

  private func applyTools() {
    let enabled = Set(tools)
    prompts = allPrompts.filter { enabled.contains($0.tool) }
    usage = SkillUsage.tally(uses.filter { enabled.contains($0.tool) }, skills: skills, aliases: SkillAliases.load())
  }

  private static let chatFolders = [
    "/agent-transcripts/", "/.codex/sessions/", "/.codex/archived_sessions/", "/.claude/projects/",
    "/.gemini/tmp/", "/.factory/sessions/", "/.pi/agent/sessions/", "/.local/share/amp/threads/", "/.local/share/opencode/opencode.db",
    "/.gemini/antigravity-cli/brain/", "/.copilot/session-store.db",
  ]

  private func handle(_ changed: [String]) {
    for path in changed {
      if Self.chatFolders.contains(where: path.contains) || path.hasSuffix("/.claude/history.jsonl") {
        promptsDirty = true
      } else if path.contains("/skills") || path.contains("/plugins/cache/") || path.contains("/plugins/local/")
        || path.hasSuffix("/.claude/settings.json") {
        skillsDirty = true
      }
    }
    guard skillsDirty || promptsDirty, refreshTask == nil else { return }

    refreshTask = Task {
      while skillsDirty || promptsDirty {
        try? await Task.sleep(for: .seconds(3))
        let (doSkills, doPrompts) = (skillsDirty, promptsDirty)
        skillsDirty = false
        promptsDirty = false
        if doSkills { await refreshSkills() }
        if doPrompts { await refreshPrompts() }
      }
      refreshTask = nil
    }
  }

  // MARK: - Actions

  func analyze() async {
    guard !isAnalyzing, !prompts.isEmpty else { return }
    isAnalyzing = true
    defer { isAnalyzing = false }

    do {
      let found = try await Analyzer.findSuggestions(prompts: prompts, skills: skills, dismissed: dismissed, engine: .current)
      let skillNames = Set(skills.map(\.name))
      let kept = suggestions.filter { $0.draft != nil && $0.savedTo == nil }
      let fresh = found.filter { candidate in
        !skillNames.contains(candidate.name) && !dismissed.contains(candidate.name) && !kept.contains { $0.name == candidate.name }
      }
      suggestions = kept + fresh
      analyzedIDs = Set(prompts.map(\.id))
      lastAnalysis = .now
      saveState()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func maybeAnalyzeAutomatically() async {
    let defaults = UserDefaults.standard
    guard defaults.bool(forKey: "autoAnalyze"),
          lastAnalysis != nil,
          newPromptCount >= defaults.integer(forKey: "autoThreshold"),
          lastAutoAttempt.map({ Date.now.timeIntervalSince($0) > 1800 }) ?? true
    else { return }
    lastAutoAttempt = .now
    await analyze()
  }

  func explain(_ skill: Skill) async {
    let key = skill.primary.contentHash
    let busyKey = "explain:\(key)"
    guard explanations[key] == nil, !busy.contains(busyKey),
          let text = try? String(contentsOf: skill.skillFile, encoding: .utf8)
    else { return }

    busy.insert(busyKey)
    defer { busy.remove(busyKey) }
    do {
      explanations[key] = try await Analyzer.explain(name: skill.name, skillText: text, engine: .current)
      saveState()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Adds a skill to a tool. A source from a downloaded repository with scripts or high-risk commands
  /// is shown for review first, unless the user already reviewed it.
  func add(_ skill: Skill, to tool: Tool, from source: SkillCopy? = nil, reviewed: Bool = false) async {
    if !reviewed, let chosen = source ?? preferredSource(for: skill), SkillInstaller.isFromLibrary(chosen) {
      let review = SkillReview.inspect(chosen.resolved)
      if review.needsReview {
        pendingReviewedAdd = PendingReviewedAdd(skill: skill, tool: tool, source: source, folder: chosen.resolved, review: review)
        return
      }
    }
    do {
      _ = try SkillInstaller.add(skill, to: tool, from: source ?? preferredSource(for: skill))
      if let source { setPreferredSource(source, for: skill) }
      await refreshSkills()
    } catch let conflict as SkillInstaller.AddConflict {
      addConflict = conflict
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func replaceInstallation(_ conflict: SkillInstaller.AddConflict) async {
    do {
      _ = try SkillInstaller.replace(conflict)
      setPreferredSource(conflict.source, for: conflict.skill)
    } catch {
      errorMessage = error.localizedDescription
    }
    await refreshSkills()
  }

  func remove(_ copies: [SkillCopy]) async {
    do {
      try SkillInstaller.remove(copies)
    } catch {
      errorMessage = error.localizedDescription
    }
    await refreshSkills()
  }

  func moveToCentral(_ skill: Skill) async {
    do {
      _ = try SkillInstaller.moveToCentral(skill)
      await refreshSkills()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func rename(_ skill: Skill, to name: String) async {
    do {
      try SkillInstaller.rename(skill, to: name, among: skills)
      await refreshSkills()
      revealRequest = name
    } catch {
      errorMessage = error.localizedDescription
      await refreshSkills()
    }
  }

  /// Throws instead of showing an alert, so the editor stays open with your text.
  func save(_ edit: SkillInstaller.Edit, text: String, overwrite: Bool) async throws {
    try SkillInstaller.save(edit, text: text, overwrite: overwrite)
    await refreshSkills()
  }

  func dismissPair(_ pair: SimilarPair) {
    dismissedPairs.append(pair.id)
    similar.removeAll { $0.id == pair.id }
    saveState()
  }

  func draftMerge(_ plan: SkillInstaller.MergePlan) async {
    let busyKey = "merge:\(plan.id)"
    busy.insert(busyKey)
    defer { busy.remove(busyKey) }
    do {
      mergeDrafts[plan.id] = try await Analyzer.mergeSkills(plan, engine: .current)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func merge(_ plan: SkillInstaller.MergePlan) async {
    guard let draft = mergeDrafts[plan.id] else { return }
    do {
      try SkillInstaller.merge(plan, markdown: draft)
      mergeDrafts[plan.id] = nil
      await refreshSkills()
      revealRequest = plan.kept.id
    } catch {
      errorMessage = error.localizedDescription
      await refreshSkills()
    }
  }

  func draft(_ id: Suggestion.ID) async {
    guard let suggestion = suggestion(id) else { return }
    let busyKey = "draft:\(id)"
    busy.insert(busyKey)
    defer { busy.remove(busyKey) }
    do {
      let markdown = try await Analyzer.draftSkill(for: suggestion, engine: .current)
      updateDraft(id, markdown)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func updateDraft(_ id: Suggestion.ID, _ markdown: String) {
    guard let index = suggestions.firstIndex(where: { $0.id == id }) else { return }
    suggestions[index].draft = markdown
    scheduleSave()
  }

  func save(_ id: Suggestion.ID, to target: SaveTarget) async {
    guard let index = suggestions.firstIndex(where: { $0.id == id }), let draft = suggestions[index].draft else { return }
    do {
      let folder = try SkillInstaller.save(markdown: draft, fallbackName: suggestions[index].name, to: target)
      suggestions[index].savedTo = folder.path
      saveState()
      await refreshSkills()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func dismiss(_ id: Suggestion.ID) {
    guard let suggestion = suggestion(id) else { return }
    dismissed.append(suggestion.name)
    suggestions.removeAll { $0.id == id }
    saveState()
  }

  // MARK: - Skillsets

  func createSkillset(name: String) {
    skillsets.append(Skillset(name: name))
    saveState()
  }

  func toggleSkillInSkillset(skill: Skill, skillsetID: UUID) {
    guard let set = skillsets.first(where: { $0.id == skillsetID }) else { return }
    setSkillMembership([skill.id], in: skillsetID, included: !set.skills.contains(skill.id))
  }

  // MARK: - Persistence

  private struct SavedState: Codable {
    var suggestions: [Suggestion]
    var dismissed: [String]
    var explanations: [String: String]
    var analyzedIDs: [String]
    var lastAnalysis: Date?
    var skillsets: [Skillset]?
    var skillsetAssignments: [SkillsetAssignment]?
    var skillsetEntries: [SkillsetEntry]?
    var skillsetIssues: [String: [String]]?
    var preferredSources: [Skill.ID: String]?
    var dismissedPairs: [String]?
  }

  private func loadState() {
    guard let data = try? Data(contentsOf: stateFile),
          let state = try? JSONDecoder().decode(SavedState.self, from: data)
    else { return }
    suggestions = state.suggestions
    dismissed = state.dismissed
    explanations = state.explanations
    analyzedIDs = Set(state.analyzedIDs)
    lastAnalysis = state.lastAnalysis
    if let loaded = state.skillsets { skillsets = loaded }
    skillsetAssignments = state.skillsetAssignments ?? []
    skillsetEntries = state.skillsetEntries ?? []
    skillsetIssues = state.skillsetIssues ?? [:]
    preferredSources = state.preferredSources ?? [:]
    dismissedPairs = state.dismissedPairs ?? []
  }

  @discardableResult
  func saveState() -> Bool {
    saveTask?.cancel()
    saveTask = nil
    let state = SavedState(
      suggestions: suggestions,
      dismissed: dismissed,
      explanations: explanations,
      analyzedIDs: Array(analyzedIDs),
      lastAnalysis: lastAnalysis,
      skillsets: skillsets,
      skillsetAssignments: skillsetAssignments,
      skillsetEntries: skillsetEntries,
      skillsetIssues: skillsetIssues,
      preferredSources: preferredSources,
      dismissedPairs: dismissedPairs
    )
    do {
      let data = try JSONEncoder().encode(state)
      try data.write(to: stateFile, options: .atomic)
      return true
    } catch {
      errorMessage = "Couldn't save Skillscout's state: \(error.localizedDescription)"
      return false
    }
  }

  private func scheduleSave() {
    saveTask?.cancel()
    saveTask = Task {
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      saveState()
    }
  }

  func addRepoToLibrary(source: String, token: String? = nil) async throws -> URL {
    let destination = try await SkillInstaller.install(source: source, explicitTools: [], token: token)
    await refreshSkills()
    return destination
  }

  func deleteRepo(name: String) async {
    do {
      try SkillInstaller.removeRepo(name: name)
    } catch {
      errorMessage = error.localizedDescription
    }
    await refreshSkills()
  }

  /// Prepares and applies a repository update without a preview.
  @discardableResult
  func redownloadRepo(name: String) async throws -> [URL] {
    let update = try await SkillInstaller.prepareRepoUpdate(name: name)
    let trashed = try SkillInstaller.applyRepoUpdate(update)
    await refreshSkills()
    return trashed
  }

  /// Stages a repository update and shows its changes for the user to apply or discard.
  func previewRepoUpdate(name: String) async {
    do {
      pendingRepoUpdate = try await SkillInstaller.prepareRepoUpdate(name: name)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Applies or discards the previewed update, and returns where the previous copy went in the Trash.
  @discardableResult
  func finishRepoUpdate(apply: Bool) async -> [URL] {
    guard let update = pendingRepoUpdate else { return [] }
    pendingRepoUpdate = nil
    guard apply else {
      SkillInstaller.discardRepoUpdate(update)
      return []
    }
    var trashed: [URL] = []
    do { trashed = try SkillInstaller.applyRepoUpdate(update) }
    catch { errorMessage = error.localizedDescription }
    await refreshSkills()
    return trashed
  }

  func repairLibrary() async -> String {
    var fixedSymlinks = 0
    var renamedRepos = 0
    var deletedSymlinks = 0
    let fm = FileManager.default

    // 1. Rename incorrectly named managed repos
    let managedRoot = SkillRoot.all.first { $0.kind == .managed }!.url
    if let enumerator = fm.enumerator(at: managedRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
      while let folder = enumerator.nextObject() as? URL {
        enumerator.skipDescendants()
        let gitConfig = folder.appending(path: ".git/config")
        if let configStr = try? String(contentsOf: gitConfig, encoding: .utf8) {
          if let range = configStr.range(of: "url = ") {
            let urlStr = String(configStr[range.upperBound...].split(separator: "\n").first!.trimmingCharacters(in: .whitespacesAndNewlines))
            let expectedName: String
            if urlStr.hasPrefix("http"), let url = URL(string: urlStr) {
               expectedName = SkillInstaller.slug(url.path.replacingOccurrences(of: ".git", with: ""))
            } else if urlStr.hasPrefix("git@") {
               let path = urlStr.components(separatedBy: ":").last?.replacingOccurrences(of: ".git", with: "") ?? urlStr
               expectedName = SkillInstaller.slug(path)
            } else {
               expectedName = SkillInstaller.slug(URL(string: urlStr)?.lastPathComponent.replacingOccurrences(of: ".git", with: "") ?? urlStr)
            }
            if folder.lastPathComponent != expectedName {
               let newFolder = managedRoot.appending(path: expectedName)
               if !fm.fileExists(atPath: newFolder.path) {
                 try? fm.moveItem(at: folder, to: newFolder)
                 renamedRepos += 1
                 // Now update all symlinks pointing to `folder`
                 for root in SkillRoot.all.filter({ $0.kind != .managed && $0.kind != .plugin }) {
                   if let entries = try? fm.contentsOfDirectory(at: root.url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                     for entry in entries {
                       if let isSymlink = (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink, isSymlink {
                         if let target = try? fm.destinationOfSymbolicLink(atPath: entry.path) {
                           let absoluteTarget = URL(fileURLWithPath: target, relativeTo: entry.deletingLastPathComponent()).standardizedFileURL
                           if absoluteTarget.path.hasPrefix(folder.path) {
                             let remainder = absoluteTarget.path.dropFirst(folder.path.count)
                             let newTarget = newFolder.path + remainder
                             try? fm.removeItem(at: entry)
                             try? fm.createSymbolicLink(at: entry, withDestinationURL: URL(fileURLWithPath: newTarget))
                             fixedSymlinks += 1
                           }
                         }
                       }
                     }
                   }
                 }
               }
            }
          }
        }
      }
    }

    // 2. Delete broken symlinks
    for root in SkillRoot.all.filter({ $0.kind != .managed && $0.kind != .plugin }) {
      if let entries = try? fm.contentsOfDirectory(at: root.url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
        for entry in entries {
          if let isSymlink = (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink, isSymlink {
            if !fm.fileExists(atPath: entry.appending(path: "SKILL.md").path) && !fm.fileExists(atPath: entry.resolvingSymlinksInPath().path) {
              try? fm.removeItem(at: entry)
              deletedSymlinks += 1
            }
          }
        }
      }
    }

    await refreshSkills()

    var msgs: [String] = []
    if renamedRepos > 0 { msgs.append("Renamed \(renamedRepos) repos") }
    if fixedSymlinks > 0 { msgs.append("Fixed \(fixedSymlinks) links") }
    if deletedSymlinks > 0 { msgs.append("Deleted \(deletedSymlinks) broken links") }
    return msgs.isEmpty ? "No issues found." : msgs.joined(separator: ", ") + "."
  }
}

/// An Add to tool request waiting for the user to read the skill's scripts and flagged commands.
struct PendingReviewedAdd: Identifiable {
  let id = UUID()
  let skill: Skill
  let tool: Tool
  let source: SkillCopy?
  let folder: URL
  let review: SkillReview
}
