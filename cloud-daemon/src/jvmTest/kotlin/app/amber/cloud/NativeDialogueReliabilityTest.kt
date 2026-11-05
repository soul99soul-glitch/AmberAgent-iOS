package app.amber.cloud

import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.gateway.*
import app.amber.cloud.orchestration.*
import app.amber.cloud.runtime.*
import kotlinx.coroutines.*
import io.ktor.client.request.*
import io.ktor.client.statement.bodyAsText
import io.ktor.server.testing.testApplication
import kotlinx.serialization.json.*
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.*

class NativeDialogueReliabilityTest {
    @Test fun paired_http_dialogue_acknowledges_dispatch_and_pushes_safe_timeout_then_success() = runBlocking {
        val dir = Files.createTempDirectory("native-dialogue-http").toFile()
        val workerStarted = CompletableDeferred<Unit>()
        val releaseWorker = CompletableDeferred<Unit>()
        val contexts = CopyOnWriteArrayList<String>()
        val k = CloudAgentKernel(dir, CloudModelClient { messages, tools ->
            val text = messages.last().toText().lineSequence().last()
            if (tools.any { it.name == "dispatch_work" }) {
                contexts += messages.joinToString { it.toText() }
                when {
                    text == "派活" || text == "再派一次" -> UIMessage.assistant("").copy(parts = listOf(UIMessagePart.Tool(
                        toolCallId = "dispatch-$text", toolName = "dispatch_work",
                        input = """{"tasks":[{"task_key":"check","title":"检查状态","brief":"检查状态"}]}""",
                    )))
                    text == "7+8" -> UIMessage.assistant("15")
                    else -> UIMessage.assistant("已看到失败原因")
                }
            } else UIMessage.assistant("""{"tags":[]}""")
        }, masterSecretOverride = "dialogue-http-test")
        var runs = 0
        k.orchestrationKernel.workerTurnRunner = { item, _ ->
            if (++runs == 1) {
                workerStarted.complete(Unit); releaseWorker.await()
                throw CloudModelTimeoutException(2, java.net.SocketTimeoutException("Socket timeout at https://private.example"))
            }
            WorkerSettlementReport(item.workItemId, "completed", "状态检查完成")
        }
        val pair = k.gatewayState.pairDevice(k.gatewayState.issuePairingTicket(), "ios", "fixture") as CloudGatewayState.PairResult.Success
        try {
            testApplication {
                application { configureCloudGateway(k.gatewayState, agentApi = AgentCentricApi(k)) }
                suspend fun send(id: String, text: String) = client.post("/v2/dialogue/messages") {
                    bearerAuth(pair.token); setBody("""{"requestId":"$id","text":"$text"}""")
                }
                suspend fun page(): List<JsonObject> = Json.parseToJsonElement(client.get("/v2/dialogue/events?after=0&limit=100") {
                    bearerAuth(pair.token)
                }.bodyAsText()).jsonObject.getValue("items").jsonArray.map { it.jsonObject }
                assertEquals(202, send("dispatch", "派活").status.value)
                withTimeout(2_000) { workerStarted.await() }
                assertTrue(page().any { it["text"]?.jsonPrimitive?.content?.contains("收到") == true })
                assertEquals(202, send("math", "7+8").status.value)
                withTimeout(2_000) { while (page().none { it["text"]?.jsonPrimitive?.content == "15" }) delay(10) }
                releaseWorker.complete(Unit)
                withTimeout(2_000) { while (page().none { it["kind"]?.jsonPrimitive?.content == "task_result" }) delay(10) }
                val failure = page().single { it["kind"]?.jsonPrimitive?.content == "task_result" }
                assertEquals("failed", failure["outcome"]!!.jsonPrimitive.content)
                assertContains(failure["text"]!!.jsonPrimitive.content, "自动重试 1 次")
                assertFalse(failure.toString().contains("private.example"))
                assertFalse(failure.toString().contains("Socket"))
                assertEquals(202, send("why", "为什么失败").status.value)
                withTimeout(2_000) { while (contexts.none { it.contains("自动重试 1 次") }) delay(10) }
                assertEquals(202, send("retry", "再派一次").status.value)
                withTimeout(2_000) { while (page().none { it["outcome"]?.jsonPrimitive?.content == "completed" }) delay(10) }
                assertEquals(2, k.orchestrationStore.listWorkItems().size)
            }
        } finally {
            releaseWorker.complete(Unit)
            k.router.awaitIdle(includeWorkers = true); k.conversationTagger.closeAndJoin()
            k.agentRegistry.close(); k.orchestrationStore.close(); k.supertagStore.close()
            dir.deleteRecursively()
        }
    }

    private suspend fun fixture(block: suspend (CloudAgentKernel, PairedDevice) -> Unit) {
        val dir = Files.createTempDirectory("native-dialogue-reliability").toFile()
        val kernel = CloudAgentKernel(dir, CloudModelClient { _, _ -> UIMessage.assistant("fixture") },
            masterSecretOverride = "dialogue-reliability-test")
        kernel.orchestrationKernel.autoExecuteWorkersInBackground = false
        kernel.gatewayState.pairDevice(kernel.gatewayState.issuePairingTicket(), "ios", "fixture")
        try { block(kernel, kernel.gatewayState.loadDevicesStrict().single()) }
        finally {
            kernel.router.awaitIdle(includeWorkers = true)
            kernel.conversationTagger.closeAndJoin()
            kernel.agentRegistry.close(); kernel.orchestrationStore.close(); kernel.supertagStore.close()
            dir.deleteRecursively()
        }
    }

