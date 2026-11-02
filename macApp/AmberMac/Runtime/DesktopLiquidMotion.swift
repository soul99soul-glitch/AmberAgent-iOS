import SwiftUI

/// Kinematics for the top-right toolbar Liquid Glass capsule bar (shortens when the right inspector expands,
/// lengthens when the right inspector collapses, with volume-conserving waist necking, overshoot, and elastic rebound),
/// while keeping lower workspace panels on a calm, standard non-bouncy transition.
enum DesktopLiquidMotion {
    struct ToolbarCapsuleTransform: Equatable, Sendable {
        let width: CGFloat
        let baseHeight: CGFloat
        let scaleY: CGFloat
        let waistPinch: CGFloat
        let cornerRadius: CGFloat
        let specularOpacity: Double
    }

    struct ToolbarItemTransform: Equatable, Sendable {
        let scale: CGFloat
        let offsetX: CGFloat
        let opacity: Double
    }

    /// Calm, standard non-bouncy animation for the left sidebar and right inspector panels.
    static func panelAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.34, dampingFraction: 0.84)
    }

    /// Underdamped Liquid Glass spring for the top toolbar capsule bar (`dampingFraction: 0.54` produces
    /// a visible ~10–12% width overshoot + vertical squash/rebound on both lengthening and shortening).
    static func toolbarCapsuleAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.38, dampingFraction: 0.54, blendDuration: 0.06)
    }

    /// Evaluates the top toolbar capsule bar geometry from continuous `extensionProgress`:
    /// - `0.0`: Short capsule (`[ ⌘  ◧ ]`, right inspector expanded / docked)
    /// - `1.0`: Long capsule (`[ ⌘  💬  📌  📁  ☑️  (📅)  ◧ ]`, right inspector collapsed / undocked)
    /// - `< 0.0`: Shortening overshoot (compresses narrower than `shortWidth` while bulging vertically `scaleY > 1`)
    /// - `> 1.0`: Lengthening overshoot (stretches wider than `longWidth` with elastic counter-bulge before settling)
    static func toolbarCapsuleTransform(
        extensionProgress: CGFloat,
        extraItemCount: Int,
        reduceMotion: Bool
    ) -> ToolbarCapsuleTransform {
        let baseHeight: CGFloat = 32.0
        let shortWidth: CGFloat = 80.0
        let deltaWidth: CGFloat = CGFloat(max(0, extraItemCount)) * 36.0
        let longWidth = shortWidth + deltaWidth

        if reduceMotion {
            let clamped = min(max(extensionProgress, 0.0), 1.0)
            return ToolbarCapsuleTransform(
                width: shortWidth + deltaWidth * clamped,
                baseHeight: baseHeight,
                scaleY: 1.0,
                waistPinch: 0.0,
                cornerRadius: baseHeight * 0.5,
                specularOpacity: 0.0
            )
        }

        if abs(extensionProgress) < 0.0005 {
            return ToolbarCapsuleTransform(
                width: shortWidth,
                baseHeight: baseHeight,
                scaleY: 1.0,
                waistPinch: 0.0,
                cornerRadius: baseHeight * 0.5,
                specularOpacity: 0.0
            )
        }

        if abs(extensionProgress - 1.0) < 0.0005 {
            return ToolbarCapsuleTransform(
                width: longWidth,
                baseHeight: baseHeight,
                scaleY: 1.0,
                waistPinch: 0.0,
                cornerRadius: baseHeight * 0.5,
                specularOpacity: 0.0
            )
        }

        if extensionProgress < 0.0 {
            // Shortening overshoot (right panel just expanded -> top capsule slams shut against trailing anchor):
            // Horizontal compression converts into vertical Q-弹 bulge (`scaleY > 1`, convex waist `waistPinch < 0`).
            let under = min(-extensionProgress, 0.25)
            let width = max(64.0, shortWidth - deltaWidth * 0.72 * under)
            let scaleY = 1.0 + 1.25 * under
            let waistPinch = -0.80 * under
            return ToolbarCapsuleTransform(
                width: width,
                baseHeight: baseHeight,
                scaleY: scaleY,
                waistPinch: waistPinch,
                cornerRadius: (baseHeight * 0.5) * scaleY,
                specularOpacity: Double(min(0.90, under * 6.8))
            )
        } else if extensionProgress <= 1.0 {
            // Mid-transition between short (0.0) and long (1.0):
            // Surface-tension waist necking pulls the vertical waist thinner (`scaleY < 1`, concave `waistPinch > 0`).
            let u = extensionProgress
            let envelope = sin(.pi * u)
            let width = shortWidth + deltaWidth * u
            let scaleY = 1.0 - 0.14 * envelope
            let waistPinch = 0.22 * envelope
            return ToolbarCapsuleTransform(
                width: width,
                baseHeight: baseHeight,
                scaleY: scaleY,
                waistPinch: waistPinch,
                cornerRadius: (baseHeight * 0.5) * scaleY,
                specularOpacity: Double(0.92 * envelope)
            )
        } else {
            // Lengthening overshoot (right panel just collapsed -> top capsule stretches past longWidth and rebounds):
            let over = min(extensionProgress - 1.0, 0.25)
            let width = longWidth + deltaWidth * 0.90 * over
            let scaleY = 1.0 + 0.85 * over
            let waistPinch = -0.55 * over
            return ToolbarCapsuleTransform(
                width: width,
                baseHeight: baseHeight,
                scaleY: scaleY,
                waistPinch: waistPinch,
                cornerRadius: (baseHeight * 0.5) * scaleY,
                specularOpacity: Double(min(0.90, over * 6.8))
            )
        }
    }

    /// Evaluates uniform 1:1 icon appearance for each collapsible middle toolbar item so icons remain crisp
    /// and readable without ever stretching into distorted ovals.
    static func toolbarItemTransform(
        index: Int,
        totalCount: Int,
        extensionProgress: CGFloat,
        reduceMotion: Bool
    ) -> ToolbarItemTransform {
        if reduceMotion {
            let clamped = min(max(extensionProgress, 0.0), 1.0)
            return ToolbarItemTransform(scale: 1.0, offsetX: 0.0, opacity: Double(clamped))
        }
        let safeTotal = max(1, totalCount)
        let reverseIdx = CGFloat(max(0, safeTotal - 1 - index))
        let delay = min(0.32, reverseIdx * 0.075)
        if extensionProgress <= 0.0 {
            return ToolbarItemTransform(scale: 0.45, offsetX: 10.0, opacity: 0.0)
        } else if extensionProgress <= 1.0 {
            let localU = max(0.0, min(1.0, (extensionProgress - delay) / max(0.01, 0.88 - delay)))
            let scale = 0.45 + 0.55 * localU
            let offsetX = (1.0 - localU) * 10.0
            let opacity = Double(min(1.0, pow(localU, 0.70) * 1.15))
            return ToolbarItemTransform(scale: scale, offsetX: offsetX, opacity: opacity)
        } else {
            let over = min(extensionProgress - 1.0, 0.22)
            let scale = 1.0 + 0.45 * over
            return ToolbarItemTransform(scale: scale, offsetX: -1.5 * over, opacity: 1.0)
        }
    }
}
