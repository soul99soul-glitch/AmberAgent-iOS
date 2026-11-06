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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("desktop.inspector.collapsed") private var collapsedRaw = ""
    @State private var collapsedKeys = Set((UserDefaults.standard.string(forKey: "desktop.inspector.collapsed") ?? "")
        .split(separator: ",").map(String.init))
    @State private var expandedEmptyShelf = false
    @State private var pluginViewWidths: [String: CGFloat] = [:]
    @Namespace private var pluginMorph

    private enum Section: String, CaseIterable { case context, shelf, files, tasks }

    private var conversation: DesktopConversation? { workspace.selectedConversation }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Module 1: Live Plugin Agenda Islands (e.g. 今日飞书日程)
                    ForEach(workspace.plugins.inspectorSnapshots) { snapshot in
                        pluginSnapshotIsland(snapshot)
                    }

                    // Module 1b: Custom WebView Inspector / Right Sidebar Views (amber.plugin.v3)
                    ForEach(workspace.plugins.activeCustomViews.filter { $0.slot == .inspector || $0.slot == .rightSidebar }) { customView in
                        if let compactHeight = customView.compactHeight {
                            let key = "plugin.webview.\(customView.id)"
                            let collapsed = isCollapsed(key)
                            floatingIsland {
                                DesktopPluginWebView(
                                    store: workspace.plugins,
                                    pluginID: customView.pluginID,
                                    viewID: customView.viewID,
                                    entryPath: customView.entryPath,
                                    reloadRevision: workspace.plugins.pluginReloadRevisions[customView.pluginID] ?? 0,
                                    isDark: scheme == .dark,
                                    isCompact: collapsed
                                )
                                .frame(maxWidth: .infinity)
                                .frame(height: collapsed ? CGFloat(compactHeight) :
                                    (pluginViewWidths[customView.id] ?? 280) / CGFloat(customView.aspectRatio ?? 1))
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                                    if width > 0, pluginViewWidths[customView.id] != width {
                                        pluginViewWidths[customView.id] = width
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                                .overlay(alignment: .leading) {
                                    if collapsed {
                                        HStack(spacing: 0) {
                                            Button { toggle(key, animation: reduceMotion ? nil : .easeInOut(duration: 0.24)) } label: {
                                                Color.clear.contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel("展开\(customView.title)")
                                            Color.clear.frame(width: 52).allowsHitTesting(false)
                                        }
                                    }
                                }
                                .overlay(alignment: .topTrailing) {
                                    if !collapsed {
                                        Button { toggle(key, animation: reduceMotion ? nil : .easeInOut(duration: 0.24)) } label: {
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(DesktopTheme.inkTertiary)
                                                .frame(width: 36, height: 36)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("收起\(customView.title)")
                                    }
                                }
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: collapsed)
                                .transaction { if reduceMotion { $0.animation = nil } }
                            }
                        } else {
                            legacyPluginIsland(customView)
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
                .animation(.spring(response: 0.32, dampingFraction: 0.85), value: expandedEmptyShelf)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: collapsedRaw, initial: true) { _, value in
            let stored = Set(value.split(separator: ",").map(String.init))
            if stored != collapsedKeys {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                    collapsedKeys = stored
                }
            }
        }
    }

    private func floatingIsland<Content: View>(cornerRadius: CGFloat = 18, @ViewBuilder content: () -> Content) -> some View {
        content()
            .desktopGlass(cornerRadius: cornerRadius)
    }

    private func pluginSnapshotIsland(_ snapshot: DesktopInspectorCardSnapshot) -> some View {
        let key = "plugin.\(snapshot.id)"
        let widthKey = "snapshot.\(snapshot.id)"
        let collapsed = isCollapsed(key)
        let first = snapshot.items.first
        let detail = first.map { [$0.badge, $0.subtitle ?? ""].filter { !$0.isEmpty }.joined(separator: " · ") }
        let emptyDetail = snapshot.emptyMessage.isEmpty ? (snapshot.statusBadge ?? "已启用") : snapshot.emptyMessage
        return floatingIsland {
            Group {
                if collapsed {
                    compactPluginRow(
                        symbol: snapshot.symbol,
                        title: first?.title ?? snapshot.title,
                        detail: (detail?.isEmpty == false ? detail : nil) ?? (first == nil ? emptyDetail : snapshot.statusBadge ?? "已启用"),
                        morphID: key,
                        expand: { toggle(key, animation: reduceMotion ? nil : .easeInOut(duration: 0.24)) },
                        open: {
                            if let viewID = snapshot.opensWorkspaceViewID {
                                workspace.openPluginView(pluginID: snapshot.pluginID, viewID: viewID)
                            } else {
                                toggle(key, animation: reduceMotion ? nil : .easeInOut(duration: 0.24))
                            }
                        }
                    )
                    .transition(reduceMotion ? .opacity.animation(.easeInOut(duration: 0.1)) : .opacity)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        pluginIslandHeader(title: snapshot.title, symbol: snapshot.symbol, badge: snapshot.statusBadge, morphID: key) {
                            toggle(key, animation: reduceMotion ? nil : .easeInOut(duration: 0.24))
                        }
                        ScrollView {
                            pluginCardContent(snapshot)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 16)
                        }
                        .scrollIndicators(.automatic)
                    }
                    .transition(reduceMotion ? .opacity.animation(.easeInOut(duration: 0.1)) : .opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: collapsed ? 60 : (pluginViewWidths[widthKey] ?? 280))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if width > 0, pluginViewWidths[widthKey] != width { pluginViewWidths[widthKey] = width }
            }
            .transaction { if reduceMotion { $0.animation = nil } }
        }
    }

    private func legacyPluginIsland(_ view: DesktopPluginCustomViewEntry) -> some View {
        let key = "plugin.webview.\(view.id)"
        let collapsed = isCollapsed(key)
        let height = (pluginViewWidths[view.id] ?? 280) / CGFloat(view.aspectRatio ?? 1)
        return floatingIsland {
            VStack(spacing: 0) {
                if !collapsed {
                    pluginIslandHeader(title: view.title, symbol: view.symbol, badge: nil, morphID: key) {
                        toggle(key, animation: reduceMotion ? nil : .easeInOut(duration: 0.24))
                    }
                    .transition(reduceMotion ? .opacity.animation(.easeInOut(duration: 0.1)) : .opacity)
                }
                // The view stays mounted at zero height so the plugin document and its state survive collapse.
                DesktopPluginWebView(
                    store: workspace.plugins,
                    pluginID: view.pluginID,
                    viewID: view.viewID,
                    entryPath: view.entryPath,
                    reloadRevision: workspace.plugins.pluginReloadRevisions[view.pluginID] ?? 0,
                    isDark: scheme == .dark
                )
                .frame(maxWidth: .infinity)
                .frame(height: collapsed ? 0 : max(0, height - 48))
                .clipped()
                .opacity(collapsed ? 0 : 1)
                .allowsHitTesting(!collapsed)
                .accessibilityHidden(collapsed)
                if collapsed {
                    compactPluginRow(
                        symbol: view.symbol,
                        title: view.title,
                        detail: "已启用",
                        morphID: key,
                        expand: { toggle(key, animation: reduceMotion ? nil : .easeInOut(duration: 0.24)) },
                        open: { toggle(key, animation: reduceMotion ? nil : .easeInOut(duration: 0.24)) }
                    )
                    .transition(reduceMotion ? .opacity.animation(.easeInOut(duration: 0.1)) : .opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: collapsed ? 60 : height)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if width > 0, pluginViewWidths[view.id] != width { pluginViewWidths[view.id] = width }
            }
            .transaction { if reduceMotion { $0.animation = nil } }
        }
    }

    private func pluginIslandHeader(title: String, symbol: String, badge: String?, morphID: String, collapse: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            pluginMorphIcon(symbol: symbol, size: 14, morphID: morphID)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DesktopTheme.ink).lineLimit(1)
            Spacer(minLength: 4)
            if let badge { Text(badge).font(.system(size: 11)).foregroundStyle(DesktopTheme.inkTertiary).lineLimit(1) }
            Button(action: collapse) {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesktopTheme.inkTertiary).frame(width: 36, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起\(title)")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 48)
    }

    private func compactPluginRow(symbol: String, title: String, detail: String, morphID: String, expand: @escaping () -> Void, open: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Button(action: expand) {
                HStack(spacing: 10) {
                    pluginMorphIcon(symbol: symbol, size: 15, morphID: morphID)
                        .frame(width: 36, height: 36).background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DesktopTheme.ink).lineLimit(1)
                        Text(detail).font(.system(size: 11)).foregroundStyle(DesktopTheme.inkSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("展开\(title)，\(detail)")
            Button("打开", action: open)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesktopTheme.accentInk)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("打开\(title)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 60)
    }

    @ViewBuilder
    private func pluginMorphIcon(symbol: String, size: CGFloat, morphID: String) -> some View {
        let icon = Image(systemName: symbol).font(.system(size: size)).foregroundStyle(DesktopTheme.accent)
        if reduceMotion {
            icon
        } else {
            icon.matchedGeometryEffect(id: "\(morphID).icon", in: pluginMorph)
        }
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

    private func isCollapsed(_ key: String) -> Bool { collapsedKeys.contains(key) }

    private func toggle(_ key: String, animation: Animation? = .spring(response: 0.32, dampingFraction: 0.85)) {
        if key == Section.shelf.rawValue, !hasShelfContent, expandedEmptyShelf {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                expandedEmptyShelf = false
            }
            return
        }
        var set = collapsedKeys
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        withAnimation(animation) {
            collapsedKeys = set
            collapsedRaw = set.sorted().joined(separator: ",")
        }
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

            if !collapsed {
                content()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: collapsed)
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
