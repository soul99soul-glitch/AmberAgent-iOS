package app.amber.cloud.runtime

import app.amber.ai.core.MessageRole
import app.amber.ai.core.Tool
import app.amber.ai.provider.*
import app.amber.ai.provider.claude.claudeProviderWithClient
import app.amber.ai.provider.openai.openAIProviderWithClient
import app.amber.ai.ui.UIMessage
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.HttpRequestTimeoutException
import io.ktor.client.plugins.HttpTimeout
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
) : CloudModelClient {
    private val openAIProvider by lazy { openAIProviderWithClient(httpClient) }
    private val claudeProvider by lazy { claudeProviderWithClient(httpClient) }

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
                val timeout = generateSequence<Throwable>(e) { it.cause }.any {
                    it is SocketTimeoutException || it is HttpRequestTimeoutException ||
                        it is io.ktor.client.network.sockets.SocketTimeoutException ||
                        it is io.ktor.client.network.sockets.ConnectTimeoutException
                }
                if (!timeout) throw e
                if (attempt == 1) throw CloudModelTimeoutException(attempt + 1, e)
                // Only generation is retried: no returned tool call has been executed yet.
                delay(retryDelayMs)
            }
        }
        error("unreachable")
    }
}
