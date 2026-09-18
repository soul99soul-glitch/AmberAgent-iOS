import SwiftUI

/// A small, deterministic RPG sprite library for sub-agent avatars.
/// The sprite art is code-native 16×16 data: @ ink, # body, + accent, * highlight.
enum ChatSubAgentPixelSpriteLibrary {
    struct Layer: Identifiable {
        let id: Int
        let bits: [UInt16]
        let color: Color
    }

    private static let arts: [(name: String, rows: [String])] = [
        ("勇者", [
            "......@@......@@", ".....@##@....@#.", "....@####@..@##.", "....@#**#@@@@##.",
            "....@#####++++#", ".....@#######@@.", "......@###@.....", "..++..@###@.....",
            "..+...@###@.....", "..+...@###@.....", "..++++@###@.....", ".....@####@.....",
            "....@######@....", "...@########@...", "..@##########@..", "..@@@@@@@@@@@@.."
        ]),
        ("魔王", [
            "..@..........@.", "..@@........@@.", "..@#@......@#@.", "..@##@@@@@@##@.",
            "...@########@..", "..@###**####@..", ".@@@########@@@", "@##@########@##",
            "@##############", "@@##########@@.", "..@###++++###@.", "..@##########@.",
            "...@##++++##@..", "..@##@@@@@@##@.", ".@##@......@##@", "@@@..........@@"
        ]),
        ("鸟人", [
            "....@....@.....", "...@@....@@....", "...@#....#@....", "..@###..###@...",
            "..@##@@@@##@...", ".@##@#**#@##@..", "@###@####@###@.", "@############@.",
            "..@###++++#@...", "...@########@..", "....@######@...", "....@######@...",
            "...@##@..@##@..", "..@##@....@##@.", ".@##@......@##@", "@@@..........@@"
        ]),
        ("猪头人", [
            "...@@......@@..", "..@##@....@##@.", "..@###@@@@###@.", "..@####**####@.",
            "..@##########@.", "..@##+####+##@.", "..@##########@.", "...@########@..",
            "...@##++++##@..", "...@##++++##@..", "...@########@..", "....@######@...",
            "....@######@...", "....@######@...", "...@########@..", "..@@@@@@@@@@@@.."
        ]),
        ("巫师", [
            "......@.......@", ".....@#@.....@#", "....@###@@@@@##", "...@###########",
            "..@############", "..@####++++####", "...@##########@", ".....@##@##@...",
            ".....@##@##@...", "...@@@####@@@..", "..@##@####@##@.", "..@###****###@.",
            "..@############", "...@##########@", "....@########@.", ".....@@@@@@@@.."
        ]),
        ("骑士", [
            ".....@@@@@@....", "....@######@...", "...@##****##@..", "...@########@..",
            "...@###++++#@..", "....@######@...", "....@######@...", "...@##+##+##@..",
            "...@########@..", "..@###++++###@.", "..@##########@.", "..@##########@.",
            "...@########@..", "...@##@..@##@..", "..@##@....@##@.", "..@@@@@@@@@@@@.."
        ]),
        ("骷髅", [
            "....@@@@@@@@....", "..@@########@@..", ".@##@**##**@##@.", ".@############@.",
            ".@##@++++++@##@.", ".@############@.", "..@@########@@..", "....@######@....",
            "....@##@@##@....", "...@########@...", "..@##@####@##@..", "..@##@####@##@..",
            "..@##########@..", "..@##@....@##@..", "..@##@....@##@..", "..@@@......@@@.."
        ]),
        ("史莱姆", [
            "................", "................", "......@@@@......", "...@@######@@...",
            "..@############@", ".@####**#######@", "@#####++++#####@", "@###############",
            "@###############", "@####@####@####@", "@###############", ".@######@@#####@",
            "..@############@", "...@##########@.", "....@########@..", ".....@@@@@@@@..."
        ]),
        ("蘑菇怪", [
            "....@@....@@....", "..@@##@@@@##@@..", ".@############@.", "@######**######@",
            "@##############@", ".@##++++++##@...", "..@##########@..", "...@########@...",
            "..@##@####@##@..", "..@##@####@##@..", "...@########@...", "...@###++###@...",
            "...@########@...", "..@##########@..", ".@##@......@##@.", "@@@..........@@@"
        ]),
        ("外星人", [
            "..@........@...", "...@......@....", "....@....@.....", ".....@..@......",
            ".....@@@@......", "...@@####@@....", "..@##**####@...", ".@##++++++##@..",
            "@############@.", "@##@######@##@.", "..@########@...", "...@######@....",
            "...@##++##@....", "...@######@....", "...@##@@##@....", "...@@....@@...."
        ]),
        ("龙", [
            "...@.........@.", "..@#@.......@#@", ".@###@.....@###", "@#####@@@@#####",
            "@##**######**##", "@##############", "@##++++++####@.", "@#############@",
            "..@##########@.", "..@###@##@###@.", "..@##@....@##@.", ".@##@......@##@",
            "@##@........@##", "@#@..........@#", "@..............", "@@@@@@@@@@@@@@@@"
        ]),
        ("猫妖", [
            "..@........@...", "..@#@......@#..", "..@##@@@@@@##@.", "..@############",
            "..@##**##**##@.", "...@########@..", "..@#@++++@#@...", "..@############",
            "...@########@..", "....@######@...", "...@##@..@##@..", "..@##@....@##@.",
            "..@##@....@##@.", "..@##########@.", ".@##@......@##@", "@@@........@@@."
        ]),
        ("狐狸", [
            "...@........@..", "..@#@......@#@.", "..@##@@@@@@##@.", ".@############@",
            "@###@**##**@###", "@##############", "..@##++++##@...", "...@########@..",
            "..@##@####@##@.", "..@##@####@##@.", "...@########@..", "...@###++###@..",
            "....@######@...", "....@######@...", "...@########@..", "..@@@@@@@@@@@@.."
        ]),
        ("南瓜怪", [
            "......@@......@@", ".....@##@....@#@", "....@###########", "..@##+##**##+##@",
            ".@##############", "@##@############", "@###############", "@###############",
            "@##+##+##+##+##@", "@###############", ".@##@##########@", "..@############@",
            "...@##########@.", "....@########@..", ".....@######@...", "......@@@@@@...."
        ]),
        ("独眼巨人", [
            ".....@@@@@@.....", "...@@########@@.", "..@############@", ".@#######**#####",
            "@######@**@#####", "@######@**@#####", "@###############", "..@############@",
            "...@##########@.", "...@##++++##@...", "...@##########@.", "...@##########@.",
            "...@##@..@##@...", "..@##@....@##@..", "..@##@....@##@..", "..@@@......@@@.."
        ]),
        ("机器人", [
            "......@..@......", "......@++@......", "...@@@####@@@...", "..@############@",
            "..@##+##+##+##@.", "..@############@", "..@##**####**##@", "..@############@",
            "...@##########@.", "...@##++++##@...", "..@############@", "..@##@####@##@.",
            "..@##@####@##@.", "..@############@", "..@##@....@##@.", "..@@@......@@@.."
        ]),
        ("树精", [
            "..@#@......@#@..", "...@#@....@#@...", "....@######@....", "...@##**##**##@.",
            "..@############@", ".@###++++++###@.", "@##############@", "...@##########@.",
            "...@##@..@##@...", "..@##@....@##@..", "..@##@....@##@..", "..@##@....@##@..",
            "..@##@....@##@..", ".@##@......@##@.", "@##@........@##@", "@@@..........@@@"
        ]),
        ("幽灵", [
            ".....@@@@@@.....", "...@@######@@...", "..@############@", ".@####**#######@",
            "@#####++++#####@", "@###############", "@##@######@####@", "@###############",
            "@##+##+##+##+##@", "@###############", "@##@##@##@##@##@", "@###############",
            ".@###@####@###@.", "..@##@####@##@..", "...@##@..@##@...", "....@@....@@...."
        ]),
        ("石头人", [
            "....@@....@@....", "..@@########@@..", ".@############@.", "@###@**##**@###@",
            "@##############@", "@##++++++#######", "@###############", "@###@######@###@",
            "@###############", "@##@#######@##@.", "@###############", "@####++##++####@",
            ".@############@.", "..@##########@..", "...@########@...", "....@@@@@@@@...."
        ]),
        ("章鱼", [
            ".....@@@@@@.....", "...@@######@@...", "..@############@", ".@####**#######@",
            "@###############", "@##++++++######@", "@###############", ".@#############@",
            "..@###########@.", "..@##@####@##@..", ".@##@######@##@.", "@##@########@##",
            "@##@..@##@..@##", "@#@...@##@...@#", "@....@####@....", ".....@@@@@@....."
        ])
    ]

