import SwiftUI
import UIKit

extension AmberTheme {
    struct AmberHomeTokens: Sendable {
        let sep, press, hoverCard, activeCard: UInt32
        let sepAlpha, pressAlpha: Double
        let section: UInt32
        let avatarActive, avatarActiveInk, avatarIdle, avatarIdleInk: UInt32
        let shadowContact, shadowAmbient: UInt32
        let shadowContactAlpha, shadowAmbientAlpha: Double
        let glassTopAlpha, glassBottomAlpha, glassEdgeAlpha, glassHighlightAlpha: Double
        let glassShadow: UInt32
        let glassShadowAmbientAlpha, glassShadowContactAlpha: Double
    }

    // 暖灰 light
    private static let homeNeutral = AmberHomeTokens(
        sep: 0x161410, press: 0x463A28, hoverCard: 0xF0EEEA, activeCard: 0xEFE9DF,
        sepAlpha: 0.045, pressAlpha: 0.06,
        section: 0x55524D,
        avatarActive: 0xE8DDC6, avatarActiveInk: 0x6F5019, avatarIdle: 0xEDEBE7, avatarIdleInk: 0x8F8B85,
        shadowContact: 0x3A342C, shadowAmbient: 0x3A342C,
        shadowContactAlpha: 0.09, shadowAmbientAlpha: 0.05,
        glassTopAlpha: 0.78, glassBottomAlpha: 0.58, glassEdgeAlpha: 0.5, glassHighlightAlpha: 0.9,
        glassShadow: 0x28241C, glassShadowAmbientAlpha: 0.10, glassShadowContactAlpha: 0.06
    )
    // 暖纸 light
    private static let homePaper = AmberHomeTokens(
        sep: 0x261E14, press: 0x594223, hoverCard: 0xF7F1E6, activeCard: 0xF4EAD8,
        sepAlpha: 0.05, pressAlpha: 0.055,
        section: 0x5B5449,
        avatarActive: 0xEADCBC, avatarActiveInk: 0x6F5019, avatarIdle: 0xF0EBE2, avatarIdleInk: 0x918A80,
        shadowContact: 0x4C3B22, shadowAmbient: 0x4C3B22,
        shadowContactAlpha: 0.09, shadowAmbientAlpha: 0.06,
        glassTopAlpha: 0.78, glassBottomAlpha: 0.58, glassEdgeAlpha: 0.5, glassHighlightAlpha: 0.9,
        glassShadow: 0x28241C, glassShadowAmbientAlpha: 0.10, glassShadowContactAlpha: 0.06
    )
    // 中性白 light：冷灰分隔/投影，激活带浅中性灰
    private static let homeWhite = AmberHomeTokens(
        sep: 0x000000, press: 0x000000, hoverCard: 0xF0F0EF, activeCard: 0xEBEBEA,
        sepAlpha: 0.08, pressAlpha: 0.05,
        section: 0x5C5C5C,
        avatarActive: 0xE8E8E7, avatarActiveInk: 0x3A3A3A, avatarIdle: 0xEEEEED, avatarIdleInk: 0x8E8E8E,
        shadowContact: 0x000000, shadowAmbient: 0x000000,
        shadowContactAlpha: 0.06, shadowAmbientAlpha: 0.04,
        glassTopAlpha: 0.82, glassBottomAlpha: 0.62, glassEdgeAlpha: 0.45, glassHighlightAlpha: 0.9,
        glassShadow: 0x000000, glassShadowAmbientAlpha: 0.08, glassShadowContactAlpha: 0.05
    )
    // 深色（玻璃改 10% 白、投影改黑系）
    private static let homeDark = AmberHomeTokens(
        sep: 0xFFFFFF, press: 0xFFFFFF, hoverCard: 0x29262D, activeCard: 0x302A25,
        sepAlpha: 0.055, pressAlpha: 0.055,
        section: 0xC3BEC5,
        avatarActive: 0x443824, avatarActiveInk: 0xE0BA72, avatarIdle: 0x2B2930, avatarIdleInk: 0xAAA5AD,
        shadowContact: 0x000000, shadowAmbient: 0x000000,
        shadowContactAlpha: 0.58, shadowAmbientAlpha: 0.76,
        glassTopAlpha: 0.14, glassBottomAlpha: 0.08, glassEdgeAlpha: 0.16, glassHighlightAlpha: 0.16,
        glassShadow: 0x000000, glassShadowAmbientAlpha: 0.30, glassShadowContactAlpha: 0.22
    )

