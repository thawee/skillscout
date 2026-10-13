import Foundation
import CryptoKit

struct RepositoryID: RawRepresentable, Hashable, Codable, Sendable {
  let rawValue: String
  init(rawValue: String) { self.rawValue = rawValue }
  init(source: RepositorySource) {
    switch source {
    case .local(let path): rawValue = "local:" + URL(fileURLWithPath: path).standardizedFileURL.path
    case .git(let address):
      var value = RepositoryLibrary.cleanAddress(address)
      let equivalentHosts: Set<String> = ["github.com", "gitlab.com", "bitbucket.org"]
      if value.hasPrefix("git@"), let colon = value.firstIndex(of: ":"), equivalentHosts.contains(String(value[value.index(value.startIndex, offsetBy: 4)..<colon]).lowercased()) {
        value = "https://" + value[value.index(value.startIndex, offsetBy: 4)..<colon] + "/" + value[value.index(after: colon)...]
      }
      if var url = URLComponents(string: value), let host = url.host {
        url.host = host.lowercased()
        if equivalentHosts.contains(host.lowercased()), url.port == nil, ["https", "http", "ssh"].contains(url.scheme ?? "") { url.scheme = "https"; url.user = nil }
        value = url.string ?? value
      }
      while value.hasSuffix("/") { value.removeLast() }
      if value.hasSuffix(".git") { value.removeLast(4) }
      rawValue = "git:" + value
    }
  }
}

enum RepositorySource: Codable, Hashable, Sendable {
  case git(String), local(String)
  init(address: String) throws {
    let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw RepositoryLibrary.Failure.invalidSource }
    if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("ssh://") || value.hasPrefix("git@") || value.hasPrefix("file://") {
      self = .git(RepositoryLibrary.cleanAddress(value))
    } else if value.hasPrefix("/") || value.hasPrefix("~/") {
      self = .local(URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path)
    } else { throw RepositoryLibrary.Failure.invalidSource }
  }
  var address: String { switch self { case .git(let value), .local(let value): value } }
  var isGit: Bool { if case .git = self { true } else { false } }
}

enum RepositoryRef: Codable, Hashable, Sendable {
  case defaultBranch, branch(String), tag(name: String, commit: String? = nil), commit(String)
  var label: String {
    switch self {
    case .defaultBranch: "Default branch"
    case .branch(let name): "Branch: \(name)"
    case .tag(let name, _): "Tag: \(name)"
    case .commit(let value): "Commit: \(value.prefix(12))"
    }
  }
  var isPinned: Bool { switch self { case .tag, .commit: true; default: false } }
}

struct InstalledSnapshot: Codable, Hashable, Sendable {
  var version = 1
  let source: RepositorySource
  let ref: RepositoryRef
  let commit: String?
  let baselineFingerprints: [String: String]
  let installedAt: Date
  var upstreamArchiveDigest: String? = nil
}

struct RepositoryEntry: Identifiable, Sendable {
  let id: RepositoryID
  let name: String
  let description: String
  var source: RepositorySource
  let catalog: RegistrySkill?
  var installedFolder: URL?
  var snapshot: InstalledSnapshot?
  var issue: String?
}

struct RepositorySkill: Identifiable, Hashable, Sendable {
  var id: String { relativePath }
  let skill: Skill
  let copy: SkillCopy
  let relativePath: String
}

struct RepositoryPreview: Identifiable, Sendable {
  let id: UUID
  let repositoryID: RepositoryID
  let source: RepositorySource
  let ref: RepositoryRef
  let commit: String?
  let folder: URL
  let fingerprints: [String: String]
  let skills: [RepositorySkill]
  let review: SkillReview
  let contentSeal: String
}

struct RepositoryCheck: Sendable {
  enum Status: String, Sendable { case upToDate, updateAvailable, pinned, tagMoved }
  let status: Status
  let installedCommit: String?
  let latestCommit: String?
  let checkedAt: Date
  var message: String {
    switch status {
    case .upToDate: "Up to date"
    case .updateAvailable: "Update available"
    case .pinned: "Pinned version"
    case .tagMoved: "The remote tag moved. The installed version remains pinned."
    }
  }
}

