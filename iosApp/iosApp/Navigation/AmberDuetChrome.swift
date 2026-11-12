import Shared
import SwiftUI

// MARK: - Argon 3+1 Bottom Mode Switcher & Inline Panels (Tasks / Hubs / Secondary Drawer)

enum AmberDuetModeTab: String, CaseIterable, Identifiable {
    case chat
    case tasks
    case hubs

    static var workspace: AmberDuetModeTab { .hubs }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat:
            return IOSAppLocalization.string("对话", defaultValue: "对话")
        case .tasks:
            return IOSAppLocalization.string("任务", defaultValue: "任务")
        case .hubs:
            return IOSAppLocalization.string("中心", defaultValue: "中心")
        }
    }
}

enum AmberHandoffExecutionTarget: String, CaseIterable, Identifiable {
    case cloud
    case cloudMainDialogue
    case localBackground

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .cloud:
            return IOSAppLocalization.string("云端", defaultValue: "云端")
        case .cloudMainDialogue:
            return IOSAppLocalization.string("已配对云主对话", defaultValue: "已配对云主对话")
        case .localBackground:
            return IOSAppLocalization.string("本机", defaultValue: "本机")
        }
    }

    var menuTitle: String {
        switch self {
        case .cloud:
            return IOSAppLocalization.string("云端后台 (Amber Cloud)", defaultValue: "云端后台 (Amber Cloud)")
        case .cloudMainDialogue:
            return IOSAppLocalization.string("已配对云主对话 (Cloud Dialogue)", defaultValue: "已配对云主对话 (Cloud Dialogue)")
        case .localBackground:
            return IOSAppLocalization.string("本机后台子代理", defaultValue: "本机后台子代理")
        }
    }
}

struct AmberDuetBottomSwitcher: View {
    var selectedTab: AmberDuetModeTab = .chat
    var activeTaskCount: Int = 0
    var needsAttentionCount: Int = 0
    var gateway: MacGatewayStore = .shared
    var subAgentStore: IOSSubAgentActivityStore? = nil
    var hubStore: AmberHubStore? = nil
    var onSelectTab: ((AmberDuetModeTab) -> Void)? = nil
    let onOpenTasks: () -> Void
    let onOpenWorkspace: () -> Void
    var onSelectHost: ((Bool) -> Void)? = nil
    var onOpenCloudPairingSettings: (() -> Void)? = nil

    @Namespace private var glassNamespace
    @State private var tabFrames: [AmberDuetModeTab: CGRect] = [:]
    @State private var dragLocationX: CGFloat? = nil
    @State private var dragVelocityX: CGFloat = 0

    private var resolvedTaskCounts: (active: Int, needsAttention: Int) {
        if let subAgentStore {
            let groups = AmberUnifiedTaskProjectionCache.shared.groups(
                gateway: gateway, subAgentStore: subAgentStore, hubStore: hubStore ?? .shared
            )
            return (groups.activeCount, groups.needsAttention.count)
        }
        return (activeTaskCount, needsAttentionCount)
    }

    private var badgeCount: Int {
        let counts = resolvedTaskCounts
        return counts.needsAttention + counts.active
    }

    private var badgeColor: Color {
        resolvedTaskCounts.needsAttention > 0 ? AmberTheme.accentRed : AmberTheme.accent
    }

