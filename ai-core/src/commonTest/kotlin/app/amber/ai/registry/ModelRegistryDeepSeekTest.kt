package app.amber.ai.registry

import app.amber.ai.provider.Modality
import app.amber.ai.provider.ModelAbility
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ModelRegistryDeepSeekTest {
    @Test
    fun officialFlashAliasInheritsExistingV4FlashCapabilities() {
        for (id in listOf("deepseek-flash", "DEEPSEEK-FLASH")) {
            assertEquals(
                listOf(ModelAbility.TOOL, ModelAbility.REASONING),
                ModelRegistry.MODEL_ABILITIES.getData(id), id,
            )
            assertEquals(
                ModelRegistry.MODEL_ABILITIES.getData("deepseek-v4-flash"),
                ModelRegistry.MODEL_ABILITIES.getData(id), id,
            )
            assertEquals(listOf(Modality.TEXT), ModelRegistry.MODEL_INPUT_MODALITIES.getData(id), id)
            assertEquals(listOf(Modality.TEXT), ModelRegistry.MODEL_OUTPUT_MODALITIES.getData(id), id)
            assertEquals(
                ModelRegistry.MODEL_CONTEXT_WINDOW.getData("deepseek-v4-flash"),
                ModelRegistry.MODEL_CONTEXT_WINDOW.getData(id), id,
            )
            assertEquals(1_000_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData(id), id)
        }
    }

    @Test
    fun officialFlashAliasUsesExistingDeepSeekReasoningSessionGroup() {
        for (id in listOf("deepseek-flash", "DEEPSEEK-FLASH")) {
            assertEquals("deepseek_reasoning", ModelRegistry.sessionDefaultGroupForModel(id)?.id, id)
        }
    }

    @Test
    fun similarUnrecognizedNamesDoNotAcquireFlashCapabilities() {
        for (id in listOf(
            "deepseek-flash-lite", "deepseek-flash-preview", "deepseek-pro",
            "other-flash", "vendor/deepseek-flash",
        )) {
            assertEquals(emptyList(), ModelRegistry.MODEL_ABILITIES.getData(id), id)
            assertEquals(listOf(Modality.TEXT), ModelRegistry.MODEL_INPUT_MODALITIES.getData(id), id)
            assertEquals(listOf(Modality.TEXT), ModelRegistry.MODEL_OUTPUT_MODALITIES.getData(id), id)
            assertNull(ModelRegistry.MODEL_CONTEXT_WINDOW.getData(id), id)
            assertNull(ModelRegistry.sessionDefaultGroupForModel(id), id)
        }
    }

    @Test
    fun legacyDeepSeekModelsKeepTheirCapabilitiesAndContextWindows() {
        val toolOnly = listOf(ModelAbility.TOOL)
        val toolReasoning = listOf(ModelAbility.TOOL, ModelAbility.REASONING)
        for ((id, abilities, context) in listOf(
            Triple("deepseek-chat", toolOnly, 1_000_000),
            Triple("deepseek-reasoner", toolReasoning, 1_000_000),
            Triple("deepseek-v3", toolOnly, 128_000),
            Triple("deepseek-v3-flash", toolOnly, 128_000),
            Triple("deepseek-v3.1", toolReasoning, 128_000),
            Triple("deepseek-v3.2", toolReasoning, 128_000),
            Triple("deepseek-v4-flash", toolReasoning, 1_000_000),
            Triple("deepseek-v4-pro", toolReasoning, 1_000_000),
            Triple("vendor/deepseek-v4-flash", toolReasoning, 1_000_000),
        )) {
            assertEquals(abilities, ModelRegistry.MODEL_ABILITIES.getData(id), id)
            assertEquals(listOf(Modality.TEXT), ModelRegistry.MODEL_INPUT_MODALITIES.getData(id), id)
            assertEquals(listOf(Modality.TEXT), ModelRegistry.MODEL_OUTPUT_MODALITIES.getData(id), id)
            assertEquals(context, ModelRegistry.MODEL_CONTEXT_WINDOW.getData(id), id)
        }
    }
}
