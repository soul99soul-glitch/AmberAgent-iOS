import SwiftUI
import Shared

enum ChatLayout {
    static let assistantPartSpacing: CGFloat = 9
    static let assistantTextPadding: CGFloat = 14
    static let contentHorizontalInset: CGFloat = 18
    static let timelineHorizontalInset: CGFloat = 16
    static let userMaxWidth: CGFloat = 319
    static let userMessageRowVerticalPadding: CGFloat = 7
    static let followBottomGap: CGFloat = 96
    /// 用户真实拖拽/惯性结束在底部附近时恢复自动跟随的意图阈值。
    /// 它必须大于 `bottomStickThreshold`：后者只描述物理 true-bottom，不能混用。
    static let nearBottomResumeThreshold = followBottomGap
    static let bottomStickThreshold: CGFloat = 40
    /// 内容底部的静止留白：会话定位与回到底部时，最后一条气泡与输入框之间的
    /// 舒适间距。配合时间线内容层的 `.padding(.bottom)` 使用，两者相加才是可见间隙；
    /// 现取 12：贴得近但不死贴输入框边缘。
    static let bottomRestGap: CGFloat = 12
    /// 内容最底部的不可见锚点 id:定位到它(而非最后一条气泡)即停在「带留白的内容底」。
    static let bottomAnchorID = "chat-bottom-rest-anchor"
    /// 流式消息离底部足够远时冻结渲染,避免用户看历史时为不可见的新 token 重排 Markdown。
    static let liveRenderingLODMinDistance: CGFloat = 700
    static let liveRenderingLODScreenFactor: CGFloat = 1.15
}

struct ChatComposerHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ChatAssistantStack<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ChatLayout.assistantPartSpacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatAgentName: View {
    private var agentName: Bool { IOSChatRenderPreferences.shared.agentName }

    var body: some View {
        if agentName {
            let name = AgentSoulStore.shared.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            Text(name.isEmpty ? AgentSoulStore.defaultDisplayName : name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AmberTheme.muted)
                .padding(.leading, 4)
        }
    }
}

/// The same trailing alignment and width budget for local and cloud user messages.
struct ChatUserMessageRow<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 4) { content }
                .frame(maxWidth: ChatLayout.userMaxWidth, alignment: .trailing)
        }
    }
}

struct ChatUserBubble: View {
    let text: String
    private var fontScale: Double { IOSChatRenderPreferences.shared.fontScale }
    private var chatFont: String { IOSChatRenderPreferences.shared.chatFont }
    @ScaledMetric(relativeTo: .body) private var scaledBodyPointSize: CGFloat = IOSChatFont.defaultBodyPointSize

    private var boundedScale: Double {
        IOSChatFont.clampedScale(fontScale)
    }

    private var selectedFont: IOSChatFont {
        IOSChatFont(rawValue: chatFont) ?? .default
    }

    /// 用户气泡沿用原先的 `radiusXLarge` 语义；自定义组件只覆盖气泡槽，
    /// 不能因为卡片圆角也开放了就意外跟随 `cardRadius`。
    private static var userBubbleRadius: CGFloat {
        if let radius = AmberThemeRuntime.shared.design?.components?.bubbleRadius {
            return CGFloat(radius)
        }
        switch AmberThemeRuntime.shared.bubbleChrome {
        case .standard: return 18
        case .soft: return 22
        case .crisp: return 14
        }
    }

    static var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: userBubbleRadius,
            bottomLeadingRadius: userBubbleRadius,
            bottomTrailingRadius: 6,
            topTrailingRadius: userBubbleRadius,
            style: .continuous
        )
    }

    var body: some View {
        Text(text)
            .font(selectedFont.font(size: scaledBodyPointSize * boundedScale))
            .foregroundStyle(AmberTheme.accentInk)
            .lineSpacing(3.2 * boundedScale)
            // cell self-sizing 测量会传入受限的垂直 proposal,普通 Text 会按 proposal
            // 截断——曾表现为用户消息只显示一行。fixedSize 让文本按理想高度完整布局;
            // 超长消息以 50 行为折叠上限,避免单条消息占掉数十屏。
            .lineLimit(50)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 15)
            .padding(.vertical, 10.5)
            .background(AmberTheme.accent, in: Self.bubbleShape)
            .overlay {
                Self.bubbleShape
                    .stroke(AmberTheme.border, lineWidth: AmberTheme.designBorderWidth)
                    .allowsHitTesting(false)
            }
            // 不在这里 cap 宽度:气泡保持内容尺寸,长按 contextMenu 的高亮平台才会贴合气泡而非
            // 撑成 300pt 灰条。宽度上限由各调用方的父容器负责(消息流是 MessageBubbleView 的 VStack)。
    }
}

