import Foundation
import SwiftUI

/// Validation failures for an imported or generated design theme.
enum AmberThemeDesignValidationError: LocalizedError, Equatable, Hashable, Sendable {
    case invalidColor(field: String, value: String)
    case invalidContrast(field: String, ratio: Double, minimum: Double)
    case invalidCount(field: String, count: Int, minimum: Int, maximum: Int)
    case invalidValue(field: String, value: String, expected: String)
    case invalidPatternKind(field: String, value: String)

    var errorDescription: String? {
        switch self {
        case let .invalidColor(field, value):
            return "设计主题字段 \(field) 的颜色无效：\(value)"
        case let .invalidContrast(field, ratio, minimum):
            return String(
                format: "设计主题字段 %@ 的对比度不足（%.2f:1，至少 %.1f:1）",
                field,
                ratio,
                minimum
            )
        case let .invalidCount(field, count, minimum, maximum):
            return "设计主题字段 \(field) 数量无效：\(count)（应为 \(minimum)...\(maximum)）"
        case let .invalidValue(field, value, expected):
            return "设计主题字段 \(field) 数值无效：\(value)（应为 \(expected)）"
        case let .invalidPatternKind(field, value):
            return "设计主题字段 \(field) 图案类型无效：\(value)（可选 dots、grid、diagonal、crosses、waves、rings）"
        }
    }
}

/// A portable, color-and-texture based visual theme recipe.
struct AmberThemeDesign: Codable, Equatable, Hashable, Sendable {
    struct Palette: Codable, Equatable, Hashable, Sendable {
        var background: String
        var surface: String
        var foreground: String
        var mutedForeground: String
        var border: String

        /// Replaces the five semantic canvas tokens and derives the secondary roles from them.
        /// Invalid values fall back to the supplied palette; callers should validate first.
        func resolving(_ base: AmberPalette) -> AmberPalette {
            let resolvedBackground = Self.hex(background, fallback: base.background)
            let resolvedSurface = Self.hex(surface, fallback: base.surface)
            let resolvedForeground = Self.hex(foreground, fallback: base.foreground)
            let resolvedMuted = Self.hex(mutedForeground, fallback: base.muted)
            let resolvedBorder = Self.hex(border, fallback: base.border)
            return AmberPalette(
                background: resolvedBackground,
                surface: resolvedSurface,
                surface2: Self.midpoint(resolvedBackground, resolvedSurface),
                foreground: resolvedForeground,
                foreground2: resolvedForeground,
                muted: resolvedMuted,
                muted2: resolvedMuted,
                border: resolvedBorder,
                borderSoft: resolvedBorder
            )
        }

        private static func hex(_ raw: String, fallback: UInt32) -> UInt32 {
            (try? AmberThemePackTransfer.parseHex(raw)) ?? fallback
        }

        private static func midpoint(_ first: UInt32, _ second: UInt32) -> UInt32 {
            let red = (((first >> 16) & 0xFF) + ((second >> 16) & 0xFF)) / 2
            let green = (((first >> 8) & 0xFF) + ((second >> 8) & 0xFF)) / 2
            let blue = ((first & 0xFF) + (second & 0xFF)) / 2
            return (red << 16) | (green << 8) | blue
        }
    }

    struct Gradient: Codable, Equatable, Hashable, Sendable {
        var colors: [String]
        var darkColors: [String]
        /// Direction in degrees, clockwise from the horizontal axis.
        var angle: Double
    }

    struct Pattern: Codable, Equatable, Hashable, Sendable {
        var kind: String
        var color: String
        var opacity: Double
        var spacing: Double
        var size: Double
    }

    /// Optional component-level controls. A nil value keeps the existing app token.
    struct Components: Codable, Equatable, Hashable, Sendable {
        var cardRadius: Double? = nil
        var bubbleRadius: Double? = nil
        var controlRadius: Double? = nil
        var borderWidth: Double? = nil
        var shadowOpacity: Double? = nil
        var shadowRadius: Double? = nil
        var brandText: String? = nil
        var brandSize: Double? = nil
        var brandTracking: Double? = nil
    }

