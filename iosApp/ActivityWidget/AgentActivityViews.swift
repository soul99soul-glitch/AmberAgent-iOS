import AppIntents
import SwiftUI
import WidgetKit

/// 灵动岛 v3 配色：颜色只用来表达状态，其余一律是白色的不同透明度。
enum AgentIslandPalette {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.66)
    // 0.40 在黑底上只有约 3.7:1，低于 4.5:1；0.50 约 5.3:1，仍与二级拉开层次。
    static let tertiary = Color.white.opacity(0.50)
    static let line = Color.white.opacity(0.12)
    static let well = Color.white.opacity(0.07)
    static let accent = Color(red: 0.787, green: 0.612, blue: 0.328)
    static let ok = Color(red: 0.45, green: 0.869, blue: 0.642)
    static let danger = Color(red: 0.957, green: 0.482, blue: 0.454)
}

extension AgentActivityKeylineRole {
    var color: Color {
        switch self {
        case .attention: AgentIslandPalette.accent
        case .failure: AgentIslandPalette.danger.opacity(0.45)
        }
    }
}

private func copy(_ key: String, _ state: AgentActivityAttributes.ContentState) -> String {
    AgentActivityCopy.text("agent.activity.\(key)", languageCode: state.languageCode)
}

/// 计时与时刻文本跟随 App 语言，而不是系统语言，避免和其余文案混排。
private func activityLocale(_ state: AgentActivityAttributes.ContentState) -> Locale {
    state.languageCode.map(Locale.init(identifier:)) ?? .current
}

/// 完成用时是格式化好的字符串，`.environment(\.locale)` 管不到，需在格式化时指定语言。
private func elapsedText(_ seconds: TimeInterval, _ state: AgentActivityAttributes.ContentState) -> String {
    Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3_600
        ? .hourMinuteSecond(padHourToLength: 1)
        : .minuteSecond(padMinuteToLength: 1)).locale(activityLocale(state)))
}

// MARK: - 标志

/// 不带底板的 Amber 标志。失联时褪成灰色，不再像报错。
struct AgentActivityMark: View {
    var size: CGFloat
    var faded = false

    var body: some View {
        Image("AmberMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .grayscale(faded ? 1 : 0)
            .opacity(faded ? 0.42 : 1)
            .accessibilityHidden(true)
    }
}

/// 最小态：标志外一圈细环表示运行/待确认，右下角徽标表示完成/失败。
struct AgentActivityMinimalMark: View {
    let phase: AgentActivityPhase

    /// 跟随 App 语言；失联读"暂停"，与界面一致。
    static func accessibilityLabel(state: AgentActivityAttributes.ContentState, phase: AgentActivityPhase) -> String {
        let presentation = state.presentation
        let status = switch phase {
        case .running: presentation.stage.localizedTitle(languageCode: state.languageCode)
        case .reconnecting: copy("sub.reconnecting", state)
        case .stale: copy("status.paused", state)
        case .waitingForUser: copy("sub.waiting", state)
        case .completed: copy("sub.completed", state)
        case .failed: copy("sub.failed", state)
        case .cancelled: copy("sub.cancelled", state)
        }
        return "\(presentation.kind.localizedTitle(languageCode: state.languageCode)), \(status)"
    }

    var body: some View {
        AgentActivityMark(size: 20, faded: phase == .stale)
            .padding(4)
            .overlay { ring }
            .overlay(alignment: .bottomTrailing) { badge }
    }

    @ViewBuilder
    private var ring: some View {
        switch phase {
        case .running, .reconnecting:
            // 设计稿：上、右两段四分之一弧，一实一淡，表示"在转"而不是进度百分比。
            ZStack {
                Circle().trim(from: 0, to: 0.25)
                    .stroke(AgentIslandPalette.primary, lineWidth: 1.5)
                Circle().trim(from: 0.25, to: 0.5)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1.5)
            }
            .rotationEffect(.degrees(-90))
        case .waitingForUser:
            Circle().stroke(AgentIslandPalette.accent, lineWidth: 1.5)
        case .stale, .completed, .failed, .cancelled:
            EmptyView()
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch phase {
        case .completed:
            badgeView(symbol: "checkmark", fill: AgentIslandPalette.ok)
        case .failed:
            badgeView(symbol: "exclamationmark", fill: AgentIslandPalette.danger)
        case .running, .reconnecting, .waitingForUser, .stale, .cancelled:
            EmptyView()
        }
    }

