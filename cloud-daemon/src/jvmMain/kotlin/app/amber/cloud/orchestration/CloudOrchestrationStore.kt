package app.amber.cloud.orchestration

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import androidx.sqlite.execSQL
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.PlaceholderCredentialException
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.Closeable
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.ArrayDeque

/**
 * 基于 SQLite (`BundledSQLiteDriver`) + 原子文件镜像的持久化编排存储层。
 *
 * 负责持久化：
 * 1. `source_messages`：原始人类消息溯源表（严禁非主人/Agent/自动化消息授权新任务）
 * 2. `work_items`：8 态 WorkItem 队列与并发槽位控制
 * 3. `orchestration_operations`：`requestId` 幂等操作账本
 * 4. `thread_subscriptions`：Thread 与 Worker 多对多订阅直通关系
 * 5. `batch_rollups`：BatchRollup 与 `wakeClaim` 原子唤醒锁
 * 6. `archived_documents`：带 `expectedRevision` CAS 乐观锁与 SHA-256 的文档/报告归档表（不引入 Git）
 * 7. `diagnostic_events`：全量持久化诊断事件表 + 内存 RingBuffer 双层覆盖
 * 8. `automations`：三种自动化模式 (`DEDICATED` / `STANDALONE` / `HEARTBEAT`) 与 32 KiB 记忆状态
 * 9. `recall_edges`：对象 ID 之间的链式召回（Chain of Recall）引用图
 */
