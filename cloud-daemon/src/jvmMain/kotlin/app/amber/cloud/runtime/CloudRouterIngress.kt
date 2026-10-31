package app.amber.cloud.runtime

import app.amber.ai.ui.UIMessage
import app.amber.cloud.channel.ChannelIngress
import app.amber.cloud.channel.ConversationScope
import app.amber.cloud.channel.InboundMessage
import app.amber.cloud.channel.OutboundMessage
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.channel.resolveConversationId
import app.amber.cloud.orchestration.ModelRouterBrain
import app.amber.cloud.orchestration.RouterTurnInput
import app.amber.cloud.security.CredentialRedactor
import app.amber.core.model.Conversation
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

    override suspend fun handleInbound(message: InboundMessage): OutboundMessage {
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
                kernel.extractExplicitMemoryIfPresent(message.text, conversationId.toString())
            }
            kernel.conversationStorage.saveConversation(conversation.copy(
                messageNodes = conversation.messageNodes + UIMessage.user(CredentialRedactor.redact(message.text)).toMessageNode(),
                updateAt = Clock.System.now(),
            ))
        }
        // The connector sends the returned acknowledgement; Router only sends subsequent replies/status.
        val ack = kernel.router.onInbound(message, postAck = false, sessionId = conversationId.toString())
        return response(message, ack.text)
    }

    suspend fun contextMessages(input: RouterTurnInput): List<UIMessage> = conversationMutex.withLock {
        val conversationId = Uuid.parse(input.events.first().conversationId)
        val conversation = kernel.conversationStorage.loadConversation(conversationId) ?: return@withLock emptyList()
        val history = conversation.messageNodes.map { it.currentMessage }
        kernel.contextManager.compactIfNeeded(conversationId.toString(), history, kernel.contextWindowTokens)
        val memories = kernel.memoryStore.recallForPrompt(input.batchPrompt).let { recalled ->
            if (conversationId == PRIMARY_CONVERSATION_ID) recalled else recalled.filter { it.scope != MemoryScope.CORE }
        }
        kernel.contextManager.prepareRequestMessages(
            systemPrompt = kernel.memoryStore.loadSoulPrompt() + "\n" + ModelRouterBrain.DEFAULT_ROUTER_SYSTEM_PROMPT,
            memories = memories, conversationId = conversationId.toString(),
            historyMessages = history, tokenBudget = kernel.contextWindowTokens,
        )
    }

    suspend fun recordReply(conversationId: String, text: String) = conversationMutex.withLock {
        val id = Uuid.parse(conversationId)
        val conversation = kernel.conversationStorage.loadConversation(id) ?: return@withLock
        kernel.conversationStorage.saveConversation(conversation.copy(
            messageNodes = conversation.messageNodes + UIMessage.assistant(text).toMessageNode(),
            updateAt = Clock.System.now(),
        ))
    }

    private fun response(message: InboundMessage, text: String) = OutboundMessage(
        channel = message.channel, chatId = message.chatId, threadId = message.threadId,
        replyToMessageId = message.messageId, text = text,
        conversationId = resolveConversationId(message).toString(),
    )
}
