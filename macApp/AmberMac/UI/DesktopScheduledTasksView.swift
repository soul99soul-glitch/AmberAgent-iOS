import SwiftUI

/// 定时任务: list (name, next run, last result, switch) and an editor with run history.
struct DesktopScheduledTasksView: View {
    let workspace: DesktopWorkspace
    let scheduler: DesktopScheduler
    var onOpenConversation: ((UUID) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedID: UUID?
    @State private var draft: DesktopScheduledTask?
    @State private var error: String?
    @State private var deleting: DesktopScheduledTask?
    @State private var confirmingHighRisk = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("定时任务").font(DesktopTheme.serif(size: 22, weight: .semibold))
                    Text("到点自动运行提示词，结果写进会话并发通知。Mac 睡眠时不会运行，醒来后按任务设置补跑一次。")
                        .font(.system(size: 13)).foregroundStyle(DesktopTheme.muted(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("暂停全部", isOn: Binding(get: { scheduler.isPaused }, set: { scheduler.isPaused = $0 }))
                    .toggleStyle(.switch).fixedSize()
                Button("新建任务") { newTask() }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let message = scheduler.errorMessage ?? (scheduler.unreadableFiles.isEmpty ? nil
                : "有 \(scheduler.unreadableFiles.count) 个任务文件无法读取，已原样保留：" + scheduler.unreadableFiles.joined(separator: "、")) {
                Label(message, systemImage: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(DesktopTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HSplitView {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(scheduler.tasks) { task in row(task) }
                        if scheduler.tasks.isEmpty {
                            Text("还没有定时任务").font(.system(size: 13)).foregroundStyle(DesktopTheme.inkTertiary).padding(12)
                        }
                    }
                    .padding(8)
                }
                .background(DesktopTheme.sidebar(colorScheme))
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if draft != nil { editor } else {
                            ContentUnavailableView("选择或新建一个定时任务", systemImage: "clock",
                                description: Text("例如每天 9:00 汇总会话文件夹里的新文件。"))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                .frame(minWidth: 470)
            }
        }
        .padding(24).frame(minWidth: 900, minHeight: 700)
        .background(DesktopTheme.background(colorScheme))
        .tint(DesktopTheme.accent)
        .task {
            await scheduler.waitUntilLoaded()
            if selectedID == nil, let first = scheduler.tasks.first { select(first) }
        }
        .confirmationDialog("删除这个定时任务？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible) {
            Button("删除任务", role: .destructive) {
                if let deleting {
                    Task { await scheduler.delete(deleting.id) }
                    if selectedID == deleting.id { selectedID = nil; draft = nil }
                }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { Text("已经生成的会话会保留。") }
        .confirmationDialog("允许无人值守时自动批准高风险工具？", isPresented: $confirmingHighRisk, titleVisibility: .visible) {
            Button("仍然允许", role: .destructive) { draft?.approval.autoApproveHighRisk = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("终端命令、删除文件和外部 MCP 调用将在没人看着时直接执行。建议同时设置工具白名单。")
        }
    }

    // MARK: list

    private func row(_ task: DesktopScheduledTask) -> some View {
        let selected = selectedID == task.id
        let secondary = selected ? DesktopTheme.inkSecondary : DesktopTheme.inkTertiary
        return DesktopSelectableRow(selected: selected, action: { select(task) }) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(task.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(DesktopTheme.ink).lineLimit(1)
                        if task.approval.autoApproveHighRisk {
                            Text("高风险自动批准").font(.system(size: 10, weight: .semibold)).foregroundStyle(DesktopTheme.danger)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .overlay(Capsule().strokeBorder(DesktopTheme.danger.opacity(0.6)))
                        }
                    }
                    Text(Self.ruleText(task.schedule)).font(.system(size: 12)).foregroundStyle(secondary).lineLimit(1)
                    Text(nextText(task)).font(.system(size: 12)).foregroundStyle(secondary).lineLimit(1)
                    if let last = task.lastRun { lastRunLabel(last).font(.system(size: 12)) }
                }
                Spacer(minLength: 0)
                Toggle("启用", isOn: Binding(get: { task.enabled }, set: { value in
                    Task { await scheduler.setEnabled(task.id, value); if selectedID == task.id { reloadDraft() } }
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .accessibilityLabel("启用 \(task.name)")
            }
        }
        .contextMenu {
            Button("立即运行一次") { runNow(task.id) }
            Button("删除任务", role: .destructive) { deleting = task }
        }
    }

    private func nextText(_ task: DesktopScheduledTask) -> String {
        if scheduler.running.contains(task.id) { return "正在运行…" }
        if scheduler.queued.contains(task.id) { return "等待空闲后运行" }
        guard task.enabled else { return "已停用" }
        if scheduler.isPaused { return "已暂停" }
        return task.nextRunAt.map { "下次：" + DesktopScheduleMenu.format($0) } ?? "没有下次运行"
    }

    @ViewBuilder private func lastRunLabel(_ run: DesktopScheduleRunRecord) -> some View {
        switch run.status {
        case .completed: Label("上次已完成", systemImage: "checkmark.circle").foregroundStyle(DesktopTheme.inkTertiary)
        case .failed: Label("上次未完成", systemImage: "exclamationmark.circle").foregroundStyle(DesktopTheme.accent)
        case .running: Label("运行中", systemImage: "clock").foregroundStyle(DesktopTheme.inkTertiary)
        case .skipped: Label("上次已跳过", systemImage: "forward").foregroundStyle(DesktopTheme.inkTertiary)
        }
    }

    // MARK: editor

    private var editor: some View {
        let binding = Binding(get: { draft! }, set: { draft = $0 })
        let saved = scheduler.tasks.first { $0.id == draft?.id }
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(saved == nil ? "新建定时任务" : "编辑定时任务").font(.system(size: 17, weight: .semibold))
                Spacer()
                if let saved {
                    Button("立即运行一次") { runNow(saved.id) }
                        .disabled(scheduler.running.contains(saved.id))
                }
            }
            field("名称") { TextField("例如：每日汇总", text: binding.name).textFieldStyle(.desktop) }
            field("提示词") {
                TextField("到点后发给模型的内容", text: binding.prompt, axis: .vertical)
                    .textFieldStyle(.desktop).lineLimit(3...8)
            }
            DesktopScheduleRuleEditor(schedule: binding.schedule)
            section("运行方式") {
                Picker("模型", selection: binding.modelID) {
                    Text("当前默认模型").tag(UUID?.none)
                    ForEach(workspace.settings.providers) { provider in
                        ForEach(provider.models.filter(\.enabled)) { model in
                            Text("\(provider.name) · \(model.displayName)").tag(UUID?.some(model.id))
                        }
                    }
                }
                Toggle("使用工具", isOn: binding.toolsEnabled)
                Toggle("允许派发只读子代理", isOn: binding.subagentsEnabled)
                Picker("结果写到", selection: outputBinding(binding)) {
                    Text("每次新建会话").tag(UUID?.none)
                    ForEach(workspace.summaries.prefix(50)) { summary in
                        Text("追加到「\(summary.title)」").lineLimit(1).tag(UUID?.some(summary.id))
                    }
                }
                Picker("错过运行时", selection: binding.missedRun) {
                    Text("醒来后补跑一次").tag(DesktopMissedRunPolicy.runOnceOnWake)
                    Text("跳过，等下一次").tag(DesktopMissedRunPolicy.skip)
                }
            }
            section("无人值守审批") {
                Text("定时任务只用这里的设置，不受对话里「自动批准」开关影响。没有自动批准的工具会暂停并发通知等你批准。")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).fixedSize(horizontal: false, vertical: true)
                Toggle("自动批准普通工具", isOn: binding.approval.autoApproveOrdinary)
                Toggle("自动批准高风险工具（终端、删除、外部 MCP）", isOn: Binding(get: { draft?.approval.autoApproveHighRisk ?? false }, set: { value in
                    if value { confirmingHighRisk = true } else { draft?.approval.autoApproveHighRisk = false }
                }))
                if draft?.approval.autoApproveHighRisk == true {
                    Label("高风险工具会在无人看管时直接执行。", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(DesktopTheme.danger)
                }
                Toggle("只允许指定的工具", isOn: Binding(get: { draft?.approval.allowedTools != nil }, set: { value in
                    draft?.approval.allowedTools = value ? (draft?.approval.allowedTools ?? []) : nil
                }))
                if draft?.approval.allowedTools != nil {
                    TextField("工具名，用逗号分隔，例如 workspace_file_list, workspace_file_read",
                        text: Binding(get: { (draft?.approval.allowedTools ?? []).joined(separator: ", ") }, set: { text in
                            draft?.approval.allowedTools = text.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace })
                                .map(String.init).filter { !$0.isEmpty }
                        }), axis: .vertical)
                        .textFieldStyle(.desktop).lineLimit(1...3)
                        .font(.system(size: 12, design: .monospaced))
                    Text("名单外的工具会被直接拒绝，不会等待批准。").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                }
                Stepper("审批等待超过 \(draft?.approval.approvalTimeoutHours ?? 12) 小时记为失败",
                    value: binding.approval.approvalTimeoutHours, in: 1...72)
            }
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(DesktopTheme.accent).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if let saved { Button("删除任务", role: .destructive) { deleting = saved } }
                Spacer()
                if saved != nil { Button("还原") { reloadDraft() }.disabled(draft.map(stripped) == saved.map(stripped)) }
                Button(saved == nil ? "创建任务" : "保存") { save() }
                    .buttonStyle(.desktopProminent)
                    .disabled(draft.map(stripped) == saved.map(stripped))
            }
            if let saved, !saved.recentRuns.isEmpty { history(saved) }
        }
    }

    private func history(_ task: DesktopScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("运行记录").font(.system(size: 13, weight: .semibold))
            ForEach(task.recentRuns) { run in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    lastRunLabel(run).labelStyle(.iconOnly).font(.system(size: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DesktopScheduleMenu.format(run.startedAt) + (run.scheduledFor == nil ? " · 手动运行" : ""))
                            .font(.system(size: 12)).foregroundStyle(DesktopTheme.ink)
                        if let error = run.error {
                            Text(error).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).lineLimit(2)
                        }
                        if !run.autoApprovedTools.isEmpty {
                            Text("自动批准：" + run.autoApprovedTools.joined(separator: "、"))
                                .font(.system(size: 12)).foregroundStyle(task.approval.autoApproveHighRisk ? DesktopTheme.danger : DesktopTheme.inkTertiary)
                        }
                    }
                    Spacer()
                    if let id = run.conversationID, workspace.summaries.contains(where: { $0.id == id }) {
                        Button("打开会话") { open(id) }.controlSize(.small)
                    }
                }
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            content()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesktopTheme.raised(colorScheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.border(colorScheme)))
    }

    private func outputBinding(_ binding: Binding<DesktopScheduledTask>) -> Binding<UUID?> {
        Binding(get: { if case .appendTo(let id) = binding.wrappedValue.output { id } else { nil } },
            set: { binding.wrappedValue.output = $0.map { .appendTo($0) } ?? .newConversation })
    }

    // MARK: actions

    private func newTask() {
        var task = DesktopScheduledTask(name: "", prompt: "", schedule: .daily(hour: 9, minute: 0))
        task.approval.allowedTools = nil
        selectedID = nil
        draft = task
        error = nil
    }

    private func select(_ task: DesktopScheduledTask) {
        selectedID = task.id
        draft = task
        error = nil
    }

    private func reloadDraft() {
        if let id = selectedID, let task = scheduler.tasks.first(where: { $0.id == id }) { draft = task }
    }

    /// History and timing fields the scheduler owns; ignored when comparing an edit against the saved task.
    private func stripped(_ task: DesktopScheduledTask) -> DesktopScheduledTask {
        var value = task
        value.lastRun = nil; value.recentRuns = []; value.nextRunAt = nil
        return value
    }

    private func save() {
        guard let draft else { return }
        Task {
            if let message = await scheduler.save(task: draft) { error = message; return }
            error = nil
            selectedID = draft.id
            reloadDraft()
        }
    }

    private func runNow(_ id: UUID) {
        error = scheduler.runNow(id)
    }

    private func open(_ id: UUID) {
        if let onOpenConversation { onOpenConversation(id) } else { workspace.select(id) }
        dismiss()
    }

    static func ruleText(_ schedule: DesktopSchedule) -> String {
        func clock(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }
        switch schedule {
        case .once(let date): return "仅一次 · " + DesktopScheduleMenu.format(date)
        case .daily(let hour, let minute): return "每天 " + clock(hour, minute)
        case .weekdays(let hour, let minute): return "工作日 " + clock(hour, minute)
        case .weekly(let days, let hour, let minute):
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            return "每周" + days.sorted().map { names[($0 - 1) % 7] }.joined(separator: "、") + " " + clock(hour, minute)
        case .interval(let minutes, _):
            return minutes % 60 == 0 ? "每 \(minutes / 60) 小时" : "每 \(minutes) 分钟"
        }
    }
}

