@file:OptIn(kotlin.uuid.ExperimentalUuidApi::class)

package shared

import app.amber.core.settings.DEFAULT_AGENT_SOUL_MARKDOWN
import app.amber.core.settings.DEFAULT_AMBER_ASSISTANT_SYSTEM_PROMPT
import app.amber.core.settings.DEFAULT_AGENT_SOUL_MARKDOWN_20260901
import app.amber.core.settings.DEFAULT_AMBER_ASSISTANT_SYSTEM_PROMPT_20260901
import app.amber.core.settings.Settings
import kotlin.test.Test
import kotlin.test.assertEquals

class IosSettingsMutationsIdentityTest {
    @Test
    fun identityRebrandMigratesFactoryTextAndPreservesCustomText() {
        val base = Settings()
        val legacyAssistant = base.assistants.first().copy(
            name = "AmberAgent",
            systemPrompt = DEFAULT_AMBER_ASSISTANT_SYSTEM_PROMPT_20260901.replace("AmberAgent", "Amber"),
        )
        val customPrompt = "AmberAgent custom instructions for Android System WebView"
        val customAssistant = base.assistants[1].copy(
            name = "Custom Agent",
            systemPrompt = customPrompt,
        )
        val legacySoul = base.agentRuntime.copy(
            agentSoulMarkdown = DEFAULT_AGENT_SOUL_MARKDOWN_20260901,
        )
        val updated = IosSettingsMutations.rebrandAmberIdentity(
            base.copy(
                agentRuntime = legacySoul,
                assistants = listOf(legacyAssistant, customAssistant),
            )
        )

        val expectedIosPrompt = DEFAULT_AMBER_ASSISTANT_SYSTEM_PROMPT
            .replace("AmberAgent", "Amber")
            .replace("an agent-only Android assistant", "an agent-only iOS assistant")
            .replace("Android System WebView", "the system WebView")
        assertEquals("Amber", updated.assistants[0].name)
        assertEquals(expectedIosPrompt, updated.assistants[0].systemPrompt)
        assertEquals("Custom Agent", updated.assistants[1].name)
        assertEquals(customPrompt, updated.assistants[1].systemPrompt)
        assertEquals(DEFAULT_AGENT_SOUL_MARKDOWN, updated.agentRuntime.agentSoulMarkdown)
    }
}
