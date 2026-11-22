import Foundation

/// Camera roll and converging verticals, from long straight lines (Hough transform).
/// Sign convention: + = the scene is rotated clockwise in the frame (rotate counter-clockwise to fix).
struct TiltResult {
    var tilt: Double?
    var source: String?
    var confidence: Double?
    var keystone: Double?
    var lines: [[Double]] = []     // detected lines, normalized [x0, y0, x1, y1] (for the overlay)
    var debug = ""
}

private struct Line { var angle: Double; var pos: Double; var votes: Int }

/// Hough transform for near-vertical lines: x = x0 - (y - yc) * tan(phi), phi in [-maxDeg, maxDeg].
private func houghVertical(_ edges: [(Int, Int)], w: Int, h: Int, maxDeg: Double, minVotes: Int) -> [Line] {
    let step = 0.1
    let nA = Int(2 * maxDeg / step) + 1
    let pad = w / 3
    let nX = w + 2 * pad
    let tans = (0..<nA).map { tan((Double($0) * step - maxDeg) * .pi / 180) }
    var acc = [Int32](repeating: 0, count: nA * nX)
    let yc = Double(h) / 2
    acc.withUnsafeMutableBufferPointer { a in
        for (x, y) in edges {
            let dy = Double(y) - yc
            for k in 0..<nA {
                let x0 = Int((Double(x) + dy * tans[k]).rounded()) + pad
                if x0 >= 0 && x0 < nX { a[k * nX + x0] += 1 }
            }
        }
    }
    var cands: [(Int, Int, Int32)] = []
    for k in 0..<nA {
        for x in 0..<nX where acc[k * nX + x] >= Int32(minVotes) { cands.append((k, x, acc[k * nX + x])) }
    }
    cands.sort { $0.2 > $1.2 }
    var lines: [Line] = []
    for c in cands {
        let ang = Double(c.0) * step - maxDeg
        let pos = Double(c.1 - pad)
        if lines.contains(where: { abs($0.angle - ang) <= 1.5 && abs($0.pos - pos) <= 12 }) { continue }
        lines.append(Line(angle: ang, pos: pos, votes: Int(c.2)))
        if lines.count >= 40 { break }
    }
    return lines
}

/// Thresholds for tilt verdicts (also used by the edit recipe: it rotates only flagged frames).
enum TiltRules {
    static let flagDegrees = 1.5
    static let flagConfidence = 0.4
    static let minLines = 8                 // vertical lines needed for a roll estimate
    static let minHorizonCoverage = 0.4     // a horizon must be collinear edges over 40% of the width
}

