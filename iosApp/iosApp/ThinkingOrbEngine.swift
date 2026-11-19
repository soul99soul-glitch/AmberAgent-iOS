// Thinking-orb dot engine, ported from Jakub Antalik's `thinking-orbs`
// (MIT, https://github.com/Jakubantalik/thinking-orbs). The math is a
// faithful 1:1 translation of the TypeScript engine so the six states look
// identical to the reference. This file is UI-free: pure functions mapping a
// time `t` to a z-sorted list of grayscale dots. The UIKit renderer lives in
// ThinkingOrbView.swift and draws these dots with CGContext.
//
// Honestly 3D — rotated, depth-shaded, z-sorted. Depth is carried by dot size
// and ink weight alone; no blur or gradient filters, so it renders the same on
// every substrate.

import CoreGraphics
import Foundation

// MARK: - Core primitives

struct OrbDot {
    var x: Double
    var y: Double
    var z: Double
    var r: Double
    /// Ink value: 0 = darkest ink on paper. Mirrored on dark themes.
    var white: Double
    var a: Double
}

typealias OrbOpts = [String: Double]
typealias OrbProjector = @Sendable (Double, Double, Double) -> (Double, Double, Double)

private func ov(_ o: OrbOpts, _ k: String, _ d: Double) -> Double {
    o[k] ?? d
}

/// Deterministic hash in [0, 1).
func orbHash(_ a: Double, _ b: Double) -> Double {
    let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
    return h - floor(h)
}

/// Stable directions on a unit sphere (Fibonacci lattice).
func orbFibDir(_ i: Int, _ n: Int) -> (Double, Double, Double) {
    let golden = Double.pi * (3 - sqrt(5))
    let y = 1 - (2 * (Double(i) + 0.5)) / Double(n)
    let rad = sqrt(1 - y * y)
    let a = Double(i) * golden
    return (rad * cos(a), y, rad * sin(a))
}

/// Shortest signed angular distance, wrapped to (-π, π].
private func orbAngleDelta(_ a: Double, _ b: Double) -> Double {
    atan2(sin(a - b), cos(a - b))
}

/// Shared spin + tilt + orthographic projection. Note `z` is returned
/// un-scaled (normalised ±1 for unit-sphere inputs) so depth reads stay
/// consistent regardless of the pixel `scale` applied to x/y.
func orbMakeProj(
    yaw: Double, tilt: Double, cx: Double, cy: Double, scale: Double
) -> OrbProjector {
    let st = sin(tilt)
    let ct = cos(tilt)
    let sy = sin(yaw)
    let cyw = cos(yaw)
    return { x, y, z in
        let x1 = x * cyw + z * sy
        let z1 = -x * sy + z * cyw
        let y1 = y * ct - z1 * st
        let z2 = y * st + z1 * ct
        return (cx + x1 * scale, cy - y1 * scale, z2)
    }
}

/// Dot radii were tuned for a 300pt frame; sub-linear scaling keeps small
/// spinners legible. Lower pow = radii shrink less with size.
func orbRadiusScale(_ size: Double, _ pow: Double) -> Double {
    Foundation.pow(size / 300, pow)
}

/// 可跨帧复用的草稿缓冲，消除 30fps 重绘时的数组与几何表堆分配。
struct OrbScratch {
    var dots: [OrbDot] = []
    var moveAmounts: [Double] = []
    var morphPoints: [(Double, Double)] = []
    var morphSegmentLengths: [Double] = []
}

/// z-sort far→near, matte grayscale dots. On dark substrates the ink value is
/// mirrored (1 - white) so near dots read bright — the same depth language on
/// an inverted substrate.
func orbPaint(_ ctx: CGContext, _ dots: inout [OrbDot], dark: Bool, rMin: Double = 0.3) {
    dots.sort { $0.z < $1.z }
    var lastGray: Double = -1
    var lastAlpha: Double = -1
    for d in dots {
        if d.a < 0.02 { continue }
        let w = min(1, max(0, d.white))
        let g = (dark ? 1 - w : w)
        if g != lastGray || d.a != lastAlpha {
            // Zero-allocation path: single C call, no CGColor/CGColorSpace/Array.
            ctx.setFillColor(red: CGFloat(g), green: CGFloat(g), blue: CGFloat(g), alpha: CGFloat(d.a))
            lastGray = g
            lastAlpha = d.a
        }
        let rr = max(rMin, d.r)
        ctx.fillEllipse(in: CGRect(x: d.x - rr, y: d.y - rr, width: rr * 2, height: rr * 2))
    }
}

// MARK: - Orbits (working)

private struct OrbOrbitSpec {
    let radiusFraction: Double
    let h2: Double
    let ux, uy, uz: Double
    let vx, vy, vz: Double
    let speed: Double
}

struct OrbOrbitsPlan {
    fileprivate let orbits: [OrbOrbitSpec]
    fileprivate let ghostTrig: [(ca: Double, sa: Double)]
    fileprivate let particleOffsets: [Double]
    let rsPow, ghostR, ghostA, partR, partRDepth, rMin: Double
    let expectedDotCount: Int

