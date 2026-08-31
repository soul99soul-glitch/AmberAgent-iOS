import Foundation
import Observation
@preconcurrency import StoreKit

struct IOSStoreProductDefinition: Equatable, Sendable {
    let id: String
    let fallbackName: String
    let fallbackDescription: String
}

struct IOSStoreProductCatalog: Equatable, Sendable {
    let products: [IOSStoreProductDefinition]

    static let amberPro = IOSStoreProductCatalog(products: [
        IOSStoreProductDefinition(
            id: "app.amber.ios.pro.monthly",
            fallbackName: "Amber Pro 月度",
            fallbackDescription: "解锁 iCloud 私有数据库中的加密跨设备备份。"
        ),
        IOSStoreProductDefinition(
            id: "app.amber.ios.pro.yearly",
            fallbackName: "Amber Pro 年度",
            fallbackDescription: "解锁 iCloud 私有数据库中的加密跨设备备份。"
        )
    ])

    var productIDs: [String] { products.map(\.id) }
}

struct IOSStoreProductDisplay: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let description: String
    let displayPrice: String
    let periodLabel: String
}

struct IOSStorePolicyLinks: Equatable, Sendable {
    static let appleStandardTermsURL = URL(
        string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
    )!

    let privacyPolicyURL: URL?
    let termsOfUseURL: URL?

    var publicPrivacyPolicyURL: URL? {
        Self.isPublicHTTPS(privacyPolicyURL) ? privacyPolicyURL : nil
    }

    var publicTermsOfUseURL: URL? {
        Self.isPublicHTTPS(termsOfUseURL) ? termsOfUseURL : nil
    }

    var allowsPurchases: Bool {
        publicPrivacyPolicyURL != nil && publicTermsOfUseURL != nil
    }

    static func configured(bundle: Bundle = .main) -> Self {
        let privacy = url(for: "AmberPrivacyPolicyURL", bundle: bundle)
        let configuredTerms = url(for: "AmberTermsOfUseURL", bundle: bundle)
        return Self(
            privacyPolicyURL: privacy,
            termsOfUseURL: isPublicHTTPS(configuredTerms) ? configuredTerms : appleStandardTermsURL
        )
    }

    private static func url(for key: String, bundle: Bundle) -> URL? {
        guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
        return URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isPublicHTTPS(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
    }
}

enum IOSSubscriptionEntitlementState: Codable, Equatable, Sendable {
    case none
    case active(productID: String, expirationDate: Date?)
    case gracePeriod(productID: String, expirationDate: Date?)
    case billingRetry(productID: String, expirationDate: Date?)
    case expired(productID: String, expirationDate: Date?)
    case revoked(productID: String, revocationDate: Date?)

    var grantsPremiumAccess: Bool {
        switch self {
        case .active, .gracePeriod: true
        case .none, .billingRetry, .expired, .revoked: false
        }
    }

    var productID: String? {
        switch self {
        case .none: nil
        case .active(let productID, _),
             .gracePeriod(let productID, _),
             .billingRetry(let productID, _),
             .expired(let productID, _),
             .revoked(let productID, _): productID
        }
    }
}

struct IOSSubscriptionSnapshot: Codable, Equatable, Sendable {
    let state: IOSSubscriptionEntitlementState
    let checkedAt: Date
    let isFromCache: Bool

    static func none(at date: Date = Date()) -> Self {
        Self(state: .none, checkedAt: date, isFromCache: false)
    }

    func cached(now: Date) -> Self {
        Self(state: normalizedState(now: now), checkedAt: checkedAt, isFromCache: true)
    }

    func grantsPremiumAccess(at date: Date) -> Bool {
        normalizedState(now: date).grantsPremiumAccess
    }

    var premiumAccessExpirationDate: Date? {
        switch state {
        case .active(_, let expirationDate), .gracePeriod(_, let expirationDate):
            expirationDate
        case .none, .billingRetry, .expired, .revoked:
            nil
        }
    }

