package app.amber.cloud.channel

import app.amber.core.native.AmberNativeBridge
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlin.uuid.Uuid

/**
 * Global primary timeline UUID shared across all direct (1-on-1) entry points
 * (Telegram DM, Feishu DM, native App default chat, CLI direct chat).
 */
val PRIMARY_CONVERSATION_ID: Uuid = Uuid.parse("00000000-0000-4000-8000-000000000001")

@Serializable
enum class ChannelKind(val wireName: String) {
    @SerialName("telegram")
    TELEGRAM("telegram"),

    @SerialName("feishu")
    FEISHU("feishu"),

    @SerialName("app")
    APP("app"),

    @SerialName("cli")
    CLI("cli"),

    @SerialName("custom")
    CUSTOM("custom"),
    ;

    companion object {
        fun fromWireName(wireName: String): ChannelKind =
            entries.firstOrNull { it.wireName.equals(wireName.trim(), ignoreCase = true) } ?: CUSTOM
    }
}

@Serializable
enum class ConversationScope {
    /** All private/direct entry points share [PRIMARY_CONVERSATION_ID]. */
    @SerialName("direct")
    DIRECT,

    /** Group chats or forum topics get an isolated thread per group/topic. */
    @SerialName("group")
    GROUP,

    /** Dedicated background/scheduled tasks get an isolated thread. */
    @SerialName("task")
    TASK,
}

/**
 * Unified C3 v2 sender role matrix.
 * In IM channels, even [OWNER] can only deny tool approvals; approving requires a paired,
 * unlocked native App in the foreground after biometric verification.
 */
@Serializable
enum class SenderRole {
    @SerialName("owner")
    OWNER,

    @SerialName("collaborator")
    COLLABORATOR,

    @SerialName("guest")
    GUEST,
}

@Serializable
enum class ButtonStyle {
    DEFAULT,
    PRIMARY,
    DANGER,
}

@Serializable
data class OutboundButton(
    val text: String,
    val actionData: String,
    val style: ButtonStyle = ButtonStyle.DEFAULT,
)

/**
 * Structured card for Feishu interactive cards and Telegram inline keyboards.
 *
 * Security rule: When associated with an approval ([approvalToolCallId] != null),
 * IM channels ONLY render the "Deny" button and strip any "Approve" button.
 */
@Serializable
data class OutboundCard(
    val title: String,
    val markdownBody: String,
    val headerTemplate: String = "wathet",
    val buttons: List<OutboundButton> = emptyList(),
    val approvalToolCallId: String? = null,
    val highRisk: Boolean = true,
)

/**
 * Parsed IM callback approval decision.
 *
 * C3 v2 boundary: IM callbacks can ONLY produce [allow] = false ("DENIED").
 * Any forged `approve` or `allow=true` callback is intercepted with [coercedFromApproveAttempt] = true.
 */
@Serializable
data class ImApprovalDecision(
    val toolCallId: String,
    val allow: Boolean = false,
    val decision: String = "DENIED",
    val coercedFromApproveAttempt: Boolean = false,
    val reason: String,
    val sessionKey: String? = null,
)

/**
 * Untrusted inbound text sandbox wrapper (Prompt Injection Defense / Taint Tracking).
 */
object TaintSandbox {
    fun wrap(
        rawText: String,
        source: String,
        senderId: String,
        senderRole: SenderRole,
    ): String {
        val safeSource = escapeAttr(source)
        val safeSender = escapeAttr(senderId)
        val safeRole = senderRole.name.lowercase()
        val escapedBody = rawText
            .replace("</untrusted_input>", "&lt;/untrusted_input&gt;", ignoreCase = true)
            .replace("<untrusted_input", "&lt;untrusted_input", ignoreCase = true)
        return buildString {
            append("<untrusted_input source=\"")
            append(safeSource)
            append("\" sender_id=\"")
            append(safeSender)
            append("\" sender_role=\"")
            append(safeRole)
            append("\">\n")
            append(escapedBody)
            append("\n</untrusted_input>")
        }
    }

