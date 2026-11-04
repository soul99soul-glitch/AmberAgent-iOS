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
    fun settlement(item:CloudWorkItemRecord,report:WorkerSettlementReport) {
        if(report.outcome=="cancelled")events.abandonPending(item.workItemId)
        if(item.subscribedThreadKeys.none {it.startsWith("native:")})return
        val text=OutwardTextSanitizer.sanitize(report.summary,kernel.router.forbiddenToolNames)
        events.append(DialogueEvent("result:${item.workItemId}","task_result","assistant",text,topic(item),item.workItemId,report.outcome))
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
