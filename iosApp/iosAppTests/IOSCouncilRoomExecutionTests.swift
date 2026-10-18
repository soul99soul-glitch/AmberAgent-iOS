import XCTest
import SwiftUI
import Observation
@preconcurrency import Shared
@testable import iosApp


@MainActor
final class IOSCouncilRoomExecutionTests: IOSCouncilMechanicsTestCase {
    func testDynamicSeatsProbeAssignedModelsAndReplaceUnreachableOnes() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let models = ["gpt-main", "gpt-bad", "gpt-good"].map(makeCouncilModel)
        let provider = makeCouncilProvider(models: models)
        let streamer = ScriptedCouncilStreamer([
            .success("最终议题"),
            .success(#"{"seats":[{"name":"求证","lens":"核对证据"},{"name":"反方","lens":"寻找反例"}]}"#),
            .failure(CouncilTestError.scriptedFailure),
            .success("OK"),
            .success("求证席发言"),
            .success("反方席发言"),
            .success("主持总结")
        ])
        let runner = IOSCouncilRoomRunner(
            streamer: streamer,
            researcher: StaticCouncilResearcher(),
            taskStore: taskStore
        )
        var request = roomRequest(
            settings: compactRoomSettings(defaultRounds: 1),
            researchConsent: .unavailable,
            providerSetting: provider,
            currentModel: models[0]
        )
        request.dynamicSeatGeneration = true
        var rosters: [[IOSCouncilRoomSpeaker]] = []

        let outcome = await runner.run(request: request, onEvent: { event in
            if case .roster(let speakers, _, _) = event {
                rosters.append(speakers)
            }
        })

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertTrue(outcome.failedSeats.isEmpty)
        XCTAssertEqual(streamer.receivedModels.prefix(4).map(\.modelId), [
            "gpt-main", "gpt-main", "gpt-bad", "gpt-good"
        ])
        XCTAssertFalse(streamer.receivedModels.dropFirst(4).contains { $0.modelId == "gpt-bad" })
        let finalSeats = try XCTUnwrap(rosters.last).filter { !$0.isHost }
        XCTAssertEqual(finalSeats.count, 2)
        XCTAssertFalse(finalSeats.contains { $0.modelId == "gpt-bad" })
    }

    func testDynamicSeatsCarryAndUseCrossProviderRoutes() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let currentModels = [makeCouncilModel("gpt-main"), makeCouncilModel("gpt-host")]
        let claudeModel = makeCouncilModel("claude-seat")
        let grokModel = makeCouncilModel("grok-seat")
        let currentProvider = makeCouncilProvider(name: "DeepSeek", models: currentModels)
        let claudeProvider = makeCouncilProvider(name: "Anthropic", models: [claudeModel])
        let grokProvider = makeCouncilProvider(name: "xAI", models: [grokModel])
        let streamer = ScriptedCouncilStreamer([
            .success("最终议题"),
            .success(#"{"seats":[{"name":"求证","lens":"核对证据"},{"name":"反方","lens":"寻找反例"}]}"#),
            .success("OK"),
            .success("OK"),
            .success("求证席发言"),
            .success("反方席发言"),
            .success("主持总结")
        ])
        let runner = IOSCouncilRoomRunner(
            streamer: streamer,
            researcher: StaticCouncilResearcher(),
            taskStore: taskStore
        )
        var request = roomRequest(
            settings: compactRoomSettings(defaultRounds: 1),
            researchConsent: .unavailable,
            providerSetting: currentProvider,
            providerSettings: [currentProvider, claudeProvider, grokProvider],
            currentModel: currentModels[0]
        )
        request.dynamicSeatGeneration = true
        var rosters: [[IOSCouncilRoomSpeaker]] = []

        let outcome = await runner.run(request: request, onEvent: { event in
            if case .roster(let speakers, _, _) = event {
                rosters.append(speakers)
            }
        })

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(streamer.receivedProviderNames, [
            "DeepSeek", "DeepSeek", "Anthropic", "xAI", "Anthropic", "xAI", "DeepSeek"
        ])
        XCTAssertEqual(streamer.receivedModels.map(\.modelId), [
            "gpt-host", "gpt-host", "claude-seat", "grok-seat", "claude-seat", "grok-seat", "gpt-host"
        ])
        let finalSeats = try XCTUnwrap(rosters.last).filter { !$0.isHost }
        XCTAssertEqual(
            Set(finalSeats.map { "\($0.providerId ?? "")/\($0.modelId)" }),
            Set([
                "\(claudeProvider.id.description())/claude-seat",
                "\(grokProvider.id.description())/grok-seat"
            ])
        )
    }

