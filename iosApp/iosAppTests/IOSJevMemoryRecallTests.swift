import XCTest
@preconcurrency import Shared
@testable import iosApp

// IOSJevMemoryRecallTests：硬筛选先于外发、orderedSelection 组装（强保留 +
// 预算）、一次计算选中集合（注入与 IDs 共用）、turnKey 失效语义、shadow 不影
// 响注入、off 零网络、fallback 保持同步原行为。

@MainActor
final class IOSJevMemoryRecallTests: XCTestCase {

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: IOSJevSettings.productionEndpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func scorePayload(_ answers: [String: Double]) -> Data {
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": answers.mapValues { ["type": "score", "score": $0] },
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func makeSettings(mode: IOSJevMode, pinned: String? = "jev-fixed-v1") -> IOSJevSettings {
        var settings = IOSJevSettings()
        settings.setMode(mode, for: .memoryRecall)
        settings.pinnedModelVersion = pinned
        return settings
    }

    private func makeService(
        settings: IOSJevSettings,
        transport: JevStubTransport
    ) -> IOSJevMemoryRecallService {
        let box = SettingsBox(settings)
        let coordinator = IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport),
            settingsProvider: { box.get() },
            apiKeyProvider: { "test-key" },
            now: { Date() }
        ))
        return IOSJevMemoryRecallService(coordinator: coordinator, settingsProvider: { box.get() })
    }

    private final class SettingsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: IOSJevSettings
        init(_ value: IOSJevSettings) { self.value = value }
        func get() -> IOSJevSettings { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func userMessage(text: String) -> UIMessage {
        UIMessage.companion.user(prompt: text)
    }

    private let runtime = JevTestRuntimeFactory.makeRuntime()

    /// 测试专用 runtime 构造（KMP 类型无导出无参 init）。
    private enum JevTestRuntimeFactory {
        static func makeRuntime(
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
    }

    private func identity(turn: String = "t1") -> IOSJevMemoryRecallService.RunIdentity {
        .init(runId: "run-\(turn)")
    }

    // MARK: orderedSelection

    func testOrderedSelectionKeepsHighScoresAndDropsLowScores() {
        let records = JevFixtures.makeRecords().filter { [3, 9, 15].contains(Int($0.id)) }
        let decision = IOSJevDecision(
            answers: [
                IOSJevAnswer(id: "m3", type: "score", score: 0.95),
                IOSJevAnswer(id: "m9", type: "score", score: 0.5),
                IOSJevAnswer(id: "m15", type: "score", score: 0.1),
            ],
            usage: nil, modelVersion: "jev-latest", latencyMs: 10, requestBytes: 0, responseBytes: 0
        )
        let ordered = IOSJevMemoryRecallService.orderedSelection(
            eligible: records,
            candidates: records,
            decision: decision,
            minScore: 0.34,
            queryText: "项目",
            now: JevFixtures.memoryNow
        )
        XCTAssertEqual(ordered.map { Int($0.id) }, [3, 9], "only score >= minScore survives, in score order")
    }

    func testOrderedSelectionAlwaysKeepsPinnedAndCore() {
        // 30 置顶、5 核心过敏、14 低分注入文本（非强保留 → 不保留）。
        let records = JevFixtures.makeRecords().filter { [30, 5, 14, 15].contains(Int($0.id)) }
        let decision = IOSJevDecision(
            answers: [IOSJevAnswer(id: "m15", type: "score", score: 0.9)],
            usage: nil, modelVersion: "jev-latest", latencyMs: 10, requestBytes: 0, responseBytes: 0
        )
        let ordered = IOSJevMemoryRecallService.orderedSelection(
            eligible: records,
            candidates: records,
            decision: decision,
            minScore: 0.34,
            queryText: "咖啡",
            now: JevFixtures.memoryNow
        )
        // 强保留（pinned 30、core 5）即使零分也在；15 高分在；14 零分非强保留淘汰。
        let ids = Set(ordered.map { Int($0.id) })
        XCTAssertTrue(ids.contains(30), "pinned must be retained")
        XCTAssertTrue(ids.contains(5), "core must be retained")
        XCTAssertTrue(ids.contains(15), "high score must be retained")
        XCTAssertFalse(ids.contains(14), "zero-score non-resident memory must be dropped")
    }

    func testOrderedSelectionAppendsTopicsWithoutScoring() {
        var topic = JevFixtures.makeRecord(JevFixtures.memories[0])
        topic = topic.doCopy(
            id: topic.id, content: "主题：咖啡相关记忆汇总", scope: topic.scope,
            kind: MemoryKind.topic, assistantId: topic.assistantId,
            sourceConversationId: topic.sourceConversationId,
            sourceMessageIds: topic.sourceMessageIds,
            supersedesIds: topic.supersedesIds, expiresAt: topic.expiresAt,
            confidence: topic.confidence, pinned: topic.pinned, archived: topic.archived,
            createdAt: topic.createdAt, updatedAt: topic.updatedAt,
            lastUsedAt: topic.lastUsedAt, topicTitle: "咖啡", memberIds: topic.memberIds
        )
        let decision = IOSJevDecision(answers: [], usage: nil, modelVersion: "m", latencyMs: 0, requestBytes: 0, responseBytes: 0)
        let ordered = IOSJevMemoryRecallService.orderedSelection(
            eligible: [topic],
            candidates: [],
            decision: decision,
            minScore: 0.5,
            queryText: "咖啡",
            now: JevFixtures.memoryNow
        )
        XCTAssertEqual(ordered.map { Int($0.id) }, [Int(topic.id)], "topic rows keep their mid-tier eligibility")
    }

    // MARK: Builder consumes ordered selection

    func testContextPromptResultWithOrderedSelectionHonorsBudgets() {
        let records = JevFixtures.makeRecords()
        let ordered = Array(records.prefix(30))
        let runtime = JevTestRuntimeFactory.makeRuntime(maxItems: 5, maxPromptChars: 12_000)
        let result = ChatMemoryContextBuilder.contextPromptResult(
            records: records,
            runtime: runtime,
            queryText: "任意",
            orderedSelection: ordered
        )
        XCTAssertEqual(result.records.count, 5, "maxItems budget must apply to ordered selection")
        XCTAssertEqual(result.records.map { Int($0.id) }, ordered.prefix(5).map { Int($0.id) })
        XCTAssertTrue(result.prompt?.contains("memory_id=") ?? false)
    }

    func testContextPromptResultOrderedSelectionDropsArchivedSnapshot() {
        // 外部排序里混入已归档记录（快照期间被归档）→ 组装时过滤。
        var archived = JevFixtures.makeRecord(JevFixtures.memories[1])
        archived = archived.doCopy(
            id: archived.id, content: archived.content, scope: archived.scope,
            kind: archived.kind, assistantId: archived.assistantId,
            sourceConversationId: archived.sourceConversationId,
            sourceMessageIds: archived.sourceMessageIds,
            supersedesIds: archived.supersedesIds, expiresAt: archived.expiresAt,
            confidence: archived.confidence, pinned: archived.pinned, archived: true,
            createdAt: archived.createdAt, updatedAt: archived.updatedAt,
            lastUsedAt: archived.lastUsedAt, topicTitle: archived.topicTitle, memberIds: archived.memberIds
        )
        // 合法集合按归档状态排除 id 2（fixture 本体 archived=false，测试里单独移除）。
        let eligible = JevFixtures.makeRecords().filter { Int($0.id) != 2 }
        let result = ChatMemoryContextBuilder.contextPromptResult(
            records: eligible,
            runtime: runtime,
            queryText: "猫",
            orderedSelection: [archived]
        )
        XCTAssertFalse(result.records.contains { $0.id == archived.id })
    }

    // MARK: turnKey invalidation

    func testTurnKeyChangesOnUserMessageRevisionAndFingerprint() {
        let records = JevFixtures.makeRecords()
        let messages1 = [userMessage(text: "你好")]
        let messages2 = [userMessage(text: "你好")]
        let key1 = IOSJevMemoryRecallService.turnKey(messages: messages1, eligible: records, settingsRevision: 1)
        let key2 = IOSJevMemoryRecallService.turnKey(messages: messages2, eligible: records, settingsRevision: 1)
        XCTAssertNotEqual(key1, key2, "new user message (steer) must change turnKey")

        let key3 = IOSJevMemoryRecallService.turnKey(messages: messages1, eligible: records, settingsRevision: 2)
        XCTAssertNotEqual(key1, key3, "config revision change must change turnKey")

        var bumped = records
        bumped[0] = bumped[0].doCopy(
            id: bumped[0].id, content: "内容更新", scope: bumped[0].scope,
            kind: bumped[0].kind, assistantId: bumped[0].assistantId,
            sourceConversationId: bumped[0].sourceConversationId,
            sourceMessageIds: bumped[0].sourceMessageIds,
            supersedesIds: bumped[0].supersedesIds, expiresAt: bumped[0].expiresAt,
            confidence: bumped[0].confidence, pinned: bumped[0].pinned, archived: bumped[0].archived,
            createdAt: bumped[0].createdAt, updatedAt: bumped[0].updatedAt + 1,
            lastUsedAt: bumped[0].lastUsedAt, topicTitle: bumped[0].topicTitle, memberIds: bumped[0].memberIds
        )
        let key4 = IOSJevMemoryRecallService.turnKey(messages: messages1, eligible: bumped, settingsRevision: 1)
        XCTAssertNotEqual(key1, key4, "record content change must change turnKey")
    }

    // MARK: Full flow (active)

    func testActiveFlowComputesSharedSelectionOnce() async {
        let transport = JevStubTransport { _ in
            (self.scorePayload([
                "m3": 2.5, "m9": 0.2, "m15": 2.0, "m40": 1.5,
            ]), self.httpResponse(status: 200))
        }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let messages = [userMessage(text: "帮我准备项目 Alpha 的周报")]
        let selection = await service.prepareTurnSelection(
            messages: messages,
            records: JevFixtures.makeRecords(),
            runtime: runtime,
            identity: identity()
        )
        XCTAssertGreaterThan(transport.calls, 0)
        let ids = selection?.records.map { Int($0.id) } ?? []
        // 高分记忆进入集合；低分不进。
        XCTAssertTrue(ids.contains(3))
        XCTAssertFalse(ids.contains(9))

        // 工具循环同轮复用：再次 prepare 不发起新请求、返回同一集合。
        let second = await service.prepareTurnSelection(
            messages: messages,
            records: JevFixtures.makeRecords(),
            runtime: runtime,
            identity: identity()
        )
        XCTAssertEqual(transport.calls, 1, "same turn must reuse the cached selection")
        XCTAssertEqual(second?.records.map(\.id), selection?.records.map(\.id))

        // 注入与 usage marking 经 override 共用同一份：metadata ids 一致。
        let builder = ChatRuntimeContextBuilder(
            sharedSettings: makeSettingsStore(),
            mcpTools: [],
            miniAppRepository: makeMiniAppRepository(),
            miniAppRuntimeEnabled: false
        )
        let viaBuilder = builder.memoryRecallResult(for: messages, override: selection)
        XCTAssertEqual(viaBuilder.ids, selection?.ids)
    }

    func testOffFlowMakesZeroNetworkCallsAndNoSelection() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .off, pinned: nil), transport: transport)
        let messages = [userMessage(text: "你好")]
        let selection = await service.prepareTurnSelection(
            messages: messages,
            records: JevFixtures.makeRecords(),
            runtime: runtime,
            identity: identity()
        )
        XCTAssertEqual(transport.calls, 0)
        XCTAssertNil(selection)
    }

    func testShadowDoesNotApplySelection() async {
        let transport = JevStubTransport { _ in (self.scorePayload(["m3": 0.9]), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .shadow, pinned: nil), transport: transport)
        let messages = [userMessage(text: "你好")]
        let selection = await service.prepareTurnSelection(
            messages: messages,
            records: JevFixtures.makeRecords(),
            runtime: runtime,
            identity: identity()
        )
        XCTAssertNil(selection)
    }

    func testFallbackOnNetworkFailureKeepsSyncPath() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 500)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let messages = [userMessage(text: "你好")]
        let selection = await service.prepareTurnSelection(
            messages: messages,
            records: JevFixtures.makeRecords(),
            runtime: runtime,
            identity: identity()
        )
        XCTAssertNil(selection)
    }

    func testScopeNotAllowedSkipsNetwork() async {
        var settings = makeSettings(mode: .active)
        settings.setScopes([.selectedTaskText], for: .memoryRecall) // 缺 personalMemory
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(settings: settings, transport: transport)
        let messages = [userMessage(text: "你好")]
        let selection = await service.prepareTurnSelection(
            messages: messages,
            records: JevFixtures.makeRecords(),
            runtime: runtime,
            identity: identity()
        )
        XCTAssertEqual(transport.calls, 0)
        XCTAssertNil(selection)
    }

    // MARK: Frozen eval set（基线不得由 Jev 自评）

    func testFrozenEvalCasesBaselineViaSyncPath() {
        // 同步基线：验证冻结集在原行为下可运行并统计命中（基线缺口如实记录，
        // 不为达标改金标准；弱词面 forbidden 属于 Jev 评估口径，不在基线断言）。
        let records = ChatMemoryContextBuilder.recordsForPrompt(
            records: JevFixtures.makeRecords(),
            runtime: runtime
        )
        var fullHits = 0
        var total = 0
        for evalCase in JevFixtures.memoryFrozenCases {
            total += 1
            let result = ChatMemoryContextBuilder.contextPromptResult(
                records: records,
                runtime: runtime,
                queryText: evalCase.query,
                now: JevFixtures.memoryNow
            )
            let found = Set(result.records.map(\.id))
            // 硬筛选禁止项：过期（29）与归档（27）在任何路径都不得注入。
            for forbidden in evalCase.forbidden {
                let fixture = JevFixtures.memories.first { $0.id == forbidden }!
                if fixture.archived || (fixture.expiresAt.map { $0 <= JevFixtures.memoryNow } ?? false) {
                    XCTAssertFalse(found.contains(forbidden), "hard-filtered id \(forbidden) must never be injected")
                }
            }
            if evalCase.mustKeep.allSatisfy(found.contains) {
                fullHits += 1
            }
        }
        print("[Jev Phase 1 baseline] memory frozen cases full-hit: \(fullHits)/\(total)")
        XCTAssertEqual(total, JevFixtures.memoryFrozenCases.count)
    }

    // MARK: Test helpers

    private func makeSettingsStore() -> IOSSharedSettingsStore {
        IOSSharedSettingsStore(userDefaults: UserDefaults(suiteName: "IOSJevMemoryRecallTests-\(UUID().uuidString)")!)
    }

    private func makeMiniAppRepository() -> IOSMiniAppRepository {
        IOSMiniAppRepository(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("JevMemTests-\(UUID().uuidString)"),
            seedOnMissingStore: false
        )
    }
}
