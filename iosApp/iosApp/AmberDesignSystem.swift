import SwiftUI
import os
import UIKit
@preconcurrency import Shared
import UniformTypeIdentifiers


/// A full set of canvas tokens for one appearance (warm paper / warm gray / neutral white / dark).
struct AmberPalette {
    let background, surface, surface2, foreground, foreground2, muted, muted2, border, borderSoft: UInt32
}

// Theme tokens are dynamic: the canvas (paper / warm gray / white) + accent come from
// AmberThemeRuntime, and light/dark is resolved by a UIColor dynamicProvider. Because the color
// getters read the @Observable runtime, any SwiftUI body that reads AmberTheme.* auto-tracks
// theme changes and re-renders — with zero changes at the ~1500 existing call sites.
enum AmberTheme {
    // 暖纸：画布 #EFE7D6、卡片 #FFFDF7，投影偏暖棕。
    static let paperLight = AmberPalette(
        background: 0xEFE7D6, surface: 0xFFFDF7, surface2: 0xF0EBE2,
        foreground: 0x1B1813, foreground2: 0x5B5449, muted: 0x746D62, muted2: 0x918A80,
        border: 0xDBCEBC, borderSoft: 0xECE3D6
    )
    // 暖灰（E 版默认）：画布 #ECE8E4 + 暖白卡片 #F6F5F3。
    static let neutralLight = AmberPalette(
        background: 0xECE8E4, surface: 0xF6F5F3, surface2: 0xEDEBE7,
        foreground: 0x161514, foreground2: 0x55524D, muted: 0x716D67, muted2: 0x8F8B85,
        border: 0xD9D5CF, borderSoft: 0xE4E1DC
    )
    // 中性白：冷中性画布 + 真白分组面（background ≠ surface ≠ surface2，避免塌层级）。
    static let whiteLight = AmberPalette(
        background: 0xF5F5F4, surface: 0xFFFFFF, surface2: 0xEEEEED,
        foreground: 0x1A1A1A, foreground2: 0x5C5C5C, muted: 0x737373, muted2: 0x8E8E8E,
        border: 0xD4D4D4, borderSoft: 0xE5E5E5
    )
    // 点阵 · 钢蓝（pi-dotgrid / Open Design brand-spec）：奶油稿纸 + 实底卡片。
    static let piLight = AmberPalette(
        background: 0xF3F0EB, surface: 0xFAF9F7, surface2: 0xEBE7E0,
        foreground: 0x1C1B19, foreground2: 0x4A4640, muted: 0x6A6560, muted2: 0x9A948C,
        border: 0xD4CFC7, borderSoft: 0xE8E4DC
    )
    // 空白 · 暖白（Open Design blank-workspace / Notion 工作台）：暖中性 + 真白 surface。
    static let notionLight = AmberPalette(
        background: 0xF6F5F4, surface: 0xFFFFFF, surface2: 0xEFEEEC,
        foreground: 0x1A1918, foreground2: 0x31302E, muted: 0x615D59, muted2: 0xA39E98,
        border: 0xE6E5E3, borderSoft: 0xF0EFED
    )
    // 深色 · 暖灰工作台（E 版 / neutral）：画布 #0E0D10、卡片 #1F1D23。
    static let darkPalette = AmberPalette(
        background: 0x0E0D10, surface: 0x1F1D23, surface2: 0x2B2930,
        foreground: 0xF4F1ED, foreground2: 0xC3BEC5, muted: 0xAAA5AD, muted2: 0x6E6760,
        border: 0x3A3741, borderSoft: 0x2A2830
    )
    // 深色 · 暖纸：偏棕墨底，保留纸本气质。
    static let paperDark = AmberPalette(
        background: 0x14110E, surface: 0x221E19, surface2: 0x2E2822,
        foreground: 0xF5F0E8, foreground2: 0xC8BDB0, muted: 0xA89888, muted2: 0x6E6258,
        border: 0x3D342C, borderSoft: 0x2A241E
    )
    // 深色 · 中性白：冷中性灰阶，避免偏紫底。
    static let whiteDark = AmberPalette(
        background: 0x111111, surface: 0x1C1C1C, surface2: 0x282828,
        foreground: 0xF5F5F5, foreground2: 0xBDBDBD, muted: 0x8E8E8E, muted2: 0x6B6B6B,
        border: 0x383838, borderSoft: 0x2A2A2A
    )
    // 深色 · Pi 稿纸：暖橄榄底，对齐奶油稿纸角色。
    static let piDark = AmberPalette(
        background: 0x12110F, surface: 0x1E1C18, surface2: 0x2A2722,
        foreground: 0xF3F0EB, foreground2: 0xC4BEB4, muted: 0x9A948C, muted2: 0x6A6560,
        border: 0x3A3630, borderSoft: 0x28251F
    )
    // 深色 · Notion 暖白：冷灰工作台（近 Notion dark）。
    static let notionDark = AmberPalette(
        background: 0x191919, surface: 0x252525, surface2: 0x2F2F2F,
        foreground: 0xEBEBEB, foreground2: 0xB4B4B4, muted: 0x9B9B9B, muted2: 0x6F6F6F,
        border: 0x373737, borderSoft: 0x2C2C2C
    )

