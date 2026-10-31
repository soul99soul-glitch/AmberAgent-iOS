package app.amber.cloud.gateway

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
fun Application.configureCloudGateway(state: CloudGatewayState) {
    val gatewayJson = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }

    install(ContentNegotiation) {
        json(gatewayJson)
    }

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
            val body = call.parseJsonBody()
            val secret = body["secret"]?.jsonPrimitive?.contentOrNull.orEmpty()
            val platform = body["platform"]?.jsonPrimitive?.contentOrNull.orEmpty()
            val deviceName = body["deviceName"]?.jsonPrimitive?.contentOrNull
            val protocolVersion = body["protocolVersion"]?.jsonPrimitive?.intOrNull ?: 1
            val nodeRole = body["nodeRole"]?.jsonPrimitive?.contentOrNull ?: "hybrid"
            val trustedApprovalSurface = body["trustedApprovalSurface"]?.jsonPrimitive?.booleanOrNull

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
                    val resp = buildJsonObject {
                        put("deviceId", result.deviceId)
                        put("token", result.token)
                        put("gatewayId", result.gatewayId)
                        put("gatewayName", result.gatewayName)
                    }
                    call.respondJson(200, gatewayJson.encodeToString(JsonObject.serializer(), resp))
                }
                is CloudGatewayState.PairResult.BadRequest -> call.respondError(400, result.error)
                is CloudGatewayState.PairResult.Forbidden -> call.respondError(403, result.error)
                is CloudGatewayState.PairResult.ServerError -> call.respondError(500, result.error)
            }
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
            val trustedForeground = device.trustedApprovalSurface && !isUntrustedSurface && (foregroundHeader || foregroundBody)

            val decisionResult = state.processDecision(
                sessionKey = sessionKey,
                toolCallId = toolCallId,
                allow = allow,
                actorDevice = device.id,
                trustedForegroundSource = trustedForeground,
            )
            if (decisionResult.error != null) {
                call.respondError(decisionResult.status, decisionResult.error)
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
            val (status, result) = state.triggerScheduleNow(id, device.id)
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
    }
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
