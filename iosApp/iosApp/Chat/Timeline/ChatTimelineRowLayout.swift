import SwiftUI
import SwiftStreamingMarkdown

enum ChatTimelineRowLayoutInvalidation {
    nonisolated(unsafe) private static var isHookInstalled = false
    nonisolated(unsafe) private static var unscopedGeneration: UInt64 = 0
    nonisolated(unsafe) private static var rowGenerations: [String: UInt64] = [:]

    static func installHookIfNeeded() {
        guard !isHookInstalled else { return }
        isHookInstalled = true
        ParagraphLayoutInvalidationHook.onInvalidate = { messageID in
            if let messageID, !messageID.isEmpty {
                rowGenerations[messageID, default: 0] &+= 1
            } else {
                unscopedGeneration &+= 1
            }
        }
    }

    static func markRowDirty(_ messageID: String?) {
        installHookIfNeeded()
        guard let messageID, !messageID.isEmpty else {
            unscopedGeneration &+= 1
            return
        }
        rowGenerations[messageID, default: 0] &+= 1
    }

    static func currentToken(for messageID: String, layoutSignature: Int) -> Int {
        installHookIfNeeded()
        let prefs = IOSChatRenderPreferences.shared
        var hasher = Hasher()
        hasher.combine(unscopedGeneration)
        hasher.combine(rowGenerations[messageID, default: 0])
        hasher.combine(layoutSignature)
        hasher.combine(prefs.fontScale)
        hasher.combine(prefs.chatFont)
        hasher.combine(prefs.agentName)
        hasher.combine(prefs.appLanguage)
        return hasher.finalize()
    }
}

/// Reuse a row's measured size while its content and proposal are unchanged.
/// Unlike lazy history, this preserves both its exact height and mounted Markdown views.
struct ChatTimelineRowLayout: Layout {
    var messageID: String = "all"
    var tracksRowInvalidation: Bool = false
    var layoutSignature: Int = 0

    struct Proposal: Hashable {
        let widthKey: Int?

        init(_ proposal: ProposedViewSize) {
            if let width = proposal.width, width > 0, width.isFinite {
                widthKey = Int((width * 10).rounded())
            } else {
                widthKey = nil
            }
        }
    }

    struct Cache {
        var sizes: [Proposal: CGSize] = [:]
        var lastFiniteSize: CGSize?
        var invalidationToken: Int?
    }

    func makeCache(subviews: Subviews) -> Cache {
        var cache = Cache()
        if tracksRowInvalidation {
            cache.invalidationToken = ChatTimelineRowLayoutInvalidation.currentToken(
                for: messageID,
                layoutSignature: layoutSignature
            )
        }
        return cache
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        if tracksRowInvalidation {
            let token = ChatTimelineRowLayoutInvalidation.currentToken(
                for: messageID,
                layoutSignature: layoutSignature
            )
            if cache.invalidationToken == token, !cache.sizes.isEmpty {
                return
            }
            cache.invalidationToken = token
        }
        ChatRenderProbe.record("layout-invalidate", id: messageID)
        // SwiftUI invalidates on child changes, including asynchronous media/layout updates.
        cache.sizes.removeAll(keepingCapacity: true)
        cache.lastFiniteSize = nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        ChatRenderProbe.record("layout-request", id: messageID)
        guard let row = subviews.first else { return .zero }
        if tracksRowInvalidation, let proposedWidth = proposal.width {
            if proposedWidth <= 0 {
                return CGSize(width: 0, height: cache.lastFiniteSize?.height ?? 0)
            }
            if !proposedWidth.isFinite {
                return cache.lastFiniteSize ?? .zero
            }
        } else if tracksRowInvalidation, proposal.width == nil, let lastFiniteSize = cache.lastFiniteSize {
            return lastFiniteSize
        }
        let key = Proposal(proposal)
        if let size = cache.sizes[key] { return size }
        ChatRenderProbe.record("layout-measure", id: messageID)
        let measurementProposal = (proposal.width != nil && proposal.width! > 0 && proposal.width!.isFinite)
            ? ProposedViewSize(width: proposal.width, height: nil)
            : proposal
        let size = row.sizeThatFits(measurementProposal)
        cache.sizes[key] = size
        if let width = proposal.width, width > 0, width.isFinite {
            cache.lastFiniteSize = size
        }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        ChatRenderProbe.record("layout-place", id: messageID)
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }
}
