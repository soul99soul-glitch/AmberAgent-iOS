import XCTest
import SwiftUI
import Observation
@preconcurrency import Shared
@testable import iosApp


@MainActor
final class IOSCouncilRuntimeOwnershipTests: IOSCouncilMechanicsTestCase {
    func testLateDurableStartFailureCannotReleaseReplacementDiscussion() async throws {
        let oldStart = CouncilDurableAwaitGate(started: expectation(description: "old durable start paused"))
        let replacementStart = CouncilDurableAwaitGate(started: expectation(description: "replacement durable start paused"))
        var starts = 0
        let harness = try makeViewModelHarness(
            streamer: ScriptedCouncilStreamer([
                .success("新议题"), .success("新工程发言"), .success("新风险发言"), .success("新主持总结")
            ]),
            durableRunAwaiter: { point, operation in
                let result = await operation()
                guard case .start = point else { return result }
                starts += 1
                if starts == 1 {
                    await oldStart.wait()
                    return false
                }
                await replacementStart.wait()
                return result
            }
        )
        defer { oldStart.resume(); replacementStart.resume() }
        harness.viewModel.inputText = "旧议题"
        harness.viewModel.send()
        await fulfillment(of: [oldStart.started], timeout: 1)
        harness.viewModel.cancelDiscussion()
        harness.viewModel.inputText = "新议题"
        harness.viewModel.send()
        await fulfillment(of: [replacementStart.started], timeout: 1)

        oldStart.resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(harness.viewModel.isRunning, "The late failed start must not release the replacement owner.")
        XCTAssertFalse(harness.viewModel.messages.contains { $0.body == "无法保存运行状态，本轮议会未启动。" })

        replacementStart.resume()
        for _ in 0..<200 where harness.viewModel.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(harness.viewModel.isRunning)
        XCTAssertEqual(harness.viewModel.messages.last(where: { $0.kind == .host })?.body, "新主持总结")
    }

    func testLateDurableCompletionCannotReleaseReplacementDiscussion() async throws {
        let oldCompletion = CouncilDurableAwaitGate(started: expectation(description: "old durable completion paused"))
        let replacementStart = CouncilDurableAwaitGate(started: expectation(description: "replacement durable start paused"))
        var starts = 0
        var completions = 0
        let harness = try makeViewModelHarness(
            streamer: ScriptedCouncilStreamer([
                .success("旧议题"), .success("旧工程发言"), .success("旧风险发言"), .success("旧主持总结"),
                .success("新议题"), .success("新工程发言"), .success("新风险发言"), .success("新主持总结")
            ]),
            durableRunAwaiter: { point, operation in
                let result = await operation()
                switch point {
                case .start:
                    starts += 1
                    if starts == 2 { await replacementStart.wait() }
                case .completion:
                    completions += 1
                    if completions == 1 { await oldCompletion.wait() }
                case .configurationFailure:
                    break
                }
                return result
            }
        )
        defer { oldCompletion.resume(); replacementStart.resume() }
        harness.viewModel.inputText = "旧议题"
        harness.viewModel.send()
        await fulfillment(of: [oldCompletion.started], timeout: 1)
        harness.viewModel.cancelDiscussion()
        harness.viewModel.startFreshRoom()
        harness.viewModel.inputText = "新议题"
        harness.viewModel.send()
        await fulfillment(of: [replacementStart.started], timeout: 1)

        oldCompletion.resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(harness.viewModel.isRunning, "The late terminal write must not clear the replacement owner.")
        XCTAssertFalse(harness.viewModel.messages.contains { $0.body == "旧主持总结" })

        replacementStart.resume()
        for _ in 0..<200 where harness.viewModel.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(harness.viewModel.isRunning)
        XCTAssertEqual(harness.viewModel.messages.last(where: { $0.kind == .host })?.body, "新主持总结")
    }

