import SwiftUI

/// Reuse a row's measured size while its content and proposal are unchanged.
/// Unlike lazy history, this preserves both its exact height and mounted Markdown views.
struct ChatTimelineRowLayout: Layout {
    var messageID: String = "all"
    struct Proposal: Hashable {
        let width: CGFloat?
        let height: CGFloat?

        init(_ proposal: ProposedViewSize) {
            width = proposal.width
            height = proposal.height
        }
    }

    struct Cache {
        var sizes: [Proposal: CGSize] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        ChatRenderProbe.record("layout-invalidate", id: messageID)
        // SwiftUI invalidates on child changes, including asynchronous media/layout updates.
        cache.sizes.removeAll(keepingCapacity: true)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        ChatRenderProbe.record("layout-request", id: messageID)
        guard let row = subviews.first else { return .zero }
        let key = Proposal(proposal)
        if let size = cache.sizes[key] { return size }
        ChatRenderProbe.record("layout-measure", id: messageID)
        let size = row.sizeThatFits(proposal)
        cache.sizes[key] = size
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        ChatRenderProbe.record("layout-place", id: messageID)
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }
}
