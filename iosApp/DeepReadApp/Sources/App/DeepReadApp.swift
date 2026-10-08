import SwiftUI

@main
struct DeepReadApp: App {
    @State private var settings: DeepReadSettingsStore
    @State private var runtime: DeepReadRuntime
    @State private var tab = 0
    @State private var tabDirection: CGFloat = 0

    init() {
        let settings = DeepReadSettingsStore()
        _settings = State(initialValue: settings)
        _runtime = State(initialValue: DeepReadRuntime(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            // The direction is set in the same update as the selection, so the arriving tab reads it.
            TabView(selection: Binding(get: { tab }, set: { new in
                if new != tab { tabDirection = new > tab ? 1 : -1 }
                tab = new
            })) {
                Tab("发现", systemImage: "newspaper", value: 0) {
                    NavigationStack {
                        DeepReadDiscoveryView(settings: settings, runtime: runtime)
                    }
                    .environment(\.deepReadTabActive, tab == 0)
                }
                Tab("阅读库", systemImage: "books.vertical", value: 1) {
                    NavigationStack {
                        DeepReadLibraryView(settings: settings, runtime: runtime)
                    }
                    .environment(\.deepReadTabActive, tab == 1)
                }
                Tab("设置", systemImage: "gearshape", value: 2) {
                    NavigationStack {
                        DeepReadSettingsView(store: settings)
                    }
                    .environment(\.deepReadTabActive, tab == 2)
                }
            }
            .environment(\.deepReadTabDirection, tabDirection)
            .tint(DeepReadPalette.accent)
            .tabBarMinimizeBehavior(.onScrollDown)
            .sensoryFeedback(.selection, trigger: tab)
            .task { runtime.recoverInterruptedRuns() }
        }
    }
}
