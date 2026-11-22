import AppKit
import SwiftUI

/// 设置 › 云端：pair this Mac to a cloud amberd, review its model/search configuration,
/// and import selected local provider/search keys over the paired, pinned channel.
struct DesktopCloudSelfSettingsView: View {
    @Bindable var store: DesktopCloudSelfStore
    @State private var confirmsUnpair = false
    @State private var importPresented = false
    @State private var configEditorPresented = false
    @State private var pairingSheetPresented = false
    @State private var showTechnical = false
    @State private var showAddRuleForm = false
    @State private var showHistoryRules = false
    @State private var newRuleTitle = ""
    @State private var newRuleInstruction = ""
    @State private var rulePendingRevoke: DesktopProceduralRule?
    @State private var copiedFieldID: String?

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
                    .foregroundStyle(DesktopTheme.inkSecondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { store.startPolling() }
        .onDisappear { store.stopPolling() }
        .onChange(of: store.issuedPairingTicket != nil) { _, hasTicket in
            if hasTicket { pairingSheetPresented = true }
        }
        .onChange(of: store.connection == nil) { _, unpaired in
            if unpaired {
                pairingSheetPresented = false
                rulePendingRevoke = nil
            }
        }
        .sheet(isPresented: $importPresented) {
            DesktopCloudImportSheet(store: store)
        }
        .sheet(isPresented: $configEditorPresented) {
            DesktopCloudConfigSheet(store: store)
        }
        .sheet(isPresented: $pairingSheetPresented, onDismiss: {
            store.clearIssuedPairing()
        }) {
            DesktopCloudSingleScanPairingSheet(store: store)
        }
        .confirmationDialog("取消与云端的配对？", isPresented: $confirmsUnpair, titleVisibility: .visible) {
            Button("取消配对", role: .destructive) { Task { await store.unpair() } }
            Button("保留", role: .cancel) {}
        } message: { Text("本机保存的配对凭据会移除；云端设备列表里的此设备同时吊销。本机 Mac Gateway 与已配对手机不受影响。") }
        .confirmationDialog(
            "移除这条习惯？",
            isPresented: Binding(
                get: { rulePendingRevoke != nil },
                set: { if !$0 { rulePendingRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移除", role: .destructive) {
                if let rule = rulePendingRevoke {
                    rulePendingRevoke = nil
                    Task { await store.revokeRule(id: rule.id) }
                }
            }
            Button("取消", role: .cancel) { rulePendingRevoke = nil }
        } message: {
            if let rule = rulePendingRevoke {
                Text("「\(rule.title)」移除后将立即失效且不可恢复；如需再次启用，需要重新添加并确认。")
            }
        }
    }

    // MARK: connection

    private var connectionCard: some View {
        card {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("云端连接").font(.system(size: 14, weight: .semibold)).foregroundStyle(DesktopTheme.ink)
                    HStack(spacing: 6) {
                        connectionStatusIndicator
                        Text(connectionStatusText)
                            .font(.system(size: 12))
                            .foregroundStyle(connectionStatusColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if store.connection != nil {
                    Button { Task { await store.refresh() } } label: {
                        Group {
                            if store.isRefreshing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .frame(width: 28, height: 28)
                    }
                    .buttonStyle(DesktopQuietButtonStyle())
                    .disabled(store.isRefreshing || store.isBusy)
                    .help("刷新云端状态")
                    .accessibilityLabel("刷新云端状态")
                }
            }
            if let connection = store.connection {
                let endpointSummary = DesktopCloudSelfStore.formattedEndpoints(
                    addresses: connection.addrs,
                    port: connection.port
                )
                Divider()
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "cloud").font(.system(size: 15)).foregroundStyle(DesktopTheme.accent)
                        .frame(width: 22).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(connection.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DesktopTheme.ink)
                            .lineLimit(1)
                        Text(endpointSummary)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(endpointSummary)
                    }
                    .frame(minWidth: 0, alignment: .leading)
                    Spacer(minLength: 12)
                    HStack(spacing: 8) {
                        Button {
                            Task {
                                await store.issueSingleScanPairing()
                                if store.issuedPairingTicket != nil {
                                    pairingSheetPresented = true
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if store.isIssuingPairing {
                                    ProgressView().controlSize(.small)
                                }
                                Text(store.isIssuingPairing ? "生成配对码…" : "扫码配对新手机…")
                            }
                        }
                        .disabled(store.isIssuingPairing || store.isBusy)
                        Button("取消配对", role: .destructive) { confirmsUnpair = true }
                            .disabled(store.isBusy)
                    }
                    .fixedSize()
                }
            } else if let pending = store.pendingPairing {
                Divider()
                pendingPairingRows(pending)
            } else {
                Divider()
                HStack(alignment: .center, spacing: 12) {
                    Text("在云端主机运行 amber-cli pair，把输出的 amber:// 配对链接复制到这里。")
                        .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("粘贴配对链接") { store.pasteLinkFromClipboard() }
                        .fixedSize()
                }
            }
        }
    }

    @ViewBuilder
    private var connectionStatusIndicator: some View {
        if store.connection != nil {
            switch store.isReachable {
            case true:
                Circle().fill(DesktopTheme.success).frame(width: 6, height: 6).accessibilityHidden(true)
            case false:
                Circle().fill(DesktopTheme.danger).frame(width: 6, height: 6).accessibilityHidden(true)
            case nil:
                ProgressView().controlSize(.mini).accessibilityHidden(true)
            }
        }
    }

    private func pendingPairingRows(_ payload: DesktopCloudPairingPayload) -> some View {
        let endpointSummary = DesktopCloudSelfStore.formattedEndpoints(
            addresses: payload.addrs,
            port: payload.port
        )
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.shield").font(.system(size: 15)).foregroundStyle(DesktopTheme.accent)
                    .frame(width: 22).padding(.top, 1).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(payload.name).font(.system(size: 13, weight: .medium)).foregroundStyle(DesktopTheme.ink)
                    Text(endpointSummary)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(endpointSummary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("证书指纹").font(.system(size: 11.5, weight: .medium)).foregroundStyle(DesktopTheme.inkSecondary)
                    Spacer()
                    copyIconButton(value: payload.fp, fieldID: "pending-fp", label: "复制证书指纹")
                }
                Text(payload.fp)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DesktopTheme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("请核对与云端终端显示的指纹一致。").font(.system(size: 11)).foregroundStyle(DesktopTheme.inkTertiary)
            }
            .padding(10)
            .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.hairline))
            HStack(spacing: 8) {
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
                Text("云端配置").font(.system(size: 14, weight: .semibold)).foregroundStyle(DesktopTheme.ink)
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
            Text("从本机导入").font(.system(size: 14, weight: .semibold)).foregroundStyle(DesktopTheme.ink)
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
        let proposedRules = store.rules.filter { $0.status == .proposed }
        let activeRules = store.rules.filter { $0.status == .active }
        let historyRules = store.rules.filter { $0.status == .archived || $0.status == .revoked }
        let primaryRules = proposedRules + activeRules

        return card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("行为习惯与规则")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesktopTheme.ink)
                        Text(rulesSummaryText(proposed: proposedRules.count, active: activeRules.count, history: historyRules.count))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(DesktopTheme.inkTertiary)
                    }
                    Spacer(minLength: 8)
                    Button(showAddRuleForm ? "收起" : "添加一条习惯") {
                        showAddRuleForm.toggle()
                    }
                    .buttonStyle(.desktopActionPill)
                    .disabled(store.isMutatingRule)
                    Button { Task { await store.refreshRules() } } label: {
                        Group {
                            if store.isRefreshingRules {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .frame(width: 28, height: 28)
                    }
                    .buttonStyle(DesktopQuietButtonStyle())
                    .disabled(store.isRefreshingRules || store.isMutatingRule)
                    .help("刷新行为习惯与规则")
                    .accessibilityLabel("刷新行为习惯与规则")
                }
                Text("你交代给 Amber 的固定做法，确认后会自动遵守；高风险操作仍会先征得你同意。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showAddRuleForm {
                addRuleForm
            }

            if let redirect = store.ruleSoulRedirectNotice {
                Label(redirect, systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 12))
                    .foregroundStyle(DesktopTheme.accentInk)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.honeyEdge))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.rulesError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(DesktopTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.rules.isEmpty {
                Text("还没有固定习惯。你在对话中纠正过的做法会先出现在这里，确认后才会长期生效。")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if !primaryRules.isEmpty {
                    Divider()
                    ForEach(Array(primaryRules.enumerated()), id: \.element.id) { index, rule in
                        if index > 0 { Divider() }
                        ruleRow(rule)
                    }
                }
                if !historyRules.isEmpty {
                    if primaryRules.isEmpty {
                        Divider()
                        Text("已暂停与已移除（\(historyRules.count)）")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                        ForEach(Array(historyRules.enumerated()), id: \.element.id) { index, rule in
                            if index > 0 { Divider() }
                            ruleRow(rule)
                        }
                    } else {
                        Divider()
                        DisclosureGroup("已暂停与已移除（\(historyRules.count)）", isExpanded: $showHistoryRules) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(historyRules.enumerated()), id: \.element.id) { index, rule in
                                    if index > 0 { Divider() }
                                    ruleRow(rule)
                                }
                            }
                            .padding(.top, 8)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                    }
                }
            }
        }
    }

    private func rulesSummaryText(proposed: Int, active: Int, history: Int) -> String {
        var parts = ["待确认 \(proposed)", "生效中 \(active)"]
        if history > 0 { parts.append("已停用 \(history)") }
        return parts.joined(separator: " · ")
    }

    private var addRuleForm: some View {
        let trimmedInstruction = newRuleInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 8) {
            TextField("简短名称（可选）", text: $newRuleTitle)
                .textFieldStyle(.desktop)
                .disabled(store.isMutatingRule)
            TextField("固定做法（如：提交代码前先跑定向单测）", text: $newRuleInstruction, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.desktop)
                .disabled(store.isMutatingRule)
            HStack(alignment: .center, spacing: 8) {
                Text("如果是语气或性格偏好，请前往「形象人设」调整。")
                    .font(.system(size: 11))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if store.isMutatingRule && store.mutatingRuleId == nil {
                    ProgressView().controlSize(.small)
                }
                Button("取消") {
                    newRuleTitle = ""
                    newRuleInstruction = ""
                    showAddRuleForm = false
                }
                .disabled(store.isMutatingRule)
                Button("添加（待确认）") {
                    let title = newRuleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedInstruction.isEmpty else { return }
                    Task {
                        let result = await store.proposeRule(
                            title: title.isEmpty ? nil : title,
                            instruction: trimmedInstruction
                        )
                        if case .proposed = result {
                            newRuleTitle = ""
                            newRuleInstruction = ""
                            showAddRuleForm = false
                        }
                    }
                }
                .buttonStyle(.desktopProminent)
                .disabled(store.isMutatingRule || trimmedInstruction.isEmpty)
            }
        }
        .padding(12)
        .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.hairline))
    }

    private func ruleRow(_ rule: DesktopProceduralRule) -> some View {
        let isHistory = rule.status == .archived || rule.status == .revoked
        let isThisMutating = store.mutatingRuleId == rule.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(rule.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isHistory ? DesktopTheme.inkSecondary : DesktopTheme.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    ruleStatusBadge(rule.status)
                        .fixedSize()
                        .layoutPriority(1)
                }
                .frame(minWidth: 0, alignment: .leading)
                Spacer(minLength: 10)
                if rule.status == .proposed || rule.status == .active {
                    HStack(spacing: 8) {
                        if isThisMutating {
                            ProgressView().controlSize(.small)
                        }
                        if rule.status == .proposed {
                            Button("确认生效") { Task { await store.confirmRule(id: rule.id) } }
                                .buttonStyle(.desktopTintedPill)
                                .disabled(store.isMutatingRule)
                            Button("移除", role: .destructive) { rulePendingRevoke = rule }
                                .buttonStyle(RuleDestructivePillButtonStyle())
                                .disabled(store.isMutatingRule)
                        } else if rule.status == .active {
                            Button("暂停") { Task { await store.archiveRule(id: rule.id) } }
                                .buttonStyle(.desktopActionPill)
                                .disabled(store.isMutatingRule)
                            Button("移除", role: .destructive) { rulePendingRevoke = rule }
                                .buttonStyle(RuleDestructivePillButtonStyle())
                                .disabled(store.isMutatingRule)
                        }
                    }
                    .fixedSize()
                    .layoutPriority(2)
                }
            }
            Text(rule.instruction)
                .font(.system(size: 12.5))
                .foregroundStyle(isHistory ? DesktopTheme.inkTertiary : DesktopTheme.inkSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                let scopeLabel = rule.scope == "global" ? "全部对话" : rule.scope
                Text("适用范围：\(scopeLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(rule.scope)
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                Text("已应用 \(rule.hitCount) 次")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(DesktopTheme.inkTertiary)
                    .fixedSize()
            }
        }
        .padding(.vertical, 2)
    }

    private func ruleStatusBadge(_ status: DesktopProceduralRuleStatus) -> some View {
        let style = Self.badgeStyle(for: status)
        return Text(Self.statusLabel(for: status))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(style.foreground)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(style.background))
            .overlay(Capsule().strokeBorder(style.border, lineWidth: 0.75))
    }

    private static func statusLabel(for status: DesktopProceduralRuleStatus) -> String {
        switch status {
        case .proposed: "待确认"
        case .active: "生效中"
        case .archived: "已暂停"
        case .revoked: "已移除"
        }
    }

    private static func badgeStyle(for status: DesktopProceduralRuleStatus) -> (foreground: Color, background: Color, border: Color) {
        switch status {
        case .proposed:
            return (DesktopTheme.accentInk, DesktopTheme.honeySoft, DesktopTheme.honeyEdge)
        case .active:
            return (DesktopTheme.success, DesktopTheme.success.opacity(0.12), DesktopTheme.success.opacity(0.32))
        case .archived:
            return (DesktopTheme.inkSecondary, DesktopTheme.paperDeep, DesktopTheme.hairlineStrong)
        case .revoked:
            return (DesktopTheme.danger, DesktopTheme.danger.opacity(0.10), DesktopTheme.danger.opacity(0.28))
        }
    }

    private var technicalCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let connection = store.connection {
                let endpointSummary = DesktopCloudSelfStore.formattedEndpoints(
                    addresses: connection.addrs,
                    port: connection.port
                )
                techRow("TLS 代理", endpointSummary, fieldID: "tech-endpoint")
                techRow("云端实例", connection.gatewayId, fieldID: "tech-gateway")
                techRow("设备标识", connection.deviceId, fieldID: "tech-device")
                techRow("证书指纹", connection.fingerprint, fieldID: "tech-fp")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.hairline))
    }

    private func techRow(_ title: String, _ value: String, fieldID: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(DesktopTheme.inkTertiary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DesktopTheme.inkSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            copyIconButton(value: value, fieldID: fieldID, label: "复制\(title)")
        }
    }

    private func copyIconButton(value: String, fieldID: String, label: String) -> some View {
        let isCopied = copiedFieldID == fieldID
        return Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copiedFieldID = fieldID
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                if copiedFieldID == fieldID { copiedFieldID = nil }
            }
        } label: {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isCopied ? DesktopTheme.success : DesktopTheme.inkTertiary)
                .frame(width: 24, height: 22)
        }
        .buttonStyle(DesktopQuietButtonStyle())
        .help(isCopied ? "已复制" : label)
        .accessibilityLabel(isCopied ? "已复制" : label)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.hairline))
    }
}

