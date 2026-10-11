import SwiftUI

struct SuggestionList: View {
  @Environment(AppStore.self) private var store
  let suggestions: [Suggestion]
  @Binding var selection: Suggestion.ID?

  var body: some View {
    List(suggestions, selection: $selection) { suggestion in
      SuggestionRow(suggestion: suggestion)
    }
    .overlay {
      if suggestions.isEmpty {
        ContentUnavailableView {
          Label(store.isAnalyzing ? "Analyzing…" : "No suggestions yet", systemImage: "lightbulb")
        } description: {
          Text(store.isAnalyzing
            ? "Reading your \(min(store.prompts.count, Analyzer.maxMessages)) most recent messages. This takes a minute or two."
            : "Skillscout reads your recent messages and finds tasks you ask for again and again.")
        } actions: {
          if !store.isAnalyzing {
            Button("Analyze now") { Task { await store.analyze() } }
              .disabled(store.prompts.isEmpty)
          }
        }
      }
    }
    .navigationSplitViewColumnWidth(min: 320, ideal: 400)
  }
}

struct SuggestionRow: View {
  @Environment(AppStore.self) private var store
  let suggestion: Suggestion

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(suggestion.title)
          .font(.body.weight(.semibold))
          .lineLimit(1)
        Spacer()
        if suggestion.savedTo != nil {
          Text("Saved").font(.caption2.weight(.semibold)).foregroundStyle(.green)
        } else if suggestion.draft != nil {
          Text("Draft").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
      }
      Text(suggestion.summary)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)
      HStack(spacing: 4) {
        Text("Asked \(suggestion.examples.count) times")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
      }
      WrapLayout(spacing: 4) {
        ForEach(store.tools.filter(suggestion.tools.contains)) { ToolBadge(tool: $0) }
      }
    }
    .padding(.vertical, 4)
  }
}

private enum DraftDestination: Hashable {
  case library, all, tool(Tool)
}

struct SuggestionDetail: View {
  @Environment(AppStore.self) private var store
  let suggestion: Suggestion
  @State private var destination = DraftDestination.library
  @State private var isSaving = false

  private var saveTarget: SaveTarget {
    switch destination {
    case .library: .library
    case .all: .everywhere(store.tools)
    case .tool(let tool): .tool(tool)
    }
  }

  private var destinationNote: String {
    switch destination {
    case .library: "Saves to your library without making the skill available to tools. Add it to a tool or skillset when you are ready."
    case .all: saveEverywhereNote
    case .tool(let tool):
      "Saves in \(Paths.abbreviate(tool.skillsFolder)). This folder is read by \(store.tools.filter { candidate in SkillRoot.all.contains { $0.url == tool.skillsFolder && $0.readBy.contains(candidate) } }.map(\.name).formatted())."
    }
  }

  private var isDrafting: Bool { store.busy.contains("draft:\(suggestion.id)") }

  private var saveEverywhereNote: String {
    let shared = SkillRoot.all[0]
    let readers = store.tools.filter(shared.readBy.contains).map(\.name)
    let links = SkillInstaller.linkTargets(for: store.tools).map { "\(Paths.abbreviate($0.skillsFolder)) for \($0.name)" }
    var note = "All tools saves it in \(Paths.abbreviate(shared.url))"
    if !readers.isEmpty { note += ", which \(readers.formatted(.list(type: .and))) read" }
    if !links.isEmpty { note += ", and links it into \(links.formatted(.list(type: .and)))" }
    return note + "."
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        VStack(alignment: .leading, spacing: 8) {
          Text(suggestion.title)
            .font(.largeTitle.bold())
          Text(suggestion.summary)
            .font(.title3)
          Text(suggestion.why)
            .foregroundStyle(.secondary)
          HStack(spacing: 6) {
            Text("Asked \(suggestion.examples.count) times in ^[\(suggestion.projects.count) project](inflect: true)")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          WrapLayout(spacing: 4) {
            ForEach(store.tools.filter(suggestion.tools.contains)) { ToolBadge(tool: $0) }
          }
        }
        .textSelection(.enabled)

        DetailSection("Skill") {
          draftSection
        }
        DetailSection("Messages that match") {
          examples
        }
        Button("Dismiss this idea", role: .destructive) {
          store.dismiss(suggestion.id)
        }
      }
      .padding(28)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onChange(of: store.tools) {
      if case .tool(let tool) = destination, !store.tools.contains(tool) { destination = .library }
      if destination == .all, store.tools.isEmpty { destination = .library }
    }
  }

