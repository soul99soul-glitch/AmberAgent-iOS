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
                               observation("after", [node("new", id: "search")])])
        let result = await fixture.loop().run(request())
        XCTAssertEqual(result.status, .handback)
        XCTAssertNotEqual(result.verification?.status, .satisfied)
        XCTAssertEqual(fixture.actions, [.tap(ref: "old")])
        XCTAssertEqual(fixture.chooseCount, 0)
        XCTAssertEqual(fixture.observeCount, 2)
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

    func testRepeatedWaitUsesOnlyOneReadonlyRefresh() async {
        let fixture = Fixture([observation("loading", [node("first", id: "search"), node("first-alternative", id: "alternate-search")]),
                               observation("still-loading", [node("second", id: "search"), node("second-alternative", id: "alternate-search")])])
        fixture.selections = [.wait, .wait]
        let result = await fixture.loop().run(branchingRequest())
        XCTAssertEqual(result.status, .handback)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.waitCount, 1)
        XCTAssertEqual(fixture.observeCount, 2)
        XCTAssertEqual(fixture.chooseCount, 2)
        XCTAssertEqual(result.reasonCode, .waitBudgetExhausted)
    }

    func testReadonlyWaitContributesToWaitAndTotalMetrics() async {
        let fixture = Fixture([
            observation("loading", [node("first", id: "search"), node("alternative", id: "alternate-search")]),
            observation("still-loading", [node("second", id: "search"), node("second-alternative", id: "alternate-search")]),
        ])
        fixture.observeDuration = 0.01
        fixture.chooseDuration = 0.02
        fixture.waitDuration = 0.05
        fixture.selections = [.wait, .wait]

        let result = await fixture.loop().run(branchingRequest())

        XCTAssertEqual(result.reasonCode, .waitBudgetExhausted)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.waitCount, 1)
        XCTAssertEqual(result.metrics.waitMs, 50, accuracy: 0.001)
        XCTAssertEqual(result.metrics.totalMs, 110, accuracy: 0.001)
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

    func testCandidateDiagnosticsDistinguishExcludedTargetsWithoutCallingJev() async {
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

    func testTapStillRejectsTwoMatchingButtonsWithTheSameLabel() async {
        let request = IOSPhoneGoalRequest(
            goal: "选择单词", bundleID: "app.test",
            actions: [.init(action: .tap, target: .init(label: "ワンピース"))],
            completion: .init(kind: .visible, target: .init(identifier: "selected")))
        let fixture = Fixture([observation("question", [
            node("first-button", id: "word-1", label: "ワンピース"),
            node("second-button", id: "word-2", label: "ワンピース")
        ])])

        let result = await fixture.loop().run(request)

        XCTAssertEqual(result.reasonCode, .noExecutableCandidates)
        XCTAssertEqual(result.candidateDiagnostics, [.init(id: "a0", reasonCode: .targetAmbiguous)])
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.chooseCount, 0)
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
        let fixture = Fixture([screen, observation("after", screen.nodes)])

        let result = await fixture.loop().run(request)

        XCTAssertEqual(result.reasonCode, .screenUnchanged)
        XCTAssertEqual(fixture.actions, [.tap(ref: "word")])
        XCTAssertEqual(fixture.chooseCount, 0)
        XCTAssertEqual(fixture.adviceCount, 0)
    }

    func testLiveStopsBeforeChoosingOnTruncatedTree() async {
        let request = IOSPhoneGoalRequest(
            goal: "选择单词", bundleID: "app.test",
            completion: .init(kind: .visible, target: .init(identifier: "done")))
        let fixture = Fixture([observation("partial", [node("word", id: "word", label: "ワンピース")], truncated: true)])

        let result = await fixture.loop().run(request)

        XCTAssertEqual(result.reasonCode, .treeTruncated)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.chooseCount, 0)
    }

    func testLegacyAlertHandbackAndWaitBudgetDoNotAdvertiseUnderlyingCandidates() async {
        let nodes = [node("underlying", id: "search"),
                     node("alert", id: "alert", type: "XCUIElementTypeAlert")]
        let covered = observation("covered", nodes)
        let request = request()
        XCTAssertEqual(IOSPhoneGoalLoop.candidates(request.actions, in: covered).count, 1,
                       "The underlying action would otherwise be marked eligible")
        for waits in [false, true] {
            let fixture = Fixture([covered, observation("still-covered", nodes)])
            fixture.selections = waits ? [.wait, .wait] : [.handback("alert")]
            let result = await fixture.loop().run(request)
            XCTAssertEqual(result.status, .handback)
            XCTAssertEqual(result.reasonCode, waits ? .waitBudgetExhausted : .unexpectedAlert)
            XCTAssertTrue(result.candidateDiagnostics.isEmpty)
            XCTAssertTrue(fixture.actions.isEmpty)
            XCTAssertTrue(fixture.candidateBatches.allSatisfy { $0.isEmpty })
            XCTAssertEqual(fixture.chooseCount, waits ? 2 : 1)
            XCTAssertEqual(fixture.observeCount, waits ? 2 : 1)
            XCTAssertEqual(fixture.waitCount, waits ? 1 : 0)
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
        let offResult = await off.loop().run(branchingRequest())
        XCTAssertEqual(offResult.reasonCode, .modeOff)
        XCTAssertEqual(offResult.metrics, .init())
        XCTAssertEqual(off.observeCount, 0)

        let expired = Fixture([observation("initial", [node("ref", id: "search"), node("ref-alternative", id: "alternate-search")])])
        expired.onChoose = { expired.time += 60 }
        let expiredResult = await expired.loop().run(branchingRequest())
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
        XCTAssertEqual(Set(json.keys), ["observe_ms", "choose_ms", "act_ms", "advise_ms", "selection_calls", "review_calls",
                                        "settle_ms", "settle_calls", "local_actions", "wait_ms", "total_ms"])
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
            XCTAssertEqual(fixture.chooseCount, 0)
            if index == 0 {
                XCTAssertEqual(result.status, .completed)
                XCTAssertEqual(fixture.pageAnchorRefs, ["parent"])
                XCTAssertEqual(fixture.actions, [.tap(ref: "open")])
                XCTAssertEqual(fixture.requireUnchangedObservations, [false])
            } else {
                XCTAssertEqual(result.status, .handback)
                XCTAssertEqual(result.reasonCode, .pageChanged)
                XCTAssertTrue(fixture.actions.isEmpty)
                XCTAssertEqual(fixture.observeCount, 1)
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

    func testSequenceStopsWhenQuestionChangesEvenIfNextButtonStillExists() async {
        let screens = sequenceScreens()
        let changed = observation("different-question", [node("new", id: "other-question"),
            node("selected", id: "selected-one"), node("same-button", id: "two")])
        let fixture = Fixture([screens[0], changed])
        let result = await fixture.loop().run(sequenceRequest())
        XCTAssertEqual(result.reasonCode, .pageChanged)
        XCTAssertEqual(result.verifiedStepCount, 1)
        XCTAssertEqual(fixture.actions.count, 1)
        XCTAssertEqual(fixture.observeCount, 2)
        XCTAssertEqual(fixture.chooseCount, 0)
    }

    func testSequenceIncompleteResultDoesNotExposeSuccessOrOldCandidates() async {
        let changed = observation("new-question", [node("q2", id: "other-question"),
            node("selected", id: "selected-one"), node("done", id: "done")])
        let fixture = Fixture([sequenceScreens()[0], changed])
        let result = await fixture.loop().run(sequenceRequest())
        XCTAssertEqual(result.reasonCode, .pageChanged)
        XCTAssertEqual(result.verifiedStepCount, 1)
        XCTAssertNil(result.verification, "The overall goal is not verified before all steps finish")
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

    func testSequenceRejectsAmbiguousTargetsAndInactiveModesBeforeClicking() async {
        let initial = observation("ambiguous", [node("q", id: "question"),
            node("one", id: "one"), node("duplicate", id: "one")])
        let ambiguous = Fixture([initial])
        let result = await ambiguous.loop().run(sequenceRequest())
        XCTAssertEqual(result.reasonCode, .ambiguousTarget)
        XCTAssertTrue(ambiguous.actions.isEmpty)
        XCTAssertEqual(ambiguous.chooseCount, 0)
        let fixture = Fixture(sequenceScreens())
        fixture.mode = .off
        let off = await fixture.loop().run(sequenceRequest())
        XCTAssertEqual(off.reasonCode, .modeOff)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.observeCount, 0)
    }

    func testSequenceStopsWhenQuestionTextChangesUnderTheSameIdentifier() async {
        let before = observation("q1", [node("q", id: "question", value: "Translate cat"), node("one", id: "one")])
        let after = observation("q2", [node("q", id: "question", value: "Translate dog"),
            node("selected", id: "selected-one"), node("two", id: "two")])
        let fixture = Fixture([before, after])
        let result = await fixture.loop().run(sequenceRequest())
        XCTAssertEqual(result.reasonCode, .pageChanged)
        XCTAssertEqual(fixture.actions.count, 1)
        XCTAssertEqual(result.verifiedStepCount, 1)
    }

    func testSequenceCannotUseJevContinueToOverrideUnmetStepExpectation() async {
        let fixture = Fixture([sequenceScreens()[0], observation("unchanged", sequenceScreens()[0].nodes)])
        fixture.advices = [.continueTask]
        let result = await fixture.loop().run(sequenceRequest())
        XCTAssertEqual(result.reasonCode, .stepExpectationUnmet)
        XCTAssertEqual(result.verifiedStepCount, 0)
        XCTAssertEqual(result.stepVerification?.status, .unmet)
        XCTAssertEqual(fixture.actions.count, 1)
        XCTAssertEqual(fixture.adviceCount, 1)
        XCTAssertEqual(fixture.observeCount, 2)
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
        XCTAssertEqual(fixture.adviceCount, 1)
        XCTAssertEqual(fixture.chooseCount, 0)
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
            XCTAssertEqual(fixture.settleCount, 1)
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
