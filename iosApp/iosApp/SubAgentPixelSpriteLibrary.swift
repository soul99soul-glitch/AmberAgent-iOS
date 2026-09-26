import SwiftUI

/// A small, deterministic RPG sprite library for sub-agent avatars.
/// The sprite art is code-native 16×16 data: @ ink, # body, + accent, * highlight.
enum ChatSubAgentPixelSpriteLibrary {
    struct Layer: Identifiable {
        let id: Int
        let bits: [UInt16]
        let color: Color
    }

    private struct Palette {
        let hue: Double
        let saturation: Double
        let accentHue: Double
        let accentSaturation: Double
    }

    private struct Art {
        let name: String
        let motion: MotionPattern
        let palette: Palette
        let rows: [String]
    }

    /// Chibi-style cast: big heads, 2×2 eyes, silhouettes that read as the name.
    /// Every row must be exactly 16 characters wide.
    private static let arts: [Art] = [
        Art(name: "勇者", motion: .hop, palette: Palette(hue: 0.60, saturation: 0.62, accentHue: 0.12, accentSaturation: 0.85), rows: [
            "................", "....@@@@@@....@.", "...@++++++@..@*@", "..@++++++++@.@*@",
            "..@@@@@@@@@@.@*@", "..@********@.@*@", "..@*@@**@@*@.@*@", "..@*@@**@@*@.@*@",
            "..@+******+@@+++", "...@@#@@#@@.@+@.", "..@##@@@@##@@@@.", ".@#@######@#@...",
            ".@@@##++##@@@...", "...@######@.....", "...@##@@##@.....", "...@@@..@@@....."
        ]),
        Art(name: "魔王", motion: .breathe, palette: Palette(hue: 0.78, saturation: 0.55, accentHue: 0.99, accentSaturation: 0.80), rows: [
            "@..............@", "@@............@@", ".@*@..@@@@..@*@.", ".@**@@####@@**@.",
            "..@@########@@..", ".@############@.", ".@#@@@####@@@#@.", ".@##@+@##@+@##@.",
            ".@############@.", "..@##@*@@*@##@..", "..@@@######@@@..", ".@++@@####@@++@.",
            "@+++@######@+++@", "@++@##@##@##@++@", "@++@##@..@##@++@", "@@@.@@@..@@@.@@@"
        ]),
        Art(name: "鸟人", motion: .hop, palette: Palette(hue: 0.55, saturation: 0.60, accentHue: 0.08, accentSaturation: 0.85), rows: [
            "......@@@@......", ".....@#@@#@.....", "....@@#@@#@@....", "...@########@...",
            "..@##########@..", "..@#@*####*@#@..", "..@#@@#@@#@@#@..", "@@.@###@@###@.@@",
            "@#@.@##@@##@.@#@", "@##@@######@@##@", ".@##@######@##@.", "..@@@#****#@@@..",
            "....@#****#@....", ".....@####@.....", ".....@+@@+@.....", "....@++..++@...."
        ]),
        Art(name: "猪头人", motion: .breathe, palette: Palette(hue: 0.95, saturation: 0.40, accentHue: 0.97, accentSaturation: 0.60), rows: [
            "................", "..@@........@@..", ".@+#@@@@@@@@#+@.", ".@##@######@##@.",
            ".@############@.", "@##############@", "@##@*######*@##@", "@##@@######@@##@",
            "@+##@@@@@@@@##+@", "@###@+@++@+@###@", ".@##@@++++@@##@.", "..@*@@@@@@@@*@..",
            ".@@@########@@@.", "@##@########@##@", ".@@@#@@##@@#@@@.", "...@@@.@@.@@@..."
        ]),
        Art(name: "巫师", motion: .float, palette: Palette(hue: 0.70, saturation: 0.60, accentHue: 0.13, accentSaturation: 0.85), rows: [
            "........@@......", ".......@##@.....", "......@###@.....", ".....@##+#@.....",
            ".....@#+###@....", "....@#######@...", "..@@++++++++@@..", ".@@@@@@@@@@@@@@.",
            "...@*@****@*@...", "...@*@****@*@...", "...@**+**+**@...", "..@#@******@#@..",
            ".@##@@****@@##@.", ".@###@@**@@###@.", ".@############@.", ".@@@@@@@@@@@@@@."
        ]),
        Art(name: "骑士", motion: .breathe, palette: Palette(hue: 0.58, saturation: 0.18, accentHue: 0.00, accentSaturation: 0.80), rows: [
            ".......@@.......", "......@++@......", ".....@++++@.....", "....@@@++@@@....",
            "...@#*####*#@...", "..@##########@..", "..@@@@@@@@@@@@..", "..@#@**@@**@#@..",
            "..@@@@@@@@@@@@..", "..@##########@..", "...@@######@@...", ".@##@@++++@@##@.",
            ".@##@+****+@##@.", "..@@@@+**+@@@@..", "...@##@@@@##@...", "...@@@....@@@..."
        ]),
        Art(name: "骷髅", motion: .hop, palette: Palette(hue: 0.12, saturation: 0.10, accentHue: 0.50, accentSaturation: 0.80), rows: [
            "................", ".....@@@@@@.....", "...@@******@@...", "..@**********@..",
            "..@**********@..", "..@*@@@**@@@*@..", "..@*@+@**@+@*@..", "..@*@@@**@@@*@..",
            "...@@******@@...", "....@*@**@*@....", ".....@@@@@@.....", "...@@*@**@*@@...",
            "..@*@@****@@*@..", "...@@*@**@*@@...", "....@*@..@*@....", "....@@@..@@@...."
        ]),
        Art(name: "史莱姆", motion: .breathe, palette: Palette(hue: 0.33, saturation: 0.62, accentHue: 0.95, accentSaturation: 0.55), rows: [
            "................", ".......@@.......", "......@##@......", ".....@####@.....",
            "....@#*####@....", "...@#*######@...", "..@##########@..", ".@###@*##@*###@.",
            ".@###@@##@@###@.", "@##+###@@###+##@", "@######@@######@", "@##############@",
            "@##############@", ".@############@.", "..@@@@@@@@@@@@..", "................"
        ]),
        Art(name: "蘑菇怪", motion: .breathe, palette: Palette(hue: 0.00, saturation: 0.72, accentHue: 0.10, accentSaturation: 0.25), rows: [
            "................", ".....@@@@@@.....", "...@@##**##@@...", "..@#**####**#@..",
            ".@##**####**##@.", ".@######**####@.", "@###**##**##*##@", "@###**######*##@",
            "@@@@@@@@@@@@@@@@", "...@++++++++@...", "...@+@*++@*+@...", "...@+@@++@@+@...",
            "...@++++++++@...", "...@+++@@+++@...", "....@++++++@....", "...@@@@..@@@@..."
        ]),
        Art(name: "外星人", motion: .float, palette: Palette(hue: 0.25, saturation: 0.55, accentHue: 0.90, accentSaturation: 0.70), rows: [
            ".++..........++.", ".++@........@++.", "...@..@@@@..@...", "....@@####@@....",
            "...@########@...", "..@##########@..", ".@############@.", ".@#@@@####@@@#@.",
            ".@#@*@@##@@*@#@.", ".@#@@@@##@@@@#@.", "..@##########@..", "...@###@@###@...",
            "....@@####@@....", "....@######@....", "....@#@..@#@....", "....@@@..@@@...."
        ]),
        Art(name: "龙", motion: .breathe, palette: Palette(hue: 0.42, saturation: 0.60, accentHue: 0.12, accentSaturation: 0.80), rows: [
            "..@..........@..", ".@+@........@+@.", ".@+@.@@@@@@.@+@.", "..@+@######@+@..",
            "..@##########@..", ".@##@*####*@##@.", ".@##@@####@@##@.", ".@############@.",
            "..@#@######@#@..", "@..@@@@@@@@@@..@", "@@.@#++++++#@.@@", "@#@@#++++++#@@#@",
            "@##@#++++++#@##@", ".@@@########@@@.", "...@#@@##@@#@...", "...@@@.@@.@@@..."
        ]),
        Art(name: "猫妖", motion: .hop, palette: Palette(hue: 0.80, saturation: 0.30, accentHue: 0.93, accentSaturation: 0.55), rows: [
            "..@..........@..", "..@@........@@..", "..@+@......@+@..", "..@++@@@@@@++@..",
            "..@##########@..", ".@############@.", ".@##@*####*@##@.", "@@##@@####@@##@@",
            ".@+####@@####+@.", "..@##########@..", "...@@######@@...", "..@#@######@#@..",
            "..@#@######@#@..", "..@##########@..", "..@#@@####@@#@..", "..@@@.@@@@.@@@.."
        ]),
        Art(name: "狐狸", motion: .hop, palette: Palette(hue: 0.07, saturation: 0.80, accentHue: 0.10, accentSaturation: 0.10), rows: [
            ".@@........@@...", ".@+@......@+@...", ".@++@@@@@@++@...", ".@##########@...",
            "@############@..", "@##@*####@*##@..", "@##@@####@@##@..", ".@++++@@++++@...",
            "..@++++++++@....", "...@@####@@...@.", "..@########@.@#@", "..@##++++##@@##@",
            "..@##++++##@##@.", "..@########@#@..", "..@##@..@##@@...", "..@@@....@@@...."
        ]),
        Art(name: "南瓜怪", motion: .breathe, palette: Palette(hue: 0.07, saturation: 0.85, accentHue: 0.15, accentSaturation: 0.85), rows: [
            "................", ".......@@@......", "......@#@.......", "....@@@@@@@@....",
            "..@@###@@###@@..", ".@###@####@###@.", "@###@######@###@", "@##@+@####@+@##@",
            "@#@+++@##@+++@#@", "@###@######@###@", "@##@++++++++@##@", "@##@+@++++@+@##@",
            "@###@#@##@#@###@", ".@###@####@###@.", "..@@@@@@@@@@@@..", "................"
        ]),
        Art(name: "独眼巨人", motion: .breathe, palette: Palette(hue: 0.08, saturation: 0.40, accentHue: 0.55, accentSaturation: 0.70), rows: [
            "................", ".......@@.......", "......@++@......", "....@@@@@@@@....",
            "...@########@...", "..@###@@@@###@..", "..@##@****@##@..", "..@##@*@@*@##@..",
            "..@###@@@@###@..", "..@##########@..", "..@###@@@@###@..", ".@@@########@@@.",
            "@##@########@##@", ".@@@########@@@.", "...@##@@@@##@...", "...@@@....@@@..."
        ]),
        Art(name: "机器人", motion: .float, palette: Palette(hue: 0.52, saturation: 0.30, accentHue: 0.00, accentSaturation: 0.75), rows: [
            ".......@@.......", ".......++.......", ".......@@.......", "..@@@@@@@@@@@@..",
            "..@##########@..", "..@#@@@@@@@@#@..", "..@#@*+@@+*@#@..", "..@#@@@@@@@@#@..",
            "..@##########@..", "..@@@@@@@@@@@@..", "....@######@....", ".@@@@+####+@@@@.",
            "@##@########@##@", ".@@@#@@##@@#@@@.", "...@#@....@#@...", "...@@@....@@@..."
        ]),
        Art(name: "树精", motion: .breathe, palette: Palette(hue: 0.30, saturation: 0.55, accentHue: 0.08, accentSaturation: 0.50), rows: [
            "....@@@@@@@@....", "..@@########@@..", ".@###*####*###@.", "@#####*##*#####@",
            "@##############@", ".@@@@@@@@@@@@@@.", "..@++++@@++++@..", "..@+@*++++*@+@..",
            "..@+@@++++@@+@..", "..@+++@++@+++@..", "@.@++++@@++++@.@", "@@@++++++++++@@@",
            "..@++@++++@++@..", "..@++++++++++@..", ".@+@@+@@@@+@@+@.", ".@@..@@..@@..@@."
        ]),
        Art(name: "幽灵", motion: .float, palette: Palette(hue: 0.66, saturation: 0.12, accentHue: 0.95, accentSaturation: 0.55), rows: [
            "................", ".....@@@@@@.....", "...@@******@@...", "..@**********@..",
            "..@**********@..", "..@**@@**@@**@..", "..@**@@**@@**@..", "@@@*+**@@**+*@@@",
            "@**@***@@***@**@", ".@@@********@@@.", "...@********@...", "...@********@...",
            "...@********@...", "...@**@**@**@...", "...@@.@@.@@.@...", "................"
        ]),
        Art(name: "石头人", motion: .breathe, palette: Palette(hue: 0.10, saturation: 0.12, accentHue: 0.30, accentSaturation: 0.55), rows: [
            "................", "...@@@@@@@@@@...", "..@##########@..", "..@#+@####@+#@..",
            "..@#@*####*@#@..", "..@##########@..", "@@@@@@@@@@@@@@@@", "@###@######@###@",
            "@#+#@######@#+#@", "@###@######@###@", "@@@@#@####@#@@@@", "...@#@####@#@...",
            "...@########@...", "..@@@@@##@@@@@..", "..@###@..@###@..", "..@@@@@..@@@@@.."
        ]),
        Art(name: "章鱼", motion: .float, palette: Palette(hue: 0.92, saturation: 0.55, accentHue: 0.60, accentSaturation: 0.40), rows: [
            "................", ".....@@@@@@.....", "...@@######@@...", "..@##*####*##@..",
            "..@#*######*#@..", "..@##########@..", "..@#@*####*@#@..", "..@#@@####@@#@..",
            "..@+########+@..", "...@########@...", "..@#@##@@##@#@..", ".@#@@#@##@#@@#@.",
            "@#@.@#@##@#@.@#@", "@#@.@#@..@#@.@#@", ".@#@.@@..@@.@#@.", "..@..........@.."
        ]),
        Art(name: "精灵", motion: .hop, palette: Palette(hue: 0.35, saturation: 0.40, accentHue: 0.14, accentSaturation: 0.80), rows: [
            "......@@@@......", ".....@++++@.....", "....@++++++@....", "...@++++++++@...",
            "@@@++++++++++@@@", "@*@**********@*@", ".@@*@@****@@*@@.", "..@*@@****@@*@..",
            "..@+********+@..", "...@@*@@@@*@@...", "...@########@...", "..@*@######@*@..",
            "..@@@######@@@..", "....@#@@@@#@....", "....@#@..@#@....", "....@@@..@@@...."
        ]),
        Art(name: "忍者", motion: .hop, palette: Palette(hue: 0.65, saturation: 0.35, accentHue: 0.00, accentSaturation: 0.80), rows: [
            "................", ".....@@@@@@.....", "...@@######@@...", "..@##########@..",
            "..@++++++++++@@@", "..@@@@@@@@@@@@+@", "..@#*****@**#@.+", "..@#@****@@*#@..",
            "..@@@@@@@@@@@@..", "..@##########@..", "...@@######@@...", "..@##@@##@@##@..",
            ".@##@######@##@.", "..@@@##++##@@@..", "...@##@..@##@...", "...@@@....@@@..."
        ]),
        Art(name: "天使", motion: .float, palette: Palette(hue: 0.13, saturation: 0.15, accentHue: 0.14, accentSaturation: 0.85), rows: [
            ".....@@@@@@.....", "....@+....+@....", ".....@@@@@@.....", "......@@@@......",
            ".@@..@****@..@@.", "@**@@******@@**@", "@***@*@**@*@***@", "@****@@**@@****@",
            ".@***+****+***@.", "..@@**@@@@**@@..", "..@*@******@*@..", ".@**@******@**@.",
            "..@@@******@@@..", "....@******@....", "....@*@@@@*@....", "....@@@..@@@...."
        ]),
        Art(name: "蝙蝠", motion: .float, palette: Palette(hue: 0.75, saturation: 0.35, accentHue: 0.00, accentSaturation: 0.85), rows: [
            "................", "...@........@...", "...@@......@@...", "...@#@@@@@@#@...",
            "...@########@...", "@..@#@*##*@#@..@", "@@.@#@@##@@#@.@@", "@#@@###**###@@#@",
            "@##@@######@@##@", "@###@######@###@", "@#@#@######@#@#@", "@@.@@######@@.@@",
            "@...@@####@@...@", ".....@####@.....", "......@@@@......", "................"
        ])
    ]

