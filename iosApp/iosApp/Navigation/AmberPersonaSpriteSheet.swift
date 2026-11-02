import SwiftUI
import UIKit

// MARK: - Four-state persona mood

/// Four core states of the agent persona, mirroring Codex Pets' row-per-state sprite sheet.
/// `working` / `alert` remain available as aliases so existing call sites and tests keep compiling.
enum AmberAgentPersonaMood: String, CaseIterable, Equatable, Sendable, Identifiable {
    case idle
    case running
    case needsInput
    case blocked

    var id: String { clipKey }

    /// Stable persisted key inside `animation_manifest.json` — never rename.
    var clipKey: String {
        switch self {
        case .idle: "idle"
        case .running: "running"
        case .needsInput: "needsInput"
        case .blocked: "blocked"
        }
    }

    var displayTitle: String {
        switch self {
        case .idle: "待机"
        case .running: "忙碌"
        case .needsInput: "等待"
        case .blocked: "异常"
        }
    }

    /// Row index inside a single-request 4×4 sprite sheet produced by `AmberPersonaSpriteSheetPrompt`.
    var spriteSheetRow: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    static var working: Self { .running }
    static var alert: Self { .blocked }

    init?(clipKey: String) {
        guard let match = Self.allCases.first(where: { $0.clipKey == clipKey }) else { return nil }
        self = match
    }
}

// MARK: - Animation manifest (per-state clips, backward compatible with the single sequence)

struct AmberPersonaAnimationManifest: Codable, Equatable, Sendable {
    /// Per-state frame file names keyed by `AmberAgentPersonaMood.clipKey`.
    var clips: [String: [String]]
    var frameIntervalMs: Int
    var updatedAtMs: Int64

    init(clips: [String: [String]], frameIntervalMs: Int, updatedAtMs: Int64) {
        self.clips = clips
        self.frameIntervalMs = frameIntervalMs
        self.updatedAtMs = updatedAtMs
    }

    /// Legacy single-sequence initialiser: the same frames serve every state.
    init(frameFileNames: [String], frameIntervalMs: Int, updatedAtMs: Int64) {
        self.init(
            clips: Self.uniformClips(frameFileNames),
            frameIntervalMs: frameIntervalMs,
            updatedAtMs: updatedAtMs
        )
    }

    /// Frames for one state, falling back to the idle clip (old manifests have no per-state split).
    func clip(for mood: AmberAgentPersonaMood) -> [String] {
        let direct = clips[mood.clipKey] ?? []
        if !direct.isEmpty { return direct }
        return clips[AmberAgentPersonaMood.idle.clipKey] ?? []
    }

    var hasDistinctClips: Bool {
        Set(AmberAgentPersonaMood.allCases.map { clip(for: $0) }).count > 1
    }

    var frameCount: Int {
        AmberAgentPersonaMood.allCases.reduce(0) { $0 + clip(for: $1).count }
    }

    var allFrameFileNames: [String] {
        var seen = Set<String>()
        return AmberAgentPersonaMood.allCases.flatMap { clip(for: $0) }.filter { seen.insert($0).inserted }
    }

    static func uniformClips(_ fileNames: [String]) -> [String: [String]] {
        guard !fileNames.isEmpty else { return [:] }
        return AmberAgentPersonaMood.allCases.reduce(into: [String: [String]]()) { result, mood in
            result[mood.clipKey] = fileNames
        }
    }

    private enum CodingKeys: String, CodingKey {
        case clips
        case frameFileNames
        case frameIntervalMs
        case updatedAtMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frameIntervalMs = try container.decodeIfPresent(Int.self, forKey: .frameIntervalMs) ?? 550
        updatedAtMs = try container.decodeIfPresent(Int64.self, forKey: .updatedAtMs) ?? 0
        if let decodedClips = try container.decodeIfPresent([String: [String]].self, forKey: .clips),
           !decodedClips.isEmpty {
            clips = decodedClips
        } else {
            let legacy = try container.decodeIfPresent([String].self, forKey: .frameFileNames) ?? []
            clips = Self.uniformClips(legacy)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clips, forKey: .clips)
        // Downgrade safety: older builds only understand the single sequence.
        try container.encode(clip(for: .idle), forKey: .frameFileNames)
        try container.encode(frameIntervalMs, forKey: .frameIntervalMs)
        try container.encode(updatedAtMs, forKey: .updatedAtMs)
    }
}

// MARK: - Sprite sheet geometry

enum AmberPersonaSpriteSheetLayout: String, Equatable, Sendable {
    /// Single-request grid: 4 rows (one per state) × 4 frame columns.
    case quad4x4
    /// Codex Pets standard: 8 columns × 9 rows (e.g. 1536×1872); the first 4 rows carry our 4 states.
    case codexPets8x9

