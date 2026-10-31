import SwiftUI

/// Obsidian-inspired Workspace Leaf view for active plugins (such as the built-in Feishu Calendar board)
/// plus the global `⌘K` Command Palette (`DesktopCommandPaletteView`).
struct DesktopPluginWorkspaceView: View {
    @Bindable var workspace: DesktopWorkspace
    let pluginID: String
    let viewID: String
    var onFocusComposer: () -> Void = {}

    @State private var dateFilter = 0
    @State private var creatingEvent = false
    @State private var newSummary = ""
    @State private var newStartTime = ""
    @State private var newEndTime = ""
    @State private var newLocation = "飞书视频会议"
    @State private var newAttendees = ""
    @State private var newNotes = ""

    // Feishu Bot Studio states
    @State private var botComposerTab = 0 // 0 = 消息卡片, 1 = 云文档读写, 2 = 群聊记录
    @State private var botTitle = "Amber 进展同步卡片"
    @State private var botContent = ""
    @State private var botReceiveID = ""
    @State private var botDocInput = ""
    @State private var botNewDocTitle = ""
    @State private var botNewDocContent = ""
    @State private var botChatID = ""
    @State private var isRunningBotAction = false

    @State private var statusBannerText: String?
    @State private var statusIsError = false

    private var isFeishuBotView: Bool {
        pluginID == "feishu_calendar" && viewID == "bot_studio"
    }

    private var plugin: DesktopInstalledPlugin? {
        workspace.plugins.plugins.first { $0.id == pluginID }
    }

    private var viewEntry: DesktopPluginWorkspaceViewEntry? {
        workspace.plugins.activeWorkspaceViews.first { $0.pluginID == pluginID && $0.viewID == viewID }
    }

    private var todayString: String {
        workspace.plugins.todayDateString
    }

    private var tomorrowString: String {
        workspace.plugins.tomorrowDateString
    }

    private var allEvents: [DesktopPluginEventItem] {
        workspace.plugins.calendarEvents
    }

    private var todayEvents: [DesktopPluginEventItem] {
        allEvents.filter { $0.datePrefix == todayString }
    }

    private var tomorrowEvents: [DesktopPluginEventItem] {
        allEvents.filter { $0.datePrefix == tomorrowString }
    }

    private var filteredEvents: [DesktopPluginEventItem] {
        switch dateFilter {
        case 1: todayEvents
        case 2: tomorrowEvents
        default: allEvents
        }
    }

    var body: some View {
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

    // MARK: - Header

    private var header: some View {
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

    private var feishuCalendarBoard: some View {
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

    private var agendaColumn: some View {
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

    private var newEventComposerCard: some View {
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

    private func eventCard(_ event: DesktopPluginEventItem) -> some View {
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

    // MARK: - Feishu Bot Studio Workspace Body

    private var feishuBotBoard: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 900
            ScrollView(.vertical) {
                let layout = wide
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
                layout {
                    botMainColumn
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    botSideColumn
                        .frame(width: wide ? 310 : nil)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var botMainColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            botActionComposerCard

            HStack {
                Label("机器人动态与消息记录", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(DesktopTheme.ink)
                Spacer()
                Text("共 \(workspace.plugins.botActivities.count) 条")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(DesktopTheme.inkTertiary)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)

            if workspace.plugins.botActivities.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "paperplane.circle")
                        .font(.system(size: 26))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                    Text("暂无飞书机器人操作记录")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                    Text("可在上方发送群消息卡片、读取飞书云文档或拉取群聊历史。")
                        .font(.system(size: 12))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesktopTheme.hairline))
            } else {
                ForEach(workspace.plugins.botActivities) { item in
                    botActivityCard(item)
                }
            }
        }
    }

    private var botActionComposerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Label("飞书机器人操作台", systemImage: "paperplane.circle.fill")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(DesktopTheme.ink)
                DesktopSegmented(
                    options: [
                        (0, "发送消息卡片"),
                        (1, "云文档读写"),
                        (2, "拉取群聊记录")
                    ],
                    selection: $botComposerTab
                )
                Spacer()
            }

            if botComposerTab == 0 {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("卡片标题")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DesktopTheme.inkSecondary)
                        TextField("例如：Amber 今日研发进展", text: $botTitle)
                            .textFieldStyle(.desktop)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("目标群聊 / 用户 ID（留空默认走群 Webhook）")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DesktopTheme.inkSecondary)
                        TextField("可选 oc_xxx 或 ou_xxx", text: $botReceiveID)
                            .textFieldStyle(.desktop)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("卡片正文（支持飞书 Markdown）")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                    TextField("输入要推送到飞书的通知要点、会议结论或日报内容…", text: $botContent)
                        .textFieldStyle(.desktop)
                }

