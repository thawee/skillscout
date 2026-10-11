import AppKit
import SwiftUI

private enum RepositoryFilter: String, CaseIterable {
  case all = "All", library = "In Library", updates = "Updates available"
}

struct RepositoryList: View {
  let repositories: [RepositoryEntry]
  @Binding var selection: RepositoryID?
  var localOnly = false
  var hasSearch = false
  var clearSearch: () -> Void = {}
  var onAdded: (RepositoryEntry) -> Void = { _ in }
  @Environment(AppStore.self) private var store
  @State private var filter = RepositoryFilter.all
  @State private var showingAdd = false
  @State private var addedSource: String?

  private var filtered: [RepositoryEntry] {
    repositories.filter { entry in
      switch filter {
      case .all: true
      case .library: entry.installedFolder != nil
      case .updates: store.repositoryChecks[entry.id]?.status == .updateAvailable
      }
    }
  }

  private var checkTitle: String {
    guard let progress = store.repositoryCheckProgress else { return "Check all for updates" }
    return "Checking \(progress.done + 1) of \(progress.total)…"
  }

  var body: some View {
    VStack(spacing: 0) {
      ChoiceChips(title: "Show", options: RepositoryFilter.allCases.filter { !localOnly || $0 != .updates }.map {
        ChoiceOption(value: $0, title: $0.rawValue)
      }, selection: $filter)
      .padding(10)
      if !localOnly, let summary = store.repositoryCheckSummary {
        Text(summary).font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10).padding(.bottom, 6)
      }
      List(selection: $selection) {
        ForEach(filtered) { entry in
          VStack(alignment: .leading, spacing: 5) {
            Text(entry.name).font(.headline)
            Text(entry.description).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 5) {
              if entry.installedFolder != nil {
                Label("In Library", systemImage: "checkmark.circle").foregroundStyle(.green)
              } else {
                Text("Not in Library").foregroundStyle(.secondary)
              }
              if store.repositoryChecks[entry.id]?.status == .updateAvailable {
                Text("Update available").foregroundStyle(.orange)
              }
            }
            .font(.caption)
            if entry.issue != nil || store.repositoryErrors[entry.id] != nil {
              Label("Needs attention", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
          }
          .padding(.vertical, 5)
          .tag(entry.id)
        }
      }
      .overlay {
        if filtered.isEmpty {
          ContentUnavailableView {
            Label(hasSearch ? "No matching sources" : "No sources here", systemImage: "shippingbox")
          } description: {
            Text(hasSearch ? "Try another name or address." : "Add a repository URL or a local skills folder.")
          } actions: {
            if hasSearch { Button("Clear search", action: clearSearch) }
            if filter != .all { Button("Show all sources") { filter = .all } }
            Button("Add source") { showingAdd = true }
          }
        }
      }
    }
    .navigationSplitViewColumnWidth(min: 260, ideal: 320)
    .toolbar {
      Button { showingAdd = true } label: { Label("Add source", systemImage: "plus") }
      if !localOnly {
        Button {
          Task { if await store.checkAllRepositories() > 0 { filter = .updates } }
        } label: {
          Label(checkTitle, systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
        }
        .help("Check every Git repository in the Library for updates")
        .disabled(store.isCheckingRepositories)
      }
    }
    .sheet(isPresented: $showingAdd) { AddSourceView(selection: $addedSource) }
    .onChange(of: addedSource) {
      guard let address = addedSource else { return }
      Task {
        await store.loadRegistry()
        if let entry = store.repositories.first(where: {
          $0.catalog?.repo == address || $0.source.address == SkillInstaller.redactedSource(address)
        }) {
          selection = entry.id
          onAdded(entry)
        }
      }
    }
  }
}

struct RepositoryDetail: View {
  let repository: RepositoryEntry
  @Environment(AppStore.self) private var store
  @State private var search = ""
  @State private var selectedSkill: RepositorySkill?
  @State private var showingRemove = false
  @State private var showingVersion = false
  @State private var versionRequest: RepositoryRef?
  @State private var versionToken: String?
  @State private var showingAuthentication = false
  @State private var token = ""

