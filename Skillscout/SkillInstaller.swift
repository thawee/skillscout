import CryptoKit
import Foundation

enum SaveTarget: Hashable {
  case library
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
      case .alreadyExists(let url): "\(Paths.describe(url)) already exists."
      case .builtIn(let name): "\(name) is built into its tool and can't be moved."
      case .managed(let url): Paths.libraryRepo(url.resolvingSymlinksInPath()) != nil
        ? "\(Paths.describe(url)) comes from a Library repository and stays as downloaded. Update or remove the repository instead."
        : "\(Paths.describe(url)) belongs to a plugin or to its tool, so Quartermaster leaves it alone."
      case .conflictingCopies(let name): "\(name) has copies with different content. Keep the copy you want before moving it to the library."
      case .changedOnDisk(let url): "\(Paths.describe(url)) changed since you started editing it."
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

  static func canEdit(_ skill: Skill) -> Bool {
    skill.removableCopies.contains { !isManaged($0.resolved) }
  }

  static func canRename(_ skill: Skill) -> Bool {
    !skill.removableCopies.isEmpty && !skill.removableCopies.contains { isManaged($0.resolved) }
  }

  static func canMoveToCentral(_ skill: Skill) -> Bool {
    guard centralSource(skill) != nil, !skill.copiesDiffer,
          !skill.copies.contains(where: { $0.root.kind == .managed || $0.root.kind == .shared || $0.root.kind == .drafts }),
          !skill.copies.contains(where: { isManaged($0.resolved) }) else { return false }
    return !exists(Paths.libraryFolder.appending(path: slug(skill.name)))
  }

