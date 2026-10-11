import Foundation
import CryptoKit

enum RepoFileResolution: Hashable, Sendable {
  case keepMine
  case useIncoming
  case merge(String)
}

enum RepoFileStatus: String, Sendable {
  case unchanged, incoming, local, merged, conflict
}

struct RepoUpdateFile: Identifiable, Sendable {
  let path: String
  let status: RepoFileStatus
  let reason: String?
  let baseText: String?
  let localText: String?
  let incomingText: String?
  let suggestedMerge: String?
  let localExists: Bool
  let incomingExists: Bool
  let canMerge: Bool
  var id: String { path }
}

enum RepositoryMerge {
  static let archiveName = RepositoryLibrary.upstreamMarkerName
  static let maxTextSize = 512 * 1024
  static let reserved: Set<String> = [RepositoryLibrary.markerName, archiveName, ".skillscout-local-source"]

  struct Entry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case file, link, directory }
    let kind: Kind
    let data: Data
    let mode: Int
    var text: String? {
      guard kind == .file, data.count <= maxTextSize, !data.contains(0) else { return nil }
      return String(data: data, encoding: .utf8)
    }
    var fingerprint: String {
      let bytes = kind == .link ? Data("link:".utf8) + data : data
      return String(digest(bytes).prefix(24))
    }
  }
  struct Archive: Codable {
    let version: Int
    let files: [String: Entry]
  }
  struct Comparison: Sendable {
    let file: RepoUpdateFile
    let automatic: Entry?
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func validatePath(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }),
          !reserved.contains(String(components[0])), components[0] != ".git" else {
      throw RepositoryLibrary.Failure.metadata("Invalid upstream path.")
    }
  }

  static func validateTree(_ files: [String: Entry]) throws {
    var normalized: Set<String> = []
    var directories: [String: String] = [:]
    for (path, entry) in files {
      if path == ".", entry.kind == .directory {
        guard (0...0o777).contains(entry.mode) else { throw RepositoryLibrary.Failure.metadata("Invalid repository folder mode.") }
        continue
      }
      try validatePath(path)
      guard (0...0o777).contains(entry.mode),
            entry.kind != .link || String(data: entry.data, encoding: .utf8).map({ !$0.contains("\0") }) == true,
            normalized.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
        throw RepositoryLibrary.Failure.metadata("Invalid upstream file kind, mode or colliding path.")
      }
      var ancestor = (path as NSString).deletingLastPathComponent
      while !ancestor.isEmpty {
        let foldedAncestor = ancestor.precomposedStringWithCanonicalMapping.lowercased()
        guard directories[foldedAncestor] == nil || directories[foldedAncestor] == ancestor else {
          throw RepositoryLibrary.Failure.metadata("Parent folders differ only by case or Unicode spelling.")
        }
        directories[foldedAncestor] = ancestor
        guard files[ancestor] == nil || files[ancestor]?.kind == .directory else { throw RepositoryLibrary.Failure.metadata("A file or link is also a parent folder.") }
        ancestor = (ancestor as NSString).deletingLastPathComponent
      }
    }
    let byFoldedPath = Dictionary(uniqueKeysWithValues: files.keys.map { ($0.precomposedStringWithCanonicalMapping.lowercased(), $0) })
    for path in files.keys {
      var ancestor = (path as NSString).deletingLastPathComponent
      while !ancestor.isEmpty {
        if let matching = byFoldedPath[ancestor.precomposedStringWithCanonicalMapping.lowercased()],
           files[matching]?.kind != .directory {
          throw RepositoryLibrary.Failure.metadata("A file or link collides with a parent folder.")
        }
        ancestor = (ancestor as NSString).deletingLastPathComponent
      }
    }
  }

  static func validateAncestors(_ folder: URL) throws {
    let fm = FileManager.default
    var url = folder.standardizedFileURL
    while url.path != "/" {
      if let attributes = try? fm.attributesOfItem(atPath: url.path) {
        if ["/var", "/tmp"].contains(url.path),
           (try? fm.destinationOfSymbolicLink(atPath: url.path)) == "private" + url.path {
          url = URL(fileURLWithPath: "/private" + url.path)
          continue
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
          throw RepositoryLibrary.Failure.metadata("A repository folder or ancestor is a link or file.")
        }
      }
      url.deleteLastPathComponent()
    }
  }

  static func tree(_ folder: URL, includeMetadata: Bool = false, includeDirectories: Bool = true) throws -> [String: Entry] {
    try validateAncestors(folder)
    let fm = FileManager.default
    let rootAttributes = try fm.attributesOfItem(atPath: folder.path)
    guard rootAttributes[.type] as? FileAttributeType == .typeDirectory else { throw RepositoryLibrary.Failure.stalePreview }
    var files: [String: Entry] = [:]
    if includeDirectories { files["."] = Entry(kind: .directory, data: Data(), mode: (rootAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) }
    func visit(_ directory: URL, prefix: String) throws {
      for name in try fm.contentsOfDirectory(atPath: directory.path).sorted() {
      let path = prefix.isEmpty ? name : prefix + "/" + name
      if path == ".git" {
        guard (try fm.attributesOfItem(atPath: folder.appending(path: path).path))[.type] as? FileAttributeType == .typeDirectory else {
          throw RepositoryLibrary.Failure.metadata("Git metadata must be a directory inside the snapshot.")
        }
        continue
      }
      if !includeMetadata && reserved.contains(path) { continue }
      let url = folder.appending(path: path)
      let attributes = try fm.attributesOfItem(atPath: url.path)
      let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
      let entry: Entry
      switch attributes[.type] as? FileAttributeType {
      case .typeDirectory:
        try visit(url, prefix: path)
        guard includeDirectories else { continue }
        entry = Entry(kind: .directory, data: Data(), mode: mode)
      case .typeSymbolicLink:
        entry = Entry(kind: .link, data: Data(try fm.destinationOfSymbolicLink(atPath: url.path).utf8), mode: 0o777)
      case .typeRegular: entry = Entry(kind: .file, data: try Data(contentsOf: url), mode: mode)
      default: throw RepositoryLibrary.Failure.metadata("Unsupported repository file at \(path).")
      }
      files[path] = entry
      }
    }
    try visit(folder, prefix: "")
    if !includeMetadata { try validateTree(files) }
    return files
  }

  static func seal(_ folder: URL) throws -> String {
    let files = try tree(folder, includeMetadata: true, includeDirectories: true)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return digest(try encoder.encode(files))
  }

  static func writeArchive(in folder: URL) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(Archive(version: 1, files: tree(folder)))
    try data.write(to: folder.appending(path: archiveName), options: .atomic)
    return digest(data)
  }

  static func baseline(in folder: URL, snapshot: InstalledSnapshot?, commit: String?) throws -> [String: Entry]? {
    if let expected = snapshot?.upstreamArchiveDigest {
      let file = folder.appending(path: archiveName)
      guard (try? FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular,
            let data = try? Data(contentsOf: file), digest(data) == expected,
            let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1 else {
        throw RepositoryLibrary.Failure.metadata("The upstream archive is missing or damaged. Reimport a verified snapshot.")
      }
      try validateTree(archive.files)
      return archive.files
    }
    guard let commit, RepositoryLibrary.isCommit(commit) else { return nil }
    do {
      let output = try RepositoryGit.runSynchronously(["-C", folder.path, "ls-tree", "-rz", "--full-tree", commit])
      var result: [String: Entry] = [:]
      for record in output.split(separator: "\0") {
        let fields = record.split(separator: "\t", maxSplits: 1)
        guard fields.count == 2 else { return nil }
        let header = fields[0].split(separator: " ")
        guard header.count == 3, header[1] == "blob", RepositoryLibrary.isCommit(String(header[2])) else { return nil }
        let path = String(fields[1]); try validatePath(path)
        let mode = String(header[0]); guard ["100644", "100755", "120000"].contains(mode) else { return nil }
        let bytes = try RepositoryGit.dataSynchronously(["-C", folder.path, "cat-file", "blob", String(header[2])])
        result[path] = Entry(kind: mode == "120000" ? .link : .file, data: bytes, mode: mode == "100755" ? 0o755 : mode == "120000" ? 0o777 : 0o644)
      }
      try validateTree(result)
      if let fingerprints = snapshot?.baselineFingerprints, !fingerprints.isEmpty {
        guard fingerprints.allSatisfy({ result[$0.key]?.fingerprint == $0.value }) else { return nil }
      }
      return result
    } catch { return nil }
  }

  static func structuralConflicts(_ comparisons: [String: Comparison], nonDirectories: Set<String>) -> [String: Comparison] {
    let paths = comparisons.filter { $0.value.automatic != nil }.keys.sorted()
    var conflicts: Set<String> = []
    var normalized: [String: String] = [:]
    for path in paths {
      let folded = path.precomposedStringWithCanonicalMapping.lowercased()
      if let previous = normalized[folded] { conflicts.insert(path); conflicts.insert(previous) }
      normalized[folded] = path
    }
    for path in comparisons.keys where nonDirectories.contains(path) && comparisons[path]?.file.status == .conflict {
      normalized[path.precomposedStringWithCanonicalMapping.lowercased()] = path
    }
    for path in paths {
      var ancestor = (path.precomposedStringWithCanonicalMapping.lowercased() as NSString).deletingLastPathComponent
      while !ancestor.isEmpty {
        if let parent = normalized[ancestor], comparisons[parent]?.automatic?.kind != .directory { conflicts.insert(path); conflicts.insert(parent) }
        ancestor = (ancestor as NSString).deletingLastPathComponent
      }
    }
    var result = comparisons
    for path in conflicts {
      let file = comparisons[path]!.file
      result[path] = Comparison(file: RepoUpdateFile(path: path, status: .conflict,
        reason: "The combined result has a file, link or folder path collision.", baseText: file.baseText,
        localText: file.localText, incomingText: file.incomingText, suggestedMerge: file.suggestedMerge,
        localExists: file.localExists, incomingExists: file.incomingExists, canMerge: false), automatic: nil)
    }
    return result
  }

  static func hasMarkers(_ text: String) -> Bool {
    text.components(separatedBy: .newlines).contains { line in
      line.hasPrefix("<<<<<<<") || line.hasPrefix("|||||||") || line == "=======" || line.hasPrefix(">>>>>>>")
    }
  }

  static func merge(base: String, local: String, incoming: String) throws -> String {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appending(path: "skillscout-merge-" + UUID().uuidString)
    try fm.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: folder) }
    for (name, text) in [("base", base), ("local", local), ("incoming", incoming)] {
      try Data(text.utf8).write(to: folder.appending(path: name))
    }
    return try RepositoryGit.runSynchronously(["merge-file", "-p", "-L", "Mine", "-L", "Base", "-L", "Incoming", folder.appending(path: "local").path, folder.appending(path: "base").path, folder.appending(path: "incoming").path], acceptedExitCodes: Set(0...127))
  }

  static func compare(path: String, base: Entry?, baseKnown: Bool, legacyHash: String?, local: Entry?, incoming: Entry?, directoryBaseKnown: Bool = true) throws -> Comparison {
    let canMerge = local?.text != nil && incoming?.text != nil && local?.mode == incoming?.mode
    var status: RepoFileStatus
    var reason: String?
    var selected: Entry?
    var suggestion: String?
    if local == incoming { status = .unchanged; selected = local }
    else if !directoryBaseKnown, local?.kind == .directory, incoming == nil || incoming?.kind == .directory {
      status = .local; selected = local
    } else if !directoryBaseKnown, local == nil, incoming?.kind == .directory {
      status = .incoming; selected = incoming
    }
    else if baseKnown && local == base { status = .incoming; selected = incoming }
    else if baseKnown && incoming == base { status = .local; selected = local }
    else if !baseKnown, let legacyHash, local?.fingerprint == legacyHash, local?.kind == incoming?.kind, local?.mode == incoming?.mode {
      status = .incoming; selected = incoming
    } else if !baseKnown, let legacyHash, incoming?.fingerprint == legacyHash, local?.kind == incoming?.kind, local?.mode == incoming?.mode {
      status = .local; selected = local
    } else if baseKnown, canMerge, let baseText = base?.text, base?.mode == local?.mode {
      let text = try merge(base: baseText, local: local!.text!, incoming: incoming!.text!)
      suggestion = text
      if hasMarkers(text) { status = .conflict; reason = "Mine and incoming edit overlapping or adjacent lines." }
      else { status = .merged; selected = Entry(kind: .file, data: Data(text.utf8), mode: local!.mode) }
    } else {
      status = .conflict
      if !baseKnown { reason = "The previous upstream contents are unavailable." }
      else if local == nil || incoming == nil { reason = "One version deleted a file that the other changed." }
      else if local?.mode != incoming?.mode { reason = "The file permissions changed differently." }
      else { reason = "Both versions changed a binary, link or non-mergeable file." }
    }
    let versions = [("Base", base), ("Mine", local), ("Incoming", incoming)]
    if Set(versions.compactMap { $0.1?.mode }).count > 1 {
      let permissions = versions.map { label, entry in
        "\(label): \(entry.map { String(format: "%04o", $0.mode) } ?? "absent")"
      }.joined(separator: "; ")
      reason = [reason, "Permissions: \(permissions)."].compactMap { $0 }.joined(separator: " ")
    }
    return Comparison(file: RepoUpdateFile(path: path, status: status, reason: reason, baseText: base?.text, localText: local?.text,
      incomingText: incoming?.text, suggestedMerge: suggestion, localExists: local != nil, incomingExists: incoming != nil, canMerge: canMerge), automatic: selected)
  }

  static func materialize(_ files: [String: Entry], in folder: URL) throws {
    try validateTree(files)
    try validateAncestors(folder)
    let fm = FileManager.default
    for (path, entry) in files.sorted(by: { $0.key < $1.key }) {
      if entry.kind == .directory {
        if path != "." { try fm.createDirectory(at: folder.appending(path: path), withIntermediateDirectories: true) }
        continue
      }
      let url = folder.appending(path: path)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try validateAncestors(url.deletingLastPathComponent())
      switch entry.kind {
      case .file:
        try entry.data.write(to: url)
        try fm.setAttributes([.posixPermissions: entry.mode], ofItemAtPath: url.path)
      case .link: try fm.createSymbolicLink(atPath: url.path, withDestinationPath: String(decoding: entry.data, as: UTF8.self))
      case .directory: throw RepositoryLibrary.Failure.metadata("Unexpected directory entry.")
      }
    }
    for (path, entry) in files.filter({ $0.value.kind == .directory }).sorted(by: { $0.key.count > $1.key.count }) {
      let url = path == "." ? folder : folder.appending(path: path)
      try fm.setAttributes([.posixPermissions: entry.mode], ofItemAtPath: url.path)
    }
  }
}
