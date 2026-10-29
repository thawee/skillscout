import SwiftUI

enum SkillListEmptyState {
  case fresh, search, source, skillset, scope, noTools
}

struct SkillListEmptyView: View {
  let reason: SkillListEmptyState
  var browse: () -> Void = {}
  var addFolder: () -> Void = {}
  var clearSearch: () -> Void = {}
  var showAll: () -> Void = {}
  var addSkills: () -> Void = {}

  private var title: String {
    switch reason {
    case .noTools: "No enabled tools"
    case .fresh: "Build your skill library"
    case .search: "No matching skills"
    case .source: "No skills of this type"
    case .skillset: "This skillset is empty"
    case .scope: "No skills in this view"
    }
  }

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: "square.stack.3d.up.slash")
    } description: {
      switch reason {
      case .noTools: Text("Enable an AI tool in Settings to see its Global skills.")
      case .fresh: Text("Browse skills or add a local folder to start using them with your tools.")
      case .search: Text("Try another name or description.")
      case .source: Text("Other skill types may be available in your library.")
      case .skillset: Text("Choose skills from your library before assigning this skillset to a tool.")
      case .scope: Text("Try all skills or another usage scope. Recorded use depends on the chats your tools retain.")
      }
    } actions: {
      switch reason {
      case .noTools: SettingsLink { Text("Open Settings") }
      case .fresh:
        VStack(spacing: 8) {
          Button("Browse Discovery", action: browse)
          Button("Add local folder", action: addFolder)
        }
      case .search: Button("Clear search", action: clearSearch)
      case .source: Button("Show all skill types", action: showAll)
      case .skillset: Button("Add skills", action: addSkills)
      case .scope: Button("Show all skills", action: showAll)
      }
    }
  }
}

/// The view a skill is shown in. Each one leads with the facts and actions for its purpose.
enum SkillListContext: Equatable {
  case library
  case global(Tool?)
  /// Global's Shared row: the skills in `~/.agents/skills`, removed from that folder only.
  case globalShared
  case activity
  case skillset(UUID)
  case discovery
  case plugin

  var tool: Tool? { if case .global(let tool) = self { tool } else { nil } }
  var isGlobal: Bool {
    switch self {
    case .global, .globalShared: true
    default: false
    }
  }
  var skillsetID: UUID? { if case .skillset(let id) = self { id } else { nil } }
  /// Only Library and Chat activity have their own project and period filters.
  var usesAllLoadedHistory: Bool { self != .library && self != .activity }
  /// Edit and Rename belong to Library, where sources are stored.
  var editsSkills: Bool { self == .library }
  /// Only Library shows Skillscout's own storage folders. Other views name them as the Library.
  var showsLibraryStorage: Bool { self == .library }
  /// Library and Global add, remove and move installations. Other views link to them.
  var managesInstallations: Bool { self == .library || isGlobal }

  var detailSections: [SkillDetailSection] {
    switch self {
    case .library: [.problems, .sources, .contents, .skillsets, .usage, .explanation, .file]
    case .global, .globalShared: [.problems, .sources, .contents, .skillsets, .usage, .file]
    case .activity: [.usage, .sources, .file]
    case .skillset: [.skillsets, .sources, .usage, .file]
    case .discovery: [.contents, .problems, .sources, .explanation, .file]
    case .plugin: [.contents, .sources, .usage, .file]
    }
  }

  func removal(for skills: [Skill], selectedCount: Int) -> Removal? {
    if self == .globalShared { return .shared(skills, selectedCount: selectedCount) }
    if let tool { return .from(tool, skills: skills, selectedCount: selectedCount) }
    return nil
  }
}

enum SkillDetailSection {
  case problems, sources, contents, skillsets, usage, explanation, file
}

private struct OpenInLibraryKey: EnvironmentKey {
  static let defaultValue: (@MainActor (Skill.ID) -> Void)? = nil
}

private struct OpenSourceInDiscoveryKey: EnvironmentKey {
  static let defaultValue: (@MainActor (_ address: String, _ description: String) -> Void)? = nil
}

extension EnvironmentValues {
  /// Shows a skill in Library. Views outside Library link there instead of editing in place.
  var openInLibrary: (@MainActor (Skill.ID) -> Void)? {
    get { self[OpenInLibraryKey.self] }
    set { self[OpenInLibraryKey.self] = newValue }
  }

  /// Shows a repository address in Discovery, adding it as a source when Discovery doesn't list it.
  var openSourceInDiscovery: (@MainActor (_ address: String, _ description: String) -> Void)? {
    get { self[OpenSourceInDiscoveryKey.self] }
    set { self[OpenSourceInDiscoveryKey.self] = newValue }
  }
}

struct SkillContextMenu: View {
  @Environment(AppStore.self) private var store
  @Environment(\.openInLibrary) private var openInLibrary
  let ids: Set<Skill.ID>
  let context: SkillListContext
  var manageGlobal: (Skill.ID, Tool?) -> Void = { _, _ in }

  private var skills: [Skill] { ids.sorted().compactMap { store.skill($0) } }
  private var addableIDs: Set<Skill.ID> {
    Set(skills.filter { !SkillInstaller.installableSources(for: $0).isEmpty }.map(\.id))
  }
  private var destinationSets: [Skillset] {
    store.skillsets.filter { $0.id != context.skillsetID && !addableIDs.isSubset(of: $0.skills) }
  }
  private var removal: Removal? { context.removal(for: skills, selectedCount: ids.count) }

