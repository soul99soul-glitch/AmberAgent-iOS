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
