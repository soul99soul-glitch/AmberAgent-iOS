package app.amber.cloud.gateway

import app.amber.cloud.orchestration.DialogueConflict
import app.amber.cloud.runtime.CloudAgentKernel
import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable private data class DialogueRequest(val requestId:String,val text:String="")
internal fun Application.configureDialogueRoutes(state:CloudGatewayState,kernel:CloudAgentKernel) {
    val json=Json {encodeDefaults=true}
    suspend fun ApplicationCall.error(code:Int,message:String)=respondText("{\"error\":\"$message\"}",ContentType.Application.Json,HttpStatusCode.fromValue(code))
    suspend fun ApplicationCall.device():PairedDevice? {
        val token=request.header(HttpHeaders.Authorization)?.takeIf {it.startsWith("Bearer ",true)}?.substringAfter(' ')
        return when(val auth=state.authenticateBearer(token)) {
            is CloudGatewayState.AuthResult.Authenticated->auth.device
            else->{error(401,"unauthorized");null}
        }
    }
    suspend fun ApplicationCall.submit(kind:String) {
        val device=device()?:return
        try {
            val text=receiveText();require(text.length<=100_000)
            val body=json.decodeFromString<DialogueRequest>(text)
            val receipt=kernel.nativeDialogue.submit(device,body.requestId,body.text,kind,parameters["id"])
            respondText(json.encodeToString(receipt),ContentType.Application.Json,
                if(kind=="stop"||receipt.replayed)HttpStatusCode.OK else HttpStatusCode.Accepted)
        }catch(e:DialogueConflict){error(409,e.code)}
        catch(_:NoSuchElementException){error(404,"task_not_found")}
        catch(e:IllegalArgumentException){error(if(e.message=="task_terminal")409 else 400,if(e.message=="task_terminal")"task_terminal" else "invalid_request")}
    }
    routing {
        post("/v2/dialogue/messages"){call.submit("message")}
        post("/v2/work-items/{id}/inputs"){call.submit("followup")}
        post("/v2/work-items/{id}/stop"){call.submit("stop")}
        get("/v2/dialogue/receipts/{requestId}"){
            val device=call.device()?:return@get
            val receipt=kernel.nativeDialogue.receipt(device,call.parameters["requestId"].orEmpty())?:return@get call.error(404,"receipt_not_found")
            call.respondText(json.encodeToString(receipt),ContentType.Application.Json)
        }
        get("/v2/dialogue/events"){
            call.device()?:return@get
            try {
                val after=call.request.queryParameters["after"]?.toLong()?:0
                val limit=call.request.queryParameters["limit"]?.toInt()?:100
                call.respondText(json.encodeToString(kernel.orchestrationStore.dialogue.page(after,limit)),ContentType.Application.Json)
            }catch(_:IllegalArgumentException){call.error(400,"invalid_cursor")}
        }
    }
}
