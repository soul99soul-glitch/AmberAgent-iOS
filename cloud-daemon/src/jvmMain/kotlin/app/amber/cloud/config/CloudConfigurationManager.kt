package app.amber.cloud.config

import app.amber.cloud.gateway.PairedDevice
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.EnvelopeCredentialVault
import app.amber.cloud.tasks.CloudSearch
import app.amber.cloud.tasks.PublicHttp
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import java.net.URI
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicReference

/** Existing vault is the single durable owner; immutable snapshots are the only runtime publication point. */
class CloudConfigurationManager internal constructor(
    private val vault: EnvelopeCredentialVault,
    private val gatewayId: String,
    private val bootstrap: CloudDaemonConfig,
    private val clockSeconds: () -> Long = { System.currentTimeMillis() / 1000 },
    private val modelFactory: (CloudDaemonConfig, String?) -> CloudModelClient = { config, key -> configuredModelClient(config, key, allowUnconfigured = true) },
    private val http: PublicHttp = PublicHttp(),
) {
    @Serializable private data class RequestRecord(val deviceId: String, val requestId: String, val operationHash: String, val revision: Int)
    @Serializable private data class State(
        val revision: Int, val model: ManagedModelSettings, val search: ManagedSearchSettings,
        val requests: List<RequestRecord> = emptyList(),
    )
    private val json = Json { encodeDefaults = true }
    private var state = vault.getSecret(STATE_KEY)?.let { json.decodeFromString<State>(it) }
        ?: State(0, ManagedModelSettings(bootstrap.modelProvider, bootstrap.modelId, bootstrap.modelBaseUrl),
            ManagedSearchSettings(bootstrap.searchSources.split(',').map(String::trim).filter(String::isNotEmpty), bootstrap.searchMode))
    private var keys = KEY_NAMES.values.associateWith(vault::getSecret)
    private val active = AtomicReference(buildSnapshot(state, keys))
    private val encryption = ConfigurationEncryption(vault, gatewayId)

    val modelClient = CloudModelClient { messages, tools ->
        val pinned = currentCoroutineContext()[RuntimeConfigurationSnapshot] ?: snapshot()
        pinned.model.generateReply(messages, tools)
    }
    fun snapshot(): RuntimeConfigurationSnapshot = active.get()

    @Synchronized fun view(device: PairedDevice): ConfigurationView {
        requireManagementDevice(device)
        fun configured(name: String) = ConfiguredCredential(!keys[KEY_NAMES.getValue(name)].isNullOrBlank())
        return ConfigurationView(gatewayId, state.revision, state.model, state.search,
            ConfiguredCredentials(configured("modelApiKey"), configured("exaApiKey"), configured("braveApiKey")))
    }

    fun importKey(device: PairedDevice): ConfigurationImportKey {
        requireManagementDevice(device)
        return encryption.publicKey(device.id, clockSeconds())
    }

    @Synchronized fun update(device: PairedDevice, compact: String): ConfigurationReceipt {
        requireManagementDevice(device)
        val bytes = encryption.decrypt(compact)
        val payload = try { json.decodeFromString<ConfigurationEnvelopePayload>(bytes.decodeToString()) }
            catch (_: Exception) { throw ConfigurationApiException(400, "invalid_request") }
            finally { bytes.fill(0) }
        if (payload.version != 1 || payload.gatewayId != gatewayId || payload.deviceId != device.id) fail(400, "invalid_envelope")
        if (!Regex("[A-Za-z0-9._:-]{1,128}").matches(payload.requestId) || payload.expectedRevision < 0) fail(400, "invalid_request")
        val mutations = mutations(payload.credentials)
        // Canonical typed patch + selected operations; excludes envelope randomness and expiry so a client can re-seal a retry.
        val operation = buildJsonObject {
            put("configuration", json.encodeToJsonElement(payload.configuration))
            put("credentials", JsonObject(mutations.toSortedMap().mapValues { (_, value) -> value?.let(::JsonPrimitive) ?: JsonNull }))
        }
        val hash = MessageDigest.getInstance("SHA-256").digest(operation.toString().toByteArray()).joinToString("") { "%02x".format(it) }
        state.requests.firstOrNull { it.deviceId == device.id && it.requestId == payload.requestId }?.let {
            if (it.operationHash != hash) fail(409, "request_id_conflict")
            return ConfigurationReceipt(payload.requestId, it.revision, state.revision, true)
        }
        val now = clockSeconds()
        if (payload.expiresAt <= now) fail(410, "envelope_expired")
        if (payload.issuedAt < now - 300 || payload.issuedAt > now + 60 || payload.expiresAt <= payload.issuedAt || payload.expiresAt - payload.issuedAt > 300) fail(400, "invalid_envelope")
        if (payload.expectedRevision != state.revision) throw ConfigurationApiException(409, "revision_conflict", state.revision)
        payload.configuration?.model?.let(::validateRemoteModel)
        val next = state.copy(
            revision = state.revision + 1,
            model = payload.configuration?.model?.let { it.copy(provider = it.provider.trim().lowercase(), modelId = it.modelId.trim(), baseUrl = it.baseUrl.trim().trimEnd('/')) } ?: state.model,
            search = payload.configuration?.search ?: state.search,
            requests = state.requests + RequestRecord(device.id, payload.requestId, hash, state.revision + 1),
        )
        validateSearch(next.search)
        // Retention is not permission to forward a credential to a different provider/address.
        if (!keys[CloudConfigLoader.KEY_MODEL_API_KEY].isNullOrBlank() && destination(state.model) != destination(next.model) &&
            CloudConfigLoader.KEY_MODEL_API_KEY !in mutations) fail(422, "credential_action_required")
        val candidateKeys = keys.toMutableMap().apply { putAll(mutations) }.toMap()
        val outwardValues = listOf(next.model.provider, next.model.modelId, next.model.baseUrl, next.search.mode, payload.requestId) + next.search.sources
        if ((keys.values + candidateKeys.values).filterNotNull().filter(String::isNotBlank).any { secret ->
                outwardValues.any { it == secret || secret.length >= 8 && it.contains(secret) }
            }) fail(422, "invalid_configuration")
        val candidate = try { buildSnapshot(next, candidateKeys) }
            catch (_: Exception) { fail(422, "invalid_configuration") }
        // All validation/client construction precedes a single existing-vault atomic replacement.
        // A failed write leaves both the old snapshot and persisted revision/credentials intact.
        vault.updateSecrets(mutations + (STATE_KEY to json.encodeToString(next)))
        state = next
        keys = candidateKeys
        active.set(candidate)
        return ConfigurationReceipt(payload.requestId, state.revision, state.revision, false)
    }

    private fun buildSnapshot(config: State, credentials: Map<String, String?>): RuntimeConfigurationSnapshot {
        validateSearch(config.search)
        val runtime = bootstrap.copy(modelProvider = config.model.provider, modelId = config.model.modelId, modelBaseUrl = config.model.baseUrl,
            searchSources = config.search.sources.joinToString(","), searchMode = config.search.mode)
        val model = credentialSafeModel(modelFactory(runtime, credentials[CloudConfigLoader.KEY_MODEL_API_KEY]), credentials.values)
        val search = CloudSearch(http, vault, config.search.sources, config.search.mode, credentialLookup = { credentials[it] })
        return RuntimeConfigurationSnapshot(config.revision, model, search)
    }

    private fun mutations(patch: CredentialPatch?): Map<String, String?> {
        val values = mapOf("modelApiKey" to patch?.modelApiKey, "exaApiKey" to patch?.exaApiKey, "braveApiKey" to patch?.braveApiKey)
        return buildMap { for ((name, change) in values) {
            if (change == null) continue
            val value = change.value?.trim().orEmpty()
            when (change.action) {
                "replace" -> if (value.isNotEmpty()) {
                    if (value.length > 16_384 || value.any(Char::isISOControl) || CredentialRedactor.isPlaceholderCredential(value)) fail(422, "invalid_configuration")
                    put(KEY_NAMES.getValue(name), value)
                }
                "delete" -> { if (value.isNotEmpty()) fail(422, "invalid_configuration"); put(KEY_NAMES.getValue(name), null) }
                else -> fail(422, "invalid_configuration")
            }
        } }
    }

    private fun destination(model: ManagedModelSettings): String {
        val provider = model.provider.trim().lowercase()
        val url = model.baseUrl.trim().ifBlank { if (provider == "claude") "https://api.anthropic.com/v1" else "https://api.openai.com/v1" }.trimEnd('/')
        return "$provider|$url"
    }

    private fun validateRemoteModel(model: ManagedModelSettings) {
        if (model.provider.trim().lowercase() !in setOf("openai", "claude") || model.modelId.isBlank() || model.modelId.length > 200 || model.modelId.any(Char::isISOControl)) fail(422, "invalid_configuration")
        if (model.baseUrl.isBlank()) return
        val uri = runCatching { URI(model.baseUrl.trim()) }.getOrNull()
        if (uri == null || uri.scheme != "https" || uri.host.isNullOrBlank() || uri.userInfo != null || uri.rawQuery != null || uri.rawFragment != null) fail(422, "invalid_configuration")
    }

    private fun validateSearch(search: ManagedSearchSettings) {
        if (search.mode !in setOf("fallback", "aggregate") || search.sources.isEmpty() || search.sources.distinct().size != search.sources.size ||
            !setOf("bing", "duckduckgo", "exa", "brave").containsAll(search.sources)) fail(422, "invalid_configuration")
    }

    companion object {
        const val STATE_KEY = "daemon.configuration.state.v1"
        val KEY_NAMES = mapOf("modelApiKey" to "model.api_key", "exaApiKey" to "search.exa_key", "braveApiKey" to "search.brave_key")
        fun requireManagementDevice(device: PairedDevice) {
            if (!device.trustedApprovalSurface || device.platform !in setOf("ios", "macos", "android", "harmony")) throw ConfigurationApiException(403, "untrusted_device")
        }
        private fun fail(status: Int, code: String): Nothing = throw ConfigurationApiException(status, code)
    }
}
