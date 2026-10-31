package app.amber.cloud.orchestration

import app.amber.cloud.channel.ChannelConnector
import app.amber.cloud.channel.ChannelKind
import app.amber.cloud.channel.InboundMessage
import app.amber.cloud.channel.OutboundMessage
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.channel.resolveConversationId
import app.amber.cloud.channels.FeishuChannel
import app.amber.cloud.channels.TelegramChannel
import app.amber.cloud.runtime.CloudToolDefinition
import app.amber.cloud.runtime.CloudToolRegistry
import app.amber.cloud.runtime.ExecutionScope
import app.amber.cloud.runtime.ToolEffect
import app.amber.cloud.security.CredentialRedactor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

// ============================================================================
// Router 层：对外交互 + 派单（不挂执行类工具）
// ============================================================================

/** IM 投递地址。 */
data class ImAddress(
    val channel: ChannelKind,
    val chatId: String,
    val threadId: String? = null,
)

/**
 * IM 状态出口：投递新消息 / 编辑同一条消息。
 * - [edit] 返回 false 表示该通道不支持编辑（Router 退化为仅在终态补发一条，不刷屏）。
 */
interface ImStatusSink {
    suspend fun post(address: ImAddress, text: String): String
    suspend fun edit(address: ImAddress, messageId: String, text: String): Boolean
}

/**
 * 可选的“编辑已发消息”通道能力。当前 Telegram/Feishu 连接器尚未实现（缺陷清单 #9：不虚假声明），
 * 未实现时 [ConnectorImStatusSink.edit] 返回 false。
 */
interface EditableChannelConnector {
    suspend fun edit(chatId: String, messageId: String, text: String): Result<Unit>
}

/** 生产适配：把 [ImStatusSink] 接到已注册的 [ChannelConnector]。 */
class ConnectorImStatusSink(
    private val connectorLookup: (ChannelKind) -> ChannelConnector?,
) : ImStatusSink {
    override suspend fun post(address: ImAddress, text: String): String {
        val connector = connectorLookup(address.channel) ?: return ""
        return connector.send(
            OutboundMessage(
                channel = address.channel,
                chatId = address.chatId,
                threadId = address.threadId,
                text = text,
            )
        ).getOrDefault("")
    }

    override suspend fun edit(address: ImAddress, messageId: String, text: String): Boolean {
        if (messageId.isBlank()) return false
        return when (val connector = connectorLookup(address.channel)) {
            is EditableChannelConnector -> connector.edit(address.chatId, messageId, text).isSuccess
            is TelegramChannel -> connector.editStreamMessage(address.chatId, messageId, text).ok
            is FeishuChannel -> connector.editStreamMessage(address.chatId, messageId, text).ok
            else -> false
        }
    }
}

/** Router 单轮输入：积压事件合并成一批。 */
data class RouterTurnInput(
    val events: List<RouterTriggerEvent>,
    val activeTasks: List<CloudWorkItemRecord>,
    /** 本批中可授权新任务的主人原始消息 ID（服务端溯源解析结果） */
    val ownerAuthorizedMessageIds: List<String>,
    val batchPrompt: String,
)

data class RouterSteer(val workItemId: String, val instruction: String)

/** Router 单轮决策（模型或 Mock 产出；Router 只能回复、派单、引导，不能直接执行工具）。 */
data class RouterDecision(
    val reply: String? = null,
    val dispatch: List<WorkItemSubmissionSpec> = emptyList(),
    val steer: List<RouterSteer> = emptyList(),
)

fun interface RouterBrain {
    suspend fun decide(input: RouterTurnInput): RouterDecision
}

data class RouterAck(
    val text: String,
    val messageId: String?,
    val latencyMs: Long,
    val routing: DefaultCloudOrchestrationKernel.InboundRoutingDecision,
)

/**
 * 对外文本净化：不暴露工具名、参数、原始返回与推理内容；强制经过 [CredentialRedactor]。
 */
object OutwardTextSanitizer {
    const val ACTIVITY_LABEL_MAX_CHARS = 20

