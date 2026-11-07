import SwiftUI
import UIKit

private struct ChatPacesStreamingTextBlocksKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ChatIsActivelyPacingRevealKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var chatPacesStreamingTextBlocks: Bool {
        get { self[ChatPacesStreamingTextBlocksKey.self] }
        set { self[ChatPacesStreamingTextBlocksKey.self] = newValue }
    }

    var chatIsActivelyPacingReveal: Bool {
        get { self[ChatIsActivelyPacingRevealKey.self] }
        set { self[ChatIsActivelyPacingRevealKey.self] = newValue }
    }
}

/// A subtree publishes only pending/settled transitions, never per-frame text or offsets.
struct ChatStreamingRevealProgress: Equatable {
    var isMounted = false
    var hasPendingReveal = false
}

struct ChatStreamingRevealProgressKey: PreferenceKey {
    static let defaultValue = ChatStreamingRevealProgress()

    static func reduce(value: inout ChatStreamingRevealProgress, nextValue: () -> ChatStreamingRevealProgress) {
        let next = nextValue()
        value.isMounted = value.isMounted || next.isMounted
        value.hasPendingReveal = value.hasPendingReveal || next.hasPendingReveal
    }
}

/// A value writer keeps an unchanged pending flag stable through token updates.
/// A background sibling merges with descendant writers via the key's OR reduce.
struct ChatStreamingRevealProgressModifier: ViewModifier {
    let progress: ChatStreamingRevealProgress

    func body(content: Content) -> some View {
        content.background {
            Color.clear.frame(width: 0, height: 0)
                .preference(key: ChatStreamingRevealProgressKey.self, value: progress)
                .accessibilityHidden(true)
        }
    }
}

/// 流式正文的平滑吐字器 + 平滑高度。
///
/// 三个问题一起解决：
///
/// 1. **文字逐字连续吐出**：上游 delta 成块到达，直接整块上屏会一次撑高多行。
///    这里按帧小步推进已显示字数，文字以正常字色连续出现。
///
/// 2. **流式结束时绝不一次性刷出剩余文字**：网络流关闭后仍按节奏吐到追平全文
///    再落到静态终态，避免尾部突然冒出一大段。
///
/// 3. **消除折行时的高度阶梯跳变**：文本换行会让布局高度单帧 +一整行（约 22pt），
///    这是排版固有属性、无法靠逐字插值消除。所以给气泡占位高度加一层平滑：
///    内容仍按自然高度排版（`fixedSize` 垂直方向不管提议），外层只显示
///    `displayedHeight` 这么高（`alignment: .top` + `clipped`），并在内容长高时
///    用短促线性动画把 `displayedHeight` 推上去。
///
///    每帧只长高一点点，配合底部锚点（`.sizeChanges` 或原生贴底）同帧上移同样的量：
///    底边不动，已有文字与上方历史平滑上浮，新增的一行从底边缓缓露出，
///    而不是整屏 0ms 瞬移一行。
// Native timeline supplies a growth owner: the layout remains natural-sized and
// the content layer performs the same 0.14s movement. Other hosts keep the
// existing local-height transition until they opt into that owner.
struct ChatStreamingRevealPacer<Content: View>: View {
    /// 上游已到达的全部文本。
    let text: String
    /// 是否仍在流式接收。
    let isStreaming: Bool
    /// 无障碍「减弱动态效果」：不做逐字推进，也不做高度过渡。
    let reduceMotion: Bool
    /// 分块前已显示的正文保持原样；新尾块即使随最终快照到达也需排空。
    private let initiallyRevealedUTF16Count: Int?
    private let completionFeedback: ChatCompletionFeedback?
    private let completionRunID: String?
    private let messageID: String?
    private let textPartIndex: Int
    @ViewBuilder let content: (String, Bool) -> Content

