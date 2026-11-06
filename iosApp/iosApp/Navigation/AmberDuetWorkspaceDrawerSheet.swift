import Shared
import SwiftUI

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
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
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
