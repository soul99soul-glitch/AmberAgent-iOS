import SwiftUI

@main
struct AmberAgentApp: App {
    @State private var settingsStore = SettingsStore()
    @AppStorage(IOSAppLanguagePreference.defaultsKey)
    private var appLanguage = IOSAppLanguage.system.rawValue

    init() {
        IOSAppLanguagePreference.normalize()
    }

    private var selectedLanguage: IOSAppLanguage {
        IOSAppLanguage(storedValue: appLanguage)
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
            .environment(\.locale, selectedLanguage.resolvedLocale())
        }
    }
}