    fileprivate init(opts o: OrbOpts) {
        let orbitN = Int(ov(o, "orbitN", 12))
        let ghostN = Int(ov(o, "ghostN", 40))
        let particles = Int(ov(o, "particles", 3))
        rsPow = ov(o, "rsPow", 0.6)
        ghostR = ov(o, "ghostR", 0.9)
        ghostA = ov(o, "ghostA", 0.5)
        partR = ov(o, "partR", 1.2)
        partRDepth = ov(o, "partRDepth", 1.6)
        rMin = ov(o, "rMin", 0.3)
        expectedDotCount = max(0, orbitN * (ghostN + particles))

        var builtOrbits: [OrbOrbitSpec] = []
        builtOrbits.reserveCapacity(max(0, orbitN))
        for orb in 0..<orbitN {
            let h1 = orbHash(Double(orb), 1.7)
            let h2 = orbHash(Double(orb), 5.2)
            let h3 = orbHash(Double(orb), 8.9)
            let th = h1 * 2 * .pi
            let phi = acos(2 * h2 - 1)
            let nx = sin(phi) * cos(th)
            let ny = cos(phi)
            let nz = sin(phi) * sin(th)
            var ux = -ny
            var uy = nx
            let uz = 0.0
            let ul = max(1e-6, sqrt(ux * ux + uy * uy))
            ux /= ul
            uy /= ul
            let vx = ny * uz - nz * uy
            let vy = nz * ux - nx * uz
            let vz = nx * uy - ny * ux
            let speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1)
            builtOrbits.append(OrbOrbitSpec(
                radiusFraction: 0.45 + 0.52 * h1,
                h2: h2, ux: ux, uy: uy, uz: uz, vx: vx, vy: vy, vz: vz, speed: speed
            ))
        }
        orbits = builtOrbits
        ghostTrig = (0..<ghostN).map { k in
            let a = (Double(k) / Double(ghostN)) * 2 * .pi
            return (cos(a), sin(a))
        }
        particleOffsets = (0..<particles).map { m in
            (Double(m) / Double(particles)) * 2 * .pi
        }
    }
}

func orbDrawOrbits(
    _ ctx: CGContext, size: Double, t: Double, dark: Bool, o: OrbOpts
) {
    var scratch = OrbScratch()
    orbDrawOrbits(ctx, size: size, t: t, dark: dark, plan: OrbOrbitsPlan(opts: o), scratch: &scratch)
}

private func orbDrawOrbits(
    _ ctx: CGContext, size: Double, t: Double, dark: Bool, plan: OrbOrbitsPlan, scratch: inout OrbScratch
) {
    let cx = size / 2
    let cy = size / 2
    let R = (size / 2) * 0.82
    let pt = orbMakeProj(yaw: t * 0.12, tilt: 0.3, cx: cx, cy: cy, scale: 1)
    let rs = orbRadiusScale(size, plan.rsPow)
    let ghostRadius = plan.ghostR * rs
    let ghostAlpha = plan.ghostA
    let particleRadius = plan.partR
    let particleDepthRadius = plan.partRDepth

    scratch.dots.removeAll(keepingCapacity: true)
    if scratch.dots.capacity < plan.expectedDotCount {
        scratch.dots.reserveCapacity(plan.expectedDotCount)
    }

    for orbit in plan.orbits {
        let ro = R * orbit.radiusFraction
        for trig in plan.ghostTrig {
            let (px, py, z) = pt(
                (orbit.ux * trig.ca + orbit.vx * trig.sa) * ro,
                (orbit.uy * trig.ca + orbit.vy * trig.sa) * ro,
                (orbit.uz * trig.ca + orbit.vz * trig.sa) * ro
            )
            let depth = (z / ro + 1) / 2
            scratch.dots.append(OrbDot(
                x: px, y: py, z: z,
                r: ghostRadius,
                white: 0.72,
                a: ghostAlpha * (0.4 + 0.6 * depth)
            ))
        }
        for offset in plan.particleOffsets {
            let a = t * orbit.speed + offset + orbit.h2 * 6
            let ca = cos(a)
            let sa = sin(a)
            let (px, py, z) = pt(
                (orbit.ux * ca + orbit.vx * sa) * ro,
                (orbit.uy * ca + orbit.vy * sa) * ro,
                (orbit.uz * ca + orbit.vz * sa) * ro
            )
            let depth = (z / ro + 1) / 2
            scratch.dots.append(OrbDot(
                x: px, y: py, z: z,
                r: (particleRadius + particleDepthRadius * depth) * rs,
                white: 0.3 - 0.22 * depth,
                a: 1
            ))
        }
    }
    orbPaint(ctx, &scratch.dots, dark: dark, rMin: plan.rMin)
}

// MARK: - Lattice modes (globe / rubik / wave)

private struct OrbMove {
    let axis: Int
    let lo: Double
    let hi: Double
    let ang: Double
}

private func orbMakeMoves(_ count: Int) -> [OrbMove] {
    var moves: [OrbMove] = []
    for i in 0..<count {
        let axis = min(2, Int(floor(orbHash(Double(i), 2.3) * 3)))
        let lo = -1.0 + 0.5 * Double(min(3, Int(floor(orbHash(Double(i), 5.9) * 4))))
        let dir: Double = orbHash(Double(i), 7.7) < 0.5 ? 1 : -1
        moves.append(OrbMove(axis: axis, lo: lo, hi: lo + 0.5, ang: dir * .pi / 2))
    }
    return moves
}

