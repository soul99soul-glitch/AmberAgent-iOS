import AppKit
import SwiftUI

// MARK: - 1. Official Amber Brand Mark Vector + Liquid Glass Emblem

/// Understated Claude Desktop / Linear style reasoning glyph ("思维涟漪"):
/// a calm center node with two delicate partial concentric arcs that softly breathe while thinking.
/// Replaces the overused `sparkles` (✨) cliché.
struct DesktopReasoningGlyph: View {
    var thinking = false
    @State private var breathing = false

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let c = CGPoint(x: w / 2, y: h / 2)
            let style = StrokeStyle(lineWidth: 1.25, lineCap: .round)

            // Center thought core
            let coreR: CGFloat = 1.65
            let core = Path(ellipseIn: CGRect(x: c.x - coreR, y: c.y - coreR, width: coreR * 2, height: coreR * 2))
            context.fill(core, with: .color(DesktopTheme.inkSecondary))

            // Inner partial ripple arc (top-left to bottom-right)
            var innerArc = Path()
            innerArc.addArc(center: c, radius: min(w, h) * 0.28, startAngle: .degrees(-145), endAngle: .degrees(35), clockwise: false)
            context.stroke(innerArc, with: .color(DesktopTheme.inkSecondary.opacity(0.85)), style: style)

            // Outer partial ripple arc (opposite phase)
            var outerArc = Path()
            outerArc.addArc(center: c, radius: min(w, h) * 0.45, startAngle: .degrees(35), endAngle: .degrees(215), clockwise: false)
            context.stroke(outerArc, with: .color(DesktopTheme.inkTertiary.opacity(0.75)), style: style)
        }
        .frame(width: 13, height: 13)
        .scaleEffect(thinking && breathing ? 0.90 : 1.0)
        .opacity(thinking && breathing ? 0.45 : 0.92)
        .animation(thinking ? .easeInOut(duration: 1.35).repeatForever(autoreverses: true) : .default, value: breathing)
        .onAppear { if thinking { breathing = true } }
        .onChange(of: thinking) { _, active in breathing = active }
        .accessibilityHidden(true)
    }
}

