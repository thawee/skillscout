import SwiftUI

extension ProjectFolderStatus {
  var label: String {
    switch self {
    case .available: "Folder available"
    case .missing: "Folder missing. Restore it at its registered path."
    case .replaced: "Folder changed. The registered directory was replaced. Forget it and register the new folder to manage it."
    case .unreadable(let message): "Folder unavailable. \(message)"
    }
  }

  var isAvailable: Bool { self == .available }
}

extension ProjectSkillTarget {
  var label: String { self == .shared ? "Shared agents" : "Compatible agents" }
}

struct ProjectListView: View {
  @Environment(AppStore.self) private var store
  @Binding var selection: UUID?
  let register: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Projects").font(.headline)
        Spacer()
        Button("Register project folder", systemImage: "plus", action: register)
          .labelStyle(.iconOnly).help("Register project folder")
      }.padding(12)
      Divider()
      if store.projectState.projects.isEmpty {
        Text("No projects registered yet.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
        Spacer()
      } else {
        List(selection: $selection) {
          ForEach(store.orderedProjects) { project in
            VStack(alignment: .leading, spacing: 5) {
              Text(project.name).font(.headline)
              Text(Paths.abbreviate(project.url)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
              let inventory = store.projectInventories[project.id]
              Text(inventory?.status.label ?? "Reading project skills…").font(.caption).foregroundStyle(inventory?.status.isAvailable == false ? Color.orange : Color.secondary)
              if let inventory, inventory.status.isAvailable {
                Text("\(inventory.skills.count { !$0.localTools.intersection(store.tools).isEmpty }) project skills").font(.caption).foregroundStyle(.secondary)
              }
            }.padding(.vertical, 5).tag(project.id)
          }
        }
      }
    }.navigationTitle("Projects")
  }
}

struct ProjectWelcomeView: View {
  let register: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Skills for a project", systemImage: "folder.badge.gearshape").font(.title2)
      Text("Register a project folder to see the skills available here. Add individual skills or a skillset to this project.")
      Text("Each registered folder is scanned at its known skill locations. Register nested projects separately. Agent settings and trust rules can affect which skills load.").foregroundStyle(.secondary)
      Button("Register project…", action: register).buttonStyle(.borderedProminent)
    }.padding(28).frame(maxWidth: 580, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct ProjectSkillListView: View {
  @Environment(AppStore.self) private var store
  let project: RegisteredProject
  @Binding var selection: String?
  @Binding var filter: ProjectSkillFilter
  var search: String = ""

  private var inventory: ProjectInventory? { store.projectInventories[project.id] }
  private var rows: [ProjectSkillRow] {
    (inventory?.skills ?? []).filter { !(filter.scope == .projectOnly ? $0.localTools : $0.availableIn).intersection(store.tools).isEmpty && filter.matches($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search)) }
  }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(project.name).font(.headline)
              Spacer()
              Button("Refresh project skills", systemImage: "arrow.clockwise") { Task { await store.refreshProjectInventories() } }
                .labelStyle(.iconOnly).help("Refresh project skills")
            }
            Text(Paths.abbreviate(project.url)).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            WrapLayout(spacing: 12) {
              Button("Add skills…") { store.pendingSkillAdd = SkillAddPresentation(destination: .project(project.id), tool: filter.tool) }
                .disabled(inventory?.status.isAvailable != true || store.projectState.pending != nil || store.isManagingProjects)
              Button("Project overview") { selection = nil }.buttonStyle(.link)
            }
            AgentChoices(tools: store.tools, allTitle: "All enabled agents", selection: $filter.tool)
            ProjectSkillsetsView(project: project, tool: filter.tool)
            ChoiceChips(title: "Show", options: [
              ChoiceOption(value: ProjectSkillScope.availableHere, title: "Available here"),
              ChoiceOption(value: ProjectSkillScope.projectOnly, title: "Project only")
            ], selection: $filter.scope)
            UsagePeriodPicker()
            Text(usageScopeLabel).font(.caption2).foregroundStyle(.secondary)
          }.padding(12)
        }.frame(maxHeight: min(340, geometry.size.height * 0.55))
        Divider()
        if let inventory, !inventory.status.isAvailable {
          ContentUnavailableView("Project unavailable", systemImage: "folder.badge.questionmark", description: Text(inventory.status.label))
        } else if store.tools.isEmpty {
          ContentUnavailableView {
            Label("No enabled tools", systemImage: "square.stack.3d.up")
          } description: {
            Text("Enable an AI tool in Settings to see skills available in this project.")
          } actions: {
            SettingsLink { Text("Open Settings") }
          }
        } else if rows.isEmpty {
          ContentUnavailableView {
            Label(filter == ProjectSkillFilter() && search.isEmpty ? "No skills available" : "No matching skills", systemImage: "square.stack.3d.up")
          } description: {
            Text("Add skills to this project or inherit installations from Global.")
          } actions: {
            if filter != ProjectSkillFilter() { Button("Reset filters") { filter = ProjectSkillFilter() } }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          let usage = store.projectUsage(project, tool: filter.tool)
          List(selection: $selection) {
            ForEach(rows) { row in
              VStack(alignment: .leading, spacing: 5) {
                HStack {
                  Text(row.name).fontWeight(.medium)
                  Spacer()
                  Text("\(usage[row.name]?.chats ?? 0) chats").font(.caption).foregroundStyle(.secondary)
                }
                Text(row.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 10) {
                  if row.localCopies.contains(where: { filter.tool.map($0.root.readBy.contains) ?? !$0.root.readBy.intersection(store.tools).isEmpty }) { Label("Project", systemImage: "folder") }
                  if filter.tool.map(row.globalTools.contains) ?? !row.globalTools.intersection(store.tools).isEmpty { Label("Inherited from Global", systemImage: "globe") }
                }.font(.caption2).foregroundStyle(.secondary)
              }.padding(.vertical, 4).tag(row.id)
            }
          }
        }
      }
    }.navigationTitle(project.name)
      .onChange(of: store.tools) { if let tool = filter.tool, !store.tools.contains(tool) { filter.tool = nil } }
      .onAppear { if let tool = filter.tool, !store.tools.contains(tool) { filter.tool = nil } }
      .onChange(of: rows.map(\.id)) { if let selection, !rows.contains(where: { $0.id == selection }) { self.selection = nil } }
  }

  private var usageScopeLabel: String {
    if let tool = filter.tool {
      return store.tools.contains(tool) ? "Chat counts for \(tool.name)" : "\(tool.name) history is disabled. Chat counts are zero."
    }
    return "Chat counts for enabled agents"
  }
}

