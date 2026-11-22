import SwiftUI
import UIKit

// MARK: - Stage 2-B: Adaptive Semantic Ink (WCAG AA >= 4.5:1 across light & dark paper surfaces)

enum MacDelegationSemanticInk {
    /// Vermilion red tuned for >= 5.2:1 contrast on both light paper tint and dark surface tint.
    static let danger = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.478, blue: 0.420, alpha: 1.0)     // #FF7A6B
            : UIColor(red: 0.651, green: 0.141, blue: 0.090, alpha: 1.0)   // #A62417
    })

    /// Warm amber ink tuned for >= 4.7:1 contrast on light paper surfaces and >= 5.7:1 on dark.
    static let warning = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.961, green: 0.690, blue: 0.255, alpha: 1.0)   // #F5B041
            : UIColor(red: 0.604, green: 0.322, blue: 0.0, alpha: 1.0)     // #9A5200
    })

    /// Pine green ink tuned for >= 5.0:1 contrast on both light and dark diff/status surfaces.
    static let success = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.369, green: 0.816, blue: 0.604, alpha: 1.0)   // #5ED09A
            : UIColor(red: 0.114, green: 0.400, blue: 0.275, alpha: 1.0)   // #1D6646
    })
}

// MARK: - Stage 2-B: Half-Sheet Read-Only Diff Approval Card (Arquiel Design 2.0 Paper Surface)

