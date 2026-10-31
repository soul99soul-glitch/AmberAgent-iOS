package app.amber.cloud.proactive

import app.amber.cloud.channel.ChannelConnector
import app.amber.cloud.channel.OutboundCard
import app.amber.cloud.channel.OutboundMessage
import app.amber.cloud.channel.OutboundReceipt
import app.amber.cloud.channels.FeishuCalendarEvent
import app.amber.cloud.security.CredentialRedactor
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

/**
 * 单次主动引擎流水线执行结果。
 */
sealed class ProactiveRunResult {
    /** 在第一级确定性预筛（L1）即被拦截（0 模型调用）。 */
    data class DroppedAtL1(
        val outcome: L1Outcome.DroppedUnchanged,
    ) : ProactiveRunResult()

    /** 在第二级小模型评分（L2）或节制阀门被拦截/延后（不推送 IM）。 */
    data class SuppressedAtGate(
        val l1Delta: L1Outcome.PassedWithDelta,
        val l2Score: L2NoteworthyScore?,
        val restraintVerdict: RestraintVerdict,
    ) : ProactiveRunResult()

    /** 通过三级漏斗与节制阀门，产出 L3 主动卡片并投递至目标通道。 */
    data class PushedAtL3(
        val l1Delta: L1Outcome.PassedWithDelta,
        val l2Score: L2NoteworthyScore?,
        val restraintVerdict: RestraintVerdict.AllowedToPush,
        val card: OutboundCard,
        val receipt: OutboundReceipt?,
    ) : ProactiveRunResult()
}

/**
 * 主动引擎运行指标快照（用于验证 L1 零 Token 拦截率与节制效果）。
 */
data class ProactiveEngineMetrics(
    val l1EvaluatedCount: Int,
    val l1DroppedCount: Int,
    val l2ModelCallCount: Int,
    val l3CardsProducedCount: Int,
    val pushedCount: Int,
    val suppressedQuietHoursCount: Int,
    val deferredByBudgetCount: Int,
)

/**
 * Amber 云端本体主动引擎 v1（Proactive Intelligence Engine）。
 *
 * 完整串联：
 * 五类触发源 -> L1 确定性零成本预筛 -> L2 廉价小模型 `noteworthy` 评分 -> 静默时段与打扰预算桶 -> L3 主动卡片产出与通道投递。
 */
