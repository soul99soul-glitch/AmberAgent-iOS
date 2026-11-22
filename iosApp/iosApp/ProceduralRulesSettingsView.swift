import SwiftUI
import UIKit

/// Restrained management surface for "correction -> procedural rule card" memory (Stage 3-D).
/// Follows Arquiel Design 2.0: >=44pt hit targets, >=4.5:1 light/dark contrast, zero disk IO in `body`.
struct ProceduralRulesSettingsView: View {
    let sharedSettings: IOSSharedSettingsStore

    private enum RuleActionKind: Equatable {
        case confirm
        case archive
        case revoke
    }

    private enum BannerStyle: Equatable {
        case success
        case warning
        case riskImmutable
        case redirectToSoul
    }

    private struct FeedbackBannerState: Equatable {
        let style: BannerStyle
        let message: String
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let store = IOSProceduralRuleStore.shared
    private let gatewayStore = MacGatewayStore.shared

    @State private var showingProposeSheet = false
    @State private var showingSoulSheet = false
    @State private var pendingOpenSoulAfterProposeDismiss = false
    @State private var showHistory = false
    @State private var banner: FeedbackBannerState?
    @State private var busyRuleActions: [String: RuleActionKind] = [:]
    @State private var pendingRevokeRule: IOSProceduralRule?
    @State private var copiedRuleId: String?
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        authorityOverviewCard
                        if let banner {
                            feedbackBanner(banner)
                        }
                        proposedSection
                        activeSection
                        historySection
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await syncFromGateway(surfaceError: true)
        }
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
        }
        .confirmationDialog(
            revokeDialogTitle,
            isPresented: Binding(
                get: { pendingRevokeRule != nil },
                set: { if !$0 { pendingRevokeRule = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRevokeRule
        ) { rule in
            Button(rule.status == .proposed ? L("确认忽略并撤销") : L("确认撤销"), role: .destructive) {
                pendingRevokeRule = nil
                revokeRule(rule)
            }
            Button(L("取消"), role: .cancel) {
                pendingRevokeRule = nil
            }
        } message: { rule in
            Text(verbatim: rule.status == .proposed
                 ? L("忽略后该规则将被标记为已撤销，不会参与注入。")
                 : L("撤销后下一轮起将永久停止注入，无法恢复为生效中；如仅想暂时停用，可选择「归档」。"))
        }
        .sheet(isPresented: $showingProposeSheet, onDismiss: {
            if pendingOpenSoulAfterProposeDismiss {
                pendingOpenSoulAfterProposeDismiss = false
                showingSoulSheet = true
            }
        }) {
            ProceduralRuleProposeSheet(
                store: store,
                syncClient: gatewayStore.client,
                onProposed: { rule, deduplicated in
                    banner = FeedbackBannerState(
                        style: .success,
                        message: deduplicated
                            ? L("已存在相同的规则卡，可在「待确认」或「生效中」查看：") + rule.title
                            : L("已创建待确认规则卡，需你点击「确认生效」后才参与注入。")
                    )
                },
                onRedirectToSoul: { message in
                    banner = FeedbackBannerState(style: .redirectToSoul, message: message)
                },
                onRejected: { code, message in
                    banner = FeedbackBannerState(
                        style: code == "risk_table_immutable" ? .riskImmutable : .warning,
                        message: message
                    )
                },
                onOpenSoul: {
                    pendingOpenSoulAfterProposeDismiss = true
                    showingProposeSheet = false
                }
            )
        }
        .sheet(isPresented: $showingSoulSheet) {
            AgentEmbodimentHomeSheet(sharedSettings: sharedSettings)
        }
    }

    private var revokeDialogTitle: String {
        guard let rule = pendingRevokeRule else { return L("撤销规则卡？") }
        return rule.status == .proposed
            ? L("忽略并撤销待确认规则「\(rule.title)」？")
            : L("撤销规则卡「\(rule.title)」？")
    }

    // MARK: - Header

    private var header: some View {
        let hasSyncButton = gatewayStore.client != nil
        let balancedSideWidth: CGFloat? = dynamicTypeSize.isAccessibilitySize ? nil : (hasSyncButton ? 94 : 44)
        return HStack(spacing: 8) {
            HStack(spacing: 0) {
                AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回", size: 44, symbolSize: 20) {
                    dismiss()
                }
                Spacer(minLength: 0)
            }
            .frame(width: balancedSideWidth)

            Text(verbatim: L("执行规则卡"))
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                if hasSyncButton {
                    Button {
                        Task { await syncFromGateway(surfaceError: true) }
                    } label: {
                        Group {
                            if store.isSyncing {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(AmberTheme.accent)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AmberTheme.accent)
                    .disabled(store.isSyncing)
                    .accessibilityLabel(Text(verbatim: L("同步云端规则卡")))
                }
                Button {
                    showingProposeSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AmberTheme.accent)
                .accessibilityLabel(Text(verbatim: L("提议新规则卡")))
            }
            .frame(width: balancedSideWidth, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    // MARK: - Authority Overview

    private var authorityOverviewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .accessibilityHidden(true)
                Text(verbatim: L("四层上下文权威顺序"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
            }
            Text(verbatim: L("系统静态风险表（L1–L3，不可绕过）> 已确认规则 > 形象人设（C-SOUL-V1）> 对话记忆 / Episode"))
                .font(.footnote.weight(.medium))
                .foregroundStyle(AmberTheme.foreground2)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: L("新规则须经你显式确认后才生效；归档或撤销后下一轮立即停止注入。"))
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                .strokeBorder(AmberTheme.borderSoft, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func feedbackBanner(_ state: FeedbackBannerState) -> some View {
        let accentColor: Color
        let iconName: String
        let title: String?
        let fillTint: Color
        switch state.style {
        case .success:
            accentColor = MacDelegationSemanticInk.success
            iconName = "checkmark.circle.fill"
            title = nil
            fillTint = AmberTheme.surface
        case .warning:
            accentColor = MacDelegationSemanticInk.warning
            iconName = "exclamationmark.triangle.fill"
            title = nil
            fillTint = AmberTheme.surface
        case .riskImmutable:
            accentColor = MacDelegationSemanticInk.danger
            iconName = "shield.slash.fill"
            title = L("静态风险表不可绕过（L1–L3）")
            fillTint = MacDelegationSemanticInk.danger.opacity(colorScheme == .dark ? 0.14 : 0.07)
        case .redirectToSoul:
            accentColor = AmberTheme.accent
            iconName = "person.crop.circle.badge.exclamationmark"
            title = L("请前往「形象人设」编辑")
            fillTint = AmberTheme.surface
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accentColor)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    if let title {
                        Text(verbatim: title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(state.style == .riskImmutable ? accentColor : AmberTheme.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(verbatim: state.message)
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    banner = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.muted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: L("关闭提示")))
            }
            if state.style == .redirectToSoul {
                Button {
                    showingSoulSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle")
                            .font(.subheadline.weight(.semibold))
                        Text(verbatim: L("前往「形象人设」编辑"))
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(AmberTheme.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(AmberTheme.accentTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 10)
        .background(fillTint, in: RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                .strokeBorder(accentColor.opacity(state.style == .riskImmutable ? 0.55 : 0.40), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Proposed Section

    private var proposedSection: some View {
        let items = store.proposedRules
        return VStack(spacing: 0) {
            AmberSectionLabel(verbatim: L("待确认规则卡（\(items.count)）"))
            if items.isEmpty {
                AmberFormGroup {
                    emptyRow(text: L("暂无待确认规则卡。可点击右上角「+」提议一条新执行规则。"))
                }
            } else {
                AmberFormGroup {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, rule in
                        proposedRuleRow(rule)
                        if idx < items.count - 1 {
                            Divider().overlay(AmberTheme.borderSoft).padding(.leading, 16)
                        }
                    }
                }
            }
        }
    }

    private func proposedRuleRow(_ rule: IOSProceduralRule) -> some View {
        let activeAction = busyRuleActions[rule.id]
        let isBusy = activeAction != nil
        return VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: rule.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            ruleMetadataBar(rule: rule)

            ruleInstructionText(rule)

            ruleActionContainer {
                Button {
                    performRuleAction(rule.id, kind: .confirm) {
                        _ = try await store.confirm(id: rule.id, syncClient: gatewayStore.client)
                        banner = FeedbackBannerState(
                            style: .success,
                            message: L("已确认生效：") + rule.title
                        )
                    }
                } label: {
                    HStack(spacing: 6) {
                        if activeAction == .confirm {
                            ProgressView()
                                .controlSize(.small)
                                .tint(AmberTheme.accentInk)
                        }
                        Text(verbatim: activeAction == .confirm ? L("确认中…") : L("确认生效"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AmberTheme.accentInk)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 12)
                    .background(AmberTheme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .opacity(isBusy && activeAction != .confirm ? 0.55 : 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                Button {
                    pendingRevokeRule = rule
                } label: {
                    HStack(spacing: 6) {
                        if activeAction == .revoke {
                            ProgressView()
                                .controlSize(.small)
                                .tint(AmberTheme.foreground)
                        }
                        Text(verbatim: activeAction == .revoke ? L("处理中…") : L("忽略"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                    }
                    .frame(minWidth: 84, maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 44)
                    .padding(.horizontal, 14)
                    .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(AmberTheme.borderSoft, lineWidth: 0.5)
                    )
                    .opacity(isBusy && activeAction != .revoke ? 0.55 : 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
        }
        .padding(16)
    }

    // MARK: - Active Section

    private var activeSection: some View {
        let items = store.activeRules
        return VStack(spacing: 0) {
            AmberSectionLabel(verbatim: L("已生效规则卡（\(items.count)）"))
            if items.isEmpty {
                AmberFormGroup {
                    emptyRow(text: L("暂无已生效规则卡。规则经你确认后才会参与上下文注入。"))
                }
            } else {
                AmberFormGroup {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, rule in
                        activeRuleRow(rule)
                        if idx < items.count - 1 {
                            Divider().overlay(AmberTheme.borderSoft).padding(.leading, 16)
                        }
                    }
                }
            }
        }
    }

    private func activeRuleRow(_ rule: IOSProceduralRule) -> some View {
        let activeAction = busyRuleActions[rule.id]
        let isBusy = activeAction != nil
        let titleLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return VStack(alignment: .leading, spacing: 10) {
            titleLayout {
                Text(verbatim: rule.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                hitCountBadge(rule.hitCount)
            }

            ruleMetadataBar(rule: rule)

            ruleInstructionText(rule)

            ruleActionContainer {
                Button {
                    performRuleAction(rule.id, kind: .archive) {
                        _ = try await store.archive(id: rule.id, syncClient: gatewayStore.client)
                        banner = FeedbackBannerState(
                            style: .success,
                            message: L("已归档，下一轮停止注入：") + rule.title
                        )
                    }
                } label: {
                    HStack(spacing: 6) {
                        if activeAction == .archive {
                            ProgressView()
                                .controlSize(.small)
                                .tint(AmberTheme.foreground)
                        }
                        Text(verbatim: activeAction == .archive ? L("归档中…") : L("归档"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AmberTheme.foreground)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 14)
                    .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(AmberTheme.borderSoft, lineWidth: 0.5)
                    )
                    .opacity(isBusy && activeAction != .archive ? 0.55 : 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                Button {
                    pendingRevokeRule = rule
                } label: {
                    HStack(spacing: 6) {
                        if activeAction == .revoke {
                            ProgressView()
                                .controlSize(.small)
                                .tint(MacDelegationSemanticInk.danger)
                        }
                        Text(verbatim: activeAction == .revoke ? L("撤销中…") : L("撤销"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MacDelegationSemanticInk.danger)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 14)
                    .background(
                        MacDelegationSemanticInk.danger.opacity(colorScheme == .dark ? 0.16 : 0.10),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(MacDelegationSemanticInk.danger.opacity(0.28), lineWidth: 0.75)
                    )
                    .opacity(isBusy && activeAction != .revoke ? 0.55 : 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
        }
        .padding(16)
    }

    // MARK: - History Section

    @ViewBuilder
    private var historySection: some View {
        let items = store.archivedOrRevokedRules
        if !items.isEmpty {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        showHistory.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(verbatim: L("已归档 / 已撤销（\(items.count)）"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AmberTheme.muted)
                            .monospacedDigit()
                        Spacer(minLength: 8)
                        Image(systemName: showHistory ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AmberTheme.muted)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
                .accessibilityHint(Text(verbatim: showHistory ? L("双击收起历史规则卡") : L("双击展开历史规则卡")))

                if showHistory {
                    AmberFormGroup {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, rule in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(verbatim: rule.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AmberTheme.foreground)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    statusPill(rule.status)
                                }
                                ruleMetadataBar(rule: rule)
                                ruleInstructionText(rule, font: .footnote)
                            }
                            .padding(16)
                            if idx < items.count - 1 {
                                Divider().overlay(AmberTheme.borderSoft).padding(.leading, 16)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Shared Row Components

    private func ruleMetadataBar(rule: IOSProceduralRule) -> some View {
        HStack(spacing: 8) {
            scopeBadge(rule.scope)
            if rule.status != .active && rule.hitCount > 0 {
                Text(verbatim: L("曾命中 \(rule.hitCount) 次"))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 4)
            copyRuleButton(rule)
        }
    }

    private func ruleInstructionText(_ rule: IOSProceduralRule, font: Font = .subheadline) -> some View {
        Text(verbatim: rule.instruction)
            .font(font)
            .foregroundStyle(AmberTheme.foreground2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .contextMenu {
                Button {
                    copyRule(rule)
                } label: {
                    Label(L("复制规则内容"), systemImage: "doc.on.doc")
                }
            }
    }

    private func copyRuleButton(_ rule: IOSProceduralRule) -> some View {
        let isCopied = copiedRuleId == rule.id
        return Button {
            copyRule(rule)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                Text(verbatim: isCopied ? L("已复制") : L("复制"))
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(isCopied ? MacDelegationSemanticInk.success : AmberTheme.muted)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(Text(verbatim: isCopied ? L("已复制规则内容") : L("复制规则内容")))
    }

    @ViewBuilder
    private func ruleActionContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                content()
            }
        } else {
            HStack(spacing: 10) {
                content()
            }
        }
    }

    private func emptyRow(text: String) -> some View {
        Text(verbatim: text)
            .font(.footnote)
            .foregroundStyle(AmberTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
    }

    private func scopeBadge(_ scope: String) -> some View {
        let isGlobal = scope == IOSProceduralRule.scopeGlobal
        let label = isGlobal ? L("全局") : scope
        return Text(verbatim: label)
            .font(.caption.weight(.medium))
            .foregroundStyle(AmberTheme.foreground)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(AmberTheme.surface2, in: Capsule())
            .overlay(Capsule().strokeBorder(AmberTheme.borderSoft, lineWidth: 0.5))
            .accessibilityLabel(Text(verbatim: L("作用域：") + label))
    }

    private func hitCountBadge(_ count: Int) -> some View {
        Text(verbatim: L("命中 \(count) 次"))
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(MacDelegationSemanticInk.success)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                MacDelegationSemanticInk.success.opacity(colorScheme == .dark ? 0.18 : 0.11),
                in: Capsule()
            )
            .fixedSize(horizontal: true, vertical: false)
    }

    private func statusPill(_ status: IOSProceduralRuleStatus) -> some View {
        let tint: Color = status == .revoked ? MacDelegationSemanticInk.danger : AmberTheme.muted
        return Text(verbatim: status.displayTitle)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                status == .revoked
                    ? MacDelegationSemanticInk.danger.opacity(colorScheme == .dark ? 0.16 : 0.09)
                    : AmberTheme.surface2,
                in: Capsule()
            )
            .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Actions

    private func copyRule(_ rule: IOSProceduralRule) {
        UIPasteboard.general.string = rule.instruction
        copiedRuleId = rule.id
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            if copiedRuleId == rule.id {
                copiedRuleId = nil
            }
        }
    }

    private func syncFromGateway(surfaceError: Bool) async {
        guard let client = gatewayStore.client else { return }
        await store.syncFromGateway(syncClient: client)
        if surfaceError, let syncError = store.lastSyncError, !syncError.isEmpty {
            banner = FeedbackBannerState(style: .warning, message: syncError)
        }
    }

    private func revokeRule(_ rule: IOSProceduralRule) {
        performRuleAction(rule.id, kind: .revoke) {
            _ = try await store.revoke(id: rule.id, syncClient: gatewayStore.client)
            banner = FeedbackBannerState(
                style: .success,
                message: rule.status == .proposed
                    ? L("已忽略并撤销：") + rule.title
                    : L("已撤销，下一轮 100% 停止注入：") + rule.title
            )
        }
    }

    private func performRuleAction(
        _ id: String,
        kind: RuleActionKind,
        action: @escaping @MainActor () async throws -> Void
    ) {
        guard busyRuleActions[id] == nil else { return }
        busyRuleActions[id] = kind
        Task { @MainActor in
            defer { busyRuleActions.removeValue(forKey: id) }
            do {
                try await action()
            } catch {
                banner = FeedbackBannerState(style: .warning, message: error.localizedDescription)
            }
        }
    }
}

// MARK: - Propose Rule Sheet

private struct ProceduralRuleProposeSheet: View {
    let store: IOSProceduralRuleStore
    let syncClient: (any IOSProceduralRulesSyncing)?
    let onProposed: (IOSProceduralRule, Bool) -> Void
    let onRedirectToSoul: (String) -> Void
    let onRejected: (String, String) -> Void
    let onOpenSoul: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var title = ""
    @State private var instruction = ""
    @State private var scope = IOSProceduralRule.scopeGlobal
    @State private var isSubmitting = false
    @State private var inlineError: (code: String, message: String)?
    @State private var redirectToSoulMessage: String?

    private var isSubmitDisabled: Bool {
        isSubmitting || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmberTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        fieldSection(title: L("规则标题（可选）")) {
                            TextField(L("例如：提交代码前先跑单测"), text: $title)
                                .textFieldStyle(.plain)
                                .foregroundStyle(AmberTheme.foreground)
                                .padding(12)
                                .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(AmberTheme.borderSoft, lineWidth: 0.75)
                                )
                        }

                        fieldSection(title: L("执行规则内容")) {
                            ZStack(alignment: .topLeading) {
                                if instruction.isEmpty {
                                    Text(verbatim: L("输入希望 Agent 在后续轮次遵守的具体执行规则…"))
                                        .font(.body)
                                        .foregroundStyle(AmberTheme.muted)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 16)
                                        .allowsHitTesting(false)
                                }
                                TextEditor(text: $instruction)
                                    .scrollContentBackground(.hidden)
                                    .foregroundStyle(AmberTheme.foreground)
                                    .frame(minHeight: 112)
                                    .padding(10)
                            }
                            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(AmberTheme.borderSoft, lineWidth: 0.75)
                            )
                        }

                        fieldSection(title: L("作用域")) {
                            TextField("global", text: $scope)
                                .textFieldStyle(.plain)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .foregroundStyle(AmberTheme.foreground)
                                .padding(12)
                                .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(AmberTheme.borderSoft, lineWidth: 0.75)
                                )
                            Text(verbatim: L("填 global 可用于共享记忆的会话。只想用于一个会话时，填写该会话的 ID。"))
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let redirectToSoulMessage {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AmberTheme.accent)
                                        .padding(.top, 1)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(verbatim: L("该内容属于形象人设（C-SOUL-V1）"))
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(AmberTheme.foreground)
                                        Text(verbatim: redirectToSoulMessage)
                                            .font(.footnote)
                                            .foregroundStyle(AmberTheme.foreground2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Button {
                                    onOpenSoul()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "person.crop.circle")
                                            .font(.subheadline.weight(.semibold))
                                        Text(verbatim: L("前往「形象人设 (C-SOUL-V1)」"))
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    .foregroundStyle(AmberTheme.accent)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(AmberTheme.accentTint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(14)
                            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(AmberTheme.accent.opacity(0.42), lineWidth: 1)
                            )
                        } else if let inlineError {
                            let isRiskImmutable = inlineError.code == "risk_table_immutable"
                            let inkColor = isRiskImmutable ? MacDelegationSemanticInk.danger : MacDelegationSemanticInk.warning
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: isRiskImmutable ? "shield.slash.fill" : "exclamationmark.triangle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(inkColor)
                                    .padding(.top, 1)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    if isRiskImmutable {
                                        Text(verbatim: L("静态风险表不可绕过（L1–L3）"))
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(inkColor)
                                    }
                                    Text(verbatim: inlineError.message)
                                        .font(.footnote)
                                        .foregroundStyle(isRiskImmutable ? AmberTheme.foreground : inkColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(14)
                            .background(
                                isRiskImmutable
                                    ? MacDelegationSemanticInk.danger.opacity(colorScheme == .dark ? 0.16 : 0.08)
                                    : AmberTheme.surface,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(inkColor.opacity(isRiskImmutable ? 0.55 : 0.42), lineWidth: 1)
                            )
                        }

                        Button {
                            submit()
                        } label: {
                            HStack(spacing: 8) {
                                if isSubmitting {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(AmberTheme.accentInk)
                                }
                                Text(verbatim: isSubmitting ? L("提交中…") : L("提交为待确认规则"))
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(AmberTheme.accentInk)
                            }
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(AmberTheme.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .opacity(isSubmitDisabled ? 0.45 : 1)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitDisabled)
                    }
                    .padding(16)
                }
            }
            .navigationTitle(Text(verbatim: L("提议执行规则")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(isSubmitting)
                }
            }
        }
    }

    private func fieldSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)
            content()
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        inlineError = nil
        redirectToSoulMessage = nil
        Task { @MainActor in
            defer { isSubmitting = false }
            let outcome = await store.propose(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title,
                instruction: instruction,
                scope: scope,
                syncClient: syncClient
            )
            switch outcome {
            case .proposed(let rule, let deduplicated):
                onProposed(rule, deduplicated)
                dismiss()
            case .redirectToSoul(_, let message):
                redirectToSoulMessage = message
                onRedirectToSoul(message)
            case .rejected(let code, let message):
                inlineError = (code: code, message: message)
                onRejected(code, message)
            }
        }
    }
}

private func L(_ key: String) -> String {
    IOSAppLocalization.string(key, defaultValue: key)
}
