import AppKit
import SwiftUI

/// The Amber mark. Breathes softly on the empty state; five quick taps release a drop of resin
/// that falls and settles — a small reward for the curious.
struct DesktopAmberMark: View {
    let size: CGFloat
    @Binding var taps: Int
    var breathes = false
    @State private var glow = false
    @State private var drop = false
    @State private var wobble = false
    @State private var lastTap = Date.distantPast

    var body: some View {
        Group {
            if let nsImage = NSImage(named: "AmberMark") {
                Image(nsImage: nsImage).resizable().interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            } else {
                DesktopAmberEmblem(size: size)
            }
        }
        .shadow(color: DesktopTheme.honey.opacity(breathes && glow ? 0.85 : 0.25), radius: breathes ? size * 0.35 : size * 0.14, y: size * 0.05)
        .rotationEffect(.degrees(wobble ? -8 : 0), anchor: .bottom)
            .overlay(alignment: .bottom) {
                Circle()
                    .fill(RadialGradient(colors: [DesktopTheme.accent, DesktopTheme.honey], center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.12))
                    .frame(width: size * 0.18, height: size * 0.22)
                    .offset(y: drop ? size * 1.4 : -size * 0.2)
                    .scaleEffect(drop ? 1 : 0.4)
                    .opacity(drop ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onAppear {
                guard breathes else { return }
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { glow = true }
            }
            .onTapGesture {
                taps = Date().timeIntervalSince(lastTap) < 0.6 ? taps + 1 : 1
                lastTap = Date()
                withAnimation(.spring(response: 0.18, dampingFraction: 0.3)) { wobble = true }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5).delay(0.12)) { wobble = false }
                if taps >= 5 {
                    taps = 0
                    drop = false
                    withAnimation(.easeIn(duration: 0.9)) { drop = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { drop = false }
                }
            }
            .accessibilityHidden(true)
    }
}

/// Messages rise in once, the first time they appear.
struct DesktopRiseIn: ViewModifier {
    @State private var shown = false
    let enabled: Bool
    func body(content: Content) -> some View {
        content
            .opacity(shown || !enabled ? 1 : 0)
            .offset(y: shown || !enabled ? 0 : 12)
            .onAppear {
                guard enabled, !shown else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { shown = true }
            }
    }
}

/// While a reply streams in, a soft Claude Desktop warm-gray shimmer travels along its leading edge.
struct DesktopStreamingEdge: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = 0
    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            if active {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(LinearGradient(colors: [.clear, DesktopTheme.inkTertiary.opacity(0.38), .clear], startPoint: .top, endPoint: .bottom))
                        .frame(width: 1.5, height: min(proxy.size.height, max(24, proxy.size.height * 0.35)))
                        // Travels the full height and back, easing at both ends, forever.
                        .offset(y: phase * max(0, proxy.size.height - max(24, proxy.size.height * 0.35)))
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { phase = 1 }
                        }
                }
                .frame(width: 1.5)
                .offset(x: -16)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: active)
    }
}

/// Segmented switcher: a paper chip slides under the chosen option (replaces the system segmented picker,
/// which jumps without motion and paints a solid accent block).
struct DesktopSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var expands = false
    @Namespace private var chip
    @State private var hovered: Value?
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: 13, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? DesktopTheme.ink : (hovered == option.value ? DesktopTheme.inkSecondary : DesktopTheme.inkTertiary))
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: expands ? .infinity : nil)
                        .frame(height: 26)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(DesktopTheme.card)
                                    .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DesktopTheme.hairline))
                                    .matchedGeometryEffect(id: "chip", in: chip)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? option.value : (hovered == option.value ? nil : hovered) }
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.hairline))
        .opacity(enabled ? 1 : 0.5)
        .fixedSize(horizontal: !expands, vertical: true)
    }
}

/// Tab content swap: the incoming page drifts in from the side of the chosen tab.
struct DesktopTabTransition: ViewModifier {
    let forward: Bool
    func body(content: Content) -> some View {
        content.transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(x: forward ? 14 : -14)),
            removal: .opacity))
    }
}

/// Live strip above the composer while a council / sub-agent run started from the composer works.
struct DesktopCollaborationProgress: View {
    let run: DesktopCollaborationRun
    let onOpen: () -> Void
    let onStop: () -> Void

    private var active: DesktopCollaborationOutput? { run.outputs.last { $0.status == .running } }
    private var done: Int { run.outputs.filter { $0.status.isTerminal }.count }

