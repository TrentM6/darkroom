import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Film-like grain, added after RawTherapee (previews and exports).
///
/// * The grain lives on a fixed grid of 3000 cells across the image's long edge (≈ 2 px per grain on a
///   26 MP frame), so a 1600 px preview and a 6240 px export carry the same grain pattern; each is
///   resampled from the grid with vImage (Lanczos), which averages the grain down in the preview
///   exactly as viewing the export at that size would.
/// * Size = how grains clump: fine (small clumps), medium, coarse (larger, stronger clumps). Every size
///   keeps the crisp individual grains, so coarse is "grainier", never a soft mottle.
/// * Cells come from a hash of (photo seed, cell x, y): deterministic, and independent of the output
///   size or aspect rounding.
/// * Clumped, slightly soft: two octaves (cells + half-resolution clumps), lightly blurred.
/// * Monochrome: the same offset on R, G and B; weighted toward the midtones (film response).
public struct GrainSpec: Equatable {
    public var amount: Double      // 0...100
    public var size: String        // fine | medium | coarse
    public var seed: UInt64
    /// The colour balance by tone (Balance.swift), done in the same pass, before the grain. nil = none.
    public var balance: Balance? = nil
    public init(amount: Double, size: String, seed: UInt64) { self.amount = amount; self.size = size; self.seed = seed }
    /// The pass after RawTherapee: grain and/or colour balance; nil when the photo has neither.
    public init?(_ e: EditParams, id: String) {
        let bal = Balance(e)
        guard e.grain > 0 || bal != nil else { return nil }
        self.init(amount: e.grain, size: e.grainSize, seed: Grain.seed(id))
        balance = bal
    }
}

public let grainSizes = ["fine", "medium", "coarse"]

enum Grain {
    static func seed(_ id: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    static let cells = 3000.0
    /// (weight of single grains, clump size in grains, weight of clumps)
    static func sizeMix(_ size: String) -> (fine: Float, clump: Float, clumpWeight: Float) {
        size == "coarse" ? (0.75, 4, 1.05) : size == "medium" ? (0.85, 2.8, 0.8) : (1, 2, 0.45)
    }

    @inline(__always) static func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9e3779b97f4a7c15
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }

