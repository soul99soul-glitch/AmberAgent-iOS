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

    private func makeStore() -> WatchLocalStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-status-" + UUID().uuidString + ".json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return WatchLocalStore(fileURL: url)
    }
}