    var body: some View {
        let _ = ChatRenderProbe.record("duet-chrome-body")
        AmberGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                // Left (3): Native Liquid Glass segmented pill (对话 | 任务 [N] | 中心)
                modeSegmentedTrack

                Spacer(minLength: 4)

                // Right (+1): 本机 ⇄ 云端 宿主切换胶囊（短按一键直切，长按快捷菜单）
                AmberHostSwitcherPill(
                    gateway: gateway,
                    onSelectHost: { useCloud in
                        if let onSelectHost {
                            onSelectHost(useCloud)
                        } else {
                            gateway.setCloudMainDialogueSelected(useCloud)
                            if selectedTab != .chat {
                                onSelectTab?(.chat)
                            }
                        }
                    },
                    onOpenPairingSettings: {
                        onOpenCloudPairingSettings?()
                    }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.duet.bottomSwitcher")
    }

    private var modeSegmentedTrack: some View {
        let counts = resolvedTaskCounts
        let tasksBadgeCount = counts.needsAttention + counts.active
        let tasksBadgeColor = counts.needsAttention > 0 ? AmberTheme.accentRed : AmberTheme.accent
        return HStack(spacing: 2) {
            modeButton(
                tab: .chat,
                isSelected: selectedTab == .chat,
                badgeCount: 0,
                badgeColor: AmberTheme.accent
            ) {
                if let onSelectTab {
                    onSelectTab(.chat)
                }
            }

            modeButton(
                tab: .tasks,
                isSelected: selectedTab == .tasks,
                badgeCount: tasksBadgeCount,
                badgeColor: tasksBadgeColor
            ) {
                if let onSelectTab {
                    onSelectTab(selectedTab == .tasks ? .chat : .tasks)
                } else {
                    onOpenTasks()
                }
            }

            modeButton(
                tab: .hubs,
                isSelected: selectedTab == .hubs,
                badgeCount: 0,
                badgeColor: AmberTheme.accent
            ) {
                if let onSelectTab {
                    onSelectTab(selectedTab == .hubs ? .chat : .hubs)
                } else {
                    onOpenWorkspace()
                }
            }
        }
        .padding(3.5)
        .modifier(DuetBottomTrackWellSurface())
        .contentShape(Capsule(style: .continuous))
        .highPriorityGesture(modeScrubGesture)
        .coordinateSpace(name: "duetModeTrack")
    }

    private func scrubLensDeformation(for tab: AmberDuetModeTab, isSelected: Bool) -> (offsetX: CGFloat, scaleX: CGFloat, scaleY: CGFloat) {
        guard isSelected, let locationX = dragLocationX, let frame = tabFrames[tab], frame.width > 0 else {
            return (0, 1, 1)
        }
        let rawDelta = locationX - frame.midX
        let clampedOffset = min(max(rawDelta * 0.45, -10), 10)
        let edgeStretch = min(abs(rawDelta) / max(1, frame.width * 0.5), 1.0) * 0.05
        let speedFactor = min(abs(dragVelocityX) / 900.0, 1.0)
        let scaleX = 1.0 + edgeStretch + 0.06 * speedFactor
        let scaleY = 1.03 - 0.02 * speedFactor
        return (clampedOffset, scaleX, scaleY)
    }

    private var modeScrubGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("duetModeTrack"))
            .onChanged { value in
                guard abs(value.translation.width) >= abs(value.translation.height) else { return }
                dragLocationX = value.location.x
                dragVelocityX = value.velocity.width
                if let hoveredTab = resolvedTab(at: value.location.x), hoveredTab != selectedTab {
                    withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.82)) {
                        activateTabFromScrub(hoveredTab)
                    }
                }
            }
            .onEnded { value in
                defer {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                        dragLocationX = nil
                        dragVelocityX = 0
                    }
                }
                guard abs(value.translation.width) >= abs(value.translation.height) else { return }
                if let finalTab = resolvedTab(at: value.location.x), finalTab != selectedTab {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                        activateTabFromScrub(finalTab)
                    }
                }
            }
    }


    static func resolvedTab(atX x: CGFloat, in frames: [AmberDuetModeTab: CGRect]) -> AmberDuetModeTab? {
        guard !frames.isEmpty else { return nil }
        if let containing = frames.first(where: { $0.value.insetBy(dx: -2, dy: -16).contains(CGPoint(x: x, y: $0.value.midY)) }) {
            return containing.key
        }
        return frames.min(by: { abs($0.value.midX - x) < abs($1.value.midX - x) })?.key
    }

    static func interpolatedLensRect(
        atX x: CGFloat,
        in frames: [AmberDuetModeTab: CGRect],
        fallbackTab: AmberDuetModeTab
    ) -> CGRect? {
        let ordered = AmberDuetModeTab.allCases.compactMap { tab -> (AmberDuetModeTab, CGRect)? in
            guard let rect = frames[tab], rect.width > 0 else { return nil }
            return (tab, rect)
        }
        guard !ordered.isEmpty else { return frames[fallbackTab] }
        let minMidX = ordered.first!.1.midX
        let maxMidX = ordered.last!.1.midX
        let clampedX = min(max(x, minMidX), maxMidX)

        for idx in 0..<(ordered.count - 1) {
            let lhs = ordered[idx].1
            let rhs = ordered[idx + 1].1
            if clampedX >= lhs.midX && clampedX <= rhs.midX {
                let span = max(1, rhs.midX - lhs.midX)
                let t = (clampedX - lhs.midX) / span
                let width = lhs.width + (rhs.width - lhs.width) * t
                let height = lhs.height + (rhs.height - lhs.height) * t
                let midY = lhs.midY + (rhs.midY - lhs.midY) * t
                return CGRect(x: clampedX - width / 2, y: midY - height / 2, width: width, height: height)
            }
        }
        let target = frames[fallbackTab] ?? ordered.first!.1
        return CGRect(x: clampedX - target.width / 2, y: target.minY, width: target.width, height: target.height)
    }

    private func resolvedTab(at x: CGFloat) -> AmberDuetModeTab? {
        var bestTab: AmberDuetModeTab?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for tab in AmberDuetModeTab.allCases {
            guard let frame = tabFrames[tab], frame.width > 0 else { continue }
            if x >= frame.minX && x <= frame.maxX {
                return tab
            }
            let distance = abs(frame.midX - x)
            if distance < bestDistance {
                bestDistance = distance
                bestTab = tab
            }
        }
        return bestTab
    }

    private func activateTabFromScrub(_ tab: AmberDuetModeTab) {
        if let onSelectTab {
            onSelectTab(tab)
        } else {
            switch tab {
            case .chat:
                break
            case .tasks:
                onOpenTasks()
            case .hubs:
                onOpenWorkspace()
            }
        }
    }

    private func modeButton(
        tab: AmberDuetModeTab,
        isSelected: Bool,
        badgeCount: Int,
        badgeColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        let deformation = scrubLensDeformation(for: tab, isSelected: isSelected)
        return Button(action: action) {
            HStack(spacing: 4) {
                Text(tab.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(badgeColor, in: Capsule(style: .continuous))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(isSelected ? AmberTheme.foreground : AmberTheme.foreground2)
            .padding(.horizontal, tab == .tasks ? 13 : 14)
            .padding(.vertical, 6)
            .modifier(
                DuetActiveModeLensModifier(
                    namespace: isSelected ? glassNamespace : nil,
                    isActive: isSelected
                )
            )
            .scaleEffect(x: deformation.scaleX, y: deformation.scaleY)
            .offset(x: deformation.offsetX)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("duetModeTrack"))
        } action: { rect in
            if tabFrames[tab] != rect {
                tabFrames[tab] = rect
            }
        }
        .accessibilityIdentifier("chat.duet.tab.\(tab.rawValue)")
    }
}