  @ViewBuilder
  private var draftSection: some View {
    if let draft = suggestion.draft {
      VStack(alignment: .leading, spacing: 10) {
        PlainTextEditor(text: Binding(get: { draft }, set: { store.updateDraft(suggestion.id, $0) }))
          .frame(minHeight: 380)
          .padding(8)
          .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
          .disabled(suggestion.savedTo != nil)

        if let saved = suggestion.savedTo {
          Label("Saved to \(Paths.describe(URL(fileURLWithPath: saved)))", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
          ForEach(store.suggestionSaveIssues[suggestion.id] ?? [], id: \.self) { issue in
            Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
          }
          if let skill = store.savedSkill(for: suggestion) {
            Button("Open skill") { store.revealRequest = skill.id }
            SkillSelectionActions(skills: [skill])
            Text(skill.availableIn.intersection(store.tools).isEmpty ? "Not available to enabled tools."
              : "Available to \(store.tools.filter(skill.availableIn.contains).map(\.name).formatted()).")
              .font(.callout).foregroundStyle(.secondary)
            if let usage = store.usage[skill.id] {
              Text("Recorded in \(usage.chats) chats in \(store.usageScopeDescription).")
                .font(.callout).foregroundStyle(.secondary)
            } else {
              Text("No recorded use in \(store.usageScopeDescription). Your retained chats may not include every use.")
                .font(.callout).foregroundStyle(.secondary)
            }
          } else {
            Text("The saved skill is no longer in the scanned library. Restore its source to open it again.")
              .font(.callout).foregroundStyle(.secondary)
          }
        } else {
          ChoiceChips(title: "Save destination", options:
            [ChoiceOption(value: DraftDestination.library, title: "Library only", symbol: "books.vertical")] + (store.tools.isEmpty ? [] : [ChoiceOption(value: DraftDestination.all, title: "All enabled tools", symbol: "globe")])
              + store.tools.map { ChoiceOption(value: DraftDestination.tool($0), title: $0.name, symbol: $0.symbol, tint: $0.color) },
            selection: $destination)
          Text(destinationNote).font(.caption).foregroundStyle(.secondary)
          if case .tool(let tool) = destination {
            DisabledReaderNotice(readers: Set(SkillRoot.all.filter { $0.url == tool.skillsFolder }.flatMap(\.readBy)))
          } else if destination == .all { DisabledReaderNotice(readers: Set(SkillRoot.all[0].readBy)) }
          HStack(spacing: 10) {
            Button("Save skill") {
              Task {
                isSaving = true
                await store.save(suggestion.id, to: saveTarget)
                isSaving = false
              }
            }
            .buttonStyle(.borderedProminent).disabled(isSaving)
            Button("Redraft") { Task { await store.draft(suggestion.id) } }
              .disabled(isDrafting || isSaving)
            if isDrafting || isSaving { ProgressView().controlSize(.small) }
          }
        }
      }
    } else if isDrafting {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Writing the SKILL.md…").foregroundStyle(.secondary)
      }
    } else {
      Button {
        Task { await store.draft(suggestion.id) }
      } label: {
        Label("Draft the skill with AI", systemImage: "sparkles")
      }
    }
  }

  private var examples: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(suggestion.examples.filter { store.tools.contains($0.tool) }.prefix(40)) { prompt in
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            ToolBadge(tool: prompt.tool)
            Text(prompt.project)
              .font(.caption.weight(.medium))
            Text(prompt.date, format: .dateTime.day().month().year())
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Text(prompt.text)
            .font(.callout)
            .lineLimit(6)
            .textSelection(.enabled)
        }
        Divider()
      }
    }
  }
}