    /// Omitted palettes inherit the existing paper tokens, including secondary
    /// colors and home chrome. Component-only edits must not recolor the app.
    var light: Palette?
    var dark: Palette?
    var gradient: Gradient?
    var patterns: [Pattern]
    var components: Components? = nil

    private static let patternKinds: Set<String> = [
        "dots", "grid", "diagonal", "crosses", "waves", "rings"
    ]

    /// Validates colors, readability, gradient stops, texture density, and optional controls.
    func validate() throws {
        let lightForeground = try light.map { try Self.validatePalette($0, prefix: "light") }
        let darkForeground = try dark.map { try Self.validatePalette($0, prefix: "dark") }

        if let gradient {
            guard let lightForeground, let darkForeground else {
                throw AmberThemeDesignValidationError.invalidValue(
                    field: "gradient", value: "缺少配色", expected: "渐变需要完整的浅色和深色配色以校验对比度"
                )
            }
            try Self.validateGradientColors(
                gradient.colors,
                field: "gradient.colors",
                foreground: lightForeground
            )
            try Self.validateGradientColors(
                gradient.darkColors,
                field: "gradient.darkColors",
                foreground: darkForeground
            )
            guard gradient.angle.isFinite else {
                throw AmberThemeDesignValidationError.invalidValue(
                    field: "gradient.angle",
                    value: String(describing: gradient.angle),
                    expected: "有限数字"
                )
            }
        }

        try Self.validatePatterns(patterns)
        try Self.validateComponents(components)
    }

    private static func validatePalette(_ palette: Palette, prefix: String) throws -> UInt32 {
        let background = try parseColor(palette.background, field: "\(prefix).background")
        let surface = try parseColor(palette.surface, field: "\(prefix).surface")
        let foreground = try parseColor(palette.foreground, field: "\(prefix).foreground")
        let muted = try parseColor(palette.mutedForeground, field: "\(prefix).mutedForeground")
        _ = try parseColor(palette.border, field: "\(prefix).border")

        try requireContrast(
            foreground,
            background,
            field: "\(prefix).foreground/background",
            minimum: 4.5
        )
        try requireContrast(
            foreground,
            surface,
            field: "\(prefix).foreground/surface",
            minimum: 4.5
        )
        try requireContrast(
            muted,
            background,
            field: "\(prefix).mutedForeground/background",
            minimum: 3
        )
        try requireContrast(
            muted,
            surface,
            field: "\(prefix).mutedForeground/surface",
            minimum: 3
        )
        return foreground
    }

    private static func validateGradientColors(
        _ colors: [String],
        field: String,
        foreground: UInt32
    ) throws {
        guard (2...4).contains(colors.count) else {
            throw AmberThemeDesignValidationError.invalidCount(
                field: field,
                count: colors.count,
                minimum: 2,
                maximum: 4
            )
        }
        for (index, raw) in colors.enumerated() {
            let color = try parseColor(raw, field: "\(field)[\(index)]")
            try requireContrast(
                foreground,
                color,
                field: "\(field)[\(index)]/foreground",
                minimum: 4.5
            )
        }
    }

    private static func validatePatterns(_ patterns: [Pattern]) throws {
        guard patterns.count <= 3 else {
            throw AmberThemeDesignValidationError.invalidCount(
                field: "patterns",
                count: patterns.count,
                minimum: 0,
                maximum: 3
            )
        }

        for (index, pattern) in patterns.enumerated() {
            let prefix = "patterns[\(index)]"
            guard patternKinds.contains(pattern.kind) else {
                throw AmberThemeDesignValidationError.invalidPatternKind(
                    field: "\(prefix).kind",
                    value: pattern.kind
                )
            }
            _ = try parseColor(pattern.color, field: "\(prefix).color")
            try validateNumber(pattern.opacity, field: "\(prefix).opacity", range: "0...0.3") {
                $0 >= 0 && $0 <= 0.3
            }
            try validateNumber(pattern.spacing, field: "\(prefix).spacing", range: "12...120") {
                $0 >= 12 && $0 <= 120
            }
            try validateNumber(pattern.size, field: "\(prefix).size", range: "0.5...8") {
                $0 >= 0.5 && $0 <= 8
            }
        }
    }

