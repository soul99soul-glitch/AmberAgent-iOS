package app.amber.cloud.config

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

@Serializable data class ManagedModelSettings(val provider: String, val modelId: String, val baseUrl: String = "")
@Serializable data class ManagedSearchSettings(val sources: List<String>, val mode: String)
@Serializable data class ConfigurationPatch(val model: ManagedModelSettings? = null, val search: ManagedSearchSettings? = null)
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

/** Only fixed, non-secret error codes may reach HTTP responses or logs. */
class ConfigurationApiException(val status: Int, val code: String, val currentRevision: Int? = null) : IllegalArgumentException(code)
