package shared

import app.amber.ai.core.ReasoningLevel
import app.amber.core.settings.Settings
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
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
}
