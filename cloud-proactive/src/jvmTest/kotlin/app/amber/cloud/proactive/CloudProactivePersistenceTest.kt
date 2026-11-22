package app.amber.cloud.proactive

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.test.runTest
import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class CloudProactivePersistenceTest {
    private val zoneId = ZoneId.of("Asia/Shanghai")

    private fun epochMsAt(year: Int, month: Int, day: Int, hour: Int, minute: Int): Long =
        LocalDateTime.of(year, month, day, hour, minute)
            .atZone(zoneId)
            .toInstant()
            .toEpochMilli()

    @Test
    fun `L1 filter persists watchtower snapshots and dedup keys with 0600 permissions across restart`() = runTest {
        val dir = Files.createTempDirectory("proactive-l1-persist").toFile()
        val l1File = File(dir, "l1-filter.json")
        val nowMs = epochMsAt(2026, 11, 23, 10, 0)

        // First instance establishes watchtower snapshot + dedup keys for new signal types
        val filter1 = L1DeterministicFilter(persistenceFile = l1File)
        val wtFirst = filter1.evaluate(
            ProactiveTriggerSignal.WatchtowerPageSignal(
                signalId = "wt-1",
                url = "https://example.com/status",
                title = "Status Page",
                httpStatusCode = 200,
                etag = "\"v1\"",
                rawBody = "<html><body>All systems operational</body></html>",
                timestampEpochMs = nowMs,
            )
        )
        assertIs<L1Outcome.PassedWithDelta>(wtFirst)

        val prepFirst = filter1.evaluate(
            ProactiveTriggerSignal.UpcomingEventPrepSignal(
                signalId = "ev-1",
                eventSignature = "sig-arch-review",
                eventTitle = "架构评审会",
                startMs = nowMs + 20 * 60_000L,
                endMs = nowMs + 80 * 60_000L,
                minutesUntilStart = 20,
                recalledMemories = listOf("上次评审确认优先完成主动引擎持久化"),
                timestampEpochMs = nowMs,
            )
        )
        assertIs<L1Outcome.PassedWithDelta>(prepFirst)

        val whFirst = filter1.evaluate(
            ProactiveTriggerSignal.WebhookInboundSignal(
                signalId = "wh-1",
                webhookId = "wh_ci",
                webhookName = "GitHub CI",
                deliveryId = "deliv-100",
                signedPayloadHash = "body-hash",
                instruction = "关注构建失败",
                redactedPayload = """{"status":"failed"}""",
                timestampEpochMs = nowMs,
            )
        )
        assertIs<L1Outcome.PassedWithDelta>(whFirst)

        assertTrue(l1File.exists())
        val perms = PosixFilePermissions.toString(Files.getPosixFilePermissions(l1File.toPath()))
        assertEquals("rw-------", perms, "l1-filter.json 必须为 0600 权限")

        // Second instance simulates daemon restart
        val filter2 = L1DeterministicFilter(persistenceFile = l1File)
        assertEquals("\"v1\"", filter2.getWatchtowerSnapshot("https://example.com/status")?.etag)

        val wtUnchanged = filter2.evaluate(
            ProactiveTriggerSignal.WatchtowerPageSignal(
                signalId = "wt-2",
                url = "https://example.com/status",
                title = "Status Page",
                httpStatusCode = 200,
                etag = "\"v2\"",
                rawBody = "<html><body>All   systems operational</body></html>",
                timestampEpochMs = nowMs + 60_000L,
            )
        )
        assertIs<L1Outcome.DroppedUnchanged>(wtUnchanged)

        val prepDup = filter2.evaluate(
            ProactiveTriggerSignal.UpcomingEventPrepSignal(
                signalId = "ev-2",
                eventSignature = "sig-arch-review",
                eventTitle = "架构评审会",
                startMs = nowMs + 20 * 60_000L,
                endMs = nowMs + 80 * 60_000L,
                minutesUntilStart = 18,
                timestampEpochMs = nowMs + 120_000L,
            )
        )
        assertIs<L1Outcome.DroppedUnchanged>(prepDup)

        val whReplay = filter2.evaluate(
            ProactiveTriggerSignal.WebhookInboundSignal(
                signalId = "wh-2",
                webhookId = "wh_ci",
                webhookName = "GitHub CI",
                deliveryId = "deliv-100",
                redactedPayload = """{"status":"failed"}""",
                timestampEpochMs = nowMs + 120_000L,
            )
        )
        assertIs<L1Outcome.DroppedUnchanged>(whReplay)
        val sameSignedBody = ProactiveTriggerSignal.WebhookInboundSignal(
            signalId = "wh-3", webhookId = "wh_ci", webhookName = "GitHub CI",
            deliveryId = "different-id", signedPayloadHash = "body-hash", redactedPayload = """{"status":"failed"}""",
        )
        assertIs<L1Outcome.DroppedUnchanged>(filter2.evaluate(sameSignedBody))
    }

    @Test
    fun `webhook dedup admits one concurrent evaluation and evicts oldest keys`() = runTest {
        val filter = L1DeterministicFilter()
        val signal = ProactiveTriggerSignal.WebhookInboundSignal("s", "w", "CI", "delivery", redactedPayload = "done")
        val results = List(24) { async(Dispatchers.Default) { filter.evaluate(signal) } }.awaitAll()
        assertEquals(1, results.count { it is L1Outcome.PassedWithDelta })
        repeat(5_000) { filter.evaluate(signal.copy(deliveryId = it.toString())) }
        assertFalse(filter.hasProcessedDeduplicationKey("webhook:w:delivery"))
        assertTrue(filter.hasProcessedDeduplicationKey("webhook:w:4999"))
    }

    @Test
    fun `budget cannot rewind after midnight and morning backlog stays bounded across restart`() = runTest {
        val file = File(Files.createTempDirectory("proactive-budget").toFile(), "gate.json")
        val gate = ProactiveRestraintGate(quietHours = QuietHoursConfig(enabled = false),
            budgetConfig = InterruptionBudgetConfig(dailyMaxPushes = 1), persistenceFile = file)
        val yesterday = epochMsAt(2026, 11, 23, 23, 59)
        val today = yesterday + 60_000L
        fun push(id: String, time: Long) = gate.evaluateAndConsume(id, id, 20, true, time)
        assertIs<RestraintVerdict.AllowedToPush>(push("first", yesterday))
        val results = List(12) { async(Dispatchers.Default) { push("next-$it", today) } }.awaitAll()
        assertEquals(1, results.count { it is RestraintVerdict.AllowedToPush })
        assertIs<RestraintVerdict.DeferredByBudget>(push("late", yesterday))
        repeat(105) { assertIs<RestraintVerdict.DeferredByBudget>(push("buffer-$it", today)) }
        val restored = ProactiveRestraintGate(persistenceFile = file)
        assertEquals(0, restored.statusSnapshot(today).remainingToday)
        assertEquals((5..104).map { "buffer-$it" }, restored.drainBufferedPulseItems())
    }

    @Test
    fun `invalid budget cannot partially apply quiet hours`() {
        val gate = ProactiveRestraintGate()
        kotlin.test.assertFailsWith<IllegalArgumentException> {
            gate.updateConfig(quietHoursEnabled = false, dailyMaxPushes = 0)
        }
        assertTrue(gate.quietHours.enabled)
    }

    @Test
    fun `restraint gate persists quiet hours config daily count and buffered pulse items across restart`() = runTest {
        val dir = Files.createTempDirectory("proactive-gate-persist").toFile()
        val gateFile = File(dir, "restraint-gate.json")
        val l2Calls = AtomicInteger(0)

        val gate1 = ProactiveRestraintGate(
            quietHours = QuietHoursConfig(),
            budgetConfig = InterruptionBudgetConfig(dailyMaxPushes = 2, topicCooldownMs = 60_000L),
            persistenceFile = gateFile,
        )
        // Update config via updateConfig and verify persistence
        gate1.updateConfig(quietHoursStart = "22:30", quietHoursEnd = "07:30", dailyMaxPushes = 1)

        val daytimeMs = epochMsAt(2026, 11, 23, 10, 0)
        val quietNightMs = epochMsAt(2026, 11, 23, 22, 45)
        val morningMs = epochMsAt(2026, 11, 24, 8, 0)

        val v1 = gate1.evaluateAndConsume("topic:a", "日间推送 1", score = 16, noteworthy = true, nowEpochMs = daytimeMs)
        assertIs<RestraintVerdict.AllowedToPush>(v1)

        val vQuiet = gate1.evaluateAndConsume("topic:night", "夜间暂存洞察", score = 16, noteworthy = true, nowEpochMs = quietNightMs)
        assertIs<RestraintVerdict.SuppressedQuietHours>(vQuiet)

        val perms = PosixFilePermissions.toString(Files.getPosixFilePermissions(gateFile.toPath()))
        assertEquals("rw-------", perms, "restraint-gate.json 必须为 0600 权限")

        // Simulate restart with fresh gate pointing to same file (even with different constructor defaults)
        val gate2 = ProactiveRestraintGate(
            quietHours = QuietHoursConfig(enabled = false),
            budgetConfig = InterruptionBudgetConfig(dailyMaxPushes = 99),
            persistenceFile = gateFile,
        )
        val snap = gate2.statusSnapshot(daytimeMs)
        assertEquals(true, snap.quietHoursEnabled)
        assertEquals("22:30", snap.quietHoursStart)
        assertEquals("07:30", snap.quietHoursEnd)
        assertEquals(1, snap.dailyMaxPushes)
        assertEquals(1, snap.pushesToday)
        assertEquals(0, snap.remainingToday)
        assertEquals(1, snap.bufferedPulseCount)

        // Same day second push must still be blocked by persisted dailyMaxPushes = 1
        val vBudgetBlocked = gate2.evaluateAndConsume("topic:b", "超出日上限事项", score = 20, noteworthy = true, nowEpochMs = daytimeMs + 120_000L)
        assertIs<RestraintVerdict.DeferredByBudget>(vBudgetBlocked)

        // Morning briefing on next day drains buffered items across restart
        val engine2 = ProactiveEngine(
            l2Judge = NoteworthyJudgeProvider {
                l2Calls.incrementAndGet()
                L2NoteworthyScore(true, 4, 4, summary = "ok")
            },
            restraintGate = gate2,
        )
        val briefRes = engine2.runMorningBriefing(
            dateString = "2026-11-24",
            events = emptyList(),
            targetChatId = "owner",
            channel = null,
            nowEpochMs = morningMs,
        )
        val pushed = assertIs<ProactiveRunResult.PushedAtL3>(briefRes)
        assertTrue(pushed.card.markdownBody.contains("夜间暂存洞察"))
        assertEquals(0, gate2.peekBufferedPulseItems().size)
        assertEquals(0, l2Calls.get())
    }
}
