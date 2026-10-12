import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSIntelligentUISubmissionTests: XCTestCase {
    private final class TextProvider: IOSAgentTextProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var userInputs: [String] = []
        var inputs: [String] { lock.withLock { userInputs } }
        func generateText(providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams) async throws -> MessageChunk {
            lock.withLock { userInputs.append(messages.last(where: { $0.role == .user })?.toText() ?? "") }
            return IOSChatForegroundFixtures.chunk(with: IOSChatForegroundFixtures.assistantText("已根据选择继续。"))
        }
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let store: IOSConversationStore
        let viewModel: ChatViewModel
        let definition: IOSIntelligentUICardDefinition
        let source: IOSIntelligentUISource
        let provider: TextProvider
        func submission() throws -> IOSIntelligentUISubmission {
            try IOSIntelligentUISubmission(source: source, definition: definition,
                draft: store.intelligentUIStateStore.draft(for: source, definition: definition))
        }
    }

    private func makeFixture(autoGenerate: Bool = false, completed: Bool = true, actionsEnabled: Bool = true,
                             definitionJSON: String = IOSIntelligentUIProtocol.exampleJSON) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IntelligentUISubmission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let defaults = UserDefaults(suiteName: "IntelligentUISubmission-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let configured = IosSettingsMutations.shared.buildOpenAIProvider(name: "Task UI test", apiKey: "sk-test",
            baseUrl: "https://example.test/v1", modelName: "Task UI", modelId: "task-ui-test")
        let added = settings.addProvider(configured)
        settings.setCurrentChatModelId(added.models.first { $0.type == .chat }!.id.description())
        if !actionsEnabled {
            let encoded = IosSettingsJsonBridge.shared.encode(settings: settings.snapshot)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
            var runtime = object["agentRuntime"] as? [String: Any] ?? [:]
            var ui = runtime["generativeUi"] as? [String: Any] ?? [:]
            ui["enableActions"] = false
            runtime["generativeUi"] = ui
            object["agentRuntime"] = runtime
            let disabled = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            settings.restoreSnapshot(try IosSettingsJsonBridge.shared.decode(json: disabled))
            XCTAssertFalse(settings.snapshot.agentRuntime.generativeUi.enableActions)
        }
        let database = IosDatabaseFactory.shared.createDatabase(atFilePath: directory.appendingPathComponent("runs.db").path)
        let provider = TextProvider()
        let viewModel = ChatViewModel(settingsStore: SettingsStore(userDefaults: defaults), sharedSettings: settings,
            autoGenerateResponses: autoGenerate, auxiliaryTextProvider: provider, agentRuntimeDao: database.agentRuntimeDao())
        viewModel.conversationStore = store
        viewModel.kernelTextProviderOverrideForTesting = provider
        let definition = try IOSIntelligentUIProtocol.decode(definitionJSON)
        let raw = IOSChatForegroundFixtures.assistantText("```task-ui\n\(definitionJSON)\n```")
        let messages = completed ? IOSIntelligentUITerminal.markCompleted([raw], baseline: [], runID: "source-run") : [raw]
        let conversationID = try XCTUnwrap(store.currentConversation?.id)
        let saved = await store.save(messages: messages, to: conversationID)
        XCTAssertTrue(saved)
        viewModel.reloadFromStore()
        let source = IOSIntelligentUISource(conversationID: conversationID.toHexDashString(),
            messageID: raw.id.toHexDashString(), textPartIndex: 0, cardID: definition.cardID)
        try store.intelligentUIStateStore.update(source: source, definition: definition,
            selectedOptionID: definition.kind == "decision" ? "native" : nil,
            values: definition.kind == "decision" ? ["constraints": "保留现有展示能力"] : [:])
        return Fixture(directory: directory, store: store, viewModel: viewModel, definition: definition, source: source, provider: provider)
    }

    func testTerminalMetadataPreservesExistingJSONThroughDiskReload() async throws {
        let f = try await makeFixture(completed: false)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let original = try XCTUnwrap(f.viewModel.messages.first)
        let sourceJSON = try JSONSerialization.data(withJSONObject: [[
            "type": "text", "text": original.toText(),
            "metadata": ["existing": ["records": [7, 9], "enabled": true]]
        ]])
        let sourceParts = try IosToolOutputJsonBridge.shared.decode(json: String(decoding: sourceJSON, as: UTF8.self))
        let source = UIMessage(id: original.id, role: original.role,
            parts: sourceParts,
            annotations: original.annotations, createdAt: original.createdAt, finishedAt: original.finishedAt,
            modelId: original.modelId, usage: original.usage, translation: original.translation)
        let pending = IOSIntelligentUITerminal.markSourcesPending([source], baseline: [], runID: "round-trip-run")
        let conversationID = try XCTUnwrap(f.store.currentConversation?.id)
        let pendingSaved = await f.store.save(messages: pending, to: conversationID)
        XCTAssertTrue(pendingSaved)
        let pendingMessages = await f.store.messages(for: conversationID)
        let pendingFromDisk = try XCTUnwrap(pendingMessages)
        let completed = IOSIntelligentUITerminal.markCompleted(
            pendingFromDisk, baseline: pendingFromDisk, runID: "round-trip-run"
        )
        let completedSaved = await f.store.save(messages: completed, to: conversationID)
        XCTAssertTrue(completedSaved)

        let reopened = IOSConversationStore(baseDirectory: f.directory)
        await reopened.bootstrap()
        let restoredMessages = await reopened.messages(for: conversationID)
        let restored = try XCTUnwrap(restoredMessages)
        let text = try XCTUnwrap(restored.first?.parts.first as? UIMessagePart.Text)
        let metadataJSON = try XCTUnwrap(IosToolOutputJsonBridge.shared.metadataJson(part: text))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(metadataJSON.utf8)) as? [String: Any])
        let inherited = try XCTUnwrap(metadata["existing"] as? [String: Any])
        XCTAssertEqual(inherited["records"] as? [Int], [7, 9])
        XCTAssertEqual(inherited["enabled"] as? Bool, true)
        XCTAssertEqual(IosToolOutputJsonBridge.shared.metadataString(part: text, key: IOSIntelligentUITerminal.completedKey), "completed")
        XCTAssertEqual(IosToolOutputJsonBridge.shared.metadataString(part: text, key: IOSIntelligentUITerminal.runIDKey), "round-trip-run")
    }

    func testIndependentSubmissionPersistsSnapshotAndPreservesComposerAttachments() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let image = ChatViewModel.PendingChatImage(dataUrl: "data:image/png;base64,QUJD", previewData: Data("preview".utf8))
        let file = SelectedDocumentReadResult(fileName: "notes.md", fileType: "text/markdown", totalBytes: 12,
            bytesRead: 12, characterCount: 5, preview: "private composer file", isTruncated: false, note: nil)
        f.viewModel.inputText = "未发送的草稿"
        f.viewModel.pendingImages = [image]
        f.viewModel.pendingSelectedFilePreview = file
        let submission = try f.submission()
        let result = await f.viewModel.submitIntelligentUI(submission)
        XCTAssertEqual(result, .saved)
        XCTAssertEqual(f.viewModel.inputText, "未发送的草稿")
        XCTAssertEqual(f.viewModel.pendingImages.first?.id, image.id)
        XCTAssertEqual(f.viewModel.pendingSelectedFilePreview, file)
        let conversationID = try XCTUnwrap(f.store.currentConversation?.id)
        let stored = await f.store.messages(for: conversationID)
        let user = try XCTUnwrap(stored?.last)
        XCTAssertEqual(user.parts.count, 1)
        XCTAssertEqual(user.toText(), submission.prompt())
        XCTAssertFalse(user.toText().contains("private composer file"))
        let text = try XCTUnwrap(user.parts.first as? UIMessagePart.Text)
        let metadata = try XCTUnwrap(IosToolOutputJsonBridge.shared.metadataString(part: text, key: IOSIntelligentUISubmission.metadataKey))
        let decoded = try JSONDecoder().decode(IOSIntelligentUISubmission.self, from: Data(metadata.utf8))
        XCTAssertEqual(decoded, submission)
        XCTAssertEqual(f.viewModel.intelligentUIHost?.receipts[f.source], submission)
    }

    func testDuplicateRevisionIsRejectedButEditedDraftCanSubmitAgain() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let first = await f.viewModel.submitIntelligentUI(try f.submission())
        XCTAssertEqual(first, .saved)
        let duplicate = await f.viewModel.submitIntelligentUI(try f.submission())
        guard case .failure = duplicate else { return XCTFail("duplicate revision was accepted") }
        XCTAssertEqual(f.viewModel.messages.count, 2)
        try f.store.intelligentUIStateStore.update(source: f.source, definition: f.definition,
            selectedOptionID: "web", values: [:])
        let edited = await f.viewModel.submitIntelligentUI(try f.submission())
        XCTAssertEqual(edited, .saved)
        XCTAssertEqual(f.viewModel.messages.count, 3)
    }

    func testChangedDraftAndRemovedBranchSourceRejectBeforeMessageInsertion() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let stale = try f.submission()
        try f.store.intelligentUIStateStore.update(source: f.source, definition: f.definition,
            selectedOptionID: "web", values: [:])
        let changed = await f.viewModel.submitIntelligentUI(stale)
        guard case .failure = changed else { return XCTFail("stale draft was accepted") }
        XCTAssertEqual(f.viewModel.messages.count, 1)
        let current = try f.submission()
        f.viewModel.messages = [IOSChatForegroundFixtures.assistantText("另一个分支")]
        let removed = await f.viewModel.submitIntelligentUI(current)
        guard case .failure = removed else { return XCTFail("removed source was accepted") }
        XCTAssertEqual(f.viewModel.messages.count, 1)
    }

    func testIncompleteSourceAndBusyOrApprovalGateRejectWithoutSteer() async throws {
        let incomplete = try await makeFixture(completed: false)
        defer { try? FileManager.default.removeItem(at: incomplete.directory) }
        let incompleteResult = await incomplete.viewModel.submitIntelligentUI(try incomplete.submission())
        guard case .failure = incompleteResult else { return XCTFail("incomplete source was accepted") }
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.viewModel.generationActiveOverrideForTesting = { _ in true }
        let busy = await f.viewModel.submitIntelligentUI(try f.submission())
        guard case .failure = busy else { return XCTFail("busy submission was accepted") }
        f.viewModel.generationActiveOverrideForTesting = nil
        f.viewModel.pendingAskUser = ChatAskUserRequest(id: "ask", question: "先回答", options: [])
        let approval = await f.viewModel.submitIntelligentUI(try f.submission())
        guard case .failure = approval else { return XCTFail("pending user gate was bypassed") }
        XCTAssertEqual(f.viewModel.messages.count, 1)
        XCTAssertTrue(f.viewModel.steerQueue.isEmpty)
    }

    func testReceiptReloadUsesDurableMessageAndHostIdentityIsStable() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let host = try XCTUnwrap(f.viewModel.intelligentUIHost)
        let submission = try f.submission()
        let result = await f.viewModel.submitIntelligentUI(submission)
        XCTAssertEqual(result, .saved)
        f.viewModel.reloadFromStore()
        XCTAssertTrue(host === f.viewModel.intelligentUIHost)
        XCTAssertEqual(host.receipts[f.source], submission)
    }

    func testSourceConversationIsCapturedWhilePersistenceWaits() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let originalID = try XCTUnwrap(f.store.currentConversation?.id)
        let reached = expectation(description: "submission save suspended")
        var resume: CheckedContinuation<Void, Never>?
        f.store.beforePersistForTesting = { conversation in
            guard conversation.id == originalID else { return }
            reached.fulfill()
            await withCheckedContinuation { resume = $0 }
        }
        let submission = try f.submission()
        let task = Task { await f.viewModel.submitIntelligentUI(submission) }
        await fulfillment(of: [reached], timeout: 5)
        XCTAssertEqual(f.viewModel.composerSendBlockReason(for: "draft"), .generationActive)
        XCTAssertTrue(f.viewModel.isIntelligentUISubmissionInFlight)
        f.viewModel.deleteMessage(atMessageIndex: 0)
        f.viewModel.regenerate(atMessageIndex: 0)
        f.viewModel.selectVariant(messageIndex: 0, variantIndex: 0)
        f.viewModel.editMessage(atMessageIndex: 0, newText: "changed")
        XCTAssertNotNil(f.viewModel.configurationError)
        XCTAssertEqual(f.viewModel.messages.count, 2)
        XCTAssertTrue(f.provider.inputs.isEmpty)
        let created = await f.store.newConversation()
        XCTAssertTrue(created)
        let newID = try XCTUnwrap(f.store.currentConversation?.id)
        f.viewModel.reloadFromStore(reason: .conversationSwitch)
        f.viewModel.inputText = "新会话草稿"
        f.store.beforePersistForTesting = nil
        resume?.resume()
        let result = await task.value
        XCTAssertEqual(result, .saved)
        XCTAssertEqual(f.viewModel.currentConversationId, newID)
        XCTAssertEqual(f.viewModel.inputText, "新会话草稿")
        XCTAssertTrue(f.viewModel.messages.isEmpty)
        let originalMessages = await f.store.messages(for: originalID)
        XCTAssertEqual(originalMessages?.last?.toText(), submission.prompt())
        XCTAssertTrue(f.provider.inputs.isEmpty)
    }

    func testProviderStartsAfterDurableSubmissionAndReceivesSemanticSnapshot() async throws {
        let f = try await makeFixture(autoGenerate: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.store.beforePersistForTesting = { _ in XCTAssertTrue(f.provider.inputs.isEmpty) }
        let submission = try f.submission()
        let result = await f.viewModel.submitIntelligentUI(submission)
        f.store.beforePersistForTesting = nil
        XCTAssertEqual(result, .started)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, f.provider.inputs.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(f.provider.inputs.first, submission.prompt())
        while Date() < deadline, f.viewModel.isGenerationActive { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(f.viewModel.isGenerationActive)
    }

    func testStudyResultUsesDurableProductionSubmissionAndKeepsComposer() async throws {
        let f = try await makeFixture(autoGenerate: true, definitionJSON: IOSIntelligentUIProtocol.studyExampleJSON)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let study = try XCTUnwrap(f.definition.study)
        var session = IOSIntelligentUIStudySession()
        try session.setMode(.quiz, definition: study)
        try session.answer(optionID: "di", definition: study)
        try f.store.intelligentUIStateStore.update(source: f.source, definition: f.definition,
            selectedOptionID: nil, values: [IOSIntelligentUIStudySession.storageKey: session.encodedValue()])
        f.viewModel.inputText = "保留我的独立草稿"
        f.store.beforePersistForTesting = { _ in XCTAssertTrue(f.provider.inputs.isEmpty) }
        let submission = try f.submission()
        let result = await f.viewModel.submitIntelligentUI(submission)
        XCTAssertEqual(result, .started)
        f.store.beforePersistForTesting = nil
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, f.provider.inputs.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        while Date() < deadline, f.viewModel.isGenerationActive { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(f.viewModel.isGenerationActive)
        XCTAssertEqual(f.viewModel.inputText, "保留我的独立草稿")
        XCTAssertTrue(f.provider.inputs.contains(submission.prompt()))
        let conversationID = try XCTUnwrap(f.store.currentConversation?.id)
        let diskMessages = await f.store.messages(for: conversationID)
        let stored = try XCTUnwrap(diskMessages)
        let user = try XCTUnwrap(stored.first { $0.role == .user })
        let text = try XCTUnwrap(user.parts.first as? UIMessagePart.Text)
        let raw = try XCTUnwrap(IosToolOutputJsonBridge.shared.metadataString(part: text, key: IOSIntelligentUISubmission.metadataKey))
        let frozen = try JSONDecoder().decode(IOSIntelligentUISubmission.self, from: Data(raw.utf8))
        XCTAssertEqual(frozen, submission)
        XCTAssertEqual(frozen.studySummary?.answeredCount, 1)
        XCTAssertEqual(frozen.studySummary?.correctCount, 0)
        try session.reset(definition: study)
        try f.store.intelligentUIStateStore.update(source: f.source, definition: f.definition,
            selectedOptionID: nil, values: [IOSIntelligentUIStudySession.storageKey: session.encodedValue()])
        XCTAssertFalse(submission.matches(f.store.intelligentUIStateStore.draft(for: f.source, definition: f.definition)))
        XCTAssertEqual(frozen.studySummary?.answeredCount, 1, "重练不会改写已保存的练习快照。")
    }
    func testExplicitComposerContinuationIncludesSnapshotAndCanReuseSubmittedSelection() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let first = await f.viewModel.submitIntelligentUI(try f.submission())
        XCTAssertEqual(first, .saved)
        f.viewModel.inputText = "按这个继续"
        XCTAssertTrue(f.viewModel.sendMessage())
        XCTAssertEqual(f.viewModel.inputText, "")
        XCTAssertEqual(f.viewModel.messages.count, 3)
        let user = try XCTUnwrap(f.viewModel.messages.last)
        XCTAssertTrue(user.toText().contains("所选方案：原生任务卡"))
        XCTAssertTrue(user.toText().contains("补充约束：保留现有展示能力"))
        XCTAssertTrue(user.toText().contains("请求：按这个继续"))
        let text = try XCTUnwrap(user.parts.first as? UIMessagePart.Text)
        XCTAssertNotNil(IosToolOutputJsonBridge.shared.metadataString(part: text, key: IOSIntelligentUISubmission.metadataKey))
        await waitForOrdinarySave(f, messageID: user.id.toHexDashString())
    }

    func testUnrelatedComposerTextDoesNotInjectActiveCard() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.viewModel.inputText = "画一个 Three.js 模型"
        XCTAssertTrue(f.viewModel.sendMessage())
        let user = try XCTUnwrap(f.viewModel.messages.last)
        XCTAssertEqual(user.toText(), "画一个 Three.js 模型")
        let text = try XCTUnwrap(user.parts.first as? UIMessagePart.Text)
        XCTAssertNil(IosToolOutputJsonBridge.shared.metadataString(part: text, key: IOSIntelligentUISubmission.metadataKey))
        await waitForOrdinarySave(f, messageID: user.id.toHexDashString())
    }

    func testExplicitContinuationRejectsHiddenSourceAndPreservesComposerDraft() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.viewModel.messages = [IOSChatForegroundFixtures.assistantText("另一个分支")]
        f.viewModel.inputText = "按当前选择继续"
        XCTAssertFalse(f.viewModel.sendMessage())
        XCTAssertEqual(f.viewModel.inputText, "按当前选择继续")
        XCTAssertNotNil(f.viewModel.configurationError)
        XCTAssertEqual(f.viewModel.messages.count, 1)
    }

    func testDisabledActionsRejectIndependentAndExplicitCardContinuation() async throws {
        let f = try await makeFixture(actionsEnabled: false)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let result = await f.viewModel.submitIntelligentUI(try f.submission())
        guard case .failure = result else { return XCTFail("disabled actions accepted card submission") }
        f.viewModel.inputText = "基于选择继续"
        XCTAssertFalse(f.viewModel.sendMessage())
        XCTAssertNotNil(f.viewModel.configurationError)
        XCTAssertEqual(f.viewModel.inputText, "基于选择继续")
        XCTAssertEqual(f.viewModel.messages.count, 1)
    }

    func testDeletingSubmittedUserMessageClearsReceiptAndPreservesCardDraft() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let host = try XCTUnwrap(f.viewModel.intelligentUIHost)
        let draftBefore = f.store.intelligentUIStateStore.draft(for: f.source, definition: f.definition)
        let submission = try f.submission()
        let result = await f.viewModel.submitIntelligentUI(submission)
        XCTAssertEqual(result, .saved)
        XCTAssertEqual(host.receipts[f.source], submission)
        let user = try XCTUnwrap(f.viewModel.messages.last)
        XCTAssertEqual(user.role, .user)
        let submittedMessageID = user.id.toHexDashString()
        f.viewModel.deleteMessage(messageId: submittedMessageID)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, host.receipts[f.source] != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(host.receipts[f.source])
        let conversationID = try XCTUnwrap(f.store.currentConversation?.id)
        let stored = await f.store.messages(for: conversationID)
        XCTAssertFalse(try XCTUnwrap(stored).contains { $0.id.toHexDashString() == submittedMessageID })
        XCTAssertTrue(try XCTUnwrap(stored).contains { $0.id.toHexDashString() == f.source.messageID })
        let draftAfter = f.store.intelligentUIStateStore.draft(for: f.source, definition: f.definition)
        XCTAssertEqual(draftAfter.revision, draftBefore.revision)
        XCTAssertEqual(draftAfter, draftBefore)
    }

    private func waitForOrdinarySave(_ f: Fixture, messageID: String) async {
        guard let id = f.store.currentConversation?.id else { return }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let stored = await f.store.messages(for: id), stored.contains(where: { $0.id.toHexDashString() == messageID }) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("ordinary send did not persist")
    }

}
