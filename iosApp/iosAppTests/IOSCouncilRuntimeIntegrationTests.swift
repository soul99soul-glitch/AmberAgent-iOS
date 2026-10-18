import XCTest
import SwiftUI
import Observation
@preconcurrency import Shared
@testable import iosApp


@MainActor
final class IOSCouncilRuntimeIntegrationTests: IOSCouncilMechanicsTestCase {
    func testViewModelDoesNotResearchWhenWebSearchIsDisabled() async throws {
        let researcher = RecordingCouncilResearcher()
        let harness = try makeViewModelHarness(
            streamer: ScriptedCouncilStreamer([
                .success("最终议题"),
                .success("工程发言"),
                .success("风险发言"),
                .success("主持总结")
            ]),
            researcher: researcher
        )
        harness.sharedSettings.setEnableWebSearch(false)

        harness.viewModel.inputText = "不联网议题"
        harness.viewModel.send()
        for _ in 0..<200 where harness.viewModel.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(researcher.callCount, 0)
        let task = try XCTUnwrap(harness.taskStore.recent(kind: .modelCouncil, limit: 1).first)
        XCTAssertEqual(task.toolScope, [])
        XCTAssertEqual(task.metadata["research_consent"], IOSCouncilResearchConsent.unavailable.rawValue)
    }