struct ChatAssistantText<Content: View>: View {
    let content: Content
    private var fontScale: Double { IOSChatRenderPreferences.shared.fontScale }
    private var chatFont: String { IOSChatRenderPreferences.shared.chatFont }
    @ScaledMetric(relativeTo: .body) private var scaledBodyPointSize: CGFloat = IOSChatFont.defaultBodyPointSize

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var boundedScale: Double {
        IOSChatFont.clampedScale(fontScale)
    }

    private var selectedFont: IOSChatFont {
        IOSChatFont(rawValue: chatFont) ?? .default
    }

    var body: some View {
        content
            .font(selectedFont.font(size: scaledBodyPointSize * boundedScale))
            .foregroundStyle(AmberTheme.foreground)
            .lineSpacing(3.2 * boundedScale)
            .fixedSize(horizontal: false, vertical: true)
            .padding(ChatLayout.assistantTextPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AmberTheme.border, lineWidth: 0.7)
            }
    }
}

/// 已播过入场的 live 元素 key：LazyVStack 回收后重建不会重播，只有真正新出现的元素才渐入。
@MainActor
enum ChatLiveEntranceRegistry {
    private static var revealed: Set<String> = []
    private static var order: [String] = []
    private static let capacity = 512

    static func hasRevealed(_ key: String) -> Bool { revealed.contains(key) }

    static func claim(_ key: String) -> Bool {
        guard revealed.insert(key).inserted else { return false }
        order.append(key)
        if order.count > capacity {
            revealed.remove(order.removeFirst())
        }
        return true
    }
}

/// 流式过程中新出现的元素（等待指示、思考卡、工具胶囊、首段正文）轻微上移 + 渐入。
/// 只用 opacity/offset 这类渲染期效果，不改变布局高度，不干扰滚动测量与底部跟随。
/// 历史内容（`isLive == false`）和已播过的 key 直接以终态出现。
private struct ChatLiveEntranceModifier: ViewModifier {
    let key: String
    let isLive: Bool
    var onStart: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Phase = .pending

    private enum Phase { case pending, hidden, shown }

    func body(content: Content) -> some View {
        // 重建的已播元素首帧就按终态绘制，避免一帧闪烁。
        let hidden = phase == .hidden ||
            (phase == .pending && isLive && !ChatLiveEntranceRegistry.hasRevealed(key))
        content
            .opacity(hidden ? 0 : 1)
            .offset(y: hidden && !reduceMotion ? 8 : 0)
            .onAppear {
                guard phase == .pending else { return }
                guard isLive, ChatLiveEntranceRegistry.claim(key) else {
                    phase = .shown
                    return
                }
                phase = .hidden
                onStart?()
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.38)) {
                    phase = .shown
                }
            }
    }
}

extension View {
    func chatLiveEntrance(key: String, isLive: Bool, onStart: (() -> Void)? = nil) -> some View {
        modifier(ChatLiveEntranceModifier(key: key, isLive: isLive, onStart: onStart))
    }

    func chatUserSendEntrance(key: String?) -> some View {
        modifier(ChatUserSendEntranceModifier(key: key))
    }
}

/// Explicit opt-in gate for foreground user-sent bubbles (Local & Cloud Main Dialogue).
/// Only keys armed at the moment of an active user send animate once within `freshnessWindow`;
/// history loads, scroll reuse, host/tab switches, background/Watch sends, and Cloud event replays
/// never arm this gate and always render immediately in their settled state.
@MainActor
enum ChatUserSendEntranceGate {
    static let freshnessWindow: TimeInterval = 1.5
    static let settleDuration: TimeInterval = 0.32
    private static let historyCapacity = 512

