import CryptoKit
import Security
import XCTest
@testable import AmberMac

/// macOS 出站云端配对/配置导入的定点测试：解析、错误映射、本机目录、
/// 「所选才上传」「空Key保留」「删除独立」「401吊销」「冲突保留」等失败与脱敏语义。
/// 全部使用内存凭据与假值，不触 Keychain、不触真实 TLS。
final class DesktopCloudSelfTests: XCTestCase {

    // MARK: fakes

    final class MemoryTokens: DesktopCloudTokenStore, @unchecked Sendable {
        var values: [String: String] = [:]
        func load(key: String) -> String? { values[key] }
        @discardableResult func store(key: String, value: String) -> Bool { values[key] = value; return true }
        @discardableResult func delete(key: String) -> Bool { values.removeValue(forKey: key); return true }
    }

    final class FakeSync: DesktopCloudConfigSync, @unchecked Sendable {
        var remote = DesktopCloudRemoteConfig(
            model: .init(provider: "openai", modelId: "gpt-old", baseURL: "https://api.openai.com/v1",
                         keyConfigured: true),
            search: .init(sources: ["bing"], mode: "fallback",
                          exaKeyConfigured: false, braveKeyConfigured: false),
            configuredSecrets: ["modelApiKey"], revision: 3)
        var applyError: (any Error)?
        var fetchError: (any Error)?
        var received: [(apply: DesktopCloudConfigApply, requestId: String)] = []

        func fetchConfig() async throws -> DesktopCloudRemoteConfig {
            if let fetchError { throw fetchError }
            return remote
        }
        func applyConfig(_ request: DesktopCloudConfigApply, requestId: String) async throws -> DesktopCloudRemoteConfig {
            received.append((request, requestId))
            if let applyError { throw applyError }
            return remote
        }
    }

    private let connection = DesktopCloudConnection(
        gatewayId: "cloud-1", name: "云端主机", addrs: ["100.64.1.2"], port: 47_821,
        fingerprint: "fp-fixture", deviceId: "mac-device-1")

    @MainActor
    private func makePairedStore(
        sync: FakeSync? = FakeSync(),
        settings: (DesktopSettings, DesktopMemoryCredentials)? = nil,
        search: (DesktopSearchSettings, DesktopMemoryCredentials)? = nil
    ) -> (DesktopCloudSelfStore, MemoryTokens, UserDefaults) {
        let defaults = UserDefaults(suiteName: "test.cloudSelf.\(UUID().uuidString)")!
        let tokens = MemoryTokens()
        let providerCredentials = settings?.1 ?? DesktopMemoryCredentials()
        let providerSettings = settings?.0 ?? DesktopSettings(
            defaults: UserDefaults(suiteName: "test.cloudSelf.providers.\(UUID().uuidString)")!,
            credentials: providerCredentials)
        let searchCredentials = search?.1 ?? DesktopMemoryCredentials()
        let searchSettings = search?.0 ?? DesktopSearchSettings(
            defaults: UserDefaults(suiteName: "test.cloudSelf.search.\(UUID().uuidString)")!,
            credentials: searchCredentials)
        defaults.set(try? JSONEncoder().encode(connection), forKey: "desktop.cloudSelf.connection.v1")
        tokens.store(key: "cloudSelf.deviceToken", value: "fake-device-token")
        let store = DesktopCloudSelfStore(
            settings: providerSettings, searchSettings: searchSettings,
            defaults: defaults, tokens: tokens) { _, _ in sync }
        return (store, tokens, defaults)
    }

    private func link(_ payload: DesktopCloudPairingPayload) throws -> String {
        let encoded = try JSONEncoder().encode(payload)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "amber://gateway/pair?p=\(encoded)"
    }

    private var payload: DesktopCloudPairingPayload {
        DesktopCloudPairingPayload(v: 1, id: "cloud-1", name: "云端主机",
            addrs: ["100.64.1.2"], port: 47_821, fp: "fingerprint", s: "secret")
    }

    // MARK: pairing link parsing

    func testPairingLinkParsingAcceptsFullLinkAndBareValue() throws {
        let url = try link(payload)
        XCTAssertEqual(DesktopCloudPairingPayload.parse(url), payload)
        XCTAssertEqual(DesktopCloudPairingPayload.parse("  \n\(url)  "), payload)
        let bare = url.components(separatedBy: "p=").last!
        XCTAssertEqual(DesktopCloudPairingPayload.parse(bare), payload)
    }

