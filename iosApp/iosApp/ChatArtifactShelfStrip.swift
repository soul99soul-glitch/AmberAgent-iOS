import SwiftUI

struct ChatArtifactShelfStrip: View {
    let title: String
    let onExpand: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onExpand) {
                HStack(spacing: 9) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AmberTheme.accent)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AmberTheme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint("展开产物架面板")
            .accessibilityIdentifier("chat-artifact-shelf-strip-expand")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AmberTheme.muted)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("关闭产物架")
            .accessibilityIdentifier("chat-artifact-shelf-strip-close")
        }
        .padding(.horizontal, 12)
        .modifier(ChatArtifactShelfStripGlass())
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height > 14 {
                        onExpand()
                    }
                }
        )
        .accessibilityElement(children: .contain)
    }
}

private struct ChatArtifactShelfStripGlass: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .background(AmberTheme.glass.opacity(0.18), in: Capsule())
                .glassEffect(.regular, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(AmberTheme.border.opacity(0.28), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().stroke(AmberTheme.border.opacity(0.28), lineWidth: 0.5)
                }
        }
    }
}
