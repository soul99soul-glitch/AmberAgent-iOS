package app.amber.cloud

import app.amber.cloud.agents.AgentMemoryPolicy
import app.amber.cloud.agents.AgentProfile
import app.amber.cloud.gateway.AgentCentricApi
import app.amber.cloud.gateway.CloudGatewayState
import app.amber.cloud.gateway.configureCloudGateway
import app.amber.cloud.orchestration.CloudPrincipal
import app.amber.cloud.orchestration.WorkerSettlementReport
import app.amber.cloud.orchestration.WorkItemState
import app.amber.cloud.runtime.CloudAgentKernel
import com.sun.net.httpserver.HttpServer
import io.ktor.client.request.*
import io.ktor.client.statement.bodyAsText
import io.ktor.server.testing.testApplication
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.*
import java.io.Closeable
import java.io.File
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.*

class NativeTaskHttpTest {
    private val master = "native-task-test-master"
    private val key = "native-task-stub-key"

    @Test fun paired_openai_task_persists_result_and_replays_after_restart() = verifyProtocol("openai")
    @Test fun paired_claude_task_persists_result_and_replays_after_restart() = verifyProtocol("claude")

    private fun verifyProtocol(provider: String) {
        val dir = Files.createTempDirectory("native-task-$provider").toFile()
        ProviderStub().use { stub ->
            // Existing pairing data predates bootstrap. It must remain usable after the upgrade.
            val oldState = CloudGatewayState(dir)
            val paired = oldState.pairDevice(oldState.issuePairingTicket(), "ios", "local test") as CloudGatewayState.PairResult.Success
            val identity = oldState.identityFile.readText()
            val body = """{"requestId":"phone-retry-1","agentId":"research","title":"分析","text":"只分析专题资料"}"""
            val kernel = boot(dir, provider, stub)
            var workId = ""
            try {
                kernel.agentRegistry.save(CloudPrincipal.OwnerUser("owner", "test"), AgentProfile(
                    "research", "研究", instructions = "只回答专题问题", memoryPolicy = AgentMemoryPolicy.HUB_ISOLATED,
                ), 0)
                kernel.memoryStore.saveSoulPrompt("不可召回的全局身份")
                kernel.memoryStore.upsertMemory("专题记忆", agentId = "research")
                testApplication {
                    application { configureCloudGateway(kernel.gatewayState, agentApi = AgentCentricApi(kernel)) }
                    assertEquals(401, client.post("/v2/work-items") { setBody(body) }.status.value)
                    assertEquals(400, client.post("/v2/work-items") { bearerAuth(paired.token); setBody("{") }.status.value)
                    assertEquals(400, client.post("/v2/work-items") { bearerAuth(paired.token); setBody("""{"requestId":"bad","text":" "}""") }.status.value)
                    assertEquals(404, client.post("/v2/work-items") { bearerAuth(paired.token); setBody("""{"requestId":"missing","agentId":"absent","text":"test"}""") }.status.value)
                    val accepted = client.post("/v2/work-items") { bearerAuth(paired.token); setBody(body) }
                    assertEquals(202, accepted.status.value)
                    val receipt = Json.parseToJsonElement(accepted.bodyAsText()).jsonObject
                    workId = receipt["workItem"]!!.jsonObject["id"]!!.jsonPrimitive.content
                    assertEquals("research", receipt["workItem"]!!.jsonObject["agentId"]!!.jsonPrimitive.content)
                    assertFalse(receipt["replayed"]!!.jsonPrimitive.boolean)
                    val changed = body.replace("只分析专题资料", "改成另一件事")
                    assertEquals(409, client.post("/v2/work-items") { bearerAuth(paired.token); setBody(changed) }.status.value)
                    withTimeout(10_000) {
                        while (true) {
                            val response = client.get("/v2/work-items/$workId") { bearerAuth(paired.token) }
                            assertEquals(200, response.status.value)
                            val detail = Json.parseToJsonElement(response.bodyAsText()).jsonObject
                            assertFalse(detail["workItem"]!!.jsonObject["state"]!!.jsonPrimitive.content in setOf("FAILED", "CANCELLED"), detail.toString())
                            if (detail["workItem"]!!.jsonObject["state"]!!.jsonPrimitive.content == "COMPLETED") {
                                val result = detail["resultMarkdown"]!!.jsonPrimitive.content
                                assertContains(result, "模型结果")
                                assertContains(result, "```json\n{\"answer\":42}\n```", message = "结果保留用户所需代码和 JSON")
                                assertFalse(result.contains("sensitive-stub-value"))
                                assertFalse(response.bodyAsText().contains("workerSessionId"))
                                break
                            }
                            delay(25)
                        }
                    }
                }
                runBlocking { kernel.router.awaitIdle(includeWorkers = true); kernel.conversationTagger.awaitIdle() }
                val worker = stub.requests.single { it.body.toString().contains("受管 Worker") }
                assertContains(worker.body.toString(), "只回答专题问题")
                assertContains(worker.body.toString(), "专题记忆")
                assertFalse(worker.body.toString().contains("不可召回的全局身份"))
                assertEquals(if (provider == "openai") "/v1/chat/completions" else "/v1/messages", worker.path)
                assertEquals(if (provider == "openai") "Bearer $key" else key, worker.credential)
                assertEquals("native-stub-model", worker.body["model"]!!.jsonPrimitive.content)
            } finally { close(kernel) }

            val calls = stub.requests.size
            val restarted = boot(dir, provider, stub, includeKey = false)
            try {
                testApplication {
                    application { configureCloudGateway(restarted.gatewayState, agentApi = AgentCentricApi(restarted)) }
                    val result = client.get("/v2/work-items/$workId") { bearerAuth(paired.token) }
                    assertEquals(200, result.status.value)
                    assertContains(result.bodyAsText(), "模型结果")
                    val replay = client.post("/v2/work-items") { bearerAuth(paired.token); setBody(body) }
                    assertEquals(200, replay.status.value)
                    val receipt = Json.parseToJsonElement(replay.bodyAsText()).jsonObject
                    assertTrue(receipt["replayed"]!!.jsonPrimitive.boolean)
                    assertEquals(workId, receipt["workItem"]!!.jsonObject["id"]!!.jsonPrimitive.content)
                }
                assertEquals(calls, stub.requests.size, "重试和重启后的查询不再次执行模型")
                assertEquals(1, restarted.orchestrationStore.listWorkItems().size)
                assertEquals(identity, File(dir, "identity.json").readText())
                assertEquals(paired.deviceId, restarted.gatewayState.loadDevicesStrict().single().id)
            } finally { close(restarted) }
        }
        dir.deleteRecursively()
    }

