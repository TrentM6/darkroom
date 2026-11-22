import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One adjustment in a recommended edit: which control, the value, and why.
public struct EditStep: Codable {
    public var tool: String
    public var setting: String
    public var reason: String
}

/// The single source of truth for an edit, in UI-friendly units. Everything RawTherapee sees
/// (the .pp3 sidecar, preview renders, exports) is generated from this by `pp3(for:)`.
public struct EditParams: Codable, Equatable {
    public var exposure: Double = 0       // EV, -2...2
    public var contrast: Double = 0       // tone-curve S strength, 0...100
    public var highlights: Double = 0     // -100...100: + = recovery (shoulder), - = brighter highlights
    public var shadows: Double = 0        // -100...100: + = lift, - = deeper shadows
    public var blacks: Double = 0         // -50...50: negative = deeper/crushed, positive = matte
    public var punch: Double = 0          // local contrast, 0...100
    public var vibrance: Double = 0       // -100...100
    public var saturation: Double = 0     // -100...100
    public var warmth: Double = 0         // -50...50 -> b* shift
    public var tint: Double = 0           // -50...50 -> a* shift (+ = magenta)
    public var film: String = ""          // LUT path relative to the LUT root, "" = none
    public var filmStrength: Double = 0   // 0...100
    public var vignette: Double = 0       // 0...100
    public var rotate: Double = 0         // degrees, -10...10, + = counter-clockwise
    public var sharpen: Double = 0        // 0...100
    /// Crop of the straightened frame (normalized to the oriented original). nil = full frame.
    /// Encoded only when set, so params files without a crop stay byte-identical to older versions.
    public var crop: CropRect? = nil
    /// Film grain added after RawTherapee (Grain.swift): amount 0...100, size fine | medium | coarse.
    /// Encoded only when set (grain > 0 / size not fine), like crop.
    public var grain: Double = 0
    public var grainSize: String = "fine"
    /// Saturated-colour protection (Lab chromaticity, -30...0), set by the auto red-clip guard; 0 = off.
    public var chromaGuard: Double = 0
    /// Colour balance by tone (-50...50 each, like warmth/tint: + = warmer/yellower, + tint = magenta): corrects a
    /// cast that differs between shadows and highlights (film scans: blue-green shadows, pink highlights). Applied
    /// after RawTherapee (Balance.swift), the same formula as the editor's GPU preview. Encoded only when set.
    public var shadowWarmth: Double = 0
    public var shadowTint: Double = 0
    public var highlightWarmth: Double = 0
    public var highlightTint: Double = 0
    public var hasBalance: Bool { shadowWarmth != 0 || shadowTint != 0 || highlightWarmth != 0 || highlightTint != 0 }

    public init() {}

    enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, blacks, punch, vibrance, saturation, warmth, tint, film, filmStrength, vignette, rotate, sharpen, crop, grain, grainSize, chromaGuard
        case shadowWarmth, shadowTint, highlightWarmth, highlightTint
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(exposure, forKey: .exposure); try c.encode(contrast, forKey: .contrast); try c.encode(highlights, forKey: .highlights)
        try c.encode(shadows, forKey: .shadows); try c.encode(blacks, forKey: .blacks); try c.encode(punch, forKey: .punch)
        try c.encode(vibrance, forKey: .vibrance); try c.encode(saturation, forKey: .saturation); try c.encode(warmth, forKey: .warmth)
        try c.encode(tint, forKey: .tint); try c.encode(film, forKey: .film); try c.encode(filmStrength, forKey: .filmStrength)
        try c.encode(vignette, forKey: .vignette); try c.encode(rotate, forKey: .rotate); try c.encode(sharpen, forKey: .sharpen)
        try c.encodeIfPresent(crop, forKey: .crop)
        if grain != 0 { try c.encode(grain, forKey: .grain) }
        if grainSize != "fine" { try c.encode(grainSize, forKey: .grainSize) }
        if chromaGuard != 0 { try c.encode(chromaGuard, forKey: .chromaGuard) }
        if shadowWarmth != 0 { try c.encode(shadowWarmth, forKey: .shadowWarmth) }
        if shadowTint != 0 { try c.encode(shadowTint, forKey: .shadowTint) }
        if highlightWarmth != 0 { try c.encode(highlightWarmth, forKey: .highlightWarmth) }
        if highlightTint != 0 { try c.encode(highlightTint, forKey: .highlightTint) }
    }

    /// Lenient decoding: missing keys keep their neutral default, so partial bodies and old files work.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ k: CodingKeys) -> Double? {
            if let v = try? c.decodeIfPresent(Double.self, forKey: k) { return v }
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return Double(s) }
            return nil
        }
        exposure = d(.exposure) ?? 0; contrast = d(.contrast) ?? 0; highlights = d(.highlights) ?? 0
        shadows = d(.shadows) ?? 0; blacks = d(.blacks) ?? 0; punch = d(.punch) ?? 0
        vibrance = d(.vibrance) ?? 0; saturation = d(.saturation) ?? 0; warmth = d(.warmth) ?? 0
        tint = d(.tint) ?? 0; film = (try? c.decodeIfPresent(String.self, forKey: .film)) ?? ""
        filmStrength = d(.filmStrength) ?? 0; vignette = d(.vignette) ?? 0; rotate = d(.rotate) ?? 0; sharpen = d(.sharpen) ?? 0
        crop = try? c.decodeIfPresent(CropRect.self, forKey: .crop)
        grain = d(.grain) ?? 0
        grainSize = (try? c.decodeIfPresent(String.self, forKey: .grainSize)) ?? "fine"
        chromaGuard = d(.chromaGuard) ?? 0
        shadowWarmth = d(.shadowWarmth) ?? 0; shadowTint = d(.shadowTint) ?? 0
        highlightWarmth = d(.highlightWarmth) ?? 0; highlightTint = d(.highlightTint) ?? 0
    }

    /// Clamped to the UI ranges and quantized to the slider steps (so equality is stable).
    /// `film` must be a relative path inside the LUT root; anything else becomes "" (none).
    public func clamped(lutRoot: URL? = nil) -> EditParams {
        func q(_ v: Double, _ lo: Double, _ hi: Double, _ step: Double) -> Double {
            let x = v.isFinite ? min(hi, max(lo, v)) : 0
            let r = (x / step).rounded() * step
            return (r * 100).rounded() / 100 + 0   // + 0 turns -0 into 0
        }
        var e = self
        e.exposure = q(exposure, -2, 2, 0.05)
        e.contrast = q(contrast, 0, 100, 1)
        e.highlights = q(highlights, -100, 100, 1)
        e.shadows = q(shadows, -100, 100, 1)
        e.blacks = q(blacks, -50, 50, 1)
        e.punch = q(punch, 0, 100, 1)
        e.vibrance = q(vibrance, -100, 100, 1)
        e.saturation = q(saturation, -100, 100, 1)
        e.warmth = q(warmth, -50, 50, 1)
        e.tint = q(tint, -50, 50, 1)
        e.filmStrength = q(filmStrength, 0, 100, 1)
        e.vignette = q(vignette, 0, 100, 1)
        e.rotate = q(rotate, -10, 10, 0.1)
        e.sharpen = q(sharpen, 0, 100, 1)
        let f = film.trimmingCharacters(in: .whitespaces)
        // Paths stay inside the LUT root; the one exception is the black-and-white films beside it.
        let bwPrefix = "../Black-and-White/"
        let escapes = f.hasPrefix(bwPrefix) ? f.dropFirst(bwPrefix.count).contains("..") : f.contains("..")
        if f.isEmpty || f.hasPrefix("/") || escapes || !f.lowercased().hasSuffix(".png") {
            e.film = ""
        } else if let root = lutRoot, !FileManager.default.fileExists(atPath: root.appendingPathComponent(f).path) {
            e.film = ""
        } else { e.film = f }
        e.crop = crop?.clamped()
        e.grain = q(grain, 0, 100, 1)
        e.chromaGuard = q(chromaGuard, -30, 0, 1)
        e.shadowWarmth = q(shadowWarmth, -50, 50, 1); e.shadowTint = q(shadowTint, -50, 50, 1)
        e.highlightWarmth = q(highlightWarmth, -50, 50, 1); e.highlightTint = q(highlightTint, -50, 50, 1)
        e.grainSize = grainSizes.contains(grainSize.lowercased()) ? grainSize.lowercased() : "fine"
        return e
    }
}

