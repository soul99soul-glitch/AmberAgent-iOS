import SwiftUI
import Shared

/// Reference callbacks stay current when an unchanged history chunk skips body.
@MainActor
final class ChatTimelineChunkCallbacks {
    var boundary: (String, CGFloat?, CGFloat?) -> Void = { _, _, _ in }
    var action: (ChatListAction) -> Void = { _ in }
}

struct ChatTimelineChunkView<EntryContent: View>: View, @MainActor Equatable {
    let chunk: NativeTimelineChunk
    let presentationSignature: Int
    let firstEntryID: String?
    let firstHistoryEntryID: String?
    let historyBoundaryIDs: Set<String>
    let activity: ChatTimelineActivity?
    let hasActivityAnchor: Bool
    let contextCompactState: ChatContextCompactState
    let callbacks: ChatTimelineChunkCallbacks
    let entryView: (NativeTimelineEntry) -> EntryContent

    static func == (lhs: Self, rhs: Self) -> Bool {
        ChatRenderProbe.record("chunk-compare", id: lhs.chunk.id)
        return lhs.chunk.signature == rhs.chunk.signature &&
            lhs.presentationSignature == rhs.presentationSignature && lhs.activity == rhs.activity
    }

    var body: some View {
        let _ = ChatRenderProbe.record("chunk", id: chunk.id)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(chunk.entries) { entry in
                let isHistoryBoundary = entry.id == firstHistoryEntryID || historyBoundaryIDs.contains(entry.id)
                let activityHere = entry.messageId != nil && entry.messageId == activity?.anchorMessageID
                let statusReplacesEntry = activityHere && entry.isGlobalStatusOnly
                let isHiddenStatus = (entry.isGlobalStatusOnly && !statusReplacesEntry) || entry.kind == .pendingAssistant ||
                    entry.kind == .visionRecognition ||
                    (entry.kind == .contextMarker &&
                     (entry.compactState ?? contextCompactState).status != .completed)
                // Hidden status-only entries must not leave per-task gaps in the timeline.
                let topSpacing: CGFloat = entry.id == firstEntryID ||
                    isHiddenStatus ? 0 : (
                    entry.isAssistantContinuation ? ChatLayout.assistantPartSpacing : 14
                )
                if isHistoryBoundary {
                    Color.clear
                        .frame(height: 0)
                        .id("history-boundary-" + entry.id)
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat?.self) { proxy in
                            guard let viewport = proxy.bounds(of: .scrollView),
                                  viewport.height > 0 else { return nil }
                            return -viewport.minY / viewport.height
                        } action: { previous, current in
                            callbacks.boundary(entry.id, previous, current)
                        }
                        .padding(.top, topSpacing)
                }
                if entry.kind == .bottomAnchor, let activity, !hasActivityAnchor {
                    ChatTimelineActivityRowView(activity: activity, showAgentName: true, onAction: { callbacks.action($0) })
                        .padding(.top, ChatLayout.assistantPartSpacing)
                }
                Group {
                    if let activity, statusReplacesEntry {
                        ChatTimelineActivityRowView(activity: activity, showAgentName: !entry.isAssistantContinuation, onAction: { callbacks.action($0) })
                            .id(entry.id)
                    } else {
                        entryView(entry)
                    }
                }
                .padding(.top, isHistoryBoundary ? 0 : topSpacing)
                if let activity, activityHere, !statusReplacesEntry, activity.shouldDisplayBelow(entry) {
                    // 仅当当前轮气泡正在吐正文时收起进度行（防流式结束 28pt 下坠）；工具执行与次轮思考仍展示在首轮气泡下方。
                    let isAfterUserMessage = entry.role == MessageRole.user
                    ChatTimelineActivityRowView(activity: activity, showAgentName: isAfterUserMessage, onAction: { callbacks.action($0) })
                        .padding(.top, isAfterUserMessage ? 14 : ChatLayout.assistantPartSpacing)
                }
            }
        }
        .scrollTargetLayout()
    }
}