  /// The folder that moves into the Library: a real folder in an agent's skills folder. A skill that only
  /// links to a folder elsewhere stays put, since that folder belongs to you.
  private static func centralSource(_ skill: Skill) -> SkillCopy? {
    skill.copies.first { $0.root.kind == .user && !$0.isSymlink }
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
      if destination != copy.folder, exists(destination) { return "\(Paths.describe(destination)) already exists." }
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
    var undo: [() throws -> Void] = []
    do {
      for copy in copies where !copy.isSymlink {
        let destination = renamed(copy, to: name)
        if destination != copy.folder {
          try fm.moveItem(at: copy.folder, to: destination)
          undo.append { try fm.moveItem(at: destination, to: copy.folder) }
        }
        moved[copy.resolved] = destination.resolvingSymlinksInPath()
      }
      for copy in copies where copy.isSymlink {
        let target = try fm.destinationOfSymbolicLink(atPath: copy.folder.path)
        try fm.removeItem(at: copy.folder)
        undo.append { try fm.createSymbolicLink(atPath: copy.folder.path, withDestinationPath: target) }
        let link = renamed(copy, to: name)
        try fm.createSymbolicLink(at: link, withDestinationURL: moved[copy.resolved] ?? copy.resolved)
        undo.append { try fm.removeItem(at: link) }
      }
      for folder in Set(copies.map { moved[$0.resolved] ?? $0.resolved }) {
        let file = folder.appending(path: "SKILL.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        try Frontmatter.setting(name: name, in: text).write(to: file, atomically: true, encoding: .utf8)
        undo.append { try text.write(to: file, atomically: true, encoding: .utf8) }
      }
    } catch {
      var issues: [String] = []
      for step in undo.reversed() {
        do { try step() } catch { issues.append(error.localizedDescription) }
      }
      if issues.isEmpty { throw error }
      throw Failure.problem("Renaming \(skill.name) failed (\(error.localizedDescription)), and some steps couldn't be undone: \(issues.joined(separator: " ")).")
    }
    SkillAliases.record(skill.name, as: name)
  }

  private static func renamed(_ copy: SkillCopy, to name: String) -> URL {
    copy.folder.deletingLastPathComponent().appending(path: name)
  }

  static func renameFolders(_ skill: Skill, to name: String) -> [String: String] {
    Dictionary(skill.removableCopies.map { ($0.folder.path, renamed($0, to: name).path) }, uniquingKeysWith: { first, _ in first })
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

    var replacedFolders: [String: String] {
      Dictionary(merged.removableCopies.compactMap { copy -> (String, String)? in
        guard let link = links.first(where: { $0.deletingLastPathComponent() == copy.folder.deletingLastPathComponent() }) else { return nil }
        return (copy.folder.path, link.path)
      }, uniquingKeysWith: { first, _ in first })
    }

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
  @discardableResult
  static func merge(_ plan: MergePlan, markdown: String) throws -> [URL] {
    let fm = FileManager.default
    var trashed: [URL] = []
    let text = Frontmatter.setting(name: plan.kept.name, in: markdown)
    for folder in plan.folders {
      for path in plan.copiedFiles where !exists(folder.appending(path: path)) {
        let destination = folder.appending(path: path)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: plan.source.appending(path: path), to: destination)
      }
      let file = folder.appending(path: "SKILL.md")
      let pending = folder.appending(path: ".SKILL.md.skillscout-\(UUID().uuidString)")
      try text.write(to: pending, atomically: true, encoding: .utf8)
      var previousFile: NSURL?
      do { try fm.trashItem(at: file, resultingItemURL: &previousFile) }
      catch { try? fm.removeItem(at: pending); throw error }
      if let previousFile { trashed.append(previousFile as URL) }
      do { try fm.moveItem(at: pending, to: file) }
      catch {
        if let previous = previousFile as URL? { try? fm.moveItem(at: previous, to: file) }
        throw error
      }
    }
    trashed += try remove(plan.merged.removableCopies)
    for link in plan.links {
      try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.createSymbolicLink(at: link, withDestinationURL: plan.folders[0])
    }
    SkillAliases.record(plan.merged.name, as: plan.kept.name)
    return trashed
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

  /// Whether a folder belongs to a plugin, a tool's built-in skills, or a Library repository. A skill you
  /// moved into the Library is yours, so it isn't managed.
  private static func isManaged(_ folder: URL) -> Bool {
    let resolved = folder.resolvingSymlinksInPath()
    if Paths.libraryRepo(resolved) != nil { return true }
    let path = resolved.path
    return SkillRoot.all.contains { root in
      let rootPath = root.url.resolvingSymlinksInPath().path
      return (root.kind == .plugin || root.kind == .builtIn) && (path == rootPath || path.hasPrefix(rootPath + "/"))
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

  /// Moves a skill's folder into the Library and links every agent copy to it. Other identical folders go to
  /// the Trash. If any step fails, the earlier steps are undone.
  @discardableResult
  static func moveToCentral(_ skill: Skill) throws -> (destination: URL, trashed: [URL]) {
    guard skill.copies.contains(where: { $0.root.kind == .user }) else { throw Failure.builtIn(skill.name) }
    guard let source = centralSource(skill) else {
      throw Failure.problem("\(skill.name) links to a folder outside your skills folders. Move that folder yourself, or add it to Library as a local repository.")
    }
    guard !skill.copiesDiffer else { throw Failure.conflictingCopies(skill.name) }
    if let protected = skill.copies.first(where: { isManaged($0.resolved) }) {
      throw Failure.managed(protected.resolved)
    }

    let fm = FileManager.default
    let managedRoot = SkillRoot.all.first { $0.kind == .managed }!.url
    try fm.createDirectory(at: managedRoot, withIntermediateDirectories: true)
    let destination = managedRoot.appending(path: slug(skill.name))
    guard !exists(destination) else { throw Failure.alreadyExists(destination) }

    var undo: [() throws -> Void] = []
    var trashedCopies: [URL] = []
    do {
      try fm.moveItem(at: source.folder, to: destination)
      undo.append { try fm.moveItem(at: destination, to: source.folder) }
      for copy in skill.copies where copy.root.kind == .user || copy.root.kind == .shared {
        if copy.folder != source.folder, exists(copy.folder) {
          if let target = try? fm.destinationOfSymbolicLink(atPath: copy.folder.path) {
            try fm.removeItem(at: copy.folder)
            undo.append { try fm.createSymbolicLink(atPath: copy.folder.path, withDestinationPath: target) }
          } else {
            var trashed: NSURL?
            try fm.trashItem(at: copy.folder, resultingItemURL: &trashed)
            if let trashed = trashed as URL? {
              trashedCopies.append(trashed)
              undo.append { try fm.moveItem(at: trashed, to: copy.folder) }
            }
          }
        }
        try fm.createSymbolicLink(at: copy.folder, withDestinationURL: destination)
        undo.append { try fm.removeItem(at: copy.folder) }
      }
    } catch {
      var issues: [String] = []
      for step in undo.reversed() {
        do { try step() } catch { issues.append(error.localizedDescription) }
      }
      if issues.isEmpty { throw error }
      throw Failure.problem("Moving \(skill.name) to Library failed (\(error.localizedDescription)), and some steps couldn't be undone: \(issues.joined(separator: " ")). Check the Trash.")
    }
    return (destination, trashedCopies)
  }

  /// The folders a move to the Library replaced, mapped to the Library folder, for saved sources and receipts.
  static func centralMoves(_ skill: Skill, to destination: URL) -> [String: String] {
    Dictionary(skill.copies.filter { !$0.isSymlink && ($0.root.kind == .user || $0.root.kind == .shared) }
      .map { ($0.resolved.path, destination.resolvingSymlinksInPath().path) }, uniquingKeysWith: { first, _ in first })
  }

  /// Remove only the repository and links into it, preserving independent copies of its skills.
  @discardableResult
  static func removeRepo(name: String) throws -> [URL] {
    guard !name.isEmpty, name == slug(name) else { throw InstallFailure.notFound }
    let root = Paths.libraryFolder.resolvingSymlinksInPath()
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

    var errorDescription: String? { "\(Paths.describe(destination)) already contains an installation. Choose whether to keep it or replace it." }
  }

  private static func installationSignature(_ folder: URL) throws -> String {
    let fm = FileManager.default
    if let target = try? fm.destinationOfSymbolicLink(atPath: folder.path) {
      return "link:\(target)"
    }
    guard (try folder.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
      throw Failure.problem("\(Paths.describe(folder)) is not a skill folder. Move it aside before installing.")
    }
    return "folder:\(try skillsetFingerprint(folder))"
  }

  static func add(_ skill: Skill, to tool: Tool, from selectedSource: SkillCopy? = nil) throws -> URL {
    guard !installableSources(for: skill).isEmpty else { throw Failure.builtIn(skill.name) }
    guard let source = selectedSource ?? defaultSource(for: skill) else { throw InstallFailure.sourceChoiceRequired(skill.name) }
    switch try addPreview(skill, to: tool, from: source) {
    case .available(let destination): return destination
    case .conflict(let conflict): throw conflict
    case .ready(let destination):
      try FileManager.default.createDirectory(at: tool.skillsFolder, withIntermediateDirectories: true)
      try createInstallation(from: source, at: destination)
      return destination
    }
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

  static func install(source: String, explicitTools: [Tool]? = nil, token: String? = nil, stagingAt: URL? = nil, ref: RepositoryRef = .defaultBranch) async throws -> URL {
    let repositorySource = try RepositorySource(address: source)
    let preview = try await RepositoryLibrary.preview(source: repositorySource, ref: ref, token: token)
    defer { RepositoryLibrary.discard(preview) }
    guard !preview.skills.isEmpty else { throw InstallFailure.invalidSkill }
    if let staged = stagingAt {
      guard staged.deletingLastPathComponent().standardizedFileURL == RepositoryLibrary.managedRoot.standardizedFileURL else { throw InstallFailure.notFound }
      try copyRepositoryPreview(preview, to: staged, consume: true)
      try linkSkills(in: staged, name: repoName(for: source), explicitTools: explicitTools)
      return staged
    }
    return try importRepository(preview: preview, explicitTools: explicitTools, consumePreview: true)
  }

  static func writeRepositorySnapshot(_ preview: RepositoryPreview, in folder: URL) throws {
    let fm = FileManager.default
    guard (try fm.attributesOfItem(atPath: folder.path))[.type] as? FileAttributeType == .typeDirectory else { throw RepositoryLibrary.Failure.stalePreview }
    for name in [RepositoryLibrary.markerName, RepositoryMerge.archiveName, ".skillscout-local-source"] {
      let marker = folder.appending(path: name)
      if (try? fm.attributesOfItem(atPath: marker.path))?[.type] as? FileAttributeType == .typeSymbolicLink {
        try fm.removeItem(at: marker)
      }
    }
    let archiveDigest = try RepositoryMerge.writeArchive(in: folder)
    let snapshot = InstalledSnapshot(source: preview.source, ref: preview.ref, commit: preview.commit,
      baselineFingerprints: preview.fingerprints, installedAt: Date(), upstreamArchiveDigest: archiveDigest)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(snapshot).write(to: folder.appending(path: RepositoryLibrary.markerName), options: .atomic)
    if !preview.source.isGit {
      try preview.source.address.write(to: folder.appending(path: ".skillscout-local-source"), atomically: true, encoding: .utf8)
    }
  }

  private static func verifyRepositoryPreview(_ preview: RepositoryPreview) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: preview.folder.path)
    guard preview.folder.deletingLastPathComponent().standardizedFileURL == RepositoryLibrary.previewRoot.standardizedFileURL,
          preview.folder.lastPathComponent == preview.id.uuidString,
          attributes[.type] as? FileAttributeType == .typeDirectory,
          preview.repositoryID == RepositoryID(source: preview.source),
          SkillReview.fingerprints(preview.folder) == preview.fingerprints,
          (try? RepositoryMerge.seal(preview.folder)) == preview.contentSeal else { throw RepositoryLibrary.Failure.stalePreview }
    if preview.source.isGit {
      let commit = try RepositoryGit.runSynchronously(["-C", preview.folder.path, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard commit == preview.commit else { throw RepositoryLibrary.Failure.stalePreview }
    }
  }

  static func copyRepositoryPreview(_ preview: RepositoryPreview, to destination: URL, consume: Bool = false) throws {
    try verifyRepositoryPreview(preview)
    try RepositoryMerge.validateAncestors(destination.deletingLastPathComponent())
    let fm = FileManager.default
    guard !exists(destination) else { throw Failure.alreadyExists(destination) }
    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
      let sourceVolume = (try? fm.attributesOfFileSystem(forPath: preview.folder.path))?[.systemNumber] as? NSNumber
      let destinationVolume = (try? fm.attributesOfFileSystem(forPath: destination.deletingLastPathComponent().path))?[.systemNumber] as? NSNumber
      if consume, let sourceVolume, sourceVolume == destinationVolume {
        try fm.moveItem(at: preview.folder, to: destination)
      } else {
        try fm.copyItem(at: preview.folder, to: destination)
      }
      guard (try fm.attributesOfItem(atPath: destination.path))[.type] as? FileAttributeType == .typeDirectory,
            SkillReview.fingerprints(destination) == preview.fingerprints,
            (try? RepositoryMerge.seal(destination)) == preview.contentSeal else { throw RepositoryLibrary.Failure.stalePreview }
      try writeRepositorySnapshot(preview, in: destination)
      if consume, exists(preview.folder) { try fm.removeItem(at: preview.folder) }
    }
    catch { try? fm.removeItem(at: destination); throw error }
  }

  static func importRepository(preview: RepositoryPreview, explicitTools: [Tool]? = [], root: URL = RepositoryLibrary.managedRoot,
                               consumePreview: Bool = false) throws -> URL {
    defer { if consumePreview { RepositoryLibrary.discard(preview) } }
    let inventory = RepositoryLibrary.inventory(catalog: [], root: root)
    if let existing = inventory.first(where: { RepositoryID(source: $0.source) == preview.repositoryID }), let folder = existing.installedFolder {
      try verifyRepositoryPreview(preview)
      guard existing.issue == nil,
            existing.snapshot?.commit == preview.commit,
            existing.snapshot?.ref == preview.ref,
            SkillReview.fingerprints(folder) == preview.fingerprints else { throw RepositoryLibrary.Failure.conflictingInstall }
      try linkSkills(in: folder, explicitTools: explicitTools)
      return folder
    }
    let slug = repoName(for: preview.source.address)
    var destination = root.appending(path: slug)
    if exists(destination) {
      let suffix = SHA256.hash(data: Data(preview.repositoryID.rawValue.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
      destination = root.appending(path: slug + "-" + suffix)
    }
    guard !exists(destination) else { throw Failure.alreadyExists(destination) }
    let staged = root.appending(path: "." + slug + "-import-" + UUID().uuidString)
    try copyRepositoryPreview(preview, to: staged, consume: consumePreview)
    defer { if exists(staged) { try? FileManager.default.removeItem(at: staged) } }
    try FileManager.default.moveItem(at: staged, to: destination)
    try linkSkills(in: destination, explicitTools: explicitTools)
    return destination
  }

  /// The skill folders in a Library repository, including the hidden `.claude/skills` folder some repositories use.
  static func skillFolders(in destination: URL) -> [URL] {
    let fm = FileManager.default
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
    return skillDirs
  }

  /// Links each skill of a Library repository into the tools that should load it: the explicit tools,
  /// else the skill's `supported_tools`, else every enabled tool.
  static func linkSkills(in destination: URL, name: String? = nil, explicitTools: [Tool]?) throws {
    if explicitTools?.isEmpty == true { return }
    let fm = FileManager.default
    let name = name ?? destination.lastPathComponent
    let skillDirs = skillFolders(in: destination)
    for skillDir in skillDirs {
       let skillFile = skillDir.appending(path: "SKILL.md")
       guard skillFile.resolvingSymlinksInPath().path.hasPrefix(destination.resolvingSymlinksInPath().path + "/") else { continue }
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
  }

  static func save(markdown: String, fallbackName: String, to target: SaveTarget) throws -> URL {
    let name = slug(Frontmatter.parse(markdown)["name"] ?? fallbackName)
    let fm = FileManager.default

    let shared = SkillRoot.all[0]
    let folder: URL
    switch target {
    case .library: folder = SkillRoot.all.first { $0.kind == .drafts }!.url.appending(path: name)
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

  /// Rewrites a folder and its descendants, never a sibling with a similar name.
  static func relocatedPath(_ path: String, folders: [String: String]) -> String {
    guard let old = folders.keys.sorted(by: { $0.count > $1.count }).first(where: {
      path == $0 || path.hasPrefix($0 + "/")
    }) else { return path }
    return folders[old]! + path.dropFirst(old.count)
  }

  struct LibraryRepairResult {
    var movedFolders: [String: String] = [:]
    var repairedLinks = 0
    var removedPaths: Set<String> = []
    var trashed: [URL] = []
    var issues: [String] = []

    var message: String {
      var parts: [String] = []
      if !movedFolders.isEmpty { parts.append("Renamed \(movedFolders.count) repos") }
      if repairedLinks > 0 { parts.append("Fixed \(repairedLinks) links") }
      if !removedPaths.isEmpty { parts.append("Moved \(removedPaths.count) broken Library links to Trash") }
      parts += issues
      return parts.isEmpty ? "No issues found." : parts.joined(separator: ". ") + "."
    }
  }

  /// Repairs only personal roots. Failed renames restore the original folder and links.
  static func repairLibrary() -> LibraryRepairResult {
    let fm = FileManager.default
    let managed = SkillRoot.all.first { $0.kind == .managed }!.url
    let roots = SkillRoot.all.filter { $0.kind == .user || $0.kind == .shared }
    var result = LibraryRepairResult()
    let folders = (try? fm.contentsOfDirectory(at: managed, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
    for folder in folders.sorted(by: { $0.path < $1.path }) {
      guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
            values.isDirectory == true, values.isSymbolicLink != true,
            fm.fileExists(atPath: folder.appending(path: ".git/config").path) else { continue }
      do {
        let name = repoName(for: try repoSource(name: folder.lastPathComponent))
        guard !name.isEmpty, name != folder.lastPathComponent else { continue }
        let destination = managed.appending(path: name)
        guard !exists(destination) else { throw Failure.alreadyExists(destination) }
        var links: [(url: URL, original: String, replacement: String)] = []
        for root in roots where fm.fileExists(atPath: root.url.path) {
          for link in try fm.contentsOfDirectory(at: root.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            guard let target = try? fm.destinationOfSymbolicLink(atPath: link.path) else { continue }
            let absolute = URL(fileURLWithPath: target, relativeTo: link.deletingLastPathComponent()).standardizedFileURL.path
            let replacement = relocatedPath(absolute, folders: [folder.path: destination.path])
            if replacement != absolute { links.append((link, target, replacement)) }
          }
        }
        try fm.moveItem(at: folder, to: destination)
        var changed: [(url: URL, original: String, replacement: String)] = []
        do {
          for link in links {
            guard (try? fm.destinationOfSymbolicLink(atPath: link.url.path)) == link.original else {
              throw Failure.changedOnDisk(link.url)
            }
            try fm.removeItem(at: link.url)
            changed.append(link)
            try fm.createSymbolicLink(atPath: link.url.path, withDestinationPath: link.replacement)
          }
        } catch {
          for link in changed.reversed() {
            do {
              if exists(link.url) {
                guard (try? fm.destinationOfSymbolicLink(atPath: link.url.path)) == link.replacement else {
                  throw Failure.changedOnDisk(link.url)
                }
                try fm.removeItem(at: link.url)
              }
              try fm.createSymbolicLink(atPath: link.url.path, withDestinationPath: link.original)
            } catch { result.issues.append("Could not restore \(Paths.describe(link.url)): \(error.localizedDescription)") }
          }
          do { try fm.moveItem(at: destination, to: folder) }
          catch { result.issues.append("Could not restore \(Paths.describe(folder)): \(error.localizedDescription)") }
          throw error
        }
        result.movedFolders[folder.path] = destination.path
        result.repairedLinks += links.count
      } catch {
        result.issues.append("Could not repair \(folder.lastPathComponent): \(error.localizedDescription)")
      }
    }
    // Do not sweep links after an incomplete repair; their targets may still need restoration.
    guard result.issues.isEmpty else { return result }
    // Move broken links into the Library to the Trash, so they stay recoverable. Other broken links may point
    // to a drive or folder that is only away for now, so they stay. Plugin and built-in roots are never touched.
    for root in roots where fm.fileExists(atPath: root.url.path) {
      do {
        for link in try fm.contentsOfDirectory(at: root.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
          guard let target = try? fm.destinationOfSymbolicLink(atPath: link.path) else { continue }
          let absolute = URL(fileURLWithPath: target, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
          guard !fm.fileExists(atPath: absolute.path), Paths.libraryLocation(absolute) != nil else { continue }
          var trashed: NSURL?
          try fm.trashItem(at: link, resultingItemURL: &trashed)
          if let trashed { result.trashed.append(trashed as URL) }
          result.removedPaths.insert(link.path)
        }
      } catch { result.issues.append("Could not repair \(Paths.describe(root.url)): \(error.localizedDescription)") }
    }
    return result
  }
}

extension SkillsetState {
  /// Carries explicit ownership through a user-requested rename or merge without adopting other entries.
  mutating func migrateSkill(from oldID: String, to newID: String, movedFolders: [String: String],
                             merging: Bool, ownedBefore: Set<SkillsetEntry>) {
    for index in skillsets.indices where skillsets[index].skills.remove(oldID) != nil {
      skillsets[index].skills.insert(newID)
    }
    for index in assignments.indices where assignments[index].members.remove(oldID) != nil {
      assignments[index].members.insert(newID)
    }
    if let preferred = preferredSources.removeValue(forKey: oldID), !merging {
      preferredSources[newID] = SkillInstaller.relocatedPath(preferred, folders: movedFolders)
    }
    entries = entries.compactMap { entry in
      let path = SkillInstaller.relocatedPath(entry.path, folders: movedFolders)
      if merging && entry.skillID == oldID && (path == entry.path || !ownedBefore.contains(entry)) { return nil }
      return migratedEntry(entry, id: entry.skillID == oldID ? newID : entry.skillID,
        path: path, movedFolders: movedFolders, ownedBefore: ownedBefore,
        refreshContents: merging && entry.skillID == newID)
    }
    // A kept skill's existing receipt wins over a merged entry mapping to the same destination.
    var paths: Set<String> = []
    entries = entries.filter { paths.insert($0.path).inserted }
  }

  mutating func relocateFolders(_ folders: [String: String], removedPaths: Set<String>, ownedBefore: Set<SkillsetEntry>) {
    preferredSources = preferredSources.mapValues { SkillInstaller.relocatedPath($0, folders: folders) }
    entries = entries.filter { !removedPaths.contains($0.path) }.map { entry in
      migratedEntry(entry, id: entry.skillID, path: SkillInstaller.relocatedPath(entry.path, folders: folders),
        movedFolders: folders, ownedBefore: ownedBefore)
    }
  }

  /// After a move into the Library: saved sources and recorded link targets follow the moved folders, while
  /// each receipt keeps its own path, which now holds a link.
  mutating func relocateSources(_ folders: [String: String], ownedBefore: Set<SkillsetEntry>) {
    preferredSources = preferredSources.mapValues { SkillInstaller.relocatedPath($0, folders: folders) }
    entries = entries.map { entry in
      let moved = folders.keys.contains(entry.path)
      return migratedEntry(entry, id: entry.skillID, path: entry.path, movedFolders: folders, ownedBefore: ownedBefore, refreshContents: moved)
    }
  }

  private func migratedEntry(_ entry: SkillsetEntry, id: String, path: String,
                             movedFolders: [String: String], ownedBefore: Set<SkillsetEntry>,
                             refreshContents: Bool = false) -> SkillsetEntry {
    var destination = entry.linkDestination.map { target in
      let absolute = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: entry.path).deletingLastPathComponent()).standardizedFileURL.path
      let moved = SkillInstaller.relocatedPath(absolute, folders: movedFolders)
      return moved == absolute ? target : moved
    }
    var fingerprint = entry.fingerprint
    if ownedBefore.contains(entry), id != entry.skillID || path != entry.path || destination != entry.linkDestination || refreshContents {
      if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
        destination = target
        fingerprint = nil
      } else {
        destination = nil
        fingerprint = (try? SkillInstaller.skillsetFingerprint(URL(fileURLWithPath: path))) ?? fingerprint
      }
    }
    return SkillsetEntry(skillID: id, tool: entry.tool, path: path, linkDestination: destination, fingerprint: fingerprint)
  }
}


extension SkillInstaller {
  enum AddPreview: Sendable {
    case available(URL)
    case ready(URL)
    case conflict(AddConflict)
  }

  static func addPreview(_ skill: Skill, to tool: Tool, from source: SkillCopy) throws -> AddPreview {
    guard installableSources(for: skill).contains(where: { $0.resolved.path == source.resolved.path }) else {
      throw InstallFailure.sourceChoiceRequired(skill.name)
    }
    guard FileManager.default.fileExists(atPath: source.resolved.appending(path: "SKILL.md").path) else {
      throw InstallFailure.invalidSkill
    }
    if skill.copies.contains(where: {
      $0.root.readBy.contains(tool) && $0.resolved.path == source.resolved.path
        && $0.folder.resolvingSymlinksInPath().path == source.resolved.path
        && FileManager.default.fileExists(atPath: $0.folder.appending(path: "SKILL.md").path)
    }) { return .available(source.resolved) }
    let destination = tool.skillsFolder.appending(path: source.resolved.lastPathComponent)
    if exists(destination) {
      if destination.resolvingSymlinksInPath().path == source.resolved.path { return .available(destination) }
      guard !isManaged(destination.deletingLastPathComponent()) else { throw Failure.managed(destination) }
      return .conflict(AddConflict(skill: skill, tool: tool, source: source, destination: destination,
        signature: try installationSignature(destination)))
    }
    return .ready(destination)
  }

  private static func reviewedSource(_ request: SkillAddRequest, among skills: [Skill]) throws -> (Skill, SkillCopy) {
    guard let skill = skills.first(where: { $0.id == request.skillID }),
          let source = installableSources(for: skill).first(where: { $0.resolved.path == request.sourcePath }) else {
      throw Failure.problem("Source is missing. Choose an available source.")
    }
    guard try skillsetFingerprint(source.resolved) == request.reviewedFingerprint else {
      throw Failure.problem("Source contents changed. Inspect them again before adding.")
    }
    return (skill, source)
  }

  static func addReviewed(_ request: SkillAddRequest, among skills: [Skill]) -> SkillAddResult {
    do {
      let (skill, source) = try reviewedSource(request, among: skills)
      let outcome: SkillAddOutcome
      switch try addPreview(skill, to: request.tool, from: source) {
      case .available(let folder): outcome = .available(folder)
      case .conflict(let conflict): outcome = .conflict(conflict)
      case .ready: outcome = .added(try add(skill, to: request.tool, from: source))
      }
      return SkillAddResult(request: request, outcome: outcome)
    } catch let conflict as AddConflict {
      return SkillAddResult(request: request, outcome: .conflict(conflict))
    } catch {
      return SkillAddResult(request: request, outcome: .failed(error.localizedDescription))
    }
  }

  static func replaceReviewed(_ request: SkillAddRequest, conflict: AddConflict, among skills: [Skill]) -> SkillAddResult {
    do {
      _ = try reviewedSource(request, among: skills)
      guard conflict.skill.id == request.skillID, conflict.tool == request.tool,
            conflict.source.resolved.path == request.sourcePath else { throw InstallFailure.invalidSkill }
      return SkillAddResult(request: request, outcome: .added(try replace(conflict).destination))
    } catch {
      return SkillAddResult(request: request, outcome: .failed(error.localizedDescription))
    }
  }
}

extension SkillInstaller {
  struct DraftSaveResult {
    let folder: URL
    let skillID: Skill.ID
    let issues: [String]
  }

  static func saveDraft(markdown: String, fallbackName: String, to target: SaveTarget) throws -> DraftSaveResult {
    let initial: SaveTarget
    switch target {
    case .everywhere: initial = .everywhere([])
    case .library, .tool: initial = target
    }
    let folder = try save(markdown: markdown, fallbackName: fallbackName, to: initial)
    let identity = Frontmatter.parse(markdown)["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
    var issues: [String] = []
    if case .everywhere(let tools) = target {
      let root = SkillRoot.all[0]
      let copy = SkillCopy(folder: folder, resolved: folder, root: root, pluginName: nil, isSymlink: false,
        contentHash: shortHash(markdown), created: Date())
      let skill = Skill(name: identity, description: "", copies: [copy])
      for tool in linkTargets(for: tools) {
        do { _ = try add(skill, to: tool, from: copy) }
        catch { issues.append("\(tool.name): \(error.localizedDescription)") }
      }
    }
    return DraftSaveResult(folder: folder, skillID: identity, issues: issues)
  }
}

// MARK: - Rename to Quartermaster

extension SkillInstaller {
  /// Moves the folder Skillscout kept the Library in, ~/.config/skillscout, to Quartermaster's. The old path
  /// stays as a link to the new folder, so links and scripts that name it keep working, while the links in the
  /// agents' folders and the paths in the state file follow the move. If the folder can't move, the new path
  /// links to the old one instead. Runs again safely: once the old path is a link, it only relinks.
  static func moveConfigFolder(
    home: URL = Paths.home, stateFile: URL = Paths.stateFile,
    roots: [URL] = SkillRoot.all.filter { $0.kind == .user || $0.kind == .shared }.map(\.url)
  ) {
    let fm = FileManager.default
    let old = home.appending(path: ".config/skillscout"), new = home.appending(path: ".config/quartermaster")
    // Absolute targets as written: standardizedFileURL would drop the /private of an existing /private/tmp path.
    func linkTarget(_ url: URL) -> String? {
      (try? fm.destinationOfSymbolicLink(atPath: url.path)).map {
        $0.hasPrefix("/") ? $0 : URL(fileURLWithPath: $0, relativeTo: url.deletingLastPathComponent()).absoluteURL.standardized.path
      }
    }
    if let target = linkTarget(old) {
      // The user's own link, to a dotfiles folder say: the new path points to the same place.
      if target != new.path, !exists(new) { try? fm.createSymbolicLink(atPath: new.path, withDestinationPath: target) }
      guard target == new.path else { return }
    } else {
      var isDirectory: ObjCBool = false
      guard fm.fileExists(atPath: old.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
      // An empty folder at the new path, left by an earlier run say, gives way. Anything in it is kept.
      if exists(new), linkTarget(new) == nil { rmdir(new.path) }
      guard !exists(new) else { return }
      do {
        try fm.moveItem(at: old, to: new)
      } catch {
        try? fm.createSymbolicLink(atPath: new.path, withDestinationPath: old.path)
        return
      }
      try? fm.createSymbolicLink(atPath: old.path, withDestinationPath: new.path)
    }
    let folders = [old.path: new.path]
    for root in roots {
      for link in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
        guard let target = linkTarget(link) else { continue }
        let moved = relocatedPath(target, folders: folders)
        guard moved != target else { continue }
        // A new link under a temporary name replaces the old one in a single rename.
        let temporary = root.appending(path: ".quartermaster-relink-\(UUID().uuidString)")
        guard (try? fm.createSymbolicLink(atPath: temporary.path, withDestinationPath: moved)) != nil else { continue }
        if Darwin.rename(temporary.path, link.path) != 0 { try? fm.removeItem(at: temporary) }
      }
    }
    relocatePaths(in: stateFile, folders: folders)
  }

  /// Rewrites every path in a JSON file that's in one of `folders`, and saves the file only if one changed.
  static func relocatePaths(in file: URL, folders: [String: String]) {
    guard let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) else { return }
    var changed = false
    func relocate(_ value: Any) -> Any {
      switch value {
      case let string as String:
        let moved = relocatedPath(string, folders: folders)
        if moved != string { changed = true }
        return moved
      case let array as [Any]: return array.map(relocate)
      case let dictionary as [String: Any]: return dictionary.mapValues(relocate)
      default: return value
      }
    }
    let relocated = relocate(object)
    guard changed, let output = try? JSONSerialization.data(withJSONObject: relocated) else { return }
    try? output.write(to: file, options: .atomic)
  }
}
