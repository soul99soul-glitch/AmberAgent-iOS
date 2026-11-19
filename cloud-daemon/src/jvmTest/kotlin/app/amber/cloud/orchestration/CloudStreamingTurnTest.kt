package app.amber.cloud.orchestration

import app.amber.ai.core.MessageRole
import app.amber.ai.core.Tool
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.gateway.AgentCentricApi
import app.amber.cloud.gateway.NativeTaskRequest
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.runtime.CloudModelTimeoutException
import app.amber.cloud.runtime.CloudToolDefinition
import app.amber.cloud.runtime.CloudToolRegistry
import app.amber.cloud.runtime.KmpProviderModelClient
import app.amber.cloud.runtime.StreamActivity
import app.amber.cloud.runtime.ToolEffect
import app.amber.cloud.runtime.cloudStreamHttpClient
import app.amber.core.storage.conversation.ConversationFile
import app.amber.core.storage.conversation.JsonConversationStorage
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CloudStreamingTurnTest {

    private suspend fun sseServer(
        handler: (call: Int, flushEvent: (String) -> Unit) -> Unit,
        block: suspend (String, AtomicInteger) -> Unit,
    ) {
        val calls = AtomicInteger()
        val executor = Executors.newCachedThreadPool { r -> Thread(r, "stream-stub").apply { isDaemon = true } }
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.executor = executor
        server.createContext("/chat/completions") { exchange ->
            val call = calls.incrementAndGet()
            exchange.requestBody.use { it.readBytes() }
            exchange.responseHeaders.add("Content-Type", "text/event-stream; charset=utf-8")
            exchange.responseHeaders.add("Cache-Control", "no-cache")
            exchange.sendResponseHeaders(200, 0)
            val out = exchange.responseBody
            try {
                handler(call) { line ->
                    out.write(line.toByteArray())
                    out.flush()
                }
            } catch (_: Throwable) {
                // Expected when tests intentionally abort stream or trigger idle timeout.
            } finally {
                runCatching { out.close() }
                exchange.close()
            }
        }
        server.start()
        try {
            block("http://127.0.0.1:${server.address.port}", calls)
        } finally {
            server.stop(0)
            executor.shutdownNow()
        }
    }

    private fun openAiTextChunk(content: String): String =
        """data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"stub","choices":[{"index":0,"delta":{"role":"assistant","content":"$content"},"finish_reason":null}]}""" + "\n\n"

    private fun openAiToolStartChunk(callId: String, name: String, argsPart: String): String =
        """data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"stub","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"$callId","type":"function","function":{"name":"$name","arguments":"$argsPart"}}]},"finish_reason":null}]}""" + "\n\n"

    private fun openAiToolArgsChunk(argsPart: String): String =
        """data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"stub","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"$argsPart"}}]},"finish_reason":null}]}""" + "\n\n"

    private fun openAiStopChunk(reason: String = "stop"): String =
        """data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"stub","choices":[{"index":0,"delta":{},"finish_reason":"$reason"}]}""" + "\n\n" + "data: [DONE]\n\n"

    private class WorkerHarness(
        val dir: File = Files.createTempDirectory("stream-turn").toFile(),
        val modelClient: CloudModelClient,
    ) {
        val kernel = CloudAgentKernel(
            dataDir = dir,
            modelClient = modelClient,
            masterSecretOverride = "stream-turn-fixture",
        )
        val api = AgentCentricApi(kernel)
        val device: app.amber.cloud.gateway.PairedDevice

        init {
            kernel.gatewayState.pairDevice(kernel.gatewayState.issuePairingTicket(), "ios", "fixture")
            device = kernel.gatewayState.loadDevicesStrict().single()
        }

        suspend fun submit(requestId: String, prompt: String = "流式执行任务") =
            api.tasks.submit(device, NativeTaskRequest(requestId, prompt, title = "流式任务"))

        suspend fun awaitIdle() = withTimeout(15_000) { kernel.router.awaitIdle(includeWorkers = true) }

        suspend fun close() {
            kernel.orchestrationStore.listWorkItems().filter { !it.state.isTerminal }.forEach {
                kernel.orchestrationKernel.cancelWorkItem(CloudPrincipal.OwnerUser(device.id, "app"), it.workItemId)
            }
            awaitIdle()
            kernel.nativeDialogue.closeAndJoin()
            kernel.conversationTagger.closeAndJoin()
            kernel.agentRegistry.close()
            kernel.orchestrationStore.close()
            kernel.supertagStore.close()
            dir.deleteRecursively()
        }
    }

    @Test
    fun c1_stream_reply_accumulates_sse_text_and_tool_call_deltas() = runBlocking {
        sseServer({ _, send ->
            send(openAiTextChunk("先检查"))
            send(openAiTextChunk("进度。"))
            send(openAiToolStartChunk("call-1", "task_finish", """{\"outcome\":\"completed\","""))
            send(openAiToolArgsChunk("""\"summary\":\"全部完成\"}"""))
            send(openAiStopChunk("tool_calls"))
        }) { url, calls ->
            val streamHttp = cloudStreamHttpClient(idleTimeoutMs = 5_000)
            try {
                val client = KmpProviderModelClient(
                    providerSetting = ProviderSetting.OpenAI(apiKey = "fake-key", baseUrl = url),
                    modelId = "stub",
                    streamHttpClient = streamHttp,
                )
                val activities = CopyOnWriteArrayList<StreamActivity>()
                val reply = client.streamReply(listOf(UIMessage.user("开始")), emptyList()) {
                    activities += it
                }
                assertEquals(1, calls.get())
                assertEquals("先检查进度。", reply.parts.filterIsInstance<UIMessagePart.Text>().joinToString("") { it.text })
                val tool = reply.getTools().single()
                assertEquals("call-1", tool.toolCallId)
                assertEquals("task_finish", tool.toolName)
                assertEquals("""{"outcome":"completed","summary":"全部完成"}""", tool.input)
                assertTrue(activities.any { it.kind == "text" && it.deltaTextChars > 0 })
                assertTrue(activities.any { it.kind == "tool_delta" && it.toolName == "task_finish" })
            } finally {
                streamHttp.close()
            }
        }
    }

    @Test
    fun c2_mid_stream_exception_preserves_failure_and_never_retries() = runBlocking {
        sseServer({ _, send ->
            send(openAiTextChunk("半截输出"))
        }) { url, calls ->
            val streamHttp = cloudStreamHttpClient(idleTimeoutMs = 5_000)
            try {
                val client = KmpProviderModelClient(
                    providerSetting = ProviderSetting.OpenAI(apiKey = "fake-key", baseUrl = url),
                    modelId = "stub",
                    retryDelayMs = 1,
                    streamHttpClient = streamHttp,
                )
                assertFailsWith<Exception> {
                    client.streamReply(listOf(UIMessage.user("开始")), emptyList()) {}
                }
                assertEquals(1, calls.get())
            } finally {
                streamHttp.close()
            }
        }
    }

    @Test
    fun c3_stop_cooperatively_cancels_in_flight_stream_under_1s() = runBlocking {
        val streamStarted = CompletableDeferred<Unit>()
        val streamCancelled = CompletableDeferred<Unit>()
        val toolCalled = AtomicInteger()
        val harness = WorkerHarness(
            modelClient = object : CloudModelClient {
                override suspend fun generateReply(messages: List<UIMessage>, tools: List<Tool>): UIMessage =
                    error("should use streamReply")

                override suspend fun streamReply(
                    messages: List<UIMessage>,
                    tools: List<Tool>,
                    onActivity: (StreamActivity) -> Unit,
                ): UIMessage {
                    if (!messages.first().toText().contains("受管 Worker")) {
                        return UIMessage.assistant("""{"tags":[]}""")
                    }
                    onActivity(StreamActivity("text", deltaTextChars = 4))
                    streamStarted.complete(Unit)
                    try {
                        awaitCancellation()
                    } finally {
                        streamCancelled.complete(Unit)
                    }
                }
            },
        )
        try {
            val submitted = harness.submit("c3-stop")
            val itemId = submitted.workItem.id
            withTimeout(5_000) { streamStarted.await() }
            val startStopMs = System.currentTimeMillis()
            harness.kernel.orchestrationKernel.cancelWorkItem(
                CloudPrincipal.OwnerUser(harness.device.id, "app"),
                itemId,
            )
            withTimeout(1_000) { streamCancelled.await() }
            harness.awaitIdle()
            val elapsed = System.currentTimeMillis() - startStopMs
            assertTrue(elapsed < 1_000L, "stop should cancel stream under 1s, was ${elapsed}ms")
            val item = harness.kernel.orchestrationStore.getWorkItem(itemId)!!
            assertEquals(WorkItemState.CANCELLED, item.state)
            assertEquals(0, toolCalled.get())
        } finally {
            harness.close()
        }
    }

    @Test
    fun c3_followup_cancels_in_flight_stream_without_persisting_partial_and_consumes_once() = runBlocking {
        val firstChunkArrived = CompletableDeferred<Unit>()
        val firstStreamCancelled = CompletableDeferred<Unit>()
        val callCount = AtomicInteger()
        val harness = WorkerHarness(
            modelClient = object : CloudModelClient {
                override suspend fun generateReply(messages: List<UIMessage>, tools: List<Tool>): UIMessage =
                    error("should use streamReply")

                override suspend fun streamReply(
                    messages: List<UIMessage>,
                    tools: List<Tool>,
                    onActivity: (StreamActivity) -> Unit,
                ): UIMessage {
                    if (!messages.first().toText().contains("受管 Worker")) {
                        return UIMessage.assistant("""{"tags":[]}""")
                    }
                    val call = callCount.incrementAndGet()
                    if (call == 1) {
                        onActivity(StreamActivity("text", deltaTextChars = 6))
                        firstChunkArrived.complete(Unit)
                        try {
                            awaitCancellation()
                        } finally {
                            firstStreamCancelled.complete(Unit)
                        }
                    }
                    val hasFollowup = messages.any { it.toText().contains("改查端口配置") }
                    assertTrue(hasFollowup, "second stream turn must see new followup")
                    return UIMessage(
                        role = MessageRole.ASSISTANT,
                        parts = listOf(
                            UIMessagePart.Tool(
                                toolCallId = "fin-followup",
                                toolName = "task_finish",
                                input = """{"outcome":"completed","summary":"已按补充改查端口"}""",
                            ),
                        ),
                    )
                }
            },
        )
        try {
            val submitted = harness.submit("c3-followup")
            val itemId = submitted.workItem.id
            withTimeout(5_000) { firstChunkArrived.await() }
            harness.kernel.nativeDialogue.submit(
                device = harness.device,
                requestId = "c3-followup-req",
                text = "改查端口配置",
                kind = "followup",
                workItemId = itemId,
            )
            withTimeout(2_000) { firstStreamCancelled.await() }
            harness.awaitIdle()
            val item = harness.kernel.orchestrationStore.getWorkItem(itemId)!!
            assertEquals(WorkItemState.COMPLETED, item.state)
            assertEquals(2, callCount.get())
            val followupInput = harness.kernel.orchestrationStore.dialogue.find(harness.device.id, "c3-followup-req")!!
            assertTrue(harness.kernel.orchestrationStore.dialogue.isConsumed(followupInput.id))
            val consumedEvents = harness.kernel.orchestrationStore.dialogue.page(after = 0, limit = 100).items
                .filter { it.workItemId == itemId && it.kind == "input_consumed" && it.id == "consumed:${followupInput.id}" }
            assertEquals(1, consumedEvents.size, "followup input_consumed must appear exactly once")
        } finally {
            harness.close()
        }
    }

    @Test
    fun c4_streaming_does_not_emit_per_chunk_dialogue_events_and_page_after_is_monotonic() = runBlocking {
        val midStreamGate = CompletableDeferred<Unit>()
        val allowFinish = CompletableDeferred<Unit>()
        val harness = WorkerHarness(
            modelClient = object : CloudModelClient {
                override suspend fun generateReply(messages: List<UIMessage>, tools: List<Tool>): UIMessage =
                    error("should use streamReply")

                override suspend fun streamReply(
                    messages: List<UIMessage>,
                    tools: List<Tool>,
                    onActivity: (StreamActivity) -> Unit,
                ): UIMessage {
                    if (!messages.first().toText().contains("受管 Worker")) {
                        // Router turn dispatches work item
                        return UIMessage(
                            role = MessageRole.ASSISTANT,
                            parts = listOf(
                                UIMessagePart.Tool(
                                    toolCallId = "dispatch-c4",
                                    toolName = "dispatch_work",
                                    input = """{"tasks":[{"task_key":"c4-task","title":"流式测试","brief":"产出多chunk并结算"}]}""",
                                ),
                            ),
                        )
                    }
                    repeat(20) {
                        onActivity(StreamActivity("text", deltaTextChars = 5))
                        delay(2)
                    }
                    midStreamGate.complete(Unit)
                    allowFinish.await()
                    return UIMessage(
                        role = MessageRole.ASSISTANT,
                        parts = listOf(
                            UIMessagePart.Tool(
                                toolCallId = "fin-c4",
                                toolName = "task_finish",
                                input = """{"outcome":"completed","summary":"流式无逐chunk落库"}""",
                            ),
                        ),
                    )
                }
            },
        )
        try {
            harness.kernel.nativeDialogue.submit(harness.device, "c4-mono", "执行流式测试")
            withTimeout(5_000) { midStreamGate.await() }
            val midPage = harness.kernel.orchestrationStore.dialogue.page(after = 0, limit = 100).items
            assertTrue(midPage.isNotEmpty())
            assertTrue(midPage.size < 10, "mid-stream must not emit per-chunk dialogue events, got ${midPage.size}")
            val cursor = midPage.last().seq
            allowFinish.complete(Unit)
            harness.awaitIdle()
            val tailPage = harness.kernel.orchestrationStore.dialogue.page(after = cursor, limit = 100).items
            val combined = midPage + tailPage
            assertTrue(tailPage.isNotEmpty())
            assertEquals(combined.map { it.seq }.sorted(), combined.map { it.seq })
            assertTrue(combined.zipWithNext().all { (a, b) -> a.seq < b.seq })
            assertEquals(combined.map { it.id }.distinct().size, combined.size)
            assertTrue(combined.size < 20, "must not emit one dialogue event per streamed chunk")
            assertEquals(WorkItemState.COMPLETED, harness.kernel.orchestrationStore.listWorkItems().single().state)
        } finally {
            harness.close()
        }
    }

    @Test
    fun c5_idle_timeout_allows_long_multi_chunk_stream_and_fails_on_idle_gap() = runBlocking {
        sseServer({ _, send ->
            repeat(4) { i ->
                Thread.sleep(80)
                send(openAiTextChunk("段$i"))
            }
            send(openAiStopChunk())
        }) { url, calls ->
            val streamHttp = cloudStreamHttpClient(idleTimeoutMs = 200)
            try {
                val client = KmpProviderModelClient(
                    providerSetting = ProviderSetting.OpenAI(apiKey = "fake-key", baseUrl = url),
                    modelId = "stub",
                    retryDelayMs = 1,
                    streamHttpClient = streamHttp,
                )
                val msg = client.streamReply(listOf(UIMessage.user("慢速持续流")), emptyList()) {}
                assertEquals("段0段1段2段3", msg.toText())
                assertEquals(1, calls.get())
            } finally {
                streamHttp.close()
            }
        }

        sseServer({ _, send ->
            send(openAiTextChunk("首段"))
            Thread.sleep(500)
            send(openAiStopChunk())
        }) { url, calls ->
            val streamHttp = cloudStreamHttpClient(idleTimeoutMs = 180)
            try {
                val client = KmpProviderModelClient(
                    providerSetting = ProviderSetting.OpenAI(apiKey = "fake-key", baseUrl = url),
                    modelId = "stub",
                    retryDelayMs = 1,
                    streamHttpClient = streamHttp,
                )
                val ex = assertFailsWith<CloudModelTimeoutException> {
                    client.streamReply(listOf(UIMessage.user("流中途卡死")), emptyList()) {}
                }
                assertEquals(1, calls.get())
                assertEquals(1, ex.attempts)
            } finally {
                streamHttp.close()
            }
        }
    }

    @Test
    fun c6_continuous_streaming_updates_last_activity_and_prevents_health_monitor_nudge() = runBlocking {
        val dir = Files.createTempDirectory("c6-nudge").toFile()
        val fakeClock = AtomicLong(1_762_000_000_000L)
        val chunk1Sent = CompletableDeferred<Unit>()
        val allowChunk2 = CompletableDeferred<Unit>()
        val chunk2Sent = CompletableDeferred<Unit>()
        val allowFinish = CompletableDeferred<Unit>()
        val store = CloudOrchestrationStore(dir)
        val convDir = File(dir, "conv").also { it.mkdirs() }
        val storage = JsonConversationStorage(ConversationFile(convDir.absolutePath))
        val toolRegistry = CloudToolRegistry().apply {
            register(
                CloudToolDefinition(
                    name = "task_finish",
                    description = "finish",
                    highRisk = false,
                    effect = ToolEffect.PURE,
                ) { args ->
                    buildJsonObject {
                        put("ok", true)
                        put("outcome", args["outcome"]?.jsonPrimitive?.content ?: "completed")
                        put("summary", args["summary"]?.jsonPrimitive?.content ?: "ok")
                        put("artifacts", buildJsonArray {})
                    }
                }
            )
        }
        val config = OrchestrationConfig(runningQuietNudgeMs = 60_000L, recoveryRedeliverDelayMs = 30_000L)
        val kernel = DefaultCloudOrchestrationKernel(
            config = config,
            store = store,
            conversationStorage = storage,
            toolRegistry = toolRegistry,
            clockMs = { fakeClock.get() },
            autoExecuteWorkersInBackground = true,
        )
        val runner = ModelWorkerTurnRunner(
            kernel = kernel,
            modelClient = object : CloudModelClient {
                override suspend fun generateReply(messages: List<UIMessage>, tools: List<Tool>): UIMessage =
                    error("should use streamReply")

                override suspend fun streamReply(
                    messages: List<UIMessage>,
                    tools: List<Tool>,
                    onActivity: (StreamActivity) -> Unit,
                ): UIMessage {
                    onActivity(StreamActivity("text", deltaTextChars = 4))
                    chunk1Sent.complete(Unit)
                    allowChunk2.await()
                    onActivity(StreamActivity("text", deltaTextChars = 4))
                    chunk2Sent.complete(Unit)
                    allowFinish.await()
                    return UIMessage(
                        role = MessageRole.ASSISTANT,
                        parts = listOf(
                            UIMessagePart.Tool(
                                toolCallId = "fin-c6",
                                toolName = "task_finish",
                                input = """{"outcome":"completed","summary":"持续流式完成"}""",
                            ),
                        ),
                    )
                }
            },
            toolRegistry = toolRegistry,
            activityThrottleMs = 30_000L,
        )
        kernel.workerTurnRunner = { item, principal -> runner.run(item, principal) }
        try {
            val msgId = "msg-c6"
            store.recordSourceMessage(
                provenance = SourceMessageProvenance(
                    sessionId = PRIMARY_CONVERSATION_ID.toString(),
                    messageId = msgId,
                    senderId = "owner-1",
                    channelId = "telegram",
                    senderRole = SenderRole.OWNER,
                    origin = MessageProvenanceOrigin.OWNER_HUMAN,
                    rawTextHash = OrchestrationHash.sha256Hex("持续流式"),
                    createdAtEpochMs = fakeClock.get(),
                ),
                rawText = "持续流式",
            )
            val coordinator = CloudPrincipal.CloudCoordinator(activeSessionId = PRIMARY_CONVERSATION_ID.toString(), activeTurnId = "t-c6")
            val submitted = kernel.submitWorkBatch(
                principal = coordinator,
                requestId = "req-c6",
                contextMessageIds = listOf(msgId),
                items = listOf(
                    WorkItemSubmissionSpec(
                        taskKey = "task-c6",
                        title = "持续流式",
                        brief = "持续流式保活",
                        targetNode = ExecutionTargetNode.CloudSubagent("worker"),
                    ),
                ),
                nowEpochMs = fakeClock.get(),
            ).items.single()
            withTimeout(5_000) { chunk1Sent.await() }
            // Advance 40s (chunk1 emitted at T+0, now T+40s), emit chunk2 which updates lastActivityAtMs to T+40s
            fakeClock.addAndGet(40_000L)
            allowChunk2.complete(Unit)
            withTimeout(5_000) { chunk2Sent.await() }
            // Advance another 40s (total elapsed 80s > 60s nudge threshold, but since chunk2 only 40s!)
            fakeClock.addAndGet(40_000L)
            val actions = kernel.runDeterministicHealthTick(fakeClock.get())
            assertTrue(actions.none { it.workItemId == submitted.workItemId && it.action == HealthActionKind.NUDGE })
            allowFinish.complete(Unit)
            withTimeout(5_000) {
                while (store.getWorkItem(submitted.workItemId)?.state?.isTerminal != true) delay(10)
            }
            val finalItem = store.getWorkItem(submitted.workItemId)!!
            assertEquals(WorkItemState.COMPLETED, finalItem.state)
            assertEquals(0, finalItem.recoveriesUsed)
            assertFalse(store.dialogue.page(after = 0, limit = 50).items.any { it.text.contains("暂无新进展") })
        } finally {
            store.close()
            dir.deleteRecursively()
        }
    }

    @Test
    fun c7_fun_interface_model_client_default_stream_reply_remains_compatible() = runBlocking {
        val harness = WorkerHarness(
            modelClient = CloudModelClient { messages, _ ->
                if (!messages.first().toText().contains("受管 Worker")) {
                    UIMessage.assistant("""{"tags":[]}""")
                } else {
                    UIMessage(
                        role = MessageRole.ASSISTANT,
                        parts = listOf(
                            UIMessagePart.Tool(
                                toolCallId = "fin-c7",
                                toolName = "task_finish",
                                input = """{"outcome":"completed","summary":"SAM 兼容完成"}""",
                            ),
                        ),
                    )
                }
            },
        )
        try {
            val submitted = harness.submit("c7-sam")
            harness.awaitIdle()
            val item = harness.kernel.orchestrationStore.getWorkItem(submitted.workItem.id)!!
            assertEquals(WorkItemState.COMPLETED, item.state)
            assertEquals("completed", item.settlementOutcome)
        } finally {
            harness.close()
        }
    }
}
