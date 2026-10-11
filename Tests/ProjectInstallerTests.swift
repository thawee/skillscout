import Foundation
import Testing

private final class ProjectInstallFixture {
  let root: URL
  let project: RegisteredProject
  let source: URL
  let skill: Skill
  let skillsetID = UUID()
  var state: ProjectState
  var trashed: [URL] = []

  init() throws {
    let fm = FileManager.default
    root = fm.temporaryDirectory.appending(path: "skillscout-project-install-\(UUID().uuidString)")
      .standardizedFileURL.resolvingSymlinksInPath()
    let folder = root.appending(path: "project")
    source = root.appending(path: "library/demo")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try fm.createDirectory(at: source.appending(path: "scripts"), withIntermediateDirectories: true)
    try Data("---\nname: demo\ndescription: Fixture\n---\nRun the script.\n".utf8).write(to: source.appending(path: "SKILL.md"))
    try Data("#!/bin/sh\nprintf fixture\n".utf8).write(to: source.appending(path: "scripts/run.sh"))
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appending(path: "scripts/run.sh").path)
    try Data("hidden fixture".utf8).write(to: source.appending(path: ".support"))
    project = try ProjectLibrary.register(folder, projects: [])
    skill = Self.skill("demo", at: source)
    state = ProjectState(projects: [project])
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  static func skill(_ name: String, at folder: URL) -> Skill {
    let root = SkillRoot(label: "Fixture", url: folder.deletingLastPathComponent(), kind: .managed,
      owner: nil, readBy: [])
    let copy = SkillCopy(folder: folder, resolved: folder, root: root, pluginName: nil,
      isSymlink: false, contentHash: "fixture", created: .distantPast)
    return Skill(name: name, description: "Fixture", copies: [copy])
  }

  var destination: URL { ProjectSkillTarget.shared.url(in: project).appending(path: "demo") }

  func additionalSkill(_ name: String) throws -> Skill {
    let folder = root.appending(path: "library/\(name)")
    try FileManager.default.copyItem(at: source, to: folder)
    try Data("---\nname: \(name)\ndescription: Fixture\n---\nAdditional fixture\n".utf8).write(to: folder.appending(path: "SKILL.md"))
    return Self.skill(name, at: folder)
  }

  func direct(_ ids: Set<Skill.ID>, skills: [Skill]? = nil, target: ProjectSkillTarget = .shared) -> ProjectSkillPlan {
    SkillInstaller.projectSkillsPlan(project: project, state: state, skills: skills ?? [skill],
      skillIDs: ids, target: target)
  }

  func remove(_ id: Skill.ID = "demo", skills: [Skill]? = nil, target: ProjectSkillTarget = .shared) -> ProjectSkillPlan {
    SkillInstaller.projectRemoveSkillPlan(project: project, state: state, skills: skills ?? [skill],
      skillID: id, target: target)
  }

  func plan(target: ProjectSkillTarget = .shared, id: UUID? = nil, skills: [Skill]? = nil) -> ProjectSkillPlan {
    SkillInstaller.projectPlan(project: project, state: state, skills: skills ?? [skill],
      skillsetID: id ?? skillsetID, members: ["demo"], target: target)
  }

  func trash(_ url: URL) throws -> URL {
    let fm = FileManager.default
    let parent = root.appending(path: "trash")
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    let destination = parent.appending(path: UUID().uuidString)
    try fm.moveItem(at: url, to: destination)
    trashed.append(destination)
    return destination
  }

  func apply(_ plan: ProjectSkillPlan? = nil) throws -> ProjectApplyResult {
    let preview = plan ?? self.plan()
    return try SkillInstaller.applyProjectPlan(preview, state: &state, persist: { _ in }, trash: trash)
  }

  func unassign(_ id: UUID? = nil, target: ProjectSkillTarget = .shared) -> ProjectSkillPlan {
    SkillInstaller.projectUnassignPlan(project: project, state: state, skills: [skill],
      skillsetID: id ?? skillsetID, target: target)
  }
}

@Suite struct ProjectInstallerTests {
  @Test func directAssignmentsAreStableAndIndependentAcrossTargets() throws {
    let fixture = try ProjectInstallFixture()
    let other = try fixture.additionalSkill("other")
    let skills = [fixture.skill, other]
    _ = try fixture.apply(fixture.direct(["demo", "other"], skills: skills))
    let initial = fixture.state.assignments
    #expect(initial.count == 2)
    #expect(initial.allSatisfy { assignment in assignment.individualSkillID.map { assignment.members == [$0] } ?? false })
    #expect(Set(initial.compactMap(\.individualSkillID)) == ["demo", "other"])
    let repeated = fixture.direct(["demo", "other"], skills: skills)
    #expect(repeated.changes.isEmpty)
    _ = try fixture.apply(repeated)
    #expect(fixture.state.assignments == initial)
    _ = try fixture.apply(fixture.direct(["demo"], target: .claude))
    #expect(fixture.state.assignments.count == 3)
    #expect(fixture.state.assignments.filter { $0.target == .shared } == initial)
    #expect(fixture.state.entries.count == 3)
  }

