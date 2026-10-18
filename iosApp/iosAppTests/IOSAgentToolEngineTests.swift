import XCTest
@preconcurrency import Shared
@testable import iosApp


/// Multi-turn execution, approval, request snapshots, and tool exposure.
final class IOSAgentToolEngineTests: IOSAgentToolEngineTestCase {
    // MARK: - Tests

    func testLoopExecutesThenTerminatesWhenNoToolCallsRemain() async {
        // script: [tool_call(echo, "{}"), text("done")]
        let provider = ScriptedProvider([
            toolCallMessage(toolCallId: "tc-1", toolName: "echo", input: "{}"),
            assistantText("done")
        ])
        let executor = RecordingExecutor(.filled("{\"ok\":true}"))
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["echo": executor],
            configuration: .init(maxSteps: 4)
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("hi")],
            params: makeParams(tools: ["echo"])
        )

        XCTAssertEqual(provider.callCount, 2, "engine should call provider once for the tool turn and once for the final text turn")
        XCTAssertEqual(executor.calls.count, 1)
        XCTAssertEqual(executor.calls.first?.name, "echo")
        XCTAssertNil(result.pendingApproval)
        XCTAssertFalse(result.hitStepLimit)
        XCTAssertEqual(result.stepsExecuted, 2)
        // Final message is the "done" assistant turn.
        let last = result.messages.last
        XCTAssertEqual(last?.role, MessageRole.assistant)
        XCTAssertTrue(last?.parts.first is UIMessagePart.Text)
    }

    func testEveryProviderRoundRecordsPreparedRequestSnapshot() async {
        let provider = ScriptedProvider([
            toolCallMessage(toolCallId: "tc-1", toolName: "echo", input: "{}"),
            assistantText("done"),
        ])
        let ledger = RecordingLedger()
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["echo": RecordingExecutor(.filled("{\"ok\":true}"))],
            configuration: .init(maxSteps: 4),
            ledger: ledger,
            ledgerRunId: "request-snapshot-run"
        )
        let compact = makeMessage(
            role: MessageRole.system,
            parts: [UIMessagePart.Text(
                text: "[Conversation compact handoff: compact-42]\n\nsummary",
                metadata: nil
            )]
        )
        let compactBox = IOSMailboxDrainResult(values: [compact])

        _ = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("private request text")],
            params: makeParams(tools: ["echo"]),
            prepareRequestMessages: { messages in compactBox.values + messages }
        )

        let snapshots = await ledger.snapshots()
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(snapshots.map(\.roundIndex), [1, 2])
        XCTAssertEqual(snapshots.map(\.compactionRefs), [["compact-42"], ["compact-42"]])
        // This fixture intentionally cannot construct a bridged Kotlin Tool,
        // so the actual outbound tool catalog is empty even though the scripted
        // provider returns an `echo` call.
        XCTAssertEqual(snapshots.map(\.toolNames), [[], []])
        XCTAssertTrue(snapshots.allSatisfy { $0.toolCatalogDigest.count == 64 })
        XCTAssertNotEqual(snapshots[0].requestDigest, snapshots[1].requestDigest)
        XCTAssertTrue(snapshots.allSatisfy { $0.requestDigest.count == 64 })
    }

    func testRequestSnapshotWriteFailurePreventsProviderInvocation() async {
        let provider = ScriptedProvider([assistantText("must not run")])
        let ledger = RecordingLedger(requestSnapshotResult: false)
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: [:],
            ledger: ledger,
            ledgerRunId: "request-snapshot-failure"
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("hello")],
            params: makeParams(tools: [])
        )

        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(result.providerFailureMessage, "request snapshot ledger write failed")
    }

    func testNativePromptTranscriptAttachesTransitionToAssistantAndReplaysNextRound() async {
        let provider = ParamsRecordingProvider([
            toolCallMessage(toolCallId: "tc-1", toolName: "echo", input: "{}"),
            assistantText("second"),
        ])
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["echo": RecordingExecutor(.filled("{\"ok\":true}"))]
        )
        let result = await engine.run(
            providerSetting: makePromptTranscriptProviderSetting(),
            messages: [userMessage("hello")],
            params: makePromptTranscriptParams(),
            prepareRequestMessages: { messages in
                [PromptTranscript.shared.sectionMessage(name: "system", text: "stable instructions")] + messages
            }
        )

        XCTAssertNil(result.providerFailureMessage)
        guard let assistant = result.messages.first(where: { $0.role == MessageRole.assistant }) else {
            return XCTFail("native transcript test must produce an assistant response")
        }
        XCTAssertNotNil(PromptTranscript.shared.event(message: assistant))
        guard provider.recordedMessages.count >= 2 else {
            return XCTFail("tool round must be followed by a second provider round")
        }
        XCTAssertTrue(
            provider.recordedMessages[1].contains { message in
                message.role == MessageRole.system && message.toText().contains("amber_section")
            }
        )
    }

    @MainActor
    func testApprovalToolResultPreservesPromptTranscriptEventOnPureToolAssistant() {
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(),
            localToolExecutor: nil,
            searchTransport: IOSURLSessionSearchHTTPTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] })
        )
        let user = userMessage("approve this")
        let prepared = PromptTranscript.shared.prepare(
            canonicalMessages: [user],
            preparedMessages: [
                PromptTranscript.shared.sectionMessage(name: "system", text: "stable instructions"),
                user,
            ],
            tools: []
        )
        let toolMessage = toolCallMessage(toolCallId: "approval-tool", toolName: "search_web", input: "{}")
        let recorded = PromptTranscript.shared.recordResponse(message: toolMessage, request: prepared)
        let target = recorded.parts.compactMap { $0 as? UIMessagePart.Tool }.first!

        let finished = runtime.messagesByFinishingToolCall(
            target,
            outputText: #"{"ok":true}"#,
            in: [user, recorded]
        )

        guard let assistant = finished.last(where: { $0.role == MessageRole.assistant }) else {
            return XCTFail("approval finisher must retain the assistant tool message")
        }
        XCTAssertNotNil(PromptTranscript.shared.event(message: assistant))
        XCTAssertFalse(
            assistant.parts.compactMap { $0 as? UIMessagePart.Tool }.first?.output.isEmpty ?? true
        )
    }

    func testProviderFailureIsExposedWithoutParsingTheTranscript() async {
        let engine = IOSAgentToolEngine(provider: ThrowingProvider(), executors: [:])

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("hello")],
            params: makeParams(tools: [])
        )

        XCTAssertEqual(result.providerFailureMessage, "upstream unavailable")
        XCTAssertFalse(result.hitOutputLimit)
        XCTAssertTrue(result.messages.last?.toText().contains("[engine] provider error") == true)
    }

    func testToolOutputFilledInPlaceWithExecutorResult() async {
        let provider = ScriptedProvider([
            toolCallMessage(toolCallId: "tc-1", toolName: "echo", input: "{\"q\":\"x\"}"),
            assistantText("after")
        ])
        let executor = RecordingExecutor(.filled("{\"answer\":42}"))
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["echo": executor],
            configuration: .init(maxSteps: 4)
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("ask")],
            params: makeParams(tools: ["echo"])
        )

        // The tool-call assistant message (now second in the list, after the
        // user message) must have its tool output filled.
        let toolMessage = result.messages[1]
        let toolPart = toolMessage.parts.compactMap { $0 as? UIMessagePart.Tool }.first
        XCTAssertNotNil(toolPart)
        XCTAssertFalse(toolPart?.output.isEmpty ?? true, "tool output must be filled after execution")
        let outputText = toolPart?.output.compactMap { $0 as? UIMessagePart.Text }.first?.text
        XCTAssertEqual(outputText, "{\"answer\":42}")
    }

    @MainActor
    func testForegroundProviderCreateRedactsCanonicalInputAndNextRequest() async throws {
        let defaults = UserDefaults(suiteName: "ProviderEngine-\(UUID().uuidString)")!
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(userDefaults: defaults), sharedSettings: store,
            localToolExecutor: nil, searchTransport: IOSURLSessionSearchHTTPTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] })
        )
        let secret = "sk-test-engine-private-key"
        let call = toolCallMessage(
            toolCallId: "create-provider", toolName: "provider_config_create",
            input: #"{"name":"Engine Provider","base_url":"https://example.test/v1","api_key":"\#(secret)"}"#
        )
        let messages = [userMessage("configure"), call]
        let provider = ParamsRecordingProvider([call, assistantText("done")])
        let params = makeParams(tools: []).replacingTools(
            ToolKt.iosToolDeclarations(names: ["provider_config_create"])
        )
        let executors = runtime.foregroundToolExecutors(
            providerSetting: makeProviderSetting(), params: params,
            runId: "provider-engine", startedAt: 1, inputDigest: "test", conversationId: nil,
            toolExposureBridge: nil, baseMessagesProvider: { messages },
            approvalPromptBox: ChatToolRuntime.IOSForegroundApprovalPromptBox(),
            executionPolicy: IOSExecutionPolicySnapshot(
                capabilityPolicies: [:], globalAutoApproveEnabled: false,
                highRiskAutoApproveEnabled: true, execJavaScriptEnabled: false, webSearchEnabled: false
            )
        )
        let engine = IOSAgentToolEngine(provider: provider, executors: executors)
        let result = await engine.run(
            providerSetting: makeProviderSetting(), messages: [messages[0]], params: params
        )
        let saved = try XCTUnwrap(store.snapshot.providers.first { $0.name == "Engine Provider" } as? ProviderSetting.OpenAI)
        defer { _ = store.removeProvider(providerId: saved.id.description()) }
        XCTAssertEqual(saved.apiKey, secret, "execution must still receive the original key")
        XCTAssertEqual(provider.recordedMessages.count, 2)
        for transcript in [result.messages, try XCTUnwrap(provider.recordedMessages.last)] {
            let tool = try XCTUnwrap(transcript.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }.first)
            XCTAssertFalse(tool.input.contains(secret))
            XCTAssertTrue(tool.input.contains("****"))
        }
    }

    func testMultipleToolCallsInOneTurnAreAllExecutedBeforeNextRound() async {
        // One assistant turn carrying TWO tool calls, then a final text turn.
        let twoToolMessage = makeMessage(
            role: MessageRole.assistant,
            parts: [
                UIMessagePart.Tool(toolCallId: "a", toolName: "echo", input: "{}", output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil),
                UIMessagePart.Tool(toolCallId: "b", toolName: "echo", input: "{}", output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)
            ]
        )
        let provider = ScriptedProvider([twoToolMessage, assistantText("done")])
        let executor = RecordingExecutor(.filled("{\"ok\":true}"))
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["echo": executor],
            configuration: .init(maxSteps: 4)
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("both")],
            params: makeParams(tools: ["echo"])
        )

        XCTAssertEqual(executor.calls.count, 2, "both tool calls in the turn must execute")
        let toolMessage = result.messages[1]
        let toolParts = toolMessage.parts.compactMap { $0 as? UIMessagePart.Tool }
        XCTAssertEqual(toolParts.count, 2)
        XCTAssertTrue(toolParts.allSatisfy { !$0.output.isEmpty }, "both tool outputs must be filled")
    }

    func testHitStepLimitWhenModelKeepsEmittingToolCalls() async {
        // Script always returns a fresh tool call (queue of 10 > maxSteps 3).
        // Arguments differ per call (`{"i":N}`) so this exercises step-limit
        // exhaustion specifically — with identical arguments, IOSToolLoopGuard
        // (I-5) would now stop the run on the 3rd repeat before maxSteps is
        // ever reached, which is a different (and separately tested) terminal.
        let endless = (0..<10).map { toolCallMessage(toolCallId: "tc-\($0)", toolName: "echo", input: "{\"i\":\($0)}") }
        let provider = ScriptedProvider(endless)
        let executor = RecordingExecutor(.filled("{}"))
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["echo": executor],
            configuration: .init(maxSteps: 3)
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("loop")],
            params: makeParams(tools: ["echo"])
        )

        XCTAssertTrue(result.hitStepLimit, "engine must stop at maxSteps when tool calls keep coming")
        XCTAssertEqual(result.stepsExecuted, 3)
    }

    func testApprovalPauseSurfacesPendingApprovalAndStopsLoop() async {
        let provider = ScriptedProvider([
            toolCallMessage(toolCallId: "tc-1", toolName: "sensitive", input: "{}"),
            assistantText("should-not-reach")
        ])
        let executor = RecordingExecutor(.needsApproval("requires foreground confirmation"))
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["sensitive": executor],
            configuration: .init(maxSteps: 4, honorApprovalPause: true)
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("ask")],
            params: makeParams(tools: ["sensitive"])
        )

        XCTAssertEqual(provider.callCount, 1, "loop must stop after the approval-requesting turn")
        XCTAssertEqual(result.pendingApproval?.toolName, "sensitive")
        XCTAssertEqual(result.pendingApproval?.reason, "requires foreground confirmation")
        XCTAssertFalse(result.hitStepLimit)
    }

    func testApprovalPausePreservesEarlierOutputsFromSameBatch() async {
        let mixedToolMessage = makeMessage(
            role: MessageRole.assistant,
            parts: [
                UIMessagePart.Tool(
                    toolCallId: "search",
                    toolName: "search_web",
                    input: "{}",
                    output: [],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                ),
                UIMessagePart.Tool(
                    toolCallId: "approval",
                    toolName: "ask_user",
                    input: "{}",
                    output: [],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                )
            ]
        )
        let provider = ScriptedProvider([mixedToolMessage, assistantText("should-not-reach")])
        let searchExecutor = RecordingExecutor(.filled("{\"results\":[\"source\"]}"))
        let approvalExecutor = RecordingExecutor(.needsApproval("requires user choice"))
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: [
                "search_web": searchExecutor,
                "ask_user": approvalExecutor
            ],
            configuration: .init(maxSteps: 4, honorApprovalPause: true)
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("search, then ask")],
            params: makeParams(tools: ["search_web", "ask_user"])
        )

        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(searchExecutor.calls.count, 1)
        XCTAssertEqual(approvalExecutor.calls.count, 1)
        XCTAssertEqual(result.pendingApproval?.toolName, "ask_user")

        let toolParts = result.messages[1].parts.compactMap { $0 as? UIMessagePart.Tool }
        let searchOutput = toolParts
            .first { $0.toolCallId == "search" }?
            .output.compactMap { $0 as? UIMessagePart.Text }.first?.text
        let approvalOutput = toolParts.first { $0.toolCallId == "approval" }?.output
        XCTAssertEqual(searchOutput, "{\"results\":[\"source\"]}")
        XCTAssertTrue(approvalOutput?.isEmpty == true)
    }

    func testDeniedAndFailedToolsProduceHonestOutputNotApproval() async throws {
        let twoToolMessage = makeMessage(
            role: MessageRole.assistant,
            parts: [
                UIMessagePart.Tool(toolCallId: "d", toolName: "deniedTool", input: "{}", output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil),
                UIMessagePart.Tool(toolCallId: "f", toolName: "failedTool", input: "{}", output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)
            ]
        )
        let provider = ScriptedProvider([twoToolMessage, assistantText("done")])
        let deniedExecutor = RecordingExecutor(.denied("policy blocks this"))
        let failedExecutor = RecordingExecutor(.failed("network down"))
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["deniedTool": deniedExecutor, "failedTool": failedExecutor],
            configuration: .init(maxSteps: 4)
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("ask")],
            params: makeParams(tools: ["deniedTool", "failedTool"])
        )

        XCTAssertNil(result.pendingApproval, "denial/failure must not pause the loop")
        let toolMessage = result.messages[1]
        let toolParts = toolMessage.parts.compactMap { $0 as? UIMessagePart.Tool }
        for (id, reason, status) in [("d", "policy blocks this", "denied"), ("f", "network down", "failed")] {
            let tool = try XCTUnwrap(toolParts.first { $0.toolCallId == id })
            let text = try XCTUnwrap((tool.output.first as? UIMessagePart.Text)?.text)
            let data = try XCTUnwrap(text.data(using: .utf8))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(payload["ok"] as? Bool, false)
            XCTAssertEqual(payload["status"] as? String, status)
            XCTAssertEqual(ChatToolOutputFormatter.failureReason(from: tool.output), reason)
        }
    }

    func testUnregisteredToolProducesFailureOutput() async {
        let provider = ScriptedProvider([
            toolCallMessage(toolCallId: "tc-1", toolName: "ghost", input: "{}"),
            assistantText("done")
        ])
        // No executor registered for "ghost".
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: [:],
            configuration: .init(maxSteps: 4)
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("ask")],
            params: makeParams(tools: ["ghost"])
        )

        let toolPart = result.messages[1].parts.compactMap { $0 as? UIMessagePart.Tool }.first
        XCTAssertNotNil(toolPart)
        XCTAssertEqual(
            ChatToolOutputFormatter.failureReason(from: toolPart?.output ?? []),
            "[engine] no executor registered for tool `ghost`"
        )
    }

    func testToolSearchHitIsDeclaredOnNextEngineRoundViaRunBridge() async {
        let declarations = fullIosDeclarations()
        let bridge = IosToolExposureBridge(tools: declarations)
        XCTAssertTrue(bridge.lazyModeEnabled())
        XCTAssertFalse(bridge.visibleTools().map(\.name).contains("wm_type"))

        // Round 1: the model calls tool_search (executed locally through the
        // real bridge, which exposes wm_type). Round 2: plain text "done".
        let provider = ParamsRecordingProvider([
            toolCallMessage(toolCallId: "ts-1", toolName: "tool_search", input: #"{"query":"wm_type","limit":1}"#),
            assistantText("done")
        ])
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: ["tool_search": BridgeToolSearchExecutor(bridge: bridge)]
        )
        let model = Model(
            modelId: "engine-exposure-test",
            displayName: "engine-exposure-test",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        let params = TextGenerationParams(
            model: model,
            temperature: nil,
            topP: nil,
            maxTokens: nil,
            tools: bridge.visibleTools(),
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("use wm_type")],
            params: params,
            toolExposureBridge: bridge
        )

        XCTAssertNil(result.pendingApproval)
        XCTAssertFalse(result.wasCancelled)
        XCTAssertFalse(result.hitStepLimit)
        XCTAssertGreaterThanOrEqual(provider.recordedParams.count, 2, "engine must run a second model round after tool_search")
        let secondRoundNames = Set(provider.recordedParams[1].tools.map(\.name))
        XCTAssertTrue(
            secondRoundNames.contains("wm_type"),
            "the tool_search hit must be declared on the NEXT engine round's params"
        )
        XCTAssertTrue(secondRoundNames.contains("wm_visual_read"))
        XCTAssertFalse(secondRoundNames.contains("wm_screenshot"))
        XCTAssertFalse(
            result.messages.contains { message in
                message.parts.contains { ($0 as? UIMessagePart.Tool)?.output.isEmpty == true }
            },
            "all tool calls must be filled before the engine stops"
        )
    }

    // MARK: - M2: 每轮 replacingTools 后 executor 表重建（命中工具下一轮可执行）

    /// 红测试对应缺陷：executors 在 job 启动时按初始 params 注册一次，P0-a Fix C
    /// 每轮刷新 params 后命中工具「可声明不可执行」（[engine] no executor registered）。
    /// 修复后：传了 toolExposureBridge + executorRebuilder 的路径每轮重建表，
    /// mock 宿主断言第二轮 wm_type 真实被调用。
    func testExposedToolGetsExecutorOnNextRoundViaRebuilder() async {
        let declarations = fullIosDeclarations()
        let bridge = IosToolExposureBridge(tools: declarations)
        XCTAssertTrue(bridge.lazyModeEnabled())
        XCTAssertFalse(bridge.visibleTools().map(\.name).contains("wm_type"))

        // 第一轮 tool_search 命中 wm_type；第二轮模型直接调 wm_type；第三轮收尾。
        let provider = ParamsRecordingProvider([
            toolCallMessage(toolCallId: "ts-1", toolName: "tool_search", input: #"{"query":"wm_type","limit":1}"#),
            toolCallMessage(toolCallId: "wm-1", toolName: "wm_type", input: #"{"keys":"hello"}"#),
            assistantText("done")
        ])
        let wmTypeExecutor = RecordingExecutor(.filled("{\"ok\":true,\"typed\":true}"))
        // 与后台协调器同构的注册入口：按当轮 params.tools 注册（闭包捕获当轮 params）。
        let rebuilder: (TextGenerationParams) -> [String: any IOSToolExecutor] = { params in
            var executors: [String: any IOSToolExecutor] = [:]
            for tool in params.tools {
                if tool.name == "tool_search" {
                    executors["tool_search"] = BridgeToolSearchExecutor(bridge: bridge)
                } else if tool.name == "wm_type" {
                    executors["wm_type"] = wmTypeExecutor
                }
            }
            return executors
        }
        // 初始 params = 首轮可见工具（后台 handoff 同构：tool_search 在列）。
        let initialParams = TextGenerationParams(
            model: Model(
                modelId: "engine-m2-test",
                displayName: "engine-m2-test",
                id: KotlinUuid.companion.random(),
                type: ModelType.chat,
                customHeaders: [],
                customBodies: [],
                inputModalities: [],
                outputModalities: [],
                abilities: [],
                tools: Set<BuiltInTools>(),
                contextWindowTokens: nil,
                providerOverwrite: nil
            ),
            temperature: KotlinFloat(value: 0.7),
            topP: nil,
            maxTokens: nil,
            tools: bridge.visibleTools(),
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: rebuilder(initialParams),
            configuration: .init(maxSteps: 6, honorApprovalPause: false),
            executorRebuilder: rebuilder
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [userMessage("use wm_type")],
            params: initialParams,
            toolExposureBridge: bridge
        )

        XCTAssertNil(result.pendingApproval)
        XCTAssertFalse(result.wasCancelled)
        XCTAssertFalse(result.hitStepLimit)
        XCTAssertGreaterThanOrEqual(provider.recordedParams.count, 3, "引擎必须跑三轮：tool_search → wm_type → 终答")
        XCTAssertEqual(
            wmTypeExecutor.calls.count, 1,
            "tool_search 命中后下一轮该工具必须声明且可执行（mock 宿主断言真实调用），实际: \(wmTypeExecutor.calls.count)"
        )
        XCTAssertEqual(wmTypeExecutor.calls.first?.name, "wm_type")
        XCTAssertFalse(
            result.messages.contains { message in
                message.parts.contains { ($0 as? UIMessagePart.Tool)?.output.isEmpty == true }
            },
            "所有工具调用必须填满（wm_type 不得落 [engine] no executor registered）"
        )
        let allOutput = result.messages.flatMap { message in
            message.parts.compactMap { ($0 as? UIMessagePart.Tool)?.output.compactMap { ($0 as? UIMessagePart.Text)?.text } }
        }.flatMap { $0 }.joined()
        XCTAssertFalse(allOutput.contains("no executor registered"), "命中工具不得走未注册失败")
        XCTAssertTrue(allOutput.contains("\"typed\":true"), "wm_type 必须真实执行并回灌结果")
    }

    func testImageFailureReasonIgnoresSuccessfulImageOutputJSON() {
        let output: [UIMessagePart] = [
            UIMessagePart.Image(url: "amber-image://image-generation/file.png", metadata: nil),
            UIMessagePart.Text(
                text: #"{"count":1,"files":[{"url":"amber-image://image-generation/file.png"}],"source":"generate_image","status":"ok"}"#,
                metadata: nil
            )
        ]

        XCTAssertNil(ChatToolOutputFormatter.imageFailureReason(from: output))
    }

    func testImageFailureReasonKeepsExplicitFailureJSON() {
        let output: [UIMessagePart] = [
            UIMessagePart.Text(
                text: #"{"ok":false,"reason":"图片生成服务没有返回图片。","tool":"generate_image"}"#,
                metadata: nil
            )
        ]

        XCTAssertEqual(ChatToolOutputFormatter.imageFailureReason(from: output), "图片生成服务没有返回图片。")
    }

}
