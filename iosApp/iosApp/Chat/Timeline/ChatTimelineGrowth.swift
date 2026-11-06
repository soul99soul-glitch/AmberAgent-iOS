import SwiftUI
import Combine

/// The timeline takes its natural height immediately. Only its presentation
/// transform interpolates, keeping bottom-anchored text moving at the old pace.
@MainActor
final class ChatTimelineGrowth: ObservableObject {
    @Published private(set) var totalGrowth: CGFloat = 0
    private var enabled = false

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
    }

    func reset() {
        enabled = false
        guard totalGrowth != 0 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { totalGrowth = 0 }
    }

    func contentGrew(by delta: CGFloat) {
        guard enabled, delta > 0 else { return }
        #if DEBUG
        ChatRenderProbe.record("growth-transform")
        #endif
        withAnimation(.linear(duration: ChatStreamingRevealTiming.heightSettleSeconds)) {
            totalGrowth += delta
        }
    }
}

private struct ChatTimelineGrowthKey: EnvironmentKey {
    static let defaultValue: ChatTimelineGrowth? = nil
}

extension EnvironmentValues {
    var chatTimelineGrowth: ChatTimelineGrowth? {
        get { self[ChatTimelineGrowthKey.self] }
        set { self[ChatTimelineGrowthKey.self] = newValue }
    }
}

struct ChatTimelineGrowthModifier: ViewModifier {
    @ObservedObject var growth: ChatTimelineGrowth

    func body(content: Content) -> some View {
        content.modifier(ChatTimelineGrowthEffect(
            destination: growth.totalGrowth, presented: growth.totalGrowth
        ))
    }
}

/// `destination` jumps with the real layout; `presented` interpolates from the
/// previous presentation value, including overlapping line-growth animations.
/// GeometryEffect never changes the layout proposal or scroll content size.
private struct ChatTimelineGrowthEffect: GeometryEffect {
    let destination: CGFloat
    var presented: CGFloat

    var animatableData: CGFloat {
        get { presented }
        set { presented = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 0, y: destination - presented))
    }
}
