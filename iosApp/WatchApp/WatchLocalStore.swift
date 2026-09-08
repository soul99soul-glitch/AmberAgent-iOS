import Combine
import Foundation

/// A small durable store for input that originated on Apple Watch.
///
/// The store intentionally keeps notes and composer drafts in one encoded
/// value. Every mutation is written with `Data.write(options: .atomic)` before
/// the published in-memory state changes, so a failed disk write cannot make
/// the UI send data that was never durably saved. The phone remains the owner
/// of conversations; this store only owns Watch input until the phone
/// acknowledges it.
@MainActor
final class WatchLocalStore: ObservableObject {
    struct Settings: Codable, Hashable, Sendable {
        var hapticsEnabled: Bool = true
        var showContentPreview: Bool = false
    }

    @Published private(set) var notes: [WatchNote]
    @Published private(set) var drafts: [WatchComposerDraft]
    @Published private(set) var settings: Settings
    @Published private(set) var transferringNoteIDs: Set<String>
    @Published private(set) var storageError: String?
    @Published private(set) var viewedActivities: [String: Date] = [:]

    private struct PersistedState: Codable {
        var notes: [WatchNote]
        var drafts: [WatchComposerDraft]
        var settings: Settings
        var transferringNoteIDs: Set<String>
        var viewedActivities: [String: TimeInterval]

        init(
            notes: [WatchNote],
            drafts: [WatchComposerDraft],
            settings: Settings,
            transferringNoteIDs: Set<String>,
            viewedActivities: [String: Date]
        ) {
            self.notes = notes
            self.drafts = drafts
            self.settings = settings
            self.transferringNoteIDs = transferringNoteIDs
            self.viewedActivities = viewedActivities.mapValues(\.timeIntervalSince1970)
        }

        private enum CodingKeys: String, CodingKey {
            case notes
            case drafts
            case settings
            case transferringNoteIDs
            case viewedActivities
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            notes = try container.decode([WatchNote].self, forKey: .notes)
            drafts = try container.decode([WatchComposerDraft].self, forKey: .drafts)
            settings = try container.decode(Settings.self, forKey: .settings)
            transferringNoteIDs = try container.decodeIfPresent(Set<String>.self, forKey: .transferringNoteIDs) ?? []
            if let versions = try? container.decode([String: TimeInterval].self, forKey: .viewedActivities) {
                viewedActivities = versions
            } else {
                // Read earlier development caches without losing their notes
                // or drafts. New writes retain subsecond version precision.
                viewedActivities = try container.decodeIfPresent([String: Date].self, forKey: .viewedActivities)?
                    .mapValues(\.timeIntervalSince1970) ?? [:]
            }
        }
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var writesBlocked = false

    init(
        fileURL: URL? = nil,
        defaults: UserDefaults = .standard,
        storageKey: String = "amber.watch.local-state.v1"
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL(defaults: defaults, storageKey: storageKey)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        notes = []
        drafts = []
        settings = Settings()
        transferringNoteIDs = []
        load()
    }

    private static func defaultFileURL(defaults: UserDefaults, storageKey: String) -> URL {
        // `defaults` is retained as an injection point for callers that used
        // the pre-file API; the durable value itself intentionally lives in a
        // file so `.atomic` can be honored.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let safeName = storageKey.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return base
            .appendingPathComponent("Amber", isDirectory: true)
            .appendingPathComponent("Watch", isDirectory: true)
            .appendingPathComponent("\(safeName).json")
    }

    var unsyncedNotes: [WatchNote] {
        notes
            .filter { $0.syncedAt == nil }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var hasUnsyncedNotes: Bool { notes.contains { $0.syncedAt == nil } }

    func note(id: String) -> WatchNote? {
        notes.first { $0.id == id }
    }

    /// Saves a note before any transport call. The note ID is also the
    /// request ID, which makes retransmission idempotent on the phone.
    @discardableResult
    func saveNote(_ note: WatchNote) -> Bool {
        guard !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        var nextNotes = notes
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            // Saved notes are immutable. A repeated save after an interrupted
            // draft cleanup is successful only for the same original text.
            return notes[index].text == note.text
        } else {
            var pending = note
            pending.syncedAt = nil
            nextNotes.append(pending)
        }
        return persist(
            notes: nextNotes,
            drafts: drafts,
            settings: settings,
            transferringNoteIDs: transferringNoteIDs
        )
    }