    private static func seed(for identity: String) -> UInt64 {
        identity.utf8.reduce(UInt64(14695981039346656037)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1099511628211
        }
    }

    static let spriteCount = arts.count
    static let spriteNames = arts.map(\.name)
    static let baseFaceCount = spriteCount
    private static let masks: [[[UInt16]]] = arts.map { makeMasks(rows: $0.rows) }

    /// Run-cycle motion for one character. Frames are derived from the base
    /// art by 1px row shifts, so all characters animate without hand-drawn
    /// sprite sheets: 0 = base, 1 = crouch (sinks 1px), 2 = rise (hops 1px).
    enum MotionPattern {
        case hop
        case breathe
        case float

        var stepSequence: [Int] {
            switch self {
            case .hop: [0, 1, 2, 0]
            case .breathe: [0, 1, 1, 0]
            case .float: [0, 2, 0, 2]
            }
        }

        /// Hover drifts slower than a hop so the pattern reads by feel alone.
        var tempoScale: Double {
            switch self {
            case .hop: 1.0
            case .breathe: 1.2
            case .float: 1.35
            }
        }
    }

    private static let motionGeometry: [[[[UInt16]]]] = masks.map { layers in
        [layers, layers.map(crouched), layers.map(airborne)]
    }

    static func spriteIndex(for identity: String) -> Int {
        let hash = seed(for: identity)
        let mixed = hash ^ (hash >> 8) ^ (hash >> 16) ^ (hash >> 24)
            ^ (hash >> 32) ^ (hash >> 40) ^ (hash >> 48) ^ (hash >> 56)
        return Int(mixed % UInt64(spriteCount))
    }