/// A crop rectangle, normalized: x and w are fractions of the image width, y and h of its height,
/// measured on the oriented original after straightening (RawTherapee's AutoFill keeps the
/// straightened frame at the original's size, so the same numbers apply with or without rotation).
/// `aspect` is the UI's ratio label: "original", "free", or "W:H" (e.g. "3:2", "4:5", "1:1", "16:9").
public struct CropRect: Codable, Equatable {
    public var aspect: String = "original"
    public var x: Double = 0
    public var y: Double = 0
    public var w: Double = 1
    public var h: Double = 1

    public init(aspect: String = "original", x: Double = 0, y: Double = 0, w: Double = 1, h: Double = 1) {
        self.aspect = aspect; self.x = x; self.y = y; self.w = w; self.h = h
    }
    enum CodingKeys: String, CodingKey { case aspect, x, y, w, h }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ k: CodingKeys, _ def: Double) -> Double {
            if let v = try? c.decodeIfPresent(Double.self, forKey: k) { return v }
            if let s = try? c.decodeIfPresent(String.self, forKey: k), let v = Double(s) { return v }
            return def
        }
        aspect = (try? c.decodeIfPresent(String.self, forKey: .aspect)) ?? "original"
        x = d(.x, 0); y = d(.y, 0); w = d(.w, 1); h = d(.h, 1)
    }

    /// The ratio W/H for a "W:H" label, nil for original/free.
    public var ratio: Double? {
        let parts = aspect.split(separator: ":")
        guard parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), a > 0, b > 0 else { return nil }
        return a / b
    }
    public var isFullFrame: Bool { x <= 0.0001 && y <= 0.0001 && w >= 0.9999 && h >= 0.9999 }

    /// Inside the frame, at least 2% per side, quantized to 1/10000.
    /// nil when it's the full frame with no ratio chosen (= no crop).
    public func clamped() -> CropRect? {
        func q(_ v: Double) -> Double { ((v.isFinite ? v : 0) * 10000).rounded() / 10000 + 0 }
        var r = self
        let label = aspect.trimmingCharacters(in: .whitespaces).lowercased()
        r.aspect = label == "free" ? "free" : (ratio != nil ? label.replacingOccurrences(of: " ", with: "") : "original")
        r.w = q(min(1, max(0.02, w))); r.h = q(min(1, max(0.02, h)))
        r.x = q(min(1 - r.w, max(0, x))); r.y = q(min(1 - r.h, max(0, y)))
        if r.isFullFrame && r.aspect == "original" { return nil }
        return r
    }

    /// Pixel rectangle for an image of `width` x `height` (always inside the image).
    public func pixels(width: Int, height: Int) -> (x: Int, y: Int, w: Int, h: Int) {
        let W = Double(width), H = Double(height)
        let px = max(0, min(width - 1, Int((x * W).rounded())))
        let py = max(0, min(height - 1, Int((y * H).rounded())))
        let pw = max(1, min(width - px, Int((w * W).rounded())))
        let ph = max(1, min(height - py, Int((h * H).rounded())))
        return (px, py, pw, ph)
    }
}

/// Curated film stocks offered in the editor (Hald CLUTs, relative to the LUT root).
public let filmStocks: [(path: String, name: String)] = [
    ("Kodak/Kodak Kodachrome 64.png", "Kodachrome 64"),
    ("Kodak/Kodak Kodachrome 200.png", "Kodachrome 200"),
    ("Kodak/Kodak Ektachrome 100 VS.png", "Ektachrome 100 VS"),
    ("Kodak/Kodak Ektar 100.png", "Ektar 100"),
    ("Kodak/Kodak Portra 400 2.png", "Portra 400"),
    ("Kodak/Kodak Portra 400 VC 2.png", "Portra 400 VC"),
    ("Kodak/Kodak Portra 800 2.png", "Portra 800"),
    ("Fuji/Fuji Superia 400 2.png", "Superia 400"),
    ("Fuji/Fuji 400H 2.png", "Fuji 400H"),
]

func filmName(_ path: String) -> String {
    filmStocks.first { $0.path == path }?.name ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
}

