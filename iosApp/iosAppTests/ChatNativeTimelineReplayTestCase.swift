import XCTest
import SwiftUI
import QuartzCore
import Shared
@testable import SwiftStreamingMarkdown
@testable import iosApp

/// 默认路径(`NativeChatTimelineView`)的执行层集成回放门禁。
///
/// 背景:`ChatStreamReplayTests` 全部作用于非默认的 UICollectionView 路径；
/// 本套件必须直驱 `ChatView` 当前使用的 Native timeline，不能让退役列表替它背书。
/// `handleSignal` 分派、入场重试梯、真实高度增长跟随、terminal settle 等执行层
/// 零执行覆盖。本套件把真实列表挂进带 windowScene 的 UIWindow,用公开输入面
/// (signal + messagesProvider)驱动,断言只取自 `onViewportStateChange` 的
/// 状态快照与底层 UIScrollView 的终态几何。除一条固定输入的 measured-growth
/// 动画 canary 外，其余用例只断终态与单调性，避免把普通回放变成录屏测试。
///
/// 明确不在 sim 覆盖(真机专属):真实拖拽/惯性的 scroll phase、键盘避让、
/// 120Hz 时序、录屏级视觉基线。拖拽暂停语义由 `ChatViewportPolicyTests`
/// 的 reducer 纯单测锁定。
@MainActor
class ChatNativeTimelineReplayTestCase: XCTestCase {
    final class HarnessModel: ObservableObject {
        @Published var signal = ChatMessageUpdateSignal(revision: 0, reason: .initialLoad)
        @Published var isGenerationActive = false
        @Published var followGeneration = true
        @Published var scrollToBottomTrigger = 0
        @Published var messageAnchor: ChatMessageAnchor?
        @Published var currentConversationID: String?
        var messages: [UIMessage] = []
        var requestedVariantIndices: Set<Int> = []
        private(set) var viewportHistory: [ChatViewportState] = []

        var latestViewport: ChatViewportState {
            viewportHistory.last ?? ChatViewportState()
        }

        func recordViewport(_ state: ChatViewportState) {
            viewportHistory.append(state)
        }

        func send(_ reason: ChatMessageUpdateReason, lagAllowance: CGFloat = 1) {
            signal = ChatMessageUpdateSignal(
                revision: signal.revision + 1,
                reason: reason,
                lagAllowance: lagAllowance
            )
        }
    }

    struct Harness: View {
        @ObservedObject var model: HarnessModel
        let displaySetting: DisplaySetting
        let generativeUiSetting: GenerativeUiSetting
        let workspaceStore: IOSWorkspaceStore

        var body: some View {
            NativeChatTimelineView(
                signal: model.signal,
                configurationIssue: nil,
                isGenerationActive: model.isGenerationActive,
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
                variantInfoProvider: { [weak model] index in
                    model?.requestedVariantIndices.insert(index)
                    return nil
                },
                onAction: { _ in },
                onViewportStateChange: { [weak model] state in model?.recordViewport(state) },
                onDismissKeyboard: {}
            )
        }
    }

    struct Fixture {
        let model: HarnessModel
        let window: UIWindow
        let host: UIHostingController<Harness>

        var scrollView: UIScrollView? {
            Self.findScrollView(in: host.view)
        }

        static func findScrollView(in view: UIView) -> UIScrollView? {
            if let scrollView = view as? UIScrollView { return scrollView }
            for subview in view.subviews {
                if let found = findScrollView(in: subview) { return found }
            }
            return nil
        }

