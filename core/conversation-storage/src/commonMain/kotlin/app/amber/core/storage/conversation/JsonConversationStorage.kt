package app.amber.core.storage.conversation

import app.amber.core.agent.utils.JsonInstant
import app.amber.core.model.Conversation
import app.amber.core.model.ConversationMemoryMode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlin.uuid.Uuid

private val SUMMARY_STORAGE_JSON: Json = JsonInstant

class ConversationStorageException(
    message: String,
    cause: Throwable? = null,
) : IllegalStateException(message, cause)

/**
 * 文件 JSON 持久化的实现。目录布局（PLAN_CONVERSATION_PERSISTENCE.md 已定）：
 *
 *   {baseDir}/index.json          # List<ConversationSummary>，派生缓存
 *   {baseDir}/{conversationId}.json   # 完整 Conversation
 *
 * 写策略：每个 save/delete 同时落 {id}.json 与 index.json；index 损坏可从
 * 所有 {id}.json 扫描重建（[rebuildIndex]）。
 *
 * `baseDir` 由构造方传入（iOS 传 NSDocumentDirectory/conversations，JVM 传
 * 临时目录用于测试）。
 *
 * ## 并发契约（重要）
 * 文件与 index 的读改写窗口由 [operationMutex] 串行化。`saveConversation` 是消息树写入口：
 * 对已存在会话会保留 metadata owner 字段（title/isPinned），避免旧消息快照反向覆盖
 * `updateMetadata` 的结果。
 */
