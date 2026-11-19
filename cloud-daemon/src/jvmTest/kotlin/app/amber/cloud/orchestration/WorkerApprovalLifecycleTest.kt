package app.amber.cloud.orchestration

import app.amber.ai.core.MessageRole
import app.amber.ai.ui.ToolApprovalState
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.channel.ChannelApprovalCard
import app.amber.cloud.channel.ChannelKind
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.gateway.CloudGatewayState
import app.amber.cloud.gateway.PendingApprovalDto
import app.amber.cloud.gateway.SessionDto
import app.amber.cloud.gateway.configureCloudGateway
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.runtime.CloudToolDefinition
import app.amber.cloud.runtime.CloudToolRegistry
import app.amber.cloud.runtime.ToolEffect
import app.amber.cloud.security.EnvelopeCredentialVault
import app.amber.core.model.Conversation
import app.amber.core.model.DEFAULT_ASSISTANT_ID
import app.amber.core.storage.conversation.ConversationFile
import app.amber.core.storage.conversation.JsonConversationStorage
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.contentType
import io.ktor.server.testing.testApplication
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlin.uuid.Uuid

class WorkerApprovalLifecycleTest {

    private val testJson = Json { ignoreUnknownKeys = true }

    private fun registerCounterTools(
        registry: CloudToolRegistry,
        sideEffectCounter: AtomicInteger,
        capturedArgs: CopyOnWriteArrayList<JsonObject>,
        readCounter: AtomicInteger = AtomicInteger(0),
    ) {
        registry.register(
            CloudToolDefinition(
                name = "test_side_effect_counter",
                description = "Test-only SIDE_EFFECT counter tool",
                highRisk = false,
                effect = ToolEffect.SIDE_EFFECT,
                taskHandler = { args, _ ->
                    capturedArgs.add(args)
                    val count = sideEffectCounter.incrementAndGet()
                    buildJsonObject {
                        put("ok", true)
                        put("count", count)
                        put("tokenEcho", args["apiKey"]?.jsonPrimitive?.content.orEmpty())
                    }
                },
            )
        )
        registry.register(
            CloudToolDefinition(
                name = "test_task_read",
                description = "Test-only TASK_LOCAL read counter tool",
                highRisk = false,
                effect = ToolEffect.TASK_LOCAL,
                taskHandler = { _, _ ->
                    val count = readCounter.incrementAndGet()
                    buildJsonObject {
                        put("ok", true)
                        put("readCount", count)
                    }
                },
            )
        )
    }

    private suspend fun submitSingleWorker(
        kernel: DefaultCloudOrchestrationKernel,
        requestId: String,
        title: String = "审批测试任务",
        nowMs: Long = System.currentTimeMillis(),
    ): CloudWorkItemRecord {
        val owner = CloudPrincipal.OwnerUser("owner-1", "app", trustedForegroundApp = true)
        val msgId = "msg-$requestId"
        kernel.store.recordSourceMessage(
            SourceMessageProvenance(
                sessionId = PRIMARY_CONVERSATION_ID.toString(),
                messageId = msgId,
                senderId = "owner-1",
                channelId = "app",
                senderRole = SenderRole.OWNER,
                origin = MessageProvenanceOrigin.OWNER_HUMAN,
                rawTextHash = OrchestrationHash.sha256Hex(title),
                createdAtEpochMs = nowMs,
            ),
            title,
        )
        val batch = kernel.submitWorkBatch(
            principal = owner,
            requestId = requestId,
            contextMessageIds = listOf(msgId),
            items = listOf(
                WorkItemSubmissionSpec(
                    taskKey = "task-$requestId",
                    title = title,
                    brief = "执行测试工具并调用 task_finish",
                    targetNode = ExecutionTargetNode.CloudSubagent("main", "worker"),
                )
            ),
            nowEpochMs = nowMs,
        )
        return batch.items.single()
    }

    private suspend fun awaitUntilCondition(timeoutMs: Long = 5_000L, predicate: () -> Boolean) {
        withTimeout(timeoutMs) {
            while (!predicate()) {
                delay(20L)
            }
        }
    }

    private fun assistantToolCallMessage(
        toolCallId: String,
        toolName: String,
        inputJson: String,
        extraTool: UIMessagePart.Tool? = null,
    ): UIMessage = UIMessage(
        role = MessageRole.ASSISTANT,
        parts = buildList {
            add(
                UIMessagePart.Tool(
                    toolCallId = toolCallId,
                    toolName = toolName,
                    input = inputJson,
                )
            )
            if (extraTool != null) add(extraTool)
        },
    )

