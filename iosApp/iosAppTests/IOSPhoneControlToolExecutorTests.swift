import AmberPhoneControl
import Foundation
import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSPhoneControlToolExecutorTests: XCTestCase {
    func testObservationDefaultsToTreeAndEnforcesAdvertisedBounds() throws {
        XCTAssertEqual(
            try IOSPhoneControlToolExecutor.request(name: "phone_observe", arguments: "{}"),
            .observe(maxNodes: 500, includeScreenshot: false)
        )
        XCTAssertEqual(
            try IOSPhoneControlToolExecutor.request(name: "phone_observe", arguments: #"{"max_nodes":1,"include_screenshot":true}"#),
            .observe(maxNodes: 1, includeScreenshot: true)
        )
        for invalid in [
            #"{"max_nodes":0}"#, #"{"max_nodes":501}"#,
            #"{"max_nodes":1.5}"#, #"{"max_nodes":true}"#,
            #"{"include_screenshot":1}"#,
        ] {
            XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_observe", arguments: invalid))
        }
    }

    func testActionRequiresFreshReferenceFieldsAndRejectsHome() throws {
        XCTAssertEqual(
            try IOSPhoneControlToolExecutor.request(name: "phone_act", arguments: #"{"action":"type","ref":"observation:1","text":"hello"}"#),
            .act(.type(ref: "observation:1", text: "hello"))
        )
        for invalid in [
            #"{"action":"home"}"#,
            #"{"action":"tap","ref":""}"#,
            #"{"action":"tap","ref":"observation:1","bundle_id":"other.app"}"#,
            #"{"action":"type","ref":"observation:1"}"#,
            #"{"action":"swipe","ref":"observation:1","direction":"diagonal"}"#,
        ] {
            XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_act", arguments: invalid))
        }
    }

    func testDispatchedWebDriverFailureRemainsUnknownAtEngineBoundary() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhoneToolFailureProtocol.self]
        let runner = try PhoneRunnerClient(
            token: String(repeating: "a", count: 64),
            allowedBundleIDs: ["app.test"],
            sessionConfiguration: configuration
        )
        let result = await runner.act(.launch(bundleID: "app.test"))
        guard case .outcomeUnknown(let parts) = IOSPhoneControlToolExecutor.actionOutcome(result),
              let text = parts.first as? UIMessagePart.Text,
              let object = try JSONSerialization.jsonObject(with: Data(text.text.utf8)) as? [String: Any] else {
            return XCTFail("A dispatched action's error must remain a typed unknown, not a normal tool failure.")
        }
        XCTAssertEqual(object["outcome"] as? String, "unknown")
        XCTAssertEqual(object["retry_safe"] as? Bool, false)
        XCTAssertEqual(object["http_status"] as? Int, 200)
        XCTAssertEqual(object["runner_code"] as? String, "unknown error")
        XCTAssertEqual(object["message"] as? String, "activation failed")
    }

    @MainActor
    func testStatusStopAndInvalidArgumentsDoNotStartRunner() async throws {
        let (controller, defaults, suite) = try await makeClaimedController(runID: "run-status")
        defer { defaults.removePersistentDomain(forName: suite) }
        let executor = IOSPhoneControlToolExecutor(runID: "run-status", controller: controller)

        let status = await executor.execute(name: "phone_status", arguments: "{}", isUserInitiated: true)
        guard case .filled(let statusText) = status else { return XCTFail("status must be a read-only filled result") }
        XCTAssertTrue(statusText.contains("phase=authorized"))
        XCTAssertEqual(controller.phase, .authorized)

        let invalid = await executor.execute(name: "phone_observe", arguments: #"{"max_nodes":0}"#, isUserInitiated: true)
        guard case .failed(let invalidText) = invalid else { return XCTFail("invalid args must fail before startup") }
        XCTAssertEqual(try decodedObject(invalidText)["code"] as? String, "invalid_arguments")
        XCTAssertEqual(controller.phase, .authorized)

        let stopped = await executor.execute(name: "phone_stop", arguments: "{}", isUserInitiated: true)
        guard case .filled(let stoppedText) = stopped else { return XCTFail("stop must return a filled result") }
        XCTAssertEqual(try decodedObject(stoppedText)["outcome"] as? String, "stopped")
        XCTAssertNil(controller.ownerRunID)
    }

    @MainActor
    func testFirstObserveStartupFailureIsNotSentAndSecondCallCannotRestart() async throws {
        let (controller, defaults, suite) = try await makeClaimedController(runID: "run-start")
        defer { defaults.removePersistentDomain(forName: suite) }
        let executor = IOSPhoneControlToolExecutor(runID: "run-start", controller: controller)

        let first = await executor.execute(name: "phone_observe", arguments: "{}", isUserInitiated: true)
        guard case .failed(let firstText) = first else { return XCTFail("startup failure must be a normal failed tool result") }
        let firstObject = try decodedObject(firstText)
        XCTAssertEqual(firstObject["outcome"] as? String, "not_sent")
        XCTAssertEqual(firstObject["retry_safe"] as? Bool, false)
        XCTAssertEqual(firstObject["code"] as? String, "phone_control_start_failed")
        XCTAssertTrue((firstObject["message"] as? String)?.contains("未发送任何手机动作") == true)
        XCTAssertNil(controller.ownerRunID, "startup failure must await owner cleanup")
        XCTAssertTrue(controller.hasPendingAuthorization, "a failed startup keeps the authorization window")

        let second = await executor.execute(name: "phone_observe", arguments: "{}", isUserInitiated: true)
        guard case .denied(let secondText) = second else { return XCTFail("a cleaned run must not restart from a second tool call") }
        XCTAssertEqual(try decodedObject(secondText)["code"] as? String, "run_not_authorized")
    }

    private func makeClaimedController(runID: String) async throws -> (IOSPhoneControlController, UserDefaults, String) {
        let suite = "IOSPhoneControlToolExecutorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let controller = IOSPhoneControlController(
            defaults: defaults,
            credentials: ToolExecutorPairingStore(data: Data([1]))
        )
        await controller.refreshPreparation()
        controller.enabled = true
        controller.selectedBundleIDs = ["app.test"]
        try controller.authorizeNextTask(durationSeconds: 300)
        XCTAssertTrue(controller.claim(runID: runID, onExpiration: {}))
        return (controller, defaults, suite)
    }

    private func decodedObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }



}

private final class PhoneToolFailureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"value":{"error":"unknown error","message":"activation failed"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor ToolExecutorPairingStore: IOSPhoneControlCredentialStoring {
    let data: Data

    init(data: Data) { self.data = data }

    func loadPairing() -> Data? { data }
    func savePairing(_ data: Data) { }
    func deletePairing() { }
}
