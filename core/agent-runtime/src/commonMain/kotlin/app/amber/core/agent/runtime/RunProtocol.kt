package app.amber.core.agent.runtime

/** Immutable run-level model/capability identity captured when the run starts. */
data class AgentRunProtocolContext(
    val providerId: String?,
    val modelId: String?,
    val promptVersion: String?,
    val toolCatalogVersion: String?,
    val capabilitySnapshot: String?,
)
