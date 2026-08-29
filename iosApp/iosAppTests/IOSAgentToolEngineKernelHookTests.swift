import XCTest
@testable import iosApp
import Shared

/// P0-2 B1: engine kernel-hook tests.
///
/// Pins the non-default hook behavior used by `ChatRunKernelAdapter`.
final class IOSAgentToolEngineKernelHookTests: XCTestCase {

    private typealias F = IOSChatForegroundFixtures

    /// Scripted provider that also records the exact `messages` array uploaded
    /// on every provider round — the hook assertions read "what the model saw"
    /// from here rather than from the returned transcript.
    private final class UploadRecordingProvider: IOSAgentTextProvider, @unchecked Sendable {
        private var script: [UIMessage]
        private(set) var uploads: [[UIMessage]] = []
        init(_ script: [UIMessage]) { self.script = script }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            uploads.append(messages)
            if !script.isEmpty {
                return F.chunk(with: script.removeFirst())
            }
            return F.chunk(with: F.assistantText("stop"))
        }
    }

    /// Executor that echoes `ok:<name>` and records invocation order.
    private final class OrderRecordingExecutor: IOSToolExecutor, @unchecked Sendable {
        private(set) var invocations: [String] = []
        func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
            invocations.append(name)
            return .filled("{\"ok\":true,\"tool\":\"\(name)\"}")
        }
    }

    /// String recorder safe to capture from `@Sendable` hook closures under
    /// Swift 6 strict concurrency (tests are single-threaded in practice).
    private final class EventRecorder: @unchecked Sendable {
        private(set) var values: [String] = []
        func append(_ value: String) { values.append(value) }
        var count: Int { values.count }
    }

    private func makeToolMessage(toolCallId: String, toolName: String) -> UIMessage {
        F.assistantMessage(parts: [UIMessagePart.Tool(
            toolCallId: toolCallId,
            toolName: toolName,
            input: "{}",
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )])
    }

    // MARK: - prepareRequestMessages

    func testPrepareRequestMessagesAppliesEveryRoundWithoutTouchingCanonicalTranscript() async {
        // Two rounds: tool call, then final text. The hook appends a marker
        // user message to the REQUEST only — the model must see it on both
        // rounds, and the returned transcript must stay free of it.
        let provider = UploadRecordingProvider([
            makeToolMessage(toolCallId: "tc-1", toolName: "echo"),
            F.assistantText("done")
        ])
        let executor = OrderRecordingExecutor()
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["echo": executor],
            configuration: .init(maxSteps: 4)
        )

        let hookCalls = EventRecorder()
        let result = await engine.run(
            providerSetting: F.makeProviderSetting(),
            messages: [F.userMessage("hi")],
            params: F.makeParams(toolNames: ["echo"]),
            prepareRequestMessages: { messages in
                hookCalls.append("call")
                return messages + [F.userMessage("runtime-context-\(hookCalls.count)")]
            }
        )

        XCTAssertEqual(hookCalls.count, 2, "hook must fire before every provider round")
        XCTAssertEqual(provider.uploads.count, 2)
        // Round 1 upload: original user message + marker.
        XCTAssertEqual(provider.uploads[0].count, 2)
        XCTAssertTrue(F.toolOutputText(toolCallId: "tc-1", in: result.messages).contains("\"tool\":\"echo\""))
        // Round 2 upload must contain the tool output AND a fresh marker.
        let round2Texts = provider.uploads[1].flatMap { $0.parts }.compactMap { ($0 as? UIMessagePart.Text)?.text }
        XCTAssertTrue(round2Texts.contains("runtime-context-2"), "round-2 upload should carry a fresh marker")
        // Canonical transcript: no marker anywhere, tool output filled in place.
        let resultTexts = result.messages.flatMap { $0.parts }.compactMap { ($0 as? UIMessagePart.Text)?.text }
        XCTAssertFalse(resultTexts.contains { $0.hasPrefix("runtime-context-") },
                       "request-only transform must not leak into the canonical transcript")
        XCTAssertEqual(result.stepsExecuted, 2)
    }

    // MARK: - drainSteer

    func testDrainSteerFiresAfterMailboxAndFoldsIntoNextRoundUpload() async {
        let provider = UploadRecordingProvider([
            makeToolMessage(toolCallId: "tc-1", toolName: "echo"),
            F.assistantText("done")
        ])
        let executor = OrderRecordingExecutor()
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["echo": executor],
            configuration: .init(maxSteps: 4)
        )

        let drainOrder = EventRecorder()
        let result = await engine.run(
            providerSetting: F.makeProviderSetting(),
            messages: [F.userMessage("hi")],
            params: F.makeParams(toolNames: ["echo"]),
            mailboxDrain: {
                drainOrder.append("mailbox")
                return IOSMailboxDrainResult(values: [F.userMessage("mailbox-envelope")])
            },
            drainSteer: {
                drainOrder.append("steer")
                return [F.userMessage("steer-note")]
            }
        )

        XCTAssertEqual(drainOrder.values, ["mailbox", "steer"],
                       "round-boundary consumption order must be mailbox first, then steer (CGC parity)")
        XCTAssertEqual(provider.uploads.count, 2)
        let round2Texts = provider.uploads[1].flatMap { $0.parts }.compactMap { ($0 as? UIMessagePart.Text)?.text }
        guard let mailboxIndex = round2Texts.firstIndex(of: "mailbox-envelope"),
              let steerIndex = round2Texts.firstIndex(of: "steer-note") else {
            return XCTFail("round-2 upload must fold in both mailbox and steer messages, got \(round2Texts)")
        }
        XCTAssertLessThan(mailboxIndex, steerIndex, "mailbox content precedes steer content in the upload")
        // Both are canonical (unlike prepareRequestMessages): they persist.
        let resultTexts = result.messages.flatMap { $0.parts }.compactMap { ($0 as? UIMessagePart.Text)?.text }
        XCTAssertTrue(resultTexts.contains("mailbox-envelope"))
        XCTAssertTrue(resultTexts.contains("steer-note"))
    }

    // MARK: - sortPendingToolCalls

    func testSortPendingToolCallsReordersBatchExecutionButFillsOutputsInPlace() async {
        // One assistant turn carrying TWO tool calls in model order [A, B].
        // The sorter reverses them; execution must follow [B, A] while outputs
        // still land on their own toolCallIds.
        let twoToolMessage = F.assistantMessage(parts: [
            UIMessagePart.Tool(
                toolCallId: "tc-a", toolName: "tool_a", input: "{}",
                output: [], approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil, metadata: nil
            ),
            UIMessagePart.Tool(
                toolCallId: "tc-b", toolName: "tool_b", input: "{}",
                output: [], approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil, metadata: nil
            )
        ])
        let provider = UploadRecordingProvider([twoToolMessage, F.assistantText("done")])
        let executor = OrderRecordingExecutor()
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["tool_a": executor, "tool_b": executor],
            configuration: .init(maxSteps: 4)
        )

        let result = await engine.run(
            providerSetting: F.makeProviderSetting(),
            messages: [F.userMessage("hi")],
            params: F.makeParams(toolNames: ["tool_a", "tool_b"]),
            sortPendingToolCalls: { tools in tools.reversed() }
        )

        XCTAssertEqual(executor.invocations, ["tool_b", "tool_a"],
                       "batch execution order must follow the sorter, not the model emission order")
        XCTAssertTrue(F.toolOutputText(toolCallId: "tc-a", in: result.messages).contains("\"tool\":\"tool_a\""))
        XCTAssertTrue(F.toolOutputText(toolCallId: "tc-b", in: result.messages).contains("\"tool\":\"tool_b\""))
        XCTAssertEqual(provider.uploads.count, 2)
        XCTAssertEqual(result.stepsExecuted, 2)
    }

    // MARK: - preemptToolBatch

    func testPreemptToolBatchFillsFailureAndTerminatesWithoutExecution() async {
        // 预算/硬失败语义:流完成、未决调用已检测,但整批不得执行——
        // 原地失败化 + guardStopped 终态,账本零记录。
        let provider = UploadRecordingProvider([
            makeToolMessage(toolCallId: "tc-1", toolName: "echo")
        ])
        let executor = OrderRecordingExecutor()
        let ledgerLog = IOSRunEventLog()
        let ledger = IOSRunEventLogLedger(log: ledgerLog)
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["echo": executor],
            configuration: .init(maxSteps: 4),
            ledger: ledger,
            ledgerRunId: "run-preempt"
        )

        let result = await engine.run(
            providerSetting: F.makeProviderSetting(),
            messages: [F.userMessage("hi")],
            params: F.makeParams(toolNames: ["echo"]),
            preemptToolBatch: { tools in
                XCTAssertEqual(tools.map(\.toolCallId), ["tc-1"])
                return "工具调用未执行:已达到本轮工具循环上限。"
            }
        )

        XCTAssertTrue(result.guardStopped, "批量准入拒绝必须以 guardStopped 终态收口")
        XCTAssertTrue(executor.invocations.isEmpty, "被拒绝的批次不得执行任何调用")
        XCTAssertTrue(ledgerLog.snapshot().isEmpty, "未执行的批次不进账本(无 Started/Finished)")
        XCTAssertEqual(provider.uploads.count, 1, "拒绝发生在流完成后,不追加模型轮")
        XCTAssertTrue(
            F.toolOutputText(toolCallId: "tc-1", in: result.messages).contains("上限"),
            "失败文案要回填进工具输出"
        )
    }

    // MARK: - resolveUnexposedToolCall

    func testResolveUnexposedToolCallWritesFailedWithoutStartedAndContinues() async {
        // CG-C P0-a Fix B 语义:目录有、可见集没有 → 引导软失败。账本只写
        // Finished(failed)(无 Started),循环继续到下一轮模型。
        let provider = UploadRecordingProvider([
            makeToolMessage(toolCallId: "tc-1", toolName: "hidden_tool"),
            F.assistantText("改用已暴露工具")
        ])
        let ledgerLog = IOSRunEventLog()
        let ledger = IOSRunEventLogLedger(log: ledgerLog)
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: [:],
            configuration: .init(maxSteps: 4),
            ledger: ledger,
            ledgerRunId: "run-unexposed"
        )

        let result = await engine.run(
            providerSetting: F.makeProviderSetting(),
            messages: [F.userMessage("hi")],
            params: F.makeParams(toolNames: []),
            resolveUnexposedToolCall: { tool in
                XCTAssertEqual(tool.toolCallId, "tc-1")
                return [UIMessagePart.Text(
                    text: "{\"ok\":false,\"error\":\"tool_not_exposed\"}",
                    metadata: nil
                )]
            }
        )

        XCTAssertNil(result.pendingApproval)
        XCTAssertFalse(result.guardStopped)
        XCTAssertEqual(result.stepsExecuted, 2, "软失败后循环继续到下一轮")
        XCTAssertEqual(provider.uploads.count, 2)
        XCTAssertEqual(
            ledgerLog.snapshot(),
            [.toolCallFinished(tool: "tc-1", outcome: "failed")],
            "软失败只留 Finished(failed) 痕,不写 Started"
        )
        XCTAssertTrue(
            F.toolOutputText(toolCallId: "tc-1", in: result.messages).contains("tool_not_exposed")
        )
    }

}
