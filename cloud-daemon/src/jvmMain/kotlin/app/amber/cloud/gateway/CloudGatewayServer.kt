package app.amber.cloud.gateway

import app.amber.cloud.channels.FeishuChannel
import app.amber.cloud.config.CloudConfigurationManager
import app.amber.cloud.config.ConfigurationApiException
import app.amber.cloud.config.ConfigurationEncryption
import app.amber.cloud.config.IssuedPairingTicketDto
import app.amber.cloud.config.PairingBootstrapHint
import app.amber.cloud.config.PairingBootstrapSnapshot
import app.amber.cloud.rules.ProceduralRuleStore
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.install
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.request.header
import io.ktor.server.request.receiveText
import io.ktor.server.response.header
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.net.URLDecoder
import java.nio.charset.StandardCharsets

/**
 * Ktor Server module implementing all C3 v1 endpoints and C3 v2 high-risk approval rules.
 *
 * Endpoints:
 * - `POST /v1/pair`
 * - `POST /v1/unpair`
 * - `GET /v1/status`
 * - `POST /v1/push-token`
 * - `POST /v1/test-push`
 * - `POST /v1/amber/decision`
 * - `GET /v1/amber/board`
 * - `GET /v1/amber/schedules`
 * - `POST /v1/amber/schedules`
 * - `POST /v1/amber/schedules/{id}/enabled`
 * - `POST /v1/amber/schedules/{id}/run`
 * - `POST /v1/tasks/{key}/monitor`
 */
