import SwiftUI

/// Right-hand inspector for wide windows: context, pinned artifacts, files and tool tasks stay visible beside the
/// conversation instead of hiding behind toolbar popovers. Narrow windows keep the popovers.
struct DesktopInspector: View {
    @Bindable var workspace: DesktopWorkspace
    let onLocate: (UUID) -> Void
    let onOpenFiles: () -> Void
    let onOpenTasks: () -> Void
    @AppStorage("desktop.inspector.collapsed") private var collapsedRaw = ""

    private enum Section: String, CaseIterable { case context, shelf, files, tasks }

    private var conversation: DesktopConversation? { workspace.selectedConversation }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                card(.context, title: "上下文", symbol: "text.bubble", badge: contextBadge) {
                    DesktopConversationInsightsView(workspace: workspace, embedded: true)
                }
                card(.shelf, title: "产物架", symbol: "pin", badge: shelfCount.map(String.init)) {
                    DesktopArtifactShelfView(workspace: workspace, embedded: true, onLocate: onLocate)
                }
                card(.files, title: "会话文件", symbol: "folder", badge: workspace.selectedFiles.isEmpty ? nil : "\(workspace.selectedFiles.count)") {
                    files
                }
                card(.tasks, title: "工具任务", symbol: "checklist", badge: pendingApprovals > 0 ? "\(pendingApprovals) 待批准" : nil) {
                    tasks
                }
            }
            .padding(12)
        }
        .scrollIndicators(.never)
        .background(DesktopTheme.paperSide)
        .overlay(alignment: .leading) { Rectangle().fill(DesktopTheme.hairlineStrong).frame(width: 1).ignoresSafeArea() }
    }

    // MARK: Cards

    private func isCollapsed(_ section: Section) -> Bool { collapsedRaw.split(separator: ",").contains(Substring(section.rawValue)) }

    private func toggle(_ section: Section) {
        var set = Set(collapsedRaw.split(separator: ",").map(String.init))
        if set.contains(section.rawValue) { set.remove(section.rawValue) } else { set.insert(section.rawValue) }
        withAnimation(.smooth(duration: 0.28)) { collapsedRaw = set.sorted().joined(separator: ",") }
    }

    private func card<Content: View>(_ section: Section, title: String, symbol: String, badge: String?,
        @ViewBuilder content: () -> Content) -> some View {
        let collapsed = isCollapsed(section)
        return VStack(alignment: .leading, spacing: 0) {
            Button { toggle(section) } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).frame(width: 16)
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(DesktopTheme.ink)
                    if let badge {
                        Text(badge).font(.system(size: 11).monospacedDigit()).foregroundStyle(DesktopTheme.inkTertiary)
                            .contentTransition(.numericText())
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "展开\(title)" : "收起\(title)")
            content()
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .frame(maxHeight: collapsed ? 0 : nil, alignment: .top)
                .opacity(collapsed ? 0 : 1)
                .clipped()
                .disabled(collapsed)
                .accessibilityHidden(collapsed)
        }
        .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.hairline))
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
        VStack(alignment: .leading, spacing: 4) {
            if let error = workspace.fileErrorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开会话文件…", action: onOpenFiles)
                    .buttonStyle(.link).font(.system(size: 12))
            } else if workspace.isLoadingFiles {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("正在读取文件…").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                }
            } else if workspace.selectedFiles.isEmpty {
                Text("工具写入或导入的文件会出现在这里。").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            } else {
                ForEach(workspace.selectedFiles.prefix(8)) { file in
                    Button(action: onOpenFiles) {
                        HStack(spacing: 8) {
                            Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(DesktopTheme.inkTertiary)
                            Text(file.id).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkSecondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                                .font(.system(size: 11)).foregroundStyle(DesktopTheme.inkTertiary)
                        }
                        .padding(.horizontal, 6).frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(DesktopQuietButtonStyle())
                }
            }
            if workspace.fileErrorMessage == nil {
                Button("打开会话文件…", action: onOpenFiles).buttonStyle(.link).font(.system(size: 12)).padding(.top, 4)
            }
        }
    }

    private var tasks: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = workspace.agentTasks.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            } else if ownerTasks.isEmpty {
                Text("开启「工具」后，模型调用工具的记录会出现在这里。").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            } else {
                ForEach(ownerTasks.prefix(6)) { task in
                    Button(action: onOpenTasks) {
                        HStack(spacing: 8) {
                            if task.approval != nil || task.status == .running { DesktopPulse() }
                            else { Image(systemName: task.status == .completed ? "checkmark" : "circle").font(.system(size: 10)).foregroundStyle(DesktopTheme.inkTertiary) }
                            Text(task.title).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkSecondary).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(task.transactions.count) 次").font(.system(size: 11).monospacedDigit()).foregroundStyle(DesktopTheme.inkTertiary)
                        }
                        .padding(.horizontal, 6).frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(DesktopQuietButtonStyle())
                }
            }
            Button("打开任务工作台…", action: onOpenTasks).buttonStyle(.link).font(.system(size: 12)).padding(.top, 4)
        }
    }
}
