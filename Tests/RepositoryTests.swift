import Foundation
import Testing

@Suite struct RepositoryTests {
  private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "skillscout-repository-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func skill(_ name: String, in folder: URL, body: String = "Fixture") throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "---\nname: \(name)\ndescription: A made-up skill\n---\n\(body)\n".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
  }

  private func git(_ arguments: [String], in folder: URL) async throws -> String {
    try await RepositoryGit.run(["-C", folder.path] + arguments)
  }

  private func remote(in root: URL) async throws -> URL {
    let folder = root.appending(path: "remote")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    _ = try await git(["init", "-b", "main"], in: folder)
    try skill("fixture", in: folder.appending(path: "nested/fixture"))
    _ = try await git(["add", "."], in: folder)
    _ = try await git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"], in: folder)
    return folder
  }

  @Test func identityAndCredentialRedaction() throws {
    let https = try RepositorySource(address: "https://user:secret@GitHub.com/owner/repo.git?token=secret")
    let ssh = try RepositorySource(address: "git@github.com:owner/repo.git")
    #expect(https.address == "https://GitHub.com/owner/repo.git")
    #expect(RepositoryID(source: https) == RepositoryID(source: ssh))
    #expect(RepositoryID(source: .git("https://one.invalid/owner/repo")) != RepositoryID(source: .git("https://two.invalid/owner/repo")))
  }

  @Test func catalogMergePreservesInstalledTransportAndTokensStayTransient() throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "installed")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = RepositorySource.git("git@github.com:fixture/private.git")
    let sha = String(repeating: "a", count: 40)
    let marker = InstalledSnapshot(source: source, ref: .branch("main"), commit: sha, baselineFingerprints: [:], installedAt: Date())
    try JSONEncoder().encode(marker).write(to: folder.appending(path: RepositoryLibrary.markerName))
    let catalog = RegistrySkill(name: "Private", description: "Fixture", repo: "https://github.com/fixture/private", tools: nil, author: "Fixture")
    let entries = RepositoryLibrary.inventory(catalog: [catalog], root: root)
    #expect(entries.count == 1)
    #expect(entries[0].source == source)
    let https = try RepositorySource(address: catalog.repo)
    let transport = RepositoryLibrary.transportAddress(source: https, token: "secret-token")
    #expect(URLComponents(string: transport)?.password == "secret-token")
    #expect(RepositoryLibrary.cleanAddress(transport) == https.address)
    #expect(RepositoryLibrary.transportAddress(source: source, token: "secret-token") == source.address)
    #expect(try RepositoryLibrary.snapshot(in: folder) == marker)
  }

  @Test func commitPinnedCheckSucceedsWithoutAnAccessibleRemote() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let sha = String(repeating: "b", count: 40)
    let source = RepositorySource.git(root.appending(path: "missing-remote").absoluteString)
    let marker = InstalledSnapshot(source: source, ref: .commit(sha), commit: sha, baselineFingerprints: [:], installedAt: Date())
    try JSONEncoder().encode(marker).write(to: root.appending(path: RepositoryLibrary.markerName))
    let entry = RepositoryEntry(id: RepositoryID(source: source), name: "Fixture", description: "", source: source, catalog: nil, installedFolder: root, snapshot: marker)
    let check = try await RepositoryLibrary.check(entry: entry)
    #expect(check.status == .pinned)
    #expect(check.installedCommit == sha && check.latestCommit == sha)
  }

  @Test func linkedSkillCannotBeRedirectedOutsideAnUpdateSnapshot() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source"), outside = root.appending(path: "outside"), agents = root.appending(path: "agents"), library = root.appending(path: "library")
    try skill("fixture", in: source.appending(path: "nested/fixture"))
    try skill("external", in: outside)
    let preview = try await RepositoryLibrary.preview(source: .local(source.path)); defer { RepositoryLibrary.discard(preview) }
    let installed = try SkillInstaller.importRepository(preview: preview, root: library)
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: agents.appending(path: "fixture"), withDestinationURL: installed.appending(path: "nested/fixture"))
    let agentRoot = SkillRoot(label: "Fixture", url: agents, kind: .user, owner: .codex, readBy: [.codex])
    let file = source.appending(path: "nested/fixture/SKILL.md")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside.appending(path: "SKILL.md"))
    let update = try await SkillInstaller.prepareRepoUpdate(name: installed.lastPathComponent, root: library, linkRoots: [agentRoot])
    defer { SkillInstaller.discardRepoUpdate(update) }
    #expect(throws: SkillInstaller.InstallFailure.self) {
      try SkillInstaller.resolveRepoUpdate(update, resolutions: [:])
    }
    #expect(try String(contentsOf: agents.appending(path: "fixture/SKILL.md"), encoding: .utf8).contains("name: fixture"))
  }

  @Test func inventoryKeepsEmptyLegacyAndDamagedRepositories() throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let empty = root.appending(path: "old-empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    try "/fixture/local".write(to: empty.appending(path: ".skillscout-local-source"), atomically: true, encoding: .utf8)
    let git = root.appending(path: "legacy-git/.git")
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    try "[remote \"other\"]\n url = https://wrong.invalid/repo\n[remote \"origin\"]\n url = https://user:secret@example.invalid/owner/repo.git\n".write(to: git.appending(path: "config"), atomically: true, encoding: .utf8)
    try "broken".write(to: git.deletingLastPathComponent().appending(path: RepositoryLibrary.markerName), atomically: true, encoding: .utf8)
    let catalog = RegistrySkill(name: "Remote", description: "Fixture", repo: "https://example.invalid/owner/repo", tools: nil, author: "Fixture")
    let items = RepositoryLibrary.inventory(catalog: [catalog], root: root)
    #expect(items.count == 2)
    #expect(items.first(where: { $0.name == "Remote" })?.issue != nil)
    #expect(items.first(where: { $0.name == "old-empty" })?.installedFolder?.resolvingSymlinksInPath().path == empty.resolvingSymlinksInPath().path)
    #expect(RepositoryLibrary.inventory(catalog: [catalog], root: root).map(\.id) == items.map(\.id))
  }

  @Test func localSnapshotsAreScopedAndCollisionSafe() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appending(path: "one/same"), second = root.appending(path: "two/same"), library = root.appending(path: "library")
    try skill("duplicate", in: first.appending(path: "nested/first"), body: "First source")
    try skill("duplicate", in: second.appending(path: "nested/second"), body: "Second source")
    let a = try await RepositoryLibrary.preview(source: .local(first.path)); defer { RepositoryLibrary.discard(a) }
    let b = try await RepositoryLibrary.preview(source: .local(second.path)); defer { RepositoryLibrary.discard(b) }
    #expect(!FileManager.default.fileExists(atPath: library.path))
    let one = try SkillInstaller.importRepository(preview: a, root: library)
    let two = try SkillInstaller.importRepository(preview: b, root: library)
    #expect(one.lastPathComponent == "same")
    #expect(two.lastPathComponent.hasPrefix("same-"))
    #expect(try RepositoryLibrary.snapshot(in: one)?.source == .local(first.path))
    #expect(SkillReview.fingerprints(one) == a.fingerprints)
    #expect(!SkillReview.inspect(one).files.contains { $0.path == RepositoryLibrary.markerName })
    #expect(RepositoryLibrary.skills(in: one)[0].relativePath == "nested/first")
    #expect(RepositoryLibrary.skills(in: two)[0].skill.primary.resolved.path.hasPrefix(two.resolvingSymlinksInPath().path))
  }

  @Test func symlinkedLocalSourceImportsASeparateSnapshot() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source"), alias = root.appending(path: "alias"), library = root.appending(path: "library")
    try skill("fixture", in: source)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
    let original = SkillReview.fingerprints(source)
    let preview = try await RepositoryLibrary.preview(source: .local(alias.path)); defer { RepositoryLibrary.discard(preview) }
    let installed = try SkillInstaller.importRepository(preview: preview, root: library)
    #expect(try installed.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
    #expect(!FileManager.default.fileExists(atPath: source.appending(path: RepositoryLibrary.markerName).path))
    #expect(!FileManager.default.fileExists(atPath: source.appending(path: ".skillscout-local-source").path))
    #expect(SkillReview.fingerprints(source) == original)
    #expect(RepositoryLibrary.inventory(catalog: [], root: library).count == 1)
    try FileManager.default.removeItem(at: preview.folder)
    try FileManager.default.createSymbolicLink(at: preview.folder, withDestinationURL: source)
    #expect(throws: RepositoryLibrary.Failure.self) { try SkillInstaller.importRepository(preview: preview, root: library) }
    #expect(SkillReview.fingerprints(source) == original)
  }

  @Test func repositorySkillsStayInsideReviewedSnapshot() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source"), external = root.appending(path: "external")
    try skill("external", in: external)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: source.appending(path: "SKILL.md"), withDestinationURL: external.appending(path: "SKILL.md"))
    let preview = try await RepositoryLibrary.preview(source: .local(source.path)); defer { RepositoryLibrary.discard(preview) }
    #expect(preview.skills.isEmpty)
    let imported = try SkillInstaller.importRepository(preview: preview, root: root.appending(path: "library"))
    #expect(RepositoryLibrary.skills(in: imported).isEmpty)
    #expect(SkillReview.fingerprints(imported) == preview.fingerprints)
    #expect(!FileManager.default.fileExists(atPath: external.appending(path: RepositoryLibrary.markerName).path))
  }

  @Test func oneShotImportConsumesOnlyItsPreviewAndReplacesMarkerLinks() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source"), external = root.appending(path: "original"), library = root.appending(path: "library")
    try skill("fixture", in: source)
    try "Original".write(to: external, atomically: true, encoding: .utf8)
    for name in [RepositoryLibrary.markerName, ".skillscout-local-source"] {
      try FileManager.default.createSymbolicLink(at: source.appending(path: name), withDestinationURL: external)
    }
    let preview = try await RepositoryLibrary.preview(source: .local(source.path))
    let installed = try SkillInstaller.importRepository(preview: preview, root: library, consumePreview: true)
    #expect(!FileManager.default.fileExists(atPath: preview.folder.path))
    #expect(FileManager.default.fileExists(atPath: source.appending(path: "SKILL.md").path))
    #expect(try String(contentsOf: external, encoding: .utf8) == "Original")
    #expect(try RepositoryLibrary.snapshot(in: installed)?.source == .local(source.path))
    #expect(try FileManager.default.attributesOfItem(atPath: installed.appending(path: RepositoryLibrary.markerName).path)[.type] as? FileAttributeType == .typeRegular)
    let stale = try await RepositoryLibrary.preview(source: .local(source.path))
    try "Changed".write(to: stale.folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    #expect(throws: RepositoryLibrary.Failure.self) {
      try SkillInstaller.importRepository(preview: stale, root: root.appending(path: "other-library"), consumePreview: true)
    }
    #expect(!FileManager.default.fileExists(atPath: stale.folder.path))
    #expect(try String(contentsOf: external, encoding: .utf8) == "Original")
  }

  @Test func gitPreviewImportsExactSnapshotAndRefusesChanges() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let origin = try await remote(in: root)
    let preview = try await RepositoryLibrary.preview(source: .git(origin.absoluteString)); defer { RepositoryLibrary.discard(preview) }
    #expect(preview.commit?.count == 40)
    #expect(preview.ref == .branch("main"))
    #expect(preview.skills.map(\.relativePath) == ["nested/fixture"])
    let library = root.appending(path: "library")
    let folder = try SkillInstaller.importRepository(preview: preview, root: library)
    let stored = try RepositoryLibrary.snapshot(in: folder)
    #expect(stored?.commit == preview.commit)
    #expect(stored?.baselineFingerprints == preview.fingerprints)
    try "changed".write(to: preview.folder.appending(path: "nested/fixture/SKILL.md"), atomically: true, encoding: .utf8)
    #expect(throws: RepositoryLibrary.Failure.self) { try SkillInstaller.importRepository(preview: preview, root: library) }
    #expect(try RepositoryLibrary.snapshot(in: folder)?.commit == preview.commit)
  }

  private func commit(in folder: URL, message: String, empty: Bool = false) async throws -> String {
    _ = try await git(["add", "."], in: folder)
    var arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", message]
    if empty { arguments.append("--allow-empty") }
    _ = try await git(arguments, in: folder)
    return try await RepositoryLibrary.fullCommit(in: folder)
  }

  private func moveToFakeTrash(_ root: URL) -> (URL) throws -> [URL] {
    { backup in
      let destination = root.appending(path: "trash-" + UUID().uuidString)
      try FileManager.default.moveItem(at: backup, to: destination)
      return [destination]
    }
  }

  @Test func branchPreviewsLoadOnlyTheSelectedSnapshot() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let origin = try await remote(in: root)
    _ = try await commit(in: origin, message: "Earlier history", empty: true)
    _ = try await git(["checkout", "-b", "feature"], in: origin)
    try skill("fixture", in: origin.appending(path: "nested/fixture"), body: "Feature snapshot")
    let featureCommit = try await commit(in: origin, message: "Feature skill")
    _ = try await git(["checkout", "main"], in: origin)
    try skill("fixture", in: origin.appending(path: "nested/fixture"), body: "Main snapshot")
    let mainCommit = try await commit(in: origin, message: "Main skill")
    let source = RepositorySource.git(origin.absoluteString)
    for (ref, expectedRef, expectedCommit, body) in [
      (RepositoryRef.defaultBranch, RepositoryRef.branch("main"), mainCommit, "Main snapshot"),
      (RepositoryRef.branch("feature"), RepositoryRef.branch("feature"), featureCommit, "Feature snapshot")
    ] {
      let preview = try await RepositoryLibrary.preview(source: source, ref: ref)
      defer { RepositoryLibrary.discard(preview) }
      #expect(preview.ref == expectedRef)
      #expect(preview.commit == expectedCommit)
      #expect(preview.skills.map(\.relativePath) == ["nested/fixture"])
      #expect(try String(contentsOf: preview.folder.appending(path: "nested/fixture/SKILL.md"), encoding: .utf8).contains(body))
      #expect(try await git(["rev-list", "--count", "HEAD"], in: preview.folder).trimmingCharacters(in: .whitespacesAndNewlines) == "1")
      #expect(try await git(["rev-parse", "--is-shallow-repository"], in: preview.folder).trimmingCharacters(in: .whitespacesAndNewlines) == "true")
    }
  }

  @Test func checkAndCommitOnlyUpdateAdvanceWithoutChangingSkillFiles() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let origin = try await remote(in: root), library = root.appending(path: "library")
    let preview = try await RepositoryLibrary.preview(source: .git(origin.absoluteString)); defer { RepositoryLibrary.discard(preview) }
    let folder = try SkillInstaller.importRepository(preview: preview, root: library)
    let entry = RepositoryLibrary.inventory(catalog: [], root: library)[0]
    #expect(try await RepositoryLibrary.check(entry: entry).status == .upToDate)
    let latest = try await commit(in: origin, message: "Version only", empty: true)
    let result = try await RepositoryLibrary.check(entry: entry)
    #expect(result.status == .updateAvailable)
    #expect(result.latestCommit == latest)
    #expect(try RepositoryLibrary.snapshot(in: folder)?.commit == preview.commit)
    let update = try await SkillInstaller.prepareRepoUpdate(name: folder.lastPathComponent, expectedCommit: latest, root: library, linkRoots: [])
    #expect(update.hasChanges)
    #expect(update.changed.isEmpty && update.added.isEmpty && update.removed.isEmpty)
    #expect(!update.hasLocalEdits)
    _ = try SkillInstaller.applyRepoUpdate(update, trash: moveToFakeTrash(root))
    #expect(try RepositoryLibrary.snapshot(in: folder)?.commit == latest)
    #expect(SkillReview.fingerprints(folder) == preview.fingerprints)
    #expect(try await RepositoryLibrary.check(entry: RepositoryLibrary.inventory(catalog: [], root: library)[0]).status == .upToDate)
  }

  @Test func localEditsNeedExplicitReplacementAndStaleStagesAreRefused() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let origin = try await remote(in: root), library = root.appending(path: "library")
    let preview = try await RepositoryLibrary.preview(source: .git(origin.absoluteString)); defer { RepositoryLibrary.discard(preview) }
    let folder = try SkillInstaller.importRepository(preview: preview, root: library)
    try skill("fixture", in: folder.appending(path: "nested/fixture"), body: "Local edit")
    try skill("fixture", in: origin.appending(path: "nested/fixture"), body: "Upstream edit")
    _ = try await commit(in: origin, message: "Changed skill")
    let rejected = try await SkillInstaller.prepareRepoUpdate(name: folder.lastPathComponent, root: library, linkRoots: [])
    #expect(rejected.hasLocalEdits)
    #expect(rejected.changedSkills == ["fixture"])
    #expect(throws: SkillInstaller.RepoUpdateFailure.self) { try SkillInstaller.applyRepoUpdate(rejected, trash: moveToFakeTrash(root)) }
    #expect(try String(contentsOf: folder.appending(path: "nested/fixture/SKILL.md"), encoding: .utf8).contains("Local edit"))
    let stale = try await SkillInstaller.prepareRepoUpdate(name: folder.lastPathComponent, root: library, linkRoots: [])
    try skill("fixture", in: stale.staged.appending(path: "nested/fixture"), body: "Tampered stage")
    #expect(throws: SkillInstaller.RepoUpdateFailure.self) { try SkillInstaller.applyRepoUpdate(stale, replaceLocalEdits: true, trash: moveToFakeTrash(root)) }
    let accepted = try await SkillInstaller.prepareRepoUpdate(name: folder.lastPathComponent, root: library, linkRoots: [])
    _ = try SkillInstaller.applyRepoUpdate(accepted, replaceLocalEdits: true, trash: moveToFakeTrash(root))
    #expect(try String(contentsOf: folder.appending(path: "nested/fixture/SKILL.md"), encoding: .utf8).contains("Upstream edit"))
  }

  @Test func failedTrashSwapRestoresOldSnapshotAndMetadata() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let origin = try await remote(in: root), library = root.appending(path: "library")
    let preview = try await RepositoryLibrary.preview(source: .git(origin.absoluteString)); defer { RepositoryLibrary.discard(preview) }
    let folder = try SkillInstaller.importRepository(preview: preview, root: library)
    let oldMarker = try Data(contentsOf: folder.appending(path: RepositoryLibrary.markerName))
    _ = try await commit(in: origin, message: "Version only", empty: true)
    let update = try await SkillInstaller.prepareRepoUpdate(name: folder.lastPathComponent, root: library, linkRoots: [])
    #expect(throws: CocoaError.self) {
      try SkillInstaller.applyRepoUpdate(update, trash: { _ in throw CocoaError(.fileWriteNoPermission) })
    }
    #expect(try Data(contentsOf: folder.appending(path: RepositoryLibrary.markerName)) == oldMarker)
    #expect(try await RepositoryLibrary.fullCommit(in: folder) == preview.commit)
    #expect(SkillReview.fingerprints(folder) == preview.fingerprints)
  }

  @Test func metadataAndInstalledChangesInvalidateReview() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let origin = try await remote(in: root), library = root.appending(path: "library")
    let preview = try await RepositoryLibrary.preview(source: .git(origin.absoluteString)); defer { RepositoryLibrary.discard(preview) }
    let folder = try SkillInstaller.importRepository(preview: preview, root: library)
    _ = try await commit(in: origin, message: "Version only", empty: true)
    let update = try await SkillInstaller.prepareRepoUpdate(name: folder.lastPathComponent, root: library, linkRoots: [])
    try "damaged".write(to: folder.appending(path: RepositoryLibrary.markerName), atomically: true, encoding: .utf8)
    #expect(throws: SkillInstaller.RepoUpdateFailure.self) { try SkillInstaller.applyRepoUpdate(update, trash: moveToFakeTrash(root)) }
    let entry = RepositoryLibrary.inventory(catalog: [], root: library)[0]
    #expect(entry.issue != nil)
    await #expect(throws: RepositoryLibrary.Failure.self) { try await RepositoryLibrary.check(entry: entry) }
    await #expect(throws: RepositoryLibrary.Failure.self) { try await SkillInstaller.prepareRepoUpdate(name: folder.lastPathComponent, root: library, linkRoots: []) }
  }

  @Test func linkedSkillRemovalIsRefusedBeforeAndAfterReview() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let origin = try await remote(in: root), library = root.appending(path: "library"), agents = root.appending(path: "agents")
    let preview = try await RepositoryLibrary.preview(source: .git(origin.absoluteString)); defer { RepositoryLibrary.discard(preview) }
    let folder = try SkillInstaller.importRepository(preview: preview, root: library)
    let skillRoot = SkillRoot(label: "Fixture agent", url: agents, kind: .user, owner: .codex, readBy: [.codex])
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: agents.appending(path: "fixture"), withDestinationURL: folder.appending(path: "nested/fixture"))
    _ = try await commit(in: origin, message: "Version only", empty: true)
    let update = try await SkillInstaller.prepareRepoUpdate(name: folder.lastPathComponent, root: library, linkRoots: [skillRoot])
    try FileManager.default.removeItem(at: update.staged.appending(path: "nested/fixture"))
    #expect(throws: SkillInstaller.RepoUpdateFailure.self) { try SkillInstaller.applyRepoUpdate(update, trash: moveToFakeTrash(root)) }
    try FileManager.default.removeItem(at: origin.appending(path: "nested/fixture"))
    _ = try await commit(in: origin, message: "Remove skill")
    let removedLinked = try await SkillInstaller.prepareRepoUpdate(name: folder.lastPathComponent, root: library, linkRoots: [skillRoot])
    defer { SkillInstaller.discardRepoUpdate(removedLinked) }
    #expect(throws: SkillInstaller.InstallFailure.self) { try SkillInstaller.resolveRepoUpdate(removedLinked, resolutions: [:]) }
    let keptLinked = try SkillInstaller.resolveRepoUpdate(removedLinked, resolutions: ["nested/fixture/SKILL.md": .keepMine])
    defer { SkillInstaller.discardRepoUpdate(keptLinked) }
    #expect(FileManager.default.fileExists(atPath: keptLinked.staged.appending(path: "nested/fixture/SKILL.md").path))
    #expect(FileManager.default.fileExists(atPath: agents.appending(path: "fixture/SKILL.md").path))
    try FileManager.default.removeItem(at: agents.appending(path: "fixture"))
    let missingSkill = try await SkillInstaller.prepareRepoUpdate(name: folder.lastPathComponent, root: library, linkRoots: [skillRoot])
    try FileManager.default.createSymbolicLink(at: agents.appending(path: "fixture"), withDestinationURL: folder.appending(path: "nested/fixture"))
    #expect(throws: SkillInstaller.InstallFailure.self) { try SkillInstaller.applyRepoUpdate(missingSkill, trash: moveToFakeTrash(root)) }
    #expect(FileManager.default.fileExists(atPath: agents.appending(path: "fixture/SKILL.md").path))
  }

  @Test func tagsBranchesAndOldCommitPinsResolveAndStayPinned() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let origin = try await remote(in: root), library = root.appending(path: "library")
    let old = try await RepositoryLibrary.fullCommit(in: origin)
    _ = try await git(["tag", "lightweight"], in: origin)
    _ = try await git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "tag", "-a", "release", "-m", "Fixture release"], in: origin)
    _ = try await git(["branch", "feature"], in: origin)
    let newer = try await commit(in: origin, message: "New version", empty: true)
    let source = RepositorySource.git(origin.absoluteString)
    let refs = try await RepositoryLibrary.refs(source: source)
    #expect(refs.contains(.branch("main")) && refs.contains(.branch("feature")))
    #expect(refs.contains(.tag(name: "release", commit: old)))
    #expect(refs.contains(.tag(name: "lightweight", commit: old)))
    let pinned = try await RepositoryLibrary.preview(source: source, ref: .tag(name: "release")); defer { RepositoryLibrary.discard(pinned) }
    let folder = try SkillInstaller.importRepository(preview: pinned, root: library)
    #expect(pinned.commit == old)
    #expect(try await RepositoryLibrary.check(entry: RepositoryLibrary.inventory(catalog: [], root: library)[0]).status == .pinned)
    _ = try await git(["tag", "-f", "release", newer], in: origin)
    #expect(try await RepositoryLibrary.check(entry: RepositoryLibrary.inventory(catalog: [], root: library)[0]).status == .tagMoved)
    let update = try await SkillInstaller.prepareRepoUpdate(name: folder.lastPathComponent, root: library, linkRoots: [])
    #expect(update.newCommit == old && !update.hasChanges)
    SkillInstaller.discardRepoUpdate(update)
    let commitPin = try await RepositoryLibrary.preview(source: source, ref: .commit(old)); defer { RepositoryLibrary.discard(commitPin) }
    #expect(commitPin.commit == old)
    let feature = try await RepositoryLibrary.preview(source: source, ref: .branch("feature")); defer { RepositoryLibrary.discard(feature) }
    #expect(feature.commit == old)
    await #expect(throws: RepositoryLibrary.Failure.self) { try await RepositoryLibrary.preview(source: source, ref: .branch("missing")) }
    _ = try await git(["tag", "-d", "release"], in: origin)
    await #expect(throws: RepositoryLibrary.Failure.self) { try await RepositoryLibrary.check(entry: RepositoryLibrary.inventory(catalog: [], root: library)[0]) }
  }

  @Test func expectedCommitMismatchNeverMutatesInstalledSnapshot() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let origin = try await remote(in: root), library = root.appending(path: "library")
    let preview = try await RepositoryLibrary.preview(source: .git(origin.absoluteString)); defer { RepositoryLibrary.discard(preview) }
    let folder = try SkillInstaller.importRepository(preview: preview, root: library)
    _ = try await commit(in: origin, message: "Version only", empty: true)
    await #expect(throws: RepositoryLibrary.Failure.self) {
      try await SkillInstaller.prepareRepoUpdate(name: folder.lastPathComponent, expectedCommit: preview.commit, root: library, linkRoots: [])
    }
    #expect(try await RepositoryLibrary.fullCommit(in: folder) == preview.commit)
  }

  @Test func gitRunnerDrainsOutputAndCancelsItsProcessGroup() async throws {
    let output = try await RepositoryGit.run(["-c", "alias.fixture=!i=0; while [ $i -lt 4000 ]; do echo fixture >&2; i=$((i+1)); done; echo complete", "fixture"])
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "complete")
    let clock = ContinuousClock(), start = clock.now
    await #expect(throws: RepositoryLibrary.Failure.self) {
      try await RepositoryGit.run(["-c", "alias.fixture=!sleep 10", "fixture"], timeout: 0.05)
    }
    #expect(start.duration(to: clock.now) < .seconds(2))
    let task = Task { try await RepositoryGit.run(["-c", "alias.fixture=!sleep 10", "fixture"]) }
    try await Task.sleep(for: .milliseconds(50)); task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func skillsetOptionalVersionFieldsKeepOldFilesCompatible() throws {
    let legacy = Data("{\"format\":\"skillscout-skillset\",\"version\":1,\"name\":\"Fixture\",\"skills\":[{\"name\":\"fixture\",\"source\":\"https://example.invalid/repo\"}]}".utf8)
    let decoded = try SkillsetFile.decode(legacy)
    #expect(decoded.skills[0].ref == nil && decoded.skills[0].commit == nil)
    let versioned = SkillsetFile(name: "Fixture", skills: [.init(name: "fixture", source: "https://example.invalid/repo", ref: .tag(name: "release", commit: String(repeating: "a", count: 40)), commit: String(repeating: "a", count: 40))])
    #expect(try SkillsetFile.decode(versioned.encoded()) == versioned)
  }

  @Test func failedAndCancelledPreviewLeavesNoLibraryAndRetryWorks() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let origin = try await remote(in: root)
    await #expect(throws: RepositoryLibrary.Failure.self) {
      try await RepositoryLibrary.preview(source: .git(root.appending(path: "missing-remote").absoluteString))
    }
    let cancelled = Task { try await RepositoryLibrary.preview(source: .git(origin.absoluteString)) }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    let retried = try await RepositoryLibrary.preview(source: .git(origin.absoluteString)); defer { RepositoryLibrary.discard(retried) }
    #expect(retried.skills.count == 1)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "library").path))
    do {
      _ = try await RepositoryGit.run(["-c", "alias.fixture=!echo https://username:secret@example.invalid >&2; exit 1", "fixture"])
      Issue.record("Expected fixture failure")
    } catch { #expect(!error.localizedDescription.contains("secret")) }
    await #expect(throws: SkillInstaller.InstallFailure.self) {
      try await RepositoryGit.run(["-c", "alias.fixture=!echo 'Authentication failed' >&2; exit 1", "fixture"])
    }
  }

  @Test func localFolderContainingGitStaysLocalAndUnknownMetadataIsVisible() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let origin = try await remote(in: root), library = root.appending(path: "library")
    let preview = try await RepositoryLibrary.preview(source: .local(origin.path)); defer { RepositoryLibrary.discard(preview) }
    #expect(preview.commit == nil && preview.ref == .defaultBranch)
    let folder = try SkillInstaller.importRepository(preview: preview, root: library)
    #expect(try RepositoryLibrary.snapshot(in: folder)?.source == .local(origin.path))
    let marker = folder.appending(path: RepositoryLibrary.markerName)
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
    json["version"] = 42
    try JSONSerialization.data(withJSONObject: json).write(to: marker)
    let entries = RepositoryLibrary.inventory(catalog: [], root: library)
    #expect(entries.count == 1 && entries[0].issue?.contains("42") == true)
    #expect(RepositoryLibrary.skills(in: folder).count == 1)
  }

  @Test func legacyGitVersionIsVisibleAndMigrationPreservesPath() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let origin = try await remote(in: root), library = root.appending(path: "library")
    let preview = try await RepositoryLibrary.preview(source: .git(origin.absoluteString)); defer { RepositoryLibrary.discard(preview) }
    let folder = try SkillInstaller.importRepository(preview: preview, root: library)
    _ = try await git(["checkout", "main"], in: folder)
    try FileManager.default.removeItem(at: folder.appending(path: RepositoryLibrary.markerName))
    let inventory = RepositoryLibrary.inventory(catalog: [], root: library)
    #expect(inventory[0].snapshot?.commit == preview.commit)
    #expect(inventory[0].snapshot?.ref == .branch("main"))
    let update = try await SkillInstaller.prepareRepoUpdate(name: folder.lastPathComponent, root: library, linkRoots: [])
    #expect(!update.hasLocalEdits)
    _ = try SkillInstaller.applyRepoUpdate(update, trash: moveToFakeTrash(root))
    #expect(try RepositoryLibrary.snapshot(in: folder)?.baselineFingerprints == preview.fingerprints)
    #expect(RepositoryLibrary.inventory(catalog: [], root: library)[0].installedFolder?.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
    let repeated = try await SkillInstaller.prepareRepoUpdate(name: folder.lastPathComponent, root: library, linkRoots: [])
    #expect(!repeated.hasChanges)
    SkillInstaller.discardRepoUpdate(repeated)
  }
  @Test func legacyGitObjectsSupplyExactMergeBase() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let origin = try await remote(in: root), library = root.appending(path: "library")
    try "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n".write(to: origin.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
    _ = try await commit(in: origin, message: "Add notes")
    let preview = try await RepositoryLibrary.preview(source: .git(origin.absoluteString)); defer { RepositoryLibrary.discard(preview) }
    let folder = try SkillInstaller.importRepository(preview: preview, root: library)
    var marker = try #require(try RepositoryLibrary.snapshot(in: folder))
    marker.upstreamArchiveDigest = nil
    try JSONEncoder().encode(marker).write(to: folder.appending(path: RepositoryLibrary.markerName))
    try FileManager.default.removeItem(at: folder.appending(path: RepositoryLibrary.upstreamMarkerName))
    try "mine\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n".write(to: folder.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
    try "one\ntwo\nthree\nfour\nfive\nsix\nseven\nincoming\n".write(to: origin.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
    _ = try await commit(in: origin, message: "Update notes")
    let update = try await SkillInstaller.prepareRepoUpdate(name: folder.lastPathComponent, root: library, linkRoots: [])
    defer { SkillInstaller.discardRepoUpdate(update) }
    #expect(update.files.first { $0.path == "notes.txt" }?.status == .merged)
    let result = try SkillInstaller.resolveRepoUpdate(update, resolutions: [:]); defer { SkillInstaller.discardRepoUpdate(result) }
    _ = try SkillInstaller.applyRepoUpdate(result, trash: moveToFakeTrash(root))
    #expect(try String(contentsOf: folder.appending(path: "notes.txt"), encoding: .utf8) == "mine\ntwo\nthree\nfour\nfive\nsix\nseven\nincoming\n")
    #expect(try RepositoryLibrary.snapshot(in: folder)?.upstreamArchiveDigest != nil)
  }

}
