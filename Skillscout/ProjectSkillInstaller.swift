import CryptoKit
import Foundation

struct ProjectSkillChange: Identifiable, Equatable {
  let kind: ProjectPendingStep.Operation
  let skillID: Skill.ID
  let sourcePath: String?
  let destinationPath: String
  var id: String { destinationPath }
  fileprivate let sourceFingerprint: String?
  fileprivate let previousReceipt: ProjectSkillEntry?
}

struct ProjectSkillPlan {
  let project: RegisteredProject
  let target: ProjectSkillTarget
  let intent: ProjectPlanIntent
  let proposedAssignments: [ProjectSkillsetAssignment]
  var changes: [ProjectSkillChange] = []
  var kept: [String] = []
  var issues: [String] = []
  /// Changes left out so no agent reads two versions of a skill; the rest of the plan still applies.
  var leftOut: [String] = []
  /// Worth knowing before applying, but not blocking.
  var warnings: [String] = []
  var canApply: Bool { issues.isEmpty }
  var sourcePaths: [String] { Array(Set(changes.compactMap(\.sourcePath))).sorted() }

  fileprivate let skills: [Skill]
  fileprivate let preferences: SourcePreferences
  fileprivate let baseline: ProjectState
  fileprivate var observations: [String] = []
}

struct ProjectApplyResult {
  var notes: [String] = []
  var trashed: [URL] = []
}

typealias ProjectTrashMover = (URL) throws -> URL

enum ProjectInstallFailure: LocalizedError {
  case unsafe(String), stalePreview, pendingOperation, persistence(String)
  var errorDescription: String? {
    switch self {
    case .unsafe(let message): message
    case .stalePreview: "The project, source, or installation changed after preview. Refresh the preview before applying."
    case .pendingOperation: "A project operation needs recovery before another change can be applied."
    case .persistence(let message): "Project state could not be saved. Further changes stopped: \(message)"
    }
  }
}

extension SkillInstaller {
  static func projectPlan(project: RegisteredProject, state: ProjectState, skills: [Skill],
                          skillsetID: UUID, members: Set<Skill.ID>, target: ProjectSkillTarget,
                          preferences: SourcePreferences = SourcePreferences()) -> ProjectSkillPlan {
    var assignments = state.assignments.filter {
      !($0.projectID == project.id && $0.skillsetID == skillsetID && $0.target == target && $0.individualSkillID == nil)
    }
    assignments.append(ProjectSkillsetAssignment(projectID: project.id, skillsetID: skillsetID,
                                                 target: target, members: members))
    return makeProjectPlan(project: project, state: state, skills: skills, assignments: assignments,
                           target: target, preferences: preferences)
  }

  static func projectSkillsPlan(project: RegisteredProject, state: ProjectState, skills: [Skill],
                                skillIDs: Set<Skill.ID>, target: ProjectSkillTarget,
                                preferences: SourcePreferences = SourcePreferences()) -> ProjectSkillPlan {
    var assignments = state.assignments
    for id in skillIDs.sorted() where !assignments.contains(where: {
      $0.projectID == project.id && $0.target == target && $0.individualSkillID == id
    }) {
      var assignmentID = UUID()
      while assignments.contains(where: { $0.skillsetID == assignmentID }) { assignmentID = UUID() }
      assignments.append(ProjectSkillsetAssignment(projectID: project.id, skillsetID: assignmentID,
        target: target, members: [id], individualSkillID: id))
    }
    return makeProjectPlan(project: project, state: state, skills: skills, assignments: assignments,
      target: target, preferences: preferences)
  }

  static func projectRemoveSkillPlan(project: RegisteredProject, state: ProjectState, skills: [Skill],
                                     skillID: Skill.ID, target: ProjectSkillTarget,
                                     preferences: SourcePreferences = SourcePreferences()) -> ProjectSkillPlan {
    let assignments = removingProjectSkill(skillID, from: state.assignments, projectID: project.id, target: target)
    return makeProjectPlan(project: project, state: state, skills: skills, assignments: assignments,
      target: target, preferences: preferences, intent: .removeSkill(skillID))
  }

  private static func removingProjectSkill(_ id: Skill.ID, from assignments: [ProjectSkillsetAssignment],
                                           projectID: UUID, target: ProjectSkillTarget) -> [ProjectSkillsetAssignment] {
    assignments.compactMap { assignment in
      guard assignment.projectID == projectID && assignment.target == target else { return assignment }
      var updated = assignment
      updated.members.remove(id)
      return updated.individualSkillID != nil && updated.members.isEmpty ? nil : updated
    }
  }

