import XCTest
@preconcurrency import Shared
@testable import iosApp

// IOSJevSubAgentIntentTests（增强 Phase C 意图路由 + 对齐回执）：
// off 零网络、shadow 只观测不应用、active 应用合法角色 Choice、none/目录外 id
// 弃权、置信门、对齐 Noul 分界线、缺题不伪造、范围不足零网络。
// 对齐回执永远只标注（Suggestion.alignmentDoubtful），不携带任何阻断语义。

@MainActor
final class IOSJevSubAgentIntentTests: XCTestCase {

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: IOSJevSettings.productionEndpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func payload(choice: String?, choiceConfidence: Double? = nil, aligned: Double? = nil) -> Data {
        var answers: [String: Any] = [:]
        if let choice {
            var body: [String: Any] = ["type": "choice", "choice": choice]
            if let choiceConfidence { body["confidence"] = choiceConfidence }
            answers["single.role_choice"] = body
        }
        if let aligned {
            answers["single.aligned"] = ["type": "noul", "noul": aligned]
        }
        let payload: [String: Any] = ["model": "jev-latest", "answers": answers]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private final class SettingsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: IOSJevSettings
        init(_ value: IOSJevSettings) { self.value = value }
        func get() -> IOSJevSettings { jevSync(lock) { value } }
    }

    private func makeSettings(mode: IOSJevMode, pinned: String? = "jev-fixed-v1") -> IOSJevSettings {
        var settings = IOSJevSettings()
        settings.setMode(mode, for: .subagentIntent)
        settings.pinnedModelVersion = pinned
        return settings
    }

