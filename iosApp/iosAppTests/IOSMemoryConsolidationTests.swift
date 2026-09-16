import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSMemoryConsolidationTests: XCTestCase {
    private nonisolated(unsafe) var original: [MemoryRecord] = []

    override func setUp() {
        super.setUp()
        original = IosMemoryFactory.shared.snapshotRecords()
        IosMemoryFactory.shared.replaceAll(records: [])
    }

    override func tearDown() {
        IosMemoryFactory.shared.replaceAll(records: original)
        super.tearDown()
    }

    func testExactDuplicatesMergeKeepingNewestWithProvenance() {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let older = record(id: 1, content: "喜欢冰美式。", scope: .longTerm, updatedAt: now - 5_000,
                           sourceMessageIds: ["m1"], sourceConversationId: "c1")
        let newer = record(id: 2, content: "喜欢冰美式。", scope: .longTerm, updatedAt: now - 1_000,
                           sourceMessageIds: ["m2"])
        let otherScope = record(id: 3, content: "喜欢冰美式。", scope: .core, updatedAt: now - 500)
        IosMemoryFactory.shared.replaceAll(records: [older, newer, otherScope])

        let outcome = coordinator().performMaintenance(nowMillis: now)

        XCTAssertEqual(outcome.mergedDuplicates, 1)
        let records = IosMemoryFactory.shared.getAllRecords()
        XCTAssertEqual(records.count, 2, "同范围重复合并，跨范围保留")
        let winner = records.first { $0.id == 2 }
        XCTAssertEqual(Set(winner?.sourceMessageIds ?? []), ["m1", "m2"])
        XCTAssertEqual(winner?.sourceConversationId, "c1")
        XCTAssertEqual(winner?.supersedesIds.map { Int(truncating: $0) }, [1])
    }

    func testExpiredRecordsArchiveNotDelete() {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let expired = record(id: 1, content: "临时事实", expiresAt: now - 1)
        let live = record(id: 2, content: "长期事实", expiresAt: now + 10_000)
        IosMemoryFactory.shared.replaceAll(records: [expired, live])

        let outcome = coordinator().performMaintenance(nowMillis: now)

        XCTAssertEqual(outcome.archivedExpired, 1)
        let records = IosMemoryFactory.shared.getAllRecords()
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.first { $0.id == 1 }?.archived == true)
        XCTAssertFalse(records.first { $0.id == 2 }?.archived == true)
    }

    func testStaleShortTermPromotesToLongTerm() {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let stale = record(id: 1, content: "持续项目上下文", scope: .shortTerm,
                           updatedAt: now - 15 * 24 * 60 * 60 * 1_000)
        let fresh = record(id: 2, content: "刚写的项目上下文", scope: .shortTerm,
                           updatedAt: now - 60_000)
        IosMemoryFactory.shared.replaceAll(records: [stale, fresh])

        let outcome = coordinator().performMaintenance(nowMillis: now)

        XCTAssertEqual(outcome.promotedToLongTerm, 1)
        let records = IosMemoryFactory.shared.getAllRecords()
        XCTAssertEqual(records.first { $0.id == 1 }?.scope, .longTerm)
        XCTAssertEqual(records.first { $0.id == 1 }?.assistantId, IosMemoryFactory.shared.LONG_TERM_MEMORY_ID)
        XCTAssertEqual(records.first { $0.id == 2 }?.scope, .shortTerm)
    }

    func testTopicMembersDropDeadIdsAndTopicsNeverMerge() {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let member = record(id: 2, content: "成员", scope: .longTerm)
        let archivedMember = record(id: 3, content: "已归档成员", scope: .longTerm, archived: true)
        let coreMember = record(id: 4, content: "核心成员", scope: .core)
        let grouped = topic(id: 9, memberIds: [2, 3, 4, 55])
        let duplicateTopic = topic(id: 10, memberIds: [2])
        IosMemoryFactory.shared.replaceAll(records: [member, archivedMember, coreMember, grouped, duplicateTopic])

        let outcome = coordinator().performMaintenance(nowMillis: now)

        XCTAssertEqual(outcome.mergedDuplicates, 0, "主题记录不参与重复合并")
        XCTAssertEqual(outcome.cleanedTopics, 2)
        XCTAssertEqual(outcome.retiredTopics, 2, "成员不足 2 条的主题被收起归档")
        let records = IosMemoryFactory.shared.getAllRecords()
        let groupedAfter = records.first { $0.id == 9 }
        XCTAssertEqual(groupedAfter?.memberIds.map { Int(truncating: $0) }, [2])
        XCTAssertTrue(groupedAfter?.archived == true)
        XCTAssertTrue(records.first { $0.id == 10 }?.archived == true)
        XCTAssertEqual(records.count, 5)
    }

    func testModelTopicPassUpsertsOnlyLiveMembers() async throws {
        try await withSettingsFixture { f in
            f.settings.setMemoryDreamSettings(maintenanceEnabled: false, modelEnabled: true)
            IosMemoryFactory.shared.replaceAll(records: [
                record(id: 1, content: "喜欢冰美式。", scope: .longTerm),
                record(id: 2, content: "常去手冲店。", scope: .longTerm),
                record(id: 3, content: "不相关事项", scope: .longTerm),
            ])
            var calls = 0
            let provider = TopicStubProvider { prompt in
                calls += 1
                XCTAssertTrue(prompt.contains("memories"))
                return """
                {"topics":[{"title":"咖啡偏好","summary":"都和咖啡有关","memberIds":[1,2,999]}]}
                """
            }
            let coordinator = IOSMemoryConsolidationCoordinator(
                defaults: f.defaults, persistence: f.persistence,
                audit: f.audit, provider: provider,
                environment: { (true, true, true) }
            )
            coordinator.configure(settings: f.settings)

            await coordinator.run()

            XCTAssertEqual(calls, 1)
            let topics = IosMemoryFactory.shared.getAllRecords().filter { $0.kind == .topic }
            XCTAssertEqual(topics.count, 1)
            XCTAssertEqual(topics.first?.topicTitle, "咖啡偏好")
            XCTAssertEqual(topics.first?.memberIds.map { Int(truncating: $0) }, [1, 2],
                           "不存在的成员 id 必须被过滤")
            XCTAssertEqual(f.audit.records.first?.action, "topic")
            XCTAssertTrue(f.persistence.records.contains { $0.kind == .topic })
        }
    }

    func testModelTopicPassStaysOffWhenOnlyMaintenanceEnabled() async throws {
        try await withSettingsFixture { f in
            f.settings.setMemoryDreamSettings(maintenanceEnabled: true, modelEnabled: false)
            IosMemoryFactory.shared.replaceAll(records: [
                record(id: 1, content: "喜欢冰美式。", scope: .longTerm),
                record(id: 2, content: "常去手冲店。", scope: .longTerm),
            ])
            var calls = 0
            let provider = TopicStubProvider { _ in
                calls += 1
                return #"{"topics":[{"title":"x","summary":"y","memberIds":[1,2]}]}"#
            }
            let coordinator = IOSMemoryConsolidationCoordinator(
                defaults: f.defaults, persistence: f.persistence,
                audit: f.audit, provider: provider,
                environment: { (true, true, true) }
            )
            coordinator.configure(settings: f.settings)

            await coordinator.run()

            XCTAssertEqual(calls, 0, "主题聚关闭时不得调用模型")
            XCTAssertTrue(IosMemoryFactory.shared.getAllRecords().allSatisfy { $0.kind != .topic })
        }
    }

    func testNoChangeReportsCleanAndSkipsPersist() async {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        IosMemoryFactory.shared.replaceAll(records: [record(id: 1, content: "正常记忆", updatedAt: now)])
        let suite = "MemoryConsolidation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let persistence = IOSMemoryPersistence(fileURL: root.appendingPathComponent("memories/memories.json"))
        persistence.load()
        let audit = IOSMemoryWriteAuditStore(userDefaults: defaults)
        let coordinator = IOSMemoryConsolidationCoordinator(
            defaults: defaults, persistence: persistence, audit: audit,
            environment: { (true, true, true) }
        )

        let outcome = coordinator.performMaintenance(nowMillis: now)
        XCTAssertFalse(outcome.changed)
    }

    @MainActor
    private struct SettingsFixture {
        let defaults: UserDefaults
        let settings: IOSSharedSettingsStore
        let persistence: IOSMemoryPersistence
        let audit: IOSMemoryWriteAuditStore
    }

    private func withSettingsFixture(_ body: @MainActor (SettingsFixture) async throws -> Void) async throws {
        let original = IosMemoryFactory.shared.snapshotRecords()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryDream-\(UUID().uuidString)")
        let suite = "MemoryDream-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            IosMemoryFactory.shared.replaceAll(records: original)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let persistence = IOSMemoryPersistence(fileURL: root.appendingPathComponent("memories/memories.json"))
        persistence.load()
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let model = Model(
            modelId: "dream-test", displayName: "主题测试", id: KotlinUuid.companion.random(),
            type: .chat, customHeaders: [], customBodies: [], inputModalities: [], outputModalities: [],
            abilities: [], tools: Set<BuiltInTools>(), contextWindowTokens: nil, providerOverwrite: nil
        )
        _ = settings.addProvider(ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(), enabled: true, name: "主题测试", models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""), builtIn: false,
            descriptionText: nil, shortDescriptionText: nil, apiKey: "test", baseUrl: "https://example.test",
            chatCompletionsPath: "/chat/completions", useResponseApi: false, authMode: .apiKey, brand: .generic
        ))
        settings.setCompressModelId(model.id.toHexDashString())
        try await body(SettingsFixture(defaults: defaults, settings: settings, persistence: persistence,
                                       audit: IOSMemoryWriteAuditStore(userDefaults: defaults)))
    }

    private final class TopicStubProvider: IOSAgentTextProvider, @unchecked Sendable {
        let response: @MainActor (String) async throws -> String
        init(_ response: @escaping @MainActor (String) async throws -> String) { self.response = response }
        func generateText(providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams) async throws -> MessageChunk {
            let text = try await response(messages.map { $0.toText() }.joined())
            return MessageChunk(id: "dream-test", model: "dream-test", choices: [
                UIMessageChoice(index: 0, delta: nil, message: UIMessage.companion.assistant(prompt: text), finishReason: "stop")
            ], usage: nil)
        }
    }

    private func coordinator() -> IOSMemoryConsolidationCoordinator {
        IOSMemoryConsolidationCoordinator(
            defaults: UserDefaults(suiteName: "MemoryConsolidationTests")!,
            persistence: IOSMemoryPersistence(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString).json")),
            audit: IOSMemoryWriteAuditStore(userDefaults: UserDefaults(suiteName: "MemoryConsolidationTests")!),
            environment: { (true, true, true) }
        )
    }

    private func record(
        id: Int32,
        content: String,
        scope: MemoryScope = .longTerm,
        updatedAt: Int64 = 1,
        expiresAt: Int64? = nil,
        archived: Bool = false,
        sourceMessageIds: [String] = [],
        sourceConversationId: String? = nil
    ) -> MemoryRecord {
        MemoryRecord(
            id: id,
            content: content,
            scope: scope,
            kind: .note,
            assistantId: scope == .shortTerm ? IosMemoryFactory.shared.SHORT_TERM_MEMORY_ID : IosMemoryFactory.shared.LONG_TERM_MEMORY_ID,
            sourceConversationId: sourceConversationId,
            sourceMessageIds: sourceMessageIds,
            supersedesIds: [],
            expiresAt: expiresAt.map { KotlinLong(value: $0) },
            confidence: 1,
            pinned: false,
            archived: archived,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            lastUsedAt: nil,
            topicTitle: nil,
            memberIds: []
        )
    }

    private func topic(id: Int32, memberIds: [Int32]) -> MemoryRecord {
        MemoryRecord(
            id: id,
            content: "摘要",
            scope: .longTerm,
            kind: .topic,
            assistantId: IosMemoryFactory.shared.LONG_TERM_MEMORY_ID,
            sourceConversationId: nil,
            sourceMessageIds: [],
            supersedesIds: [],
            expiresAt: nil,
            confidence: 1,
            pinned: false,
            archived: false,
            createdAt: 1,
            updatedAt: 1,
            lastUsedAt: nil,
            topicTitle: "主题 \(id)",
            memberIds: memberIds.map { KotlinInt(value: $0) }
        )
    }
}
