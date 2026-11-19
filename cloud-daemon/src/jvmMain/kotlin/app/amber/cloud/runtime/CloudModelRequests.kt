package app.amber.cloud.runtime

import app.amber.ai.core.MessageRole
import app.amber.ai.core.Tool
import app.amber.ai.provider.*
import app.amber.ai.provider.claude.claudeProviderWithClient
import app.amber.ai.provider.openai.openAIProviderWithClient
import app.amber.ai.ui.MessageStreamAccumulator
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.ai.ui.finishReasoning
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.HttpRequestTimeoutException
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.HttpTimeoutConfig
import io.ktor.client.plugins.sse.SSE
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import java.net.SocketTimeoutException

internal fun cloudModelHttpClient(requestTimeoutMs: Long = 180_000, socketTimeoutMs: Long = 180_000): HttpClient = HttpClient(OkHttp) {
    install(HttpTimeout) {
        requestTimeoutMillis = requestTimeoutMs
        socketTimeoutMillis = socketTimeoutMs
        connectTimeoutMillis = 15_000
    }
    install(SSE)
    // One retry is owned below so HTTP engine retries cannot multiply the attempt budget.
    engine { config { retryOnConnectionFailure(false) } }
}

internal fun cloudStreamHttpClient(idleTimeoutMs: Long = 180_000): HttpClient = HttpClient(OkHttp) {
    install(HttpTimeout) {
        requestTimeoutMillis = HttpTimeoutConfig.INFINITE_TIMEOUT_MS
        socketTimeoutMillis = idleTimeoutMs
        connectTimeoutMillis = 15_000
    }
    install(SSE)
    engine { config { retryOnConnectionFailure(false) } }
}

class CloudModelTimeoutException(val attempts: Int, cause: Throwable) : Exception("model_request_timeout: attempts=$attempts", cause)

internal fun cloudFailureSummary(error: Throwable): String = when (error) {
    is CloudModelTimeoutException -> "模型接口响应超时，${if (error.attempts > 1) "已自动重试 ${error.attempts - 1} 次仍未成功" else "未完成请求"}。这次任务没有完成，可以再试一次。"
    else -> "执行时遇到异常，这次任务没有完成。可以再试一次；详细原因已保留供排查。"
}

/** Cloud transport policy is deliberately separate from mobile provider defaults. */
class KmpProviderModelClient(
    private val providerSetting: ProviderSetting,
    private val modelId: String,
    private val httpClient: HttpClient = cloudModelHttpClient(),
    private val retryDelayMs: Long = 500,
    private val streamHttpClient: HttpClient? = null,
) : CloudModelClient {
    private val resolvedStreamHttpClient by lazy { streamHttpClient ?: cloudStreamHttpClient() }
    private val openAIProvider by lazy { openAIProviderWithClient(httpClient) }
    private val claudeProvider by lazy { claudeProviderWithClient(httpClient) }
    private val streamOpenAIProvider by lazy { openAIProviderWithClient(resolvedStreamHttpClient) }
    private val streamClaudeProvider by lazy { claudeProviderWithClient(resolvedStreamHttpClient) }

    override suspend fun generateReply(messages: List<UIMessage>, tools: List<Tool>): UIMessage {
        val params = TextGenerationParams(
            model = Model(modelId = modelId, abilities = if (tools.isEmpty()) emptyList() else listOf(ModelAbility.TOOL)), tools = tools,
        )
        repeat(2) { attempt ->
            try {
                val chunk = when (providerSetting) {
                    is ProviderSetting.OpenAI -> openAIProvider.generateText(providerSetting, messages, params)
                    is ProviderSetting.Claude -> claudeProvider.generateText(providerSetting, messages, params)
                    else -> error("Unsupported cloud provider: ${providerSetting::class.simpleName}")
                }
                return UIMessage(role = MessageRole.ASSISTANT, parts = emptyList()) + chunk
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                val timeout = isTimeoutException(e)
                if (!timeout) throw e
                if (attempt == 1) throw CloudModelTimeoutException(attempt + 1, e)
                // Only generation is retried: no returned tool call has been executed yet.
                delay(retryDelayMs)
            }
        }
        error("unreachable")
    }

    override suspend fun streamReply(
        messages: List<UIMessage>,
        tools: List<Tool>,
        onActivity: (StreamActivity) -> Unit,
    ): UIMessage {
        val model = Model(
            modelId = modelId,
            abilities = if (tools.isEmpty()) emptyList() else listOf(ModelAbility.TOOL),
        )
        val params = TextGenerationParams(model = model, tools = tools)
        repeat(2) { attempt ->
            var receivedChunk = false
            val accumulator = MessageStreamAccumulator(
                initialMessages = listOf(UIMessage(role = MessageRole.ASSISTANT, parts = emptyList())),
                model = model,
            )
            try {
                val flow = when (providerSetting) {
                    is ProviderSetting.OpenAI -> streamOpenAIProvider.streamText(providerSetting, messages, params)
                    is ProviderSetting.Claude -> streamClaudeProvider.streamText(providerSetting, messages, params)
                    else -> error("Unsupported cloud provider: ${providerSetting::class.simpleName}")
                }
                flow.collect { chunk ->
                    receivedChunk = true
                    accumulator.append(chunk)
                    val delta = chunk.choices.firstOrNull()?.delta ?: chunk.choices.firstOrNull()?.message
                    val textChars = delta?.parts?.filterIsInstance<UIMessagePart.Text>()?.sumOf { it.text.length } ?: 0
                    val toolName = delta?.parts?.filterIsInstance<UIMessagePart.Tool>()?.firstOrNull()?.toolName?.takeIf { it.isNotBlank() }
                    val kind = when {
                        toolName != null -> "tool_delta"
                        delta?.parts?.any { it is UIMessagePart.Reasoning } == true -> "reasoning"
                        textChars > 0 -> "text"
                        else -> "chunk"
                    }
                    onActivity(StreamActivity(kind = kind, deltaTextChars = textChars, toolName = toolName))
                }
                return accumulator.snapshot().last().finishReasoning()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val timeout = isTimeoutException(e)
                if (receivedChunk) {
                    if (timeout) throw CloudModelTimeoutException(attempt + 1, e)
                    throw e
                }
                if (!timeout) throw e
                if (attempt == 1) throw CloudModelTimeoutException(attempt + 1, e)
                delay(retryDelayMs)
            }
        }
        error("unreachable")
    }

    private fun isTimeoutException(e: Throwable): Boolean =
        generateSequence<Throwable>(e) { it.cause }.any {
            it is SocketTimeoutException || it is HttpRequestTimeoutException ||
                it is io.ktor.client.network.sockets.SocketTimeoutException ||
                it is io.ktor.client.network.sockets.ConnectTimeoutException
        }
}
