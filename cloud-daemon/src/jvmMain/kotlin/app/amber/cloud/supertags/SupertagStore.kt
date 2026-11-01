package app.amber.cloud.supertags

import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import androidx.sqlite.execSQL
import app.amber.cloud.agents.GLOBAL_MEMORY_AGENT_ID
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.security.CredentialRedactor
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import java.io.Closeable
import java.io.File
import java.util.UUID

/** One SQLite transaction owns tags, observations, negative feedback and suggestion events. */
class SupertagStore(dataDir: File, nowMs: Long = System.currentTimeMillis()) : Closeable {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    private val db = BundledSQLiteDriver().open(File(dataDir.also { it.mkdirs() }, "supertags.db").absolutePath)

    init {
        db.execSQL("PRAGMA journal_mode = WAL")
        db.execSQL("PRAGMA busy_timeout = 5000")
        db.execSQL("CREATE TABLE IF NOT EXISTS conversation_tags (conversation_id TEXT, scope_id TEXT, name TEXT, body TEXT NOT NULL, PRIMARY KEY(conversation_id, scope_id, name))")
        db.execSQL("CREATE TABLE IF NOT EXISTS tag_feedback (conversation_id TEXT, scope_id TEXT, name TEXT, PRIMARY KEY(conversation_id, scope_id, name))")
        db.execSQL("CREATE TABLE IF NOT EXISTS tagged_turns (turn_id TEXT, scope_id TEXT, PRIMARY KEY(turn_id, scope_id))")
        db.execSQL("CREATE TABLE IF NOT EXISTS pending_tag_turns (turn_id TEXT, scope_id TEXT, body TEXT NOT NULL, PRIMARY KEY(turn_id, scope_id))")
        db.execSQL("CREATE TABLE IF NOT EXISTS tag_observations (turn_id TEXT, conversation_id TEXT, scope_id TEXT, name TEXT, observed_at INTEGER, body TEXT NOT NULL, PRIMARY KEY(turn_id, scope_id, name))")
        db.execSQL("CREATE INDEX IF NOT EXISTS tag_observation_window ON tag_observations(scope_id, observed_at)")
        db.execSQL("CREATE TABLE IF NOT EXISTS tag_templates (id TEXT PRIMARY KEY, body TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS hub_promotions (collection_id TEXT PRIMARY KEY, body TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS hub_focus (conversation_id TEXT PRIMARY KEY, agent_id TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS conversation_hubs (conversation_id TEXT PRIMARY KEY, agent_id TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS supertag_events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, subject_id TEXT NOT NULL, created_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS supertag_maintenance (name TEXT PRIMARY KEY, last_run INTEGER NOT NULL)")
        seedTemplates(nowMs).forEach { execute("INSERT OR IGNORE INTO tag_templates VALUES (?, ?)", it.id, json.encodeToString(it)) }
    }

    @Synchronized
    fun tags(conversationId: String? = null, scopeId: String = GLOBAL_MEMORY_AGENT_ID): List<ConversationTag> =
        if (conversationId == null) read("SELECT body FROM conversation_tags WHERE scope_id = ? ORDER BY name, conversation_id", scopeId)
        else read("SELECT body FROM conversation_tags WHERE scope_id = ? AND conversation_id = ? ORDER BY name", scopeId, conversationId)

    @Synchronized
    fun observations(sinceMs: Long): List<TagObservation> = read("SELECT body FROM tag_observations WHERE observed_at >= ? ORDER BY observed_at", sinceMs)

    @Synchronized
    fun templates(includeInactive: Boolean = false): List<TagTemplate> = read<TagTemplate>("SELECT body FROM tag_templates ORDER BY id")
        .filter { includeInactive || (!it.archived && !it.deleted && it.mergedInto == null) }

    @Synchronized
    fun template(id: String): TagTemplate? = read<TagTemplate>("SELECT body FROM tag_templates WHERE id = ?", id).singleOrNull()

    private fun putTemplate(template: TagTemplate) = execute("INSERT INTO tag_templates VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET body = excluded.body", template.id, json.encodeToString(template))