  /// Outside Library, the folder an agent reads, never Skillscout's own storage.
  private func revealedCopy(of skill: Skill) -> SkillCopy? {
    let preferred = context.tool.flatMap { skill.provider(for: $0) } ?? store.preferredSource(for: skill) ?? skill.primary
    if context.showsLibraryStorage || Paths.libraryLocation(preferred.folder) == nil { return preferred }
    return skill.copies.first { Paths.libraryLocation($0.folder) == nil }
  }

  var body: some View {
    if !ids.isEmpty {
      switch context {
      case .skillset(let skillsetID):
        Button("Remove from this skillset") { store.setSkillMembership(ids, in: skillsetID, included: false) }
          .disabled(store.isManagingSkillsets)
        addToSkillset
        addToTool
      case .global, .globalShared:
        if let removal {
          Button(removal.actionLabel, role: .destructive) { store.removal = removal }
        }
        if skills.count == 1, let skill = skills.first, SkillInstaller.canMoveToCentral(skill) {
          Button("Move to Library") { Task { await store.moveToCentral(skill) } }
            .disabled(store.isManagingSkillsets)
        }
        addToTool
        addToSkillset
      case .library:
        addToTool
        addToSkillset
      case .activity, .discovery, .plugin:
        EmptyView()
      }
      if !context.showsLibraryStorage, skills.count == 1, let skill = skills.first, skill.isInLibrary, let openInLibrary {
        Button("Open in Library") { openInLibrary(skill.id) }
      }
      if skills.count == 1, let skill = skills.first {
        Divider()
        if context.editsSkills {
          if SkillInstaller.canEdit(skill) { Button("Edit SKILL.md…") { store.editing = skill } }
          if SkillInstaller.canRename(skill) { Button("Rename…") { store.renaming = skill } }
        }
        if let copy = revealedCopy(of: skill) {
          Button("Reveal in Finder") { Finder.reveal(copy.folder) }
        }
        if let plugin = store.plugins.first(where: { plugin in
          skill.copies.contains { copy in
            copy.root.kind == .plugin && (context.tool.map { copy.root.readBy.contains($0) } ?? true)
              && copy.resolved.path.hasPrefix(plugin.folder.resolvingSymlinksInPath().path + "/")
          }
        }) {
          Button("Show plugin in Finder") { Finder.reveal(plugin.folder) }
        }
      }
      if context == .library || context == .activity, let skill = skills.first, skills.count == 1, !skill.availableIn.intersection(store.tools).isEmpty {
        Button("Manage in Global…") { manageGlobal(skill.id, nil) }
      }
      if case .global = context {
        if skills.contains(where: { !$0.removableCopies.filter { !$0.root.readBy.isEmpty }.isEmpty }) {
          Divider()
          Menu("Remove from tool") {
            ForEach(store.tools) { tool in
              if let removal = Removal.from(tool, skills: skills, selectedCount: ids.count) {
                Button(tool.name + (removal.isShared ? " (shared installation)…" : "…"), role: .destructive) { store.removal = removal }
              }
            }
          }
        }

      }
    }
  }

  @ViewBuilder private var addToTool: some View {
    if !addableIDs.isEmpty {
      Button("Add skills…") {
        store.pendingSkillAdd = SkillAddPresentation(skillIDs: addableIDs.sorted(), tool: context.tool)
      }
      .disabled(store.isManagingSkillsets)
    }
  }

  @ViewBuilder private var addToSkillset: some View {
    if !addableIDs.isEmpty, !destinationSets.isEmpty {
      Menu(context.skillsetID == nil ? "Add to skillset" : "Add to another skillset") {
        ForEach(destinationSets) { skillset in
          Button(skillset.name) { store.setSkillMembership(addableIDs, in: skillset.id, included: true) }
        }
      }
      .disabled(store.isManagingSkillsets)
    }
  }
}

struct SkillList: View {
  @Environment(AppStore.self) private var store
  let skills: [Skill]
  @Binding var selection: Set<Skill.ID>
  var context = SkillListContext.library
  var usageOverride: [Skill.ID: SkillUsage]?
  var manageGlobal: (Skill.ID, Tool?) -> Void = { _, _ in }
  var emptyState = SkillListEmptyState.scope
  var browse: () -> Void = {}
  var addFolder: () -> Void = {}
  var clearSearch: () -> Void = {}
  var showAll: () -> Void = {}
  var addSkills: () -> Void = {}
  @State private var choosingRemoval = false

