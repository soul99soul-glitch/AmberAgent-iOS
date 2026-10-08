import SwiftUI

struct DeepReadDiscoverySettingsView: View {
    @Bindable private var preferences = DeepReadDiscoveryPreferences.shared

    var body: some View {
        Form {
            Group {
                Section("刷新") {
                    Picker("刷新间隔", selection: $preferences.configuration.refreshMinutes) {
                        ForEach([15, 30, 60, 120], id: \.self) { Text("\($0) 分钟").tag($0) }
                    }
                    Toggle("仅在 Wi-Fi 下刷新", isOn: $preferences.configuration.wifiOnly)
                    Toggle("将英文标题译为中文", isOn: $preferences.configuration.translateToChinese)
                }
                Section("关注") {
                    TextField("关键词，用逗号分隔", text: $preferences.configuration.keywords)
                    Picker("展示方式", selection: $preferences.configuration.filterMode) {
                        Text("全部热点").tag("all")
                        Text("关注优先").tag("focus_first")
                        Text("只看关注").tag("focus_only")
                    }
                }
                ForEach(IOSHotlistProviders.categoryOrder, id: \.self) { category in
                    Section(category) {
                        ForEach(IOSHotlistProviders.descriptors.filter { IOSHotlistProviders.category(for: $0.id) == category }) { source in
                            Toggle(source.displayName, isOn: Binding(
                                get: { preferences.configuration.enabledSources.contains(source.id) },
                                set: { enabled in
                                    if enabled { preferences.configuration.enabledSources.insert(source.id) }
                                    else { preferences.configuration.enabledSources.remove(source.id) }
                                }
                            ))
                        }
                    }
                }
            }
            .listRowBackground(DeepReadPalette.card)
        }
        .scrollContentBackground(.hidden)
        .background { DeepReadPaperBackground() }
        .navigationTitle("热点来源")
    }
}
