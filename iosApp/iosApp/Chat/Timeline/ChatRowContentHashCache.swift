import SwiftUI
import UIKit
import Shared
import ChatLayout
import Combine

/// UIMessage payloads are replaced by the Swift/KMP update paths, but part metadata
/// is mutable. Capture its dictionary values separately from the message so an
/// in-place metadata update cannot make an old snapshot appear unchanged.
struct ChatMessageContentIdentity {
    let message: UIMessage
    let index: Int?
    let cachedParts: [UIMessagePart]
    typealias Metadata = [String: Kotlinx_serialization_jsonJsonElement]
    private let trackedParts: [UIMessagePart]
    private let metadata: [Metadata?]
    private let hasNonNilMetadata: Bool

    init(_ message: UIMessage, index: Int? = nil, bridgedParts: [UIMessagePart]? = nil) {
        self.message = message
        self.index = index
        let topParts = bridgedParts ?? message.parts
        self.cachedParts = topParts
        var flatParts: [UIMessagePart] = []
        flatParts.reserveCapacity(topParts.count)
        Self.collectTrackedParts(from: topParts, into: &flatParts)
        self.trackedParts = flatParts
        if flatParts.contains(where: { $0.metadata != nil }) {
            self.metadata = flatParts.map(\.metadata)
            self.hasNonNilMetadata = true
        } else {
            self.metadata = []
            self.hasNonNilMetadata = false
        }
    }

    init(reusingMetadataFrom previous: ChatMessageContentIdentity, message: UIMessage) {
        let topParts = message.parts
        self.message = message
        self.index = previous.index
        self.cachedParts = topParts
        var flatParts: [UIMessagePart] = []
        flatParts.reserveCapacity(topParts.count)
        Self.collectTrackedParts(from: topParts, into: &flatParts)
        self.trackedParts = flatParts
        self.metadata = previous.metadata
        self.hasNonNilMetadata = previous.hasNonNilMetadata
    }

    func matches(_ message: UIMessage) -> Bool {
        guard self.message === message else { return false }
        return hasSameTrackedMetadata()
    }

    private func hasSameTrackedMetadata() -> Bool {
        if !hasNonNilMetadata {
            for part in trackedParts where part.metadata != nil {
                return false
            }
            return true
        }
        guard metadata.count == trackedParts.count else { return false }
        for index in trackedParts.indices where metadata[index] != trackedParts[index].metadata {
            return false
        }
        return true
    }

    func hasSameMetadata(as parts: [UIMessagePart]) -> Bool {
        if !hasNonNilMetadata {
            return !Self.containsNonNilMetadata(in: parts)
        }
        return Self.sameMetadata(metadata, Self.metadata(in: parts))
    }

    private static func collectTrackedParts(from parts: [UIMessagePart], into output: inout [UIMessagePart]) {
        for part in parts {
            output.append(part)
            if let tool = part as? UIMessagePart.Tool {
                collectTrackedParts(from: tool.output, into: &output)
            }
        }
    }

    static func containsNonNilMetadata(in parts: [UIMessagePart]) -> Bool {
        for part in parts {
            if part.metadata != nil { return true }
            if let tool = part as? UIMessagePart.Tool,
               containsNonNilMetadata(in: tool.output) {
                return true
            }
        }
        return false
    }

    static func metadata(in parts: [UIMessagePart]) -> [Metadata?] {
        var result: [Metadata?] = []
        for part in parts {
            result.append(part.metadata)
            if let tool = part as? UIMessagePart.Tool {
                result.append(contentsOf: metadata(in: tool.output))
            }
        }
        return result
    }

    static func sameMetadata(_ lhs: [Metadata?], _ rhs: [Metadata?]) -> Bool {
        lhs == rhs
    }
}

/// Hash unchanged parts once, even when they belong to a growing assistant row.
/// Replacement text/output/approval snapshots and in-place metadata updates all
/// invalidate their part. Row identity or output counts alone are insufficient.
final class ChatRowContentHashCache {
    private struct PartEntry {
        let part: UIMessagePart
        let trackedSubparts: [UIMessagePart]
        let metadata: [ChatMessageContentIdentity.Metadata?]
        let hash: Int
    }
    private struct RowHashEntry {
        let identity: ChatMessageContentIdentity
        let hash: Int
    }
    private var entries: [String: [PartEntry?]] = [:]
    private var rowHashes: [String: RowHashEntry] = [:]
    private(set) var partHashComputationCount = 0

    private static func collectSubparts(of part: UIMessagePart) -> [UIMessagePart] {
        guard let tool = part as? UIMessagePart.Tool else { return [part] }
        var result: [UIMessagePart] = [part]
        func appendChildren(_ parts: [UIMessagePart]) {
            for child in parts {
                result.append(child)
                if let nested = child as? UIMessagePart.Tool {
                    appendChildren(nested.output)
                }
            }
        }
        appendChildren(tool.output)
        return result
    }

