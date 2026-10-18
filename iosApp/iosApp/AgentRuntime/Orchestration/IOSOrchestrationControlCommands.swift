import Foundation
@preconcurrency import Shared

@MainActor
final class IOSOrchestrationControlCommands {
    /// P1-d 目标解析结果（hex = 目标会话 id，edge = 目标边记录，root 为 nil）。
    struct ResolvedTarget: Sendable {
        let hex: String
        let edge: IOSOrchestrationPersistence.ThreadEdgeSnapshot?
    }

    /// P1-d 目标解析错误（结构化 code/reason，由调用方以本工具名组装 errorJSON）。
    struct TargetError: Error, Sendable {
        let code: String
        let reason: String
    }

    /// P1-d wait_agent 竞速结果。
    private enum MailboxWaitOutcome: Sendable {
        case activity
        case timeout
        case cancelled
    }

    private let conversationStoreProvider: () -> IOSConversationStore?
    private let mailboxDaoProvider: () -> MailboxDao
    private let threadEdgeDaoProvider: () -> ThreadEdgeDao
    private let agentRuntimeDaoProvider: () -> AgentRuntimeDao
    private let backgroundCoordinator: any IOSThreadOrchestrationToolService.BackgroundScheduling
    private let currentConversationId: () -> KotlinUuid?
    private let foregroundActiveRunId: (String) -> String?
    private let cancelForegroundRun: (String) -> Bool
    private let activityCenter: IOSMailboxActivityCenter
    private let sharedSettingsProvider: () -> IOSSharedSettingsStore?
    private let modelPool: IOSSubAgentModelPool
    private let waitTimeoutMinMs: Int64
    private let waitTimeoutMaxMs: Int64
    private let waitTimeoutDefaultMs: Int64

    init(
        conversationStoreProvider: @escaping () -> IOSConversationStore?,
        mailboxDaoProvider: @escaping () -> MailboxDao,
        threadEdgeDaoProvider: @escaping () -> ThreadEdgeDao,
        agentRuntimeDaoProvider: @escaping () -> AgentRuntimeDao,
        backgroundCoordinator: any IOSThreadOrchestrationToolService.BackgroundScheduling,
        currentConversationId: @escaping () -> KotlinUuid?,
        foregroundActiveRunId: @escaping (String) -> String?,
        cancelForegroundRun: @escaping (String) -> Bool,
        activityCenter: IOSMailboxActivityCenter,
        sharedSettingsProvider: @escaping () -> IOSSharedSettingsStore?,
        modelPool: IOSSubAgentModelPool,
        waitTimeoutMinMs: Int64,
        waitTimeoutMaxMs: Int64,
        waitTimeoutDefaultMs: Int64
    ) {
        self.conversationStoreProvider = conversationStoreProvider
        self.mailboxDaoProvider = mailboxDaoProvider
        self.threadEdgeDaoProvider = threadEdgeDaoProvider
        self.agentRuntimeDaoProvider = agentRuntimeDaoProvider
        self.backgroundCoordinator = backgroundCoordinator
        self.currentConversationId = currentConversationId
        self.foregroundActiveRunId = foregroundActiveRunId
        self.cancelForegroundRun = cancelForegroundRun
        self.activityCenter = activityCenter
        self.sharedSettingsProvider = sharedSettingsProvider
        self.modelPool = modelPool
        self.waitTimeoutMinMs = waitTimeoutMinMs
        self.waitTimeoutMaxMs = waitTimeoutMaxMs
        self.waitTimeoutDefaultMs = waitTimeoutDefaultMs
    }