    @Environment(\.chatTimelineGrowth) private var timelineGrowth
    @State private var revealedUTF16Count = 0
    /// 是否处于需要逐字推进或收尾排空的会话期。
    /// 历史非流式行在 `init` 时直接为 `false`，首帧即直接渲染完整 `text`，
    /// 绝不经过「先挂空串 `""` 再在 `onAppear` 二次刷全文」的双渲染路径。
    @State private var isActivelyPacing: Bool
    /// 锁定本 pacer 所属的 runID，防止同会话并发新任务覆盖当前回复的完成反馈归属。
    @State private var latchedCompletionRunID: String?
    /// 内容自然高度（不含裁剪）。
    @State private var contentHeight: CGFloat = 0
    /// 当前实际占位高度：朝 `contentHeight` 平滑逼近。
    @State private var displayedHeight: CGFloat = 0
    /// 增量维护的表格检测器：避免在 `body` 中产生状态写回或全量扫描。
    @State private var pacerBox = ChatStreamingRevealPacerBox()

    init(
        text: String,
        isStreaming: Bool,
        reduceMotion: Bool,
        initiallyRevealedUTF16Count: Int? = nil,
        pacePendingText: Bool = false,
        completionFeedback: ChatCompletionFeedback? = nil,
        messageID: String? = nil,
        textPartIndex: Int = 0,
        @ViewBuilder content: @escaping (String) -> Content
    ) {
        self.init(
            text: text,
            isStreaming: isStreaming,
            reduceMotion: reduceMotion,
            initiallyRevealedUTF16Count: initiallyRevealedUTF16Count,
            pacePendingText: pacePendingText,
            completionFeedback: completionFeedback,
            messageID: messageID,
            textPartIndex: textPartIndex,
            content: { revealedText, _ in content(revealedText) }
        )
    }

    init(
        text: String,
        isStreaming: Bool,
        reduceMotion: Bool,
        initiallyRevealedUTF16Count: Int? = nil,
        pacePendingText: Bool = false,
        completionFeedback: ChatCompletionFeedback? = nil,
        messageID: String? = nil,
        textPartIndex: Int = 0,
        @ViewBuilder content: @escaping (String, Bool) -> Content
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.reduceMotion = reduceMotion
        self.initiallyRevealedUTF16Count = initiallyRevealedUTF16Count
        self.completionFeedback = completionFeedback
        let resolvedRunID = completionFeedback?.runID(forMessageID: messageID) ?? completionFeedback?.untrackedCurrentRunID()
        self.completionRunID = resolvedRunID
        self.messageID = messageID
        self.textPartIndex = textPartIndex
        self.content = content
        self._revealedUTF16Count = State(initialValue: initiallyRevealedUTF16Count ?? 0)
        let initialPacing = (isStreaming || pacePendingText) && !reduceMotion
        self._isActivelyPacing = State(initialValue: initialPacing)
        self._latchedCompletionRunID = State(initialValue: resolvedRunID)
    }

    /// 是否仍按帧吐字。流式结束后若还有尾巴没吐完，继续按同一节奏吐。
    private var isPacing: Bool { isStreaming && !reduceMotion }

