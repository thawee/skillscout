import Foundation
import Testing

@Suite struct RepositoryMergeTests {
  @Test func directoryPermissionsAndEmptyLocalFoldersSurviveUpdates() async throws {
    let f = try await fixture(); defer { f.cleanup() }
    let personal = f.installed.appending(path: "personal")
    try FileManager.default.createDirectory(at: personal.appending(path: "empty"), withIntermediateDirectories: true)
    try write("Mine", "personal/private.txt", in: f.installed)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: personal.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.installed.path)
    try write("Incoming", "new.txt", in: f.source)
    let update = try await f.update(); defer { SkillInstaller.discardRepoUpdate(update) }
    let result = try SkillInstaller.resolveRepoUpdate(update, resolutions: [:]); defer { SkillInstaller.discardRepoUpdate(result) }
    try f.apply(result)
    #expect(try read("personal/private.txt", in: f.installed) == "Mine")
    #expect(FileManager.default.fileExists(atPath: personal.appending(path: "empty").path))
    #expect((try FileManager.default.attributesOfItem(atPath: personal.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect((try FileManager.default.attributesOfItem(atPath: f.installed.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }

  @Test func unreadableDirectoriesAbortWithoutMutation() async throws {
    let f = try await fixture(); defer { f.cleanup() }
    let privateFolder = f.installed.appending(path: "private")
    try write("Mine", "private/personal.txt", in: f.installed)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: privateFolder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateFolder.path) }
    await #expect(throws: (any Error).self) { try await f.update() }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateFolder.path)
    #expect(try read("private/personal.txt", in: f.installed) == "Mine")
  }

  @Test func keepingChildOfDeletedFolderRetainsParentPermissions() async throws {
    let f = try await fixture(); defer { f.cleanup() }
    try write("Base", "private/notes.txt", in: f.source)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.source.appending(path: "private").path)
    let initial = try await f.update(); defer { SkillInstaller.discardRepoUpdate(initial) }
    let first = try SkillInstaller.resolveRepoUpdate(initial, resolutions: [:]); defer { SkillInstaller.discardRepoUpdate(first) }
    try f.apply(first)
    try write("Mine", "private/notes.txt", in: f.installed)
    try FileManager.default.removeItem(at: f.source.appending(path: "private"))
    let update = try await f.update(); defer { SkillInstaller.discardRepoUpdate(update) }
    let result = try SkillInstaller.resolveRepoUpdate(update, resolutions: ["private/notes.txt": .keepMine]); defer { SkillInstaller.discardRepoUpdate(result) }
    try f.apply(result)
    #expect(try read("private/notes.txt", in: f.installed) == "Mine")
    #expect((try FileManager.default.attributesOfItem(atPath: f.installed.appending(path: "private").path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }

  private struct Fixture {
    let root: URL
    let source: URL
    let library: URL
    let installed: URL
    func update(linkRoots: [SkillRoot] = []) async throws -> RepoUpdate {
      try await SkillInstaller.prepareRepoUpdate(name: installed.lastPathComponent, root: library, linkRoots: linkRoots)
    }
    func apply(_ resolved: ResolvedRepoUpdate) throws {
      _ = try SkillInstaller.applyRepoUpdate(resolved, trash: { backup in
        let trash = root.appending(path: "trash-" + UUID().uuidString)
        try FileManager.default.moveItem(at: backup, to: trash)
        return [trash]
      })
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
  }

  private func write(_ text: String, _ path: String, in folder: URL) throws {
    let file = folder.appending(path: path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
  }
  private func read(_ path: String, in folder: URL) throws -> String {
    try String(contentsOf: folder.appending(path: path), encoding: .utf8)
  }
  private func fixture(body: String = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n") async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "skillscout-merge-test-" + UUID().uuidString)
    let source = root.appending(path: "source"), library = root.appending(path: "library")
    try write("---\nname: fixture\ndescription: Test skill\n---\nFixture\n", "nested/fixture/SKILL.md", in: source)
    try write(body, "notes.txt", in: source)
    let preview = try await RepositoryLibrary.preview(source: .local(source.path))
    defer { RepositoryLibrary.discard(preview) }
    let installed = try SkillInstaller.importRepository(preview: preview, root: library)
    return Fixture(root: root, source: source, library: library, installed: installed)
  }

  @Test func disjointEditsSurviveTwoUpdatesWithUpstreamBaseline() async throws {
    let f = try await fixture(); defer { f.cleanup() }
    try write("mine\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n", "notes.txt", in: f.installed)
    try write("one\ntwo\nthree\nfour\nfive\nsix\nseven\nincoming\n", "notes.txt", in: f.source)
    let first = try await f.update(); defer { SkillInstaller.discardRepoUpdate(first) }
    #expect(first.files.first { $0.path == "notes.txt" }?.status == .merged)
    let resolved = try SkillInstaller.resolveRepoUpdate(first, resolutions: [:]); defer { SkillInstaller.discardRepoUpdate(resolved) }
    #expect(resolved.mergedPaths == ["notes.txt"])
    #expect(try read("notes.txt", in: first.staged).hasPrefix("one\n"))
    try f.apply(resolved)
    #expect(try read("notes.txt", in: f.installed) == "mine\ntwo\nthree\nfour\nfive\nsix\nseven\nincoming\n")
    try write("one\ntwo\nthree\nnext\nfive\nsix\nseven\nincoming\n", "notes.txt", in: f.source)
    let second = try await f.update(); defer { SkillInstaller.discardRepoUpdate(second) }
    #expect(second.hasLocalEdits)
    #expect(second.files.first { $0.path == "notes.txt" }?.baseText?.hasPrefix("one\n") == true)
    let result = try SkillInstaller.resolveRepoUpdate(second, resolutions: [:]); defer { SkillInstaller.discardRepoUpdate(result) }
    try f.apply(result)
    #expect(try read("notes.txt", in: f.installed) == "mine\ntwo\nthree\nnext\nfive\nsix\nseven\nincoming\n")
  }

  @Test func localAdditionsAndDeletionsStayIndependentFromIncomingChanges() async throws {
    let f = try await fixture(); defer { f.cleanup() }
    try write("Personal", "personal.txt", in: f.installed)
    try FileManager.default.removeItem(at: f.installed.appending(path: "notes.txt"))
    try write("New", "new.txt", in: f.source)
    let update = try await f.update(); defer { SkillInstaller.discardRepoUpdate(update) }
    let result = try SkillInstaller.resolveRepoUpdate(update, resolutions: [:]); defer { SkillInstaller.discardRepoUpdate(result) }
    #expect(result.preservedLocalPaths == ["notes.txt", "personal.txt"])
    #expect(result.added == ["new.txt"])
    try f.apply(result)
    #expect(try read("personal.txt", in: f.installed) == "Personal")
    #expect(!FileManager.default.fileExists(atPath: f.installed.appending(path: "notes.txt").path))
    #expect(try read("new.txt", in: f.installed) == "New")
  }

  @Test func overlapsAndAdjacentEditsRequireChoicesAndManualMergeRejectsMarkers() async throws {
    for incoming in ["incoming\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n", "one\nincoming\nthree\nfour\nfive\nsix\nseven\neight\n"] {
      let f = try await fixture(); defer { f.cleanup() }
      try write("mine\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n", "notes.txt", in: f.installed)
      try write(incoming, "notes.txt", in: f.source)
      let update = try await f.update(); defer { SkillInstaller.discardRepoUpdate(update) }
      #expect(update.files.first { $0.path == "notes.txt" }?.status == .conflict)
      #expect(throws: SkillInstaller.RepoUpdateFailure.self) { try SkillInstaller.resolveRepoUpdate(update, resolutions: [:]) }
      #expect(throws: SkillInstaller.RepoUpdateFailure.self) {
        try SkillInstaller.resolveRepoUpdate(update, resolutions: ["notes.txt": .merge("<<<<<<< Mine\nMine\n=======\nIncoming\n>>>>>>> Incoming\n")])
      }
      #expect(throws: SkillInstaller.RepoUpdateFailure.self) {
        try SkillInstaller.resolveRepoUpdate(update, resolutions: ["unknown": .keepMine])
      }
      let result = try SkillInstaller.resolveRepoUpdate(update, resolutions: ["notes.txt": .merge("Reviewed result\n")]); defer { SkillInstaller.discardRepoUpdate(result) }
      #expect(result.mergedPaths == ["notes.txt"])
      try f.apply(result)
      #expect(try read("notes.txt", in: f.installed) == "Reviewed result\n")
    }
  }

  @Test func lineEndingsAndMissingFinalNewlineSurviveCleanMerge() async throws {
    for separator in ["\n", "\r\n"] {
      let base = ["one", "two", "three", "four", "five", "six", "seven", "eight"].joined(separator: separator)
      let f = try await fixture(body: base); defer { f.cleanup() }
      try write(base.replacingOccurrences(of: "one", with: "mine"), "notes.txt", in: f.installed)
      try write(base.replacingOccurrences(of: "eight", with: "incoming"), "notes.txt", in: f.source)
      let update = try await f.update(); defer { SkillInstaller.discardRepoUpdate(update) }
      let result = try SkillInstaller.resolveRepoUpdate(update, resolutions: [:]); defer { SkillInstaller.discardRepoUpdate(result) }
      #expect(try read("notes.txt", in: result.staged) == base.replacingOccurrences(of: "one", with: "mine").replacingOccurrences(of: "eight", with: "incoming"))
    }
  }

  @Test func deleteModifyKeepsMineOrAcceptsDeletion() async throws {
    for keep in [true, false] {
      let f = try await fixture(); defer { f.cleanup() }
      try write("Personal edit", "notes.txt", in: f.installed)
      try FileManager.default.removeItem(at: f.source.appending(path: "notes.txt"))
      let update = try await f.update(); defer { SkillInstaller.discardRepoUpdate(update) }
      #expect(update.files.first { $0.path == "notes.txt" }?.status == .conflict)
      let result = try SkillInstaller.resolveRepoUpdate(update, resolutions: ["notes.txt": keep ? .keepMine : .useIncoming]); defer { SkillInstaller.discardRepoUpdate(result) }
      try f.apply(result)
      #expect(FileManager.default.fileExists(atPath: f.installed.appending(path: "notes.txt").path) == keep)
      if keep { #expect(try read("notes.txt", in: f.installed) == "Personal edit") }
    }
  }

  @Test func binaryLinksAndExecutableModesRequireExplicitDecisions() async throws {
    let f = try await fixture(); defer { f.cleanup() }
    try Data([0, 1, 2]).write(to: f.installed.appending(path: "notes.txt"))
    try Data([0, 3, 4]).write(to: f.source.appending(path: "notes.txt"))
    try write("script", "nested/fixture/run.sh", in: f.source)
    let initial = try await f.update(); defer { SkillInstaller.discardRepoUpdate(initial) }
    let seeded = try SkillInstaller.resolveRepoUpdate(initial, resolutions: ["notes.txt": .useIncoming]); defer { SkillInstaller.discardRepoUpdate(seeded) }
    try f.apply(seeded)
    try Data([0, 5]).write(to: f.installed.appending(path: "notes.txt"))
    try Data([0, 6]).write(to: f.source.appending(path: "notes.txt"))
    try FileManager.default.createSymbolicLink(atPath: f.installed.appending(path: "opaque").path, withDestinationPath: "/missing/mine")
    try FileManager.default.createSymbolicLink(atPath: f.source.appending(path: "opaque").path, withDestinationPath: "/missing/incoming")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.installed.appending(path: "nested/fixture/run.sh").path)
    try write("incoming script", "nested/fixture/run.sh", in: f.source)
    let update = try await f.update(); defer { SkillInstaller.discardRepoUpdate(update) }
    #expect(update.files.filter { $0.status == .conflict }.map(\.path) == ["nested/fixture/run.sh", "notes.txt", "opaque"])
    #expect(update.files.first { $0.path == "notes.txt" }?.canMerge == false)
    #expect(throws: SkillInstaller.RepoUpdateFailure.self) {
      try SkillInstaller.resolveRepoUpdate(update, resolutions: ["notes.txt": .merge("text"), "opaque": .keepMine, "nested/fixture/run.sh": .keepMine])
    }
    let result = try SkillInstaller.resolveRepoUpdate(update, resolutions: ["notes.txt": .useIncoming, "opaque": .keepMine, "nested/fixture/run.sh": .keepMine]); defer { SkillInstaller.discardRepoUpdate(result) }
    try f.apply(result)
    #expect(try Data(contentsOf: f.installed.appending(path: "notes.txt")) == Data([0, 6]))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.installed.appending(path: "opaque").path) == "/missing/mine")
    #expect((try FileManager.default.attributesOfItem(atPath: f.installed.appending(path: "nested/fixture/run.sh").path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
  }

  @Test func missingLegacyBaseNeedsChoicesAndCorruptArchiveIsRejected() async throws {
    let f = try await fixture(); defer { f.cleanup() }
    let markerFile = f.installed.appending(path: RepositoryLibrary.markerName)
    var marker = try #require(try RepositoryLibrary.snapshot(in: f.installed))
    marker.upstreamArchiveDigest = nil
    try JSONEncoder().encode(marker).write(to: markerFile)
    try FileManager.default.removeItem(at: f.installed.appending(path: RepositoryLibrary.upstreamMarkerName))
    try write("Mine", "notes.txt", in: f.installed)
    try write("Incoming", "notes.txt", in: f.source)
    let update = try await f.update(); defer { SkillInstaller.discardRepoUpdate(update) }
    #expect(update.files.first { $0.path == "notes.txt" }?.baseText == nil)
    #expect(update.files.first { $0.path == "notes.txt" }?.status == .conflict)
    let result = try SkillInstaller.resolveRepoUpdate(update, resolutions: ["notes.txt": .keepMine]); defer { SkillInstaller.discardRepoUpdate(result) }
    try f.apply(result)
    try write("damaged", RepositoryLibrary.upstreamMarkerName, in: f.installed)
    await #expect(throws: RepositoryLibrary.Failure.self) { try await f.update() }
  }

  @Test func currentIncomingAndResolvedContentAndModesInvalidateReview() async throws {
    for target in ["current", "incoming", "result", "resultMode", "archive"] {
      let f = try await fixture(); defer { f.cleanup() }
      try write("Incoming", "new.txt", in: f.source)
      let update = try await f.update(); defer { SkillInstaller.discardRepoUpdate(update) }
      let result = try SkillInstaller.resolveRepoUpdate(update, resolutions: [:]); defer { SkillInstaller.discardRepoUpdate(result) }
      switch target {
      case "current": try write("Stale", "notes.txt", in: f.installed)
      case "incoming": try write("Stale", "notes.txt", in: update.staged)
      case "result": try write("Stale", "notes.txt", in: result.staged)
      case "archive": try write("Stale", RepositoryLibrary.upstreamMarkerName, in: result.staged)
      default: try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: result.staged.appending(path: "notes.txt").path)
      }
      #expect(throws: SkillInstaller.RepoUpdateFailure.self) { try f.apply(result) }
      #expect(!FileManager.default.fileExists(atPath: f.installed.appending(path: "new.txt").path))
    }
  }

  @Test func wholeSnapshotReplacementDiscardsAllPersonalChanges() async throws {
    let f = try await fixture(); defer { f.cleanup() }
    try write("mine\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n", "notes.txt", in: f.installed)
    try write("one\ntwo\nthree\nfour\nfive\nsix\nseven\nincoming\n", "notes.txt", in: f.source)
    try write("Personal", "personal.txt", in: f.installed)
    try FileManager.default.removeItem(at: f.installed.appending(path: "nested/fixture/SKILL.md"))
    let update = try await f.update(); defer { SkillInstaller.discardRepoUpdate(update) }
    #expect(update.files.first { $0.path == "notes.txt" }?.status == .merged)
    _ = try SkillInstaller.applyRepoUpdate(update, replaceLocalEdits: true, trash: { backup in
      let trash = f.root.appending(path: "fake-trash")
      try FileManager.default.moveItem(at: backup, to: trash)
      return [trash]
    })
    #expect(try read("notes.txt", in: f.installed) == read("notes.txt", in: f.source))
    #expect(!FileManager.default.fileExists(atPath: f.installed.appending(path: "personal.txt").path))
    #expect(FileManager.default.fileExists(atPath: f.installed.appending(path: "nested/fixture/SKILL.md").path))
  }

  @Test func newSkillsRequireAssignmentAndLeaveIndependentCopiesAlone() async throws {
    let f = try await fixture(); defer { f.cleanup() }
    let independent = f.root.appending(path: "independent")
    try FileManager.default.copyItem(at: f.installed.appending(path: "nested/fixture"), to: independent)
    try write("---\nname: fixture\ndescription: Another skill with the same name\n---\nNew\n", "other/SKILL.md", in: f.source)
    let update = try await f.update(); defer { SkillInstaller.discardRepoUpdate(update) }
    #expect(update.newSkills.map(\.relativePath) == ["other"])
    let result = try SkillInstaller.resolveRepoUpdate(update, resolutions: [:]); defer { SkillInstaller.discardRepoUpdate(result) }
    #expect(result.newSkills.map(\.relativePath) == ["other"])
    try f.apply(result)
    #expect(try read("SKILL.md", in: independent).contains("Test skill"))
    #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "agents").path))
  }

  @Test func treeCollisionsAndSymlinkAncestorsCannotBeMaterialized() async throws {
    let f = try await fixture(); defer { f.cleanup() }
    try write("Local file", "collision", in: f.installed)
    try write("Incoming child", "collision/child", in: f.source)
    let update = try await f.update(); defer { SkillInstaller.discardRepoUpdate(update) }
    #expect(update.files.filter { $0.status == .conflict }.map(\.path) == ["collision", "collision/child"])
    #expect(throws: RepositoryLibrary.Failure.self) {
      try SkillInstaller.resolveRepoUpdate(update, resolutions: ["collision": .keepMine, "collision/child": .useIncoming])
    }
    let result = try SkillInstaller.resolveRepoUpdate(update, resolutions: ["collision": .useIncoming, "collision/child": .useIncoming]); defer { SkillInstaller.discardRepoUpdate(result) }
    #expect(try read("collision/child", in: result.staged) == "Incoming child")
    let alias = f.root.appending(path: "alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.library)
    await #expect(throws: RepositoryLibrary.Failure.self) {
      try await SkillInstaller.prepareRepoUpdate(name: f.installed.lastPathComponent, root: alias, linkRoots: [])
    }
    for invalid in ["../escape", "/escape", "a//b", ".git/config", RepositoryLibrary.upstreamMarkerName] {
      #expect(throws: RepositoryLibrary.Failure.self) { try RepositoryMerge.validatePath(invalid) }
    }
  }
  @Test func incomingOnlyExecutableChangeIsReportedAndApplied() async throws {
    let f = try await fixture(); defer { f.cleanup() }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.source.appending(path: "notes.txt").path)
    let update = try await f.update(); defer { SkillInstaller.discardRepoUpdate(update) }
    #expect(update.hasChanges)
    #expect(update.changed == ["notes.txt"])
    #expect(update.files.first { $0.path == "notes.txt" }?.status == .incoming)
    let result = try SkillInstaller.resolveRepoUpdate(update, resolutions: [:]); defer { SkillInstaller.discardRepoUpdate(result) }
    try f.apply(result)
    #expect((try FileManager.default.attributesOfItem(atPath: f.installed.appending(path: "notes.txt").path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
  }

  @Test func resolvedTrashFailureRestoresCurrentTreeAndAllowsRetry() async throws {
    let f = try await fixture(); defer { f.cleanup() }
    try write("Mine", "personal.txt", in: f.installed)
    try write("Incoming", "new.txt", in: f.source)
    let marker = try Data(contentsOf: f.installed.appending(path: RepositoryLibrary.markerName))
    let update = try await f.update(); defer { SkillInstaller.discardRepoUpdate(update) }
    let result = try SkillInstaller.resolveRepoUpdate(update, resolutions: [:]); defer { SkillInstaller.discardRepoUpdate(result) }
    #expect(throws: CocoaError.self) {
      try SkillInstaller.applyRepoUpdate(result, trash: { _ in throw CocoaError(.fileWriteNoPermission) })
    }
    #expect(try Data(contentsOf: f.installed.appending(path: RepositoryLibrary.markerName)) == marker)
    #expect(try read("personal.txt", in: f.installed) == "Mine")
    #expect(!FileManager.default.fileExists(atPath: f.installed.appending(path: "new.txt").path))
    try f.apply(result)
    #expect(try read("new.txt", in: f.installed) == "Incoming")
  }

  @Test func identicalLocalAndUpstreamEditsStillAdvanceBaseline() async throws {
    let f = try await fixture(); defer { f.cleanup() }
    try write("Agreed", "notes.txt", in: f.installed)
    try write("Agreed", "notes.txt", in: f.source)
    let update = try await f.update(); defer { SkillInstaller.discardRepoUpdate(update) }
    #expect(update.hasChanges)
    #expect(update.changed.isEmpty)
    let result = try SkillInstaller.resolveRepoUpdate(update, resolutions: [:]); defer { SkillInstaller.discardRepoUpdate(result) }
    try f.apply(result)
    let next = try await f.update(); defer { SkillInstaller.discardRepoUpdate(next) }
    #expect(!next.hasLocalEdits)
    #expect(!next.hasChanges)
  }

}
