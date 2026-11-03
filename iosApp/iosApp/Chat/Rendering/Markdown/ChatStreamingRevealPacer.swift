import SwiftUI

/// 流式正文的平滑吐字器。
///
/// 上游 delta 是**成块**到达的（几个词到一整句），直接整块塞进布局会造成
/// 「深色气泡框一次撑高 3 行，框里先是暗灰鬼影、过半秒才变亮」的观感，
/// 也就是用户说的「像小说/历史版本的刷新节奏」。
///
/// 这里把目标文本当作队列，按较高的固定节奏（约 50fps）小步推进已显示字数，
/// 让文字以正常实色连续吐出：折行时气泡随着逐字满行自然向上推升一行，
/// 而不是一次爆出多行。积压越多步长越大，流式结束时立即排空避免拖尾。
///
/// 不改变任何布局高度语义：它只决定「这一帧渲染多长的文本」，
/// 底部贴底仍由 `.sizeChanges` 在布局阶段完成。
struct ChatStreamingRevealPacer<Content: View>: View {
    /// 目标文本（上游已到达的全部内容）。
    let text: String
    /// 是否仍处于流式。非流式（历史消息/已完成）一次全量显示，不做任何延迟。
    let isStreaming: Bool
    /// 无障碍「减弱动态效果」开启时不做逐字推进，直接全量。
    let reduceMotion: Bool
    @ViewBuilder let content: (String) -> Content

    @State private var revealedCount: Int = 0

    /// 单位 1/50 秒。比 token 到达频率高一个量级，才能把块状增量摊平。
    private static var tickNanos: UInt64 { 20_000_000 }

    private var clampedRevealed: Int {
        min(max(0, revealedCount), text.count)
    }

    var body: some View {
        content(displayText)
            .onAppear { reconcile(animated: false) }
            .onChange(of: text) { _, _ in reconcile(animated: true) }
            .onChange(of: isStreaming) { _, streaming in
                if !streaming { revealedCount = text.count }
            }
            .task(id: TaskKey(text: text, streaming: isStreaming && !reduceMotion)) {
                guard isStreaming, !reduceMotion else {
                    revealedCount = text.count
                    return
                }
                await drain()
            }
    }

    private var displayText: String {
        let count = clampedRevealed
        guard count < text.count else { return text }
        return String(text.prefix(count))
    }

    /// 新文本到达时校正计数：只允许前进，避免重排/回退造成文字闪回。
    private func reconcile(animated: Bool) {
        guard isStreaming, !reduceMotion, animated else {
            revealedCount = text.count
            return
        }
        if revealedCount > text.count { revealedCount = text.count }
    }

    /// 小步推进直到追平；积压越多步长越大，收尾自动加速排空。
    private func drain() async {
        while !Task.isCancelled {
            let remaining = text.count - revealedCount
            guard remaining > 0 else { return }
            // 1…4 字/拍：小积压时几乎逐字，块状大增量时按比例追赶。
            let step = min(max(remaining / 6, 1), 4)
            revealedCount = min(revealedCount + step, text.count)
            try? await Task.sleep(nanoseconds: Self.tickNanos)
        }
    }

    /// `.task(id:)` 的重启依据：文本内容或流式状态的组合。
    private struct TaskKey: Equatable {
        let text: String
        let streaming: Bool
    }
}
