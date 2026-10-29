import AppKit
import SwiftUI

struct AddSourceView: View {
    @Binding var selection: RegistrySkill.ID?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @State private var sourceString = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Custom Skill Source").font(.headline)
            Text("Enter a repository URL or choose a local folder containing SKILL.md files.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Repository URL or folder path", text: $sourceString)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 350)
            Button("Choose Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let folder = panel.url { sourceString = folder.path }
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to Discover") {
                    do {
                        let source = try CustomRegistry.shared.add(repoURL: sourceString)
                        Task { await store.loadRegistry() }
                        selection = source // The RegistrySkill ID is its source.
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(sourceString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

/// The scripts and flagged lines of a skill review, for reading before adding or updating skills.
struct ReviewFindingsView: View {
  let review: SkillReview

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(review.scripts, id: \.path) { file in
        Label(file.path, systemImage: "terminal")
          .font(.callout.monospaced())
          .foregroundStyle(.orange)
      }
      ForEach(review.findings, id: \.self) { finding in
        VStack(alignment: .leading, spacing: 2) {
          Label("\(finding.reason) · \(finding.path):\(finding.line)",
                systemImage: finding.highRisk ? "exclamationmark.triangle.fill" : "info.circle")
            .font(.callout)
            .foregroundStyle(finding.highRisk ? .orange : .secondary)
          Text(finding.text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .textSelection(.enabled)
            .padding(.leading, 22)
        }
      }
    }
  }
}

struct ReviewedAddSheet: View {
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let request: PendingReviewedAdd

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Review \(request.skill.name) before adding it to \(request.tool.name)")
        .font(.headline)
      Text("This skill comes from a downloaded repository and has \(request.review.summary.lowercased()). \(request.tool.name) will follow its instructions, so read these before adding it.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ScrollView {
        ReviewFindingsView(review: request.review)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 280)
      HStack {
        Button("Show in Finder") { Finder.reveal(request.folder) }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Add Anyway") {
          dismiss()
          Task { if store.tools.contains(request.tool) { await store.add(request.skill, to: request.tool, from: request.source, reviewed: true) } }
        }.disabled(!store.tools.contains(request.tool))
      }
    }
    .onChange(of: store.tools) { if !store.tools.contains(request.tool) { dismiss() } }
    .padding(20)
    .frame(width: 520)
  }
}

/// Discovery's skills.sh choice: the results of the search you submit in the toolbar field. Nothing is sent
/// to skills.sh until you press Return or click Search.
struct SkillsDirectoryList: View {
  @Binding var search: String
  @Binding var selection: SkillsDirectory.Result.ID?
  @Environment(AppStore.self) private var store

  private var state: SkillsDirectorySearch { store.skillsDirectorySearch }
  private var trimmed: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
  /// Text in the search field that hasn't been searched yet.
  private var unsent: String? { trimmed.count >= 2 && trimmed != state.query ? trimmed : nil }

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
      Divider()
      content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onAppear { if search.isEmpty, !state.query.isEmpty { search = state.query } }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        if state.searching {
          ProgressView().controlSize(.small)
          Text("Searching for \u{201C}\(state.query)\u{201D}\u{2026}").lineLimit(1).truncationMode(.middle)
        } else if let results = state.results {
          Text(results.isEmpty ? "No results" : "\(results.count) results for \u{201C}\(state.query)\u{201D}")
            .lineLimit(1).truncationMode(.middle)
        } else {
          Text("Search the skills.sh directory")
        }
        Spacer(minLength: 6)
        if let unsent, !state.searching {
          Button("Search") { store.searchSkillsDirectory(unsent) }
            .controlSize(.small)
            .help("Search skills.sh for \u{201C}\(unsent)\u{201D}")
        }
      }
      .font(.callout.weight(.medium))
      Text("Press Return to search. Your search text is sent to skills.sh.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var content: some View {
    if let results = state.results, !results.isEmpty {
      List(results, selection: $selection) { row($0).tag($0.id) }
        .opacity(state.searching ? 0.5 : 1)
    } else if let error = state.error {
      ContentUnavailableView {
        Label("Couldn't reach skills.sh", systemImage: "wifi.exclamationmark")
      } description: {
        Text(error)
      } actions: {
        Button("Try again") { store.searchSkillsDirectory(state.query) }
      }
    } else if state.results != nil {
      ContentUnavailableView {
        Label("No skills match \u{201C}\(state.query)\u{201D}", systemImage: "magnifyingglass")
      } description: {
        Text("Try fewer or different words, such as a framework or a task.")
      }
    } else if state.searching {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView {
        Label("Find skills on skills.sh", systemImage: "globe")
      } description: {
        Text("Type what you need in the search field and press Return. Add a result's repository to Discovery to preview its skills and add them to Library.")
      } actions: {
        if let unsent { Button("Search for \u{201C}\(unsent)\u{201D}") { store.searchSkillsDirectory(unsent) } }
      }
    }
  }

  private func row(_ result: SkillsDirectory.Result) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(result.name).font(.headline).lineLimit(1)
      Text(result.source).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      HStack(spacing: 8) {
        if let installs = result.installs {
          Label(SkillsDirectoryInstalls.short(installs), systemImage: "arrow.down.circle").foregroundStyle(.secondary)
        }
        SkillsDirectoryStatus(result: result)
      }
      .font(.caption)
      .labelStyle(.titleAndIcon)
    }
    .padding(.vertical, 4)
    .help(result.id)
  }
}

