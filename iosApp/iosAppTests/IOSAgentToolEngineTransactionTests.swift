import XCTest
@preconcurrency import Shared
@testable import iosApp


/// Pre-existing tool transactions, handback, replay, and background output.
final class IOSAgentToolEngineTransactionTests: IOSAgentToolEngineTestCase {
    // MARK: - Background handoff parity: pre-existing empty-output tools

    /// When a run hands off to background, the input messages may already carry
    /// an assistant turn with an empty-output tool call (the model decided to
    /// generate_image, but the foreground executor was interrupted before it ran).
    /// The engine must execute that pre-existing tool ONCE before streaming, so
    /// the background run does NOT cause the model to re-issue (and re-run) the
    /// same call — e.g. wasting a Codex image-generation. This is the
    /// "generate_image must not re-run in background" fix.
    func testPreExistingEmptyOutputToolIsExecutedBeforeStreaming() async {
        // Input already contains the assistant tool-call turn (output empty).
        // Provider script: only a final text turn — the model should NOT be
        // asked to re-emit the tool (it already exists in history).
        let provider = ScriptedProvider([assistantText("image is ready")])
        let executor = RecordingExecutor(.filledParts([
            UIMessagePart.Image(url: "data:image/png;base64,AAA", metadata: nil)
        ]))
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["generate_image": executor],
            configuration: .init(maxSteps: 4)
        )

