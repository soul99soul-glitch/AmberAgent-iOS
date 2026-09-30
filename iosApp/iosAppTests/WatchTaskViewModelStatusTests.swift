import XCTest
@testable import iosApp

private final class WatchViewModelStatusTransport: WatchConnectivityTransporting {
    var isSupported = true
    var isPaired = true
    var isWatchAppInstalled = true
    var isReachable: Bool
    var actions: [WatchTaskActionRequest] = []

    init(isReachable: Bool) {
        self.isReachable = isReachable
    }

    func activate() {}

    func updateApplicationContext(_ context: [String: Any]) throws {}

    func transferUserInfo(_ userInfo: [String: Any]) -> String { "transfer" }

    func sendMessage(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?,
        errorHandler: ((Error) -> Void)?
    ) {
        guard let data = message[WatchConnectivityPayloadKey.action] as? Data,
              let request = try? WatchTaskCodec.decodeAction(data) else { return }
        actions.append(request)
    }
}

@MainActor
final class WatchTaskViewModelStatusTests: XCTestCase {
    func testReachabilityRecoveryClearsOnlyConnectionStatus() {
        let transport = WatchViewModelStatusTransport(isReachable: false)
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000)
        bridge.configure(transport: transport)
        let model = WatchTaskViewModel(bridge: bridge, store: makeStore())

        model.start()
        XCTAssertFalse(model.isPhoneReachable)
        XCTAssertEqual(model.connectionPresentation, .offline)
        XCTAssertEqual(model.statusMessage, "无法连接 iPhone，请稍后重试")

        transport.isReachable = true
        bridge.onReachabilityChanged?(true)

