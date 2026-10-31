import SwiftUI
import UIKit

struct RuntimeSheetChrome<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(AmberTheme.foreground)
                            Text(subtitle)
                                .font(.footnote)
                                .foregroundStyle(AmberTheme.muted)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        AmberGlassCircleButton(systemImage: "xmark", accessibilityLabel: "关闭", size: 44, symbolSize: 15) {
                            dismiss()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 28)
                    .padding(.bottom, 4)

                    content
                }
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct RuntimeStatusCard: View {
    let defaultRuntime: IOSTerminalRuntimeKind
    let sshProfileName: String?
    let embeddedIshAvailable: Bool
    let embeddedIshEnabled: Bool
    let externalIshAvailable: Bool
    let experimentalRuntimesLinked: Bool
    let experimentalEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(AmberTheme.accentTint, in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("当前执行策略")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                    Text(strategySummary)
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.muted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                RuntimeStatusMetric(
                    title: IOSAppLocalization.string("默认", defaultValue: "默认"),
                    value: defaultRuntime.displayName,
                    color: AmberTheme.accent
                )
                RuntimeStatusMetric(
                    title: IOSAppLocalization.string("内置 iSH", defaultValue: "内置 iSH"),
                    value: embeddedIshAvailable
                        ? (embeddedIshEnabled ? "可回传" : "已禁用")
                        : IOSAppLocalization.string("未链接", defaultValue: "未链接"),
                    color: embeddedIshEnabled ? AmberTheme.accentGreen : AmberTheme.muted
                )
                RuntimeStatusMetric(
                    title: IOSAppLocalization.string("外部 iSH", defaultValue: "外部 iSH"),
                    value: externalIshAvailable
                        ? IOSAppLocalization.string("交接", defaultValue: "交接")
                        : IOSAppLocalization.string("不可用", defaultValue: "不可用"),
                    color: externalIshAvailable ? AmberTheme.accentAmber : AmberTheme.muted
                )
            }
        }
        .padding(14)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
    }

    private var strategySummary: String {
        let profile = sshProfileName
            ?? IOSAppLocalization.string(
                "未选择 SSH Profile",
                defaultValue: "未选择 SSH Profile"
            )
        let experimental: String
        if !experimentalRuntimesLinked {
            experimental = IOSAppLocalization.string(
                "当前构建未链接实验 Runtime",
                defaultValue: "当前构建未链接实验 Runtime"
            )
        } else {
            experimental = experimentalEnabled
                ? IOSAppLocalization.string(
                    "实验 Runtime 已显示",
                    defaultValue: "实验 Runtime 已显示"
                )
                : IOSAppLocalization.string(
                    "实验 Runtime 已隐藏",
                    defaultValue: "实验 Runtime 已隐藏"
                )
        }
        return IOSAppLocalization.formatted(
            "%@ · %@。聊天中的 iSH 工具会单独走前台审批。",
            defaultValue: "%@ · %@。聊天中的 iSH 工具会单独走前台审批。",
            arguments: [profile, experimental]
        )
    }
}

private struct RuntimeStatusMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AmberTheme.muted2)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct RuntimeChoiceRow: View {
    let runtime: IOSTerminalRuntimeKind
    let isSelected: Bool
    let isEnabled: Bool
    let isRecommended: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: runtimeIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isEnabled ? runtimeColor : AmberTheme.muted2)
                    .frame(width: 30, height: 30)
                    .background((isEnabled ? runtimeColor : AmberTheme.muted2).opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(runtime.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(isEnabled ? AmberTheme.foreground : AmberTheme.muted2)
                        if isRecommended {
                            RuntimePill(
                                text: IOSAppLocalization.string("推荐", defaultValue: "推荐"),
                                color: AmberTheme.accent
                            )
                        }
                        RuntimePill(
                            text: runtimeTier == .stable
                                ? IOSAppLocalization.string("稳定", defaultValue: "稳定")
                                : IOSAppLocalization.string("实验", defaultValue: "实验"),
                            color: runtimeTier == .stable ? AmberTheme.accentGreen : AmberTheme.accentAmber
                        )
                        if !isEnabled {
                            RuntimePill(
                                text: IOSAppLocalization.string("未启用", defaultValue: "未启用"),
                                color: AmberTheme.muted
                            )
                        }
                    }

                    Text(runtimeSummary)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AmberTheme.accent)
                }
            }
            .frame(minHeight: 56)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: isEnabled ? 0.985 : 1, haptic: isEnabled ? .selection : nil))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.62)
    }

    private var runtimeTier: IOSTerminalRuntimeTier {
        IOSTerminalRuntimeCapabilities.capability(for: runtime).tier
    }

    private var runtimeSummary: String {
        switch runtime {
        case .remoteSSH:
            return "稳定远程命令主线；需要 SSH Profile、认证凭证和 Host 信任"
        case .localIOSTools:
            return IOSAppLocalization.string(
                "AmberShell；受限文件/文本命令、管道、重定向与 CPython 3.14 python -c，无 PTY",
                defaultValue: "AmberShell；受限文件/文本命令、管道、重定向与 CPython 3.14 python -c，无 PTY"
            )
        case .remoteMosh:
            return "预留的移动会话方向；当前不建议作为默认环境"
        case .ishExperimental:
            return "内置 iSH 短命令 runner；无 PTY、stdin 和长会话"
        }
    }

    private var runtimeIcon: String {
        switch runtime {
        case .remoteSSH: "desktopcomputer"
        case .localIOSTools: "iphone"
        case .remoteMosh: "antenna.radiowaves.left.and.right"
        case .ishExperimental: "shippingbox"
        }
    }

    private var runtimeColor: Color {
        switch runtime {
        case .remoteSSH: AmberTheme.accent
        case .localIOSTools: AmberTheme.accentGreen
        case .remoteMosh: AmberTheme.accentCyan
        case .ishExperimental: AmberTheme.accentAmber
        }
    }
}

