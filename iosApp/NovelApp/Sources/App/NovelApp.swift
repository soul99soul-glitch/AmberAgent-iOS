import SwiftUI

@main
struct NovelApp: App {
    @State private var model = NovelAppModel()

    var body: some Scene {
        WindowGroup {
            NovelRootView(model: model)
        }
    }
}

enum NovelAppRoute: Hashable {
    case project(NovelProjectID)
    case settings
    case writingSettings
    case appearance
}

/// App-level owners. Mirrors AmberAgent's `AppShell` wiring for the Novel
/// feature: one creation/view-model pair for the process, a discussion tool
/// host, and the background lifecycle coordinator.
@MainActor
@Observable
final class NovelAppModel {
    let settings: NovelAppSettingsStore
    let toolHost: NovelAppToolHost
    let creationViewModel: NovelCreationViewModel?
    let sessionViewModel: NovelSessionViewModel?
    let storageErrorMessage: String?
    let lifecycle = NovelWorkspaceLifecycleCoordinator()
    var path: [NovelAppRoute] = []

    init() {
        NovelGlobalModelWording.current = NovelGlobalModelWording(
            followTitle: "跟随默认模型",
            followValueFormat: "跟随默认 · %@",
            missingModelMessage: "还没有可用的写作模型，请先在设置里添加模型服务并选择默认模型。"
        )
        // Shared chat bubbles label replies "Amber" unless this display
        // preference is off; the standalone app has no Amber persona.
        // Ghostwriting runs for tens of minutes; the system continued-processing
        // task is reclaimed soon after backgrounding, so the audio leg is on by default.
        UserDefaults.standard.register(defaults: [
            IOSDisplayPreferenceKeys.agentName: false,
            IOSExecutionPreferenceKeys.audioKeepAlive: true
        ])
        let settings = NovelAppSettingsStore()
        let toolHost = NovelAppToolHost(settings: settings)
        self.settings = settings
        self.toolHost = toolHost
        do {
            let workspace = try NovelCreationComposition.makeViewModel(
                sharedSettings: settings,
                toolRuntime: toolHost
            )
            creationViewModel = workspace
            sessionViewModel = NovelSessionViewModel(workspace: workspace)
            storageErrorMessage = nil
        } catch {
            creationViewModel = nil
            sessionViewModel = nil
            storageErrorMessage = error.localizedDescription
        }
    }

    func navigate(to route: NovelAppRoute) {
        guard path.last != route else { return }
        path.append(route)
    }

    func resumeBackgroundWork() async {
        guard let creationViewModel else { return }
        await creationViewModel.resumeDetachedBackgroundGeneration()
        _ = await sessionViewModel?.resumeGhostwriteAfterBackgroundInterruptionIfNeeded()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        IOSBackgroundLifecycleLog.record("scenePhase=\(String(describing: phase))")
        switch phase {
        case .background:
            guard let creationViewModel else { return }
            lifecycle.enterBackground(
                waitForCompletion: {
                    await creationViewModel.waitForBackgroundGeneration()
                },
                interrupt: { deadline in
                    await creationViewModel.interruptSessionForBackground(deadline: deadline)
                }
            )
        case .active:
            lifecycle.enterForeground()
            Task { await resumeBackgroundWork() }
        case .inactive:
            break
        @unknown default:
            break
        }
    }
}

struct NovelRootView: View {
    @Bindable var model: NovelAppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var curtainMood: NovelLaunchMood? = NovelLaunchMood.current(at: Date())
    @AppStorage(IOSAppearancePreferenceKeys.mode) private var appearanceMode = IOSAppearanceMode.system.rawValue

    var body: some View {
        NavigationStack(path: $model.path) {
            root
                .navigationDestination(for: NovelAppRoute.self, destination: destination)
        }
        .tint(AmberTheme.accent)
        .preferredColorScheme(NovelTheme.pinnedColorScheme ?? (IOSAppearanceMode(rawValue: appearanceMode) ?? .system).colorScheme)
        .overlay {
            if let curtainMood, !reduceMotion, !voiceOverEnabled {
                NovelLaunchCurtain(mood: curtainMood) { self.curtainMood = nil }
            }
        }
        // Share/export progress and failures: one app-level mount point.
        .iosShareActivityOverlay()
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(phase)
        }
        .task {
            // The curtain is decorative; never show it later in the session.
            if reduceMotion || voiceOverEnabled { curtainMood = nil }
            if scenePhase == .active {
                await model.resumeBackgroundWork()
            }
        }
    }

    @ViewBuilder
    private var root: some View {
        if let viewModel = model.creationViewModel {
            NovelProjectListView(
                viewModel: viewModel,
                onOpen: { model.navigate(to: .project($0)) },
                onOpenSettings: { model.navigate(to: .settings) }
            )
            .novelCreationErrorAlert(viewModel: viewModel)
            .safeAreaInset(edge: .bottom) {
                if !model.settings.hasUsableModel {
                    NovelModelSetupPrompt { model.navigate(to: .settings) }
                }
            }
        } else {
            ContentUnavailableView(
                "小说创作暂不可用",
                systemImage: "exclamationmark.triangle",
                description: Text(model.storageErrorMessage ?? "无法打开项目存储。")
            )
        }
    }

    @ViewBuilder
    private func destination(_ route: NovelAppRoute) -> some View {
        switch route {
        case .project(let projectID):
            if let viewModel = model.creationViewModel, let session = model.sessionViewModel {
                NovelProjectWorkspaceView(
                    viewModel: viewModel,
                    sessionViewModel: session,
                    sharedSettings: model.settings,
                    projectID: projectID,
                    // The hub reaches model services as well as writing settings.
                    onOpenSettings: { model.navigate(to: .settings) }
                )
                .novelCreationErrorAlert(viewModel: viewModel)
            }
        case .settings:
            NovelAppSettingsView(
                settings: model.settings,
                onOpenWritingSettings: { model.navigate(to: .writingSettings) },
                onOpenAppearance: { model.navigate(to: .appearance) }
            )
        case .appearance:
            NovelAppearanceView()
        case .writingSettings:
            if let viewModel = model.creationViewModel {
                NovelCreationSettingsView(sharedSettings: model.settings, viewModel: viewModel)
                    .novelCreationErrorAlert(viewModel: viewModel)
            } else {
                NovelCreationSettingsView(sharedSettings: model.settings, viewModel: nil)
            }
        }
    }
}

/// Shown on the project list until a usable model is configured.
private struct NovelModelSetupPrompt: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "key.horizontal")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .symbolEffect(.wiggle.byLayer, options: .repeat(.periodic(2, delay: 3)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("先配置写作模型")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                    Text("添加 API 服务后才能开始生成。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted2)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        // A card, not a full-width bar, on iPad.
        .frame(maxWidth: 560)
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }
}
