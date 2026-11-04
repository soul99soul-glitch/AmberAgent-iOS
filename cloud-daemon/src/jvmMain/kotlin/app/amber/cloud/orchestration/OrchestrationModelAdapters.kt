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
import app.amber.cloud.runtime.CloudMemoryStore
import app.amber.cloud.soul.CloudSoulStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext
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
        val tools = registry.declaredTools(ExecutionScope.MAIN_AGENT)
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
            val answer = client.generateReply(messages, tools)
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
                            registry.executeGate(call.toolName, args, ExecutionScope.MAIN_AGENT).toString()
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
    private val maxSteps: Int = 20,
    private val memoryStore: CloudMemoryStore? = null,
    private val modelClients: Map<String, CloudModelClient> = emptyMap(),
    private val soulStore: CloudSoulStore? = null,
) {
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun run(item: CloudWorkItemRecord, principal: CloudPrincipal.Worker): WorkerSettlementReport {
        val sessionId = item.workerSessionId ?: return WorkerSettlementReport(item.workItemId, "failed", "缺少 Worker 会话")
        val uuid = Uuid.parse(sessionId)
        val registry = kernel.agentRegistry
        val profile = registry?.let { it.get(item.agentId) ?: error("Agent 已不存在") }
        val allowedTools = profile?.let { registry.effectiveTools(it) }
        val tools = toolRegistry.declaredTools(ExecutionScope.SUBAGENT).filter { allowedTools == null || it.name in allowedTools || it.name == "task_finish" }
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
            append(profile?.instructions.orEmpty())
            append('\n').append((item.targetNode as? ExecutionTargetNode.CloudSubagent)?.rolePrompt.orEmpty())
            if (memories.isNotEmpty()) append("\n<agent_memory>\n").append(memories.joinToString("\n") { it.content }).append("\n</agent_memory>")
        }
        var lastText = ""
        repeat(maxSteps) {
            if(kernel.workerEvents.isStopping(item.workItemId)) throw CancellationException("任务停止")
            if (kernel.store.getWorkItem(item.workItemId)?.state?.isTerminal != false)
                return WorkerSettlementReport(item.workItemId, "cancelled", "任务已结束")
            val pending=kernel.workerEvents.prepare(item)
            val history = kernel.conversationStorage.loadConversation(uuid)?.messageNodes?.map { it.currentMessage }.orEmpty()
            val answer = client.generateReply(listOf(UIMessage.system(systemPrompt)) + history, tools)
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
            var finish: WorkerSettlementReport? = null
            val executed = calls.map { call ->
                val current = kernel.store.getWorkItem(item.workItemId) ?: return WorkerSettlementReport(item.workItemId, "failed", "任务记录丢失")
                if (current.state.isTerminal) return WorkerSettlementReport(item.workItemId, "cancelled", "任务已结束")
                runCatching {
                    kernel.updateWorkerProgress(principal, item.workItemId, current.progressRevision, "正在处理第 ${it + 1} 步", call.toolName)
                }
                val args = runCatching { json.parseToJsonElement(call.input.ifBlank { "{}" }).jsonObject }
                    .getOrDefault(JsonObject(emptyMap()))
                val out = try {
                    require(finish == null) { "结算后不能再执行工具" }
                    if(kernel.workerEvents.isStopping(item.workItemId))throw CancellationException("任务停止")
                    if(call.toolName=="task_finish")require(kernel.workerEvents.pending(item.workItemId).isEmpty()) {"有尚未消费的任务事件，请先读取下一轮输入"}
                    val result = kernel.executeWorkerTool(principal, call.toolName, args)
                    if (call.toolName == "task_finish" && result.jsonObject["ok"]?.jsonPrimitive?.booleanOrNull == true) {
                        finish = WorkerSettlementReport(item.workItemId, result.jsonObject.getValue("outcome").jsonPrimitive.content,
                            CredentialRedactor.redact(result.jsonObject.getValue("summary").jsonPrimitive.content),
                            artifacts = result.jsonObject["artifacts"]?.jsonArray?.map { it.jsonObject.getValue("path").jsonPrimitive.content }.orEmpty())
                    }
                    result.toString()
                } catch (e: CancellationException) { throw e }
                  catch (e: Exception) { buildJsonObject { put("ok",false);put("error",CredentialRedactor.redact(e.message.orEmpty())) }.toString() }
                call.copy(
                    input = CredentialRedactor.redact(call.input),
                    output = listOf(UIMessagePart.Text(CredentialRedactor.redact(out))),
                )
            }
            kernel.appendWorkerMessage(
                sessionId,
                sanitize(answer.copy(parts = answer.parts.map { part ->
                    if (part is UIMessagePart.Tool) executed.firstOrNull { it.toolCallId == part.toolCallId } ?: part else part
                })),
            )
            finish?.let { return it }
        }
        return WorkerSettlementReport(item.workItemId, "failed", "超过最大步数仍未完成: ${CredentialRedactor.redact(lastText.take(200))}")
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
}