func estimateTilt(_ luma: Plane, visionHorizon: Double?) -> TiltResult {
    let p = Pixels.half(Pixels.half(luma))
    let w = p.width, h = p.height
    var mag = [Float](repeating: 0, count: w * h)
    var vEdges: [(Int, Int)] = [], hEdges: [(Int, Int)] = []
    var isV = [Bool](repeating: false, count: w * h)
    p.data.withUnsafeBufferPointer { a in
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let gx = (a[i - w + 1] + 2 * a[i + 1] + a[i + w + 1]) - (a[i - w - 1] + 2 * a[i - 1] + a[i + w - 1])
                let gy = (a[i + w - 1] + 2 * a[i + w] + a[i + w + 1]) - (a[i - w - 1] + 2 * a[i - w] + a[i - w + 1])
                mag[i] = abs(gx) + abs(gy)
                isV[i] = abs(gx) > 2 * abs(gy)
            }
        }
    }
    // Thin edges with non-maximum suppression across the edge.
    for y in 2..<(h - 2) {
        for x in 2..<(w - 2) {
            let i = y * w + x
            let m = mag[i]
            // Horizontal edges get a lower bar: a hazy sea horizon is faint.
            guard m > (isV[i] ? 60 : 30) else { continue }
            if isV[i] {
                if m >= mag[i - 1] && m > mag[i + 1] { vEdges.append((x, y)) }
            } else if m >= mag[i - w] && m > mag[i + w] {
                hEdges.append((y, x))   // transposed so the same Hough finds near-horizontal lines
            }
        }
    }

    var r = TiltResult()
    let vLines = houghVertical(vEdges, w: w, h: h, maxDeg: 15, minVotes: Int(Double(h) * 0.15))
    let debug = ProcessInfo.processInfo.environment["PHOTOLAB_DEBUG"] != nil

    // 1. Verticals. Fit angle = a + b * u, where u is the line's horizontal position (-1 left ... +1 right),
    // weighted by length. a = roll at the frame centre; b = convergence (keystone) from tipping the camera.
    var pts = vLines.map { (u: ($0.pos - Double(w) / 2) / (Double(w) / 2), a: $0.angle, wt: Double($0.votes)) }
    func fit(_ pts: [(u: Double, a: Double, wt: Double)]) -> (Double, Double, Double) {
        let W = pts.reduce(0) { $0 + $1.wt }
        let mu = pts.reduce(0) { $0 + $1.wt * $1.u } / W, ma = pts.reduce(0) { $0 + $1.wt * $1.a } / W
        let su = pts.reduce(0) { $0 + $1.wt * ($1.u - mu) * ($1.u - mu) } / W
        var b = 0.0
        if su > 0.06 { b = pts.reduce(0) { $0 + $1.wt * ($1.u - mu) * ($1.a - ma) } / W / su }
        let a = ma - b * mu
        let res = sqrt(pts.reduce(0) { $0 + $1.wt * pow($1.a - (a + b * $1.u), 2) } / W)
        return (a, b, res)
    }
    /// Separate objects: line positions split by gaps wider than 8% of the frame.
    func clusters(_ us: [Double]) -> Int {
        let s = us.sorted()
        guard !s.isEmpty else { return 0 }
        var n = 1
        for i in 1..<s.count where s[i] - s[i - 1] > 0.16 { n += 1 }
        return n
    }
    var vert: (tilt: Double, conf: Double, n: Int, label: String)? = nil
    let hasLeft = pts.filter { $0.u < -0.15 }.count >= 2, hasRight = pts.filter { $0.u > 0.15 }.count >= 2
    if pts.count >= TiltRules.minLines {
        var (a, b, res) = fit(pts)
        pts = pts.filter { abs($0.a - (a + b * $0.u)) <= max(1.0, res) }
        if pts.count >= TiltRules.minLines {
            (a, b, res) = fit(pts)
            var oneSided = false
            if !(hasLeft && hasRight) {
                // Lines on one side only: roll and keystone can't be separated, so trust only lines near
                // the centre column (little keystone there).
                pts = pts.filter { abs($0.u) < 0.3 }
                oneSided = true
                if pts.count >= 5 { b = 0; (a, _, res) = fit(pts.map { (u: 0, a: $0.a, wt: $0.wt) }) } else { pts = [] }
            }
            let us = pts.map { $0.u }
            let span = (us.max() ?? 0) - (us.min() ?? 0)
            let nObj = clusters(us)
            if debug {
                r.debug += String(format: "lines %d a %+.2f b %+.2f res %.2f span %.2f obj %d%@; ", pts.count, a, b, res, span, nObj, oneSided ? " one-sided" : "")
            }
            if oneSided {
                if nObj >= 2 && res < 0.9 {
                    let c = min(1, Double(pts.count) / 10) * max(0, 1 - res / 1.2) * 0.6
                    vert = (a, c, pts.count, "\(pts.count) central vertical lines")
                }
            } else if nObj >= 2 && span >= 0.4 && res < 0.9 {
                if abs(b) > 5 {
                    // Strong convergence: read roll only from lines near the centre column.
                    let central = pts.filter { abs($0.u) < 0.25 }
                    r.keystone = round1(-b)
                    if central.count >= 3 {
                        let W = central.reduce(0) { $0 + $1.wt }
                        let t = central.reduce(0) { $0 + $1.wt * $1.a } / W
                        let c = min(1, Double(central.count) / 8) * 0.6 * max(0, 1 - res / 1.2)
                        vert = (t, c, central.count, "\(central.count) central vertical lines")
                    }
                } else {
                    let c = min(1, Double(pts.count) / 12) * max(0, 1 - res / 1.2) * min(1, span / 0.8) * min(1, Double(nObj) / 3)
                    vert = (a, c, pts.count, "\(pts.count) vertical lines")
                    if abs(b) >= 1 { r.keystone = round1(-b) }
                }
            }
        }
    }

    // 2. A long level line: collinear edges over at least 40% of the width (sea or architectural horizon).
    var horizon: (tilt: Double, coverage: Double)? = nil
    let hLines = houghVertical(hEdges, w: h, h: w, maxDeg: 6, minVotes: Int(Double(w) * TiltRules.minHorizonCoverage))
    if debug { r.debug += "hlines " + hLines.prefix(6).map { String(format: "[%+.1f y%.2f v%.2f]", -$0.angle, $0.pos / Double(h), Double($0.votes) / Double(w)) }.joined() + "; " }
    // Only lines in the middle band count: near the bottom they are kerbs, crossings and railings close
    // to the camera, whose angle is perspective, not roll; near the top, rooflines.
    if let top = hLines.first(where: { $0.pos / Double(h) >= 0.2 && $0.pos / Double(h) <= 0.75 }) {
        // Transposed space: angle sign flips back to image convention.
        horizon = (-top.angle, min(1, Double(top.votes) / Double(w)))
    }
    // 3. Vision's horizon (same sign convention as `horizonTilt`), only within a plausible range.
    let vis = visionHorizon.flatMap { abs($0) <= 10 ? $0 : nil }
    if debug {
        r.debug += (String(format: "vertical %@  horizon %@  vision %@",
            vert.map { String(format: "%+.2f (c %.2f, n %d)", $0.tilt, $0.conf, $0.n) } ?? "-",
            horizon.map { String(format: "%+.2f (cov %.2f)", $0.tilt, $0.coverage) } ?? "-",
            vis.map { String(format: "%+.2f", $0) } ?? "-"))
    }

    // Combine. Verticals lead; a horizon line or Vision's horizon confirms (raising confidence) or
    // contradicts (lowering it). A horizon line on its own counts only when Vision agrees with it.
    if var v = vert {
        var sources = [v.label]
        if let hz = horizon {
            if abs(hz.tilt - v.tilt) <= 0.8 { v.conf += 0.25 * hz.coverage; v.tilt = (v.tilt * 2 + hz.tilt) / 3; sources.append("horizon line") }
            else if abs(hz.tilt - v.tilt) > 1.5 { v.conf *= 0.7 }
        }
        if let vi = vis {
            if abs(vi - v.tilt) <= 1.0 { v.conf += 0.15; sources.append("Vision horizon") }
            else if abs(vi - v.tilt) > 2.5 { v.conf *= 0.8 }
        }
        r.tilt = round1(v.tilt); r.confidence = round2(min(1, v.conf)); r.source = sources.joined(separator: " + ")
    } else if let hz = horizon {
        var c = 0.3 * hz.coverage
        var src = "horizon line"
        if let vi = vis, abs(vi - hz.tilt) <= 0.8 { c = 0.45 + 0.4 * hz.coverage; src += " + Vision horizon" }
        r.tilt = round1(hz.tilt); r.confidence = round2(min(1, c)); r.source = src
    } else if let vi = vis {
        r.tilt = round1(vi); r.confidence = 0.2; r.source = "Vision horizon only"
    }
    // Below 0.25 the estimate is noise (e.g. Vision alone, which follows perspective lines): report none.
    if (r.confidence ?? 0) < 0.25 { r.tilt = nil; r.confidence = nil; r.source = nil }
    r.lines = vLines.prefix(12).map { l in
        let t = tan(l.angle * .pi / 180)
        let xTop = l.pos + (Double(h) / 2) * t, xBot = l.pos - (Double(h) / 2) * t
        return [round2(xTop / Double(w)), 0, round2(xBot / Double(w)), 1].map { $0 }
    }
    return r
}