    @Test fun cancel_is_authenticated_idempotent_and_never_becomes_completed_later() {
        val dir = Files.createTempDirectory("native-task-cancel").toFile()
        ProviderStub(blockWorker = true).use { stub ->
            val kernel = boot(dir, "openai", stub)
            try {
                val pair = kernel.gatewayState.pairDevice(kernel.gatewayState.issuePairingTicket(), "ios", "test") as CloudGatewayState.PairResult.Success
                testApplication {
                    application { configureCloudGateway(kernel.gatewayState, agentApi = AgentCentricApi(kernel)) }
                    val body = """{"requestId":"cancel-task","text":"执行缓慢任务"}"""
                    val accepted = client.post("/v2/work-items") { bearerAuth(pair.token); setBody(body) }
                    assertEquals(202, accepted.status.value)
                    val item = Json.parseToJsonElement(accepted.bodyAsText()).jsonObject["workItem"]!!.jsonObject
                    assertEquals("main", item["agentId"]!!.jsonPrimitive.content)
                    val id = item["id"]!!.jsonPrimitive.content
                    assertTrue(stub.started.await(10, TimeUnit.SECONDS))
                    val duplicate = client.post("/v2/work-items") { bearerAuth(pair.token); setBody(body) }
                    assertEquals(200, duplicate.status.value)
                    assertEquals(401, client.post("/v2/work-items/$id/cancel").status.value)
                    val cancelled = client.post("/v2/work-items/$id/cancel") { bearerAuth(pair.token) }
                    assertEquals(200, cancelled.status.value)
                    assertEquals("CANCELLED", Json.parseToJsonElement(cancelled.bodyAsText()).jsonObject["workItem"]!!.jsonObject["state"]!!.jsonPrimitive.content)
                    assertEquals(200, client.post("/v2/work-items/$id/cancel") { bearerAuth(pair.token) }.status.value)
                    stub.release.countDown()
                    val result = client.get("/v2/work-items/$id") { bearerAuth(pair.token) }
                    assertEquals("CANCELLED", Json.parseToJsonElement(result.bodyAsText()).jsonObject["workItem"]!!.jsonObject["state"]!!.jsonPrimitive.content)
                    val record = kernel.orchestrationStore.getWorkItem(id)!!
                    val principal = kernel.orchestrationKernel.workerPrincipalFor(record)
                    kernel.orchestrationKernel.updateWorkerProgress(principal, id, record.progressRevision, "晚到进度")
                    assertEquals(WorkItemState.CANCELLED, kernel.orchestrationKernel.reportWorkerSettlement(
                        principal, WorkerSettlementReport(id, "completed", "晚到结果"),
                    ).state)
                    assertEquals(0, kernel.orchestrationStore.countHeldSlots())
                    assertEquals(1, kernel.orchestrationStore.listWorkItems().size)
                }
            } finally { stub.release.countDown(); close(kernel) }
        }
        dir.deleteRecursively()
    }

