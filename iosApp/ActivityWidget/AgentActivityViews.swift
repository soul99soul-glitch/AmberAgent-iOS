import AppIntents
import SwiftUI
import WidgetKit

struct AgentActivityStatusIcon: View {
    let presentation: AgentActivityPresentation
    let isStale: Bool

    var body: some View {
        Image(systemName: presentation.displaySymbolName(isStale: isStale))
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(presentation.displayPhase(isStale: isStale).activityColor)
    }
}

struct AgentActivityCompactStatus: View {
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        Text(state.presentation.displayStage(isStale: isStale)
            .localizedCompactTitle(languageCode: state.languageCode))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(state.presentation.displayPhase(isStale: isStale).activityColor)
            .lineLimit(1)
            .frame(maxWidth: 52)
            .accessibilityLabel(state.presentation.displayStage(isStale: isStale)
                .localizedTitle(languageCode: state.languageCode))
    }
}

struct AgentActivityElapsedTimer: View {
    let startedAt: Date
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        Group {
            if let end = AgentActivityElapsedTimePolicy.frozenEndDate(
                for: state.presentation.displayPhase(isStale: isStale),
                updatedAt: state.updatedAt,
                isStale: isStale || state.presentation.phase == .stale
            ) {
                let elapsed = Duration.seconds(max(0, end.timeIntervalSince(startedAt)))
                Text(elapsed.formatted(.time(pattern: end.timeIntervalSince(startedAt) >= 3_600
                    ? .hourMinuteSecond(padHourToLength: 1)
                    : .minuteSecond(padMinuteToLength: 1))))
            } else {
                Text(startedAt, style: .timer)
            }
        }
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.65))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        // Timer text has a flexible ideal width in WidgetKit. Bound it so it
        // cannot claim the title's space when the system archives this view.
        .frame(width: 72, alignment: .trailing)
        .multilineTextAlignment(.trailing)
    }
}

struct AgentActivityDetails: View {
    let attributes: AgentActivityAttributes
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool

    private var phase: AgentActivityPhase {
        state.presentation.displayPhase(isStale: isStale)
    }

    private var showsInlineStop: Bool {
        phase == .running || phase == .reconnecting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.presentation.displayStage(isStale: isStale)
                        .localizedTitle(languageCode: state.languageCode))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(attributes.conversationTitle.flatMap { $0.isEmpty ? nil : $0 }
                        ?? state.presentation.kind.localizedTitle(languageCode: state.languageCode))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                if showsInlineStop {
                    AgentActivityControls(attributes: attributes, state: state, isStale: isStale)
                }
            }

            if phase == .running, let progress = state.presentation.progressFraction {
                ProgressView(value: progress)
                    .tint(phase.activityColor)
                    .accessibilityLabel(state.presentation.metric.localizedDetailText(languageCode: state.languageCode) ?? "")
            }

            if phase == .running,
               let detail = state.presentation.metric.localizedDetailText(languageCode: state.languageCode) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }

            if !showsInlineStop {
                AgentActivityControls(attributes: attributes, state: state, isStale: isStale)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

private struct AgentActivityControls: View {
    let attributes: AgentActivityAttributes
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool

    private var controls: [AgentActivityInlineControl] {
        AgentActivityInlineControlPolicy.controls(
            presentation: state.presentation,
            isStale: isStale,
            hasConversation: attributes.conversationId != nil
        )
    }

    var body: some View {
        if let conversationId = attributes.conversationId, !controls.isEmpty {
            HStack(spacing: 8) {
                if controls.contains(.cancel) {
                    Button(intent: IOSCancelAgentRunIntent(runId: attributes.runId, conversationId: conversationId)) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .accessibilityLabel(AgentActivityCopy.text("agent.activity.control.cancel", languageCode: state.languageCode))
                }
                if controls.contains(.retry) {
                    Button(intent: IOSRetryAgentRunIntent(runId: attributes.runId, conversationId: conversationId)) {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .accessibilityLabel(AgentActivityCopy.text("agent.activity.control.retry", languageCode: state.languageCode))
                }
                if controls.contains(.open),
                   let destination = attributes.destinationURL(for: state.presentation.action) {
                    Link(destination: destination) {
                        HStack(spacing: 6) {
                            Text(state.presentation.action?.localizedTitle(languageCode: state.languageCode)
                                ?? AgentActivityCopy.text("agent.activity.action.openTask", languageCode: state.languageCode))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Image(systemName: "arrow.up.right")
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .foregroundStyle(state.presentation.displayPhase(isStale: isStale).activityColor)
                        .background(state.presentation.displayPhase(isStale: isStale).activityColor.opacity(0.14), in: Capsule())
                    }
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .buttonStyle(.plain)
        }
    }
}

struct LockScreenAgentActivityView: View {
    let attributes: AgentActivityAttributes
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentActivityStatusIcon(presentation: state.presentation, isStale: isStale)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(verbatim: "Amber")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.presentation.displayPhase(isStale: isStale).activityColor)
                Spacer(minLength: 8)
                AgentActivityElapsedTimer(startedAt: attributes.startedAt, state: state, isStale: isStale)
            }
            AgentActivityDetails(attributes: attributes, state: state, isStale: isStale)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

extension AgentActivityPhase {
    var activityColor: Color {
        switch self {
        case .running, .waitingForUser:
            Color(red: 1, green: 0.72, blue: 0.36)
        case .reconnecting, .stale:
            Color(red: 1, green: 0.81, blue: 0.44)
        case .completed:
            Color(red: 0.45, green: 0.88, blue: 0.66)
        case .failed:
            Color(red: 1, green: 0.48, blue: 0.46)
        case .cancelled:
            Color(white: 0.7)
        }
    }
}
