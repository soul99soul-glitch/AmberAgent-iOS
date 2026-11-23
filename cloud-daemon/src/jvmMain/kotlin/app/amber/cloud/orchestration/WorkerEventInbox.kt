package app.amber.cloud.orchestration

import app.amber.ai.ui.UIMessage
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.uuid.Uuid

/** Signals are only wakeups; the SQLite inbox is the source of truth. */
class WorkerEventInbox(private val kernel:DefaultCloudOrchestrationKernel) {
    private val signals=ConcurrentHashMap<String,Channel<Unit>>()
    private val stopping=ConcurrentHashMap.newKeySet<String>()
    private val wakeListeners=ConcurrentHashMap<String,CopyOnWriteArrayList<() -> Unit>>()
    fun signal(id:String){
        signals.computeIfAbsent(id){Channel(Channel.CONFLATED)}.trySend(Unit)
        wakeListeners[id]?.forEach { runCatching { it() } }
    }
    fun requestStop(id: String) {
        kernel.store.dialogue.markStopping(id)
        stopping.add(id)
        signal(id)
    }
    fun watchEvents(id: String, onWake: () -> Unit): () -> Unit {
        val list = wakeListeners.computeIfAbsent(id) { CopyOnWriteArrayList() }
        list.add(onWake)
        return { list.remove(onWake) }
    }
    fun isStopping(id:String)=id in stopping || kernel.store.dialogue.isStopping(id)
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

    suspend fun awaitUntil(id: String, timeoutMs: Long, predicate: () -> Boolean): Boolean {
        if (predicate()) return true
        if (timeoutMs <= 0L) return false
        val wakeSignal = Channel<Unit>(Channel.CONFLATED)
        val unwatch = watchEvents(id) { wakeSignal.trySend(Unit) }
        return try {
            if (predicate()) return true
            if (timeoutMs == Long.MAX_VALUE) {
                while (!predicate()) {
                    wakeSignal.receive()
                }
                true
            } else {
                val matched = withTimeoutOrNull(timeoutMs) {
                    while (!predicate()) {
                        wakeSignal.receive()
                    }
                    true
                }
                matched == true || predicate()
            }
        } finally {
            unwatch()
        }
    }
}
