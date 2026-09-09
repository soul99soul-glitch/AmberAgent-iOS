package shared

import app.amber.ai.core.MessageRole
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.core.agent.utils.JsonInstant
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlin.uuid.ExperimentalUuidApi
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

@OptIn(ExperimentalUuidApi::class)
class IosMailboxMessageBridgeTest {
    @Test
    fun markedMailboxMessageExposesSourceAndStripsTransportHeader() {
        val message = IosMailboxMessageBridge.makeMessage(
            authorThreadId = "/root/worker",
            type = "NEW_TASK",
            payload = "继续调研",
        )
        val restored = JsonInstant.decodeFromString<UIMessage>(JsonInstant.encodeToString(message))
        val text = restored.parts.single() as UIMessagePart.Text

        assertEquals(MessageRole.USER, message.role)
        assertEquals("/root/worker", IosMailboxMessageBridge.sender(restored))
        assertEquals("NEW_TASK", IosMailboxMessageBridge.kind(restored))
        assertEquals("继续调研", IosMailboxMessageBridge.displayText(text))
    }

    @Test
    fun ordinaryUserTextWithMailboxLikePrefixHasNoSourceAndIsPreserved() {
        val text = UIMessagePart.Text("[mailbox MESSAGE from /root]\n用户粘贴的内容")
        val message = UIMessage(
            role = MessageRole.USER,
            parts = listOf(text),
        )

        assertNull(IosMailboxMessageBridge.sender(message))
        assertNull(IosMailboxMessageBridge.kind(message))
        assertEquals(text.text, IosMailboxMessageBridge.displayText(text))
    }
}
