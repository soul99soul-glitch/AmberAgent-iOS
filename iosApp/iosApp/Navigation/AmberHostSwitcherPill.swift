import Shared
import SwiftUI

// MARK: - Argon 3+1 Right-Side Host Switcher Pill (本机 ⇄ 云端)

struct AmberHostSwitcherPill: View {
    let gateway: MacGatewayStore
    let onSelectHost: (Bool) -> Void
    let onOpenPairingSettings: () -> Void

    private var isPaired: Bool {
        gateway.connection != nil
    }

    private var isCloudSelected: Bool {
        isPaired && gateway.isCloudMainDialogueSelected
    }

    private var isCloudReachable: Bool {
        gateway.isReachable != false
    }

    var body: some View {
        Button {
            AmberHaptics.trigger(.selection)
            if isPaired {
                onSelectHost(!isCloudSelected)
            } else {
                onOpenPairingSettings()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isCloudSelected ? "icloud" : "iphone")
                    .font(.system(size: 11.5, weight: isCloudSelected ? .semibold : .medium))
                    .foregroundStyle(iconColor)

                Text(
                    isCloudSelected
                        ? IOSAppLocalization.string("云端", defaultValue: "云端")
                        : IOSAppLocalization.string("本机", defaultValue: "本机")
                )
                .font(.system(size: 12.5, weight: isCloudSelected ? .semibold : .medium))
                .foregroundStyle(isPaired || !isCloudSelected ? AmberTheme.foreground : AmberTheme.muted)
                .lineLimit(1)

                if let dotColor = statusDotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 5.5, height: 5.5)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14)
            .padding(.vertical, 9.5)
            .modifier(DuetBottomCapsuleGlass(isHighlighted: isCloudSelected))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.97, haptic: .none))
        .contentShape(.contextMenuPreview, Capsule(style: .continuous))
        .contextMenu {
            Button {
                AmberHaptics.trigger(.selection)
                onSelectHost(false)
            } label: {
                HStack {
                    Text(IOSAppLocalization.string("📱 本机 Amber", defaultValue: "📱 本机 Amber"))
                    if !isCloudSelected {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button {
                AmberHaptics.trigger(.selection)
                if isPaired {
                    onSelectHost(true)
                } else {
                    onOpenPairingSettings()
                }
            } label: {
                HStack {
                    Text(IOSAppLocalization.string("☁️ 云端真身", defaultValue: "☁️ 云端真身"))
                    if isCloudSelected {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            Button {
                AmberHaptics.trigger(.selection)
                onOpenPairingSettings()
            } label: {
                Label(
                    IOSAppLocalization.string("云端配对与连接设置…", defaultValue: "云端配对与连接设置…"),
                    systemImage: "slider.horizontal.3"
                )
            }
        }
        .accessibilityLabel(
            isCloudSelected
                ? IOSAppLocalization.string("当前云端对话，点按切回本机，长按打开宿主菜单", defaultValue: "当前云端对话，点按切回本机，长按打开宿主菜单")
                : (isPaired
                    ? IOSAppLocalization.string("当前本机对话，点按切到云端真身，长按打开宿主菜单", defaultValue: "当前本机对话，点按切到云端真身，长按打开宿主菜单")
                    : IOSAppLocalization.string("当前本机对话，点按配对云端，长按打开宿主菜单", defaultValue: "当前本机对话，点按配对云端，长按打开宿主菜单"))
        )
        .accessibilityIdentifier("chat.duet.hostSwitcherPill")
    }

    private var iconColor: Color {
        if isCloudSelected {
            return gateway.cloudDialogueSessionHealth.isReady ? AmberTheme.accent : AmberTheme.foreground2
        }
        return isPaired ? AmberTheme.foreground2 : AmberTheme.muted
    }

    private var statusDotColor: Color? {
        guard isPaired else { return nil }
        let baseColor = gateway.cloudDialogueSessionHealth.semanticDotColor
        return isCloudSelected ? baseColor : baseColor.opacity(0.8)
    }
}

extension MacGatewayCloudDialogueSessionHealth {
    var semanticDotColor: Color {
        switch self {
        case .ready:
            return AmberTheme.accentGreen
        case .checking, .actionRequired:
            return AmberTheme.accentAmber
        case .unavailable:
            return AmberTheme.accentRed
        case .unpaired:
            return AmberTheme.muted.opacity(0.55)
        }
    }
}

// MARK: - Inline Paired Cloud Main Dialogue View (Embedded in ChatView)

@MainActor
final class AmberCloudTimelineScrollCoordinator {
    private weak var scrollView: UIScrollView?
    private var lastAdjustedBottomInset: CGFloat = 0
    private var lastViewportHeight: CGFloat = 0
    private var lastContentHeight: CGFloat = 0
    private(set) var isPinnedToBottom: Bool = true

    func resolve(_ scrollView: UIScrollView) {
        let isNew = self.scrollView !== scrollView
        self.scrollView = scrollView
        if isNew {
            lastAdjustedBottomInset = scrollView.adjustedContentInset.bottom
            lastViewportHeight = scrollView.bounds.height
            lastContentHeight = scrollView.contentSize.height
            if isPinnedToBottom {
                scrollToBottom()
            }
        }
    }

    func scrollToBottom() {
        isPinnedToBottom = true
        applyBottomOffsetIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.applyBottomOffsetIfNeeded()
        }
    }

    private func applyBottomOffsetIfNeeded() {
        guard isPinnedToBottom, let scrollView else { return }
        scrollView.layoutIfNeeded()
        let targetY = bottomTarget(in: scrollView)
        if abs(scrollView.contentOffset.y - targetY) > 0.5 {
            scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
        }
        lastAdjustedBottomInset = scrollView.adjustedContentInset.bottom
        lastViewportHeight = scrollView.bounds.height
        lastContentHeight = scrollView.contentSize.height
    }

    func handleMetricsChanged() {
        guard let scrollView else { return }
        let currentVisibleHeight = max(
            1,
            scrollView.bounds.height - scrollView.adjustedContentInset.top - scrollView.adjustedContentInset.bottom
        )
        let previousVisibleHeight = max(
            1,
            lastViewportHeight - scrollView.adjustedContentInset.top - lastAdjustedBottomInset
        )
        let shrinkDelta = max(0, previousVisibleHeight - currentVisibleHeight)
        let contentGrowthDelta = max(0, scrollView.contentSize.height - lastContentHeight)
        let currentDistance = distanceToBottom(in: scrollView)
        let distanceBeforeChange = max(0, currentDistance - shrinkDelta - contentGrowthDelta)
        let userInteracting = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating

        lastAdjustedBottomInset = scrollView.adjustedContentInset.bottom
        lastViewportHeight = scrollView.bounds.height
        lastContentHeight = scrollView.contentSize.height

        if !userInteracting && (isPinnedToBottom || distanceBeforeChange <= NativeTimelineScrollCore.resumeEpsilon) {
            isPinnedToBottom = true
            let targetY = bottomTarget(in: scrollView)
            if abs(scrollView.contentOffset.y - targetY) > 0.5 {
                scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            }
        } else {
            isPinnedToBottom = currentDistance <= NativeTimelineScrollCore.resumeEpsilon
        }
    }

    private func bottomTarget(in scrollView: UIScrollView) -> CGFloat {
        max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
    }

    private func distanceToBottom(in scrollView: UIScrollView) -> CGFloat {
        let visibleHeight = max(
            1,
            scrollView.bounds.height - scrollView.adjustedContentInset.top - scrollView.adjustedContentInset.bottom
        )
        let visibleMaxY = scrollView.contentOffset.y + scrollView.adjustedContentInset.top + visibleHeight
        return max(0, scrollView.contentSize.height - visibleMaxY)
    }
}

struct AmberCloudTaskProgressRowView: View {
    let headline: String
    let isLive: Bool
    var outcome: MacGatewayCloudDialogueOutcome? = nil
    var showsActions: Bool = false
    var onSupplement: (() -> Void)? = nil
    var onStop: (() -> Void)? = nil
    var animationTimeOverride: TimeInterval? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dotColor: Color {
        if isLive {
            return AmberTheme.accent
        }
        switch outcome {
        case .completed, .none:
            return AmberTheme.muted2
        case .blocked, .cancelled:
            return AmberTheme.accentAmber
        case .failed:
            return AmberTheme.accentRed
        }
    }

    private var lineColor: Color {
        if isLive {
            return AmberTheme.foreground
        }
        switch outcome {
        case .completed, .none:
            return AmberTheme.muted
        case .blocked, .cancelled:
            return AmberTheme.accentAmber
        case .failed:
            return AmberTheme.accentRed
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ChatTaskProgressDot(
                tint: dotColor,
                isLive: isLive,
                reduceMotion: reduceMotion,
                timeOverride: animationTimeOverride
            )

            ZStack(alignment: .leading) {
                Text(verbatim: headline)
                    .font(.system(size: 14, weight: isLive ? .medium : .regular))
                    .foregroundStyle(lineColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .modifier(
                        ChatTaskProgressTextShimmer(
                            isActive: isLive && !reduceMotion,
                            accentColor: dotColor,
                            timeOverride: animationTimeOverride
                        )
                    )
                    .id(headline)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .opacity
                                    .combined(with: .offset(y: 5))
                                    .combined(with: .scale(scale: 0.985, anchor: .leading)),
                                removal: .opacity
                                    .combined(with: .offset(y: -5))
                            )
                    )
            }
            .frame(height: 22, alignment: .leading)
            .clipped()
            .animation(
                reduceMotion ? nil : .snappy(duration: 0.26, extraBounce: 0),
                value: headline
            )

            Spacer(minLength: 4)

            if showsActions {
                if let onSupplement {
                    Button(macGatewayL("补充")) {
                        onSupplement()
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AmberTheme.accent.opacity(0.12), in: Capsule(style: .continuous))
                    .buttonStyle(.plain)
                }

                if let onStop {
                    Button(macGatewayL("停止")) {
                        onStop()
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AmberTheme.accentRed)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AmberTheme.accentRed.opacity(0.12), in: Capsule(style: .continuous))
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.cloudMainDialogue.statusLine")
    }
}

struct AmberInlineCloudMainDialogueView: View {
    let store: MacGatewayStore
    let topInset: CGFloat
    var isInputFocused: Bool = false
    let onOpenPairingSettings: () -> Void
    var onDismissKeyboard: (() -> Void)? = nil

    @State private var scrollCoordinator = AmberCloudTimelineScrollCoordinator()

    private struct CloudTailStatusRowItem: Identifiable {
        let id: String
        let headline: String
        let isLive: Bool
        let outcome: MacGatewayCloudDialogueOutcome?
        let workItemId: String?
        let showsActions: Bool
    }

    private var liveProgressItems: [MacGatewayCloudDialogueWorkItemProgress] {
        store.liveCloudDialogueProgressItems
    }

    private var tailStatusItems: [CloudTailStatusRowItem] {
        if !liveProgressItems.isEmpty {
            return liveProgressItems.enumerated().map { index, progress in
                CloudTailStatusRowItem(
                    id: index == 0 ? "cloud-status-primary" : "cloud-status-\(progress.workItemId)",
                    headline: progress.displaySingleLine,
                    isLive: progress.isLive,
                    outcome: progress.outcome,
                    workItemId: progress.workItemId,
                    showsActions: progress.isLive && !progress.isStopRequested
                )
            }
        }
        if store.isAwaitingCloudMainReply {
            return [
                CloudTailStatusRowItem(
                    id: "cloud-status-primary",
                    headline: macGatewayL("正在思考"),
                    isLive: true,
                    outcome: nil,
                    workItemId: nil,
                    showsActions: false
                )
            ]
        }
        return []
    }

    private var unmergedMainSubmissions: [MacGatewayCloudDialoguePersistedSubmission] {
        store.unmergedCloudMainSubmissions
    }

    private var unmergedFollowups: [MacGatewayCloudDialogueFollowupRecord] {
        store.cloudDialogueFollowups.filter { record in
            !store.cloudDialogueVisibleEvents.contains(where: { $0.id == record.eventId })
        }
    }

    private var scrollTailToken: String {
        let lastEvent = store.cloudDialogueVisibleEvents.last
        let liveProgress = liveProgressItems.first
        let liveSeq = liveProgress?.lastEventSeq ?? 0
        let liveStatus = liveProgress?.displaySingleLine ?? ""
        let pendingMainCount = unmergedMainSubmissions.count
        return "\(lastEvent?.id ?? "none"):\(lastEvent?.seq ?? 0):\(pendingMainCount):\(unmergedFollowups.count):\(liveSeq):\(liveStatus):\(store.isAwaitingCloudMainReply):\(isInputFocused)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Color.clear
                        .frame(height: max(8, topInset))

                    cloudHostHeaderBanner

                    if store.cloudDialogueVisibleEvents.isEmpty
                        && unmergedMainSubmissions.isEmpty
                        && unmergedFollowups.isEmpty
                        && liveProgressItems.isEmpty
                        && !store.isAwaitingCloudMainReply {
                        emptyCloudConversationCard
                    } else {
                        ForEach(store.cloudDialogueVisibleEvents) { event in
                            cloudEventBubble(event)
                                .id("cloud-event-\(event.id)")
                        }

                        ForEach(unmergedMainSubmissions) { submission in
                            pendingMainSubmissionBubble(submission)
                                .id("cloud-main-sub-\(submission.requestId)")
                        }

                        ForEach(unmergedFollowups) { followup in
                            followupBubble(followup)
                                .id("cloud-followup-\(followup.requestId)")
                        }

                        if !tailStatusItems.isEmpty {
                            liveProgressSection
                                .id("cloud-tail-status")
                        }
                    }

                    Color.clear
                        .frame(height: 12)
                        .id("cloud-dialogue-bottom-anchor")
                }
                .padding(.horizontal, ChatLayout.contentHorizontalInset)
                .background {
                    NativeTimelineScrollViewResolver(
                        onResolve: { scrollView in
                            scrollCoordinator.resolve(scrollView)
                        },
                        onMetricsChanged: {
                            scrollCoordinator.handleMetricsChanged()
                        },
                        onDismissKeyboard: onDismissKeyboard
                    )
                }
            }
            .modifier(
                ChatSizeChangesPinModifier(
                    preservesScrollIdentity: true,
                    enabled: scrollCoordinator.isPinnedToBottom
                )
            )
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    onDismissKeyboard?()
                }
            )
            .onAppear {
                store.startCloudDialoguePollingIfNeeded()
                Task {
                    if store.cloudConfig == nil {
                        await store.refreshCloudConfig()
                    }
                    _ = await store.pollCloudDialogueEvents()
                }
                proxy.scrollTo("cloud-dialogue-bottom-anchor", anchor: .bottom)
                scrollCoordinator.scrollToBottom()
            }
            .onChange(of: scrollTailToken) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("cloud-dialogue-bottom-anchor", anchor: .bottom)
                }
                scrollCoordinator.scrollToBottom()
            }
        }
        .accessibilityIdentifier("chat.cloudMainDialogue.inlineView")
    }

    private var cloudHostHeaderBanner: some View {
        let sessionHealth = store.cloudDialogueSessionHealth
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle()
                    .fill(sessionHealth.semanticDotColor)
                    .frame(width: 6.5, height: 6.5)

                Text(
                    store.connection.map { "Amber · 云端 · \($0.name)" }
                        ?? IOSAppLocalization.string("Amber · 云端", defaultValue: "Amber · 云端")
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground2)
                .lineLimit(1)

                Spacer(minLength: 6)

                Button {
                    Task {
                        await store.refresh()
                        _ = await store.pollCloudDialogueEvents()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AmberTheme.muted)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(IOSAppLocalization.string("刷新云端对话", defaultValue: "刷新云端对话"))

                Button {
                    onOpenPairingSettings()
                } label: {
                    Text(IOSAppLocalization.string("云端设置", defaultValue: "云端设置"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AmberTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AmberTheme.accent.opacity(0.12), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if !sessionHealth.isReady {
                Text(verbatim: sessionHealth.statusText)
                    .font(.caption2)
                    .foregroundStyle(sessionHealth == .checking ? AmberTheme.muted : AmberTheme.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.75)
        }
    }

    private var liveProgressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(tailStatusItems) { item in
                AmberCloudTaskProgressRowView(
                    headline: item.headline,
                    isLive: item.isLive,
                    outcome: item.outcome,
                    showsActions: item.showsActions,
                    onSupplement: item.workItemId.map { workItemId in
                        { store.selectedCloudDialogueWorkItemId = workItemId }
                    },
                    onStop: item.workItemId.map { workItemId in
                        { Task { _ = await store.stopCloudWorkItem(workItemId: workItemId) } }
                    }
                )
            }
        }
    }

    private var emptyCloudConversationCard: some View {
        let soul = AgentSoulStore.shared
        let health = store.cloudDialogueSessionHealth
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: health.isReady ? "icloud.fill" : "exclamationmark.icloud.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(health.semanticDotColor)
                Text("\(soul.displayName) · \(health.isReady ? macGatewayL("云端真身在线") : health.statusText)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
            }

            if !health.isReady {
                Text(verbatim: health.statusText)
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    onOpenPairingSettings()
                } label: {
                    Text(macGatewayL("前往云端配置"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AmberTheme.accent.opacity(0.12), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                Text(
                    IOSAppLocalization.string(
                        "当前主界面已直连 24h 云端真身，共享同一份形象人设。直接在下方输入框发消息即可交代长任务或连续对话；点按右下角「云端」胶囊可随时一键切回本机。",
                        defaultValue: "当前主界面已直连 24h 云端真身，共享同一份形象人设。直接在下方输入框发消息即可交代长任务或连续对话；点按右下角「云端」胶囊可随时一键切回本机。"
                    )
                )
                .font(.footnote)
                .foregroundStyle(AmberTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.8)
        }
        .padding(.top, 8)
    }

    private func pendingMainSubmissionBubble(_ submission: MacGatewayCloudDialoguePersistedSubmission) -> some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                Text(verbatim: submission.text ?? "")
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(AmberTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(AmberTheme.borderSoft, lineWidth: 0.75)
                    }

                Text(verbatim: pendingSubmissionStatusText(submission))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle((submission.lastError != nil && !submission.isAwaitingReceiptConfirmation) ? AmberTheme.accentRed : AmberTheme.muted)
            }
        }
    }

    private func pendingSubmissionStatusText(_ submission: MacGatewayCloudDialoguePersistedSubmission) -> String {
        if let receipt = submission.receipt {
            return receipt.state.displayBadgeText
        }
        if store.busyCloudDialogueRequestIds.contains(submission.requestId) {
            return macGatewayL("发送中…")
        }
        if submission.isAwaitingReceiptConfirmation {
            return macGatewayL("已提交 · 待确认")
        }
        return submission.lastError ?? macGatewayL("未执行")
    }

    private var awaitingCloudReplyRow: some View {
        AmberCloudTaskProgressRowView(
            headline: macGatewayL("正在思考"),
            isLive: true
        )
    }

    @ViewBuilder
    private func cloudEventBubble(_ event: MacGatewayCloudDialogueEvent) -> some View {
        let isUser = event.role == "user" || event.kind == .userMessage || event.kind == .followup
        if isUser {
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(verbatim: event.text)
                        .font(.body)
                        .foregroundStyle(AmberTheme.foreground)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(AmberTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(AmberTheme.borderSoft, lineWidth: 0.75)
                        }

                    if event.kind == .followup,
                       let followup = store.cloudDialogueFollowups.first(where: {
                           $0.eventId == event.id || ($0.workItemId == event.workItemId && $0.text == event.text)
                       }) {
                        Text(verbatim: followup.state.displayBadgeText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(followup.state == .cancelled ? .orange : AmberTheme.accent)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(verbatim: AgentSoulStore.shared.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.accent)
                    Text("· 云端")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AmberTheme.muted)
                    if let outcome = event.outcome {
                        Text(verbatim: outcome.displayTitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(outcome == .completed ? AmberTheme.accentGreen : AmberTheme.muted)
                    }
                    Spacer()
                }

                Text(verbatim: event.text)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                    .textSelection(.enabled)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 0.75)
            }
        }
    }

    private func followupBubble(_ followup: MacGatewayCloudDialogueFollowupRecord) -> some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                Text(verbatim: followup.text)
                    .font(.subheadline)
                    .foregroundStyle(followup.state == .cancelled ? AmberTheme.muted : AmberTheme.foreground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(AmberTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text(verbatim: followup.state.displayBadgeText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(followup.state == .cancelled ? .orange : AmberTheme.accent)
            }
        }
    }
}