    @Test fun provider_rejection_is_a_queryable_failure_instead_of_echo_success() {
        val dir = Files.createTempDirectory("native-task-failure").toFile()
        ProviderStub(rejectWorker = true).use { stub ->
            val kernel = boot(dir, "openai", stub)
            try {
                val pair = kernel.gatewayState.pairDevice(kernel.gatewayState.issuePairingTicket(), "ios", "test") as CloudGatewayState.PairResult.Success
                testApplication {
                    application { configureCloudGateway(kernel.gatewayState, agentApi = AgentCentricApi(kernel)) }
                    val accepted = client.post("/v2/work-items") {
                        bearerAuth(pair.token); setBody("""{"requestId":"rejected-task","text":"执行模型任务"}""")
                    }
                    assertEquals(202, accepted.status.value)
                    val id = Json.parseToJsonElement(accepted.bodyAsText()).jsonObject["workItem"]!!.jsonObject["id"]!!.jsonPrimitive.content
                    withTimeout(10_000) {
                        while (true) {
                            val result = Json.parseToJsonElement(client.get("/v2/work-items/$id") { bearerAuth(pair.token) }.bodyAsText()).jsonObject
                            val state = result["workItem"]!!.jsonObject["state"]!!.jsonPrimitive.content
                            assertNotEquals("COMPLETED", state)
                            if (state == "FAILED") {
                                assertTrue(result["failure"]!!.jsonPrimitive.content.isNotBlank())
                                assertFalse(result.toString().contains("sensitive-stub-value"))
                                break
                            }
                            delay(25)
                        }
                    }
                    assertEquals(0, kernel.orchestrationStore.countHeldSlots())
                }
            } finally { close(kernel) }
        }
        dir.deleteRecursively()
    }

    private fun boot(dir: File, provider: String, stub: ProviderStub, includeKey: Boolean = true): CloudAgentKernel {
        val env = mapOf("AMBER_MASTER_KEY" to master, "AMBER_MODEL_PROVIDER" to provider,
            "AMBER_MODEL_ID" to "native-stub-model", "AMBER_MODEL_BASE_URL" to stub.baseUrl) +
            if (includeKey) mapOf("AMBER_MODEL_API_KEY" to key) else emptyMap()
        return loadConfiguredDaemon(dir, env = env).kernel.also { runBlocking { it.recoverColdStartConversations() } }
    }

