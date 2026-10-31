package app.amber.cloud.orchestration

import app.amber.ai.ui.UIMessage
import app.amber.cloud.channel.ConversationScope
import app.amber.cloud.channel.InboundMessage
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.security.CredentialRedactor
import java.util.concurrent.CopyOnWriteArrayList

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
        val origin = when {
            message.metadata["origin"] == "agent" -> MessageProvenanceOrigin.AGENT
            message.metadata["origin"] == "automation" -> MessageProvenanceOrigin.AUTOMATION
            message.senderRole == SenderRole.OWNER -> MessageProvenanceOrigin.OWNER_HUMAN
            message.senderRole == SenderRole.COLLABORATOR -> MessageProvenanceOrigin.COLLABORATOR_HUMAN
            else -> MessageProvenanceOrigin.GUEST_HUMAN
        }
        val provenance = SourceMessageProvenance(
            sessionId = sessionId,
            messageId = message.messageId,
            senderId = message.senderId,
            channelId = message.channel.wireName,
            senderRole = message.senderRole,
            origin = origin,
            rawTextHash = OrchestrationHash.sha256Hex(message.text),
            createdAtEpochMs = nowEpochMs,
        )
        kernel.store.recordSourceMessage(provenance, message.text, threadKey)

        val triggerEvent = RouterTriggerEvent(
            eventId = "trig:${message.messageId}",
            kind = "user_message",
            conversationId = sessionId,
            channelId = message.channel.wireName,
            chatId = message.chatId,
            threadId = threadKey ?: message.threadId,
            senderId = message.senderId,
            summaryText = CredentialRedactor.redact(message.text),
            createdAtMs = nowEpochMs,
            sourceMessageId = message.messageId,
        )
        observableEvents.add(triggerEvent)

        if (threadKey != null) {
            val subscribers = kernel.store.listActiveSubscribersForThread(threadKey)
            if (subscribers.isNotEmpty()) {
                kernel.directPassThroughCount.incrementAndGet()
                val targetWorkItemIds = mutableListOf<String>()
                val targetSessionIds = mutableListOf<String>()

                for (sub in subscribers) {
                    val wSessionId = sub.workerSessionId ?: continue
                    targetWorkItemIds.add(sub.workItemId)
                    targetSessionIds.add(wSessionId)

                    kernel.appendMessageToSessionInternal(
                        sessionId = wSessionId,
                        message = UIMessage.user(
                            "【Thread 直通事件 · $threadKey】\n${CredentialRedactor.redact(message.text)}"
                        ),
                        nowEpochMs = nowEpochMs,
                    )
                    kernel.store.upsertWorkItem(
                        sub.copy(
                            lastActivityAtMs = nowEpochMs,
                            updatedAtMs = nowEpochMs,
                        )
                    )
                    kernel.store.appendDiagnosticEvent(
                        sessionId = wSessionId,
                        workItemId = sub.workItemId,
                        kind = "thread_pass_through",
                        messageId = message.messageId,
                        detail = "直通投递话题事件 $threadKey -> ${sub.workItemId}",
                        nowMs = nowEpochMs,
                    )
                }
                return DefaultCloudOrchestrationKernel.InboundRoutingDecision.DirectPassThroughToWorkers(
                    threadKey = threadKey,
                    workerItemIds = targetWorkItemIds,
                    workerSessionIds = targetSessionIds,
                )
            }
        }

        synchronized(pendingRouterBatchQueue) {
            pendingRouterBatchQueue.addLast(triggerEvent)
            if (kernel.isRouterTurnBusy) {
                return DefaultCloudOrchestrationKernel.InboundRoutingDecision.QueuedForRouterBatch(
                    event = triggerEvent,
                    currentBatchSize = pendingRouterBatchQueue.size,
                )
            }
            return DefaultCloudOrchestrationKernel.InboundRoutingDecision.RouteToCoordinatorNow(
                batchedEvents = pendingRouterBatchQueue.toList()
            )
        }
    }

    fun enqueueRouterTriggerWhileBusy(event: RouterTriggerEvent) {
        observableEvents.add(event)
        synchronized(pendingRouterBatchQueue) {
            pendingRouterBatchQueue.addLast(event)
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
