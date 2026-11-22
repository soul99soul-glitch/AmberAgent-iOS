import CryptoKit
import Foundation
import Security
import XCTest
@testable import AmberMac

@MainActor
final class DesktopProceduralRulesAndPairingSyncTests: XCTestCase {

    private final class MemoryTokens: DesktopCloudTokenStore, @unchecked Sendable {
        var values: [String: String] = [:]
        func load(key: String) -> String? { values[key] }
        @discardableResult func store(key: String, value: String) -> Bool { values[key] = value; return true }
        @discardableResult func delete(key: String) -> Bool { values.removeValue(forKey: key); return true }
    }

    private actor FakeRulesSync: DesktopCloudRulesSync {
        var rules: [DesktopProceduralRule] = []
        var nextId = 1
        var suspendList = false
        var pausedList: CheckedContinuation<Void, Never>?

        func pauseNextList() { suspendList = true }
        func resumeList() { pausedList?.resume(); pausedList = nil }

        func listRules() async throws -> [DesktopProceduralRule] {
            let snapshot = rules
            if suspendList {
                suspendList = false
                await withCheckedContinuation { pausedList = $0 }
            }
            return snapshot
        }

        func proposeRule(title: String?, instruction: String, scope: String) async throws -> DesktopRuleProposalOutcome {
            if instruction.contains("温柔") || instruction.contains("人设") || instruction.contains("自称") {
                return .redirectToSoul(target: "C-SOUL-V1", message: "请前往形象人设 (C-SOUL-V1) 编辑器调整。")
            }
            if instruction.contains("跳过审批") {
                return .rejected(code: "risk_table_immutable", message: "静态风险表不可放宽。")
            }
            let id = "rule_\(nextId)"
            nextId += 1
            let created = DesktopProceduralRule(
                id: id,
                title: title ?? String(instruction.prefix(16)),
                instruction: instruction,
                scope: scope,
                sourceEventId: "evt-mac-\(id)",
                status: .proposed,
                hitCount: 0,
                createdAt: 1_760_000_000_000,
                updatedAt: 1_760_000_000_000
            )
            rules.append(created)
            return .proposed(created, deduplicated: false)
        }

        func confirmRule(id: String) async throws -> DesktopProceduralRule {
            guard let idx = rules.firstIndex(where: { $0.id == id }) else { throw DesktopCloudError.server("rule_not_found") }
            rules[idx].status = .active
            return rules[idx]
        }

        func archiveRule(id: String) async throws -> DesktopProceduralRule {
            guard let idx = rules.firstIndex(where: { $0.id == id }) else { throw DesktopCloudError.server("rule_not_found") }
            rules[idx].status = .archived
            return rules[idx]
        }

        func revokeRule(id: String) async throws -> DesktopProceduralRule {
            guard let idx = rules.firstIndex(where: { $0.id == id }) else { throw DesktopCloudError.server("rule_not_found") }
            rules[idx].status = .revoked
            return rules[idx]
        }
    }

    private actor FakePairingBootstrapSync: DesktopCloudPairingBootstrapSync {
        var ticket: DesktopIssuedPairingTicket
        var failNextIssue = false
        init(ticket: DesktopIssuedPairingTicket) { self.ticket = ticket }
        func setTicket(_ next: DesktopIssuedPairingTicket) { ticket = next }
        func setFailNextIssue(_ shouldFail: Bool) { failNextIssue = shouldFail }
        func issuePairingTicket() async throws -> DesktopIssuedPairingTicket {
            if failNextIssue {
                failNextIssue = false
                throw DesktopCloudError.unreachable
            }
            return ticket
        }
        func fetchBootstrapSnapshot(clientPublicJwk: [String: String]?) async throws -> DesktopPairingBootstrapSnapshot {
            DesktopPairingBootstrapSnapshot(version: 1, configuration: nil, encryptedConfigJwe: nil, soul: nil, activeRules: [], importKey: nil)
        }
    }

