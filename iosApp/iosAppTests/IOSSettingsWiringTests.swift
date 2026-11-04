import XCTest
import SwiftUI
@preconcurrency import Shared
@testable import iosApp

final class IOSSettingsWiringTests: XCTestCase {
    @MainActor
    func testAutoExpandThinkingIsPersistedAndWiredToAllReasoningCards() throws {
        let suite = "AutoExpandThinking-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = IOSDisplayPreferenceKeys.autoExpandThinking
        let preference = AppStorage(wrappedValue: true, key, store: defaults)
        XCTAssertTrue(preference.wrappedValue)
        preference.wrappedValue = false
        XCTAssertFalse(AppStorage(wrappedValue: true, key, store: defaults).wrappedValue)
        preference.wrappedValue = true
        XCTAssertTrue(AppStorage(wrappedValue: true, key, store: defaults).wrappedValue)

        let settings = try source("iosApp/DisplayFontSettingsView.swift")
        let bubble = try source("iosApp/Chat/Message/MessageBubbleView.swift")
        let novel = try source("iosApp/NovelCreation/NovelSessionBubble.swift")
        for text in [settings, bubble, novel] {
            XCTAssertTrue(text.contains("@AppStorage(IOSDisplayPreferenceKeys.autoExpandThinking) private var autoExpandThinking = true"))
        }
        let section = try XCTUnwrap(settings.range(of: "private var messageSection"))
        let nextSection = try XCTUnwrap(settings.range(of: "private var activitySection"))
        XCTAssertTrue(settings[section.lowerBound..<nextSection.lowerBound].contains("自动展开思考内容"))
        XCTAssertTrue(settings.contains("autoExpandThinking.toggle()"))
        XCTAssertEqual(bubble.components(separatedBy: "autoExpandThinking: autoExpandThinking").count - 1, 2)
        XCTAssertTrue(novel.contains("autoExpandThinking: autoExpandThinking"))
    }

    @MainActor
    func testRuntimeIshPermissionUsesTheAppPermissionStore() throws {
        let runtime = try source("iosApp/RuntimeEnvironmentView.swift")
        let shell = try source("iosApp/AppShell.swift")
        let defaults = UserDefaults(suiteName: "RuntimeIshPermission-\(UUID().uuidString)")!
        let permissionStore = IOSPermissionStore(userDefaults: defaults, taskStore: nil)
        let capability = try XCTUnwrap(IOSCapabilityRegistry.capabilities.first {
            $0.id == "ios.embedded.ish_runtime"
        })
        permissionStore.setPolicy(.disabled, for: capability)

        let view = RuntimeEnvironmentView(
            settingsStore: SettingsStore(userDefaults: defaults),
            sharedSettings: IOSSharedSettingsStore(userDefaults: defaults),
            permissionStore: permissionStore
        )

        XCTAssertTrue(view.permissionStore === permissionStore)
        XCTAssertEqual(view.permissionStore.policy(for: capability), .disabled)
        XCTAssertTrue(shell.contains("RuntimeEnvironmentView(settingsStore: settingsStore, sharedSettings: sharedSettings, permissionStore: permissionStore)"))
        XCTAssertTrue(runtime.contains("embeddedIshExecutionPolicy"))
        XCTAssertTrue(runtime.contains("set: { permissionStore.setPolicy($0, for: capability) }"))
        XCTAssertFalse(runtime.contains("permissionStore = IOSPermissionStore()"))
    }

    func testMiniAppSystemSwitchIsPersistedAndConsumedByRunnerPolicy() throws {
        let settings = try source("iosApp/MiniAppSettingsView.swift")
        let runner = try source("iosApp/MiniAppRunnerView.swift")
        let webView = try source("iosApp/MiniAppRunnerWebView.swift")
        for view in [settings, runner] {
            XCTAssertTrue(view.contains("@AppStorage(IOSMiniAppBridgePolicy.systemCapabilitiesPreferenceKey)"))
        }
        XCTAssertTrue(settings.contains("isOn: $systemCapabilitiesEnabled"))
        XCTAssertTrue(runner.contains("policy.systemCapabilitiesEnabled = systemCapabilitiesEnabled"))
        XCTAssertTrue(webView.contains("policy: policy"))
        XCTAssertTrue(webView.contains("deviceCapabilities.presentationAnchor = webView"))
        XCTAssertTrue(webView.contains("deviceCapabilities?.close()"))
    }

    /// Mac Gateway 闭环：设置入口 → 路由 → 页面；深链进入确认；APNs token 与启动注册转发到 store。
    func testMacGatewayIsReachableFromSettingsDeepLinkAndPushRegistration() throws {
        let home = try source("iosApp/Settings/SettingsHomeView.swift")
        let shell = try source("iosApp/AppShell.swift")
        let delegate = try source("iosApp/IOSLocalNotifications.swift")

        XCTAssertTrue(home.contains("route: .macGateway"))
        XCTAssertTrue(shell.contains("case .macGateway:\n                MacGatewaySettingsView()"))
        XCTAssertTrue(shell.contains("MacGatewayStore.shared.receivePairingLink(payload)"))
        XCTAssertTrue(shell.contains("rootRouter.path = [.settings, .macGateway]"))
        // Push landings and the Settings row open the task board.
        XCTAssertTrue(shell.contains("case .macTasks:\n                MacTasksBoardView()"))
        XCTAssertTrue(shell.contains("rootRouter.path = [.macTasks]"))
        XCTAssertTrue(try source("iosApp/MacGatewaySettingsView.swift").contains("router.navigate(to: .macTasks)"))
        XCTAssertTrue(delegate.contains("MacGatewayStore.shared.applicationDidFinishLaunching()"))
        XCTAssertTrue(delegate.contains("MacGatewayStore.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)"))
        XCTAssertTrue(delegate.contains("MacGatewayStore.shared.didFailToRegisterForRemoteNotifications(error)"))
    }