enum RepositoryLibrary {
  static let markerName = Paths.repositoryMarkers[0]
  static let upstreamMarkerName = Paths.repositoryMarkers[1]
  static var managedRoot: URL { SkillRoot.all.first { $0.kind == .managed }!.url }
  static var previewRoot: URL { FileManager.default.temporaryDirectory.appending(path: "skillscout-repository-previews") }

  enum Failure: LocalizedError {
    case invalidSource, metadata(String), missingRef(String), stalePreview, conflictingInstall, expectedCommit(String), git(String), timeout
    var errorDescription: String? {
      switch self {
      case .invalidSource: "Enter a Git repository address or an absolute folder path."
      case .metadata(let message): "Repository metadata: \(message)"
      case .missingRef(let ref): "The repository does not contain \(ref)."
      case .stalePreview: "The repository preview changed or expired. Load its skills again."
      case .conflictingInstall: "This repository already has a different Library snapshot. Review an update instead."
      case .expectedCommit(let commit): "The repository changed since checking for updates. Check again (expected \(commit.prefix(12)))."
      case .git(let message): message
      case .timeout: "Git timed out. Check your connection and retry."
      }
    }
  }

  static func cleanAddress(_ address: String) -> String {
    guard var components = URLComponents(string: address), components.host != nil else { return address }
    if components.scheme != "ssh" { components.user = nil }
    components.password = nil
    components.query = nil
    components.fragment = nil
    return components.string ?? address
  }

  static func snapshot(in folder: URL) throws -> InstalledSnapshot? {
    let file = folder.appending(path: markerName)
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { return nil }
    guard attributes[.type] as? FileAttributeType == .typeRegular else { throw Failure.metadata("The installed marker must be a regular file.") }
    guard let value = try? JSONDecoder().decode(InstalledSnapshot.self, from: Data(contentsOf: file)) else {
      throw Failure.metadata("The installed marker is damaged. Its files remain available.")
    }
    if let digest = value.upstreamArchiveDigest, digest.count != 64 || !digest.allSatisfy({ $0.isHexDigit }) { throw Failure.metadata("The upstream archive digest is invalid.") }
    guard value.version == 1 else { throw Failure.metadata("Unsupported marker version \(value.version).") }
    guard value.source.address == cleanAddress(value.source.address) else { throw Failure.metadata("The installed source contains credentials.") }
    guard (try? RepositorySource(address: value.source.address)) == value.source else { throw Failure.metadata("The installed source is invalid.") }
    if value.source.isGit, value.commit.map({ isCommit($0) }) != true { throw Failure.metadata("The installed commit is invalid.") }
    switch value.ref {
    case .branch(let name): try validateRef(name)
    case .tag(let name, let pin):
      try validateRef(name)
      guard pin == value.commit, pin.map(isCommit) == true else { throw Failure.metadata("The tag pin does not match its installed commit.") }
    case .commit(let pin):
      guard pin == value.commit, isCommit(pin) else { throw Failure.metadata("The commit pin is invalid.") }
    case .defaultBranch: break
    }
    if !value.source.isGit, value.commit != nil || value.ref != .defaultBranch { throw Failure.metadata("Local folders cannot have a Git version.") }
    return value
  }

  static func legacySource(in folder: URL) -> RepositorySource? {
    if let path = try? String(contentsOf: folder.appending(path: ".skillscout-local-source"), encoding: .utf8), !path.isEmpty {
      return .local(path.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    guard let config = try? String(contentsOf: folder.appending(path: ".git/config"), encoding: .utf8) else { return nil }
    var origin = false
    for raw in config.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") { origin = line == "[remote \"origin\"]" }
      if origin, line.hasPrefix("url"), let equals = line.firstIndex(of: "=") {
        return .git(cleanAddress(String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)))
      }
    }
    return nil
  }

