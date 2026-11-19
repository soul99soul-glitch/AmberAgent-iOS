import SwiftUI

struct ToolOutcomeUnknownCard: View {
    let descriptor: IOSToolOutcomeUnknownDescriptor
    let onDidApply: () -> Void
    var onRequestRecheck: (() -> Void)? = nil
    let onDidNotApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AmberTheme.accentAmber)
                    .frame(width: 30, height: 30)
                    .background(AmberTheme.accentAmber.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("确认操作结果 · 禁止自动重放")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                    Text(descriptor.sideEffectExplanation)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label(descriptor.localizedToolTitle, systemImage: "wrench.and.screwdriver")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: 28)
                    .background(AmberTheme.surface.opacity(0.72), in: Capsule())

                if let target = descriptor.redactedTargetSummary {
                    Text(target)
                        .font(.caption2.monospaced())
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(2)
                        .padding(.horizontal, 4)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    decisionButtons
                }
                VStack(alignment: .trailing, spacing: 8) {
                    decisionButtons
                }
            }
        }
        .padding(12)
        .amberGlass(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AmberTheme.accentAmber.opacity(0.34), lineWidth: 0.7)
        }
    }

    private var decisionButtons: some View {
        Group {
            Button(action: onDidNotApply) {
                Label("未生效", systemImage: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .frame(minHeight: 32)
                    .background(AmberTheme.surface2.opacity(0.86), in: Capsule())
            }
            .buttonStyle(.plain)
            .chatApprovalHitTarget()
            .accessibilityLabel("确认操作未生效")

            if let onRequestRecheck {
                Button(action: onRequestRecheck) {
                    Label("核查当前状态", systemImage: "magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .frame(minHeight: 32)
                        .background(AmberTheme.surface.opacity(0.92), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(AmberTheme.accent.opacity(0.35), lineWidth: 0.8)
                        }
                }
                .buttonStyle(.plain)
                .chatApprovalHitTarget()
                .accessibilityLabel("只读核查当前状态")
            }

            Button(action: onDidApply) {
                Label("已生效", systemImage: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(minHeight: 32)
                    .background(AmberTheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .chatApprovalHitTarget()
            .accessibilityLabel("确认操作已生效")
        }
    }
}

struct OutcomeUnknownFollowupBar: View {
    let followup: IOSOutcomeUnknownFollowup
    let onUseSuggestedPrompt: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: followup.resolution == .recheckRequested ? "magnifyingglass.circle.fill" : "arrow.clockwise.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AmberTheme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(followup.localizedToolTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                Text(followup.resolution == .recheckRequested ? "建议只读核查现状（不重放原调用）" : "已确认未生效，可重新发起并审批")
                    .font(.caption2)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button(action: onUseSuggestedPrompt) {
                Text(followup.buttonTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(AmberTheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭建议")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .amberGlass(cornerRadius: 14)
    }
}
