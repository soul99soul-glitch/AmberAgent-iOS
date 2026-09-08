package app.amber.ai.provider.openai

import app.amber.ai.core.MessageRole
import app.amber.ai.provider.Model
import app.amber.ai.provider.OpenAIAuthMode
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class OpenAICodexGenerationTest {
    @Test
    fun singleShotCodexGenerationCollectsSseAndPropagatesHttpFailure() = runBlocking {
        val request = CompletableFuture<JsonObject>()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/responses") { exchange ->
            request.complete(Json.parseToJsonElement(exchange.requestBody.bufferedReader().readText()).jsonObject)
            val body = """
                data: {"type":"response.output_text.delta","delta":"Red"}

                data: {"type":"response.completed","response":{"id":"resp_vision","model":"gpt-6-astra","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Red"}]}],"usage":{"input_tokens":10,"output_tokens":1,"total_tokens":11}}}

            """.trimIndent().plus("\n\n").toByteArray()
            exchange.responseHeaders.set("Content-Type", "text/event-stream")
            exchange.sendResponseHeaders(200, body.size.toLong())
            exchange.responseBody.use { it.write(body) }
        }
        server.createContext("/failure/responses") { exchange ->
            exchange.requestBody.readBytes()
            val body = """{"detail":"Unsupported parameter: max_output_tokens"}""".toByteArray()
            exchange.responseHeaders.set("Content-Type", "application/json")
            exchange.sendResponseHeaders(400, body.size.toLong())
            exchange.responseBody.use { it.write(body) }
        }
        server.start()
        try {
            val provider = OpenAIKmpProvider()
            val setting = ProviderSetting.OpenAI(
                apiKey = "test-token",
                baseUrl = "http://127.0.0.1:${server.address.port}",
                authMode = OpenAIAuthMode.CODEX_OAUTH,
                useResponseApi = false,
            )
            val image = "data:image/png;base64,test-fixture"
            val messages = listOf(UIMessage(role = MessageRole.USER, parts = listOf(
                UIMessagePart.Text("What color?"), UIMessagePart.Image(image),
            )))
            val params = TextGenerationParams(model = Model(modelId = "gpt-6-astra"), maxTokens = 1200)
            val result = provider.generateText(setting, messages, params)
            val body = request.get(5, TimeUnit.SECONDS)
            assertTrue(body.getValue("stream").jsonPrimitive.boolean)
            assertFalse("max_output_tokens" in body)
            assertTrue(body.toString().contains(image))
            val message = result.choices.single().message!!
            assertEquals("Red", message.parts.filterIsInstance<UIMessagePart.Text>().joinToString("") { it.text })
            assertEquals(1, result.usage?.completionTokens)
            val failure = assertFailsWith<Exception> {
                provider.generateText(setting.copy(baseUrl = setting.baseUrl + "/failure"), messages, params)
            }
            assertTrue(failure.message.orEmpty().contains("HTTP 400"))
        } finally {
            server.stop(0)
        }
    }
}