private func orbSolveCycleInto(
    _ time: Double, count: Int, slotDur: Double, rest: Double, amount: inout [Double]
) -> Int {
    if amount.count != count {
        amount = [Double](repeating: 0, count: count)
    } else {
        for i in 0..<count { amount[i] = 0 }
    }
    let cyc = 2 * Double(count) * slotDur + rest
    let tc = time.truncatingRemainder(dividingBy: cyc)
    var active = -1
    if tc < 2 * Double(count) * slotDur {
        let slot = Int(floor(tc / slotDur))
        let p = (tc - Double(slot) * slotDur) / slotDur
        let cl = min(1, p / 0.7)
        let ep = 1 - pow(1 - cl, 3)
        if slot < count {
            for i in 0..<slot { amount[i] = 1 }
            amount[slot] = ep
            active = slot
        } else {
            let u = 2 * count - 1 - slot
            for i in 0..<u { amount[i] = 1 }
            amount[u] = 1 - ep
            active = u
        }
    }
    return active
}

private func orbApplyMoves(
    _ p: (Double, Double, Double), moves: [OrbMove],
    amounts: [Double], active: Int
) -> (Double, Double, Double, Bool) {
    var (x, y, z) = p
    var inActive = false
    for i in 0..<moves.count {
        if amounts[i] <= 0 { continue }
        let mv = moves[i]
        let coord = mv.axis == 0 ? x : mv.axis == 1 ? y : z
        if coord < mv.lo || coord >= mv.hi { continue }
        if i == active { inActive = true }
        let a = mv.ang * amounts[i]
        let ca = cos(a)
        let sa = sin(a)
        if mv.axis == 0 {
            let y2 = y * ca - z * sa
            z = y * sa + z * ca
            y = y2
        } else if mv.axis == 1 {
            let x2 = x * ca + z * sa
            z = -x * sa + z * ca
            x = x2
        } else {
            let x2 = x * ca - y * sa
            y = x * sa + y * ca
            x = x2
        }
    }
    return (x, y, z, inActive)
}

struct OrbGlobePlan {
    fileprivate let points: [(x: Double, y: Double, z: Double, lon: Double)]
    let scanMul, rsPow, dimBase, rBase, rDepth, rBoost, inkFar, inkSpan, rMin: Double

    fileprivate init(opts o: OrbOpts) {
        scanMul = ov(o, "scanMul", 1)
        rsPow = ov(o, "rsPow", 0.6)
        dimBase = ov(o, "dimBase", 1)
        rBase = ov(o, "rBase", 0.6)
        rDepth = ov(o, "rDepth", 1.7)
        rBoost = ov(o, "rBoost", 1)
        inkFar = ov(o, "inkFar", 0.62)
        inkSpan = ov(o, "inkSpan", 0.54)
        rMin = ov(o, "rMin", 0.3)
        let latRings = Int(ov(o, "latRings", 17))
        let lonDensity = Int(ov(o, "lonDensity", 44))
        var pts: [(Double, Double, Double, Double)] = []
        pts.reserveCapacity(max(0, (latRings + 1) * lonDensity))
        for li in 0...latRings {
            let lat = -.pi / 2 + (Double(li) / Double(latRings)) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int((abs(cosLat) * Double(lonDensity)).rounded()))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                pts.append((cosLat * cos(lon), sinLat, cosLat * sin(lon), lon))
            }
        }
        points = pts
    }
}

func orbDrawGlobe(
    _ ctx: CGContext, size: Double, t: Double, dark: Bool, o: OrbOpts
) {
    var scratch = OrbScratch()
    orbDrawGlobe(ctx, size: size, t: t, dark: dark, plan: OrbGlobePlan(opts: o), scratch: &scratch)
}

private func orbDrawGlobe(
    _ ctx: CGContext, size: Double, t: Double, dark: Bool, plan: OrbGlobePlan, scratch: inout OrbScratch
) {
    let spin = 0.5
    let cx = size / 2
    let cy = size / 2
    let radius = (size / 2) * 0.82
    let tilt = 0.4 + 0.06 * sin(t * 0.35)
    let pt = orbMakeProj(yaw: t * spin, tilt: tilt, cx: cx, cy: cy, scale: radius)
    let scan = t * (spin + (1.7 - spin) * plan.scanMul)
    let rs = orbRadiusScale(size, plan.rsPow)

    scratch.dots.removeAll(keepingCapacity: true)
    if scratch.dots.capacity < plan.points.count {
        scratch.dots.reserveCapacity(plan.points.count)
    }
    for p in plan.points {
        let (px, py, z) = pt(p.x, p.y, p.z)
        let depth = (z + 1) / 2
        let d = orbAngleDelta(p.lon + t * spin, scan)
        let boost = exp(-(d * d) / 0.18) * max(0, z)
        scratch.dots.append(OrbDot(
            x: px, y: py, z: z,
            r: (plan.rBase + plan.rDepth * depth + plan.rBoost * boost) * rs,
            white: plan.inkFar - plan.inkSpan * depth,
            a: plan.dimBase + (1 - plan.dimBase) * min(1, boost)
        ))
    }
    orbPaint(ctx, &scratch.dots, dark: dark, rMin: plan.rMin)
}

