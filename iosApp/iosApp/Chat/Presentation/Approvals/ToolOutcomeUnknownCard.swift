import SwiftUI

struct ToolOutcomeUnknownCard: View {
    let descriptor: IOSToolOutcomeUnknownDescriptor
    let onDidApply: () -> Void
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
                    Text("确认操作结果")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                    Text("工具执行未能正常完成，无法确认操作是否已生效。请选择实际结果；系统不会自动重试。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            Label(descriptor.toolName, systemImage: "wrench.and.screwdriver")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground2)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minHeight: 28)
                .background(AmberTheme.surface.opacity(0.72), in: Capsule())

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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(minHeight: 32)
                    .background(AmberTheme.surface2.opacity(0.86), in: Capsule())
            }
            .buttonStyle(.plain)
            .chatApprovalHitTarget()
            .accessibilityLabel("确认操作未生效")

            Button(action: onDidApply) {
                Label("已生效", systemImage: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
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
