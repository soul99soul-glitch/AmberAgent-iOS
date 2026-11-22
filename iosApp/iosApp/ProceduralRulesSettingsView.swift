import SwiftUI

/// Restrained management surface for "correction -> procedural rule card" memory (Stage 3-D).
/// Follows Arquiel Design 2.0: >=44pt hit targets, >=4.5:1 light/dark contrast, zero disk IO in `body`.
struct ProceduralRulesSettingsView: View {
    let sharedSettings: IOSSharedSettingsStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var store = IOSProceduralRuleStore.shared
    @State private var gatewayStore = MacGatewayStore.shared

    @State private var showingProposeSheet = false
    @State private var showingSoulSheet = false
    @State private var showHistory = false
    @State private var bannerMessage: String?
    @State private var bannerIsWarning = false
    @State private var bannerRedirectToSoul = false
    @State private var busyRuleIds: Set<String> = []

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        authorityOverviewCard
                        if let bannerMessage {
                            feedbackBanner(
                                message: bannerMessage,
                                isWarning: bannerIsWarning,
                                showsSoulButton: bannerRedirectToSoul
                            )
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
            if let client = gatewayStore.client {
                await store.syncFromGateway(syncClient: client)
            }
        }
        .sheet(isPresented: $showingProposeSheet) {
            ProceduralRuleProposeSheet(
                store: store,
                syncClient: gatewayStore.client,
                onProposed: { rule, deduplicated in
                    bannerIsWarning = false
                    bannerRedirectToSoul = false
                    bannerMessage = deduplicated
                        ? L("已存在相同的规则卡，可在「待确认」或「生效中」查看：") + rule.title
                        : L("已创建待确认规则卡，需你点击「确认生效」后才参与注入。")
                },
                onRedirectToSoul: { message in
                    bannerIsWarning = true
                    bannerRedirectToSoul = true
                    bannerMessage = message
                },
                onRejected: { message in
                    bannerIsWarning = true
                    bannerRedirectToSoul = false
                    bannerMessage = message
                },
                onOpenSoul: {
                    showingProposeSheet = false
                    showingSoulSheet = true
                }
            )
        }
        .sheet(isPresented: $showingSoulSheet) {
            AgentEmbodimentHomeSheet(sharedSettings: sharedSettings)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回", size: 44, symbolSize: 20) {
                dismiss()
            }
            Spacer(minLength: 0)
            Text(verbatim: L("执行规则卡"))
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if gatewayStore.client != nil {
                    Button {
                        Task { await store.syncFromGateway(syncClient: gatewayStore.client) }
                    } label: {
                        Group {
                            if store.isSyncing {
                                ProgressView()
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
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    // MARK: - Authority Overview

    private var authorityOverviewCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: L("四层上下文权威顺序"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)
            Text(verbatim: L("静态风险表（L1–L3）> 已生效规则卡 > 形象人设（C-SOUL-V1）> 记忆召回"))
                .font(.footnote)
                .foregroundStyle(AmberTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: L("新规则必须由你显式确认后生效，归档或撤销后下一轮立即停止注入。"))
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AmberTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AmberTheme.borderSoft, lineWidth: 0.75)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func feedbackBanner(message: String, isWarning: Bool, showsSoulButton: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isWarning ? warningTextColor : positiveTextColor)
                    .padding(.top, 1)
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    bannerMessage = nil
                    bannerRedirectToSoul = false
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
            if showsSoulButton {
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
                    .background(AmberTheme.accent.opacity(colorScheme == .dark ? 0.18 : 0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(AmberTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder((isWarning ? warningTextColor : positiveTextColor).opacity(0.45), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Proposed Section

    private var proposedSection: some View {
        let items = store.proposedRules
        return VStack(spacing: 0) {
            AmberSectionLabel(text: "待确认规则卡（\(items.count)）")
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
        let isBusy = busyRuleIds.contains(rule.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: rule.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                scopeBadge(rule.scope)
            }
            Text(verbatim: rule.instruction)
                .font(.subheadline)
                .foregroundStyle(AmberTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    performRuleAction(rule.id) {
                        _ = try await store.confirm(id: rule.id, syncClient: gatewayStore.client)
                        bannerIsWarning = false
                        bannerRedirectToSoul = false
                        bannerMessage = L("已确认生效：") + rule.title
                    }
                } label: {
                    Text(verbatim: L("确认生效"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(confirmButtonForeground)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(AmberTheme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                Button {
                    performRuleAction(rule.id) {
                        _ = try await store.revoke(id: rule.id, syncClient: gatewayStore.client)
                        bannerIsWarning = false
                        bannerRedirectToSoul = false
                        bannerMessage = L("已忽略并撤销：") + rule.title
                    }
                } label: {
                    Text(verbatim: L("忽略"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .frame(minWidth: 84, minHeight: 44)
                        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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
            AmberSectionLabel(text: "已生效规则卡（\(items.count)）")
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
        let isBusy = busyRuleIds.contains(rule.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: rule.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                hitCountBadge(rule.hitCount)
            }
            Text(verbatim: rule.instruction)
                .font(.subheadline)
                .foregroundStyle(AmberTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                scopeBadge(rule.scope)
                Spacer(minLength: 0)
                Button {
                    performRuleAction(rule.id) {
                        _ = try await store.archive(id: rule.id, syncClient: gatewayStore.client)
                        bannerIsWarning = false
                        bannerRedirectToSoul = false
                        bannerMessage = L("已归档，下一轮停止注入：") + rule.title
                    }
                } label: {
                    Text(verbatim: L("归档"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AmberTheme.foreground)
                        .padding(.horizontal, 14)
                        .frame(minWidth: 68, minHeight: 44)
                        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                Button {
                    performRuleAction(rule.id) {
                        _ = try await store.revoke(id: rule.id, syncClient: gatewayStore.client)
                        bannerIsWarning = false
                        bannerRedirectToSoul = false
                        bannerMessage = L("已撤销，下一轮 100% 停止注入：") + rule.title
                    }
                } label: {
                    Text(verbatim: L("撤销"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(destructiveTextColor)
                        .padding(.horizontal, 14)
                        .frame(minWidth: 68, minHeight: 44)
                        .background(destructiveTextColor.opacity(colorScheme == .dark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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
                    showHistory.toggle()
                } label: {
                    HStack {
                        Text(verbatim: L("已归档 / 已撤销（\(items.count)）"))
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(AmberTheme.muted)
                        Spacer()
                        Image(systemName: showHistory ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AmberTheme.muted)
                    }
                    .padding(.horizontal, 24)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 12)

                if showHistory {
                    AmberFormGroup {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, rule in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(verbatim: rule.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(AmberTheme.foreground)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(verbatim: rule.status.displayTitle)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(AmberTheme.muted)
                                }
                                Text(verbatim: rule.instruction)
                                    .font(.footnote)
                                    .foregroundStyle(AmberTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(14)
                            if idx < items.count - 1 {
                                Divider().overlay(AmberTheme.borderSoft).padding(.leading, 14)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func emptyRow(text: String) -> some View {
        Text(verbatim: text)
            .font(.footnote)
            .foregroundStyle(AmberTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
    }

    private func scopeBadge(_ scope: String) -> some View {
        let label = scope == IOSProceduralRule.scopeGlobal ? L("全局") : scope
        return Text(verbatim: label)
            .font(.caption.weight(.medium))
            .foregroundStyle(AmberTheme.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AmberTheme.surface2, in: Capsule())
    }

    private func hitCountBadge(_ count: Int) -> some View {
        Text(verbatim: L("命中 \(count) 次"))
            .font(.caption.weight(.semibold))
            .foregroundStyle(positiveTextColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(positiveTextColor.opacity(colorScheme == .dark ? 0.18 : 0.12), in: Capsule())
    }

    private var confirmButtonForeground: Color {
        AmberTheme.accentInk
    }

    private var positiveTextColor: Color {
        colorScheme == .dark ? Color(red: 0.45, green: 0.88, blue: 0.58) : Color(red: 0.08, green: 0.45, blue: 0.22)
    }

    private var warningTextColor: Color {
        colorScheme == .dark ? Color(red: 0.98, green: 0.74, blue: 0.34) : Color(red: 0.62, green: 0.33, blue: 0.02)
    }

    private var destructiveTextColor: Color {
        colorScheme == .dark ? Color(red: 1.0, green: 0.50, blue: 0.48) : Color(red: 0.72, green: 0.12, blue: 0.14)
    }

    private func performRuleAction(_ id: String, action: @escaping @MainActor () async throws -> Void) {
        guard !busyRuleIds.contains(id) else { return }
        busyRuleIds.insert(id)
        Task { @MainActor in
            defer { busyRuleIds.remove(id) }
            do {
                try await action()
            } catch {
                bannerIsWarning = true
                bannerRedirectToSoul = false
                bannerMessage = error.localizedDescription
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
    let onRejected: (String) -> Void
    let onOpenSoul: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var title = ""
    @State private var instruction = ""
    @State private var scope = IOSProceduralRule.scopeGlobal
    @State private var isSubmitting = false
    @State private var inlineError: String?
    @State private var redirectToSoulMessage: String?

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
                                .background(AmberTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        fieldSection(title: L("执行规则内容")) {
                            TextEditor(text: $instruction)
                                .scrollContentBackground(.hidden)
                                .foregroundStyle(AmberTheme.foreground)
                                .frame(minHeight: 112)
                                .padding(10)
                                .background(AmberTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        fieldSection(title: L("作用域")) {
                            TextField("global", text: $scope)
                                .textFieldStyle(.plain)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .foregroundStyle(AmberTheme.foreground)
                                .padding(12)
                                .background(AmberTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Text(verbatim: L("填 global 对所有会话生效，也可填具体项目名或会话 ID。"))
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                        }

                        if let redirectToSoulMessage {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(verbatim: redirectToSoulMessage)
                                    .font(.footnote)
                                    .foregroundStyle(AmberTheme.foreground)
                                Button {
                                    onOpenSoul()
                                } label: {
                                    Text(verbatim: L("前往「形象人设 (C-SOUL-V1)」"))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AmberTheme.accent)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .background(AmberTheme.accent.opacity(colorScheme == .dark ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                            .background(AmberTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else if let inlineError {
                            Text(verbatim: inlineError)
                                .font(.footnote)
                                .foregroundStyle(colorScheme == .dark ? Color(red: 1.0, green: 0.56, blue: 0.50) : Color(red: 0.72, green: 0.12, blue: 0.14))
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AmberTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        Button {
                            submit()
                        } label: {
                            Group {
                                if isSubmitting {
                                    ProgressView().tint(.white)
                                } else {
                                    Text(verbatim: L("提交为待确认规则"))
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(AmberTheme.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            case .rejected(_, let message):
                inlineError = message
                onRejected(message)
            }
        }
    }
}

private func L(_ key: String) -> String {
    IOSAppLocalization.string(key, defaultValue: key)
}
