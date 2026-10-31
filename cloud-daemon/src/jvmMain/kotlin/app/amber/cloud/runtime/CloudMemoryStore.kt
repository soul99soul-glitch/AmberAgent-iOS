package app.amber.cloud.runtime

import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.PlaceholderCredentialException
import app.amber.core.memory.model.MemoryRecord
import app.amber.core.model.DEFAULT_ASSISTANT_ID
import app.amber.core.model.MemoryKind
import app.amber.core.model.MemoryScope
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * Persistent memory and identity (`SOUL.md` + `memories.json`) store for `amberd`.
 *
 * - Survives daemon restarts.
 * - Scrubs credentials via [CredentialRedactor] before persisting and rejects placeholder credentials.
 */
class CloudMemoryStore(
    private val memoryDir: File,
) {
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true; encodeDefaults = true }
    private val memoriesFile = File(memoryDir, "memories.json")
    private val soulFile = File(memoryDir, "SOUL.md")

    init {
        memoryDir.mkdirs()
        if (!soulFile.exists()) {
            soulFile.writeText(DEFAULT_SOUL_MARKDOWN)
        }
    }

    @Synchronized
    fun loadSoulPrompt(): String {
        if (!soulFile.exists()) return DEFAULT_SOUL_MARKDOWN
        return soulFile.readText().ifBlank { DEFAULT_SOUL_MARKDOWN }
    }

    @Synchronized
    fun saveSoulPrompt(markdown: String) {
        val safe = CredentialRedactor.redact(markdown)
        atomicWrite(soulFile, safe)
    }

    @Synchronized
    fun listMemories(includeArchived: Boolean = false): List<MemoryRecord> {
        if (!memoriesFile.exists()) return emptyList()
        val all = runCatching {
            json.decodeFromString<List<MemoryRecord>>(memoriesFile.readText())
        }.getOrDefault(emptyList())
        return if (includeArchived) all else all.filterNot { it.archived }
    }

    @Synchronized
    fun upsertMemory(
        content: String,
        scope: MemoryScope = MemoryScope.LONG_TERM,
        kind: MemoryKind = MemoryKind.NOTE,
        sourceConversationId: String? = null,
        pinned: Boolean = false,
    ): MemoryRecord {
        if (CredentialRedactor.isPlaceholderCredential(content)) {
            throw PlaceholderCredentialException("拒绝将占位符凭据写入长期记忆")
        }
        val redactedContent = CredentialRedactor.redact(content.trim())
        require(redactedContent.isNotEmpty()) { "记忆内容不能为空" }

        val current = listMemories(includeArchived = true).toMutableList()
        val now = System.currentTimeMillis()
        val existingIndex = current.indexOfFirst {
            !it.archived && it.content.equals(redactedContent, ignoreCase = true) && it.scope == scope
        }
        val record = if (existingIndex >= 0) {
            val existing = current[existingIndex]
            existing.copy(
                updatedAt = now,
                lastReinforcedAt = now,
                pinned = pinned || existing.pinned,
            ).also { current[existingIndex] = it }
        } else {
            val nextId = (current.maxOfOrNull { it.id } ?: 0) + 1
            MemoryRecord(
                id = nextId,
                content = redactedContent,
                scope = scope,
                kind = kind,
                assistantId = DEFAULT_ASSISTANT_ID.toString(),
                sourceConversationId = sourceConversationId,
                pinned = pinned,
                createdAt = now,
                updatedAt = now,
            ).also { current.add(it) }
        }
        persistMemories(current)
        return record
    }

    @Synchronized
    fun recallForPrompt(query: String, limit: Int = 8): List<MemoryRecord> {
        val active = listMemories(includeArchived = false)
        if (active.isEmpty()) return emptyList()
        val terms = query.lowercase().split(Regex("""\s+""")).filter { it.length >= 2 }
        return active.sortedWith(
            compareByDescending<MemoryRecord> { it.scope == MemoryScope.CORE || it.pinned }
                .thenByDescending { record ->
                    terms.count { term -> record.content.lowercase().contains(term) }
                }
                .thenByDescending { it.updatedAt }
        ).take(limit)
    }

    private fun persistMemories(records: List<MemoryRecord>) {
        memoryDir.mkdirs()
        atomicWrite(memoriesFile, json.encodeToString(records))
    }

    private fun atomicWrite(target: File, content: String) {
        target.parentFile?.mkdirs()
        val tmp = File(target.parentFile, "${target.name}.tmp")
        tmp.writeText(content)
        Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    companion object {
        const val DEFAULT_SOUL_MARKDOWN = """
# Amber Cloud Self (SOUL.md)
你是 Amber，用户的跨端个人 AI 智能体与云端常驻本体。
- 保持简洁、可靠、实事求是。
- 严禁泄露或回显任何密钥、令牌或密码。
- 高风险操作必须等待用户在已配对且已解锁的原生 App 前台核对批准。
"""
    }
}
