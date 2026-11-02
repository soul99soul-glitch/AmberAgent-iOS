package app.amber.cloud

import app.amber.ai.ui.*
import app.amber.cloud.gateway.*
import app.amber.cloud.runtime.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.server.testing.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import java.nio.file.Files
import kotlin.test.*

class TaskRuntimeHttpTest {
    @Test fun pairedTaskRunsCsvAndDownloadsArtifactWithScopedRecipeAndSettlement()=testApplication {
        val dir=Files.createTempDirectory("task-http").toFile();var step=0
        val model=CloudModelClient { messages,tools ->
            if(!messages.first().toText().contains("受管 Worker"))return@CloudModelClient UIMessage.assistant("{\"tags\":[]}")
            assertTrue(tools.any {it.name=="process_run" && it.parameters()!=null})
            val sequence=listOf(
                "host_info" to "{}",
                "recipe_run" to """{"tool":"ssh_profile_create","args":{"host":"forbidden"}}""",
                "workspace_file_write" to """{"path":"data.csv","content":"name,value\na,2\nb,3\n"}""",
                "workspace_file_write" to buildJsonObject {put("path","run.py");put("content","import csv,json\nr=list(csv.DictReader(open('data.csv')))\njson.dump({'sum':sum(int(x['value']) for x in r)},open('result.json','w'))")}.toString(),
                "process_run" to buildJsonObject {put("argv",buildJsonArray {add("/Library/Developer/CommandLineTools/usr/bin/python3");add("run.py")});put("background",false)}.toString(),
                "workspace_file_read" to """{"path":"result.json"}""",
                "task_finish" to """{"outcome":"completed","summary":"CSV已处理，sum=5","artifacts":["result.json"]}"""
            )
            if(step==2)assertContains(messages.last().getTools().single().output.toString(),"禁止调用")
            if(step==5)assertContains(messages.last().getTools().single().output.toString(),"exitCode")
            val (name,args)=sequence[step++]
            UIMessage.assistant("").copy(parts=listOf(UIMessagePart.Tool("call-$step",name,args)))
        }
        val k=CloudAgentKernel(dir,model,masterSecretOverride="task-http-test")
        application {configureCloudGateway(k.gatewayState,agentApi=AgentCentricApi(k))}
        try {
            val pair=k.gatewayState.pairDevice(k.gatewayState.issuePairingTicket(),"ios","fixture") as CloudGatewayState.PairResult.Success
            val accepted=client.post("/v2/work-items") {bearerAuth(pair.token);setBody("""{"requestId":"csv","text":"处理CSV"}""")}
            assertEquals(202,accepted.status.value)
            val id=Json.parseToJsonElement(accepted.bodyAsText()).jsonObject["workItem"]!!.jsonObject.string("id")
            withTimeout(15_000) {while(k.orchestrationStore.getWorkItem(id)?.state?.isTerminal!=true)delay(20)}
            val detail=Json.parseToJsonElement(client.get("/v2/work-items/$id"){bearerAuth(pair.token)}.bodyAsText()).jsonObject
            assertEquals("completed",detail.string("outcome"),detail.toString());assertEquals(7,step)
            assertEquals(401,client.get("/v2/work-items/$id/artifacts").status.value)
            val files=client.get("/v2/work-items/$id/artifacts"){bearerAuth(pair.token)}
            assertEquals(200,files.status.value);assertContains(files.bodyAsText(),"sha256")
            val file=client.get("/v2/work-items/$id/artifacts/download?path=result.json"){bearerAuth(pair.token)}
            assertEquals(200,file.status.value);assertEquals("{\"sum\": 5}",file.bodyAsText())
            assertEquals(400,client.get("/v2/work-items/$id/artifacts/download?path=../secrets.enc.json"){bearerAuth(pair.token)}.status.value)
            assertFalse(k.taskProcesses.active(id))
        }finally{k.router.awaitIdle(includeWorkers=true);k.conversationTagger.closeAndJoin();k.agentRegistry.close();k.orchestrationStore.close();k.supertagStore.close()}
    }
    @Test fun plainRefusalIsBlockedRatherThanCompleted()=testApplication {
        val k=CloudAgentKernel(Files.createTempDirectory("task-blocked").toFile(),CloudModelClient {_,_->UIMessage.assistant("当前无法执行")},masterSecretOverride="task-blocked")
        application {configureCloudGateway(k.gatewayState,agentApi=AgentCentricApi(k))}
        try {
            val pair=k.gatewayState.pairDevice(k.gatewayState.issuePairingTicket(),"ios","fixture") as CloudGatewayState.PairResult.Success
            val r=client.post("/v2/work-items"){bearerAuth(pair.token);setBody("""{"requestId":"blocked","text":"查看状态"}""")}
            val id=Json.parseToJsonElement(r.bodyAsText()).jsonObject["workItem"]!!.jsonObject.string("id")
            withTimeout(5_000){while(k.orchestrationStore.getWorkItem(id)?.state?.isTerminal!=true)delay(20)}
            assertEquals("blocked",AgentCentricApi(k).workItem(id)?.outcome)
        }finally{k.router.awaitIdle(includeWorkers=true);k.conversationTagger.closeAndJoin();k.agentRegistry.close();k.orchestrationStore.close();k.supertagStore.close()}
    }
    private fun JsonObject.string(key:String)=getValue(key).jsonPrimitive.content
}
