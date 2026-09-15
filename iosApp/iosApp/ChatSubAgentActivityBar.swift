import Foundation
import SwiftUI
import UIKit

/// App-level activity strip for child-agent executions that may outlive the
/// currently selected conversation.
///
/// The store is observed here, rather than by `ChatView`, so the per-second
/// elapsed-time timeline only invalidates the individual activity row.
struct ChatSubAgentActivityBar: View {
    let currentConversationId: String?
    let isInputFocused: Bool
    let onOpenSource: @MainActor (String) async -> Bool

    @State private var activityStore: IOSSubAgentActivityStore
    @State private var isExpanded = false
    @State private var selectedActivity: IOSSubAgentActivity?
    @State private var gridContentHeight: CGFloat = 48
    @State private var isKeyboardVisible = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        currentConversationId: String?,
        isInputFocused: Bool,
        activityStore: IOSSubAgentActivityStore = .shared,
        initiallyExpanded: Bool = false,
        onOpenSource: @escaping @MainActor (String) async -> Bool
    ) {
        self.currentConversationId = currentConversationId
        self.isInputFocused = isInputFocused
        self.onOpenSource = onOpenSource
        _activityStore = State(initialValue: activityStore)
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var items: [IOSSubAgentActivity] {
        activityStore.items
    }

    private var activeCount: Int {
        items.filter { $0.status == .running }.count
    }

    private var hasFinishedItems: Bool {
        items.contains { $0.canDismiss }
    }

    private var hasOtherSource: Bool {
        items.contains { item in
            guard let source = item.sourceConversationId else { return false }
            guard let currentConversationId else { return true }
            return source.caseInsensitiveCompare(currentConversationId) != .orderedSame
        }
    }

    private var expansionAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.24)
    }

    private var canExpand: Bool {
        !isInputFocused && !isKeyboardVisible
    }

    var body: some View {
        Group {
            if !activityStore.isEnabled || items.isEmpty {
                EmptyView()
            } else {
                activityBarContent
            }
        }
        .onChange(of: activityStore.isEnabled) { _, enabled in
            guard !enabled else { return }
            isExpanded = false
            selectedActivity = nil
        }
        .onChange(of: isInputFocused) { _, focused in
            if focused {
                collapseForKeyboard()
            }
        }
        .onChange(of: items.isEmpty) { _, isEmpty in
            if isEmpty {
                isExpanded = false
                selectedActivity = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
            collapseForKeyboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            isKeyboardVisible = true
            collapseForKeyboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            isKeyboardVisible = false
            collapseForKeyboard()
        }
        .sheet(item: $selectedActivity) { activity in
            ChatSubAgentActivityDetailSheet(
                activity: activity,
                activityStore: activityStore,
                onOpenSource: onOpenSource
            )
        }
    }

    private var activityBarContent: some View {
        Group {
            if isExpanded && canExpand {
                expandedActivityList
            } else {
                collapsedActivityList
                    .contentShape(Rectangle())
                    .simultaneousGesture(expandGesture)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // The timeline intentionally scrolls below the floating composer.
            // A local paper fade keeps dense message text from bleeding into
            // this strip without changing the timeline's viewport or offsets.
            LinearGradient(
                colors: [AmberTheme.background.opacity(0), AmberTheme.background.opacity(0.94)],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.subagentActivityBar")
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var runningCountBadge: some View {
        Button {
            setExpanded(!isExpanded)
        } label: {
            Text(activeCount, format: .number)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AmberTheme.foreground)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .frame(width: 32, height: 32)
                .modifier(ChatSubAgentActivityGlassModifier(reduceTransparency: reduceTransparency))
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canExpand)
        .accessibilityLabel("子代理运行中 \(activeCount) 个")
        .accessibilityValue(isExpanded ? "已展开" : "已收起")
        .accessibilityHint(canExpand
            ? (hasOtherSource ? "包含其他会话任务。轻点或上滑展开，下滑收回" : "轻点或上滑展开，下滑收回")
            : "键盘显示时保持单行")
        .accessibilityIdentifier("chat.subagentActivity.count")
        .accessibilityAction(named: "展开子代理活动") { setExpanded(true) }
        .accessibilityAction(named: "收回子代理活动") { setExpanded(false) }
        .contextMenu {
            if hasFinishedItems {
                Button("收起所有已结束任务", systemImage: "tray.and.arrow.down") {
                    activityStore.dismissAllFinished()
                }
            }
        }
    }

    private var hideBarButton: some View {
        Button {
            withAnimation(expansionAnimation) { activityStore.isEnabled = false }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(AmberTheme.muted)
                .frame(width: 32, height: 32)
                .modifier(ChatSubAgentActivityGlassModifier(reduceTransparency: reduceTransparency))
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("隐藏子代理悬浮栏")
        .accessibilityHint("任务会继续运行，可在子代理设置中重新显示")
        .accessibilityIdentifier("chat.subagentActivity.hide")
    }

    private var expandGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                guard value.translation.height < -30,
                      abs(value.translation.height) > abs(value.translation.width) * 1.25 else { return }
                setExpanded(true)
            }
    }

    private func setExpanded(_ expanded: Bool) {
        guard !expanded || canExpand else { return }
        withAnimation(expansionAnimation) { isExpanded = expanded }
    }

    private var collapsedActivityList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            AmberGlassGroup(spacing: 6) {
                HStack(spacing: 6) {
                    HStack(spacing: 0) {
                        runningCountBadge
                        hideBarButton
                    }
                    ForEach(items) { activity in
                        activityButton(activity)
                            .frame(width: dynamicTypeSize.isAccessibilitySize ? 240 : 166, alignment: .leading)
                    }
                }
                .scrollTargetLayout()
            }
        }
        .contentMargins(.horizontal, 12, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
        // Soft edges keep scrolled capsules and controls from looking sliced;
        // the leading content margin leaves the first circle fully visible.
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 12)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 12)
            }
            .padding(.vertical, -16)
        }
        .accessibilityIdentifier("chat.subagentActivity.horizontalList")
    }

    private var expandedActivityList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            // Compose glass inside the scrolling content so both the labels
            // and their surfaces share the viewport's clipping and movement.
            AmberGlassGroup(spacing: 8) {
                VStack(spacing: 6) {
                    HStack(spacing: 0) {
                        runningCountBadge
                        hideBarButton
                        Spacer(minLength: 0)
                    }
                    LazyVGrid(
                        columns: [GridItem(.flexible(minimum: 0), spacing: 8),
                                  GridItem(.flexible(minimum: 0), spacing: 8)],
                        alignment: .leading, spacing: 8
                    ) {
                        ForEach(items) { activity in
                            activityButton(activity).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(6)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if abs(gridContentHeight - height) > 0.5 { gridContentHeight = height }
            }
        }
        // Show every row when it fits; let the composer container constrain
        // the viewport on small screens or with larger accessibility text.
        .frame(idealHeight: gridContentHeight, maxHeight: gridContentHeight)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .contentShape(Rectangle())
        .gesture(SubAgentCollapseGesture { setExpanded(false) })
        .accessibilityIdentifier("chat.subagentActivity.expandedList")
    }

    private func activityButton(_ activity: IOSSubAgentActivity) -> some View {
        Button {
            selectedActivity = activity
        } label: {
            ChatSubAgentActivityCard(activity: activity)
                .modifier(ChatSubAgentActivityGlassModifier(
                    reduceTransparency: reduceTransparency
                ))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.subagentActivity.\(activity.id)")
    }

    private func collapseForKeyboard() {
        guard isExpanded else { return }
        withAnimation(expansionAnimation) {
            isExpanded = false
        }
    }
}

/// UIKit recognizes the downward swipe alongside the grid's native pan.
/// Upward movement remains available for scrolling through more tasks.
private struct SubAgentCollapseGesture: UIGestureRecognizerRepresentable {
    let collapse: @MainActor () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UISwipeGestureRecognizer {
        let recognizer = UISwipeGestureRecognizer()
        recognizer.direction = .down
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UISwipeGestureRecognizer, context: Context) {
        if recognizer.state == .ended { collapse() }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

private struct ChatSubAgentActivityCard: View {
    let activity: IOSSubAgentActivity

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ChatSubAgentPixelAvatar(identity: activity.avatarIdentity, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(activity.title)
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ActivityStatusLine(activity: activity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(minHeight: 48, alignment: .leading)
    }
}

private struct ActivityStatusLine: View {
    let activity: IOSSubAgentActivity

    var body: some View {
        Group {
            if activity.canDismiss {
                statusText(at: activity.endedAt ?? Date())
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    statusText(at: context.date)
                }
            }
        }
    }

    @ViewBuilder
    private func statusText(at date: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Circle()
                .fill(activity.status.activityColor)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)

            Text("\(activity.statusTitle) · \(ChatSubAgentActivityDuration.compactText(seconds: activity.elapsed(at: date)))")
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("\(activity.statusTitle)，用时 \(ChatSubAgentActivityDuration.text(seconds: activity.elapsed(at: date)))")
        }
        .font(.system(.caption2, design: .rounded).weight(.medium))
        .foregroundStyle(AmberTheme.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ChatSubAgentActivityDetailSheet: View {
    let initialActivity: IOSSubAgentActivity
    let activityStore: IOSSubAgentActivityStore
    let onOpenSource: @MainActor (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isOpeningSource = false
    @State private var sourceUnavailable = false
    @State private var publicOutput: IOSSubAgentOutputSnapshot?
    @State private var outputReadFailed = false
    @State private var outputRevision = 0
    @State private var isSummaryExpanded = false

    init(
        activity: IOSSubAgentActivity,
        activityStore: IOSSubAgentActivityStore,
        onOpenSource: @escaping @MainActor (String) async -> Bool
    ) {
        initialActivity = activity
        self.activityStore = activityStore
        self.onOpenSource = onOpenSource
    }

    private var activity: IOSSubAgentActivity {
        activityStore.items.first(where: { $0.id == initialActivity.id }) ?? initialActivity
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    ChatSubAgentPixelAvatar(identity: activity.avatarIdentity, size: 40)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(activity.title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("chat.subagentActivity.detail")
                        let statusLayout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                            : AnyLayout(HStackLayout(spacing: 6))
                        statusLayout {
                            HStack(spacing: 6) {
                                Circle().fill(activity.status.activityColor)
                                    .frame(width: 6, height: 6).accessibilityHidden(true)
                                Text(activity.statusTitle)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !dynamicTypeSize.isAccessibilitySize {
                                Text("·").accessibilityHidden(true)
                            }
                            ActivityDurationLabel(activity: activity)
                        }
                        .font(.subheadline)
                        .foregroundStyle(AmberTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AmberTheme.muted)
                            .frame(width: 30, height: 30)
                            .background(AmberTheme.foreground.opacity(0.05), in: Circle())
                            .frame(width: 40, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(IOSAppLocalization.string("关闭", defaultValue: "关闭"))
                    .accessibilityIdentifier("chat.subagentActivity.close")
                }

                Divider().overlay(AmberTheme.borderSoft)
                outputContent
                Divider().overlay(AmberTheme.borderSoft)
                actionSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 12)
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize
            ? [.large]
            : hasPublicOutput ? [.medium, .large] : [.height(activity.canDismiss ? 330 : 270), .medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AmberTheme.background)
        .task(id: "\(activity.id)|\(activity.status.rawValue)|\(outputRevision)") {
            repeat {
                do {
                    let next = try await IOSSubAgentOutputLoader.load(
                        activity: activity, task: activityStore.taskRecord(for: activity)
                    )
                    guard !Task.isCancelled else { return }
                    if publicOutput != next { publicOutput = next }
                    outputReadFailed = false
                } catch {
                    guard !Task.isCancelled else { return }
                    outputReadFailed = true
                }
                if activity.canDismiss { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            } while !Task.isCancelled
        }
        .onReceive(NotificationCenter.default.publisher(for: .amberSubAgentRunsDidChange)) { _ in
            outputRevision &+= 1
        }
        .onAppear {
            activityStore.beginViewing(initialActivity.id)
        }
        .onDisappear {
            activityStore.endViewing(initialActivity.id)
        }
    }

    private var hasPublicOutput: Bool {
        guard let publicOutput else { return false }
        return !publicOutput.summary.isEmpty || !publicOutput.steps.isEmpty
    }

    @ViewBuilder
    private var outputContent: some View {
        if let output = publicOutput, hasPublicOutput {
            VStack(alignment: .leading, spacing: 18) {
                if !output.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(IOSAppLocalization.string(
                            output.isFinal ? "结果摘要" : "最新产出",
                            defaultValue: output.isFinal ? "结果摘要" : "最新产出"
                        ))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.muted)
                        Text(output.summary)
                            .font(.subheadline)
                            .foregroundStyle(AmberTheme.foreground)
                            .lineSpacing(3)
                            .lineLimit(isSummaryExpanded || output.summary.count <= 160 ? nil : 6)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("chat.subagentActivity.outputSummary")
                        if output.summary.count > 160 {
                            Button(isSummaryExpanded ? "收起摘要" : "展开摘要") { isSummaryExpanded.toggle() }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(AmberTheme.accent)
                                .buttonStyle(.plain)
                        }
                    }
                }
                if !output.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(IOSAppLocalization.string("近期进展", defaultValue: "近期进展"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AmberTheme.muted)
                        ForEach(output.steps) { step in
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(step.status.activityColor)
                                    .frame(width: 5, height: 5).padding(.top, 7)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(step.title).font(.subheadline.weight(.medium))
                                        .foregroundStyle(AmberTheme.foreground)
                                    if let detail = step.detail, !detail.isEmpty, detail != step.title {
                                        Text(detail).font(.caption)
                                            .foregroundStyle(AmberTheme.muted)
                                            .lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(step.status.title).font(.caption)
                                    .foregroundStyle(AmberTheme.muted)
                            }
                        }
                    }
                    .accessibilityIdentifier("chat.subagentActivity.outputSteps")
                }
            }
        } else {
            HStack(spacing: 12) {
                Text(outputReadFailed ? "暂时无法读取产出" : "尚无可展示的公开产出")
                    .font(.subheadline).foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if outputReadFailed {
                    Button("重试") { outputRevision &+= 1 }
                        .font(.subheadline).foregroundStyle(AmberTheme.accent)
                }
            }
        }
    }

    private var actionLabelLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 6))
            : AnyLayout(HStackLayout(spacing: 6))
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    guard let source = activity.sourceConversationId, !source.isEmpty,
                          !isOpeningSource else { return }
                    isOpeningSource = true
                    sourceUnavailable = false
                    Task { @MainActor in
                        let opened = await onOpenSource(source)
                        isOpeningSource = false
                        if opened { dismiss() } else { sourceUnavailable = true }
                    }
                } label: {
                    actionLabelLayout {
                        if isOpeningSource { ProgressView().controlSize(.small) }
                        else { Image(systemName: "bubble.left") }
                        Text(IOSAppLocalization.string("打开来源会话", defaultValue: "打开来源会话"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 24, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .tint(AmberTheme.accent)
                .disabled(isOpeningSource || activity.sourceConversationId?.isEmpty != false)
                .accessibilityIdentifier("chat.subagentActivity.openSource")

                if activity.canDismiss {
                    Button {
                        activityStore.dismiss(activity.id)
                        dismiss()
                    } label: {
                        actionLabelLayout {
                            Image(systemName: "tray.and.arrow.down")
                            Text(IOSAppLocalization.string("收起此任务", defaultValue: "收起此任务"))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .tint(AmberTheme.muted)
                    .accessibilityIdentifier("chat.subagentActivity.dismiss")
                }
            }
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .fixedSize(horizontal: false, vertical: true)

            if sourceUnavailable || activity.sourceConversationId?.isEmpty != false {
                Text(IOSAppLocalization.string("来源会话已删除或不可用。", defaultValue: "来源会话已删除或不可用。"))
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat.subagentActivity.sourceUnavailable")
            }
        }
    }
}

private struct ActivityDurationLabel: View {
    let activity: IOSSubAgentActivity

    var body: some View {
        if activity.canDismiss {
            Text(ChatSubAgentActivityDuration.text(
                seconds: activity.elapsed(at: activity.endedAt ?? Date())
            ))
            .font(.footnote.monospacedDigit())
            .foregroundStyle(AmberTheme.muted)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(ChatSubAgentActivityDuration.text(
                    seconds: activity.elapsed(at: context.date)
                ))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(AmberTheme.muted)
            }
        }
    }
}

private enum ChatSubAgentActivityDuration {
    static func compactText(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total < 60 { return text(seconds: seconds) }
        if total < 3_600 { return String(format: "%d:%02d", total / 60, total % 60) }
        return String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
    }

    static func text(seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainder = totalSeconds % 60

        if hours > 0 {
            return IOSAppLocalization.formatted(
                "%lld 小时 %02lld 分",
                defaultValue: "%lld 小时 %02lld 分",
                arguments: [Int64(hours), Int64(minutes)]
            )
        }
        if minutes > 0 {
            return IOSAppLocalization.formatted(
                "%lld 分 %02lld 秒",
                defaultValue: "%lld 分 %02lld 秒",
                arguments: [Int64(minutes), Int64(remainder)]
            )
        }
        return IOSAppLocalization.formatted(
            "%lld 秒",
            defaultValue: "%lld 秒",
            arguments: [Int64(remainder)]
        )
    }
}

private struct ChatSubAgentActivityGlassModifier: ViewModifier {
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        let shape = Capsule()

        if reduceTransparency {
            content
                .background(AmberTheme.surface, in: shape)
                .overlay {
                    shape
                        .stroke(AmberTheme.borderSoft, lineWidth: 0.8)
                        .allowsHitTesting(false)
                }
        } else if #available(iOS 26.0, *) {
            content
                .background(AmberTheme.glass.opacity(0.22), in: shape)
                .glassEffect(.regular.interactive(), in: shape)
                .overlay {
                    shape
                        .stroke(AmberTheme.borderSoft.opacity(0.75), lineWidth: 0.7)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.035), radius: 4, y: 2)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape
                        .stroke(AmberTheme.borderSoft.opacity(0.8), lineWidth: 0.7)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.035), radius: 4, y: 2)
        }
    }
}

private extension IOSAdvancedTaskStatus {
    var activityColor: Color {
        switch self {
        case .queued:
            AmberTheme.muted
        case .running:
            AmberTheme.accentAmber
        case .approvalRequired:
            AmberTheme.accent
        case .completed:
            Color.green
        case .failed, .timedOut:
            AmberTheme.accentRed
        case .cancelled, .interrupted:
            AmberTheme.muted
        }
    }
}
