package app.amber.cloud.orchestration

import app.amber.ai.ui.ToolApprovalState
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.agents.AgentRegistry
import app.amber.cloud.channel.ChannelApprovalCard
import app.amber.cloud.channel.InboundMessage
import app.amber.cloud.channel.OutboundCard
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.gateway.CloudGatewayState
import app.amber.cloud.gateway.DecisionActorContext
import app.amber.cloud.proactive.ProactiveEngine
import app.amber.cloud.runtime.CloudToolRegistry
import app.amber.cloud.runtime.ExecutionScope
import app.amber.cloud.runtime.ToolApprovalHelper
import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.EnvelopeCredentialVault
import app.amber.cloud.tasks.TaskCallContext
import app.amber.core.model.Conversation
import app.amber.core.model.DEFAULT_ASSISTANT_ID
import app.amber.core.model.toMessageNode
import app.amber.core.storage.conversation.JsonConversationStorage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.coroutineContext
import kotlin.time.Clock
import kotlin.uuid.Uuid

/**
 * Amber 云端本体 P2.5 编排内核默认实现（门面编排器，将各子域职责委派给独立协作组件）：
 * - [OrchestrationWorkQueueCoordinator]：WorkItem 8 态队列、三层幂等、并发槽位、重定向、重启恢复与异步工具
 * - [OrchestrationRollupCoordinator]：Worker 进度上报、无时间戳 SHA-256 结算报告与 BatchRollup 单次唤醒锁
 * - [OrchestrationHealthMonitor]：60s 零 Token 确定性健康巡检、45m 豁免、2 步自愈阶梯与可选 Watchdog
 * - [OrchestrationSessionInspector]：两层无损会话读取、Unicode 安全切片、取证诊断与链式召回
 * - [OrchestrationAutomationRunner]：三模式自动化、4 种停机策略、32KiB/8KiB 信封与 ProactiveEngine 桥接
 * - [OrchestrationRouterBridge]：多对多 Thread 订阅直通、Router 繁忙期事件合并批处理与 100 词回复预算
 */