    // ── Immersive single-hue canvases (Apple-Music-style full-bleed color). Each is a
    // fixed color in BOTH light & dark (the theme IS the color), with text tuned for AA
    // contrast on its own ground: deep grounds get pale ink, light grounds get dark ink.
    //
    // ⚠️ CURRENTLY HIDDEN from the picker (AppearanceSettingsView filters out `isImmersive`
    // canvases) — full-bleed color read poorly app-wide. These palettes + their `Paper`
    // cases are kept as PLACEHOLDERS so re-enabling or swapping in new colors later is a
    // one-liner: edit the hex values below (or add a new palette + `Paper` case), then drop
    // the `!$0.isImmersive` filter in `backgroundCards`. Everything else (base()/picker)
    // auto-resolves. Wiring is proven-good; only the color choices were the problem.
    // 绛红 — deep wine, pale rose ink.
    static let garnetPalette = AmberPalette(
        background: 0x5B1A1C, surface: 0x6F282A, surface2: 0x843234,
        foreground: 0xF7E6E4, foreground2: 0xE4C7C5, muted: 0xC89C9B, muted2: 0xAC7E7C,
        border: 0x7C3436, borderSoft: 0x682A2C
    )
    // 赭橙 — rust sienna, cream ink.
    static let ochrePalette = AmberPalette(
        background: 0xAE5230, surface: 0xBC6440, surface2: 0xC8714C,
        foreground: 0xFBF1E8, foreground2: 0xF1DECC, muted: 0xE7C5A9, muted2: 0xD7A988,
        border: 0xC26C47, borderSoft: 0xB45E3B
    )
    // 姜黄 — mustard gold, dark espresso ink.
    static let turmericPalette = AmberPalette(
        background: 0xC18D1A, surface: 0xCE9B2C, surface2: 0xD9A83E,
        foreground: 0x3A2C06, foreground2: 0x5B4612, muted: 0x856A1E, muted2: 0xA08238,
        border: 0xAD7C16, borderSoft: 0xBC8A1C
    )
    // 品红 — rose magenta, pale blush ink.
    static let magentaPalette = AmberPalette(
        background: 0xB23A66, surface: 0xC04874, surface2: 0xCC5682,
        foreground: 0xFCE6EE, foreground2: 0xF3CCDB, muted: 0xE6ABC3, muted2: 0xD68BAA,
        border: 0xC25180, borderSoft: 0xB4426E
    )
    // 藕荷 — pale dusty blush, dark ink.
    static let lotusPalette = AmberPalette(
        background: 0xE7D5D2, surface: 0xF2E5E3, surface2: 0xDBC8C5,
        foreground: 0x2E2422, foreground2: 0x4F413E, muted: 0x7D6D69, muted2: 0xA4918D,
        border: 0xD7C1BD, borderSoft: 0xE3D0CD
    )

    private static func base(_ key: KeyPath<AmberPalette, UInt32>, alpha: Double = 1) -> Color {
        base(light: key, dark: key, alpha: alpha)
    }

    private static func base(
        light lightKey: KeyPath<AmberPalette, UInt32>, dark darkKey: KeyPath<AmberPalette, UInt32>,
        alpha: Double = 1
    ) -> Color {
        let paper = AmberThemeRuntime.shared.paper
        let design = AmberThemeRuntime.shared.design
        let lightHex = resolvedCanvasPalette(paper: paper, design: design, dark: false)[keyPath: lightKey]
        let darkHex = resolvedCanvasPalette(paper: paper, design: design, dark: true)[keyPath: darkKey]
        return Color(uiColor: UIColor { trait in
            UIColor(hex: trait.userInterfaceStyle == .dark ? darkHex : lightHex, alpha: alpha)
        })
    }

    /// Canvas palette for one appearance: the paper palette with the design theme's color
    /// overrides applied. Single source for native tokens and web surfaces (deep-read reader).
    static func resolvedCanvasPalette(
        paper: AmberThemeRuntime.Paper, design: AmberThemeDesign?, dark: Bool
    ) -> AmberPalette {
        let base = dark ? paper.darkPalette : paper.lightPalette
        return (dark ? design?.dark : design?.light)?.resolving(base) ?? base
    }

    static var background: Color { base(\.background) }
    /// 顶栏弹出面板底色：借 EDR 线性提亮到 1.25 倍，与页面背景拉开亮度层级。
    /// 暗色背景近黑，倍乘几乎无效，改以 `surface` 为底抬高层级。
    /// 不支持 EDR 的屏幕会色调映射回 SDR。
    static var elevatedPanel: Color {
        base(light: \.background, dark: \.surface).exposureAdjust(log2(1.25))
    }
    static var surface: Color { base(\.surface) }
    static var surface2: Color { base(\.surface2) }
    static var card: Color { base(\.surface) }
    static var foreground: Color { base(\.foreground) }
    static var foreground2: Color { base(\.foreground2) }
    static var muted: Color { base(\.muted) }
    static var muted2: Color { base(\.muted2) }
    static var border: Color { base(\.border) }
    static var borderSoft: Color { base(\.borderSoft) }

    // Runtime accent (the user's swatch). accentInk = on-accent text/icon color.
    static var accent: Color { Color(hex: AmberThemeRuntime.shared.accentHex) }
    static var accentTint: Color { Color(hex: AmberThemeRuntime.shared.accentHex, alpha: 0.12) }
    static var accentInk: Color { Color(hex: AmberThemeRuntime.shared.accentInkHex) }

    // Semantic status colors stay fixed (status is always color + symbol/label elsewhere).
    // `accentAmber` / `statusAmber` = warning · running · attention chrome — NOT the user theme accent.
    // Brand / selected / primary interactive chrome must use `accent` + `accentInk`.
    static let statusAmberHex: UInt32 = 0xD98324
    static let accentIndigo = Color(hex: 0x5856D6)
    static let accentAmber = Color(hex: statusAmberHex)
    /// Alias for call sites that want the semantic name (same as `accentAmber`).
    static var statusAmber: Color { accentAmber }
    static let accentGreen = Color(hex: 0x3DA35D)
    static let accentCyan = Color(hex: 0x2AA0BC)
    static let accentRed = Color(hex: 0xC8402F)

    static var glass: Color { base(\.background, alpha: 0.72) }
    static var glassStrong: Color { base(\.background, alpha: 0.85) }

