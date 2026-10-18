import Foundation
@preconcurrency import Shared

/// P1-c: 线程编排工具执行体（spawn_agent / list_agents / interrupt_agent）。
///
/// 设计要点（照 `IOSSkillMcpToolService` 模式做独立服务，经
/// `ChatToolRuntime.dispatchAdvancedToolCall` 分发）：
/// - 存储即真相：fork 会话走 `IOSConversationStore`（同写路径锁），spawn 边走
///   Room `thread_edge`，信封走 Room `mailbox_envelope`（NEW_TASK 直接渲染持久化
///   进子会话并标记 delivered，不等任何消费点；P1-d 后台引擎才有消费点）。
/// - 子 run 启动：durable 先行——构造 `IOSChatBackgroundHandoff` 落 payload 再经
///   后台协调器提交 BGTask（与既有「先落 handoff 再 submit」路径同构；子线程在
///   后台引擎里同样注册三工具，可 spawn 孙线程）。
/// - 终态回传：`notifyRunTerminal` 检查本会话是否有 Open 父 edge，有则向父线程
///   的 mailbox 投递 FINAL_ANSWER（前台 finishStreaming 与后台 job 终态两个挂钩点）。
///
@MainActor
final class IOSThreadOrchestrationToolService {

    /// P1-c 结构化错误码（常量集中；P1-e 会按并发限额细化文案/参数）。
    enum ErrorCode {
        static let agentLimitReached = "agent_limit_reached"
        static let agentDepthLimit = "agent_depth_limit"
        static let invalidTaskName = "invalid_task_name"
        static let invalidArguments = "invalid_arguments"
        static let unknownTarget = "unknown_target"
        static let notADescendant = "not_a_descendant"
        static let missingContext = "missing_context"
        static let startFailed = "start_failed"
        /// P1-d: send_message/followup_task 拒绝发给自己。
        static let cannotMessageSelf = "cannot_message_self"
    }

    /// 线程边状态（wire 字符串，与 KMP `ThreadEdgeStatus` 常量同值）。
    enum EdgeStatus {
        static let open = "Open"
        static let closed = "Closed"
    }

    /// 深度上限：/root(0) → 子(1) → 孙(2)。spawn 时沿 edge 链查父深度，
    /// 父深度 >= 2（将产生第 3 代）时拒绝。
    static let maxThreadDepth = 2

    /// 默认并发上限。运行时优先读取 shared settings，测试/旧调用点可通过
    /// initializer 显式覆盖；占用只统计子代理，不把父线程算进来。
    static let defaultMaxConcurrentRuns = 2

    /// FINAL_ANSWER 正文摘要长度；截断说明和原文引用不计入此限额。
    static let finalAnswerMaxChars = 2_000

    /// 后台 job 的调度面（生产 = `IOSChatBackgroundGenerationCoordinator.shared`，
    /// 测试注入 fake 捕获 handoff）。childThreadId 一律用 hex-dash 字符串传递，
    /// 避免在 Swift 侧从字符串重建 KotlinUuid。
    @MainActor
    protocol BackgroundScheduling: AnyObject {
        func start(
            handoff: IOSChatBackgroundHandoff,
            conversationStore: IOSConversationStore,
            toolRuntime: ChatToolRuntime,
            liveActivityController: AgentLiveActivityController,
            saveMiniAppIfPresent: (@MainActor ([UIMessage], KotlinUuid?) -> ChatMiniAppOutputApplication?)?
        ) -> Bool

        func activeRunId(conversationHex: String) -> String?

        /// P1-e: 后台活跃 job 计数（并发限额的活注册表来源之一；生产 =
        /// activeJobs.count）。
        var activeJobCount: Int { get }

        /// Child-only occupancy and configured model/provider counts. Production
        /// supplies these from its active child registry; defaults keep existing
        /// test fakes source-compatible during migration.
        var activeSubAgentJobCount: Int { get }
        var activeModelCounts: [String: Int] { get }
        var activeProviderCounts: [String: Int] { get }

        @discardableResult
        func cancelJob(runId: String) -> Bool
    }






    private let conversationStoreProvider: () -> IOSConversationStore?
    private let mailboxDaoProvider: () -> MailboxDao
    private let threadEdgeDaoProvider: () -> ThreadEdgeDao
    private let agentRuntimeDaoProvider: () -> AgentRuntimeDao
    private let backgroundCoordinator: any BackgroundScheduling
    private let makeBackgroundToolRuntime: () -> ChatToolRuntime
    private let currentConversationId: () -> KotlinUuid?
    private let foregroundActiveRunId: (String) -> String?
    private let cancelForegroundRun: (String) -> Bool
    /// P1-e: 全局前台活跃 run 判定（0/1）。生产 = `generationCoordinator.isRunning`
    /// （P1-c `activeForegroundRunId` 的同一来源，任意会话都算 1 个活跃槽）。
    private let foregroundRunCount: () -> Int
    private let maxConcurrentRunsOverride: Int?
    /// P1-e: spawn bootstrap 在途计数（服务内跟踪）。限额检查与占槽之间无
    /// await（全部 MainActor 同步读），两个并发 spawn 不会同时通过检查。
    private var inFlightBootstrapCount = 0
    /// Idle followup bootstrap and terminal resume share one per-child gate.
    /// A second operation waits for the first operation's active check plus
    /// enqueue/start sequence, instead of observing a transient idle window.
    private var inFlightFollowupTargets: Set<String> = []
    private var followupGateWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// P1-d: 进程内 mailbox 活动广播（wait_agent 的事件源；默认共享实例）。
    private let activityCenter: IOSMailboxActivityCenter
    /// M4: role_assistant_id 存在性校验（生产 = 设置快照里的 assistants；
    /// 默认恒真 = 未注入校验器的调用方/测试不误伤，生产接线必须注入）。
    private let roleAssistantExists: (KotlinUuid) -> Bool
    private let soulMarkdown: () -> String
    /// Read settings at launch time. The effective values are copied into the
    /// child marker; followups do not read the parent's current settings again.
    private let sharedSettingsProvider: () -> IOSSharedSettingsStore?
    private let jevCoordinator: IOSJevDecisionCoordinator
    /// exec store 的单一所有者；fork 时把父会话的 store 复制给子会话。
    private let jsCellRegistry: IOSJsCellRegistry
    private let jevSettingsProvider: () -> IOSJevSettings
    private let modelPool: IOSSubAgentModelPool
    private let controlCommands: IOSOrchestrationControlCommands
    private let launchPolicy: IOSOrchestrationLaunchPolicy
    private let jevRouting: IOSOrchestrationJevRouting
    /// P1-d: wait_agent 超时 clamp 区间与默认值（测试注入小下限避免真实等待）。
    private let waitTimeoutMinMs: Int64
    private let waitTimeoutMaxMs: Int64
    private let waitTimeoutDefaultMs: Int64

