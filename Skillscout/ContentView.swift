import SwiftUI

enum SidebarItem: Hashable {
  case discover
  case allSkills
  case missing
  case unused
  case unmanaged
  case tool(Tool)
  case suggestions
  case skillset(UUID)
  case repo(String)
  case similar

  var listsSkills: Bool { self != .discover && self != .suggestions && self != .similar }
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
  @State private var sidebar: SidebarItem? = .allSkills
  @State private var selectedSkills: Set<Skill.ID> = []
  @State private var selectedSuggestion: Suggestion.ID?
  @State private var selectedRegistrySkill: RegistrySkill.ID?
  @State private var selectedPair: SimilarPair.ID?
  @State private var search = ""
  @FocusState private var isSearchFocused: Bool
  @AppStorage("skillSource") private var source = SkillSource.yours
  @AppStorage("skillSort") private var sort = SkillSort.newest
  @State private var showingNewSkillset = false
  @State private var newSkillsetName = ""
  @State private var repoToRemove: String?

  init(sidebar: SidebarItem = .allSkills, skill: Skill.ID? = nil, suggestion: Suggestion.ID? = nil, pair: SimilarPair.ID? = nil) {
    _sidebar = State(initialValue: sidebar)
    _selectedSkills = State(initialValue: Set(skill.map { [$0] } ?? []))
    _selectedSuggestion = State(initialValue: suggestion)
    _selectedPair = State(initialValue: pair)
  }

  private var selectedSkill: Skill.ID? { selectedSkills.count == 1 ? selectedSkills.first : nil }

  private var selectedSkillsetID: UUID? {
    if case .skillset(let id) = sidebar { return id }
    return nil
  }

  private var enabledSkills: [Skill] {
    let tools = Set(store.tools)
    return store.skills.filter { $0.isVisible(in: tools, includePlugins: true) }
  }

  private var librarySkills: [Skill] { enabledSkills.filter(source.includes) }

  private func isMissing(_ skill: Skill) -> Bool {
    skill.isPersonal && !skill.missing(from: store.tools).isEmpty
  }

  private var listedSkills: [Skill] {
    var skills: [Skill]
    switch sidebar {
    case .missing: skills = librarySkills.filter(isMissing)
    case .unused: skills = librarySkills.filter { store.usage[$0.id] == nil }
    case .unmanaged:
      skills = librarySkills.filter { skill in
        skill.isPersonal && !skill.copies.contains { $0.root.kind == .managed || $0.root.kind == .shared }
      }
    case .tool(let tool): skills = librarySkills.filter { $0.availableIn.contains(tool) }
    case .skillset(let id):
      if let skillset = store.skillsets.first(where: { $0.id == id }) {
        skills = store.skills.filter { skillset.skills.contains($0.id) }
      } else {
        skills = []
      }
    case .repo(let repo): skills = librarySkills.filter { $0.managedRepos.contains(repo) }
    default: skills = librarySkills
    }
    if !search.isEmpty {
      skills = skills.filter {
        $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search)
      }
    }
    return skills.sorted { sort.inOrder($0, $1) { store.usage[$0.id] } }
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

  private var listedRegistrySkills: [RegistrySkill] {
    guard !search.isEmpty else { return store.registrySkills }
    return store.registrySkills.filter {
      $0.name.localizedCaseInsensitiveContains(search)
        || $0.description.localizedCaseInsensitiveContains(search)
        || $0.author.localizedCaseInsensitiveContains(search)
        || $0.repo.localizedCaseInsensitiveContains(search)
    }
  }

