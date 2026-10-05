import SwiftUI

/// Which greeting the launch curtain shows. Pure so the date rules are testable.
enum NovelLaunchMood: Equatable {
    case standard
    /// 00:00–04:59: the night-owl variant.
    case lateNight
    /// November: National Novel Writing Month.
    case novelWritingMonth
    /// Jan 1.
    case newYear

    static func current(at date: Date, calendar: Calendar = .current) -> NovelLaunchMood {
        let parts = calendar.dateComponents([.month, .day, .hour], from: date)
        if parts.month == 1, parts.day == 1 { return .newYear }
        if let hour = parts.hour, hour < 5 { return .lateNight }
        if parts.month == 11 { return .novelWritingMonth }
        return .standard
    }

    var tagline: String {
        switch self {
        case .standard: "每个故事，都从一页空白开始"
        case .lateNight: "夜深了，灵感正好"
        case .novelWritingMonth: "十一月是写作月，今天也写一点"
        case .newYear: "新的一年，新的第一章"
        }
    }

    var symbol: String? {
        switch self {
        case .standard: nil
        case .lateNight: "moon.stars.fill"
        case .novelWritingMonth: "flame.fill"
        case .newYear: "sparkles"
        }
    }
}

/// Cold-launch overlay: the app icon's seal stamps onto the page with a ring of
/// ink, the tagline types in, then the curtain lifts. Tap anywhere to skip.
/// Skipped entirely under Reduce Motion or VoiceOver.
struct NovelLaunchCurtain: View {
    let mood: NovelLaunchMood
    let onFinish: () -> Void

    @State private var stamped = false
    @State private var typedCount = 0
    @State private var lifting = false
    @State private var finished = false

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 32) {
                ZStack {
                    Circle()
                        .fill(AmberTheme.accentRed.opacity(0.18))
                        .frame(width: 190, height: 190)
                        .blur(radius: 14)
                        .keyframeAnimator(initialValue: BleedFrame(), trigger: stamped) { content, frame in
                            content.scaleEffect(frame.scale).opacity(frame.opacity)
                        } keyframes: { _ in
                            KeyframeTrack(\.scale) {
                                LinearKeyframe(0.5, duration: 0.24)
                                SpringKeyframe(1.3, duration: 0.6, spring: .smooth)
                            }
                            KeyframeTrack(\.opacity) {
                                LinearKeyframe(0, duration: 0.24)
                                LinearKeyframe(1, duration: 0.08)
                                LinearKeyframe(0, duration: 0.7)
                            }
                        }

                    NovelSealMark(size: 120)
                        .keyframeAnimator(initialValue: SlamFrame(), trigger: stamped) { content, frame in
                            content
                                .scaleEffect(frame.scale)
                                .rotationEffect(.degrees(frame.rotation))
                                .opacity(frame.opacity)
                        } keyframes: { _ in
                            KeyframeTrack(\.scale) {
                                CubicKeyframe(0.92, duration: 0.24)
                                SpringKeyframe(1, duration: 0.45, spring: .bouncy)
                            }
                            KeyframeTrack(\.rotation) {
                                CubicKeyframe(-7, duration: 0.24)
                                SpringKeyframe(-6, duration: 0.45)
                            }
                            KeyframeTrack(\.opacity) {
                                LinearKeyframe(1, duration: 0.14)
                            }
                        }
                }
                .frame(height: 190)

                HStack(spacing: 8) {
                    if let symbol = mood.symbol {
                        Image(systemName: symbol)
                            .foregroundStyle(AmberTheme.accent)
                            .symbolEffect(.pulse, options: .repeating, isActive: typedCount > 0)
                    }
                    // The full line reserves the size so typing never shifts the row.
                    Text(mood.tagline)
                        .opacity(0)
                        .overlay(alignment: .leading) {
                            Text(String(mood.tagline.prefix(typedCount)))
                        }
                        .font(.system(.callout, design: .serif))
                        .foregroundStyle(AmberTheme.foreground2)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(mood.tagline)
            }
        }
        .offset(y: lifting ? -40 : 0)
        .opacity(lifting ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task { await play() }
    }

    private func play() async {
        stamped = true
        try? await Task.sleep(for: .milliseconds(240))
        guard !finished else { return }
        AmberHaptics.trigger(.rigidImpact)
        try? await Task.sleep(for: .milliseconds(380))
        for count in 1...mood.tagline.count {
            guard !finished else { return }
            typedCount = count
            try? await Task.sleep(for: .milliseconds(45))
        }
        try? await Task.sleep(for: .milliseconds(420))
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        typedCount = mood.tagline.count
        withAnimation(.easeIn(duration: 0.32)) { lifting = true }
        Task {
            try? await Task.sleep(for: .milliseconds(330))
            onFinish()
        }
    }

    private struct SlamFrame {
        var scale: CGFloat = 1.8
        var rotation: Double = -16
        var opacity: Double = 0
    }

    private struct BleedFrame {
        var scale: CGFloat = 0.5
        var opacity: Double = 0
    }
}

/// The app icon's seal: a vermilion block with 「文」 and an inner border cut
/// through to the page beneath.
struct NovelSealMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            // Shadow on the block only, so it never shows through the cut-outs.
            RoundedRectangle(cornerRadius: size * 0.085, style: .continuous)
                .fill(AmberTheme.accentRed)
                .shadow(color: AmberTheme.accentRed.opacity(0.3), radius: 10, y: 4)
            RoundedRectangle(cornerRadius: size * 0.045, style: .continuous)
                .strokeBorder(lineWidth: size * 0.028)
                .padding(size * 0.075)
                .blendMode(.destinationOut)
            // Songti Black 「文」 rendered from the icon artwork; iOS ships no Song face.
            Image("SealGlyph")
                .resizable()
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