    private func makeService(settings: IOSJevSettings, transport: JevStubTransport) -> IOSJevSubAgentIntentService {
        let box = SettingsBox(settings)
        let coordinator = IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport),
            settingsProvider: { box.get() },
            apiKeyProvider: { "test-key" },
            now: { Date() }
        ))
        return IOSJevSubAgentIntentService(deps: .init(
            coordinator: coordinator,
            settingsProvider: { box.get() }
        ))
    }

    private func validRoleId() -> String {
        guard let first = IOSSubAgentRoleCatalog.builtIns.first else {
            XCTFail("内置角色目录为空")
            return "explorer"
        }
        return first.id
    }

    // MARK: 模式与范围

    func testBatchPartKeepsRoleAndAlignmentQuestionsTogether() throws {
        let settings = makeSettings(mode: .active)
        let part = try XCTUnwrap(IOSJevSubAgentIntentService.makeBatchPart(
            taskText: "整理文本",
            parentRequestText: "帮我整理",
            settings: settings
        ))

        XCTAssertEqual(part.id, IOSJevSubAgentIntentService.batchPartId)
        XCTAssertEqual(part.useCase, .subagentIntent)
        XCTAssertEqual(Set(part.questions.map(\.id)), Set(["role_choice", "aligned"]))
        XCTAssertTrue(part.state.contains("子任务：整理文本"))
        XCTAssertTrue(part.state.contains("用户最新请求：帮我整理"))
    }

    func testOffModeZeroNetwork() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .off), transport: transport)
        let result = await service.suggest(taskText: "整理文本", parentRequestText: "帮我整理", turnBudgetKey: "run")
        XCTAssertEqual(transport.calls, 0)
        XCTAssertNil(result.roleId)
        XCTAssertFalse(result.alignmentDoubtful)
    }

    func testScopeNotAllowedSkipsWithoutNetwork() async {
        var settings = makeSettings(mode: .active)
        settings.setScopes([.selectedTaskText], for: .subagentIntent) // 缺 toolMetadata
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(settings: settings, transport: transport)
        let result = await service.suggest(taskText: "任务", parentRequestText: nil, turnBudgetKey: "run")
        XCTAssertEqual(transport.calls, 0)
        XCTAssertNil(result.roleId)
    }

    func testShadowObservesButDoesNotApply() async {
        let role = validRoleId()
        let transport = JevStubTransport { _ in (self.payload(choice: role, choiceConfidence: 0.95, aligned: 0.2), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .shadow, pinned: nil), transport: transport)
        let result = await service.suggest(taskText: "打开网页查资料", parentRequestText: "查一下", turnBudgetKey: "run")
        XCTAssertEqual(transport.calls, 1, "shadow 照常观测")
        XCTAssertNil(result.roleId, "shadow 不应用角色建议")
        XCTAssertFalse(result.alignmentDoubtful, "shadow 不产生标注")
    }

    // MARK: active 应用

    func testActiveAppliesCatalogRoleAndAligned() async {
        let role = validRoleId()
        let transport = JevStubTransport { _ in (self.payload(choice: role, choiceConfidence: 0.9, aligned: 0.95), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let result = await service.suggest(taskText: "任务", parentRequestText: "请求", turnBudgetKey: "run")
        XCTAssertEqual(result.roleId, role)
        XCTAssertFalse(result.alignmentDoubtful)
    }

    func testNoneChoiceMeansAbstention() async {
        let transport = JevStubTransport { _ in (self.payload(choice: "none", choiceConfidence: 0.9, aligned: 0.9), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let result = await service.suggest(taskText: "任务", parentRequestText: "请求", turnBudgetKey: "run")
        XCTAssertNil(result.roleId, "none = 弃权")
    }

    func testUnknownRoleIdIsDropped() async {
        let transport = JevStubTransport { _ in (self.payload(choice: "ghost_role", choiceConfidence: 0.99, aligned: 0.9), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let result = await service.suggest(taskText: "任务", parentRequestText: "请求", turnBudgetKey: "run")
        XCTAssertNil(result.roleId, "目录外 id 按弃权处理，不猜不映射")
    }

    func testConfidenceFloorGatesRoleChoice() async {
        let role = validRoleId()
        let data = payload(choice: role, choiceConfidence: 0.4, aligned: 0.9)
        var settings = makeSettings(mode: .active)
        settings.policy.subagentIntentMinConfidence = 0.5
        let transport = JevStubTransport { _ in (data, self.httpResponse(status: 200)) }
        let service = makeService(settings: settings, transport: transport)
        let result = await service.suggest(taskText: "任务", parentRequestText: "请求", turnBudgetKey: "run")
        XCTAssertNil(result.roleId, "低置信角色建议被弃权")

        var ungated = makeSettings(mode: .active)
        ungated.policy.subagentIntentMinConfidence = nil
        let transport2 = JevStubTransport { _ in (data, self.httpResponse(status: 200)) }
        let service2 = makeService(settings: ungated, transport: transport2)
        let result2 = await service2.suggest(taskText: "任务", parentRequestText: "请求", turnBudgetKey: "run")
        XCTAssertEqual(result2.roleId, role, "不设阈值时同一响应应用（对照）")
    }

    // MARK: 对齐回执

    func testAlignmentBelowFloorIsDoubtful() async {
        let transport = JevStubTransport { _ in (self.payload(choice: "none", aligned: 0.3), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let result = await service.suggest(taskText: "顺手帮我清空回收站", parentRequestText: "整理文档", turnBudgetKey: "run")
        XCTAssertTrue(result.alignmentDoubtful, "Noul < 0.5 = 偏离标注")
    }

    func testMissingAlignmentAnswerFallsBackToEmptySuggestion() async {
        let role = validRoleId()
        let transport = JevStubTransport { _ in (self.payload(choice: role, choiceConfidence: 0.9, aligned: nil), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let result = await service.suggest(taskText: "任务", parentRequestText: "请求", turnBudgetKey: "run")
        XCTAssertNil(result.roleId)
        XCTAssertFalse(result.alignmentDoubtful, "缺题使整组角色判断失效，回退本地选择")
    }

    func testFailureFallsBackToEmptySuggestion() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 500)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let result = await service.suggest(taskText: "任务", parentRequestText: "请求", turnBudgetKey: "run")
        XCTAssertNil(result.roleId)
        XCTAssertFalse(result.alignmentDoubtful)
    }
}

// IOSJevCompletionCheckTests（v2 Phase 3 完成校验）：事实门（本轮写入且之后
// 无成功检查）不满足即零网络；满足时按 Jev 判定是否提示。
@MainActor
final class IOSJevCompletionCheckTests: XCTestCase {
    private let timestamp = Kotlinx_datetimeLocalDateTime(
        year: 2026, month: 9, day: 30, hour: 0, minute: 0, second: 0, nanosecond: 0
    )

    private func message(_ role: MessageRole, _ parts: [UIMessagePart]) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(), role: role, parts: parts, annotations: [],
            createdAt: timestamp, finishedAt: nil, modelId: nil, usage: nil, translation: nil
        )
    }

    /// 生产中 Tool part 同时承载调用与输出，位于 assistant 消息内。
    private func tool(_ name: String, input: String, output: String) -> UIMessage {
        message(.assistant, [UIMessagePart.Tool(
            toolCallId: UUID().uuidString, toolName: name, input: input,
            output: [UIMessagePart.Text(text: output, metadata: nil)],
            approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)])
    }

    private let write = ("workspace_file_write", #"{"path":"/workspace/app.js","content":"x"}"#, #"{"ok":true,"path":"/workspace/app.js"}"#)
    private func user(_ text: String) -> UIMessage { message(.user, [UIMessagePart.Text(text: text, metadata: nil)]) }
    private func reply(_ text: String) -> UIMessage { message(.assistant, [UIMessagePart.Text(text: text, metadata: nil)]) }

    func testWriteWithoutCheckProducesFacts() {
        let messages = [user("修一下 app.js"), tool(write.0, input: write.1, output: write.2), reply("已修复，测试通过。")]
        let facts = IOSJevCompletionCheckService.unverifiedChanges(in: messages)
        XCTAssertEqual(facts?.changedFiles, ["/workspace/app.js"])
        XCTAssertEqual(facts?.finalReply, "已修复，测试通过。")
    }

    func testPassingCheckAfterWriteClearsFacts() {
        let messages = [
            user("修一下 app.js"), tool(write.0, input: write.1, output: write.2),
            tool("terminal_execute", input: #"{"command":"npm test"}"#, output: #"{"exit_code":0}"#),
            reply("已修复，测试通过。"),
        ]
        XCTAssertNil(IOSJevCompletionCheckService.unverifiedChanges(in: messages))
    }

    func testFailedCheckDoesNotCountAsVerification() {
        let messages = [
            user("修一下 app.js"), tool(write.0, input: write.1, output: write.2),
            tool("terminal_execute", input: #"{"command":"npm test"}"#, output: #"{"exit_code":1}"#),
            reply("已修复。"),
        ]
        XCTAssertNotNil(IOSJevCompletionCheckService.unverifiedChanges(in: messages))
    }

    func testWriteAfterCheckNeedsNewCheck() {
        let messages = [
            user("修一下 app.js"),
            tool("terminal_execute", input: #"{"command":"npm test"}"#, output: #"{"exit_code":0}"#),
            tool(write.0, input: write.1, output: write.2),
            reply("已修复。"),
        ]
        XCTAssertNotNil(IOSJevCompletionCheckService.unverifiedChanges(in: messages))
    }

    func testDocumentOnlyWritesDoNotPrompt() {
        let messages = [
            user("写一份报告"),
            tool("workspace_file_write", input: #"{"path":"/workspace/report.md"}"#, output: #"{"ok":true,"path":"/workspace/report.md"}"#),
            reply("报告已完成。"),
        ]
        XCTAssertNil(IOSJevCompletionCheckService.unverifiedChanges(in: messages))
    }

    func testUnchangedEditIsNotAWrite() {
        let messages = [
            user("改一下 app.js"),
            tool("workspace_file_edit", input: #"{"path":"/workspace/app.js"}"#, output: #"{"ok":true,"changed":false,"path":"/workspace/app.js"}"#),
            reply("无需修改。"),
        ]
        XCTAssertNil(IOSJevCompletionCheckService.unverifiedChanges(in: messages))
    }

    func testWriteFromEarlierTurnIsIgnored() {
        let messages = [user("修一下 app.js"), tool(write.0, input: write.1, output: write.2), reply("已修复。"), user("谢谢"), reply("不客气。")]
        XCTAssertNil(IOSJevCompletionCheckService.unverifiedChanges(in: messages))
    }

    private func makeService(mode: IOSJevMode, done: Double) -> (IOSJevCompletionCheckService, JevStubTransport) {
        var configured = IOSJevSettings()
        configured.setMode(mode, for: .completionCheck)
        configured.pinnedModelVersion = "jev-fixed-v1"
        let settings = configured
        let transport = JevStubTransport { _ in
            let payload: [String: Any] = ["model": "jev-latest", "answers": [
                "single.claims_done": ["type": "noul", "noul": done],
                "single.claims_verified": ["type": "noul", "noul": 0.1],
            ]]
            return (try! JSONSerialization.data(withJSONObject: payload),
                    HTTPURLResponse(url: IOSJevSettings.productionEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let coordinator = IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport), settingsProvider: { settings },
            apiKeyProvider: { "test-key" }, now: { Date() }, metricsStore: { _, _ in }
        ))
        return (IOSJevCompletionCheckService(deps: .init(coordinator: coordinator, settingsProvider: { settings })), transport)
    }

    private var unverifiedTurn: [UIMessage] {
        [user("修一下 app.js"), tool(write.0, input: write.1, output: write.2), reply("已修复，可以用了。")]
    }

    func testActiveClaimNeedsVerification() async {
        let (service, _) = makeService(mode: .active, done: 0.9)
        let needs = await service.needsVerification(messages: unverifiedTurn, runKey: "run")
        XCTAssertTrue(needs)
    }

    func testNoClaimDoesNotPrompt() async {
        let (service, _) = makeService(mode: .active, done: 0.2)
        let needs = await service.needsVerification(messages: unverifiedTurn, runKey: "run")
        XCTAssertFalse(needs)
    }

    func testFactsGateMakesZeroNetworkCalls() async {
        let (service, transport) = makeService(mode: .active, done: 0.9)
        let needs = await service.needsVerification(messages: [user("你好"), reply("你好！")], runKey: "run")
        XCTAssertFalse(needs)
        XCTAssertEqual(transport.calls, 0)
    }

    func testShadowAndOffNeverPrompt() async throws {
        let (shadow, shadowTransport) = makeService(mode: .shadow, done: 0.9)
        let shadowNeeds = await shadow.needsVerification(messages: unverifiedTurn, runKey: "run")
        XCTAssertFalse(shadowNeeds)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(shadowTransport.calls, 1)
        let (off, offTransport) = makeService(mode: .off, done: 0.9)
        let offNeeds = await off.needsVerification(messages: unverifiedTurn, runKey: "run")
        XCTAssertFalse(offNeeds)
        XCTAssertEqual(offTransport.calls, 0)
    }
}
