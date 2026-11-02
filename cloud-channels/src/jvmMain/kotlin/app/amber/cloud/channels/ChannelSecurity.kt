package app.amber.cloud.channels

import app.amber.cloud.channel.ButtonStyle
import app.amber.cloud.channel.ConversationScope
import app.amber.cloud.channel.ImApprovalDecision
import app.amber.cloud.channel.InboundMessage
import app.amber.cloud.channel.OutboundButton
import app.amber.cloud.channel.OutboundCard
import app.amber.cloud.channel.OutboundReceipt
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.channel.TaintSandbox
import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.EnvelopeCredentialVault
import app.amber.cloud.security.PlaceholderCredentialException
import app.amber.core.native.AmberNativeBridge
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/**
 * 凭据占位符校验与敏感值包装器。
 *
 * 委托 [CredentialRedactor.isPlaceholderCredential] 进行统一占位符拦截（跨端缺陷清单 #4），
 * `toString()` 永远返回 `"<redacted>"`。
 */
class SecretValue private constructor(
    private var bytes: ByteArray,
) {
    companion object {
        fun isPlaceholderCredential(raw: String): Boolean {
            val trimmed = raw.trim()
            if (trimmed.isEmpty()) return true
            return CredentialRedactor.isPlaceholderCredential(trimmed)
        }

        fun of(raw: String, fieldName: String = "secret"): SecretValue {
            if (isPlaceholderCredential(raw)) {
                throw PlaceholderCredentialException("拒绝将空白或脱敏占位符写入凭据字段 $fieldName")
            }
            return SecretValue(raw.trim().toByteArray(StandardCharsets.UTF_8))
        }
    }

    internal fun expose(): String {
        check(bytes.isNotEmpty()) { "凭据已被擦除，无法继续读取" }
        return String(bytes, StandardCharsets.UTF_8)
    }

    /**
     * 终态或停止通道时立即擦除内存中的密钥字节（跨端缺陷清单 #2）。
     */
    fun wipe() {
        bytes.fill(0)
        bytes = ByteArray(0)
    }

    val isWiped: Boolean
        get() = bytes.isEmpty()

    override fun toString(): String = "<redacted>"

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is SecretValue) return false
        return MessageDigest.isEqual(this.bytes, other.bytes)
    }

    override fun hashCode(): Int = 31
}

/**
 * 加密配置保险箱适配器：直接委托给统一的 [EnvelopeCredentialVault]（删除重复的 AES-GCM 实现）。
 */
class EncryptedConfigVault(
    val delegate: EnvelopeCredentialVault,
) {
    private val knownPlainSecrets = LinkedHashSet<String>()

    constructor(
        masterKeyMaterial: String,
        vaultFile: File = Files.createTempFile("amber-channel-vault-", ".enc.json").toFile().also {
            it.delete()
            it.deleteOnExit()
        },
    ) : this(createDelegate(masterKeyMaterial, vaultFile))

    companion object {
        private fun createDelegate(masterKeyMaterial: String, vaultFile: File): EnvelopeCredentialVault {
            if (SecretValue.isPlaceholderCredential(masterKeyMaterial) || masterKeyMaterial.length < 8) {
                throw PlaceholderCredentialException("主密钥无效或长度不足")
            }
            return EnvelopeCredentialVault(
                vaultFile = vaultFile,
                masterSecretOverride = masterKeyMaterial,
                pbkdf2Iterations = 10_000,
            )
        }
    }

    fun putEncrypted(key: String, plainSecret: String) {
        if (SecretValue.isPlaceholderCredential(plainSecret)) {
            throw PlaceholderCredentialException("拒绝将占位符写入加密配置项: $key")
        }
        val trimmed = plainSecret.trim()
        knownPlainSecrets.add(trimmed)
        delegate.putSecret(key, trimmed)
    }

    internal fun bindLogger(logger: RedactingChannelLogger) {
        knownPlainSecrets.forEach { logger.registerLiteral(it) }
    }

    fun getSecret(key: String): SecretValue? {
        val plain = delegate.getSecret(key) ?: return null
        return SecretValue.of(plain, key)
    }
}

/**
 * 通道密钥加载器：统一从 [EnvelopeCredentialVault]（或 [EncryptedConfigVault] 委托）及环境变量读取 Token，
 * 并自动向 [RedactingChannelLogger] 注册需脱敏的敏感字面量，严禁 Token 进入日志。
 */
