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
        if let readonly { answers["readonly"] = ["type": "noul", "noul": readonly] }
        if let reversible { answers["reversible"] = ["type": "noul", "noul": reversible] }
        if let aligned { answers["goal_aligned"] = ["type": "noul", "noul": aligned] }
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

    func testMissingAnswersAreUnknown() async {
        let transport = JevStubTransport { _ in (self.payload(readonly: 0.9), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let triage = await service.triage(requestId: "r1", toolName: "t", actionSummary: "a", goalText: nil, turnBudgetKey: "run")
        XCTAssertEqual(triage?.readonly, .yes)
        XCTAssertEqual(triage?.reversible, .unknown, "缺题 = 未知，不伪造")
        XCTAssertEqual(triage?.goalAligned, .unknown)
    }

    func testFailureReturnsNil() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 500)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let triage = await service.triage(requestId: "r1", toolName: "t", actionSummary: "a", goalText: nil, turnBudgetKey: "run")
        XCTAssertNil(triage, "失败即无标注（fail-open 到原卡片）")
    }
}
