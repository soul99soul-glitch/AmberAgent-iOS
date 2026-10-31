package app.amber.cloud

import app.amber.ai.ui.UIMessage
import app.amber.cloud.agents.*
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.orchestration.*
import app.amber.cloud.runtime.CloudMemoryStore
import app.amber.cloud.runtime.CloudModelClient
import app.amber.core.memory.model.MemoryRecord
import app.amber.core.model.DEFAULT_ASSISTANT_ID
import app.amber.core.model.MemoryKind
import app.amber.core.model.MemoryScope
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import kotlin.test.*

class AgentRegistryAndMemoryTest {
    private val owner = CloudPrincipal.OwnerUser("owner", "test")
    private val coordinator = CloudPrincipal.CloudCoordinator(activeSessionId = PRIMARY_CONVERSATION_ID.toString(), activeTurnId = "test")
    private val worker = CloudPrincipal.Worker("worker", "work", "batch", ExecutionTargetNode.CloudSubagent(""))

    private fun source(store: CloudOrchestrationStore, id: String, text: String, now: Long, origin: MessageProvenanceOrigin = MessageProvenanceOrigin.OWNER_HUMAN) {
        store.recordSourceMessage(SourceMessageProvenance(PRIMARY_CONVERSATION_ID.toString(), id, "owner", "test", SenderRole.OWNER, origin, OrchestrationHash.sha256Hex(text), now), text)
    }

    @Test fun registry_cas_survives_restart_and_competing_connection_and_only_narrows_owner_scope() {
        val dir = Files.createTempDirectory("agent-cas").toFile()
        val store = CloudOrchestrationStore(dir)
        try {
            AgentRegistry(dir, store, { setOf("history_search", "history_fetch") }).use { first ->
                AgentRegistry(dir, store, { setOf("history_search", "history_fetch") }).use { second ->
                    assertEquals(listOf(MAIN_AGENT_ID), first.list().map { it.id })
                    val saved = first.save(owner, AgentProfile("coding", "编码", toolScope = setOf("history_search")), 0)
                    assertEquals(1, saved.revision)
                    assertFailsWith<AgentRevisionConflict> { second.save(owner, saved.copy(name = "旧修改"), 0) }
                    val updated = second.save(owner, saved.copy(instructions = "检查实现"), 1)
                    assertEquals(2, first.get("coding")!!.revision)
                    assertFailsWith<IllegalArgumentException> { first.save(owner, updated.copy(toolScope = setOf("terminal_exec")), 2) }
                    assertEquals(setOf("history_search"), first.get("coding")!!.toolScope)
                    assertFailsWith<PrincipalPermissionException> { first.save(worker, AgentProfile("self", "自建"), 0) }
                    assertFailsWith<PrincipalPermissionException> { first.save(coordinator, AgentProfile("self", "自建"), 0) }
                }
            }
            AgentRegistry(dir, store, { setOf("history_search") }).use { restarted ->
                assertEquals("检查实现", restarted.get("coding")!!.instructions)
                assertEquals(2, restarted.get("coding")!!.revision)
            }
        } finally { store.close(); dir.deleteRecursively() }
    }

    @Test fun router_proposal_requires_separate_owner_confirmation_and_worker_cannot_propose_or_confirm() {
        val dir = Files.createTempDirectory("agent-proposal").toFile()
        val store = CloudOrchestrationStore(dir)
        try {
            AgentRegistry(dir, store, { emptySet() }).use { registry ->
                source(store, "request", "请建议一个编码 agent", 10)
                assertFailsWith<PrincipalPermissionException> { registry.propose(worker, AgentProfile("coding", "编码"), listOf("request"), 20) }
                val proposal = registry.propose(coordinator, AgentProfile("coding", "编码"), listOf("request"), 20)
                assertNull(registry.get("coding"))
                assertFailsWith<IllegalArgumentException> { registry.confirm(owner, proposal.id, "request") }
                source(store, "agent-confirm", "确认创建 agent ${proposal.id}", 30, MessageProvenanceOrigin.AGENT)
                assertFailsWith<UnauthorizedWorkSourceException> { registry.confirm(owner, proposal.id, "agent-confirm") }
                source(store, "owner-confirm", "确认创建 agent ${proposal.id}", 30)
                assertFailsWith<PrincipalPermissionException> { registry.confirm(worker, proposal.id, "owner-confirm") }
                val saved = registry.confirm(owner, proposal.id, "owner-confirm")
                assertEquals(1, saved.revision)
                assertTrue(registry.pendingProposals().isEmpty())
                assertFailsWith<AgentRevisionConflict> { registry.confirm(owner, proposal.id, "owner-confirm") }
            }
        } finally { store.close(); dir.deleteRecursively() }
    }