  private var entry: RepositoryEntry { store.repositories.first { $0.id == repository.id } ?? repository }
  private var busy: Bool { store.repositoryBusy.contains(entry.id) }
  private var isImported: Bool { entry.installedFolder != nil }
  private var contents: [RepositorySkill] { store.repositorySkills(entry) }
  private var matches: [RepositorySkill] {
    contents.filter { search.isEmpty || $0.skill.name.localizedCaseInsensitiveContains(search)
      || $0.skill.description.localizedCaseInsensitiveContains(search) || $0.relativePath.localizedCaseInsensitiveContains(search) }
  }

  var body: some View {
    Group {
      if let selectedSkill {
        RepositorySkillInspector(repositoryID: entry.id, item: selectedSkill, imported: isImported,
          onClose: { self.selectedSkill = nil })
      } else {
        repositoryPage
      }
    }
    .sheet(isPresented: $showingVersion, onDismiss: {
      if let ref = versionRequest {
        let credential = versionToken
        versionRequest = nil
        versionToken = nil
        Task { await store.reviewRepositoryUpdate(entry, ref: ref, token: credential) }
      }
    }) {
      RepositoryVersionSheet(repository: entry, onSelect: { ref, credential in
        versionRequest = ref
        versionToken = credential
      }).environment(store)
    }
    .sheet(isPresented: $showingAuthentication, onDismiss: { token = "" }) {
      authentication
    }
    .confirmationDialog("Remove \(entry.name) from Library?", isPresented: $showingRemove) {
      Button("Move repository to Trash", role: .destructive) { Task { await store.removeRepository(entry) } }
    } message: {
      Text("The repository and agent links into it move to Trash. Independent copies stay.")
    }
    .onChange(of: contents) {
      if let selectedSkill {
        self.selectedSkill = contents.first { $0.id == selectedSkill.id }
      }
    }
  }