    func testChatCouncilToolWaitsForPermissionBeforeStartingRun() async throws {
        let defaults = isolatedDefaults()
        let permissionStore = IOSPermissionStore(userDefaults: defaults, taskStore: nil)
        let localToolExecutor = IOSLocalToolExecutor(
            permissionStore: permissionStore,
            documentStore: DocumentAccessStore(),
            workspaceStore: IOSWorkspaceStore(
                baseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("council-tool-test-\(UUID().uuidString)")
            )
        )
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: defaults),
            localToolExecutor: localToolExecutor,
            searchTransport: IOSURLSessionSearchHTTPTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] })
        )
        let provider = IOSCouncilRoomRunner.makeProviderSetting(
            baseUrl: "https://example.com/v1",
            apiKey: "test-key"
        )
        let model = Model(
            modelId: "gpt-main",
            displayName: "Council Test Model",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        let params = TextGenerationParams(
            model: model,
            temperature: nil,
            topP: nil,
            maxTokens: nil,
            tools: [],
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
        let toolCall = UIMessagePart.Tool(
            toolCallId: "council-approval",
            toolName: "model_council_run",
            input: #"{"objective":"审查发布风险","max_seats":4}"#,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let assistantSeed = UIMessage.companion.assistant(prompt: "")
        let assistant = UIMessage(
            id: assistantSeed.id,
            role: assistantSeed.role,
            parts: [toolCall],
            annotations: assistantSeed.annotations,
            createdAt: assistantSeed.createdAt,
            finishedAt: assistantSeed.finishedAt,
            modelId: assistantSeed.modelId,
            usage: assistantSeed.usage,
            translation: assistantSeed.translation
        )
        let context = ChatPendingToolApproval(
            toolCall: toolCall,
            providerSetting: provider,
            params: params,
            runId: "run-council-approval",
            startedAt: 0,
            inputDigest: "digest",
            conversationId: nil,
            baseMessages: [assistant]
        )
        let result = await runtime.execute(
            ChatPendingToolCall(kind: .advanced, toolCall: toolCall),
            context: context
        )

        guard case .waitingForApproval(.council(let request)) = result else {
            return XCTFail("Council tool must wait for its configured approval policy.")
        }
        XCTAssertEqual(request.objectivePreview, "审查发布风险")
        XCTAssertEqual(request.maxSeats, 4)

        let deniedMessages = await runtime.finishCouncilApproval(
            pending: context,
            allow: false
        )
        let deniedTool = try XCTUnwrap(
            deniedMessages.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }.first
        )
        XCTAssertEqual(
            ChatToolOutputFormatter.failureReason(from: deniedTool.output),
            "用户拒绝启动模型议会。"
        )
        XCTAssertEqual(permissionStore.approvalRecords.first?.action, .denied)
    }

    func testCouncilToolFailureWithoutReasonStillRendersAsFailure() {
        let output: [UIMessagePart] = [
            UIMessagePart.Text(
                text: #"{"ok":false,"status":"failed"}"#,
                metadata: nil
            )
        ]

        XCTAssertEqual(
            ChatToolOutputFormatter.failureReason(from: output),
            "工具执行失败"
        )
    }

    func testOpeningArchiveCheckpointsActiveCouncilTailBeforeReplacingRoom() async throws {
        let firstStreamStarted = expectation(description: "active council stream started before archive switch")
        let harness = try makeViewModelHarness(
            streamer: RestartableCouncilStreamer(firstStreamStarted: firstStreamStarted)
        )
        let targetTaskID = "archived-target"
        harness.archiveStore.save(CouncilPersistedRoom(
            taskId: targetTaskID,
            objective: "历史议题",
            modeRaw: CouncilDiscussionMode.freeChat.rawValue,
            statusRaw: "就绪",
            failedSpeakerIds: [],
            participants: harness.viewModel.participants.map(CouncilPersistedParticipant.init),
            messages: [CouncilPersistedMessage(CouncilChatMessage(
                kind: .system,
                author: "议会",
                body: "历史内容",
                systemImage: "clock",
                tint: .gray,
                subtitle: nil
            ))],
            updatedAtMs: 1
        ))

        harness.viewModel.inputText = "运行中的议题"
        harness.viewModel.send()
        await fulfillment(of: [firstStreamStarted], timeout: 1)
        let activeTaskID = try XCTUnwrap(
            harness.taskStore.recent(kind: .modelCouncil, limit: 1).first?.id
        )

        harness.viewModel.openArchive(taskId: targetTaskID)

        let checkpoint = try XCTUnwrap(harness.archiveStore.load(taskId: activeTaskID))
        XCTAssertTrue(checkpoint.messages.contains { $0.body == "旧轮精确尾部" })
        XCTAssertFalse(checkpoint.messages.contains { $0.status == "speaking" })
        XCTAssertEqual(checkpoint.statusRaw, "已取消")
        XCTAssertEqual(harness.viewModel.activeReplayTaskId, targetTaskID)
        XCTAssertEqual(harness.viewModel.messages.last?.body, "历史内容")
    }

    func testStartingFreshRoomCheckpointsActiveCouncilTailBeforeClearingRoom() async throws {
        let firstStreamStarted = expectation(description: "active council stream started before room reset")
        let harness = try makeViewModelHarness(
            streamer: RestartableCouncilStreamer(firstStreamStarted: firstStreamStarted)
        )

        harness.viewModel.inputText = "即将重开的议题"
        harness.viewModel.send()
        await fulfillment(of: [firstStreamStarted], timeout: 1)
        let activeTaskID = try XCTUnwrap(
            harness.taskStore.recent(kind: .modelCouncil, limit: 1).first?.id
        )

        harness.viewModel.startFreshRoom()

        let checkpoint = try XCTUnwrap(harness.archiveStore.load(taskId: activeTaskID))
        XCTAssertTrue(checkpoint.messages.contains { $0.body == "旧轮精确尾部" })
        XCTAssertFalse(checkpoint.messages.contains { $0.status == "speaking" })
        XCTAssertEqual(checkpoint.statusRaw, "已取消")
        XCTAssertFalse(harness.viewModel.isRunning)
        XCTAssertTrue(harness.viewModel.messages.isEmpty)
    }

    func testRoomRunnerMissingAPIKeyFailsBeforeStreaming() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let streamer = ScriptedCouncilStreamer([])
        let runner = IOSCouncilRoomRunner(
            streamer: streamer,
            researcher: StaticCouncilResearcher(),
            taskStore: taskStore
        )

        let outcome = await runner.run(
            request: roomRequest(
                settings: compactRoomSettings(),
                apiKey: "",
                researchConsent: .unavailable
            )
        )

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(outcome.failureReason?.contains("API Key") == true)
        XCTAssertEqual(streamer.callCount, 0)
        let task = try XCTUnwrap(taskStore.recent(kind: .modelCouncil, limit: 1).first)
        XCTAssertEqual(task.status, .failed)
        XCTAssertTrue(task.error.contains("API Key"))
    }

    func testStartupRecoveryOnlyInterruptsRunningCouncilTasks() throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let runningCouncil = taskStore.startTask(
            kind: .modelCouncil,
            title: "running council",
            objective: "council"
        )
        let completedCouncil = taskStore.startTask(
            kind: .modelCouncil,
            title: "completed council",
            objective: "done"
        )
        _ = taskStore.updateTask(id: completedCouncil.id, status: .completed)
        let runningContinuation = taskStore.startTask(
            kind: .modelCouncil,
            title: "running follow-up",
            objective: "follow-up",
            metadata: ["continuation_base_completed": "true"]
        )
        let runningSubAgent = taskStore.startTask(
            kind: .subAgent,
            title: "running subagent",
            objective: "subagent"
        )

        let interruptedIDs = taskStore.markInterruptedCouncilTasks()
        let secondPass = taskStore.markInterruptedCouncilTasks()

        XCTAssertEqual(Set(interruptedIDs), Set([runningCouncil.id, runningContinuation.id]))
        XCTAssertTrue(secondPass.isEmpty)
        XCTAssertEqual(taskStore.tasks.first { $0.id == runningCouncil.id }?.status, .interrupted)
        XCTAssertEqual(taskStore.tasks.first { $0.id == runningCouncil.id }?.metadata["interruption_reason"], "process_terminated")
        XCTAssertEqual(taskStore.tasks.first { $0.id == runningContinuation.id }?.status, .completed)
        XCTAssertEqual(
            taskStore.tasks.first { $0.id == runningContinuation.id }?.metadata["continuation_status"],
            IOSAdvancedTaskStatus.interrupted.rawValue
        )
        XCTAssertEqual(taskStore.tasks.first { $0.id == completedCouncil.id }?.status, .completed)
        XCTAssertEqual(taskStore.tasks.first { $0.id == runningSubAgent.id }?.status, .running)
    }

}
