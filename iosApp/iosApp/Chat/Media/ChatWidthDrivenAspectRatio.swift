import SwiftUI

struct ChatWidthDrivenAspectRatio: ViewModifier {
    let aspectRatio: CGFloat

    func body(content: Content) -> some View {
        ChatWidthAspectLayout(aspectRatio: aspectRatio) {
            content
        }
    }
}

private struct ChatWidthAspectLayout: Layout {
    let aspectRatio: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let safeAspect = max(aspectRatio, 0.1)
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite, proposed > 0 {
            width = proposed
        } else {
            // 宽度 proposal 缺失/无穷时的兜底,等效旧实现的 220 高 fallback。
            width = 220 * safeAspect
        }
        return CGSize(width: width, height: width / safeAspect)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(
                at: CGPoint(x: bounds.midX, y: bounds.midY),
                anchor: .center,
                proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
            )
        }
    }
}

