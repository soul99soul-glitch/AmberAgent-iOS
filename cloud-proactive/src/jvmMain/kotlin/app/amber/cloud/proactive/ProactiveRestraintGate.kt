package app.amber.cloud.proactive

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * 静默时段配置（默认 23:00–08:00，支持跨零点与同日区间，可配置）。
 */
data class QuietHoursConfig(
    val enabled: Boolean = true,
    val start: LocalTime = LocalTime.of(23, 0),
    val end: LocalTime = LocalTime.of(8, 0),
    val zoneId: ZoneId = ZoneId.of("Asia/Shanghai"),
) {
    /**
     * 判断给定时间戳是否处于静默时段内（左闭右开 `[start, end)`）。
     */
    fun isInQuietHours(epochMs: Long): Boolean {
        if (!enabled) return false
        val localTime = Instant.ofEpochMilli(epochMs).atZone(zoneId).toLocalTime()
        return isInQuietHours(localTime)
    }

    fun isInQuietHours(localTime: LocalTime): Boolean {
        if (!enabled) return false
        return if (start <= end) {
            // 同日区间，例如 13:00 - 14:00
            !localTime.isBefore(start) && localTime.isBefore(end)
        } else {
            // 跨午夜区间，默认 23:00 - 08:00
            !localTime.isBefore(start) || localTime.isBefore(end)
        }
    }
}

/**
 * 打扰预算桶配置（对齐 `amber-cloud-self-plan.md` §6.3）。
 */
data class InterruptionBudgetConfig(
    val dailyMaxPushes: Int = 5,
    val topicCooldownMs: Long = 2 * 60 * 60 * 1000L,
    val globalCooldownMs: Long = 0L,
    val defaultMinScore: Int = 9,
    val decayedMinScoreAfterIgnore: Int = 18,
    val consecutiveIgnoresForDecay: Int = 3,
    val zoneId: ZoneId = ZoneId.of("Asia/Shanghai"),
)

/**
 * 节制阀门裁决结果。
 */
sealed class RestraintVerdict {
    data class AllowedToPush(
        val remainingDailyBudget: Int,
        val tier: Int,
        val silentDelivery: Boolean,
        val urgency: ProactiveUrgency = ProactiveUrgency.NORMAL,
    ) : RestraintVerdict()

    data class SuppressedQuietHours(
        val reason: String,
        val bufferedForMorningBriefing: Boolean = true,
    ) : RestraintVerdict()

    data class DeferredByBudget(
        val reason: String,
        val bufferedForMorningBriefing: Boolean = true,
    ) : RestraintVerdict()

    data class DroppedLowScore(
        val reason: String,
        val score: Int,
        val requiredScore: Int,
    ) : RestraintVerdict()
}

enum class ProactiveFeedbackAction(val wire: String) {
    OPENED("opened"),
    REPLIED("replied"),
    DISMISS("dismiss"),
    SNOOZE("snooze"),
    MUTE_TOPIC("mute_topic"),
}

data class FeedbackOutcome(
    val applied: Boolean,
    val mutedUntilEpochMs: Long? = null,
)

@Serializable
data class MutedTopicDto(
    val topicKey: String,
    val untilEpochMs: Long,
)

@Serializable
data class RestraintStatusSnapshot(
    val quietHoursEnabled: Boolean,
    val quietHoursStart: String,
    val quietHoursEnd: String,
    val zoneId: String,
    val dailyMaxPushes: Int,
    val pushesToday: Int,
    val remainingToday: Int,
    val bufferedPulseCount: Int,
    val mutedTopicsCount: Int,
    val pulseEnabled: Boolean = true,
    val pulseTime: String = "08:30",
    val commitmentExtractionEnabled: Boolean = true,
    val mutedTopics: List<MutedTopicDto> = emptyList(),
)

/**
 * 四维节制守门员（静默时段 + 打扰预算桶 + 渠道分级 + 负反馈自动降频），支持 0600 原子持久化。
 */
