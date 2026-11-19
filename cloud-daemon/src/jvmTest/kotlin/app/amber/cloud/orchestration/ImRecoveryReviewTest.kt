package app.amber.cloud.orchestration

import app.amber.ai.ui.UIMessage
import app.amber.cloud.channel.*
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.runtime.CloudToolRegistry
import app.amber.cloud.startDaemonChannels
import app.amber.core.storage.conversation.ConversationFile
import app.amber.core.storage.conversation.JsonConversationStorage
import kotlinx.coroutines.*
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.*

class ImRecoveryReviewTest {
    private class Fixture(val dir: File) {
        val job = SupervisorJob()
        val scope = CoroutineScope(job + Dispatchers.Default)
        val store = CloudOrchestrationStore(dir)
        val kernel = DefaultCloudOrchestrationKernel(store = store,
            conversationStorage = JsonConversationStorage(ConversationFile(File(dir, "conversations").apply { mkdirs() }.absolutePath)),
            toolRegistry = CloudToolRegistry())
        val sent = CopyOnWriteArrayList<Pair<ImAddress, String>>()
        var postFailure: Throwable? = null
        val sink = object : ImStatusSink {
            override suspend fun post(address: ImAddress, text: String): String {
                postFailure?.let { throw it }
                sent += address to text
                return "sent-${sent.size}"
            }
            override suspend fun edit(address: ImAddress, messageId: String, text: String) = true
        }
        fun router(brain: RouterBrain, onReply: suspend (String, String) -> Unit = { _, _ -> }) =
            CloudRouter(kernel, sink, brain, scope = scope, onReply = onReply)
        suspend fun close() { job.cancelAndJoin(); store.close() }
    }
    private fun message(id: String, chat: String = "chat", text: String = id, channel: ChannelKind = ChannelKind.TELEGRAM) =
        InboundMessage(id, channel, chat, senderId = "owner", senderRole = SenderRole.OWNER,
            scope = ConversationScope.DIRECT, text = text)
    private suspend fun queue(f: Fixture, m: InboundMessage) = f.kernel.routeInboundMessage(m, PRIMARY_CONVERSATION_ID.toString(), 1000)

    @Test fun frozen_multi_input_turn_keeps_membership_when_new_input_arrives_before_restart() = runBlocking {
        val dir = Files.createTempDirectory("im-review-plan").toFile()
        val first = Fixture(dir)
        val entered = CompletableDeferred<Unit>()
        try {
            queue(first, message("a")); queue(first, message("a2"))
            val r1 = first.router(RouterBrain { RouterDecision(reply = "frozen A", dispatch = listOf(
                WorkItemSubmissionSpec("frozen-a", "A", "A", ExecutionTargetNode.CloudSubagent("worker")))) },
                onReply = { _, _ -> entered.complete(Unit); awaitCancellation() })
            r1.kick()
            withTimeout(3000) { entered.await() } // Real processTurn saved its plan and dispatched; consume has not run.
            queue(first, message("b"))
        } finally { first.close() }
        val second = Fixture(dir)
        val calls = AtomicInteger()
        try {
            val r2 = second.router(RouterBrain { input ->
                calls.incrementAndGet()
                assertEquals(listOf("b"), input.events.map { it.summaryText }, "Only the new input may call the model")
                RouterDecision(reply = "new B")
            })
            second.kernel.recoverAfterRestart(2000)
            withTimeout(3000) { r2.awaitIdle() }
            assertEquals(1, calls.get())
            assertEquals(1, second.store.listWorkItems().size)
            assertEquals(setOf("frozen A", "new B"), second.sent.map { it.second }.filter { it == "frozen A" || it == "new B" }.toSet())
            assertTrue(second.store.dialogue.pending("im_message").isEmpty())
        } finally { second.close(); dir.deleteRecursively() }
    }

    @Test fun same_platform_message_number_in_two_chats_has_independent_plan_and_source() = runBlocking {
        val dir = Files.createTempDirectory("im-review-namespace").toFile()
        val f = Fixture(dir)
        try {
            queue(f, message("42", "chat-a", "request A"))
            queue(f, message("42", "chat-b", "request B"))
            val calls = AtomicInteger()
            val r = f.router(RouterBrain { input -> calls.incrementAndGet(); RouterDecision(reply = input.events.single().summaryText) })
            f.kernel.recoverAfterRestart(2000)
            withTimeout(3000) { r.awaitIdle() }
            assertEquals(2, calls.get())
            assertEquals(setOf("chat-a" to "request A", "chat-b" to "request B"), f.sent.map { it.first.chatId to it.second }.toSet())
            assertTrue(f.store.dialogue.pending("im_message").isEmpty())
        } finally { f.close(); dir.deleteRecursively() }
    }