    static func baseFaceIndex(for identity: String) -> Int {
        spriteIndex(for: identity)
    }

    static func spriteName(for identity: String) -> String {
        spriteNames[spriteIndex(for: identity)]
    }

    static func spriteRows(for index: Int) -> [String] {
        arts[index].rows
    }

    static func spriteSignature(for index: Int) -> [UInt16] {
        masks[index].flatMap { $0 }
    }

    static func bits(for identity: String) -> [UInt16] {
        let layers = masks[spriteIndex(for: identity)]
        var union = Array(repeating: UInt16.zero, count: 16)
        for layer in layers {
            for row in 0..<16 { union[row] |= layer[row] }
        }
        return union
    }

    static func layers(for identity: String) -> [Layer] {
        layers(forSprite: spriteIndex(for: identity), identity: identity)
    }

    static func layers(forSprite index: Int, identity: String) -> [Layer] {
        let layerBits = masks[index]
        let colors = colors(forSprite: index, identity: identity)
        return layerBits.enumerated().map { index, bits in
            Layer(id: index, bits: bits, color: colors[index])
        }.filter { $0.bits.contains(where: { $0 != 0 }) }
    }

    /// How many distinct steps a run cycle has (one pattern covers all sprites).
    static let animationStepCount = 4

    static func motionPattern(forSprite index: Int) -> MotionPattern {
        arts[index].motion
    }

