import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
  var skills: [Skill] = []
  var prompts: [Prompt] = []
  var usage: [Skill.ID: SkillUsage] = [:]
  var usageScope = UsageScope()
  var reportInspectionRevision = 0
  var reportUsageRevision = 0
  var loadedLookbackDays = 60
  var usageProjects: [String] = []
  var suggestionSaveIssues: [Suggestion.ID: [String]] = [:]
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
  var projectState = ProjectState()
  var projectInventories: [UUID: ProjectInventory] = [:]
  var projectIssues: [UUID: [String]] = [:]
  var projectNotes: [UUID: [String]] = [:]
  var isManagingProjects = false
  @ObservationIgnored var projectWatcher: FileWatcher?
  @ObservationIgnored var projectWatchPaths: [String] = []
  @ObservationIgnored var projectRefreshTask: Task<Void, Never>?
  @ObservationIgnored var projectRefreshRevision = 0
  var registrySkills: [RegistrySkill] = []
  var repositories: [RepositoryEntry] = []
  var repositoryPreviews: [RepositoryID: RepositoryPreview] = [:]
  var repositoryChecks: [RepositoryID: RepositoryCheck] = [:]
  var repositoryErrors: [RepositoryID: String] = [:]
  var repositoryBusy: Set<RepositoryID> = []
  var repositoryContents: [RepositoryID: [RepositorySkill]] = [:]
  var isCheckingRepositories = false
  var isPreparingRepositoryUpdate = false
  var isApplyingRepositoryUpdate = false
  @ObservationIgnored var repositoryLoadGeneration = 0
  @ObservationIgnored var repositoryLoadTask: Task<([RepositoryEntry], [RepositoryID: [RepositorySkill]]), Never>?
  @ObservationIgnored var repositoryTasks: [RepositoryID: Task<Void, Never>] = [:]
  var explanations: [String: String] = [:]
  var dismissed: [String] = []
  /// Pairs of your skills that read alike, most alike first.
  var similar: [SimilarPair] = []
  var plugins: [InstalledPlugin] = []
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
  var importNote: String?
  var addConflict: SkillInstaller.AddConflict?
  var pendingSkillAdd: SkillAddPresentation?
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
  @ObservationIgnored private var watchedRoots: [String] = []
  @ObservationIgnored private var started = false
  @ObservationIgnored private var skillsDirty = false
  @ObservationIgnored private var promptsDirty = false
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var skillsRefreshRevision = 0
  @ObservationIgnored private var appliedSkillsRefreshRevision = 0
  @ObservationIgnored private var promptsRefreshRevision = 0
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  @ObservationIgnored private var lastAutoAttempt: Date?

  private let stateFile = Paths.stateFile

  var recordedSkillUses: [SkillUse] { uses }

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
    // An import adds a suffix when the folder name is taken, so read every repository's marker.
    let root = RepositoryLibrary.managedRoot
    let repos = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    let installed = Set(repos.compactMap { try? String(contentsOf: root.appending(path: "\($0)/.skillscout-local-source"), encoding: .utf8) })
    return registrySkills.filter { $0.repo.hasPrefix("/") && !installed.contains($0.repo) }
  }

  func loadRegistry() async {
    do {
      var allSkills = try await Registry.shared.fetch()
      let defaultRepos = Set(allSkills.map(\.repo))
      allSkills.append(contentsOf: CustomRegistry.shared.fetch().filter { !defaultRepos.contains($0.repo) })
      registrySkills = allSkills
      await reloadRepositories()
    } catch {
      errorMessage = "Failed to load skills from the registry: \(error.localizedDescription)"
    }
  }

  func skill(_ id: Skill.ID?) -> Skill? {
    skills.first { $0.id == id }
  }

  func preferredSource(for skill: Skill) -> SkillCopy? {
    SkillInstaller.skillsetSource(skill, preferredSources: preferredSources)
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
    RepositoryLibrary.cleanupExpiredPreviews()
    UserDefaults.standard.register(defaults: ["lookbackDays": 60, "autoAnalyze": true, "autoThreshold": 40])
    loadState()
    await refreshSkills()
    await refreshPrompts()
    recoverProjects()
    rebuildProjectWatcher()

    let folders = [".agents", ".config/agents", ".config/skillscout/skills", ".config/skillscout/drafts", ".gemini/antigravity-cli"] + Tool.allCases.flatMap(\.homeFolders)
    let watchedHome = Paths.home.standardizedFileURL
    watchedRoots = folders.map { watchedHome.appending(path: $0).path }
    watcher = FileWatcher(paths: FileWatcher.watchPaths(for: watchedRoots)) { [weak self] changed in
      Task { @MainActor in self?.handle(changed) }
    }
  }

  func setTool(_ tool: Tool, enabled: Bool) {
    tools = Tool.allCases.filter { $0 == tool ? enabled : tools.contains($0) }
    UserDefaults.standard.set(tools.map(\.rawValue), forKey: "tools")
    applyTools()
  }

  func refreshSkills() async {
    skillsRefreshRevision += 1
    let revision = skillsRefreshRevision
    let dismissed = Set(dismissedPairs)
    let snapshot = await Task.detached {
      let skills = SkillScanner.scan()
      return (skills, SkillSimilarity.pairs(in: skills, dismissed: dismissed), PluginScanner.scan())
    }.value
    guard revision >= appliedSkillsRefreshRevision else { return }
    appliedSkillsRefreshRevision = revision
    (skills, similar, plugins) = snapshot
    reportInspectionRevision += 1
    applyTools()
    await refreshProjectInventories()
    await reloadRepositories()
  }

  func refreshPrompts() async {
    promptsRefreshRevision += 1
    let revision = promptsRefreshRevision
    isLoadingPrompts = true
    let days = UserDefaults.standard.integer(forKey: "lookbackDays")
    let loaded = await library.load(lookbackDays: days)
    // A newer load started meanwhile, and it applies its own results.
    guard revision == promptsRefreshRevision else { return }
    loadedLookbackDays = days
    if let scopeDays = usageScope.days, scopeDays >= loadedLookbackDays { usageScope.days = nil }
    (allPrompts, uses) = loaded
    applyTools()
    isLoadingPrompts = false
    await maybeAnalyzeAutomatically()
  }

  private func applyTools() {
    reportUsageRevision += 1
    let enabled = Set(tools)
    prompts = allPrompts.filter { enabled.contains($0.tool) }
    let enabledUses = uses.filter { enabled.contains($0.tool) }
    usageProjects = Array(Set(enabledUses.map(\.project))).sorted()
    usage = SkillUsage.tally(usageScope.filter(enabledUses), skills: skills, aliases: SkillAliases.load())
  }

  func setUsageScope(_ scope: UsageScope) {
    usageScope = scope
    if let days = usageScope.days, days >= loadedLookbackDays { usageScope.days = nil }
    applyTools()
  }

  func usageReport(scope: UsageScope, tool: Tool? = nil, includeSystemSkills: Bool = true, now: Date = Date()) -> UsageReport {
    _ = reportUsageRevision
    let readers = tool.map { Set([$0]) } ?? Set(tools)
    let reportSkills = includeSystemSkills ? skills : skills.filter { $0.isInLibrary || !$0.isSystemOnly(in: readers) }
    return UsageReport(uses: uses, skills: reportSkills, enabledTools: Set(tools), scope: scope, tool: tool,
      loadedDays: loadedLookbackDays, aliases: SkillAliases.load(), now: now)
  }

  var usageScopeDescription: String { usageScope.description(loadedDays: loadedLookbackDays) }

  func savedSkill(for suggestion: Suggestion) -> Skill? {
    suggestion.savedSkill(among: skills, aliases: SkillAliases.load())
  }

  func addReviewed(_ requests: [SkillAddRequest]) async -> [SkillAddResult] {
    guard !isManagingSkillsets else {
      return requests.map { SkillAddResult(request: $0, outcome: .failed("Wait for skillset changes to finish.")) }
    }
    isManagingSkillsets = true
    defer { isManagingSkillsets = false }
    await refreshSkills()
    let currentSkills = skills
    let enabled = Set(tools)
    let results = await Task.detached { requests.map { request in
      enabled.contains(request.tool) ? SkillInstaller.addReviewed(request, among: currentSkills)
        : SkillAddResult(request: request, outcome: .failed("This destination is disabled. Enable it in Settings and review again."))
    } }.value
    await refreshSkills()
    return results
  }

  func replaceReviewed(_ request: SkillAddRequest, conflict: SkillInstaller.AddConflict) async -> SkillAddResult {
    guard !isManagingSkillsets else {
      return SkillAddResult(request: request, outcome: .failed("Wait for skillset changes to finish."))
    }
    isManagingSkillsets = true
    defer { isManagingSkillsets = false }
    await refreshSkills()
    let currentSkills = skills
    guard tools.contains(request.tool) else {
      return SkillAddResult(request: request, outcome: .failed("This destination is disabled. Enable it in Settings and review again."))
    }
    let result = await Task.detached { SkillInstaller.replaceReviewed(request, conflict: conflict, among: currentSkills) }.value
    await refreshSkills()
    return result
  }

  private static let chatFolders = [
    "/agent-transcripts/", "/.codex/sessions/", "/.codex/archived_sessions/", "/.claude/projects/",
    "/.gemini/tmp/", "/.factory/sessions/", "/.pi/agent/sessions/", "/.local/share/amp/threads/", "/.local/share/opencode/opencode.db",
    "/.gemini/antigravity-cli/brain/", "/.copilot/session-store.db",
  ]

  private func handle(_ changed: [String]) {
    for changedPath in changed {
      let path = URL(fileURLWithPath: changedPath).standardizedFileURL.path
      guard watchedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) else { continue }
      if watchedRoots.contains(where: { path == $0 || $0.hasPrefix(path + "/") }) {
        skillsDirty = true
        promptsDirty = true
      }
      if Self.chatFolders.contains(where: path.contains) || path.hasSuffix("/.claude/history.jsonl") {
        promptsDirty = true
      } else if path.contains("/skills") || path.contains("/skillscout/drafts") || path.contains("/plugins/cache/") || path.contains("/plugins/local/")
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

  func explain(_ skill: Skill, from source: SkillCopy? = nil) async {
    let key = (source ?? skill.primary).contentHash
    let busyKey = "explain:\(key)"
    guard explanations[key] == nil, !busy.contains(busyKey),
          let text = try? String(contentsOf: (source ?? skill.primary).resolved.appending(path: "SKILL.md"), encoding: .utf8)
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
    guard tools.contains(tool) else { return }
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
    guard tools.contains(conflict.tool) else { return }
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
    guard !isManagingSkillsets else {
      errorMessage = "Wait for skillset changes to finish, then move \(skill.name) to Library."
      return
    }
    guard saveState() else { return }
    let owned = Set(skillsetEntries.filter(SkillInstaller.skillsetEntryIsUnchanged))
    do {
      let destination = try SkillInstaller.moveToCentral(skill).destination
      skillsetState.relocateSources(SkillInstaller.centralMoves(skill, to: destination), ownedBefore: owned)
      saveState()
    } catch {
      errorMessage = error.localizedDescription
    }
    await refreshSkills()
  }

  func rename(_ skill: Skill, to name: String) async {
    guard !isManagingSkillsets, saveState() else { return }
    let owned = Set(skillsetEntries.filter(SkillInstaller.skillsetEntryIsUnchanged))
    let moves = SkillInstaller.renameFolders(skill, to: name)
    do {
      try SkillInstaller.rename(skill, to: name, among: skills)
      skillsetState.migrateSkill(from: skill.id, to: name, movedFolders: moves, merging: false, ownedBefore: owned)
      saveState()
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

  @discardableResult
  func merge(_ plan: SkillInstaller.MergePlan) async -> [URL] {
    guard !isManagingSkillsets, let draft = mergeDrafts[plan.id], saveState() else { return [] }
    let owned = Set(skillsetEntries.filter(SkillInstaller.skillsetEntryIsUnchanged))
    var trashed: [URL] = []
    do {
      trashed = try SkillInstaller.merge(plan, markdown: draft)
      skillsetState.migrateSkill(from: plan.merged.id, to: plan.kept.id, movedFolders: plan.replacedFolders, merging: true, ownedBefore: owned)
      saveState()
      mergeDrafts[plan.id] = nil
      await refreshSkills()
      revealRequest = plan.kept.id
    } catch {
      errorMessage = error.localizedDescription
      await refreshSkills()
    }
    return trashed
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
      let result = try SkillInstaller.saveDraft(markdown: draft, fallbackName: suggestions[index].name, to: target)
      suggestions[index].savedTo = result.folder.path
      suggestions[index].savedSkillID = result.skillID
      suggestionSaveIssues[id] = result.issues
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

  fileprivate struct SavedState: Codable {
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
    var projectState: ProjectState?
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
    projectState = state.projectState ?? ProjectState()
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
      dismissedPairs: dismissedPairs,
      projectState: projectState
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
  func finishRepoUpdate(apply: Bool, replaceLocalEdits: Bool = false) async -> [URL] {
    guard let update = pendingRepoUpdate, !isApplyingRepositoryUpdate else { return [] }
    guard apply else {
      pendingRepoUpdate = nil
      SkillInstaller.discardRepoUpdate(update)
      return []
    }
    guard !isManagingSkillsets else { return [] }
    isApplyingRepositoryUpdate = true
    isManagingSkillsets = true
    defer { isApplyingRepositoryUpdate = false; isManagingSkillsets = false }
    var trashed: [URL] = []
    do {
      trashed = try await Task.detached { try SkillInstaller.applyRepoUpdate(update, replaceLocalEdits: replaceLocalEdits) }.value
    }
    catch { errorMessage = error.localizedDescription }
    pendingRepoUpdate = nil
    await refreshSkills()
    return trashed
  }

  func repairLibrary() async -> SkillInstaller.LibraryRepairResult {
    guard !isManagingSkillsets else {
      return SkillInstaller.LibraryRepairResult(issues: ["Wait for skillset changes to finish"])
    }
    guard saveState() else {
      return SkillInstaller.LibraryRepairResult(issues: ["Repair stopped because state could not be saved"])
    }
    let owned = Set(skillsetEntries.filter(SkillInstaller.skillsetEntryIsUnchanged))
    var result = SkillInstaller.repairLibrary()
    skillsetState.relocateFolders(result.movedFolders, removedPaths: result.removedPaths, ownedBefore: owned)
    if !saveState() { result.issues.append("Repaired files, but ownership changes could not be saved. Keep the app open and retry") }
    await refreshSkills()
    return result
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

extension AppStore.SavedState {
  /// Missing keys read as empty, so a state file written by the command line tool, which holds only
  /// skillsets, still loads.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      suggestions: try container.decodeIfPresent([Suggestion].self, forKey: .suggestions) ?? [],
      dismissed: try container.decodeIfPresent([String].self, forKey: .dismissed) ?? [],
      explanations: try container.decodeIfPresent([String: String].self, forKey: .explanations) ?? [:],
      analyzedIDs: try container.decodeIfPresent([String].self, forKey: .analyzedIDs) ?? [],
      lastAnalysis: try container.decodeIfPresent(Date.self, forKey: .lastAnalysis),
      skillsets: try container.decodeIfPresent([Skillset].self, forKey: .skillsets),
      skillsetAssignments: try container.decodeIfPresent([SkillsetAssignment].self, forKey: .skillsetAssignments),
      skillsetEntries: try container.decodeIfPresent([SkillsetEntry].self, forKey: .skillsetEntries),
      skillsetIssues: try container.decodeIfPresent([String: [String]].self, forKey: .skillsetIssues),
      preferredSources: try container.decodeIfPresent([Skill.ID: String].self, forKey: .preferredSources),
      dismissedPairs: try container.decodeIfPresent([String].self, forKey: .dismissedPairs),
      projectState: try container.decodeIfPresent(ProjectState.self, forKey: .projectState))
  }
}
