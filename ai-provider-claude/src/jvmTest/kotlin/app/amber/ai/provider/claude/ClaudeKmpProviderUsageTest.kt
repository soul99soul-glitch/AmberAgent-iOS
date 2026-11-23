package app.amber.ai.provider.claude

import app.amber.ai.core.MessageRole
import app.amber.ai.core.PromptCacheWriteTier
import app.amber.ai.core.estimatePromptCacheInputCost
import app.amber.ai.core.sumUsage
import app.amber.ai.provider.Model
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.ui.MessageStreamAccumulator
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.sse.SSE
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.runBlocking
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ClaudeKmpProviderUsageTest {

    private val provider = ClaudeKmpProvider()

    private val claudeSetting = ProviderSetting.Claude(
        apiKey = "sk-ant-test",
        baseUrl = "https://api.anthropic.com/v1",
    )

    private val params = TextGenerationParams(
        model = Model(modelId = "claude-sonnet-4-5", displayName = "Claude Sonnet 4.5"),
    )

    private val userMessages = listOf(
        UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("hello"))),
    )

    @Test
    fun `non-streaming generateText records cacheCreationTokens alongside cachedTokens and input_tokens`() = runBlocking {
        val engine = MockEngine {
            respond(
                content = """
                    {
                      "id": "msg_non_stream_1",
                      "type": "message",
                      "role": "assistant",
                      "model": "claude-sonnet-4-5",
                      "content": [{"type": "text", "text": "ok"}],
                      "stop_reason": "end_turn",
                      "usage": {
                        "input_tokens": 120,
                        "cache_read_input_tokens": 300,
                        "cache_creation_input_tokens": 1000,
                        "output_tokens": 45
                      }
                    }
                """.trimIndent(),
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
            )
        }
        val httpClient = HttpClient(engine)
        val sseClient = HttpClient(engine) { install(SSE) }
        try {
            val mockProvider = ClaudeKmpProvider(httpClient, sseClient)
            val chunk = mockProvider.generateText(claudeSetting, userMessages, params)
            val usage = assertNotNull(chunk.usage)

            assertEquals(1_420, usage.promptTokens)
            assertEquals(45, usage.completionTokens)
            assertEquals(300, usage.cachedTokens)
            assertEquals(1_000, usage.cacheCreationTokens)
            assertEquals(120, usage.uncachedInputTokens)
            assertEquals(1_465, usage.totalTokens)
        } finally {
            httpClient.close()
            sseClient.close()
        }
    }

    @Test
    fun `non-streaming response omitting cache fields defaults cacheCreationTokens to zero`() = runBlocking {
        val engine = MockEngine {
            respond(
                content = """
                    {
                      "id": "msg_legacy_1",
                      "type": "message",
                      "role": "assistant",
                      "model": "claude-sonnet-4-5",
                      "content": [{"type": "text", "text": "ok"}],
                      "stop_reason": "end_turn",
                      "usage": {
                        "input_tokens": 250,
                        "output_tokens": 40
                      }
                    }
                """.trimIndent(),
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
            )
        }
        val httpClient = HttpClient(engine)
        val sseClient = HttpClient(engine) { install(SSE) }
        try {
            val mockProvider = ClaudeKmpProvider(httpClient, sseClient)
            val chunk = mockProvider.generateText(claudeSetting, userMessages, params)
            val usage = assertNotNull(chunk.usage)

            assertEquals(250, usage.promptTokens)
            assertEquals(40, usage.completionTokens)
            assertEquals(0, usage.cachedTokens)
            assertEquals(0, usage.cacheCreationTokens)
            assertEquals(250, usage.uncachedInputTokens)
            assertEquals(290, usage.totalTokens)
        } finally {
            httpClient.close()
            sseClient.close()
        }
    }

    @Test
    fun `streaming message_start and message_delta merge preserves cacheCreationTokens and net cost accounting`() {
        // Turn 1: 1 write (1000 tokens), 0 read
        val turn1Accumulator = MessageStreamAccumulator(listOf(UIMessage.user("turn 1")))
        val turn1Events = listOf(
            "message_start" to """{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-4-5","content":[],"usage":{"input_tokens":0,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0,"output_tokens":1}}}""",
            "content_block_start" to """{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}""",
            "content_block_delta" to """{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"cached write"}}""",
            "message_delta" to """{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":32}}""",
        )
        val firstStream = provider.StreamEventParser()
        turn1Events.forEach { (type, data) ->
            firstStream.parse(id = "msg_1", type = type, data = data)?.let(turn1Accumulator::append)
        }

        val turn1Snapshot = turn1Accumulator.snapshot()
        assertNull(turn1Snapshot[0].usage)
        val turn1Usage = assertNotNull(turn1Snapshot[1].usage)
        assertEquals(1_000, turn1Usage.promptTokens)
        assertEquals(32, turn1Usage.completionTokens)
        assertEquals(0, turn1Usage.cachedTokens)
        assertEquals(1_000, turn1Usage.cacheCreationTokens)
        assertEquals(0, turn1Usage.uncachedInputTokens)
        assertEquals(1_032, turn1Usage.totalTokens)

        // 1 write 0 read => 1.25x vs 1.0x (+25%)
        val turn1Cost = turn1Usage.estimatePromptCacheInputCost()
        assertApprox(1_250.0, turn1Cost.effectiveInputTokens)
        assertApprox(0.25, turn1Cost.netDeltaRatio)

        // Turn 2: 0 write, 1 read (1000 tokens)
        val turn2Accumulator = MessageStreamAccumulator(listOf(UIMessage.user("turn 2")))
        val turn2Events = listOf(
            "message_start" to """{"type":"message_start","message":{"id":"msg_2","type":"message","role":"assistant","model":"claude-sonnet-4-5","content":[],"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":1000,"output_tokens":1}}}""",
            "content_block_delta" to """{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"cached read"}}""",
            "message_delta" to """{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":48}}""",
        )
        val secondStream = provider.StreamEventParser()
        turn2Events.forEach { (type, data) ->
            secondStream.parse(id = "msg_2", type = type, data = data)?.let(turn2Accumulator::append)
        }

        val turn2Usage = assertNotNull(turn2Accumulator.snapshot().last().usage)
        assertEquals(1_000, turn2Usage.promptTokens)
        assertEquals(48, turn2Usage.completionTokens)
        assertEquals(1_000, turn2Usage.cachedTokens)
        assertEquals(0, turn2Usage.cacheCreationTokens)
        assertEquals(0, turn2Usage.uncachedInputTokens)

        // Multi-turn sum keeps cacheCreationTokens and yields 1.35x vs 2.0x (-32.5%)
        val sessionUsage = listOf(turn1Usage, turn2Usage).sumUsage()
        assertEquals(2_000, sessionUsage.promptTokens)
        assertEquals(80, sessionUsage.completionTokens)
        assertEquals(1_000, sessionUsage.cachedTokens)
        assertEquals(1_000, sessionUsage.cacheCreationTokens)
        assertEquals(0, sessionUsage.uncachedInputTokens)

        val sessionCost5m = sessionUsage.estimatePromptCacheInputCost()
        assertApprox(1_350.0, sessionCost5m.effectiveInputTokens)
        assertApprox(-0.325, sessionCost5m.netDeltaRatio)

        // 1h cache write option (2.0x write, 0.1x read): 2.1x vs 2.0x (+5%)
        val sessionCost1h = sessionUsage.estimatePromptCacheInputCost(PromptCacheWriteTier.EPHEMERAL_1H)
        assertApprox(2_100.0, sessionCost1h.effectiveInputTokens)
        assertApprox(0.05, sessionCost1h.netDeltaRatio)
    }

    @Test
    fun partial_stream_usage_preserves_omitted_counters_and_applies_explicit_zero() {
        val stream = provider.StreamEventParser()
        val accumulator = MessageStreamAccumulator(userMessages)
        fun append(type: String, data: String) =
            accumulator.append(assertNotNull(stream.parse("msg", type, data)))

        append("message_start", """{"message":{"usage":{"input_tokens":120,"cache_read_input_tokens":300,"cache_creation_input_tokens":1000,"output_tokens":1}}}""")
        append("message_delta", """{"usage":{"cache_creation_input_tokens":1000,"output_tokens":45}}""")
        val usage = assertNotNull(accumulator.snapshot().last().usage)
        assertEquals(1_420, usage.promptTokens)
        assertEquals(1_465, usage.totalTokens)
        assertEquals(1_400.0, usage.estimatePromptCacheInputCost().effectiveInputTokens)

        append("message_delta", """{"usage":{"cache_read_input_tokens":0,"output_tokens":46}}""")
        val corrected = assertNotNull(accumulator.snapshot().last().usage)
        assertEquals(0, corrected.cachedTokens)
        assertEquals(1_120, corrected.promptTokens)
    }

    private fun assertApprox(expected: Double, actual: Double, epsilon: Double = 1e-9) {
        assertTrue(
            abs(expected - actual) <= epsilon,
            "Expected $expected (+/- $epsilon) but was $actual",
        )
    }
}
