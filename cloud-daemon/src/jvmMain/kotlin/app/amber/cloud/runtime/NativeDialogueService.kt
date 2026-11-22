package app.amber.cloud.runtime

import app.amber.ai.ui.UIMessage
import app.amber.cloud.channel.*
import app.amber.cloud.gateway.PairedDevice
import app.amber.cloud.orchestration.*
import app.amber.cloud.security.CredentialRedactor
import kotlinx.coroutines.*
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** Durable native ingress, using the existing Router and task sessions rather than a second agent loop. */
class NativeDialogueService(private val kernel: CloudAgentKernel, private val ingress: suspend (InboundMessage)->OutboundMessage,
    private val persistReply:suspend (String,String)->Unit) {
    private val store get()=kernel.orchestrationStore
    private val events get()=store.dialogue
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.IO)
    private val enqueued=ConcurrentHashMap.newKeySet<String>()
    private fun fingerprint(
        kind: String,
        text: String,
        target: String?,
        conversationId: String? = null,
        epoch: Long? = null,
    ): String {
        val raw = buildString {
            append(kind).append('\u0000').append(target.orEmpty()).append('\u0000').append(text)
            if (conversationId != null) append("\u0000conv:").append(conversationId)
            if (epoch != null) append("\u0000epoch:").append(epoch)
        }
        return OrchestrationHash.sha256Hex(raw)
    }

    suspend fun submit(
        device: PairedDevice,
        requestId: String,
        text: String,
        kind: String = "message",
        workItemId: String? = null,
        conversationId: String? = null,
        executorKind: String? = null,
        executorId: String? = null,
        epoch: Long? = null,
        parentRunId: String? = null,
        observedSeq: Long? = null,
        ledgerId: String? = null,
    ): DialogueReceipt {
        require(Regex("[A-Za-z0-9._:-]{1,128}").matches(requestId))
        require(kind == "message" || workItemId != null) { "work_item_required" }
        require(kind == "stop" || (text.isNotBlank() && text.length <= 24_000))
        require(conversationId == null || (conversationId.isNotBlank() && conversationId.length <= 128))
        val safe = CredentialRedactor.redact(text)
        val targetWorkItem = workItemId?.let { store.getWorkItem(it) ?: throw NoSuchElementException() }
        val topic = targetWorkItem?.let(::topic) ?: UUID.randomUUID().toString()
        val resolvedConversationId = conversationId ?: targetWorkItem?.conversationId
        val input = DialogueInput(
            id = UUID.randomUUID().toString(),
            deviceId = device.id,
            requestId = requestId,
            kind = kind,
            text = safe,
            topicId = topic,
            workItemId = workItemId,
            conversationId = resolvedConversationId,
            executorKind = executorKind,
            executorId = executorId,
            epoch = epoch,
            parentRunId = parentRunId,
            observedSeq = observedSeq,
            ledgerId = ledgerId,
        )
        val (accepted, replayed) = events.accept(
            input,
            fingerprint(kind, text, workItemId, conversationId = conversationId, epoch = epoch),
        ) {}
        if (events.disposition(accepted.id) == "received") {
            if (kind == "stop") stop(accepted)
            else if (kind == "message") enqueue(accepted)
            else kernel.orchestrationKernel.signalWorker(workItemId!!)
        }
        return receipt(accepted, replayed)
    }
    fun receipt(device: PairedDevice, requestId: String): DialogueReceipt? = events.find(device.id, requestId)?.let { receipt(it, true) }
    private fun receipt(input: DialogueInput, replayed: Boolean): DialogueReceipt {
        val work = if (input.workItemId != null) listOf(input.workItemId) else store.listWorkItems().filter { item -> item.sourceProvenance.any { it.messageId == "native:${input.id}" } }.map { it.workItemId }
        return DialogueReceipt(
            eventId = input.id,
            requestId = input.requestId,
            topicId = input.topicId,
            workItemIds = work,
            state = events.disposition(input.id),
            replayed = replayed,
            soulRevision = kernel.soulStore.currentRevision(),
            conversationId = input.conversationId,
            executorKind = input.executorKind,
            executorId = input.executorId,
            epoch = input.epoch,
            parentRunId = input.parentRunId,
            observedSeq = input.observedSeq,
            ledgerId = input.ledgerId,
        )
    }
    private fun enqueue(input: DialogueInput) {
        if (events.isConsumed(input.id) || !enqueued.add(input.id)) return
        scope.launch {
            try {
                val metadata = buildMap {
                    put("thread_key", "native:${input.topicId}")
                    put("native_event_id", input.id)
                    if (input.conversationId != null) put("conversation_id", input.conversationId)
                }
                ingress(InboundMessage(messageId = "native:${input.id}", channel = ChannelKind.APP, chatId = input.deviceId,
                    threadId = input.topicId, senderId = input.deviceId, senderRole = SenderRole.OWNER, scope = ConversationScope.DIRECT, text = input.text,
                    metadata = metadata))
            }
            catch (e: CancellationException) { throw e }
            catch (_: Exception) { enqueued.remove(input.id) } // Remains durable and is retried by recovery, without claiming consumption.
        }
    }
    suspend fun acknowledge(id: String) {
        val input = events.pending("message").firstOrNull { it.id == id } ?: return
        val text = "收到，我来处理。完成或遇到问题都会在这里告诉你。"
        persistReply("ack:${input.id}", text)
        events.append(
            DialogueEvent(
                id = "ack:${input.id}",
                kind = DialogueEventKinds.ASSISTANT_REPLY,
                role = "assistant",
                text = text,
                topicId = input.topicId,
                conversationId = input.conversationId,
                executorKind = input.executorKind,
                executorId = input.executorId,
                epoch = input.epoch,
                causedByInputId = input.id,
                causedByRequestId = input.requestId,
                parentRunId = input.parentRunId,
                observedSeq = input.observedSeq,
                ledgerId = input.ledgerId,
            )
        )
    }
    suspend fun handled(triggers:List<RouterTriggerEvent>,replies:List<String>) {
        triggers.mapNotNull {it.sourceMessageId?.removePrefix("native:")}.forEach {id->
            events.pending("message").firstOrNull {it.id==id}?.let {
                replies.forEachIndexed {n,text->persistReply("reply:${it.id}:$n",text)}
                events.routerResult(it,replies);enqueued.remove(id)
            }
        }
    }
    private suspend fun stop(input:DialogueInput) {
        if(events.isConsumed(input.id))return
        kernel.orchestrationKernel.cancelWorkItem(CloudPrincipal.OwnerUser(input.deviceId,"app"),input.workItemId!!)
        events.consume(listOf(input))
    }
    fun topic(item:CloudWorkItemRecord)=item.subscribedThreadKeys.firstOrNull {it.startsWith("native:")}?.removePrefix("native:") ?: item.workItemId
    suspend fun settlement(item:CloudWorkItemRecord,report:WorkerSettlementReport) {
        if(report.outcome=="cancelled")events.abandonPending(item.workItemId)
        if(item.subscribedThreadKeys.none {it.startsWith("native:")})return
        val text=OutwardTextSanitizer.sanitize(report.summary,kernel.router.forbiddenToolNames)
        persistReply("result:${item.workItemId}", "${item.title} · ${if(report.outcome=="completed") "已完成" else if(report.outcome=="cancelled") "已停止" else "未完成"}\n$text")
        events.append(
            DialogueEvent(
                id = "result:${item.workItemId}",
                kind = DialogueEventKinds.TASK_RESULT,
                role = "assistant",
                text = text,
                topicId = topic(item),
                workItemId = item.workItemId,
                outcome = report.outcome,
                conversationId = item.conversationId,
                executorKind = item.executorKind,
                executorId = item.executorId,
                epoch = item.epoch,
                causedByInputId = item.causedByInputId,
                causedByRequestId = item.causedByRequestId,
                parentRunId = item.parentRunId,
                observedSeq = item.observedSeq,
                ledgerId = item.ledgerId,
                outcomeUnknown = item.outcomeUnknown,
            )
        )
    }
    suspend fun recover() {
        for(p in events.runningProcesses()) {
            kernel.taskProcesses.recoverProcess(p.pid,p.startedAtMs)
            events.processFinished(p.id,p.owner,store.getWorkItem(p.owner)?.let(::topic)?:p.owner,"进程因daemon重启中断，旧命令未重放：${p.id}")
        }
        events.pending("stop").forEach {stop(it)}
        store.listWorkItems().filter {it.state.isTerminal&&it.subscribedThreadKeys.any {key->key.startsWith("native:")}}.forEach {item->
            val markdown=item.settlementReportPath?.let(store::readArchivedDocumentText).orEmpty()
            settlement(item,WorkerSettlementReport(item.workItemId,item.settlementOutcome?:"failed",markdown.substringAfter("## Summary\n",markdown).substringBefore("\n## ")))
        }
        events.pending("message").forEach {enqueue(it)}
    }
}
