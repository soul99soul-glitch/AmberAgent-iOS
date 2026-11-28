package app.amber.core.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient
import app.amber.ai.core.MessageRole
import app.amber.ai.ui.UIMessage
import app.amber.ai.util.InstantSerializer

import kotlin.time.Clock
import kotlin.time.Instant
import kotlin.uuid.Uuid

@Serializable
data class Conversation(
    val id: Uuid = Uuid.random(),
    val assistantId: Uuid,
    val title: String = "",
    val messageNodes: List<MessageNode>,
    val chatSuggestions: List<String> = emptyList(),
    val isPinned: Boolean = false,
    val autoApproveToolCalls: Boolean = false,
    /** P2-a：会话记忆模式。harness 置位、用户复位；旧 JSON 缺字段解码为 ENABLED。 */
    val memoryMode: ConversationMemoryMode = ConversationMemoryMode.ENABLED,
    @Serializable(with = InstantSerializer::class)
    val createAt: Instant = Clock.System.now(),
    @Serializable(with = InstantSerializer::class)
    val updateAt: Instant = Clock.System.now(),
    @Transient
    val newConversation: Boolean = false
) {
    /**
     *  当前选中的 message
     */
    val currentMessages
        get(): List<UIMessage> {
            return messageNodes.map { node -> node.messages[node.selectIndex] }
        }

    fun getMessageNodeByMessage(message: UIMessage): MessageNode? {
        return messageNodes.firstOrNull { node -> node.messages.contains(message) }
    }

    fun getMessageNodeByMessageId(messageId: Uuid): MessageNode? {
        return messageNodes.firstOrNull { node -> node.messages.any { it.id == messageId } }
    }

    fun updateCurrentMessages(messages: List<UIMessage>): Conversation {
        val originalNodes = this.messageNodes
        val nodeIndexByMessageId = HashMap<Uuid, Int>(originalNodes.size * 2)
        originalNodes.forEachIndexed { nodeIndex, node ->
            node.messages.forEach { msg ->
                if (msg.id !in nodeIndexByMessageId) {
                    nodeIndexByMessageId[msg.id] = nodeIndex
                }
            }
        }

        val claimedNodeByMsg = IntArray(messages.size) { -1 }
        val claimedNodes = BooleanArray(originalNodes.size)

        // Pass 1: Claim existing nodes by stable message ID so shifting/reordering
        // (e.g. [U1, A1, U2] -> [U1, U2, A2] when a provisional reply is withdrawn on steer)
        // moves the user's node cleanly instead of mixing user and assistant variants.
        for (index in messages.indices) {
            val matchedNodeIndex = nodeIndexByMessageId[messages[index].id]
            if (matchedNodeIndex != null && !claimedNodes[matchedNodeIndex]) {
                claimedNodeByMsg[index] = matchedNodeIndex
                claimedNodes[matchedNodeIndex] = true
            }
        }

        // Pass 2: Positional fallback only for unclaimed nodes at the same index whose role matches
        // (preserves same-slot regenerate sibling variants while never mixing user/assistant roles).
        for (index in messages.indices) {
            if (claimedNodeByMsg[index] >= 0) continue
            val candidate = originalNodes.getOrNull(index) ?: continue
            if (!claimedNodes[index]
                && candidate.messages.isNotEmpty()
                && candidate.messages.all { it.role == messages[index].role }
            ) {
                claimedNodeByMsg[index] = index
                claimedNodes[index] = true
            }
        }

        val newNodes = ArrayList<MessageNode>(maxOf(messages.size, originalNodes.size))
        var anyNodeChanged = false

        messages.forEachIndexed { index, message ->
            val matchedNodeIndex = claimedNodeByMsg[index]
            if (matchedNodeIndex < 0) {
                newNodes.add(message.toMessageNode())
                anyNodeChanged = true
                return@forEachIndexed
            }

            val existingNode = originalNodes[matchedNodeIndex]
            val existingIdx = existingNode.messages.indexOfFirst { it.id == message.id }
            // Identity short-circuit: if the incoming UIMessage is the SAME
            // reference as the one already at the selected slot AND that
            // slot is the currently-selected branch, the node is unchanged
            // for every observable purpose. Skip `node.copy(...)` so the
            // outer reference stays stable across the 33ms streaming flush.
            if (existingIdx >= 0
                && existingNode.messages[existingIdx] === message
                && existingNode.selectIndex == existingIdx
            ) {
                newNodes.add(existingNode)
                if (matchedNodeIndex != index) {
                    anyNodeChanged = true
                }
                return@forEachIndexed
            }

            val newMessages = existingNode.messages.toMutableList()
            val newMessageIndex = if (existingIdx >= 0) {
                newMessages[existingIdx] = message
                existingIdx
            } else {
                newMessages.add(message)
                newMessages.lastIndex
            }

            newNodes.add(
                existingNode.copy(
                    messages = newMessages,
                    selectIndex = newMessageIndex
                )
            )
            anyNodeChanged = true
        }

        // Preserve untouched trailing nodes beyond `messages.size` only if they were not already
        // claimed/shifted into an earlier slot (prevents duplicating shifted nodes when a draft is withdrawn).
        for (tailIndex in messages.size until originalNodes.size) {
            if (!claimedNodes[tailIndex]) {
                newNodes.add(originalNodes[tailIndex])
            } else {
                anyNodeChanged = true
            }
        }

        // If nothing changed at the node-list level either, return `this`
        // so the outer Conversation reference is also preserved — gives
        // every snapshotFlow downstream a chance to short-circuit too.
        if (!anyNodeChanged && newNodes.size == originalNodes.size) {
            return this
        }
        return this.copy(
            messageNodes = newNodes
        )
    }

    companion object {
        fun ofId(
            id: Uuid,
            assistantId: Uuid = DEFAULT_ASSISTANT_ID,
            messages: List<MessageNode> = emptyList(),
            newConversation: Boolean = false
        ) = Conversation(
            id = id,
            assistantId = assistantId,
            messageNodes = messages,
            newConversation = newConversation,
        )
    }
}

@Serializable
data class MessageNode(
    val id: Uuid = Uuid.random(),
    val messages: List<UIMessage>,
    val selectIndex: Int = 0,
    @Transient
    val isFavorite: Boolean = false,
) {
    val currentMessage get() = if (messages.isEmpty() || selectIndex !in messages.indices) {
        throw IllegalStateException("MessageNode has no valid current message: messages.size=${messages.size}, selectIndex=$selectIndex")
    } else {
        messages[selectIndex]
    }

    val role get() = messages.firstOrNull()?.role ?: MessageRole.USER

    companion object {
        fun of(message: UIMessage) = MessageNode(
            messages = listOf(message),
            selectIndex = 0
        )
    }
}

fun UIMessage.toMessageNode(): MessageNode {
    return MessageNode(
        messages = listOf(this),
        selectIndex = 0
    )
}
