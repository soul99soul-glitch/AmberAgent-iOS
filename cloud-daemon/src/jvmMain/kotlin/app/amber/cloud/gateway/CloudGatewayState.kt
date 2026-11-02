package app.amber.cloud.gateway

import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.EnvelopeCredentialVault
import app.amber.core.native.AmberNativeBridge
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.security.SecureRandom
import java.time.Instant
import java.util.Base64
import java.util.UUID

@Serializable
data class GatewayIdentity(
    val id: String,
    val name: String,
)

@Serializable
data class PairingTicket(
    val secretHash: String,
    val expiresAt: Double,
)

@Serializable
data class PairedDevice(
    val id: String,
    val name: String,
    val platform: String,
    val tokenHash: String,
    val pushToken: String? = null,
    val pushEnvironment: String? = null,
    val pairedAt: Double,
    val lastSeenAt: Double,
    val protocolVersion: Int = 1,
    val nodeRole: String = "hybrid",
    val trustedApprovalSurface: Boolean = true,
)

@Serializable
data class PendingApprovalDto(
    val toolCallId: String,
    val tool: String,
    val detail: String? = null,
    val highRisk: Boolean,
)

@Serializable
data class SessionDto(
    val key: String,
    val agent: String = "amber",
    val subject: String,
    val summary: String? = null,
    val origin: String = "headless",
    val host: String? = null,
    val state: String,
    val waitReason: String? = null,
    val abnormal: Boolean = false,
    val monitored: Boolean = true,
    val updatedAt: Double,
    val pendingApproval: PendingApprovalDto? = null,
    val conversationId: String? = null,
) {
    val isOpen: Boolean
        get() = state == "running" || state == "waiting" || state == "stalled"
}

@Serializable
data class HealthSnapshotDto(
    val sampledAt: Double,
    val diskFreeBytes: Long,
    val batteryPercent: Int? = null,
    val onBattery: Boolean = false,
    val memoryPressure: String = "normal",
    val thermal: String = "nominal",
)

@Serializable
data class StatusResponseDto(
    val gateway: GatewayIdentity,
    val device: DeviceSummaryDto,
    val serverTime: Double,
    val health: HealthSnapshotDto? = null,
    val synaraURL: String? = null,
    val sessions: List<SessionDto>,
)

@Serializable
data class DeviceSummaryDto(
    val id: String,
    val name: String,
    val pushRegistered: Boolean,
)

@Serializable
data class BoardApprovalDto(
    val sessionKey: String,
    val toolCallId: String,
    val tool: String,
    val detail: String? = null,
    val highRisk: Boolean,
)

@Serializable
data class BoardItemDto(
    val id: String,
    val kind: String,
    val column: String,
    val title: String,
    val detail: String,
    val updatedAt: Double,
    val scheduleId: String? = null,
    val conversationId: String? = null,
    val nextRunAt: Double? = null,
    val waitingForReply: Boolean = false,
    val failed: Boolean = false,
    val approval: BoardApprovalDto? = null,
)

@Serializable
data class BoardResponseDto(
    val board: List<BoardItemDto>,
)

@Serializable
data class ScheduleSummaryDto(
    val id: String,
    val name: String,
    val prompt: String = "",
    val rule: String,
    val enabled: Boolean = true,
    val running: Boolean = false,
    val paused: Boolean = false,
    val nextRunAt: Double? = null,
    val lastStatus: String? = null,
    val lastRunAt: Double? = null,
    val autoApprovesHighRisk: Boolean = false,
)

@Serializable
data class ScheduleListResponseDto(
    val schedules: List<ScheduleSummaryDto>,
)

@Serializable
data class PushMessagePayload(
    val deviceId: String,
    val platform: String,
    val pushToken: String,
    val title: String,
    val body: String,
    val sessionKey: String? = null,
    val toolCallId: String? = null,
    val category: String? = null,
    val highRisk: Boolean = false,
)

fun interface PushSender {
    suspend fun send(payload: PushMessagePayload): Result<Unit>
}

/**
 * Persistent state and C3 v1/v2 coordinator for `amberd`.
 *
 * Manages:
 * - `identity.json` (Gateway UUID and display name)
 * - `devices.json` (`tokenHash = sha256_hex(token)` only, never plaintext bearer token)
 * - `pairing.json` (single-use 5-minute pairing ticket)
 * - `audit.jsonl` (0600 append-only structured audit log)
 * - `sessions.json` and `schedules.json`
 */
