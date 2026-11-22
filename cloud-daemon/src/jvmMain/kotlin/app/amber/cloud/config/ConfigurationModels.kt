package app.amber.cloud.config

import app.amber.cloud.rules.ProceduralRuleRecord
import app.amber.cloud.soul.SoulStateDto
import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

@Serializable data class ManagedModelSettings(
    val provider: String,
    val modelId: String,
    val baseUrl: String = "",
    val authMode: String = "apiKey",
    val siwcConfigured: Boolean = false,
)
@Serializable data class ManagedSearchSettings(val sources: List<String>, val mode: String)
@Serializable data class ModelSettingsPatch(
    val provider: String,
    val modelId: String,
    val baseUrl: String = "",
    @EncodeDefault(EncodeDefault.Mode.NEVER)
    val authMode: String? = null,
    @EncodeDefault(EncodeDefault.Mode.NEVER)
    val siwcConfigured: Boolean? = null,
) {
    fun settings() = ManagedModelSettings(provider.trim().lowercase(), modelId.trim(), baseUrl.trim().trimEnd('/'),
        authMode?.trim()?.ifEmpty { "apiKey" } ?: "apiKey", siwcConfigured ?: false)
}
@Serializable data class ConfigurationPatch(val model: ModelSettingsPatch? = null, val search: ManagedSearchSettings? = null)
@Serializable data class CredentialMutation(val action: String, val value: String? = null)
@Serializable data class CredentialPatch(val modelApiKey: CredentialMutation? = null, val exaApiKey: CredentialMutation? = null, val braveApiKey: CredentialMutation? = null)
@Serializable data class ConfigurationEnvelopePayload(
    val version: Int,
    val gatewayId: String,
    val deviceId: String,
    val requestId: String,
    val expectedRevision: Int,
    val issuedAt: Long,
    val expiresAt: Long,
    val configuration: ConfigurationPatch? = null,
    val credentials: CredentialPatch? = null,
)
@Serializable data class ConfigurationImportRequest(val jwe: String)
@Serializable data class ConfiguredCredential(val configured: Boolean)
@Serializable data class ConfiguredCredentials(val modelApiKey: ConfiguredCredential, val exaApiKey: ConfiguredCredential, val braveApiKey: ConfiguredCredential)
@Serializable data class ConfigurationView(
    val gatewayId: String, val revision: Int, val model: ManagedModelSettings, val search: ManagedSearchSettings,
    val credentials: ConfiguredCredentials,
    val supportedModelProviders: List<String> = listOf("openai", "claude"),
    val supportedSearchSources: List<String> = listOf("bing", "duckduckgo", "exa", "brave"),
)
@Serializable data class ConfigurationReceipt(val requestId: String, val revision: Int, val currentRevision: Int, val replayed: Boolean, val effective: String = "next_task")
@Serializable data class ConfigurationImportKey(
    val version: Int = 1, val gatewayId: String, val deviceId: String, val kid: String,
    val alg: String = "RSA-OAEP-256", val enc: String = "A256GCM",
    val publicJwk: JsonObject, val publicKeySpkiDerBase64: String,
    val serverTime: Long, val maxEnvelopeLifetimeSeconds: Int = 300,
)

/**
 * Strictly non-secret metadata carried in a single-scan pairing QR payload (`amber://gateway/pair?p=...`).
 * NEVER contains plaintext API keys, OAuth tokens, or credential fragments.
 */
@Serializable data class PairingBootstrapHint(
    val syncSupported: Boolean = true,
    val configRevision: Int = 0,
    val provider: String = "",
    val authMode: String = "apiKey",
    val siwcConfigured: Boolean = false,
    val hasEncryptedCredentials: Boolean = false,
    val soulRevision: Long = 0L,
    val activeRulesCount: Int = 0,
)

/** Plaintext credential bundle that ONLY exists inside a JWE ciphertext (`typ = "amber-bootstrap+jwe"`). */
@Serializable data class BootstrapCredentialBundle(
    val modelApiKey: String? = null,
    val exaApiKey: String? = null,
    val braveApiKey: String? = null,
)

/** Inner plaintext payload sealed into [PairingBootstrapSnapshot.encryptedConfigJwe]. */
@Serializable data class BootstrapEnvelopePayload(
    val version: Int = 1,
    val gatewayId: String,
    val deviceId: String,
    val issuedAt: Long,
    val expiresAt: Long,
    val configRevision: Int,
    val model: ManagedModelSettings,
    val search: ManagedSearchSettings,
    val credentials: BootstrapCredentialBundle,
)

/**
 * Returned over the pinned TLS channel during single-scan `POST /v1/pair` or `POST /v2/pairing/bootstrap-sync`.
 * Plaintext secrets are NEVER present in top-level fields; they are ONLY delivered inside [encryptedConfigJwe].
 */
@Serializable data class PairingBootstrapSnapshot(
    val version: Int = 1,
    val configuration: ConfigurationView? = null,
    val encryptedConfigJwe: String? = null,
    val soul: SoulStateDto? = null,
    val activeRules: List<ProceduralRuleRecord> = emptyList(),
    val importKey: ConfigurationImportKey? = null,
)

@Serializable data class IssuedPairingTicketDto(
    val deepLinkUrl: String,
    val fingerprint: String,
    val addresses: List<String>,
    val port: Int,
    val expiresAt: Double,
    val bootstrap: PairingBootstrapHint,
)

/** Only fixed, non-secret error codes may reach HTTP responses or logs. */
class ConfigurationApiException(val status: Int, val code: String, val currentRevision: Int? = null) : IllegalArgumentException(code)
