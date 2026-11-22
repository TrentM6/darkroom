import Foundation

// THE ONE PLACE where Baseline Darkroom reads the analysis model (ToneReport, SharpnessReport,
// CompositionReport, ColorReport, FujiSettings, flags, street read). When the analysis files are
// replaced and field names change, only this file needs updating. Everything else in the studio
// works from `PhotoFacts`, `StudioHint` and plain strings.

/// The measurements the studio's auto corrections, look matching and hints depend on.
public struct PhotoFacts: Codable, Equatable {
    // Tone
    public var medianL: Double = 50              // median L*
    public var key: String = "normal"            // low-key | normal | high-key
    public var highlightClipAny: Double = 0      // % pixels with any channel clipped
    public var largestHighlightRegion: Double = 0 // % of frame, largest blown region
    public var shadowClip: Double = 0            // % pure black
    public var globalContrast: Double = 25       // std dev of L*
    public var localContrast: Double = 5
    // Colour
    public var meanChroma: Double = 12
    public var saturationClip: Double = 0
    public var warmth: Double = 0                // mean b* of the frame
    // Composition / geometry
    public var brightEdges: Bool = false
    public var tilt: Double? = nil               // + = frame rotated clockwise; rotate counter-clockwise to fix
    public var tiltConfidence: Double = 0
    // Detail
    public var bestEdgeWidth: Double? = nil      // px at 100% (older analysis: sharpest tile)
    public var frameWidth: Double? = nil         // px at 100%, grain-proof frame measurement (crisp ~3, soft > 4.4)
    // Capture
    public var iso: Int = 0
    public var exposureTime: Double = 0          // seconds
    // Fuji recipe (maker notes)
    public var filmSimulation: String? = nil
    public var highlightTone: Double = 0
    public var shadowTone: Double = 0
    public var colorSetting: Double? = nil       // Fuji "Color" -4...+4
    public var grain: Bool = false
    public init() {}
}

/// A short, plain-language problem hint.
public struct StudioHint: Codable, Equatable {
    public var code: String
    public var text: String
    public var grid: Bool = false       // also shown as the ⚠ badge in the grid
    init(code: String, text: String, grid: Bool) { self.code = code; self.text = text; self.grid = grid }
    enum CodingKeys: String, CodingKey { case code, text, grid }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        text = try c.decode(String.self, forKey: .text)
        grid = (try? c.decodeIfPresent(Bool.self, forKey: .grid)) ?? false
    }
}

enum StudioAnalysis {
    static func facts(_ p: PhotoReport) -> PhotoFacts {
        var f = PhotoFacts()
        let t = p.tone
        f.medianL = t.medianLstar
        f.key = t.key
        f.highlightClipAny = t.highlightClipAny
        f.largestHighlightRegion = t.largestHighlightRegion
        f.shadowClip = t.shadowClip
        f.globalContrast = t.globalContrast
        f.localContrast = t.localContrast
        f.meanChroma = p.color.meanChroma
        f.saturationClip = p.color.saturationClip
        f.warmth = p.color.warmth
        f.brightEdges = !p.composition.brightEdges.isEmpty
        f.tilt = p.composition.horizonTilt
        f.tiltConfidence = p.composition.tiltConfidence ?? 0
        f.bestEdgeWidth = p.sharpness.bestWidth
        f.frameWidth = p.sharpness.frameWidth
        f.iso = p.capture.iso ?? 0
        f.exposureTime = p.capture.exposureTime ?? 0
        if let fu = p.fuji {
            f.filmSimulation = fu.filmSimulation
            f.highlightTone = fu.highlightTone ?? 0
            f.shadowTone = fu.shadowTone ?? 0
            f.colorSetting = fu.color.flatMap { Double($0.replacingOccurrences(of: "+", with: "")) }
            f.grain = fu.grainEffect != "Off" && !fu.grainEffect.isEmpty
        }
        return f
    }

    /// Bump when the rules change: stored hints are then recomputed from the saved analysis.
    static let hintsVersion = 3

    /// Hints: plain words, only for problems the analysis states with confidence ("bad" severity, plus
    /// a missed focus, which the analysis reports at "warn" with a wide safety margin; info findings are
    /// never shown). The grid badge only for what decides a cull outright; the edit view (at most 2) also
    /// names motion blur and blown highlights. Order = importance.
    static let hintRules: [(code: String, severities: Set<String>, text: String, grid: Bool)] = [
        ("eyes-closed", ["bad"], "Eyes closed", true),
        ("focus-off-subject", ["bad", "warn"], "Focus missed the subject", true),
        ("motion-blur", ["bad"], "Motion blur", false),
        ("highlights-blown", ["bad"], "Highlights blown", false),
    ]

    static func hints(flags: [Flag]) -> [StudioHint] {
        hintRules.filter { rule in flags.contains { $0.code == rule.code && rule.severities.contains($0.severity) } }
            .map { StudioHint(code: $0.code, text: $0.text, grid: $0.grid) }
    }
    static func hints(_ p: PhotoReport) -> [StudioHint] { hints(flags: p.flags) }

    /// The street read: a few plain sentences.
    static func notes(_ p: PhotoReport) -> [String] { p.street?.read ?? [] }

    static func streetScore(_ p: PhotoReport) -> Double? { p.street?.score.total }
    static func techScore(_ p: PhotoReport) -> Double? { p.score?.total }

    /// "2026:07:04 11:18:10" -> "2026-07-04T11:18:10" (camera local time, no zone).
    static func isoTime(_ p: PhotoReport) -> String? {
        guard let s = p.capture.dateTimeOriginal, s.count >= 19 else { return nil }
        let c = Array(s)
        return String(c[0..<4]) + "-" + String(c[5..<7]) + "-" + String(c[8..<10]) + "T" + String(c[11..<19])
    }

    static func info(_ p: PhotoReport) -> [String: String] {
        let c = p.capture
        var d: [String: String] = [:]
        let cam = [c.make, c.model].compactMap { $0 }.joined(separator: " ")
        if !cam.isEmpty { d["camera"] = cam.replacingOccurrences(of: "FUJIFILM ", with: "Fujifilm ") }
        if let l = c.lens { d["lens"] = l }
        if let s = c.shutter { d["shutter"] = s }
        if let fn = c.fNumber { d["aperture"] = String(format: "f/%g", fn) }
        if let iso = c.iso { d["iso"] = "ISO \(iso)" }
        if let fl = c.focalLength { d["focal"] = String(format: "%g mm", fl) }
        if let r = p.fuji?.recipe { d["recipe"] = r }
        return d
    }
}