class CloudGatewayState(
    val dataDir: File,
    gatewayNameOverride: String? = null,
    var pushSender: PushSender = PushSender { Result.success(Unit) },
) {
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true; encodeDefaults = true }
    private val compactJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val secureRandom = SecureRandom()

    val identityFile = File(dataDir, "identity.json")
    val devicesFile = File(dataDir, "devices.json")
    val pairingFile = File(dataDir, "pairing.json")
    val auditFile = File(dataDir, "audit.jsonl")
    val sessionsFile = File(dataDir, "sessions.json")
    val schedulesFile = File(dataDir, "schedules.json")
    val tlsIdentityFile = File(dataDir, "tls-identity.p12")

    val identity: GatewayIdentity

    private val sessions = LinkedHashMap<String, SessionDto>()
    private val schedules = LinkedHashMap<String, ScheduleSummaryDto>()
    private val decisionListeners = mutableListOf<suspend (sessionKey: String, toolCallId: String, allow: Boolean) -> Boolean>()

    init {
        dataDir.mkdirs()
        identity = loadOrCreateIdentity(gatewayNameOverride)
        loadSessionsFromDisk()
        loadSchedulesFromDisk()
    }

    @Synchronized
    fun registerDecisionListener(
        listener: suspend (sessionKey: String, toolCallId: String, allow: Boolean) -> Boolean,
    ) {
        decisionListeners.add(listener)
    }

    private fun loadOrCreateIdentity(nameOverride: String?): GatewayIdentity {
        if (identityFile.exists()) {
            runCatching {
                return json.decodeFromString<GatewayIdentity>(identityFile.readText())
            }
        }
        val created = GatewayIdentity(
            id = UUID.randomUUID().toString().lowercase(),
            name = nameOverride ?: System.getenv("AMBER_GATEWAY_NAME") ?: "Amber Cloud Self",
        )
        atomicWrite(identityFile, json.encodeToString(created))
        return created
    }

    @Synchronized
    fun issuePairingTicket(nowSeconds: Double = nowEpochSeconds(), ttlSeconds: Double = 300.0): String {
        val secretBytes = ByteArray(16).also { secureRandom.nextBytes(it) }
        val secret = Base64.getUrlEncoder().withoutPadding().encodeToString(secretBytes)
        val ticket = PairingTicket(
            secretHash = sha256Hex(secret),
            expiresAt = nowSeconds + ttlSeconds,
        )
        atomicWrite(pairingFile, json.encodeToString(ticket))
        recordAudit("pair-code")
        return secret
    }

    /**
     * Validates a one-time pairing secret and registers the device in `devices.json`.
     * Burns `pairing.json` immediately on first valid match.
     */
    @Synchronized
    fun pairDevice(
        secret: String,
        platform: String,
        deviceName: String?,
        protocolVersion: Int = 1,
        nodeRole: String = "hybrid",
        trustedApprovalSurface: Boolean? = null,
        nowSeconds: Double = nowEpochSeconds(),
    ): PairResult {
        val normalizedPlatform = platform.trim().lowercase()
        if (secret.isBlank() || normalizedPlatform !in VALID_PLATFORMS) {
            return PairResult.BadRequest("需要 secret 与 platform（ios / android / harmony / macos / linux）")
        }
        if (!pairingFile.exists()) {
            return PairResult.Forbidden("配对码无效或已过期，请重新运行 amber-cli pair")
        }
        val ticket = runCatching {
            json.decodeFromString<PairingTicket>(pairingFile.readText())
        }.getOrNull() ?: return PairResult.Forbidden("配对码无效或已过期，请重新运行 amber-cli pair")

        if (ticket.expiresAt <= nowSeconds || ticket.secretHash != sha256Hex(secret)) {
            return PairResult.Forbidden("配对码无效或已过期，请重新运行 amber-cli pair")
        }

        // Single-use invariant: burn ticket before issuing token
        pairingFile.delete()

        val displayName = (deviceName?.takeIf { it.isNotBlank() } ?: normalizedPlatform).take(64)
        val tokenBytes = ByteArray(32).also { secureRandom.nextBytes(it) }
        val token = Base64.getUrlEncoder().withoutPadding().encodeToString(tokenBytes)
        val device = PairedDevice(
            id = UUID.randomUUID().toString().lowercase(),
            name = displayName,
            platform = normalizedPlatform,
            tokenHash = sha256Hex(token),
            pairedAt = nowSeconds,
            lastSeenAt = nowSeconds,
            protocolVersion = protocolVersion,
            nodeRole = nodeRole,
            trustedApprovalSurface = trustedApprovalSurface ?: (normalizedPlatform in NATIVE_PLATFORMS),
        )
        return try {
            val current = loadDevicesStrict().toMutableList()
            current.add(device)
            saveDevicesStrict(current)
            recordAudit(
                "pair",
                mapOf(
                    "device" to device.id,
                    "name" to device.name,
                    "platform" to device.platform,
                ),
            )
            PairResult.Success(
                deviceId = device.id,
                token = token,
                gatewayId = identity.id,
                gatewayName = identity.name,
            )
        } catch (e: Exception) {
            PairResult.ServerError("无法保存设备: ${e.message}")
        }
    }

    sealed interface PairResult {
        data class Success(
            val deviceId: String,
            val token: String,
            val gatewayId: String,
            val gatewayName: String,
        ) : PairResult

        data class BadRequest(val error: String) : PairResult
        data class Forbidden(val error: String) : PairResult
        data class ServerError(val error: String) : PairResult
    }

    @Synchronized
    fun authenticateBearer(bearerToken: String?): AuthResult {
        if (bearerToken.isNullOrBlank()) return AuthResult.Unauthorized
        val devices = try {
            loadDevicesStrict()
        } catch (e: Exception) {
            // C3 §2.3: Return 500 on corrupted devices.json so clients never wipe local pairing
            return AuthResult.CorruptedStore("devices.json 无法解析: ${e.message}")
        }
        val hash = sha256Hex(bearerToken)
        val matched = devices.firstOrNull { it.tokenHash == hash } ?: return AuthResult.Unauthorized
        val now = nowEpochSeconds()
        if (now - matched.lastSeenAt > 60.0) {
            runCatching {
                val updated = devices.map { if (it.id == matched.id) it.copy(lastSeenAt = now) else it }
                saveDevicesStrict(updated)
            }
        }
        return AuthResult.Authenticated(matched)
    }

    sealed interface AuthResult {
        data class Authenticated(val device: PairedDevice) : AuthResult
        data object Unauthorized : AuthResult
        data class CorruptedStore(val error: String) : AuthResult
    }

    @Synchronized
    fun unpairDevice(deviceId: String): Boolean {
        val current = loadDevicesStrict()
        val target = current.firstOrNull { it.id == deviceId } ?: return false
        saveDevicesStrict(current.filterNot { it.id == deviceId })
        recordAudit("unpair", mapOf("device" to target.id, "name" to target.name))
        return true
    }

    @Synchronized
    fun registerPushToken(device: PairedDevice, token: String?, environment: String?): Pair<Int, String?> {
        if (
            token.isNullOrEmpty() ||
            token.length > 4096 ||
            !token.all { it.code < 128 && (it.isLetterOrDigit() || it in ":_-.+/=") }
        ) {
            return 400 to "token 非法"
        }
        if (device.platform == "ios" && environment !in setOf("sandbox", "production")) {
            return 400 to "iOS 需要 environment（sandbox / production）"
        }
        return try {
            val list = loadDevicesStrict().map { existing ->
                when {
                    existing.id == device.id -> existing.copy(
                        pushToken = token,
                        pushEnvironment = environment,
                    )
                    existing.pushToken == token -> existing.copy(
                        pushToken = null,
                        pushEnvironment = null,
                    )
                    else -> existing
                }
            }
            saveDevicesStrict(list)
            200 to null
        } catch (e: Exception) {
            500 to "无法保存推送 token: ${e.message}"
        }
    }

    suspend fun sendTestPush(deviceId: String): Pair<Int, String?> {
        val device = synchronized(this) {
            loadDevicesStrict().firstOrNull { it.id == deviceId }
        } ?: return 401 to "unauthorized"
        val pushToken = device.pushToken ?: return 409 to "设备尚未上报推送 token"
        val payload = PushMessagePayload(
            deviceId = device.id,
            platform = device.platform,
            pushToken = pushToken,
            title = "Amber 云端网关",
            body = "测试推送连接正常",
        )
        return pushSender.send(payload).fold(
            onSuccess = { 200 to null },
            onFailure = { 502 to (it.message ?: "推送发送失败") },
        )
    }

    /**
     * Builds a lock-screen privacy-preserving push payload (C3 §4.2 & Defect #1).
     * High-risk approvals NEVER include `category` or `toolCallId` on the lock screen!
     */
    fun buildApprovalPushPayload(
        device: PairedDevice,
        session: SessionDto,
        approval: PendingApprovalDto,
    ): PushMessagePayload? {
        val pushToken = device.pushToken ?: return null
        return if (approval.highRisk) {
            PushMessagePayload(
                deviceId = device.id,
                platform = device.platform,
                pushToken = pushToken,
                title = "Amber 任务 · ${session.subject}",
                body = "等你确认（高风险，请在 App 内核对）",
                sessionKey = session.key,
                toolCallId = null,
                category = null,
                highRisk = true,
            )
        } else {
            PushMessagePayload(
                deviceId = device.id,
                platform = device.platform,
                pushToken = pushToken,
                title = "Amber 任务 · ${session.subject}",
                body = "等你确认",
                sessionKey = session.key,
                toolCallId = approval.toolCallId,
                category = "amber.gateway.approval",
                highRisk = false,
            )
        }
    }

    @Synchronized
    fun upsertSession(session: SessionDto) {
        val safeApproval = session.pendingApproval?.let {
            it.copy(detail = it.detail?.let(CredentialRedactor::redact))
        }
        sessions[session.key] = session.copy(
            subject = CredentialRedactor.redact(session.subject),
            summary = session.summary?.let(CredentialRedactor::redact),
            pendingApproval = safeApproval,
        )
        persistSessions()
    }

    @Synchronized
    fun getSession(sessionKey: String): SessionDto? = sessions[sessionKey]

    @Synchronized
    fun listSessions(): List<SessionDto> = sessions.values.toList()

    @Synchronized
    fun setMonitored(sessionKey: String, monitored: Boolean): Boolean {
        val existing = sessions[sessionKey] ?: return false
        sessions[sessionKey] = existing.copy(monitored = monitored)
        persistSessions()
        recordAudit("monitor", mapOf("task" to sessionKey, "monitored" to monitored.toString()))
        return true
    }

    @Synchronized
    fun buildStatusResponse(device: PairedDevice, nowSeconds: Double = nowEpochSeconds()): StatusResponseDto {
        val freshDevice = runCatching {
            loadDevicesStrict().firstOrNull { it.id == device.id }
        }.getOrNull() ?: device
        val orderedSessions = sessions.values
            .sortedWith(
                compareByDescending<SessionDto> { if (it.isOpen) 1 else 0 }
                    .thenByDescending { it.updatedAt }
            )
            .take(50)
        return StatusResponseDto(
            gateway = identity,
            device = DeviceSummaryDto(
                id = freshDevice.id,
                name = freshDevice.name,
                pushRegistered = freshDevice.pushToken != null,
            ),
            serverTime = nowSeconds,
            health = HealthSnapshotDto(
                sampledAt = nowSeconds,
                diskFreeBytes = dataDir.usableSpace,
            ),
            sessions = orderedSessions,
        )
    }

    @Synchronized
    fun buildBoardResponse(nowSeconds: Double = nowEpochSeconds()): BoardResponseDto {
        val items = mutableListOf<BoardItemDto>()
        val sevenDaysAgo = nowSeconds - 7 * 86400.0
        val twentyFourHoursAgo = nowSeconds - 24 * 3600.0

        for (session in sessions.values) {
            // Skip orphan open sessions older than 24h without active approval
            if (session.isOpen && session.updatedAt < twentyFourHoursAgo && session.pendingApproval == null) {
                continue
            }
            val column = when {
                session.state == "waiting" -> "needsYou"
                session.state == "running" || session.state == "stalled" -> "running"
                session.state == "completed" || session.state == "stopped" -> {
                    if (session.updatedAt < sevenDaysAgo) continue
                    "done"
                }
                else -> continue
            }
            val approval = session.pendingApproval?.let {
                BoardApprovalDto(
                    sessionKey = session.key,
                    toolCallId = it.toolCallId,
                    tool = it.tool,
                    detail = it.detail?.let(CredentialRedactor::redact),
                    highRisk = it.highRisk,
                )
            }
            val detail = when {
                approval != null -> "等你确认 · ${approval.tool}"
                session.state == "running" -> "正在运行"
                session.abnormal -> "执行异常"
                else -> session.summary ?: session.subject
            }
            items.add(
                BoardItemDto(
                    id = "run:${session.key.removePrefix("amber:")}",
                    kind = if (session.agent == "amber") "run" else "agentSession",
                    column = column,
                    title = session.subject,
                    detail = detail,
                    updatedAt = session.updatedAt,
                    conversationId = session.conversationId,
                    waitingForReply = session.state == "waiting" && session.waitReason != "permission",
                    failed = session.abnormal,
                    approval = approval,
                )
            )
        }

        for (schedule in schedules.values) {
            if (schedule.enabled && !schedule.running) {
                items.add(
                    BoardItemDto(
                        id = "schedule:${schedule.id}",
                        kind = "schedule",
                        column = "scheduled",
                        title = schedule.name,
                        detail = if (schedule.paused) "${schedule.rule} · 已暂停" else schedule.rule,
                        updatedAt = schedule.lastRunAt ?: nowSeconds,
                        scheduleId = schedule.id,
                        nextRunAt = if (schedule.paused) null else schedule.nextRunAt,
                    )
                )
            }
        }

        val columnOrder = mapOf("needsYou" to 0, "running" to 1, "scheduled" to 2, "done" to 3)
        val sorted = items.sortedWith { a, b ->
            val colCmp = (columnOrder[a.column] ?: 99).compareTo(columnOrder[b.column] ?: 99)
            if (colCmp != 0) colCmp
            else if (a.column == "scheduled") {
                (a.nextRunAt ?: Double.MAX_VALUE).compareTo(b.nextRunAt ?: Double.MAX_VALUE)
            } else {
                b.updatedAt.compareTo(a.updatedAt)
            }
        }
        return BoardResponseDto(board = sorted)
    }

    /**
     * Processes a tool approval decision according to C3 v1 & C3 v2 rules:
     * - When `approval.highRisk == true` and `allow == true`:
     *   ONLY requests from a paired, trusted native App in the unlocked foreground
     *   (`trustedForeground == true`) are allowed (`200`).
     *   All untrusted or non-foreground sources (mobile remote without foreground proof,
     *   lock screen, notifications, IM channels, cloud self) receive `HTTP 403` and
     *   `outcome = "rejected_high_risk"`.
     */
    suspend fun processDecision(
        sessionKey: String?,
        toolCallId: String?,
        allow: Boolean?,
        actorDevice: String,
        trustedForegroundSource: Boolean,
    ): DecisionHttpResult {
        if (sessionKey.isNullOrBlank() || !sessionKey.startsWith("amber:") || toolCallId.isNullOrBlank() || allow == null) {
            return DecisionHttpResult(400, "需要 sessionKey、toolCallId 与 allow")
        }
        val runId = sessionKey.removePrefix("amber:")
        val session = synchronized(this) { sessions[sessionKey] }
        val pending = session?.pendingApproval

        recordAudit(
            "amber-decision",
            buildMap {
                put("device", actorDevice)
                put("task", sessionKey)
                put("run", runId)
                put("toolCallId", toolCallId)
                put("allow", allow.toString())
                put("decision", if (allow) "allow" else "deny")
                if (pending != null) put("tool", pending.tool)
            },
        )

        if (session == null || session.state != "waiting" || pending == null || pending.toolCallId != toolCallId) {
            recordAudit(
                "amber-decision-result",
                mapOf(
                    "task" to sessionKey,
                    "run" to runId,
                    "tool" to (pending?.tool ?: ""),
                    "toolCallId" to toolCallId,
                    "allow" to allow.toString(),
                    "decision" to if (allow) "allow" else "deny",
                    "outcome" to "stale",
                    "device" to actorDevice,
                ),
            )
            return DecisionHttpResult(409, "这次审批已经结束", outcome = "stale")
        }

        // C3 v2 + Defect #1: High-risk or IM `allow=true` from any non-trusted or non-foreground source -> 403!
        if (allow && (pending.highRisk || !trustedForegroundSource)) {
            if (!trustedForegroundSource) {
                recordAudit(
                    "amber-decision-result",
                    mapOf(
                        "task" to sessionKey,
                        "run" to runId,
                        "tool" to pending.tool,
                        "toolCallId" to toolCallId,
                        "allow" to "true",
                        "decision" to "allow",
                        "outcome" to "rejected_high_risk",
                        "device" to actorDevice,
                    ),
                )
                return DecisionHttpResult(
                    status = 403,
                    error = "操作只能在已配对、解锁且经过生物识别的原生 App 前台核对后批准（IM 仅可拒绝）",
                    outcome = "rejected_high_risk",
                )
            }
        }

        val listeners = synchronized(this) { decisionListeners.toList() }
        var handled = false
        for (listener in listeners) {
            if (listener(sessionKey, toolCallId, allow)) {
                handled = true
                break
            }
        }
        if (!handled) {
            synchronized(this) {
                val current = sessions[sessionKey]
                if (current == null || current.pendingApproval?.toolCallId != toolCallId) {
                    return DecisionHttpResult(409, "这次审批已经结束", outcome = "stale")
                }
                sessions[sessionKey] = current.copy(
                    state = if (allow) "running" else "completed",
                    waitReason = null,
                    pendingApproval = null,
                    updatedAt = nowEpochSeconds(),
                )
                persistSessions()
            }
        }

        val outcome = if (allow) "approved" else "denied"
        recordAudit(
            "amber-decision-result",
            mapOf(
                "task" to sessionKey,
                "run" to runId,
                "tool" to pending.tool,
                "toolCallId" to toolCallId,
                "allow" to allow.toString(),
                "decision" to if (allow) "allow" else "deny",
                "outcome" to outcome,
                "device" to actorDevice,
            ),
        )
        return DecisionHttpResult(status = 200, error = null, outcome = outcome)
    }

    data class DecisionHttpResult(
        val status: Int,
        val error: String? = null,
        val outcome: String = "",
    )

    @Synchronized
    fun listSchedules(): List<ScheduleSummaryDto> = schedules.values.toList()

    @Synchronized
    fun createSchedule(
        name: String?,
        prompt: String?,
        rule: String?,
        intervalMinutes: Int? = null,
        deviceId: String = "remote",
    ): Pair<Int, Any> {
        val cleanName = name?.trim().orEmpty()
        val cleanPrompt = prompt?.trim().orEmpty()
        val cleanRule = rule?.trim().orEmpty()
        if (cleanName.isEmpty() || cleanPrompt.isEmpty() || cleanRule !in VALID_SCHEDULE_RULES) {
            return 400 to "需要 name、prompt 与合法的 rule"
        }
        if (cleanRule == "interval" && (intervalMinutes == null || intervalMinutes < 15)) {
            return 400 to "interval 规则间隔不得小于 15 分钟"
        }
        // C3 §5.2: Remote schedule creation NEVER enables autoApproveOrdinary or autoApproveHighRisk
        val now = nowEpochSeconds()
        val schedule = ScheduleSummaryDto(
            id = UUID.randomUUID().toString().lowercase(),
            name = cleanName,
            prompt = CredentialRedactor.redact(cleanPrompt),
            rule = cleanRule,
            enabled = true,
            running = false,
            paused = false,
            nextRunAt = now + ((intervalMinutes ?: 60) * 60.0),
            autoApprovesHighRisk = false,
        )
        schedules[schedule.id] = schedule
        persistSchedules()
        recordAudit("amber-schedule-create", mapOf("device" to deviceId, "name" to schedule.name))
        return 200 to schedule
    }

    @Synchronized
    fun setScheduleEnabled(id: String, enabled: Boolean, deviceId: String = "remote"): Pair<Int, Any> {
        val existing = schedules[id] ?: return 404 to "找不到这个定时任务"
        val updated = existing.copy(enabled = enabled)
        schedules[id] = updated
        persistSchedules()
        recordAudit(
            "amber-schedule-enabled",
            mapOf("device" to deviceId, "schedule" to id, "enabled" to enabled.toString()),
        )
        return 200 to updated
    }

    @Synchronized
    fun triggerScheduleNow(id: String, deviceId: String = "remote"): Pair<Int, Any> {
        val existing = schedules[id] ?: return 404 to "找不到这个定时任务"
        if (existing.running) return 409 to "定时任务已在运行中"
        val now = nowEpochSeconds()
        val updated = existing.copy(
            running = false,
            lastStatus = "completed",
            lastRunAt = now,
        )
        schedules[id] = updated
        persistSchedules()
        recordAudit("amber-schedule-run", mapOf("device" to deviceId, "schedule" to id))
        return 200 to updated
    }

    @Synchronized
    fun loadDevicesStrict(): List<PairedDevice> {
        if (!devicesFile.exists()) return emptyList()
        return json.decodeFromString<List<PairedDevice>>(devicesFile.readText())
    }

    @Synchronized
    fun saveDevicesStrict(devices: List<PairedDevice>) {
        atomicWrite(devicesFile, json.encodeToString(devices))
        EnvelopeCredentialVault.setOwnerOnlyPermissions(devicesFile)
    }

    @Synchronized
    fun recordAudit(action: String, detail: Map<String, String> = emptyMap()) {
        val obj = buildJsonObject {
            put("action", action)
            put("at", Instant.now().toString())
            for ((k, v) in detail.toSortedMap()) {
                put(k, CredentialRedactor.redact(v))
            }
        }
        val line = compactJson.encodeToString(JsonObject.serializer(), obj) + "\n"
        auditFile.parentFile?.mkdirs()
        if (!auditFile.exists()) {
            auditFile.writeText("")
            EnvelopeCredentialVault.setOwnerOnlyPermissions(auditFile)
        }
        Files.writeString(auditFile.toPath(), line, StandardOpenOption.CREATE, StandardOpenOption.APPEND)
    }

    @Synchronized
    fun readAuditEntries(): List<JsonObject> {
        if (!auditFile.exists()) return emptyList()
        return auditFile.readLines()
            .filter { it.isNotBlank() }
            .mapNotNull { runCatching { compactJson.decodeFromString(JsonObject.serializer(), it) }.getOrNull() }
    }

    private fun loadSessionsFromDisk() {
        if (!sessionsFile.exists()) return
        runCatching {
            val loaded = json.decodeFromString<List<SessionDto>>(sessionsFile.readText())
            val now = nowEpochSeconds()
            // Defect #2 / Cold-start recovery: any session left in waiting/running from a previous
            // process crash cannot auto-replay unconfirmed tool calls; mark stopped/abnormal.
            for (session in loaded) {
                if (session.state == "waiting" || session.state == "running") {
                    sessions[session.key] = session.copy(
                        state = "stopped",
                        waitReason = null,
                        abnormal = true,
                        pendingApproval = null,
                        updatedAt = now,
                    )
                } else {
                    sessions[session.key] = session
                }
            }
            persistSessions()
        }
    }

    private fun persistSessions() {
        atomicWrite(sessionsFile, json.encodeToString(sessions.values.toList()))
    }

    private fun loadSchedulesFromDisk() {
        if (!schedulesFile.exists()) return
        runCatching {
            val loaded = json.decodeFromString<List<ScheduleSummaryDto>>(schedulesFile.readText())
            for (s in loaded) {
                schedules[s.id] = s.copy(running = false)
            }
        }
    }

    private fun persistSchedules() {
        atomicWrite(schedulesFile, json.encodeToString(schedules.values.toList()))
    }

    private fun atomicWrite(target: File, content: String) {
        target.parentFile?.mkdirs()
        val tmp = File(target.parentFile, "${target.name}.tmp")
        tmp.writeText(content)
        Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    companion object {
        val VALID_PLATFORMS = setOf("ios", "android", "harmony", "macos", "linux")
        val NATIVE_PLATFORMS = setOf("ios", "android", "harmony", "macos")
        val VALID_SCHEDULE_RULES = setOf("once", "daily", "weekdays", "weekly", "interval")

        fun nowEpochSeconds(): Double = System.currentTimeMillis() / 1000.0

        fun sha256Hex(input: String): String {
            val digest = AmberNativeBridge.sha256(input.encodeToByteArray())
                ?: error("SHA-256 unavailable")
            return digest.joinToString("") { "%02x".format(it) }
        }
    }
}
