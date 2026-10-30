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

    static let paper = dynamic(0xFAF8F3, 0x161512)
    /// Sidebar ground: one step deeper than the reading paper so the two columns read apart.
    static let paperSide = dynamic(0xF3F0E8, 0x1B1916)
    /// User message, code and chip ground.
    static let paperDeep = dynamic(0xEFECE3, 0x22201C)
    static let hover = dynamic(0xEAE6DB, 0x282520)
    static let card = dynamic(0xFFFFFF, 0x1E1C18)
    static let field = dynamic(0xFFFFFF, 0x22201C)
    static let ink = dynamic(0x191815, 0xF0EDE6)
    static let inkSecondary = dynamic(0x45433D, 0xC6C2B8)
    static let inkTertiary = dynamic(0x68645C, 0x9E998E)
    static let hairline = dynamic(0x191815, 0xFFF8EB, lightAlpha: 0.085, darkAlpha: 0.08)
    static let hairlineStrong = dynamic(0x191815, 0xFFF8EB, lightAlpha: 0.14, darkAlpha: 0.14)
    static let accent = dynamic(0xA65E26, 0xDAA972)
    static let danger = dynamic(0xB3261E, 0xE5736B)
    static let success = dynamic(0x2A7B4C, 0x68C78E)
    static let switchOff = dynamic(0x8F8B81, 0x7D786D)
    static let accentInk = dynamic(0x784012, 0xECCB9E)
    static let honey = dynamic(0xDE9648, 0xD5A064, lightAlpha: 0.24, darkAlpha: 0.22)
    static let honeySoft = dynamic(0xDE9648, 0xD5A064, lightAlpha: 0.12, darkAlpha: 0.11)
    static let honeyEdge = dynamic(0xA65E26, 0xDAA972, lightAlpha: 0.30, darkAlpha: 0.32)

    // macOS Liquid Glass optical tokens: translucent warm lens layers & directional specular rims
    static let glassSurface = dynamic(0xFFFFFF, 0x201F1C, lightAlpha: 0.78, darkAlpha: 0.74)
    static let glassElevated = dynamic(0xFFFFFF, 0x262421, lightAlpha: 0.88, darkAlpha: 0.82)
    static let glassRecessed = dynamic(0xEFECE4, 0x171614, lightAlpha: 0.70, darkAlpha: 0.68)
    static let specularTop = dynamic(0xFFFFFF, 0xFFFDF8, lightAlpha: 0.92, darkAlpha: 0.18)
    static let specularMid = dynamic(0x191815, 0xFFF8EB, lightAlpha: 0.07, darkAlpha: 0.09)
    static let specularBottom = dynamic(0xA65E26, 0xDAA972, lightAlpha: 0.14, darkAlpha: 0.14)

    /// Songti for editorial moments (brand wordmark, headings, empty state, panel titles).
    static func serif(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Songti SC", size: size).weight(weight)
    }

    /// Flat, understated warm highlight for the selected row.
    static func glow(_ shape: some InsettableShape) -> some View {
        shape
            .fill(honeySoft)
            .overlay(shape.strokeBorder(honeyEdge, lineWidth: 0.75))
    }

    // Compatibility accessors used across secondary panels.
    static func background(_ scheme: ColorScheme) -> Color { paper }
    static func surface(_ scheme: ColorScheme) -> Color { paperDeep }
    static func sidebar(_ scheme: ColorScheme) -> Color { paperSide }
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

/// Claude Desktop style understated warm-gray breathing dot for work in progress.
struct DesktopPulse: View {
    @State private var dim = false
    var body: some View {
        Circle()
            .fill(DesktopTheme.inkSecondary)
            .frame(width: 6, height: 6)
            .scaleEffect(dim ? 0.86 : 1.0)
            .opacity(dim ? 0.32 : 0.82)
            .animation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true), value: dim)
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
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(hovering && enabled ? DesktopTheme.hairline : .clear))
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
    func makeBody(configuration: Configuration) -> some View { PressLabel(configuration: configuration) }
    private struct PressLabel: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && enabled ? 0.9 : 1)
                .opacity(enabled ? 1 : 0.4)
                .animation(.spring(response: 0.22, dampingFraction: 0.55), value: configuration.isPressed)
                .contentShape(Rectangle())
        }
    }
}

/// The send key: clean, flat modern button (no fake 3D dome light or bevel).
struct DesktopSendGlyph: View {
    let enabled: Bool
    var glint = false
    @State private var hovering = false
    var body: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(enabled ? DesktopTheme.paper : DesktopTheme.inkTertiary.opacity(0.65))
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(enabled
                        ? (hovering ? DesktopTheme.accentInk : DesktopTheme.accent)
                        : DesktopTheme.paperDeep)
            )
            .animation(.easeOut(duration: 0.15), value: enabled)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
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
            .modifier(DesktopFieldFrame(focused: focused))
    }
}

