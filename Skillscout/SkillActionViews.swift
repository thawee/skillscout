import SwiftUI

struct SkillSelectionActions: View {
  @Environment(AppStore.self) private var store
  let skills: [Skill]
  var initialSources: [Skill.ID: String] = [:]
  var initialTool: Tool?
  var destination: SkillDestination = .global
  var excludedTools: Set<Tool> = []
  @State private var showingNewSet = false
  @State private var name = ""

  var body: some View {
    WrapLayout(spacing: 8) {
      Button("Add skills…") {
        store.pendingSkillAdd = SkillAddPresentation(skillIDs: skills.map(\.id), destination: destination, sources: initialSources, tool: initialTool, excludedTools: excludedTools)
      }
        .disabled((!skills.isEmpty && skills.allSatisfy(\.isBuiltInOnly)) || store.tools.allSatisfy(excludedTools.contains) || store.isManagingSkillsets)
      ChoiceAction(title: "Add to skillset", options:
        store.skillsets.map { ChoiceOption(value: Optional($0.id), title: $0.name, detail: "\($0.skills.count) skills", symbol: "square.stack") }
          + [ChoiceOption(value: UUID?.none, title: "New skillset…", symbol: "plus")]
      ) { id in
        if let id { add(to: id) } else { showingNewSet = true }
      }
      .disabled(skills.isEmpty || store.isManagingSkillsets)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .alert("New skillset", isPresented: $showingNewSet) {
      TextField("Name", text: $name)
      Button("Cancel", role: .cancel) { name = "" }
      Button("Create and add") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          store.createSkillset(name: trimmed)
          if let id = store.skillsets.last?.id { add(to: id) }
        }
        name = ""
      }
    }
  }

  private func add(to id: UUID) {
    for skill in skills {
      if let path = initialSources[skill.id],
         let copy = SkillInstaller.installableSources(for: skill).first(where: { $0.resolved.path == path }),
         !store.setPreferredSource(copy, for: skill) { return }
    }
    store.setSkillMembership(Set(skills.map(\.id)), in: id, included: true)
  }
}

struct InspectedSkillSource: Identifiable, Sendable {
  let skill: Skill
  let copy: SkillCopy
  let fingerprint: String
  let review: SkillReview
  var id: String { copy.id }
}

struct SkillContentsSheet: View {
  let source: SkillCopy
  @Environment(\.dismiss) private var dismiss
  @State private var selectedFile = "SKILL.md"
  @State private var text = ""
  @State private var review: SkillReview?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Contents from \(source.sourceLabel)").font(.headline)
      if let path = source.visiblePath { Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
      if let review {
        Text(review.summary).font(.callout)
        ReviewFindingsView(review: review)
        SearchChoice(title: "Read file", options: review.files.map {
          ChoiceOption(value: $0.path, title: $0.path, detail: "\($0.size) bytes", symbol: $0.isScript ? "terminal" : "doc.text")
        }, selection: $selectedFile)
      }
      ScrollView {
        Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        if !source.isInLibraryStorage {
          Button("Show source in Finder") { Finder.reveal(source.resolved) }
        }
        Spacer()
        Button("Back to review") { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }
    .padding(24).frame(width: 680, height: 600)
    .onAppear { review = SkillReview.inspect(source.resolved); readFile() }
    .onChange(of: selectedFile) { readFile() }
  }

  private func readFile() {
    guard !selectedFile.hasPrefix("/"), !selectedFile.split(separator: "/").contains("..") else { return }
    text = (try? SkillContents.read(selectedFile, from: source.resolved))
      ?? "This file cannot be displayed as text. Open the source in Finder to inspect it."
  }
}

private struct SourceInspectionFailure: Error, Sendable {
  let message: String
}

struct SkillAddSheet: View {
  let skillIDs: [Skill.ID]
  var initialSources: [Skill.ID: String] = [:]
  var initialTool: Tool?
  var excludedTools: Set<Tool> = []
  var initialResults: [SkillAddResult] = []
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var selectedTools: Set<Tool> = []
  @State private var sources: [Skill.ID: String] = [:]
  @State private var inspected: [Skill.ID: InspectedSkillSource] = [:]
  @State private var inspectionErrors: [Skill.ID: String] = [:]
  @State private var inspectionGenerations: [Skill.ID: UUID] = [:]
  @State private var results: [String: SkillAddResult] = [:]
  @State private var inspecting: SkillCopy?
  @State private var replacing: SkillAddResult?
  @State private var applying = false
  @State private var initialized = false

