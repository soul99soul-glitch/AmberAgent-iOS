import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSMemoryCorrectionTests: XCTestCase {
    func testEvidenceReadsUserOriginalFromSealedEpisodeOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IOSConversationStore(baseDirectory: root.appendingPathComponent("conversations"))
        await store.bootstrap()
        let user = UIMessage.companion.user(prompt: "我已经不再使用旧主机了。")
        let answer = UIMessage.companion.assistant(prompt: "助手声称的内容不能作为用户事实")
        _ = await store.saveCurrent(messages: [user, answer])
        let id = try XCTUnwrap(store.currentConversation?.id.toHexDashString())
        let episodes = ChatEpisodeStore(baseDirectoryURL: root.appendingPathComponent("episodes"))
        _ = episodes.sealCurrentEpisodeIfNeeded(conversationId: id, messages: [user, answer], reason: .manualNewTopic, nowMillis: 300)
        let activeUser = UIMessage.companion.user(prompt: "尚未归档的话题不在此次对照范围。")
        _ = await store.saveCurrent(messages: [user, answer, activeUser])
        let sources = await IOSMemoryCorrection.evidence(conversations: store, episodes: episodes)
        XCTAssertEqual(sources.map(\.messageId), [user.id.toHexDashString()])
        XCTAssertEqual(sources.first?.text, user.toText())
        await episodes.flushPendingWritesForTesting()
    }

    func testOnlyNewVerbatimEvidenceArchivesAndCuratedFactsNeedReview() throws {
        let original = IosMemoryFactory.shared.snapshotRecords()
        defer { IosMemoryFactory.shared.replaceAll(records: original) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = IOSMemoryPersistence(fileURL: root.appendingPathComponent("memories.json"))
        persistence.load()
        let snapshot = [record(1), record(2, pinned: true), record(3, scope: .core), record(4), record(5)]
        IosMemoryFactory.shared.replaceAll(records: snapshot)
        XCTAssertTrue(persistence.persist(previousRecords: []))
        let suite = "MemoryCorrection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        settings.restoreSnapshot(IosSettingsMutations.shared.setMemoryRuntimeEnabled(
            settings: settings.snapshot, enableCoreMemory: true, enableShortTermMemory: true, enableLongTermMemory: true))
        let quote = "我已经不再使用旧主机了。"
        let evidence = [IOSMemoryCorrectionEvidence(conversationId: "c", episodeId: "ep_0001", messageId: "u", text: quote, timestamp: 200)]
        let proposals = [1, 2, 3].map { IOSMemoryCorrectionProposal(memoryId: Int32($0), messageId: "u", quote: quote, reason: "后来明确停止使用", kind: "outdated") }
            + [IOSMemoryCorrectionProposal(memoryId: 4, messageId: "u", quote: "模型编造的新说法", reason: "猜测", kind: "contradicted"),
               IOSMemoryCorrectionProposal(memoryId: 5, messageId: "u", quote: quote, reason: "旧快照", kind: "outdated")]
        // Concurrent user edit must win over the captured snapshot.
        _ = IosMemoryFactory.shared.updateRecord(record: record(5, updatedAt: 300))
        let outcome = try IOSMemoryCorrection.apply(proposals, snapshot: snapshot, evidence: evidence,
                                                   runtime: settings.agentRuntime, persistence: persistence, now: 400)
        XCTAssertEqual(outcome.archived, 1)
        XCTAssertEqual(outcome.review, 2)
        XCTAssertTrue(persistence.records.first { $0.id == 1 }!.archived)
        for id: Int32 in [2, 3, 4, 5] { XCTAssertFalse(persistence.records.first { $0.id == id }!.archived) }
        XCTAssertEqual(persistence.events.records.filter { $0.type == MemoryEventType.memoryArchived.wireName }.count, 1)
        let reviews = persistence.events.records.compactMap { try? JSONDecoder().decode(IOSMemoryCorrectionReview.self, from: Data($0.message.utf8)) }
        XCTAssertEqual(reviews.filter { $0.decision == "needs_user_review" }.count, 2)
        let reloaded = IOSMemoryEventStore(directory: root)
        XCTAssertEqual(reloaded.records.count, 4)
        XCTAssertEqual(reloaded.records.first?.event?.conversationId, "c")
        XCTAssertNotNil(IosMemoryFactory.shared.restoreMemory(id: 1, now: 500))
        XCTAssertTrue(persistence.persist(previousRecords: persistence.records))
        XCTAssertFalse(persistence.records.first { $0.id == 1 }!.archived)
        XCTAssertEqual(try IOSMemoryCorrection.apply(proposals, snapshot: snapshot, evidence: evidence,
                                                     runtime: settings.agentRuntime, persistence: persistence, now: 600).archived, 0)
    }

    func testEarlierUserWordsDoNotInvalidateNewerFact() throws {
        let original = IosMemoryFactory.shared.snapshotRecords()
        defer { IosMemoryFactory.shared.replaceAll(records: original) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = IOSMemoryPersistence(fileURL: root.appendingPathComponent("memories.json"))
        persistence.load()
        IosMemoryFactory.shared.replaceAll(records: [record(1)])
        XCTAssertTrue(persistence.persist(previousRecords: []))
        let runtime = IOSSharedSettingsStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!).agentRuntime
        let proposal = IOSMemoryCorrectionProposal(memoryId: 1, messageId: "u", quote: "我已不再使用旧主机。", reason: "旧话", kind: "outdated")
        let source = IOSMemoryCorrectionEvidence(conversationId: "c", episodeId: "ep_0001", messageId: "u", text: proposal.quote, timestamp: 50)
        let result = try IOSMemoryCorrection.apply([proposal], snapshot: persistence.records, evidence: [source],
                                                  runtime: runtime, persistence: persistence, now: 400)
        XCTAssertEqual(result.archived, 0)
        XCTAssertTrue(persistence.events.records.isEmpty)
    }

    private func record(_ id: Int32, scope: MemoryScope = .longTerm, pinned: Bool = false, updatedAt: Int64 = 100) -> MemoryRecord {
        MemoryRecord(id: id, content: "用户还在使用旧主机", scope: scope, kind: .project,
                     assistantId: "__long_term__", sourceConversationId: "c", sourceMessageIds: ["earlier"],
                     supersedesIds: [], expiresAt: nil, confidence: 1, pinned: pinned, archived: false,
                     createdAt: 1, updatedAt: updatedAt, lastUsedAt: nil, topicTitle: nil, memberIds: [], lastReinforcedAt: nil)
    }
}