    private func normalizedState(now: Date) -> IOSSubscriptionEntitlementState {
        switch state {
        case .active(let productID, let expirationDate):
            guard let expirationDate, expirationDate <= now else { return state }
            return .expired(productID: productID, expirationDate: expirationDate)
        case .gracePeriod(let productID, let expirationDate):
            guard let expirationDate, expirationDate <= now else { return state }
            return .expired(productID: productID, expirationDate: expirationDate)
        case .none, .billingRetry, .expired, .revoked:
            return state
        }
    }
}

enum IOSStorePurchaseResult: Equatable, Sendable {
    case purchased(IOSSubscriptionSnapshot)
    case cancelled
    case pending
}

struct IOSStoreTransactionUpdate: Equatable, Sendable {
    let id: UInt64
    private let finishAction: @MainActor @Sendable () async -> Void

    init(id: UInt64, finish: @escaping @MainActor @Sendable () async -> Void) {
        self.id = id
        self.finishAction = finish
    }

    @MainActor
    func finish() async {
        await finishAction()
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

enum IOSStoreOperationState: Equatable {
    case idle
    case loading
    case purchasing(productID: String)
    case restoring
}

enum IOSStoreKitError: LocalizedError, Equatable {
    case productUnavailable
    case unverifiedTransaction
    case unsupportedPurchaseResult

    var errorDescription: String? {
        switch self {
        case .productUnavailable: "App Store 暂未返回这个订阅产品。"
        case .unverifiedTransaction: "StoreKit 无法在本机验证这笔交易。"
        case .unsupportedPurchaseResult: "StoreKit 返回了暂不支持的购买结果。"
        }
    }
}

@MainActor
protocol IOSStoreKitServicing: AnyObject {
    func loadProducts() async throws -> [IOSStoreProductDisplay]
    func purchase(
        productID: String,
        onVerified: (IOSSubscriptionSnapshot) -> Void
    ) async throws -> IOSStorePurchaseResult
    func restore() async throws -> IOSSubscriptionSnapshot
    func currentEntitlement() async throws -> IOSSubscriptionSnapshot
    func transactionUpdates() -> AsyncStream<IOSStoreTransactionUpdate>
}

@MainActor
final class IOSStoreKitService: IOSStoreKitServicing {
    private let catalog: IOSStoreProductCatalog
    private let now: () -> Date
    private var storeProducts: [String: Product] = [:]

    init(catalog: IOSStoreProductCatalog = .amberPro, now: @escaping () -> Date = Date.init) {
        self.catalog = catalog
        self.now = now
    }

    func loadProducts() async throws -> [IOSStoreProductDisplay] {
        let products = try await Product.products(for: catalog.productIDs)
        storeProducts = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        let order = Dictionary(uniqueKeysWithValues: catalog.productIDs.enumerated().map { ($1, $0) })
        return products
            .map { product in
                IOSStoreProductDisplay(
                    id: product.id,
                    displayName: product.displayName,
                    description: product.description,
                    displayPrice: product.displayPrice,
                    periodLabel: Self.periodLabel(product.subscription?.subscriptionPeriod)
                )
            }
            .sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }

    func purchase(
        productID: String,
        onVerified: (IOSSubscriptionSnapshot) -> Void
    ) async throws -> IOSStorePurchaseResult {
        if storeProducts[productID] == nil {
            _ = try await loadProducts()
        }
        guard let product = storeProducts[productID] else {
            throw IOSStoreKitError.productUnavailable
        }
        switch try await product.purchase() {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw IOSStoreKitError.unverifiedTransaction
            }
            let snapshot = try await currentEntitlement()
            onVerified(snapshot)
            await transaction.finish()
            return .purchased(snapshot)
        case .userCancelled:
            return .cancelled
        case .pending:
            return .pending
        @unknown default:
            throw IOSStoreKitError.unsupportedPurchaseResult
        }
    }

    func restore() async throws -> IOSSubscriptionSnapshot {
        try await AppStore.sync()
        return try await currentEntitlement()
    }

    func currentEntitlement() async throws -> IOSSubscriptionSnapshot {
        if storeProducts.isEmpty {
            _ = try await loadProducts()
        }

        var currentTransactions: [String: Transaction] = [:]
        var sawUnverified = false
        for await verification in Transaction.currentEntitlements {
            switch verification {
            case .verified(let transaction) where catalog.productIDs.contains(transaction.productID):
                currentTransactions[transaction.productID] = transaction
            case .unverified(let transaction, _) where catalog.productIDs.contains(transaction.productID):
                sawUnverified = true
            default:
                break
            }
        }

        var candidates: [IOSSubscriptionEntitlementState] = []
        do {
            for product in storeProducts.values {
                guard let subscription = product.subscription else { continue }
                for status in try await subscription.status {
                    guard case .verified(let transaction) = status.transaction,
                          catalog.productIDs.contains(transaction.productID) else {
                        if case .unverified = status.transaction { sawUnverified = true }
                        continue
                    }
                    let expiration = transaction.expirationDate
                    switch status.state {
                    case .subscribed:
                        candidates.append(.active(productID: transaction.productID, expirationDate: expiration))
                    case .inGracePeriod:
                        let graceExpiration: Date?
                        if case .verified(let renewalInfo) = status.renewalInfo {
                            graceExpiration = renewalInfo.gracePeriodExpirationDate ?? expiration
                        } else {
                            graceExpiration = expiration
                        }
                        candidates.append(.gracePeriod(productID: transaction.productID, expirationDate: graceExpiration))
                    case .inBillingRetryPeriod:
                        candidates.append(.billingRetry(productID: transaction.productID, expirationDate: expiration))
                    case .expired:
                        candidates.append(.expired(productID: transaction.productID, expirationDate: expiration))
                    case .revoked:
                        candidates.append(.revoked(productID: transaction.productID, revocationDate: transaction.revocationDate))
                    default:
                        break
                    }
                }
            }
        } catch {
            if currentTransactions.isEmpty { throw error }
        }

        for transaction in currentTransactions.values where !candidates.contains(where: { $0.productID == transaction.productID }) {
            candidates.append(.active(productID: transaction.productID, expirationDate: transaction.expirationDate))
        }
        if candidates.isEmpty, sawUnverified {
            throw IOSStoreKitError.unverifiedTransaction
        }
        let state = candidates.max(by: { Self.priority($0) < Self.priority($1) }) ?? .none
        return IOSSubscriptionSnapshot(state: state, checkedAt: now(), isFromCache: false)
    }

    func transactionUpdates() -> AsyncStream<IOSStoreTransactionUpdate> {
        let productIDs = Set(catalog.productIDs)
        return AsyncStream { continuation in
            let task = Task {
                for await verification in Transaction.updates {
                    guard !Task.isCancelled else { break }
                    guard case .verified(let transaction) = verification,
                          productIDs.contains(transaction.productID) else { continue }
                    continuation.yield(IOSStoreTransactionUpdate(id: transaction.id) {
                        await transaction.finish()
                    })
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func priority(_ state: IOSSubscriptionEntitlementState) -> Int {
        switch state {
        case .active: 5
        case .gracePeriod: 4
        case .billingRetry: 3
        case .revoked: 2
        case .expired: 1
        case .none: 0
        }
    }

    private static func periodLabel(_ period: Product.SubscriptionPeriod?) -> String {
        guard let period else { return "" }
        let value = period.value
        switch period.unit {
        case .day: return value == 1 ? "每天" : "每 \(value) 天"
        case .week: return value == 1 ? "每周" : "每 \(value) 周"
        case .month: return value == 1 ? "每月" : "每 \(value) 个月"
        case .year: return value == 1 ? "每年" : "每 \(value) 年"
        @unknown default: return ""
        }
    }
}

protocol IOSStoreEntitlementCaching: AnyObject {
    func load() -> IOSSubscriptionSnapshot?
    func save(_ snapshot: IOSSubscriptionSnapshot)
}

final class IOSUserDefaultsStoreEntitlementCache: IOSStoreEntitlementCaching {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "app.amber.ios.storekit.entitlement") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> IOSSubscriptionSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(IOSSubscriptionSnapshot.self, from: data)
    }

    func save(_ snapshot: IOSSubscriptionSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
@Observable
final class IOSStoreCoordinator {
    private(set) var products: [IOSStoreProductDisplay] = []
    private(set) var entitlement: IOSSubscriptionSnapshot
    private(set) var operation: IOSStoreOperationState = .idle
    private(set) var purchaseResult: IOSStorePurchaseResult?
    private(set) var message: String?

    @ObservationIgnored private let service: any IOSStoreKitServicing
    @ObservationIgnored private let cache: any IOSStoreEntitlementCaching
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var expirationTask: Task<Void, Never>?
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var pendingTransactionUpdates: [UInt64: IOSStoreTransactionUpdate] = [:]

    var hasPremiumAccess: Bool {
        entitlement.grantsPremiumAccess(at: now())
    }

    init(
        service: (any IOSStoreKitServicing)? = nil,
        cache: any IOSStoreEntitlementCaching = IOSUserDefaultsStoreEntitlementCache(),
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service ?? IOSStoreKitService(now: now)
        self.cache = cache
        self.now = now
        self.entitlement = cache.load()?.cached(now: now()) ?? .none(at: now())
        scheduleExpirationNormalization()
    }

    func start() async {
        startListeningForTransactions()
        await refresh()
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        expirationTask?.cancel()
        expirationTask = nil
    }

    func refresh() async {
        guard !isRefreshing, operation == .idle else { return }
        isRefreshing = true
        operation = .loading
        message = nil
        defer {
            operation = .idle
            isRefreshing = false
        }
        do {
            products = try await service.loadProducts()
            apply(try await service.currentEntitlement())
            await finishPendingTransactions()
        } catch {
            if let cached = cache.load()?.cached(now: now()) {
                entitlement = cached
                scheduleExpirationNormalization()
                message = "暂时无法连接 App Store，正在使用本机缓存的订阅状态。"
            } else {
                message = error.localizedDescription
            }
        }
    }

    func purchase(productID: String) async {
        guard operation == .idle else { return }
        operation = .purchasing(productID: productID)
        purchaseResult = nil
        message = nil
        do {
            let result = try await service.purchase(productID: productID) { snapshot in
                self.apply(snapshot)
            }
            purchaseResult = result
            switch result {
            case .purchased:
                message = "购买已完成，订阅状态已更新。"
            case .cancelled:
                message = "购买已取消，没有产生扣款。"
            case .pending:
                message = "购买正在等待批准或付款确认；完成后会自动更新。"
            }
        } catch {
            message = error.localizedDescription
        }
        operation = .idle
    }

    func restore() async {
        guard operation == .idle else { return }
        operation = .restoring
        purchaseResult = nil
        message = nil
        do {
            let snapshot = try await service.restore()
            apply(snapshot)
            message = snapshot.state == .none ? "没有找到可恢复的购买。" : "购买记录已恢复。"
        } catch {
            message = error.localizedDescription
        }
        operation = .idle
    }

    private func startListeningForTransactions() {
        guard updatesTask == nil else { return }
        let updates = service.transactionUpdates()
        updatesTask = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled, let self else { return }
                self.pendingTransactionUpdates[update.id] = update
                do {
                    self.apply(try await self.service.currentEntitlement())
                    await self.finishPendingTransactions()
                    self.message = "App Store 已更新订阅状态。"
                } catch {
                    self.message = error.localizedDescription
                }
            }
        }
    }

    private func apply(_ snapshot: IOSSubscriptionSnapshot) {
        let fresh = IOSSubscriptionSnapshot(
            state: snapshot.state,
            checkedAt: snapshot.checkedAt,
            isFromCache: false
        )
        entitlement = fresh
        cache.save(fresh)
        scheduleExpirationNormalization()
    }

    private func scheduleExpirationNormalization() {
        expirationTask?.cancel()
        expirationTask = nil
        guard let expirationDate = entitlement.premiumAccessExpirationDate else { return }
        let delay = expirationDate.timeIntervalSince(now())
        guard delay > 0 else {
            normalizeExpiredEntitlement()
            return
        }
        expirationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.normalizeExpiredEntitlement()
        }
    }

    private func normalizeExpiredEntitlement() {
        guard !entitlement.grantsPremiumAccess(at: now()), entitlement.state.grantsPremiumAccess else { return }
        let normalized = entitlement.cached(now: now())
        let fresh = IOSSubscriptionSnapshot(
            state: normalized.state,
            checkedAt: entitlement.checkedAt,
            isFromCache: entitlement.isFromCache
        )
        entitlement = fresh
        cache.save(fresh)
        expirationTask = nil
    }

    private func finishPendingTransactions() async {
        let updates = Array(pendingTransactionUpdates.values)
        pendingTransactionUpdates.removeAll()
        for update in updates {
            await update.finish()
        }
    }
}
