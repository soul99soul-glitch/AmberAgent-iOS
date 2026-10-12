import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSBackgroundCompletionMergeTests: XCTestCase {
    func testTerminalUpdatesCheckpointedAssistantWithSameIDAndPersistsSuccessMetadata() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let user = UIMessage.companion.user(prompt: "比较方案")
        let checkpoint = UIMessage.companion.assistant(prompt: "草稿")
        try await saveFixtureMessages(in: store, id: id, messages: [user, checkpoint])
        let terminal = terminalMessage(replacing: checkpoint, text: "终态任务卡")

        let saved = await store.saveBackgroundCompletion(
            baseMessages: [user], completedMessages: [user, terminal], to: id
        )

        try requireSaved(saved, in: store)
        try requireMessages(in: store, count: 2)
        XCTAssertEqual(store.currentMessages[1].id, checkpoint.id)
        XCTAssertTrue(store.currentMessages[1].toText().contains("终态任务卡"))
        XCTAssertEqual(terminalRunID(in: store.currentMessages[1]), "checkpoint-run")
        let restarted = IOSConversationStore(baseDirectory: directory)
        await restarted.bootstrap()
        XCTAssertEqual(terminalRunID(in: try XCTUnwrap(restarted.currentMessages.last)), "checkpoint-run")
    }

    func testMergeUpdatesOnlyGeneratedAssistantAndPreservesNewRunAndChangedHistory() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let user = UIMessage.companion.user(prompt: "原始任务")
        let history = UIMessage.companion.assistant(prompt: "旧历史")
        let editedHistory = replacing(history, text: "用户修改的历史")
        let checkpoint = UIMessage.companion.assistant(prompt: "后台 checkpoint")
        let newUser = UIMessage.companion.user(prompt: "新轮任务")
        let newRunAssistant = UIMessage.companion.assistant(prompt: "新轮已产生的结果")
        let terminal = terminalMessage(replacing: checkpoint, text: "旧轮最终结果")
        let freshResult = UIMessage.companion.assistant(prompt: "旧轮补充结果")
        try await saveFixtureMessages(in: store, id: id, messages: [user, editedHistory, checkpoint, newUser, newRunAssistant])

        let saved = await store.saveBackgroundCompletion(
            baseMessages: [user, history],
            completedMessages: [user, history, terminal, freshResult], to: id
        )

        try requireSaved(saved, in: store)
        try requireMessages(in: store, count: 7)
        XCTAssertEqual(store.currentMessages[1].toText(), "用户修改的历史")
        XCTAssertEqual(terminalRunID(in: store.currentMessages[2]), "checkpoint-run")
        XCTAssertEqual(store.currentMessages[3], newUser)
        XCTAssertEqual(store.currentMessages[4], newRunAssistant)
        XCTAssertEqual(store.currentMessages.last, freshResult)
        XCTAssertEqual(store.currentMessages.filter { $0.id == checkpoint.id }.count, 1)
        XCTAssertEqual(store.currentMessages.filter { $0.toText().contains("后台生成已完成") }.count, 1)
    }

    func testDrainDeduplicationPreservesExistingEnvelopeWhileUpdatingAssistant() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let user = UIMessage.companion.user(prompt: "任务")
        let envelope = UIMessage.companion.user(prompt: "已持久化信封")
        let incomingEnvelope = replacing(envelope, text: "终态旧信封投影")
        let checkpoint = UIMessage.companion.assistant(prompt: "checkpoint")
        let terminal = terminalMessage(replacing: checkpoint, text: "成功")
        try await saveFixtureMessages(in: store, id: id, messages: [user, envelope, checkpoint])

        let saved = await store.saveBackgroundCompletion(
            baseMessages: [user], completedMessages: [user, incomingEnvelope, terminal], to: id
        )

        try requireSaved(saved, in: store)
        try requireMessages(in: store, count: 3)
        XCTAssertEqual(store.currentMessages[1], envelope)
        XCTAssertEqual(terminalRunID(in: store.currentMessages[2]), "checkpoint-run")
        XCTAssertFalse(store.currentMessages.contains { $0.toText().contains("后台生成已完成") })
    }

    func testCheckpointMergeRetriesWithLatestWriteBaselineAndKeepsConcurrentNewRunMessages() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let user = UIMessage.companion.user(prompt: "旧轮任务")
        let checkpoint = UIMessage.companion.assistant(prompt: "checkpoint")
        let terminal = terminalMessage(replacing: checkpoint, text: "旧轮终态")
        try await saveFixtureMessages(in: store, id: id, messages: [user, checkpoint])

        let reachedPersist = expectation(description: "checkpoint merge reached first persist")
        var permitWrite: CheckedContinuation<Void, Never>?
        var blocked = false
        store.beforePersistForTesting = { _ in
            guard !blocked else { return }
            blocked = true
            reachedPersist.fulfill()
            await withCheckedContinuation { permitWrite = $0 }
        }
        let completion = Task { @MainActor in
            await store.saveBackgroundCompletion(
                baseMessages: [user], completedMessages: [user, terminal], to: id
            )
        }
        await fulfillment(of: [reachedPersist], timeout: 2)
        store.beforePersistForTesting = nil
        let newUser = UIMessage.companion.user(prompt: "新轮用户输入")
        let newRunAssistant = UIMessage.companion.assistant(prompt: "新轮内容")
        try await saveFixtureMessages(in: store, id: id, messages: [user, checkpoint, newUser, newRunAssistant])
        permitWrite?.resume()
        let saved = await completion.value

        try requireSaved(saved, in: store)
        try requireMessages(in: store, count: 4)
        XCTAssertEqual(terminalRunID(in: store.currentMessages[1]), "checkpoint-run")
        XCTAssertEqual(store.currentMessages[2], newUser)
        XCTAssertEqual(store.currentMessages[3], newRunAssistant)
    }

    func testAdvancedBaselineFinalizesSameRunCardAndPreservesCurrentOtherPartsAndMetadata() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let user = UIMessage.companion.user(prompt: "本轮任务")
        let checkpoint = pendingCard(runID: "checkpoint-run")
        let checkpointPart = try XCTUnwrap(checkpoint.parts.first as? UIMessagePart.Text)
        var metadata = checkpointPart.metadata ?? [:]
        metadata["preserve_current_metadata"] = try IOSIntelligentUISubmission.jsonString("current value")
        let extraPart = UIMessagePart.Text(text: "用户侧额外文本 part", metadata: nil)
        let currentCard = copy(checkpoint, parts: [IosToolOutputJsonBridge.shared.textPart(text: checkpointPart.text, metadata: metadata), extraPart])
        let newerUser = UIMessage.companion.user(prompt: "并行增加的消息")
        try await saveFixtureMessages(in: store, id: id, messages: [user, currentCard, newerUser])
        let terminal = IOSIntelligentUITerminal.markCompleted(
            [user, checkpoint], baseline: [user, checkpoint], runID: "checkpoint-run"
        )

        let saved = await store.saveBackgroundCompletion(
            baseMessages: [user, checkpoint], completedMessages: terminal, to: id
        )

        try requireSaved(saved, in: store)
        try requireMessages(in: store, count: 3)
        let merged = store.currentMessages[1]
        let mergedPart = try XCTUnwrap(merged.parts.first as? UIMessagePart.Text)
        XCTAssertEqual(mergedPart.metadata?[IOSIntelligentUITerminal.completedKey]?.jsonPrimitiveOrNull?.content, "completed")
        XCTAssertEqual(mergedPart.metadata?["preserve_current_metadata"]?.jsonPrimitiveOrNull?.content, "current value")
        XCTAssertEqual(try XCTUnwrap(merged.parts.dropFirst().first), extraPart)
        XCTAssertEqual(merged.finishedAt, currentCard.finishedAt)
        XCTAssertEqual(store.currentMessages[2], newerUser)
        let restarted = IOSConversationStore(baseDirectory: directory)
        await restarted.bootstrap()
        try requireMessages(in: restarted, count: 3)
        let restored = try XCTUnwrap(restarted.currentMessages[1].parts.first as? UIMessagePart.Text)
        XCTAssertEqual(restored.metadata?[IOSIntelligentUITerminal.completedKey]?.jsonPrimitiveOrNull?.content, "completed")
    }

    func testAdvancedBaselineTerminalDoesNotOverwriteChangedCurrentTextOrDifferentRun() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let user = UIMessage.companion.user(prompt: "本轮任务")
        let checkpoint = pendingCard(runID: "checkpoint-run")
        let checkpointPart = try XCTUnwrap(checkpoint.parts.first as? UIMessagePart.Text)
        let terminal = IOSIntelligentUITerminal.markCompleted(
            [user, checkpoint], baseline: [user, checkpoint], runID: "checkpoint-run"
        )
        var differentRunMetadata = checkpointPart.metadata ?? [:]
        differentRunMetadata[IOSIntelligentUITerminal.runIDKey] = try IOSIntelligentUISubmission.jsonString("newer-run")
        let alteredCards = [
            copy(checkpoint, parts: [IosToolOutputJsonBridge.shared.textPart(text: checkpointPart.text + "\n已编辑正文", metadata: checkpointPart.metadata)]),
            copy(checkpoint, parts: [IosToolOutputJsonBridge.shared.textPart(text: checkpointPart.text, metadata: differentRunMetadata)])
        ]
        let newerUser = UIMessage.companion.user(prompt: "前台新消息")
        for altered in alteredCards {
            try await saveFixtureMessages(in: store, id: id, messages: [user, altered, newerUser])
            let saved = await store.saveBackgroundCompletion(
                baseMessages: [user, checkpoint], completedMessages: terminal, to: id
            )
            try requireSaved(saved, in: store)
            try requireMessages(in: store, count: 3)
            XCTAssertEqual(store.currentMessages[1], altered)
            XCTAssertEqual(store.currentMessages[2], newerUser)
            let currentPart = try XCTUnwrap(store.currentMessages[1].parts.first as? UIMessagePart.Text)
            XCTAssertNil(currentPart.metadata?[IOSIntelligentUITerminal.completedKey])
        }
    }

    func testAdvancedBaselineCompletionPreservesNestedMetadataAcrossDiskReload() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let user = UIMessage.companion.user(prompt: "嵌套来源任务")
        let card = UIMessage.companion.assistant(prompt: "任务卡")
        let cardText = "```task-ui\n" + IOSIntelligentUIProtocol.exampleJSON + "\n```"
        let originalMetadata: [String: Any] = [
            IOSIntelligentUITerminal.runIDKey: "nested-run",
            "source_context": [
                "labels": ["alpha", "beta"],
                "details": ["retry": 2, "enabled": true]
            ],
            "preserve_current_metadata": "original value"
        ]
        let payload = try JSONSerialization.data(withJSONObject: [[
            "type": "text", "text": cardText, "metadata": originalMetadata
        ]])
        let checkpoint = copy(card, parts: try IosToolOutputJsonBridge.shared.decode(
            json: String(decoding: payload, as: UTF8.self)
        ))
        let extraPart = UIMessagePart.Text(text: "保留额外正文", metadata: nil)
        let currentCard = copy(checkpoint, parts: checkpoint.parts + [extraPart])
        let newerUser = UIMessage.companion.user(prompt: "并行用户消息")
        try await saveFixtureMessages(in: store, id: id, messages: [user, currentCard, newerUser])
        let terminal = IOSIntelligentUITerminal.markCompleted(
            [user, checkpoint], baseline: [user, checkpoint], runID: "nested-run"
        )

        let saved = await store.saveBackgroundCompletion(
            baseMessages: [user, checkpoint], completedMessages: terminal, to: id
        )

        try requireSaved(saved, in: store)
        try requireMessages(in: store, count: 3)
        var expectedMetadata = originalMetadata
        expectedMetadata[IOSIntelligentUITerminal.completedKey] = "completed"
        let merged = store.currentMessages[1]
        XCTAssertEqual(try metadataObject(in: merged), expectedMetadata as NSDictionary)
        XCTAssertEqual(try XCTUnwrap(merged.parts.dropFirst().first), extraPart)
        XCTAssertEqual(store.currentMessages[2], newerUser)

        let restarted = IOSConversationStore(baseDirectory: directory)
        await restarted.bootstrap()
        try requireMessages(in: restarted, count: 3)
        XCTAssertEqual(try metadataObject(in: restarted.currentMessages[1]), expectedMetadata as NSDictionary)
    }

    func testAdvancedBaselineTerminalDoesNotReplaceSelectedNewVariant() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let user = UIMessage.companion.user(prompt: "本轮任务")
        let checkpoint = pendingCard(runID: "checkpoint-run")
        let newVariant = pendingCard(runID: "newer-run")
        let newerUser = UIMessage.companion.user(prompt: "新消息")
        let terminal = IOSIntelligentUITerminal.markCompleted(
            [user, checkpoint], baseline: [user, checkpoint], runID: "checkpoint-run"
        )
        try await saveFixtureMessages(in: store, id: id, messages: [user, newVariant, newerUser])

        let saved = await store.saveBackgroundCompletion(
            baseMessages: [user, checkpoint], completedMessages: terminal, to: id
        )

        try requireSaved(saved, in: store)
        XCTAssertEqual(store.currentMessages, [user, newVariant, newerUser])
        XCTAssertFalse(store.currentMessages.contains { $0.id == checkpoint.id })
    }

    private func pendingCard(runID: String) -> UIMessage {
        let card = UIMessage.companion.assistant(prompt: "```task-ui\n" + IOSIntelligentUIProtocol.exampleJSON + "\n```")
        return IOSIntelligentUITerminal.markSourcesPending([card], baseline: [], runID: runID)[0]
    }

    private func copy(_ message: UIMessage, parts: [UIMessagePart]) -> UIMessage {
        UIMessage(
            id: message.id, role: message.role, parts: parts, annotations: message.annotations,
            createdAt: message.createdAt, finishedAt: message.finishedAt, modelId: message.modelId,
            usage: message.usage, translation: message.translation
        )
    }

    private func terminalMessage(replacing checkpoint: UIMessage, text: String) -> UIMessage {
        let message = replacing(
            checkpoint, text: text + "\n```task-ui\n" + IOSIntelligentUIProtocol.exampleJSON + "\n```"
        )
        return IOSIntelligentUITerminal.markCompleted([message], baseline: [], runID: "checkpoint-run")[0]
    }

    private func replacing(_ message: UIMessage, text: String) -> UIMessage {
        UIMessage(
            id: message.id, role: message.role, parts: [UIMessagePart.Text(text: text, metadata: nil)],
            annotations: message.annotations, createdAt: message.createdAt,
            finishedAt: message.finishedAt, modelId: message.modelId, usage: message.usage,
            translation: message.translation
        )
    }

    private func terminalRunID(in message: UIMessage) -> String? {
        message.parts.compactMap { $0 as? UIMessagePart.Text }.first.flatMap {
            IosToolOutputJsonBridge.shared.metadataString(part: $0, key: IOSIntelligentUITerminal.runIDKey)
        }
    }

    private func metadataObject(in message: UIMessage) throws -> NSDictionary {
        let part = try XCTUnwrap(message.parts.first as? UIMessagePart.Text)
        let json = try XCTUnwrap(IosToolOutputJsonBridge.shared.metadataJson(part: part))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
    }

    private func saveFixtureMessages(in store: IOSConversationStore, id: KotlinUuid, messages: [UIMessage]) async throws {
        try requireSaved(await store.save(messages: messages, to: id), in: store)
        try requireMessages(in: store, count: messages.count)
    }

    private func requireSaved(_ saved: Bool, in store: IOSConversationStore) throws {
        _ = try XCTUnwrap(saved ? true : nil, "会话保存失败：\(store.lastIOError?.detail ?? "没有 storage error")")
    }

    private func requireMessages(in store: IOSConversationStore, count: Int) throws {
        let actual = store.currentMessages.count
        _ = try XCTUnwrap(actual == count ? true : nil, "会话消息数量预期 \(count)，实际 \(actual)。\(store.lastIOError?.detail ?? "")")
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSBackgroundCompletionMergeTests-\(UUID().uuidString)")
    }
}
