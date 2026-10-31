import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - DesktopPluginsSettingsView (Arquiel Design 2.0)

/// Arquiel Design 2.0 plugin management pane inside Settings:
/// - Left sidebar: Extension Plugins + Core Plugins + Import / Reload / Remove toolbar.
/// - Right detail: Quiet layered hierarchy ("概览与模块 → 连接设置 → 通用设置 → 高级设置（默认折叠） → 权限摘要与技术详情（默认折叠）").
struct DesktopPluginsSettingsView: View {
    @Bindable var plugins: DesktopPluginStore
    var workspace: DesktopWorkspace?

    enum Selection: Hashable {
        case core(DesktopCorePlugin)
        case ext(String)
    }

    @State private var selection: Selection = .ext("feishu_calendar")
    @State private var draftSettings: [String: String] = [:]
    @State private var feishuModule: DesktopFeishuModule = .calendar
    @State private var isAdvancedExpanded: Bool
    @State private var isTechnicalDetailsExpanded: Bool
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var confirmsDeletePluginID: String?

    init(
        plugins: DesktopPluginStore,
        workspace: DesktopWorkspace? = nil,
        initialFeishuModule: DesktopFeishuModule = .calendar,
        initialSelection: Selection = .ext("feishu_calendar"),
        initialAdvancedExpanded: Bool = false,
        initialTechnicalDetailsExpanded: Bool = false
    ) {
        self.plugins = plugins
        self.workspace = workspace
        _selection = State(initialValue: initialSelection)
        _feishuModule = State(initialValue: initialFeishuModule)
        _isAdvancedExpanded = State(initialValue: initialAdvancedExpanded)
        _isTechnicalDetailsExpanded = State(initialValue: initialTechnicalDetailsExpanded)
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 210, idealWidth: 232, maxWidth: 255, maxHeight: .infinity)
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
            isAdvancedExpanded = false
            isTechnicalDetailsExpanded = false
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
                                        Text(sidebarSubtitle(for: plugin))
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

