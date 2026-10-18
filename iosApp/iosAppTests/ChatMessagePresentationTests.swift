import XCTest
import Combine
import SwiftUI
import CoreText
import Shared
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class ChatMessagePresentationTests: ChatMessageProjectionTestCase {

    func testOpaqueReasoningHistoryDoesNotShowEmptyCardsOrHideThinkingPlaceholder() throws {
        let raw = #"""
        [
          {"type":"reasoning","reasoning":"","metadata":{"signature":"sig-empty"}},
          {"type":"reasoning","reasoning":"","metadata":{"encrypted_content":"encrypted"}},
          {"type":"reasoning","reasoning":"","metadata":{"claude_redacted_thinking":{"type":"redacted_thinking","data":"redacted"}}},
          {"type":"reasoning","reasoning":"","metadata":{"reasoning_content_present":true}},
          {"type":"reasoning","reasoning":"visible thought","metadata":{"signature":"sig-visible"}},
          {"type":"reasoning","reasoning":"","metadata":{"signature":"","encrypted_content":""}}
        ]
        """#
        let parts = try IosToolOutputJsonBridge.shared.decode(json: raw)
        XCTAssertEqual(parts.count, 6)
        for part in parts.prefix(3) {
            let reasoning = try XCTUnwrap(part as? UIMessagePart.Reasoning)
            XCTAssertFalse(MessageBubbleView.shouldRenderReasoningCard(reasoning))
        }
        XCTAssertFalse(MessageBubbleView.hasVisibleAssistantContent(in: Array(parts.prefix(3))),
                       "隐藏的协议块不能抑制正在生成的思考占位卡")
        XCTAssertNil(MessageBubbleView.firstVisibleReasoningIndex(in: Array(parts.prefix(3))))
        for part in parts.suffix(3) {
            let reasoning = try XCTUnwrap(part as? UIMessagePart.Reasoning)
            XCTAssertTrue(MessageBubbleView.shouldRenderReasoningCard(reasoning),
                          "普通空 reasoning 和可读 thinking 保持原卡片语义")
        }
        XCTAssertTrue(MessageBubbleView.hasVisibleAssistantContent(in: parts))
        XCTAssertEqual(MessageBubbleView.firstVisibleReasoningIndex(in: parts), 3)
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

    func testComposerFocusRunsAfterUpdateAndHonorsCancelledOrDetachedRequests() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let view = FocusProbeTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 40))
        window.rootViewController!.view.addSubview(view)
        let controller = ComposerInputController()
        controller.textView = view
        var focused = true
        let input = ComposerInputTextView(
            text: .constant("建议内容"), height: .constant(40),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            isEnabled: true, sendOnEnter: false, controller: controller, onSubmit: {}
        )
        let coordinator = input.makeCoordinator()
        coordinator.updateFocus(for: view)
        XCTAssertEqual(view.focusCalls, 0, "不能在 UIViewRepresentable 的更新栈内同步获取焦点")
        focused = false
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(view.focusCalls, 0, "已撤销的聚焦请求不能弹起键盘")

        focused = true
        for _ in 0..<10 { coordinator.updateFocus(for: view) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(view.focusCalls, 1, "同一轮视图更新只需处理一次焦点")
        coordinator.parent.isEnabled = false
        let previousResigns = view.resignCalls
        coordinator.updateFocus(for: view)
        XCTAssertEqual(view.resignCalls, previousResigns)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(view.resignCalls, previousResigns + 1)

        coordinator.parent.isEnabled = true
        coordinator.updateFocus(for: view)
        controller.textView = nil
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(view.focusCalls, 1, "已拆除的输入框不能被排队操作重新聚焦")
    }

    func testSuggestionStripReachesScreenEdgesAndDraftRemainsEditableAfterFilling() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = SuggestionComposerModel()
        let host = UIHostingController(rootView: SuggestionComposerHarness(model: model))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.backgroundColor = .systemBackground
        window.makeKeyAndVisible()
        defer {
            host.view.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(350))
        host.view.layoutIfNeeded()
        func horizontalScroll(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, !(scroll is UITextView),
               scroll.contentSize.width > scroll.bounds.width + 1 { return scroll }
            return view.subviews.compactMap { horizontalScroll(in: $0) }.first
        }
        let scroll = try XCTUnwrap(horizontalScroll(in: host.view))
        let viewport = scroll.convert(scroll.bounds, to: window)
        XCTAssertEqual(viewport.minX, window.bounds.minX, accuracy: 1)
        XCTAssertEqual(viewport.maxX, window.bounds.maxX, accuracy: 1, "滚动裁切边界必须是屏幕边缘，而不是输入框内边距")
        scroll.setContentOffset(CGPoint(x: 120, y: 0), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "suggestions-at-screen-edge"
        attachment.lifetime = .keepAlways
        add(attachment)
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("suggestions-at-screen-edge.png")
        try XCTUnwrap(image.pngData()).write(to: evidence)
        print("SUGGESTION_EVIDENCE \(evidence.path)")

        let suggestion = try XCTUnwrap(model.viewModel.chatSuggestions.last)
        model.viewModel.fillInputFromSuggestion(suggestion)
        model.focused = true
        try await Task.sleep(for: .milliseconds(500))
        let input = try XCTUnwrap(model.controller.textView)
        XCTAssertEqual(input.text, suggestion)
        XCTAssertTrue(input.isFirstResponder)
        XCTAssertTrue(model.viewModel.messages.isEmpty)
        input.insertText("！")
        XCTAssertEqual(model.viewModel.inputText, suggestion + "！", "填入后输入框必须仍能响应编辑")
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
        let grid = try source("iosApp/Chat/Media/GeneratedImages/ChatGeneratedImageGrid.swift")

        XCTAssertTrue(grid.contains("ForEach(0..<display.requestedCount"))
    }

    func testThinkingFallbackWaitsForVisibleAssistantText() throws {
        let bubble = try source("iosApp/Chat/Message/MessageBubbleView.swift")
        let start = try XCTUnwrap(bubble.range(of: "private var hasVisibleAssistantContent"))
        let end = try XCTUnwrap(
            bubble.range(of: "private var nonEmptyTextPartCount", range: start.upperBound..<bubble.endIndex)
        )
        let visibility = bubble[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(visibility.contains("text.text.contains { !$0.isWhitespace }"))
        XCTAssertFalse(visibility.contains("return !text.text.isEmpty"))
    }

    func testToolDetailSelectionKeepsStableIdentityAndResolvesCurrentMessageOutput() throws {
        let bubble = try source("iosApp/Chat/Message/MessageBubbleView.swift")
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

    private final class MeasuredComposerTextView: UITextView {
        var measurements = 0
        var fittedHeight: CGFloat = 80
        override func sizeThatFits(_ size: CGSize) -> CGSize {
            measurements += 1
            return CGSize(width: size.width, height: fittedHeight)
        }
    }

    private final class FocusProbeTextView: UITextView {
        var focusCalls = 0
        var resignCalls = 0
        private var hasInputFocus = false
        override var isFirstResponder: Bool { hasInputFocus }
        override func becomeFirstResponder() -> Bool {
            focusCalls += 1
            hasInputFocus = true
            return true
        }
        override func resignFirstResponder() -> Bool {
            resignCalls += 1
            hasInputFocus = false
            return true
        }
    }

    @MainActor
    private final class SuggestionComposerModel: ObservableObject {
        @Published var focused = false
        @Published var height: CGFloat = 40
        let controller = ComposerInputController()
        let viewModel: ChatViewModel
        init() {
            let defaults = UserDefaults(suiteName: "SuggestionComposer-\(UUID().uuidString)")!
            viewModel = ChatViewModel(
                settingsStore: SettingsStore(userDefaults: defaults),
                sharedSettings: IOSSharedSettingsStore(userDefaults: defaults),
                autoGenerateResponses: false
            )
            viewModel.chatSuggestions = [
                "给我一个可以直接照着操作的完整例子",
                "进一步解释这个结论的依据与适用条件",
                "给我一个可以直接照着操作的完整例子",
                "整理一下接下来最值得尝试的几步",
            ]
        }
    }

    private struct SuggestionComposerHarness: View {
        @ObservedObject var model: SuggestionComposerModel
        var body: some View {
            VStack(spacing: 8) {
                Spacer()
                if !model.viewModel.chatSuggestions.isEmpty {
                    ChatSuggestionStrip(suggestions: model.viewModel.chatSuggestions) { suggestion in
                        model.viewModel.fillInputFromSuggestion(suggestion)
                        model.focused = true
                    }
                }
                ComposerInputTextView(
                    text: Binding(get: { model.viewModel.inputText }, set: { model.viewModel.inputText = $0 }),
                    height: $model.height, isFocused: $model.focused,
                    isEnabled: true, sendOnEnter: false, controller: model.controller, onSubmit: {}
                )
                .frame(height: model.height)
            }
            .padding(.horizontal, ChatLayout.contentHorizontalInset)
            .padding(.bottom, 8)
            .animation(.easeOut(duration: 0.2), value: model.viewModel.chatSuggestions.isEmpty)
        }
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
}