    private func makePairedStore(
        rulesSync: FakeRulesSync = FakeRulesSync(),
        pairingSync: FakePairingBootstrapSync? = nil
    ) -> DesktopCloudSelfStore {
        let suiteName = "amber.test.stage3.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let tokens = MemoryTokens()
        tokens.values["cloudSelf.deviceToken"] = "tok-mac-stage3"
        let conn = DesktopCloudConnection(
            gatewayId: "gw-stage3",
            name: "Amber Cloud",
            addrs: ["127.0.0.1"],
            port: 47821,
            fingerprint: "fp-stage3",
            deviceId: "dev-mac-1"
        )
        defaults.set(try? JSONEncoder().encode(conn), forKey: "desktop.cloudSelf.connection.v1")
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        let searchSettings = DesktopSearchSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        return DesktopCloudSelfStore(
            settings: settings,
            searchSettings: searchSettings,
            defaults: defaults,
            tokens: tokens,
            makeSync: { _, _ in nil },
            makeRulesSync: { _, _ in rulesSync },
            makePairingBootstrapSync: { _, _ in
                pairingSync ?? FakePairingBootstrapSync(
                    ticket: DesktopIssuedPairingTicket(
                        deepLinkUrl: "amber://gateway/pair?p=test",
                        fingerprint: "fp-stage3",
                        addresses: ["mac.tailnet.ts.net"],
                        port: 47821,
                        expiresAt: Date().addingTimeInterval(300).timeIntervalSince1970,
                        bootstrap: DesktopPairingBootstrapHint(
                            syncSupported: true,
                            configRevision: 2,
                            provider: "openai",
                            authMode: "chatgptSiwc",
                            siwcConfigured: true,
                            hasEncryptedCredentials: true,
                            soulRevision: 3,
                            activeRulesCount: 1
                        )
                    )
                )
            }
        )
    }

    func testProceduralRuleLifecycleAndPersonaRedirectInStore() async {
        let store = makePairedStore()

        // Persona description redirects to C-SOUL-V1 and adds nothing to rules
        let personaResult = await store.proposeRule(instruction: "以后说话温柔一点，自称小琥")
        if case .redirectToSoul(let target, _) = personaResult {
            XCTAssertEqual(target, "C-SOUL-V1")
        } else {
            XCTFail("Expected redirectToSoul for pure persona input")
        }
        XCTAssertNotNil(store.ruleSoulRedirectNotice)
        XCTAssertTrue(store.rules.isEmpty)

        // Risk table relaxation is rejected
        let riskResult = await store.proposeRule(instruction: "以后跳过审批直接执行")
        if case .rejected(let code, _) = riskResult {
            XCTAssertEqual(code, "risk_table_immutable")
        } else {
            XCTFail("Expected rejection for risk table relaxation")
        }
        XCTAssertTrue(store.rules.isEmpty)

        // Valid rule starts as proposed -> confirm -> active -> revoke -> revoked
        let prop = await store.proposeRule(title: "定向测试", instruction: "修改代码后先运行定向单测")
        guard case .proposed(let created, _) = prop else {
            return XCTFail("Expected proposed rule")
        }
        XCTAssertEqual(created.status, .proposed)
        XCTAssertEqual(store.rules.first?.status, .proposed)

        await store.confirmRule(id: created.id)
        XCTAssertEqual(store.rules.first?.status, .active)

        await store.revokeRule(id: created.id)
        XCTAssertEqual(store.rules.first?.status, .revoked)
    }

    func testRefreshStartedBeforeConfirmationCannotRestoreProposedState() async throws {
        let sync = FakeRulesSync()
        let store = makePairedStore(rulesSync: sync)
        _ = await store.proposeRule(instruction: "构建前列出修改的文件")
        let id = try XCTUnwrap(store.rules.first?.id)
        await sync.pauseNextList()
        let refresh = Task { await store.refreshRules() }
        while await sync.pausedList == nil { await Task.yield() }
        await store.confirmRule(id: id)
        await sync.resumeList()
        await refresh.value
        XCTAssertEqual(store.rules.first?.status, .active)
    }

