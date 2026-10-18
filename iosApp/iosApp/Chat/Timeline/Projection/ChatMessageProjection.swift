import Foundation
import Shared

struct ChatMessageRowModel: Identifiable {
    let rowId: String
    let messageId: String
    let message: UIMessage
    let role: MessageRole
    let parts: [UIMessagePart]
    let index: Int
    let isLast: Bool
    let isStreaming: Bool
    let hasEverStreamed: Bool
    let canAnimateInsertion: Bool

    var isAssistantContinuation: Bool = false

    var id: String { rowId }
}

enum ChatTimelineRendererKind: Equatable {
    case user
    case staticAssistantMarkdown
    case streamingAssistantMarkdown
}

enum ChatTimelineEntry: Equatable {
    case message(ChatTimelineMessageEntry)
    case pendingAssistant(id: String)
    case bottomAnchor(id: String)

    var id: String {
        switch self {
        case let .message(entry):
            return entry.id
        case let .pendingAssistant(id), let .bottomAnchor(id):
            return id
        }
    }
}

struct ChatTimelineMessageEntry: Equatable {
    let id: String
    let messageId: String
    let message: UIMessage
    let role: MessageRole
    let index: Int
    let isLast: Bool
    let isStreaming: Bool
    let hasEverStreamed: Bool
    let canAnimateInsertion: Bool
    let renderer: ChatTimelineRendererKind
    let renderToken: String

    var isAssistantContinuation: Bool = false

    var rowModel: ChatMessageRowModel {
        ChatMessageRowModel(
            rowId: messageId,
            messageId: messageId,
            message: message,
            role: role,
            parts: message.parts,
            index: index,
            isLast: isLast,
            isStreaming: isStreaming,
            hasEverStreamed: hasEverStreamed,
            canAnimateInsertion: canAnimateInsertion,
            isAssistantContinuation: isAssistantContinuation
        )
    }
}

struct ChatTimelinePlan: Equatable {
    let entries: [ChatTimelineEntry]
    let latestRenderToken: String

    func messageEntry(for messageId: String) -> ChatTimelineMessageEntry? {
        entries.lazy.compactMap { entry -> ChatTimelineMessageEntry? in
            guard case let .message(message) = entry else { return nil }
            return message.messageId == messageId ? message : nil
        }.first
    }
}

enum ChatTimelinePlanner {
    static let bottomAnchorID = ChatLayout.bottomAnchorID
    static let pendingAssistantID = "timeline-pending-assistant"
    static let messageEntryIDPrefix = "message-"

    /// `includeRenderTokens` 控制是否计算逐行 renderToken。Native timeline
    /// projection 消费 token；旧 SwiftUI/collection 路径只取 row model，传 false
    /// 跳过尾行每个 chunk 都要 O(文本长度) 扫一遍的 token 计算。
    static func build(
        messages: [UIMessage],
        event: ChatEvent,
        streamedMessageIDs: Set<String> = [],
        includePendingAssistant: Bool = false,
        includeRenderTokens: Bool = true,
        startIndex: Int = 0
    ) -> ChatTimelinePlan {
        let rows = ChatMessageProjector.rows(
            messages: messages,
            event: event,
            streamedMessageIDs: streamedMessageIDs,
            startIndex: startIndex
        )
        var entries = rows.map { row in
            ChatTimelineEntry.message(messageEntry(for: row, includeRenderToken: includeRenderTokens))
        }

        if includePendingAssistant {
            entries.append(.pendingAssistant(id: pendingAssistantID))
        }
        entries.append(.bottomAnchor(id: bottomAnchorID))

        return ChatTimelinePlan(
            entries: entries,
            latestRenderToken: includeRenderTokens
                ? latestRenderToken(rows: rows, includePendingAssistant: includePendingAssistant)
                : ""
        )
    }

    static func messageEntry(for row: ChatMessageRowModel, includeRenderToken: Bool = true) -> ChatTimelineMessageEntry {
        ChatTimelineMessageEntry(
            id: messageEntryIDPrefix + row.messageId, messageId: row.messageId,
            message: row.message, role: row.role, index: row.index,
            isLast: row.isLast, isStreaming: row.isStreaming, hasEverStreamed: row.hasEverStreamed,
            canAnimateInsertion: row.canAnimateInsertion, renderer: rendererKind(for: row),
            renderToken: includeRenderToken ? renderToken(for: row) : "",
            isAssistantContinuation: row.isAssistantContinuation
        )
    }

