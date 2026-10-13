import Foundation

struct UsageReportInputs: Equatable, Sendable {
  let uses: [SkillUse]
  let skills: [Skill]
  let enabledTools: Set<Tool>
  let loadedDays: Int
  let aliases: [String: String]
  var calendar: Calendar = .current
}

struct UsageReportCache {
  private struct Key: Equatable {
    let scope: UsageScope
    let tool: Tool?
    let includeSystemSkills: Bool
  }

  private struct Entry {
    let key: Key
    let report: UsageReport
    let builtAt: Date
    let nextEligibility: Date?
    let nextExpiry: Date?

    func contains(_ now: Date) -> Bool {
      now >= builtAt && (nextEligibility.map { now < $0 } ?? true)
        && (nextExpiry.map { now <= $0 } ?? true)
    }
  }

  private var inputs: UsageReportInputs?
  private var entries: [Entry] = []

  mutating func report(inputs: UsageReportInputs, scope: UsageScope, tool: Tool? = nil,
                       includeSystemSkills: Bool = true, now: Date) -> UsageReport {
    if self.inputs != inputs {
      self.inputs = inputs
      entries.removeAll(keepingCapacity: true)
    }
    var effective = scope
    if let days = effective.days, days >= inputs.loadedDays { effective.days = nil }
    let key = Key(scope: effective, tool: tool, includeSystemSkills: includeSystemSkills)
    if let entry = entries.first(where: { $0.key == key && $0.contains(now) }) {
      return entry.report.withWindow(endingAt: now)
    }
    let readers = tool.map { Set([$0]) } ?? inputs.enabledTools
    let skills = includeSystemSkills ? inputs.skills : inputs.skills.filter { $0.isInLibrary || !$0.isSystemOnly(in: readers) }
    let report = UsageReport(uses: inputs.uses, skills: skills, enabledTools: inputs.enabledTools,
      scope: effective, tool: tool, loadedDays: inputs.loadedDays, aliases: inputs.aliases, now: now, calendar: inputs.calendar)
    let relevant = inputs.uses.filter { inputs.enabledTools.contains($0.tool) && (tool == nil || $0.tool == tool) }
    let eligibility = relevant.lazy.filter { $0.date > now }.map(\.date).min()
    let periods = Set([inputs.loadedDays, effective.days ?? inputs.loadedDays])
    let expiry = relevant.flatMap { use in
      periods.map { use.date.addingTimeInterval(Double($0) * 86_400) }
    }.filter { $0 >= now }.min()
    entries.removeAll { $0.key == key }
    if entries.count >= 8 { entries.removeFirst() }
    entries.append(Entry(key: key, report: report, builtAt: now, nextEligibility: eligibility, nextExpiry: expiry))
    return report
  }
}

struct SkillAliasSnapshot {
  private struct Metadata: Equatable {
    let inode: UInt64?
    let permissions: UInt16?
    let size: UInt64?
    let modified: Date?
    let created: Date?
  }
  private var metadata: Metadata?
  private var initialized = false
  private var aliases: [String: String] = [:]

  mutating func load(_ file: URL = SkillAliases.file) -> [String: String] {
    let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
    let current = attributes.map { Metadata(inode: ($0[.systemFileNumber] as? NSNumber)?.uint64Value,
      permissions: ($0[.posixPermissions] as? NSNumber)?.uint16Value,
      size: ($0[.size] as? NSNumber)?.uint64Value, modified: $0[.modificationDate] as? Date,
      created: $0[.creationDate] as? Date) }
    if !initialized || current != metadata {
      aliases = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
      metadata = current
      initialized = true
    }
    return aliases
  }
}
