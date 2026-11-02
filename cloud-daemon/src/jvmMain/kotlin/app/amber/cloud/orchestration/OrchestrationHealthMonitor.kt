package app.amber.cloud.orchestration

import app.amber.ai.ui.UIMessage
import app.amber.cloud.channel.OutboundCard
import app.amber.cloud.security.CredentialRedactor

/**
 * 负责每 60 秒零 Token 确定性健康巡检（3m 未启动、5m 审批等待、90s 断连宽限、10m 静默催促、
 * 45m 长耗时工具白名单豁免、离线 Mac 队列 24h 超期、最多 2 次两步自愈阶梯）及可选的模型 Watchdog。
 */
internal class OrchestrationHealthMonitor(
    private val kernel: DefaultCloudOrchestrationKernel,
) {

    suspend fun runDeterministicHealthTick(nowEpochMs: Long): List<HealthTickAction> {
        kernel.deterministicHealthTicksCount.incrementAndGet()
        val actions = mutableListOf<HealthTickAction>()
        val items = kernel.store.listWorkItems()

        for (item in items) {
            if (item.state.isTerminal) continue

            val target = item.targetNode
            if (item.state == WorkItemState.QUEUED && target is ExecutionTargetNode.PairedMacNode) {
                if (kernel.isMacNodeOnline(target.deviceId)) {
                    kernel.pumpWorkQueue(nowEpochMs)
                    val afterPump = kernel.store.getWorkItem(item.workItemId)
                    if (afterPump != null && afterPump.state != WorkItemState.QUEUED) {
                        actions.add(
                            HealthTickAction(
                                workItemId = item.workItemId,
                                action = HealthActionKind.DISPATCH_ONLINE_MAC_QUEUE,
                                finding = "mac_node_online_resumed",
                                detail = "PairedMacNode(${target.deviceId}) 已上线，自动派发排队任务 ${item.workItemId}",
                            )
                        )
                    }
                    continue
                }

                val queuedDurationMs = nowEpochMs - item.createdAtMs
                if (queuedDurationMs > kernel.config.macOfflineQueueTtlMs) {
                    val expired = item.copy(
                        state = WorkItemState.FAILED,
                        slotHeld = false,
                        failureReason = "mac_node_offline_timeout_24h",
                        updatedAtMs = nowEpochMs,
                    )
                    kernel.store.upsertWorkItem(expired)
                    kernel.store.unsubscribeAllForWorkItem(item.workItemId)
                    kernel.emitActivityInternal(expired, ActivityPhase.FAILED)
                    val detail = "派给 Mac 节点 (${target.deviceId}) 的任务「${item.title}」因设备离线超过 24 小时已转为 FAILED"
                    kernel.store.appendDiagnosticEvent(
                        sessionId = item.workerSessionId ?: item.workItemId,
                        workItemId = item.workItemId,
                        kind = "mac_offline_expired",
                        detail = detail,
                        nowMs = nowEpochMs,
                    )
                    kernel.onOwnerNotificationCard?.invoke(
                        OutboundCard(
                            title = "Mac 节点离线超 24 小时 · 任务已失败",
                            markdownBody = detail,
                            headerTemplate = "red",
                            highRisk = false,
                        ),
                        item.workItemId,
                    )
                    actions.add(
                        HealthTickAction(
                            workItemId = item.workItemId,
                            action = HealthActionKind.EXPIRE_OFFLINE_MAC_QUEUE,
                            finding = "mac_node_offline_timeout_24h",
                            detail = detail,
                        )
                    )
                    kernel.maybeTriggerBatchRollupInternal(item.batchId, nowEpochMs)
                }
                continue
            }

            val discSince = item.disconnectedSinceMs
            if (discSince != null) {
                val discElapsed = nowEpochMs - discSince
                if (discElapsed >= kernel.config.disconnectGraceMs) {
                    val detail = "节点断连已达 ${discElapsed / 1000}s（超出 90s 宽限期）"
                    kernel.store.appendDiagnosticEvent(
                        sessionId = item.workerSessionId ?: item.workItemId,
                        workItemId = item.workItemId,
                        kind = "remote_node_disconnected",
                        detail = detail,
                        nowMs = nowEpochMs,
                    )
                    actions.add(
                        HealthTickAction(
                            workItemId = item.workItemId,
                            action = HealthActionKind.NODE_DISCONNECTED_ALERT,
                            finding = "remote_node_disconnected",
                            detail = detail,
                        )
                    )
                    actions.add(advanceRecoveryLadder(item, "remote_node_disconnected", nowEpochMs))
                }
                continue
            }

            if (item.state == WorkItemState.STARTING) {
                val startElapsed = nowEpochMs - (item.startedAtMs ?: item.createdAtMs)
                if (startElapsed >= kernel.config.neverStartedTimeoutMs) {
                    actions.add(advanceRecoveryLadder(item, "never_started", nowEpochMs))
                }
                continue
            }

            if (item.state == WorkItemState.WAITING) {
                val waitElapsed = nowEpochMs - (item.waitingStartedAtMs ?: item.lastActivityAtMs)
                if (waitElapsed >= kernel.config.approvalStuckTimeoutMs) {
                    val detail = "任务 ${item.workItemId} 等待审批或输入已卡住 ${waitElapsed / 1000}s（超过 5 分钟阈值）"
                    kernel.store.appendDiagnosticEvent(
                        sessionId = item.workerSessionId ?: item.workItemId,
                        workItemId = item.workItemId,
                        kind = "approval_wait_timeout",
                        detail = detail,
                        nowMs = nowEpochMs,
                    )
                    actions.add(
                        HealthTickAction(
                            workItemId = item.workItemId,
                            action = HealthActionKind.APPROVAL_STUCK_ALERT,
                            finding = "approval_wait_timeout",
                            detail = detail,
                        )
                    )
                }
                continue
            }

            if (item.state == WorkItemState.WORKING) {
                if (kernel.config.isExemptLongRunningTool(item.activeToolName)) {
                    val toolElapsed = nowEpochMs - (item.activeToolStartedAtMs ?: item.lastActivityAtMs)
                    if (toolElapsed < kernel.config.longToolExemptionMs) {
                        actions.add(
                            HealthTickAction(
                                workItemId = item.workItemId,
                                action = HealthActionKind.EXEMPT_LONG_TOOL,
                                finding = "long_tool_exempt:${item.activeToolName}",
                                detail = "长耗时工具 ${item.activeToolName} 已运行 ${toolElapsed / 60_000}m（45m 内豁免打断）",
                            )
                        )
                        continue
                    } else {
                        actions.add(advanceRecoveryLadder(item, "tool_overtime", nowEpochMs))
                        continue
                    }
                }

                val quietElapsed = nowEpochMs - item.lastActivityAtMs
                if (quietElapsed >= kernel.config.runningQuietNudgeMs) {
                    actions.add(advanceRecoveryLadder(item, "running_quiet", nowEpochMs))
                }
            }
        }

        return actions
    }

    private suspend fun advanceRecoveryLadder(
        item: CloudWorkItemRecord,
        finding: String,
        nowEpochMs: Long,
    ): HealthTickAction {
        val sessionId = item.workerSessionId ?: item.workItemId

        if (item.recoveriesUsed >= kernel.config.maxRecoveryAttempts) {
            val exhausted = item.copy(
                state = WorkItemState.FAILED,
                slotHeld = false,
                recoveryStage = RecoveryStage.EXHAUSTED,
                needsYouEscalated = true,
                failureReason = "recovery_exhausted:$finding",
                updatedAtMs = nowEpochMs,
            )
            kernel.store.upsertWorkItem(exhausted)
            kernel.store.unsubscribeAllForWorkItem(item.workItemId)
            kernel.emitActivityInternal(exhausted, ActivityPhase.FAILED)
            val detail = "任务「${item.title}」(${item.workItemId}) 异常 ($finding) 且已用尽 ${kernel.config.maxRecoveryAttempts} 次自愈上限，请求主人介入"
            kernel.store.appendDiagnosticEvent(
                sessionId = sessionId,
                workItemId = item.workItemId,
                kind = "recovery_exhausted",
                detail = detail,
                nowMs = nowEpochMs,
            )
            kernel.onOwnerNotificationCard?.invoke(
                OutboundCard(
                    title = "Worker 自愈耗尽需介入 · ${item.title}",
                    markdownBody = detail,
                    headerTemplate = "red",
                    highRisk = false,
                ),
                item.workItemId,
            )
            kernel.pumpWorkQueue(nowEpochMs)
            kernel.maybeTriggerBatchRollupInternal(item.batchId, nowEpochMs)
            return HealthTickAction(
                workItemId = item.workItemId,
                action = HealthActionKind.ESCALATE_NEEDS_YOU,
                finding = "recovery_exhausted:$finding",
                detail = detail,
            )
        }

        if (item.recoveryStage == RecoveryStage.NONE) {
            val nudged = item.copy(
                recoveryStage = RecoveryStage.NUDGED,
                lastNudgedAtMs = nowEpochMs,
                updatedAtMs = nowEpochMs,
            )
            kernel.store.upsertWorkItem(nudged)
            val nudgeText = "【系统巡检催促】检测到任务已静默超过 10 分钟 ($finding)，请汇报当前进度或调用结算工具提交结果。"
            kernel.appendMessageToSessionInternal(sessionId, UIMessage.user(nudgeText), nowEpochMs)
            kernel.store.appendDiagnosticEvent(
                sessionId = sessionId,
                workItemId = item.workItemId,
                kind = "recovery_nudge",
                detail = nudgeText,
                nowMs = nowEpochMs,
            )
            return HealthTickAction(
                workItemId = item.workItemId,
                action = HealthActionKind.NUDGE,
                finding = finding,
                detail = "Step 1 温和催促 ($finding)",
            )
        }

        val sinceNudge = nowEpochMs - (item.lastNudgedAtMs ?: item.lastActivityAtMs)
        if (sinceNudge >= kernel.config.recoveryRedeliverDelayMs || finding == "never_started" || finding == "remote_node_disconnected") {
            val nextRecoveries = item.recoveriesUsed + 1
            val redelivered = item.copy(
                state = WorkItemState.WORKING,
                slotHeld = true,
                recoveriesUsed = nextRecoveries,
                recoveryStage = RecoveryStage.NONE,
                lastNudgedAtMs = null,
                activeToolName = null,
                activeToolStartedAtMs = null,
                lastActivityAtMs = nowEpochMs,
                updatedAtMs = nowEpochMs,
            )
            kernel.store.upsertWorkItem(redelivered)
            val redeliverText = "【系统自愈重派 #$nextRecoveries/${kernel.config.maxRecoveryAttempts}】中断卡住轮次并重派任务：${item.brief}"
            kernel.appendMessageToSessionInternal(sessionId, UIMessage.user(redeliverText), nowEpochMs)
            kernel.store.appendDiagnosticEvent(
                sessionId = sessionId,
                workItemId = item.workItemId,
                kind = "agent-recovery:interrupt_and_redeliver",
                detail = "Step 2 中断重派 ($finding), recoveriesUsed=$nextRecoveries/${kernel.config.maxRecoveryAttempts}",
                nowMs = nowEpochMs,
            )
            return HealthTickAction(
                workItemId = item.workItemId,
                action = HealthActionKind.INTERRUPT_AND_REDELIVER,
                finding = finding,
                detail = "Step 2 中断并重派 (recoveriesUsed=$nextRecoveries/${kernel.config.maxRecoveryAttempts})",
            )
        }

        return HealthTickAction(
            workItemId = item.workItemId,
            action = HealthActionKind.NUDGE,
            finding = finding,
            detail = "已处于 NUDGED 观察窗口内 (${sinceNudge / 1000}s)",
        )
    }

    suspend fun runWatchdogTick(nowEpochMs: Long): List<WatchdogAssessment> {
        if (!kernel.config.modelWatchdogEnabled) return emptyList()
        val judge = kernel.watchdogJudge ?: return emptyList()
        val assessments = mutableListOf<WatchdogAssessment>()
        for (item in kernel.store.listWorkItems().filter { it.state == WorkItemState.WORKING }) {
            val sessionId = item.workerSessionId ?: item.workItemId
            val recent = kernel.store.collapseDiagnosticEvents(kernel.store.listSqliteDiagnosticEvents(sessionId, limit = 20))
            val assessment = judge.assess(item, recent)
            assessments.add(assessment)
            kernel.store.appendDiagnosticEvent(
                sessionId = sessionId,
                workItemId = item.workItemId,
                kind = "watchdog_assessment",
                detail = "makingProgress=${assessment.makingProgress}, onTrack=${assessment.onTrack}, rec=${assessment.recommendation}: ${assessment.rationale}",
                nowMs = nowEpochMs,
            )
            if (!assessment.makingProgress || !assessment.onTrack) {
                when (assessment.recommendation.lowercase()) {
                    "nudge", "steer" -> {
                        kernel.appendMessageToSessionInternal(
                            sessionId = sessionId,
                            message = UIMessage.user("【Watchdog 巡检纠偏】${CredentialRedactor.redact(assessment.rationale)}"),
                            nowEpochMs = nowEpochMs,
                        )
                    }
                    "stop" -> {
                        kernel.transitionWorkItemState(item.workItemId, WorkItemState.CANCELLED, nowEpochMs, "Watchdog 判定偏离停止")
                        kernel.pumpWorkQueue(nowEpochMs)
                    }
                }
            }
        }
        return assessments
    }
}
