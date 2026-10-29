import SwiftUI

struct SkillsetHeader: View {
  let skillsetID: UUID
  @Environment(AppStore.self) private var store
  @State private var showingEditor = false
  @State private var showingAssignments = false

  var body: some View {
    if let skillset = store.skillsets.first(where: { $0.id == skillsetID }) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
          Text(skillset.name).font(.headline).lineLimit(1)
          if store.isManagingSkillsets { ProgressView().controlSize(.small) }
          Spacer()
          Button("Edit…") { showingEditor = true }
            .help("Edit skills in \(skillset.name)")
            .accessibilityLabel("Edit skills in \(skillset.name)")
            .disabled(store.isManagingSkillsets)
        }
        let assigned = store.tools.filter { store.assignment(for: skillset.id, to: $0) != nil }
        let incomplete = assigned.count { store.skillsetStatus(skillset, to: $0).available < skillset.skills.count }
        HStack(spacing: 10) {
          Text("\(skillset.skills.count) skills · \(assigned.count) assigned")
            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
          if incomplete > 0 {
            Label("\(incomplete) need attention", systemImage: "exclamationmark.triangle")
              .font(.caption).foregroundStyle(.orange)
          }
          Spacer(minLength: 0)
          Button("Install skillset…") { store.pendingSkillAdd = SkillAddPresentation(skillsetID: skillsetID) }
            .help("Add this skillset to Global or a project for \(skillset.name)")
            .accessibilityLabel("Manage tool assignments for \(skillset.name)")
        }
        if store.skillsetAssignments.contains(where: { $0.skillsetID == skillset.id && !store.tools.contains($0.tool) }) {
          Text("Assignments for disabled tools are retained. Enable those tools in Settings to manage them.").font(.caption).foregroundStyle(.secondary)
        }
        let missing = skillset.skills.filter { store.skill($0) == nil }.sorted()
        if !missing.isEmpty {
          DisclosureGroup("\(missing.count) missing sources") {
            ForEach(missing, id: \.self) { id in
              HStack {
                Label(id, systemImage: "exclamationmark.triangle")
                Spacer()
                Button("Remove from skillset") { store.setSkillMembership([id], in: skillset.id, included: false) }
                  .accessibilityLabel("Remove \(id) from \(skillset.name)")
              }
            }
          }
          .font(.caption)
        }
      }
      .padding(12)
      .background(.regularMaterial)
      .sheet(isPresented: $showingEditor) { SkillsetEditor(skillset: skillset) }
      .sheet(isPresented: $showingAssignments) { SkillsetAssignmentsSheet(skillsetID: skillsetID) }
    }
  }
}

struct ToolSkillsetsView: View {
  let tool: Tool
  @Environment(AppStore.self) private var store
  @State private var showingAssignments = false

  var body: some View {
    HStack(spacing: 10) {
      let assigned = store.skillsets.count { store.assignment(for: $0.id, to: tool) != nil }
      Text("\(assigned) of \(store.skillsets.count) skillsets assigned")
        .font(.callout).foregroundStyle(.secondary)
      let issueCount = (store.skillsetIssues[tool.rawValue] ?? []).count
      if issueCount > 0 {
        Label("\(issueCount) issues", systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
      }
      Spacer(minLength: 0)
      Button("Manage…") { showingAssignments = true }
        .help("Manage skillsets for \(tool.name)")
        .accessibilityLabel("Manage skillsets for \(tool.name)")
    }
    .padding(12)
    .background(.regularMaterial)
    .sheet(isPresented: $showingAssignments) { SkillsetAssignmentsSheet(tool: tool) }
  }
}

struct ProjectSkillsetsView: View {
  let project: RegisteredProject
  var tool: Tool?
  @Environment(AppStore.self) private var store
  @State private var showingAssignments = false

