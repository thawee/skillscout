import SwiftUI

struct SimilarList: View {
  let pairs: [SimilarPair]
  @Binding var selection: SimilarPair.ID?

  var body: some View {
    List(pairs, selection: $selection) { pair in
      SimilarRow(pair: pair)
    }
    .overlay {
      if pairs.isEmpty {
        ContentUnavailableView(
          "No similar skills",
          systemImage: "arrow.triangle.merge",
          description: Text("Skillscout compares the words your skills use. When two of them cover the same ground, they show up here, so you can merge them.")
        )
      }
    }
    .navigationSplitViewColumnWidth(min: 320, ideal: 400)
  }
}

struct SimilarRow: View {
  let pair: SimilarPair

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(pair.first)
          .font(.body.weight(.semibold))
          .lineLimit(1)
        Image(systemName: "plus")
          .font(.caption2.weight(.bold))
          .foregroundStyle(.tertiary)
        Text(pair.second)
          .font(.body.weight(.semibold))
          .lineLimit(1)
        Spacer()
        Text("\(pair.score, format: .percent.precision(.fractionLength(0))) alike")
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .fixedSize()
      }
      Text("Both mention \(pair.sharedWords.formatted(.list(type: .and)))")
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding(.vertical, 4)
  }
}

struct SimilarDetail: View {
  @Environment(AppStore.self) private var store
  let pair: SimilarPair
  @State private var keep: Skill.ID
  @State private var plan: SkillInstaller.MergePlan?
  @State private var planProblem: String?
  @State private var confirming = false

  init(pair: SimilarPair, keep: Skill.ID) {
    self.pair = pair
    _keep = State(initialValue: keep)
  }

  private var isDrafting: Bool { plan.map { store.busy.contains("merge:\($0.id)") } ?? false }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        VStack(alignment: .leading, spacing: 6) {
          Text("\(pair.first) and \(pair.second)")
            .font(.largeTitle.bold())
          Text("\(pair.score, format: .percent.precision(.fractionLength(0))) alike. Both mention \(pair.sharedWords.formatted(.list(type: .and))).")
            .font(.title3)
            .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)

        HStack(alignment: .top, spacing: 14) {
          ForEach([pair.first, pair.second].compactMap(store.skill)) { skill in
            SkillCard(skill: skill)
          }
        }
        .fixedSize(horizontal: false, vertical: true)

        DetailSection("Merge") {
          mergeSection
        }

        VStack(alignment: .leading, spacing: 4) {
          Button("They're different skills") { store.dismissPair(pair) }
          Text("Skillscout won't pair them again.")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(28)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task(id: keep) { makePlan() }
    .onChange(of: store.skills) { makePlan() }
    .confirmationDialog(
      plan.map { "Merge \($0.merged.name) into \($0.kept.name)?" } ?? "",
      isPresented: $confirming,
      presenting: plan
    ) { plan in
      Button("Merge") { Task { await store.merge(plan) } }
    } message: { plan in
      Text(plan.message(tools: store.tools))
    }
  }

  private func makePlan() {
    guard let kept = store.skill(keep), let merged = store.skill(pair.other(than: keep)) else { return }
    do {
      plan = try SkillInstaller.planMerge(merged, into: kept)
      planProblem = nil
    } catch {
      plan = nil
      planProblem = error.localizedDescription
    }
  }

  @ViewBuilder
  private var mergeSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Text("Keep the name")
        Picker("Keep the name", selection: $keep) {
          Text(pair.first).tag(pair.first)
          Text(pair.second).tag(pair.second)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }

