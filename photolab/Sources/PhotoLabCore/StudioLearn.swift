import Foundation
import ImageIO

// My Look learns from Best Work (favorites).
//
// * Learned look params: each favorite's final params are taken back to "look space" (its per-photo
//   adaptations and Look Amount removed, as "Make This My Look" does), then a recency-weighted median per
//   numeric value (half-life 90 days, relative to the newest favorite, so the result doesn't depend on
//   today's date) and a weighted mode for film and grain size.
// * Learned targets: measured on the favorites' current renders (512 px): median / p1 / p5 / p95 / p99 L*,
//   mean chroma, mid-tone a*/b*, shadow a*/b*, local contrast; the median across favorites and its spread.
// * Below 5 favorites both blend from the starter look / generic targets in proportion n/5.
// * Per photo (unedited only): after a background render, the render is measured and bounded corrections
//   are solved toward the targets (exposure, contrast, blacks, highlights, warmth, tint, vibrance), scaled
//   by min(1, n/5); then it is rendered again. Once per target set. Deterministic.
// * Pinned: learning doesn't change the look or the targets.

public struct LookTargets: Codable, Equatable {
    public var medianL: Double = 50
    public var p1: Double = 5
    public var p5: Double = 12
    public var p95: Double = 88
    public var p99: Double = 96
    public var chroma: Double = 24
    public var midA: Double = 1
    public var midB: Double = 5
    public var shadowA: Double = 0
    public var shadowB: Double = 0
    public var localContrast: Double = 6
    public var spread: [String: Double] = [:]
    public init() {}
    public static let generic = LookTargets()

    static let keys = ["medianL", "p1", "p5", "p95", "p99", "chroma", "midA", "midB", "shadowA", "shadowB", "localContrast"]
    subscript(_ k: String) -> Double {
        get {
            switch k {
            case "medianL": return medianL
            case "p1": return p1
            case "p5": return p5
            case "p95": return p95
            case "p99": return p99
            case "chroma": return chroma
            case "midA": return midA
            case "midB": return midB
            case "shadowA": return shadowA
            case "shadowB": return shadowB
            default: return localContrast
            }
        }
        set {
            switch k {
            case "medianL": medianL = newValue
            case "p1": p1 = newValue
            case "p5": p5 = newValue
            case "p95": p95 = newValue
            case "p99": p99 = newValue
            case "chroma": chroma = newValue
            case "midA": midA = newValue
            case "midB": midB = newValue
            case "shadowA": shadowA = newValue
            case "shadowB": shadowB = newValue
            default: localContrast = newValue
            }
        }
    }
    var hash: String {
        var h: UInt64 = 0xcbf29ce484222325
        for k in Self.keys { for b in String(format: "%@=%.1f;", k, self[k]).utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 } }
        return String(h, radix: 16)
    }
}

public struct LearnedLook: Codable, Equatable {
    public var params: LookParams          // what learning suggests (blended with the starter below 5 favorites)
    public var targets: LookTargets
    public var favorites: Int
    public var measured: Int               // favorites with an up-to-date render (used for targets)
    public var blend: Double               // min(1, n/5)
    public var updatedAt: String
}

/// Per-photo fit toward the targets (slider units), stored with the auto corrections.
public struct FitAdjust: Codable, Equatable {
    public var ev: Double = 0
    public var contrast: Double = 0
    public var blacks: Double = 0
    public var highlights: Double = 0
    public var warmth: Double = 0
    public var tint: Double = 0
    public var vibrance: Double = 0
    public var target: String = ""         // targets hash it was solved for
    public var iter: Int = 0               // measured steps taken for this target set (max 3)
    public init() {}
}

/// Measured qualities of a rendered image (sRGB JPEG).
struct RenderStats {
    var medianL = 0.0, p1 = 0.0, p5 = 0.0, p95 = 0.0, p99 = 0.0
    var chroma = 0.0, midA = 0.0, midB = 0.0, shadowA = 0.0, shadowB = 0.0, localContrast = 0.0
    var satRedClip = 0.0
    var strongPct = 0.0          // % of non-sky pixels with chroma > 40
    var accent: String? = nil    // hue family of a small, very saturated patch (0.4-5% of the frame, chroma > 55)

    subscript(_ k: String) -> Double {
        switch k {
        case "medianL": return medianL
        case "p1": return p1
        case "p5": return p5
        case "p95": return p95
        case "p99": return p99
        case "chroma": return chroma
        case "midA": return midA
        case "midB": return midB
        case "shadowA": return shadowA
        case "shadowB": return shadowB
        default: return localContrast
        }
    }