public struct EditReport: Codable {
    public var look: String
    public var steps: [EditStep]
    public var sidecar: String          // absolute path of the RawTherapee sidecar (.pp3)
    public var workspace: String        // folder to open in RawTherapee
    public var preview: String?         // rendered edit, relative to the report folder
    public var thumb: String?
    public var userModified: Bool       // sidecar was changed in RawTherapee (not by photolab)
    public var params: EditParams? = nil
    public var recommended: EditParams? = nil
    public var modified: Bool? = nil    // params != recommended
    public var version: Int? = nil      // bumps on every committed render (cache busting)
}

/// Writes a RawTherapee processing profile (.pp3) section by section.
struct PP3 {
    private(set) var sections: [(String, [(String, String)])] = []
    mutating func set(_ section: String, _ pairs: [(String, String)]) {
        if let i = sections.firstIndex(where: { $0.0 == section }) { sections[i].1 += pairs } else { sections.append((section, pairs)) }
    }
    var text: String {
        var s = "[Version]\nAppVersion=5.11\nVersion=351\n"
        for (name, pairs) in sections {
            s += "\n[\(name)]\n"
            for (k, v) in pairs { s += "\(k)=\(v)\n" }
        }
        return s
    }
}

private func f(_ v: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", v) }
private func sgn(_ v: Double, _ d: Int = 0) -> String { (v > 0 ? "+" : "") + f(v, d) }
private func curve(_ pts: [(Double, Double)]) -> String {
    "1;" + pts.map { "\(f($0.0, 4));\(f($0.1, 4));" }.joined()
}

/// The tone curve for `contrast` (S strength), `blacks` (crush or matte), and the negative halves of
/// `highlights` (brighten the upper tones) and `shadows` (deepen the lower tones), as spline points.
/// A smooth monotone function sampled at fixed points, so the spline can't ring. White stays white and
/// black stays black for the highlight/shadow moves.
func toneCurvePoints(contrast: Double, blacks: Double, highlights: Double = 0, shadows: Double = 0) -> [(Double, Double)]? {
    let hiLift = max(0, -highlights) / 100      // 0...1
    let shDeep = max(0, -shadows) / 100         // 0...1
    if contrast == 0 && blacks == 0 && hiLift == 0 && shDeep == 0 { return nil }
    let k = contrast / 100
    let bp = max(0, -blacks) / 50 * 0.07        // input level that maps to pure black
    let lift = max(0, blacks) / 50 * 0.14       // output level of pure black (matte)
    func s(_ x: Double) -> Double {
        // Asymmetric S: shadows go down a little, upper mids/highlights go up a little more.
        let amp = x < 0.5 ? 0.07 : 0.10
        var y = x - k * amp * sin(2 * .pi * x)
        // Highlights < 0: raise the upper half (sin² bump, peak +0.06 at 3/4, flat at 1/2 and at white).
        // Shadows < 0: lower the lower half (peak -0.07 at 1/4, flat at black and 1/2). The amplitudes keep
        // the curve monotone even at contrast 100.
        if hiLift > 0 && x > 0.5 { let t = sin(.pi * (x - 0.5) / 0.5); y += hiLift * 0.06 * t * t }
        if shDeep > 0 && x < 0.5 { let t = sin(.pi * x / 0.5); y -= shDeep * 0.07 * t * t }
        return y
    }
    var xs: [Double] = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1]
    if bp > 0 { xs = (xs.filter { $0 == 0 || $0 > bp + 0.02 } + [bp]).sorted() }
    return xs.map { x in
        let xi = bp > 0 ? max(0, (x - bp) / (1 - bp)) : x
        return (x, lift + (1 - lift) * min(1, max(0, s(xi))))
    }
}

/// Deterministic mapping from params to a RawTherapee 5.11 profile.
/// `scale` < 1 renders from a downscaled proxy: pixel radii shrink to match.
/// `size` is the pixel size of the (oriented) input; the crop needs it. Without it no crop is written.
public func pp3(for e: EditParams, lutRoot: URL?, scale: Double = 1, size: (width: Int, height: Int)? = nil) -> String {
    pp3Sections(for: e, lutRoot: lutRoot, scale: scale, size: size).text
}

/// The profile as sections (the single source for both the .pp3 text and the GPU pipeline description).
func pp3Sections(for e: EditParams, lutRoot: URL?, scale: Double = 1, size: (width: Int, height: Int)? = nil) -> PP3 {
    var pp = PP3()
    if let c = e.crop, !c.isFullFrame, let size, size.width > 0, size.height > 0 {
        // RawTherapee crops last, in the coordinates of the transformed (straightened + AutoFill) frame,
        // which has the oriented input's dimensions.
        let r = c.pixels(width: size.width, height: size.height)
        pp.set("Crop", [("Enabled", "true"), ("X", "\(r.x)"), ("Y", "\(r.y)"), ("W", "\(r.w)"), ("H", "\(r.h)"),
                        ("FixedRatio", "false"), ("Ratio", "As Image"), ("Orientation", "As Image"), ("Guide", "Frame")])
    }
    if e.rotate != 0 {
        pp.set("Rotation", [("Degree", f(e.rotate, 2))])
        pp.set("Common Properties for Transformations", [("Method", "log"), ("AutoFill", "true")])
    }
    var exposure: [(String, String)] = [("Auto", "false"), ("Clip", "0.02"), ("Compensation", f(e.exposure)),
                                        ("Saturation", f(e.saturation, 0)),
                                        ("HighlightCompr", f(max(0, e.highlights), 0)), ("HighlightComprThreshold", "0")]
    if let pts = toneCurvePoints(contrast: e.contrast, blacks: e.blacks, highlights: e.highlights, shadows: e.shadows) {
        exposure += [("CurveMode", "FilmLike"), ("Curve", curve(pts))]
    } else {
        exposure += [("CurveMode", "FilmLike"), ("Curve", "0;")]
    }
    pp.set("Exposure", exposure)
    if e.shadows > 0 {
        pp.set("Shadows & Highlights", [("Enabled", "true"), ("Highlights", "0"), ("Shadows", f(e.shadows, 0)),
                                        ("ShadowTonalWidth", "30"), ("HighlightTonalWidth", "70"),
                                        ("Radius", f(max(5, 40 * scale), 0))])
    }
    if e.punch > 0 {
        pp.set("Local Contrast", [("Enabled", "true"), ("Radius", f(max(20, 80 * scale), 0)), ("Amount", f(e.punch / 100 * 0.6, 3)),
                                  ("Darkness", "1.0"), ("Lightness", "1.0")])
    }
    if e.chromaGuard != 0 {
        pp.set("Luminance Curve", [("Enabled", "true"), ("Chromaticity", f(e.chromaGuard, 0))])
    }
    if e.vibrance != 0 {
        pp.set("Vibrance", [("Enabled", "true"), ("Pastels", f(e.vibrance, 0)), ("Saturated", f((e.vibrance / 2).rounded(), 0)),
                            ("ProtectSkins", "true"), ("AvoidColorShift", "true"), ("PastSatTog", "true")])
    }
    if e.warmth != 0 || e.tint != 0 {
        // LabGrid with Low == High is a constant a*/b* shift: units = Δ Lab * 983.04. 1 slider unit = 0.3 Lab.
        let a = e.tint * 0.3 * 983.04, b = e.warmth * 0.3 * 983.04
        pp.set("ColorToning", [("Enabled", "true"), ("Method", "LabGrid"),
                               ("LabGridALow", f(a, 1)), ("LabGridBLow", f(b, 1)), ("LabGridAHigh", f(a, 1)), ("LabGridBHigh", f(b, 1))])
    }
    if !e.film.isEmpty, e.filmStrength > 0, let root = lutRoot {
        let path = root.appendingPathComponent(e.film).standardizedFileURL.path   // "../Black-and-White/…" made absolute
        if FileManager.default.fileExists(atPath: path) {
            pp.set("Film Simulation", [("Enabled", "true"), ("ClutFilename", path), ("Strength", f(e.filmStrength, 0))])
        }
    }
    if e.vignette > 0 {
        pp.set("PCVignette", [("Enabled", "true"), ("Strength", f(e.vignette / 100 * 1.2, 2)), ("Feather", "60"), ("Roundness", "50")])
    }
    if e.sharpen > 0 {
        // At preview scale the same deconvolution would look much stronger; soften it there.
        let amount = e.sharpen * (scale < 1 ? 0.5 : 1)
        pp.set("Sharpening", [("Enabled", "true"), ("Method", "rld"), ("DeconvRadius", "0.6"), ("DeconvAmount", f(amount, 0)),
                              ("DeconvDamping", "0"), ("DeconvIterations", "20")])
    }
    return pp
}

