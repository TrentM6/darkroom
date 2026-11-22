import Foundation

// My Look + per-photo matching.
//
//   per-photo params = resolve(My Look, auto corrections, Look Amount) overlaid with manual overrides
//
// * My Look (library-level): the look-defining values only (film, film amount, contrast, blacks,
//   punch, vibrance, saturation, warmth, tint, vignette, sharpen).
// * Auto corrections (per photo, from analysis): absolute exposure / highlights / shadows / straighten,
//   plus small look-relative adaptations (flat frame -> a bit more contrast, already-warm frame -> a
//   bit less warmth, low light -> Kodachrome 200, the camera recipe, ...). A project pass nudges
//   exposure and warmth toward the project median.
// * Look Amount (per photo, 0...150 %) scales the adapted look-defining values relative to neutral (0).
// * Manual overrides: sparse; a photo is "edited" when it has any, or a Look Amount other than 100.
//
// With the default look and Look Amount 100 %, resolve() reproduces `recommendParams` (the original
// Kodachrome recipe) except for the project-consistency nudges.

public let lookKeys = ["film", "filmStrength", "contrast", "blacks", "punch", "vibrance", "saturation", "warmth", "tint", "vignette", "sharpen", "grain", "grainSize"]
public let numericParamKeys = ["exposure", "contrast", "highlights", "shadows", "blacks", "punch", "vibrance", "saturation", "warmth", "tint", "filmStrength", "vignette", "rotate", "sharpen", "grain",
                                "shadowWarmth", "shadowTint", "highlightWarmth", "highlightTint"]
let scaledLookKeys = ["filmStrength", "contrast", "blacks", "punch", "vibrance", "saturation", "warmth", "tint", "vignette", "sharpen", "grain"]

extension EditParams {
    subscript(num key: String) -> Double {
        get {
            switch key {
            case "exposure": return exposure
            case "contrast": return contrast
            case "highlights": return highlights
            case "shadows": return shadows
            case "blacks": return blacks
            case "punch": return punch
            case "vibrance": return vibrance
            case "saturation": return saturation
            case "warmth": return warmth
            case "tint": return tint
            case "filmStrength": return filmStrength
            case "vignette": return vignette
            case "rotate": return rotate
            case "sharpen": return sharpen
            case "grain": return grain
            case "shadowWarmth": return shadowWarmth
            case "shadowTint": return shadowTint
            case "highlightWarmth": return highlightWarmth
            case "highlightTint": return highlightTint
            default: return 0
            }
        }
        set {
            switch key {
            case "grain": grain = newValue
            case "shadowWarmth": shadowWarmth = newValue
            case "shadowTint": shadowTint = newValue
            case "highlightWarmth": highlightWarmth = newValue
            case "highlightTint": highlightTint = newValue
            case "exposure": exposure = newValue
            case "contrast": contrast = newValue
            case "highlights": highlights = newValue
            case "shadows": shadows = newValue
            case "blacks": blacks = newValue
            case "punch": punch = newValue
            case "vibrance": vibrance = newValue
            case "saturation": saturation = newValue
            case "warmth": warmth = newValue
            case "tint": tint = newValue
            case "filmStrength": filmStrength = newValue
            case "vignette": vignette = newValue
            case "rotate": rotate = newValue
            case "sharpen": sharpen = newValue
            default: break
            }
        }
    }
}

/// My Look.
public struct LookParams: Codable, Equatable {
    public var film: String = "Kodak/Kodak Kodachrome 64.png"
    public var filmStrength: Double = 72
    // Toned down 2026-11-09 ("a teeny bit too punchy, blacks a little too dark — keep the grit"), checked
    // by eye on 12 frames and against the panel critique: contrast 45→34, blacks -6→+5, punch 45→20,
    // vibrance 24→6, saturation 10→2, vignette 25→6 (film, film amount, warmth, tint, sharpen, grain unchanged).
    public var contrast: Double = 34
    public var blacks: Double = 5
    public var punch: Double = 20
    public var vibrance: Double = 6
    public var saturation: Double = 2
    public var warmth: Double = 10
    public var tint: Double = -6
    public var vignette: Double = 6
    public var sharpen: Double = 0
    public var grain: Double = 0
    public var grainSize: String = "fine"

    /// The Kodachrome street recipe's look-defining values (the middle of each of its adaptive buckets).
    public static let kodachrome = LookParams()
    public init() {}

