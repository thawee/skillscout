import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
  case dashboard
  case discovery
  case library
  case global
  case used
  case usedOnce
  case unused
  case suggestions
  case skillset(UUID)
  case repo(String)
  case localSource(String)
  case similar
  case plugins
  case projects
  case project(UUID)

  var isRepositoryBrowser: Bool {
    switch self {
    case .discovery, .repo, .localSource: true
    default: false
    }
  }

  var isProjectBrowser: Bool {
    switch self {
    case .projects, .project: true
    default: false
    }
  }

  var listsSkills: Bool { !isRepositoryBrowser && !isProjectBrowser && self != .suggestions && self != .similar && self != .plugins && self != .dashboard }

}

enum DiscoveryKind: String, CaseIterable {
  case git = "Git repositories"
  case local = "Local folders"
}

struct DiscoveryKindChoices: View {
  @Binding var selection: DiscoveryKind

  var body: some View {
    Group {
      ForEach(DiscoveryKind.allCases, id: \.self) { kind in
        Button { selection = kind } label: {
          Text(kind.rawValue)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .fontWeight(selection == kind ? .semibold : .regular)
            .foregroundStyle(selection == kind ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
        }
        .tint(selection == kind ? .accentColor : .secondary)
      }
    }
    .help("Choose Git repositories or local folders")
  }
}

private enum DiscoveryTarget {
  case folder(String)
  case address(String)
  case repository(RepositoryID)
}

enum SkillSource: String {
  case yours, plugin, builtIn, all

  func includes(_ skill: Skill) -> Bool {
    switch self {
    case .yours: skill.isPersonal
    case .plugin: !skill.isPersonal && skill.copies.contains { $0.root.kind == .plugin }
    case .builtIn: !skill.isPersonal && skill.copies.contains { $0.root.kind == .builtIn }
    case .all: true
    }
  }
}

struct ContentView: View {
  @Environment(AppStore.self) private var store
  @State private var sidebar: SidebarItem? = .dashboard
  @State private var discoveryKind = DiscoveryKind.git
  @State private var discoveryTarget: DiscoveryTarget?
  @State private var selectedSkills: Set<Skill.ID> = []
  @State private var selectedSuggestion: Suggestion.ID?
  @State private var selectedRepository: RepositoryID?
  @State private var selectedPair: SimilarPair.ID?
  @State private var selectedPlugin: InstalledPlugin.ID?
  @State private var selectedProjectSkill: String?
  @State private var globalTool: Tool?
  @State private var projectFilters: [UUID: ProjectSkillFilter] = [:]
  @State private var search = ""
  @FocusState private var isSearchFocused: Bool
  @AppStorage("skillSource") private var source = SkillSource.all
  @AppStorage("skillSort") private var sort = SkillSort.newest
  @AppStorage("showSystemSkills") private var showSystemSkills = false
  @State private var showingNewSkillset = false
  @State private var showingEmptySkillsetEditor = false
  @State private var showingLocalFolder = false
  @State private var addedSource: String?
  @State private var newSkillsetName = ""
  @AppStorage("sidebar.projectsExpanded") private var projectsExpanded = true
  @AppStorage("sidebar.activityExpanded") private var activityExpanded = true
  @AppStorage("sidebar.pluginsExpanded") private var pluginsExpanded = true
  @AppStorage("sidebar.skillsetsExpanded") private var skillsetsExpanded = true
  @AppStorage("sidebar.ideasExpanded") private var ideasExpanded = true

  init(sidebar: SidebarItem? = nil, skill: Skill.ID? = nil, suggestion: Suggestion.ID? = nil, pair: SimilarPair.ID? = nil, repository: RepositoryID? = nil, discoveryKind: DiscoveryKind = .git, globalTool: Tool? = nil) {
    let destination: SidebarItem
    if let sidebar { destination = sidebar }
    else if skill != nil { destination = .library }
    else if suggestion != nil { destination = .suggestions }
    else if pair != nil { destination = .similar }
    else if repository != nil { destination = .discovery }
    else { destination = .dashboard }
    var kind = discoveryKind
    let target: DiscoveryTarget?
    switch destination {
    case .repo(let folder): target = .folder(folder)
    case .localSource(let address): target = .address(address); kind = .local
    default: target = destination.isRepositoryBrowser ? repository.map(DiscoveryTarget.repository) : nil
    }
    _globalTool = State(initialValue: globalTool)
    _sidebar = State(initialValue: destination.isRepositoryBrowser ? .discovery : destination)
    _discoveryKind = State(initialValue: kind)
    _discoveryTarget = State(initialValue: target)
    _selectedSkills = State(initialValue: Set(skill.map { [$0] } ?? []))
    _selectedSuggestion = State(initialValue: suggestion)
    _selectedPair = State(initialValue: pair)
    _selectedRepository = State(initialValue: repository)
  }