    var body: some View {
        HStack(spacing: 12) {
            DesktopPulse()
            VStack(alignment: .leading, spacing: 2) {
                Text(run.isCouncil ? "模型议会进行中" : "子代理调研中")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(DesktopTheme.ink)
                Text(active.map { "\($0.name) 正在发言" } ?? (run.outputs.isEmpty ? "主持人正在安排席位…" : "正在综合结论…"))
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkSecondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: active?.id)
            }
            Spacer(minLength: 8)
            if !run.outputs.isEmpty {
                Text("\(done)/\(run.outputs.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(DesktopTheme.inkTertiary)
            }
            Button("查看", action: onOpen).buttonStyle(.desktopActionPill)
            Button("停止", action: onStop).buttonStyle(.desktopActionPill)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 10))
        .background(DesktopTheme.glow(RoundedRectangle(cornerRadius: 10)))
    }
}

/// Streaming text: characters past `settled` fade (and lift 3pt) in over `duration`. Glyphs already shown draw as-is,
/// so only the arriving tail animates and nothing earlier flickers.
struct DesktopStreamingFade: TextRenderer, Animatable {
    /// Number of characters that were visible before this update.
    var settled: Int
    /// 0 → 1 as the new tail appears.
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let total = layout.reduce(0) { lines, line in lines + line.reduce(0) { $0 + $1.count } }
        let tail = max(1, total - settled)
        var index = 0
        for line in layout {
            for run in line {
                for glyph in run {
                    let position = index
                    index += 1
                    guard position >= settled else { context.draw(glyph); continue }
                    // Stagger across the tail so it washes in left to right rather than all at once.
                    let local = min(1, max(0, progress * 1.6 - Double(position - settled) / Double(tail) * 0.6))
                    var copy = context
                    copy.opacity = local
                    copy.translateBy(x: 0, y: (1 - local) * 3)
                    copy.draw(glyph)
                }
            }
        }
    }
}

/// Applies the fade to a paragraph-like Text while its message streams; static otherwise.
struct DesktopStreamingTextModifier: ViewModifier {
    let text: String
    let active: Bool
    @State private var settled = 0
    @State private var progress = 1.0
    @State private var shown = ""

    func body(content: Content) -> some View {
        content
            .textRenderer(DesktopStreamingFade(settled: active ? settled : .max, progress: active ? progress : 1))
            .onChange(of: text, initial: true) { old, new in
                guard active, new.count > shown.count, new.hasPrefix(shown) else {
                    shown = new; settled = Self.visibleCount(new); progress = 1; return
                }
                // Boundary in rendered characters (markdown markers removed, a formula draws as one image).
                settled = Self.visibleCount(shown)
                shown = new
                progress = 0
                withAnimation(.easeOut(duration: 0.35)) { progress = 1 }
            }
    }
}

extension DesktopStreamingTextModifier {
    @MainActor static func visibleCount(_ source: String) -> Int {
        DesktopMathTokenizer.inline(source).reduce(0) { count, segment in
            switch segment {
            case .text(let value): count + DesktopMarkdownInline.parse(value).characters.filter { !$0.isNewline }.count
            case .formula: count + 1
            }
        }
    }
}

extension View {
    func desktopStreamingText(_ text: String, active: Bool) -> some View {
        modifier(DesktopStreamingTextModifier(text: text, active: active))
    }
}

/// Claude Desktop style soft warm-gray shimmer across active thinking/status labels:
/// a gentle luminance wave that never glares or changes color saturation.
struct DesktopSoftShimmer: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -0.6

    func body(content: Content) -> some View {
        if active {
            content
                .overlay {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, DesktopTheme.ink.opacity(0.45), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(36, proxy.size.width * 0.55))
                        .offset(x: phase * proxy.size.width * 1.6)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    phase = -0.6
                    withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) {
                        phase = 1.2
                    }
                }
        } else {
            content
        }
    }
}

/// Thinking card: a fixed-height window while it streams (growth scrolls inside, never pushes the answer),
/// softly folds when the answer begins, and toggles with an eased height change.
struct DesktopReasoningCard: View {
    let reasoning: String
    let thinking: Bool
    let streaming: Bool
    let autoExpand: Bool
    let defaultExpanded: Bool
    let font: Font
    /// Owned by the transcript per message, so the choice survives the row being swapped for a placeholder.
    @Binding var expanded: Bool?
    @State private var hovering = false