  static func legacySnapshot(in folder: URL, source: RepositorySource) -> InstalledSnapshot? {
    guard source.isGit,
          let head = try? String(contentsOf: folder.appending(path: ".git/HEAD"), encoding: .utf8) else { return nil }
    let value = head.trimmingCharacters(in: .whitespacesAndNewlines)
    var commit: String?
    var ref: RepositoryRef = .defaultBranch
    if value.hasPrefix("ref: refs/heads/") {
      let name = String(value.dropFirst("ref: refs/heads/".count))
      guard (try? validateRef(name)) != nil else { return nil }
      ref = .branch(name)
      commit = (try? String(contentsOf: folder.appending(path: ".git/refs/heads/" + name), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
      if commit == nil, let packed = try? String(contentsOf: folder.appending(path: ".git/packed-refs"), encoding: .utf8) {
        let target = "refs/heads/" + name
        commit = packed.components(separatedBy: .newlines).compactMap { line -> String? in
          let parts = line.split(separator: " ")
          return parts.count == 2 && parts[1] == target ? String(parts[0]) : nil
        }.first
      }
    } else if isCommit(value) { commit = value }
    guard let commit, isCommit(commit) else { return nil }
    return InstalledSnapshot(source: source, ref: ref, commit: commit, baselineFingerprints: [:], installedAt: .distantPast)
  }

  static func inventory(catalog: [RegistrySkill], custom: [RegistrySkill] = [], root: URL = managedRoot) -> [RepositoryEntry] {
    var entries: [RepositoryEntry] = []
    for item in catalog + custom {
      guard let source = try? RepositorySource(address: item.repo) else { continue }
      let id = RepositoryID(source: source)
      guard !entries.contains(where: { $0.id == id }) else { continue }
      entries.append(RepositoryEntry(id: id, name: item.name, description: item.description, source: source, catalog: item))
    }
    let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
    for folder in folders.sorted(by: { $0.path < $1.path }) {
      guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else { continue }
      var metadata: InstalledSnapshot?
      var issue: String?
      do { metadata = try snapshot(in: folder) } catch { issue = error.localizedDescription }
      let source = metadata?.source ?? legacySource(in: folder) ?? .local(folder.path)
      if metadata == nil, issue == nil { metadata = legacySnapshot(in: folder, source: source) }
      let id = RepositoryID(source: source)
      if let index = entries.firstIndex(where: { $0.id == id && $0.installedFolder == nil }) {
        entries[index].source = source
        entries[index].installedFolder = folder; entries[index].snapshot = metadata; entries[index].issue = issue
      } else {
        let physicalID = entries.contains(where: { $0.id == id }) ? RepositoryID(rawValue: id.rawValue + "#" + folder.lastPathComponent) : id
        entries.append(RepositoryEntry(id: physicalID, name: folder.lastPathComponent, description: "Imported repository", source: source, catalog: nil, installedFolder: folder, snapshot: metadata, issue: issue))
      }
    }
    return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  static func skills(in folder: URL) -> [RepositorySkill] {
    let base = folder.resolvingSymlinksInPath()
    let root = SkillRoot(label: "Repository", url: base, kind: .managed, owner: nil, readBy: [])
    return SkillInstaller.skillFolders(in: base).compactMap { skillFolder in
      guard skillFolder.resolvingSymlinksInPath().path == base.path || skillFolder.resolvingSymlinksInPath().path.hasPrefix(base.path + "/"),
            skillFolder.appending(path: "SKILL.md").resolvingSymlinksInPath().path.hasPrefix(base.path + "/") else { return nil }
      guard let text = try? String(contentsOf: skillFolder.appending(path: "SKILL.md"), encoding: .utf8) else { return nil }
      let meta = Frontmatter.parse(text)
      let copy = SkillCopy(folder: skillFolder, resolved: skillFolder.resolvingSymlinksInPath(), root: root, pluginName: nil, isSymlink: false, contentHash: shortHash(text), created: .distantPast)
      let skill = Skill(name: meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? skillFolder.lastPathComponent, description: meta["description"] ?? "", copies: [copy])
      let components = skillFolder.resolvingSymlinksInPath().pathComponents.dropFirst(base.pathComponents.count)
      let relative = components.isEmpty ? "." : components.joined(separator: "/")
      return RepositorySkill(skill: skill, copy: copy, relativePath: relative)
    }.sorted { $0.relativePath < $1.relativePath }
  }

  static func isCommit(_ value: String) -> Bool {
    (value.count == 40 || value.count == 64) && value.allSatisfy { $0.isHexDigit }
  }

  static func fullCommit(in folder: URL) async throws -> String {
    try await RepositoryGit.run(["-C", folder.path, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func preview(source: RepositorySource, ref: RepositoryRef = .defaultBranch, token: String? = nil) async throws -> RepositoryPreview {
    let normalized = try RepositorySource(address: source.address)
    guard normalized.isGit == source.isGit else { throw Failure.invalidSource }
    let source = normalized
    let fm = FileManager.default
    try fm.createDirectory(at: previewRoot, withIntermediateDirectories: true)
    let id = UUID()
    let folder = previewRoot.appending(path: id.uuidString)
    do {
      var selectedRef = ref
      var commit: String?
      switch source {
      case .git(let address):
        let transport = transportAddress(source: source, token: token)
        var cloneArguments = ["clone", "--no-checkout"]
        switch ref {
        case .defaultBranch:
          cloneArguments += ["--depth=1"]
        case .branch(let name):
          try validateRef(name)
          cloneArguments += ["--depth=1", "--branch", name]
        case .tag, .commit:
          break
        }
        _ = try await RepositoryGit.run(cloneArguments + ["--", transport, folder.path])
        _ = try await RepositoryGit.run(["-C", folder.path, "remote", "set-url", "origin", cleanAddress(address)])
        let target: String
        switch ref {
        case .defaultBranch:
          target = "refs/remotes/origin/HEAD"
          let branch = try await RepositoryGit.run(["-C", folder.path, "symbolic-ref", "refs/remotes/origin/HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
          selectedRef = .branch(String(branch.dropFirst("refs/remotes/origin/".count)))
        case .branch(let name): try validateRef(name); target = "refs/remotes/origin/" + name
        case .tag(let name, let pin):
          try validateRef(name)
          if let pin, !isCommit(pin) { throw Failure.missingRef(ref.label) }
          target = pin ?? "refs/tags/" + name
        case .commit(let value):
          guard value.count >= 7, value.count <= 64, value.allSatisfy({ $0.isHexDigit }) else { throw Failure.missingRef(value) }
          target = value
        }
        do { commit = try await RepositoryGit.run(["-C", folder.path, "rev-parse", "--verify", target + "^{commit}"]).trimmingCharacters(in: .whitespacesAndNewlines) }
        catch { throw Failure.missingRef(ref.label) }
        guard let resolved = commit, isCommit(resolved) else { throw Failure.missingRef(ref.label) }
        _ = try await RepositoryGit.run(["-C", folder.path, "checkout", "--detach", resolved])
        if case .tag(let name, _) = ref { selectedRef = .tag(name: name, commit: resolved) }
        if case .commit = ref { selectedRef = .commit(resolved) }
      case .local(let path):
        guard !ref.isPinned, ref == .defaultBranch else { throw Failure.missingRef(ref.label) }
        let sourceFolder = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard (try? sourceFolder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { throw SkillInstaller.InstallFailure.notFound }
        try fm.copyItem(at: sourceFolder, to: folder)
      }
      try Task.checkCancellation()
      return RepositoryPreview(id: id, repositoryID: RepositoryID(source: source), source: source, ref: selectedRef, commit: commit, folder: folder, fingerprints: SkillReview.fingerprints(folder), skills: skills(in: folder), review: SkillReview.inspect(folder), contentSeal: try RepositoryMerge.seal(folder))
    } catch { try? fm.removeItem(at: folder); throw error }
  }

  static func discard(_ preview: RepositoryPreview) {
    guard preview.folder.deletingLastPathComponent().standardizedFileURL == previewRoot.standardizedFileURL, preview.folder.lastPathComponent == preview.id.uuidString else { return }
    try? FileManager.default.removeItem(at: preview.folder)
  }

  static func cleanupExpiredPreviews(now: Date = Date(), maxAge: TimeInterval = 24 * 60 * 60) {
    let fm = FileManager.default
    let entries = (try? fm.contentsOfDirectory(at: previewRoot, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey])) ?? []
    for folder in entries {
      guard UUID(uuidString: folder.lastPathComponent) != nil,
            let values = try? folder.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]),
            values.isDirectory == true, values.isSymbolicLink != true,
            let modified = values.contentModificationDate, now.timeIntervalSince(modified) > maxAge else { continue }
      try? fm.removeItem(at: folder)
    }
  }

  static func validateRef(_ value: String) throws {
    guard !value.isEmpty, !value.hasPrefix("-"), !value.contains(".."), !value.contains("@{"), !value.hasSuffix("/"), !value.hasSuffix(".lock"), !value.contains(where: { $0.isWhitespace || $0.isNewline || "~^:?*[\\".contains($0) }) else { throw Failure.missingRef(value) }
  }

  static func transportAddress(source: RepositorySource, token: String?) -> String {
    guard let token, !token.isEmpty, var url = URLComponents(string: source.address),
          ["http", "https"].contains(url.scheme ?? "") else { return source.address }
    url.user = "x-access-token"
    url.password = token
    return url.string ?? source.address
  }

  private static func remoteRefs(source: RepositorySource, token: String? = nil) async throws -> [(String, String)] {
    guard source.isGit else { throw Failure.invalidSource }
    let output = try await RepositoryGit.run(["ls-remote", "--symref", "--", transportAddress(source: source, token: token)])
    return output.components(separatedBy: .newlines).compactMap { line in
      let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
      guard fields.count == 2 else { return nil }; return (fields[0], fields[1])
    }
  }

  static func refs(source: RepositorySource, token: String? = nil) async throws -> [RepositoryRef] {
    let values = try await remoteRefs(source: source, token: token)
    let branches = values.filter { $0.1.hasPrefix("refs/heads/") }.map { RepositoryRef.branch(String($0.1.dropFirst(11))) }
    let tags = values.filter { $0.1.hasPrefix("refs/tags/") && !$0.1.hasSuffix("^{}") }.map { entry in
      let resolved = values.first { $0.1 == entry.1 + "^{}" }?.0 ?? entry.0
      return RepositoryRef.tag(name: String(entry.1.dropFirst(10)), commit: resolved)
    }
    return (branches + tags).sorted { $0.label < $1.label }
  }

  static func check(entry: RepositoryEntry, token: String? = nil) async throws -> RepositoryCheck {
    guard entry.issue == nil, let folder = entry.installedFolder else { throw Failure.metadata(entry.issue ?? "Repository is not in Library.") }
    let snapshot = try snapshot(in: folder)
    var installed = snapshot?.commit
    if installed == nil, entry.source.isGit { installed = try await fullCommit(in: folder) }
    let ref = snapshot?.ref ?? legacySnapshot(in: folder, source: entry.source)?.ref ?? .defaultBranch
    guard entry.source.isGit else { throw Failure.invalidSource }
    if case .commit = ref {
      return RepositoryCheck(status: .pinned, installedCommit: installed, latestCommit: installed, checkedAt: Date())
    }
    let values = try await remoteRefs(source: snapshot?.source ?? entry.source, token: token)
    let latest: String
    let status: RepositoryCheck.Status
    switch ref {
    case .commit: latest = installed ?? ""; status = .pinned
    case .tag(let name, _):
      guard let tag = values.first(where: { $0.1 == "refs/tags/" + name + "^{}" }) ?? values.first(where: { $0.1 == "refs/tags/" + name }) else { throw Failure.missingRef(ref.label) }
      latest = tag.0; status = latest == installed ? .pinned : .tagMoved
    case .branch(let name):
      guard let branch = values.first(where: { $0.1 == "refs/heads/" + name }) else { throw Failure.missingRef(ref.label) }
      latest = branch.0; status = latest == installed ? .upToDate : .updateAvailable
    case .defaultBranch:
      guard let head = values.first(where: { $0.1 == "HEAD" && isCommit($0.0) }) else { throw Failure.missingRef(ref.label) }
      latest = head.0; status = latest == installed ? .upToDate : .updateAvailable
    }
    return RepositoryCheck(status: status, installedCommit: installed, latestCommit: latest, checkedAt: Date())
  }
}

enum RepositoryGit {
  private final class Run: @unchecked Sendable {
    let lock = NSLock()
    var process: Process?
    var cancelled = false
    var timedOut = false
    var outputOverflow = false
    var output = Data()
    var errors = Data()
    func cancel(timeout: Bool = false) {
      lock.lock(); cancelled = true; timedOut = timedOut || timeout; let running = process; lock.unlock()
      if let running, running.isRunning {
        // Foundation starts children in their own process group on macOS. Kill the group only
        // after checking that it belongs to this child, so SSH cannot keep its pipes open.
        let pid = running.processIdentifier
        if getpgid(pid) == pid { _ = kill(-pid, SIGKILL) }
        else { running.terminate() }
      }
    }
    func drain(_ handle: FileHandle, errors: Bool) {
      while true {
        let data = handle.availableData
        if data.isEmpty { break }
        lock.lock()
        if errors { self.errors.append(data.prefix(max(0, 256 * 1024 - self.errors.count))) }
        else {
          let remaining = max(0, 2 * 1024 * 1024 - output.count)
          outputOverflow = outputOverflow || data.count > remaining
          output.append(data.prefix(remaining))
        }
        lock.unlock()
      }
    }
    func executeData(_ arguments: [String], timeout: TimeInterval, acceptedExitCodes: Set<Int32> = [0]) throws -> Data {
      let task = Process()
      task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      task.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments
      var environment = ProcessInfo.processInfo.environment
      environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_ASKPASS"] = "/usr/bin/false"
      environment["SSH_ASKPASS"] = "/usr/bin/false"; environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15"
      environment["GIT_CONFIG_NOSYSTEM"] = "1"
      task.environment = environment
      task.standardInput = FileHandle.nullDevice
      let out = Pipe(), err = Pipe(); task.standardOutput = out; task.standardError = err
      lock.lock()
      if cancelled { lock.unlock(); throw CancellationError() }
      process = task
      do { try task.run() } catch { lock.unlock(); throw error }
      lock.unlock()
      let group = DispatchGroup()
      group.enter(); DispatchQueue.global().async { self.drain(out.fileHandleForReading, errors: false); group.leave() }
      group.enter(); DispatchQueue.global().async { self.drain(err.fileHandleForReading, errors: true); group.leave() }
      let timer = DispatchSource.makeTimerSource(queue: .global())
      timer.schedule(deadline: .now() + timeout); timer.setEventHandler { self.cancel(timeout: true) }; timer.resume()
      task.waitUntilExit(); timer.cancel(); group.wait()
      lock.lock(); let wasCancelled = cancelled, expired = timedOut, overflow = outputOverflow, result = output, failure = errors; process = nil; lock.unlock()
      if expired { throw RepositoryLibrary.Failure.timeout }
      if wasCancelled { throw CancellationError() }
      if overflow { throw RepositoryLibrary.Failure.git("Git returned more repository references than can be displayed.") }
      guard acceptedExitCodes.contains(task.terminationStatus) else {
        let message = String(data: failure, encoding: .utf8) ?? ""
        let lower = message.lowercased()
        if lower.contains("authentication") || lower.contains("username") || lower.contains("permission denied") { throw SkillInstaller.InstallFailure.authRequired }
        // Git can repeat the credential-bearing transport URL; keep diagnostics credential-free.
        throw RepositoryLibrary.Failure.git("Git could not fetch or resolve the repository. Check its address, access, and selected version.")
      }
      return result
    }
    func execute(_ arguments: [String], timeout: TimeInterval, acceptedExitCodes: Set<Int32> = [0]) throws -> String {
      String(decoding: try executeData(arguments, timeout: timeout, acceptedExitCodes: acceptedExitCodes), as: UTF8.self)
    }
  }
  static func dataSynchronously(_ arguments: [String], timeout: TimeInterval = 60) throws -> Data {
    try Run().executeData(arguments, timeout: timeout)
  }
  static func runSynchronously(_ arguments: [String], timeout: TimeInterval = 60, acceptedExitCodes: Set<Int32> = [0]) throws -> String {
    try Run().execute(arguments, timeout: timeout, acceptedExitCodes: acceptedExitCodes)
  }
  static func run(_ arguments: [String], timeout: TimeInterval = 60) async throws -> String {
    let run = Run()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await Task.detached { try run.execute(arguments, timeout: timeout) }.value
    } onCancel: { run.cancel() }
  }
}
