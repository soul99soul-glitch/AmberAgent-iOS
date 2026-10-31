import SwiftUI

/// Obsidian-inspired Workspace Leaf view for active plugins (such as the built-in Feishu Calendar board)
/// plus the global `⌘K` Command Palette (`DesktopCommandPaletteView`).
struct DesktopPluginWorkspaceView: View {
    @Bindable var workspace: DesktopWorkspace
    let pluginID: String
    let viewID: String
    var onFocusComposer: () -> Void = {}

    @State var dateFilter = 0
    @State var creatingEvent = false
    @State var newSummary = ""
    @State var newStartTime = ""
    @State var newEndTime = ""
    @State var newLocation = "飞书视频会议"
    @State var newAttendees = ""
    @State var newNotes = ""

    // Feishu Bot Studio states
    @State var botComposerTab = 0 // 0 = 消息卡片, 1 = 云文档读写, 2 = 群聊记录
    @State var botTitle = "Amber 进展同步卡片"
    @State var botContent = ""
    @State var botReceiveID = ""
    @State var botDocInput = ""
    @State var botNewDocTitle = ""
    @State var botNewDocContent = ""
    @State var botChatID = ""
    @State var isRunningBotAction = false

    @State var statusBannerText: String?
    @State var statusIsError = false

    var isFeishuBotView: Bool {
        pluginID == "feishu_calendar" && viewID == "bot_studio"
    }

    var plugin: DesktopInstalledPlugin? {
        workspace.plugins.plugins.first { $0.id == pluginID }
    }

    var viewEntry: DesktopPluginWorkspaceViewEntry? {
        workspace.plugins.activeWorkspaceViews.first { $0.pluginID == pluginID && $0.viewID == viewID }
    }

    var customViewEntry: DesktopPluginCustomViewEntry? {
        workspace.plugins.activeCustomViews.first { $0.pluginID == pluginID && $0.viewID == viewID }
    }

    var customEntryPath: String? {
        if let path = customViewEntry?.entryPath, !path.isEmpty { return path }
        if let path = viewEntry?.entryPath, !path.isEmpty { return path }
        return nil
    }

    var todayString: String {
        workspace.plugins.todayDateString
    }

    var tomorrowString: String {
        workspace.plugins.tomorrowDateString
    }

    var allEvents: [DesktopPluginEventItem] {
        workspace.plugins.calendarEvents
    }

    var todayEvents: [DesktopPluginEventItem] {
        allEvents.filter { $0.datePrefix == todayString }
    }

    var tomorrowEvents: [DesktopPluginEventItem] {
        allEvents.filter { $0.datePrefix == tomorrowString }
    }

    var filteredEvents: [DesktopPluginEventItem] {
        switch dateFilter {
        case 1: todayEvents
        case 2: tomorrowEvents
        default: allEvents
        }
    }