    private fun assistantTaskFinish(toolCallId: String, summary: String): UIMessage = UIMessage(
        role = MessageRole.ASSISTANT,
        parts = listOf(
            UIMessagePart.Tool(
                toolCallId = toolCallId,
                toolName = "task_finish",
                input = """{"outcome":"completed","summary":${testJson.encodeToString(JsonPrimitive.serializer(), JsonPrimitive(summary))}}""",
            )
        ),
    )

    @Test
    fun production_workspace_writers_require_approval_even_after_task_registration() = runBlocking {
        val dir = Files.createTempDirectory("codex-workspace-gate").toFile()
        val kernel = CloudAgentKernel(dataDir = dir, modelClient = CloudModelClient { _, _ -> UIMessage.assistant("unused") },
            masterSecretOverride = "test-only-key")
        try {
            for (name in listOf("workspace_file_write", "workspace_file_edit")) {
                assertEquals(ToolEffect.SIDE_EFFECT, kernel.toolRegistry.get(name)?.effect, name)
                assertTrue(kernel.toolRegistry.isWorkerApprovalTool(name), name)
                assertFalse(kernel.toolRegistry.declaredTools(app.amber.cloud.runtime.ExecutionScope.SUBAGENT).any { it.name == name })
                assertTrue(kernel.toolRegistry.declaredTools(app.amber.cloud.runtime.ExecutionScope.SUBAGENT,
                    includeWorkerApprovalTools = true).single { it.name == name }.needsApproval)
                val rejected = kernel.toolRegistry.executeGate(name, buildJsonObject { put("path", "proof.txt"); put("content", "blocked") },
                    app.amber.cloud.runtime.ExecutionScope.SUBAGENT,
                    context = app.amber.cloud.tasks.TaskCallContext("wi-gate", "amber", "session", setOf(name)))
                assertEquals(false, rejected.jsonObject["ok"]?.jsonPrimitive?.content?.toBoolean())
            }
        } finally {
            kernel.stopProactiveLoop()
            kernel.nativeDialogue.closeAndJoin()
            kernel.conversationTagger.closeAndJoin()
            kernel.agentRegistry.close()
            kernel.orchestrationStore.close()
            kernel.supertagStore.close()
            dir.deleteRecursively()
        }
    }

    @Test
    fun production_workspace_write_waits_then_executes_once_after_approval() = runBlocking {
        val dir = Files.createTempDirectory("codex-workspace-approval").toFile()
        val step = AtomicInteger()
        val kernel = CloudAgentKernel(dataDir = dir, modelClient = CloudModelClient { _, _ ->
            if (step.incrementAndGet() == 1) assistantToolCallMessage("write-real", "workspace_file_write", """{"path":"proof.txt","content":"approved"}""")
            else assistantTaskFinish("finish-real", "done")
        }, masterSecretOverride = "test-only-key", workerApprovals = true)
        try {
            val item = submitSingleWorker(kernel.orchestrationKernel, "codex-real-write")
            awaitUntilCondition { kernel.orchestrationStore.getWorkItem(item.workItemId)?.state in setOf(WorkItemState.WAITING, WorkItemState.COMPLETED) }
            assertEquals(WorkItemState.WAITING, kernel.orchestrationStore.getWorkItem(item.workItemId)?.state)
            val file = File(kernel.taskWorkspace.directory(item.workItemId), "proof.txt")
            assertFalse(file.exists())
            val approval = kernel.orchestrationStore.listWorkerApprovals(item.workItemId).single()
            val key = kernel.orchestrationKernel.v2ApprovalSessionKey(item.workItemId, approval.id)
            // WAITING is durable before the gateway card is published.
            awaitUntilCondition { kernel.gatewayState.getSession(key)?.pendingApproval != null }
            val accepted = kernel.gatewayState.processDecision(key, "write-real", true, "test-app", true)
            assertEquals(200, accepted.status)
            awaitUntilCondition { kernel.orchestrationStore.getWorkItem(item.workItemId)?.state == WorkItemState.COMPLETED }
            assertEquals("approved", file.readText())
            assertEquals(409, kernel.gatewayState.processDecision(key, "write-real", true, "test-app", true).status)
            assertEquals("done", kernel.orchestrationStore.getWorkerApproval(approval.id)?.state)
        } finally {
            kernel.stopProactiveLoop()
            kernel.nativeDialogue.closeAndJoin()
            kernel.conversationTagger.closeAndJoin()
            kernel.agentRegistry.close()
            kernel.orchestrationStore.close()
            kernel.supertagStore.close()
            dir.deleteRecursively()
        }
    }

