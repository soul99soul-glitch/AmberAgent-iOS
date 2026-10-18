package app.amber.ai.provider.openai

import app.amber.ai.core.MessageRole
import app.amber.ai.provider.Model
import app.amber.ai.provider.OpenAIAuthMode
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.ui.MessageStreamAccumulator
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.headersOf
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class OpenAIRefusalGenerationTest {
    private val refusal = "I cannot help with that."
    private val messages = listOf(UIMessage.user("Hello"))
    private val params = TextGenerationParams(model = Model(modelId = "gpt-5.4"))

    @Test
    fun responsesStreamPreservesRefusalDeltasWithoutRepeatingDoneOrCompleted() = runBlocking {
        withProvider(responsesRefusalStream(), streaming = true) { provider ->
            val snapshots = streamSnapshots(provider, setting(responses = true))

            assertTrue("I cannot " in snapshots, "The refusal must be visible while streaming.")
            assertEquals(refusal, snapshots.last())
        }
    }

    @Test
    fun codexSingleShotGenerationPreservesStreamedRefusal() = runBlocking {
        withProvider(responsesRefusalStream(), streaming = true) { provider ->
            val result = provider.generateText(
                setting(responses = false).copy(authMode = OpenAIAuthMode.CODEX_OAUTH),
                messages,
                params,
            )

            assertEquals(refusal, result.choices.single().message!!.text())
        }
    }

    @Test
    fun chatCompletionStreamPreservesRefusalDeltas() = runBlocking {
        val stream = """
            data: {"id":"chat_refusal","choices":[{"delta":{"role":"assistant","content":null,"refusal":"I cannot "},"finish_reason":null}]}

            data: {"id":"chat_refusal","choices":[{"delta":{"refusal":"help with that."},"finish_reason":null}]}

            data: {"id":"chat_refusal","choices":[{"delta":{},"finish_reason":"stop"}]}

            data: [DONE]

        """.trimIndent()
        withProvider(stream, streaming = true) { provider ->
            val snapshots = streamSnapshots(provider, setting(responses = false))

            assertTrue("I cannot " in snapshots)
            assertEquals(refusal, snapshots.last())
        }
    }

    @Test
    fun chatCompletionGenerationPreservesRefusalWhenContentIsNull() = runBlocking {
        val body = """{"id":"chat_refusal","choices":[{"message":{"role":"assistant","content":null,"refusal":"$refusal"},"finish_reason":"stop"}]}"""
        withProvider(body, streaming = false) { provider ->
            val result = provider.generateText(setting(responses = false), messages, params)

            assertEquals(refusal, result.choices.single().message!!.text())
        }
    }

    @Test
    fun responsesTextStreamStillDoesNotRepeatDoneOrCompleted() = runBlocking {
        val stream = """
            data: {"type":"response.output_text.delta","item_id":"msg_text","delta":"Hello"}

            data: {"type":"response.output_text.done","item_id":"msg_text","text":"Hello"}

            data: {"type":"response.output_item.done","item":{"id":"msg_text","type":"message","content":[{"type":"output_text","text":"Hello"}]}}

            data: {"type":"response.completed","response":{"id":"resp_text","status":"completed","output":[{"id":"msg_text","type":"message","content":[{"type":"output_text","text":"Hello"}]}]}}

        """.trimIndent()
        withProvider(stream, streaming = true) { provider ->
            assertEquals("Hello", streamSnapshots(provider, setting(responses = true)).last())
        }
    }

    private fun responsesRefusalStream(): String = """
        data: {"type":"response.output_item.added","item":{"id":"msg_refusal","type":"message","role":"assistant","content":[]}}

        data: {"type":"response.refusal.delta","item_id":"msg_refusal","delta":"I cannot "}

        data: {"type":"response.refusal.delta","item_id":"msg_refusal","delta":"help with that."}

        data: {"type":"response.refusal.done","item_id":"msg_refusal","refusal":"$refusal"}

        data: {"type":"response.output_item.done","item":{"id":"msg_refusal","type":"message","content":[{"type":"refusal","refusal":"$refusal"}]}}

        data: {"type":"response.completed","response":{"id":"resp_refusal","status":"completed","output":[{"id":"msg_refusal","type":"message","content":[{"type":"refusal","refusal":"$refusal"}]}]}}

    """.trimIndent()

    private suspend fun streamSnapshots(
        provider: OpenAIKmpProvider,
        setting: ProviderSetting.OpenAI,
    ): List<String> {
        val accumulator = MessageStreamAccumulator(
            listOf(UIMessage(role = MessageRole.ASSISTANT, parts = emptyList())),
        )
        val snapshots = mutableListOf<String>()
        provider.streamText(setting, messages, params).collect { chunk ->
            accumulator.append(chunk)
            snapshots += accumulator.snapshot().last().text()
        }
        return snapshots
    }

    private fun setting(responses: Boolean): ProviderSetting.OpenAI = ProviderSetting.OpenAI(
        apiKey = "sk-test",
        baseUrl = "https://api.openai.com/v1",
        useResponseApi = responses,
    )

    private suspend fun withProvider(
        body: String,
        streaming: Boolean,
        block: suspend (OpenAIKmpProvider) -> Unit,
    ) {
        val client = HttpClient(MockEngine {
            respond(
                content = body,
                headers = headersOf(
                    HttpHeaders.ContentType,
                    if (streaming) "text/event-stream" else "application/json",
                ),
            )
        })
        try {
            block(OpenAIKmpProvider(client, client))
        } finally {
            client.close()
        }
    }

    private fun UIMessage.text(): String = parts.filterIsInstance<UIMessagePart.Text>().joinToString("") { it.text }
}
