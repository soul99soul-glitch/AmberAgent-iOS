import SwiftUI

/// Generation-in-progress page in AmberTheme colors: stage rail, a type tray setting the
/// title in lead, and rotating desk notes. Stages follow the launcher's real progress labels.
struct IOSDeepReadNewsroomView: View {
    let title: String
    let progressLabel: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now

    private static let notes = [
        "好的报道，始于多问一句。",
        "事实是神圣的，评论是自由的。",
        "把来源摆上桌，再下结论。",
        "慢一点，才能读得深一点。",
        "区分事实与观点，是阅读的第一步。",
    ]

    var body: some View {
        let stage = DeepReadNewsroomStage.from(label: progressLabel)
        TimelineView(.periodic(from: start, by: 0.3)) { context in
            let tick = Int(context.date.timeIntervalSince(start) / 0.3)
            VStack(spacing: 28) {
                rail(stage)
                VStack(spacing: 10) {
                    Image(systemName: stage.symbol)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(AmberTheme.accent)
                        .symbolEffect(.breathe, isActive: !reduceMotion)
                        .contentTransition(.symbolEffect(.replace))
                    Text(stage.headline)
                        .font(.system(.title2, design: .serif).weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .contentTransition(.opacity)
                    if let progressLabel {
                        Text(progressLabel)
                            .font(.footnote)
                            .foregroundStyle(AmberTheme.muted)
                            .contentTransition(.numericText())
                    }
                }
                .animation(.snappy, value: stage)
                .animation(.snappy, value: progressLabel)
                typeTray(tick: tick)
                let note = (tick / 14) % Self.notes.count
                ZStack {
                    Text(Self.notes[note])
                        .font(.system(.callout, design: .serif)).italic()
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(2, reservesSpace: true)
                        .id(note)
                        .transition(reduceMotion ? .opacity : .push(from: .bottom).combined(with: .opacity))
                }
                .clipped()
                .animation(.easeInOut(duration: 0.5), value: note)
                Text("可以离开此页面，稍后在深度阅读历史查看进度。")
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted2)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 22)
            .padding(.vertical, 28)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage.headline)。\(progressLabel ?? "")")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func rail(_ stage: DeepReadNewsroomStage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(DeepReadNewsroomStage.allCases, id: \.self) { item in
                if item != .interview {
                    Capsule().fill(AmberTheme.borderSoft).frame(height: 2)
                        .overlay(alignment: .leading) {
                            Capsule().fill(AmberTheme.accent).frame(height: 2)
                                .scaleEffect(x: item.rawValue <= stage.rawValue ? 1 : 0, anchor: .leading)
                        }
                        .padding(.top, 16) // centered on the 34pt node, independent of label size
                }
                VStack(spacing: 6) {
                    ZStack {
                        Circle().fill(item.rawValue < stage.rawValue ? AmberTheme.accent : AmberTheme.surface)
                        Circle().strokeBorder(item.rawValue <= stage.rawValue ? AmberTheme.accent : AmberTheme.border, lineWidth: 1.5)
                        Image(systemName: item.rawValue < stage.rawValue ? "checkmark" : item.symbol)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(item.rawValue < stage.rawValue ? Color.white
                                : item == stage ? AmberTheme.accent : AmberTheme.muted)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .frame(width: 34, height: 34)
                    .background {
                        if item == stage && !reduceMotion {
                            Circle().stroke(AmberTheme.accent.opacity(0.5), lineWidth: 2)
                                .phaseAnimator([false, true]) { ring, out in
                                    ring.scaleEffect(out ? 1.55 : 1).opacity(out ? 0 : 1)
                                } animation: { out in out ? .easeOut(duration: 1.2) : .linear(duration: 0.01) }
                        }
                    }
                    Text(item.title)
                        .font(.caption2.weight(item == stage ? .bold : .regular))
                        .foregroundStyle(item.rawValue <= stage.rawValue ? AmberTheme.foreground : AmberTheme.muted)
                }
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: stage)
        .accessibilityHidden(true)
    }

    /// The title's characters drop into a type case one by one, then the tray resets.
    private func typeTray(tick: Int) -> some View {
        let glyphs = Array(title.filter { !$0.isWhitespace && !$0.isPunctuation }.prefix(10))
        let cycle = glyphs.count + 6
        let placed = reduceMotion ? glyphs.count : min(tick % max(cycle, 1), glyphs.count)
        return HStack(spacing: 5) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { index, glyph in
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(AmberTheme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    if index < placed {
                        RoundedRectangle(cornerRadius: 5).fill(AmberTheme.foreground)
                            .overlay(Text(String(glyph)).font(.system(size: 17, weight: .bold, design: .serif))
                                .foregroundStyle(AmberTheme.background))
                            .shadow(color: .black.opacity(0.18), radius: 2, y: 2)
                            .transition(.asymmetric(insertion: .offset(y: -28).combined(with: .opacity), removal: .opacity))
                    }
                }
                .frame(maxWidth: 28)
                .frame(height: 32)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.58), value: placed)
        .accessibilityHidden(true)
    }
}

/// "Approved for press" moment when a run finishes while the reader is watching.
struct IOSDeepReadPressMoment: View {
    let inscription: String
    let caption: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var fire = 0
    @State private var captionShown = false

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                stamp
                    .opacity(fire == 0 ? 0 : 1)
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
                Text(caption)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(AmberTheme.foreground)
                    .opacity(captionShown ? 1 : 0)
                    .offset(y: captionShown ? 0 : 8)
            }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: fire)
        .onAppear {
            fire += 1
            withAnimation(.easeOut(duration: 0.4).delay(0.3)) { captionShown = true }
        }
        .accessibilityElement(children: .combine)
    }

    /// Two characters set vertically inside a double frame, like a traditional seal.
    private var stamp: some View {
        let size: CGFloat = 128
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.14).stroke(AmberTheme.accent, lineWidth: size * 0.07)
            RoundedRectangle(cornerRadius: size * 0.08).stroke(AmberTheme.accent, lineWidth: size * 0.02)
                .padding(size * 0.1)
            Text(verbatim: inscription.map(String.init).joined(separator: "\n"))
                .font(.system(size: size * 0.3, weight: .heavy, design: .serif))
                .foregroundStyle(AmberTheme.accent)
                .multilineTextAlignment(.center)
                .lineSpacing(-size * 0.04)
                .fixedSize()
        }
        .frame(width: size, height: size)
        .opacity(0.88)
        .blendMode(colorScheme == .dark ? .normal : .multiply)
        .accessibilityLabel("印章：\(inscription)")
    }

    private struct StampFrame {
        var scale = 1.0
        var angle = -10.0
        var opacity = 1.0
    }
}