    static func homeTokens(
        for paper: AmberThemeRuntime.Paper,
        dark: Bool,
        design: AmberThemeDesign? = nil,
        resolvedPalette: AmberPalette? = nil
    ) -> AmberHomeTokens {
        if let source = dark ? design?.dark : design?.light {
            let palette = resolvedPalette ?? source.resolving(dark ? paper.darkPalette : paper.lightPalette)
            let chrome = dark ? homeDark : homeNeutral
            return AmberHomeTokens(
                sep: palette.foreground, press: palette.foreground,
                hoverCard: palette.surface2, activeCard: palette.surface2,
                sepAlpha: chrome.sepAlpha, pressAlpha: chrome.pressAlpha,
                section: palette.foreground2,
                avatarActive: palette.surface2, avatarActiveInk: palette.foreground,
                avatarIdle: palette.surface2, avatarIdleInk: palette.muted,
                shadowContact: chrome.shadowContact, shadowAmbient: chrome.shadowAmbient,
                shadowContactAlpha: chrome.shadowContactAlpha, shadowAmbientAlpha: chrome.shadowAmbientAlpha,
                glassTopAlpha: chrome.glassTopAlpha, glassBottomAlpha: chrome.glassBottomAlpha,
                glassEdgeAlpha: chrome.glassEdgeAlpha, glassHighlightAlpha: chrome.glassHighlightAlpha,
                glassShadow: chrome.glassShadow,
                glassShadowAmbientAlpha: chrome.glassShadowAmbientAlpha,
                glassShadowContactAlpha: chrome.glassShadowContactAlpha
            )
        }
        if dark {
            switch paper {
            case .neutral:
                // E-edition warm-gray chrome stays the canonical dark home table.
                return homeDark
            case .paper, .white, .pi, .notion:
                // Only retint idle/hover/section against that paper's dark surfaces;
                // glass/shadow geometry stay on homeDark (no full per-paper home tables).
                return homeDarkAligned(to: paper.darkPalette)
            case .garnet, .ochre, .turmeric, .magenta, .lotus:
                break
            }
        } else {
            switch paper {
            case .neutral: return homeNeutral
            case .paper: return homePaper
            case .white: return homeWhite
            case .pi: return homePaper // cream draft paper shares warm-home chrome
            case .notion: return homeWhite // warm-white workspace
            case .garnet, .ochre, .turmeric, .magenta, .lotus:
                break
            }
        }
        // 沉浸式单色画布目前是隐藏的占位主题：从各自调色板派生中性令牌。
        let palette = dark ? paper.darkPalette : paper.lightPalette
        return AmberHomeTokens(
            sep: palette.foreground, press: palette.foreground,
            hoverCard: palette.surface2, activeCard: palette.surface2,
            sepAlpha: 0.18, pressAlpha: 0.08,
            section: palette.foreground2,
            avatarActive: palette.surface2, avatarActiveInk: palette.foreground,
            avatarIdle: palette.surface2, avatarIdleInk: palette.muted,
            shadowContact: 0x000000, shadowAmbient: 0x000000,
            shadowContactAlpha: 0.25, shadowAmbientAlpha: 0.30,
            glassTopAlpha: 0.14, glassBottomAlpha: 0.08, glassEdgeAlpha: 0.16, glassHighlightAlpha: 0.16,
            glassShadow: 0x000000, glassShadowAmbientAlpha: 0.30, glassShadowContactAlpha: 0.22
        )
    }

