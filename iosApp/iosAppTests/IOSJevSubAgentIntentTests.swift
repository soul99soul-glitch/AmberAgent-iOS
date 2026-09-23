import XCTest
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