    @Synchronized
    fun applyTags(conversationId: String, scopeId: String, turnId: String, candidates: List<TagCandidate>, nowMs: Long): List<ConversationTag> = transaction {
        applyTagsInTransaction(conversationId, scopeId, turnId, candidates, nowMs)
    }

    private fun applyTagsInTransaction(conversationId: String, scopeId: String, turnId: String, candidates: List<TagCandidate>, nowMs: Long): List<ConversationTag> {
        if (isTagged(turnId, scopeId)) return tags(conversationId, scopeId)
        candidates.take(3).forEach { candidate ->
            val safe = sanitize(candidate)
            if (exists("SELECT 1 FROM tag_feedback WHERE conversation_id = ? AND scope_id = ? AND name = ?", conversationId, scopeId, safe.name)) return@forEach
            val old = tags(conversationId, scopeId).firstOrNull { it.name == safe.name }
            if (old?.userModified == true) return@forEach
            val catalog = templates().filter { it.scopeId == scopeId || it.scopeId == GLOBAL_MEMORY_AGENT_ID }
            val canonicalId = safe.templateId?.let { id -> generateSequence(template(id)) { it.mergedInto?.let(::template) }.lastOrNull()?.id }
            val schema = catalog.firstOrNull { it.id == canonicalId }
                ?: catalog.firstOrNull { it.name == safe.name || safe.name in it.aliases }
            val attrs = if (schema == null) safe.attributes else safe.attributes.filter { (key, value) -> schema.fields.any { it.name == key && it.type == value.type } }
            val tag = ConversationTag(conversationId, scopeId, safe.name, schema?.id, attrs, updatedAtMs = nowMs)
            putTag(tag)
            val observation = TagObservation(turnId, tag, nowMs)
            execute("INSERT OR IGNORE INTO tag_observations VALUES (?, ?, ?, ?, ?, ?)", turnId, conversationId, scopeId, tag.name, nowMs, json.encodeToString(observation))
            schema?.let { putTemplate(it.copy(lastUsedAtMs = maxOf(it.lastUsedAtMs, nowMs))) }
        }
        refreshPromotions(nowMs)
        execute("INSERT INTO tagged_turns VALUES (?, ?)", turnId, scopeId)
        event("conversation.tags_updated", conversationId, nowMs)
        return tags(conversationId, scopeId)
    }

    @Synchronized
    fun isTagged(turnId: String, scopeId: String): Boolean = exists("SELECT 1 FROM tagged_turns WHERE turn_id = ? AND scope_id = ?", turnId, scopeId)

    @Synchronized
    fun acceptTaggingTurn(turn: PendingTaggingTurn): Boolean = transaction {
        if (isTagged(turn.turnId, turn.scopeId)) return@transaction false
        val safe = turn.copy(text = CredentialRedactor.redact(turn.text).take(12_000))
        execute("INSERT OR IGNORE INTO pending_tag_turns VALUES (?, ?, ?)", safe.turnId, safe.scopeId, json.encodeToString(safe))
        true
    }

    @Synchronized
    fun pendingTaggingTurns(): List<PendingTaggingTurn> = read("SELECT body FROM pending_tag_turns ORDER BY rowid")

    @Synchronized
    fun discardTaggingTurn(turn: PendingTaggingTurn) = execute("DELETE FROM pending_tag_turns WHERE turn_id = ? AND scope_id = ?", turn.turnId, turn.scopeId)

    /** Extraction output, completion marker and queue removal commit together, including empty results. */
    @Synchronized
    fun completeTaggingTurn(turn: PendingTaggingTurn, tags: List<TagCandidate>, nowMs: Long) = transaction {
        // Owner promotion may have moved this turn into another scope while the model was running.
        if (exists("SELECT 1 FROM pending_tag_turns WHERE turn_id = ? AND scope_id = ?", turn.turnId, turn.scopeId)) {
            applyTagsInTransaction(turn.conversationId, turn.scopeId, turn.turnId, tags, nowMs)
            discardTaggingTurn(turn)
        }
    }

