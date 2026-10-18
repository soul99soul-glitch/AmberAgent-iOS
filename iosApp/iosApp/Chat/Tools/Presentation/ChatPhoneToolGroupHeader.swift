import SwiftUI
import UIKit
import Shared


// MARK: - Phone automation step group header

/// Keep environment identity stable while the timeline refreshes its callback.
@MainActor
final class ChatPhoneToolGroupToggleHandler {
    var action: (@MainActor (String) -> Void)?

    func callAsFunction(_ groupID: String) {
        action?(groupID)
    }
}

private struct ChatPhoneToolGroupToggleKey: EnvironmentKey {
    static let defaultValue: ChatPhoneToolGroupToggleHandler? = nil
}

extension EnvironmentValues {
    /// Toggles one phone-step group's expanded state (presentation state owned by the timeline).
    var chatPhoneToolGroupToggle: ChatPhoneToolGroupToggleHandler? {
        get { self[ChatPhoneToolGroupToggleKey.self] }
        set { self[ChatPhoneToolGroupToggleKey.self] = newValue }
    }
}

/// Collapsed row for a run of phone-automation steps: "手机操作 · N 步", the latest
/// step (live-updating), elapsed time, and anything needing the user's attention.
/// Same capsule chrome as `ChatToolTimeline` rows; expanded steps are rendered by
/// their own messages below the header.
struct ChatPhoneToolGroupHeader: View {
    /// Leading inset for expanded steps (head and member bubbles) under the header.
    static let expandedStepIndent: CGFloat = 12
    static let expansionAnimation: Animation = .smooth(duration: 0.28)

