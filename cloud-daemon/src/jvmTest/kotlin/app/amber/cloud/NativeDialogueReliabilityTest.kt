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
    @Test fun worker_progress_resets_silence_but_repeated_commentary_and_polling_do_not() = runBlocking {
        val dir = Files.createTempDirectory("native-dialogue-feedback").toFile()
        val now = java.util.concurrent.atomic.AtomicLong(0)
        val workerStarted = CompletableDeferred<Unit>()
        val begin = CompletableDeferred<Unit>()
        val firstMilestone = CompletableDeferred<Unit>()
        val nextMilestone = CompletableDeferred<Unit>()
        val finalStarted = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()
        var step = 0
        val k = CloudAgentKernel(dir, CloudModelClient { messages, tools ->
            if (messages.first().toText().contains("<native-wait-feedback>")) {
                return@CloudModelClient UIMessage.assistant(when {
                    messages.last().toText().contains("silent_without_new_visible_progress") && messages.last().toText().contains("已核对任务文件") -> "还没等到最后的结果，我接着留意。"
                    messages.last().toText().contains("silent_without_new_visible_progress") -> "这一步还没等到新结果，我会继续留意。"
                    else -> "这项检查我会继续，你先稍等一下。"
                })
            }
            if (tools.any { it.name == "dispatch_work" }) {
                UIMessage.assistant("").copy(parts = listOf(UIMessagePart.Tool("dispatch", "dispatch_work",
                    """{"tasks":[{"task_key":"probe","title":"检查环境","brief":"检查环境"}]}""")))
            } else if (messages.first().toText().contains("受管 Worker")) {
                val current = step++
                val text = when (current) {
                    0 -> { workerStarted.complete(Unit); begin.await(); "继续查。" }
                    1, 3 -> "已确认运行环境，接下来核对任务文件。"
                    2 -> "我继续查一下。"
                    4 -> { firstMilestone.complete(Unit); nextMilestone.await(); "已核对任务文件，可以整理结果了。" }
                    else -> { finalStarted.complete(Unit); finish.await(); "" }
                }
                val tool = if (current < 5) UIMessagePart.Tool("probe-$current", "host_info", "{}")
                    else UIMessagePart.Tool("finish", "task_finish", """{"outcome":"completed","summary":"环境核对完成","artifacts":[]}""")
                UIMessage.assistant("").copy(parts = listOf(UIMessagePart.Text(text), tool))
            } else UIMessage.assistant("""{"tags":[]}""")
        }, masterSecretOverride = "native-feedback-test")
        k.nativeDialogue.clockMs = now::get
        k.gatewayState.pairDevice(k.gatewayState.issuePairingTicket(), "ios", "fixture")
        val device = k.gatewayState.loadDevicesStrict().single()
        fun assistantEvents() = k.orchestrationStore.dialogue.page(0, 100).items.filter { it.role == "assistant" }
        try {
            k.nativeDialogue.submit(device, "long", "检查环境")
            withTimeout(2_000) {
                workerStarted.await()
                while (assistantEvents().none { it.text == "这项检查我会继续，你先稍等一下。" }) delay(10)
            }
            assertEquals(listOf("这项检查我会继续，你先稍等一下。"), assistantEvents().map { it.text })
            begin.complete(Unit)
            withTimeout(2_000) { firstMilestone.await() }
            assertEquals(1, assistantEvents().count { it.text == "已确认运行环境，接下来核对任务文件。" })
            assertTrue(assistantEvents().none { it.text == "继续查。" || it.text == "我继续查一下。" })
            now.set(59_999); k.nativeDialogue.evaluateFeedback()
            assertEquals(0, assistantEvents().count { it.id.startsWith("ack:keepalive:") })
            now.set(60_000); k.nativeDialogue.evaluateFeedback()
            withTimeout(2_000) { while (assistantEvents().none { it.id.startsWith("ack:keepalive:") }) delay(10) }
            now.set(120_000); k.nativeDialogue.evaluateFeedback()
            assertEquals(1, assistantEvents().count { it.id.startsWith("ack:keepalive:") }, "无进展静默窗口最多一条保活")
            nextMilestone.complete(Unit)
            withTimeout(2_000) { finalStarted.await() }
            now.set(179_999); k.nativeDialogue.evaluateFeedback()
            assertEquals(1, assistantEvents().count { it.id.startsWith("ack:keepalive:") }, "从实质进展重新计时")
            now.set(180_000); k.nativeDialogue.evaluateFeedback()
            withTimeout(2_000) { while (assistantEvents().count { it.id.startsWith("ack:keepalive:") } < 2) delay(10) }
            assertEquals(2, assistantEvents().count { it.id.startsWith("ack:keepalive:") })
            val beforeRecovery = assistantEvents()
            val recovered = NativeDialogueService(k, { error("no pending ingress expected") }, clockMs = now::get) { id, text ->
                CloudRouterIngress(k).recordReply(PRIMARY_CONVERSATION_ID.toString(), text,
                    kotlin.uuid.Uuid.parse(java.util.UUID.nameUUIDFromBytes(id.toByteArray()).toString()))
            }
            try {
                recovered.recover()
                now.set(240_000); recovered.evaluateFeedback()
                assertEquals(beforeRecovery, assistantEvents(), "活动任务恢复必须沿用已发送的静默窗口，不能重复 ACK 或保活")
            } finally { recovered.closeAndJoin() }
            finish.complete(Unit)
            k.router.awaitIdle(includeWorkers = true)
            assertEquals("环境核对完成", assistantEvents().single { it.kind == "task_result" }.text)
            val settled = assistantEvents()
            now.set(300_000); k.nativeDialogue.evaluateFeedback()
            k.nativeDialogue.recover()
            assertEquals(settled, assistantEvents(), "终态、重连和恢复不得再产生进度正文")
            assertEquals(1, settled.count { it.text == "这项检查我会继续，你先稍等一下。" })
            assertTrue(settled.all { it.text.isNotBlank() }, "事件流不能创建空气泡")
            val history = k.conversationStorage.loadConversation(PRIMARY_CONVERSATION_ID)!!.messageNodes
                .filter { it.role == app.amber.ai.core.MessageRole.ASSISTANT }.map { it.currentMessage.toText() }
            assertTrue(history.all { it.isNotBlank() })
            assertEquals(1, history.count { it == "已确认运行环境，接下来核对任务文件。" })
        } finally {
            begin.complete(Unit); nextMilestone.complete(Unit); finish.complete(Unit)
            k.router.awaitIdle(includeWorkers = true); k.nativeDialogue.evaluateFeedback()
            k.nativeDialogue.closeAndJoin(); k.conversationTagger.closeAndJoin(); k.agentRegistry.close(); k.orchestrationStore.close(); k.supertagStore.close()
            dir.deleteRecursively()
        }
    }

    @Test fun paired_http_dialogue_acknowledges_dispatch_and_pushes_safe_timeout_then_success() = runBlocking {
        val dir = Files.createTempDirectory("native-dialogue-http").toFile()
        val workerStarted = CompletableDeferred<Unit>()
        val releaseWorker = CompletableDeferred<Unit>()
        val contexts = CopyOnWriteArrayList<String>()
        val k = CloudAgentKernel(dir, CloudModelClient { messages, tools ->
            if (messages.first().toText().contains("<native-wait-feedback>")) return@CloudModelClient UIMessage.assistant("这项检查我会继续，你先稍等一下。")
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
                withTimeout(2_000) { while (page().none { it["text"]?.jsonPrimitive?.content == "这项检查我会继续，你先稍等一下。" }) delay(10) }
                val math = send("math", "7+8")
                assertEquals(202, math.status.value)
                val mathTopic = Json.parseToJsonElement(math.bodyAsText()).jsonObject.getValue("topicId").jsonPrimitive.content
                withTimeout(2_000) { while (page().none { it["text"]?.jsonPrimitive?.content == "15" }) delay(10) }
                assertEquals(listOf("15"), page().filter {
                    it["topicId"]?.jsonPrimitive?.content == mathTopic && it["role"]?.jsonPrimitive?.content == "assistant"
                }.map { it.getValue("text").jsonPrimitive.content }, "简单问题只能有实质答案，不能额外生成通用 ACK 正文")
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
            k.router.awaitIdle(includeWorkers = true); k.nativeDialogue.closeAndJoin(); k.conversationTagger.closeAndJoin()
            k.agentRegistry.close(); k.orchestrationStore.close(); k.supertagStore.close()
            dir.deleteRecursively()
        }
    }

    private suspend fun fixture(block: suspend (CloudAgentKernel, PairedDevice) -> Unit) {
        val dir = Files.createTempDirectory("native-dialogue-reliability").toFile()
        val kernel = CloudAgentKernel(dir, CloudModelClient { messages, _ -> UIMessage.assistant(if (messages.first().toText().contains("<native-wait-feedback>")) "这项检查我会继续，你先稍等一下。" else "fixture") },
            masterSecretOverride = "dialogue-reliability-test")
        kernel.orchestrationKernel.autoExecuteWorkersInBackground = false
        kernel.gatewayState.pairDevice(kernel.gatewayState.issuePairingTicket(), "ios", "fixture")
        try { block(kernel, kernel.gatewayState.loadDevicesStrict().single()) }
        finally {
            kernel.router.awaitIdle(includeWorkers = true)
            kernel.nativeDialogue.closeAndJoin(); kernel.conversationTagger.closeAndJoin()
            kernel.agentRegistry.close(); kernel.orchestrationStore.close(); kernel.supertagStore.close()
            dir.deleteRecursively()
        }
    }

    @Test fun acknowledgement_is_durable_before_model_finishes_and_replay_does_not_duplicate_it() = runBlocking {
        fixture { k, device ->
            val now = java.util.concurrent.atomic.AtomicLong(0)
            k.nativeDialogue.clockMs = now::get
            val started = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            k.router.brain = RouterBrain {
                started.complete(Unit); release.await()
                RouterDecision(dispatch = listOf(WorkItemSubmissionSpec("check", "检查状态", "只读检查", ExecutionTargetNode.CloudSubagent(rolePrompt = "worker"))))
            }
            try {
                val receipt = k.nativeDialogue.submit(device, "dispatch", "查一下状态")
                withTimeout(2_000) { started.await() }
                assertEquals("received", receipt.state)
                assertTrue(k.orchestrationStore.dialogue.page(0, 100).items.none { it.role == "assistant" }, "快速路径先等待实质回答")
                now.set(1_499); k.nativeDialogue.evaluateFeedback()
                assertTrue(k.orchestrationStore.dialogue.page(0, 100).items.none { it.role == "assistant" })
                now.set(1_500); k.nativeDialogue.evaluateFeedback()
                withTimeout(2_000) { while (!k.orchestrationStore.dialogue.hasEvent("ack:${receipt.eventId}")) delay(10) }
                val replies = k.orchestrationStore.dialogue.page(0, 100).items.filter { it.role == "assistant" }
                assertEquals(listOf("这项检查我会继续，你先稍等一下。"), replies.map { it.text }, "模型等待超过短阈值时才出现一次反馈")
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

    @Test fun native_stop_prevents_late_feedback_and_empty_sanitized_text_never_becomes_a_bubble() = runBlocking {
        fixture { k, device ->
            val now = java.util.concurrent.atomic.AtomicLong(0)
            k.nativeDialogue.clockMs = now::get
            k.router.brain = RouterBrain {
                RouterDecision(reply = "<think>private reasoning</think>", dispatch = listOf(
                    WorkItemSubmissionSpec("check", "检查", "检查", ExecutionTargetNode.CloudSubagent(rolePrompt = "worker"))))
            }
            k.nativeDialogue.submit(device, "cancel-me", "检查")
            withTimeout(2_000) {
                while (k.nativeDialogue.receipt(device, "cancel-me")!!.state != "consumed") delay(10)
            }
            k.router.awaitIdle()
            val work = k.orchestrationStore.listWorkItems().single()
            val stopped = k.nativeDialogue.submit(device, "stop", "", "stop", work.workItemId)
            assertEquals("consumed", stopped.state)
            assertTrue(k.nativeDialogue.submit(device, "stop", "", "stop", work.workItemId).replayed)
            val page = k.orchestrationStore.dialogue.page(0, 100).items
            assertEquals("cancelled", page.single { it.kind == "task_result" }.outcome)
            assertTrue(page.filter { it.role == "assistant" }.all { it.text.isNotBlank() && !it.text.contains("private reasoning") })
            now.set(180_000); k.nativeDialogue.evaluateFeedback()
            k.nativeDialogue.commentary(work, "迟到的进度")
            k.nativeDialogue.recover()
            assertEquals(page, k.orchestrationStore.dialogue.page(0, 100).items)
        }
    }

    @Test fun native_rule_is_scoped_to_the_originating_conversation_on_the_shared_timeline() = runBlocking {
        fixture { k, device ->
            val prompts = CopyOnWriteArrayList<String>()
            val ingress = CloudRouterIngress(k)
            k.router.brain = RouterBrain { input ->
                prompts += ingress.contextMessages(input).first().toText()
                RouterDecision(reply = "收到")
            }
            suspend fun turn(id: String, text: String, conversation: String) {
                k.nativeDialogue.submit(device, id, text, conversationId = conversation)
                withTimeout(2_000) { while (k.nativeDialogue.receipt(device, id)?.state != "consumed") delay(10) }
                k.router.awaitIdle()
            }
            turn("proposal", "以后提交前列出变更清单", "client-A")
            val rule = k.proceduralRuleStore.list().single()
            k.proceduralRuleStore.confirm(rule.id)
            turn("elsewhere", "汇报进度", "client-B")
            assertFalse(prompts.last().contains(rule.instruction))
            turn("origin", "汇报进度", "client-A")
            assertContains(prompts.last(), rule.instruction)
            assertEquals(1, k.proceduralRuleStore.get(rule.id)?.hitCount)
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
            k.nativeDialogue.submit(device, "probe", "派活", conversationId = "shared-conversation")
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
            assertEquals("shared-conversation", event.conversationId)
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
