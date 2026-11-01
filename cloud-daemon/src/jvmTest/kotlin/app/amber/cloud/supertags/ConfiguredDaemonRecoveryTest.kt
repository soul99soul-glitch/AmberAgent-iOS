package app.amber.cloud.supertags

import app.amber.ai.ui.UIMessage
import app.amber.cloud.agents.AgentMemoryPolicy
import app.amber.cloud.channel.*
import app.amber.cloud.config.CloudConfigLoader
import app.amber.cloud.loadConfiguredDaemon
import app.amber.cloud.orchestration.CloudPrincipal
import app.amber.cloud.orchestration.WorkItemState
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.security.CredentialRedactor
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.*
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.*
import kotlin.uuid.Uuid

class ConfiguredDaemonRecoveryTest {
    private val fakeKey = "local-provider-stub-key"
    private val env get() = mapOf("AMBER_MASTER_KEY" to "temporary-test-master", "AMBER_MODEL_API_KEY" to fakeKey)
    private val owner = CloudPrincipal.OwnerUser("owner", "local")

    @Test fun missing_model_configuration_fails_clearly_and_echo_requires_explicit_selection() = runBlocking<Unit> {
        val dir = Files.createTempDirectory("daemon-model-config").toFile()
        try {
            val unsafeMaster = assertFailsWith<IllegalArgumentException> {
                loadConfiguredDaemon(dir, env = mapOf("AMBER_MODEL_API_KEY" to fakeKey))
            }
            assertContains(unsafeMaster.message.orEmpty(), "AMBER_MASTER_KEY")
            assertFalse(File(dir, "secrets.enc.json").exists(), "主密钥检查先于任何模型 Key 写入")
            val masterEnv = env - "AMBER_MODEL_API_KEY"
            val missing = assertFailsWith<IllegalArgumentException> { loadConfiguredDaemon(dir, env = masterEnv) }
            assertContains(missing.message.orEmpty(), "AMBER_MODEL_API_KEY")
            val unsupported = assertFailsWith<IllegalArgumentException> {
                loadConfiguredDaemon(dir, env = masterEnv + ("AMBER_MODEL_PROVIDER" to "unknown"))
            }
            assertContains(unsupported.message.orEmpty(), "AMBER_MODEL_PROVIDER")
            val (_, kernel) = loadConfiguredDaemon(dir, env = masterEnv + ("AMBER_MODEL_PROVIDER" to "echo"))
            try {
                assertContains(kernel.modelClient.generateReply(listOf(UIMessage.user("本地开发")), emptyList()).toText(), "本地开发")
            } finally { closeKernel(kernel) }
        } finally { dir.deleteRecursively() }
    }

    @Test fun configured_openai_http_protocol_runs_worker_and_persists_tags() = verifyConfiguredProtocol("openai")
    @Test fun configured_claude_http_protocol_runs_worker_and_persists_tags() = verifyConfiguredProtocol("claude")

    private fun verifyConfiguredProtocol(provider: String) = runBlocking<Unit> {
        val dir = Files.createTempDirectory("daemon-$provider-stub").toFile()
        LocalProvider().use { stub ->
            writeConfig(dir, provider, stub.baseUrl)
            val (_, kernel) = loadConfiguredDaemon(dir, env = env)
            try {
                kernel.recoverColdStartConversations()
                sendScopedWork(kernel)
                withTimeout(10_000) { kernel.router.awaitIdle(includeWorkers = true); kernel.conversationTagger.awaitIdle() }
                val item = kernel.orchestrationStore.listWorkItems().single()
                assertEquals(WorkItemState.COMPLETED, item.state)
                assertEquals("coding", item.agentId)
                assertTrue(kernel.supertagStore.pendingTaggingTurns().isEmpty())
                assertEquals(setOf("dev/amber", "obsolete/tag", "additional/tag"), kernel.supertagStore.tags(scopeId = "coding").map { it.name }.toSet())
                assertTrue(kernel.supertagStore.tags().isEmpty())
                assertEquals(1, stub.taggingCalls.get())
                assertTrue(stub.requests.any { it.body.toString().contains("受管 Worker") })
                assertTrue(stub.requests.any { it.body["tools"] != null }, "主 Router 也走同一个生产客户端")
                assertTrue(stub.requests.all { it.body["model"]?.jsonPrimitive?.content == "local-stub-model" })
                assertTrue(stub.requests.all { request ->
                    if (provider == "openai") request.path == "/v1/chat/completions" && request.authorization == "Bearer $fakeKey"
                    else request.path == "/v1/messages" && request.apiKey == fakeKey
                })
                assertFalse(File(dir, "secrets.enc.json").readText().contains(fakeKey))
            } finally { closeKernel(kernel) }
        }
        dir.deleteRecursively()
    }

