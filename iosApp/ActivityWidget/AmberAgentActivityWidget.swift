import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

@main
struct AmberAgentActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        AmberAgentActivityWidget()
        AmberAlarmActivityWidget()
    }
}

struct AmberAlarmActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<IOSAmberAlarmMetadata>.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "alarm.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.metadata?.title ?? IOSAlarmCopy.defaultTitle)
                        .font(.headline)
                        .lineLimit(2)
                    AmberAlarmStateLabel(mode: context.state.mode)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .activityBackgroundTint(.black.opacity(0.92))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "alarm.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.metadata?.title ?? IOSAlarmCopy.defaultTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    AmberAlarmStateLabel(mode: context.state.mode)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "alarm.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(IOSAlarmCopy.defaultTitle)
            } compactTrailing: {
                AmberAlarmCompactLabel(mode: context.state.mode)
            } minimal: {
                Image(systemName: "alarm.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(
                        "\(IOSAlarmCopy.defaultTitle), \(IOSAlarmCopy.accessibilityState(for: context.state.mode))"
                    )
            }
            .keylineTint(.orange)
        }
    }
}

private struct AmberAlarmStateLabel: View {
    let mode: AlarmPresentationState.Mode

    var body: some View {
        switch mode {
        case .countdown(let countdown):
            if countdown.fireDate > Date() {
                Text(timerInterval: Date()...countdown.fireDate, countsDown: true)
                    .monospacedDigit()
                    .font(.subheadline.weight(.semibold))
            } else {
                Text(IOSAlarmCopy.zeroTime)
                    .monospacedDigit()
                    .font(.subheadline.weight(.semibold))
            }
        case .paused:
            Label(IOSAlarmCopy.paused, systemImage: "pause.fill")
                .font(.subheadline.weight(.semibold))
        case .alert:
            Label(IOSAlarmCopy.ringing, systemImage: "bell.and.waves.left.and.right.fill")
                .font(.subheadline.weight(.semibold))
        @unknown default:
            Text(IOSAlarmCopy.defaultTitle)
                .font(.subheadline.weight(.semibold))
        }
    }
}

private struct AmberAlarmCompactLabel: View {
    let mode: AlarmPresentationState.Mode

    var body: some View {
        switch mode {
        case .countdown(let countdown):
            if countdown.fireDate > Date() {
                Text(timerInterval: Date()...countdown.fireDate, countsDown: true)
                    .monospacedDigit()
                    .font(.caption2.weight(.semibold))
                    .frame(maxWidth: 52)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text(IOSAlarmCopy.zeroTime)
                    .monospacedDigit()
                    .font(.caption2.weight(.semibold))
            }
        case .paused:
            Image(systemName: "pause.fill")
                .accessibilityLabel(IOSAlarmCopy.paused)
        case .alert:
            Image(systemName: "bell.fill")
                .accessibilityLabel(IOSAlarmCopy.ringing)
        @unknown default:
            Image(systemName: "alarm")
                .accessibilityLabel(IOSAlarmCopy.defaultTitle)
        }
    }
}

struct AmberAgentActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            LockScreenAgentActivityView(
                attributes: context.attributes,
                state: context.state,
                isStale: context.isStale
            )
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
            .widgetURL(context.attributes.destinationURL(for: context.state.presentation.action))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AgentActivityStatusIcon(presentation: context.state.presentation, isStale: context.isStale)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AgentActivityElapsedTimer(
                        startedAt: context.attributes.startedAt,
                        state: context.state,
                        isStale: context.isStale
                    )
                    .frame(height: 28)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    AgentActivityDetails(
                        attributes: context.attributes,
                        state: context.state,
                        isStale: context.isStale
                    )
                    .padding(.top, 4)
                }
            } compactLeading: {
                AgentActivityStatusIcon(presentation: context.state.presentation, isStale: context.isStale)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
            } compactTrailing: {
                AgentActivityCompactStatus(state: context.state, isStale: context.isStale)
            } minimal: {
                AgentActivityStatusIcon(presentation: context.state.presentation, isStale: context.isStale)
                    .frame(width: 22, height: 22)
                    .accessibilityLabel(context.state.presentation.displayStage(isStale: context.isStale)
                        .localizedTitle(languageCode: context.state.languageCode))
            }
            .widgetURL(context.attributes.destinationURL(for: context.state.presentation.action))
            .keylineTint(context.state.presentation.displayPhase(isStale: context.isStale).activityColor)
        }
    }
}

#if DEBUG
private let previewAttributes = AgentActivityAttributes(
    runId: "preview-run",
    conversationId: "01234567-89ab-cdef-0123-456789abcdef",
    startedAt: .now.addingTimeInterval(-125),
    conversationTitle: "整理京都旅行攻略与值得一去的地方"
)

#Preview("Lock Screen", as: .content, using: previewAttributes) {
    AmberAgentActivityWidget()
} contentStates: {
    AgentActivityAttributes.ContentState(presentation: .defaultRunning, updatedAt: .now, languageCode: "zh-Hans")
    AgentActivityAttributes.ContentState(presentation: .waitingForUser(), updatedAt: .now, languageCode: "zh-Hans")
    AgentActivityAttributes.ContentState(presentation: .completed(), updatedAt: .now, languageCode: "zh-Hans")
}

#Preview("Expanded", as: .dynamicIsland(.expanded), using: previewAttributes) {
    AmberAgentActivityWidget()
} contentStates: {
    AgentActivityAttributes.ContentState(presentation: .defaultRunning, updatedAt: .now, languageCode: "zh-Hans")
    AgentActivityAttributes.ContentState(presentation: .measurablePreview(kind: .document, completed: 12, total: 30, unit: .item), updatedAt: .now, languageCode: "zh-Hans")
    AgentActivityAttributes.ContentState(presentation: .waitingForUser(), updatedAt: .now, languageCode: "zh-Hans")
    AgentActivityAttributes.ContentState(presentation: .failed(), updatedAt: .now, languageCode: "en")
}

#Preview("Compact", as: .dynamicIsland(.compact), using: previewAttributes) {
    AmberAgentActivityWidget()
} contentStates: {
    AgentActivityAttributes.ContentState(presentation: .defaultRunning, updatedAt: .now, languageCode: "zh-Hans")
    AgentActivityAttributes.ContentState(presentation: .reconnecting(), updatedAt: .now, languageCode: "en")
}

#Preview("Minimal", as: .dynamicIsland(.minimal), using: previewAttributes) {
    AmberAgentActivityWidget()
} contentStates: {
    AgentActivityAttributes.ContentState(presentation: .defaultRunning, updatedAt: .now, languageCode: "zh-Hans")
    AgentActivityAttributes.ContentState(presentation: .waitingForUser(), updatedAt: .now, languageCode: "zh-Hans")
}
#endif
