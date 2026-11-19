import XCTest
@preconcurrency import Shared
@testable import iosApp

/// Cloud configuration import model tests. Uses isolated UserDefaults suites and
/// in-memory credential closures — fake keys only, never the real Keychain.
@MainActor
final class IOSCloudConfigTests: XCTestCase {

    func testReviewedVersionRequiresNewAcknowledgmentAfterRefreshOrPairingChange() {
        let reviewed = makeRemote(revision: 1, provider: "openai", modelId: "m",
            baseUrl: "https://fake.example/v1", modelKeyConfigured: true,
            sources: ["bing"], mode: "fallback")
        var refreshed = reviewed
        refreshed.revision += 1
        XCTAssertFalse(reviewed.hasSameVersion(as: refreshed))
        XCTAssertEqual(reviewed.revision, refreshed.revision - 1,
                       "刷新全局快照不得改变编辑弹窗持有的版本")
        var anotherGateway = reviewed
        anotherGateway.gatewayId = "another-gateway"
        XCTAssertFalse(reviewed.hasSameVersion(as: anotherGateway))
        XCTAssertFalse(reviewed.hasSameVersion(as: nil))
        XCTAssertTrue(reviewed.hasSameVersion(as: reviewed))
    }

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

    // ---- R7: model deselection → search-only import ----

