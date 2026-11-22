import SwiftUI

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

                    if !diffLines.isEmpty {
                        readOnlyDiffCard
                    }

                    if isLocalApprovalRequired {
                        macLocalRedlineBanner
                    } else if let localNotice, !localNotice.isEmpty {
                        Text(verbatim: localNotice)
                            .font(.footnote)
                            .foregroundStyle(AmberTheme.accentAmber)
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
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 12, weight: .semibold))
                Text(verbatim: item.targetDeviceName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
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
                .foregroundStyle(item.riskTier == .l3 ? AmberTheme.accentRed : AmberTheme.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    (item.riskTier == .l3 ? AmberTheme.accentRed : AmberTheme.accent).opacity(0.12),
                    in: Capsule(style: .continuous)
                )

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AmberTheme.muted)
                    .frame(width: 30, height: 30)
                    .background(AmberTheme.surface, in: Circle())
            }
            .buttonStyle(.plain)
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
                    .font(.caption2)
                    .foregroundStyle(AmberTheme.muted2)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(diffLines) { line in
                    Text(verbatim: line.text.isEmpty ? " " : line.text)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(line.foregroundColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(line.backgroundColor)
                }
            }
            .padding(.vertical, 6)
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AmberTheme.accentRed)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: macGatewayL("此高危操作请在 Mac 上批准"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.accentRed)
                    .accessibilityIdentifier("mac.approval.localOnlyWarning")

                Text(verbatim: macGatewayL("解锁手机不会扩大授权范围。你可以在手机端先查看差异、直接驳回，或点名补充修改要求。"))
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AmberTheme.accentRed.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AmberTheme.accentRed.opacity(0.28), lineWidth: 0.8)
        }
    }

    private var actionFooter: some View {
        HStack(spacing: 10) {
            Button {
                submitDecision(allow: false)
            } label: {
                Text(verbatim: macGatewayL("驳回"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.accentRed)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(AmberTheme.accentRed.opacity(0.11), in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityIdentifier("mac.approval.rejectButton")

            if let onRequestModification {
                Button {
                    dismiss()
                    onRequestModification(item)
                } label: {
                    Text(verbatim: macGatewayL("点名修改"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(AmberTheme.surface, in: Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(AmberTheme.border, lineWidth: 0.8)
                        }
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
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(AmberTheme.accent, in: Capsule(style: .continuous))
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
                source: .foregroundApp
            )
            isSubmitting = false
            if delivered {
                dismiss()
            } else if !isLocalApprovalRequired {
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
            return AmberTheme.accentGreen
        }
        if text.hasPrefix("-") {
            return AmberTheme.accentRed
        }
        if text.hasPrefix("@@") {
            return AmberTheme.accentAmber
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

// MARK: - Composer Explicit "交给 Mac" Capsule

struct ComposerDelegateToMacPill: View {
    let isArmed: Bool
    let deviceName: String
    let isReachable: Bool
    let onToggle: () -> Void

    var body: some View {
        Button {
            AmberHaptics.trigger(.selection)
            onToggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isArmed ? "desktopcomputer.and.arrow.down" : "desktopcomputer")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(verbatim: isArmed
                     ? macGatewayL("本次交给 Mac")
                     : macGatewayL("交给 Mac"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if isArmed {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .opacity(0.85)
                } else {
                    Circle()
                        .fill(isReachable ? AmberTheme.accentGreen : AmberTheme.accentAmber)
                        .frame(width: 5.5, height: 5.5)
                }
            }
            .foregroundStyle(isArmed ? AmberTheme.accentInk : AmberTheme.foreground2)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                isArmed ? AmberTheme.accent : AmberTheme.surface,
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(
                        isArmed ? AmberTheme.accent : AmberTheme.borderSoft,
                        lineWidth: 0.75
                    )
            }
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.96, haptic: .none))
        .accessibilityLabel(
            isArmed
                ? "\(macGatewayL("已选中本次交给 Mac"))（\(deviceName)），点按取消并恢复本机发送"
                : "\(macGatewayL("交给 Mac"))（\(deviceName)），点按后本次发送由 Mac 后台执行"
        )
        .accessibilityIdentifier("chat.composer.delegateToMacPill")
    }
}

// MARK: - Unified Timeline Mac Delegation Cards

struct UnifiedMacDelegationTimelineSection: View {
    let runs: [MacDelegatedTimelineRun]
    let pendingStandaloneApprovals: [MacGatewayApprovalCardItem]
    let onRecheckPending: (MacDelegatedTimelineRun) -> Void
    let onCancelPending: (MacDelegatedTimelineRun) -> Void
    let onRecheckUnknown: (String) -> Void
    let onRetryUnknown: (String) -> Void
    let onAbandonUnknown: (String) -> Void
    let onFollowup: (String) -> Void
    let onStop: (String) -> Void
    let onOpenApproval: (MacGatewayApprovalCardItem) -> Void

    var body: some View {
        if !runs.isEmpty || !pendingStandaloneApprovals.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(runs) { run in
                    UnifiedMacDelegationRunCard(
                        run: run,
                        onRecheckPending: { onRecheckPending(run) },
                        onCancelPending: { onCancelPending(run) },
                        onRecheckUnknown: {
                            if let id = run.workItemId { onRecheckUnknown(id) }
                        },
                        onRetryUnknown: {
                            if let id = run.workItemId { onRetryUnknown(id) }
                        },
                        onAbandonUnknown: {
                            if let id = run.workItemId { onAbandonUnknown(id) }
                        },
                        onFollowup: {
                            if let id = run.workItemId { onFollowup(id) }
                        },
                        onStop: {
                            if let id = run.workItemId { onStop(id) }
                        },
                        onOpenApproval: {
                            if let approval = run.pendingApproval { onOpenApproval(approval) }
                        }
                    )
                }

                ForEach(pendingStandaloneApprovals) { approval in
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
}

private struct UnifiedMacDelegationRunCard: View {
    let run: MacDelegatedTimelineRun
    let onRecheckPending: () -> Void
    let onCancelPending: () -> Void
    let onRecheckUnknown: () -> Void
    let onRetryUnknown: () -> Void
    let onAbandonUnknown: () -> Void
    let onFollowup: () -> Void
    let onStop: () -> Void
    let onOpenApproval: () -> Void

    private var badgeTint: Color {
        switch run.badge {
        case .running: return AmberTheme.accent
        case .awaitingMacApproval, .outcomeUnknown: return AmberTheme.accentAmber
        case .completed: return AmberTheme.accentGreen
        case .failed: return AmberTheme.accentRed
        case .cancelled: return AmberTheme.muted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(verbatim: "[\(run.badge.label)]")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(badgeTint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(badgeTint.opacity(0.12), in: Capsule(style: .continuous))
                .accessibilityIdentifier("chat.macRun.badge.\(run.badge.rawValue)")

                if run.isBusy {
                    ProgressView().controlSize(.mini)
                }

                Spacer(minLength: 4)

                if run.canStop, run.workItemId != nil, !run.isReceiptUnconfirmed {
                    Button(macGatewayL("停止"), action: onStop)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AmberTheme.accentRed)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AmberTheme.accentRed.opacity(0.11), in: Capsule(style: .continuous))
                        .buttonStyle(.plain)
                }
            }

            Text(verbatim: run.promptText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let resultText = run.resultText, !resultText.isEmpty, run.badge == .completed {
                Text(verbatim: resultText)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: run.statusLine)
                    .font(.caption)
                    .foregroundStyle(run.isOutcomeUnknown || run.isReceiptUnconfirmed ? AmberTheme.accentAmber : AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !run.sourceAnnotations.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(run.sourceAnnotations, id: \.self) { source in
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 10))
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
    }

    @ViewBuilder
    private var actionBar: some View {
        if run.isOutcomeUnknown, run.workItemId != nil {
            HStack(spacing: 8) {
                compactPill(macGatewayL("重查状态"), tint: AmberTheme.accent, action: onRecheckUnknown)
                compactPill(macGatewayL("确认未执行后重试"), tint: AmberTheme.accentAmber, action: onRetryUnknown)
                compactPill(macGatewayL("放弃"), tint: AmberTheme.muted, action: onAbandonUnknown)
            }
            .accessibilityIdentifier("chat.macRun.outcomeUnknownActions")
        } else if run.isReceiptUnconfirmed {
            HStack(spacing: 8) {
                compactPill(macGatewayL("重查状态"), tint: AmberTheme.accent, action: onRecheckPending)
                compactPill(macGatewayL("显式取消"), tint: AmberTheme.accentRed, action: onCancelPending)
            }
            .accessibilityIdentifier("chat.macRun.weakNetworkActions")
        } else {
            HStack(spacing: 8) {
                if run.pendingApproval != nil {
                    compactPill(macGatewayL("查看 Diff 并审批"), tint: AmberTheme.accentAmber, action: onOpenApproval)
                }
                if run.canFollowup, run.workItemId != nil {
                    compactPill(macGatewayL("点名补充修改"), tint: AmberTheme.accent, action: onFollowup)
                }
            }
        }
    }

    private func compactPill(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5.5)
                .background(tint.opacity(0.12), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct MacPendingApprovalTimelineBanner: View {
    let approval: MacGatewayApprovalCardItem
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: approval.requiresLocalApproval ? "lock.desktopcomputer" : "checkmark.shield")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(approval.requiresLocalApproval ? AmberTheme.accentRed : AmberTheme.accentAmber)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "[\(macGatewayL("等待 Mac 确认"))] \(approval.summary)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .lineLimit(1)
                    Text(verbatim: approval.requiresLocalApproval
                         ? macGatewayL("此高危操作请在 Mac 上批准 · 点按查看只读差异")
                         : macGatewayL("点按打开半屏只读 Diff 审批卡"))
                        .font(.caption2)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        (approval.requiresLocalApproval ? AmberTheme.accentRed : AmberTheme.accentAmber).opacity(0.35),
                        lineWidth: 0.8
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.unifiedTimeline.pendingMacApprovalBanner")
    }
}