    @Synchronized
    fun editTag(conversationId: String, scopeId: String, candidate: TagCandidate, nowMs: Long): ConversationTag = transaction {
        val safe = sanitize(candidate)
        val schema = safe.templateId?.let { id -> templates().firstOrNull { it.id == id && it.scopeId in setOf(scopeId, GLOBAL_MEMORY_AGENT_ID) } ?: throw SupertagNotFound("模板不存在") }
        require(schema == null || safe.attributes.all { (key, value) -> schema.fields.any { it.name == key && it.type == value.type } })
        val tag = ConversationTag(conversationId, scopeId, safe.name, schema?.id, safe.attributes, userModified = true, updatedAtMs = nowMs)
        execute("DELETE FROM tag_feedback WHERE conversation_id = ? AND scope_id = ? AND name = ?", conversationId, scopeId, tag.name)
        putTag(tag)
        // An owner correction replaces the old extraction evidence too.
        execute("DELETE FROM tag_observations WHERE conversation_id = ? AND scope_id = ? AND name = ?", conversationId, scopeId, tag.name)
        val observation = TagObservation("owner:$conversationId:${tag.name}", tag, nowMs)
        execute("INSERT INTO tag_observations VALUES (?, ?, ?, ?, ?, ?)", observation.turnId, conversationId, scopeId, tag.name, nowMs, json.encodeToString(observation))
        schema?.let { putTemplate(it.copy(lastUsedAtMs = maxOf(it.lastUsedAtMs, nowMs))) }
        refreshPromotions(nowMs)
        event("conversation.tags_updated", conversationId, nowMs)
        tag
    }

    @Synchronized
    fun removeTag(conversationId: String, scopeId: String, name: String, nowMs: Long) = transaction {
        val normalized = normalizeTag(name)
        execute("INSERT OR IGNORE INTO tag_feedback VALUES (?, ?, ?)", conversationId, scopeId, normalized)
        execute("DELETE FROM conversation_tags WHERE conversation_id = ? AND scope_id = ? AND name = ?", conversationId, scopeId, normalized)
        execute("DELETE FROM tag_observations WHERE conversation_id = ? AND scope_id = ? AND name = ?", conversationId, scopeId, normalized)
        event("conversation.tags_updated", conversationId, nowMs)
    }

    private fun putTag(tag: ConversationTag) = execute("INSERT INTO conversation_tags VALUES (?, ?, ?, ?) ON CONFLICT(conversation_id, scope_id, name) DO UPDATE SET body = excluded.body", tag.conversationId, tag.scopeId, tag.name, json.encodeToString(tag))

    @Synchronized
    fun collections(scopeId: String, nowMs: Long): List<TagCollection> = recentCollections(nowMs, scopeId)

    private fun recentCollections(nowMs: Long, scopeId: String? = null): List<TagCollection> {
        val promotions = promotions().associateBy { it.collectionId }
        val rows = if (scopeId == null) observations(nowMs - 14 * DAY_MS)
            else read<TagObservation>("SELECT body FROM tag_observations WHERE scope_id = ? AND observed_at >= ?", scopeId, nowMs - 14 * DAY_MS)
        return rows.filter { it.observedAtMs <= nowMs }.groupBy { it.tag.scopeId to it.tag.name }.map { (key, members) ->
                val (scope, tag) = key
                val id = collectionId(scope, tag)
                val promotion = promotions[id]
                TagCollection(id, scope, tag, members.map { it.tag.conversationId }.distinct().sorted(), promotion?.id, promotion?.hubId)
            }.sortedBy { it.tag }
    }

    private fun refreshPromotions(nowMs: Long) {
        recentCollections(nowMs).filter { it.conversationIds.size >= 4 && it.promotionId == null }.forEach { collection ->
            val promotion = HubPromotion(UUID.randomUUID().toString(), collection.id, collection.scopeId, collection.tag, collection.conversationIds, nowMs)
            execute("INSERT INTO hub_promotions VALUES (?, ?)", collection.id, json.encodeToString(promotion))
            event("hub.promotion_suggested", promotion.id, nowMs)
        }
    }

