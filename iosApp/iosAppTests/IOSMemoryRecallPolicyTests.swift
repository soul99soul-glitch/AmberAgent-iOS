import XCTest
import Shared
@testable import iosApp

final class IOSMemoryRecallPolicyTests: XCTestCase {
    func testRecallFiltersAndBoundsDeterministically() {
        let records = [
            record(id: 2, content: "favorite color blue", scope: .core, kind: .user, updatedAt: 10),
            record(id: 1, content: "unrelated", scope: .longTerm, kind: .note, updatedAt: 20),
            record(id: 3, content: "blue project", scope: .longTerm, kind: .project, updatedAt: 5),
        ]
        let runtime = runtime(maxItems: 2, maxPromptChars: 120)
        let result = ChatMemoryContextBuilder.contextPromptResult(records: records, runtime: runtime, queryText: "blue", now: 100)
        XCTAssertEqual(result.records.map(\.id), [2, 3])
        XCTAssertLessThanOrEqual(result.records.count, Int(runtime.memoryRecall.maxItems))
    }

    // MARK: 时间感知场景
    // 记忆原文常含相对时间（"下周"）。注入行必须带记录日期、页眉带今天日期，
    // 模型才能把相对时间换算到记录当天，而不是当成今天说的话。

    func testInjectedMemoryCarriesRecordedDateAndTodayHeader() throws {
        let recorded = localMillis(2026, 9, 25)
        let today = localMillis(2026, 10, 2)
        let records = [
            record(id: 1, content: "我下周要去东京出差", scope: .longTerm, kind: .project,
                   createdAt: recorded, updatedAt: recorded),
        ]
        let result = ChatMemoryContextBuilder.contextPromptResult(
            records: records, runtime: runtime(maxItems: 10, maxPromptChars: 2_000),
            queryText: "东京出差", now: today
        )
        let prompt = try XCTUnwrap(result.prompt)
        XCTAssertTrue(prompt.contains("Today is 2026-10-02."), prompt)
        XCTAssertTrue(prompt.contains("- memory_id=1 [long_term/project] (recorded 2026-09-25) 我下周要去东京出差"), prompt)
    }

    func testExpiringMemoryShowsValidUntilDate() throws {
        let recorded = localMillis(2026, 9, 25)
        let records = [
            record(id: 2, content: "本周在上海出差", scope: .longTerm, kind: .project,
                   createdAt: recorded, updatedAt: recorded, expiresAt: localMidnight(2026, 10, 11)),
        ]
        let result = ChatMemoryContextBuilder.contextPromptResult(
            records: records, runtime: runtime(maxItems: 10, maxPromptChars: 2_000),
            queryText: "上海出差", now: localMillis(2026, 10, 2)
        )
        let prompt = try XCTUnwrap(result.prompt)
        // 抽取把 expiresOn 10-10 存成 10-11 0 点；注入要显示最后有效日 10-10。
        XCTAssertTrue(prompt.contains("(recorded 2026-09-25, until 2026-10-10) 本周在上海出差"), prompt)
    }

    func testUnknownCreationTimeOmitsRecordedDate() throws {
        let records = [record(id: 3, content: "旧版导入的记忆", scope: .core, kind: .user, createdAt: 0, updatedAt: 0)]
        let result = ChatMemoryContextBuilder.contextPromptResult(
            records: records, runtime: runtime(maxItems: 10, maxPromptChars: 2_000),
            queryText: "", now: localMillis(2026, 10, 2)
        )
        let prompt = try XCTUnwrap(result.prompt)
        XCTAssertTrue(prompt.contains("- memory_id=3 [core/user] 旧版导入的记忆"), prompt)
        XCTAssertFalse(prompt.contains("(recorded"), prompt)
    }

    private func localMidnight(_ year: Int, _ month: Int, _ day: Int) -> Int64 {
        let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
        return Int64(date.timeIntervalSince1970 * 1_000)
    }

