package app.amber.cloud.supertags

import app.amber.ai.ui.UIMessage
import app.amber.cloud.agents.*
import app.amber.cloud.channel.*
import app.amber.cloud.gateway.AgentCentricApi
import app.amber.cloud.gateway.CloudGatewayState
import app.amber.cloud.gateway.configureCloudGateway
import app.amber.cloud.orchestration.CloudPrincipal
import app.amber.cloud.orchestration.WorkItemState
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import app.amber.core.model.*
import io.ktor.client.request.*
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.server.testing.testApplication
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.*
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.*

class HubBackendTest {
    private val owner = CloudPrincipal.OwnerUser("owner", "test")

    @Test fun automatic_and_focused_hub_mounts_use_existing_memory_policies_and_disabled_turns_skip_tagging() = runBlocking {
        val dir = Files.createTempDirectory("hub-context").toFile()
        val prompts = CopyOnWriteArrayList<String>()
        val taggingCalls = AtomicInteger()
        val kernel = CloudAgentKernel(dir, CloudModelClient { messages, _ ->
            if (messages.first().toText().startsWith("你是对话标签提取器")) {
                taggingCalls.incrementAndGet()
                UIMessage.assistant("""{"tags":[{"name":"space/flight","attributes":{"destination":{"type":"TEXT","value":"火星"}}}]}""")
            } else {
                prompts += messages.joinToString("\n") { it.toText() }
                UIMessage.assistant("已核对计划")
            }
        }, masterSecretOverride = "hub-context-test")
        try {
            kernel.hubs.save(owner, HubSettings("space", "火星计划", "先核对飞船", tags = listOf("火星"), template = HubTemplate.NOVEL), 0)
            kernel.memoryStore.saveSoulPrompt("全局语气偏好")
            kernel.memoryStore.upsertMemory("全局称呼偏好", scope = MemoryScope.CORE, kind = MemoryKind.USER)
            kernel.memoryStore.upsertMemory("其他中心秘密", agentId = "other")
            kernel.memoryStore.upsertMemory("火星局部事实", agentId = "space")
            val input = InboundMessage("first", ChannelKind.TELEGRAM, "owner", senderId = "owner", text = "火星 记忆核对", senderRole = SenderRole.OWNER)
            kernel.handleInbound(input)
            kernel.conversationTagger.awaitIdle()
            assertTrue(prompts.first().contains("先核对飞船"))
            assertTrue(prompts.first().contains("火星局部事实") && prompts.first().contains("全局称呼偏好"))
            assertEquals(listOf("火星局部事实", "全局称呼偏好"), kernel.memoryStore.recallForPrompt("火星", agentId = "space").map { it.content })
            assertTrue(prompts.first().contains("全局语气偏好"))
            assertFalse(prompts.first().contains("其他中心秘密"))
            assertEquals("space/flight", kernel.supertagStore.tags(PRIMARY_CONVERSATION_ID.toString(), "space").single().name)
            val current = kernel.hubs.get("space")
            kernel.hubs.save(owner, current.copy(memoryPolicy = AgentMemoryPolicy.HUB_ISOLATED), current.revision)
            kernel.hubs.focus("space")
            assertEquals("focus", kernel.agentRouting.select("核对下一步", PRIMARY_CONVERSATION_ID.toString()).method)
            kernel.handleInbound(input.copy(messageId = "second", text = "核对下一步"))
            kernel.conversationTagger.awaitIdle()
            // Current history is retained by the main timeline, but shared SOUL and global recall are removed.
            val system = prompts.last().substringBefore("<context-memory>")
            assertFalse(system.contains("全局语气偏好"))
            val recalled = kernel.memoryStore.recallForPrompt("", agentId = "space", memoryPolicy = AgentMemoryPolicy.HUB_ISOLATED)
            assertEquals(listOf("火星局部事实"), recalled.map { it.content })
            assertEquals(2, taggingCalls.get())
            assertTrue(kernel.conversationStorage.updateMemoryMode(PRIMARY_CONVERSATION_ID, ConversationMemoryMode.DISABLED))
            kernel.handleInbound(input.copy(messageId = "disabled", text = "记住：不应保存"))
            kernel.conversationTagger.awaitIdle()
            assertEquals(2, taggingCalls.get())
            assertFalse(kernel.memoryStore.listMemories(agentId = "space").any { it.content.contains("不应保存") })
            kernel.hubs.focus(null)
            assertNull(kernel.supertagStore.focusedHub(PRIMARY_CONVERSATION_ID.toString()))
        } finally {
            kernel.conversationTagger.awaitIdle(); kernel.conversationTagger.close(); kernel.supertagStore.close()
            kernel.agentRegistry.close(); kernel.orchestrationStore.close(); dir.deleteRecursively()
        }
    }

