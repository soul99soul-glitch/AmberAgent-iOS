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
            // 浅色壁纸上 0.55 时 40% 白的说明文字对比度只有约 2:1。
            .activityBackgroundTint(.black.opacity(0.72))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(context.attributes.destinationURL(for: context.state.presentation.action))
        } dynamicIsland: { context in
            let phase = context.state.presentation.displayPhase(isStale: context.isStale)
            // 左右贴着摄像头放标志和时间并垂直居中；会话名与状态居中放在摄像头正下方，
            // 填满中间；底部一行步骤或按钮。两侧优先分宽，标题拿剩下的，避免右上角被截断。边距用系统默认值，内容不进圆角。
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    // 两侧与中间的标题块底对齐；居中时比标题高约 8pt，看起来是歪的。
                    AgentActivityMark(size: 30, faded: phase == .stale)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                DynamicIslandExpandedRegion(.trailing, priority: 1) {
                    AgentActivityTrailingFact(
                        startedAt: context.attributes.startedAt,
                        state: context.state,
                        phase: phase
                    )
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                DynamicIslandExpandedRegion(.center) {
                    AgentActivityHeadline(
                        attributes: context.attributes,
                        state: context.state,
                        phase: phase,
                        centered: true
                    )
                }
                DynamicIslandExpandedRegion(.bottom) {
                    AgentActivityBody(
                        attributes: context.attributes,
                        state: context.state,
                        phase: phase
                    )
                    .padding(.top, 6)
                }
            } compactLeading: {
                AgentActivityCompactStatus(state: context.state, phase: phase)
            } compactTrailing: {
                AgentActivityCompactTimer(
                    startedAt: context.attributes.startedAt,
                    state: context.state,
                    phase: phase
                )
            } minimal: {
                AgentActivityMinimalMark(phase: phase)
                    // 标志和圆环都不是可读元素，需合成一个元素才能挂上标签。
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(AgentActivityMinimalMark.accessibilityLabel(state: context.state, phase: phase))
            }
            .widgetURL(context.attributes.destinationURL(for: context.state.presentation.action))
            .keylineTint(phase.keylineRole?.color)
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

private let previewWaiting = AgentActivityPresentation.waitingForUser(
    approval: AgentActivityApproval(requestId: "preview-request", title: "npm install three")
)
private let previewCompleted = AgentActivityPresentation.completed()
private let previewFailed: AgentActivityPresentation = {
    var presentation = AgentActivityPresentation.failed(retryable: true)
    presentation.failureReason = .network
    return presentation
}()
private let previewRunning: AgentActivityPresentation = {
    var presentation = AgentActivityPresentation.runningTool(
        toolName: "scrape_web",
        input: #"{"url":"https://www.japan-guide.com/e/e3900.html"}"#
    )
    presentation.recentSteps = [
        AgentActivityStep(stage: .searching, detail: "京都红叶 最佳时间"),
        AgentActivityStep(stage: .readingWeb, count: 3),
    ]
    return presentation
}()

#Preview("Lock Screen", as: .content, using: previewAttributes) {
    AmberAgentActivityWidget()
} contentStates: {
    AgentActivityAttributes.ContentState(presentation: previewRunning, updatedAt: .now, languageCode: "zh-Hans")
    AgentActivityAttributes.ContentState(presentation: previewWaiting, updatedAt: .now, languageCode: "zh-Hans")
    AgentActivityAttributes.ContentState(presentation: previewFailed, updatedAt: .now, languageCode: "zh-Hans")
}

#Preview("Expanded", as: .dynamicIsland(.expanded), using: previewAttributes) {
    AmberAgentActivityWidget()
} contentStates: {
    AgentActivityAttributes.ContentState(presentation: previewRunning, updatedAt: .now, languageCode: "zh-Hans")
    AgentActivityAttributes.ContentState(presentation: .measurablePreview(kind: .document, completed: 12, total: 30, unit: .item), updatedAt: .now, languageCode: "zh-Hans")
    AgentActivityAttributes.ContentState(presentation: previewWaiting, updatedAt: .now, languageCode: "zh-Hans")
    AgentActivityAttributes.ContentState(presentation: previewCompleted, updatedAt: .now, languageCode: "zh-Hans")
    AgentActivityAttributes.ContentState(presentation: previewFailed, updatedAt: .now, languageCode: "zh-Hans")
}

#Preview("Compact", as: .dynamicIsland(.compact), using: previewAttributes) {
    AmberAgentActivityWidget()
} contentStates: {
    AgentActivityAttributes.ContentState(presentation: previewRunning, updatedAt: .now, languageCode: "zh-Hans")
    AgentActivityAttributes.ContentState(presentation: previewWaiting, updatedAt: .now, languageCode: "zh-Hans")
    AgentActivityAttributes.ContentState(presentation: previewCompleted, updatedAt: .now, languageCode: "zh-Hans")
    AgentActivityAttributes.ContentState(presentation: .reconnecting(), updatedAt: .now, languageCode: "en")
}

#Preview("Minimal", as: .dynamicIsland(.minimal), using: previewAttributes) {
    AmberAgentActivityWidget()
} contentStates: {
    AgentActivityAttributes.ContentState(presentation: .defaultRunning, updatedAt: .now, languageCode: "zh-Hans")
    AgentActivityAttributes.ContentState(presentation: .waitingForUser(), updatedAt: .now, languageCode: "zh-Hans")
}
#endif
