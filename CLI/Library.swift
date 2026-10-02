import Foundation

struct CLIError: LocalizedError {
  let message: String
  var usage = false
  var errorDescription: String? { message }
}

/// Skills, chats and usage, filtered to the tools picked in the app.
struct Library {
  let tools: [Tool]
  let days: Int
  let skills: [Skill]
  var prompts: [Prompt] = []
  var usage: [Skill.ID: SkillUsage] = [:]

  static func load(days: Int, readChats: Bool) async -> Library {
    Terminal.status("Scanning skill folders…")
    var library = Library(tools: Tool.enabled, days: days, skills: SkillScanner.scan())
    if readChats {
      Terminal.status("Reading your chats from the last \(days) days…")
      let (prompts, uses) = await PromptLibrary().load(lookbackDays: days)
      let enabled = Set(library.tools)
      library.prompts = prompts.filter { enabled.contains($0.tool) }
      library.usage = SkillUsage.tally(uses.filter { enabled.contains($0.tool) }, skills: library.skills, aliases: SkillAliases.load())
    }
    Terminal.clearStatus()
    return library
  }

  func listed(includePlugins: Bool) -> [Skill] {
    let enabled = Set(tools)
    return skills.filter { $0.isVisible(in: enabled, includePlugins: includePlugins) }
  }

  func skill(named name: String) throws -> Skill {
    if let skill = skills.first(where: { $0.name == name }) ?? skills.first(where: { $0.name.lowercased() == name.lowercased() }) {
      return skill
    }
    let close = skills.map(\.name).filter { $0.localizedCaseInsensitiveContains(name) }.sorted().prefix(5)
    if close.isEmpty { throw CLIError(message: "There's no skill called \(name). Run skillscout-thawee list to see them all.") }
    throw CLIError(message: "There's no skill called \(name). Did you mean \(close.formatted(.list(type: .or)))?")
  }

  func chats(_ skill: Skill) -> Int { usage[skill.id]?.chats ?? 0 }
}

/// The parts of the app's saved state the CLI reads. It never writes it, so a running app keeps its own copy.
struct AppState: Decodable {
  var explanations: [String: String]?
  var dismissed: [String]?
  var dismissedPairs: [String]?

  static func load() -> AppState {
    (try? Data(contentsOf: Paths.stateFile)).flatMap { try? JSONDecoder().decode(AppState.self, from: $0) }
      ?? AppState()
  }
}

// MARK: - JSON output

struct SkillJSON: Encodable {
  struct Copy: Encodable {
    let path: String
    let source: String
    let linksTo: String?
  }

  let name: String
  let description: String
  let personal: Bool
  let availableIn: [String]
  let missingIn: [String]
  let chats: Int
  let chatsByTool: [String: Int]
  let lastUsed: Date?
  let projects: [String]
  let created: Date?
  let skillFile: String
  let copies: [Copy]

  init(_ skill: Skill, in library: Library) {
    let usage = library.usage[skill.id]
    name = skill.name
    description = skill.description
    personal = skill.isPersonal
    availableIn = library.tools.filter(skill.availableIn.contains).map(\.rawValue)
    missingIn = skill.missing(from: library.tools).map(\.rawValue)
    chats = usage?.chats ?? 0
    chatsByTool = Dictionary(uniqueKeysWithValues: (usage?.byTool ?? [:]).map { ($0.key.rawValue, $0.value) })
    lastUsed = usage?.lastUsed
    projects = usage?.topProjects ?? []
    let createdDate = skill.created(usage: usage)
    created = createdDate == .distantPast ? nil : createdDate
    skillFile = skill.skillFile.path
    copies = skill.copies.map {
      Copy(path: $0.folder.path, source: $0.sourceLabel, linksTo: $0.isSymlink ? $0.resolved.path : nil)
    }
  }
}

func printJSON<T: Encodable>(_ value: T) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  encoder.dateEncodingStrategy = .iso8601
  print(String(decoding: try encoder.encode(value), as: UTF8.self))
}
