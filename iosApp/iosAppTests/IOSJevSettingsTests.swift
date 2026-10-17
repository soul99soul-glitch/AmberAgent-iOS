import XCTest
import UIKit
@testable import iosApp

// IOSJevSettingsTests：默认 off、持久化 round-trip、active 无固定版本降级、
// 范围判定、revision 递增、Keychain Key 存取闭环、指标上限与清除。

final class IOSJevSettingsTests: XCTestCase {

    private func isolatedDefaults() -> UserDefaults {
        let suite = "IOSJevSettingsTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    // MARK: Settings semantics

    func testDefaultSettingsAreAllOff() {
        let settings = IOSJevSettings()
        for useCase in IOSJevUseCase.allCases {
            XCTAssertEqual(settings.mode(for: useCase), .off, "\(useCase) must default off")
            XCTAssertEqual(settings.effectiveMode(for: useCase), .off)
        }
        XCTAssertNil(settings.pinnedModelVersion)
        XCTAssertEqual(settings.revision, 0)
    }

    func testActiveWithoutPinnedVersionDegradesToShadow() {
        var settings = IOSJevSettings()
        settings.setMode(.active, for: .toolDiscovery)
        // 未 pin 版本。
        XCTAssertEqual(settings.effectiveMode(for: .toolDiscovery), .shadow)
        // pin 了实验版同样不作为 active 依据。
        settings.pinnedModelVersion = "jev-latest"
        XCTAssertEqual(settings.effectiveMode(for: .toolDiscovery), .shadow)
        // 固定版本后 active 生效。
        settings.pinnedModelVersion = "jev-fixed-v3"
        XCTAssertEqual(settings.effectiveMode(for: .toolDiscovery), .active)
    }

    func testCanSendRequiresAllScopes() {
        var settings = IOSJevSettings()
        settings.setScopes([.toolMetadata], for: .toolDiscovery)
        XCTAssertTrue(settings.canSend(useCase: .toolDiscovery, required: [.toolMetadata]))
        XCTAssertFalse(settings.canSend(useCase: .toolDiscovery, required: [.toolMetadata, .selectedTaskText]))
    }

    func testPhoneUseCasesRequirePhoneContentAndKeepScopesIndependent() {
        var settings = IOSJevSettings()
        for useCase in [IOSJevUseCase.phoneVerification, .phoneActions] {
            XCTAssertEqual(settings.mode(for: useCase), .off)
            XCTAssertTrue(settings.allowedScopes(for: useCase).isEmpty)
            XCTAssertEqual(useCase.defaultDataScopes, [.selectedTaskText, .phoneContent])
            settings.setMode(.active, for: useCase)
            XCTAssertEqual(settings.effectiveMode(for: useCase), .shadow)
        }
        settings.setPinnedModelVersion("jev-fixed-v3")
        XCTAssertEqual(settings.effectiveMode(for: .phoneActions), .active)
        settings.setScopes([.selectedTaskText, .webContent, .toolOutput], for: .phoneVerification)
        XCTAssertFalse(settings.canSend(useCase: .phoneVerification, required: IOSJevUseCase.phoneVerification.defaultDataScopes),
                       "网页或普通工具范围不能替代手机界面文字授权")
        XCTAssertTrue(settings.canSend(useCase: .phoneActions, required: IOSJevUseCase.phoneActions.defaultDataScopes),
                      "收紧效果检查的数据范围不改变快速操作的范围")
    }

    func testPhoneSettingsPersistScopeRevocationAndMode() {
        let defaults = isolatedDefaults()
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        var settings = store.jevSettings
        settings.setPinnedModelVersion("jev-fixed-v3")
        settings.setMode(.active, for: .phoneVerification)
        settings.setMode(.shadow, for: .phoneActions)
        let beforeRevocation = settings.revision
        settings.setScopes([.selectedTaskText], for: .phoneVerification)
        store.updateJevSettings(settings)

        let reloaded = IOSSharedSettingsStore(userDefaults: defaults).jevSettings
        XCTAssertEqual(reloaded.effectiveMode(for: .phoneVerification), .active)
        XCTAssertEqual(reloaded.effectiveMode(for: .phoneActions), .shadow)
        XCTAssertGreaterThan(reloaded.revision, beforeRevocation)
        XCTAssertFalse(reloaded.canSend(useCase: .phoneVerification, required: IOSJevUseCase.phoneVerification.defaultDataScopes))
        XCTAssertEqual(reloaded.allowedScopes(for: .phoneActions), [.selectedTaskText, .phoneContent])
    }

    func testScreenshotScopePersistsWithoutChangingExistingVersionOrOtherPhoneUseCase() {
        let defaults = isolatedDefaults()
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        var settings = store.jevSettings
        settings.setPinnedModelVersion("jev-1.13.0")
        settings.setMode(.active, for: .phoneActions)
        settings.setMode(.active, for: .phoneVerification)
        XCTAssertFalse(settings.canSendPhoneScreenshots(for: .phoneActions))
        settings.setScopes(settings.allowedScopes(for: .phoneActions).union([.phoneScreenshots]), for: .phoneActions)
        store.updateJevSettings(settings)
        let loaded = IOSSharedSettingsStore(userDefaults: defaults).jevSettings
        XCTAssertEqual(loaded.pinnedModelVersion, "jev-1.13.0")
        XCTAssertTrue(loaded.canSendPhoneScreenshots(for: .phoneActions))
        XCTAssertFalse(loaded.canSendPhoneScreenshots(for: .phoneVerification))
        var revoked = loaded
        revoked.setScopes([.phoneContent, .phoneScreenshots], for: .phoneActions)
        XCTAssertFalse(revoked.canSendPhoneScreenshots(for: .phoneActions), "image scope cannot replace task-text permission")
        var gateway = loaded
        gateway.setAPIStyle(.vercelGateway)
        XCTAssertTrue(gateway.canSendPhoneScreenshots(for: .phoneActions))
        gateway.setProviderModel("typesafe-ai/jev")
        XCTAssertFalse(gateway.canSendPhoneScreenshots(for: .phoneActions))
    }

    func testLegacyPreviewPinDoesNotEnableActiveMode() throws {
        let settings = try JSONDecoder().decode(IOSJevSettings.self, from: Data("""
        {"pinnedModelVersion":"jev-preview","modes":{"phoneActions":"active"}}
        """.utf8))
        XCTAssertEqual(settings.effectiveMode(for: .phoneActions), .shadow)
    }

    func testAddingPhonePolicyDoesNotMigrateExistingActiveUseCases() throws {
        var settings = IOSJevSettings()
        settings.setPinnedModelVersion("jev-fixed-v3")
        settings.setMode(.active, for: .webActions)
        settings.policy.webActionsMinConfidence = 0.73
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        var policy = try XCTUnwrap(object["policy"] as? [String: Any])
        policy.removeValue(forKey: "phoneActionsMinConfidence")
        object["policy"] = policy

        let decoded = try JSONDecoder().decode(IOSJevSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.effectiveMode(for: .webActions), .active)
        XCTAssertEqual(decoded.policy.webActionsMinConfidence, 0.73)
        XCTAssertEqual(decoded.policy.phoneActionsMinConfidence, 0.6)
        XCTAssertEqual(decoded.mode(for: .phoneVerification), .off)
        XCTAssertEqual(decoded.mode(for: .phoneActions), .off)
        XCTAssertEqual(decoded.policy.activeWaitBudgetMs(for: .phoneVerification), decoded.policy.deadlineMs)
        XCTAssertEqual(decoded.policy.activeWaitBudgetMs(for: .phoneActions), decoded.policy.webActionsDeadlineMs)
    }

    func testSetModeAndScopesBumpRevision() {
        var settings = IOSJevSettings()
        settings.setMode(.shadow, for: .memoryRecall)
        let afterMode = settings.revision
        XCTAssertGreaterThan(afterMode, 0)
        settings.setScopes([.personalMemory], for: .memoryRecall)
        XCTAssertGreaterThan(settings.revision, afterMode)
    }

    func testCodableRoundTrip() throws {
        var settings = IOSJevSettings()
        settings.setMode(.shadow, for: .toolDiscovery)
        settings.setMode(.active, for: .memoryRecall)
        settings.pinnedModelVersion = "jev-fixed-v3"
        settings.setScopes([.toolMetadata, .selectedTaskText], for: .toolDiscovery)
        settings.bumpRevision()

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(IOSJevSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testLegacyDecodeDefaultsOff() throws {
        // 旧持久化（无 modes 字段）解码后必须全 off。
        let legacy = """
        {"schemaVersion":1,"revision":4}
        """
        let settings = try JSONDecoder().decode(IOSJevSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.mode(for: .toolDiscovery), .off)
        XCTAssertEqual(settings.mode(for: .memoryRecall), .off)
        XCTAssertEqual(settings.revision, 4)
    }

    // MARK: API 形态（systemone / vercelGateway）

    func testDefaultAPIStyleIsSystemone() {
        let settings = IOSJevSettings()
        XCTAssertEqual(settings.apiStyle, .systemone)
        XCTAssertEqual(settings.providerModel, "")
        XCTAssertEqual(settings.resolvedEndpoint, IOSJevSettings.productionEndpoint)
        XCTAssertEqual(settings.activeModelVersion, "jev-1.14.0")
        XCTAssertTrue(settings.modelConfigured)
    }

    func testVercelStyleResolvesEndpointAndModel() {
        var settings = IOSJevSettings()
        settings.setAPIStyle(.vercelGateway)
        settings.setProviderModel("  openai/gpt-4o  ")
        XCTAssertEqual(settings.resolvedEndpoint, IOSJevSettings.vercelGatewayEndpoint)
        XCTAssertEqual(settings.providerModel, "openai/gpt-4o", "slug 必须 trim")
        XCTAssertEqual(settings.activeModelVersion, "openai/gpt-4o")
        XCTAssertTrue(settings.modelConfigured)
    }

    /// 选 vercel 形态自动填默认 slug（typesafe-ai/jev）——用户只需配 Key；
    /// 已有自定义 slug 不被覆盖。
    func testVercelStyleSelectionPrefillsDefaultModel() {
        var settings = IOSJevSettings()
        settings.setAPIStyle(.vercelGateway)
        XCTAssertEqual(settings.providerModel, IOSJevSettings.vercelDefaultModel)
        XCTAssertEqual(settings.activeModelVersion, "typesafe-ai/jev-1.14.0")
        // 显式改过的 slug 不因重选被覆盖。
        settings.setProviderModel("openai/gpt-5.6-luna")
        settings.setAPIStyle(.systemone)
        settings.setAPIStyle(.vercelGateway)
        XCTAssertEqual(settings.providerModel, "openai/gpt-5.6-luna")
        // systemone 默认不填 vercel slug（无意义字段不污染存量配置）。
        XCTAssertEqual(IOSJevSettings().providerModel, "")
    }

    /// 四家供应商的端点 / 默认模型 / 截图能力一次锁定。
    func testAllProvidersResolveEndpointModelAndCapabilities() {
        struct Expectation {
            let style: IOSJevAPIStyle
            let endpoint: URL
            let model: String
            let screenshots: Bool
        }
        let expected = [
            Expectation(style: .systemone, endpoint: IOSJevProvider.typesafe.endpoint, model: "jev-1.14.0", screenshots: true),
            Expectation(style: .vercelGateway, endpoint: IOSJevProvider.vercelGateway.endpoint, model: "typesafe-ai/jev-1.14.0", screenshots: true),
            Expectation(style: .perplexityDecisions, endpoint: IOSJevProvider.perplexity.endpoint, model: "pplx-decider-v1.2", screenshots: false),
            Expectation(style: .liquidSystemone, endpoint: IOSJevProvider.liquid.endpoint, model: "d1", screenshots: false),
        ]
        for item in expected {
            var settings = IOSJevSettings()
            settings.setAPIStyle(item.style)
            XCTAssertEqual(settings.resolvedEndpoint, item.endpoint, "\(item.style)")
            XCTAssertEqual(settings.recommendedModelForAPI, item.model, "\(item.style)")
            if item.style != .systemone {
                XCTAssertEqual(settings.activeModelVersion, item.model, "\(item.style) 选型应自动填入默认模型")
            }
            XCTAssertEqual(settings.supportsPhoneScreenshots, item.screenshots, "\(item.style)")
        }
    }

    /// 非原生供应商没有模型时不能报 active：否则 runtime_status 显示 active，
    /// 实际每次都被 model_unspecified 静默跳过。
    func testNewProvidersRequireConfiguredModelForActive() {
        var settings = IOSJevSettings()
        settings.setAPIStyle(.perplexityDecisions)
        settings.setProviderModel("")
        settings.setMode(.active, for: .toolDiscovery)
        XCTAssertEqual(settings.effectiveMode(for: .toolDiscovery), .shadow)
        settings.setProviderModel("pplx-decider-v1.2")
        XCTAssertEqual(settings.effectiveMode(for: .toolDiscovery), .active)
    }

    /// 跨供应商切换不能把上一家的默认模型带进新家（含经 systemone 中转）。
    func testSwitchingProvidersDoesNotCarryPreviousDefaultModel() {
        var settings = IOSJevSettings()
        settings.setAPIStyle(.vercelGateway)
        XCTAssertEqual(settings.providerModel, "typesafe-ai/jev-1.14.0")
        settings.setAPIStyle(.perplexityDecisions)
        XCTAssertEqual(settings.providerModel, "pplx-decider-v1.2")
        settings.setAPIStyle(.systemone)
        settings.setAPIStyle(.liquidSystemone)
        XCTAssertEqual(settings.providerModel, "d1")
        // 自定义值归属于 Liquid：切到 Perplexity 必须换成 Perplexity 的默认模型，
        // 否则会把 d1-ultra 发到 Perplexity 的端点。
        settings.setProviderModel("d1-ultra")
        settings.setAPIStyle(.perplexityDecisions)
        XCTAssertEqual(settings.providerModel, "pplx-decider-v1.2")
        // 归属仍是同一家时（经 systemone 中转）保留自定义值。
        settings.setAPIStyle(.liquidSystemone)
        settings.setProviderModel("d1-ultra")
        settings.setAPIStyle(.systemone)
        settings.setAPIStyle(.liquidSystemone)
        XCTAssertEqual(settings.providerModel, "d1-ultra")
    }

    /// 归属字段必须真的落盘：若 encode 缺失，解码只能按 apiStyle 推断，
    /// 这条断言就会把自定义值清成默认值。
    func testProviderModelStyleSurvivesRoundTrip() throws {
        var settings = IOSJevSettings()
        settings.setAPIStyle(.liquidSystemone)
        settings.setProviderModel("d1-ultra")
        settings.setAPIStyle(.systemone)   // 不碰 providerModel / 归属
        let decoded = try JSONDecoder().decode(IOSJevSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.providerModelStyle, .liquidSystemone, "归属必须落盘，不能靠推断重建")
        var restored = decoded
        restored.setAPIStyle(.liquidSystemone)
        XCTAssertEqual(restored.providerModel, "d1-ultra", "同家往返保留自定义模型")
    }

    /// 旧 JSON 没有归属字段：槽位语义就是当前供应商的模型，不能当成未知。
    func testLegacyProviderModelWithoutOwnerInfersCurrentStyle() throws {
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(IOSJevSettings())) as? [String: Any]
        )
        legacy["apiStyle"] = "perplexityDecisions"
        legacy["vercelModel"] = "pplx-decider-v9"
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(IOSJevSettings.self, from: data)
        XCTAssertEqual(decoded.providerModelStyle, .perplexityDecisions)
        var settings = decoded
        settings.setAPIStyle(.systemone)
        settings.setAPIStyle(.perplexityDecisions)
        XCTAssertEqual(settings.providerModel, "pplx-decider-v9", "迁移后同家往返不该被换成默认值")
    }

    func testVercelActiveRequiresConfiguredModel() {
        var settings = IOSJevSettings()
        settings.setAPIStyle(.vercelGateway)
        // 默认 slug 已自动填入，active 直接生效。
        settings.setMode(.active, for: .toolDiscovery)
        XCTAssertEqual(settings.effectiveMode(for: .toolDiscovery), .active)
        // 显式清空 slug：active 按 shadow 收口。
        settings.setProviderModel("")
        XCTAssertEqual(settings.effectiveMode(for: .toolDiscovery), .shadow)
        XCTAssertFalse(settings.modelConfigured)
        // 填 slug 即固定版本，active 生效（pinnedModelVersion 不参与 vercel 判定）。
        settings.setProviderModel("anthropic/claude-haiku-4.5")
        XCTAssertEqual(settings.effectiveMode(for: .toolDiscovery), .active)
        // 反向：systemone 下 vercelModel 不影响 pinned 判定。
        settings.setAPIStyle(.systemone)
        settings.pinnedModelVersion = nil
        XCTAssertEqual(settings.effectiveMode(for: .toolDiscovery), .shadow)
    }

    func testAPIStyleSettersBumpRevision() {
        var settings = IOSJevSettings()
        let r0 = settings.revision
        settings.setAPIStyle(.vercelGateway)
        XCTAssertGreaterThan(settings.revision, r0)
        let r1 = settings.revision
        settings.setProviderModel("openai/gpt-4o")
        XCTAssertGreaterThan(settings.revision, r1)
    }

    func testAPIStyleRoundTripAndLegacyDecode() throws {
        var settings = IOSJevSettings()
        settings.setAPIStyle(.vercelGateway)
        settings.setProviderModel("openai/gpt-4o")
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(IOSJevSettings.self, from: data), settings)

        // 旧 JSON 无新字段 → 默认 systemone，不破坏存量设置。
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "apiStyle")
        legacyObject.removeValue(forKey: "vercelModel")
        let decoded = try JSONDecoder().decode(
            IOSJevSettings.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        XCTAssertEqual(decoded.apiStyle, .systemone)
        XCTAssertEqual(decoded.providerModel, "")
    }

