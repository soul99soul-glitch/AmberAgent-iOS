import AppKit
import SwiftUI

/// 设置 › 云端：pair this Mac to a cloud amberd, review its model/search configuration,
/// and import selected local provider/search keys over the paired, pinned channel.
struct DesktopCloudSelfSettingsView: View {
    @Bindable var store: DesktopCloudSelfStore
    @State private var confirmsUnpair = false
    @State private var importPresented = false
    @State private var configEditorPresented = false
    @State private var showTechnical = false
    @State private var showAddRuleForm = false
    @State private var newRuleTitle = ""
    @State private var newRuleInstruction = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("让云端 Amber 使用你选择的模型与搜索配置。Key 只在这台 Mac 的钥匙串读取，经已配对的加密连接上传，不经聊天、不落明文盘。")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).fixedSize(horizontal: false, vertical: true)
                connectionCard
                if let notice = store.notice {
                    Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle" : "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(notice.isError ? DesktopTheme.danger : DesktopTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.connection != nil {
                    remoteConfigCard
                    importCard
                    proceduralRulesCard
                    DisclosureGroup("连接详情", isExpanded: $showTechnical) {
                        technicalCard
                            .padding(.top, 8)
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { store.startPolling() }
        .onDisappear { store.stopPolling() }
        .sheet(isPresented: $importPresented) {
            DesktopCloudImportSheet(store: store)
        }
        .sheet(isPresented: $configEditorPresented) {
            DesktopCloudConfigSheet(store: store)
        }
        .sheet(item: Binding(
            get: { store.issuedPairingTicket.map { IssuedPairingSheetID(url: $0.deepLinkUrl) } },
            set: { if $0 == nil { store.clearIssuedPairing() } }
        )) { _ in
            DesktopCloudSingleScanPairingSheet(store: store)
        }
        .confirmationDialog("取消与云端的配对？", isPresented: $confirmsUnpair, titleVisibility: .visible) {
            Button("取消配对", role: .destructive) { Task { await store.unpair() } }
            Button("保留", role: .cancel) {}
        } message: { Text("本机保存的配对凭据会移除；云端设备列表里的此设备同时吊销。本机 Mac Gateway 与已配对手机不受影响。") }
    }

    // MARK: connection

    private var connectionCard: some View {
        card {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("云端连接").font(.system(size: 14, weight: .semibold))
                    Text(connectionStatusText).font(.system(size: 12)).foregroundStyle(connectionStatusColor)
                }
                Spacer()
                if store.connection != nil {
                    Button { Task { await store.refresh() } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderless).accessibilityLabel("刷新云端状态")
                }
            }
            if let connection = store.connection {
                Divider()
                HStack(spacing: 12) {
                    Image(systemName: "cloud").font(.system(size: 15)).foregroundStyle(DesktopTheme.accent)
                        .frame(width: 22).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(connection.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(connection.addrs.joined(separator: " · ")).font(.system(size: 12))
                            .foregroundStyle(DesktopTheme.inkTertiary).lineLimit(1)
                    }
                    Spacer()
                    Button("扫码配对新手机…") { Task { await store.issueSingleScanPairing() } }
                        .disabled(store.isIssuingPairing)
                    Button("取消配对", role: .destructive) { confirmsUnpair = true }
                }
            } else if let pending = store.pendingPairing {
                Divider()
                pendingPairingRows(pending)
            } else {
                Divider()
                HStack {
                    Text("在云端主机运行 amber-cli pair，把输出的 amber:// 配对链接复制到这里。")
                        .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("粘贴配对链接") { store.pasteLinkFromClipboard() }
                }
            }
        }
    }

    private func pendingPairingRows(_ payload: DesktopCloudPairingPayload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield").font(.system(size: 15)).foregroundStyle(DesktopTheme.accent)
                    .frame(width: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(payload.name).font(.system(size: 13, weight: .medium))
                    Text(payload.addrs.joined(separator: " · ")).font(.system(size: 12))
                        .foregroundStyle(DesktopTheme.inkTertiary).lineLimit(2)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("证书指纹").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                Text(payload.fp).font(.system(size: 11, design: .monospaced)).foregroundStyle(DesktopTheme.inkSecondary)
                    .textSelection(.enabled).lineLimit(2).minimumScaleFactor(0.85)
                Text("请核对与云端终端显示的指纹一致。").font(.system(size: 11)).foregroundStyle(DesktopTheme.inkTertiary)
            }
            HStack {
                if store.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { store.pendingPairing = nil }.disabled(store.isBusy)
                Button("配对") { Task { await store.confirmPairing() } }
                    .buttonStyle(.desktopProminent).disabled(store.isBusy)
            }
        }
    }

    private var connectionStatusText: String {
        if store.connection == nil {
            return store.pendingPairing == nil ? "未配对" : "核对指纹后确认配对"
        }
        switch store.isReachable {
        case nil: return "正在连接…"
        case false: return "无法连接（云端未启动或网络不可达）"
        case true:
            if let sampled = store.status?.serverTime {
                return "在线 · 更新于 " + sampled.formatted(.relative(presentation: .named))
            }
            return "在线"
        }
    }

    private var connectionStatusColor: Color {
        store.isReachable == false ? DesktopTheme.danger : DesktopTheme.inkTertiary
    }

    // MARK: remote config

    private var remoteConfigCard: some View {
        card {
            HStack {
                Text("云端配置").font(.system(size: 14, weight: .semibold))
                Spacer()
                if store.canSyncConfig {
                    Button("手动更新…") { configEditorPresented = true }
                }
            }
            if !store.canSyncConfig {
                Text("云端配置接口由后端契约接入；当前可先核对下方「从本机导入」预览。")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let config = store.remoteConfig {
                Divider()
                LabeledContent("模型") {
                    let label = [config.model.provider, config.model.modelId].filter { !$0.isEmpty }.joined(separator: " · ")
                    Text(label.isEmpty ? "未配置" : label).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkSecondary)
                }
                if !config.model.baseURL.isEmpty {
                    LabeledContent("接口地址") {
                        Text(config.model.baseURL).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                LabeledContent("模型 Key") { keyBadge(configured: config.model.keyConfigured) }
                let search = config.search
                LabeledContent("搜索") {
                    Text(search.sources.isEmpty ? "未配置" : search.sources.joined(separator: search.mode == "aggregate" ? " + " : " → "))
                        .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkSecondary)
                }
                if search.sources.contains("exa") || search.exaKeyConfigured {
                    LabeledContent("Exa Key") { keyBadge(configured: search.exaKeyConfigured) }
                }
                if search.sources.contains("brave") || search.braveKeyConfigured {
                    LabeledContent("Brave Key") { keyBadge(configured: search.braveKeyConfigured) }
                }
            } else {
                Text(store.remoteConfigError ?? "读取云端配置中…")
                    .font(.system(size: 12))
                    .foregroundStyle(store.remoteConfigError == nil ? DesktopTheme.inkTertiary : DesktopTheme.danger)
            }
        }
    }

    private func keyBadge(configured: Bool) -> some View {
        Text(configured ? "已配置" : "未配置")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(configured ? DesktopTheme.inkSecondary : DesktopTheme.danger)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().strokeBorder(DesktopTheme.hairline, lineWidth: 1))
    }

    // MARK: import

    private var importCard: some View {
        card {
            Text("从本机导入").font(.system(size: 14, weight: .semibold))
            Text("选择要复用到云端的服务商与搜索 Key；上传前可预览每一项将替换的云端配置，Key 离开钥匙串即封装加密。")
                .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let configured = store.lastConfiguredSecrets, !configured.isEmpty {
                Text("上次导入已配置：" + configured.sorted().map(DesktopCloudSelfStore.secretDisplayName).joined(separator: "、"))
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkSecondary)
            }
            HStack {
                Spacer()
                Button("选择并导入…") { importPresented = true }
                    .buttonStyle(.desktopProminent)
            }
        }
    }

    // MARK: procedural rules (Stage 3-A)

    private var proceduralRulesCard: some View {
        let activeCount = store.rules.filter { $0.status == .active }.count
        let proposedCount = store.rules.filter { $0.status == .proposed }.count
        return card {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("执行规则卡").font(.system(size: 14, weight: .semibold))
                    Text("生效中 \(activeCount) · 待确认 \(proposedCount) · 仅确认后生效，不可放宽 L1–L3 风险表")
                        .font(.system(size: 11.5)).foregroundStyle(DesktopTheme.inkTertiary)
                }
                Spacer()
                Button { showAddRuleForm.toggle() } label: {
                    Text(showAddRuleForm ? "收起" : "新增提议")
                }
                Button { Task { await store.refreshRules() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderless).accessibilityLabel("刷新规则卡")
            }

            if showAddRuleForm {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("规则标题（可选）", text: $newRuleTitle)
                        .textFieldStyle(.desktop)
                    TextField("执行规矩（如：提交代码前先跑定向单测；纯性格/语气请改用形象人设）", text: $newRuleInstruction)
                        .textFieldStyle(.desktop)
                    HStack {
                        Spacer()
                        Button("提议（待确认）") {
                            let title = newRuleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            let instruction = newRuleInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !instruction.isEmpty else { return }
                            Task {
                                let result = await store.proposeRule(
                                    title: title.isEmpty ? nil : title,
                                    instruction: instruction
                                )
                                if case .proposed = result {
                                    newRuleTitle = ""
                                    newRuleInstruction = ""
                                    showAddRuleForm = false
                                }
                            }
                        }
                        .buttonStyle(.desktopProminent)
                        .disabled(store.isMutatingRule || newRuleInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(10)
                .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))
            }

            if let redirect = store.ruleSoulRedirectNotice {
                Label(redirect, systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 12))
                    .foregroundStyle(DesktopTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.rulesError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(DesktopTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.rules.isEmpty {
                Text("尚无规则卡。你在对话中的执行纠正会先生成待确认规则卡，显式确认后才会注入上下文。")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(store.rules.enumerated()), id: \.element.id) { index, rule in
                    if index > 0 { Divider() }
                    ruleRow(rule)
                }
            }
        }
    }

    private func ruleRow(_ rule: DesktopProceduralRule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(rule.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(rule.status.displayTitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(rule.status == .active ? DesktopTheme.accent : DesktopTheme.inkTertiary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().strokeBorder(DesktopTheme.hairline, lineWidth: 1))
                Text("命中 \(rule.hitCount) 次")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                Spacer()
                if rule.status == .proposed {
                    Button("确认生效") { Task { await store.confirmRule(id: rule.id) } }
                        .disabled(store.isMutatingRule)
                    Button("撤销", role: .destructive) { Task { await store.revokeRule(id: rule.id) } }
                        .disabled(store.isMutatingRule)
                } else if rule.status == .active {
                    Button("归档") { Task { await store.archiveRule(id: rule.id) } }
                        .disabled(store.isMutatingRule)
                    Button("撤销", role: .destructive) { Task { await store.revokeRule(id: rule.id) } }
                        .disabled(store.isMutatingRule)
                }
            }
            Text(rule.instruction)
                .font(.system(size: 12))
                .foregroundStyle(DesktopTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("作用域：\(rule.scope == "global" ? "全局" : rule.scope)")
                .font(.system(size: 11))
                .foregroundStyle(DesktopTheme.inkTertiary)
        }
    }

    private struct IssuedPairingSheetID: Identifiable { let url: String; var id: String { url } }

    private var technicalCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let connection = store.connection {
                techRow("云端实例", connection.gatewayId)
                techRow("设备标识", connection.deviceId)
                techRow("证书指纹", connection.fingerprint)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))
    }

    private func techRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 11)).foregroundStyle(DesktopTheme.inkTertiary).frame(width: 56, alignment: .leading)
            Text(value).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(DesktopTheme.inkSecondary)
                .textSelection(.enabled).lineLimit(2).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.hairline))
    }
}

