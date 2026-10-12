import XCTest

/// Deterministic component AX checks run only against the dedicated DEBUG fixture app.
/// They do not establish production timeline, provider, or durable device acceptance.
final class IOSIntelligentUIComponentAXAcceptanceTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["AMBER_TASK_UI_COMPONENT_FIXTURE"] == "1" else {
            throw XCTSkip("Run component AX checks with the dedicated DEBUG fixture build and explicit fixture opt-in.")
        }
    }

    func testDecisionSummaryDisplaysDeclaredLabelsAndOptionText() throws {
        let app = try fixture("summary")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "需要的能力")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "离线可用")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["capabilities"].exists)
        XCTAssertFalse(app.staticTexts["offline"].exists)
        attach(app, name: "component-ax-readable-summary")
    }

    func testEmbeddedContinueUsesHostSubmissionGateAndResetStaysAvailable() throws {
        let app = try fixture("continueGate")
        let labels = ["CONTINUE_ONLY", "SUBMIT_ONLY", "RESET_DRAFT", "RESET_NATIVE"]
        for canSubmit in [false, true] {
            if canSubmit { try tap(app.buttons["fixture-toggle-submit-gate"], in: app) }
            for label in labels {
                let element = button(label, in: app)
                XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing rendered button \(label)")
                let expectedDisabled = !canSubmit && ["CONTINUE_ONLY", "SUBMIT_ONLY"].contains(label)
                XCTAssertEqual(element.isEnabled, !expectedDisabled, label)
            }
        }
        try tap(button("CONTINUE_ONLY", in: app), in: app)
        XCTAssertEqual(app.staticTexts["fixture-submit-count"].label, "提交次数：1")
        try tap(button("SUBMIT_ONLY", in: app), in: app)
        XCTAssertEqual(app.staticTexts["fixture-submit-count"].label, "提交次数：2")
        try tap(app.buttons["fixture-toggle-submit-gate"], in: app)
        XCTAssertFalse(button("CONTINUE_ONLY", in: app).isEnabled)
        XCTAssertFalse(button("SUBMIT_ONLY", in: app).isEnabled)
        try tap(button("RESET_DRAFT", in: app), in: app)
        try tap(button("RESET_NATIVE", in: app), in: app)
        XCTAssertEqual(app.staticTexts["fixture-reset-count"].label, "重置次数：2")
        XCTAssertEqual(app.staticTexts["fixture-submit-count"].label, "提交次数：2", "Reset must not submit")
        attach(app, name: "component-ax-submit-owner-gate")
    }

    func testUntitledBoundInputsExposeFieldLabelAndExplicitDefaultAnswer() throws {
        let app = try fixture("untitledInputs")
        for kind in ["toggle", "textField", "slider", "stepper"] {
            try tap(app.buttons["fixture-input-\(kind)"], in: app)
            let label = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "用户补充约束", "必填")).firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 5), "Missing required field label for \(kind)")
            XCTAssertEqual(try value("fixture-input-value", in: app), "UNANSWERED")
            if kind == "toggle" {
                for answer in ["是", "否"] {
                    let option = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "：\(answer)")).firstMatch
                    XCTAssertTrue(option.exists, "Missing explicit \(answer) button")
                    XCTAssertTrue(option.isEnabled)
                }
                try tap(app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "：否")).firstMatch, in: app)
                try waitForValue("false", identifier: "fixture-input-value", in: app)
            } else if kind == "slider" || kind == "stepper" {
                let confirm = button("使用当前值", in: app)
                XCTAssertTrue(confirm.exists, "Missing explicit default confirmation for \(kind)")
                XCTAssertTrue(confirm.isEnabled)
                try tap(confirm, in: app)
                try waitForValue("0.0", identifier: "fixture-input-value", in: app)
            } else {
                let text = app.textFields.firstMatch
                XCTAssertTrue(text.exists)
                try tap(text, in: app)
                text.typeText("offline")
                try waitForValue("offline", identifier: "fixture-input-value", in: app)
            }
        }
        attach(app, name: "component-ax-unanswered-inputs")
    }

    func testStudyActionsPersistLocallyAndOnlyExplicitContinueSubmits() throws {
        let app = try fixture("study")
        XCTAssertEqual(try value("fixture-study-draft", in: app), "EMPTY")
        // Root container IDs must coexist with mode, choice, feedback and score IDs.
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "task-ui-card-ming-study").firstMatch.exists)
        XCTAssertTrue(app.buttons["task-ui-study-mode-quiz"].exists)
        try tap(button("抽考", in: app), in: app)
        try waitForDraft(containing: #""mode":"quiz""#, in: app)
        XCTAssertTrue(app.buttons["task-ui-study-choice-yongle"].exists)
        try tap(button("永乐", in: app), in: app)
        try waitForDraft(containing: #""hongwu":"yongle""#, in: app)
        XCTAssertEqual(app.staticTexts["fixture-study-submit-count"].label, "提交次数：0", "Local grading must not call the agent")
        attachSystemTree(app, name: "component-ax-study-wrong-answer")
        let feedback = app.staticTexts["task-ui-study-feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertTrue(feedback.label.contains("再记一下"))
        let chosen = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND value == %@", "task-ui-study-choice-yongle", "已选择，答案错误")).firstMatch
        XCTAssertTrue(chosen.exists, "Answered choice must preserve its selected/error AX value")
        XCTAssertFalse(app.buttons["task-ui-study-choice-yongle"].exists, "Answered choice must be a readable row, not a disabled button")
        try tap(button("下一题", in: app), in: app)
        try waitForDraft(containing: #""index":1"#, in: app)
        try tap(button("正统与天顺", in: app), in: app)
        try waitForDraft(containing: #""yingzong":"two-reigns""#, in: app)
        let raw = try value("fixture-study-draft", in: app)
        let session = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let answers = try XCTUnwrap(session["answers"] as? [String: String])
        XCTAssertEqual(answers, ["hongwu": "yongle", "yingzong": "two-reigns"])
        XCTAssertEqual(app.staticTexts["fixture-study-submit-count"].label, "提交次数：0")
        XCTAssertTrue(app.staticTexts["task-ui-study-score"].label.contains("答对 1 题"))
        try tap(button("针对错题继续练习", in: app), in: app)
        let count = app.staticTexts["fixture-study-submit-count"]
        let submitted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "提交次数：1"), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [submitted], timeout: 5), .completed)
        XCTAssertEqual(try value("fixture-study-source", in: app), "study-origin/study-message/ming-study")
        let frozen = try value("fixture-study-receipt", in: app)
        XCTAssertTrue(frozen.contains("已答 2/2 题，答对 1 题"))
        XCTAssertTrue(frozen.contains("错题项目：hongwu"))
        try tap(button("清空学习卡", in: app), in: app)
        try waitForValue("EMPTY", identifier: "fixture-study-draft", in: app)
        try tap(button("查看答案", in: app), in: app)
        try waitForDraft(containing: #""revealed":true"#, in: app)
        let reset = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try value("fixture-study-draft", in: app).utf8)) as? [String: Any])
        XCTAssertEqual(reset["mode"] as? String, "review")
        XCTAssertEqual(reset["index"] as? Int, 0)
        XCTAssertTrue(try XCTUnwrap(reset["answers"] as? [String: String]).isEmpty)
        XCTAssertEqual(app.staticTexts["fixture-study-submit-count"].label, "提交次数：1", "Reset and reveal must not submit")
        XCTAssertEqual(try value("fixture-study-receipt", in: app), frozen, "Reset cannot rewrite the explicit submission")
        attach(app, name: "component-ax-study-owner-and-frozen-receipt")
    }

    func testNativeNumericControlUpdatesBoundGraphicsAndExplicitSubmission() throws {
        let app = try fixture("numeric")
        XCTAssertEqual(try value("fixture-numeric-draft", in: app), "UNANSWERED", "Preview must not write a draft")
        let submit = button("根据进度安排下一步", in: app)
        XCTAssertFalse(submit.isEnabled, "Required numeric preview is not a confirmed input")
        let chart = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND value CONTAINS %@", "完成数量与总量", "已完成：1")).firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 5), "Chart must expose the actual preview value")
        XCTAssertTrue(app.progressIndicators.matching(NSPredicate(format: "value == %@", "1 / 4")).firstMatch.exists)
        let steps = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND value == %@", "章节进度", "1 / 4")).firstMatch
        XCTAssertTrue(steps.exists)
        attachSystemTree(app, name: "component-ax-numeric-before-increment")
        print("COMPONENT_AX_NUMERIC_STEPPERS \(app.steppers.debugDescription)")
        print("COMPONENT_AX_NUMERIC_BUTTONS \(app.buttons.allElementsBoundByIndex.map { "id=\($0.identifier) label=\($0.label) enabled=\($0.isEnabled)" }.joined(separator: "\n"))")
        let increment = app.steppers.firstMatch.buttons.matching(NSPredicate(format: "label ENDSWITH %@ OR label ENDSWITH %@", "增量", "Increment")).firstMatch
        try tap(increment, in: app)
        try waitForValue("2.0", identifier: "fixture-numeric-draft", in: app)
        let updatedChart = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND value CONTAINS %@", "完成数量与总量", "已完成：2")).firstMatch
        XCTAssertTrue(updatedChart.waitForExistence(timeout: 5), "Chart value must follow the native input owner")
        XCTAssertTrue(app.progressIndicators.matching(NSPredicate(format: "value == %@", "2 / 4")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND value == %@", "章节进度", "2 / 4")).firstMatch.waitForExistence(timeout: 5))
        let metric = app.descendants(matching: .any).matching(identifier: "task-ui-component-chapter-metric").firstMatch
        XCTAssertTrue(metric.staticTexts["2"].waitForExistence(timeout: 5), "Metric must display the changed input")
        XCTAssertEqual(app.staticTexts["fixture-numeric-submit-count"].label, "提交次数：0", "Native input must not call the agent")
        try tap(button("清空数字卡", in: app), in: app)
        try waitForValue("UNANSWERED", identifier: "fixture-numeric-draft", in: app)
        XCTAssertTrue(chart.waitForExistence(timeout: 5), "Reset must restore the preview instead of preserving stale graphic values")
        XCTAssertFalse(submit.isEnabled)
        try tap(button("使用当前值 1", in: app), in: app)
        try waitForValue("1.0", identifier: "fixture-numeric-draft", in: app)
        XCTAssertTrue(submit.isEnabled)
        try tap(submit, in: app)
        try waitForValue("1.0", identifier: "fixture-numeric-receipt", in: app)
        XCTAssertEqual(app.staticTexts["fixture-numeric-submit-count"].label, "提交次数：1")
        attach(app, name: "component-ax-native-numeric-graphics-and-submit")
    }

    private func fixture(_ kind: String) throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "app.amber.ios")
        app.launchArguments = ["-amber-intelligent-ui-component-fixture", kind]
        app.launch()
        let marker = app.staticTexts["intelligent-ui-acceptance-fixture"]
        guard marker.waitForExistence(timeout: 15), marker.label == "Intelligent UI AX fixture: \(kind)" else {
            XCTFail("Dedicated DEBUG component fixture is unavailable; normal app cannot satisfy this test")
            throw NSError(domain: "IntelligentUIFixture", code: 1)
        }
        attachSystemTree(app, name: "component-ax-\(kind)-initial")
        return app
    }

    private func attachSystemTree(_ app: XCUIApplication, name: String) {
        attach(app, name: name)
        let description = app.debugDescription
        let tree = XCTAttachment(string: description)
        tree.name = "\(name)-system-tree"
        tree.lifetime = .keepAlways
        add(tree)
        print("COMPONENT_AX_FIXTURE_TREE \(name)\n\(description)")
    }

    private func button(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing fixture element: \(element)")
        let scroll = app.scrollViews["intelligent-ui-fixture-scroll"]
        for _ in 0..<5 {
            if element.isHittable { break }
            scroll.swipeUp()
        }
        if !element.isHittable {
            for _ in 0..<5 {
                if element.isHittable { break }
                scroll.swipeDown()
            }
        }
        XCTAssertTrue(element.isEnabled && element.isHittable, "Fixture action must be enabled and visible")
        element.tap()
    }

    private func value(_ identifier: String, in app: XCUIApplication) throws -> String {
        try XCTUnwrap(app.staticTexts[identifier].value as? String, "Missing owner state AX value: \(identifier)")
    }

    private func waitForValue(_ expected: String, identifier: String, in app: XCUIApplication) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: app.staticTexts[identifier])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    private func waitForDraft(containing fragment: String, in app: XCUIApplication) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", fragment), object: app.staticTexts["fixture-study-draft"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
