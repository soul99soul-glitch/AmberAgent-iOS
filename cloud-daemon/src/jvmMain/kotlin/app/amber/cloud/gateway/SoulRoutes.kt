package app.amber.cloud.gateway

import app.amber.cloud.security.PlaceholderCredentialException
import app.amber.cloud.soul.CloudSoulStore
import app.amber.cloud.soul.SoulPutRequestDto
import app.amber.cloud.soul.SoulStateDto
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.request.header
import io.ktor.server.request.receiveText
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.put
import io.ktor.server.routing.routing
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * C-SOUL-V1 endpoints (`GET /v2/soul`, `PUT /v2/soul`, plus `/v2/dialogue/timeline` alias).
 */
internal fun Application.configureSoulRoutes(
    state: CloudGatewayState,
    soulStore: CloudSoulStore,
    agentApi: AgentCentricApi? = null,
) {
    val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }

    suspend fun ApplicationCall.respondError(status: Int, message: String) = respondText(
        text = json.encodeToString(buildJsonObject { put("error", message) }),
        contentType = ContentType.Application.Json,
        status = HttpStatusCode.fromValue(status),
    )

    suspend fun ApplicationCall.authenticate(): PairedDevice? {
        val header = request.header(HttpHeaders.Authorization)
        val token = header
            ?.takeIf { it.startsWith("Bearer ", ignoreCase = true) }
            ?.substringAfter(' ')
            ?.trim()
        return when (val auth = state.authenticateBearer(token)) {
            is CloudGatewayState.AuthResult.Authenticated -> auth.device
            is CloudGatewayState.AuthResult.Unauthorized -> {
                respondError(401, "unauthorized")
                null
            }
            is CloudGatewayState.AuthResult.CorruptedStore -> {
                respondError(500, auth.error)
                null
            }
        }
    }

    routing {
        get("/v2/soul") {
            call.authenticate() ?: return@get
            val payload = json.encodeToString(SoulStateDto.serializer(), soulStore.get())
            call.respondText(payload, ContentType.Application.Json, HttpStatusCode.OK)
        }

        put("/v2/soul") {
            val device = call.authenticate() ?: return@put
            try {
                val raw = call.receiveText()
                require(raw.length <= 100_000) { "请求体过大" }
                val req = if (raw.isBlank()) {
                    SoulPutRequestDto()
                } else {
                    json.decodeFromString<SoulPutRequestDto>(raw)
                }
                val resolvedReq = if (req.source.isNullOrBlank()) {
                    req.copy(source = "device:${device.platform.ifBlank { "app" }}")
                } else {
                    req
                }
                val updated = soulStore.put(resolvedReq)
                state.recordAudit(
                    "soul-update",
                    mapOf(
                        "device" to device.id,
                        "revision" to updated.revision.toString(),
                        "isDefault" to updated.isDefault.toString(),
                        "source" to updated.source,
                    ),
                )
                val payload = json.encodeToString(SoulStateDto.serializer(), updated)
                call.respondText(payload, ContentType.Application.Json, HttpStatusCode.OK)
            } catch (_: SerializationException) {
                call.respondError(400, "invalid_soul_payload")
            } catch (_: PlaceholderCredentialException) {
                call.respondError(400, "placeholder_credential_rejected")
            } catch (_: IllegalArgumentException) {
                call.respondError(400, "invalid_soul_payload")
            }
        }

        if (agentApi != null) {
            get("/v2/dialogue/timeline") {
                call.authenticate() ?: return@get
                val rawLimit = call.request.queryParameters["limit"]
                val limit = rawLimit?.toIntOrNull() ?: if (rawLimit == null) 50 else return@get call.respondError(400, "无效 limit")
                try {
                    val page = agentApi.timeline(call.request.queryParameters["before"], limit)
                    call.respondText(json.encodeToString(TimelinePage.serializer(), page), ContentType.Application.Json)
                } catch (_: IllegalArgumentException) {
                    call.respondError(400, "无效游标或 limit")
                }
            }
        }
    }
}