    private func partEntry(_ part: UIMessagePart, cached: PartEntry?) -> PartEntry {
        if let cached, cached.part === part {
            if cached.metadata.isEmpty {
                if !cached.trackedSubparts.contains(where: { $0.metadata != nil }) {
                    return cached
                }
            } else if cached.metadata.count == cached.trackedSubparts.count {
                var allSame = true
                for index in cached.trackedSubparts.indices
                where cached.metadata[index] != cached.trackedSubparts[index].metadata {
                    allSame = false
                    break
                }
                if allSame { return cached }
            }
        }
        let trackedSubparts = Self.collectSubparts(of: part)
        let metadata = trackedSubparts.contains(where: { $0.metadata != nil })
            ? trackedSubparts.map(\.metadata)
            : []
        // Never `String(describing: part)`: Kotlin toString() of a phone tool part
        // serializes its base64 screenshots (100–200 KB each, MBs per row).
        // ChatPartSignature keeps tool payloads bounded and text parts exact.
        partHashComputationCount &+= 1
        return PartEntry(
            part: part,
            trackedSubparts: trackedSubparts,
            metadata: metadata,
            hash: ChatPartSignature.hash(part, exactText: true)
        )
    }

    func contentHash(for row: ChatMessageRowModel) -> Int {
        if let cachedRow = rowHashes[row.messageId],
           cachedRow.identity.matches(row.message) {
            return cachedRow.hash
        }
        let previous = entries[row.messageId] ?? []
        var next: [PartEntry?] = []
        next.reserveCapacity(row.parts.count)
        var hasher = Hasher()
        hasher.combine(row.parts.count)
        for (index, part) in row.parts.enumerated() {
            let entry = partEntry(part, cached: index < previous.count ? previous[index] : nil)
            next.append(entry)
            hasher.combine(entry.hash)
        }
        for annotation in row.message.annotations {
            hasher.combine(String(describing: annotation))
        }
        entries[row.messageId] = next
        let finalized = hasher.finalize()
        rowHashes[row.messageId] = RowHashEntry(
            identity: ChatMessageContentIdentity(row.message, bridgedParts: row.parts),
            hash: finalized
        )
        return finalized
    }

    /// Streaming tail rows are re-laid out by the live-tail invalidation bridge on
    /// every delta. They do not need the expensive full `message.toText()` hash that
    /// historical rows need for precise cache invalidation; a cheap structural token
    /// is enough to mark tail growth without doing O(total text) string joins on the
    /// main actor for every provider chunk.
    func streamingTailLayoutToken(for row: ChatMessageRowModel) -> Int {
        let previous = entries[row.messageId] ?? []
        var next = Array<PartEntry?>(repeating: nil, count: row.parts.count)
        var hasher = Hasher()
        hasher.combine(row.messageId)
        hasher.combine(row.parts.count)
        hasher.combine(row.message.annotations.count)
        for annotation in row.message.annotations {
            hasher.combine(String(describing: annotation))
        }
        for (index, part) in row.parts.enumerated() {
            switch part {
            case let text as UIMessagePart.Text:
                hasher.combine("text")
                hasher.combine(text.text.utf16.count)
                hasher.combine(String(text.text.suffix(24)))
            case let reasoning as UIMessagePart.Reasoning:
                hasher.combine("reasoning")
                hasher.combine(reasoning.reasoning.utf16.count)
                hasher.combine(String(reasoning.reasoning.suffix(24)))
                hasher.combine(reasoning.finishedAt != nil)
            case let tool as UIMessagePart.Tool:
                let entry = partEntry(tool, cached: index < previous.count ? previous[index] : nil)
                next[index] = entry
                hasher.combine(entry.hash)
            case let image as UIMessagePart.Image:
                hasher.combine("image")
                ChatPartSignature.combinePayload(image.url, into: &hasher)
            case let document as UIMessagePart.Document:
                hasher.combine("document")
                hasher.combine(document.fileName)
                ChatPartSignature.combinePayload(document.url, into: &hasher)
            case let miniApp as UIMessagePart.MiniApp:
                hasher.combine("mini_app")
                hasher.combine(miniApp.appId)
                hasher.combine(miniApp.version)
                hasher.combine(miniApp.htmlHash ?? "")
                hasher.combine(miniApp.title)
            default:
                hasher.combine(String(describing: type(of: part)))
            }
        }
        entries[row.messageId] = next
        rowHashes.removeValue(forKey: row.messageId)
        return hasher.finalize()
    }

    /// 尾行几何已确认离开 ScrollView viewport 后，保持 token 只依赖行身份，
    /// 避免每个 delta 都让巨大的流式 bubble 参与 SwiftUI diff 和布局；重新
    /// 与 viewport 相交后会使用 streamingTailLayoutToken 接上累计全文。
    func suspendedStreamingTailLayoutToken(for row: ChatMessageRowModel) -> Int {
        var hasher = Hasher()
        hasher.combine("suspended-streaming-tail")
        hasher.combine(row.messageId)
        return hasher.finalize()
    }

    func retain(ids: Set<String>) {
        entries = entries.filter { ids.contains($0.key) }
        rowHashes = rowHashes.filter { ids.contains($0.key) }
    }

    func removeAll() {
        entries.removeAll()
        rowHashes.removeAll()
    }
}

