package app.amber.cloud.proactive

import kotlinx.coroutines.test.runTest
import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ProactiveUrgencyFeedbackTest {
    private val zoneId = ZoneId.of("Asia/Shanghai")

    private fun epochMsAt(year: Int, month: Int, day: Int, hour: Int, minute: Int): Long =
        LocalDateTime.of(year, month, day, hour, minute)
            .atZone(zoneId)
            .toInstant()
            .toEpochMilli()

    @Test
    fun `a failed feedback write is retryable and an older opened card leaves the current card pending`() {
        val dir = Files.createTempDirectory("proactive-gate-write").toFile()
        val file = File(dir, "restraint-gate.json")
        val gate = ProactiveRestraintGate(
            quietHours = QuietHoursConfig(enabled = false),
            budgetConfig = InterruptionBudgetConfig(topicCooldownMs = 0, consecutiveIgnoresForDecay = 1),
            persistenceFile = file,
        )
        val now = epochMsAt(2026, 11, 26, 12, 0)
        Files.createDirectory(file.toPath())
        assertFailsWith<java.io.IOException> {
            gate.applyFeedback("s", "topic", ProactiveFeedbackAction.MUTE_TOPIC, now)
        }
        assertTrue(gate.statusSnapshot(now).mutedTopics.isEmpty())
        Files.delete(file.toPath())
        assertTrue(gate.applyFeedback("s", "topic", ProactiveFeedbackAction.MUTE_TOPIC, now).applied)
        gate.unmuteTopic("topic")

        fun push(id: String, score: Int) = gate.evaluateAndConsume("topic", id, score, true, now, signalId = id)
        assertIs<RestraintVerdict.AllowedToPush>(push("old", 20))
        assertIs<RestraintVerdict.AllowedToPush>(push("current", 20))
        gate.applyFeedback("old", "topic", ProactiveFeedbackAction.OPENED, now)
        assertIs<RestraintVerdict.DroppedLowScore>(push("next", 12))
    }

    @Test
    fun `urgent userRequested penetrates normal budget cooldown quiet hours and degrades after 10 daily pushes`() {
        val gate = ProactiveRestraintGate(
            quietHours = QuietHoursConfig(enabled = true),
            budgetConfig = InterruptionBudgetConfig(dailyMaxPushes = 1, topicCooldownMs = 2 * 3_600_000L),
        )
        val daytimeMs = epochMsAt(2026, 11, 26, 10, 0)
        val quietNightMs = epochMsAt(2026, 11, 26, 23, 30)

        // 先打满普通日预算并触发同一 topic 的冷却
        val normalAllowed = gate.evaluateAndConsume(
            topicKey = "wakeup:wk_hot",
            summary = "普通推送消耗唯一日预算",
            score = 16,
            noteworthy = true,
            nowEpochMs = daytimeMs,
        )
        assertIs<RestraintVerdict.AllowedToPush>(normalAllowed)
        assertEquals(0, normalAllowed.remainingDailyBudget)
        assertEquals(ProactiveUrgency.NORMAL, normalAllowed.urgency)

        // 顺手静音该 topic，确认 userRequested=true 同样可穿透
        gate.applyFeedback("sig_mute_pre", "wakeup:wk_hot", ProactiveFeedbackAction.MUTE_TOPIC, daytimeMs, muteHours = 24)

        // 当日前 10 次 URGENT + userRequested=true 全部放行（穿透预算、topic 冷却、静音、静默时段），且不扣减普通预算
        for (i in 1..10) {
            val nowMs = if (i <= 5) daytimeMs + i * 1_000L else quietNightMs + i * 1_000L
            val verdict = gate.evaluateAndConsume(
                topicKey = "wakeup:wk_hot",
                summary = "用户设定提醒 #$i",
                score = 12,
                noteworthy = true,
                nowEpochMs = nowMs,
                urgency = ProactiveUrgency.URGENT,
                userRequested = true,
            )
            val allowed = assertIs<RestraintVerdict.AllowedToPush>(verdict, "第 $i 次 URGENT 应穿透放行")
            assertEquals(3, allowed.tier)
            assertFalse(allowed.silentDelivery)
            assertEquals(ProactiveUrgency.URGENT, allowed.urgency)
            assertEquals(0, allowed.remainingDailyBudget)
        }
        assertEquals(1, gate.statusSnapshot(daytimeMs).pushesToday, "URGENT 不得扣减普通日预算")

        // 第 11 次降级为 NORMAL：静默时段内按 NORMAL 被静默拦截
        val eleventhQuiet = gate.evaluateAndConsume(
            topicKey = "wakeup:wk_hot",
            summary = "第 11 次静默降级",
            score = 12,
            noteworthy = true,
            nowEpochMs = quietNightMs + 60_000L,
            urgency = ProactiveUrgency.URGENT,
            userRequested = true,
        )
        assertIs<RestraintVerdict.SuppressedQuietHours>(eleventhQuiet)

        // 另建一个仍有普通日预算的 gate 验证白天的第 11 次会降级返回 NORMAL 并消耗普通预算
        val daytimeGate = ProactiveRestraintGate(
            quietHours = QuietHoursConfig(enabled = false),
            budgetConfig = InterruptionBudgetConfig(dailyMaxPushes = 3, topicCooldownMs = 0L),
        )
        repeat(10) { idx ->
            val v = daytimeGate.evaluateAndConsume(
                topicKey = "wakeup:day_$idx",
                summary = "紧急 #$idx",
                score = 12,
                noteworthy = true,
                nowEpochMs = daytimeMs + idx * 1_000L,
                urgency = ProactiveUrgency.URGENT,
                userRequested = true,
            )
            assertEquals(ProactiveUrgency.URGENT, assertIs<RestraintVerdict.AllowedToPush>(v).urgency)
        }
        val eleventhDay = daytimeGate.evaluateAndConsume(
            topicKey = "wakeup:day_10",
            summary = "第 11 次白天降级",
            score = 12,
            noteworthy = true,
            nowEpochMs = daytimeMs + 20_000L,
            urgency = ProactiveUrgency.URGENT,
            userRequested = true,
        )
        val degradedAllowed = assertIs<RestraintVerdict.AllowedToPush>(eleventhDay)
        assertEquals(ProactiveUrgency.NORMAL, degradedAllowed.urgency)
        assertEquals(1, degradedAllowed.tier)
        assertTrue(degradedAllowed.silentDelivery)
        assertEquals(1, daytimeGate.statusSnapshot(daytimeMs).pushesToday)

        // 跨天后紧急推送计数按本地日期重置
        val nextDayMs = epochMsAt(2026, 11, 27, 9, 0)
        val nextDayUrgent = daytimeGate.evaluateAndConsume(
            topicKey = "wakeup:next_day",
            summary = "次日紧急提醒",
            score = 12,
            noteworthy = true,
            nowEpochMs = nextDayMs,
            urgency = ProactiveUrgency.URGENT,
            userRequested = true,
        )
        assertEquals(ProactiveUrgency.URGENT, assertIs<RestraintVerdict.AllowedToPush>(nextDayUrgent).urgency)
    }

    @Test
    fun `system urgent without userRequested is buffered during quiet hours and blocked when topic muted`() {
        val gate = ProactiveRestraintGate(
            quietHours = QuietHoursConfig(enabled = true),
            budgetConfig = InterruptionBudgetConfig(dailyMaxPushes = 5),
        )
        val quietMs = epochMsAt(2026, 11, 26, 23, 45)
        val quietVerdict = gate.evaluateAndConsume(
            topicKey = "sys:alert",
            summary = "系统紧急告警夜间触发",
            score = 20,
            noteworthy = true,
            nowEpochMs = quietMs,
            urgency = ProactiveUrgency.URGENT,
            userRequested = false,
        )
        val suppressed = assertIs<RestraintVerdict.SuppressedQuietHours>(quietVerdict)
        assertTrue(suppressed.bufferedForMorningBriefing)
        assertEquals(listOf("系统紧急告警夜间触发"), gate.peekBufferedPulseItems())

        // 白天被静音的话题，非 userRequested 的 URGENT 也不穿透
        val dayMs = epochMsAt(2026, 11, 27, 10, 0)
        gate.applyFeedback("sig_m1", "sys:alert", ProactiveFeedbackAction.MUTE_TOPIC, dayMs, muteHours = 24)
        val mutedVerdict = gate.evaluateAndConsume(
            topicKey = "sys:alert",
            summary = "被静音的系统告警",
            score = 25,
            noteworthy = true,
            nowEpochMs = dayMs + 1_000L,
            urgency = ProactiveUrgency.URGENT,
            userRequested = false,
        )
        val deferred = assertIs<RestraintVerdict.DeferredByBudget>(mutedVerdict)
        assertFalse(deferred.bufferedForMorningBriefing)
    }

    @Test
    fun `digest only buffers into pulse without consuming normal daily budget`() {
        val gate = ProactiveRestraintGate(
            quietHours = QuietHoursConfig(enabled = false),
            budgetConfig = InterruptionBudgetConfig(dailyMaxPushes = 2),
        )
        val dayMs = epochMsAt(2026, 11, 26, 14, 0)

        val digestVerdict = gate.evaluateAndConsume(
            topicKey = "watchtower:release",
            summary = "新版本 v2.1.0 发布摘要",
            score = 20,
            noteworthy = true,
            nowEpochMs = dayMs,
            urgency = ProactiveUrgency.DIGEST,
        )
        val deferred = assertIs<RestraintVerdict.DeferredByBudget>(digestVerdict)
        assertEquals("已转入 Pulse 汇总", deferred.reason)
        assertTrue(deferred.bufferedForMorningBriefing)
        assertEquals(listOf("新版本 v2.1.0 发布摘要"), gate.peekBufferedPulseItems())

        val snap = gate.statusSnapshot(dayMs)
        assertEquals(0, snap.pushesToday)
        assertEquals(2, snap.remainingToday)
        assertEquals(1, snap.bufferedPulseCount)
    }

    @Test
    fun `applyFeedback deduplicates idempotently decays after 3 distinct dismisses and persists across restart`() {
        val dir = Files.createTempDirectory("proactive-feedback-persist").toFile()
        val gateFile = File(dir, "restraint-gate.json")
        val dayMs = epochMsAt(2026, 11, 26, 11, 0)

        val gate1 = ProactiveRestraintGate(
            quietHours = QuietHoursConfig(enabled = false),
            budgetConfig = InterruptionBudgetConfig(dailyMaxPushes = 10, topicCooldownMs = 0L),
            persistenceFile = gateFile,
        )

        // 同一 signalId 重复 dismiss 必须幂等（只记 1 次）
        assertTrue(gate1.applyFeedback("sig_1", "topic:news", ProactiveFeedbackAction.DISMISS, dayMs).applied)
        assertFalse(gate1.applyFeedback("sig_1", "topic:news", ProactiveFeedbackAction.DISMISS, dayMs + 1_000L).applied)
        assertFalse(gate1.applyFeedback("sig_1", "topic:news", ProactiveFeedbackAction.DISMISS, dayMs + 2_000L).applied)

        // SNOOZE 记录去重但不增加忽略计数
        assertTrue(gate1.applyFeedback("sig_1", "topic:news", ProactiveFeedbackAction.SNOOZE, dayMs + 3_000L).applied)
        assertFalse(gate1.applyFeedback("sig_1", "topic:news", ProactiveFeedbackAction.SNOOZE, dayMs + 4_000L).applied)

        // 此时仅 1 次忽略，score=12 仍可通过（默认阈值 9）
        assertIs<RestraintVerdict.AllowedToPush>(
            gate1.evaluateAndConsume("topic:news", "新闻 1", score = 12, noteworthy = true, nowEpochMs = dayMs + 5_000L)
        )

        // 再来 2 次不同 signalId 的 dismiss -> 累计 3 次触发衰减阈值（18）
        assertTrue(gate1.applyFeedback("sig_2", "topic:news", ProactiveFeedbackAction.DISMISS, dayMs + 6_000L).applied)
        assertTrue(gate1.applyFeedback("sig_3", "topic:news", ProactiveFeedbackAction.DISMISS, dayMs + 7_000L).applied)

        val perms = PosixFilePermissions.toString(Files.getPosixFilePermissions(gateFile.toPath()))
        assertEquals("rw-------", perms)

        // 重启从磁盘重载后，去重键与 3 次忽略计数必须保留
        val gate2 = ProactiveRestraintGate(
            quietHours = QuietHoursConfig(enabled = false),
            budgetConfig = InterruptionBudgetConfig(dailyMaxPushes = 10, topicCooldownMs = 0L),
            persistenceFile = gateFile,
        )
        assertFalse(gate2.applyFeedback("sig_3", "topic:news", ProactiveFeedbackAction.DISMISS, dayMs + 8_000L).applied)

        val decayedDrop = gate2.evaluateAndConsume(
            topicKey = "topic:news",
            summary = "新闻 2",
            score = 15,
            noteworthy = true,
            nowEpochMs = dayMs + 9_000L,
        )
        val dropped = assertIs<RestraintVerdict.DroppedLowScore>(decayedDrop)
        assertEquals(18, dropped.requiredScore)

        // OPENED 重置忽略计数（恢复为默认阈值 9）
        assertTrue(gate2.applyFeedback("sig_4", "topic:news", ProactiveFeedbackAction.OPENED, dayMs + 10_000L).applied)
        assertIs<RestraintVerdict.AllowedToPush>(
            gate2.evaluateAndConsume("topic:news", "新闻 3", score = 12, noteworthy = true, nowEpochMs = dayMs + 11_000L)
        )
    }

    @Test
    fun `muteTopic unmuteTopic snapshot filters expired items and pulse config validates HHmm`() {
        val dir = Files.createTempDirectory("proactive-mute-config").toFile()
        val gateFile = File(dir, "restraint-gate.json")
        val t0 = epochMsAt(2026, 11, 26, 10, 0)
        val gate = ProactiveRestraintGate(persistenceFile = gateFile)

        val mute1 = gate.applyFeedback("sig_m1", "topic:short", ProactiveFeedbackAction.MUTE_TOPIC, t0, muteHours = 1)
        assertTrue(mute1.applied)
        assertEquals(t0 + 3_600_000L, mute1.mutedUntilEpochMs)

        // 重复 mute 同一 signalId 返回 applied=false
        val dupMute = gate.applyFeedback("sig_m1", "topic:short", ProactiveFeedbackAction.MUTE_TOPIC, t0 + 1_000L, muteHours = 24)
        assertFalse(dupMute.applied)
        assertNull(dupMute.mutedUntilEpochMs)

        val mute2 = gate.applyFeedback("sig_m2", "topic:long", ProactiveFeedbackAction.MUTE_TOPIC, t0, muteHours = 24)
        assertTrue(mute2.applied)
        assertEquals(t0 + 24 * 3_600_000L, mute2.mutedUntilEpochMs)

        // t0 + 30min 两个都未过期
        val snapActive = gate.statusSnapshot(t0 + 30 * 60_000L)
        assertEquals(2, snapActive.mutedTopicsCount)
        assertEquals(listOf("topic:long", "topic:short"), snapActive.mutedTopics.map { it.topicKey })

        // t0 + 2h：topic:short 已过期，仅保留 topic:long
        val snapExpiredFiltered = gate.statusSnapshot(t0 + 2 * 3_600_000L)
        assertEquals(1, snapExpiredFiltered.mutedTopicsCount)
        assertEquals(listOf("topic:long"), snapExpiredFiltered.mutedTopics.map { it.topicKey })

        // 取消静音并持久化
        gate.unmuteTopic("topic:long")
        val reloaded = ProactiveRestraintGate(persistenceFile = gateFile)
        val snapAfterUnmute = reloaded.statusSnapshot(t0 + 2 * 3_600_000L)
        assertEquals(0, snapAfterUnmute.mutedTopicsCount)
        assertTrue(snapAfterUnmute.mutedTopics.isEmpty())

        // updateConfig 校验 HH:mm 且原子更新 pulse/commitment 字段
        assertFailsWith<IllegalArgumentException> {
            reloaded.updateConfig(pulseEnabled = false, pulseTime = "8:30")
        }
        assertFailsWith<IllegalArgumentException> {
            reloaded.updateConfig(pulseTime = "25:00")
        }
        assertTrue(reloaded.statusSnapshot(t0).pulseEnabled, "非法 pulseTime 不得部分提交 pulseEnabled")

        val updated = reloaded.updateConfig(
            pulseEnabled = false,
            pulseTime = "09:15",
            commitmentExtractionEnabled = false,
        )
        assertFalse(updated.pulseEnabled)
        assertEquals("09:15", updated.pulseTime)
        assertFalse(updated.commitmentExtractionEnabled)

        val reloadedAgain = ProactiveRestraintGate(persistenceFile = gateFile)
        val persistedSnap = reloadedAgain.statusSnapshot(t0)
        assertFalse(persistedSnap.pulseEnabled)
        assertEquals("09:15", persistedSnap.pulseTime)
        assertFalse(persistedSnap.commitmentExtractionEnabled)
    }

    @Test
    fun `selfWakeup skips L2 deduplicates and never drains buffered pulse items`() = runTest {
        val l2Calls = AtomicInteger(0)
        val gate = ProactiveRestraintGate(
            quietHours = QuietHoursConfig(enabled = true),
            budgetConfig = InterruptionBudgetConfig(dailyMaxPushes = 1),
        )
        val engine = ProactiveEngine(
            l2Judge = NoteworthyJudgeProvider {
                l2Calls.incrementAndGet()
                L2NoteworthyScore(true, 4, 4, summary = "should not be called")
            },
            restraintGate = gate,
        )

        // 先往晨报缓冲里塞一条夜间事项
        val quietMs = epochMsAt(2026, 11, 26, 23, 20)
        gate.evaluateAndConsume("watchtower:pricing", "昨晚静默暂存事项", score = 16, noteworthy = true, nowEpochMs = quietMs)
        assertEquals(1, gate.peekBufferedPulseItems().size)

        // 触发 userRequested=true 的 SelfWakeupSignal（静默时段内）
        val wakeupSignal = ProactiveTriggerSignal.SelfWakeupSignal(
            signalId = "wk_abc1234567_29927000",
            wakeupId = "wk_abc1234567",
            kind = "snooze",
            title = "回看部署状态",
            detail = "请确认发布流水线是否完成",
            checkPrompt = "检查发布流水线状态并汇报",
            userRequested = true,
            originSignalId = "wt_origin01",
            timestampEpochMs = quietMs + 60_000L,
        )
        assertEquals(TriggerCategory.CLOCK_CRON, wakeupSignal.category)

        val firstRes = engine.processSignal(wakeupSignal, targetChatId = "owner", nowOverrideMs = quietMs + 60_000L)
        val pushed = assertIs<ProactiveRunResult.PushedAtL3>(firstRes)
        assertEquals(0, l2Calls.get(), "SelfWakeupSignal 必须跳过 L2 模型调用")
        assertNull(pushed.l2Score)
        assertEquals(ProactiveUrgency.URGENT, pushed.restraintVerdict.urgency)
        assertEquals(3, pushed.restraintVerdict.tier)
        assertFalse(pushed.restraintVerdict.silentDelivery)
        assertEquals("wk_abc1234567", pushed.l1Delta.wakeupId)
        assertEquals("wt_origin01", pushed.l1Delta.originSignalId)
        assertEquals("检查发布流水线状态并汇报", pushed.l1Delta.checkPrompt)
        assertTrue(pushed.l1Delta.skipL2)
        assertTrue(pushed.l1Delta.userRequested)

        // 关键不变量：唤醒卡绝不 drain 晨报缓冲，且卡片正文不含缓冲项
        assertEquals(listOf("昨晚静默暂存事项"), gate.peekBufferedPulseItems())
        assertFalse(pushed.card.markdownBody.contains("昨晚静默暂存事项"))

        // 重复投递同一 wakeup 必须在 L1 被去重拦截（0 模型调用）
        val dupRes = engine.processSignal(wakeupSignal, targetChatId = "owner", nowOverrideMs = quietMs + 120_000L)
        assertIs<ProactiveRunResult.DroppedAtL1>(dupRes)
        assertEquals(0, l2Calls.get())

        // 非 userRequested 的 commitment 唤醒走 NORMAL（固定分 12 -> tier 1 被动推送，仍跳过 L2）
        val daytimeMs = epochMsAt(2026, 11, 27, 10, 0)
        val commitSignal = ProactiveTriggerSignal.SelfWakeupSignal(
            signalId = "wk_commit001_29927640",
            wakeupId = "wk_commit001",
            kind = "commitment",
            title = "周五发周报",
            detail = "提醒发送本周研发进度周报",
            userRequested = false,
            timestampEpochMs = daytimeMs,
        )
        assertEquals(TriggerCategory.MEMORY_COMMITMENT, commitSignal.category)
        val commitRes = engine.processSignal(commitSignal, targetChatId = "owner", nowOverrideMs = daytimeMs)
        val commitPushed = assertIs<ProactiveRunResult.PushedAtL3>(commitRes)
        assertEquals(0, l2Calls.get())
        assertEquals(ProactiveUrgency.NORMAL, commitPushed.restraintVerdict.urgency)
        assertEquals(1, commitPushed.restraintVerdict.tier)
        assertTrue(commitPushed.restraintVerdict.silentDelivery)
        assertEquals(listOf("昨晚静默暂存事项"), gate.peekBufferedPulseItems())
    }

    @Test
    fun `non-approval L3 card buttons use pa prefix within 64 bytes and drop oversized buttons`() = runTest {
        val normalDelta = L1Outcome.PassedWithDelta(
            signalId = "wt_1234abcd",
            category = TriggerCategory.EXTERNAL_SENSOR,
            topicKey = "watchtower:https://example.com/very/long/url/that/used/to/exceed/telegram/64/bytes/limit",
            title = "网页异动提醒",
            deltaSummary = "价格更新",
        )
        val normalCard = L3ProactiveCardProducer.buildCard(normalDelta, null)
        assertEquals(3, normalCard.buttons.size)
        assertEquals(
            listOf(
                "🔍 让 Amber 处理" to "pa:act:wt_1234abcd",
                "⏰ 1 小时后" to "pa:snooze:wt_1234abcd",
                "🔕 减少此类" to "pa:mute:wt_1234abcd",
            ),
            normalCard.buttons.map { it.text to it.actionData },
        )
        for (btn in normalCard.buttons) {
            assertTrue(btn.actionData.startsWith("pa:"))
            assertTrue(btn.actionData.toByteArray(StandardCharsets.UTF_8).size <= 64)
        }

        // 55 字节 signalId：pa:snooze: (10+55=65B) 被丢弃，pa:act: (62B) 与 pa:mute: (63B) 保留
        val borderSignalId = "s".repeat(55)
        val borderCard = L3ProactiveCardProducer.buildCard(normalDelta.copy(signalId = borderSignalId), null)
        assertEquals(
            listOf("pa:act:$borderSignalId", "pa:mute:$borderSignalId"),
            borderCard.buttons.map { it.actionData },
        )
        assertTrue(borderCard.buttons.all { it.actionData.toByteArray(StandardCharsets.UTF_8).size <= 64 })

        // 60 字节 signalId：所有 pa: 按钮均超 64B，全部丢弃
        val oversizedCard = L3ProactiveCardProducer.buildCard(normalDelta.copy(signalId = "x".repeat(60)), null)
        assertTrue(oversizedCard.buttons.isEmpty())

        // 晨报无日程时输出“今日暂无日程”，不再输出“共有 0 场日程”
        val engine = ProactiveEngine(
            l2Judge = NoteworthyJudgeProvider { error("morning briefing must not call L2") },
            restraintGate = ProactiveRestraintGate(quietHours = QuietHoursConfig(enabled = false)),
        )
        val briefRes = engine.runMorningBriefing(
            dateString = "2026-11-26",
            events = emptyList(),
            targetChatId = "owner",
            nowEpochMs = epochMsAt(2026, 11, 26, 8, 30),
        )
        val pushedBrief = assertIs<ProactiveRunResult.PushedAtL3>(briefRes)
        assertTrue(pushedBrief.card.markdownBody.contains("今日暂无日程"))
        assertFalse(pushedBrief.card.markdownBody.contains("共有 0 场日程"))
    }

    @Test
    fun `legacy restraint-gate json without new fields loads cleanly with defaults`() {
        val dir = Files.createTempDirectory("proactive-legacy-json").toFile()
        val gateFile = File(dir, "restraint-gate.json")
        val dayMs = epochMsAt(2026, 11, 26, 10, 0)
        val futureMuteMs = dayMs + 2 * 3_600_000L

        val legacyJson = """
            {
              "version": 1,
              "quietHoursEnabled": true,
              "quietHoursStart": "22:00",
              "quietHoursEnd": "07:00",
              "zoneId": "Asia/Shanghai",
              "dailyMaxPushes": 4,
              "currentDay": "2026-11-26",
              "pushesToday": 2,
              "lastGlobalPushEpochMs": $dayMs,
              "lastPushByTopic": {"topic:old": $dayMs},
              "consecutiveIgnoresByTopic": {"topic:ignored": 3},
              "mutedUntilByTopic": {"topic:muted": $futureMuteMs},
              "bufferedPulseItems": ["旧版本暂存项"]
            }
        """.trimIndent()
        gateFile.writeText(legacyJson, StandardCharsets.UTF_8)

        val gate = ProactiveRestraintGate(persistenceFile = gateFile)
        val snap = gate.statusSnapshot(dayMs)
        assertEquals(true, snap.quietHoursEnabled)
        assertEquals("22:00", snap.quietHoursStart)
        assertEquals("07:00", snap.quietHoursEnd)
        assertEquals(4, snap.dailyMaxPushes)
        assertEquals(2, snap.pushesToday)
        assertEquals(2, snap.remainingToday)
        assertEquals(1, snap.bufferedPulseCount)
        assertEquals(1, snap.mutedTopicsCount)
        assertEquals(listOf(MutedTopicDto("topic:muted", futureMuteMs)), snap.mutedTopics)

        // 新增字段默认加载
        assertEquals(true, snap.pulseEnabled)
        assertEquals("08:30", snap.pulseTime)
        assertEquals(true, snap.commitmentExtractionEnabled)
        assertEquals(listOf("旧版本暂存项"), gate.peekBufferedPulseItems())

        // 旧记录中的连续忽略计数与新 URGENT 计数均可正常工作
        val dropped = gate.evaluateAndConsume("topic:ignored", "低分", score = 15, noteworthy = true, nowEpochMs = dayMs + 1_000L)
        assertEquals(18, assertIs<RestraintVerdict.DroppedLowScore>(dropped).requiredScore)

        val urgent = gate.evaluateAndConsume(
            topicKey = "wakeup:fresh",
            summary = "升级后首次紧急提醒",
            score = 12,
            noteworthy = true,
            nowEpochMs = dayMs + 2_000L,
            urgency = ProactiveUrgency.URGENT,
            userRequested = true,
        )
        assertNotNull(assertIs<RestraintVerdict.AllowedToPush>(urgent))
    }

    @Test
    fun `watchtowerPageSignal with digest true routes as DIGEST urgency buffering into pulse without consuming daily budget`() = runTest {
        val gate = ProactiveRestraintGate(
            quietHours = QuietHoursConfig(enabled = false),
            budgetConfig = InterruptionBudgetConfig(dailyMaxPushes = 3, topicCooldownMs = 0L),
        )
        val engine = ProactiveEngine(
            l2Judge = NoteworthyJudgeProvider { req ->
                L2NoteworthyScore(
                    noteworthy = true,
                    urgency = 4,
                    importance = 4,
                    summary = "汇总摘要：${req.topicKey}",
                )
            },
            restraintGate = gate,
        )
        val dayMs = epochMsAt(2026, 11, 26, 14, 0)

        val digestSignal = ProactiveTriggerSignal.WatchtowerPageSignal(
            signalId = "wt_digest_1",
            url = "https://github.com/amber/demo/releases.atom",
            title = "Amber Demo Releases",
            httpStatusCode = 200,
            rawBody = "<feed><entry><title>v3.0.0</title></entry></feed>",
            topicKey = "watchtower:mon_digest",
            timestampEpochMs = dayMs,
            digest = true,
        )
        val digestResult = engine.processSignal(digestSignal, targetChatId = "owner", nowOverrideMs = dayMs)
        val suppressed = assertIs<ProactiveRunResult.SuppressedAtGate>(digestResult)
        assertEquals(ProactiveUrgency.DIGEST, suppressed.l1Delta.urgency)
        val deferred = assertIs<RestraintVerdict.DeferredByBudget>(suppressed.restraintVerdict)
        assertEquals("已转入 Pulse 汇总", deferred.reason)
        assertTrue(deferred.bufferedForMorningBriefing)

        val snap = gate.statusSnapshot(dayMs)
        assertEquals(0, snap.pushesToday, "DIGEST 不得扣减普通日预算")
        assertEquals(3, snap.remainingToday)
        assertEquals(1, snap.bufferedPulseCount)
        assertEquals(listOf("汇总摘要：watchtower:mon_digest"), gate.peekBufferedPulseItems())
        assertEquals(0, engine.metrics().pushedCount)
        assertEquals(0, engine.metrics().l3CardsProducedCount)

        // 默认 digest = false 的 WatchtowerPageSignal 保持 NORMAL 并即时推送
        val immediateSignal = ProactiveTriggerSignal.WatchtowerPageSignal(
            signalId = "wt_imm_1",
            url = "https://example.com/status",
            title = "Status Page",
            httpStatusCode = 200,
            rawBody = "<html><body>Incident resolved</body></html>",
            topicKey = "watchtower:mon_imm",
            timestampEpochMs = dayMs + 60_000L,
        )
        val immediateResult = engine.processSignal(immediateSignal, targetChatId = "owner", nowOverrideMs = dayMs + 60_000L)
        val pushed = assertIs<ProactiveRunResult.PushedAtL3>(immediateResult)
        assertEquals(ProactiveUrgency.NORMAL, pushed.l1Delta.urgency)
        assertEquals(1, gate.statusSnapshot(dayMs + 60_000L).pushesToday)
    }

    @Test
    fun `implicit ignore accumulates unread same-topic pushes decays on threshold persists and respects feedback and userRequested urgent`() {
        val dir = Files.createTempDirectory("proactive-implicit-ignore").toFile()
        val gateFile = File(dir, "restraint-gate.json")
        val t0 = epochMsAt(2026, 11, 26, 10, 0)

        val gate1 = ProactiveRestraintGate(
            quietHours = QuietHoursConfig(enabled = false),
            budgetConfig = InterruptionBudgetConfig(dailyMaxPushes = 20, topicCooldownMs = 0L),
            persistenceFile = gateFile,
        )

        // 1. 同一 topic 连续推送第 1、2、3 次且均无反馈：第 1、2、3 次放行（累计 2 次未读忽略，pending=sig_3）
        assertIs<RestraintVerdict.AllowedToPush>(
            gate1.evaluateAndConsume("topic:blog", "文章 1", score = 12, noteworthy = true, nowEpochMs = t0, signalId = "sig_1")
        )
        assertIs<RestraintVerdict.AllowedToPush>(
            gate1.evaluateAndConsume("topic:blog", "文章 2", score = 12, noteworthy = true, nowEpochMs = t0 + 1_000L, signalId = "sig_2")
        )
        assertIs<RestraintVerdict.AllowedToPush>(
            gate1.evaluateAndConsume("topic:blog", "文章 3", score = 12, noteworthy = true, nowEpochMs = t0 + 2_000L, signalId = "sig_3")
        )

        val perms = PosixFilePermissions.toString(Files.getPosixFilePermissions(gateFile.toPath()))
        assertEquals("rw-------", perms)

        // 2. 重启从磁盘重载 pendingFeedbackByTopic 后，第 4 次推送结算 sig_3 未读 -> 累计 3 次忽略 -> 触发衰减阈值 18
        val gate2 = ProactiveRestraintGate(
            quietHours = QuietHoursConfig(enabled = false),
            budgetConfig = InterruptionBudgetConfig(dailyMaxPushes = 20, topicCooldownMs = 0L),
            persistenceFile = gateFile,
        )
        val fourthVerdict = gate2.evaluateAndConsume(
            topicKey = "topic:blog",
            summary = "文章 4",
            score = 12,
            noteworthy = true,
            nowEpochMs = t0 + 3_000L,
            signalId = "sig_4",
        )
        val dropped = assertIs<RestraintVerdict.DroppedLowScore>(fourthVerdict)
        assertEquals(18, dropped.requiredScore)
        assertTrue(gate2.peekBufferedPulseItems().contains("文章 4"))

        // 高分（>= 18）即使已衰减仍可通过
        assertIs<RestraintVerdict.AllowedToPush>(
            gate2.evaluateAndConsume("topic:blog", "重大更新", score = 20, noteworthy = true, nowEpochMs = t0 + 4_000L, signalId = "sig_5")
        )

        // 3. 中途调用 applyFeedback（OPENED / REPLIED / SNOOZE）清除 pendingFeedbackByTopic，不累计隐式忽略
        assertIs<RestraintVerdict.AllowedToPush>(
            gate2.evaluateAndConsume("topic:active", "提醒 1", score = 12, noteworthy = true, nowEpochMs = t0 + 10_000L, signalId = "act_1")
        )
        assertTrue(gate2.applyFeedback("act_1", "topic:active", ProactiveFeedbackAction.SNOOZE, t0 + 11_000L).applied)

        assertIs<RestraintVerdict.AllowedToPush>(
            gate2.evaluateAndConsume("topic:active", "提醒 2", score = 12, noteworthy = true, nowEpochMs = t0 + 12_000L, signalId = "act_2")
        )
        assertTrue(gate2.applyFeedback("act_2", "topic:active", ProactiveFeedbackAction.OPENED, t0 + 13_000L).applied)

        assertIs<RestraintVerdict.AllowedToPush>(
            gate2.evaluateAndConsume("topic:active", "提醒 3", score = 12, noteworthy = true, nowEpochMs = t0 + 14_000L, signalId = "act_3")
        )
        assertTrue(gate2.applyFeedback("act_3", "topic:active", ProactiveFeedbackAction.REPLIED, t0 + 15_000L).applied)

        assertIs<RestraintVerdict.AllowedToPush>(
            gate2.evaluateAndConsume("topic:active", "提醒 4", score = 12, noteworthy = true, nowEpochMs = t0 + 16_000L, signalId = "act_4")
        )

        // DISMISS 显式计 1 次忽略并清除 pending，下一次推送不应对同一张卡双重计数
        assertIs<RestraintVerdict.AllowedToPush>(
            gate2.evaluateAndConsume("topic:dismiss_once", "条目 1", score = 12, noteworthy = true, nowEpochMs = t0 + 20_000L, signalId = "dis_1")
        )
        assertTrue(gate2.applyFeedback("dis_1", "topic:dismiss_once", ProactiveFeedbackAction.DISMISS, t0 + 21_000L).applied)
        assertIs<RestraintVerdict.AllowedToPush>(
            gate2.evaluateAndConsume("topic:dismiss_once", "条目 2", score = 12, noteworthy = true, nowEpochMs = t0 + 22_000L, signalId = "dis_2")
        )
        // 若 dis_1 被误双重计数，此处 dis_3 就会变成第 3 次而衰减；正确情况下此处应为第 2 次忽略，仍放行
        assertIs<RestraintVerdict.AllowedToPush>(
            gate2.evaluateAndConsume("topic:dismiss_once", "条目 3", score = 12, noteworthy = true, nowEpochMs = t0 + 23_000L, signalId = "dis_3")
        )

        // 4. userRequested=true 的 URGENT 唤醒不参与隐式忽略（既不结算前一张未读，也不写入 pending）
        assertIs<RestraintVerdict.AllowedToPush>(
            gate2.evaluateAndConsume("wakeup:user_timer", "普通通知 1", score = 12, noteworthy = true, nowEpochMs = t0 + 30_000L, signalId = "norm_1")
        )
        repeat(4) { idx ->
            val u = gate2.evaluateAndConsume(
                topicKey = "wakeup:user_timer",
                summary = "用户定时提醒 #$idx",
                score = 12,
                noteworthy = true,
                nowEpochMs = t0 + 31_000L + idx * 1_000L,
                urgency = ProactiveUrgency.URGENT,
                userRequested = true,
                signalId = "wk_urgent_$idx",
            )
            assertEquals(ProactiveUrgency.URGENT, assertIs<RestraintVerdict.AllowedToPush>(u).urgency)
        }
        // 后续普通通知仅结算 norm_1 这 1 次忽略，绝不因 4 次 userRequested URGENT 衰减
        assertIs<RestraintVerdict.AllowedToPush>(
            gate2.evaluateAndConsume("wakeup:user_timer", "普通通知 2", score = 12, noteworthy = true, nowEpochMs = t0 + 40_000L, signalId = "norm_2")
        )
    }
}