/// Destructive counterpart of `DesktopActionPillButtonStyle` sharing identical 25pt height and geometry.
private struct RuleDestructivePillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Label(configuration: configuration) }
    private struct Label: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DesktopTheme.danger)
                .padding(.horizontal, 10)
                .frame(height: 25)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering && enabled ? DesktopTheme.danger.opacity(0.14) : DesktopTheme.danger.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(DesktopTheme.danger.opacity(hovering && enabled ? 0.42 : 0.24), lineWidth: 0.75)
                )
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.42)
                .scaleEffect(configuration.isPressed && enabled ? 0.97 : 1)
                .animation(.easeOut(duration: 0.14), value: hovering)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

/// Single-scan onboarding QR sheet for pairing a new phone with encrypted config + C-SOUL-V1 + active rules sync.
struct DesktopCloudSingleScanPairingSheet: View {
    @Bindable var store: DesktopCloudSelfStore
    @Environment(\.dismiss) private var dismiss
    @State private var now = Date()
    @State private var copiedLink = false
    @State private var copiedFingerprint = false

    private static let qrDisplaySize: CGFloat = 240
    private static let qrQuietZone: CGFloat = 20

    var body: some View {
        let ticket = store.issuedPairingTicket
        let remainingSeconds = ticket.map { max(0, Int(Date(timeIntervalSince1970: $0.expiresAt).timeIntervalSince(now))) } ?? 0
        let isExpired = ticket != nil && remainingSeconds == 0

        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("单次扫码配对新手机")
                    .font(DesktopTheme.serif(size: 20, weight: .semibold))
                    .foregroundStyle(DesktopTheme.ink)
                Text("手机一次扫码即可建立配对，并通过加密信道自动同步当前模型配置、形象人设与已生效的行为习惯。")
                    .font(.system(size: 12))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            qrContainer(ticket: ticket, isExpired: isExpired)

            if let issueError = store.pairingIssueError {
                Label(issueError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(DesktopTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let ticket {
                let endpointSummary = DesktopCloudSelfStore.formattedEndpoints(
                    addresses: ticket.addresses,
                    port: ticket.port
                )
                VStack(alignment: .leading, spacing: 8) {
                    infoRow("TLS 代理", value: endpointSummary, mono: true)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("证书指纹")
                            .font(.system(size: 12))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                            .frame(width: 64, alignment: .leading)
                        Text(ticket.fingerprint)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DesktopTheme.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ticket.fingerprint, forType: .string)
                            copiedFingerprint = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.6))
                                copiedFingerprint = false
                            }
                        } label: {
                            Image(systemName: copiedFingerprint ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(copiedFingerprint ? DesktopTheme.success : DesktopTheme.inkTertiary)
                                .frame(width: 24, height: 22)
                        }
                        .buttonStyle(DesktopQuietButtonStyle())
                        .help(copiedFingerprint ? "已复制证书指纹" : "复制证书指纹")
                        .accessibilityLabel(copiedFingerprint ? "已复制证书指纹" : "复制证书指纹")
                    }
                    infoRow("同步内容", value: syncSummary(ticket.bootstrap), mono: false)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("有效期")
                            .font(.system(size: 12))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                            .frame(width: 64, alignment: .leading)
                        Text(remainingText(seconds: remainingSeconds))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(remainingSeconds <= 30 ? DesktopTheme.danger : DesktopTheme.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    infoRow("安全说明", value: "二维码不含明文 API Key 或 OAuth Token", mono: false, subtle: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.hairline))
            }