  var body: some View {
    List(skills, selection: $selection) { skill in
      SkillRow(skill: skill, usageOverride: usageOverride, tool: context.tool)
    }
    .contextMenu(forSelectionType: Skill.ID.self) { ids in
      SkillContextMenu(ids: ids, context: context, manageGlobal: manageGlobal)
    }
    .onDeleteCommand {
      guard !store.isManagingSkillsets else { return }
      if let id = context.skillsetID {
        store.setSkillMembership(selection, in: id, included: false)
      } else if context.tool != nil || context == .globalShared {
        store.removal = context.removal(for: selection.compactMap { store.skill($0) }, selectedCount: selection.count)
      } else if context.isGlobal {
        choosingRemoval = store.tools.contains { Removal.from($0, skills: selection.compactMap { store.skill($0) }, selectedCount: selection.count) != nil }
      }
    }
    .confirmationDialog("Remove selected skills", isPresented: $choosingRemoval) {
      ForEach(store.tools) { tool in
        if let removal = Removal.from(tool, skills: selection.compactMap { store.skill($0) }, selectedCount: selection.count) {
          Button(tool.name + (removal.isShared ? " (shared installation)…" : "…"), role: .destructive) { store.removal = removal }
        }
      }
    }
    .overlay {
      if skills.isEmpty {
        SkillListEmptyView(reason: emptyState, browse: browse, addFolder: addFolder,
          clearSearch: clearSearch, showAll: showAll, addSkills: addSkills)
      }
    }
  }
}

struct SkillRow: View {
  @Environment(AppStore.self) private var store
  let skill: Skill
  var usageOverride: [Skill.ID: SkillUsage]?
  var tool: Tool? = nil

  var body: some View {
    let activeTools = store.tools.filter { skill.availableIn.contains($0) }
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(skill.name)
          .font(.body.weight(.semibold))
          .lineLimit(1)
        Spacer()
        Text("^[\((usageOverride ?? store.usage)[skill.id]?.chats ?? 0) chat](inflect: true)")
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .fixedSize()
      }
      if !skill.description.isEmpty {
        Text(skill.description)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      let readers = tool.map { Set([$0]) } ?? Set(store.tools)
      if skill.isSystemOnly(in: readers) {
        Text("System · Managed by \(skill.systemOwners(in: readers).map(\.name).formatted())")
          .font(.caption).foregroundStyle(.secondary)
      }
      Group {
        if activeTools.isEmpty {
          Text(skill.availableIn.isEmpty ? "Not added to a tool" : "Not available to enabled tools")
            .font(.caption)
            .foregroundStyle(.tertiary)
        } else {
          WrapLayout(spacing: 3) {
            ForEach(activeTools) { tool in ToolBadge(tool: tool) }
          }
        }
      }
      .help(activeTools.isEmpty ? "Not available in an enabled tool" : "Available in \(activeTools.map(\.name).formatted())")
      .accessibilityLabel(activeTools.isEmpty ? "Not available in an enabled tool" : "Available in \(activeTools.map(\.name).formatted())")
    }
    .padding(.vertical, 4)
  }
}

struct SkillDetail: View {
  @Environment(AppStore.self) private var store
  let skill: Skill
  var installationSource: SkillCopy? = nil
  let context: SkillListContext
  var usageOverride: [Skill.ID: SkillUsage]?
  var manageGlobal: (Skill.ID, Tool?) -> Void = { _, _ in }
  @Environment(\.openInLibrary) private var openInLibrary
  @State private var inspector = SkillDetailInspector()
  @State private var inspection: SkillDetailInspection?

  private var inspectionRequest: SkillDetailRequest {
    SkillDetailRequest(skill: skill, installationSource: installationSource, revision: store.reportInspectionRevision)
  }

  private var currentInspection: SkillDetailInspection? {
    inspection?.request == inspectionRequest ? inspection : nil
  }

  private var content: String { currentInspection?.content ?? "" }
  private var selectedDescription: String { currentInspection?.description ?? "" }
  private var review: SkillReview? { currentInspection?.review }
  private var problems: [String] { currentInspection?.problems ?? [] }
  @State private var selectedPlugin: InstalledPlugin?

  private var displayedUsage: [Skill.ID: SkillUsage] {
    if let usageOverride { return usageOverride }
    if context.usesAllLoadedHistory {
      return store.usageReport(scope: UsageScope(), tool: context.tool).usage
    }
    return store.usage
  }

  private func supplyingPlugins(for readers: [Tool]) -> [InstalledPlugin] {
    store.plugins.filter { plugin in
      store.tools.contains(plugin.tool) && skill.copies.contains { copy in
        let folder = copy.folder.standardizedFileURL.path
        let provider = plugin.folder.standardizedFileURL.path
        return copy.root.kind == .plugin && !copy.root.readBy.isDisjoint(with: readers)
          && (folder == provider || folder.hasPrefix(provider + "/"))
      }
    }
  }

  private var managesPersonalCopies: Bool {
    guard let installationSource else { return skill.isPersonal }
    return installationSource.root.kind != .plugin && installationSource.root.kind != .builtIn && skill.isPersonal
  }

  private func place(_ url: URL) -> String {
    context.showsLibraryStorage ? Paths.abbreviate(url) : Paths.describe(url)
  }

  private var storedInLibrary: Bool { skill.copies.contains(where: \.isInLibraryStorage) }

  private var systemReaders: Set<Tool> { context.tool.map { Set([$0]) } ?? Set(store.tools) }

  private var removalToolGroups: [[Tool]] {
    var groups: [[Tool]] = []
    var positions: [[String]: Int] = [:]
    for tool in store.tools where skill.availableIn.contains(tool) && (context.tool.map { $0 == tool } ?? true) {
      let folders = skill.copiesRemoving(from: tool).map(\.folder.path).sorted()
      if let index = positions[folders] {
        groups[index].append(tool)
      } else {
        positions[folders] = groups.count
        groups.append([tool])
      }
    }
    return groups
  }

