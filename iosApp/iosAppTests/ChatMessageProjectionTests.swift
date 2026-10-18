import XCTest
import Combine
import SwiftUI
import CoreText
import Shared
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class ChatMessageProjectionTests: ChatMessageProjectionTestCase {

    func testToolProjectionReusesHistoryAndRefreshesNonTailBackfills() throws {
        let cache = NativeTimelineProjectionCache()
        let hashes = ChatRowContentHashCache()
        let renderStore = ChatRenderStateStore()
        var messages = (0..<60).map { UIMessage.companion.assistant(prompt: "历史 \($0)") }
        var revision = 0
        var requested: [Int] = []
        let streamed = Set([ChatMessageProjector.messageId(for: messages.last!)])
        var boundary = ChatContextCompactBoundary(id: "tools-compact",
            afterMessageId: ChatMessageProjector.messageId(for: messages[20]),
            coveredMessageIds: [ChatMessageProjector.messageId(for: messages[0])],
            state: ChatContextCompactState(status: .completed, summary: "摘要", updatedAt: Date()))
        func project(_ event: ChatEvent, display: String = "") -> NativeTimelineProjection {
            revision += 1
            requested = []
            return cache.projection(messages: messages, event: event, sourceRevision: revision,
                startIndex: 0, configurationIssue: nil, isGenerationActive: true,
                isLoading: false, isRecognizingImages: false, contextCompactState: .idle,
                contextCompactBoundaries: [boundary], viewportState: ChatViewportState(),
                displaySettingSignature: display, generativeUiSettingSignature: "",
                renderStateRevision: 0, reasoningLevelLabel: nil, streamedMessageIDs: streamed,
                renderStateStore: renderStore, variantInfoProvider: { index in
                    requested.append(index); return nil
                }, contentHashProvider: { row, streaming in
                    streaming ? hashes.streamingTailLayoutToken(for: row) : hashes.contentHash(for: row)
                })
        }
        let before = project(.toolResultAppended)
        XCTAssertEqual(requested.count, 60)
        let old = messages[40]
        let output = UIMessagePart.Text(text: #"{"status":"completed","stdout":"late"}"#, metadata: nil)
        let tool = UIMessagePart.Tool(toolCallId: "late-ssh", toolName: "terminal_execute", input: "{}",
            output: [output], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)
        messages[40] = UIMessage(id: old.id, role: old.role, parts: [tool], annotations: [],
            createdAt: old.createdAt, finishedAt: old.finishedAt, modelId: nil, usage: nil, translation: nil)
        let after = project(.toolResultAppended)
        XCTAssertEqual(requested, [40, 59], "只重建变化的历史行与承载运行状态的尾行")
        let full = NativeTimelineProjector.build(messages: messages, event: .toolResultAppended,
            isGenerationActive: true, contextCompactBoundaries: [boundary],
            streamedMessageIDs: streamed, renderStateStore: renderStore,
            contentHashProvider: { row, streaming in
                streaming ? hashes.streamingTailLayoutToken(for: row) : hashes.contentHash(for: row)
            })
        XCTAssertEqual(after, full, "增量结果必须与全量投影完全一致，包括压缩标记与行操作索引")
        XCTAssertEqual(before.entries.first, after.entries.first)
        output.metadata = [:]
        _ = project(.toolResultAppended)
        XCTAssertEqual(requested, [40, 59], "同一消息对象内的 metadata 修改不能被 identity 短路")
        boundary = ChatContextCompactBoundary(id: boundary.id, afterMessageId: boundary.afterMessageId,
            coveredMessageIds: boundary.coveredMessageIds,
            state: ChatContextCompactState(status: .completed, summary: "更新后的摘要", updatedAt: Date()))
        let newBoundary = project(.toolResultAppended)
        XCTAssertEqual(requested.count, 60, "同 id 压缩边界内容变化必须使结构缓存失效")
        XCTAssertEqual(newBoundary.entries.first { $0.kind == .contextMarker }?.compactState?.summary, "更新后的摘要")
        _ = project(.toolResultAppended, display: "changed-font")
        XCTAssertEqual(requested.count, 60, "显示设置变化必须全量重建")
        messages.insert(UIMessage.companion.user(prompt: "新输入"), at: 0)
        _ = project(.toolResultAppended)
        XCTAssertEqual(requested.count, 61, "消息结构变化必须重新计算全部操作索引")
        cache.reset()
        _ = project(.conversationSwitched)
        XCTAssertEqual(requested.count, 61, "切换会话不得复用旧快照")
        let backfilled = messages[20]
        messages[20] = UIMessage(id: backfilled.id, role: backfilled.role, parts: [tool],
            annotations: [], createdAt: backfilled.createdAt, finishedAt: backfilled.finishedAt,
            modelId: nil, usage: nil, translation: nil)
        let tail = messages.last!
        messages[messages.count - 1] = UIMessage(id: tail.id, role: tail.role,
            parts: [UIMessagePart.Text(text: "回填后继续流式输出", metadata: nil)],
            annotations: [], createdAt: tail.createdAt, finishedAt: nil,
            modelId: nil, usage: nil, translation: nil)
        let coalesced = project(.assistantStreamDelta)
        XCTAssertEqual(requested.count, 61, "历史回填与尾行 delta 合并时必须退出仅尾行快路径")
        XCTAssertTrue(coalesced.messageEntry(for: ChatMessageProjector.messageId(for: backfilled))?.message === messages[20])
        let hidden = IosMailboxMessageBridge.shared.makeMessage(
            authorThreadId: "/root/reviewer", type: "MESSAGE", payload: "内部进展")
        messages.insert(hidden, at: 40)
        let withHiddenMessage = project(.toolResultAppended)
        XCTAssertNil(withHiddenMessage.messageEntry(for: ChatMessageProjector.messageId(for: hidden)))
        (hidden.parts[0] as! UIMessagePart.Text).metadata = nil
        let withVisibleMessage = project(.toolResultAppended)
        XCTAssertNotNil(withVisibleMessage.messageEntry(for: ChatMessageProjector.messageId(for: hidden)),
            "metadata 改变可见性时，不能因 UIMessage 身份未变而漏掉新行")
        XCTAssertEqual(requested.count, 62)
    }

    func testHistoryWindowPreservesAbsoluteIndicesCompactionAndStreamingTail() throws {
        let messages = (0..<451).map { UIMessage.companion.assistant(prompt: "历史消息 \($0)") }
        let boundary = ChatContextCompactBoundary(
            id: "window-compact",
            afterMessageId: ChatMessageProjector.messageId(for: messages[420]),
            coveredMessageIds: [ChatMessageProjector.messageId(for: messages[0])],
            state: ChatContextCompactState(status: .completed, summary: "历史摘要", updatedAt: Date())
        )
        var projectedIndices: [Int] = []
        let initial = NativeTimelineProjector.build(
            messages: messages,
            event: .assistantStreamDelta,
            contextCompactBoundaries: [boundary],
            variantInfoProvider: { index in
                projectedIndices.append(index)
                return nil
            },
            startIndex: 391
        )
        XCTAssertEqual(projectedIndices, Array(391..<451), "首屏只为窗口内消息生成行模型，仍使用原始索引")
        let first = try XCTUnwrap(initial.entries.first { $0.kind == .message })
        XCTAssertEqual(first.index, 391)
        XCTAssertTrue(first.isAssistantContinuation)
        XCTAssertTrue(first.isCompactedHistory, "压缩范围必须包含窗口外的已覆盖消息")
        XCTAssertTrue(initial.entries.contains { $0.id == "context-compact-window-compact" })
        let tail = try XCTUnwrap(initial.entries.last { $0.kind == .message })
        XCTAssertEqual(tail.index, 450)
        XCTAssertTrue(tail.isLastMessage)
        XCTAssertTrue(tail.isStreaming)
        XCTAssertFalse(tail.isCompactedHistory)
        XCTAssertEqual(initial.entries.last?.id, ChatLayout.bottomAnchorID)

        let expanded = NativeTimelineProjector.build(
            messages: messages, event: .assistantStreamDelta,
            contextCompactBoundaries: [boundary], startIndex: 331
        )
        XCTAssertEqual(expanded.entries.filter { $0.kind == .message }.count, 120)
        XCTAssertEqual(Array(expanded.entries.suffix(initial.entries.count)), initial.entries,
                       "加载更早消息不改变已显示消息的身份、索引和尾部锚点")
    }

    func testLiveTailModelPublishesAtMostOncePerSignalRevision() {
        let message = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [UIMessagePart.Text(text: "stream", metadata: nil)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
        let renderState = ChatRenderState(
            rendererMode: .streamingMarkdown,
            hasEverStreamed: true,
            liveRenderingEnabled: true,
            frozenMarkdownSnapshot: nil
        )
        let model = ChatLiveTailModel(
            message: message,
            isGenerationActive: true,
            renderState: renderState
        )
        var publishedUpdates = 0
        let cancellable = model.objectWillChange.sink { publishedUpdates += 1 }

        model.update(
            message: message,
            isGenerationActive: true,
            renderState: renderState,
            sourceRevision: 7
        )
        model.update(
            message: message,
            isGenerationActive: true,
            renderState: renderState,
            sourceRevision: 7
        )
        XCTAssertEqual(publishedUpdates, 1)

        model.update(
            message: message,
            isGenerationActive: true,
            renderState: renderState,
            sourceRevision: 8
        )
        XCTAssertEqual(publishedUpdates, 2)
        withExtendedLifetime(cancellable) {}
    }

    func testInitialLoadRowsDoNotAnimateInsertion() {
        let rows = ChatMessageProjector.rows(
            messages: [
                UIMessage.companion.user(prompt: "你好"),
                UIMessage.companion.assistant(prompt: "在。")
            ],
            event: .conversationLoaded
        )

        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(rows[0].canAnimateInsertion)
        XCTAssertFalse(rows[1].canAnimateInsertion)
    }

    func testOnlyLastUserAppendCanAnimateInsertion() {
        let user = UIMessage.companion.user(prompt: "新的问题")
        let rows = ChatMessageProjector.rows(
            messages: [user],
            event: .userMessageAppended
        )

        XCTAssertEqual(rows.first?.messageId, ChatMessageProjector.messageId(for: user))
        XCTAssertTrue(rows.first?.canAnimateInsertion ?? false)
    }

    func testUserAppendQueuesOnlyNewUserRowForInsertionAnimation() {
        let previous = UIMessage.companion.assistant(prompt: "旧回复")
        let user = UIMessage.companion.user(prompt: "新的问题")
        let previousItemID = "message-\(ChatMessageProjector.messageId(for: previous))"
        let rows = ChatMessageProjector.rows(
            messages: [previous, user],
            event: .userMessageAppended
        )

        let animationIDs = ChatInsertionAnimationPolicy.animatedInsertionItemIDs(
            previousItemIDs: [previousItemID],
            rows: rows
        )

        XCTAssertEqual(animationIDs, ["message-\(ChatMessageProjector.messageId(for: user))"])
    }

    func testUserAppendDoesNotQueueAnimationWhenUserItemAlreadyExists() {
        let user = UIMessage.companion.user(prompt: "新的问题")
        let existingItemID = "message-\(ChatMessageProjector.messageId(for: user))"
        let rows = ChatMessageProjector.rows(
            messages: [user],
            event: .userMessageAppended
        )

        let animationIDs = ChatInsertionAnimationPolicy.animatedInsertionItemIDs(
            previousItemIDs: [existingItemID],
            rows: rows
        )

        XCTAssertEqual(animationIDs, [])
    }

    func testBranchChangeDoesNotAnimateUserRows() {
        let rows = ChatMessageProjector.rows(
            messages: [UIMessage.companion.user(prompt: "切分支后的用户消息")],
            event: .branchChanged
        )

        XCTAssertFalse(rows.first?.canAnimateInsertion ?? true)
    }

    func testStreamingFinalReplaceKeepsRowIdentityAndStreamedMemory() {
        let streamed = UIMessage.companion.assistant(prompt: "正在生成")
        let messageId = ChatMessageProjector.messageId(for: streamed)

        let streamingRows = ChatMessageProjector.rows(
            messages: [streamed],
            event: .assistantStreamDelta
        )
        let finalRows = ChatMessageProjector.rows(
            messages: [streamed],
            event: .generationCompleted,
            streamedMessageIDs: [messageId]
        )

        XCTAssertEqual(streamingRows.first?.rowId, finalRows.first?.rowId)
        XCTAssertTrue(streamingRows.first?.isStreaming ?? false)
        XCTAssertTrue(finalRows.first?.hasEverStreamed ?? false)
    }

    func testTimelinePlanAlwaysEndsWithStableBottomAnchor() {
        let plan = ChatTimelinePlanner.build(
            messages: [UIMessage.companion.user(prompt: "你好")],
            event: .userMessageAppended
        )

        XCTAssertEqual(plan.entries.last, .bottomAnchor(id: ChatTimelinePlanner.bottomAnchorID))
    }

    func testTimelinePlanKeepsStreamingRendererAfterGenerationCompletes() {
        let assistant = UIMessage.companion.assistant(prompt: "# 标题\n\n正在生成长内容")
        let messageId = ChatMessageProjector.messageId(for: assistant)

        let streamingPlan = ChatTimelinePlanner.build(
            messages: [assistant],
            event: .assistantStreamDelta
        )
        let completedPlan = ChatTimelinePlanner.build(
            messages: [assistant],
            event: .generationCompleted,
            streamedMessageIDs: [messageId]
        )

        XCTAssertEqual(streamingPlan.messageEntry(for: messageId)?.id, completedPlan.messageEntry(for: messageId)?.id)
        XCTAssertEqual(streamingPlan.messageEntry(for: messageId)?.renderer, .streamingAssistantMarkdown)
        XCTAssertEqual(completedPlan.messageEntry(for: messageId)?.renderer, .streamingAssistantMarkdown)
        XCTAssertFalse(completedPlan.messageEntry(for: messageId)?.isStreaming ?? true)
        XCTAssertTrue(completedPlan.messageEntry(for: messageId)?.hasEverStreamed ?? false)
    }

    func testTimelinePlanUsesStaticRendererForHistoricalAssistantWithoutStreamMemory() {
        let assistant = UIMessage.companion.assistant(prompt: "历史回复")
        let messageId = ChatMessageProjector.messageId(for: assistant)

        let plan = ChatTimelinePlanner.build(
            messages: [assistant],
            event: .conversationLoaded
        )

        XCTAssertEqual(plan.messageEntry(for: messageId)?.renderer, .staticAssistantMarkdown)
    }

    func testTimelineRenderTokenChangesWhenStreamingTextChanges() {
        let short = UIMessage.companion.assistant(prompt: "第一段")
        let longer = UIMessage.companion.assistant(prompt: "第一段，继续追加新的 token")

        let shortPlan = ChatTimelinePlanner.build(messages: [short], event: .assistantStreamDelta)
        let longerPlan = ChatTimelinePlanner.build(messages: [longer], event: .assistantStreamDelta)

        XCTAssertNotEqual(shortPlan.latestRenderToken, longerPlan.latestRenderToken)
    }

    func testMessageIdKeepsDescriptionFormatViaCheapAccessor() {
        // messageId 改用 toHexDashString() 直接访问器;app 内另有少量
        // String(describing: message.id) 站点(MessageBubbleView 身份串、
        // context compaction),两种写法必须逐字等价,否则 ForEach 身份会串线。
        let message = UIMessage.companion.assistant(prompt: "格式 canary")

        XCTAssertEqual(message.id.toHexDashString(), String(describing: message.id))
        XCTAssertEqual(ChatMessageProjector.messageId(for: message), String(describing: message.id))
    }

    func testTimelinePlanCanSkipRenderTokensForNonNativePaths() {
        let assistant = UIMessage.companion.assistant(prompt: "正在生成")

        let skipped = ChatTimelinePlanner.build(
            messages: [assistant],
            event: .assistantStreamDelta,
            includeRenderTokens: false
        )
        let skippedEntries = skipped.entries.compactMap { entry -> ChatTimelineMessageEntry? in
            guard case let .message(messageEntry) = entry else { return nil }
            return messageEntry
        }
        XCTAssertFalse(skippedEntries.isEmpty)
        XCTAssertTrue(skippedEntries.allSatisfy { $0.renderToken.isEmpty })
        XCTAssertTrue(skipped.latestRenderToken.isEmpty)

        // 默认路径(native mirror diff 消费 token)必须保留非空 token。
        let withTokens = ChatTimelinePlanner.build(
            messages: [assistant],
            event: .assistantStreamDelta
        )
        let tokenEntries = withTokens.entries.compactMap { entry -> ChatTimelineMessageEntry? in
            guard case let .message(messageEntry) = entry else { return nil }
            return messageEntry
        }
        XCTAssertTrue(tokenEntries.allSatisfy { !$0.renderToken.isEmpty })
        XCTAssertFalse(withTokens.latestRenderToken.isEmpty)
    }

    func testToolRoundsShareAssistantHeaderUntilNextUserMessage() throws {
        let user = UIMessage.companion.user(prompt: "查一下资料")
        let toolRound = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [UIMessagePart.Tool(
                toolCallId: "search-1",
                toolName: "search_web",
                input: "{}",
                output: [UIMessagePart.Text(text: "检索结果", metadata: nil)],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
        let answer = UIMessage.companion.assistant(prompt: "根据检索结果回答")
        let messages = [user, toolRound, answer]
        let loaded = NativeTimelineProjector.build(messages: messages, event: .conversationLoaded)
        XCTAssertEqual(loaded.entries.filter { $0.kind == .message }.map(\.isAssistantContinuation),
                       [false, false, true])
        XCTAssertEqual(loaded.entries.compactMap(\.messageId), messages.map(ChatMessageProjector.messageId(for:)))

        let streaming = try XCTUnwrap(NativeTimelineProjector.replacingStreamingTail(
            in: loaded,
            messages: messages,
            event: .assistantStreamDelta,
            isGenerationActive: true,
            viewportState: ChatViewportState()
        ))
        XCTAssertTrue(try XCTUnwrap(streaming.entries.last { $0.kind == .message }).isAssistantContinuation)

        let nextTurn = messages + [UIMessage.companion.user(prompt: "继续解释"),
                                   UIMessage.companion.assistant(prompt: "新的回复")]
        let plan = ChatTimelinePlanner.build(messages: nextTurn, event: .conversationLoaded)
        XCTAssertEqual(plan.entries.compactMap { entry -> Bool? in
            guard case let .message(message) = entry else { return nil }
            return message.rowModel.isAssistantContinuation
        }, [false, false, true, false, false])

        let afterDeletion = NativeTimelineProjector.build(messages: [user, answer], event: .branchChanged)
        XCTAssertFalse(try XCTUnwrap(afterDeletion.entries.last { $0.kind == .message }).isAssistantContinuation)
    }

    func testNativeTimelineProjectionMirrorsTimelinePlanIdentityAndDecorations() {
        let user = UIMessage.companion.user(prompt: "问题")
        let assistant = UIMessage.companion.assistant(prompt: "回答")
        let plan = ChatTimelinePlanner.build(
            messages: [user, assistant],
            event: .assistantStreamDelta,
            includePendingAssistant: true
        )
        let projection = NativeTimelineProjector.build(
            messages: [user, assistant],
            event: .assistantStreamDelta,
            includePendingAssistant: true
        )

        XCTAssertEqual(projection.latestRenderToken, plan.latestRenderToken)
        XCTAssertEqual(projection.entries.map(\.id), plan.entries.map(\.id))
        XCTAssertEqual(projection.entries.map(\.kind), [
            .message,
            .message,
            .pendingAssistant,
            .bottomAnchor
        ])
        XCTAssertEqual(projection.entries.last?.id, ChatTimelinePlanner.bottomAnchorID)
    }

    func testNativeTimelineProjectionIncludesEmptyAndConfigurationDecorations() {
        let emptyProjection = NativeTimelineProjector.build(
            messages: [],
            event: .conversationLoaded
        )
        let configurationProjection = NativeTimelineProjector.build(
            messages: [],
            event: .conversationLoaded,
            configurationIssue: .missingAPIKey
        )

        XCTAssertEqual(emptyProjection.entries.map(\.kind), [.emptyState, .bottomAnchor])
        XCTAssertEqual(configurationProjection.entries.map(\.kind), [
            .configurationIssue(compact: false),
            .bottomAnchor
        ])
    }

    func testNativeTimelineProjectionIncludesTailDecorationsBeforeBottomAnchor() {
        let context = ChatContextCompactState(
            status: .compacting,
            summary: "已压缩上下文",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let projection = NativeTimelineProjector.build(
            messages: [UIMessage.companion.assistant(prompt: "回答")],
            event: .conversationLoaded,
            isRecognizingImages: true,
            contextCompactState: context
        )

        XCTAssertEqual(projection.entries.map(\.kind), [
            .message,
            .visionRecognition,
            .contextMarker,
            .bottomAnchor
        ])
    }

    func testCompactBoundaryStaysWithCoveredHistoryWhenConversationContinues() throws {
        let old = UIMessage.companion.user(prompt: "old history")
        let recent = UIMessage.companion.assistant(prompt: "recent answer")
        let new = UIMessage.companion.user(prompt: "continue")
        let oldID = String(describing: old.id)
        let boundary = ChatContextCompactBoundary(
            id: "compact-1", afterMessageId: String(describing: recent.id), coveredMessageIds: [oldID],
            state: ChatContextCompactState(status: .completed, summary: "summary", updatedAt: Date())
        )
        for messages in [[old, recent], [old, recent, new]] {
            let projection = NativeTimelineProjector.build(
                messages: messages, event: .conversationLoaded, contextCompactBoundaries: [boundary]
            )
            XCTAssertEqual(projection.entries[2].id, "context-compact-compact-1")
            XCTAssertEqual(projection.entries[2].compactState?.status, .completed)
            XCTAssertTrue(try XCTUnwrap(projection.messageEntry(for: oldID)).isCompactedHistory)
            XCTAssertTrue(try XCTUnwrap(projection.messageEntry(for: String(describing: recent.id))).isCompactedHistory)
            XCTAssertFalse(projection.messageEntry(for: String(describing: new.id))?.isCompactedHistory ?? false)
            XCTAssertEqual(projection.entries.filter { $0.kind == .contextMarker }.count, 1)
        }
        let switched = NativeTimelineProjector.build(
            messages: [recent, new], event: .branchChanged, contextCompactBoundaries: [boundary]
        )
        XCTAssertFalse(switched.entries.contains { $0.kind == .contextMarker || $0.isCompactedHistory })
    }

    func testNativeTimelineProjectionLeavesWaitingStatusToTopIslandByDefault() {
        let user = UIMessage.companion.user(prompt: "问题")
        let assistant = UIMessage.companion.assistant(prompt: "回答")

        let loadingAfterUser = NativeTimelineProjector.build(
            messages: [user],
            event: .userMessageAppended,
            isLoading: true
        )
        let explicitPendingAfterUser = NativeTimelineProjector.build(
            messages: [user],
            event: .userMessageAppended,
            isLoading: true,
            includePendingAssistant: true
        )
        let generatingAfterAssistant = NativeTimelineProjector.build(
            messages: [assistant],
            event: .assistantStreamDelta,
            isGenerationActive: true
        )

        XCTAssertEqual(loadingAfterUser.entries.map(\.kind), [.message, .bottomAnchor])
        XCTAssertEqual(
            explicitPendingAfterUser.entries.map(\.kind),
            [.message, .pendingAssistant, .bottomAnchor]
        )
        XCTAssertEqual(generatingAfterAssistant.entries.map(\.kind), [.message, .bottomAnchor])
    }

    func testNativeTimelineProjectionPreservesStreamingRendererMemory() {
        let assistant = UIMessage.companion.assistant(prompt: "流式内容")
        let messageId = ChatMessageProjector.messageId(for: assistant)

        let completedProjection = NativeTimelineProjector.build(
            messages: [assistant],
            event: .generationCompleted,
            streamedMessageIDs: [messageId]
        )
        let entry = completedProjection.messageEntry(for: messageId)

        XCTAssertEqual(entry?.kind, .message)
        XCTAssertEqual(entry?.messageId, messageId)
        XCTAssertEqual(entry?.renderer, .streamingAssistantMarkdown)
        XCTAssertFalse(entry?.isStreaming ?? true)
        XCTAssertTrue(entry?.hasEverStreamed ?? false)
    }

    func testNativeTimelineRendererMatrixMatchesTimelinePlanner() {
        let historical = UIMessage.companion.assistant(prompt: "历史回复")
        let streaming = UIMessage.companion.assistant(prompt: "正在生成")
        let completed = UIMessage.companion.assistant(prompt: "刚刚完成")
        let completedId = ChatMessageProjector.messageId(for: completed)
        let cases: [(message: UIMessage, event: ChatEvent, streamedIDs: Set<String>)] = [
            (historical, .conversationLoaded, []),
            (streaming, .assistantStreamDelta, []),
            (completed, .generationCompleted, [completedId])
        ]

        for item in cases {
            let messageId = ChatMessageProjector.messageId(for: item.message)
            let plan = ChatTimelinePlanner.build(
                messages: [item.message],
                event: item.event,
                streamedMessageIDs: item.streamedIDs
            )
            let projection = NativeTimelineProjector.build(
                messages: [item.message],
                event: item.event,
                streamedMessageIDs: item.streamedIDs
            )

            XCTAssertEqual(
                projection.messageEntry(for: messageId)?.renderer,
                plan.messageEntry(for: messageId)?.renderer
            )
            XCTAssertEqual(
                projection.messageEntry(for: messageId)?.hasEverStreamed,
                plan.messageEntry(for: messageId)?.hasEverStreamed
            )
            XCTAssertEqual(
                projection.messageEntry(for: messageId)?.isStreaming,
                plan.messageEntry(for: messageId)?.isStreaming
            )
        }
    }

    func testNativeTimelineProjectionCarriesActiveStreamingTailRendererIdentity() {
        let user = UIMessage.companion.user(prompt: "问题")
        let assistant = UIMessage.companion.assistant(prompt: "正在流式")
        let messageId = ChatMessageProjector.messageId(for: assistant)

        let projection = NativeTimelineProjector.build(
            messages: [user, assistant],
            event: .assistantStreamDelta,
            isGenerationActive: true,
            streamedMessageIDs: [messageId]
        )
        let entry = projection.messageEntry(for: messageId)

        XCTAssertEqual(entry?.renderer, .streamingAssistantMarkdown)
        XCTAssertTrue(entry?.isStreaming ?? false)
        XCTAssertTrue(entry?.hasEverStreamed ?? false)
    }

    func testNativeTimelineProjectionCarriesFullVariantInfoAndRenderDigest() {
        let user = UIMessage.companion.user(prompt: "问题")
        let messageId = ChatMessageProjector.messageId(for: user)
        let projection = NativeTimelineProjector.build(
            messages: [user],
            event: .conversationLoaded,
            displaySettingSignature: "display",
            generativeUiSettingSignature: "generative",
            variantInfoProvider: { index in
                index == 0
                    ? IOSConversationStore.VariantInfo(variantCount: 3, selectedIndex: 1)
                    : nil
            },
            contentHashProvider: { _, _ in 42 }
        )
        let entry = projection.messageEntry(for: messageId)

        XCTAssertEqual(entry?.variantInfo, NativeTimelineVariantInfo(variantCount: 3, selectedIndex: 1))
        XCTAssertEqual(entry?.hasMultipleVariants, true)
        XCTAssertNotNil(entry?.renderDigest)
    }

    func testNativeStaticTimelineViewportPolicyPublishesBottomButtonAndLODState() {
        let shortContent = NativeStaticTimelineViewportPolicy.state(
            distanceToBottom: 0,
            visibleHeight: 800,
            contentHeight: 400,
            hasMessages: true
        )
        XCTAssertTrue(shortContent.isAtBottom)
        XCTAssertFalse(shortContent.isContentScrollable)
        XCTAssertFalse(shortContent.showScrollToBottom)
        XCTAssertFalse(shortContent.followPaused)
        XCTAssertFalse(shortContent.liveRenderingFarFromBottom)

        let awayFromBottom = NativeStaticTimelineViewportPolicy.state(
            distanceToBottom: 950,
            visibleHeight: 800,
            contentHeight: 2_200,
            hasMessages: true
        )
        XCTAssertFalse(awayFromBottom.isAtBottom)
        XCTAssertTrue(awayFromBottom.isContentScrollable)
        XCTAssertTrue(awayFromBottom.showScrollToBottom)
        XCTAssertFalse(awayFromBottom.followPaused)
        XCTAssertTrue(awayFromBottom.liveRenderingFarFromBottom)

        let userDraggingAwayFromBottom = NativeStaticTimelineViewportPolicy.state(
            distanceToBottom: 950,
            visibleHeight: 800,
            contentHeight: 2_200,
            hasMessages: true,
            userInteracting: true
        )
        XCTAssertTrue(userDraggingAwayFromBottom.followPaused)

        let driverPausedAfterDrag = NativeStaticTimelineViewportPolicy.state(
            distanceToBottom: 950,
            visibleHeight: 800,
            contentHeight: 2_200,
            hasMessages: true,
            driverPausedForUser: true
        )
        XCTAssertTrue(driverPausedAfterDrag.followPaused, "手指抬起后的几何帧不能清掉 native driver 持有的历史浏览暂停。")

        let bottomOfScrollableContent = NativeStaticTimelineViewportPolicy.state(
            distanceToBottom: 0,
            visibleHeight: 800,
            contentHeight: 2_200,
            hasMessages: true
        )
        XCTAssertTrue(bottomOfScrollableContent.isAtBottom)
        XCTAssertTrue(bottomOfScrollableContent.isContentScrollable)
        XCTAssertFalse(bottomOfScrollableContent.showScrollToBottom)
        XCTAssertFalse(bottomOfScrollableContent.followPaused)
        XCTAssertFalse(bottomOfScrollableContent.liveRenderingFarFromBottom)
    }

    func testNativeStaticTimelineRendererMemoryKeepsCompletedStreamingAssistant() {
        let user = UIMessage.companion.user(prompt: "问题")
        let assistant = UIMessage.companion.assistant(prompt: "回答")
        let assistantID = ChatMessageProjector.messageId(for: assistant)

        let remembered = NativeStaticTimelineRendererMemory.nextStreamedMessageIDs(
            previous: [],
            event: .generationCompleted,
            messages: [user, assistant]
        )

        XCTAssertEqual(remembered, Set([assistantID]))
    }

    func testNativeTimelineKeepsLiveTailModelAcrossGenerationCompletion() throws {
        let assistant = UIMessage.companion.assistant(prompt: "流式回答")
        let messageID = ChatMessageProjector.messageId(for: assistant)
        let store = ChatRenderStateStore()
        let streamingRow = ChatMessageRowModel(
            rowId: messageID,
            messageId: messageID,
            message: assistant,
            role: MessageRole.assistant,
            parts: assistant.parts,
            index: 0,
            isLast: true,
            isStreaming: true,
            hasEverStreamed: true,
            canAnimateInsertion: false
        )
        let streamingState = store.stateForRow(
            streamingRow,
            isLiveRenderingFarFromBottom: false
        )
        let streamingModel = try XCTUnwrap(store.liveTailModel(
            for: streamingRow,
            renderState: streamingState,
            isGenerationActive: true
        ))
        let completedRow = ChatMessageRowModel(
            rowId: messageID,
            messageId: messageID,
            message: assistant,
            role: MessageRole.assistant,
            parts: assistant.parts,
            index: 0,
            isLast: true,
            isStreaming: false,
            hasEverStreamed: true,
            canAnimateInsertion: false
        )
        let completedState = store.stateForRow(
            completedRow,
            isLiveRenderingFarFromBottom: false
        )

        let completedModel = store.liveTailModel(
            for: completedRow,
            renderState: completedState,
            isGenerationActive: false
        )

        XCTAssertNotNil(completedModel)
        XCTAssertTrue(streamingModel === completedModel)
    }

    func testNativeStaticTimelineRendererMemoryResetsOnConversationBoundary() {
        let assistant = UIMessage.companion.assistant(prompt: "回答")
        let assistantID = ChatMessageProjector.messageId(for: assistant)

        let reset = NativeStaticTimelineRendererMemory.nextStreamedMessageIDs(
            previous: [assistantID],
            event: .conversationLoaded,
            messages: [assistant]
        )

        XCTAssertTrue(reset.isEmpty)
    }

    func testNativeTimelineProjectionUsesSharedRenderStateStoreFreezeLifecycle() {
        let assistant = UIMessage.companion.assistant(prompt: "正在流式生成")
        let messageId = ChatMessageProjector.messageId(for: assistant)
        let streamedIDs: Set<String> = [messageId]
        let liveStore = ChatRenderStateStore()
        let frozenStore = ChatRenderStateStore()
        frozenStore.freeze(messageID: messageId, latestText: "冻结快照")

        let live = NativeTimelineProjector.build(
            messages: [assistant],
            event: .generationCompleted,
            streamedMessageIDs: streamedIDs,
            renderStateStore: liveStore,
            contentHashProvider: { _, _ in 1 }
        )
        let frozen = NativeTimelineProjector.build(
            messages: [assistant],
            event: .generationCompleted,
            streamedMessageIDs: streamedIDs,
            renderStateStore: frozenStore,
            contentHashProvider: { _, _ in 1 }
        )

        XCTAssertNotEqual(
            live.messageEntry(for: messageId)?.renderDigest,
            frozen.messageEntry(for: messageId)?.renderDigest
        )
    }

    func testNativeTimelineFrozenStreamingTailDoesNotRequestContentHash() {
        let assistant = UIMessage.companion.assistant(prompt: "正在流式生成")
        let messageId = ChatMessageProjector.messageId(for: assistant)
        var contentHashCallCount = 0

        let projection = NativeTimelineProjector.build(
            messages: [assistant],
            event: .assistantStreamDelta,
            isGenerationActive: true,
            viewportState: ChatViewportState(liveRenderingFarFromBottom: true),
            streamedMessageIDs: [messageId],
            renderStateStore: ChatRenderStateStore(),
            contentHashProvider: { _, _ in
                contentHashCallCount += 1
                return 1
            }
        )

        XCTAssertEqual(projection.messageEntry(for: messageId)?.renderState?.rendererMode, .frozen)
        XCTAssertEqual(contentHashCallCount, 0)
    }

    func testNativeTimelineProjectionCarriesRenderStateForNativeUIConsumption() {
        let assistant = UIMessage.companion.assistant(prompt: "正在流式生成")
        let messageId = ChatMessageProjector.messageId(for: assistant)
        let store = ChatRenderStateStore()
        store.freeze(messageID: messageId, latestText: "冻结快照")

        let projection = NativeTimelineProjector.build(
            messages: [assistant],
            event: .generationCompleted,
            viewportState: ChatViewportState(liveRenderingFarFromBottom: true),
            streamedMessageIDs: [messageId],
            renderStateStore: store,
            contentHashProvider: { _, _ in 1 }
        )
        let entry = projection.messageEntry(for: messageId)

        XCTAssertEqual(entry?.renderState?.rendererMode, .frozen)
        XCTAssertEqual(entry?.renderHasEverStreamed, true)
        XCTAssertEqual(entry?.liveMarkdownRenderingEnabled, false)
        XCTAssertEqual(entry?.frozenMarkdownSnapshot, "冻结快照")
    }
}
