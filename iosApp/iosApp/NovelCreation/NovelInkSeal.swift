import SwiftUI

/// What the collect sheet stamps after a successful collection. A new chapter
/// gets 「成章」; crossing a whole-book length milestone swaps in its own seal.
/// Revisions (append, replace) stamp only when they cross a milestone.
struct NovelInkSealStamp: Equatable {
    let glyphs: String
    let caption: String

    static let milestones: [(characters: Int, glyphs: String)] = [
        (10_000, "万字"),
        (50_000, "五万"),
        (100_000, "十万"),
        (200_000, "廿万"),
        (300_000, "卅万"),
        (500_000, "五十万"),
        (1_000_000, "百万")
    ]

    static func after(
        collecting target: NovelCollectionTarget,
        previousTotal: Int,
        newTotal: Int,
        nextChapterOrdinal: Int
    ) -> NovelInkSealStamp? {
        if let milestone = milestones.last(where: { previousTotal < $0.characters && newTotal >= $0.characters }) {
            // 50,000 words is the National Novel Writing Month finish line.
            let caption = milestone.characters == 50_000
                ? IOSAppLocalization.string("全书突破 5 万字，写作月的终点线", defaultValue: "全书突破 5 万字，写作月的终点线")
                : IOSAppLocalization.formatted(
                    "全书突破 %lld 万字",
                    defaultValue: "全书突破 %lld 万字",
                    arguments: [milestone.characters / 10_000]
                )
            return NovelInkSealStamp(glyphs: milestone.glyphs, caption: caption)
        }
        guard case .createNextChapter = target else { return nil }
        return NovelInkSealStamp(
            glyphs: "成章",
            caption: IOSAppLocalization.formatted(
                "第 %lld 章已收入正文",
                defaultValue: "第 %lld 章已收入正文",
                arguments: [nextChapterOrdinal]
            )
        )
    }
}

/// A vermilion seal that slams onto the page, bleeds a ring of ink, and settles.
/// Under Reduce Motion it simply fades in.
struct NovelInkSealView: View {
    let stamp: NovelInkSealStamp

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = false

    private static let vermilion = AmberTheme.accentRed
    /// Fixed so the cut-out glyphs stay paper-white in dark mode too.
    private static let paper = Color(white: 0.97)

    var body: some View {
        VStack(spacing: 14) {
            if reduceMotion {
                seal
                    .rotationEffect(.degrees(-5))
                    .opacity(landed ? 1 : 0)
            } else {
                animatedSeal
            }

            Text(stamp.caption)
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                // Solid paper: the caption sits over the sheet's own text.
                .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                .padding(.horizontal, 24)
                .opacity(landed ? 1 : 0)
                .offset(y: landed || reduceMotion ? 0 : 6)
                .animation(.easeOut(duration: 0.25).delay(reduceMotion ? 0 : 0.2), value: landed)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stamp.caption)
        .onAppear {
            AccessibilityNotification.Announcement(stamp.caption).post()
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.2)) { landed = true }
            } else {
                landed = true
                AmberHaptics.trigger(.rigidImpact)
            }
        }
    }

    private var animatedSeal: some View {
        ZStack {
            Circle()
                .fill(Self.vermilion.opacity(0.22))
                .frame(width: 120, height: 120)
                .blur(radius: 10)
                .keyframeAnimator(initialValue: BleedFrame(), trigger: landed) { content, frame in
                    content.scaleEffect(frame.scale).opacity(frame.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        LinearKeyframe(0.4, duration: 0.16)
                        SpringKeyframe(1.35, duration: 0.5, spring: .smooth)
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(0, duration: 0.16)
                        LinearKeyframe(1, duration: 0.08)
                        LinearKeyframe(0, duration: 0.55)
                    }
                }

            seal
                .keyframeAnimator(initialValue: SlamFrame(), trigger: landed) { content, frame in
                    content
                        .scaleEffect(frame.scale)
                        .rotationEffect(.degrees(frame.rotation))
                        .opacity(frame.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        CubicKeyframe(0.9, duration: 0.16)
                        SpringKeyframe(1, duration: 0.4, spring: .bouncy)
                    }
                    KeyframeTrack(\.rotation) {
                        CubicKeyframe(-7, duration: 0.16)
                        SpringKeyframe(-5, duration: 0.4)
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(1, duration: 0.1)
                    }
                }
        }
    }

    /// 白文印: paper-colored glyphs cut out of a vermilion block, read top to bottom.
    private var seal: some View {
        VStack(spacing: 0) {
            ForEach(Array(stamp.glyphs.enumerated()), id: \.offset) { _, glyph in
                Text(String(glyph))
                    .font(.system(size: stamp.glyphs.count > 2 ? 20 : 30, weight: .heavy, design: .serif))
            }
        }
        // Three stacked CJK lines sit ~2.5pt low in the line boxes (measured 10pt
        // above vs 5pt below); lift them back to the optical center.
        .offset(y: stamp.glyphs.count > 2 ? -2.5 : 0)
        .foregroundStyle(Self.paper)
        .frame(width: 76, height: 92)
        .background(Self.vermilion, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Self.paper.opacity(0.85), lineWidth: 1.5)
                .padding(5)
        }
        .shadow(color: Self.vermilion.opacity(0.35), radius: 8, y: 3)
    }

    private struct SlamFrame {
        var scale: CGFloat = 2.2
        var rotation: Double = -16
        var opacity: Double = 0
    }

    private struct BleedFrame {
        var scale: CGFloat = 0.4
        var opacity: Double = 0
    }
}
