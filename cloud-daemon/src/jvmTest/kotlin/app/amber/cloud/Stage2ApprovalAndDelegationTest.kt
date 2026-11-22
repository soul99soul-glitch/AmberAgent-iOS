package app.amber.cloud

import app.amber.ai.core.MessageRole
import app.amber.ai.core.Tool
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.channel.ChannelKind
import app.amber.cloud.channel.ConversationScope
import app.amber.cloud.channel.InboundMessage
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.gateway.AgentCentricApi
import app.amber.cloud.gateway.PendingApprovalDto
import app.amber.cloud.gateway.PublicWorkDetail
import app.amber.cloud.gateway.configureCloudGateway
import app.amber.cloud.gateway.configureDialogueRoutes
import app.amber.cloud.orchestration.DialogueEventKinds
import app.amber.cloud.orchestration.OrchestrationHash
import app.amber.cloud.orchestration.DialoguePage
import app.amber.cloud.orchestration.DialogueReceipt
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.runtime.ToolRiskLevel
import app.amber.cloud.runtime.ToolRiskPolicy
import io.ktor.client.request.bearerAuth
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.server.testing.testApplication
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Test
import java.io.File
import java.nio.file.Files
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class Stage2ApprovalAndDelegationTest {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private fun tempDir(prefix: String): File =
        Files.createTempDirectory(prefix).toFile().apply { deleteOnExit() }

    private fun fakeModel(handler: suspend (List<UIMessage>, List<Tool>) -> UIMessage): CloudModelClient =
        object : CloudModelClient {
            override suspend fun generateReply(messages: List<UIMessage>, tools: List<Tool>): UIMessage =
                handler(messages, tools)
        }

    @Test
    fun staticRiskTableClassifiesL1L2L3AndRedactsTruncatesPreviews() {
        val dir = tempDir("stage2-risk-")
        val kernel = CloudAgentKernel(
            dataDir = dir,
            modelClient = fakeModel { _, _ -> UIMessage.assistant("ok") },
            masterSecretOverride = "stage2-risk-master",
        )
        // L1: read-only probes
        assertEquals(ToolRiskLevel.L1, kernel.toolRegistry.riskLevel("history_search"))
        assertEquals(ToolRiskLevel.L1, kernel.toolRegistry.riskLevel("workspace_file_read"))
        assertEquals(ToolRiskLevel.L1, kernel.toolRegistry.riskLevel("host_info"))
        assertEquals(ToolRiskLevel.L1, kernel.toolRegistry.riskLevel("device_context_read"))

        // L2: reversible writes
        assertEquals(ToolRiskLevel.L2, kernel.toolRegistry.riskLevel("workspace_file_write"))
        assertEquals(ToolRiskLevel.L2, kernel.toolRegistry.riskLevel("workspace_file_edit"))
        assertEquals(ToolRiskLevel.L2, kernel.toolRegistry.riskLevel("memory_write"))
        val l2Preview = kernel.toolRegistry.approvalPreview(
            toolName = "workspace_file_edit",
            args = buildJsonObject {
                put("path", "docs/draft.md")
                put("old", "第二条：很长的一段原文内容")
                put("replacement", "第二条：精简版")
            },
            targetDevice = "mac-studio-1",
        )
        assertEquals("L2", l2Preview.riskLevel)
        assertFalse(l2Preview.requiresLocalApproval)
        assertEquals("mac-studio-1", l2Preview.targetDevice)
        assertEquals("workspace_file_edit: docs/draft.md", l2Preview.targetSummary)
        assertTrue(l2Preview.diffPreview.orEmpty().contains("- 第二条"))
        assertTrue(l2Preview.diffPreview.orEmpty().contains("+ 第二条：精简版"))
        val l2Notice = ToolRiskPolicy.reversibleWriteNotification(
            "workspace_file_write",
            buildJsonObject { put("path", "docs/draft.md") },
        )
        assertTrue(l2Notice.contains("L2") && l2Notice.contains("撤回"))

        // L3: irreversible / external / high-risk & unknown fail-closed
        assertEquals(ToolRiskLevel.L3, kernel.toolRegistry.riskLevel("terminal_exec"))
        assertEquals(ToolRiskLevel.L3, kernel.toolRegistry.riskLevel("ssh_profile_create"))
        assertEquals(ToolRiskLevel.L3, kernel.toolRegistry.riskLevel("workspace_artifact_delete"))
        assertEquals(ToolRiskLevel.L3, kernel.toolRegistry.riskLevel("plugin__feishu__send"))
        assertEquals(ToolRiskLevel.L3, kernel.toolRegistry.riskLevel("unregistered_external_op"))

        val secret = "sk-live-secret-1234567890abcdef"
        val l3Preview = kernel.toolRegistry.approvalPreview(
            toolName = "terminal_exec",
            args = buildJsonObject {
                put("command", "curl -H 'Authorization: Bearer $secret' https://api.example.com && echo " + "x".repeat(500))
            },
            targetDevice = "mac-studio-1",
        )
        assertEquals("L3", l3Preview.riskLevel)
        assertTrue(l3Preview.requiresLocalApproval)
        assertFalse(l3Preview.diffPreview.orEmpty().contains(secret))
        assertTrue((l3Preview.diffPreview?.length ?: 0) <= ToolRiskPolicy.DIFF_PREVIEW_LIMIT)

        // Backward compatibility: legacy PendingApprovalDto JSON without Stage 2 optional fields decodes cleanly
        val legacy = json.decodeFromString<PendingApprovalDto>(
            """{"toolCallId":"c-old","tool":"terminal_exec","detail":"ls","highRisk":true}"""
        )
        assertEquals("c-old", legacy.toolCallId)
        assertEquals(null, legacy.riskLevel)
        assertEquals(null, legacy.requiresLocalApproval)
    }

    @Test
    fun gatewayExposesStructuredApprovalAnd403IncludesRequiresLocalApproval() = testApplication {
        val dir = tempDir("stage2-gateway-403-")
        val model = fakeModel { _, _ ->
            UIMessage(
                role = MessageRole.ASSISTANT,
                parts = listOf(
                    UIMessagePart.Tool(
                        toolCallId = "call-l3-ssh",
                        toolName = "ssh_profile_create",
                        input = """{"host":"prod.internal","password":"super-secret-password-99"}""",
                    )
                ),
            )
        }
        val kernel = CloudAgentKernel(dataDir = dir, modelClient = model, masterSecretOverride = "stage2-403-master")
        application { configureCloudGateway(kernel.gatewayState) }

        val secret = kernel.gatewayState.issuePairingTicket()
        val pairResp = client.post("/v1/pair") {
            contentType(ContentType.Application.Json)
            setBody("""{"secret":"$secret","platform":"ios","deviceName":"iPhone 16 Pro"}""")
        }
        val token = json.parseToJsonElement(pairResp.bodyAsText()).jsonObject.getValue("token").jsonPrimitive.content

        val outbound = kernel.handleInbound(
            InboundMessage(
                messageId = "msg-l3-1",
                channel = ChannelKind.APP,
                chatId = "iphone-chat",
                senderId = "owner",
                senderRole = SenderRole.OWNER,
                scope = ConversationScope.DIRECT,
                text = "配置 prod.internal 的 SSH 凭据",
            )
        )
        val card = assertNotNull(outbound.approvalCard)
        assertEquals("L3", card.riskLevel)
        assertEquals(false, card.requiresLocalApproval)
        // The same tool on a paired Mac belongs to that execution device, even for a trusted phone.
        val session = assertNotNull(kernel.gatewayState.getSession(card.sessionKey))
        val pending = assertNotNull(session.pendingApproval)
        kernel.gatewayState.upsertSession(session.copy(pendingApproval = pending.copy(
            targetDevice = "mac-studio", requiresLocalApproval = true,
        )))
        assertEquals("cloud-daemon", card.targetDevice)
        assertEquals("ssh_profile_create: prod.internal", card.targetSummary)
        assertFalse(card.diffPreview.orEmpty().contains("super-secret-password-99"))

        val boardResp = client.get("/v1/amber/board") { bearerAuth(token) }
        val boardJson = json.parseToJsonElement(boardResp.bodyAsText()).jsonObject
        val approvalObj = boardJson.getValue("board").jsonArray.first().jsonObject.getValue("approval").jsonObject
        assertEquals("L3", approvalObj["riskLevel"]?.jsonPrimitive?.contentOrNull)
        assertEquals(approvalObj["targetSummary"], approvalObj["summary"])
        assertEquals(approvalObj["targetDevice"], approvalObj["targetDeviceName"])
        assertEquals(true, approvalObj["requiresLocalApproval"]?.jsonPrimitive?.booleanOrNull)
        assertEquals("ssh_profile_create: prod.internal", approvalObj["targetSummary"]?.jsonPrimitive?.contentOrNull)

        // Local-only requests stay pending even for a biometrically verified foreground client.
        val deny403 = client.post("/v1/amber/decision") {
            bearerAuth(token)
            header("X-Amber-Trusted-Foreground", "true")
            header("X-Amber-Biometric-Verified", "true")
            contentType(ContentType.Application.Json)
            setBody("""{"sessionKey":"${card.sessionKey}","toolCallId":"${card.toolCallId}","allow":true}""")
        }
        assertEquals(403, deny403.status.value)
        val errJson = json.parseToJsonElement(deny403.bodyAsText()).jsonObject
        assertEquals(true, errJson["requiresLocalApproval"]?.jsonPrimitive?.booleanOrNull)
        assertEquals("L3", errJson["riskLevel"]?.jsonPrimitive?.contentOrNull)
        assertEquals("ssh_profile_create: prod.internal", errJson["targetSummary"]?.jsonPrimitive?.contentOrNull)
        assertEquals("mac-studio", errJson["targetDevice"]?.jsonPrimitive?.contentOrNull)
        assertEquals(card.diffPreview, errJson["diffPreview"]?.jsonPrimitive?.contentOrNull)
        assertTrue(errJson["error"]?.jsonPrimitive?.contentOrNull.orEmpty().contains("L3"))
    }

    @Test
    fun privateBaselineDelegationPropagatesSourceRefsAllowsConcurrentQaAndTargetedFollowupEdit() = testApplication {
        val dir = tempDir("stage2-delegation-")
        val workerStarted = CompletableDeferred<Unit>()
        val allowWorkerFinish = CompletableDeferred<Unit>()

        val model = fakeModel { messages, tools ->
            if (messages.firstOrNull()?.toText()?.contains("<native-wait-feedback>") == true) {
                return@fakeModel UIMessage.assistant("任务仍在读取本机文件，完成后立刻告诉你。")
            }
            val latestUser = messages.lastOrNull { it.role == MessageRole.USER }?.toText().orEmpty()
            val hasDispatch = tools.any { it.name == "dispatch_work" }
            if (hasDispatch) {
                return@fakeModel when {
                    latestUser.contains("把第二条改短") -> UIMessage.assistant("好的，已基于刚才的差异稿把第二条精简为：本周完成 Stage 2 契约联调。")
                    latestUser.contains("今天天气") -> UIMessage.assistant("本地快速问答正常：任务仍在后台运行，不阻塞当前对话。")
                    latestUser.contains("整理本机周报") -> UIMessage(
                        role = MessageRole.ASSISTANT,
                        parts = listOf(
                            UIMessagePart.Tool(
                                toolCallId = "dispatch-1",
                                toolName = "dispatch_work",
                                input = """{"tasks":[{"task_key":"weekly-diff","title":"读取本机文件并起草差异稿","brief":"读取 notes/weekly.md 并输出两条摘要"}]}""",
                            )
                        ),
                    )
                    else -> UIMessage.assistant("已收到。")
                }
            }
            if (messages.firstOrNull()?.toText()?.contains("受管 Worker") != true) {
                return@fakeModel UIMessage.assistant("""{"tags":[]}""")
            }
            // Worker turns
            val hasRead = messages.any { message -> message.getTools().any { it.toolCallId == "read-1" && it.output.isNotEmpty() } }
            if (!hasRead) {
                workerStarted.complete(Unit)
                allowWorkerFinish.await()
                UIMessage(
                    role = MessageRole.ASSISTANT,
                    parts = listOf(
                        UIMessagePart.Tool(
                            toolCallId = "read-1",
                            toolName = "workspace_file_read",
                            input = """{"path":"notes/weekly.md"}""",
                        ),
                        UIMessagePart.Tool(
                            toolCallId = "search-1",
                            toolName = "workspace_file_search",
                            input = """{"query":"第二条"}""",
                        )
                    ),
                )
            } else {
                UIMessage(
                    role = MessageRole.ASSISTANT,
                    parts = listOf(
                        UIMessagePart.Tool(
                            toolCallId = "finish-1",
                            toolName = "task_finish",
                            input = """{"outcome":"completed","summary":"1. 完成了 Stage 1 汇流；2. 完成了 Stage 2-A 的 L1-L3 审批协议与 20 条基线。","sourcePaths":["/unobserved/private.md"],"sourceRefs":["invented source"]}""",
                        )
                    ),
                )
            }
        }

        val kernel = CloudAgentKernel(
            dataDir = dir,
            modelClient = model,
            masterSecretOverride = "stage2-delegation-master",
        )
        val api = AgentCentricApi(kernel)
        application {
            configureCloudGateway(kernel.gatewayState, agentApi = api)
            configureDialogueRoutes(kernel.gatewayState, kernel)
        }

        try {
            val secret = kernel.gatewayState.issuePairingTicket()
            val pairResp = client.post("/v1/pair") {
                contentType(ContentType.Application.Json)
                setBody("""{"secret":"$secret","platform":"ios","deviceName":"iPhone"}""")
            }
            val token = json.parseToJsonElement(pairResp.bodyAsText()).jsonObject.getValue("token").jsonPrimitive.content

            // 1. iPhone delegates a task with stable conversationId + parentRunId + epoch
            val submitResp = client.post("/v2/dialogue/messages") {
                bearerAuth(token)
                header("X-Amber-Dialogue-Version", "1")
                contentType(ContentType.Application.Json)
                setBody("""{"requestId":"req-delegate-1","text":"请帮我整理本机周报","conversationId":"conv-shared-42","parentRunId":"ios-run-99","executorKind":"mac","executorId":"mac-studio-1","epoch":1}""")
            }
            assertEquals(202, submitResp.status.value)
            val submitReceipt = json.decodeFromString<DialogueReceipt>(submitResp.bodyAsText())
            assertEquals("conv-shared-42", submitReceipt.conversationId)

            withTimeout(5_000) { workerStarted.await() }
            val workItem = kernel.orchestrationStore.listWorkItems().single()
            assertEquals("conv-shared-42", workItem.conversationId)
            assertEquals("ios-run-99", workItem.parentRunId)

            // Seed real local file inside the worker's workspace so workspace_file_read succeeds
            val workspaceFile = File(kernel.taskWorkspace.directory(workItem.workItemId), "notes/weekly.md")
            workspaceFile.parentFile.mkdirs()
            workspaceFile.writeText("第一条：完成汇流\n第二条：完成 Stage 2-A 审批协议和缓存净账")

            // 2. While Task A is running, send an independent local Q&A in the SAME conversationId -> must NOT block!
            val qaResp = client.post("/v2/dialogue/messages") {
                bearerAuth(token)
                header("X-Amber-Dialogue-Version", "1")
                contentType(ContentType.Application.Json)
                setBody("""{"requestId":"req-qa-1","text":"顺便问下今天天气怎么样？","conversationId":"conv-shared-42"}""")
            }
            assertEquals(202, qaResp.status.value)
            val qaReceipt = json.decodeFromString<DialogueReceipt>(qaResp.bodyAsText())
            withTimeout(5_000) {
                while (true) {
                    val page = json.decodeFromString<DialoguePage>(
                        client.get("/v2/dialogue/events?after=0&limit=100") {
                            bearerAuth(token)
                            header("X-Amber-Dialogue-Version", "1")
                        }.bodyAsText()
                    )
                    val qaReply = page.items.firstOrNull {
                        it.kind == DialogueEventKinds.ASSISTANT_REPLY && it.causedByInputId == qaReceipt.eventId
                    }
                    if (qaReply != null) {
                        assertEquals("conv-shared-42", qaReply.conversationId)
                        assertTrue(qaReply.text.contains("不阻塞"))
                        break
                    }
                    delay(30)
                }
            }

            // 3. Stage 1-A followup + idempotency + stale_epoch while Task A is active
            val followupResp = client.post("/v2/work-items/${workItem.workItemId}/inputs") {
                bearerAuth(token)
                header("X-Amber-Dialogue-Version", "1")
                contentType(ContentType.Application.Json)
                setBody("""{"requestId":"req-fu-1","text":"请重点保留第二条数据","conversationId":"conv-shared-42","epoch":2}""")
            }
            assertEquals(202, followupResp.status.value)
            val followupReplay = client.post("/v2/work-items/${workItem.workItemId}/inputs") {
                bearerAuth(token)
                header("X-Amber-Dialogue-Version", "1")
                contentType(ContentType.Application.Json)
                setBody("""{"requestId":"req-fu-1","text":"请重点保留第二条数据","conversationId":"conv-shared-42","epoch":2}""")
            }
            assertEquals(200, followupReplay.status.value)
            assertTrue(json.decodeFromString<DialogueReceipt>(followupReplay.bodyAsText()).replayed)

            val staleResp = client.post("/v2/work-items/${workItem.workItemId}/inputs") {
                bearerAuth(token)
                header("X-Amber-Dialogue-Version", "1")
                contentType(ContentType.Application.Json)
                setBody("""{"requestId":"req-fu-stale","text":"旧代际输入","conversationId":"conv-shared-42","epoch":1}""")
            }
            assertEquals(409, staleResp.status.value)
            assertTrue(staleResp.bodyAsText().contains("stale_epoch"))

            // 4. Let Task A read file & settle -> verify task_result event AND /v2/work-items/{id} carry sourcePaths/sourceRefs/parentRunId/conversationId
            allowWorkerFinish.complete(Unit)
            val taskResultEvent = withTimeout(5_000) {
                while (true) {
                    val page = json.decodeFromString<DialoguePage>(
                        client.get("/v2/dialogue/events?after=0&limit=100") {
                            bearerAuth(token)
                            header("X-Amber-Dialogue-Version", "1")
                        }.bodyAsText()
                    )
                    val found = page.items.firstOrNull {
                        it.kind == DialogueEventKinds.TASK_RESULT && it.workItemId == workItem.workItemId
                    }
                    if (found != null) return@withTimeout found
                    delay(30)
                }
                error("unreachable")
            }
            assertEquals("conv-shared-42", taskResultEvent.conversationId)
            assertEquals("ios-run-99", taskResultEvent.parentRunId)
            assertEquals(workItem.workItemId, taskResultEvent.workItemId)
            assertEquals(listOf("notes/weekly.md"), taskResultEvent.sourcePaths)
            val digest = OrchestrationHash.sha256Hex(workspaceFile.readText())
            assertEquals(listOf("notes/weekly.md · sha256:$digest", "notes/weekly.md:2"), taskResultEvent.sourceRefs)

            val detailResp = client.get("/v2/work-items/${workItem.workItemId}") { bearerAuth(token) }
            assertEquals(200, detailResp.status.value)
            val detail = json.decodeFromString<PublicWorkDetail>(detailResp.bodyAsText())
            assertEquals("conv-shared-42", detail.conversationId)
            assertEquals("ios-run-99", detail.parentRunId)
            assertEquals(taskResultEvent.sourcePaths, detail.sourcePaths)
            assertEquals(taskResultEvent.sourceRefs, detail.sourceRefs)
            assertTrue(detail.resultMarkdown.orEmpty().contains("## Sources"))

            // 5. Targeted edit referencing the settled workItem as parentRunId in the same conversationId
            val editResp = client.post("/v2/dialogue/messages") {
                bearerAuth(token)
                header("X-Amber-Dialogue-Version", "1")
                contentType(ContentType.Application.Json)
                setBody("""{"requestId":"req-edit-2","text":"把第二条改短","conversationId":"conv-shared-42","parentRunId":"${workItem.workItemId}"}""")
            }
            assertEquals(202, editResp.status.value)
            val editReceipt = json.decodeFromString<DialogueReceipt>(editResp.bodyAsText())
            assertEquals(workItem.workItemId, editReceipt.parentRunId)
            withTimeout(5_000) {
                while (true) {
                    val page = json.decodeFromString<DialoguePage>(
                        client.get("/v2/dialogue/events?after=0&limit=100") {
                            bearerAuth(token)
                            header("X-Amber-Dialogue-Version", "1")
                        }.bodyAsText()
                    )
                    val editReply = page.items.firstOrNull {
                        it.kind == DialogueEventKinds.ASSISTANT_REPLY && it.causedByInputId == editReceipt.eventId
                    }
                    if (editReply != null) {
                        assertEquals("conv-shared-42", editReply.conversationId)
                        assertEquals(workItem.workItemId, editReply.parentRunId)
                        assertTrue(editReply.text.contains("精简"))
                        break
                    }
                    delay(30)
                }
            }

            // 6. Late stop after completion produces stop_too_late with causal IDs (Stage 1-A invariant)
            val lateStopResp = client.post("/v2/work-items/${workItem.workItemId}/stop") {
                bearerAuth(token)
                header("X-Amber-Dialogue-Version", "1")
                contentType(ContentType.Application.Json)
                setBody("""{"requestId":"req-stop-late","text":""}""")
            }
            assertEquals(200, lateStopResp.status.value)
            val lateStopReceipt = json.decodeFromString<DialogueReceipt>(lateStopResp.bodyAsText())
            val finalPage = json.decodeFromString<DialoguePage>(
                client.get("/v2/dialogue/events?after=0&limit=100") {
                    bearerAuth(token)
                    header("X-Amber-Dialogue-Version", "1")
                }.bodyAsText()
            )
            val stopTooLate = finalPage.items.firstOrNull {
                it.kind == DialogueEventKinds.STOP_TOO_LATE && it.causedByInputId == lateStopReceipt.eventId
            }
            assertNotNull(stopTooLate)
            assertEquals("req-stop-late", stopTooLate.causedByRequestId)
        } finally {
            kernel.nativeDialogue.closeAndJoin()
        }
    }
}