    private static func rendererKind(for row: ChatMessageRowModel) -> ChatTimelineRendererKind {
        switch row.role {
        case MessageRole.user:
            return .user
        case MessageRole.assistant:
            return row.isStreaming || row.hasEverStreamed ? .streamingAssistantMarkdown : .staticAssistantMarkdown
        default:
            return .staticAssistantMarkdown
        }
    }

    private static func latestRenderToken(rows: [ChatMessageRowModel], includePendingAssistant: Bool) -> String {
        guard let row = rows.last else {
            return includePendingAssistant ? "empty:pending" : "empty"
        }
        return "\(rows.count):\(row.messageId):\(renderToken(for: row)):\(includePendingAssistant)"
    }

    private static func renderToken(for row: ChatMessageRowModel) -> String {
        let partTokens = row.parts.map { compactRenderToken(for: $0) }.joined(separator: "|")
        return "\(row.messageId):\(row.role.name):\(row.isStreaming):\(row.hasEverStreamed):\(row.isAssistantContinuation):\(partTokens)"
    }

    private static func compactRenderToken(for part: UIMessagePart) -> String {
        switch part {
        case let text as UIMessagePart.Text:
            // utf16.count 而非 count:Character 计数是 O(n) 字素簇遍历,流式尾行
            // 每个 chunk 都要为 32KB 级文本付一次;token 只需要"长度变了就变"。
            return "text:\(text.text.utf16.count):\(String(text.text.suffix(16)))"
        case let reasoning as UIMessagePart.Reasoning:
            return "reasoning:\(reasoning.reasoning.utf16.count):\(reasoning.finishedAt != nil)"
        case let image as UIMessagePart.Image:
            // Bounded: never walk graphemes of a base64 data URL or stringify metadata.
            return "image:\(ChatPartSignature.hash(image, exactText: false))"
        case let document as UIMessagePart.Document:
            return "document:\(document.fileName):\(ChatPartSignature.hash(document, exactText: false))"
        case let miniApp as UIMessagePart.MiniApp:
            return "mini_app:\(miniApp.appId):\(miniApp.version):\(miniApp.htmlHash ?? ""):\(miniApp.title)"
        case let tool as UIMessagePart.Tool:
            let outputToken = tool.output.last.map { compactRenderToken(for: $0) } ?? "empty"
            return "tool:\(tool.toolCallId):\(tool.toolName):\(tool.isExecuted):\(tool.output.count):\(outputToken)"
        default:
            return "\(type(of: part)):\(ChatPartSignature.hash(part, exactText: false))"
        }
    }
}

enum ChatMessageProjector {
    /// Internal progress stays in context; completed results have a dedicated
    /// agent-side card while retaining their provider transport role.
    static func isVisibleInTimeline(_ message: UIMessage) -> Bool {
        guard message.role == MessageRole.user else { return true }
        switch IosMailboxMessageBridge.shared.kind(message: message) {
        case "MESSAGE": return false
        default: return true
        }
    }

    static func isSubAgentResult(_ message: UIMessage) -> Bool {
        message.role == MessageRole.user &&
            IosMailboxMessageBridge.shared.kind(message: message) == "FINAL_ANSWER"
    }

    static func isConversationMessage(_ message: UIMessage) -> Bool {
        isVisibleInTimeline(message) && !isSubAgentResult(message)
    }

    static func messageId(for message: UIMessage) -> String {
        // String(describing:) 走桥接 description 路径(单次 ~25µs,逐行×每 delta);
        // toHexDashString() 是直接访问器,产出同样的 8-4-4-4-12 字符串
        // (格式等价由 ChatMessageProjectionTests 的 canary 锁定)。
        message.id.toHexDashString()
    }

    static func isAssistantContinuation(at index: Int, in messages: [UIMessage]) -> Bool {
        guard index > 0, messages[index].role == MessageRole.assistant else { return false }
        for previous in messages[..<index].reversed() where isVisibleInTimeline(previous) {
            return previous.role == MessageRole.assistant
        }
        return false
    }

