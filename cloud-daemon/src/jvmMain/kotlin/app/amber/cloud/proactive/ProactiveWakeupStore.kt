package app.amber.cloud.proactive

import app.amber.cloud.security.CredentialRedactor
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID

/**
 * 主动自唤醒记录（snooze / agent / commitment 共用，冻结契约 §4.2）。
 * 持久化于 `dataDir/proactive/wakeups.json`（0600 原子写）。
 */
@Serializable
data class ProactiveWakeupRecord(
    val id: String,
    val kind: String,
    val title: String,
    val detail: String = "",
    val checkPrompt: String? = null,
    val triggerAtEpochMs: Long,
    val userRequested: Boolean = false,
    val originSignalId: String? = null,
    val sourceConversationId: String? = null,
    val status: String = STATUS_PENDING,
    val createdAtEpochMs: Long,
    val firedAtEpochMs: Long? = null,
) {
    companion object {
        const val KIND_SNOOZE = "snooze"
        const val KIND_AGENT = "agent"
        const val KIND_COMMITMENT = "commitment"

        const val STATUS_PENDING = "pending"
        const val STATUS_FIRED = "fired"
        const val STATUS_CANCELLED = "cancelled"
        const val STATUS_EXPIRED = "expired"
    }
}

/**
 * 自唤醒持久化仓库（`@Synchronized` 线程安全，0600 原子写）。
 */
class ProactiveWakeupStore(proactiveDir: File) {
    data class DuePartition(
        val due: List<ProactiveWakeupRecord>,
        val expired: List<ProactiveWakeupRecord>,
    )