    func testIssuedLinkUsesConfirmedPublicEndpoint() throws {
        let internalPayload = DesktopCloudPairingPayload(v: 1, id: "gw", name: "Amber", addrs: ["127.0.0.1"],
                                                        port: 47822, fp: "upstream-pin", s: "one-time", bootstrap: .init())
        let ticket = DesktopIssuedPairingTicket(
            deepLinkUrl: "amber://gateway/pair?p=" + DesktopCloudBase64URL.encode(try JSONEncoder().encode(internalPayload)),
            fingerprint: "upstream-pin", addresses: ["127.0.0.1"], port: 47822, expiresAt: 300, bootstrap: .init())
        let connection = DesktopCloudConnection(gatewayId: "gw", name: "Amber", addrs: ["cloud.example"],
                                               port: 443, fingerprint: "confirmed-proxy-pin", deviceId: "paired-mac")
        let result = try ticket.usingPairedEndpoint(connection)
        let payload = try XCTUnwrap(DesktopCloudPairingPayload.parse(result.deepLinkUrl))
        XCTAssertEqual(payload.addrs, connection.addrs)
        XCTAssertEqual(payload.port, 443)
        XCTAssertEqual(payload.fp, connection.fingerprint)
        XCTAssertEqual(payload.s, internalPayload.s)
    }