    @Test
    fun redeliver_waiting_worker_expires_old_approval_and_wipes_vault() = runBlocking {
        val dir = Files.createTempDirectory("codex-redeliver-approval").toFile()
        val step = AtomicInteger()
        val effects = AtomicInteger()
        val kernel = CloudAgentKernel(dataDir = dir, modelClient = CloudModelClient { _, _ ->
            if (step.incrementAndGet() == 1) assistantToolCallMessage("old-approval", "test_side_effect_counter", """{"apiKey":"synthetic-secret"}""")
            else assistantTaskFinish("finish-redeliver", "done")
        }, masterSecretOverride = "test-only-key", workerApprovals = true)
        registerCounterTools(kernel.toolRegistry, effects, CopyOnWriteArrayList())
        try {
            val item = submitSingleWorker(kernel.orchestrationKernel, "codex-redeliver")
            awaitUntilCondition { kernel.orchestrationStore.getWorkItem(item.workItemId)?.state == WorkItemState.WAITING }
            val approval = kernel.orchestrationStore.listWorkerApprovals(item.workItemId).single()
            val key = kernel.orchestrationKernel.v2ApprovalSessionKey(item.workItemId, approval.id)
            awaitUntilCondition { kernel.gatewayState.getSession(key)?.pendingApproval != null }
            kernel.orchestrationKernel.redeliverWorker(item.workItemId, "test")
            awaitUntilCondition { kernel.orchestrationStore.getWorkItem(item.workItemId)?.state == WorkItemState.COMPLETED }
            assertEquals("expired", kernel.orchestrationStore.getWorkerApproval(approval.id)?.state)
            assertFalse(kernel.vault.hasPendingToolArgs("old-approval"))
            assertEquals(409, kernel.gatewayState.processDecision(key, "old-approval", true, "test-app", true).status)
            assertEquals(0, effects.get())
            val conv = kernel.conversationStorage.loadConversation(Uuid.parse(item.workerSessionId!!))!!
            val part = conv.messageNodes.flatMap { it.currentMessage.parts }.filterIsInstance<UIMessagePart.Tool>().single { it.toolCallId == "old-approval" }
            assertTrue(part.output.toString().contains("cancelled"))
        } finally {
            kernel.stopProactiveLoop()
            kernel.nativeDialogue.closeAndJoin()
            kernel.conversationTagger.closeAndJoin()
            kernel.agentRegistry.close()
            kernel.orchestrationStore.close()
            kernel.supertagStore.close()
            dir.deleteRecursively()
        }
    }