    func testPhoneControlSettingsReachPersistentRunScopedRuntime() throws {
        let view = try source("iosApp/PhoneControl/IOSPhoneControlSettingsView.swift")
        let execution = try source("iosApp/ExecutionSettingsView.swift")
        let shell = try source("iosApp/AppShell.swift")
        let owner = try source("iosApp/PhoneControl/IOSPhoneControlController.swift")
        let host = try source("iosApp/ChatKernelRunHost.swift")
        let chat = try source("iosApp/Chat/Generation/ChatGenerationRequestBuilder.swift")
        let inbox = try source("iosApp/Chat/Session/ChatConversationInbox.swift")
        XCTAssertTrue(execution.contains("router.navigate(to: .phoneControl)"))
        XCTAssertTrue(shell.contains("case .phoneControl:"))
        XCTAssertTrue(shell.contains("IOSPhoneControlSettingsView()"))
        XCTAssertTrue(view.contains("NavigationLink(value: Route.phoneSavedTasks)"))
        XCTAssertTrue(shell.contains("IOSPhoneControlSavedTasksView(sharedSettings: sharedSettings)"))
        XCTAssertTrue(view.contains("controller.enabled = $0"))
        XCTAssertTrue(view.contains("controller.prepareConnection()"))
        XCTAssertTrue(view.contains("phoneControlPrepareConnection"))
        XCTAssertTrue(view.contains("controller.localTunnel.state"))
        XCTAssertTrue(view.contains(".onChange(of: scenePhase)"))
        XCTAssertTrue(view.contains("phoneControlChooseApp"))
        XCTAssertTrue(view.contains("IOSPhoneControlAppPicker(controller: controller)"))
        let picker = try source("iosApp/PhoneControl/IOSPhoneControlAppPicker.swift")
        XCTAssertTrue(picker.contains("controller.loadInstalledApplications()"))
        XCTAssertTrue(picker.contains("controller.addInstalledApplication(bundleID:"))
        // The RemotePairing port is resolved per connection (it changes; 49152 is only the fallback).
        XCTAssertTrue(owner.contains("let port = await localTunnel.resolveRemotePairingPort()"))
        XCTAssertTrue(owner.contains("let endpoint = \"\\(IOSPhoneControlLoopbackRoute.peer):\\(port)\""))
        XCTAssertFalse(owner.contains("services.uniqueLocalIPv4Endpoint"))
        let pairing = try source("PhoneControlRuntime/PhoneControlPairingSession.swift")
        XCTAssertTrue(pairing.contains("IOSPhoneControlLoopbackRoute.endpoint.withCString"))
        let configuration = PhoneControlLaunchConfiguration(pairing: Data(), allowedBundleIDs: [])
        XCTAssertEqual(configuration.endpoint, "10.7.0.1:49152")
        XCTAssertEqual(configuration.connectionMode, .embedded)
        XCTAssertTrue(owner.contains("connectionMode: connectionMode"))
        XCTAssertTrue(pairing.contains("connectionMode.nativeRouteMode"))
        XCTAssertFalse(view.contains("phoneControlDuration"))
        XCTAssertFalse(view.contains("authorizeNextTask"))
        XCTAssertFalse(host.contains("revokeAuthorizationWindow"))
        XCTAssertTrue(host.contains("phoneControl.revoke(runID: runId)"))
        XCTAssertTrue(owner.contains("defaults.set(enabled, forKey: Self.enabledPreferenceKey)"))
        XCTAssertTrue(host.contains("phoneControlUserInitiated: Bool = false"))
        XCTAssertTrue(host.contains("let hasPhoneDeclarations = bridge.fullToolDeclarations()"))
        XCTAssertTrue(host.contains("phoneControlUserInitiated && hasPhoneDeclarations"))
        XCTAssertTrue(host.contains("&& phoneControl.claim(runID: runId, conversationID: conversationId?.toHexDashString())"))
        XCTAssertFalse(host.contains("phoneControl.start(runID:"))
        XCTAssertTrue(chat.contains("includePhoneControlTools: phoneControlUserInitiated && !currentRun.state.isOrchestratedChild"))
        let autoResume = try XCTUnwrap(inbox.range(of: "private func resumeYieldedRunIfReady"))
        let endResume = try XCTUnwrap(inbox.range(of: "/// 工具循环/新 run", range: autoResume.upperBound..<inbox.endIndex))
        XCTAssertFalse(inbox[autoResume.lowerBound..<endResume.lowerBound].contains("phoneControlUserInitiated: true"))
    }

