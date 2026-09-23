import XCTest
@preconcurrency import Shared
@testable import iosApp

/// KMP RecallResult is not Sendable; test tasks cross the actor boundary with Void only.
@MainActor
private final class JevMemoryRecallResultBox {
    var value: ChatMemoryContextBuilder.RecallResult?
}

// IOSJevMemoryRecallTests：硬筛选先于外发、orderedSelection 组装（强保留 +
// 预算）、一次计算选中集合（注入与 IDs 共用）、turnKey 失效语义、shadow 不影
// 响注入、off 零网络、fallback 保持同步原行为。

@MainActor
final class IOSJevMemoryRecallTests: XCTestCase {

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: IOSJevSettings.productionEndpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func batchPayload(
        for request: URLRequest,
        scores: [String: Double],
        noul: [String: Double] = [:],
        includeNoulAnswers: Bool = true
    ) -> Data {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let questions = body?["questions"] as? [String: Any] ?? [:]
        var answers: [String: [String: Any]] = [:]
        for questionId in questions.keys {
            if questionId.hasPrefix("memory_recall.") {
                let id = String(questionId.dropFirst("memory_recall.".count))
                answers[questionId] = ["type": "score", "score": scores[id] ?? 0]
            } else if includeNoulAnswers, questionId.hasPrefix("memory_injection.") {
                let id = String(questionId.dropFirst("memory_injection.".count))
                answers[questionId] = ["type": "noul", "noul": noul[id] ?? 0]
            }
        }
        let payload: [String: Any] = ["model": "jev-latest", "answers": answers]
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
        let transport = JevStubTransport { request in
            (self.batchPayload(for: request, scores: [
                "m3": 2.5, "m9": 0.2, "m15": 2.0, "m40": 1.5,
            ], noul: ["inj3": 0.05]), self.httpResponse(status: 200))
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
        // 同一 user turn 只判断一次；后续模型步骤复用固定集合。
        let second = await service.prepareTurnSelection(
            messages: messages,
            records: JevFixtures.makeRecords(),
            runtime: runtime,
            identity: identity()
        )
        XCTAssertEqual(transport.calls, 1, "相关性与筛查共用一次请求，后续步骤复用该集合")
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

    func testShadowDoesNotApplySelectionAndRecordsOverlapRatio() async throws {
        let runId = "memory-shadow-overlap-\(UUID().uuidString)"
        let records = JevFixtures.makeRecords().filter { [3, 14].contains($0.id) }
        let transport = JevStubTransport { request in
            (self.batchPayload(for: request, scores: ["m3": 0.1, "m14": 2.5], noul: ["inj3": 0, "inj14": 0]), self.httpResponse(status: 200))
        }
        let service = makeService(settings: makeSettings(mode: .shadow, pinned: nil), transport: transport)
        let messages = [userMessage(text: "项目 Alpha")]
        let selection = await service.prepareTurnSelection(
            messages: messages,
            records: records,
            runtime: runtime,
            identity: .init(runId: runId)
        )
        XCTAssertNil(selection)
        let baseline = ChatMemoryContextBuilder.contextPromptResult(
            records: records,
            runtime: runtime,
            queryText: "项目 Alpha"
        )
        XCTAssertEqual(baseline.ids, [3])
        XCTAssertEqual(selection?.ids ?? baseline.ids, baseline.ids, "shadow 不得覆盖 prompt/usage/citation 所用基线")

        var overlapMetric: IOSJevMetricsRecord?
        for _ in 0..<100 where overlapMetric == nil {
            overlapMetric = IOSJevMetricsStore.load().first {
                $0.runId == runId && $0.waitPhase == "t1_shadow_selection"
            }
            if overlapMetric == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        XCTAssertEqual(overlapMetric?.numbers?["overlap_ratio"], 0)
        XCTAssertEqual(transport.calls, 1)
    }

    func testFallbackOnInvalidResponseKeepsSyncPath() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let messages = [userMessage(text: "你好")]
        let selection = await service.prepareTurnSelection(
            messages: messages,
            records: JevFixtures.makeRecords(),
            runtime: runtime,
            identity: identity()
        )
        let eligible = ChatMemoryContextBuilder.hardEligible(
            ChatMemoryContextBuilder.recordsForPrompt(records: JevFixtures.makeRecords(), runtime: runtime)
        )
        let baseline = ChatMemoryContextBuilder.contextPromptResult(records: eligible, runtime: runtime, queryText: "你好")
        XCTAssertEqual(selection?.ids, baseline.ids, "失败时返回并冻结原同步基线")
        let callsAfterFirst = transport.calls
        let second = await service.prepareTurnSelection(
            messages: messages,
            records: JevFixtures.makeRecords(),
            runtime: runtime,
            identity: identity()
        )
        XCTAssertEqual(second?.ids, selection?.ids)
        XCTAssertEqual(transport.calls, callsAfterFirst, "本轮失败回退也固定，后续步骤不再重发")
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
        let eligible = ChatMemoryContextBuilder.hardEligible(
            ChatMemoryContextBuilder.recordsForPrompt(records: JevFixtures.makeRecords(), runtime: runtime)
        )
        let baseline = ChatMemoryContextBuilder.contextPromptResult(records: eligible, runtime: runtime, queryText: "你好")
        XCTAssertEqual(selection?.ids, baseline.ids, "范围不允许时回退并冻结同步基线")
        let repeated = await service.prepareTurnSelection(
            messages: messages,
            records: JevFixtures.makeRecords(),
            runtime: runtime,
            identity: identity()
        )
        XCTAssertEqual(repeated?.ids, baseline.ids)
        XCTAssertEqual(transport.calls, 0)
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

    /// A3 置信弃权：低置信高分记忆不进选中集；高置信次高分顶上。
    /// 记录 3/9 均非 pinned/core，不会被强保留段重新捞回。
    func testOrderedSelectionDropsLowConfidenceHighScore() {
        let records = JevFixtures.makeRecords().filter { [3, 9].contains(Int($0.id)) }
        let decision = IOSJevDecision(
            answers: [
                IOSJevAnswer(id: "m3", type: "score", confidence: 0.2, score: 0.95),
                IOSJevAnswer(id: "m9", type: "score", confidence: 0.9, score: 0.6),
            ],
            usage: nil, modelVersion: "jev-latest", latencyMs: 10, requestBytes: 0, responseBytes: 0
        )
        let gated = IOSJevMemoryRecallService.orderedSelection(
            eligible: records,
            candidates: records,
            decision: decision,
            minScore: 0.34,
            minConfidence: 0.5,
            queryText: "项目",
            now: JevFixtures.memoryNow
        )
        XCTAssertEqual(gated.map { Int($0.id) }, [9], "低置信高分被弃权")

        let ungated = IOSJevMemoryRecallService.orderedSelection(
            eligible: records,
            candidates: records,
            decision: decision,
            minScore: 0.34,
            queryText: "项目",
            now: JevFixtures.memoryNow
        )
        XCTAssertEqual(ungated.map { Int($0.id) }, [3, 9], "不设阈值时按分排序（对照）")
    }

    // MARK: 注入筛查（增强 Phase D）

    /// 选中集注入前的顺路筛查：命中条目被剔除，干净条目保留；相关性与筛查
    /// 在同一个请求里完成。
    func testActiveSelectionDropsInjectedMemory() async {
        let runId = "memory-screen-metric-\(UUID().uuidString)"
        let transport = JevStubTransport { request in
            (self.batchPayload(for: request, scores: ["m3": 2.5, "m14": 2.4], noul: ["inj3": 0.05, "inj14": 0.92]), self.httpResponse(status: 200))
        }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        // 查询词同时命中记录 3（项目 Alpha）与 14（注入测试文本）。
        let selection = await service.prepareTurnSelection(
            messages: [userMessage(text: "项目 Alpha system prompt")],
            records: JevFixtures.makeRecords(),
            runtime: runtime,
            identity: .init(runId: runId)
        )
        let ids = selection?.records.map { Int($0.id) } ?? []
        XCTAssertTrue(ids.contains(3), "干净记忆保留")
        XCTAssertFalse(ids.contains(14), "注入命中记忆被剔除")
        XCTAssertEqual(transport.calls, 1, "相关性与筛查共用一次请求")
        let metrics = IOSJevMetricsStore.load().filter { $0.runId == runId }
        XCTAssertTrue(metrics.contains { $0.numbers?["memory_injection_hits"] == 1 }, "筛查命中数以数值写入指标")
        XCTAssertTrue(metrics.contains { $0.numbers?["memory_selected"] == Double(selection?.records.count ?? -1) })
        XCTAssertTrue(metrics.contains { $0.numbers?["overlap_ratio"] != nil })
    }

    /// 响应缺少 Noul 答案时 fail-open：选中集原样保留，不丢记忆。
    func testScreeningFailureKeepsOriginalSelection() async {
        let transport = JevStubTransport { request in
            (self.batchPayload(for: request, scores: ["m3": 2.5], includeNoulAnswers: false), self.httpResponse(status: 200))
        }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let selection = await service.prepareTurnSelection(
            messages: [userMessage(text: "项目 Alpha 截止日期")],
            records: JevFixtures.makeRecords(),
            runtime: runtime,
            identity: identity()
        )
        XCTAssertTrue(selection?.records.map { Int($0.id) }.contains(3) == true, "筛查失败不得丢记忆（fail-open）")
    }

    /// P1 回归：筛查把选中集剔空时，必须如实返回空选中集（prompt nil、
    /// records 空），不得返回 nil——nil 会让消费方回退同步基线，把刚判为
    /// 注入的记忆重新注回。
    func testScreeningEmptiedSelectionReturnsEmptyNotNil() async {
        let transport = JevStubTransport { request in
            (self.batchPayload(for: request, scores: ["m14": 2.5], noul: ["inj14": 0.95]), self.httpResponse(status: 200))
        }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        // 只放注入记录：选中集=[14]，筛查命中后剔空。
        let onlyInjected = JevFixtures.makeRecords().filter { $0.id == 14 }
        let selection = await service.prepareTurnSelection(
            messages: [userMessage(text: "system prompt")],
            records: onlyInjected,
            runtime: runtime,
            identity: identity()
        )
        XCTAssertNotNil(selection, "筛查剔空 ≠ 回退基线；必须返回显式空选中集")
        XCTAssertTrue(selection?.records.isEmpty == true)
        XCTAssertNil(selection?.prompt)
        XCTAssertEqual(transport.calls, 1, "相关性与筛查共用一次请求")
    }

    func testInjectionProbabilityUsesPolicyThreshold() async {
        var settings = makeSettings(mode: .active)
        settings.policy.memoryInjectionMinProbability = 0.95
        let transport = JevStubTransport { request in
            (self.batchPayload(for: request, scores: ["m14": 2.5], noul: ["inj14": 0.9]), self.httpResponse(status: 200))
        }
        let service = makeService(settings: settings, transport: transport)
        let selection = await service.prepareTurnSelection(
            messages: [userMessage(text: "system prompt")],
            records: JevFixtures.makeRecords().filter { $0.id == 14 },
            runtime: runtime,
            identity: identity()
        )
        XCTAssertTrue(selection?.ids.contains(14) == true, "0.9 低于 policy 的 0.95 时应按 fail-open 保留")
        XCTAssertEqual(transport.calls, 1)
    }

    func testOrdinaryLanguagePreferenceBelowPolicyThresholdIsKept() async {
        let original = JevFixtures.makeRecords().first { $0.id == 31 }!
        let preference = original.doCopy(
            id: original.id,
            content: "回答时使用简体中文。",
            scope: original.scope,
            kind: original.kind,
            assistantId: original.assistantId,
            sourceConversationId: original.sourceConversationId,
            sourceMessageIds: original.sourceMessageIds,
            supersedesIds: original.supersedesIds,
            expiresAt: original.expiresAt,
            confidence: original.confidence,
            pinned: original.pinned,
            archived: original.archived,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt,
            lastUsedAt: original.lastUsedAt,
            topicTitle: original.topicTitle,
            memberIds: original.memberIds
        )
        let transport = JevStubTransport { request in
            (self.batchPayload(for: request, scores: ["m31": 2.5], noul: ["inj31": 0.7]), self.httpResponse(status: 200))
        }
        let service = makeService(settings: makeSettings(mode: .active), transport: transport)
        let selection = await service.prepareTurnSelection(
            messages: [userMessage(text: "怎么回复")],
            records: [preference],
            runtime: runtime,
            identity: identity()
        )
        XCTAssertTrue(selection?.ids.contains(31) == true, "0.7 位于旧 0.5 与默认 0.8 之间，不应误删正常偏好")
        XCTAssertEqual(transport.calls, 1)
    }

    func testCandidatePoolKeepsBothQuestionsWithinOneRequestLimit() async throws {
        var settings = makeSettings(mode: .active)
        settings.policy.maxQuestions = 5
        settings.policy.maxCandidates = 64
        let transport = JevStubTransport { request in
            (self.batchPayload(for: request, scores: ["m30": 2.0], noul: ["inj30": 0.0]), self.httpResponse(status: 200))
        }
        let service = makeService(settings: settings, transport: transport)
        _ = await service.prepareTurnSelection(
            messages: [userMessage(text: "无词面匹配的查询")],
            records: JevFixtures.makeRecords(),
            runtime: runtime,
            identity: identity()
        )
        XCTAssertEqual(IOSJevMemoryRecallService.candidatePoolLimit(policy: settings.policy), 2)
        XCTAssertEqual(transport.calls, 1, "候选池已缩小，不应并行拆批")
        let body = try XCTUnwrap(transport.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let questions = try XCTUnwrap(json["questions"] as? [String: Any])
        XCTAssertEqual(questions.count, 4, "每条候选一题相关性 + 一题筛查")
        XCTAssertLessThanOrEqual(questions.count, settings.policy.maxQuestions)
    }

    func testLateBatchCannotReplaceFirstLocalSelection() async throws {
        var settings = makeSettings(mode: .active)
        settings.policy.t1WaitBudgetMs = 20
        let runId = "memory-late-\(UUID().uuidString)"
        let transport = JevStubTransport { request in
            try await Task.sleep(nanoseconds: 200_000_000)
            return (self.batchPayload(for: request, scores: ["m14": 2.5], noul: ["inj14": 0.0]), self.httpResponse(status: 200))
        }
        let service = makeService(settings: settings, transport: transport)
        let messages = [userMessage(text: "项目 Alpha")]
        let records = JevFixtures.makeRecords().filter { [3, 14].contains($0.id) }
        let first = await service.prepareTurnSelection(
            messages: messages,
            records: records,
            runtime: runtime,
            identity: .init(runId: runId)
        )
        let baseline = ChatMemoryContextBuilder.contextPromptResult(
            records: records,
            runtime: runtime,
            queryText: "项目 Alpha"
        )
        XCTAssertEqual(first?.ids, baseline.ids, "wait budget expires to the frozen local selection")
        let second = await service.prepareTurnSelection(
            messages: messages,
            records: records,
            runtime: runtime,
            identity: .init(runId: runId)
        )
        XCTAssertEqual(second?.ids, first?.ids)

        try await Task.sleep(nanoseconds: 250_000_000)
        let third = await service.prepareTurnSelection(
            messages: messages,
            records: records,
            runtime: runtime,
            identity: .init(runId: runId)
        )
        XCTAssertEqual(third?.ids, first?.ids, "late Jev answer cannot mutate the turn")
        let metrics = IOSJevMetricsStore.load().filter { $0.runId == runId }
        XCTAssertTrue(metrics.contains { $0.outcome == "late" && $0.numbers?["memory_injection_hits"] == 0 })
    }

    func testDifferentTurnsKeepIndependentSelectionsWhileRequestsOverlap() async throws {
        var settings = makeSettings(mode: .active)
        settings.policy.t1WaitBudgetMs = 1_000
        let records = JevFixtures.makeRecords().filter { [3, 14].contains($0.id) }
        let transport = JevStubTransport { request in
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let isFirstTurn = body.contains("任务甲")
            if isFirstTurn { try await Task.sleep(nanoseconds: 150_000_000) }
            let payload = isFirstTurn
                ? self.batchPayload(for: request, scores: ["m3": 2.5, "m14": 0.1], noul: ["inj3": 0, "inj14": 0])
                : self.batchPayload(for: request, scores: ["m3": 0.1, "m14": 2.5], noul: ["inj3": 0, "inj14": 0])
            return (payload, self.httpResponse(status: 200))
        }
        let service = makeService(settings: settings, transport: transport)
        let firstMessages = [userMessage(text: "请处理任务甲")]
        let secondMessages = [userMessage(text: "项目 Alpha")]
        let firstBox = JevMemoryRecallResultBox()
        let firstTask = Task { @MainActor in
            firstBox.value = await service.prepareTurnSelection(
                messages: firstMessages,
                records: records,
                runtime: runtime,
                identity: .init(runId: "overlap-a")
            )
        }

        for _ in 0..<100 where transport.calls == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transport.calls, 1, "第一轮请求已进入传输层后再启动第二轮")

        let second = await service.prepareTurnSelection(
            messages: secondMessages,
            records: records,
            runtime: runtime,
            identity: .init(runId: "overlap-b")
        )
        await firstTask.value
        let first = firstBox.value

        XCTAssertTrue(first?.ids.contains(3) == true)
        XCTAssertFalse(first?.ids.contains(14) == true)
        XCTAssertTrue(second?.ids.contains(14) == true)
        XCTAssertFalse(second?.ids.contains(3) == true)
        XCTAssertEqual(transport.calls, 2, "两个不同 turnKey 都应各自出站一次")

        let repeatedFirst = await service.prepareTurnSelection(
            messages: firstMessages,
            records: records,
            runtime: runtime,
            identity: .init(runId: "overlap-a")
        )
        XCTAssertEqual(repeatedFirst?.ids, first?.ids)
        XCTAssertEqual(transport.calls, 2, "A 的结果应保存在 A 的 turnKey 下，工具循环不能重发")
    }
}
