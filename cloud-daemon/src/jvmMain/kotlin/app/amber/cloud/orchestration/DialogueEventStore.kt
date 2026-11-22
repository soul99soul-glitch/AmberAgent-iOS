package app.amber.cloud.orchestration

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.execSQL
import app.amber.cloud.security.CredentialRedactor
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID

const val DIALOGUE_CONTRACT_SCHEMA_VERSION: Int = 1

object DialogueEventKinds {
    const val USER_MESSAGE = "user_message"
    const val FOLLOWUP = "followup"
    const val STOP_REQUESTED = "stop_requested"
    const val INPUT_CONSUMED = "input_consumed"
    const val INPUT_CANCELLED = "input_cancelled"
    const val ASSISTANT_REPLY = "assistant_reply"
    const val PROCESS_EVENT = "process_event"
    const val TASK_RESULT = "task_result"
    const val RUN_STARTED = "run_started"
    const val RUN_FINISHED = "run_finished"
    const val RUN_HANDOFF = "run_handoff"
    const val LEDGER_IMPORTED = "ledger_imported"
    const val STOP_TOO_LATE = "stop_too_late"
}

@Serializable data class DialogueInput(
    val id: String,
    val deviceId: String,
    val requestId: String,
    val kind: String,
    val text: String,
    val topicId: String,
    val workItemId: String? = null,
    val replyAddress: ImAddress? = null,
    val sourceMessageId: String? = null,
    val senderId: String? = null,
    val threadId: String? = null,
    val createdAtMs: Long? = null,
    val routerPlanId: String? = null,
    val directWorkItemIds: List<String>? = null,
    val conversationId: String? = null,
    val executorKind: String? = null,
    val executorId: String? = null,
    val epoch: Long? = null,
    val parentRunId: String? = null,
    val observedSeq: Long? = null,
    val ledgerId: String? = null,
    val schemaVersion: Int = DIALOGUE_CONTRACT_SCHEMA_VERSION,
    // Stored at admission so a legacy retry can distinguish a rejected input from one cancelled later.
    internal val closedOnArrival: Boolean = false,
)

@Serializable data class DialogueReceipt(
    val eventId: String,
    val requestId: String,
    val topicId: String,
    val workItemIds: List<String>,
    val state: String,
    val replayed: Boolean = false,
    val soulRevision: Long = 0L,
    val conversationId: String? = null,
    val executorKind: String? = null,
    val executorId: String? = null,
    val epoch: Long? = null,
    val causedByInputId: String? = null,
    val causedByRequestId: String? = null,
    val parentRunId: String? = null,
    val observedSeq: Long? = null,
    val ledgerId: String? = null,
    val outcomeUnknown: Boolean = false,
    val schemaVersion: Int = DIALOGUE_CONTRACT_SCHEMA_VERSION,
)

@Serializable data class DialogueEvent(
    val id: String,
    val kind: String,
    val role: String,
    val text: String,
    val topicId: String,
    val workItemId: String? = null,
    val outcome: String? = null,
    val seq: Long = 0,
    val conversationId: String? = null,
    val executorKind: String? = null,
    val executorId: String? = null,
    val epoch: Long? = null,
    val causedByInputId: String? = null,
    val causedByRequestId: String? = null,
    val parentRunId: String? = null,
    val observedSeq: Long? = null,
    val ledgerId: String? = null,
    val outcomeUnknown: Boolean = false,
    val schemaVersion: Int = DIALOGUE_CONTRACT_SCHEMA_VERSION,
    val riskLevel: String? = null,
    val targetDevice: String? = null,
    val targetSummary: String? = null,
    val diffPreview: String? = null,
    val requiresLocalApproval: Boolean? = null,
    val sourceRefs: List<String>? = null,
    val sourcePaths: List<String>? = null,
)

@Serializable data class DialoguePage(
    val items: List<DialogueEvent>,
    val nextCursor: Long,
    val soulRevision: Long = 0L,
    val schemaVersion: Int = DIALOGUE_CONTRACT_SCHEMA_VERSION,
)

@Serializable data class LedgerImportResult(
    val ledgerId: String,
    val importedCount: Int,
    val duplicateCount: Int,
    val auditEventId: String,
    val schemaVersion: Int = DIALOGUE_CONTRACT_SCHEMA_VERSION,
)

