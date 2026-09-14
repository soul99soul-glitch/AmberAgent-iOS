package shared

import app.amber.ai.core.ReasoningLevel
import app.amber.ai.provider.Model
import app.amber.ai.provider.ModelAbility
import app.amber.ai.provider.ProviderSetting
import app.amber.core.settings.Settings
import app.amber.feature.subagent.SubAgentPoolModel
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.uuid.Uuid

@OptIn(kotlin.uuid.ExperimentalUuidApi::class)
class IosSettingsMutationsSubAgentTest {
    @Test
    fun roleConfigurationAndDynamicSwitchSurviveSerialization() {
        val modelId = Uuid.random().toString()
        val configured = IosSettingsMutations.configureSubAgentRole(
            settings = Settings(), roleId = "browser", systemPrompt = "Inspect the requested page",
            modelId = modelId, reasoningLevel = ReasoningLevel.HIGH,
            toolAllowlist = setOf("wm_open", "wm_state"), defaultSkillNames = listOf("browser-guide"),
        )
        val disabled = IosSettingsMutations.setDynamicSubAgentsAllowed(configured, false)
        val restored = IosSettingsJsonBridge.decode(IosSettingsJsonBridge.encode(disabled))
        assertFalse(restored.agentRuntime.subAgent.allowDynamicSubAgents)
        assertEquals(configured.agentRuntime.subAgent.overrides, restored.agentRuntime.subAgent.overrides)

        val reset = IosSettingsMutations.configureSubAgentRole(
            settings = restored, roleId = "browser", systemPrompt = null, modelId = null,
            reasoningLevel = null, toolAllowlist = emptySet(), defaultSkillNames = emptyList(),
        )
        assertEquals(emptySet(), reset.agentRuntime.subAgent.overrides["browser"]?.toolAllowlist)
        assertEquals(null, reset.agentRuntime.subAgent.overrides["browser"]?.modelId)
    }

    @Test
    fun executionLimitsClampAndModelPoolPreservesOverridesAndUnavailableIds() {
        val first = Uuid.random()
        val unavailable = Uuid.random()
        val defaults = Settings().agentRuntime.subAgent
        assertEquals(2, defaults.maxConcurrentRuns)
        assertEquals(5 * 60_000L, defaults.timeoutMs)
        val seeded = Settings(
            agentRuntime = Settings().agentRuntime.copy(
                subAgent = Settings().agentRuntime.subAgent.copy(
                    modelPool = listOf(
                        SubAgentPoolModel(first, ReasoningLevel.HIGH),
                        SubAgentPoolModel(unavailable, ReasoningLevel.LOW),
                    )
                )
            )
        )

        val limited = IosSettingsMutations.setSubAgentExecutionLimits(
            settings = seeded,
            maxConcurrentRuns = 99,
            timeoutMinutes = 0,
        )
        assertEquals(10, limited.agentRuntime.subAgent.maxConcurrentRuns)
        assertEquals(60_000L, limited.agentRuntime.subAgent.timeoutMs)

        val upperLimited = IosSettingsMutations.setSubAgentExecutionLimits(
            settings = limited,
            maxConcurrentRuns = 0,
            timeoutMinutes = 99,
        )
        assertEquals(1, upperLimited.agentRuntime.subAgent.maxConcurrentRuns)
        assertEquals(60 * 60_000L, upperLimited.agentRuntime.subAgent.timeoutMs)

        val updated = IosSettingsMutations.setSubAgentModelPool(
            settings = limited,
            modelIds = listOf(first.toString(), first.toString(), unavailable.toString()),
        )
        assertEquals(
            listOf(first, unavailable),
            updated.agentRuntime.subAgent.modelPool.map { it.modelId },
        )
        assertEquals(
            ReasoningLevel.HIGH,
            updated.agentRuntime.subAgent.modelPool.first().reasoningLevel,
        )

        val restored = IosSettingsJsonBridge.decode(IosSettingsJsonBridge.encode(updated))
        assertEquals(updated.agentRuntime.subAgent.modelPool, restored.agentRuntime.subAgent.modelPool)
        val removed = IosSettingsMutations.setSubAgentModelPool(restored, listOf(first.toString()))
        assertEquals(listOf(first), removed.agentRuntime.subAgent.modelPool.map { it.modelId })
    }

    @Test
    fun poolReasoningRequiresModelSupportAndOnlyUpdatesSelectedEntry() {
        val modelId = Uuid.random()
        val model = Model(
            id = modelId,
            modelId = "gpt-5.3-codex",
            displayName = "Codex",
            abilities = listOf(ModelAbility.REASONING),
        )
        val provider = ProviderSetting.OpenAI(models = listOf(model))
        val selected = IosSettingsMutations.setSubAgentModelPool(
            Settings(providers = listOf(provider)),
            listOf(modelId.toString()),
        )

        val configured = IosSettingsMutations.setSubAgentPoolReasoning(
            selected,
            modelId.toString(),
            ReasoningLevel.HIGH,
        )
        assertEquals(
            ReasoningLevel.HIGH,
            configured.agentRuntime.subAgent.modelPool.single().reasoningLevel,
        )

        val unsupported = IosSettingsMutations.setSubAgentPoolReasoning(
            configured,
            modelId.toString(),
            ReasoningLevel.AUTO,
        )
        assertEquals(configured, unsupported)
        assertTrue(configured.agentRuntime.subAgent.modelPool.single().reasoningLevel != null)
    }
}