    @Test fun restart_does_not_merge_different_reply_addresses_or_rollups() = runBlocking {
        val dir = Files.createTempDirectory("im-review-address").toFile()
        val first = Fixture(dir)
        try {
            for ((id, channel) in listOf("a" to ChannelKind.TELEGRAM, "b" to ChannelKind.FEISHU)) {
                val m = message(id, "chat-$id", channel = channel).copy(threadId = "topic-$id")
                queue(first, m)
                val source = first.kernel.listObservableRouterEvents().last().sourceMessageId!!
                val batch = first.kernel.submitWorkBatch(CloudPrincipal.OwnerUser("owner", channel.wireName), "batch-$id", listOf(source), listOf(
                    WorkItemSubmissionSpec("task-$id", id, id, ExecutionTargetNode.CloudSubagent("worker"), replyAddress = ImAddress(channel, m.chatId, m.threadId))))
                val item = batch.items.single()
                first.kernel.reportWorkerSettlement(first.kernel.workerPrincipalFor(item), WorkerSettlementReport(item.workItemId, "completed", "result-$id"))
            }
            first.store.dialogue.consume(first.store.dialogue.pending("im_message"))
        } finally { first.close() }
        val second = Fixture(dir)
        try {
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            val r = second.router(RouterBrain { input ->
                if (input.events.singleOrNull()?.eventId == "blocker") {
                    entered.complete(Unit); release.await(); RouterDecision()
                } else RouterDecision(reply = "result-" + input.events.single().replyAddress!!.chatId)
            })
            second.kernel.enqueueRouterTriggerWhileBusy(RouterTriggerEvent("blocker", "test", PRIMARY_CONVERSATION_ID.toString(), "internal", "internal", senderId = "system", summaryText = "block", createdAtMs = 0))
            withTimeout(3000) { entered.await() }
            second.kernel.recoverAfterRestart(2000)
            release.complete(Unit)
            withTimeout(3000) { r.awaitIdle() }
            assertEquals(setOf("chat-a" to "result-chat-a", "chat-b" to "result-chat-b"), second.sent.map { it.first.chatId to it.second }.toSet())
            assertEquals(setOf("topic-a", "topic-b"), second.sent.map { it.first.threadId }.toSet())
            assertTrue(second.store.listWorkItems().all { second.store.getBatchRollup(it.batchId)!!.deliveredToRouter })
        } finally { second.close(); dir.deleteRecursively() }
    }

    @Test fun daemon_start_registers_outputs_before_recovering_pending_im() = runBlocking {
        val dir = Files.createTempDirectory("im-review-start").toFile()
        val f = Fixture(dir)
        try { queue(f, message("start")) } finally { f.close() }
        val k = CloudAgentKernel(dir, CloudModelClient { _, _ -> UIMessage.assistant("recovered") }, masterSecretOverride = "synthetic-review-secret")
        val sent = CopyOnWriteArrayList<OutboundMessage>()
        val connector = object : ChannelConnector {
            override val kind = ChannelKind.TELEGRAM
            override fun attachIngress(ingress: ChannelIngress) { runBlocking { withTimeout(3000) { k.router.awaitIdle() } } }
            override suspend fun start() { withTimeout(3000) { k.router.awaitIdle() } }
            override suspend fun stop() = Unit
            override suspend fun send(message: OutboundMessage): Result<String> { sent += message; return Result.success("sent") }
        }
        try {
            startDaemonChannels(k, listOf(connector))
            withTimeout(3000) { k.router.awaitIdle() }
            assertEquals(listOf("recovered"), sent.map { it.text })
            assertFalse(k.orchestrationStore.listSqliteDiagnosticEvents(PRIMARY_CONVERSATION_ID.toString()).any { it.kind == "im_post_failed" })
        } finally { k.stopProactiveLoop(); k.nativeDialogue.closeAndJoin(); k.conversationTagger.closeAndJoin(); k.agentRegistry.close(); k.orchestrationStore.close(); k.supertagStore.close(); dir.deleteRecursively() }
    }

