import SwiftUI

struct GlobalSkillHeader: View {
  let tools: [Tool]
  let counts: [Tool: Int]
  let allCount: Int
  let normalCount: Int
  let systemCount: Int
  @Binding var selectedTool: Tool?
  @Binding var showSystemSkills: Bool

  var body: some View {
    VStack(spacing: 0) {
      AgentChoices(tools: tools, allTitle: "All enabled agents", selection: $selectedTool,
        counts: counts, allCount: allCount)
        .padding(.horizontal, 10).padding(.vertical, 8)
      WrapLayout(spacing: 4) {
        Text("^[\(normalCount) skill](inflect: true) available globally")
          .accessibilityIdentifier("global-skill-count")
        Text("·").foregroundStyle(.secondary)
        Text("^[\(systemCount) system skill](inflect: true)")
          .foregroundStyle(.secondary).accessibilityIdentifier("global-system-count")
      }
      .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
      Toggle("Show system skills", isOn: $showSystemSkills)
        .accessibilityIdentifier("show-system-skills")
        .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 8)
    }
  }
}