    var body: some View {
        if let entryPath = customEntryPath {
            DesktopPluginCustomViewContainer(
                workspace: workspace,
                pluginID: pluginID,
                viewID: viewID,
                title: customViewEntry?.title ?? viewEntry?.title ?? plugin?.manifest.name ?? "插件视图",
                subtitle: customViewEntry?.subtitle ?? viewEntry?.subtitle ?? plugin?.manifest.description ?? "",
                symbol: customViewEntry?.symbol ?? viewEntry?.symbol ?? plugin?.manifest.icon ?? "puzzlepiece.extension",
                entryPath: entryPath,
                showHeader: true
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle().fill(DesktopTheme.hairline).frame(height: 1)

                if let statusBannerText {
                    HStack(spacing: 8) {
                        Image(systemName: statusIsError ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(statusIsError ? DesktopTheme.danger : DesktopTheme.accent)
                        Text(statusBannerText)
                            .font(.system(size: 12.5))
                            .foregroundStyle(statusIsError ? DesktopTheme.danger : DesktopTheme.inkSecondary)
                        Spacer()
                        Button {
                            self.statusBannerText = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DesktopTheme.inkTertiary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("关闭提示")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 9)
                    .background(DesktopTheme.honeySoft)
                }

                if pluginID == "feishu_calendar" {
                    if isFeishuBotView {
                        feishuBotBoard
                    } else {
                        feishuCalendarBoard
                    }
                } else {
                    genericPluginBoard
                }
            }
            .background(DesktopTheme.paper)
        }
    }

    // MARK: - Header

    var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                workspace.openChatSurface()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("返回对话")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
            }
            .buttonStyle(DesktopQuietButtonStyle())
            .fixedSize()
            .help("切回当前对话视图")
            .accessibilityLabel("返回对话")
            .keyboardShortcut(.escape, modifiers: [])

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(viewEntry?.title ?? plugin?.manifest.name ?? "飞书工作区")
                        .font(DesktopTheme.serif(size: 21, weight: .semibold))
                        .foregroundStyle(DesktopTheme.ink)
                        .fixedSize()

                    if pluginID == "feishu_calendar" {
                        let badgeText = isFeishuBotView
                            ? workspace.plugins.feishuBotConnectionBadge
                            : workspace.plugins.feishuCalendarConnectionBadge
                        let badgeActive = isFeishuBotView
                            ? workspace.plugins.hasFeishuBotCredentials
                            : workspace.plugins.hasFeishuRemoteCredentials

                        Text(badgeText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(badgeActive ? DesktopTheme.accent : DesktopTheme.inkTertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                badgeActive ? DesktopTheme.honeySoft : DesktopTheme.paperDeep,
                                in: Capsule()
                            )
                            .fixedSize()
                    }
                }
                Text(viewEntry?.subtitle ?? plugin?.manifest.description ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if pluginID == "feishu_calendar" {
                DesktopSegmented(
                    options: [
                        (0, "飞书日历"),
                        (1, "飞书机器人")
                    ],
                    selection: Binding(
                        get: { isFeishuBotView ? 1 : 0 },
                        set: { idx in
                            workspace.openPluginView(
                                pluginID: "feishu_calendar",
                                viewID: idx == 1 ? "bot_studio" : "calendar_board"
                            )
                        }
                    )
                )
                .fixedSize()

                if isFeishuBotView {
                    Button {
                        pushTodayScheduleToFeishuBot()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "paperplane")
                                .font(.system(size: 11, weight: .semibold))
                            Text("推送今日日程到飞书群")
                        }
                    }
                    .buttonStyle(.desktopProminent)
                    .fixedSize()
                    .disabled(isRunningBotAction)
                } else {
                    DesktopSegmented(
                        options: [
                            (0, "全部 \(allEvents.count)"),
                            (1, "今天 \(todayEvents.count)"),
                            (2, "明天 \(tomorrowEvents.count)")
                        ],
                        selection: $dateFilter
                    )
                    .fixedSize()

                    Button {
                        Task {
                            do {
                                let msg = try await workspace.plugins.syncFeishuCalendar()
                                statusIsError = false
                                statusBannerText = msg
                            } catch {
                                statusIsError = true
                                statusBannerText = error.localizedDescription
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if workspace.plugins.isSyncingPluginID == "feishu_calendar" {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 12))
                            }
                            Text("同步 CalDAV")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                    }
                    .buttonStyle(DesktopQuietButtonStyle())
                    .fixedSize()
                    .disabled(workspace.plugins.isSyncingPluginID == "feishu_calendar")

                    Button {
                        openCreateComposer(start: "\(todayString) 16:00", end: "\(todayString) 16:45")
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                            Text("新建日程")
                        }
                    }
                    .buttonStyle(.desktopProminent)
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - Feishu Calendar Workspace Body

    var feishuCalendarBoard: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 900
            ScrollView(.vertical) {
                let layout = wide
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
                layout {
                    agendaColumn
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    sideColumn
                        .frame(width: wide ? 310 : nil)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    var agendaColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            if creatingEvent {
                newEventComposerCard
            }

            if filteredEvents.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 26))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                    Text("当前筛选范围内暂无飞书日程")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                    Text("可以点击右上角「新建日程」，或在对话中用 /feishu-meet 让 Amber 帮你安排。")
                        .font(.system(size: 12))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 42)
                .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesktopTheme.hairline))
            } else {
                ForEach(filteredEvents) { event in
                    eventCard(event)
                }
            }
        }
    }

    var newEventComposerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("新建飞书日程", systemImage: "calendar.badge.plus")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(DesktopTheme.ink)
                Spacer()
                Button("取消") {
                    withAnimation(.easeOut(duration: 0.18)) { creatingEvent = false }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(DesktopTheme.inkTertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("日程主题")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                TextField("例如：产品迭代评审与排期同步", text: $newSummary)
                    .textFieldStyle(.desktop)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("开始时间 (yyyy-MM-dd HH:mm)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                    TextField("\(todayString) 16:00", text: $newStartTime)
                        .textFieldStyle(.desktop)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("结束时间 (yyyy-MM-dd HH:mm)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                    TextField("\(todayString) 16:45", text: $newEndTime)
                        .textFieldStyle(.desktop)
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("会议地点或链接")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                    TextField("飞书视频会议", text: $newLocation)
                        .textFieldStyle(.desktop)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("参会人（逗号或顿号分隔）")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                    TextField("林夏、周航", text: $newAttendees)
                        .textFieldStyle(.desktop)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("议程与备注")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                TextField("可选会议议程说明", text: $newNotes)
                    .textFieldStyle(.desktop)
            }

            HStack {
                Spacer()
                Button("保存日程") {
                    submitNewEvent()
                }
                .buttonStyle(.desktopProminent)
                .disabled(newSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesktopTheme.honeyEdge, lineWidth: 1))
    }

    func eventCard(_ event: DesktopPluginEventItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Left time column
            VStack(alignment: .leading, spacing: 4) {
                Text(dateBadgeLabel(event.datePrefix))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(event.datePrefix == todayString ? DesktopTheme.accent : DesktopTheme.inkSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        event.datePrefix == todayString ? DesktopTheme.honeySoft : DesktopTheme.paperDeep,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                Text(event.timeRangeText)
                    .font(.system(size: 13, design: .monospaced).weight(.semibold))
                    .foregroundStyle(DesktopTheme.ink)
            }
            .frame(width: 96, alignment: .leading)

            // Middle content
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(event.summary)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(DesktopTheme.ink)
                    Text(event.source == "feishu" ? "飞书日历" : "本地新建")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(DesktopTheme.paperDeep, in: Capsule())
                }

                HStack(spacing: 14) {
                    if !event.location.isEmpty {
                        Label(event.location, systemImage: "video")
                            .font(.system(size: 12))
                            .foregroundStyle(DesktopTheme.inkSecondary)
                    }
                    if !event.attendees.isEmpty {
                        Label(event.attendees.joined(separator: "、"), systemImage: "person.2")
                            .font(.system(size: 12))
                            .foregroundStyle(DesktopTheme.inkSecondary)
                    }
                }

                if !event.notes.isEmpty {
                    Text(event.notes)
                        .font(.system(size: 12.5))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right actions
            HStack(spacing: 6) {
                Button {
                    pushSingleEventToBot(event)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperplane")
                            .font(.system(size: 11))
                        Text("推到群")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                }
                .buttonStyle(DesktopQuietButtonStyle())
                .help("通过飞书机器人将这场会议提醒卡片推送到飞书群")

                Button {
                    sendPromptToChat(event.preparationPrompt)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                        Text("带入对话准备")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                }
                .buttonStyle(DesktopQuietButtonStyle())
                .help("将此日程详情带入对话输入框，由 Amber 协助准备议程或纪要")

                Button {
                    workspace.plugins.deleteCalendarEvent(id: event.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(DesktopQuietButtonStyle())
                .help("删除此日程")
                .accessibilityLabel("删除日程 \(event.summary)")
            }
        }
        .padding(16)
        .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesktopTheme.hairline))
    }


    // MARK: - Right Side Column (Free/Busy & Quick Commands)

    var sideColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Free/Busy Card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("今日空闲时段建议", systemImage: "clock.badge.checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesktopTheme.ink)
                    Spacer()
                    Text(todayString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                }

                let slots = workspace.plugins.todayFreeSlots
                if slots.isEmpty {
                    Text("今日工作时段已排满。")
                        .font(.system(size: 12))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                } else {
                    ForEach(slots) { slot in
                        HStack {
                            Text("\(slot.start)–\(slot.end)")
                                .font(.system(size: 12, design: .monospaced).weight(.medium))
                                .foregroundStyle(DesktopTheme.ink)
                            Text("（\(slot.minutes) 分钟）")
                                .font(.system(size: 11.5))
                                .foregroundStyle(DesktopTheme.inkTertiary)
                            Spacer()
                            Button("预约") {
                                openCreateComposer(
                                    start: "\(todayString) \(slot.start)",
                                    end: "\(todayString) \(slot.end)"
                                )
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DesktopTheme.accent)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(16)
            .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesktopTheme.hairline))

            // Quick AI Actions Card
            VStack(alignment: .leading, spacing: 10) {
                Label("AI 飞书快捷动作", systemImage: "bolt.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesktopTheme.ink)

                ForEach(workspace.plugins.activeSlashCommands.filter { $0.pluginID == "feishu_calendar" }) { cmd in
                    Button {
                        sendPromptToChat(cmd.promptTemplate)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: cmd.symbol)
                                .font(.system(size: 12))
                                .foregroundStyle(DesktopTheme.accent)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cmd.title)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(DesktopTheme.ink)
                                Text(cmd.slash)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(DesktopTheme.inkTertiary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DesktopTheme.inkTertiary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesktopTheme.hairline))
        }
    }

    var genericPluginBoard: some View {
        let pluginCommands = workspace.plugins.activeSlashCommands.filter { $0.pluginID == pluginID }
        return VStack(spacing: 16) {
            Image(systemName: viewEntry?.symbol ?? plugin?.manifest.icon ?? "puzzlepiece.extension")
                .font(.system(size: 32))
                .foregroundStyle(DesktopTheme.accent)
            Text(viewEntry?.title ?? plugin?.manifest.name ?? "插件视图")
                .font(DesktopTheme.serif(size: 20, weight: .semibold))
                .foregroundStyle(DesktopTheme.ink)
            Text(viewEntry?.subtitle.isEmpty == false ? (viewEntry?.subtitle ?? "") : (plugin?.manifest.description ?? ""))
                .font(.system(size: 13))
                .foregroundStyle(DesktopTheme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            if !pluginCommands.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("快捷命令")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                    ForEach(pluginCommands) { cmd in
                        Button {
                            sendPromptToChat(cmd.promptTemplate)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: cmd.symbol)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(DesktopTheme.accent)
                                Text(cmd.title)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(DesktopTheme.ink)
                                Spacer(minLength: 8)
                                Text(cmd.slash)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(DesktopTheme.inkTertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.hairline))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 420)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    func dateBadgeLabel(_ prefix: String) -> String {
        if prefix == todayString { return "今天" }
        if prefix == tomorrowString { return "明天" }
        return prefix
    }

    func openCreateComposer(start: String, end: String) {
        newSummary = ""
        newStartTime = start
        newEndTime = end
        newLocation = "飞书视频会议"
        newAttendees = ""
        newNotes = ""
        withAnimation(.easeOut(duration: 0.18)) {
            creatingEvent = true
        }
    }

    func submitNewEvent() {
        let attendees = newAttendees
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let summary = newSummary
        let start = newStartTime
        let end = newEndTime
        let location = newLocation
        let notes = newNotes
        Task {
            do {
                _ = try await workspace.plugins.createCalendarEvent(
                    summary: summary,
                    startTime: start,
                    endTime: end,
                    location: location,
                    attendees: attendees,
                    notes: notes
                )
                creatingEvent = false
                statusIsError = false
                statusBannerText = "已创建日程「\(summary)」。"
            } catch {
                statusIsError = true
                statusBannerText = error.localizedDescription
            }
        }
    }

    func pushSingleEventToBot(_ event: DesktopPluginEventItem) {
        Task {
            do {
                let body = """
                **会议主题**：\(event.summary)
                **会议时间**：\(event.startTime) – \(event.endTime)
                **会议地点**：\(event.location)
                \(event.notes.isEmpty ? "" : "**议程备注**：\(event.notes)")
                """
                let item = try await workspace.plugins.sendFeishuBotMessage(
                    title: "📅 飞书会议提醒：\(event.summary)",
                    content: body
                )
                statusIsError = false
                statusBannerText = "已通过飞书机器人推送会议提醒卡片（目标：\(item.target)）。"
            } catch {
                statusIsError = true
                statusBannerText = error.localizedDescription
            }
        }
    }

    func pushTodayScheduleToFeishuBot() {
        isRunningBotAction = true
        Task {
            defer { isRunningBotAction = false }
            do {
                let lines = todayEvents.map { "• **\($0.timeRangeText)** \($0.summary)（\($0.location)）" }
                let content = lines.isEmpty
                    ? "今日暂无飞书日程安排。"
                    : lines.joined(separator: "\n")
                let item = try await workspace.plugins.sendFeishuBotMessage(
                    title: "📅 今日飞书日程汇总 (\(todayString))",
                    content: content
                )
                statusIsError = false
                statusBannerText = "已向飞书推送今日日程汇总卡片（目标：\(item.target)）。"
            } catch {
                statusIsError = true
                statusBannerText = error.localizedDescription
            }
        }
    }
}
