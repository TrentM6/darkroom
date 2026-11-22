import Foundation

func labPlane(_ img: RGBAImage) -> [Lab] {
    var out = [Lab](repeating: Lab(L: 0, a: 0, b: 0), count: img.width * img.height)
    img.data.withUnsafeBufferPointer { s in
        for i in 0..<(img.width * img.height) {
            out[i] = ColorMath.lab(r: s[i * 4], g: s[i * 4 + 1], b: s[i * 4 + 2])
        }
    }
    return out
}

func analyzeColor(_ img: RGBAImage, lab: [Lab]) -> ColorReport {
    let n = lab.count
    var na = 0.0, nb = 0.0, nn = 0
    var ga = 0.0, gb = 0.0, gn = 0
    var chromaSum = 0.0
    var chromaHist = [Int](repeating: 0, count: 151)
    var satClip = 0
    var bSum = 0.0
    img.data.withUnsafeBufferPointer { s in
        for i in 0..<n {
            let c = lab[i]
            let C = sqrt(Double(c.a * c.a + c.b * c.b))
            chromaSum += C
            chromaHist[min(150, Int(C))] += 1
            bSum += Double(c.b)
            if c.L > 2 && c.L < 98 {
                ga += Double(c.a); gb += Double(c.b); gn += 1
            }
            if C < 12 && c.L > 15 && c.L < 92 {
                na += Double(c.a); nb += Double(c.b); nn += 1
            }
            let r = s[i * 4], g = s[i * 4 + 1], b = s[i * 4 + 2]
            if C > 35 && (max(r, g, b) == 255 || min(r, g, b) == 0) { satClip += 1 }
        }
    }
    let neutralFrac = Double(nn) / Double(n)
    var castA = 0.0, castB = 0.0, confidence = "low"
    if nn > 0 && neutralFrac >= 0.02 {
        castA = na / Double(nn); castB = nb / Double(nn)
        confidence = neutralFrac >= 0.10 ? "high" : "medium"
    } else if gn > 0 {
        castA = ga / Double(gn); castB = gb / Double(gn)
    }
    let mag = sqrt(castA * castA + castB * castB)

    var acc = 0, p95 = 0
    for i in 0...150 { acc += chromaHist[i]; if Double(acc) >= 0.95 * Double(n) { p95 = i; break } }

    let palette = kmeansPalette(lab, k: 6)
    return ColorReport(
        castA: round1(castA), castB: round1(castB), castMagnitude: round1(mag),
        castName: castName(a: castA, b: castB, magnitude: mag),
        neutralFraction: round2(neutralFrac * 100), castConfidence: confidence,
        grayWorldA: round1(gn > 0 ? ga / Double(gn) : 0), grayWorldB: round1(gn > 0 ? gb / Double(gn) : 0),
        meanChroma: round1(chromaSum / Double(n)), p95Chroma: Double(p95),
        saturationClip: round2(Double(satClip) / Double(n) * 100),
        warmth: round1(bSum / Double(n)),
        palette: palette,
        harmony: harmony(palette)
    )
}

func castName(a: Double, b: Double, magnitude: Double) -> String {
    if magnitude < 2 { return "neutral" }
    var ang = atan2(b, a) * 180 / .pi
    if ang < 0 { ang += 360 }
    let names = ["magenta-red", "warm / orange", "yellow", "yellow-green", "green", "cyan", "blue", "magenta"]
    let name = names[Int(((ang + 22.5).truncatingRemainder(dividingBy: 360)) / 45)]
    let strength = magnitude < 5 ? "slight" : magnitude < 10 ? "moderate" : "strong"
    return "\(strength) \(name)"
}

