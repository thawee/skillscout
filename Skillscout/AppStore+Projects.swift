import Foundation

extension AppStore {
  private struct ProjectSaveFailure: LocalizedError {
    var errorDescription: String? { "Project changes stopped because Quartermaster could not save its state. Retry recovery after fixing the save error." }
  }

  func project(_ id: UUID) -> RegisteredProject? { projectState.projects.first { $0.id == id } }

  @discardableResult
  func registerProject(_ folder: URL) -> RegisteredProject? {
    guard !isManagingProjects else { return nil }
    do {
      let registered = try ProjectLibrary.register(folder, projects: projectState.projects)
      if !projectState.projects.contains(where: { $0.id == registered.id }) {
        let previous = projectState
        projectState.projects.append(registered)
        guard saveState() else { projectState = previous; return nil }
      }
      rebuildProjectWatcher()
      Task { await refreshProjectInventories() }
      return registered
    } catch { errorMessage = error.localizedDescription; return nil }
  }

  @discardableResult
  func forgetProject(_ id: UUID) -> Bool {
    guard !isManagingProjects else { return false }
    guard projectState.pending?.projectID != id else {
      errorMessage = "Recover the pending project operation before forgetting this project."
      return false
    }
    let previous = projectState
    projectState.projects.removeAll { $0.id == id }
    projectState.assignments.removeAll { $0.projectID == id }
    projectState.entries.removeAll { $0.projectID == id }
    guard saveState() else { projectState = previous; return false }
    projectInventories[id] = nil
    projectIssues[id] = nil
    projectNotes[id] = nil
    rebuildProjectWatcher()
    return true
  }

  func refreshProjectInventories() async {
    projectRefreshRevision += 1
    let revision = projectRefreshRevision
    let projects = projectState.projects
    let globalSkills = skills
    let inventories = await Task.detached {
      projects.map { ProjectLibrary.inventory(project: $0, globalSkills: globalSkills) }
    }.value
    guard revision == projectRefreshRevision else { return }
    let registered = Set(projectState.projects.map(\.id))
    projectInventories = Dictionary(uniqueKeysWithValues: inventories.filter { registered.contains($0.project.id) }.map { ($0.project.id, $0) })
    rebuildProjectWatcher()
  }

  private var projectObservedRoots: [String] {
    projectState.projects.flatMap { project in
      let roots = ProjectSkillRoot.all.map { $0.url(in: project) }
      let copies = projectInventories[project.id]?.skills.flatMap(\.localCopies) ?? []
      return roots.flatMap { [$0.path, $0.resolvingSymlinksInPath().path] } + copies.map { $0.resolved.path }
    }
  }

  func rebuildProjectWatcher() {
    let desired = FileWatcher.watchPaths(for: projectState.projects.map(\.path) + projectObservedRoots)
    guard desired != projectWatchPaths else { return }
    projectWatcher = nil
    projectWatchPaths = desired
    guard !desired.isEmpty else { return }
    projectWatcher = FileWatcher(paths: desired) { [weak self] changed in
      Task { @MainActor in self?.handleProjectChanges(changed) }
    }
  }

  private func handleProjectChanges(_ changed: [String]) {
    let projectPaths = projectState.projects.map(\.path)
    let roots = projectObservedRoots
    guard changed.contains(where: { event in
      let path = URL(fileURLWithPath: event).standardizedFileURL.path
      return projectPaths.contains { path == $0 || $0.hasPrefix(path + "/") }
        || roots.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
    }) else { return }
    projectRefreshTask?.cancel()
    projectRefreshTask = Task {
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      await refreshProjectInventories()
      projectRefreshTask = nil
    }
  }

