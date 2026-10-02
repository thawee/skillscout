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
        ForEach(suggestion.tools) { ToolBadge(tool: $0) }
      }
    }
    .padding(.vertical, 4)
  }
}

struct SuggestionDetail: View {
  @Environment(AppStore.self) private var store
  let suggestion: Suggestion

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
            ForEach(suggestion.tools) { ToolBadge(tool: $0) }
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
          Label("Saved to \(Paths.abbreviate(URL(fileURLWithPath: saved)))", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else {
          HStack(spacing: 10) {
            Menu("Save to all tools") {
              ForEach(store.tools) { tool in
                Button("Save to \(tool.name) only") {
                  Task { await store.save(suggestion.id, to: .tool(tool)) }
                }
              }
            } primaryAction: {
              Task { await store.save(suggestion.id, to: .everywhere(store.tools)) }
            }
            .fixedSize()
            Button("Redraft") { Task { await store.draft(suggestion.id) } }
              .disabled(isDrafting)
            if isDrafting {
              ProgressView().controlSize(.small)
            }
          }
          Text(saveEverywhereNote)
            .font(.caption)
            .foregroundStyle(.secondary)
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
      ForEach(suggestion.examples.prefix(40)) { prompt in
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
