package app.amber.ai.provider.openai

import app.amber.ai.core.InputSchema
import app.amber.ai.core.MessageRole
import app.amber.ai.core.Tool
import app.amber.ai.ui.MessageChunk
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessageChoice
import app.amber.ai.ui.UIMessagePart
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlin.uuid.Uuid

/**
 * MiMo 在正文里生成 `<tool_call><function=NAME><parameter=KEY>VALUE</parameter></function></tool_call>`，
 * 再由小米网关解析成 `tool_calls`。模型漏写 `</parameter>` / `</function>` 等闭合标签时网关解析失败，
 * 整段 XML 会作为普通 `content` 返回：界面把它当正文显示，工具也不会执行。
 *
 * 这里在流式 content 上做兜底：一旦出现 `<tool_call>` 就扣住后续文本，块结束（或流结束）后
 * 按已声明工具解析成标准 [UIMessagePart.Tool]；解析不了（未知工具名等）则原样还给正文。
 * 参数值按工具 schema 定型：string 保留原文，其余尝试按 JSON 解析。
 */
internal class MiMoTextToolCallRecovery(tools: List<Tool>) {
    private val properties: Map<String, JsonObject?> = tools.associate { tool ->
        tool.name to (runCatching { tool.parameters() }.getOrNull() as? InputSchema.Obj)?.properties
    }
    private val pending = StringBuilder()
    private var capturing = false
    private var recoveredCount = 0
    private val callIdPrefix = "call_mimo_text_${Uuid.random().toHexString().take(12)}"

    /** 本轮是否恢复过工具调用；调用方据此把终态 finish_reason 改为 `tool_calls`。 */
    val recoveredAny: Boolean get() = recoveredCount > 0

    fun transform(chunk: MessageChunk): MessageChunk {
        val choice = chunk.choices.firstOrNull() ?: return chunk
        val message = choice.delta ?: choice.message ?: return chunk
        val parts = mutableListOf<UIMessagePart>()
        message.parts.forEach { part ->
            if (part is UIMessagePart.Text) {
                val (text, tools) = consume(part.text)
                if (text.isNotEmpty()) parts += part.copy(text = text)
                parts += tools
            } else {
                parts += part
            }
        }
        if (choice.finishReason.isTerminal()) parts += finish().toParts()
        val finishReason = if (choice.finishReason.isTerminal() && recoveredAny) "tool_calls" else choice.finishReason
        val rebuilt = message.copy(parts = parts)
        return chunk.copy(
            choices = listOf(
                choice.copy(
                    delta = choice.delta?.let { rebuilt },
                    message = if (choice.delta == null) rebuilt else choice.message,
                    finishReason = finishReason,
                )
            ) + chunk.choices.drop(1)
        )
    }

    /** 流在没有终态 finish_reason 的情况下结束时，吐出仍被扣住的内容。 */
    fun drain(): MessageChunk? {
        val parts = finish().toParts()
        if (parts.isEmpty()) return null
        return MessageChunk(
            id = "",
            model = "",
            choices = listOf(
                UIMessageChoice(
                    index = 0,
                    delta = UIMessage(role = MessageRole.ASSISTANT, parts = parts),
                    message = null,
                    finishReason = null,
                )
            ),
        )
    }

    /** 非流式：整条消息一次性处理。 */
    fun transformMessage(message: UIMessage): UIMessage {
        val parts = mutableListOf<UIMessagePart>()
        message.parts.forEach { part ->
            if (part is UIMessagePart.Text) {
                val (text, tools) = consume(part.text)
                val (tail, tailTools) = finish()
                val merged = text + tail
                if (merged.isNotEmpty()) parts += part.copy(text = merged)
                parts += tools + tailTools
            } else {
                parts += part
            }
        }
        return if (recoveredAny) message.copy(parts = parts) else message
    }

    private fun consume(text: String): Pair<String, List<UIMessagePart.Tool>> {
        pending.append(text)
        val visible = StringBuilder()
        val tools = mutableListOf<UIMessagePart.Tool>()
        while (true) {
            if (!capturing) {
                val start = pending.indexOf(OPEN)
                if (start >= 0) {
                    visible.append(pending, 0, start)
                    pending.deleteRange(0, start + OPEN.length)
                    capturing = true
                    continue
                }
                // 流式分片可能把 `<tool_call>` 劈开：扣住末尾可能是开标签前缀的部分。
                val keep = heldPrefixLength()
                visible.append(pending, 0, pending.length - keep)
                pending.deleteRange(0, pending.length - keep)
                break
            }
            val end = pending.indexOf(CLOSE)
            if (end < 0) break
            val body = pending.substring(0, end)
            pending.deleteRange(0, end + CLOSE.length)
            capturing = false
            val tool = parse(body)
            if (tool != null) tools += tool else visible.append(OPEN).append(body).append(CLOSE)
        }
        return visible.toString() to tools
    }