    @Test fun failed_empty_rollup_stays_pending_without_hot_loop_and_restart_reuses_plan() = runBlocking {
        val dir = Files.createTempDirectory("im-review-rollup-failure").toFile()
        val first = Fixture(dir)
        val batchId: String
        try {
            queue(first, message("rollup"))
            val source = first.kernel.listObservableRouterEvents().last().sourceMessageId!!
            val item = first.kernel.submitWorkBatch(CloudPrincipal.OwnerUser("owner", "telegram"), "rollup-batch", listOf(source), listOf(
                WorkItemSubmissionSpec("rollup", "Rollup", "Rollup", ExecutionTargetNode.CloudSubagent("worker"), replyAddress = ImAddress(ChannelKind.TELEGRAM, "chat")))).items.single()
            batchId = item.batchId
            first.kernel.reportWorkerSettlement(first.kernel.workerPrincipalFor(item), WorkerSettlementReport(item.workItemId, "completed", "actual result"))
            first.store.dialogue.consume(first.store.dialogue.pending("im_message"))
        } finally { first.close() }
        val second = Fixture(dir)
        try {
            second.postFailure = java.io.IOException("synthetic post failure")
            val calls = AtomicInteger()
            val r = second.router(RouterBrain { calls.incrementAndGet(); RouterDecision() })
            second.kernel.recoverAfterRestart(2000)
            withTimeout(3000) { r.awaitIdle() }
            assertEquals(1, calls.get(), "A failure must not cause a hot retry loop")
            assertFalse(second.store.getBatchRollup(batchId)!!.deliveredToRouter)
        } finally { second.close() }
        val third = Fixture(dir)
        try {
            val calls = AtomicInteger()
            val r = third.router(RouterBrain { calls.incrementAndGet(); RouterDecision(reply = "must not call again") })
            third.kernel.recoverAfterRestart(2001) // Well inside the claim TTL.
            withTimeout(3000) { r.awaitIdle() }
            assertEquals(0, calls.get(), "Rollup replay must reuse its frozen decision")
            assertEquals(1, third.sent.size)
            assertTrue(third.sent.single().second.contains("actual result"), "Empty model replies must retain the actual rollup")
            assertTrue(third.store.getBatchRollup(batchId)!!.deliveredToRouter)
        } finally { third.close(); dir.deleteRecursively() }
    }

    @Test fun partially_accepted_direct_input_recovers_original_target_once() = runBlocking {
        val dir = Files.createTempDirectory("im-review-direct-recovery").toFile()
        val first = Fixture(dir)
        val itemId: String
        val sessionId: String
        try {
            queue(first, message("initial").copy(threadId = "topic"))
            val source = first.kernel.listObservableRouterEvents().last().sourceMessageId!!
            val item = first.kernel.submitWorkBatch(CloudPrincipal.OwnerUser("owner", "telegram"), "direct-batch", listOf(source), listOf(
                WorkItemSubmissionSpec("direct", "Direct", "Direct", ExecutionTargetNode.CloudSubagent("worker"), subscribedThreadKeys = listOf("telegram:chat:topic")))).items.single()
            itemId = item.workItemId; sessionId = item.workerSessionId!!
            first.store.dialogue.consume(first.store.dialogue.pending("im_message"))
            // Inject a real storage write failure after durable followup admission, before parent consume.
            val sessionFile = File(dir, "conversations/$sessionId.json")
            val saved = File(dir, "saved-session.json")
            assertTrue(sessionFile.renameTo(saved))
            assertTrue(sessionFile.mkdir())
            File(sessionFile, "block-replacement").writeText("synthetic fault")
            try {
                assertFailsWith<java.io.IOException> { queue(first, message("followup", text = "durable direct text").copy(threadId = "topic")) }
            } finally { sessionFile.deleteRecursively(); assertTrue(saved.renameTo(sessionFile)) }
        } finally { first.close() }
        val second = Fixture(dir)
        try {
            val calls = AtomicInteger()
            val r = second.router(RouterBrain { calls.incrementAndGet(); RouterDecision() })
            second.kernel.recoverAfterRestart(2000)
            withTimeout(3000) { r.awaitIdle() }
            assertEquals(0, calls.get())
            assertEquals(1, second.kernel.workerEvents.pending(itemId).size)
            val session = second.kernel.conversationStorage.loadConversation(kotlin.uuid.Uuid.parse(sessionId))!!
            assertEquals(1, session.messageNodes.count { it.currentMessage.toText().contains("durable direct text") })
            assertTrue(second.store.dialogue.pending("im_message").isEmpty())
            assertTrue(second.store.dialogue.page(0, 100).items.isEmpty())
        } finally { second.close(); dir.deleteRecursively() }
    }

