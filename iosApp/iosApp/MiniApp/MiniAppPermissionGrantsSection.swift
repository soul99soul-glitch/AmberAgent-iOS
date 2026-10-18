import SwiftUI

@MainActor
struct MiniAppPermissionGrantsSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let app: IOSMiniAppRecord
    let systemCapabilitiesEnabled: Bool
    let grants: [IOSMiniAppGrantRecord]
    let onDecision: (String, IOSMiniAppGrantDecision) -> Void

    var body: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "权限")
            AmberFormGroup {
                if !systemCapabilitiesEnabled,
                   app.permissions.contains(where: { isSystemCapabilityPermission($0) }) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AmberTheme.accentAmber)
                            .accessibilityHidden(true)
                        Text("系统交互已在小应用设置中关闭。系统相关权限会保留授权意图，但当前无法调用。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    MiniAppCapabilityDivider(leading: 14)
                }

                if app.permissions.isEmpty {
                    MiniAppCapabilityStatusRow(row: .init(
                        title: IOSAppLocalization.string("无需额外权限", defaultValue: "无需额外权限"),
                        subtitle: IOSAppLocalization.string(
                            "这个小应用只用基础能力。",
                            defaultValue: "这个小应用只用基础能力。"
                        ),
                        status: IOSAppLocalization.string("就绪", defaultValue: "就绪"),
                        tint: AmberTheme.accentGreen
                    ))
                } else {
                    ForEach(Array(app.permissions.enumerated()), id: \.element) { index, permission in
                        let stacksControls = dynamicTypeSize.isAccessibilitySize ||
                            (!systemCapabilitiesEnabled && isSystemCapabilityPermission(permission))
                        let layout = stacksControls
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                            : AnyLayout(HStackLayout(spacing: 12))
                        layout {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(miniAppPermissionDisplayName(permission))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AmberTheme.foreground)
                                Text(grantDescription(permission))
                                    .font(.caption)
                                    .foregroundStyle(AmberTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Menu {
                                Button {
                                    onDecision(permission, .allow)
                                } label: {
                                    Label("允许", systemImage: "checkmark.circle")
                                }
                                Button(role: .destructive) {
                                    onDecision(permission, .deny)
                                } label: {
                                    Label("拒绝", systemImage: "xmark.circle")
                                }
                            } label: {
                                Text(grantTitle(permission: permission))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(grantTint(permission: permission))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .frame(minHeight: 32)
                                    .background(
                                        grantTint(permission: permission).opacity(0.12),
                                        in: Capsule()
                                    )
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .frame(minHeight: 44)
                            .accessibilityLabel(miniAppPermissionDisplayName(permission))
                            .accessibilityValue(grantTitle(permission: permission))
                            .accessibilityHint("更改授权")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        if index < app.permissions.count - 1 {
                            MiniAppCapabilityDivider(leading: 14)
                        }
                    }
                }
            }
        }
    }

    private func grantDecision(_ permission: String) -> IOSMiniAppGrantDecision? {
        let normalized = IOSMiniAppPermission.normalized(permission)
        return grants.first { $0.permission == normalized }?.decision
    }

    private func grantTitle(permission: String) -> String {
        let key = grantDecision(permission)?.title ?? "未设置"
        let title = IOSAppLocalization.string(key, defaultValue: key)
        guard !systemCapabilitiesEnabled,
              isSystemCapabilityPermission(permission) else {
            return title
        }
        return IOSAppLocalization.formatted(
            "%@ · 全局关闭", defaultValue: "%@ · 全局关闭", arguments: [title]
        )
    }

    private func grantTint(permission: String) -> Color {
        if !systemCapabilitiesEnabled, isSystemCapabilityPermission(permission) {
            return AmberTheme.muted2
        }
        switch grantDecision(permission) {
        case .allow:
            return AmberTheme.accentGreen
        case .deny:
            return AmberTheme.accentRed
        case nil:
            return AmberTheme.accentAmber
        }
    }

    private func isSystemCapabilityPermission(_ permission: String) -> Bool {
        switch IOSMiniAppPermission(rawValue: permission) {
        case .haptics, .device, .screen, .speech, .share, .openURL:
            return true
        default:
            return false
        }
    }

    private func grantDescription(_ permission: String) -> String {
        let key: String?
        switch IOSMiniAppPermission(rawValue: permission) {
        case .storage: key = "允许读写这个小应用自己的本地数据。"
        case .toast: key = "允许显示提示信息。"
        case .theme: key = "允许读取当前主题色。"
        case .network: key = "允许访问 HTTPS 网络。"
        case .externalImages: key = "允许加载外链图片。"
        case .search: key = "允许使用网页搜索。"
        case .clipboardCopy: key = "只写剪贴板，不读取。"
        case .hostUpdateBoardSummary: key = "允许更新这个小应用的深度阅读摘要。"
        case .hostContext: key = "允许读取必要的宿主上下文。"
        case .hostSendToConversation: key = "允许生成聊天草稿，不会自动发送。"
        case .hostCreateArtifact: key = "允许创建内容卡片。"
        case .aiGenerate: key = "允许调用当前聊天模型。"
        case .sharedStore: key = "允许使用这个小应用自己的本地存储。"
        case .eventBus: key = "允许在运行期间发送本地事件。"
        case .launch: key = "允许打开其他小应用。"
        case .sensor: key = "允许订阅设备传感器。"
        case .location: key = "允许读取当前位置。"
        case .clipboardRead: key = "允许读取剪贴板文本。"
        case .haptics: key = "允许播放短暂振动和触感反馈。"
        case .device: key = "允许读取系统版本、语言、电量和无障碍偏好，不包含设备标识。"
        case .screen: key = "允许调整亮度和保持常亮，离开或进入后台时恢复。"
        case .speech: key = "允许使用系统声音朗读文本，离开或进入后台时停止。"
        case .share: key = "允许展示系统分享面板，内容由你确认分享。"
        case .openURL: key = "允许在每次确认后打开网页、邮件或拨号链接。"
        case nil: key = nil
        }
        guard let key else {
            guard !permission.isEmpty else {
                return IOSAppLocalization.string("权限", defaultValue: "权限")
            }
            return IOSAppLocalization.formatted(
                "未识别的权限标识：%@",
                defaultValue: "未识别的权限标识：%@",
                arguments: [permission]
            )
        }
        return IOSAppLocalization.string(key, defaultValue: key)
    }
}

