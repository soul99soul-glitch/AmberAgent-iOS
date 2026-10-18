import SwiftUI
import UIKit
import Shared


typealias ChatSubAgentRunStatusLoader = @MainActor @Sendable ([String]) async -> [String: String]

struct ChatToolTimeline: View {
    let steps: [ChatToolStepModel]
    /// Tapping a step (used for subagent steps, which open a detail sheet). nil = not tappable.
    var onTapStep: ((ChatToolStepModel) -> Void)? = nil
    private let subAgentRunStatusLoader: ChatSubAgentRunStatusLoader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var subAgentRunStatuses: [String: String] = [:]
    @State private var subAgentStatusRevision: UInt = 0

    init(
        steps: [ChatToolStepModel],
        onTapStep: ((ChatToolStepModel) -> Void)? = nil,
        subAgentRunStatusLoader: @escaping ChatSubAgentRunStatusLoader = { conversationHexes in
            await IOSChatBackgroundGenerationCoordinator.shared
                .subAgentRunStatuses(conversationHexes: conversationHexes)
        }
    ) {
        self.steps = steps
        self.onTapStep = onTapStep
        self.subAgentRunStatusLoader = subAgentRunStatusLoader
    }

    private var subAgentThreadIDs: [String] {
        var seen = Set<String>()
        return steps.compactMap { step in
            guard step.canApplySubAgentRunStatus else { return nil }
            guard let threadID = step.subAgentPresentation?.threadID else { return nil }
            let normalized = threadID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private var subAgentStatusTaskID: String {
        let stepIdentity = steps.map { step in
            let threadID = step.subAgentPresentation?.threadID?.lowercased() ?? ""
            let receiptStatus = step.subAgentPresentation?.status ?? ""
            return "\(step.id)|\(threadID)|\(step.state)|\(receiptStatus)"
        }.joined(separator: "\u{1F}")
        return "\(subAgentStatusRevision)|\(stepIdentity)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ChatLayout.assistantPartSpacing) {
            ForEach(steps) { step in
                let tappable = onTapStep != nil
                if tappable {
                    Button { onTapStep?(step) } label: { row(step, chevron: true) }
                        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.98, haptic: .selection))
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(accessibilityTitle(for: step))
                        .accessibilityValue(step.detail ?? "")
                } else {
                    row(step, chevron: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: subAgentStatusTaskID) {
            await refreshSubAgentRunStatuses(for: subAgentThreadIDs)
        }
        .onReceive(NotificationCenter.default.publisher(for: .amberChatBackgroundJobStateDidChange)) { notification in
            refreshSubAgentStatusesIfNeeded(for: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .amberChatBackgroundJobDidTerminate)) { notification in
            refreshSubAgentStatusesIfNeeded(for: notification)
        }
    }

    @MainActor
    private func refreshSubAgentStatusesIfNeeded(for notification: Notification) {
        let eventConversationID = (notification.object as? IOSChatBackgroundJobStateEvent)?.conversationId
            ?? (notification.object as? IOSChatBackgroundJobTerminalEvent)?.conversationId
        guard let eventConversationID else { return }
        let normalized = eventConversationID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard subAgentThreadIDs.contains(normalized) else { return }
        subAgentStatusRevision &+= 1
    }

    @MainActor
    private func refreshSubAgentRunStatuses(for threadIDs: [String]) async {
        guard !threadIDs.isEmpty else {
            if subAgentRunStatuses.isEmpty { return }
            guard !Task.isCancelled else { return }
            subAgentRunStatuses = [:]
            return
        }
        // Fail closed while the batch read is in flight. A reused timeline
        // view can otherwise briefly show the previous child run's terminal
        // check for a newly dispatched run with the same thread id.
        guard !Task.isCancelled else { return }
        subAgentRunStatuses = [:]
        let statuses = await subAgentRunStatusLoader(threadIDs)
        guard !Task.isCancelled else { return }
        subAgentRunStatuses = statuses.reduce(into: [:]) { result, entry in
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return }
            result[key] = entry.value
        }
    }

    private func runtimeState(for step: ChatToolStepModel) -> ChatSubAgentRunVisualState? {
        guard step.canApplySubAgentRunStatus,
              let threadID = step.subAgentPresentation?.threadID else { return nil }
        let normalized = threadID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ChatSubAgentRunVisualState(rawStatus: subAgentRunStatuses[normalized])
    }

    private func displayState(for step: ChatToolStepModel) -> ChatToolStepState {
        runtimeState(for: step)?.stepState ?? step.state
    }

    // Cream capsule: colored tool icon (no backing square) + title (+ optional detail) + trailing
    // status (green check when done, spinner while active, ! on failure). Matches the requested
    // pill style shared with the reasoning card.
    @ViewBuilder
    private func row(_ step: ChatToolStepModel, chevron: Bool) -> some View {
        let state = displayState(for: step)
        let runtimeState = runtimeState(for: step)
        HStack(spacing: 7) {
            if step.isSubAgent, let presentation = step.subAgentPresentation {
                subAgentContents(presentation, state: state, isRunning: state == .active)
            } else {
                // Koboyo 实心剪影：与思考胶囊同系；进行中轻呼吸（不用 SF symbolEffect）。
                Group {
                    if state == .active {
                        ChatKoboyoSpinningIcon(
                            mark: step.koboyoMark,
                            pointSize: 14,
                            tint: UIColor(state.color),
                            isActive: !reduceMotion
                        )
                    } else {
                        ChatKoboyoIcon(step.koboyoMark, size: 14)
                            .foregroundStyle(state.color)
                    }
                }
                .frame(width: 16, height: 16)

                titleLabel(for: step)
            }

            trailingStatus(
                for: state,
                subAgentPresentation: step.subAgentPresentation,
                usesPendingIndicator: runtimeState?.usesPendingIndicator
            )

            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AmberTheme.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Background first (hug the HStack), then cap at the column proposal so long
        // titles truncate without expanding ScrollView content width. Short titles
        // stay chip-sized and leading-aligned — do not use fixedSize(horizontal:false)
        // here or the capsule stretches to full column width.
        .background(state.rowFill, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(state.stroke, lineWidth: 0.7)
        }
        .chatIslandToolAnchorHighlight(toolCallID: step.id)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Capsule(style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle(for: step))
        .accessibilityValue(
            [runtimeState?.accessibilityTitle ?? step.statusTitle, step.detail]
                .compactMap { $0?.nilIfBlank }
                .joined(separator: "，")
        )
        // The parent message animates tool-result updates. Opt this row out so swapping the
        // spinner/checkmark cannot interpolate its layout and produce a one-frame width shake.
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func accessibilityTitle(for step: ChatToolStepModel) -> String {
        let runtimeStatus = runtimeState(for: step)
        let statusTitle = runtimeStatus?.accessibilityTitle ?? step.statusTitle
        guard let presentation = step.subAgentPresentation else {
            return IOSAppLocalization.formatted(
                "%@，状态：%@",
                defaultValue: "%@，状态：%@",
                arguments: [step.title, statusTitle]
            )
        }
        return [
            "@\(presentation.displayName)",
            presentation.workSummary,
            statusTitle
        ]
        .compactMap { $0?.nilIfBlank }
        .joined(separator: "，")
    }

    /// The subagent row intentionally keeps the generic tool title out of the
    /// visual hierarchy. A pixel face + @name + one bounded work/status hint
    /// makes parallel workers distinguishable at a glance, while the trailing
    /// slot preserves the same 44pt tap target and terminal state affordance.
    @ViewBuilder
    private func subAgentContents(
        _ presentation: ChatSubAgentCapsulePresentation,
        state: ChatToolStepState,
        isRunning: Bool
    ) -> some View {
        ChatSubAgentPixelAvatar(identity: presentation.identity, size: 20, isRunning: isRunning)
            .frame(width: 20, height: 20)

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 0) {
                nameLabel(for: presentation)
                if let workSummary = presentation.workSummary {
                    workSummaryLabel(workSummary, color: state.color)
                }
            }
            .frame(minWidth: 0, alignment: .leading)
        } else {
            nameLabel(for: presentation)
            if let workSummary = presentation.workSummary {
                workSummaryLabel(workSummary, color: state.color)
            }
        }
    }

    @ViewBuilder
    private func nameLabel(for presentation: ChatSubAgentCapsulePresentation) -> some View {
        Text("@\(presentation.displayName)")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AmberTheme.foreground2)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private func workSummaryLabel(_ summary: String, color: Color) -> some View {
        Text(summary)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private func titleLabel(for step: ChatToolStepModel) -> some View {
        let title = Text(step.title)
            .font(.footnote.weight(.medium))
            .foregroundStyle(AmberTheme.foreground2)
        if step.phonePresentation != nil, dynamicTypeSize.isAccessibilitySize {
            title.lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            title.lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private func trailingStatus(
        for state: ChatToolStepState,
        subAgentPresentation: ChatSubAgentCapsulePresentation? = nil,
        usesPendingIndicator: Bool? = nil
    ) -> some View {
        Group {
            let pendingStatuses = [
                IOSAppLocalization.string("已启动", defaultValue: "已启动"),
                IOSAppLocalization.string("已排队", defaultValue: "已排队"),
                IOSAppLocalization.string("等待中", defaultValue: "等待中")
            ]
            let shouldUsePendingIndicator = usesPendingIndicator
                ?? (subAgentPresentation.map { pendingStatuses.contains($0.status) } ?? false)
            if state == .done, shouldUsePendingIndicator {
                Circle()
                    .fill(AmberTheme.accentGreen)
                    .frame(width: 7, height: 7)
            } else {
                switch state {
                case .done:
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AmberTheme.accentGreen)
                        .contentTransition(.symbolEffect(.replace.downUp))
                case .active:
                    IOSGenerationActivityIndicator()
                case .cancelled:
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AmberTheme.muted)
                        .contentTransition(.symbolEffect(.replace.downUp))
                case .failed:
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AmberTheme.accentRed)
                        .contentTransition(.symbolEffect(.replace.downUp))
                }
            }
        }
        // 状态指示器固定占位（转圈/对勾/叹号同槽居中）：胶囊宽度在
        // toolCallStarted → toolResultAppended 生命周期内不随状态图标尺寸变化。
        .frame(width: 18, height: 18)
    }
}