        func tearDown() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    final class DisplayLinkGapProbe: NSObject {
        private var displayLink: CADisplayLink?
        private var previousTimestamp: CFTimeInterval?
        private(set) var gaps: [TimeInterval] = []
        private(set) var gapEndTimestamps: [CFTimeInterval] = []

        func start() {
            let displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick(_ displayLink: CADisplayLink) {
            defer { previousTimestamp = displayLink.timestamp }
            guard let previousTimestamp else { return }
            gaps.append(displayLink.timestamp - previousTimestamp)
            gapEndTimestamps.append(displayLink.timestamp)
        }
    }

    @MainActor
    final class ScrollFrameProbe: NSObject {
        private static let streamingMarker = "连续正文开始。"

        struct Sample {
            let contentHeight: CGFloat
            let distanceToBottom: CGFloat
            let contentOffsetX: CGFloat
            let contentOffsetY: CGFloat
            let paragraphHeight: CGFloat?
            let paragraphLength: Int?
            let paragraphUsesTextKit1: Bool?
            let paragraphIdentity: ObjectIdentifier?
            /// vendor TableView 内层横向 ScrollView 的高度：表格最后一行是否
            /// 已在流式期显示的直接证据（完成时成批出现 = 高度增长一行）。
            let tableHeight: CGFloat?
            let tableIdentity: ObjectIdentifier?
            /// 本帧是否出现「未渲染的 markdown 原文」：正文段落里可见字面
            /// `**`/`## `、或以 `| … |` 表格管道行形式存在的纯文本。流式渲染
            /// 产物永远不会携带这些字面标记；出现即证明渲染管线切到了
            /// `RenderableDocument(plainText:)` 兜底（完成切换空窗闪帧）。
            let rawMarkdownVisible: Bool?
        }

        private weak var scrollView: UIScrollView?
        private weak var rootView: UIView?
        private var displayLink: CADisplayLink?
        private let capturesAfterDisplayLinkCallbacks: Bool
        private var postCallbackSamplePending = false
        private var isRunning = false
        private(set) var samples: [Sample] = []

        init(
            scrollView: UIScrollView,
            rootView: UIView,
            capturesAfterDisplayLinkCallbacks: Bool = false
        ) {
            self.scrollView = scrollView
            self.rootView = rootView
            self.capturesAfterDisplayLinkCallbacks = capturesAfterDisplayLinkCallbacks
        }

        func start() {
            isRunning = true
            let displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }

        func stop() {
            isRunning = false
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick(_ displayLink: CADisplayLink) {
            guard capturesAfterDisplayLinkCallbacks else {
                captureSample()
                return
            }
            guard !postCallbackSamplePending else { return }
            postCallbackSamplePending = true
            let scheduledContentHeight = scrollView?.contentSize.height
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                postCallbackSamplePending = false
                guard isRunning else { return }
                guard let scheduledContentHeight,
                      let scrollView,
                      abs(scrollView.contentSize.height - scheduledContentHeight) < 0.5 else {
                    return
                }
                captureSample()
            }
        }

        private func captureSample() {
            guard let scrollView else { return }
            let paragraph = rootView.flatMap(Self.streamingParagraph(in:))
            let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height
                - scrollView.adjustedContentInset.bottom
            let table = rootView.flatMap { Self.tableScrollView(in: $0, excluding: scrollView) }
            samples.append(Sample(
                contentHeight: scrollView.contentSize.height,
                distanceToBottom: max(0, scrollView.contentSize.height - visibleBottom),
                contentOffsetX: scrollView.contentOffset.x,
                contentOffsetY: scrollView.contentOffset.y,
                paragraphHeight: paragraph?.frame.height,
                paragraphLength: paragraph.flatMap(Self.streamingTextLength(in:)),
                paragraphUsesTextKit1: paragraph?.usesTextKit1,
                paragraphIdentity: paragraph.map(ObjectIdentifier.init),
                tableHeight: table?.frame.height,
                tableIdentity: table.map(ObjectIdentifier.init),
                rawMarkdownVisible: rootView.map(Self.hasRawMarkdown(in:))
            ))
        }

        /// 「未渲染 markdown 原文」判定：正文段落里出现字面结构标记。
        /// - `**`：粗体定界符原样显示（流式/终态解析渲染后不可能保留）。
        /// - `## `：标题井号原样显示。
        /// - `| … | … |`：整行表格管道文本（vendor 表格渲染后不可能出现）。
        /// - 行首 `- `/`* `：列表标记原样显示。
        static func hasRawMarkdown(in view: UIView) -> Bool {
            if let textView = view as? ParagraphUIView,
               let text = textView.text {
                // UITextView supplies a foreign String. Avoid grapheme splitting
                // and searching every frame without an ASCII marker candidate.
                // Keep the original checks: literal search alone would also match
                // markers whose final character has a combining mark.
                let nativeText = text as NSString
                if nativeText.range(of: "**", options: .literal).location != NSNotFound && text.contains("**") { return true }
                if nativeText.range(of: "## ", options: .literal).location != NSNotFound && text.contains("## ") { return true }
                if nativeText.range(of: " | ", options: .literal).location != NSNotFound &&
                    text.contains(" | ") && text.contains("|") { return true }
                if nativeText.range(of: "- ", options: .literal).location != NSNotFound ||
                    nativeText.range(of: "* ", options: .literal).location != NSNotFound {
                    for line in text.split(separator: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return true }
                    }
                }
            }
            for subview in view.subviews {
                if hasRawMarkdown(in: subview) { return true }
            }
            return false
        }

        static func streamingParagraph(in view: UIView) -> ParagraphUIView? {
            if let textView = view as? ParagraphUIView,
               textView.text.contains(streamingMarker) {
                return textView
            }
            for subview in view.subviews {
                if let paragraph = streamingParagraph(in: subview) {
                    return paragraph
                }
            }
            return nil
        }

        static func streamingTextLength(in paragraph: ParagraphUIView) -> Int? {
            let text = paragraph.attributedText.string as NSString
            let markerRange = text.range(of: streamingMarker)
            guard markerRange.location != NSNotFound else { return nil }
            return text.length - markerRange.location
        }

        static func paragraph(in view: UIView, withPrefix prefix: String) -> ParagraphUIView? {
            if let textView = view as? ParagraphUIView,
               textView.text.hasPrefix(prefix) {
                return textView
            }
            for subview in view.subviews {
                if let paragraph = paragraph(in: subview, withPrefix: prefix) {
                    return paragraph
                }
            }
            return nil
        }

        /// vendor TableView 的内层横向 ScrollView（fixture 无代码块/LaTeX，非主列表的
        /// 小高度 UIScrollView 只有表格一个；ParagraphUIView 的 UITextView 排除）。
        static func tableScrollView(
            in view: UIView,
            excluding mainScrollView: UIScrollView
        ) -> UIScrollView? {
            if let scrollView = view as? UIScrollView,
               !(scrollView is UITextView),
               scrollView !== mainScrollView,
               scrollView.contentSize.height > 0,
               scrollView.contentSize.height < 800 {
                return scrollView
            }
            for subview in view.subviews {
                if let found = tableScrollView(in: subview, excluding: mainScrollView) {
                    return found
                }
            }
            return nil
        }
    }