    func listAgents(
        arguments: String,
        conversationId: KotlinUuid?,
        capacitySnapshot: @MainActor () -> (maxConcurrentRuns: Int, occupiedRuns: Int)
    ) async -> String {
        // 根 = run 锚定的会话（execute 透传）；currentConversationId() 仅兜底。
        guard let parentConversationId = conversationId ?? currentConversationId() else {
            return IOSThreadOrchestrationToolService.errorJSON(
                toolName: "list_agents",
                code: IOSThreadOrchestrationToolService.ErrorCode.missingContext,
                reason: "当前会话不可用，无法列出子线程。"
            )
        }
        let parentHex = parentConversationId.toHexDashString()
        let args = ChatToolCallParsing.jsonObject(arguments)
        let rawPathPrefix = (args?["path_prefix"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pathPrefix = rawPathPrefix == "" ? nil : rawPathPrefix

        let edges = await IOSOrchestrationPersistence.descendants(of: parentHex, threadEdgeDao: threadEdgeDaoProvider())
        let runsByConversation = await IOSOrchestrationPersistence.latestRunStatusByConversation(
            agentRuntimeDao: agentRuntimeDaoProvider()
        )
        var items: [[String: Any]] = []
        for edge in edges {
            if let pathPrefix, !edge.agentPath.hasPrefix(pathPrefix) { continue }
            items.append([
                "child_thread_id": edge.childThreadId,
                "agent_path": edge.agentPath,
                "nickname": edge.nickname ?? "",
                "role": edge.roleAssistantId ?? "",
                "status": edge.status,
                "fork_turns": edge.forkTurns,
                "run_status": runsByConversation[edge.childThreadId] ?? "none",
            ])
        }
        let capacity = capacitySnapshot()
        return IOSWorkspaceStore.json([
            "ok": true,
            "tool": "list_agents",
            "threads": items,
            "count": items.count,
            "model_pool": modelPoolSnapshot(),
            "max_concurrent_runs": capacity.maxConcurrentRuns,
            "occupied_runs": capacity.occupiedRuns,
            "timeout_minutes": sharedSettingsProvider()?.subAgentTimeoutMinutes ?? 5,
            "active_model_counts": backgroundCoordinator.activeModelCounts,
            "active_provider_counts": backgroundCoordinator.activeProviderCounts,
        ])
    }

    private func modelPoolSnapshot() -> [[String: Any]] {
        guard let sharedSettings = sharedSettingsProvider() else { return [] }
        let settings = sharedSettings.snapshot
        let candidates = modelPool.candidates(settings: settings, sharedSettings: sharedSettings)
        let candidatesById = Dictionary(uniqueKeysWithValues: candidates.map { ($0.modelId, $0) })
        return settings.agentRuntime.subAgent.modelPool.map { entry in
            let modelId = entry.modelId.toHexDashString()
            guard let candidate = candidatesById[modelId] else {
                return [
                    "model_id": modelId,
                    "name": "",
                    "provider": "",
                    "available": false,
                    "supported_reasoning": [],
                    "default_reasoning": NSNull(),
                    "active_model_runs": 0,
                    "active_provider_runs": 0,
                ]
            }
            let supported = candidate.supportedReasoning.map { $0.name.lowercased() }
            let defaultReasoning = (entry.reasoningLevel.flatMap {
                candidate.supportedReasoning.contains($0) ? $0.name.lowercased() : nil
            })
                ?? modelPool.defaultReasoning(for: candidate).name.lowercased()
            return [
                "model_id": candidate.modelId,
                "name": candidate.model.displayName,
                "provider": candidate.provider.name,
                "available": true,
                "supported_reasoning": supported,
                "default_reasoning": defaultReasoning,
                "active_model_runs": backgroundCoordinator.activeModelCounts[candidate.modelId, default: 0],
                "active_provider_runs": backgroundCoordinator.activeProviderCounts[candidate.providerId, default: 0],
            ]
        }
    }

    // MARK: - interrupt_agent

    func interruptAgent(arguments: String, conversationId: KotlinUuid?) async -> String {
        guard let args = ChatToolCallParsing.jsonObject(arguments),
              let targetRaw = args["target"] as? String else {
            return IOSThreadOrchestrationToolService.errorJSON(
                toolName: "interrupt_agent",
                code: IOSThreadOrchestrationToolService.ErrorCode.invalidArguments,
                reason: "interrupt_agent 需要 target（child_thread_id 或 agent path）。"
            )
        }
        let target = targetRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target != "/root" else {
            return IOSThreadOrchestrationToolService.errorJSON(
                toolName: "interrupt_agent",
                code: IOSThreadOrchestrationToolService.ErrorCode.invalidArguments,
                reason: "不能中断根线程或空 target。"
            )
        }
        // 根 = run 锚定的会话（execute 透传）；currentConversationId() 仅兜底。
        guard let parentConversationId = conversationId ?? currentConversationId() else {
            return IOSThreadOrchestrationToolService.errorJSON(
                toolName: "interrupt_agent",
                code: IOSThreadOrchestrationToolService.ErrorCode.missingContext,
                reason: "当前会话不可用，无法解析目标线程。"
            )
        }
        let parentHex = parentConversationId.toHexDashString()

        // 按 childThreadId 或 agentPath 解析；必须是 run 锚定会话的 descendant。
        let dao = threadEdgeDaoProvider()
        let targetEdge: IOSOrchestrationPersistence.ThreadEdgeSnapshot?
        if target.contains("/") {
            let all = await IOSOrchestrationPersistence.allEdges(threadEdgeDao: dao)
            targetEdge = all.first { $0.agentPath == target }
        } else {
            targetEdge = await IOSOrchestrationPersistence.edgeFor(childThreadId: target, threadEdgeDao: dao)
        }
        guard let targetEdge else {
            return IOSThreadOrchestrationToolService.errorJSON(
                toolName: "interrupt_agent",
                code: IOSThreadOrchestrationToolService.ErrorCode.unknownTarget,
                reason: "找不到线程 \(target)。请用 list_agents 查看可寻址线程。"
            )
        }
        let descendants = await IOSOrchestrationPersistence.descendants(of: parentHex, threadEdgeDao: dao)
        guard descendants.contains(where: { $0.childThreadId == targetEdge.childThreadId }) else {
            return IOSThreadOrchestrationToolService.errorJSON(
                toolName: "interrupt_agent",
                code: IOSThreadOrchestrationToolService.ErrorCode.notADescendant,
                reason: "线程 \(target) 不是当前线程的后代，不能从中断它。"
            )
        }
        let childHex = targetEdge.childThreadId

        // 活跃 run：前台当前会话 run 优先，其次后台 job；都无 → idle（不算错误，
        // 线程保留 edge 仍 Open）。
        if let runId = foregroundActiveRunId(childHex) {
            _ = cancelForegroundRun(runId)
            return Self.interruptResultJSON(target: target, childHex: childHex, threadStatus: targetEdge.status, previousStatus: "running")
        }
        if let backgroundRunId = backgroundCoordinator.activeRunId(conversationHex: childHex) {
            _ = backgroundCoordinator.cancelJob(runId: backgroundRunId)
            return Self.interruptResultJSON(target: target, childHex: childHex, threadStatus: targetEdge.status, previousStatus: "running")
        }
        return Self.interruptResultJSON(target: target, childHex: childHex, threadStatus: targetEdge.status, previousStatus: "idle")
    }

    // MARK: - send_message / followup_task / wait_agent（P1-d）

    /// User-facing child-page followup. The page has no parent run to borrow for
    /// target resolution, so resolve the child's recorded parent first and then
    /// reuse the exact followup path (queue an active run, bootstrap an idle run).
    func sendMessage(arguments: String, runId: String, conversationId: KotlinUuid?) async -> String {
        guard let args = ChatToolCallParsing.jsonObject(arguments),
              let targetRaw = args["target"] as? String,
              let message = args["message"] as? String else {
            return IOSThreadOrchestrationToolService.errorJSON(
                toolName: "send_message",
                code: IOSThreadOrchestrationToolService.ErrorCode.invalidArguments,
                reason: "send_message 需要 target 与 message。"
            )
        }
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            return IOSThreadOrchestrationToolService.errorJSON(
                toolName: "send_message",
                code: IOSThreadOrchestrationToolService.ErrorCode.invalidArguments,
                reason: "message 不能为空。"
            )
        }
        guard let runConversationId = conversationId ?? currentConversationId() else {
            return IOSThreadOrchestrationToolService.errorJSON(
                toolName: "send_message",
                code: IOSThreadOrchestrationToolService.ErrorCode.missingContext,
                reason: "当前会话不可用，无法确定发送方线程。"
            )
        }
        let resolved = await resolveTarget(targetRaw, runConversationId: runConversationId)
        guard case .success(let target) = resolved else {
            if case .failure(let failure) = resolved {
                return IOSThreadOrchestrationToolService.errorJSON(toolName: "send_message", code: failure.code, reason: failure.reason)
            }
            return IOSThreadOrchestrationToolService.errorJSON(toolName: "send_message", code: IOSThreadOrchestrationToolService.ErrorCode.unknownTarget, reason: "找不到线程 \(targetRaw)。")
        }
        let senderAgentPath = await IOSOrchestrationPersistence.agentPath(of: runConversationId.toHexDashString(), threadEdgeDao: threadEdgeDaoProvider())
        let envelope = MailboxEnvelopeEntity(
            id: "msg-\(UUID().uuidString)",
            authorThreadId: senderAgentPath,
            recipientThreadId: target.hex,
            type: MailboxEnvelopeType.message.name,
            payload: trimmedMessage,
            triggerTurn: false,
            parentTurnId: runId,
            createdAt: Int64(Date().timeIntervalSince1970 * 1000),
            deliveredAt: nil
        )
        do {
            try await IOSOrchestrationPersistence.enqueue(mailboxDao: mailboxDaoProvider(), envelope: envelope)
        } catch {
            return IOSThreadOrchestrationToolService.errorJSON(
                toolName: "send_message",
                code: IOSThreadOrchestrationToolService.ErrorCode.startFailed,
                reason: "消息入队失败，请重试。"
            )
        }
        // 信号在入队成功之后：wait_agent「先订阅、后查 pending」的防丢窗口由此闭合。
        await activityCenter.signal(conversationIdHex: target.hex)
        return IOSWorkspaceStore.json([
            "ok": true,
            "tool": "send_message",
            "target": targetRaw,
            "recipient_thread_id": target.hex,
            "status": "queued",
        ])
    }

    /// P1-d: 投递 + 唤醒。目标无活跃 run（前台/后台两路径判定，与 interrupt 同）
    /// → spawn 同款 bootstrap（信封渲染直写目标会话 + 标 delivered + durable
    /// 后台 run 启动）；有活跃 run → 留 pending 等目标边界 drain。
    func waitAgent(arguments: String, conversationId: KotlinUuid?) async -> String {
        guard let runConversationId = conversationId ?? currentConversationId() else {
            return IOSThreadOrchestrationToolService.errorJSON(
                toolName: "wait_agent",
                code: IOSThreadOrchestrationToolService.ErrorCode.missingContext,
                reason: "当前会话不可用，无法等待 mailbox。"
            )
        }
        let hex = runConversationId.toHexDashString()
        let args = ChatToolCallParsing.jsonObject(arguments)
        let requestedMs = (args?["timeout_ms"] as? NSNumber)?.int64Value

        // A foreground root is an interactive turn. Waiting here holds the
        // only foreground run owner, so return a control result immediately
        // and let the host release the run. Child/background runs retain the
        // event-backed wait below. The edge check is deliberate: a foreground
        // child must still be able to wait and report its completion to its
        // parent instead of being mistaken for the root conversation.
        var isForegroundRoot = false
        if foregroundActiveRunId(hex) != nil {
            isForegroundRoot = await IOSOrchestrationPersistence.edgeFor(
                childThreadId: hex,
                threadEdgeDao: threadEdgeDaoProvider()
            ) == nil
        }
        if isForegroundRoot {
            let pendingCount = await IOSOrchestrationPersistence.pendingCount(
                mailboxDao: mailboxDaoProvider(),
                recipientId: hex
            )
            if pendingCount > 0 {
                return IOSWorkspaceStore.json([
                    "ok": true,
                    "tool": "wait_agent",
                    "message": "mailbox already has \(pendingCount) pending",
                    "timed_out": false,
                    "pending_count": pendingCount,
                ])
            }
            let children: [IOSOrchestrationPersistence.ThreadEdgeSnapshot]
            do {
                children = try await withCheckedThrowingContinuation { continuation in
                    threadEdgeDaoProvider().childrenOf(parentThreadId: hex) { result, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: (result ?? []).map(IOSOrchestrationPersistence.ThreadEdgeSnapshot.init)) }
                    }
                }
            } catch {
                return IOSThreadOrchestrationToolService.errorJSON(
                    toolName: "wait_agent", code: "state_unavailable",
                    reason: "无法读取子代理状态：\(error.localizedDescription)"
                )
            }
            // A child may finish while the edge query is suspended. Check its
            // durable mail again before deciding whether another wait can help.
            let pendingAfterLookup = await IOSOrchestrationPersistence.pendingCount(mailboxDao: mailboxDaoProvider(), recipientId: hex)
            if pendingAfterLookup > 0 {
                return IOSWorkspaceStore.json([
                    "ok": true, "tool": "wait_agent", "timed_out": false,
                    "pending_count": pendingAfterLookup,
                    "message": "mailbox already has \(pendingAfterLookup) pending",
                ])
            }
            let activeChildren = children.filter { child in
                child.status == IOSThreadOrchestrationToolService.EdgeStatus.open &&
                    (foregroundActiveRunId(child.childThreadId) != nil ||
                     backgroundCoordinator.activeRunId(conversationHex: child.childThreadId) != nil)
            }
            guard !activeChildren.isEmpty else {
                return IOSWorkspaceStore.json([
                    "ok": true, "tool": "wait_agent", "status": "no_active_children",
                    "yielded": false, "timed_out": false, "pending_count": 0,
                    "active_child_count": 0,
                    "message": "No child run is active. Waiting does not restart an ended child. Read its saved report with native session_read (follow next_offset for truncated text). If more work is needed, call native followup_task before waiting again; send_message does not wake an idle child. Use tool_search first if a native tool is hidden, never mcp_call. Do not ask the user to reissue the task just to retrieve omitted results.",
                ])
            }
            return IOSWorkspaceStore.json([
                "ok": true,
                "tool": "wait_agent",
                "message": "Foreground run yielded; resume on a child completion report unless newer user input supersedes this wait.",
                "timed_out": false,
                "pending_count": 0,
                "active_child_count": activeChildren.count,
                "yielded": true,
            ])
        }

