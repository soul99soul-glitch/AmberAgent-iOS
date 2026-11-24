import Darwin
import Foundation
import os

/// Encode and stage the large payload off the main actor. Only the atomic rename
/// runs with its owner, so a cancelled write cannot publish after unpair or a newer write.
@MainActor
final class DebouncedSnapshotFile {
    let url: URL
    var delay: Duration = .milliseconds(500)
    private(set) var pending: Task<Void, Never>?
    nonisolated static let logger = Logger(subsystem: "app.amber.agent", category: "SnapshotStorage")

    init(url: URL) {
        self.url = url
    }

    nonisolated static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }

    func schedule(
        encode: @escaping @Sendable () throws -> Data,
        didWrite: @escaping @MainActor (Int) -> Void = { _ in }
    ) {
        cancel()
        let url = url
        let delay = delay
        pending = Task {
            do {
                try await Task.sleep(for: delay)
                let staged = url.deletingLastPathComponent().appending(path: UUID().uuidString + ".tmp")
                defer { try? FileManager.default.removeItem(at: staged) }
                let size = try await Task.detached(priority: .utility) {
                    let data = try encode()
                    try Self.write(data, to: staged)
                    return data.count
                }.value
                try Task.checkCancellation()
                guard rename(staged.path, url.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                didWrite(size)
            } catch is CancellationError {
            } catch {
                Self.logger.error("Snapshot write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

@MainActor
final class MacGatewayDialogueFiles {
    typealias Envelope = MacGatewayCloudDialoguePersistedEnvelope

    // Retryable requests belong to this device pairing, including after a backup restore.
    static let applicationDirectory: URL = {
        var url = URL.applicationSupportDirectory.appending(path: "MacGateway")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            DebouncedSnapshotFile.logger.error("Preparing gateway storage failed: \(error.localizedDescription, privacy: .public)")
        }
        return url
    }()

    let snapshot: DebouncedSnapshotFile
    let journalURL: URL
    private var journalID: UUID?
    private var journalRequestIDs = Set<String>()

    init(directory: URL, role: MacGatewayEndpointRole) {
        let directory = directory.appending(path: role.rawValue)
        snapshot = DebouncedSnapshotFile(url: directory.appending(path: "dialogue.json"))
        journalURL = directory.appending(path: "submissions.json")
    }

    func clear() {
        snapshot.cancel()
        journalID = nil
        journalRequestIDs.removeAll()
        for url in [snapshot.url, journalURL] where FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) }
            catch { DebouncedSnapshotFile.logger.error("Removing dialogue file failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func load(connection: MacGatewayConnection, defaults: UserDefaults, key: String) throws -> (Envelope, Int)? {
        snapshot.cancel()
        journalID = nil
        journalRequestIDs.removeAll()
        let decoder = JSONDecoder()
        func belongs(_ envelope: Envelope) -> Bool {
            envelope.gatewayId == connection.gatewayId && envelope.deviceId == connection.deviceId
        }
        var base: Envelope?
        var size = 0
        if let data = try read(snapshot.url) {
            let envelope = try decoder.decode(Envelope.self, from: data)
            if belongs(envelope) {
                base = envelope
                size = data.count
            } else {
                try FileManager.default.removeItem(at: snapshot.url)
            }
        }
        if let legacy = defaults.data(forKey: key) {
            let envelope = try decoder.decode(Envelope.self, from: legacy)
            if belongs(envelope) {
                if base == nil {
                    base = envelope
                    size = legacy.count
                    // Keep the original as the recovery source if storage is temporarily unavailable.
                    do {
                        try DebouncedSnapshotFile.write(legacy, to: snapshot.url)
                        defaults.removeObject(forKey: key)
                    } catch {
                        DebouncedSnapshotFile.logger.error("Dialogue migration deferred: \(error.localizedDescription, privacy: .public)")
                    }
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        journalID = base?.journalID
        guard let bytes = try read(journalURL) else { return base.map { ($0, size) } }
        let journal = try decoder.decode(Envelope.self, from: bytes)
        guard belongs(journal), journal.journalID != base?.journalID else {
            try? FileManager.default.removeItem(at: journalURL)
            return base.map { ($0, size) }
        }
        journalID = journal.journalID
        journalRequestIDs = Set(journal.submissions.map(\.requestId))
        guard var restored = base else { return (journal, bytes.count) }
        // Submissions insert at the head. Follow-ups append. A retry updates its original row in place.
        let existingSubmissions = Set(restored.submissions.map(\.id))
        let submissions = Dictionary(journal.submissions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        restored.submissions = journal.submissions.filter { !existingSubmissions.contains($0.id) }
            + restored.submissions.map { submissions[$0.id] ?? $0 }
        let existingFollowups = Set(restored.followups.map(\.id))
        let followups = Dictionary(journal.followups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        restored.followups = restored.followups.map { followups[$0.id] ?? $0 }
            + journal.followups.filter { !existingFollowups.contains($0.id) }
        restored.receipts.merge(journal.receipts) { _, newer in newer }
        restored.progressByWorkItem.merge(journal.progressByWorkItem) { _, newer in newer }
        restored.conversationId = journal.conversationId
        restored.isCloudMainDialogueSelected = journal.isCloudMainDialogueSelected
        return (restored, size + bytes.count)
    }

    /// Only requests changed since the last checkpoint participate in a synchronous POST fence.
    func recordIntent(requestID: String, state: Envelope) throws {
        let ids = journalRequestIDs.union([requestID])
        var journal = state
        journal.journalID = UUID()
        journal.cursor = 0 // A journal alone has no matching event page.
        journal.events = []
        journal.receipts = state.receipts.filter { ids.contains($0.key) }
        journal.trimmedInputEventIds = nil
        journal.dismissedUnifiedMacRunIds = nil
        journal.submissions = state.submissions.filter { ids.contains($0.requestId) }
        let stops = Set(journal.submissions.filter { $0.kind == .stopWorkItem }.compactMap(\.workItemId))
        journal.followups = state.followups.filter { ids.contains($0.requestId) || stops.contains($0.workItemId) }
        let workIDs = Set(journal.submissions.compactMap(\.workItemId) + journal.receipts.values.flatMap(\.workItemIds))
        journal.progressByWorkItem = Dictionary(uniqueKeysWithValues: workIDs.compactMap { key in
            state.progressByWorkItem[key].map { (key, $0) }
        })
        let data = try JSONEncoder().encode(MacGatewayStore.redactedEnvelopeForPersistence(journal))
        try DebouncedSnapshotFile.write(data, to: journalURL)
        journalID = journal.journalID
        journalRequestIDs = ids
    }

    func schedule(_ state: Envelope, didWrite: @escaping @MainActor (Int) -> Void) {
        var checkpoint = state
        checkpoint.journalID = journalID
        snapshot.schedule { [checkpoint] in
            try JSONEncoder().encode(MacGatewayStore.redactedEnvelopeForPersistence(checkpoint))
        } didWrite: { [weak self] size in
            // The ID in the snapshot also fences a crash between rename and journal removal.
            if let self, !self.journalRequestIDs.isEmpty, self.journalID == checkpoint.journalID {
                try? FileManager.default.removeItem(at: self.journalURL)
                self.journalRequestIDs.removeAll()
            }
            didWrite(size)
        }
    }
}
