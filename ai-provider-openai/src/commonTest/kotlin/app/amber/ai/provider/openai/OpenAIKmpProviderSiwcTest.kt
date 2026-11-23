package app.amber.ai.provider.openai

import app.amber.ai.core.InputSchema
import app.amber.ai.core.MessageRole
import app.amber.ai.core.PromptTranscript
import app.amber.ai.core.PromptTranscriptEvent
import app.amber.ai.core.ReasoningLevel
import app.amber.ai.core.Tool
import app.amber.ai.provider.CustomBody
import app.amber.ai.provider.CustomHeader
import app.amber.ai.provider.Model
import app.amber.ai.provider.ModelAbility
import app.amber.ai.provider.OpenAIAuthMode
import app.amber.ai.provider.OpenAIBrand
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class OpenAIKmpProviderSiwcTest {
    private val provider = OpenAIKmpProvider()

    private val siwcSetting = ProviderSetting.OpenAI(
        apiKey = "siwc-access-token",
        baseUrl = "https://api.openai.com/v1",
        useResponseApi = false,
        authMode = OpenAIAuthMode.CHATGPT_SIWC,
        brand = OpenAIBrand.OPENAI,
    )

    private fun testModel(abilities: List<ModelAbility> = listOf(ModelAbility.TOOL)): Model = Model(
        modelId = "gpt-5.4",
        displayName = "GPT-5.4",
        abilities = abilities,
    )

    private fun testFunctionTool(): Tool = Tool(
        name = "get_weather",
        description = "Look up weather",
        parameters = { InputSchema.Obj(properties = buildJsonObject { }, required = emptyList()) },
        execute = { emptyList() },
    )

    @Test
    fun siwcAlwaysUsesResponsesApiEvenWhenUseResponseApiIsFalse() {
        assertTrue(usesOpenAIResponsesApi(siwcSetting, "gpt-5.4"))
        assertTrue(usesOpenAIResponsesApi(siwcSetting, "gpt-4o"))
    }

    @Test
    fun siwcUsesOnlyTheSelectedBearerForAuthentication() {
        val requestId = CustomHeader("X-Client-Request-ID", "test-id")
        val headers = provider.resolveAuthenticationHeaders(siwcSetting, listOf(
            CustomHeader("authorization", "stale"), CustomHeader("ChatGPT-Account-Id", "old"), requestId,
        ))
        assertEquals(listOf(CustomHeader("Authorization", "Bearer siwc-access-token"), requestId), headers)
    }

    @Test
    fun siwcRequestForcesStoreFalseStreamTrueAndStripsUnsupportedPreviewFields() {
        val customBodies = listOf(
            CustomBody("background", JsonPrimitive(true)),
            CustomBody("conversation", JsonPrimitive("conv_123")),
            CustomBody("max_output_tokens", JsonPrimitive(4096)),
            CustomBody("max_tool_calls", JsonPrimitive(5)),
            CustomBody("metadata", buildJsonObject { put("k", "v") }),
            CustomBody("moderation", JsonPrimitive("auto")),
            CustomBody("multi_agent", JsonPrimitive(true)),
            CustomBody("previous_response_id", JsonPrimitive("resp_old")),
            CustomBody("prompt", buildJsonObject { put("id", "pmpt_1") }),
            CustomBody("prompt_cache_retention", JsonPrimitive("24h")),
            CustomBody("safety_identifier", JsonPrimitive("safe_1")),
            CustomBody("temperature", JsonPrimitive(0.7)),
            CustomBody("top_logprobs", JsonPrimitive(3)),
            CustomBody("top_p", JsonPrimitive(0.95)),
            CustomBody("truncation", JsonPrimitive("auto")),
            CustomBody("user", JsonPrimitive("user_1")),
            CustomBody("store", JsonPrimitive(true)),
            CustomBody("stream", JsonPrimitive(false)),
        )

        val body = provider.buildResponsesRequestBody(
            providerSetting = siwcSetting,
            messages = listOf(
                UIMessage(role = MessageRole.SYSTEM, parts = listOf(UIMessagePart.Text("Be helpful."))),
                UIMessage.user("Hello"),
            ),
            params = TextGenerationParams(
                model = Model(modelId = "gpt-4.1", displayName = "GPT-4.1", abilities = listOf(ModelAbility.TOOL)),
                temperature = 0.5f,
                topP = 0.8f,
                maxTokens = 2048,
                tools = listOf(testFunctionTool()),
                reasoningLevel = ReasoningLevel.OFF,
                customBody = customBodies,
            ),
            stream = false,
        )

        assertEquals(false, body.getValue("store").jsonPrimitive.boolean)
        assertEquals(true, body.getValue("stream").jsonPrimitive.boolean)
        assertEquals("Be helpful.", body.getValue("instructions").jsonPrimitive.content)

        val forbidden = listOf(
            "background",
            "conversation",
            "max_output_tokens",
            "max_tool_calls",
            "metadata",
            "moderation",
            "multi_agent",
            "previous_response_id",
            "prompt",
            "prompt_cache_retention",
            "safety_identifier",
            "temperature",
            "top_logprobs",
            "top_p",
            "truncation",
            "user",
        )
        forbidden.forEach { key ->
            assertFalse(key in body, "Expected SIWC request to omit unsupported field '$key'")
        }
    }

    @Test
    fun siwcNeverSendsSystemRoleInInputMessages() {
        val initialEvent = PromptTranscriptEvent(
            initial = true,
            sections = mapOf("core" to "Initial instructions"),
        )
        val deltaEvent = PromptTranscriptEvent(
            initial = false,
            sections = mapOf("mode" to "Updated rule"),
        )
        val body = provider.buildResponsesRequestBody(
            providerSetting = siwcSetting,
            messages = listOf(
                PromptTranscript.message(initialEvent),
                UIMessage.user("Turn 1"),
                PromptTranscript.message(deltaEvent),
                UIMessage.user("Turn 2"),
            ),
            params = TextGenerationParams(
                model = testModel(abilities = listOf(ModelAbility.TOOL)),
            ),
            stream = true,
        )

        val roles = body.getValue("input").jsonArray.mapNotNull {
            it.jsonObject["role"]?.jsonPrimitive?.content
        }
        assertFalse("system" in roles, "SIWC input must never contain role=system")
        assertTrue("developer" in roles, "SIWC mid-conversation system transition must use role=developer")

        // Also verify customBody injection of {type:"message", role:"system"} is rewritten.
        val sanitized = provider.sanitizeChatGptSiwcResponsesBody(
            buildJsonObject {
                put("model", "gpt-5.4")
                put("input", buildJsonArray {
                    add(buildJsonObject {
                        put("type", "message")
                        put("role", "system")
                        put("content", "Injected")
                    })
                })
            }
        )
        assertEquals(
            "developer",
            sanitized.getValue("input").jsonArray.single().jsonObject.getValue("role").jsonPrimitive.content,
        )
    }

    @Test
    fun siwcFiltersUnsupportedHostedToolsAndRetainsCustomFunctionTools() {
        val mixedTools = buildJsonArray {
            add(buildJsonObject {
                put("type", "function")
                put("name", "get_weather")
            })
            listOf(
                "image_generation",
                "file_search",
                "code_interpreter",
                "computer",
                "computer_use",
                "computer_use_preview",
                "mcp",
                "tool_search",
                "programmatic_tool_calling",
            ).forEach { hosted ->
                add(buildJsonObject { put("type", hosted) })
            }
        }

        val sanitized = provider.sanitizeChatGptSiwcResponsesBody(
            buildJsonObject {
                put("model", "gpt-5.4")
                put("tools", mixedTools)
                put("tool_choice", buildJsonObject { put("type", "computer") })
                put("input", buildJsonArray {
                    add(buildJsonObject {
                        put("type", "additional_tools")
                        put("role", "user")
                        put("tools", mixedTools)
                    })
                })
            }
        )

        assertFalse("tools" in sanitized)
        val declarations = sanitized.getValue("input").jsonArray
        val remaining = declarations.first().jsonObject.getValue("tools").jsonArray
        assertEquals(1, remaining.size)
        assertEquals("function", remaining.single().jsonObject.getValue("type").jsonPrimitive.content)
        assertEquals("get_weather", remaining.single().jsonObject.getValue("name").jsonPrimitive.content)
        assertFalse("tool_choice" in sanitized)
        assertEquals(2, declarations.size)
        val inline = declarations.last().jsonObject
        assertEquals(remaining, inline["tools"])
        assertEquals("developer", inline.getValue("role").jsonPrimitive.content)
    }

    @Test
    fun siwcTreatsOnlyResponseCompletedAsSuccess() {
        // Incomplete even with max_output_tokens fails under SIWC.
        assertFailsWith<IllegalStateException> {
            provider.parseResponsesStreamData(
                """{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}""",
                authMode = OpenAIAuthMode.CHATGPT_SIWC,
            )
        }

        // Strict terminal state rejects [DONE] and response.incomplete without response.completed.
        val incompleteState = OpenAIStreamTerminalState(OpenAIStreamKind.RESPONSES_SIWC)
        incompleteState.observe("""data: {"type":"response.output_text.delta","delta":"hi"}""")
        incompleteState.observe("""data: [DONE]""")
        assertFailsWith<IllegalStateException> { incompleteState.requireCompleted() }

        val completedState = OpenAIStreamTerminalState(OpenAIStreamKind.RESPONSES_SIWC)
        completedState.observe("""data: {"type":"response.completed","response":{"id":"resp_1","status":"completed"}}""")
        completedState.requireCompleted()
    }

    @Test
    fun siwcMapsSubscriptionSharingUsageErrorsToFriendlyGuidance() {
        val errorEvent = """{"type":"error","code":"subscription_sharing_usage_limit_exceeded","message":"limit reached"}"""
        val streamError = assertFailsWith<IllegalStateException> {
            provider.parseResponsesStreamData(errorEvent, OpenAIAuthMode.CHATGPT_SIWC)
        }
        assertTrue(streamError.message.orEmpty().contains(CHATGPT_SIWC_USAGE_SETTINGS_URL))
        val limitErr = assertFailsWith<IllegalStateException> {
            provider.parseResponsesStreamData(
                """{"type":"response.failed","response":{"status":"failed","error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit reached"}}}""",
                authMode = OpenAIAuthMode.CHATGPT_SIWC,
            )
        }
        assertTrue(limitErr.message.orEmpty().contains("subscription_sharing_usage_limit_exceeded"))
        assertTrue(limitErr.message.orEmpty().contains(CHATGPT_SIWC_USAGE_SETTINGS_URL))

        val unavailableErr = assertFailsWith<IllegalStateException> {
            provider.parseResponsesStreamData(
                """{"type":"response.failed","response":{"status":"failed","error":{"code":"subscription_sharing_usage_unavailable","message":"unavailable"}}}""",
                authMode = OpenAIAuthMode.CHATGPT_SIWC,
            )
        }
        assertTrue(unavailableErr.message.orEmpty().contains("subscription_sharing_usage_unavailable"))
        assertTrue(unavailableErr.message.orEmpty().contains(CHATGPT_SIWC_USAGE_SETTINGS_URL))

        val legacyError = assertFailsWith<IllegalStateException> {
            provider.parseResponsesStreamData(
                """{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_unavailable","message":"upstream unavailable"}}}""",
                OpenAIAuthMode.CODEX_OAUTH,
            )
        }
        assertEquals("OpenAI Responses stream failed: upstream unavailable", legacyError.message)
    }

    @Test
    fun backgroundTransportRejectsSiwcProvider() {
        assertFailsWith<IllegalArgumentException> {
            OpenAIResponsesBackgroundTransport.requireOfficialResponsesProvider(
                siwcSetting.copy(useResponseApi = true)
            )
        }
    }
}
