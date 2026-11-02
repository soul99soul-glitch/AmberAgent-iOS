package app.amber.cloud

import app.amber.ai.ui.UIMessage
import app.amber.cloud.gateway.*
import app.amber.cloud.orchestration.*
import app.amber.cloud.runtime.*
import kotlinx.coroutines.runBlocking
import java.nio.file.Files
import kotlin.test.*

class DialogueSettlementTest {
    @Test fun acceptedInputMustBeConsumedBeforeTerminalAdmission()=runBlocking {
        val dir=Files.createTempDirectory("dialogue-settlement").toFile()
        val k=CloudAgentKernel(dir,CloudModelClient {_,_->UIMessage.assistant("fixture")},masterSecretOverride="fake-dialogue-test")
        k.orchestrationKernel.autoExecuteWorkersInBackground=false
        try {
            k.gatewayState.pairDevice(k.gatewayState.issuePairingTicket(),"ios","fixture")
            val device=k.gatewayState.loadDevicesStrict().single()
            val item=AgentCentricApi(k).tasks.submit(device,NativeTaskRequest("first","fixture")).workItem
            val accepted=k.nativeDialogue.submit(device,"followup","must consume",kind="followup",workItemId=item.id)
            val record=k.orchestrationStore.getWorkItem(item.id)!!
            val principal=k.orchestrationKernel.workerPrincipalFor(record)
            val report=WorkerSettlementReport(item.id,"completed","old inference result")
            assertEquals(WorkItemState.WORKING,k.orchestrationKernel.reportWorkerSettlement(principal,report).state)
            assertNull(k.orchestrationStore.getWorkItem(item.id)!!.settlementReportPath)
            val inputs=k.orchestrationKernel.workerEvents.prepare(record)
            assertEquals(listOf(accepted.eventId),inputs.map {it.id})
            assertEquals("received",k.nativeDialogue.receipt(device,"followup")!!.state)
            k.orchestrationStore.dialogue.consume(inputs)
            assertEquals(WorkItemState.COMPLETED,k.orchestrationKernel.reportWorkerSettlement(principal,report).state)
            assertEquals("consumed",k.nativeDialogue.receipt(device,"followup")!!.state)
            assertTrue(k.nativeDialogue.submit(device,"followup","must consume",kind="followup",workItemId=item.id).replayed)
            assertFailsWith<IllegalArgumentException> {k.nativeDialogue.submit(device,"new-followup","too late",kind="followup",workItemId=item.id)}
            assertEquals(WorkItemState.COMPLETED,k.orchestrationKernel.cancelWorkItem(CloudPrincipal.OwnerUser(device.id,"app"),item.id).state)
        } finally {
            k.router.awaitIdle(includeWorkers=true);k.conversationTagger.closeAndJoin()
            k.agentRegistry.close();k.orchestrationStore.close();k.supertagStore.close()
            dir.deleteRecursively()
        }
    }
}
