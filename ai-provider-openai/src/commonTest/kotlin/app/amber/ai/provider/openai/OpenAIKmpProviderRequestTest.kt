package app.amber.ai.provider.openai

import app.amber.ai.core.MessageRole
import app.amber.ai.core.ReasoningLevel
import app.amber.ai.core.Tool
import app.amber.ai.provider.Model
import app.amber.ai.provider.CustomBody
import app.amber.ai.provider.ModelAbility
import app.amber.ai.provider.OpenAIBrand
import app.amber.ai.provider.OpenAIAuthMode
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class OpenAIKmpProviderRequestTest {
    private val provider = OpenAIKmpProvider()
    private val setting = ProviderSetting.OpenAI(
        apiKey = "sk-test",
        baseUrl = "https://api.openai.com/v1",
    )

    @Test
    fun chatCompletionsToolsDisableParallelToolCalls() {
        val body = provider.buildChatCompletionRequest(
            providerSetting = setting,
            messages = listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("weather?")))),
            params = TextGenerationParams(model = toolModel(), tools = listOf(testTool())),
            stream = false,
        )

        assertFalse(body.getValue("parallel_tool_calls").jsonPrimitive.boolean)
    }

    @Test
    fun responsesToolsDisableParallelToolCalls() {
        val body = provider.buildResponsesRequestBody(
            providerSetting = setting,
            messages = listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("weather?")))),
            params = TextGenerationParams(model = toolModel(), tools = listOf(testTool())),
            stream = false,
        )

        assertFalse(body.getValue("parallel_tool_calls").jsonPrimitive.boolean)
    }

    @Test
    fun siliconFlowThinkingModelWithoutAbilityStillReceivesDisableThinking() {
        val body = provider.buildChatCompletionRequest(
            providerSetting = setting.copy(baseUrl = "https://api.siliconflow.cn/v1"),
            messages = listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("sync")))),
            params = TextGenerationParams(
                model = Model(
                    modelId = "deepseek-ai/DeepSeek-V4-Flash",
                    displayName = "DeepSeek V4 Flash",
                ),
                reasoningLevel = ReasoningLevel.OFF,
            ),
            stream = false,
        )

        assertFalse(body.getValue("enable_thinking").jsonPrimitive.boolean)
    }

    @Test
    fun siliconFlowThinkingModelWithoutAbilityDoesNotForceEnableThinking() {
        val body = provider.buildChatCompletionRequest(
            providerSetting = setting.copy(baseUrl = "https://api.siliconflow.cn/v1"),
            messages = listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("chat")))),
            params = TextGenerationParams(
                model = Model(
                    modelId = "deepseek-ai/DeepSeek-V4-Flash",
                    displayName = "DeepSeek V4 Flash",
                ),
                reasoningLevel = ReasoningLevel.AUTO,
            ),
            stream = false,
        )

        assertFalse("enable_thinking" in body)
    }

    @Test
    fun kimiK3SendsReasoningEffortWithoutThinkingObject() {
        val body = provider.buildChatCompletionRequest(
            providerSetting = setting.copy(
                brand = OpenAIBrand.KIMI,
                baseUrl = "https://api.kimi.com/coding/v1",
            ),
            messages = listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("hi")))),
            params = TextGenerationParams(
                model = reasoningModel("kimi-k3"),
                reasoningLevel = ReasoningLevel.HIGH,
            ),
            stream = false,
        )
        assertFalse("thinking" in body)
        assertEquals("high", body.getValue("reasoning_effort").jsonPrimitive.content)
    }

    @Test
    fun deepSeekV4SendsLowEffort() {
        val body = provider.buildChatCompletionRequest(
            providerSetting = setting.copy(
                brand = OpenAIBrand.DEEPSEEK,
                baseUrl = "https://api.deepseek.com/v1",
            ),
            messages = listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("hi")))),
            params = TextGenerationParams(
                model = reasoningModel("deepseek-v4-pro"),
                reasoningLevel = ReasoningLevel.LOW,
            ),
            stream = false,
        )
        assertEquals("enabled", body.getValue("thinking").jsonObject.getValue("type").jsonPrimitive.content)
        assertEquals("low", body.getValue("reasoning_effort").jsonPrimitive.content)
    }

    @Test
    fun glm53NeverSendsDisabledThinking() {
        val body = provider.buildChatCompletionRequest(
            providerSetting = setting.copy(
                brand = OpenAIBrand.ZHIPU,
                baseUrl = "https://open.bigmodel.cn/api/paas/v4",
            ),
            messages = listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("hi")))),
            params = TextGenerationParams(
                model = reasoningModel("glm-5.3"),
                reasoningLevel = ReasoningLevel.OFF,
            ),
            stream = false,
        )
        assertEquals("enabled", body.getValue("thinking").jsonObject.getValue("type").jsonPrimitive.content)
        assertEquals("low", body.getValue("reasoning_effort").jsonPrimitive.content)
    }

    @Test
    fun museSparkUsesResponsesEvenWhenProviderStaysOnCompletions() {
        val go = setting.copy(
            baseUrl = "https://opencode.ai/zen/go/v1",
            useResponseApi = false,
        )
        assertTrue(usesOpenAIResponsesApi(go, "muse-spark-1.2-contributor"))
        assertTrue(usesOpenAIResponsesApi(go, "muse-spark-1.2"))
        assertTrue(usesOpenAIResponsesApi(go, "opencode-go/muse-spark-1.2-contributor"))
        assertFalse(usesOpenAIResponsesApi(go, "deepseek-v4-flash"))
        assertFalse(usesOpenAIResponsesApi(go, "mimo-v2.5"))
        assertTrue(usesOpenAIResponsesApi(go.copy(useResponseApi = true), "deepseek-v4-flash"))
    }

    @Test
    fun grokCliProxyResponsesOmitsEncryptedContentAndUsesGrokEffort() {
        val body = provider.buildResponsesRequestBody(
            providerSetting = setting.copy(baseUrl = "https://cli-chat-proxy.grok.com/v1"),
            messages = listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("hi")))),
            params = TextGenerationParams(
                model = reasoningModel("grok-4.6"),
                reasoningLevel = ReasoningLevel.XHIGH,
            ),
            stream = true,
        )
        val reasoning = body.getValue("reasoning").jsonObject
        assertEquals("xhigh", reasoning.getValue("effort").jsonPrimitive.content)
        assertFalse("summary" in reasoning)
        assertFalse("include" in body)
    }

    @Test
    fun openAiChatCompletionsKeepsXhigh() {
        val body = provider.buildChatCompletionRequest(
            providerSetting = setting,
            messages = listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("hi")))),
            params = TextGenerationParams(
                model = reasoningModel("gpt-5.6"),
                reasoningLevel = ReasoningLevel.XHIGH,
            ),
            stream = false,
        )
        assertEquals("xhigh", body.getValue("reasoning_effort").jsonPrimitive.content)
    }

    @Test
    fun codexAstraResponsesOmitSamplingAndMapOffToLow() {
        val codex = setting.copy(
            baseUrl = "https://chatgpt.com/backend-api/codex",
            authMode = OpenAIAuthMode.CODEX_OAUTH,
            useResponseApi = true,
        )
        val body = provider.buildResponsesRequestBody(
            providerSetting = codex,
            messages = listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("hi")))),
            params = TextGenerationParams(
                model = reasoningModel("gpt-6-astra"),
                temperature = 0.2f,
                topP = 0.9f,
                maxTokens = 1200,
                reasoningLevel = ReasoningLevel.OFF,
                customBody = listOf(CustomBody("max_output_tokens", JsonPrimitive(1200)), CustomBody("stream", JsonPrimitive(false))),
            ),
            stream = false,
        )

        assertTrue(usesOpenAIResponsesApi(codex, "gpt-6-astra"))
        assertTrue(body.getValue("stream").jsonPrimitive.boolean)
        assertFalse("temperature" in body)
        assertFalse("top_p" in body)
        assertFalse("max_output_tokens" in body)
        assertEquals("low", body.getValue("reasoning").jsonObject.getValue("effort").jsonPrimitive.content)

        val apiBody = provider.buildResponsesRequestBody(
            providerSetting = setting.copy(useResponseApi = true),
            messages = listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("hi")))),
            params = TextGenerationParams(model = reasoningModel("gpt-6-astra"), maxTokens = 1200),
            stream = false,
        )
        assertFalse(apiBody.getValue("stream").jsonPrimitive.boolean)
        assertEquals("1200", apiBody.getValue("max_output_tokens").jsonPrimitive.content)
    }

    @Test
    fun toolOutputImagesReachBothOpenAiRequestFormats() {
        val imageUrl = "data:image/jpeg;base64,/9j/2Q=="
        val messages = listOf(UIMessage(
            role = MessageRole.ASSISTANT,
            parts = listOf(UIMessagePart.Tool(
                toolCallId = "call_picker",
                toolName = "photos_pick",
                input = "{}",
                output = listOf(
                    UIMessagePart.Image(url = imageUrl),
                    UIMessagePart.Text("{\"ok\":true}"),
                ),
            )),
        ))

        val chatMessages = provider.buildChatCompletionRequest(
            providerSetting = setting,
            messages = messages,
            params = TextGenerationParams(model = toolModel(), tools = listOf(testTool())),
        ).getValue("messages").jsonArray
        assertTrue(chatMessages.last().toString().contains(imageUrl))

        val responsesInput = provider.buildResponsesRequestBody(
            providerSetting = setting,
            messages = messages,
            params = TextGenerationParams(model = toolModel(), tools = listOf(testTool())),
            stream = false,
        ).getValue("input").jsonArray
        assertTrue(responsesInput.last().toString().contains(imageUrl))
    }

    private fun reasoningModel(modelId: String): Model = Model(
        modelId = modelId,
        displayName = modelId,
        abilities = listOf(ModelAbility.REASONING),
    )

    private fun toolModel(): Model = Model(
        modelId = "gpt-5",
        displayName = "GPT-5",
        abilities = listOf(ModelAbility.TOOL),
    )

    private fun testTool(): Tool = Tool(
        name = "get_weather",
        description = "Get the weather",
        parameters = {
            app.amber.ai.core.InputSchema.Obj(
                properties = buildJsonObject { },
                required = emptyList(),
            )
        },
        execute = { emptyList() },
    )
}
