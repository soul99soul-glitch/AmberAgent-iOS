import SwiftUI

struct WorkspaceToolApprovalCard: View {
    let request: WorkspaceToolApprovalRequest
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: request.isWrite ? "folder.badge.gearshape" : "folder")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(request.isWrite ? AmberTheme.accentRed : AmberTheme.accentIndigo)
                    .frame(width: 30, height: 30)
                    .background((request.isWrite ? AmberTheme.accentRed : AmberTheme.accentIndigo).opacity(0.12), in: Circle())

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
                Text(request.action)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .lineLimit(1)
                Text(request.target)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AmberTheme.surface.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )

            HStack(spacing: 6) {
                WebMountApprovalChip(systemImage: "wrench.and.screwdriver", title: request.toolName)
                WebMountApprovalChip(systemImage: request.isWrite ? "square.and.pencil" : "doc.text", title: request.isWrite ? "写入" : "读取")
                Spacer(minLength: 0)
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
                .accessibilityLabel("拒绝 Workspace 工具")

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
                .accessibilityLabel("批准 Workspace 工具")
            }
        }
        .padding(12)
        .amberGlass(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke((request.isWrite ? AmberTheme.accentRed : AmberTheme.accentIndigo).opacity(0.34), lineWidth: 0.7)
        }
    }
}