/// Single-scan onboarding QR sheet for pairing a new phone with encrypted config + C-SOUL-V1 + active rules sync.
struct DesktopCloudSingleScanPairingSheet: View {
    @Bindable var store: DesktopCloudSelfStore
    @Environment(\.dismiss) private var dismiss
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 16) {
            Text("单次扫码配对新手机").font(DesktopTheme.serif(size: 20, weight: .semibold))
            if let ticket = store.issuedPairingTicket {
                if let image = DesktopGatewayPairingSheet.qrImage(ticket.deepLinkUrl) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220)
                        .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("单次扫码配对二维码")
                }
                Text("手机一次扫码即可建立配对，并通过加密信道自动同步当前 Provider 配置、C-SOUL-V1 人设与生效规则卡。")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkSecondary)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 6) {
                    row("同步内容", syncSummary(ticket.bootstrap), mono: false)
                    row("证书指纹", ticket.fingerprint, mono: true)
                    row("安全说明", "二维码不含明文 API Key 或 OAuth Token", mono: false)
                    row("有效期", remaining(Date(timeIntervalSince1970: ticket.expiresAt)), mono: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if let ticket = store.issuedPairingTicket {
                    Button("复制配对链接") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ticket.deepLinkUrl, forType: .string)
                    }
                }
                Spacer()
                Button("完成") {
                    store.clearIssuedPairing()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(DesktopTheme.paper)
        .task {
            while !Task.isCancelled {
                now = Date()
                if let ticket = store.issuedPairingTicket,
                   Date().timeIntervalSince1970 >= ticket.expiresAt {
                    store.clearIssuedPairing()
                    dismiss()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func syncSummary(_ hint: DesktopPairingBootstrapHint) -> String {
        let auth = hint.siwcConfigured ? "SIWC" : (hint.authMode.isEmpty ? "apiKey" : hint.authMode)
        let provider = hint.provider.isEmpty ? "默认配置" : "\(hint.provider) (\(auth))"
        return "\(provider) · Soul v\(hint.soulRevision) · \(hint.activeRulesCount) 条生效规则"
    }

    private func row(_ title: String, _ value: String, mono: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).frame(width: 60, alignment: .leading)
            Text(value).font(.system(size: mono ? 11 : 12, design: mono ? .monospaced : .default))
                .foregroundStyle(DesktopTheme.inkSecondary)
                .textSelection(.enabled)
                .lineLimit(mono ? 1 : nil)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: !mono)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func remaining(_ expiry: Date) -> String {
        let seconds = max(0, Int(expiry.timeIntervalSince(now)))
        return String(format: "%d:%02d，仅可使用一次", seconds / 60, seconds % 60)
    }
}
