import XCTest
@testable import AmberMac

@MainActor final class RuntimeBranchTests: XCTestCase {
    private final class Provider: DesktopTextProvider {
        var requests: [[DesktopMessage]] = []
        var runs: [DesktopGeneration] = []
        var failsStart = false
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            requests.append(messages)
            if failsStart { throw DesktopRuntimeError.message("provider unavailable") }
            let run = DesktopGeneration()
            runs.append(run)
            return run
        }
    }

    private func make(_ values: [DesktopConversation], storage: (any DesktopConversationStorage)? = nil) throws -> (DesktopWorkspace, Provider, DesktopMemoryConversationStorage) {
        let defaults = UserDefaults(suiteName: "amber.branch.tests.\(UUID().uuidString)")!
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        var configuration = settings.selectedProvider!
        configuration.modelID = "branch-test"
        try settings.saveProvider(configuration, apiKey: "test-key")
        let provider = Provider()
        let memory = DesktopMemoryConversationStorage(values)
        return (DesktopWorkspace(settings: settings, storage: storage ?? memory, provider: provider,
            initialConversations: values), provider, memory)
    }

    private func finish(_ workspace: DesktopWorkspace, _ provider: Provider, text: String) async {
        provider.runs.last!.yield(.snapshot(text: text, reasoning: ""))
        provider.runs.last!.yield(.complete)
        workspace.stop()
        _ = await workspace.flush()
    }

    func testRegeneratePreservesOriginalCandidateAndRequestsOnlyEarlierContext() async throws {
        let user = DesktopMessage(role: .user, text: "原问题")
        let answer = DesktopMessage(role: .assistant, text: "原回答", canonicalJSON: "opaque-original-parts")
        let trailing = DesktopMessage(role: .user, text: "之后的问题")
        let conversation = DesktopConversation(messages: [user, answer, trailing])
        let (workspace, provider, _) = try make([conversation])
        await workspace.regenerate(answer.id)?.value
        let replacement = try XCTUnwrap(workspace.selectedConversation?.messages.last)
        XCTAssertNotEqual(replacement.id, answer.id)
        XCTAssertEqual(replacement.variantIDs, [answer.id, replacement.id])
        XCTAssertEqual(replacement.variantIndex, 1)
        XCTAssertEqual(provider.requests.first?.map(\.id), [user.id])
        XCTAssertEqual(workspace.selectedConversation?.messages.count, 2)
        await finish(workspace, provider, text: "新的回答")
        await workspace.selectVariant(replacement.id, index: 0)?.value
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.id, answer.id)
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.canonicalJSON, "opaque-original-parts")
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.variantCount, 2)
    }

    func testEditResendsNewUserCandidateWithoutOldReplyOrTrailingTurns() async throws {
        let user = DesktopMessage(role: .user, text: "旧问题")
        let values = [user, DesktopMessage(role: .assistant, text: "旧回答"),
            DesktopMessage(role: .user, text: "后续问题"), DesktopMessage(role: .assistant, text: "后续回答")]
        let (workspace, provider, storage) = try make([DesktopConversation(messages: values)])
        await workspace.editAndResend(user.id, text: "编辑后的问题")?.value
        let edited = try XCTUnwrap(workspace.selectedConversation?.messages.first)
        XCTAssertNotEqual(edited.id, user.id)
        XCTAssertEqual(edited.variantIDs, [user.id, edited.id])
        XCTAssertEqual(provider.requests.first?.map(\.text), ["编辑后的问题"])
        XCTAssertEqual(workspace.selectedConversation?.messages.count, 2)
        await finish(workspace, provider, text: "新回答")
        let restored = DesktopWorkspace(settings: workspace.settings, storage: storage, provider: provider)
        await restored.waitUntilLoaded()
        XCTAssertEqual(restored.selectedConversation?.messages.first?.text, "编辑后的问题")
        await restored.selectVariant(edited.id, index: 0)?.value
        XCTAssertEqual(restored.selectedConversation?.messages.first?.text, "旧问题")
        XCTAssertEqual(restored.selectedConversation?.messages.last?.text, "新回答")
    }

    func testSelectingCandidateKeepsLaterNodesAndNextRequestUsesSelectedContent() async throws {
        let user = DesktopMessage(role: .user, text: "问题")
        let original = DesktopMessage(role: .assistant, text: "原回答", canonicalJSON: "opaque-first-candidate")
        let (workspace, provider, _) = try make([DesktopConversation(messages: [user, original])])
        await workspace.regenerate(original.id)?.value
        await finish(workspace, provider, text: "新回答")
        let replacementID = try XCTUnwrap(workspace.selectedConversation?.messages.last?.id)
        workspace.draft = "后续问题"
        workspace.send()
        await finish(workspace, provider, text: "后续回答")
        let suffix = Array(try XCTUnwrap(workspace.selectedConversation).messages.suffix(2))
        await workspace.selectVariant(replacementID, index: 0)?.value
        XCTAssertEqual(Array(try XCTUnwrap(workspace.selectedConversation).messages.suffix(2)), suffix)
        workspace.draft = "再继续"
        workspace.send()
        XCTAssertEqual(provider.requests.last?[1].id, original.id)
        XCTAssertEqual(provider.requests.last?[1].canonicalJSON, original.canonicalJSON)
        XCTAssertEqual(provider.requests.last?.count, 5)
        workspace.stop()
        _ = await workspace.flush()
    }

    func testDeleteRemovesOnlyTargetNodeAndPersistsNextRequestContext() async throws {
        let values = [DesktopMessage(role: .user, text: "问题一"), DesktopMessage(role: .assistant, text: "回答一"),
            DesktopMessage(role: .user, text: "问题二"), DesktopMessage(role: .assistant, text: "回答二")]
        let (workspace, provider, storage) = try make([DesktopConversation(messages: values)])
        await workspace.deleteMessage(values[1].id)?.value
        XCTAssertEqual(workspace.selectedConversation?.messages.map(\.id), [values[0].id, values[2].id, values[3].id])
        let restored = DesktopWorkspace(settings: workspace.settings, storage: storage, provider: provider)
        await restored.waitUntilLoaded()
        restored.draft = "下一步"
        restored.send()
        XCTAssertFalse(provider.requests.last!.contains { $0.id == values[1].id })
        XCTAssertEqual(provider.requests.last?.map(\.text), ["问题一", "问题二", "回答二", "下一步"])
        restored.stop()
        _ = await restored.flush()
    }

    func testFailedMutationDoesNotPublishOrGenerateAndErrorStaysWithOwner() async throws {
        let answer = DesktopMessage(role: .assistant, text: "已保存回答")
        let original = DesktopConversation(title: "原会话", messages: [DesktopMessage(role: .user, text: "问题"), answer])
        let second = DesktopConversation(title: "第二个会话")
        let gate = GateStorage([original, second])
        let (workspace, provider, _) = try make([original, second], storage: gate)
        let mutation = try XCTUnwrap(workspace.regenerate(answer.id))
        while !gate.isWaiting { await Task.yield() }
        XCTAssertTrue(workspace.isMutatingBranch)
        XCTAssertEqual(workspace.selectedConversation, original)
        workspace.select(second.id)
        workspace.draft = "不应在保存分支时发送"
        workspace.send()
        workspace.delete(original.id)
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(workspace.conversations.count, 2)
        gate.release(succeeds: false)
        await mutation.value
        XCTAssertFalse(workspace.isMutatingBranch)
        XCTAssertEqual(workspace.conversations.first(where: { $0.id == original.id }), original)
        XCTAssertNil(workspace.errorMessage)
        workspace.select(original.id)
        XCTAssertTrue(workspace.errorMessage?.contains("原分支已保留") == true)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testStopWhileBranchSaveIsPendingPreventsGenerationAndFlushesCancelledPlaceholder() async throws {
        let answer = DesktopMessage(role: .assistant, text: "原回答")
        let original = DesktopConversation(messages: [DesktopMessage(role: .user, text: "问题"), answer])
        let gate = GateStorage([original])
        let (workspace, provider, _) = try make([original], storage: gate)
        let mutation = try XCTUnwrap(workspace.regenerate(answer.id))
        while !gate.isWaiting { await Task.yield() }
        workspace.stop()
        gate.release(succeeds: true)
        await mutation.value
        let flushed = await workspace.flush()
        XCTAssertTrue(flushed)
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertFalse(workspace.isGenerating)
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.state, .cancelled)
        XCTAssertEqual(gate.memory.values.first?.messages.last?.state, .cancelled)
    }

    func testDeletingOnlyUserThenRegeneratingOrphanReplyDoesNotChangeBranchOrLaunch() async throws {
        let user = DesktopMessage(role: .user, text: "唯一的问题")
        let answer = DesktopMessage(role: .assistant, text: "孤立的回复")
        let (workspace, provider, storage) = try make([DesktopConversation(messages: [user, answer])])
        await workspace.deleteMessage(user.id)?.value
        let remaining = workspace.selectedConversation
        XCTAssertNil(workspace.regenerate(answer.id))
        XCTAssertEqual(workspace.selectedConversation, remaining)
        XCTAssertEqual(storage.values.first, remaining)
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertTrue(workspace.errorMessage?.contains("没有用户消息") == true)
    }

    func testSuccessfulBranchAndGenerationDoNotHideConcurrentMetadataWriteFailure() async throws {
        let answer = DesktopMessage(role: .assistant, text: "原回答")
        let original = DesktopConversation(messages: [DesktopMessage(role: .user, text: "问题"), answer])
        let gate = GateStorage([original])
        gate.failsMetadata = true
        let (workspace, provider, _) = try make([original], storage: gate)
        let mutation = try XCTUnwrap(workspace.regenerate(answer.id))
        while !gate.isWaiting { await Task.yield() }
        workspace.rename(original.id, title: "新标题")
        while gate.metadataAttempts == 0 { await Task.yield() }
        gate.release(succeeds: true)
        await mutation.value
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertTrue(workspace.errorMessage?.contains("会话保存失败") == true)
        workspace.stop()
        let flushed = await workspace.flush()
        XCTAssertFalse(flushed)
        XCTAssertTrue(workspace.errorMessage?.contains("会话保存失败") == true)
        XCTAssertEqual(workspace.selectedConversation?.title, "新标题")
    }

    func testCompactFacadePreparesNextRequestWithoutRemovingOriginalHistory() async throws {
        let messages = (0..<4).flatMap { index in
            [DesktopMessage(role: .user, text: "问题\(index)"), DesktopMessage(role: .assistant,
                text: index < 2 ? String(repeating: "较早的完整工作记录与决定。", count: 30) : "回答\(index)")]
        }
        let conversation = DesktopConversation(messages: messages)
        let (workspace, provider, _) = try make([conversation])
        workspace.requestInsight(.compact)
        let deadline = Date().addingTimeInterval(3)
        while provider.runs.isEmpty, Date() < deadline { await Task.yield() }
        let insightRun = try XCTUnwrap(provider.runs.first)
        insightRun.yield(.snapshot(text: "较早两轮的摘要", reasoning: ""))
        insightRun.yield(.complete)
        await workspace.insights.flush()
        XCTAssertNotNil(workspace.insights.value(.compact, for: conversation))
        workspace.draft = "继续"
        workspace.send()
        let request = try XCTUnwrap(provider.requests.last)
        XCTAssertEqual(request.first?.role, .system)
        XCTAssertTrue(request.first?.text.contains("较早两轮的摘要") == true)
        XCTAssertEqual(request.dropFirst().map(\.text), ["问题2", "回答2", "问题3", "回答3", "继续"])
        XCTAssertEqual(Array(try XCTUnwrap(workspace.selectedConversation).messages.prefix(8)), messages)
        workspace.stop()
        _ = await workspace.flush()
    }

    func testChatStopDoesNotCancelIndependentInsightRequest() async throws {
        let conversation = DesktopConversation(messages: [DesktopMessage(role: .user, text: "问题"),
            DesktopMessage(role: .assistant, text: "回答")])
        let (workspace, provider, _) = try make([conversation])
        workspace.requestInsight(.recap)
        let deadline = Date().addingTimeInterval(3)
        while provider.runs.isEmpty, Date() < deadline { await Task.yield() }
        let insightRun = try XCTUnwrap(provider.runs.first)
        workspace.stop()
        XCTAssertTrue(workspace.insights.activeOwners.contains(conversation.id))
        insightRun.yield(.snapshot(text: "独立回顾仍可完成", reasoning: ""))
        insightRun.yield(.complete)
        await workspace.insights.flush()
        XCTAssertEqual(workspace.insights.value(.recap, for: conversation)?.text, "独立回顾仍可完成")
    }

    func testEditCommitRejectsInvalidMessageAndEmptyInputExactlyOnce() throws {
        let user = DesktopMessage(role: .user, text: "original")
        let conversation = DesktopConversation(messages: [user])
        let (workspace, provider, _) = try make([conversation])
        var rejected: [Bool] = []
        XCTAssertNil(workspace.editAndResend(UUID(), text: "edited", completion: { rejected.append($0) }))
        XCTAssertNil(workspace.editAndResend(user.id, text: " \n ", completion: { rejected.append($0) }))
        XCTAssertEqual(rejected, [false, false])
        XCTAssertEqual(workspace.selectedConversation, conversation)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testEditCommitConfigurationFailureKeepsOriginalMessage() throws {
        let user = DesktopMessage(role: .user, text: "original")
        let conversation = DesktopConversation(messages: [user])
        let (workspace, provider, _) = try make([conversation])
        for configuration in workspace.settings.providers { try workspace.settings.deleteProvider(configuration.id) }
        var results: [Bool] = []
        XCTAssertNil(workspace.editAndResend(user.id, text: "edited", completion: { results.append($0) }))
        XCTAssertEqual(results, [false])
        XCTAssertEqual(workspace.selectedConversation, conversation)
        XCTAssertTrue(workspace.conversationError(for: conversation.id)?.contains("服务商") == true)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testEditCommitWriteFailureKeepsOriginalAndReportsToOriginalOwnerOnce() async throws {
        let user = DesktopMessage(role: .user, text: "original")
        let conversation = DesktopConversation(messages: [user]), other = DesktopConversation()
        let gate = GateStorage([conversation, other])
        let (workspace, provider, _) = try make([conversation, other], storage: gate)
        var results: [Bool] = []
        var callbackSawMutation: [Bool] = []
        let operation = try XCTUnwrap(workspace.editAndResend(user.id, text: "edited", completion: {
            results.append($0); callbackSawMutation.append(workspace.isMutatingBranch)
        }))
        while !gate.isWaiting { await Task.yield() }
        XCTAssertTrue(results.isEmpty)
        var busyResult: [Bool] = []
        XCTAssertNil(workspace.editAndResend(user.id, text: "duplicate", completion: { busyResult.append($0) }))
        XCTAssertEqual(busyResult, [false])
        workspace.select(other.id)
        gate.release(succeeds: false)
        await operation.value
        XCTAssertEqual(results, [false])
        XCTAssertEqual(callbackSawMutation, [false])
        XCTAssertEqual(workspace.conversations.first(where: { $0.id == conversation.id }), conversation)
        XCTAssertNil(workspace.errorMessage)
        XCTAssertTrue(workspace.conversationError(for: conversation.id)?.contains("消息更改未保存") == true)
        XCTAssertNil(workspace.conversationError(for: other.id))
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testEditCommitReportsSuccessAfterDurablePublish() async throws {
        let user = DesktopMessage(role: .user, text: "original")
        let (workspace, provider, storage) = try make([DesktopConversation(messages: [user])])
        var results: [Bool] = []
        var visibleAtCommit: [String?] = []
        var durableAtCommit: [String?] = []
        var callbackSawMutation: [Bool] = []
        let operation = try XCTUnwrap(workspace.editAndResend(user.id, text: "edited", completion: {
            results.append($0)
            visibleAtCommit.append(workspace.selectedConversation?.messages.first?.text)
            durableAtCommit.append(storage.values.first?.messages.first?.text)
            callbackSawMutation.append(workspace.isMutatingBranch)
        }))
        await operation.value
        XCTAssertEqual(results, [true])
        XCTAssertEqual(visibleAtCommit, ["edited"])
        XCTAssertEqual(durableAtCommit, ["edited"])
        XCTAssertEqual(callbackSawMutation, [false])
        XCTAssertEqual(provider.requests.count, 1)
        await finish(workspace, provider, text: "new reply")
        XCTAssertEqual(results, [true])
    }

    func testEditCommitRemainsAcceptedWhenProviderCannotStart() async throws {
        let user = DesktopMessage(role: .user, text: "original")
        let (workspace, provider, storage) = try make([DesktopConversation(messages: [user])])
        provider.failsStart = true
        var results: [Bool] = []
        let operation = try XCTUnwrap(workspace.editAndResend(user.id, text: "edited", completion: { results.append($0) }))
        await operation.value
        let flushed = await workspace.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(results, [true])
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertFalse(workspace.isGenerating)
        XCTAssertEqual(storage.values.first?.messages.first?.text, "edited")
        XCTAssertEqual(storage.values.first?.messages.last?.state, .failed)
    }

    private final class GateStorage: DesktopConversationStorage {
        let memory: DesktopMemoryConversationStorage
        var isWaiting = false
        var failsMetadata = false
        var metadataAttempts = 0
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ values: [DesktopConversation]) { memory = DesktopMemoryConversationStorage(values) }
        func release(succeeds: Bool) { continuation?.resume(returning: succeeds); continuation = nil }
        func loadAll() async throws -> [DesktopConversation] { try await memory.loadAll() }
        func save(_ value: DesktopConversation) async throws -> DesktopConversation { try await memory.save(value) }
        func delete(_ id: UUID) async throws { try await memory.delete(id) }
        func updateMetadata(_ id: UUID, title: String?, isPinned: Bool?) async throws {
            metadataAttempts += 1
            if failsMetadata { throw DesktopRuntimeError.message("测试标题保存失败") }
            try await memory.updateMetadata(id, title: title, isPinned: isPinned)
        }
        func regenerate(_ conversation: DesktopConversation, messageID: UUID, responseID: UUID) async throws -> DesktopConversation {
            try await waitForWrite()
            return try await memory.regenerate(conversation, messageID: messageID, responseID: responseID)
        }
        func editMessage(_ conversation: DesktopConversation, messageID: UUID, textPartIndex: Int, text: String, responseID: UUID) async throws -> DesktopConversation {
            try await waitForWrite()
            return try await memory.editMessage(conversation, messageID: messageID, textPartIndex: textPartIndex, text: text, responseID: responseID)
        }
        private func waitForWrite() async throws {
            let succeeds = await withCheckedContinuation { continuation in
                self.continuation = continuation
                isWaiting = true
            }
            guard succeeds else { throw DesktopRuntimeError.message("测试写盘失败") }
        }
    }
}