    enum CodingKeys: String, CodingKey { case film, filmStrength, contrast, blacks, punch, vibrance, saturation, warmth, tint, vignette, sharpen, grain, grainSize }
    public init(from decoder: Decoder) throws {
        self = LookParams.kodachrome
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ k: CodingKeys) -> Double? {
            if let v = try? c.decodeIfPresent(Double.self, forKey: k) { return v }
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return Double(s) }
            return nil
        }
        if let v = try? c.decodeIfPresent(String.self, forKey: .film) { film = v }
        filmStrength = d(.filmStrength) ?? filmStrength; contrast = d(.contrast) ?? contrast; blacks = d(.blacks) ?? blacks
        punch = d(.punch) ?? punch; vibrance = d(.vibrance) ?? vibrance; saturation = d(.saturation) ?? saturation
        warmth = d(.warmth) ?? warmth; tint = d(.tint) ?? tint; vignette = d(.vignette) ?? vignette; sharpen = d(.sharpen) ?? sharpen
        grain = d(.grain) ?? grain
        if let g = try? c.decodeIfPresent(String.self, forKey: .grainSize) { grainSize = g }
    }

    /// Same ranges/steps as EditParams.
    public func clamped(lutRoot: URL?) -> LookParams {
        var e = EditParams()
        for k in scaledLookKeys { e[num: k] = self[k] }
        e.film = film
        e.grainSize = grainSize
        e = e.clamped(lutRoot: lutRoot)
        var l = self
        for k in scaledLookKeys { l[k] = e[num: k] }
        l.film = e.film
        l.grainSize = e.grainSize
        return l
    }

    subscript(_ key: String) -> Double {
        get {
            switch key {
            case "filmStrength": return filmStrength
            case "contrast": return contrast
            case "blacks": return blacks
            case "punch": return punch
            case "vibrance": return vibrance
            case "saturation": return saturation
            case "warmth": return warmth
            case "tint": return tint
            case "vignette": return vignette
            case "sharpen": return sharpen
            case "grain": return grain
            default: return 0
            }
        }
        set {
            switch key {
            case "grain": grain = newValue
            case "filmStrength": filmStrength = newValue
            case "contrast": contrast = newValue
            case "blacks": blacks = newValue
            case "punch": punch = newValue
            case "vibrance": vibrance = newValue
            case "saturation": saturation = newValue
            case "warmth": warmth = newValue
            case "tint": tint = newValue
            case "vignette": vignette = newValue
            case "sharpen": sharpen = newValue
            default: break
            }
        }
    }
}

/// Low-light variants: the same stock family with more forgiveness in the shadows.
let lowLightFilm: [String: String] = ["Kodak/Kodak Kodachrome 64.png": "Kodak/Kodak Kodachrome 200.png"]

/// Per-photo corrections derived from analysis. Stored in project.json so look changes never need
/// the analysis again. All values in slider units.
public struct AutoCorrections: Codable, Equatable {
    // absolute
    public var exposure: Double = 0
    public var highlights: Double = 15
    public var shadows: Double = 0
    public var rotate: Double = 0
    // look-relative
    public var contrastDelta: Double = 0      // from measured global contrast
    public var recipeContrast: Double = 0     // from the camera recipe (tone settings, film simulation)
    public var blacksFactor: Double = 1       // scales a negative (crushing) look blacks
    public var punchDelta: Double = 0
    public var vibranceDelta: Double = 0
    public var vibranceCap: Bool = false      // colours already at the sRGB edge
    public var saturationDelta: Double = 0
    public var saturationCap: Bool = false
    public var warmthDelta: Double = 0        // frame already warm
    public var warmthNudge: Double = 0        // project consistency
    public var vignetteDelta: Double = 0
    public var sharpenAdd: Double = 0
    public var lowLight: Bool = false
    public var monochrome: Bool = false
    /// Saturated-red protection, 0...2, raised when the rendered result clips saturated reds (> 1.5%).
    public var redGuard: Int = 0
    /// Bounded corrections solved toward My Look's learned targets (StudioLearn.swift).
    public var fit: FitAdjust? = nil
    // inputs kept for the project pass
    public var evRaw: Double = 0
    public var highlightsBase: Double = 15
    public var highlightsAtRisk: Bool = false
    public var medianL: Double = 50
    public var key: String = "normal"
    public var measuredWarmth: Double = 0
    public init() {}
}