    @Synchronized
    fun promotions(): List<HubPromotion> = read("SELECT body FROM hub_promotions ORDER BY collection_id")

    /** Called only by the owner-confirmation service. Repeating the same confirmation is idempotent. */
    @Synchronized
    fun confirmPromotion(id: String, createHub: (HubPromotion) -> String, nowMs: Long): HubPromotion = transaction {
        val promotion = promotions().firstOrNull { it.id == id } ?: throw SupertagNotFound("升级提示不存在")
        if (promotion.hubId != null) return@transaction promotion
        val live = collections(promotion.scopeId, nowMs).firstOrNull { it.id == promotion.collectionId && it.conversationIds.size >= 4 }
            ?: throw SupertagConflict("合集已不满足升级阈值")
        val current = promotion.copy(conversationIds = live.conversationIds)
        val confirmed = current.copy(hubId = createHub(current))
        execute("UPDATE hub_promotions SET body = ? WHERE collection_id = ?", json.encodeToString(confirmed), promotion.collectionId)
        confirmed.conversationIds.filter { it != PRIMARY_CONVERSATION_ID.toString() }.forEach { conversationId ->
            moveTagsToHub(conversationId, confirmed.scopeId, confirmed.hubId!!)
            bindConversation(conversationId, confirmed.hubId)
        }
        event("hub.promoted", confirmed.hubId!!, nowMs)
        confirmed
    }

    private fun moveTagsToHub(conversationId: String, fromScope: String, hubId: String) {
        fun moved(tag: ConversationTag): ConversationTag {
            val schema = tag.templateId?.let(::template)
            return tag.copy(scopeId = hubId, templateId = schema?.takeIf { it.scopeId == GLOBAL_MEMORY_AGENT_ID }?.id)
        }
        tags(conversationId, fromScope).forEach { putTag(moved(it)) }
        val samples = read<TagObservation>("SELECT body FROM tag_observations WHERE conversation_id = ? AND scope_id = ?", conversationId, fromScope)
        samples.forEach { sample ->
            val updated = sample.copy(tag = moved(sample.tag))
            execute("INSERT OR IGNORE INTO tag_observations VALUES (?, ?, ?, ?, ?, ?)", sample.turnId, conversationId, hubId, sample.tag.name, sample.observedAtMs, json.encodeToString(updated))
        }
        pendingTaggingTurns().filter { it.conversationId == conversationId && it.scopeId == fromScope }.forEach { pending ->
            val moved = pending.copy(scopeId = hubId)
            execute("INSERT OR IGNORE INTO pending_tag_turns VALUES (?, ?, ?)", moved.turnId, moved.scopeId, json.encodeToString(moved))
            discardTaggingTurn(pending)
        }
        execute("INSERT OR IGNORE INTO tag_feedback SELECT conversation_id, ?, name FROM tag_feedback WHERE conversation_id = ? AND scope_id = ?", hubId, conversationId, fromScope)
        execute("DELETE FROM conversation_tags WHERE conversation_id = ? AND scope_id = ?", conversationId, fromScope)
        execute("DELETE FROM tag_observations WHERE conversation_id = ? AND scope_id = ?", conversationId, fromScope)
        execute("DELETE FROM tag_feedback WHERE conversation_id = ? AND scope_id = ?", conversationId, fromScope)
    }

    @Synchronized
    fun focusedHub(conversationId: String): String? = db.prepare("SELECT agent_id FROM hub_focus WHERE conversation_id = ?").use {
        it.bindText(1, conversationId); if (it.step()) it.getText(0) else null
    }

    @Synchronized
    fun focus(conversationId: String, agentId: String?) {
        if (agentId == null) execute("DELETE FROM hub_focus WHERE conversation_id = ?", conversationId)
        else execute("INSERT INTO hub_focus VALUES (?, ?) ON CONFLICT(conversation_id) DO UPDATE SET agent_id = excluded.agent_id", conversationId, agentId)
    }