    /// 手动 pin 直接控制 effectiveMode：systemone 空 pin→shadow，固定版本→active，
    /// 清空（含空白）→回未验收 shadow。
    func testSetPinnedModelVersionControlsEffectiveMode() {
        var settings = IOSJevSettings()
        settings.setMode(.active, for: .webActions)
        XCTAssertEqual(settings.effectiveMode(for: .webActions), .shadow, "未验收一律 shadow")
        settings.setPinnedModelVersion("jev-2026-09-15")
        XCTAssertEqual(settings.effectiveMode(for: .webActions), .active)
        settings.setPinnedModelVersion("jev-latest")
        XCTAssertNil(settings.pinnedModelVersion, "浮动别名同验收口径：不存不留")
        XCTAssertEqual(settings.effectiveMode(for: .webActions), .shadow)
        settings.setPinnedModelVersion("jev-preview")
        XCTAssertNil(settings.pinnedModelVersion, "preview alias moves with releases and cannot pin acceptance")
        XCTAssertEqual(settings.effectiveMode(for: .webActions), .shadow)
        settings.setPinnedModelVersion("  ")
        XCTAssertNil(settings.pinnedModelVersion)
        XCTAssertEqual(settings.effectiveMode(for: .webActions), .shadow, "清空回到未验收")
    }

