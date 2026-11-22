import CoreGraphics
import Foundation
import ImageIO

/// Colour balance by tone: separate a*/b* corrections for the shadows and the highlights, blended through the
/// midtones. Made for film scans, whose casts differ by tone (blue-green shadows, pink highlights), but works on
/// anything. Applied after RawTherapee on the sRGB-encoded result, with exactly the formula the editor's GPU
/// preview uses (gpu.js, "balance"), so what you see while dragging is what renders and exports.
///
///   t  = smoothstep(15, 85, L)                       0 in the shadows, 1 in the highlights
///   ws = (1 - t) * smoothstep(0, 12, L)              pure black stays neutral
///   wh = t * (1 - smoothstep(97, 100, L))            pure white stays neutral
///   a += sa * ws + ha * wh;   b += sb * ws + hb * wh  (Lab units; slider * 0.3, like warmth and tint)
public struct Balance: Equatable {
    public var sa: Double, sb: Double, ha: Double, hb: Double

    public init?(_ e: EditParams) {
        guard e.hasBalance else { return nil }
        sa = e.shadowTint * 0.3; sb = e.shadowWarmth * 0.3; ha = e.highlightTint * 0.3; hb = e.highlightWarmth * 0.3
    }

    static let weightsDoc = "t = smoothstep(15, 85, L); shadows (1 - t) * smoothstep(0, 12, L); highlights t * (1 - smoothstep(97, 100, L))"

    @inline(__always) static func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t)
    }
    @inline(__always) static func weights(_ L: Float) -> (Float, Float) {
        let t = smooth(15, 85, L)
        return ((1 - t) * smooth(0, 12, L), t * (1 - smooth(97, 100, L)))
    }

    // sRGB <-> linear, and linear sRGB <-> Lab (D65), as in gpu.js.
    @inline(__always) static func toLin(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4) }
    @inline(__always) static func toGam(_ c0: Float) -> Float { let c = max(0, c0); return c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055 }
    @inline(__always) static func f(_ t: Float) -> Float { t > 0.008856 ? cbrtf(t) : 7.787 * t + 16 / 116 }
    @inline(__always) static func fInv(_ t: Float) -> Float { t > 0.206897 ? t * t * t : (t - 16 / 116) / 7.787 }
    @inline(__always) static func lab(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        let fx = f(max(0, x)), fy = f(max(0, y)), fz = f(max(0, z))
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
    @inline(__always) static func rgb(_ L: Float, _ a: Float, _ b: Float) -> (Float, Float, Float) {
        let fy = (L + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        let x = fInv(fx) * 0.95047, y = fInv(fy), z = fInv(fz) * 1.08883
        return (3.2404542 * x - 1.5371385 * y - 0.4985314 * z, -0.9692660 * x + 1.8760108 * y + 0.0415560 * z, 0.0556434 * x - 0.2040259 * y + 1.0572252 * z)
    }

    /// The balanced image (8 or 16 bits per channel; returns the same depth, RGBX).
    func apply(_ img: CGImage) -> CGImage? {
        let w = img.width, h = img.height, deep = img.bitsPerComponent >= 16
        let cs = (img.colorSpace?.model == .rgb ? img.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | (deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0, space: cs, bitmapInfo: info),
              let base = ctx.data else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let rowBytes = ctx.bytesPerRow
        let sa = Float(self.sa), sb = Float(self.sb), ha = Float(self.ha), hb = Float(self.hb)
        // Encoded -> linear by table (exact per code value).
        let n = deep ? 65536 : 256, maxV = Float(n - 1)
        var lin = [Float](repeating: 0, count: n)
        for i in 0..<n { lin[i] = Self.toLin(Float(i) / maxV) }
        lin.withUnsafeBufferPointer { lt in
            DispatchQueue.concurrentPerform(iterations: h) { y in
                func px(_ r: Int, _ g: Int, _ b: Int) -> (Float, Float, Float) {
                    let (L, a, bb) = Self.lab(lt[r], lt[g], lt[b])
                    let (ws, wh) = Self.weights(L)
                    let (R, G, B) = Self.rgb(L, a + sa * ws + ha * wh, bb + sb * ws + hb * wh)
                    return (Self.toGam(R), Self.toGam(G), Self.toGam(B))
                }
                if deep {
                    let row = (base + y * rowBytes).assumingMemoryBound(to: UInt16.self)
                    for x in 0..<w {
                        let (r, g, b) = px(Int(row[x * 4]), Int(row[x * 4 + 1]), Int(row[x * 4 + 2]))
                        row[x * 4] = UInt16(min(65535, max(0, (r * 65535).rounded())))
                        row[x * 4 + 1] = UInt16(min(65535, max(0, (g * 65535).rounded())))
                        row[x * 4 + 2] = UInt16(min(65535, max(0, (b * 65535).rounded())))
                    }
                } else {
                    let row = (base + y * rowBytes).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<w {
                        let (r, g, b) = px(Int(row[x * 4]), Int(row[x * 4 + 1]), Int(row[x * 4 + 2]))
                        row[x * 4] = UInt8(min(255, max(0, (r * 255).rounded())))
                        row[x * 4 + 1] = UInt8(min(255, max(0, (g * 255).rounded())))
                        row[x * 4 + 2] = UInt8(min(255, max(0, (b * 255).rounded())))
                    }
                }
            }
        }
        return ctx.makeImage()
    }

    /// The cast still in an image, in the shadows and in the highlights: the median a*/b* of near-neutral pixels
    /// (low chroma: greys, whites, concrete, sky haze) in each band. Strongly coloured things don't count. nil for
    /// a band with too few neutral pixels to judge.
    static func measure(_ img: CGImage) -> (shadow: (a: Double, b: Double)?, highlight: (a: Double, b: Double)?) {
        let w = img.width, h = img.height
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let base = ctx.data else { return (nil, nil) }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = base.assumingMemoryBound(to: UInt8.self)
        var lin = [Float](repeating: 0, count: 256)
        for i in 0..<256 { lin[i] = toLin(Float(i) / 255) }
        var sh: [(Float, Float)] = [], hi: [(Float, Float)] = []
        sh.reserveCapacity(w * h / 8); hi.reserveCapacity(w * h / 8)
        let step = max(1, Int((Double(w * h) / 400_000).squareRoot()))
        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: 0, to: w, by: step) {
                let o = (y * w + x) * 4
                let (L, a, b) = lab(lin[Int(p[o])], lin[Int(p[o + 1])], lin[Int(p[o + 2])])
                guard (a * a + b * b).squareRoot() < 16 else { continue }
                let (ws, wh) = weights(L)
                if ws > 0.6 { sh.append((a, b)) } else if wh > 0.6 { hi.append((a, b)) }
            }
        }
        let total = max(1, (h / step) * (w / step))
        func median(_ v: [(Float, Float)]) -> (a: Double, b: Double)? {
            guard v.count >= max(200, total / 200) else { return nil }
            let a = v.map { $0.0 }.sorted(), b = v.map { $0.1 }.sorted()
            return (Double(a[a.count / 2]), Double(b[b.count / 2]))
        }
        return (median(sh), median(hi))
    }
}