  static func projectUnassignPlan(project: RegisteredProject, state: ProjectState, skills: [Skill],
                                  skillsetID: UUID, target: ProjectSkillTarget,
                                  preferences: SourcePreferences = SourcePreferences()) -> ProjectSkillPlan {
    let assignments = state.assignments.filter {
      !($0.projectID == project.id && $0.skillsetID == skillsetID && $0.target == target)
    }
    return makeProjectPlan(project: project, state: state, skills: skills, assignments: assignments,
                           target: target, preferences: preferences)
  }

  private static func makeProjectPlan(project: RegisteredProject, state: ProjectState, skills: [Skill],
                                      assignments: [ProjectSkillsetAssignment], target: ProjectSkillTarget,
                                      preferences: SourcePreferences, intent: ProjectPlanIntent = .reconcile) -> ProjectSkillPlan {
    let proposed = assignments.filter { $0.projectID == project.id && $0.target == target }
    var plan = ProjectSkillPlan(project: project, target: target, intent: intent, proposedAssignments: proposed,
                               skills: skills, preferences: preferences, baseline: state)
    do {
      guard state.pending == nil else { throw ProjectInstallFailure.pendingOperation }
      guard state.projects.contains(project) else { throw ProjectInstallFailure.unsafe("Register this project before applying skills.") }
      try validateProjectAssignments(state.assignments.filter { $0.projectID == project.id && $0.target == target })
      try validateProjectPath(project, target: target)
      plan.observations.append(try projectAncestorSignature(project, target: target))
      let receipts = state.entries.filter {
        guard $0.projectID == project.id && $0.target == target else { return false }
        if case .removeSkill(let id) = intent { return $0.skillID == id }
        return true
      }
      for entry in receipts { try validateProjectReceipt(entry, project: project, target: target) }
      guard Set(receipts.map(\.path)).count == receipts.count,
            Set(receipts.map(\.skillID)).count == receipts.count else {
        throw ProjectInstallFailure.unsafe("Duplicate project ownership receipts need to be repaired before applying.")
      }
      guard Set(proposed.map(\.skillsetID)).count == proposed.count else {
        throw ProjectInstallFailure.unsafe("Duplicate project skillset assignments need to be repaired before applying.")
      }
      try validateProjectAssignments(proposed)
      let desired = proposed.reduce(into: Set<Skill.ID>()) { $0.formUnion($1.members) }
      let reconciled: Set<Skill.ID> = intent == .reconcile ? desired : []
      var destinations: [String: String] = [:]
      var plannedHashes: [String: String] = [:]
      for id in reconciled.sorted() {
        let destination = try projectDestination(id, project: project, target: target)
        if let other = destinations[destination.path], other != id {
          plan.issues.append("\(other) and \(id) have the same project folder name. Rename one before applying.")
          continue
        }
        destinations[destination.path] = id
        if let owner = receipts.first(where: { $0.path == destination.path && $0.skillID != id }) {
          plan.issues.append("\(id): this folder is owned as \(owner.skillID). Unassign that skill before applying a different name to the same folder.")
          continue
        }
        let receipt = receipts.first { $0.skillID == id }
        let existing = try projectObservation(destination)
        plan.observations.append(existing)
        if let receipt, projectExists(destination), !projectEntryUnchanged(receipt) {
          plan.kept.append("\(id): kept its modified project copy without updating it.")
          continue
        }
        guard let skill = skills.first(where: { $0.id == id }) else {
          if let receipt, projectEntryUnchanged(receipt) {
            plan.kept.append("\(id): kept the existing copy; its library source is missing.")
          } else {
            plan.issues.append("\(id): no library or installed source is available.")
          }
          continue
        }
        do {
          let (source, fingerprint) = try projectSource(skill, project: project, preferences: preferences)
          plan.observations.append("source:\(id):\(source.path):\(fingerprint)")
          plannedHashes[destination.path] = shortHash(try String(contentsOf: source.appending(path: "SKILL.md"), encoding: .utf8))
          if projectExists(destination) {
            if let receipt {
              if receipt.installedFingerprint == fingerprint {
                plan.kept.append("\(id): already installed in this project.")
              } else {
                plan.changes.append(ProjectSkillChange(kind: .replace, skillID: id, sourcePath: source.path,
                  destinationPath: destination.path, sourceFingerprint: fingerprint, previousReceipt: receipt))
              }
            } else if (try? projectFingerprint(destination)) == fingerprint {
              plan.kept.append("\(id): kept the identical existing copy without taking ownership.")
            } else {
              plan.issues.append("\(id): a different existing copy occupies \(destination.path). It will be preserved.")
            }
          } else {
            plan.changes.append(ProjectSkillChange(kind: .install, skillID: id, sourcePath: source.path,
              destinationPath: destination.path, sourceFingerprint: fingerprint, previousReceipt: receipt))
          }
        } catch { plan.issues.append("\(id): \(error.localizedDescription)") }
      }
      if case .removeSkill(let id) = intent, receipts.isEmpty {
        let destination = try projectDestination(id, project: project, target: target)
        plan.observations.append(try projectObservation(destination))
        if projectExists(destination) { plan.kept.append("\(id): kept its existing project copy without an ownership receipt.") }
      }
      for receipt in receipts.filter({ !desired.contains($0.skillID) }).sorted(by: { $0.path < $1.path }) {
        let destination = URL(fileURLWithPath: receipt.path)
        plan.observations.append(try projectObservation(destination))
        if !projectExists(destination) {
          plan.kept.append("\(receipt.skillID): its missing copy will no longer be tracked.")
        } else if projectEntryUnchanged(receipt) {
          plan.changes.append(ProjectSkillChange(kind: .remove, skillID: receipt.skillID, sourcePath: nil,
            destinationPath: receipt.path, sourceFingerprint: nil, previousReceipt: receipt))
        } else {
          plan.kept.append("\(receipt.skillID): kept its modified copy; it will no longer be tracked.")
        }
      }
      checkProjectVersions(&plan, plannedHashes: plannedHashes)
    } catch { plan.issues.append(error.localizedDescription) }
    return plan
  }