class JsonConversationStorage(
    private val baseDir: ConversationFile,
) : ConversationStorageInterface {

    private val operationMutex = Mutex()
    private val indexFile: ConversationFile get() = baseDir.child(INDEX_FILENAME)
    private val summaryCache = mutableMapOf<String, SummaryCacheEntry>()
    /**
     * Recent complete snapshots avoid decoding the same conversation again when the user
     * switches away and back. Keep this intentionally small: the current conversation is
     * already owned by IOSConversationStore, so this is only a short recency window.
     */
    private val conversationCache = LinkedHashMap<String, ConversationCacheEntry>()

    internal var beforeUpdateMetadataSaveForTesting: (suspend () -> Unit)? = null
    internal var beforeSummaryDecodeForTesting: (() -> Unit)? = null
    internal var beforeConversationDecodeForTesting: (() -> Unit)? = null

    init {
        // 确保目录存在；不存在则静默创建（首次启动/全新安装场景）。
        baseDir.mkdirs()
    }

    @Throws(Throwable::class)
    override suspend fun listSummaries(): List<ConversationSummary> = operationMutex.withLock {
        // File IO and JSON decoding are synchronous in ConversationFile/serialization.
        // Keep the mutex across the dispatcher hop so summary reads cannot overlap
        // writes or observe a partially replaced conversation file.
        withContext(Dispatchers.Default) {
            ensureBaseDir()
            val cached = readIndex()
            if (cached != null) {
                // index.json is a derived cache. A delete can remove the conversation
                // file before an index write fails, so never surface entries without
                // a backing file and repair that stale cache opportunistically.
                val repaired = readConversationFileSummaries()
                if (repaired.size != cached.size ||
                    repaired.associateBy { it.id } != cached.associateBy { it.id }
                ) {
                    runCatching { writeIndex(repaired) }
                }
                return@withContext orderSummaries(repaired)
            }
            // index 损坏或缺失：从 {id}.json 扫描重建。
            val rebuilt = rebuildIndex()
            orderSummaries(rebuilt)
        }
    }

    @Throws(Throwable::class)
    override suspend fun loadConversation(id: Uuid): Conversation? = operationMutex.withLock {
        // File IO and JSON decoding are synchronous in ConversationFile/serialization.
        // Keep the mutex across the dispatcher hop so reads cannot overlap writes or
        // observe a partially replaced conversation file.
        withContext(Dispatchers.Default) {
            loadConversationUnlocked(id)
        }
    }

    private fun loadConversationUnlocked(id: Uuid): Conversation? {
        ensureBaseDir()
        val file = conversationFile(id)
        val before = file.fileVersion()
        if (before != null) {
            conversationCache[file.path]?.takeIf { it.version == before }?.let {
                // LinkedHashMap insertion order is the recency order for this tiny LRU.
                conversationCache.remove(file.path)
                conversationCache[file.path] = it
                return it.conversation
            }
        } else {
            // If the platform cannot provide a safe fingerprint, never reuse a snapshot.
            conversationCache.remove(file.path)
        }
        val text = file.readText() ?: run {
            conversationCache.remove(file.path)
            return null
        }
        val conversation = runCatching {
            beforeConversationDecodeForTesting?.invoke()
            JsonInstant.decodeFromString<Conversation>(text)
        }.getOrElse {
            // 单条会话损坏不应让整个列表崩；返回 null 让上层视为「不存在」。
            // 损坏文件可由用户在 Phase 3 UI 上删除恢复。
            null
        }
        if (conversation != null && before != null && before == file.fileVersion()) {
            conversationCache.remove(file.path)
            conversationCache[file.path] = ConversationCacheEntry(before, conversation)
            while (conversationCache.size > MAX_CONVERSATION_CACHE_ENTRIES) {
                conversationCache.entries.iterator().next().let { eldest ->
                    conversationCache.remove(eldest.key)
                }
            }
        } else {
            conversationCache.remove(file.path)
        }
        return conversation
    }

    @Throws(Throwable::class)
    override suspend fun saveConversation(conversation: Conversation): Conversation = operationMutex.withLock {
        saveConversationLocked(conversation)
    }

    private fun saveConversationLocked(conversation: Conversation): Conversation {
        ensureBaseDir()
        val conversationToSave = mergeMessageWriteWithExistingMetadata(conversation)
        saveConversationReplacingAllFieldsLocked(conversationToSave)
        return conversationToSave
    }

    private fun saveConversationReplacingAllFieldsLocked(conversationToSave: Conversation) {
        val text = encodeConversation(conversationToSave)
        conversationFile(conversationToSave.id).writeText(text)
        // The file is now the source of truth; do not let a pre-write snapshot survive it.
        conversationCache.remove(conversationFile(conversationToSave.id).path)
        // The conversation file is canonical; index.json is a derived cache and
        // must not turn an already-committed message write into a false failure.
        runCatching { upsertIndex(conversationToSave.toSummary()) }
    }

    @Throws(Throwable::class)
    override suspend fun importConversations(serializedConversations: List<String>) = operationMutex.withLock {
        ensureBaseDir()
        val validated = serializedConversations.mapIndexed { index, text ->
            val conversation = runCatching {
                JsonInstant.decodeFromString<Conversation>(text)
            }.getOrElse {
                throw ConversationStorageException("Failed to decode conversation import at index $index", it)
            }
            conversation to encodeConversation(conversation)
        }

        // Clear before writing so a partial write failure cannot leave a stale decoded
        // snapshot for any document that was already replaced in this batch.
        conversationCache.clear()
        validated.forEach { (conversation, text) ->
            conversationFile(conversation.id).writeText(text)
        }
        rebuildIndex()
        Unit
    }

    private fun encodeConversation(conversation: Conversation): String = runCatching {
        JsonInstant.encodeToString(conversation)
    }.getOrElse {
        throw ConversationStorageException(
            "Failed to encode conversation ${conversation.id} for storage",
            it,
        )
    }

    private fun mergeMessageWriteWithExistingMetadata(incoming: Conversation): Conversation {
        val existing = loadConversationUnlocked(incoming.id) ?: return incoming
        val title = if (existing.title.isEmpty()) incoming.title else existing.title
        if (title == incoming.title
            && existing.chatSuggestions == incoming.chatSuggestions
            && existing.isPinned == incoming.isPinned
            && existing.autoApproveToolCalls == incoming.autoApproveToolCalls
            && existing.memoryMode == incoming.memoryMode
        ) {
            return incoming
        }
        return incoming.copy(
            title = title,
            chatSuggestions = existing.chatSuggestions,
            isPinned = existing.isPinned,
            autoApproveToolCalls = existing.autoApproveToolCalls,
            // P2-a：POLLUTED 由 harness/用户显式写者拥有，旧消息快照回写不得把它
            // 降级回 ENABLED（只升不降）。见 MemoryPollutionTest。
            memoryMode = if (existing.memoryMode == ConversationMemoryMode.POLLUTED) {
                existing.memoryMode
            } else {
                incoming.memoryMode
            },
        )
    }

    @Throws(Throwable::class)
    override suspend fun deleteConversation(id: Uuid) = operationMutex.withLock {
        ensureBaseDir()
        conversationFile(id).delete()
        conversationCache.remove(conversationFile(id).path)
        removeFromIndex(id)
    }

    @Throws(Throwable::class)
    override suspend fun updateMetadata(id: Uuid, title: String?, isPinned: Boolean?) = operationMutex.withLock {
        val current = loadConversationUnlocked(id) ?: return@withLock
        beforeUpdateMetadataSaveForTesting?.invoke()
        val updated = current.copy(
            title = title ?: current.title,
            isPinned = isPinned ?: current.isPinned,
        )
        saveConversationReplacingAllFieldsLocked(updated)
    }

    @Throws(Throwable::class)
    override suspend fun updateTitleIfCurrentTitleMatches(
        id: Uuid,
        title: String,
        expectedTitle: String,
    ): Boolean = operationMutex.withLock {
        val current = loadConversationUnlocked(id) ?: return@withLock false
        if (current.title != expectedTitle) return@withLock false
        beforeUpdateMetadataSaveForTesting?.invoke()
        saveConversationReplacingAllFieldsLocked(current.copy(title = title))
        true
    }

    @Throws(Throwable::class)
    override suspend fun updateMemoryMode(id: Uuid, memoryMode: ConversationMemoryMode): Boolean =
        operationMutex.withLock {
            val current = loadConversationUnlocked(id) ?: return@withLock false
            // 幂等：已是 POLLUTED 时重复置位为空操作（成功返回，不报错不降级）。
            if (memoryMode == ConversationMemoryMode.POLLUTED
                && current.memoryMode == ConversationMemoryMode.POLLUTED
            ) {
                return@withLock true
            }
            // POLLUTED 只升不降（任意非 POLLUTED 态可升级）；POLLUTED 的唯一出口是
            // ENABLED 复位；POLLUTED→DISABLED 被拒（值不变，返回 false），避免把
            //「已污染」静默降级为「用户关闭」；ENABLED↔DISABLED 互转保留（用户开关）。
            val effective = when {
                memoryMode == ConversationMemoryMode.POLLUTED -> ConversationMemoryMode.POLLUTED
                memoryMode == ConversationMemoryMode.DISABLED
                    && current.memoryMode == ConversationMemoryMode.POLLUTED -> return@withLock false
                else -> memoryMode
            }
            saveConversationReplacingAllFieldsLocked(current.copy(memoryMode = effective))
            true
        }

    // ---- 内部：index 维护 ----

    private fun readIndex(): List<ConversationSummary>? {
        val text = indexFile.readText() ?: return null
        return runCatching {
            JsonInstant.decodeFromString<List<ConversationSummary>>(text)
        }.getOrNull()
    }

    private fun writeIndex(summaries: List<ConversationSummary>) {
        val text = runCatching {
            SUMMARY_STORAGE_JSON.encodeToString(summaries)
        }.getOrElse {
            throw ConversationStorageException("Failed to encode conversation index", it)
        }
        indexFile.writeText(text)
    }

    private fun upsertIndex(summary: ConversationSummary) {
        val current = readIndex().orEmpty()
        val without = current.filterNot { it.id == summary.id }
        writeIndex(without + summary)
    }

    private fun removeFromIndex(id: Uuid) {
        val current = readIndex().orEmpty()
        val without = current.filterNot { it.id == id }
        if (without.size != current.size) {
            writeIndex(without)
        }
    }

    /**
     * 扫描 baseDir 下所有 {id}.json，逐个 load 出 Conversation 取摘要。
     * 用于 index 损坏/首次迁移恢复。会顺带把重建结果落盘，避免下次再扫。
     */
    private suspend fun rebuildIndex(): List<ConversationSummary> {
        val summaries = readConversationFileSummaries()
        if (summaries.isNotEmpty()) writeIndex(summaries)
        return summaries
    }

    private fun readConversationFileSummaries(): List<ConversationSummary> {
        val files = baseDir.listFilesByExtension("json")
            .filterNot { it.path.endsWith(INDEX_FILENAME) }
        val currentPaths = files.mapTo(mutableSetOf()) { it.path }
        summaryCache.entries.removeAll { it.key !in currentPaths }
        return files.mapNotNull { file ->
            val before = file.fileVersion()
            if (before != null) {
                summaryCache[file.path]?.takeIf { it.version == before }?.let {
                    return@mapNotNull it.summary
                }
            }

            val text = file.readText()
            val summary = text?.let {
                beforeSummaryDecodeForTesting?.invoke()
                runCatching {
                    JsonInstant.decodeFromString<Conversation>(it)
                }.getOrNull()?.toSummary()
            }
            val after = file.fileVersion()
            if (summary != null && before != null && before == after) {
                summaryCache[file.path] = SummaryCacheEntry(before, summary)
            } else {
                summaryCache.remove(file.path)
            }
            summary
        }
    }

    private data class SummaryCacheEntry(
        val version: ConversationFileVersion,
        val summary: ConversationSummary,
    )

    private data class ConversationCacheEntry(
        val version: ConversationFileVersion,
        val conversation: Conversation,
    )

    // ---- 排序：置顶优先，再按 updateAt 倒序 ----

    private fun orderSummaries(summaries: List<ConversationSummary>): List<ConversationSummary> =
        summaries.sortedWith(
            compareByDescending<ConversationSummary> { it.isPinned }
                .thenByDescending { it.updateAt }
        )

    // ---- 路径助手 ----

    private fun ensureBaseDir() {
        if (!baseDir.mkdirs()) {
            throw ConversationStorageException("Failed to create conversation storage directory: ${baseDir.path}")
        }
    }

    private fun conversationFile(id: Uuid): ConversationFile =
        baseDir.child("${id}.json")

    private companion object {
        const val INDEX_FILENAME = "index.json"
        const val MAX_CONVERSATION_CACHE_ENTRIES = 2
    }
}
