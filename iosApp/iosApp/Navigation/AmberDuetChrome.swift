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
    case localBackground

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .cloud:
            return IOSAppLocalization.string("云端", defaultValue: "云端")
        case .localBackground:
            return IOSAppLocalization.string("本机", defaultValue: "本机")
        }
    }
}

struct AmberDuetBottomSwitcher: View {
    var selectedTab: AmberDuetModeTab = .chat
    let activeTaskCount: Int
    let needsAttentionCount: Int
    var isBackgroundHandoffMode: Bool = false
    var handoffExecutionTarget: AmberHandoffExecutionTarget = .cloud
    var activeHubTitle: String? = nil
    var hubs: [AmberHubItem] = []
    var cloudAgents: [MacGatewayCloudAgent] = []
    var selectedCloudAgentId: String = "main"
    var onSelectTab: ((AmberDuetModeTab) -> Void)? = nil
    let onOpenTasks: () -> Void
    let onOpenWorkspace: () -> Void
    var onDelegateCloudTask: (() -> Void)? = nil
    var onSelectHub: ((String?) -> Void)? = nil
    var onSelectExecutionTarget: ((AmberHandoffExecutionTarget) -> Void)? = nil
    var onSelectCloudAgent: ((String) -> Void)? = nil
    var onExitHandoffMode: (() -> Void)? = nil

    private var badgeCount: Int {
        needsAttentionCount > 0 ? needsAttentionCount : activeTaskCount
    }

    private var badgeColor: Color {
        needsAttentionCount > 0 ? AmberTheme.accentRed : AmberTheme.accent
    }

