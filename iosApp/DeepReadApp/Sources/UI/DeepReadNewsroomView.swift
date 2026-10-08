import SwiftUI

/// Generation-in-progress page: stage rail, a type tray setting the title in lead, and rotating desk notes.
struct DeepReadNewsroomView: View {
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
        // Centered when it fits; scrolls in landscape or at large text sizes.
        ViewThatFits(in: .vertical) {
            desk(stage)
            ScrollView { desk(stage) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage.headline)。\(progressLabel ?? "")")
    }

    private func desk(_ stage: DeepReadNewsroomStage) -> some View {
        TimelineView(.periodic(from: start, by: 0.3)) { context in
            let tick = Int(context.date.timeIntervalSince(start) / 0.3)
            VStack(spacing: 28) {
                rail(stage)
                VStack(spacing: 10) {
                    Image(systemName: stage.symbol)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(DeepReadPalette.accent)
                        .symbolEffect(.breathe, isActive: !reduceMotion)
                        .contentTransition(.symbolEffect(.replace))
                    Text(stage.headline)
                        .font(.system(.title2, design: .serif).weight(.semibold))
                        .contentTransition(.opacity)
                }
                .animation(.snappy, value: stage)
                typeTray(tick: tick)
                let note = (tick / 14) % Self.notes.count
                ZStack {
                    Text(Self.notes[note])
                        .font(.system(.callout, design: .serif)).italic()
                        .foregroundStyle(DeepReadPalette.muted)
                        .lineLimit(2, reservesSpace: true)
                        .id(note)
                        .transition(reduceMotion ? .opacity : .push(from: .bottom).combined(with: .opacity))
                }
                .clipped()
                .animation(.easeInOut(duration: 0.5), value: note)
                Text("可以离开此页面，稍后在阅读库查看进度。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }

    private func rail(_ stage: DeepReadNewsroomStage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(DeepReadNewsroomStage.allCases, id: \.self) { item in
                if item != .interview {
                    Capsule().fill(DeepReadPalette.rule).frame(height: 2)
                        .overlay(alignment: .leading) {
                            Capsule().fill(DeepReadPalette.accent).frame(height: 2)
                                .scaleEffect(x: item.rawValue <= stage.rawValue ? 1 : 0, anchor: .leading)
                        }
                        .padding(.top, 16) // centered on the 34pt node, independent of label size
                }
                VStack(spacing: 6) {
                    ZStack {
                        Circle().fill(item.rawValue < stage.rawValue ? DeepReadPalette.accent : DeepReadPalette.card)
                        Circle().strokeBorder(item.rawValue <= stage.rawValue ? DeepReadPalette.accent : DeepReadPalette.rule, lineWidth: 1.5)
                        Image(systemName: item.rawValue < stage.rawValue ? "checkmark" : item.symbol)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(item.rawValue < stage.rawValue ? DeepReadPalette.paper
                                : item == stage ? DeepReadPalette.accent : DeepReadPalette.muted)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .frame(width: 34, height: 34)
                    .background {
                        if item == stage && !reduceMotion {
                            Circle().stroke(DeepReadPalette.accent.opacity(0.5), lineWidth: 2)
                                .phaseAnimator([false, true]) { ring, out in
                                    ring.scaleEffect(out ? 1.55 : 1).opacity(out ? 0 : 1)
                                } animation: { out in out ? .easeOut(duration: 1.2) : .linear(duration: 0.01) }
                        }
                    }
                    Text(item.title).font(.caption2.weight(item == stage ? .bold : .regular))
                        .foregroundStyle(item.rawValue <= stage.rawValue ? DeepReadPalette.ink : DeepReadPalette.muted)
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
                        .strokeBorder(DeepReadPalette.rule, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    if index < placed {
                        RoundedRectangle(cornerRadius: 5).fill(DeepReadPalette.ink)
                            .overlay(Text(String(glyph)).font(.system(size: 17, weight: .bold, design: .serif))
                                .foregroundStyle(DeepReadPalette.paper))
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

/// Full-screen "approved for press" moment when a run finishes while the reader is watching.
struct DeepReadPressMoment: View {
    let inscription: String
    let caption: String
    @State private var slam = 0
    @State private var captionShown = false

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                DeepReadInkStamp(text: inscription, size: 128)
                    .modifier(DeepReadStampSlam(trigger: 0))
                Text(caption)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(DeepReadPalette.ink)
                    .opacity(captionShown ? 1 : 0)
                    .offset(y: captionShown ? 0 : 8)
            }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: slam)
        .onAppear {
            slam += 1
            withAnimation(.easeOut(duration: 0.4).delay(0.3)) { captionShown = true }
        }
        .accessibilityElement(children: .combine)
    }
}