    var body: some View {
        let activePacing = !reduceMotion && (isStreaming || isActivelyPacing)
        // Markdown 表格在 `ChatStreamingBlockMarkdownView` 内部已有稳定前缀 + 尾部节流分块策略；
        // 若外层再按 60fps 逐字切片并对整张 `TableView` 施加 `.frame(height: displayedHeight)` 动画，
        // 会导致数百个单元格每 16ms 触发多遍 `TableLayout` 与滚动几何反馈环（单帧卡死 200-330ms）。
        let bypassPacingForTable = activePacing && pacerBox.containsTable(in: text)
        let localPendingReveal = activePacing && !bypassPacingForTable && (revealedUTF16Count < text.utf16.count || isActivelyPacing)
        let hasPendingReveal = isStreaming || localPendingReveal
        let isActivelyRevealing = isStreaming || localPendingReveal
        let displayedText: String
        let heightTransitionActive: Bool
        if activePacing && !bypassPacingForTable {
            let totalUTF16 = text.utf16.count
            let clampedUTF16 = min(max(0, revealedUTF16Count), totalUTF16)
            if clampedUTF16 < totalUTF16 {
                displayedText = ChatStreamingRevealTiming.slicedPrefix(of: text, utf16Count: clampedUTF16)
            } else {
                displayedText = text
            }
            heightTransitionActive = clampedUTF16 < totalUTF16 || isStreaming || isActivelyPacing
        } else {
            displayedText = text
            heightTransitionActive = false
        }
        let observesTimelineTableGrowth = timelineGrowth != nil && initiallyRevealedUTF16Count == nil && bypassPacingForTable
        let observesGeometry = (activePacing && !bypassPacingForTable) || observesTimelineTableGrowth

        return content(displayedText, isActivelyRevealing)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                observesGeometry ? proxy.size.height : 0
            } action: { height in
                guard observesGeometry else { return }
                if let timelineGrowth {
                    // 当外层 pacer 已接管含表格整块的 timelineGrowth 观测时，内层分块 pacer 不重复累加。
                    guard initiallyRevealedUTF16Count == nil else { return }
                    #if DEBUG
                    ChatRenderProbe.record("pacer-native-height")
                    #endif
                    let previous = pacerBox.naturalHeight
                    pacerBox.naturalHeight = height
                    // A remounted live row already contains visible text. Its first
                    // measurement establishes the baseline, not new content growth.
                    let shouldGrowTimeline = heightTransitionActive || observesTimelineTableGrowth
                    if shouldGrowTimeline && previous > 0 && height > previous {
                        pacerBox.lastGrowthUptime = ProcessInfo.processInfo.systemUptime
                        timelineGrowth.contentGrew(by: height - previous)
                    }
                    return
                }
                let isFirstMeasurement = contentHeight == 0
                if !isFirstMeasurement && height > contentHeight {
                    pacerBox.lastGrowthUptime = ProcessInfo.processInfo.systemUptime
                }
                contentHeight = height
                if isFirstMeasurement,
                   initiallyRevealedUTF16Count != nil,
                   revealedUTF16Count >= text.utf16.count {
                    displayedHeight = height
                } else {
                    syncDisplayedHeight(heightTransitionActive: heightTransitionActive)
                }
            }
            .frame(
                height: timelineGrowth == nil && heightTransitionActive && (initiallyRevealedUTF16Count == nil || contentHeight > 0 || revealedUTF16Count < text.utf16.count)
                    ? displayedHeight : nil,
                alignment: .top
            )
            .clipped()
            .environment(\.chatPacesStreamingTextBlocks, bypassPacingForTable)
            .environment(\.chatIsActivelyPacingReveal, isActivelyRevealing)
            .modifier(ChatStreamingRevealProgressModifier(progress: .init(
                isMounted: true, hasPendingReveal: hasPendingReveal)))
            .onPreferenceChange(ChatStreamingRevealProgressKey.self) { progress in
                guard progress.isMounted, !progress.hasPendingReveal,
                      let messageID else { return }
                let resolvedRunID = completionFeedback?.runID(forMessageID: messageID)
                    ?? latchedCompletionRunID
                    ?? completionRunID
                    ?? completionFeedback?.untrackedCurrentRunID()
                guard let resolvedRunID else { return }
                completionFeedback?.didDrain(
                    runID: resolvedRunID, messageID: messageID, partIndex: textPartIndex, text: text
                )
            }
            .onAppear {
                if latchedCompletionRunID == nil {
                    latchedCompletionRunID = completionFeedback?.runID(forMessageID: messageID) ?? completionRunID ?? completionFeedback?.untrackedCurrentRunID()
                }
                guard isPacing, revealedUTF16Count == 0 else { return }
                guard initiallyRevealedUTF16Count == nil else { return }
                if pacerBox.containsTable(in: text) {
                    revealedUTF16Count = text.utf16.count
                    return
                }
                // 流式中途重进入：只补尾部，不要把已有正文整段重打。
                revealedUTF16Count = ChatStreamingRevealTiming.reentryStartUTF16Offset(
                    in: text,
                    tailCharacterBudget: ChatStreamingRevealTiming.reentryTailBudget
                )
                displayedHeight = contentHeight
                isActivelyPacing = true
            }
            .onChange(of: completionRunID) { _, newValue in
                if let newValue, isStreaming || latchedCompletionRunID == nil {
                    latchedCompletionRunID = newValue
                }
            }
            .task(
                id: PacingKey(
                    targetUTF16Count: activePacing && !bypassPacingForTable ? text.utf16.count : 0,
                    isStreaming: isStreaming,
                    reduceMotion: reduceMotion
                )
            ) {
                await drain()
            }
    }

    /// 内容长高时把占位高度平滑推上去；缩短（收口）直接跟上，避免留白。
    private func syncDisplayedHeight(heightTransitionActive: Bool) {
        guard heightTransitionActive else {
            if displayedHeight != contentHeight {
                displayedHeight = contentHeight
            }
            return
        }
        guard contentHeight > displayedHeight else {
            if displayedHeight != contentHeight {
                displayedHeight = contentHeight
            }
            return
        }
        withAnimation(.linear(duration: ChatStreamingRevealTiming.heightSettleSeconds)) {
            displayedHeight = contentHeight
        }
    }

    /// 小步推进直到追平全文。全程同一节奏：流式结束后不提速、不一次性刷出。
    private func drain() async {
        guard !reduceMotion else {
            pacerBox.lastTickUptime = nil
            if isActivelyPacing { isActivelyPacing = false }
            return
        }
        guard isStreaming || isActivelyPacing else {
            pacerBox.lastTickUptime = nil
            return
        }
        if pacerBox.containsTable(in: text) {
            pacerBox.lastTickUptime = nil
            revealedUTF16Count = text.utf16.count
            // 分块子树持有各正文尾块的排空状态。完成事件后仍保留委托，
            // 包括只随最终快照新增的正文，不能拆掉其 pacer 后一次性露出全文。
            return
        }
        if isStreaming && !isActivelyPacing {
            isActivelyPacing = true
        }
        let totalUTF16 = text.utf16.count
        guard revealedUTF16Count < totalUTF16 else {
            pacerBox.lastTickUptime = nil
            await settleTailGrowthIfNeeded(totalUTF16: totalUTF16)
            return
        }
        let tickSeconds = Double(ChatStreamingRevealTiming.tickNanos) / 1_000_000_000
        let maxCatchUpTicks = ChatStreamingRevealTiming.maxCatchUpTicksPerWake
        let maxCreditWindow = Double(maxCatchUpTicks) * tickSeconds
        while !Task.isCancelled, revealedUTF16Count < totalUTF16 {
            let now = ProcessInfo.processInfo.systemUptime
            let stepsToAdvance: Int
            if let lastTick = pacerBox.lastTickUptime {
                let elapsed = now - lastTick
                if elapsed < tickSeconds {
                    let remainingNanos = UInt64(max(1, (tickSeconds - elapsed) * 1_000_000_000))
                    try? await Task.sleep(nanoseconds: remainingNanos)
                    guard !Task.isCancelled else { return }
                }
                let wakeUptime = ProcessInfo.processInfo.systemUptime
                let totalElapsed = max(0, wakeUptime - lastTick)
                let dueTicks = max(1, Int(totalElapsed / tickSeconds))
                stepsToAdvance = min(maxCatchUpTicks, dueTicks)
                let advancedSeconds = Double(stepsToAdvance) * tickSeconds
                pacerBox.lastTickUptime = max(lastTick + advancedSeconds, wakeUptime - maxCreditWindow)
            } else {
                stepsToAdvance = 1
                pacerBox.lastTickUptime = now
            }

            var nextUTF16 = revealedUTF16Count
            for _ in 0..<stepsToAdvance {
                guard nextUTF16 < totalUTF16 else { break }
                let candidate = ChatStreamingRevealTiming.nextStepUTF16Offset(
                    in: text,
                    fromUTF16Offset: nextUTF16
                )
                if candidate <= nextUTF16 {
                    nextUTF16 = totalUTF16
                    break
                }
                nextUTF16 = min(candidate, totalUTF16)
            }
            revealedUTF16Count = nextUTF16
            ChatRenderProbe.record("pacer-tick")
            if revealedUTF16Count >= totalUTF16 {
                pacerBox.lastTickUptime = nil
                break
            }
            try? await Task.sleep(nanoseconds: ChatStreamingRevealTiming.tickNanos)
        }
        await settleTailGrowthIfNeeded(totalUTF16: totalUTF16)
    }

    private func settleTailGrowthIfNeeded(totalUTF16: Int) async {
        guard !Task.isCancelled, !isStreaming, revealedUTF16Count >= totalUTF16, isActivelyPacing else {
            return
        }
        pacerBox.lastTickUptime = nil
        if let lastGrowth = pacerBox.lastGrowthUptime {
            let remaining = ChatStreamingRevealTiming.heightSettleSeconds - (ProcessInfo.processInfo.systemUptime - lastGrowth)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
        guard !Task.isCancelled, !isStreaming, revealedUTF16Count >= text.utf16.count else { return }
        isActivelyPacing = false
    }

    private struct PacingKey: Equatable {
        let targetUTF16Count: Int
        let isStreaming: Bool
        let reduceMotion: Bool
    }
}

