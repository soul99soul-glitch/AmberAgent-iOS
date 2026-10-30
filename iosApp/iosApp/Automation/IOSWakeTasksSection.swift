import SwiftUI

@MainActor
struct IOSWakeTasksSection: View {
    var scheduler: IOSWakeScheduler = .shared
    @Environment(\.openURL) private var openURL
    @State private var operationID: String?
    @State private var result: String?
    @State private var pendingCancellation: IOSWakeTask?

    private var displayedTasks: [IOSWakeTask] {
        scheduler.store.tasks.sorted { left, right in
            let leftPending = left.status != .completed && left.status != .cancelled
            let rightPending = right.status != .completed && right.status != .cancelled
            return leftPending == rightPending ? left.createdAt > right.createdAt : leftPending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "自动续跑")
            AmberFormGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Text(scheduler.schedulingStatus)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                    Text("告诉 Amber 何时继续，或让它在任务中自行安排。快捷指令可执行到期任务，也可发送命名事件。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                    if let error = scheduler.store.loadError ?? scheduler.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if let result {
                        Text(result).font(.caption).foregroundStyle(AmberTheme.foreground)
                    }
                    Button("检查并执行到期任务", systemImage: "play.circle") {
                        Task { result = await scheduler.runDueTasks().summary }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(AmberTheme.accent)
                    ForEach(displayedTasks) { task in
                        Divider().overlay(AmberTheme.borderSoft)
                        taskRow(task)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
            }
        }
        .confirmationDialog(
            "取消续跑任务？",
            isPresented: Binding(
                get: { pendingCancellation != nil },
                set: { if !$0 { pendingCancellation = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingCancellation
        ) { task in
            Button("取消任务", role: .destructive) {
                operationID = task.id
                Task {
                    defer { operationID = nil }
                    do {
                        let current = try await scheduler.cancel(id: task.id)
                        result = "\(current.title)：\(current.status.title)"
                    } catch { result = error.localizedDescription }
                }
            }
            Button("继续保留", role: .cancel) {}
        } message: { task in
            Text("取消“\(task.title)”后将停止后续执行，已有结果仍保留在原对话中。")
        }
    }

    private func taskRow(_ task: IOSWakeTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title).font(.subheadline.weight(.medium)).foregroundStyle(AmberTheme.foreground)
            Text(task.status.title).font(.caption).foregroundStyle(AmberTheme.accent)
            if let fireAt = task.fireAt {
                Text("最早执行：\(fireAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(AmberTheme.muted)
            }
            if let event = task.event {
                Text("等待事件：\(event)").font(.caption).foregroundStyle(AmberTheme.muted)
            }
            if task.requiresForeground {
                Text("需要前台执行").font(.caption).foregroundStyle(AmberTheme.muted)
            }
            if let message = task.lastMessage {
                Text(message).font(.caption).foregroundStyle(AmberTheme.muted)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { taskActions(task) }
                VStack(alignment: .leading, spacing: 10) { taskActions(task) }
            }
        }
    }

    @ViewBuilder
    private func taskActions(_ task: IOSWakeTask) -> some View {
        Button {
            if let url = IOSAppDeepLink.url(for: .conversation(id: task.conversationID)) { openURL(url) }
        } label: {
            Text("查看原对话").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        if [.scheduled, .failed, .interrupted].contains(task.status) {
            Button {
                operationID = task.id
                Task {
                    defer { operationID = nil }
                    result = await scheduler.runTask(id: task.id).summary
                }
            } label: {
                Text(task.status == .scheduled ? "立即执行" : "重试")
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .disabled(operationID != nil)
        }
        if task.status != .completed && task.status != .cancelled {
            Button(role: .destructive) {
                pendingCancellation = task
            } label: {
                Text("取消").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .disabled(operationID != nil)
        }
    }
}