        let input: [UIMessage] = [
            userMessage("draw a cat"),
            toolCallMessage(toolCallId: "img-1", toolName: "generate_image", input: "{\"prompt\":\"cat\"}")
        ]

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: input,
            params: makeParams(tools: ["generate_image"])
        )

        // The pre-existing tool must have been executed exactly once.
        XCTAssertEqual(executor.calls.count, 1, "pre-existing empty-output tool must execute once before streaming")
        XCTAssertEqual(executor.calls.first?.name, "generate_image")
        XCTAssertEqual(executor.calls.first?.arguments, "{\"prompt\":\"cat\"}")

        // Its output must be filled in place in the returned message list.
        let toolMessage = result.messages[1]
        let toolPart = toolMessage.parts.compactMap { $0 as? UIMessagePart.Tool }.first
        XCTAssertFalse(toolPart?.output.isEmpty ?? true, "pre-existing tool output must be filled")

        // The model must not be asked to re-emit the tool: the provider should
        // only have been called for the single scripted final text turn.
        XCTAssertEqual(provider.callCount, 1, "engine must not re-prompt the model to regenerate an already-present tool call")
    }

    func testPreExistingBatchSurfacesSecondApprovalBeforeStreaming() async {
        let pendingTurn = makeMessage(
            role: MessageRole.assistant,
            parts: [
                UIMessagePart.Tool(
                    toolCallId: "read-1",
                    toolName: "read_tool",
                    input: "{}",
                    output: [],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                ),
                UIMessagePart.Tool(
                    toolCallId: "approval-2",
                    toolName: "sensitive_tool",
                    input: "{}",
                    output: [],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                ),
            ]
        )
        let provider = ScriptedProvider([assistantText("should-not-reach")])
        let readExecutor = RecordingExecutor(.filled("{\"ok\":true}"))
        let approvalExecutor = RecordingExecutor(.needsApproval("second approval required"))
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: [
                "read_tool": readExecutor,
                "sensitive_tool": approvalExecutor,
            ],
            configuration: .init(maxSteps: 4, honorApprovalPause: true)
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("continue pending batch"), pendingTurn],
            params: makeParams(tools: ["read_tool", "sensitive_tool"])
        )

        XCTAssertEqual(provider.callCount, 0, "pre-existing approval must pause before another model round")
        XCTAssertEqual(readExecutor.calls.count, 1)
        XCTAssertEqual(approvalExecutor.calls.count, 1)
        XCTAssertEqual(result.pendingApproval?.toolCallId, "approval-2")
        XCTAssertEqual(result.pendingApproval?.reason, "second approval required")
        let tools = result.messages[1].parts.compactMap { $0 as? UIMessagePart.Tool }
        XCTAssertFalse(tools.first { $0.toolCallId == "read-1" }?.output.isEmpty ?? true)
        XCTAssertTrue(tools.first { $0.toolCallId == "approval-2" }?.output.isEmpty == true)
    }

    func testExecutionCallbacksBracketPreExistingAndFreshToolsInOrder() async {
        let provider = ScriptedProvider([
            toolCallMessage(
                toolCallId: "search-1",
                toolName: "search_web",
                input: "{\"query\":\"cat care\"}"
            ),
            assistantText("done")
        ])
        let events = AssistantTextRecorder()
        let imageExecutor = RecordingExecutor(.filled("{\"image\":true}"), events: events)
        let searchExecutor = RecordingExecutor(.filled("{\"results\":[]}"), events: events)
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: [
                "generate_image": imageExecutor,
                "search_web": searchExecutor,
            ],
            configuration: .init(maxSteps: 4)
        )
        let input: [UIMessage] = [
            userMessage("draw, then research"),
            toolCallMessage(
                toolCallId: "image-1",
                toolName: "generate_image",
                input: "{\"prompt\":\"cat\"}"
            ),
        ]

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: input,
            params: makeParams(tools: ["generate_image", "search_web"]),
            onAssistantTurnStarted: {
                events.append("assistant")
            },
            onToolExecutionStarted: { toolName, _ in
                events.append("tool:\(toolName)")
            }
        )

        XCTAssertEqual(
            events.snapshot,
            [
                "tool:generate_image",
                "execute:generate_image",
                "assistant",
                "tool:search_web",
                "execute:search_web",
                "assistant",
            ]
        )
        XCTAssertEqual(imageExecutor.calls.count, 1)
        XCTAssertEqual(searchExecutor.calls.count, 1)
        XCTAssertEqual(result.messages.last?.toText(), "done")
    }

    func testCancellationDuringToolStageCallbackDoesNotStartExecutor() async {
        let provider = ScriptedProvider([assistantText("should not run")])
        let executor = RecordingExecutor(.filled("{\"ok\":true}"))
        let ledger = RecordingLedger()
        let gate = ToolStageGate()
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["generate_image": executor],
            configuration: .init(maxSteps: 4),
            ledger: ledger,
            ledgerRunId: "cancel-before-execution"
        )
        let input: [UIMessage] = [
            userMessage("draw a cat"),
            toolCallMessage(
                toolCallId: "image-1",
                toolName: "generate_image",
                input: "{\"prompt\":\"cat\"}"
            ),
        ]
        let providerSetting = makeProviderSetting()
        let params = makeParams(tools: ["generate_image"])
        let task = Task {
            await engine.run(
                providerSetting: providerSetting,
                messages: input,
                params: params,
                onToolExecutionStarted: { _, _ in
                    await gate.suspend()
                }
            )
        }

        await gate.waitUntilEntered()
        task.cancel()
        await gate.resume()
        let result = await task.value
        let ledgerOutcomes = await ledger.outcomes()

        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(executor.calls.count, 0)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(ledgerOutcomes, ["cancelled_before_execution"])
    }

    /// Guard against double execution: a pre-existing empty-output tool that the
    /// model ALSO re-issues in its next turn (provider quirk) must not be
    /// executed twice — the in-place fill from pre-execution makes the model's
    /// re-issued copy collapse into the already-filled one rather than running
    /// the executor a second time.
    func testPreExecutedToolNotReRunIfModelReIssuesIt() async {
        // Provider re-emits the SAME tool call id in its first turn (a buggy /
        // streaming-merged provider echo), then a final text turn.
        let provider = ScriptedProvider([
            toolCallMessage(toolCallId: "img-1", toolName: "generate_image", input: "{\"prompt\":\"cat\"}"),
            assistantText("done")
        ])
        let executor = RecordingExecutor(.filledParts([
            UIMessagePart.Image(url: "data:image/png;base64,AAA", metadata: nil)
        ]))
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["generate_image": executor],
            configuration: .init(maxSteps: 4)
        )

        let input: [UIMessage] = [
            userMessage("draw a cat"),
            toolCallMessage(toolCallId: "img-1", toolName: "generate_image", input: "{\"prompt\":\"cat\"}")
        ]

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: input,
            params: makeParams(tools: ["generate_image"])
        )

        // Even though the model re-issued img-1, the executor must run only once.
        XCTAssertEqual(executor.calls.count, 1, "a tool whose output is already filled must not be re-executed")
        XCTAssertEqual(provider.callCount, 2, "the engine must continue to the provider's final text turn")
        XCTAssertEqual(result.messages.last?.toText(), "done")
    }

    func testFinishedTransactionReplaysStoredResultWithoutCallingExecutor() async {
        let payload = IosToolOutputJsonBridge.shared.encode(parts: [
            UIMessagePart.Text(text: "{\"ok\":true,\"source\":\"replay\"}", metadata: nil),
        ])
        let ledger = RecordingLedger(preparation: .replay(resultPayload: payload))
        let executor = RecordingExecutor(.filled("{\"ok\":true,\"source\":\"executor\"}"))
        let engine = IOSAgentToolEngine(
            provider: ScriptedProvider([]),
            executors: ["generate_image": executor],
            ledger: ledger,
            ledgerRunId: "finished-replay"
        )

        let result = await engine.executePreExistingToolsOnly(messages: [
            toolCallMessage(
                toolCallId: "image-replay-1",
                toolName: "generate_image",
                input: "{\"prompt\":\"cat\"}"
            ),
        ])

        let output = result.messages
            .flatMap(\.parts)
            .compactMap { $0 as? UIMessagePart.Tool }
            .first?.output
            .compactMap { ($0 as? UIMessagePart.Text)?.text }
            .first
        XCTAssertEqual(output, "{\"ok\":true,\"source\":\"replay\"}")
        XCTAssertEqual(executor.calls.count, 0)
        let starts = await ledger.starts()
        let outcomes = await ledger.outcomes()
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(outcomes.isEmpty)
    }

    private func humanControlBatch() -> UIMessage {
        makeMessage(role: MessageRole.assistant, parts: [
            UIMessagePart.Tool(toolCallId: "handback", toolName: "phone_run_goal", input: "{}", output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil),
            UIMessagePart.Tool(toolCallId: "old-launch", toolName: "phone_act", input: "{\"action\":\"launch\",\"bundle_id\":\"app.old\"}", output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil),
        ])
    }

    func testHumanHandbackSkipsOldBatchAndAllowsNewProviderPlan() async throws {
        let freshResult = "{\"reason_code\":\"human_control_returned\",\"tree\":\"fresh-screen\"}"
        let provider = ParamsRecordingProvider([
            humanControlBatch(),
            toolCallMessage(toolCallId: "new-launch", toolName: "phone_act", input: "{\"action\":\"launch\",\"bundle_id\":\"app.new\"}"),
            assistantText("done"),
        ])
        let handback = RecordingExecutor(.replanRequired([UIMessagePart.Text(text: freshResult, metadata: nil)]))
        let launch = RecordingExecutor(.filled("{\"ok\":true}"))
        let ledger = RecordingLedger()
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["phone_run_goal": handback, "phone_act": launch],
            configuration: .init(maxSteps: 4),
            ledger: ledger,
            ledgerRunId: "human-handback"
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("continue after human control")],
            params: makeParams(tools: ["phone_run_goal", "phone_act"])
        )

        XCTAssertEqual(handback.calls.count, 1)
        XCTAssertEqual(launch.calls.map(\.arguments), ["{\"action\":\"launch\",\"bundle_id\":\"app.new\"}"])
        XCTAssertEqual(provider.recordedMessages.count, 3)
        let replanningTools = provider.recordedMessages[1].flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }
        let handbackOutput = try XCTUnwrap(replanningTools.first { $0.toolCallId == "handback" }?.output.first as? UIMessagePart.Text)
        XCTAssertEqual(handbackOutput.text, freshResult)
        let skippedOutput = try XCTUnwrap(replanningTools.first { $0.toolCallId == "old-launch" }?.output.first as? UIMessagePart.Text)
        let skipped = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(skippedOutput.text.utf8)) as? [String: Any])
        XCTAssertEqual(skipped["outcome"] as? String, "not_sent")
        XCTAssertEqual(skipped["reason_code"] as? String, "replan_required")
        let prepared = await ledger.preparedIDs()
        let starts = await ledger.starts()
        let outcomes = await ledger.outcomes()
        XCTAssertEqual(prepared, ["handback", "new-launch"])
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(outcomes, ["completed_requires_replan", "completed"])
        XCTAssertEqual(result.messages.last?.toText(), "done")
        XCTAssertNil(result.toolOutcomeUnknown)
        XCTAssertNil(result.durabilityFailureMessage)
    }

    func testDurableHumanHandbackReplayPreservesBatchBarrier() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("handback-replay-\(UUID().uuidString).db").path
        let database = IosDatabaseFactory.shared.createDatabase(atFilePath: path)
        let dao = database.agentRuntimeDao()
        let runId = "handback-replay-\(UUID().uuidString)"
        let run = AgentRunEntity(
            runId: runId, parentRunId: nil,
            agentDescriptorId: IOSDurableRunStore.Descriptor.chat,
            agentVersion: IOSDurableRunStore.Descriptor.chatVersion,
            conversationId: nil, messageNodeId: nil, producesMessageId: nil, assistantId: nil,
            status: "running", inputDigest: "digest", inputSnapshotRef: nil,
            inputSchemaVersion: 1, startedAt: 1, finishedAt: nil, interruptedReason: nil,
            terminalReason: nil, providerId: nil, modelId: nil, promptVersion: nil,
            toolCatalogVersion: nil, capabilitySnapshot: nil
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            dao.insertRunIfAbsent(run: run) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        let freshParts: [UIMessagePart] = [UIMessagePart.Text(text: "fresh-screen", metadata: nil)]
        let handback = RecordingExecutor(.replanRequired(freshParts))
        let launch = RecordingExecutor(.filled("{\"ok\":true}"))
        let firstLedger = IOSAgentRunLedger(dao: dao)
        let firstEngine = IOSAgentToolEngine(
            provider: ScriptedProvider([]),
            executors: ["phone_run_goal": handback, "phone_act": launch],
            ledger: firstLedger, ledgerRunId: runId
        )
        let firstResult = await firstEngine.executePreExistingToolsOnly(messages: [humanControlBatch()])
        XCTAssertNil(firstResult.durabilityFailureMessage)
        XCTAssertEqual(handback.calls.count, 1)
        XCTAssertTrue(launch.calls.isEmpty)

        let replayLedger = IOSAgentRunLedger(dao: dao)
        let replayEngine = IOSAgentToolEngine(
            provider: ScriptedProvider([]),
            executors: ["phone_run_goal": handback, "phone_act": launch],
            ledger: replayLedger, ledgerRunId: runId
        )
        let replayResult = await replayEngine.executePreExistingToolsOnly(messages: [humanControlBatch()])

        XCTAssertEqual(handback.calls.count, 1, "terminal replay must not dispatch the handback again")
        XCTAssertTrue(launch.calls.isEmpty, "terminal replay must retain the barrier before the old launch")
        XCTAssertNil(replayResult.durabilityFailureMessage)
        let replayTools = replayResult.messages.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }
        XCTAssertEqual((replayTools.first?.output.first as? UIMessagePart.Text)?.text, "fresh-screen")
        let skipped = try XCTUnwrap(replayTools.last?.output.first as? UIMessagePart.Text)
        XCTAssertTrue(skipped.text.contains("\"reason_code\":\"replan_required\""))
        let storedTransactions = await replayLedger.toolTransactions(runId: runId)
        let transactions = try XCTUnwrap(storedTransactions)
        XCTAssertEqual(transactions.count, 1, "the old launch must not even prepare a transaction")
        XCTAssertEqual(transactions.first?.outcome, "completed_requires_replan")
        XCTAssertEqual(transactions.first?.resultPayload, IosToolOutputJsonBridge.shared.encode(parts: freshParts))
    }

    func testMalformedHumanHandbackReplayStillSkipsOldBatch() async {
        let ledger = RecordingLedger(preparation: .replay(resultPayload: "{", requiresReplan: true))
        let executor = RecordingExecutor(.filled("unexpected"))
        let engine = IOSAgentToolEngine(
            provider: ScriptedProvider([]),
            executors: ["phone_run_goal": executor, "phone_act": executor],
            ledger: ledger, ledgerRunId: "malformed-handback-replay"
        )

        let result = await engine.executePreExistingToolsOnly(messages: [humanControlBatch()])

        XCTAssertTrue(executor.calls.isEmpty)
        let tools = result.messages.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }
        XCTAssertTrue((tools.first?.output.first as? UIMessagePart.Text)?.text.contains("tool_result_replay_failed") == true)
        XCTAssertTrue((tools.last?.output.first as? UIMessagePart.Text)?.text.contains("\"reason_code\":\"replan_required\"") == true)
        let prepared = await ledger.preparedIDs()
        let starts = await ledger.starts()
        XCTAssertEqual(prepared, ["handback"])
        XCTAssertEqual(starts, 0)
    }

    func testCancelledHumanHandbackDoesNotRequestAnotherProviderRound() async {
        let provider = ScriptedProvider([humanControlBatch(), assistantText("must not run")])
        let handback = RecordingExecutor(.replanRequired([UIMessagePart.Text(text: "fresh-screen", metadata: nil)]), cancelOnExecute: true)
        let launch = RecordingExecutor(.filled("unexpected"))
        let ledger = RecordingLedger()
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["phone_run_goal": handback, "phone_act": launch],
            ledger: ledger, ledgerRunId: "cancelled-handback"
        )
        let setting = makeProviderSetting()
        let messages = [userMessage("continue")]
        let params = makeParams(tools: ["phone_run_goal", "phone_act"])
        let task = Task {
            await engine.run(
                providerSetting: setting,
                messages: messages,
                params: params
            )
        }

        let result = await task.value

        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertTrue(launch.calls.isEmpty)
        let tools = result.messages.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }
        XCTAssertEqual((tools.first?.output.first as? UIMessagePart.Text)?.text, "fresh-screen")
        XCTAssertTrue((tools.last?.output.first as? UIMessagePart.Text)?.text.contains("\"outcome\":\"not_sent\"") == true)
        let outcomes = await ledger.outcomes()
        XCTAssertEqual(outcomes, ["completed_requires_replan"])
    }

    func testHumanHandbackTerminalWriteFailureStopsBeforePublishingOrReplanning() async {
        let provider = ScriptedProvider([humanControlBatch(), assistantText("must not run")])
        let handback = RecordingExecutor(.replanRequired([UIMessagePart.Text(text: "fresh-screen", metadata: nil)]))
        let launch = RecordingExecutor(.filled("unexpected"))
        let ledger = RecordingLedger(terminalResult: false)
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["phone_run_goal": handback, "phone_act": launch],
            ledger: ledger, ledgerRunId: "failed-handback-terminal"
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("continue")],
            params: makeParams(tools: ["phone_run_goal", "phone_act"])
        )

        XCTAssertNotNil(result.durabilityFailureMessage)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertTrue(launch.calls.isEmpty)
        XCTAssertTrue(result.messages.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }.allSatisfy { $0.output.isEmpty })
        let prepared = await ledger.preparedIDs()
        XCTAssertEqual(prepared, ["handback"])
    }

    func testCompletedToolEchoIsRemovedWhenSameTurnAlsoContainsTextAndANewTool() async {
        let mixedTurn = makeMessage(
            role: MessageRole.assistant,
            parts: [
                UIMessagePart.Text(text: "I will search next.", metadata: nil),
                UIMessagePart.Tool(
                    toolCallId: "img-1",
                    toolName: "generate_image",
                    input: "{\"prompt\":\"cat\"}",
                    output: [],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                ),
                UIMessagePart.Tool(
                    toolCallId: "search-1",
                    toolName: "search_web",
                    input: "{\"query\":\"cat care\"}",
                    output: [],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                )
            ]
        )
        let provider = ScriptedProvider([mixedTurn, assistantText("done")])
        let imageExecutor = RecordingExecutor(.filled("{\"image\":true}"))
        let searchExecutor = RecordingExecutor(.filled("{\"results\":[]}"))
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: [
                "generate_image": imageExecutor,
                "search_web": searchExecutor,
            ],
            configuration: .init(maxSteps: 4)
        )
        let input: [UIMessage] = [
            userMessage("draw, then research"),
            toolCallMessage(
                toolCallId: "img-1",
                toolName: "generate_image",
                input: "{\"prompt\":\"cat\"}"
            )
        ]

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: input,
            params: makeParams(tools: ["generate_image", "search_web"])
        )

        XCTAssertEqual(imageExecutor.calls.count, 1)
        XCTAssertEqual(searchExecutor.calls.count, 1)
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(result.messages.last?.toText(), "done")
        XCTAssertTrue(result.messages.contains { $0.toText().contains("I will search next.") })
        let toolParts = result.messages.flatMap { message in
            message.parts.compactMap { $0 as? UIMessagePart.Tool }
        }
        XCTAssertEqual(toolParts.filter { $0.toolCallId == "img-1" }.count, 1)
        XCTAssertEqual(toolParts.filter { $0.toolCallId == "search-1" }.count, 1)
        XCTAssertFalse(
            toolParts.first(where: { $0.toolCallId == "search-1" })?.output.isEmpty ?? true
        )
    }

    /// P3-a: exec 工具循环集成——脚本化 provider 让模型调用 exec，真实
    /// JavaScriptCore 沙箱求值（IOSJsSandboxEngine），工具输出以
    /// `{result, logs}` 回填并折入下一轮（完整 engine 循环，fake provider）。
    func testExecToolRunsThroughEngineLoopWithRealSandbox() async {
        let provider = ScriptedProvider([
            toolCallMessage(
                toolCallId: "tc-exec",
                toolName: "exec",
                input: #"{"code":"console.log('hi'); 6 * 7"}"#
            ),
            assistantText("done")
        ])
        let executor = RealJsSandboxExecutor()
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["exec": executor],
            configuration: .init(maxSteps: 4)
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("run js")],
            params: makeParams(tools: ["exec"])
        )

        XCTAssertEqual(provider.callCount, 2, "engine should run the tool turn then the final text turn")
        XCTAssertEqual(executor.calls.count, 1)
        XCTAssertEqual(executor.calls.first?.name, "exec")
        let toolMessage = result.messages[1]
        let toolPart = toolMessage.parts.compactMap { $0 as? UIMessagePart.Tool }.first
        let outputText = toolPart?.output.compactMap { $0 as? UIMessagePart.Text }.first?.text ?? ""
        XCTAssertTrue(outputText.contains("\"result\":\"42\""), "tool output must carry the evaluated result: \(outputText)")
        XCTAssertTrue(outputText.contains("[LOG] hi"), "tool output must carry console capture: \(outputText)")
    }

    // MARK: - P2-c: background engine citation stripping

    /// P2-c 修复 1：后台引擎（`IOSAgentToolEngine`）流式输出含
    /// `<amber-mem-cite>` 隐藏标记时，必须像前台一样在持久化前剥离——终态消息
    /// 无标记、正文保留；引用 id 经 `markUsed(force:)`（bg 接线同款调用）落盘
    /// 可读回。脚本化 streaming provider 驱动两轮：第一轮标签跨 chunk 拆分 +
    /// 工具调用，第二轮再一个标签。
    @MainActor
    func testBackgroundEngineStripsCitationTagsAcrossRoundsAndMarksUsed() async throws {
        try await withIsolatedPersistence { persistence, fileURL in
            IosMemoryFactory.shared.replaceAll(records: [
                makeMemoryRecord(id: 1, content: "favorite color blue", updatedAt: 10),
                makeMemoryRecord(id: 2, content: "green project", updatedAt: 20),
                makeMemoryRecord(id: 3, content: "untouched", updatedAt: 30),
            ])

            let round1Text = #"Your favorite color is blue. <amber-mem-cite>{"ids":[1]}</amber-mem-cite> And green too."#
            let round2Text = #"<amber-mem-cite>{"ids":[2,3],"note":"fav"}</amber-mem-cite> Done."#
            let engine = IOSAgentToolEngine(
                provider: TwoRoundScriptedStreamingProvider(
                    round1: [
                        streamingDelta(#"Your favorite color is blue. <amber-mem-cite>{"ids":[1]}"#),
                        streamingDelta(#"</amber-mem-cite> And green too."#),
                        streamingFinal(makeMessage(
                            role: MessageRole.assistant,
                            parts: [
                                UIMessagePart.Text(text: round1Text, metadata: nil),
                                UIMessagePart.Tool(
                                    toolCallId: "tc-1",
                                    toolName: "memory_tool",
                                    input: #"{"action":"read","id":2}"#,
                                    output: [],
                                    approvalState: ToolApprovalState.Auto.shared,
                                    streamIndex: nil,
                                    metadata: nil
                                ),
                            ]
                        )),
                    ],
                    round2: [
                        streamingDelta(#"<amber-mem-cite>{"id"#),
                        streamingDelta(#"s":[2,3],"note":"fav"}</amber-mem-cite> Done."#),
                        streamingFinal(assistantText(round2Text)),
                    ]
                ),
                executors: ["memory_tool": RecordingExecutor(.filled(
                    #"{"ok":true,"tool":"memory_tool","action":"read","memory":{"id":2,"content":"green project"}}"#
                ))],
                configuration: .init(maxSteps: 4)
            )
            let tracker = IOSMemoryCitationTracker(enforceCitationAllowlist: true)
            tracker.allowCitationIds([1])
            let result = await engine.run(
                providerSetting: makeProviderSetting(),
                messages: [userMessage("ask")],
                params: makeParams(tools: ["memory_tool"]),
                citationTracker: tracker
            )

            // 两轮都跑完、工具输出已填、正常终态。
            XCTAssertEqual(result.stepsExecuted, 2)
            XCTAssertFalse(result.hitStepLimit)
            XCTAssertNil(result.pendingApproval)
            XCTAssertFalse(result.wasCancelled)

            // 终态消息链（要持久化的内容）无标签；剥离后正文保留。
            let assistantTexts = result.messages
                .filter { $0.role == MessageRole.assistant }
                .flatMap { message in message.parts.compactMap { ($0 as? UIMessagePart.Text)?.text } }
                .joined()
            XCTAssertFalse(assistantTexts.contains("<amber-mem-cite>"))
            XCTAssertTrue(assistantTexts.contains("Your favorite color is blue."))
            XCTAssertTrue(assistantTexts.contains("And green too."))
            XCTAssertTrue(assistantTexts.contains(" Done."))

            // 后续读取的 id=2 自动准入；未提供给模型的 id=3 不得被引用落盘。
            XCTAssertEqual(tracker.citationIds, Set<Int32>([1, 2]))
            XCTAssertTrue(persistence.markUsed(ids: tracker.citationIds, now: 999, force: true))
            let reader = IOSMemoryPersistence(fileURL: fileURL)
            reader.load()
            XCTAssertEqual(reader.loadState, .loaded)
            XCTAssertEqual(reader.records.first { $0.id == 1 }?.lastUsedAt?.int64Value, 999)
            XCTAssertEqual(reader.records.first { $0.id == 2 }?.lastUsedAt?.int64Value, 999)
            XCTAssertNil(reader.records.first { $0.id == 3 }?.lastUsedAt)
        }
    }

    // MARK: - P2-c fixtures

    /// 每轮（一次 streamStep）回放一组 chunk 的两轮 streaming provider。
    private final class TwoRoundScriptedStreamingProvider: IOSAgentTextProvider, IOSAgentStreamingProvider, @unchecked Sendable {
        private let round1: [MessageChunk]
        private let round2: [MessageChunk]
        private var roundIndex = 0

        init(round1: [MessageChunk], round2: [MessageChunk]) {
            self.round1 = round1
            self.round2 = round2
        }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            roundIndex += 1
            return (roundIndex == 1 ? round1 : round2).last
                ?? MessageChunk(id: "empty", model: "test-model", choices: [], usage: nil)
        }

        func streamText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams,
            onChunk: @escaping @Sendable (MessageChunk) -> Void,
            onComplete: @escaping @Sendable () -> Void,
            onError: @escaping @Sendable (KotlinThrowable) -> Void
        ) -> Kotlinx_coroutines_coreJob? {
            roundIndex += 1
            let chunks = roundIndex == 1 ? round1 : round2
            chunks.forEach(onChunk)
            onComplete()
            return nil
        }
    }

    private func streamingDelta(_ text: String) -> MessageChunk {
        MessageChunk(
            id: UUID().uuidString,
            model: "test-model",
            choices: [UIMessageChoice(
                index: 0,
                delta: assistantText(text),
                message: nil,
                finishReason: nil
            )],
            usage: nil
        )
    }

    private func streamingFinal(_ message: UIMessage) -> MessageChunk {
        MessageChunk(
            id: UUID().uuidString,
            model: "test-model",
            choices: [UIMessageChoice(
                index: 0,
                delta: nil,
                message: message,
                finishReason: "stop"
            )],
            usage: nil
        )
    }

    @MainActor
    private func withIsolatedPersistence(
        _ body: (IOSMemoryPersistence, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSAgentToolEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("memories.json")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let originalRecords = IosMemoryFactory.shared.snapshotRecords()
        defer { IosMemoryFactory.shared.replaceAll(records: originalRecords) }
        IosMemoryFactory.shared.replaceAll(records: [])
        let persistence = IOSMemoryPersistence(fileURL: fileURL)
        persistence.load()
        try await body(persistence, fileURL)
    }

    private func makeMemoryRecord(id: Int32, content: String, updatedAt: Int64 = 0) -> MemoryRecord {
        MemoryRecord(
            id: id,
            content: content,
            scope: MemoryScope.core,
            kind: MemoryKind.user,
            assistantId: "__global__",
            sourceConversationId: nil,
            sourceMessageIds: [],
            supersedesIds: [],
            expiresAt: nil,
            confidence: 1,
            pinned: false,
            archived: false,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            lastUsedAt: nil,
            topicTitle: nil,
            memberIds: [], lastReinforcedAt: nil
        )
    }
}

/// P3-a: executor that runs `exec` calls through the real JS sandbox engine
/// (same contract as the production dispatch: parse code from arguments,
/// clamp timeout, format the payload with truncation).
private final class RealJsSandboxExecutor: IOSToolExecutor {
    private(set) var calls: [(name: String, arguments: String)] = []

    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        calls.append((name, arguments))
        let sandbox = IOSJsSandboxEngine()
        let args = ChatToolCallParsing.jsonObject(arguments)
        let code = (args?["code"] as? String) ?? "undefined"
        let timeoutMs = IOSJsSandboxEngine.clampTimeoutMs(
            (args?["timeout_ms"] as? Int) ?? IOSJsSandboxEngine.defaultTimeoutMs
        )
        let result = await sandbox.evaluate(
            code: code,
            timeoutMs: timeoutMs,
            maxOutputChars: IOSJsSandboxEngine.defaultMaxOutputChars
        )
        return .filled(IOSJsSandboxEngine.toolPayload(
            result,
            maxOutputChars: IOSJsSandboxEngine.defaultMaxOutputChars
        ))
    }
}