    private fun finish(): Pair<String, List<UIMessagePart.Tool>> {
        val rest = pending.toString()
        pending.clear()
        if (!capturing) return rest to emptyList()
        capturing = false
        val tool = parse(rest) ?: return (OPEN + rest) to emptyList()
        return "" to listOf(tool)
    }

    private fun Pair<String, List<UIMessagePart.Tool>>.toParts(): List<UIMessagePart> = buildList {
        if (first.isNotEmpty()) add(UIMessagePart.Text(first))
        addAll(second)
    }

    private fun heldPrefixLength(): Int {
        val max = minOf(OPEN.length - 1, pending.length)
        for (length in max downTo 1) {
            if (OPEN.startsWith(pending.substring(pending.length - length))) return length
        }
        return 0
    }

    private fun parse(body: String): UIMessagePart.Tool? {
        val fnStart = body.indexOf(FUNCTION)
        if (fnStart < 0) return null
        val nameEnd = body.indexOf('>', fnStart)
        if (nameEnd < 0) return null
        val name = body.substring(fnStart + FUNCTION.length, nameEnd).trim()
        if (name !in properties) return null
        var rest = body.substring(nameEnd + 1)
        rest.indexOf(FUNCTION_CLOSE).takeIf { it >= 0 }?.let { rest = rest.substring(0, it) }
        val schema = properties[name]
        val arguments = buildJsonObject {
            var cursor = 0
            while (true) {
                val start = rest.indexOf(PARAMETER, cursor)
                if (start < 0) break
                val keyEnd = rest.indexOf('>', start)
                if (keyEnd < 0) break
                val key = rest.substring(start + PARAMETER.length, keyEnd).trim()
                val valueStart = keyEnd + 1
                // 容忍漏写 `</parameter>`：值截止到下一个闭合标签或下一个参数。
                val valueEnd = listOf(
                    rest.indexOf(PARAMETER_CLOSE, valueStart),
                    rest.indexOf(PARAMETER, valueStart),
                ).filter { it >= 0 }.minOrNull() ?: rest.length
                if (key.isNotEmpty()) put(key, coerce(schema?.get(key), rest.substring(valueStart, valueEnd)))
                cursor = valueEnd
            }
        }
        recoveredCount += 1
        return UIMessagePart.Tool(
            toolCallId = "${callIdPrefix}_$recoveredCount",
            toolName = name,
            input = arguments.toString(),
        )
    }

    private fun coerce(propertySchema: JsonElement?, raw: String): JsonElement {
        val types = when (val type = (propertySchema as? JsonObject)?.get("type")) {
            is JsonPrimitive -> setOfNotNull(type.contentOrNull)
            is JsonArray -> type.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.toSet()
            else -> emptySet()
        }
        if ("string" in types && types.none { it in NON_STRING_TYPES }) {
            return JsonPrimitive(raw.removePrefix("\n").removeSuffix("\n"))
        }
        val trimmed = raw.trim()
        parseJson(trimmed)?.let { return it }
        if (types.any { it == "object" || it == "array" }) {
            // 模型偶尔输出中文弯引号包裹的 JSON。
            parseJson(trimmed.replace('“', '"').replace('”', '"'))?.let { return it }
        }
        return JsonPrimitive(trimmed)
    }

    private fun parseJson(value: String): JsonElement? =
        runCatching { Json.parseToJsonElement(value) }.getOrNull()
            ?.takeUnless { it is JsonPrimitive && it.isString }

    private fun String?.isTerminal(): Boolean = this != null && this != "unknown"

    private companion object {
        const val OPEN = "<tool_call>"
        const val CLOSE = "</tool_call>"
        const val FUNCTION = "<function="
        const val FUNCTION_CLOSE = "</function>"
        const val PARAMETER = "<parameter="
        const val PARAMETER_CLOSE = "</parameter>"
        val NON_STRING_TYPES = setOf("object", "array", "number", "integer", "boolean")
    }
}
