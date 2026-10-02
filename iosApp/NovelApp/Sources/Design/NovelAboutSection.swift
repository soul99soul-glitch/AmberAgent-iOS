import SwiftUI

/// Lines the ink easter egg types out. Index picked by the tap streak count so
/// repeated discoveries cycle through them deterministically.
enum NovelInkQuotes {
    static let all = [
        "先写下来，再写好它。",
        "人物想要什么？什么挡着他？",
        "删掉你最舍不得的那一句试试。",
        "每一章都该让读者多问一个问题。",
        "卡住的时候，让角色做一件蠢事。",
        "好的结尾，在第一章就埋好了。"
    ]

    static func quote(forDiscovery index: Int) -> String {
        all[((index % all.count) + all.count) % all.count]
    }
}

/// Settings footer: app mark, version, and the hidden ink splash.
struct NovelAboutSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var taps = 0
    @State private var lastTap = Date.distantPast
    @State private var discoveries = 0
    @State private var splash = 0
    @State private var quote: String?
    @State private var typed = 0

    static let tapsToReveal = 5
    static let streakWindow: TimeInterval = 1.2

    var body: some View {
        Section {
            VStack(spacing: 12) {
                ZStack {
                    NovelInkSplash(trigger: splash)
                        .frame(width: 160, height: 120)
                    // Drawn at the launch-curtain design size, then scaled, so the
                    // page lines keep their proportions.
                    VStack(spacing: -12) {
                        NovelNibMark()
                            .frame(width: 22, height: 54)
                            .rotationEffect(.degrees(taps == 0 ? 0 : Double(taps) * 7 - 14))
                        NovelBookMark(open: true)
                            .frame(width: 132, height: 96)
                    }
                    .scaleEffect(0.5 + Double(taps) * 0.02)
                    .frame(width: 70, height: 76)
                    .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.45), value: taps)
                }
                .frame(height: 96)
                .contentShape(Rectangle())
                .onTapGesture(perform: tap)
                .accessibilityHidden(true)

                Text("小说创作 \(Self.version)")
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted)

                if let quote {
                    // The full line reserves the size so typing never resizes the row.
                    Text(quote)
                        .opacity(0)
                        .overlay(alignment: .topLeading) {
                            Text(String(quote.prefix(typed)))
                        }
                        .font(.system(.callout, design: .serif))
                        .foregroundStyle(AmberTheme.foreground2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(quote)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func tap() {
        let now = Date()
        // A streak breaks after a pause, so casual taps never trigger it.
        taps = now.timeIntervalSince(lastTap) < Self.streakWindow ? taps + 1 : 1
        lastTap = now
        AmberHaptics.trigger(.selection)
        guard taps >= Self.tapsToReveal else {
            // Settle the mark back if the streak stops short.
            Task {
                try? await Task.sleep(for: .seconds(Self.streakWindow))
                if lastTap == now { taps = 0 }
            }
            return
        }
        taps = 0
        reveal()
    }

    private func reveal() {
        AmberHaptics.trigger(.rigidImpact)
        let next = NovelInkQuotes.quote(forDiscovery: discoveries)
        discoveries += 1
        if !reduceMotion { splash += 1 }
        withAnimation(.easeOut(duration: 0.2)) {
            quote = next
            typed = reduceMotion ? next.count : 0
        }
        guard !reduceMotion else { return }
        Task {
            for count in 1...next.count {
                guard quote == next else { return }
                typed = count
                try? await Task.sleep(for: .milliseconds(55))
            }
        }
    }
}

/// Copper ink drops that burst outward from the mark and fade.
private struct NovelInkSplash: View {
    let trigger: Int

    private struct Drop: Identifiable {
        let id: Int
        let angle: Double
        let distance: CGFloat
        let size: CGFloat
    }

    private static let drops: [Drop] = (0..<14).map { index in
        let angle = Double(index) / 14 * 2 * .pi + (index.isMultiple(of: 2) ? 0.2 : -0.15)
        return Drop(
            id: index,
            angle: angle,
            distance: CGFloat(38 + (index * 7) % 26),
            size: CGFloat(4 + (index * 5) % 7)
        )
    }

    var body: some View {
        ZStack {
            ForEach(Self.drops) { drop in
                Circle()
                    .fill(AmberTheme.accent)
                    .frame(width: drop.size, height: drop.size)
                    .keyframeAnimator(initialValue: SplashFrame(), trigger: trigger) { content, frame in
                        content
                            .offset(
                                x: cos(drop.angle) * drop.distance * frame.progress,
                                y: sin(drop.angle) * drop.distance * frame.progress + frame.fall
                            )
                            .scaleEffect(frame.scale)
                            .opacity(frame.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.progress) {
                            LinearKeyframe(0, duration: 0)
                            SpringKeyframe(1, duration: 0.45, spring: .bouncy)
                        }
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(0.2, duration: 0)
                            SpringKeyframe(1, duration: 0.25)
                            LinearKeyframe(0.6, duration: 0.6)
                        }
                        KeyframeTrack(\.fall) {
                            LinearKeyframe(0, duration: 0.4)
                            CubicKeyframe(18, duration: 0.5)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(trigger == 0 ? 0 : 1, duration: 0)
                            LinearKeyframe(1, duration: 0.5)
                            LinearKeyframe(0, duration: 0.4)
                        }
                    }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct SplashFrame {
        var progress: CGFloat = 0
        var scale: CGFloat = 0.2
        var fall: CGFloat = 0
        var opacity: Double = 0
    }
}