  @Test func removalUpdatesEveryProjectSnapshotAndLeavesGlobalTemplatesAndOtherTargets() throws {
    let fixture = try ProjectInstallFixture()
    let other = try fixture.additionalSkill("other")
    let skills = [fixture.skill, other]
    let templates = [Skillset(name: "First", skills: ["demo", "other"]), Skillset(name: "Second", skills: ["demo"])]
    let originals = templates
    for template in templates {
      _ = try fixture.apply(SkillInstaller.projectPlan(project: fixture.project, state: fixture.state,
        skills: skills, skillsetID: template.id, members: template.skills, target: .shared))
    }
    _ = try fixture.apply(fixture.direct(["demo"], skills: skills))
    _ = try fixture.apply(fixture.direct(["demo"], target: .claude))
    let claude = fixture.state.assignments.filter { $0.target == .claude }
    let removal = fixture.remove(skills: [])
    #expect(removal.intent == .removeSkill("demo"))
    #expect(removal.changes.map(\.skillID) == ["demo"])
    _ = try fixture.apply(removal)
    #expect(templates == originals)
    #expect(fixture.state.assignments.first { $0.skillsetID == templates[0].id }?.members == ["other"])
    #expect(fixture.state.assignments.first { $0.skillsetID == templates[1].id }?.members.isEmpty == true)
    #expect(!fixture.state.assignments.contains { $0.target == .shared && $0.individualSkillID == "demo" })
    #expect(fixture.state.assignments.filter { $0.target == .claude } == claude)
    #expect(fixture.state.entries.count == 2)
    #expect(FileManager.default.fileExists(atPath: other.copies[0].folder.path))
    #expect(FileManager.default.fileExists(atPath: ProjectSkillTarget.shared.url(in: fixture.project).appending(path: "other").path))
    #expect(FileManager.default.fileExists(atPath: ProjectSkillTarget.claude.url(in: fixture.project).appending(path: "demo").path))
    #expect(fixture.trashed.count == 1)
  }

  @Test func targetedRemovalIgnoresUnrelatedSourcesConflictsAndOrphanReceipts() throws {
    let fixture = try ProjectInstallFixture()
    let other = try fixture.additionalSkill("other")
    let orphan = try fixture.additionalSkill("orphan")
    _ = try fixture.apply(fixture.direct(["demo", "other", "orphan"], skills: [fixture.skill, other, orphan]))
    fixture.state.assignments.removeAll { $0.individualSkillID == "orphan" }
    let preserved = fixture.state.entries.filter { $0.skillID != "demo" }
    let otherDestination = ProjectSkillTarget.shared.url(in: fixture.project).appending(path: "other")
    let before = try SkillInstaller.projectFingerprint(otherDestination)
    try Data("updated library source".utf8).write(to: other.copies[0].folder.appending(path: "SKILL.md"))
    let conflicting = try fixture.additionalSkill("conflicting")
    let conflict = Skill(name: other.name, description: other.description, copies: other.copies + conflicting.copies)
    let preview = fixture.remove(skills: [conflict])
    #expect(preview.canApply)
    #expect(preview.changes.count == 1)
    _ = try fixture.apply(preview)
    #expect(fixture.state.entries == preserved)
    #expect(try SkillInstaller.projectFingerprint(otherDestination) == before)
    #expect(preserved.allSatisfy(SkillInstaller.projectEntryUnchanged))
    #expect(fixture.state.assignments.compactMap(\.individualSkillID) == ["other"])
    #expect(fixture.trashed.count == 1)
  }

  @Test func targetedRemovalKeepsModifiedAndUnownedCopiesWithoutOwnership() throws {
    for owned in [false, true] {
      let fixture = try ProjectInstallFixture()
      if owned {
        _ = try fixture.apply(fixture.direct(["demo"]))
        try Data("user changes".utf8).write(to: fixture.destination.appending(path: "SKILL.md"))
      } else {
        try FileManager.default.createDirectory(at: fixture.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.source, to: fixture.destination)
        _ = try fixture.apply(fixture.direct(["demo"]))
      }
      let before = try SkillInstaller.projectFingerprint(fixture.destination)
      let preview = fixture.remove()
      #expect(preview.canApply)
      #expect(preview.changes.isEmpty)
      #expect(preview.kept.contains { $0.contains(owned ? "modified" : "without an ownership receipt") })
      _ = try fixture.apply(preview)
      #expect(try SkillInstaller.projectFingerprint(fixture.destination) == before)
      #expect(fixture.state.entries.isEmpty && fixture.state.assignments.isEmpty)
      #expect(fixture.trashed.isEmpty)
    }
  }

