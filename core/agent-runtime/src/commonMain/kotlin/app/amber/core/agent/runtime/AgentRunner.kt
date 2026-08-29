package app.amber.core.agent.runtime

import kotlinx.coroutines.flow.StateFlow

interface AgentRunner {
    fun <I : AgentInput> launch(
        descriptorId: AgentDescriptorId,
        input: I,
    ): Result<AgentRunHandle>

    fun observe(runId: AgentRunId): StateFlow<AgentRunSnapshot>
    fun cancel(runId: AgentRunId)
    suspend fun listUnfinishedRuns(): List<AgentRunSnapshot>
}

data class AgentRunHandle(
    val runId: AgentRunId,
    val descriptorId: AgentDescriptorId,
)

data class AgentRunSnapshot(
    val runId: AgentRunId,
    val parentRunId: AgentRunId?,
    val descriptorId: AgentDescriptorId,
    val status: AgentRunStatus,
    val startedAt: Long,
    val finishedAt: Long?,
    val terminalReason: String? = null,
    val protocolContext: AgentRunProtocolContext? = null,
)

enum class AgentRunStatus(
    val wireName: String,
    val isTerminal: Boolean,
    val isRecoverable: Boolean,
) {
    CREATED("created", isTerminal = false, isRecoverable = true),
    RUNNING("running", isTerminal = false, isRecoverable = true),
    /** Canonical WAITING_USER state; the enum name is retained for Swift source compatibility. */
    AWAITING_PERMISSION("waiting_user", isTerminal = false, isRecoverable = true),
    WAITING_EXTERNAL("waiting_external", isTerminal = false, isRecoverable = true),
    /** Canonical RESUMABLE state; the enum name is retained for Swift source compatibility. */
    RECOVERY_PENDING("resumable", isTerminal = false, isRecoverable = true),
    OUTCOME_UNKNOWN("outcome_unknown", isTerminal = false, isRecoverable = true),
    COMPLETED("completed", isTerminal = true, isRecoverable = false),
    FAILED("failed", isTerminal = true, isRecoverable = false),
    INTERRUPTED("interrupted", isTerminal = true, isRecoverable = false),
    CANCELLED("cancelled", isTerminal = true, isRecoverable = false),
    ;

    fun canTransitionTo(next: AgentRunStatus): Boolean = when (this) {
        CREATED -> next in setOf(
            RUNNING,
            FAILED,
            INTERRUPTED,
            CANCELLED,
        )
        RUNNING -> next in setOf(
            AWAITING_PERMISSION,
            WAITING_EXTERNAL,
            RECOVERY_PENDING,
            OUTCOME_UNKNOWN,
            COMPLETED,
            FAILED,
            INTERRUPTED,
            CANCELLED,
        )
        AWAITING_PERMISSION -> next in setOf(
            RUNNING,
            WAITING_EXTERNAL,
            RECOVERY_PENDING,
            OUTCOME_UNKNOWN,
            FAILED,
            INTERRUPTED,
            CANCELLED,
        )
        WAITING_EXTERNAL -> next in setOf(
            RUNNING,
            AWAITING_PERMISSION,
            RECOVERY_PENDING,
            OUTCOME_UNKNOWN,
            FAILED,
            INTERRUPTED,
            CANCELLED,
        )
        RECOVERY_PENDING -> next in setOf(
            RUNNING,
            AWAITING_PERMISSION,
            WAITING_EXTERNAL,
            OUTCOME_UNKNOWN,
            FAILED,
            INTERRUPTED,
            CANCELLED,
        )
        OUTCOME_UNKNOWN -> next in setOf(
            RUNNING,
            AWAITING_PERMISSION,
            COMPLETED,
            FAILED,
            INTERRUPTED,
            CANCELLED,
        )
        COMPLETED,
        FAILED,
        INTERRUPTED,
        CANCELLED,
        -> false
    }

    companion object {
        /**
         * Decodes persisted wire values. Historical domain-specific terminal
         * values are failed runs; unknown values also fail closed instead of
         * being presented as an interrupted/recoverable run.
         */
        fun fromWireName(value: String): AgentRunStatus = when (value.lowercase()) {
            CREATED.wireName -> CREATED
            RUNNING.wireName -> RUNNING
            AWAITING_PERMISSION.wireName, "awaiting_permission" -> AWAITING_PERMISSION
            WAITING_EXTERNAL.wireName -> WAITING_EXTERNAL
            RECOVERY_PENDING.wireName, "recovery_pending" -> RECOVERY_PENDING
            OUTCOME_UNKNOWN.wireName -> OUTCOME_UNKNOWN
            COMPLETED.wireName -> COMPLETED
            FAILED.wireName, "truncated", "guard_stopped" -> FAILED
            INTERRUPTED.wireName -> INTERRUPTED
            CANCELLED.wireName -> CANCELLED
            else -> FAILED
        }
    }
}
