import Foundation

struct SkillsetStatus {
  let assigned: Bool
  let pending: Bool
  let available: Int
  let total: Int
  let missing: [String]
  let inherited: [String]

  var label: String {
    let state = assigned ? (pending ? "Changes pending" : available == total ? "Assigned" : "Assigned · Incomplete") : "Not assigned"
    return "\(state) · \(available)/\(total) available"
  }
}

extension AppStore {
  func assignment(for skillsetID: UUID, to tool: Tool) -> SkillsetAssignment? {
    skillsetAssignments.first { $0.skillsetID == skillsetID && $0.tool == tool }
  }

  func skillsetStatus(_ skillset: Skillset, to tool: Tool) -> SkillsetStatus {
    let assigned = assignment(for: skillset.id, to: tool)
    let members = skillset.skills.sorted()
    let available = members.filter { id in skill(id)?.availableIn.contains(tool) == true }
    let inherited = available.compactMap { id -> String? in
      guard let provider = skill(id)?.provider(for: tool), provider.root.url != tool.skillsFolder else { return nil }
      return "\(id) is available through \(Paths.abbreviate(provider.root.url)). Unassigning may leave it available."
    }
    return SkillsetStatus(assigned: assigned != nil, pending: assigned.map { $0.members != skillset.skills } ?? false,
      available: available.count, total: members.count, missing: members.filter { skill($0) == nil }, inherited: inherited)
  }

  func setSkillMembership(_ ids: Set<Skill.ID>, in skillsetID: UUID, included: Bool) {
    guard !isManagingSkillsets, let index = skillsets.firstIndex(where: { $0.id == skillsetID }) else { return }
    var members = skillsets[index].skills
    if included { members.formUnion(ids) } else { members.subtract(ids) }
    replaceSkillsetMembers(members, in: skillsetID)
  }

  @discardableResult
  func replaceSkillsetMembers(_ members: Set<Skill.ID>, in skillsetID: UUID) -> Bool {
    guard !isManagingSkillsets, let index = skillsets.firstIndex(where: { $0.id == skillsetID }) else { return false }
    let previous = skillsets[index].skills
    skillsets[index].skills = members
    if !saveState() { skillsets[index].skills = previous; return false }
    return true
  }

  private func proposedAssignments(_ skillset: Skillset, to tool: Tool, assigned: Bool) -> [SkillsetAssignment] {
    var proposed = skillsetAssignments.filter { !($0.skillsetID == skillset.id && $0.tool == tool) }
    if assigned { proposed.append(SkillsetAssignment(skillsetID: skillset.id, tool: tool, members: skillset.skills)) }
    return proposed
  }

  func skillsetPreview(_ skillset: Skillset, to tool: Tool, assigned: Bool) -> SkillsetPlan {
    SkillInstaller.skillsetPlan(tool: tool, assignments: proposedAssignments(skillset, to: tool, assigned: assigned),
      entries: skillsetEntries, skills: skills, preferredSources: preferredSources)
  }

  @discardableResult
  func applySkillset(id: UUID, to tool: Tool, assigned: Bool = true) async -> [URL] {
    guard !isManagingSkillsets, let skillset = skillsets.first(where: { $0.id == id }) else { return [] }
    let previous = skillsetAssignments
    skillsetAssignments = proposedAssignments(skillset, to: tool, assigned: assigned)
    guard saveState() else { skillsetAssignments = previous; return [] }
    return await reconcileSkillsets(for: tool)
  }

  @discardableResult
  func reconcileSkillsets(for tool: Tool) async -> [URL] {
    guard !isManagingSkillsets else { return [] }
    isManagingSkillsets = true
    defer { isManagingSkillsets = false }
    await refreshSkills()
    let plan = SkillInstaller.skillsetPlan(tool: tool, assignments: skillsetAssignments, entries: skillsetEntries, skills: skills, preferredSources: preferredSources)
    var issues = plan.issues
    var notes: [String] = []
    var trashed: [URL] = []
    for skill in plan.additions {
      do {
        let entry = try SkillInstaller.addForSkillset(skill, to: tool, preferredSources: preferredSources)
        // Replace an old receipt if an externally removed entry was recreated.
        skillsetEntries.removeAll { $0.path == entry.path }
        skillsetEntries.append(entry)
        guard saveState() else {
          skillsetIssues[tool.rawValue] = issues + ["Stopped: ownership could not be saved."]
          await refreshSkills()
          return trashed
        }
      } catch {
        issues.append("\(skill.name): \(error.localizedDescription)")
      }
    }
    for entry in plan.removals {
      do {
        let result = try SkillInstaller.removeSkillsetEntry(entry, entries: skillsetEntries, skills: skills)
        trashed += result.trashed
        if let note = result.note { notes.append(note) }
        skillsetEntries.removeAll { $0 == entry }
        guard saveState() else {
          skillsetIssues[tool.rawValue] = issues + ["Stopped: ownership could not be saved."]
          await refreshSkills()
          return trashed
        }
      } catch {
        issues.append("\(entry.skillID): \(error.localizedDescription)")
      }
    }
    skillsetIssues[tool.rawValue] = issues
    skillsetNotes[tool.rawValue] = notes
    saveState()
    await refreshSkills()
    return trashed
  }

  @discardableResult
  func deleteSkillset(id: UUID) async -> [URL] {
    guard !isManagingSkillsets else { return [] }
    let previousSets = skillsets
    let previousAssignments = skillsetAssignments
    let affected = Set(skillsetAssignments.filter { $0.skillsetID == id }.map(\.tool))
    skillsetAssignments.removeAll { $0.skillsetID == id }
    skillsets.removeAll { $0.id == id }
    guard saveState() else {
      skillsets = previousSets
      skillsetAssignments = previousAssignments
      return []
    }
    var trashed: [URL] = []
    for tool in Tool.allCases where affected.contains(tool) { trashed += await reconcileSkillsets(for: tool) }
    return trashed
  }
}
