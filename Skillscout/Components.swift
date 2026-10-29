import AppKit
import SwiftUI

struct ChoiceOption<Value: Hashable>: Identifiable {
  let value: Value
  let title: String
  var detail: String? = nil
  var symbol: String? = nil
  var tint: Color? = nil
  var count: Int? = nil
  var id: Value { value }
}

struct ChoiceChips<Value: Hashable>: View {
  let title: String
  let options: [ChoiceOption<Value>]
  @Binding var selection: Value

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      WrapLayout(spacing: 5) {
        ForEach(options) { option in
          let selected = option.value == selection
          let tint = option.tint ?? .accentColor
          Button { selection = option.value } label: {
            HStack(spacing: 4) {
              if selected { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
              else if let symbol = option.symbol { Image(systemName: symbol).font(.caption2) }
              Text(option.title).font(.caption.weight(selected ? .semibold : .regular))
              if let count = option.count {
                Text(count, format: .number).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
              }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .foregroundStyle(selected ? tint : .primary)
            .background(selected ? tint.opacity(0.14) : Color.primary.opacity(0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.45) : Color.primary.opacity(0.12)))
            .contentShape(Capsule())
          }
          .buttonStyle(.plain)
          .help(option.detail ?? option.title)
          .accessibilityLabel("\(title): \(option.title)")
          .accessibilityValue(selected ? "Selected" : "Not selected")
          .accessibilityHint(option.count.map { "\($0) skills available globally" } ?? "")
          .accessibilityIdentifier("choice.\(title).\(option.title)")
        }
      }
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct AgentChoices: View {
  var title = "Agent"
  let tools: [Tool]
  var allTitle = "All agents"
  @Binding var selection: Tool?
  var counts: [Tool: Int] = [:]
  var allCount: Int? = nil

  var body: some View {
    ChoiceChips(title: title, options:
      [ChoiceOption<Tool?>(value: nil, title: allTitle, symbol: "square.grid.2x2", count: allCount)] + tools.map {
        ChoiceOption(value: Optional($0), title: $0.shortName, detail: $0.name, symbol: $0.symbol, tint: $0.color, count: counts[$0])
      }, selection: $selection)
  }
}

struct SearchChoice<Value: Hashable>: View {
  let title: String
  let options: [ChoiceOption<Value>]
  @Binding var selection: Value
  @State private var showing = false
  @Environment(\.isEnabled) private var enabled

  private var selected: ChoiceOption<Value>? { options.first { $0.value == selection } }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Button { showing = true } label: {
        HStack(spacing: 8) {
          Image(systemName: selected?.symbol ?? "list.bullet")
          VStack(alignment: .leading, spacing: 2) {
            Text(selected?.title ?? "Choose \(title.lowercased())…").lineLimit(1)
            if let detail = selected?.detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
          }
          Spacer(minLength: 4)
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        }.font(.callout).padding(8).contentShape(RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
      .help(selected.map { [$0.title, $0.detail].compactMap { $0 }.joined(separator: " · ") } ?? "Choose \(title.lowercased())")
      .accessibilityLabel("Choose \(title)")
      .accessibilityValue(selected?.title ?? "No available selection")
      .accessibilityIdentifier("search-choice.\(title)")
      .popover(isPresented: $showing) {
        ChoiceSearchPanel(title: title, options: options, selected: selection) { value in
          guard enabled else { return }
          showing = false
          selection = value
        } close: { showing = false }
        .disabled(!enabled)
      }
    }
    .onChange(of: enabled) { if !enabled { showing = false } }
  }
}

struct ChoiceAction<Value: Hashable>: View {
  let title: String
  let options: [ChoiceOption<Value>]
  let action: (Value) -> Void
  @State private var showing = false
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    Button(title) { showing = true }
      .accessibilityIdentifier("choice-action.\(title)")
      .popover(isPresented: $showing) {
        ChoiceSearchPanel(title: title, options: options, selected: nil) { value in
          guard enabled else { return }
          showing = false
          action(value)
        } close: { showing = false }
        .disabled(!enabled)
      }
      .onChange(of: enabled) { if !enabled { showing = false } }
  }
}

private struct ChoiceSearchPanel<Value: Hashable>: View {
  let title: String
  let options: [ChoiceOption<Value>]
  let selected: Value?
  let choose: (Value) -> Void
  let close: () -> Void
  @State private var query = ""
  @State private var focusedIndex = 0
  @FocusState private var searchFocused: Bool

