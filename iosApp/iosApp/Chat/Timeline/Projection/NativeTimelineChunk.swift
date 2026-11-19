import Foundation

/// Absolute message indices keep every row in the same block across prepends.
/// Markers after a message belong to that message's block; the bottom anchor
/// remains in its own stable block instead of moving as the history grows.
struct NativeTimelineChunk: Identifiable {
    let id: String
    let entries: [NativeTimelineEntry]
    let messageIDs: Set<String>
    let signature: Int

    static func group(_ entries: [NativeTimelineEntry]) -> [Self] {
        var groups: [(String, [NativeTimelineEntry])] = []
        var previousMessageBlock: String?
        for entry in entries {
            let block: String
            if let index = entry.index {
                block = "chunk-\(index / 10)"
                previousMessageBlock = block
            } else if entry.kind == .contextMarker, let previousMessageBlock,
                      groups.last?.0 == previousMessageBlock {
                block = previousMessageBlock
            } else {
                block = "decoration-\(entry.id)"
            }
            if groups.last?.0 == block {
                groups[groups.count - 1].1.append(entry)
            } else {
                groups.append((block, [entry]))
            }
        }
        return groups.map { id, entries in
            var hash = Hasher()
            for entry in entries {
                hash.combine(entry.id); hash.combine(entry.renderDigest)
                hash.combine(entry.renderToken); hash.combine(String(describing: entry.kind))
                if entry.isGenerating && entry.isLastMessage { hash.combine(true) }
                hash.combine(entry.isStreaming)
                hash.combine(entry.hasEverStreamed); hash.combine(entry.canAnimateInsertion)
                hash.combine(entry.isAssistantContinuation); hash.combine(entry.isGlobalStatusOnly)
                hash.combine(entry.isCompactedHistory); hash.combine(entry.isTaskLive)
                hash.combine(entry.variantInfo?.variantCount); hash.combine(entry.variantInfo?.selectedIndex)
                hash.combine(entry.phoneToolGroup?.signature); hash.combine(entry.assistantTurn?.signature); hash.combine(entry.automationScreenshotGroup?.signature)
                hash.combine(entry.renderState?.rendererMode.rawValue)
                hash.combine(entry.renderState?.liveRenderingEnabled)
                hash.combine(entry.renderState?.hasEverStreamed)
                // A frozen snapshot changes only with its render-state revision,
                // which is already included in renderDigest. Do not rehash prose.
                if let state = entry.compactState {
                    hash.combine(String(describing: state.status)); hash.combine(state.summary)
                    hash.combine(state.updatedAt); hash.combine(state.customCompletedTitle)
                }
            }
            return Self(id: id, entries: entries, messageIDs: Set(entries.compactMap(\.messageId)),
                        signature: hash.finalize())
        }
    }
}
