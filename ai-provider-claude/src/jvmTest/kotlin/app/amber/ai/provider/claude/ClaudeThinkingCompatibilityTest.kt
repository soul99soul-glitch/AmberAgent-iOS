package app.amber.ai.provider.claude

import app.amber.ai.core.ReasoningLevel
import app.amber.ai.provider.Model
import app.amber.ai.provider.ModelAbility
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.provider.reasoningOptions
import app.amber.ai.ui.UIMessage
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ClaudeThinkingCompatibilityTest {
    private val provider = ClaudeKmpProvider()
    private val setting = ProviderSetting.Claude(apiKey = "test-key")

    @Test
    fun `legacy thinking models use manual budget without adaptive fields`() {
        for (id in listOf(
            "claude-3-7-sonnet-20250219", "claude-sonnet-4-20250514",
            "claude-opus-4-1", "claude-sonnet-4-5", "claude-opus-4-5", "claude-haiku-4-5",
            "anthropic.claude-sonnet-4-5-20250929-v1:0",
        )) {
            val body = request(id, ReasoningLevel.MEDIUM)
            val thinking = body["thinking"]!!.jsonObject
            assertEquals("enabled", thinking["type"]!!.jsonPrimitive.content, id)
            assertEquals(2_000, thinking["budget_tokens"]!!.jsonPrimitive.int, id)
            assertNull(thinking["display"], id)
            assertNull(body["output_config"], id)
        }
    }

    @Test
    fun `manual budget respects API minimum and output limit`() {
        val low = request("claude-sonnet-4-5", ReasoningLevel.LOW)
        assertEquals(1_024, low["thinking"]!!.jsonObject["budget_tokens"]!!.jsonPrimitive.int)
        val bounded = request("claude-sonnet-4-5", ReasoningLevel.HIGH, maxTokens = 2_000)
        assertEquals(1_999, bounded["thinking"]!!.jsonObject["budget_tokens"]!!.jsonPrimitive.int)
        val auto = request("claude-sonnet-4-5", ReasoningLevel.AUTO)
        assertTrue(auto["thinking"]!!.jsonObject["budget_tokens"]!!.jsonPrimitive.int >= 1_024)
        assertFailsWith<IllegalArgumentException> {
            request("claude-sonnet-4-5", ReasoningLevel.LOW, maxTokens = 1_024)
        }
    }

    @Test
    fun `adaptive models keep effort and do not receive manual budget`() {
        for (id in listOf("claude-opus-4-6", "claude-sonnet-4-6", "claude-sonnet-4.6", "claude-opus-4-7", "claude-opus-5")) {
            val body = request(id, ReasoningLevel.HIGH)
            assertEquals("adaptive", body["thinking"]!!.jsonObject["type"]!!.jsonPrimitive.content, id)
            assertNull(body["thinking"]!!.jsonObject["budget_tokens"], id)
            assertEquals("high", body["output_config"]!!.jsonObject["effort"]!!.jsonPrimitive.content, id)
        }
    }

    @Test
    fun `off uses each model supported wire mode`() {
        for (id in listOf("claude-sonnet-4-5", "claude-opus-4-6", "claude-opus-5", "claude-sonnet-5", "claude-haiku-5-5")) {
            val body = request(id, ReasoningLevel.OFF)
            assertEquals("disabled", body["thinking"]!!.jsonObject["type"]!!.jsonPrimitive.content, id)
            assertNull(body["output_config"], id)
            assertTrue(ReasoningLevel.OFF in model(id).reasoningOptions(setting).map { it.level }, id)
        }
        val sonnet = request("claude-sonnet-5-5", ReasoningLevel.OFF)
        assertEquals("between_tools", sonnet["thinking"]!!.jsonObject["type"]!!.jsonPrimitive.content)
        for (id in listOf("claude-opus-5-5", "claude-opus-5.5", "claude-fable-5", "claude-mythos-preview")) {
            val body = request(id, ReasoningLevel.OFF)
            assertEquals("adaptive", body["thinking"]!!.jsonObject["type"]!!.jsonPrimitive.content, id)
            assertEquals("low", body["output_config"]!!.jsonObject["effort"]!!.jsonPrimitive.content, id)
            assertFalse(ReasoningLevel.OFF in model(id).reasoningOptions(setting).map { it.level }, id)
        }
    }

    private fun model(id: String) = Model(modelId = id, abilities = listOf(ModelAbility.REASONING))

    private fun request(id: String, level: ReasoningLevel, maxTokens: Int? = null) = provider.buildMessageRequest(
        setting,
        listOf(UIMessage.user("hello")),
        TextGenerationParams(model = model(id), reasoningLevel = level, maxTokens = maxTokens),
    )
}
