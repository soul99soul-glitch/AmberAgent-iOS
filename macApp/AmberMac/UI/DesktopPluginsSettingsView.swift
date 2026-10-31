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

    @State var selection: Selection = .ext("feishu_calendar")
    @State var draftSettings: [String: String] = [:]
    @State var feishuModule: DesktopFeishuModule = .calendar
    @State var isAdvancedExpanded: Bool
    @State var isTechnicalDetailsExpanded: Bool
    @State var statusMessage: String?
    @State var statusIsError = false
    @State var confirmsDeletePluginID: String?
    @State var pendingInstallPlan: DesktopPluginInstallPlan?

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
        .sheet(
            isPresented: Binding(
                get: { pendingInstallPlan != nil },
                set: { if !$0 { pendingInstallPlan = nil } }
            )
        ) {
            if let plan = pendingInstallPlan {
                DesktopPluginPermissionConsentSheet(
                    plan: plan,
                    onApprove: {
                        do {
                            let id = try plugins.importPlugin(from: plan.sourceURL, approvePermissions: true)
                            selection = .ext(id)
                            loadDraftSettings()
                            setStatus("已批准权限并导入插件「\(plan.manifest.name)」。", isError: false)
                        } catch {
                            setStatus(error.localizedDescription, isError: true)
                        }
                        pendingInstallPlan = nil
                    },
                    onCancel: {
                        pendingInstallPlan = nil
                    }
                )
            }
        }
    }

    // MARK: - Left Sidebar

    var sidebar: some View {
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

    func sidebarSubtitle(for plugin: DesktopInstalledPlugin) -> String {
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

    func sectionHeader(_ title: String, count: Int) -> some View {
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
    var detail: some View {
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

    func coreDetail(_ core: DesktopCorePlugin) -> some View {
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

    func extensionDetail(_ plugin: DesktopInstalledPlugin) -> some View {
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

    func overviewCard(
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

    func feishuModuleCard(
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

    func connectionSettingsCard(
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

}
