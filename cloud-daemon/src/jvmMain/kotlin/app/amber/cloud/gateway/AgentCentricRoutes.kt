package app.amber.cloud.gateway

import app.amber.cloud.agents.AgentProfile
import app.amber.cloud.agents.AgentRevisionConflict
import app.amber.cloud.orchestration.CloudPrincipal
import app.amber.cloud.orchestration.PrincipalPermissionException
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.request.header
import io.ktor.server.request.receive
import io.ktor.server.request.receiveText
import io.ktor.server.response.respondText
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.put
import io.ktor.server.routing.routing
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

internal fun Application.configureAgentCentricRoutes(state: CloudGatewayState, api: AgentCentricApi) {
    configureSupertagRoutes(state, api.kernel)
    configureTaskArtifactRoutes(state, api)
    configureConfigurationRoutes(state, api.kernel)
    configureDialogueRoutes(state, api.kernel)
    val json = Json { encodeDefaults = true; explicitNulls = false }
    suspend fun ApplicationCall.error(status: Int, message: String) = respondText(
        json.encodeToString(buildJsonObject { put("error", message) }), ContentType.Application.Json, HttpStatusCode.fromValue(status),
    )
    suspend fun ApplicationCall.authenticate(): PairedDevice? {
        val header = request.header(HttpHeaders.Authorization)
        val token = header?.takeIf { it.startsWith("Bearer ", ignoreCase = true) }?.substringAfter(' ')?.trim()
        return when (val auth = state.authenticateBearer(token)) {
            is CloudGatewayState.AuthResult.Authenticated -> auth.device
            is CloudGatewayState.AuthResult.Unauthorized -> { error(401, "unauthorized"); null }
            is CloudGatewayState.AuthResult.CorruptedStore -> { error(500, "认证存储不可用"); null }
        }
    }
    routing {
        get("/v2/agents") {
            call.authenticate() ?: return@get
            call.respondText(json.encodeToString(buildJsonObject { put("agents", json.encodeToJsonElement(kotlinx.serialization.builtins.ListSerializer(PublicAgent.serializer()), api.agents())) }), ContentType.Application.Json)
        }
        get("/v2/agents/{id}/activity") {
            call.authenticate() ?: return@get
            val activity = api.activity(call.parameters["id"].orEmpty()) ?: return@get call.error(404, "agent 不存在")
            call.respondText(json.encodeToString(activity), ContentType.Application.Json)
        }
        get("/v2/timeline") {
            call.authenticate() ?: return@get
            val rawLimit = call.request.queryParameters["limit"]
            val limit = rawLimit?.toIntOrNull() ?: if (rawLimit == null) 50 else return@get call.error(400, "无效 limit")
            try {
                call.respondText(json.encodeToString(api.timeline(call.request.queryParameters["before"], limit)), ContentType.Application.Json)
            } catch (_: IllegalArgumentException) { call.error(400, "无效游标或 limit") }
        }
        get("/v2/work-items/{id}") {
            call.authenticate() ?: return@get
            val item = api.workItem(call.parameters["id"].orEmpty()) ?: return@get call.error(404, "work item 不存在")
            call.respondText(json.encodeToString(item), ContentType.Application.Json)
        }
        post("/v2/work-items") {
            val device = call.authenticate() ?: return@post
            try {
                val body = call.receiveText()
                require(body.length <= 100_000) { "请求过长" }
                val result = api.tasks.submit(device, json.decodeFromString<NativeTaskRequest>(body))
                call.respondText(json.encodeToString(result), ContentType.Application.Json,
                    if (result.replayed) HttpStatusCode.OK else HttpStatusCode.Accepted)
            } catch (_: NativeTaskConflict) { call.error(409, "requestId 已用于不同任务") }
            catch (_: NativeTaskAgentMissing) { call.error(404, "agent 不存在") }
            catch (_: IllegalArgumentException) { call.error(400, "无效任务：需要 requestId、text 及有效的 agentId/title") }
        }
        post("/v2/work-items/{id}/cancel") {
            val device = call.authenticate() ?: return@post
            val id = call.parameters["id"].orEmpty()
            if (api.kernel.orchestrationStore.getWorkItem(id) == null) return@post call.error(404, "work item 不存在")
            api.kernel.orchestrationKernel.cancelWorkItem(CloudPrincipal.OwnerUser(device.id, "c3"), id)
            call.respondText(json.encodeToString(api.workItem(id)!!), ContentType.Application.Json)
        }
        post("/v2/agents") {
            val device = call.authenticate() ?: return@post
            try {
                val body = json.parseToJsonElement(call.receiveText()).jsonObject
                val profile = json.decodeFromJsonElement<AgentProfile>(body["profile"] ?: throw IllegalArgumentException())
                val revision = body["expectedRevision"]?.jsonPrimitive?.intOrNull ?: throw IllegalArgumentException()
                val result = api.kernel.agentRegistry.save(CloudPrincipal.OwnerUser(device.id, "c3"), profile, revision)
                call.respondText(json.encodeToString(api.publicAgent(result)), ContentType.Application.Json)
            } catch (_: AgentRevisionConflict) { call.error(409, "revision 冲突") }
            catch (_: IllegalArgumentException) { call.error(400, "无效 agent 配置、模型或权限范围") }
            catch (_: PrincipalPermissionException) { call.error(403, "无权修改 agent") }
        }
        // Management projection for reviewing a concrete Router proposal before confirming its ID.
        get("/v2/agent-proposals") {
            call.authenticate() ?: return@get
            call.respondText(json.encodeToString(api.kernel.agentRegistry.pendingProposals()), ContentType.Application.Json)
        }
        post("/v2/agent-proposals/{id}/confirm") {
            val device = call.authenticate() ?: return@post
            try {
                val body = json.parseToJsonElement(call.receiveText()).jsonObject
                val messageId = body["sourceMessageId"]?.jsonPrimitive?.contentOrNull ?: throw IllegalArgumentException()
                val result = api.kernel.agentRegistry.confirm(CloudPrincipal.OwnerUser(device.id, "c3"), call.parameters["id"].orEmpty(), messageId)
                call.respondText(json.encodeToString(api.publicAgent(result)), ContentType.Application.Json)
            } catch (_: AgentRevisionConflict) { call.error(409, "提议已过期或已确认") }
            catch (_: IllegalArgumentException) { call.error(400, "需要独立主人确认消息") }
            catch (_: SecurityException) { call.error(403, "主人溯源校验失败") }
        }
        put("/v2/device-context/snapshot") {
            val device = call.authenticate() ?: return@put
            val rawBytes = runCatching { call.receive<ByteArray>() }.getOrDefault(ByteArray(0))
            when (val res = state.deviceContextStore.putRawJson(device, rawBytes)) {
                is DeviceContextSnapshotStore.PutResult.Error -> call.error(res.status, res.message)
                is DeviceContextSnapshotStore.PutResult.Stored -> {
                    state.recordAudit("device-context-put", mapOf("device" to device.id))
                    val s = res.snapshot
                    val body = buildJsonObject {
                        put("status", "active")
                        put("deviceId", s.deviceId)
                        put("capturedAtEpochMs", s.capturedAtEpochMs)
                        put("ttlSeconds", s.ttlSeconds)
                        put("expiresAtEpochMs", s.expiresAtEpochMs)
                        put("domains", kotlinx.serialization.json.JsonArray(s.domains.presentDomainNames().map { kotlinx.serialization.json.JsonPrimitive(it) }))
                    }
                    call.respondText(json.encodeToString(body), ContentType.Application.Json)
                }
            }
        }
        get("/v2/device-context/snapshot") {
            val device = call.authenticate() ?: return@get
            if (device.platform != "ios") {
                return@get call.error(403, "仅限已配对 iOS 设备访问")
            }
            when (val res = state.deviceContextStore.read(device.id)) {
                is DeviceContextSnapshotStore.ReadResult.Missing -> {
                    val body = buildJsonObject {
                        put("status", "not_shared")
                        put("domains", kotlinx.serialization.json.JsonArray(emptyList()))
                    }
                    call.respondText(json.encodeToString(body), ContentType.Application.Json)
                }
                is DeviceContextSnapshotStore.ReadResult.Expired -> {
                    state.recordAudit("device-context-get", mapOf("device" to device.id, "status" to "expired"))
                    val body = buildJsonObject {
                        put("status", "expired")
                        put("capturedAtEpochMs", res.capturedAtEpochMs)
                        put("domains", kotlinx.serialization.json.JsonArray(emptyList()))
                    }
                    call.respondText(json.encodeToString(body), ContentType.Application.Json)
                }
                is DeviceContextSnapshotStore.ReadResult.Active -> {
                    state.recordAudit("device-context-get", mapOf("device" to device.id, "status" to "active"))
                    val s = res.snapshot
                    val body = buildJsonObject {
                        put("status", "active")
                        put("deviceId", s.deviceId)
                        put("capturedAtEpochMs", s.capturedAtEpochMs)
                        put("ttlSeconds", s.ttlSeconds)
                        put("expiresAtEpochMs", s.expiresAtEpochMs)
                        put("domains", kotlinx.serialization.json.JsonArray(s.domains.presentDomainNames().map { kotlinx.serialization.json.JsonPrimitive(it) }))
                    }
                    call.respondText(json.encodeToString(body), ContentType.Application.Json)
                }
            }
        }
        delete("/v2/device-context/snapshot") {
            val device = call.authenticate() ?: return@delete
            if (device.platform != "ios") {
                return@delete call.error(403, "仅限已配对 iOS 设备删除")
            }
            val deleted = state.deviceContextStore.delete(device.id)
            state.recordAudit("device-context-delete", mapOf("device" to device.id, "deleted" to deleted.toString()))
            call.respondText(json.encodeToString(buildJsonObject { put("deleted", deleted) }), ContentType.Application.Json)
        }
    }
}
