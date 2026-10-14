import AmberPhoneControl
import Foundation
import XCTest
@testable import iosApp

@MainActor
final class IOSPhoneGoalLoopTests: XCTestCase {
    func testNavigationAndTypingResolveFreshReferencesAndVerifyFinalBudgetedAction() async {
        let fixture = Fixture([
            observation("home", [node("home:search", id: "search")]),
            observation("search", [node("search:input", id: "query", type: "XCUIElementTypeSearchField", value: "")]),
            observation("typed", [node("typed:input", id: "query", type: "XCUIElementTypeSearchField", value: "星巴克")]),
        ])
        fixture.observeDuration = 0.01
        fixture.chooseDuration = 0.02
        fixture.actDuration = 0.03
        fixture.adviseDuration = 0.04
        let request = IOSPhoneGoalRequest(
            goal: "打开搜索并填写关键词，停在草稿", bundleID: "app.test",
            actions: [.init(action: .tap, target: .init(identifier: "search")),
                      .init(action: .type, target: .init(identifier: "query"), text: "星巴克")],
            completion: .init(kind: .valueEquals, target: .init(identifier: "query"), value: "星巴克"), maxSteps: 2
        )
        let result = await fixture.loop().run(request)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.verification?.status, .satisfied)
        XCTAssertEqual(result.observation?.observationID, "typed")
        XCTAssertEqual(fixture.actions, [.tap(ref: "home:search"), .type(ref: "search:input", text: "星巴克")])
        XCTAssertEqual(fixture.candidateBatches, [["a0"], ["a1"]])
        XCTAssertEqual(fixture.observeCount, 3)
        XCTAssertEqual(fixture.adviceCount, 0, "A fresh next candidate is assessed by the next choice, without a separate remote review")
        XCTAssertEqual(result.steps, ["a0: completed", "a1: completed"])
        XCTAssertEqual(result.reasonCode, .completed)
        XCTAssertEqual(result.candidateDiagnostics.map(\.reasonCode), [.alreadyExecuted, .alreadyExecuted])
        XCTAssertEqual(result.metrics.observeMs, 30, accuracy: 0.001)
        XCTAssertEqual(result.metrics.chooseMs, 40, accuracy: 0.001)
        XCTAssertEqual(result.metrics.actMs, 60, accuracy: 0.001)
        XCTAssertEqual(result.metrics.adviseMs, 0, accuracy: 0.001)
        XCTAssertEqual(result.metrics.selectionCalls, 2)
        XCTAssertEqual(result.metrics.reviewCalls, 0)
    }

    func testCompletedReceiptWithUnchangedScreenCannotBecomeSuccessOrRepeatTap() async {
        let fixture = Fixture([observation("before", [node("old", id: "search")]),
                               observation("after", [node("new", id: "search")])])
        let result = await fixture.loop().run(request())
        XCTAssertEqual(result.status, .handback)
        XCTAssertNotEqual(result.verification?.status, .satisfied)
        XCTAssertEqual(fixture.actions, [.tap(ref: "old")])
        XCTAssertEqual(fixture.chooseCount, 1)
        XCTAssertEqual(fixture.observeCount, 2)
        XCTAssertTrue(result.needsScreenshot)
        XCTAssertEqual(result.steps, ["a0: completed"])
    }

    func testFreshIntermediateCandidateStillRequiresTheNextDecision() async {
        let fixture = Fixture([
            observation("home", [node("home:search", id: "search")]),
            observation("search", [node("search:input", id: "query", type: "XCUIElementTypeSearchField", value: "")]),
        ])
        fixture.selections = [.action("a0"), .handback("needs a revised plan")]
        let request = IOSPhoneGoalRequest(
            goal: "打开搜索并填写草稿", bundleID: "app.test",
            actions: [.init(action: .tap, target: .init(identifier: "search")),
                      .init(action: .type, target: .init(identifier: "query"), text: "draft")],
            completion: .init(kind: .valueEquals, target: .init(identifier: "query"), value: "draft"))
        let result = await fixture.loop().run(request)
        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.reasonCode, .decisionHandback)
        XCTAssertEqual(fixture.actions, [.tap(ref: "home:search")])
        XCTAssertEqual(fixture.chooseCount, 2)
        XCTAssertEqual(fixture.adviceCount, 0)
        XCTAssertEqual(result.steps, ["a0: completed"])
    }

    func testIncompleteAmbiguousDisabledOrUnboundedTargetsNeverReachDecisionOrAction() async {
        let scenarios = [
            observation("truncated", [node("ref", id: "search")], truncated: true),
            observation("ambiguous", [node("one", id: "search"), node("two", id: "search")]),
            observation("disabled", [node("ref", id: "search", enabled: false)]),
            observation("no-ref", [node(nil, id: "search")]),
            observation("empty-ref", [node("", id: "search")]),
            observation("offscreen", [node("ref", id: "search", y: 1800)]),
            observation("unknown-geometry", [node("ref", id: "search")], bounds: nil),
        ]
        for screen in scenarios {
            let fixture = Fixture([screen])
            let result = await fixture.loop().run(request())
            XCTAssertEqual(result.status, .handback, screen.observationID)
            XCTAssertTrue(fixture.actions.isEmpty, screen.observationID)
            XCTAssertEqual(fixture.chooseCount, 0, screen.observationID)
        }
    }

    func testTypingNeverAppendsToNonemptyOrSecureField() async {
        let draft = IOSPhoneGoalRequest(
            goal: "填写草稿", bundleID: "app.test",
            actions: [.init(action: .type, target: .init(identifier: "query"), text: "new")],
            completion: .init(kind: .valueEquals, target: .init(identifier: "query"), value: "new")
        )
        for input in [node("ref", id: "query", type: "XCUIElementTypeTextField", value: "existing"),
                      node("ref", id: "query", type: "XCUIElementTypeTextField", value: nil),
                      node("ref", id: "query", type: "XCUIElementTypeSecureTextField", value: ""),
                      node("ref", id: "query", type: "XCUIElementTypeStaticText", value: "")] {
            let fixture = Fixture([observation("input", [input])])
            let result = await fixture.loop().run(draft)
            XCTAssertEqual(result.status, .handback)
            XCTAssertTrue(fixture.actions.isEmpty)
            XCTAssertEqual(fixture.chooseCount, 0)
        }
    }

    func testShadowNeverActsOrWaitsEvenIfDecisionRequestsIt() async {
        for selection: IOSJevPhoneControlService.Selection in [.action("a0"), .wait] {
            let fixture = Fixture([observation("initial", [node("ref", id: "search")])])
            fixture.mode = .shadow
            fixture.selections = [selection]
            let result = await fixture.loop().run(request())
            XCTAssertEqual(result.status, .handback)
            XCTAssertTrue(fixture.actions.isEmpty)
            XCTAssertEqual(fixture.chooseCount, 1)
            XCTAssertEqual(fixture.observeCount, 1)
            XCTAssertEqual(fixture.waitCount, 0)
            XCTAssertEqual(result.reasonCode, .shadowMode)
            XCTAssertEqual(result.metrics.selectionCalls, 1)
            XCTAssertEqual(result.metrics.reviewCalls, 0)
        }
    }

    func testUnknownReceiptEndsLoopWithoutPostActionObservationOrReplay() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoalLoopFailureProtocol.self]
        let runner = try PhoneRunnerClient(token: String(repeating: "a", count: 64),
                                          allowedBundleIDs: ["app.test"], sessionConfiguration: configuration)
        let unknownReceipt = await runner.act(.launch(bundleID: "app.test"))
        guard case .unknown(let problem) = unknownReceipt else { return XCTFail("Expected a dispatched failure") }
        let fixture = Fixture([observation("initial", [node("ref", id: "search")])])
        fixture.receipts = [unknownReceipt]
        let result = await fixture.loop().run(request())
        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.reasonCode, .actionOutcomeUnknown)
        XCTAssertTrue(result.candidateDiagnostics.isEmpty)
        XCTAssertEqual(result.metrics.selectionCalls, 1)
        XCTAssertEqual(result.metrics.reviewCalls, 0)
        XCTAssertEqual(result.unknownProblem, problem)
        XCTAssertNil(result.observation)
        XCTAssertEqual(result.steps, ["a0: unknown"])
        XCTAssertEqual(fixture.actions, [.tap(ref: "ref")])
        XCTAssertEqual(fixture.observeCount, 1)
        XCTAssertEqual(fixture.adviceCount, 0)
    }

    func testOwnerRevocationDuringDecisionPreventsDispatch() async {
        let fixture = Fixture([observation("initial", [node("ref", id: "search")])])
        fixture.onChoose = { fixture.current = false }
        let result = await fixture.loop().run(request())
        XCTAssertEqual(result.status, .handback)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.observeCount, 1)
    }

    func testCancellationDuringDecisionPreventsDispatch() async {
        let fixture = Fixture([observation("initial", [node("ref", id: "search")])])
        fixture.onChoose = { withUnsafeCurrentTask { $0?.cancel() } }
        let goal = request()
        let task = Task { await fixture.loop().run(goal) }
        let result = await task.value
        XCTAssertEqual(result.status, .handback)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.observeCount, 1)
    }

    func testModeChangeDuringDecisionPreventsDispatch() async {
        let fixture = Fixture([observation("initial", [node("ref", id: "search")])])
        fixture.onChoose = { fixture.mode = .off }
        let result = await fixture.loop().run(request())
        XCTAssertEqual(result.status, .handback)
        XCTAssertTrue(fixture.actions.isEmpty)
    }

    func testConfigurationRevisionChangeDuringActionActivityPreventsDispatchDespiteActiveMode() async {
        let fixture = Fixture([observation("initial", [node("ref", id: "search")])])
        fixture.onActivity = { phase in
            if case .tapping = phase { fixture.configurationRevision += 1 }
        }
        let result = await fixture.loop().run(request())
        XCTAssertEqual(fixture.mode, .active)
        XCTAssertEqual(fixture.configurationRevision, 1)
        XCTAssertEqual(result.reasonCode, .configurationChanged)
        XCTAssertEqual(fixture.chooseCount, 1)
        XCTAssertEqual(result.status, .handback)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertTrue(result.steps.isEmpty)
        XCTAssertEqual(fixture.observeCount, 1)
    }

    func testOwnerRevocationAfterReceiptPreservesExecutedStepWithoutFurtherObservation() async {
        let fixture = Fixture([observation("initial", [node("ref", id: "search")])])
        fixture.onAct = { fixture.current = false }
        let result = await fixture.loop().run(request())
        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.steps, ["a0: completed"])
        XCTAssertNil(result.observation)
        XCTAssertEqual(fixture.observeCount, 1)
    }

    func testFinalAllowedActionStillReceivesEffectVerification() async {
        let fixture = Fixture([observation("initial", [node("ref", id: "search")]),
                               observation("finished", [node("done", id: "results")])])
        let result = await fixture.loop().run(request(maxSteps: 1))
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.verification?.status, .satisfied)
        XCTAssertEqual(fixture.actions.count, 1)
        XCTAssertEqual(fixture.observeCount, 2)
        XCTAssertEqual(fixture.adviceCount, 0)
    }

    func testDecisionFailureHandsBackWithoutAnyAction() async {
        let fixture = Fixture([observation("initial", [node("ref", id: "search")])])
        fixture.selections = [.handback("provider_unavailable")]
        let result = await fixture.loop().run(request())
        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.reason, "provider_unavailable")
        XCTAssertEqual(result.reasonCode, .decisionHandback)
        XCTAssertEqual(result.metrics.selectionCalls, 1)
        XCTAssertEqual(result.metrics.reviewCalls, 0)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertTrue(result.steps.isEmpty)
    }

    func testRepeatedWaitUsesOnlyOneReadonlyRefresh() async {
        let fixture = Fixture([observation("loading", [node("first", id: "search")]),
                               observation("still-loading", [node("second", id: "search")])])
        fixture.selections = [.wait, .wait]
        let result = await fixture.loop().run(request())
        XCTAssertEqual(result.status, .handback)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.waitCount, 1)
        XCTAssertEqual(fixture.observeCount, 2)
        XCTAssertEqual(fixture.chooseCount, 2)
        XCTAssertEqual(result.reasonCode, .waitBudgetExhausted)
    }

    func testProcessRestartDuringReadonlyWaitDoesNotDispatchIntoNewProcess() async {
        let fixture = Fixture([observation("loading", [node("old", id: "search")]),
                               observation("restarted", [node("new", id: "search")], pid: 99)])
        fixture.selections = [.wait, .action("a0")]
        let result = await fixture.loop().run(request())
        XCTAssertEqual(result.status, .handback)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.chooseCount, 1)
        XCTAssertEqual(fixture.observeCount, 2)
    }

    func testConfigurationRevisionChangeDuringReadonlyWaitEndsInvocationDespiteActiveMode() async {
        let fixture = Fixture([observation("loading", [node("old", id: "search")]),
                               observation("loaded", [node("new", id: "search")])])
        fixture.selections = [.wait, .action("a0")]
        fixture.onActivity = { phase in
            if case .waitingForUI = phase { fixture.configurationRevision += 1 }
        }

        let result = await fixture.loop().run(request())

        XCTAssertEqual(fixture.mode, .active)
        XCTAssertTrue(fixture.current)
        XCTAssertEqual(fixture.configurationRevision, 1)
        XCTAssertEqual(result.reasonCode, .configurationChanged)
        XCTAssertEqual(result.status, .handback)
        XCTAssertTrue(result.steps.isEmpty)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.chooseCount, 1)
    }

    func testCandidateDiagnosticsDistinguishExcludedTargetsWithoutCallingJev() async {
        let screens: [(PhoneObservation, IOSPhoneGoalLoop.CandidateDiagnostic.ReasonCode)] = [
            (observation("partial", [node("ref", id: "search")], truncated: true), .treeTruncated),
            (observation("duplicate", [node("one", id: "search"), node("two", id: "search")]), .targetAmbiguous),
            (observation("missing", [node("other", id: "other")]), .targetNotVisible),
            (observation("disabled", [node("ref", id: "search", enabled: false)]), .disabled),
            (observation("no-ref", [node(nil, id: "search")]), .referenceUnavailable),
            (observation("unsupported", [node("ref", id: "search", type: "XCUIElementTypeStaticText")]), .unsupported),
            (observation("no-geometry", [node("ref", id: "search")], bounds: nil), .screenBoundsUnavailable),
        ]
        for (screen, code) in screens {
            let fixture = Fixture([screen])
            let result = await fixture.loop().run(request())
            XCTAssertEqual(result.status, .handback)
            XCTAssertEqual(result.reasonCode, screen.truncated ? .treeTruncated : .noExecutableCandidates)
            XCTAssertEqual(result.candidateDiagnostics, [.init(id: "a0", reasonCode: code)])
            XCTAssertEqual(result.metrics.selectionCalls, 0)
            XCTAssertEqual(result.metrics.reviewCalls, 0)
            XCTAssertTrue(fixture.actions.isEmpty)
        }
    }

    func testInputDiagnosticsKeepNonemptyUnreadableAndSecureFieldsDistinct() async {
        let request = IOSPhoneGoalRequest(goal: "填写草稿", bundleID: "app.test",
            actions: [.init(action: .type, target: .init(identifier: "query"), text: "new")],
            completion: .init(kind: .valueEquals, target: .init(identifier: "query"), value: "new"))
        let inputs: [(PhoneObservationNode, IOSPhoneGoalLoop.CandidateDiagnostic.ReasonCode)] = [
            (node("ref", id: "query", type: "XCUIElementTypeTextField", value: "existing"), .inputNotEmpty),
            (node("ref", id: "query", type: "XCUIElementTypeTextField", value: nil), .inputValueUnavailable),
            (node("ref", id: "query", type: "XCUIElementTypeSecureTextField", value: ""), .unsupported),
        ]
        for (input, code) in inputs {
            let fixture = Fixture([observation("input", [input])])
            let result = await fixture.loop().run(request)
            XCTAssertEqual(result.candidateDiagnostics, [.init(id: "a0", reasonCode: code)])
            XCTAssertEqual(result.reasonCode, .noExecutableCandidates)
            XCTAssertEqual(fixture.chooseCount, 0)
            XCTAssertTrue(fixture.actions.isEmpty)
        }
    }

    func testExhaustedActionsReportAlreadyExecutedWithoutRepeating() async {
        let fixture = Fixture([observation("before", [node("old", id: "search")]),
                               observation("after", [node("new", id: "search", value: "changed")])])
        let result = await fixture.loop().run(request())
        XCTAssertEqual(result.reasonCode, .actionsExhausted)
        XCTAssertEqual(result.candidateDiagnostics, [.init(id: "a0", reasonCode: .alreadyExecuted)])
        XCTAssertEqual(result.steps, ["a0: completed"])
        XCTAssertEqual(fixture.actions.count, 1)
    }

    func testModeOffAndTimeBudgetReturnStableReasonsAndAccurateServiceCounts() async {
        let off = Fixture([])
        off.mode = .off
        let offResult = await off.loop().run(request())
        XCTAssertEqual(offResult.reasonCode, .modeOff)
        XCTAssertEqual(offResult.metrics, .init())
        XCTAssertEqual(off.observeCount, 0)

        let expired = Fixture([observation("initial", [node("ref", id: "search")])])
        expired.onChoose = { expired.time += 60 }
        let expiredResult = await expired.loop().run(request())
        XCTAssertEqual(expiredResult.reasonCode, .timeBudgetExhausted)
        XCTAssertEqual(expiredResult.metrics.chooseMs, 60_000, accuracy: 0.001)
        XCTAssertEqual(expiredResult.metrics.selectionCalls, 1)
        XCTAssertTrue(expired.actions.isEmpty)
    }

    func testStepBudgetDiffersFromExhaustedCandidateList() async {
        let fixture = Fixture([observation("before", [node("old", id: "search")]),
                               observation("after", [node("new", id: "search", value: "changed")])])
        let result = await fixture.loop().run(request(maxSteps: 1))
        XCTAssertEqual(result.reasonCode, .stepBudgetExhausted)
        XCTAssertEqual(result.steps, ["a0: completed"])
        XCTAssertEqual(fixture.actions.count, 1)
    }

    func testFailedObservationStillContributesMeasuredTimeWithoutServiceCalls() async {
        let fixture = Fixture([])
        fixture.observeDuration = 0.125
        let result = await fixture.loop().run(request())
        XCTAssertEqual(result.reasonCode, .observationInterrupted)
        XCTAssertEqual(result.metrics.observeMs, 125, accuracy: 0.001)
        XCTAssertEqual(result.metrics.selectionCalls, 0)
        XCTAssertEqual(result.metrics.reviewCalls, 0)
        XCTAssertTrue(result.candidateDiagnostics.isEmpty)
    }

    func testDiagnosticAndMetricJSONUsesStableKeysWithoutUIContent() throws {
        let diagnostic = IOSPhoneGoalLoop.CandidateDiagnostic(id: "a0", reasonCode: .inputNotEmpty)
        let diagnosticJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostic)) as? [String: String])
        XCTAssertEqual(diagnosticJSON, ["id": "a0", "reason_code": "input_not_empty"])
        let metrics = IOSPhoneGoalLoop.Metrics(observeMs: 12, chooseMs: 23, actMs: 34, adviseMs: 45,
                                               selectionCalls: 2, reviewCalls: 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metrics)) as? [String: NSNumber])
        XCTAssertEqual(Set(json.keys), ["observe_ms", "choose_ms", "act_ms", "advise_ms", "wait_ms", "total_ms", "selection_calls", "review_calls"])
        XCTAssertEqual(json["selection_calls"], 2)
        XCTAssertEqual(json["review_calls"], 1)
    }

    private func request(maxSteps: Int = 6) -> IOSPhoneGoalRequest {
        .init(goal: "打开搜索结果", bundleID: "app.test", actions: [.init(action: .tap, target: .init(identifier: "search"))],
              completion: .init(kind: .visible, target: .init(identifier: "results")), maxSteps: maxSteps)
    }

    private func observation(_ id: String, _ nodes: [PhoneObservationNode], pid: Int = 42, truncated: Bool = false,
                             bounds: PhoneElementRect? = .init(x: 0, y: 0, width: 402, height: 874)) -> PhoneObservation {
        .init(observationID: id, bundleID: "app.test", processID: pid, backend: "test", truncated: truncated,
              nodes: nodes, screenBounds: bounds)
    }

    private func node(_ ref: String?, id: String, type: String = "XCUIElementTypeButton", value: String? = nil,
                      enabled: Bool = true, y: Double = 20) -> PhoneObservationNode {
        .init(ref: ref, depth: 1, type: type, identifier: id, label: nil, value: value,
              rect: .init(x: 20, y: y, width: 80, height: 44), enabled: enabled, focused: false)
    }

    @MainActor
    private final class Fixture {
        var observations: [PhoneObservation]
        var actions: [PhoneAction] = []
        var receipts: [PhoneActionResult] = []
        var selections: [IOSJevPhoneControlService.Selection] = []
        var candidateBatches: [[String]] = []
        var observeCount = 0
        var chooseCount = 0
        var adviceCount = 0
        var waitCount = 0
        var mode: IOSJevMode = .active
        var current = true
        var configurationRevision = 0
        var time: TimeInterval = 0
        var observeDuration: TimeInterval = 0
        var chooseDuration: TimeInterval = 0
        var actDuration: TimeInterval = 0
        var adviseDuration: TimeInterval = 0
        var onChoose: (() -> Void)?
        var onAct: (() -> Void)?
        var onActivity: ((AgentPhoneControlActivityPhase) -> Void)?

        init(_ observations: [PhoneObservation]) { self.observations = observations }

        func loop() -> IOSPhoneGoalLoop {
            IOSPhoneGoalLoop(deps: .init(
                observe: {
                    self.observeCount += 1
                    self.time += self.observeDuration
                    guard !self.observations.isEmpty else { throw NSError(domain: "Unexpected observation", code: 1) }
                    return self.observations.removeFirst()
                },
                act: { action in
                    self.actions.append(action)
                    self.time += self.actDuration
                    self.onAct?()
                    return self.receipts.isEmpty ? .completed : self.receipts.removeFirst()
                },
                choose: { _, _, candidates, _ in
                    self.chooseCount += 1
                    self.time += self.chooseDuration
                    self.candidateBatches.append(candidates.map(\.id))
                    self.onChoose?()
                    return self.selections.isEmpty ? .action(candidates[0].id) : self.selections.removeFirst()
                },
                advise: { _, _, _, _, _ in
                    self.adviceCount += 1
                    self.time += self.adviseDuration
                    return .continueTask
                },
                mode: { self.mode }, isCurrent: { self.current }, reportActivity: { self.onActivity?($0) },
                configurationRevision: { self.configurationRevision },
                now: { Date(timeIntervalSince1970: self.time) },
                waitForUI: { self.waitCount += 1 }
            ))
        }
    }
}

private final class GoalLoopFailureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"value":{"error":"unknown error","message":"dispatched action failed"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
