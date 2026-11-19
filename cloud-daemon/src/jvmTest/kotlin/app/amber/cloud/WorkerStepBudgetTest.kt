package app.amber.cloud

import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.gateway.AgentCentricApi
import app.amber.cloud.gateway.NativeTaskRequest
import app.amber.cloud.orchestration.CloudPrincipal
import app.amber.cloud.orchestration.ModelWorkerTurnRunner
import app.amber.cloud.orchestration.WorkerSettlementReport
import app.amber.cloud.orchestration.WorkItemState
import app.amber.cloud.runtime.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.*

class WorkerStepBudgetTest {
    private class Fixture(reply: suspend (Int) -> UIMessage) {
        val dir = Files.createTempDirectory("worker-budget").toFile()
        val modelSteps = AtomicInteger()
        val toolSteps = AtomicInteger()
        val settlements = CopyOnWriteArrayList<WorkerSettlementReport>()
        val kernel = CloudAgentKernel(dir, CloudModelClient { messages, _ ->
            if (messages.first().toText().contains("受管 Worker")) reply(modelSteps.incrementAndGet())
            else UIMessage.assistant("{\"tags\":[]}")
        }, masterSecretOverride = "worker-budget-fixture")
        val api = AgentCentricApi(kernel)
        val device = run {
            kernel.toolRegistry.register(CloudToolDefinition("budget_probe", "合成步数探针", false, ToolEffect.PURE) {
                toolSteps.incrementAndGet()
                buildJsonObject { put("ok", true) }
            })
            val previous = kernel.orchestrationKernel.settlementListener
            kernel.orchestrationKernel.settlementListener = { item, report ->
                settlements += report
                previous(item, report)
            }
            kernel.gatewayState.pairDevice(kernel.gatewayState.issuePairingTicket(), "ios", "fixture")
            kernel.gatewayState.loadDevicesStrict().single()
        }
        suspend fun submit(id: String) = api.tasks.submit(device, NativeTaskRequest(id, "合成预算测试", title = "预算测试"))
        suspend fun awaitIdle() = withTimeout(20_000) { kernel.router.awaitIdle(includeWorkers = true) }
        suspend fun close() {
            kernel.orchestrationStore.listWorkItems().filter { !it.state.isTerminal }.forEach {
                kernel.orchestrationKernel.cancelWorkItem(CloudPrincipal.OwnerUser(device.id, "app"), it.workItemId)
            }
            awaitIdle(); kernel.nativeDialogue.closeAndJoin(); kernel.conversationTagger.closeAndJoin()
            kernel.agentRegistry.close(); kernel.orchestrationStore.close(); kernel.supertagStore.close()
            dir.deleteRecursively()
        }
    }

    private fun probe(step: Int) = UIMessage.assistant("").copy(parts = listOf(UIMessagePart.Tool("step-$step", "budget_probe", "{}")))
    private fun finish(outcome: String) = UIMessage.assistant("").copy(parts = listOf(UIMessagePart.Tool(
        "finish", "task_finish", """{"outcome":"$outcome","summary":"合成结算","artifacts":[]}""")))

    @Test fun new_task_can_pass_the_old_20_step_limit_and_finish_on_step_512() = runBlocking {
        val f = Fixture { step -> if (step == 512) finish("completed") else probe(step) }
        try {
            val task = f.submit("finish-at-512")
            f.awaitIdle()
            assertEquals(512, f.modelSteps.get(), "实际默认 Worker 必须能越过旧的20步并执行第512步")
            assertEquals(511, f.toolSteps.get())
            assertEquals(WorkItemState.COMPLETED, f.kernel.orchestrationStore.getWorkItem(task.workItem.id)!!.state)
            assertEquals(listOf("completed"), f.settlements.map { it.outcome })
        } finally { f.close() }
    }

