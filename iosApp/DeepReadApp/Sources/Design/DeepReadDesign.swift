import SwiftUI
import UIKit

enum DeepReadPalette {
    static let paper = adaptive(light: 0xFBF7F1, dark: 0x201C19)
    static let card = adaptive(light: 0xFFFDF9, dark: 0x2A2521)
    static let ink = adaptive(light: 0x2A2320, dark: 0xF1E9DF)
    /// Follows the user's swatch; reading it in a view body subscribes that view to changes.
    @MainActor static var accent: Color { accents[DeepReadAppearance.shared.accent]! }
    static let muted = adaptive(light: 0x6E6254, dark: 0xB9AA98)
    static let rule = adaptive(light: 0xE4D9CB, dark: 0x3D3530)
    static let done = adaptive(light: 0x3F6A4A, dark: 0x8DBB98)
    static let warn = adaptive(light: 0x8F5A10, dark: 0xE2A75A)
    static let danger = adaptive(light: 0xA8261F, dark: 0xFF7B6E)
    static let lamp = Color(red: 1, green: 0.78, blue: 0.45)

    private static let accents = Dictionary(uniqueKeysWithValues: DeepReadAccent.allCases.map { ($0, adaptive(light: $0.light, dark: $0.dark)) })

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Warm paper with a fixed grain, plus a desk-lamp glow late at night.
struct DeepReadPaperBackground: View {
    var night = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var lampOn = false

    var body: some View {
        ZStack {
            DeepReadPalette.paper
            Canvas { context, size in
                var seed: UInt64 = 0x9E3779B97F4A7C15
                func next() -> CGFloat {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
                }
                let count = Int(size.width * size.height / 260)
                for _ in 0..<count {
                    let rect = CGRect(x: next() * size.width, y: next() * size.height, width: 1.1, height: 1.1)
                    context.fill(Path(ellipseIn: rect), with: .color(DeepReadPalette.ink.opacity(0.05 * next())))
                }
            }
            .allowsHitTesting(false)
            if night {
                // Additive light washes cream paper to white, so light mode tints instead.
                RadialGradient(colors: [DeepReadPalette.lamp.opacity(lampOn ? (colorScheme == .dark ? 0.26 : 0.2) : 0), .clear],
                               center: .init(x: 0.82, y: 0), startRadius: 10, endRadius: 520)
                    .blendMode(colorScheme == .dark ? .plusLighter : .normal)
                    .allowsHitTesting(false)
                    .onAppear {
                        withAnimation(reduceMotion ? .easeIn(duration: 0.3) : .easeOut(duration: 1.6).delay(0.2)) { lampOn = true }
                    }
            }
        }
        .ignoresSafeArea()
    }
}

/// A cinnabar seal. Multiply blending lets the paper show through like real ink.
struct DeepReadInkStamp: View {
    let text: String
    var size: CGFloat = 64
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.14).stroke(DeepReadPalette.accent, lineWidth: size * 0.07)
            RoundedRectangle(cornerRadius: size * 0.08).stroke(DeepReadPalette.accent, lineWidth: size * 0.02)
                .padding(size * 0.1)
            // Two characters set vertically, like a traditional seal.
            Text(verbatim: text.map(String.init).joined(separator: "\n"))
                .font(.system(size: size * 0.3, weight: .heavy, design: .serif))
                .foregroundStyle(DeepReadPalette.accent)
                .multilineTextAlignment(.center)
                .lineSpacing(-size * 0.04)
                .fixedSize()
        }
        .frame(width: size, height: size)
        .opacity(0.88)
        .blendMode(colorScheme == .dark ? .normal : .multiply)
        .accessibilityLabel("印章：\(text)")
    }
}