  var body: some View {
    HStack(spacing: 10) {
      let assigned = Set(store.projectState.assignments.filter { assignment in
        assignment.projectID == project.id && assignment.individualSkillID == nil && !assignment.target.readBy.intersection(store.tools).isEmpty
          && (tool.map(assignment.target.readBy.contains) ?? true)
          && store.skillsets.contains(where: { $0.id == assignment.skillsetID })
      }.map(\.skillsetID)).count
      Text("\(assigned) of \(store.skillsets.count) skillsets assigned").font(.callout).foregroundStyle(.secondary)
      Spacer(minLength: 0)
      Button("Manage…") { showingAssignments = true }
        .fixedSize()
        .help("Manage skillsets for \(project.name)")
        .accessibilityLabel("Manage skillsets for \(project.name)")
        .accessibilityIdentifier("project-manage-skillsets")
    }
    .sheet(isPresented: $showingAssignments) { SkillsetAssignmentsSheet(tool: tool, project: project) }
  }
}

struct SkillsetAssignmentsSheet: View {
  var skillsetID: UUID?
  var tool: Tool?
  var project: RegisteredProject? = nil
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var projectTarget: ProjectSkillTarget = .shared
  @State private var applying: ProjectApplyRequest?

  private var projectTargets: [ProjectSkillTarget] {
    ProjectSkillTarget.allCases.filter { target in
      !target.readBy.intersection(store.tools).isEmpty && (tool.map { store.tools.contains($0) && target.readBy.contains($0) } ?? true)
    }
  }
  private var projectAssignments: [ProjectSkillsetAssignment] {
    store.projectState.assignments.filter { $0.projectID == project?.id && $0.individualSkillID == nil && (skillsetID == nil || $0.skillsetID == skillsetID) }
  }
  private var canManageProject: Bool {
    guard let project else { return false }
    return store.projectInventories[project.id]?.status.isAvailable == true && store.projectState.pending == nil
      && !store.isManagingProjects && !store.isManagingSkillsets && projectTargets.contains(projectTarget)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(skillsetID.flatMap { id in store.skillsets.first(where: { $0.id == id })?.name }.map { "Assign \($0) to \(project?.name ?? "Global")" }
        ?? "Skillsets for \(tool?.name ?? (project == nil ? "tool" : "enabled agents"))")
        .font(.title2.weight(.semibold))
      if store.tools.isEmpty { Text("Enable a tool in Settings to manage assignments.").font(.caption).foregroundStyle(.secondary) }
      if let project {
        projectContext(project)
      } else if store.skillsetAssignments.contains(where: { (skillsetID == nil || $0.skillsetID == skillsetID) && !store.tools.contains($0.tool) }) {
        Text("Assignments for disabled tools are retained. Enable those tools in Settings to manage them.").font(.caption).foregroundStyle(.secondary)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if project != nil {
            projectRows
          } else if let skillsetID {
            ForEach(store.tools.filter { tool == nil || $0 == tool }) { candidate in
              SkillsetAssignmentView(skillsetID: skillsetID, tool: candidate)
              Divider()
            }
            ForEach(store.tools.filter { tool == nil || $0 == tool }) { candidate in
              toolMessages(candidate)
            }
          } else if let tool, store.tools.contains(tool) {
            ForEach(store.skillsets) { skillset in
              SkillsetAssignmentView(skillsetID: skillset.id, tool: tool, showSkillsetName: true)
              Divider()
            }
            toolMessages(tool)
          }
        }
      }
      HStack {
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(width: 620, height: 560)
    .onAppear { normalizeProjectTarget(preferDefault: true) }
    .onChange(of: store.tools) {
      normalizeProjectTarget()
      if let applying, !projectTargets.contains(applying.target) { self.applying = nil }
    }
    .sheet(item: $applying) { request in
      if let project { ProjectApplySheet(project: project, request: request) }
    }
  }

