import SwiftUI

struct RepoUpdateSheet: View {
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let update: RepoUpdate
  @State private var phase: Phase = .decisions
  @State private var resolutions: [String: RepoFileResolution] = [:]
  @State private var mergeDrafts: [String: String] = [:]
  @State private var selectedPath = ""
  @State private var merging: RepoUpdateFile?
  @State private var errorMessage: String?

  private enum Phase {
    case decisions, preparing(UUID), review(ResolvedRepoUpdate), applying(ResolvedRepoUpdate), closed

    var isPreparing: Bool { if case .preparing = self { true } else { false } }
    var isApplying: Bool { if case .applying = self { true } else { false } }
    var resolved: ResolvedRepoUpdate? {
      switch self { case .review(let value), .applying(let value): value; default: nil }
    }
  }

  private var files: [RepoUpdateFile] { update.files.filter { $0.status != .unchanged } }
  private var selectedFile: RepoUpdateFile? { files.first { $0.path == selectedPath } }
  private var unresolvedCount: Int {
    files.filter { $0.status == .conflict && resolutions[$0.path] == nil }.count
  }
  private var incomingLabel: String {
    let source = update.source.lowercased()
    if URLComponents(string: source)?.host == "github.com" || source.hasPrefix("git@github.com:") { return "GitHub" }
    return "Incoming"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(phase.resolved == nil ? "Choose changes for \(update.name)" : "Review final update for \(update.name)")
        .font(.headline)
      VStack(alignment: .leading, spacing: 2) {
        Text(update.source)
        Text(update.selectedRef.label)
        if let new = update.newCommit {
          Text(update.oldCommit.map { "Commit \($0.prefix(12)) → \(new.prefix(12))" } ?? "Commit \(new.prefix(12))")
        }
      }
      .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)