    private fun escapeAttr(input: String): String =
        input
            .replace("&", "&amp;")
            .replace("\"", "&quot;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
}

@Serializable
data class ChannelAttachment(
    val kind: String,
    val url: String,
    val fileName: String? = null,
    val mimeType: String? = null,
)

@Serializable
data class InboundMessage(
    val messageId: String,
    val channel: ChannelKind,
    val chatId: String,
    val threadId: String? = null,
    val senderId: String,
    val senderName: String? = null,
    val senderRole: SenderRole = SenderRole.OWNER,
    val scope: ConversationScope = ConversationScope.DIRECT,
    val text: String,
    val isExplicitMention: Boolean = false,
    val replyToMessageId: String? = null,
    val attachments: List<ChannelAttachment> = emptyList(),
    val receivedAtEpochSeconds: Long = System.currentTimeMillis() / 1000L,
    val tainted: Boolean = true,
    val sandboxedText: String = TaintSandbox.wrap(
        rawText = text,
        source = "${channel.wireName}:${scope.name.lowercase()}:$chatId",
        senderId = senderId,
        senderRole = senderRole,
    ),
    val callbackData: String? = null,
    val approvalDecision: ImApprovalDecision? = null,
    val metadata: Map<String, String> = emptyMap(),
) {
    val id: String
        get() = messageId

    val channelId: String
        get() = channel.wireName
}

@Serializable
data class ChannelApprovalCard(
    val sessionKey: String,
    val toolCallId: String,
    val toolName: String,
    val redactedDetail: String,
    val highRisk: Boolean,
    /**
     * C3 v2 rule: IM channels (including OWNER) can ONLY deny, never approve.
     */
    val allowApproveInChannel: Boolean = false,
)

@Serializable
data class OutboundReceipt(
    val ok: Boolean,
    val channelId: String,
    val messageId: String,
    val replayed: Boolean = false,
    val note: String? = null,
)

@Serializable
data class OutboundMessage(
    val channel: ChannelKind = ChannelKind.CUSTOM,
    val chatId: String,
    val threadId: String? = null,
    val replyToMessageId: String? = null,
    val text: String = "",
    val conversationId: String = PRIMARY_CONVERSATION_ID.toString(),
    val markdown: Boolean = true,
    val silent: Boolean = false,
    val approvalCard: ChannelApprovalCard? = null,
    val card: OutboundCard? = null,
    val idempotencyKey: String? = null,
    val metadata: Map<String, String> = emptyMap(),
) {
    fun effectiveCard(): OutboundCard? {
        if (card != null) return card
        val approval = approvalCard ?: return null
        return OutboundCard(
            title = if (approval.highRisk) "高风险工具待确认 · ${approval.toolName}" else "工具待确认 · ${approval.toolName}",
            markdownBody = buildString {
                if (text.isNotBlank()) {
                    append(text.trim()).append("\n\n")
                }
                append("参数摘要：`").append(approval.redactedDetail).append("`")
            },
            headerTemplate = if (approval.highRisk) "amber" else "wathet",
            buttons = listOf(
                OutboundButton(
                    text = "❌ 拒绝此次操作",
                    actionData = "im_approval:deny:${approval.toolCallId}",
                    style = ButtonStyle.DANGER,
                )
            ),
            approvalToolCallId = approval.toolCallId,
            highRisk = approval.highRisk,
        )
    }
}

@Serializable
data class ChannelDecisionOutcome(
    val httpStatus: Int,
    val outcome: String,
    val error: String? = null,
)

/**
 * Implemented by the `amberd` kernel to consume messages and approval callbacks
 * from external IM channels (Telegram, Feishu, etc.).
 */
interface ChannelIngress {
    suspend fun handleInbound(message: InboundMessage): OutboundMessage

    suspend fun handleChannelDecision(
        channel: ChannelKind,
        senderId: String,
        sessionKey: String,
        toolCallId: String,
        allow: Boolean,
    ): ChannelDecisionOutcome
}

/**
 * Unified SPI implemented by external channel connectors (Telegram Long Polling, Feishu Webhook/OpenAPI, etc.).
 */
interface ChannelConnector {
    val kind: ChannelKind
    fun attachIngress(ingress: ChannelIngress)
    suspend fun start()
    suspend fun stop()
    suspend fun send(message: OutboundMessage): Result<String>

    suspend fun sendWithReceipt(message: OutboundMessage): OutboundReceipt {
        val res = send(message)
        return OutboundReceipt(
            ok = res.isSuccess,
            channelId = kind.wireName,
            messageId = res.getOrDefault(""),
            note = res.exceptionOrNull()?.message,
        )
    }
}

/**
 * Resolves the target conversation UUID for an [InboundMessage]:
 * - [ConversationScope.DIRECT] -> always [PRIMARY_CONVERSATION_ID] (shared primary timeline).
 * - [ConversationScope.GROUP] / [ConversationScope.TASK] -> deterministic UUID derived from
 *   `(scope, channel, chatId, threadId)`.
 */
fun resolveConversationId(message: InboundMessage): Uuid {
    if (message.scope == ConversationScope.DIRECT) {
        return PRIMARY_CONVERSATION_ID
    }
    val seed = "${message.scope.name.lowercase()}:${message.channel.wireName}:${message.chatId}:${message.threadId.orEmpty()}"
    val hash = AmberNativeBridge.sha256(seed.encodeToByteArray())
        ?: error("SHA-256 unavailable on JVM")
    val bytes = hash.copyOfRange(0, 16)
    // Set version 5 (name-based) and IETF variant bits
    bytes[6] = ((bytes[6].toInt() and 0x0f) or 0x50).toByte()
    bytes[8] = ((bytes[8].toInt() and 0x3f) or 0x80).toByte()
    return Uuid.fromByteArray(bytes)
}