private struct DesktopFieldFrame: ViewModifier {
    let focused: Bool
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(enabled ? DesktopTheme.field : DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? DesktopTheme.accent : DesktopTheme.hairlineStrong))
            .opacity(enabled ? 1 : 0.55)
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
    @FocusState private var focused: Bool
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
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? DesktopTheme.accent.opacity(0.5) : .clear, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: selected)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Primary action: amber fill with a paper label (white on the light dark-mode amber would fail contrast).
struct DesktopProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Label(configuration: configuration) }
    private struct Label: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesktopTheme.paper)
                .padding(.horizontal, 14)
                .frame(minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(DesktopTheme.accent).brightness(hovering && enabled ? 0.04 : 0))
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == DesktopProminentButtonStyle {
    static var desktopProminent: DesktopProminentButtonStyle { DesktopProminentButtonStyle() }
}

/// Clean, flat pill button for cards, inspectors, and boards (no fake 3D gradients or shadows).
struct DesktopActionPillButtonStyle: ButtonStyle {
    var tinted = false
    func makeBody(configuration: Configuration) -> some View { PillLabel(configuration: configuration, tinted: tinted) }
    private struct PillLabel: View {
        let configuration: Configuration
        let tinted: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tinted ? DesktopTheme.accentInk : (hovering && enabled ? DesktopTheme.ink : DesktopTheme.inkSecondary))
                .padding(.horizontal, 10)
                .frame(height: 25)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tinted
                            ? (hovering && enabled ? DesktopTheme.honey : DesktopTheme.honeySoft)
                            : (hovering && enabled ? DesktopTheme.hover : DesktopTheme.paperDeep))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(tinted ? DesktopTheme.honeyEdge : DesktopTheme.hairline, lineWidth: 0.75)
                )
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.42)
                .scaleEffect(configuration.isPressed && enabled ? 0.97 : 1)
                .animation(.easeOut(duration: 0.14), value: hovering)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == DesktopActionPillButtonStyle {
    static var desktopActionPill: DesktopActionPillButtonStyle { DesktopActionPillButtonStyle() }
    static var desktopTintedPill: DesktopActionPillButtonStyle { DesktopActionPillButtonStyle(tinted: true) }
}

/// Minimal flat composer toggle button (Claude Desktop / Linear style):
/// quiet and borderless when off, soft flat tint when on — no redundant dots, no nested pills, no fake 3D shine.
struct DesktopToggleChip: View {
    let title: String
    let symbol: String
    let isOn: Bool
    var badge: String? = nil
    var badgeColor: Color = DesktopTheme.accentInk
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: isOn ? .medium : .regular))
                    .foregroundStyle(isOn ? DesktopTheme.accentInk : (hovering ? DesktopTheme.ink : DesktopTheme.inkTertiary))
                Text(title)
                    .font(.system(size: 12.5, weight: isOn ? .medium : .regular))
                    .foregroundStyle(isOn ? DesktopTheme.accentInk : (hovering ? DesktopTheme.ink : DesktopTheme.inkSecondary))
                if let badge, isOn {
                    Text("· \(badge)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(badgeColor.opacity(0.85))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? DesktopTheme.honeySoft : (hovering && enabled ? DesktopTheme.hover : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isOn ? DesktopTheme.honeyEdge : (hovering && enabled ? DesktopTheme.hairline : .clear), lineWidth: 0.75)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isOn)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Calm, flat warm-parchment canvas ground.
struct DesktopAmbientCanvas: View {
    var body: some View {
        DesktopTheme.paper.ignoresSafeArea()
    }
}

/// Clean, flat floating card surface (no fake 3D top glare or bevels).
struct DesktopLiquidGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 16
    var tinted = false
    var highlighted = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(tinted ? DesktopTheme.paperDeep : DesktopTheme.card, in: shape)
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    highlighted ? DesktopTheme.honeyEdge : DesktopTheme.hairlineStrong,
                    lineWidth: 1.0
                )
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.26 : 0.035), radius: 12, x: 0, y: 4)
    }
}

extension View {
    func desktopGlass(cornerRadius: CGFloat = 18, tinted: Bool = false, highlighted: Bool = false) -> some View {
        modifier(DesktopLiquidGlassModifier(cornerRadius: cornerRadius, tinted: tinted, highlighted: highlighted))
    }
}

/// Paper editor frame shared by every TextEditor: field ground, hairline, amber edge while editing, dim when disabled.
struct DesktopEditorFrame: ViewModifier {
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(8)
            .background(enabled ? DesktopTheme.field : DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? DesktopTheme.accent : DesktopTheme.hairlineStrong))
            .opacity(enabled ? 1 : 0.6)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

extension View {
    func desktopEditor() -> some View { modifier(DesktopEditorFrame()) }
}
