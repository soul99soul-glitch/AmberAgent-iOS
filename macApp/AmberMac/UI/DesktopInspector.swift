import SwiftUI

/// Right-hand inspector for wide windows: context, pinned artifacts, files and tool tasks stay visible beside the
/// conversation instead of hiding behind toolbar popovers. Narrow windows keep the popovers.
struct DesktopInspector: View {
    @Bindable var workspace: DesktopWorkspace
    let onLocate: (UUID) -> Void
    let onOpenFiles: () -> Void
    let onOpenTasks: () -> Void
    var onFocusComposer: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    @AppStorage("desktop.inspector.collapsed") private var collapsedRaw = ""
    @State private var expandedEmptyShelf = false

    private enum Section: String, CaseIterable { case context, shelf, files, tasks }

    private var conversation: DesktopConversation? { workspace.selectedConversation }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Module 1: Live Plugin Agenda Islands (e.g. 今日飞书日程)
                    ForEach(workspace.plugins.inspectorSnapshots) { snapshot in
                        floatingIsland {
                            sectionBlock(
                                "plugin.\(snapshot.id)",
                                title: snapshot.title,
                                glyph: .calendar,
                                tone: .terracotta,
                                badge: snapshot.statusBadge
                            ) {
                                pluginCardContent(snapshot)
                            }
                        }
                    }

                    // Module 2: Conversation Context & Intelligence Island
                    floatingIsland {
                        sectionBlock(
                            Section.context.rawValue,
                            title: "上下文",
                            glyph: .contextStack,
                            tone: .amber,
                            badge: contextBadge.map { "约 \($0) tok" }
                        ) {
                            DesktopConversationInsightsView(workspace: workspace, embedded: true)
                        }
                    }

