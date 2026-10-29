import AppKit

/// Links the command bundled in the app as quartermaster and qm, and as skillscout-mod for scripts written
/// before the rename, into the first folder that works without a password, or /usr/local/bin.
enum CommandLineTool {
  static let names = ["quartermaster", "qm", "skillscout-mod"]
  static let system = "/usr/local/bin"
  /// The user's own folder first, then Homebrew's on Apple silicon, then the system's.
  static let folders = [Paths.at(".local/bin").path, "/opt/homebrew/bin", system]
  static let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/quartermaster")

  /// A path the installer may write: missing, or a link to the command in a copy of this app, old or new.
  /// Anything else, like another program's qm, stays as it is.
  static func isOurs(_ link: URL) -> Bool {
    let fm = FileManager.default
    guard (try? fm.attributesOfItem(atPath: link.path)) != nil else { return true }
    guard let target = try? fm.destinationOfSymbolicLink(atPath: link.path) else { return false }
    return [".app/Contents/Helpers/quartermaster", ".app/Contents/Helpers/skillscout-mod"].contains { target.hasSuffix($0) }
  }

  /// The first folder that is on the login shell's PATH, writable without a password and free of another
  /// program's quartermaster, or /usr/local/bin.
  static func folder(path: [String]) -> String {
    folders.first { folder in
      path.contains(folder) && FileManager.default.isWritableFile(atPath: folder)
        && isOurs(URL(fileURLWithPath: folder).appending(path: names[0]))
    } ?? system
  }

  @MainActor
  static func install() async {
    let fm = FileManager.default
    let path = await ShellEnvironment.shared.loginShellPath()?.split(separator: ":").map(String.init) ?? []
    let folder = folder(path: path)
    let links = names.map { URL(fileURLWithPath: folder).appending(path: $0) }
    let skipped = links.filter { !isOurs($0) }
    let pending = links.filter { isOurs($0) && (try? fm.destinationOfSymbolicLink(atPath: $0.path)) != bundled.path }
    let note = skipped.isEmpty ? "" : " Left \(skipped.map(\.path).formatted(.list(type: .and))) alone, since another program uses that name."
    guard !skipped.contains(links[0]) else {
      show("Couldn't install the command.", detail: "\(links[0].path) belongs to another program.")
      return
    }
    if pending.isEmpty {
      show("The quartermaster command is already installed.", detail: "Run quartermaster help, or qm help, in your terminal to see what it does." + note)
      return
    }

    do {
      for link in pending {
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: bundled)
      }
    } catch {
      // One administrator prompt for every link still to make.
      let command = (["mkdir -p '\(folder)'"] + pending.map { "ln -sfn '\(bundled.path)' '\($0.path)'" }).joined(separator: " && ")
      var failure: NSDictionary?
      NSAppleScript(source: "do shell script \"\(command)\" with administrator privileges")?.executeAndReturnError(&failure)
      if let failure {
        if failure[NSAppleScript.errorNumber] as? Int == -128 { return }
        show("Couldn't install the command.", detail: failure[NSAppleScript.errorMessage] as? String ?? "")
        return
      }
    }
    show("Installed the quartermaster command in \(Paths.abbreviate(URL(fileURLWithPath: folder))).", detail: "Open a new terminal window and run quartermaster help, or qm help, to get started." + note)
  }

  @MainActor
  private static func show(_ message: String, detail: String) {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = detail
    alert.runModal()
  }
}