    /// The geometric frame shown at each step of the character's run cycle.
    static func stepSequence(forSprite index: Int) -> [Int] {
        arts[index].motion.stepSequence
    }

    /// Colored, empty-filtered layers for one step of the running cycle.
    static func animatedLayers(forSprite index: Int, identity: String, step: Int) -> [Layer] {
        let sequence = stepSequence(forSprite: index)
        let frame = sequence[nonNegativeRemainder(step, sequence.count)]
        let layerBits = motionGeometry[index][frame]
        let colors = colors(forSprite: index, identity: identity)
        return layerBits.enumerated().map { layerIndex, bits in
            Layer(id: layerIndex, bits: bits, color: colors[layerIndex])
        }.filter { $0.bits.contains(where: { $0 != 0 }) }
    }

    /// Per-frame cadence, varied per identity so a crowd of workers never bobs
    /// in lockstep. Deterministic: the same agent keeps the same tempo.
    static func frameInterval(for identity: String) -> TimeInterval {
        let base = 0.36 + Double((seed(for: identity) >> 4) % 5) * 0.05
        return base * arts[spriteIndex(for: identity)].motion.tempoScale
    }

    /// Step offset so agents started together still move out of phase.
    static func animationPhase(for identity: String) -> Int {
        Int((seed(for: identity) >> 12) % UInt64(animationStepCount))
    }

