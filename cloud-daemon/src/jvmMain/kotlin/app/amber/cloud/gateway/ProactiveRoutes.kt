package app.amber.cloud.gateway

import app.amber.cloud.orchestration.DialogueEvent
import app.amber.cloud.proactive.CreatedProactiveWebhook
import app.amber.cloud.proactive.L1DeterministicFilter
import app.amber.cloud.proactive.ProactiveFeedbackAction
import app.amber.cloud.proactive.ProactiveMonitorRecord
import app.amber.cloud.proactive.ProactiveRunHistoryEntry
import app.amber.cloud.proactive.ProactiveRunResult
import app.amber.cloud.proactive.ProactiveTriggerSignal
import app.amber.cloud.proactive.ProactiveWakeupRecord
import app.amber.cloud.proactive.ProactiveWebhookRecord
import app.amber.cloud.proactive.RestraintStatusSnapshot
import app.amber.cloud.proactive.RestraintVerdict
import app.amber.cloud.proactive.readBoundedBody
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.security.CredentialRedactor
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.request.header
import io.ktor.server.request.receiveChannel
import io.ktor.server.request.receiveText
import io.ktor.server.response.header
import io.ktor.server.response.respondText
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.patch
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.time.format.DateTimeParseException
import java.util.UUID

@Serializable
data class ProactiveSummaryResponseDto(
    val monitors: List<ProactiveMonitorRecord>,
    val webhooks: List<ProactiveWebhookRecord>,
    val restraint: RestraintStatusSnapshot,
    val recentRuns: List<ProactiveRunHistoryEntry>,
    val wakeups: List<ProactiveWakeupRecord> = emptyList(),
)

private const val MAX_WEBHOOK_BODY_BYTES = 64 * 1024
private val PROACTIVE_SIGNAL_ID_REGEX = Regex("^[A-Za-z0-9_-]{1,48}$")

/**
 * 主动自动化 v2 REST API 与个人签名入站 Webhook 端点：
 * - `POST /v2/triggers/webhook/{id}`（独立 HMAC-SHA256 / Bearer 恒定时间验签，无需配对设备 token）
 * - `GET  /v2/proactive/summary`
 * - `POST /v2/proactive/monitors`, `PATCH /v2/proactive/monitors/{id}`, `DELETE /v2/proactive/monitors/{id}`
 * - `POST /v2/proactive/webhooks`, `PATCH /v2/proactive/webhooks/{id}`, `DELETE /v2/proactive/webhooks/{id}`
 * - `PATCH /v2/proactive/restraint`
 */
