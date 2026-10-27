import SwiftUI

struct DesktopAgentTasksView: View {
    @Bindable var workspace: DesktopWorkspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("任务工作台").font(DesktopTheme.serif(size: 22, weight: .semibold))
                    Text("查看工具调用、确认操作与执行结果。")
                        .font(.system(size: 13)).foregroundStyle(DesktopTheme.muted(colorScheme))
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let error = workspace.agentTasks.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 13)).foregroundStyle(DesktopTheme.accent).fixedSize(horizontal: false, vertical: true)
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
                        .font(.system(size: 12)).foregroundStyle(task.status.color)
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
                .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            if let error = task.error {
                Text(error).font(.system(size: 13)).foregroundStyle(DesktopTheme.inkTertiary)
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
                                    Text(transaction.stateTitle).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                                }
                                if let outcome = transaction.outcome { Text(outcome).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary) }
                                if let invocation = transaction.canonicalInvocation, !invocation.isEmpty {
                                    DisclosureGroup("调用详情") {
                                        ScrollView {
                                            Text(invocation).font(.system(size: 12, design: .monospaced))
                                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        }.frame(maxHeight: 160).padding(.top, 5)
                                    }.font(.system(size: 12))
                                }
                                if let payload = transaction.resultPayload, !payload.isEmpty {
                                    DisclosureGroup("执行结果") {
                                        ScrollView {
                                            Text(payload).font(.system(size: 12, design: .monospaced))
                                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        }.frame(maxHeight: 180).padding(.top, 5)
                                    }.font(.system(size: 12))
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
    @State private var detailsPresented = false
    @State private var appeared = false
    @State private var decided = false

    var body: some View {
        if let approval = task.approval {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    DesktopPulse()
                    Text("等待你批准").font(.system(size: 14, weight: .semibold)).foregroundStyle(DesktopTheme.ink)
                    Text(approval.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(DesktopTheme.inkTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("查看完整调用") { detailsPresented = true }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .popover(isPresented: $detailsPresented) { details(approval) }
                }
                .padding(.bottom, 6)
                Text(approval.reason).font(.system(size: 14)).foregroundStyle(DesktopTheme.inkSecondary)
                    .lineSpacing(4).lineLimit(3)
                    .padding(.leading, 14)
                    .padding(.bottom, 12)
                ScrollView {
                    Text(approval.arguments).font(.system(size: 12, design: .monospaced)).foregroundStyle(DesktopTheme.ink)
                        .lineSpacing(2).textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 112)
                .fixedSize(horizontal: false, vertical: true)
                .background(DesktopTheme.paper, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.hairline))
                    .padding(.leading, 14)
                HStack(spacing: 8) {
                    // Turn on auto-approval straight from the prompt, then approve this call. Not for calls that always ask.
                    if !DesktopToolRegistry.alwaysAsks(approval.name) { Menu {
                        if DesktopToolRegistry.isHighRisk(approval.name) {
                            Button("开启高风险自动批准并批准") { tasks.autoApprove = true; tasks.autoApproveHighRisk = true; decide(true) }
                        } else {
                            Button("开启全局自动批准并批准") { tasks.autoApprove = true; decide(true) }
                            Button("同时开启高风险自动批准") { tasks.autoApprove = true; tasks.autoApproveHighRisk = true; decide(true) }
                        }
                    } label: {
                        Text("始终允许").font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .tint(DesktopTheme.inkSecondary)
                    .help(DesktopToolRegistry.isHighRisk(approval.name) ? "这是高风险操作（终端命令、删除或外部工具）" : "之后的普通工具调用不再询问") }
                    if DesktopToolRegistry.isHighRisk(approval.name) {
                        Text("高风险").font(.system(size: 11, weight: .medium)).foregroundStyle(DesktopTheme.danger)
                            .padding(.horizontal, 6).frame(height: 18)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DesktopTheme.danger.opacity(0.5)))
                    }
                    Spacer()
                    Button { decide(false) } label: {
                        Text("拒绝").font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).frame(height: 30)
                            .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.hairlineStrong))
                    }
                    .buttonStyle(DesktopPressButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
                    Button { decide(true) } label: {
                        HStack(spacing: 8) {
                            Text("批准").font(.system(size: 13, weight: .medium))
                            Text("⌘↩").font(.system(size: 12)).opacity(0.7)
                        }
                        .foregroundStyle(DesktopTheme.paper)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(DesktopTheme.ink, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(DesktopPressButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.top, 12)
                .disabled(decided)
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 12).fill(DesktopTheme.card)
                    .overlay(RoundedRectangle(cornerRadius: 12).fill(RadialGradient(colors: [DesktopTheme.honey, DesktopTheme.honeySoft, .clear],
                        center: .topLeading, startRadius: 0, endRadius: 360)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesktopTheme.honeyEdge))
                    .background(RoundedRectangle(cornerRadius: 12).inset(by: -4).fill(DesktopTheme.honeySoft))
                    .shadow(color: DesktopTheme.honey, radius: 16, y: 8)
            }
            .tint(DesktopTheme.accent)
            .scaleEffect(appeared ? 1 : 0.97)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            .onAppear { withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { appeared = true } }
        }
    }

    private func decide(_ allow: Bool) {
        decided = true
        withAnimation(.easeIn(duration: 0.16)) { appeared = false }
        tasks.decide(runID: task.id, allow: allow)
    }

    private func details(_ approval: DesktopToolApproval) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(approval.name).font(DesktopTheme.serif(size: 17, weight: .semibold)).lineLimit(1)
                Spacer()
                Button("完成") { detailsPresented = false }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(approval.reason).font(.system(size: 14)).foregroundStyle(DesktopTheme.inkSecondary).lineSpacing(4)
                    Text(approval.arguments).font(.system(size: 12, design: .monospaced))
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))
                }
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20).frame(width: 540, height: 340)
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
        case .failed, .waiting, .outcomeUnknown: DesktopTheme.accent
        case .completed: DesktopTheme.inkTertiary
        default: DesktopTheme.inkTertiary
        }
    }
}

/// 全局自动批准 / 高风险自动批准 (iOS「快速批准」). High-risk implies global.
struct DesktopToolApprovalSettings: View {
    @Bindable var tasks: DesktopAgentTasks

    var body: some View {
        Section("工具批准") {
            Toggle(isOn: Binding(get: { tasks.autoApprove || tasks.autoApproveHighRisk }, set: { on in
                withAnimation(.easeOut(duration: 0.2)) {
                    tasks.autoApprove = on
                    if !on { tasks.autoApproveHighRisk = false }
                }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("全局自动批准")
                    Text("写入会话文件、记忆、发起议会等普通工具直接执行，不再逐次确认。")
                        .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                }
            }
            Toggle(isOn: Binding(get: { tasks.autoApproveHighRisk }, set: { on in
                withAnimation(.easeOut(duration: 0.2)) { tasks.autoApproveHighRisk = on }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("高风险自动批准")
                    Text("还会直接执行终端命令、删除文件、调用外部 MCP 工具。只在信任当前任务时开启。")
                        .font(.system(size: 12)).foregroundStyle(tasks.autoApproveHighRisk ? DesktopTheme.danger : DesktopTheme.inkTertiary)
                }
            }
        }
    }
}
