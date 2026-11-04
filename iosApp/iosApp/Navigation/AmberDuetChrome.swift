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
    let activeTaskCount: Int
    let needsAttentionCount: Int
    var gateway: MacGatewayStore = .shared
    var onSelectTab: ((AmberDuetModeTab) -> Void)? = nil
    let onOpenTasks: () -> Void
    let onOpenWorkspace: () -> Void
    var onSelectHost: ((Bool) -> Void)? = nil
    var onOpenCloudPairingSettings: (() -> Void)? = nil

    private var badgeCount: Int {
        needsAttentionCount + activeTaskCount
    }

    private var badgeColor: Color {
        needsAttentionCount > 0 ? AmberTheme.accentRed : AmberTheme.accent
    }

    var body: some View {
        HStack(spacing: 8) {
            // Left (3): Pure-typography segmented pill (对话 | 任务 [N] | 中心)
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
            .modifier(DuetBottomCapsuleGlass(isHighlighted: false))

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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.duet.bottomSwitcher")
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
            .foregroundStyle(isSelected ? AmberTheme.foreground : AmberTheme.muted)
            .padding(.horizontal, tab == .tasks ? 13 : 14)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(AmberTheme.surfaceElevated)
                        .shadow(color: Color.black.opacity(0.06), radius: 2.5, x: 0, y: 1)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.duet.tab.\(tab.rawValue)")
    }
}

struct DuetBottomCapsuleGlass: ViewModifier {
    var isHighlighted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = Capsule(style: .continuous)
        if #available(iOS 26.0, *) {
            content
                .background(AmberTheme.glass.opacity(0.16), in: shape)
                .glassEffect(.regular, in: shape)
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
        VStack(alignment: .leading, spacing: 18) {
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

                // Header: 任务 + 全部中心 ⌄
                HStack(alignment: .center) {
                    Text(IOSAppLocalization.string("任务", defaultValue: "任务"))
                        .font(.system(size: 20, weight: .bold))
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
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5.5)
                        .background(AmberTheme.surface, in: Capsule(style: .continuous))
                    }
                    .accessibilityIdentifier("chat.duet.tasks.hubFilter")
                }
            }
            .padding(.horizontal, 20)

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
                        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                // 3. Collapsed Recent Terminal Results Summary Bar (No Clock Icon)
                if !groups.recent.isEmpty {
                    recentResultsSection(groups.recent)
                }
            }
            .padding(.horizontal, 20)
        }
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
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(item.statusBadgeText)
                        .font(.system(size: 11.2, weight: .semibold))
                        .foregroundStyle(AmberTheme.accentRed)
                }

                HStack(alignment: .center) {
                    Text(item.subtitle)
                        .font(.system(size: 12.2))
                        .foregroundStyle(AmberTheme.muted)
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
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(AmberTheme.accentRed, in: Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(AmberTheme.accentRed.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AmberTheme.accentRed.opacity(0.24), lineWidth: 0.85)
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
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 13.8, weight: .semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .lineLimit(1)

                    Text(item.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 4.5) {
                    Circle()
                        .fill(AmberTheme.accent)
                        .frame(width: 5, height: 5)
                    Text(item.statusBadgeText)
                        .font(.system(size: 11.2, weight: .medium))
                        .foregroundStyle(AmberTheme.accent)
                }
                .padding(.horizontal, 8.5)
                .padding(.vertical, 3.5)
                .background(AmberTheme.accent.opacity(0.09), in: Capsule(style: .continuous))

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AmberTheme.muted2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AmberTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(AmberTheme.border, lineWidth: 0.75)
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
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AmberTheme.foreground2)

                    Text(summaryText)
                        .font(.system(size: 12))
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    Text(isRecentExpanded ? "收起" : "展开")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AmberTheme.muted)

                    Image(systemName: isRecentExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(AmberTheme.muted2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        VStack(alignment: .leading, spacing: 18) {
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

            if isShowingCreateHubForm {
                createHubInlineForm
                    .padding(.horizontal, 20)
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
                    // Pure-typography Hub cards (No left category icon boxes)
                    ForEach(hubStore.hubs) { hub in
                        hubRowCard(hub)
                    }
                }

                // Collapsed single-line Smart Collections bar
                smartCollectionsSection
            }
            .padding(.horizontal, 20)
        }
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
