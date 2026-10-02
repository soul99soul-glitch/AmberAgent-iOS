package app.amber.ai.ui

import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

const val REASONING_CONTENT_PRESENT_METADATA_KEY = "reasoning_content_present"
const val CLAUDE_REDACTED_THINKING_METADATA_KEY = "claude_redacted_thinking"
const val CLAUDE_THINKING_BLOCK_INDEX_METADATA_KEY = "claude_thinking_block_index"

fun reasoningContentPresentMetadata() = buildJsonObject {
    put(REASONING_CONTENT_PRESENT_METADATA_KEY, true)
}

fun UIMessagePart.Reasoning.hasExplicitReasoningContentField(): Boolean =
    metadata?.get(REASONING_CONTENT_PRESENT_METADATA_KEY)
        ?.jsonPrimitive
        ?.booleanOrNull == true

internal fun JsonObject?.hasProtocolReasoningContent(): Boolean =
    listOf("signature", "encrypted_content").any { key ->
        (this?.get(key) as? JsonPrimitive)?.contentOrNull?.isNotBlank() == true
    } || ((this?.get(CLAUDE_REDACTED_THINKING_METADATA_KEY) as? JsonObject)
        ?.get("data") as? JsonPrimitive)?.contentOrNull?.isNotBlank() == true

/** Empty encrypted/signed blocks belong in history, but have no readable card body. */
fun isEmptyProtocolReasoning(reasoning: UIMessagePart.Reasoning): Boolean =
    reasoning.reasoning.isBlank() && reasoning.metadata.hasProtocolReasoningContent()

internal fun reasoningBlocksCanMerge(previous: JsonObject?, incoming: JsonObject?): Boolean {
    if (previous?.containsKey(CLAUDE_REDACTED_THINKING_METADATA_KEY) == true ||
        incoming?.containsKey(CLAUDE_REDACTED_THINKING_METADATA_KEY) == true
    ) return false
    return listOf(CLAUDE_THINKING_BLOCK_INDEX_METADATA_KEY, "reasoning_id").all { key ->
        val before = previous?.get(key)
        val after = incoming?.get(key)
        before == null || after == null || before == after
    }
}
