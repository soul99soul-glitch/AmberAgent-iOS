package app.amber.cloud.proactive

import app.amber.cloud.gateway.DeviceContextSnapshotStore
import app.amber.cloud.gateway.PairedDevice
import app.amber.cloud.runtime.CloudMemoryStore
import java.time.Instant
import java.time.ZoneId
import kotlin.math.roundToInt

/**
 * 日历 / 待办驱动的「临近事件主动准备」触发源（P0-2）：
 * - 读取 [DeviceContextSnapshotStore] 中所有未过期设备快照的 `calendarUpcoming` 与 `remindersDue`；
 * - 非全天日程距开始 15–30 分钟内：结合 [CloudMemoryStore] 检索相关历史记忆，发出 [ProactiveTriggerSignal.UpcomingEventPrepSignal]；
 * - 已过期超过 24 小时的待办：按日汇总发出 [ProactiveTriggerSignal.OverdueReminderPrepSignal]。
 */
class DeviceContextPrepTriggerSource(
    private val deviceContextStore: DeviceContextSnapshotStore,
    private val memoryStore: CloudMemoryStore,
    private val pairedDevicesProvider: () -> List<PairedDevice>,
    private val zoneIdProvider: () -> ZoneId = { ZoneId.of("Asia/Shanghai") },
) : TriggerSource {

    override val id: String = "device_context_prep"
    override val category: TriggerCategory = TriggerCategory.EXTERNAL_SENSOR

    override suspend fun pollAll(nowEpochMs: Long): List<ProactiveTriggerSignal> {
        val pairedIds = runCatching { pairedDevicesProvider().map { it.id }.toSet() }.getOrDefault(emptySet())
        if (pairedIds.isEmpty()) return emptyList()
        val snapshots = deviceContextStore.listActiveSnapshots(
            nowEpochMs = nowEpochMs,
            allowedDeviceIds = pairedIds,
        )
        if (snapshots.isEmpty()) return emptyList()

        val signals = mutableListOf<ProactiveTriggerSignal>()
        val seenEventSignatures = LinkedHashSet<String>()
        val overdueLines = LinkedHashMap<String, String>()
        var overdueDeviceName = ""

        for (snap in snapshots) {
            val deviceLabel = snap.deviceName.ifBlank { snap.deviceId }

            // 1. 会前 15–30 分钟临近日程（非全天）
            val calendarItems = snap.domains.calendarUpcoming?.items.orEmpty()
            for (item in calendarItems) {
                if (item.allDay) continue
                val deltaMs = item.startMs - nowEpochMs
                if (deltaMs < UPCOMING_WINDOW_MIN_MS || deltaMs > UPCOMING_WINDOW_MAX_MS) continue
                val sig = L1DeterministicFilter.sha256Hex(
                    "${item.title.trim().lowercase()}|${item.startMs}|${item.endMs}"
                ).take(24)
                if (!seenEventSignatures.add(sig)) continue

                val recalled = memoryStore.recallForPrompt(query = item.title, limit = 5, requireMatch = true)
                    .map { it.content }
                    .distinct()
                val minutesUntil = (deltaMs.toDouble() / 60_000.0).roundToInt().coerceIn(15, 30)
                signals.add(
                    ProactiveTriggerSignal.UpcomingEventPrepSignal(
                        signalId = "prep_ev_${sig}_$nowEpochMs",
                        eventSignature = sig,
                        eventTitle = item.title,
                        startMs = item.startMs,
                        endMs = item.endMs,
                        minutesUntilStart = minutesUntil,
                        deviceName = deviceLabel,
                        recalledMemories = recalled,
                        timestampEpochMs = nowEpochMs,
                    )
                )
            }

            // 2. 延期超过 24 小时的待办提醒
            val reminderItems = snap.domains.remindersDue?.items.orEmpty()
            for (rem in reminderItems) {
                val dueMs = rem.dueMs ?: continue
                val overdueMs = nowEpochMs - dueMs
                if (overdueMs <= OVERDUE_THRESHOLD_MS) continue
                val key = "${rem.title.trim().lowercase()}|$dueMs"
                if (key !in overdueLines) {
                    val overdueHours = (overdueMs / 3_600_000L).coerceAtLeast(24L)
                    val overdueText = if (overdueHours >= 48L) {
                        "${overdueHours / 24L} 天"
                    } else {
                        "$overdueHours 小时"
                    }
                    overdueLines[key] = "${rem.title}（已延期约 $overdueText）"
                    if (overdueDeviceName.isEmpty()) overdueDeviceName = deviceLabel
                }
            }
        }

        if (overdueLines.isNotEmpty()) {
            val dateKey = Instant.ofEpochMilli(nowEpochMs).atZone(zoneIdProvider()).toLocalDate().toString()
            signals.add(
                ProactiveTriggerSignal.OverdueReminderPrepSignal(
                    signalId = "prep_overdue_$dateKey",
                    dateKey = dateKey,
                    overdueItems = overdueLines.values.toList(),
                    deviceName = overdueDeviceName,
                    timestampEpochMs = nowEpochMs,
                )
            )
        }

        return signals
    }

    companion object {
        const val UPCOMING_WINDOW_MIN_MS = 15 * 60_000L
        const val UPCOMING_WINDOW_MAX_MS = 30 * 60_000L
        const val OVERDUE_THRESHOLD_MS = 24 * 60 * 60 * 1000L
    }
}
