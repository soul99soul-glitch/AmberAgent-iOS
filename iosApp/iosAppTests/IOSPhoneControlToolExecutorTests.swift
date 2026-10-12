import AmberPhoneControl
import Foundation
import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSPhoneControlToolExecutorTests: XCTestCase {
    func testScreenshotOnlyCloseButtonHasReachableAction() throws {
        // The reported popup exposes only window containers, so there is no close-button ref.
        XCTAssertNoThrow(try IOSPhoneControlToolExecutor.request(
            name: "phone_act",
            arguments: #"{"action":"tap_point","observation_id":"popup-frame","x":0.5,"y":0.744}"#
        ))
    }

    func testVisualTapRequiresScreenshotIDAndNormalizedCoordinatesWithoutElementRef() throws {
        XCTAssertEqual(try IOSPhoneControlToolExecutor.request(
            name: "phone_act",
            arguments: #"{"action":"tap_point","observation_id":"popup-frame","x":0.5,"y":0.744}"#
        ), .act(.tapPoint(observationID: "popup-frame", x: 0.5, y: 0.744)))
        for arguments in [
            #"{"action":"tap_point","x":0.5,"y":0.744}"#,
            #"{"action":"tap_point","observation_id":"","x":0.5,"y":0.744}"#,
            #"{"action":"tap_point","observation_id":"frame","x":201,"y":650}"#,
            #"{"action":"tap_point","observation_id":"frame","x":1,"y":0.744}"#,
            #"{"action":"tap_point","observation_id":"frame","x":0.5,"y":-0.1}"#,
            #"{"action":"tap_point","observation_id":"frame","x":0.5,"y":0.744,"ref":"frame:1"}"#,
            #"{"action":"tap","ref":"frame:1","x":0.5,"y":0.744}"#,
        ] {
            XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_act", arguments: arguments))
        }
        XCTAssertEqual(IOSPhoneControlToolExecutor.actionActivity(.tapPoint(observationID: "frame", x: 0.5, y: 0.744)), .tapping)
    }

    func testScreenshotSwipeRequiresDistinctNormalizedEndpointsAndScreenshotID() throws {
        let action = PhoneAction.swipePoint(observationID: "overlay-frame", startX: 0.5, startY: 0.06, endX: 0.5, endY: 0.005)
        XCTAssertEqual(try IOSPhoneControlToolExecutor.request(
            name: "phone_act",
            arguments: #"{"action":"swipe_point","observation_id":"overlay-frame","x":0.5,"y":0.06,"end_x":0.5,"end_y":0.005}"#
        ), .act(action))
        XCTAssertEqual(IOSPhoneControlToolExecutor.actionActivity(action), .swiping)
        for arguments in [
            #"{"action":"swipe_point","x":0.5,"y":0.06,"end_x":0.5,"end_y":0.005}"#,
            #"{"action":"swipe_point","observation_id":"frame","x":0.5,"y":0.06,"end_x":0.5}"#,
            #"{"action":"swipe_point","observation_id":"frame","x":0.5,"y":0.06,"end_x":0.5,"end_y":0.06}"#,
            #"{"action":"swipe_point","observation_id":"frame","x":0.5,"y":0.06,"end_x":1,"end_y":0}"#,
            #"{"action":"swipe_point","observation_id":"frame","x":201,"y":52,"end_x":201,"end_y":5}"#,
            #"{"action":"swipe_point","observation_id":"frame","x":0.5,"y":0.06,"end_x":0.5,"end_y":0.005,"ref":"ref"}"#,
        ] {
            XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_act", arguments: arguments))
        }
    }

    func testPhoneActivityUsesOnlyActionCategoriesAndPreservesUnknownOutcome() {
        XCTAssertEqual(IOSPhoneControlToolExecutor.actionActivity(.type(ref: "private-ref", text: "private message")), .typing)
        XCTAssertEqual(IOSPhoneControlToolExecutor.actionActivity(.launch(bundleID: "private.app")), .openingApp)
        XCTAssertEqual(IOSPhoneControlToolExecutor.completionActivity(request: .act(.tap(ref: "ref")), outcome: .outcomeUnknown([])), .outcomeUnknown)
        XCTAssertEqual(IOSPhoneControlToolExecutor.completionActivity(request: .observe(maxNodes: 1, includeScreenshot: false), outcome: .denied("no access")), .failed)
        XCTAssertEqual(IOSPhoneControlToolExecutor.completionActivity(request: .stop, outcome: .filled("stopped")), .stopped)
    }

    func testObservationDefaultsToTreeAndEnforcesAdvertisedBounds() throws {
        XCTAssertEqual(
            try IOSPhoneControlToolExecutor.request(name: "phone_observe", arguments: "{}"),
            .observe(maxNodes: 500, includeScreenshot: false)
        )
        XCTAssertEqual(
            try IOSPhoneControlToolExecutor.request(name: "phone_observe", arguments: #"{"max_nodes":1,"include_screenshot":true}"#),
            .observe(maxNodes: 1, includeScreenshot: true)
        )
        XCTAssertEqual(
            try IOSPhoneControlToolExecutor.request(name: "phone_observe", arguments: #"{"max_nodes":2000}"#),
            .observe(maxNodes: 2000, includeScreenshot: false)
        )
        for invalid in [
            #"{"max_nodes":0}"#, #"{"max_nodes":2001}"#,
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
        var phases: [AgentPhoneControlActivityPhase] = []
        let executor = IOSPhoneControlToolExecutor(runID: "run-start", controller: controller) { phases.append($0) }

        let first = await executor.execute(name: "phone_observe", arguments: "{}", isUserInitiated: true)
        guard case .failed(let firstText) = first else { return XCTFail("startup failure must be a normal failed tool result") }
        let firstObject = try decodedObject(firstText)
        XCTAssertEqual(firstObject["outcome"] as? String, "not_sent")
        XCTAssertEqual(firstObject["retry_safe"] as? Bool, false)
        XCTAssertEqual(firstObject["code"] as? String, "phone_control_start_failed")
        XCTAssertTrue((firstObject["message"] as? String)?.contains("未发送任何手机动作") == true)
        XCTAssertNil(controller.ownerRunID, "startup failure must await owner cleanup")
        XCTAssertEqual(phases, [.connecting, .failed])
        XCTAssertTrue(controller.enabled, "A failed startup must not disable future user-started tasks")

        let second = await executor.execute(name: "phone_observe", arguments: "{}", isUserInitiated: true)
        guard case .denied(let secondText) = second else { return XCTFail("a cleaned run must not restart from a second tool call") }
        XCTAssertEqual(try decodedObject(secondText)["code"] as? String, "run_not_authorized")
    }

    func testApplicationToolArgumentsHaveBoundedPaginationAndExactIDs() throws {
        XCTAssertEqual(try IOSPhoneControlToolExecutor.request(name: "phone_apps", arguments: "{}"),
                       .apps(query: "", offset: 0, limit: 50))
        XCTAssertEqual(try IOSPhoneControlToolExecutor.request(name: "phone_apps", arguments: #"{"query":" Office ","offset":5,"limit":100}"#),
                       .apps(query: "Office", offset: 5, limit: 100))
        XCTAssertEqual(try IOSPhoneControlToolExecutor.request(name: "phone_add_app", arguments: #"{"bundle_id":"com.example.office"}"#),
                       .addApp(bundleID: "com.example.office"))
        for arguments in [#"{"limit":101}"#, #"{"limit":0}"#, #"{"offset":-1}"#, #"{"query":1}"#, #"{"launch":true}"#] {
            XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_apps", arguments: arguments))
        }
        for arguments in ["{}", #"{"bundle_id":""}"#, #"{"bundle_id":"Office App"}"#, #"{"bundle_id":"app.valid","launch":true}"#] {
            XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_add_app", arguments: arguments))
        }
    }

    @MainActor
    func testApplicationToolsSearchPageAndAddInSameRunWithoutStartingRunner() async throws {
        let suite = "IOSPhoneControlToolExecutorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = IOSPhoneControlController(
            defaults: defaults, credentials: ToolExecutorPairingStore(data: Data([1])),
            applications: ToolApplicationDiscovery(applications: [
                PhoneControlInstalledApp(bundleID: "app.office.beta", name: "Office Beta", isSystem: false),
                PhoneControlInstalledApp(bundleID: "app.office.alpha", name: "Office Alpha", isSystem: false),
                PhoneControlInstalledApp(bundleID: "com.apple.notes", name: "Notes", isSystem: true),
            ]), localTunnel: PhoneControlTunnelStub()
        )
        controller.enabled = true
        XCTAssertTrue(controller.claim(runID: "apps", onStop: {}))
        var phases: [AgentPhoneControlActivityPhase] = []
        let executor = IOSPhoneControlToolExecutor(runID: "apps", controller: controller) { phases.append($0) }
        let first = await executor.execute(name: "phone_apps", arguments: #"{"query":"OFFICE","limit":1}"#, isUserInitiated: true)
        guard case .filled(let firstText) = first else { return XCTFail("Application catalog should succeed") }
        let firstObject = try decodedObject(firstText)
        XCTAssertEqual(firstObject["total"] as? Int, 2)
        XCTAssertEqual(firstObject["has_more"] as? Bool, true)
        let firstPage = try XCTUnwrap(firstObject["applications"] as? [[String: Any]])
        XCTAssertEqual(firstPage.first?["bundle_id"] as? String, "app.office.alpha")
        XCTAssertEqual(firstPage.first?["selected"] as? Bool, false)
        XCTAssertEqual(controller.phase, .authorized)
        XCTAssertEqual(phases, [.listingApps, .waitingForModel])

        let add = await executor.execute(name: "phone_add_app", arguments: #"{"bundle_id":"app.office.beta"}"#, isUserInitiated: true)
        guard case .filled(let addText) = add else { return XCTFail("A catalog ID should be addable immediately") }
        XCTAssertEqual(try decodedObject(addText)["selected"] as? Bool, true)
        XCTAssertTrue(controller.statusText(runID: "apps").contains("scope=app.office.beta"))
        XCTAssertEqual(Array(phases.suffix(2)), [.addingApp, .waitingForModel])
        let second = await executor.execute(name: "phone_apps", arguments: #"{"query":"app.office","offset":1,"limit":1}"#, isUserInitiated: true)
        guard case .filled(let secondText) = second else { return XCTFail("The next application page should succeed") }
        let secondObject = try decodedObject(secondText)
        XCTAssertEqual(secondObject["has_more"] as? Bool, false)
        let secondPage = try XCTUnwrap(secondObject["applications"] as? [[String: Any]])
        XCTAssertEqual(secondPage.first?["bundle_id"] as? String, "app.office.beta")
        XCTAssertEqual(secondPage.first?["selected"] as? Bool, true)
        let invalid = await executor.execute(name: "phone_add_app", arguments: #"{"bundle_id":"app.invented"}"#, isUserInitiated: true)
        guard case .failed = invalid else { return XCTFail("An invented application must be rejected") }
        XCTAssertEqual(phases.last, .failed)
        XCTAssertEqual(controller.selectedBundleIDs, ["app.office.beta"])
        XCTAssertEqual(controller.phase, .authorized, "Metadata tools must not create an XCTest session")
        await controller.stop(runID: "apps")
        let stale = await executor.execute(name: "phone_add_app", arguments: #"{"bundle_id":"app.office.alpha"}"#, isUserInitiated: true)
        guard case .denied = stale else { return XCTFail("Stopped runs cannot add applications") }
        XCTAssertEqual(controller.selectedBundleIDs, ["app.office.beta"])
    }

    func testStopReportsFailedCleanupWhenCatalogTunnelDoesNotDisconnect() async throws {
        let suite = "IOSPhoneControlToolExecutorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tunnel = PhoneControlTunnelStub()
        tunnel.stopOperation = { _ in false }
        let controller = IOSPhoneControlController(defaults: defaults,
            credentials: ToolExecutorPairingStore(data: Data([1])),
            applications: ToolApplicationDiscovery(applications: []), localTunnel: tunnel)
        controller.enabled = true
        XCTAssertTrue(controller.claim(runID: "cleanup", onStop: {}))
        var phases: [AgentPhoneControlActivityPhase] = []
        let executor = IOSPhoneControlToolExecutor(runID: "cleanup", controller: controller) { phases.append($0) }
        let query = await executor.execute(name: "phone_apps", arguments: "{}", isUserInitiated: true)
        guard case .failed = query else { return XCTFail("Physical disconnect failure must fail the query") }
        let stopped = await executor.execute(name: "phone_stop", arguments: "{}", isUserInitiated: true)
        guard case .failed(let text) = stopped else { return XCTFail("Stop must not claim successful cleanup") }
        let result = try decodedObject(text)
        XCTAssertEqual(result["outcome"] as? String, "stopped", "Actions were revoked even though transport cleanup failed")
        XCTAssertEqual(result["cleanup_complete"] as? Bool, false)
        XCTAssertEqual(result["retry_safe"] as? Bool, false)
        XCTAssertEqual(result["code"] as? String, "phone_control_cleanup_failed")
        XCTAssertEqual(phases.last, .failed)
        XCTAssertNil(controller.ownerRunID)
    }

    private func makeClaimedController(runID: String) async throws -> (IOSPhoneControlController, UserDefaults, String) {
        let suite = "IOSPhoneControlToolExecutorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let controller = IOSPhoneControlController(
            defaults: defaults,
            credentials: ToolExecutorPairingStore(data: Data([1])),
            localTunnel: PhoneControlTunnelStub()
        )
        await controller.refreshPreparation()
        controller.enabled = true
        controller.selectedBundleIDs = ["app.test"]
        XCTAssertTrue(controller.claim(runID: runID, onStop: {}))
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

private actor ToolApplicationDiscovery: PhoneControlApplicationDiscovering {
    let applications: [PhoneControlInstalledApp]
    init(applications: [PhoneControlInstalledApp]) { self.applications = applications }
    func installedApplications(pairing: Data) -> [PhoneControlInstalledApp] { applications }
}
