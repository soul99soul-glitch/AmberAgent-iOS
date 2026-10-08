package app.amber.core.memory.model

import app.amber.core.model.AssistantMemory
import app.amber.core.settings.IosSettingsDefaults
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlin.time.Clock

/**
 * iOS memory store — provides read/write access to memory records.
 *
 * [Slice 6] Persistence: a Swift wrapper (IOSMemoryPersistence) serializes
 * [snapshotRecords] to Documents/memories/memories.json on explicit
 * `persist(previousRecords:)` calls made by each mutator; on app startup it
 * loads that file and calls [replaceAll] to seed the store. The KMP side stays
 * platform-agnostic (pure in-memory StateFlow); file IO lives in Swift where
 * Foundation interop is native.
 *
 * HONESTY: Persistence is real (JSON file via Swift NSFileManager, atomic
 * write). The seed data comes from IosSettingsDefaults when no persisted file
 * exists. This is the iOS-local persistence layer for memories — same role as
 * the Android Room MemoryRepository, but file-based.
 */
object IosMemoryFactory {

    private val _records = MutableStateFlow<List<MemoryRecord>>(seedRecords())
    val recordsFlow: StateFlow<List<MemoryRecord>> = _records

    private var nextId = (_records.value.maxOfOrNull { it.id } ?: 999) + 1

    fun getAllRecords(): List<MemoryRecord> = _records.value

    fun addMemory(
        scope: MemoryScope,
        kind: MemoryKind,
        content: String,
        assistantId: String = bucketForScope(scope),
    ): MemoryRecord = addDetailedMemory(
        scope = scope,
        kind = kind,
        content = content,
        assistantId = assistantId,
        sourceConversationId = null,
        sourceMessageIds = emptyList(),
        supersedesIds = emptyList(),
        expiresAt = null,
        confidence = 1f,
        pinned = false,
        archived = false,
    )

    fun addDetailedMemory(
        scope: MemoryScope,
        kind: MemoryKind,
        content: String,
        assistantId: String = bucketForScope(scope),
        sourceConversationId: String? = null,
        sourceMessageIds: List<String> = emptyList(),
        supersedesIds: List<Int> = emptyList(),
        expiresAt: Long? = null,
        confidence: Float = 1f,
        pinned: Boolean = false,
        archived: Boolean = false,
    ): MemoryRecord {
        val now = Clock.System.now().toEpochMilliseconds()
        val record = MemoryRecord(
            id = nextId++,
            content = content,
            scope = scope,
            kind = kind,
            assistantId = assistantId,
            sourceConversationId = sourceConversationId,
            sourceMessageIds = sourceMessageIds,
            supersedesIds = supersedesIds,
            expiresAt = expiresAt,
            confidence = confidence,
            pinned = pinned,
            archived = archived,
            createdAt = now,
            updatedAt = now,
            lastUsedAt = now,
        )
        _records.value = _records.value + record
        return record
    }

    fun addSimpleMemory(assistantId: String, content: String): AssistantMemory {
        val scope = scopeForBucket(assistantId)
        val kind = if (scope == MemoryScope.SHORT_TERM) MemoryKind.PROJECT else MemoryKind.NOTE
        val record = addMemory(scope = scope, kind = kind, content = content, assistantId = assistantId)
        return record.toAssistantMemory()
    }

    fun updateContent(id: Int, content: String): AssistantMemory? {
        val records = _records.value.toMutableList()
        val index = records.indexOfFirst { it.id == id }
        if (index < 0) return null
        // Topic summaries are owned by the consolidation pass, not this path.
        if (records[index].kind == MemoryKind.TOPIC) return null
        val updated = records[index].copy(content = content, updatedAt = Clock.System.now().toEpochMilliseconds())
        records[index] = updated
        _records.value = records
        return updated.toAssistantMemory()
    }

    fun updateRecord(record: MemoryRecord): MemoryRecord? {
        val records = _records.value.toMutableList()
        val index = records.indexOfFirst { it.id == record.id }
        if (index < 0) return null
        records[index] = record
        _records.value = records
        // Only ever advance: deleting the current max-id record must not let a
        // later update pull nextId backwards and reuse a deleted id.
        nextId = maxOf(nextId, (records.maxOfOrNull { it.id } ?: 999) + 1)
        return record
    }

    /** Updates usage metadata only; content/update timestamps remain unchanged. */
    fun touchMemories(ids: List<Int>, timestamp: Long) {
        if (ids.isEmpty()) return
        val wanted = ids.toSet()
        _records.value = _records.value.map { record ->
            if (record.id in wanted) record.copy(lastUsedAt = timestamp) else record
        }
    }

