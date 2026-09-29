package app.amber.ai.provider.openai

import app.amber.ai.core.InputSchema
import app.amber.ai.core.MessageRole
import app.amber.ai.core.Tool
import app.amber.ai.ui.MessageStreamAccumulator
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MiMoTextToolCallRecoveryTest {
    private val themeTool = Tool(
        name = "theme_pack_import",
        description = "",
        parameters = {
            InputSchema.Obj(
                properties = buildJsonObject {
                    putJsonObject("base_id") { put("type", "string") }
                    putJsonObject("design") { put("type", "object") }
                }
            )
        },
        execute = { emptyList() },
    )

    /** 网关没解析成功、整段落进 content 且缺 `</parameter>`/`</function>` 的真实形态。 */
    @Test
    fun leakedMalformedXmlToolCallBecomesAStructuredToolCall() {
        val content = "好，四条一起改：\n\n<tool_call><function=theme_pack_import><parameter=base_id>current" +
            "<parameter=design>{\"components\": {\"cardRadius\": 22}, \"dark\": {\"mutedForeground\": \"#B69A82\"}}</tool_call>"
        val recovery = MiMoTextToolCallRecovery(listOf(themeTool))
        val accumulator = MessageStreamAccumulator(listOf(UIMessage(role = MessageRole.USER, parts = emptyList())))
        val provider = OpenAIKmpProvider()
        content.chunked(5).forEach { piece ->
            val payload = buildJsonObject {
                put("choices", Json.parseToJsonElement("""[{"index":0,"delta":{"content":${Json.encodeToString(piece)}}}]"""))
            }
            provider.parseChatCompletionStreamData(payload.toString()).forEach { accumulator.append(recovery.transform(it)) }
        }
        provider.parseChatCompletionStreamData("""{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}""")
            .forEach { accumulator.append(recovery.transform(it)) }

        val message = accumulator.snapshot().last()
        val text = message.parts.filterIsInstance<UIMessagePart.Text>().joinToString("") { it.text }
        assertEquals("好，四条一起改：\n\n", text)
        val tool = message.parts.filterIsInstance<UIMessagePart.Tool>().single()
        assertEquals("theme_pack_import", tool.toolName)
        assertTrue(tool.toolCallId.isNotBlank())
        val args = Json.parseToJsonElement(tool.input).jsonObject
        assertEquals("current", args.getValue("base_id").jsonPrimitive.content)
        assertEquals("22", args.getValue("design").jsonObject.getValue("components").jsonObject.getValue("cardRadius").jsonPrimitive.content)
    }

    @Test
    fun undeclaredToolNameStaysVisibleText() {
        val raw = "<tool_call><function=rm_rf><parameter=path>/</parameter></function></tool_call>"
        val recovery = MiMoTextToolCallRecovery(listOf(themeTool))
        val message = recovery.transformMessage(UIMessage(role = MessageRole.ASSISTANT, parts = listOf(UIMessagePart.Text(raw))))

        assertEquals(raw, (message.parts.single() as UIMessagePart.Text).text)
        assertEquals(false, recovery.recoveredAny)
    }
}
