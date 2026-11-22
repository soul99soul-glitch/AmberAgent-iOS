import Foundation

/// Payload passed from the iOS Share Extension into the Amber main timeline via App Group storage.
struct AmberSharePayload: Codable, Equatable, Sendable {
    static let maxPrefillLength = 4_000
    static let expirationSeconds: TimeInterval = 30 * 60

    var id: String
    var title: String?
    var text: String?
    var urlString: String?
    var createdAt: Date

    init(
        id: String = UUID().uuidString.lowercased(),
        title: String? = nil,
        text: String? = nil,
        urlString: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.urlString = urlString?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
    }

    var formattedPrefillText: String? {
        var parts: [String] = []
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanURL = urlString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !cleanTitle.isEmpty, cleanTitle != cleanText, cleanTitle != cleanURL {
            parts.append(cleanTitle)
        }
        if !cleanText.isEmpty {
            parts.append(cleanText)
        }
        if !cleanURL.isEmpty, !cleanText.contains(cleanURL) {
            parts.append(cleanURL)
        }

        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        if joined.count > Self.maxPrefillLength {
            return String(joined.prefix(Self.maxPrefillLength))
        }
        return joined
    }

    static func mergeIntoDraft(existingDraft: String, incoming: String) -> String {
        let cleanIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanIncoming.isEmpty else { return existingDraft }
        let trimmedExisting = existingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedExisting.isEmpty {
            return cleanIncoming
        }
        return "\(trimmedExisting)\n\n\(cleanIncoming)"
    }
}

/// Shared App Group handoff store used by `AmberShareExtension` and `iosApp`.
final class AmberShareHandoffStore: @unchecked Sendable {
    static let storageKey = "app.amber.ios.shareHandoff.pendingPayloads.v1"
    static let maxRetainedPayloads = 8

    static let shared = AmberShareHandoffStore(
        defaults: UserDefaults(suiteName: resolvedAppGroupIdentifier(forBundleIdentifier: Bundle.main.bundleIdentifier))
            ?? .standard
    )

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    static func resolvedAppGroupIdentifier(forBundleIdentifier bundleIdentifier: String?) -> String {
        let bundleId = bundleIdentifier ?? ""
        if bundleId.contains(".experimental-gpl") {
            return "group.app.amber.ios.experimental-gpl.watchkit"
        }
        return "group.app.amber.ios.watchkit"
    }

    static func resolvedURLScheme(forBundleIdentifier bundleIdentifier: String?) -> String {
        let bundleId = bundleIdentifier ?? ""
        if bundleId.contains(".experimental-gpl") {
            return "amber-experimental"
        }
        return "amber"
    }

    static func shareDeepLinkURL(
        for handoffID: String,
        scheme: String = resolvedURLScheme(forBundleIdentifier: Bundle.main.bundleIdentifier)
    ) -> URL? {
        guard !handoffID.isEmpty, handoffID.count <= 64 else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "share"
        components.path = "/\(handoffID)"
        return components.url
    }

    @discardableResult
    func save(_ payload: AmberSharePayload, now: Date = Date()) -> Bool {
        guard payload.formattedPrefillText != nil else { return false }
        return lock.withLock {
            var items = loadAllLocked(now: now)
            items.removeAll { $0.id.caseInsensitiveCompare(payload.id) == .orderedSame }
            items.append(payload)
            if items.count > Self.maxRetainedPayloads {
                items = Array(items.suffix(Self.maxRetainedPayloads))
            }
            return persistLocked(items)
        }
    }

    func consume(id: String, now: Date = Date()) -> AmberSharePayload? {
        lock.withLock {
            var items = loadAllLocked(now: now)
            guard let index = items.firstIndex(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
                _ = persistLocked(items)
                return nil
            }
            let payload = items.remove(at: index)
            _ = persistLocked(items)
            return payload
        }
    }

    func consumeLatestPending(now: Date = Date()) -> AmberSharePayload? {
        lock.withLock {
            var items = loadAllLocked(now: now)
            guard let latest = items.popLast() else {
                return nil
            }
            _ = persistLocked(items)
            return latest
        }
    }

    private func loadAllLocked(now: Date) -> [AmberSharePayload] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([AmberSharePayload].self, from: data) else {
            return []
        }
        return decoded.filter { now.timeIntervalSince($0.createdAt) <= AmberSharePayload.expirationSeconds }
    }

    private func persistLocked(_ items: [AmberSharePayload]) -> Bool {
        if items.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
            return true
        }
        guard let data = try? JSONEncoder().encode(items) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        return true
    }
}
