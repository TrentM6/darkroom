import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 8-bit sRGB, RGBX, row 0 = top of the image.
struct RGBAImage {
    let width: Int
    let height: Int
    var data: [UInt8]
}

/// Single-channel float plane.
struct Plane {
    let width: Int
    let height: Int
    var data: [Float]
}

enum Pixels {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// sRGB-encoded 8-bit value -> linear light 0...1
    static let toLinear: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    /// linear light quantized to 4096 steps -> sRGB-encoded 0...255 bin
    static let linearToBin: [Int] = (0..<4096).map { i in
        let l = Float(i) / 4095
        let c = l <= 0.0031308 ? l * 12.92 : 1.055 * powf(l, 1 / 2.4) - 0.055
        return min(255, max(0, Int((c * 255).rounded())))
    }

    /// Oriented image decoded by ImageIO, optionally downscaled (JPEG DCT scaling where possible).
    static func load(_ src: CGImageSource, maxPixel: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func rgba(_ cg: CGImage, width: Int? = nil, height: Int? = nil) -> RGBAImage {
        let w = width ?? cg.width, h = height ?? cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return RGBAImage(width: w, height: h, data: data)
    }

    static func downscaled(_ cg: CGImage, longEdge: Int) -> RGBAImage {
        let s = Double(longEdge) / Double(max(cg.width, cg.height))
        return rgba(cg, width: max(1, Int((Double(cg.width) * s).rounded())), height: max(1, Int((Double(cg.height) * s).rounded())))
    }

    /// Encoded (perceptual) luma Y' in 0...255, Rec.709 weights on encoded values.
    static func luma(_ img: RGBAImage) -> Plane {
        let n = img.width * img.height
        var out = [Float](repeating: 0, count: n)
        img.data.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                for i in 0..<n {
                    let p = i * 4
                    o[i] = 0.2126 * Float(s[p]) + 0.7152 * Float(s[p + 1]) + 0.0722 * Float(s[p + 2])
                }
            }
        }
        return Plane(width: img.width, height: img.height, data: out)
    }

    /// 2x2 box downsample.
    static func half(_ p: Plane) -> Plane {
        let w = p.width / 2, h = p.height / 2
        var out = [Float](repeating: 0, count: w * h)
        p.data.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<h {
                    let r0 = (2 * y) * p.width, r1 = r0 + p.width
                    for x in 0..<w {
                        let c = 2 * x
                        o[y * w + x] = (s[r0 + c] + s[r0 + c + 1] + s[r1 + c] + s[r1 + c + 1]) * 0.25
                    }
                }
            }
        }
        return Plane(width: w, height: h, data: out)
    }

    /// Half-resolution BT.601 chroma planes (Cb, Cr centred on 0), like JPEG 4:2:0.
    static func chromaHalf(_ img: RGBAImage) -> (Plane, Plane) {
        let w = img.width / 2, h = img.height / 2
        var cb = [Float](repeating: 0, count: w * h), cr = cb
        img.data.withUnsafeBufferPointer { s in
            for y in 0..<h {
                for x in 0..<w {
                    var r: Float = 0, g: Float = 0, b: Float = 0
                    for dy in 0..<2 {
                        for dx in 0..<2 {
                            let p = ((2 * y + dy) * img.width + 2 * x + dx) * 4
                            r += Float(s[p]); g += Float(s[p + 1]); b += Float(s[p + 2])
                        }
                    }
                    r *= 0.25; g *= 0.25; b *= 0.25
                    cb[y * w + x] = -0.168736 * r - 0.331264 * g + 0.5 * b
                    cr[y * w + x] = 0.5 * r - 0.418688 * g - 0.081312 * b
                }
            }
        }
        return (Plane(width: w, height: h, data: cb), Plane(width: w, height: h, data: cr))
    }

    static func writeJPEG(_ cg: CGImage, to url: URL, quality: Double) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    static func writePNG(rgba: [UInt8], width: Int, height: Int, to url: URL) {
        var data = rgba
        let cg: CGImage? = data.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(data: ptr.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            return ctx?.makeImage()
        }
        guard let cg, let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }
}

// MARK: - Lab

struct Lab { var L: Float; var a: Float; var b: Float }

enum ColorMath {
    static func lab(r: UInt8, g: UInt8, b: UInt8) -> Lab {
        let R = Pixels.toLinear[Int(r)], G = Pixels.toLinear[Int(g)], B = Pixels.toLinear[Int(b)]
        let X = (0.4124564 * R + 0.3575761 * G + 0.1804375 * B) / 0.95047
        let Y = 0.2126729 * R + 0.7151522 * G + 0.0721750 * B
        let Z = (0.0193339 * R + 0.1191920 * G + 0.9503041 * B) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrtf(t) : (7.787 * t + 16 / 116) }
        let fx = f(X), fy = f(Y), fz = f(Z)
        return Lab(L: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    static func lstar(fromLinear y: Double) -> Double {
        y > 0.008856 ? 116 * cbrt(y) - 16 : 903.3 * y
    }

    static func hex(_ lab: Lab) -> String {
        let fy = (Double(lab.L) + 16) / 116
        let fx = fy + Double(lab.a) / 500, fz = fy - Double(lab.b) / 200
        func finv(_ t: Double) -> Double { t * t * t > 0.008856 ? t * t * t : (t - 16 / 116) / 7.787 }
        let X = finv(fx) * 0.95047, Y = finv(fy), Z = finv(fz) * 1.08883
        let rl = 3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z
        let gl = -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z
        let bl = 0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z
        func enc(_ c: Double) -> Int {
            let v = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(max(c, 0), 1 / 2.4) - 0.055
            return min(255, max(0, Int((v * 255).rounded())))
        }
        return String(format: "#%02X%02X%02X", enc(rl), enc(gl), enc(bl))
    }
}

func percentile(_ v: [Double], _ p: Double) -> Double? {
    guard !v.isEmpty else { return nil }
    let s = v.sorted()
    let idx = min(s.count - 1, max(0, Int((p * Double(s.count - 1)).rounded())))
    return s[idx]
}

func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
