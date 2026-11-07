import Foundation
import Observation
@preconcurrency import Shared

/// Same four input fields as the UI branch's MemoryHealthCheckSnapshot. Keep
/// this data layer independent of that branch's presentation type.
struct IOSMemoryHealthData: Equatable, Sendable {
    let supersededRatio: Double?
    let citedRatio: Double?
    let residentInjectedChars: Int?
    let maxPromptCharsBudget: Int?
}

struct IOSMemoryPromptUsage: Codable, Equatable, Sendable {
    /// Resident navigation only; relevant facts and experiences vary per turn.
    let residentChars: Int
    let residentBudget: Int
    let totalMemoryPromptChars: Int
}

struct IOSMemoryRecallObservation: Codable {
    let feature: String
    let action: String
    let runId: String
    let ids: [Int32]
}

struct IOSMemoryPendingReview: Identifiable {
    let id: String
    let memoryId: Int32
    let conversationId: String?
    let detail: IOSMemoryCorrectionReview
}

@Observable @MainActor
final class IOSMemoryHealthStore {
    private let fileURL: URL
    private(set) var latestPrompt: IOSMemoryPromptUsage?
    private(set) var errorMessage: String?

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("prompt-usage.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do { latestPrompt = try JSONDecoder().decode(IOSMemoryPromptUsage.self, from: Data(contentsOf: fileURL)) }
        catch { errorMessage = "注入统计无法读取。" }
    }

    func recordPrompt(residentChars: Int, totalChars: Int) {
        let observation = IOSMemoryPromptUsage(residentChars: residentChars, residentBudget: 1000, totalMemoryPromptChars: totalChars)
        guard observation != latestPrompt else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(observation).write(to: fileURL, options: .atomic)
            latestPrompt = observation
            errorMessage = nil
        } catch { errorMessage = "注入统计无法保存。" }
    }

    func snapshot(records: [MemoryRecord], events: IOSMemoryEventStore) -> IOSMemoryHealthData {
        let facts = records.filter { $0.kind != .topic }
        let byId = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        let replaced = Set(facts.flatMap { $0.supersedesIds.map { Int32(truncating: $0) } })
        let invalidated = Set(events.records.compactMap { event -> Int32? in
            guard event.type == MemoryEventType.memoryArchived.wireName,
                  let id = event.memoryId, byId[id]?.archived == true,
                  let payload = (try? JSONSerialization.jsonObject(with: Data(event.message.utf8))) as? [String: Any],
                  ["memory_correction", "memory_invalidation"].contains(payload["feature"] as? String ?? "") else { return nil }
            return id
        })
        let universe = Set(byId.keys).union(replaced)
        let retired = Set(replaced.filter { byId[$0]?.archived != false }).union(invalidated)
        let observations = events.records.filter { $0.type == MemoryEventType.memoryUpdated.wireName }
            .compactMap { try? JSONDecoder().decode(IOSMemoryRecallObservation.self, from: Data($0.message.utf8)) }
            .filter { $0.feature == "memory_recall" }
        var injected: Set<String> = []
        var cited: Set<String> = []
        for observation in observations {
            let keys = observation.ids.map { "\(observation.runId)/\($0)" }
            if observation.action == "injected" { injected.formUnion(keys) }
            if observation.action == "cited" { cited.formUnion(keys) }
        }
        return IOSMemoryHealthData(
            supersededRatio: universe.isEmpty || events.errorMessage != nil ? nil : Double(retired.count) / Double(universe.count),
            citedRatio: injected.isEmpty || events.errorMessage != nil ? nil : Double(injected.intersection(cited).count) / Double(injected.count),
            residentInjectedChars: latestPrompt?.residentChars,
            maxPromptCharsBudget: latestPrompt?.residentBudget
        )
    }
}

extension IOSMemoryEventStore {
    func recordInvalidation(memoryId: Int32, conversationId: String, evidence: String, now: Int64) {
        let detail = ["feature": "memory_invalidation", "quote": evidence]
        guard let data = try? JSONSerialization.data(withJSONObject: detail) else { return }
        _ = append([MemoryEvent(id: UUID().uuidString, type: .memoryArchived, conversationId: conversationId,
                                memoryId: KotlinInt(value: memoryId), candidateId: nil, modelId: nil,
                                message: String(decoding: data, as: UTF8.self), durationMs: nil, messageCount: nil, createdAt: now)])
    }

    /// Existing MemoryEventType.memoryUpdated: this updates usage metadata,
    /// not the fact text. Run+id pairs keep repeated tool loops out of ratios.
    func recordRecall(ids: Set<Int32>, runId: String?, cited: Bool, now: Int64) {
        guard let runId, !runId.isEmpty, !ids.isEmpty else { return }
        let action = cited ? "cited" : "injected"
        let detail = IOSMemoryRecallObservation(feature: "memory_recall", action: action, runId: runId, ids: ids.sorted())
        guard let data = try? JSONEncoder().encode(detail) else { return }
        _ = append([MemoryEvent(id: "recall:\(runId):\(action):\(ids.sorted().map(String.init).joined(separator: ","))",
                                type: .memoryUpdated, conversationId: nil, memoryId: nil, candidateId: nil,
                                modelId: nil, message: String(decoding: data, as: UTF8.self), durationMs: nil,
                                messageCount: nil, createdAt: now)])
    }

    func pendingCorrectionReviews(records: [MemoryRecord]) -> [IOSMemoryPendingReview] {
        self.records.compactMap { event in
            guard event.type == MemoryEventType.dreamPlanned.wireName, let id = event.memoryId,
                  let detail = try? JSONDecoder().decode(IOSMemoryCorrectionReview.self, from: Data(event.message.utf8)),
                  detail.feature == "memory_correction", detail.decision == "needs_user_review",
                  records.contains(where: { $0.id == id && !$0.archived && $0.updatedAt == detail.memoryVersion }) else { return nil }
            return IOSMemoryPendingReview(id: event.id, memoryId: id, conversationId: event.conversationId, detail: detail)
        }
    }
}

extension IOSMemoryPersistence {
    func memoryHealthSnapshot() -> IOSMemoryHealthData {
        health.snapshot(records: records, events: events)
    }
}
