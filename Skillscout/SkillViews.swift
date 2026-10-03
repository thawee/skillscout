import SwiftUI

struct SkillList: View {
  @Environment(AppStore.self) private var store
  let skills: [Skill]
  @Binding var selection: Set<Skill.ID>
  var skillsetID: UUID?

  var body: some View {
    List(skills, selection: $selection) { skill in
      SkillRow(skill: skill)
    }
    .contextMenu(forSelectionType: Skill.ID.self) { ids in
      if !ids.isEmpty {
        Menu("Add to skillset") {
          ForEach(store.skillsets) { skillset in
            Button(skillset.name) { store.setSkillMembership(ids, in: skillset.id, included: true) }
          }
        }
        .disabled(store.skillsets.isEmpty || store.isManagingSkillsets)
        if let skillsetID {
          Button("Remove from skillset") { store.setSkillMembership(ids, in: skillsetID, included: false) }
            .disabled(store.isManagingSkillsets)
        }
      }
      if ids.count == 1, let skill = store.skill(ids.first), skill.isPersonal {
        Button("Edit SKILL.md…") { store.editing = skill }
        Button("Rename…") { store.renaming = skill }
      }
      if let removal = removal(for: ids) {
        Button(ids.count == 1 ? "Uninstall" : "Uninstall selected skills…", role: .destructive) {
          store.removal = removal
        }
      }
    }
    .onDeleteCommand {
      if let skillsetID {
        store.setSkillMembership(selection, in: skillsetID, included: false)
      } else {
        store.removal = removal(for: selection)
      }
    }
    .overlay {
      if skills.isEmpty {
        ContentUnavailableView("No skills here", systemImage: "square.stack.3d.up.slash")
      }
    }
    .navigationSplitViewColumnWidth(min: 320, ideal: 400)
  }

  private func removal(for ids: Set<Skill.ID>) -> Removal? {
    let removable = ids.compactMap { store.skill($0) }.filter(\.isPersonal)
    guard !removable.isEmpty else { return nil }
    if ids.count == 1 { return .uninstall(removable[0]) }
    return .uninstall(removable, selectedCount: ids.count)
  }
}

struct SkillRow: View {
  @Environment(AppStore.self) private var store
  let skill: Skill

