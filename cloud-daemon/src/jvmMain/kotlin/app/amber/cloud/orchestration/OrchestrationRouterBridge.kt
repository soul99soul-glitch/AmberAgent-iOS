package app.amber.cloud.orchestration

import app.amber.ai.ui.UIMessage
import app.amber.cloud.channel.ChannelKind
import app.amber.cloud.channel.ConversationScope
import app.amber.cloud.channel.InboundMessage
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.security.CredentialRedactor
import java.util.UUID
import kotlinx.serialization.encodeToString
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.uuid.Uuid

/**
 * 负责多对多 Thread 订阅直通快路径（Fast Path）、Router 繁忙期积压事件合并批处理（Slow Path），
 * 以及 IM 100 词回复预算裁剪与超长自动归档引用。
 */
internal class OrchestrationRouterBridge(
    private val kernel: DefaultCloudOrchestrationKernel,
) {
    private val observableEvents = CopyOnWriteArrayList<RouterTriggerEvent>()
    private val pendingRouterBatchQueue = ArrayDeque<RouterTriggerEvent>()

    fun deriveThreadKey(message: InboundMessage): String? {
        val explicit = message.metadata["thread_key"]?.trim()?.takeIf { it.isNotEmpty() }
        if (explicit != null) return explicit
        val tid = message.threadId?.trim()?.takeIf { it.isNotEmpty() }
        if (tid != null) {
            return "${message.channel.wireName}:${message.chatId}:$tid"
        }
        if (message.scope == ConversationScope.GROUP) {
            return "${message.channel.wireName}:group:${message.chatId}"
        }
        return null
    }

    suspend fun routeInboundMessage(
        message: InboundMessage,
        sessionId: String,
        nowEpochMs: Long,
    ): DefaultCloudOrchestrationKernel.InboundRoutingDecision {
        val threadKey = deriveThreadKey(message)
        val isIm = message.channel != ChannelKind.APP
        val sourceId = if (isIm) imMessageIdentity(message.channel, message.chatId, message.messageId) else message.messageId
        val origin = when {
            message.metadata["origin"] == "agent" -> MessageProvenanceOrigin.AGENT
            message.metadata["origin"] == "automation" -> MessageProvenanceOrigin.AUTOMATION
            message.senderRole == SenderRole.OWNER -> MessageProvenanceOrigin.OWNER_HUMAN
            message.senderRole == SenderRole.COLLABORATOR -> MessageProvenanceOrigin.COLLABORATOR_HUMAN
            else -> MessageProvenanceOrigin.GUEST_HUMAN
        }
        val subscribers = if (threadKey != null && !message.text.contains('@')) {
            kernel.store.listActiveSubscribersForThread(threadKey).filter {
                it.workerSessionId != null && !it.state.isTerminal && !kernel.workerEvents.isStopping(it.workItemId)
            }
        } else emptyList()
        val address = if (isIm) ImAddress(message.channel, message.chatId, message.threadId) else null
        if (!isIm || kernel.store.getSourceMessage(sourceId) == null) {
            kernel.store.recordSourceMessage(SourceMessageProvenance(
                sessionId = sessionId, messageId = sourceId, senderId = message.senderId,
                channelId = message.channel.wireName, senderRole = message.senderRole, origin = origin,
                rawTextHash = OrchestrationHash.sha256Hex(message.text), createdAtEpochMs = nowEpochMs,
            ), message.text, threadKey)
        }
        val input = if (isIm) {
            val fingerprint = OrchestrationHash.sha256Hex(kotlinx.serialization.json.Json.encodeToString(
                listOf(sessionId, message.threadId.orEmpty(), message.senderId, message.senderRole.name, origin.name, message.text)))
            kernel.store.dialogue.acceptSilent(
                DialogueInput(
                    id = UUID.nameUUIDFromBytes(sourceId.toByteArray()).toString(),
                    deviceId = "im:${message.channel.wireName}:${message.chatId}", requestId = message.messageId,
                    kind = "im_message", text = CredentialRedactor.redact(message.text), topicId = sessionId,
                    replyAddress = address, sourceMessageId = sourceId, senderId = message.senderId,
                    threadId = threadKey ?: message.threadId, createdAtMs = nowEpochMs,
                    directWorkItemIds = subscribers.map { it.workItemId }.takeIf { it.isNotEmpty() },
                ), fingerprint,
            ).first
        } else null
        val triggerEvent = RouterTriggerEvent(
            eventId = "trig:$sourceId", kind = "user_message", conversationId = sessionId,
            channelId = message.channel.wireName, chatId = message.chatId,
            threadId = threadKey ?: message.threadId, senderId = message.senderId,
            summaryText = CredentialRedactor.redact(message.text), createdAtMs = nowEpochMs,
            sourceMessageId = sourceId, replyAddress = address, dialogueInputId = input?.id,
        )
        if (input != null && kernel.store.dialogue.isConsumed(input.id)) {
            return DefaultCloudOrchestrationKernel.InboundRoutingDecision.QueuedForRouterBatch(
                triggerEvent, synchronized(pendingRouterBatchQueue) { pendingRouterBatchQueue.size })
        }
        observableEvents.add(triggerEvent)

        if (input?.directWorkItemIds != null) return deliverDirectInput(input, nowEpochMs)
        if (!isIm && subscribers.isNotEmpty()) {
            // Preserve the APP fast path; native HTTP dialogue has its own durable admission.
            return deliverDirectInput(DialogueInput(
                UUID.randomUUID().toString(), "native:${message.chatId}", message.messageId, "message",
                CredentialRedactor.redact(message.text), sessionId, threadId = threadKey,
                directWorkItemIds = subscribers.map { it.workItemId },
            ), nowEpochMs, persistCompletion = false)
        }
        return synchronized(pendingRouterBatchQueue) {
            if (pendingRouterBatchQueue.none { it.eventId == triggerEvent.eventId }) pendingRouterBatchQueue.addLast(triggerEvent)
            if (kernel.isRouterTurnBusy) DefaultCloudOrchestrationKernel.InboundRoutingDecision.QueuedForRouterBatch(triggerEvent, pendingRouterBatchQueue.size)
            else DefaultCloudOrchestrationKernel.InboundRoutingDecision.RouteToCoordinatorNow(pendingRouterBatchQueue.toList())
        }
    }

    private suspend fun deliverDirectInput(
        input: DialogueInput, nowEpochMs: Long, persistCompletion: Boolean = true,
    ): DefaultCloudOrchestrationKernel.InboundRoutingDecision.DirectPassThroughToWorkers {
        val targets = mutableListOf<CloudWorkItemRecord>()
        val followupText = "【Thread 直通事件 · ${input.threadId}】\n${input.text}"
        for (id in input.directWorkItemIds.orEmpty()) {
            val item = kernel.store.getWorkItem(id) ?: continue
            if (item.state.isTerminal || kernel.workerEvents.isStopping(id) || item.workerSessionId == null) continue
            val deviceId = if (persistCompletion) "im:followup:${input.id}" else input.deviceId
            val requestId = if (persistCompletion) id else "${input.requestId}:$id"
            kernel.acceptFollowupAndSignalInternal(
                deviceId, requestId, id, followupText, nowEpochMs,
                silentDialogueEvent = persistCompletion, appendBrief = false,
            )
            targets += item
            if (!kernel.autoExecuteWorkersInBackground || kernel.workerTurnRunner == null) {
                val stored = kernel.store.dialogue.find(deviceId, requestId)!!
                kernel.appendMessageToSessionInternal(item.workerSessionId,
                    UIMessage.user(followupText).copy(id = Uuid.parse(stored.id)), nowEpochMs)
            }
            kernel.store.appendDiagnosticEvent(item.workerSessionId, id, "thread_pass_through",
                messageId = input.sourceMessageId, detail = "直通投递话题事件 ${input.threadId} -> $id", nowMs = nowEpochMs)
        }
        // Persist the original target set before delivery; partial fan-out replays only those targets.
        if (persistCompletion) kernel.store.dialogue.consume(listOf(input))
        kernel.directPassThroughCount.incrementAndGet()
        return DefaultCloudOrchestrationKernel.InboundRoutingDecision.DirectPassThroughToWorkers(
            input.threadId.orEmpty(), targets.map { it.workItemId }, targets.mapNotNull { it.workerSessionId })
    }

    suspend fun recoverPendingImTriggers(nowEpochMs: Long) {
        val pendingIm = kernel.store.dialogue.pending(kind = "im_message")
        if (pendingIm.isEmpty()) return
        for (input in pendingIm) {
            if (input.directWorkItemIds != null) {
                deliverDirectInput(input, nowEpochMs)
                continue
            }
            val parts = input.deviceId.removePrefix("im:").split(':', limit = 2)
            val channelId = input.replyAddress?.channel?.wireName ?: parts.getOrNull(0) ?: "internal"
            val chatId = input.replyAddress?.chatId ?: parts.getOrNull(1) ?: "unknown"
            val srcId = input.sourceMessageId ?: input.requestId
            val event = RouterTriggerEvent(
                eventId = "trig:$srcId",
                kind = "user_message",
                conversationId = input.topicId,
                channelId = channelId,
                chatId = chatId,
                threadId = input.threadId ?: input.replyAddress?.threadId,
                senderId = input.senderId ?: "owner",
                summaryText = input.text,
                createdAtMs = input.createdAtMs ?: nowEpochMs,
                sourceMessageId = srcId,
                replyAddress = input.replyAddress,
                dialogueInputId = input.id,
            )
            synchronized(pendingRouterBatchQueue) {
                if (pendingRouterBatchQueue.none { it.dialogueInputId == input.id || it.eventId == event.eventId }) {
                    pendingRouterBatchQueue.addLast(event)
                }
            }
        }
        kernel.routerWakeListener?.invoke()
    }

    fun enqueueRouterTriggerWhileBusy(event: RouterTriggerEvent) {
        observableEvents.add(event)
        synchronized(pendingRouterBatchQueue) {
            val duplicate = pendingRouterBatchQueue.any { existing ->
                existing.eventId == event.eventId ||
                    (event.kind == "batch_rollup" && event.batchId != null && existing.kind == "batch_rollup" && existing.batchId == event.batchId)
            }
            if (!duplicate) {
                pendingRouterBatchQueue.addLast(event)
            }
        }
        kernel.routerWakeListener?.invoke()
    }

    fun hasPendingRouterEvents(): Boolean = synchronized(pendingRouterBatchQueue) { pendingRouterBatchQueue.isNotEmpty() }

    fun drainPendingRouterBatch(): List<RouterTriggerEvent> {
        synchronized(pendingRouterBatchQueue) {
            if (pendingRouterBatchQueue.isEmpty()) return emptyList()
            val list = pendingRouterBatchQueue.toList()
            pendingRouterBatchQueue.clear()
            if (list.size > 1) {
                kernel.routerBatchedCallCount.incrementAndGet()
            }
            return list
        }
    }

    fun formatRouterBatchPrompt(events: List<RouterTriggerEvent>): String {
        if (events.size == 1) {
            return events.single().summaryText
        }
        return buildString {
            append("<router_event_batch count=\"").append(events.size).append("\">\n")
            events.forEachIndexed { idx, ev ->
                append("[").append(idx + 1).append("] (").append(ev.kind)
                    .append(" from ").append(ev.channelId).append(":").append(ev.senderId)
                if (ev.sourceMessageId != null) append(" msgId=").append(ev.sourceMessageId)
                append("): ").append(CredentialRedactor.redact(ev.summaryText)).append('\n')
            }
            append("</router_event_batch>")
        }
    }

    fun listObservableRouterEvents(): List<RouterTriggerEvent> = observableEvents.toList()

    fun enforceImReplyWordBudget(
        rawText: String,
        referenceSlug: String,
        nowEpochMs: Long,
    ): String {
        val safeText = CredentialRedactor.redact(rawText.trim())
        if (OrchestrationHash.countWords(safeText) <= kernel.config.routerMaxReplyWords) {
            return safeText
        }

        val docPath = "docs/replies/$referenceSlug.md"
        val coordinatorPrincipal = CloudPrincipal.CloudCoordinator(
            activeSessionId = PRIMARY_CONVERSATION_ID.toString(),
            activeTurnId = "reply:$referenceSlug",
        )
        val archived = kernel.store.writeArchivedDocument(
            principal = coordinatorPrincipal,
            docPath = docPath,
            content = safeText,
            expectedRevision = null,
            deduplicateIfSameSha256 = true,
            nowMs = nowEpochMs,
        )
        val suffix = "… [全文 doc:${archived.docPath}]"
        val suffixWords = OrchestrationHash.countWords(suffix)
        val keepCount = (kernel.config.routerMaxReplyWords - suffixWords).coerceAtLeast(10)
        val head = OrchestrationHash.truncateToWords(safeText, keepCount).first
        return "$head $suffix"
    }
}
