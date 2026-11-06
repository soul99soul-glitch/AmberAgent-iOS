import SwiftUI
import UIKit

// MARK: - Persona pose (per state · per keyframe)

/// One keyframe of the built-in Canvas presets. All values are fractions of the medallion diameter
/// so the same drawing stays correct at any size.
struct AmberPersonaPose: Equatable {
    var tilt: CGFloat = 0
    /// Positive drops the head (nod); negative lifts it.
    var headDrop: CGFloat = 0
    var eyeOpen: CGFloat = 1
    var gazeX: CGFloat = 0
    var gazeY: CGFloat = 0
    /// Positive raises the ear tips, negative droops them.
    var earLift: CGFloat = 0
    /// 0…1 outward ear fall, used together with `earLift` for the blocked state.
    var earDroop: CGFloat = 0
    /// 0 = paw hidden, 1 = paw raised beside the cheek.
    var pawLift: CGFloat = 0
    var blush: CGFloat = 0

    /// Four keyframes per state, matching the generation prompt's row order.
    static func pose(for mood: AmberAgentPersonaMood, frame: Int) -> AmberPersonaPose {
        let index = max(0, min(3, frame))
        switch mood {
        case .idle:
            // calm gaze → half blink → closed breathing → eyes open with a small drift
            switch index {
            case 0: return AmberPersonaPose()
            case 1: return AmberPersonaPose(eyeOpen: 0.42)
            case 2: return AmberPersonaPose(headDrop: 0.012, eyeOpen: 0.06)
            default: return AmberPersonaPose(tilt: -0.035, gazeX: 0.03)
            }
        case .running:
            // lean in → review left → review right → determined nod
            switch index {
            case 0: return AmberPersonaPose(headDrop: -0.014)
            case 1: return AmberPersonaPose(tilt: -0.075, headDrop: -0.010, gazeX: -0.045)
            case 2: return AmberPersonaPose(tilt: 0.075, headDrop: -0.010, gazeX: 0.045)
            default: return AmberPersonaPose(headDrop: 0.026, eyeOpen: 0.80)
            }
        case .needsInput:
            // look up at you → head tilt → light wave → expectant gaze
            switch index {
            case 0: return AmberPersonaPose(headDrop: -0.030, eyeOpen: 1.05, blush: 0.18)
            case 1: return AmberPersonaPose(tilt: 0.105, gazeY: -0.010, blush: 0.22)
            case 2: return AmberPersonaPose(tilt: 0.060, eyeOpen: 0.82, pawLift: 1, blush: 0.26)
            default: return AmberPersonaPose(headDrop: -0.022, gazeY: -0.018, pawLift: 0.55, blush: 0.22)
            }
        case .blocked:
            // startled freeze → ears droop with a sigh → head in hands → cheering up
            switch index {
            case 0: return AmberPersonaPose(headDrop: -0.010, eyeOpen: 1.16)
            case 1: return AmberPersonaPose(headDrop: 0.020, eyeOpen: 0.46, earLift: -0.045, earDroop: 0.85)
            case 2: return AmberPersonaPose(tilt: -0.055, headDrop: 0.030, eyeOpen: 0.30, earLift: -0.032, earDroop: 1.0)
            default: return AmberPersonaPose(headDrop: -0.020, eyeOpen: 1.0, earLift: 0.018, earDroop: 0.15)
            }
        }
    }
}

// MARK: - Canvas presets

/// Built-in amber fox / amber crystal mascot. `frame` drives the state's four keyframes;
/// callers pass `0` when Reduce Motion is enabled.
struct AmberAgentPersonaCanvasView: View {
    let preset: AmberPersonaPreset
    let mood: AmberAgentPersonaMood
    let frame: Int
    let accentColor: Color

    var body: some View {
        switch preset {
        case .amberCrystal:
            crystalCanvas
        case .amberFox, .customPortrait:
            foxCanvas
        }
    }

    private var pose: AmberPersonaPose { .pose(for: mood, frame: frame) }

    private var foxCanvas: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let cx = w * 0.5
            let cy = h * 0.51 + h * pose.headDrop
            let eyeOpen = max(0.07, min(1.25, pose.eyeOpen))