    @Test fun im_router_steer_does_not_publish_native_followup_events() = runBlocking {
        val dir = Files.createTempDirectory("im-review-steer").toFile()
        val f = Fixture(dir)
        try {
            queue(f, message("create"))
            val source = f.kernel.listObservableRouterEvents().last().sourceMessageId!!
            val item = f.kernel.submitWorkBatch(CloudPrincipal.OwnerUser("owner", "telegram"), "steer-batch", listOf(source), listOf(
                WorkItemSubmissionSpec("steer", "Steer", "Steer", ExecutionTargetNode.CloudSubagent("worker")))).items.single()
            f.store.dialogue.consume(f.store.dialogue.pending("im_message"))
            queue(f, message("steer"))
            val r = f.router(RouterBrain { RouterDecision(steer = listOf(RouterSteer(item.workItemId, "new instruction"))) })
            f.kernel.recoverAfterRestart(2000)
            withTimeout(3000) { r.awaitIdle() }
            assertEquals(1, f.kernel.workerEvents.pending(item.workItemId).size)
            assertTrue(f.store.dialogue.page(0, 100).items.isEmpty(), "IM Router steer must stay out of native dialogue events")
        } finally { f.close(); dir.deleteRecursively() }
    }

    @Test fun cancelled_im_direct_followup_stays_out_of_native_events_and_redelivery_stays_direct() = runBlocking {
        val dir = Files.createTempDirectory("im-review-cancel").toFile()
        val k = CloudAgentKernel(dir, CloudModelClient { _, _ -> UIMessage.assistant("unused") }, masterSecretOverride = "synthetic-review-secret")
        k.orchestrationKernel.autoExecuteWorkersInBackground = false
        try {
            val initial = message("initial").copy(threadId = "topic")
            k.orchestrationKernel.routeInboundMessage(initial, PRIMARY_CONVERSATION_ID.toString(), 1000)
            val source = k.orchestrationKernel.listObservableRouterEvents().last().sourceMessageId!!
            val item = k.orchestrationKernel.submitWorkBatch(CloudPrincipal.OwnerUser("owner", "telegram"), "direct-batch", listOf(source), listOf(
                WorkItemSubmissionSpec("direct", "Direct", "Direct", ExecutionTargetNode.CloudSubagent("worker"), subscribedThreadKeys = listOf("telegram:chat:topic")))).items.single()
            val followup = message("followup").copy(threadId = "topic", senderRole = SenderRole.COLLABORATOR)
            assertIs<DefaultCloudOrchestrationKernel.InboundRoutingDecision.DirectPassThroughToWorkers>(k.orchestrationKernel.routeInboundMessage(followup, PRIMARY_CONVERSATION_ID.toString(), 1100))
            k.orchestrationKernel.cancelWorkItem(CloudPrincipal.OwnerUser("owner", "telegram"), item.workItemId)
            assertTrue(k.orchestrationStore.dialogue.page(0, 100).items.isEmpty(), "IM cancellation must not emit native input_cancelled")
            val pendingBefore = k.orchestrationStore.dialogue.pending("im_message").map { it.id }
            k.orchestrationKernel.routeInboundMessage(followup, PRIMARY_CONVERSATION_ID.toString(), 1200)
            assertEquals(pendingBefore, k.orchestrationStore.dialogue.pending("im_message").map { it.id }, "Redelivery after terminal settlement must not become a new Router input")
        } finally { k.stopProactiveLoop(); k.nativeDialogue.closeAndJoin(); k.conversationTagger.closeAndJoin(); k.agentRegistry.close(); k.orchestrationStore.close(); k.supertagStore.close(); dir.deleteRecursively() }
    }
}