/// Deterministic k-means in Lab (seeded k-means++), merged and sorted by weight.
func kmeansPalette(_ lab: [Lab], k: Int) -> [PaletteColor] {
    let stride = max(1, lab.count / 40_000)
    var pts: [Lab] = []
    pts.reserveCapacity(lab.count / stride + 1)
    var i = 0
    while i < lab.count { pts.append(lab[i]); i += stride }
    guard pts.count > k else { return [] }

    var seed: UInt64 = 0x9E3779B97F4A7C15
    func rand() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(1 << 53)
    }
    func d2(_ p: Lab, _ q: Lab) -> Float {
        let dl = p.L - q.L, da = p.a - q.a, db = p.b - q.b
        return dl * dl + da * da + db * db
    }
    var centers = [pts[Int(rand() * Double(pts.count))]]
    var dist = pts.map { d2($0, centers[0]) }
    while centers.count < k {
        let total = dist.reduce(0, +)
        var target = Float(rand()) * total
        var pick = 0
        for (j, d) in dist.enumerated() { target -= d; if target <= 0 { pick = j; break } }
        centers.append(pts[pick])
        for j in 0..<pts.count { dist[j] = min(dist[j], d2(pts[j], pts[pick])) }
    }
    var assign = [Int](repeating: 0, count: pts.count)
    for _ in 0..<15 {
        for j in 0..<pts.count {
            var bi = 0, bd = Float.greatestFiniteMagnitude
            for (ci, c) in centers.enumerated() { let d = d2(pts[j], c); if d < bd { bd = d; bi = ci } }
            assign[j] = bi
        }
        var sums = [(Double, Double, Double, Int)](repeating: (0, 0, 0, 0), count: k)
        for j in 0..<pts.count {
            let a = assign[j]
            sums[a].0 += Double(pts[j].L); sums[a].1 += Double(pts[j].a); sums[a].2 += Double(pts[j].b); sums[a].3 += 1
        }
        for ci in 0..<k where sums[ci].3 > 0 {
            let c = Double(sums[ci].3)
            centers[ci] = Lab(L: Float(sums[ci].0 / c), a: Float(sums[ci].1 / c), b: Float(sums[ci].2 / c))
        }
    }
    var weights = [Double](repeating: 0, count: k)
    for a in assign { weights[a] += 1 }
    var clusters = (0..<k).map { (centers[$0], weights[$0]) }.filter { $0.1 > 0 }
    // Merge near-identical colours (ΔE76 < 7).
    var merged = true
    while merged {
        merged = false
        outer: for x in 0..<clusters.count {
            for y in (x + 1)..<clusters.count where sqrt(d2(clusters[x].0, clusters[y].0)) < 7 {
                let (c1, w1) = clusters[x], (c2, w2) = clusters[y]
                let w = Float(w1 + w2)
                clusters[x] = (Lab(L: (c1.L * Float(w1) + c2.L * Float(w2)) / w, a: (c1.a * Float(w1) + c2.a * Float(w2)) / w,
                                   b: (c1.b * Float(w1) + c2.b * Float(w2)) / w), w1 + w2)
                clusters.remove(at: y)
                merged = true
                break outer
            }
        }
    }
    let total = Double(pts.count)
    return clusters.sorted { $0.1 > $1.1 }.map {
        PaletteColor(hex: ColorMath.hex($0.0), weight: round2($0.1 / total * 100), lab: [round1(Double($0.0.L)), round1(Double($0.0.a)), round1(Double($0.0.b))])
    }
}

func harmony(_ palette: [PaletteColor]) -> String {
    let hues = palette.filter { $0.weight >= 4 && sqrt($0.lab[1] * $0.lab[1] + $0.lab[2] * $0.lab[2]) >= 15 }
        .map { (atan2($0.lab[2], $0.lab[1]) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360) }
    if hues.isEmpty { return "neutral / muted" }
    if hues.count == 1 { return "single accent hue" }
    func diff(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 360); return min(d, 360 - d) }
    var maxDiff = 0.0
    var hasComplement = false
    for i in 0..<hues.count {
        for j in (i + 1)..<hues.count {
            let d = diff(hues[i], hues[j])
            maxDiff = max(maxDiff, d)
            if d >= 150 { hasComplement = true }
        }
    }
    if maxDiff <= 35 { return "monochromatic" }
    if maxDiff <= 75 { return "analogous" }
    if hasComplement { return hues.count >= 3 ? "split-complementary" : "complementary" }
    if hues.count >= 3 { return "triadic / varied" }
    return "contrasting"
}

/// Vectorscope angle of a face's skin. The skin-tone line sits at ~123°.
func skinAngle(_ img: RGBAImage, rect: [Double]) -> (angle: Double, offset: Double)? {
    let x0 = Int((rect[0] + rect[2] * 0.25) * Double(img.width)), x1 = Int((rect[0] + rect[2] * 0.75) * Double(img.width))
    let y0 = Int((rect[1] + rect[3] * 0.3) * Double(img.height)), y1 = Int((rect[1] + rect[3] * 0.8) * Double(img.height))
    guard x1 > x0 + 2, y1 > y0 + 2 else { return nil }
    var cb = 0.0, cr = 0.0, n = 0.0
    for y in max(0, y0)..<min(img.height, y1) {
        for x in max(0, x0)..<min(img.width, x1) {
            let p = (y * img.width + x) * 4
            let r = Double(img.data[p]), g = Double(img.data[p + 1]), b = Double(img.data[p + 2])
            let Y = 0.299 * r + 0.587 * g + 0.114 * b
            guard Y > 40 && Y < 235 else { continue }
            cb += -0.168736 * r - 0.331264 * g + 0.5 * b
            cr += 0.5 * r - 0.418688 * g - 0.081312 * b
            n += 1
        }
    }
    guard n > 20 else { return nil }
    var ang = atan2(cr / n, cb / n) * 180 / .pi
    if ang < 0 { ang += 360 }
    return (round1(ang), round1(ang - 123))
}
