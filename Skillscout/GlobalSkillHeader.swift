import SwiftUI

struct GlobalSkillHeader: View {
  /// The agents the counts cover, such as "All enabled agents" or one agent's name.
  let scope: String
  let normalCount: Int
  let systemCount: Int
  @Binding var showSystemSkills: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(scope).font(.headline)
      WrapLayout(spacing: 4) {
        Text("^[\(normalCount) skill](inflect: true) available globally")
          .accessibilityIdentifier("global-skill-count")
        Text("·").foregroundStyle(.secondary)
        Text("^[\(systemCount) system skill](inflect: true)")
          .foregroundStyle(.secondary).accessibilityIdentifier("global-system-count")
      }
      .font(.caption)
      Toggle("Show system skills", isOn: $showSystemSkills)
        .accessibilityIdentifier("show-system-skills")
        .font(.caption)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 10).padding(.vertical, 8)
  }
}

/// The shared `~/.agents/skills` folder: how many skills it holds and which enabled agents read them.
struct SharedSkillHeader: View {
  let count: Int
  let readers: [Tool]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Shared \u{00B7} ~/.agents/skills").font(.headline)
      Text("^[\(count) skill](inflect: true) in the shared folder").font(.caption)
        .accessibilityIdentifier("shared-skill-count")
      Text(readers.isEmpty ? "No enabled agent reads this folder."
        : "Read by \(readers.map(\.name).formatted(.list(type: .and))). Removing a skill here affects all of them.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 10).padding(.vertical, 8)
  }
}