struct OrbRubikPlan {
    fileprivate let moves: [OrbMove]
    fileprivate let points: [(Double, Double, Double)]
    let moveCount: Int
    let rsPow, rBase, rDepth, rActive, inkFar, inkSpan, rMin: Double

    fileprivate init(opts o: OrbOpts) {
        moveCount = Int(ov(o, "moveCount", 14))
        moves = orbMakeMoves(moveCount)
        rsPow = ov(o, "rsPow", 0.6)
        rBase = ov(o, "rBase", 0.6)
        rDepth = ov(o, "rDepth", 1.7)
        rActive = ov(o, "rActive", 0.3)
        inkFar = ov(o, "inkFar", 0.62)
        inkSpan = ov(o, "inkSpan", 0.54)
        rMin = ov(o, "rMin", 0.3)
        let latRings = Int(ov(o, "latRings", 15))
        let lonDensity = Int(ov(o, "lonDensity", 40))
        var pts: [(Double, Double, Double)] = []
        pts.reserveCapacity(max(0, (latRings + 1) * lonDensity))
        for li in 0...latRings {
            let lat = -.pi / 2 + (Double(li) / Double(latRings)) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int((abs(cosLat) * Double(lonDensity)).rounded()))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                pts.append((cosLat * cos(lon), sinLat, cosLat * sin(lon)))
            }
        }
        points = pts
    }
}

func orbDrawRubik(
    _ ctx: CGContext, size: Double, t: Double, dark: Bool, o: OrbOpts
) {
    var scratch = OrbScratch()
    orbDrawRubik(ctx, size: size, t: t, dark: dark, plan: OrbRubikPlan(opts: o), scratch: &scratch)
}

private func orbDrawRubik(
    _ ctx: CGContext, size: Double, t: Double, dark: Bool, plan: OrbRubikPlan, scratch: inout OrbScratch
) {
    let cx = size / 2
    let cy = size / 2
    let R = (size / 2) * 0.82
    let pt = orbMakeProj(
        yaw: t * 0.55, tilt: 0.35 + 0.1 * sin(t * 0.9), cx: cx, cy: cy, scale: R
    )
    let rs = orbRadiusScale(size, plan.rsPow)
    let active = orbSolveCycleInto(t, count: plan.moveCount, slotDur: 0.42, rest: 1.2, amount: &scratch.moveAmounts)

    scratch.dots.removeAll(keepingCapacity: true)
    if scratch.dots.capacity < plan.points.count {
        scratch.dots.reserveCapacity(plan.points.count)
    }
    for p in plan.points {
        let (x, y, z, inActive) = orbApplyMoves(p, moves: plan.moves, amounts: scratch.moveAmounts, active: active)
        let (px, py, zr) = pt(x, y, z)
        let depth = (zr + 1) / 2
        scratch.dots.append(OrbDot(
            x: px, y: py, z: zr,
            r: (plan.rBase + plan.rDepth * depth + (inActive ? plan.rActive : 0)) * rs,
            white: plan.inkFar - plan.inkSpan * depth - (inActive ? 0.14 : 0),
            a: 1
        ))
    }
    orbPaint(ctx, &scratch.dots, dark: dark, rMin: plan.rMin)
}

struct OrbWavePlan {
    fileprivate struct Ring {
        let ri: Double
        let sinLat: Double
        let lonPoints: [(cx: Double, sz: Double)]
    }

    fileprivate let rings: [Ring]
    let rsPow, rBase, rDepth, rMin: Double
    let expectedDotCount: Int

    fileprivate init(opts o: OrbOpts) {
        rsPow = ov(o, "rsPow", 0.6)
        rBase = ov(o, "rBase", 0.6)
        rDepth = ov(o, "rDepth", 1.7)
        rMin = ov(o, "rMin", 0.3)
        let ringCount = Int(ov(o, "rings", 15))
        let lonDensity = Int(ov(o, "lonDensity", 40))
        var built: [Ring] = []
        built.reserveCapacity(max(0, ringCount + 1))
        var total = 0
        for ri in 0...ringCount {
            let lat = -.pi / 2 + (Double(ri) / Double(ringCount)) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int((abs(cosLat) * Double(lonDensity)).rounded()))
            var lonPoints: [(Double, Double)] = []
            lonPoints.reserveCapacity(lonCount)
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                lonPoints.append((cosLat * cos(lon), cosLat * sin(lon)))
            }
            total += lonCount
            built.append(Ring(ri: Double(ri), sinLat: sinLat, lonPoints: lonPoints))
        }
        rings = built
        expectedDotCount = total
    }
}

func orbDrawWave(
    _ ctx: CGContext, size: Double, t: Double, dark: Bool, o: OrbOpts
) {
    var scratch = OrbScratch()
    orbDrawWave(ctx, size: size, t: t, dark: dark, plan: OrbWavePlan(opts: o), scratch: &scratch)
}