                    // Module 3: Session Artifacts, Files & Tool Tasks Dock Island
                    floatingIsland {
                        VStack(alignment: .leading, spacing: 0) {
                            if hasShelfContent || expandedEmptyShelf {
                                sectionBlock(
                                    Section.shelf.rawValue,
                                    title: "产物架",
                                    glyph: .pinTack,
                                    tone: .amber,
                                    badge: shelfCount.map(String.init)
                                ) {
                                    DesktopArtifactShelfView(workspace: workspace, embedded: true, onLocate: onLocate)
                                }
                            } else {
                                quietSingleRow(
                                    glyph: .pinTack,
                                    tone: .stone,
                                    title: "产物架",
                                    trailingText: "未固定",
                                    action: { withAnimation(.smooth(duration: 0.24)) { expandedEmptyShelf = true } }
                                )
                            }

                            sectionDivider

                            if hasFilesContent {
                                sectionBlock(
                                    Section.files.rawValue,
                                    title: "会话文件",
                                    glyph: .folderArchive,
                                    tone: .terracotta,
                                    badge: workspace.selectedFiles.isEmpty ? nil : "\(workspace.selectedFiles.count)"
                                ) {
                                    files
                                }
                            } else {
                                quietSingleRow(
                                    glyph: .folderArchive,
                                    tone: .stone,
                                    title: "会话文件",
                                    trailingText: "管理",
                                    showsArrow: true,
                                    action: onOpenFiles
                                )
                            }

                            sectionDivider

                            if hasTasksContent {
                                sectionBlock(
                                    Section.tasks.rawValue,
                                    title: "工具任务",
                                    glyph: .terminalTask,
                                    tone: .jade,
                                    badge: pendingApprovals > 0 ? "\(pendingApprovals) 待批准" : (ownerTasks.isEmpty ? nil : "\(ownerTasks.count)")
                                ) {
                                    tasks
                                }
                            } else {
                                quietSingleRow(
                                    glyph: .terminalTask,
                                    tone: .stone,
                                    title: "工具任务",
                                    trailingText: "工作台",
                                    showsArrow: true,
                                    action: onOpenTasks
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.top, 16)
                .padding(.trailing, 20)
                .padding(.leading, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func floatingIsland<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .desktopGlass(cornerRadius: 18)
    }

    private var hasShelfContent: Bool {
        shelfCount != nil || workspace.artifactShelf.errorMessage != nil
    }

    private var hasFilesContent: Bool {
        !workspace.selectedFiles.isEmpty || workspace.isLoadingFiles || workspace.fileErrorMessage != nil
    }

    private var hasTasksContent: Bool {
        !ownerTasks.isEmpty || workspace.agentTasks.errorMessage != nil
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(DesktopTheme.hairline)
            .frame(height: 1)
            .padding(.horizontal, 20)
    }

    private func quietSingleRow(
        glyph: DesktopCraftGlyph,
        tone: DesktopCraftTone,
        title: String,
        trailingText: String,
        showsArrow: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                DesktopCraftIcon(glyph: glyph, tone: tone, size: 22)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    Text(trailingText)
                        .font(.system(size: 12))
                    if showsArrow {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                }
                .foregroundStyle(DesktopTheme.inkTertiary)
            }
            .padding(.horizontal, 20)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Cards

    private func isCollapsed(_ key: String) -> Bool { collapsedRaw.split(separator: ",").contains(Substring(key)) }

    private func toggle(_ key: String) {
        var set = Set(collapsedRaw.split(separator: ",").map(String.init))
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        withAnimation(.smooth(duration: 0.28)) { collapsedRaw = set.sorted().joined(separator: ",") }
    }

    private func sectionBlock<Content: View>(_ key: String, title: String, glyph: DesktopCraftGlyph, tone: DesktopCraftTone, badge: String?,
        @ViewBuilder content: () -> Content) -> some View {
        let collapsed = isCollapsed(key)
        return VStack(alignment: .leading, spacing: 0) {
            Button { toggle(key) } label: {
                HStack(spacing: 10) {
                    DesktopCraftIcon(glyph: glyph, tone: tone, size: 22)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesktopTheme.ink)
                    Spacer(minLength: 4)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                            .contentTransition(.numericText())
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(DesktopTheme.inkTertiary.opacity(0.75))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, collapsed ? 16 : 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "展开\(title)" : "收起\(title)")
            content()
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
                .frame(maxHeight: collapsed ? 0 : nil, alignment: .top)
                .opacity(collapsed ? 0 : 1)
                .clipped()
                .disabled(collapsed)
                .accessibilityHidden(collapsed)
        }
    }

    // MARK: Badges

    private var contextBadge: String? {
        guard let conversation else { return nil }
        let prepared = workspace.insights.prepare(messages: conversation.messages, conversationID: conversation.id)
        let extraText = workspace.settings.systemPrompt + workspace.draft
            + workspace.pendingAttachments.map(\.text).joined()
        let tokens = DesktopConversationInsights.estimatedTokens(prepared, extraText: extraText)
        return tokens >= 1_000 ? String(format: "%.1fk", Double(tokens) / 1_000) : "\(tokens)"
    }

    private var shelfCount: Int? {
        guard let conversation else { return nil }
        let count = workspace.artifactShelf.pins(for: conversation.id).count
        return count == 0 ? nil : count
    }

    private var ownerTasks: [DesktopAgentTask] {
        workspace.agentTasks.records.filter { $0.conversationID == workspace.selectedID }
    }

    private var pendingApprovals: Int { ownerTasks.filter { $0.approval != nil }.count }

    // MARK: Files & tasks

    private var files: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = workspace.fileErrorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开会话文件…", action: onOpenFiles)
                    .buttonStyle(.desktopActionPill)
            } else if workspace.isLoadingFiles {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("正在读取文件…").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                }
            } else if workspace.selectedFiles.isEmpty {
                HStack(spacing: 8) {
                    Text("尚无工具写入或导入文件").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    Spacer(minLength: 4)
                    Button("管理文件…", action: onOpenFiles)
                        .buttonStyle(.desktopActionPill)
                }
            } else {
                ForEach(workspace.selectedFiles.prefix(8)) { file in
                    Button(action: onOpenFiles) {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(DesktopTheme.accent)
                            Text(file.id).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkSecondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                                .font(.system(size: 11).monospacedDigit()).foregroundStyle(DesktopTheme.inkTertiary)
                        }
                        .padding(.horizontal, 6).frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(DesktopQuietButtonStyle())
                }
                Button("打开会话文件…", action: onOpenFiles)
                    .buttonStyle(.desktopActionPill)
                    .padding(.top, 2)
            }
        }
    }

    private var tasks: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = workspace.agentTasks.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            } else if ownerTasks.isEmpty {
                HStack(spacing: 8) {
                    Text("尚无工具调用记录").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("任务工作台…", action: onOpenTasks)
                        .buttonStyle(.desktopActionPill)
                }
            } else {
                ForEach(ownerTasks.prefix(6)) { task in
                    Button(action: onOpenTasks) {
                        HStack(spacing: 8) {
                            if task.approval != nil || task.status == .running { DesktopPulse() }
                            else { Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "circle").font(.system(size: 10.5)).foregroundStyle(task.status == .completed ? DesktopTheme.success : DesktopTheme.inkTertiary) }
                            Text(task.title).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkSecondary).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(task.transactions.count) 次").font(.system(size: 11).monospacedDigit()).foregroundStyle(DesktopTheme.inkTertiary)
                        }
                        .padding(.horizontal, 6).frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(DesktopQuietButtonStyle())
                }
                Button("打开任务工作台…", action: onOpenTasks)
                    .buttonStyle(.desktopActionPill)
                    .padding(.top, 2)
            }
        }
    }

    private func pluginCardContent(_ snapshot: DesktopInspectorCardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if snapshot.items.isEmpty {
                Text(snapshot.emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(snapshot.items.prefix(5)) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DesktopTheme.ink)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if let actionTitle = item.actionTitle, let prompt = item.prompt {
                                Button {
                                    workspace.openChatSurface()
                                    workspace.draft = prompt
                                    workspace.agentTasks.toolsEnabled = true
                                    onFocusComposer()
                                } label: {
                                    HStack(spacing: 2) {
                                        Text(actionTitle)
                                        Image(systemName: "arrow.down.left")
                                            .font(.system(size: 9, weight: .semibold))
                                    }
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(DesktopTheme.accentInk)
                                }
                                .buttonStyle(.plain)
                                .help("将此日程带入对话输入框")
                            }
                        }
                        HStack(alignment: .center, spacing: 6) {
                            if !item.badge.isEmpty {
                                Text(item.badge)
                                    .font(.system(size: 11.5, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(DesktopTheme.accent)
                            }
                            if let subtitle = item.subtitle, !subtitle.isEmpty {
                                DesktopCraftIcon(
                                    glyph: subtitle.contains("视频") ? .videoCamera : .meetingRoom,
                                    tone: subtitle.contains("视频") ? .jade : .terracotta,
                                    size: 13,
                                    boxed: false
                                )
                                Text(subtitle)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(DesktopTheme.inkTertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            if let footer = snapshot.footerActionTitle, let viewID = snapshot.opensWorkspaceViewID {
                Button {
                    workspace.openPluginView(pluginID: snapshot.pluginID, viewID: viewID)
                } label: {
                    HStack(spacing: 4) {
                        Text(footer)
                        Image(systemName: "arrow.up.right").font(.system(size: 9.5, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }
}

/// Compact popover for plugin inspector cards when the window is narrow (`!inspectorDocked`).
struct DesktopPluginInspectorPopoverView: View {
    @Bindable var workspace: DesktopWorkspace
    var onFocusComposer: () -> Void = {}
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(workspace.plugins.inspectorSnapshots) { snapshot in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: snapshot.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DesktopTheme.accent)
                        Text(snapshot.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DesktopTheme.ink)
                        Spacer()
                        if let badge = snapshot.statusBadge {
                            Text(badge)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(DesktopTheme.inkTertiary)
                        }
                    }
                    if snapshot.items.isEmpty {
                        Text(snapshot.emptyMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                    } else {
                        ForEach(snapshot.items) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .center, spacing: 6) {
                                    Text(item.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(DesktopTheme.ink)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if let actionTitle = item.actionTitle, let prompt = item.prompt {
                                        Button(actionTitle) {
                                            workspace.openChatSurface()
                                            workspace.draft = prompt
                                            workspace.agentTasks.toolsEnabled = true
                                            onFocusComposer()
                                            onDismiss()
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(DesktopTheme.accent)
                                    }
                                }
                                HStack(alignment: .center, spacing: 6) {
                                    if !item.badge.isEmpty {
                                        Text(item.badge)
                                            .font(.system(size: 10.5, design: .monospaced).weight(.medium))
                                            .foregroundStyle(DesktopTheme.accent)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1.5)
                                            .background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 4))
                                    }
                                    if let sub = item.subtitle, !sub.isEmpty {
                                        Text(sub)
                                            .font(.system(size: 11))
                                            .foregroundStyle(DesktopTheme.inkTertiary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    if let footer = snapshot.footerActionTitle, let viewID = snapshot.opensWorkspaceViewID {
                        Button(footer) {
                            workspace.openPluginView(pluginID: snapshot.pluginID, viewID: viewID)
                            onDismiss()
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                        .foregroundStyle(DesktopTheme.accent)
                        .padding(.top, 2)
                    }
                }
                .padding(12)
                .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.hairline))
            }
        }
        .padding(14)
        .frame(width: 340)
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(DesktopTheme.paper)
    }
}