    func makeFixture(
        configure: (HarnessModel) -> Void = { _ in }
    ) -> Fixture {
        let sharedSettings = IOSSharedSettingsStore(
            userDefaults: UserDefaults(suiteName: "ChatSwiftUIStreamReplay-\(UUID().uuidString)")!
        )
        let workspaceStore = IOSWorkspaceStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ChatSwiftUIStreamReplay-\(UUID().uuidString)", isDirectory: true)
        )
        let model = HarnessModel()
        configure(model)
        let host = UIHostingController(rootView: Harness(
            model: model,
            displaySetting: sharedSettings.displaySetting,
            generativeUiSetting: sharedSettings.snapshot.agentRuntime.generativeUi,
            workspaceStore: workspaceStore
        ))
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return Fixture(model: model, window: window, host: host)
    }

    // MARK: - Fixture content

    func makeUserMessage(_ text: String) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.user,
            parts: [UIMessagePart.Text(text: text, metadata: nil)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    func makeAssistantMessage(
        id: KotlinUuid = KotlinUuid.companion.random(),
        text: String,
        finished: Bool
    ) -> UIMessage {
        UIMessage(
            id: id,
            role: MessageRole.assistant,
            parts: [UIMessagePart.Text(text: text, metadata: nil)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: finished ? chatNowLocalDateTime() : nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    func makeCompletedImageMessage(
        id: KotlinUuid,
        toolCallID: String
    ) -> UIMessage {
        let leadingText = (0..<64).map { paragraph in
            "第 \(paragraph) 段：生成前的长说明用于验证图片锚点必须落到 tool part，而不是整条超高消息的中点。"
        }.joined(separator: "\n\n")
        return UIMessage(
            id: id,
            role: MessageRole.assistant,
            parts: [
                UIMessagePart.Text(text: leadingText, metadata: nil),
                UIMessagePart.Tool(
                    toolCallId: toolCallID,
                    toolName: "generate_image",
                    input: #"{"prompt":"一座琥珀色的未来城市"}"#,
                    output: [UIMessagePart.Image(
                        url: "amber-image-generation://completed.png",
                        metadata: nil
                    )],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                ),
                UIMessagePart.Text(text: "图片后的简短说明。", metadata: nil)
            ],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    func longConversation(turns: Int) -> [UIMessage] {
        var messages: [UIMessage] = []
        for turn in 0..<turns {
            messages.append(makeUserMessage("问题 \(turn):请展开讲讲流式渲染分层的第 \(turn) 个机制细节。"))
            messages.append(makeAssistantMessage(
                text: "回答 \(turn):缓冲层平滑释放 chunk,渲染层做增量解析与容错,滚动层维护三态机,视觉层负责逐词淡入。每层单一所有者,症状归层后自底向上修。",
                finished: true
            ))
        }
        return messages
    }

    func longHistoricalConversation() -> [UIMessage] {
        var messages: [UIMessage] = []
        for turn in 0..<2 {
            messages.append(makeUserMessage("历史问题 \(turn)：请完整展开这一轮分析。"))
            var text = "## 历史长回复 \(turn)\n\n"
            for paragraph in 0..<90 {
                text += "第 \(paragraph) 段：这一段用于稳定复现长历史消息在双向浏览时的真实布局测量。"
                text += "滚动层只应改变可见位置，不能因为历史行重新物化而改写整条时间线的高度事实。\n\n"
            }
            messages.append(makeAssistantMessage(text: text, finished: true))
        }
        messages.append(makeUserMessage("当前问题：继续总结。"))
        messages.append(makeAssistantMessage(
            text: "当前回复已经完成，下面开始浏览历史内容。",
            finished: true
        ))
        return messages
    }

    func pump(seconds: TimeInterval, onTick: (() -> Void)? = nil) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            onTick?()
        }
    }

    /// 泵到谓词成立或超时。注意不能用「连续两次采样一致」当收敛判据——
    /// 入场重试梯(50-350ms)/settle(0.4-1s)期间存在长于采样间隔的静默段,
    /// 稳定 ≠ 终态,会提前返回中间态造成假红。
    @discardableResult
    func pumpUntil(
        timeout: TimeInterval,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            pump(seconds: 0.05)
        }
        return predicate()
    }

    func percentile(_ values: [CGFloat], percentile: Double) -> CGFloat {
        guard !values.isEmpty else { return .greatestFiniteMagnitude }
        let sorted = values.sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int((Double(sorted.count) * percentile).rounded(.up)) - 1)
        )
        return sorted[index]
    }
}