  private var matches: [ChoiceOption<Value>] {
    options.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
      || ($0.detail?.localizedCaseInsensitiveContains(query) ?? false) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(title).font(.headline)
        Spacer()
        Button { close() } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).help("Close choices").accessibilityLabel("Close choices")
      }
      TextField("Search \(title.lowercased())", text: $query)
        .textFieldStyle(.roundedBorder).focused($searchFocused)
        .accessibilityIdentifier("choice-search.\(title)")
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) { chooseFocused(); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
      if matches.isEmpty {
        Text(options.isEmpty ? "No choices available" : "No matching choices")
          .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 70)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: 3) {
              ForEach(Array(matches.enumerated()), id: \.element.id) { index, option in
                Button { choose(option.value) } label: {
                  HStack(alignment: .top, spacing: 8) {
                    if let symbol = option.symbol { Image(systemName: symbol).foregroundStyle(option.tint ?? .secondary) }
                    VStack(alignment: .leading, spacing: 3) {
                      Text(option.title).font(.callout.weight(.medium))
                      if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    }
                    Spacer(minLength: 4)
                    if let selected, selected == option.value { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                  }
                  .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                  .background(index == focusedIndex ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                  .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain).id(option.id)
                .accessibilityLabel(option.title)
                .accessibilityValue(selected == option.value ? "Selected" : "Not selected")
                .accessibilityIdentifier("choice-result.\(title).\(option.title)")
              }
            }
          }.frame(maxHeight: 280)
          .onChange(of: focusedIndex) {
            if matches.indices.contains(focusedIndex) { proxy.scrollTo(matches[focusedIndex].id) }
          }
        }
      }
    }
    .padding(14).frame(width: 360)
    .defaultFocus($searchFocused, true)
    .onAppear {
      focusedIndex = options.firstIndex { $0.value == selected } ?? 0
    }
    .task {
      await Task.yield()
      searchFocused = true
    }
    .onDisappear { searchFocused = false }
    .onChange(of: query) { focusedIndex = 0 }
    .onExitCommand { close() }
  }

  private func move(_ offset: Int) {
    guard !matches.isEmpty else { return }
    focusedIndex = min(max(0, focusedIndex + offset), matches.count - 1)
  }

  private func chooseFocused() {
    guard matches.indices.contains(focusedIndex) else { return }
    choose(matches[focusedIndex].value)
  }
}

/// Lays out its views in rows, left to right, starting a new row only when one is full.
struct WrapLayout: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    positions(width: proposal.width, subviews: subviews).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = positions(width: bounds.width, subviews: subviews)
    for (index, view) in subviews.enumerated() {
      let position = result.points[index]
      view.place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), anchor: .topLeading,
        proposal: ProposedViewSize(width: min(view.sizeThatFits(.unspecified).width, bounds.width), height: nil))
    }
  }

  private func positions(width proposed: CGFloat?, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
    let naturalSizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let minimumWidth = naturalSizes.map(\.width).max() ?? 0
    let naturalWidth = naturalSizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, subviews.count - 1))
    let width = max(minimumWidth, proposed.flatMap { $0.isFinite ? $0 : nil } ?? naturalWidth)
    var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
    var points: [CGPoint] = []
    for view in subviews {
      let size = view.sizeThatFits(ProposedViewSize(width: min(view.sizeThatFits(.unspecified).width, width), height: nil))
      if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
      points.append(CGPoint(x: x, y: y))
      usedWidth = max(usedWidth, x + size.width)
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    return (CGSize(width: proposed == nil ? usedWidth : width, height: y + rowHeight), points)
  }
}

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
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
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
      .accessibilityLabel(tool.name)
      .accessibilityValue(active ? "Available" : "Not available")
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
        .accessibilityAddTraits(.isHeader)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A monospaced editor for SKILL.md files. SwiftUI's TextEditor follows the system's smart quotes and dashes,
/// which turn the commands in a skill into curly quotes and em dashes, so this one turns every substitution off.
struct PlainTextEditor: NSViewRepresentable {
  @Binding var text: String

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    scrollView.drawsBackground = false
    scrollView.autohidesScrollers = true
    let textView = scrollView.documentView as! NSTextView
    textView.delegate = context.coordinator
    textView.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
    textView.drawsBackground = false
    textView.isRichText = false
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.smartInsertDeleteEnabled = false
    textView.string = text
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.text = $text
    let textView = scrollView.documentView as! NSTextView
    if textView.string != text { textView.string = text }
    textView.isEditable = context.environment.isEnabled
    textView.textColor = context.environment.isEnabled ? .textColor : .secondaryLabelColor
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>

    init(text: Binding<String>) { self.text = text }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
    }
  }
}

enum Finder {
  static func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  static func reveal(_ urls: [URL]) {
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  static func open(_ url: URL) {
    NSWorkspace.shared.open(url)
  }
}