extension Studio {
    /// Neutralize: the shadow and highlight balance that cancels the cast left in the photo's current render.
    /// Returns slider values (the current ones plus the correction), clamped; a band too colourful to judge keeps
    /// its value. The editor applies them like any edit (one undo step).
    public func neutralize(_ pid: String, _ id: String) throws -> [String: Any] {
        guard let ph = sync({ photoIndex(pid, id).flatMap { projects[pid]?.photos[$0] } }) else { throw StudioError.notFound("no photo \(id) in \(pid)") }
        let eng = engine(pid)
        if !FileManager.default.fileExists(atPath: eng.previewURL(ph.ref).path) { renderNow(pid, id, interactive: false) }
        guard let src = CGImageSourceCreateWithURL(eng.previewURL(ph.ref) as CFURL, nil), let img = Pixels.load(src, maxPixel: 900) else {
            throw StudioError.failed("the photo's preview isn't ready yet")
        }
        let m = Balance.measure(img), e = ph.params
        func q(_ v: Double) -> Double { min(50, max(-50, v.rounded())) }
        var out: [String: Any] = ["shadowWarmth": e.shadowWarmth, "shadowTint": e.shadowTint, "highlightWarmth": e.highlightWarmth, "highlightTint": e.highlightTint]
        // Small residuals (under one slider step) are left alone so Neutralize settles instead of hunting.
        if let s = m.shadow {
            if abs(s.b) >= 0.3 { out["shadowWarmth"] = q(e.shadowWarmth - s.b / 0.3) }
            if abs(s.a) >= 0.3 { out["shadowTint"] = q(e.shadowTint - s.a / 0.3) }
        }
        if let hgh = m.highlight {
            if abs(hgh.b) >= 0.3 { out["highlightWarmth"] = q(e.highlightWarmth - hgh.b / 0.3) }
            if abs(hgh.a) >= 0.3 { out["highlightTint"] = q(e.highlightTint - hgh.a / 0.3) }
        }
        func cast(_ c: (a: Double, b: Double)?) -> Any {
            guard let c else { return NSNull() }
            let a: Double = (c.a * 10).rounded() / 10, b: Double = (c.b * 10).rounded() / 10
            return ["a": a, "b": b] as [String: Double]
        }
        out["measured"] = ["shadow": cast(m.shadow), "highlight": cast(m.highlight)] as [String: Any]
        return out
    }
}
