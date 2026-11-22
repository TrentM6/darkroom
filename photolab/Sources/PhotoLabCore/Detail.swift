import Foundation

// MARK: - Noise (Immerkær's fast noise estimate on the flattest blocks)

private func immerkaer(_ a: UnsafeBufferPointer<Float>, stride w: Int, x0: Int, y0: Int, size: Int) -> (sigma: Float, mean: Float) {
    var sum: Float = 0, mean: Float = 0
    for y in (y0 + 1)..<(y0 + size - 1) {
        let r = y * w
        for x in (x0 + 1)..<(x0 + size - 1) {
            let i = r + x
            let v = a[i - w - 1] - 2 * a[i - w] + a[i - w + 1]
                - 2 * a[i - 1] + 4 * a[i] - 2 * a[i + 1]
                + a[i + w - 1] - 2 * a[i + w] + a[i + w + 1]
            sum += abs(v)
            mean += a[i]
        }
    }
    let k = Float((size - 2) * (size - 2))
    return (sum * sqrtf(.pi / 2) / (6 * k), mean / k)
}

func analyzeNoise(luma: Plane, lumaHalf: Plane, cb: Plane, cr: Plane) -> NoiseReport {
    let B = 32
    struct Blk { var sigma: Float; var sigmaHalf: Float; var chroma: Float; var mean: Float }
    var blocks: [Blk] = []
    luma.data.withUnsafeBufferPointer { a in
        lumaHalf.data.withUnsafeBufferPointer { ah in
            cb.data.withUnsafeBufferPointer { cbp in
                cr.data.withUnsafeBufferPointer { crp in
                    var y = 0
                    while y + B <= luma.height {
                        var x = 0
                        while x + B <= luma.width {
                            let f = immerkaer(a, stride: luma.width, x0: x, y0: y, size: B)
                            if f.mean > 6 && f.mean < 249 {
                                let hx = x / 2, hy = y / 2
                                if hx + B / 2 <= lumaHalf.width && hy + B / 2 <= lumaHalf.height {
                                    let hs = immerkaer(ah, stride: lumaHalf.width, x0: hx, y0: hy, size: B / 2)
                                    let c1 = immerkaer(cbp, stride: cb.width, x0: hx, y0: hy, size: B / 2)
                                    let c2 = immerkaer(crp, stride: cr.width, x0: hx, y0: hy, size: B / 2)
                                    blocks.append(Blk(sigma: f.sigma, sigmaHalf: hs.sigma, chroma: sqrtf((c1.sigma * c1.sigma + c2.sigma * c2.sigma) / 2), mean: f.mean))
                                }
                            }
                            x += B
                        }
                        y += B
                    }
                }
            }
        }
    }

    // Noise lives in the flattest areas: take the 10th percentile of sigma per tonal band.
    // Measured at 1:1 and at 2x (coarse grain survives 2x2 averaging; fine noise halves). Report the larger.
    func band(_ lo: Float, _ hi: Float) -> Double? {
        let sel = blocks.filter { $0.mean >= lo && $0.mean < hi }
        guard sel.count >= 20 else { return nil }
        let fine = percentile(sel.map { Double($0.sigma) }, 0.10) ?? 0
        let coarse = percentile(sel.map { Double($0.sigmaHalf) }, 0.10) ?? 0
        return round2(max(fine, coarse))
    }
    let shadows = band(6, 70), mids = band(70, 180), highs = band(180, 249)
    let all = band(6, 249)
    let luma = mids ?? all
    let fineSigma = percentile(blocks.filter { $0.mean >= 70 && $0.mean < 180 }.map { Double($0.sigma) }, 0.10).map(round2)
    let coarseSigma = percentile(blocks.filter { $0.mean >= 70 && $0.mean < 180 }.map { Double($0.sigmaHalf) }, 0.10).map(round2)

    // Coarseness: in flat blocks, pure fine noise halves when 2x2-averaged. Larger ratio = coarser grain.
    let flat = blocks.sorted { $0.sigma < $1.sigma }.prefix(max(20, blocks.count / 10))
    let ratios = flat.filter { $0.sigma > 0.05 }.map { Double(2 * $0.sigmaHalf / $0.sigma) }
    let coarse = percentile(ratios, 0.5).map(round2)
    let chroma = percentile(flat.map { Double($0.chroma) }, 0.5).map(round2)

    var level = "unknown"
    if let s = luma {
        level = s < 0.8 ? "very clean" : s < 1.5 ? "clean" : s < 2.5 ? "fine grain" : s < 4 ? "moderate" : "heavy"
    }
    return NoiseReport(lumaSigma: luma, fineSigma: fineSigma, coarseSigma: coarseSigma, shadowSigma: shadows, midSigma: mids, highlightSigma: highs, chromaSigma: chroma, coarseness: coarse, level: level)
}

