package app.amber.cloud.gateway

import app.amber.ai.core.MessageRole
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.agents.AgentMemoryPolicy
import app.amber.cloud.agents.AgentProfile
import app.amber.cloud.agents.MAIN_AGENT_ID
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.orchestration.ActivityPhase
import app.amber.cloud.orchestration.ActivityStatus
import app.amber.cloud.orchestration.CloudWorkItemRecord
import app.amber.cloud.orchestration.OutwardTextSanitizer
import app.amber.cloud.orchestration.WorkItemState
import app.amber.cloud.runtime.CloudAgentKernel
import kotlinx.serialization.Serializable

@Serializable
data class PublicAgent(val id: String, val name: String, val memoryPolicy: AgentMemoryPolicy, val tags: List<String>, val revision: Int)
@Serializable
data class PublicWorkItem(val id: String, val agentId: String, val title: String, val state: WorkItemState, val progress: String?, val updatedAtMs: Long)
@Serializable
data class AgentActivity(val agentId: String, val activities: List<ActivityStatus>, val workItems: List<PublicWorkItem>)
@Serializable
data class TimelineEntry(val id: String, val role: String, val agentId: String = MAIN_AGENT_ID, val text: String)
@Serializable
data class TimelinePage(val items: List<TimelineEntry>, val nextCursor: String? = null)
@Serializable
data class PublicWorkDetail(val workItem: PublicWorkItem, val brief: String, val failure: String?, val sessionArchived: Boolean, val resultMarkdown: String? = null)

/** Explicit public projections: raw profiles, tool parts, reasoning and session identities never serialize here. */
class AgentCentricApi(val kernel: CloudAgentKernel) {
    val tasks = NativeTaskApi(this)
    private fun safe(text: String): String = OutwardTextSanitizer.sanitize(text, kernel.router.forbiddenToolNames)

    fun publicAgent(profile: AgentProfile) = PublicAgent(profile.id, safe(profile.name), profile.memoryPolicy, profile.tags.map(::safe).filter { it.isNotEmpty() }, profile.revision)
    fun agents() = kernel.agentRegistry.list().map(::publicAgent)
    internal fun publicWork(item: CloudWorkItemRecord) = PublicWorkItem(item.workItemId, item.agentId, safe(item.title), item.state, item.latestProgressNote?.let(::safe), item.updatedAtMs)

    fun activity(id: String): AgentActivity? {
        if (kernel.agentRegistry.get(id) == null) return null
        val items = kernel.orchestrationStore.listWorkItems().filter { it.agentId == id }
            .sortedWith(compareBy<CloudWorkItemRecord> { it.state.isTerminal }.thenByDescending { it.updatedAtMs }).take(100)
        return AgentActivity(id, items.map { item ->
            val phase = when (item.state) {
                WorkItemState.COMPLETED -> ActivityPhase.DONE
                WorkItemState.FAILED, WorkItemState.CANCELLED -> ActivityPhase.FAILED
                WorkItemState.QUEUED, WorkItemState.STARTING -> ActivityPhase.STARTED
                else -> ActivityPhase.PROGRESS
            }
            ActivityStatus(item.workItemId, OutwardTextSanitizer.activityLabel(item.latestProgressNote ?: item.title, kernel.router.forbiddenToolNames), phase, item.updatedAtMs)
        }, items.map(::publicWork))
    }

    fun workItem(id: String): PublicWorkDetail? = kernel.orchestrationStore.getWorkItem(id)?.let {
        // Final output may intentionally contain code/JSON. Activity sanitization would destroy that result.
        val result = if (it.state.isTerminal) it.settlementReportPath?.let(kernel.orchestrationStore::readArchivedDocumentText) else null
        PublicWorkDetail(publicWork(it), safe(it.brief), it.failureReason?.let(::safe), it.state.isTerminal, result)
    }

    suspend fun timeline(before: String? = null, limit: Int = 50): TimelinePage {
        require(limit in 1..100) { "limit 必须在 1..100" }
        val messages = kernel.conversationStorage.loadConversation(PRIMARY_CONVERSATION_ID)?.messageNodes.orEmpty().map { it.currentMessage }
            .filter { it.role == MessageRole.USER || it.role == MessageRole.ASSISTANT }
        val end = if (before == null) messages.size else messages.indexOfFirst { it.id.toString() == before }.also { require(it >= 0) { "无效游标" } }
        val start = (end - limit).coerceAtLeast(0)
        val items = messages.subList(start, end).mapNotNull { message ->
            val text = safe(message.parts.filterIsInstance<UIMessagePart.Text>().joinToString("\n") { it.text })
            if (text.isBlank()) null else TimelineEntry(message.id.toString(), message.role.name.lowercase(), text = text)
        }
        return TimelinePage(items, if (start > 0) messages[start].id.toString() else null)
    }
}
