import AmberPhoneControl
import Foundation
import XCTest
@testable import iosApp

@MainActor
final class IOSPhoneFlowTests: XCTestCase {
    func testTwoStepsReuseVerifiedFreshTreeAndNeedOnlyOneInitialObservation() async {
        let fixture = Fixture([
            observation("initial", [node("open-old", id: "open"), node("next-old", id: "next")]),
            observation("opened", [node("next-fresh", id: "next")]),
            observation("finished", [node("done-fresh", id: "done")]),
        ])
        fixture.useSettledObservation = true

        let result = await fixture.flow().run(twoSteps())

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(fixture.actions, [.tap(ref: "open-old"), .tap(ref: "next-fresh")])
        XCTAssertEqual(fixture.plainObserveCount, 1)
        XCTAssertEqual(fixture.settledObserveCount, 2)
        XCTAssertEqual(result.observation?.observationID, "finished")
        XCTAssertEqual(result.steps.map(\.index), [0, 1])
        XCTAssertEqual(result.steps.map(\.outcome), ["completed", "completed"])
        XCTAssertEqual(result.steps.map(\.verification?.status), [.satisfied, .satisfied])
        XCTAssertEqual(result.verification?.status, .satisfied)
        XCTAssertEqual(result.metrics.actionCount, 2)
        XCTAssertEqual(result.metrics.observationCount, 3)
        // Flow Dependencies deliberately has no Jev mode, choose, or advise input.
    }

    func testPostconditionWaitRepeatsOnlyReadAndOnlyFirstReadUsesSettledObservation() async {
        let fixture = Fixture([
            observation("initial", [node("open", id: "open")]),
            observation("loading", [node("loading", id: "loading")]),
            observation("loaded", [node("done", id: "done")]),
        ])
        fixture.useSettledObservation = true

        let result = await fixture.flow().run(oneStep())

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(fixture.actions, [.tap(ref: "open")])
        XCTAssertEqual(fixture.plainObserveCount, 2)
        XCTAssertEqual(fixture.settledObserveCount, 1)
        XCTAssertEqual(fixture.waitCount, 1)
        XCTAssertEqual(result.steps.first?.verification?.status, .satisfied)
    }

    func testKnownPracticeAnswerChecksEnabledAndCorrectFeedbackBeforeContinuingToNewQuestion() async {
        let initial = observation("question", [node("answer-old", id: "answer"),
                                                node("check-disabled", id: "check", enabled: false)])
        let checkVisible = IOSPhoneGoalExpectation(kind: .visible, target: .init(identifier: "check"))
        let checkEnabled = IOSPhoneGoalExpectation(kind: .enabled, target: .init(identifier: "check"))
        XCTAssertEqual(IOSPhoneGoalVerification.evaluate(expectation: checkVisible, before: nil,
                                                         after: initial).status, .satisfied)
        XCTAssertEqual(IOSPhoneGoalVerification.evaluate(expectation: checkEnabled, before: nil,
                                                         after: initial).status, .unmet)
        let fixture = Fixture([
            initial,
            observation("answered", [node("check-fresh", id: "check")]),
            observation("correct", [node(nil, id: "known-correct-feedback", type: "XCUIElementTypeStaticText"),
                                     node("continue-fresh", id: "continue")]),
            observation("new-question", [node(nil, id: "new-question")]),
        ])
        fixture.useSettledObservation = true

        let result = await fixture.flow().run(knownPracticeAnswer())

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(fixture.actions, [.tap(ref: "answer-old"), .tap(ref: "check-fresh"),
                                         .tap(ref: "continue-fresh")])
        XCTAssertEqual(result.steps.map(\.verification?.status), [.satisfied, .satisfied, .satisfied])
        XCTAssertEqual(result.steps.first?.verification?.reason, "target_enabled")
        XCTAssertEqual(result.verification?.status, .satisfied)
        XCTAssertEqual(result.observation?.observationID, "new-question")
        XCTAssertEqual(fixture.plainObserveCount, 1)
        XCTAssertEqual(fixture.settledObserveCount, 3)
        XCTAssertEqual(result.metrics.actionCount, 3)
        // No Jev callback exists in Flow Dependencies; only the known current question is executed.
    }

