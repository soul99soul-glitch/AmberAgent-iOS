import XCTest
@preconcurrency import Shared
@testable import iosApp


/// Streaming output, provider preparation, and interrupted streams.
final class IOSAgentToolEngineStreamingTests: IOSAgentToolEngineTestCase {
    func testStreamingAssistantTextDoesNotSnapshotOnEveryChunk() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testDirectory.deletingLastPathComponent().appendingPathComponent("iosApp")
        let source = try String(
            contentsOf: appDirectory.appendingPathComponent("AgentRuntime/ToolEngine/IOSAgentProviderStep.swift"),
            encoding: .utf8
        )

        guard let onChunkStart = source.range(of: "onChunk: { chunk in"),
              let onCompleteStart = source.range(of: "onComplete:", range: onChunkStart.upperBound..<source.endIndex) else {
            return XCTFail("Expected streamStep to have onChunk before onComplete")
        }
        let onChunkBody = source[onChunkStart.upperBound..<onCompleteStart.lowerBound]
        XCTAssertFalse(
            onChunkBody.contains("accumulator.snapshot()"),
            "Background/sub-agent streaming must not snapshot+join the full accumulator on every chunk; long streams make this O(n²)."
        )
        XCTAssertTrue(
            source.contains("appendAssistantDelta"),
            "streamStep should maintain cumulative assistant text incrementally and publish that text without a per-chunk full snapshot."
        )
    }

    func testStreamingAssistantTextPublishesCumulativeTextAndHonorsFinalReplacement() async {
        func delta(_ text: String) -> MessageChunk {
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
        let final = MessageChunk(
            id: "final",
            model: "test-model",
            choices: [UIMessageChoice(
                index: 0,
                delta: nil,
                message: assistantText("Hello!"),
                finishReason: "stop"
            )],
            usage: nil
        )
        let recorder = AssistantTextRecorder()
        let engine = IOSAgentToolEngine(
            provider: ScriptedStreamingProvider([delta("Hel"), delta("lo"), final]),
            executors: [:]
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("ask")],
            params: makeParams(tools: []),
            onAssistantText: { recorder.append($0) }
        )

        XCTAssertEqual(recorder.snapshot, ["Hel", "Hello", "Hello!"])
        XCTAssertEqual(result.messages.last?.toText(), "Hello!")
    }

    func testStreamingAssistantStagePublishesReasoningThenResponse() async {
        func delta(_ message: UIMessage) -> MessageChunk {
            MessageChunk(
                id: UUID().uuidString,
                model: "test-model",
                choices: [UIMessageChoice(
                    index: 0,
                    delta: message,
                    message: nil,
                    finishReason: nil
                )],
                usage: nil
            )
        }
        let final = MessageChunk(
            id: "final",
            model: "test-model",
            choices: [UIMessageChoice(
                index: 0,
                delta: nil,
                message: assistantText("答案"),
                finishReason: "stop"
            )],
            usage: nil
        )
        let recorder = AssistantStageRecorder()
        let engine = IOSAgentToolEngine(
            provider: ScriptedStreamingProvider([
                delta(assistantReasoning("先分析")),
                delta(assistantText("答")),
                final,
            ]),
            executors: [:]
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("ask")],
            params: makeParams(tools: []),
            onAssistantStage: { recorder.append($0) }
        )

        XCTAssertEqual(recorder.snapshot, [.thinking, .generating])
        // Stage-only consumers must still receive the accumulator's final
        // message even though no cumulative text callback is registered.
        XCTAssertEqual(result.messages.last?.toText(), "答案")
    }

    func testStreamingAssistantReasoningCallbackAccumulates() async {
        func delta(_ message: UIMessage) -> MessageChunk {
            MessageChunk(
                id: UUID().uuidString,
                model: "test-model",
                choices: [UIMessageChoice(
                    index: 0,
                    delta: message,
                    message: nil,
                    finishReason: nil
                )],
                usage: nil
            )
        }
        let final = MessageChunk(
            id: "final",
            model: "test-model",
            choices: [UIMessageChoice(
                index: 0,
                delta: nil,
                message: assistantText("答案"),
                finishReason: "stop"
            )],
            usage: nil
        )
        let recorder = AssistantTextRecorder()
        let engine = IOSAgentToolEngine(
            provider: ScriptedStreamingProvider([
                delta(assistantReasoning("先")),
                delta(assistantReasoning("分析")),
                delta(assistantText("答")),
                final,
            ]),
            executors: [:]
        )

        _ = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("ask")],
            params: makeParams(tools: []),
            onAssistantReasoning: { recorder.append($0) }
        )

        XCTAssertEqual(recorder.snapshot, ["先", "先分析"])
    }

    func testStreamingOutputLimitIsSurfacedAsProviderFailure() async {
        let limited = MessageChunk(
            id: "limited",
            model: "test-model",
            choices: [UIMessageChoice(
                index: 0,
                delta: assistantText("未写完"),
                message: nil,
                finishReason: "length"
            )],
            usage: nil
        )
        let recorder = AssistantTextRecorder()
        let engine = IOSAgentToolEngine(
            provider: ScriptedStreamingProvider([limited]),
            executors: [:]
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("ask")],
            params: makeParams(tools: []),
            onAssistantText: { recorder.append($0) }
        )

        XCTAssertEqual(recorder.snapshot, ["未写完"])
        XCTAssertEqual(result.providerFailureMessage, "模型回复达到输出上限，请重试。")
        XCTAssertTrue(result.hitOutputLimit)
    }

    func testCancellingEngineTaskStopsWaitingForStreamingTerminal() async {
        let engine = IOSAgentToolEngine(
            provider: DelayedCompletingStreamingProvider(delayNanos: 400_000_000),
            executors: [:]
        )
        let providerSetting = makeProviderSetting()
        let params = makeParams(tools: [])
        let messages = [userMessage("ask")]
        let finished = expectation(description: "cancelled engine returns without provider terminal")
        let task = Task {
            let result = await engine.run(
                providerSetting: providerSetting,
                messages: messages,
                params: params
            )
            finished.fulfill()
            return result
        }

        await Task.yield()
        task.cancel()
        await fulfillment(of: [finished], timeout: 0.15)
        let result = await task.value
        XCTAssertTrue(result.wasCancelled)
    }

    private func interruptedStreamChunks() -> [MessageChunk] {
        let first = makeMessage(role: .assistant, parts: [
            UIMessagePart.Text(text: "正文", metadata: nil),
            assistantReasoning("思考").parts[0],
        ])
        let tail = makeMessage(role: .assistant, parts: [
            UIMessagePart.Text(text: "尾段", metadata: nil),
            assistantReasoning("尾推理").parts[0],
            toolCallMessage(toolCallId: "partial-tool", toolName: "echo", input: "{").parts[0],
        ])
        return [first, tail].map {
            MessageChunk(id: UUID().uuidString, model: "test-model",
                         choices: [UIMessageChoice(index: 0, delta: $0, message: nil, finishReason: nil)], usage: nil)
        }
    }

    func testStreamingErrorPreservesTextReasoningAndUnfinishedToolWithoutExecutingIt() async {
        let provider = InterruptedStreamingProvider(interruptedStreamChunks(), fails: true)
        let executor = RecordingExecutor(.filled("must not run"))
        let engine = IOSAgentToolEngine(provider: provider, executors: ["echo": executor])
        let result = await engine.run(providerSetting: makeProviderSetting(), messages: [userMessage("ask")], params: makeParams(tools: []))
        XCTAssertEqual(result.providerFailureMessage, "connection lost")
        let partial = result.messages.first { message in
            message.parts.contains { ($0 as? UIMessagePart.Text)?.text == "正文" }
        }
        XCTAssertEqual(partial?.parts.compactMap { ($0 as? UIMessagePart.Text)?.text }, ["正文", "尾段"])
        XCTAssertEqual(result.messages.flatMap(\.parts).compactMap { ($0 as? UIMessagePart.Reasoning)?.reasoning }.joined(), "思考尾推理")
        XCTAssertTrue(executor.calls.isEmpty)
        let tool = result.messages.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }.first
        XCTAssertFalse(tool?.output.isEmpty ?? true)
    }

    func testStreamingCancellationPreservesUnpublishedTailAndIgnoresLateCompletion() async {
        let provider = InterruptedStreamingProvider(interruptedStreamChunks(), fails: false)
        let executor = RecordingExecutor(.filled("must not run"))
        let engine = IOSAgentToolEngine(provider: provider, executors: ["echo": executor])
        let setting = makeProviderSetting()
        let params = makeParams(tools: [])
        let messages = [userMessage("ask")]
        let task = Task { await engine.run(providerSetting: setting, messages: messages, params: params) }
        while !provider.didEmit { await Task.yield() }
        task.cancel()
        let result = await task.value
        provider.completeLate()
        XCTAssertTrue(result.wasCancelled)
        let partial = result.messages.first { message in
            message.parts.contains { ($0 as? UIMessagePart.Text)?.text == "正文" }
        }
        XCTAssertEqual(partial?.parts.compactMap { ($0 as? UIMessagePart.Text)?.text }, ["正文", "尾段"])
        XCTAssertEqual(result.messages.flatMap(\.parts).compactMap { ($0 as? UIMessagePart.Reasoning)?.reasoning }.joined(), "思考尾推理")
        XCTAssertTrue(executor.calls.isEmpty)
        XCTAssertFalse(result.messages.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }.first?.output.isEmpty ?? true)
    }

    func testGuardFinalizationStreamErrorPreservesPromptTranscriptAndDisablesTools() async {
        await assertGuardPartialHasPromptTranscript(fails: true)
    }

    func testGuardFinalizationStreamCancelPreservesPromptTranscriptAndDisablesTools() async {
        await assertGuardPartialHasPromptTranscript(fails: false)
    }

    private func assertGuardPartialHasPromptTranscript(fails: Bool) async {
        let prelude = (1...3).map { index in
            chunk(with: toolCallMessage(toolCallId: "guard-\(index)", toolName: "echo", input: "{}"))
        }
        let provider = InterruptedStreamingProvider(interruptedStreamChunks(), fails: fails, prelude: prelude)
        let executor = RecordingExecutor(.filled("same result"))
        let engine = IOSAgentToolEngine(provider: provider, executors: ["echo": executor], configuration: .init(maxSteps: 8))
        let setting = makePromptTranscriptProviderSetting()
        let params = makePromptTranscriptParams().replacingTools(ToolKt.iosToolDeclarations(names: ["search_web"]))
        let messages = [userMessage("ask")]
        let task = Task {
            await engine.run(providerSetting: setting, messages: messages, params: params,
                             prepareRequestMessages: { messages in
                [PromptTranscript.shared.sectionMessage(name: "system", text: "stable instructions")] + messages
            })
        }
        while !provider.didEmit { await Task.yield() }
        if !fails { task.cancel() }
        let result = await task.value
        guard let partial = result.messages.last(where: {
            $0.parts.compactMap { ($0 as? UIMessagePart.Text)?.text } == ["正文", "尾段"]
        }) else {
            return XCTFail("guard finalization must retain its interrupted assistant")
        }
        XCTAssertNotNil(PromptTranscript.shared.event(message: partial))
        XCTAssertFalse(partial.parts.contains { $0 is UIMessagePart.Tool })
        XCTAssertEqual(partial.parts.compactMap { ($0 as? UIMessagePart.Reasoning)?.reasoning }.joined(), "思考尾推理")
        XCTAssertTrue(result.guardStopped)
        XCTAssertEqual(result.wasCancelled, !fails)
        XCTAssertEqual(executor.calls.count, 2, "guard-stopped third call and partial finalization call must not execute")
        XCTAssertEqual(provider.toolCatalogs.count, 4)
        XCTAssertFalse(provider.toolCatalogs.first?.isEmpty ?? true)
        XCTAssertEqual(provider.toolCatalogs.last, [])
    }

    func testStreamingRequestPreparationRunsBeforeDispatch() async {
        let provider = PreparingStreamingProvider()
        let engine = IOSAgentToolEngine(provider: provider, executors: [:])

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("ask")],
            params: makeParams(tools: [])
        )

        XCTAssertEqual(provider.streamedAPIKey, "prepared-token")
        XCTAssertEqual(result.messages.last?.toText(), "streamed")
    }

    func testGrokWebRouteDoesNotEnterKMPStreamingDispatch() {
        let adapter = OpenAIKmpProviderAdapter()

        XCTAssertFalse(adapter.supportsStreaming(providerSetting: makeGrokProviderSetting()))
    }

    func testGrokWebGenerationUsesNativeGenerator() async {
        let adapter = OpenAIKmpProviderAdapter { _, _, _ in
            throw GrokStubError.invoked
        }

        do {
            _ = try await adapter.generateText(
                providerSetting: makeGrokProviderSetting(),
                messages: [userMessage("ask")],
                params: makeParams(tools: [])
            )
            XCTFail("Expected the native Grok generator to be invoked")
        } catch GrokStubError.invoked {
            // Expected: Grok must not fall through to the OpenAI KMP adapter.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

}
