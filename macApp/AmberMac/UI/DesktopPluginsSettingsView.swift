import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Obsidian-style plugin management pane inside Settings:
/// - Left sidebar: Core Plugins (核心插件) + Installed Extension Plugins (扩展插件) + Import / Reload / Remove toolbar.
/// - Right detail: Toggle, Feishu Calendar sync & view jump, capability boundaries, settings schema form, and registered AI tools / UI slots.
struct DesktopPluginsSettingsView: View {
    @Bindable var plugins: DesktopPluginStore
    var workspace: DesktopWorkspace?

    enum Selection: Hashable {
        case core(DesktopCorePlugin)
        case ext(String)
    }

    @State private var selection: Selection = .ext("feishu_calendar")
    @State private var draftSettings: [String: String] = [:]
    @State private var feishuSettingsTab: Int = 0 // 0 = 日历 (CalDAV), 1 = 机器人 (Bot)
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var confirmsDeletePluginID: String?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 230, idealWidth: 245, maxWidth: 265, maxHeight: .infinity)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            ensureValidSelection()
            loadDraftSettings()
        }
        .onChange(of: selection) { _, _ in
            statusMessage = nil
            statusIsError = false
            loadDraftSettings()
        }
        .onChange(of: plugins.plugins.map(\.id)) { _, _ in
            ensureValidSelection()
            loadDraftSettings()
        }
        .confirmationDialog(
            "移除这个扩展插件？",
            isPresented: Binding(
                get: { confirmsDeletePluginID != nil },
                set: { if !$0 { confirmsDeletePluginID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移除插件", role: .destructive) {
                if let id = confirmsDeletePluginID {
                    removePlugin(id: id)
                }
                confirmsDeletePluginID = nil
            }
            Button("取消", role: .cancel) { confirmsDeletePluginID = nil }
        } message: {
            Text("插件目录、配置与保存在钥匙串中的凭据将被一并移除。")
        }
    }

    // MARK: - Left Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        sectionHeader("扩展插件", count: plugins.plugins.count)
                        ForEach(plugins.plugins) { plugin in
                            DesktopSelectableRow(selected: selection == .ext(plugin.id), action: {
                                selection = .ext(plugin.id)
                            }) {
                                HStack(spacing: 9) {
                                    Image(systemName: plugin.manifest.icon)
                                        .font(.system(size: 13))
                                        .foregroundStyle(plugin.enabled ? DesktopTheme.accent : DesktopTheme.inkTertiary)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 5) {
                                            Text(plugin.manifest.name)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(DesktopTheme.ink)
                                                .lineLimit(1)
                                            if plugin.isBuiltIn {
                                                Text("内置")
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundStyle(DesktopTheme.inkTertiary)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(DesktopTheme.paperDeep, in: Capsule())
                                            }
                                        }
                                        Text("v\(plugin.manifest.version) · \(plugin.manifest.tools.count) 个工具")
                                            .font(.system(size: 11))
                                            .foregroundStyle(DesktopTheme.inkTertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    Circle()
                                        .fill(plugin.enabled ? DesktopTheme.accent : DesktopTheme.inkTertiary.opacity(0.35))
                                        .frame(width: 7, height: 7)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        sectionHeader("核心插件", count: DesktopCorePlugin.allCases.count)
                        ForEach(DesktopCorePlugin.allCases) { core in
                            let enabled = plugins.isCoreEnabled(core)
                            DesktopSelectableRow(selected: selection == .core(core), action: {
                                selection = .core(core)
                            }) {
                                HStack(spacing: 9) {
                                    Image(systemName: core.symbol)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(enabled ? DesktopTheme.inkSecondary : DesktopTheme.inkTertiary)
                                        .frame(width: 18)
                                    Text(core.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(DesktopTheme.ink)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Circle()
                                        .fill(enabled ? DesktopTheme.accent : DesktopTheme.inkTertiary.opacity(0.35))
                                        .frame(width: 7, height: 7)
                                }
                            }
                        }
                    }
                }
                .padding(10)
            }

            Rectangle().fill(DesktopTheme.hairline).frame(height: 1)
            HStack(spacing: 4) {
                Button(action: presentImportPanel) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("导入插件")
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                }
                .buttonStyle(DesktopQuietButtonStyle())
                .help("从包含 plugin.json 的文件夹或文件导入扩展插件")
                .accessibilityLabel("导入扩展插件")

                if case .ext(let id) = selection,
                   let plugin = plugins.plugins.first(where: { $0.id == id }),
                   !plugin.isBuiltIn {
                    Button {
                        confirmsDeletePluginID = id
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(DesktopQuietButtonStyle())
                    .help("移除当前选中的自定义插件")
                    .accessibilityLabel("移除自定义插件")
                }

                Spacer()

                Button {
                    plugins.reload()
                    loadDraftSettings()
                    setStatus("已重新扫描插件目录", isError: false)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(DesktopQuietButtonStyle())
                .help("重新加载插件目录")
                .accessibilityLabel("重新加载插件目录")
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
        }
        .background(DesktopTheme.paperSide)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesktopTheme.inkTertiary)
            Text("\(count)")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(DesktopTheme.inkTertiary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 2)
    }

    // MARK: - Right Detail

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let loadError = plugins.loadError {
                    statusBanner(text: loadError, isError: true)
                }
                if let statusMessage {
                    statusBanner(text: statusMessage, isError: statusIsError)
                }

                switch selection {
                case .core(let core):
                    coreDetail(core)
                case .ext(let id):
                    if let plugin = plugins.plugins.first(where: { $0.id == id }) {
                        extensionDetail(plugin)
                    } else {
                        ContentUnavailableView("选择左侧插件", systemImage: "puzzlepiece.extension")
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func coreDetail(_ core: DesktopCorePlugin) -> some View {
        let enabled = plugins.isCoreEnabled(core)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: core.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(DesktopTheme.accent)
                    .frame(width: 36, height: 36)
                    .background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(core.title)
                            .font(DesktopTheme.serif(size: 18, weight: .semibold))
                            .foregroundStyle(DesktopTheme.ink)
                        Text("核心插件")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DesktopTheme.inkSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(DesktopTheme.paperDeep, in: Capsule())
                    }
                    Text(enabled ? "已启用 · 在工作台与智能体工具链中生效" : "已停用 · 入口与对应模型工具已隐藏")
                        .font(.system(size: 12))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                }
                Spacer(minLength: 12)
                Button {
                    plugins.setCoreEnabled(core, enabled: !enabled)
                } label: {
                    HStack(spacing: 7) {
                        Text(enabled ? "已启用" : "已停用")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(enabled ? DesktopTheme.inkSecondary : DesktopTheme.inkTertiary)
                        DesktopSwitch(isOn: enabled)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                }
                .buttonStyle(DesktopQuietButtonStyle())
                .accessibilityLabel("启用 \(core.title)")
                .accessibilityValue(enabled ? "已启用" : "已停用")
            }
            .padding(14)
            .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.hairline))

            VStack(alignment: .leading, spacing: 8) {
                Text("功能说明")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                Text(core.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(DesktopTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.hairline))

            if !core.governedToolNames.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("关联的智能体工具")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                    Text("停用此核心插件后，以下工具将自动从对话与定时任务工具列表中移除：")
                        .font(.system(size: 12))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                    FlowTagRow(items: Array(core.governedToolNames).sorted())
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.hairline))
            }
        }
    }

    private func extensionDetail(_ plugin: DesktopInstalledPlugin) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header Card
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: plugin.manifest.icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(DesktopTheme.accent)
                        .frame(width: 36, height: 36)
                        .background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(plugin.manifest.name)
                                .font(DesktopTheme.serif(size: 18, weight: .semibold))
                                .foregroundStyle(DesktopTheme.ink)
                            Text("v\(plugin.manifest.version)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DesktopTheme.inkTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DesktopTheme.paperDeep, in: Capsule())
                            Text(plugin.isBuiltIn ? "官方内置" : "扩展插件")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(DesktopTheme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DesktopTheme.honeySoft, in: Capsule())
                        }
                        Text("插件 ID：\(plugin.id) · 协议：\(plugin.manifest.schema)")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                    }
                    Spacer(minLength: 12)
                    Button {
                        do {
                            try plugins.setPluginEnabled(plugin.id, enabled: !plugin.enabled)
                        } catch {
                            setStatus(error.localizedDescription, isError: true)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Text(plugin.enabled ? "已启用" : "已停用")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(plugin.enabled ? DesktopTheme.inkSecondary : DesktopTheme.inkTertiary)
                            DesktopSwitch(isOn: plugin.enabled)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                    }
                    .buttonStyle(DesktopQuietButtonStyle())
                    .accessibilityLabel("启用 \(plugin.manifest.name)")
                    .accessibilityValue(plugin.enabled ? "已启用" : "已停用")
                }

                Text(plugin.manifest.description)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if plugin.id == "feishu_calendar" {
                    HStack(spacing: 8) {
                        Label("日历：\(plugins.feishuCalendarConnectionBadge)", systemImage: "calendar")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(plugins.hasFeishuRemoteCredentials ? DesktopTheme.accent : DesktopTheme.inkSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(plugins.hasFeishuRemoteCredentials ? DesktopTheme.honeySoft : DesktopTheme.paperDeep, in: Capsule())

                        Label("机器人：\(plugins.feishuBotConnectionBadge)", systemImage: "paperplane.circle")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(plugins.hasFeishuBotCredentials ? DesktopTheme.accent : DesktopTheme.inkSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(plugins.hasFeishuBotCredentials ? DesktopTheme.honeySoft : DesktopTheme.paperDeep, in: Capsule())

                        Spacer()
                        Text("\(plugins.calendarEvents.count) 项日程 · \(plugins.botActivities.count) 条机器人动态")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(DesktopTheme.inkTertiary)
                    }

                    HStack(spacing: 10) {
                        Button {
                            syncFeishu()
                        } label: {
                            HStack(spacing: 6) {
                                if plugins.isSyncingPluginID == "feishu_calendar" {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 12))
                                }
                                Text("同步飞书日历")
                                    .font(.system(size: 12.5, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.hairlineStrong))
                        }
                        .buttonStyle(.plain)
                        .disabled(!plugin.enabled || plugins.isSyncingPluginID == "feishu_calendar")

                        Button {
                            sendTestBotCard()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "paperplane")
                                    .font(.system(size: 11.5))
                                Text("测试飞书机器人")
                                    .font(.system(size: 12.5, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.hairlineStrong))
                        }
                        .buttonStyle(.plain)
                        .disabled(!plugin.enabled)

                        if let workspace, plugin.enabled {
                            Button("打开日历") {
                                workspace.openPluginView(pluginID: plugin.id, viewID: "calendar_board")
                                NSApp.windows.first { $0.title == "Amber" || $0.identifier?.rawValue.contains("main") == true }?
                                    .makeKeyAndOrderFront(nil)
                                setStatus("已在主窗口打开飞书日历视图。", isError: false)
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(DesktopTheme.accent)

                            Button("打开机器人") {
                                workspace.openPluginView(pluginID: plugin.id, viewID: "bot_studio")
                                NSApp.windows.first { $0.title == "Amber" || $0.identifier?.rawValue.contains("main") == true }?
                                    .makeKeyAndOrderFront(nil)
                                setStatus("已在主窗口打开飞书机器人工作台。", isError: false)
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(DesktopTheme.accent)
                        }
                        Spacer()
                    }
                    if let syncStatus = plugin.lastSyncStatus {
                        Text(syncStatus)
                            .font(.system(size: 12))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.hairline))

            // Settings Schema Card
            if !plugin.manifest.settingsSchema.isEmpty {
                let hasFeishuGroups = plugin.id == "feishu_calendar"
                let visibleFields: [DesktopPluginSettingField] = {
                    guard hasFeishuGroups else { return plugin.manifest.settingsSchema }
                    let targetGroup = feishuSettingsTab == 0 ? "calendar" : "bot"
                    return plugin.manifest.settingsSchema.filter { $0.group == targetGroup }
                }()

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        Text("插件配置")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DesktopTheme.ink)
                        if hasFeishuGroups {
                            DesktopSegmented(
                                options: [
                                    (0, "日历 (CalDAV)"),
                                    (1, "飞书机器人 (Bot)")
                                ],
                                selection: $feishuSettingsTab
                            )
                        }
                        Spacer()
                        Label("敏感凭据独立存入系统钥匙串", systemImage: "key.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                    }

                    if hasFeishuGroups {
                        Text(
                            feishuSettingsTab == 0
                                ? "在「飞书客户端 → 设置 → 日历 → CalDAV 同步」中一键生成服务器地址、用户名与密码即可直连同步个人日历，无需企业管理员审批。"
                                : "既可填写「群自定义机器人 Webhook」向群内快速发消息卡片，也可填写企业自建应用「App ID + App Secret」调用完整飞书 OpenAPI（发消息、拉取群记录、读写云文档）。"
                        )
                        .font(.system(size: 11.5))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 7))
                    }

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 14, alignment: .top),
                            GridItem(.flexible(), spacing: 14, alignment: .top)
                        ],
                        alignment: .leading,
                        spacing: 10
                    ) {
                        ForEach(visibleFields) { field in
                            settingFieldRow(field)
                        }
                    }

                    HStack(spacing: 10) {
                        Button("保存插件配置") {
                            saveDraftSettings(for: plugin.id)
                        }
                        .buttonStyle(.desktopProminent)

                        if plugin.id == "feishu_calendar" {
                            Button {
                                if saveDraftSettings(for: plugin.id) {
                                    if feishuSettingsTab == 0 {
                                        syncFeishu()
                                    } else {
                                        sendTestBotCard()
                                    }
                                }
                            } label: {
                                Text(feishuSettingsTab == 0 ? "保存并同步 CalDAV 日历" : "保存并发送机器人测试消息")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(DesktopTheme.inkSecondary)
                                    .padding(.horizontal, 12)
                                    .frame(height: 28)
                                    .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.hairlineStrong))
                            }
                            .buttonStyle(.plain)
                            .disabled(!plugin.enabled)
                        }
                        Spacer()
                    }
                    .padding(.top, 2)
                }
                .padding(14)
                .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.hairline))
            }

            // Capabilities & Sandbox Boundaries
            VStack(alignment: .leading, spacing: 10) {
                Text("权限与沙箱边界")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesktopTheme.ink)
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("允许访问的 HTTPS 域名")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                        if plugin.manifest.capabilities.networkDomains.isEmpty {
                            Text("无外部网络权限（纯本地沙箱）")
                                .font(.system(size: 12))
                                .foregroundStyle(DesktopTheme.inkSecondary)
                        } else {
                            FlowTagRow(items: plugin.manifest.capabilities.networkDomains)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("工作区写入范围")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                        if plugin.manifest.capabilities.workspaceWritePrefixes.isEmpty {
                            Text("禁止直接写入会话工作区")
                                .font(.system(size: 12))
                                .foregroundStyle(DesktopTheme.inkSecondary)
                        } else {
                            FlowTagRow(items: plugin.manifest.capabilities.workspaceWritePrefixes)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.hairline))

            // Tools & UI Slots Card
            VStack(alignment: .leading, spacing: 12) {
                Text("提供的智能体工具与界面槽位")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesktopTheme.ink)

                if !plugin.manifest.tools.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AI 工具（\(plugin.manifest.tools.count)）")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                        ForEach(plugin.manifest.tools) { tool in
                            HStack(alignment: .top, spacing: 10) {
                                Text(plugin.qualifiedToolName(tool.name))
                                    .font(.system(size: 12, design: .monospaced).weight(.medium))
                                    .foregroundStyle(DesktopTheme.ink)
                                    .textSelection(.enabled)
                                Spacer(minLength: 8)
                                Text(effectBadgeText(tool.effect))
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(tool.effect == .sideEffect ? DesktopTheme.accent : DesktopTheme.inkSecondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        tool.effect == .sideEffect ? DesktopTheme.honeySoft : DesktopTheme.paperDeep,
                                        in: Capsule()
                                    )
                            }
                            Text(tool.description)
                                .font(.system(size: 12))
                                .foregroundStyle(DesktopTheme.inkTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 4)
                        }
                    }
                }

                if !plugin.manifest.ui.commands.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("斜杠命令与命令面板（\(plugin.manifest.ui.commands.count)）")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                        ForEach(plugin.manifest.ui.commands) { cmd in
                            HStack(spacing: 8) {
                                Text(cmd.slash)
                                    .font(.system(size: 12, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(DesktopTheme.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 5))
                                Text(cmd.title)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(DesktopTheme.inkSecondary)
                                Spacer()
                            }
                        }
                    }
                }

                if !plugin.manifest.ui.inspectorCards.isEmpty || !plugin.manifest.ui.workspaceViews.isEmpty {
                    Divider()
                    HStack(spacing: 16) {
                        if let view = plugin.manifest.ui.workspaceViews.first {
                            Label("主视图：\(view.title)", systemImage: view.symbol)
                                .font(.system(size: 12))
                                .foregroundStyle(DesktopTheme.inkSecondary)
                        }
                        if let card = plugin.manifest.ui.inspectorCards.first {
                            Label("右侧栏卡片：\(card.title)", systemImage: card.symbol)
                                .font(.system(size: 12))
                                .foregroundStyle(DesktopTheme.inkSecondary)
                        }
                    }
                }
            }
            .padding(16)
            .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.hairline))
        }
    }

    @ViewBuilder
    private func settingFieldRow(_ field: DesktopPluginSettingField) -> some View {
        let binding = Binding<String>(
            get: { draftSettings[field.key] ?? field.defaultValue },
            set: { draftSettings[field.key] = $0 }
        )
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(field.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesktopTheme.ink)
                    .lineLimit(1)
                if field.kind == .secret {
                    Text("钥匙串加密")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(DesktopTheme.paperDeep, in: Capsule())
                }
            }
            .frame(height: 18)
            if field.kind == .boolean {
                Toggle(field.title, isOn: Binding(
                    get: { (draftSettings[field.key] ?? field.defaultValue).lowercased() == "true" },
                    set: { draftSettings[field.key] = $0 ? "true" : "false" }
                ))
                .font(.system(size: 12))
            } else if field.kind == .secret {
                SecureField(field.placeholder, text: binding)
                    .textFieldStyle(.desktop)
            } else {
                TextField(field.placeholder, text: binding)
                    .textFieldStyle(.desktop)
            }
            if let help = field.help, !help.isEmpty {
                Text(help)
                    .font(.system(size: 11))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func effectBadgeText(_ effect: DesktopToolEffect) -> String {
        switch effect {
        case .pure: "只读"
        case .networkRead: "网络读取"
        case .idempotent: "幂等变更（需批准）"
        case .sideEffect: "外部写入（需批准）"
        }
    }

    // MARK: - Actions

    private func ensureValidSelection() {
        if case .ext(let id) = selection, !plugins.plugins.contains(where: { $0.id == id }) {
            if let first = plugins.plugins.first {
                selection = .ext(first.id)
            } else {
                selection = .core(.taskBoard)
            }
        }
    }

    private func loadDraftSettings() {
        guard case .ext(let id) = selection,
              let plugin = plugins.plugins.first(where: { $0.id == id }) else {
            draftSettings = [:]
            return
        }
        var loaded: [String: String] = [:]
        for field in plugin.manifest.settingsSchema {
            loaded[field.key] = plugins.settingValue(pluginID: id, key: field.key)
        }
        draftSettings = loaded
    }

    @discardableResult
    private func saveDraftSettings(for pluginID: String) -> Bool {
        do {
            try plugins.saveSettings(pluginID: pluginID, values: draftSettings)
            setStatus("插件配置已保存。", isError: false)
            return true
        } catch {
            setStatus(error.localizedDescription, isError: true)
            return false
        }
    }

    private func syncFeishu() {
        Task {
            do {
                let message = try await plugins.syncFeishuCalendar()
                setStatus(message, isError: false)
            } catch {
                setStatus(error.localizedDescription, isError: true)
            }
        }
    }

    private func sendTestBotCard() {
        Task {
            do {
                let item = try await plugins.sendFeishuBotMessage(
                    title: "Amber 飞书机器人连通性测试",
                    content: "飞书机器人模块已就绪，可通过群 Webhook 或自建应用 OpenAPI 推送消息卡片、拉取群聊纪要、读写飞书云文档。"
                )
                setStatus("已发送测试通知（通道：\(item.channel) · 目标：\(item.target)）", isError: false)
            } catch {
                setStatus(error.localizedDescription, isError: true)
            }
        }
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "导入 Amber 扩展插件"
        panel.message = "选择包含 plugin.json 与 main.js 的插件文件夹，或直接选择 plugin.json 文件。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, .folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let id = try plugins.importPlugin(from: url)
            selection = .ext(id)
            loadDraftSettings()
            setStatus("已成功导入并启用插件「\(id)」。", isError: false)
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func removePlugin(id: String) {
        do {
            try plugins.removePlugin(id: id)
            ensureValidSelection()
            loadDraftSettings()
            setStatus("已移除插件「\(id)」。", isError: false)
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusMessage = text
        statusIsError = isError
    }

    private func statusBanner(text: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isError ? DesktopTheme.danger : DesktopTheme.accent)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(isError ? DesktopTheme.danger : DesktopTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.honeyEdge, lineWidth: 0.5))
    }
}

private struct FlowTagRow: View {
    let items: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