  private var selectedSkill: Skill.ID? {
    guard selectedSkills.count == 1, let id = selectedSkills.first,
          listedSkills.contains(where: { $0.id == id }) else { return nil }
    return id
  }

  private var skillListContext: SkillListContext {
    switch sidebar {
    case .global: .global(globalTool)
    case .skillset(let id): .skillset(id)
    case .used, .usedOnce, .unused: .activity
    default: .library
    }
  }

  private var listUsage: [Skill.ID: SkillUsage] {
    if skillListContext.usesAllLoadedHistory {
      return store.usageReport(scope: UsageScope(), tool: skillListContext.tool).usage
    }
    return store.usage
  }

  private func openInLibrary(_ id: Skill.ID) {
    search = ""
    sidebar = .library
    selectedSkills = [id]
  }

  private func manageGlobal(_ id: Skill.ID, tool: Tool?) {
    globalTool = tool
    if store.skill(id)?.isSystemOnly(in: globalScopeTools) == true { showSystemSkills = true }
    source = .all
    search = ""
    sidebar = .global
    selectedSkills = [id]
  }

  private var emptySkillListReason: SkillListEmptyState {
    if sidebar == .global && store.tools.isEmpty { return .noTools }
    if !search.isEmpty { return .search }
    if selectedSkillsetID != nil { return .skillset }
    if enabledSkills.isEmpty { return .fresh }
    if source != .all && !routedSkills(enabledSkills).isEmpty { return .source }
    return .scope
  }

  private func showAllSkills() { source = .all; search = ""; sidebar = .library }


  private var selectedProject: RegisteredProject? {
    if case .project(let id) = sidebar { return store.projectState.projects.first { $0.id == id } }
    return nil
  }

  private func projectFilter(_ id: UUID) -> Binding<ProjectSkillFilter> {
    Binding(get: { projectFilters[id] ?? ProjectSkillFilter() }, set: { projectFilters[id] = $0 })
  }

  private func clearDisabledSelections() {
    if let globalTool, !store.tools.contains(globalTool) { self.globalTool = nil }
    for id in projectFilters.keys {
      if let tool = projectFilters[id]?.tool, !store.tools.contains(tool) { projectFilters[id]?.tool = nil }
    }
    if let pending = store.pendingReviewedAdd, !store.tools.contains(pending.tool) { store.pendingReviewedAdd = nil }
    if let conflict = store.addConflict, !store.tools.contains(conflict.tool) { store.addConflict = nil }
    if let removal = store.removal, case .tool(let tool) = removal.scope, !store.tools.contains(tool) { store.removal = nil }
    if let selectedPlugin, !enabledPlugins.contains(where: { $0.id == selectedPlugin }) { self.selectedPlugin = nil }
  }

  private func registerProject() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Register project"
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    if let project = store.registerProject(folder) { sidebar = .project(project.id) }
  }

  private var selectedTool: Tool? { sidebar == .global ? globalTool : nil }

  private var selectedSkillsetID: UUID? {
    if case .skillset(let id) = sidebar { return id }
    return nil
  }

  private var enabledSkills: [Skill] {
    let tools = Set(store.tools)
    return store.skills.filter { $0.isVisible(in: tools, includePlugins: true) }
  }

  private var globalScopeTools: Set<Tool> { globalTool.map { Set([$0]) } ?? Set(store.tools) }

  private struct GlobalSkillCounts {
    let normal: Int
    let system: Int

    init(skills: [Skill], readers: Set<Tool>) {
      let available = skills.filter { !$0.availableIn.isDisjoint(with: readers) }
      system = available.count { $0.isSystemOnly(in: readers) }
      normal = available.count - system
    }
  }

  private var globalCounts: GlobalSkillCounts { GlobalSkillCounts(skills: store.skills, readers: globalScopeTools) }

  private var globalAgentCounts: [Tool: Int] {
    Dictionary(uniqueKeysWithValues: store.tools.map { ($0, GlobalSkillCounts(skills: store.skills, readers: [$0]).normal) })
  }

  private var sourceOptions: [ChoiceOption<SkillSource>] {
    var options = [
      ChoiceOption(value: SkillSource.all, title: "All skills"),
      ChoiceOption(value: SkillSource.yours, title: "Your skills"),
      ChoiceOption(value: SkillSource.plugin, title: "Plugin")
    ]
    if sidebar == .global && showSystemSkills {
      options.append(ChoiceOption(value: SkillSource.builtIn, title: "System"))
    }
    return options
  }

