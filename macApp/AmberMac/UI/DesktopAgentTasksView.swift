import SwiftUI

struct DesktopAgentTasksView: View {
    @Bindable var workspace: DesktopWorkspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("任务工作台").font(.system(size: 20, weight: .semibold))
                    Text("查看工具调用、确认操作与执行结果。")
                        .font(.system(size: 13)).foregroundStyle(DesktopTheme.muted(colorScheme))
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let error = workspace.agentTasks.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(workspace.agentTasks.records) { task in taskCard(task) }
                }
                .frame(maxWidth: .infinity)
            }
            .overlay {
                if workspace.agentTasks.records.isEmpty {
                    ContentUnavailableView("还没有工具任务", systemImage: "checklist", description: Text("在输入区开启工具并发送消息后，实际执行记录会显示在这里。"))
                }
            }
        }
        .padding(24)
        .frame(width: 740, height: 600)
        .background(DesktopTheme.background(colorScheme))
        .tint(DesktopTheme.accent)
    }

    private func taskCard(_ task: DesktopAgentTask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Label(task.status.title, systemImage: task.status.symbol)
                        .font(.caption).foregroundStyle(task.status.color)
                }
                Spacer(minLength: 12)
                Button(workspace.summaries.contains(where: { $0.id == task.conversationID }) ? "打开会话" : "原会话已删除") {
                    workspace.select(task.conversationID); dismiss()
                }
                .disabled(!workspace.summaries.contains(where: { $0.id == task.conversationID }))
                if task.status == .running || task.status == .waiting {
                    Button("停止") { workspace.agentTasks.cancel(task.id) }
                }
            }
            Text(task.updatedAt, format: .dateTime.year().month().day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
            if let error = task.error {
                Text(error).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if task.approval != nil { DesktopToolApprovalCard(task: task, tasks: workspace.agentTasks) }
            if let result = task.resultText, !result.isEmpty {
                DisclosureGroup("任务结果") {
                    ScrollView {
                        Text(result).font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 180).padding(.top, 8)
                }
            }
            if !task.transactions.isEmpty {
                DisclosureGroup("\(task.transactions.count) 次工具调用") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(task.transactions, id: \.id) { transaction in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(transaction.name).font(.system(.callout, design: .monospaced).weight(.medium))
                                    Spacer()
                                    Text(transaction.stateTitle).font(.caption).foregroundStyle(.secondary)
                                }
                                if let outcome = transaction.outcome { Text(outcome).font(.caption).foregroundStyle(.secondary) }
                                if let invocation = transaction.canonicalInvocation, !invocation.isEmpty {
                                    DisclosureGroup("调用详情") {
                                        ScrollView {
                                            Text(invocation).font(.system(size: 11, design: .monospaced))
                                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        }.frame(maxHeight: 160).padding(.top, 5)
                                    }.font(.caption)
                                }
                                if let payload = transaction.resultPayload, !payload.isEmpty {
                                    DisclosureGroup("执行结果") {
                                        ScrollView {
                                            Text(payload).font(.system(size: 11, design: .monospaced))
                                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        }.frame(maxHeight: 180).padding(.top, 5)
                                    }.font(.caption)
                                }
                            }
                            if transaction.id != task.transactions.last?.id { Divider() }
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
        .padding(16)
        .background(DesktopTheme.raised(colorScheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.border(colorScheme)))
    }
}

private extension DesktopToolTransaction {
    var stateTitle: String {
        switch state {
        case "prepared": "准备中"
        case "started": "执行中"
        case "waiting_user": "等待确认"
        case "finished": "已结束"
        case "outcome_unknown": "结果待核对"
        case "reconciled": "已核对"
        default: state
        }
    }
}

struct DesktopToolApprovalCard: View {
    let task: DesktopAgentTask
    let tasks: DesktopAgentTasks
    @Environment(\.colorScheme) private var colorScheme
    @State private var detailsPresented = false

    var body: some View {
        if let approval = task.approval {
            VStack(alignment: .leading, spacing: 10) {
                Label("需要确认 · \(approval.name)", systemImage: "hand.raised")
                    .font(.system(size: 13, weight: .semibold))
                Text(approval.reason).font(.system(size: 13)).lineLimit(3)
                Text(approval.arguments).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("查看完整调用内容") { detailsPresented = true }
                    .buttonStyle(.link)
                    .popover(isPresented: $detailsPresented) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(approval.name).font(.headline).lineLimit(1)
                                Spacer()
                                Button("完成") { detailsPresented = false }
                            }
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(approval.reason).font(.callout)
                                    Text(approval.arguments).font(.system(size: 12, design: .monospaced))
                                }
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(18).frame(width: 520, height: 320)
                    }
                HStack {
                    Spacer()
                    Button("拒绝") { tasks.decide(runID: task.id, allow: false) }
                    Button("允许这次调用") { tasks.decide(runID: task.id, allow: true) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
            .background(DesktopTheme.accentWash(colorScheme), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.accent.opacity(0.22)))
            .tint(DesktopTheme.accent)
        }
    }
}

private extension DesktopAgentStatus {
    var title: String {
        switch self {
        case .running: "执行中"
        case .waiting: "等待确认"
        case .completed: "已完成"
        case .failed: "执行失败"
        case .cancelled: "已停止"
        case .interrupted: "已中断"
        case .outcomeUnknown: "需要核对结果"
        }
    }
    var symbol: String {
        switch self {
        case .running: "arrow.triangle.2.circlepath"
        case .waiting: "hand.raised"
        case .completed: "checkmark.circle"
        case .failed, .outcomeUnknown: "exclamationmark.circle"
        case .cancelled, .interrupted: "stop.circle"
        }
    }
    var color: Color {
        switch self {
        case .failed, .waiting, .outcomeUnknown: .orange
        case .completed: .green
        default: .secondary
        }
    }
}
