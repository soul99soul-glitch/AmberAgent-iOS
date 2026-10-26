@file:OptIn(kotlin.uuid.ExperimentalUuidApi::class)

package desktop

import app.amber.ai.core.MessageRole
import app.amber.ai.core.TokenUsage
import app.amber.ai.ui.ToolApprovalState
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessageAnnotation
import app.amber.ai.ui.UIMessagePart
import app.amber.core.model.Conversation
import app.amber.core.model.ConversationMemoryMode
import app.amber.core.model.MessageNode
import kotlinx.datetime.LocalDateTime
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.io.encoding.Base64
import kotlin.time.Instant
import kotlin.uuid.Uuid

internal fun canonicalConversationFixture(): Conversation {
    val instant = Instant.parse("2026-10-23T08:09:10.123456789Z")
    val local = LocalDateTime.parse("2026-10-23T16:09:10.123456789")
    val metadata = buildJsonObject {
        put("source", "fixture")
        put("nested", buildJsonObject { put("retain", true) })
    }
    val user = UIMessage(
        id = Uuid.parse("10000000-0000-4000-8000-000000000001"),
        role = MessageRole.USER,
        parts = listOf(UIMessagePart.Text("question", metadata)),
        createdAt = local,
    )
    val mixed = UIMessage(
        id = Uuid.parse("20000000-0000-4000-8000-000000000002"),
        role = MessageRole.ASSISTANT,
        parts = listOf(
            UIMessagePart.Text("before", metadata),
            UIMessagePart.Reasoning("reasoning", instant, instant, metadata),
            UIMessagePart.Image(canonicalInlineImageFixture(), metadata),
            UIMessagePart.Text("after", metadata),
            UIMessagePart.Document("file:///tmp/reference.txt", "reference.txt", "text/plain", metadata),
            UIMessagePart.Tool(
                toolCallId = "call-1", toolName = "lookup", input = "{\"query\":\"value\"}",
                output = listOf(
                    UIMessagePart.Text("result", metadata),
                    UIMessagePart.Image("https://example.com/tool-result.png", metadata),
                ),
                approvalState = ToolApprovalState.Answered("approved answer"), streamIndex = 3, metadata = metadata,
            ),
        ),
        annotations = listOf(UIMessageAnnotation.UrlCitation("Reference", "https://example.com/reference")),
        createdAt = local,
        finishedAt = local,
        modelId = Uuid.parse("30000000-0000-4000-8000-000000000003"),
        usage = TokenUsage(11, 7, 2, 18, 50),
        translation = "译文",
    )
    return Conversation(
        id = Uuid.parse("40000000-0000-4000-8000-000000000004"),
        assistantId = Uuid.parse("50000000-0000-4000-8000-000000000005"),
        title = "mixed contract",
        messageNodes = listOf(
            MessageNode(Uuid.parse("60000000-0000-4000-8000-000000000006"), listOf(user)),
            MessageNode(
                Uuid.parse("70000000-0000-4000-8000-000000000007"),
                listOf(mixed.copy(id = Uuid.parse("80000000-0000-4000-8000-000000000008")), mixed),
                selectIndex = 1,
            ),
        ),
        chatSuggestions = listOf("next question"), isPinned = true,
        autoApproveToolCalls = true, memoryMode = ConversationMemoryMode.DISABLED,
        createAt = instant, updateAt = instant,
    )
}


internal fun canonicalInlineImageFixture(): String {
    val pixel = Base64.decode("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
    // A valid one-pixel GIF with comments crosses the existing 16 KiB blob threshold.
    val comments = buildList<Byte> {
        add(0x21); add(0xFE.toByte())
        repeat(66) { add(255.toByte()); repeat(255) { add('a'.code.toByte()) } }
        add(0); add(0x3B)
    }.toByteArray()
    return "data:image/gif;base64," + Base64.encode(pixel.copyOf(pixel.size - 1) + comments)
}
