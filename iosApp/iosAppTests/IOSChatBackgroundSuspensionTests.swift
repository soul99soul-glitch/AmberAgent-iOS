import XCTest
import UIKit
@preconcurrency import Shared
@testable import iosApp

final class IOSChatBackgroundStaleSweepTests: XCTestCase {
    private let taskMapKey = "\(Bundle.main.bundleIdentifier ?? "app.amber.ios").chat.backgroundTaskMap"
    private var originalTaskMap: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalTaskMap = UserDefaults.standard.object(forKey: taskMapKey)
        UserDefaults.standard.removeObject(forKey: taskMapKey)
    }

    override func tearDownWithError() throws {
        if let originalTaskMap {
            UserDefaults.standard.set(originalTaskMap, forKey: taskMapKey)
        } else {
            UserDefaults.standard.removeObject(forKey: taskMapKey)
        }
        try super.tearDownWithError()
    }

    @MainActor
    func testColdStartSweepRemovesPersistedOwnerWithoutSubmittingAnotherRequest() async throws {
        let requestId = "\(Bundle.main.bundleIdentifier ?? "app.amber.ios").chat.stale-run"
        UserDefaults.standard.set([requestId: "stale-run"], forKey: taskMapKey)
        _ = try await IOSDurableRunStore().startChatRun(
            runId: "stale-run",
            startedAt: 1,
            inputDigest: "stale-run",
            conversationId: nil
        )

        let coordinator = IOSChatBackgroundGenerationCoordinator.shared
        coordinator.finalizeStalePersistedJobsIfNeeded()
        coordinator.finalizeStalePersistedJobsIfNeeded()

        let deadline = Date().addingTimeInterval(5)
        while UserDefaults.standard.dictionary(forKey: taskMapKey)?[requestId] != nil,
              Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(
            UserDefaults.standard
                .dictionary(forKey: taskMapKey)?[requestId] == nil,
            "冷启动扫尾后不能保留会触发下一次后台提交的 task map owner"
        )
    }

    @MainActor
    func testStaleSweepOnlyPreservesOutcomeUnknownRecoveryEvidence() {
        XCTAssertTrue(
            IOSChatBackgroundGenerationCoordinator.preservesOutcomeUnknownStaleRecoveryForTesting(
                runStatus: .outcomeUnknown,
                transactionStates: []
            )
        )
        XCTAssertTrue(
            IOSChatBackgroundGenerationCoordinator.preservesOutcomeUnknownStaleRecoveryForTesting(
                runStatus: .running,
                transactionStates: [.outcomeUnknown]
            )
        )
        XCTAssertFalse(
            IOSChatBackgroundGenerationCoordinator.preservesOutcomeUnknownStaleRecoveryForTesting(
                runStatus: .running,
                transactionStates: [.finished]
            )
        )
        XCTAssertTrue(
            IOSChatBackgroundGenerationCoordinator.preservesOutcomeUnknownStaleRecoveryForTesting(
                runStatus: .recoveryPending,
                transactionStates: [.outcomeUnknown]
            )
        )
        XCTAssertTrue(
            IOSChatBackgroundGenerationCoordinator.preservesOutcomeUnknownStaleRecoveryForTesting(
                runStatus: .recoveryPending,
                transactionStates: nil
            )
        )
    }

    @MainActor
    func testForegroundAutoResumeOnlyRestartsSafeOrdinaryStream() {
        XCTAssertTrue(
            IOSChatBackgroundGenerationCoordinator
                .canAutomaticallyResumeOrdinaryJobForTesting(
                    mode: .continueModel,
                    hasDeclaredTools: false
                )
        )
        XCTAssertFalse(
            IOSChatBackgroundGenerationCoordinator
                .canAutomaticallyResumeOrdinaryJobForTesting(
                    mode: .continueModel,
                    hasDeclaredTools: true
                )
        )
        XCTAssertFalse(
            IOSChatBackgroundGenerationCoordinator
                .canAutomaticallyResumeOrdinaryJobForTesting(
                    mode: .singleToolOnly,
                    hasDeclaredTools: false
                )
        )
    }

    @MainActor
    func testColdRestoreRejectsUnknownModeInsteadOfWideningToContinueModel() {
        XCTAssertEqual(
            IOSChatBackgroundGenerationCoordinator.rehydratedModeForTesting("single_tool_only"),
            .singleToolOnly
        )
        XCTAssertNil(
            IOSChatBackgroundGenerationCoordinator.rehydratedModeForTesting("corrupt_future_mode")
        )
    }

    /// 冷启动水合的 `resumeResponse` 没有活跃执行 owner；即使 W3 尚未跑到
    /// （或被 detached-resume 竞态绕过），也必须先把 dangling Started 收口为
    /// outcome-unknown，不能先向服务端重放 response。
    @MainActor
    func testColdStartResumeResponseStopsBeforeUnknownLedgerReplay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResumeUnknown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let fixture = DurableCancelFixture(
            name: "resume-unknown",
            conversationId: conversationId
        )
        let runStore = IOSDurableRunStore()
        let didStartRun = try await runStore.startChatRun(
            runId: fixture.handoff.runId,
            startedAt: fixture.handoff.startedAt,
            inputDigest: fixture.handoff.inputDigest,
            conversationId: conversationId.toHexDashString()
        )
        XCTAssertTrue(didStartRun)
        let ledger = IOSAgentRunLedger()
        let didStartTool = await ledger.recordToolCallStarted(
            runId: fixture.handoff.runId,
            toolCallId: "tc-resume-unknown",
            toolName: "workspace_write",
            argsDigest: "resume-unknown-digest",
            effectClass: .sideEffect
        )
        XCTAssertTrue(didStartTool)

        let sharedSettings = IOSSharedSettingsStore(
            userDefaults: UserDefaults(suiteName: "resume-unknown-\(UUID().uuidString)")!
        )
        _ = sharedSettings.addProvider(fixture.provider)
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            localToolExecutor: nil,
            searchTransport: HandoffTestSearchTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] })
        )
        let coordinator = IOSChatBackgroundGenerationCoordinator.shared
        XCTAssertTrue(coordinator.persistDurableResponseCheckpointForTesting(fixture.handoff))
        var receivedUnknown: IOSToolOutcomeUnknownDescriptor?
        let previousUnknownHandler = coordinator.onToolOutcomeUnknown
        coordinator.onToolOutcomeUnknown = { descriptor in
            receivedUnknown = descriptor
        }
        defer {
            coordinator.onToolOutcomeUnknown = previousUnknownHandler
            coordinator.discardDurableResponse(runId: fixture.handoff.runId)
        }

        coordinator.withDependenciesForTesting(
            conversationStore: store,
            toolRuntime: runtime,
            sharedSettings: sharedSettings
        ) {
            coordinator.resumeDetachedResponsesIfNeeded()
        }

        let deadline = Date().addingTimeInterval(5)
        while receivedUnknown == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let unknown = try XCTUnwrap(receivedUnknown)
        XCTAssertEqual(unknown.runId, fixture.handoff.runId)
        XCTAssertEqual(unknown.toolCallId, "tc-resume-unknown")
        let runSnapshot = try await runStore.snapshot(runId: fixture.handoff.runId)
        XCTAssertEqual(runSnapshot?.status, .outcomeUnknown)
        let transactions = await ledger.toolTransactions(runId: fixture.handoff.runId)
        XCTAssertEqual(transactions?.first?.state, .outcomeUnknown)
        let persistedTaskMap = UserDefaults.standard.dictionary(forKey: taskMapKey) as? [String: String] ?? [:]
        XCTAssertFalse(
            persistedTaskMap.values.contains(fixture.handoff.runId),
            "unknown gate 完成后不能留下可再次 resume 的 task-map owner"
        )
        let storedMessages = await store.messages(for: conversationId)
        let recoveredMessages = try XCTUnwrap(storedMessages)
        XCTAssertFalse(
            recoveredMessages
                .flatMap(\.parts)
                .compactMap { $0 as? UIMessagePart.Tool }
                .first(where: { $0.toolCallId == "tc-resume-unknown" })?.output.isEmpty ?? true
        )
    }

    /// Generic startup recovery must leave a clean durable response runnable;
    /// its coordinator ledger gate runs immediately before `resumeBackground`.
    @MainActor
    func testColdStartResumeResponseStaysRunningForSafeLedger() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResumeSafe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = IOSChatBackgroundGenerationCoordinator.shared
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let fixture = DurableCancelFixture(
            name: "resume-safe",
            conversationId: conversationId
        )
        defer {
            coordinator.discardDurableResponse(runId: fixture.handoff.runId)
            try? FileManager.default.removeItem(at: directory)
        }

        let handoff = fixture.handoff
        let runStore = IOSDurableRunStore()
        let didStartRun = try await runStore.startChatRun(
            runId: handoff.runId,
            startedAt: handoff.startedAt,
            inputDigest: handoff.inputDigest,
            conversationId: conversationId.toHexDashString()
        )
        XCTAssertTrue(didStartRun)

        let sharedSettings = IOSSharedSettingsStore(
            userDefaults: UserDefaults(suiteName: "resume-safe-\(UUID().uuidString)")!
        )
        _ = sharedSettings.addProvider(fixture.provider)
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            localToolExecutor: nil,
            searchTransport: HandoffTestSearchTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] })
        )

        XCTAssertTrue(coordinator.persistDurableResponseCheckpointForTesting(handoff))
        XCTAssertTrue(
            coordinator.hydrateDurableResponseForTesting(
                handoff,
                conversationStore: store,
                toolRuntime: runtime,
                sharedSettings: sharedSettings
            )
        )

        let exclusions = coordinator.startupRecoveryExclusionRunIds
        XCTAssertTrue(exclusions.contains(handoff.runId))
        let candidateRunIds = Set([handoff.runId])
        let pairs = await IOSRunRecovery.unfinishedRunConversationPairs(
            candidateRunIds: candidateRunIds,
            excludingRunIds: exclusions
        )
        XCTAssertEqual(pairs?.count, 0)
        let transitioned = await IOSRunRecovery.recoverInterruptedRuns(
            candidateRunIds: candidateRunIds,
            excludingRunIds: exclusions
        )
        XCTAssertEqual(transitioned, 0)
        let snapshot = try await runStore.snapshot(runId: handoff.runId)
        XCTAssertEqual(snapshot?.status, .running)
        XCTAssertTrue(
            (UserDefaults.standard.dictionary(forKey: taskMapKey) as? [String: String])?.values
                .contains(handoff.runId) == true
        )
        _ = try? await runStore.transition(
            runId: handoff.runId,
            expected: .running,
            to: .cancelled,
            detail: "test_cleanup"
        )
    }

    /// detach 后只剩 task-map/payload，没有 `activeJobs`。按 runId 取消必须
    /// 能水合这份 owner，否则服务端 response 会继续跑、回前台还会续上。
    @MainActor
    func testCancelJobFindsCheckpointedDurableResponseWithoutActiveJob() async {
        let fixture = DurableCancelFixture(name: "durable-cancel")
        await assertCancelFindsCheckpointedOwner(fixture) { coordinator, handoff in
            coordinator.cancelJob(runId: handoff.runId)
        }
    }

    /// Chat 停止按钮走 `cancelActiveJob(conversationId:)`，不是 runId。
    @MainActor
    func testCancelActiveJobFindsCheckpointedDurableResponseWithoutActiveJob() async {
        let fixture = DurableCancelFixture(name: "durable-cancel-conv")
        await assertCancelFindsCheckpointedOwner(fixture) { coordinator, handoff in
            coordinator.cancelActiveJob(conversationId: handoff.conversationId)
        }
    }

    @MainActor
    private func assertCancelFindsCheckpointedOwner(
        _ fixture: DurableCancelFixture,
        cancel: (IOSChatBackgroundGenerationCoordinator, IOSChatBackgroundHandoff) -> Bool
    ) async {
        let coordinator = IOSChatBackgroundGenerationCoordinator.shared
        let didStart = try? await IOSDurableRunStore().startChatRun(
            runId: fixture.handoff.runId,
            startedAt: fixture.handoff.startedAt,
            inputDigest: fixture.handoff.inputDigest,
            conversationId: fixture.handoff.conversationId.toHexDashString()
        )
        XCTAssertEqual(didStart, true)
        XCTAssertTrue(coordinator.persistDurableResponseCheckpointForTesting(fixture.handoff))
        let requestId = UserDefaults.standard
            .dictionary(forKey: taskMapKey)?
            .first(where: { ($0.value as? String) == fixture.handoff.runId })?
            .key
        XCTAssertNotNil(requestId, "checkpoint 必须持有唯一 task-map owner")
        XCTAssertFalse(
            coordinator.restorableRunIds.contains(fixture.handoff.runId),
            "checkpoint 不得提前挂进 activeJobs"
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DurableCancel-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            coordinator.discardDurableResponse(runId: fixture.handoff.runId)
            try? FileManager.default.removeItem(at: directory)
        }

        let sharedSettings = IOSSharedSettingsStore(
            userDefaults: UserDefaults(suiteName: "\(fixture.name)-\(UUID().uuidString)")!
        )
        _ = sharedSettings.addProvider(fixture.provider)
        let store = IOSConversationStore(baseDirectory: directory)
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            localToolExecutor: nil,
            searchTransport: HandoffTestSearchTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] })
        )

        var didCancel = false
        coordinator.withDependenciesForTesting(
            conversationStore: store,
            toolRuntime: runtime,
            sharedSettings: sharedSettings
        ) {
            didCancel = cancel(coordinator, fixture.handoff)
        }
        XCTAssertTrue(didCancel, "只有 payload/task map 时取消也必须生效")

        let deadline = Date().addingTimeInterval(5)
        while let requestId,
              UserDefaults.standard.dictionary(forKey: taskMapKey)?[requestId] != nil,
              Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if let requestId {
            XCTAssertNil(
                UserDefaults.standard.dictionary(forKey: taskMapKey)?[requestId],
                "取消即使终态 transcript 保存失败，也必须清理 durable response owner"
            )
        }
    }
}