      if let planProblem {
        Text(planProblem)
          .foregroundStyle(.secondary)
      } else if let plan {
        Text(plan.summary(tools: store.tools))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if let draft = store.mergeDrafts[plan.id] {
          HStack(spacing: 10) {
            Button("Merge into \(plan.kept.name)") { confirming = true }
              .disabled(isDrafting)
            Button("Redraft") { Task { await store.draftMerge(plan) } }
              .disabled(isDrafting)
            if isDrafting {
              ProgressView().controlSize(.small)
            }
          }
          PlainTextEditor(text: Binding(get: { draft }, set: { store.mergeDrafts[plan.id] = $0 }))
            .frame(minHeight: 380)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        } else if isDrafting {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Writing the merged SKILL.md…").foregroundStyle(.secondary)
          }
        } else {
          Button {
            Task { await store.draftMerge(plan) }
          } label: {
            Label("Merge with AI", systemImage: "sparkles")
          }
          Text("AI writes one SKILL.md from both. You can read and edit it before anything changes.")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
    }
  }
}

private struct SkillCard: View {
  @Environment(AppStore.self) private var store
  @AppStorage("lookbackDays") private var lookbackDays = 60
  let skill: Skill

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(skill.name)
        .font(.headline)
      if !skill.description.isEmpty {
        Text(skill.description)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(6)
      }
      Spacer(minLength: 0)
      AvailabilityBadges(available: skill.availableIn, tools: store.tools)
      HStack {
        if let usage = store.usage[skill.id] {
          Text("Used in ^[\(usage.chats) chat](inflect: true)")
        } else {
          Text("Not used in the last \(lookbackDays) days")
        }
        Spacer()
        Button("Open SKILL.md") { Finder.open(skill.skillFile) }
          .buttonStyle(.link)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
  }
}

extension SkillInstaller.MergePlan {
  /// What happens, in two sentences, before you ask AI for the merged SKILL.md.
  func summary(tools: [Tool]) -> String {
    var sentences = ["\(kept.name) keeps its \(folders.count == 1 ? "folder" : "folders") and gets one SKILL.md written from both. \(merged.name) goes to the Trash."]
    let gained = toolsGained(tools)
    if !gained.isEmpty {
      sentences.append("\(gained.map(\.name).formatted(.list(type: .and))) will load \(kept.name) instead.")
    }
    return sentences.joined(separator: " ")
  }

  /// Every change, with the folders, for the confirmation.
  func message(tools: [Tool]) -> String {
    let places = folders.map(Paths.abbreviate).formatted(.list(type: .and))
    var sentences = ["Skillscout writes the merged SKILL.md into \(places), and moves the old \(folders.count == 1 ? "one" : "ones") to the Trash."]
    if !copiedFiles.isEmpty {
      sentences.append("It copies over \(count(copiedFiles.count, "file")) from \(merged.name).")
    }
    if skippedFiles.count == 1 {
      sentences.append("\(skippedFiles[0]) from \(merged.name) stays out, because \(kept.name) has its own.")
    } else if !skippedFiles.isEmpty {
      sentences.append("\(skippedFiles.count) files from \(merged.name) stay out, because \(kept.name) has its own at the same paths.")
    }

    let removedFrom = merged.removableCopies.map { Paths.abbreviate($0.root.url) }.formatted(.list(type: .and))
    sentences.append("\(merged.name) goes to the Trash from \(removedFrom).")
    let targets = merged.linkTargetsKept(merged.removableCopies)
    if !targets.isEmpty {
      sentences.append("\(targets.map(Paths.abbreviate).formatted(.list(type: .and))), where its links point, \(targets.count == 1 ? "stays where it is" : "stay where they are").")
    }

    let gained = toolsGained(tools)
    if !gained.isEmpty {
      let linked = links.map { Paths.abbreviate($0.deletingLastPathComponent()) }.formatted(.list(type: .and))
      sentences.append("A link in \(linked) makes \(gained.map(\.name).formatted(.list(type: .and))) load \(kept.name) instead.")
    }
    return sentences.joined(separator: " ")
  }

  private func count(_ number: Int, _ word: String) -> String {
    "\(number) \(word)\(number == 1 ? "" : "s")"
  }
}
