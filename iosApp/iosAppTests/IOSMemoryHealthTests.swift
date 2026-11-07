import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSMemoryHealthTests: XCTestCase {
    func testRatiosUseRunMemoryPairsAndExcludeTopicsAndRestoredFacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let events = IOSMemoryEventStore(directory: root)
        let health = IOSMemoryHealthStore(directory: root)
        XCTAssertNil(health.snapshot(records: [], events: events).citedRatio)
        XCTAssertNil(health.snapshot(records: [], events: events).residentInjectedChars)
        events.recordRecall(ids: [2, 3], runId: "run-a", cited: false, now: 100)
        events.recordRecall(ids: [2, 3], runId: "run-a", cited: false, now: 101)
        events.recordRecall(ids: [2], runId: "run-a", cited: true, now: 102)
        events.recordRecall(ids: [2], runId: "run-b", cited: true, now: 103) // Was not injected in b.
        XCTAssertEqual(events.records.count, 3)
        let invalidation = #"{"feature":"memory_invalidation"}"#
        XCTAssertTrue(events.append([MemoryEvent(id: "archive-3", type: .memoryArchived, conversationId: "c", memoryId: KotlinInt(value: 3),
                                                candidateId: nil, modelId: nil, message: invalidation, durationMs: nil,
                                                messageCount: nil, createdAt: 104)]))
        let records = [record(1, archived: true), record(2, supersedes: [1]), record(3, archived: true), record(9, kind: .topic)]
        let snapshot = health.snapshot(records: records, events: events)
        XCTAssertEqual(try XCTUnwrap(snapshot.supersededRatio), 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.citedRatio, 0.5)
        let restored = [record(1), record(2, supersedes: [1]), record(3)]
        XCTAssertEqual(health.snapshot(records: restored, events: events).supersededRatio, 0)
    }

    func testResidentCountIsActualNavigationAndPersistsIndependentlyOfDeepPages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let health = IOSMemoryHealthStore(directory: root)
        let index = "<memory-wiki-index>\n[习惯](topics/3-习惯.md)\n</memory-wiki-index>"
        health.recordPrompt(residentChars: index.count, totalChars: index.count + 500)
        let loaded = IOSMemoryHealthStore(directory: root)
        let snapshot = loaded.snapshot(records: [], events: IOSMemoryEventStore(directory: root))
        XCTAssertEqual(snapshot.residentInjectedChars, index.count)
        XCTAssertEqual(snapshot.maxPromptCharsBudget, 1000)
        XCTAssertEqual(loaded.latestPrompt?.totalMemoryPromptChars, index.count + 500)

        let uiSnapshot = MemoryHealthCheckSnapshot(snapshot)
        XCTAssertEqual(uiSnapshot.supersededRatio, snapshot.supersededRatio)
        XCTAssertEqual(uiSnapshot.citedRatio, snapshot.citedRatio)
        XCTAssertEqual(uiSnapshot.residentInjectedChars, snapshot.residentInjectedChars)
        XCTAssertEqual(uiSnapshot.maxPromptCharsBudget, snapshot.maxPromptCharsBudget)
        XCTAssertEqual(uiSnapshot.residentCharsText, "\(index.count) 字")
        XCTAssertEqual(uiSnapshot.residentBudgetText, "上限 1000 字")
    }

    private func record(_ id: Int32, archived: Bool = false, supersedes: [Int32] = [], kind: MemoryKind = .project) -> MemoryRecord {
        MemoryRecord(id: id, content: "记忆", scope: .longTerm, kind: kind, assistantId: "__long_term__",
                     sourceConversationId: nil, sourceMessageIds: [], supersedesIds: supersedes.map { KotlinInt(value: $0) },
                     expiresAt: nil, confidence: 1, pinned: false, archived: archived,
                     createdAt: 1, updatedAt: 2, lastUsedAt: nil, topicTitle: kind == .topic ? "主题" : nil,
                     memberIds: [], lastReinforcedAt: nil)
    }
}
