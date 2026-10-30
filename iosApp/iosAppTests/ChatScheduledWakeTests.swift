import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatScheduledWakeTests: XCTestCase {
    private final class AuxiliaryProvider: IOSAgentTextProvider, @unchecked Sendable {
        func generateText(
            providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams
        ) async throws -> MessageChunk {
            IOSChatForegroundFixtures.chunk(with: nil)
        }
    }

    private final class Provider: IOSAgentTextProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var capturedMessages: [UIMessage] = []
        private var capturedParams: TextGenerationParams?
        private var held: Bool

        init(hold: Bool = false) { held = hold }
        func release() { lock.withLock { held = false } }

        var request: ([UIMessage], TextGenerationParams?) {
            lock.withLock { (capturedMessages, capturedParams) }
        }

        func generateText(
            providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams
        ) async throws -> MessageChunk {
            lock.withLock {
                capturedMessages = messages
                capturedParams = params
            }
            while lock.withLock({ held }) {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            return IOSChatForegroundFixtures.chunk(
                with: IOSChatForegroundFixtures.assistantText("scheduled work finished")
            )
        }
    }

    private final class SchedulingProvider: IOSAgentTextProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var initialRound = 0
        private var wakeRequests: [[UIMessage]] = []

        var resumedRequests: [[UIMessage]] { lock.withLock { wakeRequests } }

        func generateText(
            providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams
        ) async throws -> MessageChunk {
            if messages.last(where: { $0.role == .user })?.toText()
                .hasPrefix("[Amber scheduled continuation]") == true {
                lock.withLock { wakeRequests.append(messages) }
                return IOSChatForegroundFixtures.chunk(
                    with: IOSChatForegroundFixtures.assistantText("原任务的研究结果已整理完成")
                )
            }
            let round = lock.withLock { initialRound += 1; return initialRound }
            if round > 2 {
                return IOSChatForegroundFixtures.chunk(
                    with: IOSChatForegroundFixtures.assistantText("已保存收到结果后继续的计划")
                )
            }
            let call = UIMessagePart.Tool(
                toolCallId: "schedule-e2e-\(round)",
                toolName: round == 1 ? "tool_search" : "wake_schedule",
                input: round == 1 ? #"{"query":"wake_schedule","limit":5}"#
                    : #"{"title":"收到研究结果后整理","prompt":"读取事件中的研究结果，整理结论并发回原对话。","event":"e2e-research-ready"}"#,
                output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
            )
            return IOSChatForegroundFixtures.chunk(
                with: IOSChatForegroundFixtures.assistantMessage(parts: [call]), finishReason: "tool_calls"
            )
        }
    }

    private func makeViewModel(
        store: IOSConversationStore, provider: any IOSAgentTextProvider,
        autoGenerateResponses: Bool = true, wakeScheduler: IOSWakeScheduler? = nil,
        phoneControl: IOSPhoneControlController = .shared
    ) -> ChatViewModel {
        let defaults = UserDefaults(suiteName: "ChatScheduledWakeTests-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let configured = settings.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "Wake test", apiKey: "sk-test", baseUrl: "https://opencode.ai/zen/go/v1",
            modelName: "Wake test", modelId: "gpt-wake-test"
        ))
        settings.setCurrentChatModelId(configured.models.first!.id.description())
        let database = IosDatabaseFactory.shared.createDatabase(atFilePath:
            FileManager.default.temporaryDirectory.appendingPathComponent("wake-test-\(UUID().uuidString).db").path
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(userDefaults: defaults), sharedSettings: settings,
            autoGenerateResponses: autoGenerateResponses, auxiliaryTextProvider: AuxiliaryProvider(),
            agentRuntimeDao: database.agentRuntimeDao(), phoneControl: phoneControl, wakeScheduler: wakeScheduler
        )
        viewModel.kernelTextProviderOverrideForTesting = provider
        viewModel.conversationStore = store
        viewModel.reloadFromStore()
        return viewModel
    }

    private func makeTask(
        conversationID: KotlinUuid, userMessage: UIMessage, requiresForeground: Bool = false
    ) -> IOSWakeTask {
        IOSWakeTask(
            id: UUID().uuidString, requestID: "test-request", conversationID: conversationID.toHexDashString(),
            sourceRunID: "source-run", origin: IOSWakeOrigin(
                userMessageID: userMessage.id.toHexDashString(), userText: userMessage.toText()
            ),
            title: "检查外部助手回复", prompt: "读取已完成的研究，并整理报告。", createdAt: Date(),
            fireAt: Date(), event: nil, requiresForeground: requiresForeground
        )
    }

    private func waitForTerminal(_ viewModel: ChatViewModel, runID: String) async throws -> IOSDurableRunStore.Snapshot? {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let snapshot = try await viewModel.runStore.snapshot(runId: runID), snapshot.status.isTerminal {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try await viewModel.runStore.snapshot(runId: runID)
    }

    func testWakeUsesOriginalConversationAndExactRunWithoutChangingCurrentDraftOrBridge() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let originalID = try XCTUnwrap(store.currentConversation?.id)
        let originalRequest = UIMessage.companion.user(prompt: "请研究原任务，拿到回复后整理。")
        let saved = await store.save(messages: [originalRequest], to: originalID)
        XCTAssertTrue(saved)
        await store.newConversation()
        let visibleID = try XCTUnwrap(store.currentConversation?.id)
        let provider = Provider(hold: true)
        defer { provider.release() }
        let viewModel = makeViewModel(store: store, provider: provider)
        viewModel.inputText = "尚未发送的草稿"
        _ = viewModel.makeTextGenerationParams()
        let visibleBridge = viewModel.lastAssembledToolExposureBridge
        let runID = "scheduled-test-\(UUID().uuidString)"

        let result = await viewModel.startWakeTask(
            makeTask(conversationID: originalID, userMessage: originalRequest), runID: runID,
            externallyManagedBackgroundExecution: true,
            isClaimCurrent: { true }
        )
        XCTAssertEqual(result, .started)
        XCTAssertEqual(store.currentConversation?.id, visibleID)
        XCTAssertEqual(viewModel.inputText, "尚未发送的草稿")
        XCTAssertTrue(viewModel.lastAssembledToolExposureBridge === visibleBridge)
        XCTAssertFalse(BackgroundGenerationKeepAlive.shared.activeLeaseIds.contains(runID),
                       "The BGProcessing owner must not acquire a shorter UIKit/continued-processing lease")
        XCTAssertFalse(viewModel.host(runId: runID)?.handoffCurrentGenerationToBackground(
            conversationStore: store, honorKeepAliveLease: true
        ) ?? true, "A scene transition must preserve the external background owner")
        provider.release()
        let terminal = try await waitForTerminal(viewModel, runID: runID)
        XCTAssertEqual(terminal?.status, .completed)
        XCTAssertEqual(terminal?.conversationId, originalID.toHexDashString())
        XCTAssertNotNil(terminal?.finishedAt)
        let loadedOriginalMessages = await store.messages(for: originalID)
        let originalMessages = try XCTUnwrap(loadedOriginalMessages)
        XCTAssertTrue(originalMessages.contains { $0.toText().contains("scheduled work finished") })
        XCTAssertTrue(provider.request.0.contains { $0.id == originalRequest.id })
        XCTAssertEqual(provider.request.1?.customHeaders.first { $0.name == "x-opencode-session" }?.value,
                       originalID.toHexDashString())
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertFalse(viewModel.cancelWakeRun(runID: "a-different-run"))
    }

    func testClaimCancellationDuringSavePreventsStartAndRetryDoesNotDuplicateWakeMessage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let conversationID = try XCTUnwrap(store.currentConversation?.id)
        let originalRequest = UIMessage.companion.user(prompt: "稍后继续检查")
        let saved = await store.save(messages: [originalRequest], to: conversationID)
        XCTAssertTrue(saved)
        let provider = Provider()
        let viewModel = makeViewModel(store: store, provider: provider)
        let task = makeTask(conversationID: conversationID, userMessage: originalRequest)
        let reachedSave = expectation(description: "wake prompt reached durable save")
        var resumeSave: CheckedContinuation<Void, Never>?
        var claimCurrent = true
        store.beforePersistForTesting = { _ in
            reachedSave.fulfill()
            await withCheckedContinuation { resumeSave = $0 }
        }
        let preparing = Task {
            await viewModel.startWakeTask(task, runID: "cancelled-preparation", isClaimCurrent: { claimCurrent })
        }
        await fulfillment(of: [reachedSave], timeout: 2)
        claimCurrent = false
        store.beforePersistForTesting = nil
        resumeSave?.resume()
        let cancelled = await preparing.value
        guard case .deferred = cancelled else { return XCTFail("Cancelled claim must defer: \(cancelled)") }
        XCTAssertNil(viewModel.host(runId: "cancelled-preparation"))
        XCTAssertTrue(provider.request.0.isEmpty)

        let retryRunID = "wake-retry-\(UUID().uuidString)"
        let retry = await viewModel.startWakeTask(task, runID: retryRunID, isClaimCurrent: { true })
        XCTAssertEqual(retry, .started)
        let terminal = try await waitForTerminal(viewModel, runID: retryRunID)
        XCTAssertEqual(terminal?.status, .completed)
        let loadedMessages = await store.messages(for: conversationID)
        let messages = try XCTUnwrap(loadedMessages)
        let wakeMessage = try ChatViewModel.scheduledWakeMessage(task)
        XCTAssertEqual(messages.filter { $0.id == wakeMessage.id }.count, 1)
    }

    func testDisabledGenerationAndExistingUserWorkDeferBeforeAddingPrompt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let conversationID = try XCTUnwrap(store.currentConversation?.id)
        let userMessage = UIMessage.companion.user(prompt: "已有任务")
        let saved = await store.save(messages: [userMessage], to: conversationID)
        XCTAssertTrue(saved)
        let task = makeTask(conversationID: conversationID, userMessage: userMessage)
        let disabled = makeViewModel(store: store, provider: Provider(), autoGenerateResponses: false)
        let disabledResult = await disabled.startWakeTask(task, runID: "disabled", isClaimCurrent: { true })
        guard case .deferred = disabledResult else { return XCTFail("Auto generation disabled must defer") }

        let viewModel = makeViewModel(store: store, provider: Provider())
        viewModel.currentRun.state.isLoading = true
        let busyResult = await viewModel.startWakeTask(task, runID: "busy", isClaimCurrent: { true })
        guard case .deferred = busyResult else { return XCTFail("Existing user work must defer") }
        let messages = await store.messages(for: conversationID)
        XCTAssertEqual(messages?.map { $0.id }, [userMessage.id])
        XCTAssertNil(viewModel.host(runId: "busy"))
    }

    func testSystemExpirationInterruptsOnlyTheClaimedRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let conversationID = try XCTUnwrap(store.currentConversation?.id)
        let userMessage = UIMessage.companion.user(prompt: "后台完成检查")
        let saved = await store.save(messages: [userMessage], to: conversationID)
        XCTAssertTrue(saved)
        let provider = Provider(hold: true)
        defer { provider.release() }
        let viewModel = makeViewModel(store: store, provider: provider)
        let runID = "expiring-wake-\(UUID().uuidString)"
        let result = await viewModel.startWakeTask(
            makeTask(conversationID: conversationID, userMessage: userMessage), runID: runID,
            externallyManagedBackgroundExecution: true, isClaimCurrent: { true }
        )
        XCTAssertEqual(result, .started)
        let deadline = Date().addingTimeInterval(5)
        while provider.request.0.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(provider.request.0.isEmpty)
        XCTAssertFalse(viewModel.cancelWakeRun(runID: "another-run", interrupted: true))
        XCTAssertNotNil(viewModel.host(runId: runID))
        XCTAssertTrue(viewModel.cancelWakeRun(runID: runID, interrupted: true))
        let terminal = try await waitForTerminal(viewModel, runID: runID)
        XCTAssertEqual(terminal?.status, .interrupted)
        XCTAssertNotNil(terminal?.finishedAt)
    }

    func testAdoptedBackgroundOwnerReleasesOldLeaseAndIgnoresItsLateExpiration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let conversationID = try XCTUnwrap(store.currentConversation?.id)
        let userMessage = UIMessage.companion.user(prompt: "稍后在后台继续处理")
        let saved = await store.save(messages: [userMessage], to: conversationID)
        XCTAssertTrue(saved)
        let provider = Provider(hold: true)
        defer { provider.release() }
        let viewModel = makeViewModel(store: store, provider: provider)
        let runID = "adopt-existing-wake-\(UUID().uuidString)"
        let started = await viewModel.startWakeTask(
            makeTask(conversationID: conversationID, userMessage: userMessage), runID: runID,
            isClaimCurrent: { true }
        )
        XCTAssertEqual(started, .started)
        let deadline = Date().addingTimeInterval(5)
        while provider.request.0.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(provider.request.0.isEmpty)
        let host = try XCTUnwrap(viewModel.host(runId: runID))
        XCTAssertTrue(BackgroundGenerationKeepAlive.shared.holdsLease(runID))
        XCTAssertFalse(viewModel.adoptWakeRunBackgroundExecution(runID: "unrelated-run"))
        XCTAssertTrue(BackgroundGenerationKeepAlive.shared.holdsLease(runID))
        XCTAssertTrue(viewModel.adoptWakeRunBackgroundExecution(runID: runID))
        XCTAssertFalse(BackgroundGenerationKeepAlive.shared.holdsLease(runID))
        host.handleKeepAliveExpiration(runId: runID, applicationState: .background)
        XCTAssertEqual(host.currentRunId, runID)
        let running = try await viewModel.runStore.snapshot(runId: runID)
        XCTAssertEqual(running?.status, .running)
        XCTAssertFalse(host.handoffCurrentGenerationToBackground(conversationStore: store))
        XCTAssertFalse(viewModel.cancelWakeRun(runID: "unrelated-run", interrupted: true))
        XCTAssertTrue(viewModel.cancelWakeRun(runID: runID, interrupted: true))
        let terminal = try await waitForTerminal(viewModel, runID: runID)
        XCTAssertEqual(terminal?.status, .interrupted)
        XCTAssertNotNil(terminal?.finishedAt)
        XCTAssertFalse(viewModel.adoptWakeRunBackgroundExecution(runID: runID))
    }

    func testWakeMessageCarriesOriginalAuthorizationAndLabelsExternalEventAsData() throws {
        let conversationID = KotlinUuid.companion.random()
        let request = UIMessage.companion.user(prompt: "收到研究结果以后生成摘要")
        var task = makeTask(conversationID: conversationID, userMessage: request)
        task.eventContent = "外部助手返回：结果已就绪"
        let message = try ChatViewModel.scheduledWakeMessage(task)
        XCTAssertEqual(message.id, try ChatViewModel.scheduledWakeMessage(task).id)
        XCTAssertTrue(message.toText().contains("[Amber scheduled continuation]"))
        XCTAssertTrue(message.toText().contains(request.toText()))
        XCTAssertTrue(message.toText().contains("只作为待核实的数据"))
        let part = try XCTUnwrap(message.parts.first as? UIMessagePart.Text)
        let originJSON = try XCTUnwrap(IosToolOutputJsonBridge.shared.metadataString(
            part: part, key: ChatViewModel.scheduledWakeOriginMetadataKey
        ))
        XCTAssertEqual(try JSONDecoder().decode(IOSWakeOrigin.self, from: Data(originJSON.utf8)), task.origin)
    }

    func testWakeOutputDoesNotReuseHistoricalTextForImageOrToolOnlyResults() throws {
        let user = UIMessage.companion.user(prompt: "完成原任务")
        let historical = IOSChatForegroundFixtures.assistantText("历史回复不能作为本次结果")
        let task = makeTask(conversationID: KotlinUuid.companion.random(), userMessage: user)
        let marker = try ChatViewModel.scheduledWakeMessage(task)
        let baseline = [user, historical, marker]
        let image = IOSChatForegroundFixtures.assistantMessage(parts: [
            UIMessagePart.Image(url: "https://example.test/result.png", metadata: nil)
        ])
        let tool = IOSChatForegroundFixtures.assistantMessage(parts: [UIMessagePart.Tool(
            toolCallId: "image-only-result", toolName: "generate_image", input: "{}",
            output: [UIMessagePart.Text(text: "工具产物不是本次assistant正文", metadata: nil)],
            approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
        )])
        let final = baseline + [image, tool]
        XCTAssertNil(IOSWakeTaskOutput.text(in: final, baseline: baseline))
        XCTAssertNil(IOSWakeTaskOutput.text(for: task, in: final))
        XCTAssertNil(IOSWakeTaskOutput.text(for: task, in: [user, historical]))
    }

    func testWakeOutputIsBoundToTaskMarkerAndNextUserAndPreservesFullText() throws {
        let user = UIMessage.companion.user(prompt: "等结果后完成报告")
        let historical = IOSChatForegroundFixtures.assistantText("上次已完成的报告")
        let task = makeTask(conversationID: KotlinUuid.companion.random(), userMessage: user)
        let marker = try ChatViewModel.scheduledWakeMessage(task)
        let fullText = "本次完整报告\n" + String(repeating: "未截断的研究结论。", count: 2_000)
        let first = IOSChatForegroundFixtures.assistantText("本次进度")
        let final = IOSChatForegroundFixtures.assistantText(fullText)
        let baseline = [user, historical, marker]
        let nextTurn = UIMessage.companion.user(prompt: "开始另一项独立任务")
        let otherAnswer = IOSChatForegroundFixtures.assistantText("其他任务的回复不能混入")
        let conversation = baseline + [first, final, nextTurn, otherAnswer]
        XCTAssertEqual(IOSWakeTaskOutput.messageID(taskID: task.id), marker.id)
        XCTAssertEqual(IOSWakeTaskOutput.text(in: baseline + [first, final], baseline: baseline),
                       "本次进度\n" + fullText)
        XCTAssertEqual(IOSWakeTaskOutput.text(for: task, in: conversation), "本次进度\n" + fullText)
    }

    func testExplicitRetryUsesItsOwnMarkerAfterAnIndependentUserTurn() throws {
        let user = UIMessage.companion.user(prompt: "收到结果后继续整理")
        var task = makeTask(conversationID: KotlinUuid.companion.random(), userMessage: user)
        let initialMarker = try ChatViewModel.scheduledWakeMessage(task)
        let failedAnswer = IOSChatForegroundFixtures.assistantText("之前失败尝试的部分内容")
        let independentUser = UIMessage.companion.user(prompt: "先处理另一件事")
        let otherAnswer = IOSChatForegroundFixtures.assistantText("独立任务的回复")
        task.attemptNumber = 1
        let retryMarker = try ChatViewModel.scheduledWakeMessage(task)
        let fullRetryAnswer = "重试后的完整结果\n" + String(repeating: "完整研究结论。", count: 2_000)
        let retryAnswer = IOSChatForegroundFixtures.assistantText(fullRetryAnswer)
        let conversation = [user, initialMarker, failedAnswer, independentUser, otherAnswer, retryMarker, retryAnswer]
        XCTAssertNotEqual(initialMarker.id, retryMarker.id)
        XCTAssertEqual(initialMarker.id, IOSWakeTaskOutput.messageID(taskID: task.id))
        XCTAssertEqual(retryMarker.id, IOSWakeTaskOutput.messageID(taskID: task.id, attemptNumber: 1))
        XCTAssertEqual(IOSWakeTaskOutput.text(for: task, in: conversation), fullRetryAnswer)
        XCTAssertEqual(retryMarker.id, try ChatViewModel.scheduledWakeMessage(task).id,
                       "Preparation retries within the same execution attempt must still deduplicate")
    }

    func testForegroundWakeClaimsFreshPhoneOwnerWithCurrentScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let conversationID = try XCTUnwrap(store.currentConversation?.id)
        let user = UIMessage.companion.user(prompt: "收到回复后操作手机收集结果")
        let saved = await store.save(messages: [user], to: conversationID)
        XCTAssertTrue(saved)
        let suite = "ChatScheduledWakePhone-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = IOSPhoneControlController(defaults: defaults)
        controller.enabled = true
        controller.selectedBundleIDs = ["app.example.current-target"]
        let provider = Provider(hold: true)
        defer { provider.release() }
        let viewModel = makeViewModel(store: store, provider: provider, phoneControl: controller)
        let runID = "fresh-phone-wake-\(UUID().uuidString)"
        let result = await viewModel.startWakeTask(
            makeTask(conversationID: conversationID, userMessage: user, requiresForeground: true),
            runID: runID, isClaimCurrent: { true }, isForeground: { true }
        )
        XCTAssertEqual(result, .started)
        XCTAssertEqual(controller.ownerRunID, runID)
        XCTAssertEqual(controller.phase, .authorized)
        XCTAssertTrue(controller.statusText(runID: runID).contains("scope=app.example.current-target"))
        XCTAssertFalse(controller.hasRequestedSession(runID: runID), "A fresh claim must not restore or launch an old runner")
        let executor = IOSPhoneControlToolExecutor(runID: runID, controller: controller, reportActivity: { _ in })
        let status = await executor.execute(name: "phone_status", arguments: "{}", isUserInitiated: false)
        guard case .filled(let text) = status else { return XCTFail("Fresh phone tools should be authorized: \(status)") }
        XCTAssertTrue(text.contains("scope=app.example.current-target"))
        XCTAssertTrue(viewModel.cancelWakeRun(runID: runID))
        _ = try await waitForTerminal(viewModel, runID: runID)
        await controller.stop(runID: runID)
        controller.enabled = false
        let disabledRunID = "phone-disabled-wake-\(UUID().uuidString)"
        let disabledResult = await viewModel.startWakeTask(
            makeTask(conversationID: conversationID, userMessage: user, requiresForeground: true),
            runID: disabledRunID, isClaimCurrent: { true }, isForeground: { true }
        )
        XCTAssertEqual(disabledResult, .started, "A foreground UI task must not require enabling phone control")
        XCTAssertFalse(controller.enabled)
        XCTAssertNil(controller.ownerRunID)
        let names = viewModel.runRegistry.run(for: conversationID)?.state.toolExposureBridge?
            .fullToolDeclarations().map(\.name) ?? []
        XCTAssertTrue(IOSPhoneControlToolCatalog.toolNames.isDisjoint(with: names))
        XCTAssertTrue(viewModel.cancelWakeRun(runID: disabledRunID))
        _ = try await waitForTerminal(viewModel, runID: disabledRunID)
    }

    func testForegroundPhoneWakeDefersWhileBackgroundOrOccupiedAndRechecksAfterSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let conversationID = try XCTUnwrap(store.currentConversation?.id)
        let user = UIMessage.companion.user(prompt: "稍后操作手机继续任务")
        let saved = await store.save(messages: [user], to: conversationID)
        XCTAssertTrue(saved)
        let suite = "ChatScheduledWakePhoneGates-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = IOSPhoneControlController(defaults: defaults)
        controller.enabled = true
        controller.selectedBundleIDs = ["app.example.allowed"]
        let provider = Provider(hold: true)
        defer { provider.release() }
        let viewModel = makeViewModel(store: store, provider: provider, phoneControl: controller)
        let task = makeTask(conversationID: conversationID, userMessage: user, requiresForeground: true)
        let background = await viewModel.startWakeTask(task, runID: "background-phone",
            isClaimCurrent: { true }, isForeground: { false })
        guard case .deferred = background else { return XCTFail("Phone work must wait for foreground") }
        XCTAssertNil(controller.ownerRunID)
        XCTAssertTrue(controller.claim(runID: "another-owner", onStop: {}))
        let occupied = await viewModel.startWakeTask(task, runID: "occupied-phone",
            isClaimCurrent: { true }, isForeground: { true })
        guard case .deferred = occupied else { return XCTFail("Phone work must wait for its occupied controller") }
        XCTAssertEqual(controller.ownerRunID, "another-owner")
        await controller.stop(runID: "another-owner")
        var foreground = true
        store.beforePersistForTesting = { _ in foreground = false }
        let leftForeground = await viewModel.startWakeTask(task, runID: "left-foreground-phone",
            isClaimCurrent: { true }, isForeground: { foreground })
        guard case .deferred = leftForeground else { return XCTFail("Foreground must be rechecked after persistence") }
        XCTAssertNil(controller.ownerRunID)
        XCTAssertTrue(provider.request.0.isEmpty)
        XCTAssertNil(viewModel.host(runId: "left-foreground-phone"))
        store.beforePersistForTesting = nil
    }

    func testForegroundToolScheduleEventResumeAndDurableTerminalCompleteTheSameScheduler() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversationStore = IOSConversationStore(baseDirectory: directory.appendingPathComponent("conversations"))
        await conversationStore.bootstrap()
        let originalID = try XCTUnwrap(conversationStore.currentConversation?.id)
        let originalUser = UIMessage.companion.user(prompt: "等外部助手研究完成，拿到结果后整理到这里。")
        let saved = await conversationStore.save(messages: [originalUser], to: originalID)
        XCTAssertTrue(saved)
        let taskURL = directory.appendingPathComponent("wake/tasks.json")
        let taskStore = IOSWakeTaskStore(fileURL: taskURL)
        let scheduler = IOSWakeScheduler(store: taskStore, isForeground: { true })
        let provider = SchedulingProvider()
        let viewModel = makeViewModel(store: conversationStore, provider: provider, wakeScheduler: scheduler)
        scheduler.attach(chatViewModel: viewModel)
        viewModel.generateResponse(inputDigest: "initial-scheduling-turn", conversationId: originalID)
        let initialRunID = try XCTUnwrap(viewModel.host(for: originalID)?.currentRunId)
        let firstTerminal = try await waitForTerminal(viewModel, runID: initialRunID)
        XCTAssertEqual(firstTerminal?.status, .completed)
        let planned = try XCTUnwrap(taskStore.tasks.first)
        XCTAssertEqual(taskStore.tasks.count, 1)
        XCTAssertEqual(planned.status, .scheduled)
        XCTAssertEqual(planned.sourceRunID, initialRunID)
        XCTAssertEqual(planned.origin, IOSWakeOrigin(
            userMessageID: originalUser.id.toHexDashString(), userText: originalUser.toText()
        ))

        await conversationStore.newConversation()
        viewModel.reloadFromStore()
        let visibleID = try XCTUnwrap(conversationStore.currentConversation?.id)
        viewModel.inputText = "当前会话尚未发送的草稿"
        let report = await scheduler.runDueTasks(event: "e2e-research-ready", content: "外部助手资料：已完成研究。")
        XCTAssertEqual(report.startedCount, 1, report.summary)
        let resumedRunID = try XCTUnwrap(report.runIDs.first)
        let deadline = Date().addingTimeInterval(8)
        while taskStore.task(id: planned.id)?.status == .running, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let completed = try XCTUnwrap(taskStore.task(id: planned.id))
        XCTAssertEqual(completed.status, .completed, completed.lastMessage ?? "")
        XCTAssertEqual(completed.executionRunID, resumedRunID)
        XCTAssertNotNil(completed.finishedAt)
        XCTAssertEqual(completed.resultText, "原任务的研究结果已整理完成")
        let durableTerminal = try await viewModel.runStore.snapshot(runId: resumedRunID)
        XCTAssertEqual(durableTerminal?.status, .completed)
        XCTAssertEqual(durableTerminal?.conversationId, originalID.toHexDashString())
        XCTAssertNotNil(durableTerminal?.finishedAt)
        let restoredStore = IOSWakeTaskStore(fileURL: taskURL)
        XCTAssertEqual(restoredStore.task(id: planned.id)?.status, .completed)
        XCTAssertEqual(conversationStore.currentConversation?.id, visibleID)
        XCTAssertEqual(viewModel.inputText, "当前会话尚未发送的草稿")
        XCTAssertTrue(viewModel.messages.isEmpty)
        let originalMessages = await conversationStore.messages(for: originalID)
        XCTAssertTrue(originalMessages?.contains { $0.toText().contains("原任务的研究结果已整理完成") } == true)
        XCTAssertEqual(provider.resumedRequests.count, 1)
        XCTAssertTrue(provider.resumedRequests.first?.contains { $0.id == originalUser.id } == true)
        XCTAssertTrue(provider.resumedRequests.first?.contains { $0.toText().contains("外部助手资料：已完成研究。") } == true)
    }
}
