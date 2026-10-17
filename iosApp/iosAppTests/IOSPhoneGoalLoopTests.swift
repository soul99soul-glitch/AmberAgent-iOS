import AmberPhoneControl
import Foundation
import XCTest
@testable import iosApp

@MainActor
final class IOSPhoneGoalLoopTests: XCTestCase {
    func testVisibleDisabledCompletionBeforeDispatchDependsOnGoalMode() async {
        let screen = observation("ready", [node("check", id: "check", label: "Check", enabled: false)])
        let covered = observation("covered", screen.nodes + [node("alert", id: "alert", type: "XCUIElementTypeAlert")])
        let completion = IOSPhoneGoalExpectation(kind: .visible, target: .init(label: "Check"))
        XCTAssertEqual(IOSPhoneGoalVerification.evaluate(expectation: completion, before: nil, after: screen).status,
                       .satisfied, "Visible does not require enabled or a prior action")
        let requests = [
            IOSPhoneGoalRequest(goal: "Open and check the control", bundleID: "app.test",
                actions: [.init(action: .tap, target: .init(label: "Open"))], completion: completion),
            IOSPhoneGoalRequest(goal: "Show the check control", bundleID: "app.test", completion: completion),
        ]
        for request in requests {
            for waitFirst in [false, true] {
                let fixture = Fixture(waitFirst ? [covered, screen] : [screen])
                if waitFirst { fixture.selections = [.wait] }
                let result = await fixture.loop().run(request)
                if request.usesLiveCandidates {
                    XCTAssertEqual(result.status, .completed)
                    XCTAssertEqual(result.reasonCode, .completed)
                    XCTAssertEqual(result.verification?.status, .satisfied)
                } else {
                    XCTAssertEqual(result.status, .handback)
                    XCTAssertEqual(result.reasonCode, .completionAlreadySatisfied)
                    XCTAssertNil(result.verification)
                    XCTAssertTrue(result.candidateDiagnostics.isEmpty)
                }
                XCTAssertEqual(result.observation?.observationID, "ready")
                XCTAssertTrue(result.steps.isEmpty)
                XCTAssertTrue(fixture.actions.isEmpty)
                XCTAssertEqual(fixture.chooseCount, waitFirst ? 1 : 0)
                XCTAssertEqual(fixture.waitCount, waitFirst ? 1 : 0)
                XCTAssertEqual(fixture.adviceCount, 0)
                XCTAssertEqual(fixture.observeCount, waitFirst ? 2 : 1)
            }
        }
    }

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
        XCTAssertTrue(fixture.candidateBatches.isEmpty)
        XCTAssertEqual(fixture.chooseCount, 0)
        XCTAssertEqual(fixture.requireUnchangedObservations, [true, true])
        XCTAssertEqual(fixture.observeCount, 3)
        XCTAssertEqual(fixture.adviceCount, 0, "A fresh next candidate needs no separate remote review")
        XCTAssertEqual(result.steps, ["a0: completed", "a1: completed"])
        XCTAssertEqual(result.reasonCode, .completed)
        XCTAssertEqual(result.candidateDiagnostics.map(\.reasonCode), [.alreadyExecuted, .alreadyExecuted])
        XCTAssertEqual(result.metrics.observeMs, 30, accuracy: 0.001)
        XCTAssertEqual(result.metrics.chooseMs, 0, accuracy: 0.001)
        XCTAssertEqual(result.metrics.actMs, 60, accuracy: 0.001)
        XCTAssertEqual(result.metrics.adviseMs, 0, accuracy: 0.001)
        XCTAssertEqual(result.metrics.selectionCalls, 0)
        XCTAssertEqual(result.metrics.reviewCalls, 0)
        XCTAssertEqual(result.metrics.localActions, 2)
        XCTAssertEqual(result.metrics.totalMs, 90, accuracy: 0.001)
    }

    func testLegacyUsesFreshReferencesAfterRotationWhileLiveKeepsItsGeometryBoundary() async {
        let landscape = PhoneElementRect(x: 0, y: 0, width: 874, height: 402)
        let completion = IOSPhoneGoalExpectation(kind: .visible, target: .init(identifier: "done"))
        for waitFirst in [false, true] {
            for live in [false, true] {
                let portraitNodes = [node("portrait:rotate", id: "rotate")]
                    + (waitFirst ? [node("portrait:alternative", id: "alternative")] : [])
                let plannedActions: [IOSPhoneGoalActionSpec] = [
                    .init(action: .tap, target: .init(identifier: "rotate")),
                    .init(action: .tap, target: .init(identifier: "next")),
                ] + (waitFirst ? [.init(action: .tap, target: .init(identifier: "alternative"))] : [])
                let fixture = Fixture([
                    observation("portrait", portraitNodes),
                    observation("landscape", [node("landscape:next", id: "next")], bounds: landscape),
                    observation("done", [node("landscape:done", id: "done")], bounds: landscape),
                ])
                if waitFirst { fixture.selections = [.wait] }
                let request = live
                    ? IOSPhoneGoalRequest(goal: "Open the result", bundleID: "app.test", completion: completion)
                    : IOSPhoneGoalRequest(goal: "Open the result", bundleID: "app.test", actions: plannedActions,
                                          completion: completion)
                let result = await fixture.loop().run(request)
                let firstActions: [PhoneAction] = waitFirst ? [] : [.tap(ref: "portrait:rotate")]
                if live {
                    XCTAssertEqual(result.reasonCode, .foregroundAppChanged)
                    XCTAssertEqual(fixture.actions, firstActions)
                    XCTAssertEqual(fixture.observeCount, 2)
                } else {
                    XCTAssertEqual(result.status, .completed)
                    XCTAssertEqual(fixture.actions, firstActions + [.tap(ref: "landscape:next")])
                    XCTAssertEqual(fixture.observeCount, 3)
                    XCTAssertEqual(fixture.adviceCount, 0)
                }
                XCTAssertEqual(fixture.requireUnchangedObservations,
                               Array(repeating: true, count: fixture.actions.count))
            }
        }
    }

    func testCompletedReceiptWithUnchangedScreenCannotBecomeSuccessOrRepeatTap() async {
        let fixture = Fixture([observation("before", [node("old", id: "search")]),
                               observation("after", [node("new", id: "search")]),
                               observation("still", [node("newer", id: "search")])])
        let result = await fixture.loop().run(request())
        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.reasonCode, .screenUnchanged)
        XCTAssertNotEqual(result.verification?.status, .satisfied)
        XCTAssertEqual(fixture.actions, [.tap(ref: "old")], "The ineffective control is never offered again")
        XCTAssertEqual(fixture.chooseCount, 0)
        XCTAssertEqual(fixture.observeCount, 3, "One read-only re-read before handing back")
        XCTAssertTrue(result.needsScreenshot)
        XCTAssertEqual(result.steps, ["a0: completed"])
    }

    func testAcknowledgedActionUsesSettledReadWithoutRepeatingObservationOrMutation() async {
        let fixture = Fixture([
            observation("initial", [node("open", id: "search")]),
            observation("settled", [node("done", id: "results")]),
        ])

        let result = await fixture.loop().run(request())

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.observation?.observationID, "settled")
        XCTAssertEqual(fixture.actions, [.tap(ref: "open")])
        XCTAssertEqual(fixture.observeCount, 2)
        XCTAssertEqual(fixture.observeAfterActionCount, 1)
        XCTAssertEqual(fixture.chooseCount, 0)
        XCTAssertEqual(fixture.adviceCount, 0)
    }

    func testFreshIntermediateAlternativesStillRequireTheNextDecision() async {
        let fixture = Fixture([
            observation("home", [node("home:search", id: "search"), node("home:alternative", id: "alternate-search")]),
            observation("search", [node("search:input", id: "query", type: "XCUIElementTypeSearchField", value: ""),
                                   node("search:alternative", id: "alternate-query")]),
        ])
        fixture.selections = [.action("a0"), .handback("needs a revised plan")]
        let request = IOSPhoneGoalRequest(
            goal: "打开搜索并填写草稿", bundleID: "app.test",
            actions: [.init(action: .tap, target: .init(identifier: "search")),
                      .init(action: .tap, target: .init(identifier: "alternate-search")),
                      .init(action: .type, target: .init(identifier: "query"), text: "draft"),
                      .init(action: .tap, target: .init(identifier: "alternate-query"))],
            completion: .init(kind: .valueEquals, target: .init(identifier: "query"), value: "draft"))
        let result = await fixture.loop().run(request)
        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.reasonCode, .decisionHandback)
        XCTAssertEqual(fixture.actions, [.tap(ref: "home:search")])
        XCTAssertEqual(fixture.chooseCount, 2)
        XCTAssertEqual(fixture.adviceCount, 0)
        XCTAssertEqual(result.steps, ["a0: completed"])
    }

    func testIncompleteAmbiguousDisabledOrUnboundedTargetsNeverActWithoutDecision() async {
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
            // Three identical reads: the loop may re-read, but never acts on its own.
            let fixture = Fixture([screen, screen, screen])
            fixture.selections = [.handback("jev_handback")]
            let result = await fixture.loop().run(request())
            XCTAssertEqual(result.status, .handback, screen.observationID)
            XCTAssertTrue(fixture.actions.isEmpty, screen.observationID)
            XCTAssertEqual(result.metrics.localActions, 0, screen.observationID)
            // Ambiguous and truncated targets are offered to Jev instead of handing back blindly.
            let offered = ["truncated", "ambiguous"].contains(screen.observationID)
            XCTAssertEqual(fixture.chooseCount, offered ? 1 : 0, screen.observationID)
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
            let screen = observation("input", [input])
            let fixture = Fixture([screen, screen, screen])
            fixture.selections = [.handback("jev_handback")]
            let result = await fixture.loop().run(draft)
            XCTAssertEqual(result.status, .handback)
            XCTAssertFalse(fixture.actions.contains { if case .type = $0 { true } else { false } },
                           "Text is only typed into a verified empty, nonsecure input")
            XCTAssertTrue(fixture.actions.isEmpty)
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
        XCTAssertEqual(result.metrics.selectionCalls, 0)
        XCTAssertEqual(result.metrics.reviewCalls, 0)
        XCTAssertEqual(result.unknownProblem, problem)
        XCTAssertNil(result.observation)
        XCTAssertEqual(result.steps, ["a0: unknown"])
        XCTAssertEqual(fixture.actions, [.tap(ref: "ref")])
        XCTAssertEqual(fixture.observeCount, 1)
        XCTAssertEqual(fixture.adviceCount, 0)
    }

    func testOwnerRevocationDuringDecisionPreventsDispatch() async {
        let fixture = Fixture([observation("initial", [node("ref", id: "search"), node("ref-alternative", id: "alternate-search")])])
        fixture.onChoose = { fixture.current = false }
        let result = await fixture.loop().run(branchingRequest())
        XCTAssertEqual(result.status, .handback)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.observeCount, 1)
    }

    func testCancellationDuringDecisionPreventsDispatch() async {
        let fixture = Fixture([observation("initial", [node("ref", id: "search"), node("ref-alternative", id: "alternate-search")])])
        fixture.onChoose = { withUnsafeCurrentTask { $0?.cancel() } }
        let goal = branchingRequest()
        let task = Task { await fixture.loop().run(goal) }
        let result = await task.value
        XCTAssertEqual(result.status, .handback)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.observeCount, 1)
    }

    func testModeChangeDuringDecisionPreventsDispatch() async {
        let fixture = Fixture([observation("initial", [node("ref", id: "search"), node("ref-alternative", id: "alternate-search")])])
        fixture.onChoose = { fixture.mode = .off }
        let result = await fixture.loop().run(branchingRequest())
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
        XCTAssertEqual(fixture.chooseCount, 0)
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
        let fixture = Fixture([observation("initial", [node("ref", id: "search"), node("ref-alternative", id: "alternate-search")])])
        fixture.selections = [.handback("provider_unavailable")]
        let result = await fixture.loop().run(branchingRequest())
        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.reason, "provider_unavailable")
        XCTAssertEqual(result.reasonCode, .decisionHandback)
        XCTAssertEqual(result.metrics.selectionCalls, 1)
        XCTAssertEqual(result.metrics.reviewCalls, 0)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertTrue(result.steps.isEmpty)
    }

    func testRepeatedWaitOnAnUnchangedScreenHandsBackAfterBoundedRefreshes() async {
        let fixture = Fixture([observation("loading", [node("first", id: "search"), node("first-alternative", id: "alternate-search")]),
                               observation("still-loading", [node("second", id: "search"), node("second-alternative", id: "alternate-search")]),
                               observation("still-loading-2", [node("third", id: "search"), node("third-alternative", id: "alternate-search")])])
        fixture.selections = [.wait, .wait, .wait]
        let result = await fixture.loop().run(branchingRequest())
        XCTAssertEqual(result.status, .handback)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.waitCount, 2)
        XCTAssertEqual(fixture.observeCount, 3)
        XCTAssertEqual(fixture.chooseCount, 3)
        XCTAssertEqual(result.reasonCode, .waitBudgetExhausted)
    }

    func testReadonlyWaitContributesToWaitAndTotalMetrics() async {
        let fixture = Fixture([
            observation("loading", [node("first", id: "search"), node("alternative", id: "alternate-search")]),
            observation("still-loading", [node("second", id: "search"), node("second-alternative", id: "alternate-search")]),
            observation("still-loading-2", [node("third", id: "search"), node("third-alternative", id: "alternate-search")]),
        ])
        fixture.observeDuration = 0.01
        fixture.chooseDuration = 0.02
        fixture.waitDuration = 0.05
        fixture.selections = [.wait, .wait, .wait]

        let result = await fixture.loop().run(branchingRequest())

        XCTAssertEqual(result.reasonCode, .waitBudgetExhausted)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.waitCount, 2)
        XCTAssertEqual(result.metrics.waitMs, 100, accuracy: 0.001)
        XCTAssertEqual(result.metrics.totalMs, 190, accuracy: 0.001)
        XCTAssertEqual(result.metrics.recoveries, 2)
    }

    func testProcessRestartDuringReadonlyWaitDoesNotDispatchIntoNewProcess() async {
        let fixture = Fixture([observation("loading", [node("old", id: "search"), node("old-alternative", id: "alternate-search")]),
                               observation("restarted", [node("new", id: "search"), node("new-alternative", id: "alternate-search")], pid: 99)])
        fixture.selections = [.wait, .action("a0")]
        let result = await fixture.loop().run(branchingRequest())
        XCTAssertEqual(result.status, .handback)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.chooseCount, 1)
        XCTAssertEqual(fixture.observeCount, 2)
    }

    func testConfigurationRevisionChangeDuringReadonlyWaitEndsInvocationDespiteActiveMode() async {
        let fixture = Fixture([observation("loading", [node("old", id: "search"), node("old-alternative", id: "alternate-search")]),
                               observation("loaded", [node("new", id: "search"), node("new-alternative", id: "alternate-search")])])
        fixture.selections = [.wait, .action("a0")]
        fixture.onActivity = { phase in
            if case .waitingForUI = phase { fixture.configurationRevision += 1 }
        }

        let result = await fixture.loop().run(branchingRequest())

        XCTAssertEqual(fixture.mode, .active)
        XCTAssertTrue(fixture.current)
        XCTAssertEqual(fixture.configurationRevision, 1)
        XCTAssertEqual(result.reasonCode, .configurationChanged)
        XCTAssertEqual(result.status, .handback)
        XCTAssertTrue(result.steps.isEmpty)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.chooseCount, 1)
    }

    func testCandidateDiagnosticsDistinguishExcludedTargetsAndNeverActLocallyOffPlan() async {
        let screens: [(PhoneObservation, IOSPhoneGoalLoop.CandidateDiagnostic.ReasonCode)] = [
            (observation("partial", [node("ref", id: "search")], truncated: true), .treeTruncated),
            (observation("duplicate", [node("one", id: "search"), node("two", id: "search")]), .targetAmbiguous),
            (observation("missing", [node("other", id: "other")]), .targetNotVisible),
            (observation("disabled", [node("ref", id: "search", enabled: false)]), .disabled),
            (observation("no-ref", [node(nil, id: "search")]), .referenceUnavailable),
            (observation("unsupported", [node("ref", id: "search", type: "XCUIElementTypeImage")]), .unsupported),
            (observation("no-geometry", [node("ref", id: "search")], bounds: nil), .screenBoundsUnavailable),
        ]
        for (screen, code) in screens {
            let fixture = Fixture([screen, screen, screen])
            fixture.selections = [.handback("jev_handback")]
            let result = await fixture.loop().run(request())
            XCTAssertEqual(result.status, .handback, screen.observationID)
            XCTAssertTrue([.noExecutableCandidates, .decisionHandback].contains(result.reasonCode), screen.observationID)
            XCTAssertEqual(result.candidateDiagnostics, [.init(id: "a0", reasonCode: code)], screen.observationID)
            XCTAssertEqual(result.metrics.reviewCalls, 0)
            XCTAssertEqual(result.metrics.localActions, 0)
            XCTAssertTrue(fixture.actions.isEmpty, screen.observationID)
        }
    }

    func testTapResolvesButtonWhenItsLabelAlsoMatchesStaticTextChild() async {
        let request = IOSPhoneGoalRequest(
            goal: "选择单词", bundleID: "app.test",
            actions: [.init(action: .tap, target: .init(label: "ワンピース"))],
            completion: .init(kind: .visible, target: .init(identifier: "selected")))
        let fixture = Fixture([
            observation("question", [
                node("button-ref", id: "word", label: "ワンピース", width: 180, height: 80),
                node("text-ref", id: "word-label", type: "XCUIElementTypeStaticText", label: "ワンピース",
                     y: 40, depth: 2, x: 40, width: 120, height: 32)
            ]),
            observation("selected", [node("selected-ref", id: "selected")])
        ])

        let result = await fixture.loop().run(request)

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(fixture.actions, [.tap(ref: "button-ref")])
        XCTAssertEqual(fixture.chooseCount, 0)
    }

    func testTwoMatchingButtonsWithTheSameLabelGoToJevNeverToTheFirstMatch() async {
        let request = IOSPhoneGoalRequest(
            goal: "选择单词", bundleID: "app.test",
            actions: [.init(action: .tap, target: .init(label: "ワンピース"))],
            completion: .init(kind: .visible, target: .init(identifier: "selected")))
        let screen = observation("question", [
            node("first-button", id: "word-1", label: "ワンピース"),
            node("second-button", id: "word-2", label: "ワンピース", x: 220)
        ])
        let fixture = Fixture([screen])
        fixture.selections = [.handback("jev_handback")]

        let result = await fixture.loop().run(request)

        XCTAssertEqual(result.reasonCode, .decisionHandback)
        XCTAssertEqual(result.candidateDiagnostics, [.init(id: "a0", reasonCode: .targetAmbiguous)])
        XCTAssertEqual(fixture.candidateBatches, [["a0.1", "a0.2"]])
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.chooseCount, 1)
    }

    func testTapAcceptsExplicitStaticTextAndOtherTypes() async {
        for type in ["XCUIElementTypeStaticText", "XCUIElementTypeOther"] {
            let request = IOSPhoneGoalRequest(
                goal: "选择单词", bundleID: "app.test",
                actions: [.init(action: .tap, target: .init(label: "オレンジ", type: type))],
                completion: .init(kind: .visible, target: .init(identifier: "selected")))
            let fixture = Fixture([
                observation("question", [node("word-ref", id: "word", type: type, label: "オレンジ")]),
                observation("selected", [node("selected-ref", id: "selected")])
            ])

            let result = await fixture.loop().run(request)

            XCTAssertEqual(result.status, .completed, type)
            XCTAssertEqual(fixture.actions, [.tap(ref: "word-ref")], type)
        }
    }

    func testTapAcceptsNamedStaticTextAndOtherWithoutExplicitType() async {
        for type in ["XCUIElementTypeStaticText", "XCUIElementTypeOther"] {
            let request = IOSPhoneGoalRequest(
                goal: "选择单词", bundleID: "app.test",
                actions: [.init(action: .tap, target: .init(label: "オレンジ"))],
                completion: .init(kind: .visible, target: .init(identifier: "selected")))
            let fixture = Fixture([
                observation("question", [node("word-ref", id: "word", type: type, label: "オレンジ")]),
                observation("selected", [node("selected-ref", id: "selected")])
            ])

            let result = await fixture.loop().run(request)

            XCTAssertEqual(result.status, .completed, type)
            XCTAssertEqual(fixture.actions, [.tap(ref: "word-ref")], type)
        }
    }

    func testLiveCandidatesFollowNewPagesAndMovedWordBlocks() async {
        let request = IOSPhoneGoalRequest(
            goal: "完成选词", bundleID: "app.test",
            completion: .init(kind: .visible, target: .init(identifier: "done")), maxSteps: 3)
        let fixture = Fixture([
            observation("home", [
                node("start-button", id: "start", label: "开始"),
                node("start-text", id: "start-text", type: "XCUIElementTypeStaticText", label: "开始", depth: 2)
            ]),
            observation("question", [
                node("one", id: "one", type: "XCUIElementTypeOther", label: "ワンピース", y: 200),
                node("two", id: "two", type: "XCUIElementTypeOther", label: "オレンジ", y: 300)
            ]),
            observation("moved", [
                node("two-moved", id: "two", type: "XCUIElementTypeOther", label: "オレンジ", y: 500)
            ]),
            observation("done", [node("done-ref", id: "done", label: "完成")])
        ])

        let result = await fixture.loop().run(request)

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(fixture.actions, [.tap(ref: "start-button"), .tap(ref: "one"), .tap(ref: "two-moved")])
        XCTAssertEqual(fixture.chooseCount, 1)
        XCTAssertEqual(fixture.adviceCount, 0)
        XCTAssertEqual(fixture.requireUnchangedObservations, [true, true, true])
        XCTAssertEqual(fixture.candidateBatches, [["n0", "n1"]])
        XCTAssertEqual(result.metrics.selectionCalls, 1)
        XCTAssertEqual(result.metrics.localActions, 2)
        XCTAssertTrue(fixture.candidateDescriptions.first?.first?.contains("label=ワンピース") == true)
        XCTAssertTrue(fixture.candidateDescriptions.first?.first?.contains("rect=[") == true)
        XCTAssertTrue(result.steps.contains { $0.contains("ワンピース") })
        XCTAssertTrue(result.steps.contains { $0.contains("オレンジ") })
    }

    func testLiveKeepsSameNameControlsAtDifferentPositionsAsSeparateChoices() {
        let observation = observation("choices", [
            node("first", id: "word-1", label: "オレンジ", x: 20),
            node("second", id: "word-2", label: "オレンジ", x: 220)
        ])

        let candidates = IOSPhoneGoalLoop.liveCandidates(in: observation)

        XCTAssertEqual(candidates.map(\.id), ["n0", "n1"])
        XCTAssertEqual(candidates.map(\.action), [.tap(ref: "first"), .tap(ref: "second")])
    }

    func testLiveDropsOnlyAContainedSameLabelTextChild() {
        let observation = observation("nested", [
            node("control", id: "word", label: "オレンジ", width: 180, height: 80),
            node("text", id: "word-label", type: "XCUIElementTypeStaticText", label: "オレンジ",
                     y: 40, depth: 2, x: 40, width: 120, height: 32),
            node("sibling", id: "other-word", type: "XCUIElementTypeOther", label: "オレンジ", x: 240)
        ])

        let candidates = IOSPhoneGoalLoop.liveCandidates(in: observation)

        XCTAssertEqual(candidates.map(\.action), [.tap(ref: "control"), .tap(ref: "sibling")])
    }

    func testLiveStopsOnUnchangedScreenWithoutRemoteAdviceOrReplay() async {
        let request = IOSPhoneGoalRequest(
            goal: "选择单词", bundleID: "app.test",
            completion: .init(kind: .visible, target: .init(identifier: "done")), maxSteps: 3)
        let screen = observation("before", [node("word", id: "word", label: "ワンピース")])
        let fixture = Fixture([screen, observation("after", screen.nodes), observation("again", screen.nodes)])

        let result = await fixture.loop().run(request)

        XCTAssertEqual(result.reasonCode, .screenUnchanged)
        XCTAssertEqual(fixture.actions, [.tap(ref: "word")], "Never tapped twice on the unchanged screen")
        XCTAssertEqual(fixture.chooseCount, 0)
        XCTAssertEqual(fixture.adviceCount, 0)
    }

    func testLiveTruncatedTreeNeverActsWithoutJevDecision() async {
        let request = IOSPhoneGoalRequest(
            goal: "选择单词", bundleID: "app.test",
            completion: .init(kind: .visible, target: .init(identifier: "done")))
        let fixture = Fixture([observation("partial", [node("word", id: "word", label: "ワンピース")], truncated: true)])
        fixture.selections = [.handback("jev_handback")]

        let result = await fixture.loop().run(request)

        XCTAssertEqual(result.reasonCode, .decisionHandback)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.chooseCount, 1, "A partial tree's lone candidate still needs a decision")
    }

    func testLegacyAlertHandbackAndWaitBudgetDoNotAdvertiseUnderlyingCandidates() async {
        let nodes = [node("underlying", id: "search"),
                     node("alert", id: "alert", type: "XCUIElementTypeAlert")]
        let covered = observation("covered", nodes)
        let request = request()
        XCTAssertEqual(IOSPhoneGoalLoop.candidates(request.actions, in: covered).count, 1,
                       "The underlying action would otherwise be marked eligible")
        for waits in [false, true] {
            let fixture = Fixture([covered, observation("still-covered", nodes), observation("still-covered-2", nodes)])
            fixture.selections = waits ? [.wait, .wait, .wait] : [.handback("alert")]
            let result = await fixture.loop().run(request)
            XCTAssertEqual(result.status, .handback)
            XCTAssertEqual(result.reasonCode, waits ? .waitBudgetExhausted : .unexpectedAlert)
            XCTAssertTrue(result.candidateDiagnostics.isEmpty)
            XCTAssertTrue(fixture.actions.isEmpty)
            XCTAssertTrue(fixture.candidateBatches.allSatisfy { $0.isEmpty })
            XCTAssertEqual(fixture.chooseCount, waits ? 3 : 1)
            XCTAssertEqual(fixture.observeCount, waits ? 3 : 1)
            XCTAssertEqual(fixture.waitCount, waits ? 2 : 0)
        }
    }

    func testLiveHandsBackWhenAnAlertCoversThePage() async {
        let request = IOSPhoneGoalRequest(
            goal: "选择单词", bundleID: "app.test",
            completion: .init(kind: .visible, target: .init(identifier: "done")))
        let fixture = Fixture([observation("alert", [
            node("underlying", id: "word", label: "ワンピース"),
            node("alert", id: "alert", type: "XCUIElementTypeAlert", label: "提示")
        ])])
        fixture.selections = [.handback("alert")]

        let result = await fixture.loop().run(request)

        XCTAssertEqual(result.reasonCode, .unexpectedAlert)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.chooseCount, 1)
    }

    func testLiveMayWaitForAnAlertToClearWithoutClickingUnderlyingPage() async {
        let request = IOSPhoneGoalRequest(
            goal: "等待完成", bundleID: "app.test",
            completion: .init(kind: .visible, target: .init(identifier: "done")))
        let fixture = Fixture([
            observation("alert", [
                node("underlying", id: "word", label: "ワンピース"),
                node("alert", id: "alert", type: "XCUIElementTypeAlert", label: "提示")
            ]),
            observation("done", [node("done-ref", id: "done", label: "完成")])
        ])
        fixture.selections = [.wait]

        let result = await fixture.loop().run(request)

        XCTAssertEqual(result.status, .completed)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.chooseCount, 1)
        XCTAssertEqual(fixture.waitCount, 1)
        XCTAssertEqual(fixture.observeCount, 2)
    }

    func testLiveCannotCompleteBehindAnAlertBeforeOrAfterClick() async {
        let request = IOSPhoneGoalRequest(goal: "Open results", bundleID: "app.test",
            completion: .init(kind: .visible, target: .init(identifier: "done")))
        let covered = observation("covered", [
            node("done-ref", id: "done"),
            node("alert-ref", id: "alert", type: "XCUIElementTypeAlert"),
        ])
        for afterClick in [false, true] {
            let screens = afterClick ? [observation("initial", [node("open-ref", id: "open")]), covered] : [covered]
            let fixture = Fixture(screens)
            fixture.selections = [.handback("alert")]
            let result = await fixture.loop().run(request)
            XCTAssertEqual(result.status, .handback)
            XCTAssertEqual(result.reasonCode, .unexpectedAlert)
            XCTAssertEqual(result.verification?.status, .insufficient)
            XCTAssertEqual(result.verification?.reason, "unexpected_alert")
            XCTAssertEqual(fixture.actions.count, afterClick ? 1 : 0)
            XCTAssertEqual(fixture.candidateBatches.last, [])
        }
    }

    func testLiveShadowChoosesOnceWithoutDispatching() async {
        let request = IOSPhoneGoalRequest(
            goal: "选择单词", bundleID: "app.test",
            completion: .init(kind: .visible, target: .init(identifier: "done")))
        let fixture = Fixture([observation("question", [node("word", id: "word", label: "ワンピース")])])
        fixture.mode = .shadow

        let result = await fixture.loop().run(request)

        XCTAssertEqual(result.reasonCode, .shadowMode)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.observeCount, 1)
        XCTAssertEqual(fixture.chooseCount, 1)
    }

    func testLiveUnknownStopsWithoutPostActionObservation() async {
        let request = IOSPhoneGoalRequest(
            goal: "选择单词", bundleID: "app.test",
            completion: .init(kind: .visible, target: .init(identifier: "done")))
        let fixture = Fixture([observation("question", [node("word", id: "word", label: "ワンピース")])])
        fixture.receipts = [.unknown(.init(.transport, "dispatch outcome unknown"))]

        let result = await fixture.loop().run(request)

        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.reasonCode, .actionOutcomeUnknown)
        XCTAssertNil(result.observation)
        XCTAssertEqual(fixture.observeCount, 1)
        XCTAssertEqual(fixture.chooseCount, 0)
        XCTAssertEqual(fixture.actions, [.tap(ref: "word")])
        XCTAssertTrue(result.steps.first?.contains("ワンピース") == true)
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
            let screen = observation("input", [input])
            let fixture = Fixture([screen, screen, screen])
            let result = await fixture.loop().run(request)
            XCTAssertEqual(result.candidateDiagnostics, [.init(id: "a0", reasonCode: code)])
            XCTAssertEqual(result.reasonCode, .noExecutableCandidates)
            XCTAssertEqual(fixture.chooseCount, 0)
            XCTAssertEqual(fixture.waitCount, 2, "Bounded read-only re-reads before handing back")
            XCTAssertTrue(fixture.actions.isEmpty)
        }
    }

    func testExhaustedActionsReportAlreadyExecutedWithoutRepeating() async {
        let fixture = Fixture([observation("before", [node("old", id: "search")]),
                               observation("after", [node("new", id: "search", value: "changed")])])
        fixture.selections = [.handback("jev_handback")]
        let result = await fixture.loop().run(request())
        XCTAssertEqual(result.reasonCode, .decisionHandback)
        XCTAssertEqual(result.candidateDiagnostics, [.init(id: "a0", reasonCode: .alreadyExecuted)])
        XCTAssertEqual(result.steps, ["a0: completed"])
        XCTAssertEqual(fixture.actions.count, 1, "The executed listed action is not replayed")
        XCTAssertEqual(fixture.candidateBatches, [["n0"]], "Off-plan candidates come from the fresh tree and need Jev")
    }

    func testModeOffAndTimeBudgetReturnStableReasonsAndAccurateServiceCounts() async {
        let off = Fixture([])
        off.mode = .off
        let offResult = await off.loop().run(branchingRequest())
        XCTAssertEqual(offResult.reasonCode, .modeOff)
        XCTAssertEqual(offResult.metrics, .init())
        XCTAssertEqual(off.observeCount, 0)

        let expired = Fixture([observation("initial", [node("ref", id: "search"), node("ref-alternative", id: "alternate-search")])])
        expired.onChoose = { expired.time += 180 }
        let expiredResult = await expired.loop().run(branchingRequest())
        XCTAssertEqual(expiredResult.reasonCode, .timeBudgetExhausted)
        XCTAssertEqual(expiredResult.metrics.chooseMs, 180_000, accuracy: 0.001)
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
        XCTAssertEqual(Set(json.keys), ["observe_ms", "choose_ms", "act_ms", "advise_ms", "selection_calls", "review_calls",
                                        "settle_ms", "settle_calls", "local_actions", "wait_ms", "total_ms", "recoveries"])
        XCTAssertEqual(json["selection_calls"], 2)
        XCTAssertEqual(json["review_calls"], 1)
    }

    func testSequenceReusesEachNewObservationAndRemovesRedundantDecisions() async {
        let screens = sequenceScreens()
        let sequence = sequenceRequest()
        let old = Fixture(screens)
        let baseline = await old.loop().run(.init(goal: sequence.goal, bundleID: sequence.bundleID,
            actions: sequence.steps!.flatMap(\.actions), completion: sequence.completion))
        let fast = Fixture(screens)
        let result = await fast.loop().run(sequence)

        XCTAssertEqual(baseline.status, .completed)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(fast.actions, old.actions)
        XCTAssertEqual(fast.actions, [.tap(ref: "q0:one"), .tap(ref: "q1:two"), .tap(ref: "q2:three")])
        XCTAssertEqual(result.verifiedStepCount, 3)
        XCTAssertEqual(result.stepVerification?.status, .satisfied)
        XCTAssertEqual(fast.observeCount, 4, "Each post-action snapshot is the next step's input")
        XCTAssertEqual(old.observeCount, 4)
        XCTAssertEqual(old.chooseCount, 2)
        XCTAssertEqual(old.adviceCount, 0)
        XCTAssertEqual(baseline.metrics.localActions, 1)
        XCTAssertEqual(fast.chooseCount, 0)
        XCTAssertEqual(fast.adviceCount, 0)
        XCTAssertEqual(fast.settleCount, 1, "Only the requested transition waits for stability")
        XCTAssertEqual(result.metrics.localActions, 3)
        XCTAssertEqual(result.metrics.settleCalls, 1)
        XCTAssertEqual(fast.pageAnchorRefs, ["q0:question", "q1:question", "q2:question"])
        XCTAssertTrue(old.pageAnchorRefs.allSatisfy { $0 == nil }, "Legacy actions keep their existing dispatch contract")
        print("PHONE_SEQUENCE_CALL_COUNTS actions=3 observations=4 candidates_choose=2 candidates_review=0 sequence_choose=0 sequence_review=0 requested_settle=1")
    }

    func testSequenceAnchorCollapsesItsTextChildButKeepsSiblingAndCrossBranchAmbiguity() async {
        let parent = node("parent", id: "parent", type: "XCUIElementTypeOther", label: "Current item",
                          width: 240, height: 80)
        let text = node("text", id: "text", type: "XCUIElementTypeStaticText", label: "Current item",
                        y: 30, depth: 2, x: 30, width: 160, height: 32)
        let cases = [
            [parent, text],
            [node("first", id: "first", label: "Current item"),
             node("second", id: "second", label: "Current item", x: 140)],
            [parent, node("other-branch", id: "other-branch", type: "XCUIElementTypeOther"), text],
        ]
        let completion = IOSPhoneGoalExpectation(kind: .visible, target: .init(identifier: "done"))
        let request = IOSPhoneGoalRequest(goal: "Open this item", bundleID: "app.test", steps: [
            .init(pageAnchor: .init(label: "Current item"),
                  actions: [.init(action: .tap, target: .init(identifier: "open"))], expectation: completion),
        ], completion: completion)
        for (index, anchors) in cases.enumerated() {
            let before = observation("before", anchors + [node("open", id: "open", y: 200)])
            let fixture = Fixture([before, observation("after", anchors + [node("done", id: "done", y: 200)])])
            XCTAssertEqual(IOSPhoneGoalVerification.matchingNodes(target: .init(label: "Current item"), in: before).count,
                           index == 0 ? 1 : 2)
            let result = await fixture.loop().run(request)
            XCTAssertEqual(fixture.chooseCount, index == 0 ? 0 : 1)
            if index == 0 {
                XCTAssertEqual(result.status, .completed)
                XCTAssertEqual(fixture.pageAnchorRefs, ["parent"])
                XCTAssertEqual(fixture.actions, [.tap(ref: "open")])
                XCTAssertEqual(fixture.requireUnchangedObservations, [false])
            } else {
                // An ambiguous anchor no longer proves the plan's page: continue toward the
                // completion with fresh candidates, every action chosen by Jev.
                XCTAssertEqual(result.continuedFrom, .pageChanged)
                XCTAssertEqual(result.status, .completed)
                XCTAssertEqual(fixture.requireUnchangedObservations, [true])
                XCTAssertEqual(fixture.pageAnchorRefs, [nil])
                XCTAssertEqual(fixture.observeCount, 2)
            }
        }
    }

    func testSequenceUsesJevToSelectAmongCurrentStepAlternatives() async {
        let initial = observation("before", [node("q", id: "question"), node("left", id: "left"), node("right", id: "right")])
        let fixture = Fixture([initial, observation("after", [node("done", id: "done")])])
        fixture.selections = [.action("a1")]
        let goal = IOSPhoneGoalRequest(goal: "Choose the correct alternative", bundleID: "app.test", steps: [
            .init(pageAnchor: .init(identifier: "question"), actions: [
                .init(action: .tap, target: .init(identifier: "left")),
                .init(action: .tap, target: .init(identifier: "right")),
            ], expectation: .init(kind: .visible, target: .init(identifier: "done")))
        ], completion: .init(kind: .visible, target: .init(identifier: "done")))
        let result = await fixture.loop().run(goal)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(fixture.actions, [.tap(ref: "right")])
        XCTAssertEqual(fixture.chooseCount, 1)
        XCTAssertEqual(fixture.adviceCount, 0)
        XCTAssertEqual(result.metrics.localActions, 0)
        XCTAssertEqual(fixture.candidateBatches, [["a0", "a1"]])
    }

    func testSequenceLeavesThePlanWhenQuestionChangesEvenIfNextButtonStillExists() async {
        let screens = sequenceScreens()
        let changed = observation("different-question", [node("new", id: "other-question"),
            node("selected", id: "selected-one"), node("same-button", id: "two")])
        let fixture = Fixture([screens[0], changed])
        fixture.selections = [.handback("jev_handback")]
        let result = await fixture.loop().run(sequenceRequest())
        XCTAssertEqual(result.continuedFrom, .pageChanged)
        XCTAssertEqual(result.reasonCode, .decisionHandback)
        XCTAssertEqual(result.verifiedStepCount, 1)
        XCTAssertEqual(fixture.actions.count, 1, "The planned step two is never executed on the new question")
        XCTAssertEqual(fixture.observeCount, 2)
        XCTAssertEqual(fixture.chooseCount, 1)
    }

    func testSequenceOffPlanScreenCompletesOnlyOnFreshCompletionEvidence() async {
        let changed = observation("new-question", [node("q2", id: "other-question"),
            node("selected", id: "selected-one"), node("done", id: "done")])
        let fixture = Fixture([sequenceScreens()[0], changed])
        let result = await fixture.loop().run(sequenceRequest())
        XCTAssertEqual(result.continuedFrom, .pageChanged)
        XCTAssertEqual(result.status, .completed, "The completion is verified locally on the fresh tree")
        XCTAssertEqual(result.verification?.status, .satisfied)
        XCTAssertEqual(result.verifiedStepCount, 1)
        XCTAssertEqual(fixture.actions.count, 1)
        XCTAssertTrue(result.candidateDiagnostics.isEmpty, "The new page cannot inherit the previous step's eligible choices")
    }

    func testSequenceShadowObservesOneDecisionWithoutWaitingOrDispatching() async {
        for choice in [IOSJevPhoneControlService.Selection.action("a0"), .wait, .handback("shadow")] {
            let fixture = Fixture(sequenceScreens())
            fixture.mode = .shadow
            fixture.selections = [choice]
            let result = await fixture.loop().run(sequenceRequest())
            XCTAssertEqual(result.reasonCode, .shadowMode)
            XCTAssertEqual(fixture.observeCount, 1)
            XCTAssertEqual(fixture.chooseCount, 1)
            XCTAssertTrue(fixture.actions.isEmpty)
            XCTAssertEqual(fixture.waitCount, 0)
            XCTAssertEqual(fixture.settleCount, 0)
            XCTAssertNotNil(result.observation)
            XCTAssertNil(result.verification)
        }
    }

    func testSequenceOffersAmbiguousTargetsToJevAndInactiveModesNeverClick() async {
        let initial = observation("ambiguous", [node("q", id: "question"),
            node("one", id: "one"), node("duplicate", id: "one", x: 200)])
        let ambiguous = Fixture([initial])
        ambiguous.selections = [.handback("jev_handback"), .handback("jev_handback")]
        let result = await ambiguous.loop().run(sequenceRequest())
        XCTAssertEqual(result.continuedFrom, .ambiguousTarget)
        XCTAssertEqual(result.reasonCode, .decisionHandback)
        XCTAssertTrue(ambiguous.actions.isEmpty)
        XCTAssertEqual(ambiguous.candidateBatches.first, ["a0.1", "a0.2"])
        XCTAssertEqual(ambiguous.chooseCount, 2)
        let fixture = Fixture(sequenceScreens())
        fixture.mode = .off
        let off = await fixture.loop().run(sequenceRequest())
        XCTAssertEqual(off.reasonCode, .modeOff)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.observeCount, 0)
    }

    func testSequenceLeavesThePlanWhenQuestionTextChangesUnderTheSameIdentifier() async {
        let before = observation("q1", [node("q", id: "question", value: "Translate cat"), node("one", id: "one")])
        let after = observation("q2", [node("q", id: "question", value: "Translate dog"),
            node("selected", id: "selected-one"), node("two", id: "two")])
        let fixture = Fixture([before, after])
        fixture.selections = [.handback("jev_handback")]
        let result = await fixture.loop().run(sequenceRequest())
        XCTAssertEqual(result.continuedFrom, .pageChanged)
        XCTAssertEqual(fixture.actions.count, 1)
        XCTAssertEqual(result.verifiedStepCount, 1)
        XCTAssertEqual(fixture.chooseCount, 1, "Step two's planned answer is not applied to a new question")
    }

    func testSequenceCannotUseJevContinueToOverrideUnmetStepExpectation() async {
        let fixture = Fixture([sequenceScreens()[0], observation("unchanged", sequenceScreens()[0].nodes)])
        fixture.advices = [.continueTask]
        fixture.selections = [.handback("jev_handback")]
        let result = await fixture.loop().run(sequenceRequest())
        XCTAssertEqual(result.continuedFrom, .stepExpectationUnmet)
        XCTAssertNotEqual(result.status, .completed)
        XCTAssertEqual(result.verifiedStepCount, 0)
        XCTAssertEqual(result.stepVerification?.status, .unmet)
        XCTAssertEqual(fixture.actions.count, 1)
        XCTAssertEqual(fixture.adviceCount, 1)
        XCTAssertEqual(fixture.observeCount, 2)
        XCTAssertFalse(fixture.candidateBatches.last?.contains("n1") == true,
                       "The ineffective control is not offered again in goal mode")
    }

    func testSequenceJevWaitRefreshesEvidenceWithoutReplayingAction() async {
        let screens = sequenceScreens()
        let fixture = Fixture([screens[0], observation("loading", screens[0].nodes)] + Array(screens.dropFirst()))
        fixture.advices = [.wait]
        let result = await fixture.loop().run(sequenceRequest())
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(fixture.actions.count, 3)
        XCTAssertEqual(fixture.adviceCount, 1)
        XCTAssertEqual(fixture.waitCount, 1)
        XCTAssertEqual(fixture.observeCount, 5)
    }

    func testSequenceUnexpectedAlertNeverClicksUnderlyingControls() async {
        let initial = sequenceScreens()[0]
        let fixture = Fixture([observation("alert", initial.nodes + [node("alert", id: "alert", type: "XCUIElementTypeAlert")])])
        fixture.advices = [.handback]
        let result = await fixture.loop().run(sequenceRequest())
        XCTAssertEqual(result.reasonCode, .unexpectedAlert)
        XCTAssertEqual(result.continuedFrom, .unexpectedAlert)
        XCTAssertEqual(fixture.adviceCount, 1)
        XCTAssertEqual(fixture.candidateBatches, [[]], "Only alert buttons could be offered; the page underneath never is")
        XCTAssertTrue(fixture.actions.isEmpty)
    }

    func testSequenceUnknownPreservesReceiptAndStopsWithoutReadingOrSettling() async {
        let fixture = Fixture(sequenceScreens())
        fixture.receipts = [.unknown(.init(.transport, "Connection lost after dispatch"))]
        let result = await fixture.loop().run(sequenceRequest())
        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.steps, ["s0/a0: unknown"])
        XCTAssertNil(result.observation)
        XCTAssertEqual(fixture.observeCount, 1)
        XCTAssertEqual(fixture.actions.count, 1)
        XCTAssertEqual(fixture.settleCount, 0)
    }

    func testSequenceStopsAfterReceiptWhenOwnerOrConfigurationChanges() async {
        for revokeOwner in [true, false] {
            let fixture = Fixture(sequenceScreens())
            fixture.onAct = {
                if revokeOwner { fixture.current = false } else { fixture.configurationRevision += 1 }
            }
            let result = await fixture.loop().run(sequenceRequest())
            XCTAssertEqual(result.reasonCode, revokeOwner ? .taskStopped : .configurationChanged)
            XCTAssertEqual(result.steps, ["s0/a0: completed"])
            XCTAssertNil(result.observation)
            XCTAssertEqual(fixture.actions.count, 1)
            XCTAssertEqual(fixture.observeCount, 1)
        }
    }

    func testSequenceUnstableOrBlankScreenDoesNotBecomeBusinessSuccess() async {
        for stability in [PhoneScreenStability(stable: false, blank: false, waitedMs: 2000, frames: 5,
                                               changedPixels: 40, captureMs: 4, budgetMs: 2000),
                          PhoneScreenStability(stable: true, blank: true, waitedMs: 200, frames: 3,
                                               changedPixels: 0, captureMs: 4, budgetMs: 2000)] {
            let fixture = Fixture(sequenceScreens())
            fixture.stability = stability
            let result = await fixture.loop().run(sequenceRequest())
            XCTAssertEqual(result.reasonCode, .screenNotStable)
            XCTAssertEqual(result.verifiedStepCount, 2)
            XCTAssertEqual(fixture.actions.count, 3)
            XCTAssertEqual(fixture.settleCount, 2, "One extra settle before treating it as no progress")
            XCTAssertNotNil(result.observation)
            XCTAssertNil(result.verification, "An unsettled last step cannot produce overall success")
            XCTAssertTrue(result.candidateDiagnostics.isEmpty)
        }
    }

    func testSequenceWaitFailurePreservesDispatchedSteps() async {
        let fixture = Fixture(sequenceScreens())
        fixture.settleError = NSError(domain: "settle", code: 1)
        let result = await fixture.loop().run(sequenceRequest())
        XCTAssertEqual(result.reasonCode, .observationInterrupted)
        XCTAssertEqual(result.steps.count, 3)
        XCTAssertEqual(result.verifiedStepCount, 2)
        XCTAssertNil(result.observation)
        XCTAssertEqual(fixture.observeCount, 3)
    }

    private func sequenceRequest() -> IOSPhoneGoalRequest {
        let steps = ["one", "two", "three"].map { word in
            IOSPhoneSequenceStep(pageAnchor: .init(identifier: "question"),
                actions: [.init(action: .tap, target: .init(identifier: word))],
                expectation: .init(kind: .visible, target: .init(identifier: "selected-\(word)")),
                waitForStability: word == "three")
        }
        return .init(goal: "Select three words in order", bundleID: "app.test", steps: steps,
                     completion: .init(kind: .visible, target: .init(identifier: "done")))
    }

    private func sequenceScreens() -> [PhoneObservation] {
        (0...3).map { step in
            var nodes = [node("q\(step):question", id: "question")]
            for (index, word) in ["one", "two", "three"].enumerated() {
                nodes.append(node("q\(step):\(word)", id: index < step ? "selected-\(word)" : word))
            }
            if step == 3 { nodes.append(node("q3:done", id: "done")) }
            return observation("q\(step)", nodes)
        }
    }

    private func request(maxSteps: Int = 6) -> IOSPhoneGoalRequest {
        .init(goal: "打开搜索结果", bundleID: "app.test", actions: [.init(action: .tap, target: .init(identifier: "search"))],
              completion: .init(kind: .visible, target: .init(identifier: "results")), maxSteps: maxSteps)
    }

    private func branchingRequest() -> IOSPhoneGoalRequest {
        .init(goal: "打开搜索结果", bundleID: "app.test", actions: [
            .init(action: .tap, target: .init(identifier: "search")),
            .init(action: .tap, target: .init(identifier: "alternate-search")),
        ], completion: .init(kind: .visible, target: .init(identifier: "results")))
    }

    private func observation(_ id: String, _ nodes: [PhoneObservationNode], pid: Int = 42, truncated: Bool = false,
                             bounds: PhoneElementRect? = .init(x: 0, y: 0, width: 402, height: 874)) -> PhoneObservation {
        .init(observationID: id, bundleID: "app.test", processID: pid, backend: "test", truncated: truncated,
              nodes: nodes, screenBounds: bounds)
    }

    private func node(_ ref: String?, id: String, type: String = "XCUIElementTypeButton", value: String? = nil,
                      label: String? = nil, enabled: Bool = true, y: Double = 20, depth: Int = 1,
                      x: Double = 20, width: Double = 80, height: Double = 44) -> PhoneObservationNode {
        .init(ref: ref, depth: depth, type: type, identifier: id, label: label, value: value,
              rect: .init(x: x, y: y, width: width, height: height), enabled: enabled, focused: false)
    }

    @MainActor
    private final class Fixture {
        var observations: [PhoneObservation]
        var actions: [PhoneAction] = []
        var pageAnchorRefs: [String?] = []
        var pageAnchorRegions: [PhoneElementRect?] = []
        var requireUnchangedObservations: [Bool] = []
        var receipts: [PhoneActionResult] = []
        var selections: [IOSJevPhoneControlService.Selection] = []
        var candidateBatches: [[String]] = []
        var candidateDescriptions: [[String]] = []
        var observeCount = 0
        var observeAfterActionCount = 0
        var chooseCount = 0
        var adviceCount = 0
        var advices: [IOSJevPhoneControlService.Advice] = []
        var settleCount = 0
        var stability = PhoneScreenStability(stable: true, blank: false, waitedMs: 200, frames: 3,
                                              changedPixels: 0, captureMs: 4, budgetMs: 2000)
        var settleError: Error?
        var waitCount = 0
        var mode: IOSJevMode = .active
        var current = true
        var configurationRevision = 0
        var time: TimeInterval = 0
        var observeDuration: TimeInterval = 0
        var chooseDuration: TimeInterval = 0
        var actDuration: TimeInterval = 0
        var adviseDuration: TimeInterval = 0
        var waitDuration: TimeInterval = 0
        var onChoose: (() -> Void)?
        var onAct: (() -> Void)?
        var onActivity: ((AgentPhoneControlActivityPhase) -> Void)?

        init(_ observations: [PhoneObservation]) { self.observations = observations }

        private func nextObservation() throws -> PhoneObservation {
            observeCount += 1
            time += observeDuration
            guard !observations.isEmpty else { throw NSError(domain: "Unexpected observation", code: 1) }
            return observations.removeFirst()
        }

        func loop() -> IOSPhoneGoalLoop {
            IOSPhoneGoalLoop(deps: .init(
                observe: { try self.nextObservation() },
                act: { action, pageAnchorRef, pageAnchorRegion, requireUnchangedObservation in
                    self.actions.append(action)
                    self.pageAnchorRefs.append(pageAnchorRef)
                    self.pageAnchorRegions.append(pageAnchorRegion)
                    self.requireUnchangedObservations.append(requireUnchangedObservation)
                    self.time += self.actDuration
                    self.onAct?()
                    return self.receipts.isEmpty ? .completed : self.receipts.removeFirst()
                },
                choose: { _, _, candidates, _, _ in
                    self.chooseCount += 1
                    self.time += self.chooseDuration
                    self.candidateBatches.append(candidates.map(\.id))
                    self.candidateDescriptions.append(candidates.map(\.description))
                    self.onChoose?()
                    return self.selections.isEmpty
                        ? (candidates.first.map { .action($0.id) } ?? .handback("no_candidate"))
                        : self.selections.removeFirst()
                },
                advise: { _, _, _, _, _ in
                    self.adviceCount += 1
                    self.time += self.adviseDuration
                    return self.advices.isEmpty ? .continueTask : self.advices.removeFirst()
                },
                mode: { self.mode }, isCurrent: { self.current }, reportActivity: { self.onActivity?($0) },
                configurationRevision: { self.configurationRevision },
                now: { Date(timeIntervalSince1970: self.time) },
                waitForUI: { self.waitCount += 1; self.time += self.waitDuration },
                waitForStability: {
                    self.settleCount += 1
                    if let error = self.settleError { throw error }
                    return self.stability
                },
                observeAfterAction: {
                    self.observeAfterActionCount += 1
                    return try self.nextObservation()
                }
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

// MARK: - Jev disambiguation, local candidates and in-call recovery

@MainActor
extension IOSPhoneGoalLoopTests {
    /// Duolingo shape: a word already placed in the answer area and the same word in the bank.
    private func duplicateWordScreen(_ id: String, prefix: String = "") -> PhoneObservation {
        observation(id, [
            node("\(prefix)question", id: "question", type: "XCUIElementTypeStaticText", label: "Translate: I go"),
            node("\(prefix)answer-area", id: "answer-area", type: "XCUIElementTypeOther", y: 200, x: 0, width: 402, height: 120),
            node("\(prefix)placed", id: "tile", type: "XCUIElementTypeButton", label: "go", y: 240, depth: 2, x: 20),
            node("\(prefix)bank", id: "word-bank", type: "XCUIElementTypeOther", y: 600, x: 0, width: 402, height: 160),
            node("\(prefix)source", id: "tile", type: "XCUIElementTypeButton", label: "go", y: 640, depth: 2, x: 120),
        ])
    }

    func testListedDuplicateLabelIsOfferedPerMatchWithContextAndJevPicks() async {
        let fixture = Fixture([duplicateWordScreen("question"),
                               observation("answered", [node("done", id: "done")])])
        fixture.selections = [.action("a0.2")]
        let request = IOSPhoneGoalRequest(goal: "把 go 放进答案", bundleID: "app.test",
            actions: [.init(action: .tap, target: .init(label: "go"))],
            completion: .init(kind: .visible, target: .init(identifier: "done")))

        let result = await fixture.loop().run(request)

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(fixture.candidateBatches, [["a0.1", "a0.2"]])
        XCTAssertEqual(fixture.actions, [.tap(ref: "source")])
        let descriptions = fixture.candidateDescriptions.first ?? []
        XCTAssertTrue(descriptions[0].contains("match 1 of 2"))
        XCTAssertTrue(descriptions[0].contains("answer-area"), descriptions[0])
        XCTAssertTrue(descriptions[1].contains("word-bank"), descriptions[1])
        XCTAssertTrue(descriptions[1].contains("position=bottom"), descriptions[1])
        XCTAssertEqual(result.steps, ["a0.2: completed"])
        XCTAssertEqual(result.metrics.localActions, 0, "A duplicate is never executed without a decision")
    }

    func testListedAndSequenceFinalCommitsAreWithheldBeforeSelection() async {
        for sequence in [false, true] {
            for count in [1, 2] {
                let screen = observation("drafts", [
                    node("heading", id: "heading", type: "XCUIElementTypeTextView", label: "Drafts"),
                ] + (0..<count).map { index in
                    node("delete\(index)", id: "delete\(index)", label: "删除", y: Double(100 + index * 80))
                })
                let fixture = Fixture([screen, observation("done", [node("done", id: "done")])])
                fixture.selections = [.action(count == 1 ? "a0" : "a0.1")]
                let actions = [IOSPhoneGoalActionSpec(action: .tap, target: .init(label: "删除"))]
                let completion = IOSPhoneGoalExpectation(kind: .visible, target: .init(identifier: "done"))
                let request = sequence
                    ? IOSPhoneGoalRequest(goal: "整理草稿", bundleID: "app.test", steps: [
                        .init(pageAnchor: .init(identifier: "heading"), actions: actions, expectation: completion),
                    ], completion: completion)
                    : IOSPhoneGoalRequest(goal: "整理草稿", bundleID: "app.test", actions: actions, completion: completion)

                let result = await fixture.loop().run(request)

                XCTAssertEqual(result.reasonCode, .finalCommitRequired, "sequence=\(sequence), count=\(count)")
                XCTAssertEqual(result.withheldFinalActions, Array(repeating: "删除", count: count))
                XCTAssertTrue(fixture.actions.isEmpty, "Neither a unique nor an ambiguous final action may be dispatched")
                XCTAssertEqual(fixture.chooseCount, 0, "Final actions must not be offered to Jev")
            }
        }
    }

    func testSequenceDuplicateLabelUsesJevInsteadOfAmbiguityHandback() async {
        let fixture = Fixture([duplicateWordScreen("question"),
                               observation("answered", [node("q", id: "question", type: "XCUIElementTypeStaticText",
                                                             label: "Translate: I go"), node("done", id: "done")])])
        fixture.selections = [.action("a0.2")]
        let request = IOSPhoneGoalRequest(goal: "选择词块", bundleID: "app.test", steps: [
            .init(pageAnchor: .init(identifier: "question"),
                  actions: [.init(action: .tap, target: .init(label: "go"))],
                  expectation: .init(kind: .visible, target: .init(identifier: "done"))),
        ], completion: .init(kind: .visible, target: .init(identifier: "done")))

        let result = await fixture.loop().run(request)

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(fixture.actions, [.tap(ref: "source")])
        XCTAssertEqual(fixture.chooseCount, 1)
        XCTAssertEqual(result.verifiedStepCount, 1)
    }

    func testLowConfidenceSelectionIsRereadAndRetriedBeforeHandingBack() async {
        let request = IOSPhoneGoalRequest(goal: "把 go 放进答案", bundleID: "app.test",
            actions: [.init(action: .tap, target: .init(label: "go"))],
            completion: .init(kind: .visible, target: .init(identifier: "done")))
        let lowConfidence = IOSJevPhoneControlService.Selection.handback("invalid_or_low_confidence_decision")

        let persistent = Fixture((0..<3).map { duplicateWordScreen("q\($0)", prefix: "q\($0):") })
        persistent.selections = [lowConfidence, lowConfidence, lowConfidence]
        let handedBack = await persistent.loop().run(request)
        XCTAssertEqual(handedBack.status, .handback)
        XCTAssertEqual(handedBack.reasonCode, .decisionHandback)
        XCTAssertTrue(persistent.actions.isEmpty)
        XCTAssertEqual(persistent.chooseCount, 3)
        XCTAssertEqual(persistent.waitCount, 2, "Two re-reads, then the third low-confidence answer hands back")
        XCTAssertTrue(handedBack.needsScreenshot)

        let recovered = Fixture([duplicateWordScreen("q0"), duplicateWordScreen("q1", prefix: "q1:"),
                                 observation("answered", [node("done", id: "done")])])
        recovered.selections = [lowConfidence, .action("a0.2")]
        let completed = await recovered.loop().run(request)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(recovered.actions, [.tap(ref: "q1:source")], "The retry acts on the fresh observation's ref")
        XCTAssertEqual(completed.metrics.recoveries, 1)
    }

    func testExplicitJevHandbackIsNotRetried() async {
        let fixture = Fixture([duplicateWordScreen("question")])
        fixture.selections = [.handback("jev_handback")]
        let request = IOSPhoneGoalRequest(goal: "把 go 放进答案", bundleID: "app.test",
            actions: [.init(action: .tap, target: .init(label: "go"))],
            completion: .init(kind: .visible, target: .init(identifier: "done")))
        let result = await fixture.loop().run(request)
        XCTAssertEqual(result.reasonCode, .decisionHandback)
        XCTAssertEqual(fixture.chooseCount, 1)
        XCTAssertEqual(fixture.waitCount, 0)
    }

    func testLiveCandidatesFilterDedupeDescribeAndCap() {
        let screen = observation("browse", [
            node("list", id: "list", type: "XCUIElementTypeTable", label: nil, y: 100, x: 0, width: 402, height: 700),
            node("row-1", id: "row-1", type: "XCUIElementTypeCell", label: "Wi-Fi", y: 120, depth: 2, x: 0, width: 402),
            node("row-1-dup", id: "row-1", type: "XCUIElementTypeCell", label: "Wi-Fi", y: 120, depth: 2, x: 0, width: 402),
            node("disabled", id: "disabled", label: "Disabled", enabled: false, y: 200),
            node("unnamed", id: "", type: "XCUIElementTypeButton", label: nil, y: 260),
            node(nil, id: "no-ref", label: "No ref", y: 300),
            node("offscreen", id: "offscreen", label: "Offscreen", y: 2_000),
            node("toggle", id: "airplane", type: "XCUIElementTypeSwitch", label: "Airplane Mode", y: 340),
            node("caption", id: "caption", type: "XCUIElementTypeStaticText", label: "Footer", y: 400),
            node("keyboard", id: "a", type: "XCUIElementTypeKey", label: "a", y: 800),
        ] + [PhoneObservationNode(ref: "covered", depth: 1, type: "XCUIElementTypeButton", identifier: "old",
                                  label: "Covered", value: nil, rect: .init(x: 20, y: 500, width: 80, height: 44),
                                  enabled: true, focused: false, covered: true)])

        let all = IOSPhoneGoalLoop.liveCandidateSet(in: screen)
        XCTAssertEqual(all.candidates.map(\.action), [
            .tap(ref: "row-1"), .tap(ref: "toggle"), .tap(ref: "caption"),
            .swipe(ref: "list", direction: .up), .swipe(ref: "list", direction: .down),
        ])
        XCTAssertTrue(all.withheld.isEmpty)
        XCTAssertTrue(all.candidates[0].decisionDescription?.contains("label=Wi-Fi") == true)
        XCTAssertTrue(all.candidates[0].decisionDescription?.contains("in=[Table") == true)
        XCTAssertTrue(all.candidates.allSatisfy { $0.decisionDescription?.contains("position=") == true })
        XCTAssertTrue(all.candidates.filter { if case .swipe = $0.action { true } else { false } }
            .allSatisfy(\.requiresDecision))

        // Capping keeps control-like entries before scroll and plain text.
        let capped = IOSPhoneGoalLoop.liveCandidateSet(in: screen, limit: 3)
        XCTAssertEqual(capped.candidates.map(\.action),
                       [.tap(ref: "row-1"), .tap(ref: "toggle"), .swipe(ref: "list", direction: .up)])
    }

    func testFinalCommitsAreWithheldFromLiveCandidates() {
        XCTAssertTrue(IOSPhoneGoalLoop.isFinalCommit("Send"))
        XCTAssertTrue(IOSPhoneGoalLoop.isFinalCommit("发送"))
        XCTAssertTrue(IOSPhoneGoalLoop.isFinalCommit("立即支付"))
        XCTAssertTrue(IOSPhoneGoalLoop.isFinalCommit("Sign in"))
        XCTAssertTrue(IOSPhoneGoalLoop.isFinalCommit("deleteButton"))
        XCTAssertFalse(IOSPhoneGoalLoop.isFinalCommit("Display"))
        XCTAssertFalse(IOSPhoneGoalLoop.isFinalCommit("Posts"))
        XCTAssertFalse(IOSPhoneGoalLoop.isFinalCommit("Check"))
        XCTAssertFalse(IOSPhoneGoalLoop.isFinalCommit("Continue"))
        XCTAssertFalse(IOSPhoneGoalLoop.isFinalCommit("一篇关于支付行业发展的长篇新闻标题，用于测试内容文本"))

        let screen = observation("compose", [node("back", id: "back", label: "Back"),
                                             node("send", id: "send", label: "Send", x: 300)])
        let set = IOSPhoneGoalLoop.liveCandidateSet(in: screen)
        XCTAssertEqual(set.candidates.map(\.action), [.tap(ref: "back")])
        XCTAssertEqual(set.withheld, ["Send"])
    }

    func testLiveHandsBackFinalCommitWithoutTappingAndNeverTapsAloneNextToOne() async {
        let request = IOSPhoneGoalRequest(goal: "发出这条消息", bundleID: "app.test",
                                          completion: .init(kind: .visible, target: .init(identifier: "sent")))
        let onlySend = Fixture([observation("compose", [node("send", id: "send-button", label: "发送")])])
        let result = await onlySend.loop().run(request)
        XCTAssertEqual(result.reasonCode, .finalCommitRequired)
        XCTAssertEqual(result.withheldFinalActions, ["发送"])
        XCTAssertTrue(onlySend.actions.isEmpty)
        XCTAssertEqual(onlySend.chooseCount, 0)

        let withBack = Fixture([observation("compose", [node("back", id: "back", label: "Back"),
                                                        node("send", id: "send", label: "Send", x: 300)])])
        withBack.selections = [.handback("jev_handback")]
        let handedBack = await withBack.loop().run(request)
        XCTAssertEqual(withBack.chooseCount, 1, "A lone candidate next to a withheld commit still needs Jev")
        XCTAssertEqual(withBack.candidateBatches, [["n0"]])
        XCTAssertEqual(handedBack.reasonCode, .finalCommitRequired)
        XCTAssertTrue(withBack.actions.isEmpty)
    }

    func testAlertButtonsBecomeCandidatesButPermissionPromptsAreNeverAnswered() async {
        let request = IOSPhoneGoalRequest(goal: "关闭弹窗并继续", bundleID: "app.test",
                                          completion: .init(kind: .visible, target: .init(identifier: "home")))
        let dialog = PhoneObservedAlert(ref: "alert", text: "Leave this lesson?", processID: 42, buttons: [
            .init(ref: "alert:stay", name: "Keep learning"), .init(ref: "alert:quit", name: "End session"),
        ])
        let covered = PhoneObservation(observationID: "alert", bundleID: "app.test", processID: 42, backend: "test",
            truncated: false, nodes: [node("under", id: "under", label: "Underlying")],
            screenBounds: .init(x: 0, y: 0, width: 402, height: 874), alerts: [dialog], alertActionsSupported: true)
        let fixture = Fixture([covered, observation("home", [node("home", id: "home")])])
        fixture.selections = [.action("alert0.0")]
        let result = await fixture.loop().run(request)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(fixture.candidateBatches, [["alert0.0", "alert0.1"]], "The covered page is not offered")
        XCTAssertEqual(fixture.actions, [.tapAlert(ref: "alert:stay")])

        let permission = PhoneObservedAlert(ref: "perm", text: "“App” Would Like to Access Your Photos", processID: 42,
            buttons: [.init(ref: "perm:deny", name: "Don’t Allow"), .init(ref: "perm:allow", name: "Allow")])
        let prompt = PhoneObservation(observationID: "perm", bundleID: "app.test", processID: 42, backend: "test",
            truncated: false, nodes: [node("under", id: "under", label: "Underlying")],
            screenBounds: .init(x: 0, y: 0, width: 402, height: 874), alerts: [permission], alertActionsSupported: true)
        let set = IOSPhoneGoalLoop.liveCandidateSet(in: prompt)
        XCTAssertTrue(set.candidates.isEmpty)
        XCTAssertEqual(set.withheld, ["Don’t Allow", "Allow"])

        let confirm = PhoneObservedAlert(ref: "confirm", text: "Delete this draft?", processID: 42,
            buttons: [.init(ref: "confirm:cancel", name: "Cancel"), .init(ref: "confirm:ok", name: "OK")])
        let confirmScreen = PhoneObservation(observationID: "confirm", bundleID: "app.test", processID: 42, backend: "test",
            truncated: false, nodes: [node("under", id: "under", label: "Underlying")],
            screenBounds: .init(x: 0, y: 0, width: 402, height: 874), alerts: [confirm], alertActionsSupported: true)
        let confirmSet = IOSPhoneGoalLoop.liveCandidateSet(in: confirmScreen)
        XCTAssertEqual(confirmSet.candidates.map(\.action), [.tapAlert(ref: "confirm:cancel")])
        XCTAssertEqual(confirmSet.withheld, ["OK"], "A generic confirm on a delete prompt is a final commit")
    }

    func testLiveRecoversFromIneffectiveTapByChoosingAnotherControl() async {
        let request = IOSPhoneGoalRequest(goal: "打开详情", bundleID: "app.test",
                                          completion: .init(kind: .visible, target: .init(identifier: "detail")))
        let screen = observation("list", [node("a", id: "a", label: "First"), node("b", id: "b", label: "Second", x: 200)])
        let fixture = Fixture([screen, observation("same", screen.nodes),
                               observation("detail", [node("detail", id: "detail")])])
        fixture.selections = [.action("n0")]
        let result = await fixture.loop().run(request)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(fixture.actions, [.tap(ref: "a"), .tap(ref: "b")],
                       "The ineffective tap is excluded and never repeated on the unchanged screen")
        XCTAssertEqual(fixture.chooseCount, 1, "Only one candidate remains, executed locally")
        XCTAssertTrue(result.steps.first?.contains("screen unchanged") == true)
    }

    func testSequencePageChangeContinuesTowardGoalWithFreshCandidates() async {
        let request = IOSPhoneGoalRequest(goal: "完成本课", bundleID: "app.test", steps: [
            .init(pageAnchor: .init(label: "Question 1"),
                  actions: [.init(action: .tap, target: .init(identifier: "answer"))],
                  expectation: .init(kind: .visible, target: .init(identifier: "next"))),
        ], completion: .init(kind: .visible, target: .init(identifier: "complete")))
        let fixture = Fixture([
            observation("interstitial", [node("continue", id: "continue", label: "Continue")]),
            observation("complete", [node("complete", id: "complete")]),
        ])
        fixture.selections = [.action("n0")]
        let result = await fixture.loop().run(request)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.continuedFrom, .pageChanged)
        XCTAssertEqual(fixture.actions, [.tap(ref: "continue")])
        XCTAssertEqual(fixture.chooseCount, 1, "Off-plan candidates always go through Jev")
        XCTAssertEqual(fixture.requireUnchangedObservations, [true])
    }

    func testBudgetsAllowLongerGoalRuns() throws {
        let completion = IOSPhoneGoalExpectation(kind: .visible, target: .init(identifier: "done"))
        XCTAssertEqual(IOSPhoneGoalRequest(goal: "g", bundleID: "app.test", completion: completion).maxSteps, 15)
        XCTAssertNoThrow(try IOSPhoneGoalRequest(goal: "g", bundleID: "app.test", completion: completion,
                                                 maxSteps: 30).validate())
        XCTAssertThrowsError(try IOSPhoneGoalRequest(goal: "g", bundleID: "app.test", completion: completion,
                                                     maxSteps: 31).validate())
        XCTAssertEqual(IOSPhoneGoalLoop.timeBudgetSeconds, 180)
    }

    func testTimeBudgetIsOneHundredEightySeconds() async {
        for elapsed: TimeInterval in [179, 180] {
            let fixture = Fixture([observation("initial", [node("ref", id: "search"), node("ref-alternative", id: "alternate-search")]),
                                   observation("results", [node("results", id: "results")])])
            fixture.onChoose = { fixture.time += elapsed }
            let result = await fixture.loop().run(branchingRequest())
            XCTAssertEqual(result.reasonCode, elapsed < 180 ? .completed : .timeBudgetExhausted)
        }
    }

    // MARK: Final-commit scope and Jev failure reporting

    func testMessageListRowsAndNotificationTextAreNeverWithheld() {
        // Real labels from a 小米办公 conversation list that were wrongly withheld.
        let notice = "授权操作通知"
        let rejected = "你发起的 “企业自建应用发布申请” 被孙笑月拒绝"
        XCTAssertFalse(IOSPhoneGoalLoop.isFinalCommit(notice))
        XCTAssertFalse(IOSPhoneGoalLoop.isFinalCommit(rejected))
        let screen = observation("conversations", [
            node("row-notice", id: "", type: "XCUIElementTypeCell", label: notice, y: 120, x: 0, width: 402, height: 72),
            node("row-rejected", id: "", type: "XCUIElementTypeCell", label: rejected, y: 200, x: 0, width: 402, height: 72),
            node("text-notice", id: "", type: "XCUIElementTypeStaticText", label: notice, y: 290, x: 72, width: 220, height: 22),
            node("text-rejected", id: "", type: "XCUIElementTypeStaticText", label: rejected, y: 330, x: 72, width: 300, height: 22),
            node("button-notice", id: "", type: "XCUIElementTypeButton", label: notice, y: 380, x: 0, width: 402, height: 72),
            node("group", id: "", type: "XCUIElementTypeCell", label: "李晨, 邓璐良, 刘剑崑", y: 460, x: 0, width: 402, height: 72),
            node("delete-row", id: "", type: "XCUIElementTypeCell", label: "删除", y: 540, x: 0, width: 402, height: 60),
            node("allow-switch", id: "", type: "XCUIElementTypeSwitch", label: "允许通知", y: 610, x: 300, width: 60, height: 32),
        ])
        let set = IOSPhoneGoalLoop.liveCandidateSet(in: screen)
        XCTAssertEqual(set.withheld, [], "Rows, text, switches and long labels are navigation, not commits")
        XCTAssertEqual(set.candidates.map(\.action), [
            "row-notice", "row-rejected", "text-notice", "text-rejected", "button-notice", "group", "delete-row",
            "allow-switch",
        ].map { PhoneAction.tap(ref: $0) })
    }

    func testGenuineCommitButtonsAreWithheld() {
        let labels = ["发送", "Send", "发布", "确认支付", "删除", "登录", "允许", "立即支付", "确认删除", "Post", "Sign in"]
        for label in labels + ["Confirm & Pay", "deleteButton", "Log in with Apple"] {
            XCTAssertTrue(IOSPhoneGoalLoop.isFinalCommit(label), label)
        }
        for label in ["Posts", "Send feedback to the team about this article", "发送验证码", "授权管理设置页面说明",
                      "Don’t Allow", "Display"] {
            XCTAssertFalse(IOSPhoneGoalLoop.isFinalCommit(label), label)
        }
        var nodes = labels.enumerated().map { offset, label in
            node("b\(offset)", id: "", label: label, y: Double(60 + offset * 50), x: 300, width: 80, height: 40)
        }
        // Icon buttons exposed as small Other/Image/StaticText nodes still count.
        nodes.append(node("icon-send", id: "", type: "XCUIElementTypeOther", label: "发送", y: 700, x: 340, width: 44, height: 44))
        nodes.append(node("text-send", id: "", type: "XCUIElementTypeStaticText", label: "Send", y: 760, x: 340, width: 44, height: 24))
        nodes.append(node("id-send", id: "sendButton", label: nil, y: 800, x: 20, width: 44, height: 44))
        // A large container that happens to carry the label is not a button.
        nodes.append(node("panel", id: "", type: "XCUIElementTypeOther", label: "发布", y: 20, x: 0, width: 402, height: 30))
        nodes.append(node("back", id: "", label: "返回", y: 20, x: 0, width: 60, height: 30))
        let set = IOSPhoneGoalLoop.liveCandidateSet(in: observation("compose", nodes))
        XCTAssertEqual(set.withheld, labels + ["发送", "Send", "sendButton"])
        XCTAssertEqual(set.candidates.map(\.action), [.tap(ref: "panel"), .tap(ref: "back")])
    }

    func testJevFailureIsReportedAsJevFailureNotFinalCommit() async {
        let request = IOSPhoneGoalRequest(goal: "打开群聊「李晨, 邓璐良, 刘剑崑」", bundleID: "app.test",
                                          completion: .init(kind: .visible, target: .init(identifier: "chat")))
        let screen = { (id: String) in
            self.observation(id, [self.node("\(id):back", id: "back", label: "Back"),
                                  self.node("\(id):send", id: "send", label: "Send", x: 300)])
        }
        for (reason, code) in [("request_too_large", IOSPhoneGoalLoop.ReasonCode.jevFailed),
                               ("state_too_large", .jevFailed), ("http_401", .jevFailed),
                               ("mode_off", .jevUnavailable), ("budget_exhausted", .jevUnavailable),
                               ("scope_not_allowed", .jevUnavailable)] {
            let fixture = Fixture([screen("list")])
            fixture.selections = [.handback(reason)]
            let result = await fixture.loop().run(request)
            XCTAssertEqual(result.reasonCode, code, reason)
            XCTAssertEqual(result.jevReason, reason)
            XCTAssertTrue(result.reason.contains(reason), result.reason)
            XCTAssertEqual(result.withheldFinalActions, ["Send"], "Withheld controls are still reported")
            XCTAssertTrue(fixture.actions.isEmpty)
            XCTAssertEqual(fixture.chooseCount, 1, "\(reason) is not transient and is not retried")
        }

        // A transient failure is re-read and retried, then reported as a Jev failure.
        let transient = Fixture([screen("t0"), screen("t1"), screen("t2")])
        transient.selections = [.handback("timeout"), .handback("timeout"), .handback("timeout")]
        let timedOut = await transient.loop().run(request)
        XCTAssertEqual(timedOut.reasonCode, .jevFailed)
        XCTAssertEqual(timedOut.jevReason, "timeout")
        XCTAssertEqual(transient.chooseCount, 3)
        XCTAssertEqual(transient.waitCount, 2)
        XCTAssertTrue(transient.actions.isEmpty)

        let recovered = Fixture([screen("r0"), screen("r1"), observation("chat", [node("chat", id: "chat")])])
        recovered.selections = [.handback("timeout"), .action("n0")]
        let completed = await recovered.loop().run(request)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(recovered.actions, [.tap(ref: "r1:back")])
    }

    func testLateDecisionUsesFreshCandidatesAndReportsFailureWhenRecoveryExhausts() async {
        let request = IOSPhoneGoalRequest(goal: "打开详情", bundleID: "app.test",
                                          completion: .init(kind: .visible, target: .init(identifier: "done")))
        func screen(_ id: String) -> PhoneObservation {
            observation(id, [node("\(id):first", id: "first", label: "First"),
                             node("\(id):second", id: "second", label: "Second", x: 200)])
        }
        let recovered = Fixture([screen("initial"), screen("fresh"),
                                 observation("done", [node("done", id: "done")])])
        recovered.selections = [.handback("late"), .action("n0")]

        let completed = await recovered.loop().run(request)

        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(recovered.chooseCount, 2)
        XCTAssertEqual(recovered.waitCount, 1)
        XCTAssertEqual(recovered.actions, [.tap(ref: "fresh:first")], "A late decision cannot dispatch an old ref")

        let exhausted = Fixture([screen("t0"), screen("t1"), screen("t2")])
        exhausted.selections = Array(repeating: .handback("late"), count: 3)

        let failed = await exhausted.loop().run(request)

        XCTAssertEqual(failed.reasonCode, .jevFailed)
        XCTAssertEqual(failed.jevReason, "late")
        XCTAssertEqual(exhausted.chooseCount, 3)
        XCTAssertEqual(exhausted.waitCount, 2)
        XCTAssertTrue(exhausted.actions.isEmpty)
    }

    func testSequenceJevFailureHandsBackWithoutContinuingLive() async {
        let fixture = Fixture([duplicateWordScreen("question")])
        fixture.selections = [.handback("budget_exhausted")]
        let request = IOSPhoneGoalRequest(goal: "选择词块", bundleID: "app.test", steps: [
            .init(pageAnchor: .init(identifier: "question"),
                  actions: [.init(action: .tap, target: .init(label: "go"))],
                  expectation: .init(kind: .visible, target: .init(identifier: "done"))),
        ], completion: .init(kind: .visible, target: .init(identifier: "done")))
        let result = await fixture.loop().run(request)
        XCTAssertEqual(result.reasonCode, .jevUnavailable)
        XCTAssertEqual(result.jevReason, "budget_exhausted")
        XCTAssertNil(result.continuedFrom)
        XCTAssertEqual(fixture.chooseCount, 1)
        XCTAssertTrue(fixture.actions.isEmpty)
    }

    func testCandidatesCarryTheirNodeIndexToJev() {
        let screen = observation("browse", [
            node("list", id: "list", type: "XCUIElementTypeTable", label: nil, y: 100, x: 0, width: 402, height: 700),
            node("row", id: "row", type: "XCUIElementTypeCell", label: "Wi-Fi", y: 120, depth: 2, x: 0, width: 402),
        ])
        let candidates = IOSPhoneGoalLoop.liveCandidates(in: screen).map(\.decisionCandidate)
        XCTAssertEqual(candidates.first { $0.id == "n1" }?.nodeIndex, 1)
        XCTAssertEqual(candidates.first { $0.id == "s0u" }?.nodeIndex, 0)
    }
}
