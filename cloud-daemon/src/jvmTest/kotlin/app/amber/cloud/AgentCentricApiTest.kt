package app.amber.cloud

import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.agents.*
import app.amber.cloud.channel.*
import app.amber.cloud.gateway.AgentCentricApi
import app.amber.cloud.gateway.CloudGatewayState
import app.amber.cloud.gateway.configureCloudGateway
import app.amber.cloud.orchestration.*
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.runtime.CloudToolDefinition
import app.amber.cloud.runtime.ToolEffect
import app.amber.core.model.Conversation
import app.amber.core.model.DEFAULT_ASSISTANT_ID
import app.amber.core.model.MemoryKind
import app.amber.core.model.MemoryScope
import app.amber.core.model.toMessageNode
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.server.testing.testApplication
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.*
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.*

class AgentCentricApiTest {
    private class Connector : ChannelConnector {
        override val kind = ChannelKind.TELEGRAM
        lateinit var ingress: ChannelIngress
        val sent = CopyOnWriteArrayList<OutboundMessage>()
        override fun attachIngress(ingress: ChannelIngress) { this.ingress = ingress }
        override suspend fun start() = Unit
        override suspend fun stop() = Unit
        override suspend fun send(message: OutboundMessage): Result<String> { sent += message; return Result.success("out-${sent.size}") }
    }

    @Test fun deterministic_agent_dispatch_uses_scoped_memory_model_and_tools_and_retains_managed_session() = runBlocking {
        val dir = Files.createTempDirectory("agent-runtime").toFile()
        val prompts = CopyOnWriteArrayList<String>()
        var workerCalls = 0
        val preferred = CloudModelClient { messages, tools ->
            prompts += messages.joinToString("\n") { message ->
                message.toText() + message.getTools().flatMap { it.output }.filterIsInstance<UIMessagePart.Text>().joinToString("\n") { it.text }
            }
            assertEquals(listOf("history_search","task_finish"), tools.map { it.name })
            workerCalls++
            if (workerCalls == 1) UIMessage.assistant("").copy(parts = listOf(
                UIMessagePart.Tool("denied-call", "history_fetch", "{}"),
                UIMessagePart.Tool("cross-history", "history_search", """{"conversation_id":"$PRIMARY_CONVERSATION_ID","query":"全局"}"""),
            ))
            else UIMessage.assistant("").copy(parts=listOf(UIMessagePart.Tool("finish", "task_finish", """{"outcome":"completed","summary":"已按编码约束完成。"}""")))
        }
        val kernel = CloudAgentKernel(dir, CloudModelClient { _, _ -> UIMessage.assistant("已完成汇报。") },
            masterSecretOverride = "agent-runtime-test", modelClients = mapOf("coding-model" to preferred))
        try {
            kernel.agentRegistry.save(CloudPrincipal.OwnerUser("owner", "test"), AgentProfile("coding", "编码", "只读检查项目", AgentMemoryPolicy.HUB_ISOLATED,
                toolScope = setOf("history_search"), modelPreference = "coding-model"), 0)
            kernel.memoryStore.saveSoulPrompt("绝密全局身份")
            kernel.memoryStore.upsertMemory("全局私有偏好", kind = MemoryKind.USER, scope = MemoryScope.CORE)
            kernel.memoryStore.upsertMemory("编码私有记忆", agentId = "coding")
            val connector = Connector()
            kernel.registerConnector(connector)
            val ack = connector.ingress.handleInbound(InboundMessage(messageId = "agent-in", channel = ChannelKind.TELEGRAM, chatId = "owner", senderId = "owner", senderRole = SenderRole.OWNER,
                text = "@编码 记住：项目只读", scope = ConversationScope.DIRECT, threadId = "topic"))
            assertTrue(ack.text.startsWith("收到"))
            withTimeout(5_000) { kernel.router.awaitIdle(includeWorkers = true) }
            val item = kernel.orchestrationStore.listWorkItems().single()
            assertEquals("coding", item.agentId)
            assertEquals(WorkItemState.COMPLETED, item.state)
            assertTrue(AgentCentricApi(kernel).workItem(item.workItemId)!!.sessionArchived)
            assertEquals(2, workerCalls)
            assertTrue(prompts.all { it.contains("编码私有记忆") && it.contains("项目只读") && it.contains("只读检查项目") })
            assertTrue(prompts.none { it.contains("全局私有偏好") || it.contains("绝密全局身份") })
            assertTrue(prompts.last().contains("Agent 未获授该工具"), "伪造未声明工具调用也被执行门禁阻止")
            assertTrue(prompts.last().contains("禁止跨会话读取"), "已获授历史工具也不能读取主时间线")
            assertTrue(kernel.memoryStore.listMemories().none { it.content == "项目只读" })
            val events = kernel.orchestrationStore.listSqliteDiagnosticEvents(PRIMARY_CONVERSATION_ID.toString())
            assertTrue(events.any { it.kind == "agent_routed" && it.detail.contains("mention") && it.detail.contains("coding") })
            assertTrue(kernel.orchestrationStore.listActiveSubscribersForThread("telegram:owner:topic").isEmpty(), "归档任务不再接收话题直通")
            assertNotNull(kernel.conversationStorage.loadConversation(kotlin.uuid.Uuid.parse(item.workerSessionId!!)))
            connector.ingress.handleInbound(InboundMessage(messageId = "agent-followup", channel = ChannelKind.TELEGRAM, chatId = "owner", senderId = "owner", senderRole = SenderRole.OWNER,
                text = "@编码 继续检查同一项目", scope = ConversationScope.DIRECT, threadId = "topic"))
            withTimeout(5_000) { kernel.router.awaitIdle(includeWorkers = true) }
            val reused = kernel.orchestrationStore.listWorkItems().single { it.workItemId != item.workItemId }
            assertEquals(item.workerSessionId, reused.workerSessionId)
            assertEquals(WorkItemState.COMPLETED, reused.state)
            assertEquals(3, workerCalls)
        } finally { kernel.router.awaitIdle(includeWorkers = true); kernel.agentRegistry.close(); kernel.orchestrationStore.close(); dir.deleteRecursively() }
    }

