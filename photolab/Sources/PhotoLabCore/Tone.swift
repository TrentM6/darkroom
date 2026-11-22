import Foundation

struct ClipOverlay {
    let width: Int
    let height: Int
    let rgba: [UInt8]
}

/// Exposure, clipping, tonal range and contrast, measured on the full-resolution file.
func analyzeTone(_ img: RGBAImage, lab1024: [Lab], labW: Int, labH: Int) -> (ToneReport, ClipOverlay) {
    let w = img.width, h = img.height, n = w * h
    var hr = [Int](repeating: 0, count: 256), hg = hr, hb = hr, hl = hr
    var clipAny = 0, clipAll = 0, shadowAll = 0
    var clipC = [0, 0, 0], shadowC = [0, 0, 0]

    let block = 8
    let bw = (w + block - 1) / block, bh = (h + block - 1) / block
    var hiBlock = [Int32](repeating: 0, count: bw * bh)
    var loBlock = [Int32](repeating: 0, count: bw * bh)

    let lin = Pixels.toLinear, toBin = Pixels.linearToBin
    img.data.withUnsafeBufferPointer { s in
        for y in 0..<h {
            let brow = (y / block) * bw
            for x in 0..<w {
                let p = (y * w + x) * 4
                let r = Int(s[p]), g = Int(s[p + 1]), b = Int(s[p + 2])
                hr[r] += 1; hg[g] += 1; hb[b] += 1
                let Y = 0.2126 * lin[r] + 0.7152 * lin[g] + 0.0722 * lin[b]
                hl[toBin[min(4095, Int(Y * 4095 + 0.5))]] += 1
                let mx = max(r, g, b), mn = min(r, g, b)
                if mx >= 254 {
                    clipAny += 1
                    if r >= 254 { clipC[0] += 1 }
                    if g >= 254 { clipC[1] += 1 }
                    if b >= 254 { clipC[2] += 1 }
                    if mn >= 254 { clipAll += 1 }
                }
                // Blown = white (all channels at the top). A saturated red at 255/40/40 is a channel
                // clip, reported separately, not blown highlights.
                if mn >= 250 { hiBlock[brow + x / block] += 1 }
                if mn <= 2 {
                    if r <= 2 { shadowC[0] += 1 }
                    if g <= 2 { shadowC[1] += 1 }
                    if b <= 2 { shadowC[2] += 1 }
                    if mx <= 2 { shadowAll += 1; loBlock[brow + x / block] += 1 }
                }
            }
        }
    }

    let N = Double(n)
    func pct(_ c: Int) -> Double { round2(Double(c) / N * 100) }

    // Luminance statistics from the luminance histogram (bin = sRGB-encoded value).
    let binLinear: [Double] = (0..<256).map { Double(Pixels.toLinear[$0]) }
    var lsum = 0.0, lsq = 0.0, dark = 0.0
    var zones = [Double](repeating: 0, count: 11)
    for i in 0..<256 where hl[i] > 0 {
        let c = Double(hl[i])
        let yl = binLinear[i]
        let L = ColorMath.lstar(fromLinear: yl)
        lsum += c * L; lsq += c * L * L
        if L < 10 { dark += c }
        // Zone n = L* 10n ± 5 (Zone V = L* 50 = 18% grey, Zone X = paper white).
        zones[min(10, max(0, Int((L / 10).rounded())))] += c
    }
    let meanL = lsum / N
    let stdL = sqrt(max(0, lsq / N - meanL * meanL))

    func binPercentile(_ p: Double) -> Int {
        let target = p * N
        var acc = 0.0
        for i in 0..<256 { acc += Double(hl[i]); if acc >= target { return i } }
        return 255
    }
    let lp = { (p: Double) in ColorMath.lstar(fromLinear: binLinear[binPercentile(p)]) }
    let lo = max(binLinear[binPercentile(0.005)], 1.0 / 4096), hi = max(binLinear[binPercentile(0.995)], lo)
    let medianL = lp(0.5)
    // Median luminance against 18% grey. (A log-average is dragged down by shadows: correctly exposed
    // street frames read about -0.6 EV with it.) Informational only; no verdict uses it.
    let ev = log2(max(binLinear[binPercentile(0.5)], 1.0 / 4096) / 0.184)

    // Local contrast on the 1024px L* plane: mean |L - box blur(L)|, radius 8.
    let localC = localContrast(lab1024, w: labW, h: labH, radius: 8)

    // Clipped regions: blocks that are mostly clipped, 4-connected.
    let half = Int32(block * block / 2)
    let hiMask = hiBlock.map { $0 > half }
    let loMask = loBlock.map { $0 > half }
    let hiRegions = regions(hiMask, w: bw, h: bh)
    let loRegions = regions(loMask, w: bw, h: bh)
    let totalBlocks = Double(bw * bh)
    let largestHi = round2(Double(hiRegions.max() ?? 0) / totalBlocks * 100)
    let largestLo = round2(Double(loRegions.max() ?? 0) / totalBlocks * 100)
    let hiType = clipAny == 0 ? "none" : (largestHi >= 0.15 ? "area" : "specular")

    // Overlay: red = highlights clipped, blue = pure black. Faint = partially clipped block.
    var ov = [UInt8](repeating: 0, count: bw * bh * 4)
    let tenth = Int32(block * block / 10)
    for i in 0..<(bw * bh) {
        let o = i * 4
        if hiBlock[i] > tenth {
            let a: UInt8 = hiBlock[i] > half ? 230 : 110
            ov[o] = a; ov[o + 1] = UInt8(Int(a) * 15 / 100); ov[o + 2] = UInt8(Int(a) * 15 / 100); ov[o + 3] = a
        } else if loBlock[i] > tenth {
            let a: UInt8 = loBlock[i] > half ? 230 : 110
            ov[o] = UInt8(Int(a) * 15 / 100); ov[o + 1] = UInt8(Int(a) * 45 / 100); ov[o + 2] = a; ov[o + 3] = a
        }
    }

    let key = medianL >= 70 ? "high-key" : (medianL <= 30 ? "low-key" : "normal")

    let report = ToneReport(
        histogram: Histograms(r: hr, g: hg, b: hb, l: hl),
        evFromMiddleGrey: round2(ev),
        medianLstar: round1(medianL),
        lstarP1: round1(lp(0.01)),
        lstarP99: round1(lp(0.99)),
        tonalRangeStops: round1(log2(hi / lo)),
        zones: zones.map { round2($0 / N * 100) },
        key: key,
        globalContrast: round1(stdL),
        localContrast: round2(localC),
        highlightClipAny: pct(clipAny),
        highlightClipAll: pct(clipAll),
        highlightClipChannels: clipC.map(pct),
        shadowClip: pct(shadowAll),
        shadowClipChannels: shadowC.map(pct),
        largestHighlightRegion: largestHi,
        highlightRegions: hiRegions.count,
        highlightType: hiType,
        largestShadowRegion: largestLo,
        lstarP95: round1(lp(0.95)),
        darkFraction: round2(dark / N * 100)
    )
    return (report, ClipOverlay(width: bw, height: bh, rgba: ov))
}

