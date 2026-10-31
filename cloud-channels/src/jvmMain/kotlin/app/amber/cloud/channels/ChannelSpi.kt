package app.amber.cloud.channels

import kotlinx.serialization.Serializable

/**
 * 通道消息来源的会话类型。
 */
@Serializable
enum class ChatType {
    DIRECT,
    GROUP,
}

/**
 * 发送者角色（三级权限矩阵 + 未绑定态）。
 * 群聊与私聊默认只响应 [OWNER]；非主人消息将被门禁拦截。
 */
@Serializable
enum class SenderRole {
    OWNER,
    COLLABORATOR,
    GUEST,
    UNBOUND,
}

/**
 * 按钮视觉样式。
 */
@Serializable
enum class ButtonStyle {
    DEFAULT,
    PRIMARY,
    DANGER,
}

/**
 * 出站内联按钮定义。
 */
@Serializable
data class OutboundButton(
    val text: String,
    val actionData: String,
    val style: ButtonStyle = ButtonStyle.DEFAULT,
)

/**
 * 出站结构化卡片（用于飞书交互式卡片与 Telegram Inline Keyboard 消息）。
 *
 * 安全约束：当卡片关联审批（[approvalToolCallId] 非空）时，通道实现强制只渲染「拒绝」按钮，
 * 绝不在 IM 中下发批准按钮（高风险与审批操作只能在已配对授信客户端前台批准，IM 内仅允许拒绝）。
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
 * IM 卡片按钮点击后的审批解析结果。
 *
 * 强制安全边界：IM 通道内的审批交互永远只能产生 [allow] = false（拒绝）。
 * 任何试图传入 `allow=true` 或点击批准的回调均被拦截并强制转化为拒绝结果。
 */
@Serializable
data class ImApprovalDecision(
    val toolCallId: String,
    val allow: Boolean = false,
    val decision: String = "DENIED",
    val coercedFromApproveAttempt: Boolean = false,
    val reason: String,
)

/**
 * 入站消息统一模型（SPI）。
 *
 * 安全设计：
 * - [tainted] 默认恒为 `true`，表示来自外部 IM 通道的内容不可信，用于防提示词注入（Taint Tracking）。
 * - [sandboxedText] 将原始文本包裹在 `<untrusted_input>` 沙箱标签中，并转义内部闭合标签。
 */
@Serializable
data class InboundMessage(
    val id: String,
    val channelId: String,
    val chatId: String,
    val chatType: ChatType,
    val senderId: String,
    val senderRole: SenderRole = SenderRole.UNBOUND,
    val text: String,
    val tainted: Boolean = true,
    val sandboxedText: String = TaintSandbox.wrap(
        rawText = text,
        source = "$channelId:${chatType.name.lowercase()}:$chatId",
        senderId = senderId,
        senderRole = senderRole,
    ),
    val timestampEpochMs: Long,
    val threadId: String? = null,
    val callbackData: String? = null,
    val approvalDecision: ImApprovalDecision? = null,
    val metadata: Map<String, String> = emptyMap(),
)

/**
 * 出站消息统一模型（SPI）。
 */
@Serializable
data class OutboundMessage(
    val chatId: String,
    val text: String = "",
    val card: OutboundCard? = null,
    val replyToMessageId: String? = null,
    val idempotencyKey: String? = null,
    val silent: Boolean = false,
)

/**
 * 出站发送或流式编辑回执。
 */
@Serializable
data class OutboundReceipt(
    val ok: Boolean,
    val channelId: String,
    val messageId: String,
    val replayed: Boolean = false,
    val note: String? = null,
)

/**
 * Amber 云端本体 IM 通道最小 SPI（供 `:cloud-daemon` 对齐接入）。
 */
interface Channel {
    val id: String

    /**
     * 启动通道监听（如 Telegram Long Polling），通过 [onInbound] 回调已通过主人校验与去重的入站消息。
     */
    suspend fun start(onInbound: suspend (InboundMessage) -> Unit)

    /**
     * 停止通道监听。
     */
    suspend fun stop()

    /**
     * 发送出站文本或交互卡片消息（支持基于 `idempotencyKey` 的幂等防重发）。
     */
    suspend fun send(message: OutboundMessage): OutboundReceipt

    /**
     * 流式更新已发出的消息或卡片正文。
     */
    suspend fun editStreamMessage(
        chatId: String,
        messageId: String,
        newText: String,
        card: OutboundCard? = null,
    ): OutboundReceipt
}