private final class ChatStreamingRevealPacerBox {
    var naturalHeight: CGFloat = 0
    var lastTickUptime: TimeInterval?
    var lastGrowthUptime: TimeInterval?
    private var tableDetector = ChatStreamingTableDetectionState()

    func containsTable(in text: String) -> Bool {
        tableDetector.update(with: text)
        return tableDetector.containsTable
    }
}

/// pacer 的调节参数。放在非泛型类型里：Swift 不允许泛型类型持有静态存储属性。
enum ChatStreamingRevealTiming {
    /// 约 60fps 一拍。
    static let tickNanos: UInt64 = 16_000_000
    /// 主线程掉帧导致单次唤醒跨多拍时，单次唤醒最多补拍的逻辑拍数上限。
    static let maxCatchUpTicksPerWake = 4
    /// 高度增长的过渡时长：短到不拖沓，长到足以盖住单帧一整行的台阶。
    static let heightSettleSeconds: Double = 0.14
    /// 中途重进入时只补齐尾部这么多个字，避免把已有正文整段重打。
    static let reentryTailBudget = 40
    /// 每拍推进上限。固定值：流式期与收尾期一致，不做收尾提速。
    static let maxStepPerTick = 4

    /// 单拍推进字数：积压越多步长越大，但上限恒为 `maxStepPerTick`。
    /// 供单测锁住「收尾不提速」这条契约。
    static func step(remaining: Int, maxStep: Int = maxStepPerTick) -> Int {
        guard remaining > 0 else { return 0 }
        return min(max(remaining / 6, 1), maxStep)
    }

