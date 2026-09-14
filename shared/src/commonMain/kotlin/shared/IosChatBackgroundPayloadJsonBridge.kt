package shared

import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.provider.BuiltInTools
import app.amber.ai.core.InputSchema
import app.amber.ai.core.Tool
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.core.agent.utils.JsonInstant
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlin.uuid.ExperimentalUuidApi
import kotlin.uuid.Uuid

@OptIn(ExperimentalUuidApi::class)
@Serializable
data class IosChatBackgroundPayload(
    val runId: String,
    val startedAt: Long,
    val inputDigest: String,
    val conversationId: Uuid,
    val providerId: String,
    val params: TextGenerationParams,
    val uploadMessages: List<UIMessage>,
    val displayMessages: List<UIMessage>,
    val mode: String = "continue_model",
    val responseId: String? = null,
    val responseSequenceNumber: Long? = null,
    val generativeUiRequired: Boolean = false,
    val generativeUiExpectSlides: Boolean = false,
    val generativeUiExpectFullHtmlDeck: Boolean = false,
    val generativeUiFallbackAttempted: Boolean = false,
    // P0-a Fix C: full catalog tool names so the background job can rebuild a
    // lazy-mode exposure bridge (handoff.params.tools only carries the visible
    // subset ≤40, which would silently disable lazy mode). Legacy payloads
    // without this field decode as empty and fall back to params.tools.
    val fullToolNames: List<String> = emptyList(),
    // Executable Tool declarations contain Kotlin function fields and cannot
    // be serialized. Persist only the visible names; Swift rebuilds the same
    // static/dynamic declarations before resuming the background run.
    val visibleToolNames: List<String> = emptyList(),
    val executionPolicyJson: String? = null,
    val subAgentTimeoutSeconds: Double? = null,
)

/** Swift-facing bridge for persisted iOS chat background generation payloads. */
@OptIn(ExperimentalUuidApi::class)
object IosChatBackgroundPayloadJsonBridge {
    fun encode(
        runId: String,
        startedAt: Long,
        inputDigest: String,
        conversationId: Uuid,
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        uploadMessages: List<UIMessage>,
        displayMessages: List<UIMessage>,
        mode: String = "continue_model",
        responseId: String? = null,
        responseSequenceNumber: Long? = null,
        generativeUiRequired: Boolean = false,
        generativeUiExpectSlides: Boolean = false,
        generativeUiExpectFullHtmlDeck: Boolean = false,
        generativeUiFallbackAttempted: Boolean = false,
        fullToolNames: List<String> = emptyList(),
        executionPolicyJson: String? = null,
        subAgentTimeoutSeconds: Double? = null,
    ): String = JsonInstant.encodeToString(
        IosChatBackgroundPayload(
            runId = runId,
            startedAt = startedAt,
            inputDigest = inputDigest,
            conversationId = conversationId,
            providerId = providerSetting.id.toString(),
            params = params.withoutSecrets(),
            uploadMessages = uploadMessages,
            displayMessages = displayMessages,
            mode = mode,
            responseId = responseId,
            responseSequenceNumber = responseSequenceNumber,
            generativeUiRequired = generativeUiRequired,
            generativeUiExpectSlides = generativeUiExpectSlides,
            generativeUiExpectFullHtmlDeck = generativeUiExpectFullHtmlDeck,
            generativeUiFallbackAttempted = generativeUiFallbackAttempted,
            fullToolNames = fullToolNames,
            visibleToolNames = params.tools.map { it.name },
            executionPolicyJson = executionPolicyJson,
            subAgentTimeoutSeconds = subAgentTimeoutSeconds,
        )
    )

    // @Throws 必须声明：Kotlin/Native 不会把未声明的异常桥接成 Swift NSError，
    // 否则损坏的 handoff payload 会让冷启动恢复 SIGABRT 而非回退 nil（见 loadHandoff 的 do/catch）。
    @Throws(Throwable::class)
    fun decode(json: String): IosChatBackgroundPayload = JsonInstant.decodeFromString(json)

    private fun TextGenerationParams.withoutSecrets(): TextGenerationParams = copy(
        model = model.copy(
            customHeaders = emptyList(),
            customBodies = emptyList(),
            providerOverwrite = null,
        ),
        customHeaders = emptyList(),
        customBody = emptyList(),
        tools = emptyList(),
    )
}

/** Swift bridge for the short-lived durable tool-result payload. */
object IosToolOutputJsonBridge {
    fun encode(parts: List<UIMessagePart>): String = JsonInstant.encodeToString(parts)

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
