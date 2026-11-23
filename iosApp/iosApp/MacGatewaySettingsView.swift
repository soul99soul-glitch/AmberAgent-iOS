import SwiftUI
import UIKit
@preconcurrency import Shared

struct MacGatewaySettingsView: View {
    var sharedSettings: IOSSharedSettingsStore? = nil
    var embeddedInMultiDevice: Bool = false
    var onOpenCloudDialogue: (() -> Void)? = nil

    private struct LocalSiwcPromptState: Equatable {
        let providerId: String?
        let modelLabel: String
    }

    private struct SiwcCheckKey: Equatable {
        let gatewayId: String?
        let summary: IOSPairingBootstrapSyncSummary?
        let configRevision: Int?
        let cloudSiwcConfigured: Bool
        let cloudAuthMode: String
        let nonce: Int
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(RouterPath.self) private var router
    @State private var confirmsUnpair = false
    @State private var presentingCloudCompose = false
    @State private var presentingCloudDialogue = false
    @State private var copiedFingerprint = false
    @State private var copyFingerprintResetTask: Task<Void, Never>?
    @State private var localSiwcPrompt: LocalSiwcPromptState?
    @State private var presentingSiwcProviderId: String?
    @State private var siwcCheckNonce = 0

    private let store = MacGatewayStore.shared
    private let ruleStore = IOSProceduralRuleStore.shared
    private static let refreshInterval: Duration = .seconds(10)

    private var resolvedSharedSettings: IOSSharedSettingsStore? {
        sharedSettings ?? store.boundSharedSettings
    }

    private var siwcCheckKey: SiwcCheckKey {
        SiwcCheckKey(
            gatewayId: store.connection?.gatewayId,
            summary: store.lastBootstrapSyncSummary,
            configRevision: store.cloudConfig?.revision,
            cloudSiwcConfigured: store.cloudConfig?.model?.siwcConfigured ?? false,
            cloudAuthMode: store.cloudConfig?.model?.authMode ?? "",
            nonce: siwcCheckNonce
        )
    }

