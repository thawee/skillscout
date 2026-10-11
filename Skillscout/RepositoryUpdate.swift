import Foundation

struct ResolvedRepoUpdate: Identifiable, Sendable {
  let update: RepoUpdate
  let staged: URL
  let added: [String]
  let changed: [String]
  let removed: [String]
  let review: SkillReview
  let preservedLocalPaths: [String]
  let mergedPaths: [String]
  let newSkills: [RepositorySkill]
  fileprivate let seal: String
  var id: URL { staged }
}

struct RepoUpdate: Identifiable, Sendable {
  let name: String
  /// The source address without any credentials.
  let source: String
  let staged: URL
  let oldCommit: String?
  let newCommit: String?
  let added: [String]
  let removed: [String]
  let changed: [String]
  /// The review of the added and changed files.
  let review: SkillReview
  /// The current copy's file hashes when the update was prepared, so apply can refuse a copy that changed since.
  fileprivate let currentFingerprints: [String: String]
  fileprivate let nextFingerprints: [String: String]
  fileprivate let currentMetadata: Data?
  fileprivate let nextMetadata: Data?
  fileprivate let repoFolder: URL
  fileprivate let linkRoots: [SkillRoot]
  let selectedRef: RepositoryRef
  let previousRef: RepositoryRef?
  let hasLocalEdits: Bool
  let changedSkills: [String]
  let files: [RepoUpdateFile]
  let newSkills: [RepositorySkill]
  fileprivate let currentSeal: String
  fileprivate let incomingSeal: String
  fileprivate let baselineChanged: Bool
  fileprivate let comparisons: [String: RepositoryMerge.Comparison]
  fileprivate let localTree: [String: RepositoryMerge.Entry]
  fileprivate let incomingTree: [String: RepositoryMerge.Entry]

  var repositoryFolder: URL { repoFolder }

  var id: URL { staged }
  var hasChanges: Bool { baselineChanged || !added.isEmpty || !removed.isEmpty || !changed.isEmpty || files.contains { $0.status == .incoming || $0.status == .merged || $0.status == .conflict } || oldCommit != newCommit || previousRef != selectedRef }
}

extension SkillInstaller {
  enum RepoUpdateFailure: LocalizedError {
    case changedSincePreview(String), localEdits(String), stagedChanged(String), unresolved(String), invalidResolution(String)

    var errorDescription: String? {
      switch self {
      case .unresolved(let path): "Choose how to resolve \(path) before reviewing the result."
      case .invalidResolution(let path): "The resolution for \(path) is invalid. Review its contents again."
      case .localEdits(let name): "\(name) has local edits. Choose Replace local edits to apply this update."
      case .stagedChanged(let name): "The staged version of \(name) changed. Prepare the update again."
      case .changedSincePreview(let name): "\(name) changed in the Library since the update was previewed. Refresh it again to see the current changes."
      }
    }
  }

  /// Whether a copy's files live in the Library, directly or through a link, so they came from a downloaded repository.
  static func isFromLibrary(_ copy: SkillCopy) -> Bool {
    if copy.root.kind == .managed { return true }
    let library = SkillRoot.all.first { $0.kind == .managed }!.url.resolvingSymlinksInPath().path
    return copy.resolved.resolvingSymlinksInPath().path.hasPrefix(library + "/")
  }

  /// The Library repository a copy's files live in, directly or through a link.
  static func libraryRepo(of copy: SkillCopy) -> String? {
    let library = SkillRoot.all.first { $0.kind == .managed }!.url.resolvingSymlinksInPath().path
    let path = copy.resolved.resolvingSymlinksInPath().path
    guard path.hasPrefix(library + "/") else { return nil }
    return path.dropFirst(library.count + 1).split(separator: "/").first.map(String.init)
  }

  static func managedRepoFolder(_ name: String) -> URL {
    SkillRoot.all.first { $0.kind == .managed }!.url.appending(path: name)
  }

  /// The source a managed repository was added from: its local folder, or its Git remote.
  static func repoSource(name: String) throws -> String {
    guard !name.isEmpty, name == slug(name) else { throw InstallFailure.notFound }
    let repoFolder = managedRepoFolder(name)
    if let snapshot = try RepositoryLibrary.snapshot(in: repoFolder) { return snapshot.source.address }
    guard let source = RepositoryLibrary.legacySource(in: repoFolder) else { throw InstallFailure.notFound }
    return source.address
  }

