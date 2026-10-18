import XCTest
import SQLite3
@preconcurrency import Shared
@testable import iosApp


/// Model pool routing, shadow planning, and linked child outcomes.
@MainActor
final class IOSOrchestrationPoolRoutingTests: IOSOrchestrationToolTestCase {
    func testSpawnUsesConfiguredPoolModelsReasoningAndTimeout() async throws {
        let base = makeTempDirectory("SpawnModelPool")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        let modelA = makePoolModel(
            id: KotlinUuid.companion.random(),
            modelId: "gpt-5.6-sol",
            displayName: "Pool OpenAI"
        )
        let modelB = makePoolModel(
            id: KotlinUuid.companion.random(),
            modelId: "claude-3-5-sonnet",
            displayName: "Pool Claude"
        )
        let providerA = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(), enabled: true, name: "Pool OpenAI",
            models: [modelA], balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false, descriptionText: nil, shortDescriptionText: nil, apiKey: "test-key",
            baseUrl: "https://api.openai.com/v1", chatCompletionsPath: "/chat/completions",
            useResponseApi: false, authMode: .apiKey, brand: .generic
        )
        let providerB = makePoolClaudeProvider(id: KotlinUuid.companion.random(), model: modelB)
        let sharedSettings = makePoolSettings(
            modelA: modelA, providerA: providerA,
            modelB: modelB, providerB: providerB
        )
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store, db: db, scheduler: scheduler,
            currentConversationId: { parentId }, sharedSettings: sharedSettings
        )

        let first = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "pool_a"),
            providerSetting: providerA,
            params: makeParams(),
            runId: "pool-parent-a"
        ))
        let second = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "pool_b"),
            providerSetting: providerA,
            params: makeParams(),
            runId: "pool-parent-b"
        ))
        XCTAssertEqual(first["ok"] as? Bool, true)
        XCTAssertEqual(second["ok"] as? Bool, true)
        XCTAssertEqual(scheduler.startedHandoffs.count, 2)

        let handoffs = scheduler.startedHandoffs
        XCTAssertEqual(
            Set(handoffs.map { $0.params.model.id.toHexDashString() }),
            Set([modelA.id.toHexDashString(), modelB.id.toHexDashString()])
        )
        XCTAssertEqual(
            Set(handoffs.map { $0.providerSetting.id.toHexDashString() }),
            Set([providerA.id.toHexDashString(), providerB.id.toHexDashString()])
        )
        XCTAssertEqual(Set(handoffs.map { $0.params.reasoningLevel }), Set([.low, .high]))
        XCTAssertTrue(handoffs.allSatisfy { $0.subAgentTimeoutSeconds == 600 })

        let listed = parseJSON(await service.execute(
            toolName: "list_agents", arguments: "{}",
            providerSetting: providerA, params: makeParams(), runId: "pool-list",
            conversationId: parentId
        ))
        XCTAssertEqual(listed["timeout_minutes"] as? Int, 10)
        let pool = try XCTUnwrap(listed["model_pool"] as? [[String: Any]])
        XCTAssertEqual(pool.count, 2)
        let defaults = Dictionary(uniqueKeysWithValues: pool.compactMap { entry -> (String, String)? in
            guard let id = entry["model_id"] as? String,
                  let reasoning = entry["default_reasoning"] as? String else { return nil }
            return (id, reasoning)
        })
        XCTAssertEqual(defaults[modelA.id.toHexDashString()], "low")
        XCTAssertEqual(defaults[modelB.id.toHexDashString()], "high")
    }

    func testSpawnBatchesModelRoutingAndRoleIntentInOneRequest() async throws {
        let base = makeTempDirectory("SpawnJevBatch")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "请调查并总结这份材料")])
        let db = makeDatabase(directory: base)

        let modelA = makePoolModel(id: KotlinUuid.companion.random(), modelId: "api-model", displayName: "Candidate A")
        let modelB = makePoolModel(id: KotlinUuid.companion.random(), modelId: "api-model", displayName: "Candidate B")
        let providerA = makeProviderSetting()
        let providerB = makePoolClaudeProvider(id: KotlinUuid.companion.random(), model: modelB)
        let sharedSettings = makePoolSettings(
            modelA: modelA,
            providerA: ProviderSetting.OpenAI(
                id: providerA.id, enabled: true, name: "Pool OpenAI", models: [modelA],
                balanceOption: providerA.balanceOption, builtIn: false, descriptionText: nil,
                shortDescriptionText: nil, apiKey: "test-key", baseUrl: "https://example.test",
                chatCompletionsPath: "/chat/completions", useResponseApi: false,
                authMode: .apiKey, brand: .generic
            ),
            modelB: modelB,
            providerB: providerB
        )
        var jevSettings = IOSJevSettings()
        jevSettings.pinnedModelVersion = "jev-fixed-v1"
        jevSettings.setMode(.active, for: .modelRouting)
        jevSettings.setMode(.active, for: .subagentIntent)
        let roleId = try XCTUnwrap(IOSSubAgentRoleCatalog.builtIns.first?.id)
        let transport = JevStubTransport { request in
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let questionMap = try XCTUnwrap(object["questions"] as? [String: Any])
            var candidateAnswers: [String: Any] = [:]
            for questionId in questionMap.keys {
                if questionId.hasPrefix("model_routing.") {
                    let candidateId = String(questionId.dropFirst("model_routing.".count))
                    candidateAnswers[questionId] = [
                        "type": "score",
                        "score": candidateId == modelB.id.toHexDashString() ? 3 : 1,
                    ]
                } else if questionId == "subagent_intent.role_choice" {
                    candidateAnswers[questionId] = ["type": "choice", "choice": roleId, "confidence": 0.9]
                } else if questionId == "subagent_intent.aligned" {
                    candidateAnswers[questionId] = ["type": "noul", "noul": 0.2]
                }
            }
            return (
                try JSONSerialization.data(withJSONObject: ["model": "jev-latest", "answers": candidateAnswers]),
                jevResponse(200)
            )
        }
        let coordinator = makeJevCoordinator(settings: jevSettings, transport: transport)
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store,
            db: db,
            scheduler: scheduler,
            currentConversationId: { parentId },
            sharedSettings: sharedSettings,
            jevCoordinator: coordinator,
            jevSettingsProvider: { jevSettings }
        )

        let spawned = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "investigate", message: "调查并总结材料"),
            providerSetting: providerA,
            params: makeParams(),
            runId: "spawn-jev-batch"
        ))

        XCTAssertEqual(spawned["ok"] as? Bool, true)
        XCTAssertEqual(transport.calls, 1, "模型调度和角色意图应共用一次出站请求")
        XCTAssertEqual(scheduler.startedHandoff?.params.model.id.toHexDashString(), modelB.id.toHexDashString())
        XCTAssertEqual(spawned["jev_alignment"] as? String, "doubtful")
        let requestBody = try XCTUnwrap(transport.lastBody)
        let requestObject = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let questions = try XCTUnwrap(requestObject["questions"] as? [String: Any])
        XCTAssertEqual(Set(questions.keys), Set([
            "model_routing.\(modelA.id.toHexDashString())",
            "model_routing.\(modelB.id.toHexDashString())",
            "subagent_intent.role_choice",
            "subagent_intent.aligned",
        ]))

        let childId = try XCTUnwrap(spawned["child_thread_id"] as? String)
        let childRunId = try XCTUnwrap(scheduler.startedHandoff?.runId)
        let routingRecord = try XCTUnwrap(IOSJevMetricsStore.load().last {
            $0.useCase == .modelRouting
                && $0.outcome == "summary"
                && $0.runId == "spawn-jev-batch"
                && $0.ids?["child_thread_id"] == childId
        })
        XCTAssertEqual(routingRecord.ids?["child_run_id"], childRunId)
        XCTAssertEqual(routingRecord.ids?["selected_model_id"], modelB.id.toHexDashString())
        let childUUID = KotlinUuid.companion.parse(uuidString: childId)
        let maybeChild = try await store.loadConversationForOrchestration(childUUID)
        let child = try XCTUnwrap(maybeChild)
        let configText = try XCTUnwrap(child.currentMessages.first {
            $0.role == MessageRole.system && $0.toText().hasPrefix("[amber orchestration configuration v1]\n")
        }?.toText())
        let configData = Data(configText.dropFirst("[amber orchestration configuration v1]\n".count).utf8)
        let configuration = try XCTUnwrap(try JSONSerialization.jsonObject(with: configData) as? [String: Any])
        XCTAssertEqual(configuration["roleId"] as? String, roleId)

        let explicit = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(
                taskName: "explicit_choice",
                roleId: roleId,
                modelId: modelA.id.toHexDashString()
            ),
            providerSetting: providerA,
            params: makeParams(),
            runId: "spawn-jev-explicit"
        ))
        XCTAssertEqual(explicit["ok"] as? Bool, true)
        XCTAssertEqual(transport.calls, 1, "显式 model_id 与 role_id 都不触发 Jev 判断")

        await store.newConversation()
        let idleTargetId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "已有任务")])
        let idleTargetHex = idleTargetId.toHexDashString()
        try await db.threadEdgeDao().insertEdge(edge: ThreadEdgeEntity(
            childThreadId: idleTargetHex,
            parentThreadId: parentId.toHexDashString(),
            agentPath: "/root/idle_target",
            nickname: nil,
            roleAssistantId: nil,
            forkTurns: "all",
            status: IOSThreadOrchestrationToolService.EdgeStatus.open,
            createdAt: Int64(Date().timeIntervalSince1970 * 1_000)
        ))
        let followup = parseJSON(await service.execute(
            toolName: "followup_task",
            arguments: #"{"target":"\#(idleTargetHex)","message":"继续核对"}"#,
            providerSetting: providerA,
            params: makeParams(),
            runId: "followup-jev-batch",
            conversationId: parentId
        ))
        XCTAssertEqual(followup["status"] as? String, "started")
        XCTAssertEqual(transport.calls, 2)
        let followupBody = try XCTUnwrap(transport.lastBody)
        let followupObject = try XCTUnwrap(JSONSerialization.jsonObject(with: followupBody) as? [String: Any])
        let followupQuestions = try XCTUnwrap(followupObject["questions"] as? [String: Any])
        XCTAssertEqual(Set(followupQuestions.keys), Set([
            "model_routing.\(modelA.id.toHexDashString())",
            "model_routing.\(modelB.id.toHexDashString())",
        ]), "followup 只判断模型调度")
    }

    func testShadowT3DoesNotWaitForNetworkAndRecordsSnapshotMetricsLater() async throws {
        let base = makeTempDirectory("SpawnJevShadowDeferred")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "请调查这份材料")])
        let db = makeDatabase(directory: base)

        let modelAId = KotlinUuid.companion.parse(uuidString: "11111111-1111-1111-1111-111111111111")
        let modelBId = KotlinUuid.companion.parse(uuidString: "22222222-2222-2222-2222-222222222222")
        let modelA = makePoolModel(id: modelAId, modelId: "same-api-model", displayName: "Candidate A")
        let modelB = makePoolModel(id: modelBId, modelId: "same-api-model", displayName: "Candidate B")
        let callerProvider = makeProviderSetting()
        let poolProviderA = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(), enabled: true, name: "Pool OpenAI", models: [modelA],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false, descriptionText: nil, shortDescriptionText: nil, apiKey: "test-key",
            baseUrl: "https://example.test", chatCompletionsPath: "/chat/completions",
            useResponseApi: false, authMode: .apiKey, brand: .generic
        )
        let poolProviderB = makePoolClaudeProvider(id: KotlinUuid.companion.random(), model: modelB)
        let sharedSettings = makePoolSettings(
            modelA: modelA,
            providerA: poolProviderA,
            modelB: modelB,
            providerB: poolProviderB
        )
        sharedSettings.setDynamicSubAgentsAllowed(true)

        var jevSettings = IOSJevSettings()
        jevSettings.setMode(.shadow, for: .modelRouting)
        jevSettings.setMode(.shadow, for: .subagentIntent)
        let roleId = try XCTUnwrap(IOSSubAgentRoleCatalog.builtIns.first?.id)
        let transport = JevStubTransport { request in
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let questionMap = try XCTUnwrap(object["questions"] as? [String: Any])
            var answers: [String: Any] = [:]
            for id in questionMap.keys {
                if id.hasPrefix("model_routing.") {
                    answers[id] = ["type": "score", "score": 3]
                } else if id == "subagent_intent.role_choice" {
                    answers[id] = ["type": "choice", "choice": roleId, "confidence": 0.9]
                } else if id == "subagent_intent.aligned" {
                    answers[id] = ["type": "noul", "noul": 0.9]
                }
            }
            try await Task.sleep(nanoseconds: 900_000_000)
            return (
                try JSONSerialization.data(withJSONObject: ["model": "jev-latest", "answers": answers]),
                jevResponse(200)
            )
        }
        let coordinator = makeJevCoordinator(settings: jevSettings, transport: transport)
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store,
            db: db,
            scheduler: scheduler,
            currentConversationId: { parentId },
            sharedSettings: sharedSettings,
            jevCoordinator: coordinator,
            jevSettingsProvider: { jevSettings }
        )

        let runId = "spawn-shadow-deferred-\(UUID().uuidString)"
        let startedAt = Date()
        let spawned = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "shadow_async", message: "调查并总结材料"),
            providerSetting: callerProvider,
            params: makeParams(),
            runId: runId
        ))
        let elapsedMs = Date().timeIntervalSince(startedAt) * 1_000

        XCTAssertEqual(spawned["ok"] as? Bool, true)
        XCTAssertLessThan(
            elapsedMs,
            Double(jevSettings.policy.t3WaitBudgetMs),
            "全 shadow spawn 应先启动子 run，不能等待 400ms Jev 预算"
        )
        XCTAssertEqual(scheduler.startedHandoff?.params.model.id.toHexDashString(), modelA.id.toHexDashString())
        let childThreadId = try XCTUnwrap(spawned["child_thread_id"] as? String)
        let childRunId = try XCTUnwrap(scheduler.startedHandoff?.runId)

        let earlyModelRecord = IOSJevMetricsStore.load().last {
            $0.useCase == .modelRouting
                && $0.outcome == "summary"
                && $0.runId == runId
                && $0.ids?["child_thread_id"] == childThreadId
        }
        XCTAssertNotNil(earlyModelRecord, "实际本地模型 ID 在 durable start 后立即记录")
        XCTAssertNil(earlyModelRecord?.numbers?["difference"], "网络结果到达前不得伪造 shadow 差异")

        let callDeadline = Date().addingTimeInterval(0.5)
        while transport.calls == 0 && Date() < callDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(transport.calls, 1)

        let metricDeadline = Date().addingTimeInterval(2.0)
        var modelMetric: IOSJevMetricsRecord?
        var intentMetric: IOSJevMetricsRecord?
        while Date() < metricDeadline {
            let records = IOSJevMetricsStore.load()
            modelMetric = records.last {
                $0.useCase == .modelRouting
                    && $0.outcome == "summary"
                    && $0.runId == runId
                    && $0.ids?["child_thread_id"] == childThreadId
                    && $0.numbers?["difference"] != nil
            }
            intentMetric = records.last {
                $0.useCase == .subagentIntent
                    && $0.outcome == "summary"
                    && $0.runId == runId
                    && $0.ids?["child_thread_id"] == childThreadId
            }
            if modelMetric != nil, intentMetric != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let modelMetricValue = try XCTUnwrap(modelMetric, "observed 模型调度应在网络返回后写差异")
        XCTAssertEqual(modelMetricValue.ids?["selected_model_id"], modelA.id.toHexDashString())
        XCTAssertEqual(modelMetricValue.ids?["counterfactual_model_id"], modelA.id.toHexDashString())
        XCTAssertEqual(modelMetricValue.ids?["child_run_id"], childRunId)
        XCTAssertEqual(modelMetricValue.numbers?["preferred_set_size"], 2)
        XCTAssertEqual(modelMetricValue.numbers?["difference"], 0, "必须用本地选择前的轮转快照算反事实")

        let intentMetricValue = try XCTUnwrap(intentMetric, "observed 角色意图应在网络返回后比较最终角色")
        XCTAssertEqual(intentMetricValue.ids?["suggested_role_id"], roleId)
        XCTAssertEqual(intentMetricValue.ids?["selected_role_id"], "none")
        XCTAssertEqual(intentMetricValue.numbers?["difference"], 1)
    }

    func testDeferredShadowT3SkipsWhenSettingsRevisionChangesBeforeDispatch() async throws {
        let base = makeTempDirectory("SpawnJevShadowRevision")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "请调查这份材料")])
        let db = makeDatabase(directory: base)

        var originalSettings = IOSJevSettings()
        originalSettings.setMode(.shadow, for: .subagentIntent)
        var changedSettings = originalSettings
        changedSettings.revision += 1
        let currentCoordinatorSettings = changedSettings
        let settingsReads = JevCallCounter()
        let transport = JevStubTransport { _ in
            (self.payloadForShadowRoleChoice(), jevResponse(200))
        }
        let coordinator = IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport),
            settingsProvider: { settingsReads.next(); return currentCoordinatorSettings },
            apiKeyProvider: { "test-key" },
            now: { Date() }
        ))
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store,
            db: db,
            scheduler: scheduler,
            currentConversationId: { parentId },
            jevCoordinator: coordinator,
            jevSettingsProvider: { originalSettings }
        )
        let runId = "spawn-shadow-revision-\(UUID().uuidString)"

        let spawned = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "revision", message: "调查材料"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: runId
        ))

        XCTAssertEqual(spawned["ok"] as? Bool, true)
        let dispatchDeadline = Date().addingTimeInterval(0.5)
        while settingsReads.current == 0 && Date() < dispatchDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(settingsReads.current, 0, "deferred batch 应读取出站时配置 revision")
        XCTAssertEqual(transport.calls, 0, "旧设置 revision 不应在后台 shadow 子任务中继续出站")
        let staleIntentMetric = IOSJevMetricsStore.load().last {
            $0.useCase == .subagentIntent
                && $0.outcome == "summary"
                && $0.runId == runId
        }
        XCTAssertNil(staleIntentMetric, "revision 失配不得记录角色差异")
    }

    private func payloadForShadowRoleChoice() -> Data {
        let roleId = IOSSubAgentRoleCatalog.builtIns.first?.id ?? "none"
        return try! JSONSerialization.data(withJSONObject: [
            "model": "jev-latest",
            "answers": [
                "subagent_intent.role_choice": ["type": "choice", "choice": roleId],
                "subagent_intent.aligned": ["type": "noul", "noul": 0.9],
            ],
        ])
    }

    func testModelRoutingChildOutcomeUsesLinkedDurableTerminalAndIsIdempotent() async throws {
        let base = makeTempDirectory("JevChildOutcome")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        let service = makeService(
            store: store,
            db: db,
            scheduler: FakeBackgroundScheduler(),
            currentConversationId: { conversationId }
        )
        let parentRunId = UUID().uuidString

        func link(childRunId: String, childThreadId: String) {
            IOSJevMetricsStore.append(IOSJevMetricsRecord(
                timestamp: Date(),
                useCase: .modelRouting,
                mode: .shadow,
                modelVersion: "jev-test",
                outcome: "summary",
                latencyMs: 0,
                requestBytes: 0,
                responseBytes: 0,
                inputTokens: nil,
                outputTokens: nil,
                reason: nil,
                runId: parentRunId,
                waitPhase: "t3",
                numbers: ["preferred_set_size": 1],
                ids: ["child_run_id": childRunId, "child_thread_id": childThreadId]
            ))
        }

        let cases: [(AgentRunStatus, String?, String)] = [
            (.completed, nil, "child_succeeded"),
            (.failed, nil, "child_failed"),
            (.failed, IOSThreadOrchestrationToolService.modelRoutingTimeoutTerminalReason, "child_timed_out"),
        ]
        var trackedChildren: [(String, String, String)] = []
        for (status, reason, expectedNumber) in cases {
            let childRunId = UUID().uuidString
            let childThreadId = UUID().uuidString
            trackedChildren.append((childRunId, childThreadId, expectedNumber))
            link(childRunId: childRunId, childThreadId: childThreadId)
            service.recordModelRoutingChildOutcomeIfNeeded(
                childThreadId: childThreadId,
                childRunId: childRunId,
                terminalStatus: status,
                terminalReason: reason
            )
            service.recordModelRoutingChildOutcomeIfNeeded(
                childThreadId: childThreadId,
                childRunId: childRunId,
                terminalStatus: status,
                terminalReason: reason
            )
        }

        let cancelledRunId = UUID().uuidString
        let cancelledThreadId = UUID().uuidString
        link(childRunId: cancelledRunId, childThreadId: cancelledThreadId)
        service.recordModelRoutingChildOutcomeIfNeeded(
            childThreadId: cancelledThreadId,
            childRunId: cancelledRunId,
            terminalStatus: .cancelled,
            terminalReason: nil
        )
        service.recordModelRoutingChildOutcomeIfNeeded(
            childThreadId: UUID().uuidString,
            childRunId: UUID().uuidString,
            terminalStatus: .completed,
            terminalReason: nil
        )

        let outcomes = IOSJevMetricsStore.load().filter {
            $0.useCase == .modelRouting
                && $0.outcome == "summary"
                && $0.ids?["child_outcome"] == "terminal"
                && $0.runId == parentRunId
        }
        XCTAssertEqual(outcomes.count, cases.count)
        for (childRunId, childThreadId, expectedNumber) in trackedChildren {
            let outcome = try XCTUnwrap(outcomes.first {
                $0.ids?["child_run_id"] == childRunId
                    && $0.ids?["child_thread_id"] == childThreadId
            })
            XCTAssertEqual(outcome.numbers, [expectedNumber: 1])
        }
    }

    func testExplicitPoolModelAndReasoningRejectInvalidRequests() async throws {
        let base = makeTempDirectory("SpawnModelPoolExplicit")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        let modelA = makePoolModel(
            id: KotlinUuid.companion.random(), modelId: "gpt-5.6-sol", displayName: "Pool OpenAI"
        )
        let modelB = makePoolModel(
            id: KotlinUuid.companion.random(), modelId: "claude-3-5-sonnet", displayName: "Pool Claude"
        )
        let providerA = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(), enabled: true, name: "Pool OpenAI",
            models: [modelA], balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false, descriptionText: nil, shortDescriptionText: nil, apiKey: "test-key",
            baseUrl: "https://api.openai.com/v1", chatCompletionsPath: "/chat/completions",
            useResponseApi: false, authMode: .apiKey, brand: .generic
        )
        let providerB = makePoolClaudeProvider(id: KotlinUuid.companion.random(), model: modelB)
        let sharedSettings = makePoolSettings(
            modelA: modelA, providerA: providerA,
            modelB: modelB, providerB: providerB,
            timeoutMinutes: 5
        )
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store, db: db, scheduler: scheduler,
            currentConversationId: { parentId }, sharedSettings: sharedSettings
        )

        let valid = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(
                taskName: "explicit_valid",
                modelId: modelB.id.toHexDashString(),
                reasoningLevel: "high"
            ),
            providerSetting: providerA, params: makeParams(), runId: "explicit-valid"
        ))
        XCTAssertEqual(valid["ok"] as? Bool, true)
        XCTAssertEqual(
            scheduler.startedHandoffs.last?.params.model.id.toHexDashString(),
            modelB.id.toHexDashString()
        )
        XCTAssertEqual(scheduler.startedHandoffs.last?.params.reasoningLevel, .high)
        let handoffCount = scheduler.startedHandoffs.count

        let outside = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(
                taskName: "explicit_outside",
                modelId: KotlinUuid.companion.random().toHexDashString(),
                reasoningLevel: "low"
            ),
            providerSetting: providerA, params: makeParams(), runId: "explicit-outside"
        ))
        XCTAssertEqual(outside["error"] as? String, "invalid_arguments")
        XCTAssertEqual(scheduler.startedHandoffs.count, handoffCount)

        let unsupported = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(
                taskName: "explicit_unsupported",
                modelId: modelB.id.toHexDashString(),
                reasoningLevel: "max"
            ),
            providerSetting: providerA, params: makeParams(), runId: "explicit-unsupported"
        ))
        XCTAssertEqual(unsupported["error"] as? String, "invalid_arguments")
        XCTAssertEqual(scheduler.startedHandoffs.count, handoffCount)
    }

}
