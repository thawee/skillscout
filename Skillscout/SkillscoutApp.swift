import SwiftUI

@main
struct SkillscoutApp: App {
  @State private var store: AppStore

  init() {
    // Settings from before the rename to Quartermaster, then from the original Skillscout.
    let settings = UserDefaults.standard
    for (key, value) in settings.persistentDomain(forName: "com.thawee.skillscout") ?? [:] where settings.object(forKey: key) == nil {
      settings.set(value, forKey: key)
    }
    let oldSettings = UserDefaults(suiteName: "com.flaviocopes.skillscout")
    for key in ["tools", "skillSort", "skillSource", "engine", "codexModel", "claudeModel", "lookbackDays", "autoAnalyze", "autoThreshold"] {
      if settings.object(forKey: key) == nil, let value = oldSettings?.object(forKey: key) {
        settings.set(value, forKey: key)
      }
    }
    // Before anything reads the Library, so its paths are the new ones.
    SkillInstaller.moveConfigFolder()
    _store = State(initialValue: AppStore())
    AppUpdater.shared.start(repository: "thawee/skillscout")
  }

  var body: some Scene {
    Window("Quartermaster", id: "main") {
      ContentView()
        .environment(store)
        .task { await store.start() }
    }
    .defaultSize(width: 1180, height: 760)
    .commands {
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") {
          AppUpdater.shared.checkForUpdates()
        }
      }
      CommandGroup(after: .appSettings) {
        Button("Install Command Line Tool…") { Task { await CommandLineTool.install() } }
      }
      CommandGroup(after: .textEditing) {
        Button("Find…") { store.searchRequests += 1 }
          .keyboardShortcut("f")
      }
    }

    Settings {
      SettingsView()
        .environment(store)
    }
  }
}