  var body: some View {
    let activeTools = store.tools.filter { skill.availableIn.contains($0) }
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(skill.name)
          .font(.body.weight(.semibold))
          .lineLimit(1)
        Spacer()
        if let usage = store.usage[skill.id] {
          Text("^[\(usage.chats) chat](inflect: true)")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
        }
      }
      if !skill.description.isEmpty {
        Text(skill.description)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      HStack(spacing: 4) {
        if activeTools.isEmpty {
          Text("Not added to a tool")
            .font(.caption)
            .foregroundStyle(.tertiary)
        } else {
          ForEach(Array(activeTools.prefix(2))) { tool in ToolBadge(tool: tool) }
          if activeTools.count > 2 {
            Text("+\(activeTools.count - 2)")
              .font(.caption2.weight(.semibold))
              .fixedSize(horizontal: true, vertical: false)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Capsule().fill(.quaternary))
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
  @State private var content = ""
  @State private var review: SkillReview?
  @AppStorage("lookbackDays") private var lookbackDays = 60

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        VStack(alignment: .leading, spacing: 6) {
          Text(skill.name)
            .font(.largeTitle.bold())
          if !skill.description.isEmpty {
            Text(skill.description)
              .font(.title3)
              .foregroundStyle(.secondary)
          }
        }
        .textSelection(.enabled)

        DetailSection("Installation") {
          installations
        }
        if let review {
          DetailSection("Contents") {
            VStack(alignment: .leading, spacing: 8) {
              Text("\(review.files.count == 1 ? "1 file" : "\(review.files.count) files") from a downloaded repository: \(review.summary.lowercased()).")
                .foregroundStyle(.secondary)
              ReviewFindingsView(review: review)
            }
          }
        }
        if !store.skillsets.isEmpty {
          DetailSection("Skillsets") {
            ForEach(store.skillsets) { skillset in
              Toggle(skillset.name, isOn: Binding(
                get: { skillset.skills.contains(skill.id) },
                set: { included in store.setSkillMembership([skill.id], in: skillset.id, included: included) }
              ))
              .disabled(store.isManagingSkillsets)
            }
          }
        }
        DetailSection("Usage") {
          usageSummary
        }
        DetailSection("What it does") {
          explanation
        }
        DetailSection("SKILL.md") {
          file
        }
      }
      .padding(28)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task(id: skill.primary) {
      content = (try? String(contentsOf: skill.skillFile, encoding: .utf8)) ?? ""
      review = skill.copies.first(where: SkillInstaller.isFromLibrary).map { SkillReview.inspect($0.resolved) }
    }
  }

  @ViewBuilder
  private var usageSummary: some View {
    if let usage = store.usage[skill.id] {
      VStack(alignment: .leading, spacing: 10) {
        Text("Used in ^[\(usage.chats) chat](inflect: true) in the last \(lookbackDays) days, most recently \(usage.lastUsed, format: .relative(presentation: .named)).")
        HStack(spacing: 14) {
          ForEach(Tool.allCases.filter { usage.byTool[$0] != nil }) { tool in
            HStack(spacing: 5) {
              ToolBadge(tool: tool)
              Text("\(usage.byTool[tool] ?? 0)")
                .font(.callout)
                .monospacedDigit()
            }
          }
        }
        if !usage.topProjects.isEmpty {
          Text("Mostly in \(usage.topProjects.formatted(.list(type: .and)))")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    } else {
      Text("Not used in the last \(lookbackDays) days.")
        .foregroundStyle(.secondary)
    }
    Text("A use is a chat where the agent read this skill, or where you attached it yourself.")
      .font(.caption)
      .foregroundStyle(.tertiary)
  }

  @ViewBuilder
  private var explanation: some View {
    let key = skill.primary.contentHash
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
        Task { await store.explain(skill) }
      } label: {
        Label("Explain with AI", systemImage: "sparkles")
      }
    }
  }

  private var installations: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !store.tools.isEmpty {
        if skill.isBuiltInOnly {
          Text("Built-in skills stay with their original tool.")
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
          Menu(skill.isPluginOnly ? "Copy to tool…" : "Add to tool…") {
            let sources = SkillInstaller.installableSources(for: skill)
            ForEach(store.tools) { tool in
              if sources.count <= 1 {
                Button(skill.availableIn.contains(tool) ? "\(tool.name) (installed)" : tool.name) { Task { await store.add(skill, to: tool) } }
              } else {
                Menu(skill.availableIn.contains(tool) ? "\(tool.name) (installed)" : tool.name) {
                  ForEach(sources) { source in
                    Button("\(source.sourceLabel) · \(Paths.abbreviate(source.resolved))") {
                      Task { await store.add(skill, to: tool, from: source) }
                    }
                  }
                }
              }
            }
          }
        }
      }
      let created = skill.created(usage: store.usage[skill.id])
      if created != .distantPast {
        Text("Created \(created, format: .dateTime.day().month(.wide).year())")
          .foregroundStyle(.secondary)
      }
      ForEach(Array(installationGroups.enumerated()), id: \.offset) { _, copies in
        let source = copies.first(where: { !$0.isSymlink }) ?? copies[0]
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(source.sourceLabel).font(.callout.weight(.semibold))
            Spacer()
            Menu {
              Button("Show source in Finder") { Finder.reveal(source.folder) }
              if skill.removableCopies.contains(source) {
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
          Text("\(copies.count) \(copies.count == 1 ? "location" : "locations") · \(Paths.abbreviate(source.resolved))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(source.resolved.path)
          DisclosureGroup("Show locations") {
            ForEach(copies) { copy in
              VStack(alignment: .leading, spacing: 3) {
                HStack {
                  Text(copy.root.label).font(.caption.weight(.medium))
                  Spacer()
                  Button("Finder") { Finder.reveal(copy.folder) }.buttonStyle(.link)
                  if skill.removableCopies.contains(copy) {
                    Button("Remove…") { store.removal = .copy(copy, of: skill) }.buttonStyle(.link)
                  }
                }
                Text(copy.isSymlink ? "\(Paths.abbreviate(copy.folder)) → \(Paths.abbreviate(copy.resolved))" : Paths.abbreviate(copy.folder))
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
      if skill.copiesDiffer {
        Label("These copies have different content, so editing one won't update the others.", systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.orange)
      }
      if skill.isPersonal {
        Button("Rename…") { store.renaming = skill }
        if skill.removableCopies.count > 1 {
          Button("Remove all user copies", role: .destructive) { store.removal = .uninstall(skill) }
        }
        if !skill.copies.contains(where: { $0.root.kind == .managed || $0.root.kind == .shared }) {
          Button("Move to Central") {
            Task { await store.moveToCentral(skill) }
          }
        }
      } else if let plugin = skill.copies.first(where: { $0.root.kind == .plugin }) {
        Text("It comes from the \(plugin.sourceLabel), so uninstall the plugin to remove it.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var installationGroups: [[SkillCopy]] {
    var seen = Set<String>()
    return skill.copies.compactMap { copy in
      guard seen.insert(copy.resolved.path).inserted else { return nil }
      return skill.copies.filter { $0.resolved.path == copy.resolved.path }
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
      Text("Loaded by")
        .font(.caption)
        .foregroundStyle(.secondary)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 4) {
          ForEach(readers) { tool in
            ToolBadge(tool: tool).fixedSize()
          }
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78, maximum: 110), spacing: 4, alignment: .leading)], alignment: .leading, spacing: 4) {
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
        if skill.isPersonal {
          Button("Edit") { store.editing = skill }
        }
        Button("Open in editor") { Finder.open(skill.skillFile) }
      }
      .buttonStyle(.link)
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
  let skills: [Skill]
  let copies: [SkillCopy]
  let selectedCount: Int

  static func uninstall(_ skill: Skill) -> Removal {
    Removal(skills: [skill], copies: skill.removableCopies, selectedCount: 1)
  }

  static func uninstall(_ skills: [Skill], selectedCount: Int) -> Removal {
    var seen = Set<String>()
    let ordered = skills.sorted { $0.name < $1.name }
    let copies = ordered.flatMap(\.removableCopies)
      .filter { seen.insert($0.folder.standardizedFileURL.path).inserted }
      .sorted { $0.folder.pathComponents.count > $1.folder.pathComponents.count }
    return Removal(skills: ordered, copies: copies, selectedCount: selectedCount)
  }

  static func copy(_ copy: SkillCopy, of skill: Skill) -> Removal {
    Removal(skills: [skill], copies: skill.copiesGoing(with: copy), selectedCount: 1)
  }

  var title: String {
    if selectedCount > 1 {
      return "Uninstall \(skills.count) selected \(skills.count == 1 ? "skill" : "skills")?"
    }
    let skill = skills[0]
    if copies.count == skill.copies.count { return "Uninstall \(skill.name)?" }
    if copies.count > 1 { return "Remove \(skill.name) from \(copies.count) locations?" }
    return "Remove \(skill.name) from \(Paths.abbreviate(copies[0].root.url))?"
  }

  func message(tools: [Tool]) -> String {
    if selectedCount > 1 {
      var sentences = ["Skillscout moves \(copies.count) user-managed folders or links to the Trash."]
      let skipped = selectedCount - skills.count
      if skipped > 0 {
        sentences.append("\(skipped) selected \(skipped == 1 ? "skill has" : "skills have") no removable copies and will be kept.")
      }
      let losing = tools.filter { tool in
        skills.contains { $0.toolsLosing($0.removableCopies).contains(tool) }
      }
      if !losing.isEmpty {
        sentences.append("\(losing.map(\.name).formatted(.list(type: .and))) will stop loading at least one selected skill.")
      }
      return sentences.joined(separator: " ")
    }
    let skill = skills[0]
    let folders = copies.map { Paths.abbreviate($0.root.url) }
    var sentences = ["Skillscout moves it to the Trash from \(folders.formatted(.list(type: .and)))."]

    let losing = tools.filter(skill.toolsLosing(copies).contains)
    if losing.isEmpty {
      sentences.append("Your agents still load it from another folder.")
    } else if losing == tools.filter(skill.availableIn.contains) {
      sentences.append("None of your agents will load it anymore.")
    } else {
      sentences.append("\(losing.map(\.name).formatted(.list(type: .and))) will stop loading it.")
    }

    let targets = skill.linkTargetsKept(copies)
    if !targets.isEmpty {
      let links = copies.count(where: { $0.isSymlink && targets.contains($0.resolved) })
      sentences.append(
        "\(links == 1 ? "The link points" : "The links point") to \(targets.map(Paths.abbreviate).formatted(.list(type: .and))), "
          + "\(targets.count == 1 ? "which stays where it is" : "which stay where they are")."
      )
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
    var sentences = ["Skillscout renames \(what.formatted(.list(type: .and))), and changes the name in SKILL.md."]

    let targets = skill.linkTargetsKept(skill.removableCopies)
    if !targets.isEmpty {
      sentences.append("\(targets.map(Paths.abbreviate).formatted(.list(type: .and))), where the links point, \(targets.count == 1 ? "keeps its" : "keep their") folder name.")
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
    var sentences = ["Skillscout saves it to \(edit.files.map(Paths.abbreviate).formatted(.list(type: .and)))."]
    if !edit.otherFiles.isEmpty {
      let one = edit.otherFiles.count == 1
      sentences.append("\(edit.otherFiles.map(Paths.abbreviate).formatted(.list(type: .and))) \(one ? "has" : "have") other text, so \(one ? "it stays as it is" : "they stay as they are").")
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
