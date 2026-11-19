import SwiftUI
import Combine
import UIKit

/// The timeline takes its natural height immediately. Only its presentation
/// transform interpolates, keeping bottom-anchored text moving at the old pace.
@MainActor
final class ChatTimelineGrowth: ObservableObject, Equatable {
    nonisolated static func == (lhs: ChatTimelineGrowth, rhs: ChatTimelineGrowth) -> Bool {
        lhs === rhs
    }
    @Published private(set) var totalGrowth: CGFloat = 0
    var onContentGrew: ((CGFloat) -> Void)?
    private var enabled = false
    private weak var presentationLayer: CALayer?
    private static let animationKey = "amber.timeline-growth"

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            presentationLayer?.removeAnimation(forKey: Self.animationKey)
        }
    }

    func reset() {
        enabled = false
        presentationLayer?.removeAnimation(forKey: Self.animationKey)
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
        totalGrowth += delta
        // Bottom-anchored streaming bubbles must keep their bottom edge at a fixed
        // distance above the composer while new content pushes the top upward.
        // Applying a positive downward `transform.translation.y` on the already-grown
        // content layer pushed the bubble's bottom border downward into the composer
        // and then slid it back up; instead, notify the scroll driver to lock the
        // bottom offset synchronously in the same layout pass.
        presentationLayer?.removeAnimation(forKey: Self.animationKey)
        onContentGrew?(delta)
    }

    func attachPresentationLayer(_ layer: CALayer?) {
        guard presentationLayer !== layer else { return }
        presentationLayer?.removeAnimation(forKey: Self.animationKey)
        presentationLayer = layer
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
    let growth: ChatTimelineGrowth

    func body(content: Content) -> some View {
        content.background(ChatTimelineGrowthLayerBridge(growth: growth))
    }
}

/// Resolves just the scrolling content container. The additive animation does
/// not write UIScrollView offsets, content size or any model-layer transform.
private struct ChatTimelineGrowthLayerBridge: UIViewRepresentable {
    let growth: ChatTimelineGrowth

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.growth = growth
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.growth = growth
        view.resolve()
    }

    static func dismantleUIView(_ view: Probe, coordinator: ()) {
        view.growth?.attachPresentationLayer(nil)
    }

    final class Probe: UIView {
        weak var growth: ChatTimelineGrowth?
        override func didMoveToWindow() { super.didMoveToWindow(); resolve() }
        override func didMoveToSuperview() { super.didMoveToSuperview(); resolve() }
        override func layoutSubviews() { super.layoutSubviews(); resolve() }

        func resolve() {
            guard window != nil else { return }
            var candidate: UIView = self
            while let parent = candidate.superview {
                if parent is UIScrollView {
                    growth?.attachPresentationLayer(candidate.layer)
                    return
                }
                candidate = parent
            }
        }
    }
}
