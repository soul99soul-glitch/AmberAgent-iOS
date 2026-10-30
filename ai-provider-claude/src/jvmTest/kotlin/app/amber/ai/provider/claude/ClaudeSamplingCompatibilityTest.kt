package app.amber.ai.provider.claude

import app.amber.ai.core.ReasoningLevel
import app.amber.ai.provider.Model
import app.amber.ai.provider.ModelAbility
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.ui.UIMessage
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ClaudeSamplingCompatibilityTest {
    private val provider = ClaudeKmpProvider()
    private val setting = ProviderSetting.Claude(apiKey = "test-key")

    @Test
    fun `fixed sampling models omit temperature and top p in all thinking modes`() {
        for (id in listOf(
            "claude-fable-5-1", "claude-mythos-5-1", "claude-fable-5", "claude-mythos-5",
            "claude-mythos-preview", "claude-opus-5-5", "claude-opus-5",
            "claude-opus-4-8", "claude-opus-4-7", "claude-sonnet-5-5", "claude-sonnet-5",
            "claude-haiku-5-5", "anthropic.claude-opus-4-7-v1:0", "claude-sonnet-5.5",
        )) {
            for (level in listOf(ReasoningLevel.OFF, ReasoningLevel.HIGH)) {
                val body = request(id, level)
                assertNull(body["temperature"], "$id / $level")
                assertNull(body["top_p"], "$id / $level")
            }
        }
    }

    @Test
    fun `older and unrecognized models preserve explicit sampling when thinking is off`() {
        for (id in listOf("claude-sonnet-4-6", "claude-opus-4-6", "claude-sonnet-4-5", "custom-model")) {
            val body = request(id, ReasoningLevel.OFF)
            assertEquals(0.7f, body["temperature"]!!.jsonPrimitive.content.toFloat(), id)
            assertEquals(0.8f, body["top_p"]!!.jsonPrimitive.content.toFloat(), id)
        }
    }

    private fun request(id: String, level: ReasoningLevel) = provider.buildMessageRequest(
        setting,
        listOf(UIMessage.user("hello")),
        TextGenerationParams(
            model = Model(modelId = id, abilities = listOf(ModelAbility.REASONING)),
            reasoningLevel = level,
            temperature = 0.7f,
            topP = 0.8f,
        ),
    )
}
