import UIKit
import WebKit
import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSMemoryPressureCoordinatorTests: IOSWebMountToolTestCase {
    func testWarningClearsColdMarkdownAndStreamingRunFinishesWithSameMessageID() async throws {
        typealias Fixtures = IOSChatForegroundFixtures
        let defaults = isolatedDefaults()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let chat = ChatViewModel(settingsStore: SettingsStore(userDefaults: defaults),
                                 sharedSettings: IOSSharedSettingsStore(userDefaults: defaults),
                                 autoGenerateResponses: false)
        chat.conversationStore = store
        let provider = IOSChatProgressStreamingProvider()
        chat.kernelTextProviderOverrideForTesting = provider
        let run = chat.currentRun
        let user = Fixtures.userMessage("continue through memory pressure")
        run.state.messages = [user]
        let slot = ChatAsyncTaskSlot(
            conversationId: run.state.conversationId, inputDigest: "memory-pressure",
            anchorUserMessageId: ChatMessageProjector.messageId(for: user), phoneControlUserInitiated: false,
            providerSetting: Fixtures.makeProviderSetting(), params: Fixtures.makeParams(toolNames: []),
            toolExposureBridge: nil, recipeCatalogSnapshot: nil, baselineMessages: [user]
        )
        let center = NotificationCenter()
        let coordinator = IOSMemoryPressureCoordinator(
            conversationStore: store, sessionStore: IOSWebMountSessionStore(),
            notificationCenter: center
        ) { chat.runRegistry.activeMarkdownMessageIDs }
        defer { withExtendedLifetime(coordinator) {} }
        _ = chat.startOrEnqueueTaskSlot(slot, in: run)
        defer { slot.host?.cancel() }
        try await waitUntil { provider.callCount == 1 }
        provider.emit(Fixtures.streamChunk(delta: Fixtures.assistantText("first")))
        try await waitUntil { run.state.messages.last?.toText() == "first" }
        let partial = try XCTUnwrap(run.state.messages.last)
        let liveID = ChatMessageProjector.messageId(for: partial)
        let liveKey = "\(liveID):text:0:block"
        let coldKey = "\(liveID)-other:text:0:block"
        typealias Cache = ChatStableStreamingMarkdownCacheTestSupport
        defer { Cache.reset() }
        Cache.storeIdentity(identity: liveKey, text: "first", animate: true)
        Cache.storeIdentity(identity: coldKey, text: "cold", animate: false)
        Cache.store(text: "first", animate: true)
        Cache.store(text: "cold", animate: false)
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await waitUntil { !Cache.hasCachedIdentity(identity: coldKey, text: "cold", animate: false) }
        XCTAssertTrue(Cache.hasCachedIdentity(identity: liveKey, text: "first", animate: true))
        XCTAssertTrue(Cache.hasCachedRenderable(text: "first", animate: true))
        XCTAssertFalse(Cache.hasCachedRenderable(text: "cold", animate: false))
        provider.emit(Fixtures.streamChunk(delta: Fixtures.assistantText(" second")))
        provider.finishRound()
        try await waitUntil { slot.isTerminal }
        XCTAssertEqual(run.state.messages.last?.toText(), "first second")
        XCTAssertEqual(run.state.messages.last.map(ChatMessageProjector.messageId(for:)), liveID)
    }

    func testWarningDropsBothDecodedImageCachesAndLeavesRetainedImagesUsable() async throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let url = "data:image/png;base64," + png.base64EncodedString()
        func images() async throws -> (UIImage, UIImage) {
            guard case .success(let dataImage) = await ChatDataImageLoadState.resolve(urlString: url) else {
                throw CocoaError(.coderReadCorrupt)
            }
            return (dataImage, try await ChatMediaImageLoader.shared.image(urlString: url, pixelLimit: 16))
        }

        let before = try await images()
        let hit = try await images()
        XCTAssertTrue(before.0 === hit.0 && before.1 === hit.1)
        let center = NotificationCenter()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let observer = IOSMemoryPressureCoordinator(
            conversationStore: IOSConversationStore(baseDirectory: directory),
            sessionStore: IOSWebMountSessionStore(), notificationCenter: center
        ) { [] }
        defer { withExtendedLifetime(observer) {} }
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        let deadline = Date().addingTimeInterval(5)
        var after = try await images()
        while (after.0 === before.0 || after.1 === before.1), Date() < deadline {
            await Task.yield()
            after = try await images()
        }
        XCTAssertFalse(after.0 === before.0)
        XCTAssertFalse(after.1 === before.1)
        XCTAssertEqual(after.0.size, before.0.size)
        XCTAssertEqual(after.1.size, before.1.size)
        XCTAssertNotNil(before.1.cgImage)
    }

    func testReclamationReleasesOnlyIdleWebViewsWhileAgentToolAwaitsResolution() async throws {
        let resolving = expectation(description: "Agent is awaiting host resolution")
        let resume = DispatchSemaphore(value: 0)
        let defaults = isolatedDefaults()
        let agent = IOSWebMountWKRuntime(sessionId: "active-tool")
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: defaults),
            settings: IOSWebMountSettings(userDefaults: defaults),
            runtime: agent,
            resolveHost: { _ in
                resolving.fulfill()
                _ = resume.wait(timeout: .now() + 10)
                return []
            }
        )
        let sessions = controller.sessionStore
        let idle = IOSWebMountWKRuntime(sessionId: "idle-tab")
        let user = IOSWebMountWKRuntime(sessionId: "user-tab")
        let idleID = try sessions.newSession(persistent: true, runtime: idle).id
        let userID = try sessions.newSession(runtime: user).id
        try sessions.acquireUserControl(sessionId: userID)
        let agentID = agent.snapshot.sessionId
        let agentView = try XCTUnwrap(agent.webView)
        let userView = try XCTUnwrap(user.webView)
        let idleView = try XCTUnwrap(idle.webView)
        idleView.loadHTMLString("<title>Initial title</title><p>Saved page</p>", baseURL: URL(string: "https://example.org"))
        try await waitUntil { idle.snapshot.status == .ready }
        _ = try await idleView.evaluateJavaScript("document.title = 'Idle fixture'")
        try await waitUntil { idleView.title == "Idle fixture" && !idleView.isLoading }
        let call = Task {
            await controller.execute(
                toolName: "wm_open",
                input: IOSWebMountController.json(["session_id": agentID, "url": "https://pressure.example.org/page"]),
                isUserInitiated: false,
                context: IOSWebMountExecutionContext(runId: "active-run", conversationId: "conversation"),
                allowUnlistedHosts: true
            )
        }
        await fulfillment(of: [resolving], timeout: 5)
        sessions.reclaimIdleWebViews()
        resume.signal()
        let result = try jsonObject(await call.value)
        XCTAssertEqual(result["error_code"] as? String, "dns_resolution_failed")
        XCTAssertTrue(agent.webView === agentView)
        XCTAssertTrue(user.webView === userView)
        XCTAssertNil(idle.webView)
        XCTAssertNil(idleView.navigationDelegate)
        let record = try XCTUnwrap(sessions.record(sessionId: idleID))
        XCTAssertTrue(record.needsReopen)
        XCTAssertTrue(record.persistentOptIn)
        XCTAssertEqual(record.title, "Idle fixture")
        let replacement = try XCTUnwrap(sessions.runtimeIfPresent(sessionId: idleID) as? IOSWebMountWKRuntime)
        XCTAssertFalse(replacement === idle)
        XCTAssertNil(replacement.reclaimablePageSnapshot)
        XCTAssertNotNil(sessions.reopen(sessionId: idleID))
        XCTAssertNotNil(replacement.webView)
        sessions.reclaimIdleWebViews()
        XCTAssertNil(agent.webView, "The failed tool released its pin")
        XCTAssertEqual(sessions.record(sessionId: agentID)?.needsReopen, false, "A blank tab never had a page to reopen")
        XCTAssertTrue(user.webView === userView)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if !condition() { throw CocoaError(.coderValueNotFound) }
    }
}