    /// 连接测试验收只认具体版本：浮动别名/空值不落 pin；vercel 的 slug 即
    /// 固定版本，验收入口不动 pinned 字段。
    func testAcceptVerifiedModelVersion() {
        var settings = IOSJevSettings()
        settings.setMode(.active, for: .toolDiscovery)
        settings.acceptVerifiedModelVersion("jev-latest")
        XCTAssertNil(settings.pinnedModelVersion, "浮动别名不验收")
        settings.acceptVerifiedModelVersion("jev-preview")
        XCTAssertNil(settings.pinnedModelVersion)
        settings.acceptVerifiedModelVersion(nil)
        XCTAssertNil(settings.pinnedModelVersion)
        settings.acceptVerifiedModelVersion("jev-2026-09-15")
        XCTAssertEqual(settings.pinnedModelVersion, "jev-2026-09-15")
        XCTAssertEqual(settings.effectiveMode(for: .toolDiscovery), .active)

        var vercel = IOSJevSettings()
        vercel.setAPIStyle(.vercelGateway)
        vercel.setMode(.active, for: .toolDiscovery)
        vercel.acceptVerifiedModelVersion("anything")
        XCTAssertNil(vercel.pinnedModelVersion, "vercel 无需验收，pinned 字段不动")
        XCTAssertEqual(vercel.effectiveMode(for: .toolDiscovery), .active)
    }

