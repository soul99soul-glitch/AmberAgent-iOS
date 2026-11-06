import SwiftUI
import Shared

struct ChatTimelineActivity: Equatable {
    let anchorMessageID: String
    let hasAssistant: Bool
    let presentation: ChatActivityIslandState
    let tool: UIMessagePart.Tool?
    let taskSlot: ChatAsyncTaskSlot?
    let plannedStages: [String]
    let stagePlanStartedUptime: TimeInterval?
    let liveReasoningSummary: String?
    let tracksTaskLiveness: Bool
    let showsThought: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.anchorMessageID == rhs.anchorMessageID && lhs.hasAssistant == rhs.hasAssistant &&
            lhs.presentation == rhs.presentation && lhs.tool === rhs.tool && lhs.taskSlot === rhs.taskSlot &&
            lhs.plannedStages == rhs.plannedStages && lhs.stagePlanStartedUptime == rhs.stagePlanStartedUptime &&
            lhs.liveReasoningSummary == rhs.liveReasoningSummary &&
            lhs.tracksTaskLiveness == rhs.tracksTaskLiveness && lhs.showsThought == rhs.showsThought
    }

    static func thoughtTitle(stages: [String], start: TimeInterval?, summary: String?, at uptime: TimeInterval) -> String {
        if !stages.isEmpty, let start {
            let index = Int(max(0, uptime - start) / 1.8)
            guard index > 0 else { return "正在思考" }
            let stage = stages[min(index - 1, stages.count - 1)]
            let direction = stage.hasPrefix("正在") ? String(stage.dropFirst(2)) : stage
            return "正在思考 · \(direction)"
        }
        if let summary, !summary.isEmpty { return "正在思考 · \(summary)" }
        return "正在思考"
    }

    @MainActor
    func resolvedPresentation(at uptime: TimeInterval) -> ChatActivityIslandState {
        if tracksTaskLiveness, let taskSlot, uptime - taskSlot.lastActivityUptime >= 30 {
            return .activity(kind: .waiting, title: "等待响应", systemImage: "clock", tint: .amber)
        }
        guard showsThought else { return presentation }
        return .activity(kind: presentation.kind,
                         title: Self.thoughtTitle(stages: plannedStages, start: stagePlanStartedUptime,
                                                  summary: liveReasoningSummary, at: uptime),
                         detail: presentation.detail, systemImage: presentation.systemImage,
                         tint: presentation.tint, toolID: presentation.toolID)
    }

    @MainActor
    func shouldDisplayBelow(_ entry: NativeTimelineEntry, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if entry.role == MessageRole.user || !entry.hasVisibleBodyText { return true }
        guard resolvedPresentation(at: uptime).kind == .generating else { return true }
        return taskSlot.map { $0.currentRoundAssistantMessageId != entry.messageId } ?? false
    }
}

/// The clock belongs to the one visible status row, not the timeline or chat screen.
struct ChatTimelineActivityRowView: View {
    let activity: ChatTimelineActivity
    let showAgentName: Bool
    let onAction: (ChatListAction) -> Void
    @State private var now = ProcessInfo.processInfo.systemUptime

    var body: some View {
        let _ = ChatRenderProbe.record("progress")
        let state = activity.resolvedPresentation(at: now)
        let rollup: ChatTaskRollupState = state.kind == .awaitingUser ? .approvalPending(count: 1)
            : (state.tint == .red ? .needsAttention(failedCount: 1, totalCount: 1, failedToolTitle: state.title, reason: nil)
               : .working(currentStepTitle: state.title))
        let displayName = AgentSoulStore.shared.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let segment = ChatTaskRunSegment(
            id: "global-status-\(activity.anchorMessageID)", messageID: activity.anchorMessageID,
            taskId: activity.anchorMessageID, agentDisplayName: displayName.isEmpty ? AgentSoulStore.defaultDisplayName : displayName, subAgentIdentity: nil,
            headline: state.title, subtitle: nil, rollupState: rollup,
            tools: activity.tool.map { [$0] } ?? [], steps: [], reasonings: [], mediaBearingTools: [],
            hidesCompletedStandaloneReasoning: false, deferToolDetails: true
        )
        let card = ChatTaskInlineCardView(segment: segment, onTapToolDetail: { onAction(.openToolDetail(tool: $0)) },
                                          onOpenSubagentConversation: { onAction(.openSubagentConversation(id: $0)) })
        Group {
            if showAgentName { ChatAssistantStack { ChatAgentName(); card } } else { card }
        }
        .task(id: activity.tracksTaskLiveness) {
            guard activity.tracksTaskLiveness else { return }
            now = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled else { return }
                now = ProcessInfo.processInfo.systemUptime
            }
        }
    }
}

