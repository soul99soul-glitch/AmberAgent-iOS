import SwiftUI
@preconcurrency import Shared

enum AmberMultiDeviceTab: String, CaseIterable, Identifiable, Hashable {
    case cloud
    case mac
    case watch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cloud:
            return IOSAppLocalization.string("云端", defaultValue: "云端")
        case .mac:
            return "Mac"
        case .watch:
            return "Watch"
        }
    }
}

enum AmberMultiDevicePairingClassifier {
    /// Honest classification for the current single-slot gateway connection.
    /// Never invents a second connection when only one peer is paired.
    static func isMacConnection(connection: MacGatewayConnection?, status: MacGatewayStatus?) -> Bool {
        guard let connection else { return false }
        if status?.health?.batteryPercent != nil {
            return true
        }
        let label = AmberHostSwitcherPillPolicy.remoteDisplayLabel(connectionName: connection.name)
        return label.title == "Mac"
    }
}

@MainActor
struct AmberMultiDeviceSettingsView: View {
    let sharedSettings: IOSSharedSettingsStore
    let conversationStore: IOSConversationStore
    var initialTab: AmberMultiDeviceTab = .cloud

    @Environment(\.dismiss) private var dismiss
    @Environment(RouterPath.self) private var router
    @State private var selectedTab: AmberMultiDeviceTab
    @Namespace private var tabSelection
    @State private var confirmsUnpairMac = false
    @State private var showingMacPairingSheet = false
    @State private var showingCloudPairingSheet = false

    private let gatewayStore = MacGatewayStore.shared

    init(
        sharedSettings: IOSSharedSettingsStore,
        conversationStore: IOSConversationStore,
        initialTab: AmberMultiDeviceTab = .cloud
    ) {
        self.sharedSettings = sharedSettings
        self.conversationStore = conversationStore
        self.initialTab = initialTab
        self._selectedTab = State(initialValue: initialTab)
    }

    private var isPairedMac: Bool {
        AmberMultiDevicePairingClassifier.isMacConnection(
            connection: gatewayStore.connection,
            status: gatewayStore.status
        )
    }

    private var isPairedCloud: Bool {
        gatewayStore.connection != nil && !isPairedMac
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                tabPicker
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

                switch selectedTab {
                case .cloud:
                    cloudTabContent
                case .mac:
                    macTabContent
                case .watch:
                    IOSWatchSettingsView(
                        sharedSettings: sharedSettings,
                        conversationStore: conversationStore,
                        showsNavigationHeader: false
                    )
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .tint(AmberTheme.accent)
        .confirmationDialog(
            L("取消与这台 Mac 的配对？"),
            isPresented: $confirmsUnpairMac,
            titleVisibility: .visible
        ) {
            Button(L("取消配对"), role: .destructive) {
                Task { await gatewayStore.unpair() }
            }
            Button(L("保留"), role: .cancel) {}
        } message: {
            Text(verbatim: L("取消后此设备将断开与该 Mac 的连接，不会删除本地对话。"))
        }
        .sheet(isPresented: $showingMacPairingSheet) {
            NavigationStack {
                MacGatewaySettingsView(sharedSettings: sharedSettings)
            }
        }
        .sheet(isPresented: $showingCloudPairingSheet) {
            NavigationStack {
                MacGatewaySettingsView(sharedSettings: sharedSettings)
            }
        }
    }

    private var header: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回设置", size: 44, symbolSize: 20) {
                dismiss()
            }

            Spacer()