    private func source(_ relativePath: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let iosAppRoot = testsDir.deletingLastPathComponent()
        let fileURL = iosAppRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    /// G7 接线闭环：设置页可见选项面板、UserDefaults key、运行时消费
    /// （coordinator 从 SettingsStore 读上限）三处齐备。
    func testChatToolResumeCapIsWiredThroughExecutionSettings() throws {
        let view = try source("iosApp/ExecutionSettingsView.swift")
        let host = try source("iosApp/ChatKernelRunHost.swift")
        let store = try source("iosApp/SettingsStore.swift")

        XCTAssertTrue(view.contains("@AppStorage(IOSExecutionPreferenceKeys.chatMaxToolResumeCount)"))
        XCTAssertTrue(view.contains("chatMaxToolResumeCountOptions"))
        XCTAssertFalse(view.contains("Stepper("))
        XCTAssertTrue(view.contains("Text(\"\\(clampedCount)\")"))
        XCTAssertFalse(view.contains("Text(\"\\(clampedCount) 次\")"))
        XCTAssertTrue(store.contains("chatMaxToolResumeCount"))
        XCTAssertEqual(SettingsStore.chatMaxToolResumeCountOptions, [128, 256, 512, 1024, 2048, 4096, 8192])
        XCTAssertEqual(SettingsStore.chatMaxToolResumeCountRange, 128...8192)
        XCTAssertTrue(host.contains("dependencies.settingsStore.chatMaxToolResumeCount"))
    }

    func testAudioKeepAliveCoversNovelCouncilDeepReadAndChatBackground() throws {
        let novelRunBridge = try source("iosApp/NovelCreation/NovelRunBridgeViewModel.swift")
        let novelStateSync = try source("iosApp/NovelCreation/NovelStateSyncViewModel.swift")
        let novelContinuity = try source("iosApp/NovelCreation/NovelContinuityViewModel.swift")
        let sessionGhostwrite = try source("iosApp/NovelCreation/Session/NovelSessionGhostwriteRecovery.swift")
        let novelGenerationStream = try source("iosApp/NovelCreation/NovelGenerationStream.swift")
        let council = try source("iosApp/Council/CouncilChatViewModel.swift")
        let deepRead = try source("iosApp/DeepReadCreateView.swift")
        let chatBackground = try source("iosApp/IOSChatBackgroundGenerationCoordinator.swift")
        let chatHost = try source("iosApp/Chat/Generation/Kernel/ChatRunProgressPresentation.swift")
        let miniApp = try source("iosApp/MiniAppRunnerView.swift")
        let keepAlive = try source("iosApp/BackgroundGenerationKeepAlive.swift")

        XCTAssertTrue(novelRunBridge.contains("beginBackgroundGeneration(for: request)"))
        XCTAssertTrue(novelRunBridge.contains("BackgroundGenerationKeepAlive.shared.begin("))
        XCTAssertTrue(novelStateSync.contains("beginStateSyncBackgroundLease("))
        XCTAssertTrue(novelStateSync.contains("BackgroundGenerationKeepAlive.shared.begin("))
        XCTAssertTrue(novelContinuity.contains("beginContinuityBackgroundLease("))
        XCTAssertTrue(novelContinuity.contains("BackgroundGenerationKeepAlive.shared.begin("))
        XCTAssertTrue(sessionGhostwrite.contains("beginGhostwriteBackgroundLease("))
        XCTAssertTrue(sessionGhostwrite.contains("BackgroundGenerationKeepAlive.shared.begin("))
        XCTAssertTrue(novelGenerationStream.contains("BackgroundGenerationKeepAlive.shared.begin("))
        XCTAssertTrue(council.contains("beginBackgroundKeepAlive(for: discussionID)"))
        XCTAssertTrue(council.contains("beginMaterialsKeepAlive()"))
        XCTAssertTrue(deepRead.contains("BackgroundGenerationKeepAlive.shared.begin("))
        XCTAssertTrue(chatHost.contains("backgroundExecution.begin("))
        XCTAssertTrue(chatBackground.contains("beginChatBackgroundKeepAlive("))
        XCTAssertTrue(chatBackground.contains("submitSystemFallback: true"))
        XCTAssertTrue(chatBackground.contains("submitSystemTask: submitSystemFallback"))
        XCTAssertTrue(keepAlive.contains("handoffBridgeLeaseId"))
        XCTAssertTrue(keepAlive.contains(".handoff-bridge"))
        XCTAssertTrue(chatBackground.contains("必须在派发前就把音频腿拉起来"))
        let miniAppBegin = try XCTUnwrap(miniApp.range(of: "BackgroundGenerationKeepAlive.shared.begin("))
        let miniAppEnsure = try XCTUnwrap(miniApp.range(of: "durableRunStore.ensureRunning("))
        XCTAssertLessThan(miniAppBegin.lowerBound, miniAppEnsure.lowerBound)
    }

    func testChatComposerSendAndStopReachTheCurrentConversationRun() throws {
        let chat = try source("iosApp/Chat/Composer/ChatViewComposer.swift")
        let viewModel = try source("iosApp/Chat/Session/ChatConversationMutations.swift")
        let sendStart = try XCTUnwrap(chat.range(of: "private func sendComposerMessage()"))
        let sendEnd = try XCTUnwrap(chat.range(of: "private func openComposerModelSheet()", range: sendStart.upperBound..<chat.endIndex))
        let send = chat[sendStart.lowerBound..<sendEnd.lowerBound]
        let gate = try XCTUnwrap(send.range(of: "guard sendEnabled(for: committedText) else { return }"))
        let dispatch = try XCTUnwrap(send.range(of: "viewModel.sendMessage(startsGenerationAfterInsertion: true)"))
        let cancelStart = try XCTUnwrap(viewModel.range(of: "func cancelGeneration()"))
        let cancelEnd = try XCTUnwrap(viewModel.range(of: "func cancelGeneration(runId:", range: cancelStart.upperBound..<viewModel.endIndex))
        let cancel = viewModel[cancelStart.lowerBound..<cancelEnd.lowerBound]

        XCTAssertTrue(chat.contains("onSend: sendComposerMessage"))
        XCTAssertTrue(chat.contains("isLoading: isComposerStopMode"))
        XCTAssertTrue(chat.contains("viewModel.isGenerationActiveForCurrentConversation"))
        XCTAssertTrue(chat.contains("viewModel.cancelGeneration()"))
        XCTAssertTrue(send.contains("composerInputController.committedText()"))
        XCTAssertFalse(send.contains("dismissKeyboard()"))
        XCTAssertTrue(chat.contains("return viewModel.composerSendBlockReason(for: text) == nil"))
        XCTAssertLessThan(gate.lowerBound, dispatch.lowerBound)
        // 停止键在生成延后启动的窗口内也要作用于本轮 run。
        XCTAssertTrue(cancel.contains("startDeferredGenerationNow()"))
        XCTAssertTrue(cancel.contains("guard let currentConversationId else { return }"))
        XCTAssertTrue(cancel.contains("conversationId: currentConversationId"))
    }

    func testChatMessageListRendersNativeTimelineDirectlyWithoutRoutePolicy() throws {
        let chatView = try source("iosApp/ChatView.swift")
        let list = try source("iosApp/Chat/Timeline/NativeChatTimelineView.swift")
        let projection = try source("iosApp/Chat/Timeline/Projection/NativeTimelineProjection.swift")
        let settings = try source("iosApp/DisplayFontSettingsView.swift")
        let keys = try source("iosApp/AmberDesignSystem.swift")

        // native timeline 已 hardcode 为唯一 Chat 列表路径：route 判定层（route enum /
        // policy / eligibility / 开关 flag）整层退役，ChatView 直接渲染 NativeChatTimelineView。
        XCTAssertTrue(chatView.contains("NativeChatTimelineView("))
        XCTAssertFalse(chatView.contains("ChatMessageListRoutePolicy.route"))
        XCTAssertFalse(chatView.contains("swiftUICleanListEnabled"))
        XCTAssertFalse(chatView.contains("@AppStorage(NativeChatTimelineStaticRenderFeatureFlags.key)"))
        XCTAssertFalse(chatView.contains("@AppStorage(NativeChatTimelineStreamingTailFeatureFlags.key)"))
        XCTAssertFalse(list.contains("enum ChatMessageListRoutePolicy"))
        XCTAssertFalse(list.contains("NativeChatTimelineRoutePolicy.shouldUseNativeTimeline"))
        XCTAssertFalse(list.contains("var nativeScrollDriverEnabled: Bool"))
        XCTAssertTrue(list.contains("@State private var scrollDriver = NativeTimelineScrollDriver()"))
        XCTAssertTrue(list.contains("scrollDriver.attach(scrollView)"))
        XCTAssertFalse(chatView.contains("NativeChatTimelineMirror"))
        XCTAssertFalse(chatView.contains("recordNativeTimelineMirrorIfEnabled"))
        XCTAssertFalse(projection.contains("NativeTimelineMirrorInput"))
        XCTAssertFalse(projection.contains("NativeChatTimelineMirror"))
        XCTAssertTrue(settings.contains("DisplayToggleRow(title: \"生成时跟随滚动\", isOn: followGeneration)"))
        XCTAssertTrue(keys.contains("static let followGeneration = \"app.amber.ios.display.followGeneration\""))
        XCTAssertTrue(chatView.contains("@AppStorage(IOSDisplayPreferenceKeys.followGeneration) private var followGeneration = true"))
        XCTAssertTrue(chatView.contains("followGeneration: followGeneration"))
    }

    func testStaticMarkdownUsesTheSharedExternalURLPolicy() throws {
        let markdown = try source("iosApp/MarkdownView.swift")

        XCTAssertTrue(markdown.contains("ChatMarkdownOpenURLPolicy.url(from: raw)"))
        XCTAssertFalse(markdown.contains("scheme == \"http\" || scheme == \"https\""))
        XCTAssertEqual(
            ChatMarkdownOpenURLPolicy.url(from: "mailto:hello@example.com")?.absoluteString,
            "mailto:hello@example.com"
        )
    }

    func testActivityIslandEdgeGlowIsOptionalAndDefaultsOff() throws {
        let keys = try source("iosApp/AmberDesignSystem.swift")
        let settings = try source("iosApp/DisplayFontSettingsView.swift")
        let activityIsland = try source("iosApp/ChatActivityIslandView.swift")
        let storageDeclaration =
            "@AppStorage(IOSDisplayPreferenceKeys.activityIslandEdgeGlow)" +
            " private var activityIslandEdgeGlow = false"

        XCTAssertTrue(
            keys.contains(
                "static let activityIslandEdgeGlow = \"app.amber.ios.display.activityIslandEdgeGlow\""
            )
        )
        XCTAssertTrue(settings.contains(storageDeclaration))
        XCTAssertTrue(settings.contains("彩色边缘辉光"))
        XCTAssertTrue(settings.contains("activityIslandEdgeGlow.toggle()"))
        XCTAssertTrue(activityIsland.contains(storageDeclaration))
        XCTAssertTrue(activityIsland.contains("if activityIslandEdgeGlow,"))
    }

    /// 生成完成触觉：「显示与字体 → 生成完成振动」默认开启，off 时所有完成路径零触发，on 时正常触发，
    /// 等待子代理的前台分段让出及子代理会话不误触发，且按钮/安全审批独立触感保持不变。
    @MainActor
    func testCompletionHapticToggleGatesCompletionPathsForOffAndOn() throws {
        let keys = try source("iosApp/AmberDesignSystem.swift")
        let settings = try source("iosApp/DisplayFontSettingsView.swift")
        let chatAux = try source("iosApp/Chat/Generation/ChatAuxiliaryGeneration.swift")
        let topBar = try source("iosApp/ChatTopBarView.swift")
        let novelSeal = try source("iosApp/NovelCreation/NovelInkSeal.swift")
        let deepRead = try source("iosApp/IOSDeepReadNewsroomView.swift")
        let storageDeclaration =
            "@AppStorage(IOSDisplayPreferenceKeys.completionHaptic)" +
            " private var completionHaptic = true"

        XCTAssertEqual(IOSDisplayPreferenceKeys.completionHaptic, "app.amber.ios.display.completionHaptic")
        XCTAssertTrue(keys.contains("static func isCompletionHapticEnabled"))
        XCTAssertTrue(keys.contains("static func triggerCompletion"))
        XCTAssertTrue(settings.contains(storageDeclaration))
        XCTAssertTrue(settings.contains("生成完成振动"))
        XCTAssertTrue(settings.contains("completionHaptic.toggle()"))
        XCTAssertTrue(chatAux.contains("AmberHaptics.triggerCompletion(.rigidImpact)"))
        XCTAssertFalse(chatAux.contains("AmberHaptics.trigger(.rigidImpact)"))
        XCTAssertTrue(topBar.contains("AmberHaptics.triggerCompletion(.lightImpact)"))
        XCTAssertFalse(topBar.contains("else if notice.kind == .completed {\n                UIImpactFeedbackGenerator"))
        XCTAssertTrue(topBar.contains("if notice.kind == .awaitingUser {\n                UINotificationFeedbackGenerator().notificationOccurred(.warning)"))
        XCTAssertTrue(novelSeal.contains("AmberHaptics.triggerCompletion(.rigidImpact)"))
        XCTAssertTrue(deepRead.contains(storageDeclaration))
        XCTAssertTrue(deepRead.contains(".sensoryFeedback(.impact(weight: .heavy), trigger: fire) { _, _ in completionHaptic }"))

        let standard = UserDefaults.standard
        let key = IOSDisplayPreferenceKeys.completionHaptic
        let previousValue = standard.object(forKey: key)
        var recordedEvents: [AmberHapticEvent] = []
        AmberHaptics.onTriggerForTesting = { recordedEvents.append($0) }
        defer {
            AmberHaptics.onTriggerForTesting = nil
            if let previousValue {
                standard.set(previousValue, forKey: key)
            } else {
                standard.removeObject(forKey: key)
            }
        }

        let suiteName = "CompletionHapticRuntime-\(UUID().uuidString)"
        let vmDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { vmDefaults.removePersistentDomain(forName: suiteName) }
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(userDefaults: vmDefaults),
            sharedSettings: IOSSharedSettingsStore(userDefaults: vmDefaults),
            autoGenerateResponses: false
        )
        let state = ChatConversationRunState(conversationId: nil)
        state.messages = [
            UIMessage.companion.user(prompt: "你好"),
            UIMessage.companion.assistant(prompt: "你好，这是最终回复。")
        ]

        // 1. 默认值（未写入 key）为 true，前台完成与后台提醒到达均正常触发
        standard.removeObject(forKey: key)
        XCTAssertTrue(AmberHaptics.isCompletionHapticEnabled(defaults: standard))
        viewModel.onGenerationCompleted(state: state)
        XCTAssertTrue(AmberHaptics.triggerCompletion(.lightImpact, defaults: standard))
        XCTAssertEqual(recordedEvents, [.rigidImpact, .lightImpact])

        // 2. 开关置为 off（false）：前台完成、后台完成提醒均零触发；独立控件触感仍保留
        recordedEvents.removeAll()
        standard.set(false, forKey: key)
        XCTAssertFalse(AmberHaptics.isCompletionHapticEnabled(defaults: standard))
        viewModel.onGenerationCompleted(state: state)
        XCTAssertFalse(AmberHaptics.triggerCompletion(.lightImpact, defaults: standard))
        XCTAssertFalse(AmberHaptics.triggerCompletion(.rigidImpact, defaults: standard))
        XCTAssertTrue(recordedEvents.isEmpty, "生成完成振动关闭时所有完成路径必须零触发")
        AmberHaptics.trigger(.selection)
        XCTAssertEqual(recordedEvents, [.selection], "按钮/选择器独立触感不得被生成完成开关误伤")

        // 3. 开关实时切回 on（true）：恢复触发；分段等待子代理让出或子代理会话不触发
        recordedEvents.removeAll()
        standard.set(true, forKey: key)
        state.waitingForChildRunId = "run-yielded"
        viewModel.onGenerationCompleted(state: state)
        XCTAssertTrue(recordedEvents.isEmpty, "前台让出等待子代理期间不应提前触发完成振动")

        state.waitingForChildRunId = nil
        state.isOrchestratedChild = true
        viewModel.onGenerationCompleted(state: state)
        XCTAssertTrue(recordedEvents.isEmpty, "后台子代理会话不应直接触发前台完成振动")

        state.isOrchestratedChild = false
        viewModel.onGenerationCompleted(state: state)
        XCTAssertEqual(recordedEvents, [.rigidImpact], "主会话最终完成且开关开启时应触发一次刚性轻触")
    }

