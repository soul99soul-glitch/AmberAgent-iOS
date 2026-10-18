import AmberPhoneControl
import Foundation
import XCTest
@testable import iosApp


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
