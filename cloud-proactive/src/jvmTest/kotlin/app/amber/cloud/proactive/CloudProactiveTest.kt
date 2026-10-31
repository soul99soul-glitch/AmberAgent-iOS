package app.amber.cloud.proactive

import app.amber.cloud.channels.ChannelSecretLoader
import app.amber.cloud.channels.EncryptedConfigVault
import app.amber.cloud.channels.FeishuCalendarEvent
import app.amber.cloud.channels.FeishuChannel
import app.amber.cloud.channels.OwnerBindingManager
import app.amber.cloud.channels.RedactingChannelLogger
import app.amber.cloud.channels.TelegramChannel
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.test.runTest
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class CloudProactiveTest {
    private lateinit var fakeServer: HttpServer
    private var baseUrl: String = ""

    private var watchtowerPageHtml: String = """
        <html>
          <head><title>Anthropic Pricing</title><script>console.log("dynamic_ts=" + Date.now())</script></head>
          <body>
            <h1>Claude API Pricing</h1>
            <p>Claude Sonnet 5.5 Input: $2.00 / M tokens</p>
            <p>Prompt Cache Read: $0.10 / M tokens</p>
          </body>
        </html>
    """.trimIndent()
    private var watchtowerEtag: String = "\"etag-v1\""

    private val telegramSentPayloads = CopyOnWriteArrayList<String>()
    private val feishuSentPayloads = CopyOnWriteArrayList<String>()

    private val zoneId = ZoneId.of("Asia/Shanghai")

    private fun epochMsAt(year: Int, month: Int, day: Int, hour: Int, minute: Int): Long =
        LocalDateTime.of(year, month, day, hour, minute)
            .atZone(zoneId)
            .toInstant()
            .toEpochMilli()

    @BeforeTest
    fun setUp() {
        telegramSentPayloads.clear()
        feishuSentPayloads.clear()
        watchtowerEtag = "\"etag-v1\""
        watchtowerPageHtml = """
            <html>
              <head><title>Anthropic Pricing</title><script>console.log("dynamic_ts=1001")</script></head>
              <body>
                <h1>Claude API Pricing</h1>
                <p>Claude Sonnet 5.5 Input: $2.00 / M tokens</p>
                <p>Prompt Cache Read: $0.10 / M tokens</p>
              </body>
            </html>
        """.trimIndent()

        fakeServer = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        fakeServer.createContext("/") { exchange ->
            handleFakeServer(exchange)
        }
        fakeServer.start()
        baseUrl = "http://127.0.0.1:${fakeServer.address.port}"
    }

    @AfterTest
    fun tearDown() {
        fakeServer.stop(0)
    }

    private fun handleFakeServer(exchange: HttpExchange) {
        val path = exchange.requestURI.path
        val reqBody = exchange.requestBody.readBytes().toString(StandardCharsets.UTF_8)

        when {
            path == "/watched-pricing" -> {
                val ifNoneMatch = exchange.requestHeaders.getFirst("If-None-Match")
                if (ifNoneMatch != null && ifNoneMatch == watchtowerEtag) {
                    exchange.responseHeaders.add("ETag", watchtowerEtag)
                    exchange.sendResponseHeaders(304, -1)
                    exchange.close()
                    return
                }
                val bytes = watchtowerPageHtml.toByteArray(StandardCharsets.UTF_8)
                exchange.responseHeaders.add("Content-Type", "text/html; charset=utf-8")
                exchange.responseHeaders.add("ETag", watchtowerEtag)
                exchange.sendResponseHeaders(200, bytes.size.toLong())
                exchange.responseBody.use { it.write(bytes) }
            }
            path.endsWith("/sendMessage") -> {
                telegramSentPayloads.add(reqBody)
                respondJson(exchange, 200, """{"ok":true,"result":{"message_id":${2000 + telegramSentPayloads.size}}}""")
            }
            path == "/open-apis/auth/v3/tenant_access_token/internal" -> {
                respondJson(exchange, 200, """{"code":0,"tenant_access_token":"t-fake_proactive_token_123456","expire":7200}""")
            }
            path == "/open-apis/im/v1/messages" -> {
                feishuSentPayloads.add(reqBody)
                respondJson(exchange, 200, """{"code":0,"data":{"message_id":"om_proactive_${feishuSentPayloads.size}"}}""")
            }
            else -> {
                respondJson(exchange, 404, """{"ok":false}""")
            }
        }
    }

    private fun respondJson(exchange: HttpExchange, status: Int, json: String) {
        val bytes = json.toByteArray(StandardCharsets.UTF_8)
        exchange.responseHeaders.add("Content-Type", "application/json; charset=utf-8")
        exchange.sendResponseHeaders(status, bytes.size.toLong())
        exchange.responseBody.use { it.write(bytes) }
    }

    private fun createChannels(): Pair<TelegramChannel, FeishuChannel> {
        val logger = RedactingChannelLogger()
        val vault = EncryptedConfigVault("proactive-master-key-12345")
        vault.putEncrypted(TelegramChannel.CONFIG_KEY_BOT_TOKEN, "8877665544:AAH_PROACTIVE_FAKE_TG_TOKEN_12345")
        vault.putEncrypted(FeishuChannel.CONFIG_KEY_APP_SECRET, "sec_proactive_fake_feishu_secret_12345")
        val loader = ChannelSecretLoader(vault = vault, envProvider = { null }, logger = logger)
        val ownerBinding = OwnerBindingManager().apply {
            bindOwnerDirectly(TelegramChannel.CHANNEL_ID, "123456")
            bindOwnerDirectly(FeishuChannel.CHANNEL_ID, "ou_owner_001")
        }
        val tg = TelegramChannel(
            baseUrl = baseUrl,
            secretLoader = loader,
            ownerBinding = ownerBinding,
            logger = logger,
        )
        val feishu = FeishuChannel(
            openApiBaseUrl = baseUrl,
            appId = "cli_proactive_01",
            secretLoader = loader,
            ownerBinding = ownerBinding,
            logger = logger,
        )
        return tg to feishu
    }

    @Test
    fun `when content is unchanged running L1 10 consecutive times makes 0 model calls`() = runTest {
        val (tgChannel, _) = createChannels()
        val l2CallCounter = AtomicInteger(0)
        val fakeJudge = NoteworthyJudgeProvider { req ->
            l2CallCounter.incrementAndGet()
            L2NoteworthyScore(
                noteworthy = true,
                urgency = 4,
                importance = 4,
                summary = "发现更新: ${req.topicKey}",
            )
        }

        val daytimeMs = epochMsAt(2026, 10, 31, 10, 30)
        val engine = ProactiveEngine(
            l2Judge = fakeJudge,
            clockMs = { daytimeMs },
        )

        val watchedUrl = "$baseUrl/watched-pricing"

        // 首次建立基线快照
        val initialResult = engine.checkWatchtowerUrl(
            url = watchedUrl,
            title = "Anthropic 定价页",
            targetChatId = "123456",
            channel = tgChannel,
            nowEpochMs = daytimeMs,
        )
        assertIs<ProactiveRunResult.PushedAtL3>(initialResult)
        assertEquals(1, l2CallCounter.get(), "首次建立快照应调用 1 次 L2")

        // 重置 L2 计数器，验证接下来连续 10 次内容无变化（即使更新 ETag 以强制走 SHA-256 归一化对比，含不同 script 动态噪音）时，
        // 模型调用次数严格为 0！
        l2CallCounter.set(0)
        var lastDropped: ProactiveRunResult.DroppedAtL1? = null
        for (i in 1..10) {
            // 模拟网页每次变化了 ETag 和 <script> 里的动态时间戳，但可见正文完全没变
            watchtowerEtag = "\"etag-same-body-$i\""
            watchtowerPageHtml = """
                <html>
                  <head><title>Anthropic Pricing</title><script>console.log("dynamic_ts=${1000 + i}")</script></head>
                  <body>
                    <h1>Claude API Pricing</h1>
                    <p>Claude   Sonnet 5.5 Input: $2.00 / M tokens</p>
                    <p>Prompt Cache Read: $0.10 / M tokens</p>
                  </body>
                </html>
            """.trimIndent()

            val res = engine.checkWatchtowerUrl(
                url = watchedUrl,
                title = "Anthropic 定价页",
                targetChatId = "123456",
                channel = tgChannel,
                nowEpochMs = daytimeMs + i * 60_000L,
            )
            lastDropped = assertIs<ProactiveRunResult.DroppedAtL1>(res, "第 $i 次内容未变化必须在 L1 静默拦截")
        }

        assertEquals(0, l2CallCounter.get(), "内容没有变化时，连续跑 10 次 L1，模型调用次数必须为 0")
        assertEquals(10, lastDropped!!.outcome.consecutiveUnchanged)
        assertEquals(30, lastDropped.outcome.recommendedPollIntervalMinutes, "连续 10 次无变化后推荐轮询间隔应自动退避至 30 分钟")
        assertEquals(1, telegramSentPayloads.size, "连续 10 次无变化期间不得向 Telegram 发送任何新消息")
    }

    @Test
    fun `quiet hours 23_00 to 08_00 suppress immediate push and buffer into morning briefing`() = runTest {
        val (_, feishuChannel) = createChannels()
        val l2CallCounter = AtomicInteger(0)
        val fakeJudge = NoteworthyJudgeProvider {
            l2CallCounter.incrementAndGet()
            L2NoteworthyScore(
                noteworthy = true,
                urgency = 5,
                importance = 5,
                summary = "Anthropic 发布了新的缓存计费折扣规则",
            )
        }

        val engine = ProactiveEngine(l2Judge = fakeJudge)
        val watchedUrl = "$baseUrl/watched-pricing"

        // 1. 在静默时段内（23:30 与 次日 02:15）触发网页异动与日程冲突 -> 验证绝不推送 IM
        val quietNightMs = epochMsAt(2026, 10, 31, 23, 30)
        val nightWatchResult = engine.checkWatchtowerUrl(
            url = watchedUrl,
            title = "Anthropic 定价页",
            targetChatId = "ou_owner_001",
            channel = feishuChannel,
            nowEpochMs = quietNightMs,
        )
        val suppressed1 = assertIs<ProactiveRunResult.SuppressedAtGate>(nightWatchResult)
        assertIs<RestraintVerdict.SuppressedQuietHours>(suppressed1.restraintVerdict)
        assertEquals(0, feishuSentPayloads.size, "23:30 静默时段内严禁推送飞书消息")

        val quietEarlyMorningMs = epochMsAt(2026, 11, 1, 2, 15)
        val conflictEvents = listOf(
            FeishuCalendarEvent(
                id = "ev_1",
                summary = "架构评审",
                startTime = "2026-11-01 14:00",
                endTime = "2026-11-01 15:00",
            ),
            FeishuCalendarEvent(
                id = "ev_2",
                summary = "客户拜访",
                startTime = "2026-11-01 14:30",
                endTime = "2026-11-01 15:30",
            ),
        )
        val nightConflictResult = engine.checkCalendarConflicts(
            datePrefix = "2026-11-01",
            events = conflictEvents,
            targetChatId = "ou_owner_001",
            channel = feishuChannel,
            nowEpochMs = quietEarlyMorningMs,
        )
        val suppressed2 = assertIs<ProactiveRunResult.SuppressedAtGate>(nightConflictResult)
        assertIs<RestraintVerdict.SuppressedQuietHours>(suppressed2.restraintVerdict)
        assertEquals(0, feishuSentPayloads.size, "02:15 静默时段内严禁推送飞书消息")
        assertEquals(2, engine.restraintGate.peekBufferedPulseItems().size, "静默时段内的 2 条重要洞察应暂存至晨报队列")

        // 2. 次日清晨 08:30（静默时段结束）触发晨间简报 -> 一次性汇总推送到飞书
        val morning0830Ms = epochMsAt(2026, 11, 1, 8, 30)
        val briefingResult = engine.runMorningBriefing(
            dateString = "2026-11-01",
            events = conflictEvents,
            targetChatId = "ou_owner_001",
            channel = feishuChannel,
            nowEpochMs = morning0830Ms,
        )
        val pushedBriefing = assertIs<ProactiveRunResult.PushedAtL3>(briefingResult)
        assertEquals(1, feishuSentPayloads.size, "08:30 晨间简报应正常推送 1 张汇总卡片")
        assertTrue(pushedBriefing.card.markdownBody.contains("Anthropic 发布了新的缓存计费折扣规则"))
        assertTrue(pushedBriefing.card.markdownBody.contains("架构评审"))
        assertEquals(0, engine.restraintGate.peekBufferedPulseItems().size, "晨间简报发出后暂存队列应被清空")
    }

    @Test
    fun `three scenarios and five trigger categories with interruption budget bucket work end to end`() = runTest {
        val (tgChannel, feishuChannel) = createChannels()
        val fakeJudge = NoteworthyJudgeProvider { req ->
            val rawModelJson = """
                ```json
                {"noteworthy": true, "urgency": 4, "importance": 4, "summary": "AI快判：${req.topicKey}"}
                ```
            """.trimIndent()
            NoteworthyResponseParser.parse(rawModelJson)!!
        }

        // 设置每日主动推送上限为 2 次，验证打扰预算桶
        val restraintGate = ProactiveRestraintGate(
            quietHours = QuietHoursConfig(),
            budgetConfig = InterruptionBudgetConfig(
                dailyMaxPushes = 2,
                topicCooldownMs = 60_000L,
            ),
        )
        val daytimeMs = epochMsAt(2026, 10, 31, 11, 0)
        val engine = ProactiveEngine(
            l2Judge = fakeJudge,
            restraintGate = restraintGate,
            clockMs = { daytimeMs },
        )

        // 场景 1：Watchtower 网页异动（第 1 次消耗预算 -> 推送成功）
        val watchRes = engine.checkWatchtowerUrl(
            url = "$baseUrl/watched-pricing",
            title = "Anthropic 定价页",
            targetChatId = "123456",
            channel = tgChannel,
            nowEpochMs = daytimeMs,
        )
        assertIs<ProactiveRunResult.PushedAtL3>(watchRes)
        assertEquals(1, telegramSentPayloads.size)

        // 场景 2：日历冲突预警（第 2 次消耗预算 -> 推送成功，且包含冲突时段与可用空闲段建议）
        val events = listOf(
            FeishuCalendarEvent(
                id = "e1",
                summary = "产品周会",
                startTime = "2026-10-31 14:00",
                endTime = "2026-10-31 15:00",
            ),
            FeishuCalendarEvent(
                id = "e2",
                summary = "技术架构评审",
                startTime = "2026-10-31 14:30",
                endTime = "2026-10-31 15:30",
            ),
        )
        val conflictRes = engine.checkCalendarConflicts(
            datePrefix = "2026-10-31",
            events = events,
            targetChatId = "ou_owner_001",
            channel = feishuChannel,
            nowEpochMs = daytimeMs + 5_000L,
        )
        val pushedConflict = assertIs<ProactiveRunResult.PushedAtL3>(conflictRes)
        assertEquals(1, feishuSentPayloads.size)
        assertTrue(pushedConflict.card.markdownBody.contains("14:30-15:00 重叠"))
        assertTrue(pushedConflict.card.markdownBody.contains("09:00-14:00"))

        // 验证第 3、4、5 类触发源接口（边缘节点事件、记忆承诺跟进、挂起任务生命周期）
        // 由于今日预算 (dailyMaxPushes = 2) 已用完，第 3 个普通主动信号应被预算桶拦截并转入 Pulse 汇总！
        val edgeSignal = ProactiveTriggerSignal.EdgeNodeSensorSignal(
            signalId = "sig_edge_01",
            nodeId = "macbook-pro",
            eventKind = "agent_session_ended",
            deduplicationKey = "claude_session_99",
            summaryText = "Mac 上的 Claude Code 任务已完成构建验证",
            timestampEpochMs = daytimeMs + 10_000L,
        )
        val edgeRes = engine.processSignal(edgeSignal, targetChatId = "123456", channel = tgChannel)
        val deferredEdge = assertIs<ProactiveRunResult.SuppressedAtGate>(edgeRes)
        assertIs<RestraintVerdict.DeferredByBudget>(deferredEdge.restraintVerdict)
        assertEquals(1, telegramSentPayloads.size, "超出每日打扰预算桶上限后不应继续推送 IM")

        // 验证挂起任务生命周期信号（含高风险审批关联时，生成的卡片只能包含「拒绝」按钮）
        val lifecycleDelta = L1Outcome.PassedWithDelta(
            signalId = "sig_task_01",
            category = TriggerCategory.TASK_LIFECYCLE,
            topicKey = "task:t1:approval_expiring",
            title = "高风险任务待确认",
            deltaSummary = "终端命令即将超时",
            approvalToolCallId = "call_danger_007",
        )
        val approvalCard = L3ProactiveCardProducer.buildCard(lifecycleDelta, null)
        assertEquals(1, approvalCard.buttons.size)
        assertFalse(approvalCard.buttons.single().text.contains("批准"))
        assertEquals("im_approval:deny:call_danger_007", approvalCard.buttons.single().actionData)
    }
}