    @Synchronized
    fun bindConversation(conversationId: String, agentId: String) = execute("INSERT INTO conversation_hubs VALUES (?, ?) ON CONFLICT(conversation_id) DO UPDATE SET agent_id = excluded.agent_id", conversationId, agentId)

    @Synchronized
    fun conversationHub(conversationId: String): String? = db.prepare("SELECT agent_id FROM conversation_hubs WHERE conversation_id = ?").use {
        it.bindText(1, conversationId); if (it.step()) it.getText(0) else null
    }

    @Synchronized
    fun createEvolvedTemplate(template: TagTemplate): Boolean = transaction {
        if (templates().size >= 30 || templates(true).any { it.scopeId == template.scopeId && (it.name == template.name || template.name in it.aliases) }) return@transaction false
        putTemplate(template)
        // Reclassify existing extraction without overwriting owner-edited attributes.
        tags(scopeId = template.scopeId).filter { it.name == template.name && !it.userModified && it.templateId == null }.forEach { tag ->
            putTag(tag.copy(templateId = template.id, attributes = tag.attributes.filter { (key, value) -> template.fields.any { it.name == key && it.type == value.type } }))
        }
        event("tag_template.created", template.id, template.createdAtMs)
        true
    }

    @Synchronized
    fun editTemplate(id: String, revision: Int, name: String? = null, archived: Boolean? = null, delete: Boolean = false, nowMs: Long): TagTemplate = transaction {
        val old = template(id) ?: throw SupertagNotFound("模板不存在")
        if (old.revision != revision || old.deleted || old.mergedInto != null) throw SupertagConflict("模板 revision 冲突")
        val normalized = name?.let { sanitize(TagCandidate(it)).name } ?: old.name
        require(templates(true).none { it.id != id && it.scopeId == old.scopeId && (it.name == normalized || normalized in it.aliases) }) { "模板名称已存在" }
        if (archived == false && old.archived && templates().size >= 30) throw SupertagConflict("活跃模板已达上限")
        val updated = old.copy(name = normalized, aliases = (old.aliases + old.name).filter { it != normalized }.distinct(), archived = archived ?: old.archived,
            deleted = delete, userModified = true, revision = old.revision + 1, lastUsedAtMs = nowMs)
        putTemplate(updated)
        if (delete) tags(scopeId = old.scopeId).filter { it.templateId == old.id }.forEach { putTag(it.copy(templateId = null)) }
        event("tag_template.updated", id, nowMs)
        updated
    }

    @Synchronized
    fun mergeTemplates(sourceId: String, targetId: String, sourceRevision: Int, targetRevision: Int, byUser: Boolean, nowMs: Long): TagTemplate = transaction {
        val source = template(sourceId) ?: throw SupertagNotFound("模板不存在")
        val target = template(targetId) ?: throw SupertagNotFound("模板不存在")
        if (source.revision != sourceRevision || target.revision != targetRevision) throw SupertagConflict("模板 revision 冲突")
        require(source.id != target.id && source.scopeId == target.scopeId && !source.deleted && !target.deleted && source.mergedInto == null && target.mergedInto == null)
        if (!byUser && (source.userModified || target.userModified)) throw SupertagConflict("用户修改优先")
        require(source.fields.none { from -> target.fields.any { it.name == from.name && it.type != from.type } }) { "字段类型冲突" }
        val result = target.copy(fields = (target.fields + source.fields).distinct(), aliases = (target.aliases + source.aliases + source.name).distinct().filter { it != target.name },
            userModified = byUser || target.userModified, revision = target.revision + 1, lastUsedAtMs = if (byUser) nowMs else maxOf(target.lastUsedAtMs, source.lastUsedAtMs))
        putTemplate(result)
        putTemplate(source.copy(mergedInto = target.id, userModified = byUser || source.userModified, revision = source.revision + 1))
        tags(scopeId = source.scopeId).filter { it.templateId == source.id && (byUser || !it.userModified) }.forEach { tag ->
            putTag(tag.copy(templateId = target.id, attributes = tag.attributes.filter { (key, value) -> result.fields.any { it.name == key && it.type == value.type } }))
        }
        event("tag_template.merged", source.id, nowMs)
        result
    }

