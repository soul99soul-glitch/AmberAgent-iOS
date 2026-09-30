import AppIntents
import SwiftUI

@main
struct AmberWatchApp: App {
    @StateObject private var model: WatchTaskViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init() {
        let model = WatchTaskViewModel()
        _model = StateObject(wrappedValue: model)
        AppDependencyManager.shared.add(dependency: model)
        model.start()
    }

    var body: some Scene {
        WindowGroup {
            WatchTaskRootView(model: model)
                #if DEBUG
                .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("-amber-watch-large-text")
                             ? .xxxLarge : dynamicTypeSize)
                #endif
                .onAppear { model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.resume() }
                }
                .onOpenURL { model.handleURL($0) }
                .onChange(of: model.library?.quickActions, initial: true) { _, _ in
                    AmberWatchShortcuts.updateAppShortcutParameters()
                }
        }
        .backgroundTask(.watchConnectivity) {
            await model.receiveBackgroundConnectivity()
        }
    }
}
