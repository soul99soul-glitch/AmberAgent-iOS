import Foundation
import Observation

struct IOSPinnedSnippet: Codable, Equatable, Identifiable {
    let id: String
    let messageID: String
    let turn: Int
    let text: String
    let kind: ChatArtifactPinKind
    let codeLanguage: String?

    init(
        id: String,
        messageID: String,
        turn: Int,
        text: String,
        kind: ChatArtifactPinKind,
        codeLanguage: String? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.turn = turn
        self.text = text
        self.kind = kind
        self.codeLanguage = codeLanguage
    }
}

private struct IOSConversationArtifactValues: Codable, Equatable {
    var snippets: [IOSPinnedSnippet] = []
    var adoptedVersions: [String: String] = [:]

    var isEmpty: Bool {
        snippets.isEmpty && adoptedVersions.isEmpty
    }
}

private struct IOSConversationArtifactStoreValues: Codable, Equatable {
    var conversations: [String: IOSConversationArtifactValues] = [:]
}

enum IOSConversationArtifactStoreError: LocalizedError {
    case recoveredCorruptStore(backupName: String?, reason: String)

    var errorDescription: String? {
        switch self {
        case .recoveredCorruptStore(let backupName?, let reason):
            "产物架收藏数据无法读取（\(reason)），已另存为 \(backupName) 并重新开始。"
        case .recoveredCorruptStore(nil, let reason):
            "产物架收藏数据无法读取（\(reason)），且未能另存原文件；新的收藏会覆盖它。"
        }
    }
}

/// 按会话保存收藏片段和采用的文件版本。
@MainActor
@Observable
final class IOSConversationArtifactStore {
    private(set) var revision = 0
    /// 启动时读取失败的一次性说明，由会话 store 上报给用户。
    private(set) var storageError: Error?

    private var state = IOSConversationArtifactStoreValues()
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

    func snippets(for conversationID: String) -> [IOSPinnedSnippet] {
        state.conversations[conversationID]?.snippets ?? []
    }

    func adoptedVersions(for conversationID: String) -> [String: String] {
        state.conversations[conversationID]?.adoptedVersions ?? [:]
    }

    func adoptedVersionID(for conversationID: String, path: String) -> String? {
        state.conversations[conversationID]?.adoptedVersions[path]
    }

    func pin(_ snippet: IOSPinnedSnippet, for conversationID: String) throws {
        try update(conversationID) { values in
            if let index = values.snippets.firstIndex(where: { $0.id == snippet.id }) {
                guard values.snippets[index] != snippet else { return }
                values.snippets[index] = snippet
            } else {
                values.snippets.append(snippet)
            }
        }
    }

    func unpin(snippetID: String, for conversationID: String) throws {
        try update(conversationID) { values in
            values.snippets.removeAll { $0.id == snippetID }
        }
    }

    func adopt(versionID: String, path: String, for conversationID: String) throws {
        try update(conversationID) { values in
            values.adoptedVersions[path] = versionID
        }
    }

    func removeConversation(_ conversationID: String) throws {
        guard state.conversations[conversationID] != nil else { return }
        var next = state
        next.conversations.removeValue(forKey: conversationID)
        try commit(next)
    }

    /// 损坏的文件移到旁边保留（非 .json 扩展名，不会被备份或会话扫描当成会话），然后从空开始。
    private func reload() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            state = try decoder.decode(IOSConversationArtifactStoreValues.self, from: Data(contentsOf: fileURL))
        } catch {
            let backupURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("artifact-shelf-corrupt-\(Int(Date().timeIntervalSince1970)).bak")
            let moved = (try? fileManager.moveItem(at: fileURL, to: backupURL)) != nil
            storageError = IOSConversationArtifactStoreError.recoveredCorruptStore(
                backupName: moved ? backupURL.lastPathComponent : nil,
                reason: error.localizedDescription
            )
        }
    }

    private func update(
        _ conversationID: String,
        _ mutation: (inout IOSConversationArtifactValues) -> Void
    ) throws {
        var next = state
        var values = next.conversations[conversationID] ?? IOSConversationArtifactValues()
        mutation(&values)
        if values.isEmpty {
            next.conversations.removeValue(forKey: conversationID)
        } else {
            next.conversations[conversationID] = values
        }
        guard next != state else { return }
        try commit(next)
    }

    private func commit(_ next: IOSConversationArtifactStoreValues) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(next).write(to: fileURL, options: [.atomic])
        state = next
        revision &+= 1
    }
}
