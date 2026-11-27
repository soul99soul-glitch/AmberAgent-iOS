package app.amber.cloud.gateway

import app.amber.cloud.orchestration.CloudWorkItemRecord
import app.amber.cloud.orchestration.WorkItemState
import app.amber.cloud.orchestration.WorkerSettlementReport
import app.amber.cloud.runtime.CloudAgentKernel
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Executes paired schedules through `NativeTaskApi` and reconciles their status on settlement,
 * missed-slot catchup (max 1), owner unpairing, and daemon restart (X2).
 */
class CloudScheduleRunner(
    private val kernel: CloudAgentKernel,
) {
    private val agentApi by lazy { AgentCentricApi(kernel) }
    private val nativeTaskApi by lazy { NativeTaskApi(agentApi) }
    private val dispatchMutex = Mutex()
    private val needsYouNotifications = ConcurrentHashMap.newKeySet<String>()

    suspend fun triggerManual(id: String, requesterDevice: PairedDevice): Pair<Int, Any> {
        return when (val claimResult = kernel.gatewayState.claimScheduleForManualRun(id, requesterDevice)) {
            is CloudGatewayState.ManualClaimResult.Error -> claimResult.status to claimResult.message
            is CloudGatewayState.ManualClaimResult.Claimed -> {
                val updated = dispatchClaimed(claimResult.claim)
                200 to updated
            }
        }
    }

    suspend fun runDue(nowMs: Long = System.currentTimeMillis()): List<ScheduleSummaryDto> {
        reconcileActiveSchedulesWithStore()
        kernel.gatewayState.pendingScheduleSubmissions().forEach { dispatchClaimed(it) }
        val claimed = kernel.gatewayState.claimDueSchedules(nowSeconds = nowMs / 1000.0)
        if (claimed.isEmpty()) return emptyList()
        return claimed.map { dispatchClaimed(it) }
    }

    suspend fun onWorkItemSettled(item: CloudWorkItemRecord, report: WorkerSettlementReport) {
        settleAndNotify(
            workItemId = item.workItemId,
            outcome = report.outcome,
            errorDetail = if (item.state == WorkItemState.COMPLETED) null else (item.failureReason ?: report.summary),
        )
    }

    suspend fun onWorkItemNeedsYou(item: CloudWorkItemRecord) {
        val schedule = kernel.gatewayState.listRunningSchedules().firstOrNull { it.lastWorkItemId == item.workItemId } ?: return
        val ownerId = schedule.ownerDeviceId ?: return
        val owner = kernel.gatewayState.findDeviceById(ownerId) ?: return
        if (!kernel.gatewayState.pushConfigured) return
        val payload = kernel.gatewayState.buildSchedulePushPayload(
            device = owner,
            schedule = schedule,
            workItemId = item.workItemId,
            outcome = "needsYou",
        ) ?: return
        if (!needsYouNotifications.add(item.workItemId)) return
        var sent = false
        try {
            sent = sendNotification(payload)
        } finally {
            // A waiting task is reconciled again on the next cycle.
            if (!sent) needsYouNotifications.remove(item.workItemId)
        }
    }

    suspend fun recoverAfterRestart() {
        kernel.gatewayState.reconcileSchedulesOnRestart(
            workersWillRelaunch = kernel.orchestrationKernel.autoExecuteWorkersInBackground,
            lookupWorkItem = { workId -> kernel.orchestrationStore.getWorkItem(workId) },
        )
        kernel.gatewayState.pendingScheduleSubmissions().forEach { dispatchClaimed(it) }
    }

    private suspend fun dispatchClaimed(claim: CloudGatewayState.ClaimedScheduleRun): ScheduleSummaryDto = dispatchMutex.withLock {
        val live = kernel.gatewayState.getSchedule(claim.schedule.id) ?: return@withLock claim.schedule
        if (!live.running || live.lastSlotEpochSec != claim.slotEpochSec || live.lastWorkItemId != null) return@withLock live
        val request = NativeTaskRequest(
            requestId = "sched.${claim.schedule.id}.${claim.slotEpochSec}",
            text = claim.schedule.prompt,
            title = claim.schedule.name,
        )
        try {
            val receipt = nativeTaskApi.submit(claim.ownerDevice, request)
            val attached = kernel.gatewayState.attachScheduleWorkItem(
                id = claim.schedule.id,
                workItemId = receipt.workItem.id,
                expectedSlotEpochSec = claim.slotEpochSec,
            ) ?: claim.schedule.copy(lastWorkItemId = receipt.workItem.id)
            val currentItem = kernel.orchestrationStore.getWorkItem(receipt.workItem.id)
            if (currentItem != null && currentItem.state.isTerminal) {
                settleAndNotify(
                    workItemId = currentItem.workItemId,
                    outcome = currentItem.settlementOutcome
                        ?: if (currentItem.state == WorkItemState.COMPLETED) "completed" else "failed",
                    errorDetail = currentItem.failureReason,
                ) ?: attached
            } else {
                attached
            }
        } catch (t: CancellationException) {
            throw t
        } catch (t: Exception) {
            kernel.gatewayState.failScheduleDispatch(
                id = claim.schedule.id,
                error = t.message ?: t::class.simpleName ?: "schedule_dispatch_failed",
                expectedSlotEpochSec = claim.slotEpochSec,
            ) ?: claim.schedule.copy(running = false, lastStatus = "failed")
        }
    }

    private suspend fun reconcileActiveSchedulesWithStore() {
        for (running in kernel.gatewayState.listRunningSchedules()) {
            val workId = running.lastWorkItemId ?: continue
            val item = kernel.orchestrationStore.getWorkItem(workId) ?: continue
            when {
                item.state.isTerminal -> {
                    val outcome = item.settlementOutcome
                        ?: if (item.state == WorkItemState.COMPLETED) "completed" else "failed"
                    settleAndNotify(workId, outcome, item.failureReason)
                }
                item.state == WorkItemState.WAITING || item.needsYouEscalated -> {
                    onWorkItemNeedsYou(item)
                }
            }
        }
    }

    private suspend fun settleAndNotify(
        workItemId: String,
        outcome: String,
        errorDetail: String?,
    ): ScheduleSummaryDto? {
        val settled = kernel.gatewayState.settleScheduleForWorkItem(
            workItemId = workItemId,
            outcome = outcome,
            errorDetail = errorDetail,
        ) ?: return null
        val (updatedSchedule, ownerDevice) = settled
        needsYouNotifications.remove(workItemId)
        if (ownerDevice != null && kernel.gatewayState.pushConfigured) {
            val pushOutcome = updatedSchedule.lastStatus ?: outcome
            kernel.gatewayState.buildSchedulePushPayload(
                device = ownerDevice,
                schedule = updatedSchedule,
                workItemId = workItemId,
                outcome = pushOutcome,
            )?.let { payload ->
                sendNotification(payload)
            }
        }
        return updatedSchedule
    }

    private suspend fun sendNotification(payload: PushMessagePayload): Boolean {
        val result = kernel.gatewayState.sendPush(payload)
        if (result.isFailure) {
            kernel.gatewayState.recordAudit("schedule-push-failed", mapOf(
                "device" to payload.deviceId,
                "workItemId" to payload.workItemId.orEmpty(),
            ))
        }
        return result.isSuccess
    }
}
