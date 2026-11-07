import Foundation
import Observation
@preconcurrency import Shared

/// Codable mirror of the existing KMP MemoryEvent contract. The message holds
/// structured evidence for correction events, rather than another memory fact.
struct IOSMemoryEventRecord: Codable, Identifiable {
    let id: String
    let type: String
    let conversationId: String?
    let memoryId: Int32?
    let candidateId: String?
    let modelId: String?
    let message: String
    let durationMs: Int64?
    let messageCount: Int32?
    let createdAt: Int64

    init(_ event: MemoryEvent) {
        id = event.id; type = event.type.wireName; conversationId = event.conversationId
        memoryId = event.memoryId?.int32Value; candidateId = event.candidateId; modelId = event.modelId
        message = event.message; durationMs = event.durationMs?.int64Value
        messageCount = event.messageCount?.int32Value; createdAt = event.createdAt
    }

    var event: MemoryEvent? {
        guard let kind = MemoryEventType.entries.first(where: { $0.wireName == type }) else { return nil }
        return MemoryEvent(id: id, type: kind, conversationId: conversationId,
                           memoryId: memoryId.map { KotlinInt(value: $0) }, candidateId: candidateId,
                           modelId: modelId, message: message, durationMs: durationMs.map { KotlinLong(value: $0) },
                           messageCount: messageCount.map { KotlinInt(value: $0) }, createdAt: createdAt)
    }
}

@Observable @MainActor
final class IOSMemoryEventStore {
    private let fileURL: URL
    private(set) var records: [IOSMemoryEventRecord] = []
    private(set) var errorMessage: String?

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("events.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do { records = try JSONDecoder().decode([IOSMemoryEventRecord].self, from: Data(contentsOf: fileURL)) }
        catch { errorMessage = "记忆事件无法读取，已保留原文件。" }
    }

    @discardableResult
    func append(_ events: [MemoryEvent]) -> Bool {
        guard errorMessage == nil else { return false }
        let ids = Set(records.map(\.id))
        let fresh = events.filter { !ids.contains($0.id) }.map(IOSMemoryEventRecord.init)
        guard !fresh.isEmpty else { return true }
        let updated = records + fresh
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
            records = updated
            return true
        } catch {
            errorMessage = "无法保存记忆事件。"
            return false
        }
    }
}
