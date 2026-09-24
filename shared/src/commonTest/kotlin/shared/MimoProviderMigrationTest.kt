package shared

import app.amber.ai.provider.LEGACY_MIMO_API_DEFAULT_BASE_URL
import app.amber.ai.provider.MIMO_API_DEFAULT_BASE_URL
import app.amber.ai.provider.MIMO_TOKEN_PLAN_DEFAULT_BASE_URL
import app.amber.ai.provider.Model
import app.amber.ai.provider.OpenAIBrand
import app.amber.ai.provider.OpenAIAuthMode
import app.amber.ai.provider.ProviderSetting
import app.amber.core.settings.MimoProviderIdRef
import app.amber.core.settings.DEFAULT_PROVIDERS
import app.amber.core.settings.Settings
import kotlin.test.Test
import kotlin.test.assertEquals

@OptIn(kotlin.uuid.ExperimentalUuidApi::class)
class MimoProviderMigrationTest {
    @Test
    fun bundledMimoPresetStartsOnThePublicApiEndpoint() {
        val preset = DEFAULT_PROVIDERS.single { it.id == MimoProviderIdRef } as ProviderSetting.OpenAI
        assertEquals(MIMO_API_DEFAULT_BASE_URL, preset.baseUrl)
    }

    @Test
    fun legacyApiEndpointMigratesToThePublicApiEndpoint() {
        val provider = ProviderSetting.OpenAI(
            id = MimoProviderIdRef,
            name = "MiMo",
            enabled = false,
            apiKey = "sk-preserve",
            baseUrl = LEGACY_MIMO_API_DEFAULT_BASE_URL,
            models = listOf(Model(modelId = "mimo-v2.5-pro")),
            useResponseApi = true,
            authMode = OpenAIAuthMode.API_KEY,
            brand = OpenAIBrand.MIMO,
        )

        val migrated = decode(provider)

        assertEquals(provider.copy(baseUrl = MIMO_API_DEFAULT_BASE_URL), migrated)
    }

    @Test
    fun legacyEndpointUsesTokenPlanWhenAuthModeWasAlreadySelected() {
        val provider = ProviderSetting.OpenAI(
            id = MimoProviderIdRef,
            apiKey = "tp-preserve",
            baseUrl = LEGACY_MIMO_API_DEFAULT_BASE_URL,
            authMode = OpenAIAuthMode.MIMO_CODING_PLAN,
            brand = OpenAIBrand.MIMO,
        )

        assertEquals(MIMO_TOKEN_PLAN_DEFAULT_BASE_URL, decode(provider).baseUrl)
    }

    @Test
    fun customMimoEndpointIsNeverRewritten() {
        val custom = "https://mimo-gateway.example/v1"
        val provider = ProviderSetting.OpenAI(
            id = MimoProviderIdRef,
            apiKey = "sk-custom",
            baseUrl = custom,
            authMode = OpenAIAuthMode.API_KEY,
            brand = OpenAIBrand.MIMO,
        )

        assertEquals(custom, decode(provider).baseUrl)
    }

    @Test
    fun genericProviderUsingTheLegacyStringIsNotRewritten() {
        val provider = ProviderSetting.OpenAI(
            apiKey = "sk-generic",
            baseUrl = LEGACY_MIMO_API_DEFAULT_BASE_URL,
            brand = OpenAIBrand.GENERIC,
        )

        assertEquals(provider, decode(provider))
    }

    private fun decode(provider: ProviderSetting.OpenAI): ProviderSetting.OpenAI =
        IosSettingsJsonBridge.decode(
            IosSettingsJsonBridge.encode(Settings(providers = listOf(provider))),
        ).providers.single() as ProviderSetting.OpenAI
}
