package desktop

import app.amber.ai.ui.UIMessagePart
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull

private const val citationKey = "amber_memory_record_ids"
private const val citationOpen = "<amber-mem-cite>"
private const val citationClose = "</amber-mem-cite>"
private val citationTag = Regex("<amber-mem-cite>([\\s\\S]*?)</amber-mem-cite>")

internal fun desktopMemoryMapping(json: String): Map<Int, Int> = Json.decodeFromString<Map<Int, Int>>(json).also { mapping ->
    require(mapping.keys.all { it > 0 } && mapping.values.all { it > 0 }) { "Memory ID mapping must contain positive IDs" }
}

private fun remapIds(value: JsonElement, mapping: Map<Int, Int>): JsonArray {
    require(value is JsonArray) { "Memory citation IDs must be a numeric array" }
    val ids = value.map { element ->
        val primitive = element as? JsonPrimitive
        require(primitive != null && !primitive.isString && primitive.intOrNull != null) { "Memory citation ID must be an integer" }
        primitive.intOrNull!!
    }
    return JsonArray(ids.mapNotNull { mapping[it] }.distinct().map(::JsonPrimitive))
}

private fun remapTags(text: String, mapping: Map<Int, Int>): String {
    val result = citationTag.replace(text) { match ->
        val payload = Json.parseToJsonElement(match.groupValues[1])
        require(payload is JsonObject && payload["ids"] != null) { "Unsupported memory citation tag" }
        citationOpen + JsonObject(payload + ("ids" to remapIds(payload.getValue("ids"), mapping))).toString() + citationClose
    }
    // Detect incomplete markers without confusing a rewritten, valid tag with one.
    val outside = citationTag.replace(result, "")
    require(!outside.contains(citationOpen) && !outside.contains(citationClose)) { "Incomplete memory citation tag" }
    return result
}

internal fun UIMessagePart.remapDesktopMemoryCitations(mapping: Map<Int, Int>): UIMessagePart = when (this) {
    is UIMessagePart.Text -> {
        val text = remapTags(text, mapping)
        val ids = metadata?.get(citationKey)
        val metadata = if (ids == null) metadata else JsonObject(metadata.orEmpty() + (citationKey to remapIds(ids, mapping)))
        if (text == this.text && metadata == this.metadata) this else copy(text = text, metadata = metadata)
    }
    is UIMessagePart.Tool -> {
        val output = output.map { it.remapDesktopMemoryCitations(mapping) }
        if (output == this.output) this else copy(output = output)
    }
    else -> this
}
