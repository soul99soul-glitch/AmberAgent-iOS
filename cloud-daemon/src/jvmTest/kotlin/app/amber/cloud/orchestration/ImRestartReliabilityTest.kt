package app.amber.cloud.orchestration

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
import app.amber.cloud.channels.ChannelCrypto
import app.amber.cloud.channels.ChannelSecretLoader
import app.amber.cloud.channels.FeishuChannel
import app.amber.cloud.channels.OwnerBindingManager
import app.amber.cloud.channels.RedactingChannelLogger
import app.amber.cloud.channels.TelegramChannel
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import app.amber.core.storage.conversation.ConversationFile
import app.amber.core.storage.conversation.JsonConversationStorage
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class ImRestartReliabilityTest {

    private class RecordingConnector(
        override val kind: ChannelKind,
        private val failSendWith: Throwable? = null,
    ) : ChannelConnector {
        lateinit var ingress: ChannelIngress
        val sent = CopyOnWriteArrayList<OutboundMessage>()

        override fun attachIngress(ingress: ChannelIngress) {
            this.ingress = ingress
        }

        override suspend fun start() = Unit
        override suspend fun stop() = Unit

        override suspend fun send(message: OutboundMessage): Result<String> {
            sent += message
            failSendWith?.let { return Result.failure(it) }
            return Result.success("msg-${sent.size}")
        }
    }

    private suspend fun shutdownKernelForRestart(kernel: CloudAgentKernel) {
        kernel.stopProactiveLoop()
        kernel.nativeDialogue.closeAndJoin()
        kernel.conversationTagger.closeAndJoin()
        kernel.agentRegistry.close()
        kernel.orchestrationStore.close()
        kernel.supertagStore.close()
    }

    // ========================================================================
    // Scenario A: IM 任务派出后重启，原地址（私聊 + 群话题）恰好收到一条 rollup；
    // 找不到地址时写时间线且有诊断；connector post 失败记录诊断
    // ========================================================================

    @Test
    fun scenario_a_im_task_across_restart_delivers_rollup_to_original_dm_and_group_topic_address() = runBlocking {
        val dir = Files.createTempDirectory("amber-im-restart-a").toFile()
        try {
            // 1) Telegram 私聊 + 飞书同时绑定，验证即使多通道绑定也不会混淆原地址
            val workerStarted1 = CompletableDeferred<Unit>()
            val workerGate1 = CompletableDeferred<Unit>()
            val first = CloudAgentKernel(dir, CloudModelClient { messages, tools ->
                if (messages.first().toText().startsWith("你是对话标签提取器")) return@CloudModelClient UIMessage.assistant("""{"tags":[]}""")
                if (tools.any { it.name == "dispatch_work" }) {
                    UIMessage.assistant("").copy(parts = listOf(UIMessagePart.Tool(
                        toolCallId = "d-dm", toolName = "dispatch_work",
                        input = """{"tasks":[{"task_key":"dm-restart-task","title":"私聊重启任务","brief":"执行检查"}]}""",
                    )))
                } else {
                    UIMessage.assistant("正在执行")
                }
            }, masterSecretOverride = "restart-a-secret")
            first.ownerBinding.bindOwnerDirectly(TelegramChannel.CHANNEL_ID, "tg-owner-1", "tg-dm-chat-99")
            first.ownerBinding.bindOwnerDirectly(FeishuChannel.CHANNEL_ID, "ou_feishu_1", "oc_feishu_dm_88")
            first.orchestrationKernel.workerTurnRunner = { item, _ ->
                workerStarted1.complete(Unit)
                workerGate1.await()
                WorkerSettlementReport(item.workItemId, "completed", "私聊任务在旧进程完成")
            }
            val tg1 = RecordingConnector(ChannelKind.TELEGRAM)
            val fs1 = RecordingConnector(ChannelKind.FEISHU)
            first.registerConnector(tg1)
            first.registerConnector(fs1)

            val ack = tg1.ingress.handleInbound(
                InboundMessage(
                    messageId = "tg-dm-msg-1",
                    channel = ChannelKind.TELEGRAM,
                    chatId = "tg-dm-chat-99",
                    threadId = "topic-dm-7",
                    senderId = "tg-owner-1",
                    senderRole = SenderRole.OWNER,
                    scope = ConversationScope.DIRECT,
                    text = "帮我跑个私聊长任务",
                )
            )
            assertTrue(ack.text.startsWith("收到"))
            withTimeout(3_000) { workerStarted1.await() }

            // 模拟守护进程重启：旧进程未完成即退出
            shutdownKernelForRestart(first)
            workerGate1.complete(Unit)

            val second = CloudAgentKernel(dir, CloudModelClient { messages, _ ->
                if (messages.first().toText().startsWith("你是对话标签提取器")) UIMessage.assistant("""{"tags":[]}""")
                else UIMessage.assistant("私聊任务已在重启后完成并汇总。")
            }, masterSecretOverride = "restart-a-secret")
            val workerCompleted2 = CompletableDeferred<Unit>()
            second.orchestrationKernel.workerTurnRunner = { item, _ ->
                workerCompleted2.complete(Unit)
                WorkerSettlementReport(item.workItemId, "completed", "私聊任务重启恢复完成")
            }
            val tg2 = RecordingConnector(ChannelKind.TELEGRAM)
            val fs2 = RecordingConnector(ChannelKind.FEISHU)
            second.registerConnector(tg2)
            second.registerConnector(fs2)
            try {
                second.recoverColdStartConversations()
                withTimeout(5_000) { workerCompleted2.await() }
                withTimeout(5_000) { second.router.awaitIdle(includeWorkers = true) }

                val rollupsOnTg = tg2.sent.filter { it.text.contains("重启后完成") || it.text.contains("私聊任务") }
                assertEquals(1, rollupsOnTg.size, "重启后原 Telegram 私聊话题地址必须恰好收到 1 条 rollup，实际=${tg2.sent}")
                assertEquals("tg-dm-chat-99", rollupsOnTg.single().chatId)
                assertEquals("topic-dm-7", rollupsOnTg.single().threadId)
                assertTrue(fs2.sent.isEmpty(), "不能串发到另一通道")
            } finally {
                shutdownKernelForRestart(second)
            }

            // 2) 飞书群聊话题场景：无 ownerBinding 也能在重启后精确回到原群话题地址
            val dirGroup = Files.createTempDirectory("amber-im-restart-a-group").toFile()
            try {
                val gStarted = CompletableDeferred<Unit>()
                val gGate = CompletableDeferred<Unit>()
                val k1 = CloudAgentKernel(dirGroup, CloudModelClient { messages, tools ->
                    if (messages.first().toText().startsWith("你是对话标签提取器")) return@CloudModelClient UIMessage.assistant("""{"tags":[]}""")
                    if (tools.any { it.name == "dispatch_work" }) {
                        UIMessage.assistant("").copy(parts = listOf(UIMessagePart.Tool(
                            toolCallId = "d-grp", toolName = "dispatch_work",
                            input = """{"tasks":[{"task_key":"grp-restart-task","title":"群话题任务","brief":"排查群问题"}]}""",
                        )))
                    } else UIMessage.assistant("收到")
                }, masterSecretOverride = "restart-a-group-secret")
                k1.orchestrationKernel.workerTurnRunner = { item, _ ->
                    gStarted.complete(Unit)
                    gGate.await()
                    WorkerSettlementReport(item.workItemId, "completed", "群任务完成")
                }
                val fsGroup1 = RecordingConnector(ChannelKind.FEISHU)
                k1.registerConnector(fsGroup1)
                fsGroup1.ingress.handleInbound(
                    InboundMessage(
                        messageId = "fs-grp-msg-1",
                        channel = ChannelKind.FEISHU,
                        chatId = "oc_group_123:sub",
                        threadId = "om_root_456:part",
                        senderId = "ou_owner_9",
                        senderRole = SenderRole.OWNER,
                        scope = ConversationScope.GROUP,
                        text = "在群话题跑一个检查",
                    )
                )
                withTimeout(3_000) { gStarted.await() }
                shutdownKernelForRestart(k1)
                gGate.complete(Unit)

                val k2 = CloudAgentKernel(dirGroup, CloudModelClient { messages, _ ->
                    if (messages.first().toText().startsWith("你是对话标签提取器")) UIMessage.assistant("""{"tags":[]}""")
                    else UIMessage.assistant("群话题任务已完成汇总。")
                }, masterSecretOverride = "restart-a-group-secret")
                k2.orchestrationKernel.workerTurnRunner = { item, _ ->
                    WorkerSettlementReport(item.workItemId, "completed", "群任务恢复完成")
                }
                val fsGroup2 = RecordingConnector(ChannelKind.FEISHU)
                k2.registerConnector(fsGroup2)
                try {
                    k2.recoverColdStartConversations()
                    withTimeout(5_000) { k2.router.awaitIdle(includeWorkers = true) }
                    val groupReplies = fsGroup2.sent.filter { it.text.contains("群话题任务已完成") }
                    assertEquals(1, groupReplies.size, "群话题重启恢复后必须收到恰好 1 条 rollup，实际=${fsGroup2.sent}")
                    assertEquals("oc_group_123:sub", groupReplies.single().chatId)
                    assertEquals("om_root_456:part", groupReplies.single().threadId)
                } finally {
                    shutdownKernelForRestart(k2)
                }
            } finally {
                dirGroup.deleteRecursively()
            }
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun scenario_a_missing_address_writes_timeline_and_diagnostic_and_post_failure_records_diagnostic() = runBlocking {
        // 1) 无地址时非原生回复仍写入时间线并记录诊断
        val dir1 = Files.createTempDirectory("amber-im-missing-addr").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val store = CloudOrchestrationStore(dir1)
        try {
            val convStorage = JsonConversationStorage(ConversationFile(File(dir1, "conversations").apply { mkdirs() }.absolutePath))
            val kernel = DefaultCloudOrchestrationKernel(
                store = store,
                conversationStorage = convStorage,
                toolRegistry = app.amber.cloud.runtime.CloudToolRegistry(),
            )
            val timelineReplies = CopyOnWriteArrayList<Pair<String, String>>()
            val router = CloudRouter(
                kernel = kernel,
                sink = object : ImStatusSink {
                    override suspend fun post(address: ImAddress, text: String): String = "ok"
                    override suspend fun edit(address: ImAddress, messageId: String, text: String): Boolean = true
                },
                brain = RouterBrain { RouterDecision(reply = "无地址时的汇总回复") },
                scope = scope,
                onReply = { convId, text -> timelineReplies += convId to text },
            )
            kernel.enqueueRouterTriggerWhileBusy(
                RouterTriggerEvent(
                    eventId = "rollup:no-addr-1",
                    kind = "batch_rollup",
                    conversationId = PRIMARY_CONVERSATION_ID.toString(),
                    channelId = "telegram",
                    chatId = "unknown",
                    senderId = "system",
                    summaryText = "批次结束汇总",
                    createdAtMs = 1_000L,
                )
            )
            withTimeout(3_000) { router.awaitIdle() }

            assertTrue(timelineReplies.any { it.second.contains("无地址时的汇总回复") }, "找不到地址时仍需写入时间线")
            assertTrue(
                store.listSqliteDiagnosticEvents(PRIMARY_CONVERSATION_ID.toString()).any { it.kind == "im_reply_address_missing" },
                "找不到地址时必须记录 im_reply_address_missing 诊断",
            )
        } finally {
            scope.cancel()
            store.close()
            dir1.deleteRecursively()
        }

        // 2) connector post 失败记录诊断
        val dir2 = Files.createTempDirectory("amber-im-post-fail").toFile()
        val kernel2 = CloudAgentKernel(dir2, CloudModelClient { messages, _ ->
            if (messages.first().toText().startsWith("你是对话标签提取器")) UIMessage.assistant("""{"tags":[]}""")
            else UIMessage.assistant("尝试外发回复")
        }, masterSecretOverride = "post-fail-secret")
        try {
            val failingConnector = RecordingConnector(ChannelKind.TELEGRAM, failSendWith = IllegalStateException("http_429_rate_limited"))
            kernel2.registerConnector(failingConnector)
            failingConnector.ingress.handleInbound(
                InboundMessage(
                    messageId = "tg-fail-post-1",
                    channel = ChannelKind.TELEGRAM,
                    chatId = "tg-chat-fail",
                    senderId = "tg-owner",
                    senderRole = SenderRole.OWNER,
                    scope = ConversationScope.DIRECT,
                    text = "普通问答",
                )
            )
            withTimeout(3_000) { kernel2.router.awaitIdle() }
            assertTrue(
                kernel2.orchestrationStore.listSqliteDiagnosticEvents(PRIMARY_CONVERSATION_ID.toString()).any { it.kind == "im_post_failed" },
                "connector post 失败必须记录 im_post_failed 诊断",
            )
        } finally {
            shutdownKernelForRestart(kernel2)
            dir2.deleteRecursively()
        }
    }

    // ========================================================================
    // Scenario B: rollup 已领取但 Router 未处理时重启，恢复后重投一次，不重复派单
    // ========================================================================

    @Test
    fun scenario_b_rollup_claimed_before_router_processed_redelivers_once_after_restart() = runBlocking {
        val dir = Files.createTempDirectory("amber-im-restart-b").toFile()
        val clock = AtomicLong(1_762_000_000_000L)
        try {
            val scope1 = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            val store1 = CloudOrchestrationStore(dir)
            val convStorage1 = JsonConversationStorage(ConversationFile(File(dir, "conversations").apply { mkdirs() }.absolutePath))
            val kernel1 = DefaultCloudOrchestrationKernel(
                store = store1,
                conversationStorage = convStorage1,
                toolRegistry = app.amber.cloud.runtime.CloudToolRegistry(),
                clockMs = { clock.get() },
            )
            val rollupTurnEntered = CompletableDeferred<Unit>()
            val releaseRollupTurn = CompletableDeferred<Unit>()
            val sink1 = CloudOrchestrationKernelTest.MockEditableImSink()
            val router1 = CloudRouter(
                kernel = kernel1,
                sink = sink1,
                brain = RouterBrain { input ->
                    if (input.events.any { it.kind == "batch_rollup" }) {
                        rollupTurnEntered.complete(Unit)
                        releaseRollupTurn.await()
                        RouterDecision(reply = "旧进程不应完成此回复")
                    } else {
                        RouterDecision(
                            reply = "已派发任务",
                            dispatch = listOf(
                                WorkItemSubmissionSpec(
                                    taskKey = "b-task-1",
                                    title = "批次汇总恢复测试",
                                    brief = "执行检查",
                                    targetNode = ExecutionTargetNode.CloudSubagent("worker"),
                                )
                            ),
                        )
                    }
                },
                clockMs = { clock.get() },
                scope = scope1,
            )

            router1.onInbound(
                InboundMessage(
                    messageId = "msg-b-1",
                    channel = ChannelKind.TELEGRAM,
                    chatId = "chat-b",
                    threadId = "topic-b",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    scope = ConversationScope.DIRECT,
                    text = "启动批次任务",
                )
            )
            withTimeout(3_000) {
                while (store1.listWorkItems().isEmpty()) delay(10)
            }
            val item = store1.listWorkItems().single()
            // Worker 完成并触发 tryClaimBatchWake（写入 batch_rollups，未处理完前进程重启）
            kernel1.reportWorkerSettlement(
                kernel1.workerPrincipalFor(item),
                WorkerSettlementReport(item.workItemId, "completed", "任务结果 OK"),
                clock.addAndGet(1_000L),
            )
            withTimeout(3_000) { rollupTurnEntered.await() }
            // 进程在 Router 处理完 rollup 之前崩溃（仅间隔 2s，远小于 10 分钟 wakeClaimTtlMs）
            scope1.cancel()
            store1.close()

            // 重建 kernel2 + router2
            val scope2 = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            val store2 = CloudOrchestrationStore(dir)
            val convStorage2 = JsonConversationStorage(ConversationFile(File(dir, "conversations").apply { mkdirs() }.absolutePath))
            val kernel2 = DefaultCloudOrchestrationKernel(
                store = store2,
                conversationStorage = convStorage2,
                toolRegistry = app.amber.cloud.runtime.CloudToolRegistry(),
                clockMs = { clock.addAndGet(2_000L) },
            )
            val sink2 = CloudOrchestrationKernelTest.MockEditableImSink()
            val router2BrainCalls = AtomicInteger(0)
            val router2 = CloudRouter(
                kernel = kernel2,
                sink = sink2,
                brain = RouterBrain { input ->
                    router2BrainCalls.incrementAndGet()
                    assertTrue(input.events.any { it.kind == "batch_rollup" })
                    RouterDecision(reply = "重启后重投汇总：任务结果 OK")
                },
                clockMs = { clock.get() },
                scope = scope2,
            )
            kernel2.recoverAfterRestart(clock.get())
            withTimeout(3_000) { router2.awaitIdle() }

            assertEquals(1, router2BrainCalls.get(), "重启后应重投一次 rollup")
            assertEquals(1, store2.listWorkItems().size, "重投 rollup 不得重复派单")
            assertTrue(
                sink2.postedMessages.any { it.currentText.contains("重启后重投汇总") && it.address == ImAddress(ChannelKind.TELEGRAM, "chat-b", "topic-b") },
                "原地址必须收到重投后的汇总，实际=${sink2.postedMessages}",
            )
            assertTrue(store2.getBatchRollup(item.batchId)?.deliveredToRouter == true, "处理完成后应写入已处理标记")
            scope2.cancel()
            store2.close()

            // 再次重启，已处理过的 rollup 不再重投
            val scope3 = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            val store3 = CloudOrchestrationStore(dir)
            val convStorage3 = JsonConversationStorage(ConversationFile(File(dir, "conversations").apply { mkdirs() }.absolutePath))
            val kernel3 = DefaultCloudOrchestrationKernel(
                store = store3,
                conversationStorage = convStorage3,
                toolRegistry = app.amber.cloud.runtime.CloudToolRegistry(),
                clockMs = { clock.addAndGet(2_000L) },
            )
            val sink3 = CloudOrchestrationKernelTest.MockEditableImSink()
            val router3 = CloudRouter(
                kernel = kernel3,
                sink = sink3,
                brain = RouterBrain { RouterDecision(reply = "不应再触发") },
                clockMs = { clock.get() },
                scope = scope3,
            )
            kernel3.recoverAfterRestart(clock.get())
            withTimeout(3_000) { router3.awaitIdle() }
            assertTrue(sink3.postedMessages.isEmpty(), "已处理标记落盘后二次重启不得重投")
            scope3.cancel()
            store3.close()
        } finally {
            dir.deleteRecursively()
        }
    }

    // ========================================================================
    // Scenario C: 飞书/Telegram 入站 ACK 后、Router 决策前重启，恢复后只形成一次冻结决策、
    // 零重复派单；同一平台 message/update 重投只处理一次
    // ========================================================================

    @Test
    fun scenario_c_feishu_telegram_inbound_ack_then_restart_freezes_decision_and_dedups_redelivery() = runBlocking {
        val dir = Files.createTempDirectory("amber-im-restart-c").toFile()
        val updatesQueue = CopyOnWriteArrayList<String>()
        val tgSent = CopyOnWriteArrayList<String>()
        val fakeServer = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        fakeServer.createContext("/") { exchange: HttpExchange ->
            val path = exchange.requestURI.path
            val body = exchange.requestBody.readBytes().toString(StandardCharsets.UTF_8)
            val resp = when {
                path.endsWith("/getUpdates") -> """{"ok":true,"result":[${updatesQueue.joinToString(",")}]}"""
                path.endsWith("/sendMessage") -> {
                    tgSent += body
                    """{"ok":true,"result":{"message_id":${100 + tgSent.size}}}"""
                }
                else -> """{"ok":true}"""
            }
            val bytes = resp.toByteArray(StandardCharsets.UTF_8)
            exchange.responseHeaders.add("Content-Type", "application/json")
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        fakeServer.start()
        val baseUrl = "http://127.0.0.1:${fakeServer.address.port}"
        val tgToken = "9988776655:AAH_FAKE_TG_TOKEN_FOR_RESTART_C"

        try {
            val routerEntered1 = CompletableDeferred<Unit>()
            val routerGate1 = CompletableDeferred<Unit>()
            val modelCalls = AtomicInteger(0)

            val first = CloudAgentKernel(dir, CloudModelClient { messages, tools ->
                if (messages.first().toText().startsWith("你是对话标签提取器")) return@CloudModelClient UIMessage.assistant("""{"tags":[]}""")
                modelCalls.incrementAndGet()
                if (tools.any { it.name == "dispatch_work" }) {
                    routerEntered1.complete(Unit)
                    routerGate1.await()
                }
                UIMessage.assistant("旧进程不应到达这里")
            }, masterSecretOverride = "restart-c-secret")
            val logger1 = RedactingChannelLogger()
            val secretLoader1 = ChannelSecretLoader(envProvider = { if (it == TelegramChannel.ENV_BOT_TOKEN) tgToken else null }, logger = logger1)
            first.ownerBinding.bindOwnerDirectly(TelegramChannel.CHANNEL_ID, "123456", "123456")
            val tg1 = TelegramChannel(baseUrl = baseUrl, secretLoader = secretLoader1, ownerBinding = first.ownerBinding, logger = logger1)
            first.registerConnector(tg1)

            val updatePayload = """{"update_id":7001,"message":{"message_id":9001,"from":{"id":123456},"chat":{"id":123456,"type":"private"},"date":1730380000,"text":"帮我核对重启恢复"}}"""
            updatesQueue += updatePayload
            assertEquals(1, tg1.pollOnce())
            // ACK 已返回给 Telegram（sendMessage 收到 ACK），Router 在决策前卡住
            assertEquals(1, tgSent.size)
            withTimeout(3_000) { routerEntered1.await() }

            // 验证 ACK 前已持久写入 dialogue_inputs(kind="im_message") 且未写原生 dialogue_events
            val pendingBeforeCrash = first.orchestrationStore.dialogue.pending(kind = "im_message")
            assertEquals(1, pendingBeforeCrash.size, "IM ACK 前必须持久化到 dialogue_inputs")
            assertEquals(0, first.orchestrationStore.dialogue.page(0, 100).items.size, "IM 输入不得额外复制进原生 dialogue_events")

            // 模拟重启
            shutdownKernelForRestart(first)
            routerGate1.complete(Unit)

            // 重启后：恢复并执行一次冻结决策与派单
            val second = CloudAgentKernel(dir, CloudModelClient { messages, tools ->
                if (messages.first().toText().startsWith("你是对话标签提取器")) return@CloudModelClient UIMessage.assistant("""{"tags":[]}""")
                if (tools.any { it.name == "dispatch_work" }) {
                    modelCalls.incrementAndGet()
                    UIMessage.assistant("").copy(parts = listOf(UIMessagePart.Tool(
                        toolCallId = "d-c-1", toolName = "dispatch_work",
                        input = """{"tasks":[{"task_key":"c-task-1","title":"恢复核对","brief":"核对"}]}""",
                    )))
                } else {
                    UIMessage.assistant("重启恢复完成")
                }
            }, masterSecretOverride = "restart-c-secret")
            second.orchestrationKernel.workerTurnRunner = { item, _ ->
                WorkerSettlementReport(item.workItemId, "completed", "核对完成")
            }
            val logger2 = RedactingChannelLogger()
            val tg2 = TelegramChannel(
                baseUrl = baseUrl,
                secretLoader = ChannelSecretLoader(envProvider = { if (it == TelegramChannel.ENV_BOT_TOKEN) tgToken else null }, logger = logger2),
                ownerBinding = second.ownerBinding,
                logger = logger2,
            )
            second.registerConnector(tg2)
            try {
                second.recoverColdStartConversations()
                withTimeout(5_000) { second.router.awaitIdle(includeWorkers = true) }

                assertEquals(1, second.orchestrationStore.listWorkItems().size, "恢复后只能派单一次")
                assertTrue(second.orchestrationStore.dialogue.pending(kind = "im_message").isEmpty(), "轮次结束后 im_message 必须整体 consume")
                assertEquals(0, second.orchestrationStore.dialogue.page(0, 100).items.count { it.kind == "user_message" }, "IM 输入不得进入原生 dialogue_events")
                val callsAfterRecovery = modelCalls.get()

                // 模拟 Telegram 重启后以 offset=0 再次投递同一个 update_id=7001 / message_id=9001
                val third = CloudAgentKernel(dir, CloudModelClient { messages, tools ->
                    if (messages.first().toText().startsWith("你是对话标签提取器")) return@CloudModelClient UIMessage.assistant("""{"tags":[]}""")
                    if (tools.any { it.name == "dispatch_work" }) modelCalls.incrementAndGet()
                    UIMessage.assistant("不应重复处理")
                }, masterSecretOverride = "restart-c-secret")
                val logger3 = RedactingChannelLogger()
                val tg3 = TelegramChannel(
                    baseUrl = baseUrl,
                    secretLoader = ChannelSecretLoader(envProvider = { if (it == TelegramChannel.ENV_BOT_TOKEN) tgToken else null }, logger = logger3),
                    ownerBinding = third.ownerBinding,
                    logger = logger3,
                )
                third.registerConnector(tg3)
                try {
                    third.recoverColdStartConversations()
                    // updatesQueue 仍包含 update_id=7001，新实例 nextUpdateOffset=0 且内存去重表为空
                    tg3.pollOnce()
                    withTimeout(3_000) { third.router.awaitIdle(includeWorkers = true) }

                    assertEquals(callsAfterRecovery, modelCalls.get(), "同一平台 message/update 重投不得再次调用 Router 模型")
                    assertEquals(1, third.orchestrationStore.listWorkItems().size, "重投不得产生重复派单")
                    val userNodes = third.conversationStorage.loadConversation(PRIMARY_CONVERSATION_ID)!!
                        .messageNodes.filter { it.currentMessage.toText().contains("帮我核对重启恢复") }
                    assertEquals(1, userNodes.size, "重投不得在主时间线写入重复用户消息")
                } finally {
                    shutdownKernelForRestart(third)
                }
            } finally {
                shutdownKernelForRestart(second)
            }
        } finally {
            fakeServer.stop(0)
            dir.deleteRecursively()
        }
    }

    @Test
    fun scenario_c_frozen_plan_replayed_without_second_model_call() = runBlocking {
        val dir = Files.createTempDirectory("amber-im-frozen-plan").toFile()
        val brainCalls = AtomicInteger(0)
        try {
            val store1 = CloudOrchestrationStore(dir)
            val conv1 = JsonConversationStorage(ConversationFile(File(dir, "conversations").apply { mkdirs() }.absolutePath))
            val k1 = DefaultCloudOrchestrationKernel(store = store1, conversationStorage = conv1, toolRegistry = app.amber.cloud.runtime.CloudToolRegistry())
            val msg = InboundMessage(
                messageId = "fs-freeze-1",
                channel = ChannelKind.FEISHU,
                chatId = "oc_freeze",
                senderId = "ou_owner",
                senderRole = SenderRole.OWNER,
                scope = ConversationScope.DIRECT,
                text = "触发冻结决策测试",
            )
            k1.routeInboundMessage(msg, PRIMARY_CONVERSATION_ID.toString(), 1_000L)
            // 模拟决策已写入 dialogue_plans 并已派单一次，但进程在 consume 前崩溃
            val frozenEvent = k1.listObservableRouterEvents().single()
            val planId = "dialogue-plan:" + frozenEvent.eventId
            val frozen = RouterDecision(
                reply = "已冻结派单",
                dispatch = listOf(WorkItemSubmissionSpec("freeze-task", "冻结任务", "只执行一次", ExecutionTargetNode.CloudSubagent("w"))),
            )
            store1.dialogue.savePlan(planId, frozen)
            k1.submitWorkBatch(
                principal = CloudPrincipal.CloudCoordinator(activeSessionId = PRIMARY_CONVERSATION_ID.toString(), activeTurnId = "t1"),
                requestId = "router:" + OrchestrationHash.sha256Hex("${frozenEvent.eventId}|freeze-task").take(32),
                contextMessageIds = listOf(frozenEvent.sourceMessageId!!),
                items = frozen.dispatch,
                nowEpochMs = 1_001L,
            )
            store1.close()

            // 重启恢复：应直接命中冻结决策，0 次调用 RouterBrain，0 重复派单
            val scope2 = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            val store2 = CloudOrchestrationStore(dir)
            val conv2 = JsonConversationStorage(ConversationFile(File(dir, "conversations").apply { mkdirs() }.absolutePath))
            val k2 = DefaultCloudOrchestrationKernel(store = store2, conversationStorage = conv2, toolRegistry = app.amber.cloud.runtime.CloudToolRegistry())
            val sink2 = CloudOrchestrationKernelTest.MockEditableImSink()
            val router2 = CloudRouter(
                kernel = k2,
                sink = sink2,
                brain = RouterBrain {
                    brainCalls.incrementAndGet()
                    RouterDecision(reply = "不应该被再次调用")
                },
                scope = scope2,
            )
            k2.recoverAfterRestart(2_000L)
            withTimeout(3_000) { router2.awaitIdle() }

            assertEquals(0, brainCalls.get(), "命中冻结决策重放时绝对不能再次调用模型")
            assertEquals(1, store2.listWorkItems().size, "重放不得产生重复派单")
            assertTrue(store2.dialogue.pending(kind = "im_message").isEmpty(), "重放完成后应 consume pending 输入")
            assertTrue(sink2.postedMessages.any { it.currentText.contains("已冻结派单") })
            scope2.cancel()
            store2.close()
        } finally {
            dir.deleteRecursively()
        }
    }

    // ========================================================================
    // Scenario D: Worker await() 时直通立即唤醒；task_finish 前补充被结算屏障拦住；权限语义不变
    // ========================================================================

    @Test
    fun scenario_d_worker_await_wakes_immediately_and_settlement_barrier_holds_until_consumed() = runBlocking {
        val dir = Files.createTempDirectory("amber-im-restart-d").toFile()
        val workerAwaitEntered = CompletableDeferred<Unit>()
        val workerStep2Prompt = CompletableDeferred<String>()
        val barrierHookEntered = CompletableDeferred<Unit>()
        val releaseBarrierHook = CompletableDeferred<Unit>()
        val stepCounter = AtomicInteger(0)

        val kernel = CloudAgentKernel(dir, CloudModelClient { messages, tools ->
            if (messages.first().toText().startsWith("你是对话标签提取器")) return@CloudModelClient UIMessage.assistant("""{"tags":[]}""")
            if (tools.any { it.name == "dispatch_work" }) {
                return@CloudModelClient UIMessage.assistant("").copy(parts = listOf(UIMessagePart.Tool(
                    toolCallId = "d-pass", toolName = "dispatch_work",
                    input = """{"tasks":[{"task_key":"await-task","title":"后台直通测试","brief":"启动后台进程并等待直通补充","thread_keys":["telegram:group:grp-d"]}]}""",
                )))
            }
            val step = stepCounter.incrementAndGet()
            val historyText = messages.joinToString("\n") { it.toText() }
            when (step) {
                1 -> {
                    // 启动后台进程
                    UIMessage.assistant("").copy(parts = listOf(UIMessagePart.Tool(
                        toolCallId = "proc-bg-1", toolName = "process_run",
                        input = """{"argv":["/bin/sleep","30"],"background":true}""",
                    )))
                }
                2 -> {
                    // 无工具调用 -> 进入 workerEvents.await()
                    workerAwaitEntered.complete(Unit)
                    UIMessage.assistant("后台进程运行中，等待新事件。")
                }
                3 -> {
                    workerStep2Prompt.complete(historyText)
                    val procOutput = messages.flatMap { it.parts }.filterIsInstance<UIMessagePart.Tool>()
                        .firstOrNull { it.toolName == "process_run" }?.output?.joinToString("") ?: ""
                    val procId = Regex("\"id\"\\s*:\\s*\"([^\"]+)\"").find(procOutput)?.groupValues?.get(1) ?: ""
                    UIMessage.assistant("").copy(parts = listOf(UIMessagePart.Tool(
                        toolCallId = "proc-stop-1", toolName = "process_stop",
                        input = """{"id":"$procId"}""",
                    )))
                }
                4 -> {
                    // 在 task_finish 前先阻塞一下，让测试注入第二条直通消息触发结算屏障
                    barrierHookEntered.complete(Unit)
                    releaseBarrierHook.await()
                    UIMessage.assistant("").copy(parts = listOf(UIMessagePart.Tool(
                        toolCallId = "finish-early", toolName = "task_finish",
                        input = """{"outcome":"completed","summary":"尝试提前结算"}""",
                    )))
                }
                else -> {
                    assertTrue(historyText.contains("补充要求二：请带上最终版本号"), "Worker 必须先消费第二条直通补充才能结算")
                    UIMessage.assistant("").copy(parts = listOf(UIMessagePart.Tool(
                        toolCallId = "finish-final", toolName = "task_finish",
                        input = """{"outcome":"completed","summary":"已读取全部直通补充并完成"}""",
                    )))
                }
            }
        }, masterSecretOverride = "restart-d-secret")

        val connector = RecordingConnector(ChannelKind.TELEGRAM)
        kernel.registerConnector(connector)
        try {
            // 1) 主人在群里派发任务（订阅 telegram:group:grp-d）
            connector.ingress.handleInbound(
                InboundMessage(
                    messageId = "d-init-1",
                    channel = ChannelKind.TELEGRAM,
                    chatId = "grp-d",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    scope = ConversationScope.GROUP,
                    text = "在群里跑一个后台任务",
                )
            )
            withTimeout(5_000) { workerAwaitEntered.await() }
            val workItem = kernel.orchestrationStore.listWorkItems().single()
            // 确保后台进程仍在运行，Worker 已进入 workerEvents.await()
            delay(100)
            assertTrue(kernel.taskProcesses.active(workItem.workItemId))

            // 2) 协作者发 Thread 直通消息 -> 必须立即唤醒 await() 中的 Worker（不需等 sleep 30 结束）
            val passAck1 = connector.ingress.handleInbound(
                InboundMessage(
                    messageId = "d-pass-1",
                    channel = ChannelKind.TELEGRAM,
                    chatId = "grp-d",
                    senderId = "collab-2",
                    senderRole = SenderRole.COLLABORATOR,
                    scope = ConversationScope.GROUP,
                    text = "补充要求一：请顺便核对配置",
                )
            )
            assertIs<DefaultCloudOrchestrationKernel.InboundRoutingDecision.DirectPassThroughToWorkers>(
                kernel.router.onInbound(
                    InboundMessage(
                        messageId = "d-pass-1-check",
                        channel = ChannelKind.TELEGRAM,
                        chatId = "grp-d",
                        senderId = "collab-2",
                        senderRole = SenderRole.COLLABORATOR,
                        scope = ConversationScope.GROUP,
                        text = "权限探测：协作者应允许直通",
                    )
                ).routing
            )
            assertTrue(passAck1.text.contains("已转给进行中的"))

            val wokenPrompt = withTimeout(3_000) { workerStep2Prompt.await() }
            assertTrue(wokenPrompt.contains("补充要求一：请顺便核对配置"), "await() 唤醒后应立即读取到直通消息")

            // 3) 等 Worker 进入准备调 task_finish 的第 3 步 -> 在 task_finish 执行前发直通补充，触发结算屏障
            withTimeout(3_000) { barrierHookEntered.await() }
            connector.ingress.handleInbound(
                InboundMessage(
                    messageId = "d-pass-2",
                    channel = ChannelKind.TELEGRAM,
                    chatId = "grp-d",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    scope = ConversationScope.GROUP,
                    text = "补充要求二：请带上最终版本号",
                )
            )
            releaseBarrierHook.complete(Unit)

            withTimeout(5_000) { kernel.router.awaitIdle(includeWorkers = true) }
            val settled = kernel.orchestrationStore.getWorkItem(workItem.workItemId)!!
            assertEquals(WorkItemState.COMPLETED, settled.state)
            val report = kernel.orchestrationStore.readArchivedDocumentText(settled.settlementReportPath!!)!!
            assertTrue(report.contains("已读取全部直通补充并完成"), "必须消费第二条直通补充后才结算，实际报告=$report")

            // 4) 权限语义不变：ExternalCaller (COLLABORATOR) 不能调 steerWorker / submitWorkBatch；GROUP+GUEST 仍被拦截
            assertFailsWith<PrincipalPermissionException> {
                kernel.orchestrationKernel.steerWorker(
                    CloudPrincipal.ExternalCaller("collab-2", "telegram", SenderRole.COLLABORATOR),
                    workItem.workItemId,
                    "越权引导",
                )
            }
            assertFailsWith<PrincipalPermissionException> {
                kernel.orchestrationKernel.submitWorkBatch(
                    CloudPrincipal.ExternalCaller("collab-2", "telegram", SenderRole.COLLABORATOR),
                    "req-unauth",
                    listOf("d-pass-1"),
                    listOf(WorkItemSubmissionSpec("x", "x", "x", ExecutionTargetNode.CloudSubagent("w"))),
                )
            }
            val guestRejected = connector.ingress.handleInbound(
                InboundMessage(
                    messageId = "d-guest-1",
                    channel = ChannelKind.TELEGRAM,
                    chatId = "grp-d",
                    senderId = "guest-9",
                    senderRole = SenderRole.GUEST,
                    scope = ConversationScope.GROUP,
                    text = "路人消息",
                )
            )
            assertTrue(guestRejected.text.contains("仅响应已绑定的主人或授权协作者"))
        } finally {
            releaseBarrierHook.complete(Unit)
            kernel.orchestrationStore.listWorkItems().forEach { kernel.taskProcesses.cancelTask(it.workItemId) }
            shutdownKernelForRestart(kernel)
            dir.deleteRecursively()
        }
    }
}