            context.drawLayer { layer in
                layer.translateBy(x: cx, y: cy)
                layer.rotate(by: .radians(pose.tilt))
                layer.translateBy(x: -cx, y: -cy)

                for sign in [-1.0, 1.0] {
                    let s = CGFloat(sign)
                    let tip = CGPoint(
                        x: cx + s * (w * 0.25 + w * 0.07 * pose.earDroop),
                        y: cy + h * (-0.30 + 0.12 * pose.earDroop) - h * pose.earLift
                    )
                    var ear = Path()
                    ear.move(to: CGPoint(x: cx + s * w * 0.23, y: cy - h * 0.04))
                    ear.addQuadCurve(
                        to: tip,
                        control: CGPoint(
                            x: cx + s * w * 0.29,
                            y: cy + h * (-0.18 + 0.06 * pose.earDroop) - h * pose.earLift * 0.4
                        )
                    )
                    ear.addQuadCurve(
                        to: CGPoint(x: cx + s * w * 0.06, y: cy - h * 0.14),
                        control: CGPoint(x: cx + s * w * 0.14, y: cy - h * 0.26)
                    )
                    ear.closeSubpath()
                    layer.fill(ear, with: .color(accentColor))

                    var inner = Path()
                    inner.move(to: CGPoint(x: cx + s * w * 0.19, y: cy - h * 0.09))
                    inner.addLine(to: tip)
                    inner.addLine(to: CGPoint(x: cx + s * w * 0.10, y: cy - h * 0.14))
                    inner.closeSubpath()
                    layer.fill(inner, with: .color(AmberTheme.background.opacity(0.92)))
                }

                let headW = w * 0.48
                let headH = h * 0.38
                let headRect = CGRect(x: cx - headW * 0.5, y: cy - headH * 0.48, width: headW, height: headH)
                layer.fill(
                    Path(roundedRect: headRect, cornerRadius: headH * 0.46, style: .continuous),
                    with: .color(accentColor)
                )

                let cheekW = w * 0.39
                let cheekH = h * 0.20
                let cheekRect = CGRect(x: cx - cheekW * 0.5, y: cy - cheekH * 0.10, width: cheekW, height: cheekH)
                layer.fill(
                    Path(roundedRect: cheekRect, cornerRadius: cheekH * 0.48, style: .continuous),
                    with: .color(AmberTheme.background)
                )

                if pose.blush > 0 {
                    for sign in [-1.0, 1.0] {
                        let s = CGFloat(sign)
                        let blushRect = CGRect(
                            x: cx + s * w * 0.135 - w * 0.035,
                            y: cy + h * 0.055,
                            width: w * 0.07,
                            height: h * 0.035
                        )
                        layer.fill(
                            Path(ellipseIn: blushRect),
                            with: .color(AmberTheme.accentAmber.opacity(0.30 * pose.blush))
                        )
                    }
                }

                let eyeY = cy - h * 0.04 + h * pose.gazeY
                let eyeOffset = w * 0.095
                let eyeR = max(1.8, w * 0.036)
                let eyeH = max(1.1, eyeR * 2 * eyeOpen)

                for sign in [-1.0, 1.0] {
                    let ex = cx + CGFloat(sign) * eyeOffset + w * pose.gazeX
                    let rect = CGRect(x: ex - eyeR, y: eyeY - eyeH * 0.5, width: eyeR * 2, height: eyeH)
                    layer.fill(Path(ellipseIn: rect), with: .color(AmberTheme.foreground))
                    guard eyeOpen > 0.45 else { continue }
                    let specR = max(0.7, eyeR * 0.36)
                    layer.fill(
                        Path(ellipseIn: CGRect(
                            x: ex - eyeR * 0.35 + w * pose.gazeX * 0.4,
                            y: eyeY - eyeR * 0.45,
                            width: specR * 2,
                            height: specR * 2
                        )),
                        with: .color(.white.opacity(0.92))
                    )
                }

                let noseR = max(1.4, w * 0.023)
                layer.fill(
                    Path(ellipseIn: CGRect(
                        x: cx - noseR,
                        y: cy + h * 0.03 - noseR + h * pose.gazeY * 0.4,
                        width: noseR * 2,
                        height: noseR * 2
                    )),
                    with: .color(AmberTheme.foreground)
                )

                if pose.pawLift > 0.05 {
                    let pawW = w * 0.15
                    let pawH = h * 0.105
                    let center = CGPoint(x: cx + w * 0.30, y: cy + h * (0.13 - 0.05 * pose.pawLift))
                    layer.drawLayer { paw in
                        paw.translateBy(x: center.x, y: center.y)
                        paw.rotate(by: .radians(-0.42 + 0.30 * pose.pawLift))
                        paw.translateBy(x: -center.x, y: -center.y)
                        let rect = CGRect(
                            x: center.x - pawW * 0.5,
                            y: center.y - pawH * 0.5,
                            width: pawW,
                            height: pawH
                        )
                        paw.fill(
                            Path(roundedRect: rect, cornerRadius: pawH * 0.5, style: .continuous),
                            with: .color(accentColor.opacity(0.92))
                        )
                    }
                }
            }
        }
        .scaleEffect(1.16)
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }

    private var crystalCanvas: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let cx = w * 0.5
            let cy = h * 0.47 + h * pose.headDrop
            let pulse = CGFloat(1 + [-0.02, 0.015, 0.03, 0.0][max(0, min(3, frame))])
            let r = w * 0.25 * pulse
            let eyeOpen = max(0.08, min(1.25, pose.eyeOpen))

            context.drawLayer { layer in
                layer.translateBy(x: cx, y: cy)
                layer.rotate(by: .radians(pose.tilt))
                layer.translateBy(x: -cx, y: -cy)

                var gem = Path()
                gem.move(to: CGPoint(x: cx, y: cy - r * 1.15))
                gem.addLine(to: CGPoint(x: cx + r * 0.95, y: cy - r * 0.2))
                gem.addLine(to: CGPoint(x: cx + r * 0.65, y: cy + r * 0.95))
                gem.addLine(to: CGPoint(x: cx - r * 0.65, y: cy + r * 0.95))
                gem.addLine(to: CGPoint(x: cx - r * 0.95, y: cy - r * 0.2))
                gem.closeSubpath()
                layer.fill(gem, with: .color(accentColor))

                if mood == .blocked {
                    var crack = Path()
                    crack.move(to: CGPoint(x: cx - r * 0.20, y: cy - r * 0.62))
                    crack.addLine(to: CGPoint(x: cx + r * 0.02, y: cy - r * 0.18))
                    crack.addLine(to: CGPoint(x: cx - r * 0.16, y: cy + r * 0.16))
                    layer.stroke(crack, with: .color(AmberTheme.background.opacity(0.65)), lineWidth: max(0.8, w * 0.012))
                }

                let eyeR = max(1.7, w * 0.032)
                let eyeH = max(1.0, eyeR * 2 * eyeOpen)
                for sign in [-1.0, 1.0] {
                    let ex = cx + CGFloat(sign) * w * 0.075 + w * pose.gazeX
                    let ey = cy - h * 0.02 + h * pose.gazeY
                    layer.fill(
                        Path(ellipseIn: CGRect(x: ex - eyeR, y: ey - eyeH * 0.5, width: eyeR * 2, height: eyeH)),
                        with: .color(.white)
                    )
                }
            }
        }
        .scaleEffect(1.16)
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }

    private var diameter: CGFloat { ChatTopBarLayout.avatarDiameter }
}