/// "Kodachrome street" (Meyerowitz / Webb / Gruyaert): dense saturated colour, deep (not matte)
/// blacks, full whites, hard-light contrast, rich reds, deep blues, slight warmth. Built for a soft
/// in-camera JPEG (e.g. Classic Negative with H-2 S-1), so it adds density instead of flattening.
/// Deterministic: the same analysis always gives the same recommendation.
public func recommendParams(_ p: PhotoReport) -> (EditParams, [EditStep]) {
    var e = EditParams()
    var steps: [EditStep] = []
    let t = p.tone, col = p.color, comp = p.composition, s = p.sharpness
    func step(_ tool: String, _ setting: String, _ reason: String) { steps.append(EditStep(tool: tool, setting: setting, reason: reason)) }

    // Film first: it defines the look everything else is balanced against.
    let iso = p.capture.iso ?? 0
    let lowLight = iso >= 1600 || (iso >= 800 && (p.capture.exposureTime ?? 0) >= 1.0 / 30)
    e.film = lowLight ? "Kodak/Kodak Kodachrome 200.png" : "Kodak/Kodak Kodachrome 64.png"
    e.filmStrength = lowLight ? 70 : 72
    step("Film", "\(filmName(e.film)) at \(Int(e.filmStrength))%", lowLight
         ? "Low light (ISO \(iso)), so Kodachrome 200: the same dense Kodachrome colour with a little more forgiveness in the shadows."
         : "Kodachrome 64 is the main look: deep blues, rich reds and warm, dense midtones, the classic colour street palette. Blended at \(Int(e.filmStrength))% over your \(p.fuji?.filmSimulation ?? "camera") JPEG.")

    // Level.
    // Only confident, clearly visible tilts: the detector misreads some level frames at 1-2.6° with low confidence.
    if let tilt = comp.horizonTilt, abs(tilt) >= 1.5, abs(tilt) <= 8, (comp.tiltConfidence ?? 0) >= 0.4 {
        e.rotate = tilt
        step("Straighten", "\(f(abs(tilt), 1))° \(tilt > 0 ? "counter-clockwise" : "clockwise")",
             "The frame measures \(f(abs(tilt), 1))° off level from \(comp.tiltSource ?? "straight lines"). The corners are trimmed to fill the frame.")
    }

    // Exposure: aim the median at a bright, printed-slide level. The film LUT and S-curve pull the
    // mids down a little, so the target sits above a "correct" middle grey.
    let target: Double = t.key == "low-key" ? 40 : t.key == "high-key" ? max(t.medianLstar, 62) : 56
    var ev = (target - t.medianLstar) / 15 + 0.1
    // Bright sunny frames stay bright: only a small pull-down, the shoulder handles the highlights.
    ev = min(0.6, max(-0.15, ev))
    let highlightsAtRisk = t.highlightClipAny > 1 || t.largestHighlightRegion > 0.2
    if highlightsAtRisk { ev = min(ev, 0.2) }
    e.exposure = (ev * 20).rounded() / 20
    step("Exposure", "\(sgn(e.exposure, 2)) EV",
         "Median brightness is L* \(Int(t.medianLstar)) (\(t.key)); moving it toward \(Int(target)) for bright, luminous mids under the denser film curve\(highlightsAtRisk && ev >= 0.2 ? ", capped to protect the highlights" : "").")

    var hl = 15.0
    if t.highlightClipAny > 0.5 { hl += 20 }
    if t.highlightClipAny > 2 { hl += 15 }
    if t.largestHighlightRegion > 0.5 { hl += 15 }
    if e.exposure >= 0.3 { hl += 10 }
    e.highlights = hl
    step("Highlights", "\(Int(hl))", hl > 25
         ? String(format: "%.1f%% of the frame touches the top of the range, so the brightest areas get a soft shoulder instead of a hard edge.", t.highlightClipAny)
         : "A light shoulder so bright areas roll off smoothly while whites stay full.")

    if t.key != "high-key" && t.medianLstar < 36 && t.shadowClip < 3 {
        e.shadows = 15
        step("Shadows", "+15", "The frame is dark (median L* \(Int(t.medianLstar))) but the shadows aren't crushed, so there's detail worth opening a little.")
    }

    // Contrast: hard-light density for a JPEG that's already soft in camera.
    let gc = t.globalContrast
    let softCamera = ((p.fuji?.highlightTone ?? 0) + (p.fuji?.shadowTone ?? 0)) <= -2
    var contrast = gc < 22 ? 55.0 : gc < 28 ? 45 : 35
    if softCamera { contrast += 10 }
    e.contrast = contrast
    step("Contrast", "\(Int(contrast))",
         "Global contrast measures \(f(gc, 1))\(softCamera ? " and the camera recipe softens highlights and shadows (H\(sgn(p.fuji?.highlightTone ?? 0)) S\(sgn(p.fuji?.shadowTone ?? 0)))" : ""). An S-curve gives the hard-light density of slide film: deeper shadows, brighter upper mids.")

    // Blacks: deep, never matte. Back off where the shadows are already black.
    e.blacks = t.shadowClip > 10 ? 0 : t.shadowClip > 2 ? -3 : -6
    step("Blacks", "\(Int(e.blacks))", e.blacks == 0
         ? String(format: "%.0f%% of the frame is already pure black, so the black point is left alone.", t.shadowClip)
         : "Slightly deeper blacks for a dense, inky Kodachrome base instead of the soft lifted shadows of the JPEG.")

    // Punch (local contrast).
    let lc = t.localContrast
    e.punch = lc < 3 ? 55 : lc < 5 ? 45 : lc < 7 ? 35 : 28
    step("Punch", "\(Int(e.punch))", "Measured local detail is \(f(lc, 1)); \(e.punch >= 45 ? "it's flat, so more" : e.punch >= 35 ? "a moderate amount of" : "already crisp, so only a little") texture and separation for a dynamic street look.")

    // Colour: positive saturation. Classic Negative is muted, the LUT does most of the work.
    let mc = col.meanChroma
    var vib = mc < 10 ? 30.0 : mc < 16 ? 24 : 16
    var sat = mc < 10 ? 12.0 : mc < 16 ? 10 : 6
    if col.saturationClip > 0.5 { sat = 0; vib = min(vib, 12) }
    e.vibrance = vib; e.saturation = sat
    step("Vibrance", "+\(Int(vib))", "Mean saturation is C* \(Int(mc)); vibrance lifts the muted colours most and protects skin tones.")
    step("Saturation", sgn(sat), col.saturationClip > 0.5
         ? String(format: "%.1f%% of the colours are already at the edge of sRGB, so global saturation stays put.", col.saturationClip)
         : "A small global boost so reds and blues read as dense Kodachrome colour, not pastel.")

    // Warmth/tint: the Kodachrome LUT pushes neutrals ~2 a* magenta and ~2 b* cool (measured on
    // this camera's JPEGs). Counter that and land slightly warm, less so if the frame is warm already.
    e.warmth = col.warmth > 4 ? 6 : 10
    e.tint = -6
    step("Warmth", sgn(e.warmth), "Mean b* is \(f(col.warmth, 1)). The film LUT cools neutrals a little; this lands greys slightly warm, the sunny Kodachrome cast.")
    step("Tint", sgn(e.tint), "The film LUT pushes greys toward magenta; a small green shift keeps skies blue and pavements neutral.")

    // Vignette.
    e.vignette = comp.brightEdges.isEmpty ? 25 : 45
    step("Vignette", "\(Int(e.vignette))", comp.brightEdges.isEmpty
         ? "A light edge burn holds the eye in the frame."
         : "Bright \(comp.brightEdges.joined(separator: " and ")) edge measured; a stronger edge burn keeps attention inside the frame.")

    // Detail.
    if let w = s.bestWidth, w > 1.7 {
        e.sharpen = 35
        step("Sharpen", "35", "The sharpest edges take \(f(w, 2)) px to rise; a light deconvolution restores some crispness without exaggerating the grain.")
    }
    if let g = p.fuji?.grainEffect, g != "Off" {
        step("Grain", "keep camera grain", "Your in-camera Grain Effect (\(g)) is already in the file, so no grain is added.")
    }
    if p.faces.contains(where: { $0.eyesClosed == true }) || t.largestHighlightRegion >= 1 {
        step("Note", "edit can't fix everything", t.largestHighlightRegion >= 1
             ? String(format: "%.1f%% of the frame is blown in the JPEG; the shoulder softens the edge, but that detail isn't recoverable.", t.largestHighlightRegion)
             : "Closed eyes can't be fixed by editing; check the other frames in this moment.")
    }
    return (e.clamped(), steps)
}

// MARK: - Workspace, files, rendering

public struct EditOptions {
    public var rawTherapeeCLI: URL
    public var jobs: Int
    public var reset: Bool
    public init(rawTherapeeCLI: URL, jobs: Int, reset: Bool) { self.rawTherapeeCLI = rawTherapeeCLI; self.jobs = jobs; self.reset = reset }
}

public let previewSize = 1600
public let studioPreviewSize = 2560

/// What the engine needs to know about a photo (a PhotoReport carries more; studio projects store just this).
public struct PhotoRef {
    public var id: String
    public var file: String
    public var path: String
    public var width: Int
    public var height: Int
    public init(id: String, file: String, path: String, width: Int, height: Int) {
        self.id = id; self.file = file; self.path = path; self.width = width; self.height = height
    }
}

extension PhotoReport {
    public var ref: PhotoRef { PhotoRef(id: id, file: file, path: path, width: width, height: height) }
}

/// Paths and RawTherapee calls for one report folder or studio project. Thread-safe (no mutable state).
public struct EditEngine {
    public let reportDir: URL
    public let lutRoot: URL?
    public let rt: URL?
    /// Folder holding a link to each original plus its RawTherapee sidecar (<file>.pp3).
    public let workspace: URL
    let gen: URL
    let proxyDir: URL
    let previewDir: URL
    let thumbDir: URL
    let thumbSuffix: String
    let renderTmp: URL
    let exportTmp: URL
    /// Long edge of proxies and preview renders: 1600 for `photolab analyze/serve`, 2560 in the studio.
    public let previewLong: Int

    /// The `photolab analyze/serve` report layout.
    public init(reportDir: URL, lutRoot: URL?, rt: URL?) {
        self.reportDir = reportDir; self.lutRoot = lutRoot; self.rt = rt
        workspace = reportDir.appendingPathComponent("edit")
        gen = workspace.appendingPathComponent(".photolab")
        proxyDir = gen.appendingPathComponent("proxy")
        previewDir = reportDir.appendingPathComponent("edits")
        thumbDir = reportDir.appendingPathComponent("thumbs")
        thumbSuffix = "-edit"
        renderTmp = gen.appendingPathComponent("render")
        exportTmp = reportDir.appendingPathComponent("export/.tmp")
        previewLong = previewSize
    }

    /// The studio project layout: sidecars/, proxies/, renders/, thumbs/, .tmp/.
    public init(studioProject dir: URL, lutRoot: URL?, rt: URL?) {
        reportDir = dir; self.lutRoot = lutRoot; self.rt = rt
        workspace = dir.appendingPathComponent("sidecars")
        gen = workspace.appendingPathComponent(".gen")
        proxyDir = dir.appendingPathComponent("proxies")
        previewDir = dir.appendingPathComponent("renders")
        thumbDir = dir.appendingPathComponent("thumbs")
        thumbSuffix = ""
        renderTmp = dir.appendingPathComponent(".tmp/render")
        exportTmp = dir.appendingPathComponent(".tmp/export")
        previewLong = studioPreviewSize
    }

    func link(_ p: PhotoRef) -> URL { workspace.appendingPathComponent(p.file) }
    func sidecar(_ p: PhotoRef) -> URL { workspace.appendingPathComponent(p.file + ".pp3") }
    func generatedSidecar(_ p: PhotoRef) -> URL { gen.appendingPathComponent(p.file + ".pp3") }
    func paramsURL(_ p: PhotoRef) -> URL { gen.appendingPathComponent(p.file + ".params.json") }
    func recommendedURL(_ p: PhotoRef) -> URL { gen.appendingPathComponent(p.file + ".recommended.json") }
    public func proxyURL(_ p: PhotoRef) -> URL { proxyDir.appendingPathComponent("\(p.id).jpg") }
    public func previewURL(_ p: PhotoRef) -> URL { previewDir.appendingPathComponent("\(p.id).jpg") }
    public func thumbURL(_ p: PhotoRef) -> URL { thumbDir.appendingPathComponent("\(p.id)\(thumbSuffix).jpg") }

    func link(_ p: PhotoReport) -> URL { link(p.ref) }
    func sidecar(_ p: PhotoReport) -> URL { sidecar(p.ref) }
    func generatedSidecar(_ p: PhotoReport) -> URL { generatedSidecar(p.ref) }
    func paramsURL(_ p: PhotoReport) -> URL { paramsURL(p.ref) }
    func recommendedURL(_ p: PhotoReport) -> URL { recommendedURL(p.ref) }
    func proxyURL(_ p: PhotoReport) -> URL { proxyURL(p.ref) }
    public func previewURL(_ p: PhotoReport) -> URL { previewURL(p.ref) }
    public func thumbURL(_ p: PhotoReport) -> URL { thumbURL(p.ref) }

    static func readParams(_ url: URL) -> EditParams? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EditParams.self, from: d)
    }
    static func writeJSON<T: Encodable>(_ v: T, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(v).write(to: url, options: .atomic)
    }

    public func loadParams(_ p: PhotoReport) -> EditParams? { Self.readParams(paramsURL(p))?.clamped(lutRoot: lutRoot) }
    public func loadRecommended(_ p: PhotoReport) -> EditParams { Self.readParams(recommendedURL(p))?.clamped(lutRoot: lutRoot) ?? recommendParams(p).0.clamped(lutRoot: lutRoot) }

    /// Saves params.json and regenerates the RawTherapee sidecar from them.
    public func save(_ e: EditParams, for p: PhotoReport) throws {
        try FileManager.default.createDirectory(at: gen, withIntermediateDirectories: true)
        try Self.writeJSON(e, to: paramsURL(p))
        let text = pp3(for: e, lutRoot: lutRoot, size: (p.width, p.height))
        try text.write(to: sidecar(p), atomically: true, encoding: .utf8)
        try text.write(to: generatedSidecar(p), atomically: true, encoding: .utf8)
    }

    /// Writes the full-resolution sidecar for `e` and makes sure the link to the original exists
    /// (studio projects: no params.json, the project file holds the params).
    public func writeSidecar(_ e: EditParams, for p: PhotoRef) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        let l = link(p)
        if (try? fm.destinationOfSymbolicLink(atPath: l.path)) != p.path {
            try? fm.removeItem(at: l)
            try fm.createSymbolicLink(at: l, withDestinationURL: URL(fileURLWithPath: p.path))
        }
        try pp3(for: e, lutRoot: lutRoot, size: (p.width, p.height)).write(to: sidecar(p), atomically: true, encoding: .utf8)
    }

    /// A high-quality, upright copy of the original at `previewLong` (1600 / 2560 px). Preview renders
    /// start from it, so a slider change costs a fraction of a second instead of decoding 26 MP every time.
    /// An existing smaller proxy (made before the size went up) is replaced when `upgrade` is set, else reused.
    /// If the original is missing, an existing proxy is still returned.
    @discardableResult
    public func ensureProxy(_ p: PhotoRef, upgrade: Bool = true) -> URL? {
        let fm = FileManager.default
        let url = proxyURL(p)
        let srcDate = (try? fm.attributesOfItem(atPath: p.path))?[.modificationDate] as? Date ?? .distantPast
        if let d = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, d >= srcDate {
            if !upgrade || !fm.fileExists(atPath: p.path) { return url }
            let want = min(previewLong, max(p.width, p.height))
            if let (w, h) = Self.pixelSize(url), max(w, h) >= want - 2 { return url }
        }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p.path) as CFURL, nil),
              let img = Pixels.load(src, maxPixel: previewLong) else { return fm.fileExists(atPath: url.path) ? url : nil }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(p.id)-\(UUID().uuidString).jpg")
        Pixels.writeJPEG(img, to: tmp, quality: 0.95)
        _ = try? fm.replaceItemAt(url, withItemAt: tmp)
        if !fm.fileExists(atPath: url.path) { try? fm.moveItem(at: tmp, to: url) }
        try? fm.removeItem(at: tmp)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    /// A smaller copy of the proxy (for previews rendered at the editor's displayed size), cached next to it.
    public func sizedProxy(_ p: PhotoRef, long: Int) -> URL? {
        guard let base = ensureProxy(p, upgrade: false), let (w, h) = Self.pixelSize(base), max(w, h) > long else { return nil }
        let fm = FileManager.default
        let url = proxyDir.appendingPathComponent("\(p.id)@\(long).jpg")
        let baseDate = (try? fm.attributesOfItem(atPath: base.path))?[.modificationDate] as? Date ?? .distantFuture
        if let d = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, d >= baseDate { return url }
        guard let src = CGImageSourceCreateWithURL(base as CFURL, nil), let img = Pixels.load(src, maxPixel: long) else { return nil }
        let tmp = proxyDir.appendingPathComponent(".\(p.id)@\(long)-\(UUID().uuidString).jpg")
        Pixels.writeJPEG(img, to: tmp, quality: 0.95)
        try? fm.removeItem(at: url)
        try? fm.moveItem(at: tmp, to: url)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    static func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let pr = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let w = pr[kCGImagePropertyPixelWidth as String] as? Int, let h = pr[kCGImagePropertyPixelHeight as String] as? Int else { return nil }
        return (w, h)
    }

    @discardableResult
    public func ensureProxy(_ p: PhotoReport) -> URL? { ensureProxy(p.ref) }

    /// Runs rawtherapee-cli, retrying: parallel instances occasionally fail on startup.
    /// A run that exceeds `timeout` is killed and not retried (e.g. macOS is holding the read of an
    /// original behind a privacy prompt).
    func runRT(_ args: [String], output: URL, timeout: TimeInterval = 120) -> Bool {
        guard let rt else { return false }
        let fm = FileManager()
        for _ in 0..<3 {
            try? fm.removeItem(at: output)
            let proc = Process()
            proc.executableURL = rt
            proc.arguments = args
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            let done = DispatchSemaphore(value: 0)
            proc.terminationHandler = { _ in done.signal() }
            guard (try? proc.run()) != nil else { continue }
            if done.wait(timeout: .now() + timeout) == .timedOut {
                proc.terminate()
                if done.wait(timeout: .now() + 2) == .timedOut { kill(proc.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 2) }
                return false
            }
            if proc.terminationStatus == 0 && fm.fileExists(atPath: output.path) { return true }
        }
        return false
    }

    /// Renders a 1600 px preview to `out` (and a 480 px thumb to `thumbOut`).
    /// With params: from the proxy with a scale-adjusted profile (fast). Without: the sidecar as
    /// RawTherapee left it, from the original (used when the sidecar was changed in RawTherapee).
    public func renderPreview(_ p: PhotoRef, params: EditParams?, to out: URL, thumbOut: URL?, upgradeProxy: Bool = true, proxyOverride: URL? = nil) -> Bool {
        let fm = FileManager()
        try? fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmpDir = renderTmp
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let token = UUID().uuidString
        var cleanup: [URL] = []
        defer { for u in cleanup { try? fm.removeItem(at: u) } }
        var args = ["-q", "-Y"]
        let input: URL
        if let e = params, let proxy = proxyOverride ?? ensureProxy(p, upgrade: upgradeProxy) {
            let longEdge = Double(max(p.width, p.height))
            let size = Self.pixelSize(proxy)
            let proxyLong = Double(size.map { max($0.0, $0.1) } ?? previewLong)
            let profile = tmpDir.appendingPathComponent("\(p.id)-\(token).pp3")
            guard (try? pp3(for: e, lutRoot: lutRoot, scale: min(1, proxyLong / max(1, longEdge)), size: size).write(to: profile, atomically: true, encoding: .utf8)) != nil else { return false }
            cleanup.append(profile)
            args += ["-p", profile.path]
            input = proxy
        } else {
            let resize = tmpDir.appendingPathComponent("resize-\(token).pp3")
            try? """
            [Resize]
            Enabled=true
            AppliesTo=Full image
            Method=Lanczos
            DataSpecified=3
            Width=\(previewLong)
            Height=\(previewLong)
            AllowUpscaling=false
            """.write(to: resize, atomically: true, encoding: .utf8)
            cleanup.append(resize)
            args += ["-p", sidecar(p).path, "-p", resize.path]
            input = link(p)
        }
        if let e = params, let spec = GrainSpec(e, id: p.id) {
            // Grain: RawTherapee writes a TIFF, the grain goes on, the JPEG is encoded once.
            let tif = tmpDir.appendingPathComponent("\(p.id)-\(token).tif")
            cleanup.append(tif)
            guard runRT(args + ["-o", tif.path, "-t", "-c", input.path], output: tif, timeout: 30),
                  let src = CGImageSourceCreateWithURL(tif as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let grained = Grain.apply(img, spec),
                  let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(dest, grained, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return false }
            if let thumbOut, let s2 = CGImageSourceCreateWithURL(out as CFURL, nil), let th = Pixels.load(s2, maxPixel: 480) {
                Pixels.writeJPEG(th, to: thumbOut, quality: 0.8)
            }
            return true
        }
        args += ["-o", out.path, "-j90", "-js3", "-c", input.path]
        guard runRT(args, output: out, timeout: params != nil ? 30 : 90) else { return false }
        if let thumbOut, let src = CGImageSourceCreateWithURL(out as CFURL, nil), let th = Pixels.load(src, maxPixel: 480) {
            Pixels.writeJPEG(th, to: thumbOut, quality: 0.8)
        }
        return true
    }
    public func renderPreview(_ p: PhotoReport, params: EditParams?, to out: URL, thumbOut: URL?) -> Bool {
        renderPreview(p.ref, params: params, to: out, thumbOut: thumbOut)
    }

    /// The edit at full resolution from the original (for 1:1 zoom): JPEG q92, grain included, no frame.
    public func renderFullRes(_ p: PhotoRef, params e: EditParams, to out: URL) -> Bool {
        let fm = FileManager()
        try? fm.createDirectory(at: renderTmp, withIntermediateDirectories: true)
        try? writeSidecar(e, for: p)   // also makes sure the link to the original exists
        let token = UUID().uuidString
        let profile = renderTmp.appendingPathComponent("\(p.id)-full-\(token).pp3")
        defer { try? fm.removeItem(at: profile) }
        guard (try? pp3(for: e, lutRoot: lutRoot, size: (p.width, p.height)).write(to: profile, atomically: true, encoding: .utf8)) != nil else { return false }
        if let spec = GrainSpec(e, id: p.id) {
            let tif = renderTmp.appendingPathComponent("\(p.id)-full-\(token).tif")
            defer { try? fm.removeItem(at: tif) }
            guard runRT(["-q", "-Y", "-p", profile.path, "-o", tif.path, "-t", "-c", link(p).path], output: tif, timeout: 90),
                  let src = CGImageSourceCreateWithURL(tif as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let grained = Grain.apply(img, spec),
                  let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(dest, grained, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            return CGImageDestinationFinalize(dest)
        }
        return runRT(["-q", "-Y", "-p", profile.path, "-o", out.path, "-j92", "-js3", "-c", link(p).path], output: out, timeout: 90)
    }
}

public let lookName = "Kodachrome street"

/// Creates <report>/edit/ with links to the originals, recommended + current params, and a
/// RawTherapee sidecar per photo generated from the current params.
/// - Your params (edit/.photolab/<FILE>.params.json) are kept unless `reset`; if you never changed
///   them, they follow an updated recommendation.
/// - A sidecar you changed in RawTherapee is left alone (flagged `userModified`) unless `reset`.
public func prepareEdits(_ report: inout ShootReport, reportDir: URL, reset: Bool, lutRoot: URL? = nil) throws {
    let fm = FileManager.default
    let eng = EditEngine(reportDir: reportDir, lutRoot: lutRoot, rt: nil)
    try fm.createDirectory(at: eng.gen, withIntermediateDirectories: true)
    for i in report.photos.indices {
        let p = report.photos[i]
        let link = eng.link(p)
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil {
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: p.path))
        }
        var (rec, steps) = recommendParams(p)
        rec = rec.clamped(lutRoot: lutRoot)
        let oldRec = EditEngine.readParams(eng.recommendedURL(p))?.clamped(lutRoot: lutRoot)
        var params = reset ? nil : eng.loadParams(p)
        if let cur = params, let old = oldRec, cur == old { params = rec }   // untouched: follow the new recommendation
        let current = params ?? rec
        try EditEngine.writeJSON(rec, to: eng.recommendedURL(p))
        try EditEngine.writeJSON(current, to: eng.paramsURL(p))

        let text = pp3(for: current, lutRoot: lutRoot, size: (p.width, p.height))
        let onDisk = try? String(contentsOf: eng.sidecar(p), encoding: .utf8)
        let lastGenerated = try? String(contentsOf: eng.generatedSidecar(p), encoding: .utf8)
        let external = !reset && onDisk != nil && onDisk != lastGenerated
        if !external {
            try text.write(to: eng.sidecar(p), atomically: true, encoding: .utf8)
            try text.write(to: eng.generatedSidecar(p), atomically: true, encoding: .utf8)
        }
        report.photos[i].edit = EditReport(look: lookName, steps: steps, sidecar: eng.sidecar(p).path,
                                           workspace: eng.workspace.path, preview: p.edit?.preview, thumb: p.edit?.thumb,
                                           userModified: external, params: current, recommended: rec,
                                           modified: current != rec, version: p.edit?.version)
    }
}

