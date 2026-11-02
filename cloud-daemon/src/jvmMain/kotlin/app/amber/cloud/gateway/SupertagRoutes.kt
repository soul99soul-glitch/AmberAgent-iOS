package app.amber.cloud.gateway

import app.amber.cloud.agents.AgentRevisionConflict
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.orchestration.CloudPrincipal
import app.amber.cloud.orchestration.PrincipalPermissionException
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.supertags.*
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.request.header
import io.ktor.server.request.receiveText
import io.ktor.server.response.respondText
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.uuid.Uuid

private val supertagJson = Json { encodeDefaults = true; explicitNulls = true }

@Serializable private data class HubsResponse(val hubs: List<HubSummary>)
@Serializable private data class HubSummary(val id: String, val name: String, val memoryPolicy: app.amber.cloud.agents.AgentMemoryPolicy, val template: app.amber.cloud.agents.HubTemplate, val tags: List<String>, val revision: Int)
@Serializable private data class SaveHubRequest(val hub: HubSettings, val expectedRevision: Int)
@Serializable private data class FocusRequest(val hubId: String? = null)
@Serializable private data class TagsResponse(val tags: List<ConversationTag>)
@Serializable private data class EditTagRequest(val tag: TagCandidate, val hubId: String? = null)
@Serializable private data class RemoveTagRequest(val name: String, val hubId: String? = null)
@Serializable private data class TemplatesResponse(val templates: List<TagTemplate>)
@Serializable private data class EditTemplateRequest(val expectedRevision: Int, val name: String? = null, val archived: Boolean? = null)
@Serializable private data class DeleteTemplateRequest(val expectedRevision: Int)
@Serializable private data class MergeTemplateRequest(val targetId: String, val sourceRevision: Int, val targetRevision: Int)
@Serializable private data class CollectionsResponse(val collections: List<TagCollection>)
@Serializable private data class PromotionsResponse(val promotions: List<HubPromotion>)
@Serializable private data class EventsResponse(val events: List<SupertagEvent>, val nextCursor: Long)
@Serializable private data class RemovedResponse(val removed: Boolean = true)