    private func badgeView(symbol: String, fill: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 6.5, weight: .black))
            .foregroundStyle(.black)
            .frame(width: 11, height: 11)
            .background(fill, in: Circle())
            // 2pt 黑色外环画在填充之外，保持 11pt 实心徽标（描边居中会吃掉填充）。
            .padding(2)
            .background(.black, in: Circle())
            .offset(x: 2, y: 2)
    }
}

// MARK: - 右侧：时间 + 说明

struct AgentActivityTrailingFact: View {
    let startedAt: Date
    let state: AgentActivityAttributes.ContentState
    let phase: AgentActivityPhase

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            value
                .font(.system(size: 19, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(phase == .stale ? AgentIslandPalette.secondary : AgentIslandPalette.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                // 计时文本在 WidgetKit 里会撑满提议宽度；右侧区域又会被标题压到很窄，
                // 真机上曾截成"0:…"，所以定宽。系统按两侧较宽者对称留位，每多 1pt
                // 中间标题就少 2pt：56 放得下"12:34"，"1:02:03"缩到约 0.8。
                .frame(width: 56, alignment: .trailing)
                .multilineTextAlignment(.trailing)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(AgentIslandPalette.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 56, alignment: .trailing)
        .environment(\.locale, activityLocale(state))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var value: some View {
        switch phase {
        case .running, .reconnecting:
            Text(startedAt, style: .timer)
        case .stale:
            // "2 分钟前"：只到分钟，不跳秒，和"暂停"的语义一致。
            // 英/俄文（"25 minutes ago"）缩到最小也放不下，改显示最后更新的时刻。
            ViewThatFits(in: .horizontal) {
                Text(.currentDate, format: .reference(
                    to: state.updatedAt,
                    allowedFields: [.minute, .hour, .day],
                    maxFieldCount: 1
                ))
                .fixedSize()
                Text(state.updatedAt, style: .time)
            }
        case .waitingForUser:
            Text(state.updatedAt, style: .timer)
        case .failed:
            Text(state.updatedAt, style: .time)
        case .completed, .cancelled:
            let seconds = max(0, state.updatedAt.timeIntervalSince(startedAt))
            Text(elapsedText(seconds, state))
        }
    }

    private var caption: String {
        switch phase {
        case .running, .reconnecting: copy("trail.elapsed", state)
        case .stale: copy("trail.lastUpdate", state)
        case .waitingForUser: copy("trail.waited", state)
        case .failed: copy("trail.interruptedAt", state)
        case .completed, .cancelled: copy("trail.duration", state)
        }
    }
}

// MARK: - 会话名 + 状态说明

struct AgentActivityHeadline: View {
    let attributes: AgentActivityAttributes
    let state: AgentActivityAttributes.ContentState
    let phase: AgentActivityPhase
    /// 锁屏是共享表面：待确认只写类别，不写具体操作。
    var isLockScreen = false
    /// 灵动岛展开态居中放在摄像头正下方；锁屏跟随标志左对齐。
    var centered = false

    private var title: String {
        attributes.conversationTitle.flatMap { $0.isEmpty ? nil : $0 }
            ?? state.presentation.kind.localizedTitle(languageCode: state.languageCode)
    }

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AgentIslandPalette.primary)
                .lineLimit(1)
            subtitle
                .font(.system(size: 13))
                .foregroundStyle(AgentIslandPalette.secondary)
                // 锁屏没有灵动岛 160pt 的高度上限，长文案（英/俄的暂停、失败说明）可换行。
                .lineLimit(isLockScreen ? 2 : 1)
                // 写不下时截尾（默认）：搜索词的开头信息量最大；
                // 省略中间会把本就截过的搜索词再挖掉一段，只剩零碎字词。
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: Text {
        let presentation = state.presentation
        switch phase {
        case .running:
            // 展开态这里写当前操作的具体内容，底部步骤行只写阶段，两者同时可见。
            // 锁屏是共享表面，不写搜索词、网址、文件名。
            if !isLockScreen, let detail = presentation.stepDetail,
               AgentActivityStepDetailPolicy.detailedStages.contains(presentation.stage) {
                return Text(String(format: copy("now.\(presentation.stage.rawValue)", state), detail))
            }
            return Text(copy("sub.running", state))
        case .reconnecting:
            return Text(copy("sub.reconnecting", state))
        case .stale:
            return Text(copy("sub.stale", state))
        case .cancelled:
            return Text(copy("sub.cancelled", state))
        case .waitingForUser:
            // 灵动岛只写要批准的内容本身：琥珀描边和按钮已表达"待确认"，
            // 省下前缀，命令才不会被截掉。
            if !isLockScreen, let approvalTitle = presentation.approval?.title {
                var text = AttributedString(approvalTitle)
                text.foregroundColor = AgentIslandPalette.accent
                return Text(text)
            }
            let detail = isLockScreen
                ? presentation.kind.localizedTitle(languageCode: state.languageCode)
                : presentation.approval?.title
                    ?? presentation.kind.localizedTitle(languageCode: state.languageCode)
            return tinted(copy("sub.waiting", state), AgentIslandPalette.accent, then: detail)
        case .completed:
            return tinted(
                copy("sub.completed", state),
                AgentIslandPalette.ok,
                then: presentation.metric.localizedDetailText(languageCode: state.languageCode)
            )
        case .failed:
            let reason = presentation.failureReason.map { copy("failure.\($0.rawValue)", state) }
                ?? copy("sub.failed", state)
            return tinted(
                reason,
                AgentIslandPalette.danger,
                then: presentation.retryable == true ? copy("sub.retryable", state) : nil
            )
        }
    }

    /// 着色的状态词 + " · 说明"。用 AttributedString 拼接（Text + Text 在 iOS 26 已弃用）。
    private func tinted(_ lead: String, _ color: Color, then detail: String?) -> Text {
        var text = AttributedString(lead)
        text.foregroundColor = color
        if let detail {
            text += AttributedString(" · \(detail)")
        }
        return Text(text)
    }
}

// MARK: - 底部：步骤行 / 按钮

struct AgentActivityBody: View {
    let attributes: AgentActivityAttributes
    let state: AgentActivityAttributes.ContentState
    let phase: AgentActivityPhase
    /// 锁屏是共享表面，步骤只显示类别和数量，不显示搜索词、网址、文件名。
    var showsContent = true

    private var controls: [AgentActivityInlineControl] {
        AgentActivityInlineControlPolicy.controls(
            presentation: state.presentation,
            isStale: phase == .stale,
            hasConversation: attributes.conversationId != nil
        )
    }

    var body: some View {
        if let conversationId = attributes.conversationId, !controls.isEmpty {
            AgentActivityButtons(
                attributes: attributes,
                conversationId: conversationId,
                state: state,
                controls: controls
            )
        } else if let mode = stepsMode {
            AgentActivitySteps(state: state, mode: mode, showsContent: showsContent)
        }
    }

    /// 完成/中断时列出这次做过的步骤；一步都没有就不显示，避免和状态行重复。
    private var stepsMode: AgentActivitySteps.Mode? {
        let hasFinishedSteps = !(state.presentation.recentSteps ?? []).isEmpty
        switch phase {
        case .running, .reconnecting: return .running
        case .stale: return .paused
        case .completed: return hasFinishedSteps ? .completed : nil
        case .failed: return hasFinishedSteps ? .failed : nil
        case .waitingForUser, .cancelled: return nil
        }
    }
}

/// 一行最多三步：做完的打勾，最后一项是当前一步（运行中亮起、失联时暂停）
/// 或结果（完成打绿勾、中断标红）。宽度不够时依次退到两步、一步。
struct AgentActivitySteps: View {
    enum Mode {
        case running
        case paused
        case completed
        case failed
    }

    let state: AgentActivityAttributes.ContentState
    let mode: Mode
    var showsContent = true

    var body: some View {
        let finished = Array((state.presentation.recentSteps ?? [])
            .suffix(AgentActivityStepHistoryPolicy.maxFinishedSteps))
        // 先保证步数（整体进度），再保证每步的内容：
        // 三步带内容 → 三步只写类别 → 两步带内容 → …
        ViewThatFits(in: .horizontal) {
            ForEach((0...finished.count).reversed(), id: \.self) { shown in
                row(finished: Array(finished.suffix(shown)), detailed: true).fixedSize()
                row(finished: Array(finished.suffix(shown)), detailed: false).fixedSize()
            }
            // 兜底：连当前一步都放不下时允许中间截断，不溢出胶囊。
            row(finished: [], detailed: false).truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
        .background(AgentIslandPalette.well, in: Capsule())
    }

    private func text(_ key: String) -> String {
        AgentActivityCopy.text("agent.activity.\(key)", languageCode: state.languageCode)
    }

    private func finishedLabel(_ finished: AgentActivityStep, detailed: Bool) -> String {
        let stage = finished.stage.rawValue
        if finished.count > 1, AgentActivityStepDetailPolicy.countableStages.contains(finished.stage) {
            return String(format: text("doneCount.\(stage)"), finished.count)
        }
        if showsContent, detailed, let detail = finished.detail {
            return String(format: text("doneDetail.\(stage)"), detail)
        }
        return text("done.\(stage)")
    }

    /// 当前一步只写阶段名，具体内容在标题下方的副标题里。
    private var currentLabel: String {
        state.presentation.stage.localizedTitle(languageCode: state.languageCode)
    }

    private func row(finished: [AgentActivityStep], detailed: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(finished.enumerated()), id: \.offset) { _, finishedStep in
                step(icon: Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)),
                     text: finishedLabel(finishedStep, detailed: detailed),
                     color: AgentIslandPalette.tertiary, weight: .medium)
                connector
            }
            switch mode {
            case .running:
                step(icon: Circle().fill(AgentIslandPalette.primary).frame(width: 6, height: 6),
                     text: currentLabel, color: AgentIslandPalette.primary, weight: .semibold)
            case .paused:
                // 阶段名带"正在"，配暂停图标自相矛盾；暂停时只写"暂停"。
                step(icon: Image(systemName: "pause.fill").font(.system(size: 9)),
                     text: text("status.paused"), color: AgentIslandPalette.secondary, weight: .medium)
            case .completed:
                step(icon: Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)),
                     text: text("status.done"), color: AgentIslandPalette.ok, weight: .semibold)
            case .failed:
                step(icon: Image(systemName: "exclamationmark").font(.system(size: 9, weight: .heavy)),
                     text: text("status.interrupted"), color: AgentIslandPalette.danger, weight: .semibold)
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
    }

    private var connector: some View {
        Rectangle()
            .fill(Color.white.opacity(0.22))
            .frame(width: 12, height: 1)
            .accessibilityHidden(true)
    }

    private func step(icon: some View, text: String, color: Color, weight: Font.Weight) -> some View {
        HStack(spacing: 5) {
            icon.accessibilityHidden(true)
            Text(text).fontWeight(weight)
        }
        .foregroundStyle(color)
    }
}