  /// The one card a removal belongs in: the resolved folder of every copy it moves,
  /// or, for a plugin or built-in provider, of every copy its agents read. Nil when they span cards.
  private func cardPath(_ copies: [SkillCopy]) -> String? {
    let paths = Set(copies.map(\.resolved.path))
    return paths.count == 1 ? paths.first : nil
  }

  private func cardPath(forRemovalBy tools: [Tool]) -> String? {
    guard let tool = tools.first else { return nil }
    let removing = skill.copiesRemoving(from: tool)
    return cardPath(removing.isEmpty ? skill.copies.filter { $0.root.readBy.contains(tool) } : removing)
  }

  private var cardPaths: Set<String> { Set(installationGroups.map { $0[0].resolved.path }) }

  /// Global's removals for the card at `path`, or with nil, those that belong in no single card.
  @ViewBuilder
  private func removals(in path: String?) -> some View {
    let placed: (String?) -> Bool = { found in
      path == nil ? found.map { !cardPaths.contains($0) } ?? true : found == path
    }
    if context == .globalShared, let removal = Removal.shared([skill], selectedCount: 1) {
      if placed(cardPath(removal.copies)) {
        Button(removal.actionLabel) { store.removal = removal }
          .buttonStyle(.link)
          .help("Moves the copy in ~/.agents/skills to the Trash, after naming the agents that read it")
      }
    } else if context.isGlobal {
      ForEach(Array(removalToolGroups.filter { placed(cardPath(forRemovalBy: $0)) }.enumerated()), id: \.offset) { _, tools in
        removalGroup(tools)
      }
    }
  }

