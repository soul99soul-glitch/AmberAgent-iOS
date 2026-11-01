package app.amber.cloud.orchestration

import app.amber.ai.ui.UIMessage
import app.amber.cloud.agents.AgentRegistry
import app.amber.cloud.channel.InboundMessage
import app.amber.cloud.channel.OutboundCard
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.proactive.ProactiveEngine
import app.amber.cloud.runtime.CloudToolRegistry
import app.amber.cloud.runtime.ExecutionScope
import app.amber.cloud.security.CredentialRedactor
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
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

    internal suspend fun maybeTriggerBatchRollupInternal(batchId: String, nowEpochMs: Long) {
        rollupCoordinator.maybeTriggerBatchRollup(batchId, nowEpochMs)
    }

    @Synchronized
    internal fun launchWorkerRunnerInternal(item: CloudWorkItemRecord) {
        if (activeWorkerJobs[item.workItemId]?.isActive == true) return
        val runner = workerTurnRunner ?: return
        val workerPrincipal = workerPrincipalFor(item)
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                val report = runCatching { runner(item, workerPrincipal) }.getOrElse { t ->
                    if (t is CancellationException) throw t
                    WorkerSettlementReport(
                        workItemId = item.workItemId,
                        outcome = "failed",
                        summary = "执行异常: ${CredentialRedactor.redact(t.message.orEmpty())}",
                    )
                }
                if (report != null) {
                    runCatching { reportWorkerSettlement(workerPrincipal, report, clockMs()) }
                }
            } finally {
                activeWorkerJobs.remove(item.workItemId)
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
                messageNodes = existing.messageNodes + message.toMessageNode(),
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

    val isHealthLoopRunning: Boolean get() = healthJob?.isActive == true

    fun setMacNodeOnline(deviceId: String, online: Boolean, nowEpochMs: Long = clockMs()) =
        workQueueCoordinator.setMacNodeOnline(deviceId, online, nowEpochMs)

    fun isMacNodeOnline(deviceId: String): Boolean =
        workQueueCoordinator.isMacNodeOnline(deviceId)

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
    ): JsonElement {
        if (principal !is CloudPrincipal.Worker) {
            throw PrincipalPermissionException("executeWorkerTool 仅限 Worker 主体调用")
        }
        val item = store.getWorkItem(principal.workItemId)
            ?: throw PrincipalPermissionException("Worker 任务不存在")
        if (principal != workerPrincipalFor(item) || item.state.isTerminal) throw PrincipalPermissionException("Worker 身份或状态无效")
        val registry = agentRegistry
        if (registry != null) {
            val agent = registry.get(item.agentId) ?: throw PrincipalPermissionException("Agent 不存在")
            if (toolName !in registry.effectiveTools(agent)) throw PrincipalPermissionException("Agent 未获授该工具")
            // History tools must never reopen the global timeline or another agent's session.
            if (toolName in setOf("history_search", "history_fetch")) {
                val requested = (args["conversation_id"] as? kotlinx.serialization.json.JsonPrimitive)?.content
                if (requested != null && requested != item.workerSessionId) throw PrincipalPermissionException("禁止跨会话读取")
                val scopedArgs = JsonObject(args + ("conversation_id" to kotlinx.serialization.json.JsonPrimitive(item.workerSessionId)))
                return toolRegistry.executeGate(toolName, scopedArgs, ExecutionScope.SUBAGENT)
            }
        }
        return toolRegistry.executeGate(toolName, args, ExecutionScope.SUBAGENT)
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
