package app.amber.cloud.agents

import kotlinx.serialization.Serializable

const val MAIN_AGENT_ID = "main"
const val GLOBAL_MEMORY_AGENT_ID = "global"

@Serializable
enum class AgentMemoryPolicy { SHARED_WITH_GLOBAL, HUB_ISOLATED }

@Serializable
enum class HubTemplate { GENERAL, CODING, NOVEL, RESEARCH }

/** The agent is also the topic hub and memory boundary; there is no parallel Hub identity. */
@Serializable
data class AgentProfile(
    val id: String,
    val name: String,
    val instructions: String = "",
    val memoryPolicy: AgentMemoryPolicy = AgentMemoryPolicy.SHARED_WITH_GLOBAL,
    val toolScope: Set<String> = emptySet(),
    val modelPreference: String? = null,
    val tags: List<String> = emptyList(),
    val routingKeywords: List<String> = emptyList(),
    val revision: Int = 0,
    val hubTemplate: HubTemplate = HubTemplate.GENERAL,
)

@Serializable
data class AgentProposal(
    val id: String,
    val profile: AgentProfile,
    val sourceMessageIds: List<String>,
    val createdAtMs: Long,
)

@Serializable
data class AgentRoute(val agentId: String, val method: String, val reason: String)

class AgentRevisionConflict(message: String) : IllegalStateException(message)
