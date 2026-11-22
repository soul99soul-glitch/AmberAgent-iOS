package app.amber.cloud.gateway

import app.amber.cloud.config.CloudConfigurationManager
import app.amber.cloud.config.ConfigurationApiException
import app.amber.cloud.rules.ProceduralRuleListResponseDto
import app.amber.cloud.rules.ProceduralRuleRedirectDto
import app.amber.cloud.rules.ProceduralRuleResponseDto
import app.amber.cloud.rules.ProceduralRuleStatus
import app.amber.cloud.rules.ProceduralRuleStore
import app.amber.cloud.rules.ProposeRuleRequestDto
import app.amber.cloud.rules.RuleProposalOutcome
import app.amber.cloud.security.PlaceholderCredentialException
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.request.header
import io.ktor.server.request.receiveText
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Procedural Rule Card endpoints:
 * - `GET  /v2/rules` (optional `?status=proposed|active|archived|revoked&scope=...`)
 * - `POST /v2/rules/propose` (and `POST /v2/rules` alias) — always creates `proposed`; redirects pure persona to C-SOUL-V1
 * - `POST /v2/rules/{id}/confirm` — explicit confirmation `proposed -> active`
 * - `POST /v2/rules/{id}/archive` — archive rule (excluded on next turn)
 * - `POST /v2/rules/{id}/revoke`  — revoke rule (100% excluded on next turn)
 */
internal fun Application.configureProceduralRuleRoutes(
    state: CloudGatewayState,
    ruleStore: ProceduralRuleStore,
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
            is CloudGatewayState.AuthResult.Authenticated -> try {
                CloudConfigurationManager.requireManagementDevice(auth.device)
                auth.device
            } catch (e: ConfigurationApiException) {
                respondError(e.status, e.code)
                null
            }
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

    suspend fun ApplicationCall.handlePropose() {
        val device = authenticate() ?: return
        try {
            val raw = receiveText()
            require(raw.length <= 32_000) { "请求体过大" }
            val req = json.decodeFromString<ProposeRuleRequestDto>(raw)
            when (
                val outcome = ruleStore.propose(
                    instruction = req.instruction,
                    title = req.title,
                    scope = req.scope,
                    sourceEventId = req.sourceEventId.orEmpty(),
                )
            ) {
                is RuleProposalOutcome.Proposed -> {
                    state.recordAudit(
                        "rule-propose",
                        mapOf(
                            "device" to device.id,
                            "ruleId" to outcome.rule.id,
                            "status" to outcome.rule.status.wireName,
                        ),
                    )
                    respondText(
                        json.encodeToString(
                            ProceduralRuleResponseDto.serializer(),
                            ProceduralRuleResponseDto(rule = outcome.rule, deduplicated = outcome.deduplicated),
                        ),
                        ContentType.Application.Json,
                        HttpStatusCode.Created,
                    )
                }
                is RuleProposalOutcome.RedirectToSoul -> {
                    respondText(
                        json.encodeToString(
                            ProceduralRuleRedirectDto.serializer(),
                            ProceduralRuleRedirectDto(
                                target = outcome.target,
                                message = "${outcome.reason}${outcome.suggestion}",
                            ),
                        ),
                        ContentType.Application.Json,
                        HttpStatusCode.UnprocessableEntity,
                    )
                }
                is RuleProposalOutcome.Rejected -> {
                    respondText(
                        json.encodeToString(
                            buildJsonObject {
                                put("error", outcome.code)
                                put("message", outcome.reason)
                            },
                        ),
                        ContentType.Application.Json,
                        HttpStatusCode.UnprocessableEntity,
                    )
                }
            }
        } catch (_: SerializationException) {
            respondError(400, "invalid_rule_payload")
        } catch (_: PlaceholderCredentialException) {
            respondError(400, "placeholder_credential_rejected")
        } catch (_: IllegalArgumentException) {
            respondError(400, "invalid_rule_payload")
        }
    }

    routing {
        get("/v2/rules") {
            call.authenticate() ?: return@get
            val statusParam = call.request.queryParameters["status"]
            val status = if (statusParam.isNullOrBlank()) {
                null
            } else {
                ProceduralRuleStatus.parse(statusParam)
                    ?: return@get call.respondError(400, "invalid_rule_status")
            }
            val scope = call.request.queryParameters["scope"]
            val scopedRules = ruleStore.list(scope = scope)
            val (activeCount, proposedCount) = ruleStore.counts(scopedRules)
            val payload = json.encodeToString(
                ProceduralRuleListResponseDto.serializer(),
                ProceduralRuleListResponseDto(
                    rules = scopedRules.filter { status == null || it.status == status },
                    activeCount = activeCount,
                    proposedCount = proposedCount,
                ),
            )
            call.respondText(payload, ContentType.Application.Json, HttpStatusCode.OK)
        }

        post("/v2/rules") { call.handlePropose() }
        post("/v2/rules/propose") { call.handlePropose() }

        post("/v2/rules/{id}/confirm") {
            val device = call.authenticate() ?: return@post
            val id = call.parameters["id"].orEmpty()
            try {
                val updated = ruleStore.confirm(id)
                state.recordAudit(
                    "rule-confirm",
                    mapOf("device" to device.id, "ruleId" to updated.id, "status" to updated.status.wireName),
                )
                call.respondText(
                    json.encodeToString(ProceduralRuleResponseDto.serializer(), ProceduralRuleResponseDto(rule = updated)),
                    ContentType.Application.Json,
                    HttpStatusCode.OK,
                )
            } catch (_: NoSuchElementException) {
                call.respondError(404, "rule_not_found")
            } catch (e: IllegalStateException) {
                call.respondError(409, e.message ?: "rule_state_conflict")
            }
        }

        post("/v2/rules/{id}/archive") {
            val device = call.authenticate() ?: return@post
            val id = call.parameters["id"].orEmpty()
            try {
                val updated = ruleStore.archive(id)
                state.recordAudit(
                    "rule-archive",
                    mapOf("device" to device.id, "ruleId" to updated.id, "status" to updated.status.wireName),
                )
                call.respondText(
                    json.encodeToString(ProceduralRuleResponseDto.serializer(), ProceduralRuleResponseDto(rule = updated)),
                    ContentType.Application.Json,
                    HttpStatusCode.OK,
                )
            } catch (_: NoSuchElementException) {
                call.respondError(404, "rule_not_found")
            }
        }

        post("/v2/rules/{id}/revoke") {
            val device = call.authenticate() ?: return@post
            val id = call.parameters["id"].orEmpty()
            try {
                val updated = ruleStore.revoke(id)
                state.recordAudit(
                    "rule-revoke",
                    mapOf("device" to device.id, "ruleId" to updated.id, "status" to updated.status.wireName),
                )
                call.respondText(
                    json.encodeToString(ProceduralRuleResponseDto.serializer(), ProceduralRuleResponseDto(rule = updated)),
                    ContentType.Application.Json,
                    HttpStatusCode.OK,
                )
            } catch (_: NoSuchElementException) {
                call.respondError(404, "rule_not_found")
            }
        }
    }
}
