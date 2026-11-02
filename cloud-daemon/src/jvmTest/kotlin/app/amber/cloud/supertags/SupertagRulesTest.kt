package app.amber.cloud.supertags

import app.amber.ai.ui.UIMessage
import app.amber.cloud.agents.*
import app.amber.cloud.orchestration.CloudOrchestrationStore
import app.amber.cloud.orchestration.CloudPrincipal
import app.amber.cloud.runtime.CloudMemoryStore
import app.amber.cloud.runtime.CloudModelClient
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonPrimitive
import java.nio.file.Files
import kotlin.test.*

class SupertagRulesTest {
    private val now = 1_800_000_000_000L
    private val attrs = mapOf("destination" to TagValue(TagFieldType.TEXT, JsonPrimitive("京都")), "budget" to TagValue(TagFieldType.NUMBER, JsonPrimitive(15000)))
    private val owner = CloudPrincipal.OwnerUser("owner", "test")

    @Test fun evolution_requires_five_recent_occurrences_and_sixty_percent_with_two_stable_fields() {
        val dir = Files.createTempDirectory("supertag-threshold").toFile()
        SupertagStore(dir, now).use { store ->
            val maintenance = SupertagMaintenance(store, CloudModelClient { _, _ -> error("阈值计算无需模型") }) { error(it) }
            repeat(4) { i -> store.applyTags("c$i", "global", "turn$i", listOf(TagCandidate("holiday", attributes = if (i < 3) attrs else emptyMap())), now) }
            store.applyTags("stale", "global", "old", listOf(TagCandidate("holiday", attributes = attrs)), now - 30 * DAY_MS - 1)
            maintenance.evolve(now)
            assertEquals(6, store.templates().size)
            // A duplicate completion is not a fifth occurrence.
            store.applyTags("c0", "global", "turn0", listOf(TagCandidate("holiday", attributes = attrs)), now)
            maintenance.evolve(now)
            assertEquals(6, store.templates().size)
            store.applyTags("c4", "global", "turn4", listOf(TagCandidate("holiday")), now)
            maintenance.evolve(now)
            val evolved = store.templates().single { it.name == "holiday" }
            assertTrue(evolved.aiSuggested)
            assertEquals(setOf(TemplateField("destination", TagFieldType.TEXT), TemplateField("budget", TagFieldType.NUMBER)), evolved.fields.toSet())
            assertEquals(evolved.id, store.tags("c0").single().templateId)
            repeat(5) { i -> store.applyTags("s$i", "global", "s$i", listOf(TagCandidate("sparse", attributes = if (i < 2) attrs else emptyMap())), now) }
            maintenance.evolve(now)
            assertFalse(store.templates().any { it.name == "sparse" })
            // The active cap includes seeds; archived templates do not consume a slot.
            repeat(23) { i -> assertTrue(store.createEvolvedTemplate(TagTemplate("cap$i", "global", "cap$i", emptyList(), aiSuggested = true, createdAtMs = now))) }
            assertEquals(30, store.templates().size)
            assertFalse(store.createEvolvedTemplate(TagTemplate("overflow", "global", "overflow", emptyList(), createdAtMs = now)))
        }
        dir.deleteRecursively()
    }

    @Test fun owner_tag_and_template_changes_win_and_deleted_tags_and_templates_do_not_return() {
        val dir = Files.createTempDirectory("supertag-owner").toFile()
        SupertagStore(dir, now).use { store ->
            val corrected = store.editTag("c", "global", TagCandidate("#Holiday", attributes = attrs), now)
            store.applyTags("c", "global", "model", listOf(TagCandidate("holiday", attributes = emptyMap())), now)
            assertEquals(corrected, store.tags("c").single())
            store.removeTag("c", "global", "holiday", now)
            store.applyTags("c", "global", "model2", listOf(TagCandidate("holiday", attributes = attrs)), now)
            assertTrue(store.tags("c").isEmpty())
            assertTrue(store.observations(0).isEmpty())
            val first = TagTemplate("first", "global", "holiday", attrs.map { TemplateField(it.key, it.value.type) }, aiSuggested = true, createdAtMs = now)
            val second = first.copy(id = "second", name = "vacation")
            store.createEvolvedTemplate(first); store.createEvolvedTemplate(second)
            val renamed = store.editTemplate(first.id, 1, name = "旅行计划", nowMs = now)
            assertFailsWith<SupertagConflict> { store.mergeTemplates(first.id, second.id, renamed.revision, 1, false, now) }
            assertFalse(store.createEvolvedTemplate(first.copy(id = "regenerated")))
            val merged = store.mergeTemplates(second.id, renamed.id, second.revision, renamed.revision, true, now)
            store.applyTags("late", "global", "late-model", listOf(TagCandidate("travel/topic", second.id, attrs)), now)
            assertEquals(merged.id, store.tags("late").single().templateId, "旧模型快照须跟随主人合并后的模板")
            val deleted = store.editTemplate(merged.id, merged.revision, delete = true, nowMs = now)
            assertTrue(deleted.deleted)
            assertFalse(store.createEvolvedTemplate(first.copy(id = "regenerated2")))
            val safe = store.editTag("safe", "global", TagCandidate("work", attributes = mapOf(
                "api_key" to TagValue(TagFieldType.TEXT, JsonPrimitive("unshaped-secret")),
                "note" to TagValue(TagFieldType.TEXT, JsonPrimitive("sk-ant-api03-SECRETKEY1234567890ABCDEF")),
                "count" to TagValue(TagFieldType.NUMBER, JsonPrimitive("not-a-number")),
            )), now)
            assertTrue(safe.attributes.isEmpty(), "敏感键、凭据形状与无效类型不落库")
        }
        dir.deleteRecursively()
    }