/** All mutations are explicit paired-owner management actions; no model/Worker tools call these. */
internal fun Application.configureSupertagRoutes(state: CloudGatewayState, kernel: CloudAgentKernel) {
    val store = kernel.supertagStore
    val hubs = kernel.hubs
    suspend fun conversation(call: ApplicationCall): String {
        val id = call.parameters["id"].orEmpty()
        val uuid = Uuid.parse(id)
        if (kernel.conversationStorage.loadConversation(uuid) == null) throw SupertagNotFound("对话不存在")
        return uuid.toString()
    }
    routing {
        get("/v2/hubs") {
            call.supertagRequest(state) { HubsResponse(hubs.list().map { HubSummary(it.id, it.name, it.memoryPolicy, it.template, it.tags, it.revision) }) }
        }
        get("/v2/hubs/{id}") { call.supertagRequest(state) { hubs.get(call.parameters["id"].orEmpty()) } }
        post("/v2/hubs") {
            call.supertagRequest(state) { device ->
                val body = supertagJson.decodeFromString<SaveHubRequest>(call.receiveText())
                hubs.save(CloudPrincipal.OwnerUser(device.id, "c3"), body.hub, body.expectedRevision)
            }
        }
        get("/v2/hub-focus") { call.supertagRequest(state) { FocusRequest(store.focusedHub(PRIMARY_CONVERSATION_ID.toString())) } }
        post("/v2/hub-focus") {
            call.supertagRequest(state) {
                val body = supertagJson.decodeFromString<FocusRequest>(call.receiveText())
                hubs.focus(body.hubId)
                body
            }
        }
        get("/v2/tags") {
            call.supertagRequest(state) {
                val scope = hubs.scope(call.request.queryParameters["hubId"])
                val conversationId = call.request.queryParameters["conversationId"]?.let { Uuid.parse(it).toString() }
                TagsResponse(store.tags(conversationId, scope))
            }
        }
        post("/v2/conversations/{id}/tags") {
            call.supertagRequest(state) {
                val body = supertagJson.decodeFromString<EditTagRequest>(call.receiveText())
                store.editTag(conversation(call), hubs.scope(body.hubId), body.tag, System.currentTimeMillis())
            }
        }
        delete("/v2/conversations/{id}/tags") {
            call.supertagRequest(state) {
                val body = supertagJson.decodeFromString<RemoveTagRequest>(call.receiveText())
                store.removeTag(conversation(call), hubs.scope(body.hubId), body.name, System.currentTimeMillis())
                RemovedResponse()
            }
        }
        get("/v2/tag-templates") {
            call.supertagRequest(state) {
                val scope = hubs.scope(call.request.queryParameters["hubId"])
                val inactive = when (call.request.queryParameters["includeInactive"]) { null, "false" -> false; "true" -> true; else -> throw IllegalArgumentException() }
                TemplatesResponse(store.templates(inactive).filter { it.scopeId in setOf(scope, app.amber.cloud.agents.GLOBAL_MEMORY_AGENT_ID) })
            }
        }
        post("/v2/tag-templates/{id}") {
            call.supertagRequest(state) {
                val body = supertagJson.decodeFromString<EditTemplateRequest>(call.receiveText())
                store.editTemplate(call.parameters["id"].orEmpty(), body.expectedRevision, body.name, body.archived, nowMs = System.currentTimeMillis())
            }
        }
        delete("/v2/tag-templates/{id}") {
            call.supertagRequest(state) {
                val body = supertagJson.decodeFromString<DeleteTemplateRequest>(call.receiveText())
                store.editTemplate(call.parameters["id"].orEmpty(), body.expectedRevision, delete = true, nowMs = System.currentTimeMillis())
            }
        }
        post("/v2/tag-templates/{id}/merge") {
            call.supertagRequest(state) {
                val body = supertagJson.decodeFromString<MergeTemplateRequest>(call.receiveText())
                store.mergeTemplates(call.parameters["id"].orEmpty(), body.targetId, body.sourceRevision, body.targetRevision, byUser = true, nowMs = System.currentTimeMillis())
            }
        }
        get("/v2/collections") {
            call.supertagRequest(state) { CollectionsResponse(store.collections(hubs.scope(call.request.queryParameters["hubId"]), System.currentTimeMillis())) }
        }
        get("/v2/hub-promotions") {
            call.supertagRequest(state) {
                val scope = hubs.scope(call.request.queryParameters["hubId"])
                val live = store.collections(scope, System.currentTimeMillis()).filter { it.conversationIds.size >= 4 }.associateBy { it.id }
                PromotionsResponse(store.promotions().filter { it.scopeId == scope && it.hubId == null && it.collectionId in live }
                    .map { it.copy(conversationIds = live.getValue(it.collectionId).conversationIds) })
            }
        }
        post("/v2/hub-promotions/{id}/confirm") {
            call.supertagRequest(state) { device -> hubs.confirm(CloudPrincipal.OwnerUser(device.id, "c3"), call.parameters["id"].orEmpty(), System.currentTimeMillis()) }
        }
        get("/v2/supertag-events") {
            call.supertagRequest(state) {
                val raw = call.request.queryParameters["after"]
                val after = raw?.toLongOrNull() ?: if (raw == null) 0L else throw IllegalArgumentException()
                val events = store.events(after)
                EventsResponse(events, events.lastOrNull()?.sequence ?: after)
            }
        }
    }
}

private suspend fun ApplicationCall.supertagError(status: Int, message: String) = respondText(supertagJson.encodeToString(buildJsonObject { put("error", message) }), ContentType.Application.Json, HttpStatusCode.fromValue(status))

private suspend inline fun <reified T> ApplicationCall.supertagRequest(state: CloudGatewayState, action: (PairedDevice) -> T) {
    val token = request.header(HttpHeaders.Authorization)?.takeIf { it.startsWith("Bearer ", ignoreCase = true) }?.substringAfter(' ')?.trim()
    val device = when (val auth = state.authenticateBearer(token)) {
        is CloudGatewayState.AuthResult.Authenticated -> auth.device
        is CloudGatewayState.AuthResult.Unauthorized -> { supertagError(401, "unauthorized"); return }
        is CloudGatewayState.AuthResult.CorruptedStore -> { supertagError(500, "认证存储不可用"); return }
    }
    try { respondText(supertagJson.encodeToString(action(device)), ContentType.Application.Json) }
    catch (_: SupertagNotFound) { supertagError(404, "对象不存在") }
    catch (_: AgentRevisionConflict) { supertagError(409, "revision 冲突") }
    catch (_: SupertagConflict) { supertagError(409, "状态或 revision 冲突") }
    catch (_: PrincipalPermissionException) { supertagError(403, "需要主人权限") }
    catch (_: IllegalArgumentException) { supertagError(400, "无效请求") }
}