      if let resolved = phase.resolved {
        RepositoryFinalReviewView(resolved: resolved)
      } else {
        decisions
      }
      if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
      controls
    }
    .padding(20)
    .frame(minWidth: 640, idealWidth: 820, maxWidth: 960, minHeight: 600, idealHeight: 720, maxHeight: 850)
    .interactiveDismissDisabled(phase.isApplying || store.isApplyingRepositoryUpdate)
    .onAppear { selectedPath = files.first(where: { $0.status == .conflict })?.path ?? files.first?.path ?? "" }
    .onDisappear { abandon() }
    .sheet(item: $merging) { file in
      RepositoryMergeEditor(file: file, incomingLabel: incomingLabel, text: Binding(
        get: { mergeDrafts[file.path] ?? file.suggestedMerge ?? file.localText ?? file.incomingText ?? "" },
        set: { mergeDrafts[file.path] = $0 }
      )) { text in
        resolutions[file.path] = .merge(text)
        merging = nil
      }
    }
  }

  private var decisions: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Your local edits stay when they can be combined safely. Choose an outcome for each conflict, then review the final files before applying.")
          .font(.callout).foregroundStyle(.secondary)
        if files.isEmpty {
          Text("There are no file changes to choose.").font(.callout)
        } else {
          Text(unresolvedCount == 0 ? "All conflicts have choices." : "\(unresolvedCount) \(unresolvedCount == 1 ? "conflict needs" : "conflicts need") a choice.")
            .font(.callout).foregroundStyle(unresolvedCount == 0 ? Color.secondary : Color.orange)
          SearchChoice(title: "Compare file", options: files.map {
            ChoiceOption(value: $0.path, title: $0.path, detail: decisionLabel($0),
              symbol: $0.status == .conflict ? "exclamationmark.triangle" : "doc.text")
          }, selection: $selectedPath)
          if let file = selectedFile {
            VStack(alignment: .leading, spacing: 10) {
              Text(decisionLabel(file)).font(.subheadline.weight(.semibold))
              if let reason = file.reason { Text(reason).font(.callout).foregroundStyle(.secondary) }
              LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 8) {
                decisionButton("Keep mine", file: file, resolution: .keepMine)
                decisionButton("Use \(incomingLabel)", file: file, resolution: .useIncoming)
                if file.canMerge {
                  Button {
                    merging = file
                  } label: {
                    Label(isMerged(file) ? "Edit merge" : "Merge…", systemImage: isMerged(file) ? "checkmark" : "pencil")
                  }
                  .accessibilityIdentifier("repo-update.merge")
                }
                if resolutions[file.path] != nil && file.status != .conflict {
                  Button("Use automatic choice") { resolutions[file.path] = nil }
                }
              }
              ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) { comparison(file) }
                VStack(alignment: .leading, spacing: 10) { comparison(file) }
              }
              if case .merge(let text) = resolutions[file.path] {
                RepositoryTextPanel(title: "Your merged result", text: text, unavailable: "")
              }
            }
          }
        }
        Divider()
        RepositoryUpdateImpactView(update: update)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .disabled(phase.isPreparing)
  }

  @ViewBuilder
  private func comparison(_ file: RepoUpdateFile) -> some View {
    RepositoryTextPanel(title: "Base", text: file.baseText,
      unavailable: "Base text is unavailable. This can be a new file, folder, binary or symbolic link, an oversized file, or a missing saved baseline.")
    RepositoryTextPanel(title: "Mine", text: file.localText,
      unavailable: file.localExists ? "This version has no displayable text. It may be a folder, binary, symbolic link, or oversized file." : "Deleted or absent in your Library copy.")
    RepositoryTextPanel(title: incomingLabel, text: file.incomingText,
      unavailable: file.incomingExists ? "This version has no displayable text. It may be a folder, binary, symbolic link, or oversized file." : "Deleted or absent in the incoming version.")
  }

  private func decisionButton(_ title: String, file: RepoUpdateFile, resolution: RepoFileResolution) -> some View {
    Button { resolutions[file.path] = resolution } label: {
      HStack(spacing: 5) {
        if resolutions[file.path] == resolution { Image(systemName: "checkmark") }
        Text(title)
      }
    }
    .tint(resolutions[file.path] == resolution ? .accentColor : nil)
    .accessibilityValue(resolutions[file.path] == resolution ? "Selected" : "Not selected")
    .accessibilityIdentifier(resolution == .keepMine ? "repo-update.keep-mine" : "repo-update.use-incoming")
  }

  private func isMerged(_ file: RepoUpdateFile) -> Bool {
    if case .merge = resolutions[file.path] { true } else { false }
  }

  private func decisionLabel(_ file: RepoUpdateFile) -> String {
    switch resolutions[file.path] {
    case .keepMine: return file.localExists ? "Keep your Library version" : "Keep your deletion"
    case .useIncoming: return file.incomingExists ? "Use the \(incomingLabel) version" : "Use the incoming deletion"
    case .merge: return "Use your merged text"
    case nil:
      switch file.status {
      case .unchanged: return "Unchanged"
      case .incoming: return "Incoming change"
      case .local: return "Local edit preserved automatically"
      case .merged: return "Merged automatically"
      case .conflict: return "Needs your choice"
      }
    }
  }

  private var controls: some View {
    HStack {
      if phase.isPreparing { ProgressView("Preparing final review…").controlSize(.small) }
      if phase.isApplying { ProgressView("Applying update…").controlSize(.small) }
      Spacer()
      Button("Cancel", role: .cancel) { cancel() }
        .keyboardShortcut(.cancelAction)
        .disabled(phase.isApplying || store.isApplyingRepositoryUpdate)
      if let resolved = phase.resolved {
        Button("Back to choices") { backToChoices() }
          .disabled(phase.isApplying || store.isApplyingRepositoryUpdate)
          .accessibilityIdentifier("repo-update.back")
        Button("Apply update") { apply(resolved) }
          .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
          .disabled(phase.isApplying || store.isApplyingRepositoryUpdate || store.isManagingSkillsets)
          .accessibilityIdentifier("repo-update.apply")
      } else {
        Button("Review choices") { prepareReview() }
          .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
          .disabled(unresolvedCount > 0 || phase.isPreparing || store.isApplyingRepositoryUpdate)
          .accessibilityIdentifier("repo-update.review")
      }
    }
  }

  private func prepareReview() {
    let token = UUID()
    let choices = resolutions
    phase = .preparing(token)
    errorMessage = nil
    Task {
      do {
        let resolved = try await Task.detached { [update] in
          try SkillInstaller.resolveRepoUpdate(update, resolutions: choices)
        }.value
        guard case .preparing(let active) = phase, active == token,
              store.pendingRepoUpdate?.staged == update.staged else {
          SkillInstaller.discardRepoUpdate(resolved)
          return
        }
        phase = .review(resolved)
      } catch {
        guard case .preparing(let active) = phase, active == token else { return }
        errorMessage = error.localizedDescription
        phase = .decisions
      }
    }
  }

  private func backToChoices() {
    if let resolved = phase.resolved { SkillInstaller.discardRepoUpdate(resolved) }
    phase = .decisions
    errorMessage = nil
  }

  private func apply(_ resolved: ResolvedRepoUpdate) {
    phase = .applying(resolved)
    Task {
      await store.finishResolvedRepoUpdate(resolved)
      if store.pendingRepoUpdate?.staged == update.staged {
        phase = .review(resolved)
      } else {
        phase = .closed
        dismiss()
      }
    }
  }

  private func cancel() {
    abandon()
    dismiss()
  }

  private func abandon() {
    guard !phase.isApplying, !store.isApplyingRepositoryUpdate else { return }
    if let resolved = phase.resolved { SkillInstaller.discardRepoUpdate(resolved) }
    phase = .closed
    if store.pendingRepoUpdate?.staged == update.staged {
      Task {
        guard store.pendingRepoUpdate?.staged == update.staged else { return }
        await store.finishRepoUpdate(apply: false)
      }
    }
  }
}

