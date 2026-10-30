import SwiftUI
@preconcurrency import GatewayCore

/// 任务: scheduled tasks, their runs and the gateway's Claude Code / Codex sessions, in four columns.
/// Wide windows lay the columns side by side; narrow ones stack them.
struct DesktopBoardView: View {
    let workspace: DesktopWorkspace
    let scheduler: DesktopScheduler
    var onOpenConversation: (UUID) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var items: [AmberControl.BoardItem] = []
    @State private var editingTasks = false
    @State private var editingTaskID: UUID?
    @State private var message: String?

    private static let columnMinWidth: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let message {
                Label(message, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkSecondary)
                    .padding(.horizontal, 24).padding(.bottom, 10)
            }
            GeometryReader { geometry in
                let wide = geometry.size.width >= Self.columnMinWidth * 4 + 24 * 2 + 16 * 3
                ScrollView(.vertical) {
                    let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 16)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                    layout {
                        ForEach(AmberControl.BoardItem.Column.allCases, id: \.self) { column in
                            columnView(column, wide: wide)
                                .frame(width: wide ? (geometry.size.width - 48 - 48) / 4 : nil)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .background(DesktopTheme.paper)
        .task {
            while !Task.isCancelled {
                items = workspace.boardItems()
                workspace.refreshBoardBadge(from: items)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(isPresented: $editingTasks) {
            DesktopScheduledTasksView(workspace: workspace, scheduler: scheduler, initialSelection: editingTaskID,
                onOpenConversation: onOpenConversation)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("任务").font(DesktopTheme.serif(size: 22, weight: .semibold)).foregroundStyle(DesktopTheme.ink)
                Text("定时任务与 Claude Code、Codex 会话。Mac 睡眠时不会运行，醒来后按设置补跑。")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            }
            Spacer()
            Toggle("暂停全部", isOn: Binding(get: { scheduler.isPaused }, set: { scheduler.isPaused = $0; refresh() }))
                .toggleStyle(.switch).fixedSize()
            Button("管理定时任务…") { editingTaskID = nil; editingTasks = true }
            Button("新建定时任务") { editingTaskID = DesktopScheduledTasksView.newTaskMarker; editingTasks = true }
                .buttonStyle(.desktopProminent)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private func columnView(_ column: AmberControl.BoardItem.Column, wide: Bool) -> some View {
        let cards = items.filter { $0.column == column }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Self.columnDotColor(column))
                    .frame(width: 6.5, height: 6.5)
                Text(Self.title(column)).font(.system(size: 13, weight: .semibold)).foregroundStyle(DesktopTheme.ink)
                Text("\(cards.count)").font(.system(size: 11, design: .monospaced).weight(.semibold)).foregroundStyle(DesktopTheme.inkSecondary)
                    .padding(.horizontal, 6.5).padding(.vertical, 1.5)
                    .background(DesktopTheme.paperDeep, in: Capsule())
            }
            .padding(.bottom, 2)
            if cards.isEmpty {
                Text(Self.empty(column)).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(DesktopTheme.paperDeep.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.hairline))
            }
            ForEach(cards) { card($0) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func card(_ item: AmberControl.BoardItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: Self.icon(item)).font(.system(size: 13)).foregroundStyle(item.failed ? DesktopTheme.danger : DesktopTheme.accent)
                    .frame(width: 18).padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DesktopTheme.ink).lineLimit(2)
                    Text(detail(item)).font(.system(size: 12)).foregroundStyle(item.failed ? DesktopTheme.danger : DesktopTheme.inkTertiary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let approval = item.approval ?? localApproval(item) {
                approvalBlock(item, approval)
            }
            actions(item)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(item.column == .needsYou ? DesktopTheme.honeyEdge : DesktopTheme.hairline))
    }

    /// A run that waits on an approval the gateway didn't see (gateway off) is still answered here on the Mac.
    private func localApproval(_ item: AmberControl.BoardItem) -> AmberControl.BoardItem.Approval? {
        guard item.kind == .run, item.column == .needsYou, let id = item.conversationId.flatMap(UUID.init(uuidString:)),
              let approval = workspace.agentTasks.records.first(where: { $0.conversationID == id && $0.status == .waiting })?.approval
        else { return nil }
        return .init(sessionKey: "", toolCallId: approval.id, tool: approval.name, detail: DesktopGatewayReporter.excerpt(approval.arguments),
            highRisk: DesktopToolRegistry.isHighRisk(approval.name))
    }

    private func approvalBlock(_ item: AmberControl.BoardItem, _ approval: AmberControl.BoardItem.Approval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(approval.tool).font(.system(size: 12, design: .monospaced)).foregroundStyle(DesktopTheme.ink)
                if approval.highRisk {
                    Text("高风险").font(.system(size: 11, weight: .medium)).foregroundStyle(DesktopTheme.danger)
                }
            }
            // High risk is approvable here because the full call is on screen, as in DesktopToolApprovalCard.
            if approval.highRisk, let full = fullArguments(item, approval) {
                ScrollView {
                    Text(full).font(.system(size: 11, design: .monospaced)).foregroundStyle(DesktopTheme.inkSecondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120).fixedSize(horizontal: false, vertical: true)
            } else if let detail = approval.detail {
                Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(DesktopTheme.inkSecondary).lineLimit(3)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button("拒绝") { decide(item, approval, allow: false) }
                if !approval.highRisk || fullArguments(item, approval) != nil {
                    Button("批准") { decide(item, approval, allow: true) }.buttonStyle(.desktopProminent)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func actions(_ item: AmberControl.BoardItem) -> some View {
        let conversation = item.conversationId.flatMap(UUID.init(uuidString:))
        let task = item.scheduleId.flatMap(UUID.init(uuidString:))
        if conversation != nil || (item.kind == .schedule && task != nil) {
            HStack(spacing: 8) {
                if let conversation, workspace.summaries.contains(where: { $0.id == conversation }) {
                    Button("打开会话") { onOpenConversation(conversation) }.buttonStyle(.desktopActionPill)
                }
                if item.kind == .schedule, let task {
                    Button("立即运行") { let error = scheduler.runNow(task); refresh(); message = error }.buttonStyle(.desktopTintedPill)
                    Button("编辑") { editingTaskID = task; editingTasks = true }.buttonStyle(.desktopActionPill)
                }
            }
            .padding(.leading, 26)
        }
    }

    private static func columnDotColor(_ column: AmberControl.BoardItem.Column) -> Color {
        switch column {
        case .needsYou: DesktopTheme.accent
        case .running: DesktopTheme.honeyEdge
        case .scheduled: DesktopTheme.inkTertiary
        case .done: DesktopTheme.success
        }
    }

    private func fullArguments(_ item: AmberControl.BoardItem, _ approval: AmberControl.BoardItem.Approval) -> String? {
        guard let conversation = item.conversationId.flatMap(UUID.init(uuidString:)) else { return nil }
        return workspace.agentTasks.records.first { $0.conversationID == conversation && $0.approval?.id == approval.toolCallId }?.approval?.arguments
    }

    private func decide(_ item: AmberControl.BoardItem, _ approval: AmberControl.BoardItem.Approval, allow: Bool) {
        guard let conversation = item.conversationId.flatMap(UUID.init(uuidString:)),
              let run = workspace.agentTasks.records.first(where: { $0.conversationID == conversation && $0.approval?.id == approval.toolCallId })
        else { return }
        // On the Mac the person is at the keyboard with the full call in front of them, so high risk can be approved here.
        Task {
            let applied = await workspace.agentTasks.decide(runID: run.id, allow: allow)?.value ?? false
            refresh()
            if !applied { message = workspace.agentTasks.errorMessage ?? "此审批已经结束。" }
        }
    }

    private func refresh() {
        message = nil
        items = workspace.boardItems()
        workspace.refreshBoardBadge(from: items)
    }

    private func detail(_ item: AmberControl.BoardItem) -> String {
        guard item.column == .scheduled, let next = item.nextRunAt else { return item.detail }
        return item.detail + " · 下次 " + DesktopScheduleMenu.format(next)
    }

    static func title(_ column: AmberControl.BoardItem.Column) -> String {
        switch column {
        case .needsYou: "等你处理"
        case .running: "进行中"
        case .scheduled: "已排定"
        case .done: "已完成"
        }
    }

    private static func empty(_ column: AmberControl.BoardItem.Column) -> String {
        switch column {
        case .needsYou: "没有要你处理的事"
        case .running: "没有正在运行的任务"
        case .scheduled: "还没有排定的定时任务"
        case .done: "最近 7 天没有完成的任务"
        }
    }

    private static func icon(_ item: AmberControl.BoardItem) -> String {
        if item.failed { return "exclamationmark.circle" }
        switch item.kind {
        case .schedule: return "clock"
        case .run: return item.column == .done ? "checkmark.circle" : "clock.badge"
        case .agentSession: return item.waitingForReply ? "text.bubble" : "terminal"
        }
    }
}
