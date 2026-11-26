package app.amber.cloud.proactive

/**
 * 自唤醒触发源（P1 服务 snooze 延后提醒，P2 复用同一 Store 服务 Agent 回访与隐式承诺）。
 *
 * - 到期且逾期 `<= 12h`：产出 [ProactiveTriggerSignal.SelfWakeupSignal]（`signalId = "wk_{id}_{epochMin}"`），
 *   经 [onResult] 置位 `fired`；
 * - 逾期 `> 12h`：在 [ProactiveWakeupStore.findDueAndExpireOverdue] 中标记为 `expired`，并回调 [onExpired]
 *   写入 Pulse 缓冲与 `wakeup_expired` 运行历史，不再弹窗打扰。
 */
class SelfWakeupTriggerSource(
    private val wakeupStore: ProactiveWakeupStore,
    private val onExpired: (record: ProactiveWakeupRecord, nowEpochMs: Long) -> Unit = { _, _ -> },
) : TriggerSource {
    override val id: String = "self_wakeup"
    override val category: TriggerCategory = TriggerCategory.CLOCK_CRON

    override suspend fun pollAll(nowEpochMs: Long): List<ProactiveTriggerSignal> {
        val partition = wakeupStore.findDueAndExpireOverdue(nowEpochMs)
        for (expired in partition.expired) {
            runCatching { onExpired(expired, nowEpochMs) }
        }
        return partition.due.map { record ->
            ProactiveTriggerSignal.SelfWakeupSignal(
                signalId = ProactiveWakeupStore.signalIdFor(record),
                wakeupId = record.id,
                kind = record.kind,
                title = record.title,
                detail = record.detail,
                checkPrompt = record.checkPrompt,
                userRequested = record.userRequested,
                originSignalId = record.originSignalId,
                topicKey = "wakeup:${record.id}",
                timestampEpochMs = nowEpochMs,
            )
        }
    }

    override suspend fun onResult(
        signal: ProactiveTriggerSignal,
        result: ProactiveRunResult,
        nowEpochMs: Long,
    ) {
        if (signal !is ProactiveTriggerSignal.SelfWakeupSignal) return
        when (result) {
            is ProactiveRunResult.PushedAtL3,
            is ProactiveRunResult.DroppedAtL1,
            is ProactiveRunResult.SuppressedAtGate -> {
                wakeupStore.markFired(signal.wakeupId, firedAtEpochMs = nowEpochMs)
            }
        }
    }
}