    private static func seed(for identity: String) -> UInt64 {
        identity.utf8.reduce(UInt64(14695981039346656037)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1099511628211
        }
    }

    static let spriteCount = arts.count
    static let spriteNames = arts.map { $0.name }
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

    /// Motion personality per sprite: heavy creatures breathe, light ones hop,
    /// buoyant ones hover.
    private static let motionPatterns: [MotionPattern] = [
        .hop,      // 勇者
        .breathe,  // 魔王
        .hop,      // 鸟人
        .breathe,  // 猪头人
        .float,    // 巫师
        .breathe,  // 骑士
        .hop,      // 骷髅
        .breathe,  // 史莱姆
        .breathe,  // 蘑菇怪
        .float,    // 外星人
        .breathe,  // 龙
        .hop,      // 猫妖
        .hop,      // 狐狸
        .breathe,  // 南瓜怪
        .breathe,  // 独眼巨人
        .float,    // 机器人
        .breathe,  // 树精
        .float,    // 幽灵
        .breathe,  // 石头人
        .float,    // 章鱼
    ]

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
        let colors = colors(for: identity)
        return layerBits.enumerated().map { index, bits in
            Layer(id: index, bits: bits, color: colors[index])
        }.filter { $0.bits.contains(where: { $0 != 0 }) }
    }

    /// How many distinct steps a run cycle has (one pattern covers all sprites).
    static let animationStepCount = 4

    static func motionPattern(forSprite index: Int) -> MotionPattern {
        motionPatterns[index]
    }

    /// The geometric frame shown at each step of the character's run cycle.
    static func stepSequence(forSprite index: Int) -> [Int] {
        motionPatterns[index].stepSequence
    }

    /// Colored, empty-filtered layers for one step of the running cycle.
    static func animatedLayers(forSprite index: Int, identity: String, step: Int) -> [Layer] {
        let sequence = stepSequence(forSprite: index)
        let frame = sequence[nonNegativeRemainder(step, sequence.count)]
        let layerBits = motionGeometry[index][frame]
        let colors = colors(for: identity)
        return layerBits.enumerated().map { layerIndex, bits in
            Layer(id: layerIndex, bits: bits, color: colors[layerIndex])
        }.filter { $0.bits.contains(where: { $0 != 0 }) }
    }

    /// Per-frame cadence, varied per identity so a crowd of workers never bobs
    /// in lockstep. Deterministic: the same agent keeps the same tempo.
    static func frameInterval(for identity: String) -> TimeInterval {
        let base = 0.36 + Double((seed(for: identity) >> 4) % 5) * 0.05
        return base * motionPatterns[spriteIndex(for: identity)].tempoScale
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

    private static func colors(for identity: String) -> [Color] {
        let hash = seed(for: identity)
        let hue = Double(hash % 360) / 360
        let accentHue = (hue + 0.11).truncatingRemainder(dividingBy: 1)
        return [
            Color(hue: hue, saturation: 0.78, brightness: 0.26),
            Color(hue: hue, saturation: 0.68, brightness: 0.76),
            Color(hue: accentHue, saturation: 0.72, brightness: 0.80),
            Color(hue: hue, saturation: 0.22, brightness: 0.98)
        ]
    }

    static func foreground(for identity: String) -> Color {
        colors(for: identity)[1]
    }

    static func background(for identity: String) -> Color {
        let hash = seed(for: identity)
        let hue = Double(hash % 360) / 360
        return Color(hue: hue, saturation: 0.26, brightness: 0.96)
    }
}
