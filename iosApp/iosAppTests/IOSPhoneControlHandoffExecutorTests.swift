import AmberPhoneControl
import CryptoKit
import Foundation
import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSPhoneControlHandoffExecutorTests: XCTestCase {
    func testIdleTakeoverThenResumeReplacesLateTapCoordinatesAndGoalWithFreshEvidence() async throws {
        for kind in ["tap", "tap_point", "goal"] {
            let harness = try await Harness()
            defer { harness.dispose() }
            let initial = await harness.executor.execute(name: "phone_observe", arguments: "{}", isUserInitiated: true)
            guard case .filledParts = initial else { return XCTFail("Initial observation must use the real runner") }
            let runner = try await harness.session.runner(runID: UUID())
            let oldObservation = await runner.latestObservation
            let old = try XCTUnwrap(oldObservation)
            let arguments: String
            let name: String
            switch kind {
            case "tap":
                name = "phone_act"
                arguments = #"{"action":"tap","ref":"\#(try XCTUnwrap(old.nodes[1].ref))"}"#
            case "tap_point":
                name = "phone_act"
                arguments = #"{"action":"tap_point","observation_id":"\#(old.observationID)","x":0.5,"y":0.5}"#
            default:
                name = "phone_run_goal"
                arguments = #"{"goal":"Open the item","bundle_id":"app.test","actions":[{"action":"tap","target":{"identifier":"item"}}],"completion":{"kind":"visible","target":{"identifier":"done"}}}"#
            }
            try harness.controller.requestHumanTakeover(runID: harness.runID)
            XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .paused)
            try harness.controller.resumeAutomation(runID: harness.runID)
            let outcome = await harness.executor.execute(name: name, arguments: arguments, isUserInitiated: true)
            let receipt = try handback(outcome)
            XCTAssertEqual(receipt["outcome"] as? String, "not_sent", kind)
            XCTAssertEqual(receipt["fresh_observation_available"] as? Bool, true, kind)
            XCTAssertNil(receipt["prior_tool_receipt"], kind)
            let freshObservation = await runner.latestObservation
            let fresh = try XCTUnwrap(freshObservation)
            XCTAssertNotEqual(fresh.observationID, old.observationID, kind)
            XCTAssertEqual(fresh.nodes[1].label, "screen-2", kind)
            XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .automated)
            XCTAssertEqual(harness.http.sourceCount, 2)
            XCTAssertTrue(harness.http.mutationPaths.isEmpty, "The late \(kind) request must never dispatch")
            await harness.controller.stop(runID: harness.runID)
        }
    }

    func testTakeoverDuringMutationWaitsForReceiptThenPreservesItAndObservesAfterResume() async throws {
        let gate = HandoffReplyGate()
        let paused = expectation(description: "Receipt ends the tool and acknowledges pause")
        let harness = try await Harness(postGate: gate, onHandoff: { _, state in
            if state == .paused { paused.fulfill() }
        })
        defer { harness.dispose(); gate.release() }
        let execution = PendingExecution()
        let task = execution.start(executor: harness.executor, name: "phone_act", arguments: launchArguments)
        defer { task.cancel() }
        await fulfillment(of: [gate.started], timeout: 2)
        try harness.controller.requestHumanTakeover(runID: harness.runID)
        XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .pausing)
        XCTAssertThrowsError(try harness.controller.resumeAutomation(runID: harness.runID))
        XCTAssertNil(execution.outcome)
        XCTAssertEqual(harness.http.sourceCount, 0)
        gate.release()
        await fulfillment(of: [paused], timeout: 2)
        XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .paused)
        XCTAssertNil(execution.outcome, "The receipt must not resume automation on its own")
        try harness.controller.resumeAutomation(runID: harness.runID)
        await fulfillment(of: [execution.finished], timeout: 2)
        let receipt = try handback(XCTUnwrap(execution.outcome))
        let prior = try XCTUnwrap(receipt["prior_tool_receipt"] as? [String: Any])
        XCTAssertEqual(prior["kind"] as? String, "filled")
        let original = try object(XCTUnwrap(prior["result"] as? String))
        XCTAssertEqual(original["outcome"] as? String, "completed")
        XCTAssertEqual(receipt["fresh_observation_available"] as? Bool, true)
        XCTAssertEqual(harness.http.mutationPaths, ["/wda/apps/activate"])
        XCTAssertEqual(harness.http.sourceCount, 1)
        let startCount = await harness.session.startCount
        XCTAssertEqual(startCount, 1, "Resume must reuse the owner session")
        await harness.controller.stop(runID: harness.runID)
    }

    func testUnknownMutationReceiptOverridesRequestedPauseWithoutWaitingOrObserving() async throws {
        let gate = HandoffReplyGate()
        var handoffStates: [IOSPhoneControlHandoffState] = []
        let harness = try await Harness(postGate: gate, unknownMutation: true,
                                       onHandoff: { _, state in handoffStates.append(state) })
        defer { harness.dispose(); gate.release() }
        let execution = PendingExecution()
        let task = execution.start(executor: harness.executor, name: "phone_act", arguments: launchArguments)
        defer { task.cancel() }
        await fulfillment(of: [gate.started], timeout: 2)
        try harness.controller.requestHumanTakeover(runID: harness.runID)
        gate.release()
        await fulfillment(of: [execution.finished], timeout: 2)
        guard case .outcomeUnknown(let parts) = try XCTUnwrap(execution.outcome),
              let text = parts.first as? UIMessagePart.Text else {
            return XCTFail("Dispatched uncertainty must reach the real engine outcome")
        }
        let receipt = try object(text.text)
        XCTAssertEqual(receipt["outcome"] as? String, "unknown")
        XCTAssertEqual(receipt["runner_code"] as? String, "unknown error")
        XCTAssertEqual(receipt["retry_safe"] as? Bool, false)
        XCTAssertEqual(handoffStates, [.pausing])
        XCTAssertNil(harness.controller.handoffState(runID: harness.runID))
        XCTAssertThrowsError(try harness.controller.resumeAutomation(runID: harness.runID))
        XCTAssertEqual(harness.http.sourceCount, 0)
        XCTAssertEqual(harness.http.mutationPaths, ["/wda/apps/activate"])
        await harness.controller.stop(runID: harness.runID)
    }

    func testStopOrTaskCancellationReleasesPausedToolWithoutStartingRunner() async throws {
        for stopsRun in [true, false] {
            let harness = try await Harness()
            defer { harness.dispose() }
            try harness.controller.requestHumanTakeover(runID: harness.runID)
            let execution = PendingExecution()
            let task = execution.start(executor: harness.executor, name: "phone_act", arguments: launchArguments)
            defer { task.cancel() }
            // This task runs on MainActor through lease creation into the first
            // suspended resume wait before this test can regain the actor.
            await fulfillment(of: [execution.started], timeout: 2)
            XCTAssertNil(execution.outcome)
            XCTAssertTrue(harness.http.paths.isEmpty)
            if stopsRun { await harness.controller.stop(runID: harness.runID) }
            else { task.cancel() }
            await fulfillment(of: [execution.finished], timeout: 2)
            let receipt = try handback(XCTUnwrap(execution.outcome))
            XCTAssertEqual(receipt["outcome"] as? String, "not_sent")
            XCTAssertEqual(receipt["fresh_observation_available"] as? Bool, false)
            XCTAssertNotNil(receipt["resume_error"])
            XCTAssertTrue(harness.http.paths.isEmpty)
            let starts = await harness.session.startCount
            XCTAssertEqual(starts, 0)
            if stopsRun { XCTAssertNil(harness.controller.ownerRunID) }
            else {
                // Cancelling the wait must release its slot, rather than denying
                // every subsequent tool as busy for this still-valid owner.
                try harness.controller.resumeAutomation(runID: harness.runID)
                let followup = await harness.executor.execute(name: "phone_observe", arguments: "{}", isUserInitiated: true)
                XCTAssertEqual(try handback(followup)["fresh_observation_available"] as? Bool, true)
                await harness.controller.stop(runID: harness.runID)
            }
        }
    }

    func testSecondTakeoverDuringResumeObservationCannotBeConsumedByOlderGeneration() async throws {
        let gate = HandoffReplyGate()
        var handoffStates: [IOSPhoneControlHandoffState] = []
        let harness = try await Harness(sourceGate: gate, onHandoff: { _, state in handoffStates.append(state) })
        defer { harness.dispose(); gate.release() }
        try harness.controller.requestHumanTakeover(runID: harness.runID)
        try harness.controller.resumeAutomation(runID: harness.runID)
        let execution = PendingExecution()
        let task = execution.start(executor: harness.executor, name: "phone_act", arguments: launchArguments)
        defer { task.cancel() }
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .resuming)
        try harness.controller.requestHumanTakeover(runID: harness.runID)
        XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .paused)
        gate.release()
        let runner = try await harness.session.runner(runID: UUID())
        // Wait for publication of the first tree, using actor reads rather than
        // a wall-clock delay. Publication occurs after all observation requests.
        var first: PhoneObservation?
        for _ in 0..<500 {
            first = await runner.latestObservation
            if first != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.nodes[1].label, "screen-1")
        XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .paused)
        XCTAssertNil(execution.outcome)
        try harness.controller.resumeAutomation(runID: harness.runID)
        await fulfillment(of: [execution.finished], timeout: 2)
        XCTAssertEqual(try handback(XCTUnwrap(execution.outcome))["fresh_observation_available"] as? Bool, true)
        let fresh = await runner.latestObservation
        XCTAssertEqual(fresh?.nodes[1].label, "screen-2")
        XCTAssertNotEqual(fresh?.observationID, first?.observationID)
        XCTAssertEqual(harness.http.sourceCount, 2)
        XCTAssertTrue(harness.http.mutationPaths.isEmpty)
        XCTAssertEqual(handoffStates, [.paused, .resuming, .paused, .resuming, .automated])
        await harness.controller.stop(runID: harness.runID)
    }

    func testFailedResumeSourcePausesAndRequiresUserResumeBeforeAnotherRead() async throws {
        var states: [IOSPhoneControlHandoffState] = []
        let harness = try await Harness(firstSourceError: .cannotConnectToHost,
                                       onHandoff: { _, state in states.append(state) })
        defer { harness.dispose() }
        try harness.controller.requestHumanTakeover(runID: harness.runID)
        try harness.controller.resumeAutomation(runID: harness.runID)
        let failed = await harness.executor.execute(name: "phone_act", arguments: launchArguments, isUserInitiated: true)
        XCTAssertEqual(try handback(failed)["fresh_observation_available"] as? Bool, false)
        XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .paused)
        let reason = try XCTUnwrap(harness.controller.handoffFailure(runID: harness.runID))
        XCTAssertTrue(reason.contains("重新读取界面失败"))
        XCTAssertTrue(harness.controller.statusText(runID: harness.runID).contains(reason))
        XCTAssertEqual(harness.http.sourceCount, 1)
        XCTAssertFalse(harness.controller.canDispatchAction(runID: harness.runID))

        let pending = PendingExecution()
        let task = pending.start(executor: harness.executor, name: "phone_act", arguments: launchArguments)
        defer { task.cancel() }
        await fulfillment(of: [pending.started], timeout: 2)
        XCTAssertNil(pending.outcome)
        XCTAssertEqual(harness.http.sourceCount, 1, "A new model tool must not implicitly retry the failed read")
        let status = await harness.executor.execute(name: "phone_status", arguments: "{}", isUserInitiated: true)
        guard case .filled(let statusText) = status else { return XCTFail("Status remains available while paused") }
        XCTAssertTrue(statusText.contains(reason))
        XCTAssertEqual(harness.http.sourceCount, 1)
        try harness.controller.resumeAutomation(runID: harness.runID)
        XCTAssertNil(harness.controller.handoffFailure(runID: harness.runID))
        await fulfillment(of: [pending.finished], timeout: 2)
        XCTAssertEqual(try handback(XCTUnwrap(pending.outcome))["fresh_observation_available"] as? Bool, true)
        XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .automated)
        XCTAssertEqual(harness.http.sourceCount, 2)
        XCTAssertTrue(harness.http.mutationPaths.isEmpty)
        XCTAssertEqual(states, [.paused, .resuming, .paused, .resuming, .automated])
        await harness.controller.stop(runID: harness.runID)
    }

    func testCancellationDuringResumeReadDoesNotRecordFailureOrChangeHandoffState() async throws {
        let gate = HandoffReplyGate()
        var states: [IOSPhoneControlHandoffState] = []
        let harness = try await Harness(sourceGate: gate, onHandoff: { _, state in states.append(state) })
        defer { harness.dispose(); gate.release() }
        try harness.controller.requestHumanTakeover(runID: harness.runID)
        try harness.controller.resumeAutomation(runID: harness.runID)
        let execution = PendingExecution()
        let task = execution.start(executor: harness.executor, name: "phone_act", arguments: launchArguments)
        defer { task.cancel() }
        await fulfillment(of: [gate.started], timeout: 2)
        task.cancel()
        gate.release()
        await fulfillment(of: [execution.finished], timeout: 2)
        XCTAssertEqual(try handback(XCTUnwrap(execution.outcome))["fresh_observation_available"] as? Bool, false)
        XCTAssertNil(harness.controller.handoffFailure(runID: harness.runID))
        XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .resuming)
        XCTAssertEqual(states, [.paused, .resuming])
        XCTAssertTrue(harness.http.mutationPaths.isEmpty)
        await harness.controller.stop(runID: harness.runID)
    }

    private var launchArguments: String { #"{"action":"launch","bundle_id":"app.test"}"# }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func handback(_ outcome: IOSAgentToolOutcome) throws -> [String: Any] {
        let text: String
        switch outcome {
        case .replanRequired(let parts): text = try XCTUnwrap(parts.first as? UIMessagePart.Text).text
        default: throw NSError(domain: "Expected real executor handback", code: 1)
        }
        let receipt = try object(text)
        XCTAssertEqual(receipt["status"] as? String, "handback")
        XCTAssertEqual(receipt["reason_code"] as? String, "human_intervened")
        XCTAssertEqual(receipt["retry_safe"] as? Bool, false)
        return receipt
    }

    @MainActor
    private final class PendingExecution {
        let started = XCTestExpectation(description: "Tool task entered executor")
        let finished = XCTestExpectation(description: "Real executor returned")
        var outcome: IOSAgentToolOutcome?

        func start(executor: IOSPhoneControlToolExecutor, name: String, arguments: String) -> Task<Void, Never> {
            Task { [self] in
                started.fulfill()
                outcome = await executor.execute(name: name, arguments: arguments, isUserInitiated: true)
                finished.fulfill()
            }
        }
    }

    @MainActor
    private final class Harness {
        let runID: String
        let suite: String
        let defaults: UserDefaults
        let http: HandoffHTTPFixture
        let session: HandoffSessionStub
        let controller: IOSPhoneControlController
        let executor: IOSPhoneControlToolExecutor

        init(postGate: HandoffReplyGate? = nil, sourceGate: HandoffReplyGate? = nil,
             unknownMutation: Bool = false, firstSourceError: URLError.Code? = nil,
             onHandoff: @escaping @MainActor (String, IOSPhoneControlHandoffState) -> Void = { _, _ in }) async throws {
            let runID = "handoff-\(UUID().uuidString)"
            let suite = "IOSPhoneControlHandoffExecutorTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let http = HandoffHTTPFixture(postGate: postGate, sourceGate: sourceGate,
                                          unknownMutation: unknownMutation, firstSourceError: firstSourceError)
            let session = HandoffSessionStub(fixture: http)
            let key = Curve25519.Signing.PrivateKey()
            let pairing = try PropertyListSerialization.data(fromPropertyList: [
                "public_key": key.publicKey.rawRepresentation, "private_key": key.rawRepresentation,
                "identifier": UUID().uuidString,
            ], format: .binary, options: 0)
            let controller = IOSPhoneControlController(defaults: defaults, credentials: HandoffPairingStore(data: pairing),
                session: session, localTunnel: PhoneControlTunnelStub(), onHandoffChange: onHandoff)
            self.runID = runID
            self.suite = suite
            self.defaults = defaults
            self.http = http
            self.session = session
            self.controller = controller
            executor = IOSPhoneControlToolExecutor(runID: runID, controller: controller, reportActivity: { _ in })
            await controller.refreshPreparation()
            controller.enabled = true
            controller.selectedBundleIDs = ["app.test"]
            XCTAssertTrue(controller.claim(runID: runID, onStop: {}))
        }

        func dispose() {
            http.unregister()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

private actor HandoffPairingStore: IOSPhoneControlCredentialStoring {
    let data: Data
    init(data: Data) { self.data = data }
    func loadPairing() -> Data? { data }
    func savePairing(_ data: Data) {}
    func deletePairing() {}
}

private actor HandoffSessionStub: IOSPhoneControlSessionServing {
    let fixture: HandoffHTTPFixture
    private var client: PhoneRunnerClient?
    private(set) var startCount = 0
    init(fixture: HandoffHTTPFixture) { self.fixture = fixture }
    func start(runID: UUID, configuration: PhoneControlLaunchConfiguration) async throws -> PhoneRunnerStatus {
        startCount += 1
        let http = URLSessionConfiguration.ephemeral
        http.protocolClasses = [HandoffHTTPProtocol.self]
        let runner = try PhoneRunnerClient(token: String(repeating: "a", count: 64),
            allowedBundleIDs: configuration.allowedBundleIDs, port: fixture.port, sessionConfiguration: http)
        client = runner
        return try await runner.status()
    }
    func runner(runID: UUID) throws -> PhoneRunnerClient { try XCTUnwrap(client) }
    func stop(runID: UUID) async { await client?.stop() }
    func launchStatus(runID: UUID) -> PhoneControlLaunchStatus? { nil }
    func cachedApplications(runID: UUID) -> [PhoneControlInstalledApp] { [] }
}

private final class HandoffHTTPFixture: @unchecked Sendable {
    let port: UInt16
    private let postGate: HandoffReplyGate?
    private let sourceGate: HandoffReplyGate?
    private let unknownMutation: Bool
    private let firstSourceError: URLError.Code?
    private let lock = NSLock()
    private var requests: [(String, String)] = []
    private var sources = 0
    var paths: [String] { lock.withLock { requests.map { $0.1 } } }
    var mutationPaths: [String] { lock.withLock { requests.filter { $0.0 == "POST" }.map { $0.1 } } }
    var sourceCount: Int { lock.withLock { sources } }

    init(postGate: HandoffReplyGate?, sourceGate: HandoffReplyGate?, unknownMutation: Bool,
         firstSourceError: URLError.Code?) {
        self.postGate = postGate
        self.sourceGate = sourceGate
        self.unknownMutation = unknownMutation
        self.firstSourceError = firstSourceError
        port = HandoffHTTPProtocol.nextPort()
        HandoffHTTPProtocol.register(self)
    }
    func unregister() { HandoffHTTPProtocol.remove(port) }

    func reply(_ request: URLRequest) throws -> (String, HandoffReplyGate?) {
        let path = try XCTUnwrap(request.url?.path)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("IPU-HMAC-SHA256 ") == true)
        let sourceIndex = lock.withLock {
            requests.append((request.httpMethod ?? "", path))
            if path == "/source" { sources += 1 }
            return sources
        }
        switch path {
        case "/status": return (#"{"value":{"ready":true,"sessionId":"handoff","auth":{"required":true,"scheme":"IPU-HMAC-SHA256"}}}"#, nil)
        case "/wda/activeAppInfo": return (#"{"value":{"bundleId":"app.test","pid":42}}"#, nil)
        case "/window/size": return (#"{"value":{"width":402,"height":874}}"#, nil)
        case "/source":
            if sourceIndex == 1, let firstSourceError { throw URLError(firstSourceError) }
            let body = #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":402,"height":874},"children":[{"type":"XCUIElementTypeButton","rawIdentifier":"item","label":"screen-\#(sourceIndex)","rect":{"x":20,"y":100,"width":80,"height":44},"children":[]}]}}"#
            return (body, sourceIndex == 1 ? sourceGate : nil)
        case "/wda/apps/activate":
            XCTAssertEqual(request.httpMethod, "POST")
            return (unknownMutation ? #"{"value":{"error":"unknown error","message":"activation receipt lost"}}"# : #"{"value":null}"#, postGate)
        default:
            XCTFail("Unexpected runner request \(path)")
            throw URLError(.badURL)
        }
    }
}

private final class HandoffReplyGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "Runner request awaits its real response")
    private let lock = NSLock()
    private var send: (@Sendable () -> Void)?
    func enqueue(_ send: @escaping @Sendable () -> Void) {
        lock.withLock { self.send = send }
        started.fulfill()
    }
    func release() {
        let reply = lock.withLock { let reply = send; send = nil; return reply }
        reply?()
    }
}

private final class HandoffHTTPProtocol: URLProtocol, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var port: UInt16 = 36_000
        var fixtures: [UInt16: HandoffHTTPFixture] = [:]
    }
    private static let registry = Registry()
    static func nextPort() -> UInt16 { registry.lock.withLock { registry.port += 1; return registry.port } }
    static func register(_ fixture: HandoffHTTPFixture) { registry.lock.withLock { registry.fixtures[fixture.port] = fixture } }
    static func remove(_ port: UInt16) { _ = registry.lock.withLock { registry.fixtures.removeValue(forKey: port) } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.registry.lock.withLock({ request.url?.port.flatMap { Self.registry.fixtures[UInt16($0)] } }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        do {
            let (body, gate) = try fixture.reply(request)
            let send: @Sendable () -> Void = { [self] in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["X-IPU-Pid": "42", "X-IPU-Backend": "private-ax", "X-IPU-Truncated": "0"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            if let gate { gate.enqueue(send) } else { send() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