  /// Keeps each agent on one version of a skill across the project's own folders. A change that would give an agent
  /// a second version is left out; a conflict the project already has is reported. Neither stops the other skills.
  private static func checkProjectVersions(_ plan: inout ProjectSkillPlan, plannedHashes: [String: String]) {
    let existing = ProjectLibrary.inventory(project: plan.project, globalSkills: []).skills.flatMap { row in
      row.localCopies.map { PlannedCopy(skillID: row.name, folder: $0.folder, contentHash: $0.contentHash, readBy: $0.root.readBy) }
    }
    let target = plan.target
    func additions(_ changes: [ProjectSkillChange]) -> [PlannedCopy] {
      changes.compactMap { change in
        plannedHashes[change.destinationPath].map {
          PlannedCopy(skillID: change.skillID, folder: URL(fileURLWithPath: change.destinationPath), contentHash: $0, readBy: target.readBy)
        }
      }
    }
    let removing = Set(plan.changes.filter { $0.kind == .remove }.map { SkillVersions.key(URL(fileURLWithPath: $0.destinationPath)) })
    let adding = additions(plan.changes)
    let created = SkillVersions.newConflicts(existing: existing, adding: adding, removing: removing)
    for text in created.map({ SkillVersions.message($0, adding: adding) }) where !plan.leftOut.contains(text) { plan.leftOut.append(text) }
    let blocked = Set(created.map(\.skillID))
    plan.changes.removeAll { $0.kind != .remove && blocked.contains($0.skillID) }
    let kept = additions(plan.changes)
    plan.warnings += SkillVersions.conflicts(existing: existing, adding: kept, removing: removing).map { SkillVersions.message($0) }
    plan.warnings += homeWarnings(kept, skills: plan.skills)
  }

  /// An agent that reads a project copy can also read a different copy in a home folder. Which one it uses is the
  /// agent's call, so this warns instead of blocking.
  private static func homeWarnings(_ adding: [PlannedCopy], skills: [Skill]) -> [String] {
    let agents = SkillVersions.countedAgents
    return adding.flatMap { planned -> [String] in
      guard let skill = skills.first(where: { $0.id == planned.skillID }) else { return [] }
      return Tool.allCases.filter { planned.readBy.contains($0) && agents.contains($0) }.compactMap { tool -> String? in
        // Plugin skills are namespaced by their plugin, so they load next to a project skill instead of competing.
        let folders = skill.copies.filter { $0.root.kind != .plugin && $0.root.readBy.contains(tool) && $0.contentHash != planned.contentHash }
          .map { Paths.abbreviate($0.folder.deletingLastPathComponent()) }
          .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard !folders.isEmpty else { return nil }
        let start = "\(planned.skillID): \(tool.name) also reads a different copy in \(folders.joined(separator: ", "))."
        return tool.personalOverridesProject
          ? "\(start) \(tool.name) uses its personal copy over the project's."
          : "\(start) Which copy \(tool.name) uses is up to \(tool.name)."
      }
    }
  }

