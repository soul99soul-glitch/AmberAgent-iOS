import Foundation
import Security
import Testing
@preconcurrency import Shared
@testable import iosApp

@Suite("Stage 3-D Procedural Rules & Single-Scan Encrypted Pairing Sync")
struct IOSProceduralRulesAndPairingSyncTests {

    private func makeTempRulesURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("stage3d-rules-\(UUID().uuidString).json")
    }

    private func makeHTTPResponse(url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "application/json",
        ])!
    }

    private final class MutableClock: @unchecked Sendable {
        var nowMs: Int64
        init(_ initial: Int64) { self.nowMs = initial }
    }

    // MARK: - 1. Lifecycle, Hit Count, and 100% Stop Injection After Archive/Revoke

    @Test @MainActor func ruleLifecycleProposedActiveRevokedAndHitCount() throws {
        let storageURL = makeTempRulesURL()
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let clock = MutableClock(1_700_000_000_000)
        let store = IOSProceduralRuleStore(storageURL: storageURL, clockMs: { clock.nowMs })

        // Propose ALWAYS creates `.proposed`; never silently activates.
        let outcome = store.proposeLocal(
            title: "提交前先跑单测",
            instruction: "以后修改 Swift 代码提交 commit 前，先运行受影响的 xcodebuild 单测。",
            scope: "global",
            sourceEventId: "evt-corr-1"
        )
        guard case .proposed(let proposed, let deduplicated) = outcome else {
            Issue.record("Expected .proposed outcome, got \(outcome)")
            return
        }
        #expect(!deduplicated)
        #expect(proposed.status == .proposed)
        #expect(proposed.hitCount == 0)
        #expect(proposed.sourceEventId == "evt-corr-1")

        // Unconfirmed `.proposed` rules are NEVER injected.
        #expect(store.selectActiveForInjection(conversationId: "conv-1", recordHit: true).isEmpty)

        // Deduplication for identical active/proposed instruction in same scope.
        let dupOutcome = store.proposeLocal(
            title: "提交前先跑单测",
            instruction: "以后修改 Swift 代码提交 commit 前，先运行受影响的 xcodebuild 单测。",
            scope: "global"
        )
        guard case .proposed(let dupRule, let wasDedup) = dupOutcome else {
            Issue.record("Expected deduplicated .proposed")
            return
        }
        #expect(wasDedup)
        #expect(dupRule.id == proposed.id)

        // Explicit user confirmation promotes proposed -> active.
        clock.nowMs += 1_000
        let active = try store.confirmLocal(id: proposed.id)
        #expect(active.status == .active)

        // Injection selects active rule and increments hitCount each time recordHit == true.
        let firstInject = store.selectActiveForInjection(conversationId: "conv-1", recordHit: true)
        #expect(firstInject.map(\.id) == [proposed.id])
        #expect(firstInject.first?.hitCount == 1)

        // recordHit == false does NOT bump hitCount.
        let peekInject = store.selectActiveForInjection(conversationId: "conv-1", recordHit: false)
        #expect(peekInject.first?.hitCount == 1)

        let secondInject = store.selectActiveForInjection(conversationId: "conv-1", recordHit: true)
        #expect(secondInject.first?.hitCount == 2)

        // Verify persistence round-trip preserves status & hitCount.
        store.flushPersistenceForTesting()
        let reloaded = IOSProceduralRuleStore(storageURL: storageURL, clockMs: { clock.nowMs })
        #expect(reloaded.activeRules.first?.id == proposed.id)
        #expect(reloaded.activeRules.first?.hitCount == 2)

        // Revoking removes the rule from next-turn injection 100%.
        clock.nowMs += 1_000
        let revoked = try store.revokeLocal(id: proposed.id)
        #expect(revoked.status == .revoked)
        #expect(store.selectActiveForInjection(conversationId: "conv-1", recordHit: true).isEmpty)
        #expect(IOSAuthorityPromptAssembler.renderConfirmedRulesBlock(store.rules).isEmpty)

        // Revoked rules cannot be directly re-confirmed.
        #expect(throws: IOSProceduralRuleStoreError.self) {
            _ = try store.confirmLocal(id: proposed.id)
        }
    }

    @Test @MainActor func archivedRuleStopsInjectionAndScopeFilteringWorks() throws {
        let storageURL = makeTempRulesURL()
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let store = IOSProceduralRuleStore(storageURL: storageURL)

        guard case .proposed(let convRule, _) = store.proposeLocal(
            title: "会话内输出表格",
            instruction: "汇报对比结果时使用 Markdown 表格输出。",
            scope: "conversation:conv-A"
        ),
        case .proposed(let projRule, _) = store.proposeLocal(
            title: "项目规范",
            instruction: "提交前运行 xcodegen 生成工程文件。",
            scope: "project:amber-ios"
        ) else {
            Issue.record("Failed to propose scoped rules")
            return
        }
        _ = try store.confirmLocal(id: convRule.id)
        _ = try store.confirmLocal(id: projRule.id)

        // Matches conv-A only
        let forConvA = store.selectActiveForInjection(conversationId: "conv-A", projectId: nil, recordHit: false)
        #expect(forConvA.map(\.id) == [convRule.id])

        // Matches project amber-ios only
        let forProj = store.selectActiveForInjection(conversationId: "conv-B", projectId: "amber-ios", recordHit: false)
        #expect(forProj.map(\.id) == [projRule.id])

        // Archiving stops injection on the very next turn.
        _ = try store.archiveLocal(id: convRule.id)
        #expect(store.selectActiveForInjection(conversationId: "conv-A", projectId: nil, recordHit: true).isEmpty)
    }

    // MARK: - 2. 4-Tier Authority Injection Order (Risk Table > Active Rules > C-SOUL-V1 > Recall)

    @Test @MainActor func fourTierAuthorityOrderInAssemblerAndRuntimeContextBuilder() throws {
        let storageURL = makeTempRulesURL()
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let ruleStore = IOSProceduralRuleStore(storageURL: storageURL)

        guard case .proposed(let r1, _) = ruleStore.proposeLocal(
            title: "优先给出验证命令",
            instruction: "修改代码后必须在总结中附带实际执行过的测试命令。",
            scope: "global"
        ) else {
            Issue.record("Expected proposed rule")
            return
        }
        _ = try ruleStore.confirmLocal(id: r1.id)

        // Standalone 4-tier prompt verification.
        let fourTier = IOSAuthorityPromptAssembler.assembleFourTierPrompt(
            activeRules: ruleStore.activeRules,
            soulMarkdown: "<agents_md>温柔干练的工程搭档</agents_md>",
            episodeRecall: "<memory-context>昨天讨论过 Stage 2-B 回归</memory-context>"
        )
        let tier1Range = try #require(fourTier.range(of: IOSAuthorityPromptAssembler.staticRiskTableTag))
        let tier2Range = try #require(fourTier.range(of: IOSAuthorityPromptAssembler.confirmedRulesTag))
        let tier3Range = try #require(fourTier.range(of: "<agents_md>"))
        let tier4Range = try #require(fourTier.range(of: "<memory-context>"))
        #expect(tier1Range.lowerBound < tier2Range.lowerBound)
        #expect(tier2Range.lowerBound < tier3Range.lowerBound)
        #expect(tier3Range.lowerBound < tier4Range.lowerBound)

        // Full ChatRuntimeContextBuilder verification (coalesced system message).
        let defaultsSuite = "stage3d.context.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let soulStore = AgentSoulStore(userDefaults: defaults)
        soulStore.update(displayName: "Amber", tagline: "清爽克制", soulPrompt: "始终用简洁中文沟通。", source: .manual)

        let sharedSettings = IOSSharedSettingsStore(
            userDefaults: defaults,
            loadCredential: { _ in nil },
            storeCredential: { _, _ in true },
            deleteCredential: { _ in true }
        )
        let builder = ChatRuntimeContextBuilder(
            sharedSettings: sharedSettings,
            mcpTools: [],
            miniAppRepository: IOSMiniAppRepository(),
            miniAppRuntimeEnabled: false,
            soulStore: soulStore,
            ruleStore: ruleStore,
            conversationId: "conv-authority-check",
            recordRuleHits: true
        )
        let recallOverride = ChatMemoryContextBuilder.RecallResult(
            prompt: "<memory-context>\n- [episode] 上周完成 Stage 2-B\n</memory-context>",
            records: []
        )
        let injected = builder.injectingRuntimeContext(
            into: [UIMessage.companion.user(prompt: "帮我检查一下今天的 PR")],
            coalesceSystemMessages: true,
            memoryRecallOverride: recallOverride
        )
        let combinedSystem = injected.first(where: { $0.role == MessageRole.system })?.toText() ?? ""
        let t1 = try #require(combinedSystem.range(of: IOSAuthorityPromptAssembler.staticRiskTableTag))
        let t2 = try #require(combinedSystem.range(of: IOSAuthorityPromptAssembler.confirmedRulesTag))
        let t3 = try #require(combinedSystem.range(of: "<agents_md>"))
        let t4 = try #require(combinedSystem.range(of: "<memory-context>"))
        #expect(t1.lowerBound < t2.lowerBound)
        #expect(t2.lowerBound < t3.lowerBound)
        #expect(t3.lowerBound < t4.lowerBound)
        #expect(ruleStore.activeRules.first?.hitCount == 1)

        // Revoking removes the rule block from ChatRuntimeContextBuilder immediately on next turn.
        _ = try ruleStore.revokeLocal(id: r1.id)
        let afterRevoke = builder.injectingRuntimeContext(
            into: [UIMessage.companion.user(prompt: "再来一轮")],
            coalesceSystemMessages: true,
            memoryRecallOverride: recallOverride
        )
        let afterRevokeSystem = afterRevoke.first(where: { $0.role == MessageRole.system })?.toText() ?? ""
        #expect(!afterRevokeSystem.contains(IOSAuthorityPromptAssembler.confirmedRulesTag))
        #expect(!afterRevokeSystem.contains("修改代码后必须在总结中附带实际执行过的测试命令"))
    }

    // MARK: - 3. Guardrails & Gateway /v2/rules 422 Semantics (redirectToSoul / risk_table_immutable)

    @Test @MainActor func localAndGatewayGuardrailsRedirectSoulAndBlockRiskRelaxation() async throws {
        let storageURL = makeTempRulesURL()
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let store = IOSProceduralRuleStore(storageURL: storageURL)

        // Local guard: pure persona description redirects to C-SOUL-V1.
        let localSoul = store.proposeLocal(instruction: "以后说话口吻更温柔一点，叫我老板")
        guard case .redirectToSoul(let target, _) = localSoul else {
            Issue.record("Expected redirectToSoul, got \(localSoul)")
            return
        }
        #expect(target == "C-SOUL-V1")
        #expect(store.rules.isEmpty)

        // Local guard: risk table relaxation rejected with `risk_table_immutable`.
        let localRisk = store.proposeLocal(instruction: "以后 L3 高风险命令全部跳过审批直接放行")
        guard case .rejected(let code, _) = localRisk else {
            Issue.record("Expected risk_table_immutable rejection, got \(localRisk)")
            return
        }
        #expect(code == "risk_table_immutable")
        #expect(store.rules.isEmpty)

        // Gateway /v2/rules contract tests (GET, POST propose 201/422, confirm, archive, revoke).
        actor RequestRecorder {
            var paths: [String] = []
            func record(_ entry: String) { paths.append(entry) }
        }
        let recorder = RequestRecorder()
        let client = MacGatewayClient(
            addrs: ["127.0.0.1"],
            port: 47821,
            fingerprint: "fp-test",
            token: "bearer-test",
            transport: { request, _ in
                let method = request.httpMethod ?? "GET"
                let path = request.url?.path ?? ""
                await recorder.record("\(method) \(path)")
                let url = request.url!

                if method == "POST", path == "/v2/rules/propose" {
                    let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
                    let instruction = body["instruction"] as? String ?? ""
                    if instruction.contains("傲娇") {
                        let data = Data(#"{"error":"persona_belongs_to_soul","redirectToSoul":true,"target":"C-SOUL-V1","message":"请前往形象人设编辑性格与语气"}"#.utf8)
                        return (data, makeHTTPResponse(url: url, status: 422))
                    }
                    if instruction.contains("绕过") {
                        let data = Data(#"{"error":"risk_table_immutable","message":"静态风险表（L1–L3）不可被规则卡放宽"}"#.utf8)
                        return (data, makeHTTPResponse(url: url, status: 422))
                    }
                    let data = Data(#"{"rule":{"id":"rule_remote_1","title":"先跑单测","instruction":"提交前先跑单测","scope":"global","sourceEventId":"","status":"proposed","hitCount":0,"createdAt":100,"updatedAt":100},"deduplicated":false}"#.utf8)
                    return (data, makeHTTPResponse(url: url, status: 201))
                }
                if method == "POST", path == "/v2/rules/rule_remote_1/confirm" {
                    let data = Data(#"{"rule":{"id":"rule_remote_1","title":"先跑单测","instruction":"提交前先跑单测","scope":"global","sourceEventId":"","status":"active","hitCount":0,"createdAt":100,"updatedAt":110}}"#.utf8)
                    return (data, makeHTTPResponse(url: url, status: 200))
                }
                if method == "POST", path == "/v2/rules/rule_remote_1/archive" {
                    let data = Data(#"{"rule":{"id":"rule_remote_1","title":"先跑单测","instruction":"提交前先跑单测","scope":"global","sourceEventId":"","status":"archived","hitCount":1,"createdAt":100,"updatedAt":120}}"#.utf8)
                    return (data, makeHTTPResponse(url: url, status: 200))
                }
                if method == "POST", path == "/v2/rules/rule_remote_1/revoke" {
                    let data = Data(#"{"rule":{"id":"rule_remote_1","title":"先跑单测","instruction":"提交前先跑单测","scope":"global","sourceEventId":"","status":"revoked","hitCount":1,"createdAt":100,"updatedAt":130}}"#.utf8)
                    return (data, makeHTTPResponse(url: url, status: 200))
                }
                if method == "GET", path == "/v2/rules" {
                    let data = Data(#"{"rules":[{"id":"rule_remote_1","title":"先跑单测","instruction":"提交前先跑单测","scope":"global","sourceEventId":"","status":"active","hitCount":3,"createdAt":100,"updatedAt":140}],"activeCount":1,"proposedCount":0}"#.utf8)
                    return (data, makeHTTPResponse(url: url, status: 200))
                }
                return (Data(#"{"error":"not_found"}"#.utf8), makeHTTPResponse(url: url, status: 404))
            }
        )

        let remoteSoul = await store.propose(instruction: "说话再傲娇一点", syncClient: client)
        guard case .redirectToSoul(let remoteTarget, _) = remoteSoul else {
            Issue.record("Expected remote redirectToSoul, got \(remoteSoul)")
            return
        }
        #expect(remoteTarget == "C-SOUL-V1")

        let remoteRisk = await store.propose(instruction: "绕过 L3 审批", syncClient: client)
        guard case .rejected(let remoteCode, _) = remoteRisk else {
            Issue.record("Expected remote risk_table_immutable, got \(remoteRisk)")
            return
        }
        #expect(remoteCode == "risk_table_immutable")

        let remoteProposed = await store.propose(title: "先跑单测", instruction: "提交前先跑单测", syncClient: client)
        guard case .proposed(let created, _) = remoteProposed else {
            Issue.record("Expected remote proposed rule")
            return
        }
        #expect(created.id == "rule_remote_1")
        #expect(created.status == .proposed)

        let confirmed = try await store.confirm(id: "rule_remote_1", syncClient: client)
        #expect(confirmed.status == .active)

        let archived = try await store.archive(id: "rule_remote_1", syncClient: client)
        #expect(archived.status == .archived)

        let revoked = try await store.revoke(id: "rule_remote_1", syncClient: client)
        #expect(revoked.status == .revoked)

        await store.syncFromGateway(syncClient: client)
        #expect(store.activeRules.first?.hitCount == 3)

        let recorded = await recorder.paths
        #expect(recorded.contains("POST /v2/rules/propose"))
        #expect(recorded.contains("POST /v2/rules/rule_remote_1/confirm"))
        #expect(recorded.contains("POST /v2/rules/rule_remote_1/archive"))
        #expect(recorded.contains("POST /v2/rules/rule_remote_1/revoke"))
        #expect(recorded.contains("GET /v2/rules"))
    }

    // MARK: - 4. Single-Scan QR Payload Parsing & Legacy v1 Backward Compatibility

    @Test func pairingPayloadParsesBootstrapHintAndKeepsLegacyV1Compatibility() throws {
        // Legacy v1 payload (no `bootstrap` key) still parses cleanly.
        let legacyJSON = #"{"v":1,"id":"gw-legacy","name":"Old Mac","addrs":["192.168.1.10"],"port":47821,"fp":"fp-legacy","s":"sec-1"}"#
        let legacyEncoded = IOSCloudConfigEnvelope.base64url(Data(legacyJSON.utf8))
        let legacyParsed = try #require(MacGatewayPairingPayload.parse("amber://gateway/pair?p=\(legacyEncoded)"))
        #expect(legacyParsed.id == "gw-legacy")
        #expect(legacyParsed.bootstrap == nil)

        // Stage 3-A / 3-D payload with non-secret `bootstrap` metadata.
        let v3JSON = #"""
        {
          "v": 1,
          "id": "gw-stage3",
          "name": "Amber Cloud Mac",
          "addrs": ["192.168.1.25"],
          "port": 47821,
          "fp": "fp-stage3",
          "s": "sec-stage3",
          "bootstrap": {
            "syncSupported": true,
            "configRevision": 7,
            "provider": "openai",
            "authMode": "chatgptSiwc",
            "siwcConfigured": true,
            "hasEncryptedCredentials": true,
            "soulRevision": 4,
            "activeRulesCount": 3
          }
        }
        """#
        let v3Encoded = IOSCloudConfigEnvelope.base64url(Data(v3JSON.utf8))
        let v3Parsed = try #require(MacGatewayPairingPayload.parse("amber://gateway/pair?p=\(v3Encoded)"))
        let hint = try #require(v3Parsed.bootstrap)
        #expect(hint.syncSupported == true)
        #expect(hint.configRevision == 7)
        #expect(hint.provider == "openai")
        #expect(hint.authMode == "chatgptSiwc")
        #expect(hint.siwcConfigured == true)
        #expect(hint.hasEncryptedCredentials == true)
        #expect(hint.soulRevision == 4)
        #expect(hint.activeRulesCount == 3)

        // QR payloads illegally carrying plaintext API keys MUST be rejected.
        let leakedJSON = #"{"v":1,"id":"gw-bad","name":"sk-live1234567890abcdef","addrs":["127.0.0.1"],"port":47821,"fp":"fp","s":"sec"}"#
        let leakedEncoded = IOSCloudConfigEnvelope.base64url(Data(leakedJSON.utf8))
        #expect(MacGatewayPairingPayload.parse("amber://gateway/pair?p=\(leakedEncoded)") == nil)
    }

    // MARK: - 5. Ephemeral RSA-OAEP-256 + A256GCM (`amber-bootstrap+jwe`) Crypto

    @Test func bootstrapJweRoundTripAndTamperRejection() throws {
        let keyPair = try IOSPairingBootstrapCrypto.generateEphemeralKeyPair()
        #expect(keyPair.publicJwk["kty"] == "RSA")
        #expect(keyPair.publicJwk["alg"] == "RSA-OAEP-256")
        #expect(keyPair.publicJwk["use"] == "enc")
        #expect(!(keyPair.publicJwk["kid"] ?? "").isEmpty)
        #expect(!(keyPair.publicJwk["n"] ?? "").isEmpty)
        #expect(!(keyPair.publicJwk["e"] ?? "").isEmpty)
        // Strictly public JWK: never expose private key fields.
        for forbidden in ["d", "p", "q", "dp", "dq", "qi", "oth"] {
            #expect(keyPair.publicJwk[forbidden] == nil)
        }

        let payload = IOSBootstrapEnvelopePayload(
            version: 1,
            gatewayId: "gw-crypto-1",
            deviceId: "dev-ios-1",
            issuedAt: 1_700_000_000,
            expiresAt: 1_700_000_300,
            configRevision: 5,
            model: .init(
                provider: "openai",
                modelId: "gpt-5.4",
                baseUrl: "https://api.openai.com/v1",
                authMode: "chatgptSiwc",
                siwcConfigured: true
            ),
            search: .init(sources: ["bing", "exa"], mode: "fallback"),
            credentials: .init(
                modelApiKey: "sk-test-secret-do-not-leak-987654",
                exaApiKey: "exa-test-key-123456",
                braveApiKey: nil
            )
        )

        let compact = try IOSPairingBootstrapCrypto.seal(payload, publicJwk: keyPair.publicJwk)
        let segments = compact.split(separator: ".").map(String.init)
        #expect(segments.count == 5)
        // Plaintext secret must NEVER appear in the compact JWE.
        #expect(!compact.contains("sk-test-secret-do-not-leak-987654"))

        // Verify protected header matches Stage 3-A contract (`amber-bootstrap+jwe`).
        let headerData = try #require(IOSPairingBootstrapCrypto.base64urlDecode(segments[0]))
        let header = try #require(JSONSerialization.jsonObject(with: headerData) as? [String: Any])
        #expect(header["alg"] as? String == "RSA-OAEP-256")
        #expect(header["enc"] as? String == "A256GCM")
        #expect(header["typ"] as? String == "amber-bootstrap+jwe")

        // Valid decryption succeeds.
        let opened = try IOSPairingBootstrapCrypto.unseal(
            compact,
            privateKey: keyPair.privateKey,
            expectedGatewayId: "gw-crypto-1",
            expectedDeviceId: "dev-ios-1",
            nowSeconds: 1_700_000_120
        )
        #expect(opened == payload)

        // Wrong gateway / device / expired / tampered ciphertext / wrong key all fail cleanly.
        #expect(throws: IOSPairingBootstrapError.gatewayMismatch) {
            _ = try IOSPairingBootstrapCrypto.unseal(
                compact,
                privateKey: keyPair.privateKey,
                expectedGatewayId: "gw-other",
                expectedDeviceId: "dev-ios-1",
                nowSeconds: 1_700_000_120
            )
        }
        #expect(throws: IOSPairingBootstrapError.deviceMismatch) {
            _ = try IOSPairingBootstrapCrypto.unseal(
                compact,
                privateKey: keyPair.privateKey,
                expectedGatewayId: "gw-crypto-1",
                expectedDeviceId: "dev-other",
                nowSeconds: 1_700_000_120
            )
        }
        #expect(throws: IOSPairingBootstrapError.envelopeExpired) {
            _ = try IOSPairingBootstrapCrypto.unseal(
                compact,
                privateKey: keyPair.privateKey,
                expectedGatewayId: "gw-crypto-1",
                expectedDeviceId: "dev-ios-1",
                nowSeconds: 1_700_000_500
            )
        }

        // Tamper ciphertext segment -> GCM authentication failure.
        var tamperedParts = segments
        tamperedParts[3] = tamperedParts[3].reversed().map(String.init).joined()
        #expect(throws: IOSPairingBootstrapError.self) {
            _ = try IOSPairingBootstrapCrypto.unseal(tamperedParts.joined(separator: "."), privateKey: keyPair.privateKey)
        }

        // Wrong private key fails.
        let otherKeyPair = try IOSPairingBootstrapCrypto.generateEphemeralKeyPair()
        #expect(throws: IOSPairingBootstrapError.decryptionFailed) {
            _ = try IOSPairingBootstrapCrypto.unseal(compact, privateKey: otherKeyPair.privateKey)
        }
    }

    // MARK: - 6. End-to-End Single-Scan Pairing Sync Flow (No Plaintext Secrets in Summary)

    @Test @MainActor func singleScanPairingImportsEncryptedConfigSoulAndActiveRulesWithoutLeakingSecrets() async throws {
        let suite = "stage3d.pairing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let soulStore = AgentSoulStore(userDefaults: defaults)
        let ruleStorage = makeTempRulesURL()
        defer { try? FileManager.default.removeItem(at: ruleStorage) }
        let ruleStore = IOSProceduralRuleStore(storageURL: ruleStorage)
        let gatewayStore = MacGatewayStore(defaults: defaults)

        let secretApiKey = "sk-topsecret-never-appear-in-ui-998877"
        let pairJSON = #"""
        {
          "v": 1,
          "id": "gw-sync-1",
          "name": "Studio Cloud",
          "addrs": ["127.0.0.1"],
          "port": 47821,
          "fp": "fp-sync-1",
          "s": "one-time-secret",
          "bootstrap": {
            "syncSupported": true,
            "configRevision": 3,
            "provider": "openai",
            "authMode": "chatgptSiwc",
            "siwcConfigured": true,
            "hasEncryptedCredentials": true,
            "soulRevision": 2,
            "activeRulesCount": 1
          }
        }
        """#
        let encoded = IOSCloudConfigEnvelope.base64url(Data(pairJSON.utf8))
        gatewayStore.receivePairingLink("amber://gateway/pair?p=\(encoded)")
        #expect(gatewayStore.pendingPairing?.bootstrap?.siwcConfigured == true)

        actor PairRequestCapture {
            var sawBootstrapFlag = false
            var clientPublicJwk: [String: String]?
            func set(flag: Bool, jwk: [String: String]?) {
                sawBootstrapFlag = flag
                clientPublicJwk = jwk
            }
        }
        let capture = PairRequestCapture()

        let mockPairingClient = MacGatewayClient(
            addrs: ["127.0.0.1"],
            port: 47821,
            fingerprint: "fp-sync-1",
            token: nil,
            transport: { request, _ in
                let url = request.url!
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
                let flag = (body["requestBootstrapSync"] as? Bool) == true
                let jwk = body["clientPublicJwk"] as? [String: String]
                await capture.set(flag: flag, jwk: jwk)

                let now = Int64(Date().timeIntervalSince1970)
                let envelope = IOSBootstrapEnvelopePayload(
                    version: 1,
                    gatewayId: "gw-sync-1",
                    deviceId: "dev-sync-ios",
                    issuedAt: now,
                    expiresAt: now + 300,
                    configRevision: 3,
                    model: .init(
                        provider: "openai",
                        modelId: "gpt-5.4",
                        baseUrl: "https://api.openai.com/v1",
                        authMode: "chatgptSiwc",
                        siwcConfigured: true
                    ),
                    search: .init(sources: ["bing", "duckduckgo"], mode: "fallback"),
                    credentials: .init(modelApiKey: secretApiKey, exaApiKey: nil, braveApiKey: nil)
                )
                let jwe = try IOSPairingBootstrapCrypto.seal(envelope, publicJwk: jwk ?? [:])

                let responseObj: [String: Any] = [
                    "deviceId": "dev-sync-ios",
                    "token": "tok-paired-1",
                    "gatewayId": "gw-sync-1",
                    "gatewayName": "Studio Cloud",
                    "bootstrap": [
                        "version": 1,
                        "encryptedConfigJwe": jwe,
                        "configuration": [
                            "gatewayId": "gw-sync-1",
                            "revision": 3,
                            "model": [
                                "provider": "openai",
                                "modelId": "gpt-5.4",
                                "baseUrl": "https://api.openai.com/v1",
                                "authMode": "chatgptSiwc",
                                "siwcConfigured": true,
                            ],
                            "search": [
                                "sources": ["bing", "duckduckgo"],
                                "mode": "fallback",
                            ],
                            "credentials": [
                                "modelApiKey": ["configured": true],
                                "exaApiKey": ["configured": false],
                                "braveApiKey": ["configured": false],
                            ],
                        ],
                        "soul": [
                            "revision": 2,
                            "updatedAtMs": 1_700_000_500_000,
                            "displayName": "琥珀搭档",
                            "tagline": "简洁务实",
                            "soulMarkdown": "始终保持克制、清晰的工程回复。",
                            "isDefault": false,
                            "source": "cloud_sync",
                            "history": [],
                        ],
                        "activeRules": [
                            [
                                "id": "rule_boot_1",
                                "title": "先核查再修改",
                                "instruction": "修改配置文件前先完整检查已有键位。",
                                "scope": "global",
                                "sourceEventId": "evt-boot",
                                "status": "active",
                                "hitCount": 2,
                                "createdAt": 100,
                                "updatedAt": 200,
                            ],
                            // Proposed rule in snapshot must NOT be auto-activated.
                            [
                                "id": "rule_boot_proposed",
                                "title": "不应自动导入",
                                "instruction": "未确认规则不得自动生效。",
                                "scope": "global",
                                "sourceEventId": "",
                                "status": "proposed",
                                "hitCount": 0,
                                "createdAt": 100,
                                "updatedAt": 200,
                            ],
                        ],
                    ],
                ]
                let data = try JSONSerialization.data(withJSONObject: responseObj)
                return (data, makeHTTPResponse(url: url, status: 200))
            }
        )

        var storedCreds: [String: String] = [:]
        let sharedSettings = IOSSharedSettingsStore(
            userDefaults: defaults,
            loadCredential: { key in storedCreds[key] },
            storeCredential: { key, value in
                storedCreds[key] = value
                return true
            },
            deleteCredential: { key in
                storedCreds.removeValue(forKey: key)
                return true
            }
        )

        var storedPairingToken: String?
        await gatewayStore.confirmPairing(
            sharedSettings: sharedSettings,
            soulStore: soulStore,
            ruleStore: ruleStore,
            pairingClientOverride: mockPairingClient,
            storeToken: { _, value in
                storedPairingToken = value
                return true
            }
        )

        #expect(storedPairingToken == "tok-paired-1")
        #expect(await capture.sawBootstrapFlag == true)
        #expect((await capture.clientPublicJwk)?["kty"] == "RSA")
        #expect(gatewayStore.connection?.gatewayId == "gw-sync-1")
        #expect(gatewayStore.pendingPairing == nil)

        // Verify decrypted provider config & secret reached local settings store.
        #expect(storedCreds.values.contains(secretApiKey))
        let syncedOpenAI = sharedSettings.snapshot.providers.compactMap { $0 as? ProviderSetting.OpenAI }.first { $0.models.contains { $0.modelId == "gpt-5.4" } }
        #expect(syncedOpenAI != nil)
        #expect(syncedOpenAI?.authMode == OpenAIAuthMode.chatgptSiwc)

        // Verify C-SOUL-V1 and active rules were imported; proposed rule was excluded.
        #expect(soulStore.displayName == "琥珀搭档")
        #expect(ruleStore.activeRules.map(\.id) == ["rule_boot_1"])
        #expect(ruleStore.proposedRules.isEmpty)

        // Verify non-secret remote config & user-facing sync summary.
        #expect(gatewayStore.cloudConfig?.model?.authMode == "chatgptSiwc")
        #expect(gatewayStore.cloudConfig?.model?.siwcConfigured == true)
        let summary = try #require(gatewayStore.lastBootstrapSyncSummary)
        #expect(summary.encryptedConfigDecrypted == true)
        #expect(summary.soulSynced == true)
        #expect(summary.activeRulesImported == 1)
        #expect(summary.credentialsImported == true)
        #expect(!summary.summaryText.contains(secretApiKey))
        let noticeText = try #require(gatewayStore.notice?.text)
        #expect(noticeText == summary.summaryText)
        #expect(!noticeText.contains(secretApiKey))
    }
}