    func testViewModelCancelClosesStreamingTailAndRejectsOldRunEventsAfterRestart() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let firstStreamStarted = expectation(description: "view model first stream started")
        let streamer = RestartableCouncilStreamer(firstStreamStarted: firstStreamStarted)
        let runner = IOSCouncilRoomRunner(
            streamer: streamer,
            researcher: StaticCouncilResearcher(),
            taskStore: taskStore
        )
        let settingsStore = SettingsStore(
            userDefaults: defaults,
            storageKey: "legacy-settings",
            apiKeyStore: CouncilTestAPIKeyStore(key: "test-key")
        )
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "Council Test Provider",
            apiKey: "test-key",
            baseUrl: "https://example.com/v1",
            modelName: "Council Test Model",
            modelId: "gpt-main"
        )
        _ = sharedSettings.addProvider(provider)
        let model = try XCTUnwrap(
            sharedSettings.availableChatModels().first { $0.providerName == "Council Test Provider" }
        )
        sharedSettings.setCurrentChatModelId(model.id)
        let roomSettings = IOSCouncilRoomSettingsStore(
            userDefaults: defaults,
            storageKey: "room-settings",
            currentModelId: "gpt-main"
        )
        roomSettings.settings = compactRoomSettings(defaultRounds: 1)
        roomSettings.dynamicSeatGeneration = false
        let archiveStore = CouncilRoomArchiveStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("council-vm-test-\(UUID().uuidString)", isDirectory: true)
        )
        let viewModel = CouncilChatViewModel(
            settingsStore: settingsStore,
            sharedSettings: sharedSettings,
            providerRegistry: nil,
            permissionStore: IOSPermissionStore(
                userDefaults: defaults,
                storageKey: "policies",
                approvalStorageKey: "approvals",
                taskStore: taskStore
            ),
            roomSettingsStore: roomSettings,
            runner: runner,
            transcriptDefaults: defaults,
            archiveStore: archiveStore
        )

        viewModel.inputText = "第一轮"
        viewModel.send()
        await fulfillment(of: [firstStreamStarted], timeout: 1)
        viewModel.cancelDiscussion()

        XCTAssertFalse(viewModel.messages.contains { $0.status == .speaking })
        XCTAssertEqual(
            viewModel.messages.first { $0.body == "旧轮精确尾部" }?.status,
            .failed,
            "取消时尚未完成的流式尾部不能伪装成已完成。"
        )

        viewModel.inputText = "第二轮"
        viewModel.send()
        for _ in 0..<200 where viewModel.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertFalse(viewModel.isRunning)
        XCTAssertFalse(viewModel.messages.contains { $0.status == .speaking })
        XCTAssertFalse(
            viewModel.messages.contains { $0.body == "模型议会已取消。" },
            "The cancelled run's late terminal event must not enter the replacement room."
        )
        XCTAssertEqual(viewModel.messages.last(where: { $0.kind == .host })?.body, "主持总结")
    }

    func testViewModelCancelArchivesFailedSeatStatus() async throws {
        let hostStarted = expectation(description: "final host stream started")
        let harness = try makeViewModelHarness(
            streamer: FailedSeatThenBlockingCouncilStreamer(hostStarted: hostStarted)
        )

        harness.viewModel.inputText = "停止后保留失败席位"
        harness.viewModel.send()
        await fulfillment(of: [hostStarted], timeout: 1)
        let taskID = try XCTUnwrap(
            harness.taskStore.recent(kind: .modelCouncil, limit: 1).first?.id
        )

        harness.viewModel.cancelDiscussion()

        let archive = try XCTUnwrap(harness.archiveStore.load(taskId: taskID))
        XCTAssertTrue(
            archive.failedSpeakerIds.contains("risk"),
            "Cancelling a run must preserve failed seat evidence in the archive."
        )
    }

    func testDetachedCouncilRuntimeFinishesWithoutCancellingTheOwner() async throws {
        let streamer = ScriptedCouncilStreamer([
            .success("最终议题"),
            .success("工程发言"),
            .success("风险发言"),
            .success("主持总结")
        ])
        let harness = try makeViewModelHarness(streamer: streamer)

        harness.viewModel.inputText = "离页后继续完成"
        harness.viewModel.send()
        harness.viewModel.runtimeDidDisappear()

        for _ in 0..<200 where harness.viewModel.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertFalse(harness.viewModel.isRunning)
        XCTAssertEqual(harness.viewModel.messages.last(where: { $0.kind == .host })?.body, "主持总结")
    }

    func testSubmittedCouncilInputIsPersistedBeforeRunnerTaskStarts() throws {
        let harness = try makeViewModelHarness(streamer: ScriptedCouncilStreamer([]))

        harness.viewModel.inputText = "进程启动前也要保留的议题"
        harness.viewModel.send()

        let transcript = try XCTUnwrap(CouncilTranscriptStore.load(defaults: harness.defaults))
        XCTAssertEqual(transcript.messages.last?.body, "进程启动前也要保留的议题")
        XCTAssertTrue(transcript.messages.last?.kind == CouncilMessageKind.user.rawKey)

        // Avoid leaving the test-owned foreground task alive after the synchronous assertion.
        harness.viewModel.cancelDiscussion()
    }

    func testConfigurationErrorMessageSurfacesWhenChatModelMissing() throws {
        let harness = try makeViewModelHarness(streamer: ScriptedCouncilStreamer([]))
        harness.sharedSettings.setCurrentChatModelId("00000000-0000-0000-0000-000000000000")

        XCTAssertEqual(
            harness.viewModel.configurationErrorMessage,
            ChatConfigurationIssue.missingModel.message
        )
        harness.viewModel.inputText = "有议题也发不出去"
        XCTAssertFalse(harness.viewModel.canSend)
    }

    func testMembersSeatFooterFollowsDynamicSeatGeneration() {
        XCTAssertEqual(
            CouncilMembersCopy.seatSectionFooter(isRunning: true, dynamicSeatGeneration: false),
            "本轮议会运行中，模式与席位下一轮生效。"
        )
        XCTAssertEqual(
            CouncilMembersCopy.seatSectionFooter(isRunning: false, dynamicSeatGeneration: true),
            "席位由主持人按议题联网调研后动态组建。"
        )
        XCTAssertEqual(
            CouncilMembersCopy.seatSectionFooter(isRunning: false, dynamicSeatGeneration: false),
            "席位来自设置中已添加的固定角色。"
        )
    }

    func testGuestBubbleUsesThemeSurfaceToken() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let presentationModels = try String(
            contentsOf: testDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("iosApp/Council/CouncilPresentationModels.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            presentationModels.contains("case .guest: return AmberTheme.surface2"),
            "Guest bubbles must use a theme surface token so dark mode does not stay paper-white."
        )
        XCTAssertFalse(
            presentationModels.contains("case .guest: return Color.white"),
            "Hard-coded Color.white guest bubbles regress dark/theme hierarchy."
        )
    }

    func testSpeakingPartialTailIsCheckpointedByTheExistingThrottle() async throws {
        let partialPublished = expectation(description: "partial seat tail published")
        let streamer = DelayedPartialCouncilStreamer(partialPublished: partialPublished)
        let harness = try makeViewModelHarness(streamer: streamer)

        harness.viewModel.inputText = "中途发言也要保留"
        harness.viewModel.send()
        await fulfillment(of: [partialPublished], timeout: 2)
        try await Task.sleep(nanoseconds: 350_000_000)
        await harness.archiveStore.flushDeferred()

        let taskID = try XCTUnwrap(
            harness.taskStore.recent(kind: .modelCouncil, limit: 1).first?.id
        )
        let archive = try XCTUnwrap(harness.archiveStore.load(taskId: taskID))
        XCTAssertTrue(
            archive.messages.contains { $0.body == DelayedPartialCouncilStreamer.partialTail },
            "A speaking update must reach the existing throttled archive checkpoint."
        )

        harness.viewModel.cancelDiscussion()
    }

    func testSecondSendContinuesCurrentCouncilAsFollowUpRound() async throws {
        let streamer = ScriptedCouncilStreamer([
            .success("第一场最终议题"),
            .success("第一场工程发言"),
            .success("第一场风险发言"),
            .success("第一场主持总结"),
            .success("第二轮工程发言"),
            .success("第二轮风险发言"),
            .success("第二轮主持总结"),
            .success("不应发生的额外调用")
        ])
        let harness = try makeViewModelHarness(streamer: streamer)

        harness.viewModel.inputText = "第一场用户议题"
        harness.viewModel.send()
        for _ in 0..<200 where harness.viewModel.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let taskID = try XCTUnwrap(
            harness.taskStore.recent(kind: .modelCouncil, limit: 1).first?.id
        )

        harness.viewModel.inputText = "补充：请重点解释证据不足的地方"
        harness.viewModel.send()
        for _ in 0..<200 where harness.viewModel.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let tasks = harness.taskStore.recent(kind: .modelCouncil, limit: 2)
        let archive = try XCTUnwrap(harness.archiveStore.load(taskId: taskID))

        XCTAssertEqual(tasks.map(\.id), [taskID], "追问应继续同一议会任务，而不是另开议题。")
        XCTAssertTrue(archive.messages.contains { $0.body == "第一场用户议题" })
        XCTAssertTrue(archive.messages.contains { $0.body == "第一场主持总结" })
        XCTAssertTrue(archive.messages.contains { $0.body == "补充：请重点解释证据不足的地方" })
        XCTAssertTrue(archive.messages.contains { $0.body == "第二轮主持总结" })
        XCTAssertEqual(harness.viewModel.discussionRound, 2)
        XCTAssertEqual(harness.viewModel.messages.last(where: { $0.kind == .host })?.body, "第二轮主持总结")
        let followUpPrompts = streamer.receivedUserPrompts.suffix(3)
        XCTAssertEqual(followUpPrompts.count, 3)
        XCTAssertTrue(followUpPrompts.allSatisfy { $0.contains("第一场主持总结") })
        XCTAssertTrue(followUpPrompts.allSatisfy { $0.contains("补充：请重点解释证据不足的地方") })
        XCTAssertTrue(followUpPrompts.allSatisfy { $0.contains("最终议题：\n第一场最终议题") })
    }

    func testFailedFollowUpKeepsCompletedCouncilEligibleForAnotherRound() async throws {
        let streamer = ScriptedCouncilStreamer([
            .success("首轮最终议题"),
            .success("首轮工程发言"),
            .success("首轮风险发言"),
            .success("首轮主持总结"),
            .success("失败轮工程发言"),
            .success("失败轮风险发言"),
            .failure(CouncilTestError.scriptedFailure),
            .success("第三轮工程发言"),
            .success("第三轮风险发言"),
            .success("第三轮主持总结")
        ])
        let harness = try makeViewModelHarness(streamer: streamer)

        harness.viewModel.inputText = "首轮议题"
        harness.viewModel.send()
        for _ in 0..<200 where harness.viewModel.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let taskID = try XCTUnwrap(
            harness.taskStore.recent(kind: .modelCouncil, limit: 1).first?.id
        )

        harness.viewModel.inputText = "第二轮追问"
        harness.viewModel.send()
        for _ in 0..<200 where harness.viewModel.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(
            harness.taskStore.tasks.first { $0.id == taskID }?.status,
            .completed,
            "失败的追加轮不能覆盖此前已经完成的议会终态。"
        )
        XCTAssertEqual(harness.viewModel.composerPlaceholder, "输入补充或追问，再讨论一轮")

        harness.viewModel.inputText = "第三轮继续追问"
        harness.viewModel.send()
        for _ in 0..<200 where harness.viewModel.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(harness.taskStore.recent(kind: .modelCouncil, limit: 2).map(\.id), [taskID])
        XCTAssertEqual(harness.viewModel.discussionRound, 3)
        XCTAssertEqual(harness.viewModel.messages.last(where: { $0.kind == .host })?.body, "第三轮主持总结")
    }

    func testHomeResumeContextRestoresEveryRecoverableContinuationStatus() async throws {
        let harness = try makeViewModelHarness(streamer: ScriptedCouncilStreamer([
            .success("首轮最终议题"),
            .success("首轮工程发言"),
            .success("首轮风险发言"),
            .success("首轮主持总结"),
        ]))

        harness.viewModel.inputText = "首轮议题"
        harness.viewModel.send()
        for _ in 0..<200 where harness.viewModel.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let taskID = try XCTUnwrap(
            harness.taskStore.recent(kind: .modelCouncil, limit: 1).first?.id
        )
        for status in [
            IOSAdvancedTaskStatus.failed,
            .cancelled,
            .timedOut,
            .interrupted,
        ] {
            _ = harness.taskStore.updateTask(
                id: taskID,
                status: .completed,
                metadata: ["continuation_status": status.rawValue]
            )

            let context = try XCTUnwrap(harness.viewModel.homeResumeContext)
            XCTAssertEqual(context.status, status)
            XCTAssertTrue(context.canContinue)
        }
    }

    func testHomeResumeContextRejectsUndecodableArchive() async throws {
        let harness = try makeViewModelHarness(streamer: ScriptedCouncilStreamer([
            .success("首轮最终议题"),
            .success("首轮工程发言"),
            .success("首轮风险发言"),
            .success("首轮主持总结"),
        ]))

        harness.viewModel.inputText = "首轮议题"
        harness.viewModel.send()
        for _ in 0..<200 where harness.viewModel.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let taskID = try XCTUnwrap(
            harness.taskStore.recent(kind: .modelCouncil, limit: 1).first?.id
        )
        let archiveURL = harness.archiveBaseDirectory
            .appendingPathComponent("council", isDirectory: true)
            .appendingPathComponent("\(taskID).json", isDirectory: false)
        try Data("not-json".utf8).write(to: archiveURL, options: .atomic)

        XCTAssertNil(harness.viewModel.homeResumeContext)
    }

    func testHomeResumeContextRejectsMismatchedArchiveIdentity() async throws {
        let harness = try makeViewModelHarness(streamer: ScriptedCouncilStreamer([
            .success("首轮最终议题"),
            .success("首轮工程发言"),
            .success("首轮风险发言"),
            .success("首轮主持总结"),
        ]))

        harness.viewModel.inputText = "首轮议题"
        harness.viewModel.send()
        for _ in 0..<200 where harness.viewModel.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let taskID = try XCTUnwrap(
            harness.taskStore.recent(kind: .modelCouncil, limit: 1).first?.id
        )
        let archiveURL = harness.archiveBaseDirectory
            .appendingPathComponent("council", isDirectory: true)
            .appendingPathComponent("\(taskID).json", isDirectory: false)
        let archiveData = try Data(contentsOf: archiveURL)
        var archive = try XCTUnwrap(
            JSONSerialization.jsonObject(with: archiveData) as? [String: Any]
        )
        archive["taskId"] = "another-task"
        try JSONSerialization.data(withJSONObject: archive)
            .write(to: archiveURL, options: .atomic)

        XCTAssertNil(harness.viewModel.homeResumeContext)
    }

    func testHomeResumeProjectionInvalidatesWhenFirstCouncilStarts() async throws {
        let streamStarted = expectation(description: "first council stream started")
        let harness = try makeViewModelHarness(
            streamer: RestartableCouncilStreamer(firstStreamStarted: streamStarted)
        )
        let projectionChanged = expectation(description: "home resume projection invalidated")
        withObservationTracking {
            XCTAssertNil(harness.viewModel.homeResumeContext)
        } onChange: {
            projectionChanged.fulfill()
        }

        harness.viewModel.inputText = "新议题"
        harness.viewModel.send()
        await fulfillment(of: [projectionChanged, streamStarted], timeout: 1)
        harness.viewModel.cancelDiscussion()
    }

    func testFollowUpRestoresEvictedTaskWithTheSameIdentity() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let streamer = ScriptedCouncilStreamer([
            .success("工程续轮发言"),
            .success("风险续轮发言"),
            .success("主持续轮总结")
        ])
        let runner = IOSCouncilRoomRunner(
            streamer: streamer,
            researcher: StaticCouncilResearcher(),
            taskStore: taskStore
        )
        var request = roomRequest(
            settings: compactRoomSettings(defaultRounds: 1),
            researchConsent: .unavailable
        )
        request.continuation = IOSCouncilRoomContinuation(
            taskId: "evicted-council-task",
            originalObjective: "原始议题",
            finalTopic: "主持完善后的最终议题",
            priorTranscript: "[主持人] 既有总结",
            speakers: [
                IOSCouncilRoomSpeaker(
                    id: "host",
                    name: "主持人",
                    rolePrompt: "主持与综合",
                    modelId: "gpt-main",
                    reasoning: .off,
                    prompt: "",
                    isHost: true
                ),
                IOSCouncilRoomSpeaker(
                    id: "engineering",
                    name: "工程",
                    rolePrompt: "工程实现",
                    modelId: "gpt-main",
                    reasoning: .medium,
                    prompt: "",
                    isHost: false
                ),
                IOSCouncilRoomSpeaker(
                    id: "risk",
                    name: "风险",
                    rolePrompt: "风险审计",
                    modelId: "gpt-main",
                    reasoning: .medium,
                    prompt: "",
                    isHost: false
                )
            ],
            nextRound: 2
        )

        let outcome = await runner.run(request: request)

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.taskId, "evicted-council-task")
        XCTAssertEqual(taskStore.tasks.map(\.id), ["evicted-council-task"])
    }

    func testMidRunCheckpointsThrottleToOffMainThreadWrites() async throws {
        // 旧实现:roster/append/消息完结每个事件都在主线程同步 save(≈11 次 encode+write)。
        // 新实现:中段事件经 300ms 节流合并成离主线程延迟写,终态一次同步写收口。
        // ScriptedCouncilStreamer 无 pacing,事件密集到达 → 节流任务在终态前不会单独触发,
        // 因此写入次数应远低于事件数(这里断言 ≤5,旧实现约 11 会红)。
        let harness = try makeViewModelHarness(streamer: ScriptedCouncilStreamer([
            .success("最终议题"),
            .success("工程发言"),
            .success("风险发言"),
            .success("主持总结")
        ]))

        harness.viewModel.inputText = "归档节流议题"
        harness.viewModel.send()
        for _ in 0..<200 where harness.viewModel.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(harness.viewModel.isRunning)

        let taskID = try XCTUnwrap(
            harness.taskStore.recent(kind: .modelCouncil, limit: 1).first?.id
        )
        let archive = try XCTUnwrap(harness.archiveStore.load(taskId: taskID))
        XCTAssertTrue(
            archive.messages.contains { $0.body == "主持总结" },
            "终态同步写必须把完成态落盘,load-after-save 要看到最新事实。"
        )
        XCTAssertGreaterThanOrEqual(
            harness.archiveStore.completedWriteCount, 2,
            "至少应有 taskStarted 与终态两次同步写。"
        )
        XCTAssertLessThanOrEqual(
            harness.archiveStore.completedWriteCount, 5,
            "中段检查点应防抖合并,不能每条消息都在主线程同步落盘。"
        )
    }

}
