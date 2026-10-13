import Foundation
import Testing

@Suite struct UsageReportCacheTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let day: TimeInterval = 86_400

  private func skill(_ name: String = "demo", kind: SkillRoot.Kind = .user) -> Skill {
    let folder = URL(fileURLWithPath: "/fixture/\(name)")
    let root = SkillRoot(label: "Fixture", url: folder.deletingLastPathComponent(), kind: kind, owner: nil, readBy: [.codex])
    let copy = SkillCopy(folder: folder, resolved: folder, root: root, pluginName: nil, isSymlink: false,
      contentHash: name, created: .distantPast)
    return Skill(name: name, description: "Fixture", copies: [copy])
  }

  private func use(_ chat: String, date: Date, folder: String = "demo", tool: Tool = .codex) -> SkillUse {
    SkillUse(tool: tool, chat: chat, project: "fixture", date: date, folder: folder)
  }

  @Test func exactCutoffIncludesExpiryThenRemovesUseAndSlidesWindow() {
    let inputs = UsageReportInputs(uses: [use("one", date: now.addingTimeInterval(-day))], skills: [skill()],
      enabledTools: [.codex], loadedDays: 60, aliases: [:])
    var cache = UsageReportCache()
    let before = cache.report(inputs: inputs, scope: UsageScope(days: 7), now: now)
    let expiry = now.addingTimeInterval(6 * day)
    let at = cache.report(inputs: inputs, scope: UsageScope(days: 7), now: expiry)
    let after = cache.report(inputs: inputs, scope: UsageScope(days: 7), now: expiry.addingTimeInterval(0.001))
    #expect(before.chats == 1 && at.chats == 1 && after.chats == 0)
    #expect(at.window.end == expiry)
    #expect(at.window.start == expiry.addingTimeInterval(-7 * day))
    #expect(after.projects == ["fixture"])
    let loadedExpiry = now.addingTimeInterval(59 * day)
    #expect(cache.report(inputs: inputs, scope: UsageScope(days: 7), now: loadedExpiry).projects == ["fixture"])
    #expect(cache.report(inputs: inputs, scope: UsageScope(days: 7), now: loadedExpiry.addingTimeInterval(0.001)).projects.isEmpty)
  }

  @Test func futureUseBecomesEligibleAtItsExactDateAndBackwardQueriesRebuild() {
    let future = now.addingTimeInterval(10)
    let inputs = UsageReportInputs(uses: [use("future", date: future)], skills: [skill()],
      enabledTools: [.codex], loadedDays: 60, aliases: [:])
    var cache = UsageReportCache()
    #expect(cache.report(inputs: inputs, scope: UsageScope(), now: now).chats == 0)
    #expect(cache.report(inputs: inputs, scope: UsageScope(), now: future).chats == 1)
    #expect(cache.report(inputs: inputs, scope: UsageScope(), now: now).chats == 0)
  }

  @Test func changedHistoryToolsSkillsAliasesAndLoadedDaysChangeReport() {
    var cache = UsageReportCache()
    let event = use("one", date: now.addingTimeInterval(-2 * day), folder: "old")
    func report(uses: [SkillUse] = [], skills: [Skill] = [], tools: Set<Tool> = [.codex],
                days: Int = 60, aliases: [String: String] = [:]) -> UsageReport {
      cache.report(inputs: UsageReportInputs(uses: uses, skills: skills, enabledTools: tools,
        loadedDays: days, aliases: aliases), scope: UsageScope(), now: now)
    }
    #expect(report(uses: [event], skills: [skill()]).chats == 0)
    #expect(report(uses: [event], skills: [skill()], aliases: ["old": "demo"]).chats == 1)
    #expect(report(uses: [event], skills: [skill()], tools: [.claude], aliases: ["old": "demo"]).chats == 0)
    #expect(report(uses: [event], skills: [skill("old")]).chats == 1)
    #expect(report(uses: [], skills: [skill("old")]).chats == 0)
    #expect(report(uses: [event], skills: [skill("old")], days: 1).chats == 0)
  }

  @Test func normalizedScopesAndSystemPolicyRetainReportSemantics() {
    var cache = UsageReportCache()
    let inputs = UsageReportInputs(uses: [use("system", date: now)], skills: [skill(kind: .builtIn)],
      enabledTools: [.codex], loadedDays: 60, aliases: [:])
    let all = cache.report(inputs: inputs, scope: UsageScope(days: 90), now: now)
    #expect(all.scope.days == nil && all.chats == 1)
    #expect(cache.report(inputs: inputs, scope: UsageScope(days: 60), now: now.addingTimeInterval(1)).chats == 1)
    #expect(cache.report(inputs: inputs, scope: UsageScope(), includeSystemSkills: false, now: now).chats == 0)
    #expect(cache.report(inputs: inputs, scope: UsageScope(), tool: .claude, now: now).chats == 0)
    #expect(cache.report(inputs: inputs, scope: UsageScope(project: "other"), now: now).chats == 0)
  }

  @Test func calendarTimeZoneChangeRegroupsDays() {
    var cache = UsageReportCache()
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    var local = utc
    local.timeZone = TimeZone(secondsFromGMT: 7 * 3600)!
    var inputs = UsageReportInputs(uses: [use("one", date: now)], skills: [skill()],
      enabledTools: [.codex], loadedDays: 60, aliases: [:], calendar: utc)
    #expect(cache.report(inputs: inputs, scope: UsageScope(), now: now).days.first?.date == utc.startOfDay(for: now))
    inputs.calendar = local
    #expect(cache.report(inputs: inputs, scope: UsageScope(), now: now).days.first?.date == local.startOfDay(for: now))
  }

  @Test func externalAliasReplacementAndRemovalRefreshSnapshot() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "aliases.json")
    var snapshot = SkillAliasSnapshot()
    #expect(snapshot.load(file).isEmpty)
    try Data(#"{"old":"demo"}"#.utf8).write(to: file, options: .atomic)
    #expect(snapshot.load(file) == ["old": "demo"])
    try Data(#"{"old":"next"}"#.utf8).write(to: file, options: .atomic)
    #expect(snapshot.load(file) == ["old": "next"])
    try FileManager.default.removeItem(at: file)
    #expect(snapshot.load(file).isEmpty)
  }
}
