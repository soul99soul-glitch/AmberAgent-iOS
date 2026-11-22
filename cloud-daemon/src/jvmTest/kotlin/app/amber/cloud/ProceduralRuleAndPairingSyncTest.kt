package app.amber.cloud

import app.amber.ai.ui.UIMessage
import app.amber.cloud.channel.ChannelKind
import app.amber.cloud.channel.ConversationScope
import app.amber.cloud.channel.InboundMessage
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.config.BootstrapEnvelopePayload
import app.amber.cloud.config.CloudConfigurationManager
import app.amber.cloud.config.CloudDaemonConfig
import app.amber.cloud.config.ConfigurationEnvelopePayload
import app.amber.cloud.config.ConfigurationImportKey
import app.amber.cloud.config.ConfigurationPatch
import app.amber.cloud.config.CredentialMutation
import app.amber.cloud.config.CredentialPatch
import app.amber.cloud.config.IssuedPairingTicketDto
import app.amber.cloud.config.ModelSettingsPatch
import app.amber.cloud.config.ManagedSearchSettings
import app.amber.cloud.config.PairingBootstrapSnapshot
import app.amber.cloud.gateway.AgentCentricApi
import app.amber.cloud.gateway.PairingPayload
import app.amber.cloud.gateway.configureCloudGateway
import app.amber.cloud.rules.ProceduralRuleListResponseDto
import app.amber.cloud.rules.ProceduralRuleRecord
import app.amber.cloud.rules.ProceduralRuleRedirectDto
import app.amber.cloud.rules.ProceduralRuleResponseDto
import app.amber.cloud.rules.ProceduralRuleStatus
import app.amber.cloud.rules.ProceduralRuleStore
import app.amber.cloud.rules.RuleProposalOutcome
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.runtime.ToolRiskLevel
import app.amber.cloud.runtime.ToolRiskPolicy
import app.amber.cloud.security.EnvelopeCredentialVault
import app.amber.cloud.soul.SoulPutRequestDto
import app.amber.core.model.MemoryKind
import app.amber.core.model.MemoryScope
import com.nimbusds.jose.EncryptionMethod
import com.nimbusds.jose.JOSEObjectType
import com.nimbusds.jose.JWEAlgorithm
import com.nimbusds.jose.JWEHeader
import com.nimbusds.jose.JWEObject
import com.nimbusds.jose.Payload
import com.nimbusds.jose.crypto.RSADecrypter
import com.nimbusds.jose.crypto.RSAEncrypter
import com.nimbusds.jose.jwk.KeyUse
import com.nimbusds.jose.jwk.RSAKey
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator
import io.ktor.client.request.bearerAuth
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.server.testing.testApplication
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ProceduralRuleAndPairingSyncTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    @Test
    fun scoped_rules_keep_distinct_ids_and_failed_writes_do_not_publish() {
        val dir = Files.createTempDirectory("amber-rule-scopes").toFile()
        try {
            val store = ProceduralRuleStore(dir)
            val instruction = "删除文件前不得跳过审批"
            fun propose(scope: String) = (store.propose(instruction, scope = scope) as RuleProposalOutcome.Proposed).rule
            val first = propose("project:Docs")
            val second = propose("project:docs")
            assertTrue(first.id != second.id)
            store.confirm(first.id)
            store.confirm(second.id)
            assertEquals(listOf(first.id), store.list(scope = "project:Docs").map { it.id })
            assertEquals(listOf(second.id), store.selectActiveForInjection(projectId = "docs").map { it.id })
            assertTrue(store.selectActiveForInjection(conversationId = "docs").isEmpty())
            assertTrue(store.selectActiveForInjection(conversationId = "project:docs").isEmpty())
            val pool = java.util.concurrent.Executors.newFixedThreadPool(4)
            try {
                val hits = List(16) { pool.submit { store.selectActiveForInjection(projectId = "docs") } }
                hits.forEach { it.get() }
            } finally { pool.shutdown() }
            assertEquals(17, ProceduralRuleStore(dir).get(second.id)?.hitCount)
            assertEquals(0, store.get(first.id)?.hitCount)
            File(dir, "procedural-rules.json.tmp").mkdir()
            assertFailsWith<java.io.IOException> { store.revoke(first.id) }
            assertEquals(ProceduralRuleStatus.ACTIVE, store.get(first.id)?.status)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun correction_proposes_only_explicit_confirm_activates_hitCount_increments_and_revoke_excludes_immediately() = runBlocking {
        val dir = Files.createTempDirectory("amber-rules-lifecycle").toFile()
        val seenSystemPrompts = CopyOnWriteArrayList<String>()
        val model = CloudModelClient { messages, _ ->
            val sys = messages.first().toText()
            if (!sys.startsWith("你是对话标签提取器")) {
                seenSystemPrompts += sys
            }
            UIMessage.assistant("收到。")
        }
        val kernel = CloudAgentKernel(dir, model, masterSecretOverride = "rules-test-master")
        try {
            // 1. User correction in chat MUST only create a `proposed` rule, never auto-activate!
            kernel.handleInbound(
                InboundMessage(
                    channel = ChannelKind.TELEGRAM,
                    chatId = "owner-chat",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    scope = ConversationScope.DIRECT,
                    text = "以后提交代码前先跑定向单测，禁止全量测试",
                    messageId = "evt-correction-1",
                )
            )
            val proposedList = kernel.proceduralRuleStore.list(status = ProceduralRuleStatus.PROPOSED)
            assertEquals(1, proposedList.size, "纠正应生成 1 条 proposed 规则卡")
            val rule = proposedList.first()
            assertEquals(ProceduralRuleStatus.PROPOSED, rule.status)
            assertEquals("evt-correction-1", rule.sourceEventId)
            assertEquals(0, rule.hitCount)
            assertEquals(0, kernel.proceduralRuleStore.list(status = ProceduralRuleStatus.ACTIVE).size)
            assertFalse(
                seenSystemPrompts.last().contains("禁止全量测试"),
                "未确认的 proposed 规则卡绝不可静默注入上下文",
            )

            // 2. Explicit user confirmation transitions proposed -> active
            val active = kernel.proceduralRuleStore.confirm(rule.id)
            assertEquals(ProceduralRuleStatus.ACTIVE, active.status)
            assertEquals(0, active.hitCount)

            // 3. Next two turns inject the confirmed rule and increment hitCount each time
            repeat(2) { turn ->
                kernel.handleInbound(
                    InboundMessage(
                        channel = ChannelKind.TELEGRAM,
                        chatId = "owner-chat",
                        senderId = "owner-1",
                        senderRole = SenderRole.OWNER,
                        scope = ConversationScope.DIRECT,
                        text = "帮我准备第 ${turn + 1} 次变更说明",
                        messageId = "evt-turn-${turn + 1}",
                    )
                )
                assertContains(seenSystemPrompts.last(), "<confirmed-procedural-rules authority=\"2\">")
                assertContains(seenSystemPrompts.last(), "禁止全量测试")
            }
            assertEquals(2, kernel.proceduralRuleStore.get(rule.id)?.hitCount)

            // Persistence across store reload
            val reloaded = ProceduralRuleStore(dir)
            assertEquals(2, reloaded.get(rule.id)?.hitCount)
            assertEquals(ProceduralRuleStatus.ACTIVE, reloaded.get(rule.id)?.status)

            // 4. Revoke -> next turn MUST 100% NOT inject the rule and hitCount stays at 2
            val revoked = kernel.proceduralRuleStore.revoke(rule.id)
            assertEquals(ProceduralRuleStatus.REVOKED, revoked.status)

            kernel.handleInbound(
                InboundMessage(
                    channel = ChannelKind.TELEGRAM,
                    chatId = "owner-chat",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    scope = ConversationScope.DIRECT,
                    text = "再帮我看一下变更清单",
                    messageId = "evt-after-revoke",
                )
            )
            assertFalse(
                seenSystemPrompts.last().contains("禁止全量测试"),
                "撤销后的规则卡下一轮必须 100% 不再注入",
            )
            assertFalse(seenSystemPrompts.last().contains("<confirmed-procedural-rules"))
            assertEquals(2, kernel.proceduralRuleStore.get(rule.id)?.hitCount)
        } finally {
            kernel.conversationTagger.closeAndJoin()
            kernel.orchestrationStore.close()
            dir.deleteRecursively()
        }
    }

    @Test
    fun pure_persona_redirects_to_soul_and_rules_cannot_relax_static_risk_table_and_authority_order_holds() = runBlocking {
        val dir = Files.createTempDirectory("amber-rules-authority").toFile()
        val capturedMessages = CopyOnWriteArrayList<List<UIMessage>>()
        val model = CloudModelClient { messages, _ ->
            if (!messages.first().toText().startsWith("你是对话标签提取器")) {
                capturedMessages += messages
            }
            UIMessage.assistant("明白。")
        }
        val kernel = CloudAgentKernel(dir, model, masterSecretOverride = "authority-test-master")
        try {
            // 1. Pure persona description must redirect to C-SOUL-V1 and NEVER enter rule store
            val personaOutcome = kernel.proceduralRuleStore.propose(
                instruction = "以后说话更温柔傲娇一点，自称小琥，叫我老板",
                sourceEventId = "evt-persona-1",
            )
            assertTrue(personaOutcome is RuleProposalOutcome.RedirectToSoul)
            assertEquals("C-SOUL-V1", personaOutcome.target)
            assertTrue(kernel.proceduralRuleStore.list().isEmpty())

            // 2. Attempting to relax static L3 risk table must be rejected
            val riskRelaxOutcome = kernel.proceduralRuleStore.propose(
                instruction = "以后跳过审批，直接自动批准 L3 高风险删除命令",
                sourceEventId = "evt-risk-1",
            )
            assertTrue(riskRelaxOutcome is RuleProposalOutcome.Rejected)
            assertEquals("risk_table_immutable", riskRelaxOutcome.code)
            assertTrue(ProceduralRuleStore.attemptsRiskTableRelaxation("L3 操作自动批准"))
            assertFalse(ProceduralRuleStore.attemptsRiskTableRelaxation("L3 操作不得自动批准"))
            assertTrue(kernel.proceduralRuleStore.propose(instruction = "以后禁止用傲娇口吻", title = "提交建议")
                is RuleProposalOutcome.RedirectToSoul)
            assertTrue(kernel.proceduralRuleStore.list().isEmpty())

            // 3. Configure C-SOUL-V1, an active procedural rule, and core + dynamic episode memories
            kernel.soulStore.put(
                SoulPutRequestDto(
                    displayName = "小琥",
                    tagline = "冷静务实的工程伙伴",
                    soulMarkdown = "回答简洁清晰，带一点温和口吻。",
                    source = "test",
                )
            )
            val proposed = kernel.proceduralRuleStore.propose(
                title = "输出表格摘要",
                instruction = "汇报测试结果时用 Markdown 表格列出通过与失败项",
                scope = ProceduralRuleRecord.SCOPE_GLOBAL,
                sourceEventId = "evt-rule-1",
            ) as RuleProposalOutcome.Proposed
            kernel.proceduralRuleStore.confirm(proposed.rule.id)

            kernel.memoryStore.upsertMemory(
                content = "用户偏好在周报中按模块汇总进度",
                scope = MemoryScope.CORE,
                kind = MemoryKind.USER,
                pinned = true,
            )
            kernel.memoryStore.upsertMemory(
                content = "昨天讨论过打包耗时需要排查",
                scope = MemoryScope.LONG_TERM,
                kind = MemoryKind.NOTE,
            )

            kernel.handleInbound(
                InboundMessage(
                    channel = ChannelKind.TELEGRAM,
                    chatId = "owner-chat",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    scope = ConversationScope.DIRECT,
                    text = "请汇总今天的打包耗时与测试结果",
                    messageId = "evt-authority-check",
                )
            )

            val msgs = capturedMessages.last()
            val systemPrompt = msgs.first().toText()
            val idxRisk = systemPrompt.indexOf("<static-risk-table authority=\"1\"")
            val idxRules = systemPrompt.indexOf("<confirmed-procedural-rules authority=\"2\">")
            val idxSoul = systemPrompt.indexOf("<agent-soul")
            val idxCoreEpisode = systemPrompt.indexOf("<core-memory>")

            assertTrue(idxRisk >= 0, "缺少 Layer 1 静态风险表")
            assertTrue(idxRules > idxRisk, "Layer 2 确认规则必须排在 Layer 1 静态风险表之后")
            assertTrue(idxSoul > idxRules, "Layer 3 C-SOUL-V1 必须排在 Layer 2 确认规则之后")
            assertTrue(idxCoreEpisode > idxSoul, "Layer 4 Episode 核心记忆必须排在 Layer 3 C-SOUL-V1 之后")

            val lastUserPrompt = msgs.last().toText()
            assertContains(lastUserPrompt, "<memory-context>")
            assertContains(lastUserPrompt, "打包耗时")

            // Static L3 classification remains unchanged despite active rules & custom soul
            assertEquals(ToolRiskLevel.L3, ToolRiskPolicy.classify("shell_exec"))
            assertEquals(ToolRiskLevel.L3, ToolRiskPolicy.classify("plugin_install"))
        } finally {
            kernel.conversationTagger.closeAndJoin()
            kernel.orchestrationStore.close()
            dir.deleteRecursively()
        }
    }

    @Test
    fun rest_api_rules_lifecycle_and_single_scan_pairing_jwe_bootstrap_sync_with_secret_redaction() = testApplication {
        val dir = Files.createTempDirectory("amber-stage3-http").toFile()
        val vault = EnvelopeCredentialVault(File(dir, "secrets.enc.json"), masterSecretOverride = "stage3-vault-master")
        val bootstrapCfg = CloudDaemonConfig(
            modelProvider = "openai",
            modelId = "gpt-5",
            modelBaseUrl = "https://api.openai.com/v1",
            searchSources = "bing,exa",
            searchMode = "fallback",
        )
        val nowSec = 1_760_000_000L
        val gatewayId = app.amber.cloud.gateway.CloudGatewayState(dir).identity.id
        val alignedConfigManager = CloudConfigurationManager(
            vault = vault,
            gatewayId = gatewayId,
            bootstrap = bootstrapCfg,
            clockSeconds = { nowSec },
            modelFactory = { _, _ -> CloudModelClient { _, _ -> UIMessage.assistant("ok") } },
        )
        val kernel2 = CloudAgentKernel(
            dataDir = dir,
            modelClient = alignedConfigManager.modelClient,
            masterSecretOverride = "stage3-vault-master",
            configurationManager = alignedConfigManager,
            vaultOverride = vault,
        )

        application {
            configureCloudGateway(
                state = kernel2.gatewayState,
                agentApi = AgentCentricApi(kernel2),
                gatewayPort = 47821,
                publicAddresses = listOf("mac.tailnet.ts.net"),
            )
        }

        try {
            // Pair initial Mac management device
            val state = kernel2.gatewayState
            val retryTicket = state.issuePairingTicket()
            val failure = state.pairDevice(retryTicket, "ios", "fixture") { error("fixture export unavailable") }
            assertTrue(failure is app.amber.cloud.gateway.CloudGatewayState.PairResult.ServerError)
            assertTrue(state.loadDevicesStrict().isEmpty())
            assertTrue(state.pairDevice(retryTicket, "ios", "fixture") is app.amber.cloud.gateway.CloudGatewayState.PairResult.Success)
            val macSecret = kernel2.gatewayState.issuePairingTicket()
            val macPairResp = client.post("/v1/pair") {
                contentType(ContentType.Application.Json)
                setBody("""{"secret":"$macSecret","platform":"macos","deviceName":"Arquiel Mac"}""")
            }
            assertEquals(200, macPairResp.status.value)
            val macPairJson = json.parseToJsonElement(macPairResp.bodyAsText()).jsonObject
            assertEquals(setOf("deviceId", "token", "gatewayId", "gatewayName"), macPairJson.keys)
            val macToken = macPairJson["token"]!!.jsonPrimitive.content

            val viewer = kernel2.gatewayState.pairDevice(kernel2.gatewayState.issuePairingTicket(), "linux", "viewer")
                as app.amber.cloud.gateway.CloudGatewayState.PairResult.Success
            assertEquals(403, client.get("/v2/rules") { bearerAuth(viewer.token) }.status.value)
            assertEquals(403, client.post("/v2/rules/example/confirm") { bearerAuth(viewer.token) }.status.value)

            // Push an encrypted provider config (with real secrets + SIWC metadata) via existing JWE channel
            val importKeyResp = client.get("/v2/configuration/import-key") { bearerAuth(macToken) }
            assertEquals(200, importKeyResp.status.value)
            val importKey = json.decodeFromString<ConfigurationImportKey>(importKeyResp.bodyAsText())
            val secretModelKey = "sk-live-stage3-super-secret-99887766"
            val secretExaKey = "exa-secret-stage3-11223344"
            val envelopePayload = ConfigurationEnvelopePayload(
                version = 1,
                gatewayId = importKey.gatewayId,
                deviceId = importKey.deviceId,
                requestId = "req-stage3-init",
                expectedRevision = 0,
                issuedAt = nowSec,
                expiresAt = nowSec + 300,
                configuration = ConfigurationPatch(
                    model = ModelSettingsPatch(
                        provider = "openai",
                        modelId = "gpt-5.2",
                        baseUrl = "https://api.openai.com/v1",
                        authMode = "chatgptSiwc",
                        siwcConfigured = true,
                    ),
                    search = ManagedSearchSettings(sources = listOf("bing", "exa"), mode = "fallback"),
                ),
                credentials = CredentialPatch(
                    modelApiKey = CredentialMutation("replace", secretModelKey),
                    exaApiKey = CredentialMutation("replace", secretExaKey),
                ),
            )
            val serverPubKey = RSAKey.parse(importKey.publicJwk.toString()).toRSAPublicKey()
            val sealedConfig = JWEObject(
                JWEHeader.Builder(JWEAlgorithm.RSA_OAEP_256, EncryptionMethod.A256GCM)
                    .keyID(importKey.kid)
                    .type(JOSEObjectType("amber-config+jwe"))
                    .build(),
                Payload(json.encodeToString(envelopePayload)),
            ).apply { encrypt(RSAEncrypter(serverPubKey)) }.serialize()

            val applyResp = client.post("/v2/configuration") {
                bearerAuth(macToken)
                contentType(ContentType.Application.Json)
                setBody(buildJsonObject { put("jwe", sealedConfig) }.toString())
            }
            assertEquals(200, applyResp.status.value)

            val rename = envelopePayload.copy(requestId = "rename-model", expectedRevision = 1,
                configuration = ConfigurationPatch(model = ModelSettingsPatch("openai", "renamed-model", "https://api.openai.com/v1")),
                credentials = null)
            val renameJwe = JWEObject(JWEObject.parse(sealedConfig).header, Payload(json.encodeToString(rename)))
                .apply { encrypt(RSAEncrypter(serverPubKey)) }.serialize()
            val renamed = client.post("/v2/configuration") {
                bearerAuth(macToken)
                setBody(buildJsonObject { put("jwe", renameJwe) }.toString())
            }
            assertEquals(200, renamed.status.value)

            // Update C-SOUL-V1 so revision > 0
            kernel2.soulStore.put(
                SoulPutRequestDto(
                    displayName = "Amber-Stage3",
                    tagline = "单次扫码即同步",
                    soulMarkdown = "保持简洁精准。",
                    source = "macos_ui",
                )
            )

            // Exercise REST /v2/rules: persona redirect (422), propose (201), confirm (200), archive/revoke (200)
            val personaResp = client.post("/v2/rules/propose") {
                bearerAuth(macToken)
                contentType(ContentType.Application.Json)
                setBody("""{"instruction":"你以后扮演高冷管家，用温柔口吻叫我主人"}""")
            }
            assertEquals(422, personaResp.status.value)
            val redirectDto = json.decodeFromString<ProceduralRuleRedirectDto>(personaResp.bodyAsText())
            assertTrue(redirectDto.redirectToSoul)
            assertEquals("C-SOUL-V1", redirectDto.target)

            val propActiveResp = client.post("/v2/rules/propose") {
                bearerAuth(macToken)
                contentType(ContentType.Application.Json)
                setBody("""{"title":"先列变更清单","instruction":"修改代码前先列出受影响文件清单","scope":"global","sourceEventId":"evt-http-1"}""")
            }
            assertEquals(201, propActiveResp.status.value)
            val activeRuleId = json.decodeFromString<ProceduralRuleResponseDto>(propActiveResp.bodyAsText()).rule.id

            val confirmResp = client.post("/v2/rules/$activeRuleId/confirm") { bearerAuth(macToken) }
            assertEquals(200, confirmResp.status.value)
            assertEquals(
                ProceduralRuleStatus.ACTIVE,
                json.decodeFromString<ProceduralRuleResponseDto>(confirmResp.bodyAsText()).rule.status,
            )

            // Also create one proposed and one revoked rule — neither may leak into bootstrap activeRules!
            val propPendingResp = client.post("/v2/rules/propose") {
                bearerAuth(macToken)
                contentType(ContentType.Application.Json)
                setBody("""{"title":"待确认规则","instruction":"每次输出附带耗时统计","scope":"global"}""")
            }
            assertEquals(201, propPendingResp.status.value)

            val propRevokedResp = client.post("/v2/rules/propose") {
                bearerAuth(macToken)
                contentType(ContentType.Application.Json)
                setBody("""{"title":"已撤销规则","instruction":"所有结论用英文输出","scope":"global"}""")
            }
            val revokedId = json.decodeFromString<ProceduralRuleResponseDto>(propRevokedResp.bodyAsText()).rule.id
            assertEquals(200, client.post("/v2/rules/$revokedId/confirm") { bearerAuth(macToken) }.status.value)
            assertEquals(200, client.post("/v2/rules/$revokedId/revoke") { bearerAuth(macToken) }.status.value)

            val listResp = client.get("/v2/rules") { bearerAuth(macToken) }
            assertEquals(200, listResp.status.value)
            val listDto = json.decodeFromString<ProceduralRuleListResponseDto>(listResp.bodyAsText())
            assertEquals(1, listDto.activeCount)
            assertEquals(1, listDto.proposedCount)
            assertEquals(3, listDto.rules.size)

            // Issue single-scan pairing QR from Mac
            val issueResp = client.post("/v2/pairing/issue") { bearerAuth(macToken) }
            assertEquals(200, issueResp.status.value)
            val issued = json.decodeFromString<IssuedPairingTicketDto>(issueResp.bodyAsText())
            assertTrue(issued.deepLinkUrl.startsWith("amber://gateway/pair?p="))
            assertTrue(issued.bootstrap.syncSupported)
            assertEquals(2, issued.bootstrap.configRevision)
            assertEquals("openai", issued.bootstrap.provider)
            assertEquals("chatgptSiwc", issued.bootstrap.authMode)
            assertTrue(issued.bootstrap.siwcConfigured)
            assertTrue(issued.bootstrap.hasEncryptedCredentials)
            assertEquals(1L, issued.bootstrap.soulRevision)
            assertEquals(1, issued.bootstrap.activeRulesCount)

            // Secret redaction check on QR URL + parsed payload
            assertFalse(issued.deepLinkUrl.contains(secretModelKey), "QR URL 绝不可包含明文模型 Key")
            assertFalse(issued.deepLinkUrl.contains(secretExaKey), "QR URL 绝不可包含明文 Exa Key")
            val parsedQr = PairingPayload.parse(issued.deepLinkUrl)
            assertNotNull(parsedQr)
            val rows = app.amber.cloud.gateway.TerminalQrGenerator.renderAnsi(issued.deepLinkUrl).trimEnd('\n').lines()
                .map { it.removePrefix("\u001B[30;47m").removeSuffix("\u001B[0m") }
            // Recover modules from the printed upper/lower half blocks, excluding the four-module quiet zone.
            val modules = com.google.zxing.common.BitMatrix(rows.first().length - 8)
            for (y in 0 until modules.height) {
                val row = rows[(y + 4) / 2]
                for (x in 0 until modules.width) {
                    val block = row[x + 4]
                    if (block == '█' || block == (if (y % 2 == 0) '▀' else '▄')) modules.set(x, y)
                }
            }
            assertEquals(issued.deepLinkUrl, com.google.zxing.qrcode.decoder.Decoder().decode(modules).text)
            assertEquals(issued.bootstrap, parsedQr.bootstrap)
            assertFalse(parsedQr.toString().contains(secretModelKey))

            // Verify PairingPayload explicitly rejects smuggled plaintext keys
            assertFailsWith<IllegalArgumentException> {
                PairingPayload(
                    id = "gw",
                    name = "gw",
                    addrs = listOf("127.0.0.1"),
                    port = 47821,
                    fp = "fp",
                    s = "secret",
                    bootstrap = issued.bootstrap.copy(provider = "sk-live-leaked-key-1234567890"),
                ).deepLinkUrl
            }

            // Generate ephemeral phone RSA keypair for single-scan JWE bootstrap
            val phoneRsa = RSAKeyGenerator(2048)
                .keyUse(KeyUse.ENCRYPTION)
                .algorithm(JWEAlgorithm.RSA_OAEP_256)
                .keyID("phone-ephemeral-1")
                .generate()

            // First test: passing a private JWK parameter (`d`) MUST be rejected (400) WITHOUT burning the pairing ticket!
            val badJwkResp = client.post("/v1/pair") {
                contentType(ContentType.Application.Json)
                setBody(
                    buildJsonObject {
                        put("secret", parsedQr.s)
                        put("platform", "ios")
                        put("deviceName", "Bad Client")
                        put("requestBootstrapSync", true)
                        put("clientPublicJwk", json.parseToJsonElement(phoneRsa.toJSONString()))
                    }.toString()
                )
            }
            assertEquals(400, badJwkResp.status.value)

            val invalidRole = client.post("/v1/pair") {
                contentType(ContentType.Application.Json)
                setBody("""{"secret":"${parsedQr.s}","platform":"ios","nodeRole":"unsupported"}""")
            }
            assertEquals(400, invalidRole.status.value)

            // Now perform the real single-scan pair with public JWK only
            val phonePairResp = client.post("/v1/pair") {
                contentType(ContentType.Application.Json)
                setBody(
                    buildJsonObject {
                        put("secret", parsedQr.s)
                        put("platform", "ios")
                        put("deviceName", "New iPhone 17")
                        put("requestBootstrapSync", true)
                        put("clientPublicJwk", json.parseToJsonElement(phoneRsa.toPublicJWK().toJSONString()))
                    }.toString()
                )
            }
            assertEquals(200, phonePairResp.status.value)
            val phoneBodyText = phonePairResp.bodyAsText()
            // Top-level JSON MUST NOT contain plaintext secrets!
            assertFalse(phoneBodyText.contains(secretModelKey), "响应明文 JSON 不得暴露 API Key")
            assertFalse(phoneBodyText.contains(secretExaKey), "响应明文 JSON 不得暴露 Exa Key")

            val phonePairJson = json.parseToJsonElement(phoneBodyText).jsonObject
            val phoneDeviceId = phonePairJson["deviceId"]!!.jsonPrimitive.content
            val phoneToken = phonePairJson["token"]!!.jsonPrimitive.content
            val bootstrap = json.decodeFromString<PairingBootstrapSnapshot>(phonePairJson["bootstrap"].toString())

            // Verify C-SOUL-V1 & active-only rules snapshot
            assertEquals(1L, bootstrap.soul?.revision)
            assertEquals("Amber-Stage3", bootstrap.soul?.displayName)
            assertEquals(1, bootstrap.activeRules.size)
            assertEquals(activeRuleId, bootstrap.activeRules.single().id)
            assertEquals(ProceduralRuleStatus.ACTIVE, bootstrap.activeRules.single().status)

            // Verify non-secret configuration metadata + SIWC fields
            assertEquals("chatgptSiwc", bootstrap.configuration?.model?.authMode)
            assertEquals(true, bootstrap.configuration?.model?.siwcConfigured)
            assertEquals(true, bootstrap.configuration?.credentials?.modelApiKey?.configured)
            assertNotNull(bootstrap.importKey)

            // Decrypt the JWE with phone's private key and verify full credential recovery
            val jweText = assertNotNull(bootstrap.encryptedConfigJwe)
            val parsedJwe = JWEObject.parse(jweText)
            assertEquals(JWEAlgorithm.RSA_OAEP_256, parsedJwe.header.algorithm)
            assertEquals(EncryptionMethod.A256GCM, parsedJwe.header.encryptionMethod)
            assertEquals("amber-bootstrap+jwe", parsedJwe.header.type.type)
            parsedJwe.decrypt(RSADecrypter(phoneRsa.toRSAPrivateKey()))
            val decrypted = json.decodeFromString<BootstrapEnvelopePayload>(parsedJwe.payload.toString())
            assertEquals(kernel2.gatewayState.identity.id, decrypted.gatewayId)
            assertEquals(phoneDeviceId, decrypted.deviceId)
            assertEquals("openai", decrypted.model.provider)
            assertEquals("renamed-model", decrypted.model.modelId)
            assertEquals("chatgptSiwc", decrypted.model.authMode)
            assertTrue(decrypted.model.siwcConfigured)
            assertEquals(secretModelKey, decrypted.credentials.modelApiKey)
            assertEquals(secretExaKey, decrypted.credentials.exaApiKey)
            assertNull(decrypted.credentials.braveApiKey)

            // Single-use invariant: re-using the same QR secret fails with 403
            val replayResp = client.post("/v1/pair") {
                contentType(ContentType.Application.Json)
                setBody("""{"secret":"${parsedQr.s}","platform":"ios","deviceName":"Replay"}""")
            }
            assertEquals(403, replayResp.status.value)

            // Audit log must NEVER contain plaintext keys
            val auditText = kernel2.gatewayState.auditFile.readText()
            assertFalse(auditText.contains(secretModelKey), "审计日志绝不可包含明文模型 Key")
            assertFalse(auditText.contains(secretExaKey), "审计日志绝不可包含明文 Exa Key")
            assertContains(auditText, "pair-bootstrap-sync")

            // Authenticated bootstrap re-sync endpoint also works for the newly paired phone
            val resyncResp = client.post("/v2/pairing/bootstrap-sync") {
                bearerAuth(phoneToken)
                contentType(ContentType.Application.Json)
                setBody(buildJsonObject {
                    put("clientPublicJwk", json.parseToJsonElement(phoneRsa.toPublicJWK().toJSONString()))
                }.toString())
            }
            assertEquals(200, resyncResp.status.value)
            val resyncSnapshot = json.decodeFromString<PairingBootstrapSnapshot>(resyncResp.bodyAsText())
            assertNotNull(resyncSnapshot.encryptedConfigJwe)
            assertEquals(1, resyncSnapshot.activeRules.size)
        } finally {
            kernel2.conversationTagger.closeAndJoin()
            kernel2.orchestrationStore.close()
            dir.deleteRecursively()
        }
    }
}