    /// Dark home chrome that tracks `paper.darkPalette` for surfaces next to the card face.
    private static func homeDarkAligned(to palette: AmberPalette) -> AmberHomeTokens {
        AmberHomeTokens(
            sep: homeDark.sep, press: homeDark.press,
            hoverCard: palette.surface2, activeCard: homeDark.activeCard,
            sepAlpha: homeDark.sepAlpha, pressAlpha: homeDark.pressAlpha,
            section: palette.foreground2,
            avatarActive: homeDark.avatarActive, avatarActiveInk: homeDark.avatarActiveInk,
            avatarIdle: palette.surface2, avatarIdleInk: palette.muted,
            shadowContact: homeDark.shadowContact, shadowAmbient: homeDark.shadowAmbient,
            shadowContactAlpha: homeDark.shadowContactAlpha, shadowAmbientAlpha: homeDark.shadowAmbientAlpha,
            glassTopAlpha: homeDark.glassTopAlpha, glassBottomAlpha: homeDark.glassBottomAlpha,
            glassEdgeAlpha: homeDark.glassEdgeAlpha, glassHighlightAlpha: homeDark.glassHighlightAlpha,
            glassShadow: homeDark.glassShadow,
            glassShadowAmbientAlpha: homeDark.glassShadowAmbientAlpha,
            glassShadowContactAlpha: homeDark.glassShadowContactAlpha
        )
    }

    /// 预解算的动态色令牌快照：在主题输入变化时构建一次，避免 ~1500 个调用点在每次 body/Canvas 帧中
    /// 重复堆分配 UIDynamicProviderColor 闭包并重复执行 hex 解析（同时保证 `Color == Color` 成立）。
    struct ResolvedTokens: Sendable {
        let background: Color
        let elevatedPanel: Color
        let surface: Color
        let surface2: Color
        let surfaceElevated: Color
        let foreground: Color
        let foreground2: Color
        let muted: Color
        let muted2: Color
        let border: Color
        let borderSoft: Color

        let accent: Color
        let accentTint: Color
        let accentInk: Color
        let focusRing: Color

        let glass: Color
        let glassStrong: Color

        let separator: Color
        let press: Color
        let hoverCard: Color
        let activeCard: Color
        let section: Color
        let avatarActive: Color
        let avatarActiveInk: Color
        let avatarIdle: Color
        let avatarIdleInk: Color
        let activeAvatarGlow: Color

        let homeGlassTop: Color
        let homeGlassBottom: Color
        let homeGlassEdge: Color
        let homeGlassHighlight: Color
        let homeGlassShadowAmbient: Color
        let homeGlassShadowContact: Color

        let cardShadowContact: Color
        let cardShadowAmbient: Color

        static func dynamicColor(light: UIColor, dark: UIColor) -> Color {
            Color(uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark ? dark : light
            })
        }

        private static func dynamicHex(light: UInt32, dark: UInt32, alpha: Double = 1) -> Color {
            dynamicColor(light: UIColor(hex: light, alpha: alpha), dark: UIColor(hex: dark, alpha: alpha))
        }

