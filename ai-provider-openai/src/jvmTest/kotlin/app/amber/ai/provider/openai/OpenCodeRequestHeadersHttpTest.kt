package app.amber.ai.provider.openai

import app.amber.ai.core.MessageRole
import app.amber.ai.provider.CustomHeader
import app.amber.ai.provider.Model
import app.amber.ai.provider.OpenCodeRequestHeaders
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.uuid.Uuid

class OpenCodeRequestHeadersHttpTest {
    private val userMessageId = Uuid.parse("00000000-0000-0000-0000-000000000201")
    private val messages = listOf(
        UIMessage(
            id = userMessageId,
            role = MessageRole.USER,
            parts = listOf(UIMessagePart.Text("hello")),
        ),
    )

    @Test
    fun chatCompletionsGenerationSendsSessionAndDefaultUserAgent() = runBlocking {
        val engine = MockEngine {
            respond(
                content = """{"id":"chat-1","model":"gpt-5","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}""",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
            )
        }
        val client = HttpClient(engine)
        try {
            val provider = OpenAIKmpProvider(client, client)
            provider.generateText(
                providerSetting = openCodeSetting(),
                messages = messages,
                params = params(),
            )

            val request = engine.requestHistory.single()
            assertEquals(userMessageId.toString(), request.headers[OpenCodeRequestHeaders.SESSION_HEADER])
            assertEquals(OpenCodeRequestHeaders.DEFAULT_USER_AGENT, request.headers[HttpHeaders.UserAgent])
            assertTrue(request.url.encodedPath.endsWith("/chat/completions"))
        } finally {
            client.close()
        }
    }

    @Test
    fun chatCompletionsStreamingSendsExplicitHeaders() = runBlocking {
        val engine = MockEngine {
            respond(
                content = """
                    data: {"id":"chat-1","model":"gpt-5","choices":[{"delta":{"role":"assistant","content":"ok"},"finish_reason":null}]}

                    data: {"id":"chat-1","model":"gpt-5","choices":[{"delta":{},"finish_reason":"stop"}]}

                    data: [DONE]

                """.trimIndent(),
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
            )
        }
        val client = HttpClient(engine)
        try {
            val provider = OpenAIKmpProvider(client, client)
            val chunks = provider.streamText(
                providerSetting = openCodeSetting(),
                messages = messages,
                params = params(
                    customHeaders = listOf(
                        CustomHeader("X-OpenCode-Session", "explicit-session"),
                        CustomHeader("user-agent", "Client/2"),
                    ),
                ),
            ).toList()

            val request = engine.requestHistory.single()
            assertEquals("explicit-session", request.headers[OpenCodeRequestHeaders.SESSION_HEADER])
            assertEquals("Client/2", request.headers[HttpHeaders.UserAgent])
            assertTrue(chunks.isNotEmpty())
        } finally {
            client.close()
        }
    }

    @Test
    fun responsesGenerationSendsSessionAndDefaultUserAgent() = runBlocking {
        val engine = MockEngine {
            respond(
                content = responsesBody(),
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
            )
        }
        val client = HttpClient(engine)
        try {
            val provider = OpenAIKmpProvider(client, client)
            provider.generateText(
                providerSetting = openCodeSetting(useResponseApi = true),
                messages = messages,
                params = params(),
            )

            val request = engine.requestHistory.single()
            assertEquals(userMessageId.toString(), request.headers[OpenCodeRequestHeaders.SESSION_HEADER])
            assertEquals(OpenCodeRequestHeaders.DEFAULT_USER_AGENT, request.headers[HttpHeaders.UserAgent])
            assertTrue(request.url.encodedPath.endsWith("/responses"))
        } finally {
            client.close()
        }
    }

    @Test
    fun responsesStreamingSendsSessionAndDefaultUserAgent() = runBlocking {
        val engine = MockEngine {
            respond(
                content = """
                    event: response.output_text.delta
                    data: {"type":"response.output_text.delta","item_id":"item-1","delta":"ok"}

                    event: response.completed
                    data: {"type":"response.completed","response":{"id":"resp-1","model":"gpt-5","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}]}}

                """.trimIndent(),
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
            )
        }
        val client = HttpClient(engine)
        try {
            val provider = OpenAIKmpProvider(client, client)
            val chunks = provider.streamText(
                providerSetting = openCodeSetting(useResponseApi = true),
                messages = messages,
                params = params(),
            ).toList()

            val request = engine.requestHistory.single()
            assertEquals(userMessageId.toString(), request.headers[OpenCodeRequestHeaders.SESSION_HEADER])
            assertEquals(OpenCodeRequestHeaders.DEFAULT_USER_AGENT, request.headers[HttpHeaders.UserAgent])
            assertTrue(chunks.isNotEmpty())
            assertFalse(request.headers[OpenCodeRequestHeaders.SESSION_HEADER].isNullOrBlank())
        } finally {
            client.close()
        }
    }

    private fun openCodeSetting(useResponseApi: Boolean = false) = ProviderSetting.OpenAI(
        apiKey = "test-token",
        baseUrl = "https://opencode.ai/zen/go/v1",
        useResponseApi = useResponseApi,
    )

    private fun params(
        customHeaders: List<CustomHeader> = emptyList(),
    ) = TextGenerationParams(
        model = Model(modelId = "gpt-5", displayName = "GPT-5"),
        customHeaders = customHeaders,
    )

    private fun responsesBody() = """
        {"id":"resp-1","model":"gpt-5","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}]}
    """.trimIndent()
}