    func testFreshFreeChatAndDebateUseConfiguredDefaultRounds() async {
        for mode in [IOSCouncilRoomRunMode.freeChat, .debate] {
            let streamer = ScriptedCouncilStreamer([
                .success("最终议题"),
                .success("工程第一轮"),
                .success("风险第一轮"),
                .success("主持点评"),
                .success("工程第二轮"),
                .success("风险第二轮"),
                .success("主持总结")
            ])
            let runner = IOSCouncilRoomRunner(
                streamer: streamer,
                researcher: StaticCouncilResearcher(),
                taskStore: IOSAdvancedTaskStore(userDefaults: isolatedDefaults(), storageKey: "tasks-\(mode.rawValue)")
            )
            var roundDividers: [String] = []
            var seatMessageCount = 0

            let outcome = await runner.run(
                request: roomRequest(
                    mode: mode,
                    settings: compactRoomSettings(defaultRounds: 2),
                    researchConsent: .unavailable
                ),
                onEvent: { event in
                    guard case .append(let message) = event else { return }
                    if message.kind == .divider, message.body.hasPrefix("第 ") {
                        roundDividers.append(message.body)
                    } else if message.kind == .seat {
                        seatMessageCount += 1
                    }
                }
            )

            XCTAssertEqual(outcome.status, .completed, "mode=\(mode.rawValue)")
            XCTAssertEqual(roundDividers, ["第 1 轮", "第 2 轮"], "mode=\(mode.rawValue)")
            XCTAssertEqual(seatMessageCount, 4, "mode=\(mode.rawValue)")
            XCTAssertEqual(streamer.callCount, 7, "mode=\(mode.rawValue)")
        }
    }

    func testRoomRunnerFreeChatPersistsTaskApprovalAndOrderedMessages() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let permissionStore = IOSPermissionStore(
            userDefaults: defaults,
            storageKey: "policies",
            approvalStorageKey: "approvals",
            taskStore: taskStore
        )
        let policiesBefore = permissionStore.policies
        let streamer = ScriptedCouncilStreamer([
            .success("""
            最终议题：把模型议会做成正式 Room。
            席位: 工程 | 看实现路径
            席位: 风险 | 看失败模式
            """),
            .success("工程建议：拆 runner，UI 只消费事件。"),
            .success("风险建议：不要伪装跨 provider。"),
            .success("主持总结：先做当前服务商内多模型 Room。")
        ])
        let runner = IOSCouncilRoomRunner(
            streamer: streamer,
            researcher: StaticCouncilResearcher(),
            taskStore: taskStore,
            permissionStore: permissionStore
        )
        var events: [IOSCouncilRoomEvent] = []