// MARK: - Explicit Paired Cloud Main Dialogue Sheet View

struct MacGatewayCloudDialogueSheet: View {
    let store: MacGatewayStore
    @Environment(\.dismiss) private var dismiss
    @State private var inputText = ""
    @State private var activeRequestId = UUID().uuidString.lowercased()
    @State private var lastAttemptedFingerprint: String?
    @State private var submitGeneration = 0
    @State private var errorMessage: String?
    @State private var isSending = false

    private var currentFingerprint: String {
        ChatComposerLocalState.cloudDialogueFingerprint(
            text: inputText,
            targetWorkItemId: store.selectedCloudDialogueWorkItemId
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !store.cloudDialogueProgressByWorkItem.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(Array(store.cloudDialogueProgressByWorkItem.values.sorted(by: { $0.lastEventSeq > $1.lastEventSeq }))) { progress in
                            AmberCloudTaskProgressRowView(
                                headline: progress.displaySingleLine,
                                isLive: progress.isLive,
                                outcome: progress.outcome,
                                showsActions: progress.isLive && !progress.isStopRequested,
                                onSupplement: {
                                    store.selectedCloudDialogueWorkItemId = progress.workItemId
                                },
                                onStop: {
                                    Task { _ = await store.stopCloudWorkItem(workItemId: progress.workItemId) }
                                }
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                List {
                    ForEach(store.cloudDialogueVisibleEvents) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(verbatim: event.role == "user" ? macGatewayL("你") : "Amber Cloud")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AmberTheme.muted)
                                if let workItemId = event.workItemId {
                                    Text(verbatim: workItemId)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(AmberTheme.muted2)
                                }
                                Spacer()
                                if event.kind == .followup,
                                   let followup = store.cloudDialogueFollowups.first(where: { $0.eventId == event.id || ($0.workItemId == event.workItemId && $0.text == event.text) }) {
                                    Text(verbatim: followup.state.displayBadgeText)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(followup.state == .cancelled ? .orange : AmberTheme.accent)
                                }
                            }
                            Text(verbatim: event.text)
                                .font(.body)
                                .foregroundStyle(AmberTheme.foreground)
                        }
                        .padding(.vertical, 2)
                    }

                    ForEach(store.cloudDialogueFollowups.filter { record in
                        !store.cloudDialogueVisibleEvents.contains(where: { $0.id == record.eventId })
                    }) { followup in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(verbatim: macGatewayL("任务补充"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AmberTheme.muted)
                                Spacer()
                                Text(verbatim: followup.state.displayBadgeText)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(followup.state == .cancelled ? .orange : AmberTheme.accent)
                            }
                            Text(verbatim: followup.text)
                                .font(.subheadline)
                                .foregroundStyle(followup.state == .cancelled ? AmberTheme.muted : AmberTheme.foreground)
                        }
                    }
                }
                .listStyle(.plain)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    if let targetWorkItemId = store.selectedCloudDialogueWorkItemId {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AmberTheme.accent)
                            Text(verbatim: "\(macGatewayL("补充运行中任务"))：\(targetWorkItemId)")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Button {
                                store.selectedCloudDialogueWorkItemId = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(AmberTheme.muted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    HStack(spacing: 8) {
                        TextField(
                            store.selectedCloudDialogueWorkItemId == nil
                                ? macGatewayL("发送消息给已配对云主对话…")
                                : macGatewayL("向选中任务追加补充说明…"),
                            text: $inputText,
                            axis: .vertical
                        )
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)

                        Button(macGatewayL("发送")) {
                            sendInput()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSending || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(12)
                .background(AmberTheme.surface)
            }
            .navigationTitle(Text(verbatim: macGatewayL("已配对云主对话")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(macGatewayL("关闭")) {
                        store.setCloudMainDialogueSelected(false)
                        dismiss()
                    }
                }
            }
            .onAppear {
                store.setCloudMainDialogueSelected(true)
            }
        }
        .tint(AmberTheme.accent)
    }

    private func sendInput() {
        let submittedFingerprint = currentFingerprint
        if let lastAttemptedFingerprint, lastAttemptedFingerprint != submittedFingerprint {
            activeRequestId = UUID().uuidString.lowercased()
        }
        lastAttemptedFingerprint = submittedFingerprint
        submitGeneration += 1
        let generation = submitGeneration
        let reqId = activeRequestId
        let text = inputText
        let targetWorkItemId = store.selectedCloudDialogueWorkItemId
        isSending = true
        errorMessage = nil

        Task { @MainActor in
            let result: Result<MacGatewayCloudDialogueReceipt, Error>
            if let targetWorkItemId {
                result = await store.sendCloudWorkItemInput(workItemId: targetWorkItemId, text: text, requestId: reqId)
            } else {
                result = await store.sendCloudDialogueMessage(text: text, requestId: reqId)
            }
            if generation == submitGeneration {
                isSending = false
            }
            switch result {
            case .success:
                if inputText == text {
                    inputText = ""
                }
                if store.selectedCloudDialogueWorkItemId == targetWorkItemId {
                    store.selectedCloudDialogueWorkItemId = nil
                }
                if lastAttemptedFingerprint == submittedFingerprint {
                    activeRequestId = UUID().uuidString.lowercased()
                    lastAttemptedFingerprint = nil
                    errorMessage = nil
                }
                _ = await store.pollCloudDialogueEvents()
            case .failure(let error):
                if generation == submitGeneration && currentFingerprint == submittedFingerprint {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