    static func rows(
        messages: [UIMessage],
        event: ChatEvent,
        streamedMessageIDs: Set<String> = [],
        startIndex: Int = 0
    ) -> [ChatMessageRowModel] {
        let lastVisibleIndex = messages.lastIndex(where: isVisibleInTimeline)
        return messages.indices.dropFirst(max(0, startIndex)).compactMap { index in
            row(at: index, in: messages, event: event, streamedMessageIDs: streamedMessageIDs,
                lastVisibleIndex: lastVisibleIndex)
        }
    }

    static func row(
        at index: Int, in messages: [UIMessage], event: ChatEvent,
        streamedMessageIDs: Set<String>, lastVisibleIndex: Int?
    ) -> ChatMessageRowModel? {
        let message = messages[index]
        guard isVisibleInTimeline(message) else { return nil }
        let messageId = messageId(for: message)
        let isResult = isSubAgentResult(message)
        let isLast = index == lastVisibleIndex
        let isStreaming = event == .assistantStreamDelta && isLast && message.role == MessageRole.assistant
        let hasEverStreamed = !isResult && (isStreaming || streamedMessageIDs.contains(messageId))
        let canAnimateInsertion = (event == .toolResultAppended && isResult) ||
            (event == .userMessageAppended && isLast && message.role == MessageRole.user && !isResult)
        return ChatMessageRowModel(
            rowId: messageId, messageId: messageId, message: message,
            role: isResult ? MessageRole.assistant : message.role, parts: message.parts, index: index,
            isLast: isLast, isStreaming: isStreaming, hasEverStreamed: hasEverStreamed,
            canAnimateInsertion: canAnimateInsertion,
            isAssistantContinuation: isAssistantContinuation(at: index, in: messages)
        )
    }

}

enum ChatInsertionAnimationPolicy {
    static func animatedInsertionItemIDs(
        previousItemIDs: [String],
        rows: [ChatMessageRowModel]
    ) -> [String] {
        let previous = Set(previousItemIDs)
        return rows.compactMap { row in
            guard row.canAnimateInsertion else { return nil }
            let itemID = "message-\(row.messageId)"
            return previous.contains(itemID) ? nil : itemID
        }
    }
}

/// L1 content signatures for message parts.
///
/// Tool outputs in phone automation carry 100–200 KB base64 screenshots per step
/// (16–20 MB per conversation). Signatures must never stringify (`String(describing:)`
/// runs Kotlin `toString()` over the whole payload), walk graphemes (`.count`) or
/// hash those payloads in full.
/// - Text (tool output text, reasoning, tool input, approval text) is hashed exactly
///   up to `textExactLimit`; the per-part identity cache bounds how often that runs.
/// - Media URLs, `data:` payloads and texts above the limit are sampled: UTF-16
///   length (O(1) via the bridged `NSString`) plus fixed head/tail/interior windows.
/// - Top-level message text/reasoning (`exactText: true`) is always exact: user edits
///   can change one character in the middle of a long message without changing its length.
enum ChatPartSignature {
    typealias Metadata = [String: Kotlinx_serialization_jsonJsonElement]

    /// Text-like strings up to this many UTF-16 units are hashed exactly.
    static let textExactLimit = 65_536
    /// URL/base64-like payload strings up to this many UTF-16 units are hashed exactly.
    static let payloadExactLimit = 2_048
    private static let edgeWindow = 256
    private static let interiorWindowCount = 16
    private static let interiorWindowLength = 32

    static func hash(_ part: UIMessagePart, exactText: Bool) -> Int {
        var hasher = Hasher()
        combine(part, exactText: exactText, into: &hasher)
        return hasher.finalize()
    }

    /// Text-like content: exact up to `textExactLimit`, sampled above; `data:`
    /// payloads embedded as text are treated as media.
    static func combineText(_ string: String, into hasher: inout Hasher) {
        let bridged = string as NSString
        let isPayload = bridged.length > payloadExactLimit && bridged.hasPrefix("data:")
        combineBounded(bridged, exactLimit: isPayload ? payloadExactLimit : textExactLimit, into: &hasher)
    }

