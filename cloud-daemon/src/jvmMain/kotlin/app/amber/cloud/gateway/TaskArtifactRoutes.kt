package app.amber.cloud.gateway

import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

internal fun Application.configureTaskArtifactRoutes(state: CloudGatewayState, api: AgentCentricApi) {
    routing {
        get("/v2/work-items/{id}/artifacts") { artifactRequest(state,api,false) }
        get("/v2/work-items/{id}/artifacts/download") { artifactRequest(state,api,true) }
    }
}
private suspend fun RoutingContext.artifactRequest(state: CloudGatewayState, api: AgentCentricApi, download: Boolean) {
    val token = call.request.header(HttpHeaders.Authorization)?.takeIf { it.startsWith("Bearer ",true) }?.substringAfter(' ')
    when (state.authenticateBearer(token)) {
        is CloudGatewayState.AuthResult.Unauthorized -> return call.respondText("unauthorized",status=HttpStatusCode.Unauthorized)
        is CloudGatewayState.AuthResult.CorruptedStore -> return call.respondText("认证存储不可用",status=HttpStatusCode.InternalServerError)
        else -> Unit
    }
    val id=call.parameters["id"].orEmpty()
    if (api.kernel.orchestrationStore.getWorkItem(id)==null) return call.respondText("任务不存在",status=HttpStatusCode.NotFound)
    try {
        val files=api.kernel.taskWorkspace
        if (download) {
            val path=call.request.queryParameters["path"] ?: throw IllegalArgumentException("需要path")
            val bytes=files.bytes(id,path)
            val name=File(path).name.replace(Regex("[^a-zA-Z0-9._-]"),"_")
            call.response.header(HttpHeaders.ContentDisposition,ContentDisposition.Attachment.withParameter(ContentDisposition.Parameters.FileName,name).toString())
            call.respondBytes(bytes,ContentType.Application.OctetStream)
        } else call.respondText(Json.encodeToString(files.artifacts(id)),ContentType.Application.Json)
    } catch (e: CancellationException) { throw e }
    catch (_: Exception) { call.respondText("产物不存在、路径无效或文件执行能力不可用",status=HttpStatusCode.BadRequest) }
}
