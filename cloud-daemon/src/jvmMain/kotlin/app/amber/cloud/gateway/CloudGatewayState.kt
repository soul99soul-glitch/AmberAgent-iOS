package app.amber.cloud.gateway

import app.amber.cloud.config.ConfigurationApiException
import app.amber.cloud.config.PairingBootstrapSnapshot
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
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.security.SecureRandom
import java.time.Instant
import java.util.Base64
import java.util.UUID
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.withContext

internal class DecisionActorContext(val actorDevice: String) : AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<DecisionActorContext>
}

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
    val riskLevel: String? = null,
    val targetDevice: String? = null,
    val targetSummary: String? = null,
    val diffPreview: String? = null,
    val requiresLocalApproval: Boolean? = null,
) {
    // Stage 2-B reads these display keys in the status and board cards.
    val summary = targetSummary
    val targetDeviceName = targetDevice
}

private val PendingApprovalDto.needsLocalDecision: Boolean
    get() = requiresLocalApproval == true ||
        (targetDevice != null && targetDevice != "cloud-daemon" && (riskLevel == "L3" || (riskLevel == null && highRisk)))

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
    val soulRevision: Long = 0L,
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
    val riskLevel: String? = null,
    val targetDevice: String? = null,
    val targetSummary: String? = null,
    val diffPreview: String? = null,
    val requiresLocalApproval: Boolean? = null,
) {
    // Stage 2-B reads these display keys in the status and board cards.
    val summary = targetSummary
    val targetDeviceName = targetDevice
}

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
    val ownerDeviceId: String? = null,
    val intervalMinutes: Int? = null,
    val lastRunDeviceId: String? = null,
    val lastWorkItemId: String? = null,
    val lastSlotEpochSec: Long? = null,
    val lastError: String? = null,
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
    val deepLink: String? = null,
    val workItemId: String? = null,
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
    var soulRevisionProvider: () -> Long = { 0L },
    internal val clockEpochSeconds: () -> Double = { nowEpochSeconds() },
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
    val deviceContextStore = DeviceContextSnapshotStore(File(dataDir, "device-context"))

    val identity: GatewayIdentity

    private val sessions = LinkedHashMap<String, SessionDto>()
    private val schedules = LinkedHashMap<String, ScheduleSummaryDto>()
    private val decisionListeners = mutableListOf<suspend (sessionKey: String, toolCallId: String, allow: Boolean) -> Boolean>()

    init {
        dataDir.mkdirs()
        identity = loadOrCreateIdentity(gatewayNameOverride)
        loadSessionsFromDisk()
        loadSchedulesFromDisk()
        deviceContextStore.purgeExpired()
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

    // The CLI and the HTTP gateway can issue a ticket in different processes.
    private inline fun <T> withTicketLock(action: () -> T): T {
        val path = File(dataDir, "pairing.lock").toPath()
        return FileChannel.open(path, StandardOpenOption.CREATE, StandardOpenOption.WRITE).use { channel ->
            channel.lock().use { action() }
        }
    }

    @Synchronized
    fun issuePairingTicket(nowSeconds: Double = clockEpochSeconds(), ttlSeconds: Double = 300.0): String = withTicketLock {
        val secretBytes = ByteArray(16).also { secureRandom.nextBytes(it) }
        val secret = Base64.getUrlEncoder().withoutPadding().encodeToString(secretBytes)
        val ticket = PairingTicket(
            secretHash = sha256Hex(secret),
            expiresAt = nowSeconds + ttlSeconds,
        )
        atomicWrite(pairingFile, json.encodeToString(ticket))
        recordAudit("pair-code")
        secret
    }

    /**
     * Validates a one-time pairing secret and registers the device in `devices.json`.
     * Consumes the ticket once registration parameters and any bootstrap response are ready.
     */
    @Synchronized
    fun pairDevice(
        secret: String,
        platform: String,
        deviceName: String?,
        protocolVersion: Int = 1,
        nodeRole: String = "hybrid",
        trustedApprovalSurface: Boolean? = null,
        nowSeconds: Double = clockEpochSeconds(),
        prepareBootstrap: ((PairedDevice) -> PairingBootstrapSnapshot?)? = null,
    ): PairResult = withTicketLock {
        val normalizedPlatform = platform.trim().lowercase()
        if (secret.isBlank() || normalizedPlatform !in VALID_PLATFORMS) {
            return@withTicketLock PairResult.BadRequest("需要 secret 与 platform（ios / android / harmony / macos / linux）")
        }
        if (protocolVersion !in 1..2 || nodeRole !in setOf("viewer", "executor", "hybrid")) {
            return@withTicketLock PairResult.BadRequest("invalid_pair_request")
        }
        if (!pairingFile.exists()) {
            return@withTicketLock PairResult.Forbidden("配对码无效或已过期，请重新运行 amber-cli pair")
        }
        val ticket = runCatching {
            json.decodeFromString<PairingTicket>(pairingFile.readText())
        }.getOrNull() ?: return@withTicketLock PairResult.Forbidden("配对码无效或已过期，请重新运行 amber-cli pair")

        if (ticket.expiresAt <= nowSeconds || ticket.secretHash != sha256Hex(secret)) {
            return@withTicketLock PairResult.Forbidden("配对码无效或已过期，请重新运行 amber-cli pair")
        }

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
        try {
            val current = loadDevicesStrict().toMutableList()
            val bootstrap = prepareBootstrap?.invoke(device)
            // Validation and encryption are complete. Consume before publishing a device token.
            Files.delete(pairingFile.toPath())
            current.add(device)
            saveDevicesStrict(current)
            recordAudit(
                "pair",
                mapOf(
                    "device" to device.id,
                    "platform" to device.platform,
                ),
            )
            PairResult.Success(
                deviceId = device.id,
                token = token,
                gatewayId = identity.id,
                gatewayName = identity.name,
                bootstrap = bootstrap,
            )
        } catch (e: ConfigurationApiException) {
            if (e.status == 400) PairResult.BadRequest(e.code) else PairResult.ServerError(e.code)
        } catch (_: Exception) {
            PairResult.ServerError("pairing_unavailable")
        }
    }

    sealed interface PairResult {
        data class Success(
            val deviceId: String,
            val token: String,
            val gatewayId: String,
            val gatewayName: String,
            val bootstrap: PairingBootstrapSnapshot? = null,
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
        deviceContextStore.delete(deviceId)
        var scheduleChanged = false
        for ((schedId, schedule) in schedules.toMap()) {
            if (schedule.ownerDeviceId == deviceId) {
                schedules[schedId] = schedule.copy(
                    running = false,
                    paused = true,
                    lastError = "owner_unpaired",
                )
                scheduleChanged = true
            }
        }
        if (scheduleChanged) persistSchedules()
        recordAudit("unpair", mapOf("device" to target.id, "name" to target.name))
        return true
    }

    @Synchronized
    fun findDeviceById(deviceId: String): PairedDevice? =
        runCatching { loadDevicesStrict().firstOrNull { it.id == deviceId } }.getOrNull()

    /**
     * Privacy-preserving push payload for scheduled Cloud tasks (X2).
     * Never exposes schedule prompt, execution output, error details, or tool names.
     */
    fun buildSchedulePushPayload(
        device: PairedDevice,
        schedule: ScheduleSummaryDto,
        workItemId: String,
        outcome: String,
    ): PushMessagePayload? {
        val pushToken = device.pushToken ?: return null
        val body = when (outcome.trim().lowercase()) {
            "completed" -> "定时任务已完成，点击查看详情"
            "blocked", "paused", "needsyou" -> "定时任务需要你的确认，请在 App 内查看"
            else -> "定时任务执行失败，点击查看详情"
        }
        return PushMessagePayload(
            deviceId = device.id,
            platform = device.platform,
            pushToken = pushToken,
            title = "定时任务更新",
            body = body,
            sessionKey = null,
            toolCallId = null,
            category = "amber.cloud.task",
            highRisk = false,
            deepLink = "amber://cloud-task/$workItemId",
            workItemId = workItemId,
        )
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
            it.copy(
                detail = it.detail?.let(CredentialRedactor::redact),
                targetDevice = it.targetDevice?.let(CredentialRedactor::redact),
                targetSummary = it.targetSummary?.let(CredentialRedactor::redact),
                diffPreview = it.diffPreview?.let(CredentialRedactor::redact),
            )
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
            soulRevision = soulRevisionProvider(),
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
                    riskLevel = it.riskLevel ?: if (it.highRisk) "L3" else "L2",
                    targetDevice = it.targetDevice,
                    targetSummary = it.targetSummary?.let(CredentialRedactor::redact),
                    diffPreview = it.diffPreview?.let(CredentialRedactor::redact),
                    requiresLocalApproval = it.needsLocalDecision,
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
     * Mac-local approval stays on the target. A paired, biometrically verified foreground
     * client may approve ordinary or cloud operations. Remote denial is always available.
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

        val requiresLocal = pending.needsLocalDecision
        if (allow && (requiresLocal || !trustedForegroundSource)) {
            val resolvedRiskLevel = pending.riskLevel ?: if (pending.highRisk) "L3" else "L2"
            recordAudit(
                "amber-decision-result",
                mapOf(
                    "task" to sessionKey,
                    "run" to runId,
                    "tool" to pending.tool,
                    "toolCallId" to toolCallId,
                    "allow" to "true",
                    "decision" to "allow",
                    "riskLevel" to resolvedRiskLevel,
                    "requiresLocalApproval" to requiresLocal.toString(),
                    "outcome" to "rejected_high_risk",
                    "device" to actorDevice,
                ),
            )
            return DecisionHttpResult(
                status = 403,
                error = if (requiresLocal) "操作（$resolvedRiskLevel）只能在目标设备本机核对后批准"
                    else "操作（$resolvedRiskLevel）需要已配对、解锁且经过生物识别的原生 App 前台核对批准",
                outcome = "rejected_high_risk",
                riskLevel = resolvedRiskLevel,
                targetDevice = pending.targetDevice,
                targetSummary = pending.targetSummary,
                diffPreview = pending.diffPreview,
                requiresLocalApproval = requiresLocal,
            )
        }

        val listeners = synchronized(this) { decisionListeners.toList() }
        val handled = withContext(DecisionActorContext(actorDevice)) {
            var matched = false
            for (listener in listeners) {
                if (listener(sessionKey, toolCallId, allow)) {
                    matched = true
                    break
                }
            }
            matched
        }
        if (!handled) {
            recordAudit(
                "amber-decision-result",
                mapOf(
                    "task" to sessionKey,
                    "run" to runId,
                    "tool" to pending.tool,
                    "toolCallId" to toolCallId,
                    "allow" to allow.toString(),
                    "decision" to if (allow) "allow" else "deny",
                    "outcome" to "stale",
                    "device" to actorDevice,
                ),
            )
            return DecisionHttpResult(409, "这次审批已经结束", outcome = "stale")
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
        val riskLevel: String? = null,
        val targetDevice: String? = null,
        val targetSummary: String? = null,
        val diffPreview: String? = null,
        val requiresLocalApproval: Boolean? = null,
    )

    @Synchronized
    fun listSchedules(): List<ScheduleSummaryDto> = schedules.values.toList()

    @Synchronized
    fun getSchedule(id: String): ScheduleSummaryDto? = schedules[id]

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
        if (intervalMinutes != null && intervalMinutes !in 15..10080) {
            return 400 to "规则间隔须为 15..10080 分钟"
        }
        val resolvedInterval = when (cleanRule) {
            "interval" -> intervalMinutes ?: 60
            "hourly" -> intervalMinutes?.coerceAtLeast(15) ?: 60
            "daily", "weekdays" -> intervalMinutes?.coerceAtLeast(15) ?: 1440
            "weekly" -> intervalMinutes?.coerceAtLeast(15) ?: 10080
            else -> intervalMinutes?.coerceAtLeast(15) ?: 60
        }
        val boundOwnerDeviceId = deviceId.trim().takeIf { it.isNotEmpty() && it != "remote" }
        // C3 §5.2: Remote schedule creation NEVER enables autoApproveOrdinary or autoApproveHighRisk
        val now = clockEpochSeconds()
        val schedule = ScheduleSummaryDto(
            id = UUID.randomUUID().toString().lowercase(),
            name = cleanName,
            prompt = CredentialRedactor.redact(cleanPrompt),
            rule = cleanRule,
            enabled = true,
            running = false,
            paused = false,
            nextRunAt = now + (resolvedInterval * 60.0),
            autoApprovesHighRisk = false,
            ownerDeviceId = boundOwnerDeviceId,
            intervalMinutes = resolvedInterval,
        )
        schedules[schedule.id] = schedule
        persistSchedules()
        recordAudit("amber-schedule-create", mapOf("device" to deviceId, "name" to schedule.name))
        return 200 to schedule
    }

    @Synchronized
    fun setScheduleEnabled(id: String, enabled: Boolean, deviceId: String = "remote"): Pair<Int, Any> {
        val existing = schedules[id] ?: return 404 to "找不到这个定时任务"
        val now = clockEpochSeconds()
        val nextRunAt = if (enabled) {
            existing.nextRunAt?.takeIf { it > now } ?: (now + (existing.intervalMinutes ?: 60).coerceIn(15, 10080) * 60.0)
        } else {
            existing.nextRunAt
        }
        val updated = existing.copy(
            enabled = enabled,
            paused = if (enabled) false else existing.paused,
            nextRunAt = nextRunAt,
        )
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
        if (schedules[id] == null) return 404 to "找不到这个定时任务"
        return 409 to "定时任务须通过已认证的任务执行入口运行"
    }

    data class ClaimedScheduleRun(
        val schedule: ScheduleSummaryDto,
        val ownerDevice: PairedDevice,
        val slotEpochSec: Long,
    )

    sealed interface ManualClaimResult {
        data class Claimed(val claim: ClaimedScheduleRun) : ManualClaimResult
        data class Error(val status: Int, val message: String) : ManualClaimResult
    }

    @Synchronized
    fun claimScheduleForManualRun(
        id: String,
        requesterDevice: PairedDevice,
        nowSeconds: Double = clockEpochSeconds(),
    ): ManualClaimResult {
        val existing = schedules[id] ?: return ManualClaimResult.Error(404, "找不到这个定时任务")
        if (existing.running) return ManualClaimResult.Error(409, "定时任务已在运行中")
        val ownerDevice = loadDevicesStrict().firstOrNull { it.id == requesterDevice.id }
            ?: return ManualClaimResult.Error(403, "调用设备已解绑")
        val baseEpochSec = kotlin.math.floor(nowSeconds).toLong()
        val slotEpochSec = maxOf(baseEpochSec, (existing.lastSlotEpochSec ?: 0L) + 1L)
        val claimed = existing.copy(
            running = true,
            paused = false,
            lastStatus = "submitting",
            lastWorkItemId = null,
            lastRunDeviceId = ownerDevice.id,
            lastSlotEpochSec = slotEpochSec,
            lastError = null,
            ownerDeviceId = existing.ownerDeviceId ?: ownerDevice.id,
        )
        schedules[id] = claimed
        persistSchedules()
        recordAudit("amber-schedule-run", mapOf("device" to requesterDevice.id, "schedule" to id, "slot" to slotEpochSec.toString()))
        return ManualClaimResult.Claimed(ClaimedScheduleRun(claimed, ownerDevice, slotEpochSec))
    }

    @Synchronized
    fun claimDueSchedules(nowSeconds: Double = clockEpochSeconds()): List<ClaimedScheduleRun> {
        val claimed = mutableListOf<ClaimedScheduleRun>()
        var changed = false
        val pairedDevices = loadDevicesStrict()
        for ((id, existing) in schedules.toMap()) {
            if (!existing.enabled || existing.paused) continue
            // Legacy records lack a complete execution contract and require manual binding.
            val ownerId = existing.ownerDeviceId ?: continue
            val interval = existing.intervalMinutes ?: continue
            val nextRun = existing.nextRunAt ?: continue
            if (nowSeconds < nextRun) continue
            val ownerDevice = pairedDevices.firstOrNull { it.id == ownerId }
            if (ownerDevice == null) {
                schedules[id] = existing.copy(lastError = "owner_unpaired")
                changed = true
                continue
            }
            val stepSec = interval.coerceIn(15, 10080) * 60.0
            val future = nextRun + (kotlin.math.floor((nowSeconds - nextRun) / stepSec) + 1) * stepSec
            if (existing.running) {
                schedules[id] = existing.copy(nextRunAt = future)
                recordAudit("amber-schedule-skipped_overlap", mapOf("schedule" to id))
            } else {
                val slot = kotlin.math.floor(nextRun).toLong()
                val updated = existing.copy(
                    enabled = if (existing.rule == "once") false else existing.enabled,
                    running = true,
                    nextRunAt = if (existing.rule == "once") null else future,
                    lastStatus = "submitting",
                    lastWorkItemId = null,
                    lastRunDeviceId = ownerId,
                    lastSlotEpochSec = slot,
                    lastError = null,
                )
                schedules[id] = updated
                claimed += ClaimedScheduleRun(updated, ownerDevice, slot)
                recordAudit("amber-schedule-due-claim", mapOf("schedule" to id, "slot" to slot.toString()))
            }
            changed = true
        }
        if (changed) persistSchedules()
        return claimed
    }

    @Synchronized
    fun attachScheduleWorkItem(
        id: String,
        workItemId: String,
        expectedSlotEpochSec: Long? = null,
        nowSeconds: Double = clockEpochSeconds(),
    ): ScheduleSummaryDto? {
        val existing = schedules[id] ?: return null
        if (expectedSlotEpochSec != null && (!existing.running || existing.lastSlotEpochSec != expectedSlotEpochSec)) return null
        val updated = existing.copy(
            lastStatus = "running",
            lastWorkItemId = workItemId,
            lastRunAt = nowSeconds,
        )
        schedules[id] = updated
        persistSchedules()
        return updated
    }

    @Synchronized
    fun failScheduleDispatch(
        id: String,
        error: String,
        expectedSlotEpochSec: Long? = null,
        nowSeconds: Double = clockEpochSeconds(),
    ): ScheduleSummaryDto? {
        val existing = schedules[id] ?: return null
        if (expectedSlotEpochSec != null && existing.lastSlotEpochSec != expectedSlotEpochSec) return null
        // Submission may have committed before an interruption. Preserve its idempotency key.
        val updated = existing.copy(
            running = true,
            lastStatus = "submitting",
            lastRunAt = nowSeconds,
            lastError = CredentialRedactor.redact(error).take(200),
        )
        schedules[id] = updated
        persistSchedules()
        return updated
    }

    @Synchronized
    fun settleScheduleForWorkItem(
        workItemId: String,
        outcome: String,
        errorDetail: String?,
        nowSeconds: Double = clockEpochSeconds(),
    ): Pair<ScheduleSummaryDto, PairedDevice?>? {
        val entry = schedules.entries.firstOrNull { it.value.running && it.value.lastWorkItemId == workItemId } ?: return null
        val normalized = outcome.trim().lowercase()
        val isCompleted = normalized == "completed"
        val isBlocked = normalized == "blocked"
        val updated = entry.value.copy(
            running = false,
            paused = isBlocked || entry.value.paused,
            lastStatus = when {
                isCompleted -> "completed"
                isBlocked -> "blocked"
                else -> "failed"
            },
            lastRunAt = nowSeconds,
            lastError = if (isCompleted) null else errorDetail?.let(CredentialRedactor::redact)?.take(200),
        )
        schedules[entry.key] = updated
        persistSchedules()
        val owner = updated.ownerDeviceId?.let { ownerId ->
            runCatching { loadDevicesStrict().firstOrNull { it.id == ownerId } }.getOrNull()
        }
        return updated to owner
    }

    @Synchronized
    fun listRunningSchedules(): List<ScheduleSummaryDto> =
        schedules.values.filter { it.running }

    @Synchronized
    fun reconcileSchedulesOnRestart(
        workersWillRelaunch: Boolean,
        lookupWorkItem: (String) -> app.amber.cloud.orchestration.CloudWorkItemRecord?,
        nowSeconds: Double = clockEpochSeconds(),
    ): List<ScheduleSummaryDto> {
        // WAITING and IDLE are live states too. Only durable worker terminal evidence settles a run.
        for (s in schedules.values.toList().filter { it.running }) {
            val workId = s.lastWorkItemId ?: continue
            val item = lookupWorkItem(workId) ?: continue
            if (item.state.isTerminal) {
                settleScheduleForWorkItem(
                    workId,
                    item.settlementOutcome ?: if (item.state == app.amber.cloud.orchestration.WorkItemState.COMPLETED) "completed" else "failed",
                    item.failureReason,
                    nowSeconds,
                )
            }
        }
        return schedules.values.toList()
    }

    @Synchronized
    fun pendingScheduleSubmissions(): List<ClaimedScheduleRun> = schedules.values.toList().mapNotNull { schedule ->
        if (!schedule.running || schedule.lastWorkItemId != null) return@mapNotNull null
        val slot = schedule.lastSlotEpochSec ?: return@mapNotNull null
        val deviceId = schedule.lastRunDeviceId ?: schedule.ownerDeviceId ?: return@mapNotNull null
        val device = loadDevicesStrict().firstOrNull { it.id == deviceId } ?: run {
            schedules[schedule.id] = schedule.copy(running = false, lastError = "owner_unpaired")
            persistSchedules()
            return@mapNotNull null
        }
        ClaimedScheduleRun(schedule, device, slot)
    }

    @Synchronized
    fun setScheduleNextRunAtForTesting(id: String, nextRunAt: Double?): ScheduleSummaryDto? {
        val existing = schedules[id] ?: return null
        val updated = existing.copy(nextRunAt = nextRunAt)
        schedules[id] = updated
        persistSchedules()
        return updated
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
                schedules[s.id] = s
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
        val VALID_SCHEDULE_RULES = setOf("once", "hourly", "daily", "weekdays", "weekly", "interval")

        fun nowEpochSeconds(): Double = System.currentTimeMillis() / 1000.0

        fun sha256Hex(input: String): String {
            val digest = AmberNativeBridge.sha256(input.encodeToByteArray())
                ?: error("SHA-256 unavailable")
            return digest.joinToString("") { "%02x".format(it) }
        }
    }
}
