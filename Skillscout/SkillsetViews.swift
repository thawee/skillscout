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
            .disabled(store.isManagingSkillsets)
        }
        let assigned = Tool.allCases.filter { store.assignment(for: skillset.id, to: $0) != nil }
        let incomplete = assigned.count { store.skillsetStatus(skillset, to: $0).available < skillset.skills.count }
        HStack(spacing: 10) {
          Text("\(skillset.skills.count) skills · \(assigned.count) assigned")
            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
          if incomplete > 0 {
            Label("\(incomplete) need attention", systemImage: "exclamationmark.triangle")
              .font(.caption).foregroundStyle(.orange)
          }
          Spacer(minLength: 0)
          Button("Manage…") { showingAssignments = true }
            .help("Manage tool assignments for \(skillset.name)")
        }
        let missing = skillset.skills.filter { store.skill($0) == nil }.sorted()
        if !missing.isEmpty {
          DisclosureGroup("\(missing.count) missing sources") {
            ForEach(missing, id: \.self) { id in
              HStack {
                Label(id, systemImage: "exclamationmark.triangle")
                Spacer()
                Button("Remove from skillset") { store.setSkillMembership([id], in: skillset.id, included: false) }
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
    }
    .padding(12)
    .background(.regularMaterial)
    .sheet(isPresented: $showingAssignments) { SkillsetAssignmentsSheet(tool: tool) }
  }
}

struct SkillsetAssignmentsSheet: View {
  var skillsetID: UUID?
  var tool: Tool?
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(skillsetID.flatMap { id in store.skillsets.first(where: { $0.id == id })?.name }.map { "Assign \($0) to tools" }
        ?? "Skillsets for \(tool?.name ?? "tool")")
        .font(.title2.weight(.semibold))
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if let skillsetID {
            ForEach(Tool.allCases.filter { store.tools.contains($0) || store.assignment(for: skillsetID, to: $0) != nil }) { candidate in
              SkillsetAssignmentView(skillsetID: skillsetID, tool: candidate)
              Divider()
            }
            ForEach(Tool.allCases.filter { store.tools.contains($0) || store.assignment(for: skillsetID, to: $0) != nil }) { candidate in
              toolMessages(candidate)
            }
          } else if let tool {
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
    if let skillset = store.skillsets.first(where: { $0.id == skillsetID }) {
      let status = store.skillsetStatus(skillset, to: tool)
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 12) {
          Label(showSkillsetName ? skillset.name : tool.name, systemImage: showSkillsetName ? "folder" : tool.symbol)
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(status.label)
            .font(.caption)
            .foregroundStyle(status.pending || (status.assigned && status.available < status.total) ? .orange : .secondary)
            .lineLimit(1)
          Button(status.pending ? "Apply changes…" : status.assigned ? ((store.skillsetIssues[tool.rawValue] ?? []).isEmpty && status.available == status.total ? "Review…" : "Retry…") : "Apply…") {
            proposedAssignment = true
            showingPreview = true
          }
          .disabled(!status.assigned && skillset.skills.isEmpty)
          if status.assigned {
            Menu {
              Button("Unassign…", role: .destructive) {
                proposedAssignment = false
                showingPreview = true
              }
            } label: {
              Label("More actions", systemImage: "ellipsis")
            }
            .menuStyle(.borderlessButton)
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

  var body: some View {
    if let skillset = store.skillsets.first(where: { $0.id == skillsetID }) {
      let plan = store.skillsetPreview(skillset, to: tool, assigned: assigned)
      let reviews = plan.additions.reduce(into: [Skill.ID: SkillReview]()) { $0[$1.id] = additionReview($1) }
      VStack(alignment: .leading, spacing: 16) {
        Text("\(assigned ? "Apply" : "Unassign") \(skillset.name) \(assigned ? "to" : "from") \(tool.name)")
          .font(.headline)
        Text("Add \(plan.additions.count) · Keep \(plan.kept) existing · Remove up to \(plan.removals.count)")
        Text("Other assigned skillsets keep the skills they need. Existing personal installations and modified copies stay.")
          .font(.callout).foregroundStyle(.secondary)
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(plan.additions) { skill in
              if let review = reviews[skill.id] {
                Label("Add \(skill.name): \(review.summary.lowercased())", systemImage: "exclamationmark.triangle")
                  .foregroundStyle(.orange)
                  .help("From a downloaded repository. Open the skill to read its Contents before applying.")
              } else {
                Label("Add \(skill.name)", systemImage: "plus")
              }
            }
            ForEach(plan.removals, id: \.path) { Label("Remove \($0.skillID)", systemImage: "minus") }
            ForEach(plan.issues, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        if !plan.issues.isEmpty {
          Text("Available changes can be applied now. Unresolved items remain visible for retry.").font(.caption)
        }
        if !reviews.isEmpty {
          Text("Skills marked in orange come from downloaded repositories and have scripts or high-risk commands. Read their Contents before applying.")
            .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Spacer()
          Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
          Button(assigned ? "Apply" : "Unassign") {
            Task {
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
    }
  }

  /// The review of an addition's source when it comes from a downloaded repository and needs a look.
  private func additionReview(_ skill: Skill) -> SkillReview? {
    guard let source = SkillInstaller.skillsetSource(skill, preferredSources: store.preferredSources),
          SkillInstaller.isFromLibrary(source) else { return nil }
    let review = SkillReview.inspect(source.resolved)
    return review.needsReview ? review : nil
  }
}

struct SkillsetEditor: View {
  let skillset: Skillset
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var search = ""
  @State private var members: Set<Skill.ID>

  init(skillset: Skillset) {
    self.skillset = skillset
    _members = State(initialValue: skillset.skills)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Skills in \(skillset.name)").font(.headline)
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
            Menu {
              ForEach(sources) { source in
                Button("\(source.sourceLabel) · \(Paths.abbreviate(source.resolved))") {
                  store.setPreferredSource(source, for: skill)
                }
              }
            } label: {
              Text(store.preferredSource(for: skill).map { "Source: \($0.sourceLabel)" } ?? "Choose source…")
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
        Button("Save membership") {
          if store.replaceSkillsetMembers(members, in: skillset.id) { dismiss() }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 600, height: 560)
    .disabled(store.isManagingSkillsets)
  }
}