            Text(verbatim: L("Amber 多终端"))
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)

            Spacer()

            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(AmberMultiDeviceTab.allCases) { tab in
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(verbatim: tab.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selectedTab == tab ? AmberTheme.foreground : AmberTheme.foreground2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background {
                            if selectedTab == tab {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(AmberTheme.background.opacity(0.92))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .stroke(AmberTheme.borderSoft.opacity(0.9), lineWidth: 0.5)
                                    }
                                    .matchedGeometryEffect(id: "multiDeviceTabSelection", in: tabSelection)
                            }
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                .accessibilityIdentifier("settings.multiDevice.tab.\(tab.rawValue)")
            }
        }
        .padding(3)
        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AmberTheme.borderSoft, lineWidth: 0.5)
        }
    }

    // MARK: - 云端 Tab

    @ViewBuilder
    private var cloudTabContent: some View {
        if isPairedMac, let connection = gatewayStore.connection {
            ScrollView {
                VStack(spacing: 0) {
                    AmberSectionLabel(text: "云端连接状态")
                    AmberFormGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "desktopcomputer")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AmberTheme.accent)
                                Text(verbatim: L("当前仅连接了 Mac（\(connection.name)）"))
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(AmberTheme.foreground)
                            }
                            Text(verbatim: L("当前版本仅支持连接一台远端主机。你可以前往「Mac」页查看这台 Mac 的任务与状态，或切换配对到云端真身。"))
                                .font(.footnote)
                                .foregroundStyle(AmberTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 10) {
                                Button {
                                    withAnimation(.smooth(duration: 0.2)) {
                                        selectedTab = .mac
                                    }
                                } label: {
                                    Text(verbatim: L("前往 Mac 页"))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AmberTheme.accentInk)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .background(AmberTheme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                }
                                .buttonStyle(.plain)

                                Button {
                                    showingCloudPairingSheet = true
                                } label: {
                                    Text(verbatim: L("配对设置"))
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(AmberTheme.foreground)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        } else {
            MacGatewaySettingsView(
                sharedSettings: sharedSettings,
                showsNavigationHeader: false
            )
        }
    }

    // MARK: - Mac Tab

    @ViewBuilder
    private var macTabContent: some View {
        if isPairedMac, let connection = gatewayStore.connection {
            let sessions = gatewayStore.status?.sessions ?? []
            let approvals = gatewayStore.activeMacApprovalCardItems()
            let localOnlyApprovals = approvals.filter(\.requiresLocalApproval)
            let schedules = gatewayStore.schedules ?? []

            ScrollView {
                VStack(spacing: 0) {
                    AmberSectionLabel(text: "已连接的 Mac")
                    AmberFormGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(gatewayStore.isReachable == false ? MacDelegationSemanticInk.danger : MacDelegationSemanticInk.success)
                                    .frame(width: 8, height: 8)
                                Text(verbatim: connection.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(AmberTheme.foreground)
                                Spacer()
                                Text(verbatim: gatewayStore.isReachable == false ? L("离线") : L("在线"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(gatewayStore.isReachable == false ? MacDelegationSemanticInk.danger : MacDelegationSemanticInk.success)
                            }
                            if let addr = connection.addrs.first {
                                Text(verbatim: "\(addr):\(connection.port)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(AmberTheme.muted)
                            }
                        }
                        .padding(16)
                    }

                    AmberSectionLabel(text: "Mac 任务与会话")
                    AmberFormGroup {
                        AmberFormRow(
                            systemImage: "checklist",
                            iconColor: AmberTheme.accent,
                            iconUsesAccentPlate: true,
                            title: L("Mac 任务看板"),
                            subtitle: L("查看运行中的任务、定时计划与 Claude Code / Codex 会话"),
                            trailing: sessions.isEmpty ? nil : L("\(sessions.count) 个会话"),
                            showsChevron: true
                        ) {
                            router.navigate(to: .macTasks)
                        }
                        Divider().overlay(AmberTheme.borderSoft).padding(.leading, 54)
                        AmberFormRow(
                            systemImage: "clock.badge.checkmark",
                            iconColor: AmberTheme.accent,
                            iconUsesAccentPlate: true,
                            title: L("定时任务"),
                            subtitle: schedules.isEmpty ? L("暂未配置 Mac 定时任务") : L("已配置 \(schedules.count) 条定时任务"),
                            trailing: "\(schedules.count)",
                            showsChevron: true
                        ) {
                            router.navigate(to: .macTasks)
                        }
                        Divider().overlay(AmberTheme.borderSoft).padding(.leading, 54)
                        AmberFormRow(
                            systemImage: "checkmark.shield",
                            iconColor: approvals.isEmpty ? AmberTheme.accent : MacDelegationSemanticInk.warning,
                            iconUsesAccentPlate: true,
                            title: L("待审批项"),
                            subtitle: localOnlyApprovals.isEmpty
                                ? (approvals.isEmpty ? L("当前没有待处理审批") : L("有 \(approvals.count) 项待审批操作"))
                                : L("其中 \(localOnlyApprovals.count) 项为高危操作，需在 Mac 本机批准"),
                            trailing: approvals.isEmpty ? "0" : "\(approvals.count)",
                            showsChevron: true
                        ) {
                            router.navigate(to: .macTasks)
                        }
                    }

                    AmberSectionLabel(text: "连接管理")
                    AmberFormGroup {
                        AmberFormRow(
                            systemImage: "qrcode.viewfinder",
                            iconColor: AmberTheme.accent,
                            iconUsesAccentPlate: true,
                            title: L("完整连接与同步设置"),
                            subtitle: L("查看证书指纹、重新扫码或导入配置"),
                            showsChevron: true
                        ) {
                            showingMacPairingSheet = true
                        }
                        Divider().overlay(AmberTheme.borderSoft).padding(.leading, 54)
                        Button {
                            confirmsUnpairMac = true
                        } label: {
                            Text(verbatim: L("取消配对"))
                                .font(.body.weight(.medium))
                                .foregroundStyle(MacDelegationSemanticInk.danger)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.horizontal, 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
            .task(id: connection.gatewayId) {
                await gatewayStore.refresh()
            }
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    AmberSectionLabel(text: "Mac 连接状态")
                    AmberFormGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "desktopcomputer")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AmberTheme.muted)
                                Text(verbatim: L("尚未单独连接 Mac"))
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(AmberTheme.foreground)
                            }
                            Text(verbatim: isPairedCloud
                                 ? L("当前已连接云端（\(gatewayStore.connection?.name ?? "Amber Cloud")），尚未单独配对 Mac。扫码连接 Mac 后可在这里查看 Mac 任务、会话与定时计划。")
                                 : L("扫码连接你电脑上的 Amber 后，可在这里查看 Mac 在线状态、任务看板、定时任务与待审批项。"))
                                .font(.footnote)
                                .foregroundStyle(AmberTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)

                            Button {
                                showingMacPairingSheet = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "qrcode.viewfinder")
                                        .font(.subheadline.weight(.semibold))
                                    Text(verbatim: L("扫码配对 Mac"))
                                        .font(.subheadline.weight(.semibold))
                                }
                                .foregroundStyle(AmberTheme.accentInk)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(AmberTheme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(16)
                    }
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private func L(_ key: String) -> String {
    IOSAppLocalization.string(key, defaultValue: key)
}
