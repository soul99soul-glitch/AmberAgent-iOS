import Shared
import SwiftUI

// MARK: - Duet-Style Inline Task Progress & Result Card

struct ChatTaskInlineCardView: View {
    let segment: ChatTaskRunSegment
    var onTapToolDetail: (UIMessagePart.Tool) -> Void
    var onOpenSubagentConversation: ((String) -> Void)? = nil

    @State private var isShowingGroupSheet = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var rollup: ChatTaskRollupState {
        segment.rollupState
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if segment.tools.count == 1 && segment.reasonings.isEmpty,
                   let onlyTool = segment.tools.first,
                   !rollup.isFailureOrNeedsUser {
                    onTapToolDetail(onlyTool)
                } else {
                    isShowingGroupSheet = true
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    // One quiet line: a status dot and what is happening now, replaced in place.
                    HStack(alignment: .center, spacing: 8) {
                        ChatTaskProgressDot(tint: dotColor, isLive: rollup.isLive && !reduceMotion)

                        Text(segment.headline)
                            .font(.system(size: 14))
                            .foregroundStyle(lineColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .contentTransition(.opacity)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: segment.headline)

                        if !rollup.isLive {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(AmberTheme.muted2)
                        }
                    }

                    // A second line only when the user has to know why.
                    if rollup.isFailureOrNeedsUser,
                       let subtitle = segment.subtitle,
                       !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(rollup.tintColor)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.leading, 14)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.985, haptic: .selection))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(segment.agentDisplayName) 任务：\(segment.headline)，\(rollup.statusBadgeText)")
            .accessibilityValue(segment.subtitle ?? "")
            .accessibilityHint(IOSAppLocalization.string("轻点查看任务详情与诊断步骤", defaultValue: "轻点查看任务详情与诊断步骤"))
            .accessibilityIdentifier("chat.taskProgressLine")
            .background {
                // Preserve ScrollViewReader anchor targets for all tools inside this grouped task card
                ForEach(toolAnchorIDs, id: \.self) { anchorID in
                    Color.clear
                        .frame(width: 0, height: 0)
                        .id(anchorID)
                }
            }
        }
        .sheet(isPresented: $isShowingGroupSheet) {
            ChatTaskGroupDetailSheet(
                segment: segment,
                onSelectTool: { tool in
                    isShowingGroupSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        onTapToolDetail(tool)
                    }
                },
                onOpenSubagentConversation: onOpenSubagentConversation
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var toolAnchorIDs: [String] {
        guard segment.toolAnchorIDs.isEmpty else { return Array(Set(segment.toolAnchorIDs)) }
        return segment.tools.map {
            ChatToolCallAnchorTarget.id(messageID: segment.messageID, toolCallID: $0.toolCallId)
        }
    }

    /// Tools finishing is not the task succeeding, so a settled line stays neutral.
    private var dotColor: Color {
        if case .completed = rollup { return AmberTheme.muted2 }
        return rollup.tintColor
    }

    private var lineColor: Color {
        rollup.isLive ? AmberTheme.foreground2 : (rollup.isFailureOrNeedsUser ? rollup.tintColor : AmberTheme.muted)
    }
}

/// Status dot; breathes only while the turn is really running.
struct ChatTaskProgressDot: View {
    let tint: Color
    let isLive: Bool

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 6, height: 6)
            .phaseAnimator(isLive ? [1.0, 0.3] : [1.0]) { dot, opacity in
                dot.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.7)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Secondary Task & Diagnostic Sheet

struct ChatTaskGroupDetailSheet: View {
    let segment: ChatTaskRunSegment
    let onSelectTool: (UIMessagePart.Tool) -> Void
    var onOpenSubagentConversation: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showsReasoningDetails = false

    private var rollup: ChatTaskRollupState {
        segment.rollupState
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard

                    if !segment.steps.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(IOSAppLocalization.string("任务进展与操作记录", defaultValue: "任务进展与操作记录"))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(AmberTheme.muted)
                                .padding(.horizontal, 4)

                            // Offset identity: provider toolCallIds repeat across a turn's messages.
                            ForEach(Array(zip(segment.tools, segment.steps).enumerated()), id: \.offset) { _, row in
                                Button {
                                    onSelectTool(row.0)
                                } label: {
                                    stepRow(step: row.1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !segment.reasonings.isEmpty {
                        reasoningDisclosureSection
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .background(AmberTheme.background.ignoresSafeArea())
            .navigationTitle(IOSAppLocalization.string("任务详情", defaultValue: "任务详情"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(IOSAppLocalization.string("完成", defaultValue: "完成")) {
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                }
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(segment.agentDisplayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AmberTheme.accent.opacity(0.12), in: Capsule())

                Spacer()

                Label(rollup.statusBadgeText, systemImage: rollup.iconSystemName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(rollup.tintColor)
            }

            Text(segment.headline)
                .font(.headline)
                .foregroundStyle(AmberTheme.foreground)

            if let subtitle = segment.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(rollup.isFailureOrNeedsUser ? rollup.tintColor : AmberTheme.foreground2)
            }

            if case .needsAttention(let failedCount, let totalCount, let failedToolTitle, _) = rollup {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(AmberTheme.accentRed)
                        .font(.subheadline)
                    Text("共 \(totalCount) 步操作中，「\(failedToolTitle)」有 \(failedCount) 次失败未恢复。请点击下方具体步骤查看错误原因与原始返回。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.foreground2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AmberTheme.accentRed.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(14)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.8)
        }
    }

    private func stepRow(step: ChatToolStepModel) -> some View {
        HStack(spacing: 10) {
            Image(systemName: stepStatusIcon(for: step.state))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(step.state.color)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)

                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(step.state == .failed ? AmberTheme.accentRed : AmberTheme.muted)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 6)

            Text(step.statusTitle)
                .font(.caption2.weight(.medium))
                .foregroundStyle(step.state.color)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AmberTheme.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(step.state == .failed ? AmberTheme.accentRed.opacity(0.32) : AmberTheme.borderSoft, lineWidth: 0.7)
        }
    }

    private var reasoningDisclosureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    showsReasoningDetails.toggle()
                }
            } label: {
                HStack {
                    Label(
                        IOSAppLocalization.string("诊断：内部思考记录", defaultValue: "诊断：内部思考记录"),
                        systemImage: "brain"
                    )
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AmberTheme.muted)

                    Spacer()

                    Text("\(segment.reasonings.count) 段")
                        .font(.caption2)
                        .foregroundStyle(AmberTheme.muted2)

                    Image(systemName: showsReasoningDetails ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AmberTheme.muted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(AmberTheme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            if showsReasoningDetails {
                ForEach(segment.reasonings) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        if let seconds = entry.durationSeconds {
                            Text(String(format: "思考耗时 %.1f 秒", seconds))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(AmberTheme.muted)
                        }
                        Text(entry.text)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.foreground2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private func stepStatusIcon(for state: ChatToolStepState) -> String {
        switch state {
        case .done: return "checkmark.circle.fill"
        case .active: return "clock.arrow.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }
}
