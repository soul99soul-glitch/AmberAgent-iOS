import CoreGraphics
import Observation
import QuartzCore
import SwiftUI
import UIKit
import XCTest
@testable import iosApp

@MainActor
final class VisualMotionPerformanceTests: XCTestCase {
    private let designDefaultsKey = "app.amber.ios.theme.design"
    private var runtime: AmberThemeRuntime { .shared }
    private var savedRuntimeDocument: AmberThemePackDocument?
    private var savedDesignData: Data?
    private var savedThemeID: String?
    private var savedThemeName: String?

    override func setUp() async throws {
        try await super.setUp()
        runtime.discardTryOn()
        savedRuntimeDocument = AmberThemePackTransfer.document(from: runtime)
        savedDesignData = UserDefaults.standard.data(forKey: designDefaultsKey)
        savedThemeID = runtime.selectedThemeID
        savedThemeName = runtime.selectedThemeName
    }

    override func tearDown() async throws {
        runtime.discardTryOn()
        if let savedRuntimeDocument {
            try? runtime.apply(savedRuntimeDocument)
        }
        runtime.rememberThemeIdentity(id: savedThemeID, displayName: savedThemeName)
        if let savedDesignData {
            UserDefaults.standard.set(savedDesignData, forKey: designDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: designDefaultsKey)
        }
        try await super.tearDown()
    }

    // MARK: - 1. AmberTheme cached snapshot tokens & Observation

    func testAmberThemeTokensPreserveValueEqualityTraitColorsAndObservation() {
        runtime.apply(AmberThemeRuntime.Paper.paper)
        runtime.apply(AmberAccentOption.terracotta)

        // Value equality must hold across consecutive reads (regression check for
        // allocating a fresh UIDynamicProviderColor closure on every getter access).
        XCTAssertEqual(AmberTheme.background, AmberTheme.background)
        XCTAssertEqual(AmberTheme.elevatedPanel, AmberTheme.elevatedPanel)
        XCTAssertEqual(AmberTheme.surface, AmberTheme.surface)
        XCTAssertEqual(AmberTheme.surface2, AmberTheme.surface2)
        XCTAssertEqual(AmberTheme.surfaceElevated, AmberTheme.surfaceElevated)
        XCTAssertEqual(AmberTheme.foreground, AmberTheme.foreground)
        XCTAssertEqual(AmberTheme.foreground2, AmberTheme.foreground2)
        XCTAssertEqual(AmberTheme.muted, AmberTheme.muted)
        XCTAssertEqual(AmberTheme.muted2, AmberTheme.muted2)
        XCTAssertEqual(AmberTheme.border, AmberTheme.border)
        XCTAssertEqual(AmberTheme.borderSoft, AmberTheme.borderSoft)
        XCTAssertEqual(AmberTheme.glass, AmberTheme.glass)
        XCTAssertEqual(AmberTheme.glassStrong, AmberTheme.glassStrong)
        XCTAssertEqual(AmberTheme.separator, AmberTheme.separator)
        XCTAssertEqual(AmberTheme.press, AmberTheme.press)
        XCTAssertEqual(AmberTheme.hoverCard, AmberTheme.hoverCard)
        XCTAssertEqual(AmberTheme.activeCard, AmberTheme.activeCard)
        XCTAssertEqual(AmberTheme.section, AmberTheme.section)
        XCTAssertEqual(AmberTheme.avatarActive, AmberTheme.avatarActive)
        XCTAssertEqual(AmberTheme.avatarActiveInk, AmberTheme.avatarActiveInk)
        XCTAssertEqual(AmberTheme.avatarIdle, AmberTheme.avatarIdle)
        XCTAssertEqual(AmberTheme.avatarIdleInk, AmberTheme.avatarIdleInk)
        XCTAssertEqual(AmberTheme.activeAvatarGlow, AmberTheme.activeAvatarGlow)
        XCTAssertEqual(AmberTheme.homeGlassTop, AmberTheme.homeGlassTop)
        XCTAssertEqual(AmberTheme.homeGlassShadowAmbient, AmberTheme.homeGlassShadowAmbient)
        XCTAssertEqual(AmberTheme.cardShadowContact, AmberTheme.cardShadowContact)
        XCTAssertEqual(AmberTheme.cardShadowAmbient, AmberTheme.cardShadowAmbient)

        // Check trait-resolved RGBA matches resolvedCanvasPalette for paper, notion, and design override.
        let lightTrait = UITraitCollection(userInterfaceStyle: .light)
        let darkTrait = UITraitCollection(userInterfaceStyle: .dark)
        let customDesign = AmberThemeDesign(
            light: .init(
                background: "#F4F0E8",
                surface: "#FCFAF4",
                foreground: "#2A2420",
                mutedForeground: "#6B5D54",
                border: "#D6C8BA"
            ),
            dark: .init(
                background: "#17141A",
                surface: "#27232D",
                foreground: "#F4EEE6",
                mutedForeground: "#A9A0B2",
                border: "#4B4150"
            ),
            gradient: nil,
            patterns: [],
            components: .init(shadowOpacity: 0.2)
        )

        let recipes: [(AmberThemeRuntime.Paper, AmberAccentOption, AmberThemeDesign?)] = [
            (.paper, .terracotta, nil),
            (.notion, .notionBlue, nil),
            (.neutral, .steelBlue, customDesign)
        ]

        for (paper, accent, design) in recipes {
            runtime.apply(paper)
            runtime.apply(accent)
            runtime.design = design

            let expectedLight = AmberTheme.resolvedCanvasPalette(paper: paper, design: design, dark: false)
            let expectedDark = AmberTheme.resolvedCanvasPalette(paper: paper, design: design, dark: true)

            assertDynamicColor(AmberTheme.background, trait: lightTrait, equalsHex: expectedLight.background)
            assertDynamicColor(AmberTheme.background, trait: darkTrait, equalsHex: expectedDark.background)
            assertDynamicColor(AmberTheme.foreground, trait: lightTrait, equalsHex: expectedLight.foreground)
            assertDynamicColor(AmberTheme.foreground, trait: darkTrait, equalsHex: expectedDark.foreground)
            assertDynamicColor(AmberTheme.surface2, trait: lightTrait, equalsHex: expectedLight.surface2)
            assertDynamicColor(AmberTheme.surface2, trait: darkTrait, equalsHex: expectedDark.surface2)
        }

        // Verify @Observable tracking still fires on token dependency changes.
        nonisolated(unsafe) var observedPaperChange = false
        withObservationTracking {
            _ = AmberTheme.foreground
        } onChange: {
            observedPaperChange = true
        }
        runtime.apply(AmberThemeRuntime.Paper.white)
        XCTAssertTrue(observedPaperChange, "Changing runtime.paper must notify @Observable readers of AmberTheme.*")

        nonisolated(unsafe) var observedDesignChange = false
        withObservationTracking {
            _ = AmberTheme.background
        } onChange: {
            observedDesignChange = true
        }
        runtime.design = customDesign
        XCTAssertTrue(observedDesignChange, "Changing runtime.design must notify @Observable readers of AmberTheme.*")
    }