    private func acquireFollowupGate(for targetHex: String) async {
        guard !inFlightFollowupTargets.insert(targetHex).inserted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            followupGateWaiters[targetHex, default: []].append(continuation)
        }
    }

    private func releaseFollowupGate(for targetHex: String) {
        guard var waiters = followupGateWaiters[targetHex], !waiters.isEmpty else {
            inFlightFollowupTargets.remove(targetHex)
            return
        }
        let next = waiters.removeFirst()
        if waiters.isEmpty {
            followupGateWaiters.removeValue(forKey: targetHex)
        } else {
            followupGateWaiters[targetHex] = waiters
        }
        // Keep the target in `inFlightFollowupTargets` while handing ownership
        // to the resumed waiter. The next acquire therefore returns directly.
        next.resume()
    }

    init(
        conversationStoreProvider: @escaping () -> IOSConversationStore?,
        mailboxDaoProvider: @escaping () -> MailboxDao,
        threadEdgeDaoProvider: @escaping () -> ThreadEdgeDao,
        agentRuntimeDaoProvider: @escaping () -> AgentRuntimeDao,
        backgroundCoordinator: any BackgroundScheduling,
        makeBackgroundToolRuntime: @escaping () -> ChatToolRuntime,
        currentConversationId: @escaping () -> KotlinUuid?,
        foregroundActiveRunId: @escaping (String) -> String?,
        cancelForegroundRun: @escaping (String) -> Bool,
        foregroundRunCount: @escaping () -> Int = { 0 },
        maxConcurrentRuns: Int? = nil,
        activityCenter: IOSMailboxActivityCenter = .shared,
        waitTimeoutMinMs: Int64 = 5_000,
        waitTimeoutMaxMs: Int64 = 300_000,
        waitTimeoutDefaultMs: Int64 = 30_000,
        roleAssistantExists: @escaping (KotlinUuid) -> Bool = { _ in true },
        soulMarkdown: @escaping () -> String = { "" },
        sharedSettingsProvider: @escaping () -> IOSSharedSettingsStore? = { nil },
        jevCoordinator: IOSJevDecisionCoordinator = .shared,
        jevSettingsProvider: @escaping () -> IOSJevSettings = { IOSSharedSettingsStore.loadPersistedJevSettings() },
        jsCellRegistry: IOSJsCellRegistry = .shared
    ) {
        self.conversationStoreProvider = conversationStoreProvider
        self.mailboxDaoProvider = mailboxDaoProvider
        self.threadEdgeDaoProvider = threadEdgeDaoProvider
        self.agentRuntimeDaoProvider = agentRuntimeDaoProvider
        self.backgroundCoordinator = backgroundCoordinator
        self.makeBackgroundToolRuntime = makeBackgroundToolRuntime
        self.currentConversationId = currentConversationId
        self.foregroundActiveRunId = foregroundActiveRunId
        self.cancelForegroundRun = cancelForegroundRun
        self.foregroundRunCount = foregroundRunCount
        self.maxConcurrentRunsOverride = maxConcurrentRuns
        self.activityCenter = activityCenter
        self.waitTimeoutMinMs = waitTimeoutMinMs
        self.waitTimeoutMaxMs = waitTimeoutMaxMs
        self.waitTimeoutDefaultMs = waitTimeoutDefaultMs
        self.roleAssistantExists = roleAssistantExists
        self.soulMarkdown = soulMarkdown
        self.sharedSettingsProvider = sharedSettingsProvider
        self.jevCoordinator = jevCoordinator
        self.jsCellRegistry = jsCellRegistry
        self.jevSettingsProvider = jevSettingsProvider
        let modelPool = IOSSubAgentModelPool()
        self.modelPool = modelPool
        self.launchPolicy = IOSOrchestrationLaunchPolicy(sharedSettingsProvider: sharedSettingsProvider, modelPool: modelPool, backgroundCoordinator: backgroundCoordinator)
        self.jevRouting = IOSOrchestrationJevRouting(sharedSettingsProvider: sharedSettingsProvider, modelPool: modelPool, jevCoordinator: jevCoordinator, jevSettingsProvider: jevSettingsProvider)
        self.controlCommands = IOSOrchestrationControlCommands(
            conversationStoreProvider: conversationStoreProvider,
            mailboxDaoProvider: mailboxDaoProvider,
            threadEdgeDaoProvider: threadEdgeDaoProvider,
            agentRuntimeDaoProvider: agentRuntimeDaoProvider,
            backgroundCoordinator: backgroundCoordinator,
            currentConversationId: currentConversationId,
            foregroundActiveRunId: foregroundActiveRunId,
            cancelForegroundRun: cancelForegroundRun,
            activityCenter: activityCenter,
            sharedSettingsProvider: sharedSettingsProvider,
            modelPool: modelPool,
            waitTimeoutMinMs: waitTimeoutMinMs,
            waitTimeoutMaxMs: waitTimeoutMaxMs,
            waitTimeoutDefaultMs: waitTimeoutDefaultMs
        )
    }

    // MARK: - Dispatch

    func execute(
        toolName: String,
        arguments: String,
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        runId: String,
        conversationId: KotlinUuid? = nil,
        toolExposureBridge: IosToolExposureBridge? = nil,
        executionPolicy: IOSExecutionPolicySnapshot? = nil
    ) async -> String {
        switch toolName {
        case "spawn_agent":
            return await spawnAgent(
                arguments: arguments,
                providerSetting: providerSetting,
                params: params,
                parentRunId: runId,
                conversationId: conversationId,
                toolExposureBridge: toolExposureBridge,
                executionPolicy: executionPolicy
            )
        case "list_agents":
            return await controlCommands.listAgents(
                arguments: arguments,
                conversationId: conversationId,
                capacitySnapshot: { (self.configuredMaxConcurrentRuns, self.occupiedRunSlotCount) }
            )
        case "interrupt_agent":
            return await controlCommands.interruptAgent(arguments: arguments, conversationId: conversationId)
        case "send_message":
            return await controlCommands.sendMessage(arguments: arguments, runId: runId, conversationId: conversationId)
        case "followup_task":
            return await followupTask(
                arguments: arguments,
                providerSetting: providerSetting,
                params: params,
                runId: runId,
                conversationId: conversationId,
                toolExposureBridge: toolExposureBridge,
                executionPolicy: executionPolicy
            )
        case "wait_agent":
            return await controlCommands.waitAgent(arguments: arguments, conversationId: conversationId)
        default:
            return Self.errorJSON(toolName: toolName, code: ErrorCode.invalidArguments, reason: "未知编排工具 \(toolName)")
        }
    }

    // MARK: - spawn_agent

    /// P1-e: 活注册表占用槽数 = 在途 bootstrap + 前台活跃 run(0/1) + 后台活跃
    /// job。替代全局 recoverable 账本计数：崩溃残留的 running 行不再占用
    /// 并发槽（恢复扫描前的窗口期不误伤 spawn）。
    private var occupiedRunSlotCount: Int {
        inFlightBootstrapCount
            + backgroundCoordinator.activeSubAgentJobCount
    }

    private var configuredMaxConcurrentRuns: Int {
        let value = maxConcurrentRunsOverride
            ?? sharedSettingsProvider()?.subAgentMaxConcurrentRuns
            ?? Self.defaultMaxConcurrentRuns
        return min(10, max(1, value))
    }

    private func spawnAgent(
        arguments: String,
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        parentRunId: String,
        conversationId: KotlinUuid?,
        toolExposureBridge: IosToolExposureBridge?,
        executionPolicy: IOSExecutionPolicySnapshot?
    ) async -> String {
        guard let args = ChatToolCallParsing.jsonObject(arguments),
              let taskNameRaw = args["task_name"] as? String,
              let message = args["message"] as? String else {
            return Self.errorJSON(
                toolName: "spawn_agent",
                code: ErrorCode.invalidArguments,
                reason: "spawn_agent 需要 task_name 与 message。"
            )
        }
        let taskName = taskNameRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidTaskName(taskName) else {
            return Self.errorJSON(
                toolName: "spawn_agent",
                code: ErrorCode.invalidTaskName,
                reason: "task_name 只能包含小写字母、数字与下划线（^[a-z0-9_]+$），实际: \(taskNameRaw)"
            )
        }
        let forkTurns = (args["fork_turns"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "all"
        guard forkTurns == "none" || forkTurns == "all" || (Int(forkTurns) ?? -1) > 0 else {
            return Self.errorJSON(
                toolName: "spawn_agent",
                code: ErrorCode.invalidArguments,
                reason: "fork_turns 必须是 \"none\"、\"all\" 或正整数，实际: \(forkTurns)"
            )
        }
        let roleAssistantId = (args["role_assistant_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        // M4: role_assistant_id 应用到子会话 assistantId（fork 后改字段再保存）。
        // 先校验：格式非法或 assistant 不存在 → 诚实错误，不创建子线程。
        // 注意 KotlinUuid.parse 对非法串在 K/N 导出下不抛 Swift 错误而是终止
        // 进程（NSException）——必须先用 Foundation UUID(uuidString:) 正则级
        // 校验拦截（并归一化小写，Kotlin stdlib 的 parse 只认小写十六进制）。
        var resolvedRoleAssistantId: KotlinUuid? = nil
        if let roleAssistantId {
            let normalizedRoleId = roleAssistantId.lowercased()
            guard UUID(uuidString: normalizedRoleId) != nil else {
                return Self.errorJSON(
                    toolName: "spawn_agent",
                    code: ErrorCode.invalidArguments,
                    reason: "role_assistant_id 不是合法的 assistant id：\(roleAssistantId)"
                )
            }
            let roleUuid = KotlinUuid.companion.parse(uuidString: normalizedRoleId)
            guard roleAssistantExists(roleUuid) else {
                return Self.errorJSON(
                    toolName: "spawn_agent",
                    code: ErrorCode.invalidArguments,
                    reason: "role_assistant_id 不存在：\(roleAssistantId)。请用 list 或设置页确认 assistant id。"
                )
            }
            resolvedRoleAssistantId = roleUuid
        }

        guard let store = conversationStoreProvider() else {
            return Self.errorJSON(
                toolName: "spawn_agent",
                code: ErrorCode.missingContext,
                reason: "会话存储不可用，无法创建子线程。"
            )
        }
        // 父会话 = run 锚定的 conversationId（execute 透传；生成中切会话不串边）。
        // `currentConversationId()` 仅作兜底：调用方未透传时（旧调用点/直接驱动
        // 服务的测试）才回退读 VM 当前会话。
        guard let parentConversationId = conversationId ?? currentConversationId() else {
            return Self.errorJSON(
                toolName: "spawn_agent",
                code: ErrorCode.missingContext,
                reason: "当前会话不可用，无法确定父线程。"
            )
        }
        let parentHex = parentConversationId.toHexDashString()
        let threadEdgeDao = threadEdgeDaoProvider()

        // (b) 深度上限（父深度 >= 2 → 第 3 代拒绝）。
        let parentDepth = await IOSOrchestrationPersistence.depth(of: parentHex, threadEdgeDao: threadEdgeDao)
        guard parentDepth < Self.maxThreadDepth else {
            return Self.errorJSON(
                toolName: "spawn_agent",
                code: ErrorCode.agentDepthLimit,
                reason: "线程深度已达上限（/root 起最多 \(Self.maxThreadDepth) 层）。请用当前线程完成子任务或汇总结果。"
            )
        }
        // (d-pre) Jev Phase 3：fork 源读取与异步判断在占槽前完成——等待网络
        // 期间不占用 bootstrap 槽，避免 active 调度延迟挤占其他 spawn 的并发
        // 名额（P2-6）。fork 本身仍发生在占槽之后。
        let sourceConversation: Conversation?
        if let current = store.currentConversation, current.id == parentConversationId {
            sourceConversation = current
        } else {
            sourceConversation = try? await store.loadConversationForOrchestration(parentConversationId)
        }
        guard let sourceConversation else {
            return Self.errorJSON(
                toolName: "spawn_agent",
                code: ErrorCode.missingContext,
                reason: "无法读取当前会话，无法 fork。"
            )
        }
        let inheritedConfiguration = IOSOrchestrationConfigurationCodec.orchestrationConfiguration(from: sourceConversation.currentMessages)
        let jevDecision = await jevRouting.jevSpawnDecision(
            arguments: args,
            parentRunId: parentRunId,
            allowPoolForInheritedModel: true,
            inherited: IOSOrchestrationLaunchPolicy.hasAgentConfigurationArguments(args) ? nil : inheritedConfiguration,
            sourceConversation: sourceConversation,
            includeRoleIntent: true
        )
        // (c) 并发上限：活注册表占用（前台 run 0/1 + 后台 activeJobs + 本服务在途
        // bootstrap 槽，含 spawner 自身——与旧全局账本计数「含父自身」同语义）。
        // 检查与占槽之间无 await（三个计数源全部 MainActor 同步），并发 spawn
        // 不会双双通过；defer 在 spawn 收口（成功入后台注册表或失败回收）时释放。
        guard occupiedRunSlotCount < configuredMaxConcurrentRuns else {
            return Self.errorJSON(
                toolName: "spawn_agent",
                code: ErrorCode.agentLimitReached,
                reason: "并发运行数已达上限（\(configuredMaxConcurrentRuns) 个子代理）。请先等待或 interrupt 一个子线程再 spawn。"
            )
        }
        inFlightBootstrapCount += 1
        defer { inFlightBootstrapCount -= 1 }

        let parentAgentPath = await IOSOrchestrationPersistence.agentPath(of: parentHex, threadEdgeDao: threadEdgeDao)
        // (a) 同父 task_name 冲突时优先换稳定英文名；仅当兜底名池耗尽
        // 才追加数字后缀（按已有直接子 agentPath 判定）。
        let resolvedTaskName = await IOSOrchestrationPersistence.uniqueTaskName(
            taskName,
            parentAgentPath: parentAgentPath,
            threadEdgeDao: threadEdgeDao
        )
        let childAgentPath = "\(parentAgentPath)/\(resolvedTaskName)"
        let childConversationId = KotlinUuid.companion.random()
        let childHex = childConversationId.toHexDashString()
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        // (d) fork 会话（三模式 + 变体折叠 + 截断安全），直接经 store 落盘。
        // fork 源与 inherited 已在占槽前读取（见 d-pre）。
        let launchResult = launchPolicy.resolveAgentLaunch(
            arguments: args,
            providerSetting: providerSetting,
            params: params,
            toolExposureBridge: toolExposureBridge,
            inherited: IOSOrchestrationLaunchPolicy.hasAgentConfigurationArguments(args) ? nil : inheritedConfiguration,
            allowPoolForInheritedModel: true,
            jevPreferredModelIds: jevDecision.preferredModelIds,
            jevObservedPreferredModelIds: jevDecision.observedPreferredModelIds,
            jevSuggestedRoleId: jevDecision.intent.roleId
        )
        let launch: IOSOrchestrationLaunchPolicy.ResolvedAgentLaunch
        switch launchResult {
        case .success(let value):
            launch = value
        case .failure(let error):
            return Self.errorJSON(
                toolName: "spawn_agent",
                code: ErrorCode.invalidArguments,
                reason: error.reason
            )
        }
        defer { modelPool.release(launch.modelReservation) }
        let forked = ConversationForkKt.forkConversation(
            source: sourceConversation,
            newId: childConversationId,
            newTitle: resolvedTaskName,
            forkTurns: forkTurns,
            assistantId: resolvedRoleAssistantId
        )
        // Persist the relationship before any child document. A saved child
        // must remain identifiable after a restart, even if bootstrap stops here.
        do {
            try await threadEdgeDao.insertEdge(
                edge: ThreadEdgeEntity(
                    childThreadId: childHex,
                    parentThreadId: parentHex,
                    agentPath: childAgentPath,
                    nickname: nil,
                    roleAssistantId: roleAssistantId,
                    forkTurns: forkTurns,
                    status: EdgeStatus.open,
                    createdAt: now
                )
            )
        } catch {
            return Self.errorJSON(
                toolName: "spawn_agent", code: ErrorCode.startFailed,
                reason: "子代理关系保存失败，任务未启动：\(error.localizedDescription)"
            )
        }
        store.registerSubagentConversation(id: childConversationId)
        guard await store.saveForkedConversation(forked) else {
            return Self.errorJSON(
                toolName: "spawn_agent",
                code: ErrorCode.startFailed,
                reason: "子会话持久化失败，请重试。"
            )
        }
        // fork 的转录保留了父会话的 exec 调用：复制 store，使这些调用写入的值
        // 在子会话按分支可见性照常可读（不带任何 exec 调用的 fork 读不到）。
        if !forked.currentMessages.isEmpty {
            await jsCellRegistry.copyStore(
                fromSessionKey: parentConversationId.description(),
                toSessionKey: childConversationId.description()
            )
        }

        // (f) bootstrap：NEW_TASK 信封渲染为 user 消息直接持久化进子会话，
        // 信封 Room 记录标 delivered（不等任何消费点）。
        let newTaskMessage = IosMailboxMessageBridge.shared.makeMessage(
            authorThreadId: parentAgentPath,
            type: MailboxEnvelopeType.theNewTask.name,
            payload: message
        )
        let forkMessages = IOSOrchestrationConfigurationCodec.removingOrchestrationConfigurationMessages(from: forked.currentMessages)
        var childMessages = forkMessages
        if let configuration = launch.configuration {
            childMessages.append(IOSOrchestrationConfigurationCodec.orchestrationConfigurationMessage(configuration))
        }
        childMessages.append(newTaskMessage)
        guard await IOSOrchestrationPersistence.persistTargetMessages(store: store, conversationId: childConversationId, messages: childMessages) else {
            return Self.errorJSON(
                toolName: "spawn_agent",
                code: ErrorCode.startFailed,
                reason: "子会话写入初始任务失败，请重试。"
            )
        }
        // 审计信封入队失败不阻塞 spawn（会话与边已持久化；IGNORE 幂等且
        // 不会像 ABORT 那样把 SQLite 冲突异常带出 @Throws 边界）。
        try? await IOSOrchestrationPersistence.enqueueIfAbsent(
            mailboxDao: mailboxDaoProvider(),
            envelope: MailboxEnvelopeEntity(
                id: "new-task-\(childHex)",
                authorThreadId: parentAgentPath,
                recipientThreadId: childHex,
                type: MailboxEnvelopeType.theNewTask.name,
                payload: message,
                triggerTurn: true,
                parentTurnId: parentRunId,
                createdAt: now,
                deliveredAt: KotlinLong(value: now) // bootstrap 已直接渲染持久化，信封仅留审计记录
            )
        )

        // (g) 启动子 run（P1-d 抽取助手：记账 + durable handoff → BGTask；
        // start 失败回收 running 行，见助手内注释）。
        let childRunId = UUID().uuidString
        guard let _ = await startDurableBackgroundRun(
            targetConversationId: childConversationId,
            targetHex: childHex,
            targetMessages: childMessages,
            renderedText: newTaskMessage.toText(),
            providerSetting: launch.providerSetting,
            params: launch.params,
            runId: childRunId,
            store: store,
            toolExposureBridge: toolExposureBridge,
            executionPolicy: executionPolicy,
            configuration: launch.configuration,
            modelReservation: launch.modelReservation
        ) else {
            return Self.errorJSON(
                toolName: "spawn_agent",
                code: ErrorCode.startFailed,
                reason: "子线程已创建但后台任务提交失败（子会话与边已持久化，线程保留可再次派活）。"
            )
        }
        jevRouting.recordSelectedPoolModelIfNeeded(
            launch: launch,
            decision: jevDecision,
            runId: parentRunId,
            childRunId: childRunId,
            childThreadId: childHex
        )
        jevRouting.recordIntentSelectionIfNeeded(launch: launch, decision: jevDecision, runId: parentRunId)
        jevRouting.scheduleDeferredShadowT3ObservationIfNeeded(
            decision: jevDecision,
            launch: launch,
            runId: parentRunId,
            childRunId: childRunId,
            childThreadId: childHex
        )

        var spawnResult: [String: Any] = [
            "ok": true,
            "tool": "spawn_agent",
            "task_name": resolvedTaskName,
            "agent_path": childAgentPath,
            "child_thread_id": childHex,
            "status": "started",
        ]
        // 对齐回执：Jev 判定子任务偏离用户最新请求时如实标注。仅 active 会
        // 产出标注（shadow/off 为空建议）；标注不改变 spawn 结果本身。
        if jevDecision.intent.alignmentDoubtful {
            spawnResult["jev_alignment"] = "doubtful"
        }
        return IOSWorkspaceStore.json(spawnResult)
    }

    // MARK: - list_agents

    /// P1-e: 控制面纪律查询——该会话是否存在 thread_edge（有 edge 即编排子线程，
    /// 只读；含 Closed 边：interrupt 取消/已完成线程同样不可直接输入）。
    /// 调用方（ChatViewModel）在会话切换时刷新并缓存，不在每条 keystroke 上直查。
    func isOrchestratedChild(conversationId: KotlinUuid) async -> Bool {
        await IOSOrchestrationPersistence.edgeFor(
            childThreadId: conversationId.toHexDashString(),
            threadEdgeDao: threadEdgeDaoProvider()
        ) != nil
    }

    /// 是否有子边（作为父线程）。供运行时上下文注入判定：只有参与线程树的
    /// 会话才注入 mailbox 语义说明，普通会话不付这笔 token。
    func hasOrchestrationChildren(conversationId: KotlinUuid) async -> Bool {
        await withCheckedContinuation { cont in
            threadEdgeDaoProvider().childrenOf(parentThreadId: conversationId.toHexDashString()) { result, _ in
                cont.resume(returning: !(result ?? []).isEmpty)
            }
        }
    }

    /// Resolve one spawn/followup configuration. `nil` means the caller did
    /// not request a role/configuration and should inherit the parent's params.
    /// An empty `tool_scope` is intentionally preserved as an empty set: it is
    /// different from an omitted scope, which inherits the parent catalog.
    /// T3：spawn 将模型调度与缺省角色意图合并成一次批量判断；followup 只加入模型调度。
    /// active 结果在占用 bootstrap 名额前等待；全 shadow 等 durable start 成功后再后台观察。
    /// 不持有模型预留；显式 model_id / role_id 整批跳过。
    static let modelRoutingTimeoutTerminalReason = IOSOrchestrationJevRouting.modelRoutingTimeoutTerminalReason

    static func shouldRequestJevSubAgentIntent(
        arguments: [String: Any],
        inheritedConfiguration: IOSOrchestrationAgentConfiguration?
    ) -> Bool {
        IOSOrchestrationLaunchPolicy.shouldRequestJevSubAgentIntent(
            arguments: arguments, inheritedConfiguration: inheritedConfiguration
        )
    }

    static func childUploadMessages(
        targetMessages: [UIMessage],
        soulMarkdown: String,
        configuration: IOSOrchestrationAgentConfiguration? = nil,
        availableToolNames: Set<String> = []
    ) -> [UIMessage] {
        IOSOrchestrationConfigurationCodec.childUploadMessages(
            targetMessages: targetMessages, soulMarkdown: soulMarkdown,
            configuration: configuration, availableToolNames: availableToolNames
        )
    }

    /// Child work must not inherit the chat surface's small output budget.
    static let childRunMinOutputTokens: Int32 = 32_768

    /// User-facing child-page followup. The page has no parent run to borrow for
    /// target resolution, so resolve the child's recorded parent first and then
    /// reuse the exact followup path (queue an active run, bootstrap an idle run).
    func appendUserTask(
        to targetConversationId: KotlinUuid,
        message: String,
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        toolExposureBridge: IosToolExposureBridge? = nil,
        executionPolicy: IOSExecutionPolicySnapshot? = nil
    ) async -> String {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            return Self.errorJSON(
                toolName: "followup_task",
                code: ErrorCode.invalidArguments,
                reason: "message 不能为空。"
            )
        }
        let childHex = targetConversationId.toHexDashString()
        guard let edge = await IOSOrchestrationPersistence.edgeFor(
            childThreadId: childHex,
            threadEdgeDao: threadEdgeDaoProvider()
        ), let parentId = IOSOrchestrationLaunchPolicy.parseKotlinUuid(edge.parentThreadId) else {
            return Self.errorJSON(
                toolName: "followup_task",
                code: ErrorCode.unknownTarget,
                reason: "找不到子代理线程 \(childHex)。"
            )
        }
        let arguments = IOSWorkspaceStore.json([
            "target": childHex,
            "message": trimmedMessage
        ])
        return await followupTask(
            arguments: arguments,
            providerSetting: providerSetting,
            params: params,
            runId: "user-followup-\(UUID().uuidString)",
            conversationId: parentId,
            toolExposureBridge: toolExposureBridge,
            executionPolicy: executionPolicy
        )
    }

    /// Resume a child after its background run released ownership. The old run
    /// may have reached a terminal boundary while a NEW_TASK was being queued;
    /// this path folds every pending task into one durable bootstrap. Pending
    /// envelopes are only marked delivered after the new BG task was accepted,
    /// so a failed start remains recoverable for a later retry.
    @discardableResult
    func resumePendingTasks(
        for conversationId: KotlinUuid,
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        toolExposureBridge: IosToolExposureBridge? = nil,
        executionPolicy: IOSExecutionPolicySnapshot? = nil
    ) async -> Bool {
        let targetHex = conversationId.toHexDashString()
        await acquireFollowupGate(for: targetHex)
        defer { releaseFollowupGate(for: targetHex) }

        // The coordinator invokes this after releasing its active ownership,
        // but keep the guard here as well for foreground/background races.
        guard foregroundActiveRunId(targetHex) == nil,
              backgroundCoordinator.activeRunId(conversationHex: targetHex) == nil,
              let edge = await IOSOrchestrationPersistence.edgeFor(
                  childThreadId: targetHex,
                  threadEdgeDao: threadEdgeDaoProvider()
              ),
              edge.status == EdgeStatus.open else {
            return false
        }
        let pending = await IOSOrchestrationPersistence.pendingTaskSnapshots(
            mailboxDao: mailboxDaoProvider(),
            recipientId: targetHex
        )
        guard !pending.isEmpty,
              let store = conversationStoreProvider(),
              let targetId = IOSOrchestrationLaunchPolicy.parseKotlinUuid(targetHex) else {
            return false
        }
        guard occupiedRunSlotCount < configuredMaxConcurrentRuns else {
            return false
        }
        inFlightBootstrapCount += 1
        defer { inFlightBootstrapCount -= 1 }

        let currentMessages: [UIMessage]
        if store.currentConversation?.id == targetId {
            currentMessages = store.currentConversation?.currentMessages ?? []
        } else {
            guard let conversation = try? await store.loadConversationForOrchestration(targetId) else {
                return false
            }
            currentMessages = conversation.currentMessages
        }

        let inheritedConfiguration = IOSOrchestrationConfigurationCodec.orchestrationConfiguration(from: currentMessages)
        let launchResult = launchPolicy.resolveAgentLaunch(
            arguments: [:],
            providerSetting: providerSetting,
            params: params,
            toolExposureBridge: toolExposureBridge,
            inherited: inheritedConfiguration,
            allowPoolForInheritedModel: false
        )  // 邮箱恢复路径无 task 文本，模型调度走现有选择
        let launch: IOSOrchestrationLaunchPolicy.ResolvedAgentLaunch
        switch launchResult {
        case .success(let value):
            launch = value
        case .failure:
            // Configuration errors do not consume the mailbox. The next user
            // retry can repair the child settings and try again.
            return false
        }
        defer { modelPool.release(launch.modelReservation) }

        let taskMessages = pending.map { envelope in
            amberMailboxMessage(
                envelopeId: envelope.id,
                authorThreadId: envelope.authorThreadId,
                type: MailboxEnvelopeType.theNewTask.name,
                payload: envelope.payload
            )
        }
        var updatedMessages = IOSOrchestrationConfigurationCodec.removingOrchestrationConfigurationMessages(from: currentMessages)
        if let configuration = launch.configuration {
            updatedMessages.append(IOSOrchestrationConfigurationCodec.orchestrationConfigurationMessage(configuration))
        }
        // A previous start may have persisted these messages before BGTask
        // submission failed. Stable envelope-derived ids make a retry merge
        // them instead of appending another visible copy.
        let existingMessageIds = Set(updatedMessages.map { $0.id.toHexDashString().lowercased() })
        updatedMessages.append(contentsOf: taskMessages.filter {
            !existingMessageIds.contains($0.id.toHexDashString().lowercased())
        })

        // Keep the same write-before-start ordering as the ordinary idle
        // followup bootstrap. If this fails, every envelope stays pending.
        guard await IOSOrchestrationPersistence.persistTargetMessages(
            store: store,
            conversationId: targetId,
            messages: updatedMessages
        ) else {
            return false
        }

        let renderedText = taskMessages.map { $0.toText() }.joined(separator: "\n")
        guard await startDurableBackgroundRun(
            targetConversationId: targetId,
            targetHex: targetHex,
            targetMessages: updatedMessages,
            renderedText: renderedText,
            providerSetting: launch.providerSetting,
            params: launch.params,
            runId: UUID().uuidString,
            store: store,
            toolExposureBridge: toolExposureBridge,
            executionPolicy: executionPolicy,
            configuration: launch.configuration,
            modelReservation: launch.modelReservation
        ) != nil else {
            // The task messages are already durable, but the original Room
            // envelopes remain pending and can drive a later retry.
            return false
        }

        let deliveredAt = Int64(Date().timeIntervalSince1970 * 1000)
        let delivered = await IOSOrchestrationPersistence.markDelivered(
            mailboxDao: mailboxDaoProvider(),
            ids: pending.map(\.id),
            deliveredAt: deliveredAt
        )
        if delivered != pending.count {
            // A concurrent foreground drain may have claimed some envelopes.
            // The run is already durable; leave the DAO's exactly-once result
            // authoritative and do not start another run.
            NSLog(
                "[AmberOrchestration] pending task delivery changed during resume: %d/%d",
                delivered,
                pending.count
            )
        }
        await activityCenter.signal(conversationIdHex: targetHex)
        return true
    }

    /// P1-d: 投递不唤醒。信封（type=MESSAGE, triggerTurn=false）入目标 mailbox，
    /// idle 目标的消息留在 mailbox 直到其下次 run；运行中目标在工具循环边界折入。
    /// P1-d: 投递 + 唤醒。目标无活跃 run（前台/后台两路径判定，与 interrupt 同）
    /// → spawn 同款 bootstrap（信封渲染直写目标会话 + 标 delivered + durable
    /// 后台 run 启动）；有活跃 run → 留 pending 等目标边界 drain。
    private func followupTask(
        arguments: String,
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        runId: String,
        conversationId: KotlinUuid?,
        toolExposureBridge: IosToolExposureBridge?,
        executionPolicy: IOSExecutionPolicySnapshot?
    ) async -> String {
        guard let args = ChatToolCallParsing.jsonObject(arguments),
              let targetRaw = args["target"] as? String,
              let message = args["message"] as? String else {
            return Self.errorJSON(
                toolName: "followup_task",
                code: ErrorCode.invalidArguments,
                reason: "followup_task 需要 target 与 message。"
            )
        }
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            return Self.errorJSON(
                toolName: "followup_task",
                code: ErrorCode.invalidArguments,
                reason: "message 不能为空。"
            )
        }
        guard let runConversationId = conversationId ?? currentConversationId() else {
            return Self.errorJSON(
                toolName: "followup_task",
                code: ErrorCode.missingContext,
                reason: "当前会话不可用，无法确定发送方线程。"
            )
        }
        let resolved = await controlCommands.resolveTarget(targetRaw, runConversationId: runConversationId)
        guard case .success(let target) = resolved else {
            if case .failure(let failure) = resolved {
                return Self.errorJSON(toolName: "followup_task", code: failure.code, reason: failure.reason)
            }
            return Self.errorJSON(toolName: "followup_task", code: ErrorCode.unknownTarget, reason: "找不到线程 \(targetRaw)。")
        }
        // Serialize the active check with the complete enqueue/idle-bootstrap
        // sequence. A terminal callback can otherwise query an empty mailbox
        // while this task is suspended in `enqueue`, then both paths observe
        // idle and leave the newly queued task without an owner.
        await acquireFollowupGate(for: target.hex)
        defer { releaseFollowupGate(for: target.hex) }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let senderAgentPath = await IOSOrchestrationPersistence.agentPath(of: runConversationId.toHexDashString(), threadEdgeDao: threadEdgeDaoProvider())

        // 活跃 run 判定（前台当前会话 run 优先，其次后台 job；两路径与 interrupt 同）。
        let activeRunId = foregroundActiveRunId(target.hex)
            ?? backgroundCoordinator.activeRunId(conversationHex: target.hex)
        if activeRunId != nil {
            if IOSOrchestrationLaunchPolicy.hasAgentConfigurationArguments(args) {
                return Self.errorJSON(
                    toolName: "followup_task",
                    code: ErrorCode.invalidArguments,
                    reason: "目标线程正在运行，本次 followup 只能追加任务，不能在当前轮切换 role、提示词或工具范围。"
                )
            }
            // 运行中：仅入队（triggerTurn=true），目标在其工具循环边界 drain 折入。
            let envelope = MailboxEnvelopeEntity(
                id: "task-\(UUID().uuidString)",
                authorThreadId: senderAgentPath,
                recipientThreadId: target.hex,
                type: MailboxEnvelopeType.theNewTask.name,
                payload: trimmedMessage,
                triggerTurn: true,
                parentTurnId: runId,
                createdAt: now,
                deliveredAt: nil
            )
            do {
                try await IOSOrchestrationPersistence.enqueue(mailboxDao: mailboxDaoProvider(), envelope: envelope)
            } catch {
                return Self.errorJSON(
                    toolName: "followup_task",
                    code: ErrorCode.startFailed,
                    reason: "任务入队失败，请重试。"
                )
            }
            await activityCenter.signal(conversationIdHex: target.hex)
            return IOSWorkspaceStore.json([
                "ok": true,
                "tool": "followup_task",
                "target": targetRaw,
                "agent_path": target.edge?.agentPath ?? "/root",
                "recipient_thread_id": target.hex,
                "status": "queued",
            ])
        }

        // idle：bootstrap（信封渲染直写目标会话 + 标 delivered + durable 后台 run）。
        guard let store = conversationStoreProvider() else {
            return Self.errorJSON(
                toolName: "followup_task",
                code: ErrorCode.missingContext,
                reason: "会话存储不可用，无法派发任务。"
            )
        }
        let targetId: KotlinUuid
        do {
            targetId = try KotlinUuid.companion.parse(uuidString: target.hex)
        } catch {
            return Self.errorJSON(
                toolName: "followup_task",
                code: ErrorCode.unknownTarget,
                reason: "目标线程 id 无法解析：\(target.hex)"
            )
        }
        // P2-6：目标会话读取与 Jev 异步判断在占槽前完成，等待网络期间不占
        // bootstrap 槽；占槽检查与自增之间保持无 await。
        let currentMessages: [UIMessage]
        if store.currentConversation?.id == targetId {
            currentMessages = store.currentConversation?.currentMessages ?? []
        } else {
            guard let conversation = try? await store.loadConversationForOrchestration(targetId) else {
                return Self.errorJSON(
                    toolName: "followup_task",
                    code: ErrorCode.missingContext,
                    reason: "无法读取目标线程会话，无法派发任务。"
                )
            }
            currentMessages = conversation.currentMessages
        }
        let inheritedConfiguration = IOSOrchestrationConfigurationCodec.orchestrationConfiguration(from: currentMessages)
        let jevDecision = await jevRouting.jevSpawnDecision(
            arguments: args,
            parentRunId: runId,
            allowPoolForInheritedModel: false,
            inherited: inheritedConfiguration,
            sourceConversation: nil,
            includeRoleIntent: false
        )
        guard occupiedRunSlotCount < configuredMaxConcurrentRuns else {
            return Self.errorJSON(
                toolName: "followup_task",
                code: ErrorCode.agentLimitReached,
                reason: "并发运行数已达上限（\(configuredMaxConcurrentRuns) 个子代理）。请先等待或 interrupt 一个子线程再 followup_task。"
            )
        }
        inFlightBootstrapCount += 1
        defer { inFlightBootstrapCount -= 1 }

        let launchResult = launchPolicy.resolveAgentLaunch(
            arguments: args,
            providerSetting: providerSetting,
            params: params,
            toolExposureBridge: toolExposureBridge,
            inherited: inheritedConfiguration,
            allowPoolForInheritedModel: false,
            jevPreferredModelIds: jevDecision.preferredModelIds,
            jevObservedPreferredModelIds: jevDecision.observedPreferredModelIds
        )
        let launch: IOSOrchestrationLaunchPolicy.ResolvedAgentLaunch
        switch launchResult {
        case .success(let value):
            launch = value
        case .failure(let error):
            return Self.errorJSON(
                toolName: "followup_task",
                code: ErrorCode.invalidArguments,
                reason: error.reason
            )
        }
        defer { modelPool.release(launch.modelReservation) }
        let newTaskMessage = IosMailboxMessageBridge.shared.makeMessage(
            authorThreadId: senderAgentPath,
            type: MailboxEnvelopeType.theNewTask.name,
            payload: trimmedMessage
        )
        var updatedMessages = IOSOrchestrationConfigurationCodec.removingOrchestrationConfigurationMessages(from: currentMessages)
        if let configuration = launch.configuration {
            updatedMessages.append(IOSOrchestrationConfigurationCodec.orchestrationConfigurationMessage(configuration))
        }
        updatedMessages.append(newTaskMessage)
        // 信封渲染消息直写目标会话（与 spawn 的 bootstrap 同语义：先持久化，
        // 后 durable 启动；进程死亡也不丢任务消息）。
        guard await IOSOrchestrationPersistence.persistTargetMessages(store: store, conversationId: targetId, messages: updatedMessages) else {
            return Self.errorJSON(
                toolName: "followup_task",
                code: ErrorCode.startFailed,
                reason: "目标会话写入任务失败，请重试。"
            )
        }
        let targetRunId = UUID().uuidString
        guard let _ = await startDurableBackgroundRun(
            targetConversationId: targetId,
            targetHex: target.hex,
            targetMessages: updatedMessages,
            renderedText: newTaskMessage.toText(),
            providerSetting: launch.providerSetting,
            params: launch.params,
            runId: targetRunId,
            store: store,
            toolExposureBridge: toolExposureBridge,
            executionPolicy: executionPolicy,
            configuration: launch.configuration,
            modelReservation: launch.modelReservation
        ) else {
            return Self.errorJSON(
                toolName: "followup_task",
                code: ErrorCode.startFailed,
                reason: "目标线程已持久化但后台任务提交失败（线程保留，可再次 followup_task）。"
            )
        }
        jevRouting.recordSelectedPoolModelIfNeeded(
            launch: launch,
            decision: jevDecision,
            runId: runId,
            childRunId: targetRunId,
            childThreadId: target.hex
        )
        jevRouting.scheduleDeferredShadowT3ObservationIfNeeded(
            decision: jevDecision,
            launch: launch,
            runId: runId,
            childRunId: targetRunId,
            childThreadId: target.hex
        )
        // 审计信封：bootstrap 已直写会话，信封仅留审计记录（标 delivered，不参与 drain）。
        try? await IOSOrchestrationPersistence.enqueueIfAbsent(
            mailboxDao: mailboxDaoProvider(),
            envelope: MailboxEnvelopeEntity(
                id: "followup-\(UUID().uuidString)",
                authorThreadId: senderAgentPath,
                recipientThreadId: target.hex,
                type: MailboxEnvelopeType.theNewTask.name,
                payload: trimmedMessage,
                triggerTurn: true,
                parentTurnId: runId,
                createdAt: now,
                deliveredAt: KotlinLong(value: now)
            )
        )
        await activityCenter.signal(conversationIdHex: target.hex)
        return IOSWorkspaceStore.json([
            "ok": true,
            "tool": "followup_task",
            "target": targetRaw,
            "agent_path": target.edge?.agentPath ?? "/root",
            "recipient_thread_id": target.hex,
            "status": "started",
        ])
    }

    /// P1-d: 后台线程等待 mailbox 时先订阅（防丢信号）再查 pending；
    /// pending 非空立即返回，否则事件（含 steer 打断）与超时竞速。
    /// 前台根会话没有 mailbox 时返回 yielded 控制结果，让出交互 run。
    /// P1-d 抽取（自 spawn (f) 段）：写基线 + 保存目标会话消息（spawn/followup 共用）。
    /// P1-d 抽取（自 spawn (g) 段）：把「记账（agent_run running）+ durable
    /// handoff → BGTask」收口为一个助手，spawn_agent 与 followup_task 共用。
    /// start 失败时回收 running 行（避免孤儿行计入并发限额，保留 failed 审计
    /// 事实），返回 nil；成功返回 handoff。
    private func startDurableBackgroundRun(
        targetConversationId: KotlinUuid,
        targetHex: String,
        targetMessages: [UIMessage],
        renderedText: String,
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        runId: String,
        store: IOSConversationStore,
        toolExposureBridge: IosToolExposureBridge?,
        executionPolicy: IOSExecutionPolicySnapshot?,
        configuration: IOSOrchestrationAgentConfiguration? = nil,
        modelReservation: IOSSubAgentModelPool.Reservation? = nil
    ) async -> IOSChatBackgroundHandoff? {
        defer { modelPool.release(modelReservation) }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let inputDigest = chatInputDigest(for: renderedText)
        guard await IOSOrchestrationPersistence.recordRunningRun(
            agentRuntimeDao: agentRuntimeDaoProvider(),
            runId: runId,
            conversationId: targetHex,
            startedAt: now,
            inputDigest: inputDigest,
            protocolContext: AgentRunProtocolContext(
                providerId: providerSetting.id.description(),
                modelId: params.model.modelId,
                promptVersion: nil,
                toolCatalogVersion: chatInputDigest(
                    for: IosRunRequestSnapshotJsonBridge.shared.encodeToolCatalog(tools: params.tools)
                ),
                capabilitySnapshot: executionPolicy?.encodedJSON
            )
        ) else {
            return nil
        }
        // M3: fullToolNames 取 run 的桥全目录（对齐 ChatKernelRunHost
        // handoff 的做法）——params.tools 只是当轮可见子集，子线程目录会被
        // 永久截断（未暴露的 wm_* 等永远不可 search/命中）。桥不可用回退现行为。
        let inheritedFullToolNames = (toolExposureBridge?.fullToolDeclarations().map(\.name)
            ?? params.tools.map { $0.name })
            .filter { !IOSDynamicToolRegistry.isDynamicWorkflowToolName($0) }
        let fullToolNames: [String]
        if let scope = configuration?.toolScope {
            fullToolNames = inheritedFullToolNames.filter { scope.contains($0) }
        } else {
            fullToolNames = inheritedFullToolNames
        }
        // 管线闭环场景 C：子线程的后台 upload 不经 ChatViewModel 注入管线，
        // 直接在 handoff 里注入子线程向编排语境（仅 upload，不进展示/持久化）。
        let uploadMessages = IOSOrchestrationConfigurationCodec.childUploadMessages(
            targetMessages: targetMessages,
            soulMarkdown: soulMarkdown(),
            configuration: configuration,
            availableToolNames: Set(fullToolNames)
        )
        // 子线程是干活线程，不能继承聊天取向的输出上限：聊天下每条回复的
        // maxTokens 通常只有几千 token（或为 nil 吃服务商默认的小上限），长报告
        // 必被截断成"达到输出上限"终态（真机观察到的子代理失败）。地板 32k，
        // 父显式设了更大值则保留。
        let childParams = params.withMaxTokenFloor(Self.childRunMinOutputTokens)
        let handoff = IOSChatBackgroundHandoff(
            runId: runId,
            startedAt: now,
            inputDigest: inputDigest,
            conversationId: targetConversationId,
            providerId: providerSetting.id.toHexDashString(),
            providerSetting: providerSetting,
            // 同工具面：继承当前 run 的 params（含已暴露的编排工具，可 spawn 孙线程），
            // 仅 maxTokens 按上注做了地板提升。
            params: childParams,
            uploadMessages: uploadMessages,
            displayMessages: targetMessages,
            mode: .continueModel,
            generativeUiRequirement: .none,
            generativeUiFallbackAttempted: false,
            fullToolNames: fullToolNames,
            executionPolicy: executionPolicy,
            subAgentTimeoutSeconds: launchPolicy.subAgentTimeoutSeconds(for: configuration),
            runDisplayBaseline: targetMessages
        )
        let didStart = !Task.isCancelled && backgroundCoordinator.start(
            handoff: handoff,
            conversationStore: store,
            toolRuntime: makeBackgroundToolRuntime(),
            liveActivityController: .shared,
            saveMiniAppIfPresent: nil
        )
        guard didStart else {
            // P1-c 修复语义：回收 running 记账行——避免 start 失败留下 running
            // 孤儿行污染恢复账本，也不把失败 run 静默抹掉。
            await IOSOrchestrationPersistence.markRunFailed(
                agentRuntimeDao: agentRuntimeDaoProvider(),
                runId: runId,
                now: Int64(Date().timeIntervalSince1970 * 1000)
            )
            return nil
        }
        return handoff
    }

    // MARK: - FINAL_ANSWER 终态回传（前台 finishStreaming / 后台 job 完成共用）

    /// run 终态钩子：本会话有 Open 父 edge 时，向父线程 mailbox 投递 FINAL_ANSWER
    /// （payload = 最后 assistant 文本摘要，必要时附带原文分页引用；triggerTurn=false；
    /// parentTurnId = 本 runId）。父线程在其下一边界/下一 run 头经 P1-b 机制折入。
    /// Production run owners pass their frozen display baseline; nil is only
    /// for direct callers whose finalMessages already contain this run alone.
    func notifyRunTerminal(
        conversationId: KotlinUuid?,
        runId: String,
        finalMessages: [UIMessage],
        displayBaseline: [UIMessage]? = nil,
        terminalStatus: AgentRunStatus? = nil,
        terminalReason: String? = nil
    ) async {
        if let conversationId, let terminalStatus {
            recordModelRoutingChildOutcomeIfNeeded(
                childThreadId: conversationId.toHexDashString(),
                childRunId: runId,
                terminalStatus: terminalStatus,
                terminalReason: terminalReason
            )
        }
        await controlCommands.notifyRunTerminal(
            conversationId: conversationId,
            runId: runId,
            finalMessages: finalMessages,
            displayBaseline: displayBaseline,
            terminalStatus: terminalStatus,
            terminalReason: terminalReason
        )
    }

    /// Keep the service's existing outcome entry point for callers that record
    /// a durable child terminal independently of mailbox delivery.
    func recordModelRoutingChildOutcomeIfNeeded(
        childThreadId: String,
        childRunId: String,
        terminalStatus: AgentRunStatus,
        terminalReason: String?
    ) {
        jevRouting.recordModelRoutingChildOutcomeIfNeeded(
            childThreadId: childThreadId,
            childRunId: childRunId,
            terminalStatus: terminalStatus,
            terminalReason: terminalReason
        )
    }

    // MARK: - 纯辅助

    static func latestRunStatusByConversation(agentRuntimeDao: AgentRuntimeDao) async -> [String: String] {
        await IOSOrchestrationPersistence.latestRunStatusByConversation(agentRuntimeDao: agentRuntimeDao)
    }

    static func isValidTaskName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.allSatisfy { character in
            (character >= "a" && character <= "z")
                || (character >= "0" && character <= "9")
                || character == "_"
        }
    }

    static func errorJSON(toolName: String, code: String, reason: String) -> String {
        IOSWorkspaceStore.json([
            "ok": false,
            "tool": toolName,
            "status": "failed",
            "error": code,
            "reason": reason,
        ])
    }


}

extension IOSThreadOrchestrationToolService.BackgroundScheduling {
    var activeSubAgentJobCount: Int { 0 }
    var activeModelCounts: [String: Int] { [:] }
    var activeProviderCounts: [String: Int] { [:] }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}


extension TextGenerationParams {
    /// 输出上限地板：低于 floor（或 nil 吃服务商默认小上限）时提升到 floor。
    func withMaxTokenFloor(_ floor: Int32) -> TextGenerationParams {
        let current = maxTokens?.int32Value ?? 0
        guard current < floor else { return self }
        return TextGenerationParams(
            model: model,
            temperature: temperature,
            topP: topP,
            maxTokens: KotlinInt(value: floor),
            tools: tools,
            reasoningLevel: reasoningLevel,
            customHeaders: customHeaders,
            customBody: customBody
        )
    }
}