internal fun Application.configureProactiveRoutes(
    state: CloudGatewayState,
    kernel: CloudAgentKernel,
) {
    val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }

    suspend fun ApplicationCall.respondJson(status: Int, payload: String) = respondText(
        text = payload,
        contentType = ContentType.Application.Json,
        status = HttpStatusCode.fromValue(status),
    )

    suspend fun ApplicationCall.respondError(status: Int, message: String) = respondJson(
        status,
        json.encodeToString(JsonObject.serializer(), buildJsonObject { put("error", CredentialRedactor.redact(message)) }),
    )

    suspend fun ApplicationCall.parseJsonBody(): JsonObject? {
        val raw = try {
            receiveText()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            return null
        }
        if (raw.isBlank()) return JsonObject(emptyMap())
        return runCatching { json.parseToJsonElement(raw).jsonObject }.getOrNull()
    }

    suspend fun ApplicationCall.authenticateOwnerDevice(): PairedDevice? {
        val authHeader = request.header(HttpHeaders.Authorization)
        val token = authHeader
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
                respondError(500, "device_registry_unavailable")
                null
            }
        }
    }

    routing {
        // -----------------------------------------------------------------
        // 1. 个人签名入站 Webhook（独立验签，不要求配对设备 token）
        // -----------------------------------------------------------------
        post("/v2/triggers/webhook/{id}") {
            val id = call.parameters["id"]?.let { URLDecoder.decode(it, StandardCharsets.UTF_8) }?.trim().orEmpty()
            val webhook = kernel.proactiveWebhookStore.get(id)
            if (webhook == null) {
                call.respondError(404, "webhook_not_found")
                return@post
            }
            if (!webhook.enabled) {
                call.respondError(403, "webhook_disabled")
                return@post
            }

            if ((call.request.header(HttpHeaders.ContentLength)?.toLongOrNull() ?: 0L) > MAX_WEBHOOK_BODY_BYTES) {
                call.respondError(413, "webhook_payload_too_large")
                return@post
            }
            val rawBytes = try {
                call.receiveChannel().readBoundedBody(MAX_WEBHOOK_BODY_BYTES)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                call.respondError(400, "invalid_request_body")
                return@post
            }
            if (rawBytes == null) {
                call.respondError(413, "webhook_payload_too_large")
                return@post
            }

            val signatureHeader = call.request.header("X-Amber-Signature")
            val authHeader = call.request.header(HttpHeaders.Authorization)
            val verified = kernel.proactiveWebhookStore.verifyInboundAuth(
                webhookId = id,
                rawBodyBytes = rawBytes,
                signatureHeader = signatureHeader,
                authorizationHeader = authHeader,
            )
            if (!verified) {
                state.recordAudit("proactive-webhook-unauthorized", mapOf("webhookId" to id))
                call.respondError(401, "invalid_webhook_signature")
                return@post
            }

            val rawText = String(rawBytes, StandardCharsets.UTF_8)
            val payloadHash = L1DeterministicFilter.sha256Hex(rawBytes)
            val deliveryId = call.request.header("X-Amber-Delivery")?.trim()?.takeIf { it.isNotEmpty() }?.let { id ->
                if (id.length <= 128 && CredentialRedactor.redact(id) == id) id else L1DeterministicFilter.sha256Hex(id)
            } ?: payloadHash
            val redactedPayload = CredentialRedactor.redact(rawText)
            val nowMs = System.currentTimeMillis()
            val signal = ProactiveTriggerSignal.WebhookInboundSignal(
                signalId = "whsig_" + UUID.randomUUID().toString().replace("-", "").take(12),
                webhookId = webhook.id,
                webhookName = webhook.name,
                deliveryId = deliveryId,
                signedPayloadHash = payloadHash.takeIf { signatureHeader != null },
                instruction = webhook.instruction,
                redactedPayload = redactedPayload,
                timestampEpochMs = nowMs,
            )

            val runResult = kernel.triggerProactiveSignal(signal, nowOverrideMs = nowMs)
            val (outcome, detail) = when (runResult) {
                is ProactiveRunResult.DroppedAtL1 -> "duplicate" to runResult.outcome.reason
                is ProactiveRunResult.PushedAtL3 -> {
                    kernel.proactiveWebhookStore.recordTriggered(webhook.id, nowMs)
                    "pushed" to (runResult.l2Score?.summary ?: runResult.card.title)
                }
                is ProactiveRunResult.SuppressedAtGate -> {
                    kernel.proactiveWebhookStore.recordTriggered(webhook.id, nowMs)
                    val reason = when (val v = runResult.restraintVerdict) {
                        is RestraintVerdict.SuppressedQuietHours -> v.reason
                        is RestraintVerdict.DeferredByBudget -> v.reason
                        is RestraintVerdict.DroppedLowScore -> v.reason
                        is RestraintVerdict.AllowedToPush -> "allowed"
                    }
                    "suppressed" to reason
                }
            }

            state.recordAudit(
                "proactive-webhook-inbound",
                mapOf("webhookId" to webhook.id, "deliveryId" to deliveryId, "outcome" to outcome),
            )
            val receipt = buildJsonObject {
                put("ok", true)
                put("webhookId", webhook.id)
                put("deliveryId", deliveryId)
                put("signalId", signal.signalId)
                put("outcome", outcome)
                put("detail", CredentialRedactor.redact(detail).take(240))
            }
            call.respondJson(200, json.encodeToString(JsonObject.serializer(), receipt))
        }

        // -----------------------------------------------------------------
        // 2. 主人统一管理端点（复用已配对设备鉴权）
        // -----------------------------------------------------------------
        get("/v2/proactive/summary") {
            call.authenticateOwnerDevice() ?: return@get
            val dto = ProactiveSummaryResponseDto(
                monitors = kernel.proactiveMonitorStore.list(includeDisabled = true),
                webhooks = kernel.proactiveWebhookStore.list(),
                restraint = kernel.proactiveEngine.restraintGate.statusSnapshot(),
                recentRuns = kernel.proactiveRunHistoryStore.recent(20),
                wakeups = kernel.proactiveWakeupStore.listPending(),
            )
            call.respondJson(200, json.encodeToString(ProactiveSummaryResponseDto.serializer(), dto))
        }

        delete("/v2/proactive/wakeups/{id}") {
            val device = call.authenticateOwnerDevice() ?: return@delete
            val id = call.parameters["id"]?.let { URLDecoder.decode(it, StandardCharsets.UTF_8) }?.trim().orEmpty()
            val cancelled = if (id.isNotEmpty()) kernel.proactiveWakeupStore.cancel(id) else false
            if (!cancelled) {
                call.respondError(404, "wakeup_not_found")
            } else {
                state.recordAudit("proactive-wakeup-cancel", mapOf("device" to device.id, "wakeupId" to id))
                val resp = buildJsonObject {
                    put("cancelled", true)
                    put("id", id)
                }
                call.respondJson(200, json.encodeToString(JsonObject.serializer(), resp))
            }
        }

        get("/v2/proactive/signals/{signalId}") {
            call.authenticateOwnerDevice() ?: return@get
            val signalId = call.parameters["signalId"].orEmpty()
            if (!PROACTIVE_SIGNAL_ID_REGEX.matches(signalId)) {
                call.respondError(400, "invalid_signal_id")
                return@get
            }
            val event = kernel.orchestrationStore.dialogue.findEvent("proactive:$signalId")
            if (event == null) {
                call.respondError(404, "signal_not_found")
                return@get
            }
            val resp = buildJsonObject {
                put("event", json.encodeToJsonElement(DialogueEvent.serializer(), event))
            }
            call.respondJson(200, json.encodeToString(JsonObject.serializer(), resp))
        }

        post("/v2/proactive/signals/{signalId}/feedback") {
            val device = call.authenticateOwnerDevice() ?: return@post
            val signalId = call.parameters["signalId"].orEmpty()
            if (!PROACTIVE_SIGNAL_ID_REGEX.matches(signalId)) {
                call.respondError(400, "invalid_signal_id")
                return@post
            }
            val body = call.parseJsonBody() ?: return@post call.respondError(400, "invalid_json")
            val rawAction = (body["action"] as? JsonPrimitive)?.contentOrNull?.trim().orEmpty()
            val action = ProactiveFeedbackAction.entries.firstOrNull { it.wire == rawAction }
            if (action == null) {
                call.respondError(400, "invalid_action")
                return@post
            }
            val snoozeMinutes = (body["snoozeMinutes"]?.jsonPrimitive?.intOrNull
                ?: body["snooze_minutes"]?.jsonPrimitive?.intOrNull
                ?: 60).coerceIn(15, 1440)
            val muteHours = (body["muteHours"]?.jsonPrimitive?.intOrNull
                ?: body["mute_hours"]?.jsonPrimitive?.intOrNull
                ?: 168).coerceIn(1, 720)

            val result = try {
                kernel.applyProactiveFeedback(
                    signalId = signalId,
                    action = action,
                    snoozeMinutes = snoozeMinutes,
                    muteHours = muteHours,
                )
            } catch (e: IllegalArgumentException) {
                return@post call.respondError(409, e.message ?: "feedback_unavailable")
            }
            when (result) {
                CloudAgentKernel.ProactiveFeedbackResult.SignalNotFound -> {
                    call.respondError(404, "signal_not_found")
                }
                is CloudAgentKernel.ProactiveFeedbackResult.Applied -> {
                    state.recordAudit(
                        "proactive-signal-feedback",
                        mapOf(
                            "device" to device.id,
                            "signalId" to signalId,
                            "action" to action.wire,
                            "applied" to result.applied.toString(),
                        ),
                    )
                    val resp = buildJsonObject {
                        put("ok", true)
                        put("action", action.wire)
                        put("applied", result.applied)
                        result.wakeupId?.let { put("wakeupId", it) }
                        result.mutedUntilEpochMs?.let { put("mutedUntilEpochMs", it) }
                    }
                    call.respondJson(200, json.encodeToString(JsonObject.serializer(), resp))
                }
            }
        }

        post("/v2/proactive/restraint/unmute") {
            val device = call.authenticateOwnerDevice() ?: return@post
            val body = call.parseJsonBody() ?: return@post call.respondError(400, "invalid_json")
            val topicKey = (body["topicKey"]?.jsonPrimitive?.contentOrNull
                ?: body["topic_key"]?.jsonPrimitive?.contentOrNull)
                ?.trim()
                .orEmpty()
            if (topicKey.isEmpty()) {
                call.respondError(400, "missing_topic_key")
                return@post
            }
            val snapshot = kernel.proactiveEngine.restraintGate.unmuteTopic(topicKey)
            state.recordAudit(
                "proactive-restraint-unmute",
                mapOf("device" to device.id, "topicKey" to topicKey.take(160)),
            )
            val resp = buildJsonObject {
                put("restraint", json.encodeToJsonElement(RestraintStatusSnapshot.serializer(), snapshot))
            }
            call.respondJson(200, json.encodeToString(JsonObject.serializer(), resp))
        }

        post("/v2/proactive/monitors") {
            val device = call.authenticateOwnerDevice() ?: return@post
            val body = call.parseJsonBody() ?: return@post call.respondError(400, "invalid_json")
            val url = body["url"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
            val title = body["title"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
            val conditionPrompt = body["conditionPrompt"]?.jsonPrimitive?.contentOrNull
                ?: body["condition_prompt"]?.jsonPrimitive?.contentOrNull
                ?: ""
            val intervalMinutes = body["intervalMinutes"]?.jsonPrimitive?.intOrNull
                ?: body["interval_minutes"]?.jsonPrimitive?.intOrNull
                ?: 15
            val enabled = body["enabled"]?.jsonPrimitive?.booleanOrNull ?: true
            try {
                val rawDeliveryModeEl = (body["deliveryMode"] ?: body["delivery_mode"])?.takeUnless { it is JsonNull }
                val deliveryMode = if (rawDeliveryModeEl != null) {
                    val prim = rawDeliveryModeEl as? JsonPrimitive
                        ?: throw IllegalArgumentException("deliveryMode 仅支持 immediate 或 digest")
                    if (!prim.isString) throw IllegalArgumentException("deliveryMode 仅支持 immediate 或 digest")
                    prim.content
                } else {
                    ProactiveMonitorRecord.DELIVERY_MODE_IMMEDIATE
                }
                val created = kernel.proactiveMonitorStore.create(
                    title = title,
                    url = url,
                    conditionPrompt = conditionPrompt,
                    intervalMinutes = intervalMinutes,
                    enabled = enabled,
                    deliveryMode = deliveryMode,
                )
                state.recordAudit("proactive-monitor-create", mapOf("device" to device.id, "monitorId" to created.id))
                val resp = buildJsonObject {
                    put("monitor", json.encodeToJsonElement(ProactiveMonitorRecord.serializer(), created))
                }
                call.respondJson(201, json.encodeToString(JsonObject.serializer(), resp))
            } catch (e: IllegalArgumentException) {
                call.respondError(400, e.message ?: "invalid_monitor")
            }
        }

        patch("/v2/proactive/monitors/{id}") {
            val device = call.authenticateOwnerDevice() ?: return@patch
            val id = call.parameters["id"]?.let { URLDecoder.decode(it, StandardCharsets.UTF_8) }?.trim().orEmpty()
            val body = call.parseJsonBody() ?: return@patch call.respondError(400, "invalid_json")
            try {
                val rawDeliveryModeEl = (body["deliveryMode"] ?: body["delivery_mode"])?.takeUnless { it is JsonNull }
                val deliveryMode = if (rawDeliveryModeEl != null) {
                    val prim = rawDeliveryModeEl as? JsonPrimitive
                        ?: throw IllegalArgumentException("deliveryMode 仅支持 immediate 或 digest")
                    if (!prim.isString) throw IllegalArgumentException("deliveryMode 仅支持 immediate 或 digest")
                    prim.content
                } else {
                    null
                }
                val updated = kernel.proactiveMonitorStore.update(
                    id = id,
                    title = body["title"]?.jsonPrimitive?.contentOrNull,
                    url = body["url"]?.jsonPrimitive?.contentOrNull,
                    conditionPrompt = body["conditionPrompt"]?.jsonPrimitive?.contentOrNull
                        ?: body["condition_prompt"]?.jsonPrimitive?.contentOrNull,
                    intervalMinutes = body["intervalMinutes"]?.jsonPrimitive?.intOrNull
                        ?: body["interval_minutes"]?.jsonPrimitive?.intOrNull,
                    enabled = body["enabled"]?.jsonPrimitive?.booleanOrNull,
                    deliveryMode = deliveryMode,
                )
                if (updated == null) {
                    call.respondError(404, "monitor_not_found")
                } else {
                    state.recordAudit("proactive-monitor-update", mapOf("device" to device.id, "monitorId" to updated.id))
                    val resp = buildJsonObject {
                        put("monitor", json.encodeToJsonElement(ProactiveMonitorRecord.serializer(), updated))
                    }
                    call.respondJson(200, json.encodeToString(JsonObject.serializer(), resp))
                }
            } catch (e: IllegalArgumentException) {
                call.respondError(400, e.message ?: "invalid_monitor")
            }
        }

        delete("/v2/proactive/monitors/{id}") {
            val device = call.authenticateOwnerDevice() ?: return@delete
            val id = call.parameters["id"]?.let { URLDecoder.decode(it, StandardCharsets.UTF_8) }?.trim().orEmpty()
            val deleted = kernel.proactiveMonitorStore.delete(id)
            if (!deleted) {
                call.respondError(404, "monitor_not_found")
            } else {
                state.recordAudit("proactive-monitor-delete", mapOf("device" to device.id, "monitorId" to id))
                val resp = buildJsonObject {
                    put("deleted", true)
                    put("id", id)
                }
                call.respondJson(200, json.encodeToString(JsonObject.serializer(), resp))
            }
        }

        post("/v2/proactive/webhooks") {
            val device = call.authenticateOwnerDevice() ?: return@post
            val body = call.parseJsonBody() ?: return@post call.respondError(400, "invalid_json")
            val name = body["name"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
            val instruction = body["instruction"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
            val enabled = body["enabled"]?.jsonPrimitive?.booleanOrNull ?: true
            try {
                val created = kernel.proactiveWebhookStore.create(
                    name = name,
                    instruction = instruction,
                    enabled = enabled,
                )
                state.recordAudit("proactive-webhook-create", mapOf("device" to device.id, "webhookId" to created.webhook.id))
                call.response.header(HttpHeaders.CacheControl, "no-store")
                call.respondJson(201, json.encodeToString(CreatedProactiveWebhook.serializer(), created))
            } catch (e: IllegalArgumentException) {
                call.respondError(400, e.message ?: "invalid_webhook")
            }
        }

        patch("/v2/proactive/webhooks/{id}") {
            val device = call.authenticateOwnerDevice() ?: return@patch
            val id = call.parameters["id"]?.let { URLDecoder.decode(it, StandardCharsets.UTF_8) }?.trim().orEmpty()
            val body = call.parseJsonBody() ?: return@patch call.respondError(400, "invalid_json")
            val updated = kernel.proactiveWebhookStore.update(
                id = id,
                name = body["name"]?.jsonPrimitive?.contentOrNull,
                enabled = body["enabled"]?.jsonPrimitive?.booleanOrNull,
                instruction = body["instruction"]?.jsonPrimitive?.contentOrNull,
            )
            if (updated == null) {
                call.respondError(404, "webhook_not_found")
            } else {
                state.recordAudit("proactive-webhook-update", mapOf("device" to device.id, "webhookId" to updated.id))
                val resp = buildJsonObject {
                    put("webhook", json.encodeToJsonElement(ProactiveWebhookRecord.serializer(), updated))
                }
                call.respondJson(200, json.encodeToString(JsonObject.serializer(), resp))
            }
        }

        delete("/v2/proactive/webhooks/{id}") {
            val device = call.authenticateOwnerDevice() ?: return@delete
            val id = call.parameters["id"]?.let { URLDecoder.decode(it, StandardCharsets.UTF_8) }?.trim().orEmpty()
            val deleted = kernel.proactiveWebhookStore.delete(id)
            if (!deleted) {
                call.respondError(404, "webhook_not_found")
            } else {
                state.recordAudit("proactive-webhook-delete", mapOf("device" to device.id, "webhookId" to id))
                val resp = buildJsonObject {
                    put("deleted", true)
                    put("id", id)
                }
                call.respondJson(200, json.encodeToString(JsonObject.serializer(), resp))
            }
        }

        patch("/v2/proactive/restraint") {
            val device = call.authenticateOwnerDevice() ?: return@patch
            val body = call.parseJsonBody() ?: return@patch call.respondError(400, "invalid_json")
            try {
                val rawPulseTimeEl = (body["pulseTime"] ?: body["pulse_time"])?.takeUnless { it is JsonNull }
                val pulseTime = if (rawPulseTimeEl != null) {
                    val prim = rawPulseTimeEl as? JsonPrimitive
                        ?: throw IllegalArgumentException("pulseTime 必须为 HH:mm 格式字符串")
                    if (!prim.isString) throw IllegalArgumentException("pulseTime 必须为 HH:mm 格式字符串")
                    prim.content
                } else null

                val updated = kernel.proactiveEngine.restraintGate.updateConfig(
                    quietHoursEnabled = body["quietHoursEnabled"]?.jsonPrimitive?.booleanOrNull
                        ?: body["quiet_hours_enabled"]?.jsonPrimitive?.booleanOrNull,
                    quietHoursStart = body["quietHoursStart"]?.jsonPrimitive?.contentOrNull
                        ?: body["quiet_hours_start"]?.jsonPrimitive?.contentOrNull,
                    quietHoursEnd = body["quietHoursEnd"]?.jsonPrimitive?.contentOrNull
                        ?: body["quiet_hours_end"]?.jsonPrimitive?.contentOrNull,
                    dailyMaxPushes = body["dailyMaxPushes"]?.jsonPrimitive?.intOrNull
                        ?: body["daily_max_pushes"]?.jsonPrimitive?.intOrNull,
                    pulseEnabled = body["pulseEnabled"]?.jsonPrimitive?.booleanOrNull
                        ?: body["pulse_enabled"]?.jsonPrimitive?.booleanOrNull,
                    pulseTime = pulseTime,
                    commitmentExtractionEnabled = body["commitmentExtractionEnabled"]?.jsonPrimitive?.booleanOrNull
                        ?: body["commitment_extraction_enabled"]?.jsonPrimitive?.booleanOrNull,
                )
                state.recordAudit(
                    "proactive-restraint-update",
                    mapOf("device" to device.id, "dailyMaxPushes" to updated.dailyMaxPushes.toString()),
                )
                val resp = buildJsonObject {
                    put("restraint", json.encodeToJsonElement(RestraintStatusSnapshot.serializer(), updated))
                }
                call.respondJson(200, json.encodeToString(JsonObject.serializer(), resp))
            } catch (e: DateTimeParseException) {
                call.respondError(400, "静默时段格式须为 HH:mm")
            } catch (e: IllegalArgumentException) {
                call.respondError(400, e.message ?: "invalid_restraint_config")
            }
        }
    }
}