    func testWrongPracticeFeedbackKeepsCheckReceiptAndNeverDispatchesContinue() async {
        let fixture = Fixture([
            observation("question", [node("answer", id: "answer"), node("check-old", id: "check", enabled: false)]),
            observation("answered", [node("check-fresh", id: "check")]),
        ] + (1...4).map { index in
            observation("wrong-\(index)", [node(nil, id: "wrong-feedback", type: "XCUIElementTypeStaticText"),
                                          node("continue-\(index)", id: "continue")])
        })

        let result = await fixture.flow().run(knownPracticeAnswer())

        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.reason, "step_verification_failed: target_not_visible")
        XCTAssertEqual(result.steps.map(\.index), [0, 1])
        XCTAssertEqual(result.steps.map(\.outcome), ["completed", "completed"])
        XCTAssertEqual(result.steps.last?.verification?.status, .unmet)
        XCTAssertEqual(fixture.actions, [.tap(ref: "answer"), .tap(ref: "check-fresh")])
        XCTAssertEqual(fixture.waitCount, 3)
        XCTAssertEqual(result.observation?.observationID, "wrong-4")
    }

    func testStillDisabledCheckCannotAdvanceEvenWhenVisibleInEveryFreshTree() async {
        let fixture = Fixture([
            observation("question", [node("answer", id: "answer"), node("check-old", id: "check", enabled: false)]),
        ] + (1...4).map { index in
            observation("unchanged-\(index)", [node("check-\(index)", id: "check", enabled: false)])
        })

        let result = await fixture.flow().run(knownPracticeAnswer())

        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.reason, "step_verification_failed: target_disabled")
        XCTAssertEqual(result.steps.map(\.outcome), ["completed"])
        XCTAssertEqual(result.steps.first?.verification?.status, .unmet)
        XCTAssertEqual(fixture.actions, [.tap(ref: "answer")])
        XCTAssertEqual(fixture.observeCount, 5)
    }

    func testUnmetPostconditionStopsAfterBoundedReadsWithoutReplayingOrAdvancing() async {
        let fixture = Fixture([
            observation("initial", [node("open", id: "open")]),
            observation("poll-1", [node("loading", id: "loading")]),
            observation("poll-2", [node("loading", id: "loading")]),
            observation("poll-3", [node("loading", id: "loading")]),
            observation("poll-4", [node("loading", id: "loading")]),
        ])

        let result = await fixture.flow().run(twoSteps())

        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.reason, "step_verification_failed: target_not_visible")
        XCTAssertEqual(result.steps.count, 1)
        XCTAssertEqual(result.steps.first?.outcome, "completed")
        XCTAssertEqual(result.steps.first?.verification?.status, .unmet)
        XCTAssertEqual(fixture.actions, [.tap(ref: "open")])
        XCTAssertEqual(fixture.observeCount, 5)
        XCTAssertEqual(fixture.waitCount, 3)
        XCTAssertEqual(result.observation?.observationID, "poll-4")
    }

    func testAmbiguousTargetCannotDispatch() async {
        let fixture = Fixture([observation("initial", [node("one", id: "open"), node("two", id: "open")])])

        let result = await fixture.flow().run(oneStep())

        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.reason, "step_not_executable")
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertTrue(result.steps.isEmpty)
    }

    func testSameExplicitTargetInSeparateStepsUsesEachNewRefAndExecutesOncePerStep() async {
        let operation = IOSPhoneGoalActionSpec(action: .tap, target: .init(identifier: "open"))
        let request = IOSPhoneFlowRequest(goal: "依次打开两页", bundleID: "app.test", steps: [
            .init(operation: operation, expectation: visible("page-1")),
            .init(operation: operation, expectation: visible("done")),
        ], completion: visible("done"))
        let fixture = Fixture([
            observation("initial", [node("first", id: "open")]),
            observation("page-1", [node("second", id: "open"), node(nil, id: "page-1")]),
            observation("done", [node(nil, id: "done")]),
        ])

        let result = await fixture.flow().run(request)

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(fixture.actions, [.tap(ref: "first"), .tap(ref: "second")])
        XCTAssertEqual(result.steps.map(\.index), [0, 1])
    }

    func testTypingRequiresEmptyReadableNonsecureField() async {
        let request = IOSPhoneFlowRequest(goal: "填写搜索词", bundleID: "app.test", steps: [
            .init(operation: .init(action: .type, target: .init(identifier: "input"), text: "Amber"),
                  expectation: .init(kind: .valueEquals, target: .init(identifier: "input"), value: "Amber")),
        ], completion: .init(kind: .valueEquals, target: .init(identifier: "input"), value: "Amber"))
        for field in [
            node("ref", id: "input", type: "XCUIElementTypeTextField", value: "existing"),
            node("ref", id: "input", type: "XCUIElementTypeTextField", value: nil),
            node("ref", id: "input", type: "XCUIElementTypeSecureTextField", value: ""),
        ] {
            let fixture = Fixture([observation("initial", [field])])
            let result = await fixture.flow().run(request)
            XCTAssertEqual(result.status, .handback)
            XCTAssertTrue(fixture.actions.isEmpty)
        }
        let allowed = Fixture([
            observation("before", [node("fresh-input", id: "input", type: "XCUIElementTypeTextField", value: "")]),
            observation("after", [node("after-input", id: "input", type: "XCUIElementTypeTextField", value: "Amber")]),
        ])
        let result = await allowed.flow().run(request)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(allowed.actions, [.type(ref: "fresh-input", text: "Amber")])
    }

    func testTruncatedDisabledOffscreenOrMissingGeometryCannotDispatch() async {
        let screens = [
            observation("truncated", [node("ref", id: "open")], truncated: true),
            observation("disabled", [node("ref", id: "open", enabled: false)]),
            observation("offscreen", [node("ref", id: "open", y: 1_000)]),
            observation("no-bounds", [node("ref", id: "open")], bounds: nil),
            observation("no-ref", [node(nil, id: "open")]),
        ]
        for screen in screens {
            let fixture = Fixture([screen])
            let result = await fixture.flow().run(oneStep())
            XCTAssertEqual(result.status, .handback)
            XCTAssertTrue(fixture.actions.isEmpty)
        }
    }

    func testUnknownPreservesTypedProblemAndStopsWithoutAnyFollowupRead() async {
        let problem = PhoneControlProblem(.transport, "ack lost", statusCode: 502)
        let fixture = Fixture([observation("initial", [node("ref", id: "open")])])
        fixture.receipts = [.unknown(problem)]

        let result = await fixture.flow().run(oneStep())

        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.unknownProblem, problem)
        XCTAssertEqual(result.steps, [.init(index: 0, outcome: "unknown")])
        XCTAssertEqual(fixture.observeCount, 1)
        XCTAssertEqual(fixture.actions.count, 1)
        XCTAssertNil(result.observation)
        XCTAssertNil(result.verification)
    }

    func testUnsentStopsWithoutVerificationRead() async {
        let fixture = Fixture([observation("initial", [node("ref", id: "open")])])
        fixture.receipts = [.unsent(.init(.staleObservation, "target changed"))]

        let result = await fixture.flow().run(oneStep())

        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.steps, [.init(index: 0, outcome: "unsent")])
        XCTAssertEqual(fixture.observeCount, 1)
        XCTAssertNil(result.observation)
    }

    func testOwnerRevocationDuringActionActivityPreventsDispatch() async {
        let fixture = Fixture([observation("initial", [node("ref", id: "open")])])
        fixture.onActivity = { if case .tapping = $0 { fixture.current = false } }

        let result = await fixture.flow().run(oneStep())

        XCTAssertEqual(result.reason, "task_stopped")
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.observeCount, 1)
    }

    func testOwnerRevocationAfterReceiptPreservesAcknowledgedStepAndDoesNotObserve() async {
        let fixture = Fixture([observation("initial", [node("ref", id: "open")])])
        fixture.onAct = { fixture.current = false }

        let result = await fixture.flow().run(oneStep())

        XCTAssertEqual(result.reason, "task_stopped")
        XCTAssertEqual(result.steps, [.init(index: 0, outcome: "completed")])
        XCTAssertEqual(fixture.actions.count, 1)
        XCTAssertEqual(fixture.observeCount, 1)
        XCTAssertNil(result.observation)
    }

    func testCancellationAfterReceiptPreservesAcknowledgedStepAndDoesNotObserve() async {
        let fixture = Fixture([observation("initial", [node("ref", id: "open")])])
        fixture.onAct = { withUnsafeCurrentTask { $0?.cancel() } }
        let request = oneStep()
        let result = await Task { await fixture.flow().run(request) }.value

        XCTAssertEqual(result.reason, "task_stopped")
        XCTAssertEqual(result.steps, [.init(index: 0, outcome: "completed")])
        XCTAssertEqual(fixture.observeCount, 1)
        XCTAssertNil(result.observation)
    }

    func testOwnerRevocationDuringVerificationWaitStopsReadPolling() async {
        let fixture = Fixture([
            observation("initial", [node("ref", id: "open")]),
            observation("loading", [node("loading", id: "loading")]),
        ])
        fixture.onWait = { fixture.current = false }

        let result = await fixture.flow().run(oneStep())

        XCTAssertEqual(result.reason, "task_stopped")
        XCTAssertEqual(result.steps, [.init(index: 0, outcome: "completed")])
        XCTAssertEqual(fixture.actions.count, 1)
        XCTAssertEqual(fixture.observeCount, 2)
        XCTAssertEqual(fixture.waitCount, 1)
        XCTAssertNil(result.observation)
    }

    func testFailedPostActionReadKeepsReceiptButNoActionableOldObservation() async {
        let fixture = Fixture([observation("initial", [node("ref", id: "open")])])

        let result = await fixture.flow().run(oneStep())

        XCTAssertEqual(result.status, .handback)
        XCTAssertTrue(result.reason.hasPrefix("observation_interrupted:"))
        XCTAssertEqual(result.steps, [.init(index: 0, outcome: "completed")])
        XCTAssertNil(result.observation)
        XCTAssertEqual(fixture.actions.count, 1)
        XCTAssertEqual(fixture.observeCount, 2)
    }

    func testSixtySecondBudgetEndsAfterReceiptBeforePostActionRead() async {
        let fixture = Fixture([observation("initial", [node("ref", id: "open")])])
        fixture.actionDuration = 60

        let result = await fixture.flow().run(oneStep())

        XCTAssertEqual(result.reason, "time_budget_exhausted")
        XCTAssertEqual(result.steps, [.init(index: 0, outcome: "completed")])
        XCTAssertEqual(fixture.observeCount, 1)
        XCTAssertEqual(result.metrics.actionMs, 60_000, accuracy: 0.001)
        XCTAssertEqual(result.metrics.totalMs, 60_000, accuracy: 0.001)
    }

    func testSixtySecondBudgetReachedInInitialReadPreventsDispatch() async {
        let fixture = Fixture([observation("initial", [node("ref", id: "open")])])
        fixture.observationDuration = 60

        let result = await fixture.flow().run(oneStep())

        XCTAssertEqual(result.reason, "time_budget_exhausted")
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertNil(result.observation)
        XCTAssertEqual(result.metrics.observationMs, 60_000, accuracy: 0.001)
    }

    func testChangedAppProcessBackendOrBoundsStopsBeforeNextAction() async {
        let changed = [
            observation("after", [node("next", id: "next")], bundleID: "app.other"),
            observation("after", [node("next", id: "next")], pid: 99),
            observation("after", [node("next", id: "next")], backend: "other"),
            observation("after", [node("next", id: "next")], bounds: .init(x: 0, y: 0, width: 874, height: 402)),
        ]
        for after in changed {
            let fixture = Fixture([observation("initial", [node("ref", id: "open")]), after])
            let result = await fixture.flow().run(twoSteps())
            XCTAssertEqual(result.status, .handback)
            XCTAssertEqual(fixture.actions, [.tap(ref: "ref")])
            XCTAssertEqual(result.steps, [.init(index: 0, outcome: "completed")])
            XCTAssertNil(result.observation)
            XCTAssertEqual(fixture.observeCount, 2)
        }
    }

    func testRepeatedObservationIdentifierCannotAdvanceFlowEvenWithChangedContent() async {
        let fixture = Fixture([
            observation("same", [node("open", id: "open")]),
            observation("same", [node("next", id: "next")]),
        ])

        let result = await fixture.flow().run(twoSteps())

        XCTAssertEqual(result.reason, "fresh_observation_required")
        XCTAssertEqual(fixture.actions, [.tap(ref: "open")])
        XCTAssertEqual(result.steps, [.init(index: 0, outcome: "completed")])
        XCTAssertNil(result.observation)
    }

    func testFinalCompletionIsRequiredAfterAllStepPostconditions() async {
        let fixture = Fixture([
            observation("initial", [node("open", id: "open")]),
            observation("after", [node("next", id: "next")]),
        ])
        let request = IOSPhoneFlowRequest(goal: "打开结果", bundleID: "app.test", steps: [
            .init(operation: .init(action: .tap, target: .init(identifier: "open")), expectation: visible("next")),
        ], completion: visible("done"))

        let result = await fixture.flow().run(request)

        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.reason, "completion_not_satisfied: target_not_visible")
        XCTAssertEqual(result.steps.first?.verification?.status, .satisfied)
        XCTAssertEqual(result.verification?.status, .unmet)
        XCTAssertEqual(fixture.actions.count, 1)
        XCTAssertEqual(fixture.observeCount, 2)
    }

    func testCompletionAlreadyVisibleDoesNotSkipExplicitRemainingSteps() async {
        let fixture = Fixture([
            observation("initial", [node("open", id: "open"), node(nil, id: "done")]),
            observation("after", [node("next", id: "next"), node(nil, id: "done")]),
            observation("finished", [node(nil, id: "done")]),
        ])

        let result = await fixture.flow().run(twoSteps())

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(fixture.actions, [.tap(ref: "open"), .tap(ref: "next")])
        XCTAssertEqual(result.steps.count, 2)
    }

    func testFinalAbsentCompletionUsesLastStepBeforeEvidence() async {
        let absence = IOSPhoneGoalExpectation(kind: .absent, target: .init(identifier: "dialog"),
                                             anchor: .init(identifier: "done"))
        let request = IOSPhoneFlowRequest(goal: "关闭弹窗", bundleID: "app.test", steps: [
            .init(operation: .init(action: .tap, target: .init(identifier: "close")), expectation: visible("done")),
        ], completion: absence)
        let fixture = Fixture([
            observation("before", [node("close", id: "close"), node(nil, id: "dialog")]),
            observation("after", [node(nil, id: "done")]),
        ])

        let result = await fixture.flow().run(request)

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.verification?.reason, "target_disappeared_with_visible_anchor")

        let notPreviouslyVisible = Fixture([
            observation("before", [node("close", id: "close")]),
            observation("after", [node(nil, id: "done")]),
        ])
        let refused = await notPreviouslyVisible.flow().run(request)
        XCTAssertEqual(refused.status, .handback)
        XCTAssertEqual(refused.verification?.reason, "target_not_previously_visible")
    }

    func testFinalAbsentDoesNotBorrowEarlierStepEvidence() async {
        let absence = IOSPhoneGoalExpectation(kind: .absent, target: .init(identifier: "dialog"),
                                             anchor: .init(identifier: "done"))
        let base = twoSteps()
        let request = IOSPhoneFlowRequest(goal: base.goal, bundleID: base.bundleID,
                                          steps: base.steps, completion: absence)
        let fixture = Fixture([
            observation("initial", [node("open", id: "open"), node(nil, id: "dialog")]),
            observation("opened", [node("next", id: "next")]),
            observation("finished", [node(nil, id: "done")]),
        ])

        let result = await fixture.flow().run(request)

        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.verification?.reason, "target_not_previously_visible")
        XCTAssertEqual(result.steps.count, 2)
    }

    func testValidationRejectsInvalidStepsExpectationsAndBudgetsBeforeObservation() async throws {
        let valid = oneStep()
        let invalidRequests = [
            IOSPhoneFlowRequest(goal: " ", bundleID: valid.bundleID, steps: valid.steps, completion: valid.completion),
            IOSPhoneFlowRequest(goal: valid.goal, bundleID: "app. test", steps: valid.steps, completion: valid.completion),
            IOSPhoneFlowRequest(goal: valid.goal, bundleID: valid.bundleID, steps: [], completion: valid.completion),
            IOSPhoneFlowRequest(goal: valid.goal, bundleID: valid.bundleID,
                                steps: Array(repeating: valid.steps[0], count: 13), completion: valid.completion),
            IOSPhoneFlowRequest(goal: valid.goal, bundleID: valid.bundleID, steps: [
                .init(operation: .init(action: .type, target: .init(identifier: "input"), text: ""),
                      expectation: visible("done")),
            ], completion: valid.completion),
            IOSPhoneFlowRequest(goal: valid.goal, bundleID: valid.bundleID, steps: [
                .init(operation: valid.steps[0].operation,
                      expectation: .init(kind: .absent, target: .init(identifier: "dialog"))),
            ], completion: valid.completion),
        ]
        for request in invalidRequests {
            let fixture = Fixture([])
            let result = await fixture.flow().run(request)
            XCTAssertEqual(result.status, .handback)
            XCTAssertTrue(result.reason.hasPrefix("invalid_request:"))
            XCTAssertTrue(fixture.actions.isEmpty)
            XCTAssertEqual(fixture.observeCount, 0)
        }
        let twelve = IOSPhoneFlowRequest(goal: valid.goal, bundleID: valid.bundleID,
                                        steps: Array(repeating: valid.steps[0], count: 12), completion: valid.completion)
        XCTAssertNoThrow(try twelve.validate())
    }

    func testMetricsIncludeFailedReadsWaitAndDispatchWithStableJSONKeys() async throws {
        let fixture = Fixture([
            observation("initial", [node("open", id: "open")]),
            observation("loading", [node("loading", id: "loading")]),
        ])
        fixture.observationDuration = 0.01
        fixture.actionDuration = 0.02
        fixture.waitDuration = 0.03

        let result = await fixture.flow().run(oneStep())

        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.metrics.observationMs, 30, accuracy: 0.001)
        XCTAssertEqual(result.metrics.actionMs, 20, accuracy: 0.001)
        XCTAssertEqual(result.metrics.waitMs, 30, accuracy: 0.001)
        XCTAssertEqual(result.metrics.totalMs, 80, accuracy: 0.001)
        XCTAssertEqual(result.metrics.actionCount, 1)
        XCTAssertEqual(result.metrics.observationCount, 3)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result.metrics)) as? [String: NSNumber])
        XCTAssertEqual(Set(json.keys), ["total_ms", "action_ms", "observation_ms", "wait_ms", "action_count", "observation_count"])
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result.steps[0])) as? [String: Any])
        XCTAssertEqual(receipt["index"] as? Int, 0)
        XCTAssertEqual(receipt["outcome"] as? String, "completed")
        XCTAssertNil(receipt["verification"])
    }

    func testRequestJSONRoundTripUsesBundleIDKeyAndNoReferences() throws {
        let request = twoSteps()
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(IOSPhoneFlowRequest.self, from: data), request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["bundle_id"] as? String, "app.test")
        XCTAssertNil(json["bundleID"])
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.contains("\"ref\""))
        XCTAssertFalse(encoded.contains("\"observation_id\""))
    }

    private func oneStep() -> IOSPhoneFlowRequest {
        .init(goal: "打开结果", bundleID: "app.test", steps: [
            .init(operation: .init(action: .tap, target: .init(identifier: "open")), expectation: visible("done")),
        ], completion: visible("done"))
    }

    private func knownPracticeAnswer() -> IOSPhoneFlowRequest {
        // This fixture assumes the exact correct-feedback identifier was already observed.
        .init(goal: "完成当前已确定答案并到下一题边界", bundleID: "app.test", steps: [
            .init(operation: .init(action: .tap, target: .init(identifier: "answer")),
                  expectation: .init(kind: .enabled, target: .init(identifier: "check"))),
            .init(operation: .init(action: .tap, target: .init(identifier: "check")),
                  expectation: visible("known-correct-feedback")),
            .init(operation: .init(action: .tap, target: .init(identifier: "continue")),
                  expectation: visible("new-question")),
        ], completion: visible("new-question"))
    }

    private func twoSteps() -> IOSPhoneFlowRequest {
        .init(goal: "依次打开结果", bundleID: "app.test", steps: [
            .init(operation: .init(action: .tap, target: .init(identifier: "open")), expectation: visible("next")),
            .init(operation: .init(action: .tap, target: .init(identifier: "next")), expectation: visible("done")),
        ], completion: visible("done"))
    }

    private func visible(_ id: String) -> IOSPhoneGoalExpectation {
        .init(kind: .visible, target: .init(identifier: id))
    }

    private func observation(_ id: String, _ nodes: [PhoneObservationNode], bundleID: String = "app.test",
                             pid: Int = 42, backend: String = "test", truncated: Bool = false,
                             bounds: PhoneElementRect? = .init(x: 0, y: 0, width: 402, height: 874)) -> PhoneObservation {
        .init(observationID: id, bundleID: bundleID, processID: pid, backend: backend,
              truncated: truncated, nodes: nodes, screenBounds: bounds)
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
        var current = true
        var time: TimeInterval = 0
        var useSettledObservation = false
        var plainObserveCount = 0
        var settledObserveCount = 0
        var observeCount: Int { plainObserveCount + settledObserveCount }
        var waitCount = 0
        var observationDuration: TimeInterval = 0
        var actionDuration: TimeInterval = 0
        var waitDuration: TimeInterval = 0
        var onActivity: ((AgentPhoneControlActivityPhase) -> Void)?
        var onAct: (() -> Void)?
        var onWait: (() -> Void)?

        init(_ observations: [PhoneObservation]) { self.observations = observations }

        private func observe(settled: Bool) throws -> PhoneObservation {
            if settled { settledObserveCount += 1 } else { plainObserveCount += 1 }
            time += observationDuration
            guard !observations.isEmpty else { throw NSError(domain: "Observation fixture exhausted", code: 1) }
            return observations.removeFirst()
        }

        func flow() -> IOSPhoneFlow {
            IOSPhoneFlow(deps: .init(
                observe: { try self.observe(settled: false) },
                act: {
                    self.actions.append($0)
                    self.time += self.actionDuration
                    self.onAct?()
                    return self.receipts.isEmpty ? .completed : self.receipts.removeFirst()
                },
                isCurrent: { self.current },
                reportActivity: { self.onActivity?($0) },
                observeAfterAction: useSettledObservation ? { try self.observe(settled: true) } : nil,
                now: { self.time },
                wait: {
                    self.waitCount += 1
                    self.time += self.waitDuration
                    self.onWait?()
                }
            ))
        }
    }
}
