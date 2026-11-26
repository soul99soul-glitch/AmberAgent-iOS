package app.amber.ai.provider.openai

import app.amber.ai.provider.Model
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.ui.UIMessagePart
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.headersOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals

class OpenAIStreamDecodingTest {
    @Test
    fun bothProtocolsDeliverEveryProxyFrameInOrder() = runBlocking {
        val expected = (0 until 500).map(Int::toString)
        for (responses in listOf(false, true)) {
            val body = buildString {
                for (token in expected) {
                    // The common ID prefix identifies these 1,000 JSON payloads in a parser profile.
                    val payload = if (responses) {
                        """{"id":"parse-count-$token","type":"response.output_text.delta","delta":"$token"}"""
                    } else {
                        """{"id":"parse-count-$token","choices":[{"delta":{"content":"$token"}}]}"""
                    }
                    appendLine("data: data: $payload")
                }
                appendLine("data: data: [DONE]")
            }
            val engine = MockEngine { respond(body, headers = headersOf(HttpHeaders.ContentType, "text/event-stream")) }
            HttpClient(engine).use { client ->
                val chunks = OpenAIKmpProvider(client, client).streamText(
                    ProviderSetting.OpenAI(apiKey = "test", useResponseApi = responses),
                    emptyList(),
                    TextGenerationParams(model = Model(modelId = "test")),
                ).toList()
                val tokens = chunks.map { (it.choices.single().delta!!.parts.single() as UIMessagePart.Text).text }
                assertEquals(expected, tokens)
            }
        }
    }
}