enum StudioLook {
    /// Per-photo corrections (before the project pass). Mirrors `recommendParams`.
    static func corrections(_ f: PhotoFacts) -> AutoCorrections {
        var c = AutoCorrections()
        c.medianL = f.medianL; c.key = f.key; c.measuredWarmth = f.warmth

        c.lowLight = f.iso >= 1600 || (f.iso >= 800 && f.exposureTime >= 1.0 / 30)

        // Straighten only clear, confident tilts; beyond 5° it's likely a deliberate cant.
        if let tilt = f.tilt, abs(tilt) >= 1.5, abs(tilt) <= 5, f.tiltConfidence >= 0.4 { c.rotate = (tilt * 10).rounded() / 10 }

        let target: Double = f.key == "low-key" ? 40 : f.key == "high-key" ? max(f.medianL, 62) : 56
        var ev = (target - f.medianL) / 15 + 0.1
        ev = min(0.6, max(-0.15, ev))
        c.highlightsAtRisk = f.highlightClipAny > 1 || f.largestHighlightRegion > 0.2
        if c.highlightsAtRisk { ev = min(ev, 0.2) }
        c.evRaw = (ev * 20).rounded() / 20
        c.exposure = c.evRaw

        var hl = 15.0
        if f.highlightClipAny > 0.5 { hl += 20 }
        if f.highlightClipAny > 2 { hl += 15 }
        if f.largestHighlightRegion > 0.5 { hl += 15 }
        c.highlightsBase = hl
        c.highlights = hl + (c.exposure >= 0.3 ? 10 : 0)

        if f.key != "high-key" && f.medianL < 36 && f.shadowClip < 3 { c.shadows = 15 }

        let gc = f.globalContrast
        c.contrastDelta = gc < 22 ? 10 : gc < 28 ? 0 : -10
        c.blacksFactor = f.shadowClip > 10 ? 0 : f.shadowClip > 2 ? 0.5 : 1
        let lc = f.localContrast
        c.punchDelta = lc < 3 ? 10 : lc < 5 ? 0 : lc < 7 ? -10 : -17
        let mc = f.meanChroma
        c.vibranceDelta = mc < 10 ? 6 : mc < 16 ? 0 : -8
        c.saturationDelta = mc < 10 ? 2 : mc < 16 ? 0 : -4
        if f.saturationClip > 0.5 { c.vibranceCap = true; c.saturationCap = true }
        c.warmthDelta = f.warmth > 4 ? -4 : 0
        c.vignetteDelta = f.brightEdges ? 20 : 0
        // Soft frames get a light deconvolution: frame width above "sharp" (3.85 px); older analyses
        // without it used the sharpest tile (> 1.7 px).
        if let fw = f.frameWidth { if fw > 3.85 { c.sharpenAdd = 35 } }
        else if let w = f.bestEdgeWidth, w > 1.7 { c.sharpenAdd = 35 }

        // Recipe-aware (Fuji maker notes): the reference is the photographer's Classic Negative,
        // H-2 S-1, Color +1. A softer in-camera tone gets more contrast, a harder one less; punchier
        // film simulations get less added colour, flatter ones more.
        let tone = f.highlightTone + f.shadowTone
        c.recipeContrast = tone <= -2 ? 10 : tone >= 2 ? -8 : 0
        if let sim = f.filmSimulation?.lowercased() {
            if ["acros", "monochrome", "sepia", "b&w"].contains(where: { sim.contains($0) }) {
                c.monochrome = true
            } else if sim.contains("velvia") {
                c.vibranceDelta -= 12; c.saturationDelta -= 8; c.recipeContrast -= 5
            } else if sim.contains("provia") || sim.contains("standard") {
                c.vibranceDelta -= 6; c.saturationDelta -= 4
            } else if sim.contains("astia") || sim.contains("soft") {
                c.vibranceDelta -= 2; c.saturationDelta -= 2; c.recipeContrast += 5
            } else if sim.contains("classic chrome") {
                c.vibranceDelta += 4
            } else if sim.contains("bleach") {
                c.vibranceDelta += 6; c.recipeContrast -= 5
            } else if sim.contains("eterna") {
                c.vibranceDelta += 8; c.saturationDelta += 4; c.recipeContrast += 10
            } else if sim.contains("pro neg") {
                c.vibranceDelta += 4; c.recipeContrast += 5
            } else if sim.contains("reala") {
                c.vibranceDelta -= 4
            }
            if let col = f.colorSetting { c.saturationDelta += (1 - col) * 3 }
        }
        return c
    }

