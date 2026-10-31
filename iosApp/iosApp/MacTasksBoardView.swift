import SwiftUI

/// Task board of the paired Mac: needs you / running / scheduled / done, as the Mac groups them.
/// Without Amber running on the Mac only the gateway's Claude Code / Codex sessions are shown, read-only.
struct MacTasksBoardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(RouterPath.self) private var router
    @State private var creatingSchedule = false
    @State private var showsDone = false

    private let store = MacGatewayStore.shared
    private static let refreshInterval: Duration = .seconds(10)

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        if store.connection == nil {
                            unpairedSection
                        } else {
                            boardSections
                        }
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
                .refreshable { await store.refresh() }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .tint(AmberTheme.accent)
        .task(id: store.connection?.gatewayId) {
            guard store.connection != nil else { return }
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
        .sheet(isPresented: $creatingSchedule) { MacGatewayScheduleSheet(store: store) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回", size: 44, symbolSize: 20) {
                dismiss()
            }
            Spacer(minLength: 0)
            Text(verbatim: L("任务"))
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if store.board != nil {
                AmberGlassCircleButton(systemImage: "plus", accessibilityLabel: "新建定时任务", size: 44, symbolSize: 17) {
                    creatingSchedule = true
                }
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    // MARK: - Sections

    private var unpairedSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Mac")
            AmberFormGroup {
                MacGatewayRow(icon: "desktopcomputer", title: L("尚未配对 Mac"),
                              detail: L("在 设置 › Mac Gateway 中扫码配对后，Mac 上的定时任务和 Claude Code / Codex 会话会出现在这里"),
                              action: { router.navigate(to: .macGateway) }) {
                    MacGatewayChevron()
                }
            }
            // e.g. the Mac revoked this device while the board was open.
            if let notice = store.notice, notice.isError {
                MacGatewaySectionFooter(text: notice.text, color: .orange)
            }
        }
    }

    @ViewBuilder
    private var boardSections: some View {
        let items = store.boardItems
        let groups = MacTasksBoardLayout.groups(items: items, schedules: store.board == nil ? nil : store.schedules)
        if store.isReachable == false {
            statusNote(icon: "wifi.slash", title: L("无法连接 Mac"),
                       detail: L("Mac 睡眠、合盖或断网时无法查看任务，下面是上次读取的内容。"))
        } else if store.board == nil, let reason = store.boardError {
            // The gateway's own reason, e.g. "Amber 未运行：在 Mac 上打开 Amber 后重试" (503) or an older gateway's 404.
            statusNote(icon: "exclamationmark.circle", title: L("只能看到 Claude Code / Codex 会话"), detail: reason)
        }
        if store.board == nil, store.boardError == nil, store.isReachable != false {
            // First load: the fallback would briefly show a board without schedules or approvals.
            VStack(spacing: 0) {
                AmberSectionLabel(text: "任务")
                AmberFormGroup {
                    MacGatewayRow(icon: "arrow.triangle.2.circlepath", title: L("正在读取…"), detail: "") { EmptyView() }
                }
            }
        } else if groups.isEmpty {
            VStack(spacing: 0) {
                AmberSectionLabel(text: "任务")
                AmberFormGroup {
                    MacGatewayRow(icon: "tray", title: L("暂无任务"),
                                  detail: L("Mac 上的定时任务和 Claude Code / Codex 会话会出现在这里")) {
                        EmptyView()
                    }
                }
            }
        }
        if store.board != nil || store.boardError != nil || store.isReachable == false {
            ForEach(groups) { group in
                section(group)
            }
        }
        if let notice = store.notice {
            MacGatewaySectionFooter(text: notice.text, color: notice.isError ? .orange : AmberTheme.muted)
                .padding(.top, 8)
        }
    }

    private func statusNote(icon: String, title: String, detail: String) -> some View {
        AmberFormGroup {
            MacGatewayRow(icon: icon, title: title, detail: detail) { EmptyView() }
        }
        .padding(.top, 8)
    }

    private func section(_ group: MacTasksBoardLayout.Group) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(verbatim: L(group.column.title))
            AmberFormGroup {
                if group.column == .done {
                    MacGatewayRow(icon: "checkmark.circle", title: IOSAppLocalization.formatted("已完成 %lld 个", defaultValue: "已完成 %lld 个",
                                                                         arguments: [group.rows.count]),
                                  detail: L("最近 7 天"),
                                  action: { withAnimation(.easeOut(duration: 0.2)) { showsDone.toggle() } }) {
                        MacGatewayChevron().rotationEffect(.degrees(showsDone ? 90 : 0))
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityValue(Text(verbatim: showsDone ? L("已展开") : L("已收起")))
                    if showsDone {
                        ForEach(group.rows) { row in
                            MacGatewayRowDivider()
                            rowView(row)
                        }
                    }
                } else {
                    if group.column == .needsYou, group.rows.contains(where: { $0.item?.kind == .agentSession }),
                       let url = store.status?.synaraURL.flatMap(URL.init(string:)) {
                        MacGatewayRow(icon: "bubble.left.and.text.bubble.right", title: L("在 Synara 中回复或确认"),
                                      detail: L("在浏览器中打开 Synara，处理其中的任务"), action: { openURL(url) }) {
                            MacGatewayChevron()
                        }
                        MacGatewayRowDivider()
                    }
                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { MacGatewayRowDivider() }
                        rowView(row)
                    }
                    if group.column == .scheduled, store.board != nil {
                        MacGatewayRowDivider()
                        MacGatewayRow(icon: "plus", title: L("新建定时任务"), detail: L("在 Mac 上按时运行提示词"),
                                      action: { creatingSchedule = true }) {
                            MacGatewayChevron()
                        }
                    }
                }
            }
            if group.column == .scheduled, store.board != nil {
                MacGatewaySectionFooter(text: L("在手机上新建的任务不会自动批准任何工具；审批规则只能在 Mac 上修改。"))
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: MacTasksBoardLayout.Row) -> some View {
        let schedule = row.scheduleId.flatMap { id in store.schedules?.first { $0.id == id } }
        MacGatewayRow(icon: row.icon, title: row.title, detail: rowDetail(row)) {
            if row.showsScheduleControls, let schedule {
                scheduleControls(schedule)
            }
        }
        if let approval = row.item?.approval {
            MacGatewayApprovalRow(approval: approval, store: store)
        } else if row.item?.kind == .run, row.item?.column == .needsYou {
            // The Mac drops approvals it can't route through the gateway; they can only be answered there.
            MacGatewaySectionFooter(text: L("请在 Mac 上处理"))
                .padding(.leading, 38)
                .padding(.top, -6)
                .padding(.bottom, 8)
        }
    }

    private func scheduleControls(_ schedule: MacGatewaySchedule) -> some View {
        HStack(spacing: 6) {
            if store.busySchedules.contains(schedule.id) || schedule.running {
                ProgressView().frame(width: 44, height: 44)
            } else {
                Button { Task { await store.runSchedule(schedule) } } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AmberTheme.accent)
                .accessibilityLabel(Text(verbatim: L("立即运行") + " " + schedule.name))
            }
            Toggle("", isOn: Binding(
                get: { schedule.enabled },
                set: { value in Task { await store.setScheduleEnabled(schedule, value) } }
            ))
            .labelsHidden()
            .tint(AmberTheme.accent)
            .disabled(store.busySchedules.contains(schedule.id))
            .accessibilityLabel(Text(verbatim: L("启用") + " " + schedule.name))
        }
    }

    private func rowDetail(_ row: MacTasksBoardLayout.Row) -> String {
        var parts = [row.detail].filter { !$0.isEmpty }
        if let next = row.nextRunAt {
            parts.append(L("下次") + " " + next.formatted(.relative(presentation: .named)))
        } else if let updated = row.updatedAt {
            parts.append(updated.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }
}

/// Pure grouping for the board page, unit-tested. Keeps the Mac's order; only adds schedules the Mac's board omits
/// (disabled ones) to "scheduled" so they can be switched back on from the phone.
enum MacTasksBoardLayout {
    struct Row: Identifiable, Equatable {
        var id: String
        var item: MacGatewayBoardItem?
        var title: String
        var detail: String
        var icon: String
        var scheduleId: String?
        var nextRunAt: Date?
        var updatedAt: Date?
        /// Run-now and the enable switch; only on scheduled-task rows, and only when Amber answered.
        var showsScheduleControls: Bool
    }

    struct Group: Identifiable, Equatable {
        var column: MacGatewayBoardItem.Column
        var rows: [Row]
        var id: String { column.rawValue }
    }

    /// `schedules` is nil when the board came from the gateway alone (no schedule controls then).
    static func groups(items: [MacGatewayBoardItem], schedules: [MacGatewaySchedule]?) -> [Group] {
        var rows: [MacGatewayBoardItem.Column: [Row]] = [:]
        for item in items {
            rows[item.column, default: []].append(Row(
                id: item.id, item: item, title: item.title, detail: item.detail, icon: icon(item),
                scheduleId: item.scheduleId, nextRunAt: item.column == .scheduled ? item.nextRunAt : nil,
                updatedAt: item.column == .scheduled ? nil : item.updatedAt,
                showsScheduleControls: schedules != nil && item.kind == .schedule))
        }
        // Schedules the board doesn't list: disabled ones, and ones just switched on before the board catches up.
        let listed = Set(items.filter { $0.kind == .schedule }.compactMap(\.scheduleId))
        for schedule in schedules ?? [] where !schedule.running && !listed.contains(schedule.id) {
            rows[.scheduled, default: []].append(Row(
                id: "schedule-off:\(schedule.id)", item: nil, title: schedule.name,
                detail: schedule.enabled ? schedule.rule
                    : schedule.rule + " · " + IOSAppLocalization.string("已停用", defaultValue: "已停用"),
                icon: "clock", scheduleId: schedule.id, nextRunAt: nil, updatedAt: nil, showsScheduleControls: true))
        }
        return MacGatewayBoardItem.Column.allCases.compactMap { column in
            guard let list = rows[column], !list.isEmpty else { return nil }
            return Group(column: column, rows: list)
        }
    }

    static func icon(_ item: MacGatewayBoardItem) -> String {
        switch item.kind {
        case .schedule: return "clock"
        case .run:
            if item.approval != nil || item.column == .needsYou { return "hand.raised" }
            if item.failed { return "exclamationmark.triangle" }
            return item.column == .done ? "checkmark.circle" : "play.circle"
        case .agentSession: return item.waitingForReply ? "text.bubble" : "terminal"
        }
    }
}

extension MacGatewayBoardItem.Column {
    var title: String {
        switch self {
        case .needsYou: "等你处理"
        case .running: "进行中"
        case .scheduled: "已排定"
        case .done: "已完成"
        }
    }
}

/// New Amber scheduled task, created on the Mac. Name, prompt and time only.
struct MacGatewayScheduleSheet: View {
    let store: MacGatewayStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MacGatewayScheduleDraft()
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("名称"), text: $draft.name)
                    TextField(L("到点后发给模型的内容"), text: $draft.prompt, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section(L("时间")) {
                    Picker(L("规则"), selection: $draft.rule) {
                        Text(verbatim: L("每天")).tag(MacGatewayScheduleDraft.Rule.daily)
                        Text(verbatim: L("工作日")).tag(MacGatewayScheduleDraft.Rule.weekdays)
                        Text(verbatim: L("每周")).tag(MacGatewayScheduleDraft.Rule.weekly)
                        Text(verbatim: L("间隔")).tag(MacGatewayScheduleDraft.Rule.interval)
                    }
                    if draft.rule == .interval {
                        Picker(L("每隔"), selection: $draft.intervalMinutes) {
                            ForEach([15, 30, 60, 120, 180, 360, 720], id: \.self) { value in
                                Text(verbatim: value < 60 ? "\(value) " + L("分钟") : "\(value / 60) " + L("小时")).tag(value)
                            }
                        }
                    } else {
                        DatePicker(L("时刻"), selection: $draft.time, displayedComponents: .hourAndMinute)
                    }
                    if draft.rule == .weekly {
                        HStack(spacing: 6) {
                            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                                let on = draft.weekdays.contains(day)
                                Button {
                                    if on { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) }
                                } label: {
                                    Text(verbatim: Calendar.current.veryShortWeekdaySymbols[day - 1])
                                        .font(.subheadline.weight(on ? .semibold : .regular))
                                        .frame(maxWidth: .infinity, minHeight: 36)
                                        .background(on ? AmberTheme.accentTint : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? AmberTheme.accent.opacity(0.4) : AmberTheme.borderSoft))
                                        .frame(minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(on ? AmberTheme.accent : AmberTheme.foreground)
                                .accessibilityLabel(Text(verbatim: Calendar.current.weekdaySymbols[day - 1]))
                                .accessibilityAddTraits(on ? [.isSelected] : [])
                            }
                        }
                    }
                }
                Section {
                    Text(verbatim: L("任务运行时不会自动批准任何工具，需要批准时会推送到手机。要调整审批规则，请在 Mac 上编辑。"))
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.muted)
                    if let error {
                        Text(verbatim: error).font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(Text(verbatim: L("新建定时任务")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(L("创建")) {
                            saving = true
                            Task {
                                error = await store.createSchedule(draft)
                                saving = false
                                if error == nil { dismiss() }
                            }
                        }
                        .disabled(!draft.isComplete)
                    }
                }
            }
        }
        .tint(AmberTheme.accent)
    }
}


private func L(_ key: String) -> String {
    IOSAppLocalization.string(key, defaultValue: key)
}
