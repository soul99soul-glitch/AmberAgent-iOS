package app.amber.cloud.runtime

import app.amber.ai.ui.ToolApprovalState
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.gateway.CloudGatewayState
import app.amber.cloud.gateway.PendingApprovalDto
import app.amber.cloud.gateway.SessionDto
import app.amber.cloud.orchestration.OrchestrationHash
import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.EnvelopeCredentialVault
import app.amber.core.storage.conversation.JsonConversationStorage
import kotlinx.serialization.json.JsonObject
import java.util.concurrent.ConcurrentHashMap
import kotlin.uuid.Uuid

/**
 * Shared approval/vault/card/tool-part helper used by both V1 (`handleInbound`)
 * and V2 (`ModelWorkerTurnRunner` / `DefaultCloudOrchestrationKernel`).
 */
internal class ToolApprovalHelper(
    private val vault: EnvelopeCredentialVault?,
    private val gatewayState: CloudGatewayState?,
    private val conversationStorage: JsonConversationStorage,
) {
    private val fallbackStash = ConcurrentHashMap<String, JsonObject>()

    fun stashPendingToolArgs(toolCallId: String, rawArgs: JsonObject): String {
        if (vault != null) {
            return vault.stashPendingToolArgs(toolCallId, rawArgs)
        }
        fallbackStash[toolCallId] = rawArgs
        return CredentialRedactor.redact(rawArgs.toString())
    }

    fun consumePendingToolArgs(toolCallId: String): JsonObject? {
        return vault?.consumePendingToolArgs(toolCallId) ?: fallbackStash.remove(toolCallId)
    }

    fun wipePendingToolArgs(toolCallId: String) {
        vault?.wipePendingToolArgs(toolCallId)
        fallbackStash.remove(toolCallId)
    }

    fun argsDigest(rawArgs: JsonObject): String = OrchestrationHash.sha256Hex(rawArgs.toString())

    fun upsertPendingApprovalSession(
        sessionKey: String,
        agent: String = "amber",
        subject: String,
        summary: String,
        origin: String,
        conversationId: String,
        toolCallId: String,
        toolName: String,
        redactedArgsJson: String,
        highRisk: Boolean,
        nowSec: Double = CloudGatewayState.nowEpochSeconds(),
        riskLevel: String? = null,
        targetDevice: String? = null,
        targetSummary: String? = null,
        diffPreview: String? = null,
        requiresLocalApproval: Boolean? = null,
    ) {
        val gw = gatewayState ?: return
        gw.upsertSession(
            SessionDto(
                key = sessionKey,
                agent = agent,
                subject = subject,
                summary = summary,
                origin = origin,
                state = "waiting",
                waitReason = "permission",
                updatedAt = nowSec,
                conversationId = conversationId,
                pendingApproval = PendingApprovalDto(
                    toolCallId = toolCallId,
                    tool = toolName,
                    detail = CredentialRedactor.redact(redactedArgsJson),
                    highRisk = highRisk,
                    riskLevel = riskLevel,
                    targetDevice = targetDevice,
                    targetSummary = targetSummary?.let(CredentialRedactor::redact),
                    diffPreview = diffPreview?.let(CredentialRedactor::redact),
                    requiresLocalApproval = requiresLocalApproval,
                ),
            )
        )
    }

    fun clearApprovalSession(
        sessionKey: String,
        nextState: String = "completed",
        abnormal: Boolean? = null,
        nowSec: Double = CloudGatewayState.nowEpochSeconds(),
    ) {
        val gw = gatewayState ?: return
        gw.getSession(sessionKey)?.let { existing ->
            gw.upsertSession(
                existing.copy(
                    state = nextState,
                    waitReason = null,
                    abnormal = abnormal ?: existing.abnormal,
                    pendingApproval = null,
                    updatedAt = nowSec,
                )
            )
        }
    }

    suspend fun updateStoredToolOutcome(
        conversationId: Uuid,
        toolCallId: String,
        approvalState: ToolApprovalState,
        outputJson: String,
    ) {
        val conv = conversationStorage.loadConversation(conversationId) ?: return
        val safeOutput = CredentialRedactor.redact(outputJson)
        val updatedNodes = conv.messageNodes.map { node ->
            val msg = node.currentMessage
            val updatedParts = msg.parts.map { part ->
                if (part is UIMessagePart.Tool && part.toolCallId == toolCallId) {
                    part.copy(
                        input = CredentialRedactor.redact(part.input),
                        approvalState = approvalState,
                        output = listOf(UIMessagePart.Text(safeOutput)),
                    )
                } else {
                    part
                }
            }
            if (updatedParts != msg.parts) {
                node.copy(
                    messages = node.messages.toMutableList().also {
                        it[node.selectIndex] = msg.copy(parts = updatedParts)
                    }
                )
            } else {
                node
            }
        }
        if (updatedNodes != conv.messageNodes) {
            conversationStorage.saveConversation(
                conv.copy(
                    messageNodes = updatedNodes,
                    updateAt = kotlin.time.Clock.System.now(),
                )
            )
        }
    }
}
