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
    static let maxMemoryRecallObservationCount = 500

    private struct RecallFeatureProbe: Decodable {
        let feature: String?
    }

    private static let probeDecoder = JSONDecoder()

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
        var seenIds = Set(records.map(\.id))
        var fresh: [IOSMemoryEventRecord] = []
        for event in events where seenIds.insert(event.id).inserted {
            fresh.append(IOSMemoryEventRecord(event))
        }
        guard !fresh.isEmpty else { return true }
        let updated = Self.pruneMemoryRecallObservations(records + fresh)
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

    private static func isMemoryRecallObservation(_ record: IOSMemoryEventRecord) -> Bool {
        guard record.type == MemoryEventType.memoryUpdated.wireName,
              let data = record.message.data(using: .utf8),
              let probe = try? probeDecoder.decode(RecallFeatureProbe.self, from: data) else {
            return false
        }
        return probe.feature == "memory_recall"
    }

    private static func pruneMemoryRecallObservations(
        _ records: [IOSMemoryEventRecord],
        limit: Int = maxMemoryRecallObservationCount
    ) -> [IOSMemoryEventRecord] {
        let recallIndices = records.indices.filter { isMemoryRecallObservation(records[$0]) }
        guard recallIndices.count > limit else { return records }
        let keptRecallIndices: Set<Int>
        if limit <= 0 {
            keptRecallIndices = []
        } else {
            let sortedNewestFirst = recallIndices.sorted { lhs, rhs in
                let leftTime = records[lhs].createdAt
                let rightTime = records[rhs].createdAt
                if leftTime != rightTime { return leftTime > rightTime }
                return lhs > rhs
            }
            keptRecallIndices = Set(sortedNewestFirst.prefix(limit))
        }
        let dropIndices = Set(recallIndices).subtracting(keptRecallIndices)
        return records.enumerated().compactMap { index, record in
            dropIndices.contains(index) ? nil : record
        }
    }
}