    /// Marks a note as synced only after an application-level accepted reply.
    @discardableResult
    func markNoteSynced(id: String, at date: Date = Date()) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        guard notes[index].syncedAt == nil else { return true }
        var nextNotes = notes
        nextNotes[index].syncedAt = date
        var nextTransferring = transferringNoteIDs
        nextTransferring.remove(id)
        return persist(
            notes: nextNotes,
            drafts: drafts,
            settings: settings,
            transferringNoteIDs: nextTransferring
        )
    }

    /// Freezes a note's payload before handing it to WatchConnectivity. A
    /// later edit must create a new note ID, because the phone deduplicates
    /// note delivery by that ID.
    @discardableResult
    func markNoteTransferStarted(id: String) -> Bool {
        guard let note = note(id: id), note.syncedAt == nil else { return false }
        if transferringNoteIDs.contains(id) { return true }
        var nextTransferring = transferringNoteIDs
        nextTransferring.insert(id)
        return persist(
            notes: notes,
            drafts: drafts,
            settings: settings,
            transferringNoteIDs: nextTransferring
        )
    }

    func draft(forKey key: String) -> WatchComposerDraft? {
        drafts.first { $0.key == key }
    }

    func draft(forRequestID requestId: String) -> WatchComposerDraft? {
        drafts.first { $0.requestId == requestId }
    }

    /// Returns a stable draft identity. Reopening a composer therefore keeps
    /// the same request ID, which is required when the previous delivery was
    /// ambiguous or a retry is needed.
    func ensureDraft(
        key: String,
        mode: WatchComposerMode,
        conversationId: String? = nil,
        quickActionId: String? = nil,
        initialText: String = ""
    ) -> WatchComposerDraft {
        if let existing = draft(forKey: key) {
            return existing
        }
        let draft = WatchComposerDraft(
            key: key,
            requestId: UUID().uuidString,
            mode: mode.rawValue,
            conversationId: conversationId,
            quickActionId: quickActionId,
            text: initialText,
            createdAt: Date(),
            updatedAt: Date(),
            pendingRequest: nil,
            deliveryUnknown: false
        )
        upsertDraft(draft)
        return draft
    }

    @discardableResult
    func upsertDraft(_ draft: WatchComposerDraft) -> Bool {
        guard let index = drafts.firstIndex(where: { $0.key == draft.key }) else {
            var nextDrafts = drafts
            nextDrafts.append(draft)
            return persist(
                notes: notes,
                drafts: nextDrafts,
                settings: settings,
                transferringNoteIDs: transferringNoteIDs
            )
        }

        // A pending request owns its exact payload. The composer may update
        // text before the first send, but it must not rewrite an in-flight or
        // delivery-unknown request under the same ID.
        if drafts[index].pendingRequest != nil {
            guard draft.pendingRequest == drafts[index].pendingRequest,
                  draft.deliveryUnknown == drafts[index].deliveryUnknown else {
                return false
            }
        }
        var nextDrafts = drafts
        nextDrafts[index] = draft
        return persist(
            notes: notes,
            drafts: nextDrafts,
            settings: settings,
            transferringNoteIDs: transferringNoteIDs
        )
    }

    @discardableResult
    func updateDraftText(key: String, text: String) -> Bool {
        guard let index = drafts.firstIndex(where: { $0.key == key }) else { return false }
        guard drafts[index].pendingRequest == nil else { return false }
        var nextDrafts = drafts
        nextDrafts[index].text = text
        nextDrafts[index].updatedAt = Date()
        return persist(
            notes: notes,
            drafts: nextDrafts,
            settings: settings,
            transferringNoteIDs: transferringNoteIDs
        )
    }