/// Recessed translucent capsule track well for the 3-tab mode switcher (`对话 | 任务 | 中心`).
/// Uses a distinct recessed glass well fill (`AmberTheme.surface2`) + vertical glass sheen +
/// dual-layer contour (outer hairline + inner specular Liquid Glass rim highlight) so the
/// 3-segment container has a clear, continuous outer silhouette on warm-paper and dark canvases,
/// while avoiding nested `.glassEffect` SDF union so the active lens inside refracts and glides cleanly.
private struct DuetBottomTrackWellSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = Capsule(style: .continuous)
        content
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay {
                        shape.fill(AmberTheme.surface2.opacity(0.68))
                    }
                    .overlay {
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    AmberTheme.homeGlassTop.opacity(0.54),
                                    AmberTheme.homeGlassBottom.opacity(0.18),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                    .overlay {
                        shape
                            .inset(by: 0.75)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        AmberTheme.homeGlassHighlight.opacity(0.88),
                                        AmberTheme.homeGlassEdge.opacity(0.28),
                                        AmberTheme.homeGlassHighlight.opacity(0.46),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.65
                            )
                    }
                    .overlay {
                        shape.strokeBorder(AmberTheme.border.opacity(0.64), lineWidth: 0.75)
                    }
            }
            .shadow(color: AmberTheme.homeGlassShadowContact, radius: 2, x: 0, y: 1)
            .shadow(color: AmberTheme.homeGlassShadowAmbient, radius: 9, x: 0, y: 4)
    }
}

/// Native iOS 26 Liquid Glass selection lens modifier for the active mode tab (`对话 | 任务 | 中心`).
/// Applied directly to the tab label so the label text is rendered on top of the `.glassEffect`
/// backdrop layer rather than occluded behind it.
private struct DuetActiveModeLensModifier: ViewModifier {
    var namespace: Namespace.ID?
    var isActive: Bool = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if !isActive {
            content
        } else {
            let shape = Capsule(style: .continuous)
            let backed = content
                .background {
                    shape
                        .fill(AmberTheme.surfaceElevated.opacity(0.82))
                        .shadow(color: Color.black.opacity(0.08), radius: 3.5, x: 0, y: 1.5)
                }
                .overlay {
                    shape
                        .strokeBorder(AmberTheme.homeGlassHighlight.opacity(0.88), lineWidth: 0.65)
                        .allowsHitTesting(false)
                }

            if #available(iOS 26.0, *) {
                if let namespace {
                    backed
                        .glassEffect(
                            .regular.tint(AmberTheme.surfaceElevated.opacity(0.46)).interactive(),
                            in: shape
                        )
                        .glassEffectID("duetActiveTabLens", in: namespace)
                        .glassEffectTransition(.matchedGeometry)
                } else {
                    backed
                        .glassEffect(
                            .regular.tint(AmberTheme.surfaceElevated.opacity(0.46)).interactive(),
                            in: shape
                        )
                }
            } else {
                if let namespace {
                    backed
                        .background(.thinMaterial, in: shape)
                        .matchedGeometryEffect(id: "duetActiveTabLens", in: namespace)
                } else {
                    backed
                        .background(.thinMaterial, in: shape)
                }
            }
        }
    }
}

struct DuetBottomCapsuleGlass: ViewModifier {
    var isHighlighted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = Capsule(style: .continuous)
        if #available(iOS 26.0, *) {
            content
                .background {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay {
                            shape.fill(AmberTheme.glass.opacity(0.16))
                        }
                }
                .glassEffect(.regular.interactive(), in: shape)
                .overlay {
                    shape
                        .strokeBorder(
                            isHighlighted ? AmberTheme.accent.opacity(0.42) : AmberTheme.border.opacity(0.32),
                            lineWidth: isHighlighted ? 0.9 : 0.6
                        )
                        .allowsHitTesting(false)
                }
        } else {
            content
                .background(.thinMaterial, in: shape)
                .overlay {
                    shape
                        .strokeBorder(
                            isHighlighted ? AmberTheme.accent.opacity(0.42) : AmberTheme.border,
                            lineWidth: 0.75
                        )
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
        }
    }
}

// MARK: - 02 Argon Tasks Panel (Real Delegated / Background / Scheduled Work)

/// The panel lists only work a durable owner actually holds. A normal assistant
/// turn that happens to call several tools keeps its single progress line inside
/// the conversation and never appears here.
private struct AmberCloudTaskSelection: Identifiable, Equatable {
    let requestId: String
    var id: String { requestId }
}

struct AmberDuetTaskCenterCard: View {
    let gateway: MacGatewayStore
    var subAgentStore: IOSSubAgentActivityStore = .shared
    var taskStore: IOSAdvancedTaskStore = .shared
    var wakeStore: IOSWakeTaskStore = .shared
    var hubStore: AmberHubStore = .shared
    var intentInboxStore: AmberIntentInboxStore = .shared
    var isEmbeddedInModalSheet: Bool = false
    let onOpenFullTaskBoard: () -> Void
    var onOpenTask: ((AmberUnifiedTaskItem) -> Void)? = nil
    var onFollowupTask: ((AmberUnifiedTaskItem) -> Void)? = nil
    var onDismissPanel: (() -> Void)? = nil
    var onHeaderDragChanged: ((DragGesture.Value) -> Void)? = nil
    var onHeaderDragEnded: ((DragGesture.Value) -> Void)? = nil