/// Renders every photo's preview (1600 px) and grid thumbnail (480 px).
public func renderEdits(_ report: inout ShootReport, reportDir: URL, opt: EditOptions, lutRoot: URL? = nil, log: @escaping (String) -> Void) throws {
    let eng = EditEngine(reportDir: reportDir, lutRoot: lutRoot, rt: opt.rawTherapeeCLI)
    try FileManager.default.createDirectory(at: reportDir.appendingPathComponent("edits"), withIntermediateDirectories: true)
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = max(1, opt.jobs)
    let lock = NSLock()
    var done = 0
    let start = Date()
    let total = report.photos.count
    var okIds = Set<String>()
    for p in report.photos {
        guard let e = p.edit else { continue }
        queue.addOperation {
            let ok = eng.renderPreview(p, params: e.userModified ? nil : e.params, to: eng.previewURL(p), thumbOut: eng.thumbURL(p))
            lock.lock()
            if ok { okIds.insert(p.id) }
            done += 1
            log("[render \(done)/\(total)] \(p.id)\(ok ? "" : " FAILED")")
            lock.unlock()
        }
    }
    queue.waitUntilAllOperationsAreFinished()
    for i in report.photos.indices where okIds.contains(report.photos[i].id) {
        let id = report.photos[i].id
        report.photos[i].edit?.preview = "edits/\(id).jpg"
        report.photos[i].edit?.thumb = "thumbs/\(id)-edit.jpg"
        let v = (report.photos[i].edit?.version ?? 0) + 1
        report.photos[i].edit?.version = v
    }
    log(String(format: "Rendered %d edits in %.1fs", done, Date().timeIntervalSince(start)))
}

