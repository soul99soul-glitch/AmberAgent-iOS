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

    func testGoalWithoutActionsOrStepsUsesLiveCandidateMode() throws {
        guard case .runGoal(let request) = try IOSPhoneControlToolExecutor.request(
            name: "phone_run_goal", arguments: json([
                "goal": "完成当前页面上的下一步",
                "bundle_id": "app.test",
                "completion": ["kind": "visible", "target": ["identifier": "done"]],
            ])) else { return XCTFail("Expected live-candidate goal request") }
        XCTAssertTrue(request.usesLiveCandidates)
        XCTAssertTrue(request.actions.isEmpty)
        XCTAssertNil(request.steps)
        XCTAssertEqual(request.maxSteps, 6)
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertEqual(try IOSPhoneControlToolExecutor.request(name: "phone_run_goal", arguments: encoded), .runGoal(request))
    }

    func testGoalArgumentPresenceAndRegionContractStaysStrict() throws {
        for keyValue in [("actions", [] as Any), ("actions", NSNull()), ("steps", NSNull())] {
            var arguments: [String: Any] = [
                "goal": "完成当前页面上的下一步",
                "bundle_id": "app.test",
                "completion": ["kind": "visible", "target": ["identifier": "done"]],
            ]
            arguments[keyValue.0] = keyValue.1
            XCTAssertThrowsError(
                try IOSPhoneControlToolExecutor.request(name: "phone_run_goal", arguments: json(arguments)),
                "\(keyValue.0) presence must not turn an empty/null list into live mode"
            )
        }

        let validRegion: [String: Any] = [
            "x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4,
        ]
        var valid = validGoal()
        valid["actions"] = [["action": "tap", "target": ["label": "Next", "region": validRegion]]]
        guard case .runGoal(let request) = try IOSPhoneControlToolExecutor.request(
            name: "phone_run_goal", arguments: json(valid)) else {
            return XCTFail("Expected region-bearing goal request")
        }
        XCTAssertEqual(request.actions.first?.target.region, .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4))

        var unknownRegion = valid
        unknownRegion["actions"] = [["action": "tap", "target": [
            "label": "Next", "region": ["x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4, "extra": 1],
        ]]]
        XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(
            name: "phone_run_goal", arguments: json(unknownRegion)))

        var booleanRegion = valid
        booleanRegion["actions"] = [["action": "tap", "target": ["label": "Next", "region": true]]]
        XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(
            name: "phone_run_goal", arguments: json(booleanRegion)))

        var extraCompletionField = validGoal()
        extraCompletionField["completion"] = [
            "kind": "visible", "target": ["identifier": "done"], "identifier": "outer-field",
        ]
        XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(
            name: "phone_run_goal", arguments: json(extraCompletionField))) { error in
                XCTAssertTrue(error.localizedDescription.contains("identifier"), error.localizedDescription)
            }
    }

    func testGoalParsesOrderedStepsWithStepDefaultAndStrictNestedFields() throws {
        let step: [String: Any] = [
            "page_anchor": ["label": "Question 1"],
            "actions": [
                ["action": "tap", "target": ["identifier": "answer-a"]],
                ["action": "tap", "target": ["identifier": "answer-b"]],
            ],
            "expectation": ["kind": "visible", "target": ["label": "Question 2"]],
            "wait_for_stability": true,
        ]
        guard case .runGoal(let request) = try IOSPhoneControlToolExecutor.request(
            name: "phone_run_goal", arguments: json([
                "goal": "Answer the next question",
                "bundle_id": "app.test",
                "steps": [step],
                "completion": ["kind": "visible", "target": ["label": "Lesson complete"]],
            ])) else { return XCTFail("Expected ordered goal request") }
        XCTAssertTrue(request.actions.isEmpty)
        XCTAssertEqual(request.steps?.count, 1)
        XCTAssertEqual(request.maxSteps, 1)
        XCTAssertEqual(request.steps?.first?.pageAnchor, .init(label: "Question 1"))
        XCTAssertEqual(request.steps?.first?.actions.count, 2)
        XCTAssertEqual(request.steps?.first?.waitForStability, true)
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertEqual(try IOSPhoneControlToolExecutor.request(name: "phone_run_goal", arguments: encoded), .runGoal(request))
    }

    func testGoalRejectsAmbiguousOrUnknownOrderedStepShape() throws {
        var both = validGoal()
        both["steps"] = [[
            "page_anchor": ["label": "Question 1"],
            "actions": [["action": "tap", "target": ["identifier": "answer"]]],
            "expectation": ["kind": "visible", "target": ["label": "Question 2"]],
        ]]
        XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_run_goal", arguments: json(both)))

        var unknown = validGoal()
        unknown.removeValue(forKey: "actions")
        unknown["steps"] = [[
            "page_anchor": ["label": "Question 1"],
            "actions": [["action": "tap", "target": ["identifier": "answer"]]],
            "expectation": ["kind": "visible", "target": ["label": "Question 2"]],
            "extra": true,
        ]]
        XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_run_goal", arguments: json(unknown)))

        var emptyAnchor = validGoal()
        emptyAnchor.removeValue(forKey: "actions")
        emptyAnchor["steps"] = [[
            "page_anchor": ["label": "   "],
            "actions": [["action": "tap", "target": ["identifier": "answer"]]],
            "expectation": ["kind": "visible", "target": ["label": "Question 2"]],
        ]]
        XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_run_goal", arguments: json(emptyAnchor)))
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

    func testSequenceChecksPageAnchorAtDispatchAfterJevReturns() async throws {
        let fixture = GoalHTTPFixture(GoalHTTPFixture.observation + [
            GoalHTTPFixture.active,
            .init(path: "/elements", body: #"{"value":[{"element-6066-11e4-a52e-4f735466cecf":"FRESH"}]}"#),
            // The button still matches, but the page anchor changed while Jev decided.
            .init(path: "/elements", body: #"{"value":[]}"#),
        ])
        defer { fixture.unregister() }
        let runner = try fixture.makeRunner()
        var selected = false
        let loop = IOSPhoneGoalLoop(deps: .init(
            observe: { try await runner.observe(includeScreenSize: true) },
            act: { action, anchor, region, requireUnchanged in
                XCTAssertTrue(selected)
                XCTAssertNotNil(anchor, "The step's page anchor must reach the real client")
                XCTAssertFalse(requireUnchanged)
                return await runner.act(action, pageAnchorRef: anchor, pageAnchorRegion: region,
                                        requireUnchangedObservation: requireUnchanged)
            },
            choose: { _, _, _, _, _ in selected = true; return .action("a0") },
            advise: { _, _, _, _, _ in XCTFail("An unsent action must not be verified"); return .handback },
            mode: { .active }, isCurrent: { true }, reportActivity: { _ in }
        ))
        let result = await loop.run(.init(goal: "Close the popup on this page", bundleID: "app.test", steps: [
            .init(pageAnchor: .init(identifier: "home"), actions: [
                .init(action: .tap, target: .init(identifier: "popup")),
                .init(action: .tap, target: .init(identifier: "home")),
            ], expectation: .init(kind: .absent, target: .init(identifier: "popup"), anchor: .init(identifier: "home")))
        ], completion: .init(kind: .visible, target: .init(identifier: "home"))))
        XCTAssertEqual(result.reasonCode, .actionNotSent)
        XCTAssertTrue(result.steps.isEmpty)
        XCTAssertTrue(result.candidateDiagnostics.isEmpty)
        XCTAssertNil(result.verification)
        XCTAssertEqual(fixture.paths.filter { $0 == "/elements" }.count, 2)
        XCTAssertEqual(fixture.paths.filter { $0 == "/source" }.count, 1, "Checking an anchor must not fetch another full tree")
        XCTAssertFalse(fixture.paths.contains { $0.hasSuffix("/click") })
    }

    func testSequenceUsesRealRunnerForNamedOtherToStaticTextMoveAndStopsAfterTwoClicks() async throws {
        let fixture = GoalHTTPFixture(
            GoalHTTPFixture.observation(tree: #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":400,"height":800},"children":[{"type":"XCUIElementTypeStaticText","rawIdentifier":"question","label":"Question 1","value":"Question 1","isEnabled":"0","rect":{"x":20,"y":20,"width":200,"height":24},"children":[]},{"type":"XCUIElementTypeOther","rawIdentifier":"word","label":"go","isEnabled":"1","rect":{"x":20,"y":560,"width":80,"height":44},"children":[]},{"type":"XCUIElementTypeButton","rawIdentifier":"next","label":"Next","isEnabled":"1","rect":{"x":20,"y":700,"width":80,"height":44},"children":[]}]}}"#)
            + GoalHTTPFixture.click
            + GoalHTTPFixture.observation(tree: #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":400,"height":800},"children":[{"type":"XCUIElementTypeStaticText","rawIdentifier":"question","label":"Question 1","value":"Question 1","isEnabled":"0","rect":{"x":20,"y":20,"width":200,"height":24},"children":[]},{"type":"XCUIElementTypeStaticText","rawIdentifier":"word","label":"go","isEnabled":"1","rect":{"x":20,"y":280,"width":80,"height":44},"children":[]},{"type":"XCUIElementTypeButton","rawIdentifier":"next","label":"Next","isEnabled":"1","rect":{"x":20,"y":700,"width":80,"height":44},"children":[]}]}}"#)
            + GoalHTTPFixture.click
            + GoalHTTPFixture.observation(tree: #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":400,"height":800},"children":[{"type":"XCUIElementTypeStaticText","rawIdentifier":"question","label":"Question 1","value":"Question 1","isEnabled":"0","rect":{"x":20,"y":20,"width":200,"height":24},"children":[]},{"type":"XCUIElementTypeStaticText","rawIdentifier":"word","label":"go","isEnabled":"1","rect":{"x":20,"y":280,"width":80,"height":44},"children":[]},{"type":"XCUIElementTypeStaticText","rawIdentifier":"done","label":"Done","isEnabled":"1","rect":{"x":20,"y":700,"width":80,"height":44},"children":[]}]}}"#)
        )
        defer { fixture.unregister() }
        let runner = try fixture.makeRunner()
        var actions: [PhoneAction] = []
        var pageAnchors: [String?] = []
        let loop = IOSPhoneGoalLoop(deps: .init(
            observe: { try await runner.observe(includeScreenSize: true) },
            act: { action, pageAnchor, pageRegion, requireUnchanged in
                actions.append(action)
                pageAnchors.append(pageAnchor)
                XCTAssertFalse(requireUnchanged)
                return await runner.act(action, pageAnchorRef: pageAnchor, pageAnchorRegion: pageRegion,
                                        requireUnchangedObservation: requireUnchanged)
            },
            choose: { _, _, _, _, _ in
                XCTFail("A uniquely resolved sequence step must stay local")
                return .handback("unexpected_selection")
            },
            advise: { _, _, _, _, _ in
                XCTFail("A satisfied step must not ask Jev to re-decide")
                return .handback
            },
            mode: { .active }, isCurrent: { true }, reportActivity: { _ in }
        ))
        guard case .runGoal(let request) = try IOSPhoneControlToolExecutor.request(name: "phone_run_goal", arguments: json([
            "goal": "把词块移动到目标区域并进入下一步",
            "bundle_id": "app.test",
            "steps": [
                [
                    "page_anchor": ["identifier": "question", "label": "Question 1"],
                    "actions": [["action": "tap", "target": [
                        "identifier": "word", "label": "go", "type": "XCUIElementTypeOther",
                        "region": ["x": 0.0, "y": 0.6, "width": 1.0, "height": 0.3],
                    ]]],
                    "expectation": ["kind": "visible", "target": [
                        "identifier": "word", "label": "go", "type": "XCUIElementTypeStaticText",
                        "region": ["x": 0.0, "y": 0.3, "width": 1.0, "height": 0.25],
                    ]],
                ],
                [
                    "page_anchor": ["identifier": "question", "label": "Question 1"],
                    "actions": [["action": "tap", "target": ["identifier": "next", "label": "Next", "type": "XCUIElementTypeButton"]]],
                    "expectation": ["kind": "visible", "target": ["identifier": "done", "label": "Done", "type": "XCUIElementTypeStaticText"]],
                ],
            ],
            "completion": ["kind": "visible", "target": ["identifier": "done", "label": "Done", "type": "XCUIElementTypeStaticText"]],
        ])) else { return XCTFail("Expected sequence goal request") }

        let result = await loop.run(request)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.reasonCode, .completed)
        XCTAssertEqual(result.verifiedStepCount, 2)
        XCTAssertEqual(result.steps, ["s0/a0: completed", "s1/a0: completed"])
        XCTAssertEqual(actions.count, 2)
        XCTAssertTrue(pageAnchors.allSatisfy { $0 != nil })
        XCTAssertEqual(fixture.paths.filter { $0 == "/source" }.count, 3,
                       "Two dispatched actions reuse each post-action observation, so source is n+1")
        XCTAssertEqual(fixture.paths.filter { $0.hasSuffix("/click") }.count, 2,
                       "Both selected targets must reach the real runner click endpoint")
        XCTAssertEqual(fixture.paths.filter { $0 == "/elements" }.count, 4,
                       "Each click must perform one target lookup and one unchanged page-anchor lookup")
    }

    func testActionsGoalChoosesBranchOnceThenRunsUniqueRemainderLocally() async throws {
        let firstTree = try GoalHTTPFixture.lessonTree(
            words: [("word-i", "I", 20, 560), ("word-go", "go", 130, 560)],
            showsCheck: false, showsContinue: false
        )
        let secondTree = try GoalHTTPFixture.lessonTree(
            words: [("word-i", "I", 20, 260), ("word-go", "go", 130, 560)],
            showsCheck: false, showsContinue: false
        )
        let thirdTree = try GoalHTTPFixture.lessonTree(
            words: [("word-i", "I", 20, 260), ("word-go", "go", 130, 260)],
            showsCheck: true, showsContinue: false
        )
        let finalTree = try GoalHTTPFixture.lessonTree(
            words: [("word-i", "I", 20, 260), ("word-go", "go", 130, 260)],
            showsCheck: false, showsContinue: true
        )
        let fixture = GoalHTTPFixture(
            GoalHTTPFixture.observation(tree: firstTree)
                + GoalHTTPFixture.tapWithoutAnchor(tree: firstTree)
                + GoalHTTPFixture.observation(tree: secondTree)
                + GoalHTTPFixture.tapWithoutAnchor(tree: secondTree)
                + GoalHTTPFixture.observation(tree: thirdTree)
                + GoalHTTPFixture.tapWithoutAnchor(tree: thirdTree)
                + GoalHTTPFixture.observation(tree: finalTree)
        )
        defer { fixture.unregister() }
        let runner = try fixture.makeRunner()

        var configuredSettings = IOSJevSettings()
        configuredSettings.setPinnedModelVersion("jev-phone-fixture-v1")
        configuredSettings.setMode(.active, for: .phoneActions)
        configuredSettings.setMode(.active, for: .phoneVerification)
        configuredSettings.setScopes([.selectedTaskText, .phoneContent], for: .phoneActions)
        configuredSettings.setScopes([.selectedTaskText, .phoneContent], for: .phoneVerification)
        let settings = configuredSettings

        let selectionCalls = JevCallCounter()
        let adviceCalls = JevCallCounter()
        let jevTransport = JevStubTransport { request in
            let body: [String: Any]
            if let data = request.httpBody,
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                body = decoded
            } else {
                body = [:]
            }
            let questions = body["questions"] as? [String: Any]
            let question = questions?["single.next_step"] as? [String: Any]
            let options = question?["criteria"] as? [String: Any] ?? [:]
            let choice: String
            if options["continue"] != nil {
                _ = adviceCalls.next()
                choice = "handback"
            } else {
                _ = selectionCalls.next()
                choice = "a0"
            }
            let payload: [String: Any] = [
                "model": "jev-phone-fixture-v1",
                "answers": ["single.next_step": [
                    "type": "choice", "choice": choice, "confidence": 0.95,
                ]],
            ]
            return (try! JSONSerialization.data(withJSONObject: payload), jevResponse(200))
        }
        let jevCoordinator = IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: jevTransport),
            settingsProvider: { settings },
            apiKeyProvider: { "fixture-key" },
            now: { Date() },
            metricsStore: { _, _ in }
        ))
        let jev = IOSJevPhoneControlService(deps: .init(
            coordinator: jevCoordinator, settingsProvider: { settings }
        ))

        let completion = IOSPhoneGoalExpectation(
            kind: .visible,
            target: .init(label: "Continue", type: "XCUIElementTypeButton",
                          region: .init(x: 0, y: 0.85, width: 0.3, height: 0.1))
        )
        var candidateIDs: [[String]] = []
        var actionRefs: [String] = []
        let loop = IOSPhoneGoalLoop(deps: .init(
            observe: { try await runner.observe(includeScreenSize: true) },
            act: { action, pageAnchor, pageRegion, requireUnchanged in
                XCTAssertNil(pageAnchor)
                XCTAssertNil(pageRegion)
                XCTAssertTrue(requireUnchanged,
                              "Jev-selected root actions need a final unchanged-screen check before dispatch")
                if case .tap(let ref) = action { actionRefs.append(ref) }
                return await runner.act(action, pageAnchorRef: pageAnchor, pageAnchorRegion: pageRegion,
                                        requireUnchangedObservation: requireUnchanged)
            },
            choose: { goal, observation, candidates, recentSteps, expectation in
                candidateIDs.append(candidates.map(\.id))
                return await jev.chooseAction(goal: goal, observation: observation, candidates: candidates,
                                              recentSteps: recentSteps, expectation: expectation,
                                              runID: "actions-goal-tool-integration")
            },
            advise: { goal, expectation, before, after, verification in
                await jev.adviseAfterAction(goal: goal, expectation: expectation, before: before, after: after,
                                            verification: verification, runID: "actions-goal-tool-integration")
            },
            mode: { .active }, isCurrent: { true }, reportActivity: { _ in }
        ))
        guard case .runGoal(let request) = try IOSPhoneControlToolExecutor.request(name: "phone_run_goal", arguments: json([
            "goal": "按顺序选择词块并点击检查",
            "bundle_id": "app.test",
            "max_steps": 3,
            "actions": [
                ["action": "tap", "target": [
                    "label": "I", "region": ["x": 0.0, "y": 0.65, "width": 0.25, "height": 0.1],
                ]],
                ["action": "tap", "target": [
                    "label": "go", "region": ["x": 0.25, "y": 0.65, "width": 0.25, "height": 0.1],
                ]],
                ["action": "tap", "target": [
                    "label": "Check", "type": "XCUIElementTypeButton",
                    "region": ["x": 0.0, "y": 0.85, "width": 0.3, "height": 0.1],
                ]],
            ],
            "completion": [
                "kind": "visible",
                "target": ["label": "Continue", "type": "XCUIElementTypeButton",
                            "region": ["x": 0.0, "y": 0.85, "width": 0.3, "height": 0.1]],
            ],
        ])) else { return XCTFail("Expected actions goal request") }

        let result = await loop.run(request)
        XCTAssertFalse(request.usesLiveCandidates)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.reasonCode, .completed)
        XCTAssertEqual(result.steps, ["a0: completed", "a1: completed", "a2: completed"])
        XCTAssertEqual(result.verification?.status, .satisfied)
        XCTAssertEqual(selectionCalls.current, 1,
                       "Only the first two-candidate branch needs Jev")
        XCTAssertEqual(adviceCalls.current, 0,
                       "Intermediate completion is not an action verification failure")
        XCTAssertEqual(candidateIDs, [["a0", "a1"]])
        XCTAssertEqual(actionRefs.count, 3)
        XCTAssertEqual(Set(actionRefs).count, 3, "Every post-action observation must produce fresh refs")
        XCTAssertEqual(result.metrics.selectionCalls, 1)
        XCTAssertEqual(result.metrics.reviewCalls, 0)
        XCTAssertEqual(result.metrics.localActions, 2)
        XCTAssertEqual(fixture.paths.filter { $0 == "/source" }.count, 7,
                       "Four full observations plus three dispatch-time source checks")
        XCTAssertEqual(fixture.paths.filter { $0 == "/elements" }.count, 3)
        XCTAssertEqual(fixture.paths.filter { $0.hasSuffix("/click") }.count, 3)
    }

    func testLiveGoalWithoutCandidatesUsesJevSelectionAndRealRunnerUntilCompletion() async throws {
        let fixture = GoalHTTPFixture(
            GoalHTTPFixture.observation(tree: #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":400,"height":800},"children":[{"type":"XCUIElementTypeStaticText","rawIdentifier":"question","label":"Question 1","value":"Question 1","isEnabled":"0","rect":{"x":20,"y":20,"width":200,"height":24},"children":[]},{"type":"XCUIElementTypeOther","rawIdentifier":"word","label":"go","isEnabled":"1","rect":{"x":20,"y":560,"width":80,"height":44},"children":[]},{"type":"XCUIElementTypeButton","rawIdentifier":"next","label":"Next","isEnabled":"1","rect":{"x":20,"y":700,"width":80,"height":44},"children":[]}]}}"#)
            + GoalHTTPFixture.tapWithoutAnchor(tree: #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":400,"height":800},"children":[{"type":"XCUIElementTypeStaticText","rawIdentifier":"question","label":"Question 1","value":"Question 1","isEnabled":"0","rect":{"x":20,"y":20,"width":200,"height":24},"children":[]},{"type":"XCUIElementTypeOther","rawIdentifier":"word","label":"go","isEnabled":"1","rect":{"x":20,"y":560,"width":80,"height":44},"children":[]},{"type":"XCUIElementTypeButton","rawIdentifier":"next","label":"Next","isEnabled":"1","rect":{"x":20,"y":700,"width":80,"height":44},"children":[]}]}}"#)
            + GoalHTTPFixture.observation(tree: #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":400,"height":800},"children":[{"type":"XCUIElementTypeStaticText","rawIdentifier":"question","label":"Question 1","value":"Question 1","isEnabled":"0","rect":{"x":20,"y":20,"width":200,"height":24},"children":[]},{"type":"XCUIElementTypeStaticText","rawIdentifier":"word","label":"go","isEnabled":"1","rect":{"x":20,"y":280,"width":80,"height":44},"children":[]},{"type":"XCUIElementTypeButton","rawIdentifier":"next","label":"Next","isEnabled":"1","rect":{"x":20,"y":700,"width":80,"height":44},"children":[]}]}}"#)
            + GoalHTTPFixture.tapWithoutAnchor(tree: #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":400,"height":800},"children":[{"type":"XCUIElementTypeStaticText","rawIdentifier":"question","label":"Question 1","value":"Question 1","isEnabled":"0","rect":{"x":20,"y":20,"width":200,"height":24},"children":[]},{"type":"XCUIElementTypeStaticText","rawIdentifier":"word","label":"go","isEnabled":"1","rect":{"x":20,"y":280,"width":80,"height":44},"children":[]},{"type":"XCUIElementTypeButton","rawIdentifier":"next","label":"Next","isEnabled":"1","rect":{"x":20,"y":700,"width":80,"height":44},"children":[]}]}}"#)
            + GoalHTTPFixture.observation(tree: #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":400,"height":800},"children":[{"type":"XCUIElementTypeStaticText","rawIdentifier":"question","label":"Question 1","value":"Question 1","isEnabled":"0","rect":{"x":20,"y":20,"width":200,"height":24},"children":[]},{"type":"XCUIElementTypeStaticText","rawIdentifier":"word","label":"go","isEnabled":"1","rect":{"x":20,"y":280,"width":80,"height":44},"children":[]},{"type":"XCUIElementTypeStaticText","rawIdentifier":"done","label":"Done","isEnabled":"1","rect":{"x":20,"y":700,"width":80,"height":44},"children":[]}]}}"#)
        )
        defer { fixture.unregister() }
        let runner = try fixture.makeRunner()
        var configuredSettings = IOSJevSettings()
        configuredSettings.setPinnedModelVersion("jev-phone-fixture-v1")
        configuredSettings.setMode(.active, for: .phoneActions)
        configuredSettings.setMode(.active, for: .phoneVerification)
        configuredSettings.setScopes([.selectedTaskText, .phoneContent], for: .phoneActions)
        configuredSettings.setScopes([.selectedTaskText, .phoneContent], for: .phoneVerification)
        let settings = configuredSettings
        let jevCalls = JevCallCounter()
        let jevTransport = JevStubTransport { _ in
            let choice = jevCalls.next() == 1 ? "n2" : "n3"
            let payload: [String: Any] = [
                "model": "jev-phone-fixture-v1",
                "answers": ["single.next_step": [
                    "type": "choice", "choice": choice, "confidence": 0.95,
                ]],
            ]
            return (try! JSONSerialization.data(withJSONObject: payload), jevResponse(200))
        }
        let jevCoordinator = IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: jevTransport),
            settingsProvider: { settings },
            apiKeyProvider: { "fixture-key" },
            now: { Date() },
            metricsStore: { _, _ in }
        ))
        let jev = IOSJevPhoneControlService(deps: .init(
            coordinator: jevCoordinator, settingsProvider: { settings }
        ))
        var selectedDescriptions: [String] = []
        var actions: [PhoneAction] = []
        let liveExpectation = IOSPhoneGoalExpectation(
            kind: .visible, target: .init(label: "Done", identifier: "done")
        )
        let loop = IOSPhoneGoalLoop(deps: .init(
            observe: { try await runner.observe(includeScreenSize: true) },
            act: { action, pageAnchor, pageRegion, requireUnchanged in
                XCTAssertNil(pageAnchor, "Live candidates do not invent a page anchor")
                XCTAssertNil(pageRegion)
                XCTAssertTrue(requireUnchanged)
                actions.append(action)
                return await runner.act(action, pageAnchorRef: pageAnchor, pageAnchorRegion: pageRegion,
                                        requireUnchangedObservation: requireUnchanged)
            },
            choose: { goal, observation, candidates, recentSteps, expectation in
                XCTAssertEqual(expectation, Optional(liveExpectation))
                let selection = await jev.chooseAction(
                    goal: goal, observation: observation, candidates: candidates,
                    recentSteps: recentSteps, expectation: expectation,
                    runID: "goal-tool-integration"
                )
                if case .action(let id) = selection,
                   let candidate = candidates.first(where: { $0.id == id }) {
                    selectedDescriptions.append(candidate.description)
                }
                return selection
            },
            advise: { _, _, _, _, _ in
                XCTFail("Live progress should not enter legacy verification advice")
                return .handback
            },
            mode: { .active }, isCurrent: { true }, reportActivity: { _ in }
        ))
        guard case .runGoal(let request) = try IOSPhoneControlToolExecutor.request(name: "phone_run_goal", arguments: json([
            "goal": "选择词块并进入下一步",
            "bundle_id": "app.test",
            "completion": ["kind": "visible", "target": ["identifier": "done", "label": "Done"]],
        ])) else { return XCTFail("Expected live goal request") }

        let result = await loop.run(request)
        XCTAssertTrue(request.usesLiveCandidates)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.reasonCode, .completed)
        XCTAssertEqual(jevCalls.current, 2)
        XCTAssertEqual(selectedDescriptions.count, 2)
        XCTAssertTrue(selectedDescriptions[0].contains("label=go"))
        XCTAssertTrue(selectedDescriptions[1].contains("label=Next"))
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(fixture.paths.filter { $0 == "/source" }.count, 5,
                       "Live mode has three loop observations plus one pre-mutation source check per action")
        XCTAssertEqual(fixture.paths.filter { $0.hasSuffix("/click") }.count, 2)
    }

    func testBothGoalModesRejectChangedSourceBeforeMutationAfterJevSelection() async throws {
        for live in [false, true] {
            let changedTree = #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":400,"height":800},"children":[{"type":"XCUIElementTypeButton","rawIdentifier":"popup","label":"Close","isEnabled":"1","rect":{"x":160,"y":500,"width":80,"height":44},"children":[]},{"type":"XCUIElementTypeButton","rawIdentifier":"home","label":"Changed page","isEnabled":"1","rect":{"x":20,"y":700,"width":80,"height":44},"children":[]}]}}"#
            let fixture = GoalHTTPFixture(GoalHTTPFixture.observation + [
                GoalHTTPFixture.active,
                .init(path: "/elements", body: #"{"value":[{"element-6066-11e4-a52e-4f735466cecf":"FRESH"}]}"#),
                .init(path: "/source", body: changedTree),
                GoalHTTPFixture.active,
            ])
            defer { fixture.unregister() }
            let runner = try fixture.makeRunner()
            let expectation = IOSPhoneGoalExpectation(kind: .visible, target: .init(identifier: "done"))
            var selected = false
            let loop = IOSPhoneGoalLoop(deps: .init(
                observe: { try await runner.observe(includeScreenSize: true) },
                act: { action, pageAnchor, pageRegion, requireUnchanged in
                    XCTAssertTrue(selected, "The source check must run after Jev returns")
                    XCTAssertNil(pageAnchor)
                    XCTAssertNil(pageRegion)
                    XCTAssertTrue(requireUnchanged)
                    return await runner.act(action, pageAnchorRef: pageAnchor, pageAnchorRegion: pageRegion,
                                            requireUnchangedObservation: requireUnchanged)
                },
                choose: { _, _, candidates, _, receivedExpectation in
                    XCTAssertEqual(receivedExpectation, Optional(expectation))
                    selected = true
                    let choice = live ? "n1" : "a0"
                    XCTAssertTrue(candidates.contains { $0.id == choice })
                    return .action(choice)
                },
                advise: { _, _, _, _, _ in XCTFail("The stale dispatch must not enter verification"); return .handback },
                mode: { .active }, isCurrent: { true }, reportActivity: { _ in }
            ))
            var arguments: [String: Any] = [
                "goal": "关闭当前弹窗", "bundle_id": "app.test",
                "completion": ["kind": "visible", "target": ["identifier": "done"]],
            ]
            if !live {
                arguments["actions"] = [
                    ["action": "tap", "target": ["identifier": "popup"]],
                    ["action": "tap", "target": ["identifier": "home"]],
                ]
            }
            guard case .runGoal(let request) = try IOSPhoneControlToolExecutor.request(
                name: "phone_run_goal", arguments: json(arguments)) else { return XCTFail("Expected goal request") }
            XCTAssertEqual(request.usesLiveCandidates, live)

            let result = await loop.run(request)
            XCTAssertTrue(selected)
            XCTAssertEqual(result.reasonCode, .actionNotSent)
            XCTAssertTrue(result.steps.isEmpty)
            XCTAssertEqual(fixture.paths.filter { $0 == "/source" }.count, 2,
                           "The second source is the pre-mutation context check")
            XCTAssertFalse(fixture.paths.contains { $0.hasSuffix("/click") },
                           "A changed page must stop before the real click")
        }
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

    static func observation(tree: String) -> [Reply] {
        [active,
         .init(path: "/source", body: tree),
         .init(path: "/window/size", body: #"{"value":{"width":400,"height":800}}"#),
         active]
    }

    static var click: [Reply] {
        [active,
         .init(path: "/elements", body: #"{"value":[{"element-6066-11e4-a52e-4f735466cecf":"FRESH"}]}"#),
         .init(path: "/elements", body: #"{"value":[{"element-6066-11e4-a52e-4f735466cecf":"ANCHOR"}]}"#),
         active,
         .init(path: "/element/FRESH/click", body: #"{"value":null}"#)]
    }

    static func tapWithoutAnchor(tree: String) -> [Reply] {
        [active,
         .init(path: "/elements", body: #"{"value":[{"element-6066-11e4-a52e-4f735466cecf":"FRESH"}]}"#),
         .init(path: "/source", body: tree),
         active,
         .init(path: "/element/FRESH/click", body: #"{"value":null}"#)]
    }

    static func lessonTree(words: [(String, String, Int, Int)], showsCheck: Bool,
                           showsContinue: Bool) throws -> String {
        func control(type: String, id: String, label: String, x: Int, y: Int) -> [String: Any] {
            ["type": type, "rawIdentifier": id, "label": label, "isEnabled": "1",
             "rect": ["x": x, "y": y, "width": 80, "height": 44],
             "children": [["type": "XCUIElementTypeStaticText", "label": label, "value": label,
                            "isEnabled": "1", "rect": ["x": x + 10, "y": y + 10, "width": 60, "height": 24],
                            "children": []]]]
        }
        var children: [[String: Any]] = [[
            "type": "XCUIElementTypeStaticText", "rawIdentifier": "question", "label": "Question 1",
            "value": "Question 1", "isEnabled": "0",
            "rect": ["x": 20, "y": 20, "width": 200, "height": 24], "children": [],
        ]]
        children += words.map { control(type: "XCUIElementTypeOther", id: $0.0, label: $0.1, x: $0.2, y: $0.3) }
        if showsCheck { children.append(control(type: "XCUIElementTypeButton", id: "check", label: "Check", x: 20, y: 700)) }
        if showsContinue { children.append(control(type: "XCUIElementTypeButton", id: "continue", label: "Continue", x: 20, y: 700)) }
        let tree: [String: Any] = ["value": ["type": "XCUIElementTypeApplication",
            "rect": ["x": 0, "y": 0, "width": 400, "height": 800], "children": children]]
        return String(decoding: try JSONSerialization.data(withJSONObject: tree), as: UTF8.self)
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
