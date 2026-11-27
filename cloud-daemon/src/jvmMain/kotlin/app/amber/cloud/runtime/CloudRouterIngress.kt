package app.amber.cloud.runtime

import app.amber.ai.ui.UIMessage
import app.amber.cloud.channel.ChannelIngress
import app.amber.cloud.channel.ConversationScope
import app.amber.cloud.channel.InboundMessage
import app.amber.cloud.channel.OutboundMessage
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.channel.resolveConversationId
import app.amber.cloud.orchestration.imMessageIdentity
import app.amber.cloud.orchestration.ModelRouterBrain
import app.amber.cloud.orchestration.RouterTurnInput
import app.amber.cloud.proactive.ProactiveFeedbackAction
import app.amber.cloud.security.CredentialRedactor
import app.amber.core.model.Conversation
import app.amber.core.model.ConversationMemoryMode
import app.amber.core.model.DEFAULT_ASSISTANT_ID
import app.amber.core.model.MemoryScope
import app.amber.core.model.toMessageNode
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.time.Clock
import kotlin.uuid.Uuid

/** Channel entry point: persist input, acknowledge once, and let the Router run in the background. */
internal class CloudRouterIngress(private val kernel: CloudAgentKernel) : ChannelIngress by kernel {
    private val conversationMutex = Mutex()

    companion object {
        private val PROACTIVE_CALLBACK_REGEX = Regex("^pa:(act|snooze|mute):([A-Za-z0-9_-]{1,48})$")
        private const val EXPIRED_CARD_REPLY = "该卡片已过期，请在 App 中处理"
    }

    override suspend fun handleInbound(message: InboundMessage): OutboundMessage {
        val rawCallback = message.callbackData?.trim()?.takeIf { it.isNotEmpty() }
        val effectiveMessage = if (rawCallback != null) {
            when (val handled = interceptProactiveCallback(message, rawCallback)) {
                is ProactiveCallbackDisposition.Handled -> return handled.reply
                is ProactiveCallbackDisposition.ReenterAsOwnerMessage -> handled.rewrittenMessage
                ProactiveCallbackDisposition.PassThrough -> message
            }
        } else {
            message
        }
        return processNormalInbound(effectiveMessage)
    }

    private sealed interface ProactiveCallbackDisposition {
        data class Handled(val reply: OutboundMessage) : ProactiveCallbackDisposition
        data class ReenterAsOwnerMessage(val rewrittenMessage: InboundMessage) : ProactiveCallbackDisposition
        data object PassThrough : ProactiveCallbackDisposition
    }