    /**
     * Marks explicit reinforcement (model citation or user restatement): sets
     * both [MemoryRecord.lastUsedAt] and [MemoryRecord.lastReinforcedAt].
     * Content/update timestamps remain unchanged, same as [touchMemories].
     */
    fun reinforceMemories(ids: List<Int>, timestamp: Long) {
        if (ids.isEmpty()) return
        val wanted = ids.toSet()
        _records.value = _records.value.map { record ->
            if (record.id in wanted) {
                record.copy(lastUsedAt = timestamp, lastReinforcedAt = timestamp)
            } else {
                record
            }
        }
    }

    fun deleteMemory(id: Int) {
        _records.value = _records.value
            .map { record ->
                if (record.kind == MemoryKind.TOPIC && record.memberIds.contains(id)) {
                    record.copy(memberIds = record.memberIds - id)
                } else {
                    record
                }
            }
            .filterNot { it.id == id }
    }

    /**
     * Points topic memberships at a new version of a superseded record, keeping
     * each topic's member order. Topics that don't contain [oldId] are untouched.
     */
    fun replaceTopicMember(oldId: Int, newId: Int) {
        val now = Clock.System.now().toEpochMilliseconds()
        _records.value = _records.value.map { record ->
            if (record.kind == MemoryKind.TOPIC && oldId in record.memberIds) {
                record.copy(
                    memberIds = record.memberIds.map { if (it == oldId) newId else it }.distinct(),
                    updatedAt = now,
                )
            } else {
                record
            }
        }
    }

    /**
     * Folds a confirmed same-meaning duplicate into [winnerId]: the loser is
     * archived (restorable, unlike exact-duplicate deletion), the winner
     * records it in supersedesIds and inherits its provenance and strongest
     * usage signals, and topic memberships move to the winner. The winner keeps
     * its own createdAt (its wording is what gets shown as recorded then); it
     * stays permanent if either side was. Returns false
     * (and changes nothing) unless both are live, distinct atomic records.
     */
    fun mergeNearDuplicate(winnerId: Int, loserId: Int, now: Long): Boolean {
        if (winnerId == loserId) return false
        val records = _records.value
        val winner = records.firstOrNull { it.id == winnerId } ?: return false
        val loser = records.firstOrNull { it.id == loserId } ?: return false
        if (winner.archived || loser.archived || winner.kind == MemoryKind.TOPIC || loser.kind == MemoryKind.TOPIC) {
            return false
        }
        val merged = winner.copy(
            sourceConversationId = winner.sourceConversationId ?: loser.sourceConversationId,
            sourceMessageIds = (winner.sourceMessageIds + loser.sourceMessageIds).distinct(),
            supersedesIds = (winner.supersedesIds + loser.id + loser.supersedesIds).distinct().sorted(),
            expiresAt = if (winner.expiresAt == null || loser.expiresAt == null) null else maxOf(winner.expiresAt, loser.expiresAt),
            lastUsedAt = listOfNotNull(winner.lastUsedAt, loser.lastUsedAt).maxOrNull(),
            lastReinforcedAt = listOfNotNull(winner.lastReinforcedAt, loser.lastReinforcedAt).maxOrNull(),
            updatedAt = now,
        )
        _records.value = records.map { record ->
            when (record.id) {
                winnerId -> merged
                loserId -> record.copy(archived = true, updatedAt = now)
                else -> record
            }
        }
        replaceTopicMember(oldId = loserId, newId = winnerId)
        return true
    }

    /**
     * User restore of an archived atomic record. An expiry that already passed
     * is cleared — restoring is an explicit "this still holds" — otherwise the
     * next maintenance pass would archive it again. Topics are not restorable
     * here (maintenance owns them). Returns the restored record or null.
     */
    fun restoreMemory(id: Int, now: Long): MemoryRecord? {
        val records = _records.value.toMutableList()
        val index = records.indexOfFirst { it.id == id }
        if (index < 0) return null
        val record = records[index]
        if (record.kind == MemoryKind.TOPIC || !record.archived) return null
        val restored = record.copy(
            archived = false,
            expiresAt = record.expiresAt?.takeIf { it > now },
            updatedAt = now,
        )
        records[index] = restored
        _records.value = records
        return restored
    }

    /** Flip the archived flag; returns the updated record or null. */
    fun setArchived(id: Int, archived: Boolean): MemoryRecord? {
        val records = _records.value.toMutableList()
        val index = records.indexOfFirst { it.id == id }
        if (index < 0) return null
        val updated = records[index].copy(
            archived = archived,
            updatedAt = Clock.System.now().toEpochMilliseconds(),
        )
        records[index] = updated
        _records.value = records
        return updated
    }