// MARK: - Medallion (built-in presets + custom static / multi-frame, all four states)

struct AmberAgentPersonaMedallionView: View {
    let mood: AmberAgentPersonaMood
    var diameter: CGFloat = ChatTopBarLayout.avatarDiameter
    var presetOverride: AmberPersonaPreset? = nil
    var accentOverride: Color? = nil
    var storeOverride: AmberPersonaStore? = nil
    var showStagedPreview: Bool = false
    var reduceMotionOverride: Bool? = nil

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.amberIsUnderlyingSheetPresented) private var isUnderlyingSheetPresented

    private var store: AmberPersonaStore { storeOverride ?? AmberPersonaStore.shared }

    private var effectiveReduceMotion: Bool {
        if let reduceMotionOverride { return reduceMotionOverride }
        return systemReduceMotion || isUnderlyingSheetPresented
    }

    private var activePreset: AmberPersonaPreset {
        if showStagedPreview, store.hasPendingPreview {
            return .customPortrait
        }
        return presetOverride ?? store.preset
    }

    private var activeAnimationFrames: [UIImage] {
        if showStagedPreview, store.hasPendingPreview {
            return store.pendingFrames(for: mood)
        }
        if activePreset == .customPortrait, store.hasActiveMultiFrameAnimation {
            return store.frames(for: mood)
        }
        return []
    }

    private var activeStaticImage: UIImage? {
        if showStagedPreview, store.pendingPreviewKind == .staticImage, let preview = store.pendingPreviewImage {
            return preview
        }
        if showStagedPreview, store.hasPendingPreview, let first = activeAnimationFrames.first {
            return first
        }
        return store.customAvatarImage
    }

    private var accentColor: Color {
        if let accentOverride { return accentOverride }
        return mood == .blocked ? AmberTheme.accentRed : AmberTheme.accent
    }

    /// Deterministic frame selector for discrete multi-frame animation.
    /// Strictly returns frame `0` when `reduceMotion` is enabled or fewer than 2 frames exist.
    static func activeFrameIndex(
        at date: Date,
        frameCount: Int,
        frameIntervalMs: Int = 550,
        reduceMotion: Bool
    ) -> Int {
        guard frameCount > 1, !reduceMotion else { return 0 }
        let cycle: [Int]
        if frameCount == 2 {
            cycle = [0, 1]
        } else {
            let forward = Array(0..<frameCount)
            let backward = Array((1..<(frameCount - 1)).reversed())
            cycle = forward + backward
        }
        let intervalSeconds = Double(max(300, frameIntervalMs)) / 1000.0
        let step = Int(floor(max(0, date.timeIntervalSinceReferenceDate) / intervalSeconds))
        return cycle[step % cycle.count]
    }

    private var frameInterval: Double {
        Double(max(300, store.animationFrameIntervalMs)) / 1000.0
    }

    var body: some View {
        content
            .frame(width: diameter, height: diameter)
            .modifier(
                PersonaMedallionBackdropGlass(
                    diameter: diameter,
                    mood: mood,
                    accentColor: accentColor
                )
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch activePreset {
        case .customPortrait:
            let frames = activeAnimationFrames
            if frames.count > 1 {
                if effectiveReduceMotion {
                    portraitImageCircle(frames[0])
                } else {
                    TimelineView(.periodic(from: .now, by: frameInterval)) { context in
                        let index = Self.activeFrameIndex(
                            at: context.date,
                            frameCount: frames.count,
                            frameIntervalMs: store.animationFrameIntervalMs,
                            reduceMotion: false
                        )
                        portraitImageCircle(frames[index])
                    }
                }
            } else if let uiImage = activeStaticImage {
                portraitImageCircle(uiImage)
            } else {
                builtInCanvas
            }
        case .amberCrystal, .amberFox:
            builtInCanvas
        }
    }

    @ViewBuilder
    private var builtInCanvas: some View {
        // Built-in presets perform the same four keyframes per state; Reduce Motion pins frame 1.
        if effectiveReduceMotion {
            canvas(frame: 0)
        } else {
            TimelineView(.periodic(from: .now, by: frameInterval)) { context in
                let index = Self.activeFrameIndex(
                    at: context.date,
                    frameCount: AmberAgentPersonaMood.allCases.count,
                    frameIntervalMs: store.animationFrameIntervalMs,
                    reduceMotion: false
                )
                canvas(frame: index)
            }
        }
    }

    private func canvas(frame: Int) -> some View {
        AmberAgentPersonaCanvasView(
            preset: activePreset == .amberCrystal ? .amberCrystal : .amberFox,
            mood: mood,
            frame: frame,
            accentColor: accentColor
        )
        .frame(width: diameter, height: diameter)
    }

    private func portraitImageCircle(_ uiImage: UIImage) -> some View {
        Image(uiImage: uiImage)
            .resizable()
            .scaledToFill()
            .frame(width: max(1, diameter - 2), height: max(1, diameter - 2))
            .clipShape(Circle())
    }
}

