package app.amber.cloud.orchestration

import app.amber.ai.ui.UIMessage
import kotlinx.coroutines.channels.Channel
import java.util.concurrent.ConcurrentHashMap
import kotlin.uuid.Uuid

/** Signals are only wakeups; the SQLite inbox is the source of truth. */
class WorkerEventInbox(private val kernel:DefaultCloudOrchestrationKernel) {
    private val signals=ConcurrentHashMap<String,Channel<Unit>>()
    private val stopping=ConcurrentHashMap.newKeySet<String>()
    fun signal(id:String){signals.computeIfAbsent(id){Channel(Channel.CONFLATED)}.trySend(Unit)}
    fun requestStop(id:String){stopping.add(id);signal(id)}
    fun isStopping(id:String)=id in stopping || kernel.store.dialogue.pending("stop",id).isNotEmpty()
    fun pending(id:String)=kernel.store.dialogue.pending(workItemId=id).filter {it.kind=="followup"||it.kind=="process"}
    suspend fun prepare(item:CloudWorkItemRecord):List<DialogueInput> {
        val inputs=pending(item.workItemId)
        for(input in inputs) kernel.appendMessageToSessionInternal(item.workerSessionId!!,
            UIMessage.user("【任务事件 ${input.kind} · ${input.id}】\n${input.text}").copy(id=Uuid.parse(input.id)),System.currentTimeMillis())
        return inputs
    }
    suspend fun await(id:String) {
        val channel=signals.computeIfAbsent(id){Channel(Channel.CONFLATED)}
        while(pending(id).isEmpty()&&!isStopping(id)&&kernel.store.getWorkItem(id)?.state?.isTerminal==false)channel.receive()
    }
}
