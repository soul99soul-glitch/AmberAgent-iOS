import AppKit
import SwiftUI

/// Menu bar item: what is running, what is next, open / pause / quit.
struct DesktopScheduleMenu: View {
    let scheduler: DesktopScheduler
    let workspace: DesktopWorkspace
    let backgroundMode: DesktopBackgroundMode
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let running = scheduler.tasks.filter { scheduler.running.contains($0.id) }
        if running.isEmpty {
            Text("没有正在运行的定时任务")
        } else {
            Section("正在运行") {
                ForEach(running) { task in Text("⏱ " + task.name) }
            }
        }
        if scheduler.isPaused {
            Text("定时任务已暂停")
        } else if let next = scheduler.nextTask, let at = next.nextRunAt {
            Text("下一个：\(next.name) · \(Self.format(at))")
        } else {
            Text("没有排定的定时任务")
        }
        Divider()
        Button("打开 Amber") { openMain() }
            .keyboardShortcut("o")
        Button("定时任务…") {
            workspace.showsScheduledTasks = true
            openMain()
        }
        Toggle("暂停所有定时任务", isOn: Binding(get: { scheduler.isPaused }, set: { scheduler.isPaused = $0 }))
        Divider()
        Button("退出 Amber") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openMain() {
        backgroundMode.showDockIcon()
        openWindow(id: "main")
    }

    static func format(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "今天 " + time }
        if calendar.isDateInTomorrow(date) { return "明天 " + time }
        return date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().weekday(.abbreviated)) + " " + time
    }
}
