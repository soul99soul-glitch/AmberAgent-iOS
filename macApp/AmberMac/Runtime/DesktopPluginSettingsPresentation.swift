import Foundation

// MARK: - Arquiel Design 2.0 Presentation Model for Plugin Settings

enum DesktopFeishuModule: Int, CaseIterable, Sendable {
    case calendar = 0
    case bot = 1

    var title: String {
        switch self {
        case .calendar: "飞书日历"
        case .bot: "飞书机器人"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .bot: "paperplane.circle"
        }
    }

    var workspaceViewID: String {
        switch self {
        case .calendar: "calendar_board"
        case .bot: "bot_studio"
        }
    }

    var openWorkspaceLabel: String {
        switch self {
        case .calendar: "打开日历"
        case .bot: "打开工作台"
        }
    }
}

enum DesktopPluginConnectionState: Equatable, Sendable {
    case disabled
    case connected
    case demoMode
    case error
}

/// One row of the capability matrix shown in the plugin settings page.
struct DesktopPluginCapabilityRow: Equatable, Identifiable, Sendable {
    enum State: String, Equatable, Sendable { case wired, declaredNotWired, hostNative }

    let id: String
    let title: String
    let state: State
    let detail: String

    var badge: String {
        switch state {
        case .wired: "已接线"
        case .declaredNotWired: "未接线"
        case .hostNative: "宿主原生"
        }
    }
}

struct DesktopPluginSettingsPresentation: Equatable, Sendable {
    struct Overview: Equatable, Sendable {
        let title: String
        let summary: String
        let connectionState: DesktopPluginConnectionState
        let connectionBadgeText: String
        let calendarModuleStatus: String
        let botModuleStatus: String
        let showsTechnicalMetadataInHeader: Bool
    }

    struct CategorizedFields: Equatable, Sendable {
        let connectionKeys: [String]
        let generalKeys: [String]
        let advancedKeys: [String]
        let advancedSummary: String
        let customizedAdvancedCount: Int
        let isAdvancedExpandedByDefault: Bool
        let isTechnicalDetailsExpandedByDefault: Bool
    }

    struct PermissionSummary: Equatable, Sendable {
        let networkSummary: String
        let approvalSummary: String
        let workspaceSummary: String
        let capabilityCountBadge: String
        let technicalMetadataLine: String
    }

    static let feishuDefaultCalDAVServer = "https://caldav.feishu.cn"
    static let feishuDefaultCalendarID = "primary"
    static let feishuDefaultWorkdayStart = "9"
    static let feishuDefaultWorkdayEnd = "18"

    @MainActor
    static func overview(
        for plugin: DesktopInstalledPlugin,
        store: DesktopPluginStore,
        hasError: Bool
    ) -> Overview {
        let isFeishu = plugin.id == "feishu_calendar"
        let summary: String = if isFeishu {
            "连接个人日历与群机器人，在对话中查排期、发群卡片与整理纪要。"
        } else {
            plugin.manifest.description
        }

        let state: DesktopPluginConnectionState
        let badge: String
        if !plugin.enabled {
            state = .disabled
            badge = "已停用"
        } else if hasError {
            state = .error
            badge = "连接异常"
        } else if isFeishu {
            if store.hasFeishuRemoteCredentials || store.hasFeishuBotCredentials {
                state = .connected
                badge = "已连接"
            } else {
                state = .demoMode
                badge = "演示模式"
            }
        } else {
            state = .connected
            badge = "已启用"
        }

        let calStatus: String = if !plugin.enabled {
            "已停用"
        } else if store.hasFeishuCalDAVCredentials {
            "CalDAV 直连"
        } else if store.hasFeishuRemoteCredentials {
            "开放平台直连"
        } else {
            "本地演示模式"
        }

        let botStatus: String = if !plugin.enabled {
            "已停用"
        } else if store.hasFeishuBotCredentials {
            store.feishuBotConnectionBadge
        } else {
            "本地沙箱模式"
        }

        return Overview(
            title: plugin.manifest.name,
            summary: summary,
            connectionState: state,
            connectionBadgeText: badge,
            calendarModuleStatus: calStatus,
            botModuleStatus: botStatus,
            showsTechnicalMetadataInHeader: false
        )
    }

