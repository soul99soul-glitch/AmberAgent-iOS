import SwiftUI

/// The Amber mark. Breathes softly on the empty state; five quick taps release a drop of resin
/// that falls and settles — a small reward for the curious.
struct DesktopAmberMark: View {
    let size: CGFloat
    @Binding var taps: Int
    var breathes = false
    @State private var glow = false
    @State private var drop = false
    @State private var wobble = false
    @State private var lastTap = Date.distantPast

    var body: some View {
        Image("AmberMark").resizable().interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24))
            .shadow(color: DesktopTheme.honey.opacity(breathes && glow ? 1 : 0), radius: size * 0.4)
            .rotationEffect(.degrees(wobble ? -8 : 0), anchor: .bottom)
            .overlay(alignment: .bottom) {
                Circle()
                    .fill(RadialGradient(colors: [DesktopTheme.accent, DesktopTheme.honey], center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.12))
                    .frame(width: size * 0.18, height: size * 0.22)
                    .offset(y: drop ? size * 1.4 : -size * 0.2)
                    .scaleEffect(drop ? 1 : 0.4)
                    .opacity(drop ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onAppear {
                guard breathes else { return }
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { glow = true }
            }
            .onTapGesture {
                taps = Date().timeIntervalSince(lastTap) < 0.6 ? taps + 1 : 1
                lastTap = Date()
                withAnimation(.spring(response: 0.18, dampingFraction: 0.3)) { wobble = true }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5).delay(0.12)) { wobble = false }
                if taps >= 5 {
                    taps = 0
                    drop = false
                    withAnimation(.easeIn(duration: 0.9)) { drop = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { drop = false }
                }
            }
            .accessibilityHidden(true)
    }
}

/// Messages rise in once, the first time they appear.
struct DesktopRiseIn: ViewModifier {
    @State private var shown = false
    let enabled: Bool
    func body(content: Content) -> some View {
        content
            .opacity(shown || !enabled ? 1 : 0)
            .offset(y: shown || !enabled ? 0 : 12)
            .onAppear {
                guard enabled, !shown else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { shown = true }
            }
    }
}

/// While a reply streams in, a faint amber shimmer travels along its leading edge.
struct DesktopStreamingEdge: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            if active {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(LinearGradient(colors: [.clear, DesktopTheme.accent.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
                        .frame(width: 1.5, height: max(24, proxy.size.height * 0.35))
                        .offset(y: phase * proxy.size.height)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
                        }
                }
                .frame(width: 1.5)
                .offset(x: -16)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: active)
    }
}

/// Segmented switcher: a paper chip slides under the chosen option (replaces the system segmented picker,
/// which jumps without motion and paints a solid accent block).
struct DesktopSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var expands = false
    @Namespace private var chip
    @State private var hovered: Value?
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: 13, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? DesktopTheme.ink : (hovered == option.value ? DesktopTheme.inkSecondary : DesktopTheme.inkTertiary))
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: expands ? .infinity : nil)
                        .frame(height: 26)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(DesktopTheme.card)
                                    .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DesktopTheme.hairline))
                                    .matchedGeometryEffect(id: "chip", in: chip)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? option.value : (hovered == option.value ? nil : hovered) }
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.hairline))
        .opacity(enabled ? 1 : 0.5)
        .fixedSize(horizontal: !expands, vertical: true)
    }
}

/// Tab content swap: the incoming page drifts in from the side of the chosen tab.
struct DesktopTabTransition: ViewModifier {
    let forward: Bool
    func body(content: Content) -> some View {
        content.transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(x: forward ? 14 : -14)),
            removal: .opacity))
    }
}