    /// Project consistency: nudge auto exposure and warmth so frames of one shoot match.
    /// * Exposure: each normal-key frame's predicted result brightness (median L* + 15 x EV) moves 25%
    ///   toward the project median (only frames held back by the recipe's limits actually move).
    ///   Low-key and high-key frames are left alone (intent).
    /// * Warmth: each frame's predicted result b* moves 25% toward the project median, at most 5 units.
    static func projectPass(_ cs: inout [AutoCorrections]) {
        func median(_ v: [Double]) -> Double? { percentile(v, 0.5) }
        let normal = cs.indices.filter { cs[$0].key == "normal" }
        let results = normal.map { cs[$0].medianL + 15 * cs[$0].evRaw }
        let R = normal.count >= 3 ? median(results) : nil
        for i in cs.indices {
            var ev = cs[i].evRaw
            if let R, cs[i].key == "normal" {
                let r = cs[i].medianL + 15 * cs[i].evRaw
                ev += 0.25 * (R - r) / 15
                ev = min(0.8, max(-0.3, ev))
                if cs[i].highlightsAtRisk { ev = min(ev, max(cs[i].evRaw, 0.2)) }
            }
            cs[i].exposure = (ev * 20).rounded() / 20 + 0
            cs[i].highlights = cs[i].highlightsBase + (cs[i].exposure >= 0.3 ? 10 : 0)
        }
        let colour = cs.indices.filter { !cs[$0].monochrome }
        let bs = colour.map { cs[$0].measuredWarmth + cs[$0].warmthDelta * 0.3 }
        let B = colour.count >= 3 ? median(bs) : nil
        for i in cs.indices {
            guard let B, !cs[i].monochrome else { cs[i].warmthNudge = 0; continue }
            let b = cs[i].measuredWarmth + cs[i].warmthDelta * 0.3
            cs[i].warmthNudge = min(5, max(-5, (0.25 * (B - b) / 0.3).rounded())) + 0
        }
    }

    /// Look + auto corrections at a Look Amount (percent). Clamped/quantized.
    static func resolve(_ look: LookParams, _ c: AutoCorrections, amount: Double, lutRoot: URL?) -> EditParams {
        var e = EditParams()
        e.exposure = c.exposure; e.highlights = c.highlights; e.shadows = c.shadows; e.rotate = c.rotate
        var v: [String: Double] = [:]
        let fit = c.fit ?? FitAdjust()
        e.exposure += fit.ev
        e.highlights += fit.highlights
        v["contrast"] = look.contrast + c.contrastDelta + c.recipeContrast + fit.contrast
        v["blacks"] = (look.blacks < 0 ? look.blacks * c.blacksFactor : look.blacks) + fit.blacks
        v["punch"] = look.punch + c.punchDelta
        var vib = look.vibrance + c.vibranceDelta + fit.vibrance
        if c.vibranceCap { vib = min(vib, look.vibrance * 0.5) }
        v["vibrance"] = vib
        var sat = look.saturation + c.saturationDelta
        if c.saturationCap { sat = min(sat, 0) }
        v["saturation"] = sat
        v["warmth"] = look.warmth + c.warmthDelta + c.warmthNudge + fit.warmth
        v["tint"] = look.tint + fit.tint
        v["vignette"] = look.vignette + c.vignetteDelta
        v["sharpen"] = look.sharpen + c.sharpenAdd
        v["grain"] = look.grain
        var film = look.film, strength = look.filmStrength
        if c.lowLight, let alt = lowLightFilm[film] { film = alt; strength -= 2 }
        v["filmStrength"] = strength
        if c.monochrome {
            film = ""; v["filmStrength"] = 0; v["vibrance"] = 0; v["saturation"] = 0; v["warmth"] = 0; v["tint"] = 0
        }
        let k = max(0, min(150, amount)) / 100
        for key in scaledLookKeys { e[num: key] = (v[key] ?? 0) * k }
        e.film = film
        e.grainSize = look.grainSize
        // Red guard: less exposure and a chroma reduction for frames whose saturated reds clip.
        let g = max(0, min(2, c.redGuard))
        e.exposure -= [0, 0.15, 0.3][g]
        e.chromaGuard = [0, -10, -18][g]
        return e.clamped(lutRoot: lutRoot)
    }

