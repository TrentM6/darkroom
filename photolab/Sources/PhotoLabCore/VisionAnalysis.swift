import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Apple's on-device Vision framework: free, offline, built into macOS.
struct VisionResult {
    var faces: [VNFaceObservation] = []
    var qualities: [Double?] = []
    var people = 0
    var saliency: [Float] = []
    var saliencyW = 0
    var saliencyH = 0
    var salientObjects: [[Double]] = []
    var horizonDegrees: Double? = nil
    var tags: [Tag] = []
    var featurePrint: VNFeaturePrintObservation? = nil
}

/// Vision rects are normalized with a bottom-left origin; convert to top-left [x, y, w, h].
func topLeft(_ r: CGRect) -> [Double] {
    [Double(r.minX), Double(1 - r.maxY), Double(r.width), Double(r.height)]
}

func runVision(_ cg: CGImage) -> VisionResult {
    var out = VisionResult()
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])

    let faces = VNDetectFaceLandmarksRequest()
    // People: full-body detection misses most people in a crowd (legs hidden), so also run the
    // upper-body detector and keep the larger count.
    let humans = VNDetectHumanRectanglesRequest()
    humans.upperBodyOnly = false
    let upper = VNDetectHumanRectanglesRequest()
    upper.upperBodyOnly = true
    let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
    let horizon = VNDetectHorizonRequest()
    let classify = VNClassifyImageRequest()
    let print = VNGenerateImageFeaturePrintRequest()
    try? handler.perform([faces, humans, upper, saliency, horizon, classify, print])

    out.faces = (faces.results ?? []).filter { $0.boundingBox.width * $0.boundingBox.height > 0.0004 }
    if !out.faces.isEmpty {
        let q = VNDetectFaceCaptureQualityRequest()
        q.inputFaceObservations = out.faces
        try? handler.perform([q])
        let res = q.results ?? []
        out.qualities = out.faces.indices.map { i in i < res.count ? res[i].faceCaptureQuality.map { Double($0) } : nil }
    }
    out.people = max(humans.results?.count ?? 0, upper.results?.count ?? 0)

    if let s = saliency.results?.first {
        out.salientObjects = (s.salientObjects ?? []).map { topLeft($0.boundingBox) }
        let pb = s.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        if let base = CVPixelBufferGetBaseAddress(pb) {
            var vals = [Float](repeating: 0, count: w * h)
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<w { vals[y * w + x] = row[x] }
            }
            out.saliency = vals; out.saliencyW = w; out.saliencyH = h
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    }
    if let hz = horizon.results?.first {
        // Same sign as `horizonTilt` (checked on this shoot: a line rising to the right reads negative).
        out.horizonDegrees = round2(Double(hz.angle) * 180 / .pi)
    }
    out.tags = (classify.results ?? [])
        .filter { $0.confidence >= 0.25 }
        .sorted { $0.confidence > $1.confidence }
        .prefix(10)
        .map { Tag(label: $0.identifier.replacingOccurrences(of: "_", with: " "), confidence: round2(Double($0.confidence))) }
    out.featurePrint = print.results?.first
    return out
}

/// Eye openness = height / width of the eye contour (Vision landmarks).
func eyeOpenness(_ region: VNFaceLandmarkRegion2D?) -> Double? {
    guard let pts = region?.normalizedPoints, pts.count >= 4 else { return nil }
    let xs = pts.map { Double($0.x) }, ys = pts.map { Double($0.y) }
    let w = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
    guard w > 0 else { return nil }
    return round2(h / w)
}

/// Rules for faces and eyes.
enum FaceRules {
    static let minEyeFacePixels = 80.0   // face width in the 2560 px Vision image
    static let minEyeQuality = 0.35      // Vision face capture quality
    static let closedOpenness = 0.16     // eye contour height / width
    static let subjectArea = 0.003       // a face is the subject only above 0.3% of the frame
}

/// Sunglasses: the eye band is much darker than the cheeks and nearly flat (a lens, not an eye).
func wearsSunglasses(_ luma: Plane, face fo: VNFaceObservation) -> Bool {
    guard let le = fo.landmarks?.leftEye?.normalizedPoints, let re = fo.landmarks?.rightEye?.normalizedPoints,
          le.count >= 4, re.count >= 4 else { return false }
    let bb = fo.boundingBox
    let bx = Double(bb.minX), by = Double(bb.minY), bw = Double(bb.width), bh = Double(bb.height)
    var pts: [(x: Double, y: Double)] = []
    for q in le + re {
        let px: Double = bx + Double(q.x) * bw
        let py: Double = 1 - (by + Double(q.y) * bh)
        pts.append((x: px, y: py))
    }
    let ex0 = pts.map { $0.x }.min()!, ex1 = pts.map { $0.x }.max()!
    let ey0 = pts.map { $0.y }.min()!, ey1 = pts.map { $0.y }.max()!
    let fh = Double(bb.height), fw = Double(bb.width)
    func stats(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> (mean: Double, sd: Double)? {
        let W = Double(luma.width), H = Double(luma.height)
        let a = max(0, Int(x0 * W)), b = min(luma.width, Int(x1 * W)), c = max(0, Int(y0 * H)), d = min(luma.height, Int(y1 * H))
        guard b > a + 2, d > c + 2 else { return nil }
        var s = 0.0, s2 = 0.0, n = 0.0
        var y = c
        while y < d { var x = a; while x < b { let v = Double(luma.data[y * luma.width + x]); s += v; s2 += v * v; n += 1; x += 2 }; y += 2 }
        let m = s / n
        return (m, sqrt(max(0, s2 / n - m * m)))
    }
    // Eye band: the eye contours, widened to where lenses sit. Cheeks: below the eyes, above the mouth.
    guard let eye = stats(ex0 - 0.02 * fw, ey0 - 0.04 * fh, ex1 + 0.02 * fw, ey1 + 0.06 * fh),
          let cheek = stats(ex0, ey1 + 0.12 * fh, ex1, ey1 + 0.28 * fh) else { return false }
    if ProcessInfo.processInfo.environment["PHOTOLAB_DEBUG"] != nil {
        FileHandle.standardError.write(String(format: "  face %.3f,%.3f w %.3f  eye band %.0f (sd %.0f)  cheek %.0f (sd %.0f)\n",
            Double(bb.minX), 1 - Double(bb.maxY), fw, eye.mean, eye.sd, cheek.mean, cheek.sd).data(using: .utf8)!)
    }
    // Calibrated on this shoot: sunglasses read 29-39 (ratio 0.46-0.61); 8088's bare squinting eyes 80.
    return eye.mean < 50 && eye.mean < 0.7 * cheek.mean
}