    private static func validateComponents(_ components: Components?) throws {
        guard let components else { return }

        try validateOptionalNumber(components.cardRadius, field: "components.cardRadius", range: "0...32") {
            $0 >= 0 && $0 <= 32
        }
        try validateOptionalNumber(components.bubbleRadius, field: "components.bubbleRadius", range: "0...28") {
            $0 >= 0 && $0 <= 28
        }
        try validateOptionalNumber(components.controlRadius, field: "components.controlRadius", range: "0...28") {
            $0 >= 0 && $0 <= 28
        }
        try validateOptionalNumber(components.borderWidth, field: "components.borderWidth", range: "0...3") {
            $0 >= 0 && $0 <= 3
        }
        try validateOptionalNumber(components.shadowOpacity, field: "components.shadowOpacity", range: "0...0.35") {
            $0 >= 0 && $0 <= 0.35
        }
        try validateOptionalNumber(components.shadowRadius, field: "components.shadowRadius", range: "0...24") {
            $0 >= 0 && $0 <= 24
        }
        if let brandText = components.brandText {
            let trimmed = brandText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 16 else {
                throw AmberThemeDesignValidationError.invalidValue(
                    field: "components.brandText",
                    value: brandText,
                    expected: "trim 后 1...16 个字符"
                )
            }
        }
        try validateOptionalNumber(components.brandSize, field: "components.brandSize", range: "20...40") {
            $0 >= 20 && $0 <= 40
        }
        try validateOptionalNumber(components.brandTracking, field: "components.brandTracking", range: "-2...6") {
            $0 >= -2 && $0 <= 6
        }
    }

    private static func parseColor(_ raw: String, field: String) throws -> UInt32 {
        do {
            return try AmberThemePackTransfer.parseHex(raw)
        } catch {
            throw AmberThemeDesignValidationError.invalidColor(field: field, value: raw)
        }
    }

    private static func requireContrast(
        _ first: UInt32,
        _ second: UInt32,
        field: String,
        minimum: Double
    ) throws {
        let ratio = AmberColorContrast.contrastRatio(first, second)
        guard ratio >= minimum else {
            throw AmberThemeDesignValidationError.invalidContrast(
                field: field,
                ratio: ratio,
                minimum: minimum
            )
        }
    }

    private static func validateNumber(
        _ value: Double,
        field: String,
        range: String,
        predicate: (Double) -> Bool
    ) throws {
        guard value.isFinite, predicate(value) else {
            throw AmberThemeDesignValidationError.invalidValue(
                field: field,
                value: String(describing: value),
                expected: range
            )
        }
    }

    private static func validateOptionalNumber(
        _ value: Double?,
        field: String,
        range: String,
        predicate: (Double) -> Bool
    ) throws {
        guard let value else { return }
        try validateNumber(value, field: field, range: range, predicate: predicate)
    }
}

/// Renders a design recipe as a static, non-interactive canvas layer.
struct AmberThemeDesignBackground: View {
    let design: AmberThemeDesign
    var basePalette: AmberPalette? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        let sourcePalette = isDark ? design.dark : design.light
        let runtimePalette = basePalette ?? (isDark
            ? AmberThemeRuntime.shared.paper.darkPalette
            : AmberThemeRuntime.shared.paper.lightPalette)
        let palette = sourcePalette?.resolving(runtimePalette) ?? runtimePalette

        ZStack {
            Color(hex: palette.background)
            if let gradient = design.gradient {
                AmberThemeDesignGradientLayer(
                    colors: isDark ? gradient.darkColors : gradient.colors,
                    angle: gradient.angle
                )
            }
            AmberThemeDesignPatternLayer(patterns: design.patterns)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct AmberThemeDesignGradientLayer: View {
    let colors: [String]
    let angle: Double

    var body: some View {
        let radians = angle.isFinite
            ? angle.truncatingRemainder(dividingBy: 360) * .pi / 180
            : 0
        let dx = CGFloat(cos(radians)) * 0.5
        let dy = CGFloat(sin(radians)) * 0.5
        LinearGradient(
            colors: colors.map(amberThemeDesignColor),
            startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
            endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy)
        )
    }
}

private struct AmberThemeDesignPatternLayer: View {
    let patterns: [AmberThemeDesign.Pattern]