/// Slams a stamp down on appearance and whenever `trigger` changes; stays on paper afterwards.
struct DeepReadStampSlam: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Local counter so a stamp inserted together with its trigger still plays on first appearance.
    @State private var fire = 0

    func body(content: Content) -> some View {
        content
            .opacity(fire == 0 ? 0 : 1)
            .onAppear { fire += 1 }
            .onChange(of: trigger) { fire += 1 }
            .keyframeAnimator(initialValue: StampFrame(), trigger: fire) { view, frame in
            view.scaleEffect(frame.scale).rotationEffect(.degrees(frame.angle)).opacity(frame.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                LinearKeyframe(reduceMotion ? 1 : 2.6, duration: 0.01)
                CubicKeyframe(reduceMotion ? 1 : 0.92, duration: reduceMotion ? 0.01 : 0.18)
                SpringKeyframe(1, duration: 0.35, spring: .bouncy)
            }
            KeyframeTrack(\.angle) {
                LinearKeyframe(reduceMotion ? -10 : 8, duration: 0.01)
                CubicKeyframe(-10, duration: reduceMotion ? 0.01 : 0.18)
            }
            KeyframeTrack(\.opacity) {
                LinearKeyframe(0, duration: 0.01)
                CubicKeyframe(1, duration: reduceMotion ? 0.25 : 0.14)
            }
        }
    }

    struct StampFrame {
        var scale = 1.0
        var angle = -10.0
        var opacity = 1.0
    }
}

extension EnvironmentValues {
    /// Whether the enclosing main tab is the selected one.
    @Entry var deepReadTabActive = true
    /// Direction of the last tab switch: 1 toward a later tab, -1 toward an earlier one, 0 before any switch.
    @Entry var deepReadTabDirection: CGFloat = 0
}

/// Hides a tab's content the moment it is deselected (its paper stays), so the system's
/// tab cross-fade dissolves into the new page instead of overlapping two pages of text.
/// The arriving content slides in from the side the tab bar moved toward, then stays put:
/// a bounce-free spring, no scale or vertical drift (both read as the page re-laying out).
struct DeepReadTabVisibility: ViewModifier {
    @Environment(\.deepReadTabActive) private var active
    @Environment(\.deepReadTabDirection) private var direction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrivals = 0
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .transaction { $0.animation = nil }
            .keyframeAnimator(initialValue: 0.0, trigger: arrivals) { content, x in
                content.offset(x: x)
            } keyframes: { _ in
                MoveKeyframe(30 * direction)
                SpringKeyframe(0, duration: 0.3, spring: .smooth(duration: 0.26))
            }
            // A tab's first visit builds it already selected, so it arrives on appear; later appears
            // (back from an article) are not arrivals. Launch (direction 0) does not slide.
            .onAppear {
                guard !appeared else { return }
                appeared = true
                arrive()
            }
            .onChange(of: active) { _, isActive in if isActive { arrive() } }
    }

    private func arrive() {
        guard active, direction != 0, !reduceMotion else { return }
        arrivals += 1
    }
}

/// Grows a text button's hit area to 44pt without changing layout.
struct DeepReadTapTarget: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(12).contentShape(.rect).padding(-12)
    }
}

/// Paper card that sinks slightly under the finger.
struct DeepReadPressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .brightness(configuration.isPressed ? -0.02 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

extension View {
    func deepReadCard() -> some View {
        background(DeepReadPalette.card, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(DeepReadPalette.rule, lineWidth: 0.6))
            .shadow(color: DeepReadPalette.ink.opacity(0.06), radius: 10, y: 4)
    }

    /// Entrance: rises from below with a stagger. Only the first rows wait, so long lists stay instant.
    func deepReadEntrance(_ index: Int, shown: Bool) -> some View {
        modifier(DeepReadEntrance(index: index, shown: shown))
    }
}

private struct DeepReadEntrance: ViewModifier {
    let index: Int
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 26)
            .animation(.spring(response: 0.55, dampingFraction: 0.82).delay(Double(min(index, 8)) * 0.05), value: shown)
    }
}

// MARK: Shake

extension Notification.Name {
    static let deepReadDeviceShaken = Notification.Name("app.amber.deepread.shake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { NotificationCenter.default.post(name: .deepReadDeviceShaken, object: nil) }
        super.motionEnded(motion, with: event)
    }
}