  static func applyProjectPlan(_ plan: ProjectSkillPlan, state: inout ProjectState,
                               persist: (ProjectState) throws -> Void,
                               trash: ProjectTrashMover? = nil) throws -> ProjectApplyResult {
    guard state.pending == nil else { throw ProjectInstallFailure.pendingOperation }
    guard plan.canApply else { throw ProjectInstallFailure.unsafe(plan.issues.joined(separator: "\n")) }
    let scope: (ProjectState) -> ProjectState = { value in
      ProjectState(projects: value.projects.filter { $0.id == plan.project.id },
        assignments: value.assignments.filter { $0.projectID == plan.project.id && $0.target == plan.target },
        entries: value.entries.filter { $0.projectID == plan.project.id && $0.target == plan.target }, pending: value.pending)
    }
    guard scope(state) == scope(plan.baseline) else { throw ProjectInstallFailure.stalePreview }
    let current = makeProjectPlan(project: plan.project, state: state, skills: plan.skills,
      assignments: state.assignments.filter { !($0.projectID == plan.project.id && $0.target == plan.target) }
        + plan.proposedAssignments, target: plan.target, preferences: plan.preferences, intent: plan.intent)
    guard current.canApply, current.observations == plan.observations,
          current.changes == plan.changes, current.kept == plan.kept else { throw ProjectInstallFailure.stalePreview }
    let steps = plan.changes.map { change in
      ProjectPendingStep(skillID: change.skillID, operation: change.kind, phase: .prepared,
        destinationPath: change.destinationPath, sourcePath: change.sourcePath,
        stagePath: change.kind == .remove ? nil : plan.target.url(in: plan.project)
          .appending(path: ".skillscout-stage-\(UUID().uuidString)").path,
        stageIdentity: nil, expectedFingerprint: change.sourceFingerprint,
        previousReceipt: change.previousReceipt, newReceipt: nil, trashPath: nil)
    }
    var next = state
    next.pending = ProjectPendingJournal(projectID: plan.project.id, target: plan.target,
      previousAssignments: state.assignments.filter { $0.projectID == plan.project.id && $0.target == plan.target },
      proposedAssignments: plan.proposedAssignments, steps: steps, intent: plan.intent)
    try saveProjectState(next, into: &state, persist: persist)
    var result = try continueProjectJournal(state: &state, persist: persist, trash: trash)
    result.notes = plan.leftOut + plan.kept + result.notes
    return result
  }

  static func recoverProjectOperation(state: inout ProjectState, persist: (ProjectState) throws -> Void,
                                      trash: ProjectTrashMover? = nil) throws -> ProjectApplyResult {
    guard state.pending != nil else { return ProjectApplyResult() }
    return try continueProjectJournal(state: &state, persist: persist, trash: trash)
  }

  static func abandonProjectOperation(state: inout ProjectState,
                                       persist: (ProjectState) throws -> Void) throws -> ProjectApplyResult {
    guard let journal = state.pending else { return ProjectApplyResult() }
    var next = state
    var result = ProjectApplyResult(notes: ["Stopped recovery while keeping every project file. Applied skillsets may be incomplete; review a new preview."])
    if let project = state.projects.first(where: { $0.id == journal.projectID }),
       (try? validateProjectJournal(journal, project: project, state: state)) != nil {
      for step in journal.steps {
        guard step.operation != .remove, let receipt = step.newReceipt,
              receipt.directoryIdentity == step.stageIdentity,
              receipt.installedFingerprint == step.expectedFingerprint,
              projectEntryUnchanged(receipt),
              step.stagePath.map({ !projectExists(URL(fileURLWithPath: $0)) }) == true else { continue }
        next.entries.removeAll { $0.projectID == project.id && $0.target == journal.target && $0.skillID == step.skillID }
        next.entries.append(receipt)
        result.notes.append("Retained ownership of \(step.skillID), verified by its promoted staging-directory identity.")
      }
      next.assignments.removeAll { $0.projectID == project.id && $0.target == journal.target }
      next.assignments += journal.previousAssignments
    } else {
      result.notes.append("The pending operation could not be validated. Existing assignments and receipts were preserved.")
    }
    for path in journal.steps.compactMap(\.stagePath) {
      if projectExists(URL(fileURLWithPath: path)) { result.notes.append("Preserved staging files at \(path)") }
    }
    next.pending = nil
    try saveProjectState(next, into: &state, persist: persist)
    return result
  }

  private static func continueProjectJournal(state: inout ProjectState, persist: (ProjectState) throws -> Void,
                                              trash: ProjectTrashMover?) throws -> ProjectApplyResult {
    guard let initial = state.pending,
          let project = state.projects.first(where: { $0.id == initial.projectID }) else {
      throw ProjectInstallFailure.unsafe("The pending operation's registered project is missing. No files were changed.")
    }
    try validateProjectJournal(initial, project: project, state: state)
    var result = ProjectApplyResult()
    for index in initial.steps.indices {
      try runProjectStep(index, project: project, state: &state, persist: persist, trash: trash, result: &result)
    }
    guard let journal = state.pending else { throw ProjectInstallFailure.pendingOperation }
    var next = state
    next.assignments.removeAll { $0.projectID == journal.projectID && $0.target == journal.target }
    next.assignments += journal.proposedAssignments
    let desired = journal.proposedAssignments.reduce(into: Set<String>()) { $0.formUnion($1.members) }
    next.entries.removeAll {
      guard $0.projectID == journal.projectID && $0.target == journal.target else { return false }
      if case .removeSkill(let id) = journal.intent ?? .reconcile { return $0.skillID == id }
      return !desired.contains($0.skillID)
    }
    next.pending = nil
    try saveProjectState(next, into: &state, persist: persist)
    return result
  }