    private val reasoningBlock = Regex("(?is)<(thinking|think|reasoning|analysis)>.*?</\\1>")
    private val codeFence = Regex("(?s)```.*?```")
    private val jsonLike = Regex("(?s)\\{\\s*\"[^\"]+\"\\s*:.*?}")
    private val snakeIdentifier = Regex("`?\\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\\b(?:\\([^)]*\\))?`?")
    private val multiSpace = Regex("[ \\t]{2,}")

    fun sanitize(text: String, forbiddenToolNames: Set<String> = emptySet()): String {
        var out = CredentialRedactor.redact(text)
        out = out.replace(CredentialRedactor.MASK, "")
        out = reasoningBlock.replace(out, "")
        out = codeFence.replace(out, "")
        out = jsonLike.replace(out, "")
        for (name in forbiddenToolNames.sortedByDescending { it.length }) {
            if (name.isNotBlank()) out = out.replace(name, "", ignoreCase = true)
        }
        out = snakeIdentifier.replace(out, "")
        out = out.replace("``", "")
        out = multiSpace.replace(out, " ")
        return out.lines().map { it.trimEnd() }.filter { it.isNotBlank() }.joinToString("\n").trim()
    }

    /** 人话短语：净化后按代码点截断至 20 字以内。 */
    fun activityLabel(raw: String, forbiddenToolNames: Set<String> = emptySet()): String {
        val clean = sanitize(raw, forbiddenToolNames).replace('\n', ' ').trim().ifEmpty { "处理中" }
        val cpCount = clean.codePointCount(0, clean.length)
        if (cpCount <= ACTIVITY_LABEL_MAX_CHARS) return clean
        val end = clean.offsetByCodePoints(0, ACTIVITY_LABEL_MAX_CHARS - 1)
        return clean.substring(0, end) + "…"
    }
}

/**
 * Router：对外交互与派单层（对标 Grok bot 的“先应答、后台干活、只显示在做什么”）。
 *
 * - 每条消息先用确定性模板在毫秒级给出一句确认（不调用模型），再把事件交给后台 Router 循环；
 * - Router 循环把积压事件合并成一批交给 [RouterBrain]，期间新消息不会被阻塞；
 * - 属于在跑任务话题的消息由内核直通对应 Worker；
 * - Worker 的生命周期通过 [ActivityStatus] 编辑同一条 IM 状态消息呈现；
 * - 一批任务结束只由 wakeClaim 唤醒一次，产出一条验收汇总。
 */