  /// A source address with any user name, password or token removed.
  static func redactedSource(_ source: String) -> String {
    RepositoryLibrary.cleanAddress(source)
  }

  /// The short commit of a Git checkout, or nil for a folder without Git.
  static func gitCommit(_ folder: URL) -> String? {
    guard FileManager.default.fileExists(atPath: folder.appending(path: ".git").path) else { return nil }
    return (try? RepositoryGit.runSynchronously(["-C", folder.path, "rev-parse", "--short", "HEAD"], timeout: 5))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Downloads or copies the repository's source again into a hidden staging folder and compares it with the current copy.
  /// Nothing in the Library changes until `applyRepoUpdate`.
  static func prepareRepoUpdate(name: String, ref: RepositoryRef? = nil, expectedCommit: String? = nil,
                                root: URL = RepositoryLibrary.managedRoot, linkRoots: [SkillRoot] = SkillRoot.all,
                                token: String? = nil) async throws -> RepoUpdate {
    guard !name.isEmpty, name == slug(name) else { throw InstallFailure.notFound }
    try RepositoryMerge.validateAncestors(root)
    let repoFolder = root.appending(path: name)
    let prefix = ".\(name)-staged-"
    let fm = FileManager.default
    for entry in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where entry.hasPrefix(prefix) {
      let folder = root.appending(path: entry)
      guard UUID(uuidString: String(entry.dropFirst(prefix.count))) != nil,
            let attributes = try? fm.attributesOfItem(atPath: folder.path),
            attributes[.type] as? FileAttributeType == .typeDirectory,
            let modified = attributes[.modificationDate] as? Date,
            Date().timeIntervalSince(modified) > 24 * 60 * 60 else { continue }
      try? fm.removeItem(at: folder)
    }
    let currentSeal = try RepositoryMerge.seal(repoFolder)
    let localTree = try RepositoryMerge.tree(repoFolder)
    let snapshot = try RepositoryLibrary.snapshot(in: repoFolder)
    guard let source = snapshot?.source ?? RepositoryLibrary.legacySource(in: repoFolder) else { throw InstallFailure.notFound }
    let current = SkillReview.fingerprints(repoFolder)
    let currentMetadata = try? Data(contentsOf: repoFolder.appending(path: RepositoryLibrary.markerName))
    var oldCommit = snapshot?.commit
    if oldCommit == nil, source.isGit { oldCommit = try await RepositoryLibrary.fullCommit(in: repoFolder) }
    let baseline = try RepositoryMerge.baseline(in: repoFolder, snapshot: snapshot, commit: oldCommit)
    let hasLocalEdits = baseline.map { base in
      if base["."]?.kind != .directory {
        return base != localTree.filter { $0.value.kind != .directory }
      }
      return base != localTree
    } ?? snapshot.map { $0.baselineFingerprints != current } ?? true
    let installedRef = snapshot?.ref ?? RepositoryLibrary.legacySnapshot(in: repoFolder, source: source)?.ref
    let preview = try await RepositoryLibrary.preview(source: source, ref: ref ?? installedRef ?? .defaultBranch, token: token)
    defer { RepositoryLibrary.discard(preview) }
    if let expectedCommit, preview.commit != expectedCommit { throw RepositoryLibrary.Failure.expectedCommit(expectedCommit) }
    let staged = root.appending(path: ".\(name)-staged-\(UUID().uuidString)")
    try copyRepositoryPreview(preview, to: staged, consume: true)
    let incomingTree: [String: RepositoryMerge.Entry]
    let incomingSeal: String
    var comparisons: [String: RepositoryMerge.Comparison] = [:]
    do {
      incomingTree = try RepositoryMerge.tree(staged)
      incomingSeal = try RepositoryMerge.seal(staged)
      let paths = Set(localTree.keys).union(incomingTree.keys).union(baseline?.keys.map { $0 } ?? [])
      for path in paths.sorted() {
        comparisons[path] = try RepositoryMerge.compare(path: path, base: baseline?[path], baseKnown: baseline != nil,
          legacyHash: snapshot?.baselineFingerprints[path], local: localTree[path], incoming: incomingTree[path],
          directoryBaseKnown: baseline?["."]?.kind == .directory)
      }
      let nonDirectories = Set(localTree.filter { $0.value.kind != .directory }.keys)
        .union(incomingTree.filter { $0.value.kind != .directory }.keys)
      comparisons = RepositoryMerge.structuralConflicts(comparisons, nonDirectories: nonDirectories)
      guard try RepositoryMerge.seal(repoFolder) == currentSeal else { throw RepoUpdateFailure.changedSincePreview(name) }
    } catch { try? fm.removeItem(at: staged); throw error }
    let next = preview.fingerprints
    let added = incomingTree.keys.filter { localTree[$0] == nil }.sorted()
    let removed = localTree.keys.filter { incomingTree[$0] == nil }.sorted()
    let changed = incomingTree.keys.filter { localTree[$0] != nil && localTree[$0] != incomingTree[$0] }.sorted()
    let changedPaths = Set(added + removed + changed)
    let affected = RepositoryLibrary.skills(in: repoFolder) + preview.skills
    let changedSkills = Set(affected.filter { skill in
      let prefix = skill.relativePath == "." ? "" : skill.relativePath + "/"
      return changedPaths.contains { $0.hasPrefix(prefix) }
    }.map { $0.skill.name }).sorted()
    return RepoUpdate(name: name, source: redactedSource(source.address), staged: staged,
      oldCommit: oldCommit, newCommit: preview.commit, added: added, removed: removed, changed: changed,
      review: preview.review.limited(to: Set(added + changed)), currentFingerprints: current,
      nextFingerprints: next, currentMetadata: currentMetadata,
      nextMetadata: try? Data(contentsOf: staged.appending(path: RepositoryLibrary.markerName)), repoFolder: repoFolder,
      linkRoots: linkRoots, selectedRef: preview.ref, previousRef: snapshot?.ref, hasLocalEdits: hasLocalEdits,
      changedSkills: changedSkills, files: comparisons.values.map(\.file).sorted { $0.path < $1.path },
      newSkills: preview.skills.filter { incoming in !RepositoryLibrary.skills(in: repoFolder).contains { $0.relativePath == incoming.relativePath } },
      currentSeal: currentSeal, incomingSeal: incomingSeal, baselineChanged: baseline.map { $0 != incomingTree } ?? snapshot.map { $0.baselineFingerprints != next } ?? true, comparisons: comparisons, localTree: localTree, incomingTree: incomingTree)
  }

  static func discardRepoUpdate(_ update: RepoUpdate) {
    guard validStage(update.staged, for: update, kind: "staged") else { return }
    do { try RepositoryMerge.validateAncestors(update.staged.deletingLastPathComponent()) } catch { return }
    try? FileManager.default.removeItem(at: update.staged)
  }

  static func discardRepoUpdate(_ resolved: ResolvedRepoUpdate) {
    guard validStage(resolved.staged, for: resolved.update, kind: "resolved") else { return }
    do { try RepositoryMerge.validateAncestors(resolved.staged.deletingLastPathComponent()) } catch { return }
    try? FileManager.default.removeItem(at: resolved.staged)
  }

  private static func validStage(_ folder: URL, for update: RepoUpdate, kind: String) -> Bool {
    let prefix = ".\(update.name)-\(kind)-"
    return folder.deletingLastPathComponent().standardizedFileURL == update.repoFolder.deletingLastPathComponent().standardizedFileURL
      && folder.lastPathComponent.hasPrefix(prefix)
      && UUID(uuidString: String(folder.lastPathComponent.dropFirst(prefix.count))) != nil
  }

  private static func validateRepoUpdate(_ update: RepoUpdate) throws {
    guard validStage(update.staged, for: update, kind: "staged"),
          update.repoFolder.lastPathComponent == update.name,
          (try? RepositoryMerge.seal(update.repoFolder)) == update.currentSeal else {
      throw RepoUpdateFailure.changedSincePreview(update.name)
    }
    if let expected = update.oldCommit {
      guard (try? RepositoryGit.runSynchronously(["-C", update.repoFolder.path, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)) == expected else {
        throw RepoUpdateFailure.changedSincePreview(update.name)
      }
    }
    guard (try? RepositoryMerge.seal(update.staged)) == update.incomingSeal else {
      throw RepoUpdateFailure.stagedChanged(update.name)
    }
    if let expected = update.newCommit {
      let actual = try RepositoryGit.runSynchronously(["-C", update.staged.path, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard actual == expected else { throw RepoUpdateFailure.stagedChanged(update.name) }
    }
  }

  static func resolveRepoUpdate(_ update: RepoUpdate, resolutions: [String: RepoFileResolution]) throws -> ResolvedRepoUpdate {
    try validateRepoUpdate(update)
    guard resolutions.keys.allSatisfy({ update.comparisons[$0] != nil }) else {
      throw RepoUpdateFailure.invalidResolution(resolutions.keys.first { update.comparisons[$0] == nil } ?? "file")
    }
    var files: [String: RepositoryMerge.Entry] = [:]
    var preserved: [String] = []
    var merged: [String] = []
    for path in update.comparisons.keys.sorted() {
      let comparison = update.comparisons[path]!
      let entry: RepositoryMerge.Entry?
      switch resolutions[path] {
      case .keepMine: entry = update.localTree[path]
      case .useIncoming: entry = update.incomingTree[path]
      case .merge(let text):
        guard comparison.file.canMerge, text.utf8.count <= RepositoryMerge.maxTextSize,
              !text.contains("\0"), !RepositoryMerge.hasMarkers(text), let local = update.localTree[path] else {
          throw RepoUpdateFailure.invalidResolution(path)
        }
        entry = RepositoryMerge.Entry(kind: .file, data: Data(text.utf8), mode: local.mode)
        merged.append(path)
      case nil:
        guard comparison.file.status != .conflict else { throw RepoUpdateFailure.unresolved(path) }
        entry = comparison.automatic
        if comparison.file.status == .merged { merged.append(path) }
      }
      if let entry { files[path] = entry }
      if entry != update.incomingTree[path] && !merged.contains(path) { preserved.append(path) }
    }
    for path in Array(files.keys) where path != "." {
      var ancestor = (path as NSString).deletingLastPathComponent
      while !ancestor.isEmpty {
        if files[ancestor] == nil {
          guard resolutions[ancestor] == nil,
                let directory = update.localTree[ancestor] ?? update.incomingTree[ancestor], directory.kind == .directory else {
            throw RepoUpdateFailure.invalidResolution(ancestor)
          }
          files[ancestor] = directory
          if directory != update.incomingTree[ancestor] { preserved.append(ancestor) }
        }
        ancestor = (ancestor as NSString).deletingLastPathComponent
      }
    }
    return try resolvedResult(update, files: files, preserved: Array(Set(preserved)), merged: merged)
  }

  private static func resolvedResult(_ update: RepoUpdate, files: [String: RepositoryMerge.Entry],
                                     preserved: [String], merged: [String]) throws -> ResolvedRepoUpdate {
    try RepositoryMerge.validateTree(files)
    let fm = FileManager.default
    let folder = update.repoFolder.deletingLastPathComponent().appending(path: ".\(update.name)-resolved-\(UUID().uuidString)")
    try fm.createDirectory(at: folder, withIntermediateDirectories: false)
    do {
      for name in RepositoryMerge.reserved.union([".git"]) {
        let source = update.staged.appending(path: name)
        if (try? fm.attributesOfItem(atPath: source.path)) != nil { try fm.copyItem(at: source, to: folder.appending(path: name)) }
      }
      try RepositoryMerge.materialize(files, in: folder)
      let added = files.keys.filter { update.localTree[$0] == nil }.sorted()
      let removed = update.localTree.keys.filter { files[$0] == nil }.sorted()
      let changed = files.keys.filter { update.localTree[$0] != nil && update.localTree[$0] != files[$0] }.sorted()
      try checkLinksSurvive(repoFolder: update.repoFolder, replacement: folder, roots: update.linkRoots)
      try validateRepoUpdate(update)
      let oldSkills = Set(RepositoryLibrary.skills(in: update.repoFolder).map(\.relativePath))
      return ResolvedRepoUpdate(update: update, staged: folder, added: added, changed: changed, removed: removed,
        review: SkillReview.inspect(folder), preservedLocalPaths: preserved.sorted(), mergedPaths: merged.sorted(),
        newSkills: RepositoryLibrary.skills(in: folder).filter { !oldSkills.contains($0.relativePath) }, seal: try RepositoryMerge.seal(folder))
    } catch { try? fm.removeItem(at: folder); throw error }
  }

  @discardableResult
  static func applyRepoUpdate(_ update: RepoUpdate, replaceLocalEdits: Bool = false,
                              trash: ((URL) throws -> [URL])? = nil) throws -> [URL] {
    defer { discardRepoUpdate(update) }
    try validateRepoUpdate(update)
    let resolved: ResolvedRepoUpdate
    if replaceLocalEdits { resolved = try resolvedResult(update, files: update.incomingTree, preserved: [], merged: []) }
    else { resolved = try resolveRepoUpdate(update, resolutions: [:]) }
    defer { discardRepoUpdate(resolved) }
    return try applyRepoUpdate(resolved, trash: trash)
  }

  @discardableResult
  static func applyRepoUpdate(_ resolved: ResolvedRepoUpdate, trash: ((URL) throws -> [URL])? = nil) throws -> [URL] {
    let update = resolved.update
    try validateRepoUpdate(update)
    guard validStage(resolved.staged, for: update, kind: "resolved"),
          (try? RepositoryMerge.seal(resolved.staged)) == resolved.seal else {
      throw RepoUpdateFailure.stagedChanged(update.name)
    }
    if let expected = update.newCommit {
      guard try RepositoryGit.runSynchronously(["-C", resolved.staged.path, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines) == expected else {
        throw RepoUpdateFailure.stagedChanged(update.name)
      }
    }
    try checkLinksSurvive(repoFolder: update.repoFolder, replacement: resolved.staged, roots: update.linkRoots)
    let fm = FileManager.default
    let repoFolder = update.repoFolder
    let backup = repoFolder.deletingLastPathComponent().appending(path: ".\(update.name)-backup-\(UUID().uuidString)")
    try fm.moveItem(at: repoFolder, to: backup)
    do {
      try fm.moveItem(at: resolved.staged, to: repoFolder)
      let locations: [URL]
      if let trash { locations = try trash(backup) }
      else {
        var result: NSURL?
        try fm.trashItem(at: backup, resultingItemURL: &result)
        locations = result.map { [$0 as URL] } ?? []
      }
      discardRepoUpdate(update)
      return locations
    } catch {
      if fm.fileExists(atPath: repoFolder.path) && !fm.fileExists(atPath: resolved.staged.path) {
        try? fm.moveItem(at: repoFolder, to: resolved.staged)
      }
      if fm.fileExists(atPath: backup.path) && !fm.fileExists(atPath: repoFolder.path) {
        try fm.moveItem(at: backup, to: repoFolder)
      }
      throw error
    }
  }

  /// Existing links keep their target path when the new repository replaces the old one.
  /// Refuses an update that would leave any of those paths broken.
  private static func checkLinksSurvive(repoFolder: URL, replacement: URL, roots: [SkillRoot] = SkillRoot.all) throws {
    let fm = FileManager.default
    let repositoryPath = repoFolder.resolvingSymlinksInPath().path
    let replacementPath = replacement.resolvingSymlinksInPath().path
    for root in roots where root.kind == .user || root.kind == .shared {
      guard fm.fileExists(atPath: root.url.path) else { continue }
      for link in try fm.contentsOfDirectory(at: root.url, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
        guard (try link.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true else { continue }
        let target = link.resolvingSymlinksInPath().path
        guard target == repositoryPath || target.hasPrefix(repositoryPath + "/") else { continue }
        let relative = String(target.dropFirst(repositoryPath.count))
        let skill = URL(fileURLWithPath: replacement.path + relative).resolvingSymlinksInPath()
        let file = skill.appending(path: "SKILL.md").resolvingSymlinksInPath()
        guard (skill.path == replacementPath || skill.path.hasPrefix(replacementPath + "/")),
              file.path.hasPrefix(replacementPath + "/"), fm.fileExists(atPath: file.path) else {
          throw InstallFailure.linkedSkillMissing(Paths.describe(link))
        }
      }
    }
  }
}
