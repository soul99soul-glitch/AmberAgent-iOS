package app.amber.cloud.orchestration

import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.runtime.CloudToolRegistry
import app.amber.cloud.runtime.ExecutionScope
import app.amber.cloud.security.CredentialRedactor
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
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
    private val systemPrompt: String = DEFAULT_ROUTER_SYSTEM_PROMPT,
    private val maxReadSteps: Int = 2,
    private val contextMessages: suspend (RouterTurnInput) -> List<UIMessage> = { emptyList() },
) : RouterBrain {
    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun decide(input: RouterTurnInput): RouterDecision {
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
        var reply: String? = null
        repeat(maxReadSteps + 1) {
            val answer = modelClient.generateReply(messages, tools)
            val calls = answer.getTools()
            reply = answer.toText().takeIf { it.isNotBlank() } ?: reply
            if (calls.isEmpty()) return RouterDecision(reply, dispatch, steer)
            var needsFollowup = false
            val executed = calls.map { call ->
                val args = runCatching { json.parseToJsonElement(call.input.ifBlank { "{}" }).jsonObject }
                    .getOrDefault(JsonObject(emptyMap()))
                when (call.toolName) {
                    "dispatch_work" -> dispatch += CloudRouter.parseDispatchSpecs(args)
                    "steer_worker" -> {
                        val id = args["work_item_id"]?.jsonPrimitive?.contentOrNull
                        val instr = args["instruction"]?.jsonPrimitive?.contentOrNull
                        if (!id.isNullOrBlank() && !instr.isNullOrBlank()) steer += RouterSteer(id, instr)
                    }
                    else -> needsFollowup = true
                }
                val out = if (call.toolName in CloudRouter.ROUTER_TOOL_NAMES) {
                    runCatching { registry.executeGate(call.toolName, args, ExecutionScope.MAIN_AGENT).toString() }
                        .getOrElse { "{\"ok\":false}" }
                } else {
                    "{\"ok\":false,\"error\":\"Router 不允许执行该工具\"}"
                }
                call.copy(output = listOf(UIMessagePart.Text(CredentialRedactor.redact(out))))
            }
            if (!needsFollowup) return RouterDecision(reply, dispatch, steer)
            messages += answer.copy(parts = answer.parts.map { part ->
                if (part is UIMessagePart.Tool) executed.firstOrNull { it.toolCallId == part.toolCallId } ?: part else part
            })
        }
        return RouterDecision(reply, dispatch, steer)
    }

    companion object {
        const val DEFAULT_ROUTER_SYSTEM_PROMPT = """你是 Amber 云端本体的 Router。你只负责和主人对话、派单与汇报：
- 需要执行的工作一律用 dispatch_work 派给后台 Worker，不要自己执行；
- 回复简短（不超过 100 词），只在需要主人决策或验收时说明；
- 不要提及工具名、参数、原始返回或你的推理过程。"""
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
    private val maxSteps: Int = 6,
) {
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun run(item: CloudWorkItemRecord, principal: CloudPrincipal.Worker): WorkerSettlementReport {
        val sessionId = item.workerSessionId ?: return WorkerSettlementReport(item.workItemId, "failed", "缺少 Worker 会话")
        val uuid = Uuid.parse(sessionId)
        val tools = toolRegistry.declaredTools(ExecutionScope.SUBAGENT)
        var lastText = ""
        repeat(maxSteps) {
            val history = kernel.conversationStorage.loadConversation(uuid)?.messageNodes?.map { it.currentMessage }.orEmpty()
            val answer = modelClient.generateReply(history, tools)
            val calls = answer.getTools()
            lastText = answer.toText().ifBlank { lastText }
            if (calls.isEmpty()) {
                kernel.appendWorkerMessage(sessionId, sanitize(answer))
                return WorkerSettlementReport(item.workItemId, "completed", CredentialRedactor.redact(lastText.ifBlank { "完成" }))
            }
            val executed = calls.map { call ->
                val current = kernel.store.getWorkItem(item.workItemId) ?: return WorkerSettlementReport(item.workItemId, "failed", "任务记录丢失")
                if (current.state.isTerminal) return WorkerSettlementReport(item.workItemId, "cancelled", "任务已结束")
                runCatching {
                    kernel.updateWorkerProgress(principal, item.workItemId, current.progressRevision, "正在处理第 ${it + 1} 步", call.toolName)
                }
                val args = runCatching { json.parseToJsonElement(call.input.ifBlank { "{}" }).jsonObject }
                    .getOrDefault(JsonObject(emptyMap()))
                val out = runCatching { toolRegistry.executeGate(call.toolName, args, ExecutionScope.SUBAGENT).toString() }
                    .getOrElse { e -> "{\"ok\":false,\"error\":\"${CredentialRedactor.redact(e.message.orEmpty()).replace("\"", "'")}\"}" }
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