    /// Body sinks 1px into the ground; the top row empties so nothing clips.
    private static func crouched(_ rows: [UInt16]) -> [UInt16] {
        var out = Array(repeating: UInt16.zero, count: 16)
        for row in 1..<16 { out[row] = rows[row - 1] }
        return out
    }

    /// Body rises 1px off the ground; the bottom row empties as a hop gap.
    private static func airborne(_ rows: [UInt16]) -> [UInt16] {
        var out = Array(repeating: UInt16.zero, count: 16)
        for row in 0..<15 { out[row] = rows[row + 1] }
        return out
    }

    private static func nonNegativeRemainder(_ value: Int, _ modulus: Int) -> Int {
        ((value % modulus) + modulus) % modulus
    }

    private static func makeMasks(rows: [String]) -> [[UInt16]] {
        var masks = Array(repeating: Array(repeating: UInt16.zero, count: 16), count: 4)
        let markers: [UInt8] = [64, 35, 43, 42]
        for row in 0..<min(rows.count, 16) {
            let bytes = Array(rows[row].utf8)
            for column in 0..<16 {
                let marker = column < bytes.count ? bytes[column] : 46
                guard let slot = markers.firstIndex(of: marker) else { continue }
                masks[slot][row] |= UInt16(1) << UInt16(15 - column)
            }
        }
        return masks
    }