private func orbDrawWave(
    _ ctx: CGContext, size: Double, t: Double, dark: Bool, plan: OrbWavePlan, scratch: inout OrbScratch
) {
    let cx = size / 2
    let cy = size / 2
    let R = (size / 2) * 0.874
    let pt = orbMakeProj(yaw: t * 0.18, tilt: 0.38, cx: cx, cy: cy, scale: 1)
    let rs = orbRadiusScale(size, plan.rsPow)

    scratch.dots.removeAll(keepingCapacity: true)
    if scratch.dots.capacity < plan.expectedDotCount {
        scratch.dots.reserveCapacity(plan.expectedDotCount)
    }
    for ring in plan.rings {
        let w = 0.62 * sin(t * 2.1 - ring.ri * 0.52) + 0.38 * sin(t * 1.27 + ring.ri * 0.83)
        let rr = R * (0.88 + 0.105 * w)
        let crest = max(0, w)
        for lp in ring.lonPoints {
            let (px, py, z) = pt(lp.cx * rr, ring.sinLat * rr, lp.sz * rr)
            let depth = (z / R + 1) / 2
            scratch.dots.append(OrbDot(
                x: px, y: py, z: z,
                r: (plan.rBase + plan.rDepth * depth) * (1 + 0.4 * crest) * rs,
                white: 0.66 - 0.56 * depth - 0.1 * crest,
                a: 1
            ))
        }
    }
    orbPaint(ctx, &scratch.dots, dark: dark, rMin: plan.rMin)
}

// MARK: - Ribbon (composing)

struct OrbRibbonPlan {
    fileprivate let fibDirs: [(Double, Double, Double)]
    fileprivate let laneParams: [(w: Double, laneOff: Double, edge: Double)]
    fileprivate let segTrig: [(a: Double, ca: Double, sa: Double)]
    let spin, rsPow, wobbleMultiplier, rBase, rDepth, rMin: Double
    let expectedDotCount: Int

    fileprivate init(opts o: OrbOpts) {
        spin = ov(o, "spin", 1)
        rsPow = ov(o, "rsPow", 0.6)
        let baseLanes = ov(o, "lanes", 5)
        let segs = Int(ov(o, "segs", 88))
        let lanes = max(1, Int((baseLanes * ov(o, "bandMul", 1)).rounded()))
        wobbleMultiplier = ov(o, "wobMul", 1)
        rBase = ov(o, "rBase", 1.1)
        rDepth = ov(o, "rDepth", 1.7)
        rMin = ov(o, "rMin", 0.3)
        let ghostN = Int(ov(o, "ghostN", 150))
        fibDirs = (0..<ghostN).map { orbFibDir($0, ghostN) }
        laneParams = (0..<lanes).map { w in
            (
                w: Double(w),
                laneOff: (Double(w) - Double(lanes - 1) / 2) * 0.075,
                edge: abs(Double(w) - Double(lanes - 1) / 2) / max(1, Double(lanes - 1) / 2)
            )
        }
        segTrig = (0..<segs).map { k in
            let a = (Double(k) / Double(segs)) * 2 * .pi
            return (a, cos(a), sin(a))
        }
        expectedDotCount = max(0, ghostN + lanes * segs)
    }
}

func orbDrawRibbon(
    _ ctx: CGContext, size: Double, t: Double, dark: Bool, o: OrbOpts
) {
    var scratch = OrbScratch()
    orbDrawRibbon(ctx, size: size, t: t, dark: dark, plan: OrbRibbonPlan(opts: o), scratch: &scratch)
}

private func orbDrawRibbon(
    _ ctx: CGContext, size: Double, t: Double, dark: Bool, plan: OrbRibbonPlan, scratch: inout OrbScratch
) {
    let cx = size / 2
    let cy = size / 2
    let R = (size / 2) * 0.78
    let spin = plan.spin
    let pt = orbMakeProj(yaw: t * 0.1 * spin, tilt: 0.3, cx: cx, cy: cy, scale: 1)
    let rs = orbRadiusScale(size, plan.rsPow)

    scratch.dots.removeAll(keepingCapacity: true)
    if scratch.dots.capacity < plan.expectedDotCount {
        scratch.dots.reserveCapacity(plan.expectedDotCount)
    }
    for d in plan.fibDirs {
        let (px, py, z) = pt(d.0 * R, d.1 * R, d.2 * R)
        let depth = (z / R + 1) / 2
        scratch.dots.append(OrbDot(x: px, y: py, z: z, r: 0.8 * rs, white: 0.78, a: 0.1 + 0.22 * depth))
    }

    let ya = t * 0.24 * spin
    let ta = 0.55 + 0.3 * sin(t * 0.18) * spin
    let ux = cos(ya)
    let uy = 0.0
    let uz = sin(ya)
    let vx = -uz * sin(ta)
    let vy = cos(ta)
    let vz = ux * sin(ta)
    let nx = uy * vz - uz * vy
    let ny = uz * vx - ux * vz
    let nz = ux * vy - uy * vx

    for lane in plan.laneParams {
        for seg in plan.segTrig {
            let wob = (0.16 * sin(seg.a * 3 - t * 1.7 + lane.w * 0.22) + 0.07 * sin(seg.a * 5 + t * 1.1)) * plan.wobbleMultiplier
            let off = lane.laneOff + wob
            let x = ux * seg.ca + vx * seg.sa + nx * off
            let y = uy * seg.ca + vy * seg.sa + ny * off
            let z = uz * seg.ca + vz * seg.sa + nz * off
            let l = sqrt(x * x + y * y + z * z)
            let (px, py, zr) = pt((x / l) * R, (y / l) * R, (z / l) * R)
            let depth = (zr / R + 1) / 2
            scratch.dots.append(OrbDot(
                x: px, y: py, z: zr,
                r: (plan.rBase + plan.rDepth * depth) * (1 - 0.25 * lane.edge) * rs,
                white: 0.52 - 0.44 * depth + 0.18 * lane.edge,
                a: 0.4 + 0.6 * depth
            ))
        }
    }
    orbPaint(ctx, &scratch.dots, dark: dark, rMin: plan.rMin)
}