    /// O(1) UTF-16 索引切片并对齐到完整字素簇边界，避免每帧 `text.prefix(count)` 从头 O(n) 扫描全文。
    static func slicedPrefix(of text: String, utf16Count: Int) -> String {
        let totalUTF16 = text.utf16.count
        guard utf16Count > 0 else { return "" }
        guard utf16Count < totalUTF16 else { return text }
        let rawIndex = String.Index(utf16Offset: utf16Count, in: text)
        let alignedIndex = rawIndex < text.endIndex
            ? text.rangeOfComposedCharacterSequence(at: rawIndex).lowerBound
            : text.endIndex
        return String(text[..<alignedIndex])
    }

    /// 中途重进入时从尾部往回数 `tailCharacterBudget` 个字，时间复杂度 O(tailCharacterBudget) 常数级。
    static func reentryStartUTF16Offset(in text: String, tailCharacterBudget: Int) -> Int {
        guard tailCharacterBudget > 0, !text.isEmpty else { return text.utf16.count }
        var index = text.endIndex
        var remaining = tailCharacterBudget
        while remaining > 0, index > text.startIndex {
            index = text.index(before: index)
            remaining -= 1
        }
        return index.utf16Offset(in: text)
    }

    /// 基于当前 UTF-16 偏移向前最多探查 `maxStepPerTick * 6`（24）个字素簇，
    /// 既保持与 `step(remaining:)` 完全一致的吐字步长，又将每帧推进从 O(n) 降为 O(1)。
    static func nextStepUTF16Offset(
        in text: String,
        fromUTF16Offset currentUTF16: Int,
        maxStep: Int = maxStepPerTick
    ) -> Int {
        let totalUTF16 = text.utf16.count
        let clamped = min(max(0, currentUTF16), totalUTF16)
        guard clamped < totalUTF16 else { return totalUTF16 }
        let rawStart = String.Index(utf16Offset: clamped, in: text)
        let startIndex = rawStart < text.endIndex
            ? text.rangeOfComposedCharacterSequence(at: rawStart).lowerBound
            : text.endIndex
        guard startIndex < text.endIndex else { return totalUTF16 }

        let lookaheadCap = max(maxStep * 6, 1)
        var probe = startIndex
        var lookaheadCount = 0
        var stepIndices: [String.Index] = []
        stepIndices.reserveCapacity(maxStep)

        while probe < text.endIndex, lookaheadCount < lookaheadCap {
            probe = text.index(after: probe)
            lookaheadCount += 1
            if lookaheadCount <= maxStep {
                stepIndices.append(probe)
            }
        }

        let chosenStep = step(remaining: lookaheadCount, maxStep: maxStep)
        guard chosenStep > 0, !stepIndices.isEmpty else { return totalUTF16 }
        let targetIndex = stepIndices[min(chosenStep, stepIndices.count) - 1]
        return targetIndex.utf16Offset(in: text)
    }
}