/// Applies the medallion glass/material backdrop strictly behind the foreground avatar content (`content`),
/// preventing a sibling `Circle().glassEffect(...)` from compositing in front of and blurring the avatar.
private struct PersonaMedallionBackdropGlass: ViewModifier {
    let diameter: CGFloat
    let mood: AmberAgentPersonaMood
    let accentColor: Color

    private var baseBackdrop: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .overlay {
                Circle().fill(AmberTheme.glass.opacity(0.18))
            }
            .overlay {
                RadialGradient(
                    colors: [
                        accentColor.opacity(mood == .running || mood == .needsInput ? 0.16 : 0.09),
                        Color.clear,
                    ],
                    center: .init(x: 0.5, y: 0.45),
                    startRadius: 2,
                    endRadius: diameter * 0.46
                )
                .clipShape(Circle())
            }
    }

    private var borderOverlay: some View {
        Circle()
            .strokeBorder(
                mood == .blocked ? AmberTheme.accentRed.opacity(0.45) : AmberTheme.border.opacity(0.32),
                lineWidth: 0.75
            )
            .allowsHitTesting(false)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background { baseBackdrop }
                .glassEffect(.regular, in: Circle())
                .overlay { borderOverlay }
        } else {
            content
                .background { baseBackdrop }
                .overlay { borderOverlay }
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 3)
        }
    }
}