    @Test fun in_flight_turn_resumes_from_sqlite_with_original_scope_owner_corrections_and_no_duplicate_commit() = runBlocking<Unit> {
        val dir = Files.createTempDirectory("daemon-tag-restart").toFile()
        LocalProvider(blockFirstTag = true).use { stub ->
            writeConfig(dir, "openai", stub.baseUrl)
            val (_, first) = loadConfiguredDaemon(dir, env = env)
            val pending: PendingTaggingTurn
            try {
                sendScopedWork(first, "检查项目 api_key=temporary-sensitive-value")
                withTimeout(10_000) { first.router.awaitIdle(includeWorkers = true) }
                assertTrue(stub.tagStarted.await(10, TimeUnit.SECONDS))
                pending = first.supertagStore.pendingTaggingTurns().single()
                assertEquals("coding", pending.scopeId)
                assertFalse(pending.text.contains("temporary-sensitive-value"))
                assertContains(pending.text, CredentialRedactor.MASK)
                first.supertagStore.editTag(pending.conversationId, "coding", TagCandidate("dev/amber", "bug", mapOf(
                    "repo" to TagValue(TagFieldType.TEXT, JsonPrimitive("owner-repo")),
                    "status" to TagValue(TagFieldType.STATUS, JsonPrimitive("owner-fixed")),
                )), pending.acceptedAtMs)
                first.supertagStore.removeTag(pending.conversationId, "coding", "obsolete/tag", pending.acceptedAtMs)
                // Cancelling the consumer while HTTP is in flight must leave the accepted row durable.
                first.conversationTagger.closeAndJoin()
                assertEquals(listOf(pending), first.supertagStore.pendingTaggingTurns())
            } finally {
                stub.releaseTag.countDown()
                closeKernel(first)
            }

            // The restart omits AMBER_MODEL_API_KEY: the same existing encrypted vault supplies it.
            val (_, restarted) = loadConfiguredDaemon(dir, env = env - "AMBER_MODEL_API_KEY")
            try {
                restarted.recoverColdStartConversations()
                withTimeout(10_000) { restarted.conversationTagger.awaitIdle() }
                assertTrue(restarted.supertagStore.pendingTaggingTurns().isEmpty())
                assertTrue(restarted.supertagStore.isTagged(pending.turnId, "coding"))
                val tags = restarted.supertagStore.tags(pending.conversationId, "coding")
                assertEquals(setOf("dev/amber", "additional/tag"), tags.map { it.name }.toSet())
                assertEquals("owner-fixed", tags.single { it.name == "dev/amber" }.attributes.getValue("status").value.content)
                assertTrue(restarted.supertagStore.tags().isEmpty())
                val before = restarted.supertagStore.events().size
                val observations = restarted.supertagStore.observations(0)
                assertEquals(1, observations.count { it.turnId == pending.turnId })
                val conversation = restarted.conversationStorage.loadConversation(Uuid.parse(pending.conversationId))!!
                // Settlement appends another assistant node; resubmit the exact accepted model turn.
                val end = conversation.messageNodes.indexOfFirst { it.currentMessage.id.toString() == pending.turnId }
                assertTrue(end >= 0)
                restarted.conversationTagger.enqueue(conversation.copy(messageNodes = conversation.messageNodes.take(end + 1)), "coding")
                restarted.conversationTagger.resumePending()
                withTimeout(10_000) { restarted.conversationTagger.awaitIdle() }
                assertEquals(before, restarted.supertagStore.events().size)
                assertEquals(observations, restarted.supertagStore.observations(0))
                assertEquals(2, stub.taggingCalls.get(), "仅一次被中断请求和一次恢复请求")
            } finally { closeKernel(restarted) }

            val (_, third) = loadConfiguredDaemon(dir, env = env - "AMBER_MODEL_API_KEY")
            try {
                third.recoverColdStartConversations()
                withTimeout(10_000) { third.conversationTagger.awaitIdle() }
                assertEquals(2, stub.taggingCalls.get(), "已提交轮次不会因再次重启重发")
            } finally { closeKernel(third) }
        }
        dir.deleteRecursively()
    }

    private fun writeConfig(dir: File, provider: String, baseUrl: String) {
        File(dir, "amberd.json").writeText(buildJsonObject {
            put("model", buildJsonObject { put("provider", provider); put("id", "local-stub-model"); put("base_url", baseUrl) })
        }.toString())
    }

