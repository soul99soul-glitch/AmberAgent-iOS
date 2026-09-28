import SwiftUI

struct MacGatewaySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @State private var confirmsUnpair = false

    private let store = MacGatewayStore.shared
    private static let refreshInterval: Duration = .seconds(10)
    private static let visibleTaskLimit = 20

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
                            tasksSection
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
                settingsRow(icon: "qrcode.viewfinder", title: L("扫码配对"),
                            detail: L("在 Mac 终端运行 amber-gateway pair，用系统相机扫描")) {
                    EmptyView()
                }
                rowDivider
                settingsRow(icon: "doc.on.clipboard", title: L("粘贴配对链接"),
                            detail: L("从 AirDrop 或消息复制的 amber:// 链接"),
                            action: { store.pasteLinkFromClipboard() }) {
                    chevron
                }
            }
            noticeFooter(fallback: L("把 Mac 上 Claude Code / Codex 任务的状态推送到手机。推送只含项目名与状态，不含代码与对话内容。"))
        }
    }

    private func confirmSection(_ payload: MacGatewayPairingPayload) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "确认配对")
            AmberFormGroup {
                settingsRow(icon: "desktopcomputer", title: payload.name, detail: payload.addrs.joined(separator: " · ")) {
                    EmptyView()
                }
                rowDivider
                settingsRow(icon: "checkmark.shield", title: L("证书指纹"), detail: payload.fp) {
                    EmptyView()
                }
            }
            sectionFooter(L("请核对与 Mac 终端显示的证书指纹一致。"))
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
                settingsRow(icon: "desktopcomputer", title: connection.name, detail: reachabilityText) {
                    Button { Task { await store.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AmberTheme.accent)
                    .accessibilityLabel(Text(verbatim: L("刷新")))
                }
                rowDivider
                settingsRow(icon: "bell.badge", title: L("推送通知"), detail: pushDetail) {
                    if store.isSendingTestPush {
                        ProgressView().frame(width: 44, height: 44)
                    } else if store.status?.device.pushRegistered == true {
                        capsuleButton(L("测试")) { Task { await store.sendTestPush() } }
                    } else {
                        capsuleButton(L("开启")) { Task { await store.enablePush() } }
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
                    rowDivider
                }
                if let percent = health.batteryPercent {
                    valueRow(icon: health.onBattery == true ? "battery.50" : "battery.100.bolt", title: L("电量"),
                             value: "\(percent)%" + (health.onBattery == true ? "" : " · " + L("接电源")))
                    rowDivider
                }
                valueRow(icon: "memorychip", title: L("内存压力"), value: Self.levelLabel(health.memoryPressure))
                rowDivider
                valueRow(icon: "thermometer.medium", title: L("温度"), value: Self.levelLabel(health.thermal))
            }
        }
    }

    private var tasksSection: some View {
        let sessions = Array((store.status?.sessions ?? []).prefix(Self.visibleTaskLimit))
        return VStack(spacing: 0) {
            AmberSectionLabel(text: "任务")
            AmberFormGroup {
                if let url = store.status?.synaraURL.flatMap(URL.init(string:)) {
                    settingsRow(icon: "bubble.left.and.text.bubble.right", title: L("在 Synara 中回复或确认"),
                                detail: L("在浏览器中打开 Synara，处理其中的任务"), action: { openURL(url) }) {
                        chevron
                    }
                    rowDivider
                }
                if sessions.isEmpty {
                    settingsRow(icon: "tray", title: L("暂无任务"),
                                detail: L("在 Mac 上使用 Claude Code 或 Codex 后会出现在这里")) {
                        EmptyView()
                    }
                }
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { rowDivider }
                    settingsRow(icon: Self.agentIcon(session.agent), title: session.subject, detail: taskDetail(session)) {
                        Toggle("", isOn: Binding(
                            get: { session.monitored },
                            set: { value in Task { await store.setMonitored(session, value) } }
                        ))
                        .labelsHidden()
                        .tint(AmberTheme.accent)
                        .accessibilityLabel(Text(verbatim: L("推送") + " " + session.subject))
                    }
                }
            }
            if !sessions.isEmpty {
                sectionFooter(L("关闭开关后，该任务不再推送。"))
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

    private func taskDetail(_ session: MacGatewayStatus.Session) -> String {
        let agent = switch session.agent {
        case "claude": "Claude Code"
        case "codex": "Codex"
        default: L("任务")
        }
        let state = switch session.state {
        case "running": L("运行中")
        case "waiting": session.waitReason == "permission" ? L("等你确认") : L("等你回复")
        case "stalled": L("可能卡住了")
        case "completed": L("已完成")
        default: session.abnormal ? L("意外中断") : L("已停止")
        }
        return [agent, session.host, state, session.updatedAt.formatted(.relative(presentation: .named))]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private static func agentIcon(_ agent: String) -> String {
        switch agent {
        case "claude": "sparkles"
        case "codex": "chevron.left.forwardslash.chevron.right"
        default: "terminal"
        }
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

    private var rowDivider: some View {
        Divider().overlay(AmberTheme.borderSoft).padding(.leading, 54)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AmberTheme.muted)
    }

    private func capsuleButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
                .background(AmberTheme.accentTint, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AmberTheme.accent)
    }

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
            iconPlate(icon)
            Text(verbatim: title).font(.body).foregroundStyle(AmberTheme.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: value).font(.subheadline).foregroundStyle(AmberTheme.muted)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
    }

    private func settingsRow<Trailing: View>(icon: String, title: String, detail: String,
        action: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            if let action {
                Button(action: action) { rowContent(icon: icon, title: title, detail: detail) }
                    .buttonStyle(.plain)
            } else {
                rowContent(icon: icon, title: title, detail: detail)
            }
            if dynamicTypeSize.isAccessibilitySize {
                HStack { Spacer(minLength: 0); trailing() }
            } else {
                trailing().fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 12 : 4)
    }

    private func rowContent(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            iconPlate(icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.body).foregroundStyle(AmberTheme.foreground)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Text(verbatim: detail).font(.caption).foregroundStyle(AmberTheme.muted)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private func iconPlate(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(AmberTheme.accent)
            .frame(width: 28, height: 28)
            .background(AmberTheme.accentTint, in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func noticeFooter(fallback: String?) -> some View {
        if let notice = store.notice {
            sectionFooter(notice.text, color: notice.isError ? .orange : AmberTheme.muted)
        } else if let fallback {
            sectionFooter(fallback)
        }
    }

    private func sectionFooter(_ text: String, color: Color = AmberTheme.muted) -> some View {
        Text(verbatim: text)
            .font(.caption2)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

private func L(_ key: String) -> String {
    IOSAppLocalization.string(key, defaultValue: key)
}