struct RuntimeToggleRow: View {
    let title: String
    let subtitle: String
    let isOn: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(isEnabled ? AmberTheme.foreground : AmberTheme.muted2)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                RuntimeSwitch(isOn: isOn)
            }
            .frame(minHeight: 56)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.58)
        .accessibilityValue(isOn ? "开启" : "关闭")
    }
}

struct RuntimeNavigationRow: View {
    let title: String
    let subtitle: String
    let value: String
    let systemImage: String
    var accent: Color = AmberTheme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 30, height: 30)
                    .background(accent.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(AmberTheme.foreground)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 7) {
                    Text(value)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.muted2)
                }
            }
            .frame(minHeight: 58)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.985, haptic: .selection))
    }
}

struct RuntimeValueRow: View {
    let title: String
    let subtitle: String
    let value: String
    let systemImage: String
    var showsChevron = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AmberTheme.accent)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(AmberTheme.muted)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted2)
            }
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct RuntimeInfoRow: View {
    let title: String
    let subtitle: String
    let value: String
    let systemImage: String
    var accent: Color = AmberTheme.accentAmber

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .background(accent.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 58)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct TerminalTaskRow: View {
    let task: IOSAdvancedTaskRecord
    var showsChevron = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.commandPreview.isEmpty ? task.title : task.commandPreview)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(task.status.title) · \(task.connectionSummary)\n\(summary)")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted2)
            }
        }
        .frame(minHeight: 62)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private var iconName: String {
        switch task.status {
        case .completed: "checkmark.circle.fill"
        case .failed, .timedOut, .interrupted: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        default: "terminal.fill"
        }
    }

    private var iconColor: Color {
        switch task.status {
        case .completed: AmberTheme.accentGreen
        case .failed, .timedOut, .interrupted: AmberTheme.accentRed
        case .cancelled: AmberTheme.muted2
        default: AmberTheme.accentAmber
        }
    }

    private var summary: String {
        if task.status == .running, !task.logTail.isEmpty {
            return task.logTail
        }
        return task.compactSummary
    }
}

struct RuntimeTextFieldRow: View {
    let title: String
    @Binding var text: String
    var placeholder: String
    var monospace = false
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField(placeholder, text: $text)
                .font(monospace ? .system(.subheadline, design: .monospaced) : .body)
                .foregroundStyle(AmberTheme.foreground)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboardType)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel(title)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

struct RuntimeSecureFieldRow: View {
    let title: String
    @Binding var text: String
    var placeholder: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)

            SecureField(placeholder, text: $text)
                .privacySensitive()
                .autocorrectionDisabled()
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(AmberTheme.foreground)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .accessibilityLabel(title)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

struct RuntimeActionRow: View {
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
        }
        .buttonStyle(.plain)
    }
}

struct RuntimeDivider: View {
    var body: some View {
        Divider()
            .overlay(AmberTheme.borderSoft)
            .padding(.leading, 14)
    }
}

struct SmokeResultCard: View {
    let result: IOSTerminalJobSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Text(result.runtime.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                RuntimePill(
                    text: IOSTerminalJobStatus(rawValue: result.status)?.title ?? result.status,
                    color: statusColor
                )
            }