    private func sidebarSubtitle(for plugin: DesktopInstalledPlugin) -> String {
        if !plugin.enabled { return "已停用" }
        if plugin.id == "feishu_calendar" {
            if plugins.hasFeishuRemoteCredentials || plugins.hasFeishuBotCredentials {
                return "已连接 · 日历与机器人"
            }
            return "日历与机器人 · 演示模式"
        }
        // A host-native plugin is honest about needing a system permission instead of claiming it "just works".
        if DesktopPluginHostModule.calendar.isWired(for: plugin) {
            return "本机日历 · \(plugin.manifest.tools.count) 项工具"
        }
        return "v\(plugin.manifest.version) · \(plugin.manifest.tools.count) 项工具"
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
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Core Plugin Detail

    private func coreDetail(_ core: DesktopCorePlugin) -> some View {
        let enabled = plugins.isCoreEnabled(core)
        return VStack(alignment: .leading, spacing: 16) {
            arquielSurfaceCard {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: core.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(DesktopTheme.accent)
                        .frame(width: 40, height: 40)
                        .background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(core.title)
                                .font(DesktopTheme.serif(size: 19, weight: .semibold))
                                .foregroundStyle(DesktopTheme.ink)
                            statusPill(
                                text: enabled ? "已启用" : "已停用",
                                state: enabled ? .connected : .disabled
                            )
                        }
                        Text(core.summary)
                            .font(.system(size: 12.5))
                            .foregroundStyle(DesktopTheme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
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
            }

            if !core.governedToolNames.isEmpty {
                arquielSurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("权限与关联工具")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DesktopTheme.ink)
                            Spacer()
                            Text("\(core.governedToolNames.count) 项内置工具")
                                .font(.system(size: 11.5))
                                .foregroundStyle(DesktopTheme.inkTertiary)
                        }
                        Text("停用此核心模块后，对应入口与工具将自动从对话及定时任务中隐藏。")
                            .font(.system(size: 12))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                        DisclosureGroup(
                            isExpanded: $isTechnicalDetailsExpanded,
                            content: {
                                FlowTagRow(items: Array(core.governedToolNames).sorted())
                                    .padding(.top, 8)
                            },
                            label: {
                                Text("查看原始工具标识符")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(DesktopTheme.inkSecondary)
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Extension Plugin Detail (Arquiel Design 2.0 Five-Tier Hierarchy)

    private func extensionDetail(_ plugin: DesktopInstalledPlugin) -> some View {
        let overview = DesktopPluginSettingsPresentation.overview(
            for: plugin,
            store: plugins,
            hasError: statusIsError
        )
        let categories = DesktopPluginSettingsPresentation.categorizeFields(
            for: plugin,
            module: feishuModule,
            draftSettings: draftSettings
        )
        let permissions = DesktopPluginSettingsPresentation.permissionSummary(
            for: plugin,
            calendarEventCount: plugins.calendarEvents.count,
            botActivityCount: plugins.botActivities.count
        )

        return VStack(alignment: .leading, spacing: 16) {
            // Tier 1: Overview & Module Selection
            overviewCard(plugin: plugin, overview: overview)

            // Tier 2: Connection Settings (连接到飞书 / 核心凭据)
            if !categories.connectionKeys.isEmpty || plugin.id == "feishu_calendar" {
                connectionSettingsCard(plugin: plugin, keys: categories.connectionKeys)
            }

            // Tier 3: General Settings (通用设置)
            if !categories.generalKeys.isEmpty {
                generalSettingsCard(plugin: plugin, keys: categories.generalKeys)
            }

            // Tier 4: Advanced Settings (高级设置 · 默认折叠)
            if !categories.advancedKeys.isEmpty {
                advancedSettingsCard(
                    plugin: plugin,
                    keys: categories.advancedKeys,
                    summary: categories.advancedSummary,
                    customizedCount: categories.customizedAdvancedCount
                )
            }

            // Tier 5: Permission Summary & Technical Details (权限摘要与技术详情 · 默认折叠)
            permissionsAndTechnicalCard(plugin: plugin, summary: permissions)
        }
    }

    // MARK: - Tier 1: Overview & Module Selector Card

    private func overviewCard(
        plugin: DesktopInstalledPlugin,
        overview: DesktopPluginSettingsPresentation.Overview
    ) -> some View {
        arquielSurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: plugin.manifest.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(DesktopTheme.accent)
                        .frame(width: 40, height: 40)
                        .background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(overview.title)
                                .font(DesktopTheme.serif(size: 20, weight: .semibold))
                                .foregroundStyle(DesktopTheme.ink)
                            statusPill(text: overview.connectionBadgeText, state: overview.connectionState)
                        }
                        Text(overview.summary)
                            .font(.system(size: 12.5))
                            .foregroundStyle(DesktopTheme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
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

                if plugin.id == "feishu_calendar" {
                    Rectangle()
                        .fill(DesktopTheme.hairline)
                        .frame(height: 1)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            feishuModuleCard(
                                module: .calendar,
                                statusText: overview.calendarModuleStatus,
                                isConnected: plugins.hasFeishuRemoteCredentials,
                                pluginEnabled: plugin.enabled
                            )
                            feishuModuleCard(
                                module: .bot,
                                statusText: overview.botModuleStatus,
                                isConnected: plugins.hasFeishuBotCredentials,
                                pluginEnabled: plugin.enabled
                            )
                        }

                        VStack(spacing: 8) {
                            feishuModuleCard(
                                module: .calendar,
                                statusText: overview.calendarModuleStatus,
                                isConnected: plugins.hasFeishuRemoteCredentials,
                                pluginEnabled: plugin.enabled
                            )
                            feishuModuleCard(
                                module: .bot,
                                statusText: overview.botModuleStatus,
                                isConnected: plugins.hasFeishuBotCredentials,
                                pluginEnabled: plugin.enabled
                            )
                        }
                    }
                }
            }
        }
    }

    private func feishuModuleCard(
        module: DesktopFeishuModule,
        statusText: String,
        isConnected: Bool,
        pluginEnabled: Bool
    ) -> some View {
        let isSelected = feishuModule == module
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)

