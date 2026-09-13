package app.amber.ai.provider.claude

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
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.sse.SSE
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import com.sun.net.httpserver.HttpServer
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import okhttp3.Dns
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.uuid.Uuid

class OpenCodeRequestHeadersHttpTest {
    private val userMessageId = Uuid.parse("00000000-0000-0000-0000-000000000301")
    private val messages = listOf(
        UIMessage(
            id = userMessageId,
            role = MessageRole.USER,
            parts = listOf(UIMessagePart.Text("hello")),
        ),
    )

    @Test
    fun messageGenerationSendsSessionAndDefaultUserAgent() = runBlocking {
        val engine = MockEngine {
            respond(
                content = """{"id":"msg-1","type":"message","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}""",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
            )
        }
        val httpClient = HttpClient(engine)
        val sseClient = HttpClient(engine) { install(SSE) }
        try {
            val provider = ClaudeKmpProvider(httpClient, sseClient)
            provider.generateText(
                providerSetting = openCodeSetting(),
                messages = messages,
                params = params(),
            )

            val request = engine.requestHistory.single()
            assertEquals(userMessageId.toString(), request.headers[OpenCodeRequestHeaders.SESSION_HEADER])
            assertEquals(OpenCodeRequestHeaders.DEFAULT_USER_AGENT, request.headers[HttpHeaders.UserAgent])
            assertTrue(request.url.encodedPath.endsWith("/messages"))
        } finally {
            httpClient.close()
            sseClient.close()
        }
    }

    @Test
    fun messageStreamingPreservesExplicitSessionAndUserAgent() = runBlocking {
        val requestHeaders = CompletableFuture<Map<String, List<String>>>()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/v1/messages") { exchange ->
            requestHeaders.complete(exchange.requestHeaders.mapValues { (_, values) -> values.toList() })
            val body = """
                event: message_start
                data: {"type":"message_start","message":{"id":"msg-1","type":"message","role":"assistant","model":"claude-sonnet-4-5","content":[],"usage":{"input_tokens":1}}}

                event: content_block_start
                data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

                event: content_block_delta
                data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}

                event: content_block_stop
                data: {"type":"content_block_stop","index":0}

                event: message_delta
                data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

                event: message_stop
                data: {"type":"message_stop"}

            """.trimIndent().plus("\n\n").toByteArray()
            exchange.responseHeaders.set("Content-Type", "text/event-stream")
            exchange.sendResponseHeaders(200, body.size.toLong())
            exchange.responseBody.use { it.write(body) }
        }
        server.start()
        val dns = object : Dns {
            override fun lookup(hostname: String): List<InetAddress> =
                listOf(InetAddress.getByName("127.0.0.1"))
        }
        val httpClient = HttpClient(OkHttp) { engine { config { dns(dns) } } }
        val sseClient = HttpClient(OkHttp) {
            engine { config { dns(dns) } }
            install(SSE)
        }
        try {
            val provider = ClaudeKmpProvider(httpClient, sseClient)
            val chunks = provider.streamText(
                providerSetting = openCodeSetting(server.address.port),
                messages = messages,
                params = params(
                    customHeaders = listOf(
                        CustomHeader("X-OpenCode-Session", "explicit-session"),
                        CustomHeader("user-agent", "Client/2"),
                    ),
                ),
            ).toList()

            val headers = requestHeaders.get(5, TimeUnit.SECONDS)
            assertEquals(listOf("explicit-session"), headers.entries.first { it.key.equals(OpenCodeRequestHeaders.SESSION_HEADER, true) }.value)
            assertEquals(listOf("Client/2"), headers.entries.first { it.key.equals(HttpHeaders.UserAgent, true) }.value)
            assertTrue(chunks.isNotEmpty())
        } finally {
            httpClient.close()
            sseClient.close()
            server.stop(0)
        }
    }

    private fun openCodeSetting(port: Int? = null) = ProviderSetting.Claude(
        apiKey = "test-token",
        baseUrl = if (port == null) "https://opencode.ai/zen/go/v1" else "http://opencode.ai:$port/v1",
    )

    private fun params(
        customHeaders: List<CustomHeader> = emptyList(),
    ) = TextGenerationParams(
        model = Model(modelId = "claude-sonnet-4-5", displayName = "Claude Sonnet 4.5"),
        customHeaders = customHeaders,
    )
}
