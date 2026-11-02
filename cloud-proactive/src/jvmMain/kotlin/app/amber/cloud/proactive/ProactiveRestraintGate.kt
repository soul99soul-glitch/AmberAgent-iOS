package app.amber.cloud.proactive

import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

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

/**
 * 四维节制守门员（静默时段 + 打扰预算桶 + 渠道分级 + 负反馈自动降频）。
 */
class ProactiveRestraintGate(
    val quietHours: QuietHoursConfig = QuietHoursConfig(),
    val budgetConfig: InterruptionBudgetConfig = InterruptionBudgetConfig(),
) {
    private var currentDay: LocalDate? = null
    private var pushesToday: Int = 0
    private var lastGlobalPushEpochMs: Long = Long.MIN_VALUE
    private val lastPushByTopic = mutableMapOf<String, Long>()
    private val consecutiveIgnoresByTopic = mutableMapOf<String, Int>()
    private val mutedUntilByTopic = mutableMapOf<String, Long>()
    private val bufferedPulseItems = mutableListOf<String>()

    /**
     * 记录用户忽略或负反馈，用于自动上调触发阈值或静默 7 天。
     */
    @Synchronized
    fun recordTopicIgnored(topicKey: String) {
        consecutiveIgnoresByTopic[topicKey] = (consecutiveIgnoresByTopic[topicKey] ?: 0) + 1
    }

    @Synchronized
    fun recordTopicResponded(topicKey: String) {
        consecutiveIgnoresByTopic[topicKey] = 0
    }

    @Synchronized
    fun muteTopicForDays(topicKey: String, nowEpochMs: Long, days: Int = 7) {
        mutedUntilByTopic[topicKey] = nowEpochMs + days * 86_400_000L
    }

    /**
     * 取出并清空在静默时段或预算受限时攒下的待汇总条目（供晨间 Pulse 简报消费）。
     */
    @Synchronized
    fun drainBufferedPulseItems(): List<String> {
        val copy = bufferedPulseItems.toList()
        bufferedPulseItems.clear()
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
    ): RestraintVerdict {
        val today = Instant.ofEpochMilli(nowEpochMs).atZone(budgetConfig.zoneId).toLocalDate()
        if (currentDay != today) {
            currentDay = today
            pushesToday = 0
        }

        // 1. 静默时段硬拦截（默认 23:00–08:00 严禁任何 IM 主动推送，攒入次日晨报）
        if (quietHours.isInQuietHours(nowEpochMs)) {
            if (noteworthy && summary.isNotBlank()) {
                bufferedPulseItems.add(summary)
            }
            return RestraintVerdict.SuppressedQuietHours(
                reason = "当前处于静默时段 (${quietHours.start}–${quietHours.end})，已暂存至次日晨间简报",
            )
        }

        // 定时晨间简报（08:30 等非静默时段）直接放行
        if (isScheduledBriefing) {
            return RestraintVerdict.AllowedToPush(
                remainingDailyBudget = (budgetConfig.dailyMaxPushes - pushesToday).coerceAtLeast(0),
                tier = 1,
                silentDelivery = false,
            )
        }

        // 2. 检查话题是否被手动静音
        val mutedUntil = mutedUntilByTopic[topicKey] ?: 0L
        if (nowEpochMs < mutedUntil) {
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
                bufferedPulseItems.add(summary)
            }
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
            bufferedPulseItems.add(summary)
            return RestraintVerdict.DeferredByBudget(
                reason = "同一话题 ($topicKey) 处于冷却间隔内",
            )
        }

        if (budgetConfig.globalCooldownMs > 0L &&
            lastGlobalPushEpochMs != Long.MIN_VALUE &&
            nowEpochMs - lastGlobalPushEpochMs < budgetConfig.globalCooldownMs &&
            score < 20
        ) {
            bufferedPulseItems.add(summary)
            return RestraintVerdict.DeferredByBudget(
                reason = "全局主动触达冷却间隔未满",
            )
        }

        if (pushesToday >= budgetConfig.dailyMaxPushes) {
            bufferedPulseItems.add(summary)
            return RestraintVerdict.DeferredByBudget(
                reason = "今日主动强触达预算已用尽 (${budgetConfig.dailyMaxPushes} 次/天)，已转入 Pulse 简报汇总",
            )
        }

        // 4. 扣减打扰预算并放行
        pushesToday++
        lastGlobalPushEpochMs = nowEpochMs
        lastPushByTopic[topicKey] = nowEpochMs

        val tier = when {
            score >= 20 -> 3
            score >= 14 -> 2
            else -> 1
        }
        return RestraintVerdict.AllowedToPush(
            remainingDailyBudget = budgetConfig.dailyMaxPushes - pushesToday,
            tier = tier,
            silentDelivery = tier <= 2,
        )
    }
}
