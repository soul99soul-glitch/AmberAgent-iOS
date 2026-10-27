package shared

import app.amber.ai.core.InputSchema
import app.amber.ai.core.Tool
import app.amber.ai.provider.BuiltInTools
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.core.agent.utils.JsonInstant
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.encodeToJsonElement
import kotlin.uuid.ExperimentalUuidApi

/** Swift JSON bridge for message parts and durable tool-result payloads. */
object IosToolOutputJsonBridge {
    fun encode(parts: List<UIMessagePart>): String = JsonInstant.encodeToString(parts)

    // Swift dictionaries bridge as ordinary maps, not Kotlin JsonObject instances.
    // Rebuild the JSON owner before a text part reaches serializers or providers.
    fun textPart(text: String, metadata: Map<String, JsonElement>?): UIMessagePart.Text =
        UIMessagePart.Text(text = text, metadata = metadata?.let { JsonObject(it) })

    fun metadataString(part: UIMessagePart, key: String): String? =
        (part.metadata?.get(key) as? JsonPrimitive)?.contentOrNull

    // Existing nested JSON must stay in Kotlin: Foundation bridges objects and
    // arrays as collections, which cannot return through a JsonElement dictionary.
    fun mergeTextMetadata(part: UIMessagePart.Text, updates: Map<String, String>): UIMessagePart.Text {
        if (updates.isEmpty()) return part
        val metadata = JsonObject(part.metadata.orEmpty() + updates.mapValues { JsonPrimitive(it.value) })
        return if (metadata == part.metadata) part else part.copy(metadata = metadata)
    }

    // Keep JsonObject/JsonArray access in Kotlin; Foundation collection bridges
    // do not preserve their JSON-specific type when Swift reconstructs them.
    fun metadataJson(part: UIMessagePart): String? = part.metadata?.toString()

    @Throws(Throwable::class)
    fun decode(json: String): List<UIMessagePart> = JsonInstant.decodeFromString(json)
}

@Serializable
private data class IosRequestToolSnapshot(
    val name: String,
    val description: String,
    val parameters: InputSchema?,
    val needsApproval: Boolean,
    val allowsAutoApproval: Boolean,
    val mandatoryApproval: Boolean,
)

@Serializable
private data class IosRequestGenerationParamsSnapshot(
    val modelId: String,
    val modelDisplayName: String,
    val modelType: String,
    val inputModalities: List<String>,
    val outputModalities: List<String>,
    val abilities: List<String>,
    val builtInTools: List<String>,
    val contextWindowTokens: Int?,
    val temperature: Float?,
    val topP: Float?,
    val maxTokens: Int?,
    val reasoningLevel: String,
)

/** Canonical, secret-free material used by iOS to hash a logical provider request. */
@OptIn(ExperimentalUuidApi::class)
object IosRunRequestSnapshotJsonBridge {
    fun encodeMessages(messages: List<UIMessage>): String = JsonInstant.encodeToString(messages)

    fun encodeGenerationParams(params: TextGenerationParams): String = JsonInstant.encodeToString(
        IosRequestGenerationParamsSnapshot(
            modelId = params.model.modelId,
            modelDisplayName = params.model.displayName,
            modelType = params.model.type.name,
            inputModalities = params.model.inputModalities.map { it.name },
            outputModalities = params.model.outputModalities.map { it.name },
            abilities = params.model.abilities.map { it.name }.sorted(),
            builtInTools = params.model.tools.map { tool ->
                when (tool) {
                    BuiltInTools.Search -> "search"
                    BuiltInTools.UrlContext -> "url_context"
                    BuiltInTools.ImageGeneration -> "image_generation"
                }
            }.sorted(),
            contextWindowTokens = params.model.contextWindowTokens,
            temperature = params.temperature,
            topP = params.topP,
            maxTokens = params.maxTokens,
            reasoningLevel = params.reasoningLevel.name,
        )
    )

    fun encodeToolCatalog(tools: List<Tool>): String = canonicalJson(
        JsonInstant.encodeToJsonElement(tools.sortedBy { it.name }.map { tool ->
            IosRequestToolSnapshot(
                name = tool.name,
                description = tool.description,
                parameters = tool.parameters(),
                needsApproval = tool.needsApproval,
                allowsAutoApproval = tool.allowsAutoApproval,
                mandatoryApproval = tool.mandatoryApproval,
            )
        })
    ).toString()

    private fun canonicalJson(element: JsonElement): JsonElement = when (element) {
        is JsonObject -> JsonObject(element.entries.sortedBy { it.key }.associate { (key, value) ->
            key to canonicalJson(value)
        })
        is JsonArray -> JsonArray(element.map(::canonicalJson))
        else -> element
    }
}
