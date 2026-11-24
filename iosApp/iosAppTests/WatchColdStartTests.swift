import Foundation
import XCTest
import Shared
@testable import iosApp

@MainActor
final class WatchColdStartTests: XCTestCase {
    private final class PairedTestTransport: WatchConnectivityTransporting {
        var isSupported = true
        var isSessionActivated: Bool
        var isPaired: Bool
        var isWatchAppInstalled: Bool
        var isReachable = false

        init(isSessionActivated: Bool = true, isPaired: Bool = true, isWatchAppInstalled: Bool = true) {
            self.isSessionActivated = isSessionActivated
            self.isPaired = isPaired
            self.isWatchAppInstalled = isWatchAppInstalled
        }

        func activate() {}
        func updateApplicationContext(_ context: [String: Any]) throws {}
        func transferUserInfo(_ userInfo: [String: Any]) -> String { "transfer" }
        func sendMessage(
            _ message: [String: Any],
            replyHandler: (([String: Any]) -> Void)?,
            errorHandler: ((Error) -> Void)?
        ) {}
    }

    private struct Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let sharedSettings: IOSSharedSettingsStore
        let conversationStore: IOSConversationStore
        let chatViewModel: ChatViewModel
        let conversationId: String
    }

    private enum FixtureError: Error {
        case unableToCreateConversation
        case missingConversationID
        case unableToPersistConversation
        case unableToCreateDefaults
    }

    func testOlderRefreshCannotOverwriteNewerLibraryWhenItFinishesLast() async throws {
        let fixture = try await makeFixture()
        defer { tearDown(fixture) }
        func library(_ version: String) -> WatchLibrarySnapshot {
            WatchLibrarySnapshot(assistantName: version, isConfigured: true,
                quickActions: [WatchQuickAction(id: version, title: version, prompt: version)],
                recent: [WatchRecentConversation(id: version, title: version, preview: version, updatedAt: Date())],
                activities: [WatchRecentActivity(id: version, kind: "response", phase: "completed",
                    title: version, summary: version, updatedAt: Date())], updatedAt: Date())
        }
        let initialReady = expectation(description: "initial attachment refreshed")
        let oldStarted = expectation(description: "old refresh suspended")
        let newStarted = expectation(description: "new refresh suspended")
        var suspend = false
        var pending: [CheckedContinuation<WatchLibrarySnapshot, Never>] = []
        let bridge = WatchConnectivityBridge()
        bridge.configure(transport: PairedTestTransport())
        let coordinator = WatchTaskCoordinator(
            bridge: bridge,
            companionService: IOSWatchCompanionService(baseDirectory: fixture.root.appendingPathComponent("watch"), defaults: fixture.defaults),
            deepLinkInbox: IOSDeepLinkInbox(defaults: fixture.defaults),
            librarySnapshotProvider: { _, _, _ in
                guard suspend else {
                    initialReady.fulfill()
                    return library("initial")
                }
                return await withCheckedContinuation { continuation in
                    pending.append(continuation)
                    if pending.count == 1 { oldStarted.fulfill() } else { newStarted.fulfill() }
                }
            }
        )
        coordinator.attach(chatViewModel: fixture.chatViewModel, sharedSettings: fixture.sharedSettings)
        await fulfillment(of: [initialReady], timeout: 5)
        suspend = true
        let oldRefresh = Task { await coordinator.refreshWatchSnapshot() }
        await fulfillment(of: [oldStarted], timeout: 5)
        let newRefresh = Task { await coordinator.refreshWatchSnapshot() }
        await fulfillment(of: [newStarted], timeout: 5)
        guard pending.count == 2 else {
            pending.forEach { $0.resume(returning: library("cleanup")) }
            return XCTFail("Both refreshes must suspend at the provider boundary")
        }
        pending[1].resume(returning: library("new"))
        await newRefresh.value
        let newestSequence = coordinator.currentSnapshot().sequence
        pending[0].resume(returning: library("old"))
        await oldRefresh.value

        let final = coordinator.currentSnapshot()
        XCTAssertEqual(final.library?.assistantName, "new")
        XCTAssertEqual(final.library?.quickActions.map(\.id), ["new"])
        XCTAssertEqual(final.library?.recent.map(\.id), ["new"])
        XCTAssertEqual(final.library?.activities?.map(\.id), ["new"])
        XCTAssertEqual(final.sequence, newestSequence, "A stale projection must not earn a fresh transport revision")
    }

    func testColdRefreshKeepsReconnectingProjectionAndHydratesRecentLibrary() async throws {
        let fixture = try await makeFixture()
        defer { tearDown(fixture) }

        let runId = "cold-refresh-run"
        let context = WatchTaskColdStartContext(
            chatViewModel: fixture.chatViewModel,
            sharedSettings: fixture.sharedSettings,
            reconnecting: [WatchTaskReconnectProjection(
                runId: runId,
                conversationId: fixture.conversationId,
                startedAt: 1_700_000_000_000
            )]
        )
        let coordinator = makeCoordinator(
            fixture: fixture,
            bridge: WatchConnectivityBridge(),
            coldStartPreparer: { context }
        )

        await coordinator.refreshWatchSnapshot(bypassCompanionGate: true)

        let snapshot = coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.runId, runId)
        XCTAssertEqual(snapshot.conversationId, fixture.conversationId)
        XCTAssertEqual(snapshot.phase, AgentActivityPhase.reconnecting.rawValue)
        XCTAssertEqual(snapshot.library?.recent.map(\.id), [fixture.conversationId])
        XCTAssertEqual(snapshot.library?.recent.first?.preview, "最近的回答")
    }

    func testColdOpenConversationPersistsDurableHandoffUntilRelaunch() async throws {
        let fixture = try await makeFixture()
        defer { tearDown(fixture) }

        let inbox = IOSDeepLinkInbox(defaults: fixture.defaults)
        let coordinator = makeCoordinator(
            fixture: fixture,
            bridge: WatchConnectivityBridge(),
            deepLinkInbox: inbox,
            coldStartPreparer: {
                WatchTaskColdStartContext(
                    chatViewModel: fixture.chatViewModel,
                    sharedSettings: fixture.sharedSettings
                )
            }
        )
        let request = WatchTaskActionRequest(
            requestId: UUID().uuidString,
            runId: "",
            conversationId: fixture.conversationId,
            decisionId: nil,
            action: .openConversation,
            optionId: nil,
            text: nil,
            createdAt: Date()
        )

        let result = await coordinator.handleWatchAction(request)

        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.conversationId, fixture.conversationId)

        // No AppShell handler was installed in the cold process. A newly
        // created inbox must still replay the durable URL after relaunch.
        let relaunchedInbox = IOSDeepLinkInbox(defaults: fixture.defaults)
        var handedOffURLs: [URL] = []
        relaunchedInbox.installHandler { handedOffURLs.append($0) }
        XCTAssertEqual(handedOffURLs.count, 1)
        XCTAssertEqual(
            handedOffURLs.first.flatMap { IOSAppDeepLink.parse($0) },
            .conversation(id: fixture.conversationId)
        )
    }

    func testColdRefreshDoesNotPublishIdleWhenAttachmentCannotBePrepared() async throws {
        let fixture = try await makeFixture()
        defer { tearDown(fixture) }

        let bridge = WatchConnectivityBridge()
        var existing = WatchTaskSnapshot.idle
        existing.runId = "still-active"
        existing.conversationId = fixture.conversationId
        existing.phase = AgentActivityPhase.reconnecting.rawValue
        existing.updatedAt = Date()
        bridge.publish(existing)
        let beforeRefresh = bridge.latestSnapshot

        let coordinator = makeCoordinator(
            fixture: fixture,
            bridge: bridge,
            coldStartPreparer: { nil },
            attachmentWaitNanoseconds: 1_000_000
        )

        await coordinator.refreshWatchSnapshot(bypassCompanionGate: true)

        XCTAssertEqual(coordinator.currentSnapshot(), beforeRefresh)
        XCTAssertEqual(coordinator.currentSnapshot().runId, "still-active")
        XCTAssertEqual(coordinator.currentSnapshot().phase, AgentActivityPhase.reconnecting.rawValue)
    }

    func testUnpairedCompanionGatesAutomaticRefreshWhileAllowingWatchInitiatedAndStateChangeRefresh() async throws {
        let fixture = try await makeFixture()
        defer { tearDown(fixture) }

        let transport = PairedTestTransport(isSessionActivated: true, isPaired: false, isWatchAppInstalled: false)
        let bridge = WatchConnectivityBridge()
        bridge.configure(transport: transport)
        XCTAssertFalse(bridge.hasInstalledWatchCompanion)

        var providerCalls = 0
        let coordinator = WatchTaskCoordinator(
            bridge: bridge,
            companionService: IOSWatchCompanionService(
                baseDirectory: fixture.root.appendingPathComponent("watch", isDirectory: true),
                defaults: fixture.defaults
            ),
            deepLinkInbox: IOSDeepLinkInbox(defaults: fixture.defaults),
            remoteStateDebounceNanoseconds: 20_000_000,
            librarySnapshotProvider: { _, _, _ in
                providerCalls += 1
                return WatchLibrarySnapshot(
                    assistantName: "Amber",
                    isConfigured: true,
                    quickActions: [],
                    recent: [],
                    updatedAt: Date()
                )
            }
        )

        coordinator.attach(chatViewModel: fixture.chatViewModel, sharedSettings: fixture.sharedSettings)
        await coordinator.refreshWatchSnapshot()
        coordinator.handleRemoteStateChanged()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(providerCalls, 0, "Unpaired devices must not load conversations for automatic Watch refreshes")

        // Watch-initiated `.refresh` action must bypass the companion gate.
        let refreshAction = WatchTaskActionRequest(
            requestId: UUID().uuidString,
            runId: "",
            conversationId: nil,
            decisionId: nil,
            action: .refresh,
            optionId: nil,
            text: nil,
            createdAt: Date()
        )
        let refreshResult = await coordinator.handleWatchAction(refreshAction)
        XCTAssertTrue(refreshResult.accepted)
        XCTAssertEqual(providerCalls, 1)

        // Newly paired & installed Watch triggers an initial snapshot refresh via state change.
        transport.isPaired = true
        transport.isWatchAppInstalled = true
        XCTAssertTrue(bridge.hasInstalledWatchCompanion)
        await bridge.handleWatchStateChanged()
        XCTAssertEqual(providerCalls, 2)
    }

    private func makeFixture() async throws -> Fixture {
        let suite = "WatchColdStartTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw FixtureError.unableToCreateDefaults
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let conversationStore = IOSConversationStore(
            baseDirectory: root.appendingPathComponent("conversations", isDirectory: true)
        )
        guard await conversationStore.newConversation() else {
            throw FixtureError.unableToCreateConversation
        }
        guard let conversationId = conversationStore.currentConversation?.id else {
            throw FixtureError.missingConversationID
        }
        guard await conversationStore.save(
            messages: [
                UIMessage.companion.user(prompt: "最近的问题"),
                UIMessage.companion.assistant(prompt: "最近的回答")
            ],
            to: conversationId
        ) else {
            throw FixtureError.unableToPersistConversation
        }

        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        let chatViewModel = ChatViewModel(
            settingsStore: SettingsStore(userDefaults: defaults),
            sharedSettings: sharedSettings,
            autoGenerateResponses: false
        )
        chatViewModel.conversationStore = conversationStore
        return Fixture(
            root: root,
            suite: suite,
            defaults: defaults,
            sharedSettings: sharedSettings,
            conversationStore: conversationStore,
            chatViewModel: chatViewModel,
            conversationId: conversationId.toHexDashString()
        )
    }

    private func makeCoordinator(
        fixture: Fixture,
        bridge: WatchConnectivityBridge,
        deepLinkInbox: IOSDeepLinkInbox? = nil,
        coldStartPreparer: @escaping WatchTaskColdStartPreparer,
        attachmentWaitNanoseconds: UInt64 = 1_000_000
    ) -> WatchTaskCoordinator {
        WatchTaskCoordinator(
            bridge: bridge,
            companionService: IOSWatchCompanionService(
                baseDirectory: fixture.root.appendingPathComponent("watch", isDirectory: true),
                defaults: fixture.defaults
            ),
            deepLinkInbox: deepLinkInbox ?? IOSDeepLinkInbox(defaults: fixture.defaults),
            coldStartPreparer: coldStartPreparer,
            attachmentWaitNanoseconds: attachmentWaitNanoseconds
        )
    }

    private func tearDown(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.root)
        fixture.defaults.removePersistentDomain(forName: fixture.suite)
    }
}