  private var skills: [Skill] { skillIDs.compactMap(store.skill) }
  private var availableTools: [Tool] { store.tools.filter { !excludedTools.contains($0) } }
  private var targets: [Tool] { availableTools.filter(selectedTools.contains) }
  private var requests: [SkillAddRequest] {
    skills.flatMap { skill in
      guard let source = inspected[skill.id], source.copy.resolved.path == sources[skill.id] else { return [SkillAddRequest]() }
      return targets.map { tool in
        SkillAddRequest(skillID: skill.id, sourcePath: source.copy.resolved.path, tool: tool,
          reviewedFingerprint: source.fingerprint)
      }
    }
  }
  private var pendingRequests: [SkillAddRequest] {
    requests.filter { request in
      guard let result = results[request.id], result.matches(request) else { return true }
      return !result.outcome.completed
    }
  }

  /// Every reviewed row has an outcome that needs nothing more from you.
  private var finished: Bool { !results.isEmpty && pendingRequests.isEmpty }

  private var resultSummary: String {
    let added = currentResults.count { $0.outcome.becameAvailable }
    let kept = currentResults.count { if case .kept = $0.outcome { true } else { false } }
    let open = pendingRequests.count
    var parts: [String] = []
    if added > 0 { parts.append("\(added) added") }
    if kept > 0 { parts.append("\(kept) kept the existing copy") }
    if open > 0 { parts.append(open == 1 ? "1 needs your choice below" : "\(open) need your choice below") }
    return parts.isEmpty ? "Nothing changed." : parts.joined(separator: " · ") + "."
  }