  private func removalGroup(_ tools: [Tool]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let tool = tools.first, let removal = Removal.from(tool, skills: [skill], selectedCount: 1) {
        Button(removal.actionLabel) { store.removal = removal }
          .buttonStyle(.link)
          .multilineTextAlignment(.leading)
      }
      let protectedTools = tools.filter { tool in
        skill.copies.contains { $0.root.readBy.contains(tool) && ($0.root.kind == .plugin || $0.root.kind == .builtIn) }
      }
      if !protectedTools.isEmpty {
        Text("Plugin and built-in skills cannot be removed individually. Manage their providers in the original tool.")
          .font(.caption)
          .foregroundStyle(.secondary)
        ForEach(supplyingPlugins(for: tools)) { plugin in
          HStack(spacing: 8) {
            Text("Provided by \(plugin.name)").font(.callout)
            ToolBadge(tool: plugin.tool)
            Button("View plugin…") { selectedPlugin = plugin }
              .buttonStyle(.link)
          }
        }
      }
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        VStack(alignment: .leading, spacing: 6) {
          Text(skill.name)
            .font(.largeTitle.bold())
            .lineLimit(2)
            .truncationMode(.middle)
            .help(skill.name)
          if !(installationSource == nil ? skill.description : selectedDescription).isEmpty {
            Text(installationSource == nil ? skill.description : selectedDescription)
              .font(.title3)
              .foregroundStyle(.secondary)
          }
        }
        .textSelection(.enabled)

        if skill.isSystemOnly(in: systemReaders) {
          Text("System · Managed by \(skill.systemOwners(in: systemReaders).map(\.name).formatted())")
            .font(.callout).foregroundStyle(.secondary)
        }

        if currentInspection == nil {
          ProgressView("Reading skill…").controlSize(.small)
        }
        ForEach(context.detailSections, id: \.self) { section($0) }
      }
      .padding(28)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task(id: inspectionRequest) {
      let request = inspectionRequest
      do {
        let result = try await inspector.inspect(request)
        try Task.checkCancellation()
        guard request == inspectionRequest else { return }
        inspection = result
      } catch is CancellationError {
        return
      } catch {
        inspection = nil
      }
    }
    .sheet(item: $selectedPlugin) { plugin in
      VStack(spacing: 0) {
        HStack {
          Text("Plugin provider").font(.headline)
          Spacer()
          Button("Close") { selectedPlugin = nil }.keyboardShortcut(.cancelAction)
        }.padding()
        PluginDetail(plugin: plugin)
      }.frame(width: 820, height: 700)
    }
    .onChange(of: store.tools) {
      if let plugin = selectedPlugin, !store.tools.contains(plugin.tool) { selectedPlugin = nil }
    }
  }

  @ViewBuilder
  private func section(_ section: SkillDetailSection) -> some View {
    switch section {
    case .problems:
      if !problems.isEmpty {
        DetailSection("Problems") {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(problems, id: \.self) { problem in
              Label(problem, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text("Checked against the Agent Skills specification. Agents may skip the skill, rename it or cut its description.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
      }
    case .sources:
      DetailSection(context.isGlobal ? "Global availability" : "Sources") {
        installations
      }
    case .contents:
      if let review {
        DetailSection("Contents") {
          VStack(alignment: .leading, spacing: 8) {
            Text("\(review.files.count == 1 ? "1 file" : "\(review.files.count) files") from this source: \(review.summary.lowercased()).")
              .foregroundStyle(.secondary)
            ReviewFindingsView(review: review)
          }
        }
      }
    case .skillsets:
      DetailSection("Skillsets") {
        memberships
      }
    case .usage:
      DetailSection("Usage") {
        usageSummary
      }
    case .explanation:
      DetailSection("What it does") {
        explanation
      }
    case .file:
      if currentInspection != nil {
        DetailSection("SKILL.md") {
          if context == .activity {
            DisclosureGroup("Show SKILL.md") { file }
          } else {
            file
          }
        }
      }
    }
  }

  @ViewBuilder
  private var memberships: some View {
    if let skillsetID = context.skillsetID, let skillset = store.skillsets.first(where: { $0.id == skillsetID }) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Member of \(skillset.name)")
        if let source = store.preferredSource(for: skill) {
          Text("Source: \(source.sourceLabel)").font(.callout).foregroundStyle(.secondary)
        }
        Button("Remove from \(skillset.name)") { store.setSkillMembership([skill.id], in: skillset.id, included: false) }
          .buttonStyle(.link)
          .disabled(store.isManagingSkillsets)
        Text("Removing membership does not uninstall the skill.").font(.caption).foregroundStyle(.secondary)
      }
    } else {
      let members = store.skillsets.filter { $0.skills.contains(skill.id) }
      Text(members.isEmpty ? "Not in a skillset" : "In \(members.map(\.name).formatted(.list(type: .and)))")
        .foregroundStyle(members.isEmpty ? .secondary : .primary)
    }
  }

  @ViewBuilder
  private var usageSummary: some View {
    let scopeDescription = context.usesAllLoadedHistory ? UsageScope().description(loadedDays: store.loadedLookbackDays) : store.usageScopeDescription
    if let usage = displayedUsage[skill.id] {
      VStack(alignment: .leading, spacing: 10) {
        Text("Used in ^[\(usage.chats) chat](inflect: true) in \(scopeDescription), most recently \(usage.lastUsed, format: .relative(presentation: .named)).")
        HStack(spacing: 14) {
          ForEach(store.tools.filter { usage.byTool[$0] != nil }) { tool in
            HStack(spacing: 5) {
              ToolBadge(tool: tool)
              Text("\(usage.byTool[tool] ?? 0)")
                .font(.callout)
                .monospacedDigit()
            }
          }
        }
        if !usage.topProjects.isEmpty {
          Text("Mostly in \(usage.topProjects.map(UsageScope.projectLabel).formatted(.list(type: .and)))")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    } else {
      Text("No recorded use in \(scopeDescription).")
        .foregroundStyle(.secondary)
    }
    Text(context.tool.map { store.tools.contains($0) ? "Chat counts for \($0.name). Counts come from retained chats." : "\($0.name) history is disabled. Chat counts are zero." } ?? "A recorded use is a chat where the agent read this skill, or where you attached it yourself. Counts come from retained chats.")
      .font(.caption)
      .foregroundStyle(.tertiary)
  }

  @ViewBuilder
  private var explanation: some View {
    let key = (installationSource ?? skill.primary).contentHash
    if let text = store.explanations[key] {
      Text(text)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    } else if store.busy.contains("explain:\(key)") {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Reading the skill…").foregroundStyle(.secondary)
      }
    } else {
      Button {
        Task { await store.explain(skill, from: installationSource) }
      } label: {
        Label("Explain with AI", systemImage: "sparkles")
      }
    }
  }

  private var installations: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let entry = SkillsLock.entry(for: skill, in: store.skillsLock) {
        SkillsLockSourceRow(entry: entry)
      }
      if context.managesInstallations, !store.tools.isEmpty, skill.isSystemOnly(in: systemReaders) {
        Text("Built-in skills cannot be removed individually. Manage them in their original tool.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      WrapLayout(spacing: 8) {
        if !context.showsLibraryStorage, skill.isInLibrary, let openInLibrary {
          Button("Open in Library") { openInLibrary(skill.id) }
        }
        if context == .library || context == .activity, !skill.availableIn.intersection(store.tools).isEmpty {
          Button("Manage in Global…") { manageGlobal(skill.id, context.tool) }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      let created = skill.created(usage: displayedUsage[skill.id])
      if created != .distantPast {
        Text("Created \(created, format: .dateTime.day().month(.wide).year())")
          .foregroundStyle(.secondary)
      }
      if !context.showsLibraryStorage, storedInLibrary {
        if installationGroups.isEmpty {
          Text("Stored in Library. Not added to an agent.").font(.callout).foregroundStyle(.secondary)
        } else if installationGroups.joined().contains(where: { $0.isSymlink && $0.isInLibraryStorage }) {
          Text("Agents load this skill from Library.").font(.callout).foregroundStyle(.secondary)
        }
      }
      ForEach(Array(installationGroups.enumerated()), id: \.offset) { _, copies in
        let source = copies.first(where: { !$0.isSymlink }) ?? copies[0]
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(source.sourceLabel).font(.callout.weight(.semibold))
            Spacer()
            Menu {
              Button("Show source in Finder") { Finder.reveal(source.folder) }
              if context == .library && !source.isSymlink && source.root.readBy.isEmpty && skill.removableCopies.contains(source) {
                Button("Remove source…", role: .destructive) { store.removal = .copy(source, of: skill) }
              }
            } label: {
              Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .help("Source actions")
            .accessibilityLabel("Source actions")
          }
          readersView(for: copies)
          removals(in: source.resolved.path)
          Text("\(copies.count) \(copies.count == 1 ? "location" : "locations") · \(place(source.resolved))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(context.showsLibraryStorage ? source.resolved.path : place(source.resolved))
          DisclosureGroup("Show locations") {
            ForEach(copies) { copy in
              VStack(alignment: .leading, spacing: 3) {
                HStack {
                  Text(copy.root.label).font(.caption.weight(.medium))
                  Spacer()
                  Button("Finder") { Finder.reveal(copy.folder) }.buttonStyle(.link)
                }
                Text(copy.isSymlink ? "\(Paths.abbreviate(copy.folder)) → \(place(copy.resolved))" : Paths.abbreviate(copy.folder))
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
              .padding(.vertical, 3)
            }
          }
          .font(.caption)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
      }
      removals(in: nil)
      if skill.copiesDiffer {
        Label("These copies have different content, so editing one won't update the others.", systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.orange)
      }
      if managesPersonalCopies {
        if context.editsSkills, SkillInstaller.canRename(skill) { Button("Rename…") { store.renaming = skill } }
        if context.managesInstallations, !skill.copies.contains(where: { $0.root.kind == .managed || $0.root.kind == .shared || $0.root.kind == .drafts }) {
          Button("Move to Library") {
            Task { await store.moveToCentral(skill) }
          }
          .disabled(store.isManagingSkillsets)
        }
      } else if let plugin = installationSource?.root.kind == .plugin ? installationSource
          : skill.copies.first(where: { $0.root.kind == .plugin }) {
        Text("It comes from the \(plugin.sourceLabel), so uninstall the plugin to remove it.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var installationGroups: [[SkillCopy]] {
    let copies = context.showsLibraryStorage ? skill.copies : skill.copies.filter { Paths.libraryLocation($0.folder) == nil }
    var seen = Set<String>()
    return copies.compactMap { copy in
      guard seen.insert(copy.resolved.path).inserted else { return nil }
      return copies.filter { $0.resolved.path == copy.resolved.path }
    }
  }

  @ViewBuilder
  private func readersView(for copies: [SkillCopy]) -> some View {
    let readers = store.tools.filter { tool in copies.contains { $0.root.readBy.contains(tool) } }
    if readers.isEmpty && copies.allSatisfy({ $0.root.readBy.isEmpty }) {
      Text("Library source")
        .font(.callout)
        .foregroundStyle(.secondary)
    } else if readers.isEmpty {
      Text("Not loaded by enabled tools")
        .font(.callout)
        .foregroundStyle(.secondary)
    } else {
      Text("Available to")
        .font(.caption)
        .foregroundStyle(.secondary)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 4) {
          ForEach(readers) { tool in
            ToolBadge(tool: tool).fixedSize()
          }
        }
        WrapLayout(spacing: 4) {
          ForEach(readers) { tool in
            ToolBadge(tool: tool)
          }
        }
      }
    }
  }

  private var file: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 14) {
        if managesPersonalCopies, context.editsSkills, SkillInstaller.canEdit(skill) {
          Button("Edit") { store.editing = skill }
        }
        if context.showsLibraryStorage || !(installationSource ?? skill.primary).isInLibraryStorage {
          Button("Open in editor") { Finder.open((installationSource ?? skill.primary).resolved.appending(path: "SKILL.md")) }
        }
      }
      .buttonStyle(.link)
      if managesPersonalCopies, context.isGlobal, !skill.isInLibrary {
        Text("Move this skill to Library to edit or rename it.").font(.caption).foregroundStyle(.secondary)
      } else if !context.showsLibraryStorage, (installationSource ?? skill.primary).isInLibraryStorage {
        Text("Open this skill in Library to edit it.").font(.caption).foregroundStyle(.secondary)
      }
      Text(content)
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
  }
}

/// Copies of a skill on their way to the Trash, with the words that confirm it.
struct Removal {
  enum Scope {
    case everywhere, tool(Tool), source
    /// The copies in the shared `~/.agents/skills` folder.
    case shared
  }

  let skills: [Skill]
  let copies: [SkillCopy]
  let selectedCount: Int
  let scope: Scope

  static func uninstall(_ skill: Skill) -> Removal {
    uninstall([skill], selectedCount: 1)
  }

  static func uninstall(_ skills: [Skill], selectedCount: Int) -> Removal {
    let ordered = skills.filter(\.isPersonal).sorted { $0.name < $1.name }
    return Removal(skills: ordered, copies: orderedCopies(ordered.flatMap(\.removableCopies)),
      selectedCount: selectedCount, scope: .everywhere)
  }

  static func from(_ tool: Tool, skills: [Skill], selectedCount: Int) -> Removal? {
    let ordered = skills.filter { !$0.copiesRemoving(from: tool).isEmpty }.sorted { $0.name < $1.name }
    guard !ordered.isEmpty else { return nil }
    return Removal(skills: ordered, copies: orderedCopies(ordered.flatMap { $0.copiesRemoving(from: tool) }),
      selectedCount: selectedCount, scope: .tool(tool))
  }

  static func shared(_ skills: [Skill], selectedCount: Int) -> Removal? {
    func sharedCopies(_ skill: Skill) -> [SkillCopy] {
      skill.removableCopies.filter { $0.root.kind == .shared }.flatMap { skill.copiesGoing(with: $0) }
    }
    let ordered = skills.filter { !sharedCopies($0).isEmpty }.sorted { $0.name < $1.name }
    guard !ordered.isEmpty else { return nil }
    return Removal(skills: ordered, copies: orderedCopies(ordered.flatMap(sharedCopies)), selectedCount: selectedCount, scope: .shared)
  }

  static func copy(_ copy: SkillCopy, of skill: Skill) -> Removal {
    Removal(skills: [skill], copies: orderedCopies(skill.copiesGoing(with: copy)), selectedCount: 1, scope: .source)
  }

  private static func orderedCopies(_ copies: [SkillCopy]) -> [SkillCopy] {
    var seen = Set<String>()
    return copies.filter { seen.insert($0.folder.standardizedFileURL.path).inserted }
      .sorted {
        let firstDepth = $0.folder.pathComponents.count
        let secondDepth = $1.folder.pathComponents.count
        return firstDepth == secondDepth ? $0.folder.path < $1.folder.path : firstDepth > secondDepth
      }
  }

  private func plannedCopies(for skill: Skill) -> [SkillCopy] {
    let folders = Set(copies.map { $0.folder.standardizedFileURL.path })
    return skill.copies.filter { folders.contains($0.folder.standardizedFileURL.path) }
  }

  var affectedTools: [Tool] {
    let readers = Set(copies.flatMap(\.root.readBy))
    return Tool.allCases.filter(readers.contains)
  }

  var isShared: Bool {
    switch scope {
    case .tool(let tool): affectedTools.contains { $0 != tool }
    case .shared: true
    case .everywhere, .source: false
    }
  }

  var actionLabel: String {
    switch scope {
    case .tool(let tool):
      let others = affectedTools.filter { $0 != tool }
      if others.isEmpty { return "Remove from \(tool.name)…" }
      if others.count <= 2 { return "Remove from \(([tool] + others).map(\.name).formatted(.list(type: .and)))…" }
      return "Remove from \(tool.name) and \(others.count) other agents…"
    case .everywhere: return "Remove everywhere…"
    case .source: return "Remove source…"
    case .shared: return "Remove from Shared…"
    }
  }

  var confirmationLabel: String { actionLabel.replacingOccurrences(of: "…", with: "") }

  var title: String {
    let names = selectedCount > 1 ? "\(skills.count) selected \(skills.count == 1 ? "skill" : "skills")" : skills[0].name
    switch scope {
    case .tool(let tool):
      return isShared ? "Remove shared installation for \(names)?" : "Remove \(names) from \(tool.name)?"
    case .everywhere: return "Remove \(names) everywhere?"
    case .source: return "Remove source for \(names)?"
    case .shared: return "Remove \(names) from the shared folder?"
    }
  }

  func message() -> String { formattedMessage(enabledTools: Tool.allCases) }

  func message(enabledTools: [Tool]) -> String { formattedMessage(enabledTools: enabledTools) }

  private func formattedMessage(enabledTools: [Tool]) -> String {
    var sentences = ["Quartermaster moves \(copies.count) user-managed \(copies.count == 1 ? "folder or link" : "folders or links") to the Trash."]
    if case .source = scope {
      let sources = copies.filter { !$0.isSymlink }.map { Paths.describe($0.folder) }
      if !sources.isEmpty { sentences.append("Source locations: \(sources.formatted(.list(type: .and))).") }
    }
    let skipped = selectedCount - skills.count
    if skipped > 0 {
      let reason: String
      if case .tool(let tool) = scope { reason = "no removable copies read by \(tool.name)" }
      else if case .shared = scope { reason = "no copy in the shared folder" }
      else { reason = "no removable copies" }
      sentences.append("\(skipped) selected \(skipped == 1 ? "skill has" : "skills have") \(reason) and will be kept.")
    }
    if isShared && affectedTools.contains(where: enabledTools.contains) {
      sentences.append("This installation is read by \(affectedTools.filter(enabledTools.contains).map(\.name).formatted(.list(type: .and))). Removing it affects those tools.")
    }
    let losing = enabledTools.filter { tool in
      skills.contains { $0.toolsLosing(plannedCopies(for: $0)).contains(tool) }
    }
    if !losing.isEmpty {
      sentences.append("\(losing.map(\.name).formatted(.list(type: .and))) will stop loading \(selectedCount > 1 ? "at least one selected skill" : "this skill").")
    }
    let remaining = enabledTools.filter { tool in
      skills.contains { skill in
        let removed = plannedCopies(for: skill)
        return skill.copies.contains { !removed.contains($0) && $0.root.readBy.contains(tool) }
      }
    }
    if !remaining.isEmpty {
      sentences.append("\(remaining.map(\.name).formatted(.list(type: .and))) can still load \(selectedCount > 1 ? "selected skills" : "this skill") from remaining copies.")
    }
    let protected = enabledTools.filter { tool in
      skills.contains { skill in
        skill.copies.contains { ($0.root.kind == .plugin || $0.root.kind == .builtIn) && $0.root.readBy.contains(tool) }
      }
    }
    if !protected.isEmpty {
      sentences.append("Plugin or built-in access stays in \(protected.map(\.name).formatted(.list(type: .and))).")
    }
    if affectedTools.contains(where: { !enabledTools.contains($0) }) {
      sentences.append("This removal also affects disabled tools that read the shared location. Enable them in Settings to see their availability.")
    }
    var seenTargets = Set<URL>()
    let targets = skills.flatMap { $0.linkTargetsKept(plannedCopies(for: $0)) }
      .filter { seenTargets.insert($0).inserted }
    if !targets.isEmpty {
      sentences.append("The linked \(targets.count == 1 ? "source stays" : "sources stay") at \(targets.map(Paths.describe).formatted(.list(type: .and))).")
    }
    return sentences.joined(separator: " ")
  }
}

struct RenameSheet: View {
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let skill: Skill
  @State private var name: String

  init(skill: Skill) {
    self.skill = skill
    _name = State(initialValue: skill.name)
  }

  private var problem: String? {
    name == skill.name ? nil : SkillInstaller.renameProblem(skill, to: name, among: store.skills)
  }

  private var note: String {
    let folders = skill.removableCopies.count(where: { !$0.isSymlink })
    let links = skill.removableCopies.count(where: \.isSymlink)
    var what: [String] = []
    if folders > 0 { what.append(folders == 1 ? "its folder" : "its \(folders) folders") }
    if links > 0 { what.append(links == 1 ? "the link to it" : "the \(links) links to it") }
    var sentences = ["Quartermaster renames \(what.formatted(.list(type: .and))), and changes the name in SKILL.md."]

    let targets = skill.linkTargetsKept(skill.removableCopies)
    if !targets.isEmpty {
      sentences.append("\(targets.map(Paths.describe).formatted(.list(type: .and))), where the links point, \(targets.count == 1 ? "keeps its" : "keep their") folder name.")
    }
    if let plugin = skill.copies.first(where: { $0.root.kind == .plugin }) {
      sentences.append("The copy from the \(plugin.sourceLabel) keeps the old name.")
    }
    sentences.append("Chats that used \(skill.name) still count.")
    return sentences.joined(separator: " ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Rename \(skill.name)")
        .font(.headline)
      TextField("Name", text: $name)
        .textFieldStyle(.roundedBorder)
        .onSubmit(rename)
      if let problem {
        Text(problem)
          .font(.callout)
          .foregroundStyle(.red)
      }
      Text(note)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Rename", action: rename)
          .keyboardShortcut(.defaultAction)
          .disabled(name == skill.name || problem != nil)
      }
    }
    .padding(20)
    .frame(width: 440)
  }

  private func rename() {
    guard name != skill.name, problem == nil else { return }
    dismiss()
    Task { await store.rename(skill, to: name) }
  }
}

struct EditSheet: View {
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let skill: Skill
  @State private var edit: SkillInstaller.Edit?
  @State private var text = ""
  @State private var failure: String?
  @State private var changedOnDisk = false
  @State private var discarding = false

  private var problem: String? { edit.flatMap { SkillInstaller.editProblem($0, text: text) } }
  private var isChanged: Bool { edit.map { text != $0.original } ?? false }

  private var note: String {
    guard let edit else { return "" }
    var sentences = ["Quartermaster saves it to \(edit.files.map(Paths.describe).formatted(.list(type: .and)))."]
    if !edit.otherFiles.isEmpty {
      let one = edit.otherFiles.count == 1
      sentences.append("\(edit.otherFiles.map(Paths.describe).formatted(.list(type: .and))) \(one ? "has" : "have") other text, so \(one ? "it stays as it is" : "they stay as they are").")
    }
    if let plugin = skill.copies.first(where: { $0.root.kind == .plugin }) {
      sentences.append("The copy from the \(plugin.sourceLabel) stays as it is.")
    }
    return sentences.joined(separator: " ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Edit \(skill.name)")
        .font(.headline)
      PlainTextEditor(text: $text)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        .disabled(edit == nil)
      if let message = failure ?? problem {
        Text(message)
          .font(.callout)
          .foregroundStyle(.red)
      } else if changedOnDisk {
        Text("SKILL.md changed since you opened it, maybe from an agent. Save anyway to replace those changes with yours.")
          .font(.callout)
          .foregroundStyle(.orange)
      }
      Text(note)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) {
          if isChanged { discarding = true } else { dismiss() }
        }
        .keyboardShortcut(.cancelAction)
        Button(changedOnDisk ? "Save anyway" : "Save", action: save)
          .keyboardShortcut("s")
          .buttonStyle(.borderedProminent)
          .disabled(!isChanged || problem != nil)
      }
    }
    .padding(20)
    .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 640)
    .task {
      do {
        let edit = try SkillInstaller.edit(skill)
        text = edit.original
        self.edit = edit
      } catch {
        failure = error.localizedDescription
      }
    }
    .confirmationDialog("Discard your changes to \(skill.name)?", isPresented: $discarding) {
      Button("Discard", role: .destructive) { dismiss() }
    }
  }

  private func save() {
    guard let edit, isChanged, problem == nil else { return }
    Task {
      do {
        try await store.save(edit, text: text, overwrite: changedOnDisk)
        dismiss()
      } catch SkillInstaller.Failure.changedOnDisk {
        changedOnDisk = true
      } catch {
        failure = error.localizedDescription
      }
    }
  }
}

struct DisabledReaderNotice: View {
  let readers: Set<Tool>
  @Environment(AppStore.self) private var store

  var body: some View {
    let disabled = Tool.allCases.filter { readers.contains($0) && !store.tools.contains($0) }
    if !disabled.isEmpty {
      Text("This shared location also affects disabled tools: \(disabled.map(\.name).formatted(.list(type: .and))). Enable them in Settings to see and manage their availability.")
        .font(.caption).foregroundStyle(.orange)
    }
  }
}