    func testPairingLinkParsingRejectsMalformed() {
        XCTAssertNil(DesktopCloudPairingPayload.parse(""))
        XCTAssertNil(DesktopCloudPairingPayload.parse("amber://gateway/pair?p=%%%"))
        XCTAssertNil(DesktopCloudPairingPayload.parse(String(repeating: "a", count: 4_200)))
        var wrongVersion = payload; wrongVersion.v = 2
        XCTAssertNil(DesktopCloudPairingPayload.parse(try! link(wrongVersion)))
        var noFingerprint = payload; noFingerprint.fp = ""
        XCTAssertNil(DesktopCloudPairingPayload.parse(try! link(noFingerprint)))
        var noAddresses = payload; noAddresses.addrs = []
        XCTAssertNil(DesktopCloudPairingPayload.parse(try! link(noAddresses)))
    }

    // MARK: response mapping

    func testResponseErrorMapping() {
        XCTAssertNil(DesktopCloudClient.responseError(status: 200, data: Data()))
        XCTAssertNil(DesktopCloudClient.responseError(status: 204, data: Data()))
        XCTAssertEqual(DesktopCloudClient.responseError(status: 401, data: Data()), .unauthorized)
        let conflict = DesktopCloudClient.responseError(
            status: 409, data: Data(#"{"error":"version mismatch"}"#.utf8))
        if case .conflict(let message) = conflict {
            XCTAssertEqual(message, "version mismatch")
        } else { XCTFail("409 必须映射为 conflict") }
        XCTAssertEqual(DesktopCloudClient.responseError(status: 410, data: Data()), .envelopeExpired)
        XCTAssertEqual(DesktopCloudClient.responseError(status: 500, data: Data()), .server("HTTP 500"))
    }

    // MARK: restore

    @MainActor func testRestoreRequiresBothConnectionAndToken() {
        let (store, _, _) = makePairedStore()
        XCTAssertEqual(store.connection, connection)
        XCTAssertTrue(store.canSyncConfig)
        let defaults = UserDefaults(suiteName: "test.cloudSelf.noToken.\(UUID().uuidString)")!
        defaults.set(try? JSONEncoder().encode(connection), forKey: "desktop.cloudSelf.connection.v1")
        let unpaired = DesktopCloudSelfStore(
            settings: DesktopSettings(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!,
                                    credentials: DesktopMemoryCredentials()),
            searchSettings: DesktopSearchSettings(defaults: UserDefaults(suiteName: "t2.\(UUID().uuidString)")!,
                                                  credentials: DesktopMemoryCredentials()),
            defaults: defaults, tokens: MemoryTokens())
        XCTAssertNil(unpaired.connection)
        XCTAssertFalse(unpaired.canSyncConfig)
    }

    // MARK: import catalog

    @MainActor func testImportCatalogReflectsLocalSources() throws {
        let providerDefaults = UserDefaults(suiteName: "test.catalog.providers.\(UUID().uuidString)")!
        let providerCredentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(defaults: providerDefaults, credentials: providerCredentials)
        let openAI = DesktopProviderConfiguration(
            name: "OpenAI", kind: .openAI, baseURL: "https://api.openai.com/v1", modelID: "gpt-5-mini")
        try settings.saveProvider(openAI, apiKey: "sk-local-fake")
        var oauth = DesktopProviderConfiguration(
            name: "Codex", kind: .responses, baseURL: "https://chatgpt.com/backend-api", modelID: "gpt-5")
        oauth.authMode = .codexOAuth
        try settings.saveProvider(oauth, apiKey: "")
        settings.selectedProviderID = openAI.id

        let searchDefaults = UserDefaults(suiteName: "test.catalog.search.\(UUID().uuidString)")!
        let searchCredentials = DesktopMemoryCredentials()
        let searchSettings = DesktopSearchSettings(defaults: searchDefaults, credentials: searchCredentials)
        try searchSettings.saveConfiguration(
            enabledServices: [.free, .exa], apiKeys: [.exa: "exa-local-fake"])

        let (store, _, _) = makePairedStore(
            settings: (settings, providerCredentials), search: (searchSettings, searchCredentials))
        let catalog = store.importCatalog()

        let openAIItem = try XCTUnwrap(catalog.providers.first { $0.id == openAI.id })
        XCTAssertTrue(openAIItem.exportable)
        XCTAssertTrue(openAIItem.hasAPIKey)
        XCTAssertTrue(openAIItem.selectedLocally)
        XCTAssertEqual(openAIItem.modelDisplay, "gpt-5-mini")

        let oauthItem = try XCTUnwrap(catalog.providers.first { $0.id == oauth.id })
        XCTAssertFalse(oauthItem.exportable)
        XCTAssertFalse(oauthItem.hasAPIKey)

        let free = try XCTUnwrap(catalog.search.first { $0.id == .free })
        XCTAssertEqual(free.cloudSources, ["bing", "duckduckgo"])
        XCTAssertNil(free.secretKey)
        XCTAssertTrue(free.supported)
        XCTAssertTrue(free.enabledLocally)

        let exa = try XCTUnwrap(catalog.search.first { $0.id == .exa })
        XCTAssertEqual(exa.cloudSources, ["exa"])
        XCTAssertEqual(exa.secretKey, "exaApiKey")
        XCTAssertTrue(exa.hasAPIKey)

        let brave = try XCTUnwrap(catalog.search.first { $0.id == .brave })
        XCTAssertTrue(brave.supported)
        XCTAssertFalse(brave.hasAPIKey)
        XCTAssertFalse(brave.enabledLocally)

        let tavily = try XCTUnwrap(catalog.search.first { $0.id == .tavily })
        XCTAssertFalse(tavily.supported)
    }

    // MARK: import apply — 所选才上传 / 空项不打包 / 删除独立

    @MainActor func testImportUploadsOnlySelectedSecretsAndMappedFields() async throws {
        let providerCredentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(
            defaults: UserDefaults(suiteName: "test.import.providers.\(UUID().uuidString)")!,
            credentials: providerCredentials)
        let provider = DesktopProviderConfiguration(
            name: "OpenAI", kind: .openAI, baseURL: "https://api.openai.com/v1", modelID: "gpt-5-mini")
        try settings.saveProvider(provider, apiKey: "sk-import-fake")
        let searchCredentials = DesktopMemoryCredentials()
        let searchSettings = DesktopSearchSettings(
            defaults: UserDefaults(suiteName: "test.import.search.\(UUID().uuidString)")!,
            credentials: searchCredentials)
        try searchSettings.saveConfiguration(
            enabledServices: [.free, .exa], apiKeys: [.exa: "exa-import-fake"])

        let sync = FakeSync()
        let (store, _, _) = makePairedStore(
            sync: sync, settings: (settings, providerCredentials), search: (searchSettings, searchCredentials))
        await store.refreshRemoteConfig()
        let catalog = store.importCatalog()
        let plan = DesktopCloudImportPlan(
            providerID: provider.id, searchServices: [.free, .exa],
            searchMode: .sequentialFallback)
        let error = await store.import(plan, catalog: catalog, requestId: "req-1")
        XCTAssertNil(error)

        let (apply, requestId) = try XCTUnwrap(sync.received.last)
        XCTAssertEqual(requestId, "req-1")
        // 只上传所选：exa 在选、brave 不在选 → brave 不得出现在打包内容里。
        XCTAssertEqual(apply.secrets["modelApiKey"], "sk-import-fake")
        XCTAssertEqual(apply.secrets["exaApiKey"], "exa-import-fake")
        XCTAssertNil(apply.secrets["braveApiKey"])
        XCTAssertEqual(apply.secrets.count, 2)
        XCTAssertTrue(apply.includesModel)
        XCTAssertTrue(apply.includesSearch)
        XCTAssertEqual(apply.config.modelProvider, "openai")
        XCTAssertEqual(apply.config.modelId, "gpt-5-mini")
        XCTAssertEqual(apply.config.modelBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(apply.config.searchSources, ["bing", "duckduckgo", "exa"])
        XCTAssertEqual(apply.config.searchMode, "fallback")
        XCTAssertEqual(apply.config.baseRevision, 3)
        XCTAssertTrue(apply.config.deletes.isEmpty)
        // 回执只携带「已配置」名字，不含值。
        XCTAssertEqual(store.lastConfiguredSecrets, ["modelApiKey"])
    }

    @MainActor func testImportRejectsProviderWithoutLocalKey() async throws {
        let credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(
            defaults: UserDefaults(suiteName: "test.nokey.providers.\(UUID().uuidString)")!,
            credentials: credentials)
        let provider = DesktopProviderConfiguration(
            name: "OpenAI", kind: .openAI, baseURL: "https://api.openai.com/v1", modelID: "gpt-5-mini")
        try settings.saveProvider(provider, apiKey: "temporary")
        try credentials.delete(id: provider.id)
        let sync = FakeSync()
        let (store, _, _) = makePairedStore(sync: sync, settings: (settings, credentials))
        let plan = DesktopCloudImportPlan(providerID: provider.id)
        let error = await store.import(plan, catalog: store.importCatalog(), requestId: "req-x")
        XCTAssertNotNil(error)
        XCTAssertTrue(sync.received.isEmpty, "没有 Key 的项不得发出上传请求")
    }

    @MainActor func testImportRejectsOAuthProvider() async throws {
        let credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(
            defaults: UserDefaults(suiteName: "test.oauth.\(UUID().uuidString)")!,
            credentials: credentials)
        var oauth = DesktopProviderConfiguration(
            name: "Codex", kind: .responses, baseURL: "https://chatgpt.com/backend-api", modelID: "gpt-5")
        oauth.authMode = .codexOAuth
        try settings.saveProvider(oauth, apiKey: "")
        let sync = FakeSync()
        let (store, _, _) = makePairedStore(sync: sync, settings: (settings, credentials))
        let error = await store.import(
            DesktopCloudImportPlan(providerID: oauth.id), catalog: store.importCatalog(), requestId: "req-oauth")
        XCTAssertNotNil(error)
        XCTAssertTrue(sync.received.isEmpty)
    }

    // MARK: manual apply — 空Key保留 / 删除独立 / requestId 稳定

    @MainActor func testApplyRemoteConfigKeepsEmptyKeys() async throws {
        let sync = FakeSync()
        let (store, _, _) = makePairedStore(sync: sync)
        var draft = DesktopCloudConfigDraft(
            modelProvider: "claude", modelId: "claude-sonnet-4", modelBaseURL: "https://api.anthropic.com/v1",
            searchSources: ["brave"], searchMode: "aggregate", baseRevision: 3)
        draft.deletes = ["exaApiKey"]
        let error = await store.applyRemoteConfig(draft, requestId: "req-keep")
        XCTAssertNil(error)
        let (apply, _) = try XCTUnwrap(sync.received.last)
        XCTAssertTrue(apply.secrets.isEmpty, "空 Key 输入必须保留原值，不得上传空串")
        XCTAssertTrue(apply.includesModel && apply.includesSearch)
        XCTAssertEqual(apply.config.deletes, ["exaApiKey"])
        XCTAssertEqual(apply.config.baseRevision, 3)
    }

    @MainActor func testApplyRemoteConfigTreatsPlaceholderAsKeep() async throws {
        let sync = FakeSync()
        let (store, _, _) = makePairedStore(sync: sync)
        let draft = DesktopCloudConfigDraft(modelProvider: "openai", modelId: "gpt-5-mini",
            modelApiKey: "••••••••", baseRevision: 3)
        let error = await store.applyRemoteConfig(draft, requestId: "req-ph")
        XCTAssertNil(error)
        XCTAssertTrue(try XCTUnwrap(sync.received.last).apply.secrets.isEmpty,
                      "脱敏占位符不得作为 Key 上传")
    }

    /// 契约 credential_action_required：已存模型 Key 时改 provider/baseURL 必须带真 Key 或删除。
    @MainActor func testCredentialActionRequiredGuard() async throws {
        let sync = FakeSync() // remote: provider=openai, baseURL=api.openai.com, keyConfigured=true
        let (store, _, _) = makePairedStore(sync: sync)
        await store.refreshRemoteConfig()
        // 换 provider 不带 Key 不删除 → 客户端提前拒绝，不发出请求。
        let blocked = await store.applyRemoteConfig(
            DesktopCloudConfigDraft(modelProvider: "claude", modelId: "claude-sonnet-4",
                modelBaseURL: "https://api.openai.com/v1", baseRevision: 3), requestId: "req-g1")
        guard case .server(let message) = blocked else { return XCTFail("应被客户端拦截") }
        XCTAssertTrue(message.contains("模型 Key"))
        XCTAssertTrue(sync.received.isEmpty, "拦截在客户端，不得发出请求")
        // 只改 modelId → 允许（Key 保留）。
        let ok = await store.applyRemoteConfig(
            DesktopCloudConfigDraft(modelProvider: "openai", modelId: "gpt-5-mini",
                modelBaseURL: "https://api.openai.com/v1", baseRevision: 3), requestId: "req-g2")
        XCTAssertNil(ok)
        // 换 provider + 显式删除旧 Key → 允许。
        var deleting = DesktopCloudConfigDraft(modelProvider: "claude", modelId: "claude-sonnet-4",
            modelBaseURL: "https://api.openai.com/v1", baseRevision: 3)
        deleting.deletes = ["modelApiKey"]
        let deleted = await store.applyRemoteConfig(deleting, requestId: "req-g3")
        XCTAssertNil(deleted)
        // 换 baseURL + 新 Key → 允许。
        let replaced = await store.applyRemoteConfig(
            DesktopCloudConfigDraft(modelProvider: "openai", modelId: "m",
                modelBaseURL: "https://api.deepseek.com/v1", modelApiKey: "sk-new",
                baseRevision: 3), requestId: "req-g4")
        XCTAssertNil(replaced)
        XCTAssertEqual(sync.received.count, 3)
    }

    @MainActor func testApplyRemoteConfigRetryKeepsSameRequestId() async throws {
        let sync = FakeSync()
        sync.applyError = DesktopCloudError.unreachable
        let (store, _, _) = makePairedStore(sync: sync)
        let draft = DesktopCloudConfigDraft(modelProvider: "openai", modelId: "gpt-5-mini",
            modelApiKey: "sk-retry", baseRevision: 3)
        _ = await store.applyRemoteConfig(draft, requestId: "req-stable")
        sync.applyError = nil
        _ = await store.applyRemoteConfig(draft, requestId: "req-stable")
        XCTAssertEqual(sync.received.map { $0.requestId }, ["req-stable", "req-stable"])
    }

    // MARK: failure semantics — 401吊销 / 冲突与失败保留配对

    @MainActor func testUnauthorizedForgetsPairing() async throws {
        let sync = FakeSync()
        sync.applyError = DesktopCloudError.unauthorized
        let (store, tokens, defaults) = makePairedStore(sync: sync)
        _ = await store.applyRemoteConfig(DesktopCloudConfigDraft(), requestId: "req-401")
        XCTAssertNil(store.connection)
        XCTAssertNil(tokens.load(key: "cloudSelf.deviceToken"))
        XCTAssertNil(defaults.data(forKey: "desktop.cloudSelf.connection.v1"))
        XCTAssertEqual(store.notice?.text, DesktopCloudError.unauthorized.localizedDescription)
    }

    @MainActor func testConflictKeepsPairingAndDoesNotOverwriteRemote() async throws {
        let sync = FakeSync()
        sync.applyError = DesktopCloudError.conflict("version mismatch")
        let (store, _, _) = makePairedStore(sync: sync)
        await store.refreshRemoteConfig()
        // 只改 modelId（保留 provider/baseURL/Key）让冲突能到达 sync 层。
        let error = await store.applyRemoteConfig(
            DesktopCloudConfigDraft(modelProvider: "openai", modelId: "gpt-5-mini",
                modelBaseURL: "https://api.openai.com/v1", baseRevision: 3),
            requestId: "req-conflict")
        guard case .conflict = error else { return XCTFail("冲突必须透传") }
        XCTAssertNotNil(store.connection, "冲突不得清掉配对")
        XCTAssertEqual(store.remoteConfig?.revision, 3, "冲突后旧云端配置仍可用")
    }

    // MARK: mapping helpers

    func testCloudSearchSourcesRespectLocalOrder() {
        let order: [DesktopSearchService] = [.brave, .free, .exa, .tavily]
        XCTAssertEqual(
            DesktopCloudSelfStore.cloudSearchSources(for: [.free, .exa, .brave], order: order),
            ["brave", "bing", "duckduckgo", "exa"])
        XCTAssertEqual(
            DesktopCloudSelfStore.cloudSearchSources(for: [.free], order: order),
            ["bing", "duckduckgo"])
    }

    func testCloudProviderNameMapping() {
        XCTAssertEqual(DesktopCloudSelfStore.cloudProviderName(for: .openAI), "openai")
        XCTAssertEqual(DesktopCloudSelfStore.cloudProviderName(for: .responses), "openai")
        XCTAssertEqual(DesktopCloudSelfStore.cloudProviderName(for: .claude), "claude")
        XCTAssertEqual(DesktopCloudSelfStore.cloudProviderName(for: .gemini), "gemini")
    }

    // MARK: contract crypto — 与 Security/CryptoKit 标准原语的互通回环（fakeKey only）

    private struct RSAFixture {
        var privateKey: SecKey
        var publicKeyData: Data   // PKCS#1 DER
        var jwkE: String
        var jwkN: String
        var kid: String
        var spkiDER: Data
    }

    private func makeRSAFixture() throws -> RSAFixture {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 3072,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else { throw XCTSkip("本机无法生成内存 RSA 密钥") }
        let components = try DesktopCloudRSA.parsePKCS1(pkcs1)
        let jwkE = DesktopCloudBase64URL.encode(components.exponent)
        let jwkN = DesktopCloudBase64URL.encode(components.modulus)
        return RSAFixture(privateKey: privateKey, publicKeyData: pkcs1, jwkE: jwkE, jwkN: jwkN,
            kid: DesktopCloudRSA.jwkThumbprint(e: jwkE, n: jwkN),
            spkiDER: DesktopCloudRSA.spkiWrappingPKCS1(pkcs1))
    }

    /// 契约要求：响应 kid 必须由 JWK 重算验证；SPKI DER 的 modulus/exponent 必须与 JWK 一致。
    func testImportKeyRecomputesKidAndCrosschecksDER() throws {
        let fixture = try makeRSAFixture()
        XCTAssertEqual(DesktopCloudRSA.jwkThumbprint(e: fixture.jwkE, n: fixture.jwkN), fixture.kid,
                       "RFC7638 kid 必须确定性可重算")
        let key = try DesktopCloudRSA.importKey(
            jwkE: fixture.jwkE, jwkN: fixture.jwkN, spkiDERBase64: fixture.spkiDER.base64EncodedString())
        XCTAssertTrue(SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionOAEPSHA256))
        // DER 与 JWK 不一致 → 拒绝
        let other = try makeRSAFixture()
        XCTAssertThrowsError(try DesktopCloudRSA.importKey(
            jwkE: fixture.jwkE, jwkN: other.jwkN, spkiDERBase64: fixture.spkiDER.base64EncodedString())
        ) { XCTAssertEqual($0 as? DesktopCloudError, .invalidResponse) }
        XCTAssertThrowsError(try DesktopCloudRSA.importKey(
            jwkE: fixture.jwkE, jwkN: fixture.jwkN, spkiDERBase64: "not-base64!")
        ) { XCTAssertEqual($0 as? DesktopCloudError, .invalidResponse) }
    }

    /// JWE 五段结构 + 私钥解 CEK + AES.GCM 以 protected ASCII 为 AAD 解开 payload ——
    /// 即后端 Nimbus 解包所依赖的全部加密语义。
    func testJWERoundtripWithPrivateKey() throws {
        let fixture = try makeRSAFixture()
        let publicKey = try DesktopCloudRSA.importKey(
            jwkE: fixture.jwkE, jwkN: fixture.jwkN, spkiDERBase64: fixture.spkiDER.base64EncodedString())
        let payload = Data(#"{"version":1,"requestId":"req-jwe","credentials":{"modelApiKey":{"action":"replace","value":"fake"}}}"#.utf8)
        let jwe = try DesktopCloudJWE.seal(payload: payload, publicKey: publicKey, kid: fixture.kid)
        let parts = jwe.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 5)

        let header = try XCTUnwrap(DesktopCloudBase64URL.decode(parts[0]))
        let headerObject = try XCTUnwrap(JSONSerialization.jsonObject(with: header) as? [String: String])
        XCTAssertEqual(headerObject["alg"], "RSA-OAEP-256")
        XCTAssertEqual(headerObject["enc"], "A256GCM")
        XCTAssertEqual(headerObject["typ"], "amber-config+jwe")
        XCTAssertEqual(headerObject["kid"], fixture.kid)

        let encryptedKey = try XCTUnwrap(DesktopCloudBase64URL.decode(parts[1]))
        var error: Unmanaged<CFError>?
        guard let cek = SecKeyCreateDecryptedData(
            fixture.privateKey, .rsaEncryptionOAEPSHA256, encryptedKey as CFData, &error) as Data?
        else { return XCTFail("私钥未能解包 CEK: \(String(describing: error?.takeRetainedValue()))") }
        let iv = try XCTUnwrap(DesktopCloudBase64URL.decode(parts[2]))
        XCTAssertEqual(iv.count, 12, "A256GCM IV 必须为 96 bit")
        let ciphertext = try XCTUnwrap(DesktopCloudBase64URL.decode(parts[3]))
        let tag = try XCTUnwrap(DesktopCloudBase64URL.decode(parts[4]))
        XCTAssertEqual(tag.count, 16, "GCM tag 必须为 128 bit")
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
        let opened = try AES.GCM.open(box, using: SymmetricKey(data: cek),
                                      authenticating: Data(parts[0].utf8))
        XCTAssertEqual(Data(opened), payload)
    }

    /// 篡改 AAD（protected 段）必须导致解封失败——JWE 完整性语义。
    func testJWERejectsTamperedProtectedHeader() throws {
        let fixture = try makeRSAFixture()
        let publicKey = try DesktopCloudRSA.importKey(
            jwkE: fixture.jwkE, jwkN: fixture.jwkN, spkiDERBase64: fixture.spkiDER.base64EncodedString())
        let jwe = try DesktopCloudJWE.seal(payload: Data("x".utf8), publicKey: publicKey, kid: fixture.kid)
        var parts = jwe.split(separator: ".").map(String.init)
        let encryptedKey = try XCTUnwrap(DesktopCloudBase64URL.decode(parts[1]))
        var error: Unmanaged<CFError>?
        let cek = try XCTUnwrap(SecKeyCreateDecryptedData(
            fixture.privateKey, .rsaEncryptionOAEPSHA256, encryptedKey as CFData, &error) as Data?)
        parts[0] = DesktopCloudBase64URL.encode(Data(#"{"alg":"RSA-OAEP-256","enc":"A256GCM","kid":"x","typ":"amber-config+jwe"}"#.utf8))
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: XCTUnwrap(DesktopCloudBase64URL.decode(parts[2]))),
            ciphertext: XCTUnwrap(DesktopCloudBase64URL.decode(parts[3])),
            tag: XCTUnwrap(DesktopCloudBase64URL.decode(parts[4])))
        XCTAssertThrowsError(try AES.GCM.open(box, using: SymmetricKey(data: cek),
            authenticating: Data(parts[0].utf8)), "被替换的 protected 段必须导致解封失败")
    }

    // MARK: payload 形状 / 省略 / 校验 / kid 固定

    private func makeContractSync(defaults: UserDefaults = UserDefaults(suiteName: "t.kid.\(UUID().uuidString)")!) -> DesktopCloudClientConfigSync {
        let connection = DesktopCloudConnection(gatewayId: "g1", name: "云端", addrs: ["127.0.0.1"],
            port: 47_821, fingerprint: "f", deviceId: "d1")
        let client = DesktopCloudClient(addrs: ["127.0.0.1"], port: 47_821, fingerprint: "f", token: "t")
        return DesktopCloudClientConfigSync(client: client, connection: connection,
            kidStore: DesktopCloudPinnedKidStore(defaults: defaults))
    }

    private func payloadObject(_ apply: DesktopCloudConfigApply, requestId: String = "req-9") async throws -> [String: Any] {
        let data = try await makeContractSync().buildPayload(apply, requestId: requestId,
            serverTime: 1_000, lifetime: 300)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testBuildPayloadContractShape() async throws {
        var draft = DesktopCloudConfigDraft(
            modelProvider: "openai", modelId: "deepseek-flash",
            modelBaseURL: "https://api.deepseek.com/v1",
            searchSources: ["bing", "exa"], searchMode: "aggregate", baseRevision: 7)
        draft.deletes = ["braveApiKey"]
        let apply = DesktopCloudConfigApply(config: draft, includesModel: true, includesSearch: true,
            secrets: ["modelApiKey": "fake-model-key", "exaApiKey": "fake-exa-key"])
        let object = try await payloadObject(apply)
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["gatewayId"] as? String, "g1")
        XCTAssertEqual(object["deviceId"] as? String, "d1")
        XCTAssertEqual(object["requestId"] as? String, "req-9")
        XCTAssertEqual(object["expectedRevision"] as? Int, 7)
        XCTAssertEqual(object["issuedAt"] as? Int, 1_000)
        XCTAssertEqual(object["expiresAt"] as? Int, 1_300)
        let configuration = try XCTUnwrap(object["configuration"] as? [String: Any])
        let model = try XCTUnwrap(configuration["model"] as? [String: Any])
        XCTAssertEqual(model["provider"] as? String, "openai")
        XCTAssertEqual(model["modelId"] as? String, "deepseek-flash")
        XCTAssertEqual(model["baseUrl"] as? String, "https://api.deepseek.com/v1")
        let search = try XCTUnwrap(configuration["search"] as? [String: Any])
        XCTAssertEqual(search["mode"] as? String, "aggregate")
        XCTAssertEqual(search["sources"] as? [String], ["bing", "exa"])
        let credentials = try XCTUnwrap(object["credentials"] as? [String: Any])
        XCTAssertEqual((credentials["modelApiKey"] as? [String: Any])?["action"] as? String, "replace")
        XCTAssertEqual((credentials["modelApiKey"] as? [String: Any])?["value"] as? String, "fake-model-key")
        let delete = try XCTUnwrap(credentials["braveApiKey"] as? [String: Any])
        XCTAssertEqual(delete["action"] as? String, "delete")
        XCTAssertNil(delete["value"], "delete 不得携带 value")
    }

    func testBuildPayloadOmitsUnselectedObjects() async throws {
        // 全省略：只带凭据动作或什么都不带，configuration/credentials 整体缺省。
        var object = try await payloadObject(DesktopCloudConfigApply(config: DesktopCloudConfigDraft()))
        XCTAssertNil(object["configuration"], "未选配置项时 configuration 必须缺省（=保持不变）")
        XCTAssertNil(object["credentials"])
        // 只上传 secrets 不带 model/search 时 credentials 单独存在。
        object = try await payloadObject(DesktopCloudConfigApply(
            config: DesktopCloudConfigDraft(), secrets: ["exaApiKey": "fake"]))
        XCTAssertNil(object["configuration"])
        XCTAssertNotNil(object["credentials"])
    }

    func testBuildPayloadReplaceWinsOverSameSlotDelete() async throws {
        var draft = DesktopCloudConfigDraft(); draft.deletes = ["modelApiKey"]
        let object = try await payloadObject(DesktopCloudConfigApply(
            config: draft, secrets: ["modelApiKey": "fake"]))
        let action = (object["credentials"] as? [String: Any])?["modelApiKey"] as? [String: Any]
        XCTAssertEqual(action?["action"] as? String, "replace", "同槽位同时上传与删除时以新 Key 为准")
    }

    func testBuildPayloadValidation() async throws {
        let sync = makeContractSync()
        // 缺模型标识
        await XCTAssertAsyncError(try await sync.buildPayload(DesktopCloudConfigApply(
            config: DesktopCloudConfigDraft(modelId: ""), includesModel: true), requestId: "r",
            serverTime: 1, lifetime: 300))
        // 非 HTTPS baseURL
        await XCTAssertAsyncError(try await sync.buildPayload(DesktopCloudConfigApply(
            config: DesktopCloudConfigDraft(modelProvider: "openai", modelId: "m",
                modelBaseURL: "http://insecure.example.com"), includesModel: true), requestId: "r",
            serverTime: 1, lifetime: 300))
        // 带 query 的 baseURL
        await XCTAssertAsyncError(try await sync.buildPayload(DesktopCloudConfigApply(
            config: DesktopCloudConfigDraft(modelProvider: "openai", modelId: "m",
                modelBaseURL: "https://api.example.com/v1?x=1"), includesModel: true), requestId: "r",
            serverTime: 1, lifetime: 300))
        // 契约外凭据键名
        await XCTAssertAsyncError(try await sync.buildPayload(DesktopCloudConfigApply(
            config: DesktopCloudConfigDraft(), secrets: ["api.github": "x"]), requestId: "r",
            serverTime: 1, lifetime: 300))
        await XCTAssertAsyncError(try await sync.buildPayload(DesktopCloudConfigApply(
            config: DesktopCloudConfigDraft(deletes: ["someOtherKey"])), requestId: "r",
            serverTime: 1, lifetime: 300))
    }

    func testImportKidPinning() async throws {
        let defaults = UserDefaults(suiteName: "t.kid.\(UUID().uuidString)")!
        let kidStore = DesktopCloudPinnedKidStore(defaults: defaults)
        let sync = makeContractSync(defaults: defaults)
        try await sync.checkPinnedKid("kid-1")
        try await sync.checkPinnedKid("kid-1")   // 同 kid 放行
        await XCTAssertAsyncError(try await sync.checkPinnedKid("kid-2"),
            matches: DesktopCloudError.importKeyChanged)
        kidStore.unpin(forGateway: "g1")
        try await sync.checkPinnedKid("kid-2")   // 解钉（重新配对）后允许重新固定
        XCTAssertEqual(kidStore.kid(forGateway: "g1"), "kid-2")
    }
}

private func XCTAssertAsyncError(_ expression: @autoclosure () async throws -> Any,
                                 matches expected: DesktopCloudError? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("应当抛出错误", file: file, line: line)
    } catch {
        if let expected { XCTAssertEqual(error as? DesktopCloudError, expected, file: file, line: line) }
    }
}
