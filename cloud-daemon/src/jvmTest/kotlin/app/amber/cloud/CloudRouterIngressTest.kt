package app.amber.cloud

import app.amber.ai.core.Tool
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.channel.ChannelConnector
import app.amber.cloud.channel.ChannelIngress
import app.amber.cloud.channel.ChannelKind
import app.amber.cloud.channel.ConversationScope
import app.amber.cloud.channel.InboundMessage
import app.amber.cloud.channel.OutboundMessage
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.orchestration.CloudRouter
import app.amber.cloud.orchestration.EditableChannelConnector
import app.amber.cloud.orchestration.WorkItemState
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CloudRouterIngressTest {
    private class Connector(override val kind: ChannelKind) : ChannelConnector, EditableChannelConnector {
        lateinit var ingress: ChannelIngress
        val sent = CopyOnWriteArrayList<OutboundMessage>()
        val edits = CopyOnWriteArrayList<String>()
        override fun attachIngress(ingress: ChannelIngress) { this.ingress = ingress }
        override suspend fun start() = Unit
        override suspend fun stop() = Unit
        override suspend fun send(message: OutboundMessage): Result<String> {
            sent += message
            return Result.success("out-${sent.size}")
        }
        override suspend fun edit(chatId: String, messageId: String, text: String): Result<Unit> {
            edits += messageId
            return Result.success(Unit)
        }
        suspend fun receive(text: String): OutboundMessage {
            val message = InboundMessage(
                messageId = "in-${System.nanoTime()}", channel = kind, chatId = "owner-dm",
                senderId = "owner", senderRole = SenderRole.OWNER,
                scope = ConversationScope.DIRECT, text = text,
            )
            return ingress.handleInbound(message).also { send(it) }
        }
    }

    @Test
    fun registered_channel_acknowledges_before_model_and_runs_isolated_worker() = runBlocking {
        val dir = Files.createTempDirectory("amber-router-ingress").toFile()
        val modelStarted = CompletableDeferred<Unit>()
        val releaseModel = CompletableDeferred<Unit>()
        val workerStarted = CompletableDeferred<Unit>()
        val releaseWorker = CompletableDeferred<Unit>()
        val toolRequests = CopyOnWriteArrayList<List<Tool>>()
        val kernel = CloudAgentKernel(dir, CloudModelClient { messages, tools ->
            toolRequests += tools
            modelStarted.complete(Unit)
            releaseModel.await()
            if (tools.any { it.name == "dispatch_work" } && messages.last().toText().contains("排查")) {
                UIMessage.assistant("").copy(parts = listOf(UIMessagePart.Tool(
                    toolCallId = "dispatch-ingress", toolName = "dispatch_work",
                    input = """{"tasks":[{"task_key":"ingress-check","title":"检查状态","brief":"读取状态并汇报"}]}""",
                )))
            } else {
                if (tools.none { it.name == "dispatch_work" }) {
                    workerStarted.complete(Unit)
                    releaseWorker.await()
                }
                UIMessage.assistant("检查完成。")
            }
        }, masterSecretOverride = "router-ingress-test-key")
        val connector = Connector(ChannelKind.TELEGRAM)
        kernel.registerConnector(connector)
        try {
            val ack = withTimeout(2_000) { connector.receive("排查运行状态") }
            assertTrue(ack.text.startsWith("收到"), "IM 必须先确认，不能等待模型完成")
            withTimeout(2_000) { modelStarted.await() }
            assertEquals(1, connector.sent.size, "确认消息只能发送一次")
            releaseModel.complete(Unit)
            withTimeout(5_000) { workerStarted.await() }
            withTimeout(5_000) { kernel.router.awaitIdle() }
            releaseWorker.complete(Unit)
            withTimeout(5_000) { kernel.router.awaitIdle(includeWorkers = true) }
            val item = kernel.orchestrationStore.listWorkItems().single()
            assertEquals(WorkItemState.COMPLETED, item.state)
            assertTrue(toolRequests.first().all { it.name in CloudRouter.ROUTER_TOOL_NAMES })
            assertTrue(toolRequests.any { tools -> tools.none { it.name in CloudRouter.ROUTER_TOOL_NAMES } })
            assertTrue(connector.edits.isNotEmpty(), "Worker 进度应编辑状态消息")
            assertEquals(1, connector.edits.distinct().size, "同一任务必须编辑同一条状态消息")
            assertFalse(toolRequests.flatten().any { it.name == "ssh_profile_create" })
        } finally {
            releaseModel.complete(Unit)
            releaseWorker.complete(Unit)
            kernel.router.awaitIdle(includeWorkers = true)
            dir.deleteRecursively()
        }
    }

    @Test
    fun routed_channel_history_and_explicit_memory_survive_cross_channel_restart() = runBlocking {
        val dir = Files.createTempDirectory("amber-router-history").toFile()
        val requests = CopyOnWriteArrayList<List<UIMessage>>()
        val model = CloudModelClient { messages, _ ->
            requests += messages
            UIMessage.assistant("已经记下。")
        }
        try {
            val first = CloudAgentKernel(dir, model, masterSecretOverride = "history-test-key")
            val telegram = Connector(ChannelKind.TELEGRAM)
            val feishu = Connector(ChannelKind.FEISHU)
            first.registerConnector(telegram)
            first.registerConnector(feishu)
            telegram.receive("记住：周五发布")
            withTimeout(5_000) { first.router.awaitIdle() }
            feishu.receive("确认材料清单")
            withTimeout(5_000) { first.router.awaitIdle() }
            assertEquals(4, first.conversationStorage.loadConversation(PRIMARY_CONVERSATION_ID)!!.messageNodes.size)

            val restarted = CloudAgentKernel(dir, model, masterSecretOverride = "history-test-key")
            restarted.recoverColdStartConversations()
            val next = Connector(ChannelKind.TELEGRAM)
            restarted.registerConnector(next)
            next.receive("之前安排了什么？")
            withTimeout(5_000) { restarted.router.awaitIdle() }
            val prompt = requests.last().joinToString("\n") { it.toText() }
            assertTrue(prompt.contains("周五发布"))
            assertTrue(prompt.contains("确认材料清单"))
            assertTrue(prompt.contains("已经记下"))
            assertTrue(restarted.memoryStore.recallForPrompt("周五").isNotEmpty())
        } finally {
            dir.deleteRecursively()
        }
    }
}