    /// Hue follows the character so names read at a glance; a small
    /// identity-derived drift keeps two agents sharing a sprite apart.
    private static func hueDrift(for identity: String) -> Double {
        Double(Int((seed(for: identity) >> 20) % 61) - 30) / 1000
    }

    private static func colors(forSprite index: Int, identity: String) -> [Color] {
        let palette = arts[index].palette
        let drift = hueDrift(for: identity)
        let hue = wrappedHue(palette.hue + drift)
        return [
            Color(hue: hue, saturation: min(1, palette.saturation + 0.15), brightness: 0.24),
            Color(hue: hue, saturation: palette.saturation, brightness: 0.80),
            Color(hue: wrappedHue(palette.accentHue + drift), saturation: palette.accentSaturation, brightness: 0.88),
            Color(hue: hue, saturation: min(palette.saturation, 0.10), brightness: 0.99)
        ]
    }

    private static func wrappedHue(_ hue: Double) -> Double {
        hue - hue.rounded(.down)
    }

    static func foreground(for identity: String) -> Color {
        colors(forSprite: spriteIndex(for: identity), identity: identity)[1]
    }

    static func background(for identity: String) -> Color {
        let palette = arts[spriteIndex(for: identity)].palette
        let hue = wrappedHue(palette.hue + hueDrift(for: identity))
        return Color(hue: hue, saturation: palette.saturation * 0.30, brightness: 0.96)
    }
}
