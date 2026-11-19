import SwiftUI

/// 冷启动骨架：会话历史还没从磁盘读上来时，用与最终对话页同构的中性占位顶住正文区。
///
/// 设计约束（unslop：chrome 保持安静，不加会呼吸的动效）：
/// - 静态气泡轮廓，不做 shimmer / pulse 循环；引导通常在一两百毫秒内结束，
///   任何循环动画都只会变成第二次动画。
/// - 只用主题中性色（surface / border / muted2），不引入新色相。
/// - 尺寸走 4pt 栅格，左右内缩与真实气泡列对齐，让位时不发生横向跳动。
/// - 内容靠底部对齐，和聊天「贴底」的真实布局一致。
struct ChatStartupSkeleton: View {
    private struct Slot {
        let isFromUser: Bool
        let widths: [CGFloat]
    }

    private let slots: [Slot] = [
        Slot(isFromUser: false, widths: [212, 148]),
        Slot(isFromUser: true, widths: [168]),
        Slot(isFromUser: false, widths: [244, 196, 116])
    ]

    var body: some View {
        // 自带不透明页面底，盖住下层尚未定型的欢迎空态。
        AmberThemePageBackground(surface: .app)
            .overlay(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                        messageRow(slot)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .ignoresSafeArea(edges: .bottom)
    }

    @ViewBuilder
    private func messageRow(_ slot: Slot) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if !slot.isFromUser {
                Circle()
                    .fill(AmberTheme.surface)
                    .overlay { Circle().strokeBorder(AmberTheme.border, lineWidth: 1) }
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: slot.isFromUser ? .trailing : .leading, spacing: 6) {
                ForEach(Array(slot.widths.enumerated()), id: \.offset) { _, width in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AmberTheme.muted2.opacity(0.22))
                        .frame(width: width, height: 12)
                }
            }
            .frame(maxWidth: slot.isFromUser ? 260 : .infinity, alignment: slot.isFromUser ? .trailing : .leading)
            if slot.isFromUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: slot.isFromUser ? .trailing : .leading)
    }
}
