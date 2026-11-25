package app.amber.ai.provider.claude

import app.amber.ai.core.PromptToolDeclaration
import app.amber.ai.core.PromptTranscript
import app.amber.ai.core.PromptTranscriptEvent
import app.amber.ai.core.Tool
import app.amber.ai.provider.CustomHeader
import app.amber.ai.provider.Model
import app.amber.ai.provider.ModelAbility
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.ui.UIMessage
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.sse.SSE
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class ClaudeTranscriptRequestTest {
    private val beta = "mid-conversation-tool-changes-2026-07-01"
    private val read = PromptToolDeclaration("read", "Read")
    private val write = PromptToolDeclaration("write", "Write")
    private val revisedRead = read.copy(description = "Read UTF-8")
    private val initial = PromptTranscript.message(
        PromptTranscriptEvent(initial = true, sections = mapOf("rules" to "规则"), toolsAdded = listOf(read)),
    )

    private data class Scenario(
        val name: String,
        val update: PromptTranscriptEvent?,
        val currentTools: List<PromptToolDeclaration>,
        val customBeta: String?,
        val expectedBeta: String?,
    )

    @Test
    fun bothEntrypointsPreserveTranscriptBodyBytesAndBetaHeader() = runBlocking {
        val scenarios = listOf(
            Scenario("plain", null, listOf(read), null, null),
            Scenario("addition", PromptTranscriptEvent(toolsAdded = listOf(write)), listOf(read, write), "other", "other,$beta"),
            Scenario("removal", PromptTranscriptEvent(toolsRemoved = listOf(read.name)), emptyList(), null, beta),
            Scenario("redefinition", PromptTranscriptEvent(toolsAdded = listOf(revisedRead)), listOf(revisedRead), "other", "other"),
        )
        val setting = ProviderSetting.Claude(baseUrl = "https://api.anthropic.com/v1", promptCaching = true)
        val baseline = requireNotNull(javaClass.getResource("/claude-transcript-bodies.json"))
        val bodies = Json.parseToJsonElement(baseline.readText()).jsonObject
        for (scenario in scenarios) {
            val messages = buildList {
                if (scenario.update != null) add(initial)
                add(UIMessage.user("你好"))
                if (scenario.update != null) add(PromptTranscript.message(scenario.update))
            }
            var schemaReads = 0
            val params = TextGenerationParams(
                model = Model(modelId = "claude-opus-5", abilities = listOf(ModelAbility.TOOL)),
                tools = scenario.currentTools.map { tool ->
                    Tool(tool.name, tool.description, parameters = {
                        schemaReads++
                        tool.parameters
                    }, execute = { emptyList() })
                },
                customHeaders = listOfNotNull(scenario.customBeta?.let { CustomHeader("Anthropic-Beta", it) }),
            )
            for (stream in listOf(false, true)) {
                schemaReads = 0
                val expected = JsonObject(bodies.getValue(scenario.name).jsonObject + ("stream" to JsonPrimitive(stream)))
                    .toString().encodeToByteArray()
                val request = captureRequest(setting, messages, params, stream)
                val body = requireNotNull(request.body)
                val buffer = Buffer()
                body.writeTo(buffer)
                assertContentEquals(expected, buffer.readByteArray(), "${scenario.name}, stream=$stream")
                assertEquals(expected.size.toLong(), body.contentLength())
                assertEquals(listOfNotNull(scenario.expectedBeta), request.headers.values("anthropic-beta"))
                if (scenario.name == "addition") {
                    assertEquals(scenario.currentTools.size, schemaReads, "read each native tool schema once per request")
                }
            }
        }
    }

    private suspend fun captureRequest(
        setting: ProviderSetting.Claude,
        messages: List<UIMessage>,
        params: TextGenerationParams,
        stream: Boolean,
    ): Request {
        val requests = mutableListOf<Request>()
        val client = HttpClient(OkHttp) {
            install(SSE)
            engine {
                addInterceptor { chain ->
                    val request = chain.request()
                    requests += request
                    val text = if (stream) "event: message_stop\ndata: {}\n\n" else """{"content":[]}"""
                    val type = if (stream) "text/event-stream" else "application/json"
                    Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                        .header("Content-Type", type).body(text.toResponseBody(type.toMediaType())).build()
                }
            }
        }
        client.use {
            val provider = ClaudeKmpProvider(client, client)
            if (stream) provider.streamText(setting, messages, params).toList()
            else provider.generateText(setting, messages, params)
        }
        return requests.single()
    }
}