    private struct Entry {
        let armedAt: TimeInterval
        var startedAt: TimeInterval?
    }

    private static var entries: [String: Entry] = [:]
    private static var insertionOrder: [String] = []

    static func arm(_ key: String, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !key.isEmpty else { return }
        if entries[key] == nil {
            insertionOrder.append(key)
            if insertionOrder.count > historyCapacity {
                let evicted = insertionOrder.removeFirst()
                entries.removeValue(forKey: evicted)
            }
        }
        entries[key] = Entry(armedAt: now, startedAt: nil)
    }

    static func initialProgress(
        for key: String?,
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> CGFloat {
        guard let key, let entry = entries[key] else { return 1 }
        if let startedAt = entry.startedAt {
            let elapsed = max(0, now - startedAt)
            guard elapsed < settleDuration else { return 1 }
            let t = elapsed / settleDuration
            return CGFloat(1 - pow(1 - t, 3))
        }
        return (now - entry.armedAt) <= freshnessWindow ? 0 : 1
    }

    static func claimOrResume(
        _ key: String?,
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> (startProgress: CGFloat, remainingFraction: Double)? {
        guard let key, var entry = entries[key] else { return nil }
        if let startedAt = entry.startedAt {
            let elapsed = max(0, now - startedAt)
            guard elapsed < settleDuration else { return nil }
            let t = elapsed / settleDuration
            let startProgress = CGFloat(1 - pow(1 - t, 3))
            return (startProgress, max(0.18, 1 - t))
        }
        guard (now - entry.armedAt) <= freshnessWindow else {
            entry.startedAt = now - settleDuration
            entries[key] = entry
            return nil
        }
        entry.startedAt = now
        entries[key] = entry
        return (0, 1.0)
    }

    static func hasStarted(_ key: String) -> Bool {
        entries[key]?.startedAt != nil
    }

    static func isArmed(_ key: String, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let entry = entries[key], entry.startedAt == nil else { return false }
        return (now - entry.armedAt) <= freshnessWindow
    }

    static func resetForTesting() {
        entries.removeAll()
        insertionOrder.removeAll()
    }
}

/// iMessage-style trailing user bubble entrance (`opacity: 0 → 1`, `scale: 0.94 → 1.0` anchored at
/// `.bottomTrailing`, `offsetY: 12 → 0`). Uses render-only effects so row measurement, bottom
/// pinning, and composer spacing remain untouched, and degrades to a short opacity fade on Reduce Motion.
struct ChatUserSendEntranceModifier: ViewModifier {
    let key: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var trackedKey: String?
    @State private var animatedProgress: CGFloat?

    static func metrics(
        progress: CGFloat,
        reduceMotion: Bool
    ) -> (opacity: Double, scale: CGFloat, offsetY: CGFloat) {
        let clamped = min(max(progress, 0), 1)
        let opacity = Double(clamped)
        guard !reduceMotion else {
            return (opacity: opacity, scale: 1.0, offsetY: 0)
        }
        let scale = 0.94 + 0.06 * clamped
        let offsetY = 12 * (1 - clamped)
        return (opacity: opacity, scale: scale, offsetY: offsetY)
    }

    func body(content: Content) -> some View {
        let effectiveProgress: CGFloat = {
            if trackedKey == key, let animatedProgress {
                return animatedProgress
            }
            return ChatUserSendEntranceGate.initialProgress(for: key)
        }()
        let current = Self.metrics(progress: effectiveProgress, reduceMotion: reduceMotion)
        content
            .opacity(current.opacity)
            .scaleEffect(current.scale, anchor: .bottomTrailing)
            .offset(y: current.offsetY)
            .onAppear {
                activateIfNeeded(for: key)
            }
            .onChange(of: key) { _, newKey in
                activateIfNeeded(for: newKey)
            }
    }

    private func activateIfNeeded(for targetKey: String?) {
        guard trackedKey != targetKey || animatedProgress == nil else { return }
        trackedKey = targetKey
        guard let claim = ChatUserSendEntranceGate.claimOrResume(targetKey) else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                animatedProgress = 1
            }
            return
        }
        var initialTransaction = Transaction()
        initialTransaction.disablesAnimations = true
        withTransaction(initialTransaction) {
            animatedProgress = claim.startProgress
        }
        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.16 * claim.remainingFraction)
            : .spring(response: 0.30 * claim.remainingFraction, dampingFraction: 0.84)
        withAnimation(animation) {
            animatedProgress = 1
        }
    }
}