  private var librarySkills: [Skill] {
    if source == .builtIn {
      if sidebar == .global && showSystemSkills {
        return store.skills.filter { $0.isSystemOnly(in: globalScopeTools) }
      }
      return store.skills.filter { !$0.isSystemOnly(in: Set(store.tools)) }
    }
    return store.skills.filter {
      source.includes($0) && (sidebar == .global && showSystemSkills || !$0.isSystemOnly(in: Set(store.tools)))
    }
  }

  private var activitySkills: [Skill] { librarySkills.filter { !$0.isSystemOnly(in: Set(store.tools)) } }

  private func chats(_ skill: Skill) -> Int { store.usage[skill.id]?.chats ?? 0 }

  private func exportSkillset(_ skillset: Skillset) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "\(skillset.name).skillset.json"
    if panel.runModal() == .OK, let url = panel.url { store.exportSkillset(id: skillset.id, to: url) }
  }

  private func importSkillset() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url,
          let skillset = store.importSkillset(from: url) else { return }
    sidebar = .skillset(skillset.id)
  }
  private func isUsed(_ skill: Skill) -> Bool { chats(skill) > 1 }
  private func isUsedOnce(_ skill: Skill) -> Bool { chats(skill) == 1 }
  private func isUnused(_ skill: Skill) -> Bool { chats(skill) == 0 }

  private func routedSkills(_ librarySkills: [Skill]) -> [Skill] {
    var skills: [Skill]
    switch sidebar {
    case .library: skills = store.skills.filter(\.isInLibrary)
    case .global:
      skills = librarySkills.filter {
        !$0.availableIn.intersection(globalScopeTools).isEmpty && (showSystemSkills || !$0.isSystemOnly(in: globalScopeTools))
      }
    case .used: skills = librarySkills.filter(isUsed)
    case .usedOnce: skills = librarySkills.filter(isUsedOnce)
    case .unused: skills = librarySkills.filter(isUnused)
    case .skillset(let id):
      if let skillset = store.skillsets.first(where: { $0.id == id }) {
        skills = store.skills.filter { skillset.skills.contains($0.id) }
      } else {
        skills = []
      }
    default: skills = librarySkills
    }
    return skills
  }

  private var listedSkills: [Skill] {
    var skills = routedSkills(librarySkills)
    if !search.isEmpty {
      skills = skills.filter {
        $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search)
      }
    }
    let usage = listUsage
    return skills.sorted { sort.inOrder($0, $1) { usage[$0.id] } }
  }

  private var listedPairs: [SimilarPair] {
    let listed = Set(enabledSkills.map(\.id))
    return store.similar.filter { pair in
      listed.contains(pair.first) && listed.contains(pair.second)
        && (search.isEmpty || pair.first.localizedCaseInsensitiveContains(search) || pair.second.localizedCaseInsensitiveContains(search))
    }
  }

  /// The selected skill, when it's yours to rename or uninstall.
  private var actionSkill: Skill? {
    guard sidebar?.listsSkills ?? true, let skill = store.skill(selectedSkill), skill.isPersonal else { return nil }
    return skill
  }

  private var removalSkills: [Skill] {
    listedSkills.filter { selectedSkills.contains($0.id) }
  }

  private var scopedRemoval: Removal? {
    guard let selectedTool else { return nil }
    return .from(selectedTool, skills: removalSkills, selectedCount: selectedSkills.count)
  }

  /// Merging keeps the skill you use more, or the one more tools load.
  private func suggestedKeep(_ pair: SimilarPair) -> Skill.ID {
    func weight(_ id: Skill.ID) -> (Int, Int) { (store.usage[id]?.chats ?? 0, store.skill(id)?.availableIn.count ?? 0) }
    return weight(pair.second) > weight(pair.first) ? pair.second : pair.first
  }

  private var listedSuggestions: [Suggestion] {
    guard !search.isEmpty else { return store.suggestions }
    return store.suggestions.filter {
      $0.title.localizedCaseInsensitiveContains(search) || $0.summary.localizedCaseInsensitiveContains(search)
    }
  }

  private var localRepositoryBrowser: Bool { discoveryKind == .local }

  private var discoverySelection: Binding<DiscoveryKind> {
    Binding(get: { discoveryKind }, set: { kind in
      guard kind != discoveryKind else { return }
      discoveryKind = kind
      discoveryTarget = nil
      selectedRepository = nil
      search = ""
    })
  }

  private var listedRepositories: [RepositoryEntry] {
    store.repositories.filter { entry in
      entry.source.isGit != localRepositoryBrowser && (search.isEmpty
        || entry.name.localizedCaseInsensitiveContains(search)
        || entry.description.localizedCaseInsensitiveContains(search)
        || entry.source.address.localizedCaseInsensitiveContains(search))
    }
  }

  private var enabledPlugins: [InstalledPlugin] {
    let tools = Set(store.tools)
    return store.plugins.filter { tools.contains($0.tool) }
  }

  private var listedPlugins: [InstalledPlugin] {
    guard !search.isEmpty else { return enabledPlugins }
    return enabledPlugins.filter {
      $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search)
        || ($0.marketplace ?? "").localizedCaseInsensitiveContains(search)
    }
  }

  private func showRepository(_ entry: RepositoryEntry) {
    discoveryTarget = nil
    discoveryKind = entry.source.isGit ? .git : .local
    selectedRepository = entry.id
    search = ""
    sidebar = .discovery
  }

  private func routeRepositorySelection() {
    guard sidebar == .discovery else { return }
    let entry: RepositoryEntry?
    switch discoveryTarget {
    case .folder(let folder):
      entry = store.repositories.first { $0.installedFolder?.lastPathComponent == folder }
    case .address(let address):
      entry = store.repositories.first { $0.source.address == address || $0.catalog?.repo == address }
    case .repository(let id):
      entry = store.repositories.first { $0.id == id }
    case nil: return
    }
    if let entry { showRepository(entry) }
  }

  @ViewBuilder private var navigation: some View {
    Group {
      if sidebar == .dashboard {
        NavigationSplitView {
          sidebarList
        } detail: {
          ReportsView(openSimilar: { pair in
            search = ""
            sidebar = .similar
            selectedPair = pair.id
          })
        }
      } else {
        NavigationSplitView {
          sidebarList
        } content: {
          contentPane
        } detail: {
          detailPane
        }
        .searchable(text: $search)
        .searchFocused($isSearchFocused)
      }
    }
  }

  private var observedNavigation: some View {
    navigation
    .task {
      await store.loadRegistry()
    }
    .onChange(of: sidebar) { previous, current in
      selectedSkills.formIntersection(Set(listedSkills.map(\.id)))
      routeRepositorySelection()
      selectedProjectSkill = nil
      if current == .global { source = .all }
      if previous?.isProjectBrowser == true || current?.isProjectBrowser == true { search = "" }
    }
    .onChange(of: listedSkills.map(\.id)) {
      selectedSkills.formIntersection(Set(listedSkills.map(\.id)))
    }
    .sheet(isPresented: $showingEmptySkillsetEditor) {
      if let id = selectedSkillsetID, let skillset = store.skillsets.first(where: { $0.id == id }) {
        SkillsetEditor(skillset: skillset)
      }
    }
    .sheet(isPresented: $showingLocalFolder) { AddSourceView(selection: $addedSource) }
    .onChange(of: addedSource) {
      guard let address = addedSource else { return }
      Task {
        await store.loadRegistry()
        if let entry = store.repositories.first(where: {
          $0.source.address == SkillInstaller.redactedSource(address) || $0.catalog?.repo == address
        }) { showRepository(entry) }
      }
    }
    .onChange(of: store.tools) { clearDisabledSelections() }
    .onChange(of: showSystemSkills) {
      if !showSystemSkills && source == .builtIn { source = .all }
    }
    .onChange(of: store.projectState.projects.map(\.id)) {
      projectFilters = projectFilters.filter { store.project($0.key) != nil }
      if case .project(let id) = sidebar, !store.projectState.projects.contains(where: { $0.id == id }) { sidebar = .projects }
    }
    .onChange(of: store.repositories.map(\.id)) { routeRepositorySelection() }
    .onAppear {
      clearDisabledSelections()
      routeRepositorySelection()
      if sidebar == .global || (!showSystemSkills && source == .builtIn) { source = .all }
    }
    .onChange(of: store.searchRequests) { isSearchFocused = true }
    .onChange(of: store.revealRequest) {
      guard let id = store.revealRequest else { return }
      if let skill = store.skill(id), !skill.isInLibrary { manageGlobal(id, tool: nil) }
      else { showAllSkills(); selectedSkills = [id] }
      store.revealRequest = nil
    }
    .toolbar { toolbar }
  }

  var body: some View {
    observedNavigation
    .environment(\.openInLibrary, openInLibrary)
    .modifier(Presentations(store: store))
    .alert("Skillset imported", isPresented: Binding(
      get: { store.importNote != nil },
      set: { if !$0 { store.importNote = nil } }
    )) {
      Button("OK") {}
    } message: {
      Text(store.importNote ?? "")
    }
    .alert("New Skillset", isPresented: $showingNewSkillset) {
      TextField("Skillset Name", text: $newSkillsetName)
      Button("Cancel", role: .cancel) { newSkillsetName = "" }
      Button("Create") {
        let name = newSkillsetName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { store.createSkillset(name: name) }
        newSkillsetName = ""
      }
    } message: {
      Text("Enter a name for the new skillset.")
    }
  }

  @ViewBuilder private var contentPane: some View {
      if sidebar == .projects {
        ProjectListView(selection: Binding(get: { selectedProject?.id }, set: { id in sidebar = id.map(SidebarItem.project) ?? .projects }), register: registerProject)
      } else if sidebar?.isProjectBrowser == true {
        if let project = selectedProject {
          ProjectSkillListView(project: project, selection: $selectedProjectSkill, filter: projectFilter(project.id), search: search)
        } else { ContentUnavailableView("Choose a project", systemImage: "folder") }
      } else if sidebar?.isRepositoryBrowser == true {
        VStack(spacing: 0) {
          HStack(spacing: 6) { DiscoveryKindChoices(selection: discoverySelection) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(10)
          Divider()
          RepositoryList(repositories: listedRepositories, selection: $selectedRepository,
            localOnly: localRepositoryBrowser, hasSearch: !search.isEmpty, clearSearch: { search = "" },
            onAdded: showRepository)
            .id(discoveryKind)
        }
        .navigationTitle("Discovery")
      } else if sidebar == .suggestions {
        SuggestionList(suggestions: listedSuggestions, selection: $selectedSuggestion)
      } else if sidebar == .similar {
        SimilarList(pairs: listedPairs, selection: $selectedPair)
      } else if sidebar == .plugins {
        PluginList(plugins: listedPlugins, selection: $selectedPlugin)
      } else {
        GeometryReader { geometry in
          VStack(spacing: 0) {
            ScrollView {
              VStack(spacing: 0) {
                if case .skillset(let id) = sidebar {
                  SkillsetHeader(skillsetID: id)
                  Divider()
                } else if sidebar == .global, let tool = globalTool, !store.skillsets.isEmpty {
                  ToolSkillsetsView(tool: tool)
                  Divider()
                }
                if sidebar == .global {
                  HStack {
                    Text("Global").font(.headline)
                    Spacer()
                    Button("Add skills…") { store.pendingSkillAdd = SkillAddPresentation(tool: globalTool) }
                      .disabled(store.tools.isEmpty)
                  }.padding(10)
                  AgentChoices(tools: store.tools, allTitle: "All enabled agents", selection: $globalTool,
                    counts: globalAgentCounts, allCount: GlobalSkillCounts(skills: store.skills, readers: Set(store.tools)).normal)
                    .padding(.horizontal, 10).padding(.bottom, 8)
                  VStack(alignment: .leading, spacing: 4) {
                    Text("^[\(globalCounts.normal) skill](inflect: true) available globally")
                      .font(.caption).accessibilityIdentifier("global-skill-count")
                    Text("^[\(globalCounts.system) system skill](inflect: true)")
                      .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("global-system-count")
                    Toggle("Show system skills", isOn: $showSystemSkills)
                      .accessibilityIdentifier("show-system-skills")
                  }.padding(.horizontal, 10).padding(.bottom, 8)
                }
                if sidebar?.listsSkills ?? true {
                  VStack(alignment: .leading, spacing: 8) {
                    if sidebar != .library && selectedSkillsetID == nil {
                      ChoiceChips(title: "Show", options: sourceOptions, selection: $source)
                    }
                    ChoiceChips(title: "Sort", options: [
                      ChoiceOption(value: SkillSort.newest, title: "Newest"),
                      ChoiceOption(value: SkillSort.name, title: "Name"),
                      ChoiceOption(value: SkillSort.use, title: "Use")
                    ], selection: $sort)
                    if !skillListContext.usesAllLoadedHistory { UsageScopeControls() }
                    Text("Recorded use in \(skillListContext.usesAllLoadedHistory ? UsageScope().description(loadedDays: store.loadedLookbackDays) : store.usageScopeDescription)").font(.caption2).foregroundStyle(.secondary)
                  }.padding(.horizontal, 10).padding(.bottom, 10)
                }
              }
            }.frame(maxHeight: min(360, geometry.size.height * 0.55))
            Divider()
            SkillList(skills: listedSkills, selection: $selectedSkills, context: skillListContext, usageOverride: listUsage, manageGlobal: manageGlobal,
              emptyState: emptySkillListReason,
              browse: { search = ""; sidebar = .discovery }, addFolder: { showingLocalFolder = true },
              clearSearch: { search = "" }, showAll: showAllSkills,
              addSkills: { showingEmptySkillsetEditor = true })
          }
        }
        .navigationTitle(sidebar == .global ? "Global" : sidebar == .library ? "Library" : "Skills")
      }
  }

  @ViewBuilder private var detailPane: some View {
      if sidebar == .projects {
        ProjectWelcomeView(register: registerProject)
      } else if sidebar?.isProjectBrowser == true {
        if let project = selectedProject {
          ProjectDetailView(project: project, skillID: selectedProjectSkill, filter: projectFilters[project.id] ?? ProjectSkillFilter(), manageGlobal: manageGlobal).id(project.id)
        } else { ProjectWelcomeView(register: registerProject) }
      } else if sidebar?.isRepositoryBrowser == true {
        if let entry = store.repositories.first(where: { $0.id == selectedRepository }),
           entry.source.isGit != localRepositoryBrowser {
          RepositoryDetail(repository: entry).id(entry.id)
        } else {
          ContentUnavailableView(localRepositoryBrowser ? "Choose a local folder" : "Choose a Git repository",
            systemImage: localRepositoryBrowser ? "folder" : "shippingbox")
        }
      } else if sidebar == .suggestions {
        if let suggestion = store.suggestion(selectedSuggestion) {
          SuggestionDetail(suggestion: suggestion)
        } else {
          ContentUnavailableView("Pick a suggestion", systemImage: "lightbulb")
        }
      } else if sidebar == .similar {
        if let pair = listedPairs.first(where: { $0.id == selectedPair }) {
          SimilarDetail(pair: pair, keep: suggestedKeep(pair)).id(pair.id)
        } else {
          ContentUnavailableView("Pick two similar skills", systemImage: "arrow.triangle.merge")
        }
      } else if sidebar == .plugins {
        if let plugin = store.plugins.first(where: { $0.id == selectedPlugin }) {
          PluginDetail(plugin: plugin)
        } else {
          ContentUnavailableView("Pick a plugin", systemImage: "puzzlepiece.extension")
        }
      } else if let skill = store.skill(selectedSkill) {
        SkillDetail(skill: skill, installationSource: selectedTool.flatMap { skill.provider(for: $0) }, context: skillListContext, usageOverride: listUsage, manageGlobal: manageGlobal)
      } else if selectedSkills.count > 1 {
        VStack(spacing: 18) {
          Text("\(selectedSkills.count) skills selected").font(.title2)
          if skillListContext != .activity {
            SkillSelectionActions(skills: listedSkills.filter { selectedSkills.contains($0.id) }, initialTool: selectedTool)
          }
        }
      } else {
        ContentUnavailableView("Pick a skill", systemImage: "square.stack.3d.up")
      }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    if skillListContext == .activity, sidebar?.listsSkills ?? true {
      ToolbarItemGroup {
        Button {
          if let id = store.skill(selectedSkill)?.id { openInLibrary(id) }
        } label: {
          Label("Open in Library", systemImage: "books.vertical")
        }
        .disabled(store.skill(selectedSkill)?.isInLibrary != true)
        .help("Show the selected skill in Library")
        Button {
          if let id = store.skill(selectedSkill)?.id { manageGlobal(id, tool: nil) }
        } label: {
          Label("Manage in Global", systemImage: "globe")
        }
        .disabled(store.skill(selectedSkill).map { $0.availableIn.isDisjoint(with: store.tools) } ?? true)
        .help("Show the selected skill in Global")
      }
    } else if sidebar?.listsSkills ?? true {
      ToolbarItem {
        SkillSelectionActions(skills: listedSkills.filter { selectedSkills.contains($0.id) }, initialTool: selectedTool)
      }
      ToolbarItemGroup {
        if skillListContext.editsSkills {
          Button {
            store.editing = actionSkill
          } label: {
            Label("Edit", systemImage: "square.and.pencil")
          }
          .disabled(actionSkill.map(SkillInstaller.canEdit) != true)
          .help("Edit the selected skill's SKILL.md")
          Button {
            store.renaming = actionSkill
          } label: {
            Label("Rename", systemImage: "character.cursor.ibeam")
          }
          .disabled(actionSkill.map(SkillInstaller.canRename) != true)
          .help("Rename the selected skill")
        }
        if let skillsetID = selectedSkillsetID {
          Button {
            store.setSkillMembership(selectedSkills, in: skillsetID, included: false)
          } label: {
            Label("Remove from skillset", systemImage: "trash")
          }
          .disabled(selectedSkills.isEmpty || store.isManagingSkillsets)
        } else if sidebar == .global, selectedTool != nil {
          Button {
            store.removal = scopedRemoval
          } label: {
            Label(scopedRemoval?.actionLabel ?? "Remove from tool…", systemImage: "trash")
          }
          .disabled(scopedRemoval == nil)
          .help(scopedRemoval?.actionLabel ?? "Select a skill with a removable installation")
        } else if sidebar == .global {
          ChoiceAction(title: "Remove from agent…", options: store.tools.compactMap { tool in
            guard let removal = Removal.from(tool, skills: removalSkills, selectedCount: selectedSkills.count) else { return nil }
            return ChoiceOption(value: tool, title: tool.name, detail: removal.isShared ? "Shared installation. Review affected agents before removing." : nil)
          }) { tool in
            store.removal = Removal.from(tool, skills: removalSkills, selectedCount: selectedSkills.count)
          }
          .disabled(!removalSkills.contains(where: \.isPersonal))
        }
      }
    }
    if sidebar == .suggestions {
      ToolbarItem {
      Button {
        Task { await store.analyze() }
      } label: {
        Label("Find repeated tasks", systemImage: "sparkle.magnifyingglass")
      }
      .disabled(store.isAnalyzing || store.prompts.isEmpty)
      .help("Analyze your recent chats and suggest new skills")
      }
    }
  }

  private var sidebarList: some View {
    List(selection: $sidebar) {
      sidebarRow("Dashboard", symbol: "chart.bar.xaxis", count: 0, item: .dashboard)
      sidebarRow("Discovery", symbol: "sparkle.magnifyingglass", count: 0, item: .discovery)
      sidebarRow("Library", symbol: "books.vertical", count: store.skills.count(where: \.isInLibrary), item: .library)
        .help("Reusable skills and sources")
      sidebarRow("Global", symbol: "globe", count: store.skills.count {
        !$0.availableIn.intersection(store.tools).isEmpty && !$0.isSystemOnly(in: Set(store.tools))
      }, item: .global)
        .help("Skills available across projects, for enabled agents")
      Section("Projects", isExpanded: $projectsExpanded) {
        sidebarRow("All projects", symbol: "folder.badge.gearshape", count: store.projectState.projects.count, item: .projects)
        ForEach(store.projectState.projects) { project in
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(project.name)
              Text(Paths.abbreviate(project.url)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
          } icon: { Image(systemName: "folder").foregroundStyle(.tint) }
          .tag(SidebarItem.project(project.id))
          .help(project.path)
        }
        Button(action: registerProject) { Label("Register project…", systemImage: "plus") }
          .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 8)
      }
      Section("Chat activity", isExpanded: $activityExpanded) {
        Text("Within selected period")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help(store.usageScopeDescription)
        sidebarRow("Used in 2+ chats", symbol: "checkmark.circle", count: activitySkills.count(where: isUsed), item: .used)
          .help("Used in more than one chat in \(store.usageScopeDescription)")
        sidebarRow("Used in 1 chat", symbol: "1.circle", count: activitySkills.count(where: isUsedOnce), item: .usedOnce)
          .help("Used in exactly one chat in \(store.usageScopeDescription)")
        sidebarRow("No recorded use", symbol: "moon.zzz", count: activitySkills.count(where: isUnused), item: .unused)
          .help("No detected use in any chat in \(store.usageScopeDescription); installation is separate")
      }
      Section("Plugins", isExpanded: $pluginsExpanded) {
        sidebarRow("Installed plugins", symbol: "puzzlepiece.extension", count: enabledPlugins.count, item: .plugins)
          .help("Plugins installed in your agents, with the hooks and servers they run")
      }
      Section("Skillsets", isExpanded: $skillsetsExpanded) {
        ForEach(store.skillsets) { skillset in
          sidebarRow(skillset.name, symbol: "folder", count: skillset.skills.count, item: .skillset(skillset.id))
            .contextMenu {
              Button("Export Skillset…") { exportSkillset(skillset) }
              Button("Unassign and Delete Skillset", role: .destructive) { Task { await store.deleteSkillset(id: skillset.id) } }
                .help("Deletes this skillset and unassigns it from all tools, including retained assignments for disabled tools.")
                .disabled(store.isManagingSkillsets)
            }
        }
        Button {
          showingNewSkillset = true
        } label: {
          Label("New Skillset...", systemImage: "plus")
        }
        .buttonStyle(.plain)
        .padding(.leading, 8)
        .foregroundStyle(.secondary)
        Button {
          importSkillset()
        } label: {
          Label("Import Skillset…", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.plain)
        .padding(.leading, 8)
        .foregroundStyle(.secondary)
        .disabled(store.isManagingSkillsets)
      }
      Section("Ideas", isExpanded: $ideasExpanded) {
        sidebarRow("Suggestions", symbol: "lightbulb", count: store.suggestions.count, item: .suggestions)
        sidebarRow("Similar skills", symbol: "arrow.triangle.merge", count: listedPairs.count, item: .similar)
      }
    }
    .listStyle(.sidebar)
    .navigationSplitViewColumnWidth(min: 210, ideal: 230)
    .safeAreaInset(edge: .bottom) {
      StatusPanel()
    }
  }

  private func sidebarRow(_ title: String, symbol: String, color: Color? = nil, count: Int, item: SidebarItem) -> some View {
    Label {
      Text(title)
    } icon: {
      Image(systemName: symbol).foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint))
    }
    .badge(count)
    .tag(item)
  }
}

