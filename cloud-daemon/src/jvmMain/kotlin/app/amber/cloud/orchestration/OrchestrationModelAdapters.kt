package app.amber.cloud.orchestration

import app.amber.ai.core.MessageRole
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.agents.AgentMemoryPolicy
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.runtime.CloudToolRegistry
import app.amber.cloud.runtime.ExecutionScope
import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.agents.AgentProfile
import app.amber.cloud.runtime.CloudContextManager
import app.amber.cloud.runtime.CloudMemoryStore
import app.amber.cloud.soul.CloudSoulStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicLong
import kotlinx.serialization.json.*
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.decodeFromJsonElement
import kotlin.uuid.Uuid

/**
 * 生产 Router 大脑：只向模型声明 Router 专属工具（派单/引导/读取/诊断/召回），绝不声明执行类工具。
 * - `dispatch_work` → 解析为 [RouterDecision.dispatch]（由 Router 走持久化 WorkItem 队列，替代内存同步 spawn_subagent）；
 * - `steer_worker` → [RouterDecision.steer]；
 * - 只读工具在本轮内执行一次并把结果回灌给模型生成最终回复。
 */
class ModelRouterBrain(
    private val modelClient: CloudModelClient,
    private val routerTools: () -> CloudToolRegistry,
    private val modelSnapshot: () -> CloudModelClient = { modelClient },
    private val systemPrompt: String = DEFAULT_ROUTER_SYSTEM_PROMPT,
    private val maxReadSteps: Int = 2,
    private val contextMessages: suspend (RouterTurnInput) -> List<UIMessage> = { emptyList() },
) : RouterBrain {
    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun decide(input: RouterTurnInput): RouterDecision {
        val client = modelSnapshot()
        val registry = routerTools()
        // Authorization comes from the server-resolved source IDs, never the model's tool arguments.
        val ownerPrincipal = input.events.firstOrNull {
            it.kind == "user_message" && it.sourceMessageId in input.ownerAuthorizedMessageIds
        }?.let { CloudPrincipal.OwnerUser(it.senderId, it.channelId) }
        val tools = registry.declaredTools(ExecutionScope.MAIN_AGENT, ownerPrincipal)
        val history = contextMessages(input)
        val messages = history.toMutableList()
        if (messages.isEmpty()) messages += UIMessage.system(systemPrompt)
        if (history.isEmpty() || input.activeTasks.isNotEmpty() || input.events.any { it.kind != "user_message" }) {
            messages += UIMessage.user(
                buildString {
                    if (input.activeTasks.isNotEmpty()) {
                        append("<active_tasks>\n")
                        input.activeTasks.forEach {
                            append("- ").append(it.workItemId).append(" [").append(it.state).append("] ")
                                .append(CredentialRedactor.redact(it.title)).append('\n')
                        }
                        append("</active_tasks>\n")
                    }
                    append(CredentialRedactor.redact(input.batchPrompt))
                }
            )
        }
        val dispatch = mutableListOf<WorkItemSubmissionSpec>()
        val steer = mutableListOf<RouterSteer>()
        val cancel = mutableListOf<String>()
        var reply: String? = null
        var proposal: AgentProfile? = null
        repeat(maxReadSteps + 1) {
            val answer = client.streamReply(messages, tools) {}
            val calls = answer.getTools()
            reply = answer.toText().takeIf { it.isNotBlank() } ?: reply
            if (calls.isEmpty()) return RouterDecision(reply, dispatch, steer, proposal,cancel)
            var needsFollowup = false
            var finish: WorkerSettlementReport? = null
            val executed = calls.map { call ->
                val args = runCatching { json.parseToJsonElement(call.input.ifBlank { "{}" }).jsonObject }
                    .getOrDefault(JsonObject(emptyMap()))
                when (call.toolName) {
                    "propose_agent" -> proposal = args["profile"]?.let { json.decodeFromJsonElement<AgentProfile>(it) }
                    "dispatch_work" -> dispatch += CloudRouter.parseDispatchSpecs(args)
                    "steer_worker" -> {
                        val id = args["work_item_id"]?.jsonPrimitive?.contentOrNull
                        val instr = args["instruction"]?.jsonPrimitive?.contentOrNull
                        if (!id.isNullOrBlank() && !instr.isNullOrBlank()) steer += RouterSteer(id, instr)
                    }
                    "cancel_work_item" -> args["work_item_id"]?.jsonPrimitive?.contentOrNull?.let {cancel+=it}
                    else -> needsFollowup = true
                }
                val out = if (call.toolName in CloudRouter.ROUTER_TOOL_NAMES) {
                    runCatching {
                        withContext(RouterTurnAuthContext(input.ownerAuthorizedMessageIds.isNotEmpty())) {
                            registry.executeGate(call.toolName, args, ExecutionScope.MAIN_AGENT, principal = ownerPrincipal).toString()
                        }
                    }.getOrElse { "{\"ok\":false}" }
                } else {
                    "{\"ok\":false,\"error\":\"Router 不允许执行该工具\"}"
                }
                call.copy(output = listOf(UIMessagePart.Text(CredentialRedactor.redact(out))))
            }
            if (!needsFollowup) return RouterDecision(reply, dispatch, steer, proposal,cancel)
            if (calls.any { it.toolName == "agent_soul_update" } && messages.firstOrNull()?.role == MessageRole.SYSTEM) {
                contextMessages(input).firstOrNull { it.role == MessageRole.SYSTEM }?.let { freshSys ->
                    messages[0] = freshSys
                }
            }
            messages += answer.copy(parts = answer.parts.map { part ->
                if (part is UIMessagePart.Tool) executed.firstOrNull { it.toolCallId == part.toolCallId } ?: part else part
            })
        }
        return RouterDecision(reply, dispatch, steer, proposal,cancel)
    }

    companion object {
        const val DEFAULT_ROUTER_SYSTEM_PROMPT = """你是云端主对话协调层（请全程使用 <agent-soul> 设定的身份、称呼与口吻和用户自然交流）。你负责对话交流、更新形象人设、派单与汇报：
- 当用户要求更换人设、性格、称呼或说话口吻时，直接调用 agent_soul_update 更新全端共享形象人设，不要派给后台 Worker；
- 其他需要实际执行的工作一律用 dispatch_work 派给后台 Worker，不要自己伪造执行结果；
- 回复简短（不超过 100 词），保持当前形象人设口吻；
- 简单问题直接给实质答案，不先生成通用确认；后台任务有状态反馈时不重复确认。阶段交流只报告新发现、阶段变化、阻塞或需要用户决定的事项，不重复说“继续查”“还在看”；
- 对外回复中不要提及内部工具名、原始参数或推理过程。"""
    }
}