/// Half-sheet read-only Diff approval card for L1/L2/L3 Mac approvals.
/// Strictly enforces the Mac-local redline: when `requiresLocalApproval` is true or remote approval
/// previously returned HTTP 403, the remote "接受" button is hidden/disabled and iOS clearly instructs
/// the user to approve on the Mac. Never offers inline text editing.
struct MacReadOnlyDiffApprovalSheet: View {
    let item: MacGatewayApprovalCardItem
    let store: MacGatewayStore
    var onRequestModification: ((MacGatewayApprovalCardItem) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isSubmitting = false
    @State private var localNotice: String? = nil

    private var isLocalApprovalRequired: Bool {
        item.requiresLocalApproval
            || store.requiresLocalApprovalOnly(sessionKey: item.sessionKey, toolCallId: item.toolCallId)
    }

    private var isBusy: Bool {
        isSubmitting || store.decidingCalls.contains(item.toolCallId)
    }

    private var diffLines: [ReadOnlyDiffLine] {
        guard let preview = item.effectivePreviewText else { return [] }
        return preview
            .components(separatedBy: .newlines)
            .prefix(240)
            .enumerated()
            .map { index, raw in
                ReadOnlyDiffLine(id: index, text: raw)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Divider().overlay(AmberTheme.borderSoft)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    summaryCard

                    if isLocalApprovalRequired {
                        macLocalRedlineBanner
                    }

                    if !diffLines.isEmpty {
                        readOnlyDiffCard
                    }

                    if let localNotice, !localNotice.isEmpty {
                        Text(verbatim: localNotice)
                            .font(.footnote)
                            .foregroundStyle(MacDelegationSemanticInk.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            Divider().overlay(AmberTheme.borderSoft)

            actionFooter
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 18)
        }
        .background(AmberTheme.background.ignoresSafeArea())
        .accessibilityIdentifier("mac.approval.halfSheetDiff")
    }

    private var headerSection: some View {
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: 8) {
            let metadataLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 8))

            metadataLayout {
                HStack(spacing: 6) {
                    Image(systemName: item.endpointRole.iconName)
                        .font(.caption.weight(.semibold))
                    Text(verbatim: item.targetDeviceName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(AmberTheme.foreground2)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(AmberTheme.surface, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(AmberTheme.borderSoft, lineWidth: 0.75)
                }

                Text(verbatim: item.riskTier.badgeText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(item.riskTier == .l3 ? MacDelegationSemanticInk.danger : AmberTheme.accent)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        (item.riskTier == .l3 ? AmberTheme.accentRed : AmberTheme.accent).opacity(0.13),
                        in: Capsule(style: .continuous)
                    )
                    .layoutPriority(1)
            }

            Spacer(minLength: 4)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted)
                    .frame(width: 30, height: 30)
                    .background(AmberTheme.surface, in: Circle())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, -7)
            .padding(.vertical, -7)
            .accessibilityLabel(macGatewayL("关闭审批预览"))
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: macGatewayL("变更摘要"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AmberTheme.muted)

            Text(verbatim: item.summary)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AmberTheme.muted)
                Text(verbatim: item.tool)
                    .font(.caption.monospaced())
                    .foregroundStyle(AmberTheme.foreground2)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.75)
        }
    }

    private var readOnlyDiffCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: macGatewayL("只读差异与正文预览"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted)
                Spacer()
                Text(verbatim: macGatewayL("只读"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AmberTheme.muted)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(diffLines) { line in
                        Text(verbatim: line.text.isEmpty ? " " : line.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(line.foregroundColor)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(line.backgroundColor)
                    }
                }
                .textSelection(.enabled)
                .frame(minWidth: 280, alignment: .leading)
                .padding(.vertical, 6)
            }
            .background(AmberTheme.surface2.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 0.6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.75)
        }
    }

    private var macLocalRedlineBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.desktopcomputer")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MacDelegationSemanticInk.danger)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: macGatewayL("此高危操作请在 Mac 上批准"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MacDelegationSemanticInk.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mac.approval.localOnlyWarning")

                Text(verbatim: macGatewayL("解锁手机不会扩大授权范围。你可以在手机端先查看差异、直接驳回，或点名补充修改要求。"))
                    .font(.caption)
                    .foregroundStyle(AmberTheme.foreground2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AmberTheme.accentRed.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(MacDelegationSemanticInk.danger.opacity(0.40), lineWidth: 0.9)
        }
    }

    private var actionFooter: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))

        return layout {
            Button {
                submitDecision(allow: false)
            } label: {
                Text(verbatim: macGatewayL("驳回"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MacDelegationSemanticInk.danger)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(AmberTheme.accentRed.opacity(0.11), in: Capsule(style: .continuous))
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityIdentifier("mac.approval.rejectButton")

            if let onRequestModification, item.workItemId != nil {
                Button {
                    dismiss()
                    onRequestModification(item)
                } label: {
                    Text(verbatim: macGatewayL("点名修改"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(AmberTheme.surface, in: Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(AmberTheme.border, lineWidth: 0.8)
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityIdentifier("mac.approval.modifyButton")
            }

            // Mac 本机红线：requiresLocalApproval == true 或 403 时隐藏远程「接受」按钮。
            if !isLocalApprovalRequired {
                Button {
                    submitDecision(allow: true)
                } label: {
                    Group {
                        if isBusy {
                            ProgressView().tint(AmberTheme.accentInk)
                        } else {
                            Text(verbatim: macGatewayL("接受"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AmberTheme.accentInk)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(AmberTheme.accent, in: Capsule(style: .continuous))
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityIdentifier("mac.approval.acceptButton")
            }
        }
    }

    private func submitDecision(allow: Bool) {
        isSubmitting = true
        localNotice = nil
        Task { @MainActor in
            let delivered = await store.decide(
                sessionKey: item.sessionKey,
                toolCallId: item.toolCallId,
                allow: allow,
                source: .foregroundApp,
                role: item.endpointRole
            )
            isSubmitting = false
            if delivered {
                dismiss()
            } else if !allow || !isLocalApprovalRequired {
                localNotice = store.notice?.text ?? macGatewayL("操作未完成，请稍后重试")
            }
        }
    }
}

private struct ReadOnlyDiffLine: Identifiable {
    let id: Int
    let text: String

    var foregroundColor: Color {
        if text.hasPrefix("+++") || text.hasPrefix("---") {
            return AmberTheme.muted
        }
        if text.hasPrefix("+") {
            return MacDelegationSemanticInk.success
        }
        if text.hasPrefix("-") {
            return MacDelegationSemanticInk.danger
        }
        if text.hasPrefix("@@") {
            return MacDelegationSemanticInk.warning
        }
        return AmberTheme.foreground2
    }

    var backgroundColor: Color {
        if text.hasPrefix("+++") || text.hasPrefix("---") {
            return .clear
        }
        if text.hasPrefix("+") {
            return AmberTheme.accentGreen.opacity(0.10)
        }
        if text.hasPrefix("-") {
            return AmberTheme.accentRed.opacity(0.10)
        }
        if text.hasPrefix("@@") {
            return AmberTheme.accentAmber.opacity(0.08)
        }
        return .clear
    }
}

// MARK: - Unified Timeline Mac Delegation Cards

struct UnifiedMacDelegationTimelineSection: View {
    let conversationId: String?
    private struct Projection: Equatable, Sendable {
        var runs: [MacDelegatedTimelineRun]
        var standalone: [MacGatewayApprovalCardItem]
    }
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var projection = Projection(runs: [], standalone: [])
    @State private var actionError: String?
    private let store = MacGatewayStore.shared
    let onFollowup: (String, MacGatewayEndpointRole) -> Void
    let onOpenApproval: (MacGatewayApprovalCardItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !projection.runs.isEmpty || !projection.standalone.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    cards.padding(.horizontal, ChatLayout.contentHorizontalInset)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 280 : 220)
                if let actionError {
                    Text(verbatim: actionError)
                        .font(.caption)
                        .foregroundStyle(MacDelegationSemanticInk.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, ChatLayout.contentHorizontalInset)
                        .padding(.top, 4)
                }
            }
        }
        .task(id: "\(conversationId ?? "")|\(locale.identifier)") {
            let updates = Observations { @MainActor in
                let approvals = store.allActiveApprovalCardItems(for: conversationId)
                let runs = store.allUnifiedDelegatedRuns(for: conversationId, approvals: approvals)
                let attached = Set(runs.compactMap { $0.pendingApproval?.id })
                return Projection(runs: runs, standalone: approvals.filter { !attached.contains($0.id) })
            }
            for await update in updates {
                guard !Task.isCancelled else { break }
                if projection != update { projection = update }
            }
        }
    }

    private func performAction(_ action: @escaping @MainActor () async throws -> Void) {
        actionError = nil
        Task { @MainActor in
            do { try await action() }
            catch { actionError = error.localizedDescription }
        }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(projection.runs) { run in
                let targetSlot = store.slot(for: run.endpointRole)
                UnifiedMacDelegationRunCard(
                    run: run,
                    onRecheckPending: {
                        performAction { try await targetSlot.recheckPendingMacSubmission(requestId: run.requestId, workItemId: run.workItemId).get() }
                    },
                    onCancelPending: {
                        performAction {
                            guard await targetSlot.cancelPendingMacSubmission(requestId: run.requestId, workItemId: run.workItemId) else {
                                throw MacGatewayError.server(macGatewayL("未能确认取消，请重新核对 \(run.endpointRole.displayName) 状态"))
                            }
                        }
                    },
                    onRecheckUnknown: {
                        if let id = run.workItemId { performAction { _ = try await targetSlot.recheckOutcomeUnknownCloudWorkItem(workItemId: id).get() } }
                    },
                    onRetryUnknown: {
                        if let id = run.workItemId { performAction { _ = try await targetSlot.retryOutcomeUnknownCloudWorkItem(workItemId: id).get() } }
                    },
                    onAbandonUnknown: {
                        if let id = run.workItemId { _ = targetSlot.abandonOutcomeUnknownCloudWorkItem(workItemId: id) }
                    },
                    onFollowup: {
                        if let id = run.workItemId { onFollowup(id, run.endpointRole) }
                    },
                    onStop: {
                        if let id = run.workItemId { performAction { _ = try await targetSlot.stopCloudWorkItem(workItemId: id).get() } }
                    },
                    onOpenApproval: {
                        if let approval = run.pendingApproval { onOpenApproval(approval) }
                    }
                )
            }

            ForEach(projection.standalone) { approval in
                MacPendingApprovalTimelineBanner(approval: approval) {
                    onOpenApproval(approval)
                }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .accessibilityIdentifier("chat.unifiedTimeline.macDelegations")
    }
}

private struct UnifiedMacDelegationRunCard: View {
    private enum PendingConfirmation: Equatable {
        case retryUnknown
        case abandonUnknown
        case cancelPending

        var title: String {
            switch self {
            case .retryUnknown: return macGatewayL("确认未执行后再重试？")
            case .abandonUnknown: return macGatewayL("确认放弃跟踪该任务？")
            case .cancelPending: return macGatewayL("确认显式取消该次派发？")
            }
        }

        var message: String {
            switch self {
            case .retryUnknown:
                return macGatewayL("若 Mac 端此前已实际执行，重试可能触发重复操作。建议先「重查状态」确认。")
            case .abandonUnknown:
                return macGatewayL("放弃后将不再自动跟踪本次回执，但不回滚 Mac 端已发生的变更。")
            case .cancelPending:
                return macGatewayL("将向 Mac 发起显式取消，不会回退到本机执行。")
            }
        }

        var confirmTitle: String {
            switch self {
            case .retryUnknown: return macGatewayL("确认未执行后重试")
            case .abandonUnknown: return macGatewayL("放弃跟踪")
            case .cancelPending: return macGatewayL("显式取消")
            }
        }
    }

    let run: MacDelegatedTimelineRun
    let onRecheckPending: () -> Void
    let onCancelPending: () -> Void
    let onRecheckUnknown: () -> Void
    let onRetryUnknown: () -> Void
    let onAbandonUnknown: () -> Void
    let onFollowup: () -> Void
    let onStop: () -> Void
    let onOpenApproval: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var pendingConfirmation: PendingConfirmation? = nil

    private var badgeTint: Color {
        switch run.badge {
        case .running, .followup: return AmberTheme.accent
        case .awaitingMacApproval, .outcomeUnknown: return MacDelegationSemanticInk.warning
        case .completed: return MacDelegationSemanticInk.success
        case .failed: return MacDelegationSemanticInk.danger
        case .cancelled, .retried, .trackingEnded: return AmberTheme.muted
        }
    }

    private var badgeFillTint: Color {
        switch run.badge {
        case .running, .followup: return AmberTheme.accent
        case .awaitingMacApproval, .outcomeUnknown: return AmberTheme.accentAmber
        case .completed: return AmberTheme.accentGreen
        case .failed: return AmberTheme.accentRed
        case .cancelled, .retried, .trackingEnded: return AmberTheme.muted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: run.endpointRole.iconName)
                        .font(.caption2.weight(.semibold))
                    Text(verbatim: "[\(run.badge.label(for: run.endpointRole))]")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                }
                .foregroundStyle(badgeTint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(badgeFillTint.opacity(0.12), in: Capsule(style: .continuous))
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
                .accessibilityIdentifier("chat.macRun.badge.\(run.endpointRole.rawValue).\(run.badge.rawValue)")

                if run.isBusy {
                    ProgressView().controlSize(.mini)
                }

                Spacer(minLength: 4)

                if run.canStop, run.workItemId != nil, !run.isReceiptUnconfirmed {
                    Button(action: onStop) {
                        Text("停止")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(MacDelegationSemanticInk.danger)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 28)
                            .background(AmberTheme.accentRed.opacity(0.11), in: Capsule(style: .continuous))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, -8)
                    .padding(.trailing, -4)
                }
            }

            Text(verbatim: run.promptText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 5 : 3)
                .fixedSize(horizontal: false, vertical: true)

            if let resultText = run.resultText, !resultText.isEmpty, run.badge == .completed {
                Text(verbatim: resultText)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: run.statusLine)
                    .font(.caption)
                    .foregroundStyle(run.isOutcomeUnknown || run.isReceiptUnconfirmed ? MacDelegationSemanticInk.warning : AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !run.sourceAnnotations.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(run.sourceAnnotations, id: \.self) { source in
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                    .font(.caption2)
                                Text(verbatim: source)
                                    .font(.caption2.monospaced())
                                    .lineLimit(1)
                            }
                            .foregroundStyle(AmberTheme.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AmberTheme.surface2, in: Capsule(style: .continuous))
                        }
                    }
                }
            }

            actionBar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.75)
        }
        .confirmationDialog(
            pendingConfirmation?.title ?? "",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let confirmation = pendingConfirmation {
                Button(confirmation.confirmTitle, role: .destructive) {
                    pendingConfirmation = nil
                    switch confirmation {
                    case .retryUnknown: onRetryUnknown()
                    case .abandonUnknown: onAbandonUnknown()
                    case .cancelPending: onCancelPending()
                    }
                }
                Button(macGatewayL("取消"), role: .cancel) {
                    pendingConfirmation = nil
                }
            }
        } message: {
            if let confirmation = pendingConfirmation {
                Text(verbatim: confirmation.message)
            }
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        if run.isOutcomeUnknown, run.workItemId != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    compactPill("重查状态", tint: AmberTheme.accent, isProminent: true, action: onRecheckUnknown)
                    Spacer(minLength: 6)
                    compactPill("确认未执行后重试", tint: MacDelegationSemanticInk.warning, fillTint: AmberTheme.accentAmber) {
                        pendingConfirmation = .retryUnknown
                    }
                    compactPill("放弃", tint: AmberTheme.muted) {
                        pendingConfirmation = .abandonUnknown
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    compactPill("重查状态", tint: AmberTheme.accent, isProminent: true, action: onRecheckUnknown)
                    HStack(spacing: 8) {
                        compactPill("确认未执行后重试", tint: MacDelegationSemanticInk.warning, fillTint: AmberTheme.accentAmber) {
                            pendingConfirmation = .retryUnknown
                        }
                        compactPill("放弃", tint: AmberTheme.muted) {
                            pendingConfirmation = .abandonUnknown
                        }
                    }
                }
            }
            .padding(.vertical, -4)
            .accessibilityIdentifier("chat.macRun.outcomeUnknownActions")
        } else if run.isReceiptUnconfirmed {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    compactPill("重查状态", tint: AmberTheme.accent, isProminent: true, action: onRecheckPending)
                    Spacer(minLength: 6)
                    compactPill("显式取消", tint: MacDelegationSemanticInk.danger, fillTint: AmberTheme.accentRed) {
                        pendingConfirmation = .cancelPending
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    compactPill("重查状态", tint: AmberTheme.accent, isProminent: true, action: onRecheckPending)
                    compactPill("显式取消", tint: MacDelegationSemanticInk.danger, fillTint: AmberTheme.accentRed) {
                        pendingConfirmation = .cancelPending
                    }
                }
            }
            .padding(.vertical, -4)
            .accessibilityIdentifier("chat.macRun.weakNetworkActions")
        } else if run.pendingApproval != nil || (run.canFollowup && run.workItemId != nil) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    if run.pendingApproval != nil {
                        compactPill("查看 Diff 并审批", tint: MacDelegationSemanticInk.warning, fillTint: AmberTheme.accentAmber, action: onOpenApproval)
                    }
                    if run.canFollowup, run.workItemId != nil {
                        compactPill("点名补充修改", tint: AmberTheme.accent, action: onFollowup)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    if run.pendingApproval != nil {
                        compactPill("查看 Diff 并审批", tint: MacDelegationSemanticInk.warning, fillTint: AmberTheme.accentAmber, action: onOpenApproval)
                    }
                    if run.canFollowup, run.workItemId != nil {
                        compactPill("点名补充修改", tint: AmberTheme.accent, action: onFollowup)
                    }
                }
            }
            .padding(.vertical, -4)
        }
    }

    private func compactPill(
        _ title: LocalizedStringKey,
        tint: Color,
        fillTint: Color? = nil,
        isProminent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isProminent ? AmberTheme.accentInk : tint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(
                    isProminent ? tint : (fillTint ?? tint).opacity(0.12),
                    in: Capsule(style: .continuous)
                )
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MacPendingApprovalTimelineBanner: View {
    let approval: MacGatewayApprovalCardItem
    let onOpen: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let iconTint = approval.requiresLocalApproval
            ? MacDelegationSemanticInk.danger
            : MacDelegationSemanticInk.warning
        let borderTint = approval.requiresLocalApproval
            ? AmberTheme.accentRed
            : AmberTheme.accentAmber

        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: approval.requiresLocalApproval ? "lock.desktopcomputer" : "checkmark.shield")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(iconTint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "[\(MacDelegationAttributionBadge.awaitingMacApproval.label(for: approval.endpointRole))] \(approval.summary)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(approval.requiresLocalApproval
                         ? LocalizedStringKey("此高危操作请在 \(approval.endpointRole.displayName) 上批准 · 点按查看只读差异")
                         : "点按打开半屏只读 Diff 审批卡")
                        .font(.caption2)
                        .foregroundStyle(approval.requiresLocalApproval ? iconTint : AmberTheme.muted)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(borderTint.opacity(0.38), lineWidth: 0.85)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.unifiedTimeline.pendingMacApprovalBanner")
    }
}