    private fun close(kernel: CloudAgentKernel) = runBlocking {
        kernel.router.awaitIdle(includeWorkers = true)
        kernel.conversationTagger.closeAndJoin()
        kernel.supertagStore.close(); kernel.agentRegistry.close(); kernel.orchestrationStore.close()
    }

    private class ProviderStub(private val blockWorker: Boolean = false, private val rejectWorker: Boolean = false) : Closeable {
        data class Request(val path: String, val credential: String?, val body: JsonObject)
        val requests = CopyOnWriteArrayList<Request>()
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        private val executor = Executors.newCachedThreadPool { r -> Thread(r, "native-task-stub").apply { isDaemon = true } }
        private val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply {
            this.executor = this@ProviderStub.executor
            createContext("/v1/") { exchange ->
                try {
                    val body = Json.parseToJsonElement(exchange.requestBody.bufferedReader().readText()).jsonObject
                    val claude = exchange.requestURI.path.endsWith("/messages")
                    requests += Request(exchange.requestURI.path, exchange.requestHeaders.getFirst(if (claude) "x-api-key" else "Authorization"), body)
                    if (body.toString().contains("受管 Worker")) {
                        started.countDown()
                        if (blockWorker) check(release.await(15, TimeUnit.SECONDS))
                        if (rejectWorker) {
                            val error = """{"error":{"message":"local rejection api_key=sensitive-stub-value","type":"authentication_error"}}""".toByteArray()
                            exchange.responseHeaders.add("Content-Type", "application/json")
                            exchange.sendResponseHeaders(401, error.size.toLong())
                            exchange.responseBody.use { it.write(error) }
                            return@createContext
                        }
                    }
                    val text = if (body.toString().contains("你是对话标签提取器")) "{\"tags\":[]}"
                        else "模型结果\n```json\n{\"answer\":42}\n```\napi_key=sensitive-stub-value"
                    val response = buildJsonObject {
                        put("id", "native-response"); put("model", "native-stub-model")
                        if (claude) {
                            put("type", "message"); put("role", "assistant"); put("stop_reason", "tool_use")
                            put("content", buildJsonArray { add(buildJsonObject {
                                if (body.toString().contains("受管 Worker")) {
                                    put("type","tool_use");put("id","finish");put("name","task_finish");put("input",buildJsonObject {put("outcome","completed");put("summary",text)})
                                } else {put("type", "text"); put("text", text)}
                            }) })
                            put("usage", buildJsonObject { put("input_tokens", 1); put("output_tokens", 1) })
                        } else put("choices", buildJsonArray { add(buildJsonObject {
                            put("index", 0); put("finish_reason", "stop")
                            put("message", buildJsonObject { put("role", "assistant"); put("content", text)
                                if(body.toString().contains("受管 Worker"))put("tool_calls",buildJsonArray {add(buildJsonObject {
                                    put("id","finish");put("type","function");put("function",buildJsonObject {put("name","task_finish");put("arguments",buildJsonObject {put("outcome","completed");put("summary",text)}.toString())})
                                })})
                            })
                        }) })
                    }.toString().toByteArray()
                    exchange.responseHeaders.add("Content-Type", "application/json")
                    exchange.sendResponseHeaders(200, response.size.toLong())
                    exchange.responseBody.use { it.write(response) }
                } catch (_: java.io.IOException) { /* Cancellation closes the HTTP client. */ }
                finally { exchange.close() }
            }
            start()
        }
        val baseUrl get() = "http://127.0.0.1:${server.address.port}/v1"
        override fun close() { release.countDown(); server.stop(0); executor.shutdownNow() }
    }
}
