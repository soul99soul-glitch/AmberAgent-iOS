import XCTest
@preconcurrency import Shared
@testable import iosApp

// IOSJevContextSelectionTests（Phase 2 / Phase 3）：
// 结构块切分（围栏/JSON 不拆坏）、必须保留信号（错误/审批/未知状态/分页 token/
// 用户要求全文）、8,000 字符门槛、隐藏判定（缺题不解码为 0 分）、投影（tool
// call ID 不变、marker 幂等、canonical 原文不动）、off 零网络、shadow 不改请
// 求、active 应用/失败固定全文、跨轮决策重放、相邻段落合并与长块首尾送检。

@MainActor
final class IOSJevContextSelectionTests: XCTestCase {

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: IOSJevSettings.productionEndpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func scorePayload(_ answers: [String: Double]) -> Data {
        let coordinatorAnswers = Dictionary(uniqueKeysWithValues: answers.map { entry in
            let id = entry.key
            return (id.hasPrefix("single.") ? id : "single.\(id)", entry.value)
        })
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": coordinatorAnswers.mapValues { ["type": "score", "score": $0] },
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func scorePayload(for request: URLRequest, score: Double = 0.1) -> Data {
        let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let questionIds = Array((body["questions"] as! [String: Any]).keys)
        return scorePayload(Dictionary(uniqueKeysWithValues: questionIds.map { ($0, score) }))
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

    private func identity(
        runId: String = "run",
        conversationId: String? = "conversation-1"
    ) -> IOSJevContextSelectionService.RunIdentity {
        .init(runId: runId, conversationId: conversationId)
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
            "ERROR: connection refused\n" + paragraphs(count: 13, prefix: "日志")
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

    private func appendingToolMessage(
        to messages: [UIMessage],
        toolCallId: String,
        text: String,
        prompt: String
    ) -> [UIMessage] {
        let toolName = "scrape_web"
        let toolArgs = "{\"url\":\"https://example.com/\(toolCallId)\"}"
        return messages + [
            UIMessage.companion.user(prompt: prompt),
            makeMessage(role: .assistant, parts: [UIMessagePart.Tool(
                toolCallId: toolCallId, toolName: toolName, input: toolArgs,
                output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
            )]),
            makeMessage(role: .tool, parts: [UIMessagePart.Tool(
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

    func testSplitBlocksMergesAdjacentParagraphsAndPreservesTables() {
        let paragraphs = (0..<8).map { "段落\($0)：" + String(repeating: "内容。", count: 180) }
        let table = "| 名称 | 值 |\n| --- | --- |\n| alpha | 1 |\n| beta | 2 |"
        let text = paragraphs.joined(separator: "\n\n") + "\n\n" + table + "\n\n尾段。"
        let blocks = IOSJevContextSelectionService.splitBlocks(text)

        XCTAssertLessThan(blocks.filter { $0.text.hasPrefix("段落") }.count, paragraphs.count, "adjacent paragraphs should merge")
        XCTAssertTrue(blocks.contains { $0.text == table }, "a Markdown table remains one structure block")
        XCTAssertTrue(blocks.contains { $0.text == "尾段。" })
        for block in blocks where block.text.hasPrefix("段落") {
            if block.text.count < 2_000, blocks.count > 3 {
                XCTAssertGreaterThan(block.text.count, 1_000, "ordinary paragraphs should merge toward the target size")
            }
        }
    }

    func testInspectionExcerptIncludesHeadAndTail() {
        let text = String(repeating: "A", count: 700) + String(repeating: "M", count: 1_000) + String(repeating: "Z", count: 700)
        let block = IOSJevContextSelectionService.Block(index: 0, text: text, mustKeep: false, keepReason: nil)
        let state = IOSJevContextSelectionService.stateText(taskText: "research", blocks: [block])

        XCTAssertTrue(state.contains(String(repeating: "A", count: 100)))
        XCTAssertTrue(state.contains(String(repeating: "Z", count: 100)))
        XCTAssertFalse(state.contains(String(repeating: "M", count: 100)), "the omitted middle should not occupy the excerpt")
        XCTAssertLessThan(state.count, 1_100)
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
        let (keep, reason) = IOSJevContextSelectionService.mustKeepSignal(toolName: "scrape_web", text: "{\"next_offset\": 40}")
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

    func testUnstructuredKeywordsDoNotForceKeepButStructuredSignalsDo() {
        for text in [
            "The cursor moves to the next page; there is a todo in the source and an error: field in the example.",
            "{\"cursor\": \"abc\", \"todo\": false}",
        ] {
            XCTAssertFalse(IOSJevContextSelectionService.mustKeepSignal(toolName: "session_read", text: text).0, text)
        }
        for text in [
            "{\"has_more\": true}",
            "{\"next_cursor\": \"abc\"}",
            "TODO: revisit pagination",
            "Traceback (most recent call last): error",
        ] {
            XCTAssertTrue(IOSJevContextSelectionService.mustKeepSignal(toolName: "session_read", text: text).0, text)
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
        let transport = JevStubTransport { request in
            (self.scorePayload(for: request), self.httpResponse(status: 200))
        }
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
        let longText = LongOutputFactory.paragraphs(count: 12) + "\n\n" + "核心结论：关键信息在这里。" + String(repeating: "补充说明。", count: 400) + "\n\n" + LongOutputFactory.paragraphs(count: 12, prefix: "附录")
        let blocks = IOSJevContextSelectionService.splitBlocks(longText)
        let coreIndex = blocks.first { $0.text.contains("核心结论") }!.index
        let answers = Dictionary(uniqueKeysWithValues: blocks.map { ($0.index, $0.index == coreIndex ? 2.5 : 0.1) })
        let transport = JevStubTransport { _ in
            (self.scorePayload(Dictionary(uniqueKeysWithValues: answers.map { ("b\($0.key)", $0.value) })), self.httpResponse(status: 200))
        }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
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
        let transport = JevStubTransport { request in
            (self.scorePayload(for: request), self.httpResponse(status: 200))
        }
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

    func testFailureIsPinnedToFullTextOnLaterTurns() async {
        let calls = JevCallCounter()
        let transport = JevStubTransport { request in
            if calls.next() == 1 {
                return (Data(), self.httpResponse(status: 400))
            }
            return (self.scorePayload(for: request), self.httpResponse(status: 200))
        }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let messages = toolMessage(text: LongOutputFactory.paragraphs(count: 14))
        _ = await service.projectedMessages(messages, identity: identity())
        let later = await service.projectedMessages(messages, identity: identity(runId: "run-2"))

        XCTAssertEqual(transport.calls, 1, "a failed first judgement is fixed as full text")
        let text = ((later[2].parts.first as! UIMessagePart.Tool).output.first as! UIMessagePart.Text).text
        XCTAssertTrue(text.contains("章节0"))
        XCTAssertFalse(IOSJevContextSelectionService.containsOmissionMarker(text))
    }

    func testStableProjectionReplaysAcrossTurnsAndTaskText() async {
        IOSJevMetricsStore.clear()
        defer { IOSJevMetricsStore.clear() }
        let transport = JevStubTransport { request in
            (self.scorePayload(for: request), self.httpResponse(status: 200))
        }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let messages = toolMessage(toolCallId: "call-stable", text: LongOutputFactory.paragraphs(count: 14))
        let first = await service.projectedMessages(messages, identity: identity())
        var laterMessages = messages
        laterMessages[0] = UIMessage.companion.user(prompt: "请总结一下")
        let later = await service.projectedMessages(laterMessages, identity: identity(runId: "run-next"))

        XCTAssertEqual(transport.calls, 1, "task text and run id do not invalidate an output decision")
        let firstText = ((first[2].parts.first as! UIMessagePart.Tool).output.first as! UIMessagePart.Text).text
        let laterText = ((later[2].parts.first as! UIMessagePart.Tool).output.first as! UIMessagePart.Text).text
        XCTAssertEqual(laterText, firstText, "projection is byte-for-byte stable on the next turn")
        XCTAssertGreaterThan(IOSJevMetricsStore.runSummary(runId: "run").hiddenCharacters ?? 0, 0)
        let originalText = ((messages[2].parts.first as! UIMessagePart.Tool).output.first as! UIMessagePart.Text).text
        let summaryRecord = IOSJevMetricsStore.load().first { $0.runId == "run" && $0.outcome == "summary" }
        XCTAssertEqual(summaryRecord?.numbers?["original_characters"], Double(originalText.count))
    }

    func testConversationIdSeparatesProjectionDecisions() async {
        let calls = JevCallCounter()
        let transport = JevStubTransport { request in
            if calls.next() == 1 {
                return (Data(), self.httpResponse(status: 400))
            }
            return (self.scorePayload(for: request), self.httpResponse(status: 200))
        }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let messages = toolMessage(text: LongOutputFactory.paragraphs(count: 14))
        let firstConversation = await service.projectedMessages(messages, identity: identity(conversationId: "conversation-a"))
        let secondConversation = await service.projectedMessages(
            messages,
            identity: identity(runId: "run-b", conversationId: "conversation-b")
        )
        XCTAssertEqual(transport.calls, 2, "a full-text decision in one conversation must not carry into another")
        let firstText = ((firstConversation[2].parts.first as! UIMessagePart.Tool).output.first as! UIMessagePart.Text).text
        let secondText = ((secondConversation[2].parts.first as! UIMessagePart.Tool).output.first as! UIMessagePart.Text).text
        XCTAssertFalse(IOSJevContextSelectionService.containsOmissionMarker(firstText))
        XCTAssertTrue(IOSJevContextSelectionService.containsOmissionMarker(secondText))
    }

    func testOlderDecisionReplaysAfterNewLongOutputArrives() async {
        let transport = JevStubTransport { request in
            (self.scorePayload(for: request), self.httpResponse(status: 200))
        }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let original = toolMessage(toolCallId: "call-old", text: LongOutputFactory.paragraphs(count: 14))
        let first = await service.projectedMessages(original, identity: identity())
        let combined = appendingToolMessage(
            to: original,
            toolCallId: "call-new",
            text: LongOutputFactory.paragraphs(count: 14, prefix: "新段落"),
            prompt: "继续检索"
        )
        let next = await service.projectedMessages(combined, identity: identity(runId: "run-new"))

        XCTAssertEqual(transport.calls, 2, "the older output replays; only the new output needs another decision")
        let firstOldText = ((first[2].parts.first as! UIMessagePart.Tool).output.first as! UIMessagePart.Text).text
        let nextOldText = ((next[2].parts.first as! UIMessagePart.Tool).output.first as! UIMessagePart.Text).text
        XCTAssertEqual(nextOldText, firstOldText)
        let requestState = String(data: transport.lastBody!, encoding: .utf8)!
        XCTAssertTrue(requestState.contains("新段落0"))
        XCTAssertFalse(requestState.contains("章节0"), "the previously decided output is not sent again")
    }

    func testDuplicateOutputIdentityUsesOneUniqueQuestionSet() async {
        let transport = JevStubTransport { request in
            (self.scorePayload(for: request), self.httpResponse(status: 200))
        }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let text = LongOutputFactory.paragraphs(count: 14)
        let original = toolMessage(toolCallId: "call-duplicate", text: text)
        let duplicated = appendingToolMessage(
            to: original,
            toolCallId: "call-duplicate",
            text: text,
            prompt: "再次读取"
        )
        let projected = await service.projectedMessages(duplicated, identity: identity())

        XCTAssertEqual(transport.calls, 1, "identical decision keys are evaluated once")
        let body = try! JSONSerialization.jsonObject(with: transport.lastBody!) as! [String: Any]
        let questionIds = Array((body["questions"] as! [String: Any]).keys)
        XCTAssertEqual(questionIds.count, Set(questionIds).count)
        for messageIndex in [2, 5] {
            let text = ((projected[messageIndex].parts.first as! UIMessagePart.Tool).output.first as! UIMessagePart.Text).text
            XCTAssertTrue(IOSJevContextSelectionService.containsOmissionMarker(text))
        }
    }

    func testActiveHistoryKeysAreNeverEvictedPastDecisionCapacity() async {
        var settings = makeSettings(mode: .active)
        settings.policy.cacheMaxEntries = 1
        let transport = JevStubTransport { request in
            (self.scorePayload(for: request), self.httpResponse(status: 200))
        }
        let service = makeService(settings: settings, transport: transport)
        var messages = toolMessage(toolCallId: "call-a", text: LongOutputFactory.paragraphs(count: 14, prefix: "A"))
        messages = appendingToolMessage(to: messages, toolCallId: "call-b", text: LongOutputFactory.paragraphs(count: 14, prefix: "B"), prompt: "继续")
        messages = appendingToolMessage(to: messages, toolCallId: "call-c", text: LongOutputFactory.paragraphs(count: 14, prefix: "C"), prompt: "继续")

        let first = await service.projectedMessages(messages, identity: identity())
        let repeated = await service.projectedMessages(messages, identity: identity(runId: "run-repeat"))
        let withNewOutput = appendingToolMessage(to: messages, toolCallId: "call-d", text: LongOutputFactory.paragraphs(count: 14, prefix: "D"), prompt: "继续")
        let later = await service.projectedMessages(withNewOutput, identity: identity(runId: "run-later"))

        XCTAssertEqual(transport.calls, 1, "overflow outputs are pinned to full text and never re-evaluated")
        for index in [2, 5, 8] {
            let firstText = ((first[index].parts.first as! UIMessagePart.Tool).output.first as! UIMessagePart.Text).text
            let repeatedText = ((repeated[index].parts.first as! UIMessagePart.Tool).output.first as! UIMessagePart.Text).text
            let laterText = ((later[index].parts.first as! UIMessagePart.Tool).output.first as! UIMessagePart.Text).text
            XCTAssertEqual(repeatedText, firstText)
            XCTAssertEqual(laterText, firstText)
        }
        let newText = ((later[11].parts.first as! UIMessagePart.Tool).output.first as! UIMessagePart.Text).text
        XCTAssertTrue(newText.contains("D0"), "new outputs beyond capacity stay complete")
    }

    func testMissingConversationIdKeepsOriginalWithoutNetwork() async {
        let transport = JevStubTransport { _ in (self.scorePayload(["b0": 0.1]), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let messages = toolMessage(text: LongOutputFactory.paragraphs(count: 14))
        let projected = await service.projectedMessages(messages, identity: identity(conversationId: nil))
        XCTAssertEqual(transport.calls, 0)
        XCTAssertEqual(((projected[2].parts.first as! UIMessagePart.Tool).output.first as! UIMessagePart.Text).text,
                       ((messages[2].parts.first as! UIMessagePart.Tool).output.first as! UIMessagePart.Text).text)
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
        cases.append(("pagination", LongOutputFactory.paragraphs(count: 12) + "\n\n{\"next_offset\": 60}", true))
        cases.append(("approval", "{\"needs_approval\": true}\n" + LongOutputFactory.paragraphs(count: 12), true))
        cases.append(("code_block", "```json\n{\"pagination\": {\"next_page\": 3}}\n```\n" + LongOutputFactory.paragraphs(count: 12), true))
        for _ in 0..<5 {
            cases.append(("log_tail", "ERROR: timeout\n" + LongOutputFactory.paragraphs(count: 12) + "\n\n{\"needs_approval\": true}", true))
        }
        XCTAssertEqual(cases.count, 20, "sample registry intact")
        for (name, text, expectMustKeep) in cases {
            let blocks = IOSJevContextSelectionService.splitBlocks(text)
            let anyKeep = blocks.contains { IOSJevContextSelectionService.mustKeepSignal(toolName: "scrape_web", text: $0.text).0 }
            XCTAssertEqual(anyKeep, expectMustKeep, "case \(name) must-keep expectation mismatch")
        }
    }

    // MARK: 长文档采样（状态字节上限）

    /// 每块约 1,800 字；题数封顶时在整篇文档上均匀取样，避免尾部永远未评估。
    func testQuestionSamplingCoversTailWithinStateBudget() async {
        let transport = JevStubTransport { request in
            (self.scorePayload(for: request), self.httpResponse(status: 200))
        }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let text = (0..<40).map { "段落\($0)标记：" + String(repeating: "内容", count: 900) }
            .joined(separator: "\n\n")
        let messages = toolMessage(toolCallId: "call-cap", text: text)
        let projected = await service.projectedMessages(messages, identity: identity())

        let body = try! JSONSerialization.jsonObject(with: transport.lastBody!) as! [String: Any]
        let questions = body["questions"] as! [String: Any]
        let questionCount = questions.count
        XCTAssertLessThanOrEqual(questionCount, IOSJevSettings().policy.maxCandidates)
        XCTAssertLessThanOrEqual((body["state"] as! String).utf8.count, IOSJevSettings().policy.maxStateBytes)
        XCTAssertTrue(questions.keys.contains("single.b39"), "the final output block should be included in the evaluation")

        let projectedText = ((projected[2].parts.first as! UIMessagePart.Tool).output.first as! UIMessagePart.Text).text
        XCTAssertTrue(IOSJevContextSelectionService.containsOmissionMarker(projectedText))
        XCTAssertFalse(projectedText.contains("段落39标记"), "the tail block can be hidden after evaluation")
        XCTAssertTrue(projectedText.contains("段落2标记"), "unselected blocks remain verbatim")
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
