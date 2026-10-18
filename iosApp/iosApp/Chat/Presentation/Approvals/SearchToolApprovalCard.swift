import SwiftUI

struct SearchToolApprovalCard: View {
    let request: SearchToolApprovalRequest
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: request.toolName == "scrape_web" ? "doc.text.magnifyingglass" : "magnifyingglass.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AmberTheme.accentCyan)
                    .frame(width: 30, height: 30)
                    .background(AmberTheme.accentCyan.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(request.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)

                    Text(request.reason)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(request.target)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(request.providerName) · \(request.providerType)")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AmberTheme.surface.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    WebMountApprovalChip(systemImage: "wrench.and.screwdriver", title: request.toolName)
                    WebMountApprovalChip(systemImage: "network", title: request.providerName)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 6) {
                    WebMountApprovalChip(systemImage: "wrench.and.screwdriver", title: request.toolName)
                    WebMountApprovalChip(systemImage: "network", title: request.providerName)
                }
            }

            HStack(spacing: 8) {
                Spacer()

                Button(action: onDeny) {
                    Label("拒绝", systemImage: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground2)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(AmberTheme.surface2.opacity(0.86), in: Capsule())
                }
                .buttonStyle(.plain)
                .chatApprovalHitTarget()
                .accessibilityLabel("拒绝网络搜索")

                Button(action: onApprove) {
                    Label("批准", systemImage: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background(AmberTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .chatApprovalHitTarget()
                .accessibilityLabel("批准网络搜索")
            }
        }
        .padding(12)
        .amberGlass(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AmberTheme.accentCyan.opacity(0.34), lineWidth: 0.7)
        }
    }
}