    static let radiusSmall: CGFloat = 6
    static let radiusMedium: CGFloat = 8
    /// Chat / tool card radius — follows optional `bubbleChrome` theme slot.
    static var radiusLarge: CGFloat {
        if let radius = AmberThemeRuntime.shared.design?.components?.cardRadius { return CGFloat(radius) }
        return switch AmberThemeRuntime.shared.bubbleChrome {
        case .standard: 12
        case .soft: 14
        case .crisp: 10
        }
    }
    static var radiusXLarge: CGFloat {
        if let radius = AmberThemeRuntime.shared.design?.components?.cardRadius { return CGFloat(radius) }
        return switch AmberThemeRuntime.shared.bubbleChrome {
        case .standard: 18
        case .soft: 22
        case .crisp: 14
        }
    }
    static var homeCardRadius: CGFloat { CGFloat(AmberThemeRuntime.shared.design?.components?.cardRadius ?? 22) }
    static func controlRadius(_ fallback: CGFloat) -> CGFloat {
        AmberThemeRuntime.shared.design?.components?.controlRadius.map { CGFloat($0) } ?? fallback
    }
    static var designBorderWidth: CGFloat { CGFloat(AmberThemeRuntime.shared.design?.components?.borderWidth ?? 0) }
    static let radiusPill: CGFloat = 980

    // ── 首页设计令牌 ────────────────────────────────────────────────
    // 画布相关（sep/activeCard/avatar…）随 Paper 变；彩色强调走 runtime accent。

    /// 全 App 唯一分隔线语言：1px hairline。
    static var separator: Color { homeColor(\.sep, alpha: \.sepAlpha) }
    /// hover/按压垫底（前景只允许加深，禁止变浅变灰）。
    static var press: Color { homeColor(\.press, alpha: \.pressAlpha) }
    static var hoverCard: Color { homeColor(\.hoverCard) }
    /// 激活会话行通栏色带。
    /// Notion 暖白：中性浅墨晕（≈ rgba(0,0,0,0.04)），蓝只留在图标/头像，避免整行「皮肤」蓝。
    /// 其它 paper：仍随 accent 浅染。
    static var activeCard: Color {
        Color(uiColor: UIColor { trait in
            let dark = trait.userInterfaceStyle == .dark
            if AmberThemeRuntime.shared.paper == .notion {
                return UIColor(hex: dark ? 0xFFFFFF : 0x000000, alpha: dark ? 0.08 : 0.04)
            }
            let hex = AmberThemeRuntime.shared.accentHex
            return UIColor(hex: hex, alpha: dark ? 0.16 : 0.09)
        })
    }
    /// 节标题墨（设计令牌 sec，与 foreground2 数值同构但语义独立，防止联动漂移）。
    static var section: Color { homeColor(\.section) }
    /// 当前/激活头像底：随 accent 浅染（Continue 功能方块、会话当前行共用）。
    static var avatarActive: Color {
        Color(uiColor: UIColor { trait in
            let hex = AmberThemeRuntime.shared.accentHex
            let alpha: Double = trait.userInterfaceStyle == .dark ? 0.32 : 0.18
            return UIColor(hex: hex, alpha: alpha)
        })
    }
    /// 当前/激活头像墨：浅色用 accent 本体；深色用 on-accent 墨（高亮色走白/浅，琥珀等走深墨时抬亮一档）。
    static var avatarActiveInk: Color {
        Color(uiColor: UIColor { trait in
            let accent = AmberThemeRuntime.shared.accentHex
            if trait.userInterfaceStyle == .dark {
                let ink = AmberThemeRuntime.shared.accentInkHex
                // 深色画布上：若 ink 是白/浅则用 ink；若 ink 是深色（琥珀/鼠尾草）则用 accent 提亮可读性。
                let r = Double((ink >> 16) & 0xFF)
                let g = Double((ink >> 8) & 0xFF)
                let b = Double(ink & 0xFF)
                let luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
                return UIColor(hex: luminance > 0.6 ? ink : accent)
            }
            return UIColor(hex: accent)
        })
    }
    static var avatarIdle: Color { homeColor(\.avatarIdle) }
    static var avatarIdleInk: Color { homeColor(\.avatarIdleInk) }
    /// 首页/浮层强调色别名：绑定用户可选 accent（齿轮、新建图标、旧 fab 调用点）。
    static var fab: Color { accent }
    static var fabInk: Color { accentInk }
    /// focus-visible 焦点环（随 accent）。
    static var focusRing: Color {
        Color(hex: AmberThemeRuntime.shared.accentHex, alpha: 0.55)
    }
    /// 当前会话头像呼吸光晕（色随 accent；alpha 刻意压低，只余光提示）。
    static var activeAvatarGlow: Color {
        Color(uiColor: UIColor { trait in
            let hex = AmberThemeRuntime.shared.accentHex
            if trait.userInterfaceStyle == .dark {
                return UIColor(hex: hex, alpha: 0.14)
            }
            let alpha: Double
            switch AmberThemeRuntime.shared.paper {
            case .paper: alpha = 0.14
            case .white: alpha = 0.12
            default: alpha = 0.15
            }
            return UIColor(hex: hex, alpha: alpha)
        })
    }
    /// 首页控制层玻璃配方（仅搜索胶囊钮/展开搜索条/齿轮按钮三个控件，设计 §2）。
    /// 浅色（含暖纸）：白 .78→.58 纵向渐变；深色：白 .14→.08。
    /// 描边 .5px 白 .5（深色 .16）、顶部内高光白 .9（深色 .16）、投影 rgba(40,36,28) .10/.06（深色黑 .30/.22）。
    static var homeGlassTop: Color { homeGlassWhite(\.glassTopAlpha) }
    static var homeGlassBottom: Color { homeGlassWhite(\.glassBottomAlpha) }
    static var homeGlassEdge: Color { homeGlassWhite(\.glassEdgeAlpha) }
    static var homeGlassHighlight: Color { homeGlassWhite(\.glassHighlightAlpha) }
    static var homeGlassShadowAmbient: Color { homeColor(\.glassShadow, alpha: \.glassShadowAmbientAlpha) }
    static var homeGlassShadowContact: Color { homeColor(\.glassShadow, alpha: \.glassShadowContactAlpha) }
    /// 贴身接触线投影（卡片「坐」在画布上的关键，不要飘）。
    static var cardShadowContact: Color {
        if let opacity = AmberThemeRuntime.shared.design?.components?.shadowOpacity { return .black.opacity(opacity * 0.5) }
        return homeColor(\.shadowContact, alpha: \.shadowContactAlpha)
    }
    /// 弱环境光投影。
    static var cardShadowAmbient: Color {
        if let opacity = AmberThemeRuntime.shared.design?.components?.shadowOpacity { return .black.opacity(opacity) }
        return homeColor(\.shadowAmbient, alpha: \.shadowAmbientAlpha)
    }

