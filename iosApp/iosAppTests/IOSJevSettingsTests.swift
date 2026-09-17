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
    }
}
