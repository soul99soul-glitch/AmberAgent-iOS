import XCTest
@preconcurrency import Shared
@testable import iosApp

/// G9 契约测试:上下文压缩对历史的静默加工必须显式标注。
///
/// 覆盖三条契约:
/// 1. 被裁剪/清空的工具消息原位留下 `[tool output compacted]` 占位标记;
/// 2. 压缩 handoff 注入的移除计数准确(trim+clear 同一条工具结果不重复计数),
///    并告知模型可重新调用工具取回原始内容;
/// 3. `fitMessagesToTokenBudget` 截尾丢弃消息时,注入侧必须可见(不得静默)。
@MainActor
final class IOSContextCompactionCoordinatorTests: XCTestCase {
    func testNativeTranscriptBudgetValidationNeverMovesSystemUpdates() throws {
        let defaults = UserDefaults(suiteName: "TranscriptBudget-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults).snapshot
        let model = Model(
            modelId: "gpt-5.4", displayName: "test", id: KotlinUuid.companion.random(),
            type: .chat, customHeaders: [], customBodies: [], inputModalities: [],
            outputModalities: [], abilities: [], tools: Set<BuiltInTools>(),
            contextWindowTokens: KotlinInt(value: 8_000), providerOverwrite: nil
        )
        let params = TextGenerationParams(
            model: model, temperature: nil, topP: nil, maxTokens: nil, tools: [],
            reasoningLevel: .off, customHeaders: [], customBody: []
        )
        let messages = [
            UIMessage.companion.system(prompt: "initial"),
            UIMessage.companion.user(prompt: "question"),
            UIMessage.companion.system(prompt: "update"),
        ]
        let coordinator = IOSContextCompactionCoordinator()
        let valid = try coordinator.finalizedMessagesForRequest(
            messages, settings: settings, params: params, preserveMessageOrder: true
        )
        XCTAssertEqual(valid.map { $0.id }, messages.map { $0.id })
        XCTAssertThrowsError(try coordinator.finalizedMessagesForRequest(
            messages, settings: settings, params: params,
            additionalOverheadTokens: 10_000, preserveMessageOrder: true
        ))
    }

    func testRequestSystemMessagesDoNotInvalidateSavedCompaction() async throws {
        let provider = SuccessfulCompactProvider()
        let coordinator = IOSContextCompactionCoordinator(textProvider: provider)
        let defaults = UserDefaults(suiteName: "CompactSystem-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults).snapshot
        let model = Model(
            modelId: "compact-test", displayName: "Compact Test", id: KotlinUuid.companion.random(),
            type: ModelType.chat, customHeaders: [], customBodies: [], inputModalities: [],
            outputModalities: [], abilities: [], tools: Set<BuiltInTools>(),
            contextWindowTokens: KotlinInt(value: 10_000), providerOverwrite: nil
        )
        let fallback = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(), enabled: true, name: "Test", models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""), builtIn: false,
            descriptionText: nil, shortDescriptionText: nil, apiKey: "test", baseUrl: "https://example.test",
            chatCompletionsPath: "/chat/completions", useResponseApi: false, authMode: .apiKey, brand: .generic
        )
        let params = TextGenerationParams(
            model: model, temperature: nil, topP: nil, maxTokens: nil, tools: [], reasoningLevel: .off,
            customHeaders: [], customBody: []
        )
        let conversationId = KotlinUuid.companion.random()
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("conversation-compacts/\(conversationId).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let history = (0..<26).map { _ in
            UIMessage.companion.user(prompt: String(repeating: "x", count: 1_400))
        }
        let firstSystem = UIMessage.companion.system(prompt: "Request-only guidance")
        var sawCompactedHistory = false
        let first = try await coordinator.prepareMessagesForRequest(
            uploadMessages: [firstSystem] + history, conversationId: conversationId,
            settings: settings, params: params, fallbackProvider: fallback,
            additionalHistoryOverhead: { retained in
                let includesOldPromptTransitions = retained.contains { $0.id == history[0].id }
                if !includesOldPromptTransitions { sawCompactedHistory = true }
                // The pre-compaction transition history alone exceeded the window.
                // Keeping that stale estimate after checkpointing would reject this request.
                return includesOldPromptTransitions ? 15_000 : 0
            }
        )
        XCTAssertTrue(sawCompactedHistory)
        XCTAssertTrue(first.contains { $0.id == firstSystem.id })
        let boundaries = coordinator.timelineBoundaries(conversationId: conversationId, messages: history)
        XCTAssertEqual(boundaries.count, 1)
        XCTAssertFalse(boundaries.contains { $0.coveredMessageIds.contains(String(describing: firstSystem.id)) })
        let callsAfterFirst = provider.calls
        XCTAssertGreaterThan(callsAfterFirst, 0)
        let nextSystem = UIMessage.companion.system(prompt: "Updated request-only guidance")
        let next = try await coordinator.prepareMessagesForRequest(
            uploadMessages: [nextSystem] + history, conversationId: conversationId,
            settings: settings, params: params, fallbackProvider: fallback
        )
        XCTAssertEqual(provider.calls, callsAfterFirst, "A new request system ID must not trigger another compression")
        XCTAssertTrue(next.contains { $0.id == nextSystem.id })
        XCTAssertFalse(next.contains { $0.id == firstSystem.id })
        XCTAssertEqual(IOSContextCompactionCoordinator().timelineBoundaries(
            conversationId: conversationId, messages: history
        ).map(\.id), boundaries.map(\.id))
    }

