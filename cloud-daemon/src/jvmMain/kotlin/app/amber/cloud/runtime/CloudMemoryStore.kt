package app.amber.cloud.runtime

import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.PlaceholderCredentialException
import app.amber.cloud.agents.AgentMemoryPolicy
import app.amber.cloud.agents.GLOBAL_MEMORY_AGENT_ID
import app.amber.core.memory.model.MemoryRecord
import app.amber.core.model.DEFAULT_ASSISTANT_ID
import app.amber.core.model.MemoryKind
import app.amber.core.model.MemoryScope
import kotlinx.serialization.encodeToString
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

@Serializable
private data class ScopedCloudMemory(val agentId: String, val record: MemoryRecord, val tags: List<String> = emptyList())

/**
 * Persistent memory and identity (`SOUL.md` + `memories.json`) store for `amberd`.
 *
 * - Survives daemon restarts.
 * - Scrubs credentials via [CredentialRedactor] before persisting and rejects placeholder credentials.
 */
class CloudMemoryStore(
    private val memoryDir: File,
    var onSoulPromptSaved: ((String) -> Unit)? = null,
) {
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true; encodeDefaults = true }
    private val memoriesFile = File(memoryDir, "memories.json")
    private val scopedMemoriesFile = File(memoryDir, "agent-memories.json")
    private val soulFile = File(memoryDir, "SOUL.md")

    init {
        memoryDir.mkdirs()
        if (!soulFile.exists()) {
            soulFile.writeText(DEFAULT_SOUL_MARKDOWN)
        }
    }

    @Synchronized
    fun loadSoulPrompt(memoryPolicy: AgentMemoryPolicy = AgentMemoryPolicy.SHARED_WITH_GLOBAL): String {
        if (memoryPolicy == AgentMemoryPolicy.HUB_ISOLATED) return DEFAULT_SOUL_MARKDOWN
        if (!soulFile.exists()) return DEFAULT_SOUL_MARKDOWN
        return soulFile.readText().ifBlank { DEFAULT_SOUL_MARKDOWN }
    }

    @Synchronized
    fun saveSoulPrompt(markdown: String) {
        val safe = CredentialRedactor.redact(markdown)
        atomicWrite(soulFile, safe)
        onSoulPromptSaved?.invoke(safe)
    }

    @Synchronized
    fun listMemories(includeArchived: Boolean = false, agentId: String = GLOBAL_MEMORY_AGENT_ID): List<MemoryRecord> {
        val all = loadAll().filter { it.agentId == agentId }.map { it.record }
        return if (includeArchived) all else all.filterNot { it.archived }
    }

    private fun loadAll(): List<ScopedCloudMemory> = when {
        scopedMemoriesFile.exists() -> json.decodeFromString(scopedMemoriesFile.readText())
        memoriesFile.exists() -> json.decodeFromString<List<MemoryRecord>>(memoriesFile.readText()).map { ScopedCloudMemory(GLOBAL_MEMORY_AGENT_ID, it) }
        else -> emptyList()
    }

    @Synchronized
    fun upsertMemory(
        content: String,
        scope: MemoryScope = MemoryScope.LONG_TERM,
        kind: MemoryKind = MemoryKind.NOTE,
        sourceConversationId: String? = null,
        pinned: Boolean = false,
        agentId: String = GLOBAL_MEMORY_AGENT_ID,
        tags: List<String> = emptyList(),
    ): MemoryRecord {
        if (CredentialRedactor.isPlaceholderCredential(content)) {
            throw PlaceholderCredentialException("拒绝将占位符凭据写入长期记忆")
        }
        val redactedContent = CredentialRedactor.redact(content.trim())
        require(redactedContent.isNotEmpty()) { "记忆内容不能为空" }

        require(agentId.isNotBlank())
        val current = loadAll().toMutableList()
        val now = System.currentTimeMillis()
        val existingIndex = current.indexOfFirst {
            it.agentId == agentId && !it.record.archived && it.record.content.equals(redactedContent, ignoreCase = true) && it.record.scope == scope
        }
        val record = if (existingIndex >= 0) {
            val existing = current[existingIndex].record
            existing.copy(
                updatedAt = now,
                lastReinforcedAt = now,
                pinned = pinned || existing.pinned,
            ).also { current[existingIndex] = ScopedCloudMemory(agentId, it, tags.map(CredentialRedactor::redact)) }
        } else {
            val nextId = (current.maxOfOrNull { it.record.id } ?: 0) + 1
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
            ).also { current.add(ScopedCloudMemory(agentId, it, tags.map(CredentialRedactor::redact))) }
        }
        persistMemories(current)
        return record
    }

    @Synchronized
    fun recallForPrompt(
        query: String, limit: Int = 8, agentId: String = GLOBAL_MEMORY_AGENT_ID,
        memoryPolicy: AgentMemoryPolicy = AgentMemoryPolicy.SHARED_WITH_GLOBAL,
    ): List<MemoryRecord> {
        val local = listMemories(agentId = agentId)
        val global = if (agentId != GLOBAL_MEMORY_AGENT_ID && memoryPolicy == AgentMemoryPolicy.SHARED_WITH_GLOBAL) {
            listMemories().filter { it.scope == MemoryScope.CORE || it.kind == MemoryKind.USER || it.pinned }
        } else emptyList()
        val active = local + global
        val localIds = local.map { it.id }.toSet()
        if (active.isEmpty()) return emptyList()
        val terms = query.lowercase().split(Regex("""\s+""")).filter { it.length >= 2 }
        return active.sortedWith(
            compareByDescending<MemoryRecord> { it.id in localIds }
                .thenByDescending { it.scope == MemoryScope.CORE || it.pinned }
                .thenByDescending { record ->
                    terms.count { term -> record.content.lowercase().contains(term) }
                }
                .thenByDescending { it.updatedAt }
        ).take(limit)
    }

    private fun persistMemories(records: List<ScopedCloudMemory>) {
        memoryDir.mkdirs()
        atomicWrite(scopedMemoriesFile, json.encodeToString(records))
    }

    @Synchronized
    fun moveConversationMemories(conversationIds: Set<String>, fromAgentId: String, toAgentId: String) {
        if (conversationIds.isEmpty()) return
        val current = loadAll()
        val moved = current.map { entry ->
            if (entry.agentId == fromAgentId && entry.record.sourceConversationId in conversationIds) entry.copy(agentId = toAgentId) else entry
        }
        if (moved != current) persistMemories(moved)
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