// MARK: - Sharpness (edge-width measurement on a grain-proof plane)
//
// Fuji's Grain Effect (Strong / Large) adds clumps 2–3 px wide with σ ≈ 6 levels. Measured at 100%,
// those clumps read as thousands of narrow "edges", so the old metric measured the grain, not the
// image. Here edges are measured on a 2× box-downsampled, 3×3-median-filtered luma plane (the grain
// clumps shrink to one pixel and the median removes them), and an edge only counts when its contrast
// is at least 4× the grain σ of the original file. Widths are reported in pixels at 100% (2× the
// measured width), so the scale below is specific to this measurement: an ideal edge reads about 3 px.

@inline(__always) private func cswap(_ a: inout Float, _ b: inout Float) { if a > b { let t = a; a = b; b = t } }

/// 3×3 median (Paeth's 19-exchange network).
func median3(_ p: Plane) -> Plane {
    let w = p.width, h = p.height
    var out = p.data
    guard w > 2, h > 2 else { return p }
    p.data.withUnsafeBufferPointer { a in
        out.withUnsafeMutableBufferPointer { o in
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let i = y * w + x
                    var p0 = a[i - w - 1], p1 = a[i - w], p2 = a[i - w + 1]
                    var p3 = a[i - 1], p4 = a[i], p5 = a[i + 1]
                    var p6 = a[i + w - 1], p7 = a[i + w], p8 = a[i + w + 1]
                    cswap(&p1, &p2); cswap(&p4, &p5); cswap(&p7, &p8); cswap(&p0, &p1); cswap(&p3, &p4); cswap(&p6, &p7)
                    cswap(&p1, &p2); cswap(&p4, &p5); cswap(&p7, &p8); cswap(&p0, &p3); cswap(&p5, &p8); cswap(&p4, &p7)
                    cswap(&p3, &p6); cswap(&p1, &p4); cswap(&p2, &p5); cswap(&p4, &p7); cswap(&p4, &p2); cswap(&p6, &p4)
                    cswap(&p4, &p2)
                    o[i] = p4
                }
            }
        }
    }
    return Plane(width: w, height: h, data: out)
}

/// Grain/noise σ of the flattest areas: per-block standard deviation after removing a fitted plane
/// (so sky gradients don't count), 10th percentile over mid-tone blocks. Unlike a Laplacian estimate,
/// this sees coarse film-grain clumps.
func flatSigma(_ p: Plane, block B: Int) -> Double {
    var sig: [Double] = []
    let w = p.width
    let c = Double(B - 1) / 2
    var uu = 0.0
    for k in 0..<B { uu += (Double(k) - c) * (Double(k) - c) }
    uu *= Double(B)
    let n = Double(B * B)
    p.data.withUnsafeBufferPointer { a in
        var y = 0
        while y + B <= p.height {
            var x = 0
            while x + B <= p.width {
                var m = 0.0, su = 0.0, sv = 0.0
                for yy in 0..<B {
                    let r = (y + yy) * w + x
                    for xx in 0..<B { let z = Double(a[r + xx]); m += z; su += z * (Double(xx) - c); sv += z * (Double(yy) - c) }
                }
                m /= n
                if m > 20 && m < 235 {
                    let gx = su / uu, gy = sv / uu
                    var ss = 0.0
                    for yy in 0..<B {
                        let r = (y + yy) * w + x
                        for xx in 0..<B {
                            let d = Double(a[r + xx]) - m - gx * (Double(xx) - c) - gy * (Double(yy) - c)
                            ss += d * d
                        }
                    }
                    sig.append(sqrt(ss / n))
                }
                x += B
            }
            y += B
        }
    }
    return percentile(sig, 0.10) ?? 1
}

struct EdgeSample { var h: [Float]; var v: [Float] }