class ProactiveEngine(
    val l1Filter: L1DeterministicFilter = L1DeterministicFilter(),
    private val l2Judge: NoteworthyJudgeProvider,
    val restraintGate: ProactiveRestraintGate = ProactiveRestraintGate(),
    private val httpClient: HttpClient = HttpClient(OkHttp),
    private val clockMs: () -> Long = { System.currentTimeMillis() },
) {
    private val l1Evaluated = AtomicInteger(0)
    private val l1Dropped = AtomicInteger(0)
    private val l2Calls = AtomicInteger(0)
    private val l3Produced = AtomicInteger(0)
    private val pushed = AtomicInteger(0)
    private val suppressedQuiet = AtomicInteger(0)
    private val deferredBudget = AtomicInteger(0)

    private val registeredSources = mutableListOf<TriggerSource>()

    fun registerTriggerSource(source: TriggerSource) {
        registeredSources.add(source)
    }

    fun metrics(): ProactiveEngineMetrics =
        ProactiveEngineMetrics(
            l1EvaluatedCount = l1Evaluated.get(),
            l1DroppedCount = l1Dropped.get(),
            l2ModelCallCount = l2Calls.get(),
            l3CardsProducedCount = l3Produced.get(),
            pushedCount = pushed.get(),
            suppressedQuietHoursCount = suppressedQuiet.get(),
            deferredByBudgetCount = deferredBudget.get(),
        )

    /**
     * 轮询所有已注册的触发源并执行三级漏斗流水线。
     */
    suspend fun pollAllSources(
        targetChatId: String,
        channel: ChannelConnector? = null,
    ): List<ProactiveRunResult> {
        val results = mutableListOf<ProactiveRunResult>()
        for (source in registeredSources) {
            val signal = source.poll() ?: continue
            results.add(processSignal(signal, targetChatId = targetChatId, channel = channel))
        }
        return results
    }

    /**
     * 执行单个触发信号的三级漏斗处理。
     */
    suspend fun processSignal(
        signal: ProactiveTriggerSignal,
        targetChatId: String,
        channel: ChannelConnector? = null,
        nowOverrideMs: Long? = null,
    ): ProactiveRunResult {
        val evalTimeMs = nowOverrideMs ?: signal.timestampEpochMs
        l1Evaluated.incrementAndGet()

        // Stage L1: 确定性零成本预筛
        when (val l1 = l1Filter.evaluate(signal)) {
            is L1Outcome.DroppedUnchanged -> {
                l1Dropped.incrementAndGet()
                return ProactiveRunResult.DroppedAtL1(l1)
            }
            is L1Outcome.PassedWithDelta -> {
                // Stage L2: 小模型 noteworthy 打分（跨端缺陷 #3：进入 L2 提示词前强制脱敏）
                val safeDeltaSummary = CredentialRedactor.redact(l1.deltaSummary)
                val l2Score: L2NoteworthyScore? = if (l1.bypassL2ForScheduledBriefing) {
                    null
                } else {
                    l2Calls.incrementAndGet()
                    l2Judge.evaluate(
                        L2EvaluationRequest(
                            signalId = l1.signalId,
                            category = l1.category,
                            topicKey = l1.topicKey,
                            deltaSummary = safeDeltaSummary,
                        )
                    )
                }

                val effectiveNoteworthy = l2Score?.noteworthy ?: true
                val effectiveScore = l2Score?.compositeScore ?: 16
                val effectiveSummary = CredentialRedactor.redact(l2Score?.summary?.ifBlank { l1.title } ?: l1.title)

                // Stage 2.5: 静默时段与打扰预算桶节制阀门
                val verdict = restraintGate.evaluateAndConsume(
                    topicKey = l1.topicKey,
                    summary = effectiveSummary,
                    score = effectiveScore,
                    noteworthy = effectiveNoteworthy,
                    nowEpochMs = evalTimeMs,
                    isScheduledBriefing = l1.bypassL2ForScheduledBriefing,
                )

                return when (verdict) {
                    is RestraintVerdict.SuppressedQuietHours -> {
                        suppressedQuiet.incrementAndGet()
                        ProactiveRunResult.SuppressedAtGate(l1, l2Score, verdict)
                    }
                    is RestraintVerdict.DeferredByBudget -> {
                        deferredBudget.incrementAndGet()
                        ProactiveRunResult.SuppressedAtGate(l1, l2Score, verdict)
                    }
                    is RestraintVerdict.DroppedLowScore -> {
                        ProactiveRunResult.SuppressedAtGate(l1, l2Score, verdict)
                    }
                    is RestraintVerdict.AllowedToPush -> {
                        // Stage L3: 产出结构化主动卡片并投递
                        val extraPulse = if (l1.bypassL2ForScheduledBriefing) {
                            restraintGate.drainBufferedPulseItems()
                        } else {
                            emptyList()
                        }
                        val card = L3ProactiveCardProducer.buildCard(
                            delta = l1.copy(deltaSummary = safeDeltaSummary),
                            l2Score = l2Score?.copy(summary = effectiveSummary),
                            extraPulseItems = extraPulse,
                        )
                        l3Produced.incrementAndGet()

                        val receipt = channel?.sendWithReceipt(
                            OutboundMessage(
                                channel = channel.kind,
                                chatId = targetChatId,
                                text = card.markdownBody,
                                card = card,
                                idempotencyKey = "proactive:${l1.signalId}",
                                silent = verdict.silentDelivery,
                            )
                        )
                        if (receipt == null || receipt.ok) {
                            pushed.incrementAndGet()
                        }
                        ProactiveRunResult.PushedAtL3(
                            l1Delta = l1,
                            l2Score = l2Score,
                            restraintVerdict = verdict,
                            card = card,
                            receipt = receipt,
                        )
                    }
                }
            }
        }
    }

    /**
     * 场景一：Watchtower 网页异动监控（自动附带 `If-None-Match` ETag 请求头抓取页面并执行三级漏斗）。
     */
    suspend fun checkWatchtowerUrl(
        url: String,
        title: String = "",
        targetChatId: String,
        channel: ChannelConnector? = null,
        nowEpochMs: Long = clockMs(),
    ): ProactiveRunResult {
        val cleanUrl = url.trim()
        val prevEtag = l1Filter.getWatchtowerSnapshot(cleanUrl)?.etag
        val response = httpClient.get(cleanUrl) {
            if (!prevEtag.isNullOrBlank()) {
                header(HttpHeaders.IfNoneMatch, prevEtag)
            }
        }
        val status = response.status.value
        val etag = response.headers[HttpHeaders.ETag]
        val bodyText = if (status == 304) "" else response.bodyAsText()

        val signal = ProactiveTriggerSignal.WatchtowerPageSignal(
            signalId = "wt_" + UUID.randomUUID().toString().take(8),
            url = cleanUrl,
            title = title.ifBlank { cleanUrl },
            httpStatusCode = status,
            etag = etag,
            rawBody = bodyText,
            timestampEpochMs = nowEpochMs,
        )
        return processSignal(signal, targetChatId = targetChatId, channel = channel, nowOverrideMs = nowEpochMs)
    }

    /**
     * 场景二：日历冲突预警（L1 精确时间区间重叠计算 + 空闲段建议 -> L2 -> L3 主动调解卡片）。
     */
    suspend fun checkCalendarConflicts(
        datePrefix: String,
        events: List<FeishuCalendarEvent>,
        targetChatId: String,
        channel: ChannelConnector? = null,
        nowEpochMs: Long = clockMs(),
    ): ProactiveRunResult {
        val signal = ProactiveTriggerSignal.CalendarSnapshotSignal(
            signalId = "cal_" + UUID.randomUUID().toString().take(8),
            datePrefix = datePrefix,
            events = events,
            timestampEpochMs = nowEpochMs,
        )
        return processSignal(signal, targetChatId = targetChatId, channel = channel, nowOverrideMs = nowEpochMs)
    }

    /**
     * 场景三：晨间 Pulse 简报（聚合今日日程、冲突提示及昨晚静默时段/后台积压的待办洞察）。
     */
    suspend fun runMorningBriefing(
        dateString: String,
        events: List<FeishuCalendarEvent>,
        targetChatId: String,
        channel: ChannelConnector? = null,
        nowEpochMs: Long = clockMs(),
    ): ProactiveRunResult {
        val signal = ProactiveTriggerSignal.ClockCronSignal(
            signalId = "brief_$dateString",
            scheduleName = "morning_briefing",
            dateString = dateString,
            calendarEvents = events,
            timestampEpochMs = nowEpochMs,
        )
        return processSignal(signal, targetChatId = targetChatId, channel = channel, nowOverrideMs = nowEpochMs)
    }
}
