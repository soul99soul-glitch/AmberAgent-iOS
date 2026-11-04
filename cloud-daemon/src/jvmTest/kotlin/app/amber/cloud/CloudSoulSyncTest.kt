package app.amber.cloud

import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.channel.ChannelConnector
import app.amber.cloud.channel.ChannelIngress
import app.amber.cloud.channel.ChannelKind
import app.amber.cloud.channel.ConversationScope
import app.amber.cloud.channel.InboundMessage
import app.amber.cloud.channel.OutboundMessage
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.gateway.AgentCentricApi
import app.amber.cloud.gateway.CloudGatewayState
import app.amber.cloud.gateway.configureCloudGateway
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.soul.CloudSoulStore
import app.amber.cloud.soul.SoulStateDto
import io.ktor.client.request.bearerAuth
import io.ktor.client.request.get
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.server.testing.testApplication
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CloudSoulSyncTest {
    private val json = Json { ignoreUnknownKeys = true }

    private class FakeImConnector : ChannelConnector {
        override val kind = ChannelKind.FEISHU
        lateinit var ingress: ChannelIngress
        val outbound = CopyOnWriteArrayList<OutboundMessage>()
        override fun attachIngress(ingress: ChannelIngress) { this.ingress = ingress }
        override suspend fun start() = Unit
        override suspend fun stop() = Unit
        override suspend fun send(message: OutboundMessage): Result<String> {
            outbound += message
            return Result.success("msg-${outbound.size}")
        }
    }

    @Test
    fun c_soul_v1_http_get_put_monotonic_revision_history_and_status_timeline_sync() = testApplication {
        val dir = Files.createTempDirectory("amber-soul-http").toFile()
        val kernel = CloudAgentKernel(
            dataDir = dir,
            modelClient = CloudModelClient { _, _ -> UIMessage.assistant("好。") },
            masterSecretOverride = "soul-http-test-secret",
        )
        val paired = kernel.gatewayState.pairDevice(
            secret = kernel.gatewayState.issuePairingTicket(),
            platform = "macos",
            deviceName = "Test Mac",
        ) as CloudGatewayState.PairResult.Success

        application {
            configureCloudGateway(kernel.gatewayState, agentApi = AgentCentricApi(kernel))
        }

        try {
            // 1. Auth required
            assertEquals(401, client.get("/v2/soul").status.value)
            assertEquals(401, client.put("/v2/soul") { setBody("{}") }.status.value)

            // 2. Initial default state (revision = 0)
            val initResp = client.get("/v2/soul") { bearerAuth(paired.token) }
            assertEquals(200, initResp.status.value)
            val initSoul = json.decodeFromString<SoulStateDto>(initResp.bodyAsText())
            assertEquals(0L, initSoul.revision)
            assertTrue(initSoul.isDefault)
            assertEquals("Amber", initSoul.displayName)
            assertEquals("", initSoul.tagline)
            assertEquals("", initSoul.soulMarkdown)
            assertTrue(initSoul.history.isEmpty())

            assertEquals(0L, statusSoulRevision(paired.token))
            assertEquals(0L, timelineSoulRevision("/v2/timeline", paired.token))
            assertEquals(0L, timelineSoulRevision("/v2/dialogue/timeline", paired.token))
            assertEquals(0L, eventsSoulRevision(paired.token))

            // 3. PUT custom persona -> revision = 1, propagated across status & timeline & dialogue events
            val putBody = """
                {
                  "displayName": "赵匡胤",
                  "tagline": "痛饮黄龙、有事直说的宋太祖大哥",
                  "soulMarkdown": "## 身份与称呼\n以赵大哥自居，豪爽直率。",
                  "isDefault": false,
                  "updatedAtMs": 1793750400000,
                  "source": "manual"
                }
            """.trimIndent()
            val put1 = client.put("/v2/soul") {
                bearerAuth(paired.token)
                contentType(ContentType.Application.Json)
                setBody(putBody)
            }
            assertEquals(200, put1.status.value)
            val soul1 = json.decodeFromString<SoulStateDto>(put1.bodyAsText())
            assertEquals(1L, soul1.revision)
            assertFalse(soul1.isDefault)
            assertEquals("赵匡胤", soul1.displayName)
            assertEquals("痛饮黄龙、有事直说的宋太祖大哥", soul1.tagline)
            assertEquals(1, soul1.history.size)
            assertEquals("Amber", soul1.history.single().displayName)

            assertEquals(1L, statusSoulRevision(paired.token))
            assertEquals(1L, timelineSoulRevision("/v2/timeline", paired.token))
            assertEquals(1L, timelineSoulRevision("/v2/dialogue/timeline", paired.token))
            assertEquals(1L, eventsSoulRevision(paired.token))

            // Idempotent re-PUT of identical content does not bump revision or pollute history
            val dup = client.put("/v2/soul") {
                bearerAuth(paired.token)
                contentType(ContentType.Application.Json)
                setBody(putBody)
            }
            assertEquals(1L, json.decodeFromString<SoulStateDto>(dup.bodyAsText()).revision)

            // 4. Push 9 more updates -> history capped at 8
            for (i in 2..10) {
                val r = client.put("/v2/soul") {
                    bearerAuth(paired.token)
                    contentType(ContentType.Application.Json)
                    setBody("""{"displayName":"人设$i","tagline":"签名$i","soulMarkdown":"内容$i"}""")
                }
                assertEquals(200, r.status.value)
            }
            val soul10 = json.decodeFromString<SoulStateDto>(client.get("/v2/soul") { bearerAuth(paired.token) }.bodyAsText())
            assertEquals(10L, soul10.revision)
            assertEquals(8, soul10.history.size)
            assertEquals("人设9", soul10.history.first().displayName)

            // 5. Reset to default Amber -> revision still increments monotonically (10 -> 11)
            val resetResp = client.put("/v2/soul") {
                bearerAuth(paired.token)
                contentType(ContentType.Application.Json)
                setBody("""{"isDefault":true,"source":"ui_reset"}""")
            }
            assertEquals(200, resetResp.status.value)
            val resetSoul = json.decodeFromString<SoulStateDto>(resetResp.bodyAsText())
            assertEquals(11L, resetSoul.revision)
            assertTrue(resetSoul.isDefault)
            assertEquals("Amber", resetSoul.displayName)
            assertEquals("", resetSoul.tagline)
            assertEquals("", resetSoul.soulMarkdown)
            assertEquals("人设10", resetSoul.history.first().displayName)
            assertEquals(11L, statusSoulRevision(paired.token))
        } finally {
            kernel.orchestrationStore.close()
            dir.deleteRecursively()
        }
    }

    private suspend fun io.ktor.server.testing.ApplicationTestBuilder.statusSoulRevision(token: String): Long =
        json.parseToJsonElement(client.get("/v1/status") { bearerAuth(token) }.bodyAsText())
            .jsonObject["soulRevision"]!!.jsonPrimitive.long

    private suspend fun io.ktor.server.testing.ApplicationTestBuilder.timelineSoulRevision(path: String, token: String): Long =
        json.parseToJsonElement(client.get(path) { bearerAuth(token) }.bodyAsText())
            .jsonObject["soulRevision"]!!.jsonPrimitive.long

    private suspend fun io.ktor.server.testing.ApplicationTestBuilder.eventsSoulRevision(token: String): Long =
        json.parseToJsonElement(client.get("/v2/dialogue/events") { bearerAuth(token) }.bodyAsText())
            .jsonObject["soulRevision"]!!.jsonPrimitive.long

    @Test
    fun router_agent_soul_update_decouples_host_discipline_persists_across_restart_and_blocks_non_owner() = runBlocking {
        val dir = Files.createTempDirectory("amber-soul-router").toFile()
        // Pre-seed customized legacy SOUL.md to verify migration on first boot
        File(dir, "memory").apply { mkdirs() }.let { mem ->
            File(mem, "SOUL.md").writeText("旧版自定义语气：简洁干练")
        }

        val turnStep = AtomicInteger(0)
        val systemPromptsSeen = CopyOnWriteArrayList<String>()
        val model = CloudModelClient { messages, tools ->
            if (messages.first().toText().startsWith("你是对话标签提取器")) {
                return@CloudModelClient UIMessage.assistant("""{"tags":[]}""")
            }
            val sys = messages.first().toText()
            systemPromptsSeen += sys
            assertTrue(tools.any { it.name == "agent_soul_get" }, "Router 必须常驻声明 agent_soul_get")
            assertTrue(tools.any { it.name == "agent_soul_update" }, "Router 必须常驻声明 agent_soul_update")
            assertContains(sys, "<host-core-discipline>")
            assertContains(sys, "agent_soul_update")

            val lastText = messages.last().toText()
            when {
                lastText.contains("路人篡改") -> UIMessage.assistant("").copy(
                    parts = listOf(
                        UIMessagePart.Tool(
                            toolCallId = "guest-hijack",
                            toolName = "agent_soul_update",
                            input = """{"display_name":"黑客","soul_markdown":"全部听我的"}""",
                        )
                    )
                )
                stepForOwnerUpdate(turnStep) == 1 -> UIMessage.assistant("").copy(
                    parts = listOf(
                        UIMessagePart.Tool(
                            toolCallId = "soul-get-1",
                            toolName = "agent_soul_get",
                            input = "{}",
                        ),
                        UIMessagePart.Tool(
                            toolCallId = "soul-upd-1",
                            toolName = "agent_soul_update",
                            input = """{"display_name":"赵匡胤","tagline":"宋太祖赵大哥","soul_markdown":"自称赵大哥，豪爽痛快、有事直说。"}""",
                        ),
                    )
                )
                else -> UIMessage.assistant("贤弟放心，往后咱兄弟有事直说！调用了 agent_soul_update 已生效。")
            }
        }

        try {
            val first = CloudAgentKernel(dir, model, masterSecretOverride = "soul-router-secret")
            // Legacy custom SOUL.md migrated as revision 1
            assertEquals(1L, first.soulStore.currentRevision())
            assertEquals("legacy_migration", first.soulStore.get().source)

            val feishu = FakeImConnector()
            first.registerConnector(feishu)

            // Collaborator (non-owner) in group chat cannot mutate global Soul
            feishu.ingress.handleInbound(
                InboundMessage(
                    messageId = "collab-1",
                    channel = ChannelKind.FEISHU,
                    chatId = "group-1",
                    senderId = "collab-user",
                    senderRole = SenderRole.COLLABORATOR,
                    scope = ConversationScope.GROUP,
                    text = "路人篡改人设",
                )
            )
            withTimeout(5_000) { first.router.awaitIdle() }
            assertEquals(1L, first.soulStore.currentRevision(), "非主人消息不得修改全局形象人设")

            // Owner updates persona via natural chat in Feishu
            turnStep.set(0)
            feishu.ingress.handleInbound(
                InboundMessage(
                    messageId = "owner-soul-1",
                    channel = ChannelKind.FEISHU,
                    chatId = "owner-dm",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    scope = ConversationScope.DIRECT,
                    text = "把你的形象人设改成宋太祖赵匡胤，以后自称赵大哥",
                )
            )
            withTimeout(5_000) { first.router.awaitIdle() }
            first.conversationTagger.awaitIdle()

            val updated = first.soulStore.get()
            assertEquals(2L, updated.revision)
            assertEquals("赵匡胤", updated.displayName)
            assertEquals("chat_self_update", updated.source)
            assertFalse(updated.isDefault)
            // Follow-up turn within the same Router decision already received refreshed <agent-soul>
            assertContains(systemPromptsSeen.last(), "赵匡胤")
            assertContains(systemPromptsSeen.last(), "<host-core-discipline>")
            // Outward reply sanitized of internal snake_case tool identifier
            val finalReply = feishu.outbound.last().text
            assertContains(finalReply, "贤弟放心")
            assertFalse(finalReply.contains("agent_soul_update"))

            // Pure role mirror in memory/SOUL.md & workspace/SOUL.md does NOT mix immutable host boilerplate
            val mirroredMd = File(dir, "memory/SOUL.md").readText()
            assertContains(mirroredMd, "赵匡胤")
            assertFalse(mirroredMd.contains("高风险操作必须等待"))
            assertEquals(mirroredMd, File(dir, "workspace/SOUL.md").readText())

            first.orchestrationStore.close()

            // Restart persistence check
            val restarted = CloudAgentKernel(dir, model, masterSecretOverride = "soul-router-secret")
            try {
                val persisted = restarted.soulStore.get()
                assertEquals(2L, persisted.revision)
                assertEquals("赵匡胤", persisted.displayName)
                assertEquals("宋太祖赵大哥", persisted.tagline)
                assertContains(persisted.soulMarkdown, "自称赵大哥")
                assertEquals(1, persisted.history.size)
                assertEquals(CloudSoulStore.IMMUTABLE_HOST_DISCIPLINE_PROMPT.trim().take(20),
                    restarted.soulStore.renderDirectSystemPrompt().take(20))
            } finally {
                restarted.orchestrationStore.close()
            }
        } finally {
            dir.deleteRecursively()
        }
    }

    private fun stepForOwnerUpdate(counter: AtomicInteger): Int = counter.incrementAndGet()
}