/// Widths (10–90% rise) of edges inside a rect. `h` = horizontal scans (vertical edges, blur along x),
/// `v` = vertical scans (horizontal edges, blur along y). An edge must have a gradient peak of at least
/// `minGrad`, continue along its length (2 lines either side), and rise by at least `minContrast`.
/// The walk across the edge stops where the slope drops under 15% of the peak, so a soft shoulder or a
/// gentle gradient next to the edge doesn't widen it.
func edgeWidths(_ p: Plane, x0: Int, y0: Int, x1: Int, y1: Int, step: Int, minContrast: Float, minGrad: Float) -> EdgeSample {
    var hs: [Float] = [], vs: [Float] = []
    let w = p.width
    let maxW = 24
    let xa = max(3, x0), xb = min(p.width - 4, x1), ya = max(3, y0), yb = min(p.height - 4, y1)
    guard xb > xa + 8, yb > ya + 8 else { return EdgeSample(h: [], v: []) }
    let buf = UnsafeMutablePointer<Float>.allocate(capacity: 2 * maxW + 8)
    defer { buf.deallocate() }
    p.data.withUnsafeBufferPointer { a in
        for dir in 0..<2 {
            let along = dir == 0 ? 1 : w        // step across the edge
            let perp = dir == 0 ? w : 1         // step along the edge
            let outerA = dir == 0 ? ya : xa, outerB = dir == 0 ? yb : xb
            let innerA = dir == 0 ? xa : ya, innerB = dir == 0 ? xb : yb
            var o = outerA
            while o < outerB {
                var t = innerA
                while t < innerB {
                    let i0 = dir == 0 ? o * w + t : t * w + o
                    let g = a[i0 + along] - a[i0 - along]
                    let ag = abs(g)
                    if ag >= minGrad && ag >= abs(a[i0 + 2 * along] - a[i0]) && ag > abs(a[i0] - a[i0 - 2 * along]) {
                        let s: Float = g > 0 ? 1 : -1
                        var continuous = true
                        for d in [-2, -1, 1, 2] where continuous {
                            var hit = false
                            for e in -1...1 {
                                let j = i0 + d * perp + e * along
                                if s * (a[j + along] - a[j - along]) >= 0.6 * ag { hit = true; break }
                            }
                            continuous = hit
                        }
                        if !continuous { t += 1; continue }
                        let stopSlope = max(0.5, 0.15 * ag / 2)
                        var i = 0, j = 0
                        while t - i > innerA - 3 && i < maxW && s * (a[i0 - i * along] - a[i0 - (i + 1) * along]) > stopSlope { i += 1 }
                        while t + j < innerB + 3 && j < maxW && s * (a[i0 + (j + 1) * along] - a[i0 + j * along]) > stopSlope { j += 1 }
                        let contrast = s * (a[i0 + j * along] - a[i0 - i * along])
                        if contrast >= minContrast && i < maxW && j < maxW {
                            let n = i + j + 1
                            for k in 0..<n { buf[k] = s * a[i0 + (k - i) * along] }
                            let wdt = rise1090(buf, n)
                            if dir == 0 { hs.append(wdt) } else { vs.append(wdt) }
                        }
                        t += j + 1
                        continue
                    }
                    t += 1
                }
                o += step
            }
        }
    }
    return EdgeSample(h: hs, v: vs)
}

/// 10–90% rise distance of a monotonic edge profile, with linear interpolation (sub-pixel).
@inline(__always) func rise1090(_ v: UnsafeMutablePointer<Float>, _ n: Int) -> Float {
    let lo = v[0], c = v[n - 1] - lo
    let l10 = lo + 0.1 * c, l90 = lo + 0.9 * c
    var p10: Float = 0, p90 = Float(n - 1)
    var found10 = false
    for k in 1..<n {
        if !found10 && v[k] >= l10 {
            p10 = Float(k - 1) + (l10 - v[k - 1]) / max(1e-6, v[k] - v[k - 1]); found10 = true
        }
        if v[k] >= l90 {
            p90 = Float(k - 1) + (l90 - v[k - 1]) / max(1e-6, v[k] - v[k - 1]); break
        }
    }
    return max(0.3, p90 - p10)
}

struct SharpnessContext {
    var luma: Plane
    var capture: CaptureInfo
}

/// The grain-proof plane plus the thresholds used on it, kept for face / region measurements.
struct SharpPlane {
    var plane: Plane
    var minContrast: Float
    var minGrad: Float
}

