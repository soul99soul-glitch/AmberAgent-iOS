import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement
@preconcurrency import GatewayCore
@preconcurrency import GatewayPush

/// 设置 › Mac Gateway: run the embedded gateway, pair phones, manage push credentials.
struct DesktopGatewaySettingsView: View {
    @Bindable var gateway: DesktopGateway
    @State private var confirmsDisable = false
    @State private var revoking: PairedDevice?
    @State private var importingAPNs = false
    @State private var credentialError: String?
    @State private var removingCredential: CredentialKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("让 iPhone 接收 Mac 上 Claude Code、Codex 与定时任务的状态，并在手机上批准定时任务的工具调用。推送只含任务名与状态，不含代码和对话内容。")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).fixedSize(horizontal: false, vertical: true)
                serviceCard
                if let message = gateway.message {
                    Label(message, systemImage: "info.circle")
                        .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
                if gateway.isEnabled {
                    devicesCard
                    credentialsCard
                    codexCard
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { gateway.startPolling() }
        .onDisappear { gateway.stopPolling() }
        .sheet(item: Binding(get: { gateway.pairing.map { PairingSheetID(url: $0.url) } }, set: { if $0 == nil { gateway.cancelPairing() } })) { _ in
            DesktopGatewayPairingSheet(gateway: gateway)
        }
        .sheet(isPresented: $importingAPNs) { DesktopAPNsImportSheet(gateway: gateway) }
        .confirmationDialog("停用 Mac Gateway？", isPresented: $confirmsDisable, titleVisibility: .visible) {
            Button("停用", role: .destructive) { gateway.disable() }
            Button("取消", role: .cancel) {}
        } message: { Text("后台服务会停止，Claude Code / Codex 的 hooks 会移除。已配对的手机和推送凭据保留，重新启用后继续可用。") }
        .confirmationDialog("吊销这台设备？", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            Button("吊销", role: .destructive) { if let revoking { gateway.revoke(revoking) }; revoking = nil }
            Button("取消", role: .cancel) { revoking = nil }
        } message: { Text("它的访问令牌立即失效，不再收到推送；需要时重新扫码配对。") }
        .confirmationDialog("移除推送凭据？", isPresented: Binding(get: { removingCredential != nil }, set: { if !$0 { removingCredential = nil } }),
            titleVisibility: .visible) {
            Button("移除", role: .destructive) { if let removingCredential { gateway.deleteCredentials(removingCredential) }; removingCredential = nil }
            Button("取消", role: .cancel) { removingCredential = nil }
        } message: { Text("移除后这类手机收不到推送。APNs 的 .p8 只能从 Apple 下载一次，请确认已备份原文件。") }
        .alert("导入未完成", isPresented: Binding(get: { credentialError != nil }, set: { if !$0 { credentialError = nil } })) {
            Button("知道了") { credentialError = nil }
        } message: { Text(credentialError ?? "") }
    }

    // MARK: cards

    private var serviceCard: some View {
        card {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("后台服务").font(.system(size: 14, weight: .semibold))
                    Text(statusText).font(.system(size: 12)).foregroundStyle(statusColor)
                }
                Spacer()
                if gateway.status == .needsApproval {
                    Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                }
                Toggle("启用 Mac Gateway", isOn: Binding(get: { gateway.isEnabled }, set: { value in
                    if value { gateway.enable() } else { confirmsDisable = true }
                }))
                .labelsHidden().toggleStyle(.switch)
            }
            if gateway.isEnabled {
                Divider()
                HStack {
                    Text("状态目录").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    Text(gateway.paths.stateDir.path).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DesktopTheme.inkSecondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([gateway.paths.stateDir]) }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private var devicesCard: some View {
        card {
            HStack {
                Text("已配对设备").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("配对手机…") { gateway.startPairing() }.disabled(gateway.status != .running)
            }
            if gateway.devices.isEmpty {
                Text("还没有配对设备。点「配对手机」，用 iPhone 系统相机扫描二维码。")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            }
            ForEach(Array(gateway.devices.enumerated()), id: \.element.id) { index, device in
                if index > 0 { Divider() }
                HStack(spacing: 12) {
                    Image(systemName: device.name.localizedCaseInsensitiveContains("iPad") ? "ipad" : device.platform == .ios ? "iphone" : "smartphone")
                        .font(.system(size: 15)).foregroundStyle(DesktopTheme.accent).frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(deviceDetail(device)).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).lineLimit(1)
                    }
                    Spacer()
                    Button("测试推送") { Task { await gateway.testPush(device) } }
                        .disabled(device.pushToken == nil || gateway.isTestingPush)
                    Button("吊销", role: .destructive) { revoking = device }
                }
            }
        }
    }

    private var credentialsCard: some View {
        card {
            Text("推送凭据").font(.system(size: 14, weight: .semibold))
            Text("只需导入你手机对应的一种。凭据保存在状态目录 secrets/（仅本用户可读），不会离开这台 Mac。")
                .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(CredentialKind.allCases.enumerated()), id: \.element) { index, kind in
                if index > 0 { Divider() }
                HStack(spacing: 12) {
                    Text(kind.displayName).font(.system(size: 13))
                    Spacer()
                    if gateway.credentials.contains(kind) {
                        Label("已导入", systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                        Button("移除", role: .destructive) { removingCredential = kind }.buttonStyle(.borderless)
                    } else {
                        Button("导入…") { importCredentials(kind) }
                    }
                }
            }
        }
    }

    private var codexCard: some View {
        card {
            Text("Codex 需要手动信任一次").font(.system(size: 14, weight: .semibold))
            Text("在 Codex 中输入 /hooks，信任命令为下面这一行的 hook（Codex 的安全机制，无法代劳）。之后更新 Amber 不需要重新信任。")
                .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).fixedSize(horizontal: false, vertical: true)
            Text(gateway.installation.hookCommand("codex"))
                .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.hairline))
    }

    // MARK: text

    private var statusText: String {
        switch gateway.status {
        case .off: "未启用"
        case .needsApproval: "需要在「系统设置 › 通用 › 登录项」中允许 Amber 在后台运行"
        case .starting: "正在启动…"
        case .running: "运行中 · 登录后自动启动，关闭 Amber 也会继续运行"
        case .failed(let reason): reason
        }
    }

    private var statusColor: Color {
        switch gateway.status {
        case .needsApproval, .failed: DesktopTheme.danger
        default: DesktopTheme.inkTertiary
        }
    }

    private func deviceDetail(_ device: PairedDevice) -> String {
        let push = device.pushToken == nil ? "未上报推送 token" : "推送已开启"
        return [push, "配对于 " + device.pairedAt.formatted(date: .abbreviated, time: .omitted),
                "最后活跃 " + device.lastSeenAt.formatted(.relative(presentation: .named))].joined(separator: " · ")
    }

    private func importCredentials(_ kind: CredentialKind) {
        if kind == .apns { importingAPNs = true; return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = kind == .fcm ? "选择 Firebase 服务账号 JSON" : "选择 AGC 服务账号密钥 JSON"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        credentialError = gateway.importServiceAccount(kind, file: url)
    }

    private struct PairingSheetID: Identifiable { let url: String; var id: String { url } }
}

