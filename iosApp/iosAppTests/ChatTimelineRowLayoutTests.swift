import Combine
import Shared
import SwiftUI
import XCTest
@testable import iosApp

@MainActor
final class ChatTimelineRowLayoutTests: ChatNativeTimelineReplayTestCase {
    private final class ContentState: ObservableObject {
        @Published var text = "一行正文"
    }

    private struct UpdatingRow: View {
        @ObservedObject var state: ContentState
        var body: some View { Text(state.text).fixedSize(horizontal: false, vertical: true) }
    }

    private struct ComposerInsetTimelineHarness: View {
        @ObservedObject var model: HarnessModel
        let composerBottomInset: CGFloat
        let displaySetting: DisplaySetting
        let generativeUiSetting: GenerativeUiSetting
        let workspaceStore: IOSWorkspaceStore

        var body: some View {
            NativeChatTimelineView(
                signal: model.signal,
                timelineUpdates: model.timelineUpdates,
                configurationIssue: nil,
                isGenerationActive: model.isGenerationActive,
                usesIndependentTasks: model.usesIndependentTasks,
                activity: model.activity,
                isLoading: false,
                isRecognizingImages: false,
                contextCompactState: .idle,
                followGeneration: model.followGeneration,
                displaySetting: displaySetting,
                generativeUiSetting: generativeUiSetting,
                reasoningLevelLabel: nil,
                workspaceStore: workspaceStore,
                scrollToBottomTrigger: model.scrollToBottomTrigger,
                scrollToBottomSource: .button,
                messageAnchor: model.messageAnchor,
                currentConversationID: model.currentConversationID,
                messagesProvider: { [weak model] in model?.messages ?? [] },
                variantInfoProvider: { _ in nil },
                onAction: { _ in },
                onViewportStateChange: { [weak model] state in model?.recordViewport(state) },
                onDismissKeyboard: {}
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: composerBottomInset)
            }
        }
    }

    func testChildStateAndWidthChangesInvalidateMeasuredRowSize() async throws {
        let state = ContentState()
        let host = UIHostingController(rootView: ChatTimelineRowLayout { UpdatingRow(state: state) })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 1_200)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let proposal = CGSize(width: 300, height: 2_000)
        let short = host.sizeThatFits(in: proposal)
        XCTAssertEqual(host.sizeThatFits(in: proposal), short)

        // The child changes itself after mounting; the layout's input value stays identical.
        state.text = String(repeating: "异步正文继续增长，旧高度不能把内容裁掉。", count: 24)
        try await Task.sleep(for: .milliseconds(80))
        host.view.layoutIfNeeded()
        let long = host.sizeThatFits(in: proposal)
        XCTAssertGreaterThan(long.height, short.height + 100)
        let narrow = host.sizeThatFits(in: CGSize(width: 150, height: 2_000))
        XCTAssertGreaterThan(narrow.height, long.height)
        XCTAssertEqual(host.sizeThatFits(in: proposal), long)
    }

    func testSubAgentResultCardExpandCollapseAndConsecutiveArrivalMaintainNonOverlappingLayoutAndBottomScrollReachability() throws {
        ChatTimelineRowLayoutInvalidation.resetDebugGeometry()
        defer { ChatTimelineRowLayoutInvalidation.resetDebugGeometry() }

        let sharedSettings = IOSSharedSettingsStore(
            userDefaults: UserDefaults(suiteName: "SubAgentCardLayout-\(UUID().uuidString)")!
        )
        let workspaceStore = IOSWorkspaceStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("SubAgentCardLayout-\(UUID().uuidString)", isDirectory: true)
        )
        let model = HarnessModel()
        let composerInset: CGFloat = 116

        let longAssistantText = """
        ### 形态对比摘要

        - 轻量单机壳层：配置简单、启动快，适合单任务快速推进。
        - 多代理队列与审批编排：支持并发工作树隔离与任务审查，但状态概念更多。
        - 跨设备共享会话：强调多端同步与运行时接力，但部署链路最长。

        下面由两个并行子代理分别返回详细核查记录，你可以按需展开查看完整证据。
        """ + "\n\n" + (1...6).map { idx in
            "第 \(idx) 节补充说明：用于构建接近真实首屏高度的主回复上下文，确保后续子代理结果卡位于时间线底部区域。"
        }.joined(separator: "\n\n")

        let reportAlpha = """
        ## 调查结论一

        已完成第一组客户端形态核查，先说明边界再列出分项清单：
        """ + "\n\n" + (1...10).map { idx in
            "- **核查项 A\(idx)**：记录子代理返回的合成脱敏段落 \(idx)，包含多行折行描述以验证展开后卡片真实高度显著超过折叠胶囊高度。"
        }.joined(separator: "\n")

        let reportBeta = """
        ## 对比结论二

        已完成第二组编排与存储机制对比，关键差异如下：
        """ + "\n\n" + (1...10).map { idx in
            "- **对比项 B\(idx)**：记录第二张子代理结果卡的合成脱敏段落 \(idx)，用于验证连续两张结果卡先后到达、分别展开与收起时的行高与滚动范围。"
        }.joined(separator: "\n")

        let userMsg = makeUserMessage("请对比几类多智能体开发环境的定位与取舍")
        let assistantMsg = makeAssistantMessage(text: longAssistantText, finished: true)
        let card1Msg = IosMailboxMessageBridge.shared.makeMessage(
            authorThreadId: "/root/survey_worker_alpha",
            type: "FINAL_ANSWER",
            payload: reportAlpha
        )
        let card2Msg = IosMailboxMessageBridge.shared.makeMessage(
            authorThreadId: "/root/compare_worker_beta",
            type: "FINAL_ANSWER",
            payload: reportBeta
        )
        let card1ID = card1Msg.id.toHexDashString()
        let card2ID = card2Msg.id.toHexDashString()

        model.isGenerationActive = true
        model.messages = [userMsg, assistantMsg]
        model.send(.initialLoad)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView: ComposerInsetTimelineHarness(
            model: model,
            composerBottomInset: composerInset,
            displaySetting: sharedSettings.displaySetting,
            generativeUiSetting: sharedSettings.snapshot.agentRuntime.generativeUi,
            workspaceStore: workspaceStore
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
            previousWindow?.makeKey()
        }

        XCTAssertTrue(pumpUntil(timeout: 4.0) { model.latestViewport.isAtBottom })
        pump(seconds: 0.2)

        // Subagent Result 1 arrives and generation settles (matching real conversation flow).
        model.messages.append(card1Msg)
        model.send(.toolResultAppended)
        pump(seconds: 0.2)
        model.isGenerationActive = false
        model.send(.generationCompleted)
        pump(seconds: 0.3)
        host.view.layoutIfNeeded()

        let scrollView = try XCTUnwrap(Fixture.findScrollView(in: host.view))
        XCTAssertGreaterThanOrEqual(scrollView.adjustedContentInset.bottom, composerInset)

        func rowAllocatedFrame(for id: String) throws -> CGRect {
            let bounds = try XCTUnwrap(ChatTimelineRowLayoutInvalidation.placedRowBounds[id], "Missing row bounds for \(id)")
            return CGRect(x: 16 + bounds.minX, y: 12 + bounds.minY, width: bounds.width, height: bounds.height)
        }

        func cardRenderedFrame(for id: String) throws -> CGRect {
            let row = try rowAllocatedFrame(for: id)
            let size = try XCTUnwrap(ChatTimelineRowLayoutInvalidation.placedSubAgentCardSizes[id], "Missing card size for \(id)")
            return CGRect(x: row.minX, y: row.minY, width: size.width, height: size.height)
        }

        func scrollToMaximumBottomAndLayout() {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            scrollView.layoutIfNeeded()
            let maxOffsetY = max(
                -scrollView.adjustedContentInset.top,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            scrollView.setContentOffset(CGPoint(x: 0, y: maxOffsetY), animated: false)
            scrollView.layoutIfNeeded()
        }

        func visibleBottomAboveComposer() -> CGFloat {
            scrollView.contentOffset.y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
        }

        // Initial baseline: Card 1 starts collapsed (~44pt).
        let initialCard1Row = try rowAllocatedFrame(for: card1ID)
        let initialCard1Rendered = try cardRenderedFrame(for: card1ID)
        let initialContentHeight = scrollView.contentSize.height
        XCTAssertEqual(initialCard1Rendered.height, 44, accuracy: 1.0)
        XCTAssertEqual(initialCard1Row.height, initialCard1Rendered.height, accuracy: 1.0)

        // 1. Expand Card 1 while it is the bottom-most message (Symptom 1: bottom clipped behind composer).
        XCTAssertTrue(ChatTimelineRowLayoutInvalidation.toggleSubAgentCard(card1ID))
        pump(seconds: 0.45)
        host.view.layoutIfNeeded()
        scrollView.layoutIfNeeded()

        let expandedCard1Row = try rowAllocatedFrame(for: card1ID)
        let expandedCard1Rendered = try cardRenderedFrame(for: card1ID)
        XCTAssertGreaterThan(expandedCard1Rendered.height, 280, "展开后的子代理结果卡应渲染完整多段 Markdown 高度")
        XCTAssertEqual(
            expandedCard1Row.height,
            expandedCard1Rendered.height,
            accuracy: 1.0,
            "展开子代理结果卡后 ChatTimelineRowLayout 行高必须同步增长，不得停留在折叠高度 44pt"
        )
        let expectedCard1Growth = expandedCard1Rendered.height - initialCard1Rendered.height
        XCTAssertEqual(
            scrollView.contentSize.height - initialContentHeight,
            expectedCard1Growth,
            accuracy: 2.0,
            "UIScrollView.contentSize.height 必须包含展开后的完整增量高度"
        )
        scrollToMaximumBottomAndLayout()
        XCTAssertLessThanOrEqual(
            expandedCard1Rendered.maxY,
            visibleBottomAboveComposer() + 0.5,
            "最后一张展开的结果卡底部必须能够滚到输入栏 (safeAreaInset.bottom) 之上，不得被遮挡"
        )

        // 2. Late arrival of Card 2 while Card 1 is already expanded (Symptom 2: Card 2 overlaps Card 1 body).
        model.messages.append(card2Msg)
        model.send(.toolResultAppended)
        pump(seconds: 0.45)
        host.view.layoutIfNeeded()
        scrollView.layoutIfNeeded()

        let afterArrivalCard1Row = try rowAllocatedFrame(for: card1ID)
        let afterArrivalCard1Rendered = try cardRenderedFrame(for: card1ID)
        let collapsedCard2Row = try rowAllocatedFrame(for: card2ID)
        let collapsedCard2Rendered = try cardRenderedFrame(for: card2ID)
        let twoCardsOneExpandedContentHeight = scrollView.contentSize.height

        XCTAssertEqual(afterArrivalCard1Row.height, afterArrivalCard1Rendered.height, accuracy: 1.0)
        XCTAssertEqual(collapsedCard2Rendered.height, 44, accuracy: 1.0)
        XCTAssertEqual(collapsedCard2Row.height, collapsedCard2Rendered.height, accuracy: 1.0)
        XCTAssertGreaterThanOrEqual(
            collapsedCard2Rendered.minY,
            afterArrivalCard1Rendered.maxY + 13.5,
            "后到达的第二张结果卡必须排布在第一张已展开结果卡底部之下，绝不能重叠压在第一张正文上"
        )

        // 3. Consecutive expand: expand Card 2 as well, scroll up, then scroll to bottom.
        XCTAssertTrue(ChatTimelineRowLayoutInvalidation.toggleSubAgentCard(card2ID))
        pump(seconds: 0.45)
        host.view.layoutIfNeeded()
        scrollView.layoutIfNeeded()

        let bothExpandedCard1Rendered = try cardRenderedFrame(for: card1ID)
        let expandedCard2Row = try rowAllocatedFrame(for: card2ID)
        let expandedCard2Rendered = try cardRenderedFrame(for: card2ID)
        XCTAssertGreaterThan(expandedCard2Rendered.height, 280)
        XCTAssertEqual(
            expandedCard2Row.height,
            expandedCard2Rendered.height,
            accuracy: 1.0,
            "第二张结果卡展开后行高必须与卡片实际展开高度一致"
        )
        XCTAssertGreaterThanOrEqual(
            expandedCard2Rendered.minY,
            bothExpandedCard1Rendered.maxY + 13.5,
            "连续两张展开的结果卡之间不得发生任何 frame 重叠"
        )

        // Scroll up to top, then scroll to bottom and verify the bottom of Card 2 clears the composer.
        scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: false)
        scrollView.layoutIfNeeded()
        scrollToMaximumBottomAndLayout()
        XCTAssertLessThanOrEqual(
            expandedCard2Rendered.maxY,
            visibleBottomAboveComposer() + 0.5,
            "上滑后再滚到底部时，连续展开的最后一张结果卡底部必须能够滚出输入栏遮挡区"
        )

        // 4. Collapse Card 1, then collapse Card 2, verifying row height and contentSize shrink back accurately.
        XCTAssertTrue(ChatTimelineRowLayoutInvalidation.toggleSubAgentCard(card1ID))
        pump(seconds: 0.45)
        host.view.layoutIfNeeded()
        scrollView.layoutIfNeeded()

        let recollapsedCard1Row = try rowAllocatedFrame(for: card1ID)
        let recollapsedCard1Rendered = try cardRenderedFrame(for: card1ID)
        let shiftedCard2Rendered = try cardRenderedFrame(for: card2ID)
        XCTAssertEqual(recollapsedCard1Rendered.height, 44, accuracy: 1.0)
        XCTAssertEqual(
            recollapsedCard1Row.height,
            recollapsedCard1Rendered.height,
            accuracy: 1.0,
            "收起第一张结果卡后 ChatTimelineRowLayout 行高必须回落到 44pt"
        )
        XCTAssertEqual(
            shiftedCard2Rendered.minY - recollapsedCard1Rendered.maxY,
            14.0,
            accuracy: 1.5,
            "第一张结果卡收起后，第二张结果卡必须紧随其折叠底部上移，无重叠也无残留空白"
        )

        XCTAssertTrue(ChatTimelineRowLayoutInvalidation.toggleSubAgentCard(card2ID))
        pump(seconds: 0.45)
        host.view.layoutIfNeeded()
        scrollView.layoutIfNeeded()

        let recollapsedCard2Row = try rowAllocatedFrame(for: card2ID)
        let recollapsedCard2Rendered = try cardRenderedFrame(for: card2ID)
        XCTAssertEqual(recollapsedCard2Rendered.height, 44, accuracy: 1.0)
        XCTAssertEqual(recollapsedCard2Row.height, recollapsedCard2Rendered.height, accuracy: 1.0)
        XCTAssertEqual(
            scrollView.contentSize.height,
            twoCardsOneExpandedContentHeight - expectedCard1Growth,
            accuracy: 2.0,
            "两张结果卡全部收起后 UIScrollView.contentSize.height 必须回到双折叠基线高度"
        )
    }
}