@MainActor
func miniAppPermissionDisplayName(_ permission: String) -> String {
    let key: String?
    switch IOSMiniAppPermission(rawValue: permission) {
    case .storage: key = "本地存储"
    case .toast: key = "提示"
    case .theme: key = "主题"
    case .network: key = "网络"
    case .search: key = "搜索"
    case .clipboardCopy: key = "写入剪贴板"
    case .aiGenerate: key = "调用 AI"
    case .sharedStore: key = "共享存储"
    case .eventBus: key = "事件"
    case .hostUpdateBoardSummary: key = "更新摘要"
    case .hostContext: key = "读取上下文"
    case .hostSendToConversation: key = "写回聊天"
    case .hostCreateArtifact: key = "创建内容卡片"
    case .externalImages: key = "外链图片"
    case .launch: key = "打开其他小应用"
    case .sensor: key = "传感器"
    case .location: key = "定位"
    case .clipboardRead: key = "读取剪贴板"
    case .haptics: key = "振动与触感"
    case .device: key = "设备与电池信息"
    case .screen: key = "屏幕控制"
    case .speech: key = "语音朗读"
    case .share: key = "系统分享"
    case .openURL: key = "打开外部链接"
    case nil: key = nil
    }
    guard let key else {
        guard !permission.isEmpty else {
            return IOSAppLocalization.string("权限", defaultValue: "权限")
        }
        return IOSAppLocalization.formatted(
            "未知权限：%@",
            defaultValue: "未知权限：%@",
            arguments: [permission]
        )
    }
    return IOSAppLocalization.string(key, defaultValue: key)
}