struct StatusPanel: View {
  @Environment(AppStore.self) private var store
  @AppStorage("lookbackDays") private var lookbackDays = 60

  private var status: String {
    if store.isAnalyzing { return "Looking for repeated tasks…" }
    if store.isLoadingPrompts { return "Reading your chats…" }
    return "Watching your chats"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        if store.isAnalyzing || store.isLoadingPrompts {
          ProgressView().controlSize(.mini)
        } else {
          Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green)
        }
        Text(status).font(.caption.weight(.medium))
      }
      Text("\(store.prompts.count) messages in the last \(lookbackDays) days")
        .font(.caption)
        .foregroundStyle(.secondary)
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .leading), count: 4), alignment: .leading, spacing: 4) {
        ForEach(store.tools) { tool in
          let count = store.prompts.count(where: { $0.tool == tool })
          if count > 0 {
            HStack(spacing: 3) {
              Image(systemName: tool.symbol).foregroundStyle(tool.color)
              Text("\(count)").lineLimit(1).minimumScaleFactor(0.8)
            }
            .help("\(count) messages from \(tool.name)")
          }
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      Group {
        if let last = store.lastAnalysis {
          Text("Analyzed \(last, format: .relative(presentation: .named)), \(store.newPromptCount) new since")
        } else {
          Text("Not analyzed yet")
        }
      }
      .font(.caption2)
      .foregroundStyle(.tertiary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The error alert, the uninstall confirmation and the sheets.
private struct Presentations: ViewModifier {
  @Bindable var store: AppStore

  func body(content: Content) -> some View {
    content
      .alert("Something went wrong", isPresented: Binding(
        get: { store.errorMessage != nil },
        set: { if !$0 { store.errorMessage = nil } }
      )) {
        Button("OK") {}
      } message: {
        Text(store.errorMessage ?? "")
      }
      .confirmationDialog(
        "Replace existing installation?",
        isPresented: Binding(
          get: { store.addConflict != nil },
          set: { if !$0 { store.addConflict = nil } }
        ),
        presenting: store.addConflict
      ) { conflict in
        Button("Replace with selected source", role: .destructive) {
          store.addConflict = nil
          Task { await store.replaceInstallation(conflict) }
        }
        Button("Keep existing", role: .cancel) { store.addConflict = nil }
      } message: { conflict in
        Text("Replace \(Paths.describe(conflict.destination)) in \(conflict.tool.name) with \(Paths.describe(conflict.source.resolved))? The existing folder or link will move to Trash. If installation fails, it will be restored.")
      }
      .confirmationDialog(
        store.removal?.title ?? "",
        isPresented: Binding(
          get: { store.removal != nil },
          set: { if !$0 { store.removal = nil } }
        ),
        presenting: store.removal
      ) { removal in
        Button(removal.confirmationLabel, role: .destructive) {
          guard case .tool(let tool) = removal.scope else { Task { await store.remove(removal.copies) }; return }
          if store.tools.contains(tool) { Task { await store.remove(removal.copies) } }
        }
      } message: { removal in
        Text(removal.message(enabledTools: store.tools))
      }
      .sheet(item: $store.pendingSkillAdd) { request in
        SkillAddFlowSheet(request: request)
      }
      .sheet(item: $store.renaming) { RenameSheet(skill: $0) }
      .sheet(item: $store.editing) { EditSheet(skill: $0) }
      .sheet(item: Binding(
        get: { store.pendingRepoUpdate },
        set: { if $0 == nil { Task { await store.finishRepoUpdate(apply: false) } } }
      )) { RepoUpdateSheet(update: $0) }
      .sheet(item: $store.pendingReviewedAdd) { ReviewedAddSheet(request: $0) }
  }
}