private struct RepositoryTextPanel: View {
  let title: String
  let text: String?
  let unavailable: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.caption.weight(.semibold))
      ScrollView([.horizontal, .vertical]) {
        Text(text.map { $0.isEmpty ? "Empty file." : $0 } ?? unavailable)
          .font(text == nil ? .callout : .system(.callout, design: .monospaced))
          .foregroundStyle(text == nil ? .secondary : .primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(minHeight: 100, maxHeight: 190)
      .padding(8)
      .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
    .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
  }
}

private struct RepositoryMergeEditor: View {
  @Environment(\.dismiss) private var dismiss
  let file: RepoUpdateFile
  let incomingLabel: String
  @Binding var text: String
  let save: (String) -> Void
  @State private var reference: Reference = .mine

  private enum Reference: Hashable { case base, mine, incoming }

  private var referenceText: String? {
    switch reference {
    case .base: file.baseText
    case .mine: file.localText
    case .incoming: file.incomingText
    }
  }

  private var referenceTitle: String {
    switch reference { case .base: "Base"; case .mine: "Mine"; case .incoming: incomingLabel }
  }

  private var referenceUnavailable: String {
    switch reference {
    case .base: "Base text is unavailable. There may be no saved baseline or no displayable text."
    case .mine: file.localExists ? "Your version cannot be displayed as text." : "Deleted or absent in your Library copy."
    case .incoming: file.incomingExists ? "The incoming version cannot be displayed as text." : "Deleted or absent in the incoming version."
    }
  }