private final class HandoffTestSearchTransport: IOSSearchHTTPTransport {
    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (response, Data())
    }
}

private struct DurableCancelFixture {
    let name: String
    let provider: ProviderSetting.OpenAI
    let handoff: IOSChatBackgroundHandoff

    @MainActor
    init(name: String, conversationId: KotlinUuid? = nil) {
        let runId = "\(name)-\(UUID().uuidString)"
        let model = Model(
            modelId: "\(name)-model",
            displayName: "\(name)-model",
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
        let provider = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: name,
            models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "sk-test",
            baseUrl: "https://example.test",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: true,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
        let messages = [
            UIMessage(
                id: KotlinUuid.companion.random(),
                role: MessageRole.assistant,
                parts: [],
                annotations: [],
                createdAt: Kotlinx_datetimeLocalDateTime(
                    year: 2026, month: 8, day: 16, hour: 0, minute: 0, second: 0, nanosecond: 0
                ),
                finishedAt: nil,
                modelId: nil,
                usage: nil,
                translation: nil
            )
        ]
        var handoff = IOSChatBackgroundHandoff(
            runId: runId,
            startedAt: Int64(Date().timeIntervalSince1970 * 1000),
            inputDigest: "\(name)-digest",
            conversationId: conversationId ?? KotlinUuid.companion.random(),
            providerId: provider.id.toHexDashString(),
            providerSetting: provider,
            params: TextGenerationParams(
                model: model,
                temperature: KotlinFloat(value: 0.7),
                topP: nil,
                maxTokens: nil,
                tools: [],
                reasoningLevel: .off,
                customHeaders: [],
                customBody: []
            ),
            uploadMessages: messages,
            displayMessages: messages,
            mode: .resumeResponse,
            generativeUiRequirement: .none,
            generativeUiFallbackAttempted: false,
            fullToolNames: []
        )
        handoff.responseId = "resp-\(runId)"
        self.name = name
        self.provider = provider
        self.handoff = handoff
    }
}
