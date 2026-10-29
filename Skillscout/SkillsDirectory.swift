import Foundation

/// skills.sh, the open agent skills directory. Skillscout searches it only when the user asks, and reads the
/// lock files its `skills` CLI writes, which record where each skill it installed came from.
enum SkillsDirectory {
  static let site = URL(string: "https://skills.sh")!

  /// One search result: a skill in a repository, with how many times the `skills` CLI installed it.
  struct Result: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let source: String
    let skillId: String
    let name: String
    let installs: Int?

    /// The repository Discovery previews and imports, or nil when the source isn't `owner/repo` on GitHub.
    var repositoryAddress: String? { SkillsDirectory.githubAddress(source) }

    /// The skill's page on skills.sh, which shows its `SKILL.md` and install command.
    var pageURL: URL? {
      let parts = id.split(separator: "/").map(String.init)
      guard parts.count >= 3 else { return nil }
      return parts.reduce(SkillsDirectory.site) { $0.appending(path: $1) }
    }
  }

  enum Failure: LocalizedError {
    case status(Int)

    var errorDescription: String? {
      switch self {
      case .status(let code): "skills.sh answered with HTTP \(code). Try again later."
      }
    }
  }

  /// The endpoint the `skills find` command uses. It needs no login, but skills.sh doesn't document it.
  static func searchURL(_ query: String) -> URL? {
    var components = URLComponents(url: site.appending(path: "api/search"), resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "50")]
    return components?.url
  }

  static func search(_ query: String, session: URLSession = .shared) async throws -> [Result] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= 2, let url = searchURL(query) else { return [] }
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw Failure.status(http.statusCode)
    }
    return try results(from: data)
  }

  /// The results in skills.sh's order, most relevant first. A result missing a field is skipped, not the whole reply.
  static func results(from data: Data) throws -> [Result] {
    struct Lossy: Decodable {
      let result: Result?
      init(from decoder: Decoder) throws { result = try? Result(from: decoder) }
    }
    struct Payload: Decodable { let skills: [Lossy] }
    var seen = Set<String>()
    return try JSONDecoder().decode(Payload.self, from: data).skills.compactMap(\.result).filter { seen.insert($0.id).inserted }
  }

  /// `https://github.com/owner/repo` for an `owner/repo` source, nil for anything else.
  static func githubAddress(_ source: String) -> String? {
    let parts = source.split(separator: "/", omittingEmptySubsequences: false)
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    guard parts.count == 2, parts.allSatisfy({
      !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains)
    }) else { return nil }
    return "https://github.com/\(parts[0])/\(parts[1])"
  }
}

/// Where the `skills` CLI installed a skill from, as its lock file records it.
struct SkillsLockEntry: Hashable, Sendable {
  let name: String
  let source: String
  let sourceType: String
  let sourceURL: String?

  /// The address Discovery previews and imports, or nil when skills.sh got the skill another way.
  var repositoryAddress: String? {
    func remote(_ value: String?) -> String? {
      guard let value, ["https://", "http://", "ssh://", "git@"].contains(where: value.hasPrefix) else { return nil }
      return value
    }
    switch sourceType {
    case "github": return remote(sourceURL) ?? SkillsDirectory.githubAddress(source)
    case "gitlab", "git": return remote(sourceURL) ?? remote(source)
    case "local": return source.hasPrefix("/") ? source : nil
    default: return nil
    }
  }

  var label: String { sourceType == "local" ? Paths.abbreviate(URL(fileURLWithPath: source)) : source }
}

enum SkillsLock {
  /// `$XDG_STATE_HOME/skills/.skill-lock.json` when that's set, as the CLI does, otherwise `~/.agents/.skill-lock.json`.
  static func globalFile(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = Paths.home) -> URL {
    if let state = environment["XDG_STATE_HOME"], !state.isEmpty {
      return URL(fileURLWithPath: state, isDirectory: true).appending(path: "skills/.skill-lock.json")
    }
    return home.appending(path: ".agents/.skill-lock.json")
  }

  static func projectFile(_ project: URL) -> URL { project.appending(path: "skills-lock.json") }

  /// The entries keyed by skill name. A missing or unreadable file has none. A project lock stores local
  /// sources relative to its folder, so they're resolved against it here.
  static func entries(in file: URL) -> [String: SkillsLockEntry] {
    guard let data = try? Data(contentsOf: file),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let skills = object["skills"] as? [String: Any] else { return [:] }
    var entries: [String: SkillsLockEntry] = [:]
    for (name, value) in skills {
      guard let fields = value as? [String: Any], var source = fields["source"] as? String,
            let sourceType = fields["sourceType"] as? String else { continue }
      if sourceType == "local", !source.hasPrefix("/") {
        source = file.deletingLastPathComponent().appending(path: source).standardizedFileURL.path
      }
      entries[name] = SkillsLockEntry(name: name, source: source, sourceType: sourceType, sourceURL: fields["sourceUrl"] as? String)
    }
    return entries
  }

  /// The entry for a skill you can remove, by its name or the name of a folder it's installed in.
  static func entry(for skill: Skill, in entries: [String: SkillsLockEntry]) -> SkillsLockEntry? {
    guard skill.isPersonal else { return nil }
    return entry(named: skill.name, folders: skill.removableCopies.map(\.folder), in: entries)
  }

  static func entry(named name: String, folders: [URL], in entries: [String: SkillsLockEntry]) -> SkillsLockEntry? {
    entries[name] ?? folders.lazy.compactMap { entries[$0.lastPathComponent] }.first
  }
}