    /// 存量 v1 策略（预算 6 次/轮、1000 次/日）经版本迁移整体回 v2 默认；
    /// v2 存量保留存储值不被覆盖。
    func testLegacyPolicyVersionResetsToCurrentDefaults() throws {
        let settings = IOSJevSettings()
        var policyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(settings.policy)) as? [String: Any]
        )
        policyObject["policyVersion"] = 1
        policyObject["perTurnRequestBudget"] = 6
        policyObject["dailyRequestBudget"] = 1_000
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(settings)) as? [String: Any]
        )
        object["policy"] = policyObject
        let decoded = try JSONDecoder().decode(
            IOSJevSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.policy.policyVersion, IOSJevPolicy.currentPolicyVersion)
        XCTAssertEqual(decoded.policy.perTurnRequestBudget, 2_000)
        XCTAssertEqual(decoded.policy.dailyRequestBudget, 100_000)

        var v2Policy = policyObject
        v2Policy["policyVersion"] = IOSJevPolicy.currentPolicyVersion
        v2Policy["perTurnRequestBudget"] = 77
        object["policy"] = v2Policy
        let decodedV2 = try JSONDecoder().decode(
            IOSJevSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decodedV2.policy.perTurnRequestBudget, 77, "v2 存量保留存储值")
    }

    func testPolicyV3MigrationReturnsActiveUseCasesToShadow() throws {
        var settings = IOSJevSettings()
        settings.setMode(.active, for: .toolDiscovery)
        settings.setMode(.active, for: .memoryRecall)
        settings.setMode(.off, for: .webActions)
        settings.pinnedModelVersion = "jev-fixed-v2"
        settings.setScopes([.toolMetadata], for: .toolDiscovery)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        var policy = try XCTUnwrap(object["policy"] as? [String: Any])
        policy["policyVersion"] = 2
        object["policy"] = policy
        let migrated = try JSONDecoder().decode(IOSJevSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated.policy.policyVersion, 3)
        XCTAssertEqual(migrated.mode(for: .toolDiscovery), .shadow)
        XCTAssertEqual(migrated.mode(for: .memoryRecall), .shadow)
        XCTAssertEqual(migrated.mode(for: .webActions), .off)
        XCTAssertEqual(migrated.allowedScopes(for: .toolDiscovery), [.toolMetadata])
        XCTAssertEqual(migrated.pinnedModelVersion, "jev-fixed-v2")
    }

    // MARK: Store wiring

    func testStorePersistsAndUpdatesJevSettings() {
        let defaults = isolatedDefaults()
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        XCTAssertEqual(store.jevSettings.mode(for: .toolDiscovery), .off)

        var settings = store.jevSettings
        settings.setMode(.shadow, for: .toolDiscovery)
        store.updateJevSettings(settings)

        // 新实例读回（持久化闭环）。
        let reloaded = IOSSharedSettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.jevSettings.mode(for: .toolDiscovery), .shadow)
        XCTAssertEqual(reloaded.jevSettings.revision, settings.revision)

        // API 形态/vercel 模型同样经 store 持久化闭环。
        settings.setAPIStyle(.vercelGateway)
        settings.setProviderModel("openai/gpt-4o")
        store.updateJevSettings(settings)
        let reloaded2 = IOSSharedSettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded2.jevSettings.apiStyle, .vercelGateway)
        XCTAssertEqual(reloaded2.jevSettings.providerModel, "openai/gpt-4o")

        // 固定模型版本经 store 持久化闭环（runtime effectiveMode 消费）。
        settings.setPinnedModelVersion("jev-2026-09-15")
        store.updateJevSettings(settings)
        let reloaded3 = IOSSharedSettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded3.jevSettings.pinnedModelVersion, "jev-2026-09-15")
    }

    func testRecommendedConfigurationPersistsOnlyLowRiskShadowUseCases() {
        let defaults = isolatedDefaults()
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        var settings = store.jevSettings
        settings.applyRecommendedConfiguration()
        store.updateJevSettings(settings)
        let reloaded = IOSSharedSettingsStore(userDefaults: defaults).jevSettings
        for useCase in [IOSJevUseCase.toolDiscovery, .memoryRecall, .contextSelection, .toolResultRetention, .modelRouting, .subagentIntent, .completionCheck] {
            XCTAssertEqual(reloaded.effectiveMode(for: useCase), .shadow)
            XCTAssertEqual(reloaded.allowedScopes(for: useCase), useCase.defaultDataScopes)
        }
        XCTAssertEqual(reloaded.mode(for: .webActions), .off)
        XCTAssertEqual(reloaded.mode(for: .approvalTriage), .off)
        for useCase in [IOSJevUseCase.phoneVerification, .phoneActions] {
            XCTAssertEqual(reloaded.mode(for: useCase), .off)
            XCTAssertTrue(reloaded.allowedScopes(for: useCase).isEmpty,
                          "推荐配置不能悄悄开放手机文字范围")
        }
        XCTAssertTrue(reloaded.allowedScopes(for: .modelRouting).contains(.modelMetadata))
    }

    func testStoreApiKeyLifecycleRequiresKeychainSuccess() {
        let defaults = isolatedDefaults()
        let store = IOSSharedSettingsStore(userDefaults: defaults)

        XCTAssertFalse(store.hasJevApiKey())
        // 空 Key 拒绝。
        XCTAssertFalse(store.storeJevApiKey("   "))
        // 正常保存。
        XCTAssertTrue(store.storeJevApiKey("sk-test-123"))
        XCTAssertTrue(store.hasJevApiKey())
        XCTAssertEqual(IOSCredentialSideTable.load(key: IOSCredentialSideTable.jevApiKey), "sk-test-123")

        let revisionAfterStore = store.jevSettings.revision
        // 清除。
        store.clearJevApiKey()
        XCTAssertFalse(store.hasJevApiKey())
        XCTAssertNil(IOSCredentialSideTable.load(key: IOSCredentialSideTable.jevApiKey))
        XCTAssertGreaterThan(store.jevSettings.revision, revisionAfterStore, "clear must bump revision to invalidate in-flight results")

        // 测试后清理，避免污染模拟器 Keychain。
        IOSCredentialSideTable.delete(key: IOSCredentialSideTable.jevApiKey)
    }

    func testSideTableStoreUpdatesInPlaceAndKeepsReadable() {
        // P0 回归：store 改为 SecItemUpdate 优先——重复保存不删除旧值，
        // 任何一步失败都不应让已存在的可用 Key 消失。
        let key = IOSCredentialSideTable.jevApiKey
        defer { IOSCredentialSideTable.delete(key: key) }
        IOSCredentialSideTable.delete(key: key)

        XCTAssertTrue(IOSCredentialSideTable.store(key: key, value: "first-key"))
        XCTAssertEqual(IOSCredentialSideTable.load(key: key), "first-key")
        // 第二次保存走 update 路径：替换值且依旧可读。
        XCTAssertTrue(IOSCredentialSideTable.store(key: key, value: "second-key"))
        XCTAssertEqual(IOSCredentialSideTable.load(key: key), "second-key")
        XCTAssertTrue(IOSCredentialSideTable.store(key: key, value: "third-key"))
        XCTAssertEqual(IOSCredentialSideTable.load(key: key), "third-key")
    }

    // MARK: Metrics

    func testMetricsAppendLoadAndClear() {
        IOSJevMetricsStore.clear()
        defer { IOSJevMetricsStore.clear() }
        IOSJevMetricsStore.append(IOSJevMetricsRecord(
            timestamp: Date(), useCase: .toolDiscovery, mode: .shadow, modelVersion: "jev-latest",
            outcome: "observed", latencyMs: 120, requestBytes: 100, responseBytes: 200,
            inputTokens: 1, outputTokens: 2, reason: nil
        ))
        let loaded = IOSJevMetricsStore.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.outcome, "observed")
        IOSJevMetricsStore.clear()
        XCTAssertTrue(IOSJevMetricsStore.load().isEmpty)
    }

    func testMetricsFlushPersistsBufferedRecord() throws {
        IOSJevMetricsStore.clear()
        defer { IOSJevMetricsStore.clear() }
        IOSJevMetricsStore.append(IOSJevMetricsRecord(
            timestamp: Date(), useCase: .toolDiscovery, mode: .shadow, modelVersion: "jev-latest",
            outcome: "observed", latencyMs: 120, requestBytes: 100, responseBytes: 200,
            inputTokens: 1, outputTokens: 2, reason: nil
        ))
        XCTAssertNil(UserDefaults.standard.data(forKey: "app.amber.ios.jevMetrics.v1"))
        IOSJevMetricsStore.flush()
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "app.amber.ios.jevMetrics.v1"))
        XCTAssertEqual(try JSONDecoder().decode([IOSJevMetricsRecord].self, from: data).count, 1)
    }

    func testMetricsAppendedAfterBackgroundNotificationPersistImmediately() throws {
        IOSJevMetricsStore.clear()
        defer {
            NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
            IOSJevMetricsStore.clear()
        }
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        IOSJevMetricsStore.append(IOSJevMetricsRecord(
            timestamp: Date(), useCase: .memoryRecall, mode: .shadow, modelVersion: "jev-latest",
            outcome: "late", latencyMs: 500, requestBytes: 100, responseBytes: 100,
            inputTokens: nil, outputTokens: nil, reason: "late"
        ))
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "app.amber.ios.jevMetrics.v1"))
        XCTAssertEqual(try JSONDecoder().decode([IOSJevMetricsRecord].self, from: data).last?.outcome, "late")
    }

    func testUseCaseSummariesIncludeBusinessFallbackAndWebCompletion() {
        IOSJevMetricsStore.clear()
        defer { IOSJevMetricsStore.clear() }
        let now = Date()
        IOSJevMetricsStore.append(IOSJevMetricsRecord(
            timestamp: now, useCase: .toolDiscovery, mode: .active, modelVersion: "jev-v1",
            outcome: "summary", latencyMs: 0, requestBytes: 0, responseBytes: 0,
            inputTokens: nil, outputTokens: nil, reason: "no_suitable_tool",
            numbers: ["business_fallback": 1, "exposure_ratio": 0.8, "next_step_new_tool_used": 1]
        ))
        for completed in [1.0, 0.0] {
            IOSJevMetricsStore.append(IOSJevMetricsRecord(
                timestamp: now, useCase: .webActions, mode: .active, modelVersion: "jev-v1",
                outcome: "summary", latencyMs: 0, requestBytes: 0, responseBytes: 0,
                inputTokens: nil, outputTokens: nil,
                reason: completed == 0 ? "jev_uncertain" : nil,
                numbers: ["web_completed": completed, "handback": 1 - completed]
            ))
        }
        let summaries = IOSJevMetricsStore.useCaseSummaries(now: now)
        XCTAssertEqual(summaries.first(where: { $0.useCase == .toolDiscovery })?.fallbackReasons["no_suitable_tool"], 1)
        XCTAssertEqual(summaries.first(where: { $0.useCase == .webActions })?.completionRate, 0.5)
        XCTAssertEqual(summaries.first(where: { $0.useCase == .webActions })?.fallbackReasons["jev_uncertain"], 1)
        for _ in 0..<2 {
            IOSJevMetricsStore.append(IOSJevMetricsRecord(
                timestamp: now, useCase: .contextSelection, mode: .active, modelVersion: "jev-v1",
                outcome: "summary", latencyMs: 0, requestBytes: 0, responseBytes: 0,
                inputTokens: nil, outputTokens: nil, reason: nil,
                runId: "run", numbers: ["hidden_characters": 1_200, "hidden_blocks": 4, "reread_after_hide_count": 1]
            ))
        }
        XCTAssertEqual(IOSJevMetricsStore.runSummary(runId: "run", now: now).hiddenCharacters, 1_200,
                       "replayed projection describes the current upload, not a sum over model steps")
        IOSJevMetricsStore.append(IOSJevMetricsRecord(
            timestamp: now, useCase: .modelRouting, mode: .active, modelVersion: "jev-v1",
            outcome: "summary", latencyMs: 0, requestBytes: 0, responseBytes: 0,
            inputTokens: nil, outputTokens: nil, reason: nil,
            numbers: ["child_succeeded": 1]
        ))
        let finalSummaries = IOSJevMetricsStore.useCaseSummaries(now: now)
        XCTAssertEqual(finalSummaries.first(where: { $0.useCase == .toolDiscovery })?.exposureRatio, 0.8)
        XCTAssertEqual(finalSummaries.first(where: { $0.useCase == .toolDiscovery })?.newToolUseRate, 1)
        XCTAssertEqual(finalSummaries.first(where: { $0.useCase == .contextSelection })?.rereadAfterHideRate, 0.25)
        XCTAssertEqual(finalSummaries.first(where: { $0.useCase == .modelRouting })?.childSucceeded, 1)
    }

    func testMetricsDropRecordsOlderThanSevenDays() {
        IOSJevMetricsStore.clear()
        defer { IOSJevMetricsStore.clear() }
        let old = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        IOSJevMetricsStore.append(IOSJevMetricsRecord(
            timestamp: old, useCase: .memoryRecall, mode: .shadow, modelVersion: "jev-latest",
            outcome: "observed", latencyMs: 10, requestBytes: 10, responseBytes: 10,
            inputTokens: nil, outputTokens: nil, reason: nil
        ))
        XCTAssertTrue(IOSJevMetricsStore.load().isEmpty, "records older than 7 days must be dropped on load/append")
    }

    func testMetricsSummaryAggregates() {
        IOSJevMetricsStore.clear()
        defer { IOSJevMetricsStore.clear() }
        let now = Date()
        IOSJevMetricsStore.append(IOSJevMetricsRecord(
            timestamp: now, useCase: .toolDiscovery, mode: .active, modelVersion: "jev-fixed",
            outcome: "applied", latencyMs: 100, requestBytes: 500, responseBytes: 900,
            inputTokens: nil, outputTokens: nil, reason: nil
        ), now: now)
        IOSJevMetricsStore.append(IOSJevMetricsRecord(
            timestamp: now, useCase: .toolDiscovery, mode: .active, modelVersion: "jev-fixed",
            outcome: "error", latencyMs: 0, requestBytes: 0, responseBytes: 0,
            inputTokens: nil, outputTokens: nil, reason: "timeout"
        ), now: now)
        let summary = IOSJevMetricsStore.summary(now: now)
        // connection_test 不计入出站统计；error 计入回退口径。
        XCTAssertEqual(summary.todayRequests, 2)
        XCTAssertEqual(summary.todayRequestBytes, 500)
        XCTAssertEqual(summary.last24hApplied, 1)
        XCTAssertEqual(summary.last24hFallback, 1)
        XCTAssertEqual(summary.lastErrorReason, "timeout")
    }

    /// lastErrorReason 取最近一次 error/skipped 的原因码，晚到的 applied 不覆盖；
    /// 全成功时为 nil。
    func testMetricsSummaryLastErrorReason() {
        IOSJevMetricsStore.clear()
        defer { IOSJevMetricsStore.clear() }
        let now = Date()
        IOSJevMetricsStore.append(IOSJevMetricsRecord(
            timestamp: now.addingTimeInterval(-2), useCase: .webActions, mode: .active, modelVersion: "jev-fixed",
            outcome: "error", latencyMs: 10, requestBytes: 10, responseBytes: 0,
            inputTokens: nil, outputTokens: nil, reason: "http_400"
        ), now: now)
        IOSJevMetricsStore.append(IOSJevMetricsRecord(
            timestamp: now, useCase: .toolDiscovery, mode: .active, modelVersion: "jev-fixed",
            outcome: "applied", latencyMs: 10, requestBytes: 10, responseBytes: 10,
            inputTokens: nil, outputTokens: nil, reason: nil
        ), now: now)
        let summary = IOSJevMetricsStore.summary(now: now)
        XCTAssertEqual(summary.lastErrorReason, "http_400")
        XCTAssertEqual(summary.last24hApplied, 1)
        XCTAssertEqual(summary.last24hFallback, 1)
    }

    // MARK: 置信弃权线（A3）

    func testPolicyConfidenceFloorsDefaultsAndRoundTrip() throws {
        var policy = IOSJevPolicy()
        // 默认：四用途不门控；webActions 接管原循环内硬编码 0.5。
        XCTAssertNil(policy.toolDiscoveryMinConfidence)
        XCTAssertNil(policy.memoryRecallMinConfidence)
        XCTAssertNil(policy.contextSelectionMinConfidence)
        XCTAssertNil(policy.modelRoutingMinConfidence)
        XCTAssertEqual(policy.webActionsMinConfidence, 0.5)

        policy.toolDiscoveryMinConfidence = 0.7
        policy.memoryRecallMinConfidence = 0.6
        policy.contextSelectionMinConfidence = 0.65
        policy.modelRoutingMinConfidence = 0.75
        policy.webActionsMinConfidence = 0.8
        let decoded = try JSONDecoder().decode(IOSJevPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertEqual(decoded, policy)
    }

    func testPolicyLegacyDecodeWithoutConfidenceKeysUsesDefaults() throws {
        let legacy = """
        {"policyVersion":2,"toolDiscoveryMinScore":1.5}
        """
        let policy = try JSONDecoder().decode(IOSJevPolicy.self, from: Data(legacy.utf8))
        XCTAssertEqual(policy.toolDiscoveryMinScore, 1.5, "存量字段保留")
        XCTAssertNil(policy.toolDiscoveryMinConfidence)
        XCTAssertNil(policy.memoryRecallMinConfidence)
        XCTAssertNil(policy.contextSelectionMinConfidence)
        XCTAssertNil(policy.modelRoutingMinConfidence)
        XCTAssertEqual(policy.webActionsMinConfidence, 0.5)
    }

    func testMetricsRecordLegacyDecodeWithoutHeadlineFields() throws {
        // 旧指标记录（无 topConfidence/topScore）必须解码成功且新字段为 nil。
        let legacy = """
        {"timestamp":0,"useCase":"toolDiscovery","mode":"shadow","modelVersion":"jev-fixed-v1",
         "outcome":"observed","latencyMs":12,"requestBytes":100,"responseBytes":200}
        """
        let record = try JSONDecoder().decode(IOSJevMetricsRecord.self, from: Data(legacy.utf8))
        XCTAssertEqual(record.outcome, "observed")
        XCTAssertNil(record.topConfidence)
        XCTAssertNil(record.topScore)
        XCTAssertNil(record.suggestedTop1)
    }
}