    let summary: ChatPhoneToolGroupSummary
    @Environment(\.chatPhoneToolGroupToggle) private var toggle
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let latestStep = ChatToolStepModel(tool: summary.latestTool)
        let state = Self.displayState(summary: summary, latestStep: latestStep)
        let tint = Self.tint(summary: summary, state: state)
        Button {
            toggle?.callAsFunction(summary.id)
        } label: {
            if dynamicTypeSize.isAccessibilitySize {
                // Large text: stack the lines (a single HStack would squeeze the
                // detail to one glyph per line) and use a rounded rect, not a capsule.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        icon(state: state, tint: tint)
                        Text(Self.title(stepCount: summary.stepCount))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Self.statusGlyph(state: state, attention: summary.attention)
                            .frame(width: 18, height: 18)
                        chevron
                    }
                    detailLabel(latestStep: latestStep, tint: tint, wraps: true)
                    elapsedLabel
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Self.fill(summary: summary, state: state),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Self.stroke(summary: summary, state: state),
                                lineWidth: summary.attention == nil ? 0.7 : 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                HStack(spacing: 7) {
                    icon(state: state, tint: tint)
                    Text(Self.title(stepCount: summary.stepCount))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground2)
                        .lineLimit(1)
                        .layoutPriority(1)
                    detailLabel(latestStep: latestStep, tint: tint, wraps: false)
                    elapsedLabel
                    Self.statusGlyph(state: state, attention: summary.attention)
                        .frame(width: 18, height: 18)
                    chevron
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Self.fill(summary: summary, state: state), in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Self.stroke(summary: summary, state: state),
                                lineWidth: summary.attention == nil ? 0.7 : 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Capsule(style: .continuous))
            }
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.98, haptic: .selection))
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(summary: summary, latestStep: latestStep, state: state))
        .accessibilityValue(latestStep.title)
        .accessibilityHint(IOSAppLocalization.string(
            summary.isExpanded ? "轻点收起步骤" : "轻点展开步骤",
            defaultValue: summary.isExpanded ? "轻点收起步骤" : "轻点展开步骤"
        ))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("chat.phoneToolGroup.header")
        // Overrides the head bubble's message menu: a long-press on the group must
        // never delete/regenerate whichever message happens to host the header.
        .contextMenu {
            Button {
                toggle?(summary.id)
            } label: {
                Label(
                    IOSAppLocalization.string(
                        summary.isExpanded ? "收起步骤" : "展开步骤",
                        defaultValue: summary.isExpanded ? "收起步骤" : "展开步骤"
                    ),
                    systemImage: summary.isExpanded ? "chevron.up" : "chevron.down"
                )
            }
        }
        // Status swaps must not interpolate the capsule width (same as tool rows).
        .transaction { transaction in
            transaction.animation = nil
        }
        // Move the header with its row while status text keeps its width-update policy.
        .geometryGroup()
    }

    @ViewBuilder
    private func icon(state: ChatToolStepState, tint: Color) -> some View {
        Group {
            if state == .active {
                ChatKoboyoSpinningIcon(
                    mark: ChatToolVisualKind.apple.koboyoMark,
                    pointSize: 14,
                    tint: UIColor(tint),
                    isActive: !reduceMotion
                )
            } else {
                ChatKoboyoIcon(ChatToolVisualKind.apple.koboyoMark, size: 14)
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 16, height: 16)
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AmberTheme.muted)
            .rotationEffect(.degrees(summary.isExpanded ? -180 : 0))
            .animation(reduceMotion ? nil : Self.expansionAnimation, value: summary.isExpanded)
    }

    @ViewBuilder
    private func detailLabel(latestStep: ChatToolStepModel, tint: Color, wraps: Bool) -> some View {
        let text = Text(Self.detail(summary: summary, latestStep: latestStep))
            .font(.caption2.weight(.medium))
            .foregroundStyle(summary.attention == nil ? AmberTheme.muted : tint)
        if wraps {
            text.fixedSize(horizontal: false, vertical: true)
        } else {
            text.lineLimit(1).truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var elapsedLabel: some View {
        // A ticking timer next to wrapping text could re-wrap (change height) every
        // second at accessibility sizes; there it is shown only once the run ends.
        if let startedAt = summary.startedAt,
           !(summary.isLive && dynamicTypeSize.isAccessibilitySize) {
            Group {
                if summary.isLive {
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                } else if let finishedAt = summary.finishedAt {
                    Text(Self.elapsedText(seconds: finishedAt.timeIntervalSince(startedAt), locale: locale))
                }
            }
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(AmberTheme.muted)
            .lineLimit(1)
            .fixedSize()
        }
    }

    static func displayState(summary: ChatPhoneToolGroupSummary, latestStep: ChatToolStepModel) -> ChatToolStepState {
        if summary.attention == .approvalPending { return .active }
        if summary.isLive { return .active }
        return latestStep.state
    }

    static func title(stepCount: Int) -> String {
        IOSAppLocalization.formatted("手机操作 · %ld 步", defaultValue: "手机操作 · %ld 步", arguments: [stepCount])
    }

    static func detail(summary: ChatPhoneToolGroupSummary, latestStep: ChatToolStepModel) -> String {
        switch summary.attention {
        case .approvalPending:
            return IOSAppLocalization.formatted("%ld 步待你批准", defaultValue: "%ld 步待你批准", arguments: [summary.attentionCount])
        case .outcomeUnknown:
            return IOSAppLocalization.formatted("%ld 步结果未知，需核对", defaultValue: "%ld 步结果未知，需核对",
                                                arguments: [summary.attentionCount])
        case .failed:
            return IOSAppLocalization.formatted("最新一步%@", defaultValue: "最新一步%@", arguments: [latestStep.statusTitle])
                + " · " + latestStep.title
        case nil:
            return latestStep.title
        }
    }

    static func accessibilityLabel(
        summary: ChatPhoneToolGroupSummary,
        latestStep: ChatToolStepModel,
        state: ChatToolStepState
    ) -> String {
        let status = summary.attention != nil
            ? detail(summary: summary, latestStep: latestStep)
            : (summary.isLive ? state.accessibilityTitle : latestStep.statusTitle)
        let expansion = IOSAppLocalization.string(
            summary.isExpanded ? "已展开" : "已收起",
            defaultValue: summary.isExpanded ? "已展开" : "已收起"
        )
        return [title(stepCount: summary.stepCount), status, expansion].joined(separator: "，")
    }

    /// Positional (1:05 / 1:02:03), matching the live `Text(timerInterval:)` format.
    static func elapsedText(seconds: TimeInterval, locale: Locale = .current) -> String {
        let total = max(0, Int(seconds.rounded()))
        let pattern: Duration.TimeFormatStyle.Pattern = total >= 3_600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(total).formatted(.time(pattern: pattern).locale(locale))
    }

    static func tint(summary: ChatPhoneToolGroupSummary, state: ChatToolStepState) -> Color {
        switch summary.attention {
        case .approvalPending: AmberTheme.accentAmber
        case .outcomeUnknown, .failed: AmberTheme.accentRed
        case nil: state.color
        }
    }

    private static func fill(summary: ChatPhoneToolGroupSummary, state: ChatToolStepState) -> Color {
        switch summary.attention {
        case .approvalPending: AmberTheme.accentAmber.opacity(0.12)
        case .outcomeUnknown, .failed: AmberTheme.accentRed.opacity(0.10)
        case nil: state.rowFill
        }
    }

    private static func stroke(summary: ChatPhoneToolGroupSummary, state: ChatToolStepState) -> Color {
        switch summary.attention {
        case .approvalPending: AmberTheme.accentAmber.opacity(0.45)
        case .outcomeUnknown, .failed: AmberTheme.accentRed.opacity(0.35)
        case nil: state.stroke
        }
    }

    @ViewBuilder
    private static func statusGlyph(state: ChatToolStepState, attention: ChatPhoneToolGroupAttention?) -> some View {
        if attention == .approvalPending {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AmberTheme.accentAmber)
        } else if attention == .outcomeUnknown {
            Image(systemName: "questionmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AmberTheme.accentRed)
        } else {
            switch state {
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AmberTheme.accentGreen)
            case .active:
                IOSGenerationActivityIndicator()
            case .cancelled:
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AmberTheme.muted)
            case .failed:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AmberTheme.accentRed)
            }
        }
    }
}
