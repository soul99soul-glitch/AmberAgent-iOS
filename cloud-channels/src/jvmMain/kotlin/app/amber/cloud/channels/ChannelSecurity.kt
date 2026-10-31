package app.amber.cloud.channels

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * 入站不可信文本沙箱封装（防提示词注入 Prompt Injection Defense）。
 */
object TaintSandbox {
    fun wrap(
        rawText: String,
        source: String,
        senderId: String,
        senderRole: SenderRole,
    ): String {
        val safeSource = escapeAttr(source)
        val safeSender = escapeAttr(senderId)
        val safeRole = senderRole.name.lowercase()
        val escapedBody = rawText
            .replace("</untrusted_input>", "&lt;/untrusted_input&gt;", ignoreCase = true)
            .replace("<untrusted_input", "&lt;untrusted_input", ignoreCase = true)
        return buildString {
            append("<untrusted_input source=\"")
            append(safeSource)
            append("\" sender_id=\"")
            append(safeSender)
            append("\" sender_role=\"")
            append(safeRole)
            append("\">\n")
            append(escapedBody)
            append("\n</untrusted_input>")
        }
    }

    private fun escapeAttr(input: String): String =
        input
            .replace("&", "&amp;")
            .replace("\"", "&quot;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
}

/**
 * 凭据占位符校验与敏感值包装器。
 *
 * - `toString()` 永远返回 `"<redacted>"`，防止直接打印或拼入异常日志时泄露 Token。
 * - 拒绝将 `<redacted>`、`[REDACTED]`、`***`、`••••`、`«已脱敏»` 等脱敏占位符写入凭据库（跨端缺陷清单 #4）。
 */
class SecretValue private constructor(
    private var bytes: ByteArray,
) {
    companion object {
        private val PLACEHOLDERS = setOf(
            "<redacted>",
            "[redacted]",
            "***",
            "••••",
            "••••••••",
            "«已脱敏»",
            "redacted",
            "null",
        )

        fun isPlaceholderCredential(raw: String): Boolean {
            val trimmed = raw.trim()
            if (trimmed.isEmpty()) return true
            if (PLACEHOLDERS.contains(trimmed.lowercase())) return true
            if (trimmed.all { it == '*' || it == '•' || it == '.' }) return true
            if (trimmed.contains("<redacted>", ignoreCase = true) ||
                trimmed.contains("[REDACTED]", ignoreCase = true) ||
                trimmed.contains("«已脱敏»")
            ) {
                return true
            }
            return false
        }

        fun of(raw: String, fieldName: String = "secret"): SecretValue {
            require(!isPlaceholderCredential(raw)) {
                "拒绝将空白或脱敏占位符写入凭据字段 $fieldName"
            }
            return SecretValue(raw.trim().toByteArray(StandardCharsets.UTF_8))
        }
    }

    /**
     * 仅在构造底层 HTTP 鉴权头或签名时读取明文。
     */
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
 * 信封加密配置保险箱（AES-256-GCM）。
 *
 * 用于在云端静息态安全存储 Bot Token、飞书 App Secret、Webhook Secret 等敏感凭据。
 */
class EncryptedConfigVault(
    masterKeyMaterial: String,
) {
    private val keySpec: SecretKeySpec
    private val random = SecureRandom()
    private val entries = mutableMapOf<String, String>()
    private val knownPlainSecrets = LinkedHashSet<String>()

    init {
        require(!SecretValue.isPlaceholderCredential(masterKeyMaterial) && masterKeyMaterial.length >= 8) {
            "主密钥无效或长度不足"
        }
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(masterKeyMaterial.toByteArray(StandardCharsets.UTF_8))
        keySpec = SecretKeySpec(digest, "AES")
    }

    fun putEncrypted(key: String, plainSecret: String) {
        require(!SecretValue.isPlaceholderCredential(plainSecret)) {
            "拒绝将占位符写入加密配置项: $key"
        }
        val trimmed = plainSecret.trim()
        knownPlainSecrets.add(trimmed)
        val iv = ByteArray(12).also { random.nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, keySpec, GCMParameterSpec(128, iv))
        cipher.updateAAD(key.toByteArray(StandardCharsets.UTF_8))
        val cipherBytes = cipher.doFinal(trimmed.toByteArray(StandardCharsets.UTF_8))
        val combined = ByteBuffer.allocate(iv.size + cipherBytes.size)
            .put(iv)
            .put(cipherBytes)
            .array()
        entries[key] = Base64.getEncoder().encodeToString(combined)
    }

    internal fun bindLogger(logger: RedactingChannelLogger) {
        knownPlainSecrets.forEach { logger.registerLiteral(it) }
    }

    fun getSecret(key: String): SecretValue? {
        val encoded = entries[key] ?: return null
        val combined = Base64.getDecoder().decode(encoded)
        require(combined.size > 12) { "密文格式损坏: $key" }
        val iv = combined.copyOfRange(0, 12)
        val cipherBytes = combined.copyOfRange(12, combined.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, keySpec, GCMParameterSpec(128, iv))
        cipher.updateAAD(key.toByteArray(StandardCharsets.UTF_8))
        val plain = String(cipher.doFinal(cipherBytes), StandardCharsets.UTF_8)
        return SecretValue.of(plain, key)
    }

    fun rawCiphertext(key: String): String? = entries[key]
}

/**
 * 通道密钥加载器：强制只从加密配置保险箱（[EncryptedConfigVault]）或环境变量读取 Token，
 * 并自动向 [RedactingChannelLogger] 注册需脱敏的敏感字面量，严禁 Token 进入日志。
 */
class ChannelSecretLoader(
    private val vault: EncryptedConfigVault? = null,
    private val envProvider: (String) -> String? = { System.getenv(it) },
    private val logger: RedactingChannelLogger,
) {
    private val activeSecrets = mutableListOf<SecretValue>()

    init {
        vault?.bindLogger(logger)
    }

    fun requireSecret(configKey: String, envName: String): SecretValue {
        val secret = resolveOptionalSecret(configKey, envName)
            ?: throw IllegalStateException("未在加密配置 ($configKey) 或环境变量 ($envName) 中找到有效凭据")
        return secret
    }

    fun resolveOptionalSecret(configKey: String, envName: String): SecretValue? {
        val fromVault = vault?.getSecret(configKey)
        if (fromVault != null) {
            register(fromVault)
            return fromVault
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
     * 在通道关闭或异常终态时擦除所有已加载的凭据。
     */
    fun wipeAll() {
        activeSecrets.forEach { it.wipe() }
        activeSecrets.clear()
    }
}

/**
 * 自动脱敏日志记录器：确保任何注册的 Token、Telegram Bot URL、Bearer Token、飞书密钥绝不出现在日志中。
 */
class RedactingChannelLogger(
    private val sink: (String) -> Unit = {},
) {
    private val secretLiterals = LinkedHashSet<String>()
    private val entries = mutableListOf<String>()

    private val patternScrubbers = listOf(
        // Telegram bot token in URL or text: bot123456:ABC-DEF...
        Regex("""bot\d{5,}:[A-Za-z0-9_-]{10,}""") to "bot<redacted>",
        // Raw Telegram token shape: 123456789:AAH...
        Regex("""\b\d{6,12}:[A-Za-z0-9_-]{20,}\b""") to "<redacted>",
        // Authorization Bearer / Basic header values
        Regex("""(?i)(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}""") to "$1 <redacted>",
        // Feishu tenant_access_token / user_access_token (t-xxx / u-xxx)
        Regex("""\b[tu]-[A-Za-z0-9._-]{12,}\b""") to "<redacted>",
        // JSON fields containing secret/token/password
        Regex("""(?i)("(?:bot_token|app_secret|webhook_secret|caldav_password|tenant_access_token|secret|password|token)"\s*:\s*)"[^"]+"""") to "$1\"<redacted>\"",
        // Key-value log pairs containing secret/token/password
        Regex("""(?i)\b(bot_token|app_secret|webhook_secret|caldav_password|tenant_access_token|appSecret|password|pass|secret|token)\s*=\s*[^\s,;)]+""") to "$1=<redacted>",
    )

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
                result = result.replace(literal, "<redacted>")
            }
        }
        for ((regex, replacement) in patternScrubbers) {
            result = regex.replace(result, replacement)
        }
        return result
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
 * 主人身份绑定管理器（支持 `/bind <一次性码>`，一次性码 3 分钟有效且单次消费即刻销毁）。
 *
 * 严格遵循 §7.3：
 * - Telegram 使用不可伪造的数字 `from.id`，飞书使用 `open_id` (`ou_xxx`)；
 * - 未绑定或非主人发来的私聊/群聊消息一律拒绝（[InboundGateVerdict.RejectedNonOwner]）。
 */
class OwnerBindingManager(
    private val clockMs: () -> Long = { System.currentTimeMillis() },
    private val codeTtlMs: Long = 3 * 60 * 1000L,
) {
    private data class PendingCode(
        val code: String,
        val expiresAtMs: Long,
    )

    private val random = SecureRandom()
    private val alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
    private val pendingCodes = mutableMapOf<String, PendingCode>()
    private val boundOwners = mutableMapOf<String, MutableSet<String>>()

    /**
     * 生成形如 `A9F3-7K2M` 的一次性绑定码。
     */
    @Synchronized
    fun generateOneTimeCode(): String {
        pruneExpiredCodes()
        val part1 = (1..4).map { alphabet[random.nextInt(alphabet.length)] }.joinToString("")
        val part2 = (1..4).map { alphabet[random.nextInt(alphabet.length)] }.joinToString("")
        val code = "$part1-$part2"
        pendingCodes[code] = PendingCode(code = code, expiresAtMs = clockMs() + codeTtlMs)
        return code
    }

    /**
     * 供配置预置已绑定的主人 ID（可选）。
     */
    @Synchronized
    fun bindOwnerDirectly(channelId: String, senderId: String) {
        val cleanSender = senderId.trim()
        require(cleanSender.isNotEmpty() && !cleanSender.startsWith("@")) {
            "主人绑定必须使用平台不可变 ID（如 Telegram 数字 ID 或飞书 open_id），禁止使用可变 @username: $senderId"
        }
        boundOwners.getOrPut(channelId) { mutableSetOf() }.add(cleanSender)
    }

    @Synchronized
    fun isOwner(channelId: String, senderId: String): Boolean {
        return boundOwners[channelId]?.contains(senderId.trim()) == true
    }

    /**
     * 校验入站消息：处理 `/bind <一次性码>`，或校验发送者是否为已绑定主人。
     */
    @Synchronized
    fun evaluate(rawMessage: InboundMessage): InboundGateVerdict {
        pruneExpiredCodes()
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
            if (rawMessage.chatType != ChatType.DIRECT) {
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
            // 一次性消费：立即销毁该绑定码
            pendingCodes.remove(codeArg)
            boundOwners.getOrPut(rawMessage.channelId) { mutableSetOf() }.add(cleanSender)
            return InboundGateVerdict.BoundSuccess(
                channelId = rawMessage.channelId,
                ownerSenderId = cleanSender,
                replyMessage = "已成功绑定主人身份（${rawMessage.channelId}:$cleanSender）。",
            )
        }

        if (!isOwner(rawMessage.channelId, cleanSender)) {
            return InboundGateVerdict.RejectedNonOwner(
                channelId = rawMessage.channelId,
                senderId = cleanSender,
                reason = "发送者不是已绑定的主人，拒绝响应",
            )
        }

        val verifiedMessage = rawMessage.copy(
            senderRole = SenderRole.OWNER,
            tainted = true,
            sandboxedText = TaintSandbox.wrap(
                rawText = rawMessage.text,
                source = "${rawMessage.channelId}:${rawMessage.chatType.name.lowercase()}:${rawMessage.chatId}",
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
}

/**
 * 入站消息去重器（防止 Webhook 重试或 Long Polling 重叠导致重复消费）。
 */
class InboundMessageDeduplicator(
    private val maxEntries: Int = 1_000,
) {
    private val seenKeys = LinkedHashSet<String>()

    /**
     * 若首次见到则返回 `true` 并记录；若已存在则返回 `false`。
     */
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
 *
 * - 支持最多 [LIMIT] (200) 条记录，超限按时间淘汰最旧条目；
 * - 同一幂等键并发调用通过协程锁排队，后续调用直接返回带 `replayed = true` 的缓存回执，绝不重复外发。
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

        /**
         * FNV-1a 8 位十六进制短摘要（与 `DesktopFeishuIdempotency.shortDigest` 算法完全一致）。
         */
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
 * IM 审批按钮与回调门禁（落实跨端已知缺陷清单 #1 与已定决策 5）。
 *
 * 核心规则：
 * 1. 出站卡片：当涉及工具审批时，IM 卡片**只渲染「拒绝」按钮**，剥离任何「批准/允许」按钮；
 * 2. 入站回调：无论用户点击了什么按钮，或攻击者伪造了 `approve:<id>` / `{"allow":true}` 回调载荷，
 *    在 IM 通道入口处一律转化为 `allow = false`（只允许拒绝，严禁产生批准结果）。
 */
object ImApprovalGate {
    private val json = Json { ignoreUnknownKeys = true }

    fun sanitizeOutboundButtons(card: OutboundCard): List<OutboundButton> {
        val approvalId = card.approvalToolCallId?.trim()
        if (!approvalId.isNullOrEmpty()) {
            // 审批卡片：强制只保留一个「拒绝」按钮
            return listOf(
                OutboundButton(
                    text = "❌ 拒绝此次操作",
                    actionData = "im_approval:deny:$approvalId",
                    style = ButtonStyle.DANGER,
                )
            )
        }
        // 非显式标记 approvalToolCallId 的普通卡片，若按钮包含试图批准的动作也强制改写为拒绝
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

    /**
     * 解析按钮回调中的审批意图。
     * 若回调是审批动作，无论原始请求是 `approve`、`allow=true` 还是 `deny`，
     * 返回的 [ImApprovalDecision.allow] 恒为 `false`（拒绝）。
     */
    fun resolveCallbackDecision(rawCallbackData: String?): ImApprovalDecision? {
        val data = rawCallbackData?.trim() ?: return null
        if (data.isEmpty()) return null

        if (data.startsWith("im_approval:")) {
            val parts = data.split(":", limit = 3)
            val verb = parts.getOrNull(1)?.lowercase() ?: "deny"
            val toolCallId = parts.getOrNull(2)?.ifBlank { "unknown" } ?: "unknown"
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
            )
        }

        if (data.startsWith("approve:") || data.startsWith("deny:")) {
            val verb = data.substringBefore(":").lowercase()
            val toolCallId = data.substringAfter(":").ifBlank { "unknown" }
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
            )
        }

        if (data.startsWith("{") && data.endsWith("}")) {
            val obj = runCatching { json.parseToJsonElement(data).jsonObject }.getOrNull() ?: return null
            val toolCallId = obj["toolCallId"]?.jsonPrimitive?.content
                ?: obj["tool_call_id"]?.jsonPrimitive?.content
                ?: return null
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
            )
        }

        return null
    }
}

/**
 * 密码学与签名工具（用于飞书 Webhook HMAC-SHA256 与事件回调 SHA-256 验签）。
 */
object ChannelCrypto {
    /**
     * 1:1 移植自 `DesktopPlugins.swift:2739` `computeFeishuWebhookSign(timestamp:secret:)`：
     * 使用 `timestamp + "\n" + secret` 作为 HMAC-SHA256 密钥，对空字节数组计算签名并 Base64 编码。
     */
    fun computeFeishuWebhookSign(timestamp: String, secret: String): String {
        val stringToSign = "$timestamp\n$secret"
        val mac = Mac.getInstance("HmacSHA256")
        val keySpec = SecretKeySpec(stringToSign.toByteArray(StandardCharsets.UTF_8), "HmacSHA256")
        mac.init(keySpec)
        val digest = mac.doFinal(ByteArray(0))
        return Base64.getEncoder().encodeToString(digest)
    }

    /**
     * 飞书事件订阅（Event Callback v2）请求头 `X-Lark-Signature` 校验：
     * `sha256(timestamp + nonce + encryptKey + rawBody)` 十六进制小写字符串恒定时间比对。
     */
    fun computeFeishuEventSignature(
        timestamp: String,
        nonce: String,
        encryptKey: String,
        rawBody: String,
    ): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val payload = (timestamp + nonce + encryptKey + rawBody).toByteArray(StandardCharsets.UTF_8)
        return digest.digest(payload).joinToString("") { "%02x".format(it) }
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
