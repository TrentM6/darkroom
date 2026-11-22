import Foundation

func analyzeComposition(vision v: VisionResult, tilt: TiltResult, faces: [FaceReport], lab: [Lab], labW: Int, labH: Int, aspect: Double) -> CompositionReport {
    var subject = [0.5, 0.5]
    var source = "frame centre"
    // Subject: the subject face (largest, >= 0.3% of the frame), else the saliency peak, else the frame centre.
    if let f = faces.first(where: { $0.isSubject == true }) {
        subject = [f.rect[0] + f.rect[2] / 2, f.rect[1] + f.rect[3] / 2]
        source = "face"
    } else if !v.saliency.isEmpty {
        var sx = 0.0, sy = 0.0, s = 0.0
        for y in 0..<v.saliencyH {
            for x in 0..<v.saliencyW {
                let m = Double(v.saliency[y * v.saliencyW + x])
                let m2 = m * m   // sharpen toward the peak
                sx += m2 * (Double(x) + 0.5) / Double(v.saliencyW)
                sy += m2 * (Double(y) + 0.5) / Double(v.saliencyH)
                s += m2
            }
        }
        if s > 0 { subject = [sx / s, sy / s]; source = "saliency" }
    }

    // Placement against centre, thirds and edges (distances in frame-normalized units).
    let thirds: [(String, Double, Double)] = [
        ("upper-left third", 1 / 3, 1 / 3), ("upper-right third", 2 / 3, 1 / 3),
        ("lower-left third", 1 / 3, 2 / 3), ("lower-right third", 2 / 3, 2 / 3),
    ]
    let dists = thirds.map { ($0.0, hypot(subject[0] - $0.1, subject[1] - $0.2)) }
    let nearest = dists.min { $0.1 < $1.1 }!
    let dCentre = hypot(subject[0] - 0.5, subject[1] - 0.5)
    var placement: String
    if dCentre < 0.07 { placement = "centred" }
    else if nearest.1 < 0.08 { placement = "on the \(nearest.0)" }
    else if subject[0] < 0.12 || subject[0] > 0.88 || subject[1] < 0.1 || subject[1] > 0.9 { placement = "near the frame edge" }
    else if abs(subject[0] - 0.5) < 0.06 { placement = "centred horizontally" }
    else { placement = "off-centre (between centre and thirds)" }

    // Saliency mass in each 6% border strip.
    var border: [String: Double] = [:]
    if !v.saliency.isEmpty {
        let W = v.saliencyW, H = v.saliencyH
        let bx = max(1, Int(Double(W) * 0.06)), by = max(1, Int(Double(H) * 0.06))
        var total = 0.0, t = 0.0, b = 0.0, l = 0.0, r = 0.0
        for y in 0..<H {
            for x in 0..<W {
                let m = Double(v.saliency[y * W + x])
                total += m
                if y < by { t += m }
                if y >= H - by { b += m }
                if x < bx { l += m }
                if x >= W - bx { r += m }
            }
        }
        if total > 0 { border = ["top": round2(t / total), "bottom": round2(b / total), "left": round2(l / total), "right": round2(r / total)] }
    }

    // Bright edges pull the eye out of the frame, but only as a compact bright blob that touches the
    // edge (a sign, a window, a hot reflection), not a sky or a wall that fills that side.
    let brightEdges = compactBrightEdgeBlobs(lab, w: labW, h: labH)

    // Visual balance: L*-weighted centre of mass offset from centre (bright areas carry weight).
    var bx = 0.0, by = 0.0, bs = 0.0
    var y = 0
    while y < labH {
        var x = 0
        while x < labW {
            let m = Double(lab[y * labW + x].L)
            bx += m * (Double(x) / Double(labW) - 0.5); by += m * (Double(y) / Double(labH) - 0.5); bs += m
            x += 4
        }
        y += 4
    }

    var headroom: Double? = nil
    if source == "face", let f = faces.first(where: { $0.isSubject == true }) {
        headroom = round2(f.rect[1] / max(f.rect[3], 0.001))   // space above the face, in face-heights
    }

    let crops = [("4:5", 4.0 / 5.0), ("1:1", 1.0), ("16:9", 16.0 / 9.0)].map {
        CropSuggestion(aspect: $0.0, rect: suggestCrop(subject: subject, frameAspect: aspect, cropAspect: $0.1, centred: placement == "centred"))
    }

    return CompositionReport(
        subject: subject.map(round2), subjectSource: source, placement: placement,
        thirdsDistance: round2(nearest.1), horizonTilt: tilt.tilt, tiltSource: tilt.source,
        tiltConfidence: tilt.confidence, keystone: tilt.keystone, lines: tilt.lines,
        saliencyBorder: border, brightEdges: brightEdges, headroom: headroom,
        balance: bs > 0 ? [round2(bx / bs), round2(by / bs)] : [0, 0],
        salientObjects: v.salientObjects.map { $0.map(round2) }, crops: crops
    )
}

