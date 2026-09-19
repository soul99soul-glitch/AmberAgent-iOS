import XCTest
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
        XCTAssertEqual(settings.vercelModel, "")
        XCTAssertEqual(settings.resolvedEndpoint, IOSJevSettings.productionEndpoint)
        XCTAssertEqual(settings.activeModelVersion, "jev-latest")
        XCTAssertTrue(settings.modelConfigured)
    }

    func testVercelStyleResolvesEndpointAndModel() {
        var settings = IOSJevSettings()
        settings.setAPIStyle(.vercelGateway)
        settings.setVercelModel("  openai/gpt-4o  ")
        XCTAssertEqual(settings.resolvedEndpoint, IOSJevSettings.vercelGatewayEndpoint)
        XCTAssertEqual(settings.vercelModel, "openai/gpt-4o", "slug 必须 trim")
        XCTAssertEqual(settings.activeModelVersion, "openai/gpt-4o")
        XCTAssertTrue(settings.modelConfigured)
    }

    /// 选 vercel 形态自动填默认 slug（typesafe-ai/jev）——用户只需配 Key；
    /// 已有自定义 slug 不被覆盖。
    func testVercelStyleSelectionPrefillsDefaultModel() {
        var settings = IOSJevSettings()
        settings.setAPIStyle(.vercelGateway)
        XCTAssertEqual(settings.vercelModel, IOSJevSettings.vercelDefaultModel)
        XCTAssertEqual(settings.activeModelVersion, "typesafe-ai/jev")
        // 显式改过的 slug 不因重选被覆盖。
        settings.setVercelModel("openai/gpt-5.6-luna")
        settings.setAPIStyle(.systemone)
        settings.setAPIStyle(.vercelGateway)
        XCTAssertEqual(settings.vercelModel, "openai/gpt-5.6-luna")
        // systemone 默认不填 vercel slug（无意义字段不污染存量配置）。
        XCTAssertEqual(IOSJevSettings().vercelModel, "")
    }

    func testVercelActiveRequiresConfiguredModel() {
        var settings = IOSJevSettings()
        settings.setAPIStyle(.vercelGateway)
        // 默认 slug 已自动填入，active 直接生效。
        settings.setMode(.active, for: .toolDiscovery)
        XCTAssertEqual(settings.effectiveMode(for: .toolDiscovery), .active)
        // 显式清空 slug：active 按 shadow 收口。
        settings.setVercelModel("")
        XCTAssertEqual(settings.effectiveMode(for: .toolDiscovery), .shadow)
        XCTAssertFalse(settings.modelConfigured)
        // 填 slug 即固定版本，active 生效（pinnedModelVersion 不参与 vercel 判定）。
        settings.setVercelModel("anthropic/claude-haiku-4.5")
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
        settings.setVercelModel("openai/gpt-4o")
        XCTAssertGreaterThan(settings.revision, r1)
    }

    func testAPIStyleRoundTripAndLegacyDecode() throws {
        var settings = IOSJevSettings()
        settings.setAPIStyle(.vercelGateway)
        settings.setVercelModel("openai/gpt-4o")
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
        XCTAssertEqual(decoded.vercelModel, "")
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
        settings.setVercelModel("openai/gpt-4o")
        store.updateJevSettings(settings)
        let reloaded2 = IOSSharedSettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded2.jevSettings.apiStyle, .vercelGateway)
        XCTAssertEqual(reloaded2.jevSettings.vercelModel, "openai/gpt-4o")

        // 固定模型版本经 store 持久化闭环（runtime effectiveMode 消费）。
        settings.setPinnedModelVersion("jev-2026-09-15")
        store.updateJevSettings(settings)
        let reloaded3 = IOSSharedSettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded3.jevSettings.pinnedModelVersion, "jev-2026-09-15")
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
}