    // MARK: - 2. Canvas texture overlays static colors & batched pixel equivalence

    func testCanvasTextureOverlaysStaticColorIdentityAndPixelEquivalence() throws {
        XCTAssertEqual(AmberDotGridOverlay.dotColor, AmberDotGridOverlay.dotColor)
        XCTAssertEqual(AmberPaperGrainOverlay.grainColor, AmberPaperGrainOverlay.grainColor)
        XCTAssertEqual(AmberLineGridOverlay.lineColor, AmberLineGridOverlay.lineColor)
        XCTAssertEqual(AmberLineGridOverlay.dotColor, AmberLineGridOverlay.dotColor)

        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let dotActual = try renderPNG(
                AmberDotGridOverlay(spacing: 18, radius: 0.7)
                    .padding(EdgeInsets(top: 7, leading: 11, bottom: 0, trailing: 0))
                    .frame(width: 90, height: 90),
                colorScheme: scheme
            )
            let dotReference = try renderPNG(
                ReferenceDotGridOverlay(spacing: 18, radius: 0.7)
                    .padding(EdgeInsets(top: 7, leading: 11, bottom: 0, trailing: 0))
                    .frame(width: 90, height: 90),
                colorScheme: scheme
            )
            XCTAssertEqual(dotActual, dotReference, "Static-color dot grid must match legacy dynamic-closure pixels in \(scheme)")

            let grainActual = try renderPNG(
                AmberPaperGrainOverlay(cell: 4)
                    .padding(EdgeInsets(top: 5, leading: 3, bottom: 0, trailing: 0))
                    .frame(width: 90, height: 90),
                colorScheme: scheme
            )
            let grainReference = try renderPNG(
                ReferencePaperGrainOverlay(cell: 4)
                    .padding(EdgeInsets(top: 5, leading: 3, bottom: 0, trailing: 0))
                    .frame(width: 90, height: 90),
                colorScheme: scheme
            )
            XCTAssertEqual(grainActual, grainReference, "Static-color paper grain must match legacy dynamic-closure pixels in \(scheme)")

            let lineActual = try renderPNG(
                AmberLineGridOverlay(spacing: 18, lineWidth: 1)
                    .padding(EdgeInsets(top: 7, leading: 11, bottom: 0, trailing: 0))
                    .frame(width: 90, height: 90),
                colorScheme: scheme
            )
            let lineReference = try renderPNG(
                ReferenceLineGridOverlay(spacing: 18, lineWidth: 1)
                    .padding(EdgeInsets(top: 7, leading: 11, bottom: 0, trailing: 0))
                    .frame(width: 90, height: 90),
                colorScheme: scheme
            )
            XCTAssertEqual(lineActual, lineReference, "Static-color line grid must match legacy dynamic-closure pixels including intersections in \(scheme)")
        }
    }

    // MARK: - 3. ThinkingOrbEngine cached/rebuilt plan equivalence & scratch reuse

    func testThinkingOrbPreResolvedPlanMatchesRebuiltPlanPixelsAndReusesScratch() throws {
        let times = [0.0, 0.6, 1.23, 3.77]
        for state in OrbState.allCases {
            for preset in [OrbPreset.small, OrbPreset.large] {
                let resolved = orbResolvePreset(state, preset)
                let size = preset == .small ? 24.0 : 64.0
                var scratch = OrbScratch()
                for dark in [false, true] {
                    for t in times {
                        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
                        let plannedImage = renderer.image { ctx in
                            orbDraw(resolved, ctx.cgContext, size: size, t: t, dark: dark, scratch: &scratch)
                        }
                        // Both entry points use the same painter. This checks plan
                        // reuse; comparison to pre-refactor pixels needs a frozen baseline.
                        let rebuiltPlanImage = renderer.image { ctx in
                            orbDraw(resolved.mode, ctx.cgContext, size: size, t: t, dark: dark, opts: resolved.opts)
                        }
                        XCTAssertEqual(
                            plannedImage.pngData(),
                            rebuiltPlanImage.pngData(),
                            "Orb \(state.rawValue) (\(preset)) t=\(t) dark=\(dark) pixels diverged"
                        )
                    }
                }
            }
        }

        // Verify scratch buffer capacity stabilizes after frame 1 across 120 frames.
        for state in OrbState.allCases {
            let resolved = orbResolvePreset(state, .large)
            var scratch = OrbScratch()
            var firstCapacity = 0
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
            for frame in 0..<120 {
                _ = renderer.image { ctx in
                    orbDraw(resolved, ctx.cgContext, size: 64, t: Double(frame) * (1.0 / 30.0), dark: true, scratch: &scratch)
                }
                if frame == 0 {
                    firstCapacity = scratch.dots.capacity
                    XCTAssertGreaterThan(firstCapacity, 0)
                } else {
                    XCTAssertEqual(
                        scratch.dots.capacity,
                        firstCapacity,
                        "Scratch buffer grew on frame \(frame) for \(state.rawValue)"
                    )
                }
            }
        }
    }

    // MARK: - 4. Orb & IslandGlow CADisplayLink pause on scene background

    func testOrbAndIslandGlowPauseDisplayLinkOnSceneBackgroundAndResumeOnForeground() {
        let window = makeHostedWindow(size: CGSize(width: 100, height: 100))
        defer {
            window.isHidden = true
        }

        let orb = OrbCanvasView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        orb.configure(state: .working, preset: .small, size: 24, speed: 1, paused: false, reduceMotion: false, dark: false)

        let glow = IslandGlowCanvasView(frame: CGRect(x: 0, y: 0, width: 100, height: 48))
        glow.configure(spec: .spectral(rotationPeriod: 14, breathing: true), opacity: 1, paused: false, reduceMotion: false)

        window.addSubview(orb)
        window.addSubview(glow)
        defer {
            orb.removeFromSuperview()
            glow.removeFromSuperview()
        }

        let sceneObject = window.windowScene
        if window.windowScene?.activationState == .background {
            NotificationCenter.default.post(name: UIScene.willEnterForegroundNotification, object: sceneObject)
        }
        XCTAssertTrue(orb.isDisplayLinkRunningForTesting)
        XCTAssertTrue(glow.isDisplayLinkRunningForTesting)

        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: sceneObject)
        XCTAssertFalse(orb.isDisplayLinkRunningForTesting)
        XCTAssertFalse(glow.isDisplayLinkRunningForTesting)

        NotificationCenter.default.post(name: UIScene.willEnterForegroundNotification, object: sceneObject)
        XCTAssertTrue(orb.isDisplayLinkRunningForTesting)
        XCTAssertTrue(glow.isDisplayLinkRunningForTesting)
    }

    // MARK: - 5. RelativeTimeFormatter equivalence & AvatarGlow idempotence

    func testRelativeTimeFormatterEquivalenceAndAvatarGlowIdempotentAnimation() throws {
        let reference = Date(timeIntervalSince1970: 1_763_000_000)
        let offsets: [TimeInterval] = [-10, -180, -7200, -86400, -400_000]
        let localeIDs = ["zh-Hans", "en_US", "ja_JP"]

        for localeID in localeIDs {
            let locale = Locale(identifier: localeID)
            let baselineFormatter = RelativeDateTimeFormatter()
            baselineFormatter.locale = locale
            baselineFormatter.unitsStyle = .abbreviated
            for offset in offsets {
                let targetDate = reference.addingTimeInterval(offset)
                let cached = ConversationRelativeTimeFormatter.string(
                    for: targetDate,
                    relativeTo: reference,
                    locale: locale
                )
                let baseline = baselineFormatter.localizedString(for: targetDate, relativeTo: reference)
                XCTAssertEqual(cached, baseline, "Locale \(localeID) offset \(offset) mismatch")
            }
        }

        let driver = AvatarGlowTestDriver()
        let rootView = AvatarGlowTestContainer(driver: driver)
        let hosting = UIHostingController(rootView: rootView)
        let window = makeHostedWindow(size: CGSize(width: 80, height: 80))
        window.rootViewController = hosting
        defer {
            window.rootViewController = nil
            window.isHidden = true
        }
        hosting.view.layoutIfNeeded()
        pumpRunLoop()

        let animatedLayer = try XCTUnwrap(findLayer(in: hosting.view, animationKey: "homeAvatarGlowBreath"))
        let initialAnimation = try XCTUnwrap(animatedLayer.animation(forKey: "homeAvatarGlowBreath"))

        // Unrelated parent re-render must preserve the existing CAAnimation instance (no strip & rebuild).
        driver.tick += 1
        pumpRunLoop()
        let afterTickAnimation = try XCTUnwrap(animatedLayer.animation(forKey: "homeAvatarGlowBreath"))
        XCTAssertTrue(initialAnimation === afterTickAnimation, "Unrelated parent updates must not recreate CAKeyframeAnimation")

        // Reduce motion change must remove the animation, then restore when re-enabled.
        driver.reduceMotion = true
        pumpRunLoop()
        XCTAssertNil(animatedLayer.animation(forKey: "homeAvatarGlowBreath"))

        driver.reduceMotion = false
        pumpRunLoop()
        XCTAssertNotNil(animatedLayer.animation(forKey: "homeAvatarGlowBreath"))
    }

    // MARK: - Helpers

    private func assertDynamicColor(
        _ color: Color,
        trait: UITraitCollection,
        equalsHex expectedHex: UInt32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = UIColor(color).resolvedColor(with: trait)
        let expected = UIColor(hex: expectedHex)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0, ea: CGFloat = 0
        actual.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        expected.getRed(&er, green: &eg, blue: &eb, alpha: &ea)
        XCTAssertEqual(ar, er, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(ag, eg, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(ab, eb, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(aa, ea, accuracy: 0.002, file: file, line: line)
    }

    private func renderPNG<V: View>(_ view: V, colorScheme: ColorScheme) throws -> Data {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, colorScheme))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        return try XCTUnwrap(image.pngData())
    }

    private func makeHostedWindow(size: CGSize) -> UIWindow {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
        }
        window.frame = CGRect(origin: .zero, size: size)
        window.isHidden = false
        return window
    }

    private func pumpRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func findLayer(in view: UIView, animationKey: String) -> CALayer? {
        if view.layer.animation(forKey: animationKey) != nil {
            return view.layer
        }
        for subview in view.subviews {
            if let match = findLayer(in: subview, animationKey: animationKey) {
                return match
            }
        }
        return nil
    }
}

