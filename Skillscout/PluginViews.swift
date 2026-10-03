import SwiftUI

struct PluginList: View {
  let plugins: [InstalledPlugin]
  @Binding var selection: InstalledPlugin.ID?

  var body: some View {
    List(selection: $selection) {
      ForEach(plugins) { plugin in
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text(plugin.name).font(.headline).lineLimit(1)
            if plugin.enabled == false {
              Text("Off").font(.caption).foregroundStyle(.secondary)
            }
          }
          if !plugin.description.isEmpty {
            Text(plugin.description).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
          }
          HStack(spacing: 6) {
            ToolBadge(tool: plugin.tool)
            Text(summary(plugin)).font(.caption).foregroundStyle(plugin.runs.isEmpty ? .tertiary : .secondary)
          }
        }
        .padding(.vertical, 4)
        .tag(plugin.id)
      }
    }
    .navigationTitle("Plugins")
    .overlay {
      if plugins.isEmpty {
        ContentUnavailableView("No plugins", systemImage: "puzzlepiece.extension",
          description: Text("Plugins you install in Claude Code, Codex or Cursor show up here."))
      }
    }
  }

  private func summary(_ plugin: InstalledPlugin) -> String {
    var parts: [String] = []
    if !plugin.skills.isEmpty { parts.append(plugin.skills.count == 1 ? "1 skill" : "\(plugin.skills.count) skills") }
    if !plugin.runs.isEmpty { parts.append(plugin.runs.count == 1 ? "runs 1 thing" : "runs \(plugin.runs.count) things") }
    return parts.isEmpty ? "Nothing to run" : parts.joined(separator: " · ")
  }
}

struct PluginDetail: View {
  let plugin: InstalledPlugin

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        VStack(alignment: .leading, spacing: 6) {
          Text(plugin.name).font(.largeTitle.bold())
          if !plugin.description.isEmpty {
            Text(plugin.description).font(.title3).foregroundStyle(.secondary)
          }
        }
        .textSelection(.enabled)

        DetailSection("Installed in") {
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
              ToolBadge(tool: plugin.tool)
              Text(status).foregroundStyle(.secondary)
            }
            if let marketplace = plugin.marketplace {
              Text("From \(marketplace)\(plugin.version.map { ", version \($0)" } ?? "")").foregroundStyle(.secondary)
            }
            HStack {
              Text(Paths.abbreviate(plugin.folder)).font(.callout.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
              Button("Show in Finder") { Finder.reveal(plugin.folder) }
                .buttonStyle(.link)
            }
          }
        }

        DetailSection("What it runs") {
          if plugin.runs.isEmpty {
            Text("Skillscout found no hooks, servers, monitors or executables.").foregroundStyle(.secondary)
          } else {
            VStack(alignment: .leading, spacing: 10) {
              ForEach(PluginRunItem.Kind.allCases, id: \.self) { kind in
                let items = plugin.runs.filter { $0.kind == kind }
                if !items.isEmpty {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(items.count == 1 ? kind.rawValue : "\(kind.rawValue)s").font(.subheadline.weight(.semibold))
                    ForEach(items, id: \.self) { item in
                      VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.callout)
                        Text(item.detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                          .lineLimit(3).textSelection(.enabled)
                      }
                    }
                  }
                }
              }
              Text("\(plugin.tool.name) runs these on your Mac while the plugin is on, without asking each time.")
                .font(.callout).foregroundStyle(.secondary)
            }
          }
        }

        DetailSection("Skills") {
          if plugin.skills.isEmpty {
            Text("No skills.").foregroundStyle(.secondary)
          } else {
            Text(plugin.skills.formatted(.list(type: .and))).textSelection(.enabled)
          }
        }

        Text("Skillscout only reads plugins. Install, update or turn them off in \(plugin.tool.name).")
          .font(.callout).foregroundStyle(.secondary)
      }
      .padding(28)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var status: String {
    switch plugin.enabled {
    case true?: "On"
    case false?: "Off"
    case nil: "Installed"
    }
  }
}