fun Application.configureCloudGateway(
    state: CloudGatewayState,
    feishuChannel: FeishuChannel? = null,
    agentApi: AgentCentricApi? = null,
    soulStore: app.amber.cloud.soul.CloudSoulStore? = agentApi?.kernel?.soulStore,
    ruleStore: ProceduralRuleStore? = agentApi?.kernel?.proceduralRuleStore,
    gatewayPort: Int = 47821,
    publicAddresses: List<String> = emptyList(),
) {
    val gatewayJson = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }

    install(ContentNegotiation) {
        json(gatewayJson)
    }
    if (agentApi != null) configureAgentCentricRoutes(state, agentApi)
    if (soulStore != null) configureSoulRoutes(state, soulStore, agentApi)
    if (ruleStore != null) configureProceduralRuleRoutes(state, ruleStore)

    suspend fun ApplicationCall.respondJson(status: Int, payload: String) {
        respondText(
            text = payload,
            contentType = ContentType.Application.Json,
            status = HttpStatusCode.fromValue(status),
        )
    }

    suspend fun ApplicationCall.respondError(status: Int, message: String) {
        val body = gatewayJson.encodeToString(
            JsonObject.serializer(),
            buildJsonObject { put("error", message) },
        )
        respondJson(status, body)
    }

    suspend fun ApplicationCall.parseJsonBody(): JsonObject {
        val raw = runCatching { receiveText() }.getOrDefault("")
        if (raw.isBlank()) return JsonObject(emptyMap())
        return runCatching {
            gatewayJson.parseToJsonElement(raw).jsonObject
        }.getOrDefault(JsonObject(emptyMap()))
    }

    suspend fun ApplicationCall.authenticate(): PairedDevice? {
        val authHeader = request.header(HttpHeaders.Authorization)
        val token = authHeader
            ?.takeIf { it.startsWith("Bearer ", ignoreCase = true) }
            ?.substringAfter(" ")
            ?.trim()
        return when (val res = state.authenticateBearer(token)) {
            is CloudGatewayState.AuthResult.Authenticated -> res.device
            is CloudGatewayState.AuthResult.Unauthorized -> {
                respondError(401, "unauthorized")
                null
            }
            is CloudGatewayState.AuthResult.CorruptedStore -> {
                respondError(500, res.error)
                null
            }
        }
    }

    routing {
        post("/v1/pair") {
            call.response.header(HttpHeaders.CacheControl, "no-store")
            val body = call.parseJsonBody()
            val secret = body["secret"]?.jsonPrimitive?.contentOrNull.orEmpty()
            val platform = body["platform"]?.jsonPrimitive?.contentOrNull.orEmpty()
            val deviceName = body["deviceName"]?.jsonPrimitive?.contentOrNull
            val protocolVersion = body["protocolVersion"]?.jsonPrimitive?.intOrNull ?: 1
            val nodeRole = body["nodeRole"]?.jsonPrimitive?.contentOrNull ?: "hybrid"
            val trustedApprovalSurface = body["trustedApprovalSurface"]?.jsonPrimitive?.booleanOrNull
            val requestBootstrapSync = body["requestBootstrapSync"]?.jsonPrimitive?.booleanOrNull ?: false
            val clientPublicJwkElement = body["clientPublicJwk"]
            val clientPublicJwk = if (clientPublicJwkElement != null) {
                val obj = runCatching { clientPublicJwkElement.jsonObject }.getOrNull()
                    ?: return@post call.respondError(400, "invalid_client_public_key")
                try {
                    ConfigurationEncryption.validateClientPublicJwk(obj)
                    obj
                } catch (e: ConfigurationApiException) {
                    return@post call.respondError(e.status, e.code)
                }
            } else {
                null
            }

            when (
                val result = state.pairDevice(
                    secret = secret,
                    platform = platform,
                    deviceName = deviceName,
                    protocolVersion = protocolVersion,
                    nodeRole = nodeRole,
                    trustedApprovalSurface = trustedApprovalSurface,
                )
            ) {
                is CloudGatewayState.PairResult.Success -> {
                    val bootstrapSnapshot = if (requestBootstrapSync || clientPublicJwk != null) {
                        val pairedDevice = state.findDeviceById(result.deviceId)
                        buildPairingBootstrap(
                            device = pairedDevice,
                            clientPublicJwk = clientPublicJwk,
                            configManager = agentApi?.kernel?.configurationManager,
                            soulStore = soulStore,
                            ruleStore = ruleStore,
                        )?.also { snapshot ->
                            state.recordAudit(
                                "pair-bootstrap-sync",
                                mapOf(
                                    "device" to result.deviceId,
                                    "encryptedConfig" to (snapshot.encryptedConfigJwe != null).toString(),
                                    "soulRevision" to (snapshot.soul?.revision ?: 0L).toString(),
                                    "activeRulesCount" to snapshot.activeRules.size.toString(),
                                ),
                            )
                        }
                    } else {
                        null
                    }
                    val resp = buildJsonObject {
                        put("deviceId", result.deviceId)
                        put("token", result.token)
                        put("gatewayId", result.gatewayId)
                        put("gatewayName", result.gatewayName)
                        if (bootstrapSnapshot != null) {
                            put(
                                "bootstrap",
                                gatewayJson.encodeToJsonElement(PairingBootstrapSnapshot.serializer(), bootstrapSnapshot),
                            )
                        }
                    }
                    call.respondJson(200, gatewayJson.encodeToString(JsonObject.serializer(), resp))
                }
                is CloudGatewayState.PairResult.BadRequest -> call.respondError(400, result.error)
                is CloudGatewayState.PairResult.Forbidden -> call.respondError(403, result.error)
                is CloudGatewayState.PairResult.ServerError -> call.respondError(500, result.error)
            }
        }

        post("/v2/pairing/issue") {
            call.response.header(HttpHeaders.CacheControl, "no-store")
            val device = call.authenticate() ?: return@post
            try {
                CloudConfigurationManager.requireManagementDevice(device)
            } catch (e: ConfigurationApiException) {
                return@post call.respondError(e.status, e.code)
            }
            val body = call.parseJsonBody()
            val requestedPort = body["port"]?.jsonPrimitive?.intOrNull?.takeIf { it in 1..65535 } ?: gatewayPort
            val tls = TlsIdentityManager.loadOrCreate(state.tlsIdentityFile, state.identity.name)
            val nowSec = state.clockEpochSeconds()
            val ttlSec = 300.0
            val secret = state.issuePairingTicket(nowSeconds = nowSec, ttlSeconds = ttlSec)
            val addrs = CandidateAddressResolver.resolve(publicAddresses = publicAddresses)
            val soulRev = soulStore?.currentRevision() ?: 0L
            val activeRulesCount = ruleStore?.activeSnapshot()?.size ?: 0
            val hint = agentApi?.kernel?.configurationManager?.buildBootstrapHint(soulRev, activeRulesCount)
                ?: PairingBootstrapHint(
                    syncSupported = true,
                    soulRevision = soulRev,
                    activeRulesCount = activeRulesCount,
                )
            val payload = PairingPayload(
                v = 1,
                id = state.identity.id,
                name = state.identity.name,
                addrs = addrs,
                port = requestedPort,
                fp = tls.spkiFingerprintBase64,
                s = secret,
                bootstrap = hint,
            )
            val dto = IssuedPairingTicketDto(
                deepLinkUrl = payload.deepLinkUrl,
                fingerprint = payload.fp,
                addresses = payload.addrs,
                port = payload.port,
                expiresAt = nowSec + ttlSec,
                bootstrap = hint,
            )
            call.respondJson(200, gatewayJson.encodeToString(IssuedPairingTicketDto.serializer(), dto))
        }

        post("/v2/pairing/bootstrap-sync") {
            call.response.header(HttpHeaders.CacheControl, "no-store")
            val device = call.authenticate() ?: return@post
            try {
                CloudConfigurationManager.requireManagementDevice(device)
            } catch (e: ConfigurationApiException) {
                return@post call.respondError(e.status, e.code)
            }
            val body = call.parseJsonBody()
            val clientPublicJwkElement = body["clientPublicJwk"]
            val clientPublicJwk = if (clientPublicJwkElement != null) {
                val obj = runCatching { clientPublicJwkElement.jsonObject }.getOrNull()
                    ?: return@post call.respondError(400, "invalid_client_public_key")
                try {
                    ConfigurationEncryption.validateClientPublicJwk(obj)
                    obj
                } catch (e: ConfigurationApiException) {
                    return@post call.respondError(e.status, e.code)
                }
            } else {
                null
            }
            val snapshot = buildPairingBootstrap(
                device = device,
                clientPublicJwk = clientPublicJwk,
                configManager = agentApi?.kernel?.configurationManager,
                soulStore = soulStore,
                ruleStore = ruleStore,
            ) ?: return@post call.respondError(503, "bootstrap_unavailable")
            state.recordAudit(
                "pair-bootstrap-sync",
                mapOf(
                    "device" to device.id,
                    "encryptedConfig" to (snapshot.encryptedConfigJwe != null).toString(),
                    "soulRevision" to (snapshot.soul?.revision ?: 0L).toString(),
                    "activeRulesCount" to snapshot.activeRules.size.toString(),
                ),
            )
            call.respondJson(200, gatewayJson.encodeToString(PairingBootstrapSnapshot.serializer(), snapshot))
        }

        get("/v1/status") {
            val device = call.authenticate() ?: return@get
            val status = state.buildStatusResponse(device)
            call.respondJson(200, gatewayJson.encodeToString(StatusResponseDto.serializer(), status))
        }

        post("/v1/unpair") {
            val device = call.authenticate() ?: return@post
            state.unpairDevice(device.id)
            call.respondJson(200, "{}")
        }

        post("/v1/push-token") {
            val device = call.authenticate() ?: return@post
            val body = call.parseJsonBody()
            val token = body["token"]?.jsonPrimitive?.contentOrNull
            val environment = body["environment"]?.jsonPrimitive?.contentOrNull
            val (status, err) = state.registerPushToken(device, token, environment)
            if (err != null) {
                call.respondError(status, err)
            } else {
                call.respondJson(200, "{}")
            }
        }

        post("/v1/test-push") {
            val device = call.authenticate() ?: return@post
            val (status, err) = state.sendTestPush(device.id)
            if (err != null) {
                call.respondError(status, err)
            } else {
                val ok = buildJsonObject { put("delivered", true) }
                call.respondJson(200, gatewayJson.encodeToString(JsonObject.serializer(), ok))
            }
        }

        post("/v1/amber/decision") {
            val device = call.authenticate() ?: return@post
            val body = call.parseJsonBody()
            val sessionKey = body["sessionKey"]?.jsonPrimitive?.contentOrNull
            val toolCallId = body["toolCallId"]?.jsonPrimitive?.contentOrNull
            val allow = body["allow"]?.jsonPrimitive?.booleanOrNull

            // C3 v2 rule: High-risk `allow=true` is ONLY permitted when the request originates from
            // a paired native App that explicitly proves unlocked foreground state
            // (`X-Amber-Trusted-Foreground: true` or `trustedForeground: true`) and is not from
            // lockscreen / notification / watch / dynamic_island / IM surface.
            val surfaceHeader = call.request.header("X-Amber-Surface")?.trim()?.lowercase()
            val isUntrustedSurface = surfaceHeader in UNTRUSTED_SURFACES
            val foregroundHeader = call.request.header("X-Amber-Trusted-Foreground")?.equals("true", ignoreCase = true) == true
            val foregroundBody = body["trustedForeground"]?.jsonPrimitive?.booleanOrNull == true
            val biometricHeader = call.request.header("X-Amber-Biometric-Verified")?.lowercase()
            val biometricBody = body["biometricVerified"]?.jsonPrimitive?.booleanOrNull
            val biometricVerified = (biometricHeader == "true" || biometricBody == true) && biometricHeader != "false" && biometricBody != false
            val trustedForeground = device.trustedApprovalSurface &&
                !isUntrustedSurface &&
                biometricVerified &&
                (foregroundHeader || foregroundBody)

            val decisionResult = state.processDecision(
                sessionKey = sessionKey,
                toolCallId = toolCallId,
                allow = allow,
                actorDevice = device.id,
                trustedForegroundSource = trustedForeground,
            )
            if (decisionResult.error != null) {
                if (decisionResult.requiresLocalApproval != null || decisionResult.riskLevel != null) {
                    val payload = buildJsonObject {
                        put("error", decisionResult.error)
                        decisionResult.requiresLocalApproval?.let { put("requiresLocalApproval", it) }
                        decisionResult.riskLevel?.let { put("riskLevel", it) }
                        decisionResult.targetDevice?.let { put("targetDevice", it) }
                        decisionResult.targetSummary?.let { put("targetSummary", it) }
                        decisionResult.diffPreview?.let { put("diffPreview", it) }
                    }
                    call.respondJson(decisionResult.status, gatewayJson.encodeToString(JsonObject.serializer(), payload))
                } else {
                    call.respondError(decisionResult.status, decisionResult.error)
                }
            } else {
                call.respondJson(200, "{}")
            }
        }

        get("/v1/amber/board") {
            call.authenticate() ?: return@get
            val board = state.buildBoardResponse()
            call.respondJson(200, gatewayJson.encodeToString(BoardResponseDto.serializer(), board))
        }

        get("/v1/amber/schedules") {
            call.authenticate() ?: return@get
            val list = ScheduleListResponseDto(schedules = state.listSchedules())
            call.respondJson(200, gatewayJson.encodeToString(ScheduleListResponseDto.serializer(), list))
        }

        post("/v1/amber/schedules") {
            val device = call.authenticate() ?: return@post
            val body = call.parseJsonBody()
            val name = body["name"]?.jsonPrimitive?.contentOrNull
            val prompt = body["prompt"]?.jsonPrimitive?.contentOrNull
            val rule = body["rule"]?.jsonPrimitive?.contentOrNull
            val intervalMinutes = body["intervalMinutes"]?.jsonPrimitive?.intOrNull
            val (status, result) = state.createSchedule(
                name = name,
                prompt = prompt,
                rule = rule,
                intervalMinutes = intervalMinutes,
                deviceId = device.id,
            )
            if (status >= 300) {
                call.respondError(status, result.toString())
            } else {
                val dto = result as ScheduleSummaryDto
                val wrapper = buildJsonObject {
                    put("schedule", gatewayJson.encodeToJsonElement(ScheduleSummaryDto.serializer(), dto))
                }
                call.respondJson(200, gatewayJson.encodeToString(JsonObject.serializer(), wrapper))
            }
        }

        post("/v1/amber/schedules/{id}/enabled") {
            val device = call.authenticate() ?: return@post
            val id = call.parameters["id"]?.let { URLDecoder.decode(it, StandardCharsets.UTF_8) }.orEmpty()
            val body = call.parseJsonBody()
            val enabled = body["enabled"]?.jsonPrimitive?.booleanOrNull
            if (enabled == null) {
                call.respondError(400, "需要 enabled 布尔值")
                return@post
            }
            val (status, result) = state.setScheduleEnabled(id, enabled, device.id)
            if (status >= 300) {
                call.respondError(status, result.toString())
            } else {
                val dto = result as ScheduleSummaryDto
                val wrapper = buildJsonObject {
                    put("schedule", gatewayJson.encodeToJsonElement(ScheduleSummaryDto.serializer(), dto))
                }
                call.respondJson(200, gatewayJson.encodeToString(JsonObject.serializer(), wrapper))
            }
        }

        post("/v1/amber/schedules/{id}/run") {
            val device = call.authenticate() ?: return@post
            val id = call.parameters["id"]?.let { URLDecoder.decode(it, StandardCharsets.UTF_8) }.orEmpty()
            val (status, result) = if (agentApi != null) {
                agentApi.kernel.scheduleRunner.triggerManual(id, device)
            } else {
                state.triggerScheduleNow(id, device.id)
            }
            if (status >= 300) {
                call.respondError(status, result.toString())
            } else {
                val dto = result as ScheduleSummaryDto
                val wrapper = buildJsonObject {
                    put("schedule", gatewayJson.encodeToJsonElement(ScheduleSummaryDto.serializer(), dto))
                }
                call.respondJson(200, gatewayJson.encodeToString(JsonObject.serializer(), wrapper))
            }
        }

        post("/v1/tasks/{key}/monitor") {
            val device = call.authenticate() ?: return@post
            val rawKey = call.parameters["key"] ?: return@post call.respondError(400, "缺少任务 key")
            val key = URLDecoder.decode(rawKey, StandardCharsets.UTF_8)
            val body = call.parseJsonBody()
            val monitored = body["monitored"]?.jsonPrimitive?.booleanOrNull
                ?: return@post call.respondError(400, "需要 monitored 布尔值")
            if (!state.setMonitored(key, monitored)) {
                call.respondError(404, "任务不存在")
            } else {
                val resp = buildJsonObject { put("monitored", monitored) }
                call.respondJson(200, gatewayJson.encodeToString(JsonObject.serializer(), resp))
            }
        }

        post("/v1/channels/feishu/webhook") {
            val ch = feishuChannel
            if (ch == null) {
                call.respondError(404, "飞书通道未启用")
                return@post
            }
            val rawBody = runCatching { call.receiveText() }.getOrDefault("")
            val headers = buildMap<String, String> {
                for (name in call.request.headers.names()) {
                    call.request.headers[name]?.let { put(name, it) }
                }
            }
            val resp = ch.handleWebhookEvent(headers = headers, rawBody = rawBody)
            call.respondJson(resp.statusCode, resp.bodyJson)
        }
    }
}

private fun buildPairingBootstrap(
    device: PairedDevice?,
    clientPublicJwk: JsonObject?,
    configManager: CloudConfigurationManager?,
    soulStore: app.amber.cloud.soul.CloudSoulStore?,
    ruleStore: ProceduralRuleStore?,
): PairingBootstrapSnapshot? {
    if (device == null) return null
    val isTrustedManagement = runCatching {
        CloudConfigurationManager.requireManagementDevice(device)
        true
    }.getOrDefault(false)
    if (!isTrustedManagement) return null
    val soul = soulStore?.get()
    val activeRules = ruleStore?.activeSnapshot().orEmpty()
    if (configManager != null) {
        return configManager.exportBootstrapSnapshot(
            device = device,
            clientPublicJwk = clientPublicJwk,
            soul = soul,
            activeRules = activeRules,
        )
    }
    return PairingBootstrapSnapshot(
        version = 1,
        configuration = null,
        encryptedConfigJwe = null,
        soul = soul,
        activeRules = activeRules,
        importKey = null,
    )
}

private val UNTRUSTED_SURFACES = setOf(
    "lockscreen",
    "notification",
    "banner",
    "dynamic_island",
    "watch",
    "im",
    "telegram",
    "feishu",
    "cloud_self",
)