    @Test fun mention_and_rules_precede_model_and_unknown_model_choice_falls_back_to_router() = runBlocking {
        val dir = Files.createTempDirectory("agent-routing").toFile()
        val store = CloudOrchestrationStore(dir)
        try {
            AgentRegistry(dir, store, { emptySet() }).use { registry ->
                registry.save(owner, AgentProfile("coding", "编码", routingKeywords = listOf("编译")), 0)
                registry.save(owner, AgentProfile("travel", "旅行", routingKeywords = listOf("行程")), 0)
                var calls = 0
                var answer = """{"agentId":"travel"}"""
                val routing = AgentRouting(registry, CloudModelClient { _, tools -> calls++; assertTrue(tools.isEmpty()); UIMessage.assistant(answer) })
                assertEquals(AgentRoute("coding", "mention", "显式提及 编码"), routing.select("@编码 请处理行程"))
                assertEquals("rule", routing.select("修复编译").method)
                assertNull(routing.deterministic("@编码助手 帮忙"))
                assertEquals(MAIN_AGENT_ID, routing.select("@编码 @旅行 帮忙").agentId)
                assertEquals(0, calls)
                assertEquals("travel", routing.select("下周怎么安排").agentId)
                answer = """{"agentId":"not-registered"}"""
                assertEquals(MAIN_AGENT_ID, routing.select("其他事情").agentId)
                assertEquals(2, calls)
            }
        } finally { store.close(); dir.deleteRecursively() }
    }

    @Test fun memory_policy_prioritizes_local_then_global_preferences_and_isolates_soul_and_legacy_data() {
        val dir = Files.createTempDirectory("agent-memory").toFile()
        try {
            val legacy = MemoryRecord(1, "旧全局偏好", MemoryScope.CORE, MemoryKind.USER, DEFAULT_ASSISTANT_ID.toString())
            File(dir, "memories.json").writeText(Json.encodeToString(listOf(legacy)))
            val store = CloudMemoryStore(dir)
            store.saveSoulPrompt("个人全局身份")
            store.upsertMemory("编码项目事实", agentId = "coding")
            store.upsertMemory("旅行私有事实", agentId = "travel")
            store.upsertMemory("全局普通笔记")
            val shared = store.recallForPrompt("旧全局偏好", agentId = "coding")
            assertEquals(listOf("编码项目事实", "旧全局偏好"), shared.map { it.content })
            val isolated = store.recallForPrompt("旧全局偏好", agentId = "coding", memoryPolicy = AgentMemoryPolicy.HUB_ISOLATED)
            assertEquals(listOf("编码项目事实"), isolated.map { it.content })
            assertFalse(store.loadSoulPrompt(AgentMemoryPolicy.HUB_ISOLATED).contains("个人全局身份"))
            val restarted = CloudMemoryStore(dir)
            assertEquals(listOf("旅行私有事实"), restarted.listMemories(agentId = "travel").map { it.content })
            assertEquals(2, restarted.listMemories().size)
            assertTrue(File(dir, "memories.json").readText().contains("旧全局偏好"), "迁移保留原文件")
        } finally { dir.deleteRecursively() }
    }
}
