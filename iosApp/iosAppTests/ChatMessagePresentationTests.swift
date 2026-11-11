import XCTest
import Combine
import SwiftUI
import CoreText
import Shared
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class ChatMessagePresentationTests: ChatMessageProjectionTestCase {

    func testExactKeepaliveAndFirstGenericWaitHaveNoVisibleTimelineBody() {
        for text in [ChatAsyncTaskSlot.keepaliveDefaultText, "正在处理，请稍候…"] {
            let message = UIMessage.companion.assistant(prompt: text)
            let coalesced = ChatTaskCommentaryCoalescer().coalesce(messages: [message])
            if text == ChatAsyncTaskSlot.keepaliveDefaultText {
                XCTAssertEqual(coalesced[0].toText(), text, "Keepalive records remain intact for persistence")
            } else {
                XCTAssertTrue(coalesced[0].toText().isEmpty, "Ordinary waiting must not receive a first-round exemption")
            }
            let projection = NativeTimelineProjector.build(messages: [message], event: .conversationLoaded)
            XCTAssertFalse(projection.entries.contains { $0.kind == .message && $0.hasVisibleBodyText },
                "Persisted waiting text must not reappear on history load")
        }
    }

    func testWaitingHistoryRendersBelowTopCapsuleAtOriginalPhoneViewport() async throws {
        struct EmptyKeyStore: SettingsAPIKeyStore {
            func loadApiKey() -> String? { nil }
            func saveApiKey(_ key: String) -> Bool { true }
        }
        let suite = "WaitingViewport-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(userDefaults: defaults, apiKeyStore: EmptyKeyStore())
        let shared = IOSSharedSettingsStore(userDefaults: defaults,
            loadCredential: { _ in nil }, storeCredential: { _, _ in true }, deleteCredential: { _ in true })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let conversations = IOSConversationStore(baseDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ChatViewModel(settingsStore: settings, sharedSettings: shared, autoGenerateResponses: false)
        let user = UIMessage.companion.user(prompt: "完成当前练习页面，跳过听力和口语")
        let reply = UIMessage.companion.assistant(prompt: "已识别当前题型，继续核对页面。")
        model.currentRun.state.messages = [user, reply,
            UIMessage.companion.assistant(prompt: ChatAsyncTaskSlot.keepaliveDefaultText)]
        let slot = ChatAsyncTaskSlot(conversationId: nil, inputDigest: "viewport-fixture",
            anchorUserMessageId: ChatMessageProjector.messageId(for: user), phoneControlUserInitiated: false,
            providerSetting: IOSChatForegroundFixtures.makeProviderSetting(),
            params: IOSChatForegroundFixtures.makeParams(toolNames: []),
            toolExposureBridge: nil, recipeCatalogSnapshot: nil, baselineMessages: [user])
        slot.isQueuedForConcurrencySlot = true
        model.currentRun.registerSlot(slot)
        model.bumpMessageRevision(reason: .initialLoad)
        let root = ChatView(settingsStore: settings, sharedSettings: shared, viewModel: model)
            .environment(conversations)
            .environment(ConversationActivityCenter(conversationStore: conversations))
            .environment(RouterPath())
        let host = UIHostingController(rootView: root)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(500))
        model.currentRun.state.messages = [user, reply,
            UIMessage.companion.assistant(prompt: ChatAsyncTaskSlot.keepaliveDefaultText)]
        model.currentRun.registerSlot(slot)
        model.bumpMessageRevision(reason: .initialLoad)
        try await Task.sleep(for: .milliseconds(500))
        host.view.layoutIfNeeded()
        XCTAssertEqual(model.messages.count, 3, "The rendered fixture must contain actual messages")
        func scrolls(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
        }
        let scroll = try XCTUnwrap(scrolls(host.view).max { $0.bounds.height < $1.bounds.height })
        let frame = scroll.convert(scroll.bounds, to: host.view)
        XCTAssertGreaterThanOrEqual(frame.minY, host.view.safeAreaInsets.top + ChatTopBarLayout.controlsHeight)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "waiting-history-original-viewport"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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
        let resignsBeforeFocusClear = view.resignCalls
        focused = false
        coordinator.updateFocus(for: view)
        XCTAssertEqual(view.resignCalls, resignsBeforeFocusClear, "失焦应在 SwiftUI 更新栈之外执行")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(view.resignCalls, resignsBeforeFocusClear + 1, "外部清除焦点必须释放第一响应者")
        focused = true
        coordinator.updateFocus(for: view)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(view.focusCalls, 2)
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
        XCTAssertEqual(view.focusCalls, 2, "已拆除的输入框不能被排队操作重新聚焦")
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

    // MARK: - 流式 pacer：收尾不提速

    /// 流式期间与收尾期必须用**同一个**单拍上限。
    /// 用户明确反馈：收尾把上限从 4 放宽到 8 会有「速度翻倍」的突跳感。
    func testRevealPacerKeepsSameCadenceAfterStreamingEnds() {
        let remainingValues = [1, 5, 24, 60, 200]
        for remaining in remainingValues {
            let step = ChatStreamingRevealTiming.step(remaining: remaining)
            XCTAssertGreaterThanOrEqual(step, 1, "remaining=\(remaining) 每拍至少推进 1 字")
            XCTAssertLessThanOrEqual(
                step,
                ChatStreamingRevealTiming.maxStepPerTick,
                "remaining=\(remaining) 不得超过单拍上限（收尾不得提速）"
            )
        }
        // 上限本身固定为 4：旧实现收尾会放宽到 8，这里锁死。
        XCTAssertEqual(ChatStreamingRevealTiming.maxStepPerTick, 4)
    }

    /// 积压越多步长越大，但到上限就不再增长（大积压不会引发突跳）。
    func testRevealPacerStepGrowsWithBacklogThenSaturates() {
        let small = ChatStreamingRevealTiming.step(remaining: 6)
        let medium = ChatStreamingRevealTiming.step(remaining: 18)
        let large = ChatStreamingRevealTiming.step(remaining: 1000)
        XCTAssertLessThanOrEqual(small, medium)
        XCTAssertLessThanOrEqual(medium, large)
        XCTAssertEqual(large, ChatStreamingRevealTiming.maxStepPerTick)
        XCTAssertEqual(ChatStreamingRevealTiming.step(remaining: 0), 0)
    }

    /// O(1) UTF-16 步进与切片必须与按字符 `step(remaining:)` 完全一致，且绝不劈开代理对或组合 emoji。
    func testRevealPacerUTF16SteppingMatchesCharacterStepAndPreservesComposedGraphemes() {
        let sample = "你好👨‍👩‍👧‍👦Amber✨流式性能测试1234567890"
        var utf16Offset = 0
        var revealedChars = 0
        let totalChars = sample.count
        while utf16Offset < sample.utf16.count {
            let expectedStep = ChatStreamingRevealTiming.step(remaining: totalChars - revealedChars)
            utf16Offset = ChatStreamingRevealTiming.nextStepUTF16Offset(in: sample, fromUTF16Offset: utf16Offset)
            revealedChars = min(totalChars, revealedChars + expectedStep)
            let prefix = ChatStreamingRevealTiming.slicedPrefix(of: sample, utf16Count: utf16Offset)
            XCTAssertEqual(prefix, String(sample.prefix(revealedChars)))
        }
        XCTAssertEqual(revealedChars, totalChars)
    }

    // MARK: - 子代理结果协议边界提取与编辑消息内容驱动高度

    func testSubAgentRoutePublishesReadableResultsOnLoadAndRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticSubAgentRoute-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.newConversation()
        let conversationID = try XCTUnwrap(store.currentConversation?.id)
        func results(_ phase: String) -> [UIMessage] {
            [
                IosMailboxMessageBridge.shared.makeMessage(
                    authorThreadId: "/synthetic/plain", type: "FINAL_ANSWER", payload: "Synthetic plain \(phase)"
                ),
                IosMailboxMessageBridge.shared.makeMessage(
                    authorThreadId: "/synthetic/nested", type: "FINAL_ANSWER",
                    payload: "[Synthetic reference](https://example.invalid/ref)\n\nSynthetic nested \(phase)\n\n[Amber host: child run ended]\n{\"run_ended\":true,\"terminal_status\":\"completed\"}"
                ),
                UIMessage.companion.assistant(prompt: "{\"structured_summary\":{\"conclusion\":\"Synthetic assistant \(phase)\"},\"run_ended\":true}")
            ]
        }
        await store.saveCurrent(messages: results("loaded"))
        let suite = "SyntheticSubAgentRoute.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IOSSharedSettingsStore(
            userDefaults: defaults, loadCredential: { _ in nil },
            storeCredential: { _, _ in true }, deleteCredential: { _ in true }
        )
        let channel = ChatTimelineUpdates()
        let host = UIHostingController(rootView: SubAgentConversationView(
            conversationId: conversationID.toHexDashString(), sharedSettings: settings,
            workspaceStore: IOSWorkspaceStore(baseDirectory: directory), timelineUpdates: channel
        ).environment(store).environment(RouterPath()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host.view.layoutIfNeeded()
        func waitForPublication(after revision: Int) async -> Bool {
            for _ in 0..<200 {
                if channel.latestSignal.revision > revision { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
        func assertBodies(_ phase: String) throws {
            let loaded = channel.structuralMessages
            XCTAssertEqual(loaded.count, 3)
            guard loaded.count == 3 else { return }
            XCTAssertEqual(channel.projectionCache.displayTexts(for: loaded[0])[0], "Synthetic plain \(phase)")
            XCTAssertEqual(channel.projectionCache.displayTexts(for: loaded[1])[0],
                           "[Synthetic reference](https://example.invalid/ref)\n\nSynthetic nested \(phase)")
            XCTAssertEqual(channel.projectionCache.displayTexts(for: loaded[2])[0], "Synthetic assistant \(phase)")
            XCTAssertTrue(loaded[1].toText().contains("run_ended"), "The stored protocol must stay intact")
            XCTAssertTrue(loaded[2].toText().contains("structured_summary"))
        }
        let initialPublished = await waitForPublication(after: 0)
        XCTAssertTrue(initialPublished, "The real child route must publish loaded messages through its own owner")
        try assertBodies("loaded")
        let revision = channel.latestSignal.revision
        await store.saveCurrent(messages: results("refreshed"))
        let refreshPublished = await waitForPublication(after: revision)
        XCTAssertTrue(refreshPublished, "Storage refresh must prepare the same child timeline owner")
        try assertBodies("refreshed")
    }

    private func publishedProjection(_ messages: [UIMessage]) -> (projection: NativeTimelineProjection, updates: ChatTimelineUpdates) {
        let updates = ChatTimelineUpdates()
        updates.publish(.init(revision: 1, reason: .initialLoad), messages: messages)
        // Matches the mounted timeline's initial reset after the event has prepared its snapshots.
        updates.projectionCache.reset(forRevision: 1, preservingPreparedFacts: true)
        let projection = updates.projectionCache.projection(
            messages: messages, event: .conversationLoaded, sourceRevision: 1, startIndex: 0,
            configurationIssue: nil, isGenerationActive: false, isLoading: false, isRecognizingImages: false,
            contextCompactState: .idle, contextCompactBoundaries: [], viewportState: ChatViewportState(),
            displaySettingSignature: 0, generativeUiSettingSignature: 0, renderStateRevision: 0,
            reasoningLevelLabel: nil, streamedMessageIDs: [], renderStateStore: ChatRenderStateStore(),
            variantInfoProvider: { _ in nil }, contentHashProvider: { _, _ in 0 }
        )
        return (projection, updates)
    }

    func testBracketLeadingMarkdownSurvivesMailboxCardAndExportBoundaries() throws {
        let markdown = "[Synthetic reference](https://example.invalid/ref)\n\nSynthetic result body."
        let payloads = [
            markdown,
            markdown + "\n\n[Amber host: child run ended]\n{\"run_ended\":true,\"terminal_status\":\"completed\"}",
            "[Structured Digest]\nSynthetic digest\n[Raw Output]\n" + markdown,
            "[Synthetic label]\n\nSynthetic result body."
        ]
        for payload in payloads {
            let expected = payload.hasPrefix("[Synthetic label]") ? payload : markdown
            XCTAssertEqual(IOSSubAgentOutputProjection.extractUserFacingResult(from: payload), expected)
            let mailbox = IosMailboxMessageBridge.shared.makeMessage(
                authorThreadId: "/synthetic/reviewer", type: "FINAL_ANSWER", payload: payload
            )
            let part = try XCTUnwrap(mailbox.parts.first as? UIMessagePart.Text)
            XCTAssertEqual(IOSSubAgentOutputProjection.userFacingMailboxDisplayText(part: part), expected)
            XCTAssertTrue(IOSConversationExporter.shareText(for: mailbox).contains(expected))
            let projected = publishedProjection([mailbox]).projection
            XCTAssertEqual(projected.entries.first { $0.kind == .message }?.role, .assistant)
            let card = ChatSubAgentResultCard(message: mailbox)
            XCTAssertEqual(Mirror(reflecting: card).descendant("displayText") as? String, expected)
            let projectedCard = ChatSubAgentResultCard(
                sender: "synthetic",
                displayText: projected.entries.first { $0.kind == .message }?.displayTexts[0] ?? ""
            )
            XCTAssertEqual(Mirror(reflecting: projectedCard).descendant("displayText") as? String, expected)
        }
        for internalJSON in [
            #"[{"run_ended":true,"session_read":{"offset":0}}]"#,
            #"[{"run_ended":true,"structured_summary": broken"#
        ] {
            XCTAssertNil(IOSSubAgentOutputProjection.extractUserFacingResult(from: internalJSON))
        }
    }

    func testTimelineActivityAnchorSummaryTracksStructureNotStreamingText() {
        let userA = UIMessage.companion.user(prompt: "Synthetic question A")
        let assistantA = UIMessage.companion.assistant(prompt: "Synthetic partial A")
        let userB = UIMessage.companion.user(prompt: "Synthetic question B")
        let mailbox = IosMailboxMessageBridge.shared.makeMessage(
            authorThreadId: "/synthetic/worker", type: "FINAL_ANSWER", payload: "Synthetic report"
        )
        var summary = ChatListSummarySnapshot()
        summary.updateTimelineAnchors(from: [userA, assistantA, userB, mailbox])
        let oldAnchor = ChatMessageProjector.messageId(for: assistantA)
        XCTAssertEqual(summary.timelineActivityAnchor(rawAnchor: oldAnchor, hasAssistant: true, isTargetedFollowup: false).messageID,
                       ChatMessageProjector.messageId(for: mailbox))
        XCTAssertFalse(summary.timelineActivityAnchor(rawAnchor: oldAnchor, hasAssistant: true, isTargetedFollowup: false).hasAssistant)
        XCTAssertEqual(summary.timelineActivityAnchor(rawAnchor: oldAnchor, hasAssistant: true, isTargetedFollowup: true).messageID, oldAnchor)
        let before = summary
        let updatedA = UIMessage(id: assistantA.id, role: assistantA.role,
                                 parts: [UIMessagePart.Text(text: "Synthetic updated A", metadata: nil)],
                                 annotations: assistantA.annotations, createdAt: assistantA.createdAt,
                                 finishedAt: assistantA.finishedAt, modelId: assistantA.modelId,
                                 usage: assistantA.usage, translation: assistantA.translation)
        summary.updateTimelineAnchors(from: [userA, updatedA, userB, mailbox])
        XCTAssertEqual(summary, before, "Streaming text alone must not invalidate the parent anchor summary")
        summary.updateTimelineAnchors(from: [userA, updatedA])
        XCTAssertTrue(summary.messageIDsBeforeLatestUser.isEmpty, "Branch changes must discard removed anchor ordering")
    }

    func testDisplayTextSnapshotsKeepRawProtocolAndInvalidateOnExactBodyChanges() throws {
        let raw = #"{"structured_summary":{"conclusion":"Synthetic result A"},"run_ended":true}"#
        let original = UIMessage.companion.assistant(prompt: raw)
        let published = publishedProjection([original])
        let displayTexts = published.updates.projectionCache.displayTexts(for: original)
        XCTAssertEqual(displayTexts[0], "Synthetic result A")
        XCTAssertEqual(NativeTimelineMessageFacts(message: original).displayTexts[0], "", "An unprepared body-side fallback must not decode an envelope")
        let iterations = 500
        let decodeStart = Date.timeIntervalSinceReferenceDate
        let decodedCharacters = (0..<iterations).reduce(0) { count, _ in
            count + IOSSubAgentOutputProjection.sanitizeAssistantDisplayTextIfEnvelope(raw).utf16.count
        }
        let decodeMillis = (Date.timeIntervalSinceReferenceDate - decodeStart) * 1_000
        let snapshotStart = Date.timeIntervalSinceReferenceDate
        let snapshotCharacters = (0..<iterations).reduce(0) { count, _ in
            count + (displayTexts[0]?.utf16.count ?? 0)
        }
        let snapshotMillis = (Date.timeIntervalSinceReferenceDate - snapshotStart) * 1_000
        XCTAssertEqual(snapshotCharacters, decodedCharacters)
        print(String(format: "S4 synthetic helper, %d reads: repeated sanitize %.3f ms; projected lookup %.3f ms", iterations, decodeMillis, snapshotMillis))
        XCTAssertEqual(original.toText(), raw, "Display projection must not mutate model/persistence input")
        let projection = published.projection
        XCTAssertEqual(projection.entries.first { $0.kind == .message }?.displayTexts, displayTexts)
        let state = ChatRenderState(rendererMode: .streamingMarkdown, hasEverStreamed: true,
                                    liveRenderingEnabled: true, frozenMarkdownSnapshot: nil)
        let live = ChatLiveTailModel(message: original, isGenerationActive: true, renderState: state, displayTexts: displayTexts)
        live.update(message: original, isGenerationActive: true, renderState: state, sourceRevision: 1, displayTexts: displayTexts)
        XCTAssertEqual(live.displayTexts, displayTexts)
        let changed = UIMessage(id: original.id, role: original.role,
                                parts: [UIMessagePart.Text(text: raw.replacingOccurrences(of: "result A", with: "result B"), metadata: nil)],
                                annotations: original.annotations, createdAt: original.createdAt,
                                finishedAt: original.finishedAt, modelId: original.modelId,
                                usage: original.usage, translation: original.translation)
        XCTAssertEqual(changed.toText().utf16.count, original.toText().utf16.count)
        published.updates.publish(.init(revision: 2, reason: .streamDelta), messages: [changed])
        let changedTexts = published.updates.projectionCache.displayTexts(for: changed)
        live.update(message: changed, isGenerationActive: true, renderState: state, sourceRevision: 2, displayTexts: changedTexts)
        XCTAssertEqual(live.displayTexts[0], "Synthetic result B", "ID/length equality cannot reuse a stale display snapshot")
        let facts = NativeTimelineMessageFacts(message: changed, identity: ChatMessageContentIdentity(changed), displayTexts: changedTexts)
        let replacement = try XCTUnwrap(NativeTimelineProjector.replacingStreamingTail(
            in: projection, messages: [changed], event: .assistantStreamDelta,
            isGenerationActive: true, viewportState: ChatViewportState(),
            factsByObjectID: [ObjectIdentifier(changed): facts]
        ))
        XCTAssertEqual(replacement.entries.first { $0.kind == .message }?.displayTexts[0], "Synthetic result B")
    }

    func testSubAgentResultExtractionStripsHostEnvelopePreservesMarkdownAndNeverFallsBackToRawJSON() {
        let syntheticExcerptPayload = """
        前置补充说明。
        这部分详细列出了各候选方案在离线与弱网场景下的吞吐表现，部分长表已在 2000 字符边界处截断等待按需分页读取

        [Amber host: child result excerpt]
        {"run_ended":true,"session_read":{"conversation_id":"00000000-0000-4000-8000-000000000101","message_id":"00000000-0000-4000-8000-000000000202","offset":0},"structured_summary":{"conclusion":"已完成三组候选缓存方案对比，优先推荐双层索引方案。","deliverable_hint":"缓存方案对比表 + 推荐配置 + 待验证项","formatted_summary":"核心结论：已完成三组候选缓存方案对比，优先推荐双层索引方案。\\n交付物：缓存方案对比表 + 推荐配置 + 待验证项\\n关键产出要点：\\n• 方案 A 的宣传吞吐数据缺少真实基准佐证，多处指标存在自相矛盾。\\n• 实测表明方案 B 在冷启动与内存占用之间最均衡，并支持增量快照恢复。"}}
        This child run has ended. The report above is a delivery excerpt, not a promise of another message. Read the stored full message with native session_read using the reference above, then follow next_offset until null.
        """

        // 1. 本机 FINAL_ANSWER 信封保留内部结构化通道，同时展示层仅提取面向用户的可读摘要与正文
        let mailboxMessage = IosMailboxMessageBridge.shared.makeMessage(
            authorThreadId: "/root/benchmark_worker",
            type: "FINAL_ANSWER",
            payload: syntheticExcerptPayload
        )
        XCTAssertTrue(
            mailboxMessage.toText().contains("\"session_read\""),
            "内部结构化通道（供父模型上传）必须保留原始信封引用"
        )
        let textPart = try! XCTUnwrap(mailboxMessage.parts.first as? UIMessagePart.Text)
        let userFacing = IOSSubAgentOutputProjection.userFacingMailboxDisplayText(part: textPart)
        XCTAssertTrue(userFacing.contains("核心结论：已完成三组候选缓存方案对比，优先推荐双层索引方案。"))
        XCTAssertTrue(userFacing.contains("交付物：缓存方案对比表 + 推荐配置 + 待验证项"))
        XCTAssertTrue(userFacing.contains("\n• 方案 A 的宣传吞吐数据缺少真实基准佐证"))
        XCTAssertTrue(userFacing.contains("\n• 实测表明方案 B 在冷启动与内存占用之间最均衡"))
        XCTAssertFalse(userFacing.contains("[Amber host: child result excerpt]"))
        XCTAssertFalse(userFacing.contains("\"run_ended\""))
        XCTAssertFalse(userFacing.contains("\"session_read\""))
        XCTAssertFalse(userFacing.contains("00000000-0000-4000-8000-000000000101"))
        XCTAssertFalse(userFacing.contains("00000000-0000-4000-8000-000000000202"))
        XCTAssertFalse(userFacing.contains("This child run has ended"))

        // 2. 字段顺序打乱且无 formatted_summary 时，仍按确定性顺序提取可读结论、交付物、要点与拍板项并保留换行
        let permutedJSON = """
        {"session_read":{"offset":0,"message_id":"00000000-0000-4000-8000-000000000202","conversation_id":"00000000-0000-4000-8000-000000000101"},"structured_summary":{"key_points":["要点一：方案 B 可直接合入主干","要点二：方案 C 需补充压力测试"],"needs_user_decision":true,"decision_prompt":"是否先按方案 B 推进首轮集成？","deliverable_hint":"缓存方案对比表","conclusion":"评估完成，先同步核心结论。"},"run_ended":true}
        """
        let extractedPermuted = try! XCTUnwrap(IOSSubAgentOutputProjection.extractUserFacingResult(from: permutedJSON))
        XCTAssertEqual(
            extractedPermuted,
            """
            评估完成，先同步核心结论。
            交付物：缓存方案对比表
            关键产出要点：
            • 要点一：方案 B 可直接合入主干
            • 要点二：方案 C 需补充压力测试
            需用户拍板：是否先按方案 B 推进首轮集成？
            """
        )

        // 3. 缺失可读字段的纯内部 JSON 或截断损坏 JSON：绝不回退为整包原始 JSON
        let internalOnlyJSON = """
        [Amber host: child result excerpt]
        {"run_ended":true,"session_read":{"conversation_id":"00000000-0000-4000-8000-000000000101","message_id":"00000000-0000-4000-8000-000000000202","offset":0},"terminal_status":"failed"}
        """
        XCTAssertNil(
            IOSSubAgentOutputProjection.extractUserFacingResult(from: internalOnlyJSON),
            "缺失可读摘要字段时必须返回 nil，不得把内部 JSON 回退当作正文"
        )
        let malformedJSON = #"{"run_ended":true,"structured_summary":{"conclusion":"半截损坏 JSON"#
        XCTAssertNil(
            IOSSubAgentOutputProjection.extractUserFacingResult(from: malformedJSON),
            "JSON 解析失败时绝不能回退展示原始 JSON 字符串"
        )

        // 4. 云端入口（MacGatewayStore.ingestCloudDialogueEventsPage）同步在协议边界净化子代理回包
        let gateway = MacGatewayStore()
        let cloudPage = MacGatewayCloudDialogueEventsPage(
            items: [
                MacGatewayCloudDialogueEvent(
                    seq: 1,
                    id: "evt-cloud-subagent-1",
                    kind: .taskResult,
                    role: "assistant",
                    text: syntheticExcerptPayload,
                    topicId: "topic-1",
                    workItemId: "work-1",
                    outcome: .completed,
                    soulRevision: nil
                )
            ],
            nextCursor: 1,
            soulRevision: nil
        )
        gateway.ingestCloudDialogueEventsPage(cloudPage, requestedAfter: 0)
        let ingestedText = try! XCTUnwrap(gateway.cloudDialogueEvents.first?.text)
        XCTAssertTrue(ingestedText.contains("核心结论：已完成三组候选缓存方案对比"))
        XCTAssertFalse(ingestedText.contains("[Amber host: child result excerpt]"))
        XCTAssertFalse(ingestedText.contains("00000000-0000-4000-8000-000000000101"))
    }

    func testChatMessageEditSheetUsesContentDrivenHeightCapsAndScrollsLongTextWhilePreservingLayout() throws {
        let shortText = "请帮我核对一下构建产物的大小与符号表配置"
        let mediumText = """
        我们已经有一套默认的主工程编译配置了，现在需要针对模拟器与回归测试环境单独梳理一份轻量构建参数，优先保证增量链接速度和符号完整性。

        目前主要想确认哪些调试阶段可以按需延后执行，因为日常开发只需要验证核心模块。请帮我在工程构建脚本和相关配置文档里查一下可行方案。
        """
        let longText = Array(
            repeating: "这是一段较长的历史消息内容，用于验证编辑消息框在达到最大高度上限后转为内部滚动，并且全文保持完整可编辑。",
            count: 24
        ).joined(separator: "\n")

        let shortEditorH = ChatMessageEditSheet.editorHeight(for: shortText, availableWidth: 393, dynamicTypeSize: .large)
        let mediumEditorH = ChatMessageEditSheet.editorHeight(for: mediumText, availableWidth: 393, dynamicTypeSize: .large)
        let longEditorH = ChatMessageEditSheet.editorHeight(for: longText, availableWidth: 393, dynamicTypeSize: .large)

        // 1. 短消息与中等消息高度由内容驱动，绝不占满整屏；随内容行数增长，长消息在上限（320pt）封顶
        XCTAssertLessThanOrEqual(shortEditorH, 110, "短消息编辑框应保持紧凑最小高度，不留大块空白")
        XCTAssertGreaterThan(mediumEditorH, shortEditorH, "6 行消息的编辑框高度应随内容自然增长")
        XCTAssertLessThan(mediumEditorH, ChatMessageEditSheet.defaultMaxEditorHeight, "中等长度消息未达上限前不应直接拉满上限")
        XCTAssertEqual(longEditorH, ChatMessageEditSheet.defaultMaxEditorHeight, accuracy: 0.5, "超长消息编辑框高度应在上限处封顶并转为内部滚动")

        let shortSheetH = ChatMessageEditSheet.preferredSheetHeight(for: shortText, availableWidth: 393, dynamicTypeSize: .large)
        let mediumSheetH = ChatMessageEditSheet.preferredSheetHeight(for: mediumText, availableWidth: 393, dynamicTypeSize: .large)
        XCTAssertLessThan(shortSheetH, 240, "短消息默认弹窗高度应紧凑贴合内容，不占近整屏")
        XCTAssertGreaterThan(mediumSheetH, shortSheetH)
        XCTAssertLessThan(mediumSheetH, 360)

        // 2. 动态字号（Accessibility）下最小高度与测量高度同步放大且不裁切
        let largeTypeEditorH = ChatMessageEditSheet.editorHeight(for: shortText, availableWidth: 393, dynamicTypeSize: .accessibility2)
        XCTAssertGreaterThan(largeTypeEditorH, shortEditorH, "无障碍大字号下编辑框高度应随字号同步放大")

        // 3. 在真实 UIHostingController 宿主中核对初帧布局、边距对齐、长文可滚动与完整可编辑性
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)

        func findTextView(in view: UIView) -> UITextView? {
            if let tv = view as? UITextView { return tv }
            for sub in view.subviews {
                if let found = findTextView(in: sub) { return found }
            }
            return nil
        }

        let mediumHost = UIHostingController(
            rootView: ChatMessageEditSheet(
                draft: ChatMessageEditDraft(messageId: "m-edit-1", text: mediumText),
                onSubmit: { _, _ in },
                onCancel: {}
            )
        )
        window.rootViewController = mediumHost
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        mediumHost.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        mediumHost.view.layoutIfNeeded()

        let mediumTextView = try XCTUnwrap(findTextView(in: mediumHost.view), "应挂载可编辑的 UITextView")
        let mediumFrameInWindow = mediumTextView.convert(mediumTextView.bounds, to: window)
        XCTAssertEqual(mediumTextView.text, mediumText)
        XCTAssertTrue(mediumTextView.isEditable)
        XCTAssertGreaterThanOrEqual(mediumFrameInWindow.minX, 16, "左侧应保留至少 16pt 安全边距，无越界错位")
        XCTAssertLessThanOrEqual(mediumFrameInWindow.maxX, 393 - 16, "右侧应保留至少 16pt 安全边距，无水平溢出")
        XCTAssertLessThan(mediumFrameInWindow.height, 260, "6 行中等长度内容在宿主中高度应紧凑，不得占满整屏（852pt）")

        let longHost = UIHostingController(
            rootView: ChatMessageEditSheet(
                draft: ChatMessageEditDraft(messageId: "m-edit-2", text: longText),
                onSubmit: { _, _ in },
                onCancel: {}
            )
        )
        window.rootViewController = longHost
        longHost.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        longHost.view.layoutIfNeeded()

        let longTextView = try XCTUnwrap(findTextView(in: longHost.view))
        let longFrameInWindow = longTextView.convert(longTextView.bounds, to: window)
        XCTAssertEqual(longTextView.text, longText, "长原文必须完整保留且可编辑")
        XCTAssertTrue(longTextView.isEditable)
        XCTAssertTrue(longTextView.isScrollEnabled, "达到高度上限后编辑区必须启用内部滚动")
        XCTAssertGreaterThan(longFrameInWindow.height, mediumFrameInWindow.height, "长内容编辑区高度应大于中等内容并停在上限")
        XCTAssertLessThanOrEqual(longFrameInWindow.height, ChatMessageEditSheet.defaultMaxEditorHeight + 2, "长内容编辑区高度不得突破上限")
    }
}
