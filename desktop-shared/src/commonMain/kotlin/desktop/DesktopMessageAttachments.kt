@file:OptIn(kotlin.uuid.ExperimentalUuidApi::class)

package desktop

import app.amber.ai.core.MessageRole
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.uuid.Uuid

@Serializable
internal data class DesktopMessageAttachment(
    val name: String,
    val mimeType: String,
    val kind: String,
    val dataURL: String? = null,
    val text: String? = null,
)

internal fun desktopUserMessage(id: String, text: String, attachmentsJSON: String): DesktopMessage {
    val attachments = Json.decodeFromString<List<DesktopMessageAttachment>>(attachmentsJSON)
    require(text.isNotBlank() || attachments.isNotEmpty()) { "A message requires text or an attachment" }

    fun DesktopMessageAttachment.toMessagePart(): UIMessagePart {
        require(name.isNotBlank()) { "Attachment name is required" }
        return when (kind) {
            "image" -> {
                val url = dataURL.orEmpty()
                val prefix = "data:$mimeType;base64,"
                require(mimeType.startsWith("image/") && url.startsWith(prefix) && url.length > prefix.length) {
                    "Image attachment requires an inline image data URL"
                }
                UIMessagePart.Image(url, buildJsonObject {
                    put("fileName", name)
                    put("mimeType", mimeType)
                })
            }
            "text" -> {
                require(!this.text.isNullOrBlank()) { "Document attachment is empty" }
                UIMessagePart.Text("\n\n--- $name ---\n${this.text}\n---\n")
            }
            "inline_text" -> {
                require(!this.text.isNullOrBlank()) { "Inline text segment is empty" }
                UIMessagePart.Text(this.text)
            }
            else -> error("Unsupported attachment type: $kind")
        }
    }

    val markerRegex = Regex("""!\[([^\]]*)]\(attachment://([^)\s]+)\)""")
    val matches = markerRegex.findAll(text).toList()
    val parts = buildList {
        val consumedIndices = mutableSetOf<Int>()
        if (matches.isNotEmpty()) {
            var cursor = 0
            for (match in matches) {
                val target = match.groupValues[2]
                val index = target.toIntOrNull()?.takeIf { it in attachments.indices }
                    ?: attachments.indexOfFirst { it.name == target }.takeIf { it >= 0 }
                if (index != null) {
                    val prefixText = text.substring(cursor, match.range.first)
                    if (prefixText.isNotEmpty()) add(UIMessagePart.Text(prefixText))
                    consumedIndices += index
                    add(attachments[index].toMessagePart())
                    cursor = match.range.last + 1
                }
            }
            val tailText = text.substring(cursor)
            if (tailText.isNotEmpty()) add(UIMessagePart.Text(tailText))
        } else if (text.isNotEmpty()) {
            add(UIMessagePart.Text(text))
        }
        for ((index, attachment) in attachments.withIndex()) {
            if (index !in consumedIndices) {
                add(attachment.toMessagePart())
            }
        }
    }
    return DesktopMessage.from(UIMessage(id = Uuid.parse(id), role = MessageRole.USER, parts = parts))
}
