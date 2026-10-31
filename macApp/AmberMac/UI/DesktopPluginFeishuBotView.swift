import SwiftUI

extension DesktopPluginWorkspaceView {
    // MARK: - Feishu Bot Studio Workspace Body

    var feishuBotBoard: some View {
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

    var botMainColumn: some View {
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

    var botActionComposerCard: some View {
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

    func botActivityCard(_ item: DesktopPluginBotActivityItem) -> some View {
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

    var botSideColumn: some View {
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


    func submitBotMessage() {
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

    func submitReadDoc() {
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

    func submitCreateDoc() {
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

    func submitFetchChatHistory() {
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

    func sendPromptToChat(_ prompt: String) {
        workspace.openChatSurface()
        workspace.draft = prompt
        workspace.agentTasks.toolsEnabled = true
        onFocusComposer()
    }
}

