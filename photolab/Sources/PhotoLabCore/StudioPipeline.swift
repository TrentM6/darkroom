import Foundation
import ImageIO

// The exact processing Baseline Darkroom asks RawTherapee (and the grain post-process) to do for a photo's
// current params at proxy scale, as JSON, so the UI's GPU preview mirrors it instead of re-deriving it.
// Built from the same section list `pp3(for:)` writes (pp3Sections), so the two can't drift.

extension Studio {
    static let bwPrefix = "../Black-and-White/"
    static func lutURL(_ relPath0: String) -> String {
        let bw = relPath0.hasPrefix(bwPrefix)
        let relPath = bw ? String(relPath0.dropFirst(bwPrefix.count)) : relPath0
        return (bw ? "/luts-bw/" : "/luts/") + relPath.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? String($0) }.joined(separator: "/")
    }

    public func filmsJSON() -> [[String: Any]] {
        studioFilmStocks.map { f in
            var d: [String: Any] = ["path": f.path, "name": f.name, "url": Self.lutURL(f.path)]
            if let root = lutRoot, let (w, h) = EditEngine.pixelSize(root.appendingPathComponent(f.path)) { d["width"] = w; d["height"] = h }
            return d
        }
    }

    /// RawTherapee's AutoFill zoom for a rotation of `deg` on a w x h frame: the straightened image is
    /// scaled by this (about the centre) so no blank corners show, keeping the frame at w x h.
    /// Measured against RawTherapee 5.11: matches within 0.001 at +5° and -3°.
    static func autofillScale(_ deg: Double, _ w: Int, _ h: Int) -> Double {
        guard deg != 0, w > 0, h > 0 else { return 1 }
        let t = abs(deg) * .pi / 180
        return cos(t) + Double(max(w, h)) / Double(min(w, h)) * sin(t)
    }

    /// Natural cubic spline through the points, sampled at n+1 steps on 0...1 (RawTherapee "1;" = spline).
    static func splineLUT(_ pts: [(Double, Double)], n: Int = 255) -> [Double] {
        guard pts.count >= 2 else { return (0...n).map { Double($0) / Double(n) } }
        let x = pts.map { $0.0 }, y = pts.map { $0.1 }, k = pts.count
        var y2 = [Double](repeating: 0, count: k), u = [Double](repeating: 0, count: k)
        for i in 1..<(k - 1) {
            let sig = (x[i] - x[i - 1]) / (x[i + 1] - x[i - 1])
            let p = sig * y2[i - 1] + 2
            y2[i] = (sig - 1) / p
            u[i] = (y[i + 1] - y[i]) / (x[i + 1] - x[i]) - (y[i] - y[i - 1]) / (x[i] - x[i - 1])
            u[i] = (6 * u[i] / (x[i + 1] - x[i - 1]) - sig * u[i - 1]) / p
        }
        y2[k - 1] = 0
        for i in stride(from: k - 2, through: 0, by: -1) { y2[i] = y2[i] * y2[i + 1] + u[i] }
        return (0...n).map { s in
            let t = Double(s) / Double(n)
            var lo = 0, hi = k - 1
            while hi - lo > 1 { let m = (lo + hi) / 2; if x[m] > t { hi = m } else { lo = m } }
            let h = x[hi] - x[lo]
            guard h > 0 else { return min(1, max(0, y[lo])) }
            let a = (x[hi] - t) / h, b = (t - x[lo]) / h
            let v = a * y[lo] + b * y[hi] + ((a * a * a - a) * y2[lo] + (b * b * b - b) * y2[hi]) * h * h / 6
            return (min(1, max(0, v)) * 10000).rounded() / 10000
        }
    }

    func pipelineDict(_ pid: String, _ ph: PhotoEntry) -> [String: Any] {
        let e = ph.params
        let eng = engine(pid)
        let long = max(ph.w, ph.h)
        let proxy = EditEngine.pixelSize(eng.proxyURL(ph.ref)) ?? {
            let s = Double(min(eng.previewLong, long)) / Double(max(1, long))
            return (Int((Double(ph.w) * s).rounded()), Int((Double(ph.h) * s).rounded()))
        }()
        let scale = min(1, Double(max(proxy.0, proxy.1)) / Double(max(1, long)))
        let pp = pp3Sections(for: e, lutRoot: lutRoot, scale: scale, size: proxy)
        func num(_ v: String) -> Any {
            if v == "true" { return true }
            if v == "false" { return false }
            if let d = Double(v) { return d }
            return v
        }
        var raw: [String: Any] = [:]
        var sec: [String: [String: String]] = [:]
        for (name, pairs) in pp.sections {
            var d: [String: Any] = [:], s: [String: String] = [:]
            for (k, v) in pairs { d[k] = k == "Curve" ? v : num(v); s[k] = v }
            raw[name] = d; sec[name] = s
        }
        func dbl(_ s: String, _ k: String) -> Double? { sec[s]?[k].flatMap(Double.init) }

        // Tone curve (Exposure tool, FilmLike mode).
        var points: [[Double]] = []
        if let c = sec["Exposure"]?["Curve"], c.hasPrefix("1;") {
            let v = c.split(separator: ";").dropFirst().compactMap { Double($0) }
            points = stride(from: 0, to: v.count - 1, by: 2).map { [v[$0], v[$0 + 1]] }
        }
        let curve: [String: Any] = [
            "mode": "FilmLike", "type": points.isEmpty ? "linear" : "spline",
            "points": points, "lut": Self.splineLUT(points.map { ($0[0], $0[1]) }),
        ]
        var out: [String: Any] = [
            "scale": (scale * 10000).rounded() / 10000,
            "exposure": ["compensation": e.exposure, "clip": 0.02,
                         "highlightCompression": dbl("Exposure", "HighlightCompr") ?? 0, "highlightCompressionThreshold": 0,
                         "saturation": e.saturation],
            "curve": curve,
            // Saturated-colour protection: RawTherapee Lab adjustments "Chromaticity" (0 = off), applied before the film LUT.
            "labChromaticity": e.chromaGuard,
            "pp3": raw,
            "pp3Text": pp.text,
        ]
        if let s = sec["Shadows & Highlights"] {
            out["shadowsHighlights"] = ["shadows": Double(s["Shadows"] ?? "0") ?? 0, "highlights": 0, "shadowTonalWidth": 30,
                                        "highlightTonalWidth": 70, "radius": Double(s["Radius"] ?? "0") ?? 0]
        } else { out["shadowsHighlights"] = NSNull() }
        if let s = sec["Local Contrast"] {
            out["punch"] = ["radius": Double(s["Radius"] ?? "0") ?? 0, "amount": Double(s["Amount"] ?? "0") ?? 0, "darkness": 1, "lightness": 1]
        } else { out["punch"] = NSNull() }
        if let s = sec["Vibrance"] {
            out["vibrance"] = ["pastels": Double(s["Pastels"] ?? "0") ?? 0, "saturated": Double(s["Saturated"] ?? "0") ?? 0,
                               "protectSkins": true, "avoidColorShift": true, "linked": true]
        } else { out["vibrance"] = NSNull() }
        if let s = sec["ColorToning"] {
            let a = Double(s["LabGridALow"] ?? "0") ?? 0, b = Double(s["LabGridBLow"] ?? "0") ?? 0
            out["lab"] = ["a": (a / 983.04 * 1000).rounded() / 1000, "b": (b / 983.04 * 1000).rounded() / 1000,
                          "pp3": ["LabGridALow": a, "LabGridBLow": b, "LabGridAHigh": a, "LabGridBHigh": b], "method": "LabGrid", "unitsPerLab": 983.04]
        } else { out["lab"] = ["a": 0, "b": 0, "pp3": NSNull(), "method": "LabGrid", "unitsPerLab": 983.04] }
        if sec["Film Simulation"] != nil {
            out["film"] = ["path": e.film, "url": Self.lutURL(e.film), "strength": e.filmStrength, "strengthFraction": e.filmStrength / 100]
        } else { out["film"] = NSNull() }
        if let s = sec["PCVignette"] {
            out["vignette"] = ["strength": Double(s["Strength"] ?? "0") ?? 0, "feather": 60, "roundness": 50, "units": "stops at the corners (RawTherapee PCVignette)"]
        } else { out["vignette"] = NSNull() }
        if let s = sec["Sharpening"] {
            out["sharpen"] = ["method": "rld", "radius": 0.6, "amount": Double(s["DeconvAmount"] ?? "0") ?? 0, "damping": 0, "iterations": 20]
        } else { out["sharpen"] = NSNull() }
        if let b = Balance(e) {
            out["balance"] = ["shadow": ["a": b.sa, "b": b.sb], "highlight": ["a": b.ha, "b": b.hb],
                              "units": "Lab a*/b* (slider * 0.3)", "weights": Balance.weightsDoc, "appliedAfter": "RawTherapee, before grain and the frame"]
        } else { out["balance"] = NSNull() }
        if let g = GrainSpec(e, id: ph.id), g.amount > 0 {
            let m = Grain.sizeMix(g.size)
            out["grain"] = ["amount": g.amount, "size": g.size, "seed": String(g.seed, radix: 16),
                            "cellsAcrossLongEdge": Grain.cells, "cellPxAtProxy": Double(max(proxy.0, proxy.1)) / Grain.cells,
                            "fineWeight": m.fine, "clumpCells": m.clump, "clumpWeight": m.clumpWeight,
                            "sd": g.amount / 100 * 0.075, "midtoneWeight": "0.15 + 0.85 * 4 * Y * (1 - Y), Y = Rec.709 luma of the encoded RGB",
                            "monochrome": true, "appliedAfter": "RawTherapee, on sRGB-encoded values, before the frame"]
        } else { out["grain"] = NSNull() }
        var geo: [String: Any] = ["width": ph.w, "height": ph.h, "proxyW": proxy.0, "proxyH": proxy.1,
                                  "rotate": e.rotate, "rotateDirection": "positive = counter-clockwise",
                                  "autofillScale": (Self.autofillScale(e.rotate, ph.w, ph.h) * 100000).rounded() / 100000,
                                  "order": "rotate about the centre, scale by autofillScale about the centre (frame stays width x height), then crop"]
        if let c = e.crop, !c.isFullFrame {
            geo["crop"] = ["aspect": c.aspect, "x": c.x, "y": c.y, "w": c.w, "h": c.h]
            let r = c.pixels(width: proxy.0, height: proxy.1)
            geo["cropProxyPixels"] = ["x": r.x, "y": r.y, "w": r.w, "h": r.h]
            let f = c.pixels(width: ph.w, height: ph.h)
            geo["cropPixels"] = ["x": f.x, "y": f.y, "w": f.w, "h": f.h]
            geo["outputW"] = f.w; geo["outputH"] = f.h
        } else {
            geo["crop"] = NSNull(); geo["outputW"] = ph.w; geo["outputH"] = ph.h
        }
        out["geometry"] = geo
        return out
    }
}