        // 订阅在前：订阅后的信号由缓冲流兜住，订阅前的信号必已落 Room 由
        // 下方 pending 检查兜住——两个窗口都不丢（选型理由见文件头注释）。
        let stream = await activityCenter.events(for: hex)
        let pendingCount = await IOSOrchestrationPersistence.pendingCount(mailboxDao: mailboxDaoProvider(), recipientId: hex)
        if pendingCount > 0 {
            return IOSWorkspaceStore.json([
                "ok": true,
                "tool": "wait_agent",
                "message": "mailbox already has \(pendingCount) pending",
                "timed_out": false,
                "pending_count": pendingCount,
            ])
        }
        var timeoutMs = requestedMs ?? waitTimeoutDefaultMs
        var clamped = false
        if timeoutMs < waitTimeoutMinMs {
            timeoutMs = waitTimeoutMinMs
            clamped = true
        }
        if timeoutMs > waitTimeoutMaxMs {
            timeoutMs = waitTimeoutMaxMs
            clamped = true
        }

        let outcome = await Self.awaitMailboxEvent(stream: stream, timeoutMs: timeoutMs)
        switch outcome {
        case .activity:
            // 事件后复查 mailbox：有信封 → 活动；无 → steer 打断（steer 不产生信封）。
            let pendingAfterEvent = await IOSOrchestrationPersistence.pendingCount(mailboxDao: mailboxDaoProvider(), recipientId: hex)
            if pendingAfterEvent > 0 {
                return IOSWorkspaceStore.json([
                    "ok": true,
                    "tool": "wait_agent",
                    "message": "Mailbox activity detected.",
                    "timed_out": false,
                    "pending_count": pendingAfterEvent,
                ])
            }
            return IOSWorkspaceStore.json([
                "ok": true,
                "tool": "wait_agent",
                "message": "Wait interrupted by new input.",
                "timed_out": false,
            ])
        case .timeout:
            var payload: [String: Any] = [
                "ok": true,
                "tool": "wait_agent",
                "message": "Timed out waiting for mailbox activity after \(timeoutMs) ms.",
                "timed_out": true,
                "timeout_ms": timeoutMs,
            ]
            if clamped {
                // clamp 时在返回里说明（下限/上限按注入常量，测试可改小）。
                payload["clamped"] = true
                payload["clamp_range_ms"] = [waitTimeoutMinMs, waitTimeoutMaxMs]
            }
            return IOSWorkspaceStore.json(payload)
        case .cancelled:
            // Task 取消不吞：走既有工具取消语义——立即返回、不等到超时；
            // 引擎在下一边界把 run 收口为 wasCancelled，输出不冒充成功。
            return IOSWorkspaceStore.json([
                "ok": true,
                "tool": "wait_agent",
                "status": "cancelled",
                "message": "Wait cancelled.",
                "timed_out": false,
            ])
        }
    }

    /// P1-d 目标解析共用：target 支持 childThreadId（hex）或 agentPath（含 "/"）。
    /// 同树校验：从当前 run 会话沿 edge 走到 root，target == root 或 root 的
    /// descendant 才合法；拒绝自身。未知/树外/自身分别给结构化错误。
    func resolveTarget(
        _ targetRaw: String,
        runConversationId: KotlinUuid
    ) async -> Result<ResolvedTarget, TargetError> {
        let runHex = runConversationId.toHexDashString()
        let target = targetRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return .failure(TargetError(code: IOSThreadOrchestrationToolService.ErrorCode.invalidArguments, reason: "target 不能为空。"))
        }
        let dao = threadEdgeDaoProvider()
        let all = await IOSOrchestrationPersistence.allEdges(threadEdgeDao: dao)
        let targetEdge: IOSOrchestrationPersistence.ThreadEdgeSnapshot?
        if target.contains("/") {
            targetEdge = all.first { $0.agentPath == target }
        } else {
            targetEdge = await IOSOrchestrationPersistence.edgeFor(childThreadId: target, threadEdgeDao: dao)
        }
        let rootHex = await IOSOrchestrationPersistence.rootHex(of: runHex, threadEdgeDao: dao)
        let targetHex: String
        if let targetEdge {
            targetHex = targetEdge.childThreadId
        } else if target == "/root" || target == rootHex {
            // 根线程本身（无 edge 记录）。
            targetHex = rootHex
        } else {
            return .failure(TargetError(
                code: IOSThreadOrchestrationToolService.ErrorCode.unknownTarget,
                reason: "找不到线程 \(target)。请用 list_agents 查看可寻址线程。"
            ))
        }
        let descendants = await IOSOrchestrationPersistence.descendants(of: rootHex, threadEdgeDao: dao)
        guard targetHex == rootHex || descendants.contains(where: { $0.childThreadId == targetHex }) else {
            return .failure(TargetError(
                code: IOSThreadOrchestrationToolService.ErrorCode.notADescendant,
                reason: "线程 \(target) 不是当前线程所在树的后代，不能向其发送消息。"
            ))
        }
        guard targetHex != runHex else {
            return .failure(TargetError(
                code: IOSThreadOrchestrationToolService.ErrorCode.cannotMessageSelf,
                reason: "不能向自己发送消息。"
            ))
        }
        return .success(ResolvedTarget(hex: targetHex, edge: targetEdge))
    }

    /// P1-d 抽取（自 spawn (f) 段）：写基线 + 保存目标会话消息（spawn/followup 共用）。
    private static func awaitMailboxEvent(
        stream: AsyncStream<Void>,
        timeoutMs: Int64
    ) async -> MailboxWaitOutcome {
        do {
            return try await withThrowingTaskGroup(of: MailboxWaitOutcome.self) { group in
                group.addTask {
                    for await _ in stream {
                        return .activity
                    }
                    // 流结束（AsyncStream 在任务取消时结束迭代）→ 视为取消。
                    throw CancellationError()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                    return .timeout
                }
                group.addTask {
                    // 取消观察：父取消传播到子任务后立即收口，不等超时。
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    throw CancellationError()
                }
                let first = try await group.next() ?? .timeout
                group.cancelAll()
                return first
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .timeout
        }
    }

    // MARK: - FINAL_ANSWER 终态回传（前台 finishStreaming / 后台 job 完成共用）

    /// run 终态钩子：本会话有 Open 父 edge 时，向父线程 mailbox 投递 FINAL_ANSWER
    /// （payload = 最后 assistant 文本摘要，必要时附带原文分页引用；triggerTurn=false；
    /// parentTurnId = 本 runId）。父线程在其下一边界/下一 run 头经 P1-b 机制折入。
    func notifyRunTerminal(
        conversationId: KotlinUuid?,
        runId: String,
        finalMessages: [UIMessage],
        displayBaseline: [UIMessage]?,
        terminalStatus: AgentRunStatus?,
        terminalReason: String?
    ) async {
        guard let conversationId else { return }
        let childHex = conversationId.toHexDashString()
        guard let edge = await IOSOrchestrationPersistence.edgeFor(childThreadId: childHex, threadEdgeDao: threadEdgeDaoProvider()),
              edge.status == IOSThreadOrchestrationToolService.EdgeStatus.open else {
            return
        }
        if let store = conversationStoreProvider() {
            let parentID = KotlinUuid.companion.parse(uuidString: edge.parentThreadId)
            do {
                // Deleted parents cannot consume mail. The child transcript is
                // retained and remains accessible from conversation storage.
                guard try await store.loadConversationForOrchestration(parentID) != nil else { return }
            } catch {
                // A read error does not prove deletion; keep the result durable
                // in the mailbox and surface the storage error.
                store.publishUserVisibleError(IOSUserVisibleError(
                    title: "读取父会话失败", message: error.localizedDescription, severity: .error
                ))
            }
        }
        // Full transcripts remain stored in the child; only this run's output
        // may be delivered as its FINAL_ANSWER. Direct callers can pass an
        // already scoped transcript without a display baseline.
        let runMessages = displayBaseline.map {
            IOSSubAgentOutputProjection.generatedMessages(
                finalMessages: finalMessages,
                displayMessages: $0
            )
        } ?? finalMessages
        let text = Self.lastAssistantText(runMessages)
        // P1-c 修复：空转录（如整轮失败、无 assistant 输出）也回传终态——改投
        // 结构化信封携带终态语义，父线程不静默丢失子线程的终止信号；截断与
        // runId 幂等去重与文本路径一致。
        let payloadSource = text.isEmpty
            ? "[run ended without assistant output]"
            : text
        var terminalMetadata: [String: Any] = [:]
        if let terminalStatus {
            terminalMetadata["run_ended"] = true
            terminalMetadata["terminal_status"] = terminalStatus.wireName
            if let terminalReason = terminalReason?.nilIfBlank {
                terminalMetadata["terminal_reason"] = terminalReason
            }
        }
        let payload: String
        if payloadSource.count > IOSThreadOrchestrationToolService.finalAnswerMaxChars,
           let message = runMessages.last(where: { $0.role == MessageRole.assistant }) {
            var referenceMetadata = terminalMetadata
            referenceMetadata["run_ended"] = true
            referenceMetadata["truncated"] = true
            referenceMetadata["total_chars"] = payloadSource.count
            referenceMetadata["session_read"] = [
                "conversation_id": childHex,
                "message_id": message.id.toHexDashString(),
                "offset": 0,
            ]
            let reference = IOSWorkspaceStore.json(referenceMetadata)
            payload = """
            \(payloadSource.prefix(IOSThreadOrchestrationToolService.finalAnswerMaxChars))

            [Amber host: child result excerpt]
            \(reference)
            This child run has ended. The report above is a delivery excerpt, not a promise of another message. Read the stored full message with native session_read using the reference above, then follow next_offset until null. If the tool is hidden, use tool_search first; do not call it through mcp_call. Do not request regeneration or wait for more mail just because this excerpt was truncated.
            """
        } else if !terminalMetadata.isEmpty {
            payload = """
            \(payloadSource)

            [Amber host: child run ended]
            \(IOSWorkspaceStore.json(terminalMetadata))
            """
        } else {
            payload = payloadSource
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let envelope = MailboxEnvelopeEntity(
            id: "final-\(runId)",
            authorThreadId: edge.agentPath,
            recipientThreadId: edge.parentThreadId,
            type: MailboxEnvelopeType.finalAnswer.name,
            payload: payload,
            triggerTurn: false,
            parentTurnId: runId,
            createdAt: now,
            deliveredAt: nil
        )
        // 幂等去重：同 runId 的终态信封已存在（cancel/finishStreaming 双触发）
        // 时 enqueueIfAbsent 静默跳过（IGNORE），不抛冲突异常、不双发。
        try? await IOSOrchestrationPersistence.enqueueIfAbsent(mailboxDao: mailboxDaoProvider(), envelope: envelope)
        // P1-d: FINAL_ANSWER 落父 mailbox → 广播活动（父线程的 wait_agent 由此醒来）。
        await activityCenter.signal(conversationIdHex: edge.parentThreadId)
    }

    static func lastAssistantText(_ messages: [UIMessage]) -> String {
        guard let lastAssistant = messages.last(where: { $0.role == MessageRole.assistant }) else {
            return ""
        }
        return lastAssistant.parts
            .compactMap { ($0 as? UIMessagePart.Text)?.text }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func interruptResultJSON(
        target: String,
        childHex: String,
        threadStatus: String,
        previousStatus: String
    ) -> String {
        IOSWorkspaceStore.json([
            "ok": true,
            "tool": "interrupt_agent",
            "target": target,
            "child_thread_id": childHex,
            "previous_status": previousStatus,
            "thread_status": threadStatus,
        ])
    }
}
