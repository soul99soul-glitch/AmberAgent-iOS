package shared

import app.amber.ai.core.MessageRole
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.core.agent.store.renderMailboxEnvelopeToUserText
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.put
import kotlin.uuid.ExperimentalUuidApi

private const val MAILBOX_SOURCE_KEY = "amber_mailbox_source"
private const val MAILBOX_SOURCE_VALUE = "mailbox"
private const val MAILBOX_AUTHOR_THREAD_ID_KEY = "author_thread_id"
private const val MAILBOX_KIND_KEY = "kind"

/** Shared representation for a mailbox envelope rendered into a conversation. */
@OptIn(ExperimentalUuidApi::class)
object IosMailboxMessageBridge {
    /** Construct the persisted user message for a delivered mailbox envelope. */
    fun makeMessage(authorThreadId: String, type: String, payload: String): UIMessage {
        val metadata = buildJsonObject {
            put(MAILBOX_SOURCE_KEY, MAILBOX_SOURCE_VALUE)
            put(MAILBOX_AUTHOR_THREAD_ID_KEY, authorThreadId)
            put(MAILBOX_KIND_KEY, type)
        }
        return UIMessage(
            role = MessageRole.USER,
            parts = listOf(
                UIMessagePart.Text(
                    text = renderMailboxEnvelopeToUserText(
                        authorThreadId = authorThreadId,
                        type = type,
                        payload = payload,
                    ),
                    metadata = metadata,
                )
            ),
        )
    }

    /** Return the source thread only for a structurally marked mailbox message. */
    fun sender(message: UIMessage): String? = message.parts
        .filterIsInstance<UIMessagePart.Text>()
        .firstNotNullOfOrNull { mailboxSource(it)?.authorThreadId }

    /** Return the mailbox envelope kind only for a structurally marked message. */
    fun kind(message: UIMessage): String? = message.parts
        .filterIsInstance<UIMessagePart.Text>()
        .firstNotNullOfOrNull { mailboxSource(it)?.kind }

    /**
     * Hide the transport header only when both metadata and the matching header
     * are present. Ordinary user text that happens to contain the prefix remains
     * unchanged.
     */
    fun displayText(part: UIMessagePart.Text): String {
        val source = mailboxSource(part) ?: return part.text
        val header = "[mailbox ${source.kind} from ${source.authorThreadId}]\n"
        return if (part.text.startsWith(header)) {
            part.text.removePrefix(header)
        } else {
            part.text
        }
    }

    private fun mailboxSource(part: UIMessagePart.Text): MailboxSource? {
        val metadata = part.metadata ?: return null
        if (metadata[MAILBOX_SOURCE_KEY].primitiveContent() != MAILBOX_SOURCE_VALUE) {
            return null
        }
        val authorThreadId = metadata[MAILBOX_AUTHOR_THREAD_ID_KEY].primitiveContent()
            ?.takeIf { it.isNotBlank() }
            ?: return null
        val kind = metadata[MAILBOX_KIND_KEY].primitiveContent()
            ?.takeIf { it.isNotBlank() }
            ?: return null
        return MailboxSource(authorThreadId = authorThreadId, kind = kind)
    }

    private fun JsonElement?.primitiveContent(): String? =
        (this as? JsonPrimitive)?.contentOrNull

    private data class MailboxSource(
        val authorThreadId: String,
        val kind: String,
    )
}