    /// Atomically records the exact request payload before the caller sends
    /// it to the bridge. A delivery-unknown draft can only be retried with
    /// this same request value; a changed payload is rejected until a
    /// definite business result arrives.
    @discardableResult
    func beginSending(key: String, request: WatchTaskActionRequest) -> Bool {
        guard let index = drafts.firstIndex(where: { $0.key == key }) else { return false }
        let current = drafts[index]
        if let pending = current.pendingRequest, pending != request {
            return false
        }

        var nextDrafts = drafts
        nextDrafts[index].requestId = request.requestId
        nextDrafts[index].pendingRequest = request
        nextDrafts[index].deliveryUnknown = false
        nextDrafts[index].updatedAt = Date()
        return persist(
            notes: notes,
            drafts: nextDrafts,
            settings: settings,
            transferringNoteIDs: transferringNoteIDs
        )
    }

    func pendingRequest(forKey key: String) -> WatchTaskActionRequest? {
        draft(forKey: key)?.pendingRequest
    }

    /// Returns the frozen request for an explicit retry. The caller must use
    /// it unchanged while `deliveryUnknown` is true.
    func retryRequest(forKey key: String) -> WatchTaskActionRequest? {
        draft(forKey: key)?.pendingRequest
    }

    /// Applies an application-level result to a composer draft. Accepted
    /// requests are removed; a definite rejection releases the draft and
    /// rotates its request ID so an edited payload is a new request; a
    /// transport-unknown result retains the exact request for safe retry.
    @discardableResult
    func applyResult(_ result: WatchTaskActionResult) -> Bool {
        guard let index = drafts.firstIndex(where: {
            $0.pendingRequest?.requestId == result.requestId
        }) else { return false }

        if result.accepted {
            var nextDrafts = drafts
            nextDrafts.remove(at: index)
            return persist(
                notes: notes,
                drafts: nextDrafts,
                settings: settings,
                transferringNoteIDs: transferringNoteIDs
            )
        }

        var nextDrafts = drafts
        if result.deliveryUnknown == true {
            nextDrafts[index].deliveryUnknown = true
            nextDrafts[index].updatedAt = Date()
        } else {
            nextDrafts[index].pendingRequest = nil
            nextDrafts[index].deliveryUnknown = false
            nextDrafts[index].requestId = UUID().uuidString
            nextDrafts[index].updatedAt = Date()
        }
        return persist(
            notes: notes,
            drafts: nextDrafts,
            settings: settings,
            transferringNoteIDs: transferringNoteIDs
        )
    }

    @discardableResult
    func removeDraft(key: String) -> Bool {
        guard drafts.contains(where: { $0.key == key }) else { return false }
        let nextDrafts = drafts.filter { $0.key != key }
        return persist(
            notes: notes,
            drafts: nextDrafts,
            settings: settings,
            transferringNoteIDs: transferringNoteIDs
        )
    }

    @discardableResult
    func removeDraft(requestId: String) -> Bool {
        guard drafts.contains(where: { $0.requestId == requestId }) else { return false }
        let nextDrafts = drafts.filter { $0.requestId != requestId }
        return persist(
            notes: notes,
            drafts: nextDrafts,
            settings: settings,
            transferringNoteIDs: transferringNoteIDs
        )
    }

    func hasViewed(_ activity: WatchRecentActivity) -> Bool {
        guard let date = viewedActivities[activity.id] else { return false }
        return date >= activity.updatedAt
    }

    @discardableResult
    func markViewed(_ activity: WatchRecentActivity) -> Bool {
        if hasViewed(activity) { return true }
        var next = viewedActivities
        next[activity.id] = activity.updatedAt
        let retained = Dictionary(uniqueKeysWithValues: next.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(64).map { ($0.key, $0.value) })
        return persist(notes: notes, drafts: drafts, settings: settings,
                       transferringNoteIDs: transferringNoteIDs, viewedActivities: retained)
    }

    func updateSettings(_ update: (inout Settings) -> Void) {
        var nextSettings = settings
        update(&nextSettings)
        _ = persist(
            notes: notes,
            drafts: drafts,
            settings: nextSettings,
            transferringNoteIDs: transferringNoteIDs
        )
    }