        return HStack(spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    feishuModule = module
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: module.symbol)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? DesktopTheme.accentInk : DesktopTheme.inkSecondary)
                        .frame(width: 28, height: 28)
                        .background(
                            isSelected ? DesktopTheme.honey : DesktopTheme.card,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.title)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(DesktopTheme.ink)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(isConnected && pluginEnabled ? DesktopTheme.success : DesktopTheme.inkTertiary.opacity(0.45))
                                .frame(width: 5.5, height: 5.5)
                            Text(statusText)
                                .font(.system(size: 11.5))
                                .foregroundStyle(isSelected ? DesktopTheme.inkSecondary : DesktopTheme.inkTertiary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换至\(module.title)设置")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

            if let workspace, pluginEnabled {
                Button {
                    workspace.openPluginView(pluginID: "feishu_calendar", viewID: module.workspaceViewID)
                    NSApp.windows.first { $0.title == "Amber" || $0.identifier?.rawValue.contains("main") == true }?
                        .makeKeyAndOrderFront(nil)
                    setStatus("已在主窗口\(module.openWorkspaceLabel)。", isError: false)
                } label: {
                    HStack(spacing: 2) {
                        Text(module.openWorkspaceLabel)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DesktopTheme.accent)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(DesktopTheme.card.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("在主窗口中\(module.openWorkspaceLabel)")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? DesktopTheme.honeySoft : DesktopTheme.paperDeep, in: shape)
        .overlay(
            shape.strokeBorder(
                isSelected ? DesktopTheme.honeyEdge : DesktopTheme.hairline,
                lineWidth: isSelected ? 1.0 : 0.75
            )
        )
    }

    // MARK: - Tier 2: Connection Settings Card (连接设置)

    private func connectionSettingsCard(
        plugin: DesktopInstalledPlugin,
        keys: [String]
    ) -> some View {
        let isFeishu = plugin.id == "feishu_calendar"
        let fields = resolveFields(in: plugin, keys: keys)
        let sectionTitle = isFeishu
            ? (feishuModule == .calendar ? "连接设置 · 飞书日历" : "连接设置 · 飞书机器人")
            : "连接设置"
        let sectionSubtitle: String = if isFeishu {
            feishuModule == .calendar
                ? "在「飞书设置 → 日历 → CalDAV 同步」生成账号与密码即可直连，无需企业管理员审批。"
                : "填写群自定义机器人 Webhook 即可向飞书群推送卡片；企业自建应用 OpenAPI 凭证位于下方「高级设置」。"
        } else {
            "配置连接地址与访问凭据。"
        }

        return arquielSurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sectionTitle)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(DesktopTheme.ink)
                        Text(sectionSubtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Label("钥匙串加密", systemImage: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .fixedSize(horizontal: true, vertical: false)
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                        if index > 0 {
                            Rectangle().fill(DesktopTheme.hairline).frame(height: 1)
                        }
                        alignedSettingRow(field: field, compactHelp: conciseFieldSubtitle(for: field))
                    }

                    if isFeishu && feishuModule == .calendar {
                        Rectangle().fill(DesktopTheme.hairline).frame(height: 1)
                        HStack(spacing: 8) {
                            Text("CalDAV 服务器")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(DesktopTheme.inkSecondary)
                            Spacer()
                            let currentServer = (draftSettings["caldav_server"] ?? DesktopPluginSettingsPresentation.feishuDefaultCalDAVServer)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            Text(currentServer.isEmpty ? DesktopPluginSettingsPresentation.feishuDefaultCalDAVServer : currentServer)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(DesktopTheme.inkTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("修改") {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                    isAdvancedExpanded = true
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DesktopTheme.accent)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(12)
                .background(DesktopTheme.paperDeep.opacity(0.55), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(DesktopTheme.hairline, lineWidth: 0.75)
                )

                // Connection status & primary/secondary action bar
                if let message = statusMessage ?? plugin.lastSyncStatus {
                    HStack(spacing: 7) {
                        Image(systemName: statusIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(statusIsError ? DesktopTheme.danger : DesktopTheme.accent)
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(statusIsError ? DesktopTheme.danger : DesktopTheme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        (statusIsError ? DesktopTheme.danger.opacity(0.08) : DesktopTheme.honeySoft),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }

                HStack(spacing: 10) {
                    Text(hasUnsavedChanges(for: plugin) ? "有未保存的更改" : "密码与密钥独立加密存入 macOS 钥匙串")
                        .font(.system(size: 11.5))
                        .foregroundStyle(hasUnsavedChanges(for: plugin) ? DesktopTheme.accent : DesktopTheme.inkTertiary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if isFeishu {
                        Button {
                            if saveDraftSettings(for: plugin.id) {
                                if feishuModule == .calendar {
                                    syncFeishu()
                                } else {
                                    sendTestBotCard()
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if plugins.isSyncingPluginID == "feishu_calendar" && feishuModule == .calendar {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: feishuModule == .calendar ? "arrow.triangle.2.circlepath" : "paperplane")
                                        .font(.system(size: 11))
                                }
                                Text(feishuModule == .calendar ? "同步日历" : "发送测试消息")
                            }
                        }
                        .buttonStyle(.desktopActionPill)
                        .disabled(!plugin.enabled || plugins.isSyncingPluginID == "feishu_calendar")
                        .accessibilityLabel(feishuModule == .calendar ? "保存并同步飞书日历" : "保存并发送飞书机器人测试消息")
                    }

                    Button("保存配置") {
                        saveDraftSettings(for: plugin.id)
                    }
                    .buttonStyle(.desktopProminent)
                    .accessibilityIdentifier("save-plugin-settings")
                }
            }
        }
    }

    // MARK: - Tier 3: General Settings Card (通用设置)

    private func generalSettingsCard(
        plugin: DesktopInstalledPlugin,
        keys: [String]
    ) -> some View {
        let isFeishu = plugin.id == "feishu_calendar"
        return arquielSurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("通用设置")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(DesktopTheme.ink)
                    Text(isFeishu ? "工作时段忙闲计算与默认消息接收目标。" : "日常使用偏好与默认行为。")
                        .font(.system(size: 12))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                }

                if isFeishu {
                    VStack(alignment: .leading, spacing: 10) {
                        // Combined Workday Hours Row (9:00 - 18:00)
                        HStack(alignment: .center, spacing: 14) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("工作时段")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(DesktopTheme.ink)
                                Text("查询忙闲与推荐会议时段时使用的时间范围（小时）")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(DesktopTheme.inkTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 10)
                            HStack(spacing: 6) {
                                TextField("9", text: draftBinding(key: "workday_start_hour", defaultValue: "9"))
                                    .textFieldStyle(.desktop)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 48)
                                    .accessibilityLabel("工作时段开始小时")
                                Text(":00 至")
                                    .font(.system(size: 12))
                                    .foregroundStyle(DesktopTheme.inkTertiary)
                                    .fixedSize(horizontal: true, vertical: false)
                                TextField("18", text: draftBinding(key: "workday_end_hour", defaultValue: "18"))
                                    .textFieldStyle(.desktop)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 48)
                                    .accessibilityLabel("工作时段结束小时")
                                Text(":00")
                                    .font(.system(size: 12))
                                    .foregroundStyle(DesktopTheme.inkTertiary)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }

                        Rectangle().fill(DesktopTheme.hairline).frame(height: 1)

                        // Default Receive ID Row
                        if let receiveField = plugin.manifest.settingsSchema.first(where: { $0.key == "default_receive_id" }) {
                            alignedSettingRow(
                                field: receiveField,
                                compactHelp: "应用机器人默认发消息或拉取纪要的群聊 chat_id 或 open_id"
                            )
                        }
                    }
                    .padding(12)
                    .background(DesktopTheme.paperDeep.opacity(0.55), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(DesktopTheme.hairline, lineWidth: 0.75)
                    )
                } else {
                    let fields = resolveFields(in: plugin, keys: keys)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                            if index > 0 {
                                Rectangle().fill(DesktopTheme.hairline).frame(height: 1)
                            }
                            alignedSettingRow(field: field, compactHelp: field.help)
                        }
                    }
                    .padding(12)
                    .background(DesktopTheme.paperDeep.opacity(0.55), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(DesktopTheme.hairline, lineWidth: 0.75)
                    )

                    if plugin.manifest.settingsSchema.filter({ $0.kind == .secret }).isEmpty {
                        HStack {
                            Spacer()
                            Button("保存配置") {
                                saveDraftSettings(for: plugin.id)
                            }
                            .buttonStyle(.desktopProminent)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tier 4: Advanced Settings Card (高级设置 · 默认折叠)

    private func advancedSettingsCard(
        plugin: DesktopInstalledPlugin,
        keys: [String],
        summary: String,
        customizedCount: Int
    ) -> some View {
        let fields = resolveFields(in: plugin, keys: keys)
        let isFeishu = plugin.id == "feishu_calendar"

        return arquielSurfaceCard {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        isAdvancedExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text("高级设置")
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(DesktopTheme.ink)
                                if customizedCount > 0 {
                                    Text("已自定义 \(customizedCount) 项")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(DesktopTheme.accentInk)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background(DesktopTheme.honeySoft, in: Capsule())
                                }
                            }
                            Text(summary)
                                .font(.system(size: 12))
                                .foregroundStyle(DesktopTheme.inkTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(isAdvancedExpanded ? "收起" : "展开")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                            .rotationEffect(.degrees(isAdvancedExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("高级设置")
                .accessibilityValue(isAdvancedExpanded ? "已展开" : "已折叠")
                .accessibilityIdentifier("plugin-advanced-disclosure")

                if isAdvancedExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        Rectangle()
                            .fill(DesktopTheme.hairline)
                            .frame(height: 1)
                            .padding(.top, 12)

                        if isFeishu {
                            // Sub-group A: Calendar Server & OpenAPI Fallback Calendar ID
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("日历服务地址与备选日历")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(DesktopTheme.inkSecondary)
                                    Spacer()
                                    if (draftSettings["caldav_server"] ?? DesktopPluginSettingsPresentation.feishuDefaultCalDAVServer) != DesktopPluginSettingsPresentation.feishuDefaultCalDAVServer
                                        || (draftSettings["default_calendar_id"] ?? DesktopPluginSettingsPresentation.feishuDefaultCalendarID) != DesktopPluginSettingsPresentation.feishuDefaultCalendarID {
                                        Button("恢复默认") {
                                            draftSettings["caldav_server"] = DesktopPluginSettingsPresentation.feishuDefaultCalDAVServer
                                            draftSettings["default_calendar_id"] = DesktopPluginSettingsPresentation.feishuDefaultCalendarID
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(DesktopTheme.accent)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 10) {
                                    let calAdvFields = resolveFields(in: plugin, keys: ["caldav_server", "default_calendar_id"])
                                    ForEach(Array(calAdvFields.enumerated()), id: \.element.id) { idx, field in
                                        if idx > 0 {
                                            Rectangle().fill(DesktopTheme.hairline).frame(height: 1)
                                        }
                                        alignedSettingRow(field: field, compactHelp: conciseFieldSubtitle(for: field))
                                    }
                                }
                                .padding(12)
                                .background(DesktopTheme.paperDeep.opacity(0.55), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .strokeBorder(DesktopTheme.hairline, lineWidth: 0.75)
                                )
                            }

                            // Sub-group B: Enterprise Self-Built App (OpenAPI) & PAT
                            VStack(alignment: .leading, spacing: 8) {
                                Text("企业自建应用与开放平台（OpenAPI）")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DesktopTheme.inkSecondary)
                                Text("需要拉取群聊历史记录或读写飞书云文档（Docx）时，配置自建应用的 App ID 与 App Secret。")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(DesktopTheme.inkTertiary)
                                    .fixedSize(horizontal: false, vertical: true)

                                VStack(alignment: .leading, spacing: 10) {
                                    let openAPIFields = resolveFields(in: plugin, keys: ["app_id", "app_secret", "personal_access_token"])
                                    ForEach(Array(openAPIFields.enumerated()), id: \.element.id) { idx, field in
                                        if idx > 0 {
                                            Rectangle().fill(DesktopTheme.hairline).frame(height: 1)
                                        }
                                        alignedSettingRow(field: field, compactHelp: conciseFieldSubtitle(for: field))
                                    }
                                }
                                .padding(12)
                                .background(DesktopTheme.paperDeep.opacity(0.55), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .strokeBorder(DesktopTheme.hairline, lineWidth: 0.75)
                                )
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                                    if index > 0 {
                                        Rectangle().fill(DesktopTheme.hairline).frame(height: 1)
                                    }
                                    alignedSettingRow(field: field, compactHelp: field.help)
                                }
                            }
                            .padding(12)
                            .background(DesktopTheme.paperDeep.opacity(0.55), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(DesktopTheme.hairline, lineWidth: 0.75)
                            )
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Tier 5: Permission Summary & Technical Details Card (权限与技术详情 · 默认折叠)

    private func permissionsAndTechnicalCard(
        plugin: DesktopInstalledPlugin,
        summary: DesktopPluginSettingsPresentation.PermissionSummary
    ) -> some View {
        arquielSurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Text("权限与能力边界")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(DesktopTheme.ink)
                    Spacer()
                    Text(summary.capabilityCountBadge)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(DesktopTheme.paperDeep, in: Capsule())
                }

                // Declared capability versus what the host can run: un-wired capabilities must say so.
                VStack(alignment: .leading, spacing: 6) {
                    Text("能力接线")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                    ForEach(DesktopPluginSettingsPresentation.capabilityRows(for: plugin)) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DesktopTheme.ink)
                                .frame(width: 84, alignment: .leading)
                            Text(row.badge)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(row.state == .declaredNotWired ? DesktopTheme.inkTertiary : DesktopTheme.accentInk)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(DesktopTheme.paperDeep, in: Capsule())
                                // A wider badge must not shift the detail column of the other rows.
                                .frame(width: 64, alignment: .leading)
                            Text(row.detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(DesktopTheme.inkTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(12)
                .background(DesktopTheme.paperDeep.opacity(0.55), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(DesktopTheme.hairline, lineWidth: 0.75)
                )

                // Human-readable permission summary rows
                VStack(alignment: .leading, spacing: 8) {
                    permissionRow(symbol: "network", title: "网络访问", detail: summary.networkSummary)
                    permissionRow(symbol: "hand.raised", title: "执行审批", detail: summary.approvalSummary)
                    permissionRow(symbol: "folder", title: "工作区写入", detail: summary.workspaceSummary)
                }
                .padding(12)
                .background(DesktopTheme.paperDeep.opacity(0.55), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(DesktopTheme.hairline, lineWidth: 0.75)
                )

                // Collapsible Technical Details section
                Rectangle().fill(DesktopTheme.hairline).frame(height: 1)

                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        isTechnicalDetailsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("技术详情")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(DesktopTheme.inkSecondary)
                        Text("插件 ID、协议版本、域名白名单与原始工具定义")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(isTechnicalDetailsExpanded ? "收起" : "展开")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                            .rotationEffect(.degrees(isTechnicalDetailsExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("技术详情")
                .accessibilityValue(isTechnicalDetailsExpanded ? "已展开" : "已折叠")
                .accessibilityIdentifier("plugin-technical-disclosure")

                if isTechnicalDetailsExpanded {
                    VStack(alignment: .leading, spacing: 14) {
                        // 1. Metadata line
                        VStack(alignment: .leading, spacing: 4) {
                            Text("关于插件")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(DesktopTheme.inkTertiary)
                            Text(summary.technicalMetadataLine)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(DesktopTheme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }

                        // 2. Domains & Workspace Prefixes with real wrapping layout
                        if !plugin.manifest.capabilities.networkDomains.isEmpty || !plugin.manifest.capabilities.workspaceWritePrefixes.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                if !plugin.manifest.capabilities.networkDomains.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("HTTPS 域名白名单")
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundStyle(DesktopTheme.inkTertiary)
                                        FlowTagRow(items: plugin.manifest.capabilities.networkDomains)
                                    }
                                }

                                if !plugin.manifest.capabilities.workspaceWritePrefixes.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("工作区写入路径前缀")
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundStyle(DesktopTheme.inkTertiary)
                                        FlowTagRow(items: plugin.manifest.capabilities.workspaceWritePrefixes)
                                    }
                                }
                            }
                        }

                        // 3. Raw AI Tools
                        if !plugin.manifest.tools.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("AI 工具标识符（\(plugin.manifest.tools.count)）")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(DesktopTheme.inkTertiary)
                                ForEach(plugin.manifest.tools) { tool in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .center, spacing: 8) {
                                            Text(plugin.qualifiedToolName(tool.name))
                                                .font(.system(size: 11.5, design: .monospaced).weight(.medium))
                                                .foregroundStyle(DesktopTheme.ink)
                                                .textSelection(.enabled)
                                            Spacer(minLength: 6)
                                            Text(effectBadgeText(tool.effect))
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(tool.effect == .sideEffect ? DesktopTheme.accentInk : DesktopTheme.inkSecondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1.5)
                                                .background(
                                                    tool.effect == .sideEffect ? DesktopTheme.honeySoft : DesktopTheme.paperDeep,
                                                    in: Capsule()
                                                )
                                        }
                                        Text(tool.description)
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(DesktopTheme.inkTertiary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.vertical, 3)
                                }
                            }
                        }

                        // 4. Slash Commands & UI Slots
                        if !plugin.manifest.ui.commands.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("斜杠命令（\(plugin.manifest.ui.commands.count)）")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(DesktopTheme.inkTertiary)
                                ForEach(plugin.manifest.ui.commands) { cmd in
                                    HStack(spacing: 8) {
                                        Text(cmd.slash)
                                            .font(.system(size: 11.5, design: .monospaced).weight(.semibold))
                                            .foregroundStyle(DesktopTheme.accentInk)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                        Text(cmd.title)
                                            .font(.system(size: 12))
                                            .foregroundStyle(DesktopTheme.inkSecondary)
                                        Spacer()
                                    }
                                }
                            }
                        }

                        if !plugin.manifest.ui.inspectorCards.isEmpty || !plugin.manifest.ui.workspaceViews.isEmpty {
                            HStack(spacing: 16) {
                                if !plugin.manifest.ui.workspaceViews.isEmpty {
                                    Label(
                                        "工作区视图：\(plugin.manifest.ui.workspaceViews.map(\.title).joined(separator: "、"))",
                                        systemImage: "sidebar.left"
                                    )
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(DesktopTheme.inkTertiary)
                                }
                                if let card = plugin.manifest.ui.inspectorCards.first {
                                    Label("右侧栏卡片：\(card.title)", systemImage: card.symbol)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(DesktopTheme.inkTertiary)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                    .transition(.opacity)
                }
            }
        }
    }

    private func permissionRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DesktopTheme.accent)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesktopTheme.ink)
                .frame(width: 68, alignment: .leading)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(DesktopTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Reusable Row & Surface Helpers

    private func arquielSurfaceCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesktopTheme.card, in: shape)
            .overlay(shape.strokeBorder(DesktopTheme.hairlineStrong, lineWidth: 0.85))
    }

    private func statusPill(text: String, state: DesktopPluginConnectionState) -> some View {
        let dotColor: Color = switch state {
        case .connected: DesktopTheme.success
        case .demoMode: DesktopTheme.accent
        case .disabled: DesktopTheme.inkTertiary.opacity(0.5)
        case .error: DesktopTheme.danger
        }
        let bgColor: Color = switch state {
        case .connected, .demoMode: DesktopTheme.honeySoft
        case .disabled: DesktopTheme.paperDeep
        case .error: DesktopTheme.danger.opacity(0.12)
        }
        let textColor: Color = switch state {
        case .connected, .demoMode: DesktopTheme.accentInk
        case .disabled: DesktopTheme.inkTertiary
        case .error: DesktopTheme.danger
        }

        return HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(bgColor, in: Capsule())
    }

    @ViewBuilder
    private func alignedSettingRow(
        field: DesktopPluginSettingField,
        compactHelp: String?
    ) -> some View {
        let binding = draftBinding(key: field.key, defaultValue: field.defaultValue)

        if field.kind == .boolean {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cleanFieldTitle(field))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DesktopTheme.ink)
                    if let compactHelp, !compactHelp.isEmpty {
                        Text(compactHelp)
                            .font(.system(size: 11.5))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(
                    get: { (draftSettings[field.key] ?? field.defaultValue).lowercased() == "true" },
                    set: { draftSettings[field.key] = $0 ? "true" : "false" }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
        } else {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cleanFieldTitle(field))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DesktopTheme.ink)
                    if let compactHelp, !compactHelp.isEmpty {
                        Text(compactHelp)
                            .font(.system(size: 11.5))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                fieldInputControl(field: field, binding: binding)
                    .frame(width: 236)
            }
        }
    }

    @ViewBuilder
    private func fieldInputControl(
        field: DesktopPluginSettingField,
        binding: Binding<String>
    ) -> some View {
        let placeholder = field.kind == .secret && field.placeholder == "安全保存在系统钥匙串中"
            ? "未填写（加密存入钥匙串）"
            : field.placeholder

        if field.kind == .secret {
            SecureField(placeholder, text: binding)
                .textFieldStyle(.desktop)
                .accessibilityLabel(field.title)
        } else {
            TextField(placeholder, text: binding)
                .textFieldStyle(.desktop)
                .accessibilityLabel(field.title)
        }
    }

    private func cleanFieldTitle(_ field: DesktopPluginSettingField) -> String {
        switch field.key {
        case "caldav_username": "CalDAV 用户名"
        case "caldav_password": "CalDAV 密码"
        case "caldav_server": "CalDAV 服务器地址"
        case "default_calendar_id": "备选日历 ID"
        case "bot_webhook_url": "群机器人 Webhook"
        case "bot_webhook_secret": "Webhook 签名密钥"
        case "app_id": "自建应用 App ID"
        case "app_secret": "自建应用 App Secret"
        case "default_receive_id": "默认推送会话 ID"
        case "personal_access_token": "个人访问令牌 (PAT)"
        default: field.title
        }
    }

    private func conciseFieldSubtitle(for field: DesktopPluginSettingField) -> String? {
        switch field.key {
        case "caldav_username":
            "飞书生成的个人 CalDAV 账号（如 u_xxxxxx）"
        case "caldav_password":
            "专用同步密码，用于读写个人飞书日程"
        case "caldav_server":
            "默认 https://caldav.feishu.cn（Lark 可改为 caldav.larksuite.com）"
        case "default_calendar_id":
            "未配置 CalDAV 时，通过自建应用同步的日历标识（默认 primary）"
        case "bot_webhook_url":
            "群设置 → 群机器人 → 自定义机器人生成的 Webhook 地址"
        case "bot_webhook_secret":
            "可选 · 开启签名校验时自动附带 HMAC-SHA256 签名"
        case "app_id":
            "飞书开放平台企业自建应用的 App ID（cli_...）"
        case "app_secret":
            "用于自动换取 tenant_access_token"
        case "personal_access_token":
            "可选 · 优先使用个人授权调用飞书 OpenAPI"
        default:
            field.help
        }
    }

    private func resolveFields(in plugin: DesktopInstalledPlugin, keys: [String]) -> [DesktopPluginSettingField] {
        let byKey = Dictionary(uniqueKeysWithValues: plugin.manifest.settingsSchema.map { ($0.key, $0) })
        return keys.compactMap { byKey[$0] }
    }

    private func draftBinding(key: String, defaultValue: String) -> Binding<String> {
        Binding(
            get: { draftSettings[key] ?? defaultValue },
            set: { draftSettings[key] = $0 }
        )
    }

    private func hasUnsavedChanges(for plugin: DesktopInstalledPlugin) -> Bool {
        for field in plugin.manifest.settingsSchema {
            let current = draftSettings[field.key] ?? field.defaultValue
            let saved = plugins.settingValue(pluginID: plugin.id, key: field.key)
            if current != saved {
                return true
            }
        }
        return false
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
            loadDraftSettings()
            setStatus("配置已保存。", isError: false)
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
        .background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DesktopTheme.honeyEdge, lineWidth: 0.5))
    }
}

// MARK: - Wrapping Flow Layout for Domain & Capability Tags

private struct FlowTagRow: View {
    let items: [String]

    var body: some View {
        DesktopWrappingFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }
}

private struct DesktopWrappingFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > maxWidth {
                currentX = 0
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            totalWidth = max(totalWidth, currentX + size.width)
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: min(maxWidth, totalWidth), height: currentY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX && currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