    static func measure(_ url: URL) -> RenderStats? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = Pixels.load(src, maxPixel: 512) else { return nil }
        let px = Pixels.rgba(img)
        let n = px.width * px.height
        guard n > 0 else { return nil }
        var L = [Float](repeating: 0, count: n)
        var chroma = 0.0, midA = 0.0, midB = 0.0, midN = 0.0, shA = 0.0, shB = 0.0, shN = 0.0, red = 0
        var strong = 0, nonSky = 0, vivid = 0
        var hueBins = [Int](repeating: 0, count: 8)   // red orange yellow green teal blue purple pink
        for i in 0..<n {
            let r = px.data[i * 4], g = px.data[i * 4 + 1], b = px.data[i * 4 + 2]
            if r >= 254 && g < 200 { red += 1 }
            let lab = ColorMath.lab(r: r, g: g, b: b)
            L[i] = lab.L
            chroma += Double(sqrtf(lab.a * lab.a + lab.b * lab.b))
            if lab.L >= 30 && lab.L <= 70 { midA += Double(lab.a); midB += Double(lab.b); midN += 1 }
            if lab.L < 25 { shA += Double(lab.a); shB += Double(lab.b); shN += 1 }
            let c = sqrtf(lab.a * lab.a + lab.b * lab.b)
            var hue = atan2f(lab.b, lab.a) * 180 / .pi; if hue < 0 { hue += 360 }
            let sky = hue > 200 && hue < 290 && lab.L > 45
            if !sky { nonSky += 1; if c > 40 { strong += 1 } }
            if c > 55 && !sky {
                let bin = hue < 45 || hue >= 345 ? 0 : hue < 70 ? 1 : hue < 105 ? 2 : hue < 165 ? 3 : hue < 215 ? 4 : hue < 290 ? 5 : hue < 320 ? 6 : 7
                // orange needs more: tanned, sunlit skin reaches chroma 55-65 under the look
                if bin != 1 || c > 68 { vivid += 1; hueBins[bin] += 1 }
            }
        }
        var s = RenderStats()
        let sorted = L.sorted()
        func pct(_ p: Double) -> Double { Double(sorted[min(n - 1, Int(p * Double(n - 1)))]) }
        s.medianL = pct(0.5); s.p1 = pct(0.01); s.p5 = pct(0.05); s.p95 = pct(0.95); s.p99 = pct(0.99)
        s.chroma = chroma / Double(n)
        s.midA = midN > 0 ? midA / midN : 0; s.midB = midN > 0 ? midB / midN : 0
        s.shadowA = shN > 0 ? shA / shN : 0; s.shadowB = shN > 0 ? shB / shN : 0
        // local contrast: mean |L - box blur(L, 7x7)|
        let w = px.width, h = px.height, r = 3
        var tmp = [Float](repeating: 0, count: n), blur = [Float](repeating: 0, count: n)
        for y in 0..<h { for x in 0..<w { var a: Float = 0; var c: Float = 0
            for dx in -r...r { let xx = x + dx; if xx >= 0 && xx < w { a += L[y * w + xx]; c += 1 } }
            tmp[y * w + x] = a / c } }
        for y in 0..<h { for x in 0..<w { var a: Float = 0; var c: Float = 0
            for dy in -r...r { let yy = y + dy; if yy >= 0 && yy < h { a += tmp[yy * w + x]; c += 1 } }
            blur[y * w + x] = a / c } }
        var lc = 0.0
        for i in 0..<n { lc += Double(abs(L[i] - blur[i])) }
        s.localContrast = lc / Double(n)
        s.satRedClip = Double(red) / Double(n) * 100
        s.strongPct = Double(strong) / Double(max(1, nonSky)) * 100
        let vividPct = Double(vivid) / Double(n) * 100
        if vividPct >= 0.4 && vividPct <= 5, let top = hueBins.enumerated().max(by: { $0.element < $1.element }), Double(top.element) >= 0.6 * Double(vivid) {
            s.accent = ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"][top.offset]
        }
        return s
    }
}

extension Studio {
    static let learnHalfLifeDays = 90.0

    /// Weighted median (deterministic: ties by value).
    static func weightedMedian(_ v: [(Double, Double)]) -> Double? {
        let s = v.filter { $0.1 > 0 }.sorted { $0.0 < $1.0 }
        let total = s.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        var acc = 0.0
        for (x, w) in s { acc += w; if acc >= total / 2 - 1e-9 { return x } }
        return s.last?.0
    }