    /// 环境光投影的几何随主题变化（浅色 0 5px 14px -6px，深色 0 8px 20px -8px），
    /// 颜色已通过上面的动态令牌解析，这里只提供几何。
    static func cardShadowAmbientGeometry(for colorScheme: ColorScheme) -> (radius: CGFloat, y: CGFloat) {
        if let radius = AmberThemeRuntime.shared.design?.components?.shadowRadius { return (CGFloat(radius), CGFloat(radius) * 0.5) }
        return colorScheme == .dark ? (10, 8) : (7, 5)
    }

    private struct AmberHomeTokens {
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

    private static func homeTokens(for paper: AmberThemeRuntime.Paper, dark: Bool, design: AmberThemeDesign? = nil) -> AmberHomeTokens {
        if let source = dark ? design?.dark : design?.light {
            let palette = source.resolving(dark ? paper.darkPalette : paper.lightPalette)
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

    /// 玻璃用的动态白（alpha 随主题表解析）。
    private static func homeGlassWhite(_ alpha: KeyPath<AmberHomeTokens, Double>) -> Color {
        let paper = AmberThemeRuntime.shared.paper
        let design = AmberThemeRuntime.shared.design
        return Color(uiColor: UIColor { trait in
            let tokens = homeTokens(for: paper, dark: trait.userInterfaceStyle == .dark, design: design)
            return UIColor(hex: 0xFFFFFF, alpha: tokens[keyPath: alpha])
        })
    }

    private static func homeColor(
        _ key: KeyPath<AmberHomeTokens, UInt32>,
        alpha: KeyPath<AmberHomeTokens, Double>? = nil
    ) -> Color {
        let paper = AmberThemeRuntime.shared.paper
        let design = AmberThemeRuntime.shared.design
        return Color(uiColor: UIColor { trait in
            let tokens = homeTokens(for: paper, dark: trait.userInterfaceStyle == .dark, design: design)
            return UIColor(hex: tokens[keyPath: key], alpha: alpha.map { tokens[keyPath: $0] } ?? 1)
        })
    }
}

/// Persisted, observable theme state: canvas (paper vs neutral) + accent + swappable visual
/// style slots (texture / brand mark / shortcut icons). Light/dark is handled separately via
/// `IOSAppearanceMode` → `.preferredColorScheme` (+ the dynamicProvider above).
/// List layout is **not** part of this state.
@Observable
final class AmberThemeRuntime {
    // Read/written only from main-actor view bodies and tap handlers; the dynamicProvider color
    // closure does not touch it. nonisolated(unsafe) keeps the shared singleton accessible from
    // AmberTheme.* getters without forcing @MainActor onto all ~1500 call sites.
    nonisolated(unsafe) static let shared = AmberThemeRuntime()

    enum Paper: String, CaseIterable {
        /// 暖纸 / 暖灰 / 中性白（非沉浸）+ 隐藏的沉浸色画布占位。
        case paper, neutral, white, pi, notion, garnet, ochre, turmeric, magenta, lotus

        /// Light-appearance palette. Neutral canvases adapt to system dark;
        /// the immersive single-hue canvases keep their color in both appearances.
        var lightPalette: AmberPalette {
            switch self {
            case .paper: AmberTheme.paperLight
            case .neutral: AmberTheme.neutralLight
            case .white: AmberTheme.whiteLight
            case .pi: AmberTheme.piLight
            case .notion: AmberTheme.notionLight
            case .garnet: AmberTheme.garnetPalette
            case .ochre: AmberTheme.ochrePalette
            case .turmeric: AmberTheme.turmericPalette
            case .magenta: AmberTheme.magentaPalette
            case .lotus: AmberTheme.lotusPalette
            }
        }

        var darkPalette: AmberPalette {
            switch self {
            case .neutral: AmberTheme.darkPalette
            case .paper: AmberTheme.paperDark
            case .white: AmberTheme.whiteDark
            case .pi: AmberTheme.piDark
            case .notion: AmberTheme.notionDark
            case .garnet: AmberTheme.garnetPalette
            case .ochre: AmberTheme.ochrePalette
            case .turmeric: AmberTheme.turmericPalette
            case .magenta: AmberTheme.magentaPalette
            case .lotus: AmberTheme.lotusPalette
            }
        }

        var displayName: String {
            let key: String
            switch self {
            case .paper: key = "暖纸"
            case .neutral: key = "暖灰"
            case .white: key = "中性白"
            case .pi: key = "奶油稿纸"
            case .notion: key = "暖白"
            case .garnet: key = "绛红"
            case .ochre: key = "赭橙"
            case .turmeric: key = "姜黄"
            case .magenta: key = "品红"
            case .lotus: key = "藕荷"
            }
            return IOSAppLocalization.string(key, defaultValue: key)
        }

        var isImmersive: Bool {
            switch self {
            case .paper, .neutral, .white, .pi, .notion: false
            default: true
            }
        }
    }

    var design: AmberThemeDesign? {
        didSet {
            guard persistEnabled else { return }
            UserDefaults.standard.set(design.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.design)
        }
    }

    /// Identity is independent of visual equality: two named packs may share
    /// exactly the same recipe and must still remain separate edit targets.
    private(set) var selectedThemeID: String? {
        didSet { persistString(Keys.selectedThemeID, selectedThemeID) }
    }
    private(set) var selectedThemeName: String? {
        didSet { persistString(Keys.selectedThemeName, selectedThemeName) }
    }

    var paper: Paper { didSet { persistString(Keys.paper, paper.rawValue) } }
    var accentHex: UInt32 { didSet { persistInt(Keys.accent, Int(accentHex)) } }
    var accentInkHex: UInt32 { didSet { persistInt(Keys.accentInk, Int(accentInkHex)) } }
    /// Canvas texture overlay style (default `.flat` = solid color only).
    var canvasStyle: AmberCanvasStyle {
        didSet { persistString(Keys.canvasStyle, canvasStyle.rawValue) }
    }
    /// Home brand mark style (default `.systemWordmark`).
    var brandMarkStyle: AmberBrandMarkStyle {
        didSet { persistString(Keys.brandMark, brandMarkStyle.rawValue) }
    }
    /// Home shortcut icon skin (default `.phosphorFill`). Conversation list icons are independent.
    var shortcutIconStyle: AmberShortcutIconStyle {
        didSet { persistString(Keys.shortcutIconStyle, shortcutIconStyle.rawValue) }
    }
    /// Home chrome typeface (brand / section / shortcut labels). Never writes chat body font prefs.
    var chromeTypeface: AmberChromeTypeface {
        didSet { persistString(Keys.chromeTypeface, chromeTypeface.rawValue) }
    }
    var canvasScope: AmberCanvasScope {
        didSet { persistString(Keys.canvasScope, canvasScope.rawValue) }
    }
    var bubbleChrome: AmberBubbleChrome {
        didSet { persistString(Keys.bubbleChrome, bubbleChrome.rawValue) }
    }
    var glassChrome: AmberGlassChrome {
        didSet { persistString(Keys.glassChrome, glassChrome.rawValue) }
    }
    var emptyArt: AmberEmptyArtStyle {
        didSet { persistString(Keys.emptyArt, emptyArt.rawValue) }
    }
    var settingsChrome: Bool {
        didSet { persistBool(Keys.settingsChrome, settingsChrome) }
    }
    var launchBrand: AmberLaunchBrandStyle {
        didSet { persistString(Keys.launchBrand, launchBrand.rawValue) }
    }
    var assetMode: AmberThemeAssetMode {
        didSet { persistString(Keys.assetMode, assetMode.rawValue) }
    }
    var immersivePolicy: AmberImmersivePolicy {
        didSet { persistString(Keys.immersivePolicy, immersivePolicy.rawValue) }
    }

    /// In-memory try-on. Display tokens change; UserDefaults stay on the baseline until `commitTryOn`.
    private(set) var tryOnSession: AmberThemeTryOnSession?
    var isTryOnActive: Bool { tryOnSession != nil }
    var tryOnDisplayName: String? { tryOnSession?.candidate.displayName }

    /// When false, slot `didSet` skips UserDefaults. Try-on applies here.
    private var persistEnabled = true

    private enum Keys {
        static let selectedThemeID = "app.amber.ios.theme.selectedThemeID"
        static let selectedThemeName = "app.amber.ios.theme.selectedThemeName"
        static let design = "app.amber.ios.theme.design"
        static let paper = "app.amber.ios.theme.paper"
        static let accent = "app.amber.ios.theme.accentHex"
        static let accentInk = "app.amber.ios.theme.accentInkHex"
        static let canvasStyle = "app.amber.ios.theme.canvasStyle"
        static let brandMark = "app.amber.ios.theme.brandMarkStyle"
        static let shortcutIconStyle = "app.amber.ios.theme.shortcutIconStyle"
        static let chromeTypeface = "app.amber.ios.theme.chromeTypeface"
        static let canvasScope = "app.amber.ios.theme.canvasScope"
        static let bubbleChrome = "app.amber.ios.theme.bubbleChrome"
        static let glassChrome = "app.amber.ios.theme.glassChrome"
        static let emptyArt = "app.amber.ios.theme.emptyArt"
        static let settingsChrome = "app.amber.ios.theme.settingsChrome"
        static let launchBrand = "app.amber.ios.theme.launchBrand"
        static let assetMode = "app.amber.ios.theme.assetMode"
        static let immersivePolicy = "app.amber.ios.theme.immersivePolicy"
    }

    private init() {
        let d = UserDefaults.standard
        selectedThemeID = d.string(forKey: Keys.selectedThemeID)
        selectedThemeName = d.string(forKey: Keys.selectedThemeName)
        let savedDesign = d.data(forKey: Keys.design).flatMap { try? JSONDecoder().decode(AmberThemeDesign.self, from: $0) }
        if let savedDesign, (try? savedDesign.validate()) != nil {
            design = savedDesign
        } else {
            design = nil
        }
        // 默认主题 = 中性暖灰 × 琥珀金（E 版定稿）；用户显式选择过的偏好仍以持久化值为准。
        // Style 槽缺省 = 现状观感，旧安装升级后仍匹配原 6 色 pack。
        paper = Paper(rawValue: d.string(forKey: Keys.paper) ?? "") ?? .neutral
        accentHex = (d.object(forKey: Keys.accent) as? Int).map { UInt32($0) } ?? AmberAccentOption.amberGold.accentHex
        accentInkHex = (d.object(forKey: Keys.accentInk) as? Int).map { UInt32($0) } ?? AmberAccentOption.amberGold.inkHex
        canvasStyle = AmberCanvasStyle(rawValue: d.string(forKey: Keys.canvasStyle) ?? "") ?? .flat
        brandMarkStyle = AmberBrandMarkStyle(rawValue: d.string(forKey: Keys.brandMark) ?? "") ?? .systemWordmark
        shortcutIconStyle = AmberShortcutIconStyle(rawValue: d.string(forKey: Keys.shortcutIconStyle) ?? "") ?? .phosphorFill
        chromeTypeface = AmberChromeTypeface(rawValue: d.string(forKey: Keys.chromeTypeface) ?? "") ?? .system
        canvasScope = AmberCanvasScope(rawValue: d.string(forKey: Keys.canvasScope) ?? "") ?? .homeOnly
        bubbleChrome = AmberBubbleChrome(rawValue: d.string(forKey: Keys.bubbleChrome) ?? "") ?? .standard
        glassChrome = AmberGlassChrome(rawValue: d.string(forKey: Keys.glassChrome) ?? "") ?? .standard
        emptyArt = AmberEmptyArtStyle(rawValue: d.string(forKey: Keys.emptyArt) ?? "") ?? .none
        settingsChrome = d.object(forKey: Keys.settingsChrome) as? Bool ?? false
        launchBrand = AmberLaunchBrandStyle(rawValue: d.string(forKey: Keys.launchBrand) ?? "") ?? .none
        assetMode = AmberThemeAssetMode(rawValue: d.string(forKey: Keys.assetMode) ?? "") ?? .builtinOnly
        immersivePolicy = AmberImmersivePolicy(rawValue: d.string(forKey: Keys.immersivePolicy) ?? "") ?? .hidden
        // Pi builtin withdrew chat texture: migrate legacy appWide lineGrid on pi paper → shell.
        // didSet 在 init 内不触发，需显式落盘，否则下次冷启动仍读到 appWide。
        if design == nil, paper == .pi, canvasStyle == .lineGrid, canvasScope == .appWide {
            canvasScope = .shell
            d.set(AmberCanvasScope.shell.rawValue, forKey: Keys.canvasScope)
        }
    }

    func apply(_ paper: Paper) {
        if design != nil || self.paper != paper {
            rememberThemeIdentity(id: nil, displayName: nil)
        }
        design = nil
        self.paper = paper
    }

    func apply(_ option: AmberAccentOption) {
        if accentHex != option.accentHex || accentInkHex != option.inkHex {
            rememberThemeIdentity(id: nil, displayName: nil)
        }
        accentHex = option.accentHex
        accentInkHex = option.inkHex
    }

    func rememberThemeIdentity(id: String?, displayName: String?) {
        selectedThemeID = id
        selectedThemeName = displayName
    }

    /// Library deletion detaches identity even while preference writes are
    /// suspended for try-on. Reverting may restore colors, never a deleted id.
    func forgetThemeIdentity(id: String) {
        if selectedThemeID == id {
            rememberThemeIdentity(id: nil, displayName: nil)
        }
        if tryOnSession?.baseline.id == id {
            tryOnSession?.baseline.id = "custom"
            tryOnSession?.baseline.displayName = "自定义"
        }
        if UserDefaults.standard.string(forKey: Keys.selectedThemeID) == id {
            UserDefaults.standard.removeObject(forKey: Keys.selectedThemeID)
            UserDefaults.standard.removeObject(forKey: Keys.selectedThemeName)
        }
    }

    /// Wear `candidate` on screen without writing UserDefaults. A second call
    /// replaces the candidate but keeps the original baseline. Persistence stays
    /// off until commit / discard / appearance takeover.
    @MainActor
    @discardableResult
    func beginTryOn(_ candidate: AmberThemePackDocument, approval: AmberThemeTryOnApproval? = nil) throws -> UUID {
        if AmberThemePackLibrary.isBuiltinId(candidate.id) {
            throw AmberThemeTryOnError.reservedBuiltinId(candidate.id)
        }
        try AmberThemePackTransfer.validate(candidate)
        let baseline = tryOnSession?.baseline ?? AmberThemePackTransfer.document(from: self)
        persistEnabled = false
        do {
            try apply(candidate)
            let session = AmberThemeTryOnSession(baseline: baseline, candidate: candidate, approval: approval)
            tryOnSession = session
            return session.id
        } catch {
            persistEnabled = true
            throw error
        }
    }

    /// Persist the candidate slots. Does not write the theme library.
    @MainActor
    func commitTryOn() throws {
        guard let session = tryOnSession else {
            throw AmberThemeTryOnError.noActiveTryOn
        }
        persistEnabled = true
        try apply(session.candidate)
        tryOnSession = nil
    }

    /// Restore baseline slots in memory; UserDefaults already hold the baseline.
    @MainActor
    func discardTryOn() {
        guard let session = tryOnSession else { return }
        persistEnabled = false
        try? apply(session.baseline)
        persistEnabled = true
        tryOnSession = nil
    }

    /// Drop the try-on session without restoring baseline (Appearance takeover).
    @MainActor
    func endTryOnWithoutRestore() {
        persistEnabled = true
        tryOnSession = nil
    }

    private func persistString(_ key: String, _ value: String?) {
        guard persistEnabled else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    private func persistInt(_ key: String, _ value: Int) {
        guard persistEnabled else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    private func persistBool(_ key: String, _ value: Bool) {
        guard persistEnabled else { return }
        UserDefaults.standard.set(value, forKey: key)
    }
}

struct AmberThemeTryOnApproval: Equatable {
    let runId: String
    let requestId: String
}

struct AmberThemeTryOnSession: Equatable {
    let id = UUID()
    var baseline: AmberThemePackDocument
    let candidate: AmberThemePackDocument
    let approval: AmberThemeTryOnApproval?
}

extension Notification.Name {
    /// Appearance picked a different pack while an agent try-on was live.
    static let amberThemeTryOnTakenOver = Notification.Name("app.amber.ios.theme.tryOnTakenOver")
}

enum AmberThemeTryOnError: LocalizedError, Equatable {
    case reservedBuiltinId(String)
    case noActiveTryOn
    case replacedTryOn

    var errorDescription: String? {
        switch self {
        case .reservedBuiltinId(let id):
            "id「\(id)」是内置主题，请换一个新 id。"
        case .noActiveTryOn:
            "当前没有试穿中的主题。"
        case .replacedTryOn:
            "这次主题试穿已被替换或结束，请确认当前的主题预览。"
        }
    }
}

/// Authoritative accent set + paired ink (redesign/aa-base.jsx ACCENT_INK). High-luminance hues
/// (sage, amber gold) pair with dark ink; the rest with white — never a blanket white.
enum AmberAccentOption: String, CaseIterable, Identifiable {
    case amberGold, terracotta, sage, mistBlue, steelBlue, notionBlue, wisteria, rose, ink

    var id: String { rawValue }

    var accentHex: UInt32 {
        switch self {
        case .amberGold:  0xB9863A
        case .terracotta: 0xB8623A
        case .sage:       0x5E9C6E
        case .mistBlue:   0x4F86D6
        case .steelBlue:  0x6B8CAD // pi-dotgrid / Open Design
        case .notionBlue: 0x0075DE // Notion Blue (blank-workspace)
        case .wisteria:   0x9277C4
        case .rose:       0xC2607A
        case .ink:        0x222226
        }
    }

    var inkHex: UInt32 {
        switch self {
        case .sage:       0x0F150E
        case .amberGold:  0x231602
        case .steelBlue:  0xFAF9F7 // cream ink on steel blue (brand-spec)
        case .notionBlue: 0xFFFFFF
        default:          0xFFFFFF
        }
    }

    var displayName: String {
        let key: String
        switch self {
        case .terracotta: key = "陶土"
        case .sage:       key = "鼠尾草绿"
        case .mistBlue:   key = "雾蓝"
        case .steelBlue:  key = "钢蓝"
        case .notionBlue: key = "Notion 蓝"
        case .wisteria:   key = "紫藤"
        case .rose:       key = "玫红"
        case .amberGold:  key = "琥珀金"
        case .ink:        key = "墨黑"
        }
        return IOSAppLocalization.string(key, defaultValue: key)
    }
}

enum IOSAppearancePreferenceKeys {
    static let mode = "app.amber.ios.appearance.mode"
}

enum IOSAppearanceMode: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "浅色"
        case .dark: "深色"
        case .system: "跟随系统"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }
}

enum IOSDisplayPreferenceKeys {
    static let fontScale = "app.amber.ios.display.fontScale"
    static let chatFont = "app.amber.ios.display.chatFont"
    static let agentName = "app.amber.ios.display.agentName"
    static let followGeneration = "app.amber.ios.display.followGeneration"
    static let activityIslandEdgeGlow = "app.amber.ios.display.activityIslandEdgeGlow"
    static let completionHaptic = "app.amber.ios.display.completionHaptic"
    static let streamingBlockMarkdown = "app.amber.ios.display.streamingBlockMarkdown"
    static let coalescedTextBlocks = "app.amber.ios.display.coalescedTextBlocks"
}

enum IOSChatFont: String, CaseIterable, Identifiable {
    case `default`
    case serif
    case monospace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: "默认"
        case .serif: "衬线体"
        case .monospace: "等宽字体"
        }
    }

