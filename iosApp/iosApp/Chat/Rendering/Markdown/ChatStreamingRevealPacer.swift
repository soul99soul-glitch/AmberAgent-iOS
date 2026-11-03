import SwiftUI

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
struct ChatStreamingRevealPacer<Content: View>: View {
    /// 上游已到达的全部文本。
    let text: String
    /// 是否仍在流式接收。
    let isStreaming: Bool
    /// 无障碍「减弱动态效果」：不做逐字推进，也不做高度过渡。
    let reduceMotion: Bool
    @ViewBuilder let content: (String) -> Content

    @State private var revealedCount = 0
    /// 是否处于需要逐字推进或收尾排空的会话期。
    /// 历史非流式行在 `init` 时直接为 `false`，首帧即直接渲染完整 `text`，
    /// 绝不经过「先挂空串 `""` 再在 `onAppear` 二次刷全文」的双渲染路径。
    @State private var isActivelyPacing: Bool
    /// 内容自然高度（不含裁剪）。
    @State private var contentHeight: CGFloat = 0
    /// 当前实际占位高度：朝 `contentHeight` 平滑逼近。
    @State private var displayedHeight: CGFloat = 0

    init(
        text: String,
        isStreaming: Bool,
        reduceMotion: Bool,
        @ViewBuilder content: @escaping (String) -> Content
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.reduceMotion = reduceMotion
        self.content = content
        let initialPacing = isStreaming && !reduceMotion
        self._isActivelyPacing = State(initialValue: initialPacing)
    }

    /// 是否仍按帧吐字。流式结束后若还有尾巴没吐完，继续按同一节奏吐。
    private var isPacing: Bool { isStreaming && !reduceMotion }

    var body: some View {
        let activePacing = !reduceMotion && (isStreaming || isActivelyPacing)
        let displayedText: String
        let heightTransitionActive: Bool
        if activePacing {
            let totalCount = text.count
            let clampedCount = min(max(0, revealedCount), totalCount)
            displayedText = clampedCount < totalCount ? String(text.prefix(clampedCount)) : text
            heightTransitionActive = clampedCount < totalCount || isStreaming
        } else {
            displayedText = text
            heightTransitionActive = false
        }

        return content(displayedText)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                contentHeight = height
                syncDisplayedHeight(heightTransitionActive: heightTransitionActive)
            }
            .frame(height: heightTransitionActive ? displayedHeight : nil, alignment: .top)
            .clipped()
            .onAppear {
                guard isPacing, revealedCount == 0 else { return }
                let totalCount = text.count
                // 流式中途重进入：只补尾部，不要把已有正文整段重打。
                revealedCount = max(0, totalCount - ChatStreamingRevealTiming.reentryTailBudget)
                displayedHeight = contentHeight
                isActivelyPacing = true
            }
            .task(id: PacingKey(text: text, isStreaming: isStreaming, reduceMotion: reduceMotion)) {
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
        if isStreaming && !isActivelyPacing {
            isActivelyPacing = true
        }
        // 单次计算当前块的字符总数，避免每 16ms tick 在循环条件与步长里重复 3 次 O(n) 遍历。
        let totalCount = text.count
        while !Task.isCancelled, revealedCount < totalCount {
            // 全程同一节奏：流式结束后依然按同一速率自然吐完，绝不提速、绝不一次性刷出。
            // 收尾翻倍（4→8）会让用户听到/看到一次速度突跳，反而破坏节奏。
            let step = ChatStreamingRevealTiming.step(remaining: totalCount - revealedCount)
            revealedCount = min(revealedCount + step, totalCount)
            try? await Task.sleep(nanoseconds: ChatStreamingRevealTiming.tickNanos)
        }
        if !Task.isCancelled, !isStreaming, revealedCount >= totalCount, isActivelyPacing {
            isActivelyPacing = false
        }
    }

    private struct PacingKey: Equatable {
        let text: String
        let isStreaming: Bool
        let reduceMotion: Bool
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
}
