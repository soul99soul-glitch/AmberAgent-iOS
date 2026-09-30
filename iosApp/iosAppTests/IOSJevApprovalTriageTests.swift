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

// IOSJevAutoApprovalGateTests（v2 Phase 2 自动批准复核）：只收紧不放行、
// 用户明确要求可豁免（外发除外）、shadow/off/失败维持自动批准。
@MainActor
final class IOSJevAutoApprovalGateTests: XCTestCase {
    private func makeGate(
        mode: IOSJevMode,
        answers: [String: Double],
        status: Int = 200
    ) -> (IOSJevAutoApprovalGate, JevStubTransport) {
        var configured = IOSJevSettings()
        configured.setMode(mode, for: .autoApprovalGate)
        configured.pinnedModelVersion = "jev-fixed-v1"
        let settings = configured
        let transport = JevStubTransport { _ in
            let payload: [String: Any] = [
                "model": "jev-latest",
                "answers": Dictionary(uniqueKeysWithValues: answers.map { ("single.\($0.key)", ["type": "noul", "noul": $0.value]) }),
            ]
            return (try! JSONSerialization.data(withJSONObject: payload),
                    HTTPURLResponse(url: IOSJevSettings.productionEndpoint, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let coordinator = IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport),
            settingsProvider: { settings },
            apiKeyProvider: { "test-key" },
            now: { Date() },
            metricsStore: { _, _ in }
        ))
        return (IOSJevAutoApprovalGate(deps: .init(coordinator: coordinator, settingsProvider: { settings })), transport)
    }

    private func ask(_ gate: IOSJevAutoApprovalGate, id: String = "call-1") async -> Bool {
        await gate.shouldEscalate(
            requestId: id, toolName: "terminal_execute", argumentsJSON: #"{"command":"rm -rf build"}"#,
            recentUserTexts: ["帮我看看项目结构"], runKey: "run"
        )
    }

    private let allAnswers = ["destructive": 0.1, "exfiltration": 0.1, "offTask": 0.1, "authorized": 0.1]

    func testHighRiskEscalatesAndRecordsReason() async {
        var answers = allAnswers
        answers["destructive"] = 0.9
        let (gate, _) = makeGate(mode: .active, answers: answers)
        let escalated = await ask(gate)
        XCTAssertTrue(escalated)
        XCTAssertEqual(gate.escalationReasons(requestId: "call-1"), ["破坏性"])
    }

    func testExplicitlyRequestedActionIsNotEscalated() async {
        var answers = allAnswers
        answers["destructive"] = 0.9
        answers["authorized"] = 0.9
        let (gate, _) = makeGate(mode: .active, answers: answers)
        let escalated = await ask(gate)
        XCTAssertFalse(escalated)
        XCTAssertNil(gate.escalationReasons(requestId: "call-1"))
    }

    func testExfiltrationIsEscalatedEvenWhenRequested() async {
        var answers = allAnswers
        answers["exfiltration"] = 0.9
        answers["authorized"] = 0.9
        let (gate, _) = makeGate(mode: .active, answers: answers)
        let escalated = await ask(gate)
        XCTAssertTrue(escalated)
        XCTAssertEqual(gate.escalationReasons(requestId: "call-1"), ["外发数据"])
    }

    func testLowRiskKeepsAutoApproval() async {
        let (gate, _) = makeGate(mode: .active, answers: allAnswers)
        let escalated = await ask(gate)
        XCTAssertFalse(escalated)
    }

    func testFailureKeepsAutoApproval() async {
        let (gate, transport) = makeGate(mode: .active, answers: [:], status: 500)
        let escalated = await ask(gate)
        XCTAssertFalse(escalated)
        XCTAssertGreaterThanOrEqual(transport.calls, 1, "客户端对 5xx 会按既有策略重试")
    }

    func testShadowNeverEscalates() async throws {
        var answers = allAnswers
        answers["destructive"] = 0.9
        let (gate, transport) = makeGate(mode: .shadow, answers: answers)
        let escalated = await ask(gate)
        XCTAssertFalse(escalated)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(transport.calls, 1, "shadow 在后台观测")
    }