  @ViewBuilder private func projectContext(_ project: RegisteredProject) -> some View {
    Text(project.name).font(.headline)
    Text(Paths.abbreviate(project.url)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    if projectTargets.isEmpty {
      Text("Enable a compatible tool in Settings to manage this project's assignments.").font(.caption).foregroundStyle(.secondary)
    } else {
      ChoiceChips(title: "Agent group", options: projectTargets.map {
        ChoiceOption(value: $0, title: $0.label)
      }, selection: $projectTarget)
      Text(projectTarget.relativePath).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
      ProjectReaderBadges(tools: projectTarget.readBy)
      DisabledReaderNotice(readers: projectTarget.readBy)
    }
    if projectAssignments.contains(where: { $0.target.readBy.intersection(store.tools).isEmpty }) {
      Text("Assignments for disabled tools are retained. Enable those tools in Settings to manage them.").font(.caption).foregroundStyle(.secondary)
    }
    if let inventory = store.projectInventories[project.id], !inventory.status.isAvailable {
      Text(inventory.status.label).font(.caption).foregroundStyle(.orange)
    }
    if store.projectState.pending != nil {
      Text("A project operation needs recovery. Complete recovery in the project overview before managing assignments.").font(.caption).foregroundStyle(.orange)
    }
  }

  @ViewBuilder private var projectRows: some View {
    if projectTargets.contains(projectTarget) {
      let skillsets = store.skillsets.filter { skillsetID == nil || $0.id == skillsetID }
      ForEach(skillsets) { skillset in
        projectRow(skillsetID: skillset.id)
        Divider()
      }
      ForEach(projectAssignments.filter { assignment in
        assignment.target == projectTarget && !store.skillsets.contains(where: { $0.id == assignment.skillsetID })
      }, id: \.skillsetID) { assignment in
        projectRow(skillsetID: assignment.skillsetID)
        Divider()
      }
      if skillsets.isEmpty && !projectAssignments.contains(where: { $0.target == projectTarget }) {
        Text("No skillsets available. Create a skillset in the sidebar to apply it here.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 10)
      }
    }
  }

  private func projectRow(skillsetID id: UUID) -> some View {
    let skillset = store.skillsets.first { $0.id == id }
    let assignment = projectAssignments.first { $0.skillsetID == id && $0.target == projectTarget }
    let pending = skillset.map { assignment != nil && $0.skills != assignment?.members } ?? false
    let status = pending ? "Changes pending" : assignment != nil ? "Assigned" : "Not assigned"
    let action = pending ? "Apply changes" : assignment != nil ? "Review" : "Apply"
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 12) {
        Label(skillset?.name ?? "Deleted skillset", systemImage: "folder")
          .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
        Text(status).font(.caption).foregroundStyle(pending ? Color.orange : Color.secondary)
        if let skillset {
          Button("\(action)…") {
            guard canManageProject else { return }
            applying = ProjectApplyRequest(skillsetID: id, target: projectTarget)
          }
          .accessibilityIdentifier("project-skillset-apply-\(id.uuidString)")
          .accessibilityLabel("\(action) \(skillset.name) for \(project?.name ?? "project")")
          .disabled(!canManageProject || skillset.skills.isEmpty)
        }
        if assignment != nil {
          Button("Unassign…", role: .destructive) {
            guard canManageProject else { return }
            applying = ProjectApplyRequest(skillsetID: id, target: projectTarget, unassign: true)
          }
          .accessibilityIdentifier("project-skillset-unassign-\(id.uuidString)")
          .accessibilityLabel("Unassign \(skillset?.name ?? "deleted skillset") from \(project?.name ?? "project")")
          .disabled(!canManageProject)
        }
      }.controlSize(.small)
      Text("\(skillset?.skills.count ?? assignment?.members.count ?? 0) skills\(assignment.map { " · \($0.members.count) applied" } ?? "")")
        .font(.caption).foregroundStyle(.secondary)
      if skillset == nil {
        Text("The membership snapshot is retained. Files stay in place until you unassign this skillset.").font(.caption).foregroundStyle(.orange)
      }
    }.padding(.vertical, 10)
  }

  private func normalizeProjectTarget(preferDefault: Bool = false) {
    guard project != nil else { return }
    let preferred: ProjectSkillTarget = tool == .claude ? .claude : .shared
    if preferDefault, projectTargets.contains(preferred) { projectTarget = preferred }
    else if !projectTargets.contains(projectTarget), let first = projectTargets.first { projectTarget = first }
  }