    /// "Make This My Look": the look that, through this photo's corrections and Look Amount, gives
    /// these look-defining values. Keeps `current` for values that can't be inverted (capped, zeroed).
    static func lookFrom(_ p: EditParams, _ c: AutoCorrections, amount: Double, current: LookParams, lutRoot: URL?) -> LookParams {
        var l = current
        let k = max(0, min(150, amount)) / 100
        guard k > 0.001 else { return current }
        func base(_ key: String) -> Double { p[num: key] / k }
        l.contrast = base("contrast") - c.contrastDelta - c.recipeContrast
        l.punch = base("punch") - c.punchDelta
        l.vignette = base("vignette") - c.vignetteDelta
        l.sharpen = max(0, base("sharpen") - c.sharpenAdd)
        l.grain = base("grain")
        l.grainSize = p.grainSize
        if !c.monochrome {
            l.tint = base("tint")
            l.warmth = base("warmth") - c.warmthDelta - c.warmthNudge
            if !c.vibranceCap { l.vibrance = base("vibrance") - c.vibranceDelta }
            if !c.saturationCap { l.saturation = base("saturation") - c.saturationDelta }
            var film = p.film, strength = base("filmStrength")
            if c.lowLight, let orig = lowLightFilm.first(where: { $0.value == film })?.key { film = orig; strength += 2 }
            l.film = film; l.filmStrength = strength
        }
        let b = base("blacks")
        if b >= 0 { l.blacks = b } else if c.blacksFactor > 0.001 { l.blacks = b / c.blacksFactor }
        return l.clamped(lutRoot: lutRoot)
    }

    /// Centered, largest crop of `ratio` (W/H in pixels) in a `w` x `h` image.
    static func centeredCrop(ratio: Double, width: Int, height: Int, aspect: String) -> CropRect {
        let W = Double(width), H = Double(height)
        var cw = W, ch = W / ratio
        if ch > H { ch = H; cw = H * ratio }
        return CropRect(aspect: aspect, x: (W - cw) / 2 / W, y: (H - ch) / 2 / H, w: cw / W, h: ch / H)
    }

    /// Validates a crop against the image: a ratio label with no usable rectangle gets the centered
    /// crop (ratio applied in the image's orientation: "3:2" on a portrait photo is 2:3); a rectangle
    /// whose pixel ratio is off by more than 1% from the label (either orientation) is corrected
    /// around its centre.
    static func normalizeCrop(_ crop: CropRect?, width: Int, height: Int, rectGiven: Bool) -> CropRect? {
        guard var c = crop?.clamped() else { return nil }
        guard width > 0, height > 0 else { return c }
        if let r0 = c.ratio {
            let portrait = height > width
            if !rectGiven {
                let r = portrait ? min(r0, 1 / r0) : max(r0, 1 / r0)
                return CropRect.clampedOrSelf(centeredCrop(ratio: r, width: width, height: height, aspect: c.aspect))
            }
            let pr = (c.w * Double(width)) / (c.h * Double(height))
            let candidates = [r0, 1 / r0]
            let best = candidates.min(by: { abs(log(pr / $0)) < abs(log(pr / $1)) })!
            if abs(pr / best - 1) > 0.01 {
                // keep the width, fix the height (or the reverse if it no longer fits)
                let cx = c.x + c.w / 2, cy = c.y + c.h / 2
                var nw = c.w, nh = c.w * Double(width) / best / Double(height)
                if nh > 1 { nh = 1; nw = Double(height) * best / Double(width) }
                c.w = nw; c.h = nh
                c.x = min(1 - nw, max(0, cx - nw / 2)); c.y = min(1 - nh, max(0, cy - nh / 2))
                return CropRect.clampedOrSelf(c)
            }
        }
        return c
    }
}

extension CropRect {
    static func clampedOrSelf(_ c: CropRect) -> CropRect { c.clamped() ?? c }
}

/// Sparse manual adjustments on top of the auto params.
public struct ManualOverrides: Codable, Equatable {
    public var values: [String: Double] = [:]
    public var film: String? = nil
    public var grainSize: String? = nil
    public var crop: CropRect? = nil       // auto never crops, so any crop is manual
    public init() {}
    public var isEmpty: Bool { values.isEmpty && film == nil && grainSize == nil && crop == nil }

    func apply(to auto: EditParams) -> EditParams {
        var e = auto
        for (k, v) in values { e[num: k] = v }
        if let film { e.film = film }
        if let grainSize { e.grainSize = grainSize }
        e.crop = crop
        return e
    }

    /// The overrides that turn `auto` into `params`.
    static func diff(_ params: EditParams, from auto: EditParams) -> ManualOverrides {
        var m = ManualOverrides()
        for k in numericParamKeys where params[num: k] != auto[num: k] { m.values[k] = params[num: k] }
        if params.film != auto.film { m.film = params.film }
        if params.grainSize != auto.grainSize { m.grainSize = params.grainSize }
        m.crop = params.crop
        return m
    }

    /// Drops the look-defining overrides (My Look applied to "all").
    mutating func dropLook() {
        for k in lookKeys { values.removeValue(forKey: k) }
        film = nil
        grainSize = nil
    }
}
