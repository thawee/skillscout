import Foundation

struct UsageReport: Sendable {
  struct Day: Identifiable, Sendable {
    let date: Date
    let chats: Int
    var id: Date { date }
  }

  let skills: [Skill]
  let usage: [Skill.ID: SkillUsage]
  let chats: Int
  let byTool: [Tool: Int]
  let byProject: [String: Int]
  let projects: [String]
  let days: [Day]
  let scope: UsageScope
  let loadedDays: Int
  let window: DateInterval

  var usedSkills: Int { usage.count }
  var unrecordedSkills: [Skill] { skills.filter { usage[$0.id] == nil } }
  var rankedSkills: [Skill] {
    skills.filter { usage[$0.id] != nil }.sorted {
      let a = usage[$0.id]?.chats ?? 0, b = usage[$1.id]?.chats ?? 0
      return a == b ? $0.name < $1.name : a > b
    }
  }

  init(uses: [SkillUse], skills: [Skill], enabledTools: Set<Tool>, scope: UsageScope,
       tool: Tool? = nil, loadedDays: Int, aliases: [String: String] = [:], now: Date = Date()) {
    self.loadedDays = loadedDays
    var effective = scope
    if let days = effective.days, days >= loadedDays { effective.days = nil }
    self.scope = effective
    window = DateInterval(start: now.addingTimeInterval(-Double(effective.days ?? loadedDays) * 86_400), end: now)
    let visible = skills.filter { $0.isVisible(in: enabledTools, includePlugins: true) }
    let enabled = uses.filter { enabledTools.contains($0.tool) && (tool == nil || $0.tool == tool) && $0.date <= now }
    let loaded = UsageScope(days: loadedDays).filter(enabled, now: now)
    projects = Array(Set(loaded.map(\.project))).sorted()
    let filtered = effective.filter(loaded, now: now)
    let tally = SkillUsage.tally(filtered, skills: visible, aliases: aliases)
    usage = tally
    self.skills = visible.filter { skill in
      tool.map { skill.availableIn.contains($0) || tally[skill.id] != nil } ?? true
    }
    let resolver = SkillUseResolver(skills: self.skills, aliases: aliases)
    var chatDates: [RecordedChat: Date] = [:]
    for use in filtered where resolver.skillID(for: use) != nil {
      let chat = RecordedChat(use)
      chatDates[chat] = min(chatDates[chat] ?? use.date, use.date)
    }
    chats = chatDates.count
    var tools: [Tool: Int] = [:], projects: [String: Int] = [:], daily: [Date: Int] = [:]
    for (chat, date) in chatDates {
      tools[chat.tool, default: 0] += 1
      projects[chat.project, default: 0] += 1
      daily[Calendar.current.startOfDay(for: date), default: 0] += 1
    }
    byTool = tools
    byProject = projects
    days = daily.keys.sorted().map { Day(date: $0, chats: daily[$0]!) }
  }
}

struct ReportSourceInspection: Identifiable, Sendable {
  let folder: URL
  let skillIDs: Set<Skill.ID>
  let bytes: Int?
  let lines: Int?
  let review: SkillReview?
  let unavailable: String?
  var id: String { folder.path }
}

actor ReportInspector {
  private struct Cached: Sendable {
    let fingerprints: [String: String]
    let bytes: Int?
    let lines: Int?
    let review: SkillReview?
    let unavailable: String?
  }
  private var cache: [String: Cached] = [:]

  func inspect(_ skills: [Skill]) -> [ReportSourceInspection] {
    var sources: [String: Set<Skill.ID>] = [:]
    for skill in skills {
      for copy in skill.copies { sources[copy.resolved.path, default: []].insert(skill.id) }
    }
    cache = cache.filter { sources[$0.key] != nil }
    var result: [ReportSourceInspection] = []
    for path in sources.keys.sorted() {
      if Task.isCancelled { return [] }
      let folder = URL(fileURLWithPath: path)
      let fingerprints = SkillReview.fingerprints(folder)
      let value: Cached
      if let cached = cache[path], cached.fingerprints == fingerprints {
        value = cached
      } else {
        do {
          let data = try Data(contentsOf: folder.appending(path: "SKILL.md"))
          guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
          let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
          value = Cached(fingerprints: fingerprints, bytes: data.count, lines: lines,
            review: SkillReview.inspect(folder), unavailable: nil)
        } catch {
          value = Cached(fingerprints: fingerprints, bytes: nil, lines: nil, review: nil,
            unavailable: "SKILL.md could not be read. " + error.localizedDescription)
        }
        cache[path] = value
      }
      result.append(ReportSourceInspection(folder: folder, skillIDs: sources[path]!, bytes: value.bytes,
        lines: value.lines, review: value.review, unavailable: value.unavailable))
    }
    return result.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
  }
}
