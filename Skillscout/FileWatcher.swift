import CoreServices
import Foundation

final class FileWatcher: @unchecked Sendable {
  private let handler: @Sendable ([String]) -> Void
  private let queue = DispatchQueue(label: "com.thawee.quartermaster.watcher")
  private var stream: FSEventStreamRef?

  /// Watching an existing ancestor also catches agent folders created after launch.
  static func watchPaths(for paths: [String]) -> [String] {
    let ancestors = paths.map { path -> String in
      var folder = URL(fileURLWithPath: path).standardizedFileURL
      var isDirectory: ObjCBool = false
      while !FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
        let parent = folder.deletingLastPathComponent()
        guard parent.path != folder.path else { break }
        folder = parent
      }
      return folder.standardizedFileURL.path
    }
    let candidates = Set(ancestors).sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
    return candidates.reduce(into: []) { roots, path in
      if !roots.contains(where: { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) {
        roots.append(path)
      }
    }
  }

  init(paths: [String], latency: TimeInterval = 2, handler: @escaping @Sendable ([String]) -> Void) {
    self.handler = handler

    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
      let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
      watcher.handler(changed)
    }
    let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)

    guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
      return
    }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, queue)
    FSEventStreamStart(stream)
  }

  deinit {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }
}