/**
 * 生产 Worker 执行器：在隔离的 Worker 会话中驱动模型，工具一律以 [ExecutionScope.SUBAGENT] 声明与执行
 * （高风险与写工具被物理剥离，缺陷清单 #5），每步上报进度，结束时产出结算报告。
 */
class ModelWorkerTurnRunner(
    private val kernel: DefaultCloudOrchestrationKernel,
    private val modelClient: CloudModelClient,
    private val toolRegistry: CloudToolRegistry,
    private val maxSteps: Int = 512,
    private val memoryStore: CloudMemoryStore? = null,
    private val modelClients: Map<String, CloudModelClient> = emptyMap(),
    private val soulStore: CloudSoulStore? = null,
    private val contextManager: CloudContextManager? = null,
    private val contextWindowTokens: Int = 32_000,
    private val activityThrottleMs: Long = 30_000L,
) {
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun run(item: CloudWorkItemRecord, principal: CloudPrincipal.Worker): WorkerSettlementReport {
        val sessionId = item.workerSessionId ?: return WorkerSettlementReport(item.workItemId, "failed", "缺少 Worker 会话")
        val uuid = Uuid.parse(sessionId)
        val registry = kernel.agentRegistry
        val profile = registry?.let { it.get(item.agentId) ?: error("Agent 已不存在") }
        val allowedTools = profile?.let { registry.effectiveTools(it) }
        val tools = toolRegistry.declaredTools(
            scope = ExecutionScope.SUBAGENT,
            principal = principal,
            includeWorkerApprovalTools = kernel.config.workerApprovals,
        ).filter { allowedTools == null || it.name in allowedTools || it.name == "task_finish" }
        val client = profile?.modelPreference?.let { modelClients[it] ?: error("Agent 模型配置已移除") } ?: modelClient
        val memories = if (profile != null) memoryStore?.recallForPrompt(item.brief, agentId = profile.id, memoryPolicy = profile.memoryPolicy).orEmpty() else emptyList()
        val policy = profile?.memoryPolicy ?: AgentMemoryPolicy.SHARED_WITH_GLOBAL
        val systemPrompt = buildString {
            append(
                soulStore?.renderDirectSystemPrompt(policy)
                    ?: if (profile != null) memoryStore?.loadSoulPrompt(policy).orEmpty() else CloudMemoryStore.DEFAULT_SOUL_MARKDOWN
            )
            append("\n你是受管 Worker，只处理当前任务；不得创建 agent、派单或向其他 agent 发送消息。\n")
            append("任务文件以相对路径访问。脚本执行受OS隔离且不能联网，用HTTP/搜索工具联网。工具失败必须检查并修正或报告阻塞。写代码文本不等于执行。最终必须调用 task_finish，明确completed/blocked/failed并列出实际产物；没有工具调用的回答不会自动成功。\n")
            append("耗时脚本用process_run后台启动（默认background=true），立刻继续处理补充；完成/失败/停止会作为任务事件送达。等待期间可不调用工具，系统会在新事件到达时继续；不要循环长时间process_wait。重启中断事件不表示旧命令已成功，先检查输出再决定下一步。\n")
            append("阶段交流只报告已核实的新发现、阶段变化、阻塞或需要用户决定的事项；不要逐工具播报或重复‘继续查、还在看’。无进展的保活由系统按最近已展示的实质进展判定，不自行定时发正文。\n")
            append(profile?.instructions.orEmpty())
            append('\n').append((item.targetNode as? ExecutionTargetNode.CloudSubagent)?.rolePrompt.orEmpty())
            if (memories.isNotEmpty()) append("\n<agent_memory>\n").append(memories.joinToString("\n") { it.content }).append("\n</agent_memory>")
        }
        var lastText = ""
        repeat(maxSteps) {
            if(kernel.workerEvents.isStopping(item.workItemId)) throw CancellationException("任务停止")
            if (kernel.store.getWorkItem(item.workItemId)?.state?.isTerminal != false)
                return WorkerSettlementReport(item.workItemId, "cancelled", "任务已结束")
            val pending = kernel.workerEvents.prepare(item)
            val preparedIds = pending.map { it.id }.toSet()
            val history = kernel.conversationStorage.loadConversation(uuid)?.messageNodes?.map { it.currentMessage }.orEmpty()
            val requestMessages = projectWorkerRequestMessages(
                sessionId = sessionId,
                workItemId = item.workItemId,
                systemPrompt = systemPrompt,
                history = history,
            )
            val answer = streamWorkerReplyWithPreemption(
                workItemId = item.workItemId,
                preparedIds = preparedIds,
                client = client,
                requestMessages = requestMessages,
                tools = tools,
            ) ?: return@repeat
            kernel.store.dialogue.consume(pending)
            if(kernel.workerEvents.isStopping(item.workItemId))throw CancellationException("任务停止")
            if(kernel.workerEvents.pending(item.workItemId).isNotEmpty())return@repeat
            if (kernel.store.getWorkItem(item.workItemId)?.state?.isTerminal != false)
                return WorkerSettlementReport(item.workItemId, "cancelled", "任务已结束")
            val calls = answer.getTools()
            lastText = answer.toText().ifBlank { lastText }
            if (calls.isEmpty()) {
                kernel.appendWorkerMessage(sessionId, sanitize(answer))
                if(kernel.hasBackgroundProcesses(item.workItemId)) {
                    kernel.workerEvents.await(item.workItemId)
                    return@repeat
                }
                return WorkerSettlementReport(item.workItemId, "blocked", CredentialRedactor.redact(lastText.ifBlank { "模型未显式结算，无法确认目标成功" }))
            }
            // Settlement owns the final answer; only intermediate tool rounds publish commentary.
            if (calls.none { it.toolName == "task_finish" }) kernel.workerCommentary(item, answer.toText())
            var finish: WorkerSettlementReport? = null
            var persistedWithApproval = false
            val executedParts = linkedMapOf<String, UIMessagePart.Tool>()
            for ((idx, call) in calls.withIndex()) {
                val current = kernel.store.getWorkItem(item.workItemId) ?: return WorkerSettlementReport(item.workItemId, "failed", "任务记录丢失")
                if (current.state.isTerminal) return WorkerSettlementReport(item.workItemId, "cancelled", "任务已结束")
                runCatching {
                    kernel.updateWorkerProgress(principal, item.workItemId, current.progressRevision, "正在处理第 ${idx + 1} 步", call.toolName)
                }
                val args = runCatching { json.parseToJsonElement(call.input.ifBlank { "{}" }).jsonObject }
                    .getOrDefault(JsonObject(emptyMap()))
                if (kernel.workerEvents.isStopping(item.workItemId)) throw CancellationException("任务停止")
                val needsWorkerApproval = finish == null &&
                    kernel.config.workerApprovals &&
                    toolRegistry.isWorkerApprovalTool(call.toolName) &&
                    (allowedTools == null || call.toolName in allowedTools)
                if (needsWorkerApproval) {
                    val assistantSnapshot = sanitize(
                        answer.copy(
                            parts = answer.parts.map { part ->
                                if (part is UIMessagePart.Tool) executedParts[part.toolCallId] ?: part else part
                            }
                        )
                    )
                    kernel.beginWorkerApprovalAndAwait(
                        item = item,
                        principal = principal,
                        sessionUuid = uuid,
                        assistantMessage = assistantSnapshot,
                        toolCall = call,
                        parsedArgs = args,
                        deferredCalls = calls.drop(idx + 1),
                    )
                    persistedWithApproval = true
                    break
                }
                val out = try {
                    require(finish == null) { "结算后不能再执行工具" }
                    if(kernel.workerEvents.isStopping(item.workItemId))throw CancellationException("任务停止")
                    if(call.toolName=="task_finish")require(kernel.workerEvents.pending(item.workItemId).isEmpty()) {"有尚未消费的任务事件，请先读取下一轮输入"}
                    val result = kernel.executeWorkerTool(principal, call.toolName, args)
                    val resultObj = runCatching { result.jsonObject }.getOrNull()
                    if (call.toolName == "task_finish" && resultObj?.get("ok")?.jsonPrimitive?.booleanOrNull == true) {
                        finish = WorkerSettlementReport(
                            workItemId = item.workItemId,
                            outcome = resultObj.getValue("outcome").jsonPrimitive.content,
                            summary = CredentialRedactor.redact(resultObj.getValue("summary").jsonPrimitive.content),
                            artifacts = resultObj["artifacts"]?.jsonArray?.map { it.jsonObject.getValue("path").jsonPrimitive.content }.orEmpty(),
                        )
                    }
                    result.toString()
                } catch (e: CancellationException) { throw e }
                  catch (e: Exception) { buildJsonObject { put("ok",false);put("error",CredentialRedactor.redact(e.message.orEmpty())) }.toString() }
                executedParts[call.toolCallId] = call.copy(
                    input = CredentialRedactor.redact(call.input),
                    output = listOf(UIMessagePart.Text(CredentialRedactor.redact(out))),
                )
            }
            if (!persistedWithApproval) {
                kernel.appendWorkerMessage(
                    sessionId,
                    sanitize(answer.copy(parts = answer.parts.map { part ->
                        if (part is UIMessagePart.Tool) executedParts[part.toolCallId] ?: part else part
                    })),
                )
            }
            finish?.let { return it }
        }
        return WorkerSettlementReport(item.workItemId, "failed", "超过最大步数仍未完成: ${CredentialRedactor.redact(lastText.take(200))}")
    }

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    private suspend fun streamWorkerReplyWithPreemption(
        workItemId: String,
        preparedIds: Set<String>,
        client: CloudModelClient,
        requestMessages: List<UIMessage>,
        tools: List<app.amber.ai.core.Tool>,
    ): UIMessage? {
        val lastHeartbeatMs = AtomicLong(kernel.currentEpochMs())
        val interruptTrigger = CompletableDeferred<String>()
        fun checkSignal() {
            if (kernel.workerEvents.isStopping(workItemId)) {
                interruptTrigger.complete("stop")
            } else if (kernel.workerEvents.pending(workItemId).any { it.id !in preparedIds }) {
                interruptTrigger.complete("event")
            }
        }
        val unwatch = kernel.workerEvents.watchEvents(workItemId) { checkSignal() }
        return try {
            checkSignal()
            if (interruptTrigger.isCompleted) {
                return when (interruptTrigger.getCompleted()) {
                    "stop" -> throw CancellationException("任务停止")
                    "event" -> null
                    else -> null
                }
            }
            coroutineScope {
                val streamDeferred = async {
                    client.streamReply(requestMessages, tools) { _ ->
                        val now = kernel.currentEpochMs()
                        val prev = lastHeartbeatMs.get()
                        if (now - prev >= activityThrottleMs && lastHeartbeatMs.compareAndSet(prev, now)) {
                            kernel.touchWorkItemActivity(workItemId, now)
                        }
                    }
                }
                val watcherJob = launch {
                    val reason = interruptTrigger.await()
                    streamDeferred.cancel(CancellationException("worker_interrupted:$reason"))
                }
                try {
                    streamDeferred.await()
                } catch (ce: CancellationException) {
                    if (interruptTrigger.isCompleted) {
                        when (interruptTrigger.getCompleted()) {
                            "stop" -> throw CancellationException("任务停止", ce)
                            "event" -> {
                                currentCoroutineContext().ensureActive()
                                null
                            }
                            else -> throw ce
                        }
                    } else {
                        throw ce
                    }
                } finally {
                    watcherJob.cancel()
                }
            }
        } finally {
            unwatch()
        }
    }

    private fun projectWorkerRequestMessages(
        sessionId: String,
        workItemId: String,
        systemPrompt: String,
        history: List<UIMessage>,
    ): List<UIMessage> {
        val anchorIndex = history.indexOfLast { msg ->
            msg.role == MessageRole.USER && msg.toText().let { text ->
                text.startsWith("【Worker 任务简报") && text.contains("WorkItemId: $workItemId")
            }
        }
        val anchorMessage = if (anchorIndex >= 0) history[anchorIndex] else null
        val historyWithoutAnchor = if (anchorIndex >= 0) {
            history.filterIndexed { index, _ -> index != anchorIndex }
        } else {
            history
        }

        val recentToolTurnIndices = historyWithoutAnchor.indices
            .filter { idx ->
                val msg = historyWithoutAnchor[idx]
                msg.role == MessageRole.ASSISTANT && msg.parts.any { it is UIMessagePart.Tool }
            }
            .takeLast(2)
            .toSet()
        val latestEventIndex = historyWithoutAnchor.indexOfLast { msg ->
            msg.role == MessageRole.USER && msg.toText().startsWith("【任务事件 ")
        }
        val recentWindowIndices = if (latestEventIndex >= 0) {
            recentToolTurnIndices + latestEventIndex
        } else {
            recentToolTurnIndices
        }

        val projectedHistory = historyWithoutAnchor.mapIndexed { idx, msg ->
            val inRecentWindow = idx in recentWindowIndices
            projectMessageOutputs(msg, inRecentWindow)
        }

        val manager = contextManager
        if (manager == null) {
            return buildList {
                add(UIMessage.system(systemPrompt))
                if (anchorMessage != null) add(anchorMessage)
                addAll(projectedHistory)
            }
        }

        val anchorTokens = anchorMessage?.let { manager.estimateTokens(it) } ?: 0
        manager.compactIfNeeded(sessionId, projectedHistory, contextWindowTokens)
        val remainingBudget = (contextWindowTokens - anchorTokens).coerceAtLeast(64)
        val prepared = manager.prepareRequestMessages(
            systemPrompt = systemPrompt,
            memories = emptyList(),
            conversationId = sessionId,
            historyMessages = projectedHistory,
            tokenBudget = remainingBudget,
        )
        if (anchorMessage == null) return prepared
        val insertIndex = prepared.indexOfFirst { it.role != MessageRole.SYSTEM }
            .let { if (it < 0) prepared.size else it }
        return buildList(prepared.size + 1) {
            addAll(prepared.subList(0, insertIndex))
            add(anchorMessage)
            addAll(prepared.subList(insertIndex, prepared.size))
        }
    }

    private fun projectMessageOutputs(message: UIMessage, inRecentWindow: Boolean): UIMessage {
        // A model can batch several large reads in one assistant message. The
        // context fitter keeps the newest message, so bound that batch as well.
        val textPartCount = message.parts.sumOf { part ->
            when (part) {
                is UIMessagePart.Text -> 1
                is UIMessagePart.Tool -> part.output.count { it is UIMessagePart.Text }
                else -> 0
            }
        }.coerceAtLeast(1)
        val partLimit = minOf(
            if (inRecentWindow) RECENT_MAX_CHARS else OLD_FOLD_THRESHOLD_CHARS,
            RECENT_MAX_CHARS / textPartCount,
        )
        var changed = false
        val newParts = message.parts.map { part ->
            when (part) {
                is UIMessagePart.Text -> {
                    val projected = projectText(part.text, inRecentWindow, partLimit)
                    if (projected !== part.text) {
                        changed = true
                        part.copy(text = projected)
                    } else part
                }
                is UIMessagePart.Tool -> {
                    var outputChanged = false
                    val newOutput = part.output.map { outPart ->
                        if (outPart is UIMessagePart.Text) {
                            val projected = projectText(outPart.text, inRecentWindow, partLimit)
                            if (projected !== outPart.text) {
                                outputChanged = true
                                outPart.copy(text = projected)
                            } else outPart
                        } else outPart
                    }
                    if (outputChanged) {
                        changed = true
                        part.copy(output = newOutput)
                    } else part
                }
                else -> part
            }
        }
        return if (changed) message.copy(parts = newParts) else message
    }

    private fun projectText(text: String, inRecentWindow: Boolean, partLimit: Int): String {
        if (text.length <= partLimit) return text
        val keepSide = minOf(
            if (inRecentWindow) RECENT_KEEP_SIDE_CHARS else OLD_KEEP_SIDE_CHARS,
            (partLimit - 200).coerceAtLeast(0) / 2,
        )
        val omitted = text.length - keepSide * 2
        val action = if (inRecentWindow) "已截断" else "已折叠"
        return "${text.take(keepSide)}\n...[$action $omitted 字符，原长度 ${text.length} 字符，原文保留在任务会话，可用 history_fetch 读取]...\n${text.takeLast(keepSide)}"
    }

    private fun sanitize(message: UIMessage): UIMessage = message.copy(
        parts = message.parts.map { part ->
            when (part) {
                is UIMessagePart.Text -> part.copy(text = CredentialRedactor.redact(part.text))
                is UIMessagePart.Reasoning -> part.copy(reasoning = CredentialRedactor.redact(part.reasoning))
                else -> part
            }
        }
    )

    companion object {
        private const val OLD_FOLD_THRESHOLD_CHARS = 4_000
        private const val OLD_KEEP_SIDE_CHARS = 1_500
        private const val RECENT_MAX_CHARS = 24_000
        private const val RECENT_KEEP_SIDE_CHARS = 10_000
    }
}