// MARK: - Morph (shaping)

private typealias OrbPath = @Sendable (Double) -> (Double, Double)

private func orbPolyPath(_ verts: [(Double, Double)]) -> OrbPath {
    let V = verts.count
    var tmpL: [Double] = []
    var tmpTotal = 0.0
    for i in 0..<V {
        let a = verts[i]
        let b = verts[(i + 1) % V]
        let l = hypot(b.0 - a.0, b.1 - a.1)
        tmpL.append(l)
        tmpTotal += l
    }
    let L = tmpL
    let total = tmpTotal
    return { f in
        var target = f * total
        var i = 0
        while target > L[i] && i < V - 1 {
            target -= L[i]
            i += 1
        }
        let a = verts[i]
        let b = verts[(i + 1) % V]
        let ff = L[i] != 0 ? min(1, target / L[i]) : 0
        return (a.0 + (b.0 - a.0) * ff, a.1 + (b.1 - a.1) * ff)
    }
}

private let orbCirclePath: OrbPath = { f in
    let a = -.pi / 2 + f * 2 * .pi
    return (cos(a) * 0.24, sin(a) * 0.24)
}

private let orbCycle: [OrbPath] = [
    orbCirclePath,
    orbPolyPath([(0.0, -0.26), (0.24, 0.16), (-0.24, 0.16)]),
    orbPolyPath([(0, -0.2), (0.2, -0.2), (0.2, 0.2), (-0.2, 0.2), (-0.2, -0.2)])
]

private let orbMorphSampleCount = 160
private let orbCycleSamples: [[(Double, Double)]] = orbCycle.map { path in
    (0..<orbMorphSampleCount).map { path(Double($0) / Double(orbMorphSampleCount)) }
}

private func orbMorphN(_ d: Double) -> Int {
    max(6, Int((34 * d).rounded()))
}

private let orbHold = 1.4
private let orbMorph = 0.9
private let orbSeg = orbHold + orbMorph

private func orbSmoothE(_ x: Double) -> Double {
    x * x * (3 - 2 * x)
}

struct OrbMorphPlan {
    let sprd: Double
    let n: Int
    let dotRadius: Double
    let rMin: Double

    fileprivate init(opts o: OrbOpts) {
        sprd = ov(o, "spread", 1)
        n = orbMorphN(ov(o, "iconD", 1))
        dotRadius = ov(o, "rDot", 0.021) * 1.35 * sprd
        rMin = ov(o, "rMin", 0.25)
    }
}

func orbDrawMorph(
    _ ctx: CGContext, size: Double, t: Double, dark: Bool, o: OrbOpts
) {
    var scratch = OrbScratch()
    orbDrawMorph(ctx, size: size, t: t, dark: dark, plan: OrbMorphPlan(opts: o), scratch: &scratch)
}

private func orbDrawMorph(
    _ ctx: CGContext, size: Double, t: Double, dark: Bool, plan: OrbMorphPlan, scratch: inout OrbScratch
) {
    let K = orbCycleSamples.count
    let tc = t.truncatingRemainder(dividingBy: orbSeg * Double(K))
    let k = Int(floor(tc / orbSeg))
    let local = tc - Double(k) * orbSeg
    let m = local > orbHold ? orbSmoothE((local - orbHold) / orbMorph) : 0

    let pA = orbCycleSamples[k]
    let pB = orbCycleSamples[(k + 1) % K]
    let M = orbMorphSampleCount
    scratch.morphPoints.removeAll(keepingCapacity: true)
    if scratch.morphPoints.capacity < M { scratch.morphPoints.reserveCapacity(M) }
    for i in 0..<M {
        let a = pA[i]
        let b = pB[i]
        scratch.morphPoints.append(((a.0 + (b.0 - a.0) * m) * plan.sprd, (a.1 + (b.1 - a.1) * m) * plan.sprd))
    }
    scratch.morphSegmentLengths.removeAll(keepingCapacity: true)
    if scratch.morphSegmentLengths.capacity < M { scratch.morphSegmentLengths.reserveCapacity(M) }
    var total = 0.0
    for i in 0..<M {
        let a = scratch.morphPoints[i]
        let b = scratch.morphPoints[(i + 1) % M]
        let l = hypot(b.0 - a.0, b.1 - a.1)
        scratch.morphSegmentLengths.append(l)
        total += l
    }

    let n = plan.n
    let pulse = 1 + 0.02 * sin(local * 3.1)

    scratch.dots.removeAll(keepingCapacity: true)
    if scratch.dots.capacity < n { scratch.dots.reserveCapacity(n) }
    let c2 = size / 2
    var seg = 0
    var acc = 0.0
    for k2 in 0..<n {
        let target = (Double(k2) / Double(n)) * total
        while acc + scratch.morphSegmentLengths[seg] < target && seg < M - 1 {
            acc += scratch.morphSegmentLengths[seg]
            seg += 1
        }
        let a = scratch.morphPoints[seg]
        let b = scratch.morphPoints[(seg + 1) % M]
        let segLen = scratch.morphSegmentLengths[seg]
        let f = segLen != 0 ? min(1, (target - acc) / segLen) : 0
        let x = (a.0 + (b.0 - a.0) * f) * pulse
        let y = (a.1 + (b.1 - a.1) * f) * pulse
        scratch.dots.append(OrbDot(
            x: c2 + x * size, y: c2 + y * size, z: 0,
            r: max(0.35, plan.dotRadius * size), white: 0.1, a: 1
        ))
    }
    orbPaint(ctx, &scratch.dots, dark: dark, rMin: plan.rMin)
}

