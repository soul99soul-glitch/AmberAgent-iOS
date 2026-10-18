import XCTest
@preconcurrency import Shared
@testable import iosApp


/// Foreground run completion, approval, streaming, and tool rounds.
@MainActor
final class IOSChatKernelRunHostTests: IOSChatKernelRunHostTestCase {
    // MARK: - 完成终态

    /// A yielded foreground wait is a completed Host run, but it must notify
    /// the bindings before terminal steer handling so the VM can retain the
    /// waiting ownership and later resume when child mail arrives.
    func testForegroundYieldNotifiesBindingsBeforeTerminalSteerHandling() async throws {
        let fixture = try await makeForegroundYieldHost()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let idle = await waitForHostIdle(fixture.host)
        XCTAssertTrue(idle)
        XCTAssertEqual(fixture.provider.callCount, 1, "yield 必须在当前轮结束，不得继续请求下一轮 provider")

        let yieldIndexes = fixture.recorder.events.indices.filter {
            fixture.recorder.events[$0].hasPrefix("yield:")
        }
        XCTAssertEqual(yieldIndexes.count, 1, "一次 yielded 终态只通知一次等待归属")
        guard let yieldIndex = yieldIndexes.first else { return }
        XCTAssertEqual(
            fixture.recorder.events[yieldIndex],
            "yield:\(fixture.recorder.runId ?? "")"
        )
        XCTAssertEqual(
            fixture.recorder.events.dropFirst(yieldIndex + 1).first,
            "steer:true",
            "onForegroundYield 必须先于 handleSteerQueueAtTerminal"
        )
    }

