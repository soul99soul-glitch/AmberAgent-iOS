package app.amber.cloud.agents

import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.orchestration.CloudPrincipal
import app.amber.cloud.orchestration.DefaultCloudOrchestrationKernel
import app.amber.cloud.orchestration.ExecutionTargetNode
import app.amber.cloud.orchestration.OrchestrationHash
import app.amber.cloud.orchestration.RouterDecision
import app.amber.cloud.orchestration.RouterTriggerEvent
import app.amber.cloud.orchestration.WorkItemSubmissionSpec
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Only the main Router owns agent selection and translates it into managed WorkItems. */
class AgentRouterCoordinator(
    private val kernel: DefaultCloudOrchestrationKernel,
    private val registry: AgentRegistry,
    private val routing: AgentRouting,
    private val onOwnerMessage: (String, String, String) -> Unit,
) {
    fun splitTurns(events: List<RouterTriggerEvent>): List<List<RouterTriggerEvent>> =
        if (registry.list().size > 1 && events.count { it.kind == "user_message" } > 1) events.map(::listOf) else listOf(events)

    suspend fun plan(events: List<RouterTriggerEvent>, ownerIds: List<String>): RouterDecision? {
        if (events.first().conversationId != PRIMARY_CONVERSATION_ID.toString()) return null
        val humanEvents = events.filter { it.kind == "user_message" }
        if (humanEvents.isEmpty()) return null
        val confirmation = humanEvents.singleOrNull()?.takeIf { it.sourceMessageId in ownerIds }
        if (confirmation != null && confirmation.summaryText.startsWith("确认创建 agent ")) {
            val proposalId = confirmation.summaryText.removePrefix("确认创建 agent ").trim()
            val source = kernel.store.getSourceMessage(confirmation.sourceMessageId!!)!!
            val saved = registry.confirm(CloudPrincipal.OwnerUser(source.senderId, source.channelId), proposalId, source.messageId)
            return RouterDecision(reply = "已创建「${saved.name}」。可以用 @${saved.name} 交给它处理。")
        }
        val prompt = humanEvents.joinToString("\n") { it.summaryText }
        val route = routing.select(prompt)
        kernel.store.appendDiagnosticEvent(
            sessionId = events.first().conversationId, workItemId = null, kind = "agent_routed",
            detail = Json.encodeToString(route), messageId = humanEvents.last().sourceMessageId,
            nowMs = System.currentTimeMillis(),
        )
        humanEvents.filter { it.sourceMessageId in ownerIds }.forEach {
            onOwnerMessage(it.summaryText, it.conversationId, route.agentId)
        }
        if (route.agentId == MAIN_AGENT_ID || ownerIds.isEmpty()) return null
        val profile = registry.get(route.agentId) ?: error("路由目标已不存在")
        return RouterDecision(dispatch = listOf(WorkItemSubmissionSpec(
            taskKey = "agent:" + OrchestrationHash.sha256Hex(humanEvents.joinToString { it.eventId }).take(24),
            title = "${profile.name}处理请求", brief = prompt,
            targetNode = ExecutionTargetNode.CloudSubagent(profile.instructions, profile.modelPreference),
            subscribedThreadKeys = humanEvents.mapNotNull { it.threadId }.distinct(), agentId = profile.id,
        )))
    }

    fun propose(profile: AgentProfile, ownerIds: List<String>): String {
        val proposal = registry.propose(
            CloudPrincipal.CloudCoordinator(activeSessionId = PRIMARY_CONVERSATION_ID.toString(), activeTurnId = "propose"),
            profile, ownerIds,
        )
        val policy = if (profile.memoryPolicy == AgentMemoryPolicy.HUB_ISOLATED) "独立记忆" else "本中心记忆与全局偏好"
        return "建议创建「${proposal.profile.name}」（$policy，工具权限 ${profile.toolScope.size} 项，可在提议详情查看）。如同意，请回复：确认创建 agent ${proposal.id}"
    }
}