/// Vector-accurate recreation of `AmberMark` (architectural 'A' with inner amber spire inside a Liquid Glass squircle),
/// used when the asset catalog image is unavailable (such as in standalone snapshot builds).
struct DesktopAmberEmblem: View {
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
        ZStack {
            shape
                .fill(
                    LinearGradient(
                        colors: scheme == .dark
                            ? [Color(red: 0.18, green: 0.17, blue: 0.15), Color(red: 0.13, green: 0.12, blue: 0.10)]
                            : [Color(red: 1.0, green: 0.99, blue: 0.97), Color(red: 0.95, green: 0.93, blue: 0.89)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Canvas { context, canvasSize in
                let w = canvasSize.width
                let h = canvasSize.height

                // Outer 'A' legs
                var aPath = Path()
                aPath.move(to: CGPoint(x: w * 0.50, y: h * 0.18))
                aPath.addLine(to: CGPoint(x: w * 0.80, y: h * 0.80))
                aPath.addLine(to: CGPoint(x: w * 0.67, y: h * 0.80))
                aPath.addLine(to: CGPoint(x: w * 0.59, y: h * 0.63))
                aPath.addLine(to: CGPoint(x: w * 0.41, y: h * 0.63))
                aPath.addLine(to: CGPoint(x: w * 0.33, y: h * 0.80))
                aPath.addLine(to: CGPoint(x: w * 0.20, y: h * 0.80))
                aPath.closeSubpath()

                // Inner cutout of 'A'
                var cutout = Path()
                cutout.move(to: CGPoint(x: w * 0.50, y: h * 0.35))
                cutout.addLine(to: CGPoint(x: w * 0.57, y: h * 0.53))
                cutout.addLine(to: CGPoint(x: w * 0.43, y: h * 0.53))
                cutout.closeSubpath()

                let inkColor = scheme == .dark
                    ? Color(red: 0.94, green: 0.92, blue: 0.88)
                    : Color(red: 0.12, green: 0.11, blue: 0.10)
                context.fill(aPath, with: .color(inkColor))
                context.fill(
                    cutout,
                    with: .color(
                        scheme == .dark
                            ? Color(red: 0.15, green: 0.14, blue: 0.12)
                            : Color(red: 0.98, green: 0.97, blue: 0.94)
                    )
                )

                // Inner Amber Spire at the apex of the 'A'
                var spire = Path()
                spire.move(to: CGPoint(x: w * 0.50, y: h * 0.38))
                spire.addLine(to: CGPoint(x: w * 0.545, y: h * 0.55))
                spire.addLine(to: CGPoint(x: w * 0.455, y: h * 0.55))
                spire.closeSubpath()
                context.fill(spire, with: .color(DesktopTheme.accent))
            }

            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [DesktopTheme.specularTop, DesktopTheme.hairlineStrong, DesktopTheme.specularBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: max(0.75, size * 0.025)
                )
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }
}

// MARK: - 2. Koboyo & UI8 Inspired Hand-Crafted Duo-Tone Vector Icons

/// Custom vector icon palette & geometry inspired by `koboyo.com/icons` and Faisal Ahmed's UI8 design systems.
enum DesktopCraftGlyph: Equatable {
    case calendar
    case botPlane
    case clockOrbit
    case ideaBulb
    case docLens
    case editorialPen
    case meridianGlobe
    case contextStack
    case pinTack
    case folderArchive
    case terminalTask
    case videoCamera
    case meetingRoom
}

enum DesktopCraftTone {
    case amber      // Warm resin gold (for primary / active items)
    case terracotta // Editorial clay orange (for calendar & documents)
    case jade       // Calm emerald sage (for bot & completed tasks)
    case ocean      // Slate cobalt blue (for web & discovery)
    case stone      // Understated Claude warm-gray (for empty/secondary utility rows)

    var primary: Color {
        switch self {
        case .amber: Color(red: 0.65, green: 0.37, blue: 0.15)
        case .terracotta: Color(red: 0.72, green: 0.35, blue: 0.20)
        case .jade: Color(red: 0.20, green: 0.47, blue: 0.36)
        case .ocean: Color(red: 0.24, green: 0.44, blue: 0.60)
        case .stone: Color(red: 0.40, green: 0.38, blue: 0.35)
        }
    }

    var darkPrimary: Color {
        switch self {
        case .amber: Color(red: 0.88, green: 0.68, blue: 0.44)
        case .terracotta: Color(red: 0.90, green: 0.58, blue: 0.43)
        case .jade: Color(red: 0.48, green: 0.76, blue: 0.62)
        case .ocean: Color(red: 0.54, green: 0.72, blue: 0.88)
        case .stone: Color(red: 0.72, green: 0.70, blue: 0.64)
        }
    }
}

/// Hand-crafted duo-tone vector icon inside an optional Liquid Glass squircle badge.
struct DesktopCraftIcon: View {
    let glyph: DesktopCraftGlyph
    var tone: DesktopCraftTone = .amber
    var size: CGFloat = 24
    var boxed: Bool = true
    @Environment(\.colorScheme) private var scheme

    private var strokeColor: Color {
        scheme == .dark ? tone.darkPrimary : tone.primary
    }

    var body: some View {
        ZStack {
            if boxed {
                let shape = RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                DesktopTheme.specularTop.opacity(scheme == .dark ? 0.16 : 0.72),
                                strokeColor.opacity(scheme == .dark ? 0.18 : 0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [
                                    DesktopTheme.specularTop.opacity(scheme == .dark ? 0.32 : 0.85),
                                    strokeColor.opacity(0.28)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                    )
                    .shadow(color: strokeColor.opacity(0.10), radius: 3, y: 1)
            }

            Canvas { context, canvasSize in
                let w = canvasSize.width
                let h = canvasSize.height
                let s = min(w, h)
                let lw = max(1.35, s * 0.095)
                let style = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
                let fillTint = strokeColor.opacity(scheme == .dark ? 0.24 : 0.18)

                switch glyph {
                case .calendar:
                    // Rounded calendar page + header band + clock dot
                    let rect = CGRect(x: w * 0.16, y: h * 0.20, width: w * 0.68, height: h * 0.64)
                    let card = Path(roundedRect: rect, cornerRadius: s * 0.16)
                    let topBand = Path(roundedRect: CGRect(x: w * 0.16, y: h * 0.20, width: w * 0.68, height: h * 0.20), cornerRadius: s * 0.12)
                    context.fill(topBand, with: .color(fillTint))
                    context.stroke(card, with: .color(strokeColor), style: style)
                    var hooks = Path()
                    hooks.move(to: CGPoint(x: w * 0.34, y: h * 0.13))
                    hooks.addLine(to: CGPoint(x: w * 0.34, y: h * 0.25))
                    hooks.move(to: CGPoint(x: w * 0.66, y: h * 0.13))
                    hooks.addLine(to: CGPoint(x: w * 0.66, y: h * 0.25))
                    hooks.move(to: CGPoint(x: w * 0.18, y: h * 0.40))
                    hooks.addLine(to: CGPoint(x: w * 0.82, y: h * 0.40))
                    context.stroke(hooks, with: .color(strokeColor), style: style)
                    let dot = Path(ellipseIn: CGRect(x: w * 0.43, y: h * 0.53, width: s * 0.14, height: s * 0.14))
                    context.fill(dot, with: .color(strokeColor))

                case .botPlane:
                    // Koboyo-style hand-crafted paper plane with duo-tone wing fold
                    var wing = Path()
                    wing.move(to: CGPoint(x: w * 0.16, y: h * 0.48))
                    wing.addLine(to: CGPoint(x: w * 0.84, y: h * 0.18))
                    wing.addLine(to: CGPoint(x: w * 0.62, y: h * 0.82))
                    wing.addLine(to: CGPoint(x: w * 0.44, y: h * 0.58))
                    wing.closeSubpath()
                    context.fill(wing, with: .color(fillTint))
                    context.stroke(wing, with: .color(strokeColor), style: style)
                    var crease = Path()
                    crease.move(to: CGPoint(x: w * 0.84, y: h * 0.18))
                    crease.addLine(to: CGPoint(x: w * 0.44, y: h * 0.58))
                    context.stroke(crease, with: .color(strokeColor), style: style)

                case .clockOrbit:
                    let circle = Path(ellipseIn: CGRect(x: w * 0.16, y: h * 0.16, width: w * 0.68, height: h * 0.68))
                    context.fill(circle, with: .color(fillTint))
                    context.stroke(circle, with: .color(strokeColor), style: style)
                    var hands = Path()
                    hands.move(to: CGPoint(x: w * 0.50, y: h * 0.32))
                    hands.addLine(to: CGPoint(x: w * 0.50, y: h * 0.50))
                    hands.addLine(to: CGPoint(x: w * 0.64, y: h * 0.58))
                    context.stroke(hands, with: .color(strokeColor), style: style)

                case .ideaBulb:
                    let bulb = Path(ellipseIn: CGRect(x: w * 0.24, y: h * 0.16, width: w * 0.52, height: h * 0.50))
                    context.fill(bulb, with: .color(fillTint))
                    context.stroke(bulb, with: .color(strokeColor), style: style)
                    var base = Path()
                    base.move(to: CGPoint(x: w * 0.38, y: h * 0.72))
                    base.addLine(to: CGPoint(x: w * 0.62, y: h * 0.72))
                    base.move(to: CGPoint(x: w * 0.42, y: h * 0.83))
                    base.addLine(to: CGPoint(x: w * 0.58, y: h * 0.83))
                    context.stroke(base, with: .color(strokeColor), style: style)

                case .docLens:
                    let page = Path(roundedRect: CGRect(x: w * 0.18, y: h * 0.16, width: w * 0.52, height: h * 0.66), cornerRadius: s * 0.12)
                    context.fill(page, with: .color(fillTint))
                    context.stroke(page, with: .color(strokeColor), style: style)
                    let lens = Path(ellipseIn: CGRect(x: w * 0.46, y: h * 0.44, width: w * 0.30, height: h * 0.30))
                    context.fill(lens, with: .color(DesktopTheme.card))
                    context.stroke(lens, with: .color(strokeColor), style: style)
                    var handle = Path()
                    handle.move(to: CGPoint(x: w * 0.72, y: h * 0.70))
                    handle.addLine(to: CGPoint(x: w * 0.84, y: h * 0.82))
                    context.stroke(handle, with: .color(strokeColor), style: style)

                case .editorialPen:
                    let card = Path(roundedRect: CGRect(x: w * 0.16, y: h * 0.20, width: w * 0.68, height: h * 0.60), cornerRadius: s * 0.14)
                    context.fill(card, with: .color(fillTint))
                    var lines = Path()
                    lines.move(to: CGPoint(x: w * 0.24, y: h * 0.34))
                    lines.addLine(to: CGPoint(x: w * 0.76, y: h * 0.34))
                    lines.move(to: CGPoint(x: w * 0.24, y: h * 0.50))
                    lines.addLine(to: CGPoint(x: w * 0.64, y: h * 0.50))
                    lines.move(to: CGPoint(x: w * 0.24, y: h * 0.66))
                    lines.addLine(to: CGPoint(x: w * 0.52, y: h * 0.66))
                    context.stroke(lines, with: .color(strokeColor), style: style)

                case .meridianGlobe:
                    let globe = Path(ellipseIn: CGRect(x: w * 0.16, y: h * 0.16, width: w * 0.68, height: h * 0.68))
                    context.fill(globe, with: .color(fillTint))
                    context.stroke(globe, with: .color(strokeColor), style: style)
                    let meridian = Path(ellipseIn: CGRect(x: w * 0.33, y: h * 0.16, width: w * 0.34, height: h * 0.68))
                    context.stroke(meridian, with: .color(strokeColor), style: style)
                    var equator = Path()
                    equator.move(to: CGPoint(x: w * 0.18, y: h * 0.50))
                    equator.addLine(to: CGPoint(x: w * 0.82, y: h * 0.50))
                    context.stroke(equator, with: .color(strokeColor), style: style)

                case .contextStack:
                    // Layered diamond stack (Faisal Ahmed / Linear style)
                    var topLayer = Path()
                    topLayer.move(to: CGPoint(x: w * 0.50, y: h * 0.18))
                    topLayer.addLine(to: CGPoint(x: w * 0.82, y: h * 0.36))
                    topLayer.addLine(to: CGPoint(x: w * 0.50, y: h * 0.54))
                    topLayer.addLine(to: CGPoint(x: w * 0.18, y: h * 0.36))
                    topLayer.closeSubpath()
                    context.fill(topLayer, with: .color(fillTint))
                    context.stroke(topLayer, with: .color(strokeColor), style: style)
                    var midLayer = Path()
                    midLayer.move(to: CGPoint(x: w * 0.18, y: h * 0.52))
                    midLayer.addLine(to: CGPoint(x: w * 0.50, y: h * 0.70))
                    midLayer.addLine(to: CGPoint(x: w * 0.82, y: h * 0.52))
                    var botLayer = Path()
                    botLayer.move(to: CGPoint(x: w * 0.18, y: h * 0.66))
                    botLayer.addLine(to: CGPoint(x: w * 0.50, y: h * 0.84))
                    botLayer.addLine(to: CGPoint(x: w * 0.82, y: h * 0.66))
                    context.stroke(midLayer, with: .color(strokeColor), style: style)
                    context.stroke(botLayer, with: .color(strokeColor), style: style)

                case .pinTack:
                    var bookmark = Path()
                    bookmark.move(to: CGPoint(x: w * 0.26, y: h * 0.18))
                    bookmark.addLine(to: CGPoint(x: w * 0.74, y: h * 0.18))
                    bookmark.addLine(to: CGPoint(x: w * 0.74, y: h * 0.82))
                    bookmark.addLine(to: CGPoint(x: w * 0.50, y: h * 0.64))
                    bookmark.addLine(to: CGPoint(x: w * 0.26, y: h * 0.82))
                    bookmark.closeSubpath()
                    context.fill(bookmark, with: .color(fillTint))
                    context.stroke(bookmark, with: .color(strokeColor), style: style)

                case .folderArchive:
                    var folder = Path()
                    folder.move(to: CGPoint(x: w * 0.16, y: h * 0.28))
                    folder.addLine(to: CGPoint(x: w * 0.42, y: h * 0.28))
                    folder.addLine(to: CGPoint(x: w * 0.50, y: h * 0.38))
                    folder.addLine(to: CGPoint(x: w * 0.84, y: h * 0.38))
                    folder.addLine(to: CGPoint(x: w * 0.84, y: h * 0.78))
                    folder.addLine(to: CGPoint(x: w * 0.16, y: h * 0.78))
                    folder.closeSubpath()
                    context.fill(folder, with: .color(fillTint))
                    context.stroke(folder, with: .color(strokeColor), style: style)

                case .terminalTask:
                    let box = Path(roundedRect: CGRect(x: w * 0.16, y: h * 0.20, width: w * 0.68, height: h * 0.60), cornerRadius: s * 0.14)
                    context.fill(box, with: .color(fillTint))
                    context.stroke(box, with: .color(strokeColor), style: style)
                    var prompt = Path()
                    prompt.move(to: CGPoint(x: w * 0.30, y: h * 0.40))
                    prompt.addLine(to: CGPoint(x: w * 0.42, y: h * 0.50))
                    prompt.addLine(to: CGPoint(x: w * 0.30, y: h * 0.60))
                    prompt.move(to: CGPoint(x: w * 0.50, y: h * 0.60))
                    prompt.addLine(to: CGPoint(x: w * 0.68, y: h * 0.60))
                    context.stroke(prompt, with: .color(strokeColor), style: style)

                case .videoCamera:
                    let bodyRect = Path(roundedRect: CGRect(x: w * 0.14, y: h * 0.28, width: w * 0.48, height: h * 0.44), cornerRadius: s * 0.10)
                    context.fill(bodyRect, with: .color(fillTint))
                    context.stroke(bodyRect, with: .color(strokeColor), style: style)
                    var lens = Path()
                    lens.move(to: CGPoint(x: w * 0.62, y: h * 0.42))
                    lens.addLine(to: CGPoint(x: w * 0.84, y: h * 0.30))
                    lens.addLine(to: CGPoint(x: w * 0.84, y: h * 0.70))
                    lens.addLine(to: CGPoint(x: w * 0.62, y: h * 0.58))
                    lens.closeSubpath()
                    context.fill(lens, with: .color(fillTint))
                    context.stroke(lens, with: .color(strokeColor), style: style)

                case .meetingRoom:
                    let pin = Path(ellipseIn: CGRect(x: w * 0.24, y: h * 0.18, width: w * 0.52, height: h * 0.52))
                    context.fill(pin, with: .color(fillTint))
                    context.stroke(pin, with: .color(strokeColor), style: style)
                    let centerDot = Path(ellipseIn: CGRect(x: w * 0.42, y: h * 0.36, width: w * 0.16, height: h * 0.16))
                    context.fill(centerDot, with: .color(strokeColor))
                }
            }
            .frame(width: boxed ? size * 0.66 : size, height: boxed ? size * 0.66 : size)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - 3. Appica UI Inspired Tactile 3D Keycap & Context Meter

/// Tactile 3D keycap badge inspired by `appica.dev/ui` command palette shortcuts.
struct DesktopKeycap: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced).weight(.semibold))
            .foregroundStyle(DesktopTheme.inkSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [DesktopTheme.specularTop.opacity(0.85), DesktopTheme.paperDeep],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(DesktopTheme.hairlineStrong, lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.08), radius: 0.5, x: 0, y: 1.2)
    }
}

/// Appica UI inspired segmented token window meter bar for the Context floating island.
struct DesktopContextMeterBar: View {
    let tokens: Int
    var limit: Int = 128_000

    private var activeSegments: Int {
        guard tokens > 0 else { return 1 }
        let ratio = min(1.0, Double(tokens) / Double(max(1, limit)))
        return max(2, Int(ceil(ratio * 12.0)))
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<12, id: \.self) { index in
                let lit = index < activeSegments
                Capsule()
                    .fill(
                        lit
                            ? LinearGradient(
                                colors: [DesktopTheme.accent, DesktopTheme.honeyEdge],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            : LinearGradient(
                                colors: [DesktopTheme.paperDeep, DesktopTheme.paperDeep],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                    )
                    .frame(height: 4)
            }
        }
        .accessibilityHidden(true)
    }
}
