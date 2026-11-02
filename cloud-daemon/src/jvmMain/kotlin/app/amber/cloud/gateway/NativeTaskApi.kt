package app.amber.cloud.gateway

import app.amber.cloud.agents.MAIN_AGENT_ID
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.orchestration.CloudPrincipal
import app.amber.cloud.orchestration.ExecutionTargetNode
import app.amber.cloud.orchestration.OrchestrationHash
import app.amber.cloud.orchestration.SourceMessageProvenance
import app.amber.cloud.orchestration.WorkItemSubmissionSpec
import app.amber.cloud.security.CredentialRedactor
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
data class NativeTaskRequest(
    val requestId: String,
    val text: String,
    val agentId: String = MAIN_AGENT_ID,
    val title: String = "云端任务",
)

@Serializable
data class NativeTaskReceipt(val workItem: PublicWorkItem, val replayed: Boolean)

class NativeTaskConflict : IllegalStateException("同一设备的 requestId 已用于不同任务")
class NativeTaskAgentMissing : IllegalArgumentException("agent 不存在")

/** Paired devices submit owner tasks through the same provenance ledger and Worker queue as Router. */
class NativeTaskApi(private val api: AgentCentricApi) {
    private val submissions = Mutex()
    private val json = Json { encodeDefaults = true }

    suspend fun submit(device: PairedDevice, request: NativeTaskRequest): NativeTaskReceipt = submissions.withLock {
        require(Regex("[A-Za-z0-9._:-]{1,128}").matches(request.requestId)) { "无效 requestId" }
        require(request.text.isNotBlank() && request.text.length <= 24_000) { "text 必须为 1..24000 字符" }
        require(request.title.isNotBlank() && request.title.length <= 200) { "title 必须为 1..200 字符" }
        val kernel = api.kernel
        val store = kernel.orchestrationStore
        // Namespace by authenticated device. Caller-supplied IDs never select another source or operation.
        val operationId = "c3-task:" + OrchestrationHash.sha256Hex("${device.id}\u0000${request.requestId}")
        val sourceText = json.encodeToString(request)
        val fingerprint = OrchestrationHash.sha256Hex(sourceText)
        val source = store.getSourceMessage(operationId)
        if (source != null && source.rawTextHash != fingerprint) throw NativeTaskConflict()
        store.getOperationResult(operationId)?.let { previous ->
            val item = store.getWorkItem(previous.items.single().workItemId) ?: error("任务记录不可用")
            return@withLock NativeTaskReceipt(api.publicWork(item), replayed = true)
        }
        if (kernel.agentRegistry.get(request.agentId) == null) throw NativeTaskAgentMissing()
        val now = System.currentTimeMillis()
        if (source == null) store.recordSourceMessage(SourceMessageProvenance(
            sessionId = PRIMARY_CONVERSATION_ID.toString(), messageId = operationId,
            senderId = device.id, channelId = "c3", rawTextHash = fingerprint, createdAtEpochMs = now,
        ), sourceText)
        val result = kernel.orchestrationKernel.submitWorkBatch(
            principal = CloudPrincipal.OwnerUser(device.id, "c3"), requestId = operationId,
            contextMessageIds = listOf(operationId), items = listOf(WorkItemSubmissionSpec(
                taskKey = operationId, title = CredentialRedactor.redact(request.title), brief = request.text,
                targetNode = ExecutionTargetNode.CloudSubagent(rolePrompt = ""), agentId = request.agentId,
            )), nowEpochMs = now,
        )
        val item = result.items.single()
        return@withLock NativeTaskReceipt(api.publicWork(item), item.workItemId in result.replayedWorkItemIds)
    }
}