/// Sizes (in cells) of 4-connected true regions.
func regions(_ mask: [Bool], w: Int, h: Int) -> [Int] {
    var seen = [Bool](repeating: false, count: mask.count)
    var sizes: [Int] = []
    var stack: [Int] = []
    for start in 0..<mask.count where mask[start] && !seen[start] {
        var size = 0
        stack.append(start); seen[start] = true
        while let i = stack.popLast() {
            size += 1
            let x = i % w, y = i / w
            if x > 0, mask[i - 1], !seen[i - 1] { seen[i - 1] = true; stack.append(i - 1) }
            if x < w - 1, mask[i + 1], !seen[i + 1] { seen[i + 1] = true; stack.append(i + 1) }
            if y > 0, mask[i - w], !seen[i - w] { seen[i - w] = true; stack.append(i - w) }
            if y < h - 1, mask[i + w], !seen[i + w] { seen[i + w] = true; stack.append(i + w) }
        }
        sizes.append(size)
    }
    return sizes
}

func localContrast(_ lab: [Lab], w: Int, h: Int, radius r: Int) -> Double {
    // Integral image of L*.
    var integ = [Double](repeating: 0, count: (w + 1) * (h + 1))
    for y in 0..<h {
        var row = 0.0
        for x in 0..<w {
            row += Double(lab[y * w + x].L)
            integ[(y + 1) * (w + 1) + x + 1] = integ[y * (w + 1) + x + 1] + row
        }
    }
    var total = 0.0
    for y in 0..<h {
        let y0 = max(0, y - r), y1 = min(h, y + r + 1)
        for x in 0..<w {
            let x0 = max(0, x - r), x1 = min(w, x + r + 1)
            let s = integ[y1 * (w + 1) + x1] - integ[y0 * (w + 1) + x1] - integ[y1 * (w + 1) + x0] + integ[y0 * (w + 1) + x0]
            let mean = s / Double((x1 - x0) * (y1 - y0))
            total += abs(Double(lab[y * w + x].L) - mean)
        }
    }
    return total / Double(w * h)
}