    static func weightedMode(_ v: [(String, Double)]) -> String? {
        var m: [String: Double] = [:]
        for (k, w) in v { m[k, default: 0] += w }
        return m.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// Learns look params and targets from the current favorites. Doesn't apply anything.
    func computeLearned() -> LearnedLook {
        let starter = starterLook
        let favs: [(PhotoEntry, String)] = sync {
            bestItems().compactMap { r in photoIndex(r.projectId, r.id).flatMap { i in projects[r.projectId]?.photos[i] }.map { ($0, r.projectId) } }
        }
        let n = favs.count
        let blend = min(1, Double(n) / 5)
        let newest = favs.compactMap { $0.0.timestamp }.max() ?? 0
        func weight(_ ph: PhotoEntry) -> Double {
            guard let t = ph.timestamp, newest > 0 else { return 1 }
            return pow(0.5, max(0, newest - t) / 86400 / Self.learnHalfLifeDays)
        }
        // Each favorite's look, back in look space (starter as the reference for values that can't be inverted).
        let looks: [(LookParams, Double)] = favs.map { (ph, _) in
            (StudioLook.lookFrom(ph.params, ph.corrections, amount: ph.lookAmount, current: starter, lutRoot: lutRoot), weight(ph))
        }
        var learned = starter
        if !looks.isEmpty {
            for k in scaledLookKeys {
                if let m = Self.weightedMedian(looks.map { ($0.0[k], $0.1) }) { learned[k] = m }
            }
            learned.film = Self.weightedMode(looks.map { ($0.0.film, $0.1) }) ?? starter.film
            learned.grainSize = Self.weightedMode(looks.map { ($0.0.grainSize, $0.1) }) ?? starter.grainSize
        }
        // Blend with the starter below 5 favorites (strings switch once the learned side outweighs).
        var params = starter
        for k in scaledLookKeys { params[k] = starter[k] + (learned[k] - starter[k]) * blend }
        params.film = blend >= 0.5 ? learned.film : starter.film
        params.grainSize = blend >= 0.5 ? learned.grainSize : starter.grainSize
        params = params.clamped(lutRoot: lutRoot)

        // Targets from favorites whose render matches their current params.
        var stats: [(RenderStats, Double)] = []
        for (ph, pid) in favs {
            let url = engine(pid).previewURL(ph.ref)
            guard ph.rendered, ph.renderedParams == nil || ph.renderedParams == ph.params, let s = RenderStats.measure(url) else { continue }
            stats.append((s, weight(ph)))
        }
        var t = LookTargets.generic
        if !stats.isEmpty {
            var spread: [String: Double] = [:]
            for k in LookTargets.keys {
                let vals = stats.map { ($0.0[k], $0.1) }
                let med = Self.weightedMedian(vals) ?? LookTargets.generic[k]
                let mad = Self.weightedMedian(vals.map { (abs($0.0 - med), $0.1) }) ?? 0
                t[k] = (LookTargets.generic[k] + (med - LookTargets.generic[k]) * blend).roundedHalf
                spread[k] = max(1, mad * 1.4826).roundedHalf
            }
            t.spread = spread
        }
        return LearnedLook(params: params, targets: t, favorites: n, measured: stats.count, blend: blend, updatedAt: Store.iso())
    }

    /// Debounced (10 s) relearn after Best Work changes.
    /// Learning the look params from Best Work: on (PHOTOLAB_LEARN=0 turns it off).
    static var learningEnabled: Bool { ProcessInfo.processInfo.environment["PHOTOLAB_LEARN"] != "0" }
    /// The per-photo fit toward the learned targets: off until validated (PHOTOLAB_LEARN_FIT=1 turns it on).
    static var fitEnabled: Bool { ProcessInfo.processInfo.environment["PHOTOLAB_LEARN_FIT"] == "1" }

    func scheduleRelearn() {
        guard Self.learningEnabled else { return }
        let token: Int = sync { relearnToken += 1; return relearnToken }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.sync({ self.relearnToken == token }) else { return }
            self.relearn()
        }
    }

    /// Recomputes the learned look; unless pinned, applies it (unedited photos follow, low priority).
    @discardableResult
    public func relearn() -> LearnedLook {
        let l = computeLearned()
        let (pinned, oldLook, oldTargets): (Bool, LookParams, String) = sync { (lib.lookPinned, lib.look, lib.learned?.targets.hash ?? "") }
        sync { lib.learned = l; markDirty("") }
        guard !pinned else { return l }
        if l.params != oldLook {
            log("My Look learned from \(l.favorites) favorite(s) (blend \(String(format: "%.1f", l.blend)))")
            _ = setLook(l.params, priorityOrder: true)
        }
        if Self.fitEnabled && l.targets.hash != oldTargets && l.blend > 0 {
            // re-fit unedited photos (most recently opened projects first)
            for (pid, id) in unedited(recentFirst: true) { enqueueRender(pid, id) }
        }
        return l
    }

    func unedited(recentFirst: Bool) -> [(String, String)] {
        sync {
            let order = projects.keys.sorted { (lastOpened[$0] ?? .distantPast, $0) > (lastOpened[$1] ?? .distantPast, $1) }
            return order.flatMap { pid in (projects[pid]?.photos ?? []).filter { !$0.edited && !$0.gone && $0.analyzed }.map { (pid, $0.id) } }
        }
    }

