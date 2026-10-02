import AppKit
import SwiftUI

extension Tool {
  var shortName: String {
    switch self {
    case .cursor: "Cursor"
    case .claude: "Claude"
    case .codex: "Codex"
    case .copilot: "Copilot"
    case .gemini: "Gemini"
    case .antigravity: "Antigrav"
    case .opencode: "OpenCode"
    case .droid: "Droid"
    case .pi: "Pi"
    case .amp: "Amp"
    }
  }

  var color: Color {
    switch self {
    case .cursor: .indigo
    case .claude: .orange
    case .codex: .teal
    case .copilot: .red
    case .gemini: .blue
    case .antigravity: .purple
    case .opencode: .green
    case .droid: .brown
    case .pi: .purple
    case .amp: .pink
    }
  }

  var symbol: String {
    switch self {
    case .cursor: "cursorarrow.rays"
    case .claude: "asterisk"
    case .codex: "terminal"
    case .copilot: "airplane"
    case .gemini: "sparkle"
    case .antigravity: "arrow.up.circle.fill"
    case .opencode: "chevron.left.forwardslash.chevron.right"
    case .droid: "cpu"
    case .pi: "pi"
    case .amp: "bolt.fill"
    }
  }
}

struct ToolBadge: View {
  let tool: Tool
  var active = true

  var body: some View {
    Text(tool.shortName)
      .font(.caption2.weight(.semibold))
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .foregroundStyle(active ? tool.color : Color.secondary.opacity(0.5))
      .background(Capsule().fill(active ? tool.color.opacity(0.15) : .clear))
      .overlay(Capsule().strokeBorder(active ? .clear : Color.secondary.opacity(0.3)))
      .strikethrough(!active, color: .secondary.opacity(0.5))
      .help(active ? "Available in \(tool.name)" : "Not available in \(tool.name)")
  }
}

struct ToolIcon: View {
  let tool: Tool
  var active = true

  var body: some View {
    Image(systemName: tool.symbol)
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(active ? tool.color : Color.secondary.opacity(0.4))
      .frame(width: 20, height: 20)
      .background(RoundedRectangle(cornerRadius: 5).fill(active ? tool.color.opacity(0.15) : .clear))
      .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(active ? .clear : Color.secondary.opacity(0.25)))
      .help(active ? "Available in \(tool.name)" : "Not available in \(tool.name)")
  }
}

struct AvailabilityBadges: View {
  let available: Set<Tool>
  let tools: [Tool]

  var body: some View {
    HStack(spacing: 3) {
      ForEach(tools) { tool in
        ToolIcon(tool: tool, active: available.contains(tool))
      }
    }
  }
}

struct DetailSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.headline)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

enum Finder {
  static func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  static func open(_ url: URL) {
    NSWorkspace.shared.open(url)
  }
}