// MARK: - Reference unbatched overlay baselines

private enum AmberCanvasGridPhase {
    static func firstLocal(globalOrigin: CGFloat, spacing: CGFloat, base: CGFloat = 0) -> CGFloat {
        let shifted = globalOrigin - base
        let rem = shifted.truncatingRemainder(dividingBy: spacing)
        let positive = rem >= 0 ? rem : rem + spacing
        return positive == 0 ? 0 : spacing - positive
    }
}

private struct ReferenceDotGridOverlay: View {
    let spacing: CGFloat
    let radius: CGFloat

    var body: some View {
        let color = Color(uiColor: UIColor { trait in
            let dark = trait.userInterfaceStyle == .dark
            let hex: UInt32 = dark ? 0xF4F1ED : 0x281F14
            return UIColor(hex: hex, alpha: dark ? AmberDotGridOverlay.darkAlpha : AmberDotGridOverlay.lightAlpha)
        })
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let half = spacing * 0.5
            let x0 = AmberCanvasGridPhase.firstLocal(globalOrigin: origin.x, spacing: spacing, base: half)
            let y0 = AmberCanvasGridPhase.firstLocal(globalOrigin: origin.y, spacing: spacing, base: half)
            Canvas { context, size in
                var y = y0 - spacing
                while y < size.height + spacing {
                    var x = x0 - spacing
                    while x < size.width + spacing {
                        let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(color))
                        x += spacing
                    }
                    y += spacing
                }
            }
        }
    }
}

