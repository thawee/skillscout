import Foundation

extension AppStore {
  func reloadRepositories() async {
    repositoryLoadGeneration += 1
    var generation = repositoryLoadGeneration
    let catalog = registrySkills
    let task = Task.detached {
      let entries = RepositoryLibrary.inventory(catalog: catalog)
      let contents = entries.reduce(into: [RepositoryID: [RepositorySkill]]()) { result, entry in
        if let folder = entry.installedFolder {
          result[entry.id] = RepositoryLibrary.skills(in: folder)
        }
      }
      return (entries, contents)
    }
    repositoryLoadTask = task
    var loaded = await task.value
    while generation != repositoryLoadGeneration {
      generation = repositoryLoadGeneration
      guard let latest = repositoryLoadTask else { return }
      loaded = await latest.value
    }
    repositories = loaded.0
    repositoryContents = loaded.1
    repositoryChecks = repositoryChecks.filter { id, check in
      guard let entry = repositories.first(where: { $0.id == id }) else { return false }
      return entry.installedFolder != nil && (entry.snapshot == nil || entry.snapshot?.commit == check.installedCommit)
    }
    for entry in repositories where entry.installedFolder != nil {
      if let preview = repositoryPreviews.removeValue(forKey: entry.id) {
        RepositoryLibrary.discard(preview)
      }
    }
  }

  func repositorySkills(_ entry: RepositoryEntry) -> [RepositorySkill] {
    if entry.installedFolder != nil { return repositoryContents[entry.id] ?? [] }
    return repositoryPreviews[entry.id]?.skills ?? []
  }

  func scopedSkill(_ item: RepositorySkill) -> Skill {
    let related = skills.first { $0.id == item.skill.id }?.copies.filter {
      $0.resolved == item.copy.resolved && $0 != item.copy
    } ?? []
    return Skill(name: item.skill.name, description: item.skill.description, copies: [item.copy] + related)
  }

  func loadRepositoryPreview(_ entry: RepositoryEntry, token: String? = nil) {
    guard !repositoryBusy.contains(entry.id), entry.installedFolder == nil else { return }
    repositoryBusy.insert(entry.id)
    repositoryErrors[entry.id] = nil
    repositoryTasks[entry.id] = Task {
      defer {
        repositoryBusy.remove(entry.id)
        repositoryTasks[entry.id] = nil
      }
      do {
        let preview = try await RepositoryLibrary.preview(source: entry.source, token: token)
        if Task.isCancelled {
          RepositoryLibrary.discard(preview)
          return
        }
        if let old = repositoryPreviews.updateValue(preview, forKey: entry.id) {
          RepositoryLibrary.discard(old)
        }
      } catch is CancellationError {
      } catch {
        repositoryErrors[entry.id] = error.localizedDescription
      }
    }
  }

  func cancelRepositoryPreview(_ entry: RepositoryEntry) {
    repositoryTasks[entry.id]?.cancel()
  }

  func importRepository(_ entry: RepositoryEntry, token: String? = nil) async {
    guard !repositoryBusy.contains(entry.id), entry.installedFolder == nil else { return }
    repositoryBusy.insert(entry.id)
    repositoryErrors[entry.id] = nil
    defer { repositoryBusy.remove(entry.id) }
    do {
      let preview: RepositoryPreview
      if let existing = repositoryPreviews[entry.id] {
        preview = existing
      } else {
        preview = try await RepositoryLibrary.preview(source: entry.source, token: token)
      }
      defer {
        RepositoryLibrary.discard(preview)
        repositoryPreviews[entry.id] = nil
      }
      _ = try await Task.detached { try SkillInstaller.importRepository(preview: preview, explicitTools: [], consumePreview: true) }.value
      await refreshSkills()
    } catch {
      repositoryErrors[entry.id] = error.localizedDescription
    }
  }

  func checkRepository(_ entry: RepositoryEntry, token: String? = nil) async {
    guard entry.installedFolder != nil, !repositoryBusy.contains(entry.id) else { return }
    repositoryBusy.insert(entry.id)
    repositoryErrors[entry.id] = nil
    defer { repositoryBusy.remove(entry.id) }
    do {
      repositoryChecks[entry.id] = try await RepositoryLibrary.check(entry: entry, token: token)
    } catch {
      repositoryErrors[entry.id] = error.localizedDescription
    }
  }

  func checkAllRepositories() async {
    guard !isCheckingRepositories else { return }
    isCheckingRepositories = true
    defer { isCheckingRepositories = false }
    for entry in repositories where entry.source.isGit && entry.installedFolder != nil {
      if Task.isCancelled { break }
      await checkRepository(entry)
    }
  }

  func reviewRepositoryUpdate(_ entry: RepositoryEntry, ref: RepositoryRef? = nil, token: String? = nil) async {
    guard let folder = entry.installedFolder, pendingRepoUpdate == nil, !isPreparingRepositoryUpdate,
          !repositoryBusy.contains(entry.id), !isManagingSkillsets else { return }
    repositoryBusy.insert(entry.id)
    isPreparingRepositoryUpdate = true
    repositoryErrors[entry.id] = nil
    defer { repositoryBusy.remove(entry.id); isPreparingRepositoryUpdate = false }
    do {
      pendingRepoUpdate = try await SkillInstaller.prepareRepoUpdate(name: folder.lastPathComponent, ref: ref,
        expectedCommit: ref == nil && repositoryChecks[entry.id]?.status == .updateAvailable ? repositoryChecks[entry.id]?.latestCommit : nil,
        token: token)
    } catch {
      repositoryErrors[entry.id] = error.localizedDescription
    }
  }

  func removeRepository(_ entry: RepositoryEntry) async {
    guard let folder = entry.installedFolder, !repositoryBusy.contains(entry.id), !isManagingSkillsets,
          pendingRepoUpdate == nil, !isPreparingRepositoryUpdate else { return }
    repositoryBusy.insert(entry.id)
    defer { repositoryBusy.remove(entry.id) }
    await deleteRepo(name: folder.lastPathComponent)
    repositoryChecks[entry.id] = nil
  }

  @discardableResult
  func finishResolvedRepoUpdate(_ resolved: ResolvedRepoUpdate) async -> [URL] {
    guard let pending = pendingRepoUpdate, pending.staged == resolved.update.staged,
          !isApplyingRepositoryUpdate else { return [] }
    guard !isManagingSkillsets else { return [] }
    isApplyingRepositoryUpdate = true
    isManagingSkillsets = true
    defer { isApplyingRepositoryUpdate = false; isManagingSkillsets = false }
    var trashed: [URL] = []
    do {
      trashed = try await Task.detached { try SkillInstaller.applyRepoUpdate(resolved) }.value
    } catch {
      errorMessage = error.localizedDescription
    }
    SkillInstaller.discardRepoUpdate(resolved)
    SkillInstaller.discardRepoUpdate(pending)
    pendingRepoUpdate = nil
    await refreshSkills()
    return trashed
  }
}