    /// Clears local drafts and already-synced notes. Pending notes are
    /// protected so a cache action cannot silently destroy user input.
    @discardableResult
    func clearCache() -> Bool {
        guard drafts.isEmpty, !hasUnsyncedNotes else { return false }
        return persist(
            notes: [],
            drafts: [],
            settings: settings,
            transferringNoteIDs: []
        )
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let state = try decoder.decode(PersistedState.self, from: data)
            notes = state.notes
            drafts = state.drafts
            settings = state.settings
            transferringNoteIDs = state.transferringNoteIDs
            viewedActivities = state.viewedActivities.mapValues { Date(timeIntervalSince1970: $0) }
        } catch {
            // Keep the raw value in place for possible recovery. The user can
            // inspect/export it later; all writes are blocked until the source
            // is repaired so a new empty state cannot overwrite user data.
            writesBlocked = true
            storageError = "手表本地缓存无法读取，原文件已保留"
        }
    }

    @discardableResult
    private func persist(
        notes nextNotes: [WatchNote],
        drafts nextDrafts: [WatchComposerDraft],
        settings nextSettings: Settings,
        transferringNoteIDs nextTransferringNoteIDs: Set<String>,
        viewedActivities nextViewedActivities: [String: Date]? = nil
    ) -> Bool {
        guard !writesBlocked else {
            storageError = "手表本地缓存无法读取，请先恢复缓存文件"
            return false
        }
        do {
            let state = PersistedState(
                notes: nextNotes,
                drafts: nextDrafts,
                settings: nextSettings,
                transferringNoteIDs: nextTransferringNoteIDs,
                viewedActivities: nextViewedActivities ?? viewedActivities
            )
            let data = try encoder.encode(state)
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            self.notes = nextNotes
            self.drafts = nextDrafts
            self.settings = nextSettings
            self.transferringNoteIDs = nextTransferringNoteIDs
            self.viewedActivities = state.viewedActivities.mapValues { Date(timeIntervalSince1970: $0) }
            storageError = nil
            return true
        } catch {
            storageError = "手表本地缓存保存失败，请稍后重试"
            return false
        }
    }
}

enum WatchComposerMode: String, Codable, Hashable, Sendable {
    case ask
    case note
}

struct WatchComposerDraft: Codable, Hashable, Identifiable, Sendable {
    var key: String
    var requestId: String
    var mode: String
    var conversationId: String?
    var quickActionId: String?
    var text: String
    var createdAt: Date
    var updatedAt: Date
    var pendingRequest: WatchTaskActionRequest?
    var deliveryUnknown: Bool

    init(
        key: String,
        requestId: String,
        mode: String,
        conversationId: String?,
        quickActionId: String?,
        text: String,
        createdAt: Date,
        updatedAt: Date,
        pendingRequest: WatchTaskActionRequest? = nil,
        deliveryUnknown: Bool = false
    ) {
        self.key = key
        self.requestId = requestId
        self.mode = mode
        self.conversationId = conversationId
        self.quickActionId = quickActionId
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pendingRequest = pendingRequest
        self.deliveryUnknown = deliveryUnknown
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case requestId
        case mode
        case conversationId
        case quickActionId
        case text
        case createdAt
        case updatedAt
        case pendingRequest
        case deliveryUnknown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decode(String.self, forKey: .key),
            requestId: try container.decode(String.self, forKey: .requestId),
            mode: try container.decode(String.self, forKey: .mode),
            conversationId: try container.decodeIfPresent(String.self, forKey: .conversationId),
            quickActionId: try container.decodeIfPresent(String.self, forKey: .quickActionId),
            text: try container.decode(String.self, forKey: .text),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            pendingRequest: try container.decodeIfPresent(WatchTaskActionRequest.self, forKey: .pendingRequest),
            deliveryUnknown: try container.decodeIfPresent(Bool.self, forKey: .deliveryUnknown) ?? false
        )
    }

    var id: String { key }

    var composerMode: WatchComposerMode {
        WatchComposerMode(rawValue: mode) ?? .ask
    }
}