class CloudOrchestrationStore(
    val dataDir: File,
    val ringBufferCapacity: Int = 128,
) : Closeable {

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }

    val dbFile = File(dataDir, "orchestration.db")
    val archiveDir = File(dataDir, "archive").also { it.mkdirs() }

    private val driver = BundledSQLiteDriver()
    private val connection: SQLiteConnection

    private val ringBuffer = ArrayDeque<DiagnosticEventEntry>(ringBufferCapacity)

    init {
        dataDir.mkdirs()
        connection = driver.open(dbFile.absolutePath)
        initSchema()
    }

    @Synchronized
    private fun initSchema() {
        connection.execSQL("PRAGMA journal_mode = WAL")
        connection.execSQL("PRAGMA synchronous = NORMAL")
        connection.execSQL(
            """
            CREATE TABLE IF NOT EXISTS source_messages (
                message_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                sender_id TEXT NOT NULL,
                channel_id TEXT NOT NULL,
                sender_role TEXT NOT NULL,
                origin TEXT NOT NULL,
                raw_text_hash TEXT NOT NULL,
                raw_text TEXT NOT NULL,
                thread_key TEXT,
                created_at_ms INTEGER NOT NULL
            )
            """.trimIndent()
        )
        connection.execSQL(
            """
            CREATE TABLE IF NOT EXISTS work_items (
                work_item_id TEXT PRIMARY KEY,
                batch_id TEXT NOT NULL,
                scope_key TEXT NOT NULL,
                task_key TEXT NOT NULL,
                task_fingerprint TEXT NOT NULL,
                worker_session_id TEXT,
                state TEXT NOT NULL,
                slot_held INTEGER NOT NULL,
                progress_revision INTEGER NOT NULL,
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL,
                record_json TEXT NOT NULL
            )
            """.trimIndent()
        )
        connection.execSQL("CREATE INDEX IF NOT EXISTS idx_work_items_batch ON work_items(batch_id)")
        connection.execSQL("CREATE INDEX IF NOT EXISTS idx_work_items_state ON work_items(state)")
        connection.execSQL("CREATE INDEX IF NOT EXISTS idx_work_items_session ON work_items(worker_session_id)")
        connection.execSQL(
            """
            CREATE TABLE IF NOT EXISTS orchestration_operations (
                request_id TEXT PRIMARY KEY,
                batch_id TEXT NOT NULL,
                result_json TEXT NOT NULL,
                created_at_ms INTEGER NOT NULL
            )
            """.trimIndent()
        )
        connection.execSQL(
            """
            CREATE TABLE IF NOT EXISTS thread_subscriptions (
                thread_key TEXT NOT NULL,
                work_item_id TEXT NOT NULL,
                subscribed_at_ms INTEGER NOT NULL,
                PRIMARY KEY (thread_key, work_item_id)
            )
            """.trimIndent()
        )
        connection.execSQL("CREATE INDEX IF NOT EXISTS idx_thread_subs_work_item ON thread_subscriptions(work_item_id)")
        connection.execSQL(
            """
            CREATE TABLE IF NOT EXISTS batch_rollups (
                batch_id TEXT PRIMARY KEY,
                wake_claim_id TEXT NOT NULL,
                claimed_at_ms INTEGER NOT NULL,
                delivered_to_router INTEGER NOT NULL,
                rollup_json TEXT NOT NULL
            )
            """.trimIndent()
        )
        connection.execSQL(
            """
            CREATE TABLE IF NOT EXISTS archived_documents (
                doc_path TEXT PRIMARY KEY,
                owner_kind TEXT NOT NULL,
                owner_id TEXT NOT NULL,
                revision INTEGER NOT NULL,
                content_sha256 TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL,
                file_path TEXT NOT NULL
            )
            """.trimIndent()
        )
        connection.execSQL(
            """
            CREATE TABLE IF NOT EXISTS diagnostic_events (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                work_item_id TEXT,
                kind TEXT NOT NULL,
                message_id TEXT,
                detail TEXT NOT NULL,
                ts_ms INTEGER NOT NULL
            )
            """.trimIndent()
        )
        connection.execSQL("CREATE INDEX IF NOT EXISTS idx_diag_session ON diagnostic_events(session_id, seq)")
        connection.execSQL(
            """
            CREATE TABLE IF NOT EXISTS automations (
                automation_id TEXT PRIMARY KEY,
                mode TEXT NOT NULL,
                enabled INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL,
                record_json TEXT NOT NULL
            )
            """.trimIndent()
        )
        connection.execSQL(
            """
            CREATE TABLE IF NOT EXISTS recall_edges (
                from_kind TEXT NOT NULL,
                from_id TEXT NOT NULL,
                to_kind TEXT NOT NULL,
                to_id TEXT NOT NULL,
                summary TEXT NOT NULL,
                updated_at_ms INTEGER NOT NULL,
                PRIMARY KEY (from_kind, from_id, to_kind, to_id)
            )
            """.trimIndent()
        )
    }

    // ========================================================================
    // 1. SourceMessageProvenance 持久化与严格溯源校验
    // ========================================================================

    @Synchronized
    fun recordSourceMessage(
        provenance: SourceMessageProvenance,
        rawText: String,
        threadKey: String? = null,
    ) {
        val redactedText = CredentialRedactor.redact(rawText)
        connection.prepare(
            """
            INSERT OR REPLACE INTO source_messages (
                message_id, session_id, sender_id, channel_id, sender_role,
                origin, raw_text_hash, raw_text, thread_key, created_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """.trimIndent()
        ).use { stmt ->
            stmt.bindText(1, provenance.messageId)
            stmt.bindText(2, provenance.sessionId)
            stmt.bindText(3, provenance.senderId)
            stmt.bindText(4, provenance.channelId)
            stmt.bindText(5, provenance.senderRole.name)
            stmt.bindText(6, provenance.origin.name)
            stmt.bindText(7, provenance.rawTextHash)
            stmt.bindText(8, redactedText)
            if (threadKey != null) stmt.bindText(9, threadKey) else stmt.bindNull(9)
            stmt.bindLong(10, provenance.createdAtEpochMs)
            stmt.step()
        }
        if (threadKey != null) {
            addRecallEdge(
                fromKind = RecallObjectKind.TRIGGER_MESSAGE,
                fromId = provenance.messageId,
                toKind = RecallObjectKind.THREAD,
                toId = threadKey,
                summary = "所属话题 Thread: $threadKey",
                nowMs = provenance.createdAtEpochMs,
            )
            addRecallEdge(
                fromKind = RecallObjectKind.THREAD,
                fromId = threadKey,
                toKind = RecallObjectKind.TRIGGER_MESSAGE,
                toId = provenance.messageId,
                summary = redactedText.take(80),
                nowMs = provenance.createdAtEpochMs,
            )
        }
    }

    @Synchronized
    fun getSourceMessage(messageId: String): SourceMessageProvenance? {
        connection.prepare(
            """
            SELECT session_id, message_id, sender_id, channel_id, sender_role, origin, raw_text_hash, created_at_ms
            FROM source_messages WHERE message_id = ?
            """.trimIndent()
        ).use { stmt ->
            stmt.bindText(1, messageId)
            if (!stmt.step()) return null
            return SourceMessageProvenance(
                sessionId = stmt.getText(0),
                messageId = stmt.getText(1),
                senderId = stmt.getText(2),
                channelId = stmt.getText(3),
                senderRole = runCatching { SenderRole.valueOf(stmt.getText(4)) }.getOrDefault(SenderRole.GUEST),
                origin = runCatching { MessageProvenanceOrigin.valueOf(stmt.getText(5)) }.getOrDefault(MessageProvenanceOrigin.GUEST_HUMAN),
                rawTextHash = stmt.getText(6),
                createdAtEpochMs = stmt.getLong(7),
            )
        }
    }

    @Synchronized
    fun getSourceMessageText(messageId: String): String? {
        connection.prepare("SELECT raw_text FROM source_messages WHERE message_id = ?").use { stmt ->
            stmt.bindText(1, messageId)
            if (!stmt.step()) return null
            return stmt.getText(0)
        }
    }

    /**
     * 强制解析并验证新任务关联的原始主人消息快照。
     * - 必须至少包含 1 条消息；
     * - 每条消息都必须存在于持久层，且必须是 `SenderRole.OWNER` + `MessageProvenanceOrigin.OWNER_HUMAN`；
     * - Agent 或自动化产生的消息、访客或协作者消息一律抛出 [UnauthorizedWorkSourceException]。
     */
    @Synchronized
    fun resolveAuthorizedSourceMessages(messageIds: List<String>): List<SourceMessageProvenance> {
        val cleanIds = messageIds.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        if (cleanIds.isEmpty()) {
            throw UnauthorizedWorkSourceException("派发新任务必须关联至少一条已认证主人的原始消息 ID (contextMessageIds 不能为空)")
        }
        val resolved = mutableListOf<SourceMessageProvenance>()
        for (id in cleanIds) {
            val prov = getSourceMessage(id)
                ?: throw UnauthorizedWorkSourceException("找不到原始消息记录或消息未经入站验签: $id")
            if (prov.origin == MessageProvenanceOrigin.AGENT || prov.origin == MessageProvenanceOrigin.AUTOMATION) {
                throw UnauthorizedWorkSourceException("Agent and automation messages cannot authorize new work (messageId=$id, origin=${prov.origin})")
            }
            if (!prov.canAuthorizeNewWork) {
                throw UnauthorizedWorkSourceException("非主人消息不能授权创建新任务 (messageId=$id, senderRole=${prov.senderRole}, origin=${prov.origin})")
            }
            resolved.add(prov)
        }
        return resolved.sortedWith(compareBy<SourceMessageProvenance> { it.sessionId }.thenBy { it.messageId })
    }

    // ========================================================================
    // 2. WorkItem 队列、槽位统计与操作账本
    // ========================================================================

    @Synchronized
    fun getOperationResult(requestId: String): BatchSubmissionResult? {
        if (requestId.isBlank()) return null
        connection.prepare("SELECT result_json FROM orchestration_operations WHERE request_id = ?").use { stmt ->
            stmt.bindText(1, requestId)
            if (!stmt.step()) return null
            val raw = stmt.getText(0)
            return runCatching { json.decodeFromString<BatchSubmissionResult>(raw) }.getOrNull()
        }
    }

    @Synchronized
    fun saveOperationResult(requestId: String, result: BatchSubmissionResult, nowMs: Long) {
        if (requestId.isBlank()) return
        connection.prepare(
            """
            INSERT OR REPLACE INTO orchestration_operations (request_id, batch_id, result_json, created_at_ms)
            VALUES (?, ?, ?, ?)
            """.trimIndent()
        ).use { stmt ->
            stmt.bindText(1, requestId)
            stmt.bindText(2, result.batchId)
            stmt.bindText(3, json.encodeToString(result))
            stmt.bindLong(4, nowMs)
            stmt.step()
        }
    }

    @Synchronized
    fun upsertWorkItem(record: CloudWorkItemRecord) {
        val safeRecord = record.copy(
            title = CredentialRedactor.redact(record.title),
            brief = CredentialRedactor.redact(record.brief),
            latestProgressNote = record.latestProgressNote?.let(CredentialRedactor::redact),
            failureReason = record.failureReason?.let(CredentialRedactor::redact),
        )
        connection.prepare(
            """
            INSERT OR REPLACE INTO work_items (
                work_item_id, batch_id, scope_key, task_key, task_fingerprint,
                worker_session_id, state, slot_held, progress_revision,
                created_at_ms, updated_at_ms, record_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """.trimIndent()
        ).use { stmt ->
            stmt.bindText(1, safeRecord.workItemId)
            stmt.bindText(2, safeRecord.batchId)
            stmt.bindText(3, safeRecord.scopeKey)
            stmt.bindText(4, safeRecord.taskKey)
            stmt.bindText(5, safeRecord.taskFingerprint)
            if (safeRecord.workerSessionId != null) stmt.bindText(6, safeRecord.workerSessionId) else stmt.bindNull(6)
            stmt.bindText(7, safeRecord.state.name)
            stmt.bindLong(8, if (safeRecord.slotHeld) 1L else 0L)
            stmt.bindLong(9, safeRecord.progressRevision.toLong())
            stmt.bindLong(10, safeRecord.createdAtMs)
            stmt.bindLong(11, safeRecord.updatedAtMs)
            stmt.bindText(12, json.encodeToString(safeRecord))
            stmt.step()
        }
    }

    @Synchronized
    fun getWorkItem(workItemId: String): CloudWorkItemRecord? {
        connection.prepare("SELECT record_json FROM work_items WHERE work_item_id = ?").use { stmt ->
            stmt.bindText(1, workItemId)
            if (!stmt.step()) return null
            return json.decodeFromString<CloudWorkItemRecord>(stmt.getText(0))
        }
    }

    @Synchronized
    fun getWorkItemBySession(workerSessionId: String): CloudWorkItemRecord? {
        connection.prepare("SELECT record_json FROM work_items WHERE worker_session_id = ? ORDER BY CASE WHEN state IN ('COMPLETED', 'FAILED', 'CANCELLED') THEN 1 ELSE 0 END, created_at_ms DESC LIMIT 1").use { stmt ->
            stmt.bindText(1, workerSessionId)
            if (!stmt.step()) return null
            return json.decodeFromString<CloudWorkItemRecord>(stmt.getText(0))
        }
    }

    @Synchronized
    fun listWorkItems(): List<CloudWorkItemRecord> {
        val out = mutableListOf<CloudWorkItemRecord>()
        connection.prepare("SELECT record_json FROM work_items ORDER BY created_at_ms ASC, work_item_id ASC").use { stmt ->
            while (stmt.step()) {
                out.add(json.decodeFromString<CloudWorkItemRecord>(stmt.getText(0)))
            }
        }
        return out
    }

    @Synchronized
    fun listWorkItemsByBatch(batchId: String): List<CloudWorkItemRecord> {
        val out = mutableListOf<CloudWorkItemRecord>()
        connection.prepare("SELECT record_json FROM work_items WHERE batch_id = ? ORDER BY created_at_ms ASC, work_item_id ASC").use { stmt ->
            stmt.bindText(1, batchId)
            while (stmt.step()) {
                out.add(json.decodeFromString<CloudWorkItemRecord>(stmt.getText(0)))
            }
        }
        return out
    }

    @Synchronized
    fun listQueuedWorkItems(): List<CloudWorkItemRecord> {
        val out = mutableListOf<CloudWorkItemRecord>()
        connection.prepare("SELECT record_json FROM work_items WHERE state = 'QUEUED' ORDER BY created_at_ms ASC, work_item_id ASC").use { stmt ->
            while (stmt.step()) {
                out.add(json.decodeFromString<CloudWorkItemRecord>(stmt.getText(0)))
            }
        }
        return out
    }

    @Synchronized
    fun countHeldSlots(): Int {
        connection.prepare(
            "SELECT COUNT(*) FROM work_items WHERE slot_held = 1 AND state IN ('STARTING', 'WORKING', 'WAITING')"
        ).use { stmt ->
            return if (stmt.step()) stmt.getLong(0).toInt() else 0
        }
    }

    @Synchronized
    fun updateWorkItemCasRevision(
        workItemId: String,
        expectedRevision: Int,
        transform: (CloudWorkItemRecord) -> CloudWorkItemRecord,
    ): CloudWorkItemRecord {
        val existing = getWorkItem(workItemId)
            ?: throw IllegalArgumentException("找不到 WorkItem: $workItemId")
        if (existing.progressRevision != expectedRevision) {
            throw OptimisticLockConflictException(
                "WorkItem $workItemId 进度版本冲突: expectedRevision=$expectedRevision, actual=${existing.progressRevision}"
            )
        }
        val updated = transform(existing)
        upsertWorkItem(updated)
        return updated
    }

    // ========================================================================
    // 3. Thread 多对多订阅直通
    // ========================================================================

    @Synchronized
    fun subscribeThread(threadKey: String, workItemId: String, nowMs: Long) {
        val cleanThread = threadKey.trim()
        if (cleanThread.isEmpty()) return
        connection.prepare(
            """
            INSERT OR REPLACE INTO thread_subscriptions (thread_key, work_item_id, subscribed_at_ms)
            VALUES (?, ?, ?)
            """.trimIndent()
        ).use { stmt ->
            stmt.bindText(1, cleanThread)
            stmt.bindText(2, workItemId)
            stmt.bindLong(3, nowMs)
            stmt.step()
        }
        addRecallEdge(
            fromKind = RecallObjectKind.THREAD,
            fromId = cleanThread,
            toKind = RecallObjectKind.WORK_ITEM,
            toId = workItemId,
            summary = "已订阅该话题的 Worker 任务: $workItemId",
            nowMs = nowMs,
        )
        addRecallEdge(
            fromKind = RecallObjectKind.WORK_ITEM,
            fromId = workItemId,
            toKind = RecallObjectKind.THREAD,
            toId = cleanThread,
            summary = "订阅的话题 Thread: $cleanThread",
            nowMs = nowMs,
        )
    }

    @Synchronized
    fun unsubscribeThread(threadKey: String, workItemId: String) {
        connection.prepare("DELETE FROM thread_subscriptions WHERE thread_key = ? AND work_item_id = ?").use { stmt ->
            stmt.bindText(1, threadKey.trim())
            stmt.bindText(2, workItemId)
            stmt.step()
        }
    }

    @Synchronized
    fun unsubscribeAllForWorkItem(workItemId: String) {
        connection.prepare("DELETE FROM thread_subscriptions WHERE work_item_id = ?").use { stmt ->
            stmt.bindText(1, workItemId)
            stmt.step()
        }
    }

    @Synchronized
    fun listActiveSubscribersForThread(threadKey: String): List<CloudWorkItemRecord> {
        val cleanThread = threadKey.trim()
        if (cleanThread.isEmpty()) return emptyList()
        val ids = mutableListOf<String>()
        connection.prepare(
            "SELECT work_item_id FROM thread_subscriptions WHERE thread_key = ? ORDER BY subscribed_at_ms ASC, work_item_id ASC"
        ).use { stmt ->
            stmt.bindText(1, cleanThread)
            while (stmt.step()) {
                ids.add(stmt.getText(0))
            }
        }
        return ids.mapNotNull { getWorkItem(it) }.filter { !it.state.isTerminal }
    }

    @Synchronized
    fun listSubscribedThreadsForWorkItem(workItemId: String): List<String> {
        val out = mutableListOf<String>()
        connection.prepare(
            "SELECT thread_key FROM thread_subscriptions WHERE work_item_id = ? ORDER BY subscribed_at_ms ASC"
        ).use { stmt ->
            stmt.bindText(1, workItemId)
            while (stmt.step()) {
                out.add(stmt.getText(0))
            }
        }
        return out
    }

    // ========================================================================
    // 4. BatchRollup 与 wakeClaim 锁
    // ========================================================================

    @Synchronized
    fun tryClaimBatchWake(
        batchId: String,
        claimId: String,
        workItemIds: List<String>,
        rollupMarkdown: String,
        nowMs: Long,
        ttlMs: Long,
    ): BatchRollupRecord? {
        connection.execSQL("BEGIN IMMEDIATE")
        try {
            val existing = getBatchRollupInternal(batchId)
            if (existing != null) {
                if (existing.deliveredToRouter || (nowMs - existing.claimedAtMs) < ttlMs) {
                    connection.execSQL("COMMIT")
                    return null
                }
            }
            val safeMarkdown = CredentialRedactor.redact(rollupMarkdown)
            val record = BatchRollupRecord(
                batchId = batchId,
                workItemIds = workItemIds,
                rollupMarkdown = safeMarkdown,
                wakeClaimId = claimId,
                claimedAtMs = nowMs,
                deliveredToRouter = true,
            )
            connection.prepare(
                """
                INSERT OR REPLACE INTO batch_rollups (
                    batch_id, wake_claim_id, claimed_at_ms, delivered_to_router, rollup_json
                ) VALUES (?, ?, ?, 1, ?)
                """.trimIndent()
            ).use { stmt ->
                stmt.bindText(1, batchId)
                stmt.bindText(2, claimId)
                stmt.bindLong(3, nowMs)
                stmt.bindText(4, json.encodeToString(record))
                stmt.step()
            }
            connection.execSQL("COMMIT")
            return record
        } catch (t: Throwable) {
            runCatching { connection.execSQL("ROLLBACK") }
            throw t
        }
    }

    @Synchronized
    fun getBatchRollup(batchId: String): BatchRollupRecord? = getBatchRollupInternal(batchId)

    private fun getBatchRollupInternal(batchId: String): BatchRollupRecord? {
        connection.prepare("SELECT rollup_json FROM batch_rollups WHERE batch_id = ?").use { stmt ->
            stmt.bindText(1, batchId)
            if (!stmt.step()) return null
            return json.decodeFromString<BatchRollupRecord>(stmt.getText(0))
        }
    }

    // ========================================================================
    // 5. SQLite 乐观锁 + SHA-256 + 原子文件归档 (不引入 Git)
    // ========================================================================

    /**
     * 校验主体对归档文档路径的写权限：
     * - `SOUL.md` / `instructions.md` / `notes.md`：仅允许 [CloudPrincipal.OwnerUser] 写入；
     * - `decisions.md` / `docs/...` / `rollups/...`：允许 [CloudPrincipal.OwnerUser] 与 [CloudPrincipal.CloudCoordinator] 写入；
     * - `scratch/<workItemId>.md` 与 `inbox/<workItemId>/report.md`：仅允许对应 `workItemId` 的 [CloudPrincipal.Worker] 或 [CloudPrincipal.CloudCoordinator] 写入。
     */
    fun verifyDocumentWritePermission(principal: CloudPrincipal, normalizedDocPath: String) {
        val clean = normalizedDocPath.trimStart('/')
        val isOwnerOnlyDoc = clean.equals("SOUL.md", ignoreCase = true) ||
            clean.equals("instructions.md", ignoreCase = true) ||
            clean.equals("notes.md", ignoreCase = true) ||
            clean.startsWith("memory/notes/")
        if (isOwnerOnlyDoc) {
            if (principal !is CloudPrincipal.OwnerUser) {
                throw PrincipalPermissionException("文档 $clean 为主人专属只读指令，禁止 Agent/Worker 修改")
            }
            return
        }

        when (principal) {
            is CloudPrincipal.OwnerUser,
            is CloudPrincipal.CloudCoordinator,
            is CloudPrincipal.AutomationRunner,
            -> return

            is CloudPrincipal.Worker -> {
                val allowedScratch = "scratch/${principal.workItemId}.md"
                val allowedReport = "inbox/${principal.workItemId}/report.md"
                if (clean != allowedScratch && clean != allowedReport) {
                    throw PrincipalPermissionException(
                        "Worker (${principal.workItemId}) 仅允许写入自身草稿或结算报告 ($allowedScratch / $allowedReport)，禁止写入: $clean"
                    )
                }
            }

            is CloudPrincipal.ExternalCaller -> {
                throw PrincipalPermissionException("未授权外部调用方禁止写入归档文档: $clean")
            }
        }
    }

    @Synchronized
    fun writeArchivedDocument(
        principal: CloudPrincipal,
        docPath: String,
        content: String,
        expectedRevision: Int? = null,
        deduplicateIfSameSha256: Boolean = false,
        nowMs: Long = System.currentTimeMillis(),
    ): ArchivedDocumentRecord {
        if (CredentialRedactor.isPlaceholderCredential(content)) {
            throw PlaceholderCredentialException("拒绝将占位符凭据写入归档文档: $docPath")
        }
        val cleanPath = docPath.trim().trimStart('/')
        require(cleanPath.isNotEmpty() && !cleanPath.contains("..")) { "非法归档文档路径: $docPath" }
        verifyDocumentWritePermission(principal, cleanPath)

        val targetFile = File(archiveDir, cleanPath).canonicalFile
        require(targetFile.path.startsWith(archiveDir.canonicalPath)) {
            "禁止路径穿越写入归档目录之外: $docPath"
        }

        val safeContent = CredentialRedactor.redact(content)
        val sha256 = OrchestrationHash.sha256Hex(safeContent)
        val bytes = safeContent.toByteArray(Charsets.UTF_8)

        val existing = getArchivedDocument(cleanPath)
        if (deduplicateIfSameSha256 && existing != null && existing.contentSha256 == sha256 && targetFile.exists()) {
            return existing.copy(replayedUnchanged = true)
        }

        val currentRev = existing?.revision ?: 0
        if (expectedRevision != null && expectedRevision != currentRev) {
            throw OptimisticLockConflictException(
                "归档文档 $cleanPath 版本冲突: expectedRevision=$expectedRevision, actual=$currentRev"
            )
        }

        val nextRev = currentRev + 1
        targetFile.parentFile?.mkdirs()
        val tmpFile = File(targetFile.parentFile, "${targetFile.name}.tmp")
        tmpFile.writeBytes(bytes)
        Files.move(tmpFile.toPath(), targetFile.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)

        val record = ArchivedDocumentRecord(
            docPath = cleanPath,
            ownerKind = principal::class.simpleName ?: "Unknown",
            ownerId = principal.principalId,
            revision = nextRev,
            contentSha256 = sha256,
            sizeBytes = bytes.size,
            updatedAtMs = nowMs,
            absoluteFilePath = targetFile.absolutePath,
            replayedUnchanged = false,
        )

        connection.prepare(
            """
            INSERT OR REPLACE INTO archived_documents (
                doc_path, owner_kind, owner_id, revision, content_sha256, size_bytes, updated_at_ms, file_path
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """.trimIndent()
        ).use { stmt ->
            stmt.bindText(1, record.docPath)
            stmt.bindText(2, record.ownerKind)
            stmt.bindText(3, record.ownerId)
            stmt.bindLong(4, record.revision.toLong())
            stmt.bindText(5, record.contentSha256)
            stmt.bindLong(6, record.sizeBytes.toLong())
            stmt.bindLong(7, record.updatedAtMs)
            stmt.bindText(8, record.absoluteFilePath)
            stmt.step()
        }

        return record
    }

    @Synchronized
    fun getArchivedDocument(docPath: String): ArchivedDocumentRecord? {
        val cleanPath = docPath.trim().trimStart('/')
        connection.prepare(
            """
            SELECT doc_path, owner_kind, owner_id, revision, content_sha256, size_bytes, updated_at_ms, file_path
            FROM archived_documents WHERE doc_path = ?
            """.trimIndent()
        ).use { stmt ->
            stmt.bindText(1, cleanPath)
            if (!stmt.step()) return null
            return ArchivedDocumentRecord(
                docPath = stmt.getText(0),
                ownerKind = stmt.getText(1),
                ownerId = stmt.getText(2),
                revision = stmt.getLong(3).toInt(),
                contentSha256 = stmt.getText(4),
                sizeBytes = stmt.getLong(5).toInt(),
                updatedAtMs = stmt.getLong(6),
                absoluteFilePath = stmt.getText(7),
            )
        }
    }

    @Synchronized
    fun readArchivedDocumentText(docPath: String): String? {
        val record = getArchivedDocument(docPath) ?: return null
        val file = File(record.absoluteFilePath)
        if (!file.exists()) return null
        return CredentialRedactor.redact(file.readText())
    }

    // ========================================================================
    // 6. 诊断事件存储 (SQLite 持久化 + 内存 RingBuffer) 与流式事件折叠
    // ========================================================================

    @Synchronized
    fun appendDiagnosticEvent(
        sessionId: String,
        workItemId: String?,
        kind: String,
        detail: String,
        messageId: String? = null,
        nowMs: Long = System.currentTimeMillis(),
    ): DiagnosticEventEntry {
        val safeDetail = CredentialRedactor.redact(detail)
        connection.prepare(
            """
            INSERT INTO diagnostic_events (session_id, work_item_id, kind, message_id, detail, ts_ms)
            VALUES (?, ?, ?, ?, ?, ?)
            """.trimIndent()
        ).use { stmt ->
            stmt.bindText(1, sessionId)
            if (workItemId != null) stmt.bindText(2, workItemId) else stmt.bindNull(2)
            stmt.bindText(3, kind)
            if (messageId != null) stmt.bindText(4, messageId) else stmt.bindNull(4)
            stmt.bindText(5, safeDetail)
            stmt.bindLong(6, nowMs)
            stmt.step()
        }

        val seq = connection.prepare("SELECT last_insert_rowid()").use { stmt ->
            if (stmt.step()) stmt.getLong(0) else 0L
        }
        val entry = DiagnosticEventEntry(
            sequence = seq,
            sessionId = sessionId,
            workItemId = workItemId,
            kind = kind,
            messageId = messageId,
            detail = safeDetail,
            timestampMs = nowMs,
        )
        if (ringBuffer.size >= ringBufferCapacity) {
            ringBuffer.removeFirst()
        }
        ringBuffer.addLast(entry)
        return entry
    }

    @Synchronized
    fun listSqliteDiagnosticEvents(sessionId: String, limit: Int = 200): List<DiagnosticEventEntry> {
        val out = mutableListOf<DiagnosticEventEntry>()
        connection.prepare(
            """
            SELECT seq, session_id, work_item_id, kind, message_id, detail, ts_ms
            FROM diagnostic_events
            WHERE session_id = ?
            ORDER BY seq ASC
            LIMIT ?
            """.trimIndent()
        ).use { stmt ->
            stmt.bindText(1, sessionId)
            stmt.bindLong(2, limit.toLong())
            while (stmt.step()) {
                out.add(
                    DiagnosticEventEntry(
                        sequence = stmt.getLong(0),
                        sessionId = stmt.getText(1),
                        workItemId = if (stmt.isNull(2)) null else stmt.getText(2),
                        kind = stmt.getText(3),
                        messageId = if (stmt.isNull(4)) null else stmt.getText(4),
                        detail = stmt.getText(5),
                        timestampMs = stmt.getLong(6),
                    )
                )
            }
        }
        return out
    }

    @Synchronized
    fun listRingBufferDiagnosticEvents(sessionId: String): List<DiagnosticEventEntry> =
        ringBuffer.filter { it.sessionId == sessionId }

    /**
     * 折叠同一 `messageId` 的连续流式增量事件为单条 `streamUpdates: N` 摘要。
     */
    fun collapseDiagnosticEvents(events: List<DiagnosticEventEntry>): List<String> {
        if (events.isEmpty()) return emptyList()
        val result = mutableListOf<String>()
        var idx = 0
        while (idx < events.size) {
            val current = events[idx]
            if (current.kind == "stream_chunk" && current.messageId != null) {
                var count = 1
                var lastDetail = current.detail
                while (
                    idx + count < events.size &&
                    events[idx + count].kind == "stream_chunk" &&
                    events[idx + count].messageId == current.messageId
                ) {
                    lastDetail = events[idx + count].detail
                    count++
                }
                result.add(
                    "[seq=${current.sequence}] stream_chunk(messageId=${current.messageId}, streamUpdates: $count) -> ${CredentialRedactor.redact(lastDetail.take(120))}"
                )
                idx += count
            } else {
                result.add(
                    "[seq=${current.sequence}] ${current.kind}: ${CredentialRedactor.redact(current.detail)}"
                )
                idx++
            }
        }
        return result
    }

    // ========================================================================
    // 7. 自动化状态存储 (DEDICATED / STANDALONE / HEARTBEAT)
    // ========================================================================

    @Synchronized
    fun upsertAutomation(record: CloudAutomationRecord) {
        val safeMemory = OrchestrationHash.enforceMaxUtf8Bytes(
            CredentialRedactor.redact(record.memoryText),
            OrchestrationHash.AUTOMATION_MEMORY_MAX_BYTES,
        )
        val safeRecord = record.copy(
            title = CredentialRedactor.redact(record.title),
            prompt = CredentialRedactor.redact(record.prompt),
            memoryText = safeMemory,
        )
        connection.prepare(
            """
            INSERT OR REPLACE INTO automations (automation_id, mode, enabled, updated_at_ms, record_json)
            VALUES (?, ?, ?, ?, ?)
            """.trimIndent()
        ).use { stmt ->
            stmt.bindText(1, safeRecord.automationId)
            stmt.bindText(2, safeRecord.mode.name)
            stmt.bindLong(3, if (safeRecord.enabled) 1L else 0L)
            stmt.bindLong(4, safeRecord.updatedAtMs)
            stmt.bindText(5, json.encodeToString(safeRecord))
            stmt.step()
        }
    }

    @Synchronized
    fun getAutomation(automationId: String): CloudAutomationRecord? {
        connection.prepare("SELECT record_json FROM automations WHERE automation_id = ?").use { stmt ->
            stmt.bindText(1, automationId)
            if (!stmt.step()) return null
            return json.decodeFromString<CloudAutomationRecord>(stmt.getText(0))
        }
    }

    @Synchronized
    fun listAutomations(): List<CloudAutomationRecord> {
        val out = mutableListOf<CloudAutomationRecord>()
        connection.prepare("SELECT record_json FROM automations ORDER BY automation_id ASC").use { stmt ->
            while (stmt.step()) {
                out.add(json.decodeFromString<CloudAutomationRecord>(stmt.getText(0)))
            }
        }
        return out
    }

    // ========================================================================
    // 8. 链式召回 (Chain of Recall) 引用边
    // ========================================================================

    @Synchronized
    fun addRecallEdge(
        fromKind: RecallObjectKind,
        fromId: String,
        toKind: RecallObjectKind,
        toId: String,
        summary: String,
        nowMs: Long = System.currentTimeMillis(),
    ) {
        val safeSummary = CredentialRedactor.redact(summary.replace("\n", " ").trim()).take(160)
        connection.prepare(
            """
            INSERT OR REPLACE INTO recall_edges (from_kind, from_id, to_kind, to_id, summary, updated_at_ms)
            VALUES (?, ?, ?, ?, ?, ?)
            """.trimIndent()
        ).use { stmt ->
            stmt.bindText(1, fromKind.name)
            stmt.bindText(2, fromId)
            stmt.bindText(3, toKind.name)
            stmt.bindText(4, toId)
            stmt.bindText(5, safeSummary)
            stmt.bindLong(6, nowMs)
            stmt.step()
        }
    }

    @Synchronized
    fun listNextHopLinks(fromKind: RecallObjectKind, fromId: String): List<RecallLink> {
        val out = mutableListOf<RecallLink>()
        connection.prepare(
            """
            SELECT to_kind, to_id, summary
            FROM recall_edges
            WHERE from_kind = ? AND from_id = ?
            ORDER BY updated_at_ms DESC, to_id ASC
            """.trimIndent()
        ).use { stmt ->
            stmt.bindText(1, fromKind.name)
            stmt.bindText(2, fromId)
            while (stmt.step()) {
                val kind = runCatching { RecallObjectKind.valueOf(stmt.getText(0)) }.getOrNull() ?: continue
                out.add(
                    RecallLink(
                        kind = kind,
                        id = stmt.getText(1),
                        summary = stmt.getText(2),
                    )
                )
            }
        }
        return out
    }

    @Synchronized
    override fun close() {
        runCatching { connection.close() }
    }
}
