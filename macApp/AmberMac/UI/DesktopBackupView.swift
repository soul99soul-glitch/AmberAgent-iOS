import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DesktopBackupView: View {
    @Bindable var workspace: DesktopWorkspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("备份与恢复").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(workspace.isManagingBackup)
            }
            Text("备份包含会话、会话文件、服务商与模型配置、记忆及本地知识资料。不包含钥匙串 API Key / 登录凭证；自定义请求头和请求体作为模型配置随备份保存，请注意其中填写的敏感信息。")
                .font(.system(size: 13)).foregroundStyle(DesktopTheme.muted(colorScheme)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                SecureField("备份密码（可选）", text: $password).textFieldStyle(.roundedBorder)
                    .disabled(workspace.isManagingBackup)
                Label(password.isEmpty ? "当前将导出未加密备份，文件内容可被直接读取。" : "将使用所填密码加密备份；恢复时需要相同密码。",
                      systemImage: password.isEmpty ? "lock.open" : "lock")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button("导出备份…", systemImage: "square.and.arrow.up") { exportBackup() }
                    .buttonStyle(.borderedProminent)
                Button("从备份恢复…", systemImage: "square.and.arrow.down") { restoreBackup() }
                Button("导入 iOS 备份…", systemImage: "iphone") { importIOSBackup() }
            }
            .disabled(workspace.isManagingBackup || workspace.isLoading)
            Text("恢复会新增会话与配置，保留当前数据。技能、SOUL 与通用偏好放入“备份恢复资料”会话文件，供检查后手动导入或应用。恢复加密备份前，请先填写原密码。导入 iOS 备份（.amberbackup）只新增会话副本，不导入 iOS 设置与凭证；未设口令的 iOS 备份可留空密码。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if workspace.isManagingBackup {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("正在处理备份…").font(.callout)
                    Spacer()
                    Button("取消") { workspace.cancelBackup() }
                }
            }
            if let status = workspace.backupStatusMessage {
                Label(status, systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = workspace.backupErrorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(24).frame(width: 620, height: 440)
        .background(DesktopTheme.background(colorScheme))
        .tint(DesktopTheme.accent)
        .interactiveDismissDisabled(workspace.isManagingBackup)
        .onDisappear { password = "" }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: DesktopBackup.fileExtension) ?? .data]
        panel.nameFieldStringValue = "Amber-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).\(DesktopBackup.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url {
            workspace.exportBackup(to: url, password: password.isEmpty ? nil : password)
        }
    }

    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: DesktopBackup.fileExtension) ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            workspace.importBackup(from: url, password: password.isEmpty ? nil : password)
        }
    }

    private func importIOSBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: DesktopIOSBackup.fileExtension) ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            workspace.importIOSBackup(from: url, password: password.isEmpty ? nil : password)
        }
    }
}
