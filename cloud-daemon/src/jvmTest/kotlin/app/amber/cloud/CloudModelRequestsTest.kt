package app.amber.cloud

import app.amber.ai.provider.ProviderSetting
import app.amber.ai.ui.UIMessage
import app.amber.cloud.runtime.*
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.*
import java.net.InetSocketAddress
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.*

class CloudModelRequestsTest {
    private suspend fun server(delays: List<Long>, block: suspend (String, AtomicInteger) -> Unit) {
        val count = AtomicInteger()
        val executor = Executors.newCachedThreadPool { r -> Thread(r, "model-timeout-stub").apply { isDaemon = true } }
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.executor = executor
        server.createContext("/chat/completions") { exchange ->
            val call = count.incrementAndGet()
            exchange.requestBody.use { it.readBytes() }
            try {
                Thread.sleep(delays.getOrElse(call - 1) { delays.last() })
                val body = """{"id":"stub","choices":[{"index":0,"message":{"role":"assistant","content":"完成"},"finish_reason":"stop"}]}""".toByteArray()
                exchange.responseHeaders.add("Content-Type", "application/json")
                exchange.sendResponseHeaders(200, body.size.toLong())
                exchange.responseBody.use { it.write(body) }
            } catch (_: java.io.IOException) { /* The client may already have timed out. */ }
              catch (_: InterruptedException) { Thread.currentThread().interrupt() }
            finally { exchange.close() }
        }
        server.start()
        try { block("http://127.0.0.1:${server.address.port}", count) }
        finally { server.stop(0); executor.shutdownNow() }
    }

    @Test fun cloud_default_waits_beyond_the_old_engine_socket_timeout() = runBlocking {
        server(listOf(10_500)) { url, calls ->
            val http = cloudModelHttpClient()
            try {
                val model = KmpProviderModelClient(ProviderSetting.OpenAI(apiKey = "fake-key", baseUrl = url), "stub", http)
                assertEquals("完成", withTimeout(15_000) { model.generateReply(listOf(UIMessage.user("检查")), emptyList()) }.toText())
                assertEquals(1, calls.get())
            } finally { http.close() }
        }
    }

    @Test fun socket_timeout_retries_once_and_only_returns_the_successful_answer() = runBlocking {
        server(listOf(500, 0)) { url, calls ->
            val http = cloudModelHttpClient(requestTimeoutMs = 2_000, socketTimeoutMs = 150)
            try {
                val model = KmpProviderModelClient(ProviderSetting.OpenAI(apiKey = "fake-key", baseUrl = url), "stub", http, retryDelayMs = 1)
                assertEquals("完成", model.generateReply(listOf(UIMessage.user("检查")), emptyList()).toText())
                assertEquals(2, calls.get())
            } finally { http.close() }
        }
    }

    @Test fun exhausted_timeout_is_bounded_and_has_a_safe_retry_explanation() = runBlocking {
        server(listOf(500)) { url, calls ->
            val http = cloudModelHttpClient(requestTimeoutMs = 150, socketTimeoutMs = 2_000)
            try {
                val model = KmpProviderModelClient(ProviderSetting.OpenAI(apiKey = "fake-key", baseUrl = url), "stub", http, retryDelayMs = 1)
                val failure = assertFailsWith<CloudModelTimeoutException> { model.generateReply(listOf(UIMessage.user("检查")), emptyList()) }
                assertEquals(2, calls.get())
                assertEquals(2, failure.attempts)
                assertContains(cloudFailureSummary(failure), "自动重试 1 次")
                assertFalse(cloudFailureSummary(failure).contains(url))
                assertFalse(cloudFailureSummary(failure).contains("Socket"))
            } finally { http.close() }
        }
    }

    @Test fun cancellation_never_retries() = runBlocking {
        server(listOf(2_000)) { url, calls ->
            val http = cloudModelHttpClient()
            try {
                val model = KmpProviderModelClient(ProviderSetting.OpenAI(apiKey = "fake-key", baseUrl = url), "stub", http, retryDelayMs = 1)
                val request = launch { model.generateReply(listOf(UIMessage.user("检查")), emptyList()) }
                withTimeout(2_000) { while (calls.get() == 0) delay(5) }
                request.cancelAndJoin()
                delay(20)
                assertEquals(1, calls.get())
            } finally { http.close() }
        }
    }
}
