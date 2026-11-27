package app.amber.cloud.proactive

import app.amber.cloud.security.CredentialRedactor
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID
import kotlin.math.abs

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
class ProactiveWakeupStore(
    proactiveDir: File,
    private val zoneIdProvider: () -> ZoneId = { ZoneId.of("Asia/Shanghai") },
) {
    @Serializable
    private data class PersistedWakeupState(
        val version: Int = 1,
        val agentQuotaDay: String? = null,
        val agentCreatedToday: Int = 0,
        val records: List<ProactiveWakeupRecord> = emptyList(),
    )

    data class DuePartition(
        val due: List<ProactiveWakeupRecord>,
        val expired: List<ProactiveWakeupRecord>,
    )

    private val file = File(proactiveDir, "wakeups.json")
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true; encodeDefaults = true }
    private var records = LinkedHashMap<String, ProactiveWakeupRecord>()
    private val processing = mutableSetOf<String>()
    private var agentQuotaDay: LocalDate? = null
    private var agentCreatedToday: Int = 0

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

    @Synchronized
    internal fun claimPending(id: String): Boolean =
        records[id]?.status == ProactiveWakeupRecord.STATUS_PENDING && processing.add(id)

    @Synchronized
    internal fun releaseClaim(id: String) {
        processing.remove(id)
    }

    /**
     * 检查最近 [createdWithinMs]（默认 10 分钟）内同 [sourceConversationId] 下，
     * 是否已有 Agent 工具创建的、触发时间在 `dueAtEpochMs ± triggerToleranceMs`（默认 30 分钟）内的唤醒。
     * 已取消的提醒同样参与去重，以保留用户在抽取期间作出的取消决定。
     * 用于隐式承诺抽取防重。
     */
    @Synchronized
    fun hasRecentAgentWakeupNear(
        sourceConversationId: String,
        dueAtEpochMs: Long,
        nowEpochMs: Long = System.currentTimeMillis(),
        createdWithinMs: Long = COMMITMENT_DEDUP_CREATED_WINDOW_MS,
        triggerToleranceMs: Long = COMMITMENT_DEDUP_TRIGGER_TOLERANCE_MS,
    ): Boolean {
        val cleanConv = sourceConversationId.trim()
        if (cleanConv.isEmpty()) return false
        return records.values.any { record ->
            record.kind == ProactiveWakeupRecord.KIND_AGENT &&
                record.sourceConversationId == cleanConv &&
                (nowEpochMs - record.createdAtEpochMs) in 0L..createdWithinMs &&
                abs(record.triggerAtEpochMs - dueAtEpochMs) <= triggerToleranceMs
        }
    }

    @Synchronized
    fun createExtractedCommitment(
        title: String,
        triggerAtEpochMs: Long,
        userRequested: Boolean,
        sourceConversationId: String,
        nowEpochMs: Long,
    ): ProactiveWakeupRecord? {
        if (hasRecentAgentWakeupNear(sourceConversationId, triggerAtEpochMs, nowEpochMs)) return null
        return create(
            kind = ProactiveWakeupRecord.KIND_COMMITMENT,
            title = title,
            detail = "从对话中记下的待办承诺：$title",
            triggerAtEpochMs = triggerAtEpochMs,
            userRequested = userRequested,
            sourceConversationId = sourceConversationId,
            nowEpochMs = nowEpochMs,
        )
    }

    /**
     * 查询当前本地日期的 Agent 唤醒已创建次数（按 [zoneIdProvider] 计算）。
     */
    @Synchronized
    fun agentCreatedCountForDay(nowEpochMs: Long = System.currentTimeMillis()): Int {
        val today = Instant.ofEpochMilli(nowEpochMs).atZone(zoneIdProvider()).toLocalDate()
        return if (agentQuotaDay == today) agentCreatedToday else 0
    }

    /**
     * 同一卡片重复提交时保留初次选择的时间及状态，包括已取消或已触发的提醒。
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
        records[id]?.let { return it }
        validateTriggerWindow(triggerAtEpochMs = triggerAtEpochMs, nowEpochMs = nowEpochMs)
        require(records.values.count { it.status == ProactiveWakeupRecord.STATUS_PENDING } < MAX_PENDING) {
            "待触发提醒已达上限 ($MAX_PENDING)"
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
        saveChanges(listOf(record))
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
        validateTriggerWindow(triggerAtEpochMs = triggerAtEpochMs, nowEpochMs = nowEpochMs)
        val id = customId?.trim()?.takeIf { it.isNotEmpty() }
            ?: ("wk" + UUID.randomUUID().toString().replace("-", "").take(10))
        require(ID_REGEX.matches(id)) { "非法的唤醒 id" }
        val existing = records[id]
        if (existing == null || existing.status != ProactiveWakeupRecord.STATUS_PENDING) {
            val pendingCount = records.values.count { it.status == ProactiveWakeupRecord.STATUS_PENDING }
            require(pendingCount < MAX_PENDING) { "待触发提醒已达上限 ($MAX_PENDING)" }
        }
        var quotaDay = agentQuotaDay
        var quotaCount = agentCreatedToday
        if (kind == ProactiveWakeupRecord.KIND_AGENT) {
            val today = Instant.ofEpochMilli(nowEpochMs).atZone(zoneIdProvider()).toLocalDate()
            require(quotaDay?.isAfter(today) != true) { "事项属于已结算日期" }
            quotaCount = if (quotaDay == today) quotaCount + 1 else 1
            quotaDay = today
            require(quotaCount <= MAX_AGENT_DAILY_CREATES) {
                "今日 Agent 创建提醒已达上限 ($MAX_AGENT_DAILY_CREATES 次/天)"
            }
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
        saveChanges(listOf(record), quotaDay, quotaCount)
        return record
    }

    /**
     * 筛选所有已到期（`triggerAtEpochMs <= nowEpochMs`）的 pending 唤醒：
     * - 逾期 `<= overdueLimitMs`（默认 12h）：返回 [DuePartition.due] 供补发；
     * - 逾期 `> overdueLimitMs`：先在锁外通过 [onExpired] 写入 Pulse，再持久化终态。
     */
    fun findDueAndExpireOverdue(
        nowEpochMs: Long,
        overdueLimitMs: Long = OVERDUE_LIMIT_MS,
        onExpired: (ProactiveWakeupRecord) -> Unit = {},
    ): DuePartition {
        val due = mutableListOf<ProactiveWakeupRecord>()
        val expired = mutableListOf<ProactiveWakeupRecord>()
        for (record in listPending()) {
            if (record.triggerAtEpochMs > nowEpochMs) break
            val overdueMs = nowEpochMs - record.triggerAtEpochMs
            if (overdueMs > overdueLimitMs) {
                if (!claimPending(record.id)) continue
                try {
                    val updated = record.copy(status = ProactiveWakeupRecord.STATUS_EXPIRED)
                    onExpired(updated)
                    synchronized(this) { saveChanges(listOf(updated)) }
                    expired.add(updated)
                } finally {
                    releaseClaim(record.id)
                }
            } else {
                due.add(record)
            }
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
        saveChanges(listOf(updated))
        return updated
    }

    @Synchronized
    fun cancel(id: String): Boolean {
        val existing = records[id] ?: return false
        if (existing.status != ProactiveWakeupRecord.STATUS_PENDING || id in processing) return false
        saveChanges(listOf(existing.copy(status = ProactiveWakeupRecord.STATUS_CANCELLED)))
        return true
    }

    private fun validateTriggerWindow(triggerAtEpochMs: Long, nowEpochMs: Long) {
        val deltaMs = triggerAtEpochMs - nowEpochMs
        require(deltaMs in MIN_TRIGGER_DELAY_MS..MAX_TRIGGER_DELAY_MS) {
            "触发时间必须在当前时间后 1 分钟至 90 天内"
        }
    }

    private fun loadFromDisk() {
        if (!file.isFile) return
        val raw = runCatching { file.readText() }.getOrNull()?.trim().orEmpty()
        if (raw.isEmpty()) return
        if (raw.startsWith("[")) {
            val legacy = runCatching {
                json.decodeFromString<List<ProactiveWakeupRecord>>(raw)
            }.getOrNull() ?: return
            records.clear()
            for (r in legacy) {
                records[r.id] = r
            }
            return
        }
        val state = runCatching {
            json.decodeFromString<PersistedWakeupState>(raw)
        }.getOrNull() ?: return
        records.clear()
        for (r in state.records) {
            records[r.id] = r
        }
        agentQuotaDay = state.agentQuotaDay?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
        agentCreatedToday = state.agentCreatedToday.coerceAtLeast(0)
    }

    private fun saveChanges(
        updates: List<ProactiveWakeupRecord>,
        quotaDay: LocalDate? = agentQuotaDay,
        quotaCount: Int = agentCreatedToday,
    ) {
        val nextRecords = LinkedHashMap(records)
        for (record in updates) nextRecords[record.id] = record
        val terminal = nextRecords.values.filter { it.status != ProactiveWakeupRecord.STATUS_PENDING }
        if (terminal.size > MAX_TERMINAL_HISTORY) {
            terminal.sortedBy { it.firedAtEpochMs ?: it.createdAtEpochMs }
                .take(terminal.size - MAX_TERMINAL_HISTORY)
                .forEach { nextRecords.remove(it.id) }
        }
        val state = PersistedWakeupState(
            agentQuotaDay = quotaDay?.toString(),
            agentCreatedToday = quotaCount,
            records = nextRecords.values.toList(),
        )
        ProactiveFilePersistence.atomicWrite0600(file, json.encodeToString(state))
        records = nextRecords
        agentQuotaDay = quotaDay
        agentCreatedToday = quotaCount
    }

    companion object {
        const val MAX_PENDING = 50
        const val MAX_AGENT_DAILY_CREATES = 20
        const val MIN_TRIGGER_DELAY_MS = 60_000L
        const val MAX_TRIGGER_DELAY_MS = 90L * 24L * 3_600_000L
        const val COMMITMENT_DEDUP_CREATED_WINDOW_MS = 10L * 60_000L
        const val COMMITMENT_DEDUP_TRIGGER_TOLERANCE_MS = 30L * 60_000L
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
