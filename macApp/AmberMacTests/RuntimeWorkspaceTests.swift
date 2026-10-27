import XCTest
@testable import AmberMac

@MainActor final class RuntimeWorkspaceTests: XCTestCase {
    private final class Provider: DesktopTextProvider {
        var runs: [DesktopGeneration] = []
        var requests: [[DesktopMessage]] = []
        var responseIDs: [UUID] = []
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            let run = DesktopGeneration()
            runs.append(run)
            requests.append(messages)
            responseIDs.append(responseID)
            return run
        }
    }

    private func setup(_ values: [DesktopConversation] = []) throws -> (DesktopWorkspace, Provider, DesktopMemoryConversationStorage) {
        let defaults = UserDefaults(suiteName: "amber.runtime.tests.\(UUID().uuidString)")!
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        var config = settings.selectedProvider!
        config.modelID = "test-model"
        try settings.saveProvider(config, apiKey: "test-key")
        let provider = Provider()
        let storage = DesktopMemoryConversationStorage(values)
        return (DesktopWorkspace(settings: settings, storage: storage, provider: provider, initialConversations: values), provider, storage)
    }

    func testStopDrainsAcceptedChunkAndIgnoresLaterCallbacks() async throws {
        let (workspace, provider, storage) = try setup()
        workspace.draft = "问题"
        workspace.send()
        provider.runs[0].yield(.snapshot(text: "已收到的最后一段", reasoning: "思考"))
        workspace.stop()
        provider.runs[0].yield(.snapshot(text: "过期内容", reasoning: ""))
        _ = await workspace.flush()
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.text, "已收到的最后一段")
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.state, .cancelled)
        XCTAssertEqual(storage.values.first?.messages.last?.text, "已收到的最后一段")
        XCTAssertFalse(workspace.isGenerating)
    }

    func testTerminalAlreadyQueuedWinsOverStop() async throws {
        let (workspace, provider, _) = try setup()
        workspace.draft = "问题"
        workspace.send()
        provider.runs[0].yield(.snapshot(text: "完整回复", reasoning: ""))
        provider.runs[0].yield(.complete)
        workspace.stop()
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.state, .complete)
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.text, "完整回复")
    }

    func testSwitchConversationKeepsStreamAndDraftWithOriginalOwner() async throws {
        let second = DesktopConversation(title: "第二个会话")
        let (workspace, provider, storage) = try setup([second])
        workspace.createConversation()
        let original = try XCTUnwrap(workspace.selectedID)
        workspace.draft = "第一个问题"
        workspace.send()
        XCTAssertEqual(workspace.generationConversationID, original)
        XCTAssertTrue(workspace.isSelectedConversationGenerating)
        workspace.draft = "第一份草稿"
        workspace.select(second.id)
        XCTAssertEqual(workspace.generationConversationID, original)
        XCTAssertFalse(workspace.isSelectedConversationGenerating)
        workspace.draft = "第二份草稿"
        provider.runs[0].yield(.snapshot(text: "属于第一个会话", reasoning: ""))
        provider.runs[0].yield(.complete)
        for _ in 0..<20 { await Task.yield() }
        _ = await workspace.flush()
        XCTAssertEqual(workspace.selectedID, second.id)
        XCTAssertEqual(workspace.selectedConversation?.messages.count, 0)
        XCTAssertNil(workspace.generationConversationID)
        XCTAssertEqual(storage.values.first(where: { $0.id == original })?.messages.last?.text, "属于第一个会话")
        workspace.select(original)
        XCTAssertEqual(workspace.draft, "第一份草稿")
    }

    func testRetryReusesUserTurnAndMetadataSurvivesCheckpoint() async throws {
        let (workspace, provider, storage) = try setup()
        workspace.draft = "只发送一次"
        workspace.send()
        let id = try XCTUnwrap(workspace.selectedID)
        provider.runs[0].yield(.snapshot(text: "部分", reasoning: ""))
        workspace.stop()
        workspace.rename(id, title: "手动标题")
        workspace.togglePin(id)
        await workspace.retry()?.value
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(provider.requests[1].filter { $0.role == .user }.count, 1)
        provider.runs[1].yield(.snapshot(text: "重试结果", reasoning: ""))
        provider.runs[1].yield(.complete)
        workspace.stop()
        _ = await workspace.flush()
        XCTAssertEqual(storage.values.first?.title, "手动标题")
        XCTAssertEqual(storage.values.first?.isPinned, true)
        XCTAssertEqual(storage.values.first?.messages.count, 2)
    }

    func testFirstMessageTitleSurvivesRestartThroughMetadataOwner() async throws {
        let (workspace, provider, storage) = try setup()
        workspace.draft = "首条消息派生的标题"
        workspace.send()
        provider.runs[0].yield(.complete)
        workspace.stop()
        _ = await workspace.flush()
        let restored = DesktopWorkspace(settings: workspace.settings, storage: storage, provider: provider)
        await restored.waitUntilLoaded()
        XCTAssertEqual(restored.selectedConversation?.title, "首条消息派生的标题")
    }

    func testCanonicalMessageSurvivesStreamStopPersistenceAndNextRequest() async throws {
        let (workspace, provider, storage) = try setup()
        workspace.draft = "看图并执行工具"
        workspace.send()
        let responseID = try XCTUnwrap(provider.responseIDs.first)
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.id, responseID)
        let canonical = Self.canonicalMessage(id: responseID)
        provider.runs[0].yield(.snapshot(text: "保留结构", reasoning: "推理", canonicalJSON: canonical, unsupportedPartCount: 3))
        workspace.stop()
        _ = await workspace.flush()
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.canonicalJSON, canonical)
        XCTAssertEqual(storage.values.first?.messages.last?.canonicalJSON, canonical)
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.unsupportedPartCount, 3)
        workspace.draft = "继续"
        workspace.send()
        XCTAssertEqual(provider.requests[1].first(where: { $0.id == responseID })?.canonicalJSON, canonical)
        workspace.stop()
    }

    func testRetryDoesNotUploadCancelledCanonicalAssistant() async throws {
        let (workspace, provider, _) = try setup()
        workspace.draft = "原始问题"
        workspace.send()
        let firstID = try XCTUnwrap(provider.responseIDs.first)
        provider.runs[0].yield(.snapshot(text: "旧的部分回复", reasoning: "", canonicalJSON: Self.canonicalMessage(id: firstID)))
        workspace.stop()
        await workspace.retry()?.value
        XCTAssertEqual(provider.requests[1].map(\.role), [.user])
        XCTAssertFalse(provider.requests[1].contains(where: { $0.id == firstID }))
        XCTAssertNotEqual(provider.responseIDs[1], firstID)
        workspace.stop()
    }

    func testLegacyMessageDefaultsDoNotRequireNewCanonicalKeys() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","role":"assistant","text":"旧内容","reasoning":"旧思考","state":"cancelled"}"#
        let message = try DesktopJSON.decode(DesktopMessage.self, from: json)
        XCTAssertNil(message.canonicalJSON)
        XCTAssertEqual(message.unsupportedPartCount, 0)
        XCTAssertEqual(message.state, .cancelled)
        XCTAssertEqual(message.text, "旧内容")
    }

    func testExportKeepsCurrentEnvelopeWhenSaveFailsAndCanBeReimported() async throws {
        let id = UUID()
        let canonical = Self.canonicalMessage(id: id)
        let conversation = DesktopConversation(title: "备份", messages: [
            DesktopMessage(id: id, role: .assistant, text: "重要内容", canonicalJSON: canonical, unsupportedPartCount: 3),
        ], canonicalJSON: "opaque-full-document-with-hidden-variants")
        let (template, provider, _) = try setup()
        let workspace = DesktopWorkspace(settings: template.settings, storage: FailingStorage([]), provider: provider,
            initialConversations: [conversation])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let export = try XCTUnwrap(workspace.exportConversation(to: url))
        await export.value
        let document = try String(contentsOf: url, encoding: .utf8)
        let exported = try DesktopJSON.decode(DesktopConversationExport.self, from: document)
        XCTAssertEqual(exported.conversation.canonicalJSON, conversation.canonicalJSON)
        XCTAssertEqual(exported.conversation.messages.first?.canonicalJSON, canonical)
        let memory = DesktopMemoryConversationStorage()
        let imported = try await memory.normalizeImport(document)
        XCTAssertEqual(imported.messages.first?.id, id)
        XCTAssertEqual(imported.messages.first?.canonicalJSON, canonical)
    }

    func testImportKeepsInnerMessageIdentityAndPublishesOnlyAfterSave() async throws {
        let (workspace, _, _) = try setup()
        let message = DesktopMessage(role: .tool, text: "工具结果", canonicalJSON: "opaque-tool-message")
        let original = DesktopConversation(title: "导入副本", messages: [message])
        let document = try DesktopJSON.encode(DesktopConversationExport(conversation: original))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try document.write(to: url, atomically: true, encoding: .utf8)
        let task = try XCTUnwrap(workspace.importConversation(from: url))
        await task.value
        XCTAssertNotEqual(workspace.selectedID, original.id)
        XCTAssertEqual(workspace.selectedConversation?.messages.first?.id, message.id)
        XCTAssertEqual(workspace.selectedConversation?.messages.first?.canonicalJSON, message.canonicalJSON)

        let (template, provider, _) = try setup()
        let failing = DesktopWorkspace(settings: template.settings, storage: FailingStorage([]), provider: provider,
            initialConversations: [])
        let failedTask = try XCTUnwrap(failing.importConversation(from: url))
        await failedTask.value
        XCTAssertTrue(failing.conversations.isEmpty)
        XCTAssertTrue(failing.errorMessage?.contains("导入失败") == true)
    }

    private static func canonicalMessage(id: UUID) -> String {
        #"{"id":"\#(id.uuidString.lowercased())","role":"assistant","parts":[{"type":"text","text":"保留结构","metadata":{"custom":{"x":1}}},{"type":"image","url":"data:image/png;base64,AQID"},{"type":"tool","toolCallId":"call-1","toolName":"read_file","input":"{}","output":[{"type":"text","text":"结果"}],"approvalState":{"type":"approved"}},{"type":"document","url":"file:///example.txt","fileName":"example.txt"}],"annotations":[{"type":"url_citation","title":"来源","url":"https://example.com"}],"modelId":"11111111-1111-1111-1111-111111111111","usage":{"promptTokens":10,"completionTokens":20,"totalTokens":30}}"#
    }

    func testDeleteRunningConversationDoesNotRecreateItFromLateEvents() async throws {
        let (workspace, provider, storage) = try setup()
        workspace.draft = "问题"
        workspace.send()
        let id = try XCTUnwrap(workspace.selectedID)
        workspace.delete(id)
        provider.runs[0].yield(.snapshot(text: "迟到消息", reasoning: ""))
        provider.runs[0].yield(.complete)
        _ = await workspace.flush()
        XCTAssertTrue(workspace.conversations.isEmpty)
        XCTAssertTrue(storage.values.isEmpty)
    }

    func testRestoringStreamingCheckpointRetainsPartialText() async throws {
        let value = DesktopConversation(messages: [DesktopMessage(role: .assistant, text: "进程结束前的文本", state: .streaming)])
        let (template, provider, storage) = try setup([value])
        let workspace = DesktopWorkspace(settings: template.settings, storage: storage, provider: provider)
        await workspace.waitUntilLoaded()
        _ = await workspace.flush()
        XCTAssertEqual(workspace.selectedConversation?.messages.first?.state, .cancelled)
        XCTAssertEqual(workspace.selectedConversation?.messages.first?.text, "进程结束前的文本")
    }

    func testFailureRemainsOwnedByOriginalConversation() async throws {
        let second = DesktopConversation(title: "另一个会话")
        let (workspace, provider, _) = try setup([second])
        workspace.createConversation()
        let original = try XCTUnwrap(workspace.selectedID)
        workspace.draft = "问题"
        workspace.send()
        workspace.select(second.id)
        provider.runs[0].yield(.failed("服务商失败"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(workspace.errorMessage)
        workspace.select(original)
        XCTAssertEqual(workspace.errorMessage, "服务商失败")
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.state, .failed)
    }

    func testFailedDeletionRestoresConversationAndDraft() async throws {
        let conversation = DesktopConversation(title: "不能丢的会话")
        let (template, provider, _) = try setup([conversation])
        let storage = FailingStorage([conversation])
        let workspace = DesktopWorkspace(settings: template.settings, storage: storage, provider: provider,
            initialConversations: [conversation])
        workspace.draft = "还未发送的草稿"
        workspace.delete(conversation.id)
        _ = await workspace.flush()
        XCTAssertEqual(workspace.selectedConversation?.title, "不能丢的会话")
        XCTAssertEqual(workspace.draft, "还未发送的草稿")
        XCTAssertTrue(workspace.errorMessage?.contains("已恢复") == true)
    }

    func testFlushReportsUnrecoverableWriteFailure() async throws {
        let (template, provider, _) = try setup()
        let workspace = DesktopWorkspace(settings: template.settings, storage: FailingStorage([]), provider: provider,
            initialConversations: [])
        workspace.createConversation()
        let succeeded = await workspace.flush()
        XCTAssertFalse(succeeded)
        XCTAssertEqual(workspace.conversations.count, 1)
    }

    func testSuccessfulDeleteClearsEarlierUnsavedCheckpoint() async throws {
        let (template, provider, _) = try setup()
        let storage = SaveFailureDeleteSuccessStorage()
        let workspace = DesktopWorkspace(settings: template.settings, storage: storage, provider: provider, initialConversations: [])
        workspace.createConversation()
        let id = try XCTUnwrap(workspace.selectedID)
        let initialFlush = await workspace.flush()
        XCTAssertFalse(initialFlush)
        workspace.delete(id)
        let finalFlush = await workspace.flush()
        XCTAssertTrue(finalFlush)
    }

    func testConcurrentAttachmentLoadsMergeAndSendWaitsForRead() async throws {
        let (workspace, provider, _) = try setup()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        try "第一份资料".write(to: first, atomically: true, encoding: .utf8)
        try "第二份资料".write(to: second, atomically: true, encoding: .utf8)
        workspace.addAttachments([first])
        workspace.addAttachments([second])
        workspace.draft = "整理附件"
        workspace.send()
        XCTAssertTrue(provider.runs.isEmpty)
        let deadline = Date().addingTimeInterval(3)
        while workspace.isReadingAttachments && Date() < deadline { await Task.yield() }
        XCTAssertFalse(workspace.isReadingAttachments)
        XCTAssertEqual(Set(workspace.pendingAttachments.map(\.name)), Set(["first.txt", "second.txt"]))
        workspace.send()
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertTrue(provider.requests[0].last?.text.contains("第一份资料") == true)
        XCTAssertTrue(provider.requests[0].last?.text.contains("第二份资料") == true)
        workspace.stop()
    }

    private final class SaveFailureDeleteSuccessStorage: DesktopConversationStorage {
        func loadAll() async throws -> [DesktopConversation] { [] }
        func save(_ conversation: DesktopConversation) async throws -> DesktopConversation { throw DesktopRuntimeError.message("写入错误") }
        func delete(_ id: UUID) async throws {}
    }

    private final class FailingStorage: DesktopConversationStorage {
        let values: [DesktopConversation]
        init(_ values: [DesktopConversation]) { self.values = values }
        func loadAll() async throws -> [DesktopConversation] { values }
        func save(_ conversation: DesktopConversation) async throws -> DesktopConversation { throw DesktopRuntimeError.message("磁盘错误") }
        func delete(_ id: UUID) async throws { throw DesktopRuntimeError.message("删除错误") }
    }
}
