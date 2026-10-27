import Foundation
import Observation

enum DesktopPinnedSnippetKind: String, Codable, Sendable {
    case message, code
}

struct DesktopPinnedSnippet: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    let messageID: UUID
    let kind: DesktopPinnedSnippetKind
    let text: String
    var codeLanguage: String?
    var createdAt = Date()
}

/// Pins are kept per conversation in one JSON file; a nil URL keeps them in memory (preview and tests).
@MainActor @Observable
final class DesktopArtifactShelf {
    private(set) var pinsByConversation: [UUID: [DesktopPinnedSnippet]] = [:]
    private(set) var errorMessage: String?
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var unreadableOriginalRetained = false

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            pinsByConversation = try JSONDecoder().decode([UUID: [DesktopPinnedSnippet]].self, from: Data(contentsOf: fileURL))
        } catch {
            // Keep the unreadable file aside so new pins never overwrite it.
            let aside = fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(UUID().uuidString).json")
            let moved = (try? FileManager.default.moveItem(at: fileURL, to: aside)) != nil
            unreadableOriginalRetained = !moved
            errorMessage = moved ? "产物架记录无法读取，原文件已另存为 \(aside.lastPathComponent)。"
                : "产物架记录无法读取，原文件已保留。请先备份并移走原文件，再重新启动；新的固定内容仅在本次运行中保留。"
        }
    }

    func pins(for conversationID: UUID) -> [DesktopPinnedSnippet] { pinsByConversation[conversationID] ?? [] }

    func pinnedSnippet(messageID: UUID, kind: DesktopPinnedSnippetKind, text: String, in conversationID: UUID) -> DesktopPinnedSnippet? {
        pins(for: conversationID).first { $0.messageID == messageID && $0.kind == kind && $0.text == text }
    }

    func pin(messageID: UUID, kind: DesktopPinnedSnippetKind, text: String, codeLanguage: String? = nil, in conversationID: UUID) {
        guard pinnedSnippet(messageID: messageID, kind: kind, text: text, in: conversationID) == nil else { return }
        pinsByConversation[conversationID, default: []].insert(DesktopPinnedSnippet(messageID: messageID, kind: kind, text: text,
            codeLanguage: codeLanguage.flatMap { $0.isEmpty ? nil : $0 }), at: 0)
        save()
    }

    func unpin(_ id: UUID, in conversationID: UUID) {
        guard var values = pinsByConversation[conversationID], let index = values.firstIndex(where: { $0.id == id }) else { return }
        values.remove(at: index)
        pinsByConversation[conversationID] = values.isEmpty ? nil : values
        save()
    }

    @discardableResult func removeConversation(_ conversationID: UUID) -> Bool {
        guard pinsByConversation.removeValue(forKey: conversationID) != nil else { return true }
        return save()
    }

    func restore(_ pins: [DesktopPinnedSnippet], for conversationID: UUID) throws {
        guard !pins.isEmpty else { return }
        let previous = pinsByConversation[conversationID]
        pinsByConversation[conversationID] = pins
        guard save() else {
            pinsByConversation[conversationID] = previous
            throw DesktopRuntimeError.message(errorMessage ?? "产物架恢复失败。")
        }
    }

    @discardableResult private func save() -> Bool {
        guard !unreadableOriginalRetained else { return false }
        guard let fileURL else { return true }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(pinsByConversation).write(to: fileURL, options: .atomic)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "产物架保存失败，固定内容仅在本次运行中保留。请检查磁盘空间或文件权限。"
            return false
        }
    }
}
