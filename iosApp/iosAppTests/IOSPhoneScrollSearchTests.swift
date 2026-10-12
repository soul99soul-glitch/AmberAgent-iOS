import AmberPhoneControl
import Foundation
import XCTest
@testable import iosApp

@MainActor
final class IOSPhoneScrollSearchTests: XCTestCase {
    func testFindsInitiallyUnseenTargetUsingFreshContainerReferences() async {
        let fixture = Fixture([
            screen("first", [container("first:list"), row("first:a", label: "Alice")]),
            screen("second", [container("second:list"), row("second:b", label: "Bob")]),
            screen("third", [container("third:list"), row("third:target", label: "Carol")]),
        ])
        let result = await fixture.search().run(request(maxSwipes: 2))
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.swipeCount, 2)
        XCTAssertEqual(result.observation?.observationID, "third")
        XCTAssertEqual(fixture.actions, [.swipe(ref: "first:list", direction: .up),
                                         .swipe(ref: "second:list", direction: .up)])
        XCTAssertEqual(fixture.observeCount, 3)
    }

    func testAlreadyVisibleTargetCompletesWithoutContainerOrMutation() async {
        let fixture = Fixture([screen("visible", [row("target", label: "Carol")])])
        let result = await fixture.search().run(request())
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.swipeCount, 0)
        XCTAssertTrue(fixture.actions.isEmpty)
    }

    func testUnchangedScreenHandsBackAfterOneSwipeDespiteNewRefs() async {
        let fixture = Fixture([screen("before", [container("old"), row("old:a", label: "Alice")]),
                               screen("after", [container("new"), row("new:a", label: "Alice")])])
        let result = await fixture.search().run(request())
        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.reason, "screen_unchanged")
        XCTAssertEqual(result.observation?.observationID, "after")
        XCTAssertEqual(result.swipeCount, 1)
        XCTAssertEqual(fixture.actions.count, 1)
        XCTAssertEqual(fixture.observeCount, 2)
    }

    func testAmbiguousTargetOrContainerAndTruncatedTreesNeverSwipe() async {
        let scenarios: [(PhoneObservation, String)] = [
            (screen("target", [container("list"), row("one", label: "Carol"), row("two", label: "Carol")]),
             "ambiguous_target"),
            (screen("container", [container("one"), container("two")]), "ambiguous_container"),
            (screen("partial", [container("list"), row("target", label: "Carol")], truncated: true), "truncated_tree"),
        ]
        for (observation, reason) in scenarios {
            let fixture = Fixture([observation])
            let result = await fixture.search().run(request())
            XCTAssertEqual(result.status, .handback)
            XCTAssertEqual(result.reason, reason)
            XCTAssertTrue(fixture.actions.isEmpty)
            XCTAssertEqual(fixture.observeCount, 1)
        }
    }

    func testMissingDisabledNonScrollableAndOffscreenContainersNeverSwipe() async {
        let scenarios = [
            screen("missing", []),
            screen("disabled", [container("list", enabled: false)]),
            screen("wrong-role", [container("list", type: "XCUIElementTypeButton")]),
            screen("offscreen", [container("list", y: 1000)]),
            screen("no-ref", [container(nil)]),
            screen("no-bounds", [container("list")], bounds: nil),
        ]
        for observation in scenarios {
            let fixture = Fixture([observation])
            let result = await fixture.search().run(request())
            XCTAssertEqual(result.status, .handback)
            XCTAssertTrue(fixture.actions.isEmpty, observation.observationID)
        }
    }

    func testCancellationDuringSwipeActivityPreventsDispatch() async {
        let fixture = Fixture([screen("initial", [container("list")])])
        fixture.onActivity = { phase in
            if phase == .swiping { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let operation = Task { await fixture.search().run(self.request()) }
        let result = await operation.value
        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.reason, "task_stopped")
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.observeCount, 1)
    }

    func testOwnerRevocationAfterReceiptDoesNotObserveOrReplay() async {
        let fixture = Fixture([screen("initial", [container("list")])])
        fixture.onAct = { fixture.current = false }
        let result = await fixture.search().run(request())
        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.swipeCount, 1)
        XCTAssertNil(result.observation)
        XCTAssertEqual(fixture.observeCount, 1)
        XCTAssertEqual(fixture.actions.count, 1)
    }

    func testUnknownSwipePreservesTypedProblemAndNeverObservesAgain() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScrollSearchFailureProtocol.self]
        let runner = try PhoneRunnerClient(token: String(repeating: "a", count: 64),
                                          allowedBundleIDs: ["app.test"], sessionConfiguration: configuration)
        let receipt = await runner.act(.launch(bundleID: "app.test"))
        guard case .unknown(let problem) = receipt else { return XCTFail("Expected dispatched failure") }
        let fixture = Fixture([screen("initial", [container("list")])])
        fixture.receipts = [receipt]
        let result = await fixture.search().run(request())
        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.unknownProblem, problem)
        XCTAssertEqual(result.swipeCount, 1)
        XCTAssertNil(result.observation)
        XCTAssertEqual(fixture.observeCount, 1)
        XCTAssertEqual(fixture.actions.count, 1)
    }

    func testFinalBudgetedSwipeStillObservesBeforeHandback() async {
        let fixture = Fixture([screen("initial", [container("old"), row("a", label: "Alice")]),
                               screen("after", [container("new"), row("b", label: "Bob")])])
        let result = await fixture.search().run(request(maxSwipes: 1))
        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.reason, "swipe_budget_exhausted")
        XCTAssertEqual(result.observation?.observationID, "after")
        XCTAssertEqual(result.swipeCount, 1)
        XCTAssertEqual(fixture.observeCount, 2)
    }

    func testReusedObservationAndForegroundChangeCannotContinueScrolling() async {
        for after in [screen("initial", [container("new"), row("b", label: "Bob")]),
                      screen("after", [container("new"), row("target", label: "Carol")], pid: 99)] {
            let fixture = Fixture([screen("initial", [container("old"), row("a", label: "Alice")]), after])
            let result = await fixture.search().run(request())
            XCTAssertEqual(result.status, .handback)
            XCTAssertEqual(fixture.actions.count, 1)
        }
    }

    func testSixtySecondContinuationBudgetPreventsDispatchAfterActivity() async {
        let fixture = Fixture([screen("initial", [container("list")])])
        fixture.onActivity = { phase in if phase == .swiping { fixture.time += 60 } }
        let result = await fixture.search().run(request())
        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.reason, "time_budget_exhausted")
        XCTAssertTrue(fixture.actions.isEmpty)
    }

    func testRequestDefaultsAndValidationRejectInvalidBoundsBeforeObservation() async throws {
        let decoded = try JSONDecoder().decode(IOSPhoneScrollSearchRequest.self, from: Data(
            #"{"target":{"label":"Carol"},"container":{"identifier":"contacts"},"direction":"up"}"#.utf8))
        XCTAssertEqual(decoded.maxSwipes, 3)
        try decoded.validate()
        for invalid in [request(maxSwipes: 0), request(maxSwipes: 9),
                        IOSPhoneScrollSearchRequest(target: .init(type: "XCUIElementTypeCell"),
                                                    container: .init(identifier: "contacts"), direction: .up)] {
            let fixture = Fixture([])
            let result = await fixture.search().run(invalid)
            XCTAssertEqual(result.status, .handback)
            XCTAssertEqual(fixture.observeCount, 0)
        }
    }

    private func request(maxSwipes: Int = 3) -> IOSPhoneScrollSearchRequest {
        .init(target: .init(label: "Carol"), container: .init(identifier: "contacts"),
              direction: .up, maxSwipes: maxSwipes)
    }

    private func screen(_ id: String, _ nodes: [PhoneObservationNode], pid: Int = 42,
                        truncated: Bool = false,
                        bounds: PhoneElementRect? = .init(x: 0, y: 0, width: 402, height: 874)) -> PhoneObservation {
        .init(observationID: id, bundleID: "app.test", processID: pid, backend: "test",
              truncated: truncated, nodes: nodes, screenBounds: bounds)
    }

    private func container(_ ref: String?, enabled: Bool = true,
                           type: String = "XCUIElementTypeTable", y: Double = 20) -> PhoneObservationNode {
        .init(ref: ref, depth: 1, type: type, identifier: "contacts", label: nil, value: nil,
              rect: .init(x: 0, y: y, width: 402, height: 700), enabled: enabled, focused: false)
    }

    private func row(_ ref: String, label: String) -> PhoneObservationNode {
        .init(ref: ref, depth: 2, type: "XCUIElementTypeCell", identifier: nil, label: label, value: nil,
              rect: .init(x: 20, y: 100, width: 300, height: 44), enabled: true, focused: false)
    }

    @MainActor
    private final class Fixture {
        var observations: [PhoneObservation]
        var actions: [PhoneAction] = []
        var receipts: [PhoneActionResult] = []
        var observeCount = 0
        var current = true
        var time: TimeInterval = 0
        var onActivity: ((AgentPhoneControlActivityPhase) -> Void)?
        var onAct: (() -> Void)?

        init(_ observations: [PhoneObservation]) { self.observations = observations }

        func search() -> IOSPhoneScrollSearch {
            .init(deps: .init(observe: {
                self.observeCount += 1
                guard !self.observations.isEmpty else { throw NSError(domain: "Unexpected observation", code: 1) }
                return self.observations.removeFirst()
            }, act: { action in
                self.actions.append(action)
                self.onAct?()
                return self.receipts.isEmpty ? .completed : self.receipts.removeFirst()
            }, isCurrent: { self.current }, reportActivity: { self.onActivity?($0) },
               now: { Date(timeIntervalSince1970: self.time) }))
        }
    }
}

private final class ScrollSearchFailureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
    override func stopLoading() {}
}
