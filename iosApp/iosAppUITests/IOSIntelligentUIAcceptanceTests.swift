import XCTest

/// Runs against the installed production app and its current provider/model settings.
/// These provider acceptance methods use the ordinary app, without a fixture launch mode.
final class IOSIntelligentUIAcceptanceTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testInstalledAppChatNavigationWithoutProviderRequest() throws {
        guard ProcessInfo.processInfo.environment["AMBER_TASK_UI_UI_BOOTSTRAP"] == "1" else {
            throw XCTSkip("Enable the UI bootstrap only on the task-owned acceptance Simulator.")
        }
        let app = XCUIApplication(bundleIdentifier: "app.amber.ios")
        app.launch()
        let newChat = app.buttons.matching(NSPredicate(format: "label IN %@", ["新建聊天", "New chat"])).firstMatch
        if !newChat.waitForExistence(timeout: 20) {
            let back = app.buttons["topbar-back"]
            try require(back.waitForExistence(timeout: 10) && back.isHittable, "生产聊天返回入口不可用。")
            back.tap()
        }
        try require(newChat.waitForExistence(timeout: 20) && newChat.isHittable, "生产首页新建聊天入口不可用。")
        newChat.tap()
        let send = app.buttons.matching(NSPredicate(format: "label IN %@", ["发送消息", "Send message"])).firstMatch
        try require(send.waitForExistence(timeout: 20), "实际 composer 没有可识别的发送控件。")
        attach(app, name: "adaptive-ui-native-app-navigation")
    }

    func testConfiguredAppNativeTaskCardContinuesWithSelectedOfflineConstraint() throws {
        guard ProcessInfo.processInfo.environment["AMBER_TASK_UI_LIVE_PROVIDER"] == "1" else {
            throw XCTSkip("Set AMBER_TASK_UI_LIVE_PROVIDER=1 to run the configured app's two-turn provider acceptance.")
        }
        let app = XCUIApplication(bundleIdentifier: "app.amber.ios")
        app.launch()
        let newChat = app.buttons.matching(NSPredicate(format: "label IN %@", ["新建聊天", "New chat"])).firstMatch
        if !newChat.waitForExistence(timeout: 30) {
            let back = app.buttons["topbar-back"]
            try require(back.waitForExistence(timeout: 20) && back.isHittable,
                        "当前应用没有可识别的首页新建入口或聊天返回入口；没有猜测坐标或切换设置。")
            back.tap()
        }
        try require(newChat.waitForExistence(timeout: 20) && newChat.isHittable && newChat.isEnabled,
                    "无法通过实际首页的“新建聊天”创建验收会话。")
        newChat.tap()

        let send = app.buttons.matching(NSPredicate(format: "label IN %@", ["发送消息", "Send message"])).firstMatch
        try require(send.waitForExistence(timeout: 20), "新会话没有出现生产发送按钮。")
        // ComposerInputTextView currently has no identifier. A fresh conversation must
        // expose exactly one editable UITextView; ambiguity fails instead of picking one.
        let inputs = app.textViews.allElementsBoundByIndex.filter { $0.isHittable && $0.isEnabled }
        try require(inputs.count == 1, "新会话暴露 \(inputs.count) 个可编辑 textView，无法唯一识别生产 composer。")
        let composer = inputs[0]
        try require((composer.value as? String ?? "").isEmpty, "新会话输入框已有草稿；未覆盖该内容。")
        defer { attach(app, name: "task-ui-acceptance-end") }
        attach(app, name: "task-ui-acceptance-new-conversation")

        let marker = "TASK_UI_ACCEPTED_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let prompt = """
        这是智能 UI 原生交互验收会话。为个人笔记选择存储方案。请直接输出一个符合 task-ui v1 的完整 decision 任务卡：card_id 为 notes-storage，目标是确定笔记存储方案，问题是选本地存储还是云存储。options 恰好两个：第一个 id=local、title=本地存储，第二个 id=cloud、title=云存储；给出各自真实的 summary 和 tradeoffs，不替用户自动选择。fields 恰好一个 text 字段：id=constraints、label=补充约束、required=true。submit.label=基于选择继续、submit.intent=continue。不要添加 components。输出一个独立的 task-ui fenced JSON 块；无需工具或外部资料。首次回复只输出任务卡，不输出结果标记。等我通过任务卡提交选择后，下一轮只用一行纯文字复述所选方案完整名称及我的补充约束，不添加 Markdown 格式；该句话必须以 \(marker)：开头，不使用工具、不执行操作、不生成新卡片。
        """
        composer.tap()
        composer.typeText(prompt.replacingOccurrences(of: "\n", with: " "))
        try require(send.isEnabled && send.isHittable, "当前配置无法发送验收请求；没有修改模型、认证或其他设置。")
        send.tap()

        let local = app.buttons["task-ui-option-local"]
        try require(local.waitForExistence(timeout: 180), "真实模型没有在 180 秒内生成 notes-storage 本地存储任务卡。")
        try waitUntil(timeout: 180, reason: "来源回复未成功终结，原生方案选择一直未启用。") { local.isEnabled }
        try reveal(local, in: app, upward: false)
        attach(app, name: "task-ui-acceptance-provider-card")
        local.tap()

        let fieldQuery = app.descendants(matching: .any).matching(identifier: "task-ui-field-constraints")
        let constraint = fieldQuery.firstMatch
        try require(constraint.waitForExistence(timeout: 10), "真实任务卡未提供声明的 constraints 输入字段。")
        try reveal(constraint, in: app, upward: true)
        try require(constraint.elementType == .textView || constraint.elementType == .textField,
                    "constraints 的实际 AX 类型不可编辑：\(constraint.elementType)。")
        constraint.tap()
        constraint.typeText("必须离线可用")
        try require((constraint.value as? String)?.contains("必须离线可用") == true,
                    "原生字段没有保留用户实际输入的离线约束。")

        let submit = app.buttons["task-ui-submit-notes-storage"]
        try require(submit.waitForExistence(timeout: 10), "真实任务卡缺少宿主提交按钮。")
        try waitUntil(timeout: 10, reason: "已选择本地存储并填写必填字段，但提交未启用。") { submit.isEnabled }
        try reveal(submit, in: app, upward: true)
        // The initial user prompt contains the marker inside a paragraph. The visible
        // submission starts with “【任务卡选择】”; neither can satisfy this answer query.
        let answer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@ AND label CONTAINS %@", marker + "：", "本地存储", "离线")).firstMatch
        try require(!answer.exists, "结果标记在提交前已出现，无法将后续文本归属于第二轮助手。")
        attach(app, name: "task-ui-acceptance-local-and-offline-selected")
        submit.tap()
        try require(answer.waitForExistence(timeout: 180), "第二轮助手未产生带唯一标记、本地存储与离线约束的回复。用户消息复述不作为通过证据。")
        try require(send.waitForExistence(timeout: 180), "第二轮 UI 尚未回到空闲状态；成功终态另由持久化验收脚本确认。")
        let response = answer.label
        XCTAssertTrue(response.hasPrefix(marker + "："))
        XCTAssertTrue(response.contains("本地存储"))
        XCTAssertTrue(response.contains("离线"))
        let text = XCTAttachment(string: response)
        text.name = "task-ui-acceptance-second-assistant-response"
        text.lifetime = .keepAlways
        add(text)
        attach(app, name: "task-ui-acceptance-second-assistant-response")
    }

    func testNaturalMemoryTaskIsInteractiveInsideTheConversation() throws {
        guard ProcessInfo.processInfo.environment["AMBER_TASK_UI_LIVE_PROVIDER"] == "1" else {
            throw XCTSkip("Set AMBER_TASK_UI_LIVE_PROVIDER=1 for actual configured app acceptance.")
        }
        let app = XCUIApplication(bundleIdentifier: "app.amber.ios")
        app.launch()
        let newChat = app.buttons.matching(NSPredicate(format: "label IN %@", ["新建聊天", "New chat"])).firstMatch
        if !newChat.waitForExistence(timeout: 20) {
            let back = app.buttons["topbar-back"]
            try require(back.waitForExistence(timeout: 10) && back.isHittable, "无法识别生产聊天返回入口。")
            back.tap()
        }
        try require(newChat.waitForExistence(timeout: 20) && newChat.isHittable, "无法从首页新建实际验收会话。")
        newChat.tap()
        let send = app.buttons.matching(NSPredicate(format: "label IN %@", ["发送消息", "Send message"])).firstMatch
        try require(send.waitForExistence(timeout: 20), "实际发送入口未出现。")
        let inputs = app.textViews.allElementsBoundByIndex.filter { $0.isHittable && $0.isEnabled }
        try require(inputs.count == 1, "不能唯一识别新会话的 composer。")
        let composer = inputs[0]
        try require((composer.value as? String ?? "").isEmpty, "输入框已有草稿，未覆盖。")
        let marker = "STUDY_UI_ACCEPTED_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        defer { attach(app, name: "study-ui-acceptance-end") }
        composer.tap()
        composer.typeText("用智能 UI 帮我记忆明朝十六帝，最好能直接翻卡和做选择题。先给我学习内容；之后我提交练习结果时，用一行文字按‘已答 N 题’确认实际题数，N用阿拉伯数字，回复以 \(marker)：开头。")
        try require(send.isEnabled && send.isHittable, "当前配置无法发送；不修改模型和认证。")
        send.tap()
        let study = app.descendants(matching: .any)["task-ui-study"]
        try require(study.waitForExistence(timeout: 180), "自然记忆请求没有生成原生消息内学习卡。")
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-ui-card-")).firstMatch
        try require(card.exists, "学习 UI 缺少实际来源卡片。")
        let cardIdentifier = card.identifier
        let quiz = app.buttons["task-ui-study-mode-quiz"]
        try require(quiz.waitForExistence(timeout: 20), "模型未提供可直接作答的学习题。")
        try waitUntil(timeout: 180, reason: "来源生成没有成功终结。") { quiz.isEnabled }
        try reveal(quiz, in: app, upward: true, cardIdentifier: cardIdentifier)
        attach(app, name: "study-ui-inline-review")
        quiz.tap()
        let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-ui-study-choice-"))
        let choice = choices.firstMatch
        try require(choice.waitForExistence(timeout: 10), "抽考没有原生答案按钮。")
        try reveal(choice, in: app, upward: true, cardIdentifier: cardIdentifier)
        choice.tap()
        let score = app.staticTexts["task-ui-study-score"]
        try require(score.waitForExistence(timeout: 10) && score.label.contains("已答 1"), "实际作答没有更新本地进度。")
        attach(app, name: "study-ui-inline-local-answer")
        let submit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-ui-submit-")).firstMatch
        try require(submit.exists && submit.isEnabled, "本地练习没有可用的显式继续入口。")
        try reveal(submit, in: app, upward: true, cardIdentifier: cardIdentifier)
        let answer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", marker + "：")).firstMatch
        try require(!answer.exists, "提交前已出现结果标记，不能验证下一轮来源。")
        submit.tap()
        try require(answer.waitForExistence(timeout: 180), "实际学习进度提交后没有收到第二轮确认。")
        try require(send.waitForExistence(timeout: 180), "第二轮回复尚未回到空闲状态；成功终态由持久化验收另行核对。")
        XCTAssertNotNil(answer.label.range(of: #"已答\s*1\s*题"#, options: .regularExpression))
        let attachment = XCTAttachment(string: answer.label)
        attachment.name = "study-ui-actual-second-response"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, upward: Bool,
                        cardIdentifier: String = "task-ui-card-notes-storage") throws {
        if element.isHittable { return }
        let timeline = app.scrollViews.containing(.any, identifier: cardIdentifier).firstMatch
        try require(timeline.exists, "任务卡当前不可点击，且未找到其实际聊天滚动容器；没有猜测坐标。")
        for _ in 0..<5 {
            if element.isHittable { return }
            if upward { timeline.swipeUp() } else { timeline.swipeDown() }
        }
        try require(element.isHittable, "原生滚动后目标控件仍不可点击：\(element.identifier)。")
    }

    private func waitUntil(timeout: TimeInterval, reason: String, _ condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        try require(XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed, reason)
    }

    private func require(_ condition: Bool, _ reason: String) throws {
        guard condition else {
            XCTFail(reason)
            throw NSError(domain: "IOSIntelligentUIAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