private struct ReferencePaperGrainOverlay: View {
    let cell: CGFloat

    var body: some View {
        let color = Color(uiColor: UIColor { trait in
            let dark = trait.userInterfaceStyle == .dark
            let hex: UInt32 = dark ? 0xF4F1ED : 0x281F14
            return UIColor(hex: hex, alpha: dark ? AmberPaperGrainOverlay.darkAlpha : AmberPaperGrainOverlay.lightAlpha)
        })
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let x0 = AmberCanvasGridPhase.firstLocal(globalOrigin: origin.x, spacing: cell)
            let y0 = AmberCanvasGridPhase.firstLocal(globalOrigin: origin.y, spacing: cell)
            Canvas { context, size in
                var y = y0 - cell
                while y < size.height + cell {
                    var x = x0 - cell
                    while x < size.width + cell {
                        let gx = Int(((origin.x + x) / cell).rounded(.down))
                        let gy = Int(((origin.y + y) / cell).rounded(.down))
                        let h = (gx &* 374_761) &+ (gy &* 668_265)
                        if h & 0x7 == 0 {
                            context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(color))
                        }
                        x += cell
                    }
                    y += cell
                }
            }
        }
    }
}

private struct ReferenceLineGridOverlay: View {
    let spacing: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        let line = Color(uiColor: UIColor { trait in
            let dark = trait.userInterfaceStyle == .dark
            let hex: UInt32 = dark ? 0xF4F1ED : 0x281F14
            return UIColor(hex: hex, alpha: dark ? 0.11 : 0.08)
        })
        let dot = Color(uiColor: UIColor { trait in
            let dark = trait.userInterfaceStyle == .dark
            let hex: UInt32 = dark ? 0xF4F1ED : 0x281F14
            return UIColor(hex: hex, alpha: dark ? 0.14 : 0.10)
        })
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let x0 = AmberCanvasGridPhase.firstLocal(globalOrigin: origin.x, spacing: spacing)
            let y0 = AmberCanvasGridPhase.firstLocal(globalOrigin: origin.y, spacing: spacing)
            Canvas { context, size in
                var x = x0 - spacing
                while x <= size.width + spacing {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(line), lineWidth: lineWidth)
                    x += spacing
                }
                var y = y0 - spacing
                while y <= size.height + spacing {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(line), lineWidth: lineWidth)
                    y += spacing
                }
                let r: CGFloat = 0.65
                y = y0 - spacing
                while y <= size.height + spacing {
                    x = x0 - spacing
                    while x <= size.width + spacing {
                        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(dot))
                        x += spacing
                    }
                    y += spacing
                }
            }
        }
    }
}

@MainActor
@Observable
private final class AvatarGlowTestDriver {
    var tick = 0
    var start = Date()
    var reduceMotion = false
    var accentHex: UInt32 = 0xC96442
    var paper: AmberThemeRuntime.Paper = .paper
}

private struct AvatarGlowTestContainer: View {
    let driver: AvatarGlowTestDriver

    var body: some View {
        let _ = driver.tick
        AvatarGlowOpacityHost(
            start: driver.start,
            reduceMotion: driver.reduceMotion,
            accentHex: driver.accentHex,
            paper: driver.paper
        ) {
            Circle()
                .fill(AmberTheme.activeAvatarGlow)
                .frame(width: 44, height: 44)
        }
        .frame(width: 52, height: 52)
    }
}
