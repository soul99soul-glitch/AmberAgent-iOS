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
    val parts = buildList {
        if (text.isNotEmpty()) add(UIMessagePart.Text(text))
        for (attachment in attachments) {
            require(attachment.name.isNotBlank()) { "Attachment name is required" }
            when (attachment.kind) {
                "image" -> {
                    val url = attachment.dataURL.orEmpty()
                    val prefix = "data:${attachment.mimeType};base64,"
                    require(attachment.mimeType.startsWith("image/") && url.startsWith(prefix) && url.length > prefix.length) {
                        "Image attachment requires an inline image data URL"
                    }
                    add(UIMessagePart.Image(url, buildJsonObject {
                        put("fileName", attachment.name)
                        put("mimeType", attachment.mimeType)
                    }))
                }
                "text" -> {
                    require(!attachment.text.isNullOrBlank()) { "Document attachment is empty" }
                    add(UIMessagePart.Text("\n\n--- ${attachment.name} ---\n${attachment.text}\n---\n"))
                }
                else -> error("Unsupported attachment type: ${attachment.kind}")
            }
        }
    }
    return DesktopMessage.from(UIMessage(id = Uuid.parse(id), role = MessageRole.USER, parts = parts))
}
