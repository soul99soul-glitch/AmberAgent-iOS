import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSWorkspaceGuardAndMemoryEventsCapTests: XCTestCase {
    func testCorruptedWorkspaceIndexBlocksWritesAndPreservesOriginalBytes() async throws {
        let baseDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let workspaceRoot = baseDirectory.appendingPathComponent("AmberWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let stateURL = workspaceRoot.appendingPathComponent("workspace.json", isDirectory: false)
        let corruptedBytes = Data("{\"files\":[corrupted-payload".utf8)
        try corruptedBytes.write(to: stateURL, options: [.atomic])

        let store = IOSWorkspaceStore(baseDirectory: baseDirectory)
        XCTAssertEqual(store.loadState, .unreadable)
        XCTAssertTrue(store.files.isEmpty)
        XCTAssertTrue(store.artifacts.isEmpty)
        XCTAssertNotNil(store.errorMessage)

        // saveArtifact must fail and leave workspace.json bytes untouched.
        XCTAssertThrowsError(
            try store.saveArtifact(
                title: "Headless Output",
                content: "Should not overwrite corrupt workspace.json",
                type: .miniApp,
                sourceKind: "mini_app"
            )
        )
        XCTAssertEqual(try Data(contentsOf: stateURL), corruptedBytes)
        XCTAssertEqual(store.loadState, .unreadable)
        XCTAssertTrue(store.artifacts.isEmpty)
        let artifactEntries = try FileManager.default.contentsOfDirectory(
            atPath: workspaceRoot.appendingPathComponent("artifacts").path
        )
        XCTAssertTrue(artifactEntries.isEmpty)

        // importFile must fail and leave workspace.json bytes untouched.
        let sourceFile = baseDirectory.appendingPathComponent("sample.txt")
        try Data("hello workspace".utf8).write(to: sourceFile)
        do {
            _ = try await store.importFile(url: sourceFile, source: "unit_test")
            XCTFail("Expected importFile to fail while workspace.json is unreadable.")
        } catch {
            // expected
        }
        XCTAssertEqual(try Data(contentsOf: stateURL), corruptedBytes)
        XCTAssertEqual(store.loadState, .unreadable)
        XCTAssertTrue(store.files.isEmpty)
        let fileEntries = try FileManager.default.contentsOfDirectory(
            atPath: workspaceRoot.appendingPathComponent("files").path
        )
        XCTAssertTrue(fileEntries.isEmpty)

        // Tool write path must also refuse and roll back payload while preserving bytes.
        let toolOutput = await store.executeTool(
            toolName: "workspace_file_write",
            input: #"{"path":"notes/blocked.md","content":"blocked"}"#
        )
        let parsedToolOutput = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(toolOutput.utf8)) as? [String: Any]
        )
        XCTAssertEqual(parsedToolOutput["ok"] as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: stateURL), corruptedBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspaceRoot.appendingPathComponent("files/notes/blocked.md").path
            )
        )
    }

    func testMissingWorkspaceIndexAllowsInitialWrites() async throws {
        let baseDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSWorkspaceStore(baseDirectory: baseDirectory)
        XCTAssertEqual(store.loadState, .missing)
        XCTAssertNil(store.errorMessage)

        let artifact = try store.saveArtifact(
            title: "First Artifact",
            content: "Initial content",
            type: .note,
            sourceKind: "unit_test"
        )
        XCTAssertEqual(store.loadState, .loaded)
        XCTAssertEqual(store.artifacts.map(\.id), [artifact.id])

        let sourceFile = baseDirectory.appendingPathComponent("first.txt")
        try Data("initial file body".utf8).write(to: sourceFile)
        let file = try await store.importFile(url: sourceFile, source: "unit_test")
        XCTAssertEqual(store.loadState, .loaded)
        XCTAssertEqual(store.files.map(\.id), [file.id])

        let reloaded = IOSWorkspaceStore(baseDirectory: baseDirectory)
        XCTAssertEqual(reloaded.loadState, .loaded)
        XCTAssertEqual(reloaded.artifacts.map(\.id), [artifact.id])
        XCTAssertEqual(reloaded.files.map(\.id), [file.id])
    }

    func testMemoryEventsCapOnlyPrunesMemoryRecallAndPreservesCorrectionEvents() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = IOSMemoryEventStore(directory: root)
        let cap = IOSMemoryEventStore.maxMemoryRecallObservationCount
        XCTAssertEqual(cap, 500)

        let earlyArchived = makeCorrectionEvent(
            id: "archive-early",
            type: .memoryArchived,
            memoryId: 10,
            feature: "memory_invalidation",
            decision: nil,
            createdAt: 1
        )
        let earlyReview = makeCorrectionEvent(
            id: "review-early",
            type: .dreamPlanned,
            memoryId: 11,
            feature: "memory_correction",
            decision: "needs_user_review",
            createdAt: 2
        )
        XCTAssertTrue(store.append([earlyArchived, earlyReview]))

        // Insert 560 memory_recall observations in batches, with an interleaved correction event.
        var firstBatch: [MemoryEvent] = []
        for idx in 0..<300 {
            firstBatch.append(makeRecallEvent(index: idx, createdAt: Int64(100 + idx)))
        }
        XCTAssertTrue(store.append(firstBatch))

        let middleArchived = makeCorrectionEvent(
            id: "archive-mid",
            type: .memoryArchived,
            memoryId: 12,
            feature: "memory_correction",
            decision: "archive",
            createdAt: 500
        )
        XCTAssertTrue(store.append([middleArchived]))

        var secondBatch: [MemoryEvent] = []
        for idx in 300..<560 {
            secondBatch.append(makeRecallEvent(index: idx, createdAt: Int64(1000 + idx)))
        }
        XCTAssertTrue(store.append(secondBatch))

        let lateReview = makeCorrectionEvent(
            id: "review-late",
            type: .dreamPlanned,
            memoryId: 13,
            feature: "memory_correction",
            decision: "needs_user_review",
            createdAt: 2000
        )
        XCTAssertTrue(store.append([lateReview]))

        let expectedKeptRecallIds = (60..<560).map { "recall:run-\($0):injected:1" }
        let expectedNonRecallIds = ["archive-early", "review-early", "archive-mid", "review-late"]

        for instance in [store, IOSMemoryEventStore(directory: root)] {
            let recallRecords = instance.records.filter { $0.id.hasPrefix("recall:") }
            let nonRecallRecords = instance.records.filter { !$0.id.hasPrefix("recall:") }

            XCTAssertEqual(recallRecords.count, cap)
            XCTAssertEqual(recallRecords.map(\.id), expectedKeptRecallIds)
            XCTAssertEqual(nonRecallRecords.map(\.id), expectedNonRecallIds)
        }
    }

    func testPendingCorrectionReviewsAndSupersededRatioUnchangedAfterRecallPruning() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let events = IOSMemoryEventStore(directory: root)
        let health = IOSMemoryHealthStore(directory: root)

        let records = [
            makeMemoryRecord(id: 1, archived: true, updatedAt: 100),
            makeMemoryRecord(id: 2, supersedes: [1], updatedAt: 100),
            makeMemoryRecord(id: 3, archived: true, updatedAt: 100),
            makeMemoryRecord(id: 4, pinned: true, updatedAt: 200),
            makeMemoryRecord(id: 5, scope: .core, updatedAt: 250),
            makeMemoryRecord(id: 9, kind: .topic, updatedAt: 100),
        ]

        // Record invalidation + two pending user reviews before recall flood.
        events.recordInvalidation(memoryId: 3, conversationId: "conv-1", evidence: "不再使用旧设备", now: 10)
        let reviewDetail4 = IOSMemoryCorrectionReview(
            feature: "memory_correction",
            decision: "needs_user_review",
            memoryVersion: 200,
            episodeId: "ep-1",
            messageId: "msg-1",
            quote: "我换了新主力机",
            reason: "与旧记忆冲突",
            kind: "contradicted"
        )
        let reviewDetail5 = IOSMemoryCorrectionReview(
            feature: "memory_correction",
            decision: "needs_user_review",
            memoryVersion: 250,
            episodeId: "ep-2",
            messageId: "msg-2",
            quote: "不再用旧工具链",
            reason: "已过时",
            kind: "outdated"
        )
        let reviewMessage4 = String(decoding: try JSONEncoder().encode(reviewDetail4), as: UTF8.self)
        let reviewMessage5 = String(decoding: try JSONEncoder().encode(reviewDetail5), as: UTF8.self)
        XCTAssertTrue(events.append([
            MemoryEvent(
                id: "review-4",
                type: .dreamPlanned,
                conversationId: "conv-1",
                memoryId: KotlinInt(value: 4),
                candidateId: nil,
                modelId: nil,
                message: reviewMessage4,
                durationMs: nil,
                messageCount: nil,
                createdAt: 11
            ),
            MemoryEvent(
                id: "review-5",
                type: .dreamPlanned,
                conversationId: "conv-2",
                memoryId: KotlinInt(value: 5),
                candidateId: nil,
                modelId: nil,
                message: reviewMessage5,
                durationMs: nil,
                messageCount: nil,
                createdAt: 12
            ),
        ]))

        let baselineReviews = events.pendingCorrectionReviews(records: records)
        let baselineRatio = try XCTUnwrap(health.snapshot(records: records, events: events).supersededRatio)
        XCTAssertEqual(baselineReviews.map(\.id), ["review-4", "review-5"])
        XCTAssertEqual(baselineRatio, 2.0 / 5.0, accuracy: 0.0001)

        // Flood with 600 recall events (exceeding the 500 cap).
        for idx in 0..<600 {
            events.recordRecall(ids: [2, 4], runId: "flood-run-\(idx)", cited: idx % 2 == 0, now: Int64(100 + idx))
        }

        let reloadedEvents = IOSMemoryEventStore(directory: root)
        for currentEvents in [events, reloadedEvents] {
            let afterReviews = currentEvents.pendingCorrectionReviews(records: records)
            let afterRatio = try XCTUnwrap(health.snapshot(records: records, events: currentEvents).supersededRatio)

            XCTAssertEqual(afterReviews.map(\.id), baselineReviews.map(\.id))
            XCTAssertEqual(afterReviews.map(\.memoryId), baselineReviews.map(\.memoryId))
            XCTAssertEqual(afterReviews.map(\.detail.quote), baselineReviews.map(\.detail.quote))
            XCTAssertEqual(afterRatio, baselineRatio, accuracy: 0.0001)
            XCTAssertEqual(
                currentEvents.records.filter { $0.id.hasPrefix("recall:") }.count,
                IOSMemoryEventStore.maxMemoryRecallObservationCount
            )
        }
    }

    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSWorkspaceGuardAndMemoryEventsCapTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeRecallEvent(index: Int, createdAt: Int64) -> MemoryEvent {
        let observation = IOSMemoryRecallObservation(
            feature: "memory_recall",
            action: "injected",
            runId: "run-\(index)",
            ids: [1]
        )
        let payload = String(decoding: (try? JSONEncoder().encode(observation)) ?? Data(), as: UTF8.self)
        return MemoryEvent(
            id: "recall:run-\(index):injected:1",
            type: .memoryUpdated,
            conversationId: nil,
            memoryId: nil,
            candidateId: nil,
            modelId: nil,
            message: payload,
            durationMs: nil,
            messageCount: nil,
            createdAt: createdAt
        )
    }

    private func makeCorrectionEvent(
        id: String,
        type: MemoryEventType,
        memoryId: Int32,
        feature: String,
        decision: String?,
        createdAt: Int64
    ) -> MemoryEvent {
        var payload: [String: Any] = ["feature": feature, "quote": "evidence-\(id)"]
        if let decision { payload["decision"] = decision }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return MemoryEvent(
            id: id,
            type: type,
            conversationId: "conv-1",
            memoryId: KotlinInt(value: memoryId),
            candidateId: nil,
            modelId: nil,
            message: String(decoding: data, as: UTF8.self),
            durationMs: nil,
            messageCount: nil,
            createdAt: createdAt
        )
    }

    private func makeMemoryRecord(
        id: Int32,
        scope: MemoryScope = .longTerm,
        kind: MemoryKind = .project,
        pinned: Bool = false,
        archived: Bool = false,
        supersedes: [Int32] = [],
        updatedAt: Int64
    ) -> MemoryRecord {
        MemoryRecord(
            id: id,
            content: "memory-\(id)",
            scope: scope,
            kind: kind,
            assistantId: "__long_term__",
            sourceConversationId: "conv-1",
            sourceMessageIds: ["m1"],
            supersedesIds: supersedes.map { KotlinInt(value: $0) },
            expiresAt: nil,
            confidence: 1,
            pinned: pinned,
            archived: archived,
            createdAt: 1,
            updatedAt: updatedAt,
            lastUsedAt: nil,
            topicTitle: kind == .topic ? "topic" : nil,
            memberIds: [],
            lastReinforcedAt: nil
        )
    }
}
