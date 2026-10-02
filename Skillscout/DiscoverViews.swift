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
  @Environment(AppStore.self) private var store
  @State private var isWorking = false
  @State private var libraryPath: String?
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
      do { try await store.redownloadRepo(name: SkillInstaller.repoName(for: skill.repo)) }
      catch { store.errorMessage = error.localizedDescription }
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
    if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue {
      libraryPath = Paths.abbreviate(destination)
    } else {
      libraryPath = nil
    }
  }

  private func addToLibrary(token: String? = nil) {
    isWorking = true
    Task {
      do {
        let destination = try await store.addRepoToLibrary(source: skill.repo, token: token)
        libraryPath = Paths.abbreviate(destination)
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