/// Thresholds for the frame width (mean of the sharpest 20% of tiles, px at 100%, measured on the
/// grain-proof plane; an ideal edge reads ≈ 3.0). Calibrated on the July 4th X-Pro3 shoot (Grain Effect
/// Strong/Large, 21 mm, checked against 100% crops): crisp frames read 2.7–3.3; 8138, 8041 and 8088
/// (sharp subject, softer surroundings) 3.3–3.75; 8214 (soft, slight shake) ≈ 4.65; 8186 (vertical
/// shake) ≈ 5.5; 8029 (motion-blurred through a train window) ≈ 7.2.
enum SharpnessScale {
    static let ideal = 3.0, critical = 3.2, sharp = 3.85, slight = 4.4, soft = 5.2, missed = 6.5
    /// Minimum edges per scan direction for a tile to count as textured.
    static let minEdgesPerDirection = 8
    /// A tile's blur is directional when one scan direction is this much wider than the other.
    static let directionalRatio = 1.5
}
func sharpLevel(_ b: Double) -> String {
    b <= SharpnessScale.critical ? "critically sharp" : b <= SharpnessScale.sharp ? "sharp"
        : b <= SharpnessScale.slight ? "slightly soft at 100%" : b <= SharpnessScale.soft ? "soft" : b <= SharpnessScale.missed ? "very soft" : "blurred"
}
/// 100 at the critical threshold, 0 at "missed".
func sharpnessScore(_ w: Double) -> Double {
    min(100, max(0, (SharpnessScale.missed - w) / (SharpnessScale.missed - SharpnessScale.critical) * 100))
}

func analyzeSharpness(_ ctx: SharpnessContext) -> (SharpnessReport, SharpPlane) {
    let full = ctx.luma
    let grain = flatSigma(full, block: 32)
    let p = median3(Pixels.half(full))
    let cleanSigma = flatSigma(p, block: 16)
    // Edge contrast must clear 4× the grain σ of the original (≈ 23 levels with Grain Effect Strong).
    let minC = Float(max(16, 4 * grain))
    let minG = max(minC / 4, Float(3 * cleanSigma))
    let sp = SharpPlane(plane: p, minContrast: minC, minGrad: minG)

    let long = max(p.width, p.height)
    let tile = max(16, long / 16)
    let cols = max(1, p.width / tile), rows = max(1, p.height / tile)
    let tw = p.width / cols, th = p.height / rows
    var tiles: [Double?] = []
    var ratios: [Double] = []
    let need = SharpnessScale.minEdgesPerDirection
    for r in 0..<rows {
        for c in 0..<cols {
            let e = edgeWidths(p, x0: c * tw, y0: r * th, x1: (c + 1) * tw, y1: (r + 1) * th, step: 1, minContrast: minC, minGrad: minG)
            // A tile is measured only with edges in both directions; its width is the WIDER direction,
            // so motion blur (which leaves edges parallel to the motion sharp) can't hide.
            if e.h.count >= need, e.v.count >= need,
               let wh = percentile(e.h.map { Double($0) * 2 }, 0.25), let wv = percentile(e.v.map { Double($0) * 2 }, 0.25) {
                tiles.append(round2(max(wh, wv)))
                ratios.append(wh / wv)
            } else {
                tiles.append(nil)
            }
        }
    }

    let valid = tiles.enumerated().compactMap { i, v in v.map { (i, $0) } }.sorted { $0.1 < $1.1 }
    let widths = valid.map { $0.1 }
    var best: Double? = nil, bestTile: [Int]? = nil, bestRect: [Double]? = nil
    if let first = valid.first {
        let k = min(5, valid.count)
        best = round2(widths.prefix(k).reduce(0, +) / Double(k))
        bestTile = [first.0 % cols, first.0 / cols]
        bestRect = [Double(first.0 % cols) / Double(cols), Double(first.0 / cols) / Double(rows), 1 / Double(cols), 1 / Double(rows)]
    }
    let global = percentile(widths, 0.5).map(round2)
    // Frame sharpness: the mean of the sharpest 20% of textured tiles (at least 5). That's where focus
    // landed; it stays sharp when a close subject throws the background out of focus (8184), and it
    // goes soft only when nothing substantial is sharp (shake, missed focus, motion).
    var frameW: Double? = nil
    if !widths.isEmpty {
        let k = min(widths.count, max(5, widths.count / 5))
        frameW = round2(widths.prefix(k).reduce(0, +) / Double(k))
    }

    // Motion: blur along one direction in at least half of the textured tiles.
    var aniso: Double? = nil, motion: String? = nil, motionFrac: Double? = nil
    if ratios.count >= 12 {
        aniso = percentile(ratios, 0.5).map(round2)
        let n = Double(ratios.count), k = SharpnessScale.directionalRatio
        let fh = Double(ratios.filter { $0 >= k }.count) / n, fv = Double(ratios.filter { $0 <= 1 / k }.count) / n
        motionFrac = round2(max(fh, fv))
        if fh >= 0.5 { motion = "horizontal" } else if fv >= 0.5 { motion = "vertical" }
    }

    // Handheld rule of thumb: 1 / (35mm-equivalent focal length). The X-Pro3 has no IBIS.
    var limit: String? = nil, risk = false
    if let f35 = ctx.capture.focalLength35 ?? ctx.capture.focalLength.map({ $0 * 1.5 }), let t = ctx.capture.exposureTime {
        limit = "1/\(Int(f35.rounded()))"
        risk = t > 1 / f35 * 1.01
    }

    var report = SharpnessReport(cols: cols, rows: rows, tiles: tiles, bestWidth: best, bestTile: bestTile, bestRect: bestRect,
                                 anisotropy: aniso, motionHint: motion, subjectWidth: nil, afPointWidth: nil,
                                 handheldLimit: limit, shakeRisk: risk, level: "unknown", webWidth: nil)
    report.globalWidth = global
    report.texturedTiles = valid.count
    report.motionFraction = motionFrac
    report.grainSigma = round2(grain)
    report.webScale = 2048 / Double(max(full.width, full.height))
    setFrameWidth(&report, frameW)
    if let af = ctx.capture.afPoint {
        report.afPointWidth = regionWidth(report, rect: [af[0] - 0.03, af[1] - 0.03, af[2] + 0.06, af[3] + 0.06], minTiles: 1)?.width
    }
    return (report, sp)
}

