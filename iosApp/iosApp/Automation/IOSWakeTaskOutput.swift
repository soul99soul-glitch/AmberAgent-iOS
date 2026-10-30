import Foundation
import CryptoKit
@preconcurrency import Shared

enum IOSWakeTaskOutput {
    static func messageID(taskID: String, attemptNumber: Int = 0) -> KotlinUuid {
        let seed = attemptNumber == 0 ? "amber-wake-message:\(taskID)"
            : "amber-wake-message:\(taskID):attempt:\(attemptNumber)"
        let hex = SHA256.hash(data: Data(seed.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let raw = Array(hex.prefix(32))
        let uuid = "\(String(raw[0..<8]))-\(String(raw[8..<12]))-\(String(raw[12..<16]))-\(String(raw[16..<20]))-\(String(raw[20..<32]))"
        return KotlinUuid.companion.parse(uuidString: uuid)
    }

    /// Only newly produced assistant text belongs to this execution.
    static func text(in finalMessages: [UIMessage], baseline: [UIMessage]) -> String? {
        let existingIDs = Set(baseline.map(\.id))
        return assistantText(in: finalMessages.filter { !existingIDs.contains($0.id) })
    }

    /// A cold read is bounded by this task's durable marker and the next user turn.
    static func text(for task: IOSWakeTask, in conversationMessages: [UIMessage]) -> String? {
        let markerID = messageID(taskID: task.id, attemptNumber: task.attemptNumber ?? 0)
        guard let marker = conversationMessages.firstIndex(where: { $0.id == markerID && $0.role == .user }) else {
            return nil
        }
        let taskMessages = conversationMessages.dropFirst(marker + 1).prefix { $0.role != .user }
        return assistantText(in: Array(taskMessages))
    }

    private static func assistantText(in messages: [UIMessage]) -> String? {
        let parts = messages.filter { $0.role == .assistant }.flatMap(\.parts)
            .compactMap { ($0 as? UIMessagePart.Text)?.text }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