private struct AgentActivityButtons: View {
    let attributes: AgentActivityAttributes
    let conversationId: String
    let state: AgentActivityAttributes.ContentState
    let controls: [AgentActivityInlineControl]

    var body: some View {
        HStack(spacing: 8) {
            if let approval = state.presentation.approval,
               controls.contains(.approve) {
                Button(intent: approvalIntent(approval, allow: false)) {
                    label(copy("control.deny", state), background: AgentIslandPalette.line,
                          foreground: AgentIslandPalette.primary, fills: false)
                }
                Button(intent: approvalIntent(approval, allow: true)) {
                    label(copy("control.approveOnce", state), background: AgentIslandPalette.accent,
                          foreground: .black, fills: true)
                }
            }
            if controls.contains(.retry) {
                Button(intent: IOSRetryAgentRunIntent(runId: attributes.runId, conversationId: conversationId)) {
                    label(copy("control.retry", state), background: AgentIslandPalette.primary,
                          foreground: .black, fills: true)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func approvalIntent(_ approval: AgentActivityApproval, allow: Bool) -> IOSResolveAgentApprovalIntent {
        IOSResolveAgentApprovalIntent(
            runId: attributes.runId,
            conversationId: conversationId,
            requestId: approval.requestId,
            allow: allow
        )
    }

    private func label(_ text: String, background: Color, foreground: Color, fills: Bool) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(foreground)
            .padding(.horizontal, 22)
            .frame(maxWidth: fills ? .infinity : nil, minHeight: 40)
            .background(background, in: Capsule())
    }
}

// MARK: - 紧凑态：左侧状态，右侧计时

/// 紧凑态左侧：当前状态。颜色只在待确认、完成、中断时出现。
struct AgentActivityCompactStatus: View {
    let state: AgentActivityAttributes.ContentState
    let phase: AgentActivityPhase

    var body: some View {
        HStack(spacing: 4) {
            icon
            Text(title)
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        // 按内容宽度排版：maxWidth 会被系统提议撑满，导致左宽右窄、岛不对称。
        .fixedSize()
        .padding(.leading, 4)
    }

    private var title: String {
        switch phase {
        case .running:
            state.presentation.stage.localizedCompactTitle(languageCode: state.languageCode)
        case .reconnecting: copy("status.reconnecting", state)
        case .stale: copy("status.paused", state)
        case .waitingForUser: copy("status.confirm", state)
        case .completed: copy("status.done", state)
        case .failed: copy("status.interrupted", state)
        case .cancelled: copy("status.stopped", state)
        }
    }

    private var color: Color {
        switch phase {
        case .running: AgentIslandPalette.primary
        case .waitingForUser: AgentIslandPalette.accent
        case .completed: AgentIslandPalette.ok
        case .failed: AgentIslandPalette.danger
        case .reconnecting, .stale, .cancelled: AgentIslandPalette.secondary
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch phase {
        case .waitingForUser:
            Circle().fill(AgentIslandPalette.accent).frame(width: 6, height: 6)
        case .completed:
            Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy))
        case .failed:
            Image(systemName: "exclamationmark").font(.system(size: 11, weight: .heavy))
        case .stale:
            Image(systemName: "pause.fill").font(.system(size: 10))
        case .running, .reconnecting, .cancelled:
            EmptyView()
        }
    }
}

/// 紧凑态右侧：计时。运行中走字，待确认计等待时长，终态和失联定格在总用时。
struct AgentActivityCompactTimer: View {
    let startedAt: Date
    let state: AgentActivityAttributes.ContentState
    let phase: AgentActivityPhase

    var body: some View {
        value
            .font(.system(size: 15, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(phase == .running || phase == .waitingForUser
                ? AgentIslandPalette.primary
                : AgentIslandPalette.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            // 计时文本理想宽度不定，固定宽度防止挤占左侧状态。
            .frame(width: 52, alignment: .trailing)
            .multilineTextAlignment(.trailing)
            // 与左侧状态的 4pt 对称。
            .padding(.trailing, 4)
            .environment(\.locale, activityLocale(state))
    }

    @ViewBuilder
    private var value: some View {
        switch phase {
        case .running, .reconnecting:
            Text(startedAt, style: .timer)
        case .waitingForUser:
            Text(state.updatedAt, style: .timer)
        case .stale, .completed, .failed, .cancelled:
            let seconds = max(0, state.updatedAt.timeIntervalSince(startedAt))
            Text(elapsedText(seconds, state))
        }
    }
}

// MARK: - 锁屏

struct LockScreenAgentActivityView: View {
    let attributes: AgentActivityAttributes
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool

    private var phase: AgentActivityPhase {
        state.presentation.displayPhase(isStale: isStale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AgentActivityMark(size: 28, faded: phase == .stale)
                AgentActivityHeadline(attributes: attributes, state: state, phase: phase, isLockScreen: true)
                AgentActivityTrailingFact(startedAt: attributes.startedAt, state: state, phase: phase)
                    .fixedSize()
                    .layoutPriority(1)
            }
            AgentActivityBody(attributes: attributes, state: state, phase: phase, showsContent: false)
        }
        .padding(14)
        .overlay {
            if phase == .waitingForUser {
                ContainerRelativeShape()
                    .strokeBorder(AgentIslandPalette.accent.opacity(0.5), lineWidth: 1)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}
