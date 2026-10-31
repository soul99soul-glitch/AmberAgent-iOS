import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension DesktopPluginsSettingsView {
    // MARK: - Tier 3: General Settings Card (通用设置)

    func generalSettingsCard(
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

    func advancedSettingsCard(
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

    func permissionsAndTechnicalCard(
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

    func permissionRow(symbol: String, title: String, detail: String) -> some View {
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

    func arquielSurfaceCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesktopTheme.card, in: shape)
            .overlay(shape.strokeBorder(DesktopTheme.hairlineStrong, lineWidth: 0.85))
    }

    func statusPill(text: String, state: DesktopPluginConnectionState) -> some View {
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
    func alignedSettingRow(
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
    func fieldInputControl(
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

    func cleanFieldTitle(_ field: DesktopPluginSettingField) -> String {
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

    func conciseFieldSubtitle(for field: DesktopPluginSettingField) -> String? {
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

    func resolveFields(in plugin: DesktopInstalledPlugin, keys: [String]) -> [DesktopPluginSettingField] {
        let byKey = Dictionary(uniqueKeysWithValues: plugin.manifest.settingsSchema.map { ($0.key, $0) })
        return keys.compactMap { byKey[$0] }
    }

    func draftBinding(key: String, defaultValue: String) -> Binding<String> {
        Binding(
            get: { draftSettings[key] ?? defaultValue },
            set: { draftSettings[key] = $0 }
        )
    }

    func hasUnsavedChanges(for plugin: DesktopInstalledPlugin) -> Bool {
        for field in plugin.manifest.settingsSchema {
            let current = draftSettings[field.key] ?? field.defaultValue
            let saved = plugins.settingValue(pluginID: plugin.id, key: field.key)
            if current != saved {
                return true
            }
        }
        return false
    }

    func effectBadgeText(_ effect: DesktopToolEffect) -> String {
        switch effect {
        case .pure: "只读"
        case .networkRead: "网络读取"
        case .idempotent: "幂等变更（需批准）"
        case .sideEffect: "外部写入（需批准）"
        }
    }

    // MARK: - Actions

    func ensureValidSelection() {
        if case .ext(let id) = selection, !plugins.plugins.contains(where: { $0.id == id }) {
            if let first = plugins.plugins.first {
                selection = .ext(first.id)
            } else {
                selection = .core(.taskBoard)
            }
        }
    }

    func loadDraftSettings() {
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
    func saveDraftSettings(for pluginID: String) -> Bool {
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

    func syncFeishu() {
        Task {
            do {
                let message = try await plugins.syncFeishuCalendar()
                setStatus(message, isError: false)
            } catch {
                setStatus(error.localizedDescription, isError: true)
            }
        }
    }

    func sendTestBotCard() {
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

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "导入 Amber 扩展插件"
        panel.message = "选择包含 plugin.json 与 main.js 的插件文件夹，或直接选择 plugin.json 文件。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, .folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let plan = try plugins.inspectPluginPackage(at: url)
            if plan.requiresUserApproval {
                pendingInstallPlan = plan
                return
            }
            let id = try plugins.importPlugin(from: url, approvePermissions: true)
            selection = .ext(id)
            loadDraftSettings()
            setStatus("已成功导入并启用插件「\(id)」。", isError: false)
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    func removePlugin(id: String) {
        do {
            try plugins.removePlugin(id: id)
            ensureValidSelection()
            loadDraftSettings()
            setStatus("已移除插件「\(id)」。", isError: false)
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    func setStatus(_ text: String, isError: Bool) {
        statusMessage = text
        statusIsError = isError
    }

    func statusBanner(text: String, isError: Bool) -> some View {
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

struct FlowTagRow: View {
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

struct DesktopWrappingFlowLayout: Layout {
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