    var body: some View {
        HStack(spacing: 8) {
            // Left: Pure-typography segmented pill (对话 | 任务 [N] | 中心)
            HStack(spacing: 2) {
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
                    badgeCount: badgeCount,
                    badgeColor: badgeColor
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
            .background(AmberTheme.surface.opacity(0.96), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 0.75)
            }

            Spacer(minLength: 4)

            // Right (+1): In-place morphing between "后台交办 ↗" and "● 云端 · <当前中心> ⌄"
            if isBackgroundHandoffMode {
                handoffTargetMenuPill
            } else if let onDelegateCloudTask {
                Button(action: onDelegateCloudTask) {
                    HStack(spacing: 4) {
                        Text(IOSAppLocalization.string("后台交办", defaultValue: "后台交办"))
                            .font(.caption.weight(.semibold))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(AmberTheme.accent)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(AmberTheme.surface.opacity(0.95), in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(AmberTheme.accent.opacity(0.28), lineWidth: 0.85)
                    }
                }
                .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.97, haptic: .selection))
                .accessibilityIdentifier("chat.duet.delegateTaskButton")
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.duet.bottomSwitcher")
    }

    private var handoffTargetMenuPill: some View {
        let hubName = (activeHubTitle?.isEmpty == false) ? activeHubTitle! : IOSAppLocalization.string("当前中心", defaultValue: "当前中心")
        return Menu {
            Section(IOSAppLocalization.string("执行位置", defaultValue: "执行位置")) {
                ForEach(AmberHandoffExecutionTarget.allCases) { target in
                    Button {
                        onSelectExecutionTarget?(target)
                    } label: {
                        HStack {
                            Text(target == .cloud ? "云端后台 (Amber Cloud)" : "本机后台子代理")
                            if handoffExecutionTarget == target {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            if !hubs.isEmpty {
                Section(IOSAppLocalization.string("归属中心", defaultValue: "归属中心")) {
                    ForEach(hubs) { hub in
                        Button {
                            onSelectHub?(hub.id)
                        } label: {
                            HStack {
                                Text(hub.title)
                                if hub.title == activeHubTitle {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            if handoffExecutionTarget == .cloud && !cloudAgents.isEmpty {
                Section(IOSAppLocalization.string("云端 Agent", defaultValue: "云端 Agent")) {
                    ForEach(cloudAgents) { agent in
                        Button {
                            onSelectCloudAgent?(agent.id)
                        } label: {
                            HStack {
                                Text(agent.name)
                                if agent.id == selectedCloudAgentId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            if let onExitHandoffMode {
                Divider()
                Button(role: .destructive, action: onExitHandoffMode) {
                    Label(IOSAppLocalization.string("退出后台交办模式", defaultValue: "退出后台交办模式"), systemImage: "xmark.circle")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(handoffExecutionTarget == .cloud ? AmberTheme.accentGreen : AmberTheme.accent)
                    .frame(width: 6, height: 6)

                Text("\(handoffExecutionTarget.shortLabel) · \(hubName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(AmberTheme.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AmberTheme.surface.opacity(0.96), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(AmberTheme.border, lineWidth: 0.85)
            }
        }
        .accessibilityIdentifier("chat.duet.handoffTargetMenu")
    }

    private func modeButton(
        tab: AmberDuetModeTab,
        isSelected: Bool,
        badgeCount: Int,
        badgeColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(tab.title)
                    .font(.caption.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(badgeColor, in: Capsule(style: .continuous))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(isSelected ? AmberTheme.foreground : AmberTheme.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(AmberTheme.background)
                        .shadow(color: Color.black.opacity(0.06), radius: 2, x: 0, y: 1)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.duet.tab.\(tab.rawValue)")
    }
}

// MARK: - 02 Argon Tasks Panel Card & Sheet (Goal/Status Grouped + Collapsed History)

struct AmberDuetTaskCenterCard: View {
    let conversationSegments: [ChatTaskRunSegment]
    let gateway: MacGatewayStore
    var subAgentStore: IOSSubAgentActivityStore = .shared
    var hubStore: AmberHubStore = .shared
    let onOpenFullTaskBoard: () -> Void
    let onSelectTool: (UIMessagePart.Tool) -> Void
    var onFollowupTask: ((AmberUnifiedTaskItem) -> Void)? = nil
    var onDismissPanel: (() -> Void)? = nil

    @State private var selectedHubFilterId: String? = nil
    @State private var isRecentExpanded: Bool = false
    @State private var selectedSegment: ChatTaskRunSegment? = nil

    private var groupedTasks: (needsAttention: [AmberUnifiedTaskItem], running: [AmberUnifiedTaskItem], recent: [AmberUnifiedTaskItem]) {
        AmberUnifiedTaskBuilder.buildTasks(
            conversationSegments: conversationSegments,
            gateway: gateway,
            subAgentStore: subAgentStore,
            hubStore: hubStore,
            filterHubId: selectedHubFilterId
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
        let groups = groupedTasks
        VStack(alignment: .leading, spacing: 14) {
            // Drag indicator
            HStack {
                Spacer()
                Capsule()
                    .fill(AmberTheme.border)
                    .frame(width: 36, height: 4)
                Spacer()
            }
            .padding(.top, 8)

            // Header: 任务 + 全部中心 ⌄
            HStack(alignment: .center) {
                Text(IOSAppLocalization.string("任务", defaultValue: "任务"))
                    .font(.title3.weight(.bold))
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
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AmberTheme.foreground2)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(AmberTheme.muted)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(AmberTheme.background.opacity(0.85), in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(AmberTheme.borderSoft, lineWidth: 0.75)
                    }
                }
                .accessibilityIdentifier("chat.duet.tasks.hubFilter")
            }
            .padding(.horizontal, 18)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    // 1. Needs-Attention / Failed Tasks (Top Priority, No Warning Icon)
                    ForEach(groups.needsAttention) { item in
                        needsAttentionCard(item)
                    }

                    // 2. Active / Running Tasks
                    ForEach(groups.running) { item in
                        runningTaskCard(item)
                    }

                    if groups.needsAttention.isEmpty && groups.running.isEmpty && groups.recent.isEmpty {
                        Text(IOSAppLocalization.string("当前暂无运行中或待处理的任务", defaultValue: "当前暂无运行中或待处理的任务"))
                            .font(.subheadline)
                            .foregroundStyle(AmberTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(AmberTheme.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    // 3. Collapsed Recent Terminal Results Summary Bar (No Clock Icon)
                    if !groups.recent.isEmpty {
                        recentResultsSection(groups.recent)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
            .frame(maxHeight: 340)
        }
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.85)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 18, x: 0, y: -4)
        .accessibilityIdentifier("chat.duet.tasksPanel")
        .sheet(item: $selectedSegment) { segment in
            ChatTaskGroupDetailSheet(
                segment: segment,
                onSelectTool: { tool in
                    selectedSegment = nil
                    onDismissPanel?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        onSelectTool(tool)
                    }
                }
            )
        }
    }

    private func needsAttentionCard(_ item: AmberUnifiedTaskItem) -> some View {
        Button {
            if let seg = item.underlyingSegment {
                selectedSegment = seg
            } else {
                onFollowupTask?(item)
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(item.statusBadgeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.accentRed)
                }

                HStack(alignment: .center) {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.accentRed.opacity(0.9))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if let actionTitle = item.actionTitle {
                        Button {
                            if let onFollowupTask {
                                onFollowupTask(item)
                            } else if let seg = item.underlyingSegment {
                                selectedSegment = seg
                            }
                        } label: {
                            Text(actionTitle)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4.5)
                                .background(AmberTheme.accentRed, in: Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AmberTheme.accentRed.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AmberTheme.accentRed.opacity(0.28), lineWidth: 0.9)
            }
        }
        .buttonStyle(.plain)
    }

    private func runningTaskCard(_ item: AmberUnifiedTaskItem) -> some View {
        Button {
            if let seg = item.underlyingSegment {
                selectedSegment = seg
            } else if let onFollowupTask {
                onFollowupTask(item)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(AmberTheme.accent)
                            .frame(width: 5, height: 5)
                        Text(item.statusBadgeText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AmberTheme.accent)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(AmberTheme.accent.opacity(0.12), in: Capsule(style: .continuous))

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AmberTheme.muted)
                }

                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AmberTheme.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private func recentResultsSection(_ recentItems: [AmberUnifiedTaskItem]) -> some View {
        let summaryText = AmberUnifiedTaskBuilder.recentSummaryText(recentItems)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isRecentExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("最近结果 · \(recentItems.count) 项")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground2)

                    Spacer(minLength: 6)

                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(1)

                    Text(isRecentExpanded ? "收起" : "展开")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AmberTheme.muted)

                    Image(systemName: isRecentExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(AmberTheme.muted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(AmberTheme.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.duet.tasks.recentSummaryBar")

            if isRecentExpanded {
                ForEach(recentItems.prefix(6)) { item in
                    Button {
                        if let seg = item.underlyingSegment {
                            selectedSegment = seg
                        }
                    } label: {
                        HStack {
                            Text(item.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(AmberTheme.foreground)
                                .lineLimit(1)
                            Spacer()
                            Text(item.statusBadgeText)
                                .font(.caption2)
                                .foregroundStyle(AmberTheme.muted)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(AmberTheme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    onDismissPanel?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        onOpenFullTaskBoard()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(IOSAppLocalization.string("打开完整任务与定时看板", defaultValue: "打开完整任务与定时看板"))
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .padding(.top, 2)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct AmberDuetTaskCenterSheet: View {
    let conversationSegments: [ChatTaskRunSegment]
    let gateway: MacGatewayStore
    var subAgentStore: IOSSubAgentActivityStore = .shared
    var hubStore: AmberHubStore = .shared
    let onOpenFullTaskBoard: () -> Void
    let onSelectTool: (UIMessagePart.Tool) -> Void
    var onFollowupTask: ((AmberUnifiedTaskItem) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AmberDuetTaskCenterCard(
                    conversationSegments: conversationSegments,
                    gateway: gateway,
                    subAgentStore: subAgentStore,
                    hubStore: hubStore,
                    onOpenFullTaskBoard: onOpenFullTaskBoard,
                    onSelectTool: onSelectTool,
                    onFollowupTask: onFollowupTask,
                    onDismissPanel: { dismiss() }
                )
                .padding(12)
                Spacer()
            }
            .background(AmberTheme.background.ignoresSafeArea())
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
}

// MARK: - 03 Argon Hubs Panel Card & Sheet (Iconless Typography + Collapsed Smart Collections)

struct AmberDuetHubsCard: View {
    var hubStore: AmberHubStore = .shared
    let conversationStore: IOSConversationStore
    let conversationSegments: [ChatTaskRunSegment]
    let gateway: MacGatewayStore
    var subAgentStore: IOSSubAgentActivityStore = .shared
    var onSelectHub: ((AmberHubItem) -> Void)? = nil
    var onDismissPanel: (() -> Void)? = nil

    @State private var isSmartCollectionsExpanded: Bool = false
    @State private var isShowingCreateHubForm: Bool = false
    @State private var newHubTitle: String = ""
    @State private var newHubMemoryPolicy: AmberHubMemoryPolicy = .sharedWithGlobal

    private var allActiveTasks: [AmberUnifiedTaskItem] {
        let grouped = AmberUnifiedTaskBuilder.buildTasks(
            conversationSegments: conversationSegments,
            gateway: gateway,
            subAgentStore: subAgentStore,
            hubStore: hubStore
        )
        return grouped.needsAttention + grouped.running
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Drag indicator
            HStack {
                Spacer()
                Capsule()
                    .fill(AmberTheme.border)
                    .frame(width: 36, height: 4)
                Spacer()
            }
            .padding(.top, 8)

            // Header: 中心 + [1 个合集可升级 | +]
            HStack(alignment: .center) {
                Text(IOSAppLocalization.string("中心", defaultValue: "中心"))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AmberTheme.foreground)

                Spacer()

                headerActionCapsule
            }
            .padding(.horizontal, 18)

            if isShowingCreateHubForm {
                createHubInlineForm
                    .padding(.horizontal, 18)
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if hubStore.hubs.isEmpty {
                        Text(IOSAppLocalization.string("尚未创建中心 · 点按右上角 + 可将长期主题归拢为中心", defaultValue: "尚未创建中心 · 点按右上角 + 可将长期主题归拢为中心"))
                            .font(.subheadline)
                            .foregroundStyle(AmberTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(AmberTheme.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
                        // Pure-typography Hub cards (No left category icon boxes)
                        ForEach(hubStore.hubs) { hub in
                            hubRowCard(hub)
                        }
                    }

                    // Collapsed single-line Smart Collections bar
                    smartCollectionsSection
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
            .frame(maxHeight: 340)
        }
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.85)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 18, x: 0, y: -4)
        .accessibilityIdentifier("chat.duet.hubsPanel")
    }

    private var headerActionCapsule: some View {
        let upgradableCount = hubStore.upgradableCollectionCount
        return HStack(spacing: 8) {
            if upgradableCount > 0 {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        isSmartCollectionsExpanded = true
                    }
                } label: {
                    Text("\(upgradableCount) 个合集可升级")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.accent)
                }
                .buttonStyle(.plain)

                Rectangle()
                    .fill(AmberTheme.accent.opacity(0.28))
                    .frame(width: 1, height: 11)
            }

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isShowingCreateHubForm.toggle()
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AmberTheme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.duet.hubs.createButton")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(AmberTheme.accent.opacity(0.10), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(AmberTheme.accent.opacity(0.24), lineWidth: 0.75)
        }
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
        .background(AmberTheme.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func hubRowCard(_ hub: AmberHubItem) -> some View {
        let isCurrent = hubStore.activeHubId == hub.id
        let subtitle = hubStore.subtitle(
            for: hub,
            conversations: conversationStore.summaries,
            activeTasks: allActiveTasks
        )
        return Button {
            hubStore.selectHub(hub.id)
            if let currentConvId = conversationStore.currentConversation?.id.description() {
                hubStore.assignConversation(currentConvId, toHub: hub.id)
            }
            onSelectHub?(hub)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(hub.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                            .lineLimit(1)

                        if isCurrent {
                            Text(IOSAppLocalization.string("当前", defaultValue: "当前"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(AmberTheme.accentGreen)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(AmberTheme.accentGreen.opacity(0.14), in: Capsule(style: .continuous))
                        }

                        if hub.memoryPolicy == .hubIsolated {
                            Text(IOSAppLocalization.string("独立记忆", defaultValue: "独立记忆"))
                                .font(.caption2)
                                .foregroundStyle(AmberTheme.muted)
                        }
                    }

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AmberTheme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(AmberTheme.background.opacity(isCurrent ? 0.95 : 0.75), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(isCurrent ? AmberTheme.accent.opacity(0.55) : AmberTheme.borderSoft, lineWidth: isCurrent ? 1.15 : 0.75)
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
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground2)

                    Spacer(minLength: 6)

                    if let summary = hubStore.smartCollectionsSummaryText {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .lineLimit(1)

                        Text(isSmartCollectionsExpanded ? "收起" : "展开")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AmberTheme.muted)

                        Image(systemName: isSmartCollectionsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(AmberTheme.muted)
                    } else {
                        Text(IOSAppLocalization.string("暂无自动归拢项", defaultValue: "暂无自动归拢项"))
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(AmberTheme.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
                }
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
                    .background(AmberTheme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
            }
        }
    }
}

// MARK: - Secondary Workspace & Session History Drawer Sheet (Top-Left Menu Entry)

struct AmberDuetWorkspaceDrawerSheet: View {
    let conversationStore: IOSConversationStore
    let gateway: MacGatewayStore
    var sharedSettings: IOSSharedSettingsStore? = nil
    let onSelectConversation: (KotlinUuid) -> Void
    let onNewConversation: () -> Void
    let onOpenAllHistory: () -> Void
    let onNavigate: (Route) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingPersonaStudio = false
    @State private var showingMoreSpacesAndThemes = false

    private var currentId: KotlinUuid? {
        conversationStore.currentConversation?.id
    }

    private var recentSummaries: [ConversationSummary] {
        Array(conversationStore.summaries.prefix(5))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    agentPrimaryCard
                    primarySpacesListSection
                    recentHistorySection
                    moreSpacesDisclosureSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .background(AmberTheme.background.ignoresSafeArea())
            .navigationTitle(IOSAppLocalization.string("导航与历史", defaultValue: "导航与历史"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            onNavigate(.search(initialQuery: ""))
                        }
                    } label: {
                        Label(IOSAppLocalization.string("搜索", defaultValue: "搜索"), systemImage: "magnifyingglass")
                            .font(.subheadline)
                    }
                    .foregroundStyle(AmberTheme.foreground)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(IOSAppLocalization.string("返回对话", defaultValue: "返回对话")) {
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                }
            }
            .sheet(isPresented: $showingPersonaStudio) {
                AmberPersonaStudioSheet(
                    sharedSettings: sharedSettings ?? IOSSharedSettingsStore()
                )
            }
        }
    }

    private var agentPrimaryCard: some View {
        HStack(spacing: 12) {
            Button {
                showingPersonaStudio = true
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    AmberAgentPersonaMedallionView(mood: .idle, diameter: 48)
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 17, height: 17)
                        .background(AmberTheme.accent, in: Circle())
                        .overlay { Circle().stroke(AmberTheme.surface, lineWidth: 1.5) }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.duet.openPersonaStudio")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Amber 主对话")
                        .font(.headline)
                        .foregroundStyle(AmberTheme.foreground)
                    Button {
                        showingPersonaStudio = true
                    } label: {
                        Text("定制形象")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AmberTheme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AmberTheme.accent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Text(gateway.connection != nil ? "已连接 \(gateway.connection?.name ?? "云端/Mac") · 支持后台任务" : "点按头像可生成/上传形象与 Agent 参考图")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
            }

            Spacer()

            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    onNewConversation()
                }
            } label: {
                Label(IOSAppLocalization.string("新话题", defaultValue: "新话题"), systemImage: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.accentInk)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(AmberTheme.accent, in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.duet.newTopicButton")
        }
        .padding(14)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.8)
        }
    }

    private var primarySpacesListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(IOSAppLocalization.string("常用功能与设置", defaultValue: "常用功能与设置"))
                .font(.footnote.weight(.medium))
                .foregroundStyle(AmberTheme.muted)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                spaceListRow(title: "小说创作", subtitle: "章节与角色设定", icon: "book.pages", destination: .novelCreation)
                Divider().padding(.leading, 48)
                spaceListRow(title: "长文深读", subtitle: "资料精读与批注", icon: "doc.text.magnifyingglass", destination: .board)
                Divider().padding(.leading, 48)
                spaceListRow(title: "任务看板", subtitle: "后台与云端任务", icon: "checklist", destination: .macTasks)
                Divider().padding(.leading, 48)
                spaceListRow(title: "设置", subtitle: "连接、模型与偏好", icon: "gearshape", destination: .settings)
            }
            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
            }
        }
    }

    private var moreSpacesDisclosureSection: some View {
        let runtime = AmberThemeRuntime.shared
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    showingMoreSpacesAndThemes.toggle()
                }
            } label: {
                HStack {
                    Text(IOSAppLocalization.string("更多工具与主题配色", defaultValue: "更多工具与主题配色"))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(AmberTheme.muted)
                    Spacer()
                    Image(systemName: showingMoreSpacesAndThemes ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AmberTheme.muted)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showingMoreSpacesAndThemes {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AmberArquielThemePresets.all, id: \.id) { preset in
                            let isSelected = preset.matches(runtime: runtime)
                            let swatchHex = (try? AmberThemePackTransfer.parseHex(preset.accentHex)) ?? 0xC96442
                            Button {
                                try? runtime.apply(preset)
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color(hex: swatchHex))
                                        .frame(width: 9, height: 9)
                                    Text(preset.displayName)
                                        .font(.caption.weight(isSelected ? .semibold : .regular))
                                        .foregroundStyle(AmberTheme.foreground)
                                }
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(
                                    isSelected ? AmberTheme.accent.opacity(0.12) : AmberTheme.surface,
                                    in: Capsule(style: .continuous)
                                )
                                .overlay {
                                    Capsule(style: .continuous)
                                        .stroke(isSelected ? AmberTheme.accent : AmberTheme.borderSoft, lineWidth: 0.8)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(spacing: 0) {
                    spaceListRow(title: "议会讨论", subtitle: "多视角推演", icon: "person.2", destination: .council)
                    Divider().padding(.leading, 48)
                    spaceListRow(title: "小应用", subtitle: "生成式交互小工具", icon: "square.stack.3d.up", destination: .miniApps)
                    Divider().padding(.leading, 48)
                    spaceListRow(title: "网页浏览", subtitle: "网页自动化挂载", icon: "globe", destination: .webMount)
                    Divider().padding(.leading, 48)
                    spaceListRow(title: "账号", subtitle: "身份与额度", icon: "person.crop.circle", destination: .account)
                }
                .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
                }
            }
        }
    }

    private func spaceListRow(
        title: String,
        subtitle: String,
        icon: String,
        destination: Route
    ) -> some View {
        Button {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                onNavigate(destination)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(AmberTheme.foreground2)
                    .frame(width: 24)

                Text(IOSAppLocalization.string(title, defaultValue: title))
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)

                Spacer()

                Text(IOSAppLocalization.string(subtitle, defaultValue: subtitle))
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AmberTheme.muted2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.duet.capability.\(title)")
    }

    private var recentHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(IOSAppLocalization.string("历史话题（次级存档）", defaultValue: "历史话题（次级存档）"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted)
                Spacer()
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        onOpenAllHistory()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(IOSAppLocalization.string("管理全部历史", defaultValue: "管理全部历史"))
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.duet.openAllHistory")
            }
            .padding(.horizontal, 4)

            if recentSummaries.isEmpty {
                Text(IOSAppLocalization.string("暂无历史话题记录", defaultValue: "暂无历史话题记录"))
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recentSummaries.enumerated()), id: \.offset) { index, summary in
                        let isCurrent = summary.id == currentId
                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                onSelectConversation(summary.id)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: summary.isPinned ? "pin.fill" : (isCurrent ? "bubble.left.fill" : "clock"))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(isCurrent ? AmberTheme.accent : AmberTheme.muted)
                                    .frame(width: 18)

                                Text(summary.title.isEmpty ? "新对话" : summary.title)
                                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                                    .foregroundStyle(AmberTheme.foreground)
                                    .lineLimit(1)

                                Spacer()

                                if isCurrent {
                                    Text("当前")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(AmberTheme.accent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(AmberTheme.accent.opacity(0.12), in: Capsule())
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < recentSummaries.count - 1 {
                            Divider()
                                .padding(.leading, 42)
                        }
                    }
                }
                .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
                }
            }
        }
    }
}
