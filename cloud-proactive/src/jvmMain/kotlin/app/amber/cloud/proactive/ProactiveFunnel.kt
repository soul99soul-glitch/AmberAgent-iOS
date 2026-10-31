package app.amber.cloud.proactive

import app.amber.cloud.channel.ButtonStyle
import app.amber.cloud.channel.OutboundButton
import app.amber.cloud.channel.OutboundCard
import app.amber.cloud.channels.FeishuCalendarClient
import app.amber.cloud.channels.FeishuCalendarEvent
import app.amber.cloud.channels.FeishuFreeSlot
import app.amber.cloud.channels.ImApprovalGate
import app.amber.core.native.AmberNativeBridge
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.nio.charset.StandardCharsets
import java.security.MessageDigest

/**
 * L1 确定性零成本预筛结果。
 */
sealed class L1Outcome {
    /**
     * 未发生变化或已处理过：在 L1 阶段直接静默丢弃（0 模型调用）。
     */
    data class DroppedUnchanged(
        val reason: String,
        val sha256: String? = null,
        val etag: String? = null,
        val consecutiveUnchanged: Int = 0,
        val recommendedPollIntervalMinutes: Int = 15,
    ) : L1Outcome()

    /**
     * 检测到真实增量变化，进入 L2 小模型打分（或直接进入晨报汇总）。
     */
    data class PassedWithDelta(
        val signalId: String,
        val category: TriggerCategory,
        val topicKey: String,
        val title: String,
        val deltaSummary: String,
        val sha256: String? = null,
        val etag: String? = null,
        val addedLines: List<String> = emptyList(),
        val removedLines: List<String> = emptyList(),
        val conflicts: List<CalendarConflictPair> = emptyList(),
        val suggestedFreeSlots: List<FeishuFreeSlot> = emptyList(),
        val approvalToolCallId: String? = null,
        val bypassL2ForScheduledBriefing: Boolean = false,
    ) : L1Outcome()
}

/**
 * Watchtower 页面持久快照（移植并升级自 `DesktopWatchtower.swift`）。
 */
@Serializable
data class WatchtowerPageSnapshot(
    val url: String,
    val sha256: String,
    val fnvHash: String,
    val etag: String? = null,
    val lines: List<String>,
    val snapshotsCount: Int,
    val consecutiveUnchanged: Int = 0,
    val updatedAtEpochMs: Long,
)

/**
 * 日历冲突对（两场时间区间相交的日程）。
 */
@Serializable
data class CalendarConflictPair(
    val first: FeishuCalendarEvent,
    val second: FeishuCalendarEvent,
    val overlapStartMinutes: Int,
    val overlapEndMinutes: Int,
) {
    val overlapRangeText: String
        get() = "%02d:%02d-%02d:%02d".format(
            overlapStartMinutes / 60,
            overlapStartMinutes % 60,
            overlapEndMinutes / 60,
            overlapEndMinutes % 60,
        )
}

/**
 * 第一级漏斗（L1）：确定性零 Token 预筛器。
 *
 * 包含：
 * 1. HTTP 304 / ETag 比对；
 * 2. 正文去噪归一化后的 SHA-256（及 FNV-1a）快照比对与最多 8 行新增/删除提取（移植自 `DesktopWatchtower.swift`）；
 * 3. 连续 10 次无变化时的空转指数退避计算（15m -> 30m -> 60m）；
 * 4. 日历时间区间精确重叠计算 `(startA < endB && startB < endA)`；
 * 5. 事件去重集合。
 */