/// Picks one of the five rules.
struct DesktopScheduleRuleEditor: View {
    @Binding var schedule: DesktopSchedule
    @Environment(\.colorScheme) private var colorScheme

    private enum Kind: String, CaseIterable, Identifiable {
        case once, daily, weekdays, weekly, interval
        var id: String { rawValue }
        var title: String {
            switch self {
            case .once: "仅一次"
            case .daily: "每天"
            case .weekdays: "工作日"
            case .weekly: "每周"
            case .interval: "间隔"
            }
        }
    }

    private var kind: Kind {
        switch schedule {
        case .once: .once
        case .daily: .daily
        case .weekdays: .weekdays
        case .weekly: .weekly
        case .interval: .interval
        }
    }

    private var clock: (hour: Int, minute: Int) {
        switch schedule {
        case .daily(let h, let m), .weekdays(let h, let m), .weekly(_, let h, let m): (h, m)
        case .once(let date):
            (Calendar.current.component(.hour, from: date), Calendar.current.component(.minute, from: date))
        case .interval: (9, 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("时间").font(.system(size: 13, weight: .semibold))
            Picker("规则", selection: Binding(get: { kind }, set: { change(to: $0) })) {
                ForEach(Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            switch schedule {
            case .once(let date):
                DatePicker("运行时间", selection: Binding(get: { date }, set: { schedule = .once($0) }), in: Date()...)
            case .daily, .weekdays:
                timePicker
            case .weekly(let days, let hour, let minute):
                HStack(spacing: 6) {
                    // Monday first, as on a Chinese calendar.
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                        let on = days.contains(day)
                        Button(["日", "一", "二", "三", "四", "五", "六"][day - 1]) {
                            let next = on ? days.filter { $0 != day } : (days + [day]).sorted()
                            schedule = .weekly(days: next, hour: hour, minute: minute)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? DesktopTheme.accentInk : DesktopTheme.inkSecondary)
                        .frame(width: 30, height: 26)
                        .background(on ? DesktopTheme.honeySoft : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? DesktopTheme.honeyEdge : DesktopTheme.hairline))
                        .accessibilityLabel("星期" + ["日", "一", "二", "三", "四", "五", "六"][day - 1])
                        .accessibilityAddTraits(on ? [.isSelected] : [])
                    }
                }
                timePicker
            case .interval(let minutes, let anchor):
                Picker("每隔", selection: Binding(get: { minutes }, set: { schedule = .interval(minutes: $0, anchor: anchor) })) {
                    ForEach([15, 30, 60, 120, 180, 360, 720], id: \.self) { value in
                        Text(value < 60 ? "\(value) 分钟" : "\(value / 60) 小时").tag(value)
                    }
                }
                Text("从保存时开始计时。").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            }
            if let error = schedule.validationError {
                Text(error).font(.system(size: 12)).foregroundStyle(DesktopTheme.accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesktopTheme.raised(colorScheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.border(colorScheme)))
    }

    private var timePicker: some View {
        DatePicker("时刻", selection: Binding(get: {
            Calendar.current.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: date), minute = calendar.component(.minute, from: date)
            switch schedule {
            case .daily: schedule = .daily(hour: hour, minute: minute)
            case .weekdays: schedule = .weekdays(hour: hour, minute: minute)
            case .weekly(let days, _, _): schedule = .weekly(days: days, hour: hour, minute: minute)
            default: break
            }
        }), displayedComponents: .hourAndMinute)
    }

    private func change(to kind: Kind) {
        let (hour, minute) = clock
        switch kind {
        case .once:
            let today = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
            schedule = .once(today > Date() ? today : today.addingTimeInterval(86_400))
        case .daily: schedule = .daily(hour: hour, minute: minute)
        case .weekdays: schedule = .weekdays(hour: hour, minute: minute)
        case .weekly: schedule = .weekly(days: [2], hour: hour, minute: minute)
        case .interval: schedule = .interval(minutes: 60, anchor: Date())
        }
    }
}