    func testDeselectingProviderImportsOnlySelectedSearchKeys() throws {
        let store = makeStore()
        let provider = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "ProviderB", apiKey: "sk-b", baseUrl: "https://b.example/v1",
            modelName: "ModelB", modelId: "model-b"
        ))
        let model = try XCTUnwrap(provider.models.first)
        store.setCurrentChatModelId(model.id.description())
        store.addSearchProvider(name: "Exa", apiKey: "exa-key", serviceType: "exa")

        var draft = IOSCloudImportDraft.make(from: store)
        XCTAssertNotNil(draft.providerId, "默认选中当前服务商")
        // 用户点掉模型选择、只勾 Exa —— 只导入所选搜索 Key，不顺带模型与模型 Key。
        draft.providerId = nil
        draft.modelUuid = nil
        let exaItem = try XCTUnwrap(draft.searches.first { $0.typeLabel == "exa" })
        draft.selectedSearchIds = [exaItem.serviceId]
        let bundle = draft.bundle(using: store)

        XCTAssertNil(bundle.model, "取消选择后不得发送模型配置")
        XCTAssertFalse(bundle.isEmpty, "仅搜索选择仍是有效导入")
        XCTAssertNil(bundle.credentialPatch?.modelApiKey, "不得顺带模型 Key")
        XCTAssertEqual(bundle.credentialPatch?.exaApiKey?.value, "exa-key")
        XCTAssertEqual(bundle.configurationPatch?.search?.sources.first, "exa")

        let rebuilt = draft.rebuilt(from: store)
        XCTAssertNil(rebuilt.providerId, "重建不得复活被显式取消的模型选择")
        XCTAssertNil(rebuilt.modelUuid)
        XCTAssertEqual(rebuilt.selectedSearchIds, draft.selectedSearchIds,
                       "搜索选择保留")
    }

    // ---- R2: requestId lifecycle ----

    func testPendingOperationReusesIdUntilReceiptThenFreshId() {
        var pending = IOSCloudPendingOperation()

        let first = pending.requestId(forOperationKey: "op-a")
        XCTAssertEqual(pending.requestId(forOperationKey: "op-a"), first,
                       "结果未知的同一操作重试必须沿用同一 requestId")
        XCTAssertNotEqual(pending.requestId(forOperationKey: "op-b"), first,
                          "内容变化是独立操作，必须换新 id")

        pending.finish()
        XCTAssertNil(pending.requestId)
        XCTAssertNil(pending.operationKey)
        XCTAssertNotEqual(pending.requestId(forOperationKey: "op-b"), first,
                          "成功 receipt 后同内容的新提交也是新操作新 id")
    }

    func testModelOnlyDraftAndBlockedSummariesSeparatePrimaryModelFromSearchAndGroupReasons() throws {
        let store = makeStore()
        let activeProvider = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "ActiveOpenAI", apiKey: "sk-active", baseUrl: "https://active.example/v1",
            modelName: "GPT-5", modelId: "gpt-5"
        ))
        let activeModel = try XCTUnwrap(activeProvider.models.first)
        store.setCurrentChatModelId(activeModel.id.description())

        _ = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "NoKeyProvider", apiKey: "", baseUrl: "https://nokey.example/v1",
            modelName: "ModelNoKey", modelId: "model-nokey"
        ))
        let codexProvider = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "CodexAccount", apiKey: "sk-codex", baseUrl: "https://chatgpt.com/backend-api/codex",
            modelName: "Codex", modelId: "gpt-5-codex"
        ))
        _ = store.setOpenAIAuthMode(providerId: codexProvider.id.description(), authMode: OpenAIAuthMode.codexOauth)
        _ = store.addProvider(IosSettingsMutations.shared.buildGoogleProvider(
            name: "GeminiLocal", apiKey: "gemini-secret-key", baseUrl: "https://generativelanguage.googleapis.com/v1beta",
            modelName: "Gemini", modelId: "gemini-2.5-pro"
        ))
        store.addSearchProvider(name: "ExaConfigured", apiKey: "exa-secret", serviceType: "exa")
        store.addSearchProvider(name: "TavilyUnsupported", apiKey: "tvly-secret", serviceType: "tavily")

        let draft = IOSCloudImportDraft.make(from: store)

        // Primary model-only draft only patches model and never bundles search services
        let modelOnly = draft.modelOnlyDraft
        let modelOnlyBundle = modelOnly.bundle(using: store)
        XCTAssertEqual(modelOnlyBundle.model?.providerKind, "openai")
        XCTAssertEqual(modelOnlyBundle.model?.modelId, "gpt-5")
        XCTAssertTrue(modelOnlyBundle.search.isEmpty, "主任务直接切换云端模型时不得夹带搜索源")
        XCTAssertNil(modelOnlyBundle.configurationPatch?.search)

        // Exportable lists only include items ready to export
        XCTAssertTrue(draft.exportableProviders.allSatisfy(\.isExportable))
        XCTAssertTrue(draft.exportableSearches.allSatisfy(\.isExportable))

        // Blocked items are grouped by category without duplicating or echoing secrets
        let summaries = draft.blockedSummaries
        let categories = Set(summaries.map(\.category))
        XCTAssertTrue(categories.contains(.missingApiKey))
        XCTAssertTrue(categories.contains(.oauthNotExportable))
        XCTAssertTrue(categories.contains(.unsupportedProtocol))

        let joinedSummaryText = summaries.map { "\($0.title) \($0.explanation) \($0.itemNames.joined(separator: ","))" }.joined(separator: " | ")
        XCTAssertFalse(joinedSummaryText.contains("sk-codex"))
        XCTAssertFalse(joinedSummaryText.contains("gemini-secret-key"))
        XCTAssertFalse(joinedSummaryText.contains("tvly-secret"))
    }

    // ---- Key Paste & Switching Usability ----

    func testLongKeyPasteTrimsWhitespaceAndNewlinesAndReadsPasteboardOnlyOnExplicitPaste() {
        let longKeyCore = "exa_live_" + String(repeating: "9f8e7d6c5b4a3210", count: 12)
        let rawClipboard = "  \n\t " + longKeyCore + " \r\n  "
        var clipboardReadCount = 0
        var observedBindingValue = ""

        let field = AmberAPIKeyTextField(frame: CGRect(x: 0, y: 0, width: 240, height: 44))
        field.pasteboardStringProvider = {
            clipboardReadCount += 1
            return rawClipboard
        }
        field.onTextChange = { observedBindingValue = $0 }

        XCTAssertTrue(field.isSecureTextEntry, "API Key 输入必须保持不回显")
        XCTAssertEqual(field.intrinsicContentSize.width, UIView.noIntrinsicMetric,
                       "长 Key 粘贴不得撑宽输入框 intrinsicContentSize")
        XCTAssertTrue(field.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil),
                      "长按菜单与 ⌘V 必须始终允许粘贴")
        XCTAssertFalse(field.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil),
                       "密钥输入框禁止复制出明文")
        XCTAssertFalse(field.canPerformAction(#selector(UIResponderStandardEditActions.cut(_:)), withSender: nil),
                       "密钥输入框禁止剪切出明文")
        XCTAssertFalse(field.canPerformAction(#selector(UIResponder.captureTextFromCamera(_:)), withSender: nil),
                       "禁止相机取词/AutoFill 劫持长按菜单")
        XCTAssertEqual(clipboardReadCount, 0, "初始化与查询菜单权限时严禁预读剪贴板")

        let hasCmdVPasteCommand = field.keyCommands?.contains {
            $0.input == "v" && $0.modifierFlags == .command && $0.action == #selector(UIResponderStandardEditActions.paste(_:))
        } ?? false
        XCTAssertTrue(hasCmdVPasteCommand, "必须支持物理键盘 ⌘V 粘贴")

        // 用户主动触发系统粘贴（长按「粘贴」或 ⌘V）
        field.paste(nil)

        XCTAssertEqual(clipboardReadCount, 1, "仅在用户主动粘贴时读取一次剪贴板")
        XCTAssertEqual(field.text, longKeyCore, "长 Key 必须完整粘贴且自动 trim 首尾空白与换行")
        XCTAssertEqual(observedBindingValue, longKeyCore, "粘贴后必须同步更新绑定状态")
        XCTAssertGreaterThan(longKeyCore.count, 180)
    }

    func testActionReadinessAutoAdoptsInitialSnapshotAndReportsSpecificDisabledReasons() {
        let remoteV1 = makeRemote(
            revision: 1, provider: "openai", modelId: "deepseek-chat",
            baseUrl: "https://api.deepseek.com/v1", modelKeyConfigured: true,
            sources: ["bing"], mode: "fallback"
        )
        let remoteV2 = makeRemote(
            revision: 2, provider: "openai", modelId: "gpt-5",
            baseUrl: "https://api.openai.com/v1", modelKeyConfigured: true,
            sources: ["bing", "exa"], mode: "fallback", exaKeyConfigured: true
        )

        // 1. 打开弹窗时若初始快照仍在加载（reviewed == nil），加载完成后自动采纳，绝不产生假版本冲突
        let loadingState = IOSCloudConfigActionReadiness.evaluate(
            reviewed: nil, latest: nil, isLoading: true, isSubmitting: false, formBlocker: nil
        )
        XCTAssertFalse(loadingState.canSubmit)
        XCTAssertFalse(loadingState.hasVersionConflict)
        XCTAssertNotNil(loadingState.disabledReason)
        XCTAssertNotNil(loadingState.nextStep)

        let autoAdopted = IOSCloudConfigActionReadiness.evaluate(
            reviewed: nil, latest: remoteV1, isLoading: false, isSubmitting: false, formBlocker: nil
        )
        XCTAssertTrue(autoAdopted.shouldAutoAdoptLatest)
        XCTAssertFalse(autoAdopted.hasVersionConflict, "首次读取完成不得误报版本冲突")
        XCTAssertTrue(autoAdopted.canSubmit)
        XCTAssertEqual(autoAdopted.effectiveExpectedRevision, 1)
        XCTAssertNil(autoAdopted.disabledReason)

        // 2. 各类表单前置条件缺失时，必须在按钮旁给出具体原因和下一步
        let missingExaKey = IOSCloudConfigActionReadiness.evaluate(
            reviewed: remoteV1, latest: remoteV1, formBlocker: .missingSearchApiKey(serviceName: "Exa")
        )
        XCTAssertFalse(missingExaKey.canSubmit)
        XCTAssertTrue(missingExaKey.disabledReason?.contains("Exa API Key") == true)
        XCTAssertTrue(missingExaKey.nextStep?.contains("粘贴") == true)

        let missingDestKey = IOSCloudConfigActionReadiness.evaluate(
            reviewed: remoteV1, latest: remoteV1, formBlocker: .missingDestinationApiKey
        )
        XCTAssertFalse(missingDestKey.canSubmit)
        XCTAssertTrue(missingDestKey.disabledReason?.contains("Base URL") == true)
        XCTAssertTrue(missingDestKey.nextStep?.contains("API Key") == true)

        // 3. 真实并发版本变化（reviewed=1, latest=2）时明确提示原因与确认动作，确认后立即恢复可提交
        let conflictState = IOSCloudConfigActionReadiness.evaluate(
            reviewed: remoteV1, latest: remoteV2, formBlocker: nil
        )
        XCTAssertTrue(conflictState.hasVersionConflict)
        XCTAssertFalse(conflictState.canSubmit)
        XCTAssertTrue(conflictState.disabledReason?.contains("#2") == true)
        XCTAssertTrue(conflictState.nextStep?.contains("确认最新云端版本") == true)

        let confirmedState = IOSCloudConfigActionReadiness.evaluate(
            reviewed: remoteV2, latest: remoteV2, formBlocker: nil
        )
        XCTAssertFalse(confirmedState.hasVersionConflict)
        XCTAssertTrue(confirmedState.canSubmit)
        XCTAssertEqual(confirmedState.effectiveExpectedRevision, 2)
    }

    func testModelTransitionSummaryShowsCurrentToTargetAndDetectsBaseUrlChanges() throws {
        let store = makeStore()
        let deepseek = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "DeepSeek", apiKey: "sk-ds-long-key", baseUrl: "https://api.deepseek.com/v1",
            modelName: "DeepSeek Chat", modelId: "deepseek-chat"
        ))
        let model = try XCTUnwrap(deepseek.models.first)
        store.setCurrentChatModelId(model.id.description())

        let currentCloud = makeRemote(
            revision: 3, provider: "openai", modelId: "gpt-4.1",
            baseUrl: "https://api.openai.com/v1", modelKeyConfigured: true,
            sources: ["bing"], mode: "fallback"
        )

        let draft = IOSCloudImportDraft.make(from: store)
        let transition = try XCTUnwrap(draft.modelTransitionSummary(remote: currentCloud))

        XCTAssertEqual(transition.current?.modelId, "gpt-4.1")
        XCTAssertEqual(transition.current?.baseUrlDisplay, "api.openai.com")
        XCTAssertEqual(transition.target.providerLabel, "DeepSeek (openai)")
        XCTAssertEqual(transition.target.modelId, "deepseek-chat")
        XCTAssertEqual(transition.target.baseUrlDisplay, "api.deepseek.com")
        XCTAssertTrue(transition.changesEndpointOrModel)
        XCTAssertTrue(transition.replacesOrSetsKey)
        XCTAssertFalse(transition.requiresNewKeyForDestinationChange)
        XCTAssertTrue(transition.transitionArrowLine.contains("gpt-4.1"))
        XCTAssertTrue(transition.transitionArrowLine.contains("deepseek-chat"))

        // 即使同为 openai 协议且同 modelId，只要 Base URL 不同也必须识别为目标变更
        let sameModelDifferentHost = makeRemote(
            revision: 3, provider: "openai", modelId: "deepseek-chat",
            baseUrl: "https://proxy.example.com/v1", modelKeyConfigured: true,
            sources: ["bing"], mode: "fallback"
        )
        let hostTransition = try XCTUnwrap(draft.modelTransitionSummary(remote: sameModelDifferentHost))
        XCTAssertTrue(hostTransition.changesEndpointOrModel, "不同 Base URL 必须识别为切换目标变更")

        // 手动切换服务商或地址但未填新 Key 时，必须提示需要新 Key
        let manualMissingKey = IOSCloudModelTransitionSummary.forManualEdit(
            remote: currentCloud,
            providerKind: .claude,
            modelId: "claude-sonnet-4-5",
            baseUrl: "",
            hasNewApiKey: false
        )
        XCTAssertTrue(manualMissingKey.requiresNewKeyForDestinationChange)
    }

    func testPrimarySwitchStateShowsPlainInUseWhenMatchedAndConciseHintOnlyWhenChanged() throws {
        let store = makeStore()
        let openCode = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "opencode go",
            apiKey: "sk-fake-opencode",
            baseUrl: "https://opencode.ai/zen/v1",
            modelName: "deepseek-v4.1-flash",
            modelId: "deepseek-v4.1-flash"
        ))
        let anthropic = store.addProvider(IosSettingsMutations.shared.buildClaudeProvider(
            name: "Claude",
            apiKey: "sk-ant-fake",
            baseUrl: "https://api.anthropic.com/v1",
            modelName: "claude-sonnet-4-5",
            modelId: "claude-sonnet-4-5"
        ))
        let localClaudeModel = try XCTUnwrap(anthropic.models.first)
        // 本机当前聊天模型使用 Claude，但云端正在使用 opencode go · deepseek-v4.1-flash
        store.setCurrentChatModelId(localClaudeModel.id.description())

        let remoteMatchingOpenCode = makeRemote(
            revision: 4,
            provider: "openai",
            modelId: "deepseek-v4.1-flash",
            baseUrl: "https://opencode.ai/zen/v1",
            modelKeyConfigured: true,
            sources: ["bing", "duckduckgo"],
            mode: "fallback"
        )

        let rawDraft = IOSCloudImportDraft.make(from: store)
        XCTAssertEqual(rawDraft.providerId, anthropic.id.description(), "批量本机同步草稿仍默认指向本机当前聊天服务商")

        // 主操作卡「修改云端配置」初始对齐云端真实配置，显示普通状态「已在使用」，绝不显示可点击主按钮
        let alignedDraft = rawDraft.alignedToRemoteModelIfMatched(remoteMatchingOpenCode)
        XCTAssertEqual(alignedDraft.providerId, openCode.id.description())
        let matchedTransition = try XCTUnwrap(alignedDraft.modelOnlyDraft.modelTransitionSummary(remote: remoteMatchingOpenCode))
        let inUseState = IOSCloudPrimarySwitchState.resolve(
            transition: matchedTransition,
            remote: remoteMatchingOpenCode,
            isLoadingRemote: false,
            isSubmitting: false
        )
        XCTAssertEqual(inUseState, .inUse(missingKey: false))
        XCTAssertFalse(inUseState.showsPrimaryActionButton, "一致时不得显示貌似可点的主按钮")
        XCTAssertEqual(inUseState.statusText, "已在使用")

        // 用户切换到 Claude 模型后，才展示单行简短变化提示与唯一主按钮「切换并使用」，不重复目标摘要/协议/Base URL
        var switchedDraft = alignedDraft
        switchedDraft.providerId = anthropic.id.description()
        switchedDraft.modelUuid = localClaudeModel.id.description()
        let changedTransition = try XCTUnwrap(switchedDraft.modelOnlyDraft.modelTransitionSummary(remote: remoteMatchingOpenCode))
        let readyState = IOSCloudPrimarySwitchState.resolve(
            transition: changedTransition,
            remote: remoteMatchingOpenCode,
            isLoadingRemote: false,
            isSubmitting: false
        )
        XCTAssertEqual(readyState, .readyToSwitch(changeHint: "当前：opencode go · deepseek-v4.1-flash"))
        XCTAssertTrue(readyState.showsPrimaryActionButton)
        if case .readyToSwitch(let hint) = readyState {
            XCTAssertFalse(hint.contains("openai"), "主卡提示不重复平铺协议类型")
            XCTAssertFalse(hint.contains("opencode.ai"), "主卡提示不重复平铺 Base URL")
            XCTAssertFalse(hint.contains("claude-sonnet-4-5"), "主卡提示不重复生成目标摘要")
        }

        // 切换请求进行中保留明确进度状态并收起按钮
        let switchingState = IOSCloudPrimarySwitchState.resolve(
            transition: changedTransition,
            remote: remoteMatchingOpenCode,
            isLoadingRemote: false,
            isSubmitting: true
        )
        XCTAssertEqual(switchingState, .switching)
        XCTAssertFalse(switchingState.showsPrimaryActionButton)
        XCTAssertEqual(switchingState.statusText, "正在切换…")
    }

    func testHttpsUppercaseAndTrailingSlashNormalizeWhileHttpAndQueryBaseUrlsAreBlocked() throws {
        let store = makeStore()
        let openCodeMixedCase = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "opencode go",
            apiKey: "sk-fake-opencode",
            baseUrl: "  HTTPS://OpenCode.AI/zen/v1/  ",
            modelName: "deepseek-v4.1-flash",
            modelId: "deepseek-v4.1-flash"
        ))
        let lanHttpProvider = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "LocalLAN",
            apiKey: "sk-fake-lan",
            baseUrl: "http://192.168.1.20:11434/v1",
            modelName: "qwen",
            modelId: "qwen2.5"
        ))
        let queryUrlProvider = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "QueryEndpoint",
            apiKey: "sk-fake-query",
            baseUrl: "https://api.example.com/v1?api-version=2025",
            modelName: "gpt",
            modelId: "gpt-4.1"
        ))

        let draft = IOSCloudImportDraft.make(from: store)
        let openCodeItem = try XCTUnwrap(draft.providers.first { $0.providerId == openCodeMixedCase.id.description() })
        let lanItem = try XCTUnwrap(draft.providers.first { $0.providerId == lanHttpProvider.id.description() })
        let queryItem = try XCTUnwrap(draft.providers.first { $0.providerId == queryUrlProvider.id.description() })

        XCTAssertTrue(openCodeItem.isExportable, "合法 HTTPS 地址（含大小写与尾斜杠）归一化后应允许云端使用")
        XCTAssertFalse(lanItem.isExportable, "云端契约拒绝非 HTTPS 地址，应在客户端提前拦截而非提交报 422")
        XCTAssertNotNil(lanItem.blockedReason)
        XCTAssertFalse(queryItem.isExportable, "云端契约拒绝带 query/fragment 的 Base URL，应在客户端提前拦截")
        XCTAssertNotNil(queryItem.blockedReason)

        var selected = draft.modelOnlyDraft
        selected.providerId = openCodeItem.providerId
        selected.modelUuid = openCodeItem.defaultModelUuid
        let bundle = selected.bundle(using: store)
        XCTAssertEqual(
            bundle.model?.baseUrl,
            "https://opencode.ai/zen/v1",
            "上传到云端的 baseUrl 必须归一化小写 scheme/host 并去除尾斜杠，满足服务端 java.net.URI 严格 https 校验"
        )

        let remoteCanonical = makeRemote(
            revision: 4,
            provider: "openai",
            modelId: "deepseek-v4.1-flash",
            baseUrl: "https://opencode.ai/zen/v1",
            modelKeyConfigured: true,
            sources: ["bing"],
            mode: "fallback"
        )
        let aligned = draft.alignedForPrimarySwitch(remote: remoteCanonical)
        XCTAssertEqual(aligned.providerId, openCodeItem.providerId)
        let transition = try XCTUnwrap(aligned.modelOnlyDraft.modelTransitionSummary(remote: remoteCanonical))
        XCTAssertFalse(transition.changesEndpointOrModel, "大小写或尾斜杠差异归一化后应准确识别为同一云端配置")
    }

    func testPrimarySwitchFallbackWhenLocalActiveChatIsOAuthAndMissingCloudKeyAllowsSwitch() throws {
        let store = makeStore()
        let codexProvider = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "CodexAccount",
            apiKey: "sk-codex-placeholder",
            baseUrl: "https://chatgpt.com/backend-api/codex",
            modelName: "Codex",
            modelId: "gpt-5-codex"
        ))
        _ = store.setOpenAIAuthMode(providerId: codexProvider.id.description(), authMode: OpenAIAuthMode.codexOauth)
        let codexModel = try XCTUnwrap(codexProvider.models.first)
        store.setCurrentChatModelId(codexModel.id.description())

        let openCode = store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "opencode go",
            apiKey: "sk-fake-opencode",
            baseUrl: "https://opencode.ai/zen/v1",
            modelName: "deepseek-v4.1-flash",
            modelId: "deepseek-v4.1-flash"
        ))
        let claude = store.addProvider(IosSettingsMutations.shared.buildClaudeProvider(
            name: "Claude",
            apiKey: "sk-fake-claude",
            baseUrl: "https://api.anthropic.com/v1",
            modelName: "claude-sonnet-4-5",
            modelId: "claude-sonnet-4-5"
        ))
        let claudeModel = try XCTUnwrap(claude.models.first)

        let rawDraft = IOSCloudImportDraft.make(from: store)
        XCTAssertNil(rawDraft.providerId, "从本机同步默认草稿在当前聊天为 OAuth 时保持 nil，不替用户乱勾账号")

        // 主切换卡在云端尚未设置或未匹配时，必须回退选中首个可切换服务商，绝不能折叠掉模型行与切换按钮
        let switchFallback = rawDraft.alignedForPrimarySwitch(remote: nil)
        XCTAssertEqual(switchFallback.providerId, openCode.id.description())
        XCTAssertNotNil(switchFallback.selectedModel)

        // 若云端模型与当前所选一致但缺少 Key（modelKeyConfigured == false），允许点击「切换并使用」补齐本机 Key
        let remoteMissingKey = makeRemote(
            revision: 2,
            provider: "openai",
            modelId: "deepseek-v4.1-flash",
            baseUrl: "https://opencode.ai/zen/v1",
            modelKeyConfigured: false,
            sources: ["bing"],
            mode: "fallback"
        )
        let alignedMissingKey = rawDraft.alignedForPrimarySwitch(remote: remoteMissingKey)
        let missingKeyTransition = try XCTUnwrap(
            alignedMissingKey.modelOnlyDraft.modelTransitionSummary(
                remote: remoteMissingKey,
                localProviders: alignedMissingKey.providers
            )
        )
        let missingKeyState = IOSCloudPrimarySwitchState.resolve(
            transition: missingKeyTransition,
            remote: remoteMissingKey,
            isLoadingRemote: false,
            isSubmitting: false
        )
        XCTAssertTrue(missingKeyState.showsPrimaryActionButton, "云端缺 Key 且本机有 Key 时应允许点击主按钮补齐 Key")

        // 跨服务商切换（opencode go → Claude）时，变化提示同时带出云端当前友好服务商名与模型 ID
        let remoteWithKey = makeRemote(
            revision: 3,
            provider: "openai",
            modelId: "deepseek-v4.1-flash",
            baseUrl: "https://opencode.ai/zen/v1",
            modelKeyConfigured: true,
            sources: ["bing"],
            mode: "fallback"
        )
        var crossProviderDraft = rawDraft.alignedForPrimarySwitch(remote: remoteWithKey)
        crossProviderDraft.providerId = claude.id.description()
        crossProviderDraft.modelUuid = claudeModel.id.description()
        let crossTransition = try XCTUnwrap(
            crossProviderDraft.modelOnlyDraft.modelTransitionSummary(
                remote: remoteWithKey,
                localProviders: crossProviderDraft.providers
            )
        )
        let crossState = IOSCloudPrimarySwitchState.resolve(
            transition: crossTransition,
            remote: remoteWithKey,
            isLoadingRemote: false,
            isSubmitting: false
        )
        XCTAssertEqual(crossState, .readyToSwitch(changeHint: "当前：opencode go · deepseek-v4.1-flash"))
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