    private val file = File(proactiveDir, "wakeups.json")
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true; encodeDefaults = true }
    private val records = LinkedHashMap<String, ProactiveWakeupRecord>()

    init {
        ProactiveFilePersistence.ensureOwnerOnlyDir(proactiveDir)
        loadFromDisk()
    }

    @Synchronized
    fun get(id: String): ProactiveWakeupRecord? = records[id]

    @Synchronized
    fun listPending(): List<ProactiveWakeupRecord> = records.values
        .filter { it.status == ProactiveWakeupRecord.STATUS_PENDING }
        .sortedBy { it.triggerAtEpochMs }

    @Synchronized
    fun listAll(): List<ProactiveWakeupRecord> = records.values.toList()

    /**
     * 为单张主动卡片创建或幂等更新确定性 snooze 唤醒（id 由 `originSignalId` 确定性派生）。
     */
    @Synchronized
    fun upsertSnooze(
        originSignalId: String,
        title: String,
        detail: String = "",
        checkPrompt: String? = null,
        triggerAtEpochMs: Long,
        nowEpochMs: Long = System.currentTimeMillis(),
    ): ProactiveWakeupRecord {
        val cleanOrigin = originSignalId.trim()
        require(cleanOrigin.isNotEmpty()) { "originSignalId 不能为空" }
        val id = deterministicSnoozeId(cleanOrigin)
        val existing = records[id]
        if (existing == null || existing.status != ProactiveWakeupRecord.STATUS_PENDING) {
            val pendingCount = records.values.count { it.status == ProactiveWakeupRecord.STATUS_PENDING }
            require(pendingCount < MAX_PENDING) { "待触发提醒已达上限 ($MAX_PENDING)" }
        }
        val safeTitle = CredentialRedactor.redact(title.trim()).take(100).ifBlank { "延后提醒" }
        val safeDetail = CredentialRedactor.redact(detail.trim()).take(1_000)
        val safeCheckPrompt = checkPrompt
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { CredentialRedactor.redact(it).take(2_000) }

        val record = ProactiveWakeupRecord(
            id = id,
            kind = ProactiveWakeupRecord.KIND_SNOOZE,
            title = safeTitle,
            detail = safeDetail,
            checkPrompt = safeCheckPrompt,
            triggerAtEpochMs = triggerAtEpochMs,
            userRequested = true,
            originSignalId = cleanOrigin,
            sourceConversationId = null,
            status = ProactiveWakeupRecord.STATUS_PENDING,
            createdAtEpochMs = nowEpochMs,
            firedAtEpochMs = null,
        )
        records[id] = record
        pruneHistoryLocked()
        persistToDisk()
        return record
    }

    @Synchronized
    fun create(
        kind: String,
        title: String,
        detail: String = "",
        checkPrompt: String? = null,
        triggerAtEpochMs: Long,
        userRequested: Boolean = false,
        originSignalId: String? = null,
        sourceConversationId: String? = null,
        nowEpochMs: Long = System.currentTimeMillis(),
        customId: String? = null,
    ): ProactiveWakeupRecord {
        require(kind in VALID_KINDS) { "非法的唤醒类型: $kind" }
        val id = customId?.trim()?.takeIf { it.isNotEmpty() }
            ?: ("wk" + UUID.randomUUID().toString().replace("-", "").take(10))
        require(ID_REGEX.matches(id)) { "非法的唤醒 id" }
        val existing = records[id]
        if (existing == null || existing.status != ProactiveWakeupRecord.STATUS_PENDING) {
            val pendingCount = records.values.count { it.status == ProactiveWakeupRecord.STATUS_PENDING }
            require(pendingCount < MAX_PENDING) { "待触发提醒已达上限 ($MAX_PENDING)" }
        }
        val safeTitle = CredentialRedactor.redact(title.trim()).take(100).ifBlank { "定时提醒" }
        val safeDetail = CredentialRedactor.redact(detail.trim()).take(1_000)
        val safeCheckPrompt = checkPrompt
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { CredentialRedactor.redact(it).take(2_000) }

        val record = ProactiveWakeupRecord(
            id = id,
            kind = kind,
            title = safeTitle,
            detail = safeDetail,
            checkPrompt = safeCheckPrompt,
            triggerAtEpochMs = triggerAtEpochMs,
            userRequested = userRequested,
            originSignalId = originSignalId?.trim()?.takeIf { it.isNotEmpty() },
            sourceConversationId = sourceConversationId?.trim()?.takeIf { it.isNotEmpty() },
            status = ProactiveWakeupRecord.STATUS_PENDING,
            createdAtEpochMs = nowEpochMs,
            firedAtEpochMs = null,
        )
        records[id] = record
        pruneHistoryLocked()
        persistToDisk()
        return record
    }

    /**
     * 筛选所有已到期（`triggerAtEpochMs <= nowEpochMs`）的 pending 唤醒：
     * - 逾期 `<= overdueLimitMs`（默认 12h）：返回 [DuePartition.due] 供补发；
     * - 逾期 `> overdueLimitMs`：立即标记为 `expired` 落盘，并返回 [DuePartition.expired] 供写入 Pulse 缓冲与历史。
     */
    @Synchronized
    fun findDueAndExpireOverdue(
        nowEpochMs: Long,
        overdueLimitMs: Long = OVERDUE_LIMIT_MS,
    ): DuePartition {
        val due = mutableListOf<ProactiveWakeupRecord>()
        val expired = mutableListOf<ProactiveWakeupRecord>()
        var dirty = false
        for (record in records.values.toList().sortedBy { it.triggerAtEpochMs }) {
            if (record.status != ProactiveWakeupRecord.STATUS_PENDING) continue
            if (record.triggerAtEpochMs > nowEpochMs) continue
            val overdueMs = nowEpochMs - record.triggerAtEpochMs
            if (overdueMs > overdueLimitMs) {
                val updated = record.copy(status = ProactiveWakeupRecord.STATUS_EXPIRED)
                records[record.id] = updated
                expired.add(updated)
                dirty = true
            } else {
                due.add(record)
            }
        }
        if (dirty) {
            pruneHistoryLocked()
            persistToDisk()
        }
        return DuePartition(due = due, expired = expired)
    }

    @Synchronized
    fun markFired(id: String, firedAtEpochMs: Long = System.currentTimeMillis()): ProactiveWakeupRecord? {
        val existing = records[id] ?: return null
        if (existing.status != ProactiveWakeupRecord.STATUS_PENDING) return existing
        val updated = existing.copy(
            status = ProactiveWakeupRecord.STATUS_FIRED,
            firedAtEpochMs = firedAtEpochMs,
        )
        records[id] = updated
        pruneHistoryLocked()
        persistToDisk()
        return updated
    }

    @Synchronized
    fun cancel(id: String): Boolean {
        val existing = records[id] ?: return false
        if (existing.status != ProactiveWakeupRecord.STATUS_PENDING) return false
        records[id] = existing.copy(status = ProactiveWakeupRecord.STATUS_CANCELLED)
        pruneHistoryLocked()
        persistToDisk()
        return true
    }

    private fun pruneHistoryLocked() {
        val terminal = records.values.filter { it.status != ProactiveWakeupRecord.STATUS_PENDING }
        if (terminal.size <= MAX_TERMINAL_HISTORY) return
        val toDrop = terminal
            .sortedBy { it.firedAtEpochMs ?: it.createdAtEpochMs }
            .take(terminal.size - MAX_TERMINAL_HISTORY)
        for (item in toDrop) {
            records.remove(item.id)
        }
    }

    private fun loadFromDisk() {
        if (!file.isFile) return
        val loaded = runCatching {
            json.decodeFromString<List<ProactiveWakeupRecord>>(file.readText())
        }.getOrNull() ?: return
        records.clear()
        for (r in loaded) {
            records[r.id] = r
        }
    }

    private fun persistToDisk() {
        ProactiveFilePersistence.atomicWrite0600(file, json.encodeToString(records.values.toList()))
    }

    companion object {
        const val MAX_PENDING = 50
        const val MAX_TERMINAL_HISTORY = 200
        const val OVERDUE_LIMIT_MS = 12 * 3_600_000L

        private val VALID_KINDS = setOf(
            ProactiveWakeupRecord.KIND_SNOOZE,
            ProactiveWakeupRecord.KIND_AGENT,
            ProactiveWakeupRecord.KIND_COMMITMENT,
        )
        private val ID_REGEX = Regex("^[A-Za-z0-9_-]{1,32}$")

        fun deterministicSnoozeId(originSignalId: String): String =
            "wk" + L1DeterministicFilter.sha256Hex("snooze:$originSignalId").take(10)

        fun signalIdFor(record: ProactiveWakeupRecord): String {
            val epochMin = (record.triggerAtEpochMs / 60_000L).coerceAtLeast(0L)
            return "wk_${record.id}_$epochMin".take(48)
        }
    }
}
