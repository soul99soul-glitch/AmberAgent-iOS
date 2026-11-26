package app.amber.cloud

import app.amber.ai.ui.UIMessage
import app.amber.cloud.channel.ChannelConnector
import app.amber.cloud.channel.ChannelIngress
import app.amber.cloud.channel.ChannelKind
import app.amber.cloud.channel.OutboundMessage
import app.amber.cloud.gateway.AgentCentricApi
import app.amber.cloud.gateway.CloudGatewayState
import app.amber.cloud.gateway.PushMessagePayload
import app.amber.cloud.gateway.PushSender
import app.amber.cloud.gateway.configureCloudGateway
import app.amber.cloud.orchestration.CloudPrincipal
import app.amber.cloud.proactive.InterruptionBudgetConfig
import app.amber.cloud.proactive.L1DeterministicFilter
import app.amber.cloud.proactive.ProactiveEngine
import app.amber.cloud.proactive.ProactiveFeedbackAction
import app.amber.cloud.proactive.ProactiveMonitorRecord
import app.amber.cloud.proactive.ProactiveMonitorStore
import app.amber.cloud.proactive.ProactiveRestraintGate
import app.amber.cloud.proactive.ProactiveRunResult
import app.amber.cloud.proactive.ProactiveTriggerSignal
import app.amber.cloud.proactive.ProactiveUrgency
import app.amber.cloud.proactive.QuietHoursConfig
import app.amber.cloud.proactive.RestraintVerdict
import app.amber.cloud.proactive.CloudProactiveL2Judge
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.runtime.ExecutionScope
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.bearerAuth
import io.ktor.client.request.get
import io.ktor.client.request.patch
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.http.headersOf
import io.ktor.server.testing.testApplication
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import java.net.InetAddress
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CloudProactivePhase3Test {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val shanghai = ZoneId.of("Asia/Shanghai")
    private val publicIpResolver: (String) -> List<InetAddress> = {
        listOf(InetAddress.getByName("93.184.216.34"))
    }

    private fun epochMsAt(year: Int, month: Int, day: Int, hour: Int, minute: Int): Long =
        LocalDateTime.of(year, month, day, hour, minute)
            .atZone(shanghai)
            .toInstant()
            .toEpochMilli()

    private fun closeKernel(kernel: CloudAgentKernel) = runBlocking {
        kernel.stopProactiveLoop()
        kernel.commitmentExtractor.closeAndJoin()
        kernel.conversationTagger.closeAndJoin()
        kernel.supertagStore.close()
        kernel.agentRegistry.close()
        kernel.orchestrationStore.close()
    }

    private fun pairIosDevice(
        kernel: CloudAgentKernel,
        name: String = "Owner iPhone",
        pushToken: String? = "apns-token-p3-001",
    ): CloudGatewayState.PairResult.Success {
        val ticket = kernel.gatewayState.issuePairingTicket()
        val paired = kernel.gatewayState.pairDevice(ticket, "ios", name) as CloudGatewayState.PairResult.Success
        if (pushToken != null) {
            val device = kernel.gatewayState.findDeviceById(paired.deviceId)!!
            val (status, _) = kernel.gatewayState.registerPushToken(device, pushToken, "production")
            assertEquals(200, status)
        }
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

    // -----------------------------------------------------------------
    // 1. REST API: POST & PATCH /v2/proactive/monitors deliveryMode
    // -----------------------------------------------------------------

    @Test
    fun `monitor routes support deliveryMode create patch validation summary and legacy json defaults`(): Unit = testApplication {
        val dir = Files.createTempDirectory("proactive-p3-routes").toFile()
        val proactiveDir = File(dir, "proactive").also { it.mkdirs() }
        // 写入一条旧版无 deliveryMode 字段的 monitors.json 验证向后兼容默认 immediate
        File(proactiveDir, "monitors.json").writeText(
            """
            [
              {
                "id": "mon_legacy01",
                "title": "旧版监控",
                "url": "https://example.com/legacy",
                "conditionPrompt": "",
                "intervalMinutes": 15,
                "enabled": true,
                "createdAtMs": 1700000000000,
                "nextRunAtMs": 1700000000000
              }
            ]
            """.trimIndent(),
            StandardCharsets.UTF_8,
        )

        val kernel = CloudAgentKernel(
            dataDir = dir,
            modelClient = CloudModelClient { _, _ -> UIMessage.assistant("ok") },
            masterSecretOverride = "p3-routes-secret",
        )
        application {
            configureCloudGateway(kernel.gatewayState, agentApi = AgentCentricApi(kernel))
        }

        try {
            assertEquals(
                ProactiveMonitorRecord.DELIVERY_MODE_IMMEDIATE,
                kernel.proactiveMonitorStore.get("mon_legacy01")?.deliveryMode,
            )

            val paired = pairIosDevice(kernel)

            // 1. POST 默认不传 deliveryMode -> immediate
            val postDefault = client.post("/v2/proactive/monitors") {
                bearerAuth(paired.token)
                contentType(ContentType.Application.Json)
                setBody("""{"title":"价格监控","url":"https://example.com/pricing"}""")
            }
            assertEquals(HttpStatusCode.Created, postDefault.status)
            val mon1 = json.parseToJsonElement(postDefault.bodyAsText()).jsonObject["monitor"]!!.jsonObject
            val mon1Id = mon1["id"]!!.jsonPrimitive.content
            assertEquals("immediate", mon1["deliveryMode"]!!.jsonPrimitive.content)

            // 2. POST 指定 deliveryMode = "digest"
            val postDigest = client.post("/v2/proactive/monitors") {
                bearerAuth(paired.token)
                contentType(ContentType.Application.Json)
                setBody("""{"title":"Release 摘要","url":"https://github.com/amber/demo/releases.atom","deliveryMode":"digest"}""")
            }
            assertEquals(HttpStatusCode.Created, postDigest.status)
            val mon2 = json.parseToJsonElement(postDigest.bodyAsText()).jsonObject["monitor"]!!.jsonObject
            val mon2Id = mon2["id"]!!.jsonPrimitive.content
            assertEquals("digest", mon2["deliveryMode"]!!.jsonPrimitive.content)

            // 3. POST 指定 snake_case delivery_mode = "digest"
            val postSnake = client.post("/v2/proactive/monitors") {
                bearerAuth(paired.token)
                contentType(ContentType.Application.Json)
                setBody("""{"title":"博客更新","url":"https://example.com/blog.xml","delivery_mode":"digest"}""")
            }
            assertEquals(HttpStatusCode.Created, postSnake.status)
            assertEquals(
                "digest",
                json.parseToJsonElement(postSnake.bodyAsText()).jsonObject["monitor"]!!.jsonObject["deliveryMode"]!!.jsonPrimitive.content,
            )

            // 4. POST 非法值 -> 400
            val postInvalid = client.post("/v2/proactive/monitors") {
                bearerAuth(paired.token)
                contentType(ContentType.Application.Json)
                setBody("""{"title":"非法模式","url":"https://example.com/bad","deliveryMode":"weekly"}""")
            }
            assertEquals(HttpStatusCode.BadRequest, postInvalid.status)

            val postNonString = client.post("/v2/proactive/monitors") {
                bearerAuth(paired.token)
                contentType(ContentType.Application.Json)
                setBody("""{"title":"非法类型","url":"https://example.com/bad2","deliveryMode":123}""")
            }
            assertEquals(HttpStatusCode.BadRequest, postNonString.status)

            // 5. PATCH 切换 deliveryMode: immediate -> digest -> immediate
            val patchToDigest = client.patch("/v2/proactive/monitors/$mon1Id") {
                bearerAuth(paired.token)
                contentType(ContentType.Application.Json)
                setBody("""{"deliveryMode":"digest"}""")
            }
            assertEquals(HttpStatusCode.OK, patchToDigest.status)
            assertEquals(
                "digest",
                json.parseToJsonElement(patchToDigest.bodyAsText()).jsonObject["monitor"]!!.jsonObject["deliveryMode"]!!.jsonPrimitive.content,
            )

            val patchToImmediate = client.patch("/v2/proactive/monitors/$mon2Id") {
                bearerAuth(paired.token)
                contentType(ContentType.Application.Json)
                setBody("""{"delivery_mode":"immediate"}""")
            }
            assertEquals(HttpStatusCode.OK, patchToImmediate.status)
            assertEquals(
                "immediate",
                json.parseToJsonElement(patchToImmediate.bodyAsText()).jsonObject["monitor"]!!.jsonObject["deliveryMode"]!!.jsonPrimitive.content,
            )

            // 6. PATCH 非法值 -> 400
            val patchInvalid = client.patch("/v2/proactive/monitors/$mon1Id") {
                bearerAuth(paired.token)
                contentType(ContentType.Application.Json)
                setBody("""{"deliveryMode":"hourly"}""")
            }
            assertEquals(HttpStatusCode.BadRequest, patchInvalid.status)

            // 7. GET /v2/proactive/summary 返回最新 deliveryMode
            val summaryResp = client.get("/v2/proactive/summary") {
                bearerAuth(paired.token)
            }
            assertEquals(HttpStatusCode.OK, summaryResp.status)
            val monitors = json.parseToJsonElement(summaryResp.bodyAsText()).jsonObject["monitors"]!!.jsonArray
            val byId = monitors.associate {
                it.jsonObject["id"]!!.jsonPrimitive.content to it.jsonObject["deliveryMode"]!!.jsonPrimitive.content
            }
            assertEquals("immediate", byId["mon_legacy01"])
            assertEquals("digest", byId[mon1Id])
            assertEquals("immediate", byId[mon2Id])
        } finally {
            closeKernel(kernel)
        }
    }

    // -----------------------------------------------------------------
    // 2. 内置工具: proactive_monitor_create / update / list
    // -----------------------------------------------------------------

    @Test
    fun `proactive monitor builtin tools support delivery_mode create update list and validate values`(): Unit = runBlocking {
        val dir = Files.createTempDirectory("proactive-p3-tools").toFile()
        val kernel = CloudAgentKernel(
            dataDir = dir,
            modelClient = CloudModelClient { _, _ -> UIMessage.assistant("ok") },
            masterSecretOverride = "p3-tools-secret",
        )
        try {
            // 校验 schema 包含 delivery_mode 枚举
            val owner = CloudPrincipal.OwnerUser("owner-1", "app")
            val declared = kernel.toolRegistry.declaredTools(ExecutionScope.MAIN_AGENT, principal = owner)
            val createSchema = declared.first { it.name == "proactive_monitor_create" }.parameters().toString()
            val updateSchema = declared.first { it.name == "proactive_monitor_update" }.parameters().toString()
            assertTrue(createSchema.contains("delivery_mode"))
            assertTrue(createSchema.contains("digest"))
            assertTrue(updateSchema.contains("delivery_mode"))
            assertTrue(updateSchema.contains("digest"))

            // create with delivery_mode = "digest"
            val createdRes = kernel.toolRegistry.executeGate(
                toolName = "proactive_monitor_create",
                args = buildJsonObject {
                    put("title", "Kotlin Releases")
                    put("url", "https://github.com/JetBrains/kotlin/releases.atom")
                    put("delivery_mode", "digest")
                },
                scope = ExecutionScope.MAIN_AGENT,
                principal = CloudPrincipal.OwnerUser("owner-1", "app"),
            ).jsonObject
            assertTrue(createdRes["ok"]!!.jsonPrimitive.boolean)
            val createdMon = createdRes["monitor"]!!.jsonObject
            val monId = createdMon["id"]!!.jsonPrimitive.content
            assertEquals("digest", createdMon["deliveryMode"]!!.jsonPrimitive.content)

            // list 输出包含 deliveryMode
            val listRes = kernel.toolRegistry.executeGate(
                toolName = "proactive_monitor_list",
                args = buildJsonObject {},
                scope = ExecutionScope.MAIN_AGENT,
                principal = CloudPrincipal.OwnerUser("owner-1", "app"),
            ).jsonObject
            assertTrue(listRes["ok"]!!.jsonPrimitive.boolean)
            val listedMon = listRes["monitors"]!!.jsonArray.single().jsonObject
            assertEquals(monId, listedMon["id"]!!.jsonPrimitive.content)
            assertEquals("digest", listedMon["deliveryMode"]!!.jsonPrimitive.content)

            // update 切换为 immediate
            val updatedRes = kernel.toolRegistry.executeGate(
                toolName = "proactive_monitor_update",
                args = buildJsonObject {
                    put("id", monId)
                    put("delivery_mode", "immediate")
                },
                scope = ExecutionScope.MAIN_AGENT,
                principal = CloudPrincipal.OwnerUser("owner-1", "app"),
            ).jsonObject
            assertTrue(updatedRes["ok"]!!.jsonPrimitive.boolean)
            assertEquals("immediate", updatedRes["monitor"]!!.jsonObject["deliveryMode"]!!.jsonPrimitive.content)

            // update 切回 digest
            val updatedBack = kernel.toolRegistry.executeGate(
                toolName = "proactive_monitor_update",
                args = buildJsonObject {
                    put("id", monId)
                    put("delivery_mode", "digest")
                },
                scope = ExecutionScope.MAIN_AGENT,
                principal = CloudPrincipal.OwnerUser("owner-1", "app"),
            ).jsonObject
            assertTrue(updatedBack["ok"]!!.jsonPrimitive.boolean)
            assertEquals("digest", updatedBack["monitor"]!!.jsonObject["deliveryMode"]!!.jsonPrimitive.content)

            // 非法 delivery_mode 拒绝并返回 ok = false
            val badCreate = kernel.toolRegistry.executeGate(
                toolName = "proactive_monitor_create",
                args = buildJsonObject {
                    put("title", "Bad")
                    put("url", "https://example.com/bad")
                    put("delivery_mode", "monthly")
                },
                scope = ExecutionScope.MAIN_AGENT,
                principal = CloudPrincipal.OwnerUser("owner-1", "app"),
            ).jsonObject
            assertFalse(badCreate["ok"]!!.jsonPrimitive.boolean)

            val badUpdate = kernel.toolRegistry.executeGate(
                toolName = "proactive_monitor_update",
                args = buildJsonObject {
                    put("id", monId)
                    put("delivery_mode", "unknown")
                },
                scope = ExecutionScope.MAIN_AGENT,
                principal = CloudPrincipal.OwnerUser("owner-1", "app"),
            ).jsonObject
            assertFalse(badUpdate["ok"]!!.jsonPrimitive.boolean)
        } finally {
            closeKernel(kernel)
        }
    }

    // -----------------------------------------------------------------
    // 3. 端到端链路：digest Watchtower 缓冲 -> 次日晨报零 L2 汇总推送
    // -----------------------------------------------------------------

    @Test
    fun `digest watchtower monitor buffers change without instant card and delivers in next morning pulse with 0 L2 calls`(): Unit = runBlocking {
        val dir = Files.createTempDirectory("proactive-p3-digest-e2e").toFile()
        val pageBody = AtomicReference("<feed><title>Amber Releases</title><entry><title>v3.2.0 Released</title></entry></feed>")
        val pageEtag = AtomicReference("\"rel-320\"")
        val l2Calls = AtomicInteger(0)
        val capturedPushes = CopyOnWriteArrayList<PushMessagePayload>()

        val mockHttp = HttpClient(
            MockEngine { request ->
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
                            HttpHeaders.ContentType to listOf("application/atom+xml; charset=utf-8"),
                            HttpHeaders.ETag to listOf(curEtag),
                        ),
                    )
                }
            }
        )

        val modelClient = CloudModelClient { messages, _ ->
            if (messages.any { it.toText().contains("<untrusted_signal>") }) {
                l2Calls.incrementAndGet()
            }
            UIMessage.assistant(
                """{"noteworthy":true,"urgency":3,"importance":4,"actionable":true,"recommended_channel":"pulse","summary":"Amber 发布新版本 v3.2.0，包含云端摘要模式"}"""
            )
        }

        val kernel = CloudAgentKernel(
            dataDir = dir,
            modelClient = modelClient,
            masterSecretOverride = "p3-digest-e2e-secret",
            proactiveHttpClient = mockHttp,
            proactiveDnsResolver = publicIpResolver,
        )
        val connector = TestConnector()
        kernel.registerConnector(connector)
        kernel.ownerBinding.bindOwnerDirectly(connector.kind.name.lowercase(), "owner-chat-1")
        kernel.gatewayState.pushConfigured = true
        kernel.gatewayState.pushSender = PushSender { payload ->
            capturedPushes.add(payload)
            Result.success(Unit)
        }

        try {
            pairIosDevice(kernel)

            val day1Afternoon = epochMsAt(2026, 11, 26, 14, 0)
            val monitor = kernel.proactiveMonitorStore.create(
                title = "Amber Releases",
                url = "https://github.com/amber/amber/releases.atom",
                conditionPrompt = "有新版本发布时汇总给我",
                intervalMinutes = 60,
                deliveryMode = ProactiveMonitorRecord.DELIVERY_MODE_DIGEST,
                nowMs = day1Afternoon,
            )

            // 第 1 阶段：白天网页变动 -> 经 L1(DIGEST) + L2 评分 -> 转入 Pulse 缓冲，不即时弹卡/不写即时事件/不扣普通预算
            val day1Results = kernel.runProactiveCycle(nowOverrideMs = day1Afternoon)
            assertEquals(1, day1Results.size)
            val suppressed = assertIs<ProactiveRunResult.SuppressedAtGate>(day1Results.single())
            assertEquals(ProactiveUrgency.DIGEST, suppressed.l1Delta.urgency)
            val deferred = assertIs<RestraintVerdict.DeferredByBudget>(suppressed.restraintVerdict)
            assertEquals("已转入 Pulse 汇总", deferred.reason)
            assertTrue(deferred.bufferedForMorningBriefing)

            assertEquals(1, l2Calls.get(), "Watchtower digest 变动需经 1 次 L2 判断 noteworthy 与生成摘要")
            assertTrue(connector.sent.isEmpty(), "digest 模式不得触发即时 IM 卡片")
            assertTrue(capturedPushes.isEmpty(), "digest 模式不得触发即时 APNs 推送")
            assertNull(
                kernel.orchestrationStore.dialogue.findEvent("proactive:${suppressed.l1Delta.signalId}"),
                "digest 模式不得写入即时 proactive_message 事件",
            )
            val snapDay1 = kernel.proactiveEngine.restraintGate.statusSnapshot(day1Afternoon)
            assertEquals(0, snapDay1.pushesToday, "digest 模式不得扣减普通日预算")
            assertEquals(1, snapDay1.bufferedPulseCount)
            assertEquals("digest", kernel.proactiveMonitorStore.get(monitor.id)?.lastOutcome)

            // 第 2 阶段：次日 08:35 晨报窗口 -> Watchtower 返回 304 (L1 dropped, 0 L2)，DailyPulse 零 L2 汇总晨报并投递
            val l2BeforeMorning = l2Calls.get()
            val day2Morning = epochMsAt(2026, 11, 27, 8, 35)
            val day2Results = kernel.runProactiveCycle(nowOverrideMs = day2Morning)

            val pulsePushed = day2Results.filterIsInstance<ProactiveRunResult.PushedAtL3>().single()
            assertTrue(pulsePushed.l1Delta.bypassL2ForScheduledBriefing)
            assertEquals("brief_2026-11-27", pulsePushed.l1Delta.signalId)
            assertTrue(
                pulsePushed.card.markdownBody.contains("Amber 发布新版本 v3.2.0，包含云端摘要模式"),
                "晨报必须包含前一天 digest 监控缓冲的摘要",
            )
            assertEquals(l2BeforeMorning, l2Calls.get(), "次日晨报汇总阶段必须保持 0 次新增 L2 模型调用")
            assertEquals(0, kernel.proactiveEngine.restraintGate.statusSnapshot(day2Morning).bufferedPulseCount)

            // 确认晨报已落库并投递到 IM 与 APNs
            val pulseEvent = kernel.orchestrationStore.dialogue.findEvent("proactive:brief_2026-11-27")
            assertNotNull(pulseEvent)
            assertTrue(pulseEvent.text.contains("Amber 发布新版本 v3.2.0"))
            assertEquals(1, connector.sent.size)
            assertEquals(1, capturedPushes.size)
            assertEquals("brief_2026-11-27", capturedPushes.single().signalId)
        } finally {
            mockHttp.close()
            closeKernel(kernel)
        }
    }

    // -----------------------------------------------------------------
    // 4. 端到端隐式忽略验证：同 topic 连续未读自动计忽略并衰减，反馈后恢复
    // -----------------------------------------------------------------

    @Test
    fun `end to end implicit ignore decays repeated unread pushes on same topic and resets after feedback`(): Unit = runBlocking {
        val dir = Files.createTempDirectory("proactive-p3-implicit-e2e").toFile()
        val proactiveDir = File(dir, "proactive").also { it.mkdirs() }
        val modelClient = CloudModelClient { _, _ ->
            // 综合分 3 * 4 = 12（高于默认阈值 9，低于衰减阈值 18）
            UIMessage.assistant(
                """{"noteworthy":true,"urgency":3,"importance":4,"actionable":true,"recommended_channel":"im_direct","summary":"同话题新动态"}"""
            )
        }
        val engine = ProactiveEngine(
            l1Filter = L1DeterministicFilter(persistenceFile = File(proactiveDir, "l1-filter.json")),
            l2Judge = CloudProactiveL2Judge(modelClient),
            restraintGate = ProactiveRestraintGate(
                quietHours = QuietHoursConfig(enabled = false),
                budgetConfig = InterruptionBudgetConfig(dailyMaxPushes = 10, topicCooldownMs = 0L),
                persistenceFile = File(proactiveDir, "restraint-gate.json"),
            ),
        )
        val kernel = CloudAgentKernel(
            dataDir = dir,
            modelClient = modelClient,
            masterSecretOverride = "p3-implicit-e2e-secret",
            proactiveEngine = engine,
        )
        val connector = TestConnector()
        kernel.registerConnector(connector)
        kernel.ownerBinding.bindOwnerDirectly(connector.kind.name.lowercase(), "owner-chat-1")

        try {
            val t0 = epochMsAt(2026, 11, 26, 10, 0)
            fun makeWebhookSignal(idx: Int): ProactiveTriggerSignal.WebhookInboundSignal =
                ProactiveTriggerSignal.WebhookInboundSignal(
                    signalId = "whsig_imp_$idx",
                    webhookId = "wh_feed",
                    webhookName = "新闻流",
                    deliveryId = "deliv_$idx",
                    instruction = "关注动态",
                    redactedPayload = """{"item":$idx}""",
                    topicKey = "webhook:wh_feed",
                    timestampEpochMs = t0 + idx * 60_000L,
                )

            // 第 1、2、3 次推送均无反馈 -> 均成功推送并写入 DialogueEventStore
            for (i in 1..3) {
                val res = kernel.triggerProactiveSignal(makeWebhookSignal(i), nowOverrideMs = t0 + i * 60_000L)
                assertIs<ProactiveRunResult.PushedAtL3>(res, "第 $i 次推送应放行")
                assertNotNull(kernel.orchestrationStore.dialogue.findEvent("proactive:whsig_imp_$i"))
            }
            assertEquals(3, connector.sent.size)

            // 第 4 次同 topic 推送：结算第 3 张未读后累计 3 次忽略 -> 阈值衰减至 18 -> score=12 被拦截
            val fourth = kernel.triggerProactiveSignal(makeWebhookSignal(4), nowOverrideMs = t0 + 4 * 60_000L)
            val suppressed = assertIs<ProactiveRunResult.SuppressedAtGate>(fourth)
            val dropped = assertIs<RestraintVerdict.DroppedLowScore>(suppressed.restraintVerdict)
            assertEquals(18, dropped.requiredScore)
            assertEquals(3, connector.sent.size, "触发衰减后不应再即时推送")
            assertNull(kernel.orchestrationStore.dialogue.findEvent("proactive:whsig_imp_4"))

            // 用户对第 3 张卡点开反馈（OPENED）-> 重置忽略计数并清除 pending -> 第 5 次恢复正常推送
            val fb = kernel.applyProactiveFeedback(
                signalId = "whsig_imp_3",
                action = ProactiveFeedbackAction.OPENED,
                nowEpochMs = t0 + 5 * 60_000L,
            )
            val applied = assertIs<CloudAgentKernel.ProactiveFeedbackResult.Applied>(fb)
            assertTrue(applied.applied)

            val fifth = kernel.triggerProactiveSignal(makeWebhookSignal(5), nowOverrideMs = t0 + 6 * 60_000L)
            assertIs<ProactiveRunResult.PushedAtL3>(fifth)
            assertEquals(4, connector.sent.size)
            assertNotNull(kernel.orchestrationStore.dialogue.findEvent("proactive:whsig_imp_5"))
            Unit
        } finally {
            closeKernel(kernel)
        }
    }
}
