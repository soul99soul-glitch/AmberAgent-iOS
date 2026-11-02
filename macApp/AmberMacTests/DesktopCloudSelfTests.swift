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
        /// 模拟「POST 已应用但回读失败」——receipt 确认后 GET 出错。
        var readbackFails = false
        var received: [(apply: DesktopCloudConfigApply, requestId: String)] = []

        func fetchConfig() async throws -> DesktopCloudRemoteConfig {
            if let fetchError { throw fetchError }
            return remote
        }
        func applyConfig(_ request: DesktopCloudConfigApply, requestId: String) async throws -> DesktopCloudApplyOutcome {
            received.append((request, requestId))
            if let applyError { throw applyError }
            return DesktopCloudApplyOutcome(config: readbackFails ? nil : remote,
                revision: remote.revision + 1, refreshed: !readbackFails)
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
        let error = await store.import(plan, catalog: catalog)
        XCTAssertNil(error)

        let (apply, requestId) = try XCTUnwrap(sync.received.last)
        XCTAssertFalse(requestId.isEmpty)
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
        let error = await store.import(plan, catalog: store.importCatalog())
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
            DesktopCloudImportPlan(providerID: oauth.id), catalog: store.importCatalog())
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
        let error = await store.applyRemoteConfig(draft)
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
        let error = await store.applyRemoteConfig(draft)
        XCTAssertNil(error)
        XCTAssertTrue(try XCTUnwrap(sync.received.last).apply.secrets.isEmpty,
                      "脱敏占位符不得作为 Key 上传")
    }

    // MARK: R3/R4 定点失败证据（独立审查 cloud-configuration-independent-review.md）

    /// R3：手动页同槽位「填新 Key + 勾选删除」必须被拒绝，不能静默以 replace 为准。
    @MainActor func testApplyRejectsSameSlotReplaceAndDelete() async throws {
        let sync = FakeSync()
        let (store, _, _) = makePairedStore(sync: sync)
        var draft = DesktopCloudConfigDraft(modelProvider: "openai", modelId: "gpt-5-mini",
            modelApiKey: "sk-new-fake", baseRevision: 3)
        draft.deletes = ["modelApiKey"]
        let error = await store.applyRemoteConfig(draft)
        XCTAssertNotNil(error, "同槽位替换+删除必须显式拒绝（当前静默 replace，UI 承诺删除未兑现）")
    }

    /// R3：导入页勾选 provider 又勾选删除同一云端 Key 时必须被拒绝。
    @MainActor func testImportRejectsSameSlotDeleteAndReplace() async throws {
        let sync = FakeSync()
        let credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(
            defaults: UserDefaults(suiteName: "t.r3.providers.\(UUID().uuidString)")!,
            credentials: credentials)
        let provider = DesktopProviderConfiguration(
            name: "OpenAI", kind: .openAI, baseURL: "https://api.openai.com/v1", modelID: "gpt-5-mini")
        try settings.saveProvider(provider, apiKey: "sk-r3-fake")
        let (store, _, _) = makePairedStore(sync: sync, settings: (settings, credentials))
        await store.refreshRemoteConfig()
        let plan = DesktopCloudImportPlan(providerID: provider.id, deletes: ["modelApiKey"])
        let error = await store.import(plan, catalog: store.importCatalog())
        XCTAssertNotNil(error, "同槽位导入+删除必须显式拒绝")
    }

    /// R4：Gemini（云端不支持协议）即使有 Key 也不得进入模型导入，整批应被阻止而非 422。
    @MainActor func testImportRejectsCloudUnsupportedProvider() async throws {
        let sync = FakeSync()
        let credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(
            defaults: UserDefaults(suiteName: "t.r4.providers.\(UUID().uuidString)")!,
            credentials: credentials)
        let gemini = DesktopProviderConfiguration(
            name: "Gemini", kind: .gemini, baseURL: "https://generativelanguage.googleapis.com",
            modelID: "gemini-3-flash")
        try settings.saveProvider(gemini, apiKey: "gem-key-fake")
        settings.selectedProviderID = gemini.id
        let (store, _, _) = makePairedStore(sync: sync, settings: (settings, credentials))
        await store.refreshRemoteConfig()
        let plan = DesktopCloudImportPlan(providerID: gemini.id)
        let error = await store.import(plan, catalog: store.importCatalog())
        XCTAssertNotNil(error, "云端不支持的 provider 必须在客户端拦截（当前会带上 gemini 致整批 422）")
        XCTAssertTrue(sync.received.isEmpty)
    }

    /// 契约 credential_action_required：已存模型 Key 时改 provider/baseURL 必须带真 Key 或删除。
    @MainActor func testCredentialActionRequiredGuard() async throws {
        let sync = FakeSync() // remote: provider=openai, baseURL=api.openai.com, keyConfigured=true
        let (store, _, _) = makePairedStore(sync: sync)
        await store.refreshRemoteConfig()
        // 换 provider 不带 Key 不删除 → 客户端提前拒绝，不发出请求。
        let blocked = await store.applyRemoteConfig(
            DesktopCloudConfigDraft(modelProvider: "claude", modelId: "claude-sonnet-4",
                modelBaseURL: "https://api.openai.com/v1", baseRevision: 3))
        guard case .server(let message) = blocked else { return XCTFail("应被客户端拦截") }
        XCTAssertTrue(message.contains("模型 Key"))
        XCTAssertTrue(sync.received.isEmpty, "拦截在客户端，不得发出请求")
        // 只改 modelId → 允许（Key 保留）。
        let ok = await store.applyRemoteConfig(
            DesktopCloudConfigDraft(modelProvider: "openai", modelId: "gpt-5-mini",
                modelBaseURL: "https://api.openai.com/v1", baseRevision: 3))
        XCTAssertNil(ok)
        // 换 provider + 显式删除旧 Key → 允许。
        var deleting = DesktopCloudConfigDraft(modelProvider: "claude", modelId: "claude-sonnet-4",
            modelBaseURL: "https://api.openai.com/v1", baseRevision: 3)
        deleting.deletes = ["modelApiKey"]
        let deleted = await store.applyRemoteConfig(deleting)
        XCTAssertNil(deleted)
        // 换 baseURL + 新 Key → 允许。
        let replaced = await store.applyRemoteConfig(
            DesktopCloudConfigDraft(modelProvider: "openai", modelId: "m",
                modelBaseURL: "https://api.deepseek.com/v1", modelApiKey: "sk-new",
                baseRevision: 3))
        XCTAssertNil(replaced)
        XCTAssertEqual(sync.received.count, 3)
    }

    /// R5：传输失败（结果未知）时重试同一内容必须复用同一 requestId。
    @MainActor func testApplyRemoteConfigRetryKeepsSameRequestId() async throws {
        let sync = FakeSync()
        sync.applyError = DesktopCloudError.unreachable
        let (store, _, _) = makePairedStore(sync: sync)
        let draft = DesktopCloudConfigDraft(modelProvider: "openai", modelId: "gpt-5-mini",
            modelApiKey: "sk-retry", baseRevision: 3)
        _ = await store.applyRemoteConfig(draft)
        _ = await store.applyRemoteConfig(draft)
        let ids = sync.received.map(\.requestId)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], ids[1], "结果未知时重试必须复用同一 requestId")
    }

    /// R5：receipt 确认成功即结束该操作——随后的独立保存必须换新的 requestId，
    /// 哪怕内容相同；POST 成功而回读失败时也算完成并单独标记回读失败。
    @MainActor func testConfirmedReceiptEndsOperationAndRefreshesIndependently() async throws {
        let sync = FakeSync()
        let (store, _, _) = makePairedStore(sync: sync)
        await store.refreshRemoteConfig()
        let draft = DesktopCloudConfigDraft(modelProvider: "openai", modelId: "gpt-5-mini",
            modelBaseURL: "https://api.openai.com/v1", modelApiKey: "sk-fake-1", baseRevision: 3)
        let first = await store.applyRemoteConfig(draft)
        XCTAssertNil(first)
        // 同一内容再保存 = 新操作，必须是新 requestId，而不是复用旧 ID 靠 replayed 兜底。
        let second = await store.applyRemoteConfig(draft)
        XCTAssertNil(second)
        let ids = sync.received.map(\.requestId)
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1], "已确认的操作结束后，新操作不得继承旧 requestId")

        // receipt 确认、回读失败：仍算成功，且把「已提交/回读失败」单独呈现。
        sync.readbackFails = true
        var deletes = DesktopCloudConfigDraft(modelProvider: "openai", modelId: "gpt-5-mini",
            modelBaseURL: "https://api.openai.com/v1", baseRevision: 4)
        deletes.deletes = ["modelApiKey"]
        let readbackError = await store.applyRemoteConfig(deletes)
        XCTAssertNil(readbackError)
        XCTAssertNil(store.remoteConfig, "回读失败后不能用新 revision 授权旧配置快照")
        XCTAssertNil(store.lastConfiguredSecrets, "未回读确认时不预测凭据状态")
        XCTAssertNotNil(store.remoteConfigError, "回读失败必须单独呈现而非当提交失败")
    }

    /// R6：409 后不能只换 revision 重发旧完整对象——未编辑字段采纳远端新值，已编辑字段保留。
    @MainActor func testConflictMergePreservesEditsAndAdoptsUntouched() async throws {
        let base = DesktopCloudRemoteConfig(
            model: .init(provider: "openai", modelId: "gpt-old", baseURL: "https://api.openai.com/v1",
                         keyConfigured: true),
            search: .init(sources: ["bing"], mode: "fallback",
                          exaKeyConfigured: false, braveKeyConfigured: false),
            revision: 3)
        var draft = DesktopCloudConfigDraft(
            modelProvider: base.model.provider, modelId: base.model.modelId,
            modelBaseURL: base.model.baseURL, searchSources: base.search.sources,
            searchMode: base.search.mode, baseRevision: base.revision)
        // 用户只编辑了 modelId；远端同时改了 provider/baseURL/searchSources。
        draft.modelId = "gpt-5-mini"
        let fresh = DesktopCloudRemoteConfig(
            model: .init(provider: "claude", modelId: "claude-sonnet-4",
                         baseURL: "https://api.anthropic.com/v1", keyConfigured: true),
            search: .init(sources: ["brave"], mode: "aggregate",
                          exaKeyConfigured: false, braveKeyConfigured: true),
            revision: 4)
        let (merged, adopted) = draft.mergedPreservingEdits(base: base, into: fresh)
        XCTAssertEqual(merged.modelId, "gpt-5-mini", "已编辑字段保留本地值")
        XCTAssertEqual(merged.modelProvider, "claude", "未编辑字段采纳远端新值")
        XCTAssertEqual(merged.modelBaseURL, "https://api.anthropic.com/v1")
        XCTAssertEqual(merged.searchSources, ["brave"])
        XCTAssertEqual(merged.searchMode, "aggregate")
        XCTAssertEqual(merged.baseRevision, 4)
        XCTAssertEqual(Set(adopted), ["服务商", "接口地址", "搜索来源", "执行方式"])
    }

    func testConflictMergeKeepsTypedModelKeyBoundToItsDestination() {
        let base = DesktopCloudRemoteConfig(
            model: .init(provider: "openai", modelId: "original-model",
                         baseURL: "https://original.example/v1", keyConfigured: true), revision: 1)
        let draft = DesktopCloudConfigDraft(modelProvider: base.model.provider,
            modelId: base.model.modelId, modelBaseURL: base.model.baseURL,
            modelApiKey: "fake-key-for-original", baseRevision: 1)
        let fresh = DesktopCloudRemoteConfig(
            model: .init(provider: "claude", modelId: "other-model",
                         baseURL: "https://other.example/v1", keyConfigured: true), revision: 2)
        let result = draft.mergedPreservingEdits(base: base, into: fresh)
        XCTAssertEqual(result.draft.modelProvider, draft.modelProvider)
        XCTAssertEqual(result.draft.modelBaseURL, draft.modelBaseURL)
        XCTAssertEqual(result.draft.modelId, draft.modelId)
        XCTAssertEqual(result.draft.modelApiKey, draft.modelApiKey)
        XCTAssertEqual(result.draft.baseRevision, 2)
    }

    @MainActor func testUnknownImportResultKeepsRequestIdAfterRevisionRefresh() async throws {
        let sync = FakeSync()
        sync.applyError = DesktopCloudError.unreachable
        let (store, _, _) = makePairedStore(sync: sync)
        await store.refreshRemoteConfig()
        let plan = DesktopCloudImportPlan(searchServices: [.free])
        _ = await store.import(plan, catalog: store.importCatalog())
        sync.remote.revision += 1
        await store.refreshRemoteConfig()
        _ = await store.import(plan, catalog: store.importCatalog())
        XCTAssertEqual(sync.received.count, 2)
        XCTAssertEqual(sync.received[0].requestId, sync.received[1].requestId,
                       "相同语义操作的未知结果重试不能因回读版本变化而换 ID")
    }

    // MARK: failure semantics — 401吊销 / 冲突与失败保留配对

    @MainActor func testUnauthorizedForgetsPairing() async throws {
        let sync = FakeSync()
        sync.applyError = DesktopCloudError.unauthorized
        let (store, tokens, defaults) = makePairedStore(sync: sync)
        _ = await store.applyRemoteConfig(DesktopCloudConfigDraft())
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
                modelBaseURL: "https://api.openai.com/v1", baseRevision: 3))
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