    private fun interceptProactiveCallback(
        message: InboundMessage,
        rawCallback: String,
    ): ProactiveCallbackDisposition {
        val isOwnerDirect = message.scope == ConversationScope.DIRECT && message.senderRole == SenderRole.OWNER

        if (rawCallback.startsWith("proactive:")) {
            val replyText = if (isOwnerDirect) EXPIRED_CARD_REPLY else ""
            return ProactiveCallbackDisposition.Handled(response(message, replyText))
        }

        if (!rawCallback.startsWith("pa:")) {
            return ProactiveCallbackDisposition.PassThrough
        }

        if (!isOwnerDirect) {
            return ProactiveCallbackDisposition.Handled(response(message, ""))
        }

        val match = PROACTIVE_CALLBACK_REGEX.matchEntire(rawCallback)
            ?: return ProactiveCallbackDisposition.Handled(response(message, EXPIRED_CARD_REPLY))

        val verb = match.groupValues[1]
        val signalId = match.groupValues[2]

        return when (verb) {
            "snooze" -> {
                val res = try {
                    kernel.applyProactiveFeedback(
                        signalId = signalId,
                        action = ProactiveFeedbackAction.SNOOZE,
                        snoozeMinutes = 60,
                    )
                } catch (e: IllegalArgumentException) {
                    return ProactiveCallbackDisposition.Handled(response(message, e.message ?: "暂时无法安排提醒"))
                }
                val replyText = when (res) {
                    CloudAgentKernel.ProactiveFeedbackResult.SignalNotFound -> EXPIRED_CARD_REPLY
                    is CloudAgentKernel.ProactiveFeedbackResult.Applied ->
                        if (res.applied) "好的，1 小时后再提醒你。" else "这张卡片的延后操作已处理。"
                }
                ProactiveCallbackDisposition.Handled(response(message, replyText))
            }
            "mute" -> {
                val res = kernel.applyProactiveFeedback(
                    signalId = signalId,
                    action = ProactiveFeedbackAction.MUTE_TOPIC,
                    muteHours = 168,
                )
                val replyText = when (res) {
                    CloudAgentKernel.ProactiveFeedbackResult.SignalNotFound -> EXPIRED_CARD_REPLY
                    is CloudAgentKernel.ProactiveFeedbackResult.Applied ->
                        if (res.applied) "好的，已静音该类话题 7 天，可在主动中心恢复。" else "该类话题已处于静音状态。"
                }
                ProactiveCallbackDisposition.Handled(response(message, replyText))
            }
            "act" -> {
                val event = kernel.orchestrationStore.dialogue.findEvent("proactive:$signalId")
                    ?: return ProactiveCallbackDisposition.Handled(response(message, EXPIRED_CARD_REPLY))
                kernel.applyProactiveFeedback(
                    signalId = signalId,
                    action = ProactiveFeedbackAction.REPLIED,
                )
                val actPrompt = kernel.buildProactiveActPrompt(event)
                ProactiveCallbackDisposition.ReenterAsOwnerMessage(
                    message.copy(text = actPrompt, callbackData = null)
                )
            }
            else -> ProactiveCallbackDisposition.Handled(response(message, EXPIRED_CARD_REPLY))
        }
    }

    private suspend fun processNormalInbound(message: InboundMessage): OutboundMessage {
        val conversationId = resolveConversationId(message)
        if (message.scope == ConversationScope.GROUP && message.senderRole == SenderRole.GUEST) {
            return response(message, "当前群聊仅响应已绑定的主人或授权协作者。")
        }
        kernel.interruptWaitingRunsForConversation(conversationId)
        conversationMutex.withLock {
            val conversation = kernel.conversationStorage.loadConversation(conversationId)
                ?: Conversation(
                    id = conversationId, assistantId = DEFAULT_ASSISTANT_ID,
                    title = if (conversationId == PRIMARY_CONVERSATION_ID) "主时间线" else "会话-${message.chatId}",
                    messageNodes = emptyList(),
                )
            if (message.scope == ConversationScope.DIRECT && message.senderRole == SenderRole.OWNER) {
                kernel.ownerBinding.bindOwnerDirectly(message.channel.wireName, message.senderId, message.chatId)
            }
            val userMessage = UIMessage.user(CredentialRedactor.redact(message.text)).let {
                val explicitId = message.metadata["native_event_id"]?.let { id -> Uuid.parse(id) }
                if (explicitId != null) {
                    it.copy(id = explicitId)
                } else {
                    val deterministic = java.util.UUID.nameUUIDFromBytes(
                        imMessageIdentity(message.channel, message.chatId, message.messageId).toByteArray()
                    )
                    it.copy(id = Uuid.parse(deterministic.toString()))
                }
            }
            val alreadyRecorded = conversation.messageNodes.any { it.currentMessage.id == userMessage.id }
            if (!alreadyRecorded && conversation.memoryMode == ConversationMemoryMode.ENABLED &&
                message.scope == ConversationScope.DIRECT && message.senderRole == SenderRole.OWNER
            ) {
                runCatching {
                    val ruleConversation = kernel.orchestrationStore.dialogue.ruleConversationId(
                        message.channel.wireName, message.messageId, conversationId.toString())
                    kernel.proceduralRuleStore.proposeFromCorrection(
                        userText = message.text,
                        scope = "conversation:$ruleConversation",
                        sourceEventId = userMessage.id.toString(),
                    )
                }
            }
            kernel.conversationStorage.saveConversation(conversation.copy(
                messageNodes = if (alreadyRecorded) conversation.messageNodes else conversation.messageNodes + userMessage.toMessageNode(),
                updateAt = Clock.System.now(),
            ))
        }
        message.metadata["native_event_id"]?.let { kernel.nativeDialogue.watchFeedback(it) }
        // The connector sends the returned acknowledgement; Router only sends subsequent replies/status.
        val ack = kernel.router.onInbound(message, postAck = false, sessionId = conversationId.toString())
        return response(message, ack.text)
    }