/// The width that decides the verdict and the score.
func setFrameWidth(_ s: inout SharpnessReport, _ w: Double?) {
    s.frameWidth = w
    s.level = w.map(sharpLevel) ?? "unknown"
    // Equivalent width at a 2048 px long edge.
    let k = s.webScale ?? 2048.0 / 6240
    s.webWidth = w.map { round2(max(1, $0 * k)) }
}

/// Width over the tiles whose centre falls in any of the normalized rects: the 25th percentile of
/// their widths (the subject's own sharpest edges).
func regionWidth(_ s: SharpnessReport, rects: [[Double]], minTiles: Int) -> (width: Double, tiles: Int)? {
    regionWidth(s, minTiles: minTiles) { cx, cy in
        rects.contains { r in cx >= r[0] && cx <= r[0] + r[2] && cy >= r[1] && cy <= r[1] + r[3] }
    }
}
func regionWidth(_ s: SharpnessReport, rect: [Double], minTiles: Int) -> (width: Double, tiles: Int)? {
    regionWidth(s, rects: [rect], minTiles: minTiles)
}
func regionWidth(_ s: SharpnessReport, minTiles: Int, inside: (Double, Double) -> Bool) -> (width: Double, tiles: Int)? {
    var ws: [Double] = []
    for (i, t) in s.tiles.enumerated() {
        guard let t else { continue }
        let cx = (Double(i % s.cols) + 0.5) / Double(s.cols), cy = (Double(i / s.cols) + 0.5) / Double(s.rows)
        if inside(cx, cy) { ws.append(t) }
    }
    guard ws.count >= minTiles, let w = percentile(ws, 0.25) else { return nil }
    return (round2(w), ws.count)
}

/// Edge width on a face's upper part (brows, eyes, glasses), on the grain-proof plane.
/// Only used relative to the frame's sharpest area, for a focus-off-subject check.
func faceEdgeWidth(_ sp: SharpPlane, rect: [Double]) -> Double? {
    let p = sp.plane
    let x = rect[0] - rect[2] * 0.05, y = rect[1]
    let w = rect[2] * 1.1, h = rect[3] * 0.6
    let e = edgeWidths(p, x0: Int(x * Double(p.width)), y0: Int(y * Double(p.height)),
                       x1: Int((x + w) * Double(p.width)), y1: Int((y + h) * Double(p.height)), step: 1,
                       minContrast: sp.minContrast, minGrad: sp.minGrad)
    let all = (e.h + e.v).map { Double($0) * 2 }
    guard all.count >= 10 else { return nil }
    return percentile(all, 0.25).map(round2)
}
