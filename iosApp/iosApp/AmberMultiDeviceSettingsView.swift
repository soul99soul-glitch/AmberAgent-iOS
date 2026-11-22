import SwiftUI
import UIKit

/// Unified "Amber 多终端" settings surface consolidating Cloud (`amberd`), local Mac (`amber-gateway`),
/// and Apple Watch under one top-level settings entry with a 3-way segmented tab bar.
@MainActor
struct AmberMultiDeviceSettingsView: View {
    let sharedSettings: IOSSharedSettingsStore
    let conversationStore: IOSConversationStore
    var initialTab: AmberMultiDeviceTab? = nil
    var onOpenCloudDialogue: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(RouterPath.self) private var router
    @State private var selectedTab: AmberMultiDeviceTab

    private let store = MacGatewayStore.shared

    init(
        sharedSettings: IOSSharedSettingsStore,
        conversationStore: IOSConversationStore,
        initialTab: AmberMultiDeviceTab? = nil,
        onOpenCloudDialogue: (() -> Void)? = nil
    ) {
        self.sharedSettings = sharedSettings
        self.conversationStore = conversationStore
        self.initialTab = initialTab
        self.onOpenCloudDialogue = onOpenCloudDialogue
        self._selectedTab = State(initialValue: initialTab ?? MacGatewayStore.shared.preferredMultiDeviceTab)
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                tabSwitcher
                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .tint(AmberTheme.accent)
        .onChange(of: store.preferredMultiDeviceTab) { _, nextTab in
            if initialTab == nil {
                selectedTab = nextTab
            }
        }
        .onAppear {
            if let initialTab {
                selectedTab = initialTab
            } else if store.mac.pendingPairing != nil && store.pendingPairing == nil {
                selectedTab = .mac
            } else if store.pendingPairing != nil {
                selectedTab = .cloud
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回", size: 44, symbolSize: 20) {
                dismiss()
            }
            Spacer(minLength: 0)
            Text(verbatim: macGatewayL("Amber 多终端"))
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
        .padding(.bottom, 12)
    }

    private var tabSwitcher: some View {
        Picker(macGatewayL("终端类型"), selection: $selectedTab) {
            ForEach(AmberMultiDeviceTab.allCases) { tab in
                Text(verbatim: tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityIdentifier("settings.multiDevice.segmentedTabs")
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .cloud:
            MacGatewaySettingsView(
                sharedSettings: sharedSettings,
                embeddedInMultiDevice: true,
                onOpenCloudDialogue: {
                    if let onOpenCloudDialogue {
                        onOpenCloudDialogue()
                    } else {
                        store.setCloudMainDialogueSelected(true)
                        router.reset()
                        dismiss()
                    }
                }
            )
        case .mac:
            AmberMacSlotSettingsContent(
                macStore: store.mac,
                sharedSettings: sharedSettings
            )
        case .watch:
            IOSWatchSettingsView(
                sharedSettings: sharedSettings,
                conversationStore: conversationStore,
                embeddedInMultiDevice: true
            )
        }
    }
}

/// Real-time Mac slot management embedded in the "Mac" tab of "Amber 多终端".
/// Reads exclusively from `MacGatewayStore.shared.mac` (independent from Cloud pairing/token/state).
@MainActor
private struct AmberMacSlotSettingsContent: View {
    let macStore: MacGatewayStore
    let sharedSettings: IOSSharedSettingsStore

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @State private var confirmsUnpair = false
    @State private var creatingSchedule = false
    @State private var presentingBoardSheet = false
    @State private var activeApprovalCard: MacGatewayApprovalCardItem?
    @State private var copiedFingerprint = false
    @State private var copyFingerprintResetTask: Task<Void, Never>?

    private static let refreshInterval: Duration = .seconds(10)

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let pending = macStore.pendingPairing {
                    confirmSection(pending)
                } else if let connection = macStore.connection {
                    connectionSection(connection)
                    if let health = macStore.status?.health {
                        healthSection(health)
                    }
                    approvalsSection
                    boardAndSessionsSection
                    schedulesSection
                    unpairSection
                } else {
                    pairSection
                }
            }
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await macStore.refresh(role: .mac)
        }
        .task(id: macStore.connection?.gatewayId) {
            guard macStore.connection != nil else { return }
            while !Task.isCancelled {
                await macStore.refresh(role: .mac)
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
        .onDisappear {
            copyFingerprintResetTask?.cancel()
            copyFingerprintResetTask = nil
        }
        .confirmationDialog(macGatewayL("取消与这台 Mac 的配对？"), isPresented: $confirmsUnpair, titleVisibility: .visible) {
            Button(macGatewayL("取消配对"), role: .destructive) {
                Task { await macStore.unpair(role: .mac) }
            }
            Button(macGatewayL("保留"), role: .cancel) {}
        } message: {
            Text(verbatim: macGatewayL("仅解除本机与这台 Mac 的配对，不影响云端连接。"))
        }
        .sheet(isPresented: $creatingSchedule) {
            MacGatewayScheduleSheet(store: macStore)
        }
        .sheet(isPresented: $presentingBoardSheet) {
            NavigationStack {
                MacTasksBoardView(store: macStore)
            }
            .amberFloatingSheet(detents: [.large])
        }
        .sheet(item: $activeApprovalCard) { card in
            MacReadOnlyDiffApprovalSheet(item: card, store: macStore)
                .amberFloatingSheet(detents: [.medium, .large])
        }
    }

    // MARK: - Unpaired & Confirm Pairing

    private var pairSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "配对 Mac")
            AmberFormGroup {
                MacGatewayRow(
                    icon: "qrcode.viewfinder",
                    title: macGatewayL("扫码配对 Mac"),
                    detail: macGatewayL("在 Mac 终端运行 amber-gateway pair，用系统相机扫描二维码")
                ) {
                    EmptyView()
                }
                MacGatewayRowDivider()
                MacGatewayRow(
                    icon: "doc.on.clipboard",
                    title: macGatewayL("粘贴 Mac 配对链接"),
                    detail: macGatewayL("从 AirDrop 或消息复制的 amber:// 链接（与云端独立保存）"),
                    action: { macStore.pasteLinkFromClipboard(for: .mac) }
                ) {
                    MacGatewayChevron()
                }
            }
            noticeFooter(fallback: macGatewayL("Mac 配对与云端完全独立，可同时在线。实时查看 Mac 任务看板、Claude Code / Codex 会话、定时任务与审批。"))
        }
    }

    private func confirmSection(_ payload: MacGatewayPairingPayload) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "确认 Mac 配对")
            AmberFormGroup {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        MacGatewayIconPlate(icon: "desktopcomputer")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: payload.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(AmberTheme.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(verbatim: "\(payload.addrs.joined(separator: " · ")):\(payload.port)")
                                .font(.caption.monospaced())
                                .foregroundStyle(AmberTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                MacGatewayRowDivider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        MacGatewayIconPlate(icon: "checkmark.shield")
                        Text(verbatim: macGatewayL("TLS 证书指纹"))
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        fingerprintCopyButton(payload.fp)
                    }
                    Text(verbatim: payload.fp)
                        .font(.footnote.monospaced())
                        .foregroundStyle(AmberTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(AmberTheme.borderSoft, lineWidth: 0.5)
                        )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                if payload.bootstrap != nil {
                    MacGatewayRowDivider()
                    MacGatewayRow(
                        icon: "lock.shield",
                        title: macGatewayL("支持单次扫码加密同步"),
                        detail: macGatewayL("配对时将通过临时 RSA 密钥验证并同步非敏感摘要，不覆盖云端连接。")
                    ) { EmptyView() }
                }
            }
            MacGatewaySectionFooter(text: macGatewayL("请完整核对与 Mac 终端显示的 TLS 证书指纹一致后再确认配对。"))
            AmberFormGroup {
                actionRow(macGatewayL("配对 Mac"), busyTitle: macGatewayL("正在配对 Mac…"), color: AmberTheme.accent, isBusy: macStore.isBusy) {
                    Task {
                        await macStore.confirmPairing(for: .mac, sharedSettings: sharedSettings)
                    }
                }
                Divider().overlay(AmberTheme.borderSoft)
                actionRow(macGatewayL("取消"), color: AmberTheme.muted, isBusy: false) {
                    macStore.pendingPairing = nil
                }
                .opacity(macStore.isBusy ? 0.45 : 1)
                .disabled(macStore.isBusy)
            }
            .padding(.top, 16)
            noticeFooter(fallback: nil)
        }
    }

    // MARK: - Paired Mac Live Sections

    private func connectionSection(_ connection: MacGatewayConnection) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Mac 连接")
            AmberFormGroup {
                MacGatewayRow(icon: "desktopcomputer", title: connection.name, detail: reachabilityText) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusDotColor)
                            .frame(width: 7, height: 7)
                        Button {
                            Task { await macStore.refresh(role: .mac) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18, weight: .medium))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AmberTheme.accent)
                        .accessibilityLabel(Text(verbatim: macGatewayL("刷新 Mac 状态")))
                    }
                }
                MacGatewayRowDivider()
                MacGatewayRow(
                    icon: "network",
                    title: macGatewayL("主机与端口"),
                    detail: "\(connection.addrs.joined(separator: " · ")):\(connection.port)"
                ) { EmptyView() }
                MacGatewayRowDivider()
                MacGatewayRow(
                    icon: "checkmark.shield",
                    title: macGatewayL("TLS 证书指纹"),
                    detail: connection.fingerprint.isEmpty ? macGatewayL("未记录") : String(connection.fingerprint.prefix(24)) + "…"
                ) {
                    if !connection.fingerprint.isEmpty {
                        fingerprintCopyButton(connection.fingerprint)
                    }
                }
                MacGatewayRowDivider()
                MacGatewayRow(icon: "bell.badge", title: macGatewayL("推送通知"), detail: pushDetail) {
                    if macStore.isSendingTestPush {
                        ProgressView().frame(width: 44, height: 44)
                    } else if macStore.status?.device.pushRegistered == true {
                        MacGatewayCapsuleButton(title: macGatewayL("测试")) {
                            Task { await macStore.sendTestPush() }
                        }
                    } else {
                        MacGatewayCapsuleButton(title: macGatewayL("开启")) {
                            Task { await macStore.enablePush() }
                        }
                    }
                }
                if let summary = macStore.lastBootstrapSyncSummary {
                    MacGatewayRowDivider()
                    MacGatewayRow(
                        icon: "checkmark.seal",
                        title: macGatewayL("最近一次配对同步"),
                        detail: summary.summaryText
                    ) { EmptyView() }
                }
            }
            noticeFooter(fallback: macStore.isReachable == false
                ? macGatewayL("Mac 睡眠、合盖或断网时无法实时读取状态与审批。")
                : nil)
        }
    }

    private func healthSection(_ health: MacGatewayStatus.Health) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Mac 硬件状态")
            AmberFormGroup {
                if let bytes = health.diskFreeBytes {
                    valueRow(icon: "internaldrive", title: macGatewayL("磁盘剩余"),
                             value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal))
                    MacGatewayRowDivider()
                }
                if let percent = health.batteryPercent {
                    valueRow(icon: health.onBattery == true ? "battery.50" : "battery.100.bolt",
                             title: macGatewayL("电量"),
                             value: "\(percent)%" + (health.onBattery == true ? "" : " · " + macGatewayL("接电源")))
                    MacGatewayRowDivider()
                }
                valueRow(icon: "memorychip", title: macGatewayL("内存压力"), value: Self.levelLabel(health.memoryPressure))
                MacGatewayRowDivider()
                valueRow(icon: "thermometer.medium", title: macGatewayL("温度"), value: Self.levelLabel(health.thermal))
            }
        }
    }

    @ViewBuilder
    private var approvalsSection: some View {
        let approvals = macStore.activeMacApprovalCardItems()
        if !approvals.isEmpty {
            VStack(spacing: 0) {
                AmberSectionLabel(text: "待审批（Mac）")
                AmberFormGroup {
                    ForEach(Array(approvals.enumerated()), id: \.element.id) { index, card in
                        if index > 0 { MacGatewayRowDivider() }
                        let localOnly = card.requiresLocalApproval
                            || macStore.requiresLocalApprovalOnly(sessionKey: card.sessionKey, toolCallId: card.toolCallId)
                        VStack(alignment: .leading, spacing: 6) {
                            MacGatewayRow(
                                icon: localOnly ? "lock.shield" : "hand.raised",
                                title: card.summary,
                                detail: localOnly
                                    ? macGatewayL("仅限 Mac 本机审批（HTTP 403 / L3）· \(card.tool)")
                                    : "\(card.riskTier.badgeText) · \(card.tool)",
                                action: { activeApprovalCard = card }
                            ) {
                                MacGatewayChevron()
                            }
                            if localOnly {
                                Text(verbatim: macGatewayL("此高危操作请在 Mac 上批准，手机端仅可查看详情或拒绝。"))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(MacDelegationSemanticInk.danger)
                                    .padding(.leading, 54)
                                    .padding(.trailing, 14)
                                    .padding(.bottom, 10)
                            }
                        }
                    }
                }
            }
        }
    }

    private var boardAndSessionsSection: some View {
        let items = macStore.boardItems
        let sessions = macStore.status?.sessions ?? []
        let openSessions = sessions.filter { $0.agent != "amber" && $0.agent != "run" }
        return VStack(spacing: 0) {
            AmberSectionLabel(text: "任务看板与会话")
            AmberFormGroup {
                MacGatewayRow(
                    icon: "checklist",
                    title: macGatewayL("打开 Mac 任务看板"),
                    detail: boardSummaryDetail(items: items),
                    action: { presentingBoardSheet = true }
                ) {
                    MacGatewayChevron()
                }
                if let url = macStore.status?.synaraURL.flatMap(URL.init(string:)) {
                    MacGatewayRowDivider()
                    MacGatewayRow(
                        icon: "bubble.left.and.text.bubble.right",
                        title: macGatewayL("在 Synara 中处理会话"),
                        detail: url.absoluteString,
                        action: { openURL(url) }
                    ) {
                        MacGatewayChevron()
                    }
                }
                if openSessions.isEmpty {
                    MacGatewayRowDivider()
                    MacGatewayRow(
                        icon: "terminal",
                        title: macGatewayL("Claude Code / Codex 会话"),
                        detail: macStore.isReachable == false
                            ? macGatewayL("Mac 当前离线")
                            : macGatewayL("当前无活跃会话")
                    ) { EmptyView() }
                } else {
                    ForEach(openSessions.prefix(6)) { session in
                        MacGatewayRowDivider()
                        MacGatewayRow(
                            icon: session.agent == "codex" ? "chevron.left.forwardslash.chevron.right" : "terminal",
                            title: session.displayTitle,
                            detail: sessionDetail(session)
                        ) {
                            if session.isOpen {
                                Toggle("", isOn: Binding(
                                    get: { session.monitored },
                                    set: { value in Task { await macStore.setMonitored(session, value) } }
                                ))
                                .labelsHidden()
                                .tint(AmberTheme.accent)
                                .accessibilityLabel(Text(verbatim: macGatewayL("监控推送") + " " + session.displayTitle))
                            }
                        }
                    }
                }
            }
            if let error = macStore.boardError, macStore.board == nil {
                MacGatewaySectionFooter(text: error)
            }
        }
    }

    private var schedulesSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Mac 定时任务")
            AmberFormGroup {
                if let schedules = macStore.schedules {
                    if schedules.isEmpty {
                        MacGatewayRow(
                            icon: "clock",
                            title: macGatewayL("暂无定时任务"),
                            detail: macGatewayL("可在此直接新建在 Mac 上运行的定时任务")
                        ) { EmptyView() }
                    } else {
                        ForEach(Array(schedules.enumerated()), id: \.element.id) { index, schedule in
                            if index > 0 { MacGatewayRowDivider() }
                            MacGatewayRow(
                                icon: "clock",
                                title: schedule.name,
                                detail: scheduleDetail(schedule)
                            ) {
                                HStack(spacing: 6) {
                                    if macStore.busySchedules.contains(schedule.id) || schedule.running {
                                        ProgressView().frame(width: 44, height: 44)
                                    } else {
                                        Button {
                                            Task { await macStore.runSchedule(schedule) }
                                        } label: {
                                            Image(systemName: "play.fill")
                                                .font(.system(size: 15, weight: .semibold))
                                                .frame(width: 44, height: 44)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(AmberTheme.accent)
                                        .accessibilityLabel(Text(verbatim: macGatewayL("立即运行") + " " + schedule.name))
                                    }
                                    Toggle("", isOn: Binding(
                                        get: { schedule.enabled },
                                        set: { value in Task { await macStore.setScheduleEnabled(schedule, value) } }
                                    ))
                                    .labelsHidden()
                                    .tint(AmberTheme.accent)
                                    .disabled(macStore.busySchedules.contains(schedule.id))
                                    .accessibilityLabel(Text(verbatim: macGatewayL("启用") + " " + schedule.name))
                                }
                            }
                        }
                    }
                    MacGatewayRowDivider()
                    MacGatewayRow(
                        icon: "plus",
                        title: macGatewayL("新建定时任务"),
                        detail: macGatewayL("在 Mac 上按时运行提示词"),
                        action: { creatingSchedule = true }
                    ) {
                        MacGatewayChevron()
                    }
                } else {
                    MacGatewayRow(
                        icon: "clock",
                        title: macGatewayL("定时任务"),
                        detail: macStore.schedulesError ?? (macStore.isReachable == false ? macGatewayL("Mac 当前离线") : macGatewayL("正在读取或 Mac 端 Amber 未运行"))
                    ) { EmptyView() }
                }
            }
        }
    }

    private var unpairSection: some View {
        AmberFormGroup {
            actionRow(macGatewayL("取消 Mac 配对"), color: MacDelegationSemanticInk.danger, isBusy: macStore.isBusy) {
                confirmsUnpair = true
            }
        }
        .padding(.top, 28)
    }

    // MARK: - Formatting & Helpers

    private var statusDotColor: Color {
        switch macStore.endpointHealth(for: .mac) {
        case .ready: return MacDelegationSemanticInk.success
        case .checking, .actionRequired: return MacDelegationSemanticInk.warning
        case .unavailable: return MacDelegationSemanticInk.danger
        case .unpaired: return AmberTheme.muted
        }
    }

    private var reachabilityText: String {
        switch macStore.isReachable {
        case nil:
            return macGatewayL("正在连接…")
        case false:
            return macGatewayL("离线 · 无法连接")
        case true:
            guard let sampled = macStore.status?.health?.sampledAt else { return macGatewayL("在线") }
            return macGatewayL("在线") + " · " + macGatewayL("更新于") + " " + sampled.formatted(.relative(presentation: .named))
        }
    }

    private var pushDetail: String {
        if let error = macStore.pushError { return error }
        return macStore.status?.device.pushRegistered == true
            ? macGatewayL("已开启，任务需要你时会通知")
            : macGatewayL("未开启")
    }

    private func boardSummaryDetail(items: [MacGatewayBoardItem]) -> String {
        if items.isEmpty {
            return macGatewayL("查看 Mac 定时任务、运行状态与 Claude Code / Codex 会话")
        }
        let needsYou = items.filter { $0.column == .needsYou }.count
        let running = items.filter { $0.column == .running }.count
        var parts: [String] = []
        if needsYou > 0 { parts.append(macGatewayL("等你处理 \(needsYou)")) }
        if running > 0 { parts.append(macGatewayL("进行中 \(running)")) }
        parts.append(macGatewayL("共 \(items.count) 项"))
        return parts.joined(separator: " · ")
    }

    private func sessionDetail(_ session: MacGatewayStatus.Session) -> String {
        let agent = switch session.agent {
        case "claude": "Claude Code"
        case "codex": "Codex"
        default: session.agent
        }
        let state = switch session.state {
        case "running": macGatewayL("运行中")
        case "waiting": session.waitReason == "permission" ? macGatewayL("等你确认") : macGatewayL("等你回复")
        case "stalled": macGatewayL("可能卡住了")
        case "completed": macGatewayL("已完成")
        default: session.abnormal ? macGatewayL("意外中断") : macGatewayL("已停止")
        }
        return [agent, session.host, state].compactMap { $0 }.joined(separator: " · ")
    }

    private func scheduleDetail(_ schedule: MacGatewaySchedule) -> String {
        var parts = [schedule.rule]
        if !schedule.enabled {
            parts.append(macGatewayL("已停用"))
        } else if let next = schedule.nextRunAt {
            parts.append(macGatewayL("下次") + " " + next.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    private func fingerprintCopyButton(_ fingerprint: String) -> some View {
        Button {
            copyFingerprint(fingerprint)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copiedFingerprint ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                Text(verbatim: copiedFingerprint ? macGatewayL("已复制") : macGatewayL("复制"))
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(copiedFingerprint ? MacDelegationSemanticInk.success : AmberTheme.accent)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(
                copiedFingerprint
                    ? MacDelegationSemanticInk.success.opacity(colorScheme == .dark ? 0.18 : 0.11)
                    : AmberTheme.accentTint,
                in: Capsule()
            )
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func copyFingerprint(_ fingerprint: String) {
        UIPasteboard.general.string = fingerprint
        copiedFingerprint = true
        copyFingerprintResetTask?.cancel()
        copyFingerprintResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            copiedFingerprint = false
        }
    }

    private static func levelLabel(_ level: String) -> String {
        switch level {
        case "normal", "nominal": macGatewayL("正常")
        case "warning", "fair": macGatewayL("偏高")
        case "serious": macGatewayL("过高")
        default: macGatewayL("严重")
        }
    }

    private func actionRow(
        _ title: String,
        busyTitle: String? = nil,
        color: Color,
        isBusy: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().controlSize(.small).tint(color)
                    if let busyTitle {
                        Text(verbatim: busyTitle)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(color)
                    }
                } else {
                    Text(verbatim: title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(color)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private func valueRow(icon: String, title: String, value: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            HStack(spacing: 12) {
                MacGatewayIconPlate(icon: icon)
                Text(verbatim: title).font(.body).foregroundStyle(AmberTheme.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(verbatim: value).font(.subheadline).foregroundStyle(AmberTheme.muted)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 40 : 0)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func noticeFooter(fallback: String?) -> some View {
        if let notice = macStore.notice {
            MacGatewaySectionFooter(
                text: notice.text,
                color: notice.isError ? MacDelegationSemanticInk.warning : AmberTheme.muted
            )
        } else if let fallback {
            MacGatewaySectionFooter(text: fallback)
        }
    }
}