        let outcome = await runner.run(
            request: roomRequest(
                mode: .freeChat,
                settings: compactRoomSettings(defaultRounds: 1),
                researchConsent: .allowed
            ),
            onEvent: { events.append($0) }
        )

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.seatNames, ["工程", "风险"])
        XCTAssertEqual(outcome.failedSeats, [])
        XCTAssertEqual(outcome.finalAnswer, "主持总结：先做当前服务商内多模型 Room。")
        XCTAssertNil(outcome.failureReason)
        XCTAssertTrue(outcome.transcript.contains("主持总结"))
        XCTAssertEqual(streamer.callCount, 4)
        XCTAssertEqual(permissionStore.policies, policiesBefore, "Room consent must not mutate global permission policy.")

        let messageAuthors = events.compactMap { event -> String? in
            guard case let .append(message) = event,
                  message.kind == .host || message.kind == .seat else { return nil }
            return message.author
        }
        XCTAssertEqual(messageAuthors, ["主持人", "工程", "风险", "主持人"])

        XCTAssertEqual(Set(permissionStore.approvalRecords.map(\.toolName)), ["search_web", "scrape_web"])
        XCTAssertTrue(permissionStore.approvalRecords.allSatisfy { $0.action == .allowed })

        let task = try XCTUnwrap(taskStore.recent(kind: .modelCouncil, limit: 1).first)
        XCTAssertEqual(task.status, .completed)
        XCTAssertEqual(task.toolScope, ["search_web", "scrape_web"])
        XCTAssertEqual(task.metadata["room_mode"], IOSCouncilRoomRunMode.freeChat.rawValue)
    }

    func testRoomRunnerTimeoutMeasuresLackOfOutputInsteadOfTotalGenerationTime() async {
        let runner = IOSCouncilRoomRunner(
            streamer: ProgressingFinalCouncilStreamer(),
            researcher: StaticCouncilResearcher(),
            taskStore: IOSAdvancedTaskStore(userDefaults: isolatedDefaults(), storageKey: "tasks"),
            timeoutUnitNanoseconds: 10_000_000
        )
        var settings = compactRoomSettings(defaultRounds: 1)
        settings.limits.seatTimeoutSeconds = 15

        let outcome = await runner.run(
            request: roomRequest(
                settings: settings,
                researchConsent: .unavailable
            )
        )

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.finalAnswer, "第一段第二段")
    }

    func testRoomRunnerSeatFailureCompletesWithFailedSeat() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let streamer = ScriptedCouncilStreamer([
            .success("""
            最终议题：压测席位失败降级。
            席位: 工程 | 先给实现判断
            席位: 风险 | 再给风险判断
            """),
            .success("工程发言完成。"),
            .failure(CouncilTestError.scriptedFailure),
            .success("主持总结：风险席位缺席，结论保持不确定。")
        ])
        let runner = IOSCouncilRoomRunner(
            streamer: streamer,
            researcher: StaticCouncilResearcher(),
            taskStore: taskStore
        )
        var events: [IOSCouncilRoomEvent] = []

        let outcome = await runner.run(
            request: roomRequest(
                mode: .debate,
                settings: compactRoomSettings(defaultRounds: 1),
                researchConsent: .denied
            ),
            onEvent: { events.append($0) }
        )

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.seatNames, ["工程", "风险"])
        XCTAssertEqual(outcome.failedSeats, ["风险"])
        XCTAssertEqual(streamer.callCount, 4)
        XCTAssertTrue(outcome.transcript.contains("风险席位缺席"))

        let failedUpdate = events.contains { event in
            guard case let .updateMessage(_, body, status, _) = event else { return false }
            return status == .failed && body.contains("席位失败")
        }
        XCTAssertTrue(failedUpdate)

        let task = try XCTUnwrap(taskStore.recent(kind: .modelCouncil, limit: 1).first)
        XCTAssertEqual(task.status, .completed)
        XCTAssertTrue(task.retryable)
        XCTAssertTrue(task.error.contains("风险"))
    }

    func testRoomRunnerTreatsEmptySeatOutputAsThatSeatFailure() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let streamer = ScriptedCouncilStreamer([
            .success("最终议题"),
            .success(""),
            .success("风险发言"),
            .success("主持总结")
        ])
        let runner = IOSCouncilRoomRunner(
            streamer: streamer,
            researcher: StaticCouncilResearcher(),
            taskStore: taskStore
        )

        let outcome = await runner.run(
            request: roomRequest(
                settings: compactRoomSettings(defaultRounds: 1),
                researchConsent: .unavailable
            )
        )

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.failedSeats, ["工程"])
        XCTAssertEqual(outcome.finalAnswer, "主持总结")
        XCTAssertFalse(outcome.transcript.contains("[工程]"))
    }

    func testRoomRunnerFailsWhenFinalTopicIsEmpty() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let runner = IOSCouncilRoomRunner(
            streamer: ScriptedCouncilStreamer([.success("")]),
            researcher: StaticCouncilResearcher(),
            taskStore: taskStore
        )

        let outcome = await runner.run(
            request: roomRequest(
                settings: compactRoomSettings(defaultRounds: 1),
                researchConsent: .unavailable
            )
        )

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(outcome.failureReason?.contains("最终议题") == true)
        XCTAssertTrue(outcome.finalAnswer.isEmpty)
    }

    func testRoomRunnerFailsWhenFinalSynthesisIsEmpty() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let runner = IOSCouncilRoomRunner(
            streamer: ScriptedCouncilStreamer([
                .success("最终议题"),
                .success("工程发言"),
                .success("风险发言"),
                .success("")
            ]),
            researcher: StaticCouncilResearcher(),
            taskStore: taskStore
        )

        let outcome = await runner.run(
            request: roomRequest(
                settings: compactRoomSettings(defaultRounds: 1),
                researchConsent: .unavailable
            )
        )

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(outcome.failureReason?.contains("最终综合") == true)
        XCTAssertTrue(outcome.finalAnswer.isEmpty)
    }

    func testRoomRunnerAllowsLegitimateOutputBeginningWithError() async throws {
        let runner = IOSCouncilRoomRunner(
            streamer: ScriptedCouncilStreamer([
                .success("Error: budgeting assumptions need review"),
                .success("工程发言"),
                .success("风险发言"),
                .success("主持总结")
            ]),
            researcher: StaticCouncilResearcher(),
            taskStore: IOSAdvancedTaskStore(userDefaults: isolatedDefaults(), storageKey: "tasks")
        )

        let outcome = await runner.run(
            request: roomRequest(
                settings: compactRoomSettings(defaultRounds: 1),
                researchConsent: .unavailable
            )
        )

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.finalTopic, "Error: budgeting assumptions need review")
    }

    func testCouncilProviderResolutionPreservesCredentialIdentity() throws {
        let provider = IOSCouncilRoomRunner.makeProviderSetting(
            baseUrl: "https://example.com/v1",
            apiKey: "test-key"
        )

        let resolved = try XCTUnwrap(
            IOSCouncilRoomRunner.resolveProviderSetting(selected: provider)
        )

        XCTAssertTrue(resolved === provider)
    }

    func testRoomRunnerPassesTheConfiguredModelInsteadOfSynthesizingOne() async throws {
        let streamer = ScriptedCouncilStreamer([
            .success("最终议题"),
            .success("工程发言"),
            .success("产品发言"),
            .success("主持总结")
        ])
        let runner = IOSCouncilRoomRunner(
            streamer: streamer,
            researcher: StaticCouncilResearcher(),
            taskStore: IOSAdvancedTaskStore(userDefaults: isolatedDefaults(), storageKey: "tasks")
        )
        let model = Model(
            modelId: "gpt-main",
            displayName: "Configured Council Model",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [ModelAbility.reasoning],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: KotlinInt(value: 32_000),
            providerOverwrite: nil
        )
        var settings = IOSCouncilRoomSettings.defaults(currentModelId: model.modelId)
        settings.limits.maxSeats = 2
        settings.limits.defaultRounds = 1
        var request = roomRequest(settings: settings)
        request.currentModel = model

        let outcome = await runner.run(request: request)

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(streamer.receivedModels.count, 4)
        XCTAssertTrue(streamer.receivedModels.allSatisfy { $0 === model })
    }

    func testRoomRunnerPreservesExactPartialSeatTailWhenStreamFails() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let streamer = PartialTailCouncilStreamer()
        let runner = IOSCouncilRoomRunner(
            streamer: streamer,
            researcher: StaticCouncilResearcher(),
            taskStore: taskStore
        )
        var events: [IOSCouncilRoomEvent] = []

        let outcome = await runner.run(
            request: roomRequest(
                settings: compactRoomSettings(defaultRounds: 1),
                researchConsent: .denied
            ),
            onEvent: { events.append($0) }
        )

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.failedSeats, ["风险"])
        let riskFailure = events.compactMap { event -> String? in
            guard case let .updateMessage(_, body, status, _) = event,
                  status == .failed else { return nil }
            return body
        }.last
        XCTAssertEqual(
            riskFailure,
            PartialTailCouncilStreamer.partialTail,
            "A failed seat must close streaming state without replacing its exact accepted tail."
        )
    }

    func testRoomRunnerShowsFailureReasonWhenFailedSeatHasNoGeneratedTail() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let streamer = PartialTailCouncilStreamer(failedTail: nil)
        let runner = IOSCouncilRoomRunner(
            streamer: streamer,
            researcher: StaticCouncilResearcher(),
            taskStore: taskStore
        )
        var events: [IOSCouncilRoomEvent] = []

        _ = await runner.run(
            request: roomRequest(
                settings: compactRoomSettings(defaultRounds: 1),
                researchConsent: .denied
            ),
            onEvent: { events.append($0) }
        )

        let failedBody = events.compactMap { event -> String? in
            guard case let .updateMessage(_, body, status, _) = event,
                  status == .failed else { return nil }
            return body
        }.last
        XCTAssertTrue(failedBody?.contains("席位失败") == true)
        XCTAssertFalse(failedBody == "思考中...")
    }

    func testCancelledRunCannotCancelImmediateReplacementRun() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let firstStreamStarted = expectation(description: "first council stream started")
        let streamer = RestartableCouncilStreamer(firstStreamStarted: firstStreamStarted)
        let runner = IOSCouncilRoomRunner(
            streamer: streamer,
            researcher: StaticCouncilResearcher(),
            taskStore: taskStore
        )
        let request = roomRequest(
            settings: compactRoomSettings(defaultRounds: 1),
            researchConsent: .denied
        )

        let firstRun = Task { await runner.run(request: request) }
        await fulfillment(of: [firstStreamStarted], timeout: 1)
        let firstTaskID = try XCTUnwrap(taskStore.recent(kind: .modelCouncil, limit: 1).first?.id)
        runner.cancel()

        let cancelled = await firstRun.value
        // A late terminal callback from the cancelled owner must not mutate its
        // task after cancel has cleared the runner's active task identity.
        runner.markActiveTaskTerminal(
            status: .interrupted,
            summary: "不应改写旧轮",
            retryable: true
        )
        let replacement = await runner.run(request: request)

        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(replacement.status, .completed)
        XCTAssertEqual(
            taskStore.tasks.first(where: { $0.id == firstTaskID })?.status,
            .cancelled,
            "The cancelled run must remain terminal after a late callback."
        )
        XCTAssertEqual(streamer.callCount, 5)
        XCTAssertEqual(streamer.cancelCount, 1)
    }

    func testExplicitContinuationCancelRemainsCancelledInTaskLedger() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let baseTask = taskStore.startTask(
            kind: .modelCouncil,
            title: "既有议会",
            objective: "原始议题"
        )
        _ = taskStore.updateTask(id: baseTask.id, status: .completed, resultSummary: "既有结论")
        let firstStreamStarted = expectation(description: "continuation stream started")
        let runner = IOSCouncilRoomRunner(
            streamer: RestartableCouncilStreamer(firstStreamStarted: firstStreamStarted),
            researcher: StaticCouncilResearcher(),
            taskStore: taskStore
        )
        var request = roomRequest(
            settings: compactRoomSettings(defaultRounds: 1),
            researchConsent: .unavailable
        )
        request.continuation = IOSCouncilRoomContinuation(
            taskId: baseTask.id,
            originalObjective: "原始议题",
            finalTopic: "既有最终议题",
            priorTranscript: "[主持人] 既有结论",
            speakers: [
                IOSCouncilRoomSpeaker(
                    id: "host",
                    name: "主持人",
                    rolePrompt: "主持与综合",
                    modelId: "gpt-host",
                    reasoning: .off,
                    prompt: "",
                    isHost: true
                ),
                roomSpeaker(id: "engineering", name: "工程", modelId: "gpt-main"),
                roomSpeaker(id: "risk", name: "风险", modelId: "gpt-main")
            ],
            nextRound: 2
        )

        // Before the continuation runner creates its task, the reused task ID
        // still belongs to the completed prior round and must not be cancelled.
        runner.markActiveTaskTerminal(
            taskId: baseTask.id,
            status: .cancelled,
            summary: "不应改写上一轮",
            retryable: true
        )
        XCTAssertEqual(taskStore.tasks.first(where: { $0.id == baseTask.id })?.status, .completed)

        let run = Task { await runner.run(request: request) }
        await fulfillment(of: [firstStreamStarted], timeout: 1)
        runner.markActiveTaskTerminal(
            taskId: baseTask.id,
            status: .cancelled,
            summary: "本轮议会已停止。",
            retryable: true
        )
        runner.cancel()

        let summary = await run.value
        XCTAssertEqual(summary.status, .cancelled)
        XCTAssertEqual(
            taskStore.tasks.first(where: { $0.id == baseTask.id })?.status,
            .cancelled,
            "An explicit continuation cancel must not be rewritten as completed by the catch path."
        )
    }

    func testRunnerKeepsPersistedTerminalStatusAvailableAfterRunReturns() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let runner = IOSCouncilRoomRunner(
            streamer: ScriptedCouncilStreamer([
                .success("最终议题"),
                .success("工程发言"),
                .success("风险发言"),
                .success("主持总结")
            ]),
            researcher: StaticCouncilResearcher(),
            taskStore: taskStore
        )

        let summary = await runner.run(
            request: roomRequest(
                settings: compactRoomSettings(defaultRounds: 1),
                researchConsent: .unavailable
            )
        )

        XCTAssertEqual(summary.status, .completed)
        XCTAssertEqual(runner.taskStatus(taskId: summary.taskId), .completed)
        XCTAssertNil(runner.taskStatus(taskId: "missing-task"))
    }

}