            Text("退出码 \(result.exitCode.map(String.init) ?? "…")")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(AmberTheme.muted)

            if !result.outputTail.isEmpty {
                Text(result.outputTail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AmberTheme.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .textSelection(.enabled)
            }

            if let error = result.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accentRed)
            }
        }
        .padding(14)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
        .padding(.horizontal, 16)
    }

    private var statusColor: Color {
        switch IOSTerminalJobStatus(rawValue: result.status) {
        case .completed: AmberTheme.accentGreen
        case .queued, .running: AmberTheme.accentAmber
        case .failed, .timedOut, .interrupted: AmberTheme.accentRed
        case .cancelled: AmberTheme.muted2
        case nil: AmberTheme.accent
        }
    }
}

struct TerminalTaskDetailView: View {
    @Bindable var taskStore: IOSAdvancedTaskStore
    let taskId: String

    var body: some View {
        RuntimeSheetChrome(
            title: taskStore.task(id: taskId)?.kind == .embeddedIsh ? "内置 iSH Agent 作业" : "Remote SSH 作业",
            subtitle: "进程内作业会保留状态与输出尾部；应用重启后未完成作业会如实标记为已中断。"
        ) {
            if let task = taskStore.task(id: taskId) {
                VStack(spacing: 12) {
                    AmberFormGroup {
                        RemoteTaskDetailRow(title: "状态", value: task.status.title, color: statusColor(task.status))
                        RuntimeDivider()
                        RemoteTaskDetailRow(
                            title: task.kind == .embeddedIsh ? "运行环境" : "连接",
                            value: task.connectionSummary
                        )
                        if let workingDirectory = task.metadata["cwd"]?.nilIfBlank {
                            RuntimeDivider()
                            RemoteTaskDetailRow(title: "工作目录", value: workingDirectory, monospaced: true)
                        }
                        if let timeout = task.metadata["command_timeout_seconds"]?.nilIfBlank {
                            RuntimeDivider()
                            RemoteTaskDetailRow(title: "超时", value: "\(timeout) 秒")
                        }
                        if task.kind == .embeddedIsh {
                            RuntimeDivider()
                            RemoteTaskDetailRow(title: "模式", value: "异步非 PTY · 无 stdin")
                        }
                        RuntimeDivider()
                        RemoteTaskDetailRow(title: "Job ID", value: task.id, monospaced: true)
                    }

                    RemoteTaskTextCard(title: "命令", text: task.commandPreview)
                    if !task.logTail.isEmpty {
                        RemoteTaskTextCard(title: "输出尾部", text: task.logTail)
                    }
                    if let stderr = task.metadata["stderr_tail"]?.nilIfBlank {
                        RemoteTaskTextCard(title: "stderr 尾部", text: stderr, isError: true)
                    }
                    if !task.error.isEmpty {
                        Text(task.error)
                            .font(.footnote)
                            .foregroundStyle(AmberTheme.accentRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 16)
            } else {
                Text("该作业记录已不存在。")
                    .font(.body)
                    .foregroundStyle(AmberTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    private func statusColor(_ status: IOSAdvancedTaskStatus) -> Color {
        switch status {
        case .completed: AmberTheme.accentGreen
        case .failed, .timedOut, .interrupted: AmberTheme.accentRed
        case .cancelled: AmberTheme.muted2
        case .queued, .running, .approvalRequired: AmberTheme.accentAmber
        }
    }
}

private struct RemoteTaskDetailRow: View {
    let title: String
    let value: String
    var color: Color = AmberTheme.foreground2
    var monospaced = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .footnote.weight(.semibold))
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

private struct RemoteTaskTextCard: View {
    let title: String
    let text: String
    var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.muted)
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(isError ? AmberTheme.accentRed : AmberTheme.foreground2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
        .padding(.horizontal, 16)
    }
}

struct HostFingerprintCard: View {
    let status: RuntimeEnvironmentView.SSHStatus
    var hopLabel: String? = nil
    var replacesFingerprint = false
    var statusExpectedFingerprint = ""
    let onTrust: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch status {
            case .idle:
                FingerprintTitle(systemImage: "checkmark.shield", title: "尚未验证 Host 指纹", color: AmberTheme.foreground)
                Text("连接前需检查服务器可达性与 host key 指纹。未信任或指纹不匹配时不会提交认证。私钥留在本机，只用于签名。")
                    .fingerprintDescription()
            case .testing:
                FingerprintTitle(systemImage: "arrow.triangle.2.circlepath", title: "正在连接并获取 host key...", color: AmberTheme.foreground)
                Text("读取服务器公钥的 SHA256 指纹，请稍候。")
                    .fingerprintDescription()
            case .needsTrust(_, let fingerprint):
                FingerprintTitle(systemImage: "exclamationmark.triangle", title: replacesFingerprint ? "主机指纹变化，请人工核对" : "首次连接此 Host", color: replacesFingerprint ? AmberTheme.accentRed : AmberTheme.accentAmber)
                if let hopLabel { Text(hopLabel).font(.caption.weight(.semibold)) }
                if replacesFingerprint { Text("原指纹与当前主机不一致。请通过可信渠道核对后再替换。旧指纹：\(statusExpectedFingerprint)").fingerprintDescription() }
                FingerprintHash(label: "SERVER KEY · SHA256", value: fingerprint)
                Text("确认这是你信任的服务器后，显式点击「信任此 Host」才会保存指纹。")
                    .fingerprintDescription()
                HStack {
                    Button {
                        onTrust()
                    } label: {
                        Label(replacesFingerprint ? "确认替换此跳指纹" : "信任此 Host", systemImage: "checkmark")
                    }
                    .buttonStyle(RuntimeFilledButtonStyle())
                    Button("取消", action: onCancel)
                        .buttonStyle(RuntimeGlassButtonStyle())
                }
            case .success(let message):
                FingerprintTitle(systemImage: "checkmark.shield", title: "SSH 状态", color: AmberTheme.accentGreen)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accentGreen)
            case .failure(let message):
                FingerprintTitle(systemImage: "xmark.shield", title: "SSH 验证失败", color: AmberTheme.accentRed)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accentRed)
            }
        }
        .padding(14)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                .stroke(cardStroke, lineWidth: isFailure ? 1 : 0.5)
        }
        .padding(.horizontal, 16)
    }

