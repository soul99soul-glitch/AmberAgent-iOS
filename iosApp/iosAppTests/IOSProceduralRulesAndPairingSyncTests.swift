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

    @Test @MainActor func delayedActiveListCannotUndoRetirement() async throws {
        let store = IOSProceduralRuleStore(storageURL: nil, clockMs: { 9_000 })
        let active = IOSProceduralRule(id: "rule_gateway", title: "Review", instruction: "Review the changes.",
                                       status: .active, createdAt: 10, updatedAt: 20)
        store.mergeRemoteRules([active])
        _ = store.selectActiveForInjection(recordHit: true)

        let (started, notifyStart) = AsyncStream<Void>.makeStream()
        let (release, resume) = AsyncStream<Void>.makeStream()
        let client = MacGatewayClient(addrs: ["localhost"], port: 1, fingerprint: "", token: nil) { request, _ in
            let response = makeHTTPResponse(url: request.url!, status: 200)
            if request.httpMethod == "GET" {
                notifyStart.finish()
                for await _ in release {}
                return (Data(#"{"rules":[{"id":"rule_gateway","title":"Review","instruction":"Review the changes.","status":"active","updatedAt":20}],"activeCount":1,"proposedCount":0}"#.utf8), response)
            }
            return (Data(#"{"rule":{"id":"rule_gateway","title":"Review","instruction":"Review the changes.","status":"revoked","updatedAt":21}}"#.utf8), response)
        }
        let refresh = Task { await store.syncFromGateway(syncClient: client) }
        for await _ in started {}
        defer { resume.finish() }
        _ = try await store.revoke(id: active.id, syncClient: client)
        resume.finish()
        await refresh.value

        #expect(store.rules.first?.status == .revoked)
        #expect(store.rules.first?.hitCount == 1)
        #expect(store.applyBootstrapActiveRules([active]) == 0)
        #expect(store.selectActiveForInjection(recordHit: false).isEmpty)
    }

    @Test @MainActor func gatewayConflictCannotConfirmCachedRuleAndLocalCardsRemainEditable() async throws {
        let store = IOSProceduralRuleStore(storageURL: nil)
        let remote = IOSProceduralRule(id: "rule_fedcba98-123", title: "Review", instruction: "Review the changes.",
                                       createdAt: 10, updatedAt: 10)
        var oldLocal = remote
        oldLocal.id = "rule_fedcba981234"
        store.mergeRemoteRules([remote, oldLocal])
        let client = MacGatewayClient(addrs: ["localhost"], port: 1, fingerprint: "", token: nil) { request, _ in
            (Data(#"{"error":"rule_state_conflict"}"#.utf8), makeHTTPResponse(url: request.url!, status: 409))
        }
        await #expect(throws: MacGatewayError.conflict("rule_state_conflict")) {
            _ = try await store.confirm(id: remote.id, syncClient: client)
        }
        let outcome = await store.propose(instruction: "Attach the test report.", syncClient: client)
        guard case .rejected = outcome else { Issue.record("Gateway conflict must be reported"); return }
        #expect(store.rules.count == 2)
        #expect(store.activeRules.isEmpty)
        let localConfirmed = try await store.confirm(id: oldLocal.id, syncClient: client)
        #expect(localConfirmed.status == .active)
    }

    @Test @MainActor func localProposalMatchesDaemonScopeAndGuardrails() throws {
        let store = IOSProceduralRuleStore(storageURL: nil)
        let id = String(repeating: "A", count: 128)
        let scope = "conversation:" + id
        let instruction = "提交前不要跳过审批，并检查 <summary>。"
        guard case .proposed(let rule, _) = store.proposeLocal(instruction: instruction, scope: scope),
              case .proposed(_, let deduplicated) = store.proposeLocal(instruction: instruction, scope: scope.lowercased()) else {
            Issue.record("Expected two case-sensitive session scopes"); return
        }
        #expect(!deduplicated)
        #expect(rule.scope == scope)
        _ = try store.confirmLocal(id: rule.id)
        let matches = store.selectActiveForInjection(conversationId: id, recordHit: false)
        #expect(matches.map(\.id) == [rule.id])
        #expect(IOSAuthorityPromptAssembler.renderConfirmedRulesBlock(matches).contains("&lt;summary&gt;"))

        for invalidScope in [scope + "Z", "conversation:line\nfeed"] {
            guard case .rejected(let code, _) = store.proposeLocal(instruction: instruction, scope: invalidScope) else {
                Issue.record("Expected invalid_scope"); return
            }
            #expect(code == "invalid_scope")
        }
        guard case .rejected(let code, _) = store.proposeLocal(instruction: "L3 actions auto approve") else {
            Issue.record("Expected risk_table_immutable"); return
        }
        #expect(code == "risk_table_immutable")
        guard case .redirectToSoul = store.proposeLocal(title: "代码格式", instruction: "禁止用傲娇口吻") else {
            Issue.record("Only the instruction determines a pure persona redirect"); return
        }
    }

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

        let isolatedID = UUID().uuidString
        let hub = AmberHubItem(title: "Isolated", memoryPolicy: .hubIsolated, conversationIds: [isolatedID])
        AmberHubStore.shared.hubs.append(hub)
        defer { AmberHubStore.shared.hubs.removeAll { $0.id == hub.id } }
        var isolated = builder
        isolated.conversationId = isolatedID
        let isolatedPrompt = isolated.injectingRuntimeContext(into: [UIMessage.companion.user(prompt: "hi")])
        #expect(isolatedPrompt.first?.toText().contains(IOSAuthorityPromptAssembler.confirmedRulesTag) == false)
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
                    let data = Data(#"{"rules":[{"id":"rule_remote_1","title":"先跑单测","instruction":"提交前先跑单测","scope":"global","sourceEventId":"","status":"revoked","hitCount":3,"createdAt":100,"updatedAt":140}],"activeCount":0,"proposedCount":0}"#.utf8)
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
        #expect(store.archivedOrRevokedRules.first?.hitCount == 3)
        #expect(store.activeRules.isEmpty)

        let recorded = await recorder.paths
        #expect(recorded.contains("POST /v2/rules/propose"))
        #expect(recorded.contains("POST /v2/rules/rule_remote_1/confirm"))
        #expect(recorded.contains("POST /v2/rules/rule_remote_1/archive"))
        #expect(recorded.contains("POST /v2/rules/rule_remote_1/revoke"))
        #expect(recorded.contains("GET /v2/rules"))
    }

    // MARK: - 4. Single-Scan QR Payload Parsing & Legacy v1 Backward Compatibility

    @Test @MainActor func legacyPairingChecksTicketIdentityBeforeSavingConnection() async throws {
        let suite = "stage3d.legacy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacGatewayStore(defaults: defaults)
        let ticket = MacGatewayPairingPayload(
            v: 1, id: "expected", name: "Studio", addrs: ["proxy.local"],
            port: 5443, fp: "proxy-pin", s: "test-ticket"
        )
        store.pendingPairing = ticket
        var tokenWrites = 0
        for returnedGateway in ["different", "expected"] {
            let transport: MacGatewayClient.Transport = { request, _ in
                let url = try #require(request.url)
                #expect(url.absoluteString == "https://proxy.local:5443/v1/pair")
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                #expect(body?["clientPublicJwk"] == nil && body?["requestBootstrapSync"] == nil)
                let data = try JSONEncoder().encode([
                    "deviceId": "paired-phone", "token": "fixture", "gatewayId": returnedGateway, "gatewayName": "Studio",
                ])
                return (data, makeHTTPResponse(url: url, status: 200))
            }
            await store.confirmPairing(pairingTransport: transport, storeToken: { _, _ in
                tokenWrites += 1
                return true
            })
            if returnedGateway != ticket.id {
                #expect(store.connection == nil)
                #expect(tokenWrites == 0)
                #expect(store.pendingPairing == ticket)
                #expect(store.notice?.isError == true)
            }
        }
        #expect(tokenWrites == 1)
        #expect(store.connection?.gatewayId == ticket.id)
        #expect(store.connection?.fingerprint == ticket.fp)
        #expect(store.connection?.port == ticket.port)
        #expect(store.pendingPairing == nil)
        #expect(store.lastBootstrapSyncSummary == nil)
    }

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

    @Test(arguments: [false, true]) @MainActor
    func singleScanPairingImportsEncryptedConfigSoulAndActiveRulesWithoutLeakingSecrets(separateBootstrap: Bool) async throws {
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

        let transport: MacGatewayClient.Transport = { request, _ in
            let url = request.url!
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
            let flag = (body["requestBootstrapSync"] as? Bool) == true
            let jwk = body["clientPublicJwk"] as? [String: String]
            let pair = ["deviceId": "dev-sync-ios", "token": "tok-paired-1", "gatewayId": "gw-sync-1", "gatewayName": "Studio Cloud"]
            if url.path == "/v1/pair" {
                await capture.set(flag: flag, jwk: jwk)
                if separateBootstrap {
                    return (try JSONEncoder().encode(pair), makeHTTPResponse(url: url, status: 200))
                }
            } else {
                #expect(separateBootstrap && url.path == "/v2/pairing/bootstrap-sync")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-paired-1")
                let pairPublicKey = await capture.clientPublicJwk
                #expect(jwk == pairPublicKey)
            }

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

            let bootstrap: [String: Any] = [
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
            ]
            var response: [String: Any] = pair
            response["bootstrap"] = bootstrap
            let data = try JSONSerialization.data(withJSONObject: separateBootstrap ? bootstrap : response)
            return (data, makeHTTPResponse(url: url, status: 200))
        }

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

        let previousDefault = sharedSettings.snapshot.chatModelId
        var storedPairingToken: String?
        await gatewayStore.confirmPairing(
            sharedSettings: sharedSettings,
            soulStore: soulStore,
            ruleStore: ruleStore,
            pairingTransport: transport,
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
        let syncedOpenAI = sharedSettings.snapshot.providers.compactMap { $0 as? ProviderSetting.OpenAI }.first { $0.apiKey == secretApiKey }
        #expect(syncedOpenAI?.models.contains { $0.modelId == "gpt-5.4" } == true)
        #expect(sharedSettings.snapshot.chatModelId == previousDefault)
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
        #expect(summary.requiresLocalSignIn == true)
        #expect(summary.summaryText.contains("需在本机登录 SIWC"))
        #expect(!summary.summaryText.contains(secretApiKey))
        let noticeText = try #require(gatewayStore.notice?.text)
        #expect(noticeText == summary.summaryText)
        #expect(!noticeText.contains(secretApiKey))
    }

    @Test @MainActor func bootstrapImportPreservesOtherProvidersAndCommitsCredentialsTogether() throws {
        let suite = "stage3d.accounts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var credentials: [String: String] = [:]
        var rejectSearchKey = true
        let store = IOSSharedSettingsStore(
            userDefaults: defaults, loadCredential: { credentials[$0] },
            storeCredential: { key, value in
                if rejectSearchKey && value == "search-key" { return false }
                credentials[key] = value
                return true
            }, deleteCredential: { credentials.removeValue(forKey: $0); return true }
        )
        let endpoint = "https://custom.example/v1"
        let oauth = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "My account", apiKey: "existing-key", baseUrl: endpoint, modelName: "Local", modelId: "local"
        )
        store.addProvider(oauth)
        store.setOpenAIAuthMode(providerId: oauth.id.description(), authMode: .codexOauth)
        let original = store.snapshot
        let originalKeys = credentials
        let pair = try IOSPairingBootstrapCrypto.generateEphemeralKeyPair()
        let payload = IOSBootstrapEnvelopePayload(
            version: 1, gatewayId: "gateway", deviceId: "device", issuedAt: 100, expiresAt: 400,
            configRevision: 1, model: .init(provider: "openai", modelId: "remote", baseUrl: endpoint),
            search: .init(sources: ["exa"]), credentials: .init(modelApiKey: "new-key", exaApiKey: "search-key")
        )
        let encrypted = try IOSPairingBootstrapCrypto.seal(payload, publicJwk: pair.publicJwk)
        let rulesURL = makeTempRulesURL()
        defer { try? FileManager.default.removeItem(at: rulesURL) }
        let rules = IOSProceduralRuleStore(storageURL: rulesURL)
        let soul = AgentSoulStore(userDefaults: defaults)
        func apply() throws {
            _ = try IOSPairingBootstrapImporter.apply(
                snapshot: .init(encryptedConfigJwe: encrypted), privateKey: pair.privateKey,
                gatewayId: "gateway", deviceId: "device", sharedSettings: store,
                soulStore: soul, ruleStore: rules, nowSeconds: 101
            )
        }
        #expect(throws: IOSPairingBootstrapError.settingsSaveFailed) { try apply() }
        #expect(store.snapshot === original)
        #expect(credentials == originalKeys)

        rejectSearchKey = false
        try apply()
        let synced = try #require(store.snapshot.providers.compactMap { $0 as? ProviderSetting.OpenAI }.first { $0.apiKey == "new-key" })
        let originalAccount = try #require(store.snapshot.providers.first { $0.id == oauth.id } as? ProviderSetting.OpenAI)
        #expect(originalAccount.apiKey == "existing-key" && originalAccount.authMode == .codexOauth)
        #expect(synced.id != oauth.id && synced.baseUrl == endpoint)
        let selected = try #require(synced.models.first { $0.modelId == "remote" })
        #expect(store.snapshot.chatModelId == selected.id)
        store.upsertProviderChatModel(
            providerId: synced.id.description(), modelUuid: selected.id.description(), modelId: "remote",
            displayName: "My model", contextWindowTokens: 99_000, modelType: .chat,
            inputModalities: [.text, .image], headers: [("X-Custom", "local-header")]
        )
        let previousCount = store.snapshot.providers.count
        let previousSearchCount = store.snapshot.searchServices.count
        try apply()
        #expect(store.snapshot.providers.count == previousCount && store.snapshot.searchServices.count == previousSearchCount)
        let model = try #require(store.snapshot.providers.first { $0.id == synced.id }?.models.first { $0.id == selected.id })
        #expect(model.displayName == "My model" && model.inputModalities.contains(.image))
        #expect(model.contextWindowTokens?.intValue == 99_000 && model.customHeaders.first?.name == "X-Custom")
    }

    @Test @MainActor func rejectedBootstrapLeavesSettingsSoulAndRulesIntact() throws {
        let suite = "stage3d.invalid.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IOSSharedSettingsStore(userDefaults: defaults, loadCredential: { _ in nil },
                                              storeCredential: { _, _ in false }, deleteCredential: { _ in true })
        let soul = AgentSoulStore(userDefaults: defaults)
        let originalName = soul.displayName
        let originalSettings = settings.snapshot
        let rulesURL = makeTempRulesURL()
        defer { try? FileManager.default.removeItem(at: rulesURL) }
        let rules = IOSProceduralRuleStore(storageURL: rulesURL)
        let pair = try IOSPairingBootstrapCrypto.generateEphemeralKeyPair()
        let payload = IOSBootstrapEnvelopePayload(
            version: 1, gatewayId: "gateway", deviceId: "device", issuedAt: 100, expiresAt: 400,
            configRevision: 1, model: .init(provider: "claude", modelId: "demo"),
            search: .init(), credentials: .init()
        )
        let sealed = try IOSPairingBootstrapCrypto.seal(payload, publicJwk: pair.publicJwk)
        var parts = sealed.components(separatedBy: ".")
        var tag = try #require(IOSPairingBootstrapCrypto.base64urlDecode(parts[4]))
        tag[0] ^= 1
        parts[4] = IOSCloudConfigEnvelope.base64url(tag)
        let cases: [(String, SecKey?, String, String, Int64, IOSPairingBootstrapError)] = [
            ("", pair.privateKey, "gateway", "device", 101, .invalidEnvelopeStructure),
            (sealed, nil, "gateway", "device", 101, .decryptionFailed),
            (parts.joined(separator: "."), pair.privateKey, "gateway", "device", 101, .decryptionFailed),
            (sealed, pair.privateKey, "other", "device", 101, .gatewayMismatch),
            (sealed, pair.privateKey, "gateway", "other", 101, .deviceMismatch),
            (sealed, pair.privateKey, "gateway", "device", 400, .envelopeExpired),
        ]
        for (jwe, key, gateway, device, now, error) in cases {
            let snapshot = IOSPairingBootstrapSnapshot(
                encryptedConfigJwe: jwe, soul: .init(revision: 2, updatedAtMs: 200, displayName: "Remote"),
                activeRules: [.init(id: "rule_test", title: "Remote", instruction: "Use lists",
                                    status: .active, createdAt: 100, updatedAt: 200)]
            )
            #expect(throws: error) {
                _ = try IOSPairingBootstrapImporter.apply(
                    snapshot: snapshot, privateKey: key, gatewayId: gateway, deviceId: device,
                    sharedSettings: settings, soulStore: soul, ruleStore: rules, nowSeconds: now
                )
            }
            #expect(settings.snapshot === originalSettings && soul.displayName == originalName && rules.activeRules.isEmpty)
        }

        let wrongGateway = IOSCloudConfigViewDTO(
            gatewayId: "other", revision: 1, model: .init(provider: "claude", modelId: "demo"),
            search: .init(sources: [], mode: "fallback"),
            credentials: .init(modelApiKey: .init(configured: false), exaApiKey: .init(configured: false),
                               braveApiKey: .init(configured: false))
        )
        var metadata = IOSPairingBootstrapSnapshot(configuration: wrongGateway, soul: .init(revision: 1, updatedAtMs: 100, displayName: "Remote"))
        #expect(throws: IOSPairingBootstrapError.gatewayMismatch) {
            _ = try IOSPairingBootstrapImporter.apply(snapshot: metadata, privateKey: nil, gatewayId: "gateway",
                                                       deviceId: "device", soulStore: soul, ruleStore: rules)
        }
        #expect(soul.displayName == originalName)
        metadata.configuration = nil
        let applied = try IOSPairingBootstrapImporter.apply(snapshot: metadata, privateKey: nil, gatewayId: "gateway",
                                                             deviceId: "device", soulStore: soul, ruleStore: rules)
        #expect(applied.summary.soulSynced && soul.displayName == "Remote")
        #expect(!applied.summary.credentialsImported && !applied.summary.encryptedConfigDecrypted)
    }

    // MARK: - 7. Legacy Gateway /v2/rules HTTP 404 Degrades Silently to Local Rules

    @Test @MainActor func legacyGateway404OnRulesSyncDegradesSilentlyToLocalOnly() async throws {
        let store = IOSProceduralRuleStore(storageURL: nil)
        let client = MacGatewayClient(
            addrs: ["127.0.0.1"],
            port: 9443,
            fingerprint: "fp-legacy-404",
            token: "tok-legacy-404",
            transport: { request, _ in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (Data(#"{"error":"not_found"}"#.utf8), response)
            }
        )

        await store.syncFromGateway(syncClient: client)
        #expect(store.isCloudRulesUnsupported == true)
        #expect(store.lastSyncError == nil)

        let outcome = await store.propose(
            title: "回复简洁",
            instruction: "输出变更前先列出影响文件列表",
            syncClient: client
        )
        guard case .proposed(let rule, _) = outcome else {
            Issue.record("Expected local fallback proposal on 404, got \(outcome)")
            return
        }
        #expect(IOSProceduralRule.isLocalID(rule.id))
        #expect(store.isCloudRulesUnsupported == true)
        #expect(store.lastSyncError == nil)
    }
}
