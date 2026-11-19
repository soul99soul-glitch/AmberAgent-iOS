package app.amber.cloud

import app.amber.ai.core.MessageRole
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.gateway.AgentCentricApi
import app.amber.cloud.gateway.CloudGatewayState
import app.amber.cloud.gateway.PushMessagePayload
import app.amber.cloud.gateway.PushSender
import app.amber.cloud.gateway.ScheduleSummaryDto
import app.amber.cloud.gateway.NativeTaskApi
import app.amber.cloud.gateway.NativeTaskRequest
import app.amber.cloud.gateway.configureCloudGateway
import app.amber.cloud.orchestration.WorkItemState
import app.amber.cloud.orchestration.WorkerSettlementReport
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import io.ktor.client.request.bearerAuth
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.server.testing.testApplication
import kotlinx.coroutines.delay
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CloudScheduleExecutionTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private fun closeKernel(kernel: CloudAgentKernel) = runBlocking {
        kernel.router.awaitIdle(includeWorkers = true)
        kernel.conversationTagger.closeAndJoin()
        kernel.supertagStore.close()
        kernel.agentRegistry.close()
        kernel.orchestrationStore.close()
    }

    private fun workerScriptedModel(
        outcome: String = "completed",
        summary: String = "完成简报 api_key=sk-secret-value-123456",
        gate: CountDownLatch? = null,
    ): CloudModelClient = CloudModelClient { _, _ ->
        gate?.await(10, TimeUnit.SECONDS)
        val argsJson = """{"outcome":"$outcome","summary":"$summary"}"""
        UIMessage(
            role = MessageRole.ASSISTANT,
            parts = listOf(
                UIMessagePart.Tool(
                    toolCallId = "tc-finish-1",
                    toolName = "task_finish",
                    input = argsJson,
                )
            ),
        )
    }

    private suspend fun awaitScheduleTerminal(
        kernel: CloudAgentKernel,
        scheduleId: String,
    ): ScheduleSummaryDto = withTimeout(10_000) {
        while (true) {
            val s = kernel.gatewayState.getSchedule(scheduleId)
            if (s != null && !s.running && s.lastStatus != "running") return@withTimeout s
            delay(25)
        }
        error("unreachable")
    }

    @Test
    fun `S1 and S8 due tick executes via NativeTaskApi and sends privacy push with deepLink`() = runBlocking {
        val dir = Files.createTempDirectory("sched-s1").toFile()
        val pushes = CopyOnWriteArrayList<PushMessagePayload>()
        val kernel = CloudAgentKernel(
            dataDir = dir,
            modelClient = workerScriptedModel(
                outcome = "completed",
                summary = "内部敏感正文 secret_prompt_marker_xyz",
            ),
            masterSecretOverride = "sched-test-master",
        )
        kernel.gatewayState.pushSender = PushSender { payload ->
            pushes.add(payload)
            Result.success(Unit)
        }
        try {
            val secret = kernel.gatewayState.issuePairingTicket()
            val paired = kernel.gatewayState.pairDevice(secret, "ios", "iPhone 主设备") as CloudGatewayState.PairResult.Success
            val device = kernel.gatewayState.findDeviceById(paired.deviceId)!!
            kernel.gatewayState.registerPushToken(device, "apns_sched_token_1", "sandbox")

            val (status, createdObj) = kernel.gatewayState.createSchedule(
                name = "晨间健康巡检",
                prompt = "CONFIDENTIAL_PROMPT_TEXT_999 请检查昨日汇总",
                rule = "hourly",
                deviceId = paired.deviceId,
            )
            assertEquals(200, status)
            val created = createdObj as ScheduleSummaryDto
            assertEquals(paired.deviceId, created.ownerDeviceId)
            assertEquals(60, created.intervalMinutes)

            // Make due now
            kernel.gatewayState.setScheduleNextRunAtForTesting(created.id, 1_700_000_000.0)
            kernel.runProactiveCycle(nowOverrideMs = 1_700_000_010_000L)

            val settled = awaitScheduleTerminal(kernel, created.id)
            assertEquals("completed", settled.lastStatus)
            assertFalse(settled.running)
            assertNotNull(settled.lastWorkItemId)
            assertNotNull(settled.lastSlotEpochSec)
            assertNull(settled.lastError)

            val workItem = kernel.orchestrationStore.getWorkItem(settled.lastWorkItemId!!)
            assertNotNull(workItem)
            assertEquals(WorkItemState.COMPLETED, workItem.state)

            // Privacy push verification (S8)
            assertEquals(1, pushes.size)
            val push = pushes.single()
            assertEquals("amber://cloud-task/${settled.lastWorkItemId}", push.deepLink)
            assertEquals(settled.lastWorkItemId, push.workItemId)
            assertEquals("定时任务更新", push.title)
            assertEquals("amber.cloud.task", push.category)
            assertFalse(push.title.contains("CONFIDENTIAL_PROMPT_TEXT_999"))
            assertFalse(push.body.contains("CONFIDENTIAL_PROMPT_TEXT_999"))
            assertFalse(push.body.contains("secret_prompt_marker_xyz"))
            assertFalse(push.body.contains("task_finish"))
        } finally {
            closeKernel(kernel)
            dir.deleteRecursively()
        }
    }

    @Test
    fun `S2 blocked and failed settlements pause or fail with redacted error`() = runBlocking {
        val dir = Files.createTempDirectory("sched-s2").toFile()
        val kernel = CloudAgentKernel(
            dataDir = dir,
            modelClient = workerScriptedModel(outcome = "completed"),
            masterSecretOverride = "sched-test-master",
        )
        try {
            val paired = kernel.gatewayState.pairDevice(kernel.gatewayState.issuePairingTicket(), "ios", "iPhone") as CloudGatewayState.PairResult.Success
            val sched = (kernel.gatewayState.createSchedule("阻断任务", "执行一步", "daily", deviceId = paired.deviceId).second as ScheduleSummaryDto)
            assertEquals(1440, sched.intervalMinutes)

            val dummyWorkId = "work:blocked-1"
            kernel.gatewayState.claimScheduleForManualRun(sched.id, kernel.gatewayState.findDeviceById(paired.deviceId)!!)
            kernel.gatewayState.attachScheduleWorkItem(sched.id, dummyWorkId)
            val settled = kernel.gatewayState.settleScheduleForWorkItem(
                workItemId = dummyWorkId,
                outcome = "blocked",
                errorDetail = "token=sk-1234567890abcdefghij failed permission",
            )
            assertNotNull(settled)
            assertTrue(settled.first.paused)
            assertEquals("blocked", settled.first.lastStatus)
            assertFalse(settled.first.lastError.orEmpty().contains("sk-1234567890abcdefghij"))
        } finally {
            closeKernel(kernel)
            dir.deleteRecursively()
        }
    }

    @Test
    fun `S3 manual trigger runs through HTTP and rejects concurrent 409`() = runBlocking {
        val dir = Files.createTempDirectory("sched-s3").toFile()
        val gate = CountDownLatch(1)
        val kernel = CloudAgentKernel(
            dataDir = dir,
            modelClient = workerScriptedModel(outcome = "completed", gate = gate),
            masterSecretOverride = "sched-test-master",
        )
        try {
            val paired = kernel.gatewayState.pairDevice(kernel.gatewayState.issuePairingTicket(), "ios", "iPhone") as CloudGatewayState.PairResult.Success
            val sched = (kernel.gatewayState.createSchedule("手工触发", "总结邮件", "weekly", deviceId = paired.deviceId).second as ScheduleSummaryDto)
            assertEquals(10080, sched.intervalMinutes)

            testApplication {
                application { configureCloudGateway(kernel.gatewayState, agentApi = AgentCentricApi(kernel)) }
                val first = client.post("/v1/amber/schedules/${sched.id}/run") {
                    bearerAuth(paired.token)
                    contentType(ContentType.Application.Json)
                    setBody("{}")
                }
                assertEquals(200, first.status.value)
                val firstJson = Json.parseToJsonElement(first.bodyAsText()).jsonObject["schedule"]!!.jsonObject
                assertTrue(firstJson["running"]!!.jsonPrimitive.boolean)
                assertEquals("running", firstJson["lastStatus"]!!.jsonPrimitive.content)

                // Second concurrent manual trigger while running returns 409
                val conflict = client.post("/v1/amber/schedules/${sched.id}/run") {
                    bearerAuth(paired.token)
                    contentType(ContentType.Application.Json)
                    setBody("{}")
                }
                assertEquals(409, conflict.status.value)
            }

            gate.countDown()
            val finished = awaitScheduleTerminal(kernel, sched.id)
            assertEquals("completed", finished.lastStatus)
            assertFalse(finished.running)
        } finally {
            gate.countDown()
            closeKernel(kernel)
            dir.deleteRecursively()
        }
    }

    @Test
    fun `S4 missed slots trigger at most 1 catchup and S7 legacy schedules never auto-tick`() = runBlocking {
        val dir = Files.createTempDirectory("sched-s4").toFile()
        val kernel = CloudAgentKernel(
            dataDir = dir,
            modelClient = workerScriptedModel(outcome = "completed"),
            masterSecretOverride = "sched-test-master",
        )
        try {
            val paired = kernel.gatewayState.pairDevice(kernel.gatewayState.issuePairingTicket(), "ios", "iPhone") as CloudGatewayState.PairResult.Success
            val periodic = kernel.gatewayState.createSchedule("间隔任务", "巡检", "interval", intervalMinutes = 30, deviceId = paired.deviceId).second as ScheduleSummaryDto
            val legacy = kernel.gatewayState.createSchedule("遗留任务", "老任务", "daily", deviceId = "remote").second as ScheduleSummaryDto
            assertNull(legacy.ownerDeviceId)

            // Simulate 5 missed 30m slots (150 minutes overdue)
            val baseSec = 1_700_000_000.0
            kernel.gatewayState.setScheduleNextRunAtForTesting(periodic.id, baseSec)
            kernel.gatewayState.setScheduleNextRunAtForTesting(legacy.id, baseSec)

            val dispatched = kernel.scheduleRunner.runDue(nowMs = ((baseSec + 5 * 1800.0 + 10.0) * 1000.0).toLong())
            assertEquals(1, dispatched.size)
            assertEquals(periodic.id, dispatched.single().id)

            // Wait for settlement, then confirm nextRunAt advanced into the future (> nowSec)
            val settled = awaitScheduleTerminal(kernel, periodic.id)
            assertEquals("completed", settled.lastStatus)
            assertTrue((settled.nextRunAt ?: 0.0) > baseSec + 5 * 1800.0 + 10.0)

            // Legacy stayed untouched
            val reloadedLegacy = kernel.gatewayState.getSchedule(legacy.id)!!
            assertNull(reloadedLegacy.lastWorkItemId)
            assertNull(reloadedLegacy.lastStatus)
        } finally {
            closeKernel(kernel)
            dir.deleteRecursively()
        }
    }

    @Test
    fun `S5 restart does not invent a terminal status for missing work`() = runBlocking {
        val dir = Files.createTempDirectory("sched-s5").toFile()
        val kernel1 = CloudAgentKernel(
            dataDir = dir,
            modelClient = workerScriptedModel(outcome = "completed"),
            masterSecretOverride = "sched-test-master",
        )
        val paired = kernel1.gatewayState.pairDevice(kernel1.gatewayState.issuePairingTicket(), "ios", "iPhone") as CloudGatewayState.PairResult.Success
        val sched = kernel1.gatewayState.createSchedule("重启恢复", "恢复测试", "hourly", deviceId = paired.deviceId).second as ScheduleSummaryDto
        closeKernel(kernel1)

        // Simulate crash leaving schedule with lastStatus = "running" and missing workItemId on disk
        val schedulesFile = File(dir, "schedules.json")
        val existingList = json.decodeFromString<List<ScheduleSummaryDto>>(schedulesFile.readText())
        schedulesFile.writeText(
            json.encodeToString(
                existingList.map { it.copy(running = true, lastStatus = "running", lastWorkItemId = "work:missing-after-crash") }
            )
        )

        val kernel2 = CloudAgentKernel(
            dataDir = dir,
            modelClient = workerScriptedModel(outcome = "completed"),
            masterSecretOverride = "sched-test-master",
        )
        try {
            kernel2.recoverColdStartConversations()
            val afterRestart = kernel2.gatewayState.getSchedule(sched.id)!!
            assertTrue(afterRestart.running)
            assertEquals("running", afterRestart.lastStatus)
        } finally {
            closeKernel(kernel2)
            dir.deleteRecursively()
        }
    }

    @Test
    fun `S6 unpairing owner device marks schedule owner_unpaired and never guesses other device`() = runBlocking {
        val dir = Files.createTempDirectory("sched-s6").toFile()
        val kernel = CloudAgentKernel(
            dataDir = dir,
            modelClient = workerScriptedModel(outcome = "completed"),
            masterSecretOverride = "sched-test-master",
        )
        try {
            val owner = kernel.gatewayState.pairDevice(kernel.gatewayState.issuePairingTicket(), "ios", "Owner Phone") as CloudGatewayState.PairResult.Success
            val other = kernel.gatewayState.pairDevice(kernel.gatewayState.issuePairingTicket(), "ios", "Other Phone") as CloudGatewayState.PairResult.Success
            assertNotNull(other.deviceId)

            val sched = kernel.gatewayState.createSchedule("独占任务", "只归 owner", "hourly", deviceId = owner.deviceId).second as ScheduleSummaryDto
            kernel.gatewayState.setScheduleNextRunAtForTesting(sched.id, 1_700_000_000.0)
            assertTrue(kernel.gatewayState.unpairDevice(owner.deviceId))

            val dispatched = kernel.scheduleRunner.runDue(nowMs = 1_700_000_100_000L)
            assertTrue(dispatched.isEmpty())

            val updated = kernel.gatewayState.getSchedule(sched.id)!!
            assertTrue(updated.paused)
            assertEquals("owner_unpaired", updated.lastError)
            assertNull(updated.lastWorkItemId)
        } finally {
            closeKernel(kernel)
            dir.deleteRecursively()
        }
    }
    @Test
    fun `review new run clears old work binding and crash preserves claimed slot`() = runBlocking {
        val dir = Files.createTempDirectory("sched-review-claim").toFile()
        val state = CloudGatewayState(dir)
        try {
            val paired = state.pairDevice(state.issuePairingTicket(), "ios", "Owner") as CloudGatewayState.PairResult.Success
            val device = state.findDeviceById(paired.deviceId)!!
            val sched = state.createSchedule("巡检", "只读巡检", "interval", 15, device.id).second as ScheduleSummaryDto
            val first = state.claimScheduleForManualRun(sched.id, device, 1000.0) as CloudGatewayState.ManualClaimResult.Claimed
            state.attachScheduleWorkItem(sched.id, "work:old")
            state.settleScheduleForWorkItem("work:old", "completed", null)
            val next = state.claimScheduleForManualRun(sched.id, device, 1001.0) as CloudGatewayState.ManualClaimResult.Claimed
            assertNull(next.claim.schedule.lastWorkItemId, "new slot must not inherit previous work")
            assertEquals("submitting", next.claim.schedule.lastStatus)
            state.reconcileSchedulesOnRestart(false, { null }, 1002.0)
            assertTrue(state.getSchedule(sched.id)!!.running, "crashed submit must retain slot for idempotent recovery")
            assertEquals(next.claim.slotEpochSec, state.getSchedule(sched.id)!!.lastSlotEpochSec)
        } finally { dir.deleteRecursively() }
    }

    @Test
    fun `review overlapping tick advances future slot instead of catching up after current settles`() = runBlocking {
        val dir = Files.createTempDirectory("sched-review-overlap").toFile()
        val state = CloudGatewayState(dir)
        try {
            val paired = state.pairDevice(state.issuePairingTicket(), "ios", "Owner") as CloudGatewayState.PairResult.Success
            val device = state.findDeviceById(paired.deviceId)!!
            val sched = state.createSchedule("巡检", "只读巡检", "interval", 15, device.id).second as ScheduleSummaryDto
            state.setScheduleNextRunAtForTesting(sched.id, 1000.0)
            assertEquals(1, state.claimDueSchedules(1000.0).size)
            assertTrue(state.claimDueSchedules(2801.0).isEmpty())
            assertEquals(3700.0, state.getSchedule(sched.id)!!.nextRunAt)
            state.attachScheduleWorkItem(sched.id, "work:current")
            state.settleScheduleForWorkItem("work:current", "completed", null)
            assertTrue(state.claimDueSchedules(2801.0).isEmpty(), "overlapping slots may not be replayed")
        } finally { dir.deleteRecursively() }
    }

    @Test
    fun `review crash after accepted submission replays same slot with original manual principal`() = runBlocking {
        val dir = Files.createTempDirectory("sched-review-replay").toFile()
        val firstKernel = CloudAgentKernel(dir, workerScriptedModel(), masterSecretOverride = "sched-review-replay")
        firstKernel.orchestrationKernel.autoExecuteWorkersInBackground = false
        val owner = firstKernel.gatewayState.pairDevice(firstKernel.gatewayState.issuePairingTicket(), "ios", "Owner") as CloudGatewayState.PairResult.Success
        val caller = firstKernel.gatewayState.pairDevice(firstKernel.gatewayState.issuePairingTicket(), "ios", "Caller") as CloudGatewayState.PairResult.Success
        val callerDevice = firstKernel.gatewayState.findDeviceById(caller.deviceId)!!
        val sched = firstKernel.gatewayState.createSchedule("复原", "只读巡检", "interval", 15, owner.deviceId).second as ScheduleSummaryDto
        val claim = (firstKernel.gatewayState.claimScheduleForManualRun(sched.id, callerDevice, 1000.0) as CloudGatewayState.ManualClaimResult.Claimed).claim
        assertEquals(caller.deviceId, claim.ownerDevice.id, "manual run must use caller principal")
        val request = NativeTaskRequest("sched.${sched.id}.${claim.slotEpochSec}", sched.prompt, title = sched.name)
        val accepted = NativeTaskApi(AgentCentricApi(firstKernel)).submit(callerDevice, request)
        assertFalse(accepted.replayed)
        assertNull(firstKernel.gatewayState.getSchedule(sched.id)!!.lastWorkItemId)
        closeKernel(firstKernel)

        val restored = CloudAgentKernel(dir, workerScriptedModel(), masterSecretOverride = "sched-review-replay")
        restored.orchestrationKernel.autoExecuteWorkersInBackground = false
        try {
            restored.scheduleRunner.recoverAfterRestart()
            val recovered = restored.gatewayState.getSchedule(sched.id)!!
            assertEquals(accepted.workItem.id, recovered.lastWorkItemId)
            assertEquals(claim.slotEpochSec, recovered.lastSlotEpochSec)
            assertEquals(owner.deviceId, recovered.ownerDeviceId)
            assertTrue(recovered.running)
            assertEquals(1, restored.orchestrationStore.listWorkItems().size)
            val replay = NativeTaskApi(AgentCentricApi(restored)).submit(callerDevice, request)
            assertTrue(replay.replayed)
            val current = restored.orchestrationStore.getWorkItem(accepted.workItem.id)!!
            restored.orchestrationStore.upsertWorkItem(current.copy(state = WorkItemState.WAITING))
            restored.scheduleRunner.recoverAfterRestart()
            assertTrue(restored.gatewayState.getSchedule(sched.id)!!.running, "WAITING is not a terminal outcome")
            restored.orchestrationStore.upsertWorkItem(current.copy(state = WorkItemState.COMPLETED, settlementOutcome = "completed"))
            restored.scheduleRunner.recoverAfterRestart()
            assertEquals("completed", restored.gatewayState.getSchedule(sched.id)!!.lastStatus)
            assertFalse(restored.gatewayState.getSchedule(sched.id)!!.running)
        } finally { closeKernel(restored); dir.deleteRecursively() }
    }

    @Test
    fun `review legacy interval cannot silently acquire automatic execution and old trigger cannot fake completion`() {
        val dir = Files.createTempDirectory("sched-review-legacy").toFile()
        try {
            val state = CloudGatewayState(dir)
            val pair = state.pairDevice(state.issuePairingTicket(), "ios", "Owner") as CloudGatewayState.PairResult.Success
            val schedule = state.createSchedule("旧任务", "只读", "daily", deviceId = pair.deviceId).second as ScheduleSummaryDto
            state.schedulesFile.writeText(json.encodeToString(listOf(schedule.copy(intervalMinutes = null, nextRunAt = 1000.0))))
            val restored = CloudGatewayState(dir)
            assertTrue(restored.claimDueSchedules(1001.0).isEmpty())
            assertEquals(409, restored.triggerScheduleNow(schedule.id, pair.deviceId).first)
            assertNull(restored.getSchedule(schedule.id)!!.lastStatus)
            assertEquals(400, restored.createSchedule("越界", "只读", "interval", 10081, pair.deviceId).first)
        } finally { dir.deleteRecursively() }
    }

    @Test
    fun `review two concurrent ticks and manual trigger create one work item`() = runBlocking {
        val dir = Files.createTempDirectory("sched-review-concurrent").toFile()
        val gate = CountDownLatch(1)
        val kernel = CloudAgentKernel(dir, workerScriptedModel(gate = gate), masterSecretOverride = "sched-review-concurrent")
        try {
            val pair = kernel.gatewayState.pairDevice(kernel.gatewayState.issuePairingTicket(), "ios", "Owner") as CloudGatewayState.PairResult.Success
            val device = kernel.gatewayState.findDeviceById(pair.deviceId)!!
            val sched = kernel.gatewayState.createSchedule("并发巡检", "只读巡检", "interval", 15, device.id).second as ScheduleSummaryDto
            kernel.gatewayState.setScheduleNextRunAtForTesting(sched.id, 1000.0)
            coroutineScope {
                listOf(
                    async(Dispatchers.Default) { kernel.scheduleRunner.runDue(1_000_000L) },
                    async(Dispatchers.Default) { kernel.scheduleRunner.runDue(1_000_000L) },
                    async(Dispatchers.Default) { kernel.scheduleRunner.triggerManual(sched.id, device) },
                ).awaitAll()
            }
            assertEquals(1, kernel.orchestrationStore.listWorkItems().size)
            assertTrue(kernel.gatewayState.getSchedule(sched.id)!!.running)
            gate.countDown()
            assertEquals("completed", awaitScheduleTerminal(kernel, sched.id).lastStatus)
        } finally { gate.countDown(); closeKernel(kernel); dir.deleteRecursively() }
    }

}