class ChannelSecretLoader(
    private val envelopeVault: EnvelopeCredentialVault? = null,
    private val configVault: EncryptedConfigVault? = null,
    private val envProvider: (String) -> String? = { System.getenv(it) },
    private val logger: RedactingChannelLogger,
) {
    constructor(
        vault: EncryptedConfigVault? = null,
        envProvider: (String) -> String? = { System.getenv(it) },
        logger: RedactingChannelLogger,
    ) : this(
        envelopeVault = vault?.delegate,
        configVault = vault,
        envProvider = envProvider,
        logger = logger,
    )

    constructor(
        vault: EnvelopeCredentialVault,
        envProvider: (String) -> String? = { System.getenv(it) },
        logger: RedactingChannelLogger,
    ) : this(
        envelopeVault = vault,
        configVault = null,
        envProvider = envProvider,
        logger = logger,
    )

    private val activeSecrets = mutableListOf<SecretValue>()

    init {
        configVault?.bindLogger(logger)
    }

    fun requireSecret(configKey: String, envName: String): SecretValue {
        return resolveOptionalSecret(configKey, envName)
            ?: throw IllegalStateException("未在统一加密凭据库 ($configKey) 或环境变量 ($envName) 中找到有效凭据")
    }

    fun resolveOptionalSecret(configKey: String, envName: String): SecretValue? {
        val rawFromVault = envelopeVault?.getSecret(configKey)
        if (!rawFromVault.isNullOrEmpty()) {
            val secret = SecretValue.of(rawFromVault, configKey)
            register(secret)
            return secret
        }
        val fromEnv = envProvider(envName)?.trim()
        if (!fromEnv.isNullOrEmpty()) {
            val secret = SecretValue.of(fromEnv, envName)
            register(secret)
            return secret
        }
        return null
    }

    private fun register(secret: SecretValue) {
        logger.registerSecret(secret)
        activeSecrets.add(secret)
    }

    /**
     * 在通道关闭或异常终态时擦除所有已加载的内存凭据（跨端缺陷清单 #2）。
     */
    fun wipeAll() {
        activeSecrets.forEach { it.wipe() }
        activeSecrets.clear()
    }
}

/**
 * 自动脱敏日志记录器：直接委托给统一的 [CredentialRedactor]，删除重复的脱敏正则实现。
 */
class RedactingChannelLogger(
    private val sink: (String) -> Unit = {},
) {
    private val secretLiterals = LinkedHashSet<String>()
    private val entries = mutableListOf<String>()

    @Synchronized
    fun registerSecret(secret: SecretValue) {
        if (!secret.isWiped) {
            val raw = secret.expose()
            if (raw.length >= 4) {
                secretLiterals.add(raw)
            }
        }
    }

    @Synchronized
    fun registerLiteral(rawSecret: String) {
        val trimmed = rawSecret.trim()
        if (trimmed.length >= 4) {
            secretLiterals.add(trimmed)
        }
    }

    @Synchronized
    fun redact(message: String): String {
        var result = message
        for (literal in secretLiterals) {
            if (literal.isNotEmpty() && result.contains(literal)) {
                result = result.replace(literal, CredentialRedactor.MASK)
            }
        }
        return CredentialRedactor.redact(result)
    }

    @Synchronized
    fun info(message: String) = record("INFO", message)

    @Synchronized
    fun warn(message: String) = record("WARN", message)

    @Synchronized
    fun error(message: String, throwable: Throwable? = null) {
        val errText = if (throwable != null) "$message | error=${throwable.message}" else message
        record("ERROR", errText)
    }

    @Synchronized
    fun dumpLogs(): List<String> = entries.toList()

    private fun record(level: String, rawMessage: String) {
        val clean = redact("[$level] $rawMessage")
        entries.add(clean)
        sink(clean)
    }
}

/**
 * 入站主人绑定与权限门禁结果。
 */
sealed class InboundGateVerdict {
    data class Allowed(val message: InboundMessage) : InboundGateVerdict()
    data class BoundSuccess(val channelId: String, val ownerSenderId: String, val replyMessage: String) : InboundGateVerdict()
    data class RejectedNonOwner(val channelId: String, val senderId: String, val reason: String) : InboundGateVerdict()
    data class DuplicateIgnored(val channelId: String, val messageId: String) : InboundGateVerdict()
}