class L1DeterministicFilter(
    private val maxStoredLines: Int = STORED_LINES,
    private val maxReportedDiffLines: Int = REPORTED_LINES,
) {
    companion object {
        const val STORED_LINES = 400
        const val REPORTED_LINES = 8
        const val MAX_LINE_CHARS = 300

        private val SCRIPT_STYLE_REGEX = Regex("""(?is)<(script|style)\b[^>]*>.*?</\1>""")
        private val HTML_TAG_REGEX = Regex("""<[^>]+>""")
        private val WHITESPACE_REGEX = Regex("""\s+""")

        /**
         * 移植并增强自 `DesktopWatchtower.swift:84` `_lines(text)`：
         * 剥离 script/style 与 HTML 标签、折叠空白字符、截取最多 400 行（每行最多 300 字符）。
         */
        fun normalizeLines(rawContent: String): List<String> {
            val withoutScripts = SCRIPT_STYLE_REGEX.replace(rawContent, " ")
            val withoutTags = HTML_TAG_REGEX.replace(withoutScripts, "\n")
            val rawLines = withoutTags.split("\r\n", "\r", "\n")
            val out = ArrayList<String>(minOf(rawLines.size, STORED_LINES))
            for (line in rawLines) {
                if (out.size >= STORED_LINES) break
                val collapsed = WHITESPACE_REGEX.replace(line, " ").trim()
                if (collapsed.isNotEmpty()) {
                    out.add(collapsed.take(MAX_LINE_CHARS))
                }
            }
            return out
        }

        /**
         * 计算文本的 SHA-256 十六进制摘要（委托 `:core:native` [AmberNativeBridge]）。
         */
        fun sha256Hex(text: String): String {
            val digest = AmberNativeBridge.sha256(text.toByteArray(StandardCharsets.UTF_8))
                ?: error("SHA-256 unavailable on JVM")
            return digest.joinToString("") { "%02x".format(it) }
        }

        /**
         * 移植自 `DesktopWatchtower.swift:75` `_stableHash(text)` (FNV-1a 32-bit hex)。
         */
        fun fnv1aHex(text: String): String {
            var hash = 2_166_136_261u
            for (ch in text) {
                hash = hash xor ch.code.toUInt()
                hash *= 16_777_619u
            }
            return hash.toString(16)
        }

        /**
         * 根据连续无变化次数计算推荐轮询间隔（分钟）：
         * 连续 10 次无变化从 15m 升至 30m；连续 20 次升至 60m（对齐 `amber-cloud-self-plan.md` §6.2）。
         */
        fun recommendedIntervalMinutes(consecutiveUnchanged: Int): Int =
            when {
                consecutiveUnchanged >= 20 -> 60
                consecutiveUnchanged >= 10 -> 30
                else -> 15
            }

        /**
         * 确定性计算同一天内所有存在时间重叠 `(startA < endB && startB < endA)` 的日程冲突对。
         */
        fun computeCalendarConflicts(
            datePrefix: String,
            events: List<FeishuCalendarEvent>,
        ): List<CalendarConflictPair> {
            data class TimedEvent(
                val event: FeishuCalendarEvent,
                val startMin: Int,
                val endMin: Int,
            )

            val dayEvents = events
                .filter { it.startTime.startsWith(datePrefix) }
                .mapNotNull { ev ->
                    val s = parseMinutes(ev.startTime) ?: return@mapNotNull null
                    val e = parseMinutes(ev.endTime) ?: return@mapNotNull null
                    if (e > s) TimedEvent(ev, s, e) else null
                }
                .sortedWith(compareBy<TimedEvent> { it.startMin }.thenBy { it.endMin }.thenBy { it.event.id })

            val conflicts = mutableListOf<CalendarConflictPair>()
            for (i in dayEvents.indices) {
                for (j in (i + 1) until dayEvents.size) {
                    val a = dayEvents[i]
                    val b = dayEvents[j]
                    // startA < endB && startB < endA
                    if (a.startMin < b.endMin && b.startMin < a.endMin) {
                        conflicts.add(
                            CalendarConflictPair(
                                first = a.event,
                                second = b.event,
                                overlapStartMinutes = maxOf(a.startMin, b.startMin),
                                overlapEndMinutes = minOf(a.endMin, b.endMin),
                            )
                        )
                    }
                }
            }
            return conflicts
        }

        private fun parseMinutes(dateTimeStr: String): Int? {
            if (dateTimeStr.length < 16) return null
            val parts = dateTimeStr.substring(11, 16).split(":")
            if (parts.size != 2) return null
            val h = parts[0].toIntOrNull() ?: return null
            val m = parts[1].toIntOrNull() ?: return null
            return h * 60 + m
        }
    }

    private val watchtowerSnapshots = LinkedHashMap<String, WatchtowerPageSnapshot>()
    private val reportedConflictSignatures = LinkedHashSet<String>()
    private val processedDeduplicationKeys = LinkedHashSet<String>()

    @Synchronized
    fun getWatchtowerSnapshot(url: String): WatchtowerPageSnapshot? = watchtowerSnapshots[url.trim()]

    @Synchronized
    fun evaluate(signal: ProactiveTriggerSignal): L1Outcome {
        return when (signal) {
            is ProactiveTriggerSignal.WatchtowerPageSignal -> evaluateWatchtower(signal)
            is ProactiveTriggerSignal.CalendarSnapshotSignal -> evaluateCalendar(signal)
            is ProactiveTriggerSignal.ClockCronSignal -> evaluateClockCron(signal)
            is ProactiveTriggerSignal.EdgeNodeSensorSignal -> evaluateEdgeNode(signal)
            is ProactiveTriggerSignal.MemoryCommitmentSignal -> evaluateMemoryCommitment(signal)
            is ProactiveTriggerSignal.TaskLifecycleSignal -> evaluateTaskLifecycle(signal)
        }
    }

    private fun evaluateWatchtower(signal: ProactiveTriggerSignal.WatchtowerPageSignal): L1Outcome {
        val cleanUrl = signal.url.trim()
        require(cleanUrl.isNotEmpty()) { "Watchtower URL 不能为空" }
        val previous = watchtowerSnapshots[cleanUrl]

        // 1. HTTP 304 Not Modified 或 ETag 完全命中 -> 0 Token 直接返回无变化
        if (signal.httpStatusCode == 304 && previous != null) {
            val nextUnchanged = previous.consecutiveUnchanged + 1
            val updated = previous.copy(
                consecutiveUnchanged = nextUnchanged,
                updatedAtEpochMs = signal.timestampEpochMs,
            )
            watchtowerSnapshots[cleanUrl] = updated
            return L1Outcome.DroppedUnchanged(
                reason = "HTTP 304 Not Modified",
                sha256 = previous.sha256,
                etag = previous.etag,
                consecutiveUnchanged = nextUnchanged,
                recommendedPollIntervalMinutes = recommendedIntervalMinutes(nextUnchanged),
            )
        }

        val cleanEtag = signal.etag?.trim()?.takeIf { it.isNotEmpty() }
        if (cleanEtag != null && previous != null && previous.etag == cleanEtag) {
            val nextUnchanged = previous.consecutiveUnchanged + 1
            val updated = previous.copy(
                consecutiveUnchanged = nextUnchanged,
                updatedAtEpochMs = signal.timestampEpochMs,
            )
            watchtowerSnapshots[cleanUrl] = updated
            return L1Outcome.DroppedUnchanged(
                reason = "HTTP ETag 未变化 ($cleanEtag)",
                sha256 = previous.sha256,
                etag = cleanEtag,
                consecutiveUnchanged = nextUnchanged,
                recommendedPollIntervalMinutes = recommendedIntervalMinutes(nextUnchanged),
            )
        }

        // 2. 归一化正文并计算 SHA-256 与 FNV-1a
        val lines = normalizeLines(signal.rawBody).take(maxStoredLines)
        if (lines.isEmpty()) {
            return L1Outcome.DroppedUnchanged(reason = "页面正文为空")
        }
        val normalizedJoined = lines.joinToString("\n")
        val sha256 = sha256Hex(normalizedJoined)
        val fnv = fnv1aHex(normalizedJoined)

        if (previous != null && previous.sha256 == sha256) {
            val nextUnchanged = previous.consecutiveUnchanged + 1
            val updated = previous.copy(
                etag = cleanEtag ?: previous.etag,
                consecutiveUnchanged = nextUnchanged,
                updatedAtEpochMs = signal.timestampEpochMs,
            )
            watchtowerSnapshots[cleanUrl] = updated
            return L1Outcome.DroppedUnchanged(
                reason = "归一化正文 SHA-256 未变化",
                sha256 = sha256,
                etag = updated.etag,
                consecutiveUnchanged = nextUnchanged,
                recommendedPollIntervalMinutes = recommendedIntervalMinutes(nextUnchanged),
            )
        }

        // 3. 提取最多 8 行新增与 8 行删除（与 DesktopWatchtower.swift 保持一致）
        val previousLines = previous?.lines ?: emptyList()
        val previousSet = previousLines.toHashSet()
        val currentSet = lines.toHashSet()

        val added = lines.filter { !previousSet.contains(it) }.take(maxReportedDiffLines)
        val removed = previousLines.filter { !currentSet.contains(it) }.take(maxReportedDiffLines)

        val nextSnapshot = WatchtowerPageSnapshot(
            url = cleanUrl,
            sha256 = sha256,
            fnvHash = fnv,
            etag = cleanEtag,
            lines = lines,
            snapshotsCount = (previous?.snapshotsCount ?: 0) + 1,
            consecutiveUnchanged = 0,
            updatedAtEpochMs = signal.timestampEpochMs,
        )
        watchtowerSnapshots[cleanUrl] = nextSnapshot

        val pageTitle = signal.title.ifBlank { cleanUrl }
        val deltaSummary = buildString {
            append("监控页面异动：$pageTitle ($cleanUrl)\n")
            if (added.isNotEmpty()) {
                append("新增内容 (${added.size} 行)：\n")
                added.forEach { append("+ ").append(it).append('\n') }
            }
            if (removed.isNotEmpty()) {
                append("移除内容 (${removed.size} 行)：\n")
                removed.forEach { append("- ").append(it).append('\n') }
            }
        }.trim()

        return L1Outcome.PassedWithDelta(
            signalId = signal.signalId,
            category = signal.category,
            topicKey = signal.topicKey,
            title = "网页异动提醒 · $pageTitle",
            deltaSummary = deltaSummary,
            sha256 = sha256,
            etag = cleanEtag,
            addedLines = added,
            removedLines = removed,
        )
    }

    private fun evaluateCalendar(signal: ProactiveTriggerSignal.CalendarSnapshotSignal): L1Outcome {
        val allConflicts = computeCalendarConflicts(signal.datePrefix, signal.events)
        if (allConflicts.isEmpty()) {
            return L1Outcome.DroppedUnchanged(reason = "${signal.datePrefix} 无日程时间冲突")
        }

        val newConflicts = allConflicts.filter { pair ->
            val sig = "${signal.datePrefix}:${pair.first.id}@${pair.first.startTime}-${pair.first.endTime}|${pair.second.id}@${pair.second.startTime}-${pair.second.endTime}"
            reportedConflictSignatures.add(sig)
        }
        if (newConflicts.isEmpty()) {
            return L1Outcome.DroppedUnchanged(reason = "${signal.datePrefix} 冲突日程此前已预警过")
        }

        val freeSlots = FeishuCalendarClient.computeFreeSlots(
            datePrefix = signal.datePrefix,
            events = signal.events,
            minDurationMinutes = 30,
        )
        val deltaSummary = buildString {
            append("发现 ${signal.datePrefix} 共有 ${newConflicts.size} 处日程重叠冲突：\n")
            for (conflict in newConflicts) {
                append("• 「${conflict.first.summary}」(${conflict.first.startTime.takeLast(5)}-${conflict.first.endTime.takeLast(5)}) ")
                append("与「${conflict.second.summary}」(${conflict.second.startTime.takeLast(5)}-${conflict.second.endTime.takeLast(5)}) ")
                append("在 ${conflict.overlapRangeText} 重叠\n")
            }
            if (freeSlots.isNotEmpty()) {
                val slotText = freeSlots.take(3).joinToString("、") { "${it.start}-${it.end} (${it.minutes}m)" }
                append("当日可用备选空闲时段：$slotText")
            }
        }.trim()

        return L1Outcome.PassedWithDelta(
            signalId = signal.signalId,
            category = signal.category,
            topicKey = signal.topicKey,
            title = "日程冲突预警 · ${signal.datePrefix}",
            deltaSummary = deltaSummary,
            conflicts = newConflicts,
            suggestedFreeSlots = freeSlots,
        )
    }

    private fun evaluateClockCron(signal: ProactiveTriggerSignal.ClockCronSignal): L1Outcome {
        val dedupKey = "cron:${signal.scheduleName}:${signal.dateString}"
        if (!processedDeduplicationKeys.add(dedupKey)) {
            return L1Outcome.DroppedUnchanged(reason = "定时任务 $dedupKey 今日已执行")
        }
        val dayEvents = signal.calendarEvents.filter { it.startTime.startsWith(signal.dateString) }
        val conflicts = computeCalendarConflicts(signal.dateString, dayEvents)
        val freeSlots = FeishuCalendarClient.computeFreeSlots(signal.dateString, dayEvents)
        val summary = buildString {
            append("早安！今日（${signal.dateString}）共有 ${dayEvents.size} 场日程安排")
            if (conflicts.isNotEmpty()) {
                append("（含 ${conflicts.size} 处时间冲突需留意）")
            }
            append("。\n")
            for (ev in dayEvents.sortedBy { it.startTime }) {
                append("• ${ev.startTime.takeLast(5)}-${ev.endTime.takeLast(5)} ${ev.summary}（${ev.location}）\n")
            }
        }.trim()

        return L1Outcome.PassedWithDelta(
            signalId = signal.signalId,
            category = signal.category,
            topicKey = signal.topicKey,
            title = "晨间 Pulse 简报 · ${signal.dateString}",
            deltaSummary = summary,
            conflicts = conflicts,
            suggestedFreeSlots = freeSlots,
            bypassL2ForScheduledBriefing = true,
        )
    }

    private fun evaluateEdgeNode(signal: ProactiveTriggerSignal.EdgeNodeSensorSignal): L1Outcome {
        val dedupKey = "edge:${signal.nodeId}:${signal.deduplicationKey}"
        if (!processedDeduplicationKeys.add(dedupKey)) {
            return L1Outcome.DroppedUnchanged(reason = "边缘节点事件 $dedupKey 已处理")
        }
        return L1Outcome.PassedWithDelta(
            signalId = signal.signalId,
            category = signal.category,
            topicKey = signal.topicKey,
            title = "设备节点事件 · ${signal.nodeId}",
            deltaSummary = signal.summaryText,
        )
    }

    private fun evaluateMemoryCommitment(signal: ProactiveTriggerSignal.MemoryCommitmentSignal): L1Outcome {
        val dedupKey = "commitment:${signal.memoryId}:${signal.dueDateTime}"
        if (!processedDeduplicationKeys.add(dedupKey)) {
            return L1Outcome.DroppedUnchanged(reason = "承诺到期提醒 $dedupKey 已触发")
        }
        return L1Outcome.PassedWithDelta(
            signalId = signal.signalId,
            category = signal.category,
            topicKey = signal.topicKey,
            title = "待办承诺到期提醒",
            deltaSummary = "到期事项（${signal.dueDateTime}）：${signal.commitmentText}",
        )
    }

    private fun evaluateTaskLifecycle(signal: ProactiveTriggerSignal.TaskLifecycleSignal): L1Outcome {
        val dedupKey = "lifecycle:${signal.taskId}:${signal.lifecycleState}"
        if (!processedDeduplicationKeys.add(dedupKey)) {
            return L1Outcome.DroppedUnchanged(reason = "任务生命周期事件 $dedupKey 已通知")
        }
        return L1Outcome.PassedWithDelta(
            signalId = signal.signalId,
            category = signal.category,
            topicKey = signal.topicKey,
            title = "任务状态提醒 · ${signal.taskId}",
            deltaSummary = signal.detail,
            approvalToolCallId = signal.approvalToolCallId,
        )
    }
}

