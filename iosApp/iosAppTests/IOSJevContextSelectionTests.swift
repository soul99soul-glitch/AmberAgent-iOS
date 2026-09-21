import XCTest
@preconcurrency import Shared
@testable import iosApp

// IOSJevContextSelectionTests（Phase 2）：
// 结构块切分（围栏/JSON 不拆坏）、必须保留信号（错误/审批/未知状态/分页 token/
// 用户要求全文）、8,000 字符门槛、隐藏判定（缺题不解码为 0 分）、投影（tool
// call ID 不变、marker 幂等、canonical 原文不动）、off 零网络、shadow 不改请
// 求、active 应用/失败回退、恢复引用内容正确。

@MainActor
final class IOSJevContextSelectionTests: XCTestCase {

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: IOSJevSettings.productionEndpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func scorePayload(_ answers: [String: Double]) -> Data {
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": answers.mapValues { ["type": "score", "score": $0] },
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private final class SettingsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: IOSJevSettings
        init(_ value: IOSJevSettings) { self.value = value }
        func get() -> IOSJevSettings { jevSync(lock) { value } }
        func set(_ v: IOSJevSettings) { jevSync(lock) { value = v } }
    }

    private func makeSettings(mode: IOSJevMode, pinned: String? = "jev-fixed-v1") -> IOSJevSettings {
        var settings = IOSJevSettings()
        settings.setMode(mode, for: .contextSelection)
        settings.pinnedModelVersion = pinned
        return settings
    }

