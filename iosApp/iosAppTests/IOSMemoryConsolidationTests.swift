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

    // MARK: 短期记忆生命周期场景
    // "久未修改"不等于"长期有效"：只有记录满 14 天后仍被模型引用或被用户复述的
    // 短期记忆才升为长期；30 天内既未被注入也未被强化的短期记忆归档（可追溯，
    // 不删除）。置顶记录与缺少创建时间的旧数据不参与自动迁移。
    func testShortTermLifecyclePromotesOnlyReinforcedAndArchivesUnused() {
        let day: Int64 = 24 * 60 * 60 * 1_000
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        IosMemoryFactory.shared.replaceAll(records: [
            record(id: 1, content: "旧项目用 React", scope: .shortTerm, updatedAt: now - 31 * day),
            record(id: 2, content: "当前项目用 Vue", scope: .shortTerm, updatedAt: now - 20 * day,
                   lastReinforcedAt: now - 2 * day),
            record(id: 3, content: "本周在改登录页", scope: .shortTerm, updatedAt: now - 10 * day,
                   lastReinforcedAt: now - 9 * day),
            record(id: 4, content: "仓库托管在 GitHub", scope: .shortTerm, updatedAt: now - 40 * day,
                   lastUsedAt: now - 3 * day),
            record(id: 5, content: "置顶的项目约定", scope: .shortTerm, updatedAt: now - 60 * day, pinned: true),
            record(id: 6, content: "缺少创建时间的旧数据", scope: .shortTerm, updatedAt: 0),
            record(id: 7, content: "两周前写的项目上下文", scope: .shortTerm, updatedAt: now - 15 * day),
        ])

        let outcome = coordinator().performMaintenance(nowMillis: now)

        let byId = Dictionary(uniqueKeysWithValues: IosMemoryFactory.shared.getAllRecords().map { ($0.id, $0) })
        XCTAssertEqual(outcome.promotedToLongTerm, 1)
        XCTAssertEqual(outcome.archivedUnused, 1)
        XCTAssertEqual(byId[1]?.archived, true, "30 天无使用的短期记忆归档")
        XCTAssertEqual(byId[1]?.scope, .shortTerm, "归档不得顺带升级")
        XCTAssertEqual(byId[2]?.scope, .longTerm, "记录 14 天后仍被强化 → 升为长期")
        XCTAssertEqual(byId[2]?.assistantId, IosMemoryFactory.shared.LONG_TERM_MEMORY_ID)
        for id: Int32 in [3, 4, 5, 6, 7] {
            XCTAssertEqual(byId[id]?.scope, .shortTerm, "记录 \(id) 不应升级")
            XCTAssertEqual(byId[id]?.archived, false, "记录 \(id) 不应归档")
        }
    }

    // 有显式有效期的短期记忆交给过期规则；用户近期编辑过（updatedAt 新）视为仍在使用；
    // 缺 createdAt 但有 updatedAt 的旧数据按 updatedAt 计龄。
    func testUnusedArchiveSparesFutureExpiryAndRecentEdits() {
        let day: Int64 = 24 * 60 * 60 * 1_000
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        IosMemoryFactory.shared.replaceAll(records: [
            record(id: 1, content: "12 月去东京", scope: .shortTerm, updatedAt: now - 40 * day, expiresAt: now + 20 * day),
            record(id: 2, content: "项目改名为 Amber", scope: .shortTerm, updatedAt: now - day, createdAt: now - 40 * day),
            record(id: 3, content: "只有修改时间的旧数据", scope: .shortTerm, updatedAt: now - 40 * day, createdAt: 0),
        ])

        let outcome = coordinator().performMaintenance(nowMillis: now)

        let byId = Dictionary(uniqueKeysWithValues: IosMemoryFactory.shared.getAllRecords().map { ($0.id, $0) })
        XCTAssertEqual(outcome.archivedUnused, 1)
        XCTAssertEqual(byId[1]?.archived, false, "有效期未到，不按久未使用归档")
        XCTAssertEqual(byId[2]?.archived, false, "用户近期编辑视为仍在使用")
        XCTAssertEqual(byId[3]?.archived, true)
    }

    // 久未使用归档是新增的破坏性动作：短期记忆开关关闭（期间不注入、无法积累使用信号）
    // 或记忆写入权限关闭时不得执行。
    func testUnusedArchiveRespectsShortTermSwitchAndWritePermission() async throws {
        try await withSettingsFixture { f in
            f.settings.setMemoryDreamSettings(maintenanceEnabled: true, modelEnabled: false)
            let day: Int64 = 24 * 60 * 60 * 1_000
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            IosMemoryFactory.shared.replaceAll(records: [
                record(id: 1, content: "旧项目用 React", scope: .shortTerm, updatedAt: now - 40 * day),
            ])
            @MainActor func makeCoordinator(writable: Bool) -> IOSMemoryConsolidationCoordinator {
                let coordinator = IOSMemoryConsolidationCoordinator(
                    defaults: f.defaults, persistence: f.persistence, audit: f.audit,
                    environment: { (true, true, true) }
                )
                coordinator.configure(settings: f.settings, writesEnabled: { writable })
                return coordinator
            }
            @MainActor func archived() -> Bool? { IosMemoryFactory.shared.getAllRecords().first?.archived }

            f.settings.setMemoryRuntimeEnabled(shortTerm: false)
            await makeCoordinator(writable: true).run()
            XCTAssertEqual(archived(), false, "短期记忆关闭期间不得归档")

            f.settings.setMemoryRuntimeEnabled(shortTerm: true)
            await makeCoordinator(writable: false).run()
            XCTAssertEqual(archived(), false, "写入权限关闭时不得归档")

            await makeCoordinator(writable: true).run()
            XCTAssertEqual(archived(), true)
        }
    }

    // 去重合并不能丢掉败者的使用信号，否则会重置升级计时、提前触发久未使用归档。
    func testDuplicateMergeKeepsStrongestUsageSignals() {
        let day: Int64 = 24 * 60 * 60 * 1_000
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        IosMemoryFactory.shared.replaceAll(records: [
            record(id: 1, content: "当前项目用 Vue", scope: .shortTerm, updatedAt: now - 20 * day,
                   lastUsedAt: now - 3 * day, lastReinforcedAt: now - 2 * day),
            record(id: 2, content: "当前项目用 Vue", scope: .shortTerm, updatedAt: now - day),
        ])

        _ = coordinator().performMaintenance(nowMillis: now)

        let records = IosMemoryFactory.shared.getAllRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.createdAt, now - 20 * day)
        XCTAssertEqual(records.first?.lastUsedAt?.int64Value, now - 3 * day)
        XCTAssertEqual(records.first?.lastReinforcedAt?.int64Value, now - 2 * day)
        XCTAssertEqual(records.first?.scope, .longTerm, "合并后保留的强化信号使其满足升级条件")
    }

    // MARK: 用户画像与同义去重场景
    // 模型只确认候选对；较新的陈述保留、较旧的归档可恢复。画像条目只能引用
    // 偏好类来源，虚构 id 被剔除，被合并的 id 跟随到保留者；画像落盘可重载。
    // 再次运行时若画像仍准确且无候选对，不再调用模型。
    func testProfilePassMergesConfirmedDuplicatesAndCompilesProfile() async throws {
        try await withSettingsFixture { f in
            f.settings.setMemoryDreamSettings(maintenanceEnabled: false, modelEnabled: true)
            f.settings.setMemoryRuntimeEnabled(core: true, shortTerm: true, longTerm: true)
            let day: Int64 = 24 * 60 * 60 * 1_000
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            IosMemoryFactory.shared.replaceAll(records: [
                record(id: 1, content: "我习惯用中文交流。", updatedAt: now - 9 * day, kind: .user),
                record(id: 2, content: "回答尽量简短。", updatedAt: now - 8 * day, kind: .feedback),
                record(id: 3, content: "我喜欢深色模式。", updatedAt: now - 7 * day, kind: .user),
                record(id: 4, content: "当前项目使用 SwiftUI 开发", scope: .shortTerm, updatedAt: now - 6 * day, kind: .project),
                record(id: 5, content: "当前项目用 SwiftUI 开发", scope: .shortTerm, updatedAt: now - 2 * day, kind: .project),
            ])
            var profileCalls = 0
            let provider = TopicStubProvider { prompt in
                guard prompt.contains("duplicate_candidates") else { return #"{"topics":[]}"# }
                profileCalls += 1
                XCTAssertTrue(prompt.contains("\"id\":4") && prompt.contains("\"id\":5"), "近似对应提交给模型确认")
                let tooLong = String(repeating: "长", count: 200)
                return """
                {"profile":[
                  {"text":"用户用中文交流，偏好简短回答。","memoryIds":[1,2,999]},
                  {"text":"虚构条目","memoryIds":[999]},
                  {"text":"\(tooLong)","memoryIds":[3]},
                  {"text":"用户喜欢深色模式。","memoryIds":[3]}
                ],"duplicates":[[4,5],[1,3]]}
                """
            }
            let coordinator = IOSMemoryConsolidationCoordinator(
                defaults: f.defaults, persistence: f.persistence, audit: f.audit, provider: provider,
                environment: { (true, true, true) }
            )
            coordinator.configure(settings: f.settings)

            await coordinator.run()

            let byId = Dictionary(uniqueKeysWithValues: IosMemoryFactory.shared.getAllRecords().map { ($0.id, $0) })
            XCTAssertEqual(profileCalls, 1)
            XCTAssertEqual(byId[4]?.archived, true, "较旧的同义记录归档")
            XCTAssertEqual(byId[5]?.supersedesIds.map { Int(truncating: $0) }, [4])
            XCTAssertEqual(byId[1]?.archived, false, "未提交的对不得合并")
            XCTAssertEqual(byId[3]?.archived, false)

            let profile = try XCTUnwrap(f.persistence.profile)
            XCTAssertEqual(profile.items.map(\.text), ["用户用中文交流，偏好简短回答。", "用户喜欢深色模式。"])
            XCTAssertEqual(profile.items.first?.memoryIds, [1, 2])
            XCTAssertEqual(profile.coveredIds, [1, 2, 3])
            XCTAssertEqual(profile.sourceVersions["1"], byId[1]?.updatedAt)

            let reloaded = IOSMemoryPersistence(fileURL: f.memoryURL)
            reloaded.load()
            XCTAssertEqual(reloaded.profile, profile)

            await coordinator.run()
            XCTAssertEqual(profileCalls, 1, "画像仍准确且无候选对时不再调用模型")
        }
    }

    // 置顶/核心不参与自动合并；不同 kind 不配对；合并过又被用户恢复的一对不再配对。
    func testNearDuplicateCandidatesSkipCuratedMixedKindAndRestoredPairs() {
        var restoredWinner = record(id: 7, content: "当前项目用 SwiftUI 开发", scope: .shortTerm)
        restoredWinner = MemoryRecord(
            id: restoredWinner.id, content: restoredWinner.content, scope: restoredWinner.scope, kind: restoredWinner.kind,
            assistantId: restoredWinner.assistantId, sourceConversationId: nil, sourceMessageIds: [],
            supersedesIds: [KotlinInt(value: 8)], expiresAt: nil, confidence: 1, pinned: false, archived: false,
            createdAt: 1, updatedAt: 1, lastUsedAt: nil, topicTitle: nil, memberIds: [], lastReinforcedAt: nil
        )
        let records = [
            record(id: 1, content: "当前项目使用 SwiftUI 开发", scope: .shortTerm, pinned: true),
            record(id: 2, content: "当前项目用 SwiftUI 开发", scope: .longTerm, kind: .user),
            record(id: 3, content: "当前项目使用 SwiftUI 开发", scope: .longTerm, kind: .project),
            record(id: 4, content: "当前项目用 SwiftUI 开发了", scope: .core),
            record(id: 5, content: "当前项目使用 SwiftUI 开发", scope: .core),
            restoredWinner,
            record(id: 8, content: "当前项目使用 SwiftUI 开发", scope: .shortTerm),
        ]
        XCTAssertTrue(IOSMemoryConsolidationCoordinator.nearDuplicateCandidates(records, now: 100).isEmpty)
    }

    // 画像条目清洗换行与尖括号；引用的来源必须与条目有字面重叠；模型有意省略的来源
    // 记入已评估版本，下次不再因"未覆盖"重复调用模型。来源变化后画像文件立即删除。
    func testProfileItemsAreSanitizedSourcesMustOverlapAndOmissionsAreRemembered() async throws {
        try await withSettingsFixture { f in
            f.settings.setMemoryDreamSettings(maintenanceEnabled: false, modelEnabled: true)
            f.settings.setMemoryRuntimeEnabled(core: true, shortTerm: true, longTerm: true)
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            IosMemoryFactory.shared.replaceAll(records: [
                record(id: 1, content: "我习惯用中文交流。", updatedAt: now - 9_000, kind: .user),
                record(id: 2, content: "回答尽量简短。", updatedAt: now - 8_000, kind: .feedback),
                record(id: 3, content: "我喜欢深色模式。", updatedAt: now - 7_000, kind: .user),
            ])
            var calls = 0
            let provider = TopicStubProvider { prompt in
                guard prompt.contains("duplicate_candidates") else { return #"{"topics":[]}"# }
                calls += 1
                return #"{"profile":[{"text":"<b>用户</b>喜欢\n深色模式","memoryIds":[3,2]},{"text":"用户偏好简短回答","memoryIds":[2]}],"duplicates":[]}"#
            }
            let coordinator = IOSMemoryConsolidationCoordinator(
                defaults: f.defaults, persistence: f.persistence, audit: f.audit, provider: provider,
                environment: { (true, true, true) }
            )
            coordinator.configure(settings: f.settings)

            await coordinator.run()
            let profile = try XCTUnwrap(f.persistence.profile)
            XCTAssertEqual(profile.items.first?.text, "b用户/b喜欢 深色模式")
            XCTAssertEqual(profile.items.first?.memoryIds, [3], "与条目无字面重叠的 2 号被剔除")
            XCTAssertFalse(profile.coveredIds.contains(1))

            await coordinator.run()
            XCTAssertEqual(calls, 1, "被省略的 1 号已评估过，不再触发重算")

            let previous = IosMemoryFactory.shared.snapshotRecords()
            _ = IosMemoryFactory.shared.updateContent(id: 3, content: "我改用浅色模式了。")
            XCTAssertTrue(f.persistence.persist(previousRecords: previous))
            XCTAssertNil(f.persistence.profile, "来源变化后过期画像立即删除")
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: f.memoryURL.deletingLastPathComponent().appendingPathComponent("profile.json").path))
        }
    }

    func testNearDuplicateCandidatesStayWithinScopeAndSkipExactMatches() {
        let records = [
            record(id: 1, content: "当前项目使用 SwiftUI 开发", scope: .shortTerm),
            record(id: 2, content: "当前项目用 SwiftUI 开发", scope: .shortTerm),
            record(id: 3, content: "当前项目用 SwiftUI 开发", scope: .longTerm),
            record(id: 4, content: "当前项目用 SwiftUI 开发", scope: .longTerm),
            record(id: 5, content: "周末去爬山", scope: .shortTerm),
        ]
        let pairs = IOSMemoryConsolidationCoordinator.nearDuplicateCandidates(records, now: 100)
        XCTAssertEqual(pairs.map { [$0.0.id, $0.1.id] }, [[1, 2]], "跨 scope 不配对；完全相同交给确定性去重")
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
        let memoryURL: URL
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
        let memoryURL = root.appendingPathComponent("memories/memories.json")
        let persistence = IOSMemoryPersistence(fileURL: memoryURL)
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
                                       audit: IOSMemoryWriteAuditStore(userDefaults: defaults), memoryURL: memoryURL))
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
        sourceConversationId: String? = nil,
        pinned: Bool = false,
        lastUsedAt: Int64? = nil,
        lastReinforcedAt: Int64? = nil,
        createdAt: Int64? = nil,
        kind: MemoryKind = .note
    ) -> MemoryRecord {
        MemoryRecord(
            id: id,
            content: content,
            scope: scope,
            kind: kind,
            assistantId: scope == .shortTerm ? IosMemoryFactory.shared.SHORT_TERM_MEMORY_ID : IosMemoryFactory.shared.LONG_TERM_MEMORY_ID,
            sourceConversationId: sourceConversationId,
            sourceMessageIds: sourceMessageIds,
            supersedesIds: [],
            expiresAt: expiresAt.map { KotlinLong(value: $0) },
            confidence: 1,
            pinned: pinned,
            archived: archived,
            createdAt: createdAt ?? updatedAt,
            updatedAt: updatedAt,
            lastUsedAt: lastUsedAt.map { KotlinLong(value: $0) },
            topicTitle: nil,
            memberIds: [], lastReinforcedAt: lastReinforcedAt.map { KotlinLong(value: $0) }
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
            memberIds: memberIds.map { KotlinInt(value: $0) }, lastReinforcedAt: nil
        )
    }
}
