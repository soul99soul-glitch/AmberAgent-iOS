package app.amber.cloud.proactive

import app.amber.cloud.channels.FeishuCalendarEvent
import app.amber.cloud.gateway.DeviceContextSnapshotStore
import app.amber.cloud.gateway.PairedDevice
import app.amber.cloud.security.CredentialRedactor
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter

/**
 * 每日晨报 Pulse 触发源（Phase 2，零模型调用，按 §2-Q4 与 §4.1 契约实现）：
 * - 检查 `restraintGate.statusSnapshot().pulseEnabled`，关闭时不触发；
 * - 按 `restraintGate.budgetConfig.zoneId` 本地时间判断窗口 `[pulseTime, pulseTime + 3h)`（安全支持跨午夜与 DST）；
 * - 错过 3 小时窗口当天不补发；若当前处于静默时段内不发射信号（不提前消耗 L1 去重键）；
 * - 当天已触发过（依托持久化 `L1DeterministicFilter` 去重键 `cron:morning_briefing:<date>`）不再重复发送；
 * - 严格静默规则：仅当 `bufferedPulseCount > 0 || todayCalendarEvents.isNotEmpty()` 时才发出
 *   [ProactiveTriggerSignal.ClockCronSignal]，由 `ProactiveFunnel` 的 `bypassL2ForScheduledBriefing = true`
 *   分支零 L2 调用拼装并 drain `bufferedPulseItems`。
 */
