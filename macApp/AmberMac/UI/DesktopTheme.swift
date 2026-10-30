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

    /// Liquid Amber Glass glow reserved for the selected/generating/pending thing:
    /// combines warm resin refraction with a top-leading specular glass rim.
    static func glow(_ shape: some InsettableShape) -> some View {
        shape
            .fill(
                LinearGradient(
                    colors: [specularTop.opacity(0.55), honeySoft, honey.opacity(0.75)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                shape.fill(
                    RadialGradient(colors: [honey, honeySoft, .clear], center: .leading, startRadius: 0, endRadius: 240)
                )
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [specularTop, honeyEdge, honeyEdge.opacity(0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.85
                )
            )
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

/// The send key: a 3D Liquid Amber Glass lens that catches overhead light when ready to send.
struct DesktopSendGlyph: View {
    let enabled: Bool
    var glint = false
    @State private var hovering = false
    @State private var sweep: CGFloat = -1
    var body: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 13.5, weight: .bold))
            .foregroundStyle(enabled ? DesktopTheme.paper : DesktopTheme.inkTertiary)
            .frame(width: 32, height: 32)
            .background {
                Circle()
                    .fill(enabled
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    DesktopTheme.accent.opacity(hovering ? 1.0 : 0.92),
                                    DesktopTheme.accentInk
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        : AnyShapeStyle(DesktopTheme.glassRecessed))
                    .overlay {
                        // Top specular lens dome reflection
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Color.white.opacity(enabled ? 0.38 : 0.22),
                                        Color.clear
                                    ],
                                    center: .init(x: 0.35, y: 0.22),
                                    startRadius: 0,
                                    endRadius: 16
                                )
                            )
                    }
                    .overlay(
                        Circle().strokeBorder(
                            LinearGradient(
                                colors: [
                                    DesktopTheme.specularTop.opacity(enabled ? 0.65 : 0.45),
                                    enabled ? DesktopTheme.honeyEdge : DesktopTheme.hairline
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.85
                        )
                    )
                    .shadow(color: enabled ? DesktopTheme.honey : .black.opacity(0.04), radius: hovering ? 10 : 5, y: 2)
            }
            .overlay {
                // Easter egg: type just「琥珀」and light passes through the resin once.
                LinearGradient(colors: [.clear, .white.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 14)
                    .rotationEffect(.degrees(20))
                    .offset(x: sweep * 28)
                    .opacity(sweep > -1 && sweep < 1 ? 1 : 0)
                    .clipShape(Circle())
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

/// Compact Liquid Glass capsule button that replaces jarring system-blue `.link` buttons in cards, inspectors, and boards.
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
                    Capsule().fill(
                        LinearGradient(
                            colors: tinted
                                ? [DesktopTheme.specularTop.opacity(0.65), hovering && enabled ? DesktopTheme.honey : DesktopTheme.honeySoft]
                                : [DesktopTheme.specularTop.opacity(0.60), hovering && enabled ? DesktopTheme.hover : DesktopTheme.paperDeep],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    DesktopTheme.specularTop,
                                    tinted ? DesktopTheme.honeyEdge : DesktopTheme.hairlineStrong
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.85
                        )
                )
                .shadow(color: .black.opacity(0.03), radius: 2, y: 1)
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.42)
                .scaleEffect(configuration.isPressed && enabled ? 0.97 : 1)
                .animation(.easeOut(duration: 0.14), value: hovering)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == DesktopActionPillButtonStyle {
    static var desktopActionPill: DesktopActionPillButtonStyle { DesktopActionPillButtonStyle() }
    static var desktopTintedPill: DesktopActionPillButtonStyle { DesktopActionPillButtonStyle(tinted: true) }
}

/// Liquid Glass composer capability capsule: replaces inline form switches with a specular-rimmed glass pill
/// carrying a symbol, label, status dot, and optional risk/mode badge.
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
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: isOn ? .semibold : .regular))
                    .foregroundStyle(isOn ? DesktopTheme.accentInk : (hovering ? DesktopTheme.inkSecondary : DesktopTheme.inkTertiary))
                Text(title)
                    .font(.system(size: 12.5, weight: isOn ? .medium : .regular))
                    .foregroundStyle(isOn ? DesktopTheme.accentInk : (hovering ? DesktopTheme.ink : DesktopTheme.inkSecondary))
                Circle()
                    .fill(isOn ? DesktopTheme.accent : DesktopTheme.switchOff.opacity(0.45))
                    .frame(width: 5.5, height: 5.5)
                    .shadow(color: isOn ? DesktopTheme.honey : .clear, radius: 3)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(badgeColor.opacity(0.12), in: Capsule())
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: isOn
                            ? [DesktopTheme.specularTop.opacity(0.65), DesktopTheme.honeySoft, DesktopTheme.honey.opacity(0.55)]
                            : [DesktopTheme.specularTop.opacity(0.75), hovering && enabled ? DesktopTheme.hover : DesktopTheme.paperDeep.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                DesktopTheme.specularTop,
                                isOn ? DesktopTheme.honeyEdge : (hovering && enabled ? DesktopTheme.hairlineStrong : DesktopTheme.hairline)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.85
                    )
            }
            .shadow(color: isOn ? DesktopTheme.honey.opacity(0.4) : .black.opacity(0.025), radius: isOn ? 5 : 2, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isOn)
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// Calm warm-parchment canvas ground with subtle neutral depth behind Liquid Glass islands.
struct DesktopAmbientCanvas: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            DesktopTheme.paper
            RadialGradient(
                colors: [
                    DesktopTheme.paperSide.opacity(scheme == .dark ? 0.35 : 0.45),
                    .clear
                ],
                center: .init(x: 0.15, y: 0.10),
                startRadius: 20,
                endRadius: 620
            )
            RadialGradient(
                colors: [
                    DesktopTheme.paperSide.opacity(scheme == .dark ? 0.25 : 0.35),
                    .clear
                ],
                center: .init(x: 0.88, y: 0.18),
                startRadius: 20,
                endRadius: 560
            )
        }
        .ignoresSafeArea()
    }
}

/// Reusable macOS Liquid Glass card surface with understated Claude Desktop warm-gray rim & shadow.
struct DesktopLiquidGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 18
    var tinted = false
    var highlighted = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                DesktopTheme.glassElevated,
                                DesktopTheme.glassSurface,
                                tinted ? DesktopTheme.honeySoft : DesktopTheme.glassSurface
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(alignment: .top) {
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [
                                        DesktopTheme.specularTop.opacity(scheme == .dark ? 0.10 : 0.42),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    }
            }
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: highlighted ? DesktopTheme.honeyEdge : DesktopTheme.specularTop, location: 0.0),
                            .init(color: highlighted ? DesktopTheme.honeyEdge : DesktopTheme.specularMid, location: 0.50),
                            .init(color: highlighted ? DesktopTheme.honeyEdge : DesktopTheme.specularBottom, location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.32 : 0.045), radius: 18, x: 0, y: 8)
            .shadow(color: DesktopTheme.honey.opacity(highlighted ? (scheme == .dark ? 0.18 : 0.24) : (scheme == .dark ? 0.06 : 0.10)),
                    radius: highlighted ? 10 : 5, x: 0, y: 2)
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