    @Test fun agent_and_timeline_http_projections_are_authenticated_sanitized_and_session_free() = testApplication {
        val dir = Files.createTempDirectory("agent-api").toFile()
        val kernel = CloudAgentKernel(dir, CloudModelClient { _, _ -> UIMessage.assistant("ok") }, masterSecretOverride = "agent-api-test")
        application { configureCloudGateway(kernel.gatewayState, agentApi = AgentCentricApi(kernel)) }
        val secret = kernel.gatewayState.issuePairingTicket()
        val pair = kernel.gatewayState.pairDevice(secret, "ios", "test") as CloudGatewayState.PairResult.Success
        kernel.toolRegistry.register(CloudToolDefinition("specialRead", "稍后注册的工具", false, ToolEffect.PURE) { JsonObject(emptyMap()) })
        val forbidden = "terminal_exec history_search specialRead sk-ant-api03-SECRETKEY1234567890ABCDEF"
        try {
            kernel.agentRegistry.save(CloudPrincipal.OwnerUser("owner", "test"), AgentProfile("coding", "编码 terminal_exec specialRead", "隐藏指令", tags = listOf(forbidden)), 0)
            val user = UIMessage.user("请处理 $forbidden")
            val reply = UIMessage.assistant("完成 $forbidden").copy(parts = listOf(
                UIMessagePart.Text("完成 $forbidden"), UIMessagePart.Reasoning("隐藏推理"), UIMessagePart.Tool("call", "terminal_exec", "{\"password\":\"hidden-args\"}"),
            ))
            kernel.conversationStorage.saveConversation(Conversation(PRIMARY_CONVERSATION_ID, DEFAULT_ASSISTANT_ID, messageNodes = listOf(user.toMessageNode(), reply.toMessageNode())))
            assertEquals(401, client.get("/v2/agents").status.value)
            val agents = client.get("/v2/agents") { header(HttpHeaders.Authorization, "Bearer ${pair.token}") }
            val timeline = client.get("/v2/timeline?limit=1") { header(HttpHeaders.Authorization, "Bearer ${pair.token}") }
            for (response in listOf(agents, timeline)) {
                assertEquals(200, response.status.value)
                val body = response.bodyAsText()
                for (secretText in listOf("terminal_exec", "history_search", "specialRead", "SECRETKEY", "hidden-args", "隐藏推理", "隐藏指令", "toolScope", "sessionId")) assertFalse(body.contains(secretText), body)
            }
            val page = Json.parseToJsonElement(timeline.bodyAsText()).jsonObject
            assertEquals(1, page["items"]!!.jsonArray.size)
            val cursor = page["nextCursor"]!!.jsonPrimitive.content
            val older = client.get("/v2/timeline?before=$cursor") { header(HttpHeaders.Authorization, "Bearer ${pair.token}") }
            assertEquals("user", Json.parseToJsonElement(older.bodyAsText()).jsonObject["items"]!!.jsonArray.single().jsonObject["role"]!!.jsonPrimitive.content)
            assertEquals(400, client.get("/v2/timeline?limit=101") { header(HttpHeaders.Authorization, "Bearer ${pair.token}") }.status.value)
            assertEquals(404, client.get("/v2/agents/missing/activity") { header(HttpHeaders.Authorization, "Bearer ${pair.token}") }.status.value)
            val created = client.post("/v2/agents") { header(HttpHeaders.Authorization, "Bearer ${pair.token}"); setBody("""{"profile":{"id":"travel","name":"旅行"},"expectedRevision":0}""") }
            assertEquals(200, created.status.value)
            assertEquals(409, client.post("/v2/agents") { header(HttpHeaders.Authorization, "Bearer ${pair.token}"); setBody("""{"profile":{"id":"travel","name":"旅行"},"expectedRevision":0}""") }.status.value)
        } finally { kernel.agentRegistry.close(); kernel.orchestrationStore.close(); dir.deleteRecursively() }
    }
}
