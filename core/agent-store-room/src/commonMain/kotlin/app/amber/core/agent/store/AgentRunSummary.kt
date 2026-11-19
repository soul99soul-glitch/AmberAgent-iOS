package app.amber.core.agent.store

import androidx.room.ColumnInfo

/** Lightweight display data; full recovery state remains in [AgentRunEntity]. */
data class AgentRunSummary(
    @ColumnInfo(name = "run_id") val runId: String,
    @ColumnInfo(name = "agent_descriptor_id") val agentDescriptorId: String,
    @ColumnInfo(name = "conversation_id") val conversationId: String?,
    val status: String,
    @ColumnInfo(name = "started_at") val startedAt: Long,
    @ColumnInfo(name = "finished_at") val finishedAt: Long?,
    @ColumnInfo(name = "interrupted_reason") val interruptedReason: String?,
    @ColumnInfo(name = "terminal_reason") val terminalReason: String?,
)

/** Approval notices retain their token without loading unrelated protocol blobs. */
data class AgentRunNoticeSummary(
    @ColumnInfo(name = "run_id") val runId: String,
    @ColumnInfo(name = "agent_descriptor_id") val agentDescriptorId: String,
    @ColumnInfo(name = "conversation_id") val conversationId: String?,
    val status: String,
    @ColumnInfo(name = "started_at") val startedAt: Long,
    @ColumnInfo(name = "finished_at") val finishedAt: Long?,
    @ColumnInfo(name = "input_snapshot_ref") val inputSnapshotRef: String?,
)
