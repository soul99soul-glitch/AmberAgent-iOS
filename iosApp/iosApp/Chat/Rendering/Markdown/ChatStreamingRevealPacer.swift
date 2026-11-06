import SwiftUI

private struct ChatPacesStreamingTextBlocksKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var chatPacesStreamingTextBlocks: Bool {
        get { self[ChatPacesStreamingTextBlocksKey.self] }
        set { self[ChatPacesStreamingTextBlocksKey.self] = newValue }
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
    @ViewBuilder let content: (String) -> Content

    @Environment(\.chatTimelineGrowth) private var timelineGrowth
    @State private var revealedUTF16Count = 0
    /// 是否处于需要逐字推进或收尾排空的会话期。
    /// 历史非流式行在 `init` 时直接为 `false`，首帧即直接渲染完整 `text`，
    /// 绝不经过「先挂空串 `""` 再在 `onAppear` 二次刷全文」的双渲染路径。
    @State private var isActivelyPacing: Bool
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
        self.text = text
        self.isStreaming = isStreaming
        self.reduceMotion = reduceMotion
        self.initiallyRevealedUTF16Count = initiallyRevealedUTF16Count
        self.completionFeedback = completionFeedback
        self.completionRunID = completionFeedback?.runID
        self.messageID = messageID
        self.textPartIndex = textPartIndex
        self.content = content
        self._revealedUTF16Count = State(initialValue: initiallyRevealedUTF16Count ?? 0)
        let initialPacing = (isStreaming || pacePendingText) && !reduceMotion
        self._isActivelyPacing = State(initialValue: initialPacing)
    }

    /// 是否仍按帧吐字。流式结束后若还有尾巴没吐完，继续按同一节奏吐。
    private var isPacing: Bool { isStreaming && !reduceMotion }

    var body: some View {
        let activePacing = !reduceMotion && (isStreaming || isActivelyPacing)
        // Markdown 表格在 `ChatStreamingBlockMarkdownView` 内部已有稳定前缀 + 尾部节流分块策略；
        // 若外层再按 60fps 逐字切片并对整张 `TableView` 施加 `.frame(height: displayedHeight)` 动画，
        // 会导致数百个单元格每 16ms 触发多遍 `TableLayout` 与滚动几何反馈环（单帧卡死 200-330ms）。
        let bypassPacingForTable = activePacing && pacerBox.containsTable(in: text)
        let hasPendingReveal = isStreaming || (activePacing && !bypassPacingForTable && revealedUTF16Count < text.utf16.count)
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
            heightTransitionActive = clampedUTF16 < totalUTF16 || isStreaming
        } else {
            displayedText = text
            heightTransitionActive = false
        }

        return content(displayedText)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                activePacing && !bypassPacingForTable ? proxy.size.height : 0
            } action: { height in
                guard activePacing && !bypassPacingForTable else { return }
                if let timelineGrowth {
                    let previous = pacerBox.naturalHeight
                    pacerBox.naturalHeight = height
                    let prefilledFirstFrame = previous == 0 && initiallyRevealedUTF16Count != nil &&
                        revealedUTF16Count >= text.utf16.count
                    if heightTransitionActive && !prefilledFirstFrame {
                        timelineGrowth.contentGrew(by: height - previous)
                    }
                    return
                }
                let isFirstMeasurement = contentHeight == 0
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
            .transformPreference(ChatStreamingRevealProgressKey.self) { progress in
                progress.isMounted = true
                progress.hasPendingReveal = progress.hasPendingReveal || hasPendingReveal
            }
            .onPreferenceChange(ChatStreamingRevealProgressKey.self) { progress in
                guard progress.isMounted, !progress.hasPendingReveal,
                      let completionRunID, let messageID else { return }
                completionFeedback?.didDrain(
                    runID: completionRunID, messageID: messageID, partIndex: textPartIndex, text: text
                )
            }
            .onAppear {
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
            if isActivelyPacing { isActivelyPacing = false }
            return
        }
        guard isStreaming || isActivelyPacing else {
            return
        }
        if pacerBox.containsTable(in: text) {
            revealedUTF16Count = text.utf16.count
            // 分块子树持有各正文尾块的排空状态。完成事件后仍保留委托，
            // 包括只随最终快照新增的正文，不能拆掉其 pacer 后一次性露出全文。
            return
        }
        if isStreaming && !isActivelyPacing {
            isActivelyPacing = true
        }
        let totalUTF16 = text.utf16.count
        while !Task.isCancelled, revealedUTF16Count < totalUTF16 {
            let nextUTF16 = ChatStreamingRevealTiming.nextStepUTF16Offset(
                in: text,
                fromUTF16Offset: revealedUTF16Count
            )
            if nextUTF16 <= revealedUTF16Count {
                revealedUTF16Count = totalUTF16
                break
            }
            revealedUTF16Count = min(nextUTF16, totalUTF16)
            try? await Task.sleep(nanoseconds: ChatStreamingRevealTiming.tickNanos)
        }
        if !Task.isCancelled, !isStreaming, revealedUTF16Count >= totalUTF16, isActivelyPacing {
            isActivelyPacing = false
        }
    }

    private struct PacingKey: Equatable {
        let targetUTF16Count: Int
        let isStreaming: Bool
        let reduceMotion: Bool
    }
}

private final class ChatStreamingRevealPacerBox {
    var naturalHeight: CGFloat = 0
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
