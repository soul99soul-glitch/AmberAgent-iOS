package app.amber.ai.provider.openai

import app.amber.ai.core.MessageRole
import app.amber.ai.core.PromptTranscript
import app.amber.ai.core.PromptTranscriptEvent
import app.amber.ai.core.PromptToolDeclaration
import app.amber.ai.core.ReasoningLevel
import app.amber.ai.core.Tool
import app.amber.ai.provider.CustomBody
import app.amber.ai.provider.CustomHeader
import app.amber.ai.provider.MIMO_API_DEFAULT_BASE_URL
import app.amber.ai.provider.Model
import app.amber.ai.provider.ModelAbility
import app.amber.ai.provider.OpenAIBrand
import app.amber.ai.provider.OpenAIAuthMode
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.provider.defaultReasoningLevel
import app.amber.ai.provider.reasoningOptions
import app.amber.ai.registry.ModelRegistry
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
    fun mimoApiAndTokenPlanUseTheDocumentedApiKeyHeader() {
        val api = setting.copy(
            brand = OpenAIBrand.MIMO,
            baseUrl = MIMO_API_DEFAULT_BASE_URL,
        )
        assertEquals(listOf(CustomHeader("api-key", "sk-test")), provider.resolveAuthenticationHeaders(api))

        val tokenPlan = api.copy(
            apiKey = "tp-test",
            authMode = OpenAIAuthMode.MIMO_CODING_PLAN,
            baseUrl = "https://token-plan-cn.xiaomimimo.com/v1",
        )
        val tokenPlanHeaders = provider.resolveAuthenticationHeaders(tokenPlan)
        assertEquals(CustomHeader("api-key", "tp-test"), tokenPlanHeaders.first())
    }

    @Test
    fun mimoChatCompletionsUsesMimoTokenLimitAndThinkingWireFormat() {
        val body = provider.buildChatCompletionRequest(
            providerSetting = setting.copy(brand = OpenAIBrand.MIMO, baseUrl = MIMO_API_DEFAULT_BASE_URL),
            messages = listOf(UIMessage.user("hello")),
            params = TextGenerationParams(
                model = reasoningModel("mimo-v2.5-pro"),
                maxTokens = 1024,
                reasoningLevel = ReasoningLevel.HIGH,
            ),
            stream = false,
        )

        assertEquals("1024", body.getValue("max_completion_tokens").jsonPrimitive.content)
        assertFalse("max_tokens" in body)
        assertEquals("enabled", body.getValue("thinking").jsonObject.getValue("type").jsonPrimitive.content)
    }

    @Test
    fun mimoResponsesOmitsOpenAiOnlyFields() {
        val body = provider.buildResponsesRequestBody(
            providerSetting = setting.copy(
                brand = OpenAIBrand.MIMO,
                baseUrl = MIMO_API_DEFAULT_BASE_URL,
                useResponseApi = true,
            ),
            messages = listOf(UIMessage.user("hello")),
            params = TextGenerationParams(
                model = reasoningModel("mimo-v2.5-pro"),
                temperature = 0.2f,
                topP = 0.9f,
                maxTokens = 1024,
                reasoningLevel = ReasoningLevel.HIGH,
            ),
            stream = false,
        )

        assertFalse("store" in body)
        assertFalse("parallel_tool_calls" in body)
        assertEquals("high", body.getValue("reasoning").jsonObject.getValue("effort").jsonPrimitive.content)
        assertFalse("summary" in body.getValue("reasoning").jsonObject)
        assertFalse("include" in body)
    }

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
    fun responsesInstructionsPreserveAllSystemMessagesInOrder() {
        val body = provider.buildResponsesRequestBody(
            providerSetting = setting,
            messages = listOf(
                UIMessage(role = MessageRole.SYSTEM, parts = listOf(UIMessagePart.Text("base rules"))),
                UIMessage(role = MessageRole.SYSTEM, parts = listOf(UIMessagePart.Text("turn rules"))),
                UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("hello"))),
            ),
            params = TextGenerationParams(model = Model(modelId = "gpt-5", displayName = "GPT-5")),
            stream = false,
        )

        assertEquals("base rules\n\nturn rules", body.getValue("instructions").jsonPrimitive.content)
    }

    @Test
    fun responsesSingleSystemMessageKeepsItsOriginalInstructions() {
        val body = provider.buildResponsesRequestBody(
            providerSetting = setting,
            messages = listOf(
                UIMessage(role = MessageRole.SYSTEM, parts = listOf(UIMessagePart.Text("one system"))),
                UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("hello"))),
            ),
            params = TextGenerationParams(model = Model(modelId = "gpt-5", displayName = "GPT-5")),
            stream = false,
        )

        assertEquals("one system", body.getValue("instructions").jsonPrimitive.content)
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
    fun codexGpt6SolAndLunaExposeReasoningAndSendSelectedEffort() {
        val codex = setting.copy(
            baseUrl = "https://chatgpt.com/backend-api/codex",
            authMode = OpenAIAuthMode.CODEX_OAUTH,
            useResponseApi = true,
        )
        for (modelId in listOf("gpt-6-sol", "gpt-6-luna")) {
            val model = Model(
                modelId = modelId,
                displayName = modelId,
                abilities = ModelRegistry.MODEL_ABILITIES.getData(modelId),
            )
            assertTrue(ModelAbility.REASONING in model.abilities, modelId)
            assertEquals(
                listOf(
                    ReasoningLevel.OFF,
                    ReasoningLevel.LOW,
                    ReasoningLevel.MEDIUM,
                    ReasoningLevel.HIGH,
                    ReasoningLevel.XHIGH,
                    ReasoningLevel.MAX,
                ),
                model.reasoningOptions(codex).map { it.level },
                modelId,
            )
            assertEquals(ReasoningLevel.MEDIUM, model.defaultReasoningLevel(codex), modelId)

            val body = provider.buildResponsesRequestBody(
                providerSetting = codex,
                messages = listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("hi")))),
                params = TextGenerationParams(model = model, reasoningLevel = ReasoningLevel.HIGH),
                stream = true,
            )
            val reasoning = body.getValue("reasoning").jsonObject
            assertEquals("high", reasoning.getValue("effort").jsonPrimitive.content, modelId)
            assertEquals("auto", reasoning.getValue("summary").jsonPrimitive.content, modelId)
        }
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

    @Test
    fun responsesTranscriptKeepsInitialToolsAndAddsLaterToolsAtTheirHistoryPoint() {
        val base = promptTool("base_tool")
        val late = promptTool("late_tool")
        val body = provider.buildResponsesRequestBody(
            providerSetting = setting.copy(useResponseApi = true),
            messages = transcriptMessages(
                PromptTranscriptEvent(
                    initial = true,
                    sections = mapOf("rules" to "base rules"),
                    toolsAdded = listOf(base),
                ),
                PromptTranscriptEvent(
                    sections = mapOf("runtime" to "turn rules"),
                    toolsAdded = listOf(late),
                ),
            ),
            params = TextGenerationParams(
                model = Model(
                    modelId = "gpt-5.5",
                    displayName = "GPT-5.5",
                    abilities = listOf(ModelAbility.TOOL),
                ),
                tools = listOf(toolFrom(base), toolFrom(late)),
            ),
            stream = false,
        )

        val topTools = body.getValue("tools").jsonArray
        assertEquals(1, topTools.size)
        assertEquals("base_tool", topTools.single().jsonObject.getValue("name").jsonPrimitive.content)

        val input = body.getValue("input").jsonArray
        val additional = input.first { it.jsonObject["type"]?.jsonPrimitive?.content == "additional_tools" }
        assertEquals(
            "late_tool",
            additional.jsonObject.getValue("tools").jsonArray.single().jsonObject
                .getValue("name").jsonPrimitive.content,
        )
        assertEquals("turn rules", input.last().jsonObject.getValue("content").jsonPrimitive.content
            .substringAfter("<amber_section name=\"runtime\">\n")
            .substringBefore("\n</amber_section>"))
    }

    @Test
    fun codexGpt55ReplaysLateToolsThroughClientToolSearch() {
        val base = promptTool("base_tool")
        val late = promptTool("late_tool")
        val body = provider.buildResponsesRequestBody(
            providerSetting = setting.copy(
                baseUrl = "https://chatgpt.com/backend-api/codex",
                authMode = OpenAIAuthMode.CODEX_OAUTH,
                useResponseApi = true,
            ),
            messages = transcriptMessages(
                PromptTranscriptEvent(initial = true, sections = mapOf("rules" to "base"), toolsAdded = listOf(base)),
                PromptTranscriptEvent(toolsAdded = listOf(late)),
            ),
            params = TextGenerationParams(
                model = Model(
                    modelId = "gpt-5.5",
                    displayName = "GPT-5.5",
                    abilities = listOf(ModelAbility.TOOL),
                ),
                tools = listOf(toolFrom(base), toolFrom(late)),
            ),
            stream = false,
        )

        assertTrue(body.getValue("stream").jsonPrimitive.boolean)
        val input = body.getValue("input").jsonArray
        val searchOutput = input.first { it.jsonObject["type"]?.jsonPrimitive?.content == "tool_search_output" }
        assertTrue(searchOutput.jsonObject.getValue("tools").jsonArray.single().jsonObject
            .getValue("defer_loading").jsonPrimitive.boolean)
        assertTrue(input.any { it.jsonObject["type"]?.jsonPrimitive?.content == "tool_search_call" })
    }

    @Test
    fun toolOnlyTranscriptEventDoesNotEmitAnEmptySystemItem() {
        val body = provider.buildResponsesRequestBody(
            providerSetting = setting.copy(useResponseApi = true),
            messages = transcriptMessages(
                PromptTranscriptEvent(initial = true, sections = mapOf("rules" to "base")),
                PromptTranscriptEvent(toolsAdded = listOf(promptTool("late_tool"))),
            ),
            params = TextGenerationParams(
                model = Model(
                    modelId = "gpt-5.5",
                    displayName = "GPT-5.5",
                    abilities = listOf(ModelAbility.TOOL),
                ),
                tools = listOf(toolFrom(promptTool("late_tool"))),
            ),
            stream = false,
        )

        val input = body.getValue("input").jsonArray
        assertTrue(input.any { it.jsonObject["type"]?.jsonPrimitive?.content == "additional_tools" })
        assertFalse(input.any { it.jsonObject["role"]?.jsonPrimitive?.content == "system" })
        assertFalse(body.getValue("parallel_tool_calls").jsonPrimitive.boolean)
    }

    @Test
    fun nativeTranscriptKeepsUnmarkedLaterSystemMessageInline() {
        val initial = PromptTranscript.message(
            PromptTranscriptEvent(initial = true, sections = mapOf("rules" to "base")),
        )
        val body = provider.buildResponsesRequestBody(
            providerSetting = setting.copy(useResponseApi = true),
            messages = listOf(
                initial,
                UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("hello"))),
                UIMessage.system("guard finalization"),
            ),
            params = TextGenerationParams(model = Model(modelId = "gpt-5.5", displayName = "GPT-5.5")),
            stream = false,
        )

        assertEquals("<amber_section name=\"rules\">\nbase\n</amber_section>", body.getValue("instructions").jsonPrimitive.content)
        assertTrue(body.getValue("input").jsonArray.any {
            it.jsonObject["content"]?.jsonPrimitive?.content == "guard finalization"
        })
    }

    @Test
    fun moonshotK3AddsToolsAsSystemMessageWithoutChangingInitialTopLevelTools() {
        val base = promptTool("base_tool")
        val late = promptTool("late_tool")
        val body = provider.buildChatCompletionRequest(
            providerSetting = setting.copy(
                baseUrl = "https://api.moonshot.ai/v1",
                brand = OpenAIBrand.KIMI,
            ),
            messages = transcriptMessages(
                PromptTranscriptEvent(initial = true, sections = mapOf("rules" to "base"), toolsAdded = listOf(base)),
                PromptTranscriptEvent(toolsAdded = listOf(late)),
            ),
            params = TextGenerationParams(
                model = Model(
                    modelId = "kimi-k3",
                    displayName = "Kimi K3",
                    abilities = listOf(ModelAbility.TOOL),
                ),
                tools = listOf(toolFrom(base), toolFrom(late)),
            ),
            stream = false,
        )

        assertEquals("base_tool", body.getValue("tools").jsonArray.single().jsonObject
            .getValue("function").jsonObject.getValue("name").jsonPrimitive.content)
        val wireMessages = body.getValue("messages").jsonArray
        val addition = wireMessages.first { it.jsonObject["tools"] != null }
        assertEquals("late_tool", addition.jsonObject.getValue("tools").jsonArray.single().jsonObject
            .getValue("function").jsonObject.getValue("name").jsonPrimitive.content)
    }

    @Test
    fun transcriptRemovalFallsBackToCurrentToolsAndSuppressesInlineAdditions() {
        val base = promptTool("base_tool")
        val body = provider.buildResponsesRequestBody(
            providerSetting = setting.copy(useResponseApi = true),
            messages = transcriptMessages(
                PromptTranscriptEvent(initial = true, sections = mapOf("rules" to "base"), toolsAdded = listOf(base)),
                PromptTranscriptEvent(toolsRemoved = listOf("base_tool")),
            ),
            params = TextGenerationParams(
                model = Model(
                    modelId = "gpt-5.5",
                    displayName = "GPT-5.5",
                    abilities = listOf(ModelAbility.TOOL),
                ),
            ),
            stream = false,
        )

        assertTrue("tools" !in body)
        assertTrue(body.getValue("input").jsonArray.none {
            it.jsonObject["type"]?.jsonPrimitive?.content == "additional_tools"
        })
    }

    @Test
    fun restoredTranscriptKeepsTheActualResponsesWirePrefix() {
        val initialTool = toolFrom(promptTool("base_tool"))
        val lateTool = toolFrom(promptTool("late_tool"))
        val model = Model(modelId = "gpt-5.5", abilities = listOf(ModelAbility.TOOL))
        val user = UIMessage.user("hello")
        val first = PromptTranscript.prepare(listOf(user), listOf(PromptTranscript.sectionMessage("rules", "A"), user), listOf(initialTool))
        val firstBody = provider.buildResponsesRequestBody(setting.copy(useResponseApi = true), first.messages,
            TextGenerationParams(model = model, tools = listOf(initialTool)), false)
        val reply = PromptTranscript.recordResponse(UIMessage.assistant("ready"), first)
        val history = listOf(user, reply, UIMessage.user("change"))
        val next = PromptTranscript.prepare(history, listOf(PromptTranscript.sectionMessage("rules", "B")) + history, listOf(initialTool, lateTool))
        val nextBody = provider.buildResponsesRequestBody(setting.copy(useResponseApi = true), next.messages,
            TextGenerationParams(model = model, tools = listOf(initialTool, lateTool)), false)
        assertEquals(firstBody["instructions"], nextBody["instructions"])
        assertEquals(firstBody["tools"], nextBody["tools"])
        assertEquals(firstBody.getValue("input").jsonArray, nextBody.getValue("input").jsonArray.take(1))
    }

    @Test
    fun modelWithoutToolAbilityCannotActivateHistoricalInlineTools() {
        val late = promptTool("late_tool")
        val body = provider.buildResponsesRequestBody(
            setting.copy(useResponseApi = true),
            transcriptMessages(PromptTranscriptEvent(initial = true), PromptTranscriptEvent(toolsAdded = listOf(late))),
            TextGenerationParams(model = Model(modelId = "gpt-5.5"), tools = listOf(toolFrom(late))),
            false,
        )
        assertFalse("tools" in body)
        assertFalse(body.getValue("input").jsonArray.any { it.jsonObject["type"]?.jsonPrimitive?.content == "additional_tools" })
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

    private fun promptTool(name: String): PromptToolDeclaration = PromptToolDeclaration(
        name = name,
        description = "$name description",
    )

    private fun toolFrom(declaration: PromptToolDeclaration): Tool = Tool(
        name = declaration.name,
        description = declaration.description,
        execute = { emptyList() },
    )

    private fun transcriptMessages(vararg events: PromptTranscriptEvent): List<UIMessage> = buildList {
        events.firstOrNull()?.let { add(PromptTranscript.message(it)) }
        add(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("hello"))))
        events.drop(1).forEach { add(PromptTranscript.message(it)) }
    }
}
