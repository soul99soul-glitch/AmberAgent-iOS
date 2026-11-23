import Foundation
import Testing
@testable import iosApp

/// Plan 2 focused verification suite:
/// 1. Independent Cloud + Mac dual-slot persistence, Keychain isolation & revocation isolation.
/// 2. Legacy `macGateway.connection.v1` + `macGateway.deviceToken` seamless migration.
/// 3. Single-scan encrypted pairing (`amber-bootstrap+jwe`) & legacy `400 invalid_request` fallback on both slots.
/// 4. Concurrent dual-slot status/board/schedules/approvals refresh & 403 local-only isolation.
/// 5. Unified main-timeline 3-way execution target (`本机 / 云端 / Mac`), precise routing & card attribution badges.
@Suite(.serialized)
struct AmberMultiDeviceDualSlotTests {

    private final class InMemoryTokenVault: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]

        func load(_ key: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return storage[key]
        }

        func save(_ key: String, _ value: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            storage[key] = value
            return true
        }

        func delete(_ key: String) {
            lock.lock()
            defer { lock.unlock() }
            storage.removeValue(forKey: key)
        }

        var snapshot: [String: String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(host: String, method: String, path: String, auth: String?, body: [String: Any])] = []

        func append(request: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            let host = request.url?.host ?? ""
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            let auth = request.value(forHTTPHeaderField: "Authorization")
            let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            recorded.append((host, method, path, auth, body))
        }

        func items() -> [(host: String, method: String, path: String, auth: String?, body: [String: Any])] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    private static func httpResponse(url: URL, status: Int, json: String) -> (Data, URLResponse) {
        let resp = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(json.utf8), resp)
    }

    private static func makePairLink(
        id: String,
        name: String,
        addrs: [String],
        port: Int,
        fp: String = "fp-test-123456",
        secret: String = "sec-once",
        bootstrap: MacGatewayPairingBootstrapHint? = nil,
        role: MacGatewayEndpointRole? = nil
    ) throws -> String {
        let payload = MacGatewayPairingPayload(
            v: 1,
            id: id,
            name: name,
            addrs: addrs,
            port: port,
            fp: fp,
            s: secret,
            bootstrap: bootstrap,
            role: role
        )
        let encoded = IOSCloudConfigEnvelope.base64url(try JSONEncoder().encode(payload))
        return "amber://gateway/pair?p=\(encoded)"
    }

    // MARK: - 1. Independent Dual-Slot Persistence, Keychain & Revocation Isolation

    @Test @MainActor
    func cloudAndMacPairIndependentlyWithoutOverwritingEachOtherOrCrossRevoking() async throws {
        let suite = "plan2.dualSlot.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let vault = InMemoryTokenVault()
        let store = MacGatewayStore(
            defaults: defaults,
            loadToken: { vault.load($0) },
            saveToken: { vault.save($0, $1) },
            deleteToken: { vault.delete($0) }
        )

        // Pair Cloud slot first.
        let cloudLink = try Self.makePairLink(id: "gw-cloud-1", name: "Amber Cloud EU", addrs: ["cloud.example.com"], port: 443)
        store.receivePairingLink(cloudLink, preferredRole: .cloud)
        #expect(store.pendingPairing?.id == "gw-cloud-1")
        #expect(store.mac.pendingPairing == nil)

        await store.confirmPairing(
            for: .cloud,
            pairingTransport: { req, _ in
                let url = req.url!
                return Self.httpResponse(
                    url: url,
                    status: 200,
                    json: #"{"deviceId":"dev-cloud","token":"tok-cloud-secret","gatewayId":"gw-cloud-1","gatewayName":"Amber Cloud EU"}"#
                )
            }
        )

        // Pair Mac slot second — must NOT overwrite Cloud connection or Cloud Keychain token.
        let macLink = try Self.makePairLink(id: "gw-mac-1", name: "Arquiel MacBook Pro", addrs: ["192.168.1.42"], port: 47821)
        store.receivePairingLink(macLink, preferredRole: .mac)
        #expect(store.mac.pendingPairing?.id == "gw-mac-1")

        await store.confirmPairing(
            for: .mac,
            pairingTransport: { req, _ in
                let url = req.url!
                return Self.httpResponse(
                    url: url,
                    status: 200,
                    json: #"{"deviceId":"dev-mac","token":"tok-mac-secret","gatewayId":"gw-mac-1","gatewayName":"Arquiel MacBook Pro"}"#
                )
            }
        )

        #expect(store.hasCloudConnection)
        #expect(store.hasMacConnection)
        #expect(store.connection?.gatewayId == "gw-cloud-1")
        #expect(store.mac.connection?.gatewayId == "gw-mac-1")
        #expect(vault.load(MacGatewayEndpointRole.cloud.tokenStorageKey) == "tok-cloud-secret")
        #expect(vault.load(MacGatewayEndpointRole.mac.tokenStorageKey) == "tok-mac-secret")
        #expect(store.multiDeviceSummaryText.contains("云端"))
        #expect(store.multiDeviceSummaryText.contains("Mac"))

        // Cold-restart a fresh MacGatewayStore against the same defaults & Keychain vault.
        let relaunched = MacGatewayStore(
            defaults: defaults,
            loadToken: { vault.load($0) },
            saveToken: { vault.save($0, $1) },
            deleteToken: { vault.delete($0) }
        )
        #expect(relaunched.hasCloudConnection)
        #expect(relaunched.hasMacConnection)
        #expect(relaunched.connection?.gatewayId == "gw-cloud-1")
        #expect(relaunched.mac.connection?.gatewayId == "gw-mac-1")

        // Unpairing Mac must leave Cloud intact.
        await relaunched.unpair(role: .mac)
        #expect(!relaunched.hasMacConnection)
        #expect(relaunched.hasCloudConnection)
        #expect(relaunched.connection?.gatewayId == "gw-cloud-1")
        #expect(vault.load(MacGatewayEndpointRole.mac.tokenStorageKey) == nil)
        #expect(vault.load(MacGatewayEndpointRole.cloud.tokenStorageKey) == "tok-cloud-secret")
    }

    // MARK: - 2. Seamless Legacy Single-Slot Migration

    @Test @MainActor
    func legacyV1SingleSlotMigratesSeamlesslyToCloudByDefaultWithoutLosingToken() throws {
        let suite = "plan2.migrate.cloud.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacyConnection = MacGatewayConnection(
            gatewayId: "gw-legacy-cloud",
            name: "Amber Daemon",
            addrs: ["amber.mycloud.dev"],
            port: 443,
            fingerprint: "fp-legacy-cloud",
            deviceId: "dev-legacy-1"
        )
        defaults.set(try JSONEncoder().encode(legacyConnection), forKey: MacGatewayStore.legacyConnectionKey)

        let vault = InMemoryTokenVault()
        _ = vault.save(MacGatewayStore.legacyTokenKey, "tok-legacy-cloud-999")

        let store = MacGatewayStore(
            defaults: defaults,
            loadToken: { vault.load($0) },
            saveToken: { vault.save($0, $1) },
            deleteToken: { vault.delete($0) }
        )

        #expect(store.hasCloudConnection)
        #expect(!store.hasMacConnection)
        #expect(store.connection?.gatewayId == "gw-legacy-cloud")
        #expect(store.connection?.role == .cloud)
        #expect(vault.load(MacGatewayEndpointRole.cloud.tokenStorageKey) == "tok-legacy-cloud-999")
        #expect(defaults.data(forKey: MacGatewayStore.legacyConnectionKey) == nil)
        #expect(vault.load(MacGatewayStore.legacyTokenKey) == nil)
    }

    @Test @MainActor
    func legacyV1MacBookLanPairingMigratesToMacSlotAndPreservesDialogueState() throws {
        let suite = "plan2.migrate.mac.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacyMac = MacGatewayConnection(
            gatewayId: "gw-legacy-mac",
            name: "Studio Mac",
            addrs: ["192.168.1.99"],
            port: 47821,
            fingerprint: "fp-legacy-mac",
            deviceId: "dev-legacy-mac"
        )
        defaults.set(try JSONEncoder().encode(legacyMac), forKey: MacGatewayStore.legacyConnectionKey)

        let vault = InMemoryTokenVault()
        _ = vault.save(MacGatewayStore.legacyTokenKey, "tok-legacy-mac-777")

        let store = MacGatewayStore(
            defaults: defaults,
            loadToken: { vault.load($0) },
            saveToken: { vault.save($0, $1) },
            deleteToken: { vault.delete($0) }
        )

        #expect(!store.hasCloudConnection)
        #expect(store.hasMacConnection)
        #expect(store.mac.connection?.gatewayId == "gw-legacy-mac")
        #expect(store.mac.connection?.role == .mac)
        #expect(vault.load(MacGatewayEndpointRole.mac.tokenStorageKey) == "tok-legacy-mac-777")
        #expect(defaults.data(forKey: MacGatewayStore.legacyConnectionKey) == nil)
    }

    // MARK: - 3. Single-Scan Encrypted Pairing (`amber-bootstrap+jwe`) & Legacy `400 invalid_request` Fallback

    @Test(arguments: [MacGatewayEndpointRole.cloud, MacGatewayEndpointRole.mac]) @MainActor
    func legacyGateway400InvalidRequestFallbackWorksOnBothSlots(role: MacGatewayEndpointRole) async throws {
        let suite = "plan2.fallback400.\(role.rawValue).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let vault = InMemoryTokenVault()
        let store = MacGatewayStore(
            defaults: defaults,
            loadToken: { vault.load($0) },
            saveToken: { vault.save($0, $1) },
            deleteToken: { vault.delete($0) }
        )

        let link = try Self.makePairLink(
            id: "gw-old-\(role.rawValue)",
            name: role == .cloud ? "Old Cloud" : "Old MacBook",
            addrs: ["127.0.0.1"],
            port: 47821,
            bootstrap: MacGatewayPairingBootstrapHint(syncSupported: true)
        )
        store.receivePairingLink(link, preferredRole: role)

        let recorder = RequestRecorder()
        await store.confirmPairing(
            for: role,
            pairingTransport: { req, _ in
                recorder.append(request: req)
                let url = req.url!
                let body = (req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
                if url.path == "/v1/pair" {
                    if body["trustedApprovalSurface"] != nil || body["requestBootstrapSync"] != nil || body["clientPublicJwk"] != nil {
                        return Self.httpResponse(url: url, status: 400, json: #"{"error":"invalid_request"}"#)
                    }
                    return Self.httpResponse(
                        url: url,
                        status: 200,
                        json: #"{"deviceId":"dev-old","token":"tok-old-\#(role.rawValue)","gatewayId":"gw-old-\#(role.rawValue)","gatewayName":"Legacy Node"}"#
                    )
                }
                return Self.httpResponse(url: url, status: 404, json: #"{"error":"not_found"}"#)
            }
        )

        let pairCalls = recorder.items().filter { $0.path == "/v1/pair" }
        #expect(pairCalls.count == 2)
        #expect(pairCalls[0].body["requestBootstrapSync"] as? Bool == true)
        #expect(pairCalls[1].body["trustedApprovalSurface"] == nil)
        #expect(pairCalls[1].body["requestBootstrapSync"] == nil)
        #expect(pairCalls[1].body["clientPublicJwk"] == nil)

        let slot = store.slot(for: role)
        #expect(slot.connection?.gatewayId == "gw-old-\(role.rawValue)")
        #expect(vault.load(role.tokenStorageKey) == "tok-old-\(role.rawValue)")
    }

    @Test @MainActor
    func encryptedBootstrapPairingWorksOnMacSlotWithoutOverwritingCloudConfig() async throws {
        let suite = "plan2.bootstrap.mac.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let vault = InMemoryTokenVault()
        let soulStore = AgentSoulStore(userDefaults: defaults)
        let sharedSettings = IOSSharedSettingsStore(
            userDefaults: defaults,
            loadCredential: { vault.load($0) },
            storeCredential: { vault.save($0, $1) },
            deleteCredential: { vault.delete($0); return true }
        )
        let ruleURL = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ruleURL) }
        let ruleStore = IOSProceduralRuleStore(storageURL: ruleURL)

        let store = MacGatewayStore(
            defaults: defaults,
            loadToken: { vault.load($0) },
            saveToken: { vault.save($0, $1) },
            deleteToken: { vault.delete($0) }
        )
        store.cloudConfig = IOSCloudConfigSnapshot(
            gatewayId: "gw-cloud-existing",
            revision: 9,
            model: .init(provider: "openai", modelId: "gpt-5.4", baseUrl: "https://api.openai.com/v1", keyConfigured: true),
            search: [],
            searchSources: [],
            searchMode: "fallback",
            supportedModelProviders: ["openai"],
            supportedSearchSources: []
        )

        let macLink = try Self.makePairLink(
            id: "gw-mac-jwe",
            name: "Mac Studio",
            addrs: ["192.168.1.50"],
            port: 47821,
            bootstrap: MacGatewayPairingBootstrapHint(
                syncSupported: true,
                configRevision: 2,
                provider: "openai",
                authMode: "apiKey",
                siwcConfigured: false,
                hasEncryptedCredentials: true,
                soulRevision: 0,
                activeRulesCount: 0
            )
        )
        store.receivePairingLink(macLink, preferredRole: .mac)

        await store.confirmPairing(
            for: .mac,
            sharedSettings: sharedSettings,
            soulStore: soulStore,
            ruleStore: ruleStore,
            pairingTransport: { req, _ in
                let url = req.url!
                let body = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]) ?? [:]
                let jwk = try #require(body["clientPublicJwk"] as? [String: String])
                let now = Int64(Date().timeIntervalSince1970)
                let envelope = IOSBootstrapEnvelopePayload(
                    version: 1,
                    gatewayId: "gw-mac-jwe",
                    deviceId: "dev-mac-jwe",
                    issuedAt: now,
                    expiresAt: now + 300,
                    configRevision: 2,
                    model: .init(provider: "openai", modelId: "gpt-4.1", baseUrl: "https://api.openai.com/v1"),
                    search: .init(sources: [], mode: "fallback"),
                    credentials: .init(modelApiKey: nil, exaApiKey: nil, braveApiKey: nil)
                )
                let jwe = try IOSPairingBootstrapCrypto.seal(envelope, publicJwk: jwk)
                let responseObj: [String: Any] = [
                    "deviceId": "dev-mac-jwe",
                    "token": "tok-mac-jwe",
                    "gatewayId": "gw-mac-jwe",
                    "gatewayName": "Mac Studio",
                    "bootstrap": [
                        "version": 1,
                        "encryptedConfigJwe": jwe,
                        "configuration": [
                            "gatewayId": "gw-mac-jwe",
                            "revision": 2,
                            "model": [
                                "provider": "openai",
                                "modelId": "gpt-4.1",
                                "baseUrl": "https://api.openai.com/v1",
                                "authMode": "apiKey",
                                "siwcConfigured": false,
                            ],
                            "search": [
                                "sources": [],
                                "mode": "fallback",
                            ],
                            "credentials": [
                                "modelApiKey": ["configured": false],
                                "exaApiKey": ["configured": false],
                                "braveApiKey": ["configured": false],
                            ],
                        ],
                        "activeRules": [],
                    ],
                ]
                let data = try JSONSerialization.data(withJSONObject: responseObj)
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (data, resp)
            }
        )

        #expect(store.mac.connection?.gatewayId == "gw-mac-jwe")
        #expect(store.mac.lastBootstrapSyncSummary != nil)
        // Cloud config remains completely untouched.
        #expect(store.cloudConfig?.gatewayId == "gw-cloud-existing")
        #expect(store.cloudConfig?.revision == 9)
    }

    // MARK: - 4. Concurrent Dual-Slot Refresh & 403 Local-Approval Isolation

    @Test @MainActor
    func refreshAllFetchesCloudAndMacConcurrentlyAndIsolates403AndBoardState() async throws {
        let suite = "plan2.concurrentRefresh.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = MacGatewayStore(defaults: defaults, isApplicationForeground: { true })

        let cloudClient = MacGatewayClient(
            addrs: ["cloud.local"],
            port: 443,
            fingerprint: "fp-c",
            token: "tok-c",
            transport: { req, _ in
                let url = req.url!
                switch url.path {
                case "/v1/status":
                    return Self.httpResponse(
                        url: url,
                        status: 200,
                        json: #"{"gateway":{"id":"gw-cloud","name":"Amber Cloud"},"device":{"id":"dev-c","name":"iPhone","pushRegistered":true},"serverTime":1800000000,"sessions":[]}"#
                    )
                case "/v1/amber/board":
                    return Self.httpResponse(url: url, status: 200, json: #"{"board":[]}"#)
                case "/v1/amber/schedules":
                    return Self.httpResponse(url: url, status: 200, json: #"{"schedules":[]}"#)
                case "/v2/dialogue/events":
                    return Self.httpResponse(url: url, status: 200, json: #"{"items":[],"nextCursor":0}"#)
                default:
                    return Self.httpResponse(url: url, status: 404, json: #"{"error":"not_found"}"#)
                }
            }
        )

        let macClient = MacGatewayClient(
            addrs: ["mac.local"],
            port: 47821,
            fingerprint: "fp-m",
            token: "tok-m",
            transport: { req, _ in
                let url = req.url!
                switch url.path {
                case "/v1/status":
                    return Self.httpResponse(
                        url: url,
                        status: 200,
                        json: #"""
                        {
                          "gateway":{"id":"gw-mac","name":"Studio Mac"},
                          "device":{"id":"dev-m","name":"iPhone","pushRegistered":true},
                          "serverTime":1800000000,
                          "sessions":[
                            {"key":"claude:s1","agent":"claude","subject":"amberagent-ios","summary":"实现方案2双槽位","origin":"cli","host":"Synara","state":"running","abnormal":false,"monitored":true,"updatedAt":1800000000}
                          ]
                        }
                        """#
                    )
                case "/v1/amber/board":
                    return Self.httpResponse(
                        url: url,
                        status: 200,
                        json: #"""
                        {
                          "board":[
                            {
                              "id":"run:mac-approve",
                              "kind":"run",
                              "column":"needsYou",
                              "title":"执行构建脚本",
                              "detail":"等你确认 · shell_run",
                              "updatedAt":1800000000,
                              "waitingForReply":false,
                              "failed":false,
                              "approval":{
                                "sessionKey":"amber:mac-run-1",
                                "toolCallId":"call-mac-403",
                                "tool":"shell_run",
                                "detail":"rm -rf build",
                                "highRisk":true,
                                "requiresLocalApproval":false
                              }
                            }
                          ]
                        }
                        """#
                    )
                case "/v1/amber/schedules":
                    return Self.httpResponse(
                        url: url,
                        status: 200,
                        json: #"{"schedules":[{"id":"sched-mac-1","name":"每日备份","rule":"每天 09:00","enabled":true,"running":false,"autoApprovesHighRisk":false}]}"#
                    )
                case "/v1/amber/decision":
                    return Self.httpResponse(url: url, status: 403, json: #"{"error":"local_approval_only"}"#)
                case "/v2/dialogue/events":
                    return Self.httpResponse(url: url, status: 200, json: #"{"items":[],"nextCursor":0}"#)
                default:
                    return Self.httpResponse(url: url, status: 404, json: #"{"error":"not_found"}"#)
                }
            }
        )

        store.configureForTesting(
            role: .cloud,
            connection: MacGatewayConnection(gatewayId: "gw-cloud", name: "Amber Cloud", addrs: ["cloud.local"], port: 443, fingerprint: "fp-c", deviceId: "dev-c"),
            client: cloudClient
        )
        store.configureForTesting(
            role: .mac,
            connection: MacGatewayConnection(gatewayId: "gw-mac", name: "Studio Mac", addrs: ["mac.local"], port: 47821, fingerprint: "fp-m", deviceId: "dev-m"),
            client: macClient
        )

        await store.refreshAll()
        defer {
            store.stopCloudDialoguePolling()
            store.mac.stopCloudDialoguePolling()
        }

        #expect(store.isReachable == true)
        #expect(store.mac.isReachable == true)
        #expect(store.status?.gateway.name == "Amber Cloud")
        #expect(store.mac.status?.gateway.name == "Studio Mac")
        #expect(store.mac.status?.sessions.count == 1)
        #expect(store.mac.schedules?.first?.name == "每日备份")
        #expect(store.schedules?.isEmpty == true)
        #expect(store.combinedNeedsYouItems.count == 1)
        #expect(store.combinedNeedsYouItems.first?.id == "run:mac-approve")

        // Verify unified task builder surfaces Mac slot schedules and board items alongside Cloud.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("plan2-unified-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults)
        let subAgentStore = IOSSubAgentActivityStore(tasks: taskStore, defaults: defaults, loadRuns: { [] })
        let wakeStore = IOSWakeTaskStore(fileURL: tempDir.appendingPathComponent("wake.json"))
        let hubStore = AmberHubStore(defaults: defaults)
        let unifiedGroups = AmberUnifiedTaskBuilder.buildTasks(
            gateway: store,
            subAgentStore: subAgentStore,
            taskStore: taskStore,
            wakeStore: wakeStore,
            hubStore: hubStore
        )
        #expect(unifiedGroups.needsAttention.contains(where: { $0.id == "mac-board:run:mac-approve" }))
        #expect(unifiedGroups.scheduled.contains(where: { $0.id == "mac-schedule:sched-mac-1" }))

        // Trigger HTTP 403 on Mac approval -> only Mac slot marks `call-mac-403` as local-only.
        let stubBiometric = AlwaysPassBiometric()
        let macOnlyStore = MacGatewayStore(
            defaults: defaults,
            biometricAuthenticator: stubBiometric,
            isApplicationForeground: { true },
            endpointRole: .mac,
            isChildSlot: true
        )
        macOnlyStore.configureForTesting(
            role: .mac,
            connection: MacGatewayConnection(gatewayId: "gw-mac", name: "Studio Mac", addrs: ["mac.local"], port: 47821, fingerprint: "fp-m", deviceId: "dev-m"),
            client: macClient
        )
        await macOnlyStore.refresh(role: .mac)
        let allowed = await macOnlyStore.decide(sessionKey: "amber:mac-run-1", toolCallId: "call-mac-403", allow: true, source: .foregroundApp, role: .mac)
        #expect(allowed == false)
        #expect(macOnlyStore.localApprovalOnlyCallIds.contains("call-mac-403"))
        #expect(!store.localApprovalOnlyCallIds.contains("call-mac-403"))
    }

    // MARK: - 5. Three-Way Routing & Card Attribution Badges

    @Test @MainActor
    func unifiedTimelineRoutesCloudAndMacToTheirRespectiveClientsWithDistinctBadges() async throws {
        let suite = "plan2.threeWayRouting.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let recorder = RequestRecorder()
        let convId = "conv-three-way-1"

        let cloudClient = MacGatewayClient(
            addrs: ["cloud.route.test"],
            port: 443,
            fingerprint: "fp-c",
            token: "tok-cloud",
            transport: { req, _ in
                recorder.append(request: req)
                let url = req.url!
                if url.path == "/v2/dialogue/messages" {
                    return Self.httpResponse(
                        url: url,
                        status: 202,
                        json: #"{"requestId":"req-cloud-1","eventId":"ev-c1","topicId":"topic-c1","workItemIds":["wi-cloud-1"],"state":"received","replayed":false,"conversationId":"\#(convId)"}"#
                    )
                }
                return Self.httpResponse(url: url, status: 200, json: #"{"items":[],"nextCursor":0}"#)
            }
        )

        let macClient = MacGatewayClient(
            addrs: ["mac.route.test"],
            port: 47821,
            fingerprint: "fp-m",
            token: "tok-mac",
            transport: { req, _ in
                recorder.append(request: req)
                let url = req.url!
                if url.path == "/v2/dialogue/messages" {
                    return Self.httpResponse(
                        url: url,
                        status: 202,
                        json: #"{"requestId":"req-mac-1","eventId":"ev-m1","topicId":"topic-m1","workItemIds":["wi-mac-1"],"state":"received","replayed":false,"conversationId":"\#(convId)"}"#
                    )
                }
                return Self.httpResponse(url: url, status: 200, json: #"{"items":[],"nextCursor":0}"#)
            }
        )

        let store = MacGatewayStore(defaults: defaults)
        store.configureForTesting(
            role: .cloud,
            connection: MacGatewayConnection(gatewayId: "gw-c", name: "Amber Cloud", addrs: ["cloud.route.test"], port: 443, fingerprint: "fp-c", deviceId: "d-c"),
            client: cloudClient
        )
        store.configureForTesting(
            role: .mac,
            connection: MacGatewayConnection(gatewayId: "gw-m", name: "Studio Mac", addrs: ["mac.route.test"], port: 47821, fingerprint: "fp-m", deviceId: "d-m"),
            client: macClient
        )
        defer {
            store.stopCloudDialoguePolling()
            store.mac.stopCloudDialoguePolling()
        }

        // Dispatch one task to Cloud and one task to Mac on the exact same unified conversation.
        let cloudRes = await store.delegateInUnifiedTimeline(
            to: .cloud,
            text: "总结云端日志",
            conversationId: convId,
            requestId: "req-cloud-1"
        )
        let macRes = await store.delegateInUnifiedTimeline(
            to: .mac,
            text: "编译本地 Xcode 工程",
            conversationId: convId,
            requestId: "req-mac-1"
        )
        store.stopCloudDialoguePolling()
        store.mac.stopCloudDialoguePolling()

        #expect((try? cloudRes.get().workItemIds) == ["wi-cloud-1"])
        #expect((try? macRes.get().workItemIds) == ["wi-mac-1"])

        let postRequests = recorder.items().filter { $0.path == "/v2/dialogue/messages" }
        #expect(postRequests.count == 2)
        #expect(postRequests.contains { $0.host == "cloud.route.test" && $0.auth == "Bearer tok-cloud" })
        #expect(postRequests.contains { $0.host == "mac.route.test" && $0.auth == "Bearer tok-mac" })

        // Verify unified timeline runs carry distinct endpoint roles & distinct attribution badges.
        let runs = store.allUnifiedDelegatedRuns(for: convId)
        #expect(runs.count == 2)
        let cloudRun = try #require(runs.first(where: { $0.workItemId == "wi-cloud-1" }))
        let macRun = try #require(runs.first(where: { $0.workItemId == "wi-mac-1" }))
        #expect(cloudRun.endpointRole == .cloud)
        #expect(macRun.endpointRole == .mac)
        #expect(cloudRun.badge.label(for: .cloud) == "云端执行中")
        #expect(macRun.badge.label(for: .mac) == "Mac 执行中")

        // Verify unpairing Mac automatically normalizes bottom execution target back to `.local`.
        #expect(AmberHostSwitcherPillPolicy.normalizedTarget(.mac, cloudPaired: true, macPaired: false) == .local)
        #expect(AmberHostSwitcherPillPolicy.normalizedTarget(.cloud, cloudPaired: true, macPaired: false) == .cloud)
    }

    private struct AlwaysPassBiometric: MacGatewayBiometricAuthenticating {
        func verifyForegroundApproval(reason: String) async -> Bool { true }
    }
}