struct ChatAssistantPendingResponseView: View {
    @State private var startedAt = Date()
    /// Overridable so callers with a richer phase model (e.g. Novel's quickStart streaming
    /// disclosure) can distinguish "still waiting" from "already generating" without a
    /// second bespoke placeholder view. Defaults to the original Chat/Council copy so every
    /// existing call site keeps its exact prior text.
    var label: (Int) -> String = ChatAssistantPendingResponseView.defaultLabel

    nonisolated static func defaultLabel(elapsed: Int) -> String {
        elapsed >= 2 ? "正在等待模型响应 \(elapsed) 秒" : "正在连接模型"
    }

    var body: some View {
        ChatAssistantStack {
            ChatAgentName()
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(AmberTheme.accentAmber)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = Int(max(0, context.date.timeIntervalSince(startedAt)))
                    Text(label(elapsed))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(AmberTheme.foreground2)
                }

                TypingDots()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                AmberTheme.surface,
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ContextCompactTimelineMarker: View {
    let state: ChatContextCompactState

    private var isCustomEpisodeMarker: Bool {
        state.status == .completed && state.customCompletedTitle != nil
    }

    private var title: String {
        switch state.status {
        case .planning:
            return "准备压缩上下文"
        case .compacting:
            return "正在压缩上下文"
        case .completed:
            return state.customCompletedTitle ?? "上下文已压缩"
        case .failed:
            return "上下文压缩失败"
        case .idle:
            return ""
        }
    }

    private var icon: String {
        switch state.status {
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        default:
            return "shippingbox"
        }
    }

    private var tint: Color {
        if isCustomEpisodeMarker {
            return AmberTheme.muted
        }
        switch state.status {
        case .completed:
            return AmberTheme.accent
        case .failed:
            return .red
        default:
            return .blue
        }
    }

    private var preview: String {
        let text = state.summary
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 220 else { return text }
        return String(text.prefix(220)) + "..."
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(AmberTheme.border.opacity(isCustomEpisodeMarker ? 0.38 : 0.55))
                    .frame(height: 0.5)
                HStack(spacing: 6) {
                    if !isCustomEpisodeMarker {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    Text(title)
                        .font(isCustomEpisodeMarker ? .caption.weight(.medium) : .footnote.weight(.semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                    if state.isActive {
                        TypingDots()
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                Rectangle()
                    .fill(AmberTheme.border.opacity(isCustomEpisodeMarker ? 0.38 : 0.55))
                    .frame(height: 0.5)
            }

            // 完成态已经由固定分隔线表达；摘要留给失败态诊断，避免完成后再占一块多行区域。
            if state.status != .completed, !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.foreground2)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                dots(at: Date(timeIntervalSinceReferenceDate: 0))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
                    dots(at: timeline.date)
                }
            }
        }
        .frame(width: 20, height: 8)
    }

    private func dots(at date: Date) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(AmberTheme.muted.opacity(reduceMotion ? 0.55 : dotOpacity(index: index, date: date)))
                    .frame(width: 4, height: 4)
            }
        }
    }

    private func dotOpacity(index: Int, date: Date) -> Double {
        let phase = (date.timeIntervalSinceReferenceDate * 1.8 + Double(index) * 0.28)
            .truncatingRemainder(dividingBy: 1)
        return 0.25 + 0.55 * (0.5 + 0.5 * sin(phase * .pi * 2))
    }
}