    func testTimelineBoundariesRestoreFromPersistedCompacts() throws {
        let conversationId = KotlinUuid.companion.random()
        let old = UIMessage.companion.user(prompt: "old")
        let recent = UIMessage.companion.user(prompt: "recent")
        let oldID = String(describing: old.id)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("conversation-compacts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(conversationId).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var record: [String: Any] = [
            "id": "saved-compact", "conversationId": String(describing: conversationId), "summary": "Saved summary",
            "level": 1, "sourceStartIndex": 0, "sourceEndIndex": 0, "sourceMessageIds": [oldID],
            "tokenEstimate": 10, "createdAt": 1_000, "updatedAt": 1_000, "status": "completed"
        ]
        try JSONSerialization.data(withJSONObject: [record]).write(to: file)
        let restored = IOSContextCompactionCoordinator().timelineBoundaries(conversationId: conversationId, messages: [old, recent])
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.id, "saved-compact")
        XCTAssertEqual(restored.first?.afterMessageId, oldID)
        XCTAssertEqual(restored.first?.coveredMessageIds, [oldID])
        XCTAssertTrue(IOSContextCompactionCoordinator().timelineBoundaries(conversationId: conversationId, messages: [recent]).isEmpty)
        record["timelineAnchorMessageId"] = String(describing: recent.id)
        try JSONSerialization.data(withJSONObject: [record]).write(to: file)
        let anchored = IOSContextCompactionCoordinator().timelineBoundaries(conversationId: conversationId, messages: [old, recent])
        XCTAssertEqual(anchored.first?.afterMessageId, String(describing: recent.id))
        XCTAssertTrue(IOSContextCompactionCoordinator().timelineBoundaries(conversationId: conversationId, messages: [old]).isEmpty)
    }

    func testSingleThresholdWaitsBeforeReturningUploadMessagesAndCancelsWithRequest() async throws {
        let provider = BlockingCompactProvider()
        let coordinator = IOSContextCompactionCoordinator(textProvider: provider)
        let defaults = UserDefaults(suiteName: "CompactWait-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults).snapshot
        let model = Model(
            modelId: "compact-test", displayName: "Compact Test", id: KotlinUuid.companion.random(),
            type: ModelType.chat, customHeaders: [], customBodies: [], inputModalities: [],
            outputModalities: [], abilities: [], tools: Set<BuiltInTools>(),
            contextWindowTokens: KotlinInt(value: 10_000), providerOverwrite: nil
        )
        let fallback = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(), enabled: true, name: "Test", models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""), builtIn: false,
            descriptionText: nil, shortDescriptionText: nil, apiKey: "test", baseUrl: "https://example.test",
            chatCompletionsPath: "/chat/completions", useResponseApi: false, authMode: .apiKey, brand: .generic
        )
        let params = TextGenerationParams(
            model: model, temperature: nil, topP: nil, maxTokens: nil, tools: [], reasoningLevel: .off,
            customHeaders: [], customBody: []
        )
        let messages = (0..<22).map { _ in UIMessage.companion.user(prompt: String(repeating: "x", count: 1_400)) }
        _ = try await coordinator.prepareMessagesForRequest(
            uploadMessages: messages, conversationId: KotlinUuid.companion.random(), settings: settings,
            params: params, fallbackProvider: fallback
        )
        XCTAssertFalse(provider.started, "Below 85% must not call the compression model")
        let overThreshold = messages + (0..<4).map { _ in UIMessage.companion.user(prompt: String(repeating: "x", count: 1_400)) }
        var returned = false
        let task = Task { @MainActor in
            defer { returned = true }
            return try await coordinator.prepareMessagesForRequest(
                uploadMessages: overThreshold, conversationId: KotlinUuid.companion.random(), settings: settings,
                params: params, fallbackProvider: fallback
            )
        }
        defer { task.cancel() }
        for _ in 0..<500 where !provider.started && !returned {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(provider.started)
        XCTAssertFalse(returned, "An 85% compaction must finish before the agent gets its next request")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(provider.cancelled)
    }

    func testAutomaticThresholdUsesCompactedHistoryAndNewRequestOverhead() {
        let history = (0..<10).map { _ in
            UIMessage.companion.user(prompt: String(repeating: "x", count: 4_000))
        }
        let tail = (0..<8).map { _ in UIMessage.companion.user(prompt: "continue") }
        let messages = history + tail
        let covered = history.map { String(describing: $0.id) }
        XCTAssertTrue(ContextCompactionEditTestSupport.automaticPlan(messages: messages, coveredIds: []).shouldCompact)
        let compacted = ContextCompactionEditTestSupport.automaticPlan(messages: messages, coveredIds: covered)
        XCTAssertFalse(compacted.shouldCompact)
        XCTAssertLessThan(compacted.estimatedTokens, 1_000)
        XCTAssertTrue(ContextCompactionEditTestSupport.automaticPlan(
            messages: messages, coveredIds: covered, overheadTokens: 9_000
        ).shouldCompact)
        // A deleted/replaced source message invalidates its compact; do not undercount the remaining history.
        XCTAssertTrue(ContextCompactionEditTestSupport.automaticPlan(
            messages: Array(messages.dropFirst()), coveredIds: covered
        ).shouldCompact)
    }


    private func makeMessage(parts: [UIMessagePart]) -> UIMessage {
        let now = Kotlinx_datetimeLocalDateTime(
            year: 2026, month: 6, day: 20, hour: 0, minute: 0, second: 0, nanosecond: 0
        )
        return UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: parts,
            annotations: [],
            createdAt: now,
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    private func makeToolPart(toolName: String, outputChars: Int) -> UIMessagePart.Tool {
        UIMessagePart.Tool(
            toolCallId: "tool-\(toolName)",
            toolName: toolName,
            input: #"{"query":"x"}"#,
            output: [UIMessagePart.Text(text: String(repeating: "x", count: outputChars), metadata: nil)],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
    }

    private func toolOutputText(_ message: UIMessage) -> String? {
        guard let tool = message.parts.first as? UIMessagePart.Tool,
              let text = tool.output.first as? UIMessagePart.Text else { return nil }
        return text.text
    }

    func testEditPreparedContextLeavesCompactionMarkersInPlace() throws {
        let clearableLarge = makeMessage(parts: [makeToolPart(toolName: "file_read", outputChars: 5_000)])
        let nonClearableHuge = makeMessage(parts: [makeToolPart(toolName: "workspace_write", outputChars: 20_000)])
        let clearableMedium = makeMessage(parts: [makeToolPart(toolName: "file_search", outputChars: 3_000)])
        let recentTool = makeMessage(parts: [makeToolPart(toolName: "file_read", outputChars: 50_000)])
        let userTail = UIMessage.companion.user(prompt: "继续")

        let messages = [clearableLarge, nonClearableHuge, clearableMedium, recentTool, userTail]
        let edited = ContextCompactionEditTestSupport.editedMessagesWithCount(
            messages: messages,
            keepRecentMessages: 2
        )

        // 前三条旧消息被处理,近两条(recentTool + userTail)不动。
        XCTAssertEqual(edited.messages.count, messages.count)
        XCTAssertEqual(edited.removedToolResults, 3)
        XCTAssertEqual(edited.messages[2].id, messages[2].id)

        let clearedText = try XCTUnwrap(toolOutputText(edited.messages[0]))
        XCTAssertTrue(clearedText.contains(ContextCompactionEditTestSupport.compactedToolOutputMarker))
        XCTAssertTrue(clearedText.contains("\"status\":\"cleared_tool_result\""))

        let trimmedText = try XCTUnwrap(toolOutputText(edited.messages[1]))
        XCTAssertTrue(trimmedText.contains(ContextCompactionEditTestSupport.compactedToolOutputMarker))
        XCTAssertTrue(trimmedText.contains("\"status\":\"trimmed_tool_result\""))

        XCTAssertTrue(
            try XCTUnwrap(toolOutputText(edited.messages[2])).contains("\"status\":\"cleared_tool_result\"")
        )

        // 最近消息与用户消息保持原样。
        XCTAssertEqual(edited.messages[3].id, recentTool.id)
        XCTAssertEqual(toolOutputText(edited.messages[3]), String(repeating: "x", count: 50_000))
        XCTAssertEqual(edited.messages[4].toText(), "继续")
    }

    func testRemovedToolResultsCountDoesNotDoubleCountTrimThenClear() throws {
        // file_read 结果超大:先被 trim 换成长预览占位,再被 clear 换成清空占位。
        // 最终只有一条工具结果被改动,计数必须为 1,不能把两次变换数成 2。
        let huge = makeMessage(parts: [makeToolPart(toolName: "file_read", outputChars: 20_000)])
        let userTail = UIMessage.companion.user(prompt: "继续")

        let edited = ContextCompactionEditTestSupport.editedMessagesWithCount(
            messages: [huge, userTail],
            keepRecentMessages: 0
        )

        XCTAssertEqual(edited.removedToolResults, 1)
        let text = try XCTUnwrap(toolOutputText(edited.messages[0]))
        XCTAssertTrue(text.contains(ContextCompactionEditTestSupport.compactedToolOutputMarker))
        XCTAssertTrue(text.contains("\"status\":\"cleared_tool_result\""))
        XCTAssertFalse(text.contains("\"status\":\"trimmed_tool_result\""))
    }

    func testRemovedToolResultsCountIsZeroWhenNothingIsEdited() {
        let small = makeMessage(parts: [makeToolPart(toolName: "file_read", outputChars: 100)])
        let userTail = UIMessage.companion.user(prompt: "继续")

        let edited = ContextCompactionEditTestSupport.editedMessagesWithCount(
            messages: [small, userTail],
            keepRecentMessages: 0
        )

        XCTAssertEqual(edited.removedToolResults, 0)
        XCTAssertEqual(toolOutputText(edited.messages[0]), String(repeating: "x", count: 100))
    }

    func testHandoffInjectionReportsRemovedToolResultCount() throws {
        let summary = ##"{"schema_version":2,"timeline_summary":"History was compacted.","handoff_markdown":"# Goal\nContinue the plan.","covered_compact_ids":[],"source_message_ids":["a"],"created_at":1}"##

        let withNote = ContextCompactionEditTestSupport.injectedHandoffText(
            id: "compact-1",
            summary: summary,
            sourceMessageIds: ["m1", "m2"],
            removedToolResults: 3
        )
        XCTAssertTrue(withNote.hasPrefix("[Conversation compact handoff: compact-1]"))
        XCTAssertTrue(withNote.contains("Note: 3 tool result(s) from older messages were removed or trimmed"))
        XCTAssertTrue(withNote.contains("re-run the relevant tool"))
        XCTAssertTrue(withNote.contains("# Goal"))

        let withoutNote = ContextCompactionEditTestSupport.injectedHandoffText(
            id: "compact-1",
            summary: summary,
            sourceMessageIds: ["m1", "m2"],
            removedToolResults: 0
        )
        XCTAssertFalse(withoutNote.contains("Note: "))
        XCTAssertTrue(withoutNote.contains("# Goal"))
    }

    func testFitMessagesToTokenBudgetMakesTruncationVisibleOnInjectionSide() throws {
        let handoff = "[Conversation compact handoff: h1]\n\n\(String(repeating: "旧摘要", count: 6_000))"
        let messages = [
            UIMessage.companion.system(prompt: handoff),
            UIMessage.companion.user(prompt: "继续"),
            UIMessage.companion.user(prompt: String(repeating: "早前历史", count: 25)),
            UIMessage.companion.user(prompt: String(repeating: "更早历史", count: 25)),
        ]

        let fitted = ContextCompactionEditTestSupport.fittedMessagesWithBudget(messages: messages, maxTokens: 1_000)

        // 丢弃发生在截尾侧,但注记必须出现在注入侧(返回值里),不能静默。
        XCTAssertLessThan(fitted.count, messages.count)
        let notice = fitted.first { message in
            message.role == MessageRole.system && message.toText().contains("Context note:")
        }
        let noticeText = try XCTUnwrap(notice?.toText())
        let dropped = messages.count - (fitted.count - 1) // 去掉注记自身
        XCTAssertTrue(noticeText.contains("Context note: \(dropped) older message(s) were omitted"))
        XCTAssertTrue(noticeText.contains("re-run the relevant tool or expand history"))
    }

    func testFitMessagesToTokenBudgetAddsNoNoticeWhenNothingIsDropped() {
        let messages = [
            UIMessage.companion.system(prompt: "small handoff"),
            UIMessage.companion.user(prompt: "继续"),
        ]

        let fitted = ContextCompactionEditTestSupport.fittedMessagesWithBudget(messages: messages, maxTokens: 10_000)

        XCTAssertEqual(fitted.count, messages.count)
        XCTAssertFalse(fitted.map { $0.toText() }.joined(separator: "\n").contains("Context note:"))
    }

    // MARK: - 截尾兜底学会截断（真机 1MB Exa 全文 → 请求必败的第三层）

    func testFitMessagesToTokenBudgetTruncatesGiantToolOutputInsteadOfFailing() throws {
        // 真机出事轮形态：巨量 search_web 输出消息是最后（最新）一条，前面只有
        // 小消息——截尾兜底选中它时是唯一候选。旧行为把它整条硬保 → 估算远超
        // 预算 → assertFitsRequest 抛错。新行为：就地截断工具输出到预算内。
        let userTail = UIMessage.companion.user(prompt: "继续")
        let giant = makeMessage(parts: [makeToolPart(toolName: "search_web", outputChars: 2_000_000)])

        let fitted = ContextCompactionEditTestSupport.fittedMessagesWithBudget(
            messages: [userTail, giant],
            maxTokens: 1_000
        )

        let estimate = IOSContextCompactionCoordinator.estimatedTokensForRequest(fitted)
        XCTAssertLessThanOrEqual(estimate, 1_000)
        // 巨消息本身保留（宁超窗不丢消息语义不变），其工具输出被截断并带标记。
        let giantKept = try XCTUnwrap(fitted.first { $0.id == giant.id })
        let text = try XCTUnwrap(toolOutputText(giantKept))
        XCTAssertTrue(text.contains("…[truncated"))
        XCTAssertLessThan(text.count, 2_000_000)
    }

    func testFinalRequestBudgetUsesRegistryAndSameUnknownModelDefaultAsUI() throws {
        let suite = "Compaction-Window-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IOSSharedSettingsStore(userDefaults: defaults).snapshot
        // Fits 200K/272K budgets, but was truncated by the old 128K fallback.
        let message = UIMessage.companion.user(prompt: String(repeating: "x", count: 600_000))
        for modelId in ["gpt-6-astra", "unknown-window-model"] {
            let model = Model(
                modelId: modelId, displayName: modelId, id: KotlinUuid.companion.random(),
                type: .chat, customHeaders: [], customBodies: [], inputModalities: [],
                outputModalities: [], abilities: [], tools: Set<BuiltInTools>(),
                contextWindowTokens: nil, providerOverwrite: nil
            )
            let params = TextGenerationParams(
                model: model, temperature: nil, topP: nil, maxTokens: nil, tools: [],
                reasoningLevel: .off, customHeaders: [], customBody: []
            )
            let finalized = try IOSContextCompactionCoordinator().finalizedMessagesForRequest(
                [message], settings: settings, params: params
            )
            XCTAssertEqual((finalized.first?.parts.first as? UIMessagePart.Text)?.text,
                           (message.parts.first as? UIMessagePart.Text)?.text)
        }
    }

    func testFinalizedMessagesForRequestRecoversGiantOutputSession() throws {
        // 真机复现形态：已持久化的巨量 search_web 输出在请求时被 fit 就地截断，
        // finalizedMessagesForRequest 不再抛错，估算回到预算内。
        let defaults = UserDefaults(suiteName: "Compaction-Giant-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults).snapshot
        let params = TextGenerationParams(
            model: Model(
                modelId: "giant-output-test",
                displayName: "Giant Output Test",
                id: KotlinUuid.companion.random(),
                type: ModelType.chat,
                customHeaders: [],
                customBodies: [],
                inputModalities: [],
                outputModalities: [],
                abilities: [],
                tools: Set<BuiltInTools>(),
                contextWindowTokens: KotlinInt(value: 128_000),
                providerOverwrite: nil
            ),
            temperature: nil,
            topP: nil,
            maxTokens: nil,
            tools: [],
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
        let giant = makeMessage(parts: [makeToolPart(toolName: "search_web", outputChars: 2_000_000)])
        let userTail = UIMessage.companion.user(prompt: "继续")

        let finalized = try IOSContextCompactionCoordinator.shared.finalizedMessagesForRequest(
            [userTail, giant],
            settings: settings,
            params: params
        )

        let forceBudget = max(
            Int(Double(128_000) * Double(settings.agentRuntime.contextCompaction.forceRatio)),
            1
        )
        XCTAssertLessThanOrEqual(
            IOSContextCompactionCoordinator.estimatedTokensForRequest(finalized),
            forceBudget
        )
        let texts = finalized.flatMap(\.parts).compactMap { ($0 as? UIMessagePart.Tool)?.output }
            .flatMap { $0.compactMap { ($0 as? UIMessagePart.Text)?.text } }
            .joined(separator: "\n")
        XCTAssertTrue(texts.contains("…[truncated"))
    }
}

@MainActor
private final class BlockingCompactProvider: @preconcurrency IOSAgentTextProvider {
    var started = false
    var cancelled = false

    func generateText(providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams) async throws -> MessageChunk {
        started = true
        do {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        } catch {
            cancelled = true
            throw error
        }
        throw CancellationError()
    }
}

@MainActor
private final class SuccessfulCompactProvider: @preconcurrency IOSAgentTextProvider {
    var calls = 0
    func generateText(providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams) async throws -> MessageChunk {
        calls += 1
        return MessageChunk(id: "compact", model: "test", choices: [
            UIMessageChoice(index: 0, delta: nil,
                message: UIMessage.companion.assistant(prompt: "The user is testing context compaction. Preserve the conversation history. Continue the current task. No external actions were performed."),
                finishReason: "stop")
        ], usage: nil)
    }
}