  @ViewBuilder
  private func toolMessages(_ tool: Tool) -> some View {
    let issues = store.skillsetIssues[tool.rawValue] ?? []
    let notes = store.skillsetNotes[tool.rawValue] ?? []
    if !issues.isEmpty || !notes.isEmpty {
      DisclosureGroup("\(tool.name): \(issues.count) issues, \(notes.count) notes") {
        ForEach(issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
        ForEach(notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        if !issues.isEmpty {
          Button("Retry changes for \(tool.name)") { Task { await store.reconcileSkillsets(for: tool) } }
            .disabled(store.isManagingSkillsets)
        }
      }
      .font(.caption)
      .padding(.vertical, 8)
    }
  }
}

struct SkillsetAssignmentView: View {
  let skillsetID: UUID
  let tool: Tool
  var showSkillsetName = false
  @Environment(AppStore.self) private var store
  @State private var showingPreview = false
  @State private var proposedAssignment = true

  var body: some View {
    if store.tools.contains(tool), let skillset = store.skillsets.first(where: { $0.id == skillsetID }) {
      let status = store.skillsetStatus(skillset, to: tool)
      let action = status.pending ? "Apply changes" : status.assigned ? ((store.skillsetIssues[tool.rawValue] ?? []).isEmpty && status.available == status.total ? "Review" : "Retry") : "Apply"
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 12) {
          Label(showSkillsetName ? skillset.name : tool.name, systemImage: showSkillsetName ? "folder" : tool.symbol)
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(status.label)
            .font(.caption)
            .foregroundStyle(status.pending || (status.assigned && status.available < status.total) ? .orange : .secondary)
            .lineLimit(1)
          Button("\(action)…") {
            proposedAssignment = true
            showingPreview = true
          }
          .accessibilityLabel("\(action) \(skillset.name) for \(tool.name)")
          .disabled(!status.assigned && skillset.skills.isEmpty)
          if status.assigned {
            Menu {
              Button("Unassign…", role: .destructive) {
                proposedAssignment = false
                showingPreview = true
              }
              .accessibilityLabel("Unassign \(skillset.name) from \(tool.name)")
            } label: {
              Label("More actions", systemImage: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("More actions for \(skillset.name) in \(tool.name)")
          }
        }
        .controlSize(.small)
        if !status.inherited.isEmpty {
          Text(status.inherited.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 10)
      .disabled(store.isManagingSkillsets)
      .sheet(isPresented: $showingPreview) {
        SkillsetPreview(skillsetID: skillsetID, tool: tool, assigned: proposedAssignment)
      }
    }
  }

}

struct SkillsetPreview: View {
  let skillsetID: UUID
  let tool: Tool
  let assigned: Bool
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var inspecting: SkillCopy?
  @State private var choosingVersions: Skill?

  var body: some View {
    if store.tools.contains(tool), let skillset = store.skillsets.first(where: { $0.id == skillsetID }) {
      let plan = store.skillsetPreview(skillset, to: tool, assigned: assigned)
      let reviews = plan.additions.reduce(into: [Skill.ID: SkillReview]()) { $0[$1.id] = additionReview($1) }
      let affected = SkillRoot.containing(tool.skillsFolder)?.readBy ?? [tool]
      VStack(alignment: .leading, spacing: 16) {
        Text("\(assigned ? "Apply" : "Unassign") \(skillset.name) \(assigned ? "to" : "from") \(tool.name)")
          .font(.headline)
        Text("Add \(plan.additions.count) · Keep \(plan.kept) existing · Remove up to \(plan.removals.count)"
          + (plan.skipped.isEmpty ? "" : " · Skip \(plan.skipped.count)"))
        Text("Affected agents: \(store.tools.filter(affected.contains).map(\.name).formatted())")
          .font(.caption).foregroundStyle(.secondary)
        DisabledReaderNotice(readers: Set(affected))
        Text("Other assigned skillsets keep the skills they need. Existing personal installations and modified copies stay.")
          .font(.callout).foregroundStyle(.secondary)
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(plan.additions) { skill in
              if let review = reviews[skill.id] {
                Label("Add \(skill.name): \(review.summary.lowercased())", systemImage: "exclamationmark.triangle")
                  .foregroundStyle(.orange)
                  .help("Read this source's contents before applying.")
                if let source = SkillInstaller.skillsetSource(skill, for: tool, preferences: store.sourcePreferences) {
                  Button("Inspect \(skill.name) contents") { inspecting = source }
                }
              } else {
                Label("Add \(skill.name)", systemImage: "plus")
              }
            }
            ForEach(plan.removals, id: \.path) { Label("Remove \($0.skillID)", systemImage: "minus") }
            ForEach(plan.skipped, id: \.self) { Label("Skip \($0): this agent is set to skip it", systemImage: "forward") }
            ForEach(plan.issueDetails) { issue in
              VStack(alignment: .leading, spacing: 6) {
                Label(issue.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                recovery(for: issue, skillset: skillset)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        if !plan.issues.isEmpty {
          Text("Available changes can be applied now. Unresolved items remain visible for retry.").font(.caption)
        }
        if !reviews.isEmpty {
          Text("Skills marked in orange have scripts or high-risk commands. Read their Contents before applying.")
            .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Spacer()
          Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
          Button(assigned ? "Apply" : "Unassign") {
            Task {
              guard store.tools.contains(tool) else { return }
              await store.applySkillset(id: skillset.id, to: tool, assigned: assigned)
              dismiss()
            }
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
        }
      }
      .padding(24)
      .frame(width: 540)
      .disabled(store.isManagingSkillsets)
      .interactiveDismissDisabled(store.isManagingSkillsets)
      .sheet(item: $inspecting) { SkillContentsSheet(source: $0) }
      .sheet(item: $choosingVersions) { SkillVersionPicker(skill: $0) }
    } else {
      VStack(alignment: .leading, spacing: 12) {
        Text("This destination is disabled. Enable it in Settings and open a new preview.")
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      }.padding(24).frame(width: 540)
    }
  }

  @ViewBuilder private func recovery(for issue: SkillsetIssue, skillset: Skillset) -> some View {
    switch issue.reason {
    case .missingSource:
      if skillset.skills.contains(issue.skillID) {
        Button("Remove missing member") { store.setSkillMembership([issue.skillID], in: skillset.id, included: false) }
      }
    case .chooseSource:
      if let skill = store.skill(issue.skillID) {
        let sources = SkillInstaller.installableSources(for: skill)
        ChoiceAction(title: "Choose source", options: sources.map {
          ChoiceOption(value: $0.resolved.path, title: $0.sourceLabel, detail: $0.visiblePath, symbol: "folder")
        }) { path in
          if let source = sources.first(where: { $0.resolved.path == path }) {
            _ = store.setPreferredSource(source, for: skill)
          }
        }
      }
    case .chooseVersions, .versionConflict:
      if let skill = store.skill(issue.skillID), SkillVersions.versions(of: skill).count > 1 {
        Button("Choose versions…") { choosingVersions = skill }
      }
    case .existingVersions(_, let folders):
      Button("Show conflicting copies") { Finder.reveal(folders) }
        .help("Move one copy to Trash or make the copies match. Choosing versions can't change copies that are already installed.")
    case .differentContent(let folder), .destination(let folder):
      Button("Open existing copy") { Finder.reveal(folder) }
    case .builtIn:
      Text("Use this skill in its original tool, or choose an installable skill.").font(.caption).foregroundStyle(.secondary)
    }
  }

  /// The review of an addition's source when it comes from a downloaded repository and needs a look.
  private func additionReview(_ skill: Skill) -> SkillReview? {
    guard let source = SkillInstaller.skillsetSource(skill, for: tool, preferences: store.sourcePreferences),
          SkillInstaller.isFromLibrary(source) else { return nil }
    let review = SkillReview.inspect(source.resolved)
    return review.needsReview ? review : nil
  }
}

/// Which version of a skill each enabled agent gets. An agent that reads another agent's skills folder takes that
/// agent's version, and a choice that would still leave an agent reading two versions can't be saved.
struct SkillVersionPicker: View {
  let skill: Skill
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var choice = VersionChoice()
  @State private var inspecting: SkillCopy?
  @State private var saveFailed = false

  private enum Pick: Hashable { case later, skip, version(Int) }

  var body: some View {
    let versions = SkillVersions.versions(of: skill)
    let titles = SkillVersions.titles(for: skill)
    let resolved = SkillVersions.resolve(choice)
    let problems = SkillVersions.choiceProblems(for: skill, choice: choice, skills: store.skills)
    let installed = SkillVersions.installedVersions(of: skill)
    VStack(alignment: .leading, spacing: 14) {
      Text("Choose versions of \(skill.name)").font(.headline)
      Text("Each agent reads one version. An agent that reads another agent's folder gets the same one.")
        .font(.callout).foregroundStyle(.secondary)
      ForEach(versions.indices, id: \.self) { index in
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 2) {
            Text("\(index + 1). \(titles[index])")
            Text("\(versions[index][0].sourceLabel) · \(Paths.abbreviate(versions[index][0].resolved))")
              .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          }
          Spacer()
          Button("Show contents") { inspecting = versions[index][0] }.controlSize(.small)
        }
      }
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(store.tools, id: \.self) { tool in
            VStack(alignment: .leading, spacing: 4) {
              if let leaders = resolved[tool]?.follows, !leaders.isEmpty {
                Text(tool.name).font(.caption).foregroundStyle(.secondary)
                Text(followText(leaders, version: resolved[tool]?.version, titles: titles)).font(.callout)
              } else {
                SearchChoice(title: tool.name, options: options(titles), selection: pick(tool))
              }
              if let reading = installed[tool], let version = resolved[tool]?.version, !reading.contains(version) {
                Text("Already reads \(reading.sorted().map { "version \($0 + 1)" }.formatted()), which stays until you change that copy.")
                  .font(.caption).foregroundStyle(.secondary)
              }
              ForEach(problems[tool] ?? [], id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            }
          }
          let shown = Set(store.tools.flatMap { problems[$0] ?? [] })
          ForEach(Set(problems.values.joined()).subtracting(shown).sorted(), id: \.self) {
            Text($0).font(.caption).foregroundStyle(.red)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 320)
      if saveFailed { Text("Couldn't save these choices. Try again.").font(.callout).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save") { save(versions: versions, resolved: resolved) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!problems.isEmpty)
      }
    }
    .padding(24)
    .frame(width: 540)
    .onAppear { choice = initialChoice() }
    .sheet(item: $inspecting) { SkillContentsSheet(source: $0) }
  }

  /// "Decide later" means the shared preferred source when the skill has one, so the option says so.
  private func options(_ titles: [String]) -> [ChoiceOption<Pick>] {
    let later = choice.fallback.map { ChoiceOption(value: Pick.later, title: "Preferred source", detail: "\($0 + 1). \(titles[$0])") }
      ?? ChoiceOption(value: Pick.later, title: "Decide later", detail: "Applying asks again")
    return [later, ChoiceOption(value: .skip, title: "Skip", detail: "Skillsets leave this agent without it")]
      + titles.indices.map { ChoiceOption(value: Pick.version($0), title: "\($0 + 1). \(titles[$0])", symbol: "folder") }
  }

  private func pick(_ tool: Tool) -> Binding<Pick> {
    Binding(get: {
      if choice.skipped.contains(tool) { return .skip }
      return choice.own[tool].map(Pick.version) ?? .later
    }, set: { pick in
      choice.skipped.remove(tool)
      choice.own[tool] = nil
      switch pick {
      case .later: break
      case .skip: choice.skipped.insert(tool)
      case .version(let index): choice.own[tool] = index
      }
    })
  }

  private func followText(_ leaders: [Tool], version: Int?, titles: [String]) -> String {
    let folders = Set(leaders.map { Paths.abbreviate($0.skillsFolder) }).sorted().formatted()
    guard let version else { return "Reads \(folders), which get different versions" }
    return "Same as \(leaders.map(\.name).formatted()) (reads \(folders)): \(version + 1). \(titles[version])"
  }

  /// An agent that follows another saves nothing of its own, so it keeps following when that agent's choice changes.
  private func save(versions: [[SkillCopy]], resolved: [Tool: Resolution]) {
    let leading = store.tools.filter { resolved[$0]?.follows.isEmpty != false }
    let paths = Dictionary(uniqueKeysWithValues: leading.compactMap { tool in
      choice.own[tool].flatMap { versions.indices.contains($0) ? (tool, versions[$0][0].resolved.path) : nil }
    })
    if store.setAgentSources(paths, skipped: choice.skipped.intersection(leading), for: skill, tools: store.tools) {
      dismiss()
    } else {
      saveFailed = true
    }
  }

  /// Saved choices, with suggestions for the agents without one.
  private func initialChoice() -> VersionChoice {
    let saved = SkillVersions.savedChoice(for: skill, preferences: store.sourcePreferences)
    return SkillVersions.suggestedChoice(for: skill, tools: store.tools, skills: store.skills, keeping: saved)
  }
}

struct SkillsetEditor: View {
  let skillset: Skillset
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var search = ""
  @State private var members: Set<Skill.ID>

  init(skillset: Skillset) {
    self.skillset = skillset
    _name = State(initialValue: skillset.name)
    _members = State(initialValue: skillset.skills)
  }

  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var nameIssue: String? {
    if trimmedName.isEmpty { return "Enter a skillset name." }
    if trimmedName != skillset.name,
       store.skillsets.contains(where: { $0.id != skillset.id && $0.name.lowercased() == trimmedName.lowercased() }) {
      return "Another skillset already has this name."
    }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Edit skillset").font(.headline)
      Text("Name").font(.caption).foregroundStyle(.secondary)
      TextField("Skillset name", text: $name).textFieldStyle(.roundedBorder)
      if let nameIssue { Text(nameIssue).font(.caption).foregroundStyle(.orange) }
      TextField("Search skills and sources", text: $search).textFieldStyle(.roundedBorder)
      List {
        ForEach(store.skills.filter { skill in
          search.isEmpty || skill.name.localizedCaseInsensitiveContains(search)
            || skill.description.localizedCaseInsensitiveContains(search)
            || skill.copies.contains { $0.sourceLabel.localizedCaseInsensitiveContains(search) }
        }) { skill in
          let sources = SkillInstaller.installableSources(for: skill)
          Toggle(isOn: Binding(
            get: { members.contains(skill.id) },
            set: { included in
              if included { members.insert(skill.id) } else { members.remove(skill.id) }
            }
          )) {
            VStack(alignment: .leading, spacing: 3) {
              Text(skill.name).fontWeight(.medium)
              Text(skill.primary.sourceLabel).font(.caption).foregroundStyle(.secondary)
              Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
          }
          if sources.count > 1 {
            ChoiceAction(title: store.preferredSource(for: skill).map { "Source: \($0.sourceLabel)" } ?? "Choose source…",
              options: sources.map { ChoiceOption(value: $0, title: $0.sourceLabel, detail: $0.visiblePath, symbol: "folder") }) { source in
              store.setPreferredSource(source, for: skill)
            }
            .font(.caption)
          }
        }
        ForEach(skillset.skills.filter { store.skill($0) == nil }.sorted(), id: \.self) { id in
          Toggle("\(id) — source missing", isOn: Binding(
            get: { members.contains(id) },
            set: { included in
              if included { members.insert(id) } else { members.remove(id) }
            }
          ))
          .foregroundStyle(.orange)
        }
      }
      Text("\(members.count) selected. Assigned tools will show Apply changes when membership changes.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save changes") {
          if store.updateSkillset(skillset.id, name: name, members: members) { dismiss() }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(nameIssue != nil)
      }
    }
    .padding(20)
    .frame(width: 600, height: 560)
    .disabled(store.isManagingSkillsets)
  }
}
