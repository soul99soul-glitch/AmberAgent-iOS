import SwiftUI
import SwiftStreamingMarkdown

enum ChatTimelineRowLayoutInvalidation {
    nonisolated(unsafe) private static var isHookInstalled = false
    nonisolated(unsafe) private static var unscopedGeneration: UInt64 = 0
    nonisolated(unsafe) private static var rowGenerations: [String: UInt64] = [:]
    #if DEBUG
    nonisolated(unsafe) static var placedRowBounds: [String: CGRect] = [:]
    nonisolated(unsafe) static var placedSubAgentCardSizes: [String: CGSize] = [:]
    nonisolated(unsafe) private static var subAgentCardToggleHandlers: [String: () -> Void] = [:]

    static func registerSubAgentCardToggle(id: String?, action: @escaping () -> Void) {
        guard let id, !id.isEmpty else { return }
        subAgentCardToggleHandlers[id] = action
    }

    @discardableResult
    static func toggleSubAgentCard(_ id: String) -> Bool {
        guard let action = subAgentCardToggleHandlers[id] else { return false }
        action()
        return true
    }

    static func resetDebugGeometry() {
        placedRowBounds.removeAll()
        placedSubAgentCardSizes.removeAll()
        subAgentCardToggleHandlers.removeAll()
    }
    #endif

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
        hasher.combine(prefs.replyDeliveryMode)
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
        if tracksRowInvalidation {
            let token = ChatTimelineRowLayoutInvalidation.currentToken(
                for: messageID,
                layoutSignature: layoutSignature
            )
            if cache.invalidationToken != token {
                if !cache.sizes.isEmpty {
                    ChatRenderProbe.record("layout-invalidate", id: messageID)
                    cache.sizes.removeAll(keepingCapacity: true)
                    cache.lastFiniteSize = nil
                }
                cache.invalidationToken = token
            }
        }
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
        if tracksRowInvalidation {
            cache.invalidationToken = ChatTimelineRowLayoutInvalidation.currentToken(
                for: messageID,
                layoutSignature: layoutSignature
            )
        }
        cache.sizes[key] = size
        if let width = proposal.width, width > 0, width.isFinite {
            cache.lastFiniteSize = size
        }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        ChatRenderProbe.record("layout-place", id: messageID)
        #if DEBUG
        if !messageID.isEmpty, messageID != "all" {
            ChatTimelineRowLayoutInvalidation.placedRowBounds[messageID] = bounds
        }
        #endif
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }
}