    public func setPinned(_ pinned: Bool) {
        sync { lib.lookPinned = pinned; markDirty("") }
        if !pinned { scheduleRelearnNow() }
    }

    func scheduleRelearnNow() { DispatchQueue.global(qos: .utility).async { [weak self] in self?.relearn() } }

    public func lookJSON() -> [String: Any] {
        sync {
            let n = bestItems().count
            let source = lib.lookPinned ? "pinned" : (n >= 5 ? "learned" : "starter")
            return ["params": Self.dict(lib.look), "targets": lib.learned.map { Self.dict($0.targets) } ?? Self.dict(LookTargets.generic),
                    "source": source, "favorites": n, "pinned": lib.lookPinned,
                    "learned": lib.learned.map { Self.dict($0.params) } ?? NSNull(),
                    "blend": lib.learned?.blend ?? 0, "measured": lib.learned?.measured ?? 0,
                    "targetsHash": (lib.learned?.targets ?? LookTargets.generic).hash,
                    "updatedAt": lib.learned?.updatedAt ?? NSNull()]
        }
    }

    /// After a render of an unedited photo: solve bounded corrections toward the targets (once per target
    /// set) and the red guard. Returns true if the photo needs another render.
    func fitToTargets(_ pid: String, _ id: String, stats s: RenderStats, fit doFit: Bool = true) -> Bool {
        sync {
            guard let i = photoIndex(pid, id), projects[pid] != nil else { return false }
            var ph = projects[pid]!.photos[i]
            guard !ph.edited else { return false }
            var changed = false
            if s.satRedClip > 1.5 && ph.corrections.redGuard < 2 {
                ph.corrections.redGuard += 1
                log(String(format: "%@/%@: saturated reds clip on %.1f%% of the frame; red guard step %d", pid, id, s.satRedClip, ph.corrections.redGuard))
                changed = true
            }
            let blend = lib.lookPinned ? (lib.learned?.blend ?? 0) : (lib.learned?.blend ?? 0)
            if doFit, Self.fitEnabled, let t = lib.learned?.targets, blend > 0 {
                var f = ph.corrections.fit ?? FitAdjust()
                if f.target != t.hash { f.target = t.hash; f.iter = 0 }      // new targets: start again from the current fit
                func cl(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
                func tol(_ k: String) -> Double { max(2, t.spread[k] ?? 3) }
                let eL = t.medianL - s.medianL
                let eSpread = (t.p95 - t.p5) - (s.p95 - s.p5)
                let eP1 = s.p1 - t.p1, eP99 = s.p99 - t.p99
                let eB = t.midB - s.midB, eA = t.midA - s.midA, eC = t.chroma - s.chroma
                let converged = abs(eL) <= tol("medianL") && abs(eSpread) <= tol("p95") + tol("p5") && abs(eP1) <= tol("p1") + 1
                    && abs(eP99) <= tol("p99") + 1 && abs(eB) <= tol("midB") && abs(eA) <= tol("midA") && abs(eC) <= tol("chroma")
                if f.iter < 3 && !converged {
                    // Damped steps on the measured result (closed loop): each step uses the latest render.
                    let k = 0.7 * blend
                    var ev = cl(eL / 16 * k, -0.4, 0.4)
                    if ph.corrections.highlightsAtRisk && ev > 0 { ev = min(ev, 0.1) }
                    f.ev = cl(f.ev + ev, -0.6, 0.6)
                    f.contrast = cl(f.contrast + eSpread * 0.8 * k, -15, 15)
                    f.blacks = cl(f.blacks - eP1 * 1.2 * k, -10, 10)
                    f.highlights = cl(f.highlights + (eP99 > 1 ? eP99 * 3 : eP99 < -3 ? eP99 * 2 : 0) * k, -15, 25)
                    f.warmth = cl(f.warmth + eB / 0.3 * 0.5 * k, -8, 8)
                    f.tint = cl(f.tint + eA / 0.3 * 0.5 * k, -6, 6)
                    f.vibrance = cl(f.vibrance + eC * 1.0 * k, -15, 15)
                    f.ev = (f.ev * 20).rounded() / 20 + 0
                    for kp in [\FitAdjust.contrast, \.blacks, \.highlights, \.warmth, \.tint, \.vibrance] { f[keyPath: kp] = f[keyPath: kp].rounded() + 0 }
                    f.iter += 1
                    if f != ph.corrections.fit { ph.corrections.fit = f; changed = true }
                } else if ph.corrections.fit != f {
                    ph.corrections.fit = f
                }
            }
            guard changed else { return false }
            recompute(&ph)
            projects[pid]!.photos[i] = ph
            markDirty(pid)
            return true
        }
    }
}

extension Double {
    var roundedHalf: Double { (self * 2).rounded() / 2 }
}
