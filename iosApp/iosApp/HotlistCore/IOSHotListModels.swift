import Foundation

struct IOSHotlistItem: Codable, Equatable, Sendable {
    var providerId: String
    var title: String
    var url: String?
    var rank: Int
    var score: Int?
    var fetchedAt: Int64
    var displayTitle: String? = nil
    var heat: String? = nil
    var category: String? = nil

    var presentationTitle: String {
        (displayTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).hotListIfEmpty(title)
    }
}

protocol IOSHotlistProvider: Sendable {
    var providerId: String { get }
    var displayName: String { get }
    func fetch(limit: Int) async throws -> [IOSHotlistItem]
}

struct IOSHotTopicSource: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(providerId)|\(rank)|\(title)" }
    var providerId: String
    var providerName: String
    var rank: Int
    var title: String
    var displayTitle: String?
    var url: String?
    var heat: String?
    var fetchedAt: Int64

    var presentationTitle: String {
        (displayTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).hotListIfEmpty(title)
    }
}

struct IOSHotTopic: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var sources: [IOSHotTopicSource]
    var sourceCount: Int
    var bestRank: Int
    var latestFetchedAt: Int64
}

struct IOSHotListProviderSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: String { providerId }
    var providerId: String
    var providerName: String
    var items: [IOSHotlistItem]
    var fetchedAt: Int64
    var stale: Bool
    var error: String?

    init(
        providerId: String,
        providerName: String,
        items: [IOSHotlistItem],
        fetchedAt: Int64,
        stale: Bool = false,
        error: String? = nil
    ) {
        self.providerId = providerId
        self.providerName = providerName
        self.items = items
        self.fetchedAt = fetchedAt
        self.stale = stale
        self.error = error
    }
}

struct IOSHotListDashboard: Codable, Equatable, Sendable {
    var topics: [IOSHotTopic]
    var providers: [IOSHotListProviderSnapshot]
    var lastUpdatedAt: Int64
    var enabledSourceCount: Int

    static let empty = IOSHotListDashboard(topics: [], providers: [], lastUpdatedAt: 0, enabledSourceCount: 0)

    var hasContent: Bool {
        !topics.isEmpty || providers.contains { !$0.items.isEmpty }
    }

    var hasEnabledSources: Bool {
        enabledSourceCount > 0
    }

    var hasErrors: Bool {
        providers.contains { ($0.error ?? "").isEmpty == false }
    }
}