    @Test
    fun d1_d2_d4_d5_side_effect_approval_redaction_im_403_trusted_http_200_and_replay_409() = runBlocking {
        val dir = Files.createTempDirectory("amber-worker-approval-d1-d5").toFile()
        try {
            val sideEffectCounter = AtomicInteger(0)
            val capturedArgs = CopyOnWriteArrayList<JsonObject>()
            val secretLiteral = "sk-live-worker-approval-secret-99887766"
            val step = AtomicInteger(0)

            val kernel = CloudAgentKernel(
                dataDir = dir,
                modelClient = CloudModelClient { _, _ ->
                    when (step.incrementAndGet()) {
                        1 -> assistantToolCallMessage(
                            toolCallId = "call-se-1",
                            toolName = "test_side_effect_counter",
                            inputJson = """{"apiKey":"$secretLiteral","action":"deploy"}""",
                        )
                        else -> assistantTaskFinish("call-fin-1", "写操作已执行完成")
                    }
                },
                masterSecretOverride = "worker-approval-master-key",
                workerApprovals = true,
            )
            registerCounterTools(kernel.toolRegistry, sideEffectCounter, capturedArgs)

            val cards = CopyOnWriteArrayList<Pair<CloudWorkItemRecord, ChannelApprovalCard>>()
            kernel.orchestrationKernel.onWorkerApprovalRequested = { item, card ->
                cards.add(item to card)
            }

            val item = submitSingleWorker(kernel.orchestrationKernel, "req-d1-d5")

            // D1: Worker enters WAITING, keeps slotHeld=true, inserts pending row, emits process_event, redacts everywhere.
            awaitUntilCondition {
                kernel.orchestrationStore.getWorkItem(item.workItemId)?.state == WorkItemState.WAITING &&
                    cards.isNotEmpty()
            }

            val waitingItem = kernel.orchestrationStore.getWorkItem(item.workItemId)!!
            assertEquals(WorkItemState.WAITING, waitingItem.state)
            assertTrue(waitingItem.slotHeld, "WAITING must keep slotHeld=true per frozen contract")
            assertEquals(0, sideEffectCounter.get(), "SIDE_EFFECT must not run while WAITING")

            val approvals = kernel.orchestrationStore.listWorkerApprovals(item.workItemId)
            assertEquals(1, approvals.size)
            val approval = approvals.single()
            assertEquals("pending", approval.state)
            assertEquals("test_side_effect_counter", approval.toolName)
            assertFalse(approval.redactedArgs.contains(secretLiteral))

            val gwSessionKey = kernel.orchestrationKernel.v2ApprovalSessionKey(item.workItemId, approval.id)
            val gwSession = kernel.gatewayState.getSession(gwSessionKey)
            assertNotNull(gwSession)
            assertEquals("waiting", gwSession.state)
            assertEquals(true, gwSession.pendingApproval?.highRisk)
            assertFalse(gwSession.pendingApproval?.detail.orEmpty().contains(secretLiteral))

            val dialoguePage = kernel.orchestrationStore.dialogue.page(0, 100)
            val approvalEvent = dialoguePage.items.firstOrNull { it.id == "approval:${approval.id}" }
            assertNotNull(approvalEvent)
            assertEquals("process_event", approvalEvent.kind)

            assertTrue(kernel.vault.hasPendingToolArgs("call-se-1"))

            // Raw secret must NEVER appear in conversation JSON, gateway sessions, or SQLite files
            val convRaw = File(dir, "conversations/${item.workerSessionId!!}.json").readText()
            assertFalse(convRaw.contains(secretLiteral), "Conversation JSON must redact raw secret")
            assertFalse(kernel.gatewayState.sessionsFile.readText().contains(secretLiteral), "sessions.json must redact raw secret")
            val orchDbRaw = File(dir, "orchestration.db").readText(Charsets.ISO_8859_1)
            assertFalse(orchDbRaw.contains(secretLiteral), "SQLite orchestration.db must not contain raw secret")

            // D2: IM channel allow=true -> 403 rejected_high_risk, stays pending
            val imApprove = kernel.handleChannelDecision(
                channel = ChannelKind.TELEGRAM,
                senderId = "owner-tg",
                sessionKey = "",
                toolCallId = "call-se-1",
                allow = true,
            )
            assertEquals(403, imApprove.httpStatus)
            assertEquals("rejected_high_risk", imApprove.outcome)
            assertEquals("pending", kernel.orchestrationStore.getWorkerApproval(approval.id)?.state)
            assertEquals(0, sideEffectCounter.get())

            // D5 + D4 via real Ktor gateway server
            testApplication {
                application {
                    configureCloudGateway(kernel.gatewayState)
                }
                val pairSecret = kernel.gatewayState.issuePairingTicket()
                val pairResp = client.post("/v1/pair") {
                    contentType(ContentType.Application.Json)
                    setBody("""{"secret":"$pairSecret","platform":"ios","deviceName":"Owner iPhone"}""")
                }
                assertEquals(200, pairResp.status.value)
                val token = testJson.parseToJsonElement(pairResp.bodyAsText()).jsonObject["token"]!!.jsonPrimitive.content

                // D5: Missing trusted foreground / biometric headers -> 403
                val untrustedResp = client.post("/v1/amber/decision") {
                    header(HttpHeaders.Authorization, "Bearer $token")
                    contentType(ContentType.Application.Json)
                    setBody("""{"sessionKey":"$gwSessionKey","toolCallId":"call-se-1","allow":true}""")
                }
                assertEquals(403, untrustedResp.status.value)
                assertEquals("pending", kernel.orchestrationStore.getWorkerApproval(approval.id)?.state)
                assertEquals(0, sideEffectCounter.get())

                // D4: Trusted unlocked foreground App + biometric headers -> 200 & executes ONCE with raw unredacted args
                val trustedResp = client.post("/v1/amber/decision") {
                    header(HttpHeaders.Authorization, "Bearer $token")
                    header("X-Amber-Trusted-Foreground", "true")
                    header("X-Amber-Biometric-Verified", "true")
                    header("X-Amber-Surface", "foreground")
                    contentType(ContentType.Application.Json)
                    setBody("""{"sessionKey":"$gwSessionKey","toolCallId":"call-se-1","allow":true}""")
                }
                assertEquals(200, trustedResp.status.value)

                awaitUntilCondition {
                    kernel.orchestrationStore.getWorkItem(item.workItemId)?.state == WorkItemState.COMPLETED
                }

                assertEquals(1, sideEffectCounter.get())
                assertEquals(secretLiteral, capturedArgs.single()["apiKey"]?.jsonPrimitive?.content)
                assertFalse(kernel.vault.hasPendingToolArgs("call-se-1"), "Vault must wipe stashed args after execution")
                assertEquals("done", kernel.orchestrationStore.getWorkerApproval(approval.id)?.state)

                val updatedConv = kernel.conversationStorage.loadConversation(Uuid.parse(item.workerSessionId!!))!!
                val toolPart = updatedConv.messageNodes.flatMap { it.currentMessage.parts }
                    .filterIsInstance<UIMessagePart.Tool>()
                    .first { it.toolCallId == "call-se-1" }
                assertEquals(ToolApprovalState.Approved, toolPart.approvalState)

                // Repeat call -> 409 stale, no second execution
                val repeatResp = client.post("/v1/amber/decision") {
                    header(HttpHeaders.Authorization, "Bearer $token")
                    header("X-Amber-Trusted-Foreground", "true")
                    header("X-Amber-Biometric-Verified", "true")
                    header("X-Amber-Surface", "foreground")
                    contentType(ContentType.Application.Json)
                    setBody("""{"sessionKey":"$gwSessionKey","toolCallId":"call-se-1","allow":true}""")
                }
                assertEquals(409, repeatResp.status.value)
                assertEquals(1, sideEffectCounter.get())
            }
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun d3_and_d9_im_deny_and_batch_barrier_defers_subsequent_tools() = runBlocking {
        val dir = Files.createTempDirectory("amber-worker-approval-d3-d9").toFile()
        try {
            val sideEffectCounter = AtomicInteger(0)
            val readCounter = AtomicInteger(0)
            val capturedArgs = CopyOnWriteArrayList<JsonObject>()
            val step = AtomicInteger(0)

            val kernel = CloudAgentKernel(
                dataDir = dir,
                modelClient = CloudModelClient { _, _ ->
                    when (step.incrementAndGet()) {
                        1 -> assistantToolCallMessage(
                            toolCallId = "call-se-deny",
                            toolName = "test_side_effect_counter",
                            inputJson = """{"apiKey":"sk-deny-secret-123"}""",
                            extraTool = UIMessagePart.Tool(
                                toolCallId = "call-read-after",
                                toolName = "test_task_read",
                                input = """{}""",
                            ),
                        )
                        else -> assistantTaskFinish("call-fin-deny", "写操作已被拒绝，任务结束")
                    }
                },
                masterSecretOverride = "worker-approval-d3-d9-key",
                workerApprovals = true,
            )
            registerCounterTools(kernel.toolRegistry, sideEffectCounter, capturedArgs, readCounter)

            val item = submitSingleWorker(kernel.orchestrationKernel, "req-d3-d9")
            awaitUntilCondition {
                kernel.orchestrationStore.getWorkItem(item.workItemId)?.state == WorkItemState.WAITING
            }

            // D9: Batch barrier — second tool MUST NOT execute while first tool is WAITING
            assertEquals(0, sideEffectCounter.get())
            assertEquals(0, readCounter.get(), "Subsequent tool in same assistant turn must be deferred")
            val convWhileWaiting = kernel.conversationStorage.loadConversation(Uuid.parse(item.workerSessionId!!))!!
            val deferredPart = convWhileWaiting.messageNodes.flatMap { it.currentMessage.parts }
                .filterIsInstance<UIMessagePart.Tool>()
                .first { it.toolCallId == "call-read-after" }
            val deferredText = deferredPart.output.filterIsInstance<UIMessagePart.Text>().joinToString("") { it.text }
            assertTrue(deferredText.contains("deferred_until_approval"), "Expected deferred_until_approval, got: $deferredText")

            val approval = kernel.orchestrationStore.listWorkerApprovals(item.workItemId).single()
            // D3: IM allow=false -> 200, state=denied, vault wiped, Worker resumes and completes without running tool
            val imDeny = kernel.handleChannelDecision(
                channel = ChannelKind.TELEGRAM,
                senderId = "owner-tg",
                sessionKey = kernel.orchestrationKernel.v2ApprovalSessionKey(item.workItemId, approval.id),
                toolCallId = "call-se-deny",
                allow = false,
            )
            assertEquals(200, imDeny.httpStatus)
            assertEquals("denied", imDeny.outcome)

            awaitUntilCondition {
                kernel.orchestrationStore.getWorkItem(item.workItemId)?.state == WorkItemState.COMPLETED
            }
            assertEquals(0, sideEffectCounter.get())
            assertEquals(0, readCounter.get())
            assertFalse(kernel.vault.hasPendingToolArgs("call-se-deny"))
            val decided = kernel.orchestrationStore.getWorkerApproval(approval.id)!!
            assertEquals("denied", decided.state)
            assertEquals("telegram:owner-tg", decided.actor)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun d6_cancel_waiting_work_item_expires_approval_wipes_vault_and_returns_409() = runBlocking {
        val dir = Files.createTempDirectory("amber-worker-approval-d6").toFile()
        try {
            val sideEffectCounter = AtomicInteger(0)
            val capturedArgs = CopyOnWriteArrayList<JsonObject>()
            val kernel = CloudAgentKernel(
                dataDir = dir,
                modelClient = CloudModelClient { _, _ ->
                    assistantToolCallMessage(
                        toolCallId = "call-se-cancel",
                        toolName = "test_side_effect_counter",
                        inputJson = """{"apiKey":"sk-cancel-secret-456"}""",
                    )
                },
                masterSecretOverride = "worker-approval-d6-key",
                workerApprovals = true,
            )
            registerCounterTools(kernel.toolRegistry, sideEffectCounter, capturedArgs)

            val item = submitSingleWorker(kernel.orchestrationKernel, "req-d6")
            awaitUntilCondition {
                kernel.orchestrationStore.getWorkItem(item.workItemId)?.state == WorkItemState.WAITING
            }
            val approval = kernel.orchestrationStore.listWorkerApprovals(item.workItemId).single()
            val gwKey = kernel.orchestrationKernel.v2ApprovalSessionKey(item.workItemId, approval.id)
            assertTrue(kernel.vault.hasPendingToolArgs("call-se-cancel"))

            val coord = CloudPrincipal.CloudCoordinator("coord-1", "session-1", "turn-cancel")
            val cancelled = kernel.orchestrationKernel.cancelWorkItem(coord, item.workItemId)
            assertEquals(WorkItemState.CANCELLED, cancelled.state)
            assertFalse(cancelled.slotHeld)
            assertEquals("expired", kernel.orchestrationStore.getWorkerApproval(approval.id)?.state)
            assertFalse(kernel.vault.hasPendingToolArgs("call-se-cancel"))
            assertEquals("completed", kernel.gatewayState.getSession(gwKey)?.state)

            // Late approval attempt after cancellation must return 409 stale
            val lateDecision = kernel.gatewayState.processDecision(
                sessionKey = gwKey,
                toolCallId = "call-se-cancel",
                allow = true,
                actorDevice = "ios-app",
                trustedForegroundSource = true,
            )
            assertEquals(409, lateDecision.status)
            assertEquals("stale", lateDecision.outcome)
            assertEquals(0, sideEffectCounter.get())
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun d7_restart_while_waiting_marks_expired_relaunches_and_never_auto_executes() = runBlocking {
        val dir = Files.createTempDirectory("amber-worker-approval-d7").toFile()
        try {
            val sideEffectCounter = AtomicInteger(0)
            val capturedArgs = CopyOnWriteArrayList<JsonObject>()
            val kernel1 = CloudAgentKernel(
                dataDir = dir,
                modelClient = CloudModelClient { _, _ ->
                    assistantToolCallMessage(
                        toolCallId = "call-se-restart",
                        toolName = "test_side_effect_counter",
                        inputJson = """{"apiKey":"sk-restart-secret"}""",
                    )
                },
                masterSecretOverride = "worker-approval-d7-key",
                workerApprovals = true,
            )
            registerCounterTools(kernel1.toolRegistry, sideEffectCounter, capturedArgs)
            val item = submitSingleWorker(kernel1.orchestrationKernel, "req-d7")
            awaitUntilCondition {
                kernel1.orchestrationStore.getWorkItem(item.workItemId)?.state == WorkItemState.WAITING
            }
            val approval = kernel1.orchestrationStore.listWorkerApprovals(item.workItemId).single()
            kernel1.orchestrationKernel.shutdownForRestart()
            kernel1.nativeDialogue.closeAndJoin()
            kernel1.conversationTagger.closeAndJoin()
            kernel1.agentRegistry.close()
            kernel1.orchestrationStore.close()
            kernel1.supertagStore.close()

            val seenMessages = CopyOnWriteArrayList<String>()
            val kernel2 = CloudAgentKernel(
                dataDir = dir,
                modelClient = CloudModelClient { msgs, _ ->
                    seenMessages.addAll(msgs.map { it.toText() })
                    assistantTaskFinish("call-fin-d7", "重启后未自动重放，已向主人汇报")
                },
                masterSecretOverride = "worker-approval-d7-key",
                workerApprovals = true,
            )
            registerCounterTools(kernel2.toolRegistry, sideEffectCounter, capturedArgs)

            kernel2.orchestrationKernel.recoverAfterRestart()
            awaitUntilCondition {
                kernel2.orchestrationStore.getWorkItem(item.workItemId)?.state == WorkItemState.COMPLETED
            }
            assertEquals("expired", kernel2.orchestrationStore.getWorkerApproval(approval.id)?.state)
            assertEquals(0, sideEffectCounter.get(), "Unapproved tool must NEVER auto-execute across restart")
            assertTrue(seenMessages.any { it.contains("expired") })
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun d8_restart_while_executing_marks_outcome_unknown_and_never_replays() = runBlocking {
        val dir = Files.createTempDirectory("amber-worker-approval-d8").toFile()
        try {
            val sideEffectCounter = AtomicInteger(0)
            val capturedArgs = CopyOnWriteArrayList<JsonObject>()
            val convStorage = JsonConversationStorage(ConversationFile(File(dir, "conversations").apply { mkdirs() }.absolutePath))
            val store1 = CloudOrchestrationStore(dir)
            val sessionId = Uuid.random().toString()
            val nowMs = 1_700_000_000_000L
            convStorage.saveConversation(
                Conversation(
                    id = Uuid.parse(sessionId),
                    assistantId = DEFAULT_ASSISTANT_ID,
                    title = "crashed-exec",
                    messageNodes = emptyList(),
                )
            )
            store1.upsertWorkItem(
                CloudWorkItemRecord(
                    workItemId = "wi-exec-crash",
                    batchId = "batch-exec-crash",
                    scopeKey = "main",
                    taskKey = "exec-crash",
                    taskFingerprint = OrchestrationHash.sha256Hex("exec-crash"),
                    title = "执行中崩溃测试",
                    brief = "test",
                    targetNode = ExecutionTargetNode.CloudSubagent("main", "worker"),
                    state = WorkItemState.WORKING,
                    slotHeld = true,
                    workerSessionId = sessionId,
                    lastActivityAtMs = nowMs,
                    sourceProvenance = emptyList(),
                    createdAtMs = nowMs,
                    updatedAtMs = nowMs,
                )
            )
            // Simulate side effect already ran once before crash while approval row was in 'executing'
            sideEffectCounter.incrementAndGet()
            store1.insertWorkerApproval(
                WorkerApprovalRecord(
                    id = "apr-exec-1",
                    workItemId = "wi-exec-crash",
                    toolCallId = "call-se-exec",
                    toolName = "test_side_effect_counter",
                    argsDigest = OrchestrationHash.sha256Hex("{}"),
                    redactedArgs = "{}",
                    state = "executing",
                    createdMs = nowMs,
                    decidedMs = nowMs,
                    actor = "ios-app",
                )
            )
            store1.close()

            val seenMessages = CopyOnWriteArrayList<String>()
            val kernel2 = CloudAgentKernel(
                dataDir = dir,
                modelClient = CloudModelClient { msgs, _ ->
                    seenMessages.addAll(msgs.map { it.toText() })
                    assistantTaskFinish("call-fin-d8", "检测到中断时正在执行，未重放")
                },
                masterSecretOverride = "worker-approval-d8-key",
                workerApprovals = true,
            )
            registerCounterTools(kernel2.toolRegistry, sideEffectCounter, capturedArgs)

            kernel2.orchestrationKernel.recoverAfterRestart(nowMs + 5_000L)
            awaitUntilCondition {
                kernel2.orchestrationStore.getWorkItem("wi-exec-crash")?.state == WorkItemState.COMPLETED
            }
            assertEquals("outcome_unknown", kernel2.orchestrationStore.getWorkerApproval("apr-exec-1")?.state)
            assertEquals(1, sideEffectCounter.get(), "In-flight executing tool must NOT be auto-replayed after crash")
            assertTrue(seenMessages.any { it.contains("outcome_unknown") })
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun d9_and_d10_flag_off_strips_write_tools_and_blocks_fabricated_calls() = runBlocking {
        val dir = Files.createTempDirectory("amber-worker-flag-off").toFile()
        try {
            val sideEffectCounter = AtomicInteger(0)
            val capturedArgs = CopyOnWriteArrayList<JsonObject>()
            val step = AtomicInteger(0)
            val advertisedToolNames = CopyOnWriteArrayList<String>()

            val kernel = CloudAgentKernel(
                dataDir = dir,
                modelClient = CloudModelClient { _, tools ->
                    if (step.get() == 0) {
                        advertisedToolNames.addAll(tools.map { it.name })
                    }
                    when (step.incrementAndGet()) {
                        1 -> assistantToolCallMessage(
                            toolCallId = "call-forged-se",
                            toolName = "test_side_effect_counter",
                            inputJson = """{"apiKey":"sk-forged-secret"}""",
                        )
                        else -> assistantTaskFinish("call-fin-flag-off", "未授权写工具被门控拦截")
                    }
                },
                masterSecretOverride = "worker-flag-off-key",
                workerApprovals = false, // default off!
            )
            registerCounterTools(kernel.toolRegistry, sideEffectCounter, capturedArgs)

            val item = submitSingleWorker(kernel.orchestrationKernel, "req-flag-off")
            awaitUntilCondition {
                kernel.orchestrationStore.getWorkItem(item.workItemId)?.state == WorkItemState.COMPLETED
            }

            assertFalse("test_side_effect_counter" in advertisedToolNames, "Flag off must strip SIDE_EFFECT tools")
            assertFalse("memory_write" in advertisedToolNames, "Flag off must strip memory_write")
            assertEquals(0, sideEffectCounter.get(), "Fabricated SIDE_EFFECT call must be rejected by gate")
            assertTrue(kernel.orchestrationStore.listWorkerApprovals(item.workItemId).isEmpty())
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun approval_ttl_expiry_on_health_tick_clears_pending_wipes_vault_and_returns_409() = runBlocking {
        val dir = Files.createTempDirectory("amber-worker-ttl").toFile()
        try {
            val clock = AtomicLong(1_700_000_000_000L)
            val sideEffectCounter = AtomicInteger(0)
            val capturedArgs = CopyOnWriteArrayList<JsonObject>()
            val step = AtomicInteger(0)

            val store = CloudOrchestrationStore(dir)
            val convStorage = JsonConversationStorage(ConversationFile(File(dir, "conversations").apply { mkdirs() }.absolutePath))
            val registry = CloudToolRegistry()
            registry.register(
                CloudToolDefinition(
                    name = "task_finish",
                    description = "finish",
                    highRisk = false,
                    effect = ToolEffect.TASK_LOCAL,
                    taskHandler = { args, _ ->
                        buildJsonObject {
                            put("ok", true)
                            put("outcome", args["outcome"]?.jsonPrimitive?.content ?: "completed")
                            put("summary", args["summary"]?.jsonPrimitive?.content ?: "done")
                        }
                    },
                )
            )
            registerCounterTools(registry, sideEffectCounter, capturedArgs)
            val vault = EnvelopeCredentialVault(File(dir, "secrets.enc.json"), masterSecretOverride = "ttl-key")
            val gatewayState = CloudGatewayState(dir)

            val okernel = DefaultCloudOrchestrationKernel(
                config = OrchestrationConfig(workerApprovals = true, workerApprovalTtlMs = 30 * 60_000L),
                store = store,
                conversationStorage = convStorage,
                toolRegistry = registry,
                clockMs = clock::get,
                autoExecuteWorkersInBackground = true,
                vault = vault,
                gatewayState = gatewayState,
            )
            gatewayState.registerDecisionListener { sessionKey, toolCallId, allow ->
                okernel.handleV2GatewayDecision(sessionKey, toolCallId, allow)
            }
            val runner = ModelWorkerTurnRunner(
                kernel = okernel,
                modelClient = CloudModelClient { _, _ ->
                    when (step.incrementAndGet()) {
                        1 -> assistantToolCallMessage(
                            toolCallId = "call-se-ttl",
                            toolName = "test_side_effect_counter",
                            inputJson = """{"apiKey":"sk-ttl-secret"}""",
                        )
                        else -> assistantTaskFinish("call-fin-ttl", "审批超时已过期，任务收口")
                    }
                },
                toolRegistry = registry,
            )
            okernel.workerTurnRunner = { wi, p -> runner.run(wi, p) }

            val item = submitSingleWorker(okernel, "req-ttl", nowMs = clock.get())
            awaitUntilCondition {
                store.getWorkItem(item.workItemId)?.state == WorkItemState.WAITING
            }
            val approval = store.listWorkerApprovals(item.workItemId).single()
            assertTrue(vault.hasPendingToolArgs("call-se-ttl"))

            // Advance FakeClock past 30m TTL and run deterministic health monitor tick
            clock.addAndGet(30 * 60_000L + 1_000L)
            okernel.runDeterministicHealthTick(clock.get())

            awaitUntilCondition {
                store.getWorkItem(item.workItemId)?.state == WorkItemState.COMPLETED
            }
            assertEquals("expired", store.getWorkerApproval(approval.id)?.state)
            assertFalse(vault.hasPendingToolArgs("call-se-ttl"))
            assertEquals(0, sideEffectCounter.get())

            val late = gatewayState.processDecision(
                sessionKey = okernel.v2ApprovalSessionKey(item.workItemId, approval.id),
                toolCallId = "call-se-ttl",
                allow = true,
                actorDevice = "ios-app",
                trustedForegroundSource = true,
            )
            assertEquals(409, late.status)
            assertEquals("stale", late.outcome)
        } finally {
            dir.deleteRecursively()
        }
    }
}