    @Synchronized
    fun archiveUnused(nowMs: Long) = transaction {
        templates().filter { nowMs - it.lastUsedAtMs >= 60 * DAY_MS }.forEach {
            putTemplate(it.copy(archived = true, revision = it.revision + 1))
            event("tag_template.archived", it.id, nowMs)
        }
    }

    @Synchronized
    fun maintenanceDue(name: String, intervalMs: Long, nowMs: Long): Boolean = db.prepare("SELECT last_run FROM supertag_maintenance WHERE name = ?").use {
        it.bindText(1, name); !it.step() || nowMs - it.getLong(0) >= intervalMs
    }

    @Synchronized
    fun markMaintenance(name: String, nowMs: Long) = execute("INSERT INTO supertag_maintenance VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET last_run = excluded.last_run", name, nowMs)

    @Synchronized
    fun events(after: Long = 0, limit: Int = 100): List<SupertagEvent> {
        require(after >= 0 && limit in 1..100)
        return db.prepare("SELECT sequence, kind, subject_id, created_at FROM supertag_events WHERE sequence > ? ORDER BY sequence LIMIT ?").use {
            it.bindLong(1, after); it.bindLong(2, limit.toLong())
            buildList { while (it.step()) add(SupertagEvent(it.getLong(0), it.getText(1), it.getText(2), it.getLong(3))) }
        }
    }

    private fun event(kind: String, subjectId: String, nowMs: Long) = execute("INSERT INTO supertag_events(kind, subject_id, created_at) VALUES (?, ?, ?)", kind, subjectId, nowMs)

    private fun sanitize(candidate: TagCandidate): TagCandidate {
        val name = normalizeTag(CredentialRedactor.redact(candidate.name))
        require(name.length in 1..80 && Regex("[\\p{L}\\p{N}._-]+(?:/[\\p{L}\\p{N}._-]+)?").matches(name)) { "无效标签" }
        require(candidate.attributes.size <= 12)
        val attrs = candidate.attributes.mapNotNull { (rawKey, field) ->
            val key = normalizeTag(CredentialRedactor.redact(rawKey))
            if (key.length !in 1..64 || CredentialRedactor.isSensitiveKey(key) || CredentialRedactor.MASK in key) return@mapNotNull null
            val safe = field.copy(value = if (field.value.isString) JsonPrimitive(CredentialRedactor.redact(field.value.content).take(1000)) else field.value)
            if (safe.isValid() && CredentialRedactor.MASK !in safe.value.content) key to safe else null
        }.toMap()
        return candidate.copy(name = name, attributes = attrs)
    }

    private fun collectionId(scope: String, tag: String): String = UUID.nameUUIDFromBytes("$scope\u0000$tag".toByteArray(Charsets.UTF_8)).toString()

    private inline fun <reified T> read(sql: String, vararg args: Any): List<T> = db.prepare(sql).use { statement ->
        args.forEachIndexed { index, value -> if (value is Long) statement.bindLong(index + 1, value) else statement.bindText(index + 1, value.toString()) }
        buildList { while (statement.step()) add(json.decodeFromString<T>(statement.getText(0))) }
    }

    private fun exists(sql: String, vararg args: String): Boolean = db.prepare(sql).use {
        args.forEachIndexed { index, value -> it.bindText(index + 1, value) }; it.step()
    }

    private fun execute(sql: String, vararg args: Any) = db.prepare(sql).use {
        args.forEachIndexed { index, value -> if (value is Long) it.bindLong(index + 1, value) else it.bindText(index + 1, value.toString()) }; it.step(); Unit
    }

    private fun <T> transaction(action: () -> T): T {
        db.execSQL("BEGIN IMMEDIATE")
        try { val result = action(); db.execSQL("COMMIT"); return result }
        catch (t: Throwable) { db.execSQL("ROLLBACK"); throw t }
    }

    @Synchronized override fun close() = db.close()
}