    func testBackgroundToolEnginePublishesLiveActivityStagesAtExecutionBoundaries() throws {
        let coordinator = try source("iosApp/IOSChatBackgroundGenerationCoordinator.swift")
        let executor = try source("iosApp/Chat/Background/IOSChatBackgroundExecutor.swift")
        let engine = try source("iosApp/IOSAgentToolEngine.swift")
        let runStart = try XCTUnwrap(executor.range(of: "let initialResult = await engine.run("))
        let runSuffix = String(executor[runStart.lowerBound...])
        let runEnd = try XCTUnwrap(runSuffix.range(of: "case .singleToolOnly:"))
        let runBlock = String(runSuffix[..<runEnd.lowerBound])

        XCTAssertTrue(engine.contains("onToolExecutionStarted"))
        XCTAssertTrue(engine.contains("onAssistantStage"))
        XCTAssertTrue(engine.contains("onMessagesUpdated"))
        XCTAssertTrue(runBlock.contains("onToolExecutionStarted:"))
        XCTAssertTrue(runBlock.contains("onAssistantStage:"))
        XCTAssertTrue(runBlock.contains("onMessagesUpdated:"))
        XCTAssertTrue(runBlock.contains("job.messagesSnapshot.replace(with: messages)"))
        XCTAssertTrue(executor.contains("AsyncStream<AgentActivityPresentation>.makeStream()"))
        XCTAssertTrue(runBlock.contains("presentationEvents.continuation.yield("))
        XCTAssertFalse(runBlock.contains("await self.publishRunningPresentation("))
        XCTAssertTrue(coordinator.contains("guard runState.allowsRunningPresentation else { return }"))
        XCTAssertTrue(runBlock.contains("AgentActivityPresentation.runningTool(toolName: toolName, input: input)"))
        XCTAssertGreaterThanOrEqual(
            executor.components(
                separatedBy: "stage: AgentActivityResponseStagePolicy.initialStage"
            ).count - 1,
            2,
            "后台初次输出及工具后的下一轮都必须先回到准备态，再由真实 chunk 推进阶段"
        )

        let expirationStart = try XCTUnwrap(
            executor.range(of: "backgroundTask.expirationHandler = { [weak self] in")
        )
        let expirationSuffix = String(executor[expirationStart.lowerBound...])
        let expirationEnd = try XCTUnwrap(expirationSuffix.range(of: "let requestProvider: ProviderSetting"))
        let expirationBlock = String(expirationSuffix[..<expirationEnd.lowerBound])
        let mainActorHop = try XCTUnwrap(expirationBlock.range(of: "Task { @MainActor in"))
        let terminalClaim = try XCTUnwrap(
            expirationBlock.range(of: "let claim = runState.expireAndReserveTerminal()")
        )

        XCTAssertLessThan(
            terminalClaim.lowerBound,
            mainActorHop.lowerBound,
            "The expiration callback must reserve terminal ownership before hopping to MainActor."
        )
    }