  func projectUsage(_ project: RegisteredProject, tool: Tool? = nil, now: Date = Date()) -> [String: SkillUsage] {
    _ = reportUsageRevision
    let rows = projectInventories[project.id]?.skills ?? []
    var byFolder: [String: String] = [:]
    var byName: [String: String] = [:]
    for row in rows {
      byName[row.name] = row.name
      for copy in row.localCopies {
        byFolder[copy.folder.path] = row.name
        byFolder[copy.resolved.path] = row.name
        byName[copy.folder.lastPathComponent] = byName[copy.folder.lastPathComponent] ?? row.name
      }
      for copy in row.globalSkill?.copies ?? [] {
        byFolder[copy.folder.path] = row.name
        byFolder[copy.resolved.path] = row.name
        byName[copy.folder.lastPathComponent] = byName[copy.folder.lastPathComponent] ?? row.name
      }
    }
    let aliases = SkillAliases.load()
    for (old, new) in aliases where byName[old] == nil {
      var name = new
      var visited: Set<String> = []
      while byName[name] == nil, visited.insert(name).inserted, let next = aliases[name] { name = next }
      byName[old] = byName[name]
    }
    let enabled = tool.map { Set(tools).intersection([$0]) } ?? Set(tools)
    let scope = UsageScope(days: usageScope.days)
    var result: [String: SkillUsage] = [:]
    var counted: Set<RecordedSkillChat> = []
    // Cursor chats name their project only by a folder name made from its path.
    let cursorNames = PromptLibrary.cursorProjectNames(forPath: project.path)
    for use in scope.filter(recordedSkillUses, now: now) where enabled.contains(use.tool) {
      let owner = use.projectPath.flatMap { path in
        projectState.projects.filter({ path == $0.path || path.hasPrefix($0.path + "/") }).max(by: { $0.path.count < $1.path.count })?.id
      }
      guard owner == project.id || (use.projectPath == nil && use.tool == .cursor && cursorNames.contains(use.project)),
            let id = byFolder[use.folder] ?? (!use.folder.hasPrefix("/") ? byName[(use.folder as NSString).lastPathComponent] : nil) else { continue }
      var entry = result[id] ?? SkillUsage()
      entry.firstUsed = min(entry.firstUsed, use.date)
      entry.lastUsed = max(entry.lastUsed, use.date)
      if counted.insert(RecordedSkillChat(skill: id, chat: RecordedChat(use))).inserted {
        entry.chats += 1
        entry.byTool[use.tool, default: 0] += 1
        entry.projects[project.path, default: 0] += 1
      }
      result[id] = entry
    }
    return result
  }

  func projectPlan(_ project: RegisteredProject, skillsetID: UUID, target: ProjectSkillTarget, unassign: Bool = false) -> ProjectSkillPlan? {
    if unassign {
      return SkillInstaller.projectUnassignPlan(project: project, state: projectState, skills: skills, skillsetID: skillsetID, target: target, preferredSources: preferredSources)
    }
    guard let skillset = skillsets.first(where: { $0.id == skillsetID }) else { return nil }
    return SkillInstaller.projectPlan(project: project, state: projectState, skills: skills, skillsetID: skillsetID,
      members: skillset.skills, target: target, preferredSources: preferredSources)
  }

  func projectSkillsPlan(_ project: RegisteredProject, skillIDs: Set<Skill.ID>, target: ProjectSkillTarget) -> ProjectSkillPlan? {
    SkillInstaller.projectSkillsPlan(project: project, state: projectState, skills: skills,
      skillIDs: skillIDs, target: target, preferredSources: preferredSources)
  }

  func projectRemoveSkillPlan(_ project: RegisteredProject, skillID: Skill.ID, target: ProjectSkillTarget) -> ProjectSkillPlan? {
    SkillInstaller.projectRemoveSkillPlan(project: project, state: projectState, skills: skills,
      skillID: skillID, target: target, preferredSources: preferredSources)
  }

  @discardableResult
  func applyProjectPlan(_ plan: ProjectSkillPlan) async -> [URL] {
    guard !isManagingProjects, !isManagingSkillsets else { return [] }
    isManagingProjects = true
    defer { isManagingProjects = false }
    var state = projectState
    do {
      let result = try SkillInstaller.applyProjectPlan(plan, state: &state) { updated in
        self.projectState = updated
        guard self.saveState() else { throw ProjectSaveFailure() }
      }
      projectState = state
      projectIssues[plan.project.id] = nil
      projectNotes[plan.project.id] = ["Project changes applied."] + result.notes
      await refreshProjectInventories()
      return result.trashed
    } catch {
      projectState = state
      projectIssues[plan.project.id] = [error.localizedDescription]
      projectNotes[plan.project.id] = nil
      await refreshProjectInventories()
      return []
    }
  }

  func abandonProjectRecovery() {
    guard let pending = projectState.pending, !isManagingProjects else { return }
    isManagingProjects = true
    defer { isManagingProjects = false }
    var state = projectState
    do {
      let result = try SkillInstaller.abandonProjectOperation(state: &state) { updated in
        self.projectState = updated
        guard self.saveState() else { throw ProjectSaveFailure() }
      }
      projectState = state
      projectIssues[pending.projectID] = nil
      projectNotes[pending.projectID] = result.notes
    } catch {
      projectState = state
      projectIssues[pending.projectID] = [error.localizedDescription]
    }
    Task { await refreshProjectInventories() }
  }

  func recoverProjects() {
    guard let pending = projectState.pending, !isManagingProjects else { return }
    isManagingProjects = true
    defer { isManagingProjects = false }
    var state = projectState
    do {
      let result = try SkillInstaller.recoverProjectOperation(state: &state) { updated in
        self.projectState = updated
        guard self.saveState() else { throw ProjectSaveFailure() }
      }
      projectState = state
      projectIssues[pending.projectID] = nil
      projectNotes[pending.projectID] = result.notes
    } catch {
      projectState = state
      projectIssues[pending.projectID] = [error.localizedDescription]
    }
    Task { await refreshProjectInventories() }
  }
}