    private var bundledFontName: String? {
        switch self {
        case .default: nil
        case .serif: "NotoSerifSC-Regular"
        case .monospace: "JetBrainsMono-Regular"
        }
    }

    func font(size: CGFloat) -> Font {
        guard let bundledFontName else { return .system(size: size) }
        // Callers already apply Dynamic Type through @ScaledMetric.
        return .custom(bundledFontName, fixedSize: size)
    }

    func applying(to font: UIFont) -> UIFont {
        guard let bundledFontName else { return font }
        let base = UIFont(descriptor: UIFontDescriptor(name: bundledFontName, size: font.pointSize), size: font.pointSize)
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        // Copying the system design trait forces a fallback to SF. Match by family
        // and weight so the bundled variable fonts can select their bold instances.
        var descriptor = UIFontDescriptor(fontAttributes: [
            .family: base.familyName,
            .traits: [UIFontDescriptor.TraitKey.weight: traits?[.weight] ?? UIFont.Weight.regular.rawValue]
        ])
        if font.fontDescriptor.symbolicTraits.contains(.traitItalic) {
            // Neither bundled family includes italic faces; preserve Markdown emphasis.
            descriptor = descriptor.withMatrix(CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0))
        }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255.0,
            green: Double((hex >> 8) & 0xff) / 255.0,
            blue: Double(hex & 0xff) / 255.0,
            opacity: alpha
        )
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            red: CGFloat((hex >> 16) & 0xff) / 255.0,
            green: CGFloat((hex >> 8) & 0xff) / 255.0,
            blue: CGFloat(hex & 0xff) / 255.0,
            alpha: CGFloat(alpha)
        )
    }
}

