package app.amber.core.storage.conversation

import app.amber.core.agent.utils.JsonInstant
import app.amber.core.model.Conversation
import app.amber.core.model.ConversationMemoryMode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.time.Clock
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
 *   {baseDir}/summary-cache-v1.cache # 摘要及正文文件指纹，跨进程复用
 *   {baseDir}/{conversationId}.json   # 完整 Conversation（大图 data URL 换成 amber-blob:// 引用）
 *   {baseDir}/{conversationId}.blobs/  # 内容寻址的图片字节，见 ConversationBlobs.kt
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
    private var didLoadSummaryCache = false
    /**
     * Recent complete snapshots avoid decoding the same conversation again when the user
     * switches away and back. Keep this intentionally small: the current conversation is
     * already owned by IOSConversationStore, so this is only a short recency window.
     */
    private val conversationCache = LinkedHashMap<String, ConversationCacheEntry>()
    private val blobCodec = ConversationBlobCodec(baseDir)
    private var didSweepOrphanBlobs = false

    internal var beforeUpdateMetadataSaveForTesting: (suspend () -> Unit)? = null
    internal var beforeSummaryDecodeForTesting: (() -> Unit)? = null
    internal var beforeConversationDecodeForTesting: (() -> Unit)? = null
    internal var beforeImportCommitForTesting: ((Int) -> Unit)? = null

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
            if (!didSweepOrphanBlobs) {
                didSweepOrphanBlobs = true
                runCatching {
                    blobCodec.sweepOrphanDirectories(
                        nowEpochSeconds = Clock.System.now().epochSeconds,
                        minAgeSeconds = ORPHAN_BLOB_DIRECTORY_MIN_AGE_SECONDS,
                    )
                }
            }
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
        val decoded = runCatching {
            beforeConversationDecodeForTesting?.invoke()
            JsonInstant.decodeFromString<Conversation>(text)
        }.getOrElse {
            // 单条会话损坏不应让整个列表崩；返回 null 让上层视为「不存在」。
            // 损坏文件可由用户在 Phase 3 UI 上删除恢复。
            null
        } ?: run {
            conversationCache.remove(file.path)
            return null
        }
        // Upper layers always see inline data URLs; blob references never leave storage.
        val resolved = blobCodec.resolve(decoded)
        // A conversation with an unresolved blob is never cached, so the next load retries
        // the read (a transient failure heals) and saves never prune it (no known disk refs).
        if (!resolved.hadFailures && before != null && before == file.fileVersion()) {
            putCacheEntry(
                file.path,
                ConversationCacheEntry(before, resolved.conversation, resolved.memo, resolved.diskRefs),
            )
        } else {
            conversationCache.remove(file.path)
        }
        return resolved.conversation
    }

    private fun putCacheEntry(path: String, entry: ConversationCacheEntry) {
        // LinkedHashMap insertion order is the recency order for this tiny LRU.
        conversationCache.remove(path)
        conversationCache[path] = entry
        while (conversationCache.size > MAX_CONVERSATION_CACHE_ENTRIES) {
            conversationCache.entries.iterator().next().let { eldest ->
                conversationCache.remove(eldest.key)
            }
        }
    }

    @Throws(Throwable::class)
    override suspend fun saveConversation(conversation: Conversation): Conversation = operationMutex.withLock {
        // Keep the full read-modify-write serialized while moving synchronous file IO
        // and JSON work off the caller's dispatcher, matching conversation reads.
        withContext(Dispatchers.Default) {
            saveConversationLocked(conversation)
        }
    }

    private fun saveConversationLocked(conversation: Conversation): Conversation {
        ensureBaseDir()
        val conversationToSave = mergeMessageWriteWithExistingMetadata(conversation)
        saveConversationReplacingAllFieldsLocked(conversationToSave)
        return conversationToSave
    }

    private fun saveConversationReplacingAllFieldsLocked(conversationToSave: Conversation) {
        val file = conversationFile(conversationToSave.id)
        // Blobs are durably on disk before the JSON that references them is written.
        // Every caller loads under this mutex first, so a cache entry here mirrors the file
        // currently on disk (its version was just validated).
        val previous = conversationCache[file.path]
        val prepared = blobCodec.externalize(conversationToSave, previousMemo = previous?.blobRefs)
        val text = encodeConversation(prepared.forDisk)
        // Drop the pre-write snapshot first so a failed write can never leave it trusted.
        conversationCache.remove(file.path)
        file.writeText(text)
        // Keep what was just written cached under the new fingerprint so the next save's
        // metadata merge does not re-read and re-decode the file. The size check guards the
        // stat-after-write window: any other writer that changed the file in between makes
        // the fingerprint disagree with our bytes, and we fall back to a disk read next time.
        val version = file.fileVersion()
        if (!prepared.containsPlaceholder && version != null && version.size == text.utf8ByteCount()) {
            putCacheEntry(
                file.path,
                ConversationCacheEntry(
                    version,
                    conversationToSave.asDecodedFromDisk(),
                    prepared.memo,
                    prepared.referenced,
                ),
            )
        }
        // Only after the JSON is committed, and only for blobs the previous JSON referenced:
        // drop the ones this save deliberately stopped referencing. Placeholders present
        // means some blob state is unknown, so nothing is deleted.
        val previousDiskRefs = previous?.diskRefs
        if (previousDiskRefs != null && !prepared.containsPlaceholder) {
            runCatching { blobCodec.prune(conversationToSave.id, previousDiskRefs, prepared.referenced) }
        }
        // The conversation file is canonical; index.json is a derived cache and
        // must not turn an already-committed message write into a false failure.
        runCatching { upsertIndex(conversationToSave.toSummary()) }
    }

    /** What a disk read would produce for transient (non-serialized) fields. */
    private fun Conversation.asDecodedFromDisk(): Conversation {
        val nodes = if (messageNodes.any { it.isFavorite }) {
            messageNodes.map { if (it.isFavorite) it.copy(isFavorite = false) else it }
        } else messageNodes
        return if (newConversation || nodes !== messageNodes) {
            copy(messageNodes = nodes, newConversation = false)
        } else this
    }

    private fun String.utf8ByteCount(): Long {
        var count = 0L
        var index = 0
        while (index < length) {
            val c = this[index]
            when {
                c.code < 0x80 -> count += 1
                c.code < 0x800 -> count += 2
                c.isHighSurrogate() && index + 1 < length && this[index + 1].isLowSurrogate() -> {
                    count += 4
                    index += 1
                }
                else -> count += 3
            }
            index += 1
        }
        return count
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
            conversation
        }

        // Preserve last-entry-wins semantics for duplicate IDs, with one backup per file.
        val lastById = validated.associateBy { it.id }
        if (lastById.isEmpty()) return@withLock
        // Externalizing writes blobs (durably, before any staged JSON references them).
        // Imports never prune, so a rolled-back import leaves the previous JSON's blobs intact.
        val replacements = lastById.mapValues { (_, conversation) ->
            encodeConversation(blobCodec.externalize(conversation, previousMemo = null).forDisk)
        }
        val batchId = Uuid.random()
        val prepared = mutableListOf<ImportDocument>()
        val committed = mutableListOf<ImportDocument>()
        val retainedBackups = mutableSetOf<String>()
        try {
            replacements.forEach { (id, text) ->
                val target = conversationFile(id)
                val original = if (target.exists()) {
                    target.readText() ?: throw ConversationStorageException(
                        "Cannot read existing conversation before import: ${target.path}"
                    )
                } else null
                val document = ImportDocument(
                    target = target,
                    staged = baseDir.child("$id.$batchId.import"),
                    backup = original?.let { baseDir.child("$id.$batchId.backup") },
                )
                prepared += document
                document.backup?.writeText(original!!)
                document.staged.writeText(text)
            }

            // Every new document and original backup is on disk before replacing any file.
            conversationCache.clear()
            summaryCache.clear()
            try {
                prepared.forEachIndexed { index, document ->
                    beforeImportCommitForTesting?.invoke(index)
                    document.staged.moveTo(document.target)
                    committed += document
                }
            } catch (commitFailure: Throwable) {
                val failure = ConversationStorageException("Failed to commit conversation import", commitFailure)
                committed.asReversed().forEach { document ->
                    try {
                        if (document.backup != null) {
                            document.backup.moveTo(document.target)
                        } else if (!document.target.delete()) {
                            throw ConversationStorageException("Failed to remove imported conversation: ${document.target.path}")
                        }
                    } catch (rollbackFailure: Throwable) {
                        document.backup?.let { retainedBackups += it.path }
                        failure.addSuppressed(rollbackFailure)
                    }
                }
                throw failure
            }
            // Rebuilding tolerates derived index write failure, matching saveConversation.
            rebuildIndex()
        } finally {
            prepared.forEach { document ->
                runCatching { document.staged.delete() }
                document.backup?.takeIf { it.path !in retainedBackups }?.let {
                    runCatching { it.delete() }
                }
            }
        }
        Unit
    }

    private data class ImportDocument(
        val target: ConversationFile,
        val staged: ConversationFile,
        val backup: ConversationFile?,
    )

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
        // JSON first, so no surviving document can reference a deleted blob. A leftover
        // directory is only wasted space and is pruned by any later save of this id.
        runCatching { blobCodec.deleteAll(id) }
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
        // Canonical files remain readable even if this derived cache cannot be repaired.
        // Match the valid-but-stale index path in listSummaries.
        if (summaries.isNotEmpty()) runCatching { writeIndex(summaries) }
        return summaries
    }

    private fun readConversationFileSummaries(): List<ConversationSummary> {
        if (!didLoadSummaryCache) {
            // Use filenames, not sandbox paths: iOS may relocate the app container.
            // The cache has its own versioned filename and is excluded from JSON backups.
            val text = baseDir.child(SUMMARY_CACHE_FILENAME).readText()
            if (text != null) {
                runCatching {
                    JsonInstant.decodeFromString<Map<String, SummaryCacheEntry>>(text)
                }.getOrNull()?.let { summaryCache.putAll(it) }
            }
            didLoadSummaryCache = true
        }
        val previousCache = summaryCache.toMap()
        val files = baseDir.listFilesByExtension("json")
            .filter { file ->
                // Previews, recaps and other sidecars are not conversation documents.
                runCatching { Uuid.parse(file.path.substringAfterLast(separatorChar()).removeSuffix(".json")) }.isSuccess
            }
        val currentNames = files.mapTo(mutableSetOf()) { it.path.substringAfterLast(separatorChar()) }
        summaryCache.entries.removeAll { it.key !in currentNames }
        val summaries = files.mapNotNull { file ->
            val name = file.path.substringAfterLast(separatorChar())
            val before = file.fileVersion()
            if (before != null) {
                summaryCache[name]?.takeIf { it.version == before }?.let {
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
                summaryCache[name] = SummaryCacheEntry(before, summary)
            } else {
                summaryCache.remove(name)
            }
            summary
        }
        if (summaryCache != previousCache) {
            // A cache failure must not hide canonical conversations or fail a saved turn.
            runCatching {
                baseDir.child(SUMMARY_CACHE_FILENAME)
                    .writeText(SUMMARY_STORAGE_JSON.encodeToString(summaryCache))
            }
        }
        return summaries
    }

    @Serializable
    private data class SummaryCacheEntry(
        val version: ConversationFileVersion,
        val summary: ConversationSummary,
    )

    private class ConversationCacheEntry(
        val version: ConversationFileVersion,
        /** Resolved form (inline data URLs), exactly what loadConversation returns. */
        val conversation: Conversation,
        /** data URL -> blob reference for [conversation]; same String instances, no copy. */
        val blobRefs: BlobRefMemo,
        /** Blob names the JSON at [version] references; the only candidates for pruning. */
        val diskRefs: Set<String>,
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
        const val SUMMARY_CACHE_FILENAME = "summary-cache-v1.cache"
        const val MAX_CONVERSATION_CACHE_ENTRIES = 2
        /** Blob directories without a conversation are only reclaimed once this old. */
        const val ORPHAN_BLOB_DIRECTORY_MIN_AGE_SECONDS = 30L * 60L
    }
}
