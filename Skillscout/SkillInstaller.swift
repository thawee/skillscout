import Foundation

enum SaveTarget: Hashable {
  case everywhere([Tool])
  case tool(Tool)
}

enum SkillInstaller {
  enum Failure: LocalizedError {
    case alreadyExists(URL)
    case builtIn(String)
    case managed(URL)
    case conflictingCopies(String)

    var errorDescription: String? {
      switch self {
      case .alreadyExists(let url): "\(Paths.abbreviate(url)) already exists."
      case .builtIn(let name): "\(name) is built into its tool and can't be moved."
      case .managed(let url): "\(Paths.abbreviate(url)) belongs to a plugin or to its tool, so Skillscout leaves it alone."
      case .conflictingCopies(let name): "\(name) has copies with different content. Keep the copy you want before moving it to the library."
      }
    }
  }

  /// Moves the copies to the Trash, so you can put them back from there. A link goes on its own,
  /// and the folder it points to stays.
  @discardableResult
  static func remove(_ copies: [SkillCopy]) throws -> [URL] {
    if let managed = copies.first(where: { $0.root.kind == .plugin || $0.root.kind == .builtIn }) {
      throw Failure.managed(managed.folder)
    }
    var trashed: [URL] = []
    for copy in copies {
      var result: NSURL?
      try FileManager.default.trashItem(at: copy.folder, resultingItemURL: &result)
      if let result { trashed.append(result as URL) }
    }
    return trashed
  }

  static func moveToCentral(_ skill: Skill) throws -> URL {
    guard let primary = skill.copies.first(where: { $0.root.kind == .user }) else {
      throw Failure.builtIn(skill.name)
    }
    guard !skill.copiesDiffer else { throw Failure.conflictingCopies(skill.name) }

    let fm = FileManager.default
    let managedRoot = SkillRoot.all.first { $0.kind == .managed }!.url
    try fm.createDirectory(at: managedRoot, withIntermediateDirectories: true)

    let name = slug(skill.name)
    let destination = managedRoot.appending(path: name)
    guard !exists(destination) else { throw Failure.alreadyExists(destination) }

    try fm.moveItem(at: primary.resolved, to: destination)

    for copy in skill.copies {
       guard copy.root.kind == .user || copy.root.kind == .shared else { continue }
       if exists(copy.folder) {
           try fm.removeItem(at: copy.folder)
       }
       try fm.createSymbolicLink(at: copy.folder, withDestinationURL: destination)
    }
    return destination
  }