        init(
            paper: AmberThemeRuntime.Paper,
            design: AmberThemeDesign?,
            accentHex: UInt32,
            accentInkHex: UInt32
        ) {
            let lightPalette = AmberTheme.resolvedCanvasPalette(paper: paper, design: design, dark: false)
            let darkPalette = AmberTheme.resolvedCanvasPalette(paper: paper, design: design, dark: true)

            func paletteColor(_ key: KeyPath<AmberPalette, UInt32>, alpha: Double = 1) -> Color {
                Self.dynamicHex(light: lightPalette[keyPath: key], dark: darkPalette[keyPath: key], alpha: alpha)
            }

            background = paletteColor(\.background)
            elevatedPanel = Self.dynamicHex(light: lightPalette.background, dark: darkPalette.surface)
                .exposureAdjust(log2(1.25))
            surface = paletteColor(\.surface)
            surface2 = paletteColor(\.surface2)

            let elevatedLightHex: UInt32
            if design?.light != nil {
                elevatedLightHex = lightPalette.background > 0x808080 ? 0xFFFFFF : lightPalette.surface2
            } else {
                elevatedLightHex = paper.isImmersive ? paper.lightPalette.surface2 : 0xFFFFFF
            }
            surfaceElevated = Self.dynamicHex(light: elevatedLightHex, dark: darkPalette.surface2)

            foreground = paletteColor(\.foreground)
            foreground2 = paletteColor(\.foreground2)
            muted = paletteColor(\.muted)
            muted2 = paletteColor(\.muted2)
            border = paletteColor(\.border)
            borderSoft = paletteColor(\.borderSoft)

            accent = Color(hex: accentHex)
            accentTint = Color(hex: accentHex, alpha: 0.12)
            accentInk = Color(hex: accentInkHex)
            focusRing = Color(hex: accentHex, alpha: 0.55)

            glass = paletteColor(\.background, alpha: 0.72)
            glassStrong = paletteColor(\.background, alpha: 0.85)

            let lightHome = AmberTheme.homeTokens(for: paper, dark: false, design: design, resolvedPalette: lightPalette)
            let darkHome = AmberTheme.homeTokens(for: paper, dark: true, design: design, resolvedPalette: darkPalette)

            func homeColor(
                _ key: KeyPath<AmberHomeTokens, UInt32>,
                alpha alphaKey: KeyPath<AmberHomeTokens, Double>? = nil
            ) -> Color {
                Self.dynamicColor(
                    light: UIColor(hex: lightHome[keyPath: key], alpha: alphaKey.map { lightHome[keyPath: $0] } ?? 1),
                    dark: UIColor(hex: darkHome[keyPath: key], alpha: alphaKey.map { darkHome[keyPath: $0] } ?? 1)
                )
            }

            func homeGlassWhite(_ alphaKey: KeyPath<AmberHomeTokens, Double>) -> Color {
                Self.dynamicColor(
                    light: UIColor(hex: 0xFFFFFF, alpha: lightHome[keyPath: alphaKey]),
                    dark: UIColor(hex: 0xFFFFFF, alpha: darkHome[keyPath: alphaKey])
                )
            }

            separator = homeColor(\.sep, alpha: \.sepAlpha)
            press = homeColor(\.press, alpha: \.pressAlpha)
            hoverCard = homeColor(\.hoverCard)
            activeCard = if paper == .notion {
                Self.dynamicColor(
                    light: UIColor(hex: 0x000000, alpha: 0.04),
                    dark: UIColor(hex: 0xFFFFFF, alpha: 0.08)
                )
            } else {
                Self.dynamicColor(
                    light: UIColor(hex: accentHex, alpha: 0.09),
                    dark: UIColor(hex: accentHex, alpha: 0.16)
                )
            }
            section = homeColor(\.section)
            avatarActive = Self.dynamicColor(
                light: UIColor(hex: accentHex, alpha: 0.18),
                dark: UIColor(hex: accentHex, alpha: 0.32)
            )
            let r = Double((accentInkHex >> 16) & 0xFF)
            let g = Double((accentInkHex >> 8) & 0xFF)
            let b = Double(accentInkHex & 0xFF)
            let luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
            avatarActiveInk = Self.dynamicHex(
                light: accentHex,
                dark: luminance > 0.6 ? accentInkHex : accentHex
            )
            avatarIdle = homeColor(\.avatarIdle)
            avatarIdleInk = homeColor(\.avatarIdleInk)

            let lightGlowAlpha: Double
            switch paper {
            case .paper: lightGlowAlpha = 0.14
            case .white: lightGlowAlpha = 0.12
            default: lightGlowAlpha = 0.15
            }
            activeAvatarGlow = Self.dynamicColor(
                light: UIColor(hex: accentHex, alpha: lightGlowAlpha),
                dark: UIColor(hex: accentHex, alpha: 0.14)
            )

            homeGlassTop = homeGlassWhite(\.glassTopAlpha)
            homeGlassBottom = homeGlassWhite(\.glassBottomAlpha)
            homeGlassEdge = homeGlassWhite(\.glassEdgeAlpha)
            homeGlassHighlight = homeGlassWhite(\.glassHighlightAlpha)
            homeGlassShadowAmbient = homeColor(\.glassShadow, alpha: \.glassShadowAmbientAlpha)
            homeGlassShadowContact = homeColor(\.glassShadow, alpha: \.glassShadowContactAlpha)

            if let shadowOpacity = design?.components?.shadowOpacity {
                cardShadowContact = .black.opacity(shadowOpacity * 0.5)
                cardShadowAmbient = .black.opacity(shadowOpacity)
            } else {
                cardShadowContact = homeColor(\.shadowContact, alpha: \.shadowContactAlpha)
                cardShadowAmbient = homeColor(\.shadowAmbient, alpha: \.shadowAmbientAlpha)
            }
        }
    }
}
