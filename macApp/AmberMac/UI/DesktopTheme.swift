import AppKit
import SwiftUI

// Direction "琥珀含光": near-white paper, hairlines, and amber light only on what is happening now.
enum DesktopTheme {
    static let contentWidth: CGFloat = 680

    private static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    static let paper = dynamic(0xFAFAF7, 0x171613)
    /// User message, code and chip ground.
    static let paperDeep = dynamic(0xF3F2EC, 0x211F1B)
    static let hover = dynamic(0xECEAE3, 0x26241F)
    static let card = dynamic(0xFFFFFF, 0x1C1B17)
    static let field = dynamic(0xFFFFFF, 0x211F1B)
    static let ink = dynamic(0x1D1C19, 0xEDEAE3)
    static let inkSecondary = dynamic(0x4A4842, 0xC4C0B6)
    static let inkTertiary = dynamic(0x6B6860, 0x9C978C)
    static let hairline = dynamic(0x1D1C19, 0xFFF8EB, lightAlpha: 0.09, darkAlpha: 0.08)
    static let hairlineStrong = dynamic(0x1D1C19, 0xFFF8EB, lightAlpha: 0.14, darkAlpha: 0.14)
    static let accent = dynamic(0xA0602A, 0xD5AC7B)
    static let danger = dynamic(0xB3261E, 0xE5736B)
    static let switchOff = dynamic(0x1D1C19, 0xFFF8EB, lightAlpha: 0.16, darkAlpha: 0.24)
    static let accentInk = dynamic(0x7A4518, 0xE7C59C)
    static let honey = dynamic(0xDE9648, 0xD5A064, lightAlpha: 0.26, darkAlpha: 0.24)
    static let honeySoft = dynamic(0xDE9648, 0xD5A064, lightAlpha: 0.10, darkAlpha: 0.08)
    static let honeyEdge = dynamic(0xA0602A, 0xD5AC7B, lightAlpha: 0.28, darkAlpha: 0.30)

    /// Songti for editorial moments (brand wordmark, headings, empty state, panel titles).
    static func serif(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Songti SC", size: size).weight(weight)
    }

    /// The amber glow reserved for the selected/generating/pending thing.
    static func glow(_ shape: some InsettableShape) -> some View {
        shape.fill(RadialGradient(colors: [honey, honeySoft, .clear], center: .leading, startRadius: 0, endRadius: 260))
            .overlay(shape.strokeBorder(honeyEdge, lineWidth: 0.5))
    }

    // Compatibility accessors used across secondary panels.
    static func background(_ scheme: ColorScheme) -> Color { paper }
    static func surface(_ scheme: ColorScheme) -> Color { paperDeep }
    static func sidebar(_ scheme: ColorScheme) -> Color { paper }
    static func raised(_ scheme: ColorScheme) -> Color { card }
    static func border(_ scheme: ColorScheme) -> Color { hairline }
    static func muted(_ scheme: ColorScheme) -> Color { inkTertiary }
    static func accentWash(_ scheme: ColorScheme) -> Color { honeySoft }

    static func colorScheme(for appearance: String) -> ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

/// Breathing amber dot for work in progress.
struct DesktopPulse: View {
    @State private var dim = false
    var body: some View {
        Circle().fill(DesktopTheme.accent).frame(width: 6, height: 6)
            .shadow(color: DesktopTheme.honey, radius: dim ? 1 : 4)
            .opacity(dim ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
            .accessibilityLabel("进行中")
    }
}

/// Borderless icon/text button with the paper hover ground.
struct DesktopQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { QuietLabel(configuration: configuration) }
    private struct QuietLabel: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .foregroundStyle(hovering && enabled ? DesktopTheme.ink : DesktopTheme.inkTertiary)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering && enabled ? DesktopTheme.hover : .clear))
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onHover { hovering = $0 }
        }
    }
}

/// Small capsule switch used inline in toolbars and the composer.
struct DesktopSwitch: View {
    let isOn: Bool
    var body: some View {
        Capsule().fill(isOn ? DesktopTheme.accent : DesktopTheme.switchOff)
            .frame(width: 24, height: 14)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(DesktopTheme.card).frame(width: 10, height: 10).padding(2)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.68), value: isOn)
    }
}

/// Press feedback for primary round buttons: a quick squash, then spring back.
struct DesktopPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.55), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// The send key: a lump of amber that brightens when there is something to send.
struct DesktopSendGlyph: View {
    let enabled: Bool
    var glint = false
    @State private var hovering = false
    @State private var sweep: CGFloat = -1
    var body: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(enabled ? DesktopTheme.accentInk : DesktopTheme.inkTertiary)
            .frame(width: 32, height: 32)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(enabled
                        ? AnyShapeStyle(RadialGradient(colors: [DesktopTheme.accent.opacity(hovering ? 0.55 : 0.42), DesktopTheme.honey, DesktopTheme.honeySoft],
                            center: .init(x: 0.5, y: 0.3), startRadius: 0, endRadius: 26))
                        : AnyShapeStyle(DesktopTheme.paperDeep))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(enabled ? DesktopTheme.honeyEdge : .clear, lineWidth: 0.5))
                    .shadow(color: enabled ? DesktopTheme.honey : .clear, radius: hovering ? 10 : 6)
            }
            .overlay {
                // Easter egg: type just「琥珀」and light passes through the resin once.
                LinearGradient(colors: [.clear, .white.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 14)
                    .rotationEffect(.degrees(20))
                    .offset(x: sweep * 28)
                    .opacity(sweep > -1 && sweep < 1 ? 1 : 0)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.2), value: enabled)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .onChange(of: glint) { _, on in
                guard on else { return }
                sweep = -1
                withAnimation(.easeInOut(duration: 0.9)) { sweep = 1.2 }
            }
    }
}

/// Paper text field: card ground, hairline edge, amber edge while editing.
struct DesktopFieldStyle: TextFieldStyle {
    @FocusState private var focused: Bool
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(DesktopTheme.field, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? DesktopTheme.accent : DesktopTheme.hairlineStrong))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

extension TextFieldStyle where Self == DesktopFieldStyle {
    static var desktop: DesktopFieldStyle { DesktopFieldStyle() }
}

/// List row whose selection is the amber glow and whose hover is the paper ground.
struct DesktopSelectableRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if selected { DesktopTheme.glow(RoundedRectangle(cornerRadius: 8)) }
                    else if hovering { RoundedRectangle(cornerRadius: 8).fill(DesktopTheme.hover) }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: selected)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
