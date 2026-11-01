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
}