// MARK: - Profiles, presets, resolution

enum OrbState: String, CaseIterable {
    case working, searching, solving, listening, composing, shaping
}

/// Tuned density preset. The reference ships exactly two designs (64 = avatar
/// scale, 20 = inline scale); they are separate tunings, not a scale factor.
enum OrbPreset {
    case large   // 64-pt design
    case small   // 20-pt design (used for the compact activity-island glyph)

    fileprivate var key: String { self == .large ? "64" : "20" }
}

enum OrbMode: String {
    case orbits, globe, rubik, wave, ribbon, morph
}

private let orbStateToMode: [OrbState: OrbMode] = [
    .working: .orbits,
    .searching: .globe,
    .solving: .rubik,
    .listening: .wave,
    .composing: .ribbon,
    .shaping: .morph
]

enum OrbRenderPlan {
    case orbits(OrbOrbitsPlan)
    case globe(OrbGlobePlan)
    case rubik(OrbRubikPlan)
    case wave(OrbWavePlan)
    case ribbon(OrbRibbonPlan)
    case morph(OrbMorphPlan)

    fileprivate static func build(mode: OrbMode, opts: OrbOpts) -> OrbRenderPlan {
        switch mode {
        case .orbits: .orbits(OrbOrbitsPlan(opts: opts))
        case .globe: .globe(OrbGlobePlan(opts: opts))
        case .rubik: .rubik(OrbRubikPlan(opts: opts))
        case .wave: .wave(OrbWavePlan(opts: opts))
        case .ribbon: .ribbon(OrbRibbonPlan(opts: opts))
        case .morph: .morph(OrbMorphPlan(opts: opts))
        }
    }
}

struct OrbResolved {
    let mode: OrbMode
    let speed: Double
    let opts: OrbOpts
    let plan: OrbRenderPlan
}

private let orbBaseProfiles: [OrbMode: OrbOpts] = [
    .globe: [
        "latRings": 17, "lonDensity": 44, "rBase": 0.6, "rDepth": 1.7, "rBoost": 1.0,
        "inkFar": 0.62, "inkSpan": 0.54, "rsPow": 0.6, "rMin": 0.3
    ],
    .orbits: [
        "orbitN": 12, "ghostN": 40, "ghostR": 0.9, "ghostA": 0.5, "particles": 3,
        "partR": 1.2, "partRDepth": 1.6, "rsPow": 0.6, "rMin": 0.3
    ],
    .rubik: [
        "latRings": 15, "lonDensity": 40, "moveCount": 14, "rBase": 0.6, "rDepth": 1.7,
        "rActive": 0.3, "inkFar": 0.62, "inkSpan": 0.54, "rsPow": 0.6, "rMin": 0.3
    ],
    .wave: [
        "rings": 15, "lonDensity": 40, "rBase": 0.6, "rDepth": 1.7, "rsPow": 0.6, "rMin": 0.3
    ],
    .ribbon: [
        "lanes": 5, "segs": 88, "ghostN": 150, "rBase": 1.1, "rDepth": 1.7, "rsPow": 0.6, "rMin": 0.3
    ],
    .morph: [
        "rDot": 0.021, "iconD": 1, "rMin": 0.25
    ]
]

private struct OrbPresetSpec {
    let speed: Double
    let count: Double
    let size: Double
    let extra: OrbOpts
}

private let orbPresets: [OrbMode: [String: OrbPresetSpec]] = [
    .orbits: [
        "64": OrbPresetSpec(speed: 1.885, count: 1, size: 1, extra: [:]),
        "20": OrbPresetSpec(speed: 3.9, count: 0.238, size: 2.4, extra: [:])
    ],
    .globe: [
        "64": OrbPresetSpec(speed: 2.015, count: 0.42, size: 1.15, extra: ["scanMul": 4.08, "dimBase": 0.45]),
        "20": OrbPresetSpec(speed: 2.665, count: 0.105, size: 1.75, extra: ["scanMul": 4.335, "dimBase": 0.45])
    ],
    .rubik: [
        "64": OrbPresetSpec(speed: 1.82, count: 0.35, size: 1.05, extra: [:]),
        "20": OrbPresetSpec(speed: 1.95, count: 0.088, size: 1.9, extra: [:])
    ],
    .wave: [
        "64": OrbPresetSpec(speed: 4.388, count: 0.341, size: 1, extra: [:]),
        "20": OrbPresetSpec(speed: 3.998, count: 0.105, size: 1.6, extra: [:])
    ],
    .ribbon: [
        "64": OrbPresetSpec(speed: 2.34, count: 0.25, size: 0.85, extra: ["spin": 0, "bandMul": 3.9, "wobMul": 1]),
        "20": OrbPresetSpec(speed: 3.12, count: 0.051, size: 1.073, extra: ["spin": 0, "bandMul": 4.94, "wobMul": 1])
    ],
    .morph: [
        "64": OrbPresetSpec(speed: 2.405, count: 0.54, size: 0.395, extra: ["spread": 1.45]),
        "20": OrbPresetSpec(speed: 2.08, count: 0.53, size: 1.011, extra: ["spread": 1.45])
    ]
]