  @Test func targetedRemovalRejectsChangedPreviewAndKeepsInterruptedScopeOnRecovery() throws {
    let fixture = try ProjectInstallFixture()
    let orphan = try fixture.additionalSkill("orphan")
    _ = try fixture.apply(fixture.direct(["demo", "orphan"], skills: [fixture.skill, orphan]))
    fixture.state.assignments.removeAll { $0.individualSkillID == "orphan" }
    let orphanReceipt = try #require(fixture.state.entries.first { $0.skillID == "orphan" })
    let stale = fixture.remove()
    try Data("change after preview".utf8).write(to: fixture.destination.appending(path: "SKILL.md"))
    #expect(throws: ProjectInstallFailure.self) { try fixture.apply(stale) }
    #expect(fixture.state.pending == nil && fixture.trashed.isEmpty)
    try Data(contentsOf: fixture.source.appending(path: "SKILL.md")).write(to: fixture.destination.appending(path: "SKILL.md"))
    let preview = fixture.remove()
    var state = fixture.state
    #expect(throws: ProjectInstallFailure.self) {
      try SkillInstaller.applyProjectPlan(preview, state: &state, persist: { next in
        if next.pending?.steps.first?.phase == .completed { throw CocoaError(.fileWriteUnknown) }
      }, trash: fixture.trash)
    }
    #expect(state.pending?.intent == .removeSkill("demo"))
    #expect(fixture.trashed.count == 1)
    state = try JSONDecoder().decode(ProjectState.self, from: JSONEncoder().encode(state))
    _ = try SkillInstaller.recoverProjectOperation(state: &state, persist: { _ in }, trash: fixture.trash)
    #expect(state.pending == nil)
    #expect(state.entries == [orphanReceipt])
    #expect(state.assignments.isEmpty)
    #expect(fixture.trashed.count == 1)
    #expect(SkillInstaller.projectEntryUnchanged(orphanReceipt))
  }

  @Test func forgedRemovalJournalsCannotChangeUnrelatedMembershipOrRemoveOtherSkills() throws {
    for forgeSteps in [false, true] {
      let fixture = try ProjectInstallFixture()
      let other = try fixture.additionalSkill("other")
      _ = try fixture.apply(fixture.direct(["demo", "other"], skills: [fixture.skill, other]))
      let initial = fixture.state
      let demo = try #require(initial.entries.first { $0.skillID == "demo" })
      let selected = try #require(initial.entries.first { $0.skillID == (forgeSteps ? "other" : "demo") })
      let step = ProjectPendingStep(skillID: selected.skillID, operation: .remove, phase: .prepared,
        destinationPath: selected.path, sourcePath: nil, stagePath: nil, stageIdentity: nil,
        expectedFingerprint: nil, previousReceipt: selected, newReceipt: nil, trashPath: nil)
      let proposed = initial.assignments.filter { $0.individualSkillID != "demo" && (forgeSteps || $0.individualSkillID != "other") }
      var state = initial
      state.pending = ProjectPendingJournal(projectID: fixture.project.id, target: .shared,
        previousAssignments: initial.assignments, proposedAssignments: proposed, steps: [step], intent: .removeSkill("demo"))
      #expect(throws: ProjectInstallFailure.self) {
        try SkillInstaller.recoverProjectOperation(state: &state, persist: { _ in }, trash: fixture.trash)
      }
      #expect(state.entries == initial.entries && state.assignments == initial.assignments)
      #expect(fixture.trashed.isEmpty && SkillInstaller.projectEntryUnchanged(demo))
      _ = try SkillInstaller.abandonProjectOperation(state: &state, persist: { _ in })
      #expect(state.pending == nil)
      #expect(state.entries == initial.entries && state.assignments == initial.assignments)
      #expect(initial.entries.allSatisfy(SkillInstaller.projectEntryUnchanged))
    }
  }

  @Test func legacyJournalWithoutIntentRecoversSkillsetAssignments() throws {
    let fixture = try ProjectInstallFixture()
    var state = fixture.state
    #expect(throws: ProjectInstallFailure.self) {
      try SkillInstaller.applyProjectPlan(fixture.plan(), state: &state, persist: { next in
        if next.pending?.steps.first?.phase == .staged { throw CocoaError(.fileWriteUnknown) }
      }, trash: fixture.trash)
    }
    state.pending?.intent = nil
    state = try JSONDecoder().decode(ProjectState.self, from: JSONEncoder().encode(state))
    _ = try SkillInstaller.recoverProjectOperation(state: &state, persist: { _ in }, trash: fixture.trash)
    #expect(state.pending == nil)
    #expect(state.assignments.first?.individualSkillID == nil)
    #expect(state.assignments.first?.skillsetID == fixture.skillsetID)
    #expect(state.entries.count == 1 && SkillInstaller.projectEntryUnchanged(state.entries[0]))
  }

  @Test func copyIncludesSupportingFilesModesHiddenFilesAndRelativeLinks() throws {
    let fixture = try ProjectInstallFixture()
    try FileManager.default.createSymbolicLink(atPath: fixture.source.appending(path: "run").path,
      withDestinationPath: "scripts/run.sh")
    let sourceHash = try SkillInstaller.projectFingerprint(fixture.source, requirePortableLinks: true)
    let preview = fixture.plan()
    #expect(preview.canApply)
    #expect(preview.changes.count == 1)
    #expect(preview.sourcePaths == [fixture.source.path])
    _ = try fixture.apply(preview)
    #expect(try SkillInstaller.projectFingerprint(fixture.destination) == sourceHash)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination.appending(path: "run").path) == "scripts/run.sh")
    #expect(fixture.state.entries.count == 1)
    #expect(fixture.state.assignments.first?.members == ["demo"])
    #expect(fixture.state.pending == nil)
    #expect(SkillInstaller.projectEntryUnchanged(fixture.state.entries[0]))
  }

  @Test func sharedAndClaudeReceiptsAndUnionAssignmentsAreIndependent() throws {
    let fixture = try ProjectInstallFixture()
    _ = try fixture.apply()
    let other = UUID()
    _ = try fixture.apply(fixture.plan(id: other))
    #expect(fixture.state.assignments.count == 2)
    #expect(fixture.unassign().changes.isEmpty)
    _ = try fixture.apply(fixture.unassign())
    #expect(FileManager.default.fileExists(atPath: fixture.destination.path))
    _ = try fixture.apply(fixture.plan(target: .claude))
    #expect(fixture.state.entries.count == 2)
    let removal = try fixture.apply(fixture.unassign(other))
    #expect(removal.trashed.count == 1)
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    #expect(FileManager.default.fileExists(atPath: ProjectSkillTarget.claude.url(in: fixture.project).appending(path: "demo").path))
    #expect(fixture.state.entries.count == 1)
    #expect(fixture.state.assignments.count == 1)
  }

  @Test func identicalUnownedCopiesAreNeverAdoptedOrRemoved() throws {
    let fixture = try ProjectInstallFixture()
    try FileManager.default.createDirectory(at: fixture.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture.source, to: fixture.destination)
    let preview = fixture.plan()
    #expect(preview.canApply)
    #expect(preview.changes.isEmpty)
    #expect(preview.kept.contains { $0.contains("without taking ownership") })
    _ = try fixture.apply(preview)
    #expect(fixture.state.entries.isEmpty)
    _ = try fixture.apply(fixture.unassign())
    #expect(FileManager.default.fileExists(atPath: fixture.destination.path))
    #expect(fixture.trashed.isEmpty)
  }

  @Test func differentUnownedCopiesBlockWithoutChangingFilesOrState() throws {
    let fixture = try ProjectInstallFixture()
    try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
    try Data("independent".utf8).write(to: fixture.destination.appending(path: "SKILL.md"))
    let before = try SkillInstaller.projectFingerprint(fixture.destination)
    let state = fixture.state
    let preview = fixture.plan()
    #expect(!preview.canApply)
    #expect(throws: ProjectInstallFailure.self) { try fixture.apply(preview) }
    #expect(fixture.state == state)
    #expect(try SkillInstaller.projectFingerprint(fixture.destination) == before)
  }

  @Test func changedOwnedSupportingFilesAndPermissionsArePreservedOnUnassign() throws {
    for changeMode in [false, true] {
      let fixture = try ProjectInstallFixture()
      _ = try fixture.apply()
      let script = fixture.destination.appending(path: "scripts/run.sh")
      if changeMode {
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
      } else { try Data("changed by user".utf8).write(to: script) }
      #expect(!SkillInstaller.projectEntryUnchanged(fixture.state.entries[0]))
      #expect(fixture.plan().canApply)
      #expect(fixture.plan().kept.contains { $0.contains("modified") })
      let preview = fixture.unassign()
      #expect(preview.canApply)
      #expect(preview.changes.isEmpty)
      #expect(preview.kept.contains { $0.contains("modified") })
      _ = try fixture.apply(preview)
      #expect(FileManager.default.fileExists(atPath: fixture.destination.path))
      #expect(fixture.state.entries.isEmpty)
      #expect(fixture.trashed.isEmpty)
    }
  }

  @Test func sameContentReplacementDirectoryDoesNotGrantOwnership() throws {
    let fixture = try ProjectInstallFixture()
    _ = try fixture.apply()
    let owned = fixture.state.entries[0]
    _ = try fixture.trash(fixture.destination)
    try FileManager.default.copyItem(at: fixture.source, to: fixture.destination)
    #expect(try SkillInstaller.projectFingerprint(fixture.destination) == owned.installedFingerprint)
    #expect(!SkillInstaller.projectEntryUnchanged(owned))
    let preview = fixture.unassign()
    #expect(preview.changes.isEmpty)
    _ = try fixture.apply(preview)
    #expect(FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  @Test func staleSourceBytesModesAndDestinationChangesPerformNoProjectWrites() throws {
    for change in 0..<3 {
      let fixture = try ProjectInstallFixture()
      let preview = fixture.plan()
      switch change {
      case 0: try Data("new source".utf8).write(to: fixture.source.appending(path: "SKILL.md"))
      case 1: try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.source.path)
      default: try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
      }
      let before = try SkillInstaller.projectFingerprint(fixture.project.url)
      let state = fixture.state
      #expect(throws: ProjectInstallFailure.self) { try fixture.apply(preview) }
      #expect(try SkillInstaller.projectFingerprint(fixture.project.url) == before)
      #expect(fixture.state == state)
    }
  }

  @Test func replacedProjectAndSymlinkedAncestorsAreRejected() throws {
    for replaceProject in [false, true] {
      let fixture = try ProjectInstallFixture()
      let preview = fixture.plan()
      let fm = FileManager.default
      let external = fixture.root.appending(path: "external")
      try fm.createDirectory(at: external, withIntermediateDirectories: true)
      if replaceProject {
        try fm.moveItem(at: fixture.project.url, to: fixture.root.appending(path: "original"))
        try fm.createDirectory(at: fixture.project.url, withIntermediateDirectories: true)
      } else {
        try fm.createSymbolicLink(at: fixture.project.url.appending(path: ".agents"), withDestinationURL: external)
      }
      let before = try SkillInstaller.projectFingerprint(external)
      #expect(!fixture.plan().canApply)
      #expect(throws: ProjectInstallFailure.self) { try fixture.apply(preview) }
      #expect(try SkillInstaller.projectFingerprint(external) == before)
      #expect(fixture.state.pending == nil)
    }
  }

  @Test func ancestorSwapDuringPersistenceDoesNotWriteThroughLink() throws {
    for swapAt in [1, 2, 3] {
      let fixture = try ProjectInstallFixture()
      let fm = FileManager.default
      let external = fixture.root.appending(path: "external")
      try fm.createDirectory(at: external, withIntermediateDirectories: true)
      let before = try SkillInstaller.projectFingerprint(external)
      var saves = 0
      var state = fixture.state
      #expect(throws: ProjectInstallFailure.self) {
        try SkillInstaller.applyProjectPlan(fixture.plan(), state: &state, persist: { _ in
          saves += 1
          if saves == swapAt {
            let ancestor = fixture.project.url.appending(path: ".agents")
            if fm.fileExists(atPath: ancestor.path) { try fm.moveItem(at: ancestor, to: fixture.root.appending(path: "moved-ancestor")) }
            try fm.createSymbolicLink(at: ancestor, withDestinationURL: external)
          }
        }, trash: fixture.trash)
      }
      #expect(try SkillInstaller.projectFingerprint(external) == before)
      #expect(state.pending != nil)
    }
  }

  @Test func differingSupportingTreesRequireSourceChoiceAndSlugCollisionsBlock() throws {
    let fixture = try ProjectInstallFixture()
    let other = fixture.root.appending(path: "library/other")
    try FileManager.default.copyItem(at: fixture.source, to: other)
    try Data("other implementation".utf8).write(to: other.appending(path: "scripts/run.sh"))
    let second = ProjectInstallFixture.skill("demo", at: other)
    let ambiguous = Skill(name: "demo", description: "", copies: fixture.skill.copies + second.copies)
    #expect(!fixture.plan(skills: [ambiguous]).canApply)
    let chosen = SkillInstaller.projectPlan(project: fixture.project, state: fixture.state, skills: [ambiguous],
      skillsetID: fixture.skillsetID, members: ["demo"], target: .shared, preferredSources: ["demo": other.path])
    #expect(chosen.canApply)
    #expect(chosen.changes.first?.sourcePath == other.path)
    let collision = SkillInstaller.projectPlan(project: fixture.project, state: fixture.state,
      skills: [ProjectInstallFixture.skill("Foo Bar", at: fixture.source), ProjectInstallFixture.skill("foo-bar", at: other)],
      skillsetID: fixture.skillsetID, members: ["Foo Bar", "foo-bar"], target: .shared)
    #expect(!collision.canApply)
    #expect(collision.issues.contains { $0.contains("same project folder name") })
  }

  @Test func changingOwnedSkillToDifferentIDWithSameSlugCannotRemoveDesiredCopy() throws {
    let fixture = try ProjectInstallFixture()
    let old = ProjectInstallFixture.skill("Foo Bar", at: fixture.source)
    let oldPlan = SkillInstaller.projectPlan(project: fixture.project, state: fixture.state, skills: [old],
      skillsetID: fixture.skillsetID, members: [old.id], target: .shared)
    _ = try fixture.apply(oldPlan)
    let receipt = try #require(fixture.state.entries.first)
    let next = ProjectInstallFixture.skill("foo-bar", at: fixture.source)
    let preview = SkillInstaller.projectPlan(project: fixture.project, state: fixture.state, skills: [next],
      skillsetID: fixture.skillsetID, members: [next.id], target: .shared)
    #expect(!preview.canApply)
    #expect(preview.issues.contains { $0.contains("owned as Foo Bar") })
    #expect(throws: ProjectInstallFailure.self) { try fixture.apply(preview) }
    #expect(SkillInstaller.projectEntryUnchanged(receipt))
    #expect(fixture.state.assignments.first?.members == [old.id])
    #expect(fixture.trashed.isEmpty)
  }

  @Test func absoluteAndEscapingEmbeddedLinksAreRefused() throws {
    for link in ["/bin/sh", "../../outside"] {
      let fixture = try ProjectInstallFixture()
      try FileManager.default.createSymbolicLink(atPath: fixture.source.appending(path: "unsafe").path,
        withDestinationPath: link)
      #expect(!fixture.plan().canApply)
      #expect(throws: ProjectInstallFailure.self) { try SkillInstaller.projectFingerprint(fixture.source, requirePortableLinks: true) }
      #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }
  }

  @Test func persistenceFailureAtEveryInstallPhaseRecoversFromDurableState() throws {
    for failAt in 1...6 {
      let fixture = try ProjectInstallFixture()
      var state = fixture.state
      var durable = state
      var saves = 0
      #expect(throws: ProjectInstallFailure.self) {
        try SkillInstaller.applyProjectPlan(fixture.plan(), state: &state, persist: { next in
          saves += 1
          if saves == failAt { throw CocoaError(.fileWriteUnknown) }
          durable = try JSONDecoder().decode(ProjectState.self, from: JSONEncoder().encode(next))
        }, trash: fixture.trash)
      }
      #expect(saves == failAt)
      #expect(state == durable)
      if durable.pending == nil {
        let preview = SkillInstaller.projectPlan(project: fixture.project, state: durable, skills: [fixture.skill],
          skillsetID: fixture.skillsetID, members: ["demo"], target: .shared)
        _ = try SkillInstaller.applyProjectPlan(preview, state: &durable, persist: { _ in }, trash: fixture.trash)
      } else {
        _ = try SkillInstaller.recoverProjectOperation(state: &durable, persist: { _ in }, trash: fixture.trash)
      }
      #expect(durable.pending == nil)
      #expect(durable.entries.count == 1)
      #expect(durable.assignments.count == 1)
      #expect(SkillInstaller.projectEntryUnchanged(durable.entries[0]))
      #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.deletingLastPathComponent().path) == ["demo"])
    }
  }

  @Test func crashAfterTrashBeforePromotionFinishesReplacementWithoutLosingOriginal() throws {
    let fixture = try ProjectInstallFixture()
    _ = try fixture.apply()
    let oldHash = fixture.state.entries[0].installedFingerprint
    try Data("new implementation".utf8).write(to: fixture.source.appending(path: "scripts/run.sh"))
    let preview = fixture.plan()
    #expect(preview.changes.first?.kind == .replace)
    var state = fixture.state
    var durable = state
    #expect(throws: ProjectInstallFailure.self) {
      try SkillInstaller.applyProjectPlan(preview, state: &state, persist: { next in
        if next.pending?.steps.first?.phase == .displaced { throw CocoaError(.fileWriteUnknown) }
        durable = next
      }, trash: fixture.trash)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    #expect(fixture.trashed.count == 1)
    #expect(try SkillInstaller.projectFingerprint(fixture.trashed[0]) == oldHash)
    _ = try SkillInstaller.recoverProjectOperation(state: &durable, persist: { _ in }, trash: fixture.trash)
    #expect(durable.pending == nil)
    #expect(SkillInstaller.projectEntryUnchanged(durable.entries[0]))
    #expect(durable.entries[0].installedFingerprint != oldHash)
  }

  @Test func removalSaveFailureRecoversWithoutTouchingAnUnrelatedNewCopy() throws {
    let fixture = try ProjectInstallFixture()
    _ = try fixture.apply()
    var state = fixture.state
    var durable = state
    #expect(throws: ProjectInstallFailure.self) {
      try SkillInstaller.applyProjectPlan(fixture.unassign(), state: &state, persist: { next in
        if next.pending?.steps.first?.phase == .completed { throw CocoaError(.fileWriteUnknown) }
        durable = next
      }, trash: fixture.trash)
    }
    #expect(fixture.trashed.count == 1)
    try FileManager.default.copyItem(at: fixture.source, to: fixture.destination)
    let independentIdentity = try ProjectDirectoryIdentity.read(at: fixture.destination)
    #expect(throws: ProjectInstallFailure.self) {
      try SkillInstaller.recoverProjectOperation(state: &durable, persist: { _ in }, trash: fixture.trash)
    }
    #expect(durable.pending != nil)
    #expect(try ProjectDirectoryIdentity.read(at: fixture.destination) == independentIdentity)
    #expect(fixture.trashed.count == 1)
    try FileManager.default.moveItem(at: fixture.destination, to: fixture.root.appending(path: "independent-copy"))
    _ = try SkillInstaller.recoverProjectOperation(state: &durable, persist: { _ in }, trash: fixture.trash)
    #expect(durable.pending == nil)
    #expect(durable.entries.isEmpty)
    #expect(durable.assignments.isEmpty)
  }

  @Test func changedStageBeforeDisplacementPreservesOriginalInPlace() throws {
    let fixture = try ProjectInstallFixture()
    _ = try fixture.apply()
    let original = fixture.state.entries[0]
    try Data("new implementation".utf8).write(to: fixture.source.appending(path: "scripts/run.sh"))
    var state = fixture.state
    #expect(throws: ProjectInstallFailure.self) {
      try SkillInstaller.applyProjectPlan(fixture.plan(), state: &state, persist: { next in
        if let step = next.pending?.steps.first, step.phase == .staged, let path = step.stagePath {
          try Data("changed by user".utf8).write(to: URL(fileURLWithPath: path).appending(path: "SKILL.md"))
        }
      }, trash: fixture.trash)
    }
    #expect(SkillInstaller.projectEntryUnchanged(original))
    #expect(fixture.trashed.isEmpty)
    #expect(state.pending != nil)
  }

  @Test func copyFailurePreservesPartialStageAndExplicitAbandonUnblocksProject() throws {
    let fixture = try ProjectInstallFixture()
    _ = try fixture.apply()
    let original = fixture.state.entries[0]
    try Data("new implementation".utf8).write(to: fixture.source.appending(path: "scripts/run.sh"))
    var state = fixture.state
    #expect(throws: (any Error).self) {
      try SkillInstaller.applyProjectPlan(fixture.plan(), state: &state, persist: { next in
        if let step = next.pending?.steps.first, step.phase == .prepared,
           step.stageIdentity != nil, let path = step.stagePath {
          try Data("partial copy".utf8).write(to: URL(fileURLWithPath: path).appending(path: "SKILL.md"))
        }
      }, trash: fixture.trash)
    }
    let stage = URL(fileURLWithPath: try #require(state.pending?.steps.first?.stagePath))
    #expect(state.pending?.steps.first?.phase == .prepared)
    #expect(state.pending?.steps.first?.stageIdentity != nil)
    let partialHash = try SkillInstaller.projectFingerprint(stage)
    #expect(throws: ProjectInstallFailure.self) {
      try SkillInstaller.recoverProjectOperation(state: &state, persist: { _ in }, trash: fixture.trash)
    }
    let pending = state
    #expect(throws: ProjectInstallFailure.self) {
      try SkillInstaller.abandonProjectOperation(state: &state, persist: { _ in throw CocoaError(.fileWriteUnknown) })
    }
    #expect(state == pending)
    let result = try SkillInstaller.abandonProjectOperation(state: &state, persist: { _ in })
    #expect(state.pending == nil)
    #expect(state.entries == fixture.state.entries)
    #expect(state.assignments == fixture.state.assignments)
    #expect(result.notes.contains { $0.contains(stage.path) })
    #expect(try SkillInstaller.projectFingerprint(stage) == partialHash)
    #expect(SkillInstaller.projectEntryUnchanged(original))
    #expect(fixture.trashed.isEmpty)
    #expect(SkillInstaller.projectPlan(project: fixture.project, state: state, skills: [fixture.skill],
      skillsetID: fixture.skillsetID, members: ["demo"], target: .shared).canApply)
  }

  @Test func abandonAdoptsOnlyProvenPromotedCopiesAndKeepsCompletedReceipts() throws {
    for failAfterPromotion in [false, true] {
      let fixture = try ProjectInstallFixture()
      var state = fixture.state
      #expect(throws: ProjectInstallFailure.self) {
        try SkillInstaller.applyProjectPlan(fixture.plan(), state: &state, persist: { next in
          if failAfterPromotion && next.pending?.steps.first?.phase == .promoted { throw CocoaError(.fileWriteUnknown) }
          if !failAfterPromotion && next.pending == nil { throw CocoaError(.fileWriteUnknown) }
        }, trash: fixture.trash)
      }
      let identity = try ProjectDirectoryIdentity.read(at: fixture.destination)
      _ = try SkillInstaller.abandonProjectOperation(state: &state, persist: { _ in })
      #expect(state.pending == nil)
      #expect(state.entries.count == 1)
      #expect(state.entries[0].directoryIdentity == identity)
      #expect(SkillInstaller.projectEntryUnchanged(state.entries[0]))
      #expect(state.assignments.isEmpty)
      #expect(fixture.trashed.isEmpty)
    }
    let fixture = try ProjectInstallFixture()
    var state = fixture.state
    #expect(throws: ProjectInstallFailure.self) {
      try SkillInstaller.applyProjectPlan(fixture.plan(), state: &state, persist: { next in
        if next.pending?.steps.first?.phase == .staged { throw CocoaError(.fileWriteUnknown) }
      }, trash: fixture.trash)
    }
    try FileManager.default.copyItem(at: fixture.source, to: fixture.destination)
    let identity = try ProjectDirectoryIdentity.read(at: fixture.destination)
    _ = try SkillInstaller.abandonProjectOperation(state: &state, persist: { _ in })
    #expect(state.pending == nil)
    #expect(state.entries.isEmpty)
    #expect(try ProjectDirectoryIdentity.read(at: fixture.destination) == identity)
    #expect(fixture.trashed.isEmpty)
  }

  @Test func recoveryDoesNotAdoptUnrelatedDestinationWithMatchingContent() throws {
    let fixture = try ProjectInstallFixture()
    var state = fixture.state
    #expect(throws: ProjectInstallFailure.self) {
      try SkillInstaller.applyProjectPlan(fixture.plan(), state: &state, persist: { next in
        if next.pending?.steps.first?.phase == .staged { throw CocoaError(.fileWriteUnknown) }
      }, trash: fixture.trash)
    }
    let stage = try #require(state.pending?.steps.first?.stagePath)
    let stageIdentity = try #require(state.pending?.steps.first?.stageIdentity)
    try FileManager.default.copyItem(at: fixture.source, to: fixture.destination)
    let independentIdentity = try ProjectDirectoryIdentity.read(at: fixture.destination)
    #expect(independentIdentity != stageIdentity)
    #expect(throws: ProjectInstallFailure.self) {
      try SkillInstaller.recoverProjectOperation(state: &state, persist: { _ in }, trash: fixture.trash)
    }
    #expect(state.pending != nil)
    #expect(state.entries.isEmpty)
    #expect(FileManager.default.fileExists(atPath: stage))
    #expect(try ProjectDirectoryIdentity.read(at: fixture.destination) == independentIdentity)
    #expect(fixture.trashed.isEmpty)
  }

  @Test func changedStageAndMaliciousReceiptsCannotAuthorizeRemoval() throws {
    let fixture = try ProjectInstallFixture()
    _ = try fixture.apply()
    let old = fixture.state.entries[0]
    let outside = fixture.root.appending(path: "outside")
    try FileManager.default.copyItem(at: fixture.source, to: outside)
    fixture.state.entries = [ProjectSkillEntry(projectID: old.projectID, skillID: old.skillID, target: old.target,
      path: outside.path, sourcePath: old.sourcePath, sourceFingerprint: old.sourceFingerprint,
      installedFingerprint: old.installedFingerprint, directoryIdentity: try ProjectDirectoryIdentity.read(at: outside))]
    #expect(!fixture.unassign().canApply)
    #expect(throws: ProjectInstallFailure.self) { try fixture.apply(fixture.unassign()) }
    #expect(FileManager.default.fileExists(atPath: outside.path))
    #expect(fixture.trashed.isEmpty)

    let staged = try ProjectInstallFixture()
    var state = staged.state
    #expect(throws: ProjectInstallFailure.self) {
      try SkillInstaller.applyProjectPlan(staged.plan(), state: &state, persist: { next in
        if next.pending?.steps.first?.phase == .staged { throw CocoaError(.fileWriteUnknown) }
      }, trash: staged.trash)
    }
    let path = try #require(state.pending?.steps.first?.stagePath)
    try Data("changed stage".utf8).write(to: URL(fileURLWithPath: path).appending(path: "SKILL.md"))
    #expect(throws: ProjectInstallFailure.self) {
      try SkillInstaller.recoverProjectOperation(state: &state, persist: { _ in }, trash: staged.trash)
    }
    #expect(state.pending != nil)
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(!FileManager.default.fileExists(atPath: staged.destination.path))
  }
}
