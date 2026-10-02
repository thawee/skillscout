import SwiftUI

@main
struct SkillscoutApp: App {
  @State private var store = AppStore()

  init() {
    let oldSettings = UserDefaults(suiteName: "com.flaviocopes.skillscout")
    for key in ["tools", "skillSort", "skillSource", "engine", "codexModel", "claudeModel", "lookbackDays", "autoAnalyze", "autoThreshold"] {
      if UserDefaults.standard.object(forKey: key) == nil, let value = oldSettings?.object(forKey: key) {
        UserDefaults.standard.set(value, forKey: key)
      }
    }
    AppUpdater.shared.start(repository: "thawee/skillscout")
  }

  var body: some Scene {
    Window("Skillscout Mod", id: "main") {
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
        Button("Install Command Line Tool…") { CommandLineTool.install() }
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