    var columns: Int {
        switch self {
        case .quad4x4: 4
        case .codexPets8x9: 8
        }
    }

    var rows: Int {
        switch self {
        case .quad4x4: 4
        case .codexPets8x9: 9
        }
    }

    /// Rows 0..<4 map to idle / running / needsInput / blocked; extra rows are ignored.
    var stateRowCount: Int { AmberAgentPersonaMood.allCases.count }
}

// MARK: - Slicer / detector

enum AmberPersonaSpriteSheetSlicer {
    static let minimumCellSide: CGFloat = 32

    struct Probe: Equatable, Sendable {
        /// Transparent gutters, as shipped by Codex Pets PNGs.
        var transparentFraction: Double
        /// Fraction of cells whose own outer border is near-uniform: a subject padded on a plain background.
        var framedCellFraction: Double
        /// Fraction of cells whose content differs from the dominant cell. A real sheet shows 16 different
        /// poses; a plain portrait or photo repeats the same content in most cells.
        var cellDiversity: Double

        var looksLikeSpriteSheet: Bool {
            guard transparentFraction >= 0.08
                || (framedCellFraction >= 0.70 && cellDiversity >= 0.50) else { return false }
            return true
        }
    }

    /// Geometry-first detection, deliberately scale-invariant: the same sheet rendered at 1x or 3x keeps the
    /// same aspect ratio and grid, so ratios drive the decision and pixel divisibility never does.
    /// - Parameter requireContentEvidence: `true` for user file imports, so an ordinary square portrait is never
    ///   carved into 16 tiles; `false` for our own generation request, whose grid the prompt pins.
    static func detectLayout(for image: UIImage, requireContentEvidence: Bool) -> AmberPersonaSpriteSheetLayout? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width >= 4 * minimumCellSide, height >= 4 * minimumCellSide else { return nil }
        let ratio = width / height

