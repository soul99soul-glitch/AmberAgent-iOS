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
import app.amber.cloud.gateway.CloudGatewayState
import app.amber.cloud.gateway.DeviceContextSnapshotStore
import app.amber.cloud.orchestration.CloudPrincipal
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.runtime.ExecutionScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class CloudDeviceContextRouterTest {
    private class Connector : ChannelConnector {
        override val kind = ChannelKind.TELEGRAM
        lateinit var ingress: ChannelIngress
        override fun attachIngress(ingress: ChannelIngress) { this.ingress = ingress }
        override suspend fun start() = Unit
        override suspend fun stop() = Unit
        override suspend fun send(message: OutboundMessage) = Result.success("test-out")
    }

    private suspend fun withKernel(model: CloudModelClient, block: suspend (CloudAgentKernel) -> Unit) {
        val dir = Files.createTempDirectory("device-context-router").toFile()
        val kernel = CloudAgentKernel(dir, model, masterSecretOverride = "test-device-router-secret")
        try {
            val paired = kernel.gatewayState.pairDevice(
                kernel.gatewayState.issuePairingTicket(), "ios", "Test iPhone",
            ) as CloudGatewayState.PairResult.Success
            val device = kernel.gatewayState.findDeviceById(paired.deviceId)!!
            val now = System.currentTimeMillis()
            val stored = kernel.gatewayState.deviceContextStore.putRawJson(device, """
                {"capturedAtEpochMs":$now,"domains":{"calendarUpcoming":{"items":[
                  {"title":"PRIVATE_CALENDAR_TITLE","startMs":${now + 60000},"endMs":${now + 120000},"allDay":false}
                ]}}}
            """.trimIndent().toByteArray())
            assertIs<DeviceContextSnapshotStore.PutResult.Stored>(stored)
            block(kernel)
        } finally {
            kernel.router.awaitIdle(includeWorkers = true)
            kernel.conversationTagger.closeAndJoin()
            kernel.supertagStore.close()
            kernel.agentRegistry.close()
            kernel.orchestrationStore.close()
            dir.deleteRecursively()
        }
    }

    @Test
    fun `production Router exposes and executes snapshot read only for authenticated owner turn`() = runBlocking {
        checkRouterTurn(SenderRole.OWNER, ConversationScope.DIRECT, expectedAccess = true)
    }

    @Test
    fun `untrusted IM collaborator cannot discover or forge snapshot read in production Router`() = runBlocking {
        checkRouterTurn(SenderRole.COLLABORATOR, ConversationScope.GROUP, expectedAccess = false)
    }

    private suspend fun checkRouterTurn(role: SenderRole, scope: ConversationScope, expectedAccess: Boolean) {
        val toolNames = CopyOnWriteArrayList<List<String>>()
        val outputs = CopyOnWriteArrayList<String>()
        val model = CloudModelClient { messages, tools ->
            if (tools.none { it.name == "dispatch_work" }) {
                return@CloudModelClient UIMessage.assistant("""{"tags":[]}""")
            }
            toolNames += tools.map { it.name }
            val result = messages.flatMap { it.parts }.filterIsInstance<UIMessagePart.Tool>()
                .lastOrNull { it.toolName == "device_context_read" && it.output.isNotEmpty() }
            if (result == null) {
                // An untrusted model may fabricate an undeclared call; the execution gate must still reject it.
                UIMessage.assistant("").copy(parts = listOf(UIMessagePart.Tool(
                    toolCallId = "snapshot-read", toolName = "device_context_read", input = "{}",
                )))
            } else {
                outputs += result.output.filterIsInstance<UIMessagePart.Text>().joinToString { it.text }
                UIMessage.assistant("已核实共享状态。")
            }
        }
        withKernel(model) { kernel ->
            val connector = Connector()
            kernel.registerConnector(connector)
            connector.ingress.handleInbound(InboundMessage(
                messageId = "snapshot-request", channel = connector.kind,
                chatId = if (scope == ConversationScope.DIRECT) "owner-dm" else "shared-group",
                senderId = if (role == SenderRole.OWNER) "owner" else "collaborator",
                senderRole = role, scope = scope, text = "查看共享的日历摘要",
            ))
            withTimeout(5000) { kernel.router.awaitIdle() }
            assertTrue(toolNames.isNotEmpty(), "必须经过生产 ModelRouterBrain")
            assertTrue(toolNames.all { ("device_context_read" in it) == expectedAccess })
            val result = outputs.single()
            if (expectedAccess) {
                assertTrue(result.contains("PRIVATE_CALENDAR_TITLE"), "必须实际执行注册的快照读取器")
                assertTrue(result.contains("untrusted_device_data"))
            } else {
                assertFalse(result.contains("PRIVATE_CALENDAR_TITLE"))
                assertTrue(result.contains("OwnerUser"), "伪造工具调用必须由执行门禁拒绝")
            }
        }
    }

    @Test
    fun `missing principal coordinator external and nested recipe cannot read owner snapshot`() = runBlocking {
        withKernel(CloudModelClient { _, _ -> UIMessage.assistant("ok") }) { kernel ->
            val owner = CloudPrincipal.OwnerUser("owner", "app", trustedForegroundApp = true)
            val deniedPrincipals = listOf(
                null,
                CloudPrincipal.CloudCoordinator(activeSessionId = "s", activeTurnId = "t"),
                CloudPrincipal.ExternalCaller("collaborator", "telegram"),
            )
            for (principal in deniedPrincipals) {
                assertFalse(kernel.toolRegistry.availableDefinitions(ExecutionScope.MAIN_AGENT, principal)
                    .any { it.name == "device_context_read" })
                val result = kernel.toolRegistry.executeGate(
                    "device_context_read", JsonObject(emptyMap()), ExecutionScope.MAIN_AGENT, principal = principal,
                ).jsonObject
                assertEquals(false, result["ok"]?.jsonPrimitive?.booleanOrNull)
                assertFalse(result.toString().contains("PRIVATE_CALENDAR_TITLE"))
            }
            for (scope in ExecutionScope.entries.filter { it != ExecutionScope.MAIN_AGENT }) {
                assertFalse(kernel.toolRegistry.availableDefinitions(scope, owner).any { it.name == "device_context_read" })
                val result = kernel.toolRegistry.executeGate(
                    "device_context_read", JsonObject(emptyMap()), scope, principal = owner,
                ).jsonObject
                assertEquals(false, result["ok"]?.jsonPrimitive?.booleanOrNull)
            }
            val nested = kernel.toolRegistry.executeGate(
                "recipe_run", kotlinx.serialization.json.Json.parseToJsonElement(
                    """{"tool":"device_context_read","args":{}}""",
                ).jsonObject, ExecutionScope.MAIN_AGENT, principal = owner,
            ).jsonObject
            assertEquals(false, nested["ok"]?.jsonPrimitive?.booleanOrNull)
            assertFalse(nested.toString().contains("PRIVATE_CALENDAR_TITLE"))
        }
    }
}