            HStack(spacing: 10) {
                Button {
                    guard let ticket else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ticket.deepLinkUrl, forType: .string)
                    copiedLink = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.8))
                        copiedLink = false
                    }
                } label: {
                    Label(copiedLink ? "已复制链接" : "复制配对链接", systemImage: copiedLink ? "checkmark" : "doc.on.doc")
                }
                .disabled(ticket == nil || isExpired || store.isIssuingPairing)

                Button {
                    copiedLink = false
                    copiedFingerprint = false
                    Task { await store.issueSingleScanPairing() }
                } label: {
                    HStack(spacing: 5) {
                        if store.isIssuingPairing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("刷新配对码")
                    }
                }
                .disabled(store.isIssuingPairing)

                Spacer()

                Button("完成") {
                    store.clearIssuedPairing()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(DesktopTheme.paper)
        .task {
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private func qrContainer(ticket: DesktopIssuedPairingTicket?, isExpired: Bool) -> some View {
        let totalSize = Self.qrDisplaySize + Self.qrQuietZone * 2
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(DesktopTheme.hairlineStrong, lineWidth: 1)
                )

            if let ticket, let image = DesktopGatewayPairingSheet.qrImage(ticket.deepLinkUrl) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: Self.qrDisplaySize, height: Self.qrDisplaySize)
                    .padding(Self.qrQuietZone)
                    .opacity(isExpired || store.isIssuingPairing ? 0.16 : 1)
                    .accessibilityLabel("单次扫码配对二维码")
            } else if !store.isIssuingPairing {
                VStack(spacing: 8) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.black.opacity(0.45))
                    Text("无法渲染二维码，请刷新配对码或复制链接")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.black.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }

            if store.isIssuingPairing {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.regular)
                    Text("正在生成新配对码…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.75))
                }
                .padding(14)
                .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
            } else if isExpired {
                VStack(spacing: 10) {
                    Text("配对码已过期")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.85))
                    Button("刷新配对码") {
                        Task { await store.issueSingleScanPairing() }
                    }
                    .buttonStyle(.desktopProminent)
                }
                .padding(16)
                .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(width: totalSize, height: totalSize)
    }

    private func syncSummary(_ hint: DesktopPairingBootstrapHint) -> String {
        let auth = hint.siwcConfigured ? "SIWC" : (hint.authMode.isEmpty ? "apiKey" : hint.authMode)
        let provider = hint.provider.isEmpty ? "默认配置" : "\(hint.provider) (\(auth))"
        return "\(provider) · 人设 v\(hint.soulRevision) · \(hint.activeRulesCount) 条生效习惯"
    }

    private func infoRow(_ title: String, value: String, mono: Bool, subtle: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(DesktopTheme.inkTertiary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: mono ? 11.5 : (subtle ? 11.5 : 12), design: mono ? .monospaced : .default))
                .foregroundStyle(subtle ? DesktopTheme.inkTertiary : DesktopTheme.inkSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func remainingText(seconds: Int) -> String {
        if seconds <= 0 {
            return "已过期，请刷新配对码"
        }
        return String(format: "%d:%02d，仅可使用一次", seconds / 60, seconds % 60)
    }
}