    static let initialRecentPreviewCount = 3

    @State private var selectedHubFilterId: String? = nil
    @State private var isRecentExpanded: Bool = false
    @State private var selectedCloudTask: AmberCloudTaskSelection? = nil
    @State private var selectedDeliverableTask: AmberUnifiedTaskItem? = nil
    @State private var inlineDeliverableTask: AmberUnifiedTaskItem? = nil

    private var groups: AmberUnifiedTaskBuilder.Groups {
        AmberUnifiedTaskProjectionCache.shared.groups(
            gateway: gateway, subAgentStore: subAgentStore, taskStore: taskStore,
            wakeStore: wakeStore, hubStore: hubStore, filterHubId: selectedHubFilterId
        )
    }

    private var filterHubTitle: String {
        if let filterId = selectedHubFilterId,
           let hub = hubStore.hubs.first(where: { $0.id == filterId }) {
            return hub.title
        }
        return IOSAppLocalization.string("全部中心", defaultValue: "全部中心")
    }

    var body: some View {
        let _ = ChatRenderProbe.record("panel-tasks-body")
        let current = ChatRenderProbe.measureUs("us:panel-tasks-groups") { groups }
        Group {
            if isEmbeddedInModalSheet {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    taskBodyContent(current: current)
                }
                .padding(.horizontal, 20)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 8, coordinateSpace: ChatSheetDismissSmoothnessPolicy.inlinePanelDragCoordinateSpace)
                                .onChanged { onHeaderDragChanged?($0) }
                                .onEnded { onHeaderDragEnded?($0) }
                        )

                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 20) {
                            taskBodyContent(current: current)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 2)
                        .padding(.bottom, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .amberInlinePanelScrollDismiss()
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .accessibilityIdentifier("chat.duet.tasksPanel")
        .sheet(item: $selectedCloudTask) { selection in
            MacGatewayCloudTaskDetailSheet(store: gateway, requestId: selection.requestId)
        }
        .sheet(item: $selectedDeliverableTask) { deliverable in
            AmberTaskDeliverablePreviewSheet(
                item: deliverable,
                onOpenDestination: { task in
                    openDestinationDirectly(task)
                },
                onQuickDecision: { task, decision in
                    Task { await handleQuickDecision(decision, for: task) }
                }
            )
            .amberFloatingSheet(detents: [.medium, .large])
        }
    }

    @ViewBuilder
    private func taskBodyContent(current: AmberUnifiedTaskBuilder.Groups) -> some View {
        if let inlineTask = inlineDeliverableTask {
            AmberTaskDeliverablePreviewContent(
                item: inlineTask,
                onBack: {
                    withAnimation(.snappy(duration: 0.2)) {
                        inlineDeliverableTask = nil
                    }
                },
                onOpenDestination: { task in
                    inlineDeliverableTask = nil
                    openDestinationDirectly(task)
                },
                onQuickDecision: { task, decision in
                    inlineDeliverableTask = nil
                    Task { await handleQuickDecision(decision, for: task) }
                }
            )
        } else {
            AmberIntentInboxSectionView(
                store: intentInboxStore,
                onAcceptCandidate: { payload in
                    let resolvedPayload = intentInboxStore.accept(id: payload.candidateId) ?? payload
                    let followupItem = AmberUnifiedTaskItem(
                        id: "intent-candidate-\(resolvedPayload.candidateId)",
                        title: resolvedPayload.title,
                        subtitle: resolvedPayload.sourceQuote,
                        statusText: resolvedPayload.kind.badgeTitle,
                        actionButtonTitle: resolvedPayload.suggestedPrompt,
                        phase: .needsAttention,
                        ownership: resolvedPayload.kind == .scheduledWatch ? .scheduledMonitor : .delegated,
                        source: .localSubAgent(resolvedPayload.candidateId)
                    )
                    onDismissPanel?()
                    onFollowupTask?(followupItem)
                }
            )

            if current.isEmpty {
                if intentInboxStore.pendingCandidates.isEmpty {
                    emptyState
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    if !current.needsAttention.isEmpty {
                        section(
                            title: IOSAppLocalization.string("等你处理", defaultValue: "等你处理"),
                            items: current.needsAttention
                        )
                    }
                    if !current.running.isEmpty {
                        section(
                            title: IOSAppLocalization.string("进行中", defaultValue: "进行中"),
                            items: current.running
                        )
                    }
                    if !current.scheduled.isEmpty {
                        section(
                            title: IOSAppLocalization.string("已排定", defaultValue: "已排定"),
                            items: current.scheduled
                        )
                    }
                    if !current.recent.isEmpty {
                        recentSection(current.recent)
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                Capsule()
                    .fill(AmberTheme.border)
                    .frame(width: 36, height: 4)
                Spacer()
            }
            .padding(.top, 10)

            HStack(alignment: .center) {
                Text(IOSAppLocalization.string("任务", defaultValue: "任务"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AmberTheme.foreground)

                Spacer()

                Menu {
                    Button {
                        selectedHubFilterId = nil
                    } label: {
                        HStack {
                            Text(IOSAppLocalization.string("全部中心", defaultValue: "全部中心"))
                            if selectedHubFilterId == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    ForEach(hubStore.hubs) { hub in
                        Button {
                            selectedHubFilterId = hub.id
                        } label: {
                            HStack {
                                Text(hub.title)
                                if selectedHubFilterId == hub.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(filterHubTitle)
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(AmberTheme.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(AmberTheme.surface, in: Capsule(style: .continuous))
                }
                .accessibilityIdentifier("chat.duet.tasks.hubFilter")
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(IOSAppLocalization.string("暂时没有交办事项", defaultValue: "暂时没有交办事项"))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AmberTheme.foreground)

            Text(IOSAppLocalization.string(
                "把一件事交给后台或定时执行，它就会出现在这里；对话里的普通查询和工具步骤只在对话流内显示",
                defaultValue: "把一件事交给后台或定时执行，它就会出现在这里；对话里的普通查询和工具步骤只在对话流内显示"
            ))
            .font(.system(size: 12.5))
            .foregroundStyle(AmberTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func section(
        title: String,
        items: [AmberUnifiedTaskItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AmberTheme.muted)
                Text("\(items.count)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(AmberTheme.muted2)
            }
            .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider()
                            .overlay(AmberTheme.border.opacity(0.6))
                            .padding(.leading, 16)
                    }
                    taskRow(item)
                }
            }
            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AmberTheme.border, lineWidth: 0.6)
            }
        }
    }

    private func taskRow(_ item: AmberUnifiedTaskItem) -> some View {
        let statusColor = AmberUnifiedTaskBuilder.statusColor(for: item)
        let stageLine = rowStageLine(item)
        let distinctBullets = distinctDeliverableBullets(for: item, stageLine: stageLine)

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if item.phase == .needsAttention && item.hasDeliverablePreview {
                    presentDeliverablePreview(item)
                } else {
                    open(item)
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .padding(.top, 6)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AmberTheme.foreground)
                            .lineLimit(1)

                        Text(stageLine)
                            .font(.system(size: 12.5))
                            .foregroundStyle(AmberTheme.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        if item.phase == .needsAttention && !distinctBullets.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(distinctBullets.prefix(2).enumerated()), id: \.offset) { _, bullet in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("·")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(AmberTheme.muted)
                                        Text(bullet)
                                            .font(.system(size: 12))
                                            .foregroundStyle(AmberTheme.foreground2)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }

                        if item.phase == .needsAttention,
                           let decisionPrompt = item.decisionPrompt,
                           !decisionPrompt.isEmpty,
                           decisionPrompt != stageLine {
                            HStack(alignment: .top, spacing: 8) {
                                RoundedRectangle(cornerRadius: 1, style: .continuous)
                                    .fill(AmberTheme.accentAmber)
                                    .frame(width: 2)
                                    .padding(.vertical, 2)

                                Text(decisionPrompt)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(AmberTheme.foreground)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.top, 2)
                        }
                    }

                    Spacer(minLength: 8)

                    Text(item.statusText)
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(statusColor)
                        .padding(.top, 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !item.quickActions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(item.quickActions) { decision in
                        Button {
                            Task { await handleQuickDecision(decision, for: item) }
                        } label: {
                            Text(decision.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(decision.isPrimary ? AmberTheme.accent : AmberTheme.foreground2)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    decision.isPrimary
                                        ? AmberTheme.accent.opacity(0.12)
                                        : AmberTheme.surface2,
                                    in: Capsule(style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.duet.tasks.quickAction.\(item.id).\(decision.kind.rawValue)")
                    }

                    if item.hasDeliverablePreview {
                        Button {
                            presentDeliverablePreview(item)
                        } label: {
                            Text(IOSAppLocalization.string("查看结论", defaultValue: "查看结论"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AmberTheme.muted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.duet.tasks.preview.\(item.id)")
                    }
                }
                .padding(.leading, 16)
            } else if let actionTitle = item.actionTitle {
                Button {
                    if actionTitle == "去确认" {
                        Task {
                            await handleQuickDecision(
                                AmberTaskQuickDecision(title: actionTitle, kind: .confirmApproval),
                                for: item
                            )
                        }
                    } else if actionTitle == "重试" {
                        Task {
                            await handleQuickDecision(
                                AmberTaskQuickDecision(title: actionTitle, kind: .retry),
                                for: item
                            )
                        }
                    } else if let onFollowupTask {
                        onDismissPanel?()
                        onFollowupTask(item)
                    } else {
                        open(item)
                    }
                } label: {
                    Text(actionTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AmberTheme.accent)
                        .padding(.leading, 16)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.duet.tasks.row.\(item.id)")
    }

    /// Stage, most recent real conclusion and next step — never an invented
    /// percentage. A task with no outcome yet simply does not show one.
    private func rowStageLine(_ item: AmberUnifiedTaskItem) -> String {
        var parts: [String] = [item.subtitle]
        if let result = item.resultText,
           !result.isEmpty,
           result != item.subtitle,
           !item.subtitle.contains(result),
           result != item.decisionPrompt {
            parts.append(result)
        }
        if item.phase == .scheduled, let nextRunAt = item.nextRunAt {
            parts.append(IOSAppLocalization.string("下次", defaultValue: "下次") + " "
                         + nextRunAt.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    private func distinctDeliverableBullets(for item: AmberUnifiedTaskItem, stageLine: String) -> [String] {
        item.deliverableBullets.filter { bullet in
            bullet != item.resultText
                && bullet != item.subtitle
                && bullet != item.decisionPrompt
                && !stageLine.contains(bullet)
        }
    }

    func handleQuickDecision(_ decision: AmberTaskQuickDecision, for item: AmberUnifiedTaskItem) async {
        if decision.kind == .openDetail || decision.kind == .confirmApproval {
            openDestinationDirectly(item)
            return
        }
        if case .gatewayBoardItem = item.source {
            openDestinationDirectly(item)
            return
        }
        if case .gatewaySchedule = item.source {
            openDestinationDirectly(item)
            return
        }
        if decision.kind == .retry {
            switch item.source {
            case .cloudTask(let requestId):
                if let record = gateway.cloudTasks.first(where: { $0.requestId == requestId }),
                   !record.needsSubmissionRetry {
                    openDestinationDirectly(item)
                } else {
                    _ = await gateway.retryCloudTask(requestId: requestId)
                }
                return
            default:
                if item.destination != .none {
                    openDestinationDirectly(item)
                    return
                }
            }
        }
        if decision.kind == .approveAndContinue {
            switch item.source {
            case .cloudTask(let requestId):
                if let record = gateway.cloudTasks.first(where: { $0.requestId == requestId }),
                   let workItemId = record.workItemId,
                   !record.isTerminal {
                    let text = decision.followupInstruction ?? decision.title
                    let result = await gateway.sendCloudWorkItemInput(workItemId: workItemId, text: text)
                    if case .success = result {
                        await gateway.refreshCloudTask(workItemId: workItemId)
                    }
                } else {
                    openDestinationDirectly(item)
                }
                return
            case .cloudDialogueWorkItem(let workItemId):
                let text = decision.followupInstruction ?? decision.title
                _ = await gateway.sendCloudWorkItemInput(workItemId: workItemId, text: text)
                return
            case .localSubAgent, .executionRecord:
                if item.destination != .none {
                    openDestinationDirectly(item.applyingQuickDecision(decision))
                    return
                }
            default:
                break
            }
        }
        if decision.kind == .adjustDirection {
            switch item.source {
            case .localSubAgent, .executionRecord, .cloudDialogueWorkItem:
                if item.destination != .none {
                    openDestinationDirectly(item.applyingQuickDecision(decision))
                    return
                }
            default:
                break
            }
        }
        let updated = item.applyingQuickDecision(decision)
        if let onFollowupTask {
            onDismissPanel?()
            onFollowupTask(updated)
        } else {
            openDestinationDirectly(updated)
        }
    }

    private func presentDeliverablePreview(_ item: AmberUnifiedTaskItem) {
        if case .cloudTaskDetail(let requestId) = item.destination, !item.hasDeliverablePreview {
            selectedCloudTask = AmberCloudTaskSelection(requestId: requestId)
            return
        }
        withAnimation(.snappy(duration: 0.2)) {
            inlineDeliverableTask = item
        }
    }

    private func open(_ item: AmberUnifiedTaskItem) {
        if item.phase == .completed && item.hasDeliverablePreview {
            presentDeliverablePreview(item)
            return
        }
        openDestinationDirectly(item)
    }

    private func openDestinationDirectly(_ item: AmberUnifiedTaskItem) {
        switch item.destination {
        case .cloudTaskDetail(let requestId):
            selectedCloudTask = AmberCloudTaskSelection(requestId: requestId)
        case .subAgentConversation, .executionRecord, .wakeConversation, .cloudDialogueWorkItem, .macBoard:
            onDismissPanel?()
            onOpenTask?(item)
        case .none:
            onDismissPanel?()
            if let onFollowupTask {
                onFollowupTask(item)
            } else {
                onOpenTask?(item)
            }
        }
    }

    private func recentSection(_ recentItems: [AmberUnifiedTaskItem]) -> some View {
        let summaryText = AmberUnifiedTaskBuilder.recentSummaryText(recentItems)
        let visibleItems = isRecentExpanded
            ? recentItems
            : Array(recentItems.prefix(Self.initialRecentPreviewCount))
        let hiddenCount = max(0, recentItems.count - Self.initialRecentPreviewCount)

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isRecentExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text(IOSAppLocalization.string("近期交付", defaultValue: "近期交付"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AmberTheme.muted)

                    Text(summaryText)
                        .font(.system(size: 12))
                        .foregroundStyle(AmberTheme.muted2)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(isRecentExpanded
                        ? IOSAppLocalization.string("收起", defaultValue: "收起")
                        : (hiddenCount > 0
                            ? "展开其余 \(hiddenCount) 项"
                            : IOSAppLocalization.string("展开", defaultValue: "展开")))
                        .font(.system(size: 12))
                        .foregroundStyle(AmberTheme.muted)

                    Image(systemName: isRecentExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AmberTheme.muted2)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.duet.tasks.recentSummaryBar")

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider()
                            .overlay(AmberTheme.border.opacity(0.6))
                            .padding(.leading, 16)
                    }
                    recentDeliverableRow(item)
                }
            }
            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AmberTheme.border, lineWidth: 0.6)
            }

            if isRecentExpanded {
                Button {
                    onDismissPanel?()
                    onOpenFullTaskBoard()
                } label: {
                    Text(IOSAppLocalization.string("打开完整任务与定时看板", defaultValue: "打开完整任务与定时看板"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(AmberTheme.accent)
                        .padding(.leading, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func recentDeliverableRow(_ item: AmberUnifiedTaskItem) -> some View {
        let statusColor = AmberUnifiedTaskBuilder.statusColor(for: item)
        let primarySummary = (item.phase == .completed && item.resultText?.isEmpty == false) ? item.resultText! : item.subtitle
        let bullets = item.deliverableBullets.filter { $0 != primarySummary }

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                open(item)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .padding(.top, 6)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AmberTheme.foreground)
                            .lineLimit(1)

                        Text(primarySummary)
                            .font(.system(size: 12.5))
                            .foregroundStyle(item.phase == .completed ? AmberTheme.foreground2 : AmberTheme.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        if !bullets.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(bullets.prefix(2).enumerated()), id: \.offset) { _, bullet in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("·")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(AmberTheme.muted)
                                        Text(bullet)
                                            .font(.system(size: 12))
                                            .foregroundStyle(AmberTheme.muted)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .padding(.top, 1)
                        }
                    }

                    Spacer(minLength: 8)

                    Text(item.statusText)
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(statusColor)
                        .padding(.top, 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if item.hasDeliverablePreview && item.destination != .none {
                HStack(spacing: 12) {
                    Button {
                        presentDeliverablePreview(item)
                    } label: {
                        Text(IOSAppLocalization.string("查看结论", defaultValue: "查看结论"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AmberTheme.accent)
                    }
                    .buttonStyle(.plain)

                    Button {
                        openDestinationDirectly(item)
                    } label: {
                        Text(IOSAppLocalization.string("打开会话", defaultValue: "打开会话"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AmberTheme.muted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 16)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.duet.tasks.recentRow.\(item.id)")
    }
}

struct AmberDuetTaskCenterSheet: View {
    let gateway: MacGatewayStore
    var subAgentStore: IOSSubAgentActivityStore = .shared
    var taskStore: IOSAdvancedTaskStore = .shared
    var wakeStore: IOSWakeTaskStore = .shared
    var hubStore: AmberHubStore = .shared
    let onOpenFullTaskBoard: () -> Void
    var onOpenTask: ((AmberUnifiedTaskItem) -> Void)? = nil
    var onFollowupTask: ((AmberUnifiedTaskItem) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                AmberDuetTaskCenterCard(
                    gateway: gateway,
                    subAgentStore: subAgentStore,
                    taskStore: taskStore,
                    wakeStore: wakeStore,
                    hubStore: hubStore,
                    isEmbeddedInModalSheet: true,
                    onOpenFullTaskBoard: onOpenFullTaskBoard,
                    onOpenTask: onOpenTask,
                    onFollowupTask: onFollowupTask,
                    onDismissPanel: { dismiss() }
                )
                .padding(.vertical, 12)
                .amberSmoothSheetScrollDismiss()
            }
            .background(AmberTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(IOSAppLocalization.string("完成", defaultValue: "完成")) {
                        dismiss()
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AmberTheme.accent)
                }
            }
        }
    }
}


// MARK: - 03 Argon Hubs Panel Card & Sheet (Iconless Typography + Collapsed Smart Collections)

struct AmberDuetHubsCard: View {
    var hubStore: AmberHubStore = .shared
    let conversationStore: IOSConversationStore
    let gateway: MacGatewayStore
    var subAgentStore: IOSSubAgentActivityStore = .shared
    var taskStore: IOSAdvancedTaskStore = .shared
    var wakeStore: IOSWakeTaskStore = .shared
    var onSelectHub: ((AmberHubItem) -> Void)? = nil
    var onDismissPanel: (() -> Void)? = nil
    var onHeaderDragChanged: ((DragGesture.Value) -> Void)? = nil
    var onHeaderDragEnded: ((DragGesture.Value) -> Void)? = nil

    @State private var isSmartCollectionsExpanded: Bool = false
    @State private var isShowingCreateHubForm: Bool = false
    @State private var newHubTitle: String = ""
    @State private var newHubMemoryPolicy: AmberHubMemoryPolicy = .sharedWithGlobal

    private var allActiveTasks: [AmberUnifiedTaskItem] {
        let grouped = AmberUnifiedTaskProjectionCache.shared.groups(
            gateway: gateway, subAgentStore: subAgentStore, taskStore: taskStore,
            wakeStore: wakeStore, hubStore: hubStore
        )
        return grouped.needsAttention + grouped.running
    }

    var body: some View {
        let _ = ChatRenderProbe.record("panel-hubs-body")
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 12) {
                // Drag indicator
                HStack {
                    Spacer()
                    Capsule()
                        .fill(AmberTheme.border)
                        .frame(width: 36, height: 4)
                    Spacer()
                }
                .padding(.top, 10)

                // Header: 中心 + [1 个合集可升级 | +]
                HStack(alignment: .center) {
                    Text(IOSAppLocalization.string("中心", defaultValue: "中心"))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(AmberTheme.foreground)

                    Spacer()

                    headerActionCapsule
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: ChatSheetDismissSmoothnessPolicy.inlinePanelDragCoordinateSpace)
                    .onChanged { onHeaderDragChanged?($0) }
                    .onEnded { onHeaderDragEnded?($0) }
            )

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    if isShowingCreateHubForm {
                        createHubInlineForm
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        if hubStore.hubs.isEmpty {
                            Text(IOSAppLocalization.string("尚未创建中心 · 点按右上角 + 可将长期主题归拢为中心", defaultValue: "尚未创建中心 · 点按右上角 + 可将长期主题归拢为中心"))
                                .font(.subheadline)
                                .foregroundStyle(AmberTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        } else {
                            let activeTasks = ChatRenderProbe.measureUs("us:panel-hubs-tasks") { allActiveTasks }
                            // Pure-typography Hub cards (No left category icon boxes)
                            ForEach(hubStore.hubs) { hub in
                                hubRowCard(hub, activeTasks: activeTasks)
                            }
                        }

                        // Collapsed single-line Smart Collections bar
                        smartCollectionsSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .amberInlinePanelScrollDismiss()
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("chat.duet.hubsPanel")
    }

    private var headerActionCapsule: some View {
        let upgradableCount = ChatRenderProbe.measureUs("us:panel-hubs-collections") {
            hubStore.upgradableCollectionCount
        }
        return HStack(spacing: 8) {
            if upgradableCount > 0 {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        isSmartCollectionsExpanded = true
                    }
                } label: {
                    Text("\(upgradableCount) 个合集可升级")
                        .font(.system(size: 11.8, weight: .medium))
                        .foregroundStyle(AmberTheme.accent)
                }
                .buttonStyle(.plain)

                Rectangle()
                    .fill(AmberTheme.accent.opacity(0.25))
                    .frame(width: 1, height: 11)
            }

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isShowingCreateHubForm.toggle()
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AmberTheme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.duet.hubs.createButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(AmberTheme.accent.opacity(0.09), in: Capsule(style: .continuous))
    }

    private var createHubInlineForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(IOSAppLocalization.string("输入新中心名称（如：量子计算调研）", defaultValue: "输入新中心名称（如：量子计算调研）"), text: $newHubTitle)
                .font(.subheadline)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AmberTheme.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Picker("", selection: $newHubMemoryPolicy) {
                    ForEach(AmberHubMemoryPolicy.allCases, id: \.rawValue) { policy in
                        Text(policy.displayTitle).tag(policy)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    let created = hubStore.createHub(title: newHubTitle, memoryPolicy: newHubMemoryPolicy)
                    if let currentConvId = conversationStore.currentConversation?.id.description() {
                        hubStore.assignConversation(currentConvId, toHub: created.id)
                    }
                    newHubTitle = ""
                    isShowingCreateHubForm = false
                    onSelectHub?(created)
                } label: {
                    Text(IOSAppLocalization.string("创建", defaultValue: "创建"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(AmberTheme.accent, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func hubRowCard(_ hub: AmberHubItem, activeTasks: [AmberUnifiedTaskItem]) -> some View {
        let isCurrent = hubStore.activeHubId == hub.id
        let subtitle = hubStore.subtitle(
            for: hub,
            activeTasks: activeTasks
        )
        return Button {
            hubStore.selectHub(hub.id)
            if let currentConvId = conversationStore.currentConversation?.id.description() {
                hubStore.assignConversation(currentConvId, toHub: hub.id)
            }
            onSelectHub?(hub)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3.5) {
                    HStack(spacing: 7) {
                        Text(hub.title)
                            .font(.system(size: 14.2, weight: .semibold))
                            .foregroundStyle(AmberTheme.foreground)
                            .lineLimit(1)

                        if isCurrent {
                            Text(IOSAppLocalization.string("当前", defaultValue: "当前"))
                                .font(.system(size: 10.2, weight: .medium))
                                .foregroundStyle(AmberTheme.accentGreen)
                                .padding(.horizontal, 6.5)
                                .padding(.vertical, 1.5)
                                .background(AmberTheme.accentGreen.opacity(0.11), in: Capsule(style: .continuous))
                        }

                        if hub.memoryPolicy == .hubIsolated && !subtitle.contains("独立记忆") {
                            Text(IOSAppLocalization.string("独立记忆", defaultValue: "独立记忆"))
                                .font(.caption2)
                                .foregroundStyle(AmberTheme.muted)
                        }
                    }

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AmberTheme.muted2)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(AmberTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(isCurrent ? AmberTheme.accent.opacity(0.30) : AmberTheme.border, lineWidth: isCurrent ? 0.9 : 0.75)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.duet.hubs.row.\(hub.id)")
    }

    private var smartCollectionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard !hubStore.smartCollections.isEmpty else { return }
                withAnimation(.snappy(duration: 0.2)) {
                    isSmartCollectionsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text(IOSAppLocalization.string("智能合集", defaultValue: "智能合集"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AmberTheme.foreground2)

                    if let summary = hubStore.smartCollectionsSummaryText {
                        Text(summary)
                            .font(.system(size: 12))
                            .foregroundStyle(AmberTheme.muted)
                            .lineLimit(1)

                        Spacer(minLength: 6)

                        Text(isSmartCollectionsExpanded ? "收起" : "展开")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(AmberTheme.muted)

                        Image(systemName: isSmartCollectionsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(AmberTheme.muted2)
                    } else {
                        Spacer(minLength: 6)

                        Text(IOSAppLocalization.string("暂无自动归拢项", defaultValue: "暂无自动归拢项"))
                            .font(.system(size: 12))
                            .foregroundStyle(AmberTheme.muted)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.duet.hubs.smartCollectionsBar")

            if isSmartCollectionsExpanded {
                ForEach(hubStore.smartCollections) { collection in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(collection.title) (\(collection.conversationCount))")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AmberTheme.foreground)
                            Text(collection.sampleKeywords.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(AmberTheme.muted)
                        }

                        Spacer()

                        Button {
                            withAnimation(.snappy(duration: 0.22)) {
                                _ = hubStore.promoteSmartCollectionToHub(collection.id)
                            }
                        } label: {
                            Text(IOSAppLocalization.string("升级为中心", defaultValue: "升级为中心"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(AmberTheme.accent)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4.5)
                                .background(AmberTheme.accent.opacity(0.12), in: Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.duet.hubs.promote.\(collection.id)")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
            }
        }
    }
}