  private var validationMessage: String? {
    if text.utf8.count > RepositoryMerge.maxTextSize { return "Merged text must be no larger than 512 KiB." }
    if text.contains("\0") { return "Remove null characters before saving your merge." }
    if RepositoryMerge.hasMarkers(text) { return "Resolve every conflict marker before saving your merge." }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Merge \(file.path)").font(.headline).textSelection(.enabled)
      ChoiceChips(title: "Reference", options: [
        ChoiceOption(value: Reference.base, title: "Base"),
        ChoiceOption(value: Reference.mine, title: "Mine"),
        ChoiceOption(value: Reference.incoming, title: incomingLabel)
      ], selection: $reference)
      RepositoryTextPanel(title: referenceTitle, text: referenceText, unavailable: referenceUnavailable)
        .frame(height: 150)
      Text("Edit the complete final file. Remove the conflict markers and keep the text you want agents to read.")
        .font(.callout).foregroundStyle(.secondary)
      PlainTextEditor(text: $text)
        .frame(minHeight: 220)
        .accessibilityIdentifier("repo-update.merge-editor")
        .padding(8).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
      if let validationMessage { Text(validationMessage).font(.callout).foregroundStyle(.orange) }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save merge") { save(text) }
          .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
          .disabled(validationMessage != nil)
          .accessibilityIdentifier("repo-update.save-merge")
      }
    }
    .padding(20).frame(width: 680, height: 720)
  }
}

private struct RepositoryFinalReviewView: View {
  let resolved: ResolvedRepoUpdate
  @State private var selectedFile = ""
  @State private var fileText = "Choose a file to read its final contents."

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text("These are the final changes to your Library copy. Linked agents will read this result after you apply it.")
          .font(.callout).foregroundStyle(.secondary)
        fileGroup("Added", paths: resolved.added, symbol: "plus.circle")
        fileGroup("Changed", paths: resolved.changed, symbol: "pencil.circle")
        fileGroup("Removed", paths: resolved.removed, symbol: "minus.circle")
        if resolved.added.isEmpty && resolved.changed.isEmpty && resolved.removed.isEmpty {
          Text("Your Library files stay unchanged. The source version and saved baseline will advance.").font(.callout)
        }
        fileGroup("Your local edits preserved", paths: resolved.preservedLocalPaths, symbol: "person.crop.circle")
        fileGroup("Merged files", paths: resolved.mergedPaths, symbol: "arrow.triangle.merge")
        Divider()
        Text("Final content review").font(.subheadline.weight(.semibold))
        Text(resolved.review.summary).font(.callout).foregroundStyle(.secondary)
        ReviewFindingsView(review: resolved.review)
        if !resolved.review.files.isEmpty {
          SearchChoice(title: "Read file", options: resolved.review.files.map {
            ChoiceOption(value: $0.path, title: $0.path, detail: "\($0.size) bytes",
              symbol: $0.isScript ? "terminal" : "doc.text")
          }, selection: $selectedFile)
          RepositoryTextPanel(title: "Final contents", text: fileText, unavailable: "")
        }
        Divider()
        RepositoryUpdateImpactView(update: resolved.update, resolved: resolved)
        Text("The previous Library copy moves to the Trash. Your approved choices become the Library version.")
          .font(.callout).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onAppear {
      selectedFile = resolved.changed.first(where: { path in resolved.review.files.contains { $0.path == path } })
        ?? resolved.review.files.first?.path ?? ""
    }
    .task(id: selectedFile) {
      guard let file = resolved.review.files.first(where: { $0.path == selectedFile }) else { return }
      guard file.size <= RepositoryMerge.maxTextSize else {
        fileText = "This file is too large to display as text."
        return
      }
      let path = selectedFile
      let folder = resolved.staged
      fileText = "Reading final contents…"
      let contents = await Task.detached {
        guard let text = try? SkillContents.read(path, from: folder), !text.contains("\0") else {
          return "This file is binary or its text is unavailable."
        }
        return text
      }.value
      guard !Task.isCancelled else { return }
      fileText = contents
    }
  }

  @ViewBuilder
  private func fileGroup(_ title: String, paths: [String], symbol: String) -> some View {
    if !paths.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text("\(title) (\(paths.count))").font(.subheadline.weight(.semibold))
        ForEach(paths, id: \.self) { path in
          Label(path, systemImage: symbol).font(.callout.monospaced()).textSelection(.enabled)
        }
      }
    }
  }
}
