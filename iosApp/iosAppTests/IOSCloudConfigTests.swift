import XCTest
@preconcurrency import Shared
@testable import iosApp

/// Cloud configuration import model tests. Uses isolated UserDefaults suites and
/// in-memory credential closures — fake keys only, never the real Keychain.
@MainActor
final class IOSCloudConfigTests: XCTestCase {

    // ---- Draft defaults ----

    func testDraftDefaultsToActiveProviderAndSelectedSearchOnly() throws {
        let store = makeStore()
        let first = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "ProviderA", apiKey: "sk-a", baseUrl: "https://a.example/v1",
            modelName: "ModelA", modelId: "model-a"
        ))
        let second = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "ProviderB", apiKey: "sk-b", baseUrl: "https://b.example/v1",
            modelName: "ModelB", modelId: "model-b"
        ))
        let modelB = try XCTUnwrap(second.models.first)
        store.setCurrentChatModelId(modelB.id.description())
        store.addSearchProvider(name: "Brave", apiKey: "brave-key", serviceType: "brave")
        store.addSearchProvider(name: "Exa", apiKey: "exa-key", serviceType: "exa")

        let draft = IOSCloudImportDraft.make(from: store)

        XCTAssertEqual(draft.providerId, second.id.description(),
                       "默认选中当前聊天服务商，而不是第一个或全部")
        XCTAssertEqual(draft.modelUuid, modelB.id.description())
        XCTAssertEqual(draft.selectedSearchIds.count, 1,
                       "默认只选当前使用的搜索服务，不全选")
        let exaId = try XCTUnwrap(draft.searches.first { $0.typeLabel == "exa" }?.serviceId)
        XCTAssertEqual(draft.selectedSearchIds, [exaId])
        XCTAssertNotEqual(draft.providerId, first.id.description())
    }

    func testDraftListsAllProvidersButSelectsOnlyOne() throws {
        let store = makeStore()
        _ = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "ProviderA", apiKey: "sk-a", baseUrl: "https://a.example/v1",
            modelName: "ModelA", modelId: "model-a"
        ))
        let second = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "ProviderB", apiKey: "sk-b", baseUrl: "https://b.example/v1",
            modelName: "ModelB", modelId: "model-b"
        ))
        let modelB = try XCTUnwrap(second.models.first)
        store.setCurrentChatModelId(modelB.id.description())

        let draft = IOSCloudImportDraft.make(from: store)

        XCTAssertGreaterThanOrEqual(draft.providers.count, 2,
                                    "所有本机服务商都应列出供挑选")
        XCTAssertEqual(draft.selectedProvider?.providerId, second.id.description(),
                       "只有当前服务商进入默认选中")
        XCTAssertTrue(draft.hasSelection)
    }

    func testProviderWithoutKeyIsListedButBlocked() {
        let store = makeStore()
        _ = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "NoKey", apiKey: "", baseUrl: "https://c.example/v1",
            modelName: "ModelC", modelId: "model-c"
        ))

        let draft = IOSCloudImportDraft.make(from: store)
        let item = draft.providers.first { $0.name == "NoKey" }

        XCTAssertNotNil(item, "无 Key 的服务商仍列出")
        XCTAssertEqual(item?.hasApiKey, false)
        XCTAssertEqual(item?.isExportable, false)
        XCTAssertNotNil(item?.blockedReason)
    }

    func testCodexOAuthProviderIsBlockedFromExport() throws {
        let store = makeStore()
        let provider = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "CodexAcct", apiKey: "sk-codex", baseUrl: "https://chatgpt.com/backend-api/codex",
            modelName: "Codex", modelId: "gpt-5-codex"
        ))
        _ = store.setOpenAIAuthMode(providerId: provider.id.description(), authMode: OpenAIAuthMode.codexOauth)

        let draft = IOSCloudImportDraft.make(from: store)
        let item = try XCTUnwrap(draft.providers.first { $0.providerId == provider.id.description() })

        XCTAssertEqual(item.managedAuthLabel, "Codex OAuth")
        XCTAssertFalse(item.isExportable, "OAuth 登录态不能导出到云端")
        XCTAssertTrue(item.blockedReason?.contains("Codex") == true)
        XCTAssertNotEqual(draft.providerId, item.providerId,
                          "被拦截的服务商不能进入默认选中")
    }

    func testDisabledProviderIsBlocked() throws {
        let store = makeStore()
        let provider = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "Disabled", apiKey: "sk-d", baseUrl: "https://d.example/v1",
            modelName: "ModelD", modelId: "model-d"
        ))
        _ = store.updateProviderBasics(providerId: provider.id.description(), name: "Disabled", enabled: false)

        let draft = IOSCloudImportDraft.make(from: store)
        let item = try XCTUnwrap(draft.providers.first { $0.providerId == provider.id.description() })

        XCTAssertFalse(item.enabled)
        XCTAssertFalse(item.isExportable)
    }

    func testGoogleProviderIsBlockedAsUnsupportedProtocol() throws {
        let store = makeStore()
        _ = store.addProvider(IosSettingsMutations.shared.buildGoogleProvider(
            name: "Gemini", apiKey: "gemini-key", baseUrl: "https://generativelanguage.googleapis.com/v1beta",
            modelName: "Gemini", modelId: "gemini-2.5-pro"
        ))

        let draft = IOSCloudImportDraft.make(from: store)
        let item = try XCTUnwrap(draft.providers.first { $0.name == "Gemini" })

        XCTAssertEqual(item.kind, .google)
        XCTAssertFalse(item.kind.isCloudSupported)
        XCTAssertFalse(item.isExportable, "契约只接受 openai/claude 协议")
        XCTAssertNotEqual(draft.providerId, item.providerId,
                          "不支持协议的服务商不能进入默认选中")
    }

    // ---- Search items ----

    func testSearchItemWithoutKeyIsBlockedButFreeTypeNeedsNone() throws {
        let store = makeStore()
        store.addSearchProvider(name: "EmptyExa", apiKey: "", serviceType: "exa")

        let draft = IOSCloudImportDraft.make(from: store)
        let exa = try XCTUnwrap(draft.searches.first { $0.typeLabel == "exa" })

        XCTAssertTrue(exa.requiresKey)
        XCTAssertFalse(exa.hasApiKey)
        XCTAssertFalse(exa.isExportable)
        XCTAssertTrue(exa.blockedReason?.contains("API Key") == true)

        let free = IOSCloudSearchExportItem(
            serviceId: "free-1", name: "免费聚合搜索", typeLabel: "bing_local",
            requiresKey: false, hasApiKey: false, enabled: true, isSelected: false
        )
        XCTAssertTrue(free.isExportable, "免费聚合源不需要 Key 即可导出")
        XCTAssertEqual(free.cloudSources, ["bing", "duckduckgo"], "bing_local 必须映射为有序 bing、duckduckgo")
    }

    func testUnsupportedSearchTypeIsListedButBlocked() throws {
        let store = makeStore()
        store.addSearchProvider(name: "Tavily", apiKey: "tvly-key", serviceType: "tavily")

        let draft = IOSCloudImportDraft.make(from: store)
        let tavily = try XCTUnwrap(draft.searches.first { $0.typeLabel == "tavily" })

        XCTAssertFalse(tavily.isCloudSupported, "契约搜索源白名单不含 tavily")
        XCTAssertFalse(tavily.isExportable)
        XCTAssertTrue(tavily.cloudSources.isEmpty)
        XCTAssertFalse(draft.selectedSearchIds.contains(tavily.serviceId),
                       "云端不支持的服务不进入默认选中")
    }

    // ---- Bundle → contract patch ----

    func testBundleCarriesSelectedSecretsOnlyAtConfirm() throws {
        let store = makeStore()
        let provider = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "ProviderB", apiKey: "sk-b", baseUrl: "https://b.example/v1",
            modelName: "ModelB", modelId: "model-b"
        ))
        let model = try XCTUnwrap(provider.models.first)
        store.setCurrentChatModelId(model.id.description())
        store.addSearchProvider(name: "Exa", apiKey: "exa-key", serviceType: "exa")

        let draft = IOSCloudImportDraft.make(from: store)
        let bundle = draft.bundle(using: store)

        XCTAssertEqual(bundle.model?.providerKind, "openai")
        XCTAssertEqual(bundle.model?.modelId, "model-b")
        XCTAssertEqual(bundle.model?.credential, .replace("sk-b"))
        XCTAssertEqual(bundle.search.count, 1)
        XCTAssertEqual(bundle.search.first?.type, "exa")
        XCTAssertEqual(bundle.search.first?.credential, .replace("exa-key"))
        XCTAssertFalse(bundle.isEmpty)

        let patch = bundle.configurationPatch
        XCTAssertEqual(patch?.model?.provider, "openai")
        XCTAssertEqual(patch?.model?.modelId, "model-b")
        XCTAssertEqual(patch?.search?.sources, ["exa", "duckduckgo", "bing"],
                       "选中源在前，已开启的免费源按序追加并去重")
        XCTAssertEqual(patch?.search?.mode, "fallback")
        let credentials = try XCTUnwrap(bundle.credentialPatch)
        XCTAssertEqual(credentials.modelApiKey?.action, "replace")
        XCTAssertEqual(credentials.modelApiKey?.value, "sk-b")
        XCTAssertEqual(credentials.exaApiKey?.value, "exa-key")
        XCTAssertNil(credentials.braveApiKey, "未选的源不出现凭据项")
    }

    func testBundleBingLocalExpandsToOrderedFreeSources() {
        let store = makeStore()
        var draft = IOSCloudImportDraft(
            providers: [],
            searches: [IOSCloudSearchExportItem(
                serviceId: "free-agg", name: "免费聚合", typeLabel: "bing_local",
                requiresKey: false, hasApiKey: false, enabled: true, isSelected: false
            )],
            providerId: nil,
            modelUuid: nil,
            selectedSearchIds: ["free-agg"],
            enableWebSearch: true,
            freeSources: ["duckduckgo", "jina", "wikipedia"]
        )
        let bundle = draft.bundle(using: store)

        XCTAssertEqual(bundle.cloudSearchSources, ["bing", "duckduckgo"],
                       "bing_local 展开为 bing、duckduckgo；内置 duckduckgo 去重；jina/wikipedia 不在契约白名单")
        XCTAssertNil(bundle.credentialPatch, "免费源没有凭据项")
        draft.selectedSearchIds = []
        draft = IOSCloudImportDraft(
            providers: [], searches: draft.searches, providerId: nil, modelUuid: nil,
            selectedSearchIds: [], enableWebSearch: true, freeSources: []
        )
        XCTAssertTrue(draft.bundle(using: store).isEmpty)
    }

    func testBundleEmptyKeyBecomesNilKeepSemantics() {
        let store = makeStore()
        var draft = IOSCloudImportDraft(
            providers: [],
            searches: [IOSCloudSearchExportItem(
                serviceId: "missing-service", name: "Exa", typeLabel: "exa",
                requiresKey: true, hasApiKey: true, enabled: true, isSelected: false
            )],
            providerId: nil,
            modelUuid: nil,
            selectedSearchIds: ["missing-service"],
            enableWebSearch: true,
            freeSources: []
        )
        let bundle = draft.bundle(using: store)

        XCTAssertEqual(bundle.search.first?.credential, .keep,
                       "快照里取不到 Key 时必须 keep（保留云端原值），而不是 replace 空串")
        XCTAssertNil(bundle.credentialPatch, "keep 不产生凭据项")
        XCTAssertFalse(bundle.isEmpty)

        draft.selectedSearchIds = []
        draft = IOSCloudImportDraft(
            providers: [], searches: draft.searches, providerId: nil, modelUuid: nil,
            selectedSearchIds: [], enableWebSearch: true, freeSources: []
        )
        XCTAssertTrue(draft.bundle(using: store).isEmpty)
    }

    func testCredentialActionsEncodeReplaceDeleteAndKeep() {
        var bundle = IOSCloudConfigBundle(
            model: IOSCloudConfigBundle.ModelSection(
                providerKind: "openai", modelId: "m", baseUrl: "", credential: .keep
            ),
            search: [
                IOSCloudConfigBundle.SearchEntry(
                    type: "exa", name: "Exa", enabled: true,
                    credential: .replace(" fake-key-spaces "), includeInConfiguration: true
                ),
                IOSCloudConfigBundle.SearchEntry(
                    type: "brave", name: "Brave", enabled: true,
                    credential: .keep, includeInConfiguration: false
                ),
            ],
            freeSources: [],
            extraCredentials: ["braveApiKey": .delete]
        )

        let credentials = bundle.credentialPatch
        XCTAssertNil(credentials?.modelApiKey, "keep 不出现")
        XCTAssertEqual(credentials?.exaApiKey?.action, "replace")
        XCTAssertEqual(credentials?.exaApiKey?.value, "fake-key-spaces", "value 应 trim 后发送")
        XCTAssertEqual(credentials?.braveApiKey?.action, "delete")
        XCTAssertNil(credentials?.braveApiKey?.value, "delete 不携带 value")
        XCTAssertEqual(bundle.cloudSearchSources, ["exa"],
                       "includeInConfiguration=false 的 key-only 项不改搜索源列表")

        bundle.extraCredentials = [:]
        XCTAssertNil(bundle.credentialPatch?.braveApiKey, "撤销 standalone 动作后回到 keep")
    }

    func testOperationKeyTracksWireSemantics() {
        let base = IOSCloudConfigBundle(
            model: IOSCloudConfigBundle.ModelSection(
                providerKind: "openai", modelId: "m", baseUrl: "", credential: .replace("k")
            ),
            search: [], freeSources: []
        )
        var changed = base
        changed.search = [IOSCloudConfigBundle.SearchEntry(
            type: "exa", name: "Exa", enabled: true, credential: .keep, includeInConfiguration: true
        )]
        XCTAssertEqual(base.operationKey, base.operationKey, "同一语义必须得到同一 requestId 锚点")
        XCTAssertNotEqual(base.operationKey, changed.operationKey,
                          "语义变化必须换新 requestId（同 id 不同操作会被服务端 409）")
    }

    // ---- Rebuild ----

    func testRebuiltDraftPreservesSelectionsAndDropsGone() {
        let store = makeStore()
        _ = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "ProviderA", apiKey: "sk-a", baseUrl: "https://a.example/v1",
            modelName: "ModelA", modelId: "model-a"
        ))
        var draft = IOSCloudImportDraft.make(from: store)
        draft.selectedSearchIds = ["bogus-service"]

        let rebuilt = draft.rebuilt(from: store)

        XCTAssertEqual(rebuilt.providerId, draft.providerId)
        XCTAssertTrue(rebuilt.selectedSearchIds.isEmpty,
                      "快照中不存在的服务 id 必须在重建时剔除")
    }

    // ---- Preview ----

    func testPreviewEntriesMarkReplaceStateAndNeverLeakSecrets() throws {
        let store = makeStore()
        let provider = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "ProviderB", apiKey: "sk-super-secret", baseUrl: "https://b.example/v1",
            modelName: "ModelB", modelId: "model-b"
        ))
        let model = try XCTUnwrap(provider.models.first)
        store.setCurrentChatModelId(model.id.description())
        store.addSearchProvider(name: "Exa", apiKey: "exa-secret", serviceType: "exa")

        let remote = makeRemote(
            revision: 1,
            provider: "openai", modelId: "old-model", baseUrl: "https://old.example",
            modelKeyConfigured: true,
            sources: ["bing", "exa"], mode: "aggregate",
            exaKeyConfigured: true
        )

        let draft = IOSCloudImportDraft.make(from: store)
        let entries = draft.previewEntries(remote: remote)

        let modelEntry = try XCTUnwrap(entries.first { $0.section == .model })
        XCTAssertEqual(modelEntry.title, "ProviderB")
        XCTAssertTrue(modelEntry.detail.contains("model-b"))
        XCTAssertTrue(modelEntry.replacesRemote)
        XCTAssertTrue(modelEntry.includesSecret)
        XCTAssertNil(modelEntry.warning, "本机 Key 随行时无需警告")

        let exaEntry = try XCTUnwrap(entries.first { $0.sourceId == draft.selectedSearches.first?.serviceId })
        XCTAssertTrue(exaEntry.replacesRemote, "云端已启用并配置同类型源 → 标记为替换")

        for entry in entries {
            XCTAssertFalse(entry.title.contains("sk-"), "预览不得包含密钥材料")
            XCTAssertFalse(entry.detail.contains("sk-"), "预览不得包含密钥材料")
            XCTAssertFalse(entry.detail.contains("exa-secret"))
        }

        let emptyRemote = makeRemote(revision: 0, provider: "", modelId: "", baseUrl: "",
                                     modelKeyConfigured: false, sources: [], mode: "fallback")
        let fresh = draft.previewEntries(remote: emptyRemote)
        XCTAssertTrue(fresh.allSatisfy { !$0.replacesRemote })
    }

    func testPreviewWarnsWhenDestinationChangesWithoutNewKey() {
        let store = makeStore()
        var draft = IOSCloudImportDraft(
            providers: [IOSCloudProviderExportItem(
                providerId: "local-no-key", name: "NoKeyProvider", kind: .claude,
                baseUrl: "https://api.anthropic.com/v1",
                chatModels: [.init(uuid: "m1", modelId: "claude-4", displayName: "Claude")],
                defaultModelUuid: "m1", hasApiKey: false, managedAuthLabel: nil, enabled: true
            )],
            searches: [], providerId: nil, modelUuid: nil,
            selectedSearchIds: [], enableWebSearch: true, freeSources: []
        )
        // 手工绕过 isExportable 限制场景不必走完整 bundle；预览只关心选中项。
        draft.providerId = "local-no-key"
        draft.modelUuid = "m1"

        let remote = makeRemote(
            revision: 3, provider: "openai", modelId: "gpt", baseUrl: "https://api.openai.com/v1",
            modelKeyConfigured: true, sources: [], mode: "fallback"
        )
        let warning = draft.previewEntries(remote: remote).first?.warning
        XCTAssertNotNil(warning, "云端有 Key 且服务商/地址改变而本机无 Key → 必须提示 credential_action_required")
    }

    func testFreeSourcesReflectBuiltinToggles() {
        let store = makeStore()
        let draft = IOSCloudImportDraft.make(from: store)

        let snapshot = store.snapshot
        var expected: [String] = []
        if snapshot.searchBuiltinDuckDuckGoEnabled { expected.append("duckduckgo") }
        if snapshot.searchBuiltinBingEnabled { expected.append("bing") }
        if snapshot.searchBuiltinJinaEnabled { expected.append("jina") }
        if snapshot.searchBuiltinWikipediaEnabled { expected.append("wikipedia") }
        if snapshot.searchBuiltinHackerNewsEnabled { expected.append("hackernews") }
        XCTAssertEqual(draft.freeSources, expected)
        XCTAssertEqual(draft.enableWebSearch, snapshot.enableWebSearch)
    }

    // ---- helpers ----

    private func makeStore() -> IOSSharedSettingsStore {
        var creds: [String: String] = [:]
        let suite = "CloudConfig-\(UUID().uuidString)"
        return IOSSharedSettingsStore(
            userDefaults: UserDefaults(suiteName: suite)!,
            loadCredential: { creds[$0] },
            storeCredential: { key, value in creds[key] = value; return true },
            deleteCredential: { creds.removeValue(forKey: $0); return true }
        )
    }

    private func makeRemote(
        revision: Int, provider: String, modelId: String, baseUrl: String,
        modelKeyConfigured: Bool, sources: [String], mode: String,
        exaKeyConfigured: Bool = false, braveKeyConfigured: Bool = false
    ) -> IOSCloudConfigSnapshot {
        let supported = ["bing", "duckduckgo", "exa", "brave"]
        return IOSCloudConfigSnapshot(
            gatewayId: "gw",
            revision: revision,
            model: provider.isEmpty && modelId.isEmpty ? nil : .init(
                provider: provider, modelId: modelId, baseUrl: baseUrl, keyConfigured: modelKeyConfigured
            ),
            search: supported.map { source in
                IOSCloudConfigSnapshot.Search(
                    type: source,
                    name: IOSCloudConfigWire.sourceDisplayName(for: source),
                    enabled: sources.contains(source),
                    requiresKey: IOSCloudConfigWire.requiresKey(for: source),
                    keyConfigured: source == "exa" ? exaKeyConfigured : source == "brave" ? braveKeyConfigured : false
                )
            },
            searchSources: sources,
            searchMode: mode,
            supportedModelProviders: ["openai", "claude"],
            supportedSearchSources: supported
        )
    }
}