    suspend fun contextMessages(input: RouterTurnInput): List<UIMessage> = conversationMutex.withLock {
        val conversationId = Uuid.parse(input.events.first().conversationId)
        val conversation = kernel.conversationStorage.loadConversation(conversationId) ?: return@withLock emptyList()
        val fullHistory = conversation.messageNodes.map { it.currentMessage }
        // Concurrent native turns each see history through their own input, never a newer user's request.
        val nativeId = input.events.singleOrNull()?.sourceMessageId?.takeIf { it.startsWith("native:") }?.removePrefix("native:")
        val boundary = nativeId?.let { id -> fullHistory.indexOfFirst { it.id.toString() == id } } ?: -1
        val history = if (boundary >= 0) fullHistory.take(boundary + 1) else fullHistory
        kernel.contextManager.compactIfNeeded(conversationId.toString(), history, kernel.contextWindowTokens)
        val memories = kernel.memoryStore.recallForPrompt(input.batchPrompt).let { recalled ->
            if (conversationId == PRIMARY_CONVERSATION_ID) recalled else recalled.filter { it.scope != MemoryScope.CORE }
        }
        val ruleConversation = input.events.map { event ->
            kernel.orchestrationStore.dialogue.ruleConversationId(event.channelId, event.sourceMessageId, event.conversationId)
        }.distinct().singleOrNull()
        val activeRules = kernel.proceduralRuleStore.selectActiveForInjection(
            conversationId = ruleConversation,
            recordHit = true,
        )
        kernel.contextManager.prepareRequestMessages(
            systemPrompt = kernel.soulStore.renderRouterSystemPrompt(
                routerInstructions = ModelRouterBrain.DEFAULT_ROUTER_SYSTEM_PROMPT,
                activeRules = activeRules,
            ),
            memories = memories, conversationId = conversationId.toString(),
            historyMessages = history, tokenBudget = kernel.contextWindowTokens,
        )
    }

    suspend fun recordReply(
        conversationId: String,
        text: String,
        messageId: Uuid? = null,
        createPrimaryIfMissing: Boolean = false,
    ) = conversationMutex.withLock {
        val id = Uuid.parse(conversationId)
        val conversation = kernel.conversationStorage.loadConversation(id)
            ?: if (createPrimaryIfMissing && id == PRIMARY_CONVERSATION_ID) {
                Conversation(id = id, assistantId = DEFAULT_ASSISTANT_ID, title = "主时间线", messageNodes = emptyList())
            } else return@withLock
        val reply = UIMessage.assistant(text).let { if (messageId == null) it else it.copy(id = messageId) }
        val nodes = conversation.messageNodes
        kernel.conversationStorage.saveConversation(conversation.copy(
            messageNodes = if (nodes.any { it.currentMessage.id == reply.id }) nodes else nodes + reply.toMessageNode(),
            updateAt = Clock.System.now(),
        ))
    }

    private fun response(message: InboundMessage, text: String) = OutboundMessage(
        channel = message.channel, chatId = message.chatId, threadId = message.threadId,
        replyToMessageId = message.messageId, text = text,
        conversationId = resolveConversationId(message).toString(),
    )
}
