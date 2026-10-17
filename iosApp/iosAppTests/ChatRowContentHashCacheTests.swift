import XCTest
import Shared
@testable import iosApp

/// Cache hits must preserve the complete displayed snapshot, including same-size
/// tool output replacements and mutable metadata. Completed tool parts should be
/// reused when a later part of the same assistant message changes.
final class ChatRowContentHashCacheTests: XCTestCase {

    private func makeRow(
        message: UIMessage,
        isLast: Bool = false,
        isStreaming: Bool = false
    ) -> ChatMessageRowModel {
        let messageId = ChatMessageProjector.messageId(for: message)
        return ChatMessageRowModel(
            rowId: messageId,
            messageId: messageId,
            message: message,
            role: message.role,
            parts: message.parts,
            index: 0,
            isLast: isLast,
            isStreaming: isStreaming,
            hasEverStreamed: isStreaming,
            canAnimateInsertion: false
        )
    }

    private func makeToolMessage(id: KotlinUuid, outputEmpty: Bool) -> UIMessage {
        let toolPart = UIMessagePart.Tool(
            toolCallId: "tool-1",
            toolName: "search_web",
            input: "{\"query\":\"x\"}",
            output: outputEmpty ? [] : [UIMessagePart.Text(text: "结果", metadata: nil)],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        return UIMessage(
            id: id,
            role: MessageRole.assistant,
            parts: [toolPart],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    /// Historical rows also accept replacement snapshots, including text edits.
    func testHistoricalReplacementSnapshotInvalidatesCachedHash() {
        let cache = ChatRowContentHashCache()
        let id = KotlinUuid.companion.random()
        let original = makeTextMessage(id: id, text: "原始文本")
        let mutated = makeTextMessage(id: id, text: "被原地改掉的文本")

        let first = cache.contentHash(for: makeRow(message: original))
        let second = cache.contentHash(for: makeRow(message: mutated))
        XCTAssertNotEqual(first, second, "相同消息 id 的新内容快照必须使缓存失效")

        let fresh = ChatRowContentHashCache().contentHash(for: makeRow(message: mutated))
        XCTAssertEqual(second, fresh)
    }

    func testCompletedToolOutputReplacementWithSameCountInvalidatesHistoryAndTail() {
        let cache = ChatRowContentHashCache()
        let id = KotlinUuid.companion.random()
        func message(_ output: String) -> UIMessage {
            UIMessage(id: id, role: MessageRole.assistant, parts: [UIMessagePart.Tool(
                toolCallId: "ssh-1", toolName: "terminal_execute", input: "{}",
                output: [UIMessagePart.Text(text: output, metadata: nil)],
                approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
            )], annotations: [], createdAt: chatNowLocalDateTime(), finishedAt: nil,
            modelId: nil, usage: nil, translation: nil)
        }
        let running = message(#"{"status":"running","stdout":"before"}"#)
        let finished = message(#"{"status":"completed","stdout":"after!"}"#)
        for isLast in [false, true] {
            XCTAssertNotEqual(
                cache.contentHash(for: makeRow(message: running, isLast: isLast)),
                cache.contentHash(for: makeRow(message: finished, isLast: isLast))
            )
        }
    }

    func testToolDenseTailOnlyRehashesTheChangedPart() {
        let cache = ChatRowContentHashCache()
        let id = KotlinUuid.companion.random()
        let tools: [UIMessagePart] = (0..<120).map { index in
            UIMessagePart.Tool(toolCallId: "ssh-\(index)", toolName: "terminal_execute", input: "{}",
                output: [UIMessagePart.Text(text: String(repeating: "output ", count: 1_700), metadata: nil)],
                approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)
        }
        func row(_ parts: [UIMessagePart]) -> ChatMessageRowModel {
            makeRow(message: UIMessage(id: id, role: MessageRole.assistant, parts: parts,
                annotations: [], createdAt: chatNowLocalDateTime(), finishedAt: nil,
                modelId: nil, usage: nil, translation: nil), isLast: true)
        }
        _ = cache.contentHash(for: row(tools))
        XCTAssertEqual(cache.partHashComputationCount, 120)
        var parts = tools
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for index in 0..<30 {
            parts = tools + [UIMessagePart.Text(text: "继续 \(index)", metadata: nil)]
            _ = cache.contentHash(for: row(parts))
        }
        let milliseconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
        XCTAssertEqual(cache.partHashComputationCount, 150, "120 个历史工具不应随每次尾部更新重新序列化")
        print("[PERF-TOOLS] 120 tools / 30 tail updates: \(milliseconds)ms CPU; rehashed=30, full-rescan=3630")
        let output = (tools[40] as! UIMessagePart.Tool).output[0] as! UIMessagePart.Text
        output.metadata = [:]
        let beforeMetadata = cache.partHashComputationCount
        _ = cache.contentHash(for: row(parts))
        XCTAssertEqual(cache.partHashComputationCount, beforeMetadata + 1, "相同 Tool 实例中的嵌套 metadata 也必须失效")
    }

    private func makeTextMessage(id: KotlinUuid, text: String) -> UIMessage {
        UIMessage(
            id: id,
            role: MessageRole.assistant,
            parts: [UIMessagePart.Text(text: text, metadata: nil)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    /// 契约 2:tool output 空 -> 非空(已知的原地变更路径)必须让指纹变化,
    /// 从而触发重算,而不是错误地复用旧的"空输出"哈希。
    func testToolOutputBackfillChangesHash() {
        let cache = ChatRowContentHashCache()
        let messageId = KotlinUuid.companion.random()

        let pendingMessage = makeToolMessage(id: messageId, outputEmpty: true)
        let pendingRow = makeRow(message: pendingMessage, isLast: false, isStreaming: false)
        let hashBeforeBackfill = cache.contentHash(for: pendingRow)

        let completedMessage = makeToolMessage(id: messageId, outputEmpty: false)
        let completedRow = makeRow(message: completedMessage, isLast: false, isStreaming: false)
        let hashAfterBackfill = cache.contentHash(for: completedRow)

        XCTAssertNotEqual(
            hashBeforeBackfill,
            hashAfterBackfill,
            "tool output 从空回填为非空后,parts.count 不变但内容确实变了,指纹必须跟着变化"
        )
    }

    /// Live and terminal replacements must both invalidate the tail hash.
    func testLastRowReplacementInvalidatesHash() {
        let cache = ChatRowContentHashCache()
        let messageId = KotlinUuid.companion.random()

        func message(text: String) -> UIMessage {
            UIMessage(
                id: messageId,
                role: MessageRole.assistant,
                parts: [UIMessagePart.Text(text: text, metadata: nil)],
                annotations: [],
                createdAt: chatNowLocalDateTime(),
                finishedAt: nil,
                modelId: nil,
                usage: nil,
                translation: nil
            )
        }

        let streamingRowV1 = makeRow(message: message(text: "流式增量 1"), isLast: true, isStreaming: true)
        let hashV1 = cache.contentHash(for: streamingRowV1)

        let streamingRowV2 = makeRow(message: message(text: "流式增量 1 又追加了更多文字"), isLast: true, isStreaming: true)
        let hashV2 = cache.contentHash(for: streamingRowV2)

        XCTAssertNotEqual(
            hashV1,
            hashV2,
            "新内容快照必须使尾行缓存失效"
        )
    }

    func testStreamingTailLayoutTokenChangesWithAppendedText() {
        let cache = ChatRowContentHashCache()
        let messageId = KotlinUuid.companion.random()

        func message(text: String) -> UIMessage {
            UIMessage(
                id: messageId,
                role: MessageRole.assistant,
                parts: [UIMessagePart.Text(text: text, metadata: nil)],
                annotations: [],
                createdAt: chatNowLocalDateTime(),
                finishedAt: nil,
                modelId: nil,
                usage: nil,
                translation: nil
            )
        }

        let first = makeRow(message: message(text: "正在生成"), isLast: true, isStreaming: true)
        let second = makeRow(message: message(text: "正在生成更长的内容"), isLast: true, isStreaming: true)

        XCTAssertNotEqual(
            cache.streamingTailLayoutToken(for: first),
            cache.streamingTailLayoutToken(for: second)
        )
    }

    func testSuspendedStreamingTailLayoutTokenIgnoresInvisibleTextGrowth() {
        let cache = ChatRowContentHashCache()
        let messageId = KotlinUuid.companion.random()
        let first = makeRow(
            message: makeTextMessage(id: messageId, text: "正在生成"),
            isLast: true,
            isStreaming: true
        )
        let second = makeRow(
            message: makeTextMessage(id: messageId, text: "正在生成更长且当前不可见的内容"),
            isLast: true,
            isStreaming: true
        )

        XCTAssertEqual(
            cache.suspendedStreamingTailLayoutToken(for: first),
            cache.suspendedStreamingTailLayoutToken(for: second),
            "用户查看历史时，不可见流式尾行不应被每个文本 delta 反复失效。"
        )
        XCTAssertNotEqual(
            cache.streamingTailLayoutToken(for: first),
            cache.streamingTailLayoutToken(for: second),
            "恢复可见后仍需用实时 token 接收最新累计全文。"
        )
    }

    func testStreamingTailLayoutTokenChangesWhenCitationArrivesWithoutTextDelta() {
        let cache = ChatRowContentHashCache()
        let messageId = KotlinUuid.companion.random()
        let base = makeTextMessage(id: messageId, text: "带来源的回答")
        let cited = UIMessage(
            id: messageId,
            role: base.role,
            parts: base.parts,
            annotations: [UIMessageAnnotation.UrlCitation(title: "来源", url: "https://example.com")],
            createdAt: base.createdAt,
            finishedAt: base.finishedAt,
            modelId: base.modelId,
            usage: base.usage,
            translation: base.translation
        )

        XCTAssertNotEqual(
            cache.streamingTailLayoutToken(for: makeRow(message: base, isLast: true, isStreaming: true)),
            cache.streamingTailLayoutToken(for: makeRow(message: cited, isLast: true, isStreaming: true)),
            "Late citation annotations are visible rows and must invalidate the equatable bubble."
        )
    }

    func testStreamingTailLayoutTokenChangesWithToolInputAndOutputContent() {
        let cache = ChatRowContentHashCache()
        let messageId = KotlinUuid.companion.random()

        func message(input: String, output: String) -> UIMessage {
            UIMessage(
                id: messageId,
                role: MessageRole.assistant,
                parts: [UIMessagePart.Tool(
                    toolCallId: "tool-1",
                    toolName: "search_web",
                    input: input,
                    output: output.isEmpty ? [] : [UIMessagePart.Text(text: output, metadata: nil)],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                )],
                annotations: [],
                createdAt: chatNowLocalDateTime(),
                finishedAt: nil,
                modelId: nil,
                usage: nil,
                translation: nil
            )
        }

        let partialInput = makeRow(message: message(input: #"{"query":"sw"}"#, output: ""), isLast: true, isStreaming: true)
        let completeInput = makeRow(message: message(input: #"{"query":"swift"}"#, output: ""), isLast: true, isStreaming: true)
        XCTAssertNotEqual(
            cache.streamingTailLayoutToken(for: partialInput),
            cache.streamingTailLayoutToken(for: completeInput)
        )

        let firstOutput = makeRow(message: message(input: #"{"query":"swift"}"#, output: "结果 A"), isLast: true, isStreaming: true)
        let changedOutput = makeRow(message: message(input: #"{"query":"swift"}"#, output: "结果 B"), isLast: true, isStreaming: true)
        XCTAssertNotEqual(
            cache.streamingTailLayoutToken(for: firstOutput),
            cache.streamingTailLayoutToken(for: changedOutput)
        )
    }

    func testSwiftUICleanListKeepsHistoricalStreamedRowsOnStreamingRenderer() {
        let message = makeTextMessage(id: KotlinUuid.companion.random(), text: "已完成的流式 Markdown")
        let streamedHistory = makeRow(message: message, isLast: false, isStreaming: false)
        let row = ChatMessageRowModel(
            rowId: streamedHistory.rowId,
            messageId: streamedHistory.messageId,
            message: streamedHistory.message,
            role: streamedHistory.role,
            parts: streamedHistory.parts,
            index: streamedHistory.index,
            isLast: false,
            isStreaming: false,
            hasEverStreamed: true,
            canAnimateInsertion: false
        )

        let state = ChatSwiftUICleanListRenderPolicy.nonLiveTailState(for: row)

        XCTAssertEqual(state?.rendererMode, .streamingMarkdown)
        XCTAssertEqual(state?.hasEverStreamed, true)
        XCTAssertEqual(state?.liveRenderingEnabled, true)
        XCTAssertNil(state?.frozenMarkdownSnapshot)
    }

    func testSwiftUICleanListKeepsLiveTailRendererStableWhileUpdatesAreSuspended() {
        let row = makeRow(
            message: makeTextMessage(id: KotlinUuid.companion.random(), text: "正在流式生成"),
            isLast: true,
            isStreaming: true
        )

        let state = ChatSwiftUICleanListRenderPolicy.liveTailState(for: row)

        XCTAssertEqual(state?.rendererMode, .streamingMarkdown)
        XCTAssertEqual(state?.hasEverStreamed, true)
        XCTAssertEqual(state?.liveRenderingEnabled, true)
        XCTAssertNil(state?.frozenMarkdownSnapshot)
    }

    func testSwiftUICleanListRowsUseDigestEquatableWrapper() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testDirectory.deletingLastPathComponent().appendingPathComponent("iosApp")
        let source = try String(
            contentsOf: appDirectory.appendingPathComponent("ChatCollectionMessageList.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("private struct ChatSwiftUIMessageBubble: View, @MainActor Equatable"),
            "Default SwiftUI clean-list rows must have their own Equatable wrapper; native-only row gating does not protect the default path."
        )
        XCTAssertTrue(
            source.contains("ChatSwiftUIMessageBubble(") && source.contains(".equatable()"),
            "ChatSwiftUIMessageList.messageRow should render through the Equatable wrapper."
        )
        XCTAssertTrue(
            source.contains("@State private var swiftUIContentHashCache = ChatRowContentHashCache()") &&
                source.contains("@State private var swiftUIRenderStateStore = ChatRenderStateStore()") &&
                source.contains("ChatRowDigests.digest("),
            "Default SwiftUI rows must use the shared digest/content-hash gate instead of comparing full UIMessage values."
        )
        XCTAssertTrue(
            source.contains("ChatSwiftUIStreamingTailRenderPolicy.shouldSuspend(") &&
                source.contains("isLastAssistant: row.isLast && row.role == MessageRole.assistant") &&
                source.contains("hasEverStreamed: row.hasEverStreamed") &&
                source.contains("swiftUIContentHashCache.suspendedStreamingTailLayoutToken(for: row)") &&
                source.contains("proxy.bounds(of: .scrollView)"),
            "The default clean-list may suspend streaming-tail invalidation only after that tail row is confirmed offscreen."
        )
        XCTAssertTrue(
            source.contains("if lhs.updatesSuspended") &&
                source.contains("lhs.updatesSuspended == rhs.updatesSuspended"),
            "Streaming deltas must keep a confirmed-offscreen tail bubble stable until it becomes visible."
        )
        XCTAssertFalse(
            source.contains("row.isStreaming && viewportState.liveRenderingFarFromBottom"),
            "Distance-to-bottom is not proof that a very tall streaming tail is invisible."
        )
    }
}

/// Task C contract: row/part signatures are bounded (never stringify base64 tool
/// payloads) yet still change whenever height-affecting tool content changes.
final class ChatPartSignatureTests: XCTestCase {
    private func row(_ parts: [UIMessagePart], id: KotlinUuid = KotlinUuid.companion.random()) -> ChatMessageRowModel {
        let message = UIMessage(id: id, role: MessageRole.assistant, parts: parts, annotations: [],
            createdAt: chatNowLocalDateTime(), finishedAt: nil, modelId: nil, usage: nil, translation: nil)
        let messageId = ChatMessageProjector.messageId(for: message)
        return ChatMessageRowModel(rowId: messageId, messageId: messageId, message: message, role: message.role,
            parts: message.parts, index: 0, isLast: true, isStreaming: false, hasEverStreamed: false,
            canAnimateInsertion: false)
    }

    private func base64Payload(seed: Int, length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var generator = seed &* 2_654_435_761 | 1
        var characters = [Character]()
        characters.reserveCapacity(length)
        for _ in 0..<length {
            generator = generator &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            characters.append(alphabet[Int((UInt64(bitPattern: Int64(generator)) >> 33) % 64)])
        }
        return "data:image/png;base64," + String(characters)
    }

    private func phoneTool(
        _ id: String,
        output: [UIMessagePart],
        approval: ToolApprovalState = ToolApprovalState.Auto.shared,
        input: String = #"{"action":"tap","ref":"r1"}"#
    ) -> UIMessagePart.Tool {
        UIMessagePart.Tool(toolCallId: id, toolName: "phone_act", input: input, output: output,
            approvalState: approval, streamIndex: nil, metadata: nil)
    }

    private func cpuMilliseconds(_ body: () -> Void) -> Double {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        body()
        return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
    }

    /// ~20 MB of screenshots (the verified automation-conversation size) must not be
    /// stringified, bridged in full or hashed in full on conversation open.
    func testHugeScreenshotOutputsAreNotStringifiedWhenSigning() {
        let payload = base64Payload(seed: 1, length: 200_000)
        let tools: [UIMessagePart] = (0..<100).map { index in
            phoneTool("phone-\(index)", output: [
                UIMessagePart.Text(text: #"{"outcome":"completed","fresh_observation_available":true}"#, metadata: nil),
                UIMessagePart.Image(url: payload, metadata: nil)
            ])
        }
        let fullRow = row(tools)

        let legacySample = Array(tools.prefix(5))
        let legacyMs = cpuMilliseconds {
            var hasher = Hasher()
            for part in legacySample { hasher.combine(String(describing: part)) }
            _ = hasher.finalize()
        }

        let cache = ChatRowContentHashCache()
        var hash = 0
        let contentMs = cpuMilliseconds { hash = cache.contentHash(for: fullRow) }
        let tailMs = cpuMilliseconds { _ = ChatRowContentHashCache().streamingTailLayoutToken(for: fullRow) }
        let planMs = cpuMilliseconds {
            _ = ChatTimelinePlanner.build(messages: [fullRow.message], event: .conversationLoaded)
        }
        print("[PERF-SIGNATURE] 100 tools x 200KB: content=\(contentMs)ms tail=\(tailMs)ms plan=\(planMs)ms; legacy toString for 5 tools=\(legacyMs)ms")

        XCTAssertNotEqual(hash, 0)
        XCTAssertEqual(cache.partHashComputationCount, 100)
        // Signing all 100 tools must be cheaper than stringifying just 5 of them.
        XCTAssertLessThan(contentMs, legacyMs, "content hash must not scale with base64 payload size")
        XCTAssertLessThan(tailMs, legacyMs, "streaming tail token must not scale with base64 payload size")
        XCTAssertLessThan(planMs, legacyMs, "render tokens must not walk base64 graphemes")
        XCTAssertLessThan(contentMs, 250, "bounded signing of 20 MB of screenshots")
    }

    func testToolSignatureChangesWithHeightAffectingContentAndIsStableForIdenticalContent() {
        func hash(_ part: UIMessagePart) -> Int {
            ChatRowContentHashCache().contentHash(for: row([part], id: KotlinUuid.companion.random()))
        }
        func partHash(_ part: UIMessagePart) -> Int { ChatPartSignature.hash(part, exactText: true) }

        let pending = phoneTool("p1", output: [])
        let completed = phoneTool("p1", output: [UIMessagePart.Text(text: #"{"status":"success"}"#, metadata: nil)])
        let failedSameLength = phoneTool("p1", output: [UIMessagePart.Text(text: #"{"status":"failed_"}"#, metadata: nil)])
        XCTAssertNotEqual(partHash(pending), partHash(completed), "output arriving changes the signature")
        XCTAssertNotEqual(partHash(completed), partHash(failedSameLength), "same-length status change must invalidate")

        let awaiting = phoneTool("p1", output: [], approval: ToolApprovalState.Pending.shared)
        XCTAssertNotEqual(partHash(pending), partHash(awaiting), "approval state changes the signature")

        let longError = String(repeating: "e", count: 9_000)
        let errorA = phoneTool("p1", output: [UIMessagePart.Text(text: longError + "A", metadata: nil)])
        let errorB = phoneTool("p1", output: [UIMessagePart.Text(text: longError + "B", metadata: nil)])
        XCTAssertNotEqual(partHash(errorA), partHash(errorB), "large error text change at the tail is detected")

        let shotA = phoneTool("p1", output: [UIMessagePart.Image(url: base64Payload(seed: 7, length: 150_000), metadata: nil)])
        let shotB = phoneTool("p1", output: [UIMessagePart.Image(url: base64Payload(seed: 8, length: 150_000), metadata: nil)])
        XCTAssertNotEqual(partHash(shotA), partHash(shotB), "same-size screenshots with different bytes differ")

        // Two separately constructed snapshots of the same content sign equally.
        let shotACopy = phoneTool("p1", output: [UIMessagePart.Image(url: base64Payload(seed: 7, length: 150_000), metadata: nil)])
        XCTAssertEqual(partHash(shotA), partHash(shotACopy))
        XCTAssertEqual(partHash(completed), partHash(
            phoneTool("p1", output: [UIMessagePart.Text(text: #"{"status":"success"}"#, metadata: nil)])))

        // Same message id, replacement snapshots through the row cache.
        let cache = ChatRowContentHashCache()
        let id = KotlinUuid.companion.random()
        let first = cache.contentHash(for: row([pending], id: id))
        let second = cache.contentHash(for: row([completed], id: id))
        let third = cache.contentHash(for: row([phoneTool("p1", output: [
            UIMessagePart.Text(text: #"{"status":"success"}"#, metadata: nil)])], id: id))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second, third, "identical content must keep the row hash (no spurious relayout)")
        XCTAssertNotEqual(hash(pending), hash(completed))
    }

    /// Tool output text is exact up to 64 KB (same-length mid-text change detected);
    /// beyond that, and for media/base64, it is sampled with bounded work.
    func testToolOutputTextIsExactUpToLimitAndSampledBeyond() {
        func tool(_ text: String) -> UIMessagePart.Tool {
            phoneTool("t", output: [UIMessagePart.Text(text: text, metadata: nil)])
        }
        let half = String(repeating: "o", count: 15_000)
        XCTAssertNotEqual(ChatPartSignature.hash(tool(half + "1" + half), exactText: false),
                          ChatPartSignature.hash(tool(half + "2" + half), exactText: false),
                          "30 KB tool text: same-length change in the middle must invalidate")
        let huge = String(repeating: "x", count: 400_000)
        var tailHasher = Hasher()
        let sampledMs = cpuMilliseconds {
            ChatPartSignature.combineText(huge, into: &tailHasher)
        }
        XCTAssertLessThan(sampledMs, 5, "texts above 64 KB are sampled")
        XCTAssertNotEqual(ChatPartSignature.hash(tool(huge + "a"), exactText: false),
                          ChatPartSignature.hash(tool(huge + "b"), exactText: false))
        // `data:` payloads embedded as text are treated as media (sampled), not hashed in full.
        let payload = base64Payload(seed: 3, length: 50_000)
        XCTAssertNotEqual(ChatPartSignature.hash(tool(payload), exactText: false),
                          ChatPartSignature.hash(tool(base64Payload(seed: 4, length: 50_000)), exactText: false))
    }

    /// Top-level message text keeps exact hashing: a same-length edit in the middle of
    /// a long message must still invalidate.
    func testTopLevelTextKeepsExactSignatureForSameLengthEdits() {
        let prefix = String(repeating: "a", count: 5_000)
        let suffix = String(repeating: "b", count: 5_000)
        let lhs = UIMessagePart.Text(text: prefix + "X" + suffix, metadata: nil)
        let rhs = UIMessagePart.Text(text: prefix + "Y" + suffix, metadata: nil)
        XCTAssertNotEqual(ChatPartSignature.hash(lhs, exactText: true), ChatPartSignature.hash(rhs, exactText: true))
    }

    /// prior_tool_receipt.result is parsed once per output snapshot, not per step model.
    func testPriorToolReceiptParseIsMemoizedInAnalysis() throws {
        let output = UIMessagePart.Text(text:
            #"{"status":"handback","prior_tool_receipt":{"kind":"filled","result":"{\"steps\":[\"open: completed\"]}"}}"#,
            metadata: nil)
        let tool = UIMessagePart.Tool(toolCallId: "prior-1", toolName: "phone_run_goal", input: "{}",
            output: [output], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)
        let analysis = ChatToolOutputFormatter.analysis(for: tool)
        XCTAssertEqual(analysis.priorToolReceipt?["kind"] as? String, "filled")
        XCTAssertEqual((analysis.priorToolReceiptResult?["steps"] as? [String])?.first, "open: completed")
        XCTAssertTrue(ChatToolOutputFormatter.analysis(for: tool) === analysis)
        let first = ChatPhoneToolPresentation.cached(toolName: tool.toolName, executed: true, analysis: analysis)
        let second = ChatPhoneToolPresentation.cached(toolName: tool.toolName, executed: true, analysis: analysis)
        XCTAssertEqual(first.summary, second.summary)
        XCTAssertEqual(ChatToolStepModel(tool: tool).detail, first.summary)
    }
}