enum AmberHapticEvent {
    case lightImpact
    case mediumImpact
    case rigidImpact
    case selection
    case success
    case warning
    case error
}

enum AmberHaptics {
    /// 取证 canary：真机连 Mac 时用
    /// `idevicesyslog | grep amber-haptic` 可裁决「振感是否来自本 app」
    /// （用户曾报告完成时物理振动与代码振源不对应的未结之谜）。
    private static let logger = os.Logger(subsystem: "app.amber.ios", category: "amber-haptic")

    @MainActor
    static func trigger(_ event: AmberHapticEvent) {
        logger.info("haptic \(String(describing: event), privacy: .public)")
        switch event {
        case .lightImpact:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .mediumImpact:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .rigidImpact:
            // 生成完成提示：单次刚性轻触，短促清脆，避免 notification 双连震的「蹦蹦」手感。
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

struct AmberPressFeedbackStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96
    var haptic: AmberHapticEvent? = .lightImpact

    func makeBody(configuration: Configuration) -> some View {
        AmberPressFeedbackBody(
            configuration: configuration,
            pressedScale: pressedScale,
            haptic: haptic
        )
    }
}

private struct AmberPressFeedbackBody: View {
    let configuration: ButtonStyleConfiguration
    let pressedScale: CGFloat
    let haptic: AmberHapticEvent?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wasPressed = false

    var body: some View {
        configuration.label
            .scaleEffect(isEnabled && configuration.isPressed ? pressedScale : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.72),
                value: configuration.isPressed
            )
            .onChange(of: configuration.isPressed) { _, isPressed in
                defer { wasPressed = isPressed }
                guard isEnabled, isPressed, !wasPressed, let haptic else { return }
                AmberHaptics.trigger(haptic)
            }
    }
}

private struct AmberGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let interactive: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let control = content
            .contentShape(shape)