    private var isFailure: Bool {
        if case .failure = status {
            return true
        }
        return false
    }

    private var cardBackground: Color {
        isFailure ? AmberTheme.accentRed.opacity(0.05) : AmberTheme.surface
    }

    private var cardStroke: Color {
        isFailure ? AmberTheme.accentRed : AmberTheme.borderSoft
    }
}

struct RuntimeMatrixCard: View {
    let capability: IOSTerminalRuntimeCapability

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text(capability.runtime.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                RuntimePill(text: capability.tier.displayName, color: capability.tier == .stable ? AmberTheme.accentGreen : AmberTheme.muted)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 7) {
                RuntimeCapabilityLine(title: "外部 CLI", state: capability.supportsExternalCLIByDefault)
                RuntimeCapabilityLine(title: "PTY", state: capability.supportsPTY)
                RuntimeCapabilityLine(title: "安装软件", state: capability.supportsPackageInstall)
                RuntimeCapabilityLine(title: "长任务", state: capability.supportsLongRunningJobs)
                RuntimeCapabilityLine(title: "交互登录", state: capability.supportsInteractiveLogin)
                RuntimeCapabilityLine(title: "文件同步", state: capability.supportsFileSync)
                RuntimeCapabilityLine(title: "上架安全", state: capability.appStoreSafeByDefault)
            }

            Text("License: \(capability.licenseClass.displayName)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(AmberTheme.muted2)
        }
        .padding(14)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
        .padding(.horizontal, 16)
    }
}

private struct RuntimeCapabilityLine: View {
    let title: String
    let state: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(state ? AmberTheme.accentGreen : AmberTheme.muted2)
            Text(title)
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(state ? "支持" : "不支持")
    }
}

private struct FingerprintTitle: View {
    let systemImage: String
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(color)
    }
}

private struct FingerprintHash: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(AmberTheme.muted2)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(AmberTheme.foreground2)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct RuntimePill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct RuntimeSwitch: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? AmberTheme.accent : AmberTheme.surface2)
            .frame(width: 48, height: 28)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
                    .padding(2)
            }
            .animation(.snappy(duration: 0.18), value: isOn)
    }
}

struct RuntimeFilledButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(minHeight: 44)
            .padding(.horizontal, 18)
            .background(AmberTheme.accent, in: Capsule())
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
    }
}

struct RuntimeGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AmberTheme.accent)
            .frame(minHeight: 44)
            .padding(.horizontal, 18)
            .background(AmberTheme.glass, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.65), lineWidth: 0.5)
            }
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
    }
}

extension Text {
    func fingerprintDescription() -> some View {
        self
            .font(.caption)
            .foregroundStyle(AmberTheme.muted)
            .lineSpacing(2)
    }

    func runtimeFootnote() -> some View {
        self
            .font(.caption)
            .foregroundStyle(AmberTheme.muted2)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 7)
    }
}