/**
 * 主人身份绑定管理器（支持 `/bind <一次性码>`，3 分钟有效且单次消费即刻销毁，并支持落盘持久化）。
 *
 * 严格遵循 C3 v2 与 §7.3：
 * - Telegram 使用不可伪造的数字 `from.id`，飞书使用 `open_id` (`ou_xxx`)；
 * - 未绑定或非主人发来的私聊/群聊消息一律拒绝（[InboundGateVerdict.RejectedNonOwner]）；
 * - 持久化已绑定的主人 ID 与私聊 `chatId`，使重启进程后主人绑定与主动推送目标不丢失。
 */
class OwnerBindingManager(
    private val clockMs: () -> Long = { System.currentTimeMillis() },
    private val codeTtlMs: Long = 3 * 60 * 1000L,
    private val persistenceFile: File? = null,
) {
    private data class PendingCode(
        val code: String,
        val expiresAtMs: Long,
    )

    @Serializable
    private data class PersistedBindings(
        val boundOwners: Map<String, Set<String>> = emptyMap(),
        val ownerDirectChatIds: Map<String, String> = emptyMap(),
    )

    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true; encodeDefaults = true }
    private val random = SecureRandom()
    private val alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
    private val pendingCodes = mutableMapOf<String, PendingCode>()
    private val boundOwners = mutableMapOf<String, MutableSet<String>>()
    private val ownerDirectChatIds = mutableMapOf<String, String>()

    init {
        loadFromDisk()
    }

    @Synchronized
    fun generateOneTimeCode(): String {
        pruneExpiredCodes()
        val part1 = (1..4).map { alphabet[random.nextInt(alphabet.length)] }.joinToString("")
        val part2 = (1..4).map { alphabet[random.nextInt(alphabet.length)] }.joinToString("")
        val code = "$part1-$part2"
        pendingCodes[code] = PendingCode(code = code, expiresAtMs = clockMs() + codeTtlMs)
        return code
    }

    @Synchronized
    fun bindOwnerDirectly(channelId: String, senderId: String, directChatId: String? = null) {
        val cleanChannel = channelId.trim().lowercase()
        val cleanSender = senderId.trim()
        require(cleanSender.isNotEmpty() && !cleanSender.startsWith("@")) {
            "主人绑定必须使用平台不可变 ID（如 Telegram 数字 ID 或飞书 open_id），禁止使用可变 @username: $senderId"
        }
        boundOwners.getOrPut(cleanChannel) { mutableSetOf() }.add(cleanSender)
        ownerDirectChatIds[cleanChannel] = directChatId?.trim()?.takeIf { it.isNotEmpty() } ?: cleanSender
        saveToDisk()
    }

    @Synchronized
    fun isOwner(channelId: String, senderId: String): Boolean {
        return boundOwners[channelId.trim().lowercase()]?.contains(senderId.trim()) == true
    }

    @Synchronized
    fun getOwnerDirectChatId(channelId: String): String? {
        val cleanChannel = channelId.trim().lowercase()
        return ownerDirectChatIds[cleanChannel] ?: boundOwners[cleanChannel]?.firstOrNull()
    }

    @Synchronized
    fun allBoundOwnerChatTargets(): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for ((ch, owners) in boundOwners) {
            val chatId = ownerDirectChatIds[ch] ?: owners.firstOrNull() ?: continue
            out[ch] = chatId
        }
        return out
    }

    @Synchronized
    fun evaluate(rawMessage: InboundMessage): InboundGateVerdict {
        pruneExpiredCodes()
        val cleanChannel = rawMessage.channelId.trim().lowercase()
        val cleanSender = rawMessage.senderId.trim()
        if (cleanSender.isEmpty() || cleanSender.startsWith("@")) {
            return InboundGateVerdict.RejectedNonOwner(
                channelId = rawMessage.channelId,
                senderId = rawMessage.senderId,
                reason = "无效的发送者身份标识（禁止使用可变 @username 鉴权）",
            )
        }

        val trimmedText = rawMessage.text.trim()
        if (trimmedText.startsWith("/bind")) {
            if (rawMessage.scope != ConversationScope.DIRECT) {
                return InboundGateVerdict.RejectedNonOwner(
                    channelId = rawMessage.channelId,
                    senderId = cleanSender,
                    reason = "主人绑定命令 /bind 仅允许在私聊中执行",
                )
            }
            val codeArg = trimmedText.removePrefix("/bind").trim().uppercase()
            val pending = pendingCodes[codeArg]
            if (pending == null || pending.expiresAtMs < clockMs()) {
                pendingCodes.remove(codeArg)
                return InboundGateVerdict.RejectedNonOwner(
                    channelId = rawMessage.channelId,
                    senderId = cleanSender,
                    reason = "绑定码无效或已过期",
                )
            }
            pendingCodes.remove(codeArg)
            boundOwners.getOrPut(cleanChannel) { mutableSetOf() }.add(cleanSender)
            ownerDirectChatIds[cleanChannel] = rawMessage.chatId.trim().ifEmpty { cleanSender }
            saveToDisk()
            return InboundGateVerdict.BoundSuccess(
                channelId = rawMessage.channelId,
                ownerSenderId = cleanSender,
                replyMessage = "已成功绑定主人身份（${rawMessage.channelId}:$cleanSender）。",
            )
        }

        if (!isOwner(cleanChannel, cleanSender)) {
            return InboundGateVerdict.RejectedNonOwner(
                channelId = rawMessage.channelId,
                senderId = cleanSender,
                reason = "发送者不是已绑定的主人，拒绝响应",
            )
        }

        if (rawMessage.scope == ConversationScope.DIRECT && rawMessage.chatId.isNotBlank()) {
            if (ownerDirectChatIds[cleanChannel] != rawMessage.chatId.trim()) {
                ownerDirectChatIds[cleanChannel] = rawMessage.chatId.trim()
                saveToDisk()
            }
        }

        val verifiedMessage = rawMessage.copy(
            senderRole = SenderRole.OWNER,
            tainted = true,
            sandboxedText = TaintSandbox.wrap(
                rawText = rawMessage.text,
                source = "${rawMessage.channelId}:${rawMessage.scope.name.lowercase()}:${rawMessage.chatId}",
                senderId = cleanSender,
                senderRole = SenderRole.OWNER,
            ),
        )
        return InboundGateVerdict.Allowed(verifiedMessage)
    }

    private fun pruneExpiredCodes() {
        val now = clockMs()
        val iter = pendingCodes.iterator()
        while (iter.hasNext()) {
            if (iter.next().value.expiresAtMs < now) {
                iter.remove()
            }
        }
    }

    private fun loadFromDisk() {
        val file = persistenceFile ?: return
        if (!file.isFile) return
        val loaded = runCatching {
            json.decodeFromString<PersistedBindings>(file.readText())
        }.getOrNull() ?: return
        loaded.boundOwners.forEach { (ch, set) ->
            boundOwners.getOrPut(ch) { mutableSetOf() }.addAll(set)
        }
        ownerDirectChatIds.putAll(loaded.ownerDirectChatIds)
    }

    private fun saveToDisk() {
        val file = persistenceFile ?: return
        runCatching {
            file.parentFile?.mkdirs()
            val snapshot = PersistedBindings(
                boundOwners = boundOwners.mapValues { it.value.toSet() },
                ownerDirectChatIds = ownerDirectChatIds.toMap(),
            )
            file.writeText(json.encodeToString(snapshot))
        }
    }
}