/// QR code + link for `amber://gateway/pair`. Shows the paired phone briefly, then closes itself.
struct DesktopGatewayPairingSheet: View {
    let gateway: DesktopGateway
    @Environment(\.dismiss) private var dismiss
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 16) {
            Text("配对手机").font(DesktopTheme.serif(size: 20, weight: .semibold))
            if let session = gateway.pairing {
                if let name = session.pairedDeviceName {
                    Image(systemName: "checkmark.circle").font(.system(size: 44)).foregroundStyle(DesktopTheme.accent)
                        .frame(width: 240, height: 240)
                    Text("已配对 \(name)").font(.system(size: 14, weight: .medium))
                    Text(gateway.credentials.contains(.apns) ? "可以在设备列表里发一条测试推送确认。" : "还收不到推送：请导入 APNs 凭据。")
                        .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                } else {
                    if let image = Self.qrImage(session.url) {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 240, height: 240)
                            .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("配对二维码")
                    }
                    Text("用 iPhone 系统相机扫码，点「在 Amber 中打开」，核对证书指纹后配对。")
                        .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkSecondary).multilineTextAlignment(.center)
                    VStack(alignment: .leading, spacing: 6) {
                        row("证书指纹", session.fingerprint, mono: true)
                        row("地址", session.addresses.joined(separator: " · "), mono: false)
                        row("有效期", remaining(session.expiresAt), mono: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                if let session = gateway.pairing, session.pairedDeviceName == nil {
                    Button("复制配对链接") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.url, forType: .string)
                    }
                }
                Spacer()
                Button(gateway.pairing?.pairedDeviceName == nil ? "取消" : "完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(DesktopTheme.paper)
        .task {
            while !Task.isCancelled {
                now = Date()
                if gateway.pairing == nil { dismiss(); return }
                if gateway.pairing?.pairedDeviceName != nil {
                    try? await Task.sleep(for: .seconds(2))
                    dismiss(); return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func row(_ title: String, _ value: String, mono: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).frame(width: 56, alignment: .leading)
            Text(value).font(.system(size: mono ? 11 : 12, design: mono ? .monospaced : .default)).foregroundStyle(DesktopTheme.inkSecondary)
                .textSelection(.enabled).lineLimit(mono ? 1 : nil).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: !mono)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func remaining(_ expiry: Date) -> String {
        let seconds = max(0, Int(expiry.timeIntervalSince(now)))
        return String(format: "%d:%02d，仅可使用一次", seconds / 60, seconds % 60)
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// APNs needs the .p8 plus three identifiers, so it gets a small form instead of a bare file picker.
struct DesktopAPNsImportSheet: View {
    let gateway: DesktopGateway
    @Environment(\.dismiss) private var dismiss
    @State private var keyFile: URL?
    @State private var keyId = ""
    @State private var teamId = ""
    @State private var topic = "app.amber.ios"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入 APNs 凭据").font(DesktopTheme.serif(size: 20, weight: .semibold))
            Text(".p8 只能从 Apple 下载一次，导入后请自行离线备份原文件。")
                .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            HStack {
                Text(keyFile?.lastPathComponent ?? "未选择 .p8 文件")
                    .font(.system(size: 13)).foregroundStyle(keyFile == nil ? DesktopTheme.inkTertiary : DesktopTheme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("选择…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
                    if panel.runModal() == .OK { keyFile = panel.url }
                }
            }
            field("Key ID", $keyId, prompt: "10 位，如 AB12CD34EF")
            field("Team ID", $teamId, prompt: "开发者团队 ID")
            field("Bundle ID", $topic, prompt: "手机 App 的 Bundle ID")
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(DesktopTheme.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导入") {
                    guard let keyFile else { return }
                    error = gateway.importAPNs(key: keyFile, keyId: keyId, teamId: teamId, topic: topic)
                    if error == nil { dismiss() }
                }
                .buttonStyle(.desktopProminent)
                .disabled(keyFile == nil || [keyId, teamId, topic].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(DesktopTheme.paper)
    }

    private func field(_ title: String, _ text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            TextField(prompt, text: text).textFieldStyle(.desktop)
        }
    }
}