    @Test fun registered_ingress_focus_dispatches_scoped_worker_and_tags_only_the_completed_worker() = runBlocking {
        val dir = Files.createTempDirectory("hub-ingress").toFile()
        lateinit var ingress: ChannelIngress
        val prompts = CopyOnWriteArrayList<String>()
        val kernel = CloudAgentKernel(dir, CloudModelClient { messages, _ ->
            if (messages.first().toText().startsWith("你是对话标签提取器")) UIMessage.assistant("""{"tags":[{"name":"private/topic"}]}""")
            else { prompts += messages.joinToString("\n") { it.toText() }; UIMessage.assistant("完成核对") }
        }, masterSecretOverride = "hub-ingress-test")
        kernel.registerConnector(object : ChannelConnector {
            override val kind = ChannelKind.TELEGRAM
            override fun attachIngress(value: ChannelIngress) { ingress = value }
            override suspend fun start() = Unit
            override suspend fun stop() = Unit
            override suspend fun send(message: OutboundMessage) = Result.success("out")
        })
        try {
            kernel.hubs.save(owner, HubSettings("private", "私有中心", "只处理私有事项", AgentMemoryPolicy.HUB_ISOLATED), 0)
            kernel.hubs.focus("private")
            kernel.memoryStore.upsertMemory("中心事实", agentId = "private")
            kernel.memoryStore.upsertMemory("全局个人偏好", scope = MemoryScope.CORE)
            ingress.handleInbound(InboundMessage("focus-input", ChannelKind.TELEGRAM, "owner", senderId = "owner", text = "核对事项"))
            withTimeout(5_000) { kernel.router.awaitIdle(includeWorkers = true) }
            kernel.conversationTagger.awaitIdle()
            val item = kernel.orchestrationStore.listWorkItems().single()
            assertEquals("private", item.agentId)
            assertEquals(WorkItemState.COMPLETED, item.state)
            assertTrue(prompts.first().contains("中心事实"))
            assertFalse(prompts.first().contains("全局个人偏好"))
            assertEquals(item.workerSessionId, kernel.supertagStore.tags(scopeId = "private").single().conversationId)
            assertTrue(kernel.supertagStore.tags().isEmpty(), "汇总消息不再次提取到全局标签")
        } finally {
            kernel.router.awaitIdle(includeWorkers = true); kernel.conversationTagger.awaitIdle(); kernel.conversationTagger.close(); kernel.supertagStore.close()
            kernel.agentRegistry.close(); kernel.orchestrationStore.close(); dir.deleteRecursively()
        }
    }

    @Test fun v2_hub_tag_template_and_suggestion_routes_authenticate_and_enforce_revisions() = testApplication {
        val dir = Files.createTempDirectory("hub-http").toFile()
        val kernel = CloudAgentKernel(dir, CloudModelClient { _, _ -> error("管理API不调用模型") }, masterSecretOverride = "hub-http-test")
        application { configureCloudGateway(kernel.gatewayState, agentApi = AgentCentricApi(kernel)) }
        val pair = kernel.gatewayState.pairDevice(kernel.gatewayState.issuePairingTicket(), "ios", "test") as CloudGatewayState.PairResult.Success
        val auth: HttpRequestBuilder.() -> Unit = { header(HttpHeaders.Authorization, "Bearer ${pair.token}") }
        try {
            for (url in listOf("/v2/hubs", "/v2/tags", "/v2/tag-templates", "/v2/collections", "/v2/hub-promotions", "/v2/supertag-events")) assertEquals(401, client.get(url).status.value)
            val hubBody = """{"hub":{"id":"novel","name":"小说","template":"NOVEL","memoryPolicy":"HUB_ISOLATED"},"expectedRevision":0}"""
            assertEquals(200, client.post("/v2/hubs") { auth(); setBody(hubBody) }.status.value)
            assertEquals(409, client.post("/v2/hubs") { auth(); setBody(hubBody) }.status.value)
            assertEquals("NOVEL", Json.parseToJsonElement(client.get("/v2/hubs/novel", auth).bodyAsText()).jsonObject["template"]!!.jsonPrimitive.content)
            assertEquals(200, client.post("/v2/hub-focus") { auth(); setBody("""{"hubId":"novel"}""") }.status.value)
            assertEquals("novel", Json.parseToJsonElement(client.get("/v2/hub-focus", auth).bodyAsText()).jsonObject["hubId"]!!.jsonPrimitive.content)
            assertEquals(404, client.get("/v2/hubs/missing", auth).status.value)
            assertEquals(400, client.post("/v2/hubs") { auth(); setBody("{") }.status.value)
            val templates = Json.parseToJsonElement(client.get("/v2/tag-templates", auth).bodyAsText()).jsonObject["templates"]!!.jsonArray
            assertEquals(6, templates.size)
            assertEquals(200, client.post("/v2/tag-templates/task") { auth(); setBody("""{"expectedRevision":1,"name":"事项"}""") }.status.value)
            assertEquals(409, client.delete("/v2/tag-templates/task") { auth(); setBody("""{"expectedRevision":1}""") }.status.value)
            kernel.conversationStorage.saveConversation(Conversation(PRIMARY_CONVERSATION_ID, DEFAULT_ASSISTANT_ID, messageNodes = emptyList()))
            val tagsPath = "/v2/conversations/$PRIMARY_CONVERSATION_ID/tags"
            assertEquals(200, client.post(tagsPath) { auth(); setBody("""{"hubId":"novel","tag":{"name":"creative/novel","attributes":{"status":{"type":"STATUS","value":"创作中"}}}}""") }.status.value)
            assertTrue(Json.parseToJsonElement(client.get("/v2/tags", auth).bodyAsText()).jsonObject["tags"]!!.jsonArray.isEmpty())
            val tags = Json.parseToJsonElement(client.get("/v2/tags?hubId=novel", auth).bodyAsText()).jsonObject["tags"]!!.jsonArray
            assertTrue(tags.single().jsonObject["userModified"]!!.jsonPrimitive.boolean)
            assertEquals(200, client.delete(tagsPath) { auth(); setBody("""{"hubId":"novel","name":"creative/novel"}""") }.status.value)
            assertTrue(Json.parseToJsonElement(client.get("/v2/supertag-events", auth).bodyAsText()).jsonObject["events"]!!.jsonArray.isNotEmpty())
            assertEquals(400, client.get("/v2/supertag-events?after=no", auth).status.value)
        } finally {
            kernel.conversationTagger.close(); kernel.supertagStore.close(); kernel.agentRegistry.close(); kernel.orchestrationStore.close(); dir.deleteRecursively()
        }
    }
}
