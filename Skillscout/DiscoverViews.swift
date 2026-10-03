import AppKit
import SwiftUI

struct DiscoverList: View {
  let skills: [RegistrySkill]
  @Binding var selection: RegistrySkill.ID?
  @State private var showingAdd = false

  var body: some View {
    List(selection: $selection) {
      ForEach(skills) { skill in
        VStack(alignment: .leading, spacing: 4) {
          Text(skill.name).font(.headline)
          Text(skill.description).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
          Text(skill.repo.hasPrefix("/") ? "Local Folder" : (skill.author == "Custom" ? "Custom Repository" : "By \(skill.author)"))
            .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .tag(skill.id)
      }
    }
    .navigationTitle("Discover")
    .toolbar {
      Button(action: { showingAdd = true }) {
        Label("Add Custom Source", systemImage: "plus")
      }
    }
    .sheet(isPresented: $showingAdd) {
      AddSourceView(selection: $selection)
    }
  }
}

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

struct DiscoverDetail: View {
  let skill: RegistrySkill
  var onBrowseRepo: (String) -> Void = { _ in }
  var onAddedToLibrary: (String) -> Void = { _ in }
  @Environment(AppStore.self) private var store
  @State private var isWorking = false
  @State private var libraryPath: String?
  @State private var libraryCommit: String?
  @State private var showingRemove = false

  @State private var showingTokenPrompt = false
  @State private var tokenString = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 6) {
          Text(skill.name).font(.largeTitle.weight(.bold)).lineLimit(2).minimumScaleFactor(0.8)
          Text(skill.repo.hasPrefix("/") ? "Local Folder" : (skill.author == "Custom" ? "Custom Repository" : "By \(skill.author)"))
            .font(.title3).foregroundStyle(.secondary)
        }

        Text(skill.description)
          .font(.body)

        if let tools = skill.tools, !tools.isEmpty {
          DetailSection("Designed for") {
            HStack {
              ForEach(tools, id: \.self) { toolName in
                if let tool = Tool(argument: toolName) {
                  ToolBadge(tool: tool, active: true)
                }
              }
            }
          }
        }

