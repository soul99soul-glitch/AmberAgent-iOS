@file:OptIn(kotlin.uuid.ExperimentalUuidApi::class)

package desktop

import app.amber.ai.core.ReasoningLevel
import app.amber.ai.provider.CustomHeader
import app.amber.ai.provider.CustomBody
import app.amber.ai.provider.Modality
import app.amber.ai.provider.GoogleAuthMode
import app.amber.ai.provider.Model
import app.amber.ai.provider.ModelAbility
import app.amber.ai.provider.OpenAIAuthMode
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.registry.ModelRegistry
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlin.uuid.Uuid

private val modelJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }

@Serializable
internal data class DesktopModelOptions(
    val id: String,
    val modelID: String,
    val name: String = "",
    val enabled: Boolean = true,
    val contextWindowTokens: Int? = null,
    val temperature: Float? = null,
    val maxOutputTokens: Int? = null,
    val reasoning: ReasoningLevel = ReasoningLevel.OFF,
    val customHeaders: Map<String, String> = emptyMap(),
    val customBody: String? = null,
    val supportsVision: Boolean? = null,
)

@Serializable
internal data class DesktopCatalogModel(
    val modelID: String,
    val name: String,
    val contextWindowTokens: Int? = null,
    val supportsVision: Boolean? = null,
)

internal fun desktopModelParams(json: String): TextGenerationParams {
    val options = modelJson.decodeFromString<DesktopModelOptions>(json)
    require(options.enabled) { "Model is disabled" }
    require(options.modelID.isNotBlank()) { "Model ID is required" }
    require(options.contextWindowTokens == null || options.contextWindowTokens > 0) { "Context window must be positive" }
    require(options.maxOutputTokens == null || options.maxOutputTokens > 0) { "Output token limit must be positive" }
    require(options.temperature == null || (options.temperature.isFinite() && options.temperature in 0f..2f)) { "Temperature must be between zero and two" }
    val wireID = options.modelID.trim()
    val abilities = ModelRegistry.MODEL_ABILITIES.getData(wireID).toMutableSet()
    // Tools are attached only when the user enables agent tools; the registry must not silently drop them
    // for model IDs it does not recognise (gateway aliases, new releases).
    abilities += ModelAbility.TOOL
    if (options.reasoning.isEnabled) abilities += ModelAbility.REASONING
    val inputModalities = ModelRegistry.MODEL_INPUT_MODALITIES.getData(wireID).toMutableSet()
    when (options.supportsVision) {
        true -> inputModalities += Modality.IMAGE
        false -> inputModalities -= Modality.IMAGE
        null -> Unit
    }
    val headers = options.customHeaders.map { (name, value) ->
        require(name.isNotBlank() && name.all { it.isLetterOrDigit() && it.code < 128 || it in "!#$%&'*+-.^_`|~" }) { "Invalid header name" }
        require('\r' !in value && '\n' !in value) { "Invalid header value" }
        CustomHeader(name, value)
    }
    val body = options.customBody?.takeIf { it.isNotBlank() }?.let {
        modelJson.parseToJsonElement(it) as? JsonObject ?: error("Custom body must be a JSON object")
    }
    return TextGenerationParams(
        model = Model(
            id = Uuid.parse(options.id), modelId = wireID,
            displayName = options.name.ifBlank { wireID },
            inputModalities = inputModalities.toList(),
            outputModalities = ModelRegistry.MODEL_OUTPUT_MODALITIES.getData(wireID),
            abilities = abilities.toList(),
            contextWindowTokens = options.contextWindowTokens ?: ModelRegistry.MODEL_CONTEXT_WINDOW.getData(wireID),
        ),
        temperature = options.temperature, maxTokens = options.maxOutputTokens, reasoningLevel = options.reasoning,
        customHeaders = headers, customBody = body?.map { (key, value) -> CustomBody(key, value) }.orEmpty(),
    )
}

internal fun desktopCatalogJSON(models: List<Model>): String = modelJson.encodeToString(models.map { model ->
    DesktopCatalogModel(model.modelId, model.displayName.ifBlank { model.modelId },
        model.contextWindowTokens ?: ModelRegistry.MODEL_CONTEXT_WINDOW.getData(model.modelId),
        Modality.IMAGE in model.inputModalities || Modality.IMAGE in ModelRegistry.MODEL_INPUT_MODALITIES.getData(model.modelId))
}.distinctBy { it.modelID })

internal fun desktopAuthenticatedConfiguration(kind: String, id: String, name: String, baseUrl: String,
    apiKey: String, authMode: String): ProviderSetting {
    val provider = DesktopProviderBridge.configuration(kind, id, name, baseUrl, apiKey)
    return when (authMode) {
        "apiKey" -> provider
        "codexOAuth" -> {
            require(provider is ProviderSetting.OpenAI && kind == "responses") { "Codex OAuth requires Responses protocol" }
            provider.copy(authMode = OpenAIAuthMode.CODEX_OAUTH, useResponseApi = true)
        }
        "grokOAuth" -> {
            require(provider is ProviderSetting.OpenAI && kind == "openai") { "Grok OAuth requires OpenAI-compatible protocol" }
            provider
        }
        "antigravityOAuth" -> {
            require(provider is ProviderSetting.Google) { "Antigravity OAuth requires Gemini protocol" }
            provider.copy(authMode = GoogleAuthMode.ANTIGRAVITY_OAUTH)
        }
        else -> error("Unsupported authentication mode")
    }
}

internal fun desktopCodexHeaders(params: TextGenerationParams, accountID: String?, originator: String): TextGenerationParams {
    val reserved = setOf("openai-beta", "originator", "chatgpt-account-id")
    return params.copy(customHeaders = params.customHeaders.filterNot { it.name.lowercase() in reserved } + buildList {
        add(CustomHeader("OpenAI-Beta", "responses=experimental"))
        add(CustomHeader("originator", originator))
        if (!accountID.isNullOrBlank()) add(CustomHeader("ChatGPT-Account-Id", accountID))
    })
}