    /**
     * Idempotent topic upsert keyed by the normalized title: an existing TOPIC
     * record with the same normalized title is updated in place (summary +
     * member union, reviving an archived topic that maintenance retired),
     * otherwise a new TOPIC record is created. Member ids are stored
     * de-duplicated in the caller's order appended to existing members; callers
     * filter out archived/topic/missing ids beforehand. Returns null when the
     * title normalizes to empty or the suggestion changes nothing, so callers
     * can skip a redundant persist.
     */
    fun upsertTopicRecord(title: String, summary: String, memberIds: List<Int>): MemoryRecord? {
        val normalized = normalizeTopicTitle(title)
        if (normalized.isEmpty()) return null
        val now = Clock.System.now().toEpochMilliseconds()
        val existing = _records.value.firstOrNull {
            it.kind == MemoryKind.TOPIC && normalizeTopicTitle(it.topicTitle ?: "") == normalized
        }
        if (existing != null) {
            val members = (existing.memberIds + memberIds).distinct()
            if (!existing.archived && existing.content == summary && existing.memberIds == members) {
                return null
            }
            val updated = existing.copy(
                content = summary,
                memberIds = members,
                archived = false,
                updatedAt = now,
            )
            updateRecord(updated)
            return updated
        }
        val members = memberIds.distinct()
        return addDetailedMemory(
            scope = MemoryScope.LONG_TERM,
            kind = MemoryKind.TOPIC,
            content = summary,
            assistantId = LONG_TERM_MEMORY_ID,
            sourceConversationId = null,
            sourceMessageIds = emptyList(),
            supersedesIds = emptyList(),
            expiresAt = null,
            confidence = 1f,
            pinned = false,
            archived = false,
        ).let { created ->
            updateRecord(created.copy(topicTitle = title.trim(), memberIds = members)) ?: created
        }
    }

    /** Topic titles match case-insensitively and ignore whitespace entirely. */
    fun normalizeTopicTitle(title: String): String =
        title.filterNot { it.isWhitespace() }.lowercase()

    fun getMemoriesOfAssistant(assistantId: String): List<AssistantMemory> =
        _records.value.filter { it.assistantId == assistantId }.map { it.toAssistantMemory() }

    fun getGlobalMemories(): List<AssistantMemory> = getMemoriesOfAssistant(GLOBAL_MEMORY_ID)
    fun getShortTermMemories(): List<AssistantMemory> = getMemoriesOfAssistant(SHORT_TERM_MEMORY_ID)
    fun getLongTermMemories(): List<AssistantMemory> = getMemoriesOfAssistant(LONG_TERM_MEMORY_ID)

    // ---------- Persistence hooks (Slice 6, driven by Swift wrapper) ----------

    /**
     * Replace all records with [records]. Called once at app startup by the
     * Swift IOSMemoryPersistence wrapper after it loads
     * Documents/memories/memories.json. Resets nextId above the highest id.
     */
    fun replaceAll(records: List<MemoryRecord>) {
        _records.value = records
        nextId = (records.maxOfOrNull { it.id } ?: 999) + 1
    }

    /**
     * Snapshot for the Swift wrapper to serialize. Returns the current records
     * so Swift can JSON-encode + write the file (Swift's Codable/JSONEncoder is
     * cleaner than K/N Foundation interop for this).
     */
    fun snapshotRecords(): List<MemoryRecord> = _records.value

    // ---------- Constants (mirror Android MemoryRepository) ----------

    const val GLOBAL_MEMORY_ID = "__global__"
    const val SHORT_TERM_MEMORY_ID = "__short_term__"
    const val LONG_TERM_MEMORY_ID = "__long_term__"

    // ---------- Seed ----------

    private fun seedRecords(): List<MemoryRecord> {
        // No memory records in the seed Settings snapshot (memories live in Room DB,
        // not in Settings). iOS starts with an empty store; addMemory populates it
        // and the Swift wrapper persists it to disk for next launch.
        return emptyList()
    }

    private fun scopeForBucket(assistantId: String): MemoryScope = when (assistantId) {
        GLOBAL_MEMORY_ID -> MemoryScope.CORE
        SHORT_TERM_MEMORY_ID -> MemoryScope.SHORT_TERM
        LONG_TERM_MEMORY_ID -> MemoryScope.LONG_TERM
        else -> MemoryScope.LONG_TERM
    }

    private fun bucketForScope(scope: MemoryScope): String = when (scope) {
        MemoryScope.CORE -> GLOBAL_MEMORY_ID
        MemoryScope.SHORT_TERM -> SHORT_TERM_MEMORY_ID
        MemoryScope.LONG_TERM -> LONG_TERM_MEMORY_ID
    }

    private fun MemoryRecord.toAssistantMemory() = AssistantMemory(
        id = id,
        content = content,
        scope = scope,
        kind = kind,
        expiresAt = expiresAt,
        confidence = confidence,
        pinned = pinned,
        archived = archived,
    )
}
