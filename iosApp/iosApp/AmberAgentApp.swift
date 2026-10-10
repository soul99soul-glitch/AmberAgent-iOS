import SwiftUI

@main
struct AmberAgentApp: App {
    @UIApplicationDelegateAdaptor(AmberAppDelegate.self) private var appDelegate
    @State private var settingsStore = SettingsStore()

    init() {
        IOSAppLanguagePreference.normalize()
        if ProcessInfo.processInfo.arguments.contains(IOSPhoneControlSelfDiscovery.diagnosticLaunchArgument) {
            Task { @MainActor in await IOSPhoneControlSelfDiscovery.shared.start() }
        }
        if ProcessInfo.processInfo.arguments.contains(IOSPhoneControlServiceInspection.diagnosticLaunchArgument) {
            Task { @MainActor in
                await IOSPhoneControlServiceInspection().inspectAndRecord(source: "launch")
            }
        }
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