/**
 * 入站消息去重器（防止 Webhook 重试或 Long Polling 重叠导致重复消费）。
 */
class InboundMessageDeduplicator(
    private val maxEntries: Int = 1_000,
) {
    private val seenKeys = LinkedHashSet<String>()

    @Synchronized
    fun markIfFirstSeen(channelId: String, messageId: String): Boolean {
        val cleanId = messageId.trim()
        if (cleanId.isEmpty()) return false
        val composite = "$channelId:$cleanId"
        if (seenKeys.contains(composite)) {
            return false
        }
        seenKeys.add(composite)
        while (seenKeys.size > maxEntries) {
            val oldest = seenKeys.iterator().next()
            seenKeys.remove(oldest)
        }
        return true
    }
}

/**
 * 出站写操作幂等存储（移植自 `DesktopPluginIdempotency.swift`）。
 */
class OutboundIdempotencyStore(
    private val maxEntries: Int = LIMIT,
) {
    companion object {
        const val STORAGE_PREFIX = "idem:"
        const val LIMIT = 200
        const val MAX_KEY_LENGTH = 128

        fun normalizeKey(raw: String?): String? {
            val trimmed = raw?.trim() ?: return null
            if (trimmed.isEmpty() || trimmed.length > MAX_KEY_LENGTH) return null
            return trimmed
        }

        fun shortDigest(text: String): String {
            var hash = 2_166_136_261u
            for (byte in text.toByteArray(StandardCharsets.UTF_8)) {
                hash = hash xor (byte.toUInt() and 0xFFu)
                hash *= 16_777_619u
            }
            return hash.toString(16).padStart(8, '0')
        }
    }

    @Serializable
    data class StoredEntry(
        val key: String,
        val receipt: OutboundReceipt,
        val recordedAtMs: Long,
    )

    private val globalMutex = Mutex()
    private val keyMutexes = mutableMapOf<String, Mutex>()
    private val storage = LinkedHashMap<String, StoredEntry>()

    suspend fun executeIdempotent(
        rawKey: String?,
        channelId: String,
        block: suspend () -> OutboundReceipt,
    ): OutboundReceipt {
        val key = normalizeKey(rawKey) ?: return block()
        val fullKey = "$STORAGE_PREFIX$channelId:$key"
        val keyMutex = globalMutex.withLock {
            keyMutexes.getOrPut(fullKey) { Mutex() }
        }
        return keyMutex.withLock {
            val existing = globalMutex.withLock { storage[fullKey] }
            if (existing != null) {
                return@withLock existing.receipt.copy(
                    replayed = true,
                    note = "同一个幂等键此前已执行过，本次没有再次发送消息。",
                )
            }
            val fresh = block()
            if (fresh.ok) {
                globalMutex.withLock {
                    storage[fullKey] = StoredEntry(
                        key = key,
                        receipt = fresh,
                        recordedAtMs = System.currentTimeMillis(),
                    )
                    while (storage.size > maxEntries) {
                        val oldestKey = storage.entries.minByOrNull { it.value.recordedAtMs }?.key ?: break
                        storage.remove(oldestKey)
                    }
                }
            }
            fresh
        }
    }
}