    @Test fun acknowledgement_is_durable_before_model_finishes_and_replay_does_not_duplicate_it() = runBlocking {
        fixture { k, device ->
            val started = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            k.router.brain = RouterBrain {
                started.complete(Unit); release.await()
                RouterDecision(dispatch = listOf(WorkItemSubmissionSpec("check", "检查状态", "只读检查", ExecutionTargetNode.CloudSubagent(rolePrompt = "worker"))))
            }
            try {
                val receipt = k.nativeDialogue.submit(device, "dispatch", "查一下状态")
                withTimeout(2_000) { started.await() }
                val replies = k.orchestrationStore.dialogue.page(0, 100).items.filter { it.role == "assistant" }
                assertTrue(replies.any { it.topicId == receipt.topicId && it.text.contains("收到") }, "等待模型时用户必须已收到人话回执")
                k.nativeDialogue.submit(device, "dispatch", "查一下状态")
                assertEquals(replies, k.orchestrationStore.dialogue.page(0, 100).items.filter { it.role == "assistant" })
            } finally { release.complete(Unit) }
            k.router.awaitIdle()
            assertEquals(1, k.orchestrationStore.listWorkItems().size)
            assertEquals("consumed", k.nativeDialogue.receipt(device, "dispatch")!!.state)
        }
    }

    @Test fun another_native_message_gets_a_reply_while_previous_model_is_waiting() = runBlocking {
        fixture { k, device ->
            val firstStarted = CompletableDeferred<Unit>()
            val releaseFirst = CompletableDeferred<Unit>()
            k.router.brain = RouterBrain { input ->
                if (input.batchPrompt.contains("慢请求")) {
                    firstStarted.complete(Unit); releaseFirst.await()
                    RouterDecision(reply = "慢请求完成")
                } else RouterDecision(reply = "15")
            }
            k.nativeDialogue.submit(device, "slow", "慢请求")
            withTimeout(2_000) { firstStarted.await() }
            try {
                val next = k.nativeDialogue.submit(device, "fast", "7+8是多少")
                withTimeout(2_000) {
                    while (k.orchestrationStore.dialogue.page(0, 100).items.none { it.topicId == next.topicId && it.text == "15" }) delay(10)
                }
            } finally { releaseFirst.complete(Unit) }
        }
    }

    @Test fun settlement_is_readable_in_next_main_turn_without_a_model_rollup_or_redispatch() = runBlocking {
        fixture { k, device ->
            val contexts = CopyOnWriteArrayList<List<UIMessage>>()
            val ingress = CloudRouterIngress(k)
            k.router.brain = RouterBrain { input ->
                contexts += ingress.contextMessages(input)
                if (input.batchPrompt == "派活") RouterDecision(dispatch = listOf(WorkItemSubmissionSpec("probe", "检查", "检查", ExecutionTargetNode.CloudSubagent(rolePrompt = "worker"))))
                else RouterDecision(reply = "已看到结果")
            }
            k.nativeDialogue.submit(device, "probe", "派活")
            k.router.awaitIdle()
            // Ingress runs in its own scope; wait for the persisted operation, not just the Router's current queue.
            withTimeout(2_000) { while (k.orchestrationStore.listWorkItems().isEmpty()) delay(10) }
            k.router.awaitIdle()
            val item = k.orchestrationStore.listWorkItems().single()
            val report = WorkerSettlementReport(item.workItemId, "failed", "模型接口响应超时，已自动重试 1 次仍未成功。可以再试一次。")
            k.orchestrationKernel.reportWorkerSettlement(k.orchestrationKernel.workerPrincipalFor(item), report)
            k.router.awaitIdle()
            assertEquals(1, contexts.size, "原生任务已有结果事件，不应再让模型猜结果或重派")
            val event = k.orchestrationStore.dialogue.page(0, 100).items.single { it.kind == "task_result" }
            assertEquals("failed", event.outcome)
            assertContains(event.text, "自动重试 1 次")
            val history = k.conversationStorage.loadConversation(PRIMARY_CONVERSATION_ID)!!.messageNodes
            assertTrue(history.any { it.currentMessage.toText().contains("自动重试 1 次") }, "任务结果必须回到主对话历史")
            k.nativeDialogue.submit(device, "why", "为什么失败")
            withTimeout(2_000) { while (contexts.size < 2) delay(10) }
            k.router.awaitIdle()
            assertContains(contexts.last().joinToString { it.toText() }, "自动重试 1 次")
            k.nativeDialogue.recover()
            assertEquals(1, k.orchestrationStore.dialogue.page(0, 100).items.count { it.kind == "task_result" })
            assertEquals(1, k.conversationStorage.loadConversation(PRIMARY_CONVERSATION_ID)!!.messageNodes.count { it.currentMessage.toText().contains("自动重试 1 次") })
        }
    }
}
