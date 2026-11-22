package app.amber.ai.provider.claude

import app.amber.ai.core.PromptCacheWriteTier
import app.amber.ai.core.TokenUsage
import app.amber.ai.core.estimatePromptCacheInputCost
import app.amber.ai.core.sumUsage
import app.amber.ai.provider.Model
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.ui.UIMessage
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.sse.SSE
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Verifies Claude provider prompt-cache opt-in default (not globally forced on)
 * and real net-cost accounting for cold vs hot 5m cache trajectories.
 */
class ClaudePromptCacheBaselineTest {

    @Test
    fun `default Claude provider setting keeps promptCaching disabled globally`() {
        val setting = ProviderSetting.Claude(apiKey = "test-key", baseUrl = "https://api.anthropic.com/v1")
        assertFalse(setting.promptCaching, "Global promptCaching default must remain false")

        var capturedBody: String? = null
        val engine = MockEngine { request ->
            capturedBody = (request.body as? TextContent)?.text ?: request.body.toString()
            respond(
                content = """
                    {
                      "id": "msg_default_off",
                      "type": "message",
                      "role": "assistant",
                      "model": "claude-sonnet-4-5",
                      "content": [{"type": "text", "text": "ok"}],
                      "stop_reason": "end_turn",
                      "usage": {"input_tokens": 500, "output_tokens": 20}
                    }
                """.trimIndent(),
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
            )
        }
        val httpClient = HttpClient(engine)
        val sseClient = HttpClient(engine) { install(SSE) }
        try {
            val provider = ClaudeKmpProvider(httpClient, sseClient)
            val chunk = runBlocking {
                provider.generateText(
                    providerSetting = setting,
                    messages = listOf(UIMessage.system("system prompt"), UIMessage.user("hello")),
                    params = TextGenerationParams(model = Model(modelId = "claude-sonnet-4-5", displayName = "Claude Sonnet 4.5")),
                )
            }
            val bodyJson = Json.parseToJsonElement(capturedBody!!).jsonObject
            val systemField = bodyJson["system"]
            if (systemField != null) {
                assertFalse(systemField.toString().contains("cache_control"), "cache_control must not be emitted when default promptCaching=false")
            }
            assertNull(bodyJson["cache_control"])
            assertEquals(0, chunk.usage?.cacheCreationTokens ?: 0)
            assertEquals(0, chunk.usage?.cachedTokens ?: 0)
        } finally {
            httpClient.close()
            sseClient.close()
        }
    }

    @Test
    fun `cold single-turn 5m cache incurs overhead whereas multi-turn hot cache yields net savings`() {
        val coldUsage = TokenUsage(promptTokens = 2_000, completionTokens = 100, cachedTokens = 0, totalTokens = 2_100, cacheCreationTokens = 1_800)
        val coldCost = coldUsage.estimatePromptCacheInputCost(PromptCacheWriteTier.EPHEMERAL_5M)
        assertTrue(coldCost.netDeltaRatio > 0.20, "Cold 5m cache write should incur >20% net input overhead")

        val hotSession = listOf(
            TokenUsage(promptTokens = 2_400, completionTokens = 120, cachedTokens = 0, totalTokens = 2_520, cacheCreationTokens = 2_200),
            TokenUsage(promptTokens = 2_800, completionTokens = 120, cachedTokens = 2_200, totalTokens = 2_920, cacheCreationTokens = 400),
            TokenUsage(promptTokens = 3_200, completionTokens = 120, cachedTokens = 2_600, totalTokens = 3_320, cacheCreationTokens = 400),
            TokenUsage(promptTokens = 3_600, completionTokens = 120, cachedTokens = 3_000, totalTokens = 3_720, cacheCreationTokens = 400),
            TokenUsage(promptTokens = 4_000, completionTokens = 120, cachedTokens = 3_400, totalTokens = 4_120, cacheCreationTokens = 400),
            TokenUsage(promptTokens = 4_400, completionTokens = 120, cachedTokens = 3_800, totalTokens = 4_520, cacheCreationTokens = 400),
        ).sumUsage()
        val hotCost = hotSession.estimatePromptCacheInputCost(PromptCacheWriteTier.EPHEMERAL_5M)
        assertTrue(hotCost.netDeltaRatio < -0.50, "6-turn hot tool session should save >50% net input cost")
    }
}