    /// Media URLs / base64 payloads: exact only when short.
    static func combinePayload(_ string: String, into hasher: inout Hasher) {
        combineBounded(string as NSString, exactLimit: payloadExactLimit, into: &hasher)
    }

    /// Bounded work regardless of string size above `exactLimit`: at most
    /// `2 * edgeWindow + interiorWindowCount * interiorWindowLength` UTF-16 units.
    static func combineBounded(_ bridged: NSString, exactLimit: Int, into hasher: inout Hasher) {
        let length = bridged.length
        hasher.combine(length)
        guard length > 0 else { return }
        guard length > exactLimit else {
            hasher.combine(bridged as String)
            return
        }
        hasher.combine(bridged.substring(with: NSRange(location: 0, length: edgeWindow)))
        hasher.combine(bridged.substring(with: NSRange(location: length - edgeWindow, length: edgeWindow)))
        let span = length - 2 * edgeWindow - interiorWindowLength
        for index in 1...interiorWindowCount {
            let location = edgeWindow + span * index / (interiorWindowCount + 1)
            hasher.combine(bridged.substring(with: NSRange(location: location, length: interiorWindowLength)))
        }
    }

    static func combine(_ part: UIMessagePart, exactText: Bool, into hasher: inout Hasher) {
        switch part {
        case let text as UIMessagePart.Text:
            hasher.combine(0)
            if exactText { hasher.combine(text.text) } else { combineText(text.text, into: &hasher) }
        case let reasoning as UIMessagePart.Reasoning:
            hasher.combine(1)
            if exactText {
                hasher.combine(reasoning.reasoning)
            } else {
                combineText(reasoning.reasoning, into: &hasher)
            }
            hasher.combine(reasoning.createdAt.hash)
            hasher.combine(reasoning.finishedAt?.hash ?? 0)
            hasher.combine(reasoning.finishedAt != nil)
        case let image as UIMessagePart.Image:
            hasher.combine(2)
            combinePayload(image.url, into: &hasher)
        case let video as UIMessagePart.Video:
            hasher.combine(3)
            combinePayload(video.url, into: &hasher)
        case let audio as UIMessagePart.Audio:
            hasher.combine(4)
            combinePayload(audio.url, into: &hasher)
            hasher.combine(audio.fileName)
        case let document as UIMessagePart.Document:
            hasher.combine(5)
            combinePayload(document.url, into: &hasher)
            hasher.combine(document.fileName)
            hasher.combine(document.mime)
        case let tool as UIMessagePart.Tool:
            hasher.combine(6)
            hasher.combine(tool.toolCallId)
            hasher.combine(tool.toolName)
            combineText(tool.input, into: &hasher)
            combineApproval(tool.approvalState, into: &hasher)
            hasher.combine(tool.streamIndex?.intValue ?? -1)
            let output = tool.output
            hasher.combine(output.count)
            for outputPart in output {
                // Tool output text is exact up to textExactLimit; media/base64 is sampled.
                combine(outputPart, exactText: false, into: &hasher)
            }
        default:
            // MiniApp and future part kinds carry no bulk payload (MiniApp stores
            // only an html hash), so their description is small.
            hasher.combine(7)
            hasher.combine(String(describing: part))
        }
        combineMetadata(part.metadata, into: &hasher)
    }

    static func combineApproval(_ state: ToolApprovalState, into hasher: inout Hasher) {
        switch state {
        case is ToolApprovalState.Pending:
            hasher.combine("pending")
        case is ToolApprovalState.Approved:
            hasher.combine("approved")
        case let denied as ToolApprovalState.Denied:
            hasher.combine("denied")
            combineText(denied.reason, into: &hasher)
        case let answered as ToolApprovalState.Answered:
            hasher.combine("answered")
            combineText(answered.answer, into: &hasher)
        default:
            hasher.combine("auto")
        }
    }

    /// Metadata is small and mutable in place; Kotlin `hashCode()` is content based.
    static func combineMetadata(_ metadata: Metadata?, into hasher: inout Hasher) {
        guard let metadata else {
            hasher.combine(-1)
            return
        }
        hasher.combine(metadata.count)
        for key in metadata.keys.sorted() {
            hasher.combine(key)
            hasher.combine(metadata[key]?.hash ?? 0)
        }
    }
}

