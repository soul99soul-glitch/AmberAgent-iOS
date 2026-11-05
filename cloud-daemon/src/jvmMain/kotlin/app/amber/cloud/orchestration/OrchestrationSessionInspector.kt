package app.amber.cloud.orchestration

import app.amber.cloud.security.CredentialRedactor
import java.util.concurrent.ConcurrentHashMap
import kotlin.uuid.Uuid

/**
 * 负责 Worker 会话双层无损读取（第一层分页概览 `readWorkerSessionPage`，
 * 第二层按 `messageVersion` 与 Unicode 代理对安全切片 `readWorkerMessageSlice`）、
 * 单次取证诊断 `diagnoseWorkerSession` 与按对象 ID 链式召回 `recallObject`。
 */
internal class OrchestrationSessionInspector(
    private val kernel: DefaultCloudOrchestrationKernel,
) {
    private val streamingMessageIds = ConcurrentHashMap.newKeySet<String>()
    private val messageUpdatedAtMs = ConcurrentHashMap<String, Long>()

    fun recordMessageTimestamp(messageId: String, nowEpochMs: Long) {
        messageUpdatedAtMs[messageId] = nowEpochMs
    }

    fun markMessageStreaming(messageId: String, streaming: Boolean, nowEpochMs: Long) {
        if (streaming) {
            streamingMessageIds.add(messageId)
        } else {
            streamingMessageIds.remove(messageId)
        }
        messageUpdatedAtMs[messageId] = nowEpochMs
    }

    fun recordStreamingChunk(
        sessionId: String,
        messageId: String,
        chunkPreview: String,
        nowEpochMs: Long,
    ) {
        val workItem = kernel.store.getWorkItemBySession(sessionId)
        kernel.store.appendDiagnosticEvent(
            sessionId = sessionId,
            workItemId = workItem?.workItemId,
            kind = "stream_chunk",
            messageId = messageId,
            detail = chunkPreview,
            nowMs = nowEpochMs,
        )
    }

    private fun deriveSessionStatus(sessionId: String): String {
        val workItem = kernel.store.getWorkItemBySession(sessionId) ?: kernel.store.getWorkItem(sessionId)
        return when (workItem?.state) {
            WorkItemState.WAITING -> "waiting-for-approval"
            WorkItemState.STARTING, WorkItemState.WORKING -> "working"
            WorkItemState.FAILED -> "error"
            WorkItemState.CANCELLED -> "interrupted"
            else -> "idle"
        }
    }

    suspend fun readWorkerSessionPage(
        sessionId: String,
        pageCursor: String?,
        pageSize: Int,
        maxMessageChars: Int,
    ): SessionReadPage {
        val cleanPageSize = pageSize.coerceIn(1, 100)
        val cleanMaxChars = maxMessageChars.coerceIn(64, 20_000)
        val convUuid = runCatching { Uuid.parse(sessionId) }.getOrNull()
        val conv = convUuid?.let { kernel.conversationStorage.loadConversation(it) }
        val nodes = conv?.messageNodes.orEmpty()

        val startIdx = pageCursor?.removePrefix("idx:")?.toIntOrNull()?.coerceAtLeast(0) ?: 0
        val endIdxExclusive = (startIdx + cleanPageSize).coerceAtMost(nodes.size)
        val workItem = kernel.store.getWorkItemBySession(sessionId) ?: kernel.store.getWorkItem(sessionId)
        val sessionNextHops = kernel.store.listNextHopLinks(RecallObjectKind.WORKER_SESSION, sessionId) +
            (workItem?.let { kernel.store.listNextHopLinks(RecallObjectKind.WORK_ITEM, it.workItemId) }.orEmpty())

        val previewItems = (startIdx until endIdxExclusive).map { idx ->
            val msg = nodes[idx].currentMessage
            val msgId = msg.id.toString()
            val fullText = CredentialRedactor.redact(msg.toText())
            val updatedAt = messageUpdatedAtMs[msgId] ?: workItem?.updatedAtMs ?: 0L
            val version = "$updatedAt:${fullText.length}"
            val safeEnd = OrchestrationHash.unicodeSafeEndOffset(fullText, 0, cleanMaxChars)
            val truncated = safeEnd < fullText.length
            val preview = if (truncated) fullText.substring(0, safeEnd) else fullText
            MessagePreviewItem(
                messageIndex = idx,
                messageId = msgId,
                role = msg.role.name.lowercase(),
                previewText = preview,
                truncated = truncated,
                totalChars = fullText.length,
                messageVersion = version,
                streaming = msgId in streamingMessageIds,
                nextHopLinks = kernel.store.listNextHopLinks(RecallObjectKind.TRIGGER_MESSAGE, msgId),
            )
        }

        val nextCursor = if (endIdxExclusive < nodes.size) "idx:$endIdxExclusive" else null
        return SessionReadPage(
            sessionId = sessionId,
            workItemId = workItem?.workItemId,
            derivedStatus = deriveSessionStatus(sessionId),
            items = previewItems,
            nextPageCursor = nextCursor,
            nextHopLinks = sessionNextHops.distinctBy { "${it.kind}:${it.id}" },
        )
    }

    suspend fun readWorkerMessageSlice(
        cursor: MessageSliceCursor,
    ): MessageSliceResult {
        if (cursor.messageId in streamingMessageIds) {
            throw MessageVersionMismatchException("消息 ${cursor.messageId} 仍在流式生成中 (streaming)，禁止切片读取以防读到半条脏数据")
        }
        val convUuid = runCatching { Uuid.parse(cursor.sessionId) }.getOrNull()
            ?: throw IllegalArgumentException("非法 sessionId: ${cursor.sessionId}")
        val conv = kernel.conversationStorage.loadConversation(convUuid)
            ?: throw IllegalArgumentException("找不到会话: ${cursor.sessionId}")
        val nodes = conv.messageNodes
        if (cursor.messageIndex !in nodes.indices) {
            throw IllegalArgumentException("messageIndex 越界: ${cursor.messageIndex}")
        }
        val msg = nodes[cursor.messageIndex].currentMessage
        val msgId = msg.id.toString()
        if (msgId != cursor.messageId) {
            throw MessageVersionMismatchException("messageIndex=${cursor.messageIndex} 对应的 messageId ($msgId) 与游标 (${cursor.messageId}) 不一致")
        }

        val workItem = kernel.store.getWorkItemBySession(cursor.sessionId)
        val fullText = CredentialRedactor.redact(msg.toText())
        val updatedAt = messageUpdatedAtMs[msgId] ?: workItem?.updatedAtMs ?: 0L
        val currentVersion = "$updatedAt:${fullText.length}"
        if (currentVersion != cursor.messageVersion) {
            throw MessageVersionMismatchException(
                "messageVersion 已变化（防止撕裂读取）: requested=${cursor.messageVersion}, actual=$currentVersion"
            )
        }

        val safeStart = OrchestrationHash.unicodeSafeStartOffset(fullText, cursor.offsetChars)
        val safeEnd = OrchestrationHash.unicodeSafeEndOffset(fullText, safeStart, cursor.limitChars.coerceIn(1, 20_000))
        val slice = fullText.substring(safeStart, safeEnd)
        val nextOffset = if (safeEnd < fullText.length) safeEnd else null

        return MessageSliceResult(
            sessionId = cursor.sessionId,
            messageId = msgId,
            messageVersion = currentVersion,
            sliceText = slice,
            nextOffsetChars = nextOffset,
            nextHopLinks = kernel.store.listNextHopLinks(RecallObjectKind.WORKER_SESSION, cursor.sessionId),
        )
    }

    suspend fun diagnoseWorkerSession(
        sessionId: String,
        nowEpochMs: Long,
    ): SessionDiagnosticSnapshot {
        val workItem = kernel.store.getWorkItemBySession(sessionId) ?: kernel.store.getWorkItem(sessionId)
        val effectiveSessionId = workItem?.workerSessionId ?: sessionId
        val sqliteEvents = kernel.store.listSqliteDiagnosticEvents(effectiveSessionId, limit = 500)
        val ringEvents = kernel.store.listRingBufferDiagnosticEvents(effectiveSessionId)
        val collapsed = kernel.store.collapseDiagnosticEvents(sqliteEvents)

        val findings = linkedSetOf<String>()
        if (workItem != null) {
            if (workItem.disconnectedSinceMs != null && nowEpochMs - workItem.disconnectedSinceMs >= kernel.config.disconnectGraceMs) {
                findings.add("remote_node_disconnected")
            }
            if (workItem.state == WorkItemState.WAITING &&
                nowEpochMs - (workItem.waitingStartedAtMs ?: workItem.lastActivityAtMs) >= kernel.config.approvalStuckTimeoutMs
            ) {
                findings.add("approval_wait_timeout")
            }
            if (workItem.state == WorkItemState.STARTING &&
                nowEpochMs - (workItem.startedAtMs ?: workItem.createdAtMs) >= kernel.config.neverStartedTimeoutMs
            ) {
                findings.add("never_started")
            }
            if (workItem.state == WorkItemState.WORKING) {
                if (kernel.config.isExemptLongRunningTool(workItem.activeToolName)) {
                    val toolElapsed = nowEpochMs - (workItem.activeToolStartedAtMs ?: workItem.lastActivityAtMs)
                    if (toolElapsed >= kernel.config.longToolExemptionMs) {
                        findings.add("tool_overtime")
                    }
                } else if (nowEpochMs - workItem.lastActivityAtMs >= kernel.config.runningQuietNudgeMs) {
                    findings.add("running_quiet")
                }
            }
            if (workItem.needsYouEscalated || workItem.recoveryStage == RecoveryStage.EXHAUSTED) {
                findings.add("recovery_exhausted")
            }
            if (workItem.failureReason?.contains("mac_node_offline_timeout_24h") == true) {
                findings.add("mac_node_offline_timeout_24h")
            }
        }
        for (ev in sqliteEvents) {
            when (ev.kind) {
                "remote_node_disconnected" -> findings.add("remote_node_disconnected")
                "approval_wait_timeout" -> findings.add("approval_wait_timeout")
                "recovery_exhausted" -> findings.add("recovery_exhausted")
            }
        }

        val coverageNote = buildString {
            append("SQLite 持久化诊断表 (complete=true, events=").append(sqliteEvents.size).append("); ")
            append("内存 RingBuffer (complete=false, capacity=").append(kernel.store.ringBufferCapacity)
                .append(", retained=").append(ringEvents.size)
                .append(", absence in ring buffer is not proof)")
        }

        val nextHops = buildList {
            addAll(kernel.store.listNextHopLinks(RecallObjectKind.WORKER_SESSION, effectiveSessionId))
            if (workItem != null) {
                addAll(kernel.store.listNextHopLinks(RecallObjectKind.WORK_ITEM, workItem.workItemId))
            }
        }.distinctBy { "${it.kind}:${it.id}" }

        return SessionDiagnosticSnapshot(
            sessionId = effectiveSessionId,
            workItemId = workItem?.workItemId,
            derivedStatus = deriveSessionStatus(effectiveSessionId),
            findings = findings.toList(),
            recentCollapsedEvents = collapsed,
            coverageNote = coverageNote,
            sqliteEventCount = sqliteEvents.size,
            ringBufferEventCount = ringEvents.size,
            nextHopLinks = nextHops,
        )
    }

    suspend fun recallObject(
        kind: RecallObjectKind,
        id: String,
        inlineMaxChars: Int,
    ): RecallNodeSnapshot? {
        val cleanMax = inlineMaxChars.coerceIn(64, 4_000)
        val links = kernel.store.listNextHopLinks(kind, id)
        return when (kind) {
            RecallObjectKind.WORK_ITEM -> {
                val item = kernel.store.getWorkItem(id) ?: return null
                val full = "Title: ${item.title}\nState: ${item.state}\nOutcome: ${item.settlementOutcome.orEmpty()}\nFailure: ${item.failureReason.orEmpty()}\nBrief: ${item.brief}\nProgress: ${item.latestProgressNote.orEmpty()}"
                val safeEnd = OrchestrationHash.unicodeSafeEndOffset(full, 0, cleanMax)
                RecallNodeSnapshot(
                    kind = kind,
                    id = id,
                    title = item.title,
                    inlineText = full.substring(0, safeEnd),
                    spilled = safeEnd < full.length || item.settlementReportPath != null,
                    spillReference = item.settlementReportPath ?: item.workerSessionId,
                    nextHops = links,
                )
            }
            RecallObjectKind.WORKER_SESSION -> {
                val page = readWorkerSessionPage(id, null, pageSize = 5, maxMessageChars = cleanMax)
                val summary = page.items.joinToString("\n") { "[${it.role}] ${it.previewText}" }
                val safeEnd = OrchestrationHash.unicodeSafeEndOffset(summary, 0, cleanMax)
                RecallNodeSnapshot(
                    kind = kind,
                    id = id,
                    title = "WorkerSession $id (${page.derivedStatus})",
                    inlineText = summary.substring(0, safeEnd),
                    spilled = page.nextPageCursor != null || page.items.any { it.truncated },
                    spillReference = page.nextPageCursor,
                    nextHops = page.nextHopLinks,
                )
            }
            RecallObjectKind.THREAD -> {
                val subs = kernel.store.listActiveSubscribersForThread(id)
                val inline = "Thread $id (活跃订阅 Worker 数=${subs.size}: ${subs.joinToString { it.workItemId }})"
                RecallNodeSnapshot(
                    kind = kind,
                    id = id,
                    title = "Thread $id",
                    inlineText = inline,
                    spilled = false,
                    nextHops = links,
                )
            }
            RecallObjectKind.TRIGGER_MESSAGE -> {
                val text = kernel.store.getSourceMessageText(id) ?: return null
                val safeEnd = OrchestrationHash.unicodeSafeEndOffset(text, 0, cleanMax)
                RecallNodeSnapshot(
                    kind = kind,
                    id = id,
                    title = "TriggerMessage $id",
                    inlineText = text.substring(0, safeEnd),
                    spilled = safeEnd < text.length,
                    nextHops = links,
                )
            }
            RecallObjectKind.ARCHIVE_DOCUMENT -> {
                val text = kernel.store.readArchivedDocumentText(id) ?: return null
                val safeEnd = OrchestrationHash.unicodeSafeEndOffset(text, 0, cleanMax)
                RecallNodeSnapshot(
                    kind = kind,
                    id = id,
                    title = "ArchiveDocument $id",
                    inlineText = text.substring(0, safeEnd),
                    spilled = safeEnd < text.length,
                    spillReference = id,
                    nextHops = links,
                )
            }
            RecallObjectKind.BATCH -> {
                val items = kernel.store.listWorkItemsByBatch(id)
                if (items.isEmpty()) return null
                val summary = items.joinToString("\n") { "${it.workItemId} (${it.taskKey}): ${it.state}" }
                RecallNodeSnapshot(
                    kind = kind,
                    id = id,
                    title = "Batch $id",
                    inlineText = summary,
                    spilled = false,
                    spillReference = "rollups/$id.md",
                    nextHops = links,
                )
            }
        }
    }
}