class CloudRouter(
    val kernel: DefaultCloudOrchestrationKernel,
    private val sink: ImStatusSink,
    var brain: RouterBrain,
    /** 执行类工具名（来自主工具注册表），对外输出一律剥离 */
    executionToolNames: Set<String> = emptySet(),
    private val clockMs: () -> Long = { System.currentTimeMillis() },
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val onReply: suspend (conversationId: String, text: String) -> Unit = { _, _ -> },
) {
    private val json = Json { encodeDefaults = true; explicitNulls = false }

    /** Router 专属工具表：只含派单/引导/读取/诊断/召回，不含任何执行类工具。 */
    val routerTools: CloudToolRegistry = CloudToolRegistry().also { registerRouterTools(it) }

    val forbiddenToolNames: Set<String> = executionToolNames +
        routerTools.availableDefinitions(ExecutionScope.MAIN_AGENT).map { it.name }

    private val running = AtomicBoolean(false)
    private val loopMutex = Mutex()
    private val statusMutex = Mutex()
    private val eventAddress = ConcurrentHashMap<String, ImAddress>()
    private val taskAddress = ConcurrentHashMap<String, ImAddress>()
    private val batchAddress = ConcurrentHashMap<String, ImAddress>()
    private val statusMessageIds = ConcurrentHashMap<String, String>()
    private val latestStatus = ConcurrentHashMap<String, ActivityStatus>()
    @Volatile private var lastOwnerAddress: ImAddress? = null

    /** 全部对外发出的文本（审计/测试用） */
    val outboundLog = CopyOnWriteArrayList<String>()
    val activityLog = CopyOnWriteArrayList<ActivityStatus>()
    val routerTurnCount = AtomicInteger(0)
    val lastTurnEventCounts = CopyOnWriteArrayList<Int>()

    init {
        kernel.activityListener = { record, phase -> onWorkItemActivity(record, phase) }
        kernel.routerWakeListener = { kick() }
        val previousRollup = kernel.onBatchRollupWoken
        kernel.onBatchRollupWoken = { rollup ->
            previousRollup?.invoke(rollup)
            onBatchRollup(rollup)
        }
    }

    // ------------------------------------------------------------------------
    // 1. 入站：几秒内（实际毫秒级）给出确认，后台处理
    // ------------------------------------------------------------------------

    suspend fun onInbound(
        message: InboundMessage,
        postAck: Boolean = true,
        sessionId: String = resolveConversationId(message).toString(),
    ): RouterAck {
        val startedAt = System.nanoTime()
        val address = ImAddress(message.channel, message.chatId, message.threadId)
        if (message.senderRole == SenderRole.OWNER) lastOwnerAddress = address
        eventAddress["trig:${message.messageId}"] = address

        val routing = kernel.routeInboundMessage(message, sessionId, clockMs())
        val ackText = when (routing) {
            is DefaultCloudOrchestrationKernel.InboundRoutingDecision.DirectPassThroughToWorkers -> {
                val titles = routing.workerItemIds.mapNotNull { kernel.store.getWorkItem(it)?.title }
                val label = OutwardTextSanitizer.activityLabel(titles.firstOrNull().orEmpty(), forbiddenToolNames)
                "收到，已转给进行中的「$label」。"
            }
            is DefaultCloudOrchestrationKernel.InboundRoutingDecision.QueuedForRouterBatch -> "收到，和刚才的一起处理。"
            is DefaultCloudOrchestrationKernel.InboundRoutingDecision.RouteToCoordinatorNow -> "收到，马上处理。"
        }
        val ackId = if (postAck) emit(address, ackText) else null
        if (routing !is DefaultCloudOrchestrationKernel.InboundRoutingDecision.DirectPassThroughToWorkers) {
            kick()
        }
        return RouterAck(
            text = ackText,
            messageId = ackId,
            latencyMs = (System.nanoTime() - startedAt) / 1_000_000,
            routing = routing,
        )
    }

    /** 唤醒 Router 后台循环（幂等；已在运行时由循环自行 drain 新积压）。 */
    fun kick() {
        scope.launch { runLoop() }
    }

    /**
     * 等待后台 Router 循环（及可选的后台 Worker 与其触发的 BatchRollup）全部处理完毕。
     */
    suspend fun awaitIdle(includeWorkers: Boolean = false) {
        while (true) {
            while (running.get() || kernel.hasPendingRouterEvents()) {
                runLoop()
                loopMutex.withLock { }
            }
            if (!includeWorkers) break
            kernel.awaitBackgroundWorkers()
            if (!running.get() && !kernel.hasPendingRouterEvents()) break
        }
    }

    private suspend fun runLoop() {
        if (!running.compareAndSet(false, true)) return
        loopMutex.withLock {
            try {
                while (true) {
                    val events = kernel.drainPendingRouterBatch()
                    if (events.isEmpty()) break
                    kernel.isRouterTurnBusy = true
                    try {
                        for (conversationEvents in events.groupBy { it.conversationId }.values) {
                            runCatching { processTurn(conversationEvents) }
                        }
                    } finally {
                        kernel.isRouterTurnBusy = false
                    }
                }
            } finally {
                running.set(false)
            }
        }
        // 关闭窗口内新到的事件：再踢一次
        if (kernel.hasPendingRouterEvents()) kick()
    }

    private suspend fun processTurn(events: List<RouterTriggerEvent>) {
        routerTurnCount.incrementAndGet()
        lastTurnEventCounts.add(events.size)
        val ownerIds = events
            .filter { it.kind == "user_message" }
            .mapNotNull { it.sourceMessageId }
            .filter { kernel.store.getSourceMessage(it)?.canAuthorizeNewWork == true }
        val address = events.asReversed().firstNotNullOfOrNull { eventAddress[it.eventId] }
            ?: events.firstNotNullOfOrNull { ev -> ev.conversationId.let { conv -> batchAddressForConversation(conv) } }
            ?: lastOwnerAddress
        val input = RouterTurnInput(
            events = events,
            activeTasks = kernel.store.listWorkItems().filter { item ->
                !item.state.isTerminal && item.sourceProvenance.any { it.sessionId == events.first().conversationId }
            },
            ownerAuthorizedMessageIds = ownerIds,
            batchPrompt = kernel.formatRouterBatchPrompt(events),
        )
        val decision = runCatching { brain.decide(input) }
            .getOrElse { RouterDecision(reply = "这次没处理好，我稍后再试。") }

        val replies = mutableListOf<String>()
        if (decision.dispatch.isNotEmpty()) {
            if (ownerIds.isEmpty()) {
                replies += "只有主人本人可以安排新任务。"
            } else {
                try {
                    val conversationId = events.first().conversationId
                    val requestId = "router:" + OrchestrationHash.sha256Hex(
                        events.joinToString("|") { it.eventId } + "|" + decision.dispatch.joinToString("|") { it.taskKey }
                    ).take(32)
                    val result = kernel.submitWorkBatch(
                        principal = CloudPrincipal.CloudCoordinator(
                            activeSessionId = conversationId,
                            activeTurnId = requestId,
                        ),
                        requestId = requestId,
                        contextMessageIds = ownerIds,
                        items = decision.dispatch,
                        nowEpochMs = clockMs(),
                    )
                    if (address != null) {
                        batchAddress[result.batchId] = address
                        for (item in result.items) {
                            taskAddress[item.workItemId] = address
                            val status = latestStatus[item.workItemId] ?: ActivityStatus(
                                taskId = item.workItemId,
                                label = labelFor(item, ActivityPhase.STARTED),
                                phase = ActivityPhase.STARTED,
                                updatedAtMs = clockMs(),
                            ).also { recordActivity(it) }
                            upsertStatusMessage(status)
                        }
                    }
                } catch (e: UnauthorizedWorkSourceException) {
                    replies += "只有主人本人可以安排新任务。"
                } catch (e: PrincipalPermissionException) {
                    replies += "这个请求没有权限执行。"
                } catch (e: WorkItemConflictException) {
                    replies += "同名任务已存在且内容不同，请换个说法。"
                }
            }
        }
        for (steer in decision.steer) {
            runCatching {
                kernel.steerWorker(
                    principal = CloudPrincipal.CloudCoordinator(activeSessionId = events.first().conversationId, activeTurnId = "steer"),
                    workItemId = steer.workItemId,
                    followupInstruction = steer.instruction,
                    nowEpochMs = clockMs(),
                )
            }
        }
        decision.reply?.takeIf { it.isNotBlank() }?.let { replies += it }
        if (replies.isEmpty() && events.any { it.kind == "batch_rollup" }) {
            replies += events.filter { it.kind == "batch_rollup" }.joinToString("\n") { it.summaryText }
        }
        if (address != null) {
            for (reply in replies) emit(address, reply, events.first().conversationId)
        }
    }

    private fun batchAddressForConversation(conversationId: String): ImAddress? =
        if (conversationId.startsWith("batch:")) batchAddress[conversationId] else null

    // ------------------------------------------------------------------------
    // 2. ActivityStatus：编辑同一条状态消息
    // ------------------------------------------------------------------------

    private fun labelFor(record: CloudWorkItemRecord, phase: ActivityPhase): String {
        val raw = when (phase) {
            ActivityPhase.STARTED -> "开始${record.title}"
            ActivityPhase.PROGRESS -> record.latestProgressNote?.takeIf { it.isNotBlank() } ?: "正在${record.title}"
            ActivityPhase.DONE -> "已完成${record.title}"
            ActivityPhase.FAILED -> "未完成${record.title}"
        }
        return OutwardTextSanitizer.activityLabel(raw, forbiddenToolNames)
    }

    private fun recordActivity(status: ActivityStatus) {
        latestStatus[status.taskId] = status
        activityLog.add(status)
    }

    private suspend fun onWorkItemActivity(record: CloudWorkItemRecord, phase: ActivityPhase) {
        val previous = latestStatus[record.workItemId]
        if (previous != null && previous.phase.isTerminal) return
        val status = ActivityStatus(
            taskId = record.workItemId,
            label = labelFor(record, phase),
            phase = phase,
            updatedAtMs = clockMs(),
        )
        recordActivity(status)
        if (taskAddress.containsKey(record.workItemId)) upsertStatusMessage(status)
    }

    fun renderStatus(status: ActivityStatus): String {
        val icon = when (status.phase) {
            ActivityPhase.STARTED -> "⏳"
            ActivityPhase.PROGRESS -> "🔄"
            ActivityPhase.DONE -> "✅"
            ActivityPhase.FAILED -> "⚠️"
        }
        return "$icon ${status.label}"
    }

    private suspend fun upsertStatusMessage(status: ActivityStatus) = statusMutex.withLock {
        val address = taskAddress[status.taskId] ?: return@withLock
        val text = renderStatus(status)
        val existingId = statusMessageIds[status.taskId]
        if (existingId == null) {
            statusMessageIds[status.taskId] = emit(address, text)
            return@withLock
        }
        val safe = OutwardTextSanitizer.sanitize(text, forbiddenToolNames)
        val edited = sink.edit(address, existingId, safe)
        if (edited) {
            outboundLog.add(safe)
        } else if (status.phase.isTerminal) {
            // 通道不支持编辑：只在终态补发一条，避免进度刷屏
            emit(address, text)
        }
    }

    fun statusMessageIdFor(taskId: String): String? = statusMessageIds[taskId]

    // ------------------------------------------------------------------------
    // 3. BatchRollup：只唤醒一次，产出一条验收汇总
    // ------------------------------------------------------------------------

    private fun onBatchRollup(rollup: BatchRollupRecord) {
        val items = rollup.workItemIds.mapNotNull { kernel.store.getWorkItem(it) }
        val done = items.count { it.state == WorkItemState.COMPLETED }
        val notDone = items.size - done
        val summary = buildString {
            append("这批任务结束：").append(done).append(" 项完成")
            if (notDone > 0) append("，").append(notDone).append(" 项未完成")
            append("。详情 doc:rollups/").append(rollup.batchId).append(".md")
        }
        val address = batchAddress[rollup.batchId]
        val eventId = "rollup:${rollup.wakeClaimId}"
        if (address != null) eventAddress[eventId] = address
        kernel.enqueueRouterTriggerWhileBusy(
            RouterTriggerEvent(
                eventId = eventId,
                kind = "batch_rollup",
                conversationId = items.firstOrNull()?.sourceProvenance?.firstOrNull()?.sessionId ?: rollup.batchId,
                channelId = address?.channel?.wireName ?: "internal",
                chatId = address?.chatId ?: "internal",
                senderId = "system",
                summaryText = summary,
                createdAtMs = clockMs(),
            )
        )
    }

    // ------------------------------------------------------------------------
    // 4. 统一出口：净化 + 100 词预算 + 归档引用
    // ------------------------------------------------------------------------

    private suspend fun emit(address: ImAddress, raw: String, conversationId: String? = null): String {
        val sanitized = OutwardTextSanitizer.sanitize(raw, forbiddenToolNames).ifBlank { "好的。" }
        val budgeted = kernel.enforceImReplyWordBudget(sanitized)
        outboundLog.add(budgeted)
        if (conversationId != null) onReply(conversationId, budgeted)
        return sink.post(address, budgeted)
    }

    // ------------------------------------------------------------------------
    // 5. Router 专属工具（替代内存同步 spawn_subagent：派单进入持久化 WorkItem 队列）
    // ------------------------------------------------------------------------

    private fun registerRouterTools(registry: CloudToolRegistry) {
        registry.register(
            CloudToolDefinition(
                name = "dispatch_work",
                description = "把任务派给后台 Worker（异步，立即返回）。参数 tasks: [{task_key,title,brief}]",
                highRisk = false,
                effect = ToolEffect.PURE,
            ) { args ->
                // 实际派发在 Router 决策阶段由 submitWorkBatch 完成（需要服务端溯源的主人消息 ID）
                buildJsonObject {
                    put("ok", true)
                    put("status", "Accepted")
                    put("count", parseDispatchSpecs(args).size)
                }
            }
        )
        registry.register(
            CloudToolDefinition(
                name = "steer_worker",
                description = "给进行中的 Worker 追加指令",
                highRisk = false,
                effect = ToolEffect.PURE,
            ) { _ -> buildJsonObject { put("ok", true); put("status", "Accepted") } }
        )
        registry.register(
            CloudToolDefinition(
                name = "read_worker_session",
                description = "分页读取 Worker 会话摘要（含下一跳 ID）",
                highRisk = false,
                effect = ToolEffect.PURE,
            ) { args ->
                val page = kernel.readWorkerSessionPage(
                    sessionId = args["session_id"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    pageCursor = args["cursor"]?.jsonPrimitive?.contentOrNull,
                )
                json.encodeToJsonElement(page)
            }
        )
        registry.register(
            CloudToolDefinition(
                name = "read_worker_message_slice",
                description = "按 messageVersion 读取单条长消息切片（Unicode 安全）",
                highRisk = false,
                effect = ToolEffect.PURE,
            ) { args ->
                val slice = kernel.readWorkerMessageSlice(
                    MessageSliceCursor(
                        sessionId = args["session_id"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                        messageIndex = args["message_index"]?.jsonPrimitive?.intOrNull ?: 0,
                        messageId = args["message_id"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                        messageVersion = args["message_version"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                        offsetChars = args["offset"]?.jsonPrimitive?.intOrNull ?: 0,
                    )
                )
                json.encodeToJsonElement(slice)
            }
        )
        registry.register(
            CloudToolDefinition(
                name = "diagnose_worker_session",
                description = "一站式诊断 Worker 会话（findings + coverage）",
                highRisk = false,
                effect = ToolEffect.PURE,
            ) { args ->
                json.encodeToJsonElement(
                    kernel.diagnoseWorkerSession(args["session_id"]?.jsonPrimitive?.contentOrNull.orEmpty(), clockMs())
                )
            }
        )
        registry.register(
            CloudToolDefinition(
                name = "recall_object",
                description = "链式召回：按对象类型与 ID 返回摘要与下一跳",
                highRisk = false,
                effect = ToolEffect.PURE,
            ) { args ->
                val kind = runCatching {
                    RecallObjectKind.valueOf(args["kind"]?.jsonPrimitive?.contentOrNull.orEmpty().uppercase())
                }.getOrNull()
                val snap = kind?.let { kernel.recallObject(it, args["id"]?.jsonPrimitive?.contentOrNull.orEmpty()) }
                if (snap == null) buildJsonObject { put("ok", false) } else json.encodeToJsonElement(snap)
            }
        )
        registry.register(
            CloudToolDefinition(
                name = "async_tool_stop",
                description = "停止一个后台异步工具",
                highRisk = false,
                effect = ToolEffect.PURE,
            ) { args ->
                json.encodeToJsonElement(
                    kernel.stopAsyncTool(args["handle_id"]?.jsonPrimitive?.contentOrNull.orEmpty())
                )
            }
        )
    }

    companion object {
        val ROUTER_TOOL_NAMES = setOf(
            "dispatch_work",
            "steer_worker",
            "read_worker_session",
            "read_worker_message_slice",
            "diagnose_worker_session",
            "recall_object",
            "async_tool_stop",
        )

        fun parseDispatchSpecs(args: JsonObject): List<WorkItemSubmissionSpec> {
            val tasks = (args["tasks"] as? JsonArray) ?: return emptyList()
            return tasks.mapNotNull { el ->
                val obj = runCatching { el.jsonObject }.getOrNull() ?: return@mapNotNull null
                val title = obj["title"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
                val brief = obj["brief"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
                val key = obj["task_key"]?.jsonPrimitive?.contentOrNull?.trim()
                    ?.takeIf { WorkItemSubmissionSpec.TASK_KEY_REGEX.matches(it) }
                    ?: ("task:" + OrchestrationHash.sha256Hex("$title\n$brief").take(16))
                if (title.isEmpty() && brief.isEmpty()) return@mapNotNull null
                runCatching {
                    WorkItemSubmissionSpec(
                        taskKey = key,
                        title = title.ifEmpty { brief.take(20) },
                        brief = brief.ifEmpty { title },
                        targetNode = ExecutionTargetNode.CloudSubagent(rolePrompt = "worker"),
                        subscribedThreadKeys = obj["thread_keys"]?.let { tk ->
                            runCatching { tk.jsonArray.mapNotNull { it.jsonPrimitive.contentOrNull } }.getOrNull()
                        }.orEmpty(),
                    )
                }.getOrNull()
            }
        }
    }
}
