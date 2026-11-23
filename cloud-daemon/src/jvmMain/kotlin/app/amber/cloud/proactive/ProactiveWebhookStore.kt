package app.amber.cloud.proactive

import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.EnvelopeCredentialVault
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * 个人入站 Webhook 元数据记录（存于 `dataDir/proactive/webhooks.json`，权限 `0600`）。
 * 绝不包含明文 secret，独立密钥全部加密存放于 [EnvelopeCredentialVault]。
 */
@Serializable
data class ProactiveWebhookRecord(
    val id: String,
    val name: String,
    val enabled: Boolean = true,
    val instruction: String = "",
    val createdAtMs: Long,
    val lastTriggeredAtMs: Long? = null,
    val triggerCount: Int = 0,
)

/**
 * 仅在创建 Webhook 时一次性返回明文 `secret` 与相对入站路径 `/v2/triggers/webhook/{id}`。
 */
@Serializable
data class CreatedProactiveWebhook(
    val webhook: ProactiveWebhookRecord,
    val secret: String,
    val inboundPath: String,
)

/**
 * 云端个人签名入站 Webhook 存储与恒定时间验签器（P1-3A）。
 */
class ProactiveWebhookStore(
    proactiveDir: File,
    private val vault: EnvelopeCredentialVault,
    private val clockMs: () -> Long = { System.currentTimeMillis() },
) {
    private val file = File(proactiveDir, "webhooks.json")
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true; encodeDefaults = true }
    private val secureRandom = SecureRandom()
    private val records = LinkedHashMap<String, ProactiveWebhookRecord>()

    init {
        ProactiveFilePersistence.ensureOwnerOnlyDir(proactiveDir)
        loadFromDisk()
    }

    @Synchronized
    fun list(): List<ProactiveWebhookRecord> = records.values.sortedBy { it.createdAtMs }

    @Synchronized
    fun get(id: String): ProactiveWebhookRecord? = records[id]

    @Synchronized
    fun create(
        name: String,
        instruction: String = "",
        enabled: Boolean = true,
        nowMs: Long = clockMs(),
    ): CreatedProactiveWebhook {
        val cleanName = CredentialRedactor.redact(name.trim()).take(120)
        require(cleanName.isNotEmpty()) { "Webhook 名称不能为空" }
        val cleanInstruction = CredentialRedactor.redact(instruction.trim()).take(1_000)
        val id = "wh_" + UUID.randomUUID().toString().replace("-", "").take(12)
        val secretBytes = ByteArray(32).also { secureRandom.nextBytes(it) }
        val secret = "whsec_" + secretBytes.joinToString("") { "%02x".format(it) }

        vault.putSecret(vaultKey(id), secret)
        val record = ProactiveWebhookRecord(
            id = id,
            name = cleanName,
            enabled = enabled,
            instruction = cleanInstruction,
            createdAtMs = nowMs,
        )
        records[id] = record
        persistToDisk()
        return CreatedProactiveWebhook(
            webhook = record,
            secret = secret,
            inboundPath = "/v2/triggers/webhook/$id",
        )
    }

    @Synchronized
    fun update(
        id: String,
        name: String? = null,
        enabled: Boolean? = null,
        instruction: String? = null,
    ): ProactiveWebhookRecord? {
        val existing = records[id] ?: return null
        val nextName = name?.trim()?.takeIf { it.isNotEmpty() }
            ?.let { CredentialRedactor.redact(it).take(120) } ?: existing.name
        val nextEnabled = enabled ?: existing.enabled
        val nextInstruction = instruction?.trim()
            ?.let { CredentialRedactor.redact(it).take(1_000) } ?: existing.instruction
        val updated = existing.copy(
            name = nextName,
            enabled = nextEnabled,
            instruction = nextInstruction,
        )
        records[id] = updated
        persistToDisk()
        return updated
    }

    @Synchronized
    fun delete(id: String): Boolean {
        val removed = records.remove(id) != null
        vault.deleteSecret(vaultKey(id))
        if (removed) persistToDisk()
        return removed
    }

    @Synchronized
    fun recordTriggered(id: String, nowMs: Long = clockMs()): ProactiveWebhookRecord? {
        val existing = records[id] ?: return null
        val updated = existing.copy(
            lastTriggeredAtMs = nowMs,
            triggerCount = existing.triggerCount + 1,
        )
        records[id] = updated
        persistToDisk()
        return updated
    }

    /**
     * 恒定时间验签：
     * - 若携带 `X-Amber-Signature`（格式 `sha256=<hex>`），使用该 Webhook 在 Vault 中的 secret 对原始请求体做 HMAC-SHA256 恒定时间比对；
     * - 否则若携带 `Authorization: Bearer <secret>`，对密钥做恒定时间比对。
     */
    fun verifyInboundAuth(
        webhookId: String,
        rawBodyBytes: ByteArray,
        signatureHeader: String?,
        authorizationHeader: String?,
    ): Boolean {
        val secret = vault.getSecret(vaultKey(webhookId))?.takeIf { it.isNotBlank() } ?: return false
        if (signatureHeader != null) {
            val signature = signatureHeader.trim()
            if (!signature.startsWith("sha256=", ignoreCase = true)) return false
            val hex = signature.substring(7)
            if (hex.length != 64 || hex.any { it !in "0123456789abcdefABCDEF" }) return false
            val expectedHex = computeHmacSha256Hex(secret, rawBodyBytes)
            return MessageDigest.isEqual(
                expectedHex.toByteArray(Charsets.US_ASCII),
                hex.lowercase().toByteArray(Charsets.US_ASCII),
            )
        }
        val auth = authorizationHeader?.trim().orEmpty()
        if (auth.startsWith("Bearer ", ignoreCase = true)) {
            val digest = MessageDigest.getInstance("SHA-256")
            return MessageDigest.isEqual(
                digest.digest(secret.toByteArray(Charsets.UTF_8)),
                digest.digest(auth.substringAfter(' ').trim().toByteArray(Charsets.UTF_8)),
            )
        }
        return false
    }

    private fun loadFromDisk() {
        if (!file.isFile) return
        val list = runCatching {
            json.decodeFromString<List<ProactiveWebhookRecord>>(file.readText())
        }.getOrNull() ?: return
        records.clear()
        list.forEach { records[it.id] = it }
    }

    private fun persistToDisk() {
        ProactiveFilePersistence.atomicWrite0600(file, json.encodeToString(records.values.toList()))
    }

    companion object {
        fun vaultKey(webhookId: String): String = "proactive:webhook:$webhookId:secret"

        fun computeHmacSha256Hex(secret: String, rawBodyBytes: ByteArray): String {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(secret.toByteArray(StandardCharsets.UTF_8), "HmacSHA256"))
            return mac.doFinal(rawBodyBytes).joinToString("") { "%02x".format(it) }
        }
    }
}