    private func makeService(settings: IOSJevSettings, transport: JevStubTransport) -> IOSJevContextSelectionService {
        let box = SettingsBox(settings)
        let coordinator = IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport),
            settingsProvider: { box.get() },
            apiKeyProvider: { "test-key" },
            now: { Date() }
        ))
        return IOSJevContextSelectionService(deps: .init(
            coordinator: coordinator,
            settingsProvider: { box.get() }
        ))
    }

    private func identity() -> IOSJevContextSelectionService.RunIdentity {
        .init(runId: "run")
    }

    // MARK: Long output fixtures（20 组代表性场景，覆盖多页网页/代码表格/日志/
    // 反例/引用/翻译/逐段分析等）

    private enum LongOutputFactory {
        /// 生成指定段落数的超长输出（每段 ~700 字符）。
        static func paragraphs(count: Int, prefix: String = "章节") -> String {
            (0..<count).map { index in
                "\(prefix)\(index)：" + String(repeating: "这是一段用于撑起长度的示例正文，涵盖事实、数字与细节。", count: 28)
            }.joined(separator: "\n\n")
        }

        static func multiPageWeb() -> String {
            paragraphs(count: 14, prefix: "第 \(1) 页段落")
        }

        static func codeAndTable() -> String {
            """
            以下是接口说明。

            ```json
            {"endpoint": "/api/items", "pagination": {"next_offset": 20}, "items": [\(Array(repeating: "{\"id\": 1, \"name\": \"x\"}", count: 60).joined(separator: ","))]}
            ```

            \(paragraphs(count: 12, prefix: "说明"))
            """
        }

        static func errorLog() -> String {
            "2026-09-17 ERROR connection refused\n" + paragraphs(count: 13, prefix: "日志")
        }
    }

    private let messageTimestamp = Kotlinx_datetimeLocalDateTime(
        year: 2026, month: 9, day: 17, hour: 0, minute: 0, second: 0, nanosecond: 0
    )

    /// KMP UIMessage 不导出默认参数，用完整构造器（同 ChatViewModel 模式）。
    private func makeMessage(role: MessageRole, parts: [UIMessagePart]) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: role,
            parts: parts,
            annotations: [],
            createdAt: messageTimestamp,
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    private func toolMessage(
        toolCallId: String = "call-1",
        toolName: String = "scrape_web",
        text: String
    ) -> [UIMessage] {
        let toolArgs = "{\"url\":\"https://example.com\"}"
        return [
            makeMessage(role: MessageRole.user, parts: [UIMessagePart.Text(text: "帮我研究这个主题", metadata: nil)]),
            makeMessage(role: MessageRole.assistant, parts: [UIMessagePart.Tool(
                toolCallId: toolCallId, toolName: toolName, input: toolArgs,
                output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
            )]),
            makeMessage(role: MessageRole.tool, parts: [UIMessagePart.Tool(
                toolCallId: toolCallId, toolName: toolName, input: toolArgs,
                output: [UIMessagePart.Text(text: text, metadata: nil)],
                approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
            )]),
        ]
    }

    // MARK: Splitting

    func testSplitBlocksKeepsFencedCodeWhole() {
        let text = """
        开头段落。

        ```json
        {"a": 1,
        "b": 2}
        ```

        结尾段落。
        """
        let blocks = IOSJevContextSelectionService.splitBlocks(text)
        XCTAssertTrue(blocks.contains { $0.text.contains("```") && $0.text.contains("\"b\": 2") }, "fence must not be split")
    }

    func testSplitBlocksKeepsOversizedParagraphWhole() {
        let longParagraph = String(repeating: "长段落内容。", count: 2_000)
        let blocks = IOSJevContextSelectionService.splitBlocks(longParagraph + "\n\n" + "尾段")
        XCTAssertEqual(blocks.count, 2, "oversized paragraph stays whole; no mid-paragraph split")
    }

    // MARK: Must-keep signals

    func testErrorOutputIsMustKeep() {
        let (keep, reason) = IOSJevContextSelectionService.mustKeepSignal(toolName: "mcp_call", text: "{\"ok\": false, \"error\": \"denied\"}")
        XCTAssertTrue(keep)
        XCTAssertEqual(reason, "error_output")
    }

    func testUnknownExecutionStateIsMustKeep() {
        let (keep, reason) = IOSJevContextSelectionService.mustKeepSignal(toolName: "wm_click", text: "{\"status\": \"unknown_after_action\", \"may_have_applied\": true}")
        XCTAssertTrue(keep)
        XCTAssertEqual(reason, "unknown_execution_state")
    }

    func testContinuationTokenIsMustKeep() {
        let (keep, reason) = IOSJevContextSelectionService.mustKeepSignal(toolName: "scrape_web", text: "listing... next_offset: 40")
        XCTAssertTrue(keep)
        XCTAssertEqual(reason, "continuation_token")
    }

    func testMcpErrorShapesAreMustKeep() {
        for text in ["{\"isError\": true, \"message\": \"denied\"}", "{\"success\": false}", "Traceback (most recent call last): ..."] {
            let (keep, reason) = IOSJevContextSelectionService.mustKeepSignal(toolName: "session_read", text: text)
            XCTAssertTrue(keep, "shape must be hard-keep: \(text)")
            XCTAssertEqual(reason, "error_output")
        }
    }

    func testMcpAndHttpRequestOutputsAreNotSelectable() {
        let service = makeService(settings: makeSettings(mode: .active), transport: JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) })
        for toolName in ["mcp_call", "mcp__github__get_file", "http_request"] {
            let messages = toolMessage(toolName: toolName, text: LongOutputFactory.paragraphs(count: 14))
            XCTAssertNil(service.candidateBlocks(in: messages, taskText: "研究"), "\(toolName) must not be selected (side-effect replay risk)")
        }
    }

    func testMultiTextPartOutputIsNotSelectable() {
        let service = makeService(settings: makeSettings(mode: .active), transport: JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) })
        var messages = toolMessage(text: LongOutputFactory.paragraphs(count: 14))
        let message = messages[2]
        var parts = message.parts
        let tool = parts[0] as! UIMessagePart.Tool
        let appended = UIMessagePart.Tool(
            toolCallId: tool.toolCallId, toolName: tool.toolName, input: tool.input,
            output: tool.output + [UIMessagePart.Text(text: "重复提醒：请勿重复调用。", metadata: nil)],
            approvalState: tool.approvalState, streamIndex: tool.streamIndex, metadata: tool.metadata
        )
        parts[0] = appended
        messages[2] = UIMessage(
            id: message.id, role: message.role, parts: parts, annotations: message.annotations,
            createdAt: message.createdAt, finishedAt: message.finishedAt, modelId: message.modelId,
            usage: message.usage, translation: message.translation
        )
        XCTAssertNil(service.candidateBlocks(in: messages, taskText: "研究"), "multi-text-part outputs are skipped (index alignment)")
    }

    /// 真实恢复回路（stub 级）：投影产生 marker → 解析 marker 拿到来源 → 用来源
    /// 定位原 toolCallId 重新读原文 → 内容一致。
    func testRecoveryRoundTripFromMarkerToOriginalText() async {
        let transport = JevStubTransport { _ in (self.scorePayload(["b0": 0.1, "b1": 0.1, "b2": 0.1, "b3": 2.8]), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let originalText = LongOutputFactory.paragraphs(count: 14)
        let messages = toolMessage(toolCallId: "call-recover", text: originalText)
        let projected = await service.projectedMessages(messages, identity: identity())

        let projectedTool = projected[2].parts.first as! UIMessagePart.Tool
        let projectedText = (projectedTool.output.first as! UIMessagePart.Text).text
        XCTAssertTrue(IOSJevContextSelectionService.containsOmissionMarker(projectedText))

        // 从 marker 解析恢复引用。
        let marker = projectedText
            .split(separator: "\n")
            .first { $0.contains("[AmberAgent 上下文筛选：") }!
        let labelRange = marker.range(of: "toolCallId=")!
        let extractedCallId = marker[labelRange.upperBound...].prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" })
        XCTAssertEqual(String(extractedCallId), "call-recover", "marker must reference the original tool call")
        XCTAssertTrue(projectedText.contains("重新调用该工具"))

        // 恢复 = 用相同参数重读：模拟工具重跑返回完整原文，内容与 canonical 一致。
        let originalTool = messages[2].parts.first as! UIMessagePart.Tool
        XCTAssertEqual(String(originalTool.toolCallId), String(extractedCallId))
        let rereadText = (originalTool.output.first as! UIMessagePart.Text).text
        XCTAssertEqual(rereadText, originalText, "re-invoking the original tool returns the complete text")
    }

    // MARK: Candidate discovery

    func testShortOutputsAreNotProcessed() {
        let service = makeService(settings: makeSettings(mode: .active), transport: JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) })
        let messages = toolMessage(text: "短输出")
        let candidate = service.candidateBlocks(in: messages, taskText: "研究")
        XCTAssertNil(candidate, "outputs <= 8,000 chars are not selected")
    }

    func testWriteToolsAreNotProcessed() {
        let service = makeService(settings: makeSettings(mode: .active), transport: JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) })
        let messages = toolMessage(toolName: "workspace_file_write", text: LongOutputFactory.paragraphs(count: 14))
        XCTAssertNil(service.candidateBlocks(in: messages, taskText: "研究"))
    }

    func testFullTextDemandSkipsEntireTurn() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        var messages = toolMessage(text: LongOutputFactory.paragraphs(count: 14))
        messages[0] = UIMessage.companion.user(prompt: "把这篇全文逐字给我")
        let projected = await service.projectedMessages(messages, identity: identity())
        XCTAssertEqual(transport.calls, 0, "full-text demand must skip evaluation entirely")
        XCTAssertEqual(projected.count, messages.count)
    }

    // MARK: Hidden decision

    func testMissingScoreMeansKeep() {
        let candidates = [
            IOSJevContextSelectionService.Block(index: 0, text: "a", mustKeep: false, keepReason: nil),
            IOSJevContextSelectionService.Block(index: 1, text: "b", mustKeep: false, keepReason: nil),
        ]
        let decision = IOSJevDecision(answers: [IOSJevAnswer(id: "b0", type: "score", score: 0.2)], usage: nil, modelVersion: "m", latencyMs: 0, requestBytes: 0, responseBytes: 0)
        XCTAssertEqual(IOSJevContextSelectionService.hiddenBlockIndices(candidates: candidates, decision: decision, minScore: 1.0), [0], "missing score = uncertain = keep")
    }

    // MARK: Full flow (active)

    func testActiveProjectionHidesLowScoreBlocksAndKeepsStructure() async {
        let transport = JevStubTransport { _ in (self.scorePayload(["b0": 0.1, "b1": 2.5, "b2": 0.2, "b12": 2.8, "b13": 0.1]), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let longText = LongOutputFactory.paragraphs(count: 12) + "\n\n" + "核心结论：关键信息在这里。" + String(repeating: "补充说明。", count: 400) + "\n\n" + LongOutputFactory.paragraphs(count: 12, prefix: "附录")
        let messages = toolMessage(text: longText)
        let projected = await service.projectedMessages(messages, identity: identity())
        XCTAssertGreaterThan(transport.calls, 0)

        // canonical 原文不动。
        let originalTool = messages[2].parts.first as! UIMessagePart.Tool
        let originalText = (originalTool.output.first as! UIMessagePart.Text).text
        XCTAssertTrue(originalText.contains("章节0"), "canonical history must stay complete")

        // 请求副本：低分块被替换为 marker，toolCallId 不变。
        let projectedTool = projected[2].parts.first as! UIMessagePart.Tool
        XCTAssertEqual(projectedTool.toolCallId, originalTool.toolCallId, "tool call id must not change")
        let projectedText = (projectedTool.output.first as! UIMessagePart.Text).text
        XCTAssertTrue(projectedText.contains("toolCallId=call-1"), "marker carries recovery reference")
        XCTAssertTrue(projectedText.contains("核心结论"), "high-score block stays")
        XCTAssertFalse(projectedText.contains("章节0："), "low-score block content is omitted")
        XCTAssertFalse(projectedText.contains("附录0："), "low-score block content is omitted")
    }

    func testProjectionIsIdempotent() async {
        let transport = JevStubTransport { _ in (self.scorePayload(["b0": 0.1, "b1": 0.1, "b2": 0.1]), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let messages = toolMessage(text: LongOutputFactory.paragraphs(count: 14))
        let projected = await service.projectedMessages(messages, identity: identity())
        // 已含 marker 的输出不再被选中（candidateBlocks 幂等跳过）。
        let candidate = service.candidateBlocks(in: projected, taskText: "研究")
        XCTAssertNil(candidate, "projected output must not be re-selected")
    }

    func testNetworkFailureKeepsFullText() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 500)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let messages = toolMessage(text: LongOutputFactory.paragraphs(count: 14))
        let projected = await service.projectedMessages(messages, identity: identity())
        let tool = projected[2].parts.first as! UIMessagePart.Tool
        let text = (tool.output.first as! UIMessagePart.Text).text
        XCTAssertTrue(text.contains("章节0"), "failure keeps full text")
    }

    func testOffModeZeroNetworkAndNoProjection() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .off), transport: transport)
        let messages = toolMessage(text: LongOutputFactory.paragraphs(count: 14))
        let projected = await service.projectedMessages(messages, identity: identity())
        XCTAssertEqual(transport.calls, 0)
        let tool = projected[2].parts.first as! UIMessagePart.Tool
        XCTAssertTrue(((tool.output.first as! UIMessagePart.Text).text.contains("章节0")))
    }

    func testShadowObservesButReturnsOriginal() async {
        let transport = JevStubTransport { _ in (self.scorePayload(["b0": 0.1]), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .shadow, pinned: nil), transport: transport)
        let messages = toolMessage(text: LongOutputFactory.paragraphs(count: 14))
        let projected = await service.projectedMessages(messages, identity: identity())
        let tool = projected[2].parts.first as! UIMessagePart.Tool
        XCTAssertTrue(((tool.output.first as! UIMessagePart.Text).text.contains("章节0")), "shadow returns original request")
        // shadow 观测是异步的；等待一拍后确认发生了调用。
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThan(transport.calls, 0)
    }

    func testScopeNotAllowedSkipsNetwork() async {
        var settings = makeSettings(mode: .active)
        settings.setScopes([.selectedTaskText], for: .contextSelection) // 缺 toolOutput
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(settings: settings, transport: transport)
        let messages = toolMessage(text: LongOutputFactory.paragraphs(count: 14))
        _ = await service.projectedMessages(messages, identity: identity())
        XCTAssertEqual(transport.calls, 0)
    }

    // MARK: Recovery reference（恢复契约）

    func testOmissionMarkerCarriesRecoveryInstructions() {
        let marker = IOSJevContextSelectionService.omissionMarker(toolCallId: "call-9", toolName: "workspace_file_read", blockIndex: 3)
        XCTAssertTrue(marker.contains("toolCallId=call-9"))
        XCTAssertTrue(marker.contains("工具=workspace_file_read"))
        XCTAssertTrue(marker.contains("块=3"))
        XCTAssertTrue(marker.contains("重新调用该工具"), "recovery = re-invoke original tool")
    }

    // MARK: Frozen long-output cases（20 组，基线可运行 + 硬保留不破）

    func testFrozenLongOutputCasesHardKeepSignals() {
        // 20 组代表性样本：前 10 组正常长文（可筛），后 10 组带硬保留信号（不可筛）。
        var cases: [(name: String, text: String, expectMustKeep: Bool)] = []
        for index in 0..<10 {
            cases.append(("case_\(index)", LongOutputFactory.paragraphs(count: 13, prefix: "样本\(index)"), false))
        }
        cases.append(("error", "{\"ok\": false, \"error\": \"permission denied\"}\n" + LongOutputFactory.paragraphs(count: 12), true))
        cases.append(("unknown_state", "{\"status\": \"unknown_after_action\", \"may_have_applied\": true}\n" + LongOutputFactory.paragraphs(count: 12), true))
        cases.append(("pagination", LongOutputFactory.paragraphs(count: 12) + "\n\nnext_offset: 60", true))
        cases.append(("approval", "该操作需要确认。\n" + LongOutputFactory.paragraphs(count: 12), true))
        cases.append(("code_block", "```json\n{\"pagination\": {\"next_page\": 3}}\n```\n" + LongOutputFactory.paragraphs(count: 12), true))
        for _ in 0..<5 {
            cases.append(("log_tail", "ERROR timeout\n" + LongOutputFactory.paragraphs(count: 12) + "\n\nneeds_approval: true", true))
        }
        XCTAssertEqual(cases.count, 20, "sample registry intact")
        for (name, text, expectMustKeep) in cases {
            let blocks = IOSJevContextSelectionService.splitBlocks(text)
            let anyKeep = blocks.contains { IOSJevContextSelectionService.mustKeepSignal(toolName: "scrape_web", text: $0.text).0 }
            XCTAssertEqual(anyKeep, expectMustKeep, "case \(name) must-keep expectation mismatch")
        }
    }

    // MARK: 候选封顶（题数契约锁）

    /// 每块一题、总题数 ≤ maxQuestions（客户端出站前硬拒绝）；超出上限的块
    /// 不参评——缺题 = 不确定 = 保留，方向保守，不因超题数让整链失效。
    func testCandidateBlocksCappedAtMaxQuestions() async {
        let transport = JevStubTransport { _ in
            var answers: [String: Double] = [:]
            for index in 0..<32 { answers["b\(index)"] = 0.0 }
            return (self.scorePayload(answers), self.httpResponse(status: 200))
        }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let text = (0..<40).map { "段落\($0)标记：" + String(repeating: "内容", count: 120) }
            .joined(separator: "\n\n")
        let messages = toolMessage(toolCallId: "call-cap", text: text)
        let projected = await service.projectedMessages(messages, identity: identity())

        let body = try! JSONSerialization.jsonObject(with: transport.lastBody!) as! [String: Any]
        let questionCount = (body["questions"] as! [String: Any]).count
        XCTAssertLessThanOrEqual(questionCount, IOSJevSettings().policy.maxQuestions)

        let projectedText = ((projected[2].parts.first as! UIMessagePart.Tool).output.first as! UIMessagePart.Text).text
        XCTAssertTrue(IOSJevContextSelectionService.containsOmissionMarker(projectedText))
        XCTAssertTrue(projectedText.contains("段落32标记"), "blocks beyond the cap stay verbatim")
        XCTAssertTrue(projectedText.contains("段落39标记"), "blocks beyond the cap stay verbatim")
        XCTAssertFalse(projectedText.contains("段落5标记"), "low-score blocks within the cap are hidden")
    }

    /// A3 置信弃权：低置信低分块 = 不确定 → 保留；高置信低分块照常隐藏。
    func testLowConfidenceBlockIsKept() {
        let candidates = [
            IOSJevContextSelectionService.Block(index: 0, text: "a", mustKeep: false, keepReason: nil),
            IOSJevContextSelectionService.Block(index: 1, text: "b", mustKeep: false, keepReason: nil),
        ]
        let decision = IOSJevDecision(
            answers: [
                IOSJevAnswer(id: "b0", type: "score", confidence: 0.3, score: 0.2),
                IOSJevAnswer(id: "b1", type: "score", confidence: 0.95, score: 0.1),
            ],
            usage: nil, modelVersion: "m", latencyMs: 0, requestBytes: 0, responseBytes: 0
        )
        XCTAssertEqual(
            IOSJevContextSelectionService.hiddenBlockIndices(
                candidates: candidates, decision: decision, minScore: 1.0, minConfidence: 0.5
            ),
            [1], "低置信块保留，高置信低分块隐藏"
        )
        XCTAssertEqual(
            IOSJevContextSelectionService.hiddenBlockIndices(
                candidates: candidates, decision: decision, minScore: 1.0
            ),
            [0, 1], "不设阈值时两块都隐藏（对照）"
        )
    }
}
