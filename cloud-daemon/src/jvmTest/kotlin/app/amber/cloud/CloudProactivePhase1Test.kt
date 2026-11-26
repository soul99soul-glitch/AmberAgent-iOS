package app.amber.cloud

import app.amber.ai.ui.UIMessage
import app.amber.cloud.channel.ChannelConnector
import app.amber.cloud.channel.ChannelIngress
import app.amber.cloud.channel.ChannelKind
import app.amber.cloud.channel.ConversationScope
import app.amber.cloud.channel.InboundMessage
import app.amber.cloud.channel.OutboundMessage
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.config.CloudConfigLoader
import app.amber.cloud.gateway.AgentCentricApi
import app.amber.cloud.gateway.CloudGatewayState
import app.amber.cloud.gateway.PushMessagePayload
import app.amber.cloud.gateway.PushSender
import app.amber.cloud.gateway.configureCloudGateway
import app.amber.cloud.orchestration.DialogueEvent
import app.amber.cloud.orchestration.DialogueEventKinds
import app.amber.cloud.orchestration.DialoguePage
import app.amber.cloud.orchestration.RouterBrain
import app.amber.cloud.orchestration.RouterDecision
import app.amber.cloud.proactive.ProactiveRunResult
import app.amber.cloud.proactive.ProactiveTriggerSignal
import app.amber.cloud.proactive.ProactiveUrgency
import app.amber.cloud.proactive.ProactiveWakeupRecord
import app.amber.cloud.proactive.ProactiveWakeupStore
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import io.ktor.client.request.bearerAuth
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.server.testing.testApplication
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CloudProactivePhase1Test {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val zoneId = ZoneId.of("Asia/Shanghai")

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
        pushToken: String = "apns-token-p1-001",
        environment: String = "production",
    ): CloudGatewayState.PairResult.Success {
        val ticket = kernel.gatewayState.issuePairingTicket()
        val paired = kernel.gatewayState.pairDevice(ticket, "ios", name) as CloudGatewayState.PairResult.Success
        val device = kernel.gatewayState.findDeviceById(paired.deviceId)!!
        val (status, _) = kernel.gatewayState.registerPushToken(device, pushToken, environment)
        assertEquals(200, status)
        return paired
    }

    private class TestConnector(override val kind: ChannelKind = ChannelKind.TELEGRAM) : ChannelConnector {
        var attachedIngress: ChannelIngress? = null
        val sent = CopyOnWriteArrayList<OutboundMessage>()

        override fun attachIngress(ingress: ChannelIngress) {
            attachedIngress = ingress
        }

        override suspend fun start() = Unit
        override suspend fun stop() = Unit
        override suspend fun send(message: OutboundMessage): Result<String> {
            sent.add(message)
            return Result.success("msg-${sent.size}")
        }
    }

    @Test
    fun `proactive delivery writes idempotent redacted event hidden from legacy clients and visible in v1`() = runBlocking {
        val dir = Files.createTempDirectory("proactive-p1-events").toFile()
        val capturedPushes = CopyOnWriteArrayList<PushMessagePayload>()
        val l2Client = CloudModelClient { _, _ ->
            UIMessage.assistant(
                """{"noteworthy":true,"urgency":4,"importance":4,"actionable":true,"recommended_channel":"im_direct","summary":"构建告警 sk-live-secret-99887766554433221100"}"""
            )
        }
        val kernel = CloudAgentKernel(dir, l2Client, masterSecretOverride = "p1-events-secret")
        try {
            val ios = pairIosWithPush(kernel)
            kernel.gatewayState.pushSender = PushSender { payload ->
                capturedPushes.add(payload)
                Result.success(Unit)
            }
            val nowMs = epochMsAt(2026, 11, 26, 10, 0)
            val signal = ProactiveTriggerSignal.EdgeNodeSensorSignal(
                signalId = "edge_sig_001",
                nodeId = "mac-studio",
                eventKind = "job_done",
                deduplicationKey = "dedup-edge-001",
                summaryText = "编译结束 token=sk-live-secret-99887766554433221100",
                topicKey = "edge:mac-studio:job_done",
                timestampEpochMs = nowMs,
            )

            val res = kernel.triggerProactiveSignal(signal, nowOverrideMs = nowMs)
            val pushed = assertIs<ProactiveRunResult.PushedAtL3>(res)

            // 1. Exactly 1 proactive:{signalId} event exists and is properly redacted
            val stored = kernel.orchestrationStore.dialogue.findEvent("proactive:edge_sig_001")
            assertNotNull(stored)
            assertEquals(DialogueEventKinds.PROACTIVE_MESSAGE, stored.kind)
            assertEquals("assistant", stored.role)
            assertEquals("proactive:edge_sig_001", stored.topicId)
            assertNull(stored.workItemId)
            assertNull(stored.conversationId)
            assertNull(stored.causedByInputId)
            assertNull(stored.causedByRequestId)
            assertFalse(stored.text.contains("sk-live-secret-99887766554433221100"))
            val meta = assertNotNull(stored.proactive)
            assertEquals("edge_sig_001", meta.signalId)
            assertEquals("edge:mac-studio:job_done", meta.topicKey)
            assertEquals("normal", meta.urgency)
            assertEquals(true, meta.silent)
            assertEquals(listOf("act", "snooze", "mute"), meta.actions)

            // 2. Duplicate delivery is idempotent in DialogueEventStore
            kernel.deliverProactiveCardToOwner(pushed)
            val allPage = kernel.orchestrationStore.dialogue.page(after = 0, limit = 100, legacyClient = false)
            assertEquals(1, allPage.items.count { it.id == "proactive:edge_sig_001" })

            // 3. Push payload carries signalId and interruptionLevel
            assertTrue(capturedPushes.isNotEmpty())
            val firstPush = capturedPushes.first()
            assertEquals("edge_sig_001", firstPush.signalId)
            assertEquals("passive", firstPush.interruptionLevel)
            assertEquals("amber://proactive/edge_sig_001", firstPush.deepLink)

            // 4. HTTP pagination: legacy (no header) hides proactive_message; X-Amber-Dialogue-Version: 1 returns it
            testApplication {
                application { configureCloudGateway(kernel.gatewayState, agentApi = AgentCentricApi(kernel)) }

                val legacyResp = client.get("/v2/dialogue/events?after=0&limit=50") {
                    bearerAuth(ios.token)
                }
                assertEquals(200, legacyResp.status.value)
                val legacyPage = json.decodeFromString<DialoguePage>(legacyResp.bodyAsText())
                assertTrue(legacyPage.items.none { it.kind == DialogueEventKinds.PROACTIVE_MESSAGE })

                val v1Resp = client.get("/v2/dialogue/events?after=0&limit=50") {
                    bearerAuth(ios.token)
                    header("X-Amber-Dialogue-Version", "1")
                }
                assertEquals(200, v1Resp.status.value)
                val v1Page = json.decodeFromString<DialoguePage>(v1Resp.bodyAsText())
                val found = v1Page.items.single { it.id == "proactive:edge_sig_001" }
                assertEquals("edge_sig_001", found.proactive?.signalId)

                // Summary exposes wakeups array (P1 empty list)
                val summaryResp = client.get("/v2/proactive/summary") {
                    bearerAuth(ios.token)
                }
                assertEquals(200, summaryResp.status.value)
                val summaryObj = json.parseToJsonElement(summaryResp.bodyAsText()).jsonObject
                assertTrue(summaryObj["wakeups"]!!.jsonArray.isEmpty())
            }
        } finally {
            closeKernel(kernel)
        }
    }

    @Test
    fun `signal GET feedback and restraint unmute REST endpoints enforce auth validation and idempotency`() = runBlocking {
        val dir = Files.createTempDirectory("proactive-p1-rest").toFile()
        val l2Client = CloudModelClient { _, _ ->
            UIMessage.assistant(
                """{"noteworthy":true,"urgency":5,"importance":4,"actionable":true,"recommended_channel":"im_direct","summary":"价格变动提醒"}"""
            )
        }
        val kernel = CloudAgentKernel(dir, l2Client, masterSecretOverride = "p1-rest-secret")
        try {
            val ios = pairIosWithPush(kernel)
            kernel.proactiveEngine.restraintGate.updateConfig(quietHoursEnabled = false, dailyMaxPushes = 10)
            val nowMs = epochMsAt(2026, 11, 26, 11, 0)
            val sig = ProactiveTriggerSignal.EdgeNodeSensorSignal(
                signalId = "sig_rest_01",
                nodeId = "mac",
                eventKind = "price",
                deduplicationKey = "rest-01",
                summaryText = "价格发生变动",
                topicKey = "watchtower:pricing",
                timestampEpochMs = nowMs,
            )
            assertIs<ProactiveRunResult.PushedAtL3>(kernel.triggerProactiveSignal(sig, nowOverrideMs = nowMs))

            testApplication {
                application { configureCloudGateway(kernel.gatewayState, agentApi = AgentCentricApi(kernel)) }

                // GET /v2/proactive/signals/{id}: 401 / 400 / 404 / 200
                assertEquals(401, client.get("/v2/proactive/signals/sig_rest_01").status.value)
                assertEquals(400, client.get("/v2/proactive/signals/bad\$id") { bearerAuth(ios.token) }.status.value)
                assertEquals(400, client.get("/v2/proactive/signals/${"a".repeat(49)}") { bearerAuth(ios.token) }.status.value)
                assertEquals(404, client.get("/v2/proactive/signals/missing_sig_99") { bearerAuth(ios.token) }.status.value)

                val okSignal = client.get("/v2/proactive/signals/sig_rest_01") { bearerAuth(ios.token) }
                assertEquals(200, okSignal.status.value)
                val eventJson = json.parseToJsonElement(okSignal.bodyAsText()).jsonObject["event"]!!
                val decodedEvent = json.decodeFromJsonElement(DialogueEvent.serializer(), eventJson)
                assertEquals("proactive:sig_rest_01", decodedEvent.id)
                assertEquals("watchtower:pricing", decodedEvent.proactive?.topicKey)

                // POST feedback: 400 invalid_action, 404 signal_not_found
                val badAction = client.post("/v2/proactive/signals/sig_rest_01/feedback") {
                    bearerAuth(ios.token)
                    contentType(ContentType.Application.Json)
                    setBody("""{"action":"bogus"}""")
                }
                assertEquals(400, badAction.status.value)
                assertTrue(badAction.bodyAsText().contains("invalid_action"))

                val missingFb = client.post("/v2/proactive/signals/missing_sig_99/feedback") {
                    bearerAuth(ios.token)
                    contentType(ContentType.Application.Json)
                    setBody("""{"action":"opened"}""")
                }
                assertEquals(404, missingFb.status.value)

                // opened -> applied=true; duplicate -> applied=false
                val opened1 = client.post("/v2/proactive/signals/sig_rest_01/feedback") {
                    bearerAuth(ios.token)
                    contentType(ContentType.Application.Json)
                    setBody("""{"action":"opened"}""")
                }
                assertEquals(200, opened1.status.value)
                assertEquals(true, json.parseToJsonElement(opened1.bodyAsText()).jsonObject["applied"]!!.jsonPrimitive.boolean)

                val opened2 = client.post("/v2/proactive/signals/sig_rest_01/feedback") {
                    bearerAuth(ios.token)
                    contentType(ContentType.Application.Json)
                    setBody("""{"action":"opened"}""")
                }
                assertEquals(200, opened2.status.value)
                assertEquals(false, json.parseToJsonElement(opened2.bodyAsText()).jsonObject["applied"]!!.jsonPrimitive.boolean)

                // dismiss -> applied=true; duplicate -> applied=false
                val dismiss1 = client.post("/v2/proactive/signals/sig_rest_01/feedback") {
                    bearerAuth(ios.token)
                    contentType(ContentType.Application.Json)
                    setBody("""{"action":"dismiss"}""")
                }
                assertEquals(200, dismiss1.status.value)
                assertEquals(true, json.parseToJsonElement(dismiss1.bodyAsText()).jsonObject["applied"]!!.jsonPrimitive.boolean)

                val dismiss2 = client.post("/v2/proactive/signals/sig_rest_01/feedback") {
                    bearerAuth(ios.token)
                    contentType(ContentType.Application.Json)
                    setBody("""{"action":"dismiss"}""")
                }
                assertEquals(false, json.parseToJsonElement(dismiss2.bodyAsText()).jsonObject["applied"]!!.jsonPrimitive.boolean)

                // mute_topic -> applied=true, mutedUntilEpochMs present, gate records muted topic
                val mute1 = client.post("/v2/proactive/signals/sig_rest_01/feedback") {
                    bearerAuth(ios.token)
                    contentType(ContentType.Application.Json)
                    setBody("""{"action":"mute_topic","muteHours":48}""")
                }
                assertEquals(200, mute1.status.value)
                val mute1Obj = json.parseToJsonElement(mute1.bodyAsText()).jsonObject
                assertEquals(true, mute1Obj["applied"]!!.jsonPrimitive.boolean)
                assertTrue(mute1Obj["mutedUntilEpochMs"]!!.jsonPrimitive.long > 0L)
                assertEquals(1, kernel.proactiveEngine.restraintGate.statusSnapshot().mutedTopics.size)

                val mute2 = client.post("/v2/proactive/signals/sig_rest_01/feedback") {
                    bearerAuth(ios.token)
                    contentType(ContentType.Application.Json)
                    setBody("""{"action":"mute_topic","muteHours":48}""")
                }
                assertEquals(false, json.parseToJsonElement(mute2.bodyAsText()).jsonObject["applied"]!!.jsonPrimitive.boolean)

                // unmute topic
                val unmuteResp = client.post("/v2/proactive/restraint/unmute") {
                    bearerAuth(ios.token)
                    contentType(ContentType.Application.Json)
                    setBody("""{"topicKey":"watchtower:pricing"}""")
                }
                assertEquals(200, unmuteResp.status.value)
                val restraintObj = json.parseToJsonElement(unmuteResp.bodyAsText()).jsonObject["restraint"]!!.jsonObject
                assertTrue(restraintObj["mutedTopics"]!!.jsonArray.isEmpty())

                // Run history contains feedback_* entries
                val outcomes = kernel.proactiveRunHistoryStore.recent(20).map { it.outcome }
                assertTrue("feedback_opened" in outcomes)
                assertTrue("feedback_dismiss" in outcomes)
                assertTrue("feedback_mute_topic" in outcomes)
            }
        } finally {
            closeKernel(kernel)
        }
    }

    @Test
    fun `snooze creates deterministic wakeup that fires URGENT through quiet hours with 0 L2 calls`() = runBlocking {
        val dir = Files.createTempDirectory("proactive-p1-snooze").toFile()
        val l2Calls = AtomicInteger(0)
        val capturedPushes = CopyOnWriteArrayList<PushMessagePayload>()
        val l2Client = CloudModelClient { messages, _ ->
            if (messages.any { it.toText().contains("<untrusted_signal>") }) {
                l2Calls.incrementAndGet()
            }
            UIMessage.assistant(
                """{"noteworthy":true,"urgency":4,"importance":4,"actionable":true,"recommended_channel":"im_direct","summary":"记得回复合同邮件"}"""
            )
        }
        val kernel = CloudAgentKernel(dir, l2Client, masterSecretOverride = "p1-snooze-secret")
        try {
            pairIosWithPush(kernel)
            kernel.gatewayState.pushSender = PushSender { payload ->
                capturedPushes.add(payload)
                Result.success(Unit)
            }
            // Quiet hours 23:00-08:00 enabled
            val eveningMs = epochMsAt(2026, 11, 26, 22, 30)
            val sig = ProactiveTriggerSignal.EdgeNodeSensorSignal(
                signalId = "sig_snooze_base",
                nodeId = "mac",
                eventKind = "mail",
                deduplicationKey = "snooze-base",
                summaryText = "合同邮件待回复",
                topicKey = "mail:contract",
                timestampEpochMs = eveningMs,
            )
            assertIs<ProactiveRunResult.PushedAtL3>(kernel.triggerProactiveSignal(sig, nowOverrideMs = eveningMs))
            assertEquals(1, l2Calls.get())

            // Snooze 60 min -> due at 23:30 (inside quiet hours!)
            val fb1 = kernel.applyProactiveFeedback(
                signalId = "sig_snooze_base",
                action = app.amber.cloud.proactive.ProactiveFeedbackAction.SNOOZE,
                snoozeMinutes = 60,
                nowEpochMs = eveningMs,
            ) as CloudAgentKernel.ProactiveFeedbackResult.Applied
            assertTrue(fb1.applied)
            val wakeupId = assertNotNull(fb1.wakeupId)
            assertEquals(ProactiveWakeupStore.deterministicSnoozeId("sig_snooze_base"), wakeupId)

            // Duplicate snooze is idempotent
            val fb2 = kernel.applyProactiveFeedback(
                signalId = "sig_snooze_base",
                action = app.amber.cloud.proactive.ProactiveFeedbackAction.SNOOZE,
                snoozeMinutes = 120,
                nowEpochMs = eveningMs + 1000L,
            ) as CloudAgentKernel.ProactiveFeedbackResult.Applied
            assertFalse(fb2.applied)
            assertEquals(wakeupId, fb2.wakeupId)
            assertEquals(1, kernel.proactiveWakeupStore.listPending().size)

            // Verify 0600 file permissions on wakeups.json
            val wakeupsFile = File(dir, "proactive/wakeups.json")
            assertTrue(wakeupsFile.exists())
            assertEquals("rw-------", PosixFilePermissions.toString(Files.getPosixFilePermissions(wakeupsFile.toPath())))

            // Fire at 23:30 (inside quiet hours 23:00-08:00) -> userRequested snooze penetrates quiet hours as URGENT, 0 L2 calls!
            l2Calls.set(0)
            val l2CountBefore = kernel.proactiveEngine.metrics().l2ModelCallCount
            capturedPushes.clear()
            val nightDueMs = eveningMs + 60 * 60_000L
            val results = kernel.runProactiveCycle(nowOverrideMs = nightDueMs)
            assertEquals(1, results.size)
            val pushed = assertIs<ProactiveRunResult.PushedAtL3>(results.single())
            assertEquals(0, l2Calls.get(), "snooze 唤醒必须 0 次 L2 模型调用")
            assertEquals(l2CountBefore, kernel.proactiveEngine.metrics().l2ModelCallCount, "ProactiveEngine L2 计数不得增长")
            assertEquals(ProactiveUrgency.URGENT, pushed.restraintVerdict.urgency)
            assertFalse(pushed.restraintVerdict.silentDelivery)
            assertEquals(1, capturedPushes.size)
            assertEquals("time-sensitive", capturedPushes.single().interruptionLevel)
            assertEquals(ProactiveWakeupRecord.STATUS_FIRED, kernel.proactiveWakeupStore.get(wakeupId)?.status)

            // Next cycle does not re-fire
            assertTrue(kernel.runProactiveCycle(nowOverrideMs = nightDueMs + 60_000L).isEmpty())
        } finally {
            closeKernel(kernel)
        }
    }

    @Test
    fun `IM callback intercepts pa buttons for owner only swallows legacy buttons and reenters act from stored event`() = runBlocking {
        val dir = Files.createTempDirectory("proactive-p1-im").toFile()
        val l2Client = CloudModelClient { _, _ ->
            UIMessage.assistant(
                """{"noteworthy":true,"urgency":4,"importance":4,"actionable":true,"recommended_channel":"im_direct","summary":"服务器磁盘占用达到 90%"}"""
            )
        }
        val kernel = CloudAgentKernel(dir, l2Client, masterSecretOverride = "p1-im-secret")
        try {
            val connector = TestConnector(ChannelKind.TELEGRAM)
            kernel.registerConnector(connector)
            val ingress = assertNotNull(connector.attachedIngress)

            val routerCalls = AtomicInteger(0)
            val routerPrompts = CopyOnWriteArrayList<String>()
            kernel.router.brain = RouterBrain { input ->
                routerCalls.incrementAndGet()
                routerPrompts.add(input.batchPrompt)
                RouterDecision(reply = "已收到处理请求")
            }

            val nowMs = epochMsAt(2026, 11, 26, 14, 0)
            val sig = ProactiveTriggerSignal.EdgeNodeSensorSignal(
                signalId = "sig_im_01",
                nodeId = "prod-1",
                eventKind = "disk",
                deduplicationKey = "disk-90",
                summaryText = "prod-1 /var 分区已用 90%",
                topicKey = "edge:prod-1:disk",
                timestampEpochMs = nowMs,
            )
            assertIs<ProactiveRunResult.PushedAtL3>(kernel.triggerProactiveSignal(sig, nowOverrideMs = nowMs))

            // 1. Guest DM pa:mute -> ignored, 0 router calls, topic NOT muted
            val guestReply = ingress.handleInbound(
                InboundMessage(
                    channel = ChannelKind.TELEGRAM,
                    messageId = "cb-guest-1",
                    chatId = "chat-guest",
                    senderId = "guest-1",
                    senderRole = SenderRole.GUEST,
                    scope = ConversationScope.DIRECT,
                    text = "pa:mute:sig_im_01",
                    callbackData = "pa:mute:sig_im_01",
                )
            )
            assertEquals("", guestReply.text)
            assertEquals(0, kernel.proactiveEngine.restraintGate.statusSnapshot().mutedTopics.size)

            // 2. Owner GROUP pa:mute -> ignored, 0 router calls, topic NOT muted
            val groupReply = ingress.handleInbound(
                InboundMessage(
                    channel = ChannelKind.TELEGRAM,
                    messageId = "cb-group-1",
                    chatId = "group-1",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    scope = ConversationScope.GROUP,
                    text = "pa:mute:sig_im_01",
                    callbackData = "pa:mute:sig_im_01",
                )
            )
            assertEquals("", groupReply.text)
            assertEquals(0, kernel.proactiveEngine.restraintGate.statusSnapshot().mutedTopics.size)

            // 3. Legacy proactive:* button -> swallowed with expired message, 0 router calls
            val legacyReply = ingress.handleInbound(
                InboundMessage(
                    channel = ChannelKind.TELEGRAM,
                    messageId = "cb-legacy-1",
                    chatId = "owner-chat",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    scope = ConversationScope.DIRECT,
                    text = "proactive:mute:watchtower:https://example.com",
                    callbackData = "proactive:mute:watchtower:https://example.com",
                )
            )
            assertTrue(legacyReply.text.contains("已过期"))

            // 4. Owner DM pa:mute -> mutes topic, returns short confirmation, 0 router calls
            val muteReply = ingress.handleInbound(
                InboundMessage(
                    channel = ChannelKind.TELEGRAM,
                    messageId = "cb-owner-mute-1",
                    chatId = "owner-chat",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    scope = ConversationScope.DIRECT,
                    text = "pa:mute:sig_im_01",
                    callbackData = "pa:mute:sig_im_01",
                )
            )
            assertTrue(muteReply.text.contains("静音"))
            assertEquals(1, kernel.proactiveEngine.restraintGate.statusSnapshot().mutedTopics.size)

            // 5. Owner DM pa:snooze -> creates wakeup, 0 router calls
            val snoozeReply = ingress.handleInbound(
                InboundMessage(
                    channel = ChannelKind.TELEGRAM,
                    messageId = "cb-owner-snooze-1",
                    chatId = "owner-chat",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    scope = ConversationScope.DIRECT,
                    text = "pa:snooze:sig_im_01",
                    callbackData = "pa:snooze:sig_im_01",
                )
            )
            assertTrue(snoozeReply.text.contains("1 小时"))
            assertEquals(1, kernel.proactiveWakeupStore.listPending().size)

            // 6. Owner DM pa:act for missing signal -> expired reply, 0 router calls
            val missingActReply = ingress.handleInbound(
                InboundMessage(
                    channel = ChannelKind.TELEGRAM,
                    messageId = "cb-owner-act-missing",
                    chatId = "owner-chat",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    scope = ConversationScope.DIRECT,
                    text = "forged payload",
                    callbackData = "pa:act:missing_signal_404",
                )
            )
            assertTrue(missingActReply.text.contains("已过期"))

            // Give async router loop a brief moment and verify 0 router calls across all non-act callbacks
            delay(150)
            assertEquals(0, routerCalls.get(), "非 act 的 IM 回调严禁进入 Router")

            // 7. Owner DM pa:act on valid signal -> builds prompt from server-stored event (ignores callback text) and enters Router
            ingress.handleInbound(
                InboundMessage(
                    channel = ChannelKind.TELEGRAM,
                    messageId = "cb-owner-act-1",
                    chatId = "owner-chat",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    scope = ConversationScope.DIRECT,
                    text = "INJECTED_CALLBACK_TEXT_MUST_BE_IGNORED",
                    callbackData = "pa:act:sig_im_01",
                )
            )
            val deadline = System.currentTimeMillis() + 3_000L
            while (routerCalls.get() == 0 && System.currentTimeMillis() < deadline) {
                delay(30)
            }
            assertEquals(1, routerCalls.get())
            val prompt = routerPrompts.single()
            assertTrue(prompt.contains("prod-1 /var 分区已用 90%") || prompt.contains("服务器磁盘占用达到 90%"))
            assertFalse(prompt.contains("INJECTED_CALLBACK_TEXT_MUST_BE_IGNORED"))
            assertTrue(kernel.proactiveRunHistoryStore.recent(20).any { it.outcome == "feedback_replied" })
        } finally {
            closeKernel(kernel)
        }
    }

    @Test
    fun `pushConfigured false sends zero pushes and returns 503 on test-push while bootstrap configures valid p8`() = runBlocking {
        val dir = Files.createTempDirectory("proactive-p1-pushcfg").toFile()
        val pushCount = AtomicInteger(0)
        val l2Client = CloudModelClient { _, _ ->
            UIMessage.assistant(
                """{"noteworthy":true,"urgency":5,"importance":5,"actionable":true,"recommended_channel":"im_direct","summary":"高优提醒"}"""
            )
        }
        val kernel = CloudAgentKernel(dir, l2Client, masterSecretOverride = "p1-pushcfg-secret")
        try {
            val ios = pairIosWithPush(kernel)
            assertFalse(kernel.gatewayState.pushConfigured)
            kernel.gatewayState.pushSender = PushSender {
                pushCount.incrementAndGet()
                Result.success(Unit)
            }
            kernel.gatewayState.pushConfigured = false

            val nowMs = epochMsAt(2026, 11, 26, 15, 0)
            val sig = ProactiveTriggerSignal.EdgeNodeSensorSignal(
                signalId = "sig_no_apns",
                nodeId = "mac",
                eventKind = "done",
                deduplicationKey = "no-apns-1",
                summaryText = "未配置 APNs 时不应调用 pushSender",
                timestampEpochMs = nowMs,
            )
            assertIs<ProactiveRunResult.PushedAtL3>(kernel.triggerProactiveSignal(sig, nowOverrideMs = nowMs))
            assertEquals(0, pushCount.get(), "pushConfigured=false 时必须零发送")

            testApplication {
                application { configureCloudGateway(kernel.gatewayState, agentApi = AgentCentricApi(kernel)) }
                val testPushResp = client.post("/v1/test-push") { bearerAuth(ios.token) }
                assertEquals(503, testPushResp.status.value)
                assertTrue(testPushResp.bodyAsText().contains("push_not_configured"))
            }
        } finally {
            closeKernel(kernel)
        }

        // Verify loadConfiguredDaemon APNs bootstrap: missing config -> false; valid P-256 p8 file -> true
        val bootDir1 = Files.createTempDirectory("proactive-p1-boot-noapns").toFile()
        val masterEnv = mapOf("AMBER_MASTER_KEY" to "test-master-key-for-apns-boot-01", "AMBER_MODEL_PROVIDER" to "echo")
        val daemonNoApns = loadConfiguredDaemon(bootDir1, env = masterEnv)
        try {
            assertFalse(daemonNoApns.kernel.gatewayState.pushConfigured)
        } finally {
            closeKernel(daemonNoApns.kernel)
        }

        val bootDir2 = Files.createTempDirectory("proactive-p1-boot-apns").toFile()
        val keyPair = KeyPairGenerator.getInstance("EC").apply {
            initialize(ECGenParameterSpec("secp256r1"))
        }.generateKeyPair()
        val pem = buildString {
            appendLine("-----BEGIN PRIVATE KEY-----")
            appendLine(Base64.getMimeEncoder(64, "\n".toByteArray()).encodeToString(keyPair.private.encoded))
            appendLine("-----END PRIVATE KEY-----")
        }
        val p8File = File(bootDir2, "test-apns.p8").apply { writeText(pem) }
        val daemonWithApns = loadConfiguredDaemon(
            bootDir2,
            env = masterEnv + mapOf(
                CloudConfigLoader.ENV_APNS_KEY_ID to "TESTKEY123",
                CloudConfigLoader.ENV_APNS_TEAM_ID to "TEAM123456",
                CloudConfigLoader.ENV_APNS_TOPIC to "app.amber.ios",
                CloudConfigLoader.ENV_APNS_P8_FILE to p8File.absolutePath,
            ),
        )
        try {
            assertTrue(daemonWithApns.kernel.gatewayState.pushConfigured)
        } finally {
            closeKernel(daemonWithApns.kernel)
        }
    }

    @Test
    fun `restart replays wakeup overdue by 12h or less once and expires wakeup overdue over 12h into pulse buffer`() = runBlocking {
        val dir = Files.createTempDirectory("proactive-p1-overdue").toFile()
        val l2Calls = AtomicInteger(0)
        val l2Client = CloudModelClient { messages, _ ->
            if (messages.any { it.toText().contains("<untrusted_signal>") }) {
                l2Calls.incrementAndGet()
            }
            UIMessage.assistant("""{"noteworthy":false,"urgency":1,"importance":1,"actionable":false,"recommended_channel":"pulse","summary":"x"}""")
        }
        val restartNowMs = epochMsAt(2026, 11, 26, 16, 0)
        val within12hMs = restartNowMs - 6 * 3_600_000L
        val over12hMs = restartNowMs - 13 * 3_600_000L

        val recentId: String
        val staleId: String
        val kernel1 = CloudAgentKernel(dir, l2Client, masterSecretOverride = "p1-overdue-secret")
        try {
            recentId = kernel1.proactiveWakeupStore.create(
                kind = ProactiveWakeupRecord.KIND_SNOOZE,
                title = "6 小时前到期的延后提醒",
                detail = "检查部署状态",
                triggerAtEpochMs = within12hMs,
                userRequested = true,
                nowEpochMs = within12hMs - 3_600_000L,
            ).id
            staleId = kernel1.proactiveWakeupStore.create(
                kind = ProactiveWakeupRecord.KIND_SNOOZE,
                title = "13 小时前到期的过期提醒",
                detail = "早已过期的提醒",
                triggerAtEpochMs = over12hMs,
                userRequested = true,
                nowEpochMs = over12hMs - 3_600_000L,
            ).id
        } finally {
            closeKernel(kernel1)
        }

        // Simulate daemon restart on same dataDir
        val kernel2 = CloudAgentKernel(dir, l2Client, masterSecretOverride = "p1-overdue-secret")
        try {
            val firstCycle = kernel2.runProactiveCycle(nowOverrideMs = restartNowMs)
            assertEquals(1, firstCycle.size, "仅逾期 <= 12h 的唤醒应补发")
            val pushed = assertIs<ProactiveRunResult.PushedAtL3>(firstCycle.single())
            assertEquals(recentId, pushed.l1Delta.wakeupId)
            assertEquals(0, l2Calls.get())
            assertEquals(0, kernel2.proactiveEngine.metrics().l2ModelCallCount)

            assertEquals(ProactiveWakeupRecord.STATUS_FIRED, kernel2.proactiveWakeupStore.get(recentId)?.status)
            assertEquals(ProactiveWakeupRecord.STATUS_EXPIRED, kernel2.proactiveWakeupStore.get(staleId)?.status)

            val pulseItems = kernel2.proactiveEngine.restraintGate.peekBufferedPulseItems()
            assertTrue(pulseItems.any { it.contains("13 小时前到期的过期提醒") }, "逾期 > 12h 必须转入 Pulse 缓冲")
            assertTrue(kernel2.proactiveRunHistoryStore.recent(20).any { it.outcome == "wakeup_expired" })

            // Second cycle after restart does not re-fire
            assertTrue(kernel2.runProactiveCycle(nowOverrideMs = restartNowMs + 60_000L).isEmpty())
        } finally {
            closeKernel(kernel2)
        }
    }
}