    @Test fun weekly_synonyms_run_once_and_unused_ai_templates_archive_at_sixty_days() = runBlocking<Unit> {
        val dir = Files.createTempDirectory("supertag-scheduler").toFile()
        SupertagStore(dir, now).use { store ->
            val fields = attrs.map { TemplateField(it.key, it.value.type) }
            store.createEvolvedTemplate(TagTemplate("holiday", "global", "holiday", fields, aiSuggested = true, createdAtMs = now))
            store.createEvolvedTemplate(TagTemplate("vacation", "global", "vacation", fields, aiSuggested = true, createdAtMs = now))
            var calls = 0
            val maintenance = SupertagMaintenance(store, CloudModelClient { _, tools ->
                assertTrue(tools.isEmpty()); calls++
                UIMessage.assistant("""{"merges":[{"sourceId":"holiday","targetId":"vacation"}]}""")
            }) { error(it) }
            maintenance.runDue(now)
            assertEquals("vacation", store.template("holiday")!!.mergedInto)
            maintenance.runDue(now + DAY_MS)
            assertEquals(1, calls)
            store.archiveUnused(now + 60 * DAY_MS - 1)
            assertFalse(store.template("vacation")!!.archived)
            store.archiveUnused(now + 60 * DAY_MS)
            assertTrue(store.template("vacation")!!.archived)
        }
        SupertagStore(dir, now + 61 * DAY_MS).use { assertTrue(it.template("vacation")!!.archived, "重启不会重建种子或复活模板") }
        dir.deleteRecursively()
    }

    @Test fun four_distinct_recent_conversations_only_suggest_and_owner_confirmation_migrates_once() {
        val dir = Files.createTempDirectory("supertag-promote").toFile()
        val sources = CloudOrchestrationStore(dir)
        val registry = AgentRegistry(dir, sources, { emptySet() })
        val memory = CloudMemoryStore(dir.resolve("memory"))
        SupertagStore(dir, now).use { store ->
            val hubs = HubService(registry, store, memory)
            repeat(3) { i -> store.applyTags("c$i", "global", "t$i", listOf(TagCandidate("holiday", attributes = attrs)), now - 14 * DAY_MS) }
            store.applyTags("stale", "global", "old", listOf(TagCandidate("holiday")), now - 14 * DAY_MS - 1)
            assertTrue(store.promotions().isEmpty())
            store.applyTags("c0", "global", "same-conversation", listOf(TagCandidate("holiday")), now)
            assertTrue(store.promotions().isEmpty())
            store.applyTags("c3", "global", "t3", listOf(TagCandidate("holiday")), now)
            val promotion = store.promotions().single()
            assertEquals(4, promotion.conversationIds.size)
            assertEquals(listOf("main"), registry.list().map { it.id })
            assertEquals(1, store.events().count { it.kind == "hub.promotion_suggested" })
            memory.upsertMemory("京都计划", sourceConversationId = "c0")
            val pending = PendingTaggingTurn("c0", "global", "unfinished-extraction", "USER: 京都\nASSISTANT: 已整理", now)
            assertTrue(store.acceptTaggingTurn(pending))
            val confirmed = hubs.confirm(owner, promotion.id, now)
            assertEquals(confirmed, hubs.confirm(owner, promotion.id, now))
            assertEquals(2, registry.list().size)
            assertTrue(memory.listMemories().isEmpty())
            assertEquals("京都计划", memory.listMemories(agentId = confirmed.hubId!!).single().content)
            assertEquals(confirmed.hubId, store.conversationHub("c0"))
            val moved = store.pendingTaggingTurns().single()
            assertEquals(pending.copy(scopeId = confirmed.hubId!!), moved)
            store.completeTaggingTurn(pending, listOf(TagCandidate("stale-scope")), now)
            assertTrue(store.tags("c0").isEmpty())
            store.completeTaggingTurn(moved, emptyList(), now)
            assertTrue(store.pendingTaggingTurns().isEmpty())
            assertEquals("holiday", store.tags("c0", confirmed.hubId!!).single().name)
            assertTrue(store.tags("stale").isNotEmpty(), "不迁移窗口外会话")
        }
        registry.close(); sources.close(); dir.deleteRecursively()
    }
}