    /// 终端工具 mutates=false 但风险为 sensitive，不能按只读跳过复核。
    func testOnlyNormalRiskNonMutatingCallsSkipReview() {
        let terminal = IOSJevApprovalTriageService.StaticFacts.registeredTool(metadataJSON: #"{"mutates":false,"risk":"sensitive"}"#)
        let read = IOSJevApprovalTriageService.StaticFacts.registeredTool(metadataJSON: #"{"mutates":false,"risk":"normal"}"#)
        let write = IOSJevApprovalTriageService.StaticFacts.registeredTool(metadataJSON: #"{"mutates":true,"risk":"normal"}"#)
        XCTAssertFalse(IOSJevAutoApprovalGate.isStaticallyLowRisk(terminal))
        XCTAssertTrue(IOSJevAutoApprovalGate.isStaticallyLowRisk(read))
        XCTAssertFalse(IOSJevAutoApprovalGate.isStaticallyLowRisk(write))
        XCTAssertFalse(IOSJevAutoApprovalGate.isStaticallyLowRisk(nil), "无元数据时交给 Jev")
    }

    func testReaskClearsStaleEscalation() async {
        final class Box: @unchecked Sendable { var destructive = 0.9 }
        let box = Box()
        var configured = IOSJevSettings()
        configured.setMode(.active, for: .autoApprovalGate)
        configured.pinnedModelVersion = "jev-fixed-v1"
        let settings = configured
        let transport = JevStubTransport { _ in
            let answers: [String: Double] = ["destructive": box.destructive, "exfiltration": 0.1, "offTask": 0.1, "authorized": 0.1]
            let payload: [String: Any] = ["model": "jev-latest", "answers": Dictionary(uniqueKeysWithValues: answers.map {
                ("single.\($0.key)", ["type": "noul", "noul": $0.value])
            })]
            return (try! JSONSerialization.data(withJSONObject: payload),
                    HTTPURLResponse(url: IOSJevSettings.productionEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let coordinator = IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport), settingsProvider: { settings },
            apiKeyProvider: { "test-key" }, now: { Date() }, metricsStore: { _, _ in }
        ))
        let gate = IOSJevAutoApprovalGate(deps: .init(coordinator: coordinator, settingsProvider: { settings }))
        let first = await gate.shouldEscalate(requestId: "same", toolName: "terminal_execute", argumentsJSON: #"{"command":"rm -rf a"}"#, recentUserTexts: [], runKey: "run")
        XCTAssertTrue(first)
        box.destructive = 0.1
        let second = await gate.shouldEscalate(requestId: "same", toolName: "terminal_execute", argumentsJSON: #"{"command":"ls a"}"#, recentUserTexts: [], runKey: "run")
        XCTAssertFalse(second)
        XCTAssertNil(gate.escalationReasons(requestId: "same"), "同一请求重新判定为低风险时清除旧标签")
    }

    /// 收紧快照同时把逐能力自动批准降为每次询问（该能力提供此选项时）。
    func testWithoutAutoApproveDowngradesCapabilityAutoApprove() throws {
        let capability = try XCTUnwrap(IOSCapabilityRegistry.capabilities.first {
            let options = IOSPermissionStore.availablePolicies(for: $0)
            return options.contains(.autoApprove) && options.contains(.askEveryTime)
        })
        let snapshot = IOSExecutionPolicySnapshot(
            capabilityPolicies: [capability.id: IOSAgentPermissionPolicy.autoApprove.rawValue],
            globalAutoApproveEnabled: true, highRiskAutoApproveEnabled: true,
            execJavaScriptEnabled: false, webSearchEnabled: false
        )
        let tightened = snapshot.withoutAutoApprove()
        XCTAssertFalse(tightened.globalAutoApproveEnabled)
        XCTAssertFalse(tightened.highRiskAutoApproveEnabled)
        XCTAssertEqual(tightened.policy(for: capability), .askEveryTime)
    }

    func testOffMakesZeroNetworkCalls() async {
        let (gate, transport) = makeGate(mode: .off, answers: allAnswers)
        let escalated = await ask(gate)
        XCTAssertFalse(escalated)
        XCTAssertEqual(transport.calls, 0)
    }
}
