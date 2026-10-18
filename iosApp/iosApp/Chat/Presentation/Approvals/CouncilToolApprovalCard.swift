import SwiftUI

struct CouncilToolApprovalCard: View {
    let request: CouncilToolApprovalRequest
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: request.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.accentIndigo)
                    .frame(width: 28, height: 28)
                    .background(AmberTheme.accentIndigo.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
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

            VStack(alignment: .leading, spacing: 3) {
                Text("议题")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted)
                Text(request.objectivePreview)
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.foreground2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AmberTheme.surface.opacity(0.58),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    seatLabel
                    Spacer(minLength: 8)
                    decisionButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    seatLabel
                    HStack {
                        Spacer(minLength: 0)
                        decisionButtons
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .amberGlass(cornerRadius: 16)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AmberTheme.accentIndigo.opacity(0.22), lineWidth: 0.7)
        }
    }

    @ViewBuilder
    private var seatLabel: some View {
        if let maxSeats = request.maxSeats {
            Label("最多 \(maxSeats) 席", systemImage: "person.2")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
        }
    }

    private var decisionButtons: some View {
        HStack(spacing: 8) {
            Button("取消", action: onDeny)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground2)
                .padding(.horizontal, 13)
                .frame(minHeight: 34)
                .background(AmberTheme.surface2.opacity(0.72), in: Capsule())
                .buttonStyle(.plain)
                .chatApprovalHitTarget()
                .accessibilityLabel("取消启动模型议会")

            Button(action: onApprove) {
                Label("启动", systemImage: "arrow.up.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .background(AmberTheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .chatApprovalHitTarget()
            .accessibilityLabel("启动模型议会")
        }
    }
}