        if #available(iOS 26.0, *) {
            if interactive {
                control
                    .background(AmberTheme.glass.opacity(0.35), in: shape)
                    .glassEffect(.regular.interactive(), in: shape)
            } else {
                control
                    .background(AmberTheme.glass.opacity(0.35), in: shape)
                    .glassEffect(.regular, in: shape)
            }
        } else {
            control
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape
                        .stroke(.white.opacity(0.65), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.10), radius: 12, y: 2)
        }
    }
}

private struct AmberProminentGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color
    let interactive: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let control = content
            .contentShape(shape)

        if #available(iOS 26.0, *) {
            // Solid accent fill + a full-tint glass sheen so prominent buttons (the new-chat FAB,
            // prominent icon/pill buttons) actually read as the standard accent instead of the
            // washed-out 0.24/0.34-opacity tint they had before.
            if interactive {
                control
                    .background(tint, in: shape)
                    .glassEffect(.regular.tint(tint).interactive(), in: shape)
            } else {
                control
                    .background(tint, in: shape)
                    .glassEffect(.regular.tint(tint), in: shape)
            }
        } else {
            control
                .background(tint, in: shape)
                .shadow(color: tint.opacity(0.32), radius: 18, y: 4)
        }
    }
}

extension View {
    func amberGlass(cornerRadius: CGFloat, interactive: Bool = true) -> some View {
        modifier(AmberGlassModifier(cornerRadius: AmberTheme.controlRadius(cornerRadius), interactive: interactive))
    }