    var body: some View {
        ZStack {
            ForEach(patterns.indices, id: \.self) { index in
                let pattern = patterns[index]
                Canvas { context, size in
                    AmberThemeDesignPatternRenderer.draw(pattern, in: &context, size: size)
                }
                .opacity(amberThemeDesignOpacity(pattern.opacity))
            }
        }
        .allowsHitTesting(false)
    }
}

private enum AmberThemeDesignPatternRenderer {
    private static let canvasLimit: CGFloat = 16_384

    static func draw(
        _ pattern: AmberThemeDesign.Pattern,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        guard pattern.spacing.isFinite, pattern.spacing > 0,
              pattern.size.isFinite, pattern.size > 0 else { return }

        let width = min(size.width, canvasLimit)
        let height = min(size.height, canvasLimit)
        let spacing = CGFloat(pattern.spacing)
        let markSize = CGFloat(pattern.size)
        let lineWidth = max(0.5, markSize * 0.32)
        let columns = max(0, Int(ceil(width / spacing)))
        let rows = max(0, Int(ceil(height / spacing)))
        let color = amberThemeDesignColor(pattern.color)

        switch pattern.kind {
        case "dots":
            for row in 0...rows {
                let y = CGFloat(row) * spacing
                for column in 0...columns {
                    let x = CGFloat(column) * spacing
                    let rect = CGRect(
                        x: x - markSize,
                        y: y - markSize,
                        width: markSize * 2,
                        height: markSize * 2
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }

        case "grid":
            var path = Path()
            for column in 0...columns {
                let x = CGFloat(column) * spacing
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: height))
            }
            for row in 0...rows {
                let y = CGFloat(row) * spacing
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: width, y: y))
            }
            context.stroke(path, with: .color(color), lineWidth: lineWidth)

        case "diagonal":
            var path = Path()
            let count = max(0, Int(ceil((width + height) / spacing)) + 1)
            for index in 0...count {
                let x = -height + CGFloat(index) * spacing
                path.move(to: CGPoint(x: x, y: height))
                path.addLine(to: CGPoint(x: x + height, y: 0))
            }
            context.stroke(path, with: .color(color), lineWidth: lineWidth)

        case "crosses":
            var path = Path()
            for row in 0...rows {
                let y = CGFloat(row) * spacing
                for column in 0...columns {
                    let x = CGFloat(column) * spacing
                    path.move(to: CGPoint(x: x - markSize, y: y))
                    path.addLine(to: CGPoint(x: x + markSize, y: y))
                    path.move(to: CGPoint(x: x, y: y - markSize))
                    path.addLine(to: CGPoint(x: x, y: y + markSize))
                }
            }
            context.stroke(path, with: .color(color), lineWidth: lineWidth)

        case "waves":
            let wavelength = max(spacing * 2, 1)
            let amplitude = max(markSize * 1.5, 0.75)
            let sampleWidth = max(wavelength / 6, 1)
            let sampleCount = max(1, min(512, Int(ceil(width / sampleWidth))))
            for row in 0...rows {
                let baseline = CGFloat(row) * spacing
                var path = Path()
                for sample in 0...sampleCount {
                    let x = CGFloat(sample) / CGFloat(sampleCount) * width
                    let y = baseline + CGFloat(sin(Double(x / wavelength) * 2 * .pi)) * amplitude
                    let point = CGPoint(x: x, y: y)
                    if sample == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
                context.stroke(path, with: .color(color), lineWidth: lineWidth)
            }

        case "rings":
            let radius = max(markSize * 2, 0.5)
            for row in 0...rows {
                let y = CGFloat(row) * spacing
                for column in 0...columns {
                    let x = CGFloat(column) * spacing
                    let rect = CGRect(
                        x: x - radius,
                        y: y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: lineWidth)
                }
            }

        default:
            return
        }
    }
}

private func amberThemeDesignColor(_ raw: String) -> Color {
    Color(hex: (try? AmberThemePackTransfer.parseHex(raw)) ?? 0)
}

private func amberThemeDesignOpacity(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 0.3)
}