  private var repositoryPage: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 8) {
          Text(entry.name).font(.largeTitle.bold()).textSelection(.enabled)
          Text(entry.description).font(.title3).foregroundStyle(.secondary)
          Text(entry.source.address).font(.callout.monospaced()).textSelection(.enabled)
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          HStack {
            Button("Copy address") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(entry.source.address, forType: .string)
            }
            if let url = URL(string: entry.source.address), ["https", "http"].contains(url.scheme ?? "") {
              Link("Open repository", destination: url)
            }
            if let folder = entry.installedFolder {
              Button("Show in Finder") { Finder.reveal(folder) }
            }
          }
          .buttonStyle(.link)
        }
        status
        actions
        if let message = entry.issue ?? store.repositoryErrors[entry.id] {
          VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
            if message.localizedCaseInsensitiveContains("auth"), entry.source.address.hasPrefix("http") {
              Button("Authenticate…") { showingAuthentication = true }
            }
          }
        }
        Divider()
        skillList
      }
      .padding(24)
      .frame(maxWidth: 900, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var authentication: some View {
      VStack(alignment: .leading, spacing: 16) {
        Text("Repository authentication").font(.headline)
        SecureField("Personal access token", text: $token).textFieldStyle(.roundedBorder)
        HStack {
          Spacer()
          Button("Cancel") { token = ""; showingAuthentication = false }.keyboardShortcut(.cancelAction)
          if isImported {
            Button("Check for updates") {
              let credential = token
              token = ""
              showingAuthentication = false
              Task { await store.checkRepository(entry, token: credential) }
            }.disabled(token.isEmpty)
            Button("Review update…") {
              let credential = token
              token = ""
              showingAuthentication = false
              Task { await store.reviewRepositoryUpdate(entry, token: credential) }
            }.disabled(token.isEmpty).keyboardShortcut(.defaultAction)
          } else {
          Button("Load skills") {
            let credential = token
            token = ""
            showingAuthentication = false
            store.loadRepositoryPreview(entry, token: credential)
          }.disabled(token.isEmpty)
          Button("Add to Library") {
            let credential = token
            token = ""
            showingAuthentication = false
            Task { await store.importRepository(entry, token: credential) }
          }.disabled(token.isEmpty).keyboardShortcut(.defaultAction)
          }
        }
      }.padding(20).frame(width: 400)
  }

  private var status: some View {
    VStack(alignment: .leading, spacing: 7) {
      Label(isImported ? "Stored in Library" : store.repositoryPreviews[entry.id] != nil ? "Preview" : "Not in Library",
        systemImage: isImported ? "checkmark.circle.fill" : "shippingbox")
        .foregroundStyle(isImported ? .green : .secondary)
      if entry.source.isGit, let snapshot = entry.snapshot {
        Text(snapshot.ref.label).font(.callout)
        if let commit = snapshot.commit {
          Text("Installed commit \(commit.prefix(12))").font(.callout.monospaced()).textSelection(.enabled)
        }
      } else if let preview = store.repositoryPreviews[entry.id], let commit = preview.commit {
        Text("Preview commit \(commit.prefix(12))").font(.callout.monospaced())
      }
      if let check = store.repositoryChecks[entry.id] {
        if store.repositoryErrors[entry.id] == nil {
          Text(check.message).foregroundStyle(check.status == .updateAvailable || check.status == .tagMoved ? .orange : .secondary)
        }
        Text("Last successful check \(check.checkedAt, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var actions: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) { actionButtons }.fixedSize(horizontal: true, vertical: false)
      VStack(alignment: .leading, spacing: 10) { actionButtons }
    }
    .disabled(store.isManagingSkillsets || store.pendingRepoUpdate != nil || store.isPreparingRepositoryUpdate)
    .controlSize(.regular)
  }

  @ViewBuilder private var actionButtons: some View {
      if busy {
        ProgressView().controlSize(.small)
        Text("Working…").foregroundStyle(.secondary)
        if store.repositoryTasks[entry.id] != nil {
          Button("Cancel") { store.cancelRepositoryPreview(entry) }
        }
      } else if isImported {
        if entry.source.isGit {
          Button("Check for updates") { Task { await store.checkRepository(entry) } }
          if store.repositoryChecks[entry.id]?.status == .updateAvailable {
            Button("Review update…") { Task { await store.reviewRepositoryUpdate(entry) } }
              .buttonStyle(.borderedProminent)
          }
          Button("Choose version…") { showingVersion = true }
        } else {
          Button("Refresh from Folder…") { Task { await store.reviewRepositoryUpdate(entry) } }
        }
        Menu("More actions") {
          if entry.source.isGit {
            Button("Review current source…") { Task { await store.reviewRepositoryUpdate(entry) } }
          }
          Button("Remove from Library…", role: .destructive) { showingRemove = true }
          removeRegistration
        }
      } else {
        Button("Add to Library") { Task { await store.importRepository(entry) } }.buttonStyle(.borderedProminent)
        Button(store.repositoryPreviews[entry.id] == nil ? "Load skills" : "Reload preview") { store.loadRepositoryPreview(entry) }
        Menu("More actions") { removeRegistration }
      }
  }

  @ViewBuilder private var removeRegistration: some View {
    if entry.catalog?.author == "Custom", let source = entry.catalog?.repo {
      Button("Remove from Discovery", role: .destructive) {
        do {
          try CustomRegistry.shared.remove(id: source)
          Task { await store.loadRegistry() }
        } catch { store.repositoryErrors[entry.id] = error.localizedDescription }
      }
    }
  }

  private var skillList: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Skills · \(contents.count)").font(.title2.bold())
        Spacer()
        if !isImported { Text("Preview only").font(.caption).foregroundStyle(.secondary) }
      }
      if isImported || store.repositoryPreviews[entry.id] != nil {
        TextField("Search skills in this source", text: $search).textFieldStyle(.roundedBorder)
        if matches.isEmpty {
          Text(search.isEmpty ? "No skills found in this source." : "No skills match this search.").foregroundStyle(.secondary)
          if !search.isEmpty { Button("Clear search") { search = "" } }
        }
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(matches) { item in
            Button {
              selectedSkill = item
            } label: {
              VStack(alignment: .leading, spacing: 6) {
                Text(item.skill.name).font(.headline).foregroundStyle(.primary)
                Text(item.skill.description).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                Text(item.relativePath).font(.caption.monospaced()).foregroundStyle(.secondary)
                if isImported {
                  AvailabilityBadges(available: store.scopedSkill(item).availableIn, tools: store.tools)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 12)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Inspect \(item.skill.name) from \(entry.name)")
            Divider()
          }
        }
      } else {
        Text("Load skills to inspect this source before adding it to Library. Previewing creates no agent links.")
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct RepositorySkillInspector: View {
  let repositoryID: RepositoryID
  let item: RepositorySkill
  let imported: Bool
  var onClose: () -> Void = {}
  @Environment(AppStore.self) private var store

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(item.skill.name).font(.headline)
        Spacer()
        Button("Back to repository", action: onClose).keyboardShortcut(.cancelAction)
      }.padding(16)
      Divider()
      if imported {
        SkillDetail(skill: store.scopedSkill(item), installationSource: item.copy, context: .discovery)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            Text(item.skill.description).font(.title3)
            Text("Preview only. Add the repository to Library before installing this skill.").foregroundStyle(.secondary)
            if let entry = store.repositories.first(where: { $0.id == repositoryID }) {
              Button("Add repository to Library") { Task { await store.importRepository(entry); if store.repositoryErrors[entry.id] == nil { onClose() } } }
                .disabled(store.repositoryBusy.contains(entry.id))
              if let error = store.repositoryErrors[entry.id] { Text(error).foregroundStyle(.orange) }
            }
            DetailSection("Contents") { ReviewFindingsView(review: SkillReview.inspect(item.copy.resolved)) }
            DetailSection("SKILL.md") {
              Text((try? String(contentsOf: item.copy.resolved.appending(path: "SKILL.md"), encoding: .utf8)) ?? "Unavailable")
                .font(.callout.monospaced()).textSelection(.enabled)
            }
          }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct RepositoryVersionSheet: View {
  let repository: RepositoryEntry
  var onSelect: (RepositoryRef, String?) -> Void
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var refs: [RepositoryRef] = []
  @State private var selection = RepositoryRef.defaultBranch
  @State private var commit = ""
  @State private var pinCommit = false
  @State private var error: String?
  @State private var loading = true
  @State private var token = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Choose version for \(repository.name)").font(.headline)
      Text("Branches track new commits. Tags and commits stay pinned until you choose another version.")
        .font(.callout).foregroundStyle(.secondary)
      if loading { ProgressView("Loading branches and tags…") }
      SearchChoice(title: "Version", options:
        [ChoiceOption(value: RepositoryRef.defaultBranch, title: "Default branch", detail: "Track the repository default branch", symbol: "arrow.triangle.branch")]
          + refs.filter { $0 != .defaultBranch }.map { ChoiceOption(value: $0, title: $0.label,
            detail: $0.isPinned ? "Pinned version" : "Track new commits", symbol: $0.isPinned ? "pin" : "arrow.triangle.branch") },
        selection: $selection)
        .disabled(loading || pinCommit)
      Toggle("Pin a specific commit", isOn: $pinCommit)
      if pinCommit { TextField("Full commit SHA", text: $commit).textFieldStyle(.roundedBorder) }
      if let error { Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
      if repository.source.address.hasPrefix("http") {
        SecureField("Personal access token (optional)", text: $token).textFieldStyle(.roundedBorder)
        Button("Reload branches and tags") { Task { await loadRefs() } }.disabled(loading)
      }
      HStack {
        Spacer()
        Button("Cancel") { token = ""; dismiss() }.keyboardShortcut(.cancelAction)
        Button("Review version…") {
          onSelect(pinCommit ? .commit(commit.trimmingCharacters(in: .whitespacesAndNewlines)) : selection,
                   token.isEmpty ? nil : token)
          token = ""
          dismiss()
        }.disabled(loading || store.repositoryBusy.contains(repository.id) || (pinCommit && commit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
      }
    }
    .padding(24).frame(width: 480)
    .task { await loadRefs() }
  }

  private func loadRefs() async {
    loading = true
    error = nil
    defer { loading = false }
    do {
      refs = try await RepositoryLibrary.refs(source: repository.source, token: token.isEmpty ? nil : token)
      if !refs.contains(selection) { selection = .defaultBranch }
    } catch { self.error = error.localizedDescription }
  }
}
