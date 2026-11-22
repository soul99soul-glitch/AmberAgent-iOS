package app.amber.ai.registry

import app.amber.ai.provider.Modality
import app.amber.ai.provider.ModelAbility
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ModelRegistryFrontier2026Test {
    private val toolReasoning = listOf(ModelAbility.TOOL, ModelAbility.REASONING)
    private val vision = listOf(Modality.TEXT, Modality.IMAGE)
    private val omni = listOf(Modality.TEXT, Modality.IMAGE, Modality.AUDIO, Modality.VIDEO)

    @Test
    fun frontierOpenAIAnthropicGoogleXaiSpecsMatch2026OfficialDefaults() {
        for (id in listOf("gpt-5.4", "gpt-5.5", "gpt-5.6")) {
            assertEquals(1_050_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData(id), id)
            assertEquals(vision, ModelRegistry.MODEL_INPUT_MODALITIES.getData(id), id)
            assertEquals(toolReasoning, ModelRegistry.MODEL_ABILITIES.getData(id), id)
        }
        for (id in listOf("gpt-6", "gpt-6.2", "gpt-6-astra", "gpt-6-sol", "gpt-6-terra", "gpt-6-luna")) {
            assertEquals(1_047_576, ModelRegistry.MODEL_CONTEXT_WINDOW.getData(id), id)
            assertEquals(vision, ModelRegistry.MODEL_INPUT_MODALITIES.getData(id), id)
            assertEquals(toolReasoning, ModelRegistry.MODEL_ABILITIES.getData(id), id)
            assertEquals("openai_reasoning", ModelRegistry.sessionDefaultGroupForModel(id)?.id, id)
        }
        assertEquals(400_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("gpt-5.4-mini"))
        assertEquals(listOf(ModelAbility.TOOL), ModelRegistry.MODEL_ABILITIES.getData("gpt-5-chat"))

        for (id in listOf(
            "claude-opus-5-5",
            "claude-sonnet-5-5",
            "claude-haiku-5-5",
            "claude-fable-5-2",
            "claude-mythos-5-2",
            "claude-opus-4-7",
            "claude-sonnet-4-6",
        )) {
            assertEquals(1_000_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData(id), id)
            assertEquals(vision, ModelRegistry.MODEL_INPUT_MODALITIES.getData(id), id)
            assertEquals(toolReasoning, ModelRegistry.MODEL_ABILITIES.getData(id), id)
            assertTrue(ModelRegistry.CLAUDE_SERIES.match(id), id)
        }
        assertEquals(200_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("claude-haiku-4-5-20251001"))
        assertEquals(200_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("claude-4.5-haiku"))
        assertFalse(ModelRegistry.CLAUDE_SERIES.match("claude-3.5-haiku"))

        for (id in listOf(
            "gemini-4-carbon",
            "gemini-4-neon",
            "gemini-4-argon",
            "gemini-4-hydrogen",
            "gemini-3.8-pro",
            "gemini-3.5-flash",
            "gemini-3.1-pro",
            "gemini-3.1-flash",
        )) {
            assertEquals(1_048_576, ModelRegistry.MODEL_CONTEXT_WINDOW.getData(id), id)
            assertEquals(omni, ModelRegistry.MODEL_INPUT_MODALITIES.getData(id), id)
            assertEquals(toolReasoning, ModelRegistry.MODEL_ABILITIES.getData(id), id)
            assertTrue(ModelRegistry.GEMINI_SERIES.match(id), id)
        }
        assertEquals(256_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("gemini-decision-1"))

        assertEquals(500_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("grok-4.7"))
        assertEquals(500_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("grok-4.5"))
        assertEquals(1_000_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("grok-4.20-0309-reasoning"))
        assertEquals(1_000_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("grok-4.3"))
        assertEquals(256_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("grok-4.1-fast"))
        assertEquals(256_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("grok-build"))
        assertEquals(131_072, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("grok-3"))
        assertEquals(listOf(Modality.TEXT), ModelRegistry.MODEL_INPUT_MODALITIES.getData("grok-3"))
    }

    @Test
    fun domesticModelsMatch2026OfficialSpecs() {
        for (id in listOf("qwen4-max", "qwen3.8-max", "qwen3.8-flash", "qwen3.7-max", "qwen3.7-plus")) {
            assertEquals(1_000_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData(id), id)
            assertEquals(vision, ModelRegistry.MODEL_INPUT_MODALITIES.getData(id), id)
            assertEquals(toolReasoning, ModelRegistry.MODEL_ABILITIES.getData(id), id)
            assertEquals("qwen_reasoning", ModelRegistry.sessionDefaultGroupForModel(id)?.id, id)
        }
        assertEquals(65_536, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("qwen3.8-omni"))
        assertEquals(omni, ModelRegistry.MODEL_INPUT_MODALITIES.getData("qwen3.8-omni"))
        assertEquals(256_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("qwen3-vl-plus"))
        assertEquals(128_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("qwen-vl-max"))

        assertEquals(1_000_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("glm-5.3-flash"))
        assertEquals(vision, ModelRegistry.MODEL_INPUT_MODALITIES.getData("glm-5.3-flash"))
        assertEquals(vision, ModelRegistry.MODEL_INPUT_MODALITIES.getData("glm-5.3-flashx"))
        assertEquals(1_000_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("glm-5.3"))
        assertEquals(listOf(Modality.TEXT), ModelRegistry.MODEL_INPUT_MODALITIES.getData("glm-5.3"))
        assertEquals(200_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("glm-5v-turbo"))
        assertEquals(vision, ModelRegistry.MODEL_INPUT_MODALITIES.getData("glm-5v-turbo"))
        assertEquals(128_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("glm-4.5v"))

        assertEquals(1_048_576, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("kimi-k3.1"))
        assertEquals(vision, ModelRegistry.MODEL_INPUT_MODALITIES.getData("kimi-k3.1"))
        assertEquals(1_048_576, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("k3"))
        assertEquals(262_144, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("kimi-k2.5"))

        assertEquals(1_000_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("MiniMax-M3.1"))
        assertEquals(vision, ModelRegistry.MODEL_INPUT_MODALITIES.getData("MiniMax-M3.1"))
        assertEquals(204_800, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("minimax-m2.7"))
        assertEquals(200_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("minimax-m2"))

        assertEquals(1_000_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("doubao-seed-2.1-pro"))
        assertEquals(omni, ModelRegistry.MODEL_INPUT_MODALITIES.getData("doubao-seed-2.1-pro"))
        assertEquals(1_000_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("doubao-seed-evolving"))
        assertEquals(256_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("seed-2.1-turbo"))
        assertEquals(vision, ModelRegistry.MODEL_INPUT_MODALITIES.getData("seed-2.1-turbo"))
        assertEquals(256_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("doubao-seed-2.0-pro"))
    }
}
