import SwiftUI

struct RepositoryUpdateImpactView: View {
  @Environment(AppStore.self) private var store
  let update: RepoUpdate
  var resolved: ResolvedRepoUpdate? = nil

  private var impact: RepositoryUpdateImpact {
    RepositoryUpdateImpact.inspect(repository: update.repositoryFolder,
      changedPaths: resolved.map { Set($0.added + $0.changed + $0.removed) }, result: resolved?.staged,
      skills: store.skills, skillsets: store.skillsets, projectState: store.projectState)
  }

  var body: some View {
    let impact = self.impact
    let newSkills = resolved?.newSkills ?? update.newSkills
    VStack(alignment: .leading, spacing: 12) {
      Text("Where these changes apply").font(.headline)
      if impact.linked.isEmpty {
        Text("No known agent installations point to this Library source.").font(.callout).foregroundStyle(.secondary)
      } else {
        Text("Linked agent installations").font(.subheadline.weight(.semibold))
        ForEach(impact.linked) { entry in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(entry.skillID).fontWeight(.medium)
              Spacer()
              Text(entry.willChange.map { $0 ? "Changes with Library" : "Contents unchanged" } ?? "Reads this Library source")
                .font(.caption).foregroundStyle(.secondary)
            }
            agentBadges(entry.tools)
            Text(Paths.describe(URL(fileURLWithPath: entry.path))).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
        Text("These entries read through links. Changed source contents become available when you apply this Library update.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if !impact.otherCopies.isEmpty {
        Text("Other agent copies stay unchanged").font(.subheadline.weight(.semibold))
        ForEach(impact.otherCopies) { entry in
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.skillID).fontWeight(.medium)
            agentBadges(entry.tools)
            Text(Paths.describe(URL(fileURLWithPath: entry.path))).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
        Text("These copies share skill names; their source provenance is not confirmed. Manage them separately in Global.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if !impact.projects.isEmpty {
        Text("Project copies need a separate review").font(.subheadline.weight(.semibold))
        ForEach(impact.projects) { entry in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text("\(entry.projectName) · \(entry.skillID)").fontWeight(.medium)
              Spacer()
              Text(entry.state.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            agentBadges(entry.tools)
            Text(Paths.describe(URL(fileURLWithPath: entry.path))).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
        Text("This update changes no project files. Use the project’s application preview to update an unchanged owned copy. Local edits remain protected.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if !impact.skillsetNames.isEmpty {
        Text("Collections containing these skills").font(.subheadline.weight(.semibold))
        Text(impact.skillsetNames.joined(separator: ", ")).font(.callout)
        Text("Membership and assignments stay unchanged.").font(.caption).foregroundStyle(.secondary)
      }
      if !newSkills.isEmpty {
        Text("New skills in Library").font(.subheadline.weight(.semibold))
        ForEach(newSkills) { skill in
          VStack(alignment: .leading, spacing: 2) {
            Text(skill.skill.name).fontWeight(.medium)
            Text(skill.relativePath).font(.caption.monospaced()).foregroundStyle(.secondary)
          }
        }
        Text("No new agent links or skillset memberships are created. Add the skills to a destination after this update. An existing link to a containing folder may already expose nested skills.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("repository-update.impact")
  }

  private func agentBadges(_ tools: [Tool]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
    WrapLayout(spacing: 4) {
      ForEach(store.tools.filter(tools.contains)) { ToolBadge(tool: $0) }
    }
    DisabledReaderNotice(readers: Set(tools))
    }
  }
}