/**
 * L2 廉价小模型快判输入。
 */
@Serializable
data class L2EvaluationRequest(
    val signalId: String,
    val category: TriggerCategory,
    val topicKey: String,
    val deltaSummary: String,
)

/**
 * L2 廉价小模型快判输出（对齐 `amber-cloud-self-plan.md` §6.2 与 `DesktopBoardWriter.swift:71-91`）。
 */
@Serializable
data class L2NoteworthyScore(
    val noteworthy: Boolean,
    val urgency: Int = 3,
    val importance: Int = 3,
    val actionable: Boolean = true,
    val recommendedChannel: String = "im_direct",
    val summary: String,
) {
    /**
     * 综合评分 $S = \text{urgency} \times \text{importance}$（范围 1..25）。
     */
    val compositeScore: Int
        get() = urgency.coerceIn(1, 5) * importance.coerceIn(1, 5)
}

/**
 * 第二级漏斗（L2）：小模型 `noteworthy` 评分 Provider 接口。
 *
 * 仅定义接口，生产可接 DeepSeek Flash / Haiku，测试使用假实现验证调用次数与过滤逻辑。
 */
fun interface NoteworthyJudgeProvider {
    suspend fun evaluate(request: L2EvaluationRequest): L2NoteworthyScore
}

/**
 * 容错 JSON 解析器（移植并扩展自 `DesktopBoardWriter.parseSummary` `DesktopBoardWriter.swift:85-91`）。
 * 允许模型返回带代码块围栏或前后说明文字的 JSON。
 */
