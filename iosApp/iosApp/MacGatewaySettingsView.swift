import SwiftUI

struct MacGatewaySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(RouterPath.self) private var router
    @State private var confirmsUnpair = false

    private let store = MacGatewayStore.shared
    private static let refreshInterval: Duration = .seconds(10)

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        if let pending = store.pendingPairing {
                            confirmSection(pending)
                        } else if let connection = store.connection {
                            macSection(connection)
                            if let health = store.status?.health { healthSection(health) }
                            boardSection
                            unpairSection
                        } else {
                            pairSection
                        }
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .tint(AmberTheme.accent)
        .task(id: store.connection?.gatewayId) {
            guard store.connection != nil else { return }
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
        .confirmationDialog(L("取消与这台 Mac 的配对？"), isPresented: $confirmsUnpair, titleVisibility: .visible) {
            Button(L("取消配对"), role: .destructive) { Task { await store.unpair() } }
            Button(L("保留"), role: .cancel) {}
        } message: {
            Text(verbatim: L("此设备将不再收到这台 Mac 的推送。"))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回", size: 44, symbolSize: 20) {
                dismiss()
            }
            Spacer(minLength: 0)
            Text(verbatim: "Mac Gateway")
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Color.clear
                .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    // MARK: - Not paired

    private var pairSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "配对")
            AmberFormGroup {
                MacGatewayRow(icon: "qrcode.viewfinder", title: L("扫码配对"),
                            detail: L("在 Mac 终端运行 amber-gateway pair，用系统相机扫描")) {
                    EmptyView()
                }
                MacGatewayRowDivider()
                MacGatewayRow(icon: "doc.on.clipboard", title: L("粘贴配对链接"),
                            detail: L("从 AirDrop 或消息复制的 amber:// 链接"),
                            action: { store.pasteLinkFromClipboard() }) {
                    MacGatewayChevron()
                }
            }
            noticeFooter(fallback: L("把 Mac 上 Claude Code / Codex 任务的状态推送到手机。推送只含项目名与状态，不含代码与对话内容。"))
        }
    }

    private func confirmSection(_ payload: MacGatewayPairingPayload) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "确认配对")
            AmberFormGroup {
                MacGatewayRow(icon: "desktopcomputer", title: payload.name, detail: payload.addrs.joined(separator: " · ")) {
                    EmptyView()
                }
                MacGatewayRowDivider()
                MacGatewayRow(icon: "checkmark.shield", title: L("证书指纹"), detail: payload.fp) {
                    EmptyView()
                }
            }
            MacGatewaySectionFooter(text: L("请核对与 Mac 终端显示的证书指纹一致。"))
            AmberFormGroup {
                actionRow(L("配对"), color: AmberTheme.accent, isBusy: store.isBusy) {
                    Task { await store.confirmPairing() }
                }
                Divider().overlay(AmberTheme.borderSoft)
                actionRow(L("取消"), color: AmberTheme.muted, isBusy: false) {
                    store.pendingPairing = nil
                }
                .disabled(store.isBusy)
            }
            .padding(.top, 20)
            noticeFooter(fallback: nil)
        }
    }

    // MARK: - Paired

    private func macSection(_ connection: MacGatewayConnection) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Mac")
            AmberFormGroup {
                MacGatewayRow(icon: "desktopcomputer", title: connection.name, detail: reachabilityText) {
                    Button { Task { await store.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AmberTheme.accent)
                    .accessibilityLabel(Text(verbatim: L("刷新")))
                }
                MacGatewayRowDivider()
                MacGatewayRow(icon: "bell.badge", title: L("推送通知"), detail: pushDetail) {
                    if store.isSendingTestPush {
                        ProgressView().frame(width: 44, height: 44)
                    } else if store.status?.device.pushRegistered == true {
                        MacGatewayCapsuleButton(title: L("测试")) { Task { await store.sendTestPush() } }
                    } else {
                        MacGatewayCapsuleButton(title: L("开启")) { Task { await store.enablePush() } }
                    }
                }
            }
            noticeFooter(fallback: store.isReachable == false
                ? L("Mac 睡眠、合盖或断网时无法推送，也无法在这里查看状态。")
                : nil)
        }
    }

    private func healthSection(_ health: MacGatewayStatus.Health) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Mac 状态")
            AmberFormGroup {
                if let bytes = health.diskFreeBytes {
                    valueRow(icon: "internaldrive", title: L("磁盘剩余"),
                             value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal))
                    MacGatewayRowDivider()
                }
                if let percent = health.batteryPercent {
                    valueRow(icon: health.onBattery == true ? "battery.50" : "battery.100.bolt", title: L("电量"),
                             value: "\(percent)%" + (health.onBattery == true ? "" : " · " + L("接电源")))
                    MacGatewayRowDivider()
                }
                valueRow(icon: "memorychip", title: L("内存压力"), value: Self.levelLabel(health.memoryPressure))
                MacGatewayRowDivider()
                valueRow(icon: "thermometer.medium", title: L("温度"), value: Self.levelLabel(health.thermal))
            }
        }
    }

    private var boardSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "任务")
            AmberFormGroup {
                MacGatewayRow(icon: "checklist", title: L("打开任务看板"),
                              detail: L("定时任务、它们的运行，以及 Claude Code / Codex 会话"),
                              action: { router.navigate(to: .macTasks) }) {
                    MacGatewayChevron()
                }
            }
        }
    }

    private var unpairSection: some View {
        AmberFormGroup {
            actionRow(L("取消配对"), color: AmberTheme.accentRed, isBusy: store.isBusy) {
                confirmsUnpair = true
            }
        }
        .padding(.top, 28)
    }

    // MARK: - Text

    private var reachabilityText: String {
        switch store.isReachable {
        case nil: return L("正在连接…")
        case false: return L("无法连接")
        case true:
            guard let sampled = store.status?.health?.sampledAt else { return L("在线") }
            return L("在线") + " · " + L("更新于") + " " + sampled.formatted(.relative(presentation: .named))
        }
    }

    private var pushDetail: String {
        if let error = store.pushError { return error }
        return store.status?.device.pushRegistered == true ? L("已开启，任务需要你时会通知") : L("未开启")
    }

    private static func levelLabel(_ level: String) -> String {
        switch level {
        case "normal", "nominal": L("正常")
        case "warning", "fair": L("偏高")
        case "serious": L("过高")
        default: L("严重")
        }
    }

    // MARK: - Rows

    private func actionRow(_ title: String, color: Color, isBusy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if isBusy {
                    ProgressView()
                } else {
                    Text(verbatim: title).font(.body.weight(.semibold)).foregroundStyle(color)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private func valueRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            MacGatewayIconPlate(icon: icon)
            Text(verbatim: title).font(.body).foregroundStyle(AmberTheme.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: value).font(.subheadline).foregroundStyle(AmberTheme.muted)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private func noticeFooter(fallback: String?) -> some View {
        if let notice = store.notice {
            MacGatewaySectionFooter(text: notice.text, color: notice.isError ? .orange : AmberTheme.muted)
        } else if let fallback {
            MacGatewaySectionFooter(text: fallback)
        }
    }
}

private func L(_ key: String) -> String {
    IOSAppLocalization.string(key, defaultValue: key)
}
