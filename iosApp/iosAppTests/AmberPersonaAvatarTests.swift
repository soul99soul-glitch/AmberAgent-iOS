import XCTest
import SwiftUI
import UIKit
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class AmberPersonaAvatarTests: XCTestCase {

    private func makeSolidPortrait(
        color: UIColor,
        badgeText: String,
        size: CGSize = CGSize(width: 240, height: 240)
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            color.setFill()
            context.fill(rect)

            UIColor.white.withAlphaComponent(0.9).setStroke()
            let circlePath = UIBezierPath(ovalIn: rect.insetBy(dx: 18, dy: 18))
            circlePath.lineWidth = 6
            circlePath.stroke()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 46, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let textSize = (badgeText as NSString).size(withAttributes: attrs)
            let textOrigin = CGPoint(
                x: (size.width - textSize.width) * 0.5,
                y: (size.height - textSize.height) * 0.5
            )
            (badgeText as NSString).draw(at: textOrigin, withAttributes: attrs)
        }
    }

    func testTopBarAvatarEntrywiringAndHitRegion() throws {
        let chatViewSource = try String(
            contentsOfFile: "/Users/arquiel/.synara/worktrees/1a9b45202c92/iosApp/iosApp/ChatView.swift",
            encoding: .utf8
        )
        let topBarSource = try String(
            contentsOfFile: "/Users/arquiel/.synara/worktrees/1a9b45202c92/iosApp/iosApp/ChatTopBarView.swift",
            encoding: .utf8
        )
        XCTAssertTrue(chatViewSource.contains("isPresentingPersonaStudio"))
        XCTAssertTrue(chatViewSource.contains("AmberPersonaStudioSheet("))
        XCTAssertTrue(chatViewSource.contains("onAvatarTap: {"))
        XCTAssertTrue(topBarSource.contains("chat.topBar.personaAvatarButton"))

        var avatarTapCount = 0
        let topBar = ChatTopBarView(
            presentation: .idle(.conversationTitle("Amber 形象测试")),
            conversationID: "conv-avatar-test",
            hasMessages: true,
            isGenerating: false,
            notices: [],
            shelfHeight: 360,
            onBack: {},
            onIslandTap: { _ in },
            onCancel: {},
            onOpenConversation: { _ in true },
            onDismiss: { _ in },
            onNewConversation: {},
            loadPreview: { _ in nil },
            previewRevision: { _ in nil },
            onAvatarTap: { avatarTapCount += 1 }
        )
        topBar.onAvatarTap?()
        XCTAssertEqual(avatarTapCount, 1)
    }

    func testStaticUploadStagesPreviewBeforeConfirmAndPersistsAcrossRestartAndResets() throws {
        let suite = "AmberPersonaStaticTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let store = AmberPersonaStore(defaults: defaults, storageDirectory: tempDir)
        XCTAssertEqual(store.preset, .amberFox)
        XCTAssertNil(store.customAvatarImage)
        XCTAssertFalse(store.hasPendingPreview)

        let candidateImage = makeSolidPortrait(
            color: UIColor(red: 0.78, green: 0.36, blue: 0.16, alpha: 1.0),
            badgeText: "S1"
        )
        let candidateData = try XCTUnwrap(candidateImage.pngData())

        // 1. Selecting an image enters preview first — active preset & avatar remain untouched
        XCTAssertTrue(store.stageUploadedAvatarDataForPreview(candidateData))
        XCTAssertTrue(store.hasPendingPreview)
        XCTAssertEqual(store.pendingPreviewKind, .staticImage)
        XCTAssertNotNil(store.pendingPreviewImage)
        XCTAssertEqual(store.preset, .amberFox, "Active preset must not change before user confirms preview")
        XCTAssertNil(store.customAvatarImage, "Active avatar must remain nil before user confirms preview")

        // 2. Cancelling preview keeps original state untouched
        store.discardPendingPreview()
        XCTAssertFalse(store.hasPendingPreview)
        XCTAssertNil(store.pendingPreviewImage)
        XCTAssertEqual(store.preset, .amberFox)
        XCTAssertNil(store.customAvatarImage)

        // 3. Re-staging and confirming persists to disk and updates active avatar
        XCTAssertTrue(store.stageUploadedAvatarDataForPreview(candidateData))
        XCTAssertTrue(store.confirmPendingPreview())
        XCTAssertFalse(store.hasPendingPreview)
        XCTAssertEqual(store.preset, .customPortrait)
        XCTAssertNotNil(store.customAvatarImage)
        XCTAssertFalse(store.hasActiveMultiFrameAnimation)

        // 4. Reloading in a new store instance restores the confirmed static avatar
        let reloadedStore = AmberPersonaStore(defaults: defaults, storageDirectory: tempDir)
        XCTAssertEqual(reloadedStore.preset, .customPortrait)
        XCTAssertNotNil(reloadedStore.customAvatarImage)
        XCTAssertFalse(reloadedStore.hasActiveMultiFrameAnimation)

        // 5. Reset to default restores amberFox and removes custom portrait files
        reloadedStore.resetToDefault()
        XCTAssertEqual(reloadedStore.preset, .amberFox)
        XCTAssertNil(reloadedStore.customAvatarImage)
        XCTAssertFalse(reloadedStore.hasActiveMultiFrameAnimation)

        let afterResetStore = AmberPersonaStore(defaults: defaults, storageDirectory: tempDir)
        XCTAssertEqual(afterResetStore.preset, .amberFox)
        XCTAssertNil(afterResetStore.customAvatarImage)
    }

    func testMultiFrameAnimationAsyncGenerationPreviewConfirmPlaybackReduceMotionAndFailureRecovery() async throws {
        let suite = "AmberPersonaAnimTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let store = AmberPersonaStore(defaults: defaults, storageDirectory: tempDir)
        let baseAvatar = makeSolidPortrait(
            color: UIColor(red: 0.72, green: 0.34, blue: 0.15, alpha: 1.0),
            badgeText: "BASE"
        )
        store.saveCustomAvatar(baseAvatar)
        XCTAssertEqual(store.preset, .customPortrait)
        XCTAssertFalse(store.hasActiveMultiFrameAnimation)

        // 1. Honest unconfigured state when no provider is configured and no test override is set
        let unconfiguredSettings = IOSSharedSettingsStore(userDefaults: defaults)
        XCTAssertFalse(store.hasConfiguredImageGenerationProvider(sharedSettings: unconfiguredSettings))
        await store.generateAnimationFramesWithAI(sharedSettings: unconfiguredSettings, frameCount: 3)
        XCTAssertNotNil(store.lastGenerationError)
        XCTAssertFalse(store.hasPendingPreview)
        XCTAssertNotNil(store.customAvatarImage, "Existing static avatar must remain intact when unconfigured")

        // 2. Controlled async multi-frame generation while user continues chatting
        let frame1 = makeSolidPortrait(color: UIColor(red: 0.82, green: 0.38, blue: 0.16, alpha: 1.0), badgeText: "F1")
        let frame2 = makeSolidPortrait(color: UIColor(red: 0.76, green: 0.45, blue: 0.18, alpha: 1.0), badgeText: "F2")
        let frame3 = makeSolidPortrait(color: UIColor(red: 0.68, green: 0.32, blue: 0.22, alpha: 1.0), badgeText: "F3")

        var capturedSourceURL: String?
        store.frameGeneratorOverrideForTesting = { _, sourceURL, count in
            capturedSourceURL = sourceURL
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertEqual(count, 3)
            return [frame1, frame2, frame3]
        }

        let genTask = store.startGenerateAnimationFramesTask(sharedSettings: unconfiguredSettings, frameCount: 3)
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(store.isGeneratingAvatar, "Multi-frame generation should be running asynchronously")

        // Simulate user chatting while avatar generation is in flight
        let chatSettings = SettingsStore(userDefaults: defaults)
        let chatVM = ChatViewModel(settingsStore: chatSettings, sharedSettings: unconfiguredSettings)
        chatVM.inputText = "在生成头像微动画时继续正常输入聊天"
        XCTAssertEqual(chatVM.inputText, "在生成头像微动画时继续正常输入聊天")

        await genTask.value
        XCTAssertFalse(store.isGeneratingAvatar)
        XCTAssertNotNil(capturedSourceURL, "Multi-frame generator should receive the uploaded/current avatar data URL")
        XCTAssertEqual(store.pendingPreviewKind, .multiFrameAnimation)
        XCTAssertEqual(store.pendingPreviewAnimationFrames.count, 3)
        XCTAssertFalse(store.hasActiveMultiFrameAnimation, "Should wait in preview until user confirms")

        // 3. Confirming multi-frame preview activates discrete frame playback and persists across restart
        XCTAssertTrue(store.confirmPendingPreview())
        XCTAssertFalse(store.hasPendingPreview)
        XCTAssertTrue(store.hasActiveMultiFrameAnimation)
        XCTAssertEqual(store.customAnimationFrames.count, 3)

        let reloaded = AmberPersonaStore(defaults: defaults, storageDirectory: tempDir)
        XCTAssertEqual(reloaded.preset, .customPortrait)
        XCTAssertTrue(reloaded.hasActiveMultiFrameAnimation)
        XCTAssertEqual(reloaded.customAnimationFrames.count, 3)

        // 4. Verify discrete frame cycling vs Reduce Motion static frame 0
        let t0 = Date(timeIntervalSinceReferenceDate: 0.0)
        let t1 = Date(timeIntervalSinceReferenceDate: 0.56)
        let t2 = Date(timeIntervalSinceReferenceDate: 1.12)
        let t3 = Date(timeIntervalSinceReferenceDate: 1.68)

        XCTAssertEqual(AmberAgentPersonaMedallionView.activeFrameIndex(at: t0, frameCount: 3, frameIntervalMs: 550, reduceMotion: false), 0)
        XCTAssertEqual(AmberAgentPersonaMedallionView.activeFrameIndex(at: t1, frameCount: 3, frameIntervalMs: 550, reduceMotion: false), 1)
        XCTAssertEqual(AmberAgentPersonaMedallionView.activeFrameIndex(at: t2, frameCount: 3, frameIntervalMs: 550, reduceMotion: false), 2)
        XCTAssertEqual(AmberAgentPersonaMedallionView.activeFrameIndex(at: t3, frameCount: 3, frameIntervalMs: 550, reduceMotion: false), 1)

        for date in [t0, t1, t2, t3] {
            XCTAssertEqual(
                AmberAgentPersonaMedallionView.activeFrameIndex(at: date, frameCount: 3, frameIntervalMs: 550, reduceMotion: true),
                0,
                "When accessibilityReduceMotion is enabled, medallion must remain on frame 0 without cycling"
            )
        }

        // 5. Failed or cancelled subsequent generation preserves the active 3-frame avatar
        struct SimulatedGenError: LocalizedError {
            var errorDescription: String? { "模拟生图网络超时，已保留当前形象" }
        }
        store.frameGeneratorOverrideForTesting = { _, _, _ in
            throw SimulatedGenError()
        }
        await store.generateAnimationFramesWithAI(sharedSettings: unconfiguredSettings, frameCount: 3)
        XCTAssertEqual(store.lastGenerationError, "模拟生图网络超时，已保留当前形象")
        XCTAssertTrue(store.hasActiveMultiFrameAnimation)
        XCTAssertEqual(store.customAnimationFrames.count, 3)

        // 6. Switching back to a confirmed static image cleanly disables multi-frame animation (distinct states)
        XCTAssertTrue(store.stageUploadedAvatarForPreview(baseAvatar))
        XCTAssertTrue(store.confirmPendingPreview())
        XCTAssertFalse(store.hasActiveMultiFrameAnimation)
        XCTAssertEqual(store.customAnimationFrames.count, 0)
        XCTAssertNotNil(store.customAvatarImage)
    }

    func testCaptureAgentAvatarStudioAndPlaybackSnapshots() async throws {
        let suite = "AmberPersonaSnapshots.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let archiveDir = URL(
            fileURLWithPath: "/Users/arquiel/.synara/userdata/project-context/0f3f2134-3ef9-4137-8b75-6d1496ff94d1/library/snapshots/ios-agent-avatar",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        let store = AmberPersonaStore(defaults: defaults, storageDirectory: tempDir)
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        let staticImg = makeSolidPortrait(
            color: UIColor(red: 0.79, green: 0.37, blue: 0.15, alpha: 1.0),
            badgeText: "AMBER"
        )
        let animF1 = makeSolidPortrait(color: UIColor(red: 0.80, green: 0.37, blue: 0.15, alpha: 1.0), badgeText: "帧 1")
        let animF2 = makeSolidPortrait(color: UIColor(red: 0.74, green: 0.43, blue: 0.17, alpha: 1.0), badgeText: "帧 2")
        let animF3 = makeSolidPortrait(color: UIColor(red: 0.67, green: 0.33, blue: 0.20, alpha: 1.0), badgeText: "帧 3")

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.overrideUserInterfaceStyle = .light
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKey()
        }

        func snapshot<V: View>(_ view: V, fileName: String) async throws {
            window.rootViewController = UIHostingController(
                rootView: view
                    .environment(\.locale, Locale(identifier: "zh_Hans"))
            )
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(220))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let png = try XCTUnwrap(image.pngData())
            try png.write(to: archiveDir.appendingPathComponent(fileName), options: .atomic)
        }

        // Snapshot 1: Top bar with clickable agent avatar medallion
        try await snapshot(
            ZStack(alignment: .top) {
                AmberTheme.background.ignoresSafeArea()
                ChatTopBarView(
                    presentation: .idle(.conversationTitle("轻点顶部形象进入设定工坊")),
                    conversationID: "snap-conv",
                    hasMessages: true,
                    isGenerating: false,
                    notices: [],
                    shelfHeight: 420,
                    onBack: {},
                    onIslandTap: { _ in },
                    onCancel: {},
                    onOpenConversation: { _ in true },
                    onDismiss: { _ in },
                    onNewConversation: {},
                    loadPreview: { _ in nil },
                    previewRevision: { _ in nil },
                    onAvatarTap: {}
                )
            },
            fileName: "01-topbar-custom-avatar-entry.png"
        )

        // Snapshot 2: Static upload staged in preview confirmation card
        _ = store.stageUploadedAvatarForPreview(staticImg)
        try await snapshot(
            AmberPersonaStudioSheet(sharedSettings: sharedSettings, store: store),
            fileName: "02-persona-studio-static-preview.png"
        )

        // Snapshot 3: Multi-frame animation staged in preview confirmation card
        _ = store.stageAnimationFramesForPreview([animF1, animF2, animF3])
        try await snapshot(
            AmberPersonaStudioSheet(sharedSettings: sharedSettings, store: store),
            fileName: "03-persona-studio-multiframe-preview.png"
        )

        // Snapshot 4: Confirm multi-frame animation and render discrete frame strip proof
        _ = store.confirmPendingPreview()
        try await snapshot(
            VStack(spacing: 24) {
                Text("Amber 多帧微动画离散帧回放与动态减弱（Reduce Motion）验证")
                    .font(.headline)
                    .foregroundStyle(AmberTheme.foreground)
                HStack(spacing: 20) {
                    ForEach(0..<store.customAnimationFrames.count, id: \.self) { idx in
                        VStack(spacing: 8) {
                            Image(uiImage: store.customAnimationFrames[idx])
                                .resizable()
                                .scaledToFill()
                                .frame(width: 76, height: 76)
                                .clipShape(Circle())
                            Text("离散帧 #\(idx + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AmberTheme.foreground2)
                        }
                    }
                }
                AmberAgentPersonaMedallionView(
                    mood: .idle,
                    diameter: 96,
                    storeOverride: store,
                    reduceMotionOverride: true
                )
                Text("Reduce Motion 开启时固定停留在第 1 帧")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AmberTheme.background.ignoresSafeArea()),
            fileName: "04-medallion-multiframe-playback-frames.png"
        )

        for name in [
            "01-topbar-custom-avatar-entry.png",
            "02-persona-studio-static-preview.png",
            "03-persona-studio-multiframe-preview.png",
            "04-medallion-multiframe-playback-frames.png"
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: archiveDir.appendingPathComponent(name).path),
                "Expected archived snapshot \(name)"
            )
        }
    }

    func testProgressRowWaveShimmerTransitionAndFixedAvatarAnchorOnRealChatMount() async throws {
        // 1. Verify 3 varying-shade wave dots metrics & Reduce Motion degradation
        let m0 = ChatTaskProgressDot.waveMetrics(at: 0.25, dotIndex: 0, isLive: true, reduceMotion: false)
        let m1 = ChatTaskProgressDot.waveMetrics(at: 0.25, dotIndex: 1, isLive: true, reduceMotion: false)
        let m2 = ChatTaskProgressDot.waveMetrics(at: 0.25, dotIndex: 2, isLive: true, reduceMotion: false)
        XCTAssertNotEqual(m0.offsetY, m1.offsetY, "Wave dots must be phase-staggered")
        XCTAssertNotEqual(m1.offsetY, m2.offsetY, "Wave dots must be phase-staggered")
        XCTAssertNotEqual(m0.opacity, m2.opacity, "Wave dots must have distinct shade depths")

        for idx in 0..<3 {
            let reduced = ChatTaskProgressDot.waveMetrics(at: 0.65, dotIndex: idx, isLive: true, reduceMotion: true)
            XCTAssertEqual(reduced.offsetY, 0, accuracy: 0.001, "Reduce Motion must keep dots vertically static")
            XCTAssertEqual(reduced.opacity, ChatTaskProgressDot.baseShadeTiers[idx], accuracy: 0.001)
        }

        let s0 = ChatTaskProgressTextShimmer.shimmerNormalizedProgress(at: 0.30, period: 1.8)
        let s1 = ChatTaskProgressTextShimmer.shimmerNormalizedProgress(at: 0.90, period: 1.8)
        let s2 = ChatTaskProgressTextShimmer.shimmerNormalizedProgress(at: 1.50, period: 1.8)
        XCTAssertLessThan(s0, s1)
        XCTAssertLessThan(s1, s2)

        // 2. Mount real ChatView + ChatTopBarView pipeline and verify fixed avatar anchor + progress motion frames
        let suite = "AmberProgressMotionAndAnchor.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let archiveDir = URL(
            fileURLWithPath: "/Users/arquiel/.synara/userdata/project-context/0f3f2134-3ef9-4137-8b75-6d1496ff94d1/library/snapshots/ios-progress-motion-avatar-anchor",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        let conversations = IOSConversationStore(baseDirectory: tempDir, subagentConversationIDsProvider: { [] })
        await conversations.bootstrap()
        _ = await conversations.newConversation()

        let settings = SettingsStore(userDefaults: defaults)
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "测试服务商", apiKey: "sk-test-fixture", baseUrl: "https://example.invalid/v1",
            modelName: "Amber-4o", modelId: "gpt-4o"
        )
        let addedProvider = sharedSettings.addProvider(provider)
        if let chatModel = addedProvider.models.first(where: { $0.type == ModelType.chat }) {
            sharedSettings.setCurrentChatModelId(chatModel.id.toHexDashString())
        }
        let viewModel = ChatViewModel(settingsStore: settings, sharedSettings: sharedSettings)
        viewModel.conversationStore = conversations
        await viewModel.startNewConversation()

        let dao = IosDatabaseFactory.shared.createDatabase(
            atFilePath: tempDir.appendingPathComponent("runs.db").path
        ).agentRuntimeDao()
        let center = ConversationActivityCenter(conversationStore: conversations, dao: dao, startedAt: .distantPast)
        let tasks = IOSAdvancedTaskStore(userDefaults: defaults)
        let activityStore = IOSSubAgentActivityStore(
            tasks: tasks,
            defaults: defaults,
            launchedAt: Date(),
            loadRuns: { [] }
        )
        let router = RouterPath()

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.overrideUserInterfaceStyle = .light
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKey()
        }

        func captureWindow(_ fileName: String) async throws {
            try await Task.sleep(for: .milliseconds(520))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let png = try XCTUnwrap(image.pngData())
            try png.write(to: archiveDir.appendingPathComponent(fileName), options: .atomic)
        }

        // Mount real ChatView and step through live tool progress (tool_search -> web_search -> fetch_url -> settled)
        window.rootViewController = UIHostingController(
            rootView: NavigationStack {
                ChatView(
                    settingsStore: settings,
                    sharedSettings: sharedSettings,
                    viewModel: viewModel,
                    activityStore: activityStore
                )
            }
            .environment(center)
            .environment(conversations)
            .environment(router)
            .environment(\.locale, Locale(identifier: "zh_Hans"))
        )
        window.makeKeyAndVisible()

        let userMsg = UIMessage.companion.user(prompt: "https://atlasum.net/blog/cve-2026-98432-linux-ipv4-tcp-uaf 这咋办")
        let doneJSON = #"{"ok":true,"status":"completed"}"#
        func makeTool(_ id: String, _ name: String, result: String? = nil) -> UIMessagePart.Tool {
            UIMessagePart.Tool(
                toolCallId: id,
                toolName: name,
                input: "{}",
                output: result.map { [UIMessagePart.Text(text: $0, metadata: nil)] } ?? [],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
        }
        func makeAssistant(_ parts: [UIMessagePart], id: KotlinUuid = KotlinUuid.companion.random()) -> UIMessage {
            UIMessage(
                id: id,
                role: MessageRole.assistant,
                parts: parts,
                annotations: [],
                createdAt: chatNowLocalDateTime(),
                finishedAt: nil,
                modelId: nil,
                usage: nil,
                translation: nil
            )
        }

        let pendingSearchTool = makeTool("tc-1", "tool_search")
        let doneSearchTool = makeTool("tc-1", "tool_search", result: doneJSON)
        let pendingFetchTool = makeTool("tc-2", "scrape_web")
        let doneFetchTool = makeTool("tc-2", "scrape_web", result: doneJSON)
        let headMsgID = KotlinUuid.companion.random()

        // Allow ChatView collection view to complete initial mount before pushing live turn updates
        try await Task.sleep(for: .milliseconds(220))
        window.layoutIfNeeded()

        // Frame 1: Live "正在查找工具…" with 3 varying-shade wave dots + text shimmer
        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.runActivityRevision &+= 1
        viewModel.isLoading = true
        viewModel.messages = [userMsg, makeAssistant([pendingSearchTool], id: headMsgID)]
        viewModel.bumpMessageRevision(reason: .toolResultAppended)
        try await captureWindow("01-chat-progress-tool-search-wave.png")

        // Frame 2: Smooth transition in-place to "正在读取网页…" on the exact same progress line
        viewModel.messages = [userMsg, makeAssistant([doneSearchTool, pendingFetchTool], id: headMsgID)]
        viewModel.bumpMessageRevision(reason: .toolResultAppended)
        try await captureWindow("02-chat-progress-fetch-url-transition.png")

        // Frame 3: Deterministic multi-phase wave + shimmer strip (showing t=0.18s, t=0.62s, t=1.08s, and settled state)
        let activeSegment1 = ChatTaskStreamGrouping.turnSegment(
            for: ChatAssistantTurnProgress(
                id: "turn-demo",
                headMessageID: "msg-demo",
                messages: [makeAssistant([pendingSearchTool], id: headMsgID)],
                tools: [pendingSearchTool],
                anchorIDs: ["msg-demo:tc-1"],
                isLive: true,
                isComposingReply: false,
                signature: 1
            )
        )
        let activeSegment2 = ChatTaskStreamGrouping.turnSegment(
            for: ChatAssistantTurnProgress(
                id: "turn-demo",
                headMessageID: "msg-demo",
                messages: [makeAssistant([doneSearchTool, pendingFetchTool], id: headMsgID)],
                tools: [doneSearchTool, pendingFetchTool],
                anchorIDs: ["msg-demo:tc-1", "msg-demo:tc-2"],
                isLive: true,
                isComposingReply: false,
                signature: 2
            )
        )
        let settledSegment = ChatTaskStreamGrouping.turnSegment(
            for: ChatAssistantTurnProgress(
                id: "turn-demo",
                headMessageID: "msg-demo",
                messages: [makeAssistant([doneSearchTool, doneFetchTool], id: headMsgID)],
                tools: [doneSearchTool, doneFetchTool],
                anchorIDs: ["msg-demo:tc-1", "msg-demo:tc-2"],
                isLive: false,
                isComposingReply: false,
                signature: 3
            )
        )

        window.rootViewController = UIHostingController(
            rootView: VStack(alignment: .leading, spacing: 20) {
                Text("主对话单行进度：三点深浅波浪 + 文字扫光 + 文案衔接 + 结束收束")
                    .font(.headline)
                    .foregroundStyle(AmberTheme.foreground)

                VStack(alignment: .leading, spacing: 14) {
                    Text("相位 1 (t = 0.18s) · 正在查找工具…").font(.caption).foregroundStyle(AmberTheme.muted)
                    ChatTaskInlineCardView(segment: activeSegment1, onTapToolDetail: { _ in }, animationTimeOverride: 0.18)

                    Divider()
                    Text("相位 2 (t = 0.62s) · 扫光推进与波浪错峰").font(.caption).foregroundStyle(AmberTheme.muted)
                    ChatTaskInlineCardView(segment: activeSegment1, onTapToolDetail: { _ in }, animationTimeOverride: 0.62)

                    Divider()
                    Text("相位 3 (t = 1.08s) · 原位平滑衔接至「正在读取网页…」").font(.caption).foregroundStyle(AmberTheme.muted)
                    ChatTaskInlineCardView(segment: activeSegment2, onTapToolDetail: { _ in }, animationTimeOverride: 1.08)

                    Divider()
                    Text("完成收束 · 动画立即停止并收敛为静态单点摘要").font(.caption).foregroundStyle(AmberTheme.muted)
                    ChatTaskInlineCardView(segment: settledSegment, onTapToolDetail: { _ in })
                }
                .padding(18)
                .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AmberTheme.background.ignoresSafeArea())
            .environment(\.locale, Locale(identifier: "zh_Hans"))
        )
        try await captureWindow("03-progress-wave-shimmer-phases.png")

        // 3. Verify Top Avatar Visual Center & Tap Anchor Invariance across short/long text, states, and Dynamic Type
        var measuredAvatarFrames: [String: CGRect] = [:]
        var avatarTapCount = 0

        let statesToVerify: [(label: String, presentation: ChatIslandPresentation, dynamicType: DynamicTypeSize)] = [
            ("short_title", .idle(.conversationTitle("新对话")), .large),
            ("long_tool", .active(.activity(kind: .tool, title: "正在搜索：Linux IPv4 TCP UAF 漏洞补丁与分析", systemImage: "magnifyingglass", tint: .amber)), .large),
            ("generating", .active(.activity(kind: .generating, title: "正在生成回复", systemImage: "text.bubble", tint: .amber)), .large),
            ("awaiting_user", .active(.activity(kind: .awaitingUser, title: "等待确认工具审批", systemImage: "checkmark.circle", tint: .amber)), .accessibility1)
        ]

        for item in statesToVerify {
            var latestRect: CGRect = .null
            let topBar = ChatTopBarView(
                presentation: item.presentation,
                conversationID: "anchor-test",
                hasMessages: true,
                isGenerating: item.presentation.displayedState.isActive,
                notices: [],
                shelfHeight: 360,
                onBack: {},
                onIslandTap: { _ in },
                onCancel: {},
                onOpenConversation: { _ in true },
                onDismiss: { _ in },
                onNewConversation: {},
                loadPreview: { _ in nil },
                previewRevision: { _ in nil },
                onAvatarTap: { avatarTapCount += 1 },
                onAvatarFrameChange: { rect in latestRect = rect }
            )
            window.rootViewController = UIHostingController(
                rootView: ZStack(alignment: .top) {
                    AmberTheme.background.ignoresSafeArea()
                    topBar
                }
                .environment(\.locale, Locale(identifier: "zh_Hans"))
                .environment(\.dynamicTypeSize, item.dynamicType)
            )
            try await Task.sleep(for: .milliseconds(160))
            window.layoutIfNeeded()
            XCTAssertFalse(latestRect.isNull, "Expected valid avatar frame for \(item.label)")
            measuredAvatarFrames[item.label] = latestRect
            topBar.onAvatarTap?()
        }

        XCTAssertEqual(avatarTapCount, statesToVerify.count)
        let baselineRect = try XCTUnwrap(measuredAvatarFrames["short_title"])
        for (label, rect) in measuredAvatarFrames {
            XCTAssertEqual(rect.midX, baselineRect.midX, accuracy: 0.05, "Avatar center X must remain fixed for \(label)")
            XCTAssertEqual(rect.midY, baselineRect.midY, accuracy: 0.05, "Avatar center Y must remain fixed for \(label)")
            XCTAssertEqual(rect.width, ChatTopBarLayout.avatarDiameter, accuracy: 0.05)
            XCTAssertEqual(rect.height, ChatTopBarLayout.avatarDiameter, accuracy: 0.05)
        }

        // Capture visual comparison sheet proving fixed avatar center X/Y across short and long status capsules
        window.rootViewController = UIHostingController(
            rootView: VStack(spacing: 18) {
                Text("顶部伪灵动岛宽度伸缩时：形象中心与点击锚点恒定不变")
                    .font(.headline)
                    .foregroundStyle(AmberTheme.foreground)

                ForEach(Array(statesToVerify.enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 4) {
                        Text("\(item.label) · 形象中心 (\(Int(baselineRect.midX)), \(Int(baselineRect.midY)))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(AmberTheme.muted)
                        ChatTopBarView(
                            presentation: item.presentation,
                            conversationID: "anchor-snap",
                            hasMessages: true,
                            isGenerating: item.presentation.displayedState.isActive,
                            notices: [],
                            shelfHeight: 300,
                            onBack: {},
                            onIslandTap: { _ in },
                            onCancel: {},
                            onOpenConversation: { _ in true },
                            onDismiss: { _ in },
                            onNewConversation: {},
                            loadPreview: { _ in nil },
                            previewRevision: { _ in nil },
                            onAvatarTap: {}
                        )
                        .frame(height: ChatTopBarLayout.controlsHeight + 4)
                    }
                }
            }
            .padding(.top, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(AmberTheme.background.ignoresSafeArea())
            .environment(\.locale, Locale(identifier: "zh_Hans"))
        )
        try await captureWindow("04-top-avatar-fixed-anchor-across-widths.png")
    }

    func testChatFontScaleWiringAndForegroundAvatarLayering() async throws {
        // 1. Verify canonical typography constants and heading/code scaling
        XCTAssertEqual(IOSChatFont.defaultBodyPointSize, 16.0, accuracy: 0.01)
        let defaultHeading = ChatStreamingMarkdownTypography.applyingChatFont(
            .default,
            to: .init(
                h1Font: ChatStreamingMarkdownTypography.bodyFonts(chatFont: .default, pointSize: 16),
                h2Font: ChatStreamingMarkdownTypography.bodyFonts(chatFont: .default, pointSize: 16),
                h3Font: ChatStreamingMarkdownTypography.bodyFonts(chatFont: .default, pointSize: 16),
                h4Font: ChatStreamingMarkdownTypography.bodyFonts(chatFont: .default, pointSize: 16),
                h5Font: ChatStreamingMarkdownTypography.bodyFonts(chatFont: .default, pointSize: 16),
                h6Font: ChatStreamingMarkdownTypography.bodyFonts(chatFont: .default, pointSize: 16),
                textColor: .label
            ),
            pointSize: 16.0
        )
        let scaledHeading = ChatStreamingMarkdownTypography.applyingChatFont(
            .default,
            to: defaultHeading,
            pointSize: 16.0 * 1.22
        )
        XCTAssertGreaterThan(scaledHeading.h2Font.normal.pointSize, defaultHeading.h2Font.normal.pointSize + 2.5)
        XCTAssertGreaterThan(
            ChatStreamingMarkdownTypography.inlineCodeFont(pointSize: 16.0 * 1.22).pointSize,
            ChatStreamingMarkdownTypography.inlineCodeFont(pointSize: 16.0).pointSize + 2.0
        )

        // 2. Verify top bar geometry and foreground avatar layering (avatar bottom overlaps capsule top without being occluded)
        XCTAssertEqual(ChatTopBarLayout.avatarDiameter, 76)
        XCTAssertEqual(ChatTopBarLayout.islandTopOffset, 8)
        XCTAssertEqual(ChatTopBarLayout.avatarCapsuleOverlap, 8)
        XCTAssertEqual(ChatTopBarLayout.islandCapsuleTopOffset, 68)
        XCTAssertEqual(ChatTopBarLayout.controlsHeight, 108)

        let archiveDir = URL(
            fileURLWithPath: "/Users/arquiel/.synara/userdata/project-context/0f3f2134-3ef9-4137-8b75-6d1496ff94d1/library/snapshots/ios-font-scale-avatar-foreground",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        let suite = "AmberFontAndAvatarForeground.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let standardDefaults = UserDefaults.standard
        let originalScale = standardDefaults.object(forKey: IOSDisplayPreferenceKeys.fontScale)
        let originalFont = standardDefaults.object(forKey: IOSDisplayPreferenceKeys.chatFont)
        defer {
            if let originalScale {
                standardDefaults.set(originalScale, forKey: IOSDisplayPreferenceKeys.fontScale)
            } else {
                standardDefaults.removeObject(forKey: IOSDisplayPreferenceKeys.fontScale)
            }
            if let originalFont {
                standardDefaults.set(originalFont, forKey: IOSDisplayPreferenceKeys.chatFont)
            } else {
                standardDefaults.removeObject(forKey: IOSDisplayPreferenceKeys.chatFont)
            }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Prepare a distinctive custom portrait with a bright crimson collar at the bottom edge
        // so we can both visually and programmatically verify the bottom edge is in front of the capsule
        let portraitImage = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240)).image { ctx in
            let rect = CGRect(x: 0, y: 0, width: 240, height: 240)
            UIColor(red: 0.95, green: 0.89, blue: 0.80, alpha: 1.0).setFill()
            ctx.fill(rect)
            // Hat brim & warm portrait silhouette
            UIColor(red: 0.58, green: 0.36, blue: 0.22, alpha: 1.0).setFill()
            UIBezierPath(ovalIn: CGRect(x: 28, y: 18, width: 184, height: 96)).fill()
            // Face
            UIColor(red: 0.98, green: 0.88, blue: 0.78, alpha: 1.0).setFill()
            UIBezierPath(ovalIn: CGRect(x: 68, y: 60, width: 104, height: 112)).fill()
            // Eyes
            UIColor(red: 0.22, green: 0.16, blue: 0.14, alpha: 1.0).setFill()
            UIBezierPath(ovalIn: CGRect(x: 92, y: 108, width: 12, height: 14)).fill()
            UIBezierPath(ovalIn: CGRect(x: 136, y: 108, width: 12, height: 14)).fill()
            // Crimson robe/collar at the bottom (y = 168..240) — matches Muse's red collar overlap zone
            UIColor(red: 0.86, green: 0.18, blue: 0.16, alpha: 1.0).setFill()
            UIBezierPath(roundedRect: CGRect(x: 42, y: 168, width: 156, height: 72), cornerRadius: 28).fill()
        }
        AmberPersonaStore.shared.saveCustomAvatar(portraitImage)
        defer {
            AmberPersonaStore.shared.resetToDefault()
        }

        let conversations = IOSConversationStore(baseDirectory: tempDir, subagentConversationIDsProvider: { [] })
        await conversations.bootstrap()
        _ = await conversations.newConversation()
        if let cid = conversations.currentConversation?.id {
            await conversations.renameConversation(id: cid, title: "清晨问候")
        }

        let settings = SettingsStore(userDefaults: defaults)
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "测试服务商", apiKey: "sk-test-fixture", baseUrl: "https://example.invalid/v1",
            modelName: "Amber-4o", modelId: "gpt-4o"
        )
        let addedProvider = sharedSettings.addProvider(provider)
        if let chatModel = addedProvider.models.first(where: { $0.type == ModelType.chat }) {
            sharedSettings.setCurrentChatModelId(chatModel.id.toHexDashString())
        }
        let viewModel = ChatViewModel(settingsStore: settings, sharedSettings: sharedSettings)
        viewModel.conversationStore = conversations
        await viewModel.startNewConversation()
        if let cid = conversations.currentConversation?.id {
            await conversations.renameConversation(id: cid, title: "清晨问候")
        }

        let userMsg1 = UIMessage.companion.user(prompt: "早")
        let asstMsg1 = UIMessage.companion.assistant(
            prompt: "早。昨晚睡得还行吗？今天上午准备先处理哪件事？"
        )
        let userMsg2 = UIMessage.companion.user(prompt: "买了盒马的大包子")
        let asstMsg2 = UIMessage.companion.assistant(
            prompt: """
            这个点吃包子挺合适，热乎又顶饱。盒马有几款大包确实做得不错，像香菇菜包、酱肉包或者流沙包都挺受欢迎。

            ### 早餐搭配建议
            - **咸口大包**：配一杯温豆浆、纯牛奶或清爽的绿茶，解腻又舒服。
            - **甜口流沙/豆沙包**：搭一杯美式咖啡或无糖乌龙茶，刚好中和甜度。
            """
        )

        let dao = IosDatabaseFactory.shared.createDatabase(
            atFilePath: tempDir.appendingPathComponent("runs.db").path
        ).agentRuntimeDao()
        let center = ConversationActivityCenter(conversationStore: conversations, dao: dao, startedAt: .distantPast)
        let tasks = IOSAdvancedTaskStore(userDefaults: defaults)
        let activityStore = IOSSubAgentActivityStore(
            tasks: tasks,
            defaults: defaults,
            launchedAt: Date(),
            loadRuns: { [] }
        )
        let router = RouterPath()

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.overrideUserInterfaceStyle = .light
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKey()
        }

        func capture(_ fileName: String) async throws -> UIImage {
            try await Task.sleep(for: .milliseconds(520))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let png = try XCTUnwrap(image.pngData())
            try png.write(to: archiveDir.appendingPathComponent(fileName), options: .atomic)
            return image
        }

        func measureViewHeight<V: View>(_ view: V, width: CGFloat = 340) -> CGFloat {
            let hosting = UIHostingController(rootView: view.frame(width: width))
            let size = hosting.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
            return size.height
        }

        // Measure user bubble & markdown heights at 100% (1.0) vs 122% (1.22)
        standardDefaults.set(1.0, forKey: IOSDisplayPreferenceKeys.fontScale)
        standardDefaults.set(IOSChatFont.default.rawValue, forKey: IOSDisplayPreferenceKeys.chatFont)
        let userHeight100 = measureViewHeight(ChatUserBubble(text: "买了盒马的大包子，今天早上配一杯热豆浆刚刚好"))
        let mdHeight100 = measureViewHeight(AmberMarkdownView(markdown: """
        这个点吃包子挺合适，热乎又顶饱。

        ### 早餐搭配建议
        - **咸口大包**：配一杯温豆浆、纯牛奶或清爽的绿茶，解腻又舒服。
        - **甜口流沙包**：搭一杯美式咖啡或无糖乌龙茶，刚好中和甜度。
        """))

        // Mount real ChatView at 100% default font scale
        window.rootViewController = UIHostingController(
            rootView: NavigationStack {
                ChatView(
                    settingsStore: settings,
                    sharedSettings: sharedSettings,
                    viewModel: viewModel,
                    activityStore: activityStore
                )
            }
            .environment(center)
            .environment(conversations)
            .environment(router)
            .environment(\.locale, Locale(identifier: "zh_Hans"))
        )
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(220))
        viewModel.messages = [userMsg1, asstMsg1, userMsg2, asstMsg2]
        viewModel.bumpMessageRevision(reason: .conversationSwitch)
        _ = try await capture("01-chat-font-scale-default-100.png")

        // Switch fontScale to 1.22 (122%) while ChatView is mounted — must immediately update without recreating ChatView!
        standardDefaults.set(1.22, forKey: IOSDisplayPreferenceKeys.fontScale)
        let userHeight122 = measureViewHeight(ChatUserBubble(text: "买了盒马的大包子，今天早上配一杯热豆浆刚刚好"))
        let mdHeight122 = measureViewHeight(AmberMarkdownView(markdown: """
        这个点吃包子挺合适，热乎又顶饱。

        ### 早餐搭配建议
        - **咸口大包**：配一杯温豆浆、纯牛奶或清爽的绿茶，解腻又舒服。
        - **甜口流沙包**：搭一杯美式咖啡或无糖乌龙茶，刚好中和甜度。
        """))
        XCTAssertGreaterThan(userHeight122, userHeight100 + 4.0, "User bubble must scale up with fontScale")
        XCTAssertGreaterThan(mdHeight122, mdHeight100 + 18.0, "Assistant Markdown (paragraph + heading + bullet list) must scale up with fontScale")

        _ = try await capture("02-chat-font-scale-large-122.png")

        // Capture DisplayFontSettingsView at 122% showing matching preview card
        window.rootViewController = UIHostingController(
            rootView: NavigationStack {
                DisplayFontSettingsView(sharedSettings: sharedSettings)
            }
            .environment(\.locale, Locale(identifier: "zh_Hans"))
        )
        _ = try await capture("03-display-font-settings-122.png")

        // Capture close-up proof of foreground avatar overlapping the top of the status capsule across states
        window.rootViewController = UIHostingController(
            rootView: VStack(spacing: 28) {
                Text("顶部形象放大下移 + 前景轻侵入标题岛（不遮挡帽檐与领口）")
                    .font(.headline)
                    .foregroundStyle(AmberTheme.foreground)

                ChatTopBarView(
                    presentation: .idle(.conversationTitle("清晨问候")),
                    conversationID: "fg-1",
                    hasMessages: true,
                    isGenerating: false,
                    notices: [],
                    shelfHeight: 300,
                    onBack: {},
                    onIslandTap: { _ in },
                    onCancel: {},
                    onOpenConversation: { _ in true },
                    onDismiss: { _ in },
                    onNewConversation: {},
                    loadPreview: { _ in nil },
                    previewRevision: { _ in nil },
                    onAvatarTap: {}
                )
                .frame(height: ChatTopBarLayout.controlsHeight + 6)

                ChatTopBarView(
                    presentation: .active(.activity(kind: .tool, title: "正在读取网页：早安营养搭配指南", systemImage: "globe", tint: .amber)),
                    conversationID: "fg-2",
                    hasMessages: true,
                    isGenerating: true,
                    notices: [],
                    shelfHeight: 300,
                    onBack: {},
                    onIslandTap: { _ in },
                    onCancel: {},
                    onOpenConversation: { _ in true },
                    onDismiss: { _ in },
                    onNewConversation: {},
                    loadPreview: { _ in nil },
                    previewRevision: { _ in nil },
                    onAvatarTap: {}
                )
                .frame(height: ChatTopBarLayout.controlsHeight + 6)
            }
            .padding(.top, 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(AmberTheme.background.ignoresSafeArea())
            .environment(\.locale, Locale(identifier: "zh_Hans"))
        )
        _ = try await capture("04-top-avatar-foreground-overlap-comparison.png")
    }
}