object NoteworthyResponseParser {
    private val json = Json { ignoreUnknownKeys = true }

    fun parse(rawText: String): L2NoteworthyScore? {
        val openIdx = rawText.indexOf('{')
        val closeIdx = rawText.lastIndexOf('}')
        if (openIdx < 0 || closeIdx <= openIdx) return null
        val slice = rawText.substring(openIdx, closeIdx + 1)
        val obj = runCatching { json.parseToJsonElement(slice).jsonObject }.getOrNull() ?: return null
        val summary = obj["summary"]?.jsonPrimitive?.content?.trim().orEmpty()
        if (summary.isEmpty()) return null
        val noteworthy = obj["noteworthy"]?.jsonPrimitive?.booleanOrNull ?: return null
        val urgency = obj["urgency"]?.jsonPrimitive?.intOrNull ?: (if (noteworthy) 4 else 1)
        val importance = obj["importance"]?.jsonPrimitive?.intOrNull ?: (if (noteworthy) 4 else 1)
        val actionable = obj["actionable"]?.jsonPrimitive?.booleanOrNull ?: noteworthy
        val channel = obj["recommended_channel"]?.jsonPrimitive?.content ?: "im_direct"
        return L2NoteworthyScore(
            noteworthy = noteworthy,
            urgency = urgency.coerceIn(1, 5),
            importance = importance.coerceIn(1, 5),
            actionable = actionable,
            recommendedChannel = channel,
            summary = summary.take(80),
        )
    }
}

