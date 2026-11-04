package app.amber.cloud.orchestration

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.execSQL
import app.amber.cloud.security.CredentialRedactor
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID

@Serializable data class DialogueInput(
    val id: String, val deviceId: String, val requestId: String, val kind: String,
    val text: String, val topicId: String, val workItemId: String? = null,
)
@Serializable data class DialogueReceipt(
    val eventId: String, val requestId: String, val topicId: String, val workItemIds: List<String>,
    val state: String, val replayed: Boolean = false, val soulRevision: Long = 0L,
)
@Serializable data class DialogueEvent(
    val id: String, val kind: String, val role: String, val text: String, val topicId: String,
    val workItemId: String? = null, val outcome: String? = null, val seq: Long = 0,
)
@Serializable data class DialoguePage(val items: List<DialogueEvent>, val nextCursor: Long, val soulRevision: Long = 0L)
data class RecordedTaskProcess(val id: String, val owner: String, val pid: Long, val startedAtMs: Long)
class DialogueConflict(val code: String) : IllegalArgumentException(code)

/** Uses the orchestration connection and its monitor; input + outward event commit before ACK. */
class DialogueEventStore(private val db: SQLiteConnection, private val lock: Any) {
    private val json = Json { encodeDefaults = true }
    init { synchronized(lock) {
        db.execSQL("CREATE TABLE IF NOT EXISTS dialogue_inputs(id TEXT PRIMARY KEY, device_id TEXT NOT NULL, request_id TEXT NOT NULL, fingerprint TEXT NOT NULL, payload TEXT NOT NULL, consumed INTEGER NOT NULL DEFAULT 0, UNIQUE(device_id,request_id))")
        db.execSQL("CREATE TABLE IF NOT EXISTS dialogue_events(seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT UNIQUE NOT NULL,payload TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS dialogue_plans(id TEXT PRIMARY KEY,payload TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS task_processes(id TEXT PRIMARY KEY,owner TEXT NOT NULL,pid INTEGER NOT NULL,started_ms INTEGER NOT NULL,finished INTEGER NOT NULL DEFAULT 0)")
    } }
    private fun <T> transaction(block: () -> T): T = synchronized(lock) {
        db.execSQL("BEGIN IMMEDIATE")
        try { val value = block(); db.execSQL("COMMIT"); value }
        catch (t: Throwable) { db.execSQL("ROLLBACK"); throw t }
    }
    fun find(deviceId: String, requestId: String): DialogueInput? = synchronized(lock) {
        db.prepare("SELECT payload FROM dialogue_inputs WHERE device_id=? AND request_id=?").use {
            it.bindText(1,deviceId); it.bindText(2,requestId)
            if (it.step()) json.decodeFromString<DialogueInput>(it.getText(0)) else null
        }
    }
    fun accept(input: DialogueInput, fingerprint: String, validate: () -> Unit): Pair<DialogueInput, Boolean> = transaction {
        db.prepare("SELECT payload,fingerprint FROM dialogue_inputs WHERE device_id=? AND request_id=?").use {
            it.bindText(1,input.deviceId); it.bindText(2,input.requestId)
            if (it.step()) {
                if (it.getText(1) != fingerprint) throw DialogueConflict("request_id_conflict")
                return@transaction json.decodeFromString<DialogueInput>(it.getText(0)) to true
            }
        }
        validate()
        insertInput(input, fingerprint)
        append(DialogueEvent(input.id, if(input.kind=="message") "user_message" else if(input.kind=="stop") "stop_requested" else "followup",
            "user", input.text, input.topicId, input.workItemId))
        input to false
    }
    private fun insertInput(input: DialogueInput, fingerprint: String) {
        db.prepare("INSERT OR IGNORE INTO dialogue_inputs(id,device_id,request_id,fingerprint,payload) VALUES(?,?,?,?,?)").use {
            it.bindText(1,input.id);it.bindText(2,input.deviceId);it.bindText(3,input.requestId);it.bindText(4,fingerprint);it.bindText(5,json.encodeToString(input));it.step()
        }
    }
    fun pending(kind: String? = null, workItemId: String? = null): List<DialogueInput> = synchronized(lock) {
        db.prepare("SELECT payload FROM dialogue_inputs WHERE consumed=0 ORDER BY rowid").use {
            buildList { while(it.step()) { val input=json.decodeFromString<DialogueInput>(it.getText(0))
                if((kind==null||input.kind==kind)&&(workItemId==null||input.workItemId==workItemId)) add(input)
            } }
        }
    }
    fun isConsumed(id: String): Boolean = synchronized(lock) {
        db.prepare("SELECT consumed FROM dialogue_inputs WHERE id=?").use {it.bindText(1,id);it.step()&&it.getLong(0)==1L}
    }
    fun disposition(id:String):String=synchronized(lock) {
        db.prepare("SELECT consumed FROM dialogue_inputs WHERE id=?").use {
            it.bindText(1,id)
            when(if(it.step())it.getLong(0)else 0L){1L->"consumed";2L->"cancelled";else->"received"}
        }
    }
    fun abandonPending(workItemId:String)=transaction {
        pending(workItemId=workItemId).filter {it.kind!="stop"}.forEach {input->
            db.prepare("UPDATE dialogue_inputs SET consumed=2 WHERE id=?").use {it.bindText(1,input.id);it.step()}
            if(input.kind=="followup")append(DialogueEvent("cancelled:${input.id}","input_cancelled","system","任务已停止，这条补充未执行",input.topicId,workItemId))
        }
    }
    fun consume(inputs: List<DialogueInput>) = transaction {
        inputs.forEach { input ->
            db.prepare("UPDATE dialogue_inputs SET consumed=1 WHERE id=?").use {it.bindText(1,input.id);it.step()}
            if(input.kind=="followup") append(DialogueEvent("consumed:${input.id}","input_consumed","system","补充已被任务消费",input.topicId,input.workItemId))
        }
    }
    fun routerResult(input: DialogueInput, replies: List<String>) = transaction {
        replies.forEachIndexed { n,text -> append(DialogueEvent("reply:${input.id}:$n","assistant_reply","assistant",text,input.topicId)) }
        db.prepare("UPDATE dialogue_inputs SET consumed=1 WHERE id=?").use {it.bindText(1,input.id);it.step()}
    }
    fun append(event: DialogueEvent) = synchronized(lock) {
        db.prepare("INSERT OR IGNORE INTO dialogue_events(id,payload) VALUES(?,?)").use {it.bindText(1,event.id);it.bindText(2,json.encodeToString(event));it.step()}
    }
    fun page(after: Long, limit: Int): DialoguePage = synchronized(lock) {
        require(after>=0&&limit in 1..100)
        val items = db.prepare("SELECT seq,payload FROM dialogue_events WHERE seq>? ORDER BY seq LIMIT ?").use {
            it.bindLong(1,after);it.bindLong(2,limit.toLong())
            buildList {while(it.step()) add(json.decodeFromString<DialogueEvent>(it.getText(1)).copy(seq=it.getLong(0)))}
        }
        DialoguePage(items,items.lastOrNull()?.seq?:after)
    }
    fun plan(id: String): RouterDecision? = synchronized(lock) {
        db.prepare("SELECT payload FROM dialogue_plans WHERE id=?").use {it.bindText(1,id);if(it.step())json.decodeFromString<RouterDecision>(it.getText(0))else null}
    }
    fun savePlan(id: String, decision: RouterDecision) = synchronized(lock) {
        db.prepare("INSERT OR IGNORE INTO dialogue_plans(id,payload) VALUES(?,?)").use {it.bindText(1,id);it.bindText(2,json.encodeToString(decision));it.step()}
    }
    fun processStarted(id: String, owner: String, pid: Long, startedAtMs: Long) = synchronized(lock) {
        db.prepare("INSERT INTO task_processes(id,owner,pid,started_ms) VALUES(?,?,?,?)").use {
            it.bindText(1,id);it.bindText(2,owner);it.bindLong(3,pid);it.bindLong(4,startedAtMs);it.step()
        }
    }
    fun runningProcesses(): List<RecordedTaskProcess> = synchronized(lock) {
        db.prepare("SELECT id,owner,pid,started_ms FROM task_processes WHERE finished=0").use {
            buildList {while(it.step())add(RecordedTaskProcess(it.getText(0),it.getText(1),it.getLong(2),it.getLong(3)))}
        }
    }
    fun processFinished(id: String, owner: String, topic: String, text: String) = transaction {
        db.prepare("UPDATE task_processes SET finished=1 WHERE id=?").use {it.bindText(1,id);it.step()}
        val eventId=UUID.nameUUIDFromBytes("process:$id".toByteArray()).toString()
        val safe=CredentialRedactor.redact(text)
        insertInput(DialogueInput(eventId,"system",id,"process",safe,topic,owner),id)
        // Model inbox retains bounded output; the public timeline exposes only human-readable activity.
        append(DialogueEvent("process:$id","process_event","system","后台执行状态已更新",topic,owner))
    }
}
