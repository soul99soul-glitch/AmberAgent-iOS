package app.amber.cloud.orchestration

import app.amber.ai.core.MessageRole
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.channel.ChannelKind
import app.amber.cloud.channel.ConversationScope
import app.amber.cloud.channel.InboundMessage
import app.amber.cloud.channel.OutboundCard
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.proactive.L2NoteworthyScore
import app.amber.cloud.proactive.NoteworthyJudgeProvider
import app.amber.cloud.proactive.ProactiveEngine
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.runtime.CloudToolDefinition
import app.amber.cloud.runtime.CloudToolRegistry
import app.amber.cloud.runtime.ExecutionScope
import app.amber.cloud.runtime.ToolEffect
import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.PlaceholderCredentialException
import app.amber.core.storage.conversation.ConversationFile
import app.amber.core.storage.conversation.JsonConversationStorage
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
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
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CloudOrchestrationKernelTest {

    private class Harness(
        val tempDir: File = Files.createTempDirectory("amber-orch-test").toFile(),
        config: OrchestrationConfig = OrchestrationConfig(),
        initialEpochMs: Long = 1_762_000_000_000L,
        withProactiveEngine: Boolean = false,
    ) : AutoCloseable {
        val clock = AtomicLong(initialEpochMs)
        val conversationsDir = File(tempDir, "conversations").also { it.mkdirs() }
        val conversationStorage = JsonConversationStorage(ConversationFile(conversationsDir.absolutePath))
        val store = CloudOrchestrationStore(tempDir, ringBufferCapacity = 8)
        val toolRegistry = CloudToolRegistry().also { reg ->
            reg.register(
                CloudToolDefinition(
                    name = "history_search",
                    description = "只读搜索历史",
                    highRisk = false,
                    effect = ToolEffect.PURE,
                ) { buildJsonObject { put("ok", true); put("hits", buildJsonArray {}) } }
            )
            reg.register(
                CloudToolDefinition(
                    name = "workspace_file_write",
                    description = "写工作区文件",
                    highRisk = false,
                    effect = ToolEffect.SIDE_EFFECT,
                ) { buildJsonObject { put("ok", true) } }
            )
            reg.register(
                CloudToolDefinition(
                    name = "terminal_exec",
                    description = "高风险终端执行",
                    highRisk = true,
                    effect = ToolEffect.SIDE_EFFECT,
                ) { buildJsonObject { put("ok", true) } }
            )
            reg.register(
                CloudToolDefinition(
                    name = "ssh_profile_create",
                    description = "高风险 SSH 配置",
                    highRisk = true,
                    effect = ToolEffect.SIDE_EFFECT,
                ) { buildJsonObject { put("ok", true) } }
            )
        }
        val pushedCards = CopyOnWriteArrayList<Pair<OutboundCard, String>>()
        val proactiveEngine: ProactiveEngine? = if (withProactiveEngine) {
            ProactiveEngine(
                l2Judge = NoteworthyJudgeProvider { req ->
                    L2NoteworthyScore(
                        noteworthy = true,
                        urgency = 4,
                        importance = 4,
                        summary = req.deltaSummary.take(80),
                    )
                },
                clockMs = { clock.get() },
            )
        } else {
            null
        }
        val kernel = DefaultCloudOrchestrationKernel(
            config = config,
            store = store,
            conversationStorage = conversationStorage,
            toolRegistry = toolRegistry,
            clockMs = { clock.get() },
            onOwnerNotificationCard = { card, id -> pushedCards.add(card to id) },
            proactiveEngine = proactiveEngine,
        )

        fun recordOwnerMessage(
            messageId: String,
            text: String,
            sessionId: String = PRIMARY_CONVERSATION_ID.toString(),
            threadKey: String? = null,
        ): String {
            val now = clock.get()
            store.recordSourceMessage(
                provenance = SourceMessageProvenance(
                    sessionId = sessionId,
                    messageId = messageId,
                    senderId = "owner-1",
                    channelId = "telegram",
                    senderRole = SenderRole.OWNER,
                    origin = MessageProvenanceOrigin.OWNER_HUMAN,
                    rawTextHash = OrchestrationHash.sha256Hex(text),
                    createdAtEpochMs = now,
                ),
                rawText = text,
                threadKey = threadKey,
            )
            return messageId
        }

        fun coordinatorPrincipal(turnId: String = "turn-1") = CloudPrincipal.CloudCoordinator(
            activeSessionId = PRIMARY_CONVERSATION_ID.toString(),
            activeTurnId = turnId,
        )

        override fun close() {
            kernel.stopHealthLoop()
            store.close()
            tempDir.deleteRecursively()
        }
    }

    private class MockEditableImSink : ImStatusSink {
        data class MessageEntry(
            val messageId: String,
            val address: ImAddress,
            var currentText: String,
            val editHistory: MutableList<String> = mutableListOf(),
        )

        private val seq = AtomicInteger(0)
        val postedMessages = CopyOnWriteArrayList<MessageEntry>()

        override suspend fun post(address: ImAddress, text: String): String {
            val id = "im-msg-${seq.incrementAndGet()}"
            postedMessages.add(
                MessageEntry(
                    messageId = id,
                    address = address,
                    currentText = text,
                    editHistory = mutableListOf(text),
                )
            )
            return id
        }

        override suspend fun edit(address: ImAddress, messageId: String, text: String): Boolean {
            val existing = postedMessages.firstOrNull { it.messageId == messageId } ?: return false
            existing.currentText = text
            existing.editHistory.add(text)
            return true
        }

        fun entryFor(messageId: String): MessageEntry? =
            postedMessages.firstOrNull { it.messageId == messageId }
    }

    // ========================================================================
    // 1. 并发槽位（默认 3，可配 3..8；配置为 2 或 9 报错；溢出任务排队并在释放后自动推进）
    // ========================================================================

    @Test
    fun concurrency_slots_default_3_range_3_to_8_rejects_2_and_9_and_queues_overflow() = runTest {
        assertFailsWith<IllegalArgumentException> {
            OrchestrationConfig(maxConcurrentWorkers = 2)
        }
        assertFailsWith<IllegalArgumentException> {
            OrchestrationConfig(maxConcurrentWorkers = 9)
        }
        assertEquals(3, OrchestrationConfig().maxConcurrentWorkers)
        assertEquals(8, OrchestrationConfig(maxConcurrentWorkers = 8).maxConcurrentWorkers)

        Harness(config = OrchestrationConfig(maxConcurrentWorkers = 3)).use { h ->
            val msgId = h.recordOwnerMessage("msg-slot-1", "同时跑 5 个子任务")
            val specs = (1..5).map { idx ->
                WorkItemSubmissionSpec(
                    taskKey = "task-$idx",
                    title = "子任务 $idx",
                    brief = "执行第 $idx 项检查",
                    targetNode = ExecutionTargetNode.CloudSubagent(rolePrompt = "worker-$idx"),
                )
            }
            val batch = h.kernel.submitWorkBatch(
                principal = h.coordinatorPrincipal(),
                requestId = "req-slots-5",
                contextMessageIds = listOf(msgId),
                items = specs,
                nowEpochMs = h.clock.get(),
            )
            assertEquals(5, batch.items.size)
            assertEquals(3, h.store.countHeldSlots())

            val working = batch.items.filter { it.state == WorkItemState.WORKING }
            val queued = batch.items.filter { it.state == WorkItemState.QUEUED }
            assertEquals(3, working.size)
            assertEquals(2, queued.size)
            assertTrue(working.all { it.slotHeld })
            assertTrue(queued.all { !it.slotHeld })

            // 结算第 1 个 WORKING 任务 -> 释放槽位并自动唤醒第 4 个排队任务
            val first = working.first()
            h.kernel.reportWorkerSettlement(
                principal = h.kernel.workerPrincipalFor(first),
                report = WorkerSettlementReport(
                    workItemId = first.workItemId,
                    outcome = "completed",
                    summary = "第 1 项已完成",
                ),
                nowEpochMs = h.clock.addAndGet(1_000L),
            )
            assertEquals(3, h.store.countHeldSlots())
            val task4 = h.store.getWorkItem(queued.first().workItemId)!!
            assertEquals(WorkItemState.WORKING, task4.state)
            assertTrue(task4.slotHeld)
        }
    }

    // ========================================================================
    // 2. 三层幂等重放、同键篡改冲突拦截与进程重启 SQLite 恢复
    // ========================================================================

    @Test
    fun idempotent_replay_conflict_detection_and_restart_recovery_from_sqlite() = runTest {
        val tempDir = Files.createTempDirectory("amber-orch-restart").toFile()
        try {
            var workItem1Id = ""
            var workItem4Id = ""

            // --- Process 1 ---
            Harness(tempDir = tempDir).use { _ -> } // cleanup helper not used; manage lifecycle manually below
        } finally {
            tempDir.deleteRecursively()
        }

        val restartDir = Files.createTempDirectory("amber-orch-restart-db").toFile()
        try {
            val h1 = Harness(tempDir = restartDir)
            val msgId = h1.recordOwnerMessage("msg-idem-1", "分析日志并检查配置")
            val specs = (1..4).map { idx ->
                WorkItemSubmissionSpec(
                    taskKey = "idem-task-$idx",
                    title = "幂等任务 $idx",
                    brief = "说明 $idx",
                    targetNode = ExecutionTargetNode.CloudSubagent("worker"),
                )
            }

            val firstSubmit = h1.kernel.submitWorkBatch(
                principal = h1.coordinatorPrincipal("turn-a"),
                requestId = "req-idem-1",
                contextMessageIds = listOf(msgId),
                items = specs,
                nowEpochMs = h1.clock.get(),
            )
            assertTrue(firstSubmit.replayedWorkItemIds.isEmpty())

            // Layer 3: 相同 requestId 重放 -> 直接返回原批次且全部标记为 replayed
            val sameRequestReplay = h1.kernel.submitWorkBatch(
                principal = h1.coordinatorPrincipal("turn-a"),
                requestId = "req-idem-1",
                contextMessageIds = listOf(msgId),
                items = specs,
                nowEpochMs = h1.clock.addAndGet(500L),
            )
            assertEquals(firstSubmit.batchId, sameRequestReplay.batchId)
            assertEquals(4, sameRequestReplay.replayedWorkItemIds.size)

            // Layer 2: 不同 requestId 但相同 (scopeKey, taskKey) 且相同指纹 -> 幂等重放已有 WorkItem
            val sameTaskKeyReplay = h1.kernel.submitWorkBatch(
                principal = h1.coordinatorPrincipal("turn-b"),
                requestId = "req-idem-2",
                contextMessageIds = listOf(msgId),
                items = listOf(specs.first()),
                nowEpochMs = h1.clock.addAndGet(500L),
            )
            assertEquals(setOf(firstSubmit.items.first().workItemId), sameTaskKeyReplay.replayedWorkItemIds)

            // Layer 2 Conflict: 相同 (scopeKey, taskKey) 但篡改 brief 内容 -> 抛 WorkItemConflictException
            assertFailsWith<WorkItemConflictException> {
                h1.kernel.submitWorkBatch(
                    principal = h1.coordinatorPrincipal("turn-c"),
                    requestId = "req-idem-conflict",
                    contextMessageIds = listOf(msgId),
                    items = listOf(specs.first().copy(brief = "被篡改的不同任务说明")),
                    nowEpochMs = h1.clock.addAndGet(500L),
                )
            }

            val item1Id = firstSubmit.items.first { it.state == WorkItemState.WORKING }.workItemId
            val item4Id = firstSubmit.items.single { it.state == WorkItemState.QUEUED }.workItemId
            assertEquals(WorkItemState.WORKING, h1.store.getWorkItem(item1Id)!!.state)
            assertEquals(WorkItemState.QUEUED, h1.store.getWorkItem(item4Id)!!.state)
            h1.store.close()

            // --- Process 2 (模拟守护进程重启，基于同一 SQLite 数据库恢复) ---
            val store2 = CloudOrchestrationStore(restartDir)
            val convStorage2 = JsonConversationStorage(ConversationFile(File(restartDir, "conversations").absolutePath))
            val kernel2 = DefaultCloudOrchestrationKernel(
                store = store2,
                conversationStorage = convStorage2,
                toolRegistry = CloudToolRegistry(),
                clockMs = { h1.clock.get() },
            )
            val recovered = kernel2.recoverAfterRestart(h1.clock.addAndGet(2_000L))
            assertEquals(4, recovered.size)
            assertEquals(3, store2.countHeldSlots())
            assertEquals(WorkItemState.WORKING, store2.getWorkItem(item1Id)!!.state)
            assertEquals(WorkItemState.QUEUED, store2.getWorkItem(item4Id)!!.state)
            store2.close()
        } finally {
            restartDir.deleteRecursively()
        }
    }

    // ========================================================================
    // 3. Thread 多对多订阅直通（Fast Path 不经过 Router）
    // ========================================================================

    @Test
    fun many_to_many_thread_subscription_fast_path_bypasses_router() = runTest {
        Harness().use { h ->
            val sink = MockEditableImSink()
            val routerBrainCalls = AtomicInteger(0)
            val router = CloudRouter(
                kernel = h.kernel,
                sink = sink,
                brain = RouterBrain {
                    routerBrainCalls.incrementAndGet()
                    RouterDecision(reply = "Router 已处理")
                },
                clockMs = { h.clock.get() },
            )

            val ownerMsg = h.recordOwnerMessage("msg-sub-init", "启动两个协同 Worker")
            val batch = h.kernel.submitWorkBatch(
                principal = h.coordinatorPrincipal(),
                requestId = "req-sub-m2m",
                contextMessageIds = listOf(ownerMsg),
                items = listOf(
                    WorkItemSubmissionSpec(
                        taskKey = "worker-a",
                        title = "修复 PR 101",
                        brief = "跟进 PR 101 与群话题 202",
                        targetNode = ExecutionTargetNode.CloudSubagent("coder-a"),
                        subscribedThreadKeys = listOf("telegram:chat-1:pr-101", "telegram:chat-1:topic-202"),
                    ),
                    WorkItemSubmissionSpec(
                        taskKey = "worker-b",
                        title = "审查 PR 101",
                        brief = "共同关注 PR 101",
                        targetNode = ExecutionTargetNode.CloudSubagent("reviewer-b"),
                        subscribedThreadKeys = listOf("telegram:chat-1:pr-101"),
                    ),
                ),
                nowEpochMs = h.clock.get(),
            )
            val workerA = batch.items[0]
            val workerB = batch.items[1]

            // 发送命中已订阅 Thread (pr-101) 的后续消息 -> 同时直通给 Worker A 和 Worker B，不调用 RouterBrain！
            val ack = router.onInbound(
                InboundMessage(
                    messageId = "msg-pr-101-followup",
                    channel = ChannelKind.TELEGRAM,
                    chatId = "chat-1",
                    threadId = "pr-101",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    scope = ConversationScope.DIRECT,
                    text = "PR 101 刚刚补充了一条 CI 报错日志",
                )
            )
            router.awaitIdle()

            val passThrough = assertIs<DefaultCloudOrchestrationKernel.InboundRoutingDecision.DirectPassThroughToWorkers>(ack.routing)
            assertEquals(listOf(workerA.workItemId, workerB.workItemId), passThrough.workerItemIds)
            assertEquals(1, h.kernel.directPassThroughCount.get())
            assertEquals(0, routerBrainCalls.get(), "命中已订阅 Thread 的直通事件不得调用 Router 模型推理")

            // 验证两个 Worker 的隔离会话都收到了该直通消息
            val pageA = h.kernel.readWorkerSessionPage(workerA.workerSessionId!!)
            val pageB = h.kernel.readWorkerSessionPage(workerB.workerSessionId!!)
            assertTrue(pageA.items.any { it.previewText.contains("CI 报错日志") })
            assertTrue(pageB.items.any { it.previewText.contains("CI 报错日志") })

            // 同时 Router 的全局可观测列表中仍保留该事件
            assertTrue(h.kernel.listObservableRouterEvents().any { it.sourceMessageId == "msg-pr-101-followup" })
        }
    }

    // ========================================================================
    // 4. 异步工具 start/stop 与后台运行期间 Router 全双工响应
    // ========================================================================

    @Test
    fun async_tool_start_stop_and_background_worker_do_not_block_router() = runBlocking {
        Harness().use { h ->
            val sink = MockEditableImSink()
            val router = CloudRouter(
                kernel = h.kernel,
                sink = sink,
                brain = RouterBrain { input ->
                    RouterDecision(reply = "前台即时回复：收到 ${input.events.size} 条消息")
                },
                clockMs = { h.clock.get() },
            )

            val gate = CompletableDeferred<Unit>()
            val started = h.kernel.startAsyncTool(
                toolName = "long_Index_Build",
                nowEpochMs = h.clock.get(),
            ) {
                gate.await()
                "索引构建完成"
            }
            assertEquals("Started", started.status)
            assertEquals("Running", h.kernel.getAsyncToolStatus(started.handleId))

            // 后台异步工具仍在挂起运行时，Router 依然能立即确认并完成前台回复
            val ack = router.onInbound(
                InboundMessage(
                    messageId = "msg-while-async",
                    channel = ChannelKind.TELEGRAM,
                    chatId = "chat-1",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    text = "后台在跑的时候我还能说话吗？",
                )
            )
            assertTrue(ack.latencyMs < 2_000L)
            router.awaitIdle()
            assertTrue(router.outboundLog.any { it.contains("前台即时回复") })

            // 主动调用 stopAsyncTool 终止后台任务
            val stopped = h.kernel.stopAsyncTool(started.handleId, nowEpochMs = h.clock.addAndGet(500L))
            assertTrue(stopped.stopped)
            assertEquals("Stopped", stopped.status)
            assertEquals("Stopped", h.kernel.getAsyncToolStatus(started.handleId))
        }
    }

    // ========================================================================
    // 5. Router 批处理合并（上一轮推理期间积压的多条事件在下一轮合并为单次调用）
    // ========================================================================

    @Test
    fun router_batches_accumulated_events_while_busy() = runBlocking {
        Harness().use { h ->
            val sink = MockEditableImSink()
            val turn1Gate = CompletableDeferred<Unit>()
            val turn1Entered = CompletableDeferred<Unit>()

            val router = CloudRouter(
                kernel = h.kernel,
                sink = sink,
                brain = RouterBrain { input ->
                    if (input.events.any { it.sourceMessageId == "m-1" }) {
                        turn1Entered.complete(Unit)
                        turn1Gate.await()
                    }
                    RouterDecision(reply = "本轮合并处理了 ${input.events.size} 条事件")
                },
                clockMs = { h.clock.get() },
            )

            // 第 1 条消息进入 Router 并使 Turn 1 处于推理中
            router.onInbound(
                InboundMessage(
                    messageId = "m-1",
                    channel = ChannelKind.TELEGRAM,
                    chatId = "chat-1",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    text = "第一条请求",
                )
            )
            turn1Entered.await()
            assertTrue(h.kernel.isRouterTurnBusy)

            // 在 Turn 1 推理期间连续到达 m-2, m-3, m-4 -> 全部进入批处理队列且不阻塞确认
            for (i in 2..4) {
                val ack = router.onInbound(
                    InboundMessage(
                        messageId = "m-$i",
                        channel = ChannelKind.TELEGRAM,
                        chatId = "chat-1",
                        senderId = "owner-1",
                        senderRole = SenderRole.OWNER,
                        text = "积压请求 $i",
                    )
                )
                assertIs<DefaultCloudOrchestrationKernel.InboundRoutingDecision.QueuedForRouterBatch>(ack.routing)
            }

            // 放行 Turn 1 -> Turn 2 自动把 m-2, m-3, m-4 合并为单次批处理（batch size = 3）
            turn1Gate.complete(Unit)
            router.awaitIdle()

            assertEquals(listOf(1, 3), router.lastTurnEventCounts.toList())
            assertEquals(1, h.kernel.routerBatchedCallCount.get())
            assertTrue(router.outboundLog.any { it.contains("本轮合并处理了 3 条事件") })
        }
    }

    // ========================================================================
    // 6. 巡检阈值、45 分钟长耗时工具豁免、最多 2 次有界自愈阶梯与外部 Watchdog
    // ========================================================================

    @Test
    fun deterministic_health_tick_thresholds_45m_long_tool_exemption_and_bounded_recovery_ladder() = runTest {
        Harness(
            config = OrchestrationConfig(
                maxConcurrentWorkers = 5,
                modelWatchdogEnabled = false,
            )
        ).use { h ->
            val msgId = h.recordOwnerMessage("msg-health-1", "启动巡检测试任务")
            val batch = h.kernel.submitWorkBatch(
                principal = h.coordinatorPrincipal(),
                requestId = "req-health",
                contextMessageIds = listOf(msgId),
                items = listOf(
                    WorkItemSubmissionSpec("t-quiet", "静默卡住任务", "模拟静默", ExecutionTargetNode.CloudSubagent("w1")),
                    WorkItemSubmissionSpec("t-build", "长编译任务", "运行 xcodebuild", ExecutionTargetNode.CloudSubagent("w2")),
                    WorkItemSubmissionSpec("t-wait", "等待审批任务", "等待审批", ExecutionTargetNode.CloudSubagent("w3")),
                    WorkItemSubmissionSpec("t-start", "未启动任务", "卡在 STARTING", ExecutionTargetNode.CloudSubagent("w4")),
                ),
                nowEpochMs = h.clock.get(),
            )
            val quietId = batch.items[0].workItemId
            val buildId = batch.items[1].workItemId
            val waitId = batch.items[2].workItemId
            val startId = batch.items[3].workItemId

            // 设置 build 任务正在跑 xcodebuild，wait 任务处于 WAITING，start 任务处于 STARTING
            h.kernel.updateWorkerProgress(
                principal = h.kernel.workerPrincipalFor(batch.items[1]),
                workItemId = buildId,
                expectedRevision = 0,
                progressNote = "正在编译归档",
                activeToolName = "xcodebuild",
                nowEpochMs = h.clock.get(),
            )
            h.kernel.transitionWorkItemState(waitId, WorkItemState.WAITING, h.clock.get(), "等待前台高危审批")
            h.kernel.transitionWorkItemState(startId, WorkItemState.STARTING, h.clock.get(), "正在唤醒节点")

            // 推进 3 分钟：startId 触发 never_started
            val actionsAt3m = h.kernel.runDeterministicHealthTick(h.clock.addAndGet(3 * 60_000L))
            assertTrue(actionsAt3m.any { it.workItemId == startId && it.finding == "never_started" })
            // 把 startId 结算掉以便后续专注验证其余任务
            h.kernel.reportWorkerSettlement(
                h.kernel.workerPrincipalFor(batch.items[3]),
                WorkerSettlementReport(startId, "completed", "已启动并完成"),
                h.clock.get(),
            )

            // 再推进 2 分钟（总 T+5m）：waitId 满 5 分钟触发 approval_wait_timeout
            val actionsAt5m = h.kernel.runDeterministicHealthTick(h.clock.addAndGet(2 * 60_000L))
            assertTrue(actionsAt5m.any { it.workItemId == waitId && it.action == HealthActionKind.APPROVAL_STUCK_ALERT })
            h.kernel.reportWorkerSettlement(
                h.kernel.workerPrincipalFor(batch.items[2]),
                WorkerSettlementReport(waitId, "cancelled", "取消审批等待"),
                h.clock.get(),
            )

            // 再推进 5 分钟（总 T+10m）：
            // - quietId 静默满 10m -> Step 1 NUDGE (recoveriesUsed 仍为 0)
            // - buildId 运行 xcodebuild 满 10m (< 45m) -> EXEMPT_LONG_TOOL 豁免打断！
            val actionsAt10m = h.kernel.runDeterministicHealthTick(h.clock.addAndGet(5 * 60_000L))
            assertTrue(actionsAt10m.any { it.workItemId == quietId && it.action == HealthActionKind.NUDGE })
            assertTrue(actionsAt10m.any { it.workItemId == buildId && it.action == HealthActionKind.EXEMPT_LONG_TOOL })
            assertEquals(0, h.store.getWorkItem(quietId)!!.recoveriesUsed)

            // 再推进 5 分钟（总 T+15m）：
            // - quietId 催促后满 5m -> Step 2 INTERRUPT_AND_REDELIVER (recoveriesUsed = 1)
            // - buildId 仍享受 45m 豁免
            val actionsAt15m = h.kernel.runDeterministicHealthTick(h.clock.addAndGet(5 * 60_000L))
            assertTrue(actionsAt15m.any { it.workItemId == quietId && it.action == HealthActionKind.INTERRUPT_AND_REDELIVER })
            assertEquals(1, h.store.getWorkItem(quietId)!!.recoveriesUsed)

            // 验证中途普通进度更新绝不清零 recoveriesUsed（防无限自愈循环）
            val qAfterRedeliver1 = h.store.getWorkItem(quietId)!!
            h.kernel.updateWorkerProgress(
                principal = h.kernel.workerPrincipalFor(qAfterRedeliver1),
                workItemId = quietId,
                expectedRevision = qAfterRedeliver1.progressRevision,
                progressNote = "短暂输出一行日志后再次卡住",
                nowEpochMs = h.clock.get(),
            )
            assertEquals(1, h.store.getWorkItem(quietId)!!.recoveriesUsed)

            // 第二轮自愈阶梯：再静默 10m (T+25m) -> NUDGE；再静默 5m (T+30m) -> INTERRUPT_AND_REDELIVER (recoveriesUsed = 2)
            val actionsAt25m = h.kernel.runDeterministicHealthTick(h.clock.addAndGet(10 * 60_000L))
            assertTrue(actionsAt25m.any { it.workItemId == quietId && it.action == HealthActionKind.NUDGE })
            assertTrue(actionsAt25m.any { it.workItemId == buildId && it.action == HealthActionKind.EXEMPT_LONG_TOOL })

            val actionsAt30m = h.kernel.runDeterministicHealthTick(h.clock.addAndGet(5 * 60_000L))
            assertTrue(actionsAt30m.any { it.workItemId == quietId && it.action == HealthActionKind.INTERRUPT_AND_REDELIVER })
            assertEquals(2, h.store.getWorkItem(quietId)!!.recoveriesUsed)

            // 第三次静默满 10m (T+40m)：已用尽 2 次自愈上限 -> 直接转为 FAILED 并升级 ESCALATE_NEEDS_YOU！
            // 同时在 T+40m 时，buildId 的 xcodebuild (40m < 45m) 仍然被豁免！
            val actionsAt40m = h.kernel.runDeterministicHealthTick(h.clock.addAndGet(10 * 60_000L))
            assertTrue(actionsAt40m.any { it.workItemId == quietId && it.action == HealthActionKind.ESCALATE_NEEDS_YOU })
            assertTrue(actionsAt40m.any { it.workItemId == buildId && it.action == HealthActionKind.EXEMPT_LONG_TOOL })

            val failedQuiet = h.store.getWorkItem(quietId)!!
            assertEquals(WorkItemState.FAILED, failedQuiet.state)
            assertTrue(failedQuiet.needsYouEscalated)
            assertTrue(h.pushedCards.any { it.second == quietId })

            // 再推进 6 分钟（总 T+46m）：buildId 的 xcodebuild 超过 45 分钟豁免上限 -> 触发 tool_overtime 自愈催促！
            val actionsAt46m = h.kernel.runDeterministicHealthTick(h.clock.addAndGet(6 * 60_000L))
            assertTrue(actionsAt46m.any { it.workItemId == buildId && it.finding == "tool_overtime" && it.action == HealthActionKind.NUDGE })

            // 全程确定性巡检消耗 0 模型 Token
            assertEquals(0, h.kernel.deterministicHealthTokensUsed.get())
        }
    }

    // ========================================================================
    // 7. BatchRollup + wakeClaim 锁保证同一批次只唤醒 Router 一次
    // ========================================================================

    @Test
    fun batch_rollup_wakes_router_exactly_once_with_timestamp_free_sha256_reports() = runTest {
        Harness().use { h ->
            val msgId = h.recordOwnerMessage("msg-rollup-1", "并行执行三项检查")
            val batch = h.kernel.submitWorkBatch(
                principal = h.coordinatorPrincipal(),
                requestId = "req-rollup-3",
                contextMessageIds = listOf(msgId),
                items = listOf(
                    WorkItemSubmissionSpec("r-1", "检查 1", "说明 1", ExecutionTargetNode.CloudSubagent("w1")),
                    WorkItemSubmissionSpec("r-2", "检查 2", "说明 2", ExecutionTargetNode.CloudSubagent("w2")),
                    WorkItemSubmissionSpec("r-3", "检查 3", "说明 3", ExecutionTargetNode.CloudSubagent("w3")),
                ),
                nowEpochMs = h.clock.get(),
            )

            // 前两项完成时，Batch 尚未全部进入终态 -> 不得提前唤醒 Router
            h.kernel.reportWorkerSettlement(
                h.kernel.workerPrincipalFor(batch.items[0]),
                WorkerSettlementReport(batch.items[0].workItemId, "completed", "检查 1 通过"),
                h.clock.addAndGet(1_000L),
            )
            h.kernel.reportWorkerSettlement(
                h.kernel.workerPrincipalFor(batch.items[1]),
                WorkerSettlementReport(batch.items[1].workItemId, "completed", "检查 2 通过"),
                h.clock.addAndGet(1_000L),
            )
            assertEquals(0, h.kernel.batchRollupWakeCount.get())

            // 第 3 项完成 -> 全批次进入终态，通过 wakeClaim 锁恰好唤醒 1 次
            h.kernel.reportWorkerSettlement(
                h.kernel.workerPrincipalFor(batch.items[2]),
                WorkerSettlementReport(batch.items[2].workItemId, "completed", "检查 3 通过"),
                h.clock.addAndGet(1_000L),
            )
            assertEquals(1, h.kernel.batchRollupWakeCount.get())

            // 重复上报第 3 项或再次尝试抢锁 -> 幂等忽略，绝不二次唤醒
            h.kernel.reportWorkerSettlement(
                h.kernel.workerPrincipalFor(batch.items[2]),
                WorkerSettlementReport(batch.items[2].workItemId, "completed", "检查 3 通过"),
                h.clock.addAndGet(5_000L),
            )
            assertEquals(1, h.kernel.batchRollupWakeCount.get())

            // 验证无时间戳结算报告 SHA-256 稳定性
            val reportDoc = h.store.getArchivedDocument("inbox/${batch.items[0].workItemId}/report.md")
            assertNotNull(reportDoc)
            val reArchive = h.store.writeArchivedDocument(
                principal = h.coordinatorPrincipal(),
                docPath = reportDoc.docPath,
                content = h.store.readArchivedDocumentText(reportDoc.docPath)!!,
                deduplicateIfSameSha256 = true,
                nowMs = h.clock.addAndGet(60_000L),
            )
            assertTrue(reArchive.replayedUnchanged)
            assertEquals(reportDoc.revision, reArchive.revision)
        }
    }

    // ========================================================================
    // 8. Mac 节点离线排队（最多保留 24 小时，上线自动执行，超时转 FAILED 并通知用户）
    // ========================================================================

    @Test
    fun mac_offline_queued_resumes_when_online_and_fails_after_24_hours() = runTest {
        Harness().use { h ->
            h.kernel.setMacNodeOnline("mac-studio-home", online = false)
            val msgId = h.recordOwnerMessage("msg-mac-1", "在家里 Mac 跑 Xcode 构建")

            val batch = h.kernel.submitWorkBatch(
                principal = h.coordinatorPrincipal(),
                requestId = "req-mac-offline",
                contextMessageIds = listOf(msgId),
                items = listOf(
                    WorkItemSubmissionSpec(
                        taskKey = "mac-task-online-later",
                        title = "Mac 单测 A",
                        brief = "2 小时后上线执行",
                        targetNode = ExecutionTargetNode.PairedMacNode("mac-studio-home"),
                    ),
                    WorkItemSubmissionSpec(
                        taskKey = "mac-task-expire-24h",
                        title = "Mac 单测 B",
                        brief = "另一台离线超 24 小时的 Mac",
                        targetNode = ExecutionTargetNode.PairedMacNode("mac-mini-offline"),
                    ),
                ),
                nowEpochMs = h.clock.get(),
            )
            val itemA = batch.items[0]
            val itemB = batch.items[1]

            // 两台 Mac 均离线 -> 任务保持 QUEUED，且不占用云端并发槽位
            assertEquals(WorkItemState.QUEUED, itemA.state)
            assertEquals(WorkItemState.QUEUED, itemB.state)
            assertEquals(0, h.store.countHeldSlots())

            // 2 小时后 mac-studio-home 上线 -> itemA 自动获配槽位进入 WORKING
            h.clock.addAndGet(2 * 60 * 60_000L)
            h.kernel.setMacNodeOnline("mac-studio-home", online = true, nowEpochMs = h.clock.get())
            h.kernel.runDeterministicHealthTick(h.clock.get())
            assertEquals(WorkItemState.WORKING, h.store.getWorkItem(itemA.workItemId)!!.state)
            assertEquals(WorkItemState.QUEUED, h.store.getWorkItem(itemB.workItemId)!!.state)

            // 推进超过 24 小时（再 +23 小时，总 T+25h）-> mac-mini-offline 上的 itemB 超时转为 FAILED 并推送通知卡片
            h.clock.addAndGet(23 * 60 * 60_000L)
            val actions = h.kernel.runDeterministicHealthTick(h.clock.get())
            assertTrue(actions.any { it.workItemId == itemB.workItemId && it.action == HealthActionKind.EXPIRE_OFFLINE_MAC_QUEUE })

            val expiredB = h.store.getWorkItem(itemB.workItemId)!!
            assertEquals(WorkItemState.FAILED, expiredB.state)
            assertEquals("mac_node_offline_timeout_24h", expiredB.failureReason)
            assertTrue(h.pushedCards.any { it.second == itemB.workItemId && it.first.title.contains("24 小时") })
        }
    }

    // ========================================================================
    // 9. 安全与权限边界：非主人/Agent/Automation 建任务被拒、Worker 越权与横向发消息被拒、SUBAGENT 工具剥离
    // ========================================================================

    @Test
    fun security_provenance_rbac_worker_restrictions_and_subagent_tool_stripping() = runTest {
        Harness().use { h ->
            // 记录非主人 (GUEST / COLLABORATOR) 及 AGENT / AUTOMATION 消息
            val now = h.clock.get()
            h.store.recordSourceMessage(
                SourceMessageProvenance("s1", "msg-guest", "u-guest", "telegram", SenderRole.GUEST, MessageProvenanceOrigin.GUEST_HUMAN, "h1", now),
                "访客试图派发任务",
            )
            h.store.recordSourceMessage(
                SourceMessageProvenance("s1", "msg-collab", "u-collab", "feishu", SenderRole.COLLABORATOR, MessageProvenanceOrigin.COLLABORATOR_HUMAN, "h2", now),
                "群协作者试图派发任务",
            )
            h.store.recordSourceMessage(
                SourceMessageProvenance("s1", "msg-agent", "agent", "internal", SenderRole.OWNER, MessageProvenanceOrigin.AGENT, "h3", now),
                "Agent 自造消息",
            )
            h.store.recordSourceMessage(
                SourceMessageProvenance("s1", "msg-auto", "auto", "internal", SenderRole.OWNER, MessageProvenanceOrigin.AUTOMATION, "h4", now),
                "Automation 消息",
            )

            val sampleSpec = listOf(
                WorkItemSubmissionSpec("sec-1", "测试任务", "测试", ExecutionTargetNode.CloudSubagent("w"))
            )

            // 非主人、Agent、Automation 消息授权新任务一律抛出 UnauthorizedWorkSourceException
            for (badMsgId in listOf("msg-guest", "msg-collab", "msg-agent", "msg-auto", "msg-non-existent")) {
                assertFailsWith<UnauthorizedWorkSourceException> {
                    h.kernel.submitWorkBatch(
                        principal = h.coordinatorPrincipal(),
                        requestId = "req-bad-$badMsgId",
                        contextMessageIds = listOf(badMsgId),
                        items = sampleSpec,
                    )
                }
            }

            // 正常由主人创建 1 个 Worker 后，验证 Worker 不能创建新任务、不能 steer、不能横向发消息
            val ownerMsg = h.recordOwnerMessage("msg-owner-ok", "主人合法授权")
            val created = h.kernel.submitWorkBatch(
                principal = h.coordinatorPrincipal(),
                requestId = "req-owner-ok",
                contextMessageIds = listOf(ownerMsg),
                items = sampleSpec,
            ).items.single()
            val workerPrincipal = h.kernel.workerPrincipalFor(created)

            assertFailsWith<PrincipalPermissionException> {
                h.kernel.submitWorkBatch(
                    principal = workerPrincipal,
                    requestId = "req-by-worker",
                    contextMessageIds = listOf(ownerMsg),
                    items = listOf(WorkItemSubmissionSpec("sub-2", "越权子任务", "越权", ExecutionTargetNode.CloudSubagent("w"))),
                )
            }
            assertFailsWith<PrincipalPermissionException> {
                h.kernel.sendLateralMessage(workerPrincipal, "other-session", "私下横向通信")
            }
            assertFailsWith<PrincipalPermissionException> {
                h.kernel.steerWorker(workerPrincipal, created.workItemId, "自我重定向")
            }

            // Worker 写 SOUL.md 或其他 Worker 报告被拒；占位符凭据被拒
            assertFailsWith<PrincipalPermissionException> {
                h.store.writeArchivedDocument(workerPrincipal, "SOUL.md", "篡改最高指令")
            }
            assertFailsWith<PrincipalPermissionException> {
                h.store.writeArchivedDocument(workerPrincipal, "inbox/other-work-id/report.md", "伪造他人报告")
            }
            assertFailsWith<PlaceholderCredentialException> {
                h.store.writeArchivedDocument(h.coordinatorPrincipal(), "docs/note.md", "包含占位符 <redacted>")
            }

            // Worker 工具门禁强制按 SUBAGENT 作用域剥离高风险与写工具
            val subagentTools = h.toolRegistry.declaredTools(ExecutionScope.SUBAGENT).map { it.name }.toSet()
            assertFalse("terminal_exec" in subagentTools)
            assertFalse("ssh_profile_create" in subagentTools)
            assertFalse("workspace_file_write" in subagentTools)
            assertTrue("history_search" in subagentTools)

            val blockedExec = h.kernel.executeWorkerTool(
                principal = workerPrincipal,
                toolName = "terminal_exec",
                args = buildJsonObject { put("command", "rm -rf /") },
            ).jsonObject
            assertEquals(false, blockedExec["ok"]?.jsonPrimitive?.booleanOrNull)
        }
    }

    // ========================================================================
    // 10. 自动化三模式接入 ProactiveEngine：DEDICATED 平时静默仅完成/L3 异动发卡、32KiB/8KiB 与单轮信封
    // ========================================================================

    @Test
    fun automations_three_modes_proactive_engine_32kib_8kib_envelope_and_dedicated_silent_policy() = runTest {
        Harness(withProactiveEngine = true).use { h ->
            h.kernel.registerAutomation(
                CloudAutomationSpec(
                    automationId = "auto-pr-watch",
                    title = "盯紧 PR 142 CI 状态",
                    prompt = "检查 PR 142 是否合并或出现构建失败",
                    mode = CloudAutomationMode.DEDICATED,
                    completionPolicy = CompletionPolicy(stopWhenClause = "PR 142 已合并", confidenceThreshold = 0.8),
                )
            )

            // 构造 40 KiB 的多字节中文 + Emoji 记忆，验证存储截断至 <= 32 KiB 且注入信封尾部 <= 8 KiB（不拆代理对）
            val hugeMemory = ("状态记录😀🚀：" + "琥珀云端本体持续跟踪日志条目。".repeat(20) + "\n").repeat(80)
            assertTrue(hugeMemory.toByteArray(StandardCharsets.UTF_8).size > 32 * 1024)

            var capturedEnvelope: AutomationRunEnvelope? = null
            var capturedPrincipal: CloudPrincipal.AutomationRunner? = null

            // 第 1 次运行（DEDICATED 正常巡检，无异动）：静默更新记忆，即使返回 notify 也不发卡
            val run1 = h.kernel.executeAutomationRun("auto-pr-watch", h.clock.get()) { env, runner, _ ->
                capturedEnvelope = env
                capturedPrincipal = runner
                h.kernel.updateAutomationMemory(runner, "auto-pr-watch", hugeMemory, h.clock.get())
                AutomationTurnOutput(
                    summary = "第 1 次检查：CI 仍在排队，无异常",
                    decision = "notify", // DEDICATED 模式下普通巡检强制静默
                    l3AnomalyDetected = false,
                )
            }
            assertFalse(run1.cardPushed, "DEDICATED 模式平时巡检必须静默，不得发卡")
            assertEquals(0, h.pushedCards.size)

            val savedAfterRun1 = h.store.getAutomation("auto-pr-watch")!!
            val savedBytes = savedAfterRun1.memoryText.toByteArray(StandardCharsets.UTF_8).size
            assertTrue(savedBytes <= OrchestrationHash.AUTOMATION_MEMORY_MAX_BYTES, "持久化记忆不得超过 32 KiB: $savedBytes")
            assertNull(savedAfterRun1.activeRunId, "回合结束后必须立即收回 activeRunId")

            // 单轮信封防越权：在自动化回合结束后（模拟手动跟进轮次）再用旧 runnerPrincipal 改记忆必须被拒
            assertFailsWith<PrincipalPermissionException> {
                h.kernel.updateAutomationMemory(capturedPrincipal!!, "auto-pr-watch", "手动轮次越权修改")
            }

            // 第 2 次运行：验证注入信封的 memoryTail8KiB <= 8 KiB 且无断裂代理对，且检测到 L3 异动时通过 ProactiveEngine 发 1 张卡
            val run2 = h.kernel.executeAutomationRun("auto-pr-watch", h.clock.addAndGet(60_000L)) { env, _, _ ->
                capturedEnvelope = env
                AutomationTurnOutput(
                    summary = "检测到 L3 级异动：PR 142 出现阻塞性编译失败",
                    l3AnomalyDetected = true,
                )
            }
            val env2 = assertNotNull(capturedEnvelope)
            val tailBytes = env2.memoryTail8KiB.toByteArray(StandardCharsets.UTF_8).size
            assertTrue(tailBytes in 1..OrchestrationHash.AUTOMATION_MEMORY_INJECT_TAIL_BYTES)
            assertFalse(Character.isLowSurrogate(env2.memoryTail8KiB.first()))
            assertTrue(run2.cardPushed, "DEDICATED 模式出现 L3 异动时必须发卡")
            assertEquals(1, h.pushedCards.size)
            assertEquals(run1.sessionId, run2.sessionId, "DEDICATED 模式必须复用同一个专属会话")

            // 第 3 次运行：满足 CompletionPolicy ("PR 142 已合并") -> 自动停用 (disabledReason="completed") 并发送完成卡片
            val run3 = h.kernel.executeAutomationRun("auto-pr-watch", h.clock.addAndGet(60_000L)) { _, _, _ ->
                AutomationTurnOutput(
                    summary = "PR 142 已合并，跟踪目标达成",
                    l3AnomalyDetected = false,
                )
            }
            assertTrue(run3.disabled)
            assertEquals("completed", run3.disabledReason)
            assertTrue(run3.cardPushed)
            assertEquals(2, h.pushedCards.size)
            assertTrue(h.proactiveEngine!!.metrics().l1EvaluatedCount >= 2)

            // 验证 HEARTBEAT 繁忙延后 15s 与 STANDALONE 独立会话
            h.kernel.registerAutomation(
                CloudAutomationSpec(
                    automationId = "auto-hb",
                    title = "主线心跳",
                    prompt = "检查待办",
                    mode = CloudAutomationMode.HEARTBEAT,
                    maxIterations = 1,
                )
            )
            h.kernel.isRouterTurnBusy = true
            val deferredHb = h.kernel.executeAutomationRun("auto-hb", h.clock.get()) { _, _, _ ->
                AutomationTurnOutput("不应执行")
            }
            assertTrue(deferredHb.deferredHeartbeat)
            assertEquals(h.clock.get() + 15_000L, deferredHb.nextRetryAtMs)
            h.kernel.isRouterTurnBusy = false
        }
    }

    // ========================================================================
    // 11. 对标 Grok bot 交互：连发 3 条消息 2 秒内确认、不暴露工具名/参数/推理、状态 started->done 原地编辑、100 词上限
    // ========================================================================

    @Test
    fun grok_bot_style_three_rapid_messages_acked_under_2s_outward_sanitized_status_edited_in_place_and_100_word_budget() = runBlocking {
        Harness().use { h ->
            val sink = MockEditableImSink()
            val workerContinueGate = CompletableDeferred<Unit>()
            val workerProgressReady = CompletableDeferred<Unit>()

            h.kernel.autoExecuteWorkersInBackground = true
            h.kernel.workerTurnRunner = { item, principal ->
                val current = h.store.getWorkItem(item.workItemId)!!
                h.kernel.updateWorkerProgress(
                    principal = principal,
                    workItemId = item.workItemId,
                    expectedRevision = current.progressRevision,
                    progressNote = "<thinking>内部思考</thinking>调用 terminal_exec({\"cmd\":\"ls\"}) 排查日志 sk-ant-api03-SECRETKEY1234567890ABCDEF",
                    activeToolName = "terminal_exec",
                    nowEpochMs = h.clock.addAndGet(100L),
                )
                workerProgressReady.complete(Unit)
                workerContinueGate.await()
                WorkerSettlementReport(
                    workItemId = item.workItemId,
                    outcome = "completed",
                    summary = "已完成排查，修复方案准备就绪",
                )
            }

            var dispatchedOnce = false
            val router = CloudRouter(
                kernel = h.kernel,
                sink = sink,
                brain = RouterBrain { input ->
                    if (!dispatchedOnce) {
                        dispatchedOnce = true
                        // 故意在回复里混入思考块、工具名、JSON 参数、代码块、密钥和超过 100 词的长文
                        val longWords = (1..130).joinToString(" ") { "结论要点$it" }
                        RouterDecision(
                            reply = """
                                <thinking>先调 dispatch_work 再用 workspace_file_write({"path":"/tmp/a"})</thinking>
                                我已经安排后台处理 terminal_exec 和 history_search 了，密钥是 sk-ant-api03-SECRETKEY1234567890ABCDEF
                                {"raw_param": "should_not_appear"}
                                ```json
                                {"tool": "ssh_profile_create"}
                                ```
                                $longWords
                            """.trimIndent(),
                            dispatch = listOf(
                                WorkItemSubmissionSpec(
                                    taskKey = "grok-task-1",
                                    title = "排查崩溃与执行 terminal_exec 检查",
                                    brief = "定位崩溃原因",
                                    targetNode = ExecutionTargetNode.CloudSubagent("worker"),
                                    subscribedThreadKeys = listOf("telegram:chat-grok:thread-1"),
                                )
                            ),
                        )
                    } else {
                        RouterDecision(reply = "补充指示已合并跟进。")
                    }
                },
                executionToolNames = setOf("terminal_exec", "workspace_file_write", "ssh_profile_create", "history_search"),
                clockMs = { h.clock.get() },
            )

            // 连发 3 条消息：每条都必须在 2 秒内（实际 < 100ms）返回短句确认
            val ack1 = router.onInbound(
                InboundMessage(
                    messageId = "gm-1",
                    channel = ChannelKind.TELEGRAM,
                    chatId = "chat-grok",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    text = "帮我查一下最近三天崩溃原因",
                )
            )
            val ack2 = router.onInbound(
                InboundMessage(
                    messageId = "gm-2",
                    channel = ChannelKind.TELEGRAM,
                    chatId = "chat-grok",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    text = "顺便重点看网络模块",
                )
            )
            val ack3 = router.onInbound(
                InboundMessage(
                    messageId = "gm-3",
                    channel = ChannelKind.TELEGRAM,
                    chatId = "chat-grok",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    text = "结果简短告诉我",
                )
            )

            for (ack in listOf(ack1, ack2, ack3)) {
                assertTrue(ack.latencyMs < 2_000L, "确认延迟必须 < 2000ms，实际=${ack.latencyMs}ms")
                assertTrue(ack.text.startsWith("收到"), "确认语应为简短人话: ${ack.text}")
            }

            // 等待 Worker 进入 PROGRESS 状态，此时还可以随时插话直通给该任务
            workerProgressReady.await()
            val interjectAck = router.onInbound(
                InboundMessage(
                    messageId = "gm-thread-interject",
                    channel = ChannelKind.TELEGRAM,
                    chatId = "chat-grok",
                    threadId = "thread-1",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    text = "把 iOS 18 的日志也算进去",
                )
            )
            assertIs<DefaultCloudOrchestrationKernel.InboundRoutingDecision.DirectPassThroughToWorkers>(interjectAck.routing)

            // 放行后台 Worker 完成结算并等待 Router 汇总完毕
            workerContinueGate.complete(Unit)
            router.awaitIdle(includeWorkers = true)

            val item = h.store.listWorkItems().single()
            val statusMsgId = assertNotNull(router.statusMessageIdFor(item.workItemId))
            val statusEntry = assertNotNull(sink.entryFor(statusMsgId))

            // 验证 IM 里通过编辑同一条消息更新状态：started (⏳) -> progress (🔄) -> done (✅)
            assertTrue(statusEntry.editHistory.size >= 2, "状态消息必须在原消息上多次编辑更新: ${statusEntry.editHistory}")
            assertTrue(statusEntry.editHistory.first().startsWith("⏳"), "初始状态应为 started: ${statusEntry.editHistory.first()}")
            assertTrue(statusEntry.currentText.startsWith("✅"), "最终状态应编辑为 done: ${statusEntry.currentText}")

            // 验证 ActivityStatus 记录了 started -> progress -> done，且 label <= 20 字、已脱敏、不含工具名
            val phases = router.activityLog.filter { it.taskId == item.workItemId }.map { it.phase }
            assertEquals(ActivityPhase.STARTED, phases.first())
            assertTrue(ActivityPhase.PROGRESS in phases)
            assertEquals(ActivityPhase.DONE, phases.last())
            for (act in router.activityLog) {
                val cpLen = act.label.codePointCount(0, act.label.length)
                assertTrue(cpLen <= 20, "ActivityStatus.label 必须 <= 20 字: ${act.label} ($cpLen)")
                assertFalse(act.label.contains("terminal_exec"))
                assertFalse(act.label.contains("SECRETKEY1234567890ABCDEF"))
            }

            // 验证所有对外发出的消息：不含任何工具名、JSON 参数、推理内容或明文密钥，且每条 <= 100 词
            val forbidden = listOf(
                "terminal_exec",
                "workspace_file_write",
                "ssh_profile_create",
                "history_search",
                "dispatch_work",
                "<thinking>",
                "内部思考",
                "should_not_appear",
                "SECRETKEY1234567890ABCDEF",
            )
            for (out in router.outboundLog) {
                for (bad in forbidden) {
                    assertFalse(out.contains(bad, ignoreCase = true), "对外消息严禁包含 '$bad'，实际消息: $out")
                }
                val wordCount = OrchestrationHash.countWords(out)
                assertTrue(wordCount <= 100, "单次 IM 回复不得超过 100 词，实际=$wordCount: $out")
            }
            assertTrue(router.outboundLog.any { it.contains("doc:docs/replies/") }, "超 100 词回复应自动归档并附上引用")
        }
    }

    // ========================================================================
    // 12. 双层游标无损读取、Unicode 代理对安全切片、防撕裂校验、取证诊断与链式召回
    // ========================================================================

    @Test
    fun two_layer_lossless_session_reading_unicode_surrogate_safety_diagnostics_and_chain_of_recall() = runTest {
        Harness().use { h ->
            val msgId = h.recordOwnerMessage("msg-read-1", "生成带 Emoji 的长分析报告", threadKey = "feishu:group:oc_1")
            val created = h.kernel.submitWorkBatch(
                principal = h.coordinatorPrincipal(),
                requestId = "req-read-diag",
                contextMessageIds = listOf(msgId),
                items = listOf(
                    WorkItemSubmissionSpec(
                        taskKey = "read-diag-task",
                        title = "长报告与诊断测试",
                        brief = "输出包含高低代理对的长文本",
                        targetNode = ExecutionTargetNode.CloudSubagent("analyst"),
                        subscribedThreadKeys = listOf("feishu:group:oc_1"),
                    )
                ),
                nowEpochMs = h.clock.get(),
            ).items.single()
            val sessionId = created.workerSessionId!!

            // 写入一条含密集 Emoji 代理对（每个 Emoji 占 2 个 UTF-16 char）的长消息
            val emojiBody = "段落🔥🚀😀🎉".repeat(60)
            val assistantMsg = UIMessage.assistant(emojiBody)
            h.kernel.appendWorkerMessage(sessionId, assistantMsg, h.clock.addAndGet(1_000L))

            // 1. 第一层分页读取
            val page = h.kernel.readWorkerSessionPage(sessionId, pageSize = 10, maxMessageChars = 80)
            assertEquals(2, page.items.size)
            val preview = page.items[1]
            assertTrue(preview.truncated)
            assertFalse(Character.isHighSurrogate(preview.previewText.last()), "预览截断绝不能劈开 UTF-16 高代理项")

            // 2. 流式输出期间禁止切片读取（防撕裂）
            h.kernel.markMessageStreaming(preview.messageId, streaming = true, nowEpochMs = h.clock.get())
            assertFailsWith<MessageVersionMismatchException> {
                h.kernel.readWorkerMessageSlice(
                    MessageSliceCursor(
                        sessionId = sessionId,
                        messageIndex = preview.messageIndex,
                        messageId = preview.messageId,
                        messageVersion = preview.messageVersion,
                        offsetChars = 0,
                        limitChars = 50,
                    )
                )
            }
            h.kernel.markMessageStreaming(preview.messageId, streaming = false, nowEpochMs = preview.messageVersion.substringBefore(':').toLong())

            // 3. 版本号不匹配时拒绝切片读取
            assertFailsWith<MessageVersionMismatchException> {
                h.kernel.readWorkerMessageSlice(
                    MessageSliceCursor(
                        sessionId = sessionId,
                        messageIndex = preview.messageIndex,
                        messageId = preview.messageId,
                        messageVersion = "999999:10",
                        offsetChars = 0,
                        limitChars = 50,
                    )
                )
            }

            // 4. 第二层无损切片游标逐片拉取并拼接，刻意用会落在代理对中间的奇数 limitChars (如 13) 验证 Unicode 边界安全
            val reconstructed = StringBuilder()
            var offset: Int? = 0
            while (offset != null) {
                val slice = h.kernel.readWorkerMessageSlice(
                    MessageSliceCursor(
                        sessionId = sessionId,
                        messageIndex = preview.messageIndex,
                        messageId = preview.messageId,
                        messageVersion = preview.messageVersion,
                        offsetChars = offset,
                        limitChars = 13,
                    )
                )
                assertFalse(Character.isLowSurrogate(slice.sliceText.first()), "切片起点不得落在低代理项上")
                assertFalse(Character.isHighSurrogate(slice.sliceText.last()), "切片终点不得停在高代理项上")
                reconstructed.append(slice.sliceText)
                offset = slice.nextOffsetChars
            }
            assertEquals(emojiBody, reconstructed.toString())

            // 5. 连续流式事件折叠与一站式诊断覆盖率声明
            repeat(5) { idx ->
                h.kernel.recordStreamingChunk(sessionId, preview.messageId, "chunk-$idx", h.clock.addAndGet(10L))
            }
            val diag = h.kernel.diagnoseWorkerSession(sessionId, h.clock.get())
            assertTrue(diag.recentCollapsedEvents.any { it.contains("streamUpdates: 5") })
            assertTrue(diag.coverageNote.contains("SQLite 持久化诊断表 (complete=true"))
            assertTrue(diag.coverageNote.contains("absence in ring buffer is not proof"))

            // 6. 链式召回（Chain of Recall）：TRIGGER_MESSAGE -> WORK_ITEM -> WORKER_SESSION
            val hop1 = assertNotNull(h.kernel.recallObject(RecallObjectKind.TRIGGER_MESSAGE, msgId))
            assertTrue(hop1.nextHops.any { it.kind == RecallObjectKind.WORK_ITEM && it.id == created.workItemId })
            val hop2 = assertNotNull(h.kernel.recallObject(RecallObjectKind.WORK_ITEM, created.workItemId))
            assertTrue(hop2.nextHops.any { it.kind == RecallObjectKind.WORKER_SESSION && it.id == sessionId })
            val hop3 = assertNotNull(h.kernel.recallObject(RecallObjectKind.WORKER_SESSION, sessionId))
            assertTrue(hop3.inlineText.isNotBlank())
        }
    }
}
