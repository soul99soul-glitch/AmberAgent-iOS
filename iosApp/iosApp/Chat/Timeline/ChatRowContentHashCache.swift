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
    typealias Metadata = [String: Kotlinx_serialization_jsonJsonElement]
    private let metadata: [Metadata?]

    init(_ message: UIMessage, index: Int? = nil) {
        self.message = message
        self.index = index
        metadata = Self.metadata(in: message.parts)
    }

    func matches(_ message: UIMessage) -> Bool {
        self.message === message && Self.sameMetadata(metadata, Self.metadata(in: message.parts))
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
        let metadata: [ChatMessageContentIdentity.Metadata?]
        let hash: Int
    }
    private var entries: [String: [PartEntry?]] = [:]
    private(set) var partHashComputationCount = 0

    private func partEntry(_ part: UIMessagePart, cached: PartEntry?) -> PartEntry {
        let metadata = ChatMessageContentIdentity.metadata(in: [part])
        if let cached, cached.part === part,
           ChatMessageContentIdentity.sameMetadata(cached.metadata, metadata) {
            return cached
        }
        // Never `String(describing: part)`: Kotlin toString() of a phone tool part
        // serializes its base64 screenshots (100–200 KB each, MBs per row).
        // ChatPartSignature keeps tool payloads bounded and text parts exact.
        partHashComputationCount &+= 1
        return PartEntry(part: part, metadata: metadata, hash: ChatPartSignature.hash(part, exactText: true))
    }

    func contentHash(for row: ChatMessageRowModel) -> Int {
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
        return hasher.finalize()
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
    }

    func removeAll() {
        entries.removeAll()
    }
}

