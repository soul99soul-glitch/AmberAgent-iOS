import Foundation
import XCTest
@testable import iosApp

private enum FakeStoreError: Error {
    case offline
}

@MainActor
private final class FakeStoreKitService: IOSStoreKitServicing {
    var products = [
        IOSStoreProductDisplay(
            id: "app.amber.ios.pro.monthly",
            displayName: "Amber Pro 月度",
            description: "Monthly",
            displayPrice: "¥18.00",
            periodLabel: "每月"
        )
    ]
    var current = IOSSubscriptionSnapshot.none(at: Date(timeIntervalSince1970: 100))
    var purchaseResult: IOSStorePurchaseResult = .cancelled
    var restoreResult = IOSSubscriptionSnapshot.none(at: Date(timeIntervalSince1970: 100))
    var loadError: Error?
    var refreshError: Error?
    private(set) var purchaseProductIDs: [String] = []
    private(set) var restoreCallCount = 0
    private(set) var finishedTransactionIDs: [UInt64] = []
    private var updateContinuation: AsyncStream<IOSStoreTransactionUpdate>.Continuation?

    func loadProducts() async throws -> [IOSStoreProductDisplay] {
        if let loadError { throw loadError }
        return products
    }

    func purchase(
        productID: String,
        onVerified: (IOSSubscriptionSnapshot) -> Void
    ) async throws -> IOSStorePurchaseResult {
        purchaseProductIDs.append(productID)
        if case .purchased(let snapshot) = purchaseResult {
            onVerified(snapshot)
            finishedTransactionIDs.append(0)
        }
        return purchaseResult
    }

    func restore() async throws -> IOSSubscriptionSnapshot {
        restoreCallCount += 1
        return restoreResult
    }

    func currentEntitlement() async throws -> IOSSubscriptionSnapshot {
        if let refreshError { throw refreshError }
        return current
    }

    func transactionUpdates() -> AsyncStream<IOSStoreTransactionUpdate> {
        AsyncStream { continuation in
            updateContinuation = continuation
        }
    }

    func emitUpdate(id: UInt64 = 1) {
        updateContinuation?.yield(IOSStoreTransactionUpdate(id: id) { [weak self] in
            self?.finishedTransactionIDs.append(id)
        })
    }
}

private final class MemoryStoreEntitlementCache: IOSStoreEntitlementCaching {
    var snapshot: IOSSubscriptionSnapshot?
    private(set) var saved: [IOSSubscriptionSnapshot] = []

    init(snapshot: IOSSubscriptionSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func load() -> IOSSubscriptionSnapshot? { snapshot }

    func save(_ snapshot: IOSSubscriptionSnapshot) {
        self.snapshot = snapshot
        saved.append(snapshot)
    }
}

@MainActor
final class IOSStoreKitTests: XCTestCase {
    private let monthlyID = "app.amber.ios.pro.monthly"
    private let now = Date(timeIntervalSince1970: 1_000)

    func testVerifiedPurchaseActivatesAndCachesEntitlement() async {
        let service = FakeStoreKitService()
        let cache = MemoryStoreEntitlementCache()
        let active = snapshot(.active(productID: monthlyID, expirationDate: now.addingTimeInterval(3_600)))
        service.purchaseResult = .purchased(active)
        let coordinator = IOSStoreCoordinator(service: service, cache: cache, now: { self.now })

        await coordinator.purchase(productID: monthlyID)

        XCTAssertEqual(service.purchaseProductIDs, [monthlyID])
        XCTAssertEqual(coordinator.entitlement.state, active.state)
        XCTAssertEqual(coordinator.purchaseResult, .purchased(active))
        XCTAssertEqual(cache.saved.last?.state, active.state)
        XCTAssertEqual(service.finishedTransactionIDs, [0])
    }

    func testCancelledPurchaseKeepsExistingEntitlement() async {
        let service = FakeStoreKitService()
        let cache = MemoryStoreEntitlementCache()
        let existing = snapshot(.active(productID: monthlyID, expirationDate: now.addingTimeInterval(3_600)))
        cache.snapshot = existing
        service.purchaseResult = .cancelled
        let coordinator = IOSStoreCoordinator(service: service, cache: cache, now: { self.now })

        await coordinator.purchase(productID: monthlyID)

        XCTAssertEqual(coordinator.purchaseResult, .cancelled)
        XCTAssertEqual(coordinator.entitlement.state, existing.state)
        XCTAssertEqual(coordinator.message, "购买已取消，没有产生扣款。")
    }

    func testPendingPurchaseWaitsForTransactionUpdate() async {
        let service = FakeStoreKitService()
        service.purchaseResult = .pending
        let coordinator = IOSStoreCoordinator(service: service, cache: MemoryStoreEntitlementCache(), now: { self.now })

        await coordinator.purchase(productID: monthlyID)

        XCTAssertEqual(coordinator.purchaseResult, .pending)
        XCTAssertEqual(coordinator.entitlement.state, .none)
        XCTAssertTrue(coordinator.message?.contains("等待批准") == true)
    }