data class RecordedTaskProcess(val id: String, val owner: String, val pid: Long, val startedAtMs: Long)
class DialogueConflict(val code: String) : IllegalArgumentException(code)

/** Uses the orchestration connection and its monitor; input + outward event commit before ACK. */
class DialogueEventStore(private val db: SQLiteConnection, private val lock: Any) {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }

    private enum class WorkItemLifecycle(val persisted: String) {
        ACTIVE("active"),
        STOPPING("stopping"),
        COMPLETED("completed"),
        FAILED("failed"),
        CANCELLED("cancelled");

        val isTerminal: Boolean get() = this == COMPLETED || this == FAILED || this == CANCELLED
        val isStoppingOrTerminal: Boolean get() = this == STOPPING || isTerminal

        companion object {
            fun fromString(raw: String?): WorkItemLifecycle? = when (raw?.lowercase()) {
                "active" -> ACTIVE
                "stopping" -> STOPPING
                "completed" -> COMPLETED
                "failed" -> FAILED
                "cancelled" -> CANCELLED
                else -> null
            }
        }
    }
    init { synchronized(lock) {
        db.execSQL("CREATE TABLE IF NOT EXISTS dialogue_inputs(id TEXT PRIMARY KEY, device_id TEXT NOT NULL, request_id TEXT NOT NULL, fingerprint TEXT NOT NULL, payload TEXT NOT NULL, consumed INTEGER NOT NULL DEFAULT 0, UNIQUE(device_id,request_id))")
        db.execSQL("CREATE TABLE IF NOT EXISTS dialogue_events(seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT UNIQUE NOT NULL,payload TEXT NOT NULL)")
        db.execSQL("""CREATE INDEX IF NOT EXISTS dialogue_late_stop_causes ON dialogue_events(json_extract(payload,'$.causedByInputId')) WHERE json_extract(payload,'$.kind')='stop_too_late'""")
        db.execSQL("CREATE TABLE IF NOT EXISTS dialogue_plans(id TEXT PRIMARY KEY,payload TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS task_processes(id TEXT PRIMARY KEY,owner TEXT NOT NULL,pid INTEGER NOT NULL,started_ms INTEGER NOT NULL,finished INTEGER NOT NULL DEFAULT 0)")
        db.execSQL("CREATE TABLE IF NOT EXISTS dialogue_work_item_state(work_item_id TEXT PRIMARY KEY,max_epoch INTEGER,lifecycle_state TEXT)")
    } }

    private fun <T> transaction(block: () -> T): T = synchronized(lock) {
        db.execSQL("BEGIN IMMEDIATE")
        try { val value = block(); db.execSQL("COMMIT"); value }
        catch (t: Throwable) { db.execSQL("ROLLBACK"); throw t }
    }

    private fun hasWorkItemsTableLocked(): Boolean =
        db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='work_items'").use { it.step() }

    private fun currentMaxEpochLocked(workItemId: String): Long? {
        var maxEpoch: Long? = db.prepare("SELECT max_epoch FROM dialogue_work_item_state WHERE work_item_id=?").use {
            it.bindText(1, workItemId)
            if (it.step() && !it.isNull(0)) it.getLong(0) else null
        }
        if (hasWorkItemsTableLocked()) {
            db.prepare("SELECT record_json FROM work_items WHERE work_item_id=?").use {
                it.bindText(1, workItemId)
                if (it.step()) {
                    val recordEpoch = runCatching { json.decodeFromString<CloudWorkItemRecord>(it.getText(0)).epoch }.getOrNull()
                    if (recordEpoch != null && (maxEpoch == null || recordEpoch > maxEpoch)) {
                        maxEpoch = recordEpoch
                    }
                }
            }
        }
        return maxEpoch
    }

    private fun updateWorkItemEpochLocked(workItemId: String, epoch: Long?) {
        if (epoch == null) return
        val existing = db.prepare("SELECT max_epoch FROM dialogue_work_item_state WHERE work_item_id=?").use {
            it.bindText(1, workItemId)
            if (it.step()) (true to (if (it.isNull(0)) null else it.getLong(0))) else (false to null)
        }
        if (!existing.first) {
            db.prepare("INSERT INTO dialogue_work_item_state(work_item_id,max_epoch,lifecycle_state) VALUES(?,?,NULL)").use {
                it.bindText(1, workItemId); it.bindLong(2, epoch); it.step()
            }
        } else if (existing.second == null || epoch > existing.second!!) {
            db.prepare("UPDATE dialogue_work_item_state SET max_epoch=? WHERE work_item_id=?").use {
                it.bindLong(1, epoch); it.bindText(2, workItemId); it.step()
            }
        }
    }

    private fun upsertWorkItemLifecycleLocked(workItemId: String, lifecycle: WorkItemLifecycle) {
        val existing = db.prepare("SELECT lifecycle_state FROM dialogue_work_item_state WHERE work_item_id=?").use {
            it.bindText(1, workItemId)
            if (it.step()) (true to (if (it.isNull(0)) null else WorkItemLifecycle.fromString(it.getText(0)))) else (false to null)
        }
        val current = existing.second
        if (current != null && current.isTerminal && !lifecycle.isTerminal) return
        if (current == WorkItemLifecycle.COMPLETED && lifecycle == WorkItemLifecycle.CANCELLED) return
        if (!existing.first) {
            db.prepare("INSERT INTO dialogue_work_item_state(work_item_id,max_epoch,lifecycle_state) VALUES(?,NULL,?)").use {
                it.bindText(1, workItemId); it.bindText(2, lifecycle.persisted); it.step()
            }
        } else {
            db.prepare("UPDATE dialogue_work_item_state SET lifecycle_state=? WHERE work_item_id=?").use {
                it.bindText(1, lifecycle.persisted); it.bindText(2, workItemId); it.step()
            }
        }
    }

    private fun resolveWorkItemLifecycleLocked(workItemId: String): WorkItemLifecycle? {
        if (hasWorkItemsTableLocked()) {
            db.prepare("SELECT state FROM work_items WHERE work_item_id=?").use {
                it.bindText(1, workItemId)
                if (it.step()) {
                    when (it.getText(0)) {
                        WorkItemState.COMPLETED.name -> return WorkItemLifecycle.COMPLETED
                        WorkItemState.CANCELLED.name -> return WorkItemLifecycle.CANCELLED
                        WorkItemState.FAILED.name -> return WorkItemLifecycle.FAILED
                    }
                }
            }
        }
        val recorded = db.prepare("SELECT lifecycle_state FROM dialogue_work_item_state WHERE work_item_id=?").use {
            it.bindText(1, workItemId)
            if (it.step() && !it.isNull(0)) WorkItemLifecycle.fromString(it.getText(0)) else null
        }
        if (recorded != null) return recorded
        val hasPendingStop = db.prepare("SELECT payload FROM dialogue_inputs WHERE consumed=0").use { stmt ->
            var found = false
            while (stmt.step()) {
                val input = runCatching { json.decodeFromString<DialogueInput>(stmt.getText(0)) }.getOrNull()
                if (input?.kind == "stop" && input.workItemId == workItemId) {
                    found = true
                    break
                }
            }
            found
        }
        return if (hasPendingStop) WorkItemLifecycle.STOPPING else null
    }

    fun markStopping(workItemId: String) = transaction {
        upsertWorkItemLifecycleLocked(workItemId, WorkItemLifecycle.STOPPING)
    }

    fun isStopping(workItemId: String): Boolean = synchronized(lock) {
        resolveWorkItemLifecycleLocked(workItemId) == WorkItemLifecycle.STOPPING
    }

    private fun DialogueInput.toUserEvent(): DialogueEvent = DialogueEvent(
        id = id,
        kind = when (kind) {
            "message" -> DialogueEventKinds.USER_MESSAGE
            "stop" -> DialogueEventKinds.STOP_REQUESTED
            else -> DialogueEventKinds.FOLLOWUP
        },
        role = "user",
        text = text,
        topicId = topicId,
        workItemId = workItemId,
        conversationId = conversationId,
        executorKind = executorKind,
        executorId = executorId,
        epoch = epoch,
        parentRunId = parentRunId,
        observedSeq = observedSeq,
        ledgerId = ledgerId,
    )

    fun find(deviceId: String, requestId: String): DialogueInput? = synchronized(lock) {
        db.prepare("SELECT payload FROM dialogue_inputs WHERE device_id=? AND request_id=?").use {
            it.bindText(1, deviceId); it.bindText(2, requestId)
            if (it.step()) json.decodeFromString<DialogueInput>(it.getText(0)) else null
        }
    }
    fun input(id: String): DialogueInput? = findById(id)

    fun findById(inputId: String): DialogueInput? = synchronized(lock) {
        db.prepare("SELECT payload FROM dialogue_inputs WHERE id=?").use {
            it.bindText(1, inputId)
            if (it.step()) json.decodeFromString<DialogueInput>(it.getText(0)) else null
        }
    }

    fun accept(input: DialogueInput, fingerprint: String, validate: () -> Unit = {}): Pair<DialogueInput, Boolean> = transaction {
        db.prepare("SELECT payload,fingerprint FROM dialogue_inputs WHERE device_id=? AND request_id=?").use {
            it.bindText(1, input.deviceId); it.bindText(2, input.requestId)
            if (it.step()) {
                if (it.getText(1) != fingerprint) throw DialogueConflict("request_id_conflict")
                return@transaction json.decodeFromString<DialogueInput>(it.getText(0)) to true
            }
        }
        validate()
        val targetWorkItemId = input.workItemId
        if (targetWorkItemId != null && input.epoch != null) {
            val currentEpoch = currentMaxEpochLocked(targetWorkItemId)
            if (currentEpoch != null && input.epoch < currentEpoch) {
                throw DialogueConflict("stale_epoch")
            }
        }
        val lifecycle = targetWorkItemId?.let(::resolveWorkItemLifecycleLocked)
        val cancelledFollowup = input.kind == "followup" && lifecycle?.isStoppingOrTerminal == true
        val terminalStop = input.kind == "stop" && lifecycle?.isTerminal == true
        val lateStop = input.kind == "stop" && lifecycle == WorkItemLifecycle.COMPLETED
        val accepted = input.copy(closedOnArrival = cancelledFollowup || terminalStop)
        val consumed = when {
            cancelledFollowup || lateStop -> 2
            terminalStop -> 1 // Stopping an already cancelled or failed task is a handled no-op.
            else -> 0
        }
        insertInput(accepted, fingerprint, consumed)
        if (targetWorkItemId != null) {
            updateWorkItemEpochLocked(targetWorkItemId, input.epoch)
            if (input.kind == "stop" && !terminalStop) {
                upsertWorkItemLifecycleLocked(targetWorkItemId, WorkItemLifecycle.STOPPING)
            }
        }
        appendEventRawLocked(input.toUserEvent())
        if (cancelledFollowup || lateStop) {
            appendEventRawLocked(
                DialogueEvent(
                    id = if (lateStop) "stop_too_late:${input.id}" else "cancelled:${input.id}",
                    kind = if (lateStop) DialogueEventKinds.STOP_TOO_LATE else DialogueEventKinds.INPUT_CANCELLED,
                    role = "system",
                    text = if (lateStop) "任务已完成，停止请求到达过晚" else "任务已停止，这条补充未执行",
                    topicId = input.topicId,
                    workItemId = targetWorkItemId,
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
        accepted to false
    }
    /** Persist an input idempotently without mirroring into native `dialogue_events`. */
    fun acceptSilent(input: DialogueInput, fingerprint: String): Pair<DialogueInput, Boolean> = transaction {
        db.prepare("SELECT payload,fingerprint FROM dialogue_inputs WHERE device_id=? AND request_id=?").use {
            it.bindText(1, input.deviceId); it.bindText(2, input.requestId)
            if (it.step()) {
                if (it.getText(1) != fingerprint) throw DialogueConflict("request_id_conflict")
                return@transaction json.decodeFromString<DialogueInput>(it.getText(0)) to true
            }
        }
        insertInput(input, fingerprint)
        input to false
    }

    private fun insertInput(input: DialogueInput, fingerprint: String, consumed: Int = 0) {
        db.prepare("INSERT OR IGNORE INTO dialogue_inputs(id,device_id,request_id,fingerprint,payload,consumed) VALUES(?,?,?,?,?,?)").use {
            it.bindText(1, input.id); it.bindText(2, input.deviceId); it.bindText(3, input.requestId)
            it.bindText(4, fingerprint); it.bindText(5, json.encodeToString(input)); it.bindLong(6, consumed.toLong()); it.step()
        }
    }

    fun pending(kind: String? = null, workItemId: String? = null): List<DialogueInput> = synchronized(lock) {
        db.prepare("SELECT payload FROM dialogue_inputs WHERE consumed=0 ORDER BY rowid").use {
            buildList { while (it.step()) { val input = json.decodeFromString<DialogueInput>(it.getText(0))
                if ((kind == null || input.kind == kind) && (workItemId == null || input.workItemId == workItemId)) add(input)
            } }
        }
    }

    fun isConsumed(id: String): Boolean = synchronized(lock) {
        db.prepare("SELECT consumed FROM dialogue_inputs WHERE id=?").use { it.bindText(1, id); it.step() && it.getLong(0) == 1L }
    }

    fun disposition(id: String): String = synchronized(lock) {
        db.prepare("SELECT consumed FROM dialogue_inputs WHERE id=?").use {
            it.bindText(1, id)
            when (if (it.step()) it.getLong(0) else 0L) { 1L -> "consumed"; 2L -> "cancelled"; else -> "received" }
        }
    }
    fun abandonPending(workItemId: String) = transaction {
        upsertWorkItemLifecycleLocked(workItemId, WorkItemLifecycle.CANCELLED)
        pending(workItemId = workItemId).filter { it.kind != "stop" }.forEach { input ->
            db.prepare("UPDATE dialogue_inputs SET consumed=2 WHERE id=?").use { it.bindText(1, input.id); it.step() }
            if (input.kind == "followup" && !input.deviceId.startsWith("im:") && !input.deviceId.startsWith("system:")) {
                appendEventRawLocked(
                    DialogueEvent(
                        id = "cancelled:${input.id}",
                        kind = DialogueEventKinds.INPUT_CANCELLED,
                        role = "system",
                        text = "任务已停止，这条补充未执行",
                        topicId = input.topicId,
                        workItemId = workItemId,
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
        }
    }

    fun consume(inputs: List<DialogueInput>) = transaction {
        inputs.forEach { input ->
            val consumed = db.prepare("UPDATE dialogue_inputs SET consumed=1 WHERE id=? AND consumed=0 RETURNING id").use {
                it.bindText(1, input.id)
                it.step()
            }
            if (consumed && input.kind == "followup" && !input.deviceId.startsWith("im:") && !input.deviceId.startsWith("system:")) {
                appendEventRawLocked(
                    DialogueEvent(
                        id = "consumed:${input.id}",
                        kind = DialogueEventKinds.INPUT_CONSUMED,
                        role = "system",
                        text = "补充已被任务消费",
                        topicId = input.topicId,
                        workItemId = input.workItemId,
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
        }
    }

    fun routerResult(input: DialogueInput, replies: List<String>) = transaction {
        replies.forEachIndexed { n, text ->
            appendEventRawLocked(
                DialogueEvent(
                    id = "reply:${input.id}:$n",
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
        db.prepare("UPDATE dialogue_inputs SET consumed=1 WHERE id=?").use { it.bindText(1, input.id); it.step() }
    }

    fun hasEvent(id: String): Boolean = synchronized(lock) {
        db.prepare("SELECT 1 FROM dialogue_events WHERE id=?").use { it.bindText(1, id); it.step() }
    }

    fun latestMeaningfulFeedback(topicId: String): DialogueEvent? = synchronized(lock) {
        db.prepare("SELECT payload FROM dialogue_events WHERE json_extract(payload,'$.topicId')=? AND (id LIKE 'ack:progress:%' OR id LIKE 'reply:%') ORDER BY seq DESC LIMIT 1").use {
            it.bindText(1, topicId)
            if (it.step()) json.decodeFromString<DialogueEvent>(it.getText(0)) else null
        }
    }

    fun latestWaitingFeedback(topicId: String): DialogueEvent? = synchronized(lock) {
        db.prepare("SELECT payload FROM dialogue_events WHERE json_extract(payload,'$.topicId')=? AND id LIKE 'ack:%' AND id NOT LIKE 'ack:progress:%' ORDER BY seq DESC LIMIT 1").use {
            it.bindText(1, topicId)
            if (it.step()) json.decodeFromString<DialogueEvent>(it.getText(0)) else null
        }
    }

    private fun appendEventRawLocked(event: DialogueEvent): Boolean =
        db.prepare("INSERT OR IGNORE INTO dialogue_events(id,payload) VALUES(?,?) RETURNING id").use {
            it.bindText(1, event.id); it.bindText(2, json.encodeToString(event)); it.step()
        }

    fun append(event: DialogueEvent) = transaction {
        if (!appendEventRawLocked(event)) return@transaction
        val workItemId = event.workItemId
        if (workItemId != null) {
            updateWorkItemEpochLocked(workItemId, event.epoch)
            when (event.kind) {
                DialogueEventKinds.STOP_REQUESTED -> upsertWorkItemLifecycleLocked(workItemId, WorkItemLifecycle.STOPPING)
                DialogueEventKinds.TASK_RESULT, DialogueEventKinds.RUN_FINISHED -> {
                    when (event.outcome?.lowercase()) {
                        "completed" -> upsertWorkItemLifecycleLocked(workItemId, WorkItemLifecycle.COMPLETED)
                        "cancelled" -> upsertWorkItemLifecycleLocked(workItemId, WorkItemLifecycle.CANCELLED)
                        "failed" -> upsertWorkItemLifecycleLocked(workItemId, WorkItemLifecycle.FAILED)
                    }
                }
            }
        }
    }

    /**
     * Read-only offline ledger mirror import.
     * Deduplicates by event.id when canonical content matches, rejects conflicts atomically with
     * DialogueConflict("ledger_event_conflict"), appends a deterministic ledger_imported audit event,
     * and never mutates historical run ownership or work-item epoch/lifecycle state.
     */
    fun importLedgerEvents(ledgerId: String, events: List<DialogueEvent>): LedgerImportResult = transaction {
        require(ledgerId.isNotBlank() && ledgerId.length <= 128) { "invalid_ledger_id" }
        var imported = 0
        var duplicated = 0
        for (rawEvent in events) {
            require(rawEvent.id.isNotBlank()) { "invalid_event_id" }
            val normalized = rawEvent.copy(seq = 0L, ledgerId = rawEvent.ledgerId ?: ledgerId)
            val existingPayload = db.prepare("SELECT payload FROM dialogue_events WHERE id=?").use {
                it.bindText(1, normalized.id)
                if (it.step()) it.getText(0) else null
            }
            if (existingPayload != null) {
                val existing = json.decodeFromString<DialogueEvent>(existingPayload)
                val canonicalExisting = existing.copy(seq = 0L, ledgerId = existing.ledgerId ?: normalized.ledgerId)
                val canonicalIncoming = normalized.copy(seq = 0L, ledgerId = normalized.ledgerId ?: existing.ledgerId)
                if (canonicalExisting != canonicalIncoming) {
                    throw DialogueConflict("ledger_event_conflict")
                }
                duplicated += 1
            } else {
                appendEventRawLocked(normalized)
                imported += 1
            }
        }
        val batchKey = "$ledgerId\u0000" + events.joinToString("\u0000") { it.id }
        val auditEventId = "ledger_imported:$ledgerId:${OrchestrationHash.sha256Hex(batchKey).take(16)}"
        val distinctWorkItems = events.mapNotNull { it.workItemId }.distinct()
        val distinctConversations = events.mapNotNull { it.conversationId }.distinct()
        val topicId = events.firstOrNull()?.topicId ?: ledgerId
        appendEventRawLocked(
            DialogueEvent(
                id = auditEventId,
                kind = DialogueEventKinds.LEDGER_IMPORTED,
                role = "system",
                text = "已镜像导入离线账本 $ledgerId（新增 $imported 条，去重 $duplicated 条）",
                topicId = topicId,
                workItemId = distinctWorkItems.singleOrNull(),
                conversationId = distinctConversations.singleOrNull(),
                ledgerId = ledgerId,
            )
        )
        LedgerImportResult(
            ledgerId = ledgerId,
            importedCount = imported,
            duplicateCount = duplicated,
            auditEventId = auditEventId,
        )
    }

    fun page(after: Long, limit: Int, legacyClient: Boolean = false): DialoguePage = synchronized(lock) {
        require(after >= 0 && limit in 1..100)
        // Filter before LIMIT. A legacy client never advances its cursor for an empty page.
        val visible = if (legacyClient) """
            AND json_extract(e.payload,'$.kind') IN ('user_message','followup','stop_requested','assistant_reply',
                'input_consumed','input_cancelled','process_event','task_result')
            AND (json_extract(e.payload,'$.kind') <> 'stop_requested' OR (
                NOT EXISTS (SELECT 1 FROM dialogue_inputs i WHERE i.id=e.id AND json_extract(i.payload,'$.closedOnArrival')=1)
                AND NOT EXISTS (SELECT 1 FROM dialogue_events late WHERE json_extract(late.payload,'$.kind')='stop_too_late'
                    AND json_extract(late.payload,'$.causedByInputId')=e.id)
            ))
        """ else ""
        val items = db.prepare("SELECT e.seq,e.payload FROM dialogue_events e WHERE e.seq>? $visible ORDER BY e.seq LIMIT ?").use {
            it.bindLong(1, after); it.bindLong(2, limit.toLong())
            buildList { while (it.step()) add(json.decodeFromString<DialogueEvent>(it.getText(1)).copy(seq = it.getLong(0))) }
        }
        DialoguePage(items, items.lastOrNull()?.seq ?: after)
    }

    fun plan(id: String): RouterDecision? = synchronized(lock) {
        db.prepare("SELECT payload FROM dialogue_plans WHERE id=?").use { it.bindText(1, id); if (it.step()) json.decodeFromString<RouterDecision>(it.getText(0)) else null }
    }
    fun savePlan(id: String, decision: RouterDecision, inputIds: List<String> = emptyList()) = transaction {
        db.prepare("INSERT OR IGNORE INTO dialogue_plans(id,payload) VALUES(?,?)").use { it.bindText(1, id); it.bindText(2, json.encodeToString(decision)); it.step() }
        // Freeze membership with the decision: recovery must not merge a decided turn with newer inputs.
        inputIds.forEach { inputId ->
            val input = input(inputId) ?: error("Missing Router input: $inputId")
            db.prepare("UPDATE dialogue_inputs SET payload=? WHERE id=?").use {
                it.bindText(1, json.encodeToString(input.copy(routerPlanId = id))); it.bindText(2, inputId); it.step()
            }
        }
    }

    fun processStarted(id: String, owner: String, pid: Long, startedAtMs: Long) = synchronized(lock) {
        db.prepare("INSERT INTO task_processes(id,owner,pid,started_ms) VALUES(?,?,?,?)").use {
            it.bindText(1, id); it.bindText(2, owner); it.bindLong(3, pid); it.bindLong(4, startedAtMs); it.step()
        }
    }

    fun runningProcesses(): List<RecordedTaskProcess> = synchronized(lock) {
        db.prepare("SELECT id,owner,pid,started_ms FROM task_processes WHERE finished=0").use {
            buildList { while (it.step()) add(RecordedTaskProcess(it.getText(0), it.getText(1), it.getLong(2), it.getLong(3))) }
        }
    }

    fun processFinished(id: String, owner: String, topic: String, text: String): Unit = transaction {
        db.prepare("UPDATE task_processes SET finished=1 WHERE id=?").use { it.bindText(1, id); it.step() }
        val eventId = UUID.nameUUIDFromBytes("process:$id".toByteArray()).toString()
        val safe = CredentialRedactor.redact(text)
        insertInput(DialogueInput(eventId, "system", id, "process", safe, topic, owner), id)
        // Model inbox retains bounded output; the public timeline exposes only human-readable activity.
        appendEventRawLocked(DialogueEvent("process:$id", DialogueEventKinds.PROCESS_EVENT, "system", "后台执行状态已更新", topic, owner))
    }
}
