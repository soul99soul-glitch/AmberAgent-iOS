package app.amber.cloud.orchestration

import app.amber.ai.ui.UIMessage
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.security.CredentialRedactor
import java.util.UUID
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * 负责 Worker 增量进度上报、无时间戳 SHA-256 结算报告归档、并发槽位释放，
 * 以及基于 `wakeClaim` 原子锁的 `BatchRollup` 单次唤醒。
 */
internal class OrchestrationRollupCoordinator(
    private val kernel: DefaultCloudOrchestrationKernel,
) {
    private val settlementMutex = Mutex()

    suspend fun updateWorkerProgress(
        principal: CloudPrincipal,
        workItemId: String,
        expectedRevision: Int,
        progressNote: String,
        activeToolName: String?,
        nowEpochMs: Long,
    ): CloudWorkItemRecord {
        if (principal is CloudPrincipal.Worker && principal.workItemId != workItemId) {
            throw PrincipalPermissionException(
                "Worker (${principal.workItemId}) 禁止篡改其他 Worker ($workItemId) 的进度"
            )
        }
        if (principal !is CloudPrincipal.Worker && principal !is CloudPrincipal.CloudCoordinator) {
            throw PrincipalPermissionException("当前主体 (${principal.principalId}) 无权更新 Worker 进度")
        }

        val updated = kernel.store.updateWorkItemCasRevision(workItemId, expectedRevision) { existing ->
            // A late progress callback must not reclaim a slot after cancellation/settlement.
            if (existing.state.isTerminal) return@updateWorkItemCasRevision existing
            val toolStart = when {
                activeToolName.isNullOrBlank() -> null
                activeToolName == existing.activeToolName && existing.activeToolStartedAtMs != null -> existing.activeToolStartedAtMs
                else -> nowEpochMs
            }
            existing.copy(
                state = if (existing.state == WorkItemState.STARTING || existing.state == WorkItemState.IDLE) {
                    WorkItemState.WORKING
                } else {
                    existing.state
                },
                slotHeld = true,
                progressRevision = existing.progressRevision + 1,
                latestProgressNote = CredentialRedactor.redact(progressNote),
                activeToolName = activeToolName?.trim()?.takeIf { it.isNotEmpty() },
                activeToolStartedAtMs = toolStart,
                recoveryStage = RecoveryStage.NONE,
                lastNudgedAtMs = null,
                lastActivityAtMs = nowEpochMs,
                updatedAtMs = nowEpochMs,
            )
        }
        kernel.store.appendDiagnosticEvent(
            sessionId = updated.workerSessionId ?: updated.workItemId,
            workItemId = updated.workItemId,
            kind = "worker_progress",
            detail = "rev=${updated.progressRevision}, tool=${updated.activeToolName ?: "none"}, note=${updated.latestProgressNote}",
            nowMs = nowEpochMs,
        )
        kernel.emitActivityInternal(updated, ActivityPhase.PROGRESS)
        return updated
    }

    suspend fun reportWorkerSettlement(
        principal: CloudPrincipal,
        report: WorkerSettlementReport,
        nowEpochMs: Long,
    ): CloudWorkItemRecord = settlementMutex.withLock {
        reportWorkerSettlementLocked(principal, report, nowEpochMs)
    }

    private suspend fun reportWorkerSettlementLocked(
        principal: CloudPrincipal,
        report: WorkerSettlementReport,
        nowEpochMs: Long,
    ): CloudWorkItemRecord {
        if (principal is CloudPrincipal.Worker && principal.workItemId != report.workItemId) {
            throw PrincipalPermissionException(
                "Worker (${principal.workItemId}) 禁止提交其他 Worker (${report.workItemId}) 的结算报告"
            )
        }
        if (principal !is CloudPrincipal.Worker && principal !is CloudPrincipal.CloudCoordinator) {
            throw PrincipalPermissionException("当前主体 (${principal.principalId}) 无权提交结算报告")
        }

        val existing = kernel.store.getWorkItem(report.workItemId)
            ?: throw IllegalArgumentException("找不到 WorkItem: ${report.workItemId}")
        if (existing.state.isTerminal) {
            return existing
        }
        if(report.outcome!="cancelled" && (kernel.workerEvents.isStopping(existing.workItemId)||kernel.workerEvents.pending(existing.workItemId).isNotEmpty()))return existing

        val reportDocPath = "inbox/${existing.workItemId}/report.md"
        val reportMarkdown = formatTimestampFreeSettlementMarkdown(existing, report)
        val archivedDoc = kernel.store.writeSettlementReport(
            principal = principal,
            workItemId = existing.workItemId,
            content = reportMarkdown,
            nowMs = nowEpochMs,
        )

        kernel.store.addRecallEdge(
            fromKind = RecallObjectKind.WORK_ITEM,
            fromId = existing.workItemId,
            toKind = RecallObjectKind.ARCHIVE_DOCUMENT,
            toId = reportDocPath,
            summary = "结算报告 (${report.outcome}): ${report.summary.take(60)}",
            nowMs = nowEpochMs,
        )
        kernel.store.addRecallEdge(
            fromKind = RecallObjectKind.ARCHIVE_DOCUMENT,
            fromId = reportDocPath,
            toKind = RecallObjectKind.WORK_ITEM,
            toId = existing.workItemId,
            summary = "所属任务: ${existing.title}",
            nowMs = nowEpochMs,
        )

        val targetState = when (report.outcome.trim().lowercase()) {
            "completed", "success", "ok" -> WorkItemState.COMPLETED
            "cancelled", "canceled" -> WorkItemState.CANCELLED
            else -> WorkItemState.FAILED
        }

        val settled = existing.copy(
            state = targetState,
            slotHeld = false,
            activeToolName = null,
            activeToolStartedAtMs = null,
            recoveriesUsed = if (targetState == WorkItemState.COMPLETED) 0 else existing.recoveriesUsed,
            recoveryStage = RecoveryStage.NONE,
            settlementReportPath = archivedDoc.docPath,
            settlementOutcome = report.outcome,
            failureReason = if (targetState == WorkItemState.FAILED) CredentialRedactor.redact(report.summary) else null,
            lastActivityAtMs = nowEpochMs,
            updatedAtMs = nowEpochMs,
        )
        synchronized(kernel.store) {
            // Acceptance and terminal admission share the store monitor: an ACKed input cannot slip past settlement.
            if(report.outcome!="cancelled" && (kernel.workerEvents.isStopping(existing.workItemId)||kernel.workerEvents.pending(existing.workItemId).isNotEmpty()))return existing
            kernel.store.upsertWorkItem(settled)
        }
        kernel.settlementListener(settled,report)
        existing.workerSessionId?.let { sessionId ->
            kernel.appendMessageToSessionInternal(sessionId,UIMessage.assistant("【任务结算 · ${report.outcome}】\n${CredentialRedactor.redact(report.summary)}"),nowEpochMs)
        }
        kernel.store.unsubscribeAllForWorkItem(settled.workItemId)
        kernel.store.appendDiagnosticEvent(
            sessionId = settled.workerSessionId ?: settled.workItemId,
            workItemId = settled.workItemId,
            kind = "worker_settled",
            detail = "state=$targetState, report=${archivedDoc.docPath}, sha256=${archivedDoc.contentSha256.take(12)}",
            nowMs = nowEpochMs,
        )

        kernel.emitActivityInternal(settled, if (targetState == WorkItemState.COMPLETED) ActivityPhase.DONE else ActivityPhase.FAILED)
        kernel.pumpWorkQueue(nowEpochMs)
        maybeTriggerBatchRollup(settled.batchId, nowEpochMs)

        return settled
    }

    suspend fun maybeTriggerBatchRollup(batchId: String, nowEpochMs: Long) {
        val batchItems = kernel.store.listWorkItemsByBatch(batchId)
        if (batchItems.isEmpty() || !batchItems.all { it.state.isTerminal }) {
            return
        }

        val rollupMarkdown = buildString {
            append("# Batch Rollup · ").append(batchId).append('\n')
            for (item in batchItems) {
                append("- **").append(item.title).append("** (`").append(item.taskKey).append("` / `")
                    .append(item.workItemId).append("`): **").append(item.state.name).append("**")
                if (item.settlementReportPath != null) {
                    append(" → `[doc:").append(item.settlementReportPath).append("]`")
                }
                append('\n')
            }
        }.trim()

        val claimId = "wake:" + UUID.randomUUID().toString().lowercase()
        val claimedRollup = kernel.store.tryClaimBatchWake(
            batchId = batchId,
            claimId = claimId,
            workItemIds = batchItems.map { it.workItemId },
            rollupMarkdown = rollupMarkdown,
            nowMs = nowEpochMs,
            ttlMs = kernel.config.wakeClaimTtlMs,
        ) ?: return

        val coordinatorPrincipal = CloudPrincipal.CloudCoordinator(
            activeSessionId = PRIMARY_CONVERSATION_ID.toString(),
            activeTurnId = claimId,
        )
        val rollupDocPath = "rollups/$batchId.md"
        kernel.store.writeArchivedDocument(
            principal = coordinatorPrincipal,
            docPath = rollupDocPath,
            content = rollupMarkdown,
            expectedRevision = null,
            deduplicateIfSameSha256 = true,
            nowMs = nowEpochMs,
        )
        kernel.store.addRecallEdge(
            fromKind = RecallObjectKind.BATCH,
            fromId = batchId,
            toKind = RecallObjectKind.ARCHIVE_DOCUMENT,
            toId = rollupDocPath,
            summary = "批次汇总归档 ($batchId)",
            nowMs = nowEpochMs,
        )

        kernel.batchRollupWakeCount.incrementAndGet()
        kernel.onBatchRollupWoken?.invoke(claimedRollup)
    }

    private fun formatTimestampFreeSettlementMarkdown(
        item: CloudWorkItemRecord,
        report: WorkerSettlementReport,
    ): String = buildString {
        append("# Settlement Report · ").append(item.workItemId).append('\n')
        append("- TaskKey: ").append(item.taskKey).append('\n')
        append("- Title: ").append(CredentialRedactor.redact(item.title)).append('\n')
        append("- Outcome: ").append(report.outcome.trim().lowercase()).append('\n')
        append("\n## Summary\n")
        append(CredentialRedactor.redact(report.summary.trim())).append('\n')
        if (report.blockers.isNotEmpty()) {
            append("\n## Blockers\n")
            report.blockers.forEach { append("- ").append(CredentialRedactor.redact(it)).append('\n') }
        }
        if (report.artifacts.isNotEmpty()) {
            append("\n## Artifacts\n")
            report.artifacts.forEach { append("- ").append(CredentialRedactor.redact(it)).append('\n') }
        }
    }
}