    func testExplicitRestoreRefreshesEntitlementWithoutAccountDependency() async {
        let service = FakeStoreKitService()
        let restored = snapshot(.active(productID: monthlyID, expirationDate: now.addingTimeInterval(7_200)))
        service.restoreResult = restored
        let coordinator = IOSStoreCoordinator(service: service, cache: MemoryStoreEntitlementCache(), now: { self.now })

        await coordinator.restore()

        XCTAssertEqual(service.restoreCallCount, 1)
        XCTAssertEqual(coordinator.entitlement.state, restored.state)
        XCTAssertEqual(coordinator.message, "购买记录已恢复。")
    }

    func testRefreshPreservesRevokedAndExpiredStates() async {
        let service = FakeStoreKitService()
        let coordinator = IOSStoreCoordinator(service: service, cache: MemoryStoreEntitlementCache(), now: { self.now })

        service.current = snapshot(.revoked(productID: monthlyID, revocationDate: now))
        await coordinator.refresh()
        XCTAssertEqual(coordinator.entitlement.state, service.current.state)
        XCTAssertFalse(coordinator.entitlement.state.grantsPremiumAccess)

        service.current = snapshot(.expired(productID: monthlyID, expirationDate: now))
        await coordinator.refresh()
        XCTAssertEqual(coordinator.entitlement.state, service.current.state)
        XCTAssertFalse(coordinator.entitlement.state.grantsPremiumAccess)
    }

    func testGracePeriodGrantsAccessButBillingRetryDoesNot() async {
        let service = FakeStoreKitService()
        let coordinator = IOSStoreCoordinator(service: service, cache: MemoryStoreEntitlementCache(), now: { self.now })

        service.current = snapshot(.gracePeriod(productID: monthlyID, expirationDate: now.addingTimeInterval(600)))
        await coordinator.refresh()
        XCTAssertTrue(coordinator.entitlement.state.grantsPremiumAccess)

        service.current = snapshot(.billingRetry(productID: monthlyID, expirationDate: now))
        await coordinator.refresh()
        XCTAssertFalse(coordinator.entitlement.state.grantsPremiumAccess)
    }

    func testOfflineRefreshUsesCachedEntitlementAndExpiresStaleAccess() async {
        let cached = snapshot(.active(productID: monthlyID, expirationDate: now.addingTimeInterval(600)))
        let cache = MemoryStoreEntitlementCache(snapshot: cached)
        let service = FakeStoreKitService()
        service.loadError = FakeStoreError.offline
        let coordinator = IOSStoreCoordinator(service: service, cache: cache, now: { self.now })

        await coordinator.start()
        defer { coordinator.stop() }

        XCTAssertEqual(coordinator.entitlement.state, cached.state)
        XCTAssertTrue(coordinator.entitlement.isFromCache)
        XCTAssertTrue(coordinator.message?.contains("本机缓存") == true)

        let stale = snapshot(.active(productID: monthlyID, expirationDate: now.addingTimeInterval(-1)))
        let staleCoordinator = IOSStoreCoordinator(
            service: service,
            cache: MemoryStoreEntitlementCache(snapshot: stale),
            now: { self.now }
        )
        XCTAssertEqual(
            staleCoordinator.entitlement.state,
            .expired(productID: monthlyID, expirationDate: now.addingTimeInterval(-1))
        )
    }

    func testPremiumAccessExpiresAgainstCurrentTimeWithoutWaitingForNetwork() {
        var currentTime = now
        let active = snapshot(.active(productID: monthlyID, expirationDate: now.addingTimeInterval(600)))
        let coordinator = IOSStoreCoordinator(
            service: FakeStoreKitService(),
            cache: MemoryStoreEntitlementCache(snapshot: active),
            now: { currentTime }
        )

        XCTAssertTrue(coordinator.hasPremiumAccess)
        currentTime = now.addingTimeInterval(601)
        XCTAssertFalse(coordinator.hasPremiumAccess)
    }

    func testPurchasesRequirePublicHTTPSPolicyLinks() {
        let missingPrivacy = IOSStorePolicyLinks(
            privacyPolicyURL: nil,
            termsOfUseURL: IOSStorePolicyLinks.appleStandardTermsURL
        )
        XCTAssertFalse(missingPrivacy.allowsPurchases)

        let insecurePrivacy = IOSStorePolicyLinks(
            privacyPolicyURL: URL(string: "http://example.com/privacy"),
            termsOfUseURL: IOSStorePolicyLinks.appleStandardTermsURL
        )
        XCTAssertFalse(insecurePrivacy.allowsPurchases)
        XCTAssertNil(insecurePrivacy.publicPrivacyPolicyURL)

        let insecureTerms = IOSStorePolicyLinks(
            privacyPolicyURL: URL(string: "https://example.com/privacy"),
            termsOfUseURL: URL(string: "http://example.com/terms")
        )
        XCTAssertFalse(insecureTerms.allowsPurchases)
        XCTAssertNil(insecureTerms.publicTermsOfUseURL)

        let complete = IOSStorePolicyLinks(
            privacyPolicyURL: URL(string: "https://example.com/privacy"),
            termsOfUseURL: IOSStorePolicyLinks.appleStandardTermsURL
        )
        XCTAssertTrue(complete.allowsPurchases)
    }