        // Codex Pets ships 8 columns × 9 rows; cells may be square (8:9) or slightly taller (1536×1872).
        let layout: AmberPersonaSpriteSheetLayout
        let squareCellRatio = 8.0 / 9.0
        let tallCellRatio = 1536.0 / 1872.0
        if abs(ratio - squareCellRatio) <= 0.03 || abs(ratio - tallCellRatio) <= 0.03 {
            layout = .codexPets8x9
        } else if abs(ratio - 1) <= 0.06 {
            layout = .quad4x4
        } else {
            return nil
        }
        guard requireContentEvidence else { return layout }
        return probe(image, layout: layout).looksLikeSpriteSheet ? layout : nil
    }

    /// Splits a detected sheet into 4 clips × frame columns, dropping blank trailing cells.
    static func slices(
        from image: UIImage,
        layout: AmberPersonaSpriteSheetLayout
    ) -> [AmberAgentPersonaMood: [UIImage]] {
        guard let cgImage = image.cgImage else { return [:] }
        let cellWidth = cgImage.width / layout.columns
        let cellHeight = cgImage.height / layout.rows
        guard CGFloat(cellWidth) >= minimumCellSide, CGFloat(cellHeight) >= minimumCellSide else { return [:] }

        var result: [AmberAgentPersonaMood: [UIImage]] = [:]
        for mood in AmberAgentPersonaMood.allCases {
            let row = mood.spriteSheetRow
            guard row < layout.stateRowCount else { continue }
            var frames: [UIImage] = []
            for column in 0..<layout.columns {
                let rect = CGRect(
                    x: column * cellWidth,
                    y: row * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                )
                guard let cropped = cgImage.cropping(to: rect.integral) else { continue }
                let frame = UIImage(cgImage: cropped, scale: 1, orientation: image.imageOrientation)
                guard !isBlank(frame) else { continue }
                frames.append(frame)
            }
            if !frames.isEmpty { result[mood] = frames }
        }
        return result
    }

    /// A usable sheet needs at least two frames in at least one state, and every state present.
    static func isUsable(_ clips: [AmberAgentPersonaMood: [UIImage]]) -> Bool {
        guard AmberAgentPersonaMood.allCases.contains(where: { (clips[$0]?.count ?? 0) >= 2 }) else { return false }
        return AmberAgentPersonaMood.allCases.allSatisfy { !(clips[$0] ?? []).isEmpty }
    }

    static func probe(_ image: UIImage, layout: AmberPersonaSpriteSheetLayout) -> Probe {
        let samplesPerCell = 8
        let gridWidth = layout.columns * samplesPerCell
        let gridHeight = layout.rows * samplesPerCell
        guard let pixels = rasterPixels(image.cgImage, width: gridWidth, height: gridHeight) else {
            return Probe(transparentFraction: 0, framedCellFraction: 0, cellDiversity: 0)
        }

        /// Summed RGB at one grid sample.
        func color(_ x: Int, _ y: Int) -> Int {
            let base = (y * gridWidth + x) * 4
            return Int(pixels[base]) + Int(pixels[base + 1]) + Int(pixels[base + 2])
        }

        var transparent = 0
        for index in stride(from: 3, to: pixels.count, by: 4) where pixels[index] < 8 {
            transparent += 1
        }
        let totalPixels = gridWidth * gridHeight
        let transparentFraction = totalPixels > 0 ? Double(transparent) / Double(totalPixels) : 0

        func isFlatBorder(originX: Int, originY: Int) -> Bool {
            var borders: [Int] = []
            borders.reserveCapacity(samplesPerCell * 4)
            for offset in 0..<samplesPerCell {
                borders.append(color(originX + offset, originY))
                borders.append(color(originX + offset, originY + samplesPerCell - 1))
                borders.append(color(originX, originY + offset))
                borders.append(color(originX + samplesPerCell - 1, originY + offset))
            }
            guard let lowest = borders.min(), let highest = borders.max() else { return false }
            return highest - lowest <= 54
        }

        /// Average colour at the centre of a cell, used as that cell's signature.
        func cellSignature(originX: Int, originY: Int) -> [Int] {
            let inset = samplesPerCell / 4
            var sums = [0, 0, 0]
            var count = 0
            for y in (originY + inset)..<(originY + samplesPerCell - inset) {
                for x in (originX + inset)..<(originX + samplesPerCell - inset) {
                    let base = (y * gridWidth + x) * 4
                    sums[0] += Int(pixels[base])
                    sums[1] += Int(pixels[base + 1])
                    sums[2] += Int(pixels[base + 2])
                    count += 1
                }
            }
            guard count > 0 else { return [0, 0, 0] }
            return sums.map { $0 / count }
        }

        var framedCells = 0
        var examinedCells = 0
        var signatures: [[Int]] = []
        for row in 0..<layout.stateRowCount {
            for column in 0..<layout.columns {
                examinedCells += 1
                let originX = column * samplesPerCell
                let originY = row * samplesPerCell
                if isFlatBorder(originX: originX, originY: originY) { framedCells += 1 }
                signatures.append(cellSignature(originX: originX, originY: originY))
            }
        }
        let framedCellFraction = examinedCells > 0 ? Double(framedCells) / Double(examinedCells) : 0

        // Diversity: how many cells differ from the most common cell content.
        var dominantCount = 0
        for signature in signatures {
            let sameFamily = signatures.filter { other in
                zip(signature, other).allSatisfy { abs($0 - $1) <= 12 }
            }.count
            dominantCount = max(dominantCount, sameFamily)
        }
        let cellDiversity = examinedCells > 0
            ? Double(examinedCells - dominantCount) / Double(examinedCells)
            : 0

        return Probe(
            transparentFraction: transparentFraction,
            framedCellFraction: framedCellFraction,
            cellDiversity: cellDiversity
        )
    }

    private static func isBlank(_ image: UIImage) -> Bool {
        guard let pixels = rasterPixels(image.cgImage, side: 12) else { return false }
        for index in stride(from: 3, to: pixels.count, by: 4) where pixels[index] >= 8 {
            return false
        }
        return true
    }

    private static func rasterPixels(_ cgImage: CGImage?, width: Int, height: Int) -> [UInt8]? {
        guard let cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = bytes.withUnsafeMutableBytes({ buffer -> CGContext? in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            )
        }) else { return nil }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    private static func rasterPixels(_ cgImage: CGImage?, side: Int) -> [UInt8]? {
        rasterPixels(cgImage, width: side, height: side)
    }
}

// MARK: - Single-request generation prompt

enum AmberPersonaSpriteSheetPrompt {
    /// Builds the one-shot 4×4 prompt: row = state, column = keyframe, art style locked inside one image.
    static func make(stylePrompt: String) -> String {
        """
        Character sprite sheet for the personal AI companion Amber: \(stylePrompt).
        One single image containing a strict 4x4 grid: 4 equal columns and 4 equal rows, 16 equally sized cells,
        generous even padding inside every cell, plain flat background, no text, no labels, no grid lines, no borders.
        The same character appears in all 16 cells with identical face, hairstyle, outfit, palette, head-to-body ratio,
        lighting, camera distance and framing; each cell is a front-facing centered bust that stays circular-crop friendly.
        Row order top to bottom, each row is one 4-frame loop:
        Row 1 idle: calm looking ahead, half blink, eyes closed breathing, eyes open with a small gaze drift.
        Row 2 running: focused leaning forward, glancing left while reviewing, glancing right while reviewing, a small determined nod.
        Row 3 needs input: head raised looking at the viewer, slight head tilt, a light wave, expectant attentive gaze.
        Row 4 blocked: a brief startled freeze, ears drooping with a sigh, head in hands while thinking, cheering up with the head lifted.
        """
    }
}
