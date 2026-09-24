import XCTest
@testable import iosApp

// IOSJevApprovalTriageTests（增强 Phase E 审批分诊）：
// 三态分带语义（≥0.65 是 / ≤0.35 否 / 中间与缺题未知）、off 零网络、
// shadow 只观测不标注、active 应用、失败/范围不足 → nil（卡片原样）。
// 红线由设计保证：返回值只含标注信息，服务没有任何批准/拒绝通道。

@MainActor
final class IOSJevApprovalTriageTests: XCTestCase {

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: IOSJevSettings.productionEndpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func payload(readonly: Double? = nil, reversible: Double? = nil, aligned: Double? = nil) -> Data {
        var answers: [String: Any] = [:]
        if let readonly { answers["single.readonly"] = ["type": "noul", "noul": readonly] }
        if let reversible { answers["single.reversible"] = ["type": "noul", "noul": reversible] }
        if let aligned { answers["single.goal_aligned"] = ["type": "noul", "noul": aligned] }
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
        settings.setMode(mode, for: .approvalTriage)
        settings.pinnedModelVersion = pinned
        return settings
    }

    private func makeService(settings: IOSJevSettings, transport: JevStubTransport) -> IOSJevApprovalTriageService {
        let box = SettingsBox(settings)
        let coordinator = IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport),
            settingsProvider: { box.get() },
            apiKeyProvider: { "test-key" },
            now: { Date() }
        ))
        return IOSJevApprovalTriageService(deps: .init(
            coordinator: coordinator,
            settingsProvider: { box.get() }
        ))
    }

    // MARK: 三态分带

    func testBandSemantics() {
        XCTAssertEqual(IOSJevApprovalTriageService.band(0.9), .yes)
        XCTAssertEqual(IOSJevApprovalTriageService.band(0.65), .yes, "边界值入是")
        XCTAssertEqual(IOSJevApprovalTriageService.band(0.35), .no, "边界值入否")
        XCTAssertEqual(IOSJevApprovalTriageService.band(0.1), .no)
        XCTAssertEqual(IOSJevApprovalTriageService.band(0.5), .unknown, "中间带 = 未知")
        XCTAssertEqual(IOSJevApprovalTriageService.band(nil), .unknown, "缺题 = 未知")
        XCTAssertEqual(IOSJevApprovalTriageService.band(.nan), .unknown)
        XCTAssertEqual(IOSJevApprovalTriageService.band(.infinity), .unknown)
    }

    func testRegisteredToolFactsDoNotMistakeNoMutationForReadOnly() {
        let mutating = IOSJevApprovalTriageService.StaticFacts.registeredTool(
            metadataJSON: #"{"mutates":true,"risk":"sensitive"}"#
        )
        XCTAssertEqual(mutating?.readonly, .no)
        XCTAssertEqual(mutating?.reversible, .unknown)
        XCTAssertEqual(mutating?.risk, "sensitive")

        let noMutation = IOSJevApprovalTriageService.StaticFacts.registeredTool(
            metadataJSON: #"{"mutates":false,"risk":"normal"}"#
        )
        XCTAssertEqual(noMutation?.readonly, .unknown)
        XCTAssertEqual(noMutation?.reversible, .unknown)
    }

    // MARK: 模式与范围

    func testOffModeReturnsNilWithoutNetwork() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .off), transport: transport)
        let triage = await service.triage(requestId: "r1", toolName: "workspace_file_write", actionSummary: "edit(写)", goalText: "改文件", turnBudgetKey: "run")
        XCTAssertNil(triage)
        XCTAssertEqual(transport.calls, 0)
    }

    func testShadowObservesButReturnsNil() async {
        let transport = JevStubTransport { _ in (self.payload(readonly: 0.1, reversible: 0.1, aligned: 0.9), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .shadow, pinned: nil), transport: transport)
        let triage = await service.triage(requestId: "r1", toolName: "wm_click", actionSummary: "click", goalText: nil, turnBudgetKey: "run")
        XCTAssertNil(triage, "shadow 只观测不标注")
        XCTAssertEqual(transport.calls, 1)
    }

    func testScopeNotAllowedReturnsNilWithoutNetwork() async {
        var settings = makeSettings(mode: .active)
        settings.setScopes([.toolMetadata], for: .approvalTriage) // 缺 selectedTaskText
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(settings: settings, transport: transport)
        let triage = await service.triage(requestId: "r1", toolName: "t", actionSummary: "a", goalText: "g", turnBudgetKey: "run")
        XCTAssertNil(triage)
        XCTAssertEqual(transport.calls, 0)
    }

    // MARK: active 应用

    func testActiveMapsBands() async {
        let transport = JevStubTransport { _ in (self.payload(readonly: 0.2, reversible: 0.8, aligned: 0.5), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let triage = await service.triage(requestId: "r1", toolName: "workspace_file_edit", actionSummary: "edit(写)", goalText: "帮我改配置", turnBudgetKey: "run")
        XCTAssertEqual(triage?.requestId, "r1")
        XCTAssertEqual(triage?.readonly, .no)
        XCTAssertEqual(triage?.reversible, .yes)
        XCTAssertEqual(triage?.goalAligned, .unknown, "中间带 = 未知")
    }

    func testIncompletePartDoesNotApplyPartialAnswers() async {
        let transport = JevStubTransport { _ in (self.payload(readonly: 0.9), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let triage = await service.triage(requestId: "r1", toolName: "t", actionSummary: "a", goalText: nil, turnBudgetKey: "run")
        XCTAssertNil(triage, "协调器要求单个审批 part 的题目答案完整，不能应用部分答案")
    }

    func testKnownWorkspaceFactsOverrideJevAndParameterSummaryOmitsCredentials() async throws {
        let transport = JevStubTransport { _ in
            (self.payload(reversible: 0.5, aligned: 0.9), self.httpResponse(status: 200))
        }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let parameterSummary = IOSJevApprovalTriageService.parameterSummary(fromJSON: """
            {
              "target":"notes.md", "count":3, "api_key":"private-key", "password":"secret",
              "url":"https://alice:url-secret@example.com/plain?token=query-secret",
              "command":"curl -H 'Authorization: Bearer bearer-secret-1234' https://example.com/plain"
            }
            """)
        let triage = await service.triage(
            requestId: "r1",
            toolName: "workspace_file_write",
            actionSummary: "action=write",
            parameterSummary: parameterSummary,
            staticFacts: .workspace(isWrite: true),
            goalText: "修改笔记",
            turnBudgetKey: "run"
        )

        XCTAssertEqual(triage?.readonly, .no)
        XCTAssertEqual(triage?.reversible, .unknown)
        XCTAssertEqual(triage?.goalAligned, .yes)
        let body = try XCTUnwrap(transport.lastBody)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let questions = try XCTUnwrap(request["questions"] as? [String: Any])
        XCTAssertEqual(Set(questions.keys), Set(["single.reversible", "single.goal_aligned"]), "known read/write fact is not re-asked; unknown reversibility may be judged")
        let state = try XCTUnwrap(request["state"] as? String)
        XCTAssertTrue(state.contains("target=notes.md"))
        XCTAssertTrue(state.contains("count=3"))
        XCTAssertTrue(state.contains("https://example.com/plain"))
        XCTAssertFalse(state.contains("private-key"))
        XCTAssertFalse(state.contains("alice"))
        XCTAssertFalse(state.contains("secret"))
    }

    func testMcpApprovalWithoutParameterSummaryShowsUnknownWithoutNetwork() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let triage = await service.triage(
            requestId: "r1",
            toolName: "remote/read_record",
            actionSummary: "",
            parameterSummary: IOSJevApprovalTriageService.parameterSummary(fromJSON: "{}"),
            requiresParameterSummary: true,
            goalText: "查看记录",
            turnBudgetKey: "run"
        )

        XCTAssertEqual(triage?.readonly, .unknown)
        XCTAssertEqual(triage?.reversible, .unknown)
        XCTAssertEqual(triage?.goalAligned, .unknown)
        XCTAssertEqual(transport.calls, 0, "缺少参数时不要求 Jev 猜测 MCP 动作")
    }

    func testJevFailureKeepsKnownWorkspaceFacts() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 500)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let triage = await service.triage(
            requestId: "r1",
            toolName: "workspace_file_write",
            actionSummary: "action=write",
            staticFacts: .workspace(isWrite: true),
            goalText: "修改笔记",
            turnBudgetKey: "run"
        )

        XCTAssertEqual(triage?.readonly, .no)
        XCTAssertEqual(triage?.reversible, .unknown)
        XCTAssertEqual(triage?.goalAligned, .unknown)
    }

    func testFailureReturnsNil() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 500)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let triage = await service.triage(requestId: "r1", toolName: "t", actionSummary: "a", goalText: nil, turnBudgetKey: "run")
        XCTAssertNil(triage, "失败即无标注（fail-open 到原卡片）")
    }
}
