package app.amber.cloud.security

import app.amber.core.native.AmberNativeBridge
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermission
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap

class PlaceholderCredentialException(message: String) : IllegalArgumentException(message)

/**
 * Envelope Encryption (AES-256-GCM) credential store and Ephemeral Pending Tool Secret Vault.
 *
 * - Master Key (KEK) is derived via PBKDF2-HMAC-SHA256 from either:
 *   1. systemd credential file (`$CREDENTIALS_DIRECTORY/amber_master_key` or `AMBER_MASTER_KEY_FILE`)
 *   2. environment variable `AMBER_MASTER_KEY`
 *   3. explicit constructor passphrase
 * - Random 256-bit Data Encryption Key (DEK) encrypts individual secret entries with AES-256-GCM;
 *   the DEK itself is encrypted by the KEK and stored in `secrets.enc.json` (0600).
 * - Ephemeral tool call secrets (for pending high-risk tool approvals) are held only in memory
 *   encrypted under an ephemeral session key, never persisted to disk, and wiped across all 6
 *   terminal/interruption paths (`approved`, `denied`, `cancelled`, `interrupted`,
 *   `outcome_unknown`, `cold_start_recovery`).
 */
class EnvelopeCredentialVault(
    private val vaultFile: File,
    masterSecretOverride: String? = null,
    private val pbkdf2Iterations: Int = 210_000,
) {
    private val secureRandom = SecureRandom()
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true; encodeDefaults = true }
    private val masterPassphrase: String = resolveMasterPassphrase(masterSecretOverride)
    private val ephemeralKey = ByteArray(32).also { secureRandom.nextBytes(it) }
    private val ephemeralToolSecrets = ConcurrentHashMap<String, EncryptedEphemeralBlob>()

    private data class EncryptedEphemeralBlob(
        val iv: ByteArray,
        val ciphertext: ByteArray,
    ) {
        fun wipe() {
            iv.fill(0)
            ciphertext.fill(0)
        }
    }

    @Serializable
    private data class EnvelopeStoreFormat(
        val version: Int = 1,
        val kdfSaltBase64: String,
        val kdfIterations: Int,
        val wrappedDekIvBase64: String,
        val wrappedDekCiphertextBase64: String,
        val entries: Map<String, EncryptedEntry> = emptyMap(),
    )

    @Serializable
    private data class EncryptedEntry(
        val ivBase64: String,
        val ciphertextBase64: String,
        val updatedAtEpochSeconds: Long,
    )

    @Synchronized
    fun putSecret(key: String, value: String) {
        require(key.isNotBlank()) { "凭据键名不能为空" }
        if (CredentialRedactor.isPlaceholderCredential(value)) {
            throw PlaceholderCredentialException("拒绝写入占位符凭据: $key")
        }
        val (store, dek) = loadOrInitializeStoreWithDek()
        try {
            val iv = randomBytes(12)
            val ct = AmberNativeBridge.aesGcmEncrypt(value.encodeToByteArray(), dek, iv)
                ?: error("AES-256-GCM 加密失败")
            val updatedEntries = store.entries.toMutableMap()
            updatedEntries[key] = EncryptedEntry(
                ivBase64 = iv.toB64(),
                ciphertextBase64 = ct.toB64(),
                updatedAtEpochSeconds = System.currentTimeMillis() / 1000L,
            )
            persistStore(store.copy(entries = updatedEntries))
        } finally {
            dek.fill(0)
        }
    }

    @Synchronized
    fun getSecret(key: String): String? {
        if (!vaultFile.exists()) return null
        val (store, dek) = loadOrInitializeStoreWithDek()
        try {
            val entry = store.entries[key] ?: return null
            val pt = AmberNativeBridge.aesGcmDecrypt(
                ciphertext = entry.ciphertextBase64.fromB64(),
                key = dek,
                iv = entry.ivBase64.fromB64(),
            ) ?: error("凭据解密或认证标签校验失败: $key")
            return pt.decodeToString()
        } finally {
            dek.fill(0)
        }
    }

    @Synchronized
    fun deleteSecret(key: String): Boolean {
        if (!vaultFile.exists()) return false
        val (store, dek) = loadOrInitializeStoreWithDek()
        dek.fill(0)
        if (key !in store.entries) return false
        val updated = store.entries.toMutableMap().also { it.remove(key) }
        persistStore(store.copy(entries = updated))
        return true
    }

    @Synchronized
    fun listSecretKeys(): Set<String> {
        if (!vaultFile.exists()) return emptySet()
        val store = json.decodeFromString<EnvelopeStoreFormat>(vaultFile.readText())
        return store.entries.keys
    }

    /**
     * Strips sensitive fields from tool call arguments before saving a `waiting` approval state
     * to disk, storing the raw JSON in the in-memory encrypted ephemeral vault keyed by [toolCallId].
     * Returns the redacted JSON string safe for persistence in `registry.json` and `Conversation`.
     */
    fun stashPendingToolArgs(toolCallId: String, rawArgs: JsonObject): String {
        val placeholderKey = CredentialRedactor.findPlaceholderCredentialKey(rawArgs)
        if (placeholderKey != null) {
            throw PlaceholderCredentialException("拒绝包含占位符凭据的参数: $placeholderKey")
        }
        val rawJson = json.encodeToString(JsonObject.serializer(), rawArgs)
        val iv = randomBytes(12)
        val ct = AmberNativeBridge.aesGcmEncrypt(rawJson.encodeToByteArray(), ephemeralKey, iv)
            ?: error("Ephemeral AES-GCM 加密失败")
        ephemeralToolSecrets.put(toolCallId, EncryptedEphemeralBlob(iv, ct))?.wipe()

        val redactedObject = CredentialRedactor.redactJsonElement(rawArgs) as JsonObject
        return json.encodeToString(JsonElement.serializer(), redactedObject)
    }

    /**
     * Retrieves and immediately wipes the stashed raw tool arguments for [toolCallId].
     */
    fun consumePendingToolArgs(toolCallId: String): JsonObject? {
        val blob = ephemeralToolSecrets.remove(toolCallId) ?: return null
        return try {
            val pt = AmberNativeBridge.aesGcmDecrypt(blob.ciphertext, ephemeralKey, blob.iv)
                ?: return null
            val text = pt.decodeToString()
            pt.fill(0)
            json.decodeFromString(JsonObject.serializer(), text)
        } finally {
            blob.wipe()
        }
    }

    /**
     * Wipes stashed credentials for [toolCallId] on any terminal path
     * (`approved`, `denied`, `cancelled`, `interrupted`, `outcome_unknown`, `cold_start_recovery`).
     */
    fun wipePendingToolArgs(toolCallId: String) {
        ephemeralToolSecrets.remove(toolCallId)?.wipe()
    }

    /**
     * Wipes all ephemeral tool secrets (e.g. during cold-start recovery or daemon shutdown).
     */
    fun wipeAllPendingToolArgs() {
        val keys = ephemeralToolSecrets.keys.toList()
        for (key in keys) {
            ephemeralToolSecrets.remove(key)?.wipe()
        }
    }

    fun hasPendingToolArgs(toolCallId: String): Boolean = ephemeralToolSecrets.containsKey(toolCallId)

    private fun loadOrInitializeStoreWithDek(): Pair<EnvelopeStoreFormat, ByteArray> {
        if (vaultFile.exists()) {
            val store = json.decodeFromString<EnvelopeStoreFormat>(vaultFile.readText())
            val salt = store.kdfSaltBase64.fromB64()
            val kek = AmberNativeBridge.pbkdf2HmacSha256(
                passphrase = masterPassphrase,
                salt = salt,
                iterations = store.kdfIterations,
                keySizeBytes = 32,
            ) ?: error("PBKDF2 派生主密钥失败")
            val dek = try {
                AmberNativeBridge.aesGcmDecrypt(
                    ciphertext = store.wrappedDekCiphertextBase64.fromB64(),
                    key = kek,
                    iv = store.wrappedDekIvBase64.fromB64(),
                ) ?: error("无法用当前主密钥解封 DEK（主密钥不匹配或文件已损坏）")
            } finally {
                kek.fill(0)
            }
            return store to dek
        }

        val salt = randomBytes(16)
        val dek = randomBytes(32)
        val dekIv = randomBytes(12)
        val kek = AmberNativeBridge.pbkdf2HmacSha256(
            passphrase = masterPassphrase,
            salt = salt,
            iterations = pbkdf2Iterations,
            keySizeBytes = 32,
        ) ?: error("PBKDF2 派生主密钥失败")
        val wrappedDek = try {
            AmberNativeBridge.aesGcmEncrypt(dek, kek, dekIv)
                ?: error("AES-256-GCM 封装 DEK 失败")
        } finally {
            kek.fill(0)
        }
        val initialStore = EnvelopeStoreFormat(
            version = 1,
            kdfSaltBase64 = salt.toB64(),
            kdfIterations = pbkdf2Iterations,
            wrappedDekIvBase64 = dekIv.toB64(),
            wrappedDekCiphertextBase64 = wrappedDek.toB64(),
            entries = emptyMap(),
        )
        persistStore(initialStore)
        return initialStore to dek
    }

    private fun persistStore(store: EnvelopeStoreFormat) {
        vaultFile.parentFile?.mkdirs()
        val tempFile = File(vaultFile.parentFile, "${vaultFile.name}.tmp")
        tempFile.writeText(json.encodeToString(store))
        setOwnerOnlyPermissions(tempFile)
        Files.move(
            tempFile.toPath(),
            vaultFile.toPath(),
            StandardCopyOption.REPLACE_EXISTING,
            StandardCopyOption.ATOMIC_MOVE,
        )
        setOwnerOnlyPermissions(vaultFile)
    }

    private fun randomBytes(size: Int): ByteArray = ByteArray(size).also { secureRandom.nextBytes(it) }

    private fun ByteArray.toB64(): String = Base64.getEncoder().encodeToString(this)

    private fun String.fromB64(): ByteArray = Base64.getDecoder().decode(this)

    companion object {
        fun resolveMasterPassphrase(
            overridePassphrase: String? = null,
            env: Map<String, String> = System.getenv(),
        ): String {
            if (!overridePassphrase.isNullOrBlank()) {
                return overridePassphrase.trim()
            }
            val credFileFromEnv = env["AMBER_MASTER_KEY_FILE"]?.takeIf { it.isNotBlank() }
                ?: env["CREDENTIALS_DIRECTORY"]?.takeIf { it.isNotBlank() }?.let { "$it/amber_master_key" }
            if (credFileFromEnv != null) {
                val file = File(credFileFromEnv)
                if (file.isFile && file.canRead()) {
                    val content = file.readText().trim()
                    if (content.isNotEmpty()) return content
                }
            }
            val envKey = env["AMBER_MASTER_KEY"]?.trim()
            if (!envKey.isNullOrEmpty()) {
                return envKey
            }
            return "amberd-dev-local-default-master-key"
        }

        fun setOwnerOnlyPermissions(file: File) {
            runCatching {
                Files.setPosixFilePermissions(
                    file.toPath(),
                    setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
                )
            }
        }
    }
}
