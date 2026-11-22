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
        return "\(existingDraft)\n\n\(cleanIncoming)"
    }
}

/// Shared App Group handoff store used by `AmberShareExtension` and `iosApp`.
final class AmberShareHandoffStore: @unchecked Sendable {
    static let storageKey = "app.amber.ios.shareHandoff.pendingPayloads.v1"
    static let maxRetainedPayloads = 8

    static let shared: AmberShareHandoffStore? = {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AmberShareAppGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return AmberShareHandoffStore(directory: container.appendingPathComponent("AmberShareInbox", isDirectory: true),
                                      legacyDefaults: UserDefaults(suiteName: group))
    }()

    private let directory: URL
    private let legacyDefaults: UserDefaults?
    private let lock = NSLock()

    init(directory: URL, legacyDefaults: UserDefaults? = nil) {
        self.directory = directory
        self.legacyDefaults = legacyDefaults
    }

    static func shareDeepLinkURL(
        for handoffID: String,
        scheme: String
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
        guard payload.formattedPrefillText != nil, let file = fileURL(id: payload.id) else { return false }
        return lock.withLock {
            do {
                // Commit one file before opening the host. Consuming a different share cannot undo this write.
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(payload).write(to: file, options: .atomic)
                for item in pendingFiles(now: now).dropLast(Self.maxRetainedPayloads) {
                    try? FileManager.default.removeItem(at: item.file)
                }
                return true
            } catch { return false }
        }
    }

    func consume(id: String, now: Date = Date()) -> AmberSharePayload? {
        lock.withLock {
            if let file = fileURL(id: id), let item = read(file, now: now) {
                return take(item, file: file)
            }
            return consumeLegacy(id: id, now: now)
        }
    }

    func consumeLatestPending(now: Date = Date()) -> AmberSharePayload? {
        lock.withLock {
            guard let latest = pendingFiles(now: now).last else { return consumeLegacy(id: nil, now: now) }
            return take(latest.payload, file: latest.file)
        }
    }

    private func fileURL(id: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !id.isEmpty, id.utf8.count <= 64, id.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return directory.appendingPathComponent(id.lowercased()).appendingPathExtension("json")
    }

    private func take(_ payload: AmberSharePayload, file: URL) -> AmberSharePayload? {
        do {
            try FileManager.default.removeItem(at: file)
            return payload
        } catch { return nil }
    }

    private func read(_ file: URL, now: Date) -> AmberSharePayload? {
        guard let data = try? Data(contentsOf: file),
              let payload = try? JSONDecoder().decode(AmberSharePayload.self, from: data) else { return nil }
        guard now.timeIntervalSince(payload.createdAt) <= AmberSharePayload.expirationSeconds else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return payload
    }

    private func pendingFiles(now: Date) -> [(file: URL, payload: AmberSharePayload)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            read(file, now: now).map { (file: file, payload: $0) }
        }.sorted { $0.payload.createdAt < $1.payload.createdAt }
    }

    // Shares queued by the previous extension version live for up to 30 minutes.
    private func consumeLegacy(id: String?, now: Date) -> AmberSharePayload? {
        guard let defaults = legacyDefaults, let data = defaults.data(forKey: Self.storageKey),
              var items = try? JSONDecoder().decode([AmberSharePayload].self, from: data) else { return nil }
        items.removeAll { now.timeIntervalSince($0.createdAt) > AmberSharePayload.expirationSeconds }
        let index = id.flatMap { target in items.firstIndex { $0.id.caseInsensitiveCompare(target) == .orderedSame } }
        let payload = id == nil ? items.popLast() : index.map { items.remove(at: $0) }
        if items.isEmpty { defaults.removeObject(forKey: Self.storageKey) }
        else if let remaining = try? JSONEncoder().encode(items) { defaults.set(remaining, forKey: Self.storageKey) }
        return payload
    }
}