    func testReasoningExpansionAndIslandGlowHonorFrozenMotion() throws {
        let misc = try source("iosApp/ChatMiscViews.swift")
        let island = try source("iosApp/ChatActivityIslandView.swift")
        let glow = try source("iosApp/IslandEdgeGlowView.swift")

        // Reduce Motion 仍然钉死无动画；终态自动收起额外走无动画单帧收口
        // （suppressesShowsBodyAnimation），两条都要锁。
        XCTAssertTrue(misc.contains("reduceMotion || suppressesShowsBodyAnimation ? nil : .easeInOut(duration: 0.28)"))
        XCTAssertTrue(misc.contains("value: showsBody"))
        XCTAssertTrue(misc.contains("suppressesShowsBodyAnimation = true"))
        XCTAssertTrue(misc.contains("private func setExpanded(_ expanded: Bool, duration: Double)"))
        XCTAssertTrue(island.contains("isPaused: presentation.isFrozen"))
        XCTAssertTrue(glow.contains("paused: isPaused, reduceMotion: reduceMotion"))
        XCTAssertTrue(glow.contains("isAnimated && !isPaused && !isReduceMotion"))
    }

    func testMiMoCodingPlanIsSelectableInProviderSettings() throws {
        let detail = try source("iosApp/ProviderDetailView.swift")
        XCTAssertTrue(detail.contains("if brand == OpenAIBrand.mimo { return .mimoCodingPlan }"))
        XCTAssertTrue(detail.contains("switchAuthMode(to: tokenPlan)"))
        XCTAssertTrue(detail.contains("sharedSettings.setOpenAIAuthMode(providerId: providerId, authMode: mode)"))
        XCTAssertTrue(detail.contains("openAI.brand != OpenAIBrand.mimo"))
    }