  private static func runProjectStep(_ index: Int, project: RegisteredProject, state: inout ProjectState,
                                     persist: (ProjectState) throws -> Void, trash: ProjectTrashMover?,
                                     result: inout ProjectApplyResult) throws {
    guard let journal = state.pending else { throw ProjectInstallFailure.pendingOperation }
    var step = journal.steps[index]
    let target = journal.target
    let destination = URL(fileURLWithPath: step.destinationPath)
    try validateProjectPath(project, target: target)
    if step.phase == .completed {
      if step.operation != .remove {
        guard let receipt = step.newReceipt, projectEntryUnchanged(receipt) else {
          throw ProjectInstallFailure.unsafe("\(step.skillID): a completed copy changed during recovery. It was preserved.")
        }
      }
      return
    }
    if step.operation == .remove {
      if projectExists(destination) {
        guard let receipt = step.previousReceipt, projectEntryUnchanged(receipt) else {
          throw ProjectInstallFailure.unsafe("\(step.skillID): its copy changed before removal and was preserved.")
        }
        try validateProjectPath(project, target: target)
        let removed = try projectTrash(destination, mover: trash)
        result.trashed.append(removed)
        step.trashPath = removed.path
      }
      step.phase = .completed
      var next = state
      next.entries.removeAll { $0.projectID == project.id && $0.target == target && $0.skillID == step.skillID }
      next.pending?.steps[index] = step
      try saveProjectState(next, into: &state, persist: persist)
      return
    }
    guard let stagePath = step.stagePath, let sourcePath = step.sourcePath,
          let fingerprint = step.expectedFingerprint else {
      throw ProjectInstallFailure.unsafe("The pending installation has incomplete source information.")
    }
    let stage = URL(fileURLWithPath: stagePath)
    if let identity = step.stageIdentity,
       let receipt = step.newReceipt,
       projectExists(destination),
       (try? ProjectDirectoryIdentity.read(at: destination)) == identity,
       (try? projectFingerprint(destination)) == fingerprint {
      guard !projectExists(stage) else {
        throw ProjectInstallFailure.unsafe("Both staging and destination folders exist. Recovery preserved them for inspection.")
      }
      step.phase = .completed
      var next = state
      next.entries.removeAll { $0.projectID == project.id && $0.target == target && $0.skillID == step.skillID }
      next.entries.append(receipt)
      next.pending?.steps[index] = step
      try saveProjectState(next, into: &state, persist: persist)
      result.notes.append("Recovered \(step.skillID) from its recorded staging directory.")
      return
    }
    if step.phase == .promoted {
      throw ProjectInstallFailure.unsafe("\(step.skillID): the promoted folder no longer matches its recorded identity. Recovery preserved it.")
    }
    if step.stageIdentity == nil {
      guard !projectExists(stage) else {
        throw ProjectInstallFailure.unsafe("An unrecorded staging folder exists at \(stage.path). Recovery preserved it; move it aside before retrying.")
      }
      let source = URL(fileURLWithPath: sourcePath)
      guard try projectFingerprint(source, requirePortableLinks: true) == fingerprint else {
        throw ProjectInstallFailure.unsafe("\(step.skillID): its source changed before staging. Recovery stopped.")
      }
      try ensureProjectTarget(project, target: target)
      try validateProjectPath(project, target: target)
      try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
      let identity = try ProjectDirectoryIdentity.read(at: stage)
      step.stageIdentity = identity
      step.newReceipt = ProjectSkillEntry(projectID: project.id, skillID: step.skillID, target: target,
        path: destination.path, sourcePath: sourcePath, sourceFingerprint: fingerprint,
        installedFingerprint: fingerprint, directoryIdentity: identity)
      do {
        try saveProjectStep(step, at: index, state: &state, persist: persist)
      } catch {
        if (try? validateProjectPath(project, target: target)) != nil,
           (try? ProjectDirectoryIdentity.read(at: stage)) == identity,
           (try? FileManager.default.contentsOfDirectory(atPath: stage.path).isEmpty) == true {
          if let removed = try? projectTrash(stage, mover: trash) { result.trashed.append(removed) }
        }
        throw error
      }
      try validateProjectPath(project, target: target)
      guard (try? ProjectDirectoryIdentity.read(at: stage)) == identity,
            try projectFingerprint(source, requirePortableLinks: true) == fingerprint else {
        throw ProjectInstallFailure.unsafe("The source or staging folder changed before copying. Files were preserved.")
      }
      try copyProjectTree(source, into: stage)
      guard try projectFingerprint(source, requirePortableLinks: true) == fingerprint,
            try projectFingerprint(stage, requirePortableLinks: true) == fingerprint else {
        throw ProjectInstallFailure.unsafe("\(step.skillID): its source changed while copying. The staged copy was preserved for inspection.")
      }
      step.phase = .staged
      try saveProjectStep(step, at: index, state: &state, persist: persist)
    } else {
      guard projectExists(stage), (try? ProjectDirectoryIdentity.read(at: stage)) == step.stageIdentity,
            (try? projectFingerprint(stage, requirePortableLinks: true)) == fingerprint else {
        throw ProjectInstallFailure.unsafe("\(step.skillID): its staged copy changed or is missing. Recovery preserved all files.")
      }
    }
    try validateProjectPath(project, target: target)
    guard (try? ProjectDirectoryIdentity.read(at: stage)) == step.stageIdentity,
          try projectFingerprint(stage, requirePortableLinks: true) == fingerprint else {
      throw ProjectInstallFailure.unsafe("\(step.skillID): its staged copy changed before replacement. The original copy was preserved.")
    }
    if projectExists(destination) {
      guard step.operation == .replace, let previous = step.previousReceipt, projectEntryUnchanged(previous) else {
        throw ProjectInstallFailure.unsafe("\(step.skillID): an unrelated or modified destination exists. It was preserved.")
      }
      let removed = try projectTrash(destination, mover: trash)
      result.trashed.append(removed)
      step.trashPath = removed.path
      step.phase = .displaced
      try saveProjectStep(step, at: index, state: &state, persist: persist)
    } else if step.operation == .replace, step.phase == .prepared {
      throw ProjectInstallFailure.unsafe("\(step.skillID): its previous copy disappeared before replacement. Recovery stopped.")
    }
    try validateProjectPath(project, target: target)
    guard !projectExists(destination), (try? ProjectDirectoryIdentity.read(at: stage)) == step.stageIdentity,
          try projectFingerprint(stage, requirePortableLinks: true) == fingerprint else {
      throw ProjectInstallFailure.unsafe("\(step.skillID): the destination or stage changed before promotion. Files were preserved.")
    }
    try FileManager.default.moveItem(at: stage, to: destination)
    step.phase = .promoted
    try saveProjectStep(step, at: index, state: &state, persist: persist)
    guard let receipt = step.newReceipt, projectEntryUnchanged(receipt) else {
      throw ProjectInstallFailure.unsafe("\(step.skillID): the promoted copy changed. Recovery needs inspection.")
    }
    step.phase = .completed
    var next = state
    next.entries.removeAll { $0.projectID == project.id && $0.target == target && $0.skillID == step.skillID }
    next.entries.append(receipt)
    next.pending?.steps[index] = step
    try saveProjectState(next, into: &state, persist: persist)
  }

