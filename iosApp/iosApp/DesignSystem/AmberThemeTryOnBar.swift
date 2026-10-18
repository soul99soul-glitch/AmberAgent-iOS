import SwiftUI

struct AmberThemeTryOnBar: View {
    let displayName: String
    let onCommit: () -> Void
    let onRevert: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("正在试穿")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted)
                Text(displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 8)
            Button(action: onRevert) {
                Text("还原")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(AmberTheme.surface2.opacity(0.86), in: Capsule())
            }
            .buttonStyle(.plain)
            .chatApprovalHitTarget()
            .accessibilityLabel("还原主题")
            Button(action: onCommit) {
                Text("套用")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .background(AmberTheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .chatApprovalHitTarget()
            .accessibilityLabel("套用主题")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .amberGlass(cornerRadius: 16)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AmberTheme.accent.opacity(0.28), lineWidth: 0.7)
        }
    }
}