    func amberProminentGlass(
        cornerRadius: CGFloat,
        tint: Color = AmberTheme.accent,
        interactive: Bool = true
    ) -> some View {
        modifier(AmberProminentGlassModifier(cornerRadius: AmberTheme.controlRadius(cornerRadius), tint: tint, interactive: interactive))
    }
}

/// A button's tint, glass silhouette and press deformation must have one owner.
/// Keep raw glass modifiers for surfaces; native button styles own button feedback.
private struct AmberGlassButtonModifier: ViewModifier {
    let cornerRadius: CGFloat
    var prominent = false
    var tint: Color = AmberTheme.accent
    var borderShape: ButtonBorderShape? = nil
    var sizing: ButtonSizing = .flexible

    func body(content: Content) -> some View {
        Group {
            if prominent {
                content.buttonStyle(.glassProminent).tint(tint)
            } else {
                content.buttonStyle(.glass)
            }
        }
        .buttonBorderShape(borderShape ?? .roundedRectangle(radius: AmberTheme.controlRadius(cornerRadius)))
        .buttonSizing(sizing)
    }
}

extension View {
    func amberGlassButton(
        cornerRadius: CGFloat,
        prominent: Bool = false,
        tint: Color = AmberTheme.accent,
        borderShape: ButtonBorderShape? = nil,
        sizing: ButtonSizing = .flexible
    ) -> some View {
        modifier(AmberGlassButtonModifier(
            cornerRadius: cornerRadius, prominent: prominent, tint: tint,
            borderShape: borderShape, sizing: sizing
        ))
    }
}

struct AmberGlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

struct AmberGlassIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var size: CGFloat = 32
    var symbolSize: CGFloat = 15
    var tint: Color = AmberTheme.foreground2
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button {
            AmberHaptics.trigger(.lightImpact)
            action()
        } label: {
            iconLabel
        }
        .amberGlassButton(cornerRadius: size / 2, prominent: prominent, tint: tint)
        .controlSize(.mini)
        .frame(width: size, height: size)
        .accessibilityLabel(accessibilityLabel)
    }

    private var iconLabel: some View {
        Image(systemName: systemImage)
            .font(.system(size: symbolSize, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AmberGlassTextChip: View {
    let title: String
    var isSelected = false
    var tint: Color = AmberTheme.accent
    var height: CGFloat = 30
    var horizontalPadding: CGFloat = 12
    var fillsWidth = false
    var font: Font = .caption.weight(.semibold)

    var body: some View {
        if isSelected {
            label
                .foregroundStyle(Color.white)
                .amberProminentGlass(cornerRadius: height / 2, tint: tint)
        } else {
            label
                .foregroundStyle(AmberTheme.foreground2)
                .amberGlass(cornerRadius: height / 2)
        }
    }

    private var label: some View {
        Text(title)
            .font(font)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: height)
            .padding(.horizontal, horizontalPadding)
    }
}

struct AmberGlassCircleButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var size: CGFloat = 44
    var symbolSize: CGFloat = 17
    /// Top-bar chrome default: theme ink (not accent). Pass accent only for rare primary actions.
    var tint: Color = AmberTheme.foreground
    let action: () -> Void

    var body: some View {
        Button {
            AmberHaptics.trigger(.lightImpact)
            action()
        } label: {
            iconLabel
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.mini)
        .buttonSizing(.flexible)
        .frame(width: size, height: size)
        .accessibilityLabel(accessibilityLabel)
    }

    private var iconLabel: some View {
        Image(systemName: systemImage)
            .font(.system(size: symbolSize, weight: .semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AmberSectionLabel: View {
    private let label: Text

    init(text: LocalizedStringKey) {
        label = Text(text)
    }

    init(verbatim text: String) {
        label = Text(verbatim: text)
    }

    var body: some View {
        label
            .font(.caption.weight(.semibold))
            .foregroundStyle(AmberTheme.muted)
            .textCase(.uppercase)
            .tracking(0.4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 7)
            .accessibilityAddTraits(.isHeader)
    }
}

struct AmberFormGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(AmberTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
        .padding(.horizontal, 16)
    }
}

struct AmberFormRow: View {
    let systemImage: String?
    let iconColor: Color
    /// 设置首页方案 B：统一 accent 浅底圆角方块 + 图标色（默认关，免影响 Workspace 等状态色行）。
    var iconUsesAccentPlate: Bool = false
    let title: String
    let subtitle: String?
    let trailing: String?
    let showsChevron: Bool
    let action: (() -> Void)?

    init(
        systemImage: String? = nil,
        iconColor: Color = AmberTheme.accent,
        iconUsesAccentPlate: Bool = false,
        title: String,
        subtitle: String? = nil,
        trailing: String? = nil,
        showsChevron: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.iconUsesAccentPlate = iconUsesAccentPlate
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.showsChevron = showsChevron
        self.action = action
    }

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: iconUsesAccentPlate ? 15 : 16, weight: .medium))
                        .foregroundStyle(iconColor)
                        .frame(width: 28, height: 28)
                        .background {
                            if iconUsesAccentPlate {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(AmberTheme.accentTint)
                            }
                        }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(AmberTheme.foreground)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let trailing {
                    Text(trailing)
                        .font(.subheadline)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(1)
                }

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.muted2)
                }
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: action == nil ? 1 : 0.985, haptic: .selection))
        .disabled(action == nil)
    }
}