enum SkillsDirectoryInstalls {
  static func short(_ installs: Int) -> String {
    "\(installs.formatted(.number.notation(.compactName))) \(installs == 1 ? "install" : "installs")"
  }
}

/// Whether a result's repository is in Library, listed in Discovery, or can't be added.
struct SkillsDirectoryStatus: View {
  let result: SkillsDirectory.Result
  @Environment(AppStore.self) private var store

  var body: some View {
    if let address = result.repositoryAddress {
      if let entry = store.discoveryEntry(listing: address) {
        if entry.installedFolder != nil {
          Label("In Library", systemImage: "checkmark.circle").foregroundStyle(.green)
        } else {
          Label("In Discovery", systemImage: "shippingbox").foregroundStyle(.secondary)
        }
      }
    } else {
      Text("Not on GitHub").foregroundStyle(.secondary)
    }
  }
}

/// One skills.sh result, with its repository and the step that brings it into Discovery.
struct SkillsDirectoryResultDetail: View {
  let result: SkillsDirectory.Result
  /// The other results from the same repository.
  let related: [SkillsDirectory.Result]
  var select: (SkillsDirectory.Result.ID) -> Void = { _ in }
  var open: (SkillsDirectory.Result) -> Void = { _ in }
  @Environment(AppStore.self) private var store

  private var entry: RepositoryEntry? { result.repositoryAddress.flatMap(store.discoveryEntry(listing:)) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 8) {
          Text(result.name).font(.largeTitle.bold()).textSelection(.enabled)
          if result.skillId != result.name {
            Text(result.skillId).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
          }
          Text("From \(result.source)").font(.title3).foregroundStyle(.secondary).textSelection(.enabled)
          if let installs = result.installs {
            Text("Installed \(installs.formatted()) \(installs == 1 ? "time" : "times") with the skills CLI")
              .font(.callout).foregroundStyle(.secondary)
          }
          HStack {
            if let page = result.pageURL { Link("Open on skills.sh", destination: page) }
            if let address = result.repositoryAddress, let url = URL(string: address) { Link("Open repository", destination: url) }
          }
          .buttonStyle(.link)
        }
        repository
        if !related.isEmpty {
          Divider()
          VStack(alignment: .leading, spacing: 0) {
            Text("More from \(result.source) \u{00B7} \(related.count)").font(.title2.bold()).padding(.bottom, 8)
            ForEach(related) { other in
              Button { select(other.id) } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Text(other.name).font(.headline).foregroundStyle(.primary)
                  if let installs = other.installs {
                    Text(SkillsDirectoryInstalls.short(installs)).font(.caption).foregroundStyle(.secondary)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Show \(other.name) from \(other.source)")
              Divider()
            }
          }
        }
      }
      .padding(24)
      .frame(maxWidth: 900, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder private var repository: some View {
    VStack(alignment: .leading, spacing: 10) {
      if result.repositoryAddress == nil {
        Label("This source isn't a GitHub repository, so Discovery can't add it.", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      } else {
        if let entry {
          Label(entry.installedFolder != nil ? "Its repository is in Library" : "Its repository is listed in Discovery",
            systemImage: entry.installedFolder != nil ? "checkmark.circle.fill" : "shippingbox")
            .foregroundStyle(entry.installedFolder != nil ? .green : .secondary)
        }
        Button(entry == nil ? "Add Repository to Discovery" : "Show Repository") { open(result) }
          .buttonStyle(.borderedProminent)
        Text(entry == nil
          ? "Saves \(result.source) as a Discovery source and opens it. Nothing is downloaded until you choose Load skills or Add to Library there."
          : "Opens \(result.source) in Discovery, searched for this skill.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// Where the skills.sh CLI installed a skill from, with a link to that repository in Discovery.
struct SkillsLockSourceRow: View {
  let entry: SkillsLockEntry
  @Environment(AppStore.self) private var store
  @Environment(\.openSourceInDiscovery) private var openSourceInDiscovery

  var body: some View {
    WrapLayout(spacing: 8) {
      Label("Installed with skills.sh from \(entry.label)", systemImage: "shippingbox")
        .font(.callout)
        .textSelection(.enabled)
      if let address = entry.repositoryAddress, let openSourceInDiscovery {
        Button(store.listsInDiscovery(address) ? "Show in Discovery" : "Add to Discovery") {
          openSourceInDiscovery(address, "From skills.sh \u{00B7} \(entry.label)")
        }
          .buttonStyle(.link)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