/**
 * IM 审批按钮与回调门禁（落实跨端已知缺陷清单 #1 与 C3 v2 审批语义）。
 *
 * 核心规则：
 * 1. 出站卡片：当涉及工具审批时，IM 卡片**只渲染「拒绝」按钮**，剥离任何「批准/允许」按钮；
 * 2. 入站回调：无论用户点击了什么按钮，或攻击者伪造了 `approve:<id>` / `{"allow":true}` 回调载荷，
 *    在 IM 通道入口处一律转化为 `allow = false`（只允许拒绝，严禁产生批准结果），并标记 `coercedFromApproveAttempt = true`。
 */
object ImApprovalGate {
    private val json = Json { ignoreUnknownKeys = true }

    fun sanitizeOutboundButtons(card: OutboundCard): List<OutboundButton> {
        val approvalId = card.approvalToolCallId?.trim()
        if (!approvalId.isNullOrEmpty()) {
            return listOf(
                OutboundButton(
                    text = "❌ 拒绝此次操作",
                    actionData = "im_approval:deny:$approvalId",
                    style = ButtonStyle.DANGER,
                )
            )
        }
        return card.buttons.map { button ->
            val lower = button.actionData.lowercase()
            if (lower.startsWith("im_approval:approve:") || lower.startsWith("approve:")) {
                val targetId = button.actionData.substringAfterLast(":")
                OutboundButton(
                    text = "❌ 拒绝此次操作",
                    actionData = "im_approval:deny:$targetId",
                    style = ButtonStyle.DANGER,
                )
            } else {
                button
            }
        }
    }

