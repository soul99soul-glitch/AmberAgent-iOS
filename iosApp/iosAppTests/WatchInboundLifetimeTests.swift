import UIKit
import WatchConnectivity
import XCTest
@testable import iosApp

@MainActor
final class WatchInboundLifetimeTests: XCTestCase {
    private final class Transport: WatchConnectivityTransporting {
        var isSupported = true
        var isPaired = true
        var isWatchAppInstalled = true
        var isReachable = true
        var onQueue: (() -> Void)?
        func activate() {}
        func updateApplicationContext(_ context: [String: Any]) throws {}
        func transferUserInfo(_ userInfo: [String: Any]) -> String {
            onQueue?()
            return "ack"
        }
        func sendMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?,
                         errorHandler: ((Error) -> Void)?) {}
    }

    private final class DelayedHandler: WatchTaskActionHandling {
        let started: XCTestExpectation
        var continuation: CheckedContinuation<Void, Never>?
        var handled = false
        init(started: XCTestExpectation) { self.started = started }
        func refreshWatchSnapshot() async {
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
            handled = true
        }
        func handleWatchAction(_ request: WatchTaskActionRequest) async -> WatchTaskActionResult {
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
            handled = true
            return WatchTaskActionResult(requestId: request.requestId, runId: "",
                accepted: true, message: nil, snapshot: nil)
        }
    }

    func testQueuedNoteKeepsBackgroundTimeUntilApplicationAckIsQueued() async throws {
        try await checkDelegateLifetime(usesReplyHandler: false)
    }

    func testInteractiveRequestKeepsBackgroundTimeUntilReplyIsSubmitted() async throws {
        try await checkDelegateLifetime(usesReplyHandler: true)
    }

    func testColdSnapshotRefreshKeepsBackgroundTimeUntilReplyIsSubmitted() async throws {
        try await checkDelegateLifetime(usesReplyHandler: true, requestsSnapshot: true)
    }

    private func checkDelegateLifetime(usesReplyHandler: Bool, requestsSnapshot: Bool = false) async throws {
        var events: [String] = []
        let started = expectation(description: "handler starts")
        let ended = expectation(description: "background window ends")
        let handler = DelayedHandler(started: started)
        let transport = Transport()
        transport.onQueue = { events.append("ack") }
        let factory = WatchInboundBackgroundLifetimeFactory(
            beginBackgroundTask: { _, _ in
                events.append("begin")
                return UIBackgroundTaskIdentifier(rawValue: 801)
            },
            endBackgroundTask: { _ in events.append("end"); ended.fulfill() }
        )
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000_000,
            inboundLifetimeFactory: factory)
        bridge.configure(transport: transport, actionHandler: handler)
        let request = WatchTaskActionRequest(requestId: UUID().uuidString, runId: "",
            conversationId: nil, decisionId: nil, action: .saveNote, optionId: nil,
            text: "durable note", createdAt: Date())
        let message = try requestsSnapshot ? WatchTaskCodec.requestSnapshotMessage() : WatchTaskCodec.actionMessage(for: request)
        if usesReplyHandler {
            bridge.session(WCSession.default, didReceiveMessage: message) { _ in events.append("reply") }
        } else {
            bridge.session(WCSession.default, didReceiveUserInfo: message)
        }
        XCTAssertEqual(events, ["begin"], "Keep alive must start before hopping to MainActor")
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(events, ["begin"], "Awaiting storage must not release background time")
        handler.continuation?.resume()
        handler.continuation = nil
        await fulfillment(of: [ended], timeout: 1)
        XCTAssertTrue(handler.handled)
        XCTAssertEqual(events, ["begin", usesReplyHandler ? "reply" : "ack", "end"])
    }

    private final class Spy {
        var beginCount = 0
        var begunNames: [String] = []
        var endedIdentifiers: [UIBackgroundTaskIdentifier] = []
        var expirationHandlers: [() -> Void] = []
        var nextIdentifier: Int = 701
        var fireExpirationDuringBegin = false

        func makeLifetime(name: String = "test-inbound") -> WatchInboundBackgroundLifetime {
            WatchInboundBackgroundLifetime(
                name: name,
                beginBackgroundTask: { [self] name, expiration in
                    beginCount += 1
                    begunNames.append(name)
                    expirationHandlers.append(expiration)
                    let identifier = UIBackgroundTaskIdentifier(rawValue: nextIdentifier)
                    nextIdentifier += 1
                    if fireExpirationDuringBegin {
                        expiration()
                    }
                    return identifier
                },
                endBackgroundTask: { [self] identifier in
                    endedIdentifiers.append(identifier)
                }
            )
        }
    }

    func testNormalCompletionEndsTheShortWindowOnlyOnce() {
        let spy = Spy()
        let lifetime = spy.makeLifetime()

        lifetime.begin()
        lifetime.begin()
        lifetime.end()
        lifetime.end()
        spy.expirationHandlers.first?()

        XCTAssertEqual(spy.beginCount, 1)
        XCTAssertEqual(spy.begunNames, ["test-inbound"])
        XCTAssertEqual(spy.endedIdentifiers, [UIBackgroundTaskIdentifier(rawValue: 701)])
    }

    func testExpirationAndReplyCompletionRaceEndsTheTaskOnce() {
        let spy = Spy()
        let lifetime = spy.makeLifetime()

        lifetime.begin()
        spy.expirationHandlers.first?()
        lifetime.end()

        XCTAssertEqual(spy.endedIdentifiers, [UIBackgroundTaskIdentifier(rawValue: 701)])
    }

    func testSynchronousExpirationDuringBeginStillEndsAfterIdentifierIsKnown() {
        let spy = Spy()
        spy.fireExpirationDuringBegin = true
        let lifetime = spy.makeLifetime()

        lifetime.begin()
        lifetime.end()

        XCTAssertEqual(spy.endedIdentifiers, [UIBackgroundTaskIdentifier(rawValue: 701)])
    }
}