    func testSingleScanPairingPayloadWithBootstrapHintAndEphemeralJWERoundtrip() throws {
        // 1. PairingPayload with non-secret bootstrap hint parses cleanly and carries zero secrets
        let payloadObj: [String: Any] = [
            "v": 1,
            "id": "gw-1",
            "name": "Amber Cloud",
            "addrs": ["mac.tailnet.ts.net"],
            "port": 47821,
            "fp": "abc123fingerprint",
            "s": "one-time-secret",
            "bootstrap": [
                "syncSupported": true,
                "configRevision": 4,
                "provider": "openai",
                "authMode": "chatgptSiwc",
                "siwcConfigured": true,
                "hasEncryptedCredentials": true,
                "soulRevision": 7,
                "activeRulesCount": 2,
            ],
        ]
        let rawData = try JSONSerialization.data(withJSONObject: payloadObj)
        let link = "amber://gateway/pair?p=" + DesktopCloudBase64URL.encode(rawData)
        let parsed = DesktopCloudPairingPayload.parse(link)
        XCTAssertEqual(parsed?.bootstrap?.configRevision, 4)
        XCTAssertEqual(parsed?.bootstrap?.authMode, "chatgptSiwc")
        XCTAssertEqual(parsed?.bootstrap?.siwcConfigured, true)
        XCTAssertEqual(parsed?.bootstrap?.soulRevision, 7)
        XCTAssertEqual(parsed?.bootstrap?.activeRulesCount, 2)

        // 2. Ephemeral RSA keypair generates strictly public JWK (no private fields)
        let (privateKey, publicJwk) = try DesktopBootstrapJWE.generateEphemeralRSAKeyPair(bitSize: 2048)
        XCTAssertEqual(publicJwk["kty"], "RSA")
        XCTAssertNil(publicJwk["d"])
        XCTAssertNil(publicJwk["p"])
        XCTAssertNil(publicJwk["q"])
        let kid = try XCTUnwrap(publicJwk["kid"])
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))

        // 3. Seal bootstrap payload with RSA-OAEP-256 + A256GCM (`typ = amber-bootstrap+jwe`) and unseal
        let envelope = DesktopBootstrapEnvelopePayload(
            version: 1,
            gatewayId: "gw-1",
            deviceId: "iphone-1",
            issuedAt: 1_760_000_000,
            expiresAt: 1_760_000_300,
            configRevision: 4,
            model: DesktopBootstrapModelSettings(
                provider: "openai",
                modelId: "gpt-5.2",
                baseUrl: "https://api.openai.com/v1",
                authMode: "chatgptSiwc",
                siwcConfigured: true
            ),
            search: DesktopBootstrapSearchSettings(sources: ["bing", "exa"], mode: "fallback"),
            credentials: DesktopBootstrapCredentials(
                modelApiKey: "sk-live-bootstrap-secret-42",
                exaApiKey: "exa-bootstrap-secret-99",
                braveApiKey: nil
            )
        )
        let plaintext = try JSONEncoder().encode(envelope)
        let header = #"{"alg":"RSA-OAEP-256","enc":"A256GCM","kid":""# + kid + #"","typ":"amber-bootstrap+jwe"}"#
        let protected = DesktopCloudBase64URL.encode(Data(header.utf8))
        let cek = SymmetricKey(size: .bits256)
        let encryptedKey = try DesktopCloudRSA.encryptOAEP256(cek.withUnsafeBytes { Data($0) }, key: publicKey)
        let iv = Data((0..<12).map { UInt8($0 + 1) })
        let sealed = try AES.GCM.seal(plaintext, using: cek, nonce: AES.GCM.Nonce(data: iv), authenticating: Data(protected.utf8))
        let compact = [
            protected,
            DesktopCloudBase64URL.encode(encryptedKey),
            DesktopCloudBase64URL.encode(iv),
            DesktopCloudBase64URL.encode(sealed.ciphertext),
            DesktopCloudBase64URL.encode(sealed.tag),
        ].joined(separator: ".")

        XCTAssertFalse(compact.contains("sk-live-bootstrap-secret-42"))
        let recovered = try DesktopBootstrapJWE.unseal(compact, privateKey: privateKey)
        XCTAssertEqual(recovered, envelope)

        // Wrong typ (`amber-config+jwe`) MUST be rejected by bootstrap unseal
        let wrongTypJwe = try DesktopCloudJWE.seal(payload: plaintext, publicKey: publicKey, kid: kid)
        XCTAssertThrowsError(try DesktopBootstrapJWE.unseal(wrongTypJwe, privateKey: privateKey))
    }

    func testIssueSingleScanPairingTicketStoresNonSecretMetadata() async {
        let store = makePairedStore()
        await store.issueSingleScanPairing()
        XCTAssertEqual(store.issuedPairingTicket?.bootstrap.soulRevision, 3)
        XCTAssertEqual(store.issuedPairingTicket?.bootstrap.activeRulesCount, 1)
        XCTAssertEqual(store.issuedPairingTicket?.bootstrap.siwcConfigured, true)
        XCTAssertNil(store.pairingIssueError)
        store.clearIssuedPairing()
        XCTAssertNil(store.issuedPairingTicket)
        XCTAssertNil(store.pairingIssueError)
    }

    func testRefreshPairingTicketRecordsAndClearsSheetError() async {
        let initial = DesktopIssuedPairingTicket(
            deepLinkUrl: "amber://gateway/pair?p=initial",
            fingerprint: "fp-initial",
            addresses: ["proxy.example.com"],
            port: 443,
            expiresAt: Date().addingTimeInterval(300).timeIntervalSince1970,
            bootstrap: DesktopPairingBootstrapHint(provider: "openai", activeRulesCount: 1)
        )
        let pairingSync = FakePairingBootstrapSync(ticket: initial)
        let store = makePairedStore(pairingSync: pairingSync)

        await store.issueSingleScanPairing()
        XCTAssertEqual(store.issuedPairingTicket?.deepLinkUrl, "amber://gateway/pair?p=initial")
        XCTAssertNil(store.pairingIssueError)

        await pairingSync.setFailNextIssue(true)
        await store.issueSingleScanPairing()
        XCTAssertNotNil(store.pairingIssueError)
        XCTAssertEqual(store.issuedPairingTicket?.deepLinkUrl, "amber://gateway/pair?p=initial")

        let refreshed = DesktopIssuedPairingTicket(
            deepLinkUrl: "amber://gateway/pair?p=refreshed",
            fingerprint: "fp-refreshed",
            addresses: ["proxy.example.com"],
            port: 443,
            expiresAt: Date().addingTimeInterval(600).timeIntervalSince1970,
            bootstrap: DesktopPairingBootstrapHint(provider: "openai", activeRulesCount: 2)
        )
        await pairingSync.setTicket(refreshed)
        await store.issueSingleScanPairing()
        XCTAssertNil(store.pairingIssueError)
        XCTAssertEqual(store.issuedPairingTicket?.deepLinkUrl, "amber://gateway/pair?p=refreshed")
    }

    func testFormattedEndpointsHandlesIPv4HostAndIPv6WithPort() {
        XCTAssertEqual(
            DesktopCloudSelfStore.formattedEndpoints(addresses: ["cloud.example.com", "100.64.0.10"], port: 443),
            "cloud.example.com:443 · 100.64.0.10:443"
        )
        XCTAssertEqual(
            DesktopCloudSelfStore.formattedEndpoints(addresses: ["2001:db8::1", "[::1]"], port: 47821),
            "[2001:db8::1]:47821 · [::1]:47821"
        )
    }
}
