import SwiftUI

@main
struct AmberAgentApp: App {
    @State private var settingsStore = SettingsStore()

    init() {
        IOSAppLanguagePreference.normalize()
    }

    var body: some Scene {
        WindowGroup {
            Group {
#if CHAT_PERF_REPLAY
                ChatPerfReplayView()
#else
                AppShell(settingsStore: settingsStore)
#endif
            }
        }
    }
}
