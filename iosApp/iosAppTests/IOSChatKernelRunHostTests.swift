import XCTest
@preconcurrency import Shared
@testable import iosApp

/// P0-2 B1:kernel Host(`ChatKernelRunHost`)的生命周期序列钉测试。
///
/// 这里钉「Host 把适配器回调接到真实副作用的序列」——暂停(markRunAwaitingPermission
/// 先于发卡、等待期 isLoading=false、脱敏快照先持久化)、恢复(resume 认领 +
/// 续跑)、三种终态(completed/failed/cancelled)各自的 CGC 对齐序列。
///
/// 复用前台 harness 的录制 bindings/依赖(同一装配);provider 是剧本化
/// generateText(引擎对非流式 provider 有回退,IOSAgentToolEngine :670)。
@MainActor
final class IOSChatKernelRunHostTests: XCTestCase {

    private typealias F = IOSChatForegroundFixtures

    // MARK: - 剧本化 provider

    /// generateText 轮次剧本。
    private final class HostScriptedProvider: IOSAgentTextProvider, @unchecked Sendable {
        struct Round {
            let message: UIMessage
            let finishReason: String
        }

        private let lock = NSLock()
        private var rounds: [Round]
        private var uploads: [[UIMessage]] = []

        init(rounds: [Round]) {
            self.rounds = rounds
        }