  /// Remove only the repository and links into it, preserving independent copies of its skills.
  @discardableResult
  static func removeRepo(name: String) throws -> [URL] {
    guard !name.isEmpty, name == slug(name) else { throw InstallFailure.notFound }
    let root = Paths.at(".config/skillscout/skills").resolvingSymlinksInPath()
    let folder = root.appending(path: name)
    let fm = FileManager.default
    guard exists(folder) else { throw InstallFailure.notFound }
    var trashed: [URL] = []
    for skillRoot in SkillRoot.all where skillRoot.kind == .user || skillRoot.kind == .shared {
      let entries = (try? fm.contentsOfDirectory(at: skillRoot.url, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
      for entry in entries {
        guard (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
        let target = entry.resolvingSymlinksInPath().path
        if target == folder.path || target.hasPrefix(folder.path + "/") {
          var result: NSURL?
          try fm.trashItem(at: entry, resultingItemURL: &result)
          if let result { trashed.append(result as URL) }
        }
      }
    }
    var result: NSURL?
    try fm.trashItem(at: folder, resultingItemURL: &result)
    if let result { trashed.append(result as URL) }
    return trashed
  }

  static func installableSources(for skill: Skill) -> [SkillCopy] {
    var seen = Set<String>()
    return skill.copies.filter { $0.root.kind != .builtIn }
      .sorted { a, b in
        let rank: (SkillCopy) -> Int = { $0.root.kind == .managed ? 0 : $0.root.kind == .plugin ? 2 : 1 }
        return rank(a) == rank(b) ? a.resolved.path < b.resolved.path : rank(a) < rank(b)
      }
      .filter { seen.insert($0.resolved.path).inserted }
  }

  static func defaultSource(for skill: Skill) -> SkillCopy? {
    let sources = installableSources(for: skill)
    let managed = sources.filter { $0.root.kind == .managed }
    if managed.count == 1 { return managed[0] }
    return sources.count == 1 ? sources[0] : nil
  }

  static func add(_ skill: Skill, to tool: Tool, from selectedSource: SkillCopy? = nil) throws -> URL {
    let sources = installableSources(for: skill)
    guard !sources.isEmpty else {
      throw Failure.builtIn(skill.name)
    }
    guard let source = selectedSource ?? defaultSource(for: skill),
          sources.contains(where: { $0.resolved.path == source.resolved.path }) else {
      throw InstallFailure.sourceChoiceRequired(skill.name)
    }
    let fm = FileManager.default
    try fm.createDirectory(at: tool.skillsFolder, withIntermediateDirectories: true)
    let destination = tool.skillsFolder.appending(path: source.resolved.lastPathComponent)
    guard !exists(destination) else { throw Failure.alreadyExists(destination) }

    if source.root.kind == .plugin {
      try fm.copyItem(at: source.resolved, to: destination)
    } else {
      try fm.createSymbolicLink(at: destination, withDestinationURL: source.resolved)
    }
    return destination
  }

  enum InstallFailure: LocalizedError {
    case gitFailed(String)
    case notFound
    case invalidSkill
    case authRequired
    case linkedSkillMissing(String)
    case sourceChoiceRequired(String)

    var errorDescription: String? {
       switch self {
       case .gitFailed(let message): "Git clone failed: \(message)"
       case .notFound: "The URL or path was not found."
       case .invalidSkill: "No SKILL.md found in the installed folder."
       case .authRequired: "Authentication required. Please provide a Personal Access Token."
       case .linkedSkillMissing(let path): "Re-download would break an existing skill link to \(path). Remove that link before retrying."
       case .sourceChoiceRequired(let name): "Choose which source of \(name) to add."
       }
    }
  }

  static func repoName(for source: String) -> String {
    if source.hasPrefix("http"), let url = URL(string: source) {
       return slug(url.path.replacingOccurrences(of: ".git", with: ""))
    } else if source.hasPrefix("git@") {
       let path = source.components(separatedBy: ":").last?.replacingOccurrences(of: ".git", with: "") ?? source
       return slug(path)
    } else {
       return slug(URL(fileURLWithPath: source).lastPathComponent.replacingOccurrences(of: ".git", with: ""))
    }
  }

  static func install(source: String, explicitTools: [Tool]? = nil, token: String? = nil, stagingAt: URL? = nil) async throws -> URL {
    let name = repoName(for: source)
    let managedRoot = SkillRoot.all.first { $0.kind == .managed }!.url
    let fm = FileManager.default
    try fm.createDirectory(at: managedRoot, withIntermediateDirectories: true)
    let destination = stagingAt ?? managedRoot.appending(path: name)
    if stagingAt != nil, destination.deletingLastPathComponent().standardizedFileURL.path != managedRoot.standardizedFileURL.path {
      throw InstallFailure.notFound
    }
    guard !exists(destination) else { throw Failure.alreadyExists(destination) }

    if source.hasPrefix("http") || source.hasPrefix("git@") {
       var cloneURL = source
       if let token = token, !token.isEmpty, source.hasPrefix("http") {
           cloneURL = source.replacingOccurrences(of: "://", with: "://x-access-token:\(token)@")
       }

       let process = Process()
       process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
       process.arguments = ["clone", "--depth", "1", cloneURL, destination.path]

       let pipe = Pipe()
       process.standardError = pipe

       try process.run()
       process.waitUntilExit()

       if process.terminationStatus != 0 {
           try? fm.removeItem(at: destination)
           let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
           let errorString = String(data: errorData, encoding: .utf8) ?? ""
           let lowerError = errorString.lowercased()
           if lowerError.contains("authentication failed") || lowerError.contains("could not read username") || lowerError.contains("not found") {
               throw InstallFailure.authRequired
           }
           throw InstallFailure.gitFailed(errorString.trimmingCharacters(in: .whitespacesAndNewlines))
       }
    } else {
       let local = URL(fileURLWithPath: source)
       guard exists(local) else { throw InstallFailure.notFound }
       try fm.copyItem(at: local, to: destination)
       do {
          try source.write(to: destination.appending(path: ".skillscout-local-source"), atomically: true, encoding: .utf8)
       } catch {
          try? fm.removeItem(at: destination)
          throw error
       }
    }

    var skillDirs: [URL] = []
    if let enumerator = fm.enumerator(at: destination, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
      while let url = enumerator.nextObject() as? URL {
        if url.lastPathComponent == "node_modules" {
          enumerator.skipDescendants()
        } else if url.lastPathComponent == "SKILL.md" {
          skillDirs.append(url.deletingLastPathComponent())
        }
      }
    }

    guard !skillDirs.isEmpty else {
       try? fm.removeItem(at: destination)
       throw InstallFailure.invalidSkill
    }

    for skillDir in skillDirs {
       let skillFile = skillDir.appending(path: "SKILL.md")
       let markdown = (try? String(contentsOf: skillFile, encoding: .utf8)) ?? ""
       let frontmatter = Frontmatter.parse(markdown)

       var toolsToLink = Tool.enabled
       if let explicit = explicitTools {
          toolsToLink = explicit
       } else if let supported = frontmatter["supported_tools"] {
          let names = supported.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "").split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'"))) }
          toolsToLink = names.compactMap { Tool(argument: $0) }
       }


       let fallbackName = skillDir == destination ? name : skillDir.lastPathComponent
       let linkName = slug(frontmatter["name"] ?? fallbackName)

       // Managed folders aren't read by agents, so each requested tool needs its own link.
       for tool in toolsToLink {
          let link = tool.skillsFolder.appending(path: linkName)
          if !exists(link) {
            try fm.createDirectory(at: tool.skillsFolder, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: link, withDestinationURL: skillDir)
          }
       }
    }

    return destination
  }

  static func save(markdown: String, fallbackName: String, to target: SaveTarget) throws -> URL {
    let name = slug(Frontmatter.parse(markdown)["name"] ?? fallbackName)
    let fm = FileManager.default

    let shared = SkillRoot.all[0]
    let folder: URL
    switch target {
    case .everywhere: folder = shared.url.appending(path: name)
    case .tool(let tool): folder = tool.skillsFolder.appending(path: name)
    }
    guard !exists(folder) else { throw Failure.alreadyExists(folder) }
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try markdown.write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

    if case .everywhere(let tools) = target {
      for tool in linkTargets(for: tools) {
        let link = tool.skillsFolder.appending(path: name)
        if !exists(link) {
          try fm.createDirectory(at: tool.skillsFolder, withIntermediateDirectories: true)
          try fm.createSymbolicLink(at: link, withDestinationURL: folder)
        }
      }
    }
    return folder
  }

  /// Tools that don't read the shared folder, so saving everywhere links the skill into their own folder.
  static func linkTargets(for tools: [Tool]) -> [Tool] {
    var covered = SkillRoot.all[0].readBy
    return tools.filter { tool in
      guard !covered.contains(tool) else { return false }
      covered.formUnion(SkillRoot.all.first { $0.url == tool.skillsFolder }?.readBy ?? [tool])
      return true
    }
  }

  private static func exists(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
  }

  static func slug(_ text: String) -> String {
    let lowered = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
    return String(lowered)
      .split(separator: "-", omittingEmptySubsequences: true)
      .joined(separator: "-")
  }
}
