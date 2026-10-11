import SwiftUI
import Charts

struct ReportSkillAction: View {
  @Environment(AppStore.self) private var store
  let skill: Skill
  var body: some View {
    Button("Open skill") { store.revealRequest = skill.id }
  }
}

struct ReportSimilarAction: View {
  let pair: SimilarPair
  let open: (SimilarPair) -> Void
  var body: some View {
    Button("Compare skills") { open(pair) }
  }
}

struct ReportsView: View {
  @Environment(AppStore.self) private var store
  let openSimilar: (SimilarPair) -> Void
  @State private var period = 0
  @State private var tool: Tool?
  @State private var project: String?
  @State private var inspections: [ReportSourceInspection] = []
  @State private var inspecting = true
  @State private var inspector = ReportInspector()

  private struct InspectionSnapshot: Hashable {
    let copies: [SkillCopy]
    let revision: Int
  }

  private var librarySkills: [Skill] {
    let tools = Set(store.tools)
    return store.skills.filter {
      $0.isVisible(in: tools, includePlugins: true) && ($0.isInLibrary || !$0.isSystemOnly(in: tools))
    }
  }
  private var pairs: [SimilarPair] {
    let ids = Set(librarySkills.map(\.id))
    return store.similar.filter { ids.contains($0.first) && ids.contains($0.second) }
  }

