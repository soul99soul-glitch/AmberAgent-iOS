import Shared
import SwiftUI

// MARK: - Duet Bottom Mode Switcher & Secondary Workspace / Task Sheets

enum AmberDuetModeTab: String, CaseIterable, Identifiable {
    case chat
    case tasks
    case workspace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat:
            return IOSAppLocalization.string("对话", defaultValue: "对话")
        case .tasks:
            return IOSAppLocalization.string("任务", defaultValue: "任务")
        case .workspace:
            return IOSAppLocalization.string("空间", defaultValue: "空间")
        }
    }

    var iconName: String {
        switch self {
        case .chat:
            return "bubble.left.and.text.bubble.right.fill"
        case .tasks:
            return "checklist"
        case .workspace:
            return "square.grid.2x2"
        }
    }
}

struct AmberDuetBottomSwitcher: View {
    let activeTaskCount: Int
    let needsAttentionCount: Int
    let onOpenTasks: () -> Void
    let onOpenWorkspace: () -> Void
    var onDelegateCloudTask: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            // Segmented Duet pill: Chat | Tasks | Workspace
            HStack(spacing: 4) {
                modeButton(
                    tab: .chat,
                    isSelected: true,
                    badgeCount: 0,
                    badgeColor: AmberTheme.accent,
                    action: {}
                )

                modeButton(
                    tab: .tasks,
                    isSelected: false,
                    badgeCount: needsAttentionCount > 0 ? needsAttentionCount : activeTaskCount,
                    badgeColor: needsAttentionCount > 0 ? AmberTheme.accentRed : AmberTheme.accent,
                    action: onOpenTasks
                )

                modeButton(
                    tab: .workspace,
                    isSelected: false,
                    badgeCount: 0,
                    badgeColor: AmberTheme.accent,
                    action: onOpenWorkspace
                )
            }
            .padding(3.5)
            .background(AmberTheme.surface.opacity(0.95), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 0.75)
            }

            Spacer(minLength: 4)

            // Quick task delegation trigger (Cloud / Background task)
            if let onDelegateCloudTask {
                Button(action: onDelegateCloudTask) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.right.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AmberTheme.accent)
                        Text(IOSAppLocalization.string("交办任务", defaultValue: "交办任务"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground2)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(AmberTheme.surface.opacity(0.92), in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(AmberTheme.borderSoft, lineWidth: 0.75)
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

    private func modeButton(
        tab: AmberDuetModeTab,
        isSelected: Bool,
        badgeCount: Int,
        badgeColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 11.5, weight: .semibold))

                Text(tab.title)
                    .font(.caption.weight(isSelected ? .semibold : .medium))

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
            .foregroundStyle(isSelected ? AmberTheme.foreground : AmberTheme.muted)
            .padding(.horizontal, 11)
            .padding(.vertical, 5.5)
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

// MARK: - Unified Agent Task Center Sheet (In-Chat + SubAgent + Cloud Self + Mac Gateway)

struct AmberDuetTaskCenterSheet: View {
    let conversationSegments: [ChatTaskRunSegment]
    let gateway: MacGatewayStore
    var subAgentStore: IOSSubAgentActivityStore = .shared
    let onOpenFullTaskBoard: () -> Void
    let onSelectTool: (UIMessagePart.Tool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedSegment: ChatTaskRunSegment?

    private var cloudActivities: [MacGatewayCloudActivityStatus] {
        gateway.cloudAgentActivities.values
            .flatMap(\.activities)
            .sorted { $0.updatedAtMs > $1.updatedAtMs }
    }

    var body: some View {
        NavigationStack {
            List {
                // 1. In-Conversation Tasks (grouped by taskId)
                Section {
                    if conversationSegments.isEmpty {
                        Text(IOSAppLocalization.string("当前对话暂无工具或子任务记录。", defaultValue: "当前对话暂无工具或子任务记录。"))
                            .font(.subheadline)
                            .foregroundStyle(AmberTheme.muted)
                    } else {
                        ForEach(conversationSegments) { segment in
                            Button {
                                selectedSegment = segment
                            } label: {
                                inChatTaskRow(segment)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text(IOSAppLocalization.string("当前对话任务流", defaultValue: "当前对话任务流"))
                } footer: {
                    Text(IOSAppLocalization.string("逐步工具调用已按任务折叠；失败步骤会在此处与主对话中显式标出，点击可排查原因。", defaultValue: "逐步工具调用已按任务折叠；失败步骤会在此处与主对话中显式标出，点击可排查原因。"))
                }

                // 2. Local Background SubAgents
                if !subAgentStore.items.isEmpty {
                    Section(IOSAppLocalization.string("本地并行子代理", defaultValue: "本地并行子代理")) {
                        ForEach(subAgentStore.items) { item in
                            HStack(spacing: 10) {
                                ChatSubAgentPixelAvatar(
                                    identity: item.avatarIdentity,
                                    size: 24,
                                    isRunning: item.status == .running
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(AmberTheme.foreground)
                                    Text(item.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(AmberTheme.muted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                statusTag(for: item.status)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                // 3. Cloud Self Live Agent Activity (/v2/agents/{id}/activity)
                if !cloudActivities.isEmpty {
                    Section(IOSAppLocalization.string("云端 Agent 实时活动", defaultValue: "云端 Agent 实时活动")) {
                        ForEach(cloudActivities.prefix(10)) { activity in
                            HStack(spacing: 10) {
                                Image(systemName: activity.phase.isTerminal ? "checkmark.circle" : "bolt.horizontal.circle.fill")
                                    .foregroundStyle(activity.phase == .failed ? AmberTheme.accentRed : AmberTheme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(activity.label)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(AmberTheme.foreground)
                                    Text(activity.taskId)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(AmberTheme.muted)
                                }
                                Spacer()
                                Text(activity.phase.rawValue)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(AmberTheme.muted)
                            }
                        }
                    }
                }

                // 4. Cloud Native Tasks (/v2/work-items)
                MacGatewayCloudTaskSection(gateway: gateway)

                // 5. Full Mac / Cloud Task Board Link
                Section {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            onOpenFullTaskBoard()
                        }
                    } label: {
                        Label(
                            IOSAppLocalization.string("打开完整任务与定时看板", defaultValue: "打开完整任务与定时看板"),
                            systemImage: "rectangle.3.group"
                        )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AmberTheme.accent)
                    }
                }
            }
            .navigationTitle(IOSAppLocalization.string("任务中心", defaultValue: "任务中心"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(IOSAppLocalization.string("完成", defaultValue: "完成")) {
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                }
            }
            .task {
                if gateway.connection != nil {
                    await gateway.refreshCloudAgents()
                    await gateway.refreshActiveCloudTasks()
                }
            }
            .sheet(item: $selectedSegment) { segment in
                ChatTaskGroupDetailSheet(
                    segment: segment,
                    onSelectTool: { tool in
                        selectedSegment = nil
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            onSelectTool(tool)
                        }
                    }
                )
            }
        }
    }

    private func inChatTaskRow(_ segment: ChatTaskRunSegment) -> some View {
        let rollup = segment.rollupState
        return HStack(spacing: 10) {
            Image(systemName: rollup.iconSystemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(rollup.tintColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(segment.headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .lineLimit(1)

                    Spacer()

                    Text(rollup.statusBadgeText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(rollup.tintColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(rollup.tintColor.opacity(0.12), in: Capsule())
                }

                if let subtitle = segment.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(rollup.isFailureOrNeedsUser ? rollup.tintColor : AmberTheme.muted)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func statusTag(for status: IOSSubAgentActivityStatus) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .running: return ("运行中", AmberTheme.accent)
            case .completed: return ("已完成", AmberTheme.accentGreen)
            case .failed: return ("失败", AmberTheme.accentRed)
            case .cancelled: return ("已取消", AmberTheme.muted)
            }
        }()
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Secondary Workspace & Session History Drawer Sheet

struct AmberDuetWorkspaceDrawerSheet: View {
    let conversationStore: IOSConversationStore
    let gateway: MacGatewayStore
    var sharedSettings: IOSSharedSettingsStore? = nil
    let onSelectConversation: (KotlinUuid) -> Void
    let onNewConversation: () -> Void
    let onOpenAllHistory: () -> Void
    let onNavigate: (RouterDestination) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingPersonaStudio = false

    private var currentId: KotlinUuid? {
        conversationStore.currentConversation?.id
    }

    private var recentSummaries: [ConversationSummary] {
        Array(conversationStore.summaries.prefix(8))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    agentPrimaryCard
                    arquielPaletteStripSection
                    capabilityGridSection
                    recentHistorySection
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .background(AmberTheme.background.ignoresSafeArea())
            .navigationTitle(IOSAppLocalization.string("Amber 空间与历史", defaultValue: "Amber 空间与历史"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            onNavigate(.search)
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

    private var arquielPaletteStripSection: some View {
        let runtime = AmberThemeRuntime.shared
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(IOSAppLocalization.string("主题配色 (Arquiel Design)", defaultValue: "主题配色 (Arquiel Design)"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted)
                Spacer()
            }
            .padding(.horizontal, 4)

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
                                    .frame(width: 10, height: 10)
                                Text(preset.displayName)
                                    .font(.caption.weight(isSelected ? .semibold : .medium))
                                    .foregroundStyle(AmberTheme.foreground)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(
                                isSelected ? AmberTheme.accent.opacity(0.14) : AmberTheme.surface,
                                in: Capsule(style: .continuous)
                            )
                            .overlay {
                                Capsule(style: .continuous)
                                    .stroke(isSelected ? AmberTheme.accent : AmberTheme.borderSoft, lineWidth: isSelected ? 1.1 : 0.7)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var capabilityGridSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(IOSAppLocalization.string("创作与能力空间", defaultValue: "创作与能力空间"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AmberTheme.muted)
                .padding(.horizontal, 4)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ],
                spacing: 10
            ) {
                capabilityTile(title: "小说创作", subtitle: "章节推进与设定", icon: "book.pages.fill", destination: .novelCreation)
                capabilityTile(title: "长文深读", subtitle: "精读批注与拆解", icon: "doc.text.magnifyingglass", destination: .board)
                capabilityTile(title: "议会讨论", subtitle: "多视角交叉推演", icon: "person.3.fill", destination: .council)
                capabilityTile(title: "小应用", subtitle: "可交互生成工具", icon: "sparkles.rectangle.stack.fill", destination: .miniApps)
                capabilityTile(title: "Web 挂载", subtitle: "网页自动化浏览", icon: "globe", destination: .webMount)
                capabilityTile(title: "任务看板", subtitle: "云端与 Mac 协同", icon: "checklist", destination: .macTasks)
                capabilityTile(title: "设置", subtitle: "连接、模型与偏好", icon: "gearshape.fill", destination: .settings)
                capabilityTile(title: "账号", subtitle: "身份与额度管理", icon: "person.crop.circle", destination: .account)
            }
        }
    }

    private func capabilityTile(
        title: String,
        subtitle: String,
        icon: String,
        destination: RouterDestination
    ) -> some View {
        Button {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                onNavigate(destination)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .frame(width: 30, height: 30)
                    .background(AmberTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(IOSAppLocalization.string(title, defaultValue: title))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .lineLimit(1)
                    Text(IOSAppLocalization.string(subtitle, defaultValue: subtitle))
                        .font(.caption2)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(11)
            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
            }
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
