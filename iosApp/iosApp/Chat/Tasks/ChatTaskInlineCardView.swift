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
                VStack(alignment: .leading, spacing: 5) {
                    // Argon single-line task header: ╭─ Headline · [● Status] >
                    HStack(alignment: .center, spacing: 8) {
                        DuetBranchConnectorShape()
                            .stroke(
                                rollup.isFailureOrNeedsUser ? rollup.tintColor.opacity(0.65) : AmberTheme.accent.opacity(0.38),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                            )
                            .frame(width: 11, height: 14)

                        Text(segment.headline)
                            .font(.system(size: 13.2, weight: .semibold))
                            .foregroundStyle(AmberTheme.foreground)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 6)

                        statusPill

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(AmberTheme.muted2)
                    }

                    // Second line is reserved exclusively for unrecovered failure or pending user approval
                    if rollup.isFailureOrNeedsUser,
                       let subtitle = segment.subtitle,
                       !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(rollup.tintColor)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.leading, 20)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10.5)
                .background(cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(cardStroke, lineWidth: rollup.isFailureOrNeedsUser ? 1.0 : 0.8)
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.985, haptic: .selection))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(segment.agentDisplayName) 任务：\(segment.headline)，\(rollup.statusBadgeText)")
            .accessibilityValue(segment.subtitle ?? "")
            .accessibilityHint(IOSAppLocalization.string("轻点查看任务详情与诊断步骤", defaultValue: "轻点查看任务详情与诊断步骤"))
            .accessibilityIdentifier("chat.duetTaskCard.\(segment.id)")
            .background {
                // Preserve ScrollViewReader anchor targets for all tools inside this grouped task card
                ForEach(segment.tools, id: \.toolCallId) { tool in
                    Color.clear
                        .frame(width: 0, height: 0)
                        .id(
                            ChatToolCallAnchorTarget.id(
                                messageID: segment.messageID,
                                toolCallID: tool.toolCallId
                            )
                        )
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

    @ViewBuilder
    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(rollup.tintColor)
                .frame(width: 5, height: 5)

            Text(segment.inlineStatusBadgeText)
                .font(.system(size: 11.2, weight: .medium))
                .foregroundStyle(rollup.tintColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 8.5)
        .padding(.vertical, 3.5)
        .background(rollup.tintColor.opacity(0.09), in: Capsule(style: .continuous))
    }

    private var cardFill: Color {
        switch rollup {
        case .needsAttention:
            return AmberTheme.accentRed.opacity(0.045)
        case .approvalPending:
            return AmberTheme.accentAmber.opacity(0.08)
        case .working, .completed, .cancelled:
            return AmberTheme.surfaceElevated
        }
    }

    private var cardStroke: Color {
        switch rollup {
        case .needsAttention:
            return AmberTheme.accentRed.opacity(0.28)
        case .approvalPending:
            return AmberTheme.accentAmber.opacity(0.36)
        case .working, .completed, .cancelled:
            return AmberTheme.border
        }
    }
}

/// Draws the Duet-style `╭─` elbow connector on the leading side of an inline task row.
private struct DuetBranchConnectorShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let startX = rect.minX + 2
        let bottomY = rect.maxY
        let midY = rect.midY - 1
        let radius: CGFloat = 5
        path.move(to: CGPoint(x: startX, y: bottomY))
        path.addLine(to: CGPoint(x: startX, y: midY + radius))
        path.addQuadCurve(
            to: CGPoint(x: startX + radius, y: midY),
            control: CGPoint(x: startX, y: midY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: midY))
        return path
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

                            ForEach(Array(zip(segment.tools, segment.steps)), id: \.1.id) { tool, step in
                                Button {
                                    onSelectTool(tool)
                                } label: {
                                    stepRow(step: step)
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
