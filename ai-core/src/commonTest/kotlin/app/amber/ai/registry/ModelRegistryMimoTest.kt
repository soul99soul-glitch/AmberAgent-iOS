package app.amber.ai.registry

import app.amber.ai.provider.Modality
import app.amber.ai.provider.ModelAbility
import kotlin.test.Test
import kotlin.test.assertEquals

class ModelRegistryMimoTest {
    @Test
    fun v26ModelsHaveMultimodalInputAndOneMillionTokenContext() {
        for (id in listOf("mimo-v2.6-pro", "mimo-v2.6-flash", "mimo-v2.6-pro-ultraspeed")) {
            for (modelId in listOf(id, "xiaomi/$id", id.uppercase())) {
                assertEquals(
                    listOf(Modality.TEXT, Modality.IMAGE, Modality.AUDIO, Modality.VIDEO),
                    ModelRegistry.MODEL_INPUT_MODALITIES.getData(modelId), modelId,
                )
                assertEquals(listOf(Modality.TEXT), ModelRegistry.MODEL_OUTPUT_MODALITIES.getData(modelId), modelId)
                assertEquals(listOf(ModelAbility.TOOL, ModelAbility.REASONING), ModelRegistry.MODEL_ABILITIES.getData(modelId), modelId)
                assertEquals(1_000_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData(modelId), modelId)
            }
        }
    }

    @Test
    fun existingMimoModelsKeepTheirCapabilities() {
        assertEquals(listOf(Modality.TEXT), ModelRegistry.MODEL_INPUT_MODALITIES.getData("mimo-v2.5-pro"))
        assertEquals(listOf(Modality.TEXT, Modality.IMAGE), ModelRegistry.MODEL_INPUT_MODALITIES.getData("mimo-v2-flash"))
        assertEquals(256_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("mimo-v2-flash"))
        assertEquals(1_000_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("mimo-v2.5-pro"))
    }

    @Test
    fun v26RuleDoesNotMatchOtherVersionNumbers() {
        assertEquals(listOf(Modality.TEXT, Modality.IMAGE), ModelRegistry.MODEL_INPUT_MODALITIES.getData("mimo-v2.60-flash"))
        assertEquals(256_000, ModelRegistry.MODEL_CONTEXT_WINDOW.getData("mimo-v2.60-flash"))
    }
}