        if libraryPath != nil {
          Label("In Library", systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.green)
          if let libraryCommit {
            Text("Downloaded commit \(libraryCommit)")
              .font(.callout.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          Text("\(store.skills.count { $0.managedRepos.contains(SkillInstaller.repoName(for: skill.repo)) }) skills available to browse. Add individual skills to an AI tool or skillset from there.")
            .font(.callout)
            .foregroundStyle(.secondary)
          HStack(spacing: 12) {
            Button("Browse skills") { onBrowseRepo(SkillInstaller.repoName(for: skill.repo)) }
              .buttonStyle(.borderedProminent)
            Menu("More actions") {
              Button(skill.repo.hasPrefix("/") ? "Refresh from Folder" : "Re-download Repository") { redownload() }
              Button("Remove from Library…", role: .destructive) { showingRemove = true }
              if skill.author == "Custom" {
                Button("Delete from Registry", role: .destructive) { deleteFromRegistry() }
              }
            }
            .disabled(isWorking)
          }
        } else {
          HStack(spacing: 12) {
            Button(action: { addToLibrary() }) {
              if isWorking {
                ProgressView().controlSize(.small)
                Text("Adding to Library…")
              } else {
                Text("Add to Library")
              }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)

            if skill.author == "Custom" {
              Button("Delete from Registry", role: .destructive) {
                deleteFromRegistry()
              }
              .buttonStyle(.bordered)
              .disabled(isWorking)
            }
          }
          Text(skill.repo.hasPrefix("/")
            ? "Copies this folder to your Library. Choose which skills to add to AI tools afterward."
            : "Downloads this repository to your Library. Choose which skills to add to AI tools afterward.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        DetailSection(skill.repo.hasPrefix("/") ? "Folder" : "Repository") {
          HStack(spacing: 10) {
            Text(skill.repo)
              .font(.callout.monospaced())
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
              .help(skill.repo)
            Button("Copy address") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(skill.repo, forType: .string)
            }
            .buttonStyle(.link)
            if let url = URL(string: skill.repo), ["http", "https"].contains(url.scheme ?? "") {
              Link("Open", destination: url)
            } else if skill.repo.hasPrefix("/") {
              Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.repo)])
              }
              .buttonStyle(.link)
            }
          }
        }
      }
      .padding(30)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onAppear {
      checkLibraryStatus()
    }
    .onChange(of: skill.id) {
      checkLibraryStatus()
      showingTokenPrompt = false
    }
    .onChange(of: store.pendingRepoUpdate == nil) {
      checkLibraryStatus()
    }
    .sheet(isPresented: $showingTokenPrompt) {
      VStack(alignment: .leading, spacing: 20) {
          Text("Authentication Required").font(.headline)
          Text("This repository appears to be private or requires authentication to clone.")
              .font(.subheadline)
              .foregroundStyle(.secondary)

          SecureField("Personal Access Token", text: $tokenString)
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 350)

          HStack {
              Spacer()
              Button("Cancel") { showingTokenPrompt = false }
                  .keyboardShortcut(.cancelAction)
              Button("Retry Add to Library") {
                  showingTokenPrompt = false
                  addToLibrary(token: tokenString)
              }
              .keyboardShortcut(.defaultAction)
              .buttonStyle(.borderedProminent)
              .disabled(tokenString.isEmpty)
          }
      }
      .padding(20)
    }
    .confirmationDialog("Remove \(skill.name) from Library?", isPresented: $showingRemove) {
      Button("Move Repository to Trash", role: .destructive) {
        Task {
          isWorking = true
          await store.deleteRepo(name: SkillInstaller.repoName(for: skill.repo))
          checkLibraryStatus()
          isWorking = false
        }
      }
    } message: {
      Text("This moves the repository and any links into it from AI tool folders to the Trash. Independent copies stay.")
    }
  }

  private func redownload() {
    Task {
      isWorking = true
      await store.previewRepoUpdate(name: SkillInstaller.repoName(for: skill.repo))
      checkLibraryStatus()
      isWorking = false
    }
  }

  private func deleteFromRegistry() {
    do {
      try CustomRegistry.shared.remove(id: skill.id)
      Task { await store.loadRegistry() }
    } catch {
      store.errorMessage = error.localizedDescription
    }
  }

  private func checkLibraryStatus() {
    let name = SkillInstaller.repoName(for: skill.repo)
    let managedRoot = SkillRoot.all.first { $0.kind == .managed }!.url
    let destination = managedRoot.appending(path: name)

    var isDir: ObjCBool = false
    let localMarker = destination.appending(path: ".skillscout-local-source")
    let matchesLocalSource = !skill.repo.hasPrefix("/")
      || (try? String(contentsOf: localMarker, encoding: .utf8)) == skill.repo
    if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue, matchesLocalSource {
      libraryPath = Paths.abbreviate(destination)
      libraryCommit = SkillInstaller.gitCommit(destination)
    } else {
      libraryPath = nil
      libraryCommit = nil
    }
  }

  private func addToLibrary(token: String? = nil) {
    isWorking = true
    Task {
      do {
        let destination = try await store.addRepoToLibrary(source: skill.repo, token: token)
        libraryPath = Paths.abbreviate(destination)
        onAddedToLibrary(SkillInstaller.repoName(for: skill.repo))
        isWorking = false
      } catch SkillInstaller.InstallFailure.authRequired {
        isWorking = false
        showingTokenPrompt = true
      } catch {
        store.errorMessage = error.localizedDescription
        isWorking = false
      }
    }
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

struct RepoUpdateSheet: View {
  @Environment(AppStore.self) private var store
  let update: RepoUpdate

  private var version: String? {
    switch (update.oldCommit, update.newCommit) {
    case let (old?, new?) where old != new: "Commit \(old) → \(new)"
    case let (old?, new?) where old == new: "Commit \(new), unchanged"
    case let (nil, new?): "Commit \(new)"
    default: nil
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Update \(update.name)?")
        .font(.headline)
      VStack(alignment: .leading, spacing: 2) {
        Text(update.source)
        if let version { Text(version) }
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      .textSelection(.enabled)

      if update.hasChanges {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            fileGroup("Added", update.added, symbol: "plus.circle")
            fileGroup("Changed", update.changed, symbol: "pencil.circle")
            fileGroup("Removed", update.removed, symbol: "minus.circle")
            if update.review.needsReview || !update.review.findings.isEmpty {
              VStack(alignment: .leading, spacing: 6) {
                Text("Worth reading in new and changed files").font(.subheadline.weight(.semibold))
                ReviewFindingsView(review: update.review)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 320)
        Text("The current copy moves to the Trash. Changes you made to it in the Library are replaced.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("The source has no changes.")
          .font(.callout)
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { finish(apply: false) }
          .keyboardShortcut(.cancelAction)
        if update.hasChanges {
          Button("Update", action: { finish(apply: true) })
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(20)
    .frame(width: 520)
  }

  @ViewBuilder
  private func fileGroup(_ title: String, _ paths: [String], symbol: String) -> some View {
    if !paths.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text("\(title) (\(paths.count))").font(.subheadline.weight(.semibold))
        ForEach(paths.prefix(50), id: \.self) { path in
          Label(path, systemImage: symbol).font(.callout.monospaced())
        }
        if paths.count > 50 {
          Text("and \(paths.count - 50) more").font(.callout).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func finish(apply: Bool) {
    Task { await store.finishRepoUpdate(apply: apply) }
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
          Task { await store.add(request.skill, to: request.tool, from: request.source, reviewed: true) }
        }
      }
    }
    .padding(20)
    .frame(width: 520)
  }
}