class DefaultCloudOrchestrationKernel(
    override val config: OrchestrationConfig = OrchestrationConfig(),
    val store: CloudOrchestrationStore,
    val conversationStorage: JsonConversationStorage,
    val toolRegistry: CloudToolRegistry,
    private val clockMs: () -> Long = { System.currentTimeMillis() },
    var autoExecuteWorkersInBackground: Boolean = false,
    var workerTurnRunner: (suspend (CloudWorkItemRecord, CloudPrincipal.Worker) -> WorkerSettlementReport?)? = null,
    var onBatchRollupWoken: (suspend (BatchRollupRecord) -> Unit)? = null,
    var onOwnerNotificationCard: (suspend (OutboundCard, String) -> Unit)? = null,
    var proactiveEngine: ProactiveEngine? = null,
    var watchdogJudge: CloudWatchdogJudge? = null,
    val agentRegistry: AgentRegistry? = null,
    val conversationHub: (String) -> String? = { null },
    val vault: EnvelopeCredentialVault? = null,
    val gatewayState: CloudGatewayState? = null,
    var onWorkerApprovalRequested: (suspend (CloudWorkItemRecord, ChannelApprovalCard) -> Unit)? = null,
    var completionPolicyEvaluator: CompletionPolicyEvaluator = CompletionPolicyEvaluator { policy, runOutput, memoryText ->
        val clause = policy.stopWhenClause.trim().lowercase()
        val combined = "$runOutput\n$memoryText".lowercase()
        val matched = clause.isNotEmpty() && (combined.contains(clause) || combined.contains("[completed]") || combined.contains("已达成"))
        CompletionEvaluationResult(
            matched = matched,
            confidence = if (matched) 0.95 else 0.10,
            reason = if (matched) "满足停机条件: ${policy.stopWhenClause}" else "尚未满足停机条件",
        )
    },
) : CloudOrchestrationKernel {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val activeWorkerJobs = ConcurrentHashMap<String, Job>()
    private val workerLifecycleMutexes = ConcurrentHashMap<String, Mutex>()
    private var healthJob: Job? = null

    @Volatile
    var isRouterTurnBusy: Boolean = false

    val deterministicHealthTicksCount = AtomicInteger(0)
    val deterministicHealthTokensUsed = AtomicInteger(0)
    val batchRollupWakeCount = AtomicInteger(0)
    val directPassThroughCount = AtomicInteger(0)
    val routerBatchedCallCount = AtomicInteger(0)

    var activityListener: (suspend (CloudWorkItemRecord, ActivityPhase) -> Unit)? = null
    var routerWakeListener: (() -> Unit)? = null

    private val workQueueCoordinator = OrchestrationWorkQueueCoordinator(this, scope, clockMs)
    private val rollupCoordinator = OrchestrationRollupCoordinator(this)
    private val healthMonitor = OrchestrationHealthMonitor(this)
    private val sessionInspector = OrchestrationSessionInspector(this)
    private val automationRunner = OrchestrationAutomationRunner(this)
    private val routerBridge = OrchestrationRouterBridge(this)
    internal val approvalHelper = ToolApprovalHelper(vault, gatewayState, conversationStorage)
    val workerEvents = WorkerEventInbox(this)
    var stopTaskProcesses: suspend (String)->Unit = {}
    var stopTaskProcessesNonClosing: suspend (String) -> Unit = { stopTaskProcesses(it) }
    var hasBackgroundProcesses: (String)->Boolean = {false}
    var settlementListener: suspend (CloudWorkItemRecord,WorkerSettlementReport)->Unit = {_,_->}
    var workerCommentary: suspend (CloudWorkItemRecord, String) -> Unit = { _, _ -> }
    internal var beforeHealthWriteHook: (suspend (String) -> Unit)? = null
    fun signalWorker(id:String)=workerEvents.signal(id)
    fun isWorkerRunnerActive(workItemId: String): Boolean = activeWorkerJobs[workItemId]?.isCompleted == false
    internal fun currentEpochMs(): Long = clockMs()
    internal fun touchWorkItemActivity(workItemId: String, nowEpochMs: Long = clockMs()) {
        synchronized(store) {
            val current = store.getWorkItem(workItemId) ?: return
            if (current.state.isTerminal) return
            if (nowEpochMs <= current.lastActivityAtMs) return
            store.upsertWorkItem(
                current.copy(
                    lastActivityAtMs = nowEpochMs,
                    updatedAtMs = maxOf(current.updatedAtMs, nowEpochMs),
                )
            )
        }
    }

    sealed class InboundRoutingDecision {
        data class DirectPassThroughToWorkers(
            val threadKey: String,
            val workerItemIds: List<String>,
            val workerSessionIds: List<String>,
        ) : InboundRoutingDecision()

        data class QueuedForRouterBatch(
            val event: RouterTriggerEvent,
            val currentBatchSize: Int,
        ) : InboundRoutingDecision()

        data class RouteToCoordinatorNow(
            val batchedEvents: List<RouterTriggerEvent>,
        ) : InboundRoutingDecision()
    }

    internal suspend fun emitActivityInternal(record: CloudWorkItemRecord, phase: ActivityPhase) {
        val listener = activityListener ?: return
        runCatching { listener(record, phase) }
    }

    internal fun recordMessageTimestampInternal(messageId: String, nowEpochMs: Long) {
        sessionInspector.recordMessageTimestamp(messageId, nowEpochMs)
    }

    internal suspend fun maybeTriggerBatchRollupInternal(
        batchId: String,
        nowEpochMs: Long,
        ignoreClaimTtl: Boolean = false,
    ) {
        rollupCoordinator.maybeTriggerBatchRollup(batchId, nowEpochMs, ignoreClaimTtl = ignoreClaimTtl)
    }

    internal suspend fun recoverPendingImTriggersInternal(nowEpochMs: Long) {
        routerBridge.recoverPendingImTriggers(nowEpochMs)
    }

    internal suspend fun acceptFollowupAndSignalInternal(
        deviceId: String,
        requestId: String,
        workItemId: String,
        followupText: String,
        nowEpochMs: Long,
        silentDialogueEvent: Boolean = false,
        appendBrief: Boolean = true,
        touchActivity: Boolean = true,
    ): CloudWorkItemRecord = workQueueCoordinator.acceptFollowupAndSignal(
        deviceId = deviceId,
        requestId = requestId,
        workItemId = workItemId,
        followupText = followupText,
        nowEpochMs = nowEpochMs,
        silentDialogueEvent = silentDialogueEvent,
        appendBrief = appendBrief,
        touchActivity = touchActivity,
    )

    private fun itemLifecycleMutex(workItemId: String): Mutex =
        workerLifecycleMutexes.computeIfAbsent(workItemId) { Mutex() }

    internal suspend fun nudgeWorker(
        workItemId: String,
        expectedState: WorkItemState,
        expectedUpdatedAtMs: Long,
        finding: String,
        nowEpochMs: Long,
    ): CloudWorkItemRecord? = itemLifecycleMutex(workItemId).withLock {
        beforeHealthWriteHook?.invoke(workItemId)
        val snapshot = synchronized(store) {
            val current = store.getWorkItem(workItemId) ?: return@synchronized null
            if (current.state.isTerminal || current.state != expectedState || current.updatedAtMs != expectedUpdatedAtMs) {
                return@synchronized null
            }
            current
        } ?: return@withLock null

        val nudgeText = "【系统巡检催促】检测到任务已静默超过 10 分钟 ($finding)，请汇报当前进度或调用结算工具提交结果。"
        val requestId = "health:nudge:$workItemId:${snapshot.recoveriesUsed}"
        acceptFollowupAndSignalInternal(
            deviceId = "system:health",
            requestId = requestId,
            workItemId = workItemId,
            followupText = nudgeText,
            nowEpochMs = nowEpochMs,
            silentDialogueEvent = true,
            appendBrief = false,
            touchActivity = false,
        )
        synchronized(store) {
            val current = store.getWorkItem(workItemId) ?: return@synchronized null
            if (current.state.isTerminal) return@synchronized null
            if (snapshot.slotHeld && (current.state != expectedState || current.updatedAtMs != expectedUpdatedAtMs)) {
                return@synchronized null
            }
            val nudged = current.copy(
                recoveryStage = RecoveryStage.NUDGED,
                lastNudgedAtMs = nowEpochMs,
                updatedAtMs = nowEpochMs,
            )
            store.upsertWorkItem(nudged)
            store.appendDiagnosticEvent(
                sessionId = nudged.workerSessionId ?: nudged.workItemId,
                workItemId = nudged.workItemId,
                kind = "recovery_nudge",
                detail = nudgeText,
                nowMs = nowEpochMs,
            )
            nudged
        }
    }

    suspend fun redeliverWorker(
        workItemId: String,
        reason: String,
        nowEpochMs: Long = clockMs(),
        expectedState: WorkItemState? = null,
        expectedUpdatedAtMs: Long? = null,
    ): CloudWorkItemRecord? = itemLifecycleMutex(workItemId).withLock {
        beforeHealthWriteHook?.invoke(workItemId)
        val preCheck = synchronized(store) {
            val current = store.getWorkItem(workItemId) ?: return@synchronized null
            if (current.state.isTerminal) return@synchronized null
            if (expectedState != null && current.state != expectedState) return@synchronized null
            if (expectedUpdatedAtMs != null && current.updatedAtMs != expectedUpdatedAtMs) return@synchronized null
            current
        } ?: return@withLock null

        val oldJob = activeWorkerJobs[workItemId]
        oldJob?.cancel()
        stopTaskProcessesNonClosing(workItemId)
        oldJob?.join()
        // The cancelled runner no longer owns its pending/approved call. Do not leave
        // a live card or raw arguments that a late decision could appear to approve.
        cancelPendingApprovalsForWorkItem(workItemId, nowEpochMs)

        val updated = synchronized(store) {
            val current = store.getWorkItem(workItemId) ?: return@synchronized null
            if (current.state.isTerminal) return@synchronized null
            if (expectedState != null && current.state != expectedState) return@synchronized null
            if (expectedUpdatedAtMs != null && current.updatedAtMs != expectedUpdatedAtMs) return@synchronized null
            val nextRecoveries = current.recoveriesUsed + 1
            val sessionId = current.workerSessionId ?: current.workItemId
            val topic = current.subscribedThreadKeys.firstOrNull { it.startsWith("native:") }?.removePrefix("native:") ?: workItemId
            val requestId = "health:redeliver:$workItemId:$nextRecoveries"
            val redeliverText = "【系统自愈重派 #$nextRecoveries/${config.maxRecoveryAttempts} ($reason)】上一轮被中断，未确认的工具结果不代表成功，请先检查：${current.brief}"
            val safeText = CredentialRedactor.redact(redeliverText)
            val key = OrchestrationHash.sha256Hex("system:health|$requestId|$workItemId|$redeliverText")
            val inputId = UUID.nameUUIDFromBytes(key.toByteArray()).toString()
            store.dialogue.acceptSilent(
                DialogueInput(inputId, "system:health", requestId, "followup", safeText, topic, workItemId),
                key,
            )
            val redelivered = current.copy(
                state = WorkItemState.WORKING,
                slotHeld = true,
                recoveriesUsed = nextRecoveries,
                recoveryStage = RecoveryStage.NONE,
                lastNudgedAtMs = null,
                activeToolName = null,
                activeToolStartedAtMs = null,
                lastActivityAtMs = nowEpochMs,
                updatedAtMs = nowEpochMs,
            )
            store.upsertWorkItem(redelivered)
            store.appendDiagnosticEvent(
                sessionId = sessionId,
                workItemId = workItemId,
                kind = "agent-recovery:interrupt_and_redeliver",
                detail = "Step 2 中断重派 ($reason), recoveriesUsed=$nextRecoveries/${config.maxRecoveryAttempts}",
                nowMs = nowEpochMs,
            )
            redelivered
        } ?: return@withLock null

        signalWorker(workItemId)
        if (autoExecuteWorkersInBackground) {
            launchWorkerRunnerInternal(updated)
        }
        updated
    }

    internal suspend fun exhaustWorkerRecovery(
        workItemId: String,
        expectedState: WorkItemState,
        expectedUpdatedAtMs: Long,
        finding: String,
        nowEpochMs: Long,
    ): CloudWorkItemRecord? = itemLifecycleMutex(workItemId).withLock {
        beforeHealthWriteHook?.invoke(workItemId)
        synchronized(store) {
            val current = store.getWorkItem(workItemId) ?: return@synchronized null
            if (current.state.isTerminal || current.state != expectedState || current.updatedAtMs != expectedUpdatedAtMs) {
                return@synchronized null
            }
            current
        } ?: return@withLock null

        val oldJob = activeWorkerJobs[workItemId]
        oldJob?.cancel()
        stopTaskProcessesNonClosing(workItemId)
        oldJob?.join()
        // The cancelled runner no longer owns its pending/approved call. Do not leave
        // a live card or raw arguments that a late decision could appear to approve.
        cancelPendingApprovalsForWorkItem(workItemId, nowEpochMs)

        val eligible = synchronized(store) {
            val current = store.getWorkItem(workItemId) ?: return@synchronized false
            if (current.state.isTerminal || current.state != expectedState || current.updatedAtMs != expectedUpdatedAtMs) {
                return@synchronized false
            }
            store.dialogue.abandonPending(workItemId)
            true
        }
        if (!eligible) return@withLock null

        val coordinator = CloudPrincipal.CloudCoordinator(
            activeSessionId = PRIMARY_CONVERSATION_ID.toString(),
            activeTurnId = "system:health:exhaust:$workItemId:$nowEpochMs",
        )
        val failureReason = "recovery_exhausted:$finding"
        val settled = reportWorkerSettlement(
            coordinator,
            WorkerSettlementReport(workItemId, "failed", failureReason),
            nowEpochMs,
        )
        if (settled.state != WorkItemState.FAILED || settled.failureReason != CredentialRedactor.redact(failureReason)) {
            return@withLock null
        }

        val escalated = synchronized(store) {
            val current = store.getWorkItem(workItemId) ?: return@synchronized settled
            if (current.state != WorkItemState.FAILED) return@synchronized current
            current.copy(
                recoveryStage = RecoveryStage.EXHAUSTED,
                needsYouEscalated = true,
                updatedAtMs = nowEpochMs,
            ).also { store.upsertWorkItem(it) }
        }
        val sessionId = escalated.workerSessionId ?: escalated.workItemId
        val detail = "任务「${escalated.title}」(${escalated.workItemId}) 异常 ($finding) 且已用尽 ${config.maxRecoveryAttempts} 次自愈上限，请求主人介入"
        store.appendDiagnosticEvent(
            sessionId = sessionId,
            workItemId = escalated.workItemId,
            kind = "recovery_exhausted",
            detail = detail,
            nowMs = nowEpochMs,
        )
        onOwnerNotificationCard?.invoke(
            OutboundCard(
                title = "Worker 自愈耗尽需介入 · ${escalated.title}",
                markdownBody = detail,
                headerTemplate = "red",
                highRisk = false,
            ),
            escalated.workItemId,
        )
        escalated
    }

    @Synchronized
    internal fun launchWorkerRunnerInternal(item: CloudWorkItemRecord) {
        if (activeWorkerJobs[item.workItemId]?.isCompleted == false) return
        val runner = workerTurnRunner ?: return
        val workerPrincipal = workerPrincipalFor(item)
        val job = scope.launch(start = CoroutineStart.LAZY) {
            val thisJob = this.coroutineContext[Job]
            try {
                while (!store.isClosed && store.getWorkItem(item.workItemId)?.state?.isTerminal == false) {
                    val current = store.getWorkItem(item.workItemId) ?: break
                    val report = try { runner(current, workerPrincipal) }
                    catch (t: Exception) {
                        if (t is CancellationException) throw t
                        if (store.isClosed) throw CancellationException("store closed")
                        store.appendDiagnosticEvent(current.workerSessionId ?: current.workItemId, current.workItemId,
                            "worker_execution_failed", detail = CredentialRedactor.redact(t.stackTraceToString()), nowMs = clockMs())
                        WorkerSettlementReport(item.workItemId,"failed",app.amber.cloud.runtime.cloudFailureSummary(t))
                    } ?: break
                    if (store.isClosed) break
                    val settled=reportWorkerSettlement(workerPrincipal, report, clockMs())
                    if(settled.state.isTerminal)break
                }
            } finally {
                if (thisJob != null) activeWorkerJobs.remove(item.workItemId, thisJob)
                else activeWorkerJobs.remove(item.workItemId)
            }
        }
        activeWorkerJobs[item.workItemId] = job
        job.start()
    }

    internal suspend fun appendMessageToSessionInternal(
        sessionId: String,
        message: UIMessage,
        nowEpochMs: Long,
    ) {
        val uuid = runCatching { Uuid.parse(sessionId) }.getOrNull() ?: return
        val existing = conversationStorage.loadConversation(uuid)
            ?: Conversation(
                id = uuid,
                assistantId = DEFAULT_ASSISTANT_ID,
                title = "Session-$sessionId",
                messageNodes = emptyList(),
            )
        sessionInspector.recordMessageTimestamp(message.id.toString(), nowEpochMs)
        conversationStorage.saveConversation(
            existing.copy(
                messageNodes = if(existing.messageNodes.any {it.currentMessage.id==message.id})existing.messageNodes else existing.messageNodes + message.toMessageNode(),
                updateAt = Clock.System.now(),
            )
        )
    }

    // ========================================================================
    // 1. 守护循环、节点状态与 Worker 工具门禁
    // ========================================================================

    fun startHealthLoop(intervalMs: Long = 60_000L) {
        if (healthJob?.isActive == true) return
        healthJob = scope.launch {
            while (isActive) {
                delay(intervalMs)
                runCatching { runDeterministicHealthTick(clockMs()) }
                if (config.modelWatchdogEnabled) runCatching { runWatchdogTick(clockMs()) }
            }
        }
    }

    fun stopHealthLoop() {
        healthJob?.cancel()
        healthJob = null
    }

    internal fun shutdownForRestart() {
        stopHealthLoop()
        scope.cancel()
        activeWorkerJobs.clear()
    }

    val isHealthLoopRunning: Boolean get() = healthJob?.isActive == true

    fun setMacNodeOnline(deviceId: String, online: Boolean, nowEpochMs: Long = clockMs()) =
        workQueueCoordinator.setMacNodeOnline(deviceId, online, nowEpochMs)

    fun isMacNodeOnline(deviceId: String): Boolean =
        workQueueCoordinator.isMacNodeOnline(deviceId)

    suspend fun cancelWorkItem(principal: CloudPrincipal, workItemId: String): CloudWorkItemRecord {
        val coordinator = workQueueCoordinator.requireCoordinatorAuthority(principal, "cancelWorkItem")
        val current=store.getWorkItem(workItemId)?:throw IllegalArgumentException("任务不存在")
        if(current.state.isTerminal)return current
        workerEvents.requestStop(workItemId)
        val job=activeWorkerJobs[workItemId]
        job?.cancel()
        stopTaskProcesses(workItemId)
        job?.join()
        cancelPendingApprovalsForWorkItem(workItemId, clockMs())
        val result = reportWorkerSettlement(coordinator, WorkerSettlementReport(
            workItemId, "cancelled", "主人已取消任务",
        ), clockMs())
        return result
    }

    suspend fun recoverAfterRestart(nowEpochMs: Long = clockMs()): List<CloudWorkItemRecord> =
        workQueueCoordinator.recoverAfterRestart(nowEpochMs)

    suspend fun awaitBackgroundWorkers() {
        while (true) {
            val jobs = activeWorkerJobs.values.filter { it.isActive }
            if (jobs.isEmpty()) break
            jobs.forEach { it.join() }
        }
    }

    fun workerPrincipalFor(item: CloudWorkItemRecord): CloudPrincipal.Worker = CloudPrincipal.Worker(
        principalId = "worker:${item.workItemId}",
        workItemId = item.workItemId,
        batchId = item.batchId,
        targetNode = item.targetNode,
    )

    suspend fun executeWorkerTool(
        principal: CloudPrincipal,
        toolName: String,
        args: JsonObject = JsonObject(emptyMap()),
        approvalGrant: CloudToolRegistry.ApprovalGrant? = null,
    ): JsonElement {
        if (principal !is CloudPrincipal.Worker) {
            throw PrincipalPermissionException("executeWorkerTool 仅限 Worker 主体调用")
        }
        val item = store.getWorkItem(principal.workItemId)
            ?: throw PrincipalPermissionException("Worker 任务不存在")
        if (principal != workerPrincipalFor(item) || item.state.isTerminal || workerEvents.isStopping(item.workItemId)) throw PrincipalPermissionException("Worker 身份或状态无效")
        val registry = agentRegistry
        val rawAllowed = if (registry == null) {
            toolRegistry.availableDefinitions(
                scope = ExecutionScope.SUBAGENT,
                includeWorkerApprovalTools = config.workerApprovals,
            ).map { it.name }.toSet()
        } else {
            val agent = registry.get(item.agentId) ?: throw PrincipalPermissionException("Agent 不存在")
            registry.effectiveTools(agent)
        }
        val allowed = (if (config.workerApprovals) rawAllowed else rawAllowed.filterNot { toolRegistry.isWorkerApprovalTool(it) }.toSet()) + "task_finish"
        if (toolName !in allowed) throw PrincipalPermissionException("Agent 未获授该工具")
        val context = TaskCallContext(item.workItemId, item.agentId, item.workerSessionId!!, allowed)
        // The gate owns nested recipes and history scoping too; no second, weaker execution path.
        return toolRegistry.executeGate(
            toolName = toolName,
            args = args,
            scope = ExecutionScope.SUBAGENT,
            context = context,
            approvalGrant = approvalGrant,
        )
    }

    internal fun v2ApprovalSessionKey(workItemId: String, approvalId: String): String =
        "amber:wi:$workItemId:$approvalId"

    /**
     * 处理网关发往 V2 Worker (`amber:wi:<workItemId>:<approvalId>`) 的审批决策。
     * 返回 `false` 表示该审批不存在、已过期或已终结，由 [CloudGatewayState] 返回 409 `stale`。
     */
    suspend fun handleV2GatewayDecision(
        sessionKey: String,
        toolCallId: String,
        allow: Boolean,
    ): Boolean {
        if (!sessionKey.startsWith("amber:wi:")) return false
        val body = sessionKey.removePrefix("amber:wi:")
        val sep = body.lastIndexOf(':')
        if (sep <= 0 || sep >= body.lastIndex) return false
        val workItemId = body.substring(0, sep)
        val approvalId = body.substring(sep + 1)
        val actor = coroutineContext[DecisionActorContext]?.actorDevice ?: "unknown"
        val now = clockMs()

        var expiredNow = false
        var transitionedTo: String? = null
        synchronized(store) {
            val approval = store.getWorkerApproval(approvalId) ?: return false
            if (approval.workItemId != workItemId || approval.toolCallId != toolCallId) return false
            val item = store.getWorkItem(workItemId)
            if (approval.state != "pending") return false
            if (item == null || item.state.isTerminal) {
                store.transitionWorkerApprovalState(approvalId, setOf("pending"), "expired", now, "system:terminal")
                expiredNow = true
            } else if (now - approval.createdMs >= config.workerApprovalTtlMs) {
                store.transitionWorkerApprovalState(approvalId, setOf("pending"), "expired", now, "system:ttl")
                expiredNow = true
            } else {
                val targetState = if (allow) "approved" else "denied"
                val updated = store.transitionWorkerApprovalState(approvalId, setOf("pending"), targetState, now, actor)
                if (updated != null) {
                    transitionedTo = targetState
                }
            }
        }
        if (expiredNow) {
            approvalHelper.wipePendingToolArgs(toolCallId)
            approvalHelper.clearApprovalSession(sessionKey, nextState = "running")
            workerEvents.signal(workItemId)
            return false
        }
        val decidedState = transitionedTo ?: return false
        if (decidedState == "denied") {
            approvalHelper.wipePendingToolArgs(toolCallId)
        }
        approvalHelper.clearApprovalSession(sessionKey, nextState = "running")
        store.appendDiagnosticEvent(
            sessionId = store.getWorkItem(workItemId)?.workerSessionId ?: workItemId,
            workItemId = workItemId,
            kind = "worker_approval_$decidedState",
            detail = "高危工具审批 $approvalId ($toolCallId) -> $decidedState by $actor",
            nowMs = now,
        )
        workerEvents.signal(workItemId)
        return true
    }

    internal suspend fun beginWorkerApprovalAndAwait(
        item: CloudWorkItemRecord,
        principal: CloudPrincipal.Worker,
        sessionUuid: Uuid,
        assistantMessage: UIMessage,
        toolCall: UIMessagePart.Tool,
        parsedArgs: JsonObject,
        deferredCalls: List<UIMessagePart.Tool>,
    ): String {
        val redactedArgsJson = approvalHelper.stashPendingToolArgs(toolCall.toolCallId, parsedArgs)
        val argsDigest = approvalHelper.argsDigest(parsedArgs)
        val deferredIds = deferredCalls.map { it.toolCallId }.toSet()
        val persistedAssistant = assistantMessage.copy(
            parts = assistantMessage.parts.map { part ->
                if (part !is UIMessagePart.Tool) {
                    part
                } else when {
                    part.toolCallId == toolCall.toolCallId -> part.copy(
                        input = redactedArgsJson,
                        approvalState = ToolApprovalState.Pending,
                        output = emptyList(),
                    )
                    part.toolCallId in deferredIds -> part.copy(
                        input = CredentialRedactor.redact(part.input),
                        output = listOf(
                            UIMessagePart.Text(
                                """{"status":"deferred_until_approval","blockedBy":"${toolCall.toolCallId}"}"""
                            )
                        ),
                    )
                    else -> part
                }
            }
        )
        val now = clockMs()
        appendMessageToSessionInternal(item.workerSessionId!!, persistedAssistant, now)

        val approvalId = UUID.randomUUID().toString().lowercase()
        val sessionKey = v2ApprovalSessionKey(item.workItemId, approvalId)
        val topic = item.subscribedThreadKeys.firstOrNull { it.startsWith("native:") }?.removePrefix("native:") ?: item.workItemId

        val targetDevice = (item.targetNode as? ExecutionTargetNode.PairedMacNode)?.deviceId ?: "cloud-daemon"
        val approvalPreview = toolRegistry.approvalPreview(toolCall.toolName, parsedArgs, targetDevice = targetDevice)
        val createdApproval: WorkerApprovalRecord? = synchronized(store) {
            val live = store.getWorkItem(item.workItemId)
            if (live == null || live.state.isTerminal || workerEvents.isStopping(item.workItemId)) {
                null
            } else {
                val rec = WorkerApprovalRecord(
                    id = approvalId,
                    workItemId = item.workItemId,
                    toolCallId = toolCall.toolCallId,
                    toolName = toolCall.toolName,
                    argsDigest = argsDigest,
                    redactedArgs = redactedArgsJson,
                    state = "pending",
                    createdMs = now,
                )
                store.insertWorkerApproval(rec)
                workQueueCoordinator.transitionWorkItemState(
                    workItemId = item.workItemId,
                    newState = WorkItemState.WAITING,
                    nowEpochMs = now,
                    detail = "等待高危工具 `${toolCall.toolName}` 前台核对审批 ($approvalId)",
                )
                store.dialogue.append(
                    DialogueEvent(
                        id = "approval:$approvalId",
                        kind = "process_event",
                        role = "system",
                        text = "等待你在已配对且已解锁的原生 App 前台核对批准高危工具 `${toolCall.toolName}`（IM 仅可拒绝）",
                        topicId = topic,
                        workItemId = item.workItemId,
                        conversationId = live.conversationId,
                        executorKind = live.executorKind,
                        executorId = live.executorId,
                        epoch = live.epoch,
                        parentRunId = live.parentRunId,
                        riskLevel = approvalPreview.riskLevel,
                        targetDevice = approvalPreview.targetDevice,
                        targetSummary = approvalPreview.targetSummary,
                        diffPreview = approvalPreview.diffPreview,
                        requiresLocalApproval = approvalPreview.requiresLocalApproval,
                    )
                )
                rec
            }
        }
        if (createdApproval == null) {
            approvalHelper.wipePendingToolArgs(toolCall.toolCallId)
            val msg = """{"status":"cancelled","tool":"${toolCall.toolName}"}"""
            approvalHelper.updateStoredToolOutcome(
                sessionUuid,
                toolCall.toolCallId,
                ToolApprovalState.Denied("worker_cancelled"),
                msg,
            )
            return msg
        }

        val currentSnapshot = store.getWorkItem(item.workItemId) ?: item
        approvalHelper.upsertPendingApprovalSession(
            sessionKey = sessionKey,
            agent = currentSnapshot.agentId,
            subject = currentSnapshot.title,
            summary = "高危工具 `${toolCall.toolName}` 等待审批",
            origin = "worker",
            conversationId = sessionUuid.toString(),
            toolCallId = toolCall.toolCallId,
            toolName = toolCall.toolName,
            redactedArgsJson = redactedArgsJson,
            highRisk = true,
            nowSec = now / 1000.0,
            riskLevel = approvalPreview.riskLevel,
            targetDevice = approvalPreview.targetDevice,
            targetSummary = approvalPreview.targetSummary,
            diffPreview = approvalPreview.diffPreview,
            requiresLocalApproval = approvalPreview.requiresLocalApproval,
        )
        runCatching {
            onWorkerApprovalRequested?.invoke(
                currentSnapshot,
                ChannelApprovalCard(
                    sessionKey = sessionKey,
                    toolCallId = toolCall.toolCallId,
                    toolName = toolCall.toolName,
                    redactedDetail = redactedArgsJson,
                    highRisk = true,
                    allowApproveInChannel = false,
                    riskLevel = approvalPreview.riskLevel,
                    targetDevice = approvalPreview.targetDevice,
                    targetSummary = approvalPreview.targetSummary,
                    diffPreview = approvalPreview.diffPreview,
                    requiresLocalApproval = approvalPreview.requiresLocalApproval,
                ),
            )
        }

        val expiresAtMs = createdApproval.createdMs + config.workerApprovalTtlMs
        while (true) {
            val latestApproval = store.getWorkerApproval(approvalId)
            val latestItem = store.getWorkItem(item.workItemId)
            val currentNow = clockMs()
            val doneWaiting = latestApproval == null ||
                latestApproval.state != "pending" ||
                latestItem == null ||
                latestItem.state.isTerminal ||
                workerEvents.isStopping(item.workItemId) ||
                currentNow >= expiresAtMs
            if (doneWaiting) break
            val waitMs = (expiresAtMs - currentNow).coerceAtLeast(1L)
            workerEvents.awaitUntil(item.workItemId, waitMs) {
                val a = store.getWorkerApproval(approvalId)
                val wi = store.getWorkItem(item.workItemId)
                a == null ||
                    a.state != "pending" ||
                    wi == null ||
                    wi.state.isTerminal ||
                    workerEvents.isStopping(item.workItemId) ||
                    clockMs() >= expiresAtMs
            }
        }

        val wakeNow = clockMs()
        val (resolvedRecord, stopped) = synchronized(store) {
            val wi = store.getWorkItem(item.workItemId)
            val isStopped = wi == null || wi.state.isTerminal || workerEvents.isStopping(item.workItemId)
            var current = store.getWorkerApproval(approvalId)
            if (current != null && current.state == "pending") {
                if (isStopped) {
                    current = store.transitionWorkerApprovalState(approvalId, setOf("pending"), "expired", wakeNow, "system:stopped") ?: current
                } else if (wakeNow >= expiresAtMs) {
                    current = store.transitionWorkerApprovalState(approvalId, setOf("pending"), "expired", wakeNow, "system:ttl") ?: current
                }
            }
            if (!isStopped && wi.state == WorkItemState.WAITING) {
                workQueueCoordinator.transitionWorkItemState(
                    workItemId = item.workItemId,
                    newState = WorkItemState.WORKING,
                    nowEpochMs = wakeNow,
                    detail = "高危工具审批已收敛 (${current?.state ?: "unknown"})，恢复执行",
                )
            }
            current to isStopped
        }
        approvalHelper.clearApprovalSession(sessionKey, nextState = if (stopped) "completed" else "running", nowSec = wakeNow / 1000.0)

        if (stopped) {
            approvalHelper.wipePendingToolArgs(toolCall.toolCallId)
            val msg = """{"status":"cancelled","tool":"${toolCall.toolName}"}"""
            approvalHelper.updateStoredToolOutcome(
                sessionUuid,
                toolCall.toolCallId,
                ToolApprovalState.Denied("worker_cancelled"),
                msg,
            )
            return msg
        }

        return when (resolvedRecord?.state) {
            "approved" -> {
                val executingRecord = store.transitionWorkerApprovalState(approvalId, setOf("approved"), "executing")
                if (executingRecord == null) {
                    approvalHelper.wipePendingToolArgs(toolCall.toolCallId)
                    val msg = """{"status":"stale","tool":"${toolCall.toolName}"}"""
                    approvalHelper.updateStoredToolOutcome(sessionUuid, toolCall.toolCallId, ToolApprovalState.Denied("stale"), msg)
                    return msg
                }
                val rawArgs = approvalHelper.consumePendingToolArgs(toolCall.toolCallId)
                if (rawArgs == null || approvalHelper.argsDigest(rawArgs) != executingRecord.argsDigest) {
                    store.transitionWorkerApprovalState(approvalId, setOf("executing"), "expired", clockMs(), "system:vault_miss")
                    val msg = """{"error":"高危工具原始参数校验失败或已被清除，已拒绝执行","tool":"${toolCall.toolName}"}"""
                    approvalHelper.updateStoredToolOutcome(sessionUuid, toolCall.toolCallId, ToolApprovalState.Denied("args_unavailable"), msg)
                    return msg
                }
                val grantUsed = java.util.concurrent.atomic.AtomicBoolean(false)
                val grant = CloudToolRegistry.ApprovalGrant(
                    workItemId = item.workItemId,
                    toolCallId = toolCall.toolCallId,
                    toolName = toolCall.toolName,
                    argsDigest = executingRecord.argsDigest,
                    consumeOnce = {
                        grantUsed.compareAndSet(false, true) &&
                            store.getWorkerApproval(approvalId)?.state == "executing"
                    },
                )
                try {
                    val result = executeWorkerTool(
                        principal = principal,
                        toolName = toolCall.toolName,
                        args = rawArgs,
                        approvalGrant = grant,
                    )
                    store.transitionWorkerApprovalState(approvalId, setOf("executing"), "done")
                    val outStr = CredentialRedactor.redact(result.toString())
                    approvalHelper.updateStoredToolOutcome(sessionUuid, toolCall.toolCallId, ToolApprovalState.Approved, outStr)
                    outStr
                } catch (e: CancellationException) {
                    store.transitionWorkerApprovalState(approvalId, setOf("executing"), "outcome_unknown")
                    val msg = """{"status":"outcome_unknown","tool":"${toolCall.toolName}"}"""
                    approvalHelper.updateStoredToolOutcome(sessionUuid, toolCall.toolCallId, ToolApprovalState.Denied("outcome_unknown"), msg)
                    throw e
                } catch (t: Throwable) {
                    store.transitionWorkerApprovalState(approvalId, setOf("executing"), "done")
                    val errOut = """{"error":${kotlinx.serialization.json.Json.encodeToString(kotlinx.serialization.json.JsonPrimitive(CredentialRedactor.redact(t.message ?: t::class.simpleName.orEmpty())))}}"""
                    approvalHelper.updateStoredToolOutcome(sessionUuid, toolCall.toolCallId, ToolApprovalState.Approved, errOut)
                    errOut
                }
            }
            "denied" -> {
                approvalHelper.wipePendingToolArgs(toolCall.toolCallId)
                val msg = """{"status":"denied","tool":"${toolCall.toolName}","message":"主人拒绝执行该高危工具"}"""
                approvalHelper.updateStoredToolOutcome(
                    sessionUuid,
                    toolCall.toolCallId,
                    ToolApprovalState.Denied(resolvedRecord.actor ?: "user_denied"),
                    msg,
                )
                msg
            }
            else -> {
                approvalHelper.wipePendingToolArgs(toolCall.toolCallId)
                val msg = """{"status":"expired","tool":"${toolCall.toolName}","message":"审批已超时过期，请勿重试该高危调用"}"""
                approvalHelper.updateStoredToolOutcome(
                    sessionUuid,
                    toolCall.toolCallId,
                    ToolApprovalState.Denied("approval_expired"),
                    msg,
                )
                msg
            }
        }
    }

    internal suspend fun cancelPendingApprovalsForWorkItem(workItemId: String, nowEpochMs: Long) {
        val cancelled = mutableListOf<Pair<WorkerApprovalRecord, String>>()
        synchronized(store) {
            for (approval in store.listWorkerApprovals(workItemId)) {
                when (approval.state) {
                    "pending", "approved" -> {
                        val updated = store.transitionWorkerApprovalState(
                            approval.id,
                            setOf("pending", "approved"),
                            "expired",
                            approval.decidedMs ?: nowEpochMs,
                            approval.actor ?: "system:cancelled",
                        )
                        if (updated != null) cancelled.add(updated to "cancelled")
                    }
                    "executing" -> {
                        val updated = store.transitionWorkerApprovalState(
                            approval.id,
                            setOf("executing"),
                            "outcome_unknown",
                        )
                        if (updated != null) cancelled.add(updated to "outcome_unknown")
                    }
                }
            }
        }
        val sessionUuid = store.getWorkItem(workItemId)?.workerSessionId?.let { runCatching { Uuid.parse(it) }.getOrNull() }
        for ((approval, reason) in cancelled) {
            approvalHelper.wipePendingToolArgs(approval.toolCallId)
            approvalHelper.clearApprovalSession(
                sessionKey = v2ApprovalSessionKey(workItemId, approval.id),
                nextState = "completed",
                nowSec = nowEpochMs / 1000.0,
            )
            if (sessionUuid != null) {
                approvalHelper.updateStoredToolOutcome(
                    sessionUuid,
                    approval.toolCallId,
                    ToolApprovalState.Denied(reason),
                    """{"status":"$reason","tool":"${approval.toolName}"}""",
                )
            }
        }
    }

    internal fun expireTimedOutApprovalsForWorkItem(workItemId: String, nowEpochMs: Long): Boolean {
        val expiredRecords = mutableListOf<WorkerApprovalRecord>()
        synchronized(store) {
            for (approval in store.listWorkerApprovals(workItemId)) {
                if (approval.state == "pending" && nowEpochMs - approval.createdMs >= config.workerApprovalTtlMs) {
                    val updated = store.transitionWorkerApprovalState(
                        approval.id,
                        setOf("pending"),
                        "expired",
                        nowEpochMs,
                        "system:ttl",
                    )
                    if (updated != null) expiredRecords.add(updated)
                }
            }
            if (expiredRecords.isNotEmpty()) {
                store.appendDiagnosticEvent(
                    sessionId = store.getWorkItem(workItemId)?.workerSessionId ?: workItemId,
                    workItemId = workItemId,
                    kind = "worker_approval_expired",
                    detail = "Worker 审批超时过期 (${expiredRecords.joinToString(",") { it.id }})",
                    nowMs = nowEpochMs,
                )
            }
        }
        for (approval in expiredRecords) {
            approvalHelper.wipePendingToolArgs(approval.toolCallId)
            approvalHelper.clearApprovalSession(
                sessionKey = v2ApprovalSessionKey(workItemId, approval.id),
                nextState = "running",
                nowSec = nowEpochMs / 1000.0,
            )
        }
        if (expiredRecords.isNotEmpty()) {
            signalWorker(workItemId)
            return true
        }
        return false
    }

    fun sendLateralMessage(
        principal: CloudPrincipal,
        targetSessionOrWorkItemId: String,
        @Suppress("UNUSED_PARAMETER") message: String,
    ) = workQueueCoordinator.sendLateralMessage(principal, targetSessionOrWorkItemId)

    // ========================================================================
    // 2. WorkItem 队列、状态流转、结算与 BatchRollup
    // ========================================================================

    override suspend fun submitWorkBatch(
        principal: CloudPrincipal,
        requestId: String,
        contextMessageIds: List<String>,
        items: List<WorkItemSubmissionSpec>,
        nowEpochMs: Long,
    ): BatchSubmissionResult =
        workQueueCoordinator.submitWorkBatch(principal, requestId, contextMessageIds, items, nowEpochMs)

    suspend fun pumpWorkQueue(nowEpochMs: Long = clockMs()) =
        workQueueCoordinator.pumpWorkQueue(nowEpochMs)

    fun transitionWorkItemState(
        workItemId: String,
        newState: WorkItemState,
        nowEpochMs: Long = clockMs(),
        detail: String = "",
    ): CloudWorkItemRecord =
        workQueueCoordinator.transitionWorkItemState(workItemId, newState, nowEpochMs, detail)

    override suspend fun updateWorkerProgress(
        principal: CloudPrincipal,
        workItemId: String,
        expectedRevision: Int,
        progressNote: String,
        activeToolName: String?,
        nowEpochMs: Long,
    ): CloudWorkItemRecord =
        rollupCoordinator.updateWorkerProgress(principal, workItemId, expectedRevision, progressNote, activeToolName, nowEpochMs)

    override suspend fun reportWorkerSettlement(
        principal: CloudPrincipal,
        report: WorkerSettlementReport,
        nowEpochMs: Long,
    ): CloudWorkItemRecord =
        rollupCoordinator.reportWorkerSettlement(principal, report, nowEpochMs)

    override suspend fun steerWorker(
        principal: CloudPrincipal,
        workItemId: String,
        followupInstruction: String,
        nowEpochMs: Long,
    ): CloudWorkItemRecord =
        workQueueCoordinator.steerWorker(principal, workItemId, followupInstruction, nowEpochMs)

    internal suspend fun steerImWorker(
        principal: CloudPrincipal, workItemId: String, instruction: String, nowEpochMs: Long,
    ): CloudWorkItemRecord =
        workQueueCoordinator.steerWorker(principal, workItemId, instruction, nowEpochMs, silentDialogueEvent = true)

    // ========================================================================
    // 3. Thread 订阅直通、Router 批处理、异步工具与 100 词回复预算
    // ========================================================================

    fun subscribeWorkerToThread(workItemId: String, threadKey: String, nowEpochMs: Long = clockMs()) =
        store.subscribeThread(threadKey, workItemId, nowEpochMs)

    fun unsubscribeWorkerFromThread(workItemId: String, threadKey: String) =
        store.unsubscribeThread(threadKey, workItemId)

    fun deriveThreadKey(message: InboundMessage): String? =
        routerBridge.deriveThreadKey(message)

    suspend fun routeInboundMessage(
        message: InboundMessage,
        sessionId: String,
        nowEpochMs: Long = clockMs(),
    ): InboundRoutingDecision =
        routerBridge.routeInboundMessage(message, sessionId, nowEpochMs)

    fun enqueueRouterTriggerWhileBusy(event: RouterTriggerEvent) =
        routerBridge.enqueueRouterTriggerWhileBusy(event)

    fun hasPendingRouterEvents(): Boolean =
        routerBridge.hasPendingRouterEvents()

    fun drainPendingRouterBatch(): List<RouterTriggerEvent> =
        routerBridge.drainPendingRouterBatch()

    fun formatRouterBatchPrompt(events: List<RouterTriggerEvent>): String =
        routerBridge.formatRouterBatchPrompt(events)

    fun listObservableRouterEvents(): List<RouterTriggerEvent> =
        routerBridge.listObservableRouterEvents()

    fun startAsyncTool(
        toolName: String,
        sessionId: String = PRIMARY_CONVERSATION_ID.toString(),
        nowEpochMs: Long = clockMs(),
        action: suspend () -> String,
    ): AsyncToolStartResult =
        workQueueCoordinator.startAsyncTool(toolName, sessionId, nowEpochMs, action)

    fun stopAsyncTool(
        handleId: String,
        sessionId: String = PRIMARY_CONVERSATION_ID.toString(),
        nowEpochMs: Long = clockMs(),
    ): AsyncToolStopResult =
        workQueueCoordinator.stopAsyncTool(handleId, sessionId, nowEpochMs)

    fun getAsyncToolStatus(handleId: String): String =
        workQueueCoordinator.getAsyncToolStatus(handleId)

    fun enforceImReplyWordBudget(
        rawText: String,
        referenceSlug: String = UUID.randomUUID().toString().lowercase().take(12),
        nowEpochMs: Long = clockMs(),
    ): String =
        routerBridge.enforceImReplyWordBudget(rawText, referenceSlug, nowEpochMs)

    suspend fun appendWorkerMessage(
        sessionId: String,
        message: UIMessage,
        nowEpochMs: Long = clockMs(),
    ) = appendMessageToSessionInternal(sessionId, message, nowEpochMs)

    // ========================================================================
    // 4. 健康巡检、自愈阶梯与 Watchdog
    // ========================================================================

    override suspend fun runDeterministicHealthTick(nowEpochMs: Long): List<HealthTickAction> =
        healthMonitor.runDeterministicHealthTick(nowEpochMs)

    override suspend fun runWatchdogTick(nowEpochMs: Long): List<WatchdogAssessment> =
        healthMonitor.runWatchdogTick(nowEpochMs)

    // ========================================================================
    // 5. 双层无损会话读取、取证诊断与链式召回
    // ========================================================================

    fun markMessageStreaming(messageId: String, streaming: Boolean, nowEpochMs: Long = clockMs()) =
        sessionInspector.markMessageStreaming(messageId, streaming, nowEpochMs)

    fun recordStreamingChunk(
        sessionId: String,
        messageId: String,
        chunkPreview: String,
        nowEpochMs: Long = clockMs(),
    ) = sessionInspector.recordStreamingChunk(sessionId, messageId, chunkPreview, nowEpochMs)

    override suspend fun readWorkerSessionPage(
        sessionId: String,
        pageCursor: String?,
        pageSize: Int,
        maxMessageChars: Int,
    ): SessionReadPage =
        sessionInspector.readWorkerSessionPage(sessionId, pageCursor, pageSize, maxMessageChars)

    override suspend fun readWorkerMessageSlice(
        cursor: MessageSliceCursor,
    ): MessageSliceResult =
        sessionInspector.readWorkerMessageSlice(cursor)

    override suspend fun diagnoseWorkerSession(
        sessionId: String,
        nowEpochMs: Long,
    ): SessionDiagnosticSnapshot =
        sessionInspector.diagnoseWorkerSession(sessionId, nowEpochMs)

    override suspend fun recallObject(
        kind: RecallObjectKind,
        id: String,
        inlineMaxChars: Int,
    ): RecallNodeSnapshot? =
        sessionInspector.recallObject(kind, id, inlineMaxChars)

    // ========================================================================
    // 6. 自动化三种模式与 ProactiveEngine 桥接
    // ========================================================================

    fun registerAutomation(
        spec: CloudAutomationSpec,
        nowEpochMs: Long = clockMs(),
    ): CloudAutomationRecord =
        automationRunner.registerAutomation(spec, nowEpochMs)

    suspend fun runDueAutomations(
        nowEpochMs: Long = clockMs(),
        turnExecutor: suspend (AutomationRunEnvelope, CloudPrincipal.AutomationRunner, String) -> AutomationTurnOutput,
    ): List<AutomationRunResult> =
        automationRunner.runDueAutomations(nowEpochMs, turnExecutor)

    fun updateAutomationMemory(
        principal: CloudPrincipal,
        automationId: String,
        newMemory: String,
        nowEpochMs: Long = clockMs(),
    ): CloudAutomationRecord =
        automationRunner.updateAutomationMemory(principal, automationId, newMemory, nowEpochMs)

    fun cancelAutomation(
        principal: CloudPrincipal,
        automationId: String,
        nowEpochMs: Long = clockMs(),
    ): CloudAutomationRecord =
        automationRunner.cancelAutomation(principal, automationId, nowEpochMs)

    suspend fun executeAutomationRun(
        automationId: String,
        nowEpochMs: Long = clockMs(),
        turnExecutor: suspend (AutomationRunEnvelope, CloudPrincipal.AutomationRunner, String) -> AutomationTurnOutput,
    ): AutomationRunResult =
        automationRunner.executeAutomationRun(automationId, nowEpochMs, turnExecutor)
}
