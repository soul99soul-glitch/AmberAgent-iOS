package app.amber.cloud

import app.amber.ai.ui.UIMessage
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.gateway.AgentCentricApi
import app.amber.cloud.gateway.CloudGatewayState
import app.amber.cloud.gateway.PushMessagePayload
import app.amber.cloud.gateway.PushSender
import app.amber.cloud.gateway.configureCloudGateway
import app.amber.cloud.orchestration.CloudPrincipal
import app.amber.cloud.orchestration.ExecutionTargetNode
import app.amber.cloud.proactive.CloudProactiveL2Judge
import app.amber.cloud.proactive.L2EvaluationRequest
import app.amber.cloud.proactive.ProactiveRunResult
import app.amber.cloud.proactive.ProactiveTriggerSignal
import app.amber.cloud.proactive.ProactiveUrlGuard
import app.amber.cloud.proactive.ProactiveWebhookStore
import app.amber.cloud.proactive.RestraintVerdict
import app.amber.cloud.proactive.TriggerCategory
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.runtime.ExecutionScope
import app.amber.cloud.runtime.ToolRiskLevel
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.bearerAuth
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.patch
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.contentType
import io.ktor.utils.io.ByteReadChannel
import io.ktor.http.headersOf
import io.ktor.server.testing.testApplication
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import java.net.InetAddress
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class CloudProactiveCombo1Test {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val zoneId = ZoneId.of("Asia/Shanghai")
    private val publicIpResolver: (String) -> List<InetAddress> = {
        listOf(InetAddress.getByName("93.184.216.34"))
    }

    private fun epochMsAt(year: Int, month: Int, day: Int, hour: Int, minute: Int): Long =
        LocalDateTime.of(year, month, day, hour, minute)
            .atZone(zoneId)
            .toInstant()
            .toEpochMilli()

    private fun closeKernel(kernel: CloudAgentKernel) = runBlocking {
        kernel.stopProactiveLoop()
        kernel.conversationTagger.closeAndJoin()
        kernel.supertagStore.close()
        kernel.agentRegistry.close()
        kernel.orchestrationStore.close()
    }

    private fun pairIosWithPush(
        kernel: CloudAgentKernel,
        name: String = "Owner iPhone",
        pushToken: String = "apns-token-owner-001",
    ): CloudGatewayState.PairResult.Success {
        val ticket = kernel.gatewayState.issuePairingTicket()
        val paired = kernel.gatewayState.pairDevice(ticket, "ios", name) as CloudGatewayState.PairResult.Success
        val device = kernel.gatewayState.findDeviceById(paired.deviceId)!!
        val (status, _) = kernel.gatewayState.registerPushToken(device, pushToken, "production")
        assertEquals(200, status)
        return paired
    }

    @Test
    fun `Watchtower L1 drops unchanged with 0 model calls pushes on change blocks SSRF and persists across restart`() = runBlocking {
        val dir = Files.createTempDirectory("proactive-wt-combo1").toFile()
        val pageBody = AtomicReference("<html><body><h1>Model Pricing</h1><p>Input: $2.00 / M</p></body></html>")
        val pageEtag = AtomicReference("\"etag-1\"")
        val httpFetchCount = AtomicInteger(0)
        val l2ModelCallCount = AtomicInteger(0)
        val capturedPushes = CopyOnWriteArrayList<PushMessagePayload>()

        fun makeMockClient(): HttpClient = HttpClient(
            MockEngine { request ->
                httpFetchCount.incrementAndGet()
                val reqEtag = request.headers[HttpHeaders.IfNoneMatch]
                val curEtag = pageEtag.get()
                if (reqEtag != null && reqEtag == curEtag) {
                    respond(
                        content = "",
                        status = HttpStatusCode.NotModified,
                        headers = headersOf(HttpHeaders.ETag, curEtag),
                    )
                } else {
                    respond(
                        content = pageBody.get(),
                        status = HttpStatusCode.OK,
                        headers = headersOf(
                            HttpHeaders.ContentType to listOf("text/html; charset=utf-8"),
                            HttpHeaders.ETag to listOf(curEtag),
                        ),
                    )
                }
            }
        )

        val l2Client = CloudModelClient { messages, tools ->
            val isL2JudgeCall = messages.any { it.toText().contains("<untrusted_signal>") }
            if (isL2JudgeCall) {
                assertTrue(tools.isEmpty(), "L2 评判器严禁携带任何外部写工具")
                l2ModelCallCount.incrementAndGet()
            }
            UIMessage.assistant(
                """{"noteworthy":true,"urgency":4,"importance":4,"actionable":true,"recommended_channel":"im_direct","summary":"价格页面发生变化，建议查看新费率"}"""
            )
        }

        val t0 = epochMsAt(2026, 11, 23, 10, 0)
        val kernel1 = CloudAgentKernel(
            dataDir = dir,
            modelClient = l2Client,
            masterSecretOverride = "combo1-secret",
            proactiveHttpClient = makeMockClient(),
            proactiveDnsResolver = publicIpResolver,
        )
        try {
            pairIosWithPush(kernel1)
            kernel1.gatewayState.pushSender = PushSender { payload ->
                capturedPushes.add(payload)
                Result.success(Unit)
            }

            // SSRF guards: loopback, private IP, link-local, localhost, non-http all rejected
            listOf(
                "http://127.0.0.1:8080/internal",
                "http://localhost/admin",
                "http://192.168.1.1/status",
                "http://10.0.0.5/metrics",
                "http://169.254.169.254/latest/meta-data/",
                "file:///etc/passwd",
            ).forEach { badUrl ->
                assertFailsWith<IllegalArgumentException>("应拦截非公网地址: $badUrl") {
                    kernel1.proactiveMonitorStore.create(title = "bad", url = badUrl)
                }
            }
            // DNS-time SSRF guard (domain resolving to private IP 10.0.0.9)
            assertFailsWith<IllegalArgumentException> {
                ProactiveUrlGuard.validatePublicUrl("https://rebind.example.com/hook") {
                    listOf(InetAddress.getByName("10.0.0.9"))
                }
            }

            // Create valid public monitor
            val mon = kernel1.proactiveMonitorStore.create(
                title = "API 价格页",
                url = "https://example.com/pricing",
                conditionPrompt = "价格变动时提醒我",
                intervalMinutes = 15,
                nowMs = t0,
            )

            // 1st cycle: baseline snapshot -> pushed via L2 + L3 + APNs (silentDelivery=true for tier 2 score 16)
            val res1 = kernel1.runProactiveCycle(nowOverrideMs = t0)
            assertEquals(1, res1.size)
            assertIs<ProactiveRunResult.PushedAtL3>(res1.single())
            assertEquals(1, l2ModelCallCount.get())
            assertEquals(1, kernel1.proactiveEngine.metrics().l2ModelCallCount)
            assertEquals(1, capturedPushes.size)
            assertEquals(true, capturedPushes.single().silent)
            assertTrue(capturedPushes.single().deepLink?.startsWith("amber://proactive/") == true)

            // Verify 0600 permissions under dataDir/proactive/
            val monitorsFile = File(dir, "proactive/monitors.json")
            val l1File = File(dir, "proactive/l1-filter.json")
            val gateFile = File(dir, "proactive/restraint-gate.json")
            listOf(monitorsFile, l1File, gateFile).forEach { f ->
                assertTrue(f.exists(), "${f.name} 应已落盘")
                assertEquals("rw-------", PosixFilePermissions.toString(Files.getPosixFilePermissions(f.toPath())))
            }

            // 2nd cycle after 15m with unchanged content (HTTP 304) -> L1 drops with 0 model calls!
            l2ModelCallCount.set(0)
            val t1 = t0 + 15 * 60_000L
            val res2 = kernel1.runProactiveCycle(nowOverrideMs = t1)
            assertEquals(1, res2.size)
            assertIs<ProactiveRunResult.DroppedAtL1>(res2.single())
            assertEquals(0, l2ModelCallCount.get(), "无变化巡检必须 0 次模型调用")
            assertEquals(1, kernel1.proactiveEngine.metrics().l2ModelCallCount)
            assertEquals(1, kernel1.proactiveMonitorStore.get(mon.id)?.consecutiveUnchanged)
        } finally {
            closeKernel(kernel1)
        }

        // Simulate daemon restart on same dataDir
        val kernel2 = CloudAgentKernel(
            dataDir = dir,
            modelClient = l2Client,
            masterSecretOverride = "combo1-secret",
            proactiveHttpClient = makeMockClient(),
            proactiveDnsResolver = publicIpResolver,
        )
        try {
            kernel2.gatewayState.pushSender = PushSender { payload ->
                capturedPushes.add(payload)
                Result.success(Unit)
            }
            assertEquals(1, kernel2.proactiveMonitorStore.list().size, "重启后监控规则应持久保留")

            // 3rd cycle after restart with same body (different ETag to force SHA-256 comparison) -> still 0 L2 calls!
            pageEtag.set("\"etag-2-same-body\"")
            l2ModelCallCount.set(0)
            val t2 = t0 + 30 * 60_000L
            val res3 = kernel2.runProactiveCycle(nowOverrideMs = t2)
            assertEquals(1, res3.size)
            assertIs<ProactiveRunResult.DroppedAtL1>(res3.single())
            assertEquals(0, l2ModelCallCount.get(), "重启后恢复 L1 快照，无变化仍应 0 次模型调用")
            assertEquals(0, kernel2.proactiveEngine.metrics().l2ModelCallCount)

            // 4th cycle after cooldown (3h later) with changed price -> pushes again!
            pageEtag.set("\"etag-3-changed\"")
            pageBody.set("<html><body><h1>Model Pricing</h1><p>Input: $1.20 / M (Price Cut!)</p></body></html>")
            val t3 = t0 + 180 * 60_000L
            val res4 = kernel2.runProactiveCycle(nowOverrideMs = t3)
            assertEquals(1, res4.size)
            assertIs<ProactiveRunResult.PushedAtL3>(res4.single())
            assertEquals(1, l2ModelCallCount.get())
            assertEquals(2, capturedPushes.size)
        } finally {
            closeKernel(kernel2)
        }
    }

    @Test
    fun `real L2 judge degrades conservatively on model error or invalid JSON`() = runBlocking {
        val brokenJudge = CloudProactiveL2Judge(CloudModelClient { _, _ -> error("upstream timeout") })
        val req = L2EvaluationRequest("s1", TriggerCategory.EXTERNAL_SENSOR, "watchtower:1", "价格更新")
        val fallback1 = brokenJudge.evaluate(req)
        assertFalse(fallback1.noteworthy)

        val garbageJudge = CloudProactiveL2Judge(CloudModelClient { _, _ -> UIMessage.assistant("抱歉，我现在无法判断。") })
        val fallback2 = garbageJudge.evaluate(req)
        assertFalse(fallback2.noteworthy)

        for (badReply in listOf(
            """{"noteworthy":true,"summary":"missing scores"}""",
            """{"noteworthy":"true","urgency":5,"importance":5,"actionable":true,"recommended_channel":"pulse","summary":"wrong boolean"}""",
            """{"noteworthy":true,"urgency":6,"importance":5,"actionable":true,"recommended_channel":"pulse","summary":"out of range"}""",
            """{"noteworthy":true,"urgency":5,"importance":5,"summary":{"unexpected":true}}""",
        )) {
            val judge = CloudProactiveL2Judge(CloudModelClient { _, tools ->
                assertTrue(tools.isEmpty())
                UIMessage.assistant(badReply)
            })
            assertFalse(judge.evaluate(req).noteworthy, badReply)
        }
    }

    @Test
    fun `quiet hours and daily budget persist across kernel restart and buffer for morning briefing`() = runBlocking {
        val dir = Files.createTempDirectory("proactive-restraint-combo1").toFile()
        val capturedPushes = CopyOnWriteArrayList<PushMessagePayload>()
        val l2Client = CloudModelClient { _, _ ->
            UIMessage.assistant(
                """{"noteworthy":true,"urgency":5,"importance":5,"actionable":true,"recommended_channel":"im_direct","summary":"高优先级告警：服务延迟上升"}"""
            )
        }
        val nightMs = epochMsAt(2026, 11, 23, 23, 30)
        val dayMs = epochMsAt(2026, 11, 24, 10, 0)

        val kernel1 = CloudAgentKernel(dir, l2Client, masterSecretOverride = "restraint-secret")
        try {
            pairIosWithPush(kernel1)
            kernel1.gatewayState.pushSender = PushSender { capturedPushes.add(it); Result.success(Unit) }
            kernel1.proactiveEngine.restraintGate.updateConfig(dailyMaxPushes = 1)

            // Night trigger: suppressed by quiet hours, buffered for morning briefing, 0 APNs pushes
            val nightSignal = app.amber.cloud.proactive.ProactiveTriggerSignal.EdgeNodeSensorSignal(
                signalId = "sig-night-1",
                nodeId = "mac-mini",
                eventKind = "job_done",
                deduplicationKey = "night-1",
                summaryText = "夜间定时构建出现告警",
                timestampEpochMs = nightMs,
            )
            val nightRes = kernel1.triggerProactiveSignal(nightSignal, nowOverrideMs = nightMs)
            val sup = assertIs<ProactiveRunResult.SuppressedAtGate>(nightRes)
            assertIs<RestraintVerdict.SuppressedQuietHours>(sup.restraintVerdict)
            assertEquals(0, capturedPushes.size)
            assertEquals(1, kernel1.proactiveEngine.restraintGate.peekBufferedPulseItems().size)

            // Daytime push #1 succeeds (score 25 -> tier 3 -> silentDelivery = false)
            val daySignal1 = app.amber.cloud.proactive.ProactiveTriggerSignal.EdgeNodeSensorSignal(
                signalId = "sig-day-1",
                nodeId = "mac-mini",
                eventKind = "job_done",
                deduplicationKey = "day-1",
                summaryText = "白班任务完成",
                topicKey = "edge:day1",
                timestampEpochMs = dayMs,
            )
            val dayRes1 = kernel1.triggerProactiveSignal(daySignal1, nowOverrideMs = dayMs)
            val pushed1 = assertIs<ProactiveRunResult.PushedAtL3>(dayRes1)
            assertEquals(false, pushed1.restraintVerdict.silentDelivery)
            assertEquals(1, capturedPushes.size)
            assertEquals(false, capturedPushes.single().silent)
        } finally {
            closeKernel(kernel1)
        }

        // Restart kernel: daily count=1 (limit=1) and buffered pulse item must persist!
        val kernel2 = CloudAgentKernel(dir, l2Client, masterSecretOverride = "restraint-secret")
        try {
            kernel2.gatewayState.pushSender = PushSender { capturedPushes.add(it); Result.success(Unit) }
            assertEquals(1, kernel2.proactiveEngine.restraintGate.statusSnapshot(dayMs).pushesToday)
            assertEquals(1, kernel2.proactiveEngine.restraintGate.peekBufferedPulseItems().size)

            val daySignal2 = app.amber.cloud.proactive.ProactiveTriggerSignal.EdgeNodeSensorSignal(
                signalId = "sig-day-2",
                nodeId = "mac-mini",
                eventKind = "job_done",
                deduplicationKey = "day-2",
                summaryText = "第二条事件",
                topicKey = "edge:day2",
                timestampEpochMs = dayMs + 60_000L,
            )
            val dayRes2 = kernel2.triggerProactiveSignal(daySignal2, nowOverrideMs = dayMs + 60_000L)
            val deferred = assertIs<ProactiveRunResult.SuppressedAtGate>(dayRes2)
            assertIs<RestraintVerdict.DeferredByBudget>(deferred.restraintVerdict)
            assertEquals(1, capturedPushes.size, "重启后日上限保持，不应继续推 APNs")
        } finally {
            closeKernel(kernel2)
        }
    }

    @Test
    fun `upcoming 15-30m calendar event recalls memory once and overdue reminder deduplicates per day`() = runBlocking {
        val dir = Files.createTempDirectory("proactive-prep-combo1").toFile()
        val seenPrompts = CopyOnWriteArrayList<String>()
        val capturedPushes = CopyOnWriteArrayList<PushMessagePayload>()

        val l2Client = CloudModelClient { messages, _ ->
            val promptText = messages.joinToString("\n") { it.toText() }
            seenPrompts.add(promptText)
            val summary = if (promptText.contains("prep:event:")) {
                "会前 3 条要点：1) 回顾 Q4 预算上限 50 万；2) 确认 iOS 端 APNs 联调时间；3) 带上上次会议的里程碑清单。"
            } else {
                "有 1 项待办已延期超过 24 小时，是否需要改期或先拆出第一步？"
            }
            UIMessage.assistant(
                """{"noteworthy":true,"urgency":4,"importance":4,"actionable":true,"recommended_channel":"im_direct","summary":"$summary"}"""
            )
        }

        val nowMs = epochMsAt(2026, 11, 23, 14, 0)
        val kernel = CloudAgentKernel(dir, l2Client, masterSecretOverride = "prep-secret")
        try {
            val ios = pairIosWithPush(kernel, name = "Arquiel iPhone")
            kernel.gatewayState.pushSender = PushSender { capturedPushes.add(it); Result.success(Unit) }

            // Seed relevant memory in CloudMemoryStore
            kernel.memoryStore.upsertMemory("Q4 预算评审：研发预算上限 50 万，需确认 iOS 联调排期")

            kernel.memoryStore.upsertMemory("无关的家庭旅行计划", pinned = true)
            assertTrue(kernel.memoryStore.recallForPrompt("独立无匹配会议", requireMatch = true).isEmpty())

            // Upload iOS device context snapshot:
            // - 1 upcoming non-all-day event in 20 min (should trigger!)
            // - 1 all-day event in 20 min (must NOT trigger!)
            // - 1 far event in 2 hours (must NOT trigger!)
            // - 1 overdue reminder > 24h (should trigger once per day!)
            // - 1 recent reminder < 24h overdue (must NOT trigger!)
            val device = kernel.gatewayState.findDeviceById(ios.deviceId)!!
            val snapshotJson = """
                {
                  "capturedAtEpochMs": ${nowMs - 11 * 60_000L},
                  "ttlSeconds": 86400,
                  "domains": {
                    "calendarUpcoming": {
                      "items": [
                        {"title": "Q4 预算评审", "startMs": ${nowMs + 20 * 60_000L}, "endMs": ${nowMs + 80 * 60_000L}, "allDay": false},
                        {"title": "全天纪念日", "startMs": ${nowMs + 20 * 60_000L}, "endMs": ${nowMs + 86_400_000L}, "allDay": true},
                        {"title": "晚间同步会", "startMs": ${nowMs + 120 * 60_000L}, "endMs": ${nowMs + 180 * 60_000L}, "allDay": false}
                      ]
                    },
                    "remindersDue": {
                      "items": [
                        {"title": "提交报销单", "dueMs": ${nowMs - 30 * 3_600_000L}, "priority": 2},
                        {"title": "恰好到期一天", "dueMs": ${nowMs - 24 * 3_600_000L}, "priority": 2},
                        {"title": "刚到期一小时的提醒", "dueMs": ${nowMs - 3_600_000L}, "priority": 1}
                      ]
                    }
                  }
                }
            """.trimIndent()
            val putRes = kernel.gatewayState.deviceContextStore.putRawJson(device, snapshotJson.toByteArray(), nowMs)
            assertIs<app.amber.cloud.gateway.DeviceContextSnapshotStore.PutResult.Stored>(putRes)

            val source = kernel.deviceContextPrepTriggerSource
            val startMs = nowMs + 20 * 60_000L
            for ((delta, count) in listOf(15 * 60_000L - 1 to 0, 15 * 60_000L to 1, 30 * 60_000L to 1, 30 * 60_000L + 1 to 0)) {
                assertEquals(count, source.pollAll(startMs - delta).filterIsInstance<ProactiveTriggerSignal.UpcomingEventPrepSignal>().size)
            }
            val overdue = source.pollAll(nowMs).filterIsInstance<ProactiveTriggerSignal.OverdueReminderPrepSignal>().single()
            assertEquals(1, overdue.overdueItems.size)

            // Cycle 1: produces 1 UpcomingEventPrep + 1 OverdueReminderPrep
            val cycle1 = kernel.runProactiveCycle(nowOverrideMs = nowMs)
            assertEquals(2, cycle1.size)
            val pushedCards = cycle1.filterIsInstance<ProactiveRunResult.PushedAtL3>()
            assertEquals(2, pushedCards.size)
            assertTrue(seenPrompts.any { it.contains("研发预算上限 50 万") }, "会前准备应结合 CloudMemoryStore 历史记忆")
            assertFalse(seenPrompts.any { it.contains("无关的家庭旅行计划") })
            assertTrue(pushedCards.any { it.card.markdownBody.contains("会前 3 条要点") })
            assertTrue(pushedCards.any { it.card.markdownBody.contains("提交报销单") && it.card.markdownBody.contains("是否需要改期") })
            assertEquals(2, capturedPushes.size)

            // Primary conversation timeline should contain both proactive cards
            val primary = kernel.conversationStorage.loadConversation(PRIMARY_CONVERSATION_ID)
            assertNotNull(primary)
            assertTrue(primary.messageNodes.any { it.currentMessage.toText().contains("Q4 预算评审") })

            // Cycle 2 (2 minutes later, still inside 15-30m window and same day): BOTH deduplicated at L1!
            val cycle2 = kernel.runProactiveCycle(nowOverrideMs = nowMs + 2 * 60_000L)
            assertEquals(2, cycle2.size)
            assertTrue(cycle2.all { it is ProactiveRunResult.DroppedAtL1 }, "同场会议与当日延期提醒不得重复触发")
            assertEquals(2, capturedPushes.size)

            // Orphaned snapshots can survive a lost pairing registry.
            kernel.gatewayState.saveDevicesStrict(emptyList())
            assertTrue(kernel.deviceContextPrepTriggerSource.pollAll(nowMs).isEmpty())
        } finally {
            closeKernel(kernel)
        }
    }

    @Test
    fun `a failing push cannot lose the timeline card or prevent other current recipients`() = runBlocking {
        val dir = Files.createTempDirectory("proactive-push-isolation").toFile()
        val kernel = CloudAgentKernel(dir, CloudModelClient { _, _ ->
            UIMessage.assistant("""{"noteworthy":true,"urgency":4,"importance":4,"actionable":true,"recommended_channel":"pulse","summary":"通知"}""")
        }, masterSecretOverride = "push-test")
        try {
            val first = pairIosWithPush(kernel, pushToken = "first")
            val retired = pairIosWithPush(kernel, pushToken = "retired")
            val invalid = pairIosWithPush(kernel, pushToken = "legacy")
            val last = pairIosWithPush(kernel, pushToken = "last")
            val state = kernel.gatewayState
            state.saveDevicesStrict(state.loadDevicesStrict().map {
                if (it.id == invalid.deviceId) it.copy(pushToken = "invalid token") else it
            })
            val attempts = mutableListOf<PushMessagePayload>()
            state.pushSender = PushSender { payload ->
                attempts += payload
                if (payload.deviceId == first.deviceId) {
                    state.unpairDevice(retired.deviceId)
                    error("test sender unavailable")
                }
                Result.success(Unit)
            }
            val signal = ProactiveTriggerSignal.EdgeNodeSensorSignal("notice", "mac", "finished", "one", "任务已完成")
            assertIs<ProactiveRunResult.PushedAtL3>(kernel.triggerProactiveSignal(signal, epochMsAt(2026, 11, 23, 10, 0)))
            assertEquals(listOf(first.deviceId, last.deviceId), attempts.map { it.deviceId })
            assertTrue(attempts.all { it.silent })
            val messages = kernel.conversationStorage.loadConversation(PRIMARY_CONVERSATION_ID)!!.messageNodes
            assertTrue(messages.single().currentMessage.toText().contains("任务已完成"))

            // Simultaneous webhook and polling outcomes append through the same timeline lock.
            state.pushSender = PushSender { Result.success(Unit) }
            kernel.proactiveEngine.restraintGate.updateConfig(dailyMaxPushes = 20)
            val outcomes = (1..8).map { i ->
                async(Dispatchers.IO) {
                    val next = signal.copy(signalId = "s-$i", topicKey = "topic-$i", deduplicationKey = "key-$i")
                    kernel.triggerProactiveSignal(next, epochMsAt(2026, 11, 23, 11, 0))
                }
            }.awaitAll()
            assertTrue(outcomes.all { it is ProactiveRunResult.PushedAtL3 })
            assertEquals(9, kernel.conversationStorage.loadConversation(PRIMARY_CONVERSATION_ID)!!.messageNodes.size)
        } finally {
            closeKernel(kernel)
        }
    }

    @Test
    fun `signed webhook verifies HMAC and Bearer blocks bad auth redacts secrets prevents replay and serves management REST API and builtin tools`() = runBlocking {
        val dir = Files.createTempDirectory("proactive-webhook-api").toFile()
        val l2Calls = AtomicInteger(0)
        val capturedPushes = CopyOnWriteArrayList<PushMessagePayload>()

        val l2Client = CloudModelClient { _, _ ->
            l2Calls.incrementAndGet()
            UIMessage.assistant(
                """{"noteworthy":true,"urgency":5,"importance":4,"actionable":true,"recommended_channel":"im_direct","summary":"Webhook 事件已归类：CI 构建失败需处理"}"""
            )
        }

        val kernel = CloudAgentKernel(
            dataDir = dir,
            modelClient = l2Client,
            masterSecretOverride = "webhook-secret",
            proactiveDnsResolver = publicIpResolver,
        )
        try {
            val ios = pairIosWithPush(kernel)
            kernel.gatewayState.pushSender = PushSender { capturedPushes.add(it); Result.success(Unit) }
            // Disable quiet hours for deterministic testing regardless of wall-clock hour
            kernel.proactiveEngine.restraintGate.updateConfig(quietHoursEnabled = false, dailyMaxPushes = 10)

            // Verify builtin tools ownership & risk levels
            val owner = CloudPrincipal.OwnerUser(ios.deviceId, "app")
            val subagent = CloudPrincipal.Worker("worker:w1", "w1", "batch-1", ExecutionTargetNode.RemoteSandbox())
            assertEquals(ToolRiskLevel.L1, kernel.toolRegistry.riskLevel("proactive_monitor_list"))
            assertEquals(ToolRiskLevel.L1, kernel.toolRegistry.riskLevel("proactive_webhook_list"))
            assertEquals(ToolRiskLevel.L2, kernel.toolRegistry.riskLevel("proactive_monitor_create"))
            assertEquals(ToolRiskLevel.L2, kernel.toolRegistry.riskLevel("proactive_webhook_create"))

            // Subagent denied on ownerOnly proactive tools
            val deniedTool = kernel.toolRegistry.executeGate(
                "proactive_monitor_list",
                JsonObject(emptyMap()),
                ExecutionScope.SUBAGENT,
                principal = subagent,
            ).jsonObject
            assertFalse(deniedTool["ok"]!!.jsonPrimitive.boolean)

            // Owner creates, lists, updates, deletes monitor via natural-language builtin tools
            val toolMonCreate = kernel.toolRegistry.executeGate(
                "proactive_monitor_create",
                buildJsonObject {
                    put("title", "发布日志监控")
                    put("url", "https://example.com/releases")
                    put("conditionPrompt", "新版本发布")
                    put("intervalMinutes", 30)
                },
                ExecutionScope.MAIN_AGENT,
                principal = owner,
            ).jsonObject
            assertTrue(toolMonCreate["ok"]!!.jsonPrimitive.boolean)
            val toolMonId = toolMonCreate["monitor"]!!.jsonObject["id"]!!.jsonPrimitive.content

            val toolMonUpdate = kernel.toolRegistry.executeGate(
                "proactive_monitor_update",
                buildJsonObject {
                    put("id", toolMonId)
                    put("intervalMinutes", 60)
                    put("enabled", false)
                },
                ExecutionScope.MAIN_AGENT,
                principal = owner,
            ).jsonObject
            assertTrue(toolMonUpdate["ok"]!!.jsonPrimitive.boolean)
            assertEquals(false, toolMonUpdate["monitor"]!!.jsonObject["enabled"]!!.jsonPrimitive.boolean)

            val toolWhCreate = kernel.toolRegistry.executeGate(
                "proactive_webhook_create",
                buildJsonObject {
                    put("name", "工具创建的 Webhook")
                    put("instruction", "汇总事件")
                },
                ExecutionScope.MAIN_AGENT,
                principal = owner,
            ).jsonObject
            assertTrue(toolWhCreate["ok"]!!.jsonPrimitive.boolean)
            val toolWhId = toolWhCreate["webhook"]!!.jsonObject["id"]!!.jsonPrimitive.content
            val toolWhSecret = toolWhCreate["secret"]!!.jsonPrimitive.content
            assertTrue(toolWhSecret.startsWith("whsec_"))

            val toolWhList = kernel.toolRegistry.executeGate(
                "proactive_webhook_list",
                JsonObject(emptyMap()),
                ExecutionScope.MAIN_AGENT,
                principal = owner,
            ).jsonObject
            assertFalse(toolWhList.toString().contains(toolWhSecret), "列表工具永不回显明文 secret")

            assertTrue(
                kernel.toolRegistry.executeGate(
                    "proactive_webhook_delete",
                    buildJsonObject { put("id", toolWhId) },
                    ExecutionScope.MAIN_AGENT,
                    principal = owner,
                ).jsonObject["ok"]!!.jsonPrimitive.boolean
            )
            assertTrue(
                kernel.toolRegistry.executeGate(
                    "proactive_monitor_delete",
                    buildJsonObject { put("id", toolMonId) },
                    ExecutionScope.MAIN_AGENT,
                    principal = owner,
                ).jsonObject["ok"]!!.jsonPrimitive.boolean
            )

            // Full REST API + Inbound Webhook verification via Ktor testApplication
            testApplication {
                application {
                    configureCloudGateway(kernel.gatewayState, agentApi = AgentCentricApi(kernel))
                }

                // Unauthenticated rejected on management API
                assertEquals(401, client.get("/v2/proactive/summary").status.value)

                // Create monitor via REST API
                val monResp = client.post("/v2/proactive/monitors") {
                    bearerAuth(ios.token)
                    contentType(ContentType.Application.Json)
                    setBody("""{"title":"官网价格","url":"https://example.com/price","conditionPrompt":"降价通知","intervalMinutes":20}""")
                }
                assertEquals(201, monResp.status.value)
                val monId = json.parseToJsonElement(monResp.bodyAsText()).jsonObject["monitor"]!!.jsonObject["id"]!!.jsonPrimitive.content

                // SSRF URL rejected via REST API
                val badMonResp = client.post("/v2/proactive/monitors") {
                    bearerAuth(ios.token)
                    contentType(ContentType.Application.Json)
                    setBody("""{"title":"内网探测","url":"http://127.0.0.1:9000/secret"}""")
                }
                assertEquals(400, badMonResp.status.value)

                // PATCH monitor
                val patchMonResp = client.patch("/v2/proactive/monitors/$monId") {
                    bearerAuth(ios.token)
                    contentType(ContentType.Application.Json)
                    setBody("""{"intervalMinutes":45,"enabled":true}""")
                }
                assertEquals(200, patchMonResp.status.value)
                assertEquals(45, json.parseToJsonElement(patchMonResp.bodyAsText()).jsonObject["monitor"]!!.jsonObject["intervalMinutes"]!!.jsonPrimitive.int)

                // Create webhook via REST API -> returns secret & inboundPath ONCE
                val whResp = client.post("/v2/proactive/webhooks") {
                    bearerAuth(ios.token)
                    contentType(ContentType.Application.Json)
                    setBody("""{"name":"CI 构建告警","instruction":"提取失败任务名"}""")
                }
                assertEquals(201, whResp.status.value)
                val whBody = json.parseToJsonElement(whResp.bodyAsText()).jsonObject
                val whId = whBody["webhook"]!!.jsonObject["id"]!!.jsonPrimitive.content
                val whSecret = whBody["secret"]!!.jsonPrimitive.content
                val inboundPath = whBody["inboundPath"]!!.jsonPrimitive.content
                assertEquals("/v2/triggers/webhook/$whId", inboundPath)

                // Verify webhooks.json on disk does NOT contain plaintext secret, and secret IS in Vault
                val webhooksFileText = File(dir, "proactive/webhooks.json").readText()
                assertFalse(webhooksFileText.contains(whSecret), "webhooks.json 严禁明文保存 secret")
                assertEquals(whSecret, kernel.vault.getSecret(ProactiveWebhookStore.vaultKey(whId)))

                // 1) Wrong signature / missing auth -> 401
                val badSig = client.post(inboundPath) {
                    header("X-Amber-Signature", "sha256=0000000000000000000000000000000000000000000000000000000000000000")
                    setBody("""{"event":"build_failed"}""")
                }
                assertEquals(401, badSig.status.value)
                assertEquals(0, l2Calls.get())

                assertEquals("no-store", whResp.headers[HttpHeaders.CacheControl])
                assertEquals("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
                    ProactiveWebhookStore.computeHmacSha256Hex("Jefe", "what do ya want for nothing?".toByteArray()))
                val bytes = "event".toByteArray()
                assertFalse(kernel.proactiveWebhookStore.verifyInboundAuth(whId, bytes, "", "Bearer $whSecret"))

                // 2) Payload > 64KB -> 413
                val oversized = "x".repeat(65 * 1024)
                val tooBig = client.post(inboundPath) {
                    header(HttpHeaders.Authorization, "Bearer $whSecret")
                    setBody(oversized)
                }
                assertEquals(413, tooBig.status.value)

                fun streamed(size: Int) = object : OutgoingContent.ReadChannelContent() {
                    override fun readFrom() = ByteReadChannel(ByteArray(size) { 65 })
                }
                // Missing Content-Length exercises the stream limit before authentication.
                assertEquals(413, client.post(inboundPath) { setBody(streamed(65_537)) }.status.value)
                assertEquals(401, client.post(inboundPath) { setBody(streamed(65_536)) }.status.value)

                // 3) Valid HMAC-SHA256 signature with sensitive token in body -> 200 pushed + redacted + APNs sent!
                val hmacPayload = """{"repo":"amber","status":"failed $whSecret","token":"sk-live-secret-99887766554433221100"}"""
                val validSig = "sha256=" + ProactiveWebhookStore.computeHmacSha256Hex(
                    whSecret,
                    hmacPayload.toByteArray(StandardCharsets.UTF_8),
                )
                val okHmac = client.post(inboundPath) {
                    header("X-Amber-Signature", validSig)
                    header("X-Amber-Delivery", "delivery-hmac-001")
                    setBody(hmacPayload)
                }
                assertEquals(200, okHmac.status.value)
                val okHmacJson = json.parseToJsonElement(okHmac.bodyAsText()).jsonObject
                assertEquals("pushed", okHmacJson["outcome"]!!.jsonPrimitive.content)
                assertEquals(1, l2Calls.get())
                assertEquals(1, capturedPushes.size)

                // Ensure secret in payload was redacted in primary timeline
                val primaryText = kernel.conversationStorage.loadConversation(PRIMARY_CONVERSATION_ID)!!
                    .messageNodes.joinToString("\n") { it.currentMessage.toText() }
                assertFalse(primaryText.contains("sk-live-secret-99887766554433221100"), "Webhook 载荷中的密钥必须被脱敏")

                // 4) Replay with same X-Amber-Delivery -> 200 duplicate, 0 extra L2 calls or pushes!
                val replayResp = client.post(inboundPath) {
                    header("X-Amber-Signature", validSig)
                    header("X-Amber-Delivery", "delivery-hmac-001")
                    setBody(hmacPayload)
                }
                assertEquals(200, replayResp.status.value)
                assertEquals("duplicate", json.parseToJsonElement(replayResp.bodyAsText()).jsonObject["outcome"]!!.jsonPrimitive.content)
                assertEquals(1, l2Calls.get(), "重放投递必须在 L1 幂等拦截，0 次模型调用")
                assertEquals(1, capturedPushes.size)

                val sameSignedContent = client.post(inboundPath) {
                    header("X-Amber-Signature", validSig.uppercase())
                    header("X-Amber-Delivery", whSecret)
                    setBody(hmacPayload)
                }
                val duplicate = sameSignedContent.bodyAsText()
                assertEquals("duplicate", json.parseToJsonElement(duplicate).jsonObject["outcome"]!!.jsonPrimitive.content)
                assertEquals(1, l2Calls.get())
                assertFalse(duplicate.contains(whSecret))
                assertFalse(primaryText.contains(whSecret))
                assertFalse(File(dir, "audit.jsonl").readText().contains(whSecret))
                assertFalse(File(dir, "proactive/l1-filter.json").readText().contains(whSecret))

                // 5) Valid Authorization: Bearer <secret> on a fresh webhook (separate topic cooldown) -> 200 pushed!
                val wh2Resp = client.post("/v2/proactive/webhooks") {
                    bearerAuth(ios.token)
                    contentType(ContentType.Application.Json)
                    setBody("""{"name":"部署通知","instruction":"总结部署结果"}""")
                }
                assertEquals(201, wh2Resp.status.value)
                val wh2Body = json.parseToJsonElement(wh2Resp.bodyAsText()).jsonObject
                val wh2Secret = wh2Body["secret"]!!.jsonPrimitive.content
                val wh2Path = wh2Body["inboundPath"]!!.jsonPrimitive.content
                val okBearer = client.post(wh2Path) {
                    header(HttpHeaders.Authorization, "Bearer $wh2Secret")
                    setBody("""{"deploy":"prod-v2","ok":true}""")
                }
                assertEquals(200, okBearer.status.value)
                assertEquals("pushed", json.parseToJsonElement(okBearer.bodyAsText()).jsonObject["outcome"]!!.jsonPrimitive.content)
                assertEquals(2, capturedPushes.size)

                // 6) PATCH restraint & GET summary (no plaintext secrets anywhere!)
                val patchRestraint = client.patch("/v2/proactive/restraint") {
                    bearerAuth(ios.token)
                    contentType(ContentType.Application.Json)
                    setBody("""{"quietHoursEnabled":true,"quietHoursStart":"22:00","quietHoursEnd":"07:00","dailyMaxPushes":8}""")
                }
                assertEquals(200, patchRestraint.status.value)

                val summaryResp = client.get("/v2/proactive/summary") {
                    bearerAuth(ios.token)
                }
                assertEquals(200, summaryResp.status.value)
                val summaryRaw = summaryResp.bodyAsText()
                assertFalse(summaryRaw.contains(whSecret), "summary 接口绝不能回显明文 secret")
                assertFalse(summaryRaw.contains(wh2Secret), "summary 接口绝不能回显明文 secret")
                val summaryJson = json.parseToJsonElement(summaryRaw).jsonObject
                assertEquals(1, summaryJson["monitors"]!!.jsonArray.size)
                assertEquals(2, summaryJson["webhooks"]!!.jsonArray.size)
                assertEquals("22:00", summaryJson["restraint"]!!.jsonObject["quietHoursStart"]!!.jsonPrimitive.content)
                assertEquals(8, summaryJson["restraint"]!!.jsonObject["dailyMaxPushes"]!!.jsonPrimitive.int)
                assertTrue(summaryJson["recentRuns"]!!.jsonArray.isNotEmpty())

                // Payload fallback hashes the original bytes, even for non-text deliveries.
                val binaryReceipts = listOf(0xfe, 0xff, 0xfe).map {
                    val response = client.post(wh2Path) {
                        bearerAuth(wh2Secret)
                        setBody(byteArrayOf(it.toByte()))
                    }
                    assertEquals(200, response.status.value)
                    json.parseToJsonElement(response.bodyAsText()).jsonObject
                }
                val keys = binaryReceipts.map { it.getValue("deliveryId").jsonPrimitive.content }
                assertTrue(keys[0] != keys[1])
                assertEquals(keys[0], keys[2])
                assertEquals("duplicate", binaryReceipts.last().getValue("outcome").jsonPrimitive.content)

                // 7) Disable webhook via PATCH -> inbound returns 403
                val disableWh = client.patch("/v2/proactive/webhooks/$whId") {
                    bearerAuth(ios.token)
                    contentType(ContentType.Application.Json)
                    setBody("""{"enabled":false}""")
                }
                assertEquals(200, disableWh.status.value)
                val disabledInbound = client.post(inboundPath) {
                    header(HttpHeaders.Authorization, "Bearer $whSecret")
                    setBody("""{"event":"after_disable"}""")
                }
                assertEquals(403, disabledInbound.status.value)

                // 8) Delete webhook & monitor via REST API
                assertEquals(200, client.delete("/v2/proactive/webhooks/$whId") { bearerAuth(ios.token) }.status.value)
                assertEquals(null, kernel.vault.getSecret(ProactiveWebhookStore.vaultKey(whId)), "删除 Webhook 后应同步清理 Vault 密钥")
                assertEquals(200, client.delete("/v2/proactive/monitors/$monId") { bearerAuth(ios.token) }.status.value)
            }
        } finally {
            closeKernel(kernel)
        }
    }
}
