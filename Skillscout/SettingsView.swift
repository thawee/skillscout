import SwiftUI

struct SettingsView: View {
  @Environment(AppStore.self) private var store
  @AppStorage("engine") private var engine = AIEngineKind.codex.rawValue
  @AppStorage("codexModel") private var codexModel = AIEngineKind.codex.defaultModel
  @AppStorage("claudeModel") private var claudeModel = AIEngineKind.claude.defaultModel
  @AppStorage("lookbackDays") private var lookbackDays = 60
  @AppStorage("autoAnalyze") private var autoAnalyze = true
  @AppStorage("autoThreshold") private var autoThreshold = 40
  @State private var repairMessage: String?

  var body: some View {
    Form {
      Section {
        ForEach(Tool.allCases) { tool in
          Toggle(isOn: Binding(get: { store.tools.contains(tool) }, set: { store.setTool(tool, enabled: $0) })) {
            Label {
              Text(tool.name)
              if !tool.isInstalled {
                Text("Not found on this Mac")
              }
            } icon: {
              Image(systemName: tool.symbol).foregroundStyle(tool.color).frame(width: 18)
            }
          }
        }
      } header: {
        Text("Tools")
      } footer: {
        Text("Skillscout shows the skills these tools load, and reads their chats for usage and repeated tasks.")
      }

      Section {
        ChoiceChips(title: "Engine", options: AIEngineKind.allCases.map {
          ChoiceOption(value: $0.rawValue, title: $0.name)
        }, selection: $engine)
        if engine == AIEngineKind.claude.rawValue {
          TextField("Model", text: $claudeModel)
        } else {
          TextField("Model", text: $codexModel)
        }
      } header: {
        Text("AI")
      } footer: {
        Text("Skillscout runs the CLI you're already logged in to. These runs aren't saved to your chat history.")
      }

      Section {
        ChoiceChips(title: "Read messages from the last", options: [30, 60, 90, 180].map {
          ChoiceOption(value: $0, title: "\($0) days")
        }, selection: $lookbackDays)
        Toggle("Analyze automatically", isOn: $autoAnalyze)
        Stepper("After \(autoThreshold) new messages", value: $autoThreshold, in: 10...500, step: 10)
          .disabled(!autoAnalyze)
      } header: {
        Text("Analysis")
      } footer: {
        Text("Automatic analysis starts after your first manual one, and runs at most every 30 minutes.")
      }

      Section {
        Button("Repair Library") {
          Task {
            repairMessage = await store.repairLibrary().message
          }
        }
        if let repairMessage {
          Text(repairMessage)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
      } header: {
        Text("Maintenance")
      } footer: {
        Text("Fixes folder names for older downloaded repositories and moves links to missing Library skills to Trash. Other broken links stay.")
      }
    }
    .formStyle(.grouped)
    .frame(width: 480)
    .onChange(of: lookbackDays) {
      Task { await store.refreshPrompts() }
    }
  }
}
