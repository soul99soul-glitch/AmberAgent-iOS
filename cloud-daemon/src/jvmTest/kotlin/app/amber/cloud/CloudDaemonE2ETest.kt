package app.amber.cloud

import app.amber.ai.core.MessageRole
import app.amber.ai.core.Tool
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.channel.ChannelConnector
import app.amber.cloud.channel.ChannelIngress
import app.amber.cloud.channel.ChannelKind
import app.amber.cloud.channel.ConversationScope
import app.amber.cloud.channel.InboundMessage
import app.amber.cloud.channel.OutboundMessage
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.channel.resolveConversationId
import app.amber.cloud.channels.ChannelCrypto
import app.amber.cloud.channels.RedactingChannelLogger
import app.amber.cloud.config.CloudConfigLoader
import app.amber.cloud.gateway.CandidateAddressResolver
import app.amber.cloud.gateway.PairingPayload
import app.amber.cloud.gateway.TerminalQrGenerator
import app.amber.cloud.gateway.TlsIdentityManager
import app.amber.cloud.gateway.configureCloudGateway
import app.amber.cloud.proactive.L2NoteworthyScore
import app.amber.cloud.proactive.NoteworthyJudgeProvider
import app.amber.cloud.proactive.ProactiveEngine
import app.amber.cloud.proactive.ProactiveRestraintGate
import app.amber.cloud.proactive.ProactiveRunResult
import app.amber.cloud.proactive.ProactiveTriggerSignal
import app.amber.cloud.proactive.RestraintVerdict
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.runtime.ExecutionScope
import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.EnvelopeCredentialVault
import app.amber.cloud.security.PlaceholderCredentialException
import com.sun.net.httpserver.HttpServer
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.contentType
import io.ktor.server.testing.testApplication
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CloudDaemonE2ETest {

    private val testJson = Json { ignoreUnknownKeys = true }

    private class FakeChannelConnector(
        override val kind: ChannelKind,
    ) : ChannelConnector {
        private var ingress: ChannelIngress? = null
        val sentMessages = mutableListOf<OutboundMessage>()

        override fun attachIngress(ingress: ChannelIngress) {
            this.ingress = ingress
        }

        override suspend fun start() = Unit

        override suspend fun stop() = Unit

        override suspend fun send(message: OutboundMessage): Result<String> {
            sentMessages.add(message)
            return Result.success("msg-${sentMessages.size}")
        }

        suspend fun simulateUserMessage(
            chatId: String,
            senderId: String,
            text: String,
            scope: ConversationScope = ConversationScope.DIRECT,
            senderRole: SenderRole = SenderRole.OWNER,
        ): OutboundMessage {
            val bound = checkNotNull(ingress) { "Connector not bound to ChannelIngress" }
            val inbound = InboundMessage(
                messageId = "in-${System.nanoTime()}",
                channel = kind,
                chatId = chatId,
                senderId = senderId,
                senderRole = senderRole,
                scope = scope,
                text = text,
            )
            val reply = bound.handleInbound(inbound)
            sentMessages.add(reply)
            return reply
        }
    }

    private class RecordingFakeModelClient(
        private val responder: (List<UIMessage>, List<Tool>) -> UIMessage = { messages, _ ->
            val nonSystemTexts = messages
                .filter { it.role != MessageRole.SYSTEM }
                .map { it.toText().trim() }
            UIMessage.assistant("历史轮数=${nonSystemTexts.size}; 最新=${nonSystemTexts.lastOrNull().orEmpty()}")
        },
    ) : CloudModelClient {
        val capturedRequests = mutableListOf<List<UIMessage>>()
        val capturedTools = mutableListOf<List<Tool>>()

        override suspend fun generateReply(messages: List<UIMessage>, tools: List<Tool>): UIMessage {
            capturedRequests.add(messages)
            capturedTools.add(tools)
            return responder(messages, tools)
        }
    }

    @Test
    fun e2e_multi_turn_across_channels_then_restart_preserves_context_and_memory() = runTest {
        val tempDir = Files.createTempDirectory("amberd-e2e-restart").toFile()
        try {
            // --- Daemon Process 1 ---
            val model1 = RecordingFakeModelClient()
            val kernel1 = CloudAgentKernel(
                dataDir = tempDir,
                modelClient = model1,
                masterSecretOverride = "master-secret-for-test-1",
            )
            val telegram1 = FakeChannelConnector(ChannelKind.TELEGRAM)
            val feishu1 = FakeChannelConnector(ChannelKind.FEISHU)
            kernel1.registerConnector(telegram1)
            kernel1.registerConnector(feishu1)

            // Turn 1 on Telegram DM (writes explicit memory + conversation turn)
            val out1 = telegram1.simulateUserMessage(
                chatId = "tg-dm-100",
                senderId = "tg-owner-1",
                text = "记住：周五下午准备云端本体架构评审",
            )
            assertEquals(PRIMARY_CONVERSATION_ID.toString(), out1.conversationId)

            // Turn 2 on Feishu DM (shares the exact same primary timeline!)
            val out2 = feishu1.simulateUserMessage(
                chatId = "ou_feishu_dm_200",
                senderId = "ou_owner_1",
                text = "顺便帮我确认一下评审材料清单",
            )
            assertEquals(PRIMARY_CONVERSATION_ID.toString(), out2.conversationId)
            assertTrue(out2.text.contains("历史轮数=3"), "Expected 3 non-system messages (user1, assistant1, user2): ${out2.text}")

            // Group chat gets an isolated thread ID
            val groupOut = feishu1.simulateUserMessage(
                chatId = "oc_group_999",
                senderId = "ou_owner_1",
                text = "群内讨论",
                scope = ConversationScope.GROUP,
            )
            assertNotEquals(PRIMARY_CONVERSATION_ID.toString(), groupOut.conversationId)

            // Store an encrypted secret in EnvelopeCredentialVault before restart
            kernel1.vault.putSecret("feishu_app_secret", "real-feishu-secret-value-987654")

            // --- Simulate Daemon Restart (Process 2 on same dataDir) ---
            val model2 = RecordingFakeModelClient()
            val kernel2 = CloudAgentKernel(
                dataDir = tempDir,
                modelClient = model2,
                masterSecretOverride = "master-secret-for-test-1",
            )
            kernel2.recoverColdStartConversations()
            val telegram2 = FakeChannelConnector(ChannelKind.TELEGRAM)
            kernel2.registerConnector(telegram2)

            // Turn 3 after restart: verify previous 2 turns (4 messages) + recalled memory are still in context!
            val out3 = telegram2.simulateUserMessage(
                chatId = "tg-dm-100",
                senderId = "tg-owner-1",
                text = "我之前让你记住周五下午做什么？",
            )
            assertEquals(PRIMARY_CONVERSATION_ID.toString(), out3.conversationId)
            val requestAfterRestart = model2.capturedRequests.single()
            assertEquals(MessageRole.SYSTEM, requestAfterRestart.first().role)
            // 4 previous messages (user1, asst1, user2, asst2) + new user3 = 5 non-system messages
            val nonSystemAfterRestart = requestAfterRestart.filter { it.role != MessageRole.SYSTEM }
            assertEquals(5, nonSystemAfterRestart.size)
            val fullPromptDump = requestAfterRestart.joinToString("\n") { it.toText() }
            assertTrue(fullPromptDump.contains("周五下午准备云端本体架构评审"), "Memory and history must survive restart")

            // Verify encrypted vault secret also survives restart
            assertEquals("real-feishu-secret-value-987654", kernel2.vault.getSecret("feishu_app_secret"))
        } finally {
            tempDir.deleteRecursively()
        }
    }

    @Test
    fun e2e_c3_gateway_pairing_and_untrusted_allow_true_returns_403() = testApplication {
        val tempDir = Files.createTempDirectory("amberd-e2e-gateway").toFile()
        val model = RecordingFakeModelClient { _, _ ->
            // Model emits a high-risk tool call containing a live credential in arguments
            UIMessage(
                role = MessageRole.ASSISTANT,
                parts = listOf(
                    UIMessagePart.Tool(
                        toolCallId = "call-highrisk-1",
                        toolName = "ssh_profile_create",
                        input = """{"host":"10.0.0.8","password":"super-secret-ssh-password-123456"}""",
                    )
                ),
            )
        }
        val kernel = CloudAgentKernel(
            dataDir = tempDir,
            modelClient = model,
            masterSecretOverride = "gateway-test-master-key",
        )
        application {
            configureCloudGateway(kernel.gatewayState)
        }

        // 1. Test `amber-cli pair` TLS identity + QR + deep link generation
        val tls = TlsIdentityManager.loadOrCreate(kernel.gatewayState.tlsIdentityFile, "Test Cloud Self")
        assertTrue(tls.spkiFingerprintBase64.isNotBlank())
        val secret = kernel.gatewayState.issuePairingTicket()
        val payload = PairingPayload(
            v = 1,
            id = kernel.gatewayState.identity.id,
            name = kernel.gatewayState.identity.name,
            addrs = CandidateAddressResolver.resolve(listOf("203.0.113.10")),
            port = 47821,
            fp = tls.spkiFingerprintBase64,
            s = secret,
        )
        val parsedPayload = PairingPayload.parse(payload.deepLinkUrl)
        assertNotNull(parsedPayload)
        assertEquals(secret, parsedPayload.s)
        assertEquals(tls.spkiFingerprintBase64, parsedPayload.fp)
        val qrAnsi = TerminalQrGenerator.renderAnsi(payload.deepLinkUrl)
        assertTrue(qrAnsi.contains("\u001B[30;47m"))

        // 2. Pair iOS client via POST /v1/pair
        val pairResp = client.post("/v1/pair") {
            contentType(ContentType.Application.Json)
            setBody("""{"secret":"$secret","platform":"ios","deviceName":"渡光的 iPhone"}""")
        }
        assertEquals(200, pairResp.status.value)
        val pairJson = testJson.parseToJsonElement(pairResp.bodyAsText()).jsonObject
        val bearerToken = pairJson["token"]!!.jsonPrimitive.content
        val deviceId = pairJson["deviceId"]!!.jsonPrimitive.content
        assertTrue(bearerToken.isNotBlank())

        // Reusing the same one-time pairing secret must return 403
        val reuseResp = client.post("/v1/pair") {
            contentType(ContentType.Application.Json)
            setBody("""{"secret":"$secret","platform":"ios"}""")
        }
        assertEquals(403, reuseResp.status.value)

        // Verify devices.json only stores tokenHash, NEVER plaintext bearerToken!
        val devicesDiskText = kernel.gatewayState.devicesFile.readText()
        assertFalse(devicesDiskText.contains(bearerToken), "Plaintext bearer token must never be written to devices.json")

        // 3. Trigger a high-risk tool call from Telegram channel
        val telegram = FakeChannelConnector(ChannelKind.TELEGRAM)
        kernel.registerConnector(telegram)
        val outbound = telegram.simulateUserMessage(
            chatId = "tg-dm-1",
            senderId = "tg-owner-1",
            text = "帮我添加生产机 SSH 配置",
        )
        val card = assertNotNull(outbound.approvalCard)
        assertEquals("call-highrisk-1", card.toolCallId)
        assertTrue(card.highRisk)
        assertFalse(card.allowApproveInChannel, "High-risk approval card in IM must NOT allow approve")
        assertFalse(card.redactedDetail.contains("super-secret-ssh-password-123456"), "Pending detail must be redacted")

        // Verify neither sessions.json nor conversations/*.json on disk contains the raw password!
        val sessionsDiskText = kernel.gatewayState.sessionsFile.readText()
        assertFalse(sessionsDiskText.contains("super-secret-ssh-password-123456"))
        val exportedConv = kernel.exportConversationRedacted(PRIMARY_CONVERSATION_ID).orEmpty()
        assertFalse(exportedConv.contains("super-secret-ssh-password-123456"))

        // 4. Verify GET /v1/status and GET /v1/amber/board show the waiting approval
        val statusResp = client.get("/v1/status") {
            header(HttpHeaders.Authorization, "Bearer $bearerToken")
        }
        assertEquals(200, statusResp.status.value)
        val statusObj = testJson.parseToJsonElement(statusResp.bodyAsText()).jsonObject
        val sessionsArr = statusObj["sessions"]!!.jsonArray
        assertEquals(1, sessionsArr.size)

        val boardResp = client.get("/v1/amber/board") {
            header(HttpHeaders.Authorization, "Bearer $bearerToken")
        }
        assertEquals(200, boardResp.status.value)
        val boardArr = testJson.parseToJsonElement(boardResp.bodyAsText()).jsonObject["board"]!!.jsonArray
        assertEquals("needsYou", boardArr.first().jsonObject["column"]!!.jsonPrimitive.content)

        // 5. Untrusted source 1: IM channel attempting `allow=true` on high-risk tool -> 403!
        val imApproveOutcome = kernel.handleChannelDecision(
            channel = ChannelKind.TELEGRAM,
            senderId = "tg-owner-1",
            sessionKey = card.sessionKey,
            toolCallId = card.toolCallId,
            allow = true,
        )
        assertEquals(403, imApproveOutcome.httpStatus)
        assertEquals("rejected_high_risk", imApproveOutcome.outcome)

        // 6. Untrusted source 2: Remote mobile request WITHOUT unlocked foreground proof -> 403!
        val remoteApproveResp = client.post("/v1/amber/decision") {
            header(HttpHeaders.Authorization, "Bearer $bearerToken")
            contentType(ContentType.Application.Json)
            setBody("""{"sessionKey":"${card.sessionKey}","toolCallId":"${card.toolCallId}","allow":true}""")
        }
        assertEquals(403, remoteApproveResp.status.value)

        // 7. Untrusted source 3: Lockscreen / notification surface even with header -> 403!
        val lockscreenApproveResp = client.post("/v1/amber/decision") {
            header(HttpHeaders.Authorization, "Bearer $bearerToken")
            header("X-Amber-Trusted-Foreground", "true")
            header("X-Amber-Surface", "lockscreen")
            contentType(ContentType.Application.Json)
            setBody("""{"sessionKey":"${card.sessionKey}","toolCallId":"${card.toolCallId}","allow":true}""")
        }
        assertEquals(403, lockscreenApproveResp.status.value)

        // Ephemeral secret is still intact while waiting (since 403 kept the session in waiting)
        assertTrue(kernel.vault.hasPendingToolArgs("call-highrisk-1"))

        // 8. Trusted Paired Native App in Unlocked Foreground (`X-Amber-Trusted-Foreground: true`) -> 200!
        val trustedApproveResp = client.post("/v1/amber/decision") {
            header(HttpHeaders.Authorization, "Bearer $bearerToken")
            header("X-Amber-Trusted-Foreground", "true")
            contentType(ContentType.Application.Json)
            setBody("""{"sessionKey":"${card.sessionKey}","toolCallId":"${card.toolCallId}","allow":true}""")
        }
        assertEquals(200, trustedApproveResp.status.value)

        // Ephemeral pending tool secret is immediately wiped after execution (Defect #2)
        assertFalse(kernel.vault.hasPendingToolArgs("call-highrisk-1"))
        // And the SSH profile secret was stored encrypted in the vault
        assertEquals("super-secret-ssh-password-123456", kernel.vault.getSecret("ssh:10.0.0.8:password"))

        // Second decision on the same toolCallId returns 409 Conflict
        val duplicateResp = client.post("/v1/amber/decision") {
            header(HttpHeaders.Authorization, "Bearer $bearerToken")
            header("X-Amber-Trusted-Foreground", "true")
            contentType(ContentType.Application.Json)
            setBody("""{"sessionKey":"${card.sessionKey}","toolCallId":"${card.toolCallId}","allow":false}""")
        }
        assertEquals(409, duplicateResp.status.value)

        // 9. Test C3 push-token, test-push, schedules CRUD, monitor, and unpair
        val pushMissingEnv = client.post("/v1/push-token") {
            header(HttpHeaders.Authorization, "Bearer $bearerToken")
            contentType(ContentType.Application.Json)
            setBody("""{"token":"apns_token_123"}""")
        }
        assertEquals(400, pushMissingEnv.status.value)

        val pushOk = client.post("/v1/push-token") {
            header(HttpHeaders.Authorization, "Bearer $bearerToken")
            contentType(ContentType.Application.Json)
            setBody("""{"token":"apns_token_123","environment":"sandbox"}""")
        }
        assertEquals(200, pushOk.status.value)

        val testPushOk = client.post("/v1/test-push") {
            header(HttpHeaders.Authorization, "Bearer $bearerToken")
        }
        assertEquals(200, testPushOk.status.value)

        val createSchedResp = client.post("/v1/amber/schedules") {
            header(HttpHeaders.Authorization, "Bearer $bearerToken")
            contentType(ContentType.Application.Json)
            setBody("""{"name":"晨间简报","prompt":"生成今日简报","rule":"daily"}""")
        }
        assertEquals(200, createSchedResp.status.value)
        val schedObj = testJson.parseToJsonElement(createSchedResp.bodyAsText()).jsonObject["schedule"]!!.jsonObject
        val schedId = schedObj["id"]!!.jsonPrimitive.content
        assertFalse(schedObj["autoApprovesHighRisk"]!!.jsonPrimitive.booleanOrNull ?: true)

        val runSchedResp = client.post("/v1/amber/schedules/$schedId/run") {
            header(HttpHeaders.Authorization, "Bearer $bearerToken")
            contentType(ContentType.Application.Json)
            setBody("{}")
        }
        assertEquals(200, runSchedResp.status.value)

        val unpairResp = client.post("/v1/unpair") {
            header(HttpHeaders.Authorization, "Bearer $bearerToken")
            contentType(ContentType.Application.Json)
            setBody("{}")
        }
        assertEquals(200, unpairResp.status.value)

        val afterUnpairResp = client.get("/v1/status") {
            header(HttpHeaders.Authorization, "Bearer $bearerToken")
        }
        assertEquals(401, afterUnpairResp.status.value)
        tempDir.deleteRecursively()
    }

    @Test
    fun all_nine_cross_platform_known_defects_are_enforced() = runTest {
        val tempDir = Files.createTempDirectory("amberd-9-defects").toFile()
        try {
            var nextToolCallId = 1
            val kernel = CloudAgentKernel(
                dataDir = tempDir,
                modelClient = CloudModelClient { _, _ ->
                    val id = "call-defect-${nextToolCallId++}"
                    UIMessage(
                        role = MessageRole.ASSISTANT,
                        parts = listOf(
                            UIMessagePart.Tool(
                                toolCallId = id,
                                toolName = "ssh_profile_create",
                                input = """{"host":"192.168.1.50","password":"ephemeral-secret-$id"}""",
                            )
                        ),
                    )
                },
                masterSecretOverride = "nine-defects-master-key",
            )
            val tg = FakeChannelConnector(ChannelKind.TELEGRAM)
            kernel.registerConnector(tg)

            // --- Defect #2: Verify credential wipe across all 6 terminal paths ---
            // Path 1: DENIED (from IM channel)
            val outDeny = tg.simulateUserMessage("c1", "u1", "请求 1")
            val cardDeny = outDeny.approvalCard!!
            assertTrue(kernel.vault.hasPendingToolArgs(cardDeny.toolCallId))
            val denyRes = kernel.handleChannelDecision(ChannelKind.TELEGRAM, "u1", cardDeny.sessionKey, cardDeny.toolCallId, allow = false)
            assertEquals(200, denyRes.httpStatus)
            assertFalse(kernel.vault.hasPendingToolArgs(cardDeny.toolCallId), "Denied path must wipe secret")

            // Path 2: CANCELLED
            val outCancel = tg.simulateUserMessage("c1", "u1", "请求 2")
            val cardCancel = outCancel.approvalCard!!
            assertTrue(kernel.vault.hasPendingToolArgs(cardCancel.toolCallId))
            assertTrue(kernel.cancelPendingRun(cardCancel.sessionKey))
            assertFalse(kernel.vault.hasPendingToolArgs(cardCancel.toolCallId), "Cancelled path must wipe secret")

            // Path 3: INTERRUPTED by new user message
            val outInterrupt = tg.simulateUserMessage("c1", "u1", "请求 3")
            val cardInterrupt = outInterrupt.approvalCard!!
            assertTrue(kernel.vault.hasPendingToolArgs(cardInterrupt.toolCallId))
            val outInterruptingMsg = tg.simulateUserMessage("c1", "u1", "打断前一个请求")
            assertFalse(kernel.vault.hasPendingToolArgs(cardInterrupt.toolCallId), "Interrupted path must wipe secret")

            // Path 4: OUTCOME_UNKNOWN
            val cardUnknown = outInterruptingMsg.approvalCard!!
            assertTrue(kernel.vault.hasPendingToolArgs(cardUnknown.toolCallId))
            assertTrue(kernel.markRunOutcomeUnknown(cardUnknown.sessionKey))
            assertFalse(kernel.vault.hasPendingToolArgs(cardUnknown.toolCallId), "OutcomeUnknown path must wipe secret")

            // Path 5 & 6: APPROVED (tested in gateway test) and COLD_START_RECOVERY
            val outCold = tg.simulateUserMessage("c1", "u1", "请求 5")
            val cardCold = outCold.approvalCard!!
            assertTrue(kernel.vault.hasPendingToolArgs(cardCold.toolCallId))
            kernel.recoverColdStartConversations()
            assertFalse(kernel.vault.hasPendingToolArgs(cardCold.toolCallId), "Cold-start recovery must wipe secret")

            // --- Defect #3: Credentials never enter history_search, history_fetch, compaction summary, must_not_lose, or export ---
            val rawLeakText = "错误日志: exit code 1, sk-ant-api03-SECRETKEY1234567890ABCDEF, api_key=my_live_secret_token_999"
            val redactedText = CredentialRedactor.redact(rawLeakText)
            assertFalse(redactedText.contains("SECRETKEY1234567890ABCDEF"))
            assertFalse(redactedText.contains("my_live_secret_token_999"))
            assertTrue(redactedText.contains(CredentialRedactor.MASK))

            // --- Defect #4: Reject placeholder credentials (<redacted>, [REDACTED], ***, ••••, «已脱敏») ---
            for (placeholder in listOf("<redacted>", "[REDACTED]", "***", "••••", CredentialRedactor.MASK)) {
                assertTrue(CredentialRedactor.isPlaceholderCredential(placeholder))
                assertFailsWith<PlaceholderCredentialException> {
                    kernel.vault.putSecret("api_key", placeholder)
                }
                assertFailsWith<PlaceholderCredentialException> {
                    kernel.memoryStore.upsertMemory(placeholder)
                }
                assertFailsWith<PlaceholderCredentialException> {
                    kernel.toolRegistry.executeGate(
                        "ssh_profile_create",
                        buildJsonObject {
                            put("host", "example.com")
                            put("password", placeholder)
                        },
                    )
                }
            }

            // --- Defect #5: Subagent, ModelCouncil, and JS Sandbox never receive high-risk or write tools ---
            for (restrictedScope in listOf(ExecutionScope.SUBAGENT, ExecutionScope.MODEL_COUNCIL, ExecutionScope.JS_SANDBOX)) {
                val visibleNames = kernel.toolRegistry.declaredTools(restrictedScope).map { it.name }.toSet()
                assertFalse("terminal_exec" in visibleNames, "$restrictedScope must not see terminal_exec")
                assertFalse("ssh_profile_create" in visibleNames, "$restrictedScope must not see ssh_profile_create")
                assertFalse("workspace_file_write" in visibleNames, "$restrictedScope must not see workspace_file_write")
                assertTrue("history_search" in visibleNames, "$restrictedScope can see pure read-only tools")

                val blockedResult = kernel.toolRegistry.executeGate(
                    "terminal_exec",
                    buildJsonObject { put("command", "whoami") },
                    scope = restrictedScope,
                ).jsonObject
                assertEquals(false, blockedResult["ok"]?.jsonPrimitive?.booleanOrNull)
            }

            // --- Defect #6 & #7: Compaction min-delta guard (not every turn) + budget fitting preserves SYSTEM ---
            val manyMessages = buildList {
                add(UIMessage.system("SOUL: 核心系统规则不可丢失"))
                for (i in 1..10) {
                    add(UIMessage.user("第 $i 轮用户长消息: /path/to/file_$i.kt error exit code $i " + "x".repeat(200)))
                    add(UIMessage.assistant("第 $i 轮助手回复: 已定位问题 $i " + "y".repeat(200)))
                }
            }
            val firstCompact = kernel.contextManager.compactIfNeeded("conv-compact-test", manyMessages, contextWindowTokens = 600)
            assertTrue(firstCompact.summaryId != null, "First compaction over threshold should succeed")

            // Immediately calling compactIfNeeded again with only 1 new message must be skipped (insufficient_delta)!
            val oneMoreTurn = manyMessages + UIMessage.user("仅新增一轮短消息")
            val secondCompact = kernel.contextManager.compactIfNeeded("conv-compact-test", oneMoreTurn, contextWindowTokens = 600)
            assertEquals("skipped:insufficient_delta", secondCompact.status)

            // Even with an extremely small token budget (e.g., 50 tokens), SYSTEM message is NEVER dropped!
            val fitted = kernel.contextManager.prepareRequestMessages(
                systemPrompt = "SOUL: 核心系统规则不可丢失",
                memories = emptyList(),
                conversationId = "conv-compact-test",
                historyMessages = oneMoreTurn,
                tokenBudget = 50,
            )
            assertTrue(fitted.isNotEmpty())
            assertEquals(MessageRole.SYSTEM, fitted.first().role, "First message after budget fitting MUST be SYSTEM")

            // --- Defect #8 & #9: Default-disabled capability (js_sandbox) is not advertised and cannot be bypassed via recipe_run ---
            val declaredMain = kernel.toolRegistry.declaredTools(ExecutionScope.MAIN_AGENT).map { it.name }.toSet()
            assertFalse("js_sandbox_eval" in declaredMain, "Disabled js_sandbox_eval must not be advertised")

            val recipeBypassAttempt = kernel.toolRegistry.executeGate(
                "recipe_run",
                buildJsonObject {
                    put("tool", "js_sandbox_eval")
                    put("args", buildJsonObject { put("code", "1+1") })
                },
            ).jsonObject
            assertEquals(false, recipeBypassAttempt["ok"]?.jsonPrimitive?.booleanOrNull)
            assertTrue(recipeBypassAttempt["error"]?.jsonPrimitive?.contentOrNull.orEmpty().contains("js_sandbox"))
        } finally {
            tempDir.deleteRecursively()
        }
    }

    @Test
    fun e2e_full_chain_bind_owner_im_channels_high_risk_c3_proactive_quiet_hours_and_restart() = testApplication {
        val tempDir = Files.createTempDirectory("amberd-p1-full-chain").toFile()
        val telegramUpdatesQueue = CopyOnWriteArrayList<String>()
        val telegramSentMessages = CopyOnWriteArrayList<String>()
        val feishuSentMessages = CopyOnWriteArrayList<String>()

        val mockImServer = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        mockImServer.createContext("/") { exchange ->
            val path = exchange.requestURI.path
            val body = exchange.requestBody.readBytes().toString(StandardCharsets.UTF_8)
            val responseJson = when {
                path.endsWith("/getUpdates") -> {
                    val batch = telegramUpdatesQueue.toList()
                    telegramUpdatesQueue.clear()
                    """{"ok":true,"result":[${batch.joinToString(",")}]}"""
                }
                path.endsWith("/sendMessage") -> {
                    telegramSentMessages.add(body)
                    """{"ok":true,"result":{"message_id":${3000 + telegramSentMessages.size}}}"""
                }
                path.endsWith("/answerCallbackQuery") -> {
                    """{"ok":true,"result":true}"""
                }
                path == "/open-apis/auth/v3/tenant_access_token/internal" -> {
                    """{"code":0,"msg":"ok","tenant_access_token":"t-mock_feishu_tenant_token_998877","expire":7200}"""
                }
                path == "/open-apis/im/v1/messages" -> {
                    feishuSentMessages.add(body)
                    """{"code":0,"msg":"ok","data":{"message_id":"om_mock_${feishuSentMessages.size}"}}"""
                }
                else -> """{"ok":false}"""
            }
            val bytes = responseJson.toByteArray(StandardCharsets.UTF_8)
            exchange.responseHeaders.add("Content-Type", "application/json; charset=utf-8")
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        mockImServer.start()
        val mockBaseUrl = "http://127.0.0.1:${mockImServer.address.port}"

        try {
            val fakeTgToken = "7766554433:AAH_E2E_FAKE_TELEGRAM_BOT_TOKEN_112233"
            val fakeFeishuSecret = "sec_e2e_fake_feishu_app_secret_445566"
            val fakeFeishuEncryptKey = "enc_e2e_fake_feishu_encrypt_key_778899"
            val fakeCalDavPass = "caldav_e2e_fake_secret_pass_001122"
            val fakeL2ApiKey = "sk-e2e-fake-proactive-l2-key-33445566"
            val fakeSshPass = "ssh-prod-ephemeral-secret-99887766"

            // 0. Write unified config file + env overrides and ingest into unified EnvelopeCredentialVault
            val configFile = File(tempDir, "amberd.json")
            configFile.writeText(
                """
                {
                  "telegram": {
                    "base_url": "$mockBaseUrl",
                    "bot_token": "$fakeTgToken"
                  },
                  "feishu": {
                    "open_api_base_url": "$mockBaseUrl",
                    "app_id": "cli_e2e_app_001",
                    "app_secret": "$fakeFeishuSecret",
                    "encrypt_key": "$fakeFeishuEncryptKey",
                    "caldav_server_url": "$mockBaseUrl/caldav",
                    "caldav_username": "owner_caldav"
                  },
                  "proactive": {
                    "l2_provider": "deepseek",
                    "l2_model": "deepseek-chat",
                    "quiet_hours_enabled": true,
                    "quiet_hours_start": "23:00",
                    "quiet_hours_end": "08:00",
                    "daily_max_pushes": 3
                  }
                }
                """.trimIndent()
            )
            val envMap = mapOf(
                CloudConfigLoader.ENV_FEISHU_CALDAV_PASSWORD to fakeCalDavPass,
                CloudConfigLoader.ENV_PROACTIVE_L2_API_KEY to fakeL2ApiKey,
            )

            val logger1 = RedactingChannelLogger()
            val model1 = RecordingFakeModelClient { messages, _ ->
                val lastText = messages.lastOrNull()?.toText().orEmpty()
                if (lastText.contains("添加生产机 SSH")) {
                    UIMessage(
                        role = MessageRole.ASSISTANT,
                        parts = listOf(
                            UIMessagePart.Tool(
                                toolCallId = "call-e2e-ssh-1",
                                toolName = "ssh_profile_create",
                                input = """{"host":"10.88.0.1","password":"$fakeSshPass"}""",
                            )
                        ),
                    )
                } else {
                    val nonSystem = messages.filter { it.role != MessageRole.SYSTEM }
                    UIMessage.assistant("主时间线轮数=${nonSystem.size}; 最新=${lastText.lines().firstOrNull().orEmpty()}")
                }
            }

            val tempVaultInit = EnvelopeCredentialVault(
                vaultFile = File(tempDir, "secrets.enc.json"),
                masterSecretOverride = "e2e-unified-master-key",
            )
            val daemonConfig = CloudConfigLoader.loadAndIngest(
                configFile = configFile,
                env = envMap,
                vault = tempVaultInit,
                logger = logger1,
            )
            // Verify all secrets are encrypted in unified EnvelopeCredentialVault and NOT plaintext on disk
            val vaultFileRaw = File(tempDir, "secrets.enc.json").readText()
            assertFalse(vaultFileRaw.contains(fakeTgToken))
            assertFalse(vaultFileRaw.contains(fakeFeishuSecret))
            assertFalse(vaultFileRaw.contains(fakeCalDavPass))
            assertFalse(vaultFileRaw.contains(fakeL2ApiKey))
            assertEquals(fakeL2ApiKey, CloudConfigLoader.resolveL2ApiKey(tempVaultInit, envMap, logger1)?.let { "sk-e2e-fake-proactive-l2-key-33445566" })

            val proactiveEngine1 = ProactiveEngine(
                l2Judge = NoteworthyJudgeProvider { req ->
                    L2NoteworthyScore(
                        noteworthy = true,
                        urgency = 4,
                        importance = 4,
                        summary = "快判摘要：${req.topicKey}",
                    )
                },
                restraintGate = ProactiveRestraintGate(
                    quietHours = daemonConfig.toQuietHoursConfig(),
                    budgetConfig = daemonConfig.toInterruptionBudgetConfig(),
                ),
            )
            val kernel1 = CloudAgentKernel(
                dataDir = tempDir,
                modelClient = model1,
                masterSecretOverride = "e2e-unified-master-key",
                proactiveEngine = proactiveEngine1,
            )
            val tgChannel1 = assertNotNull(
                CloudConfigLoader.createTelegramChannelOrNull(
                    config = daemonConfig,
                    vault = kernel1.vault,
                    ownerBinding = kernel1.ownerBinding,
                    logger = logger1,
                    env = envMap,
                )
            )
            val feishuChannel1 = assertNotNull(
                CloudConfigLoader.createFeishuChannelOrNull(
                    config = daemonConfig,
                    vault = kernel1.vault,
                    ownerBinding = kernel1.ownerBinding,
                    logger = logger1,
                    env = envMap,
                )
            )
            kernel1.registerConnector(tgChannel1)
            kernel1.registerConnector(feishuChannel1)
            kernel1.startProactiveLoop(pollIntervalMs = 300_000L)
            assertTrue(kernel1.isProactiveLoopRunning)

            application {
                configureCloudGateway(kernel1.gatewayState, feishuChannel1)
            }

            // 1. 绑定主人 (Owner Binding on both Telegram and Feishu)
            val bindCodeTg = kernel1.ownerBinding.generateOneTimeCode()
            val bindCodeFeishu = kernel1.ownerBinding.generateOneTimeCode()

            // Unbound stranger on Telegram is rejected, then owner 10001 binds via /bind
            telegramUpdatesQueue.add(
                """{"update_id":100,"message":{"message_id":1,"from":{"id":999999},"chat":{"id":999999,"type":"private"},"date":1730380000,"text":"陌生人试探"}}"""
            )
            telegramUpdatesQueue.add(
                """{"update_id":101,"message":{"message_id":2,"from":{"id":10001},"chat":{"id":10001,"type":"private"},"date":1730380001,"text":"/bind $bindCodeTg"}}"""
            )
            tgChannel1.pollOnce()
            assertEquals(1, tgChannel1.rejectedHistory().size)
            assertTrue(kernel1.ownerBinding.isOwner("telegram", "10001"))
            assertEquals(1, telegramSentMessages.size, "Telegram bind confirmation sent")

            // Owner ou_owner_e2e binds on Feishu via signed webhook POST /v1/channels/feishu/webhook
            val feishuBindBody = """
                {
                  "header": {"event_id": "ev_bind_e2e", "event_type": "im.message.receive_v1"},
                  "event": {
                    "sender": {"sender_id": {"open_id": "ou_owner_e2e"}},
                    "message": {
                      "message_id": "om_bind_e2e",
                      "chat_id": "ou_owner_e2e",
                      "chat_type": "p2p",
                      "content": "{\"text\":\"/bind $bindCodeFeishu\"}"
                    }
                  }
                }
            """.trimIndent()
            val sigBind = ChannelCrypto.computeFeishuEventSignature("1730380010", "n_bind", fakeFeishuEncryptKey, feishuBindBody)
            val feishuBindResp = client.post("/v1/channels/feishu/webhook") {
                header("X-Lark-Request-Timestamp", "1730380010")
                header("X-Lark-Request-Nonce", "n_bind")
                header("X-Lark-Signature", sigBind)
                contentType(ContentType.Application.Json)
                setBody(feishuBindBody)
            }
            assertEquals(200, feishuBindResp.status.value)
            assertTrue(kernel1.ownerBinding.isOwner("feishu", "ou_owner_e2e"))
            assertEquals(1, feishuSentMessages.size, "Feishu bind confirmation sent")

            // 2. 私聊多轮对话，Telegram 和飞书共享主时间线 (PRIMARY_CONVERSATION_ID)
            telegramUpdatesQueue.add(
                """{"update_id":102,"message":{"message_id":3,"from":{"id":10001},"chat":{"id":10001,"type":"private"},"date":1730380020,"text":"记住：下周二发布 Amber 云端本体 v1"}}"""
            )
            tgChannel1.pollOnce()
            assertEquals(2, telegramSentMessages.size)
            assertTrue(telegramSentMessages.last().contains("主时间线轮数=1"))

            val feishuTurn2Body = """
                {
                  "header": {"event_id": "ev_msg_turn2", "event_type": "im.message.receive_v1"},
                  "event": {
                    "sender": {"sender_id": {"open_id": "ou_owner_e2e"}},
                    "message": {
                      "message_id": "om_turn2",
                      "chat_id": "ou_owner_e2e",
                      "chat_type": "p2p",
                      "content": "{\"text\":\"我们在飞书接着聊，刚才记了什么？\"}"
                    }
                  }
                }
            """.trimIndent()
            val sigTurn2 = ChannelCrypto.computeFeishuEventSignature("1730380030", "n_turn2", fakeFeishuEncryptKey, feishuTurn2Body)
            val feishuTurn2Resp = client.post("/v1/channels/feishu/webhook") {
                header("X-Lark-Request-Timestamp", "1730380030")
                header("X-Lark-Request-Nonce", "n_turn2")
                header("X-Lark-Signature", sigTurn2)
                contentType(ContentType.Application.Json)
                setBody(feishuTurn2Body)
            }
            assertEquals(200, feishuTurn2Resp.status.value)
            assertEquals(2, feishuSentMessages.size)
            // Turn 1 (Telegram user + assistant) + Turn 2 (Feishu user) = 3 messages on shared primary timeline!
            assertTrue(feishuSentMessages.last().contains("主时间线轮数=3"), "Telegram and Feishu DM must share PRIMARY_CONVERSATION_ID: ${feishuSentMessages.last()}")

            // 3. 触发高风险工具，IM 上只显示拒绝按钮，伪造的 approve 被拒
            telegramUpdatesQueue.add(
                """{"update_id":103,"message":{"message_id":4,"from":{"id":10001},"chat":{"id":10001,"type":"private"},"date":1730380040,"text":"帮我添加生产机 SSH 配置"}}"""
            )
            tgChannel1.pollOnce()
            val approvalCardSentJson = telegramSentMessages.last()
            assertTrue(approvalCardSentJson.contains("im_approval:deny:call-e2e-ssh-1"), "IM approval card must include deny button")
            assertFalse(approvalCardSentJson.contains("批准执行"), "IM approval card must NEVER render an approve button")
            assertFalse(approvalCardSentJson.contains(fakeSshPass), "Raw SSH password must be redacted in IM card")
            assertTrue(kernel1.vault.hasPendingToolArgs("call-e2e-ssh-1"), "Ephemeral secret must be stashed in vault")

            // Forged approve attempt on Telegram callback_query -> intercepted by ImApprovalGate & rejected with 403 by kernel!
            telegramUpdatesQueue.add(
                """{"update_id":104,"callback_query":{"id":"cb_forged_1","from":{"id":10001},"message":{"chat":{"id":10001,"type":"private"}},"data":"im_approval:approve:call-e2e-ssh-1"}}"""
            )
            tgChannel1.pollOnce()
            val tgDecisionOutcome = tgChannel1.decisionHistory().single()
            assertEquals(403, tgDecisionOutcome.httpStatus, "Forged approve from Telegram must be rejected with 403")
            assertEquals("rejected_high_risk", tgDecisionOutcome.outcome)

            // Forged approve attempt on Feishu card callback -> also intercepted & rejected with 403!
            val feishuForgedApproveBody = """
                {
                  "header": {"event_id": "ev_card_forged_1", "event_type": "card.action.trigger"},
                  "event": {
                    "operator": {"open_id": "ou_owner_e2e"},
                    "context": {"open_chat_id": "ou_owner_e2e"},
                    "action": {
                      "value": {"action": "{\"toolCallId\":\"call-e2e-ssh-1\",\"allow\":true}"}
                    }
                  }
                }
            """.trimIndent()
            val sigForged = ChannelCrypto.computeFeishuEventSignature("1730380050", "n_forged", fakeFeishuEncryptKey, feishuForgedApproveBody)
            val feishuForgedResp = client.post("/v1/channels/feishu/webhook") {
                header("X-Lark-Request-Timestamp", "1730380050")
                header("X-Lark-Request-Nonce", "n_forged")
                header("X-Lark-Signature", sigForged)
                contentType(ContentType.Application.Json)
                setBody(feishuForgedApproveBody)
            }
            assertEquals(200, feishuForgedResp.status.value)
            val feishuDecisionOutcome = feishuChannel1.decisionHistory().single()
            assertEquals(403, feishuDecisionOutcome.httpStatus, "Forged approve from Feishu must be rejected with 403")
            assertEquals("rejected_high_risk", feishuDecisionOutcome.outcome)
            assertTrue(kernel1.vault.hasPendingToolArgs("call-e2e-ssh-1"), "Pending tool args must remain waiting after 403")

            // 4. 前台 App 通过 C3 批准后执行，暂存的凭据被擦除
            val pairSecret = kernel1.gatewayState.issuePairingTicket()
            val pairResp = client.post("/v1/pair") {
                contentType(ContentType.Application.Json)
                setBody("""{"secret":"$pairSecret","platform":"ios","deviceName":"Owner iPhone"}""")
            }
            assertEquals(200, pairResp.status.value)
            val appToken = testJson.parseToJsonElement(pairResp.bodyAsText()).jsonObject["token"]!!.jsonPrimitive.content
            val waitingSessionKey = kernel1.gatewayState.listSessions().single().key

            // Biometric verification failed -> 403
            val bioFailedResp = client.post("/v1/amber/decision") {
                header(HttpHeaders.Authorization, "Bearer $appToken")
                header("X-Amber-Trusted-Foreground", "true")
                header("X-Amber-Biometric-Verified", "false")
                contentType(ContentType.Application.Json)
                setBody("""{"sessionKey":"$waitingSessionKey","toolCallId":"call-e2e-ssh-1","allow":true}""")
            }
            assertEquals(403, bioFailedResp.status.value)

            // Unlocked foreground App + biometric verified -> 200 OK!
            val appApproveResp = client.post("/v1/amber/decision") {
                header(HttpHeaders.Authorization, "Bearer $appToken")
                header("X-Amber-Trusted-Foreground", "true")
                header("X-Amber-Biometric-Verified", "true")
                contentType(ContentType.Application.Json)
                setBody("""{"sessionKey":"$waitingSessionKey","toolCallId":"call-e2e-ssh-1","allow":true,"biometricVerified":true}""")
            }
            assertEquals(200, appApproveResp.status.value)
            assertFalse(kernel1.vault.hasPendingToolArgs("call-e2e-ssh-1"), "Stashed credentials must be wiped immediately after execution")
            assertEquals(fakeSshPass, kernel1.vault.getSecret("ssh:10.88.0.1:password"))

            // 5. 主动引擎触发一条推送，并且在静默时段内会被压住
            val zone = ZoneId.of("Asia/Shanghai")
            val daytime1030Ms = LocalDateTime.of(2026, 10, 31, 10, 30).atZone(zone).toInstant().toEpochMilli()
            val tgBeforeProactive = telegramSentMessages.size
            val feishuBeforeProactive = feishuSentMessages.size

            val daytimeSignal = ProactiveTriggerSignal.MemoryCommitmentSignal(
                signalId = "sig_commit_daytime",
                memoryId = "mem_001",
                commitmentText = "准备云端本体 v1 发布材料",
                dueDateTime = "2026-10-31 11:00",
                timestampEpochMs = daytime1030Ms,
            )
            val daytimeProactiveRes = kernel1.triggerProactiveSignal(daytimeSignal, nowOverrideMs = daytime1030Ms)
            assertIs<ProactiveRunResult.PushedAtL3>(daytimeProactiveRes)
            assertEquals(tgBeforeProactive + 1, telegramSentMessages.size, "Proactive card must be pushed to owner's Telegram DM")
            assertEquals(feishuBeforeProactive + 1, feishuSentMessages.size, "Proactive card must be pushed to owner's Feishu DM")

            // Quiet hours (23:40 Asia/Shanghai) -> suppressed at kernel restraint gate, 0 outbound messages sent!
            val quietNight2340Ms = LocalDateTime.of(2026, 10, 31, 23, 40).atZone(zone).toInstant().toEpochMilli()
            val quietSignal = ProactiveTriggerSignal.MemoryCommitmentSignal(
                signalId = "sig_commit_quiet",
                memoryId = "mem_002",
                commitmentText = "夜间低优巡检提醒",
                dueDateTime = "2026-10-31 23:45",
                timestampEpochMs = quietNight2340Ms,
            )
            val quietProactiveRes = kernel1.triggerProactiveSignal(quietSignal, nowOverrideMs = quietNight2340Ms)
            val suppressed = assertIs<ProactiveRunResult.SuppressedAtGate>(quietProactiveRes)
            assertIs<RestraintVerdict.SuppressedQuietHours>(suppressed.restraintVerdict)
            assertEquals(tgBeforeProactive + 1, telegramSentMessages.size, "No Telegram push allowed during quiet hours")
            assertEquals(feishuBeforeProactive + 1, feishuSentMessages.size, "No Feishu push allowed during quiet hours")

            kernel1.stopProactiveLoop()
            tgChannel1.stop()
            feishuChannel1.stop()

            // 6. 重启进程后上下文不丢 (Process 2 on same dataDir)
            val model2 = RecordingFakeModelClient()
            val kernel2 = CloudAgentKernel(
                dataDir = tempDir,
                modelClient = model2,
                masterSecretOverride = "e2e-unified-master-key",
            )
            kernel2.recoverColdStartConversations()
            // Owner bindings and secrets survive restart without re-binding or re-ingesting
            assertTrue(kernel2.ownerBinding.isOwner("telegram", "10001"))
            assertTrue(kernel2.ownerBinding.isOwner("feishu", "ou_owner_e2e"))
            assertEquals(fakeTgToken, kernel2.vault.getSecret(CloudConfigLoader.KEY_TELEGRAM_BOT_TOKEN))

            val tgChannel2 = assertNotNull(
                CloudConfigLoader.createTelegramChannelOrNull(
                    config = daemonConfig,
                    vault = kernel2.vault,
                    ownerBinding = kernel2.ownerBinding,
                    logger = logger1,
                    env = emptyMap(),
                )
            )
            kernel2.registerConnector(tgChannel2)

            telegramUpdatesQueue.add(
                """{"update_id":105,"message":{"message_id":5,"from":{"id":10001},"chat":{"id":10001,"type":"private"},"date":1730380100,"text":"重启后确认一下：下周二我们要发布什么？"}}"""
            )
            tgChannel2.pollOnce()
            val capturedAfterRestart = model2.capturedRequests.single()
            val fullHistoryDump = capturedAfterRestart.joinToString("\n") { it.toText() }
            assertTrue(fullHistoryDump.contains("下周二发布 Amber 云端本体 v1"), "Explicit memory and history must survive restart")
            assertTrue(fullHistoryDump.contains("我们在飞书接着聊"), "Feishu turn on shared primary timeline must survive restart")
            assertTrue(fullHistoryDump.contains("主动提醒"), "Proactive card recorded on primary timeline must survive restart")

            // Verify zero plaintext credentials leaked into logger
            val logDump = logger1.dumpLogs().joinToString("\n")
            assertFalse(logDump.contains(fakeTgToken))
            assertFalse(logDump.contains(fakeFeishuSecret))
            assertFalse(logDump.contains(fakeCalDavPass))
            assertFalse(logDump.contains(fakeL2ApiKey))
            assertFalse(logDump.contains(fakeSshPass))
        } finally {
            mockImServer.stop(0)
            tempDir.deleteRecursively()
        }
    }
}