  private var currentResults: [SkillAddResult] {
    requests.compactMap { request in
      guard let result = results[request.id], result.matches(request) else { return nil }
      return result
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Add \(skillIDs.count == 1 ? "skill" : "\(skillIDs.count) skills") to Global").font(.headline)
      Text("Choose agents and sources for Global. Existing installations stay until you explicitly replace them.")
        .font(.callout).foregroundStyle(.secondary)
      if availableTools.isEmpty {
        Text("Enable a tool in Settings to add skills to it.").foregroundStyle(.secondary)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], alignment: .leading) {
        ForEach(availableTools) { tool in
          Toggle(tool.name, isOn: Binding(
            get: { selectedTools.contains(tool) },
            set: { if $0 { selectedTools.insert(tool) } else { selectedTools.remove(tool) } }
          ))
        }
      }
      if !targets.isEmpty {
        let readers = Set(targets.flatMap { tool in SkillRoot.all.first(where: { $0.url == tool.skillsFolder })?.readBy ?? [tool] })
        Text("Affected agents · \(store.tools.filter(readers.contains).map(\.name).joined(separator: ", "))")
          .font(.caption).foregroundStyle(.secondary)
        DisabledReaderNotice(readers: readers)
      }
      HStack {
        Button("Select all tools") { selectedTools = Set(availableTools) }
        Button("Clear tools") { selectedTools.removeAll() }
      }.font(.caption)
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          ForEach(skills) { skill in skillRow(skill) }
          ForEach(skillIDs.filter { store.skill($0) == nil }, id: \.self) { id in
            Label("\(id): source is missing", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      if !results.isEmpty {
        Text(resultSummary).font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Button("Refresh review") {
          results = results.filter { if case .kept = $0.value.outcome { false } else { true } }
          prepareSources()
        }.disabled(applying)
        Spacer()
        if finished {
          Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        } else {
        Button(results.isEmpty ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
        Button(results.isEmpty ? "Add reviewed skills" : "Add remaining") {
          Task {
            applying = true
            let submitted = pendingRequests
            for result in await store.addReviewed(submitted) { results[result.id] = result }
            applying = false
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(applying || pendingRequests.isEmpty || store.isManagingSkillsets)
        .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(24).frame(width: 680, height: 640)
    .disabled(applying).interactiveDismissDisabled(applying)
    .onAppear {
      guard !initialized else { return }
      initialized = true
      results = Dictionary(initialResults.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
      if let initialTool, availableTools.contains(initialTool) { selectedTools = [initialTool] }
      else if availableTools.count == 1 { selectedTools = Set(availableTools) }
      for skill in skills {
        sources[skill.id] = initialSources[skill.id] ?? store.preferredSource(for: skill)?.resolved.path
      }
      prepareSources()
    }
    .onChange(of: store.tools) {
      selectedTools.formIntersection(availableTools)
      replacing = nil
    }
    .sheet(item: $inspecting) { SkillContentsSheet(source: $0) }
    .alert("Replace existing installation?", isPresented: Binding(
      get: { replacing != nil }, set: { if !$0 { replacing = nil } }
    )) {
      Button("Cancel", role: .cancel) { replacing = nil }
      Button("Move existing to Trash and replace", role: .destructive) {
        guard let result = replacing, store.tools.contains(result.request.tool), case .conflict(let conflict) = result.outcome else { return }
        replacing = nil
        Task {
          applying = true
          let updated = await store.replaceReviewed(result.request, conflict: conflict)
          results[updated.id] = updated
          applying = false
        }
      }
    } message: {
      Text("The current installation will move to Trash. Changed sources or installations require a fresh review.")
    }
  }

  @ViewBuilder private func skillRow(_ skill: Skill) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(skill.name).font(.body.weight(.semibold))
      let choices = SkillInstaller.installableSources(for: skill)
      if choices.isEmpty {
        Text("Built-in skills stay with their original tool.").foregroundStyle(.secondary)
      } else {
        SearchChoice(title: "Source", options:
          [ChoiceOption(value: "", title: "Choose a source")]
            + choices.map { ChoiceOption(value: $0.resolved.path, title: $0.sourceLabel, detail: $0.visiblePath, symbol: "folder") },
          selection: Binding(
            get: { sources[skill.id] ?? "" },
            set: { sources[skill.id] = $0; inspect(skill) }
          ))
        if let snapshot = inspected[skill.id] {
          HStack {
            Text(snapshot.review.summary).font(.caption).foregroundStyle(snapshot.review.needsReview ? Color.orange : Color.secondary)
            Spacer()
            Button("Inspect contents") { inspecting = snapshot.copy }
          }
          if let path = snapshot.copy.visiblePath { Text(path).font(.caption).foregroundStyle(.secondary) }
          ForEach(targets) { tool in targetRow(skill, source: snapshot.copy, tool: tool) }
        }
        if let error = inspectionErrors[skill.id] {
          Text(error).font(.callout).foregroundStyle(.orange)
        }
      }
    }
    .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder private func targetRow(_ skill: Skill, source: SkillCopy, tool: Tool) -> some View {
    HStack(alignment: .top) {
      Text(tool.name).frame(width: 110, alignment: .leading)
      if let result = results["\(skill.id)|\(tool.rawValue)"], result.request.sourcePath == source.resolved.path,
         result.request.reviewedFingerprint == inspected[skill.id]?.fingerprint {
        Text(result.outcome.message).foregroundStyle(result.outcome.completed ? Color.secondary : Color.orange)
        if case .conflict(let conflict) = result.outcome {
          Spacer()
          Button("Keep existing") {
            results[result.id] = SkillAddResult(request: result.request, outcome: .kept(conflict.destination))
          }
          Button("Open existing") { Finder.reveal(conflict.destination) }
          Button("Replace…") { replacing = result }
        }
      } else {
        switch try? SkillInstaller.addPreview(skill, to: tool, from: source) {
        case .available: Text("Already available from this source").foregroundStyle(.secondary)
        case .ready(let folder): Text("Add at \(Paths.abbreviate(folder))").foregroundStyle(.secondary)
        case .conflict(let conflict): Text("Existing installation will be kept at \(Paths.abbreviate(conflict.destination))").foregroundStyle(.orange)
        case nil: Text("Cannot add this source. Refresh review.").foregroundStyle(.orange)
        }
      }
    }.font(.caption)
  }

  private func prepareSources() {
    for skill in skills { inspect(skill) }
  }

  private func inspect(_ skill: Skill) {
    inspected[skill.id] = nil
    inspectionErrors[skill.id] = nil
    guard let source = SkillInstaller.installableSources(for: skill).first(where: { $0.resolved.path == sources[skill.id] }) else {
      if !SkillInstaller.installableSources(for: skill).isEmpty { inspectionErrors[skill.id] = "Choose which source to add." }
      return
    }
    let generation = UUID()
    inspectionGenerations[skill.id] = generation
    Task {
      let outcome = await Task.detached { () -> Result<InspectedSkillSource, SourceInspectionFailure> in
        do {
          return .success(InspectedSkillSource(skill: skill, copy: source,
            fingerprint: try SkillInstaller.skillsetFingerprint(source.resolved), review: SkillReview.inspect(source.resolved)))
        } catch { return .failure(SourceInspectionFailure(message: error.localizedDescription)) }
      }.value
      guard inspectionGenerations[skill.id] == generation, sources[skill.id] == source.resolved.path else { return }
      switch outcome {
      case .success(let snapshot): inspected[skill.id] = snapshot
      case .failure(let error): inspectionErrors[skill.id] = error.message
      }
    }
  }
}

/// The project the usage counts come from. Shared by every skill list that counts chats in a saved scope.
struct UsageProjectChoice: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    SearchChoice(title: "Project", options:
      [ChoiceOption(value: String?.none, title: "All projects", symbol: "folder")]
        + store.usageProjects.map { ChoiceOption(value: Optional($0), title: UsageScope.projectLabel($0), detail: $0 == "Unknown" || $0.isEmpty ? nil : $0, symbol: "folder") },
      selection: Binding(
        get: { store.usageScope.project },
        set: { store.setUsageScope(UsageScope(project: $0, days: store.usageScope.days)) }
      ))
  }
}

/// The period the usage counts cover, as a compact menu.
struct UsagePeriodPicker: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    Picker("Period", selection: Binding(
      get: { store.usageScope.days ?? 0 },
      set: { store.setUsageScope(UsageScope(project: store.usageScope.project, days: $0 == 0 ? nil : $0)) }
    )) {
      Text("All history (\(store.loadedLookbackDays) days)").tag(0)
      ForEach([7, 30, 60, 90].filter { $0 < store.loadedLookbackDays }, id: \.self) { Text("\($0) days").tag($0) }
    }
    .pickerStyle(.menu).fixedSize()
  }
}

struct SkillAddFlowSheet: View {
  let request: SkillAddPresentation
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var destination = SkillDestination.global
  @State private var selected: Set<Skill.ID> = []
  @State private var skillsetID: UUID?
  @State private var choosingSkillset = false
  @State private var reviewing = false
  @State private var initialized = false
  @State private var search = ""
  @State private var pickingSkills = true

  private var candidates: [Skill] {
    store.skills.filter { !SkillInstaller.installableSources(for: $0).isEmpty && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search)) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  var body: some View {
    Group {
      if reviewing {
        review
      } else {
        VStack(alignment: .leading, spacing: 16) {
          Text("Add skills").font(.title2.weight(.semibold))
          SearchChoice(title: "Destination", options:
            [ChoiceOption(value: SkillDestination.global, title: "Global", detail: "Available across projects", symbol: "globe")]
              + store.projectState.projects.map { ChoiceOption(value: SkillDestination.project($0.id), title: $0.name, detail: Paths.abbreviate($0.url), symbol: "folder") },
            selection: $destination)
          Picker("Choose", selection: $choosingSkillset) {
            Text("Individual skills").tag(false)
            Text("Skillset").tag(true)
          }.pickerStyle(.segmented)
          if choosingSkillset {
            SearchChoice(title: "Skillset", options:
              [ChoiceOption(value: UUID?.none, title: "Choose a skillset")]
                + store.skillsets.map { ChoiceOption(value: Optional($0.id), title: $0.name, detail: "\($0.skills.count) skills", symbol: "square.stack") },
              selection: $skillsetID)
            if let skillset = store.skillsets.first(where: { $0.id == skillsetID }) {
              Text("\(skillset.skills.count) skills").foregroundStyle(.secondary)
              Text(skillset.skills.sorted().joined(separator: ", ")).font(.callout).textSelection(.enabled)
            }
            Spacer()
          } else if !pickingSkills {
            VStack(alignment: .leading, spacing: 6) {
              Text(selected.count == 1 ? "Selected skill" : "\(selected.count) selected skills").font(.headline)
              Text(selected.sorted().joined(separator: ", ")).textSelection(.enabled)
              Button("Change skills…") { pickingSkills = true }.buttonStyle(.link)
            }
            Spacer()
          } else {
            TextField("Find a skill", text: $search)
            List(candidates, selection: $selected) { skill in
              VStack(alignment: .leading, spacing: 4) {
                Text(skill.name).fontWeight(.medium)
                Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
              }.tag(skill.id)
            }
            Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
          }
          HStack {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            Button("Continue") { reviewing = true }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
              .disabled(choosingSkillset ? skillsetID == nil : selected.isEmpty)
          }
        }.padding(24).frame(width: 680, height: 600)
      }
    }.onAppear {
      guard !initialized else { return }
      initialized = true
      destination = request.destination
      selected = Set(request.skillIDs)
      pickingSkills = request.skillIDs.isEmpty
      skillsetID = request.skillsetID
      choosingSkillset = request.skillsetID != nil
    }
  }

  @ViewBuilder private var review: some View {
    switch destination {
    case .global:
      if choosingSkillset, let skillsetID {
        SkillsetAssignmentsSheet(skillsetID: skillsetID, tool: request.tool)
      } else {
        SkillAddSheet(skillIDs: selected.sorted(), initialSources: request.sources, initialTool: request.tool, excludedTools: request.excludedTools)
      }
    case .project(let id):
      if let project = store.project(id) {
        ProjectApplySheet(project: project, request: ProjectApplyRequest(skillsetID: choosingSkillset ? skillsetID : nil,
          target: request.tool == .claude ? .claude : .shared, skillIDs: choosingSkillset ? [] : selected))
      } else {
        ContentUnavailableView("Project unavailable", systemImage: "folder.badge.questionmark")
      }
    }
  }
}
