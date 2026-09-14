import XCTest
import Combine
import SwiftUI
import CoreText
import Shared
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class ChatMessageProjectionTests: XCTestCase {
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

    private final class MeasuredComposerTextView: UITextView {
        var measurements = 0
        var fittedHeight: CGFloat = 80
        override func sizeThatFits(_ size: CGSize) -> CGSize {
            measurements += 1
            return CGSize(width: size.width, height: fittedHeight)
        }
    }
    func testComposerSkipsUnchangedLayoutAndDiscardsStaleHeightAfterSend() async {
        var text = "第一行\n第二行"
        var height: CGFloat = 40
        var publishedHeights: [CGFloat] = []
        let controller = ComposerInputController()
        let composer = ComposerInputTextView(
            text: Binding(get: { text }, set: { text = $0 }),
            height: Binding(get: { height }, set: { height = $0; publishedHeights.append($0) }),
            isFocused: .constant(false), isEnabled: true, sendOnEnter: true,
            controller: controller, onSubmit: {})
        let coordinator = composer.makeCoordinator()
        let view = MeasuredComposerTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 40))
        view.font = .systemFont(ofSize: 17)
        view.text = text
        controller.textView = view
        coordinator.updateHeight(for: view)
        for _ in 0..<20 { coordinator.updateHeight(for: view) }
        XCTAssertEqual(view.measurements, 1, "工具消息更新不能反复测量未变化的输入框")
        view.text = ""
        view.fittedHeight = 40
        coordinator.updateHeight(for: view)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(publishedHeights.isEmpty, "发送清空后，排队的旧多行高度不能再发布")
        XCTAssertEqual(height, 40)
        view.frame.size.width = 260
        coordinator.updateHeight(for: view)
        view.font = .systemFont(ofSize: 24)
        coordinator.updateHeight(for: view)
        XCTAssertEqual(view.measurements, 4, "宽度和字体变化仍要重新测量")
    }

    private final class VisibilityProbeModel: ObservableObject {
        @Published var active = true
        var creations = 0
    }
    private struct VisibilityProbe: UIViewRepresentable {
        let model: VisibilityProbeModel
        func makeUIView(context: Context) -> UIView {
            model.creations += 1
            return UIView()
        }
        func updateUIView(_ view: UIView, context: Context) {}
    }
    private struct VisibilityProbeHarness: View {
        @ObservedObject var model: VisibilityProbeModel
        var body: some View {
            VisibilityProbe(model: model)
                .frame(height: 40)
                .modifier(ChatSwiftUIStreamingTailVisibilityModifier(
                    active: model.active, assumeVisible: true, onVisibilityChanged: { _ in }))
        }
    }
    func testAssistantBecomingHistoryPreservesItsHostedView() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let model = VisibilityProbeModel()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: VisibilityProbeHarness(model: model))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.creations, 1)
        for active in [false, true, false] {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { model.active = active }
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            XCTAssertEqual(model.creations, 1, "发送新消息或尾行恢复不能重建历史工具和 Markdown 子树")
        }
    }

    func testAgentResultsUseStaticAgentCardsWhileInternalProgressStaysOutOfTimeline() throws {
        let user = UIMessage.companion.user(prompt: "继续当前任务")
        let answer = UIMessage.companion.assistant(prompt: "正在整理")
        let result = IosMailboxMessageBridge.shared.makeMessage(
            authorThreadId: "/root/test_alpha", type: "FINAL_ANSWER", payload: "子代理结果"
        )
        let message = IosMailboxMessageBridge.shared.makeMessage(
            authorThreadId: "/root/test_beta", type: "MESSAGE", payload: "内部进展"
        )
        let before = NativeTimelineProjector.build(messages: [user, answer], event: .toolResultAppended)
        let hiddenProgress = NativeTimelineProjector.build(messages: [user, answer, message], event: .toolResultAppended)
        XCTAssertEqual(hiddenProgress, before, "内部进展不改变可见尾行与布局 token")
        let after = NativeTimelineProjector.build(messages: [user, answer, result, message], event: .toolResultAppended)
        let card = try XCTUnwrap(after.entries.last { $0.kind == .message })
        XCTAssertEqual(card.role, MessageRole.assistant)
        XCTAssertEqual(card.message?.role, MessageRole.user, "模型输入与持久化协议不变")
        XCTAssertEqual(card.renderer, .staticAssistantMarkdown)
        XCTAssertFalse(card.isStreaming)
        XCTAssertTrue(card.canAnimateInsertion)
        XCTAssertEqual(card.index, 2)
        XCTAssertEqual([user, answer, result, message].last(where: ChatMessageProjector.isConversationMessage)?.id, answer.id)
        XCTAssertEqual(result.toText(), "[mailbox FINAL_ANSWER from /root/test_alpha]\n子代理结果")

        let continuation = UIMessage.companion.assistant(prompt: "整理后的回答")
        let messages = [user, answer, result, message, continuation]
        let projected = NativeTimelineProjector.build(messages: messages, event: .assistantStreamDelta)
        let tail = try XCTUnwrap(projected.entries.last { $0.kind == .message })
        XCTAssertEqual(tail.index, 4, "操作与分支索引仍指向完整会话")
        XCTAssertFalse(tail.isAssistantContinuation, "独立子代理结果卡与主代理正文保持各自标题")
        let fastPath = try XCTUnwrap(NativeTimelineProjector.replacingStreamingTail(
            in: projected, messages: messages, event: .assistantStreamDelta,
            isGenerationActive: true, viewportState: ChatViewportState()
        ))
        XCTAssertFalse(try XCTUnwrap(fastPath.entries.last { $0.kind == .message }).isAssistantContinuation)
    }

    func testTaskInstructionsAndOrdinaryUserTextRemainVisible() {
        let task = IosMailboxMessageBridge.shared.makeMessage(
            authorThreadId: "/root", type: "NEW_TASK", payload: "追加核查"
        )
        let literal = UIMessage.companion.user(prompt: "[mailbox FINAL_ANSWER from /root/test]\n我输入的文字")
        let rows = ChatMessageProjector.rows(messages: [task, literal], event: .conversationLoaded)
        XCTAssertEqual(rows.map(\.index), [0, 1])
    }

    func testSubAgentResultCardVisualLayout() async throws {
        let report = "## 适合并行的任务\n\n- **独立推进**：几个任务互不依赖。\n- **交叉核查**：从不同角度验证同一结论。\n\n> 完成后由主代理整理结果。\n\n`TEST_ALPHA_OK`"
        let message = IosMailboxMessageBridge.shared.makeMessage(
            authorThreadId: "/root/test_alpha", type: "FINAL_ANSWER",
            payload: report
        )
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        for (name, width, type, expanded) in [
            ("subagent-result-glass-393", CGFloat(393), DynamicTypeSize.large, false),
            ("subagent-result-glass-320", CGFloat(320), DynamicTypeSize.large, false),
            ("subagent-result-glass-accessibility", CGFloat(393), DynamicTypeSize.accessibility3, false),
            ("subagent-result-expanded-393", CGFloat(393), DynamicTypeSize.large, true)
        ] {
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView:
                ScrollView {
                    Group {
                        if expanded {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("普通助手正文")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AmberTheme.muted)
                                MessageBubbleView(
                                    message: UIMessage.companion.assistant(prompt: report)
                                )
                                Text("展开子代理结果")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AmberTheme.muted)
                                ChatSubAgentResultCard(
                                    sender: "/root/test_alpha",
                                    displayText: report,
                                    initiallyExpanded: true
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            MessageBubbleView(message: message)
                        }
                    }
                    .padding(16)
                }
                .background(AmberTheme.background)
                .environment(IOSWorkspaceStore())
                .environment(\.dynamicTypeSize, type)
                .environment(\.locale, Locale(identifier: "zh_Hans"))
            )
            window.frame = CGRect(x: 0, y: 0, width: width, height: 852)
            window.rootViewController = host
            window.overrideUserInterfaceStyle = .light
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKey()
            }
            try await Task.sleep(for: .milliseconds(600))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
            try XCTUnwrap(image.pngData()).write(to: output)
            print("SUBAGENT_RESULT_EVIDENCE \(output.path)")
        }
    }

    func testSubAgentResultCardHugsShortContentAndBoundsLongMarkdown() {
        func measured(_ text: String, width: CGFloat, expanded: Bool = true) -> CGSize {
            let host = UIHostingController(rootView: ChatSubAgentResultCard(
                sender: "/root/worker", displayText: text, initiallyExpanded: expanded
            ))
            return host.sizeThatFits(in: CGSize(width: width, height: 10_000))
        }
        let short = measured("已核对。", width: 361)
        let longText = "## 核查结果\n\n" + String(repeating: "结果包含说明和证据，需要在卡片内自然换行。", count: 12)
        let long = measured(longText, width: 361)
        let narrow = measured(longText, width: 288)
        let collapsed = measured(longText, width: 361, expanded: false)
        XCTAssertEqual(short.width, 361, accuracy: 0.5, "展开短结果使用聊天正文的可用全宽")
        XCTAssertEqual(long.width, 361, accuracy: 0.5, "展开结果使用聊天正文的可用全宽")
        XCTAssertEqual(narrow.width, 288, accuracy: 0.5, "窄屏展开结果仍使用父级可用宽度")
        XCTAssertLessThan(collapsed.width, long.width, "收起后只保留紧凑标题宽度")
        XCTAssertEqual(collapsed.height, 44, accuracy: 0.5)
        XCTAssertGreaterThan(long.height, short.height)
        XCTAssertGreaterThan(narrow.height, long.height)
    }

    func testResultCardBoundsUnbrokenMarkdownAndAccessibilityNames() {
        let token = String(repeating: "W", count: 160)
        let cases = [
            "https://example.com/" + token,
            "```text\n" + token + "\n```",
            "| Column | Column | Column | Column |\n|---|---|---|---|\n| " + Array(repeating: token, count: 4).joined(separator: " | ") + " |"
        ]
        for width: CGFloat in [288, 361] {
            for type: DynamicTypeSize in [.large, .accessibility3] {
                for (index, text) in cases.enumerated() {
                    let host = UIHostingController(rootView: ChatSubAgentResultCard(
                        sender: "/root/" + token, displayText: text, initiallyExpanded: true
                    ).environment(\.dynamicTypeSize, type))
                    let size = host.sizeThatFits(in: CGSize(width: width, height: 10_000))
                    XCTAssertLessThanOrEqual(size.width, width + 0.5,
                        "case \(index), width \(width), type \(type)")
                    XCTAssertTrue(size.height.isFinite)
                }
            }
        }
    }

    func testResultCardStartsCollapsedAndLongResultsDoNotGrowTheRow() {
        func height(_ text: String) -> CGFloat {
            let host = UIHostingController(rootView: ChatSubAgentResultCard(sender: "/root/nora", displayText: text))
            return host.sizeThatFits(in: CGSize(width: 288, height: 10_000)).height
        }
        let short = height("已完成任务")
        let long = height(String(repeating: "## 已收集网页内容\n\n详细内容需要用户主动展开查看。\n", count: 200))
        XCTAssertEqual(short, 44, accuracy: 0.5)
        XCTAssertEqual(long, short, accuracy: 0.5, "长结果到达时不得自动展开正文")
        XCTAssertEqual(ChatSubAgentResultCard.compactSummary("## 已收集网页内容\n\n详细报告"), "已收集网页内容")
        XCTAssertEqual(ChatSubAgentResultCard.compactSummary("执行失败"), "执行失败")
        for text in ["", "## 这是一段很长的任务结论不能全放在标题里", "**已完成任务**", "👨‍👩‍👧‍👦 已完成"] {
            XCTAssertLessThanOrEqual(ChatSubAgentResultCard.compactSummary(text).count, 7)
        }
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

    func testNativeCompactTimelineVisualLayout() async throws {
        let old = UIMessage.companion.user(prompt: "这部分历史已压缩")
        let recent = UIMessage.companion.assistant(prompt: "继续对话，新的内容显示在分界线下方。")
        let oldID = String(describing: old.id)
        let boundary = ChatContextCompactBoundary(
            id: "visual", afterMessageId: oldID, coveredMessageIds: [oldID],
            state: ChatContextCompactState(
                status: .completed,
                summary: "完成态摘要不应在分隔线下重复显示",
                updatedAt: Date()
            )
        )
        let defaults = UserDefaults(suiteName: "CompactVisual-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let view = NativeChatTimelineView(
            signal: ChatMessageUpdateSignal(), configurationIssue: nil, isGenerationActive: false,
            isLoading: false, isRecognizingImages: false,
            contextCompactState: ChatContextCompactState(status: .compacting, summary: "", updatedAt: Date()),
            contextCompactBoundaries: [boundary], followGeneration: false,
            displaySetting: settings.displaySetting, generativeUiSetting: settings.agentRuntime.generativeUi,
            reasoningLevelLabel: nil, workspaceStore: IOSWorkspaceStore(), scrollToBottomTrigger: 0,
            scrollToBottomSource: .button, messageAnchor: nil, currentConversationID: "compact-visual",
            messagesProvider: { [old, recent] }, variantInfoProvider: { _ in nil },
            onAction: { _ in }, onViewportStateChange: { _ in }, onDismissKeyboard: {}
        )
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        window.backgroundColor = .systemBackground
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 200_000_000)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "compact-native-timeline"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(host.view.bounds.width, 390)
    }

    private func source(_ relativePath: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let iosAppRoot = testsDir.deletingLastPathComponent()
        return try String(
            contentsOf: iosAppRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
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

    func testFrozenMarkdownSnapshotUsesTheSingleNonEmptyTextPartVerbatim() {
        let messageID = KotlinUuid.companion.random()
        let message = UIMessage(
            id: messageID,
            role: MessageRole.assistant,
            parts: [
                UIMessagePart.Text(text: "", metadata: nil),
                UIMessagePart.Text(text: "正文", metadata: nil),
            ],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )

        XCTAssertEqual(message.singleNonEmptyTextPart, "正文")

        let multipleTextParts = UIMessage(
            id: messageID,
            role: MessageRole.assistant,
            parts: [
                UIMessagePart.Text(text: "第一段", metadata: nil),
                UIMessagePart.Text(text: "第二段", metadata: nil),
            ],
            annotations: [],
            createdAt: message.createdAt,
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
        XCTAssertNil(multipleTextParts.singleNonEmptyTextPart)
    }

    func testPackedAstReaderParsesBlockMathNode() throws {
        let markdown = "$$E=mc^2$$"
        let node = try XCTUnwrap(Self.firstNode(ofType: .mathBlock, in: Self.astNodes(for: markdown)))

        XCTAssertEqual(Self.slice(markdown, node: node), "$$E=mc^2$$")
    }

    func testBlockMathLatexExtraction() throws {
        let inline = try XCTUnwrap(Self.firstNode(ofType: .mathBlock, in: Self.astNodes(for: "$$E=mc^2$$")))
        XCTAssertEqual(AmberMarkdownMath.blockLatex(from: inline, source: "$$E=mc^2$$"), "E=mc^2")

        let multilineMarkdown = """
        $$
          a^2 + b^2 = c^2
        $$
        """
        let multiline = try XCTUnwrap(Self.firstNode(ofType: .mathBlock, in: Self.astNodes(for: multilineMarkdown)))
        XCTAssertEqual(AmberMarkdownMath.blockLatex(from: multiline, source: multilineMarkdown), "a^2 + b^2 = c^2")
    }

    func testKnownGap_B3b_inlineMathRendersAsLiteralText() throws {
        // B3b 实现时本测试应转红并被替换为真渲染断言；设计见 IOS_FIX_PLAN_2026-07-08.md B3b。
        let markdown = "inline $x^2$ math"
        let node = try XCTUnwrap(Self.firstNode(ofType: .mathInline, in: Self.astNodes(for: markdown)))

        XCTAssertEqual(Self.slice(markdown, node: node), "$x^2$")
    }

    func testToolStepModelMarksStructuredFailureOutputAsFailed() {
        let tool = UIMessagePart.Tool(
            toolCallId: "search-denied",
            toolName: "search_web",
            input: #"{"query":"swift"}"#,
            output: [
                UIMessagePart.Text(
                    text: #"{"ok":false,"denied":true,"reason":"用户拒绝搜索。","tool":"search_web"}"#,
                    metadata: nil
                )
            ],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )

        let model = ChatToolStepModel(tool: tool)

        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(model.detail, "用户拒绝搜索。")
    }

    func testRemoteTerminalStepDistinguishesTimeoutAndCancellation() {
        func model(status: String) -> ChatToolStepModel {
            ChatToolStepModel(tool: UIMessagePart.Tool(
                toolCallId: status,
                toolName: "terminal_execute",
                input: #"{"command":"sleep 10"}"#,
                output: [
                    UIMessagePart.Text(
                        text: #"{"ok":false,"status":"\#(status)","error":"stopped"}"#,
                        metadata: nil
                    )
                ],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            ))
        }

        let timedOut = model(status: IOSTerminalJobStatus.timedOut.rawValue)
        XCTAssertEqual(timedOut.title, "Remote SSH 执行")
        XCTAssertEqual(timedOut.detail, IOSAppLocalization.string("已超时", defaultValue: "已超时"))
        XCTAssertEqual(timedOut.state, .failed)

        let cancelled = model(status: IOSTerminalJobStatus.cancelled.rawValue)
        XCTAssertEqual(cancelled.title, "Remote SSH 执行")
        XCTAssertEqual(cancelled.detail, IOSAppLocalization.string("已取消", defaultValue: "已取消"))
        XCTAssertEqual(cancelled.state, .cancelled)
    }

    func testEmbeddedTerminalJobLaunchRemainsActiveWithoutFakeExitCode() {
        let model = ChatToolStepModel(tool: UIMessagePart.Tool(
            toolCallId: "ish-job-running",
            toolName: "ios_ish_execute",
            input: #"{"command":"sleep 10","background":true}"#,
            output: [
                UIMessagePart.Text(
                    text: #"{"ok":true,"background":true,"status":"running","runtime":"ish_experimental","job_id":"job-1"}"#,
                    metadata: nil
                )
            ],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        ))

        XCTAssertEqual(model.title, "内置 iSH 执行")
        XCTAssertEqual(model.detail, IOSAppLocalization.string("运行中", defaultValue: "运行中"))
        XCTAssertEqual(model.state, .active)
    }

    func testEmbeddedTerminalCancellationUsesNeutralStateAndTitle() {
        let model = ChatToolStepModel(tool: UIMessagePart.Tool(
            toolCallId: "ish-cancelled",
            toolName: "ios_ish_execute",
            input: #"{"command":"sleep 10"}"#,
            output: [
                UIMessagePart.Text(
                    text: #"{"ok":false,"status":"cancelled","error":"stopped"}"#,
                    metadata: nil
                )
            ],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        ))

        XCTAssertEqual(model.title, "内置 iSH 执行")
        XCTAssertEqual(model.detail, IOSAppLocalization.string("已取消", defaultValue: "已取消"))
        XCTAssertEqual(model.state, .cancelled)
    }

    func testChatMarkdownOpenURLPolicyAllowsOnlyWebAndMailtoSchemes() throws {
        XCTAssertTrue(ChatMarkdownOpenURLPolicy.isAllowed(try XCTUnwrap(URL(string: "https://example.com/a"))))
        XCTAssertTrue(ChatMarkdownOpenURLPolicy.isAllowed(try XCTUnwrap(URL(string: "http://example.com/a"))))
        XCTAssertTrue(ChatMarkdownOpenURLPolicy.isAllowed(try XCTUnwrap(URL(string: "mailto:hello@example.com"))))

        XCTAssertFalse(ChatMarkdownOpenURLPolicy.isAllowed(try XCTUnwrap(URL(string: "shortcuts://run-shortcut?name=bad"))))
        XCTAssertFalse(ChatMarkdownOpenURLPolicy.isAllowed(try XCTUnwrap(URL(string: "file:///private/var/mobile/Library/foo"))))
        XCTAssertFalse(ChatMarkdownOpenURLPolicy.isAllowed(try XCTUnwrap(URL(string: "javascript:alert(1)"))))
    }

    func testInvalidDataImageURLResolvesToFailure() async {
        guard case .failure = await ChatDataImageLoadState.resolve(
            urlString: "data:image/jpeg;base64,this-is-not-base64"
        ) else {
            return XCTFail("损坏的 data URL 必须结束 loading 并进入失败态")
        }
    }

    func testGeneratedImageLoadingShowsOnePlaceholderPerRequestedImage() throws {
        let bubble = try source("iosApp/MessageBubbleView.swift")

        XCTAssertTrue(bubble.contains("ForEach(0..<display.requestedCount"))
    }

    func testThinkingFallbackWaitsForVisibleAssistantText() throws {
        let bubble = try source("iosApp/MessageBubbleView.swift")
        let start = try XCTUnwrap(bubble.range(of: "private var hasVisibleAssistantContent"))
        let end = try XCTUnwrap(
            bubble.range(of: "private var nonEmptyTextPartCount", range: start.upperBound..<bubble.endIndex)
        )
        let visibility = bubble[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(visibility.contains("text.text.contains { !$0.isWhitespace }"))
        XCTAssertFalse(visibility.contains("return !text.text.isEmpty"))
    }

    func testToolDetailSelectionKeepsStableIdentityAndResolvesCurrentMessageOutput() throws {
        let bubble = try source("iosApp/MessageBubbleView.swift")
        let detail = try source("iosApp/ChatToolDetailSheet.swift")

        XCTAssertTrue(detail.contains("let toolCallId: String"))
        XCTAssertFalse(detail.contains("let id = UUID()"))
        XCTAssertTrue(bubble.contains("toolPart(toolCallId: target.toolCallId)"))
    }

    func testToolDetailLongReceiptWrapsWithinSheetWidth() throws {
        let detail = try source("iosApp/ChatToolDetailSheet.swift")
        let renderedTextStart = try XCTUnwrap(detail.range(of: "private var renderedText"))
        let byteCountStart = try XCTUnwrap(
            detail.range(of: "private var byteCountText", range: renderedTextStart.upperBound..<detail.endIndex)
        )
        let renderedText = detail[renderedTextStart.lowerBound..<byteCountStart.lowerBound]

        XCTAssertTrue(renderedText.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertTrue(renderedText.contains(".fixedSize(horizontal: false, vertical: true)"))
    }

    func testNativeTimelineSessionIdentityChangesAcrossConversations() {
        let first = KotlinUuid.companion.random()
        let second = KotlinUuid.companion.random()

        XCTAssertNotEqual(
            NativeChatTimelineSessionIdentity.viewID(conversationId: first),
            NativeChatTimelineSessionIdentity.viewID(conversationId: second)
        )
    }

    func testTableCellFadeInPolicyDoesNotDisableVisibleAnimationForLargeTables() {
        XCTAssertTrue(
            TableViewAnimationPolicy.shouldAnimateCellText(
                configShouldAnimateText: true,
                headingCount: 4,
                rowCount: 8,
                characterCount: 120
            )
        )
    }

    func testTableStreamingThrottleTiersOnlySlowDownHugeTables() {
        // 直播解析限频档位不变（对大表降频止血）；表格尾块发布间隔改为
        // 连续曲线（0.09 + 0.13×(1−e^(−L/4000))，2026-08-15 取代四档）：
        // 锚点行为等价（与旧档偏差 <12ms），但无档位边界断点。
        let live = ChatStreamingMarkdownThrottleTestSupport.liveParseInterval
        XCTAssertEqual(live(800, true), 0.12)
        XCTAssertEqual(live(3_000, true), 0.20)
        XCTAssertEqual(live(10_000, true), 0.32)
        XCTAssertEqual(live(24_000, true), 0.5)
        XCTAssertEqual(live(24_000, false), 0, "普通文本不在此加独立定时门")

        let publish = ChatStreamingMarkdownThrottleTestSupport.blockPublishInterval
        XCTAssertEqual(publish(800, true), 0.09 + 0.13 * (1 - exp(-800.0 / 4_000)), accuracy: 0.0005)
        XCTAssertEqual(publish(3_000, true), 0.09 + 0.13 * (1 - exp(-3_000.0 / 4_000)), accuracy: 0.0005)
        XCTAssertEqual(publish(10_000, true), 0.09 + 0.13 * (1 - exp(-10_000.0 / 4_000)), accuracy: 0.0005)
        XCTAssertEqual(publish(24_000, true), 0.09 + 0.13 * (1 - exp(-24_000.0 / 4_000)), accuracy: 0.0005)
        XCTAssertEqual(publish(24_000, false), 0)
        // 连续性契约：旧档位边界（1.2k/4k/12k）两侧的间隔差 <1ms，无档位跳变。
        let belowBoundary = publish(1_200, true)
        let aboveBoundary = publish(1_201, true)
        XCTAssertLessThan(abs(belowBoundary - aboveBoundary), 0.001)
    }

    func testStreamingMarkdownConfigCacheKeyTracksPaperAndAccent() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testDirectory.deletingLastPathComponent()
                .appendingPathComponent("iosApp/MessageBubbleView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("let themePaper: String"))
        XCTAssertTrue(source.contains("let themeAccentHex: UInt32"))
        XCTAssertTrue(source.contains("themePaper: AmberThemeRuntime.shared.paper.rawValue"))
        XCTAssertTrue(source.contains("themeAccentHex: AmberThemeRuntime.shared.accentHex"))
        XCTAssertEqual(
            ChatStreamingMarkdownConfigCacheTestSupport.buildCount(themeKeys: [
                (paper: "paper", accentHex: 0xB8623A),
                (paper: "paper", accentHex: 0xB8623A),
                (paper: "neutral", accentHex: 0xB8623A),
                (paper: "neutral", accentHex: 0x5E9C6E),
            ]),
            3,
            "相同主题必须命中缓存，paper/accent 任一变化必须重建 config"
        )
    }

    func testStreamingBlockParserKeepsHeadingContextInOneMarkdownDocument() {
        let markdown = """
        [文档][reference]

        # 标题

        [reference]: https://example.com

        <script>
        # 这不是 Markdown 标题
        </script>
        """

        let blocks = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: markdown,
            includeTrailingPartialTableRow: true
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, "text")
        XCTAssertEqual(blocks.first?.text, markdown)
    }

    func testStreamingBlockParserKeepsPartialHashAppendInOneTextBlock() {
        let prefix = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: "正文\n\n#",
            includeTrailingPartialTableRow: false
        )
        let completed = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: "正文\n\n#tag",
            includeTrailingPartialTableRow: false
        )

        XCTAssertEqual(prefix.count, 1)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(prefix.first?.kind, "text")
        XCTAssertEqual(completed.first?.kind, "text")
    }

    func testTextKit1LongParagraphMeasuresEachAppendAtLineGranularity() {
        let width: CGFloat = 337.3
        let view = ParagraphUIView.makeTextKit1View()
        view.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        XCTAssertTrue(view.usesTextKit1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 17),
            .foregroundColor: UIColor.label
        ]
        var text = "连续正文开始。" + String(
            repeating: "这是一段没有空行分隔的长篇连续正文，用来复现真实回答累计变长后同一段落仍在增长的布局压力。",
            count: 180
        )
        func contents() -> NSMutableAttributedString {
            NSMutableAttributedString(string: text, attributes: attributes)
        }

        view.setParagraphContents(contents(), lineSpacing: 4, animatedByWord: false)
        var measuredHeight = view.sizeThatFits(CGSize(
            width: width,
            height: .greatestFiniteMagnitude
        )).height
        view.frame.size.height = measuredHeight
        var positiveGrowth: [CGFloat] = []

        for _ in 0..<60 {
            text += String(repeating: "流", count: 12)
            view.setParagraphContents(contents(), lineSpacing: 4, animatedByWord: false)
            let nextHeight = view.sizeThatFits(CGSize(
                width: width,
                height: .greatestFiniteMagnitude
            )).height
            if nextHeight > measuredHeight + 0.5 {
                positiveGrowth.append(nextHeight - measuredHeight)
            }
            measuredHeight = nextHeight
            view.frame.size.height = nextHeight
        }

        XCTAssertGreaterThanOrEqual(positiveGrowth.count, 30)
        XCTAssertLessThanOrEqual(positiveGrowth.max() ?? .greatestFiniteMagnitude, 26)
    }

    func testStreamingTableParserDoesNotLeakTrimmedTrailingRowAsPipeText() {
        let markdown = """
        | 阶段 | 能力 |
        | --- | --- |
        | 初觉 | 雷感 |
        | 一劫雷 | 掌心
        """

        let blocks = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: markdown,
            includeTrailingPartialTableRow: false
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, "table")
        // 行为契约变更（2026-08-15）：含管道的尾行流式期立即渲染为部分行，
        // 不再「只消费不渲染」——完成瞬间尾行成批出现即「完成后排版重排」。
        XCTAssertEqual(blocks.first?.rows, [["初觉", "雷感"], ["一劫雷", "掌心"]])
        XCTAssertFalse(blocks.contains { $0.kind == "text" && $0.text.contains("|") })
    }

    func testStreamingTableParserKeepsSinglePartialRowAsEmptyTableBlock() {
        let markdown = """
        | 层次 | 说明 |
        | --- | --- |
        | 人间界 | 现代都市
        """

        let blocks = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: markdown,
            includeTrailingPartialTableRow: false
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, "table")
        XCTAssertEqual(blocks.first?.headers, ["层次", "说明"])
        // 行为契约变更（2026-08-15）：含管道的尾行流式期立即渲染为部分行，
        // 不再「只消费不渲染」——完成瞬间尾行成批出现即「完成后排版重排」。
        XCTAssertEqual(blocks.first?.rows, [["人间界", "现代都市"]])
        XCTAssertFalse(blocks.contains { $0.kind == "text" && $0.text.contains("|") })
    }

    func testStreamingTableParserHidesNoLeadingPipePartialRow() {
        let markdown = """
        名称 | 数值
        --- | ---
        Alpha | 1
        Bet
        """

        let blocks = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: markdown,
            includeTrailingPartialTableRow: false
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, "table")
        XCTAssertEqual(blocks.first?.rows, [["Alpha", "1"]])
    }

    func testStreamingTableDetectorMatchesAcceptedSyntaxAndIgnoresFences() {
        XCTAssertTrue(ChatStreamingMarkdownBlockParserTestSupport.containsTable(in: """
        名称 | 数值
        --- | ---
        Alpha | 1
        """))
        XCTAssertFalse(ChatStreamingMarkdownBlockParserTestSupport.containsTable(in: """
        ~~~markdown
        ```not-a-closing-fence
        | 名称 | 数值 |
        | --- | --- |
        ~~~
        """))
    }

    func testStreamingTableDetectorConsumesOnlyAppendedUTF8AcrossDeltas() {
        let chunks = [
            "普通文本",
            "继续增长",
            "\n名称 | 数值",
            "\n---",
            " | ---"
        ]
        var text = ""
        let prefixes = chunks.map { chunk -> String in
            text += chunk
            return text
        }

        let result = ChatStreamingTableDetectionTestSupport.replay(prefixes)

        XCTAssertTrue(result.containsTable)
        XCTAssertEqual(result.consumedUTF8Count, text.utf8.count)
    }

    func testIncrementalStreamingTableDetectorKeepsFenceStateAcrossDeltas() {
        let prefixes = [
            "~~~markdown\n",
            "~~~markdown\n| 名称 | 数值 |\n",
            "~~~markdown\n| 名称 | 数值 |\n| --- | --- |"
        ]

        XCTAssertFalse(ChatStreamingTableDetectionTestSupport.replay(prefixes).containsTable)
    }

    func testStreamingTableRowCacheReusesCompletedRowsAcrossDeltas() {
        ChatStreamingMarkdownBlockParserTestSupport.resetRowCache()
        let prefix = """
        | 名称 | 数值 |
        | --- | --- |
        | Alpha | 1 |
        | Beta | 2 |
        """
        _ = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: prefix,
            includeTrailingPartialTableRow: false
        )
        let firstMetrics = ChatStreamingMarkdownBlockParserTestSupport.rowCacheMetrics

        _ = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: prefix + "\n| Gamma | 3",
            includeTrailingPartialTableRow: false
        )
        let secondMetrics = ChatStreamingMarkdownBlockParserTestSupport.rowCacheMetrics

        XCTAssertGreaterThan(firstMetrics.misses, 0)
        XCTAssertGreaterThan(secondMetrics.hits, firstMetrics.hits)
    }

    func testProductionStreamingTableBlocksDoNotMaterializeUnusedCellModels() {
        let markdown = """
        | 名称 | 数值 |
        | --- | --- |
        | Alpha | 1 |
        | Beta | 2 |
        """

        let counts = ChatStreamingMarkdownBlockParserTestSupport.productionTableCellCounts(in: markdown)

        XCTAssertEqual(counts?.headers, 0)
        XCTAssertEqual(counts?.rows, 0)
    }

    func testStreamingTableBlockPreservesEscapedPipeForRealMarkdownRenderer() {
        let markdown = """
        | 表达式 | 含义 |
        | --- | --- |
        | `a \\| b` | escaped pipe |
        """

        let blocks = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: markdown,
            includeTrailingPartialTableRow: true
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, "table")
        XCTAssertEqual(blocks.first?.rows, [["`a | b`", "escaped pipe"]])
        XCTAssertEqual(blocks.first?.markdown, markdown)
    }

    func testStreamingTableBlockUsesVendorMarkdownRendererAndAsyncBlockController() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testDirectory.deletingLastPathComponent()
                .appendingPathComponent("iosApp/MessageBubbleView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("text: table.markdown,"))
        XCTAssertTrue(source.contains("cacheIdentity: renderCacheNamespace.map"))
        XCTAssertTrue(source.contains("private final class ChatStreamingMarkdownBlockController"))
        XCTAssertTrue(source.contains("Task.detached(priority: .userInitiated)"))

        let controllerSource = source
            .components(separatedBy: "private final class ChatStreamingMarkdownBlockController")
            .last?
            .components(separatedBy: "private struct ChatStreamingMarkdownBlock:")
            .first ?? ""
        XCTAssertTrue(controllerSource.contains("publishPreservingSettledBlocks(parsed)"))
        XCTAssertFalse(
            controllerSource.contains("if pendingParse == nil"),
            "Continuous deltas must not starve every completed block parse publication."
        )
    }

    /// 完成切换原子性契约：流式（speculative）条目在完成（非 speculative）
    /// 配置下必须可复用——visualConfigHash 相同即视觉等价，完成态继续显示
    /// 流式渲染产物，直到终态权威解析落地再原子替换（「不换纸」）。
    /// 旧契约（完成态拒绝 speculative 条目）正是真机完成瞬间退回未渲染
    /// markdown 原文闪帧的根因：解析落后的块在 speculative 翻转时无任何
    /// 可服务的格式化 renderable，`ChatStableStreamingMarkdownView` 落到
    /// `RenderableDocument(plainText:)` 兜底。
    func testCompletedMarkdownRenderableCacheReusesSpeculativeStreamingEntry() {
        ChatStableStreamingMarkdownCacheTestSupport.reset()
        let markdown = """
        | 层次 | 说明 |
        | --- | --- |
        | 人间界 |
        """

        ChatStableStreamingMarkdownCacheTestSupport.store(text: markdown, animate: true)

        XCTAssertTrue(
            ChatStableStreamingMarkdownCacheTestSupport.hasCachedRenderable(text: markdown, animate: false),
            "完成切换瞬间必须能复用流式期已格式化的同一文本渲染产物（原子替换前不退回原文）"
        )
    }

    /// 完成切换原子性契约（前缀形态）：完成配置下必须继续复用已格式化的
    /// 前缀渲染，直到终态权威解析落地——否则完成瞬间解析落后的块退回
    /// 未渲染原文闪帧。流式期（animate=true）前缀复用保持原语义。
    func testCompletedMarkdownRenderableCacheUsesPrefixFallbackAcrossSpeculativeFlip() {
        ChatStableStreamingMarkdownCacheTestSupport.reset()
        let prefix = "第一段已经解析"
        let completedText = "\(prefix)\n第二段完成态新增内容"

        ChatStableStreamingMarkdownCacheTestSupport.store(text: prefix, animate: true)

        XCTAssertTrue(
            ChatStableStreamingMarkdownCacheTestSupport.hasCachedRenderable(text: completedText, animate: true)
        )
        XCTAssertTrue(
            ChatStableStreamingMarkdownCacheTestSupport.hasCachedRenderable(text: completedText, animate: false),
            "完成切换瞬间必须持续显示已格式化的前缀渲染（stale-prefix 跨 speculative 翻转），"
                + "不能退回未渲染的 markdown 原文"
        )
    }

    func testIdentityCacheRetainsEnoughCompletedParagraphsToSuppressRemountFade() {
        ChatStableStreamingMarkdownCacheTestSupport.reset()
        // 长篇(小说/长对话)可有上百个段落 block。完成态重挂载/回滚时,只要 identity
        // 缓存还持有该段落的 renderable,resolution 就返回 suppressesInitialFade=true,
        // 不再重新淡入。旧上限 64 会让靠前的段落被后续解析挤出 → 完成瞬间整屏重新淡入
        // (闪烁);提到 256 后,第 0 段在缓存了 100 段之后必须仍可解析。
        let paragraphCount = 100
        for index in 0..<paragraphCount {
            ChatStableStreamingMarkdownCacheTestSupport.storeIdentity(
                identity: "block-\(index)",
                text: "paragraph \(index)",
                animate: false
            )
        }
        XCTAssertTrue(
            ChatStableStreamingMarkdownCacheTestSupport.hasCachedIdentity(
                identity: "block-0",
                text: "paragraph 0",
                animate: false
            ),
            "identity 缓存应至少容纳 100 个完成段落,否则已完成段落被挤出,完成/回滚时重新淡入闪烁。"
        )
    }

    func testStableStreamingMarkdownControllerResumesAnimatedParsingAfterNonAnimatedParseCompletes() async {
        let renderedText = await ChatStableStreamingMarkdownControllerTestSupport
            .renderedTextAfterNonAnimatedThenAnimatedParse()

        XCTAssertEqual(renderedText, "initial completed text with live delta")
    }

    func testStableStreamingMarkdownControllerQueuesAnimatedDeltaDuringNonAnimatedParse() async {
        let renderedText = await ChatStableStreamingMarkdownControllerTestSupport
            .renderedTextWhenAnimatedParseArrivesDuringNonAnimatedParse()

        XCTAssertEqual(renderedText, "non-animated parse followed immediately by live delta")
    }

    func testStableStreamingMarkdownControllerReusesOnlyGrowingPrefixRenderable() {
        XCTAssertTrue(
            ChatStableStreamingMarkdownControllerTestSupport.hasStaleRenderable(
                renderedText: "已解析前缀",
                requestedText: "已解析前缀继续增长"
            )
        )
        XCTAssertFalse(
            ChatStableStreamingMarkdownControllerTestSupport.hasStaleRenderable(
                renderedText: "正文\n| 表头 | 数值 |",
                requestedText: "正文"
            ),
            "表格拆块使文本收缩时不能继续显示包含表头的旧 renderable"
        )
    }

    func testStreamingTableKeepsRenderedSnapshotWhilePaddedTailCellChanges() throws {
        let source = "| 方案 | 说明 |\n| --- | --- |\n| A | 简短 |\n| 新"
        let before = try XCTUnwrap(ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: source, includeTrailingPartialTableRow: false
        ).first { $0.kind == "table" }).markdown
        let after = try XCTUnwrap(ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: source + "方案", includeTrailingPartialTableRow: false
        ).first { $0.kind == "table" }).markdown
        XCTAssertFalse(after.hasPrefix(before), "补出的尾行管道符会被下一拍改写")
        XCTAssertTrue(ChatStableStreamingMarkdownControllerTestSupport.hasStaleRenderable(
            renderedText: before,
            requestedText: after,
            preservesRenderedTable: true
        ), "同一表格的新解析就绪前必须保留旧表格，不能退回管道原文导致高度跳变")
    }

    func testStableStreamingMarkdownControllerKeepsInstanceRenderableAcrossCompletionParse() {
        let resolution = ChatStableStreamingMarkdownControllerTestSupport
            .instanceResolutionAfterSpeculativeModeChange()

        XCTAssertTrue(resolution.hasRenderable, "完成态解析落地前应保留同一文本的已渲染内容，不能退回纯文本。")
        XCTAssertTrue(resolution.suppressesInitialFade, "完成态复用已有内容时不能让整段文字重新淡入。")
    }

    func testStableStreamingMarkdownControllerKeepsIdentityRenderableAcrossColdCompletion() {
        let resolution = ChatStableStreamingMarkdownControllerTestSupport
            .coldCompletionIdentityResolution()

        XCTAssertTrue(resolution.hasRenderable, "完成瞬间发生视图重建时也不能退回纯文本。")
        XCTAssertTrue(resolution.suppressesInitialFade, "冷完成复用已有内容时不能让整段文字重新淡入。")
    }

    func testStableStreamingMarkdownControllerKeepsSpeculativeRenderableForUnclosedMarkupAtCompletion() {
        let resolution = ChatStableStreamingMarkdownControllerTestSupport
            .instanceResolutionAfterSpeculativeModeChangeWithUnclosedMarkup()

        XCTAssertTrue(
            resolution.hasRenderable,
            "中断/超时使文本停在未闭合语法时，完成态仍复用流式 renderable 保持连续，随后由立即重解析纠正。"
        )
        XCTAssertTrue(
            resolution.suppressesInitialFade,
            "跨模式复用未闭合内容时同样不能让整段文字重新淡入。"
        )
    }

    func testRenderableDocumentReusesOnlyUnchangedPrefixObjects() async {
        let parser = MarkdownParserImpl()
        let initial = await parser.parse(text: "First paragraph.\n\nSecond paragraph.")
        let updated = await parser.parse(text: "First paragraph.\n\nSecond paragraph grows.")
        let initialRenderable = await RenderableDocument(document: initial, config: .default)
        let converted = await RenderableDocument(document: updated, config: .default)
        let updatedRenderable = converted.reusingUnchangedPrefix(from: initialRenderable)

        guard case let .paragraph(_, initialFirst) = initialRenderable.renderables[0],
              case let .paragraph(_, updatedFirst) = updatedRenderable.renderables[0],
              case let .paragraph(_, initialSecond) = initialRenderable.renderables[1],
              case let .paragraph(_, updatedSecond) = updatedRenderable.renderables[1] else {
            return XCTFail("Expected two paragraphs")
        }

        XCTAssertTrue(initialFirst === updatedFirst)
        XCTAssertFalse(initialSecond === updatedSecond)
        XCTAssertEqual(updatedSecond.string, "Second paragraph grows.")
    }

    func testStableStreamingMarkdownControllerRejectsInstanceRenderableAcrossVisualConfigChange() {
        XCTAssertFalse(
            ChatStableStreamingMarkdownControllerTestSupport
                .hasInstanceRenderableAfterVisualConfigChange(),
            "字体或排版配置变化后不能先显示旧 config renderable。"
        )
    }

    func testStableStreamingMarkdownControllerReusesIdentityPrefixOnColdReentry() {
        let result = ChatStableStreamingMarkdownControllerTestSupport
            .coldReentryIdentityPrefixResolution()

        XCTAssertTrue(result.hasRenderable, "冷重入必须复用该消息块已解析的累计前缀，而不是退回 raw Markdown。")
        XCTAssertTrue(result.suppressesInitialFade, "重建已有前缀时不能把整段内容再次从 alpha 0 淡入。")
    }

    func testStreamingTableHonorsColdReentryFadeSuppression() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let tableViewURL = testDirectory.deletingLastPathComponent()
            .appendingPathComponent("vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/TableView.swift")
        let source = try String(contentsOf: tableViewURL, encoding: .utf8)

        XCTAssertTrue(source.contains("@Environment(\\.markdownAnimateInitialText) var animateInitialText"))
        XCTAssertTrue(source.contains("config.shouldAnimateText && animateInitialText"))
    }

    func testCompletedStreamedMarkdownKeepsBlockTopologyAfterColdRecreation() {
        XCTAssertTrue(
            ChatStreamingMarkdownRendererPolicy.initialBlockRendererLatch(
                isStreaming: false,
                hasEverStreamed: true,
                liveRenderingEnabled: true
            ),
            "完成态流式消息回收后必须继续使用 block renderer，不能切回 monolith。"
        )
    }

    func testStreamingMarkdownTypographyFollowsChatFont() throws {
        let defaultFont = ChatStreamingMarkdownTypographyTestSupport.bodyFontName(chatFont: .default)
        let serifFont = ChatStreamingMarkdownTypographyTestSupport.bodyFontName(chatFont: .serif)
        let monospaceFont = ChatStreamingMarkdownTypographyTestSupport.bodyFontName(chatFont: .monospace)

        XCTAssertNotEqual(defaultFont, serifFont)
        XCTAssertNotEqual(defaultFont, monospaceFont)
        XCTAssertNotEqual(serifFont, monospaceFont)
        XCTAssertEqual(serifFont, "NotoSerifSC-Regular")
        XCTAssertEqual(monospaceFont, "JetBrainsMono-Regular")

        let serif = ChatStreamingMarkdownTypographyTestSupport.bodyFonts(chatFont: .serif).normal
        let text = "海棠花与冰块" as CFString
        let resolved = CTFontCreateForString(serif as CTFont, text, CFRange(location: 0, length: 1))
        XCTAssertTrue((CTFontCopyPostScriptName(resolved) as String).hasPrefix("NotoSerifSC"),
                      "中文必须使用包内衬线字体，不能回退到系统字体")

        let mono = ChatStreamingMarkdownTypographyTestSupport.bodyFonts(chatFont: .monospace).normal
        XCTAssertEqual(("iii" as NSString).size(withAttributes: [.font: mono]).width,
                       ("WWW" as NSString).size(withAttributes: [.font: mono]).width, accuracy: 0.01)

        for font in [IOSChatFont.serif, .monospace] {
            let fonts = ChatStreamingMarkdownTypographyTestSupport.bodyFonts(chatFont: font)
            let bold = try XCTUnwrap(fonts.bold)
            let italic = try XCTUnwrap(fonts.italic)
            XCTAssertEqual(bold.familyName, fonts.normal.familyName)
            XCTAssertEqual(bold.pointSize, fonts.normal.pointSize)
            XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
            XCTAssertNotEqual(CTFontGetMatrix(italic as CTFont).c, 0)
        }
    }

    func testStreamingParagraphAnimationUsesPromotionFrameRateRange() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let paragraphViewURL = testDirectory.deletingLastPathComponent()
            .appendingPathComponent("vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/UIKit/ParagraphUIView.swift")
        let source = try String(contentsOf: paragraphViewURL, encoding: .utf8)

        XCTAssertTrue(source.contains("preferredFrameRateRange"))
        XCTAssertFalse(source.contains("preferredFramesPerSecond = 60"))
        XCTAssertFalse(source.contains("completedAnimations.contains"))
        XCTAssertFalse(source.contains("let id: UUID = UUID()"))
    }

    func testCheckedOutParagraphViewCannotBeIssuedTwice() {
        let contents = NSMutableAttributedString(string: "streaming paragraph")
        let first = ParagraphUIViewCache.shared.createOrReuseParagraphUIView(
            contents: contents,
            lineSpacing: nil
        )
        let second = ParagraphUIViewCache.shared.createOrReuseParagraphUIView(
            contents: contents,
            lineSpacing: nil
        )

        XCTAssertFalse(
            first === second,
            "同一个 ParagraphUIView 不能同时交给两个 SwiftUI representable"
        )

        ParagraphUIViewCache.shared.recycle(first)
        ParagraphUIViewCache.shared.recycle(second)
    }

    func testParagraphViewCacheDoesNotCrossTextLayoutEngines() {
        let contents = NSMutableAttributedString(string: "layout engine isolation")
        let textKit1 = ParagraphUIViewCache.shared.createOrReuseParagraphUIView(
            contents: contents,
            lineSpacing: nil,
            usesTextKit1: true
        )
        XCTAssertTrue(textKit1.usesTextKit1)
        ParagraphUIViewCache.shared.recycle(textKit1)

        let textKit2 = ParagraphUIViewCache.shared.createOrReuseParagraphUIView(
            contents: contents,
            lineSpacing: nil,
            usesTextKit1: false
        )
        XCTAssertFalse(textKit2.usesTextKit1)
        ParagraphUIViewCache.shared.recycle(textKit2)

        let reusedTextKit1 = ParagraphUIViewCache.shared.createOrReuseParagraphUIView(
            contents: contents,
            lineSpacing: nil,
            usesTextKit1: true
        )
        XCTAssertTrue(reusedTextKit1.usesTextKit1)
        ParagraphUIViewCache.shared.recycle(reusedTextKit1)
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

    private static func astNodes(for markdown: String) -> [PackedAstNode] {
        guard let data = MarkdownBridge.parse(markdown),
              let reader = PackedAstReader(data: data),
              let root = reader.root() else {
            return []
        }
        return root.children
    }

    private static func firstNode(ofType type: NodeType, in nodes: [PackedAstNode]) -> PackedAstNode? {
        for node in nodes {
            if node.type == type {
                return node
            }
            if let found = firstNode(ofType: type, in: node.children) {
                return found
            }
        }
        return nil
    }

    private static func slice(_ source: String, node: PackedAstNode) -> String {
        guard node.startOffset < node.endOffset else { return "" }
        guard let startIndex = source.utf8.index(
            source.utf8.startIndex,
            offsetBy: node.startOffset,
            limitedBy: source.utf8.endIndex
        ), let endIndex = source.utf8.index(
            source.utf8.startIndex,
            offsetBy: node.endOffset,
            limitedBy: source.utf8.endIndex
        ) else {
            return ""
        }
        return String(source[startIndex..<endIndex])
    }
}