    fun resolveCallbackDecision(rawCallbackData: String?): ImApprovalDecision? {
        val data = rawCallbackData?.trim() ?: return null
        if (data.isEmpty()) return null

        if (data.startsWith("im_approval:")) {
            val parts = data.split(":", limit = 3)
            val verb = parts.getOrNull(1)?.lowercase() ?: "deny"
            val rawTarget = parts.getOrNull(2)?.ifBlank { "unknown" } ?: "unknown"
            val (sessionKey, toolCallId) = splitTarget(rawTarget)
            val attemptedApprove = verb == "approve" || verb == "allow"
            return ImApprovalDecision(
                toolCallId = toolCallId,
                allow = false,
                decision = "DENIED",
                coercedFromApproveAttempt = attemptedApprove,
                reason = if (attemptedApprove) {
                    "IM 通道严禁批准操作，已强制拦截并转为拒绝（请前往已配对授信 App 前台批准）"
                } else {
                    "已在 IM 通道拒绝该操作"
                },
                sessionKey = sessionKey,
            )
        }

        if (data.startsWith("approve:") || data.startsWith("deny:")) {
            val verb = data.substringBefore(":").lowercase()
            val rawTarget = data.substringAfter(":").ifBlank { "unknown" }
            val (sessionKey, toolCallId) = splitTarget(rawTarget)
            val attemptedApprove = verb == "approve"
            return ImApprovalDecision(
                toolCallId = toolCallId,
                allow = false,
                decision = "DENIED",
                coercedFromApproveAttempt = attemptedApprove,
                reason = if (attemptedApprove) {
                    "IM 通道严禁批准操作，已强制拦截并转为拒绝（请前往已配对授信 App 前台批准）"
                } else {
                    "已在 IM 通道拒绝该操作"
                },
                sessionKey = sessionKey,
            )
        }

        if (data.startsWith("{") && data.endsWith("}")) {
            val obj = runCatching { json.parseToJsonElement(data).jsonObject }.getOrNull() ?: return null
            val toolCallId = obj["toolCallId"]?.jsonPrimitive?.content
                ?: obj["tool_call_id"]?.jsonPrimitive?.content
                ?: return null
            val sessionKey = obj["sessionKey"]?.jsonPrimitive?.content
                ?: obj["session_key"]?.jsonPrimitive?.content
            val requestedAllow = obj["allow"]?.jsonPrimitive?.booleanOrNull == true ||
                obj["action"]?.jsonPrimitive?.content?.equals("approve", ignoreCase = true) == true
            return ImApprovalDecision(
                toolCallId = toolCallId,
                allow = false,
                decision = "DENIED",
                coercedFromApproveAttempt = requestedAllow,
                reason = if (requestedAllow) {
                    "IM 通道严禁批准操作，已强制拦截 allow=true 并转为拒绝"
                } else {
                    "已在 IM 通道拒绝该操作"
                },
                sessionKey = sessionKey,
            )
        }

        return null
    }

    private fun splitTarget(rawTarget: String): Pair<String?, String> {
        return if (rawTarget.contains('|')) {
            val sessionKey = rawTarget.substringBefore('|').takeIf { it.isNotBlank() }
            val toolCallId = rawTarget.substringAfter('|').ifBlank { "unknown" }
            sessionKey to toolCallId
        } else {
            null to rawTarget
        }
    }
}

/**
 * 密码学与签名工具：委托给 `:core:native` [AmberNativeBridge] 的 SHA-256 与 HMAC-SHA256 实现。
 */
object ChannelCrypto {
    fun computeFeishuWebhookSign(timestamp: String, secret: String): String {
        val stringToSign = "$timestamp\n$secret"
        val digest = AmberNativeBridge.hmacSha256(
            key = stringToSign.toByteArray(StandardCharsets.UTF_8),
            message = ByteArray(0),
        ) ?: error("HMAC-SHA256 unavailable on JVM")
        return Base64.getEncoder().encodeToString(digest)
    }

    fun computeFeishuEventSignature(
        timestamp: String,
        nonce: String,
        encryptKey: String,
        rawBody: String,
    ): String {
        val payload = (timestamp + nonce + encryptKey + rawBody).toByteArray(StandardCharsets.UTF_8)
        val digest = AmberNativeBridge.sha256(payload) ?: error("SHA-256 unavailable on JVM")
        return digest.joinToString("") { "%02x".format(it) }
    }

    fun verifyFeishuEventSignature(
        timestamp: String,
        nonce: String,
        encryptKey: String,
        rawBody: String,
        expectedSignatureHex: String,
    ): Boolean {
        if (timestamp.isBlank() || nonce.isBlank() || expectedSignatureHex.isBlank()) return false
        val computed = computeFeishuEventSignature(timestamp, nonce, encryptKey, rawBody)
        return MessageDigest.isEqual(
            computed.lowercase().toByteArray(StandardCharsets.UTF_8),
            expectedSignatureHex.trim().lowercase().toByteArray(StandardCharsets.UTF_8),
        )
    }
}