/// Largest crop of the given aspect that puts the subject on the nearest third (or keeps it centred).
func suggestCrop(subject: [Double], frameAspect: Double, cropAspect: Double, centred: Bool) -> [Double] {
    var cw = 1.0, ch = 1.0
    if cropAspect < frameAspect { cw = cropAspect / frameAspect } else { ch = frameAspect / cropAspect }
    func place(_ s: Double, _ size: Double) -> Double {
        if size >= 0.999 { return 0 }
        let options = centred ? [0.5] : [1.0 / 3, 2.0 / 3, 0.5]
        var best = 0.0, bestErr = Double.infinity
        for o in options {
            let start = min(max(s - o * size, 0), 1 - size)
            let err = abs((s - start) / size - o) + (o == 0.5 && !centred ? 0.05 : 0)
            if err < bestErr { bestErr = err; best = start }
        }
        return best
    }
    return [round2(place(subject[0], cw)), round2(place(subject[1], ch)), round2(cw), round2(ch)]
}

/// Edges ("top", "bottom", "left", "right") touched by a compact bright blob: a connected region of
/// L* >= max(85, frame p90 + 10) that touches the edge, covers 0.15–3% of the frame, spans at most a
/// quarter of that edge, and is at least 30 L* brighter than the ring around it.
func compactBrightEdgeBlobs(_ lab: [Lab], w: Int, h: Int) -> [String] {
    let n = w * h
    guard n > 0 else { return [] }
    // Work on a 4x-reduced grid.
    let s = 4, gw = w / s, gh = h / s
    guard gw > 8, gh > 8 else { return [] }
    var g = [Double](repeating: 0, count: gw * gh)
    for y in 0..<gh { for x in 0..<gw {
        var t = 0.0
        for dy in 0..<s { for dx in 0..<s { t += Double(lab[(y * s + dy) * w + x * s + dx].L) } }
        g[y * gw + x] = t / Double(s * s)
    } }
    let p90 = percentile(g, 0.9) ?? 100
    let thr = max(85, p90 + 10)
    var seen = [Bool](repeating: false, count: gw * gh)
    var out = Set<String>()
    for start in 0..<(gw * gh) where g[start] >= thr && !seen[start] {
        var stack = [start], cells: [Int] = []
        seen[start] = true
        while let i = stack.popLast() {
            cells.append(i)
            let x = i % gw, y = i / gw
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < gw && ny < gh {
                let j = ny * gw + nx
                if !seen[j] && g[j] >= thr { seen[j] = true; stack.append(j) }
            }
        }
        let area = Double(cells.count) / Double(gw * gh)
        guard area >= 0.0015 && area <= 0.03 else { continue }
        let xs = cells.map { $0 % gw }, ys = cells.map { $0 / gw }
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        var touched: [(String, Double)] = []
        if minY == 0 { touched.append(("top", Double(maxX - minX + 1) / Double(gw))) }
        if maxY == gh - 1 { touched.append(("bottom", Double(maxX - minX + 1) / Double(gw))) }
        if minX == 0 { touched.append(("left", Double(maxY - minY + 1) / Double(gh))) }
        if maxX == gw - 1 { touched.append(("right", Double(maxY - minY + 1) / Double(gh))) }
        guard !touched.isEmpty else { continue }
        // Ring: cells within 3 of the blob's bounding box but outside it.
        var ring = 0.0, rn = 0.0
        let set = Set(cells)
        for y in max(0, minY - 3)...min(gh - 1, maxY + 3) {
            for x in max(0, minX - 3)...min(gw - 1, maxX + 3) where !set.contains(y * gw + x) && g[y * gw + x] < thr {
                ring += g[y * gw + x]; rn += 1
            }
        }
        let blobMean = cells.reduce(0) { $0 + g[$1] } / Double(cells.count)
        guard rn > 0, blobMean - ring / rn >= 30 else { continue }
        for (edge, extent) in touched where extent <= 0.25 { out.insert(edge) }
    }
    return ["top", "bottom", "left", "right"].filter { out.contains($0) }
}
