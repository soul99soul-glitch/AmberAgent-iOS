package app.amber.cloud.supertags

import app.amber.cloud.agents.AgentMemoryPolicy
import app.amber.cloud.agents.AgentProfile
import app.amber.cloud.agents.AgentRegistry
import app.amber.cloud.agents.GLOBAL_MEMORY_AGENT_ID
import app.amber.cloud.agents.HubTemplate
import app.amber.cloud.agents.MAIN_AGENT_ID
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.orchestration.CloudPrincipal
import app.amber.cloud.runtime.CloudMemoryStore
import kotlinx.serialization.Serializable

@Serializable
data class HubSettings(
    val id: String,
    val name: String,
    val instructions: String = "",
    val memoryPolicy: AgentMemoryPolicy = AgentMemoryPolicy.SHARED_WITH_GLOBAL,
    val template: HubTemplate = HubTemplate.GENERAL,
    val tags: List<String> = emptyList(),
    val routingKeywords: List<String> = emptyList(),
    val revision: Int = 0,
)

/** A hub is an AgentProfile projection, not another identity or memory-policy implementation. */
class HubService(
    private val agents: AgentRegistry,
    private val store: SupertagStore,
    private val memory: CloudMemoryStore,
) {
    fun list(): List<HubSettings> = agents.list().filter { it.id != MAIN_AGENT_ID }.map(::settings)
    fun get(id: String): HubSettings = agents.get(id)?.takeIf { id != MAIN_AGENT_ID }?.let(::settings) ?: throw SupertagNotFound("中心不存在")

    fun save(owner: CloudPrincipal.OwnerUser, hub: HubSettings, expectedRevision: Int): HubSettings {
        val current = agents.get(hub.id)
        val profile = (current ?: AgentProfile(hub.id, hub.name)).copy(
            name = hub.name, instructions = hub.instructions, memoryPolicy = hub.memoryPolicy,
            hubTemplate = hub.template, tags = hub.tags, routingKeywords = hub.routingKeywords,
        )
        return settings(agents.save(owner, profile, expectedRevision))
    }

    fun focus(id: String?) {
        if (id != null) get(id)
        store.focus(PRIMARY_CONVERSATION_ID.toString(), id)
    }

    fun scope(hubId: String?): String {
        if (hubId == null) return GLOBAL_MEMORY_AGENT_ID
        get(hubId)
        return hubId
    }

    fun confirm(owner: CloudPrincipal.OwnerUser, id: String, nowMs: Long): HubPromotion = store.confirmPromotion(id, { promotion ->
        val hubId = "hub-${promotion.id}"
        val policy = if (promotion.scopeId == GLOBAL_MEMORY_AGENT_ID) AgentMemoryPolicy.SHARED_WITH_GLOBAL else get(promotion.scopeId).memoryPolicy
        if (agents.get(hubId) == null) agents.save(owner, AgentProfile(hubId, promotion.tag, memoryPolicy = policy, tags = listOf(promotion.tag)), 0)
        // Both stores use durable IDs. A retry after an interrupted migration is safe and does not re-edit the profile.
        memory.moveConversationMemories(promotion.conversationIds.filter { it != PRIMARY_CONVERSATION_ID.toString() }.toSet(), promotion.scopeId, hubId)
        hubId
    }, nowMs)

    private fun settings(profile: AgentProfile) = HubSettings(profile.id, profile.name, profile.instructions, profile.memoryPolicy, profile.hubTemplate, profile.tags, profile.routingKeywords, profile.revision)
}
