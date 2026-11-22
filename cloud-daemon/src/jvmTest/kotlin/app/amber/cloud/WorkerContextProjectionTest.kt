package app.amber.cloud

import app.amber.ai.core.MessageRole
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.gateway.AgentCentricApi
import app.amber.cloud.gateway.NativeTaskRequest
import app.amber.cloud.orchestration.CloudPrincipal
import app.amber.cloud.orchestration.ExecutionTargetNode
import app.amber.cloud.orchestration.SourceMessageProvenance
import app.amber.cloud.orchestration.WorkItemState
import app.amber.cloud.orchestration.WorkItemSubmissionSpec
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.runtime.CloudToolDefinition
import app.amber.cloud.runtime.ToolEffect
import app.amber.core.model.MemoryKind
import app.amber.core.model.MemoryScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlin.uuid.Uuid

class WorkerContextProjectionTest {

    private class Harness(
        val onWorkerModelCall: suspend (step: Int, messages: List<UIMessage>) -> UIMessage,
    ) {
        val dir = Files.createTempDirectory("worker-projection").toFile()
        val capturedRequests = CopyOnWriteArrayList<List<UIMessage>>()
        val workerSteps = AtomicInteger()
        val kernel = CloudAgentKernel(
            dataDir = dir,
            modelClient = CloudModelClient { messages, _ ->
                if (messages.first().toText().contains("受管 Worker")) {
                    capturedRequests += messages
                    onWorkerModelCall(workerSteps.incrementAndGet(), messages)
                } else {
                    UIMessage.assistant("{\"tags\":[]}")
                }
            },
            masterSecretOverride = "worker-projection-fixture",
        )
        val api = AgentCentricApi(kernel)
        val device = run {
            kernel.gatewayState.pairDevice(kernel.gatewayState.issuePairingTicket(), "ios", "fixture")
            kernel.gatewayState.loadDevicesStrict().single()
        }

        suspend fun submit(requestId: String, prompt: String, title: String = "投影测试") =
            api.tasks.submit(device, NativeTaskRequest(requestId, prompt, title = title))

        suspend fun submitWithTopic(requestId: String, taskKey: String, prompt: String, title: String, topicKey: String) = run {
            val provId = "msg-$requestId"
            kernel.orchestrationStore.recordSourceMessage(
                SourceMessageProvenance(
                    sessionId = app.amber.cloud.channel.PRIMARY_CONVERSATION_ID.toString(),
                    messageId = provId,
                    senderId = device.id,
                    channelId = "native",
                    rawTextHash = "hash-$requestId",
                    createdAtEpochMs = System.currentTimeMillis(),
                ),
                prompt,
            )
            kernel.orchestrationKernel.submitWorkBatch(
                principal = CloudPrincipal.OwnerUser(device.id, "native"),
                requestId = requestId,
                contextMessageIds = listOf(provId),
                items = listOf(
                    WorkItemSubmissionSpec(
                        taskKey = taskKey,
                        title = title,
                        brief = prompt,
                        targetNode = ExecutionTargetNode.CloudSubagent(rolePrompt = ""),
                        subscribedThreadKeys = listOf(topicKey),
                    )
                ),
            ).items.single()
        }

        suspend fun awaitIdle() = withTimeout(30_000) { kernel.router.awaitIdle(includeWorkers = true) }

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

    private fun finishCall(summary: String = "完成") = UIMessage.assistant("").copy(
        parts = listOf(
            UIMessagePart.Tool(
                "finish-${System.nanoTime()}",
                "task_finish",
                """{"outcome":"completed","summary":"$summary","artifacts":[]}""",
            )
        )
    )

    @Test
    fun worker_rechecks_rules_after_a_tool_round() = runBlocking {
        val h = Harness { step, _ ->
            if (step == 1) UIMessage.assistant("").copy(parts = listOf(UIMessagePart.Tool("probe", "test_probe", "{}")))
            else finishCall()
        }
        try {
            val store = h.kernel.proceduralRuleStore
            val proposed = store.propose("先列出变更清单") as app.amber.cloud.rules.RuleProposalOutcome.Proposed
            store.confirm(proposed.rule.id)
            h.kernel.toolRegistry.register(CloudToolDefinition("test_probe", "test probe", false, ToolEffect.PURE) {
                store.archive(proposed.rule.id)
                buildJsonObject { put("ok", true) }
            })
            h.submit("rule-refresh", "查看变更后结算")
            h.awaitIdle()
            val prompts = h.capturedRequests.map { it.first().toText() }
            assertTrue(prompts.first().contains(proposed.rule.instruction))
            assertFalse(prompts.last().contains(proposed.rule.instruction))
            assertEquals(1, store.get(proposed.rule.id)?.hitCount)
        } finally { h.close() }
    }

    @Test
    fun parallel_large_tool_outputs_fit_the_budget_without_rewriting_history() = runBlocking {
        val h = Harness { step, _ ->
            if (step == 1) UIMessage.assistant("").copy(parts = (1..8).map {
                UIMessagePart.Tool("large-$it", "large_read", "{}")
            }) else finishCall()
        }
        try {
            h.kernel.toolRegistry.register(CloudToolDefinition("large_read", "large read", false, ToolEffect.PURE) {
                buildJsonObject { put("data", "x".repeat(100_000)) }
            })
            val task = h.submit("batch-large-outputs", "读取八个大文件后结算")
            h.awaitIdle()
            val request = h.capturedRequests[1]
            val tokens = h.kernel.contextManager.estimateTokens(request)
            assertTrue(tokens <= h.kernel.contextWindowTokens, "batch request exceeded budget: $tokens")
            val id = h.kernel.orchestrationStore.getWorkItem(task.workItem.id)!!.workerSessionId!!
            val raw = h.kernel.conversationStorage.loadConversation(Uuid.parse(id))!!
            val outputs = raw.messageNodes.flatMap { it.currentMessage.getTools() }.filter { it.toolName == "large_read" }
            assertEquals(8, outputs.size)
            assertTrue(outputs.all { it.output.filterIsInstance<UIMessagePart.Text>().sumOf { part -> part.text.length } > 100_000 })
        } finally { h.close() }
    }

    @Test
    fun a1_a2_a4_a6_projects_30_large_tool_turns_and_256kb_process_event_without_mutating_storage() = runBlocking {
        val hugeChunk = "x".repeat(200 * 1024)
        val processPayload = "ERROR: /workspace/build/fail.kt exit code 1\n" + "p".repeat(256 * 1024)
        var savedRawLengths = mutableListOf<Int>()
        lateinit var h: Harness
        h = Harness { step, messages ->
            when {
                step <= 30 -> UIMessage.assistant("round $step").copy(
                    parts = listOf(
                        UIMessagePart.Text("round $step"),
                        UIMessagePart.Tool("tool-$step", "big_tool", """{"step":$step}"""),
                    )
                )
                step == 31 -> {
                    // Inject a 256KB process event into the worker inbox just like TaskProcessRunner.onBackgroundFinished
                    val item = h.kernel.orchestrationStore.listWorkItems().single { !it.state.isTerminal }
                    h.kernel.orchestrationStore.dialogue.processFinished("proc-256k", item.workItemId, "default", processPayload)
                    h.kernel.orchestrationKernel.signalWorker(item.workItemId)
                    // First return plain text so runner checks pending? Wait: we inject before returning?
                    // No, return a small tool call, or return plain text? If we inject before returning, consume(pending) only consumes what prepare() loaded!
                    // So on step 32 prepare() will load proc-256k and project it as the latest event!
                    UIMessage.assistant("waiting process").copy(
                        parts = listOf(UIMessagePart.Tool("tool-$step", "big_tool", """{"step":$step}"""))
                    )
                }
                else -> finishCall("done after 30 turns and 256kb event")
            }
        }
        try {
            h.kernel.memoryStore.upsertMemory(
                content = "用户偏好：始终用中文汇报编译路径",
                kind = MemoryKind.NOTE,
                scope = MemoryScope.CORE,
                agentId = "amber",
            )
            h.kernel.toolRegistry.register(
                CloudToolDefinition("big_tool", "200KB 合成输出工具", false, ToolEffect.PURE) { args ->
                    val s = args["step"]?.jsonPrimitive?.int ?: 0
                    val text = if (s == 1) {
                        "Error: /var/log/step1-failure.log\n$hugeChunk"
                    } else {
                        "step-$s-head\n$hugeChunk\nstep-$s-tail"
                    }
                    savedRawLengths += text.length
                    buildJsonObject { put("ok", true); put("payload", text) }
                }
            )
            val task = h.submit("proj-a1", "执行 30 轮大输出并处理 256KB 进程事件")
            h.awaitIdle()

            val item = h.kernel.orchestrationStore.getWorkItem(task.workItem.id)!!
            assertEquals(WorkItemState.COMPLETED, item.state)
            assertTrue(h.capturedRequests.size >= 32, "expected >= 32 model requests, got ${h.capturedRequests.size}")

            val rawConversation = h.kernel.conversationStorage.loadConversation(Uuid.parse(item.workerSessionId!!))!!
            val rawAnchorText = rawConversation.messageNodes.first {
                it.currentMessage.toText().startsWith("【Worker 任务简报")
            }.currentMessage.toText()

            // Verify every single captured request against A1, A4, A6
            for ((idx, req) in h.capturedRequests.withIndex()) {
                val estTokens = h.kernel.contextManager.estimateTokens(req)
                assertTrue(
                    estTokens <= h.kernel.contextWindowTokens,
                    "step ${idx + 1}: estimateTokens=$estTokens exceeded contextWindowTokens=${h.kernel.contextWindowTokens}",
                )
                assertEquals(MessageRole.SYSTEM, req[0].role, "step ${idx + 1}: [0] must be SYSTEM")
                assertTrue(req[0].toText().isNotBlank(), "step ${idx + 1}: [0] must contain soul/system prompt")
                assertTrue(req.size >= 2, "step ${idx + 1}: must have anchor at [1]")
                assertEquals(MessageRole.USER, req[1].role, "step ${idx + 1}: [1] must be USER (A6)")
                assertEquals(rawAnchorText, req[1].toText(), "step ${idx + 1}: [1] must match brief verbatim")

                // A4: <agent_memory> appears at most once across the entire request
                val memoryTagCount = req.sumOf { msg ->
                    Regex("<agent_memory>").findAll(msg.toText()).count()
                }
                assertTrue(memoryTagCount <= 1, "step ${idx + 1}: <agent_memory> appeared $memoryTagCount times")

                // A6: no Tool part with empty output in request
                val emptyOutputTools = req.flatMap { it.getTools() }.filter { it.output.isEmpty() }
                assertTrue(emptyOutputTools.isEmpty(), "step ${idx + 1}: found tool parts with empty output")
            }

            // A1: step 32 request has the latest process event last (or truncated with original length), old outputs folded, and compaction <must-not-lose>
            val step32Req = h.capturedRequests[31]
            val lastMsgText = step32Req.last().toText()
            assertTrue(lastMsgText.contains("【任务事件 process"), "step 32 last message must be latest process event")
            assertTrue(lastMsgText.contains("原长度"), "256KB latest process event must carry original length marker")

            // Check folded old output marker & original length in earlier tool turns still in tail
            val allTextInStep32 = step32Req.joinToString("\n") { m ->
                m.toText() + "\n" + m.getTools().flatMap { it.output }.filterIsInstance<UIMessagePart.Text>().joinToString("\n") { it.text }
            }
            assertTrue(allTextInStep32.contains("已折叠"), "old tool outputs outside recent window must be folded")
            assertTrue(allTextInStep32.contains("原长度"), "folded output must include original length")

            // Verify compaction triggered and <must-not-lose> captured injected error line / path
            val checkpoints = h.kernel.contextManager.loadAllCheckpoints(item.workerSessionId!!)
            assertTrue(checkpoints.isNotEmpty(), "expected compaction checkpoint to be created")
            val mustNotLoseAll = checkpoints.flatMap { it.mustNotLose }.joinToString("\n")
            assertTrue(
                mustNotLoseAll.contains("/var/log/step1-failure.log") || mustNotLoseAll.contains("step1-failure.log"),
                "expected <must-not-lose> to capture injected error path, got: $mustNotLoseAll",
            )
            assertTrue(
                step32Req.any { it.toText().contains("<must-not-lose>") },
                "expected <must-not-lose> block in compacted request",
            )

            // A2: stored conversation still has full 200KB tool outputs and full 256KB process event verbatim
            val storedToolOutputs = rawConversation.messageNodes
                .map { it.currentMessage }
                .flatMap { it.getTools() }
                .filter { it.toolName == "big_tool" }
                .map { (it.output.single() as UIMessagePart.Text).text }
            assertEquals(30, storedToolOutputs.size)
            assertTrue(storedToolOutputs.all { it.length > 200 * 1024 }, "A2: stored tool outputs must remain full length")
            val storedProcessMsg = rawConversation.messageNodes
                .map { it.currentMessage }
                .first { it.toText().startsWith("【任务事件 process") }
            assertTrue(storedProcessMsg.toText().length > 256 * 1024, "A2: stored process event must remain full 256KB")
        } finally {
            h.close()
        }
    }

    @Test
    fun a3_reused_session_pins_the_second_tasks_brief_as_anchor() = runBlocking {
        val taskRequests = CopyOnWriteArrayList<Pair<String, List<UIMessage>>>()
        var currentPhase = "task1"
        val h = Harness { _, messages ->
            taskRequests += currentPhase to messages
            finishCall("completed $currentPhase")
        }
        try {
            val item1Init = h.submitWithTopic("reuse-1", "k1", "第一个任务的独特目标 ALPHA-111", title = "任务一", topicKey = "native:topic-reuse")
            h.awaitIdle()
            val item1 = h.kernel.orchestrationStore.getWorkItem(item1Init.workItemId)!!
            assertEquals(WorkItemState.COMPLETED, item1.state)

            currentPhase = "task2"
            val item2Init = h.submitWithTopic("reuse-2", "k2", "第二个任务的独特目标 BETA-222", title = "任务二", topicKey = "native:topic-reuse")
            h.awaitIdle()
            val item2 = h.kernel.orchestrationStore.getWorkItem(item2Init.workItemId)!!
            assertEquals(WorkItemState.COMPLETED, item2.state)
            assertEquals(item1.workerSessionId, item2.workerSessionId, "same topic/agent should reuse worker session")

            val task2Req = taskRequests.last { it.first == "task2" }.second
            assertEquals(MessageRole.SYSTEM, task2Req[0].role)
            assertEquals(MessageRole.USER, task2Req[1].role)
            assertTrue(task2Req[1].toText().contains("WorkItemId: ${item2.workItemId}"), "anchor [1] must belong to task2")
            assertTrue(task2Req[1].toText().contains("BETA-222"), "anchor [1] must contain task2 brief")
            assertFalse(task2Req[1].toText().contains("ALPHA-111"), "anchor [1] must not be task1 brief")
        } finally {
            h.close()
        }
    }
}