    /// completed 序列(CG-C :2732-2797 + finishStreaming :4919-4979):
    /// recordRun(completed) → handleSteerQueueAtTerminal(autoContinue: true) →
    /// generationSucceeded → onRunTerminal;无 composer 回填。
    func testCompletedRunTerminalSequence() async {
        let harness = makeHarness()
        var foregroundYieldRunIds: [String] = []
        harness.bindings.onForegroundYield = { foregroundYieldRunIds.append($0) }
        var succeededCount = 0
        var restoreLeftoverCount = 0
        var terminalReports: [(runId: String, messageCount: Int)] = []
        var memoryExtractionRequests = 0
        harness.bindings.scheduleMemoryExtraction = { id, baseline, completed in
            memoryExtractionRequests += 1
            XCTAssertEqual(id, harness.conversationId)
            XCTAssertTrue(baseline.contains { $0.role == .user })
            XCTAssertEqual(completed.last?.toText(), "你好，世界")
        }
        harness.bindings.generationSucceeded = { succeededCount += 1 }
        harness.bindings.restoreSteerQueueLeftover = { _ in restoreLeftoverCount += 1 }
        harness.bindings.onRunTerminal = { _, runId, _, finalMessages, _ in
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
        XCTAssertTrue(foregroundYieldRunIds.isEmpty, "普通 completed 不得伪装成 foreground yield")
        XCTAssertEqual(succeededCount, 1)
        XCTAssertEqual(memoryExtractionRequests, 1)
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

    /// P3a:Jev 关闭时,基线注入(只用于压缩预算估算)与最终注入各算一次记忆召回,
    /// 最终注入在压缩/投影之后现算(读到最新记忆);usage marking 复用最终注入的结果,
    /// 标记的记忆必须与实际注入的一致。原实现三处各算一次。
    func testMemoryRecallComputedForBaselineAndFinalInjectionAndMarkingReusesFinal() async {
        let harness = makeHarness()
        harness.bindings.prepareJevMemoryRecall = { _, _ in nil } // Jev off/shadow：no override.
        var computations: [ChatMemoryContextBuilder.RecallResult] = []
        harness.bindings.memoryRecallResultForRun = { _ in
            let result = ChatMemoryContextBuilder.RecallResult(prompt: "recall-\(computations.count + 1)", records: [])
            computations.append(result)
            return result
        }
        var injectionOverrides: [ChatMemoryContextBuilder.RecallResult?] = []
        harness.bindings.messagesByInjectingRuntimeContextForRun = { messages, _, override in
            injectionOverrides.append(override)
            return messages
        }
        var recordIdsOverrides: [ChatMemoryContextBuilder.RecallResult?] = []
        harness.bindings.memoryRecordIdsForRuntimeContext = { _, override in
            recordIdsOverrides.append(override)
            return override?.ids ?? []
        }

        let provider = HostScriptedProvider(rounds: [textRound("你好，世界")])
        let host = makeHost(harness: harness, provider: provider)
        start(host, harness: harness)

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, "completed")
        let idle = await waitForHostIdle(host)
        XCTAssertTrue(idle)

        XCTAssertEqual(computations.count, 2, "基线注入与最终注入各算一次，usage marking 不再单独计算")
        XCTAssertEqual(injectionOverrides.map { $0?.prompt }, ["recall-1", "recall-2"], "最终注入必须用注入时刻现算的结果")
        XCTAssertEqual(recordIdsOverrides.map { $0?.prompt }, ["recall-2"], "标记的记忆必须与最终注入一致")
    }

    func testTerminalCASFailureReleasesLocalOwnerAndSuppressesExternalCompletion() async {
        IOSJevMetricsStore.clear()
        defer { IOSJevMetricsStore.clear() }
        let harness = makeHarness()
        harness.failRunTerminals = true
        var terminalReported = false
        harness.bindings.onRunTerminal = { _, _, _, _, _ in terminalReported = true }
        let host = makeHost(
            harness: harness,
            provider: HostScriptedProvider(rounds: [textRound("完成")])
        )

        start(host, harness: harness)
        if let runId = harness.capturedRunId {
            IOSJevToolDiscoveryMetricsTracker.registerActiveExposure(
                runId: runId, exposedToolNames: ["wm_click"], modelVersion: "jev-v1"
            )
        }
        let attempted = await waitForCondition { harness.runTerminalRecordAttempts == 1 }

        XCTAssertTrue(attempted)
        XCTAssertFalse(host.isRunning, "provider 已结束时不得把前台 owner 卡成僵尸")
        XCTAssertFalse(harness.isLoading)
        XCTAssertFalse(terminalReported, "durable 终态失败时不得发布外部完成")
        XCTAssertEqual(harness.terminalSteerAutoContinue, [false])
        XCTAssertNil(harness.log.terminalStatus())
        IOSJevToolDiscoveryMetricsTracker.recordNextModelStep(
            runId: harness.capturedRunId, calledToolNames: ["wm_click"]
        )
        XCTAssertFalse(IOSJevMetricsStore.load().contains(where: { $0.numbers?["next_step_new_tool_used"] != nil }),
                       "durable terminal rejection must discard pending tool-discovery observation")
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

    func testStaleIshApprovalRequestCannotResolveCurrentPrompt() async {
        let previousHighRiskAutoApprove = IOSLocalToolExecutor.isHighRiskAutoApproveEnabled
        IOSLocalToolExecutor.setHighRiskAutoApproveEnabled(false)
        defer { IOSLocalToolExecutor.setHighRiskAutoApproveEnabled(previousHighRiskAutoApprove) }
        let defaults = UserDefaults(suiteName: "terminal-approval-\(UUID().uuidString)")!
        let localExecutor = IOSLocalToolExecutor(
            permissionStore: IOSPermissionStore(userDefaults: defaults),
            documentStore: DocumentAccessStore(),
            workspaceStore: IOSWorkspaceStore(
                baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            )
        )
        let harness = makeHarness(
            exposedToolNames: ["ish_handoff"],
            localToolExecutor: localExecutor
        )
        let provider = HostScriptedProvider(rounds: [
            toolRound("ish-approval-1", "ish_handoff", #"{"script":"printf amber"}"#),
            textRound("已拒绝"),
        ])
        let host = makeHost(harness: harness, provider: provider)
        start(host, harness: harness)

        guard let current = await harness.waitForPendingIshHandoffApproval() else {
            return XCTFail("终端审批卡必须发布")
        }

        host.approvePendingIshHandoffTool(
            requestId: current.id,
            requestRunId: "stale-run",
            scope: .global
        )

        XCTAssertEqual(harness.pendingIshHandoffApproval?.id, current.id)
        XCTAssertTrue(host.hasPendingToolApproval)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertFalse(IOSLocalToolExecutor.isHighRiskAutoApproveEnabled)

        host.denyPendingIshHandoffTool(requestId: current.id, requestRunId: current.runId)
        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, "completed")
        XCTAssertNil(harness.pendingIshHandoffApproval)
        XCTAssertEqual(provider.callCount, 2)
    }

    func testIshSessionApprovalPersistsAcrossRunsInSameConversation() async {
        let previousHighRiskAutoApprove = IOSLocalToolExecutor.isHighRiskAutoApproveEnabled
        IOSLocalToolExecutor.setHighRiskAutoApproveEnabled(false)
        defer { IOSLocalToolExecutor.setHighRiskAutoApproveEnabled(previousHighRiskAutoApprove) }
        let harness = makeHarness(
            exposedToolNames: ["ish_handoff"],
            localToolExecutor: makeIshLocalExecutor()
        )
        let provider = HostScriptedProvider(rounds: [
            toolRound("ish-session-1", "ish_handoff", #"{"script":"printf one"}"#),
            textRound("第一轮完成"),
            toolRound("ish-session-2", "ish_handoff", #"{"script":"printf two"}"#),
            textRound("第二轮完成"),
        ])
        let host = makeHost(harness: harness, provider: provider)
        start(host, harness: harness)

        guard let first = await harness.waitForPendingIshHandoffApproval() else {
            return XCTFail("首个终端调用必须发布审批卡")
        }
        host.approvePendingIshHandoffTool(
            requestId: first.id,
            requestRunId: first.runId,
            scope: .session
        )

        let firstRunFinished = await waitForCondition {
            provider.callCount == 2 && !host.isRunning
        }
        XCTAssertTrue(firstRunFinished)

        start(host, harness: harness)
        let secondRunFinished = await waitForCondition {
            provider.callCount == 4 && !host.isRunning
        }
        XCTAssertTrue(secondRunFinished)
        XCTAssertEqual(
            harness.log.snapshot().filter { $0 == .approvalRequested(kind: "ish") }.count,
            1
        )
        XCTAssertFalse(IOSLocalToolExecutor.isHighRiskAutoApproveEnabled)
    }

    func testIshGlobalApprovalEnablesHighRiskSettingAndBridgesCurrentRun() async {
        let previousHighRiskAutoApprove = IOSLocalToolExecutor.isHighRiskAutoApproveEnabled
        IOSLocalToolExecutor.setHighRiskAutoApproveEnabled(false)
        defer { IOSLocalToolExecutor.setHighRiskAutoApproveEnabled(previousHighRiskAutoApprove) }
        let harness = makeHarness(
            exposedToolNames: ["ish_handoff"],
            localToolExecutor: makeIshLocalExecutor()
        )
        let provider = HostScriptedProvider(rounds: [
            toolRound("ish-global-1", "ish_handoff", #"{"script":"printf one"}"#),
            toolRound("ish-global-2", "ish_handoff", #"{"script":"printf two"}"#),
            textRound("已完成"),
        ])
        let host = makeHost(harness: harness, provider: provider)
        start(host, harness: harness)

        guard let first = await harness.waitForPendingIshHandoffApproval() else {
            return XCTFail("首个终端调用必须发布审批卡")
        }
        host.approvePendingIshHandoffTool(
            requestId: first.id,
            requestRunId: first.runId,
            scope: .global
        )

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, AgentRunStatus.completed.wireName)
        XCTAssertTrue(IOSLocalToolExecutor.isHighRiskAutoApproveEnabled)
        XCTAssertEqual(provider.callCount, 3)
        XCTAssertEqual(
            harness.log.snapshot().filter { $0 == .approvalRequested(kind: "ish") }.count,
            1
        )
    }

    func testSearchApprovalTerminalFailureStopsBeforeNextProviderRound() async {
        let harness = makeHarness()
        let provider = HostScriptedProvider(rounds: [
            toolRound("tc-1", "search_web", #"{"query":"amber"}"#),
            textRound("不应到达"),
        ])
        let host = makeHost(harness: harness, provider: provider)
        start(host, harness: harness)

        let approval = await harness.waitForPendingSearchApproval()
        XCTAssertNotNil(approval)
        harness.ledger.failTerminals = true
        host.approvePendingSearchTool()

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, AgentRunStatus.recoveryPending.wireName)
        let idleAfterFailure = await waitForHostIdle(host)
        XCTAssertTrue(idleAfterFailure)
        XCTAssertEqual(provider.callCount, 1, "工具终态写失败后不得请求下一轮模型")
        XCTAssertNotEqual(harness.messages.last?.toText(), "不应到达")
    }

    // MARK: - 取消

    /// 审批等待中取消(CG-C cancel 尾 :1501-1581):填充未决工具、清卡、
    /// restoreSteerQueueLeftover(非 handleSteerQueueAtTerminal)、终态
    /// cancelled 只报一次、第二轮绝不开跑。
    func testCancelDuringApprovalWait() async {
        let harness = makeHarness()
        var foregroundYieldRunIds: [String] = []
        harness.bindings.onForegroundYield = { foregroundYieldRunIds.append($0) }
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
        XCTAssertTrue(foregroundYieldRunIds.isEmpty, "cancel 不得伪装成 foreground yield")
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

    /// provisional 投影:首片 delta 后、终端前气泡上屏且随增量生长;终态
    /// 消息与 provisional 同 id 原地替换(无重挂/闪烁),streamDelta revision 落账。
    func testStreamingProvisionalBubbleProjection() async {
        let priorAssistant = F.assistantText("上一轮").applyingGenerationDurationMs(1_200)
        let harness = makeHarness(seedMessages: [
            F.userMessage("第一轮"),
            priorAssistant,
            F.userMessage("继续"),
        ])
        let provider = IOSChatScriptedStreamingProvider(streams: [
            IOSChatScriptedStreamingProvider.Stream(
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
        XCTAssertEqual(
            harness.messages.first(where: { $0.role == MessageRole.assistant })?
                .usage?.generationDurationMs,
            0,
            "新 assistant 轮开始时必须清掉上一轮的时长展示"
        )
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
        XCTAssertEqual(harness.messages.filter { $0.role == MessageRole.assistant }.count, 2)
        XCTAssertTrue(harness.revisions.contains(.streamDelta), "投影必须打 streamDelta revision")
    }

    /// citation(B1 已接线,这里钉 Host 路径端到端):隐藏标记在入累加器前
    /// 剥离,可见文本无残留;终态把引用 id 以 force 记为已使用。
    func testStreamingCitationStrippedAndUsageRecorded() async throws {
        let harness = makeHarness()
        let memoryPrompt = """
        <memory-context>
        - memory_id=7 [core/user] favorite color blue
        </memory-context>
        """
        let memoryData = try JSONSerialization.data(withJSONObject: [[
            "type": "text",
            "text": memoryPrompt,
            "metadata": [ChatRuntimeContextBuilder.memoryCitationMetadataKey: [7]]
        ]])
        let memoryParts = try IosToolOutputJsonBridge.shared.decode(
            json: String(decoding: memoryData, as: UTF8.self)
        )
        let memoryBase = UIMessage.companion.system(prompt: memoryPrompt)
        let memoryContext = memoryBase.doCopy(
            id: memoryBase.id,
            role: memoryBase.role,
            parts: memoryParts,
            annotations: memoryBase.annotations,
            createdAt: memoryBase.createdAt,
            finishedAt: memoryBase.finishedAt,
            modelId: memoryBase.modelId,
            usage: memoryBase.usage,
            translation: memoryBase.translation
        )
        harness.runtimeContextInjector = { messages in
            [memoryContext] + messages
        }
        var usageRecords: [(ids: [Int32], force: Bool)] = []
        harness.bindings.recordMemoryUsage = { ids, force in
            usageRecords.append((ids, force))
        }
        let provider = IOSChatScriptedStreamingProvider(streams: [
            IOSChatScriptedStreamingProvider.Stream(
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
        let provider = IOSChatScriptedStreamingProvider(streams: [
            .init(chunks: [
                F.streamChunk(delta: F.assistantText("准备")),
                F.streamChunk(delta: F.assistantText("查询")),
                F.streamChunk(delta: firstBatch),
            ], intervalNanos: 2_000_000),
            .init(chunks: [
                F.streamChunk(delta: F.assistantText("继续")),
                F.streamChunk(delta: F.assistantText("查询")),
                F.streamChunk(delta: limitedBatch),
            ], intervalNanos: 2_000_000),
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
        var firstVisibleEvents = 0
        var textDeltas: [String] = []
        var callbacks = ChatRunKernelAdapter.Callbacks()
        callbacks.onRunTerminal = { terminal = $0 }
        callbacks.onAssistantFirstVisibleDelta = { firstVisibleEvents += 1 }
        callbacks.onAssistantText = { textDeltas.append($0) }
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
        XCTAssertEqual(firstVisibleEvents, 2, "每轮只发一次首输出事件")
        XCTAssertEqual(textDeltas, ["准备", "准备查询", "继续", "继续查询"], "注册的完整流消费者仍收到每次累计文本更新")
        XCTAssertTrue(F.toolOutputText(toolCallId: "tc-unexposed", in: result).contains("tool_not_exposed"))
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(terminal, AgentRunStatus.failed.wireName)
        XCTAssertTrue(F.toolOutputText(toolCallId: "tc-limited", in: result).contains("上限"))
    }

}