    /// ~Gaussian value for a cell (sum of 4 uniforms), mean 0, sd 1.
    @inline(__always) static func cell(_ seed: UInt64, _ x: Int, _ y: Int) -> Float {
        let h = mix(seed ^ (UInt64(truncatingIfNeeded: x) &* 0x632be59bd9b4e019) ^ (UInt64(truncatingIfNeeded: y) &* 0x8cb92ba72f3d8dd7))
        let a = Float(h & 0xffff), b = Float((h >> 16) & 0xffff), c = Float((h >> 32) & 0xffff), d = Float(h >> 48)
        return ((a + b + c + d) / 65535 - 2) * 1.7320508   // sd of the sum of 4 U(0,1) = sqrt(1/3)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [(key: String, w: Int, h: Int, data: [Float])] = []

    /// The grain grid for an image of aspect w:h (normalized: sd 1).
    static func grid(_ spec: GrainSpec, width: Int, height: Int) -> (data: [Float], w: Int, h: Int) {
        let n = cells
        let long = Double(max(width, height))
        let gw = max(8, Int((n * Double(width) / long).rounded())), gh = max(8, Int((n * Double(height) / long).rounded()))
        let key = "\(spec.seed)-\(spec.size)-\(gw)x\(gh)"
        lock.lock()
        if let hit = cache.first(where: { $0.key == key }) { lock.unlock(); return (hit.data, hit.w, hit.h) }
        lock.unlock()

        var g = [Float](repeating: 0, count: gw * gh)
        let s1 = spec.seed, s2 = mix(spec.seed ^ 0x5bd1e995)
        let (wf, cs, wc) = sizeMix(spec.size)
        g.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: gh) { y in
                for x in 0..<gw {
                    // single grains + clumps (smoothstep-interpolated coarser cells): the clustered look of film grain
                    let fx = Float(x) / cs, fy = Float(y) / cs
                    let x0 = Int(fx), y0 = Int(fy)
                    var tx = fx - Float(x0), ty = fy - Float(y0)
                    tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty)
                    let c00 = cell(s2, x0, y0), c10 = cell(s2, x0 + 1, y0), c01 = cell(s2, x0, y0 + 1), c11 = cell(s2, x0 + 1, y0 + 1)
                    let clump = (c00 * (1 - tx) + c10 * tx) * (1 - ty) + (c01 * (1 - tx) + c11 * tx) * ty
                    p[y * gw + x] = wf * cell(s1, x, y) + wc * clump
                }
            }
        }
        // Round the grains off a little (3x3 kernel, mostly centre) so they aren't square pixels.
        var out = [Float](repeating: 0, count: gw * gh)
        let k: [Float] = [1, 2, 1, 2, 12, 2, 1, 2, 1].map { $0 / 24 }
        g.withUnsafeMutableBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var s = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(gh), width: vImagePixelCount(gw), rowBytes: gw * 4)
                var d = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(gh), width: vImagePixelCount(gw), rowBytes: gw * 4)
                _ = vImageConvolve_PlanarF(&s, &d, nil, 0, 0, k, 3, 3, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        // Normalize to sd 1.
        var mean: Float = 0, sd: Float = 0
        vDSP_normalize(out, 1, nil, 1, &mean, &sd, vDSP_Length(out.count))
        if sd > 0 { var m = -mean, inv = 1 / sd; vDSP_vsadd(out, 1, &m, &out, 1, vDSP_Length(out.count)); vDSP_vsmul(out, 1, &inv, &out, 1, vDSP_Length(out.count)) }

        lock.lock()
        cache.insert((key, gw, gh, out), at: 0)
        if cache.count > 3 { cache.removeLast() }
        lock.unlock()
        return (out, gw, gh)
    }

    /// The grain field resampled to width x height.
    static func field(_ spec: GrainSpec, width: Int, height: Int) -> [Float] {
        var (g, gw, gh) = grid(spec, width: width, height: height)
        var f = [Float](repeating: 0, count: width * height)
        g.withUnsafeMutableBufferPointer { src in
            f.withUnsafeMutableBufferPointer { dst in
                var s = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(gh), width: vImagePixelCount(gw), rowBytes: gw * 4)
                var d = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                _ = vImageScale_PlanarF(&s, &d, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        return f
    }

    /// Adds grain to an image (8 or 16 bits per channel). Returns an RGBX image of the same depth.
    static func apply(_ img: CGImage, _ spec0: GrainSpec) -> CGImage? {
        var img = img, spec = spec0
        if let b = spec.balance, let balanced = b.apply(img) { img = balanced }
        guard spec.amount > 0 else { return img }
        spec.balance = nil
        let w = img.width, h = img.height
        let deep = img.bitsPerComponent >= 16
        let cs = (img.colorSpace?.model == .rgb ? img.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | (deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0, space: cs, bitmapInfo: info),
              let base = ctx.data else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let field = Self.field(spec, width: w, height: h)
        let rowBytes = ctx.bytesPerRow
        let amp = Float(min(100, max(0, spec.amount)) / 100 * 0.075)      // sd at the midtones, fraction of full scale
        field.withUnsafeBufferPointer { fb in
            let fp = fb.baseAddress!
            DispatchQueue.concurrentPerform(iterations: h) { y in
                // CGContext rows are top-down in memory.
                let n = fp + y * w
                if deep {
                    let row = (base + y * rowBytes).assumingMemoryBound(to: UInt16.self)
                    for x in 0..<w {
                        let r = Float(row[x * 4]), g = Float(row[x * 4 + 1]), b = Float(row[x * 4 + 2])
                        let Y = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 65535
                        let wgt = 0.15 + 0.85 * 4 * Y * (1 - Y)
                        let d = amp * wgt * n[x] * 65535
                        row[x * 4] = UInt16(min(65535, max(0, r + d)))
                        row[x * 4 + 1] = UInt16(min(65535, max(0, g + d)))
                        row[x * 4 + 2] = UInt16(min(65535, max(0, b + d)))
                    }
                } else {
                    let row = (base + y * rowBytes).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<w {
                        let r = Float(row[x * 4]), g = Float(row[x * 4 + 1]), b = Float(row[x * 4 + 2])
                        let Y = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
                        let wgt = 0.15 + 0.85 * 4 * Y * (1 - Y)
                        let d = amp * wgt * n[x] * 255
                        row[x * 4] = UInt8(min(255, max(0, (r + d).rounded())))
                        row[x * 4 + 1] = UInt8(min(255, max(0, (g + d).rounded())))
                        row[x * 4 + 2] = UInt8(min(255, max(0, (b + d).rounded())))
                    }
                }
            }
        }
        return ctx.makeImage()
    }

    /// Grain on a JPEG file in place (previews), keeping its colour profile.
    @discardableResult
    static func applyToJPEG(_ url: URL, _ spec: GrainSpec, quality: Double = 0.9) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let out = apply(img, spec) else { return false }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).jpg")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: tmp); return false }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        try? FileManager.default.removeItem(at: tmp)
        return true
    }
}