  private static func saveProjectStep(_ step: ProjectPendingStep, at index: Int, state: inout ProjectState,
                                       persist: (ProjectState) throws -> Void) throws {
    var next = state
    next.pending?.steps[index] = step
    try saveProjectState(next, into: &state, persist: persist)
  }

  private static func saveProjectState(_ next: ProjectState, into state: inout ProjectState,
                                      persist: (ProjectState) throws -> Void) throws {
    do { try persist(next) }
    catch { throw ProjectInstallFailure.persistence(error.localizedDescription) }
    state = next
  }

  private static func projectTrash(_ url: URL, mover: ProjectTrashMover?) throws -> URL {
    if let mover { return try mover(url) }
    var result: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &result)
    guard let result else { throw ProjectInstallFailure.unsafe("Trash did not return the moved folder's location.") }
    return result as URL
  }

  /// A skill with versions uses only the project's own choice; `defaults` picks among copies with the same content.
  private static func projectSource(_ skill: Skill, project: RegisteredProject,
                                    preferences: SourcePreferences) throws -> (URL, String) {
    let sources = installableSources(for: skill)
    guard !sources.isEmpty else { throw ProjectInstallFailure.unsafe("This skill has no installable source.") }
    var fingerprints: [(URL, String)] = []
    let versions = SkillVersions.versions(of: skill).count
    let saved = versions > 1 ? preferences.byProject[project.path]?[skill.id] : preferences.defaults[skill.id]
    let preferred = saved.flatMap { path in sources.contains { $0.resolved.path == path } ? path : nil }
    if versions > 1 && preferred == nil {
      throw ProjectInstallFailure.unsafe("It has \(versions) versions. Choose the version this project uses before applying.")
    }
    for copy in sources {
      let source = copy.resolved.standardizedFileURL.resolvingSymlinksInPath()
      if let preferred, preferred != copy.resolved.path { continue }
      guard FileManager.default.fileExists(atPath: source.appending(path: "SKILL.md").path) else {
        throw ProjectInstallFailure.unsafe("Its selected source no longer contains SKILL.md.")
      }
      fingerprints.append((source, try projectFingerprint(source, requirePortableLinks: true)))
    }
    guard let first = fingerprints.first else { throw ProjectInstallFailure.unsafe("Choose an available source before applying.") }
    guard preferred != nil || Set(fingerprints.map(\.1)).count == 1 else {
      throw ProjectInstallFailure.unsafe("Its installed copies differ, including supporting files. Choose a source before applying.")
    }
    return first
  }

  private static func projectDestination(_ id: String, project: RegisteredProject, target: ProjectSkillTarget) throws -> URL {
    let name = slug(id)
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
      throw ProjectInstallFailure.unsafe("\(id): invalid project skill folder name.")
    }
    return target.url(in: project).appending(path: name)
  }

  private static func validateProjectReceipt(_ entry: ProjectSkillEntry, project: RegisteredProject, target: ProjectSkillTarget) throws {
    guard entry.projectID == project.id, entry.target == target,
          entry.path == (try projectDestination(entry.skillID, project: project, target: target)).path else {
      throw ProjectInstallFailure.unsafe("A project receipt points outside its authorized skill folder. No files were changed.")
    }
  }

  private static func validateProjectAssignments(_ assignments: [ProjectSkillsetAssignment]) throws {
    let individuals = assignments.compactMap(\.individualSkillID)
    guard Set(assignments.map(\.skillsetID)).count == assignments.count,
          Set(individuals).count == individuals.count,
          assignments.allSatisfy({ assignment in
            assignment.individualSkillID.map { assignment.members == [$0] } ?? true
          }) else {
      throw ProjectInstallFailure.unsafe("Project assignments contain duplicate or inconsistent individual skills.")
    }
  }

  private static func validateProjectJournal(_ journal: ProjectPendingJournal, project: RegisteredProject,
                                             state: ProjectState) throws {
    try validateProjectPath(project, target: journal.target)
    guard journal.projectID == project.id,
          journal.previousAssignments == state.assignments.filter({ $0.projectID == project.id && $0.target == journal.target }),
          journal.previousAssignments.allSatisfy({ $0.projectID == project.id && $0.target == journal.target }),
          journal.proposedAssignments.allSatisfy({ $0.projectID == project.id && $0.target == journal.target }),
          Set(journal.steps.map(\.destinationPath)).count == journal.steps.count else {
      throw ProjectInstallFailure.unsafe("The pending project's assignments or destinations are inconsistent.")
    }
    try validateProjectAssignments(journal.previousAssignments)
    try validateProjectAssignments(journal.proposedAssignments)
    if case .removeSkill(let id) = journal.intent ?? .reconcile {
      guard journal.proposedAssignments == removingProjectSkill(id, from: journal.previousAssignments,
        projectID: project.id, target: journal.target),
        journal.steps.allSatisfy({ $0.skillID == id && $0.operation == .remove && $0.sourcePath == nil
          && $0.stagePath == nil && $0.stageIdentity == nil && $0.expectedFingerprint == nil && $0.newReceipt == nil }) else {
        throw ProjectInstallFailure.unsafe("The pending skill removal exceeds its selected skill or changes other assignments.")
      }
    }
    let desired = journal.proposedAssignments.reduce(into: Set<Skill.ID>()) { $0.formUnion($1.members) }
    for step in journal.steps {
      guard step.operation == .remove ? !desired.contains(step.skillID) : desired.contains(step.skillID) else {
        throw ProjectInstallFailure.unsafe("The pending operation does not match its assignment membership.")
      }
      guard step.destinationPath == (try projectDestination(step.skillID, project: project, target: journal.target)).path else {
        throw ProjectInstallFailure.unsafe("The pending operation points outside its authorized skill folder.")
      }
      if let receipt = step.previousReceipt {
        try validateProjectReceipt(receipt, project: project, target: journal.target)
        guard receipt.skillID == step.skillID else { throw ProjectInstallFailure.unsafe("The pending receipt's skill differs from its operation.") }
      }
      if let receipt = step.newReceipt {
        try validateProjectReceipt(receipt, project: project, target: journal.target)
        guard receipt.skillID == step.skillID, receipt.directoryIdentity == step.stageIdentity,
              receipt.installedFingerprint == step.expectedFingerprint, receipt.sourcePath == step.sourcePath else {
          throw ProjectInstallFailure.unsafe("The pending staging receipt is inconsistent.")
        }
      }
      if let path = step.stagePath {
        let stage = URL(fileURLWithPath: path)
        guard stage.deletingLastPathComponent().path == journal.target.url(in: project).path,
              stage.lastPathComponent.hasPrefix(".skillscout-stage-"),
              UUID(uuidString: String(stage.lastPathComponent.dropFirst(".skillscout-stage-".count))) != nil else {
          throw ProjectInstallFailure.unsafe("The pending staging directory is outside its authorized target.")
        }
      }
      guard step.operation != .replace || step.previousReceipt != nil,
            step.operation != .remove || step.previousReceipt != nil else {
        throw ProjectInstallFailure.unsafe("The pending operation is missing its previous ownership receipt.")
      }
    }
  }

  private static func validateProjectPath(_ project: RegisteredProject, target: ProjectSkillTarget) throws {
    guard ProjectLibrary.status(of: project) == .available else {
      throw ProjectInstallFailure.unsafe("The registered project folder is missing or was replaced. No project skills were changed.")
    }
    var current = project.url
    for component in target.relativePath.split(separator: "/") {
      current.append(path: String(component))
      guard projectExists(current) else { continue }
      let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory,
            current.resolvingSymlinksInPath().path == current.path else {
        throw ProjectInstallFailure.unsafe("A project skill-folder ancestor is a symlink or non-directory: \(current.path)")
      }
    }
  }

  private static func ensureProjectTarget(_ project: RegisteredProject, target: ProjectSkillTarget) throws {
    var current = project.url
    for component in target.relativePath.split(separator: "/") {
      try validateProjectPath(project, target: target)
      current.append(path: String(component))
      if !projectExists(current) { try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false) }
    }
    try validateProjectPath(project, target: target)
  }

  private static func projectAncestorSignature(_ project: RegisteredProject, target: ProjectSkillTarget) throws -> String {
    var current = project.url
    var parts = [try projectObservation(current, contents: false)]
    for component in target.relativePath.split(separator: "/") {
      current.append(path: String(component))
      parts.append(try projectObservation(current, contents: false))
    }
    return parts.joined(separator: "|")
  }

  private static func projectObservation(_ url: URL, contents: Bool = true) throws -> String {
    guard projectExists(url) else { return "\(url.path):missing" }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let type = (attributes[.type] as? FileAttributeType)?.rawValue ?? "unknown"
    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
    let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
    let content = contents ? (try? projectFingerprint(url)) ?? "unreadable" : ""
    return "\(url.path):\(type):\(device):\(inode):\(mode):\(content)"
  }

  static func projectEntryUnchanged(_ entry: ProjectSkillEntry) -> Bool {
    let url = URL(fileURLWithPath: entry.path)
    return (try? ProjectDirectoryIdentity.read(at: url)) == entry.directoryIdentity
      && (try? projectFingerprint(url)) == entry.installedFingerprint
  }

  private static func projectExists(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
  }

  static func projectFingerprint(_ folder: URL, requirePortableLinks: Bool = false) throws -> String {
    let fm = FileManager.default
    let root = folder.standardizedFileURL
    guard (try fm.attributesOfItem(atPath: root.path))[.type] as? FileAttributeType == .typeDirectory else {
      throw ProjectInstallFailure.unsafe("A project skill copy must be a real directory: \(root.path)")
    }
    var hash = SHA256()
    func field(_ value: String) {
      let bytes = Data(value.utf8)
      hash.update(data: Data("\(bytes.count):".utf8))
      hash.update(data: bytes)
    }
    func visit(_ url: URL, relative: String) throws {
      let attrs = try fm.attributesOfItem(atPath: url.path)
      guard let type = attrs[.type] as? FileAttributeType,
            let mode = attrs[.posixPermissions] as? NSNumber else {
        throw ProjectInstallFailure.unsafe("Cannot inspect a source entry: \(url.path)")
      }
      field(relative); field(type.rawValue); field(mode.stringValue)
      switch type {
      case .typeDirectory:
        for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
          if relative.isEmpty && child.lastPathComponent == RepositoryLibrary.upstreamMarkerName { continue }
          try visit(child, relative: relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent)
        }
      case .typeRegular:
        var fileHash = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty { fileHash.update(data: chunk) }
        field(fileHash.finalize().map { String(format: "%02x", $0) }.joined())
      case .typeSymbolicLink:
        let link = try fm.destinationOfSymbolicLink(atPath: url.path)
        if requirePortableLinks {
          let destination = URL(fileURLWithPath: link, relativeTo: url.deletingLastPathComponent()).standardizedFileURL.resolvingSymlinksInPath()
          guard !link.hasPrefix("/"), destination.path.hasPrefix(root.path + "/") || destination.path == root.path else {
            throw ProjectInstallFailure.unsafe("Its supporting link escapes the skill folder: \(relative)")
          }
        }
        field(link)
      default: throw ProjectInstallFailure.unsafe("Unsupported source entry type at \(url.path)")
      }
    }
    try visit(root, relative: "")
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func copyProjectTree(_ source: URL, into stage: URL) throws {
    let fm = FileManager.default
    for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
      if child.lastPathComponent == RepositoryLibrary.upstreamMarkerName { continue }
      try fm.copyItem(at: child, to: stage.appending(path: child.lastPathComponent))
    }
    let attributes = try fm.attributesOfItem(atPath: source.path)
    if let mode = attributes[.posixPermissions] { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: stage.path) }
  }
}
