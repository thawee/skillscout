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