    @Test fun exhausted_budget_executes_exactly_512_steps_and_settles_once_without_revival() = runBlocking {
        val f = Fixture(::probe)
        try {
            val task = f.submit("exhaust-512")
            f.awaitIdle()
            assertEquals(512, f.modelSteps.get(), "预算到顶后不能请求第513轮模型")
            assertEquals(512, f.toolSteps.get(), "第513轮工具不得执行")
            val settled = f.kernel.orchestrationStore.getWorkItem(task.workItem.id)!!
            assertEquals(WorkItemState.FAILED, settled.state)
            assertContains(settled.failureReason.orEmpty(), "超过最大步数仍未完成")
            assertEquals(1, f.settlements.size)
            val replay = f.submit("exhaust-512")
            assertTrue(replay.replayed)
            f.kernel.recoverColdStartConversations()
            f.kernel.orchestrationKernel.pumpWorkQueue()
            f.awaitIdle()
            assertEquals(settled, f.kernel.orchestrationStore.getWorkItem(task.workItem.id), "终态任务不得自动复活")
            assertEquals(512, f.modelSteps.get())
            assertEquals(512, f.toolSteps.get())
            assertEquals(1, f.settlements.size, "重放和恢复不得重复结算")
        } finally { f.close() }
    }

    @Test fun cancellation_on_step_21_still_stops_inference_and_prevents_the_next_tool() = runBlocking {
        val reached21 = CompletableDeferred<Unit>()
        val f = Fixture { step ->
            if (step == 21) { reached21.complete(Unit); awaitCancellation() }
            probe(step)
        }
        try {
            val task = f.submit("cancel-after-20")
            withTimeout(5_000) { reached21.await() }
            f.kernel.orchestrationKernel.cancelWorkItem(CloudPrincipal.OwnerUser(f.device.id, "app"), task.workItem.id)
            f.awaitIdle()
            assertEquals(21, f.modelSteps.get())
            assertEquals(20, f.toolSteps.get(), "人工停止后不能再执行本轮或后续工具")
            assertEquals(WorkItemState.CANCELLED, f.kernel.orchestrationStore.getWorkItem(task.workItem.id)!!.state)
            assertEquals(listOf("cancelled"), f.settlements.map { it.outcome })
        } finally { f.close() }
    }

    @Test fun explicit_failure_on_step_21_still_settles_once_instead_of_spending_the_whole_budget() = runBlocking {
        val f = Fixture { step -> if (step == 21) finish("failed") else probe(step) }
        try {
            val task = f.submit("explicit-failure")
            f.awaitIdle()
            assertEquals(21, f.modelSteps.get())
            assertEquals(20, f.toolSteps.get())
            assertEquals(WorkItemState.FAILED, f.kernel.orchestrationStore.getWorkItem(task.workItem.id)!!.state)
            assertEquals(listOf("failed"), f.settlements.map { it.outcome })
            f.kernel.orchestrationKernel.pumpWorkQueue()
            f.awaitIdle()
            assertEquals(21, f.modelSteps.get())
            assertEquals(1, f.settlements.size)
        } finally { f.close() }
    }

    @Test fun a_legacy_20_step_failure_is_not_restarted_by_the_new_default() = runBlocking {
        val f = Fixture(::probe)
        try {
            val originalRunner = f.kernel.orchestrationKernel.workerTurnRunner
            val oldRunner = ModelWorkerTurnRunner(f.kernel.orchestrationKernel, f.kernel.modelClient, f.kernel.toolRegistry, maxSteps = 20)
            f.kernel.orchestrationKernel.workerTurnRunner = { item, principal -> oldRunner.run(item, principal) }
            val task = f.submit("legacy-exhausted")
            f.awaitIdle()
            val oldFailure = f.kernel.orchestrationStore.getWorkItem(task.workItem.id)!!
            assertEquals(20, f.modelSteps.get())
            assertEquals(WorkItemState.FAILED, oldFailure.state)
            f.kernel.orchestrationKernel.workerTurnRunner = originalRunner
            f.kernel.recoverColdStartConversations()
            assertTrue(f.submit("legacy-exhausted").replayed)
            f.kernel.orchestrationKernel.pumpWorkQueue()
            f.awaitIdle()
            assertEquals(oldFailure, f.kernel.orchestrationStore.getWorkItem(task.workItem.id))
            assertEquals(20, f.modelSteps.get(), "升级上限不能自动重试已终结的旧任务")
            assertEquals(20, f.toolSteps.get())
            assertEquals(1, f.settlements.size)
        } finally { f.close() }
    }
}
