package app.amber.ai.provider

import app.amber.ai.core.ReasoningLevel
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ReasoningPolicyTest {
    @Test
    fun kimiK3AndK31VariantsAreAlwaysLowHighMax() {
        for (id in listOf("kimi-k3", "kimi-k3.1", "k3", "k3.1", "k3.1-pro", "k3-pro", "moonshot/k3.1-pro")) {
            val options = options(id, kimi())
            assertEquals(
                listOf(ReasoningLevel.LOW, ReasoningLevel.HIGH, ReasoningLevel.MAX),
                options,
                id,
            )
            assertEquals(ReasoningLevel.MAX, default(id, kimi()), id)
        }
    }

    @Test
    fun kimiK26StaysBinary() {
        assertEquals(
            listOf(ReasoningLevel.OFF, ReasoningLevel.AUTO),
            options("kimi-k2.6", kimi()),
        )
    }

    @Test
    fun kimiK27CodeIsAlwaysOn() {
        assertEquals(
            listOf(ReasoningLevel.AUTO),
            options("kimi-k2.7-code", kimi()),
        )
    }

    @Test
    fun deepSeekV4IsOffLowHighMax() {
        assertEquals(
            listOf(ReasoningLevel.OFF, ReasoningLevel.LOW, ReasoningLevel.HIGH, ReasoningLevel.MAX),
            options("deepseek-v4-pro", deepseek()),
        )
        assertEquals(ReasoningLevel.HIGH, default("deepseek-v4-flash", deepseek()))
    }

    @Test
    fun deepSeekFlashAliasSupportsOfficialEffortLevels() {
        for (provider in listOf(deepseek(), ProviderSetting.OpenAI())) {
            assertEquals(ReasoningFamily.DEEPSEEK, model("deepseek-flash").reasoningFamily(provider))
            assertEquals(
                listOf(ReasoningLevel.OFF, ReasoningLevel.LOW, ReasoningLevel.HIGH, ReasoningLevel.MAX),
                options("deepseek-flash", provider),
            )
            assertEquals(ReasoningLevel.HIGH, default("deepseek-flash", provider))
        }
    }

    @Test
    fun legacyDeepSeekModelsAndUnrecognizedFlashNamesStayBinary() {
        for (id in listOf(
            "deepseek-chat", "deepseek-reasoner", "deepseek-v3", "deepseek-v3.2",
            "deepseek-v3-flash", "deepseek-flash-lite", "deepseek-pro", "other-flash",
        )) {
            assertEquals(ReasoningFamily.BINARY, model(id).reasoningFamily(deepseek()), id)
            assertEquals(listOf(ReasoningLevel.OFF, ReasoningLevel.AUTO), options(id, deepseek()), id)
            assertEquals(ReasoningLevel.AUTO, default(id, deepseek()), id)
        }
    }

    @Test
    fun glm53IsAlwaysLowHighMax() {
        assertEquals(
            listOf(ReasoningLevel.LOW, ReasoningLevel.HIGH, ReasoningLevel.MAX),
            options("glm-5.3", zhipu()),
        )
        assertEquals(ReasoningLevel.MAX, default("glm-5.3", zhipu()))
    }

    @Test
    fun glm52IsOffHighMax() {
        assertEquals(
            listOf(ReasoningLevel.OFF, ReasoningLevel.HIGH, ReasoningLevel.MAX),
            options("glm-5.2", zhipu()),
        )
    }

    @Test
    fun qwen38MaxIsOffLowMediumXhigh() {
        assertEquals(
            listOf(ReasoningLevel.OFF, ReasoningLevel.LOW, ReasoningLevel.MEDIUM, ReasoningLevel.XHIGH),
            options("qwen3.8-max", dashscope()),
        )
        assertEquals(ReasoningLevel.XHIGH, default("qwen3.8-max", dashscope()))
    }

    @Test
    fun openAiIncludesNoneAndMax() {
        assertEquals(
            listOf(
                ReasoningLevel.OFF,
                ReasoningLevel.LOW,
                ReasoningLevel.MEDIUM,
                ReasoningLevel.HIGH,
                ReasoningLevel.XHIGH,
                ReasoningLevel.MAX,
            ),
            options("gpt-5.6", openai()),
        )
        assertFalse(ReasoningLevel.AUTO in options("gpt-5.4", openai()))
        assertEquals(ReasoningLevel.MEDIUM, default("gpt-5.5", openai()))
    }

    @Test
    fun openAiGpt6ModelsExcludeOffAndCoerceOffToLow() {
        for (id in listOf(
            "gpt-6",
            "gpt-6.2",
            "gpt-6.2-sol",
            "gpt-6.2-astra",
            "gpt-6.1-sol",
            "gpt-6.1-terra",
            "gpt-6.1-mini",
            "gpt-6-astra",
            "gpt-6-sol",
            "gpt-6-terra",
            "gpt-6-luna",
            "openai/gpt-6.2-sol",
        )) {
            val opts = options(id, openai())
            assertEquals(
                listOf(
                    ReasoningLevel.LOW,
                    ReasoningLevel.MEDIUM,
                    ReasoningLevel.HIGH,
                    ReasoningLevel.XHIGH,
                    ReasoningLevel.MAX,
                ),
                opts,
                id,
            )
            assertFalse(ReasoningLevel.OFF in opts, id)
            assertEquals(ReasoningLevel.MEDIUM, default(id, openai()), id)
            assertEquals(
                ReasoningLevel.LOW,
                ReasoningLevel.OFF.coerceToReasoningOptions(model(id).reasoningOptions(openai()), default(id, openai())),
                id,
            )
        }
    }

    @Test
    fun gemini37FlashIsLowMediumHigh() {
        assertEquals(
            listOf(ReasoningLevel.AUTO, ReasoningLevel.LOW, ReasoningLevel.MEDIUM, ReasoningLevel.HIGH),
            options("gemini-3.7-flash", gemini()),
        )
        assertFalse(ReasoningLevel.OFF in options("gemini-3.7-flash", gemini()))
        assertEquals(ReasoningLevel.MEDIUM, default("gemini-3.7-flash", gemini()))
    }

    @Test
    fun gemini3ProIsLowHigh() {
        assertEquals(
            listOf(ReasoningLevel.AUTO, ReasoningLevel.LOW, ReasoningLevel.HIGH),
            options("gemini-3-pro-preview", gemini()),
        )
    }

    @Test
    fun claudeFableCannotDisableThinking() {
        val options = options("claude-fable-5", claude())
        assertFalse(ReasoningLevel.OFF in options)
        assertTrue(ReasoningLevel.XHIGH in options)
        assertTrue(ReasoningLevel.MAX in options)
    }

    @Test
    fun claudeOpus5HasOffAndXhigh() {
        val options = options("claude-opus-5", claude())
        assertTrue(ReasoningLevel.OFF in options)
        assertTrue(ReasoningLevel.XHIGH in options)
        assertTrue(ReasoningLevel.MAX in options)
    }

    @Test
    fun grok46And47ApiHaveXhighAndNoOff() {
        for (id in listOf("grok-4.6", "grok-4.7", "grok-4-7")) {
            assertEquals(
                listOf(ReasoningLevel.LOW, ReasoningLevel.MEDIUM, ReasoningLevel.HIGH, ReasoningLevel.XHIGH),
                options(id, xai()),
                id,
            )
            assertEquals(
                listOf(ReasoningLevel.LOW, ReasoningLevel.MEDIUM, ReasoningLevel.HIGH, ReasoningLevel.XHIGH),
                options(id, grokCliProxy()),
                id,
            )
        }
    }

    @Test
    fun frontier2026FamilyCoverageMatchesConfiguredOptions() {
        assertEquals(listOf(ReasoningLevel.OFF, ReasoningLevel.AUTO), options("MiniMax-M3.1", minimax()))
        assertEquals(
            listOf(ReasoningLevel.LOW, ReasoningLevel.HIGH, ReasoningLevel.MAX),
            options("glm-5.3-flash", zhipu()),
        )
        assertFalse(ReasoningLevel.OFF in options("claude-opus-5-5", claude()))
        assertTrue(ReasoningLevel.OFF in options("claude-sonnet-5-5", claude()))
        assertEquals(
            listOf(ReasoningLevel.OFF, ReasoningLevel.AUTO, ReasoningLevel.LOW, ReasoningLevel.MEDIUM, ReasoningLevel.HIGH),
            options("gemini-4-neon", gemini()),
        )
        assertEquals(
            listOf(ReasoningLevel.OFF, ReasoningLevel.AUTO),
            options("doubao-seed-2.1-pro", ProviderSetting.OpenAI(baseUrl = "https://ark.cn-beijing.volces.com/api/v3")),
        )
    }

    @Test
    fun grokWebModesDoNotUseApiEffortMenu() {
        assertEquals(
            listOf(ReasoningLevel.OFF),
            options("grok-4.20-fast", grokWeb()),
        )
    }

    @Test
    fun miniMaxM3IsBinary() {
        assertEquals(
            listOf(ReasoningLevel.OFF, ReasoningLevel.AUTO),
            options("MiniMax-M3", minimax()),
        )
    }

    @Test
    fun miniMaxM2IsAlwaysOn() {
        assertEquals(
            listOf(ReasoningLevel.AUTO),
            options("MiniMax-M2.5", minimax()),
        )
    }

    @Test
    fun mimoStaysBinary() {
        assertEquals(
            listOf(ReasoningLevel.OFF, ReasoningLevel.AUTO),
            options("mimo-v2.5-pro", mimo()),
        )
    }

    @Test
    fun offOnAlwaysOnModelCoercesToLow() {
        val model = model("kimi-k3")
        val coerced = ReasoningLevel.OFF.coerceToReasoningOptions(
            model.reasoningOptions(kimi()),
            model.defaultReasoningLevel(kimi()),
        )
        assertEquals(ReasoningLevel.LOW, coerced)
    }

    @Test
    fun autoOnK3CoercesToOfficialDefaultMax() {
        val model = model("kimi-k3")
        val coerced = ReasoningLevel.AUTO.coerceToReasoningOptions(
            model.reasoningOptions(kimi()),
            model.defaultReasoningLevel(kimi()),
        )
        assertEquals(ReasoningLevel.MAX, coerced)
    }

    private fun options(modelId: String, provider: ProviderSetting): List<ReasoningLevel> =
        model(modelId).reasoningOptions(provider).map { it.level }

    private fun default(modelId: String, provider: ProviderSetting): ReasoningLevel =
        model(modelId).defaultReasoningLevel(provider)

    private fun model(modelId: String) = Model(
        modelId = modelId,
        displayName = modelId,
        abilities = listOf(ModelAbility.REASONING),
    )

    private fun kimi() = ProviderSetting.OpenAI(brand = OpenAIBrand.KIMI, baseUrl = "https://api.moonshot.cn/v1")
    private fun deepseek() = ProviderSetting.OpenAI(brand = OpenAIBrand.DEEPSEEK, baseUrl = "https://api.deepseek.com/v1")
    private fun zhipu() = ProviderSetting.OpenAI(brand = OpenAIBrand.ZHIPU, baseUrl = "https://open.bigmodel.cn/api/paas/v4")
    private fun openai() = ProviderSetting.OpenAI(brand = OpenAIBrand.OPENAI, baseUrl = "https://api.openai.com/v1")
    private fun gemini() = ProviderSetting.Google()
    private fun claude() = ProviderSetting.Claude()
    private fun xai() = ProviderSetting.OpenAI(name = "xAI", baseUrl = "https://api.x.ai/v1")
    private fun grokWeb() = ProviderSetting.OpenAI(name = "Grok", baseUrl = "https://grok.com/rest/app-chat")
    private fun grokCliProxy() = ProviderSetting.OpenAI(
        name = "Grok",
        baseUrl = "https://cli-chat-proxy.grok.com/v1",
    )
    private fun minimax() = ProviderSetting.OpenAI(brand = OpenAIBrand.MINIMAX, baseUrl = "https://api.minimaxi.com/v1")
    private fun mimo() = ProviderSetting.OpenAI(brand = OpenAIBrand.MIMO, baseUrl = "https://api.xiaomimimo.com/v1")
    private fun dashscope() = ProviderSetting.OpenAI(baseUrl = "https://dashscope.aliyuncs.com/compatible-mode/v1")
}
