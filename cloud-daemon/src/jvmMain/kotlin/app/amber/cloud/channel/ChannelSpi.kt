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
    val metadata: Map<String, String> = emptyMap(),
)

@Serializable
data class ChannelApprovalCard(
    val sessionKey: String,
    val toolCallId: String,
    val toolName: String,
    val redactedDetail: String,
    val highRisk: Boolean,
    val allowApproveInChannel: Boolean = !highRisk,
)

@Serializable
data class OutboundMessage(
    val channel: ChannelKind,
    val chatId: String,
    val threadId: String? = null,
    val replyToMessageId: String? = null,
    val text: String,
    val conversationId: String,
    val markdown: Boolean = true,
    val silent: Boolean = false,
    val approvalCard: ChannelApprovalCard? = null,
    val metadata: Map<String, String> = emptyMap(),
)

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
 * SPI implemented by external channel connectors (Telegram Long Polling, Feishu WebSocket/Webhook, etc.).
 */
interface ChannelConnector {
    val kind: ChannelKind
    fun attachIngress(ingress: ChannelIngress)
    suspend fun start()
    suspend fun stop()
    suspend fun send(message: OutboundMessage): Result<String>
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