  var body: some View {
    let report = store.usageReport(scope: UsageScope(project: project, days: period == 0 ? nil : period), tool: tool, includeSystemSkills: false)
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Dashboard").font(.largeTitle.bold())
          Text("Review recorded use and your local skill library.").foregroundStyle(.secondary)
        }
        filters(projects: report.projects)
        Text("Recorded use in \(report.scope.description(loadedDays: report.loadedDays)). Retained chat history may be incomplete.")
          .font(.caption).foregroundStyle(.secondary)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], spacing: 12) {
          metric("Chats with skills", value: report.chats)
          metric("Skills used", value: report.usedSkills)
          metric("No recorded use", value: report.unrecordedSkills.count)
          metric("Skills in scope", value: report.skills.count)
        }
        if store.isLoadingPrompts {
          ProgressView("Loading recorded history…")
        } else if report.chats == 0 {
          ContentUnavailableView("No recorded skill use", systemImage: "chart.bar.xaxis",
            description: Text("Try a different period, tool or project. This does not mean these skills have never been used."))
            .frame(maxWidth: .infinity)
        } else {
          dailyUsage(report)
          usageBreakdown(report)
        }
        reportSection("Most used skills") {
          if report.rankedSkills.isEmpty { Text("No recorded use in this period.").foregroundStyle(.secondary) }
          ForEach(Array(report.rankedSkills.prefix(12))) { skill in
            skillRow(skill, detail: chatCount(report.usage[skill.id]?.chats ?? 0), lastUsed: report.usage[skill.id]?.lastUsed)
          }
        }
        DisclosureGroup("No recorded use in this period (\(report.unrecordedSkills.count))") {
          VStack(alignment: .leading, spacing: 12) {
            Text("Review relevance before removing a skill. Removing an unused skill does not automatically save tokens.")
              .font(.caption).foregroundStyle(.secondary)
            ForEach(report.unrecordedSkills) { skill in skillRow(skill, detail: "No recorded use") }
          }.padding(.top, 10)
        }
        Divider()
        VStack(alignment: .leading, spacing: 5) {
          Text("Library review").font(.title2.bold())
          Text("All skills visible to enabled tools and your Library. These checks do not change with the usage filters.")
            .font(.caption).foregroundStyle(.secondary)
        }
        reportSection("Similar skills (\(pairs.count))") {
          if pairs.isEmpty { Text("No similar pairs found.").foregroundStyle(.secondary) }
          ForEach(Array(pairs.prefix(8))) { pair in
            HStack {
              Text("\(pair.first) and \(pair.second)").lineLimit(2)
              Spacer()
              ReportSimilarAction(pair: pair, open: openSimilar)
            }
          }
        }
        reportSection("Conflicting copies") {
          let conflicts = librarySkills.filter(\.copiesDiffer)
          if conflicts.isEmpty { Text("No differing copies found.").foregroundStyle(.secondary) }
          ForEach(conflicts) { skill in skillRow(skill, detail: "Copies contain different instructions") }
        }
        reportSection("Instruction size and review findings") {
          Text("SKILL.md size is a review aid. Actual token use depends on what the agent loads. Findings are heuristic and do not prove safety or output quality.")
            .font(.caption).foregroundStyle(.secondary)
          if inspecting { ProgressView("Inspecting local sources…") }
          else if inspections.isEmpty { Text("No local sources to inspect.").foregroundStyle(.secondary) }
          else {
            Text("\(inspections.count) unique sources. Tool links to the same source count once.")
              .font(.caption).foregroundStyle(.secondary)
            Text("\(inspections.count { !($0.review?.scripts.isEmpty ?? true) || !($0.review?.findings.isEmpty ?? true) }) sources with scripts or flagged commands; \(inspections.count { $0.unavailable != nil }) unavailable. Sorted by instruction size, largest first.")
              .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(inspections.prefix(10))) { source in inspectionRow(source) }
            if inspections.count > 10 {
              DisclosureGroup("Other sources (\(inspections.count - 10))") {
                VStack(alignment: .leading, spacing: 12) {
                  ForEach(Array(inspections.dropFirst(10))) { source in inspectionRow(source) }
                }.padding(.top, 8)
              }
            }
          }
        }
      }
      .padding(24)
      .frame(maxWidth: 1100, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("Dashboard")
    .task(id: InspectionSnapshot(copies: librarySkills.flatMap(\.copies), revision: store.reportInspectionRevision)) {
      inspecting = true
      let values = await inspector.inspect(librarySkills)
      guard !Task.isCancelled else { return }
      inspections = values
      inspecting = false
    }
    .onChange(of: store.loadedLookbackDays) {
      if period >= store.loadedLookbackDays { period = 0 }
    }
    .onChange(of: store.tools) { if let tool, !store.tools.contains(tool) { self.tool = nil } }
    .onChange(of: report.projects) { if let project, !report.projects.contains(project) { self.project = nil } }
  }

  private func filters(projects: [String]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      periodChoices
      AgentChoices(tools: store.tools, allTitle: "All enabled agents", selection: $tool)
      SearchChoice(title: "Project", options: [
        ChoiceOption(value: String?.none, title: "All projects")
      ] + projects.map {
        ChoiceOption(value: String?.some($0), title: UsageScope.projectLabel($0), detail: $0, symbol: "folder")
      }, selection: $project)
    }
  }
  private var periodChoices: some View {
    ChoiceChips(title: "Period", options: [
      ChoiceOption(value: 0, title: "Loaded \(store.loadedLookbackDays) days")
    ] + [7, 30].filter { $0 < store.loadedLookbackDays }.map {
      ChoiceOption(value: $0, title: "\($0) days")
    }, selection: $period)
  }
  private func metric(_ title: String, value: Int) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(value.formatted()).font(.system(size: 30, weight: .semibold, design: .rounded))
      Text(title).font(.caption).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
  }
  private func dailyUsage(_ report: UsageReport) -> some View {
    reportSection("Recorded chats by day") {
      Chart(report.days) { day in
        BarMark(x: .value("Date", day.date, unit: .day), y: .value("Chats", day.chats))
      }
      .chartXScale(domain: report.window.start...report.window.end)
      .chartXAxis {
        AxisMarks(values: .stride(by: .day, count: max(1, (report.scope.days ?? report.loadedDays) / 6))) { _ in
          AxisGridLine()
          AxisValueLabel(format: .dateTime.month(.abbreviated).day())
        }
      }
      .frame(height: 145)
      Text("Each chat appears on its earliest recorded skill-use day in this period.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
  private func usageBreakdown(_ report: UsageReport) -> some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270))], alignment: .leading, spacing: 18) {
      reportSection("By tool") {
        ForEach(store.tools.filter { report.byTool[$0] != nil }) { tool in
          HStack { Text(tool.name); Spacer(); Text(chatCount(report.byTool[tool] ?? 0)).foregroundStyle(.secondary) }
        }
      }
      reportSection("By project") {
        ForEach(Array(report.byProject.keys.sorted { (report.byProject[$0] ?? 0) > (report.byProject[$1] ?? 0) }.prefix(8)), id: \.self) { project in
          HStack { Text(UsageScope.projectLabel(project)).lineLimit(1); Spacer(); Text(chatCount(report.byProject[project] ?? 0)).foregroundStyle(.secondary) }
        }
      }
    }
  }
  private func reportSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12) { Text(title).font(.headline); content() }
      .frame(maxWidth: .infinity, alignment: .leading)
  }
  private func chatCount(_ count: Int) -> String { "\(count.formatted()) \(count == 1 ? "chat" : "chats")" }
  private func skillRow(_ skill: Skill, detail: String, lastUsed: Date? = nil) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(skill.name).fontWeight(.medium)
        HStack {
          Text(detail)
          if let lastUsed { Text("Last used \(lastUsed.formatted(date: .abbreviated, time: .omitted))") }
        }.font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      ReportSkillAction(skill: skill)
    }
  }
  private func inspectionRow(_ source: ReportSourceInspection) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(source.skillIDs.sorted().joined(separator: ", ")).fontWeight(.medium)
        Spacer()
        if let skill = librarySkills.first(where: { source.skillIDs.contains($0.id) }) { ReportSkillAction(skill: skill) }
      }
      Text(Paths.abbreviate(source.folder)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      if let bytes = source.bytes, let lines = source.lines {
        Text("\(bytes.formatted()) bytes · \(lines.formatted()) lines in SKILL.md").font(.caption)
      }
      if let unavailable = source.unavailable { Text(unavailable).font(.caption).foregroundStyle(.orange) }
      if let review = source.review {
        Text(review.summary).font(.caption).foregroundStyle(review.needsReview ? Color.orange : Color.secondary)
        if !review.findings.isEmpty || !review.scripts.isEmpty {
          DisclosureGroup("Review details") { ReviewFindingsView(review: review) }
        }
      }
    }.padding(.vertical, 5)
  }
}
