package app.amber.ai.provider.openai

import app.amber.ai.core.MessageRole
import app.amber.ai.provider.Model
import app.amber.ai.provider.OpenAIAuthMode
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.ui.MessageChunk
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class OpenAIResponsesGenerationTest {
    @Test
    fun failedResponseSurfacesProviderMessageDespiteHttpSuccess() = runBlocking {
        val error = assertFailsWith<IllegalStateException> {
            generate("""{"status":"failed","error":{"message":"upstream unavailable"},"output":[]}""")
        }

        assertTrue(error.message.orEmpty().contains("upstream unavailable"))
    }

    @Test
    fun contentFilteredResponseFailsDespitePartialOutput() = runBlocking {
        val error = assertFailsWith<IllegalStateException> {
            generate(
                """{"status":"incomplete","incomplete_details":{"reason":"content_filter"},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Partial reply"}]}]}"""
            )
        }

        assertTrue(error.message.orEmpty().contains("content_filter"))
    }

    @Test
    fun completedResponseReturnsTextAndUsage() = runBlocking {
        val result = generate(
            """{"id":"resp_completed","model":"gpt-5.4","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Complete reply"}]}],"usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}}"""
        )

        assertEquals("Complete reply", result.outputText())
        assertEquals(10, result.usage?.promptTokens)
        assertEquals(2, result.usage?.completionTokens)
        assertEquals(null, result.choices.single().finishReason)
    }

    @Test
    fun outputCapReturnsPartialTextAndExplicitLimitFinishReason() = runBlocking {
        val result = generate(
            """{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Partial reply"}]}]}"""
        )

        assertEquals("Partial reply", result.outputText())
        assertEquals("max_output_tokens", result.choices.single().finishReason)
    }

    private suspend fun generate(responseBody: String): MessageChunk {
        val client = HttpClient(MockEngine { request ->
            assertEquals("/v1/responses", request.url.encodedPath)
            respond(
                content = responseBody,
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
            )
        })
        try {
            return OpenAIKmpProvider(client, client).generateText(
                ProviderSetting.OpenAI(
                    apiKey = "sk-test",
                    baseUrl = "https://api.openai.com/v1",
                    authMode = OpenAIAuthMode.API_KEY,
                    useResponseApi = true,
                ),
                listOf(UIMessage(role = MessageRole.USER, parts = listOf(UIMessagePart.Text("Hello")))),
                TextGenerationParams(model = Model(modelId = "gpt-5.4")),
            )
        } finally {
            client.close()
        }
    }

    private fun MessageChunk.outputText(): String =
        choices.single().message!!.parts.filterIsInstance<UIMessagePart.Text>().joinToString("") { it.text }
}
