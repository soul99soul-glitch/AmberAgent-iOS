package app.amber.cloud.gateway

import app.amber.cloud.config.*
import app.amber.cloud.runtime.CloudAgentKernel
import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import io.ktor.utils.io.*
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*

internal fun Application.configureConfigurationRoutes(state: CloudGatewayState, kernel: CloudAgentKernel) {
    val json = Json { encodeDefaults = true }
    suspend fun ApplicationCall.failure(status: Int, code: String, revision: Int? = null) {
        respondText(buildJsonObject { put("error", code); revision?.let { put("currentRevision", it) } }.toString(), ContentType.Application.Json, HttpStatusCode.fromValue(status))
    }
    suspend fun ApplicationCall.management(action: suspend (CloudConfigurationManager, PairedDevice) -> Unit) {
        response.header(HttpHeaders.CacheControl, "no-store")
        val token = request.header(HttpHeaders.Authorization)?.takeIf { it.startsWith("Bearer ", true) }?.substringAfter(' ')?.trim()
        val device = when (val auth = state.authenticateBearer(token)) {
            is CloudGatewayState.AuthResult.Authenticated -> auth.device
            is CloudGatewayState.AuthResult.Unauthorized -> return failure(401, "unauthorized")
            is CloudGatewayState.AuthResult.CorruptedStore -> return failure(503, "configuration_unavailable")
        }
        try {
            CloudConfigurationManager.requireManagementDevice(device)
            val manager = kernel.configurationManager ?: throw ConfigurationApiException(503, "configuration_unavailable")
            action(manager, device)
        } catch (e: CancellationException) { throw e }
        catch (e: ConfigurationApiException) { failure(e.status, e.code, e.currentRevision) }
        catch (_: Exception) { failure(503, "configuration_unavailable") }
    }
    routing {
        get("/v2/configuration") { call.management { manager, device -> call.respondText(json.encodeToString(manager.view(device)), ContentType.Application.Json) } }
        get("/v2/configuration/import-key") { call.management { manager, device -> call.respondText(json.encodeToString(manager.importKey(device)), ContentType.Application.Json) } }
        post("/v2/configuration") {
            call.management { manager, device ->
                // Bound the stream before decoding. The request is never handed to a logger/model/archive.
                val channel = call.receiveChannel()
                val bytes = ByteArray(120_001)
                var total = 0
                while (!channel.isClosedForRead && total < bytes.size) {
                    val size = channel.readAvailable(bytes, total, bytes.size - total)
                    if (size < 0) break
                    total += size
                }
                if (total > 120_000) throw ConfigurationApiException(413, "request_too_large")
                val body = try { json.decodeFromString<ConfigurationImportRequest>(bytes.copyOf(total).decodeToString()) }
                    catch (_: Exception) { throw ConfigurationApiException(400, "invalid_request") }
                    finally { bytes.fill(0) }
                call.respondText(json.encodeToString(manager.update(device, body.jwe)), ContentType.Application.Json)
            }
        }
    }
}
