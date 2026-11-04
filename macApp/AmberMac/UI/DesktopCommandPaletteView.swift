import SwiftUI

// MARK: - Obsidian-style ⌘K Command Palette

struct DesktopCommandPaletteView: View {
    @Bindable var workspace: DesktopWorkspace
    var onDismiss: () -> Void
    var onFocusComposer: () -> Void = {}
    var onOpenAgentSoul: () -> Void = {}

    struct PaletteItem: Identifiable {
        let id: String
        let category: String
        let title: String
        let subtitle: String
        let badge: String?
        let symbol: String
        let action: () -> Void
    }

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private var items: [PaletteItem] {
        var all: [PaletteItem] = []

        for cmd in workspace.plugins.activeSlashCommands {
            all.append(PaletteItem(
                id: "cmd.\(cmd.id)",
                category: "插件指令",
                title: cmd.title,
                subtitle: cmd.pluginName,
                badge: cmd.slash,
                symbol: cmd.symbol
            ) {
                workspace.openChatSurface()
                workspace.draft = cmd.promptTemplate
                workspace.agentTasks.toolsEnabled = true
                onDismiss()
                onFocusComposer()
            })
        }

        for view in workspace.plugins.activeWorkspaceViews {
            all.append(PaletteItem(
                id: "view.\(view.id)",
                category: "工作区视图",
                title: "打开\(view.title)视图",
                subtitle: view.subtitle,
                badge: view.badgeCount > 0 ? "\(view.badgeCount) 项" : nil,
                symbol: view.symbol
            ) {
                workspace.openPluginView(pluginID: view.pluginID, viewID: view.viewID)
                onDismiss()
            })
        }

        if workspace.activeSurface != .chat {
            all.append(PaletteItem(
                id: "nav.chat",
                category: "工作区视图",
                title: "返回当前对话",
                subtitle: workspace.selectedConversationTitle,
                badge: nil,
                symbol: "bubble.left.and.bubble.right"
            ) {
                workspace.openChatSurface()
                onDismiss()
            })
        }

        if workspace.scheduler != nil && workspace.plugins.isCoreEnabled(.taskBoard) {
            all.append(PaletteItem(
                id: "nav.task_board",
                category: "工作区视图",
                title: "打开任务看板",
                subtitle: "查看定时任务与 Claude Code / Codex 会话",
                badge: nil,
                symbol: "clock"
            ) {
                workspace.showsTaskBoard = true
                onDismiss()
            })
        }

        all.append(PaletteItem(
            id: "act.agent_soul",
            category: "智能体设定",
            title: "形象人设",
            subtitle: workspace.agentSoul.isDefault ? "默认 Amber · 查看或自定义全端共享人设" : "当前：\(workspace.agentSoul.displayName) · v\(workspace.agentSoul.revision)",
            badge: nil,
            symbol: "person.crop.circle.badge.sparkles"
        ) {
            onDismiss()
            onOpenAgentSoul()
        })

        all.append(PaletteItem(
            id: "act.new_chat",
            category: "会话动作",
            title: "新建对话",
            subtitle: "创建一条空白会话并聚焦输入框",
            badge: "⌘N",
            symbol: "square.and.pencil"
        ) {
            workspace.createConversation()
            onDismiss()
            onFocusComposer()
        })

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { item in
            item.title.lowercased().contains(q)
                || item.subtitle.lowercased().contains(q)
                || (item.badge?.lowercased().contains(q) ?? false)
                || item.category.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesktopTheme.accent)
                TextField("输入插件命令、斜杠指令（如 /feishu-today）或视图名称…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(DesktopTheme.ink)
                    .focused($searchFocused)
                    .onSubmit {
                        let list = items
                        if list.indices.contains(selectedIndex) {
                            list[selectedIndex].action()
                        }
                    }
                Button {
                    onDismiss()
                } label: {
                    Text("ESC")
                        .font(.system(size: 10.5, design: .monospaced).weight(.medium))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("关闭命令面板")
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(DesktopTheme.card)

            Rectangle().fill(DesktopTheme.hairline).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    let list = items
                    if list.isEmpty {
                        Text("没有匹配的插件命令或视图")
                            .font(.system(size: 13))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 36)
                    } else {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                            Button {
                                item.action()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.symbol)
                                        .font(.system(size: 13))
                                        .foregroundStyle(index == selectedIndex ? DesktopTheme.accent : DesktopTheme.inkSecondary)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(item.title)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(DesktopTheme.ink)
                                            Text(item.category)
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(DesktopTheme.inkTertiary)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(DesktopTheme.paperDeep, in: Capsule())
                                        }
                                        if !item.subtitle.isEmpty {
                                            Text(item.subtitle)
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(DesktopTheme.inkTertiary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if let badge = item.badge {
                                        Text(badge)
                                            .font(.system(size: 11.5, design: .monospaced).weight(.medium))
                                            .foregroundStyle(DesktopTheme.accent)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 5))
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background {
                                    if index == selectedIndex {
                                        DesktopTheme.glow(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(10)
            }
            Rectangle().fill(DesktopTheme.hairline).frame(height: 1)
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    Text("↑↓")
                        .font(.system(size: 10.5, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 4.5).padding(.vertical, 1)
                        .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DesktopTheme.hairline))
                    Text("选择")
                }
                HStack(spacing: 4) {
                    Text("↩")
                        .font(.system(size: 10.5, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 4.5).padding(.vertical, 1)
                        .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DesktopTheme.hairline))
                    Text("执行指令或切换视图")
                }
                Spacer()
                Text("Amber Command Palette")
                    .font(.system(size: 11, design: .monospaced))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(DesktopTheme.inkTertiary)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(DesktopTheme.paperSide)
        }
        .frame(width: 540, height: 520)
        .background(DesktopTheme.paper)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onKeyPress(.upArrow) {
            let count = items.count
            guard count > 0 else { return .ignored }
            selectedIndex = (selectedIndex - 1 + count) % count
            return .handled
        }
        .onKeyPress(.downArrow) {
            let count = items.count
            guard count > 0 else { return .ignored }
            selectedIndex = (selectedIndex + 1) % count
            return .handled
        }
        .onKeyPress(.return) {
            let list = items
            guard list.indices.contains(selectedIndex) else { return .ignored }
            list[selectedIndex].action()
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }
}
