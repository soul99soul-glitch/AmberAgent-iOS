import XCTest
@testable import iosApp

private final class WatchReliabilityTransport: WatchConnectivityTransporting {
    var isSupported = true
    var isPaired = true
    var isWatchAppInstalled = true
    var isReachable = true
    var isSessionActivated = true
    var response: [String: Any] = [:]
    var contextError: Error?
    var contextWrites = 0
    var queued: [[String: Any]] = []

    func activate() {}
    func updateApplicationContext(_ context: [String: Any]) throws {
        contextWrites += 1
        if let contextError { throw contextError }
    }
    func transferUserInfo(_ userInfo: [String: Any]) -> String {
        queued.append(userInfo)
        return String(queued.count)
    }
    func sendMessage(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?,
        errorHandler: ((Error) -> Void)?
    ) {
        replyHandler?(response)
    }
}

@MainActor
final class WatchTransportReliabilityTests: XCTestCase {
    func testOfflineTerminalResultKeepsItsKnownOutcome() {
        var snapshot = WatchTaskSnapshot.idle
        snapshot.runId = "completed-run"
        snapshot.phase = "completed"
        snapshot.updatedAt = Date(timeIntervalSince1970: 100)
        let presented = WatchSnapshotFreshnessPolicy.presented(
            snapshot, isPhoneReachable: false, now: Date(timeIntervalSince1970: 10_000)
        )
        XCTAssertEqual(presented.phase, "completed")
        XCTAssertFalse(presented.isStale)
    }

    func testWireRevisionKeepsSameSecondDecisionAndTerminalUpdatesOrdered() throws {
        var running = WatchTaskSnapshot.idle
        running.runId = "run"
        running.phase = "running"
        running.updatedAt = Date(timeIntervalSince1970: 100.1)
        running.sequence = 1
        var complete = running
        complete.phase = "completed"
        complete.updatedAt = Date(timeIntervalSince1970: 100.2)
        complete.sequence = 2
        let first = try WatchTaskCodec.decodeSnapshot(WatchTaskCodec.encodeSnapshot(running))
        let last = try WatchTaskCodec.decodeSnapshot(WatchTaskCodec.encodeSnapshot(complete))
        XCTAssertEqual(first.updatedAt, last.updatedAt)
        XCTAssertTrue(WatchSnapshotOrdering.accepts(last, after: first))
        XCTAssertFalse(WatchSnapshotOrdering.accepts(first, after: last))
        var conflicting = last
        conflicting.phase = "running"
        XCTAssertFalse(WatchSnapshotOrdering.accepts(conflicting, after: last))
    }

    func testFailedContextWriteCanBeRetriedAndOfflineSnapshotsAreNotQueued() {
        let transport = WatchReliabilityTransport()
        transport.isReachable = false
        transport.contextError = NSError(domain: "WatchTest", code: 1)
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000)
        bridge.configure(transport: transport)
        bridge.publish(.idle)
        XCTAssertEqual(transport.contextWrites, 1)
        transport.contextError = nil
        bridge.publish(bridge.latestSnapshot)
        XCTAssertEqual(transport.contextWrites, 2)
        bridge.publish(bridge.latestSnapshot)
        XCTAssertEqual(transport.contextWrites, 2)
        XCTAssertTrue(transport.queued.isEmpty)
    }

    func testOfflineQueueAcceptsOnlyNotesAndDeduplicatesPendingTransfers() {
        let transport = WatchReliabilityTransport()
        transport.isReachable = false
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000)
        bridge.configure(transport: transport)
        let note = request(.saveNote)
        bridge.sendNote(note)
        bridge.sendNote(note)
        bridge.sendNote(request(.cancel))
        bridge.sendAction(request(.ask))
        XCTAssertEqual(transport.queued.count, 1)
    }

    func testNoteDuringActivationReportsPendingInsteadOfClaimingDelivery() {
        let transport = WatchReliabilityTransport()
        transport.isSessionActivated = false
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000)
        bridge.configure(transport: transport)
        var result: WatchTaskActionResult?
        bridge.onActionResult = { result = $0 }
        let note = request(.saveNote)
        bridge.sendNote(note)
        XCTAssertEqual(result?.requestId, note.requestId)
        XCTAssertEqual(result?.accepted, false)
        XCTAssertTrue(transport.queued.isEmpty)
    }

    func testSnapshotRestoresAfterRestartAndRejectsOlderDelivery() async throws {
        let suite = "WatchTransportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = WatchReliabilityTransport()
        var snapshot = WatchTaskSnapshot.idle
        snapshot.phase = "completed"
        snapshot.runId = "saved-run"
        snapshot.sequence = 42
        snapshot.updatedAt = Date(timeIntervalSince1970: 100)
        transport.response = try WatchTaskCodec.snapshotMessage(for: snapshot)
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000, defaults: defaults)
        bridge.configure(transport: transport)
        let received = expectation(description: "cached snapshot")
        bridge.onSnapshotUpdated = { _ in received.fulfill() }
        XCTAssertTrue(bridge.requestSnapshotFromPhone())
        await fulfillment(of: [received], timeout: 1)
        let restored = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000, defaults: defaults)
        XCTAssertEqual(restored.latestSnapshot, snapshot)
        var older = snapshot
        older.sequence = 41
        older.phase = "running"
        XCTAssertFalse(WatchSnapshotOrdering.accepts(older, after: restored.latestSnapshot))
    }

    func testTimeoutMeansDeliveryUnknownRatherThanDefinitiveRejection() async {
        let transport = WatchReliabilityTransport()
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 10_000_000)
        bridge.configure(transport: transport)
        let received = expectation(description: "unknown delivery")
        bridge.onActionResult = { result in
            XCTAssertEqual(result.deliveryUnknown, true)
            XCTAssertFalse(result.accepted)
            received.fulfill()
        }
        bridge.sendAction(request(.ask))
        await fulfillment(of: [received], timeout: 1)
    }

    func testVersionMismatchGivesActionableConnectionError() async {
        let transport = WatchReliabilityTransport()
        transport.response = ["protocolVersion": 2, "type": "snapshot"]
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000)
        bridge.configure(transport: transport)
        let received = expectation(description: "upgrade guidance")
        bridge.onConnectionError = { message in
            XCTAssertTrue(message.contains("更新"))
            received.fulfill()
        }
        XCTAssertTrue(bridge.requestSnapshotFromPhone())
        await fulfillment(of: [received], timeout: 1)
    }

    private func request(_ action: WatchInboundAction) -> WatchTaskActionRequest {
        WatchTaskActionRequest(
            requestId: UUID().uuidString, runId: "", conversationId: nil,
            decisionId: nil, action: action, optionId: nil,
            text: "保留这段原文", createdAt: Date(timeIntervalSince1970: 100)
        )
    }
}
