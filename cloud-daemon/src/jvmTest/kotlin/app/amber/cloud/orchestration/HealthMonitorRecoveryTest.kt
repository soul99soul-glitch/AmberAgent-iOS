package app.amber.cloud.orchestration

import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.gateway.AgentCentricApi
import app.amber.cloud.gateway.NativeTaskRequest
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.runtime.CloudToolDefinition
import app.amber.cloud.runtime.ToolEffect
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class HealthMonitorRecoveryTest {

    private class Harness(
        val dir: File = Files.createTempDirectory("health-recovery").toFile(),
        val clock: AtomicLong = AtomicLong(1_000_000L),
        val onWorkerCall: suspend (step: Int, messages: List<UIMessage>, kernel: CloudAgentKernel) -> UIMessage,
    ) {
        val modelCalls = AtomicInteger()
        val concurrentRunners = AtomicInteger()
        val maxConcurrentRunners = AtomicInteger()
        val settlements = CopyOnWriteArrayList<WorkerSettlementReport>()
        lateinit var kernel: CloudAgentKernel
        val api: AgentCentricApi
        val device: app.amber.cloud.gateway.PairedDevice

        init {
            kernel = CloudAgentKernel(
                dataDir = dir,
                modelClient = CloudModelClient { messages, _ ->
                    if (messages.first().toText().contains("受管 Worker")) {
                        val active = concurrentRunners.incrementAndGet()
                        maxConcurrentRunners.updateAndGet { prev -> maxOf(prev, active) }
                        try {
                            onWorkerCall(modelCalls.incrementAndGet(), messages, kernel)
                        } finally {
                            concurrentRunners.decrementAndGet()
                        }
                    } else {
                        UIMessage.assistant("{\"tags\":[]}")
                    }
                },
                masterSecretOverride = "health-recovery-fixture",
            )
            val prevSettlement = kernel.orchestrationKernel.settlementListener
            kernel.orchestrationKernel.settlementListener = { item, report ->
                settlements += report
                prevSettlement(item, report)
            }
            api = AgentCentricApi(kernel)
            device = kernel.gatewayState.loadDevicesStrict().firstOrNull() ?: run {
                kernel.gatewayState.pairDevice(kernel.gatewayState.issuePairingTicket(), "ios", "fixture")
                kernel.gatewayState.loadDevicesStrict().single()
            }
        }

        suspend fun submit(requestId: String, prompt: String = "自愈验收任务"): app.amber.cloud.gateway.NativeTaskReceipt {
            val store = kernel.orchestrationStore
            val now = clock.get()
            val messageId = "native:$requestId"
            if (store.getSourceMessage(messageId) == null) {
                store.recordSourceMessage(
                    SourceMessageProvenance(
                        sessionId = app.amber.cloud.channel.PRIMARY_CONVERSATION_ID.toString(),
                        messageId = messageId,
                        senderId = device.id,
                        channelId = "app",
                        rawTextHash = OrchestrationHash.sha256Hex(prompt),
                        createdAtEpochMs = now,
                    ),
                    prompt,
                )
            }
            val result = kernel.orchestrationKernel.submitWorkBatch(
                principal = CloudPrincipal.OwnerUser(device.id, "app"),
                requestId = requestId,
                contextMessageIds = listOf(messageId),
                items = listOf(
                    WorkItemSubmissionSpec(
                        taskKey = requestId,
                        title = "自愈任务",
                        brief = prompt,
                        targetNode = ExecutionTargetNode.CloudSubagent(rolePrompt = ""),
                        subscribedThreadKeys = listOf("native:$requestId"),
                    )
                ),
                nowEpochMs = now,
            )
            return app.amber.cloud.gateway.NativeTaskReceipt(api.publicWork(result.items.single()), replayed = false)
        }

        suspend fun awaitIdle() = withTimeout(15_000) { kernel.router.awaitIdle(includeWorkers = true) }

        suspend fun close(deleteDir: Boolean = true) {
            kernel.orchestrationStore.listWorkItems().filter { !it.state.isTerminal }.forEach {
                kernel.orchestrationKernel.cancelWorkItem(CloudPrincipal.OwnerUser(device.id, "app"), it.workItemId)
            }
            awaitIdle()
            kernel.stopProactiveLoop()
            kernel.nativeDialogue.closeAndJoin()
            kernel.conversationTagger.closeAndJoin()
            kernel.agentRegistry.close()
            kernel.orchestrationStore.close()
            kernel.supertagStore.close()
            if (deleteDir) dir.deleteRecursively()
        }
    }

    private fun finishCall(outcome: String = "completed", summary: String = "ok") = UIMessage.assistant("").copy(
        parts = listOf(
            UIMessagePart.Tool(
                "finish-${System.nanoTime()}",
                "task_finish",
                """{"outcome":"$outcome","summary":"$summary","artifacts":[]}""",
            )
        )
    )

    private fun dialogueEventsOf(kernel: CloudAgentKernel, workItemId: String): List<DialogueEvent> =
        kernel.orchestrationStore.dialogue.page(0, 100).items.filter { it.workItemId == workItemId }

    @Test
    fun b1_nudge_exempts_active_bg_within_660s_then_wakes_awaiting_runner_idempotently() = runBlocking {
        val parkedOnce = CompletableDeferred<Unit>()
        val resumedAfterNudge = CompletableDeferred<Unit>()
        val bgActive = AtomicBoolean(true)
        val h = Harness { step, messages, _ ->
            if (step == 1) {
                parkedOnce.complete(Unit)
                UIMessage.assistant("等待后台进程完成")
            } else {
                resumedAfterNudge.complete(Unit)
                assertTrue(messages.any { it.toText().contains("系统巡检催促") })
                finishCall(summary = "nudge 后完成")
            }
        }
        try {
            h.kernel.orchestrationKernel.hasBackgroundProcesses = { bgActive.get() }
            val task = h.submit("b1-nudge")
            val workItemId = task.workItem.id
            withTimeout(5_000) { parkedOnce.await() }
            // Wait briefly until runner enters await()
            delay(50)
            val base = h.kernel.orchestrationStore.getWorkItem(workItemId)!!.lastActivityAtMs

            // Within 660s while background process is active -> exempted, no nudge
            val exemptActions = h.kernel.orchestrationKernel.runDeterministicHealthTick(base + 10 * 60_000L)
            assertTrue(exemptActions.any { it.workItemId == workItemId && it.action == HealthActionKind.EXEMPT_LONG_TOOL })
            assertTrue(h.kernel.orchestrationStore.dialogue.pending(workItemId = workItemId).isEmpty())

            // Past 660s (or when process finishes) -> NUDGE enqueues once and wakes runner
            val nudgeActions = h.kernel.orchestrationKernel.runDeterministicHealthTick(base + 11 * 60_000L + 1_000L)
            assertTrue(nudgeActions.any { it.workItemId == workItemId && it.action == HealthActionKind.NUDGE })
            withTimeout(5_000) { resumedAfterNudge.await() }
            h.awaitIdle()

            // Verify exactly one health:nudge:* input exists and was consumed, and repeating tick in window creates no second input
            val nudges = h.kernel.orchestrationStore.dialogue.find("system:health", "health:nudge:$workItemId:0")
            assertTrue(nudges != null && h.kernel.orchestrationStore.dialogue.isConsumed(nudges.id))
            assertEquals(2, h.modelCalls.get())
            assertEquals(WorkItemState.COMPLETED, h.kernel.orchestrationStore.getWorkItem(workItemId)!!.state)
        } finally {
            h.close()
        }
    }

    @Test
    fun b1_same_window_repeated_tick_does_not_create_second_nudge() = runBlocking {
        val parked = CompletableDeferred<Unit>()
        val secondCallGate = CompletableDeferred<Unit>()
        val h = Harness { step, _, _ ->
            if (step == 1) {
                parked.complete(Unit)
                UIMessage.assistant("等待后台")
            } else {
                secondCallGate.await()
                finishCall()
            }
        }
        try {
            var bg = true
            h.kernel.orchestrationKernel.hasBackgroundProcesses = { bg }
            val task = h.submit("b1-idempotent")
            val workItemId = task.workItem.id
            withTimeout(5_000) { parked.await() }
            delay(50)
            val base = h.kernel.orchestrationStore.getWorkItem(workItemId)!!.lastActivityAtMs
            bg = false

            val first = h.kernel.orchestrationKernel.runDeterministicHealthTick(base + 10 * 60_000L)
            assertEquals(HealthActionKind.NUDGE, first.single { it.workItemId == workItemId }.action)
            val second = h.kernel.orchestrationKernel.runDeterministicHealthTick(base + 11 * 60_000L)
            assertEquals(HealthActionKind.NUDGE, second.single { it.workItemId == workItemId }.action)

            // Only one nudge input exists (idempotent requestId + NUDGED stage guard)
            val pending = h.kernel.orchestrationStore.dialogue.pending(workItemId = workItemId)
            assertTrue(pending.size <= 1)
            val input = h.kernel.orchestrationStore.dialogue.find("system:health", "health:nudge:$workItemId:0")!!
            assertEquals("health:nudge:$workItemId:0", input.requestId)
            secondCallGate.complete(Unit)
            h.awaitIdle()
        } finally {
            h.close()
        }
    }

    @Test
    fun b2_b5_b6_redeliver_cancels_hanging_model_stops_processes_once_keeps_single_runner_and_no_side_effect_replay() = runBlocking {
        val firstCancelled = CompletableDeferred<Unit>()
        val secondStarted = CompletableDeferred<Unit>()
        val stopCalls = AtomicInteger()
        val sideEffectCount = AtomicInteger()
        val h = Harness { step, messages, kernel ->
            if (step == 1) {
                UIMessage.assistant("").copy(
                    parts = listOf(UIMessagePart.Tool("probe-1", "side_effect_probe", "{}"))
                )
            } else if (step == 2) {
                try {
                    awaitCancellation()
                } catch (ce: CancellationException) {
                    firstCancelled.complete(Unit)
                    throw ce
                }
            } else {
                // Step 3 is after REDELIVER: old job's finally must NOT clear the new active runner registration (B5)
                val item = kernel.orchestrationStore.listWorkItems().single()
                assertTrue(kernel.orchestrationKernel.isWorkerRunnerActive(item.workItemId), "B5: new runner must remain registered")
                assertTrue(messages.any { it.toText().contains("系统自愈重派") })
                secondStarted.complete(Unit)
                finishCall(summary = "redeliver 成功完成")
            }
        }
        try {
            h.kernel.toolRegistry.register(
                CloudToolDefinition("side_effect_probe", "副作用计数探针", false, ToolEffect.PURE) {
                    sideEffectCount.incrementAndGet()
                    buildJsonObject { put("ok", true) }
                }
            )
            val originalStop = h.kernel.orchestrationKernel.stopTaskProcessesNonClosing
            h.kernel.orchestrationKernel.stopTaskProcessesNonClosing = { id ->
                stopCalls.incrementAndGet()
                originalStop(id)
            }
            val task = h.submit("b2-redeliver")
            val workItemId = task.workItem.id

            // Wait until step 2 hangs in model call (meaning step 1 executed side_effect_probe once)
            withTimeout(5_000) {
                while (h.modelCalls.get() < 2) delay(10)
            }
            assertEquals(1, sideEffectCount.get())
            val t0 = h.kernel.orchestrationStore.getWorkItem(workItemId)!!.lastActivityAtMs

            // Step 1: NUDGE at +10m
            val tick1 = h.kernel.orchestrationKernel.runDeterministicHealthTick(t0 + 10 * 60_000L)
            assertEquals(HealthActionKind.NUDGE, tick1.single { it.workItemId == workItemId }.action)

            // Step 2: REDELIVER at +15m
            val tick2 = h.kernel.orchestrationKernel.runDeterministicHealthTick(t0 + 15 * 60_000L)
            assertEquals(HealthActionKind.INTERRUPT_AND_REDELIVER, tick2.single { it.workItemId == workItemId }.action)

            withTimeout(5_000) { firstCancelled.await() }
            withTimeout(5_000) { secondStarted.await() }
            h.awaitIdle()

            assertEquals(1, stopCalls.get(), "B2: stopTaskProcessesNonClosing must be called once")
            assertEquals(1, h.maxConcurrentRunners.get(), "B2: peak concurrent runners must be 1")
            assertEquals(1, sideEffectCount.get(), "B6: interrupted round side-effect probe must not auto-replay")
            assertNotNullRedeliverInput(h.kernel, workItemId, 1)
            val settled = h.kernel.orchestrationStore.getWorkItem(workItemId)!!
            assertEquals(WorkItemState.COMPLETED, settled.state)
            assertFalse(h.kernel.orchestrationKernel.isWorkerRunnerActive(workItemId))
        } finally {
            h.close()
        }
    }

    private fun assertNotNullRedeliverInput(kernel: CloudAgentKernel, workItemId: String, recoveryIndex: Int) {
        val input = kernel.orchestrationStore.dialogue.find("system:health", "health:redeliver:$workItemId:$recoveryIndex")
        assertTrue(input != null && kernel.orchestrationStore.dialogue.isConsumed(input.id))
    }

    @Test
    fun b3_race_completion_before_health_write_never_revives_terminal_state() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        val h = Harness { _, _, _ ->
            gate.await()
            finishCall(summary = "并发正常结算")
        }
        try {
            val task = h.submit("b3-race")
            val workItemId = task.workItem.id
            withTimeout(5_000) {
                while (h.modelCalls.get() < 1) delay(10)
            }
            val t0 = h.kernel.orchestrationStore.getWorkItem(workItemId)!!.lastActivityAtMs

            // Inject hook between health tick snapshot read and write to complete the item first
            h.kernel.orchestrationKernel.beforeHealthWriteHook = { id ->
                if (id == workItemId && !gate.isCompleted) {
                    gate.complete(Unit)
                    while (h.kernel.orchestrationStore.getWorkItem(id)?.state?.isTerminal != true) {
                        delay(10)
                    }
                }
            }

            val actions = h.kernel.orchestrationKernel.runDeterministicHealthTick(t0 + 10 * 60_000L)
            assertTrue(actions.none { it.workItemId == workItemId }, "B3: stale tick write must be skipped after terminal settlement")
            h.awaitIdle()

            val finalItem = h.kernel.orchestrationStore.getWorkItem(workItemId)!!
            assertEquals(WorkItemState.COMPLETED, finalItem.state)
            assertEquals(1, h.settlements.size, "B3: settlementListener must run exactly once")
            val taskResults = dialogueEventsOf(h.kernel, workItemId).filter { it.kind == "task_result" }
            assertEquals(1, taskResults.size, "B3: task_result event must appear once")
            assertEquals("completed", taskResults.single().outcome)
        } finally {
            h.close()
        }
    }

    @Test
    fun b4_exhausted_recovery_cancels_runner_stops_processes_and_emits_single_failed_task_result() = runBlocking {
        val cancelledCount = AtomicInteger()
        val stopCalls = AtomicInteger()
        val h = Harness { _, _, _ ->
            try {
                awaitCancellation()
            } catch (ce: CancellationException) {
                cancelledCount.incrementAndGet()
                throw ce
            }
        }
        try {
            val origStop = h.kernel.orchestrationKernel.stopTaskProcessesNonClosing
            h.kernel.orchestrationKernel.stopTaskProcessesNonClosing = { id ->
                stopCalls.incrementAndGet()
                origStop(id)
            }
            val task = h.submit("b4-exhaust")
            val workItemId = task.workItem.id
            withTimeout(5_000) { while (h.modelCalls.get() < 1) delay(10) }
            var cursor = h.kernel.orchestrationStore.getWorkItem(workItemId)!!.lastActivityAtMs

            // Recovery 1: NUDGE (+10m), REDELIVER (+15m)
            cursor += 10 * 60_000L
            assertEquals(HealthActionKind.NUDGE, h.kernel.orchestrationKernel.runDeterministicHealthTick(cursor).single().action)
            cursor += 5 * 60_000L
            assertEquals(HealthActionKind.INTERRUPT_AND_REDELIVER, h.kernel.orchestrationKernel.runDeterministicHealthTick(cursor).single().action)
            withTimeout(5_000) { while (h.modelCalls.get() < 2) delay(10) }

            // Recovery 2: NUDGE (+10m), REDELIVER (+15m)
            cursor += 10 * 60_000L
            assertEquals(HealthActionKind.NUDGE, h.kernel.orchestrationKernel.runDeterministicHealthTick(cursor).single().action)
            cursor += 5 * 60_000L
            assertEquals(HealthActionKind.INTERRUPT_AND_REDELIVER, h.kernel.orchestrationKernel.runDeterministicHealthTick(cursor).single().action)
            withTimeout(5_000) { while (h.modelCalls.get() < 3) delay(10) }

            // Exhausted (+10m)
            cursor += 10 * 60_000L
            val exhaustActions = h.kernel.orchestrationKernel.runDeterministicHealthTick(cursor)
            assertEquals(HealthActionKind.ESCALATE_NEEDS_YOU, exhaustActions.single().action)
            h.awaitIdle()

            val failed = h.kernel.orchestrationStore.getWorkItem(workItemId)!!
            assertEquals(WorkItemState.FAILED, failed.state)
            assertTrue(failed.needsYouEscalated)
            assertEquals(RecoveryStage.EXHAUSTED, failed.recoveryStage)
            assertFalse(h.kernel.orchestrationKernel.isWorkerRunnerActive(workItemId))
            assertEquals(3, cancelledCount.get())
            assertEquals(3, stopCalls.get())
            assertEquals(1, h.settlements.size)
            assertEquals("failed", h.settlements.single().outcome)
            val taskResults = dialogueEventsOf(h.kernel, workItemId).filter { it.kind == "task_result" }
            assertEquals(1, taskResults.size)
            assertEquals("failed", taskResults.single().outcome)
        } finally {
            h.close()
        }
    }

    @Test
    fun b7_restart_during_redeliver_runs_single_runner_and_settles_at_most_once() = runBlocking {
        val dir = Files.createTempDirectory("health-b7").toFile()
        val h1 = Harness(dir = dir) { _, _, _ -> awaitCancellation() }
        val workItemId: String
        try {
            val task = h1.submit("b7-restart")
            workItemId = task.workItem.id
            withTimeout(5_000) { while (h1.modelCalls.get() < 1) delay(10) }
            val t0 = h1.kernel.orchestrationStore.getWorkItem(workItemId)!!.lastActivityAtMs
            h1.kernel.orchestrationKernel.runDeterministicHealthTick(t0 + 10 * 60_000L)
            h1.kernel.orchestrationKernel.runDeterministicHealthTick(t0 + 15 * 60_000L)
            // Simulate daemon crash/restart mid-redeliver
            h1.kernel.orchestrationKernel.shutdownForRestart()
            h1.kernel.nativeDialogue.closeAndJoin()
            h1.kernel.conversationTagger.closeAndJoin()
            h1.kernel.agentRegistry.close()
            h1.kernel.orchestrationStore.close()
            h1.kernel.supertagStore.close()
        } catch (t: Throwable) {
            dir.deleteRecursively()
            throw t
        }

        val h2 = Harness(dir = dir) { _, _, _ ->
            delay(50)
            finishCall(summary = "重启后单 runner 完成")
        }
        try {
            h2.kernel.orchestrationKernel.recoverAfterRestart()
            h2.awaitIdle()
            assertEquals(1, h2.maxConcurrentRunners.get())
            assertEquals(1, h2.settlements.size)
            assertEquals(WorkItemState.COMPLETED, h2.kernel.orchestrationStore.getWorkItem(workItemId)!!.state)
            val taskResults = dialogueEventsOf(h2.kernel, workItemId).filter { it.kind == "task_result" }
            assertEquals(1, taskResults.size)
        } finally {
            h2.close()
        }
    }

    @Test
    fun b8_terminal_item_is_ignored_by_health_tick_and_rejects_followup(): Unit = runBlocking {
        val h = Harness { _, _, _ -> finishCall(summary = "直接完成") }
        try {
            val task = h.submit("b8-terminal")
            val workItemId = task.workItem.id
            h.awaitIdle()
            val settled = h.kernel.orchestrationStore.getWorkItem(workItemId)!!
            assertEquals(WorkItemState.COMPLETED, settled.state)

            val actions = h.kernel.orchestrationKernel.runDeterministicHealthTick(settled.lastActivityAtMs + 60 * 60_000L)
            assertTrue(actions.none { it.workItemId == workItemId })
            assertEquals(settled, h.kernel.orchestrationStore.getWorkItem(workItemId))

            assertFailsWith<IllegalArgumentException> {
                h.kernel.orchestrationKernel.steerWorker(
                    CloudPrincipal.OwnerUser(h.device.id, "app"),
                    workItemId,
                    "终态补充指令应被拒绝",
                )
            }
        } finally {
            h.close()
        }
    }
}
