import SwiftUI

struct SkillListFilters: View {
  @Environment(AppStore.self) private var store
  let context: SkillListContext
  let showsSource: Bool
  let sourceOptions: [ChoiceOption<SkillSource>]
  @Binding var source: SkillSource
  @Binding var sort: SkillSort

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if showsSource {
        ChoiceChips(title: "Show", options: sourceOptions, selection: $source)
      }
      WrapLayout(spacing: 12) {
        Picker("Sort", selection: $sort) {
          Text("Newest").tag(SkillSort.newest)
          Text("Name").tag(SkillSort.name)
          Text("Use").tag(SkillSort.use)
        }.pickerStyle(.menu).fixedSize()
        if !context.usesAllLoadedHistory { UsagePeriodPicker() }
      }
      if !context.usesAllLoadedHistory { UsageProjectChoice() }
      Text("Recorded use in \(context.usesAllLoadedHistory ? UsageScope().description(loadedDays: store.loadedLookbackDays) : store.usageScopeDescription)")
        .font(.caption2).foregroundStyle(.secondary)
    }.padding(.horizontal, 10).padding(.vertical, 8)
  }
}
