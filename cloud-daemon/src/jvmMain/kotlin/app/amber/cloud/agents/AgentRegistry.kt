package app.amber.cloud.agents

import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import androidx.sqlite.execSQL
import app.amber.cloud.orchestration.CloudOrchestrationStore
import app.amber.cloud.orchestration.CloudPrincipal
import app.amber.cloud.orchestration.PrincipalPermissionException
import app.amber.cloud.security.CredentialRedactor
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.Closeable
import java.io.File
import java.util.UUID

/** SQLite owns profile revisions and the proposal -> owner-confirmed creation transition. */
class AgentRegistry(
    dataDir: File,
    private val sources: CloudOrchestrationStore,
    private val ownerGrantedTools: () -> Set<String>,
    private val modelPreferences: () -> Set<String> = { emptySet() },
) : Closeable {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    private val db = BundledSQLiteDriver().open(File(dataDir.also { it.mkdirs() }, "agents.db").absolutePath)

    init {
        db.execSQL("PRAGMA journal_mode = WAL")
        db.execSQL("PRAGMA busy_timeout = 5000")
        db.execSQL("CREATE TABLE IF NOT EXISTS agents (id TEXT PRIMARY KEY, revision INTEGER NOT NULL, profile_json TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS agent_proposals (id TEXT PRIMARY KEY, proposal_json TEXT NOT NULL, confirmed INTEGER NOT NULL DEFAULT 0)")
        val main = AgentProfile(MAIN_AGENT_ID, "Amber", revision = 1)
        db.prepare("INSERT OR IGNORE INTO agents VALUES (?, ?, ?)").use {
            it.bindText(1, main.id); it.bindLong(2, 1); it.bindText(3, json.encodeToString(main)); it.step()
        }
    }

    @Synchronized
    fun get(id: String): AgentProfile? = db.prepare("SELECT profile_json FROM agents WHERE id = ?").use {
        it.bindText(1, id)
        if (it.step()) json.decodeFromString<AgentProfile>(it.getText(0)) else null
    }

    @Synchronized
    fun list(): List<AgentProfile> = db.prepare("SELECT profile_json FROM agents ORDER BY id").use {
        buildList { while (it.step()) add(json.decodeFromString<AgentProfile>(it.getText(0))) }
    }

    @Synchronized
    fun save(principal: CloudPrincipal, profile: AgentProfile, expectedRevision: Int): AgentProfile {
        requireOwner(principal)
        return transaction { saveProfile(profile, expectedRevision) }
    }

    private fun saveProfile(profile: AgentProfile, expectedRevision: Int): AgentProfile {
        val current = get(profile.id)
        if ((current?.revision ?: 0) != expectedRevision) throw AgentRevisionConflict("Agent revision conflict")
        require(profile.id != MAIN_AGENT_ID) { "主 Router 的身份与权限由宿主管理" }
        val safe = validate(profile).copy(revision = expectedRevision + 1)
        db.prepare("INSERT INTO agents VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET revision = excluded.revision, profile_json = excluded.profile_json").use {
            it.bindText(1, safe.id); it.bindLong(2, safe.revision.toLong()); it.bindText(3, json.encodeToString(safe)); it.step()
        }
        return safe
    }

    @Synchronized
    fun propose(principal: CloudPrincipal, profile: AgentProfile, sourceMessageIds: List<String>, nowMs: Long = System.currentTimeMillis()): AgentProposal {
        if (principal !is CloudPrincipal.CloudCoordinator || principal.principalId != "coordinator:main") {
            throw PrincipalPermissionException("只有主 Router 可以提议创建 agent")
        }
        sources.resolveAuthorizedSourceMessages(sourceMessageIds)
        require(get(profile.id) == null && profile.id != MAIN_AGENT_ID) { "Agent 已存在" }
        val proposal = AgentProposal(UUID.randomUUID().toString(), validate(profile).copy(revision = 0), sourceMessageIds, nowMs)
        db.prepare("INSERT INTO agent_proposals (id, proposal_json) VALUES (?, ?)").use {
            it.bindText(1, proposal.id); it.bindText(2, json.encodeToString(proposal)); it.step()
        }
        return proposal
    }

    @Synchronized
    fun pendingProposals(): List<AgentProposal> = db.prepare("SELECT proposal_json FROM agent_proposals WHERE confirmed = 0 ORDER BY id").use {
        buildList { while (it.step()) add(json.decodeFromString<AgentProposal>(it.getText(0))) }
    }

    /** A later, separate owner message must confirm the exact immutable proposal ID. */
    @Synchronized
    fun confirm(principal: CloudPrincipal, proposalId: String, confirmationMessageId: String): AgentProfile {
        requireOwner(principal)
        val source = sources.resolveAuthorizedSourceMessages(listOf(confirmationMessageId)).single()
        return transaction {
            val proposal = db.prepare("SELECT proposal_json FROM agent_proposals WHERE id = ? AND confirmed = 0").use {
                it.bindText(1, proposalId)
                if (!it.step()) throw AgentRevisionConflict("提议不存在或已经确认")
                json.decodeFromString<AgentProposal>(it.getText(0))
            }
            require(confirmationMessageId !in proposal.sourceMessageIds && source.createdAtEpochMs >= proposal.createdAtMs) { "需要提议后的独立主人确认" }
            require(sources.getSourceMessageText(confirmationMessageId)?.trim() == "确认创建 agent $proposalId") { "确认消息须指定完整提议 ID" }
            val saved = saveProfile(proposal.profile, 0)
            db.prepare("UPDATE agent_proposals SET confirmed = 1 WHERE id = ?").use { it.bindText(1, proposalId); it.step() }
            saved
        }
    }

    fun effectiveTools(profile: AgentProfile): Set<String> =
        if (profile.id == MAIN_AGENT_ID) ownerGrantedTools() else profile.toolScope.intersect(ownerGrantedTools())

    private fun requireOwner(principal: CloudPrincipal) {
        if (principal !is CloudPrincipal.OwnerUser) throw PrincipalPermissionException("只有主人可以创建或修改 agent")
    }

    private fun validate(profile: AgentProfile): AgentProfile {
        require(Regex("[a-z][a-z0-9.-]{0,63}").matches(profile.id) && profile.id != GLOBAL_MEMORY_AGENT_ID) { "无效的 agent id" }
        require(profile.name.isNotBlank() && profile.name.length <= 80 && '@' !in profile.name) { "无效的 agent 名称" }
        require(profile.instructions.length <= 32_768 && profile.routingKeywords.size <= 32 && profile.tags.size <= 32)
        require(ownerGrantedTools().containsAll(profile.toolScope)) { "toolScope 只能是主人授权范围的子集" }
        require(profile.modelPreference == null || profile.modelPreference in modelPreferences()) { "模型偏好必须指向宿主已配置的模型" }
        require(list().none { it.id != profile.id && it.name.equals(profile.name, ignoreCase = true) }) { "Agent 名称已存在" }
        val safeName = CredentialRedactor.redact(profile.name.trim())
        require(safeName.replace(CredentialRedactor.MASK, "").isNotBlank()) { "Agent 名称不能仅包含凭据" }
        return profile.copy(
            name = safeName, instructions = CredentialRedactor.redact(profile.instructions),
            tags = profile.tags.map(CredentialRedactor::redact).distinct(),
            routingKeywords = profile.routingKeywords.map { CredentialRedactor.redact(it.trim()) }.filter { it.isNotEmpty() }.distinct(),
        )
    }

    private fun <T> transaction(action: () -> T): T {
        db.execSQL("BEGIN IMMEDIATE")
        try {
            val result = action()
            db.execSQL("COMMIT")
            return result
        } catch (t: Throwable) {
            db.execSQL("ROLLBACK")
            throw t
        }
    }

    @Synchronized override fun close() = db.close()
}