                HStack(spacing: 10) {
                    Button("填入今日会议汇总") {
                        let lines = todayEvents.map { "• **\($0.timeRangeText)** \($0.summary)（\($0.location)）" }
                        botTitle = "📅 今日飞书会议提醒 (\(todayString))"
                        botContent = lines.isEmpty
                            ? "今日暂无排定会议，可集中处理研发任务。"
                            : lines.joined(separator: "\n")
                    }
                    .buttonStyle(DesktopQuietButtonStyle())
                    .font(.system(size: 12))

                    Spacer()

                    Button {
                        submitBotMessage()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 11))
                            Text("发送飞书卡片")
                        }
                    }
                    .buttonStyle(.desktopProminent)
                    .disabled(isRunningBotAction || botContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if botComposerTab == 1 {
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("读取飞书云文档（粘贴文档链接或 document_id）")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DesktopTheme.inkSecondary)
                        TextField("https://xxx.feishu.cn/docx/doxcn... 或 doxcn_xxx", text: $botDocInput)
                            .textFieldStyle(.desktop)
                    }
                    Button("读取文档") {
                        submitReadDoc()
                    }
                    .buttonStyle(.desktopProminent)
                    .disabled(isRunningBotAction || botDocInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Rectangle().fill(DesktopTheme.hairline).frame(height: 1)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("新建飞书云文档标题")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DesktopTheme.inkSecondary)
                        TextField("例如：产品周会纪要与行动项", text: $botNewDocTitle)
                            .textFieldStyle(.desktop)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("初始摘要或正文")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DesktopTheme.inkSecondary)
                        TextField("可选初始文档正文…", text: $botNewDocContent)
                            .textFieldStyle(.desktop)
                    }
                }

                HStack {
                    Spacer()
                    Button("创建飞书云文档") {
                        submitCreateDoc()
                    }
                    .buttonStyle(.desktopProminent)
                    .disabled(isRunningBotAction || botNewDocTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("飞书群聊 ID (chat_id，留空则使用插件默认接收群 ID)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DesktopTheme.inkSecondary)
                        TextField("例如：oc_a1b2c3d4e5f6...", text: $botChatID)
                            .textFieldStyle(.desktop)
                    }
                    Button("拉取群聊记录") {
                        submitFetchChatHistory()
                    }
                    .buttonStyle(.desktopProminent)
                    .disabled(isRunningBotAction)
                }
            }
        }
        .padding(16)
        .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesktopTheme.hairline))
    }

    private func botActivityCard(_ item: DesktopPluginBotActivityItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(item.kindLabel)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(DesktopTheme.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 5))

                Text(String(item.timestamp.suffix(5)))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DesktopTheme.inkTertiary)
            }
            .frame(width: 96, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesktopTheme.ink)
                    Text(item.channel == "webhook" ? "Webhook" : (item.channel == "openapi" ? "OpenAPI" : "本地记录"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(DesktopTheme.paperDeep, in: Capsule())
                }

                Text(item.summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Label(item.target, systemImage: "target")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                    if let docURL = item.documentURL, !docURL.isEmpty {
                        Text(docURL)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(DesktopTheme.accent)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Button {
                    sendPromptToChat(item.followUpPrompt)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                        Text("带入对话处理")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                }
                .buttonStyle(DesktopQuietButtonStyle())

                Button {
                    workspace.plugins.deleteBotActivity(id: item.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(DesktopQuietButtonStyle())
                .accessibilityLabel("删除记录 \(item.title)")
            }
        }
        .padding(16)
        .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesktopTheme.hairline))
    }

    private var botSideColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Label("飞书机器人通道状态", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesktopTheme.ink)

                let webhookSet = !workspace.plugins.settingValue(pluginID: "feishu_calendar", key: "bot_webhook_url")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let appSet = !workspace.plugins.settingValue(pluginID: "feishu_calendar", key: "app_id")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                HStack {
                    Text("群自定义 Webhook")
                        .font(.system(size: 12))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                    Spacer()
                    Text(webhookSet ? "已配置" : "未配置")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(webhookSet ? DesktopTheme.accent : DesktopTheme.inkTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    Text("自建应用 OpenAPI")
                        .font(.system(size: 12))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                    Spacer()
                    Text(appSet ? "已配置" : "未配置")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(appSet ? DesktopTheme.accent : DesktopTheme.inkTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))

                Text("可在「设置 → 插件 → 飞书 → 飞书机器人 (Bot)」中配置群 Webhook 地址或自建应用 App ID / Secret。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesktopTheme.hairline))

            VStack(alignment: .leading, spacing: 10) {
                Label("AI 机器人快捷动作", systemImage: "bolt.horizontal")
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

    // MARK: - Right Side Column (Free/Busy & Quick Commands)

    private var sideColumn: some View {
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

    private var genericPluginBoard: some View {
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

    private func dateBadgeLabel(_ prefix: String) -> String {
        if prefix == todayString { return "今天" }
        if prefix == tomorrowString { return "明天" }
        return prefix
    }

    private func openCreateComposer(start: String, end: String) {
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

    private func submitNewEvent() {
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

    private func pushSingleEventToBot(_ event: DesktopPluginEventItem) {
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

    private func pushTodayScheduleToFeishuBot() {
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

    private func submitBotMessage() {
        let title = botTitle
        let content = botContent
        let receiveID = botReceiveID
        isRunningBotAction = true
        Task {
            defer { isRunningBotAction = false }
            do {
                let item = try await workspace.plugins.sendFeishuBotMessage(
                    title: title,
                    content: content,
                    msgType: "interactive",
                    receiveID: receiveID
                )
                botContent = ""
                statusIsError = false
                statusBannerText = "已发送飞书消息卡片「\(item.title)」（目标：\(item.target)）。"
            } catch {
                statusIsError = true
                statusBannerText = error.localizedDescription
            }
        }
    }

    private func submitReadDoc() {
        let input = botDocInput
        isRunningBotAction = true
        Task {
            defer { isRunningBotAction = false }
            do {
                let (_, title, _, _) = try await workspace.plugins.readFeishuDocument(documentInput: input)
                botDocInput = ""
                statusIsError = false
                statusBannerText = "已读取飞书云文档「\(title)」，可点击下方卡片「带入对话处理」。"
            } catch {
                statusIsError = true
                statusBannerText = error.localizedDescription
            }
        }
    }

    private func submitCreateDoc() {
        let title = botNewDocTitle
        let content = botNewDocContent
        isRunningBotAction = true
        Task {
            defer { isRunningBotAction = false }
            do {
                let item = try await workspace.plugins.createFeishuDocument(title: title, content: content)
                botNewDocTitle = ""
                botNewDocContent = ""
                statusIsError = false
                statusBannerText = "已创建飞书云文档「\(item.title)」（\(item.target)）。"
            } catch {
                statusIsError = true
                statusBannerText = error.localizedDescription
            }
        }
    }

    private func submitFetchChatHistory() {
        let chatID = botChatID
        isRunningBotAction = true
        Task {
            defer { isRunningBotAction = false }
            do {
                let (messages, item) = try await workspace.plugins.fetchFeishuChatHistory(chatID: chatID)
                statusIsError = false
                statusBannerText = "已拉取 \(item.target) 共 \(messages.count) 条消息，可一键带入对话生成纪要。"
            } catch {
                statusIsError = true
                statusBannerText = error.localizedDescription
            }
        }
    }

    private func sendPromptToChat(_ prompt: String) {
        workspace.openChatSurface()
        workspace.draft = prompt
        workspace.agentTasks.toolsEnabled = true
        onFocusComposer()
    }
}

// MARK: - Obsidian-style ⌘K Command Palette

struct DesktopCommandPaletteView: View {
    @Bindable var workspace: DesktopWorkspace
    var onDismiss: () -> Void
    var onFocusComposer: () -> Void = {}

    struct PaletteItem: Identifiable {
        let id: String
        let category: String
        let title: String
        let subtitle: String
        let badge: String?
        let symbol: String
        let action: () -> Void
    }

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private var items: [PaletteItem] {
        var all: [PaletteItem] = []

        for cmd in workspace.plugins.activeSlashCommands {
            all.append(PaletteItem(
                id: "cmd.\(cmd.id)",
                category: "插件指令",
                title: cmd.title,
                subtitle: cmd.pluginName,
                badge: cmd.slash,
                symbol: cmd.symbol
            ) {
                workspace.openChatSurface()
                workspace.draft = cmd.promptTemplate
                workspace.agentTasks.toolsEnabled = true
                onDismiss()
                onFocusComposer()
            })
        }

        for view in workspace.plugins.activeWorkspaceViews {
            all.append(PaletteItem(
                id: "view.\(view.id)",
                category: "工作区视图",
                title: "打开\(view.title)视图",
                subtitle: view.subtitle,
                badge: view.badgeCount > 0 ? "\(view.badgeCount) 项" : nil,
                symbol: view.symbol
            ) {
                workspace.openPluginView(pluginID: view.pluginID, viewID: view.viewID)
                onDismiss()
            })
        }

        if workspace.activeSurface != .chat {
            all.append(PaletteItem(
                id: "nav.chat",
                category: "工作区视图",
                title: "返回当前对话",
                subtitle: workspace.selectedConversationTitle,
                badge: nil,
                symbol: "bubble.left.and.bubble.right"
            ) {
                workspace.openChatSurface()
                onDismiss()
            })
        }

        if workspace.scheduler != nil && workspace.plugins.isCoreEnabled(.taskBoard) {
            all.append(PaletteItem(
                id: "nav.task_board",
                category: "工作区视图",
                title: "打开任务看板",
                subtitle: "查看定时任务与 Claude Code / Codex 会话",
                badge: nil,
                symbol: "clock"
            ) {
                workspace.showsTaskBoard = true
                onDismiss()
            })
        }

        all.append(PaletteItem(
            id: "act.new_chat",
            category: "会话动作",
            title: "新建对话",
            subtitle: "创建一条空白会话并聚焦输入框",
            badge: "⌘N",
            symbol: "square.and.pencil"
        ) {
            workspace.createConversation()
            onDismiss()
            onFocusComposer()
        })

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { item in
            item.title.lowercased().contains(q)
                || item.subtitle.lowercased().contains(q)
                || (item.badge?.lowercased().contains(q) ?? false)
                || item.category.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesktopTheme.accent)
                TextField("输入插件命令、斜杠指令（如 /feishu-today）或视图名称…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(DesktopTheme.ink)
                    .focused($searchFocused)
                    .onSubmit {
                        let list = items
                        if list.indices.contains(selectedIndex) {
                            list[selectedIndex].action()
                        }
                    }
                Button {
                    onDismiss()
                } label: {
                    Text("ESC")
                        .font(.system(size: 10.5, design: .monospaced).weight(.medium))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("关闭命令面板")
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(DesktopTheme.card)

            Rectangle().fill(DesktopTheme.hairline).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    let list = items
                    if list.isEmpty {
                        Text("没有匹配的插件命令或视图")
                            .font(.system(size: 13))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 36)
                    } else {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                            Button {
                                item.action()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.symbol)
                                        .font(.system(size: 13))
                                        .foregroundStyle(index == selectedIndex ? DesktopTheme.accent : DesktopTheme.inkSecondary)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(item.title)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(DesktopTheme.ink)
                                            Text(item.category)
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(DesktopTheme.inkTertiary)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(DesktopTheme.paperDeep, in: Capsule())
                                        }
                                        if !item.subtitle.isEmpty {
                                            Text(item.subtitle)
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(DesktopTheme.inkTertiary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if let badge = item.badge {
                                        Text(badge)
                                            .font(.system(size: 11.5, design: .monospaced).weight(.medium))
                                            .foregroundStyle(DesktopTheme.accent)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 5))
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background {
                                    if index == selectedIndex {
                                        DesktopTheme.glow(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(10)
            }
            Rectangle().fill(DesktopTheme.hairline).frame(height: 1)
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    Text("↑↓")
                        .font(.system(size: 10.5, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 4.5).padding(.vertical, 1)
                        .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DesktopTheme.hairline))
                    Text("选择")
                }
                HStack(spacing: 4) {
                    Text("↩")
                        .font(.system(size: 10.5, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 4.5).padding(.vertical, 1)
                        .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DesktopTheme.hairline))
                    Text("执行指令或切换视图")
                }
                Spacer()
                Text("Amber Command Palette")
                    .font(.system(size: 11, design: .monospaced))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(DesktopTheme.inkTertiary)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(DesktopTheme.paperSide)
        }
        .frame(width: 540, height: 520)
        .background(DesktopTheme.paper)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onKeyPress(.upArrow) {
            let count = items.count
            guard count > 0 else { return .ignored }
            selectedIndex = (selectedIndex - 1 + count) % count
            return .handled
        }
        .onKeyPress(.downArrow) {
            let count = items.count
            guard count > 0 else { return .ignored }
            selectedIndex = (selectedIndex + 1) % count
            return .handled
        }
        .onKeyPress(.return) {
            let list = items
            guard list.indices.contains(selectedIndex) else { return .ignored }
            list[selectedIndex].action()
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }
}