    private suspend fun sendScopedWork(kernel: CloudAgentKernel, text: String = "检查项目") {
        kernel.hubs.save(owner, HubSettings("coding", "编码", "只读检查", AgentMemoryPolicy.HUB_ISOLATED), 0)
        val connector = Connector()
        kernel.registerConnector(connector)
        val ack = connector.ingress.handleInbound(InboundMessage("local-input", ChannelKind.CUSTOM, "owner", senderId = "owner", text = "@编码 $text"))
        assertTrue(ack.text.startsWith("收到"))
    }

    private suspend fun closeKernel(kernel: CloudAgentKernel) {
        kernel.router.awaitIdle(includeWorkers = true)
        kernel.conversationTagger.closeAndJoin()
        kernel.supertagStore.close(); kernel.agentRegistry.close(); kernel.orchestrationStore.close()
    }

    private class Connector : ChannelConnector {
        override val kind = ChannelKind.CUSTOM
        lateinit var ingress: ChannelIngress
        override fun attachIngress(ingress: ChannelIngress) { this.ingress = ingress }
        override suspend fun start() = Unit
        override suspend fun stop() = Unit
        override suspend fun send(message: OutboundMessage) = Result.success("local-output")
    }

    private class LocalProvider(blockFirstTag: Boolean = false) : Closeable {
        data class Request(val path: String, val authorization: String?, val apiKey: String?, val body: JsonObject)
        val requests = CopyOnWriteArrayList<Request>()
        val taggingCalls = AtomicInteger()
        val tagStarted = CountDownLatch(1)
        val releaseTag = CountDownLatch(1)
        private val blockTag = AtomicBoolean(blockFirstTag)
        private val executor = Executors.newCachedThreadPool { runnable -> Thread(runnable, "local-provider-stub").apply { isDaemon = true } }
        private val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply {
            this.executor = this@LocalProvider.executor
            createContext("/v1/") { respond(it) }
            start()
        }
        val baseUrl get() = "http://127.0.0.1:${server.address.port}/v1"

        private fun respond(exchange: HttpExchange) {
            try {
                val body = Json.parseToJsonElement(exchange.requestBody.bufferedReader().readText()).jsonObject
                requests += Request(exchange.requestURI.path, exchange.requestHeaders.getFirst("Authorization"), exchange.requestHeaders.getFirst("x-api-key"), body)
                val tagging = body.toString().contains("你是对话标签提取器")
                if (tagging) {
                    taggingCalls.incrementAndGet()
                    tagStarted.countDown()
                    if (blockTag.compareAndSet(true, false)) check(releaseTag.await(15, TimeUnit.SECONDS))
                }
                val text = if (tagging) """{"tags":[{"name":"dev/amber","templateId":"bug","attributes":{"repo":{"type":"TEXT","value":"model-repo"},"status":{"type":"STATUS","value":"model-fixed"}}},{"name":"obsolete/tag"},{"name":"additional/tag"}]}""" else "检查完成"
                val response = buildJsonObject {
                    put("id", "local-response"); put("model", "local-stub-model")
                    if (exchange.requestURI.path.endsWith("/messages")) {
                        put("type", "message"); put("role", "assistant"); put("stop_reason", "end_turn")
                        put("content", buildJsonArray { add(buildJsonObject {
                            if(!tagging && body.toString().contains("受管 Worker")) {
                                put("type","tool_use");put("id","finish");put("name","task_finish");put("input",buildJsonObject {put("outcome","completed");put("summary",text)})
                            }else {put("type", "text"); put("text", text)}
                        }) })
                        put("usage", buildJsonObject { put("input_tokens", 1); put("output_tokens", 1) })
                    } else {
                        put("object", "chat.completion")
                        put("choices", buildJsonArray { add(buildJsonObject {
                            put("index", 0); put("finish_reason", "stop")
                            put("message", buildJsonObject { put("role", "assistant"); put("content", text)
                                if(!tagging && body.toString().contains("受管 Worker"))put("tool_calls",buildJsonArray {add(buildJsonObject {
                                    put("id","finish");put("type","function");put("function",buildJsonObject {put("name","task_finish");put("arguments",buildJsonObject {put("outcome","completed");put("summary",text)}.toString())})
                                })})
                            })
                        }) })
                    }
                }.toString().toByteArray(Charsets.UTF_8)
                exchange.responseHeaders.add("Content-Type", "application/json; charset=utf-8")
                exchange.sendResponseHeaders(200, response.size.toLong())
                exchange.responseBody.use { it.write(response) }
            } catch (_: IOException) {
                // The first recovery-test client is deliberately cancelled while the response is held.
            } finally { exchange.close() }
        }

        override fun close() { releaseTag.countDown(); server.stop(0); executor.shutdownNow() }
    }
}
