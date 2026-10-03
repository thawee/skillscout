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
    case changedOnDisk(URL)
    case problem(String)

    var errorDescription: String? {
      switch self {
      case .alreadyExists(let url): "\(Paths.abbreviate(url)) already exists."
      case .builtIn(let name): "\(name) is built into its tool and can't be moved."
      case .managed(let url): "\(Paths.abbreviate(url)) belongs to a plugin or to its tool, so Skillscout leaves it alone."
      case .conflictingCopies(let name): "\(name) has copies with different content. Keep the copy you want before moving it to the library."
      case .changedOnDisk(let url): "\(Paths.abbreviate(url)) changed since you started editing it."
      case .problem(let problem): problem
      }
    }
  }

  // MARK: - Edit

  /// An edit of a skill's SKILL.md. It covers every personal copy with the same text, so they stay alike.
  struct Edit: Sendable {
    let skill: Skill
    let files: [URL]
    let original: String
    /// Personal copies whose SKILL.md has other text. The edit leaves them as they are.
    let otherFiles: [URL]
  }

  static func edit(_ skill: Skill) throws -> Edit {
    let copies = skill.removableCopies.filter { !isManaged($0.resolved) }
    guard let source = copies.first else { throw Failure.managed(skill.primary.resolved) }
    let original = try String(contentsOf: skillFile(source), encoding: .utf8)
    var files: [URL] = []
    var otherFiles: [URL] = []
    for file in copies.map(skillFile) where !files.contains(file) && !otherFiles.contains(file) {
      if (try? String(contentsOf: file, encoding: .utf8)) == original {
        files.append(file)
      } else {
        otherFiles.append(file)
      }
    }
    return Edit(skill: skill, files: files, original: original, otherFiles: otherFiles)
  }

  /// Why `text` can't be saved, or nil when it can. The name stays, since renaming moves folders too.
  static func editProblem(_ edit: Edit, text: String) -> String? {
    let meta = Frontmatter.parse(text)
    let before = Frontmatter.parse(edit.original)
    let name = meta["name"].flatMap { $0.isEmpty ? nil : $0 }
    if name != edit.skill.name, name != nil || !before["name", default: ""].isEmpty {
      return "Keep name: \(edit.skill.name) in the frontmatter. To change the name, use Rename."
    }
    if meta["description", default: ""].isEmpty, !before["description", default: ""].isEmpty {
      return "Keep a description in the frontmatter, so agents know when to use the skill."
    }
    return nil
  }

  /// Writes `text` into every SKILL.md of the edit. It stops when one of them changed since the edit started,
  /// unless `overwrite` is set.
  static func save(_ edit: Edit, text: String, overwrite: Bool = false) throws {
    if let problem = editProblem(edit, text: text) { throw Failure.problem(problem) }
    if !overwrite, let changed = edit.files.first(where: { (try? String(contentsOf: $0, encoding: .utf8)) != edit.original }) {
      throw Failure.changedOnDisk(changed)
    }
    for file in edit.files {
      try text.write(to: file, atomically: true, encoding: .utf8)
    }
  }

  /// The SKILL.md of a copy, with links followed, so writing it doesn't replace a link with a file.
  private static func skillFile(_ copy: SkillCopy) -> URL {
    copy.resolved.appending(path: "SKILL.md").resolvingSymlinksInPath()
  }

  // MARK: - Rename

  /// Why `skill` can't be called `name`, or nil when it can.
  static func renameProblem(_ skill: Skill, to name: String, among skills: [Skill]) -> String? {
    if name.isEmpty { return "Type a name." }
    if name != slug(name) {
      let example = slug(name).isEmpty ? "release-notes" : slug(name)
      return "Use lowercase letters, numbers and hyphens, like \(example)."
    }
    if name.count > 64 { return "Keep it under 64 characters." }
    if name == skill.name { return "It's already called \(name)." }
    if skills.contains(where: { $0.name.lowercased() == name }) { return "There's already a skill called \(name)." }
    for copy in skill.removableCopies {
      let destination = renamed(copy, to: name)
      if destination != copy.folder, exists(destination) { return "\(Paths.abbreviate(destination)) already exists." }
    }
    return nil
  }

  /// Gives a skill a new name. Its folders in your skills folders get the new name, the links get re-created
  /// under it, and each SKILL.md gets the new `name`. Plugin and built-in copies keep the old name, and so
  /// do the folders that links point to outside your skills folders.
  static func rename(_ skill: Skill, to name: String, among skills: [Skill]) throws {
    if let problem = renameProblem(skill, to: name, among: skills) { throw Failure.problem(problem) }
    let copies = skill.removableCopies
    guard !copies.isEmpty else { throw Failure.managed(skill.primary.folder) }
    if let managed = copies.first(where: { isManaged($0.resolved) }) { throw Failure.managed(managed.resolved) }

    let fm = FileManager.default
    var moved: [URL: URL] = [:]
    for copy in copies where !copy.isSymlink {
      let destination = renamed(copy, to: name)
      if destination != copy.folder { try fm.moveItem(at: copy.folder, to: destination) }
      moved[copy.resolved] = destination.resolvingSymlinksInPath()
    }
    for copy in copies where copy.isSymlink {
      try fm.removeItem(at: copy.folder)
      try fm.createSymbolicLink(at: renamed(copy, to: name), withDestinationURL: moved[copy.resolved] ?? copy.resolved)
    }
    for folder in Set(copies.map { moved[$0.resolved] ?? $0.resolved }) {
      let file = folder.appending(path: "SKILL.md")
      let text = try String(contentsOf: file, encoding: .utf8)
      try Frontmatter.setting(name: name, in: text).write(to: file, atomically: true, encoding: .utf8)
    }
    SkillAliases.record(skill.name, as: name)
  }

  private static func renamed(_ copy: SkillCopy, to name: String) -> URL {
    copy.folder.deletingLastPathComponent().appending(path: name)
  }

  // MARK: - Merge

  /// What merging one skill into another changes on disk, worked out before anything changes.
  struct MergePlan: Sendable {
    let kept: Skill
    let merged: Skill
    /// The folders that get the merged SKILL.md. Their old SKILL.md goes to the Trash.
    let folders: [URL]
    /// The folder the merged skill's other files come from.
    let source: URL
    /// The kept skill's files besides SKILL.md, as paths inside its folder.
    let keptFiles: [String]
    /// The merged skill's files that get copied into `folders`.
    let copiedFiles: [String]
    /// The merged skill's files that stay out, because the kept skill has a file at the same path.
    let skippedFiles: [String]
    /// The skills folders that get a link to the kept skill in place of the merged one, so no tool loses it.
    let linkRoots: [SkillRoot]

    var id: String { "\(merged.name)>\(kept.name)" }

    var links: [URL] { linkRoots.map { $0.url.appending(path: kept.name) } }

    /// The tools that load the kept skill instead of the merged one, once it's done.
    func toolsGained(_ tools: [Tool]) -> [Tool] {
      tools.filter { tool in !kept.availableIn.contains(tool) && linkRoots.contains { $0.readBy.contains(tool) } }
    }
  }

  static func planMerge(_ merged: Skill, into kept: Skill) throws -> MergePlan {
    guard merged != kept else { throw Failure.problem("A skill can't be merged into itself.") }
    guard let keptCopy = kept.removableCopies.first else { throw Failure.managed(kept.primary.folder) }
    guard let mergedCopy = merged.removableCopies.first(where: { !$0.isSymlink }) ?? merged.removableCopies.first else {
      throw Failure.managed(merged.primary.folder)
    }
    var folders: [URL] = []
    for copy in kept.removableCopies where !folders.contains(copy.resolved) {
      if isManaged(copy.resolved) { throw Failure.managed(copy.resolved) }
      folders.append(copy.resolved)
    }

    let keptFiles = supportFiles(in: keptCopy.resolved)
    let incoming = supportFiles(in: mergedCopy.resolved)

    var covered = kept.availableIn
    var linkRoots: [SkillRoot] = []
    for root in merged.removableCopies.map(\.root) where !root.readBy.isSubset(of: covered) {
      let link = root.url.appending(path: kept.name)
      if exists(link), !merged.removableCopies.contains(where: { $0.folder == link }) { throw Failure.alreadyExists(link) }
      linkRoots.append(root)
      covered.formUnion(root.readBy)
    }

    return MergePlan(
      kept: kept,
      merged: merged,
      folders: folders,
      source: mergedCopy.resolved,
      keptFiles: keptFiles,
      copiedFiles: incoming.filter { !keptFiles.contains($0) },
      skippedFiles: incoming.filter(keptFiles.contains),
      linkRoots: linkRoots
    )
  }

  /// Makes `markdown` the SKILL.md of the kept skill, brings over the merged skill's other files,
  /// moves the merged skill to the Trash, and links the kept one where the merged one was.
  static func merge(_ plan: MergePlan, markdown: String) throws {
    let fm = FileManager.default
    let text = Frontmatter.setting(name: plan.kept.name, in: markdown)
    for folder in plan.folders {
      for path in plan.copiedFiles where !exists(folder.appending(path: path)) {
        let destination = folder.appending(path: path)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: plan.source.appending(path: path), to: destination)
      }
      let file = folder.appending(path: "SKILL.md")
      try fm.trashItem(at: file, resultingItemURL: nil)
      try text.write(to: file, atomically: true, encoding: .utf8)
    }
    try remove(plan.merged.removableCopies)
    for link in plan.links {
      try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.createSymbolicLink(at: link, withDestinationURL: plan.folders[0])
    }
    SkillAliases.record(plan.merged.name, as: plan.kept.name)
  }

  /// The files in a skill folder besides SKILL.md, as paths inside it. Hidden files stay out.
  static func supportFiles(in folder: URL) -> [String] {
    let fm = FileManager.default
    let paths = (try? fm.subpathsOfDirectory(atPath: folder.path)) ?? []
    return paths.filter { path in
      var isFolder: ObjCBool = false
      return path != "SKILL.md"
        && !path.split(separator: "/").contains { $0.hasPrefix(".") }
        && fm.fileExists(atPath: folder.appending(path: path).path, isDirectory: &isFolder) && !isFolder.boolValue
    }.sorted()
  }

  /// Whether a folder belongs to a plugin or a tool's built-in skills.
  private static func isManaged(_ folder: URL) -> Bool {
    let path = folder.resolvingSymlinksInPath().path
    return SkillRoot.all.contains { root in
      let rootPath = root.url.resolvingSymlinksInPath().path
      return root.kind != .user && root.kind != .shared && (path == rootPath || path.hasPrefix(rootPath + "/"))
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

  struct AddConflict: LocalizedError, Sendable {
    let skill: Skill
    let tool: Tool
    let source: SkillCopy
    let destination: URL
    let signature: String

    var errorDescription: String? { "\(Paths.abbreviate(destination)) already contains an installation. Choose whether to keep it or replace it." }
  }

  private static func installationSignature(_ folder: URL) throws -> String {
    let fm = FileManager.default
    if let target = try? fm.destinationOfSymbolicLink(atPath: folder.path) {
      return "link:\(target)"
    }
    guard (try folder.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
      throw Failure.problem("\(Paths.abbreviate(folder)) is not a skill folder. Move it aside before installing.")
    }
    return "folder:\(try skillsetFingerprint(folder))"
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
    guard fm.fileExists(atPath: source.resolved.appending(path: "SKILL.md").path) else { throw InstallFailure.invalidSkill }
    try fm.createDirectory(at: tool.skillsFolder, withIntermediateDirectories: true)
    let destination = tool.skillsFolder.appending(path: source.resolved.lastPathComponent)
    if exists(destination) {
      if destination.resolvingSymlinksInPath().path == source.resolved.resolvingSymlinksInPath().path { return destination }
      // Inspect the entry's parent, not a link's target: replacing a user link must leave its source alone.
      guard !isManaged(destination.deletingLastPathComponent()) else { throw Failure.managed(destination) }
      throw AddConflict(skill: skill, tool: tool, source: source, destination: destination,
        signature: try installationSignature(destination))
    }

    try createInstallation(from: source, at: destination)
    return destination
  }

  private static func createInstallation(from source: SkillCopy, at destination: URL) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: source.resolved.appending(path: "SKILL.md").path) else { throw InstallFailure.invalidSkill }
    if source.root.kind == .plugin {
      try fm.copyItem(at: source.resolved, to: destination)
    } else {
      try fm.createSymbolicLink(at: destination, withDestinationURL: source.resolved)
    }
  }

  static func replace(_ conflict: AddConflict) throws -> (destination: URL, trashed: URL?) {
    guard conflict.destination.deletingLastPathComponent().resolvingSymlinksInPath().path == conflict.tool.skillsFolder.resolvingSymlinksInPath().path,
          !isManaged(conflict.destination.deletingLastPathComponent()) else { throw Failure.managed(conflict.destination) }
    let sourcePath = conflict.source.resolved.resolvingSymlinksInPath().path
    let destinationPath = conflict.destination.resolvingSymlinksInPath().path
    guard !sourcePath.hasPrefix(destinationPath + "/") else {
      throw Failure.problem("The selected source is inside the installation being replaced. Choose another source.")
    }
    let fm = FileManager.default
    let staged = conflict.tool.skillsFolder.appending(path: ".skillscout-install-\(UUID().uuidString)")
    defer { if exists(staged) { try? fm.removeItem(at: staged) } }
    try createInstallation(from: conflict.source, at: staged)
    guard try installationSignature(conflict.destination) == conflict.signature else { throw Failure.changedOnDisk(conflict.destination) }
    return try replacingInstallation(at: conflict.destination) {
      try fm.moveItem(at: staged, to: conflict.destination)
      return conflict.destination
    }
  }

  /// Preserve the previous entry in Trash, and restore it if the new installation fails.
  static func replacingInstallation(at destination: URL, install: () throws -> URL) throws -> (destination: URL, trashed: URL?) {
    let fm = FileManager.default
    var trashed: NSURL?
    try fm.trashItem(at: destination, resultingItemURL: &trashed)
    do {
      return (try install(), trashed as URL?)
    } catch {
      guard let backup = trashed as URL? else {
        throw Failure.problem("Installation failed: \(error.localizedDescription). The previous installation is in Trash.")
      }
      guard !exists(destination) else {
        throw Failure.problem("Installation failed: \(error.localizedDescription). The destination is occupied; the previous installation is in Trash at \(backup.path).")
      }
      do { try fm.moveItem(at: backup, to: destination) }
      catch { throw Failure.problem("Couldn't restore the previous installation from \(backup.path): \(error.localizedDescription)") }
      throw error
    }
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
    let hiddenSkills = destination.appending(path: ".claude/skills")
    if let enumerator = fm.enumerator(at: hiddenSkills, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
      while let url = enumerator.nextObject() as? URL {
        if url.lastPathComponent == "SKILL.md" {
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