    var body: some View {
        Group {
            if embeddedInMultiDevice {
                cloudScrollContent
            } else {
                ZStack {
                    AmberTheme.background.ignoresSafeArea()
                    VStack(spacing: 0) {
                        header
                        cloudScrollContent
                    }
                }
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .tint(AmberTheme.accent)
        .task(id: store.connection?.gatewayId) {
            guard store.connection != nil else { return }
            while !Task.isCancelled {
                await store.refresh(role: .cloud)
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
        .task(id: siwcCheckKey) {
            refreshLocalSiwcPrompt()
        }
        .onDisappear {
            copyFingerprintResetTask?.cancel()
            copyFingerprintResetTask = nil
        }
        .confirmationDialog(L("取消与云端的配对？"), isPresented: $confirmsUnpair, titleVisibility: .visible) {
            Button(L("取消配对"), role: .destructive) { Task { await store.unpair(role: .cloud) } }
            Button(L("保留"), role: .cancel) {}
        } message: {
            Text(verbatim: L("仅解除云端配对，不影响本机 Mac 连接。"))
        }
        .sheet(isPresented: $presentingCloudCompose) {
            MacGatewayCloudTaskComposeSheet(store: store) { _ in
                router.navigate(to: .macTasks)
            }
        }
        .sheet(isPresented: $presentingCloudDialogue) {
            MacGatewayCloudDialogueSheet(store: store)
        }
        .sheet(
            isPresented: Binding(
                get: { presentingSiwcProviderId != nil },
                set: { if !$0 { presentingSiwcProviderId = nil } }
            ),
            onDismiss: {
                siwcCheckNonce += 1
            }
        ) {
            if let providerId = presentingSiwcProviderId {
                ChatGptSiwcLoginView(
                    providerId: providerId,
                    autoStartLogin: false,
                    onAuthModeChange: { mode in
                        _ = resolvedSharedSettings?.setOpenAIAuthMode(providerId: providerId, authMode: mode)
                        siwcCheckNonce += 1
                    },
                    onModelsFetched: { _ in
                        siwcCheckNonce += 1
                    }
                )
            }
        }
    }

    private var cloudScrollContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let pending = store.pendingPairing {
                    confirmSection(pending)
                } else if let connection = store.connection {
                    macSection(connection)
                    if let siwcPrompt = localSiwcPrompt {
                        siwcSignInGuidanceSection(siwcPrompt)
                    }
                    if let health = store.status?.health { healthSection(health) }
                    cloudConfigSection
                    deviceContextSharingSection
                    boardSection
                    unpairSection
                } else {
                    pairSection
                }
            }
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await store.refresh(role: .cloud)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回", size: 44, symbolSize: 20) {
                dismiss()
            }
            Spacer(minLength: 0)
            Text(verbatim: L("Amber · 云端"))
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
                            action: { store.pasteLinkFromClipboard(for: .cloud) }) {
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        MacGatewayIconPlate(icon: "desktopcomputer")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: payload.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(AmberTheme.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(verbatim: payload.addrs.joined(separator: " · "))
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
                        Text(verbatim: L("TLS 证书指纹"))
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            copyFingerprint(payload.fp)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: copiedFingerprint ? "checkmark" : "doc.on.doc")
                                    .font(.caption.weight(.semibold))
                                Text(verbatim: copiedFingerprint ? L("已复制") : L("复制"))
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
                        .accessibilityLabel(Text(verbatim: copiedFingerprint ? L("已复制证书指纹") : L("复制证书指纹")))
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
                        .accessibilityLabel(Text(verbatim: L("完整证书指纹：") + payload.fp))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                if let hint = payload.bootstrap {
                    MacGatewayRowDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 12) {
                            MacGatewayIconPlate(icon: "lock.shield")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: L("单次扫码加密同步"))
                                    .font(.body)
                                    .foregroundStyle(AmberTheme.foreground)
                                Text(verbatim: bootstrapHintSummary(hint))
                                    .font(.caption)
                                    .foregroundStyle(AmberTheme.foreground2)
                                    .fixedSize(horizontal: false, vertical: true)
                                if hint.siwcConfigured || hint.authMode == "chatgptSiwc" {
                                    Text(verbatim: L("云端使用 ChatGPT（SIWC）；登录态与设备绑定，配对后请在本机完成登录。"))
                                        .font(.caption)
                                        .foregroundStyle(MacDelegationSemanticInk.warning)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
            MacGatewaySectionFooter(text: L("请完整核对与 Mac 终端显示的 TLS 证书指纹一致后再确认配对。"))
            AmberFormGroup {
                actionRow(L("配对"), busyTitle: L("正在配对并同步…"), color: AmberTheme.accent, isBusy: store.isBusy) {
                    Task { await store.confirmPairing(for: .cloud, sharedSettings: resolvedSharedSettings) }
                }
                Divider().overlay(AmberTheme.borderSoft)
                actionRow(L("取消"), color: AmberTheme.muted, isBusy: false) {
                    store.pendingPairing = nil
                }
                .opacity(store.isBusy ? 0.45 : 1)
                .disabled(store.isBusy)
            }
            .padding(.top, 20)
            noticeFooter(fallback: nil)
        }
    }

    // MARK: - Paired

    private func macSection(_ connection: MacGatewayConnection) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "云端连接")
            AmberFormGroup {
                MacGatewayRow(icon: "icloud", title: connection.name, detail: reachabilityText) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(sessionStatusDotColor)
                            .frame(width: 7, height: 7)

                        Button { Task { await store.refresh(role: .cloud) } } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18, weight: .medium))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AmberTheme.accent)
                        .accessibilityLabel(Text(verbatim: L("刷新")))
                    }
                }
                MacGatewayRowDivider()
                MacGatewayRow(
                    icon: "network",
                    title: L("代理地址与端口"),
                    detail: "\(connection.addrs.joined(separator: " · ")):\(connection.port)"
                ) { EmptyView() }
                MacGatewayRowDivider()
                MacGatewayRow(
                    icon: "checkmark.shield",
                    title: L("TLS 证书指纹"),
                    detail: connection.fingerprint.isEmpty ? L("未记录") : String(connection.fingerprint.prefix(24)) + "…"
                ) {
                    if !connection.fingerprint.isEmpty {
                        Button {
                            copyFingerprint(connection.fingerprint)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: copiedFingerprint ? "checkmark" : "doc.on.doc")
                                    .font(.caption.weight(.semibold))
                                Text(verbatim: copiedFingerprint ? L("已复制") : L("复制"))
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
                }
                MacGatewayRowDivider()
                MacGatewayRow(
                    icon: "bubble.left.and.text.bubble.right",
                    title: L("打开云端常驻对话"),
                    detail: L("进入已配对云端主对话，支持 24×7 持续任务与多端同步"),
                    action: {
                        if let onOpenCloudDialogue {
                            onOpenCloudDialogue()
                        } else {
                            store.setCloudMainDialogueSelected(true)
                            router.reset()
                            dismiss()
                        }
                    }
                ) {
                    MacGatewayChevron()
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
                if let syncSummary = store.lastBootstrapSyncSummary {
                    MacGatewayRowDivider()
                    bootstrapSyncSummaryRow(syncSummary)
                }
            }
            noticeFooter(fallback: store.isReachable == false
                ? L("云端或 Mac 睡眠、断网时无法推送，也无法在这里查看状态。")
                : nil)
        }
    }

    private func bootstrapSyncSummaryRow(_ summary: IOSPairingBootstrapSyncSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                MacGatewayIconPlate(icon: "checkmark.seal", tint: MacDelegationSemanticInk.success)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: L("最近一次配对同步"))
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                        Spacer(minLength: 4)
                        Text(verbatim: L("非敏感摘要"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(AmberTheme.muted)
                    }
                    Text(verbatim: summary.summaryText)
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.foreground2)
                        .fixedSize(horizontal: false, vertical: true)
                    if summary.credentialsImported {
                        Text(verbatim: L("凭据已通过临时密钥端到端加密导入，界面不展示明文密钥或 Token。"))
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func siwcSignInGuidanceSection(_ prompt: LocalSiwcPromptState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.badge.key.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MacDelegationSemanticInk.warning)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: L("云端已配置 ChatGPT（SIWC），需在本机登录"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: prompt.modelLabel.isEmpty
                         ? L("ChatGPT（SIWC）登录态仅保存在当前设备，不会随扫码同步导出；请在本机完成登录以继续使用。")
                         : L("当前云端模型为 \(prompt.modelLabel)。SIWC 登录态与设备绑定，不会随扫码同步导出；请在本机完成登录。"))
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.foreground2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    siwcPrimaryButton(prompt)
                    siwcSecondaryButton
                }
                VStack(spacing: 8) {
                    siwcPrimaryButton(prompt)
                    siwcSecondaryButton
                }
            }
        }
        .padding(14)
        .background(
            MacDelegationSemanticInk.warning.opacity(colorScheme == .dark ? 0.14 : 0.08),
            in: RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                .strokeBorder(MacDelegationSemanticInk.warning.opacity(0.45), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func siwcPrimaryButton(_ prompt: LocalSiwcPromptState) -> some View {
        Button {
            if let providerId = prompt.providerId {
                presentingSiwcProviderId = providerId
            } else {
                router.navigate(to: .providers)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.subheadline.weight(.semibold))
                Text(verbatim: prompt.providerId != nil ? L("立即在本机登录 SIWC") : L("前往配置并登录 SIWC"))
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(AmberTheme.accentInk)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 12)
            .background(AmberTheme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var siwcSecondaryButton: some View {
        Button {
            router.navigate(to: .providers)
        } label: {
            Text(verbatim: L("模型服务商"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AmberTheme.foreground)
                .frame(minWidth: 96, maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 44)
                .padding(.horizontal, 12)
                .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(AmberTheme.borderSoft, lineWidth: 0.75)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private var cloudConfigSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "云端配置")
            AmberFormGroup {
                MacGatewayRow(icon: "icloud", title: L("打开云端常驻对话"),
                              detail: L("进入云端独立对话流，不影响主界面的统一时间线"),
                              action: { presentingCloudDialogue = true }) {
                    MacGatewayChevron()
                }
                MacGatewayRowDivider()
                MacGatewayRow(icon: "gearshape.2", title: L("模型与搜索"),
                              detail: L("查看云端 provider/model，或从本机导入配置与 API Key"),
                              action: { router.navigate(to: .cloudConfig) }) {
                    MacGatewayChevron()
                }
                MacGatewayRowDivider()
                MacGatewayRow(icon: "checklist", title: L("行为习惯与规则"),
                              detail: proceduralRulesSummary,
                              action: { router.navigate(to: .proceduralRules) }) {
                    MacGatewayChevron()
                }
            }
        }
    }

    private var proceduralRulesSummary: String {
        let proposed = ruleStore.proposedCount
        let active = ruleStore.activeCount
        if proposed > 0 {
            return L("待你确认 \(proposed) 条 · 生效中 \(active) 条")
        }
        if active > 0 {
            return L("正在生效 \(active) 条")
        }
        return L("管理你交代过 Amber 的固定做法")
    }

    private func bootstrapHintSummary(_ hint: MacGatewayPairingBootstrapHint) -> String {
        var parts: [String] = []
        if !hint.provider.isEmpty {
            let auth = hint.siwcConfigured || hint.authMode == "chatgptSiwc" ? "SIWC" : hint.authMode
            parts.append("\(hint.provider) (\(auth))")
        }
        if hint.hasEncryptedCredentials {
            parts.append(L("含端到端加密凭据"))
        }
        if hint.soulRevision > 0 {
            parts.append(L("形象人设 v\(hint.soulRevision)"))
        }
        if hint.activeRulesCount > 0 {
            parts.append(L("\(hint.activeRulesCount) 条生效习惯"))
        }
        return parts.isEmpty
            ? L("配对后将使用临时 RSA 密钥自动同步云端配置")
            : parts.joined(separator: " · ")
    }

    private var deviceContextSharingSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "本机只读摘要共享")
            AmberFormGroup {
                sharingToggleRow(
                    title: "共享未来 48 小时日程摘要",
                    subtitle: "仅上传标题与起止时间，不含地点、参会人或备注",
                    isOn: Binding(
                        get: { store.shareCalendarUpcomingEnabled },
                        set: { store.setShareCalendarUpcoming($0) }
                    )
                )
                MacGatewayRowDivider()
                sharingToggleRow(
                    title: "共享待办提醒摘要",
                    subtitle: "仅上传未完成待办标题、到期时间与优先级",
                    isOn: Binding(
                        get: { store.shareRemindersDueEnabled },
                        set: { store.setShareRemindersDue($0) }
                    )
                )
                MacGatewayRowDivider()
                sharingToggleRow(
                    title: "共享近期 Workspace 产出目录",
                    subtitle: "仅上传最近 10 条产出的标题、类型与 60 字摘要",
                    isOn: Binding(
                        get: { store.shareWorkspaceArtifactsEnabled },
                        set: { store.setShareWorkspaceArtifacts($0) }
                    )
                )
                if store.anyDeviceContextSharingEnabled {
                    MacGatewayRowDivider()
                    MacGatewayRow(
                        icon: "arrow.triangle.2.circlepath",
                        title: L("立即刷新快照"),
                        detail: deviceContextStatusText
                    ) {
                        if store.isSyncingDeviceContext {
                            ProgressView().frame(width: 44, height: 44)
                        } else {
                            MacGatewayCapsuleButton(title: L("刷新")) {
                                Task { _ = await store.syncDeviceContextIfNeeded(trigger: .manual) }
                            }
                        }
                    }
                }
            }
            noticeFooter(fallback: deviceContextFooterText)
        }
    }

    private func sharingToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: L(title))
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                Text(verbatim: L(subtitle))
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var deviceContextStatusText: String {
        if let expiresMs = store.deviceContextMetadata?.expiresAtEpochMs,
           store.deviceContextMetadata?.status == "active" {
            let expiresDate = Date(timeIntervalSince1970: TimeInterval(expiresMs) / 1_000)
            return L("云端副本将于 ") + expiresDate.formatted(date: .omitted, time: .shortened) + L(" 过期")
        }
        if store.deviceContextMetadata?.status == "expired" {
            return L("云端副本已过期并清理")
        }
        return L("仅在前台且开启上方开关时推送")
    }

    private var deviceContextFooterText: String {
        if store.pendingDeviceContextRemoteDelete {
            return L("已关闭本机共享；待连接恢复后将自动清空云端缓存。")
        }
        if store.anyDeviceContextSharingEnabled {
            return deviceContextStatusText + L(" · 全部关闭开关将立即删除云端快照。")
        }
        return L("所有共享开关默认关闭，不会上传任何本机摘要。")
    }

    private var boardSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "任务")
            AmberFormGroup {
                MacGatewayRow(icon: "paperplane", title: L("交给云端执行"),
                              detail: L("直接向云端 Agent 派发任务，持久执行并查看结果"),
                              action: { presentingCloudCompose = true }) {
                    MacGatewayChevron()
                }
                MacGatewayRowDivider()
                MacGatewayRow(icon: "checklist", title: L("打开任务看板"),
                              detail: L("查看云端任务进度与结果、定时任务及 Claude Code / Codex 会话"),
                              action: { router.navigate(to: .macTasks) }) {
                    MacGatewayChevron()
                }
            }
        }
    }

    private var unpairSection: some View {
        AmberFormGroup {
            actionRow(L("取消配对"), color: MacDelegationSemanticInk.danger, isBusy: store.isBusy) {
                confirmsUnpair = true
            }
        }
        .padding(.top, 28)
    }

    // MARK: - Helpers

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

    /// Evaluates local SIWC sign-in state off `body` (no Keychain/disk IO during layout).
    private func refreshLocalSiwcPrompt() {
        guard store.connection != nil else {
            localSiwcPrompt = nil
            return
        }
        let summary = store.lastBootstrapSyncSummary
        let cloudModel = store.cloudConfig?.model
        let cloudUsesSiwc = (summary?.requiresLocalSignIn == true)
            || (summary?.siwcConfigured == true)
            || (summary?.authMode == "chatgptSiwc")
            || (cloudModel?.siwcConfigured == true)
            || (cloudModel?.authMode == "chatgptSiwc")
        guard cloudUsesSiwc else {
            localSiwcPrompt = nil
            return
        }

        let providers = resolvedSharedSettings?.snapshot.providers ?? []
        let siwcProviders = providers.filter { $0.enabled && IOSCodexProviderResolver.isChatGptSiwcProvider($0) }
        if siwcProviders.contains(where: { IOSCodexProviderResolver.isSignedIn($0) }) {
            localSiwcPrompt = nil
            return
        }

        let providerName = (summary?.provider.isEmpty == false ? summary?.provider : cloudModel?.provider) ?? ""
        let modelId = (summary?.modelId.isEmpty == false ? summary?.modelId : cloudModel?.modelId) ?? ""
        let label = [providerName, modelId].filter { !$0.isEmpty }.joined(separator: " · ")
        localSiwcPrompt = LocalSiwcPromptState(
            providerId: siwcProviders.first?.id.description(),
            modelLabel: label
        )
    }

    // MARK: - Text

    private var sessionStatusDotColor: Color {
        switch store.cloudSessionHealth {
        case .healthy:
            return MacDelegationSemanticInk.success
        case .checking, .modelUnconfigured, .degraded:
            return MacDelegationSemanticInk.warning
        case .offline:
            return MacDelegationSemanticInk.danger
        case .unpaired:
            return AmberTheme.muted
        }
    }

    private var reachabilityText: String {
        switch store.cloudSessionHealth {
        case .unpaired:
            return L("未配对")
        case .checking:
            return L("正在连接…")
        case .offline(let reason):
            return L("无法连接") + (reason.isEmpty ? "" : " · \(reason)")
        case .modelUnconfigured(let reason), .degraded(let reason):
            return reason
        case .healthy:
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
                    ProgressView()
                        .controlSize(.small)
                        .tint(color)
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
        if let notice = store.notice {
            MacGatewaySectionFooter(
                text: notice.text,
                color: notice.isError ? MacDelegationSemanticInk.warning : AmberTheme.muted
            )
        } else if let fallback {
            MacGatewaySectionFooter(text: fallback)
        }
    }
}

private func L(_ key: String) -> String {
    IOSAppLocalization.string(key, defaultValue: key)
}