    static func categorizeFields(
        for plugin: DesktopInstalledPlugin,
        module: DesktopFeishuModule,
        draftSettings: [String: String]
    ) -> CategorizedFields {
        if plugin.id == "feishu_calendar" {
            let connectionKeys: [String] = switch module {
            case .calendar:
                ["caldav_username", "caldav_password"]
            case .bot:
                ["bot_webhook_url", "bot_webhook_secret"]
            }

            let generalKeys = ["workday_start_hour", "workday_end_hour", "default_receive_id"]
            let advancedKeys = [
                "caldav_server",
                "default_calendar_id",
                "app_id",
                "app_secret",
                "personal_access_token"
            ]

            var customized = 0
            let server = (draftSettings["caldav_server"] ?? feishuDefaultCalDAVServer)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !server.isEmpty && server != feishuDefaultCalDAVServer {
                customized += 1
            }
            let calID = (draftSettings["default_calendar_id"] ?? feishuDefaultCalendarID)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !calID.isEmpty && calID != feishuDefaultCalendarID {
                customized += 1
            }
            let appID = (draftSettings["app_id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let appSecret = (draftSettings["app_secret"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !appID.isEmpty || !appSecret.isEmpty {
                customized += 1
            }
            let pat = (draftSettings["personal_access_token"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !pat.isEmpty {
                customized += 1
            }

            let summary: String = if !appID.isEmpty && !appSecret.isEmpty {
                "已启用企业自建应用 OpenAPI · 自定义服务器与备选日历"
            } else if customized > 0 {
                "已自定义 \(customized) 项 · 服务器地址、备选日历与开放平台凭证"
            } else {
                "自定义 CalDAV 服务器 · 备选日历 ID · 企业自建应用 OpenAPI"
            }

            return CategorizedFields(
                connectionKeys: connectionKeys,
                generalKeys: generalKeys,
                advancedKeys: advancedKeys,
                advancedSummary: summary,
                customizedAdvancedCount: customized,
                isAdvancedExpandedByDefault: false,
                isTechnicalDetailsExpandedByDefault: false
            )
        }

        // Generic categorization for third-party / custom plugins:
        let allFields = plugin.manifest.settingsSchema
        let connectionKeys = allFields.filter {
            $0.kind == .secret || $0.key.localizedCaseInsensitiveContains("url") || $0.key.localizedCaseInsensitiveContains("token") || $0.key.localizedCaseInsensitiveContains("key")
        }.map(\.key)
        let advancedKeys = allFields.filter {
            !connectionKeys.contains($0.key) && ($0.group == "advanced" || $0.key.localizedCaseInsensitiveContains("advanced") || $0.key.localizedCaseInsensitiveContains("fallback"))
        }.map(\.key)
        let generalKeys = allFields.filter {
            !connectionKeys.contains($0.key) && !advancedKeys.contains($0.key)
        }.map(\.key)

        return CategorizedFields(
            connectionKeys: connectionKeys,
            generalKeys: generalKeys,
            advancedKeys: advancedKeys,
            advancedSummary: advancedKeys.isEmpty ? "无额外低频配置" : "包含 \(advancedKeys.count) 项低频参数",
            customizedAdvancedCount: 0,
            isAdvancedExpandedByDefault: false,
            isTechnicalDetailsExpandedByDefault: false
        )
    }

    /// Declared capability versus what the host can actually run. Built-in plugins use native host clients,
    /// while third-party plugins access declared HTTPS domains via `amber.http.fetch` and declared workspace
    /// directory prefixes via `amber.workspace.read` / `write`. Undeclared capabilities remain `.declaredNotWired`.
    static func capabilityRows(for plugin: DesktopInstalledPlugin) -> [DesktopPluginCapabilityRow] {
        let capabilities = plugin.manifest.capabilities
        let domains = capabilities.networkDomains
        let writePrefixes = capabilities.workspaceWritePrefixes
        let readPrefixes = capabilities.workspaceReadPrefixes
        let network: DesktopPluginCapabilityRow = if plugin.isBuiltIn && !domains.isEmpty {
            .init(id: "network", title: "网络访问", state: .hostNative,
                  detail: "内置模块经宿主原生客户端访问 \(domains.count) 个域名，不经过沙箱。")
        } else if !domains.isEmpty {
            .init(id: "network", title: "网络访问", state: plugin.enabled ? .wired : .declaredNotWired,
                  detail: plugin.enabled
                      ? "经受控 HTTPS 桥（amber.http.fetch）访问 \(domains.count) 个白名单域名。"
                      : "已声明 \(domains.count) 个白名单域名；插件已停用，当前不发出请求。")
        } else {
            .init(id: "network", title: "网络访问", state: .declaredNotWired,
                  detail: "未声明域名；沙箱拒绝一切外部网络请求。")
        }
        let hasWorkspacePrefixes = !readPrefixes.isEmpty || !writePrefixes.isEmpty
        let files: DesktopPluginCapabilityRow = if !plugin.isBuiltIn && hasWorkspacePrefixes {
            .init(id: "files", title: "工作区文件",
                  state: plugin.enabled ? .wired : .declaredNotWired,
                  detail: plugin.enabled
                      ? "经受控文件桥（amber.workspace）访问已声明的会话子目录前缀。"
                      : "已声明工作区子目录前缀；插件已停用，当前不读写文件。")
        } else {
            .init(id: "files", title: "工作区文件",
                  state: .declaredNotWired,
                  detail: !hasWorkspacePrefixes
                      ? "未声明工作区路径；沙箱拒绝读写会话文件。"
                      : "内置模块不使用沙箱工作区文件桥。")
        }
        let interfaces = plugin.manifest.ui
        return [
            .init(id: "compute", title: "纯计算与命令", state: .wired,
                  detail: "在沙箱内同步求值，只读配置与持久状态。"),
            .init(id: "storage", title: "持久状态", state: .wired, detail: "键值存储随插件记录保存。"),
        ] + hostModuleRows(for: plugin) + [
            network,
            files,
            .init(id: "ui", title: "界面入口", state: .wired,
                  detail: interfaces.commands.isEmpty && interfaces.workspaceViews.isEmpty && interfaces.inspectorCards.isEmpty
                      ? "未声明命令或视图，仅提供工具。"
                      : "命令、检查器卡片与工作区视图由宿主渲染，不执行动态界面代码。"),
        ]
    }

    /// One row per declared host module. A plugin that declares none gets an explicit row: a sandbox script still
    /// cannot read the user's calendar, so saying nothing would read as "no need to mention it".
    private static func hostModuleRows(for plugin: DesktopInstalledPlugin) -> [DesktopPluginCapabilityRow] {
        let declared = plugin.manifest.capabilities.hostModules
        guard !declared.isEmpty else {
            return [.init(id: "host", title: "系统数据", state: .declaredNotWired,
                          detail: "未声明宿主模块；沙箱脚本无法访问日历、提醒事项等系统数据。")]
        }
        return declared.compactMap { raw in
            guard let module = DesktopPluginHostModule(rawValue: raw) else { return nil }
            let canWire = module.isWired(for: plugin)
            let wired = canWire && plugin.enabled
            let detail: String = if wired {
                module.wiredDetail
            } else if canWire {
                "插件已停用，宿主能力当前不生效。"
            } else if !plugin.isBuiltIn {
                DesktopPluginHostModule.thirdPartyRejectedDetail
            } else {
                DesktopPluginHostModule.unwiredDetail
            }
            return DesktopPluginCapabilityRow(id: "host:\(module.rawValue)", title: module.title,
                state: wired ? .wired : .declaredNotWired,
                detail: detail)
        }
    }

    static func permissionSummary(
        for plugin: DesktopInstalledPlugin,
        calendarEventCount: Int = 0,
        botActivityCount: Int = 0
    ) -> PermissionSummary {
        let domains = plugin.manifest.capabilities.networkDomains
        let modules = plugin.manifest.capabilities.hostModules
            .compactMap(DesktopPluginHostModule.init(rawValue:))
            .filter { $0.isWired(for: plugin) }
        let hostSummary = modules.map(\.title).joined(separator: "、")
        let networkSummary: String = if domains.isEmpty {
            hostSummary.isEmpty ? "无外部网络访问权限（纯本地沙箱运行）"
                : "无外部网络访问；\(hostSummary)经宿主直接读写，不经过沙箱"
        } else if plugin.id == "feishu_calendar" {
            "仅限飞书官方 CalDAV 与开放平台域名（\(domains.count) 个 HTTPS 域名）"
        } else if plugin.isBuiltIn {
            "内置模块经宿主原生客户端访问 \(domains.count) 个已声明 HTTPS 域名"
        } else {
            "仅限受控 HTTPS 访问已声明的 \(domains.count) 个白名单域名（\(domains.joined(separator: "、"))，20 秒超时）"
        }

        let sideEffectTools = plugin.manifest.tools.filter { $0.effect == .sideEffect || $0.effect == .idempotent }
        let readTools = plugin.manifest.tools.filter { $0.effect == .pure || $0.effect == .networkRead }
        let approvalSummary: String = if plugin.manifest.tools.isEmpty {
            "不注册智能体工具"
        } else if sideEffectTools.isEmpty {
            "全部 \(readTools.count) 项工具均为只读查询，不执行外部写入"
        } else {
            "\(readTools.count) 项只读查询直接可用；\(sideEffectTools.count) 项外部写入\(writeExamplesClause(for: sideEffectTools))需经你批准"
        }

        let readPrefixes = plugin.manifest.capabilities.workspaceReadPrefixes
        let writePrefixes = plugin.manifest.capabilities.workspaceWritePrefixes
        let workspaceSummary: String = if readPrefixes.isEmpty && writePrefixes.isEmpty {
            "禁止直接写入当前会话工作区文件"
        } else if writePrefixes.isEmpty {
            "仅允许读取当前会话工作区子目录：\(readPrefixes.joined(separator: "、"))；禁止写入文件"
        } else if readPrefixes.isEmpty {
            "仅允许在受控前缀内写入当前会话工作区：\(writePrefixes.joined(separator: "、"))"
        } else {
            "仅允许读取 \(readPrefixes.joined(separator: "、"))，并在受控前缀内写入 \(writePrefixes.joined(separator: "、"))"
        }

        var counts: [String] = []
        if !plugin.manifest.tools.isEmpty {
            counts.append("\(plugin.manifest.tools.count) 项工具")
        }
        if !plugin.manifest.ui.commands.isEmpty {
            counts.append("\(plugin.manifest.ui.commands.count) 条命令")
        }
        if !plugin.manifest.ui.workspaceViews.isEmpty {
            counts.append("\(plugin.manifest.ui.workspaceViews.count) 个视图")
        }
        let capabilityCountBadge = counts.isEmpty ? "基础扩展" : counts.joined(separator: " · ")

        var metaParts = [
            "插件 ID：\(plugin.id)",
            "版本：v\(plugin.manifest.version)",
            "协议：\(plugin.manifest.schema)",
            plugin.isBuiltIn ? "官方内置" : "扩展插件"
        ]
        if plugin.id == "feishu_calendar" {
            metaParts.append("本地缓存：\(calendarEventCount) 项日程 · \(botActivityCount) 条机器人动态")
        }

        return PermissionSummary(
            networkSummary: networkSummary,
            approvalSummary: approvalSummary,
            workspaceSummary: workspaceSummary,
            capabilityCountBadge: capabilityCountBadge,
            technicalMetadataLine: metaParts.joined(separator: " · ")
        )
    }

    private static func writeExamplesClause(for tools: [DesktopPluginToolManifest]) -> String {
        var labels: [String] = []
        for tool in tools {
            let label: String
            switch tool.name {
            case "create_event": label = "创建日程"
            case "update_event": label = "修改日程"
            case "delete_event": label = "删除日程"
            case "complete_reminder": label = "完成提醒"
            case "bot_send_message": label = "发消息"
            case "bot_create_doc": label = "建文档"
            case "meeting_closeout": label = "会后收口"
            default: label = tool.name
            }
            if !labels.contains(label) { labels.append(label) }
        }
        guard !labels.isEmpty else { return "" }
        if labels.count > 3 {
            return "（\(labels.prefix(3).joined(separator: "、"))等）"
        }
        return "（\(labels.joined(separator: "、"))）"
    }
}
