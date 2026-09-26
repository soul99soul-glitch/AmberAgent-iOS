import Foundation
import Observation

private struct IOSConversationRecapStoreValues: Codable, Equatable {
    var conversations: [String: ConversationRecap] = [:]
}

enum IOSConversationRecapStoreError: LocalizedError {
    case recoveredCorruptStore(backupName: String?, reason: String)

    var errorDescription: String? {
        switch self {
        case .recoveredCorruptStore(let backupName?, let reason):
            "回顾数据无法读取（\(reason)），已另存为 \(backupName) 并重新开始。"
        case .recoveredCorruptStore(nil, let reason):
            "回顾数据无法读取（\(reason)），且未能另存原文件；新的回顾会覆盖它。"
        }
    }
}

/// Small iOS-only JSON store keyed by conversation ID. Recaps are local-only
/// metadata and are intentionally excluded from conversation backups.
@MainActor
@Observable
final class IOSConversationRecapStore {
    private(set) var revision = 0
    private(set) var storageError: Error?

    private var state = IOSConversationRecapStoreValues()
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let decoder: JSONDecoder

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        reload()
    }

    func recap(for conversationID: String) -> ConversationRecap? {
        state.conversations[conversationID]
    }

    func save(_ recap: ConversationRecap) throws {
        var next = state
        next.conversations[recap.conversationID] = recap
        guard next != state else { return }
        try commit(next)
    }

    func removeConversation(_ conversationID: String) throws {
        guard state.conversations[conversationID] != nil else { return }
        var next = state
        next.conversations.removeValue(forKey: conversationID)
        try commit(next)
    }

    private func reload() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            state = try decoder.decode(IOSConversationRecapStoreValues.self, from: Data(contentsOf: fileURL))
        } catch {
            let backupURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("conversation-recaps-corrupt-\(Int(Date().timeIntervalSince1970)).bak")
            let moved = (try? fileManager.moveItem(at: fileURL, to: backupURL)) != nil
            storageError = IOSConversationRecapStoreError.recoveredCorruptStore(
                backupName: moved ? backupURL.lastPathComponent : nil,
                reason: error.localizedDescription
            )
        }
    }

    private func commit(_ next: IOSConversationRecapStoreValues) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(next).write(to: fileURL, options: [.atomic])
        state = next
        revision &+= 1
    }
}