    // MARK: 用户画像注入场景
    // 准确的画像替代它覆盖的记录逐条注入；被覆盖的记录仍计入注入集合（用量标记与
    // 引用白名单）。任一被覆盖记录变化后画像失效，回退逐条注入。
    func testFreshProfileReplacesCoveredRecordsAndStaleProfileFallsBack() throws {
        let records = [
            record(id: 1, content: "我习惯用中文交流。", scope: .longTerm, kind: .user, updatedAt: 10),
            record(id: 2, content: "回答尽量简短。", scope: .longTerm, kind: .feedback, updatedAt: 20),
            record(id: 3, content: "当前项目用 SwiftUI", scope: .longTerm, kind: .project, updatedAt: 30),
        ]
        let profile = IOSMemoryProfile(
            items: [.init(text: "用户用中文交流，偏好简短回答。", memoryIds: [1, 2])],
            sourceVersions: ["1": 10, "2": 20],
            generatedAt: 40
        )
        let fresh = ChatMemoryContextBuilder.contextPromptResult(
            records: records, runtime: runtime(maxItems: 10, maxPromptChars: 2_000),
            queryText: "SwiftUI 项目", now: 100, profile: profile
        )
        let freshPrompt = try XCTUnwrap(fresh.prompt)
        XCTAssertTrue(freshPrompt.contains("<user-profile>\n- 用户用中文交流，偏好简短回答。 (memory_id=1, 2)\n</user-profile>"), freshPrompt)
        XCTAssertFalse(freshPrompt.contains("我习惯用中文交流"), "被画像覆盖的记录不再逐条注入")
        XCTAssertTrue(freshPrompt.contains("当前项目用 SwiftUI"))
        XCTAssertEqual(Set(fresh.ids), [1, 2, 3])

        var edited = records
        edited[0] = record(id: 1, content: "我改成用英文交流。", scope: .longTerm, kind: .user, updatedAt: 50)
        let stale = ChatMemoryContextBuilder.contextPromptResult(
            records: edited, runtime: runtime(maxItems: 10, maxPromptChars: 2_000),
            queryText: "SwiftUI 项目", now: 100, profile: profile
        )
        let stalePrompt = try XCTUnwrap(stale.prompt)
        XCTAssertFalse(stalePrompt.contains("<user-profile>"), "来源变化后画像不得注入")
        XCTAssertTrue(stalePrompt.contains("我改成用英文交流"))
        XCTAssertTrue(stalePrompt.contains("回答尽量简短"))
    }

    // Jev 有序选择（含注入筛查）剔除的记录不能借画像回到 prompt：只有被覆盖
    // 记录全部被选中时才用画像。
    func testProfileUnderOrderedSelectionRequiresEveryCoveredRecordSelected() throws {
        let records = [
            record(id: 1, content: "我习惯用中文交流。", scope: .longTerm, kind: .user, updatedAt: 10),
            record(id: 2, content: "回答尽量简短。", scope: .longTerm, kind: .feedback, updatedAt: 20),
            record(id: 3, content: "当前项目用 SwiftUI", scope: .longTerm, kind: .project, updatedAt: 30),
        ]
        let profile = IOSMemoryProfile(
            items: [.init(text: "用户用中文交流，偏好简短回答。", memoryIds: [1, 2])],
            sourceVersions: ["1": 10, "2": 20], generatedAt: 40
        )
        let partial = ChatMemoryContextBuilder.contextPromptResult(
            records: records, runtime: runtime(maxItems: 10, maxPromptChars: 2_000), queryText: "",
            now: 100, orderedSelection: [records[0], records[2]], profile: profile
        )
        let partialPrompt = try XCTUnwrap(partial.prompt)
        XCTAssertFalse(partialPrompt.contains("<user-profile>"), "被筛掉的 2 号不能经画像注入")
        XCTAssertEqual(Set(partial.ids), [1, 3])

        let full = ChatMemoryContextBuilder.contextPromptResult(
            records: records, runtime: runtime(maxItems: 10, maxPromptChars: 2_000), queryText: "",
            now: 100, orderedSelection: records, profile: profile
        )
        XCTAssertTrue(try XCTUnwrap(full.prompt).contains("<user-profile>"))
        XCTAssertEqual(Set(full.ids), [1, 2, 3])
    }

