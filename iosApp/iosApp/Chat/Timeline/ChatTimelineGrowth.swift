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
        ChatRenderProbe.record("growth-add")
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
        // Layout has already grown. Apply that compensation immediately, then
        // let the native offset animation interpolate back at the display rate.
        // Keeping both operations as built-in effects avoids a custom SwiftUI
        // GeometryEffect evaluation for every presentation frame.
        content
            .offset(y: growth.totalGrowth)
            .transaction { $0.animation = nil }
            // Prevent coalescing the immediate compensation with its animated
            // inverse; otherwise the first line jumps instead of moving up.
            .geometryGroup()
            .offset(y: -growth.totalGrowth)
    }
}