    func testTransactionUpdateRefreshesEntitlement() async {
        let service = FakeStoreKitService()
        let coordinator = IOSStoreCoordinator(service: service, cache: MemoryStoreEntitlementCache(), now: { self.now })
        await coordinator.start()
        service.current = snapshot(.active(productID: monthlyID, expirationDate: now.addingTimeInterval(600)))

        service.emitUpdate()
        for _ in 0..<20 where coordinator.entitlement.state != service.current.state {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.entitlement.state, service.current.state)
        XCTAssertEqual(service.finishedTransactionIDs, [1])
        coordinator.stop()
    }

    func testTransactionUpdateIsNotFinishedUntilEntitlementRefreshSucceeds() async {
        let service = FakeStoreKitService()
        let coordinator = IOSStoreCoordinator(
            service: service,
            cache: MemoryStoreEntitlementCache(),
            now: { self.now }
        )
        await coordinator.start()
        defer { coordinator.stop() }
        service.current = snapshot(.active(productID: monthlyID, expirationDate: now.addingTimeInterval(600)))
        service.refreshError = FakeStoreError.offline

        service.emitUpdate(id: 7)
        for _ in 0..<20 where coordinator.message == nil {
            await Task.yield()
        }
        XCTAssertTrue(service.finishedTransactionIDs.isEmpty)

        service.refreshError = nil
        await coordinator.refresh()

        XCTAssertEqual(coordinator.entitlement.state, service.current.state)
        XCTAssertEqual(service.finishedTransactionIDs, [7])
    }

    func testCatalogAndLocalStoreKitConfigurationStayAligned() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent()
        let configURL = appDirectory.appendingPathComponent("iosApp/AmberSubscriptions.storekit")
        let projectURL = appDirectory.appendingPathComponent("project.yml")
        let configData = try Data(contentsOf: configURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: configData) as? [String: Any])
        let groups = try XCTUnwrap(object["subscriptionGroups"] as? [[String: Any]])
        let subscriptions = groups.flatMap { $0["subscriptions"] as? [[String: Any]] ?? [] }
        let configuredIDs = Set(subscriptions.compactMap { $0["productID"] as? String })
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        XCTAssertEqual(configuredIDs, Set(IOSStoreProductCatalog.amberPro.productIDs))
        XCTAssertTrue(project.contains("storeKitConfiguration: iosApp/AmberSubscriptions.storekit"))
    }

    func testAppOwnsTransactionListenerAndSharesEntitlementWithConsumers() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent()
        let shell = try String(
            contentsOf: appDirectory.appendingPathComponent("iosApp/AppShell.swift"),
            encoding: .utf8
        )
        let subscription = try String(
            contentsOf: appDirectory.appendingPathComponent("iosApp/IOSSubscriptionView.swift"),
            encoding: .utf8
        )
        let sync = try String(
            contentsOf: appDirectory.appendingPathComponent("iosApp/SyncBackupView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(shell.contains(".task { await storeCoordinator.start() }"))
        XCTAssertTrue(shell.contains("Task { await storeCoordinator.refresh() }"))
        XCTAssertTrue(shell.contains("IOSSubscriptionView(store: storeCoordinator)"))
        XCTAssertTrue(shell.contains("store: storeCoordinator"))
        XCTAssertFalse(subscription.contains("store.stop()"))
        XCTAssertFalse(sync.contains("store.stop()"))
    }

    func testCloudKitEncryptedBackupConsumesPremiumEntitlementWithoutGatingOtherProviders() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent()
        let sync = try String(
            contentsOf: appDirectory.appendingPathComponent("iosApp/SyncBackupView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(sync.contains("store.hasPremiumAccess"))
        XCTAssertTrue(sync.contains("? [.localFolder, .cloudKit, .webDAV]"))
        XCTAssertTrue(sync.contains(": [.localFolder, .webDAV]"))
        XCTAssertTrue(sync.contains("iCloud 加密跨设备备份需要有效的 Amber Pro 订阅"))
    }

    func testSubscriptionPurchaseFailsClosedUntilPolicyLinksAreConfigured() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent()
        let subscription = try String(
            contentsOf: appDirectory.appendingPathComponent("iosApp/IOSSubscriptionView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(subscription.contains("!policyLinks.allowsPurchases"))
        XCTAssertTrue(subscription.contains("Label(\"隐私政策\""))
        XCTAssertTrue(subscription.contains("Label(\"使用条款\""))
        XCTAssertTrue(subscription.contains("恢复购买仍可使用"))
    }

    private func snapshot(_ state: IOSSubscriptionEntitlementState) -> IOSSubscriptionSnapshot {
        IOSSubscriptionSnapshot(state: state, checkedAt: now, isFromCache: false)
    }
}