class ProactiveRestraintGate(
    quietHours: QuietHoursConfig = QuietHoursConfig(),
    budgetConfig: InterruptionBudgetConfig = InterruptionBudgetConfig(),
    private val persistenceFile: File? = null,
) {
    @Serializable
    private data class PersistedRestraintState(
        val version: Int = 1,
        val quietHoursEnabled: Boolean = true,
        val quietHoursStart: String = "23:00",
        val quietHoursEnd: String = "08:00",
        val zoneId: String = "Asia/Shanghai",
        val dailyMaxPushes: Int = 5,
        val currentDay: String? = null,
        val pushesToday: Int = 0,
        val lastGlobalPushEpochMs: Long = Long.MIN_VALUE,
        val lastPushByTopic: Map<String, Long> = emptyMap(),
        val consecutiveIgnoresByTopic: Map<String, Int> = emptyMap(),
        val mutedUntilByTopic: Map<String, Long> = emptyMap(),
        val bufferedPulseItems: List<String> = emptyList(),
        val pulseEnabled: Boolean = true,
        val pulseTime: String = "08:30",
        val commitmentExtractionEnabled: Boolean = true,
        val appliedFeedbackKeys: List<String> = emptyList(),
        val urgentDay: String? = null,
        val urgentPushesToday: Int = 0,
    )

    companion object {
        private const val MAX_PULSE_ITEMS = 100
        private const val MAX_APPLIED_FEEDBACK_KEYS = 500
        private const val MAX_DAILY_URGENT_PUSHES = 10
        private val HH_MM_REGEX = Regex("""^([01]\d|2[0-3]):[0-5]\d$""")
        private val TIME_FMT: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm")
        private val persistenceJson = Json { ignoreUnknownKeys = true; prettyPrint = true; encodeDefaults = true }

        private fun parseStrictPulseTime(raw: String): LocalTime {
            val trimmed = raw.trim()
            require(HH_MM_REGEX.matches(trimmed)) { "pulseTime 必须为 HH:mm 格式" }
            return LocalTime.parse(trimmed, TIME_FMT)
        }
    }

    @Volatile
    var quietHours: QuietHoursConfig = quietHours
        private set

    @Volatile
    var budgetConfig: InterruptionBudgetConfig = budgetConfig
        private set

    private var currentDay: LocalDate? = null
    private var pushesToday: Int = 0
    private var urgentDay: LocalDate? = null
    private var urgentPushesToday: Int = 0
    private var pulseEnabled: Boolean = true
    private var pulseTime: LocalTime = LocalTime.of(8, 30)
    private var commitmentExtractionEnabled: Boolean = true
    private var lastGlobalPushEpochMs: Long = Long.MIN_VALUE
    private val lastPushByTopic = mutableMapOf<String, Long>()
    private val consecutiveIgnoresByTopic = mutableMapOf<String, Int>()
    private val mutedUntilByTopic = mutableMapOf<String, Long>()
    private val bufferedPulseItems = ArrayDeque<String>()
    private val appliedFeedbackKeys = LinkedHashSet<String>()

    init {
        loadFromDisk()
    }

    @Synchronized
    fun updateConfig(
        quietHoursEnabled: Boolean? = null,
        quietHoursStart: String? = null,
        quietHoursEnd: String? = null,
        dailyMaxPushes: Int? = null,
        pulseEnabled: Boolean? = null,
        pulseTime: String? = null,
        commitmentExtractionEnabled: Boolean? = null,
    ): RestraintStatusSnapshot {
        val nextStart = quietHoursStart?.trim()?.let { LocalTime.parse(it) } ?: quietHours.start
        val nextEnd = quietHoursEnd?.trim()?.let { LocalTime.parse(it) } ?: quietHours.end
        val nextQuiet = quietHours.copy(enabled = quietHoursEnabled ?: quietHours.enabled, start = nextStart, end = nextEnd)
        val nextBudget = if (dailyMaxPushes != null) {
            require(dailyMaxPushes in 1..100) { "dailyMaxPushes 必须在 1..100 之间" }
            budgetConfig.copy(dailyMaxPushes = dailyMaxPushes)
        } else budgetConfig
        val nextPulseEnabled = pulseEnabled ?: this.pulseEnabled
        val nextPulseTime = if (pulseTime != null) {
            parseStrictPulseTime(pulseTime)
        } else {
            this.pulseTime
        }
        val nextCommitmentExtractionEnabled = commitmentExtractionEnabled ?: this.commitmentExtractionEnabled

        persistToDisk(
            quiet = nextQuiet,
            budget = nextBudget,
            pulseEnabledValue = nextPulseEnabled,
            pulseTimeValue = nextPulseTime,
            commitmentExtractionEnabledValue = nextCommitmentExtractionEnabled,
        )
        quietHours = nextQuiet
        budgetConfig = nextBudget
        this.pulseEnabled = nextPulseEnabled
        this.pulseTime = nextPulseTime
        this.commitmentExtractionEnabled = nextCommitmentExtractionEnabled
        return statusSnapshot()
    }

    @Synchronized
    fun statusSnapshot(nowEpochMs: Long = System.currentTimeMillis()): RestraintStatusSnapshot {
        val today = Instant.ofEpochMilli(nowEpochMs).atZone(budgetConfig.zoneId).toLocalDate()
        val effectivePushesToday = if (currentDay == today) pushesToday else 0
        val activeMutedTopics = mutedUntilByTopic.entries
            .filter { nowEpochMs < it.value }
            .sortedBy { it.key }
            .map { MutedTopicDto(topicKey = it.key, untilEpochMs = it.value) }
        return RestraintStatusSnapshot(
            quietHoursEnabled = quietHours.enabled,
            quietHoursStart = quietHours.start.format(TIME_FMT),
            quietHoursEnd = quietHours.end.format(TIME_FMT),
            zoneId = quietHours.zoneId.id,
            dailyMaxPushes = budgetConfig.dailyMaxPushes,
            pushesToday = effectivePushesToday,
            remainingToday = (budgetConfig.dailyMaxPushes - effectivePushesToday).coerceAtLeast(0),
            bufferedPulseCount = bufferedPulseItems.size,
            mutedTopicsCount = activeMutedTopics.size,
            pulseEnabled = pulseEnabled,
            pulseTime = pulseTime.format(TIME_FMT),
            commitmentExtractionEnabled = commitmentExtractionEnabled,
            mutedTopics = activeMutedTopics,
        )
    }

    /**
     * 幂等应用用户对单条主动卡片的反馈（按 signalId + action 去重并 0600 原子持久化）。
     */
    @Synchronized
    fun applyFeedback(
        signalId: String,
        topicKey: String,
        action: ProactiveFeedbackAction,
        nowEpochMs: Long,
        muteHours: Int = 168,
    ): FeedbackOutcome {
        val dedupKey = "$signalId:${action.wire}"
        if (dedupKey in appliedFeedbackKeys) {
            return FeedbackOutcome(applied = false)
        }
        appliedFeedbackKeys.add(dedupKey)
        while (appliedFeedbackKeys.size > MAX_APPLIED_FEEDBACK_KEYS) {
            val iter = appliedFeedbackKeys.iterator()
            if (!iter.hasNext()) break
            iter.next()
            iter.remove()
        }
        var mutedUntil: Long? = null
        when (action) {
            ProactiveFeedbackAction.OPENED,
            ProactiveFeedbackAction.REPLIED -> {
                consecutiveIgnoresByTopic[topicKey] = 0
            }
            ProactiveFeedbackAction.DISMISS -> {
                consecutiveIgnoresByTopic[topicKey] = (consecutiveIgnoresByTopic[topicKey] ?: 0) + 1
            }
            ProactiveFeedbackAction.MUTE_TOPIC -> {
                val until = nowEpochMs + muteHours.coerceIn(1, 720) * 3_600_000L
                mutedUntilByTopic[topicKey] = until
                mutedUntil = until
            }
            ProactiveFeedbackAction.SNOOZE -> Unit
        }
        persistToDisk()
        return FeedbackOutcome(applied = true, mutedUntilEpochMs = mutedUntil)
    }

    @Synchronized
    fun unmuteTopic(topicKey: String): RestraintStatusSnapshot {
        if (mutedUntilByTopic.remove(topicKey) != null) {
            persistToDisk()
        }
        return statusSnapshot()
    }

    /**
     * 记录用户忽略或负反馈，用于自动上调触发阈值或静默 7 天。
     */
    @Synchronized
    fun recordTopicIgnored(topicKey: String) {
        consecutiveIgnoresByTopic[topicKey] = (consecutiveIgnoresByTopic[topicKey] ?: 0) + 1
        persistToDisk()
    }

    @Synchronized
    fun recordTopicResponded(topicKey: String) {
        consecutiveIgnoresByTopic[topicKey] = 0
        persistToDisk()
    }

    @Synchronized
    fun muteTopicForDays(topicKey: String, nowEpochMs: Long, days: Int = 7) {
        mutedUntilByTopic[topicKey] = nowEpochMs + days * 86_400_000L
        persistToDisk()
    }

    /**
     * 取出并清空在静默时段或预算受限时攒下的待汇总条目（供晨间 Pulse 简报消费）。
     */
    @Synchronized
    fun drainBufferedPulseItems(): List<String> {
        val copy = bufferedPulseItems.toList()
        if (bufferedPulseItems.isNotEmpty()) {
            bufferedPulseItems.clear()
            persistToDisk()
        }
        return copy
    }

    @Synchronized
    fun peekBufferedPulseItems(): List<String> = bufferedPulseItems.toList()

    @Synchronized
    fun evaluateAndConsume(
        topicKey: String,
        summary: String,
        score: Int,
        noteworthy: Boolean,
        nowEpochMs: Long,
        isScheduledBriefing: Boolean = false,
        urgency: ProactiveUrgency = ProactiveUrgency.NORMAL,
        userRequested: Boolean = false,
    ): RestraintVerdict {
        val today = Instant.ofEpochMilli(nowEpochMs).atZone(budgetConfig.zoneId).toLocalDate()
        var dirty = false
        if (currentDay != today) {
            // L2 evaluations can finish out of order across midnight.
            if (currentDay?.isAfter(today) == true) {
                return RestraintVerdict.DeferredByBudget("事项属于已结算日期", bufferedForMorningBriefing = false)
            }
            currentDay = today
            pushesToday = 0
            dirty = true
        }
        if (urgentDay != today) {
            if (urgentDay?.isAfter(today) == true) {
                return RestraintVerdict.DeferredByBudget("事项属于已结算日期", bufferedForMorningBriefing = false)
            }
            urgentDay = today
            urgentPushesToday = 0
            dirty = true
        }

        // 0A. DIGEST：只写入晨报缓冲，不扣预算
        if (!isScheduledBriefing && urgency == ProactiveUrgency.DIGEST) {
            val mutedUntil = mutedUntilByTopic[topicKey] ?: 0L
            if (nowEpochMs < mutedUntil) {
                if (dirty) persistToDisk()
                return RestraintVerdict.DeferredByBudget(
                    reason = "话题 $topicKey 处于用户负反馈冷却期",
                    bufferedForMorningBriefing = false,
                )
            }
            if (!noteworthy) {
                if (dirty) persistToDisk()
                return RestraintVerdict.DroppedLowScore(
                    reason = "L2 评分未达主动触达阈值 (noteworthy=false, score=$score, required=${budgetConfig.defaultMinScore})",
                    score = score,
                    requiredScore = budgetConfig.defaultMinScore,
                )
            }
            if (summary.isNotBlank()) {
                bufferForMorning(summary)
                dirty = true
            }
            if (dirty) persistToDisk()
            return RestraintVerdict.DeferredByBudget(
                reason = "已转入 Pulse 汇总",
                bufferedForMorningBriefing = true,
            )
        }

        // 0B. URGENT：受静默（非 userRequested）、静音（非 userRequested）与当日 10 次上限约束；超限降级按 NORMAL 评估
        if (!isScheduledBriefing && urgency == ProactiveUrgency.URGENT) {
            if (quietHours.isInQuietHours(nowEpochMs) && !userRequested) {
                if (noteworthy && summary.isNotBlank()) {
                    bufferForMorning(summary)
                    dirty = true
                }
                if (dirty) persistToDisk()
                return RestraintVerdict.SuppressedQuietHours(
                    reason = "当前处于静默时段 (${quietHours.start}–${quietHours.end})，已暂存至次日晨间简报",
                    bufferedForMorningBriefing = true,
                )
            }
            val mutedUntil = mutedUntilByTopic[topicKey] ?: 0L
            if (nowEpochMs < mutedUntil && !userRequested) {
                if (dirty) persistToDisk()
                return RestraintVerdict.DeferredByBudget(
                    reason = "话题 $topicKey 处于用户负反馈冷却期",
                    bufferedForMorningBriefing = false,
                )
            }
            if (urgentPushesToday < MAX_DAILY_URGENT_PUSHES) {
                urgentPushesToday++
                persistToDisk()
                return RestraintVerdict.AllowedToPush(
                    remainingDailyBudget = (budgetConfig.dailyMaxPushes - pushesToday).coerceAtLeast(0),
                    tier = 3,
                    silentDelivery = false,
                    urgency = ProactiveUrgency.URGENT,
                )
            }
            // urgentPushesToday >= 10：降级走下方 NORMAL 规则评估
        }

        // 1. 静默时段硬拦截（默认 23:00–08:00 严禁任何 IM 主动推送，攒入次日晨报）
        if (quietHours.isInQuietHours(nowEpochMs)) {
            if (noteworthy && summary.isNotBlank()) {
                bufferForMorning(summary)
                dirty = true
            }
            if (dirty) persistToDisk()
            return RestraintVerdict.SuppressedQuietHours(
                reason = "当前处于静默时段 (${quietHours.start}–${quietHours.end})，已暂存至次日晨间简报",
            )
        }

        // 定时晨间简报（08:30 等非静默时段）直接放行
        if (isScheduledBriefing) {
            if (dirty) persistToDisk()
            return RestraintVerdict.AllowedToPush(
                remainingDailyBudget = (budgetConfig.dailyMaxPushes - pushesToday).coerceAtLeast(0),
                tier = 1,
                silentDelivery = false,
                urgency = ProactiveUrgency.NORMAL,
            )
        }

        // 2. 检查话题是否被手动静音
        val mutedUntil = mutedUntilByTopic[topicKey] ?: 0L
        if (nowEpochMs < mutedUntil) {
            if (dirty) persistToDisk()
            return RestraintVerdict.DeferredByBudget(
                reason = "话题 $topicKey 处于用户负反馈冷却期",
                bufferedForMorningBriefing = false,
            )
        }

        // 3. 检查 L2 noteworthy 与评分门槛（含连续 3 次忽略后的自动降频阈值衰减）
        val ignores = consecutiveIgnoresByTopic[topicKey] ?: 0
        val effectiveMinScore = if (ignores >= budgetConfig.consecutiveIgnoresForDecay) {
            budgetConfig.decayedMinScoreAfterIgnore
        } else {
            budgetConfig.defaultMinScore
        }

        if (!noteworthy || score < effectiveMinScore) {
            if (noteworthy && score >= budgetConfig.defaultMinScore && summary.isNotBlank()) {
                bufferForMorning(summary)
                dirty = true
            }
            if (dirty) persistToDisk()
            return RestraintVerdict.DroppedLowScore(
                reason = "L2 评分未达主动触达阈值 (noteworthy=$noteworthy, score=$score, required=$effectiveMinScore)",
                score = score,
                requiredScore = effectiveMinScore,
            )
        }

        // Tier 1 (9 <= S < 14)：如果是低紧急度事项且非即时行动项，按分级规则也可配置进入 Pulse，
        // 这里对 >= effectiveMinScore 的事项继续检查冷却与日预算桶
        val lastTopicPush = lastPushByTopic[topicKey]
        if (lastTopicPush != null && nowEpochMs - lastTopicPush < budgetConfig.topicCooldownMs) {
            bufferForMorning(summary)
            persistToDisk()
            return RestraintVerdict.DeferredByBudget(
                reason = "同一话题 ($topicKey) 处于冷却间隔内",
            )
        }

        if (budgetConfig.globalCooldownMs > 0L &&
            lastGlobalPushEpochMs != Long.MIN_VALUE &&
            nowEpochMs - lastGlobalPushEpochMs < budgetConfig.globalCooldownMs &&
            score < 20
        ) {
            bufferForMorning(summary)
            persistToDisk()
            return RestraintVerdict.DeferredByBudget(
                reason = "全局主动触达冷却间隔未满",
            )
        }

        if (pushesToday >= budgetConfig.dailyMaxPushes) {
            bufferForMorning(summary)
            persistToDisk()
            return RestraintVerdict.DeferredByBudget(
                reason = "今日主动强触达预算已用尽 (${budgetConfig.dailyMaxPushes} 次/天)，已转入 Pulse 简报汇总",
            )
        }

        // 4. 扣减打扰预算并放行
        pushesToday++
        lastGlobalPushEpochMs = nowEpochMs
        lastPushByTopic[topicKey] = nowEpochMs
        persistToDisk()

        val tier = when {
            score >= 20 -> 3
            score >= 14 -> 2
            else -> 1
        }
        return RestraintVerdict.AllowedToPush(
            remainingDailyBudget = budgetConfig.dailyMaxPushes - pushesToday,
            tier = tier,
            silentDelivery = tier <= 2,
            urgency = ProactiveUrgency.NORMAL,
        )
    }

    private fun bufferForMorning(summary: String) {
        if (bufferedPulseItems.size >= MAX_PULSE_ITEMS) bufferedPulseItems.removeFirst()
        bufferedPulseItems.addLast(summary.take(400))
    }

    private fun loadFromDisk() {
        val file = persistenceFile ?: return
        if (!file.isFile) return
        val state = runCatching {
            persistenceJson.decodeFromString<PersistedRestraintState>(file.readText())
        }.getOrNull() ?: return
        val loadedZone = runCatching { ZoneId.of(state.zoneId) }.getOrDefault(quietHours.zoneId)
        val loadedStart = runCatching { LocalTime.parse(state.quietHoursStart) }.getOrDefault(quietHours.start)
        val loadedEnd = runCatching { LocalTime.parse(state.quietHoursEnd) }.getOrDefault(quietHours.end)
        val loadedPulseTime = runCatching { parseStrictPulseTime(state.pulseTime) }.getOrDefault(LocalTime.of(8, 30))
        quietHours = QuietHoursConfig(
            enabled = state.quietHoursEnabled,
            start = loadedStart,
            end = loadedEnd,
            zoneId = loadedZone,
        )
        budgetConfig = budgetConfig.copy(
            dailyMaxPushes = state.dailyMaxPushes.coerceIn(1, 100),
            zoneId = loadedZone,
        )
        currentDay = state.currentDay?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
        pushesToday = state.pushesToday.coerceAtLeast(0)
        urgentDay = state.urgentDay?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
        urgentPushesToday = state.urgentPushesToday.coerceAtLeast(0)
        pulseEnabled = state.pulseEnabled
        pulseTime = loadedPulseTime
        commitmentExtractionEnabled = state.commitmentExtractionEnabled
        lastGlobalPushEpochMs = state.lastGlobalPushEpochMs
        lastPushByTopic.clear()
        lastPushByTopic.putAll(state.lastPushByTopic)
        consecutiveIgnoresByTopic.clear()
        consecutiveIgnoresByTopic.putAll(state.consecutiveIgnoresByTopic)
        mutedUntilByTopic.clear()
        mutedUntilByTopic.putAll(state.mutedUntilByTopic)
        bufferedPulseItems.clear()
        state.bufferedPulseItems.takeLast(MAX_PULSE_ITEMS).forEach(::bufferForMorning)
        appliedFeedbackKeys.clear()
        appliedFeedbackKeys.addAll(state.appliedFeedbackKeys.takeLast(MAX_APPLIED_FEEDBACK_KEYS))
    }

    private fun persistToDisk(
        quiet: QuietHoursConfig = quietHours,
        budget: InterruptionBudgetConfig = budgetConfig,
        pulseEnabledValue: Boolean = pulseEnabled,
        pulseTimeValue: LocalTime = pulseTime,
        commitmentExtractionEnabledValue: Boolean = commitmentExtractionEnabled,
    ) {
        val file = persistenceFile ?: return
        val state = PersistedRestraintState(
            quietHoursEnabled = quiet.enabled,
            quietHoursStart = quiet.start.format(TIME_FMT),
            quietHoursEnd = quiet.end.format(TIME_FMT),
            zoneId = quiet.zoneId.id,
            dailyMaxPushes = budget.dailyMaxPushes,
            currentDay = currentDay?.toString(),
            pushesToday = pushesToday,
            lastGlobalPushEpochMs = lastGlobalPushEpochMs,
            lastPushByTopic = lastPushByTopic.toMap(),
            consecutiveIgnoresByTopic = consecutiveIgnoresByTopic.toMap(),
            mutedUntilByTopic = mutedUntilByTopic.toMap(),
            bufferedPulseItems = bufferedPulseItems.toList(),
            pulseEnabled = pulseEnabledValue,
            pulseTime = pulseTimeValue.format(TIME_FMT),
            commitmentExtractionEnabled = commitmentExtractionEnabledValue,
            appliedFeedbackKeys = appliedFeedbackKeys.toList().takeLast(MAX_APPLIED_FEEDBACK_KEYS),
            urgentDay = urgentDay?.toString(),
            urgentPushesToday = urgentPushesToday,
        )
        ProactiveFilePersistence.atomicWrite0600(file, persistenceJson.encodeToString(state))
    }
}