class DailyPulseTriggerSource(
    private val restraintGate: ProactiveRestraintGate,
    private val l1Filter: L1DeterministicFilter,
    private val deviceContextStore: DeviceContextSnapshotStore,
    private val pairedDevicesProvider: () -> List<PairedDevice>,
) : TriggerSource {

    override val id: String = "daily_pulse"
    override val category: TriggerCategory = TriggerCategory.CLOCK_CRON

    override suspend fun pollAll(nowEpochMs: Long): List<ProactiveTriggerSignal> {
        val snapshot = restraintGate.statusSnapshot(nowEpochMs)
        if (!snapshot.pulseEnabled) return emptyList()

        val zoneId = restraintGate.budgetConfig.zoneId
        val pulseLocalTime = runCatching { LocalTime.parse(snapshot.pulseTime) }
            .getOrDefault(LocalTime.of(8, 30))
        val activeDate = resolveActivePulseDate(nowEpochMs, pulseLocalTime, zoneId) ?: return emptyList()

        // 若 pulseTime 落入静默时段，等待离开静默时段且仍在 3 小时窗口内时再触发，避免提前消耗 L1 去重键
        if (restraintGate.quietHours.isInQuietHours(nowEpochMs)) return emptyList()

        val dateString = activeDate.toString()
        val dedupKey = "cron:$SCHEDULE_NAME:$dateString"
        if (l1Filter.hasProcessedDeduplicationKey(dedupKey)) return emptyList()

        val todayEvents = collectTodayCalendarEvents(
            activeDate = activeDate,
            zoneId = zoneId,
            nowEpochMs = nowEpochMs,
        )
        val hasBufferedItems = snapshot.bufferedPulseCount > 0
        if (!hasBufferedItems && todayEvents.isEmpty()) {
            return emptyList()
        }

        return listOf(
            ProactiveTriggerSignal.ClockCronSignal(
                signalId = "brief_$dateString",
                scheduleName = SCHEDULE_NAME,
                dateString = dateString,
                calendarEvents = todayEvents,
                topicKey = "cron:$SCHEDULE_NAME:$dateString",
                timestampEpochMs = nowEpochMs,
            )
        )
    }

    private fun collectTodayCalendarEvents(
        activeDate: LocalDate,
        zoneId: ZoneId,
        nowEpochMs: Long,
    ): List<FeishuCalendarEvent> {
        val pairedIds = runCatching { pairedDevicesProvider().map { it.id }.toSet() }.getOrDefault(emptySet())
        if (pairedIds.isEmpty()) return emptyList()
        val snapshots = deviceContextStore.listActiveSnapshots(
            nowEpochMs = nowEpochMs,
            allowedDeviceIds = pairedIds,
        )
        if (snapshots.isEmpty()) return emptyList()

        val dayStartZoned = activeDate.atStartOfDay(zoneId)
        val nextDayStartZoned = activeDate.plusDays(1).atStartOfDay(zoneId)
        val dayStartMs = dayStartZoned.toInstant().toEpochMilli()
        val dayEndMs = nextDayStartZoned.toInstant().toEpochMilli()
        val datePrefix = activeDate.toString()

        val seenSignatures = LinkedHashSet<String>()
        val mapped = mutableListOf<FeishuCalendarEvent>()

        for (snap in snapshots) {
            val deviceLabel = CredentialRedactor.redact(snap.deviceName.ifBlank { snap.deviceId }).take(40)
            val items = snap.domains.calendarUpcoming?.items.orEmpty()
            for (item in items) {
                if (item.endMs <= item.startMs && !item.allDay) continue
                val effectiveEndMs = if (item.endMs > item.startMs) item.endMs else item.startMs + 60_000L
                val overlapsToday = item.startMs < dayEndMs && effectiveEndMs > dayStartMs
                if (!overlapsToday) continue

                val sig = L1DeterministicFilter.sha256Hex(
                    "${item.title.trim().lowercase()}|${item.startMs}|${item.endMs}|${item.allDay}"
                ).take(16)
                if (!seenSignatures.add(sig)) continue

                val safeTitle = CredentialRedactor.redact(item.title.trim()).take(120).ifBlank { "未命名日程" }
                val (startText, endText) = if (item.allDay) {
                    "$datePrefix 00:00" to "$datePrefix 23:59"
                } else {
                    val clampedStartMs = maxOf(item.startMs, dayStartMs)
                    val clampedEndMs = minOf(effectiveEndMs, dayEndMs - 60_000L).coerceAtLeast(clampedStartMs + 60_000L)
                    val startStr = Instant.ofEpochMilli(clampedStartMs).atZone(zoneId).format(CALENDAR_TIME_FMT)
                    val endStr = Instant.ofEpochMilli(clampedEndMs).atZone(zoneId).format(CALENDAR_TIME_FMT)
                    startStr to endStr
                }

                mapped.add(
                    FeishuCalendarEvent(
                        id = "devcal_$sig",
                        summary = safeTitle,
                        startTime = startText,
                        endTime = endText,
                        location = deviceLabel.ifBlank { "设备日历" },
                        source = "device_context",
                    )
                )
            }
        }
        return mapped.sortedBy { it.startTime }
    }

    companion object {
        const val SCHEDULE_NAME = "morning_briefing"
        const val PULSE_WINDOW_HOURS = 3L
        private const val PULSE_WINDOW_SECONDS = PULSE_WINDOW_HOURS * 3_600L
        private val CALENDAR_TIME_FMT: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")

        /**
         * 判断给定时间是否落在某天 `[pulseTime, pulseTime + 3h)` 窗口内，返回对应本地日期；
         * 同时检查昨天起算的 3 小时窗口，以安全支持 `pulseTime` 跨午夜（例如 22:00 → 22:00..次日 01:00）。
         */
        internal fun resolveActivePulseDate(
            nowEpochMs: Long,
            pulseLocalTime: LocalTime,
            zoneId: ZoneId,
        ): LocalDate? {
            val nowInstant = Instant.ofEpochMilli(nowEpochMs)
            val today = nowInstant.atZone(zoneId).toLocalDate()
            val todayStart = ZonedDateTime.of(today, pulseLocalTime, zoneId).toInstant()
            val todayEnd = todayStart.plusSeconds(PULSE_WINDOW_SECONDS)
            if (!nowInstant.isBefore(todayStart) && nowInstant.isBefore(todayEnd)) {
                return today
            }
            val yesterday = today.minusDays(1)
            val yesterdayStart = ZonedDateTime.of(yesterday, pulseLocalTime, zoneId).toInstant()
            val yesterdayEnd = yesterdayStart.plusSeconds(PULSE_WINDOW_SECONDS)
            if (!nowInstant.isBefore(yesterdayStart) && nowInstant.isBefore(yesterdayEnd)) {
                return yesterday
            }
            return null
        }
    }
}