struct ProjectDetailView: View {
  @Environment(AppStore.self) private var store
  let project: RegisteredProject
  var skillID: String?
  var filter = ProjectSkillFilter()
  var manageGlobal: (Skill.ID, Tool?) -> Void = { _, _ in }
  @State private var applying: ProjectApplyRequest?
  @State private var forgetting = false
  @State private var stoppingRecovery = false
  @State private var inspecting: ProjectContentsRequest?
  @State private var projectLock: [String: SkillsLockEntry] = [:]

  private var inventory: ProjectInventory? { store.projectInventories[project.id] }
  private var selectedSkill: ProjectSkillRow? { inventory?.skills.first { $0.id == skillID && !(filter.scope == .projectOnly ? $0.localTools : $0.availableIn).intersection(store.tools).isEmpty && filter.matches($0) } }
  private var assignments: [ProjectSkillsetAssignment] { store.projectState.assignments.filter { $0.projectID == project.id } }
  private var enabledTargets: [ProjectSkillTarget] { ProjectSkillTarget.allCases.filter { !$0.readBy.intersection(store.tools).isEmpty } }
  private var visibleAssignments: [ProjectSkillsetAssignment] { assignments.filter { enabledTargets.contains($0.target) } }
  private var canManage: Bool { inventory?.status.isAvailable == true && !store.isManagingProjects && !store.isManagingSkillsets && store.projectState.pending == nil }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 6) {
            Text(selectedSkill?.name ?? project.name).font(.title2.weight(.semibold))
            Text(Paths.abbreviate(project.url)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
          Spacer()
          Button("Show in Finder") { Finder.reveal(project.url) }
            .fixedSize(horizontal: true, vertical: false)
            .disabled(inventory?.status.isAvailable != true)
        }
        if let inventory, !inventory.status.isAvailable { Text(inventory.status.label).foregroundStyle(.orange) }
        if store.projectState.pending?.projectID == project.id {
          VStack(alignment: .leading, spacing: 8) {
            Text("A project operation needs recovery. Files remain protected until recovery completes.").foregroundStyle(.orange)
            HStack {
              Button("Retry recovery") { store.recoverProjects() }.disabled(store.isManagingProjects)
              Button("Keep files and stop recovery…") { stoppingRecovery = true }.disabled(store.isManagingProjects)
            }
          }
        }
        ForEach(store.projectIssues[project.id] ?? [], id: \.self) { Text($0).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
        if let notes = store.projectNotes[project.id], let first = notes.first {
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(first).font(.callout)
              Spacer()
              Button("Dismiss") { store.projectNotes[project.id] = nil }.buttonStyle(.link)
            }
            if notes.count > 1 {
              DisclosureGroup("Details (\(notes.count - 1))") {
                ForEach(notes.dropFirst(), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
              }.font(.caption)
            }
          }
          .padding(10).frame(maxWidth: .infinity, alignment: .leading)
          .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
        if let row = selectedSkill { skillDetail(row) }
        else { overview }
      }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }
    .task(id: [project.url.path] + (inventory?.skills.map(\.id) ?? [])) {
      let file = SkillsLock.projectFile(project.url)
      projectLock = await Task.detached { SkillsLock.entries(in: file) }.value
    }
    .sheet(item: $applying) { ProjectApplySheet(project: project, request: $0) }
    .sheet(item: $inspecting) { ProjectContentsSheet(request: $0) }
    .confirmationDialog("Stop project recovery and keep every file?", isPresented: $stoppingRecovery) {
      Button("Keep files and stop recovery") { store.abandonProjectRecovery() }
    } message: {
      Text("Copied files and staging folders will stay in place. Completed copies remain tracked where their ownership can be proved. Existing assignments stay unchanged and may be incomplete. Review the preserved paths before applying another preview.")
    }
    .confirmationDialog("Forget \(project.name)?", isPresented: $forgetting) {
      Button("Keep files and forget project", role: .destructive) { store.forgetProject(project.id) }
    } message: {
      Text("Every project file will stay in place. Quartermaster will stop tracking this folder and its installed copies. Unassign skillsets first if you want their unchanged copies moved to Trash.")
    }
  }

  @ViewBuilder private var overview: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Project skills").font(.headline)
      Text("Skills available here combine project copies and inherited Global installations. Choose Project only to manage this project’s copies. Chat counts follow the selected agent and period.").font(.callout).foregroundStyle(.secondary)
      HStack {
        Text("\(inventory?.skills.count { !$0.localTools.intersection(store.tools).isEmpty } ?? 0) project skills")
        Text("\(inventory?.skills.count { !$0.globalTools.intersection(store.tools).isEmpty } ?? 0) globally available")
      }.font(.caption)
    }
    Divider()
    if assignments.contains(where: { !enabledTargets.contains($0.target) }) {
      Text("Assignments for disabled tools are retained. Enable those tools in Settings to manage them.").font(.caption).foregroundStyle(.secondary)
    }
    let individualAssignments = visibleAssignments.filter { $0.individualSkillID != nil }
    if !individualAssignments.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text("Added individually").font(.headline)
        ForEach(individualAssignments, id: \.projectAssignmentID) { assignment in
          if let id = assignment.individualSkillID {
            VStack(alignment: .leading, spacing: 6) {
              Text(id).fontWeight(.medium)
              ProjectReaderBadges(tools: assignment.target.readBy)
              Button("Remove from project…") { applying = ProjectApplyRequest(target: assignment.target, removeSkillID: id) }.disabled(!canManage)
            }
          }
        }
      }
      Divider()
    }
    VStack(alignment: .leading, spacing: 12) {
      Text("Applied skillsets").font(.headline)
      if visibleAssignments.filter({ $0.individualSkillID == nil }).isEmpty { Text("No skillsets applied to this project.").font(.callout).foregroundStyle(.secondary) }
      ForEach(visibleAssignments.filter { $0.individualSkillID == nil }, id: \.projectAssignmentID) { assignment in
        let skillset = store.skillsets.first { $0.id == assignment.skillsetID }
        VStack(alignment: .leading, spacing: 7) {
          Text(skillset?.name ?? "Deleted skillset").fontWeight(.medium)
          Text("\(assignment.target.label) · \(assignment.members.count) skills").font(.caption).foregroundStyle(.secondary)
          ProjectReaderBadges(tools: assignment.target.readBy)
          Text(assignment.members.sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          if skillset == nil {
            Text("The membership snapshot is retained. Files stay in place until you unassign this skillset.").font(.caption).foregroundStyle(.orange)
          } else if skillset?.skills != assignment.members {
            Text("Skillset membership changed. Use Manage to review its current members.").font(.caption).foregroundStyle(.orange)
          }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
      }
    }
    Divider()
    DisclosureGroup("Scanned locations") {
      VStack(alignment: .leading, spacing: 10) {
        Text("Only native skill roots in this registered folder are scanned. Register nested projects separately. Tool settings and workspace trust can affect discovery.").font(.caption).foregroundStyle(.secondary)
      ForEach(ProjectSkillRoot.all.filter { !$0.readBy.intersection(store.tools).isEmpty }, id: \.relativePath) { root in
        VStack(alignment: .leading, spacing: 4) {
          Text(root.relativePath).font(.system(.caption, design: .monospaced))
          ProjectReaderBadges(tools: root.readBy)
        }
      }
      ForEach(inventory?.issues ?? []) { issue in
        Text("\(issue.path)\n\(issue.message)").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
      }
    }
    }
    Divider()
    Button("Forget project…", role: .destructive) { forgetting = true }.disabled(store.isManagingProjects || store.projectState.pending?.projectID == project.id)
  }

  @ViewBuilder private func skillDetail(_ row: ProjectSkillRow) -> some View {
    Text(row.description).foregroundStyle(.secondary)
    if !row.localCopies.isEmpty, let entry = SkillsLock.entry(named: row.name, folders: row.localCopies.map(\.folder), in: projectLock) {
      SkillsLockSourceRow(entry: entry)
    }
    VStack(alignment: .leading, spacing: 8) {
      Text("Project").font(.headline)
      let localReaders = filter.tool.map { row.localTools.intersection([$0]) } ?? row.localTools.intersection(store.tools)
      if localReaders.isEmpty { Text("No project copy available to this agent.").font(.callout).foregroundStyle(.secondary) }
      else { ProjectReaderBadges(tools: localReaders) }
      ForEach(row.localCopies.filter { copy in filter.tool.map(copy.root.readBy.contains) ?? !copy.root.readBy.intersection(store.tools).isEmpty }) { copy in
        VStack(alignment: .leading, spacing: 6) {
          Text(Paths.abbreviate(copy.folder)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          if copy.isSymlink { Text("Linked to \(Paths.describe(copy.resolved))").font(.caption).foregroundStyle(.secondary) }
          HStack {
            Button("Inspect project contents") { inspecting = ProjectContentsRequest(folder: copy.resolved, title: row.name) }
            Button("Show in Finder") { Finder.reveal(copy.folder) }
          }
          if let target = ProjectSkillTarget.allCases.first(where: { $0.relativePath == copy.root.relativePath }),
             store.projectState.entries.contains(where: { $0.projectID == project.id && $0.skillID == row.id && $0.target == target && $0.path == copy.folder.path }) {
            Button("Remove from project…") { applying = ProjectApplyRequest(target: target, removeSkillID: row.id) }.disabled(!canManage)
          } else {
            Text("Existing project copy. Manage this folder in Finder.").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
    }
    VStack(alignment: .leading, spacing: 8) {
      Text("Inherited from Global").font(.headline)
      let globalReaders = filter.tool.map { row.globalTools.intersection([$0]) } ?? row.globalTools.intersection(store.tools)
      if globalReaders.isEmpty { Text("No inherited Global installation for this agent.").font(.callout).foregroundStyle(.secondary) }
      else { ProjectReaderBadges(tools: globalReaders) }
      if !globalReaders.isEmpty, let skill = row.globalSkill {
        Button("Manage in Global…") { manageGlobal(skill.id, filter.tool) }
        Text("Global installations are available across projects.").font(.caption).foregroundStyle(.secondary)
        DisclosureGroup("Global locations") {
          ForEach(skill.copies.filter { copy in filter.tool.map(copy.root.readBy.contains) ?? !copy.root.readBy.intersection(store.tools).isEmpty }) { copy in
            Text(Paths.abbreviate(copy.folder)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
      }
    }
    VStack(alignment: .leading, spacing: 8) {
      Text("Recorded use in this project").font(.headline)
      let usage = store.projectUsage(project, tool: filter.tool)[row.name]
      Text("\(usage?.chats ?? 0) chats in the last \(store.usageScope.days ?? store.loadedLookbackDays) days").font(.callout)
      if let tool = filter.tool {
        Text(store.tools.contains(tool) ? "Chat counts for \(tool.name)." : "\(tool.name) history is disabled. Chat counts are zero.").font(.caption).foregroundStyle(.secondary)
      } else {
        Text("Chat counts for enabled agents.").font(.caption).foregroundStyle(.secondary)
      }
      Text("Show filters availability. Chat counts include recorded use from either location. Chats without a full working-directory path are excluded. Nested registered projects have their own counts.").font(.caption).foregroundStyle(.secondary)
      ForEach(store.tools.filter { (usage?.byTool[$0] ?? 0) > 0 }) { tool in
        HStack { ToolBadge(tool: tool); Text("\(usage?.byTool[tool] ?? 0) chats").font(.caption) }
      }
    }
  }
}

extension ProjectSkillsetAssignment {
  var projectAssignmentID: String { "\(projectID)|\(skillsetID)|\(target.rawValue)" }
}

struct ProjectReaderBadges: View {
  let tools: Set<Tool>
  @Environment(AppStore.self) private var store
  var body: some View {
    WrapLayout(spacing: 4) {
      ForEach(store.tools.filter(tools.contains)) { ToolBadge(tool: $0) }
    }
  }
}

struct ProjectApplyRequest: Identifiable {
  let id = UUID()
  var skillsetID: UUID?
  var target: ProjectSkillTarget = .shared
  var unassign = false
  var skillIDs: Set<Skill.ID> = []
  var removeSkillID: Skill.ID?
}

struct ProjectContentsRequest: Identifiable {
  let id = UUID()
  let folder: URL
  let title: String
}

struct ProjectContentsSheet: View {
  let request: ProjectContentsRequest
  @Environment(\.dismiss) private var dismiss
  @State private var review: SkillReview?
  @State private var selectedFile = "SKILL.md"
  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(request.title).font(.headline)
      Text(Paths.abbreviate(request.folder)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      if let review {
        Text(review.summary).font(.caption).foregroundStyle(.secondary)
        ReviewFindingsView(review: review)
        SearchChoice(title: "Read file", options: review.files.map {
          ChoiceOption(value: $0.path, title: $0.path, symbol: "doc.text")
        }, selection: $selectedFile)
      }
      ScrollView { Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
      HStack {
        Button("Show in Finder") { Finder.reveal(request.folder) }
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }.padding(24).frame(width: 660, height: 600)
      .onAppear { review = SkillReview.inspect(request.folder); readFile() }
      .onChange(of: selectedFile) { readFile() }
  }

  private func readFile() {
    text = (try? SkillContents.read(selectedFile, from: request.folder)) ?? "This file cannot be displayed as text. Open it in Finder to inspect it."
  }
}

struct ProjectApplySheet: View {
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let project: RegisteredProject
  let request: ProjectApplyRequest
  @State private var skillsetID: UUID?
  @State private var target: ProjectSkillTarget = .shared
  @State private var plan: ProjectSkillPlan?
  @State private var applying = false
  @State private var submitted = false
  @State private var reviews: [String: SkillReview] = [:]
  @State private var inspecting: ProjectContentsRequest?

  private var enabledTargets: [ProjectSkillTarget] { ProjectSkillTarget.allCases.filter { !$0.readBy.intersection(store.tools).isEmpty } }
  private var targetEnabled: Bool { enabledTargets.contains(target) }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Text(request.removeSkillID != nil ? "Remove skill from project" : request.unassign ? "Unassign project skillset" : "Add skills to project").font(.title2.weight(.semibold))
          Text(Paths.abbreviate(project.url)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          if request.unassign {
            Text(store.skillsets.first { $0.id == skillsetID }?.name ?? "Deleted skillset").font(.headline)
            Text(target.label).font(.caption).foregroundStyle(.secondary)
          }
          if !request.unassign && request.removeSkillID == nil {
            if request.skillIDs.isEmpty {
              SearchChoice(title: "Skillset", options: [
                ChoiceOption(value: UUID?.none, title: "Choose a skillset")
              ] + store.skillsets.map {
                ChoiceOption(value: UUID?.some($0.id), title: $0.name,
                  detail: $0.skills.isEmpty ? "No skills" : $0.skills.sorted().joined(separator: ", "), symbol: "square.stack.3d.up")
              }, selection: $skillsetID)
            } else {
              Text(request.skillIDs.sorted().joined(separator: ", ")).font(.headline)
            }
            ChoiceChips(title: "Agent group", options: enabledTargets.map {
              ChoiceOption(value: $0, title: $0 == .shared ? "Shared agents" : "Compatible agents")
            }, selection: $target)
          }
          if let id = request.removeSkillID { Text(id).font(.headline) }
          DisclosureGroup("Destination folder") {
            Text("\(project.path)/\(target.relativePath)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          }
          Text("Affected agents").font(.caption.weight(.semibold))
          ProjectReaderBadges(tools: target.readBy)
          if targetEnabled { DisabledReaderNotice(readers: target.readBy) }
          else { Text("Enable a tool in Settings for this destination before previewing changes.").font(.caption).foregroundStyle(.secondary) }
          Text(request.removeSkillID != nil
            ? "Removes this skill from assignments for the selected agent group. Unchanged project copies owned by Quartermaster move to Trash. Global installations, Library sources, and modified files are preserved."
            : "Skills are copied with their supporting files. Overlapping skillsets keep shared copies. Unchanged copies owned by Quartermaster can move to Trash. Existing and modified files are preserved.").font(.caption).foregroundStyle(.secondary)
          Divider()
          if let plan {
            if plan.changes.isEmpty, plan.issues.isEmpty { Text("No project files need to change. The project assignment will be saved.").font(.caption).foregroundStyle(.secondary) }
            ForEach(plan.issues + plan.leftOut, id: \.self) { Text($0).foregroundStyle(.orange).textSelection(.enabled) }
            ForEach(plan.warnings, id: \.self) { warning in
              Label { Text(warning).foregroundStyle(.secondary).textSelection(.enabled) } icon: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
              }.font(.callout).help("A warning. It doesn't stop Apply.")
            }
            ForEach(sourceChoices) { skill in
              VStack(alignment: .leading, spacing: 5) {
                ChoiceAction(title: "\(hasVersions(skill) ? "Choose version" : "Choose source") for \(skill.name)", options: SkillInstaller.installableSources(for: skill).map { source in
                  let version = SkillVersions.title(of: source, in: skill)
                  return ChoiceOption(value: source, title: version ?? source.sourceLabel,
                    detail: version == nil ? source.visiblePath : [source.sourceLabel, source.visiblePath].compactMap { $0 }.joined(separator: " · "),
                    symbol: "folder")
                }) { source in
                  if store.setProjectSource(source, for: skill, in: project) { refreshPreview() }
                }.help(hasVersions(skill) ? "This version is used in this project only." : "This choice becomes the skill's preferred source across Quartermaster.")
                if let source = chosenSource(for: skill) {
                  Text([SkillVersions.title(of: source, in: skill), source.sourceLabel, source.visiblePath].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else if hasVersions(skill), let suggested = preferredSource(for: skill) {
                  Text("Not chosen for this project. Suggested: \(SkillVersions.title(of: suggested, in: skill) ?? suggested.sourceLabel).").font(.caption).foregroundStyle(.secondary)
                } else {
                  Text(hasVersions(skill) ? "Choose which version this project uses." : "Choose which copy to use when the preview reports different sources.").font(.caption).foregroundStyle(.secondary)
                }
              }
            }
            ForEach(Array(plan.changes.enumerated()), id: \.offset) { _, change in
              VStack(alignment: .leading, spacing: 5) {
                Text("\(change.kind.rawValue.capitalized) \(change.skillID)").fontWeight(.medium)
                DisclosureGroup("File locations") {
                  Text(change.destinationPath).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                  if let source = change.sourcePath { Text("Source \(source)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
              }
            }
            ForEach(plan.kept, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            ForEach(plan.sourcePaths, id: \.self) { path in
              VStack(alignment: .leading, spacing: 6) {
                Text(URL(fileURLWithPath: path).lastPathComponent).fontWeight(.medium)
                Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let review = reviews[path] {
                  Text(review.summary).font(.caption).foregroundStyle(review.needsReview ? Color.orange : Color.secondary)
                  ReviewFindingsView(review: review)
                  Text("\(review.files.count) supporting files and instructions").font(.caption).foregroundStyle(.secondary)
                }
                Button("Inspect source contents") { inspecting = ProjectContentsRequest(folder: URL(fileURLWithPath: path), title: URL(fileURLWithPath: path).lastPathComponent) }
              }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
          } else { Text("Choose skills to preview project changes.").foregroundStyle(.secondary) }
          if submitted {
            ForEach(store.projectIssues[project.id] ?? [], id: \.self) { Text($0).font(.callout).foregroundStyle(.orange) }
            ForEach(store.projectNotes[project.id] ?? [], id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
            Text(store.projectState.pending == nil ? "Review the result above. Refresh the preview before applying again." : "The operation needs recovery. Close this preview and retry recovery in the project overview.").font(.caption).foregroundStyle(.secondary)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      HStack {
        Button("Refresh preview") { refreshPreview() }.disabled(applying)
        Spacer()
        Button(submitted ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button(request.removeSkillID != nil ? "Remove reviewed project copy" : request.unassign ? "Unassign and apply changes" : "Apply changes") {
          guard targetEnabled, let plan else { return }
          Task {
            applying = true
            _ = await store.applyProjectPlan(plan)
            submitted = true
            applying = false
          }
        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
          .disabled(!targetEnabled || applying || submitted || plan?.canApply != true || store.isManagingProjects || store.isManagingSkillsets)
      }
    }.padding(24)
      .frame(minWidth: 560, idealWidth: 700, maxWidth: 700, minHeight: 420, idealHeight: 700, maxHeight: 700)
      .disabled(applying).interactiveDismissDisabled(applying)
       .onAppear {
        skillsetID = request.skillsetID ?? store.skillsets.first?.id
        target = request.target
        if !request.unassign, request.removeSkillID == nil, !targetEnabled, let first = enabledTargets.first { target = first }
        refreshPreview()
      }
      .onChange(of: skillsetID) { refreshPreview() }
      .onChange(of: target) { refreshPreview() }
      .onChange(of: store.tools) {
        plan = nil
        reviews = [:]
        if !targetEnabled, !request.unassign, request.removeSkillID == nil, let first = enabledTargets.first { target = first }
      }
      .sheet(item: $inspecting) { ProjectContentsSheet(request: $0) }
  }

  private var sourceChoices: [Skill] {
    guard request.removeSkillID == nil else { return [] }
    let members = Set((plan?.proposedAssignments ?? []).flatMap(\.members))
    return store.skills.filter { members.contains($0.id) && SkillInstaller.installableSources(for: $0).count > 1 }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private func hasVersions(_ skill: Skill) -> Bool { SkillVersions.versions(of: skill).count > 1 }

  /// The preferred source only suggests a version here; the project's own choice decides it.
  private func preferredSource(for skill: Skill) -> SkillCopy? {
    store.sourcePreferences.defaults[skill.id].flatMap { path in SkillInstaller.installableSources(for: skill).first { $0.resolved.path == path } }
  }

  private func chosenSource(for skill: Skill) -> SkillCopy? {
    let sources = SkillInstaller.installableSources(for: skill)
    let saved = hasVersions(skill)
      ? store.sourcePreferences.byProject[project.path]?[skill.id].flatMap { path in sources.first { $0.resolved.path == path } }
      : preferredSource(for: skill)
    let planned = plan?.changes.first { $0.skillID == skill.id }?.sourcePath
    return saved ?? sources.first { $0.resolved.path == planned }
  }

  private func refreshPreview() {
    guard targetEnabled else { plan = nil; reviews = [:]; return }
    submitted = false
    if let id = request.removeSkillID {
      plan = store.projectRemoveSkillPlan(project, skillID: id, target: target)
    } else if !request.skillIDs.isEmpty {
      plan = store.projectSkillsPlan(project, skillIDs: request.skillIDs, target: target)
    } else if let skillsetID {
      plan = store.projectPlan(project, skillsetID: skillsetID, target: target, unassign: request.unassign)
    } else { plan = nil }
    reviews = Dictionary(uniqueKeysWithValues: (plan?.sourcePaths ?? []).map { ($0, SkillReview.inspect(URL(fileURLWithPath: $0))) })
  }
}
