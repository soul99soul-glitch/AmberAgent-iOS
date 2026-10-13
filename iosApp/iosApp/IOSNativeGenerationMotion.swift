import SwiftUI

/// A status decoration, driven by the caller's real running state.
struct IOSGenerationActivityIndicator: View {
    var isActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Image(systemName: "circle.grid.2x2.fill")
            .font(.system(size: 12, weight: .medium))
            .symbolEffect(.variableColor.iterative, options: .repeating,
                          isActive: isActive && !reduceMotion && scenePhase == .active)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

private struct IOSNativeGenerationReveal: ViewModifier {
    let key: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var phase: Phase = .pending
    @State private var outline: CGFloat = 0

    private enum Phase { case pending, drawing, revealed }

    private var canAnimate: Bool { key != nil && !reduceMotion }

    func body(content: Content) -> some View {
        let needsReveal = key.map { !ChatLiveEntranceRegistry.hasRevealed($0) } ?? false
        let hidden = canAnimate && (phase == .drawing ||
            (phase == .pending && needsReveal))
        content
            .opacity(hidden ? 0 : 1)
            .overlay {
                if canAnimate && phase != .revealed {
                    ZStack {
                        Canvas { context, size in
                            var dots = Path()
                            for x in stride(from: CGFloat(6), to: size.width, by: 14) {
                                for y in stride(from: CGFloat(6), to: size.height, by: 14) {
                                    dots.addEllipse(in: CGRect(x: x, y: y, width: 1.6, height: 1.6))
                                }
                            }
                            context.fill(dots, with: .color(AmberTheme.muted.opacity(0.22)))
                        }
                        RoundedRectangle(cornerRadius: 8)
                            .trim(from: 0, to: outline)
                            .stroke(AmberTheme.muted.opacity(0.65), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 4]))
                    }
                    .opacity(hidden ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
                }
            }
            .task(id: canAnimate) {
                guard phase == .pending else { return }
                guard canAnimate, let key, ChatLiveEntranceRegistry.claim(key) else {
                    phase = .revealed
                    return
                }
                phase = .drawing
                withAnimation(.easeOut(duration: 0.3)) { outline = 1 }
                do { try await Task.sleep(for: .milliseconds(180)) }
                catch { phase = .revealed; return }
                withAnimation(.easeOut(duration: 0.24)) { phase = .revealed }
            }
            .onChange(of: scenePhase) { _, next in
                if next == .background { phase = .revealed }
            }
    }
}

extension View {
    /// Only live, received elements have a key; completed/history cards stay immediate.
    func nativeGenerationReveal(key: String?) -> some View {
        modifier(IOSNativeGenerationReveal(key: key.map { "native-generation:\($0)" }))
    }
}
