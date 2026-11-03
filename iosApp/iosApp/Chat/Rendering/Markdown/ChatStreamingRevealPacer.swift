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
    /// 内容自然高度（不含裁剪）。
    @State private var contentHeight: CGFloat = 0
    /// 当前实际占位高度：朝 `contentHeight` 平滑逼近。
    @State private var displayedHeight: CGFloat = 0

    /// 是否仍按帧吐字。流式结束后若还有尾巴没吐完，继续按同一节奏吐。
    private var isPacing: Bool { isStreaming && !reduceMotion }

    /// 平滑高度 + 裁剪是否仍生效。
    /// 关键：上游 `isStreaming` 一关，尾巴可能还没吐完；此时若立刻解除平滑容器，
    /// 剩余文字会整段冒出、且高度一次性跳到自然值。所以这里必须延续到尾巴吐完。
    private var heightTransitionActive: Bool {
        guard !reduceMotion else { return false }
        return revealedCount < text.count || isStreaming
    }

    private var displayedCount: Int {
        min(max(0, revealedCount), text.count)
    }

    var body: some View {
        content(String(text.prefix(displayedCount)))
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                contentHeight = height
                syncDisplayedHeight()
            }
            .frame(height: heightTransitionActive ? displayedHeight : nil, alignment: .top)
            .clipped()
            .onAppear {
                guard revealedCount == 0 else { return }
                if isPacing {
                    // 流式中途重进入：只补尾部，不要把已有正文整段重打。
                    revealedCount = max(0, text.count - ChatStreamingRevealTiming.reentryTailBudget)
                    displayedHeight = contentHeight
                } else {
                    revealedCount = text.count
                }
            }
            .task(id: PacingKey(text: text, isStreaming: isStreaming, reduceMotion: reduceMotion)) {
                await drain()
            }
    }

    /// 内容长高时把占位高度平滑推上去；缩短（收口）直接跟上，避免留白。
    private func syncDisplayedHeight() {
        guard heightTransitionActive else {
            displayedHeight = contentHeight
            return
        }
        guard contentHeight > displayedHeight else {
            displayedHeight = contentHeight
            return
        }
        withAnimation(.linear(duration: ChatStreamingRevealTiming.heightSettleSeconds)) {
            displayedHeight = contentHeight
        }
    }

    /// 小步推进直到追平全文。全程同一节奏：流式结束后不提速、不一次性刷出。
    private func drain() async {
        guard !reduceMotion else {
            revealedCount = text.count
            return
        }
        while !Task.isCancelled, revealedCount < text.count {
            // 全程同一节奏：流式结束后依然按同一速率自然吐完，绝不提速、绝不一次性刷出。
            // 收尾翻倍（4→8）会让用户听到/看到一次速度突跳，反而破坏节奏。
            let step = ChatStreamingRevealTiming.step(remaining: text.count - revealedCount)
            revealedCount = min(revealedCount + step, text.count)
            try? await Task.sleep(nanoseconds: ChatStreamingRevealTiming.tickNanos)
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