    func testGrokWebLoginIsWiredToProviderSettingsAndChatRuntime() throws {
        let detail = try source("iosApp/ProviderDetailView.swift")
        let configuration = try source("iosApp/ChatProviderConfiguration.swift")
        let runtime = try source("iosApp/ChatKernelRunHost.swift")
        let grokProvider = try source("iosApp/IOSGrokWebProvider.swift")
        let grokOAuth = try source("iosApp/IOSGrokOAuthClient.swift")

        XCTAssertTrue(detail.contains("GrokWebLoginView("))
        XCTAssertTrue(detail.contains("IOSGrokWebConstants.cliProxyBaseUrl"))
        XCTAssertTrue(detail.contains("adoptGrokOAuthChatCatalog"))
        XCTAssertTrue(detail.contains("legacyWebModelIds"))
        XCTAssertTrue(detail.contains("selectChatModelAsDefault(grok46.id.description())"))
        XCTAssertTrue(detail.contains("IOSGrokOAuthAuthStore.loadBackup"))
        XCTAssertTrue(detail.contains("grokSection"))
        XCTAssertTrue(detail.contains("tokenPlanSection"))
        XCTAssertTrue(detail.contains("headerDisguiseSection"))
        XCTAssertTrue(detail.contains("OpenAICompatUserAgents.shared.OPENCODE"))
        XCTAssertTrue(detail.contains("notice = IOSAppLocalization.string("))
        XCTAssertTrue(detail.contains("\"服务商配置已保存。\""))
        XCTAssertFalse(detail.contains("alert = .saved"))
        XCTAssertFalse(detail.contains("alert = .currentModelSet"))

        XCTAssertTrue(configuration.contains("IOSGrokWebProviderResolver.isGrokWebProvider(provider)"))
        XCTAssertTrue(configuration.contains(".grokNotSignedIn"))
        XCTAssertTrue(configuration.contains("hasUsableCredential"))
        XCTAssertTrue(configuration.contains("credentialStatusTitle"))

        XCTAssertTrue(runtime.contains("IOSGrokWebProviderResolver.isGrokWebConfiguration(openAI)"))
        XCTAssertTrue(runtime.contains("IOSGrokWebProviderResolver.resolved("))
        XCTAssertTrue(runtime.contains("IOSGrokWebProviderResolver.augmentParamsForGrok("))
        XCTAssertTrue(detail.contains("providerBackup: grokProviderBackup"))
        XCTAssertTrue(detail.contains("baseUrl: backup.baseUrl"))
        XCTAssertTrue(grokProvider.contains("IOSGrokWebBrowserTransport"))
        XCTAssertTrue(grokProvider.contains(#"credentials: "include""#))
        XCTAssertTrue(grokProvider.contains("Authorization"))
        XCTAssertTrue(grokProvider.contains("IOSGrokOAuthClients.shared(providerId: providerId).resolveAccessToken()"))
        XCTAssertTrue(grokProvider.contains("@escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void"))
        XCTAssertTrue(grokProvider.contains("Grok Web 未能停留在 grok.com"))
        XCTAssertTrue(grokProvider.contains("if oauthToken != nil"))
        XCTAssertTrue(grokProvider.contains("cliProxyBaseUrl"))
        XCTAssertTrue(grokOAuth.contains("cli-chat-proxy.grok.com"))
        XCTAssertTrue(grokOAuth.contains("grok-4.6"))
        XCTAssertFalse(grokProvider.contains("session.bytes(for:"))
        XCTAssertTrue(detail.contains("用 Grok 账号登录"))
        XCTAssertFalse(detail.contains("已通过系统浏览器授权"))

        let grokLogin = try source("iosApp/GrokWebLoginView.swift")
        XCTAssertTrue(grokLogin.contains("ASWebAuthenticationSession("))
        XCTAssertTrue(grokLogin.contains("prefersEphemeralWebBrowserSession = false"))
        XCTAssertTrue(grokLogin.contains("开始登录"))
        XCTAssertTrue(grokLogin.contains("loopback?.stop()"))
        XCTAssertTrue(grokLogin.contains("attachProviderBackup"))
        XCTAssertTrue(grokLogin.contains(".onDisappear { model.cancelLogin() }"))
        XCTAssertFalse(grokLogin.contains("GrokWebLoginWebView"))
        XCTAssertFalse(grokLogin.contains("WKWebView"))
        XCTAssertTrue(grokLogin.contains("IOSGrokOAuthPKCE.buildAuthorizationURL"))
        XCTAssertTrue(grokLogin.contains("if !model.isSignedIn"))
        XCTAssertTrue(grokOAuth.contains("oauth.backup"))
    }

    func testGrokOAuthAuthorizationURLUsesLoopbackAndPKCE() {
        let verifier = IOSGrokOAuthPKCE.generateCodeVerifier()
        XCTAssertEqual(verifier.count, 64)
        let challenge = IOSGrokOAuthPKCE.s256Challenge(verifier: verifier)
        XCTAssertFalse(challenge.contains("+"))
        XCTAssertFalse(challenge.contains("/"))
        XCTAssertFalse(challenge.contains("="))

        let url = IOSGrokOAuthPKCE.buildAuthorizationURL(state: "st", nonce: "nn", codeChallenge: "ch")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let values = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["client_id"], IOSGrokOAuthConstants.clientId)
        XCTAssertEqual(values["redirect_uri"], IOSGrokOAuthConstants.redirectUri)
        XCTAssertEqual(values["state"], "st")
        XCTAssertEqual(values["nonce"], "nn")
        XCTAssertEqual(values["code_challenge"], "ch")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertTrue(values["scope"]?.contains("offline_access") == true)
        XCTAssertTrue(values["scope"]?.contains("grok-cli:access") == true)
        XCTAssertTrue(values["scope"]?.contains("conversations:read") == true)
        XCTAssertTrue(values["scope"]?.contains("api:access") == true)

        let callback = "GET /callback?code=abc&state=st HTTP/1.1\r\nHost: 127.0.0.1:8787\r\n\r\n"
        let callbackURL = IOSLoopbackOAuthRequest.callbackURL(
            from: callback,
            port: Int(IOSGrokOAuthConstants.loopbackPort),
            pathPrefix: IOSGrokOAuthConstants.callbackPath
        )
        XCTAssertEqual(callbackURL?.host, "127.0.0.1")
        XCTAssertEqual(callbackURL?.path, "/callback")
        XCTAssertEqual(
            URLComponents(url: callbackURL!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value,
            "abc"
        )
        XCTAssertNil(
            IOSLoopbackOAuthRequest.callbackURL(
                from: "GET /oauth/callback?code=abc HTTP/1.1\r\n\r\n",
                port: 8787,
                pathPrefix: "/callback"
            )
        )
    }

    func testGrokOAuthTokenStoreRoundTripAndSignsInWithoutSSOCookie() {
        let id = KotlinUuid.companion.random()
        let providerId = id.description()
        defer {
            IOSGrokOAuthAuthStore.clear(providerId: providerId)
            IOSGrokWebAuthStore.clear(providerId: providerId)
        }
        XCTAssertNil(IOSGrokOAuthAuthStore.load(providerId: providerId))

        let backup = IOSGrokWebProviderBackup(
            baseUrl: "https://api.x.ai/v1",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false
        )
        let tokens = IOSGrokOAuthTokens(
            accessToken: "at",
            refreshToken: "rt",
            expiresAtMillis: 1_800_000_000_000,
            idToken: nil,
            email: "user@example.com",
            providerBackup: backup
        )
        XCTAssertTrue(IOSGrokOAuthAuthStore.save(providerId: providerId, tokens: tokens))
        XCTAssertEqual(IOSGrokOAuthAuthStore.load(providerId: providerId), tokens)
        XCTAssertEqual(IOSGrokOAuthAuthStore.load(providerId: providerId)?.providerBackup?.baseUrl, "https://api.x.ai/v1")

        let provider = ProviderSetting.OpenAI(
            id: id,
            enabled: true,
            name: "xAI",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "",
            baseUrl: IOSGrokWebConstants.webBaseUrl,
            chatCompletionsPath: "/conversations/new",
            useResponseApi: true,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
        XCTAssertTrue(IOSGrokWebProviderResolver.isSignedIn(provider))

        IOSGrokOAuthAuthStore.clear(providerId: providerId)
        XCTAssertNil(IOSGrokOAuthAuthStore.load(providerId: providerId))
        XCTAssertFalse(IOSGrokWebProviderResolver.isSignedIn(provider))
    }

    func testGrokOAuthResolvedRewritesToCliProxyAndAttachesIdentityHeaders() async throws {
        let id = KotlinUuid.companion.random()
        let providerId = id.description()
        defer { IOSGrokOAuthAuthStore.clear(providerId: providerId) }

        let tokens = IOSGrokOAuthTokens(
            accessToken: "grok-access",
            refreshToken: "grok-refresh",
            expiresAtMillis: 3_000_000_000_000,
            idToken: nil,
            email: "grok@example.com",
            providerBackup: nil
        )
        XCTAssertTrue(IOSGrokOAuthAuthStore.save(providerId: providerId, tokens: tokens))

        let original = ProviderSetting.OpenAI(
            id: id,
            enabled: true,
            name: "xAI",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "",
            baseUrl: IOSGrokWebConstants.webBaseUrl,
            chatCompletionsPath: "/conversations/new",
            useResponseApi: true,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
        XCTAssertTrue(IOSGrokWebProviderResolver.isGrokWebConfiguration(original))
        XCTAssertFalse(IOSGrokWebProviderResolver.isGrokCliProxyConfiguration(original))

        let resolved = try await IOSGrokWebProviderResolver.resolved(original)
        let openAI = try XCTUnwrap(resolved as? ProviderSetting.OpenAI)
        XCTAssertEqual(openAI.apiKey, "grok-access")
        XCTAssertEqual(openAI.baseUrl, IOSGrokWebConstants.cliProxyBaseUrl)
        XCTAssertTrue(openAI.useResponseApi)
        XCTAssertTrue(IOSGrokWebProviderResolver.isGrokCliProxyConfiguration(openAI))
        XCTAssertFalse(IOSGrokWebProviderResolver.isGrokWebConfiguration(openAI))
        XCTAssertTrue(IOSGrokWebProviderResolver.isXAIProvider(openAI))

        let model = Model(
            modelId: "grok-4.6",
            displayName: "Grok 4.6",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        let params = IOSGrokWebProviderResolver.augmentParamsForGrok(
            TextGenerationParams(
                model: model,
                temperature: nil,
                topP: nil,
                maxTokens: nil,
                tools: [],
                reasoningLevel: ReasoningLevel.off,
                customHeaders: [],
                customBody: []
            ),
            provider: openAI
        )
        let headers = Dictionary(uniqueKeysWithValues: params.customHeaders.map { ($0.name, $0.value) })
        XCTAssertEqual(headers["x-grok-client-identifier"], "grok-shell")
        XCTAssertEqual(headers["x-grok-client-version"], IOSGrokCliProxyIdentity.clientVersion)
        XCTAssertEqual(headers["X-XAI-Token-Auth"], "xai-grok-cli")
        XCTAssertEqual(headers["x-authenticateresponse"], "authenticate-response")
        XCTAssertEqual(headers["x-grok-model-override"], "grok-4.6")
        XCTAssertEqual(IOSGrokWebConstants.fallbackModels.first?.modelId, "grok-4.6")
    }

    func testGrokCliIdentityMeetsProxyVersionFloor() throws {
        let headers = IOSGrokCliProxyIdentity.headers()
        let version = try XCTUnwrap(headers["x-grok-client-version"])
        // The proxy rejects versions below 1.0.13 with HTTP 426.
        // Keep this floor independent of the production constant.
        XCTAssertNotEqual(version.compare("1.0.13", options: .numeric), .orderedAscending)
        XCTAssertEqual(headers["User-Agent"], "grok-shell/\(version) (ios; arm64)")
    }

    func testGrokOAuthDoesNotRewriteUnrelatedOpenAIProvider() async throws {
        let id = KotlinUuid.companion.random()
        let providerId = id.description()
        defer {
            IOSGrokOAuthAuthStore.clear(providerId: providerId)
            IOSGrokWebAuthStore.clear(providerId: providerId)
        }

        XCTAssertTrue(
            IOSGrokOAuthAuthStore.save(
                providerId: providerId,
                tokens: IOSGrokOAuthTokens(
                    accessToken: "stale-grok-access",
                    refreshToken: "stale-grok-refresh",
                    expiresAtMillis: 3_000_000_000_000,
                    idToken: nil,
                    email: nil,
                    providerBackup: nil
                )
            )
        )

        let provider = ProviderSetting.OpenAI(
            id: id,
            enabled: true,
            name: "Custom OpenAI",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "ordinary-api-key",
            baseUrl: "https://api.example.com/v1",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
        XCTAssertFalse(IOSGrokWebProviderResolver.isGrokWebProvider(provider))
        XCTAssertFalse(IOSGrokWebProviderResolver.isSignedIn(provider))

        let resolved = try await IOSGrokWebProviderResolver.resolved(provider)
        let resolvedOpenAI = try XCTUnwrap(resolved as? ProviderSetting.OpenAI)
        XCTAssertEqual(resolvedOpenAI.baseUrl, provider.baseUrl)
        XCTAssertEqual(resolvedOpenAI.apiKey, provider.apiKey)

        let model = Model(
            modelId: "ordinary-model",
            displayName: "Ordinary model",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        let params = IOSGrokWebProviderResolver.augmentParamsForGrok(
            TextGenerationParams(
                model: model,
                temperature: nil,
                topP: nil,
                maxTokens: nil,
                tools: [],
                reasoningLevel: ReasoningLevel.off,
                customHeaders: [],
                customBody: []
            ),
            provider: provider
        )
        XCTAssertTrue(params.customHeaders.isEmpty)
    }

    func testGrokCliProxyModelListParserReadsOpenAIShape() {
        let json = """
        {"data":[{"id":"grok-4.6","name":"Grok 4.6"},{"id":"grok-build"}]}
        """.data(using: .utf8)!
        let models = IOSGrokOAuthClient.parseModels(json)
        XCTAssertEqual(models.map(\.modelId), ["grok-4.6", "grok-build"])
        XCTAssertEqual(models.first?.displayName, "Grok 4.6")
        XCTAssertEqual(models.last?.displayName, "grok-build")
    }

    func testGrokWebAuthenticationRequiresSSOAndRestoresReadWriteCookies() {
        let analytics = makeCookie(name: "analytics", value: "present")
        let sso = makeCookie(name: "sso", value: "session-token")

        XCTAssertNil(IOSGrokWebCookieValidator.ssoCookieHeader(from: [analytics]))
        XCTAssertEqual(
            IOSGrokWebCookieValidator.ssoCookieHeader(from: [analytics, sso]),
            "sso=session-token"
        )
        XCTAssertFalse(IOSGrokWebCookieValidator.hasSSOCookie(in: "analytics=present"))
        XCTAssertTrue(IOSGrokWebCookieValidator.hasSSOCookie(in: "analytics=present; sso=session-token"))
        let cookies = IOSGrokWebCookieValidator.authenticationCookies(from: "sso=session-token")

        XCTAssertEqual(Set(cookies.map(\.name)), Set(["sso", "sso-rw"]))
        XCTAssertTrue(cookies.allSatisfy { $0.value == "session-token" })
        XCTAssertTrue(cookies.allSatisfy { $0.domain == ".grok.com" })
        XCTAssertTrue(cookies.allSatisfy(\.isSecure))
    }

    func testGrokWebModelResolverMapsSeededModelAndRejectsAPIOnlyModel() throws {
        XCTAssertEqual(
            try IOSGrokWebModelResolver.resolve("grok-4.20-fast"),
            IOSGrokWebWireModel(modelName: "grok-420", modelMode: "MODEL_MODE_FAST")
        )

        XCTAssertThrowsError(try IOSGrokWebModelResolver.resolve("grok-4.5")) { error in
            XCTAssertTrue(error.localizedDescription.contains("xAI API"))
            XCTAssertTrue(error.localizedDescription.contains("sub2api"))
        }
    }

    func testGrokWebTerminalFramesPreserveTokensSurfaceErrorsAndCloseTransport() throws {
        let provider = try source("iosApp/IOSGrokWebProvider.swift")
        let terminal = #"{"result":{"response":{"token":"final","isThinking":false,"finalMetadata":{"done":true}}}}"#
        let error = #"data: {"error":{"message":"session expired"}}"#

        XCTAssertEqual(
            IOSGrokWebStreamParser.parse(terminal),
            IOSGrokWebStreamFrame(token: "final", isFinished: true, errorMessage: nil)
        )
        XCTAssertEqual(
            IOSGrokWebStreamParser.parse(error),
            IOSGrokWebStreamFrame(token: nil, isFinished: true, errorMessage: "session expired")
        )
        XCTAssertTrue(provider.contains("return frame.isFinished"))
    }

    func testCouncilSettingsExposeAnExplicitCurrentModelConnectivityProbe() throws {
        let settings = try source("iosApp/CouncilSettingsView.swift")
        let runtime = try source("iosApp/Council/CouncilRoomSheets.swift")

        XCTAssertTrue(settings.contains("测试当前议会模型"))
        XCTAssertTrue(settings.contains("IOSCouncilModelConnectivityTester"))
        XCTAssertTrue(settings.contains("实际回退"))
        // 生产入口跳过旧 CouncilView/CouncilSettingsView，活设置 sheet 必须自带连通性预检。
        XCTAssertTrue(runtime.contains("测试当前议会模型"))
        XCTAssertTrue(runtime.contains("IOSCouncilModelConnectivityTester"))
    }

    func testGrokWebPayloadDefaultsToChatAndSupportsIsolatedNovelRequests() {
        let wireModel = IOSGrokWebWireModel(
            modelName: "grok-420",
            modelMode: "MODEL_MODE_FAST"
        )

        let chatPayload = IOSGrokWebPayloadBuilder.makePayload(
            prompt: "chat prompt",
            wireModel: wireModel
        )
        XCTAssertEqual(chatPayload["disableSearch"] as? Bool, false)
        XCTAssertEqual(chatPayload["disableMemory"] as? Bool, false)

        let novelPayload = IOSGrokWebPayloadBuilder.makePayload(
            prompt: "novel prompt",
            wireModel: wireModel,
            options: .novel
        )
        XCTAssertEqual(novelPayload["disableSearch"] as? Bool, true)
        XCTAssertEqual(novelPayload["disableMemory"] as? Bool, true)
        XCTAssertEqual(novelPayload["message"] as? String, "novel prompt")
        XCTAssertEqual(novelPayload["modelName"] as? String, "grok-420")
    }

    func testProviderEndpointPolicyAllowsHTTPOnlyForIPAddressHosts() {
        XCTAssertTrue(IOSProviderEndpointPolicy.isValidBaseURL("https://sub2api.example/v1"))
        XCTAssertTrue(IOSProviderEndpointPolicy.isValidBaseURL("http://203.0.113.10:8080/v1"))
        XCTAssertTrue(IOSProviderEndpointPolicy.isValidBaseURL("http://[2001:db8::10]:8080/v1"))
        XCTAssertFalse(IOSProviderEndpointPolicy.isValidBaseURL("http://sub2api.example/v1"))
        XCTAssertFalse(IOSProviderEndpointPolicy.isValidBaseURL("203.0.113.10:8080/v1"))
    }

    private func makeCookie(name: String, value: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: ".grok.com",
            .path: "/",
            .name: name,
            .value: value,
            .secure: "TRUE",
        ])!
    }
}
