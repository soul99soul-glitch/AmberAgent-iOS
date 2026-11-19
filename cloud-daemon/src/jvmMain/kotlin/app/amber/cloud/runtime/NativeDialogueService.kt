package app.amber.cloud.runtime

import app.amber.ai.ui.UIMessage
import app.amber.cloud.channel.*
import app.amber.cloud.gateway.PairedDevice
import app.amber.cloud.orchestration.*
import app.amber.cloud.security.CredentialRedactor
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** Durable native ingress, using the existing Router and task sessions rather than a second agent loop. */
class NativeDialogueService(private val kernel: CloudAgentKernel, private val ingress: suspend (InboundMessage)->OutboundMessage,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob()+Dispatchers.IO),
    internal var clockMs: () -> Long = { System.nanoTime() / 1_000_000 },
    private val persistReply:suspend (String,String)->Unit) {
    private val store get()=kernel.orchestrationStore
    private val events get()=store.dialogue
    private val enqueued=ConcurrentHashMap.newKeySet<String>()
    private data class Feedback(val input: DialogueInput, val startedMs: Long,
        var lastMeaningfulMs: Long = startedMs, var window: String = "start", var keptAlive: Boolean = false,
        var lastWaitingText: String? = null, val attempted: MutableSet<String> = mutableSetOf(), var draftJob: Job? = null)
    private val feedbackMutex = Mutex()
    private val feedback = mutableMapOf<String, Feedback>()
    private var feedbackJob: Job? = null
    private val feedbackWriter = NativeDialogueFeedbackWriter(kernel)
    private fun fingerprint(kind:String,text:String,target:String?)=OrchestrationHash.sha256Hex("$kind\u0000${target.orEmpty()}\u0000$text")

    suspend fun submit(device:PairedDevice,requestId:String,text:String,kind:String="message",workItemId:String?=null):DialogueReceipt {
        require(Regex("[A-Za-z0-9._:-]{1,128}").matches(requestId))
        require(kind=="stop" || (text.isNotBlank()&&text.length<=24_000))
        val safe=CredentialRedactor.redact(text)
        val topic=workItemId?.let { topic(store.getWorkItem(it)?:throw NoSuchElementException()) } ?: UUID.randomUUID().toString()
        val input=DialogueInput(UUID.randomUUID().toString(),device.id,requestId,kind,safe,topic,workItemId)
        val (accepted,replayed)=events.accept(input,fingerprint(kind,text,workItemId)) {
            if(workItemId!=null) require(!store.getWorkItem(workItemId)!!.state.isTerminal) {"task_terminal"}
        }
        if(kind=="stop") stop(accepted)
        else if(kind=="message") enqueue(accepted)
        else kernel.orchestrationKernel.signalWorker(workItemId!!)
        return receipt(accepted,replayed)
    }
    fun receipt(device:PairedDevice,requestId:String):DialogueReceipt?=events.find(device.id,requestId)?.let {receipt(it,true)}
    private fun receipt(input:DialogueInput,replayed:Boolean):DialogueReceipt {
        val work=if(input.workItemId!=null) listOf(input.workItemId) else store.listWorkItems().filter {item->item.sourceProvenance.any {it.messageId=="native:${input.id}"}}.map {it.workItemId}
        return DialogueReceipt(input.id,input.requestId,input.topicId,work,events.disposition(input.id),replayed,soulRevision=kernel.soulStore.currentRevision())
    }
    private fun enqueue(input:DialogueInput) {
        if(events.isConsumed(input.id)||!enqueued.add(input.id))return
        scope.launch {
            try { ingress(InboundMessage(messageId="native:${input.id}",channel=ChannelKind.APP,chatId=input.deviceId,
                threadId=input.topicId,senderId=input.deviceId,senderRole=SenderRole.OWNER,scope=ConversationScope.DIRECT,text=input.text,
                metadata=mapOf("thread_key" to "native:${input.topicId}","native_event_id" to input.id))) }
            catch(e:CancellationException){throw e}
            catch(_:Exception){enqueued.remove(input.id)} // Remains durable and is retried by recovery, without claiming consumption.
        }
    }
    suspend fun watchFeedback(id: String) {
        val input = events.pending("message").firstOrNull { it.id == id } ?: return
        resumeFeedback(input)
    }
    private fun workFor(input: DialogueInput) = store.listWorkItems().filter { item ->
        item.sourceProvenance.any { it.messageId == "native:${input.id}" }
    }
    private suspend fun publish(id: String, text: String, input: DialogueInput) {
        if (text.isBlank() || events.hasEvent(id)) return
        persistReply(id, text)
        // Existing native clients recognize ack:* without workItemId as nonterminal feedback.
        // Preserve that contract for milestones and keepalives as well as the initial acknowledgement.
        events.append(DialogueEvent(id, "assistant_reply", "assistant", text, input.topicId))
    }
    /** Monotonic elapsed time since visible progress; internal step counters never reset this window. */
    internal suspend fun evaluateFeedback() = feedbackMutex.withLock {
        for ((id, state) in feedback.toMap()) {
            val work = workFor(state.input)
            if (events.isConsumed(id) && work.none { !it.state.isTerminal }) {
                removeFeedback(id)
                continue
            }
            if (work.isNotEmpty() && work.none { it.state == WorkItemState.STARTING || it.state == WorkItemState.WORKING }) continue
            val now = clockMs()
            if (now - state.startedMs >= 1_500 && state.window == "start") {
                requestFeedback(state, work, silence = false)
            }
            if (!state.keptAlive && now - state.lastMeaningfulMs >= 60_000) {
                if (requestFeedback(state, work, silence = true)) state.keptAlive = true
            }
        }
    }
    /** Called under feedbackMutex; drafting never holds it or delays the final answer/stop path. */
    private fun requestFeedback(state: Feedback, work: List<CloudWorkItemRecord>, silence: Boolean): Boolean {
        val id = if (silence) "ack:keepalive:${state.input.id}:${state.window}" else "ack:${state.input.id}"
        if (state.draftJob?.isActive == true || events.hasEvent(id) || !state.attempted.add(id)) return false
        val window = state.window
        val soulRevision = kernel.soulStore.currentRevision()
        val latestProgress = events.latestMeaningfulFeedback(state.input.topicId)?.text
        val previousWaitingText = state.lastWaitingText
        val draftJob = scope.launch(start = CoroutineStart.LAZY) {
            val text = try { feedbackWriter.draft(state.input, work, silence, latestProgress, previousWaitingText) }
                catch (e: CancellationException) { throw e }
                catch (_: Exception) {
                    store.appendDiagnosticEvent(state.input.topicId, null, "dialogue_feedback_unavailable",
                        detail = "等待说明未生成，沿用既有等待状态", nowMs = System.currentTimeMillis())
                    null
                }
            feedbackMutex.withLock {
                ensureActive()
                if (feedback[state.input.id] !== state || state.window != window || kernel.soulStore.currentRevision() != soulRevision) return@withLock
                val currentWork = workFor(state.input)
                if (events.isConsumed(state.input.id) && currentWork.none { !it.state.isTerminal }) return@withLock
                if (currentWork.isNotEmpty() && currentWork.none { it.state == WorkItemState.STARTING || it.state == WorkItemState.WORKING }) return@withLock
                if (!text.isNullOrBlank() && text.filter(Char::isLetterOrDigit) != state.lastWaitingText?.filter(Char::isLetterOrDigit)) {
                    publish(id, text, state.input)
                    state.lastWaitingText = text
                }
            }
        }
        state.draftJob = draftJob
        draftJob.start()
        return true
    }
    private fun removeFeedback(id: String) { feedback.remove(id)?.draftJob?.cancel() }
    private fun commentaryText(raw: String): String? {
        val text = OutwardTextSanitizer.sanitize(raw, kernel.router.forbiddenToolNames)
        val fingerprint = text.filter { it.isLetterOrDigit() }.lowercase()
        val continuation = Regex("^(?:我|我会|我再|我们)?(?:继续(?:查|查看|查询|处理|检查|核对)|还在(?:看|查|处理)|正在(?:看|查|查询|检查|处理))(?:一下|中|稍等|请稍等)?$")
        if (fingerprint.isEmpty() || continuation.matches(fingerprint) || fingerprint in setOf("收到", "好的", "继续", "收到我来处理", "收到我来处理完成或遇到问题都会在这里告诉你", "stilllooking", "continuing", "workingonit")) return null
        return text
    }
    suspend fun commentary(item: CloudWorkItemRecord, raw: String): Unit = feedbackMutex.withLock {
        if (store.getWorkItem(item.workItemId)?.state?.isTerminal != false) return
        val text = commentaryText(raw) ?: return
        val state = feedback.values.firstOrNull { "native:${it.input.topicId}" in item.subscribedThreadKeys } ?: return
        val signature = OrchestrationHash.sha256Hex(text.split(Regex("\\s+")).joinToString(" "))
        val id = "ack:progress:${item.workItemId}:$signature"
        if (events.hasEvent(id)) return
        publish(id, text, state.input)
        state.draftJob?.cancel()
        state.lastMeaningfulMs = clockMs()
        state.window = signature
        state.keptAlive = false
    }
    suspend fun handled(triggers:List<RouterTriggerEvent>,replies:List<String>) {
        triggers.mapNotNull {it.sourceMessageId?.removePrefix("native:")}.forEach {id->
            events.pending("message").firstOrNull {it.id==id}?.let {
                feedbackMutex.withLock {
                    val work = workFor(it)
                    val visible = replies.mapNotNull { raw ->
                        if (work.isNotEmpty()) commentaryText(raw)
                        else OutwardTextSanitizer.sanitize(raw, kernel.router.forbiddenToolNames).takeIf(String::isNotBlank)
                    }
                    visible.forEachIndexed {n,text->persistReply("reply:${it.id}:$n",text)}
                    events.routerResult(it,visible);enqueued.remove(id)
                    val state = feedback[id]
                    if (visible.isNotEmpty() && state != null) {
                        state.draftJob?.cancel()
                        state.lastMeaningfulMs = clockMs()
                        state.window = OrchestrationHash.sha256Hex(visible.joinToString("\n"))
                        state.keptAlive = false
                    } else if (state?.window == "start" && work.any { item -> !item.state.isTerminal }) {
                        // Dispatch is known to be long work; acknowledge once without waiting for the timer.
                        requestFeedback(state, work, silence = false)
                    }
                    if (work.none { item -> !item.state.isTerminal }) removeFeedback(id)
                }
            }
        }
    }
    private suspend fun stop(input:DialogueInput) {
        if(events.isConsumed(input.id))return
        kernel.orchestrationKernel.cancelWorkItem(CloudPrincipal.OwnerUser(input.deviceId,"app"),input.workItemId!!)
        events.consume(listOf(input))
    }
    fun topic(item:CloudWorkItemRecord)=item.subscribedThreadKeys.firstOrNull {it.startsWith("native:")}?.removePrefix("native:") ?: item.workItemId
    suspend fun settlement(item:CloudWorkItemRecord,report:WorkerSettlementReport): Unit = feedbackMutex.withLock {
        if(report.outcome=="cancelled")events.abandonPending(item.workItemId)
        if(item.subscribedThreadKeys.none {it.startsWith("native:")})return
        val text=OutwardTextSanitizer.sanitize(report.summary,kernel.router.forbiddenToolNames).ifBlank {
            if (report.outcome == "completed") "任务已完成。" else if (report.outcome == "cancelled") "任务已停止。" else "任务未完成。"
        }
        persistReply("result:${item.workItemId}", "${item.title} · ${if(report.outcome=="completed") "已完成" else if(report.outcome=="cancelled") "已停止" else "未完成"}\n$text")
        events.append(DialogueEvent("result:${item.workItemId}","task_result","assistant",text,topic(item),item.workItemId,report.outcome))
        feedback.filterValues { state -> workFor(state.input).let { work -> work.isNotEmpty() && work.all { it.state.isTerminal } } }
            .keys.toList().forEach(::removeFeedback)
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
        // Resume feedback for already-consumed dispatches too; published IDs prevent replay bubbles.
        store.listWorkItems().filter { !it.state.isTerminal }.forEach { item ->
            item.sourceProvenance.forEach { source ->
                source.messageId.removePrefix("native:").let { id ->
                    events.input(id)?.let { input -> resumeFeedback(input) }
                }
            }
        }
    }
    private suspend fun resumeFeedback(input: DialogueInput) = feedbackMutex.withLock {
        if (input.id !in feedback) {
            // Monotonic time starts afresh after restart; durable window IDs still prevent repeat bubbles.
            val state = Feedback(input, clockMs())
            events.latestMeaningfulFeedback(input.topicId)?.let { last ->
                state.window = if (last.id.startsWith("ack:progress:")) last.id.substringAfterLast(':')
                    else OrchestrationHash.sha256Hex(last.text)
            }
            state.keptAlive = events.hasEvent("ack:keepalive:${input.id}:${state.window}")
            state.lastWaitingText = events.latestWaitingFeedback(input.topicId)?.text
            feedback[input.id] = state
        }
        if (feedbackJob?.isActive != true) feedbackJob = scope.launch {
            while (isActive) {
                delay(1_000)
                evaluateFeedback()
                if (feedbackMutex.withLock {
                    if (feedback.isEmpty()) { feedbackJob = null; true } else false
                }) break
            }
        }
    }
    suspend fun closeAndJoin() {
        scope.coroutineContext[Job]?.cancelAndJoin()
    }
}