/**
 * 第三级漏斗（L3）：产出主动触达结构化卡片。
 */
object L3ProactiveCardProducer {
    fun buildCard(
        delta: L1Outcome.PassedWithDelta,
        l2Score: L2NoteworthyScore?,
        extraPulseItems: List<String> = emptyList(),
    ): OutboundCard {
        val headerTemplate = when {
            delta.approvalToolCallId != null -> "amber"
            (l2Score?.compositeScore ?: 15) >= 20 -> "red"
            delta.conflicts.isNotEmpty() -> "amber"
            else -> "wathet"
        }

        val markdown = buildString {
            if (l2Score != null && l2Score.summary.isNotBlank()) {
                append("**摘要**：").append(l2Score.summary).append("\n\n")
            }
            append(delta.deltaSummary)
            if (extraPulseItems.isNotEmpty()) {
                append("\n\n**静默时段 / 后台汇总事项（${extraPulseItems.size} 项）**：\n")
                for (item in extraPulseItems) {
                    append("• ").append(item).append('\n')
                }
            }
            if (delta.approvalToolCallId != null) {
                append("\n\n> 高风险或写操作需在已配对授信 App 前台批准，IM 内仅提供拒绝按钮。")
            }
        }.trim()

        val defaultButtons = if (delta.approvalToolCallId != null) {
            listOf(
                OutboundButton(
                    text = "❌ 拒绝此次操作",
                    actionData = "im_approval:deny:${delta.approvalToolCallId}",
                    style = ButtonStyle.DANGER,
                )
            )
        } else {
            listOf(
                OutboundButton(
                    text = "🔍 展开详情",
                    actionData = "proactive:detail:${delta.signalId}",
                    style = ButtonStyle.PRIMARY,
                ),
                OutboundButton(
                    text = "⏰ 稍后提醒(2h)",
                    actionData = "proactive:snooze_2h:${delta.topicKey}",
                    style = ButtonStyle.DEFAULT,
                ),
                OutboundButton(
                    text = "🔕 减少此类提醒",
                    actionData = "proactive:mute:${delta.topicKey}",
                    style = ButtonStyle.DANGER,
                ),
            )
        }

        val rawCard = OutboundCard(
            title = delta.title,
            markdownBody = markdown,
            headerTemplate = headerTemplate,
            buttons = defaultButtons,
            approvalToolCallId = delta.approvalToolCallId,
            highRisk = true,
        )
        return rawCard.copy(buttons = ImApprovalGate.sanitizeOutboundButtons(rawCard))
    }
}