    func testOversizedProfileIsIgnored() throws {
        let records = [record(id: 1, content: "我习惯用中文交流。", scope: .longTerm, kind: .user, updatedAt: 10)]
        let profile = IOSMemoryProfile(
            items: [.init(text: String(repeating: "长", count: 190), memoryIds: [1])],
            sourceVersions: ["1": 10], generatedAt: 20
        )
        let result = ChatMemoryContextBuilder.contextPromptResult(
            records: records, runtime: runtime(maxItems: 10, maxPromptChars: 300),
            queryText: "", now: 100, profile: profile
        )
        let prompt = try XCTUnwrap(result.prompt)
        XCTAssertFalse(prompt.contains("<user-profile>"), "画像超过一半预算时回退逐条注入")
        XCTAssertTrue(prompt.contains("我习惯用中文交流"))
    }

    // supersede 会产生已归档的旧版本：memory_tool list 不得把它与新版本并列，
    // 也不得编辑已归档记录（read 仍可读取并带 archived 标记，用于溯源）。
    @MainActor
    func testMemoryToolListHidesArchivedAndEditRejectsArchived() throws {
        let previousRecords = IosMemoryFactory.shared.snapshotRecords()
        defer { IosMemoryFactory.shared.replaceAll(records: previousRecords) }
        IosMemoryFactory.shared.replaceAll(records: [
            record(id: 1, content: "喜欢热美式。", scope: .longTerm, kind: .routine),
            record(id: 2, content: "我后来改成只喝冰美式了。", scope: .longTerm, kind: .routine),
        ])
        _ = IosMemoryFactory.shared.setArchived(id: 1, archived: true)
        let runtime = runtime()

        let listOutput = IOSMemoryToolExecutor.execute(input: #"{"action":"list"}"#, runtime: runtime, writePolicy: .allow)
        let editOutput = IOSMemoryToolExecutor.execute(
            input: #"{"action":"edit","id":1,"content":"改写旧版本"}"#, runtime: runtime, writePolicy: .allow
        )

        XCTAssertFalse(listOutput.contains("喜欢热美式"), listOutput)
        XCTAssertTrue(listOutput.contains("冰美式"), listOutput)
        XCTAssertTrue(editOutput.contains("memory is archived"), editOutput)
        XCTAssertEqual(IosMemoryFactory.shared.getAllRecords().first { $0.id == 1 }?.content, "喜欢热美式。")
    }

    private func localMillis(_ year: Int, _ month: Int, _ day: Int) -> Int64 {
        let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        return Int64(date.timeIntervalSince1970 * 1_000)
    }

    func testUnrelatedProjectAndReferenceAreNotAlwaysEligible() {
        let records = [
            record(id: 4, content: "project detail", scope: .longTerm, kind: .project),
            record(id: 5, content: "reference detail", scope: .longTerm, kind: .reference),
        ]
        let runtime = runtime(maxItems: 10, maxPromptChars: 500)
        let result = ChatMemoryContextBuilder.contextPromptResult(records: records, runtime: runtime, queryText: "unmatched", now: 100)
        XCTAssertTrue(result.records.isEmpty)
    }

    func testChineseRecallUsesTermsInsteadOfSingleCharacterOverlap() {
        let records = [
            record(
                id: 6,
                content: "我今天喝咖啡",
                scope: .longTerm,
                kind: .project
            ),
            record(
                id: 7,
                content: "用户喜欢苹果",
                scope: .longTerm,
                kind: .project
            ),
        ]
        let runtime = runtime(maxItems: 10, maxPromptChars: 500)

        let singleCharacterOnly = ChatMemoryContextBuilder.contextPromptResult(
            records: records,
            runtime: runtime,
            queryText: "我明天跑步",
            now: 100
        )
        let meaningfulTerm = ChatMemoryContextBuilder.contextPromptResult(
            records: records,
            runtime: runtime,
            queryText: "苹果怎么保存",
            now: 100
        )

        XCTAssertTrue(singleCharacterOnly.records.isEmpty)
        XCTAssertEqual(meaningfulTerm.records.map(\.id), [7])
    }

    func testSingleCharacterChineseQueryDoesNotRecallEveryUnrelatedMemory() {
        let records = [
            record(id: 11, content: "咖啡冲煮项目", scope: .longTerm, kind: .project),
            record(id: 12, content: "旅行参考资料", scope: .longTerm, kind: .reference),
        ]
        let runtime = runtime(maxItems: 10, maxPromptChars: 500)

        let result = ChatMemoryContextBuilder.contextPromptResult(
            records: records,
            runtime: runtime,
            queryText: "猫",
            now: 100
        )

        XCTAssertTrue(result.records.isEmpty)
    }

    func testFirstOversizedCandidateDoesNotBreakPromptBudget() {
        let records = [
            record(
                id: 8,
                content: "budget " + String(repeating: "x", count: 2_500),
                scope: .longTerm,
                kind: .project,
                updatedAt: 20
            ),
            record(
                id: 9,
                content: "budget short",
                scope: .longTerm,
                kind: .project,
                updatedAt: 10
            ),
        ]
        let runtime = runtime(maxItems: 10, maxPromptChars: 256)

        let result = ChatMemoryContextBuilder.contextPromptResult(
            records: records,
            runtime: runtime,
            queryText: "budget",
            now: 100
        )

        XCTAssertEqual(result.records.map(\.id), [9])
    }

    @MainActor
    func testApprovedEditAndDeleteRejectStaleMemoryVersion() throws {
        let previousRecords = IosMemoryFactory.shared.snapshotRecords()
        defer { IosMemoryFactory.shared.replaceAll(records: previousRecords) }
        let approved = record(
            id: 10,
            content: "approved preview",
            scope: .core,
            kind: .note,
            updatedAt: 10
        )
        IosMemoryFactory.shared.replaceAll(records: [approved])
        let editInput = #"{"action":"edit","id":10,"content":"model edit"}"#
        let deleteInput = #"{"action":"delete","id":10}"#
        let editPreview = try XCTUnwrap(IOSMemoryToolExecutor.approvalPreview(input: editInput))
        let deletePreview = try XCTUnwrap(IOSMemoryToolExecutor.approvalPreview(input: deleteInput))
        XCTAssertEqual(editPreview.expectedUpdatedAt, 10)
        XCTAssertEqual(deletePreview.expectedUpdatedAt, 10)

        let changed = record(
            id: approved.id,
            content: "user changed it",
            scope: approved.scope,
            kind: approved.kind,
            createdAt: approved.createdAt,
            updatedAt: 20
        )
        IosMemoryFactory.shared.replaceAll(records: [changed])
        let runtime = runtime()
        let editOutput = IOSMemoryToolExecutor.execute(
            input: editInput,
            runtime: runtime,
            writePolicy: .allow,
            expectedUpdatedAt: editPreview.expectedUpdatedAt
        )
        let deleteOutput = IOSMemoryToolExecutor.execute(
            input: deleteInput,
            runtime: runtime,
            writePolicy: .allow,
            expectedUpdatedAt: deletePreview.expectedUpdatedAt
        )

        XCTAssertTrue(editOutput.contains(#""code":"stale_memory""#), editOutput)
        XCTAssertTrue(deleteOutput.contains(#""code":"stale_memory""#), deleteOutput)
        XCTAssertEqual(IosMemoryFactory.shared.getAllRecords().first?.content, "user changed it")
    }

    @MainActor
    func testCreateAndEditRejectOutOfRangeSupersedesIdsWithoutMutation() {
        let previousRecords = IosMemoryFactory.shared.snapshotRecords()
        defer { IosMemoryFactory.shared.replaceAll(records: previousRecords) }
        let existing = record(id: 10, content: "unchanged", scope: .core, kind: .note, updatedAt: 10)
        IosMemoryFactory.shared.replaceAll(records: [existing])
        let runtime = runtime()

        let createOutput = IOSMemoryToolExecutor.execute(
            input: #"{"action":"create","scope":"core","kind":"note","content":"new","supersedesIds":[2147483648]}"#,
            runtime: runtime,
            writePolicy: .allow
        )
        let editOutput = IOSMemoryToolExecutor.execute(
            input: #"{"action":"edit","id":10,"content":"changed","supersedesIds":[-2147483649]}"#,
            runtime: runtime,
            writePolicy: .allow
        )
        let malformedOutput = IOSMemoryToolExecutor.execute(
            input: #"{"action":"create","content":"bad","supersedesIds":["not-an-integer"]}"#,
            runtime: runtime,
            writePolicy: .allow
        )

        XCTAssertTrue(createOutput.contains(#""code":"integer_out_of_range""#), createOutput)
        XCTAssertTrue(editOutput.contains(#""code":"integer_out_of_range""#), editOutput)
        XCTAssertTrue(malformedOutput.contains(#""code":"integer_out_of_range""#), malformedOutput)
        XCTAssertEqual(IosMemoryFactory.shared.getAllRecords().map(\.content), ["unchanged"])
    }

    @MainActor
    func testCreateAndEditRejectInvalidConfidenceWithoutMutation() {
        let previousRecords = IosMemoryFactory.shared.snapshotRecords()
        defer { IosMemoryFactory.shared.replaceAll(records: previousRecords) }
        let existing = record(id: 10, content: "unchanged", scope: .core, kind: .note, updatedAt: 10)
        IosMemoryFactory.shared.replaceAll(records: [existing])
        let runtime = runtime()

        let createOutput = IOSMemoryToolExecutor.execute(
            input: #"{"action":"create","scope":"core","kind":"note","content":"new","confidence":2}"#,
            runtime: runtime,
            writePolicy: .allow
        )
        let editOutput = IOSMemoryToolExecutor.execute(
            input: #"{"action":"edit","id":10,"content":"changed","confidence":-0.1}"#,
            runtime: runtime,
            writePolicy: .allow
        )
        let boolOutput = IOSMemoryToolExecutor.execute(
            input: #"{"action":"edit","id":10,"content":"changed","confidence":true}"#,
            runtime: runtime,
            writePolicy: .allow
        )

        XCTAssertTrue(createOutput.contains(#""error":"confidence must be a finite number from 0 to 1""#), createOutput)
        XCTAssertTrue(editOutput.contains(#""error":"confidence must be a finite number from 0 to 1""#), editOutput)
        XCTAssertTrue(boolOutput.contains(#""error":"confidence must be a finite number from 0 to 1""#), boolOutput)
        XCTAssertEqual(IosMemoryFactory.shared.getAllRecords().map(\.content), ["unchanged"])
        XCTAssertEqual(IosMemoryFactory.shared.getAllRecords().first?.confidence, 1)
    }

    func testTopicRecordsRankMidTierAndMatchOnTitle() {
        let records = [
            record(id: 1, content: "unrelated note", scope: .longTerm, kind: .note, updatedAt: 5),
            record(id: 2, content: "pinned 咖啡机", scope: .longTerm, kind: .note, pinned: true, updatedAt: 5),
            record(id: 3, content: "咖啡豆只买浅烘。", scope: .longTerm, kind: .note, updatedAt: 5),
            topicRecord(id: 9, title: "咖啡冲煮偏好", summary: "手冲为主，浅烘。", memberIds: [2, 3]),
        ]
        let runtime = runtime(maxItems: 10, maxPromptChars: 2_000)

        let matched = ChatMemoryContextBuilder.contextPromptResult(
            records: records,
            runtime: runtime,
            queryText: "咖啡",
            now: 100
        )
        // pinned(≥100) > 命中普通记录 > topic 固定中档(30)；id=1 无重叠被过滤。
        XCTAssertEqual(matched.records.map(\.id), [2, 3, 9])
        XCTAssertTrue(matched.prompt?.contains("[topic] 咖啡冲煮偏好") == true)

        let unmatched = ChatMemoryContextBuilder.contextPromptResult(
            records: records,
            runtime: runtime,
            queryText: "completely different",
            now: 100
        )
        XCTAssertEqual(unmatched.records.map(\.id), [2], "主题记录不参与 always-eligible 常驻")
    }

    @MainActor
    func testToolWritesRejectTopicRecords() throws {
        let previousRecords = IosMemoryFactory.shared.snapshotRecords()
        defer { IosMemoryFactory.shared.replaceAll(records: previousRecords) }
        IosMemoryFactory.shared.replaceAll(records: [
            topicRecord(id: 20, title: "主题", summary: "s", memberIds: [1]),
        ])
        let runtime = runtime()

        let editOutput = IOSMemoryToolExecutor.execute(
            input: #"{"action":"edit","id":20,"content":"改写"}"#,
            runtime: runtime,
            writePolicy: .allow
        )
        let deleteOutput = IOSMemoryToolExecutor.execute(
            input: #"{"action":"delete","id":20}"#,
            runtime: runtime,
            writePolicy: .allow
        )
        let createOutput = IOSMemoryToolExecutor.execute(
            input: #"{"action":"create","scope":"long_term","kind":"topic","content":"手动主题"}"#,
            runtime: runtime,
            writePolicy: .allow
        )

        XCTAssertTrue(editOutput.contains("managed automatically"), editOutput)
        XCTAssertTrue(deleteOutput.contains("managed automatically"), deleteOutput)
        XCTAssertTrue(createOutput.contains("invalid memory kind"), createOutput)
        XCTAssertEqual(IosMemoryFactory.shared.getAllRecords().first?.content, "s")
    }

    private func topicRecord(id: Int32, title: String, summary: String, memberIds: [Int32]) -> MemoryRecord {
        MemoryRecord(
            id: id,
            content: summary,
            scope: .longTerm,
            kind: .topic,
            assistantId: "__long_term__",
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
            topicTitle: title,
            memberIds: memberIds.map { KotlinInt(value: $0) }, lastReinforcedAt: nil
        )
    }

    private func runtime(
        maxItems: Int32 = 12,
        maxPromptChars: Int32 = 2_000
    ) -> AgentRuntimeSetting {
        let base = IosSettingsDefaults.shared.defaultSeededSettings().agentRuntime
        return AgentRuntimeSetting(
            enableCoreMemory: base.enableCoreMemory,
            enableShortTermMemory: base.enableShortTermMemory,
            enableLongTermMemory: base.enableLongTermMemory,
            enableRecentChatsReference: base.enableRecentChatsReference,
            enableTimeReminder: base.enableTimeReminder,
            agentSoulMarkdown: base.agentSoulMarkdown,
            operationPreviewMode: base.operationPreviewMode,
            generativeUi: base.generativeUi,
            enableLiveStatusNotification: base.enableLiveStatusNotification,
            hideSensitiveLiveStatus: base.hideSensitiveLiveStatus,
            liveMode: base.liveMode,
            maxToolLoopSteps: base.maxToolLoopSteps,
            autoApproveAllToolCalls: base.autoApproveAllToolCalls,
            autoApproveHighRiskToolCalls: base.autoApproveHighRiskToolCalls,
            terminalDefaultRuntime: base.terminalDefaultRuntime,
            terminalMaxConcurrentJobs: base.terminalMaxConcurrentJobs,
            terminalOutputTailChars: base.terminalOutputTailChars,
            terminalInstallTimeoutMs: base.terminalInstallTimeoutMs,
            feishuOfficeEnhancement: base.feishuOfficeEnhancement,
            todayBoard: base.todayBoard,
            miniApp: base.miniApp,
            contextCompaction: base.contextCompaction,
            memoryRecall: MemoryRecallSetting(
                maxItems: maxItems,
                maxPromptChars: maxPromptChars,
                debug: false
            ),
            memoryWorker: base.memoryWorker,
            subAgent: base.subAgent,
            modelCouncil: base.modelCouncil,
            externalFileAccess: base.externalFileAccess,
            harnessDebug: base.harnessDebug,
            speculativeToolExecution: base.speculativeToolExecution,
            generationRetry: base.generationRetry,
            keepGenerationAliveInBackground: base.keepGenerationAliveInBackground
        )
    }

    private func record(
        id: Int32,
        content: String,
        scope: MemoryScope,
        kind: MemoryKind,
        pinned: Bool = false,
        createdAt: Int64? = nil,
        updatedAt: Int64 = 0,
        lastUsedAt: Int64? = nil,
        expiresAt: Int64? = nil
    ) -> MemoryRecord {
        MemoryRecord(
            id: id,
            content: content,
            scope: scope,
            kind: kind,
            assistantId: scope == .longTerm ? "__long_term__" : "__global__",
            sourceConversationId: nil,
            sourceMessageIds: [],
            supersedesIds: [],
            expiresAt: expiresAt.map { KotlinLong(value: $0) },
            confidence: 1,
            pinned: pinned,
            archived: false,
            createdAt: createdAt ?? updatedAt,
            updatedAt: updatedAt,
            lastUsedAt: lastUsedAt.map { KotlinLong(value: $0) },
            topicTitle: nil,
            memberIds: [], lastReinforcedAt: nil
        )
    }
}