private let orbCountPairs: [(String, String)] = [
    ("latRings", "lonDensity"), ("rings", "lonDensity"), ("lanes", "segs")
]
private let orbCountKeys = ["orbitN", "ghostN"]
private let orbIconDensityKeys = ["iconD"]
private let orbRadiusKeys = ["rBase", "rDepth", "rActive", "rDot", "ghostR", "partR", "partRDepth"]

private func orbScaleCounts(_ opts: OrbOpts, _ scale: Double) -> OrbOpts {
    var out = opts
    var done = Set<String>()
    let rt = sqrt(scale)
    for (a, b) in orbCountPairs {
        if let va = out[a], let vb = out[b], !done.contains(a), !done.contains(b) {
            out[a] = Double(max(2, Int((va * rt).rounded())))
            out[b] = Double(max(2, Int((vb * rt).rounded())))
            done.insert(a)
            done.insert(b)
        }
    }
    for k in orbCountKeys {
        if let v = out[k], !done.contains(k) {
            out[k] = Double(max(1, Int((v * scale).rounded())))
            done.insert(k)
        }
    }
    for k in orbIconDensityKeys {
        if let v = out[k] { out[k] = max(0.02, v * scale) }
    }
    return out
}

private func orbScaleRadii(_ opts: OrbOpts, _ scale: Double) -> OrbOpts {
    var out = opts
    for k in orbRadiusKeys {
        if let v = out[k] { out[k] = v * scale }
    }
    out["rSizeMul"] = (out["rSizeMul"] ?? 1) * scale
    return out
}

/// Resolve a (state, preset) pair to its mode + fully-scaled draw options.
func orbResolvePreset(_ state: OrbState, _ preset: OrbPreset) -> OrbResolved {
    guard let mode = orbStateToMode[state] else {
        fatalError("ThinkingOrb: no mode mapping for state \(state.rawValue)")
    }
    guard let presetMap = orbPresets[mode], let spec = presetMap[preset.key] else {
        fatalError("ThinkingOrb: no preset for mode \(mode.rawValue) size \(preset.key)")
    }
    guard var opts = orbBaseProfiles[mode] else {
        fatalError("ThinkingOrb: no base profile for mode \(mode.rawValue)")
    }
    if spec.count != 1 { opts = orbScaleCounts(opts, spec.count) }
    if spec.size != 1 { opts = orbScaleRadii(opts, spec.size) }
    if !spec.extra.isEmpty { for (k, v) in spec.extra { opts[k] = v } }
    let resolved = OrbResolved(
        mode: mode,
        speed: spec.speed,
        opts: opts,
        plan: OrbRenderPlan.build(mode: mode, opts: opts)
    )
    return resolved
}

/// Dispatch a resolved mode into its frame painter (zero per-frame option lookups or geometry setup).
func orbDraw(
    _ resolved: OrbResolved, _ ctx: CGContext, size: Double, t: Double, dark: Bool, scratch: inout OrbScratch
) {
    orbDraw(resolved.plan, ctx, size: size, t: t, dark: dark, scratch: &scratch)
}

private func orbDraw(
    _ plan: OrbRenderPlan, _ ctx: CGContext, size: Double, t: Double, dark: Bool, scratch: inout OrbScratch
) {
    switch plan {
    case .orbits(let p): orbDrawOrbits(ctx, size: size, t: t, dark: dark, plan: p, scratch: &scratch)
    case .globe(let p): orbDrawGlobe(ctx, size: size, t: t, dark: dark, plan: p, scratch: &scratch)
    case .rubik(let p): orbDrawRubik(ctx, size: size, t: t, dark: dark, plan: p, scratch: &scratch)
    case .wave(let p): orbDrawWave(ctx, size: size, t: t, dark: dark, plan: p, scratch: &scratch)
    case .ribbon(let p): orbDrawRibbon(ctx, size: size, t: t, dark: dark, plan: p, scratch: &scratch)
    case .morph(let p): orbDrawMorph(ctx, size: size, t: t, dark: dark, plan: p, scratch: &scratch)
    }
}

/// Dispatch a resolved mode into its frame painter.
func orbDraw(
    _ mode: OrbMode, _ ctx: CGContext, size: Double, t: Double, dark: Bool, opts: OrbOpts
) {
    var scratch = OrbScratch()
    orbDraw(OrbRenderPlan.build(mode: mode, opts: opts), ctx, size: size, t: t, dark: dark, scratch: &scratch)
}
