package shared

import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.ui.UIMessage
import app.amber.core.agent.utils.JsonInstant
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
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
    // Null identifies legacy payloads; an empty list is a valid empty run baseline.
    val runDisplayBaseline: List<UIMessage>? = null,
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
        runDisplayBaseline: List<UIMessage>? = null,
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
            runDisplayBaseline = runDisplayBaseline,
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