  var body: some View {
    NavigationSplitView {
      sidebarList
    } content: {
      if sidebar == .discover {
        DiscoverList(skills: listedRegistrySkills, selection: $selectedRegistrySkill)
      } else if sidebar == .suggestions {
        SuggestionList(suggestions: listedSuggestions, selection: $selectedSuggestion)
      } else if sidebar == .similar {
        SimilarList(pairs: listedPairs, selection: $selectedPair)
      } else {
        VStack(spacing: 0) {
          if case .skillset(let id) = sidebar {
            SkillsetHeader(skillsetID: id)
            Divider()
          } else if case .tool(let tool) = sidebar, !store.skillsets.isEmpty {
            ToolSkillsetsView(tool: tool)
            Divider()
          }
          SkillList(skills: listedSkills, selection: $selectedSkills, skillsetID: selectedSkillsetID)
        }
      }
    } detail: {
      if sidebar == .discover {
        if let skill = store.registrySkills.first(where: { $0.id == selectedRegistrySkill }) {
          DiscoverDetail(skill: skill) { repo in
            sidebar = .repo(repo)
            selectedSkills.removeAll()
          }
        } else {
          ContentUnavailableView("Pick a community skill", systemImage: "globe")
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
      } else if let skill = store.skill(selectedSkill) {
        SkillDetail(skill: skill)
      } else if selectedSkills.count > 1 {
        ContentUnavailableView("\(selectedSkills.count) skills selected", systemImage: "square.stack.3d.up", description: Text("Right-click the selected skills to add them to a skillset or uninstall them."))
      } else {
        ContentUnavailableView("Pick a skill", systemImage: "square.stack.3d.up")
      }
    }
    .task {
      await store.loadRegistry()
    }
    .searchable(text: $search)
    .searchFocused($isSearchFocused)
    .onChange(of: sidebar) { selectedSkills.removeAll() }
    .onChange(of: store.searchRequests) { isSearchFocused = true }
    .onChange(of: store.tools) {
      if case .tool(let tool) = sidebar, !store.tools.contains(tool) { sidebar = .allSkills }
    }
    .onChange(of: store.revealRequest) {
      guard let id = store.revealRequest else { return }
      if !(sidebar?.listsSkills ?? false) { sidebar = .allSkills }
      selectedSkills = [id]
      store.revealRequest = nil
    }
    .toolbar { toolbar }
    .modifier(Presentations(store: store))
    .confirmationDialog("Remove \(repoToRemove ?? "repository") from Library?", isPresented: Binding(
      get: { repoToRemove != nil },
      set: { if !$0 { repoToRemove = nil } }
    )) {
      Button("Move Repository to Trash", role: .destructive) {
        if let repo = repoToRemove { Task { await store.deleteRepo(name: repo) } }
        repoToRemove = nil
      }
    } message: {
      Text("This moves the repository and any links into it from AI tool folders to the Trash. Independent copies stay.")
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

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    if sidebar?.listsSkills ?? true {
      ToolbarItemGroup {
        Button {
          store.editing = actionSkill
        } label: {
          Label("Edit", systemImage: "square.and.pencil")
        }
        .disabled(actionSkill == nil)
        .help("Edit the selected skill's SKILL.md")
        Button {
          store.renaming = actionSkill
        } label: {
          Label("Rename", systemImage: "character.cursor.ibeam")
        }
        .disabled(actionSkill == nil)
        .help("Rename the selected skill")
        Button {
          if let skill = actionSkill { store.removal = .uninstall(skill) }
        } label: {
          Label("Uninstall", systemImage: "trash")
        }
        .disabled(actionSkill == nil)
        .help("Uninstall the selected skill from every tool, by moving it to the Trash")
      }
      ToolbarItem {
        Picker("Show", selection: $source) {
          Text("Your skills").tag(SkillSource.yours)
          Text("Plugin skills").tag(SkillSource.plugin)
          Text("Built-in skills").tag(SkillSource.builtIn)
          Divider()
          Text("All skills").tag(SkillSource.all)
        }
        .pickerStyle(.menu)
        .help("Show your own skills, the ones from plugins, the ones built into the agents, or all of them")
      }
      ToolbarItem {
        Picker("Sort", selection: $sort) {
          Text("Newest first").tag(SkillSort.newest)
          Text("Sort by name").tag(SkillSort.name)
          Text("Sort by use").tag(SkillSort.use)
        }
        .pickerStyle(.menu)
        .help("Sort skills by when you created them, by name, or by how often they're used")
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
      Section("Community") {
        sidebarRow("Discover", symbol: "globe", count: store.registrySkills.count, item: .discover)
      }
      Section("Skills") {
        sidebarRow("All skills", symbol: "square.stack.3d.up", count: librarySkills.count, item: .allSkills)
        sidebarRow("Missing somewhere", symbol: "exclamationmark.triangle", count: librarySkills.count(where: isMissing), item: .missing)
        sidebarRow("Unused", symbol: "moon.zzz", count: librarySkills.count(where: { store.usage[$0.id] == nil }), item: .unused)
        sidebarRow("Local Only", symbol: "folder.badge.person.crop", count: librarySkills.count(where: { skill in
          skill.isPersonal && !skill.copies.contains { $0.root.kind == .managed || $0.root.kind == .shared }
        }), item: .unmanaged)
      }
      Section("Skillsets") {
        ForEach(store.skillsets) { skillset in
          sidebarRow(skillset.name, symbol: "folder", count: skillset.skills.count, item: .skillset(skillset.id))
            .contextMenu {
              Button("Unassign and Delete Skillset", role: .destructive) { Task { await store.deleteSkillset(id: skillset.id) } }
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
      }
      Section("Available in") {
        ForEach(store.tools) { tool in
          sidebarRow(tool.name, symbol: tool.symbol, color: tool.color, count: librarySkills.count(where: { $0.availableIn.contains(tool) }), item: .tool(tool))
        }
      }
      if !store.managedRepos.isEmpty {
        Section("Sources") {
          ForEach(store.managedRepos, id: \.self) { repo in
            sidebarRow(repo, symbol: "shippingbox", count: librarySkills.count(where: { $0.managedRepos.contains(repo) }), item: .repo(repo))
              .contextMenu {
                Button("Refresh Source") {
                  Task {
                    do { try await store.redownloadRepo(name: repo) }
                    catch { store.errorMessage = error.localizedDescription }
                  }
                }
                Button("Remove Repository", role: .destructive) {
                  repoToRemove = repo
                }
              }
          }
        }
      }
      Section("Ideas") {
        sidebarRow("Suggestions", symbol: "lightbulb", count: store.suggestions.count, item: .suggestions)
        sidebarRow("Similar skills", symbol: "arrow.triangle.merge", count: listedPairs.count, item: .similar)
      }
    }
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
        store.removal?.title ?? "",
        isPresented: Binding(
          get: { store.removal != nil },
          set: { if !$0 { store.removal = nil } }
        ),
        presenting: store.removal
      ) { removal in
        Button("Move to Trash", role: .destructive) {
          Task { await store.remove(removal.copies) }
        }
      } message: { removal in
        Text(removal.message(tools: store.tools))
      }
      .sheet(item: $store.renaming) { RenameSheet(skill: $0) }
      .sheet(item: $store.editing) { EditSheet(skill: $0) }
  }
}
