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

    private var isPacing: Bool { isStreaming && !reduceMotion }

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
            .frame(height: isPacing ? displayedHeight : nil, alignment: .top)
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
        guard isPacing else {
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

    /// 小步推进直到追平全文。流式结束后不跳变，只是加快排空。
    private func drain() async {
        guard !reduceMotion else {
            revealedCount = text.count
            return
        }
        while !Task.isCancelled, revealedCount < text.count {
            let remaining = text.count - revealedCount
            // 积压越多步长越大；流式结束后上限放宽，让尾段尽快追平又不跳变。
            let ceiling = isStreaming ? 4 : 8
            let step = min(max(remaining / 6, 1), ceiling)
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
}