/// Keeps the streaming subtree's graph updates local; the surrounding timeline
/// receives only a changed natural height. Non-native and settled history keep
/// their existing hosting path.
struct ChatStreamingGraphBoundary<Content: View>: View {
    let isStreaming: Bool
    let content: Content
    @State private var didStream: Bool
    @Environment(\.chatTimelineGrowth) private var growth

    init(isStreaming: Bool, @ViewBuilder content: () -> Content) {
        self.isStreaming = isStreaming
        self.content = content()
        _didStream = State(initialValue: isStreaming)
    }

    var body: some View {
        Group {
            if growth != nil && didStream {
                ChatStreamingGraphHost(content: content)
            } else {
                content
            }
        }
        .onChange(of: isStreaming) { _, active in
            if active && !didStream { didStream = true }
        }
    }
}

private struct ChatStreamingGraphHost<Content: View>: UIViewControllerRepresentable {
    let content: Content

    struct Root: View {
        let content: Content
        let environment: EnvironmentValues
        let heightChanged: (CGFloat) -> Void

        var body: some View {
            let _ = ChatRenderProbe.record("graph-host-root")
            content
                .environment(\.self, environment)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heightChanged($0) }
        }
    }

    final class SizedView: UIView {
        var height: CGFloat = 0
        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric, height: height)
        }
    }

    final class Controller: UIViewController {
        var host: UIHostingController<Root>!
        private var measuredWidth: CGFloat?
        private var hasMeasured = false
        private var sizedView: SizedView { view as! SizedView }

        init(content: Content, environment: EnvironmentValues) {
            super.init(nibName: nil, bundle: nil)
            ChatRenderProbe.record("graph-host-created")
            host = UIHostingController(rootView: root(content, environment: environment))
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { ChatRenderProbe.record("graph-host-released") }
        override func loadView() { view = SizedView() }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            addChild(host)
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            host.view.frame = view.bounds
        }
        func root(_ content: Content, environment: EnvironmentValues) -> Root {
            Root(content: content, environment: environment, heightChanged: { [weak self] height in
                guard let self, height.isFinite, height >= 0,
                      abs(sizedView.height - height) > 0.5 else { return }
                sizedView.height = height
                sizedView.invalidateIntrinsicContentSize()
                sizedView.setNeedsLayout()
            })
        }
        func update(_ content: Content, environment: EnvironmentValues) {
            host.rootView = root(content, environment: environment)
        }
        func size(width: CGFloat) -> CGSize {
            if !hasMeasured || measuredWidth.map({ abs($0 - width) > 0.5 }) == true {
                measuredWidth = width
                let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                sizedView.height = size.height
                hasMeasured = true
            }
            return CGSize(width: width, height: sizedView.height)
        }
    }

    func makeUIViewController(context: Context) -> Controller {
        Controller(content: content, environment: context.environment)
    }
    func updateUIViewController(_ controller: Controller, context: Context) {
        ChatRenderProbe.record("graph-host-update")
        controller.update(content, environment: context.environment)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: Controller, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return uiViewController.size(width: width)
    }
}
