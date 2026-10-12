import AmberPhoneControl
import Foundation
import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSPhoneGoalToolIntegrationTests: XCTestCase {
    func testScrollSearchParsesExactTargetsAndRejectsStaleCoordinates() throws {
        let valid: [String: Any] = ["target": ["label": "目标"], "container": ["identifier": "list"], "direction": "up"]
        XCTAssertEqual(try IOSPhoneControlToolExecutor.request(name: "phone_scroll_until", arguments: json(valid)),
                       .scrollUntil(.init(target: .init(label: "目标"), container: .init(identifier: "list"), direction: .up)))
        for (key, value) in [("max_swipes", 9 as Any), ("max_swipes", true as Any), ("ref", "old:1" as Any),
                             ("container", ["identifier": "list", "x": 0.5] as Any)] {
            var invalid = valid
            invalid[key] = value
            XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_scroll_until", arguments: json(invalid)))
        }
    }

    func testClearCanRequireEmptyValueWithoutChangingAppendSemantics() throws {
        XCTAssertEqual(try IOSPhoneControlToolExecutor.request(name: "phone_act", arguments:
            #"{"action":"clear","ref":"observed:8","expectation":{"kind":"value_equals","target":{"identifier":"composer"},"value":""}}"#),
            .verifiedAct(.clear(ref: "observed:8"), .init(kind: .valueEquals,
                target: .init(identifier: "composer"), value: "")))
        XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_act", arguments:
            #"{"action":"clear","ref":"observed:8","text":"replacement"}"#))
        XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_act", arguments: #"{"action":"clear"}"#))
        XCTAssertEqual(IOSPhoneControlToolExecutor.actionActivity(.clear(ref: "observed:8")), .typing)
    }

    func testActionExpectationParsesWithoutChangingOriginalReference() throws {
        let arguments = #"{"action":"tap","ref":"observed:7","expectation":{"kind":"absent","target":{"identifier":"popup"},"anchor":{"label":"Home"}}}"#
        XCTAssertEqual(try IOSPhoneControlToolExecutor.request(name: "phone_act", arguments: arguments),
                       .verifiedAct(.tap(ref: "observed:7"), .init(kind: .absent,
                           target: .init(identifier: "popup"), anchor: .init(label: "Home"))))
        XCTAssertEqual(try IOSPhoneControlToolExecutor.request(name: "phone_act", arguments:
            #"{"action":"type","ref":"observed:8","text":"draft","expectation":{"kind":"value_equals","target":{"identifier":"composer"},"value":"draft"}}"#),
            .verifiedAct(.type(ref: "observed:8", text: "draft"), .init(kind: .valueEquals,
                target: .init(identifier: "composer"), value: "draft")))
    }

    func testActionRejectsMalformedExpectationInsteadOfSilentlyDroppingIt() throws {
        let invalid: [Any] = [
            NSNull(), [:], ["kind": "guessed", "target": ["label": "Home"]],
            ["kind": "visible", "target": ["label": "Home"], "confidence": 1],
            ["kind": "visible", "target": ["label": "Home", "ref": "old:1"]],
            ["kind": "visible", "target": ["label": String(repeating: "a", count: 513)]],
            ["kind": "visible", "target": ["type": "XCUIElementTypeButton"]],
            ["kind": "absent", "target": ["label": "Popup"]],
            ["kind": "absent", "target": ["label": "Popup"], "anchor": ["label": "Popup"]],
            ["kind": "absent", "target": ["label": "Popup"], "anchor": ["label": "Home", "guess": true]],
            ["kind": "value_equals", "target": ["identifier": "input"], "value": String(repeating: "x", count: 4001)],
        ]
        for expectation in invalid {
            let arguments = try json(["action": "tap", "ref": "old:1", "expectation": expectation])
            XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_act", arguments: arguments))
        }
    }

    func testGoalParsesBoundedActionsAndStructuredCompletion() throws {
        guard case .runGoal(let request) = try IOSPhoneControlToolExecutor.request(
            name: "phone_run_goal", arguments: json(validGoal())) else { return XCTFail("Expected goal request") }
        XCTAssertEqual(request.goal, "Open search")
        XCTAssertEqual(request.bundleID, "app.test")
        XCTAssertEqual(request.maxSteps, 6)
        XCTAssertEqual(request.actions, [.init(action: .tap, target: .init(identifier: "search"))])
        XCTAssertEqual(request.completion, .init(kind: .visible, target: .init(identifier: "results")))
    }

    func testGoalRejectsUnknownFieldsUnboundedInputsAndDuplicateCandidates() throws {
        var invalid: [[String: Any]] = []
        for (key, value) in [
            ("unknown", true as Any), ("goal", "   " as Any),
            ("goal", String(repeating: "g", count: 1001) as Any),
            ("bundle_id", "not an app" as Any), ("max_steps", 0 as Any),
            ("max_steps", 13 as Any), ("max_steps", true as Any),
            ("actions", [] as Any),
        ] {
            var object = validGoal(); object[key] = value; invalid.append(object)
        }
        let badActions: [[String: Any]] = [
            ["action": "launch", "target": ["identifier": "search"]],
            ["action": "tap", "target": ["identifier": "search"], "ref": "old:1"],
            ["action": "tap", "target": ["identifier": "search", "x": 0.5]],
            ["action": "tap", "target": ["identifier": "search"], "text": "extra"],
            ["action": "type", "target": ["identifier": "search"], "text": String(repeating: "x", count: 4001)],
            ["action": "swipe", "target": ["identifier": "search"], "direction": "diagonal"],
        ]
        for action in badActions {
            var object = validGoal(); object["actions"] = [action]; invalid.append(object)
        }
        var duplicate = validGoal()
        let action: [String: Any] = ["action": "tap", "target": ["identifier": "search"]]
        duplicate["actions"] = [action, action]
        invalid.append(duplicate)
        var tooMany = validGoal()
        tooMany["actions"] = (0..<13).map { ["action": "tap", "target": ["identifier": "button-\($0)"]] as [String: Any] }
        invalid.append(tooMany)
        for object in invalid {
            XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_run_goal", arguments: json(object)))
        }
    }

    func testLatestObservationPreservesRefAndUnmetEffectDoesNotEraseCompletedReceipt() async throws {
        let fixture = GoalHTTPFixture(GoalHTTPFixture.observation + GoalHTTPFixture.tap + GoalHTTPFixture.observation)
        defer { fixture.unregister() }
        let runner = try fixture.makeRunner()
        let before = try await runner.observe(includeScreenSize: true)
        let ref = try XCTUnwrap(before.nodes.first { $0.identifier == "popup" }?.ref)
        let request = try IOSPhoneControlToolExecutor.request(name: "phone_act", arguments: json([
            "action": "tap", "ref": ref,
            "expectation": ["kind": "absent", "target": ["identifier": "popup"], "anchor": ["identifier": "home"]],
        ]))
        guard case .verifiedAct(let action, let expectation) = request else { return XCTFail("Expected verified action") }
        let requestCount = fixture.paths.count
        let retained = await runner.latestObservation
        XCTAssertEqual(retained?.observationID, before.observationID)
        XCTAssertEqual(fixture.paths.count, requestCount, "Reading prior evidence cannot refresh the tree and stale its refs")

        let receipt = await runner.act(action)
        XCTAssertEqual(receipt, .completed)
        let after = try await runner.observe(includeScreenSize: true)
        let verification = IOSPhoneGoalVerification.evaluate(expectation: expectation, before: retained, after: after)
        XCTAssertEqual(verification.status, .unmet)
        XCTAssertEqual(verification.reason, "target_still_visible")
        guard case .filled(let text) = IOSPhoneControlToolExecutor.actionOutcome(receipt) else {
            return XCTFail("A completed runner receipt must survive an unmet postcondition")
        }
        XCTAssertEqual(try object(text)["outcome"] as? String, "completed")
        XCTAssertEqual(try object(text)["retry_safe"] as? Bool, false)
        XCTAssertEqual(fixture.paths.filter { $0.hasSuffix("/click") }.count, 1)
        XCTAssertEqual(fixture.paths.filter { $0 == "/source" }.count, 2)
        guard case .unsent(let problem) = await runner.act(action) else { return XCTFail("The consumed reference cannot be replayed") }
        XCTAssertEqual(problem.kind, .staleObservation)
    }

    func testVerifiedActionUnknownRetainsTypedEngineOutcomeAndStopsReplay() async throws {
        var tap = GoalHTTPFixture.tap
        tap[tap.count - 1] = .init(path: "/element/FRESH/click", body: "", error: .networkConnectionLost)
        let fixture = GoalHTTPFixture(GoalHTTPFixture.observation + tap)
        defer { fixture.unregister() }
        let runner = try fixture.makeRunner()
        let before = try await runner.observe(includeScreenSize: true)
        let ref = try XCTUnwrap(before.nodes.first { $0.identifier == "popup" }?.ref)
        let action = PhoneAction.tap(ref: ref)
        let receipt = await runner.act(action)
        let outcome = IOSPhoneControlToolExecutor.actionOutcome(receipt)
        guard case .outcomeUnknown(let parts) = outcome,
              let text = parts.first as? UIMessagePart.Text else { return XCTFail("Unknown must remain typed, never filled") }
        XCTAssertEqual(try object(text.text)["outcome"] as? String, "unknown")
        XCTAssertEqual(try object(text.text)["retry_safe"] as? Bool, false)
        XCTAssertEqual(IOSPhoneControlToolExecutor.completionActivity(
            request: .verifiedAct(action, .init(kind: .visible, target: .init(identifier: "home"))), outcome: outcome), .outcomeUnknown)
        let latest = await runner.latestObservation
        XCTAssertNil(latest)
        guard case .unsent(let problem) = await runner.act(action) else { return XCTFail("Unknown closes further dispatch") }
        XCTAssertEqual(problem.kind, .previousOutcomeUnknown)
        XCTAssertEqual(fixture.paths.filter { $0.hasSuffix("/click") }.count, 1)
        XCTAssertEqual(fixture.paths.filter { $0 == "/source" }.count, 1, "No post-action observation or retry after unknown")
    }

    private func validGoal() -> [String: Any] {
        ["goal": "Open search", "bundle_id": "app.test",
         "actions": [["action": "tap", "target": ["identifier": "search"]]],
         "completion": ["kind": "visible", "target": ["identifier": "results"]]]
    }

    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

/// Only the runner HTTP boundary is replaced. The native launcher is deliberately
/// outside this fixture; executor startup and final packaging still need device evidence.
private final class GoalHTTPFixture: @unchecked Sendable {
    struct Reply: Sendable {
        var path: String
        var body: String
        var error: URLError.Code? = nil
    }
    static let active = Reply(path: "/wda/activeAppInfo", body: #"{"value":{"bundleId":"app.test","pid":42}}"#)
    static var observation: [Reply] { [active,
        .init(path: "/source", body: #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":400,"height":800},"children":[{"type":"XCUIElementTypeButton","rawIdentifier":"popup","label":"Close","isEnabled":"1","rect":{"x":160,"y":500,"width":80,"height":44},"children":[]},{"type":"XCUIElementTypeButton","rawIdentifier":"home","label":"Home","isEnabled":"1","rect":{"x":20,"y":700,"width":80,"height":44},"children":[]}]}}"#),
        .init(path: "/window/size", body: #"{"value":{"width":400,"height":800}}"#), active] }
    static var tap: [Reply] { [active,
        .init(path: "/elements", body: #"{"value":[{"element-6066-11e4-a52e-4f735466cecf":"FRESH"}]}"#),
        active, .init(path: "/element/FRESH/click", body: #"{"value":null}"#)] }
    let port: UInt16
    private let lock = NSLock()
    private var replies: [Reply]
    private var recordedPaths: [String] = []
    var paths: [String] { lock.withLock { recordedPaths } }

    init(_ replies: [Reply]) {
        self.replies = replies
        port = GoalHTTPProtocol.nextPort()
        GoalHTTPProtocol.register(self)
    }

    func unregister() { GoalHTTPProtocol.remove(port) }
    func makeRunner() throws -> PhoneRunnerClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GoalHTTPProtocol.self]
        return try PhoneRunnerClient(token: String(repeating: "a", count: 64), allowedBundleIDs: ["app.test"],
                                     port: port, sessionConfiguration: config)
    }

    func reply(to request: URLRequest) -> Reply {
        lock.withLock {
            let path = request.url!.path
            recordedPaths.append(path)
            guard !replies.isEmpty else {
                XCTFail("Unexpected runner request: \(path)")
                return Reply(path: path, body: "", error: .badServerResponse)
            }
            let next = replies.removeFirst()
            XCTAssertEqual(path, next.path)
            XCTAssertEqual(request.httpMethod, ["/elements", "/element/FRESH/click"].contains(path) ? "POST" : "GET")
            return next
        }
    }
}

private final class GoalHTTPProtocol: URLProtocol, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var port: UInt16 = 31_000
        var fixtures: [UInt16: GoalHTTPFixture] = [:]
    }
    private static let registry = Registry()
    static func nextPort() -> UInt16 { registry.lock.withLock { registry.port += 1; return registry.port } }
    static func register(_ fixture: GoalHTTPFixture) { registry.lock.withLock { registry.fixtures[fixture.port] = fixture } }
    static func remove(_ port: UInt16) { _ = registry.lock.withLock { registry.fixtures.removeValue(forKey: port) } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.registry.lock.withLock {
            request.url?.port.flatMap { Self.registry.fixtures[UInt16($0)] }
        }
        guard let fixture else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let reply = fixture.reply(to: request)
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "X-IPU-Pid": "42", "X-IPU-Backend": "private-ax", "X-IPU-Truncated": "0",
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