    private var isExpanded: Bool { expanded ?? (thinking ? autoExpand : defaultExpanded) }
    private var maxHeight: CGFloat { streaming ? 180 : 320 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.28)) { expanded = !isExpanded }
            } label: {
                HStack(spacing: 6) {
                    DesktopReasoningGlyph(thinking: thinking)
                    Text(thinking ? "正在思考…" : "思考过程")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(hovering || isExpanded ? DesktopTheme.inkSecondary : DesktopTheme.inkTertiary)
                        .modifier(DesktopSoftShimmer(active: thinking))
                        .contentTransition(.opacity)
                    Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering || isExpanded ? DesktopTheme.hover : DesktopTheme.paperDeep.opacity(0.65))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(DesktopTheme.hairline, lineWidth: 0.75)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(isExpanded ? "收起思考过程" : "展开思考过程")

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    Text(streaming ? Self.visibleTail(reasoning) : reasoning)
                        .font(font)
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .id("reasoning-end")
                }
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.never)
                .frame(maxHeight: maxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                        .init(color: .black, location: 0.92), .init(color: streaming ? .clear : .black, location: 1)],
                        startPoint: .top, endPoint: .bottom)
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(DesktopTheme.hairlineStrong).frame(width: 1) }
                .padding(.top, 4)
                .onChange(of: reasoning) { if streaming { proxy.scrollTo("reasoning-end", anchor: .bottom) } }
            }
            // Height collapses to zero instead of removing the view, so folding is an eased ramp, not a jump.
            .frame(maxHeight: isExpanded ? .infinity : 0, alignment: .top)
            .opacity(isExpanded ? 1 : 0)
            .clipped()
        }
        .onChange(of: thinking) { _, now in
            // Answer started: fold softly (unless the user chose explicitly).
            if !now, autoExpand, expanded == nil, !defaultExpanded {
                withAnimation(.smooth(duration: 0.32)) { expanded = false }
            }
        }
    }
}

extension DesktopReasoningCard {
    /// While streaming, the card is a 180pt bottom-anchored window that re-scrolls to the end on every chunk, so only
    /// the tail can ever be seen. Laying out just the tail keeps each chunk's cost flat instead of growing with the
    /// whole chain of thought; the full text returns when the stream ends. Cuts at a line break so wrapping matches.
    static func visibleTail(_ reasoning: String, limit: Int = 2400) -> String {
        guard reasoning.count > limit else { return reasoning }
        let tail = reasoning.suffix(limit)
        guard let newline = tail.firstIndex(of: "\n") else { return String(tail) }
        return String(tail[tail.index(after: newline)...])
    }
}

/// Follow-the-tail motor. Content may grow in bursts; the view eases toward the bottom with a critically damped
/// spring from *its own last written offset* (never from a compensated live value), and the target only ever moves
/// down while streaming, so estimation dips can't drag the view back. User scrolling stops it immediately.
@MainActor final class DesktopScrollFollower {
    struct Geometry: Equatable { var offset: CGFloat; var bottom: CGFloat }

    private var target: CGFloat = 0
    private var virtual: CGFloat?
    private var velocity: CGFloat = 0
    private var timer: Timer?
    private var write: ((CGFloat) -> Void)?
    private var lastTick = Date()

    func update(target newTarget: CGFloat, actual: CGFloat, following: Bool, streaming: Bool, write: @escaping (CGFloat) -> Void) {
        guard following else { stop(); return }
        self.write = write
        // Fresh start: seed from where the view really is; monotonic only while a run is engaged.
        if virtual == nil { virtual = actual; velocity = 0; target = newTarget }
        else {
            target = streaming ? max(target, newTarget) : newTarget
            // Something else already advanced the view (anchor, explicit scroll): never write backwards from it.
            if let current = virtual, actual > current + 0.5 { virtual = actual }
        }
        guard timer == nil, abs(target - (virtual ?? actual)) > 0.5 else { return }
        lastTick = Date()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate(); timer = nil
        virtual = nil; velocity = 0; target = 0
    }

    private func tick() {
        guard let current = virtual, let write else { stop(); return }
        let now = Date()
        let dt = min(1.0 / 30, max(1.0 / 240, now.timeIntervalSince(lastTick)))
        lastTick = now
        // Critically damped: ω = 2/τ with τ ≈ 80ms — catches bursts quickly but never overshoots.
        let omega: CGFloat = 2 / 0.08
        let distance = target - current
        let acceleration = omega * omega * distance - 2 * omega * velocity
        velocity += acceleration * dt
        var next = current + velocity * dt
        if (target - next) * distance < 0 { next = target; velocity = 0 }
        if abs(target - next) < 0.5, abs(velocity) < 5 {
            next = target
            write(next)
            timer?.invalidate(); timer = nil
            virtual = next; velocity = 0
            return
        }
        virtual = next
        write(next)
    }
}