        var callCount: Int { lock.withLock { uploads.count } }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            let round = lock.withLock { () -> Round in
                uploads.append(messages)
                return rounds.isEmpty
                    ? Round(message: F.assistantText("stop"), finishReason: "stop")
                    : rounds.removeFirst()
            }
            return F.chunk(with: round.message, finishReason: round.finishReason)
        }
    }

    private final class HostBlockingProvider: IOSAgentTextProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0

        var callCount: Int { lock.withLock { calls } }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            lock.withLock { calls += 1 }
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return F.chunk(with: F.assistantText("unreachable"))
        }
    }

    private final class HostBlockingSearchTransport: IOSSearchHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0

        var callCount: Int { lock.withLock { calls } }

        func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            lock.withLock { calls += 1 }
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return (
                IOSForegroundNoopSearchTransport.okResponse(for: request),
                Data(IOSForegroundNoopSearchTransport.resultHTML.utf8)
            )
        }
    }

    @MainActor
    private final class ImageExecutionGate {
        var started = false
        var released = false
    }

    // MARK: - 具装

    private func makeHarness(
        exposedToolNames: [String] = [],
        searchTransport: any IOSSearchHTTPTransport = IOSForegroundNoopSearchTransport(),
        chatMaxToolResumeCount: Int? = nil
    ) -> IOSChatForegroundHarness {
        // Host 不驱动 CGC;harness 的 rounds 剧本留空(dispatch 不启动)。
        IOSChatForegroundHarness(
            exposedToolNames: exposedToolNames,
            searchTransport: searchTransport,
            chatMaxToolResumeCount: chatMaxToolResumeCount
        )
    }

    private func makeHost(
        harness: IOSChatForegroundHarness,
        provider: IOSAgentTextProvider
    ) -> ChatKernelRunHost {
        ChatKernelRunHost(
            dependencies: harness.dependencies,
            bindings: harness.bindings,
            backgroundExecution: harness.keepAlive,
            toolLedger: harness.ledger,
            textProvider: provider
        )
    }

    private func start(_ host: ChatKernelRunHost, harness: IOSChatForegroundHarness) {
        host.start(
            providerSetting: harness.providerSetting,
            params: harness.params,
            inputDigest: "kernel-host-test",
            conversationId: harness.conversationId,
            uploadMessages: harness.messages,
            toolExposureBridge: harness.toolExposureBridge
        )
    }

    private func toolRound(_ toolCallId: String, _ toolName: String, _ input: String) -> HostScriptedProvider.Round {
        HostScriptedProvider.Round(
            message: F.assistantMessage(parts: [
                UIMessagePart.Tool(
                    toolCallId: toolCallId,
                    toolName: toolName,
                    input: input,
                    output: [],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                ),
            ]),
            finishReason: "stop"
        )
    }

    private func textRound(_ text: String) -> HostScriptedProvider.Round {
        HostScriptedProvider.Round(message: F.assistantText(text), finishReason: "stop")
    }

    // MARK: - 等待器

    private func waitForHostIdle(_ host: ChatKernelRunHost, timeoutSeconds: Double = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !host.isRunning { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func waitForCondition(
        timeoutSeconds: Double = 10,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    // MARK: - 完成终态

    /// completed 序列(CG-C :2732-2797 + finishStreaming :4919-4979):
    /// recordRun(completed) → handleSteerQueueAtTerminal(autoContinue: true) →
    /// generationSucceeded → onRunTerminal;无 composer 回填。
    func testCompletedRunTerminalSequence() async {
        let harness = makeHarness()
        var succeededCount = 0
        var restoreLeftoverCount = 0
        var terminalReports: [(runId: String, messageCount: Int)] = []
        harness.bindings.generationSucceeded = { succeededCount += 1 }
        harness.bindings.restoreSteerQueueLeftover = { _ in restoreLeftoverCount += 1 }
        harness.bindings.onRunTerminal = { _, runId, finalMessages in
            terminalReports.append((runId, finalMessages.count))
        }
        let provider = HostScriptedProvider(rounds: [textRound("你好，世界")])
        let host = makeHost(harness: harness, provider: provider)

        start(host, harness: harness)

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, "completed")
        let idleAfterComplete = await waitForHostIdle(host)
        XCTAssertTrue(idleAfterComplete, "run 必须收尾(isRunning 清空)")
        XCTAssertFalse(harness.isLoading)
        XCTAssertEqual(harness.terminalSteerAutoContinue, [true], "成功收尾自动续发队列")
        XCTAssertEqual(succeededCount, 1)
        XCTAssertEqual(restoreLeftoverCount, 0, "completed 不做 composer 回填(那是 cancel 语义)")
        let terminalReported = await waitForCondition { !terminalReports.isEmpty }
        XCTAssertTrue(terminalReported, "onRunTerminal 必须回传")
        XCTAssertEqual(terminalReports.first?.runId, harness.capturedRunId)
        XCTAssertEqual(
            harness.capturedRunProtocolContext?.providerId,
            harness.providerSetting.id.description()
        )
        XCTAssertEqual(harness.capturedRunProtocolContext?.modelId, harness.params.model.modelId)
        XCTAssertEqual(
            harness.capturedRunProtocolContext?.toolCatalogVersion,
            chatInputDigest(
                for: IosRunRequestSnapshotJsonBridge.shared.encodeToolCatalog(tools: harness.params.tools)
            )
        )
        XCTAssertNil(harness.capturedRunProtocolContext?.promptVersion)
        XCTAssertEqual(harness.messages.last?.toText(), "你好，世界")
        XCTAssertEqual(provider.callCount, 1)
    }

    // MARK: - 审批暂停/恢复

    /// 暂停纪律(CG-C pauseForApproval :3798-3873):markRunAwaitingPermission
    /// 先于发卡、发卡前脱敏快照已持久化、等待期 isLoading=false;
    /// 恢复(approve):runResumed 认领 + 账本 Finished(completed) + 续跑第二轮。
    func testSearchApprovalPauseThenApprove() async {
        let harness = makeHarness()
        let provider = HostScriptedProvider(rounds: [
            toolRound("tc-1", "search_web", #"{"query":"amber"}"#),
            textRound("完成"),
        ])
        let host = makeHost(harness: harness, provider: provider)
        start(host, harness: harness)

        let approval = await harness.waitForPendingSearchApproval()
        XCTAssertNotNil(approval, "审批卡必须发布")
        let snapshot = harness.log.snapshot()
        guard let markIndex = snapshot.firstIndex(where: {
            if case .runAwaitingPermission(let toolCallId) = $0 { return toolCallId == "tc-1" }
            return false
        }), let cardIndex = snapshot.firstIndex(where: {
            if case .approvalRequested(let kind) = $0 { return kind == "search" }
            return false
        }) else {
            return XCTFail("暂停序列缺事件: \(snapshot)")
        }
        XCTAssertLessThan(markIndex, cardIndex, "markRunAwaitingPermission 必须先于发卡(CG-C :3800 先于 :3873)")
        XCTAssertFalse(harness.isLoading, "等人期间必须摘掉加载态(CG-C :3854)")
        XCTAssertFalse(harness.persistedSnapshots.isEmpty, "脱敏快照必须在发卡前持久化(CG-C :3820)")
        XCTAssertTrue(host.hasPendingToolApproval)

        host.approvePendingSearchTool()

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, "completed")
        let idleAfterApprove = await waitForHostIdle(host)
        XCTAssertTrue(idleAfterApprove)
        let after = harness.log.snapshot()
        XCTAssertTrue(after.contains(.runResumed), "resume 绑定必须认领(CG-C claimRunAfterPermission)")
        XCTAssertTrue(after.contains(.toolCallFinished(tool: "search_web", outcome: "completed")))
        XCTAssertEqual(provider.callCount, 2, "批准后必须续跑第二轮模型")
        XCTAssertNil(harness.pendingSearchApproval, "入口消费后卡槽必须清空")
        XCTAssertEqual(harness.messages.last?.toText(), "完成")
    }

    /// 拒绝路径:账本 Finished(denied) + approvalDenied 落地,循环照常续跑
    /// 到 completed(CG-C executeApprovedAsyncTool :4463-4471)。
    func testSearchApprovalDenyContinuesAndCompletes() async {
        let harness = makeHarness()
        let provider = HostScriptedProvider(rounds: [
            toolRound("tc-1", "search_web", #"{"query":"amber"}"#),
            textRound("已记录"),
        ])
        let host = makeHost(harness: harness, provider: provider)
        start(host, harness: harness)

        let approval = await harness.waitForPendingSearchApproval()
        XCTAssertNotNil(approval)
        host.denyPendingSearchTool()

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, "completed")
        let idleAfterDeny = await waitForHostIdle(host)
        XCTAssertTrue(idleAfterDeny)
        let log = harness.log.snapshot()
        XCTAssertTrue(log.contains(.runResumed), "deny 也经 resume 认领(CG-C :4443 对 allow/deny 同路径)")
        XCTAssertTrue(log.contains(.toolCallFinished(tool: "search_web", outcome: "denied")))
        // approvalDenied 由 runtime recordToolApproval 的 fire-and-forget 漏斗
        // 写入(与 Finished 的相邻次序本就调度相关),这里轮询等待而不是即时断言。
        let deniedLanded = await waitForCondition {
            harness.log.snapshot().contains(.approvalDenied(tool: "search_web"))
        }
        XCTAssertTrue(deniedLanded, "approvalDenied 必须落地")
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(harness.messages.last?.toText(), "已记录")
    }

    // MARK: - 取消

    /// 审批等待中取消(CG-C cancel 尾 :1501-1581):填充未决工具、清卡、
    /// restoreSteerQueueLeftover(非 handleSteerQueueAtTerminal)、终态
    /// cancelled 只报一次、第二轮绝不开跑。
    func testCancelDuringApprovalWait() async {
        let harness = makeHarness()
        var restoreLeftoverCount = 0
        var succeededCount = 0
        harness.bindings.restoreSteerQueueLeftover = { _ in restoreLeftoverCount += 1 }
        harness.bindings.generationSucceeded = { succeededCount += 1 }
        let provider = HostScriptedProvider(rounds: [
            toolRound("tc-1", "search_web", #"{"query":"amber"}"#),
            textRound("不应到达"),
        ])
        let host = makeHost(harness: harness, provider: provider)
        start(host, harness: harness)

        let approval = await harness.waitForPendingSearchApproval()
        XCTAssertNotNil(approval)
        XCTAssertTrue(host.hasPendingToolApproval)

        host.cancel()

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, "cancelled")
        let idleAfterCancel = await waitForHostIdle(host)
        XCTAssertTrue(idleAfterCancel)
        XCTAssertFalse(harness.isLoading)
        XCTAssertNil(harness.pendingSearchApproval, "取消必须清卡")
        XCTAssertEqual(restoreLeftoverCount, 1, "cancel 回填 composer(CG-C :1533)")
        XCTAssertEqual(harness.terminalSteerAutoContinue, [], "cancel 不走 handleSteerQueueAtTerminal")
        XCTAssertEqual(succeededCount, 0, "cancel 不发 generationSucceeded")
        let filled = F.toolOutputText(toolCallId: "tc-1", in: harness.messages)
        XCTAssertTrue(filled.contains("User cancelled."), "未决工具必须原地填取消输出,实际: \(filled)")
        XCTAssertEqual(provider.callCount, 1, "第二轮模型绝不开跑")
        let terminals = harness.log.snapshot().filter {
            if case .runTerminal = $0 { return true }
            return false
        }
        XCTAssertEqual(terminals.count, 1, "终态只报一次")
    }

    // MARK: - B2 流式投影

    /// 剧本化流式 provider:按间隔投递 delta chunk 后 onComplete——真实驱动
    /// 引擎 streamStep 的累加器与 provisional 快照钩子。间隔必须大于 Host 的
    /// 投影节流窗口,测试才能在终端前观察到中间态气泡。
    private final class HostScriptedStreamingProvider: IOSAgentTextProvider, IOSAgentStreamingProvider, @unchecked Sendable {
        struct Stream {
            let chunks: [MessageChunk]
            let intervalNanos: UInt64
        }

        private let lock = NSLock()
        private var streams: [Stream]
        private(set) var callCount = 0

        init(streams: [Stream]) { self.streams = streams }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            F.chunk(with: F.assistantText("stop"), finishReason: "stop")
        }

        func streamText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams,
            onChunk: @escaping @Sendable (MessageChunk) -> Void,
            onComplete: @escaping @Sendable () -> Void,
            onError: @escaping @Sendable (KotlinThrowable) -> Void
        ) -> Kotlinx_coroutines_coreJob? {
            let stream = lock.withLock { () -> Stream in
                callCount += 1
                return streams.isEmpty
                    ? Stream(chunks: [F.streamChunk(delta: F.assistantText("stop"))], intervalNanos: 0)
                    : streams.removeFirst()
            }
            Task {
                for chunk in stream.chunks {
                    if stream.intervalNanos > 0 {
                        try? await Task.sleep(nanoseconds: stream.intervalNanos)
                    }
                    onChunk(chunk)
                }
                onComplete()
            }
            return nil
        }
    }

    /// provisional 投影:首片 delta 后、终端前气泡上屏且随增量生长;终态
    /// 消息与 provisional 同 id 原地替换(无重挂/闪烁),streamDelta revision 落账。
    func testStreamingProvisionalBubbleProjection() async {
        let harness = makeHarness()
        let provider = HostScriptedStreamingProvider(streams: [
            HostScriptedStreamingProvider.Stream(
                chunks: [
                    F.streamChunk(delta: F.assistantText("你")),
                    F.streamChunk(delta: F.assistantText("好，世界")),
                ],
                intervalNanos: 150_000_000
            ),
        ])
        let host = makeHost(harness: harness, provider: provider)
        start(host, harness: harness)

        let appeared = await waitForCondition {
            guard let last = harness.messages.last, last.role == MessageRole.assistant else { return false }
            let text = last.toText()
            return text.contains("你") && !text.contains("好")
        }
        XCTAssertTrue(appeared, "首片 delta 必须投影为 provisional 气泡(终态前可见)")
        let provisionalId = harness.messages.last?.id.toHexDashString()

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, "completed")
        let idle = await waitForHostIdle(host)
        XCTAssertTrue(idle)
        XCTAssertEqual(harness.messages.last?.toText(), "你好，世界")
        XCTAssertEqual(
            harness.messages.last?.id.toHexDashString(),
            provisionalId,
            "终态消息必须与 provisional 气泡同 id(引擎终态快照即累加器本体)"
        )
        XCTAssertEqual(
            harness.messages.filter { $0.role == MessageRole.assistant }.count,
            1,
            "provisional → 权威是原地替换,不得多长一条"
        )
        XCTAssertTrue(harness.revisions.contains(.streamDelta), "投影必须打 streamDelta revision")
    }

    /// citation(B1 已接线,这里钉 Host 路径端到端):隐藏标记在入累加器前
    /// 剥离,可见文本无残留;终态把引用 id 以 force 记为已使用。
    func testStreamingCitationStrippedAndUsageRecorded() async {
        let harness = makeHarness()
        var usageRecords: [(ids: [Int32], force: Bool)] = []
        harness.bindings.recordMemoryUsage = { ids, force in
            usageRecords.append((ids, force))
        }
        let provider = HostScriptedStreamingProvider(streams: [
            HostScriptedStreamingProvider.Stream(
                chunks: [
                    F.streamChunk(delta: F.assistantText(#"可见<amber-mem-cite>{"ids":[7]}</amber-mem-cite>"#)),
                ],
                intervalNanos: 0
            ),
        ])
        let host = makeHost(harness: harness, provider: provider)
        start(host, harness: harness)

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, "completed")
        let idle = await waitForHostIdle(host)
        XCTAssertTrue(idle)
        XCTAssertEqual(harness.messages.last?.toText(), "可见", "citation 标记必须剥离,可见文本无残留")
        let citationRecords = usageRecords.filter { $0.ids == [7] }
        XCTAssertEqual(citationRecords.count, 1, "引用 id 7 必须恰好记录一次")
        XCTAssertTrue(citationRecords.first?.force == true, "模型显式引用必须 force(CG-C P2-c 修复 2)")
    }

    // MARK: - 逐轮上传准备

    /// 上传准备(B1 组合点)必须每轮执行:两个模型轮 → 编排链接刷新两次、
    /// 运行时语境注入每轮两次(overhead 基线 + 最终注入,CG-C :1977/:2025)。
    /// session_search 在 nil store 下产出结构化不可用输出,循环继续——
    /// 正好提供一次免审批的工具轮。
    func testUploadPrepRunsEveryRound() async {
        let harness = makeHarness(exposedToolNames: ["session_search"])
        var runtimeInjectionCount = 0
        var orchestrationRefreshCount = 0
        harness.runtimeContextInjector = { messages in
            runtimeInjectionCount += 1
            return messages
        }
        harness.bindings.refreshOrchestrationLinks = {
            orchestrationRefreshCount += 1
        }
        let provider = HostScriptedProvider(rounds: [
            toolRound("tc-1", "session_search", #"{"query":"amber"}"#),
            textRound("完成"),
        ])
        let host = makeHost(harness: harness, provider: provider)
        start(host, harness: harness)

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, "completed")
        let idleAfterPrep = await waitForHostIdle(host)
        XCTAssertTrue(idleAfterPrep)
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(orchestrationRefreshCount, 2, "每轮组装前刷新编排链接缓存(CG-C :2024)")
        XCTAssertEqual(runtimeInjectionCount, 4, "每轮两次注入调用(基线 + 最终)")
    }

    // MARK: - Adapter 组合钩子 / Host 后台交接

    func testAdapterSortsMultiToolBatchAndPreemptsAfterBudget() async {
        let harness = makeHarness(exposedToolNames: ["session_search"])
        let firstBatch = F.assistantMessage(parts: [
            UIMessagePart.Tool(
                toolCallId: "tc-unexposed", toolName: "wm_click", input: "{}",
                output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
            ),
            UIMessagePart.Tool(
                toolCallId: "tc-session", toolName: "session_search", input: #"{"query":"amber"}"#,
                output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
            ),
            UIMessagePart.Tool(
                toolCallId: "tc-search", toolName: "tool_search", input: #"{"query":"session"}"#,
                output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
            ),
        ])
        let limitedBatch = F.assistantMessage(parts: [
            UIMessagePart.Tool(
                toolCallId: "tc-limited", toolName: "session_search", input: #"{"query":"again"}"#,
                output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
            ),
        ])
        let provider = HostScriptedProvider(rounds: [
            .init(message: firstBatch, finishReason: "stop"),
            .init(message: limitedBatch, finishReason: "stop"),
        ])
        let runtime = ChatToolRuntime(
            settingsStore: harness.dependencies.settingsStore,
            sharedSettings: harness.dependencies.sharedSettings,
            localToolExecutor: harness.dependencies.localToolExecutor,
            searchTransport: harness.dependencies.searchTransport,
            mcpManager: harness.dependencies.mcpManager,
            orchestrationToolService: harness.dependencies.orchestrationToolService,
            memoryPollutionMarker: harness.dependencies.memoryPollutionMarker,
            conversationStoreProvider: harness.dependencies.conversationStoreProvider,
            ledger: harness.ledger
        )
        var terminal: String?
        var callbacks = ChatRunKernelAdapter.Callbacks()
        callbacks.onRunTerminal = { terminal = $0 }
        let adapter = ChatRunKernelAdapter(runtime: runtime, ledger: harness.ledger, callbacks: callbacks)

        let result = await adapter.run(.init(
            provider: provider,
            providerSetting: harness.providerSetting,
            params: harness.params,
            runId: "adapter-budget",
            startedAt: 1,
            inputDigest: "digest",
            conversationId: harness.conversationId,
            initialMessages: harness.messages,
            toolExposureBridge: harness.toolExposureBridge,
            maxToolResumeCount: 1,
            drainSteer: nil,
            mailboxDrain: nil,
            citationTracker: nil,
            prepareUploadMessages: nil,
            nestedToolRunner: nil,
            approvalDecider: { _ in nil }
        ))

        let startedTools = harness.log.snapshot().compactMap { event -> String? in
            guard case .toolCallStarted(let tool) = event else { return nil }
            return tool
        }
        XCTAssertEqual(startedTools, ["tool_search", "session_search"])
        XCTAssertTrue(F.toolOutputText(toolCallId: "tc-unexposed", in: result).contains("tool_not_exposed"))
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(terminal, AgentRunStatus.failed.wireName)
        XCTAssertTrue(F.toolOutputText(toolCallId: "tc-limited", in: result).contains("上限"))
    }

    func testHostHandsPreparedRunToBackgroundOwner() async throws {
        let harness = makeHarness()
        let provider = HostBlockingProvider()
        let host = makeHost(harness: harness, provider: provider)
        var capturedHandoff: IOSChatBackgroundHandoff?
        host.backgroundStartOverrideForTesting = { handoff, _ in
            capturedHandoff = handoff
            return true
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernelHostHandoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)

        start(host, harness: harness)
        let providerStarted = await waitForCondition { provider.callCount == 1 }
        XCTAssertTrue(providerStarted)

        let didHandoff = host.handoffCurrentGenerationToBackground(conversationStore: store)

        XCTAssertTrue(didHandoff)
        XCTAssertEqual(capturedHandoff?.runId, harness.capturedRunId)
        XCTAssertFalse(host.isRunning)
        XCTAssertFalse(harness.isLoading)
        XCTAssertNil(harness.log.terminalStatus(), "成功交接后终态归后台 owner，前台不得抢报")
    }

    func testHandoffAllowsInFlightNetworkRead() async throws {
        let transport = HostBlockingSearchTransport()
        let harness = makeHarness(searchTransport: transport)
        let provider = HostScriptedProvider(rounds: [
            toolRound("tc-search", "search_web", #"{"query":"amber"}"#),
        ])
        let host = makeHost(harness: harness, provider: provider)
        var capturedHandoff: IOSChatBackgroundHandoff?
        host.backgroundStartOverrideForTesting = { handoff, _ in
            capturedHandoff = handoff
            return true
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernelHostSearchHandoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)

        start(host, harness: harness)
        let approval = await harness.waitForPendingSearchApproval()
        XCTAssertNotNil(approval)
        host.approvePendingSearchTool()
        let searchStarted = await waitForCondition { transport.callCount == 1 }
        XCTAssertTrue(searchStarted)

        XCTAssertTrue(host.handoffCurrentGenerationToBackground(conversationStore: store))
        XCTAssertEqual(capturedHandoff?.runId, harness.capturedRunId)
        XCTAssertFalse(host.isRunning)
        XCTAssertFalse(harness.isLoading)
        XCTAssertNil(harness.log.terminalStatus(), "networkRead 交接后终态归后台 owner")
    }

    func testHandoffRejectsInFlightImageGeneration() async throws {
        let harness = makeHarness()
        let host = makeHost(harness: harness, provider: HostScriptedProvider(rounds: []))
        var backgroundStartCount = 0
        host.backgroundStartOverrideForTesting = { _, _ in
            backgroundStartCount += 1
            return true
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernelHostImageHandoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)

        host.runImageTool(
            input: #"{"prompt":"make it brighter","source_image_url":"file:///tmp/source.png"}"#,
            conversationId: harness.conversationId,
            modelDisplayName: "image-test"
        )

        XCTAssertTrue(host.isRunning)
        XCTAssertFalse(host.handoffCurrentGenerationToBackground(conversationStore: store))
        XCTAssertEqual(backgroundStartCount, 0)

        host.cancel()
        let becameIdle = await waitForHostIdle(host)
        XCTAssertTrue(becameIdle)
    }

    func testDirectImageRunFailsClosedWhenLedgerStartCannotPersist() async {
        let harness = makeHarness()
        harness.ledger.failStarts = true
        let host = makeHost(harness: harness, provider: HostScriptedProvider(rounds: []))

        host.runImageTool(
            input: #"{"prompt":"make it brighter","source_image_url":"file:///tmp/source.png"}"#,
            conversationId: harness.conversationId,
            modelDisplayName: "image-test"
        )

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, AgentRunStatus.failed.wireName)
        XCTAssertFalse(host.isRunning)
        XCTAssertFalse(harness.isLoading)
        XCTAssertFalse(harness.messages.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }.first?.output.isEmpty ?? true)
        XCTAssertFalse(harness.log.snapshot().contains { event in
            switch event {
            case .toolCallStarted, .toolCallFinished:
                return true
            default:
                return false
            }
        }, "Started 写失败后不得执行或记录图片副作用终态")
    }

    func testDirectImageImmediateCancelDoesNotStartRunAfterTerminal() async {
        let harness = makeHarness()
        let host = makeHost(harness: harness, provider: HostScriptedProvider(rounds: []))

        host.runImageTool(
            input: #"{"prompt":"make it brighter","source_image_url":"file:///tmp/source.png"}"#,
            conversationId: harness.conversationId,
            modelDisplayName: "image-test"
        )
        host.cancel()

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, AgentRunStatus.cancelled.wireName)
        XCTAssertFalse(host.isRunning)
        XCTAssertFalse(harness.log.snapshot().contains(.runStarted))
    }

    func testDirectImagePrepareFailureReconcilesPreparedTransaction() async {
        let harness = makeHarness()
        harness.ledger.preparationResult = .blocked(reason: "event append failed")
        let host = makeHost(harness: harness, provider: HostScriptedProvider(rounds: []))

        host.runImageTool(
            input: #"{"prompt":"make it brighter","source_image_url":"file:///tmp/source.png"}"#,
            conversationId: harness.conversationId,
            modelDisplayName: "image-test"
        )

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, AgentRunStatus.failed.wireName)
        XCTAssertTrue(harness.ledger.recoveryTransitions.contains(.init(
            expected: .prepared,
            state: .reconciled,
            outcome: "not_executed_prepare_failed"
        )))
        XCTAssertFalse(harness.log.snapshot().contains { event in
            if case .toolCallStarted = event { return true }
            return false
        })
    }

    func testDirectImageCancelClosesStartedTransactionWithoutWaitingForExecutor() async {
        let harness = makeHarness()
        let host = makeHost(harness: harness, provider: HostScriptedProvider(rounds: []))
        let executionGate = ImageExecutionGate()
        host.imageToolExecutionOverrideForTesting = { _, messages in
            executionGate.started = true
            while !executionGate.released {
                await Task.yield()
            }
            return messages
        }

        host.runImageTool(
            input: #"{"prompt":"make it brighter","source_image_url":"file:///tmp/source.png"}"#,
            conversationId: harness.conversationId,
            modelDisplayName: "image-test"
        )
        let didStartExecution = await waitForCondition {
            executionGate.started && harness.log.snapshot().contains(.toolCallStarted(tool: "generate_image"))
        }
        XCTAssertTrue(didStartExecution)

        host.cancel()

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, AgentRunStatus.cancelled.wireName)
        XCTAssertFalse(host.isRunning)
        XCTAssertTrue(harness.ledger.recoveryTransitions.contains(.init(
            expected: .started,
            state: .outcomeUnknown,
            outcome: "cancelled_during_execution"
        )))

        executionGate.released = true
    }
}
