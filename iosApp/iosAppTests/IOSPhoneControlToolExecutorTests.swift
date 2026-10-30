import AmberPhoneControl
import Foundation
import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSPhoneControlToolExecutorTests: XCTestCase {
    func testPresentationAndSystemToolsHaveReachableRequests() throws {
        XCTAssertNoThrow(try IOSPhoneControlToolExecutor.request(name: "phone_return_to_amber", arguments: "{}"))
        XCTAssertNoThrow(try IOSPhoneControlToolExecutor.request(name: "phone_clipboard", arguments: "{}"))
        XCTAssertNoThrow(try IOSPhoneControlToolExecutor.request(name: "phone_system", arguments: #"{"action":"observe"}"#))
        XCTAssertNoThrow(try IOSPhoneControlToolExecutor.request(name: "phone_system", arguments: #"{"action":"home","include_screenshot":true}"#))
    }

    func testSystemClipboardAndStopArgumentsMatchTheirCapabilities() throws {
        for action in ["observe", "home", "volume_up", "volume_down", "dismiss_keyboard", "lock", "unlock", "lock_state"] {
            XCTAssertEqual(try IOSPhoneControlToolExecutor.request(name: "phone_system", arguments: "{\"action\":\"\(action)\"}"),
                .system(action: action, includeScreenshot: false))
        }
        XCTAssertEqual(try IOSPhoneControlToolExecutor.request(name: "phone_stop", arguments: "{}"), .stop(returnToAmber: true))
        XCTAssertEqual(try IOSPhoneControlToolExecutor.request(name: "phone_stop", arguments: #"{"return_to_amber":false}"#), .stop(returnToAmber: false))
        XCTAssertEqual(try IOSPhoneControlToolExecutor.request(name: "phone_clipboard", arguments: #"{"action":"write","text":""}"#), .writeClipboard(text: ""))
        for (name, arguments) in [
            ("phone_system", #"{"action":"guess"}"#),
            ("phone_system", #"{"action":"home","include_screenshot":1}"#),
            ("phone_return_to_amber", #"{"bundle_id":"other.app"}"#),
            ("phone_stop", #"{"return_to_amber":1}"#),
            ("phone_clipboard", #"{"max_chars":0}"#),
            ("phone_clipboard", #"{"max_chars":100001}"#),
            ("phone_clipboard", #"{"action":"read","text":"overwrite"}"#),
            ("phone_clipboard", #"{"action":"write","text":"x","max_chars":3}"#),
            ("phone_clipboard", #"{"action":"write"}"#),
        ] {
            XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: name, arguments: arguments), name)
        }
    }

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
        XCTAssertEqual(IOSPhoneControlToolExecutor.completionActivity(request: .stop(returnToAmber: true), outcome: .filled("stopped")), .stopped)
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
            #"{"include_screen_text":1}"#,
            #"{"include_screen_text":true,"recognition_languages":["en"]}"#,
        ] {
            XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_observe", arguments: invalid))
        }
    }

    func testScreenTextIsAnExplicitIndependentObservationOption() throws {
        XCTAssertEqual(
            try IOSPhoneControlToolExecutor.request(name: "phone_observe", arguments: #"{"include_screen_text":true}"#),
            .observe(maxNodes: 500, includeScreenshot: false, includeScreenText: true)
        )
        XCTAssertEqual(
            try IOSPhoneControlToolExecutor.request(name: "phone_observe", arguments: #"{"include_screen_text":true,"include_screenshot":true}"#),
            .observe(maxNodes: 500, includeScreenshot: true, includeScreenText: true)
        )
        XCTAssertEqual(
            try IOSPhoneControlToolExecutor.request(name: "phone_observe", arguments: #"{"include_screen_text":false}"#),
            .observe(maxNodes: 500, includeScreenshot: false, includeScreenText: false)
        )
    }

    func testLongPressDefaultsAndDurationBoundsPreserveFreshTargetContracts() throws {
        XCTAssertEqual(
            try IOSPhoneControlToolExecutor.request(name: "phone_act", arguments: #"{"action":"long_press","ref":"frame:1"}"#),
            .act(.longPress(ref: "frame:1", durationMs: 750))
        )
        XCTAssertEqual(
            try IOSPhoneControlToolExecutor.request(name: "phone_act", arguments: #"{"action":"long_press_point","observation_id":"frame","x":0.5,"y":0.25}"#),
            .act(.longPressPoint(observationID: "frame", x: 0.5, y: 0.25, durationMs: 750))
        )
        for duration in [300, 3000] {
            XCTAssertEqual(
                try IOSPhoneControlToolExecutor.request(name: "phone_act", arguments: #"{"action":"long_press","ref":"frame:1","duration_ms":\#(duration)}"#),
                .act(.longPress(ref: "frame:1", durationMs: duration))
            )
            XCTAssertEqual(
                try IOSPhoneControlToolExecutor.request(name: "phone_act", arguments: #"{"action":"long_press_point","observation_id":"frame","x":0.5,"y":0.25,"duration_ms":\#(duration)}"#),
                .act(.longPressPoint(observationID: "frame", x: 0.5, y: 0.25, durationMs: duration))
            )
        }
        for invalid in [
            #"{"action":"long_press","ref":"frame:1","duration_ms":299}"#,
            #"{"action":"long_press","ref":"frame:1","duration_ms":3001}"#,
            #"{"action":"long_press","ref":"frame:1","duration_ms":750.5}"#,
            #"{"action":"long_press","ref":"frame:1","duration_ms":true}"#,
            #"{"action":"long_press","ref":""}"#,
            #"{"action":"long_press","ref":"frame:1","x":0.5,"y":0.25}"#,
            #"{"action":"long_press_point","x":0.5,"y":0.25}"#,
            #"{"action":"long_press_point","observation_id":"frame","x":1,"y":0.25}"#,
            #"{"action":"long_press_point","observation_id":"frame","x":0.5,"y":0.25,"duration_ms":299}"#,
            #"{"action":"long_press_point","observation_id":"frame","x":0.5,"y":0.25,"ref":"frame:1"}"#,
        ] {
            XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_act", arguments: invalid), invalid)
        }
        XCTAssertEqual(IOSPhoneControlToolExecutor.actionActivity(.longPress(ref: "frame:1", durationMs: 750)), .tapping)
        XCTAssertEqual(IOSPhoneControlToolExecutor.actionActivity(.longPressPoint(observationID: "frame", x: 0.5, y: 0.25, durationMs: 750)), .tapping)
    }

    func testAlertTapRequiresObservedReferenceAndCannotSelectByUnboundText() throws {
        XCTAssertEqual(
            try IOSPhoneControlToolExecutor.request(name: "phone_act", arguments: #"{"action":"tap_alert","ref":"frame:3"}"#),
            .act(.tapAlert(ref: "frame:3"))
        )
        for invalid in [
            #"{"action":"tap_alert"}"#,
            #"{"action":"tap_alert","ref":""}"#,
            #"{"action":"tap_alert","name":"Allow"}"#,
            #"{"action":"tap_alert","ref":"frame:3","text":"Allow"}"#,
            #"{"action":"tap_alert","ref":"frame:3","duration_ms":750}"#,
        ] {
            XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_act", arguments: invalid), invalid)
        }
        XCTAssertEqual(IOSPhoneControlToolExecutor.actionActivity(.tapAlert(ref: "frame:3")), .tapping)
    }

    func testListCollectionHasBoundedDefaultsAndAllowsCurrentScreenOnly() throws {
        let target = IOSPhoneGoalTarget(identifier: "list")
        XCTAssertEqual(
            try IOSPhoneControlToolExecutor.request(name: "phone_collect_list", arguments: #"{"container":{"identifier":"list"},"direction":"up"}"#),
            .collectList(.init(container: target, direction: .up, maxSwipes: 3, maxItems: 50))
        )
        XCTAssertEqual(
            try IOSPhoneControlToolExecutor.request(name: "phone_collect_list", arguments: #"{"container":{"identifier":"list"},"direction":"down","max_swipes":0,"max_items":1}"#),
            .collectList(.init(container: target, direction: .down, maxSwipes: 0, maxItems: 1))
        )
        XCTAssertEqual(
            try IOSPhoneControlToolExecutor.request(name: "phone_collect_list", arguments: #"{"container":{"identifier":"list"},"direction":"up","max_swipes":8,"max_items":200}"#),
            .collectList(.init(container: target, direction: .up, maxSwipes: 8, maxItems: 200))
        )
        for invalid in [
            #"{"container":{"identifier":"list"},"direction":"left"}"#,
            #"{"container":{"identifier":"list"},"direction":"up","max_swipes":-1}"#,
            #"{"container":{"identifier":"list"},"direction":"up","max_swipes":9}"#,
            #"{"container":{"identifier":"list"},"direction":"up","max_items":0}"#,
            #"{"container":{"identifier":"list"},"direction":"up","max_items":201}"#,
            #"{"container":{"identifier":"list"},"direction":"up","max_swipes":1.5}"#,
            #"{"container":{"identifier":"list"},"direction":"up","max_items":true}"#,
            #"{"container":{},"direction":"up"}"#,
            #"{"container":{"identifier":"list","ref":"old:1"},"direction":"up"}"#,
            #"{"container":{"identifier":"list"},"direction":"up","collect_all":true}"#,
        ] {
            XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_collect_list", arguments: invalid), invalid)
        }
    }

    func testOrderedFlowAllowsRepeatedSemanticStepsWithinItsBound() throws {
        let operation: [String: Any] = ["action": "tap", "target": ["identifier": "item"]]
        let expectation: [String: Any] = ["kind": "visible", "target": ["identifier": "item"]]
        let step = ["operation": operation, "expectation": expectation]
        for count in [1, 2, 12] {
            let input: [String: Any] = [
                "goal": "Advance the same control in order", "bundle_id": "app.test",
                "steps": Array(repeating: step, count: count),
                "completion": ["kind": "visible", "target": ["identifier": "done"]],
            ]
            let arguments = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
            guard case .runFlow(let request) = try IOSPhoneControlToolExecutor.request(name: "phone_run_flow", arguments: arguments) else {
                return XCTFail("Ordered flows must parse into the dedicated flow request")
            }
            XCTAssertEqual(request.steps.count, count, "Repeated operations retain their explicit order")
            XCTAssertTrue(request.steps.allSatisfy { $0.operation.target.identifier == "item" })
        }
    }

    func testEnabledExpectationParsesForActionGoalAndFlowAndRejectsValueOrAnchor() throws {
        let enabled = IOSPhoneGoalExpectation(kind: .enabled, target: .init(identifier: "check"))
        let inputs = [
            ("phone_act", #"{"action":"tap","ref":"fresh:1","expectation":{"kind":"enabled","target":{"identifier":"check"}}}"#),
            ("phone_run_goal", #"{"goal":"选择当前答案","bundle_id":"app.test","actions":[{"action":"tap","target":{"identifier":"answer"}}],"completion":{"kind":"enabled","target":{"identifier":"check"}}}"#),
            ("phone_run_flow", #"{"goal":"选择当前答案","bundle_id":"app.test","steps":[{"operation":{"action":"tap","target":{"identifier":"answer"}},"expectation":{"kind":"enabled","target":{"identifier":"check"}}}],"completion":{"kind":"enabled","target":{"identifier":"check"}}}"#),
        ]
        for (name, arguments) in inputs {
            switch (name, try IOSPhoneControlToolExecutor.request(name: name, arguments: arguments)) {
            case ("phone_act", .verifiedAct(_, let expectation)):
                XCTAssertEqual(expectation, enabled)
            case ("phone_run_goal", .runGoal(let request)):
                XCTAssertEqual(request.completion, enabled)
            case ("phone_run_flow", .runFlow(let request)):
                XCTAssertEqual(request.steps.first?.expectation, enabled)
                XCTAssertEqual(request.completion, enabled)
            default:
                XCTFail("The enabled condition must reach the typed request: \(name)")
            }
            for extra in [#","value":"""#, #","anchor":{"identifier":"question"}"#,
                          #","value":null"#, #","anchor":null"#] {
                let invalid = arguments.replacingOccurrences(of: #""kind":"enabled""#,
                                                              with: #""kind":"enabled""# + extra)
                XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: name, arguments: invalid), invalid)
            }
        }
    }

    func testOrderedFlowRejectsUnknownNestedArgumentsAndUnsupportedOperations() throws {
        let operation: [String: Any] = ["action": "tap", "target": ["identifier": "item"]]
        let expectation: [String: Any] = ["kind": "visible", "target": ["identifier": "item"]]
        let step = ["operation": operation, "expectation": expectation]
        let baseline: [String: Any] = [
            "goal": "Advance the control", "bundle_id": "app.test", "steps": [step],
            "completion": ["kind": "visible", "target": ["identifier": "done"]],
        ]
        var invalidInputs: [[String: Any]] = []
        var input = baseline
        input["max_steps"] = 2
        invalidInputs.append(input)
        input = baseline
        input["steps"] = []
        invalidInputs.append(input)
        input["steps"] = Array(repeating: step, count: 13)
        invalidInputs.append(input)
        for action in ["launch", "clear", "long_press", "tap_point"] {
            input = baseline
            input["steps"] = [["operation": ["action": action, "target": ["identifier": "item"]],
                                "expectation": expectation]]
            invalidInputs.append(input)
        }
        for (field, value) in [("ref", "old:1"), ("observation_id", "old-frame")] {
            var unboundOperation = operation
            unboundOperation[field] = value
            input = baseline
            input["steps"] = [["operation": unboundOperation, "expectation": expectation]]
            invalidInputs.append(input)
        }
        input = baseline
        input["steps"] = [["operation": ["action": "tap", "target": ["identifier": "item", "ref": "old:1"]],
                            "expectation": expectation]]
        invalidInputs.append(input)
        input["steps"] = [["operation": operation, "expectation": expectation, "retry": true]]
        invalidInputs.append(input)
        input["steps"] = [["operation": operation,
                            "expectation": ["kind": "visible", "target": ["identifier": "item"], "observation_id": "old-frame"]]]
        invalidInputs.append(input)
        input = baseline
        input["completion"] = ["kind": "visible", "target": ["identifier": "done", "x": 0.5]]
        invalidInputs.append(input)
        input = baseline
        input["steps"] = [["operation": operation]]
        invalidInputs.append(input)
        for invalid in invalidInputs {
            let arguments = String(decoding: try JSONSerialization.data(withJSONObject: invalid), as: UTF8.self)
            XCTAssertThrowsError(try IOSPhoneControlToolExecutor.request(name: "phone_run_flow", arguments: arguments), arguments)
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

    func testReturnPreferenceDefaultsOnAndPreservesExplicitOptOut() throws {
        let suite = "PhoneReturnPreference-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(IOSPhoneControlReturnPreference.enabled(defaults))
        IOSPhoneControlReturnPreference.set(false, defaults)
        XCTAssertFalse(IOSPhoneControlReturnPreference.enabled(defaults))
        IOSPhoneControlReturnPreference.set(true, defaults)
        XCTAssertTrue(IOSPhoneControlReturnPreference.enabled(defaults))
    }

    func testClipboardReadsOnlyInForegroundAndReturnsBoundedTextWithoutStartingRunner() async throws {
        let (controller, defaults, suite) = try await makeClaimedController(runID: "clipboard")
        defer { defaults.removePersistentDomain(forName: suite) }
        let clipboard = ClipboardFixture()
        let executor = IOSPhoneControlToolExecutor(runID: "clipboard", controller: controller,
            clipboard: .init(isForeground: { clipboard.foreground }, read: { clipboard.reads += 1; return clipboard.text }, write: { clipboard.writes.append($0) }), reportActivity: { _ in })
        let blocked = await executor.execute(name: "phone_clipboard", arguments: "{}", isUserInitiated: true)
        guard case .failed(let blockedText) = blocked else { return XCTFail("Background clipboard access must fail visibly") }
        XCTAssertEqual(try decodedObject(blockedText)["code"] as? String, "clipboard_requires_foreground")
        XCTAssertEqual(clipboard.reads, 0)
        _ = await executor.execute(name: "phone_clipboard", arguments: #"{"action":"write","text":"new"}"#, isUserInitiated: true)
        XCTAssertTrue(clipboard.writes.isEmpty)
        clipboard.foreground = true
        let result = await executor.execute(name: "phone_clipboard", arguments: #"{"max_chars":3}"#, isUserInitiated: true)
        guard case .filled(let text) = result else { return XCTFail("Foreground text should be readable") }
        let fields = try decodedObject(text)
        XCTAssertEqual(fields["text"] as? String, "你🙂好")
        XCTAssertEqual(fields["returned_chars"] as? Int, 3)
        XCTAssertEqual(fields["total_chars"] as? Int, 6)
        XCTAssertEqual(fields["truncated"] as? Bool, true)
        XCTAssertEqual(clipboard.reads, 1)
        XCTAssertFalse(controller.hasRequestedSession(runID: "clipboard"))
        clipboard.text = nil
        let unavailable = await executor.execute(name: "phone_clipboard", arguments: "{}", isUserInitiated: true)
        guard case .failed(let unavailableText) = unavailable else { return XCTFail("Missing data is not proof of an empty clipboard") }
        XCTAssertEqual(try decodedObject(unavailableText)["status"] as? String, "unavailable")
        let written = await executor.execute(name: "phone_clipboard", arguments: #"{"action":"write","text":"new"}"#, isUserInitiated: true)
        guard case .filled(let writeText) = written else { return XCTFail("Foreground write should replace text") }
        XCTAssertEqual(try decodedObject(writeText)["written_chars"] as? Int, 3)
        XCTAssertEqual(clipboard.writes, ["new"])
        await controller.stop(runID: "clipboard")
        _ = await executor.execute(name: "phone_clipboard", arguments: "{}", isUserInitiated: true)
        XCTAssertEqual(clipboard.reads, 2, "A revoked owner must not read again")
    }

    @MainActor
    private final class ClipboardFixture {
        var foreground = false
        var reads = 0
        var writes: [String] = []
        var text: String? = "你🙂好abc"
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
    func installedApplications(pairing: Data, connectionMode: IOSPhoneControlConnectionMode) -> [PhoneControlInstalledApp] { applications }
}