        XCTAssertTrue(model.isPhoneReachable)
        XCTAssertNil(model.statusMessage)
    }

    func testSnapshotArrivalClearsStaleConnectionStatus() {
        let transport = WatchViewModelStatusTransport(isReachable: false)
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000)
        bridge.configure(transport: transport)
        let model = WatchTaskViewModel(bridge: bridge, store: makeStore())

        model.start()
        transport.isReachable = true
        bridge.onSnapshotUpdated?(bridge.latestSnapshot)

        XCTAssertTrue(model.isPhoneReachable)
        XCTAssertNil(model.statusMessage)
    }

    func testRefreshTimeoutWhilePhoneRemainsReachableUsesSyncStatus() async {
        let transport = WatchViewModelStatusTransport(isReachable: true)
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000)
        bridge.configure(transport: transport)
        let model = WatchTaskViewModel(
            bridge: bridge,
            store: makeStore(),
            refreshTimeoutNanoseconds: 10_000_000
        )

        model.start()
        XCTAssertEqual(model.connectionPresentation, .waitingForPhone)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(model.isPhoneReachable)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.connectionPresentation, .connected)
        XCTAssertEqual(model.statusMessage, "本次同步未完成，请重试")
    }

    func testLateConnectionErrorAfterSuccessfulSnapshotDoesNotRestoreOldError() {
        let transport = WatchViewModelStatusTransport(isReachable: false)
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000)
        bridge.configure(transport: transport)
        let model = WatchTaskViewModel(bridge: bridge, store: makeStore())

        model.start()
        XCTAssertEqual(model.statusMessage, "无法连接 iPhone，请稍后重试")

        transport.isReachable = true
        bridge.onSnapshotUpdated?(bridge.latestSnapshot)
        XCTAssertEqual(model.connectionPresentation, .connected)
        XCTAssertNil(model.statusMessage)

        bridge.onConnectionError?("无法连接 iPhone，请稍后重试")

        XCTAssertTrue(model.isPhoneReachable)
        XCTAssertEqual(model.connectionPresentation, .connected)
        XCTAssertNil(model.statusMessage)
    }

    func testReconnectDoesNotReplaceUnknownActionPromptWithConnectionError() throws {
        let transport = WatchViewModelStatusTransport(isReachable: true)
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000_000)
        bridge.configure(transport: transport)
        var ready = WatchTaskSnapshot.idle
        ready.library = WatchLibrarySnapshot(
            assistantName: "Amber", isConfigured: true, quickActions: [], recent: [], updatedAt: Date()
        )
        bridge.publish(ready)
        let model = WatchTaskViewModel(bridge: bridge, store: makeStore())

        model.start()
        bridge.onSnapshotUpdated?(bridge.latestSnapshot)
        model.compose(mode: .ask)
        model.store.updateDraftText(key: "ask", text: "保留这个问题")
        model.submitDraft(key: "ask")
        let request = try XCTUnwrap(transport.actions.first)
        bridge.onActionResult?(WatchTaskActionResult(
            requestId: request.requestId,
            runId: "",
            accepted: false,
            message: "正在确认是否已接收",
            snapshot: nil,
            deliveryUnknown: true
        ))
        XCTAssertEqual(model.statusMessage, "正在确认是否已接收")

        bridge.onConnectionError?("无法连接 iPhone，请稍后重试")
        XCTAssertEqual(model.statusMessage, "正在确认是否已接收")

        transport.isReachable = false
        bridge.onReachabilityChanged?(false)
        transport.isReachable = true
        bridge.onReachabilityChanged?(true)
        XCTAssertEqual(model.statusMessage, "正在确认是否已接收")
    }

    func testAccentPaletteFollowsPhoneUntilTurnedOff() {
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000_000)
        bridge.configure(transport: WatchViewModelStatusTransport(isReachable: true))
        var older = WatchTaskSnapshot.idle
        older.library = WatchLibrarySnapshot(
            assistantName: "Amber", isConfigured: true, quickActions: [], recent: [], updatedAt: Date()
        )
        bridge.publish(older)
        let model = WatchTaskViewModel(bridge: bridge, store: makeStore())
        model.start()
        bridge.onSnapshotUpdated?(bridge.latestSnapshot)
        XCTAssertEqual(model.accentPalette, .copper, "phones without accent keep copper")

        var themed = older
        themed.library?.accentHex = 0x4F86D6
        themed.updatedAt = Date().addingTimeInterval(1)
        bridge.publish(themed)
        bridge.onSnapshotUpdated?(bridge.latestSnapshot)
        XCTAssertEqual(model.accentPalette, WatchAccentPalette(hex: 0x4F86D6))
        XCTAssertNotEqual(model.accentPalette, .copper)

        model.store.updateSettings { $0.followsPhoneAccent = false }
        XCTAssertEqual(model.accentPalette, .copper)
    }

    func testDerivedAccentStaysLegibleOnBlackAndKeepsHue() {
        // Phone "ink" accent is near-black; on the Watch it must still read.
        let ink = WatchAccentPalette(hex: 0x222226)
        XCTAssertGreaterThanOrEqual(maxChannel(ink.accent), WatchAccentPalette.minimumAccentBrightness - 0.001)

        // Sage keeps green dominant for every role, including the dark card.
        let sage = WatchAccentPalette(hex: 0x5E9C6E)
        for color in [sage.accent, sage.cardAccent] + sage.cardGradient {
            XCTAssertGreaterThan(color.green, color.red)
            XCTAssertGreaterThan(color.green, color.blue)
        }
        XCTAssertLessThan(maxChannel(sage.cardGradient[0]), 0.3, "card stays a dark ground for ivory text")

        // A pale accent flips the ask button label to dark text.
        XCTAssertEqual(WatchAccentPalette(hex: 0xF2E3A0).onAccent, .init(red: 0, green: 0, blue: 0))
        XCTAssertEqual(WatchAccentPalette(hex: 0xB8623A).onAccent, .init(red: 1, green: 1, blue: 1))
    }

    func testPhaseHapticsAreDistinctAndIndividuallySilenced() {
        var settings = WatchLocalStore.Settings()
        XCTAssertEqual(WatchTaskViewModel.phaseFeedback(for: "completed", settings: settings), .success)
        XCTAssertEqual(WatchTaskViewModel.phaseFeedback(for: "waitingForUser", settings: settings), .notification)
        XCTAssertEqual(WatchTaskViewModel.phaseFeedback(for: "failed", settings: settings), .failure)
        XCTAssertNil(WatchTaskViewModel.phaseFeedback(for: "running", settings: settings))

        settings.hapticsOnCompleted = false
        XCTAssertNil(WatchTaskViewModel.phaseFeedback(for: "completed", settings: settings))
        XCTAssertEqual(WatchTaskViewModel.phaseFeedback(for: "failed", settings: settings), .failure)
    }

    func testSmartStackRelevanceFollowsRealPhase() {
        let now = Date()
        var snapshot = WatchTaskSnapshot.idle
        XCTAssertEqual(WatchWidgetRelevance.score(for: snapshot, now: now).score, 0)

        snapshot.runId = "run"
        snapshot.updatedAt = now
        snapshot.phase = "waitingForUser"
        let waiting = WatchWidgetRelevance.score(for: snapshot, now: now).score
        snapshot.phase = "running"
        let running = WatchWidgetRelevance.score(for: snapshot, now: now).score
        XCTAssertGreaterThan(waiting, running)
        XCTAssertGreaterThan(running, 0)

        snapshot.isStale = true
        XCTAssertEqual(WatchWidgetRelevance.score(for: snapshot, now: now).score, 0, "expired state never ranks")
        snapshot.isStale = false
        XCTAssertEqual(WatchWidgetRelevance.score(for: snapshot, now: now.addingTimeInterval(61)).score, 0,
                       "an unconfirmed live state stops ranking when the widget shows it expired")
        snapshot.isStale = true

        snapshot.isStale = false
        snapshot.phase = "completed"
        let fresh = WatchWidgetRelevance.score(for: snapshot, now: now.addingTimeInterval(10 * 60))
        XCTAssertGreaterThan(fresh.score, 0)
        XCTAssertEqual(fresh.duration, 20 * 60, accuracy: 0.5)
        XCTAssertEqual(WatchWidgetRelevance.score(for: snapshot, now: now.addingTimeInterval(31 * 60)).score, 0)
    }

    func testWidgetAccentRoundTripsAndClearsToCopper() throws {
        let suite = "watch-widget-accent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(WatchWidgetCache.loadAccentHex(defaults: defaults))
        WatchWidgetCache.saveAccentHex(0x5E9C6E, defaults: defaults)
        XCTAssertEqual(WatchWidgetCache.loadAccentHex(defaults: defaults), 0x5E9C6E)
        WatchWidgetCache.saveAccentHex(nil, defaults: defaults)
        XCTAssertNil(WatchWidgetCache.loadAccentHex(defaults: defaults))
    }

    private func maxChannel(_ color: WatchAccentPalette.RGB) -> Double {
        max(color.red, color.green, color.blue)
    }

    private func makeStore() -> WatchLocalStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-status-" + UUID().uuidString + ".json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return WatchLocalStore(fileURL: url)
    }
}