/// Full-resolution export of every photo with its current sidecar, using the shoot's export
/// settings (frame, destination). `dir` overrides the destination. Returns the folder used.
@discardableResult
public func exportEdits(_ report: ShootReport, reportDir: URL, to dir: URL?, opt: EditOptions, log: @escaping (String) -> Void) throws -> URL {
    var settings = loadExportSettings(reportDir: reportDir)
    if let dir { settings.dest = dir.path }
    let dest = try resolveExportDir(settings, report: report, reportDir: reportDir)
    let eng = EditEngine(reportDir: reportDir, lutRoot: nil, rt: opt.rawTherapeeCLI)
    let manifest = reportDir.appendingPathComponent("edit/.photolab/exported.json")
    var owned = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: manifest))) ?? [])
    let lock = NSLock()
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = max(1, min(opt.jobs, 3))
    for p in report.photos where p.edit != nil {
        queue.addOperation {
            switch eng.export(p, toDir: dest, settings: settings, owns: { path in lock.lock(); defer { lock.unlock() }; return owned.contains(path) }) {
            case .success(let r):
                lock.lock(); owned.insert(r.path.path); lock.unlock()
                log("exported \(p.id) \(r.width)x\(r.height) -> \(r.path.lastPathComponent)")
            case .failure(let e): log("exported \(p.id) FAILED: \(e)")
            }
        }
    }
    queue.waitUntilAllOperationsAreFinished()
    try? JSONEncoder().encode(owned.sorted()).write(to: manifest, options: .atomic)
    return dest
}
