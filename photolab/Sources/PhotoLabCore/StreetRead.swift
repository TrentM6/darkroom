import CoreGraphics
import Foundation
import Vision

// The "street read": how a street photographer would look at the frame (subject, moment, layering,
// light, colour, composition), measured deterministically from Apple's on-device Vision results and
// the pixels. No cloud, no generative model: every sentence below comes from fixed thresholds, so the
// same file always gets the same read. Rects are normalized [x, y, w, h] with a top-left origin.

public struct StreetPose: Codable {
    public var stride: Double?          // ankle spread / torso length (≈0.25 standing, 0.6+ mid-stride)
    public var lean: Double?            // torso angle from vertical, degrees
    public var gestures: [String]       // mid-stride, arm raised high, arm raised, hands to head, reaching, leaning, bent over
    public var facing: String           // toward | away | profile | unknown
    public var turn: String? = nil      // left | right: which way the head points in the image
    public var energy: Double           // 0...1
}

public struct StreetPerson: Codable {
    public var rect: [Double]
    public var tier: String             // near | mid | far
    public var height: Double           // estimated full-body height as a fraction of the frame height
    public var source: String           // body | pose | face (what found it)
    public var pose: StreetPose?
    public var faceYaw: Double?
    public var lookingAtCamera: Bool
    public var luminance: Double        // mean L* inside the figure
    public var hands: [[Double]]? = nil // wrist points [x, y]
}

public struct StreetLight: Codable {
    public var kind: String             // hard sun | sun, few shadows | backlit | soft / flat | mixed
    public var separation: Double       // L* gap between the lit and shadow halves of the frame
    public var shadowFraction: Double   // % of frame in deep shadow
    public var litFraction: Double      // % of frame brightly lit
    public var crispness: Double        // 0...1 share of light/shadow boundaries that are hard-edged
    public var shadowShapes: Double     // % of frame covered by large connected shadow shapes
    public var subject: String?         // lit | in shadow | silhouette | even
}

public struct StreetColor: Codable {
    public var families: [String: Double]   // % of the non-sky frame with chroma ≥ 30, by hue family
    public var strong: [String: Double]     // same with chroma ≥ 50
    public var skyFraction: Double
    public var chromatic: Double            // % of the non-sky frame with chroma ≥ 30
    public var complementary: [String]?
    public var accent: String?
    public var field: String?
    public var character: String            // muted | moderate | rich | busy
}

public struct StreetScore: Codable {
    public var total: Double
    public var subject: Double
    public var moment: Double
    public var layering: Double
    public var light: Double
    public var color: Double
    public var composition: Double
}

public struct StreetReport: Codable {
    public var people: [StreetPerson]
    public var mainSubject: Int?            // index into people
    public var subjectRect: [Double]?       // person, or the strongest salient object when no person anchors the frame
    public var subjectKind: String          // person | object | none
    public var subjectPlacement: String?
    public var tiers: [String: Int]
    public var gestureEnergy: Double
    public var eyeContact: Bool
    public var interaction: String?         // facing each other | hands meet | side by side
    public var figureGround: Double?        // colour difference ΔE between the subject and its surround
    public var overlap: Bool
    public var clutter: Double              // 0...1 edge density outside the sky
    public var surroundClutter: Double?     // same, in the ring around the subject
    public var saliencyFocus: Double        // share of attention in the main attention peak
    public var unexplainedPeak: [Double]?   // strong attention region no detected person covers
    public var darkFrame: [String]
    public var light: StreetLight
    public var color: StreetColor
    public var read: [String]
    public var strengths: [String]
    public var weaknesses: [String]
    public var score: StreetScore
}

/// Fixed weights for the street score (shown in the report).
public let streetWeights: [(String, Double)] = [
    ("subject", 0.25), ("moment", 0.25), ("layering", 0.10), ("light", 0.15), ("color", 0.15), ("composition", 0.10),
]

// MARK: - Pixel maps at 1/4 of the 1024 px Lab plane (≈256 px long edge)

struct StreetMaps {
    let w: Int, h: Int
    var L: [Float], A: [Float], B: [Float], grad: [Float], sky: [Bool]

    init(lab: [Lab], labW: Int, labH: Int) {
        w = max(1, labW / 4); h = max(1, labH / 4)
        L = [Float](repeating: 0, count: w * h); A = L; B = L; grad = L
        for y in 0..<h {
            for x in 0..<w {
                var l: Float = 0, a: Float = 0, b: Float = 0
                for dy in 0..<4 { for dx in 0..<4 { let p = lab[(y * 4 + dy) * labW + x * 4 + dx]; l += p.L; a += p.a; b += p.b } }
                L[y * w + x] = l / 16; A[y * w + x] = a / 16; B[y * w + x] = b / 16
            }
        }
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let gx = (L[y * w + x + 1] - L[y * w + x - 1]) * 0.5
                let gy = (L[(y + 1) * w + x] - L[(y - 1) * w + x]) * 0.5
                grad[y * w + x] = (gx * gx + gy * gy).squareRoot()
            }
        }
        // Sky: smooth, light, blue-to-cyan, connected to the top edge.
        var cand = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            let C = (A[i] * A[i] + B[i] * B[i]).squareRoot()
            var hue = atan2(B[i], A[i]) * 180 / .pi
            if hue < 0 { hue += 360 }
            // Deep skies (Classic Negative, polariser, vignetting) sit as low as L* 30.
            let blue = C >= 10 && hue >= 200 && hue <= 300 && L[i] > 25
            let pale = C < 10 && L[i] > 75
            cand[i] = (blue || pale) && grad[i] < 2.5 && i / w < Int(Double(h) * 0.75)
        }
        sky = [Bool](repeating: false, count: w * h)
        var stack: [Int] = (0..<w).filter { cand[$0] }
        for s in stack { sky[s] = true }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                let j = ny * w + nx
                if cand[j] && !sky[j] { sky[j] = true; stack.append(j) }
            }
        }
    }

    /// Index range for a normalized rect.
    func cells(_ r: [Double]) -> (Int, Int, Int, Int) {
        let x0 = max(0, min(w - 1, Int(r[0] * Double(w)))), y0 = max(0, min(h - 1, Int(r[1] * Double(h))))
        let x1 = max(x0 + 1, min(w, Int(((r[0] + r[2]) * Double(w)).rounded(.up))))
        let y1 = max(y0 + 1, min(h, Int(((r[1] + r[3]) * Double(h)).rounded(.up))))
        return (x0, y0, x1, y1)
    }

    /// Mean L, a, b, gradient inside `inner` but outside `hole`.
    func mean(_ inner: [Double], excluding hole: [Double]? = nil) -> (L: Double, a: Double, b: Double, g: Double, n: Int) {
        let (x0, y0, x1, y1) = cells(inner)
        var hx0 = -1, hy0 = -1, hx1 = -1, hy1 = -1
        if let hole { (hx0, hy0, hx1, hy1) = cells(hole) }
        var l = 0.0, a = 0.0, b = 0.0, g = 0.0, n = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                if x >= hx0 && x < hx1 && y >= hy0 && y < hy1 { continue }
                let i = y * w + x
                l += Double(L[i]); a += Double(A[i]); b += Double(B[i]); g += Double(grad[i]); n += 1
            }
        }
        guard n > 0 else { return (0, 0, 0, 0, 0) }
        return (l / Double(n), a / Double(n), b / Double(n), g / Double(n), n)
    }
}

// MARK: - People

private typealias Joint = VNHumanBodyPoseObservation.JointName

private struct Candidate {
    var rect: [Double]
    var source: String
    var joints: [Joint: CGPoint] = [:]     // top-left normalized
    var face: FaceReport? = nil
    var upperRect: [Double]? = nil
}

private func union(_ a: [Double], _ b: [Double]) -> [Double] {
    let x0 = min(a[0], b[0]), y0 = min(a[1], b[1])
    let x1 = max(a[0] + a[2], b[0] + b[2]), y1 = max(a[1] + a[3], b[1] + b[3])
    return [x0, y0, x1 - x0, y1 - y0]
}

private func interArea(_ a: [Double], _ b: [Double]) -> Double {
    let w = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
    let h = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
    return w > 0 && h > 0 ? w * h : 0
}

private func clampRect(_ r: [Double]) -> [Double] {
    let x0 = max(0, r[0]), y0 = max(0, r[1])
    let x1 = min(1, r[0] + r[2]), y1 = min(1, r[1] + r[3])
    return [x0, y0, max(0.001, x1 - x0), max(0.001, y1 - y0)]
}

private func contains(_ r: [Double], _ p: CGPoint, pad: Double = 0) -> Bool {
    let px = Double(p.x), py = Double(p.y)
    return px >= r[0] - pad * r[2] && px <= r[0] + r[2] * (1 + pad) && py >= r[1] - pad * r[3] && py <= r[1] + r[3] * (1 + pad)
}

private let streetDebug = ProcessInfo.processInfo.environment["STREET_DEBUG"] != nil

/// Joints with confidence ≥ 0.3, top-left normalized to the full frame. `roi` (bottom-left, normalized) maps
/// region-of-interest results back to the frame.
private func joints(_ o: VNHumanBodyPoseObservation, roi: CGRect? = nil) -> [Joint: CGPoint] {
    guard let pts = try? o.recognizedPoints(.all) else { return [:] }
    var j: [Joint: CGPoint] = [:]
    for (k, v) in pts where v.confidence >= 0.3 {
        var p = v.location
        if let roi { p = CGPoint(x: roi.minX + p.x * roi.width, y: roi.minY + p.y * roi.height) }
        j[k] = CGPoint(x: p.x, y: 1 - p.y)
    }
    return j
}

/// In crowds Vision sometimes stitches joints from different people into one skeleton. Drop limbs far too
/// long for the torso, and reject skeletons whose shoulders disagree with the torso or that sprawl sideways.
private func cleanPose(_ j0: [Joint: CGPoint], aspect: Double) -> [Joint: CGPoint]? {
    var j = j0
    guard j.count >= 5, j[.neck] != nil || j[.leftShoulder] != nil || j[.rightShoulder] != nil else { return nil }
    if let t = torso(j, aspect: aspect) {
        func d(_ a: Joint, _ b: Joint) -> Double? {
            guard let p = j[a], let q = j[b] else { return nil }
            return hypot(Double(p.x - q.x) * aspect, Double(p.y - q.y))
        }
        if let sw = d(.leftShoulder, .rightShoulder), j[.root] != nil, sw > 1.4 * t { return nil }   // (narrow is fine: profile)
        let chains: [[Joint]] = [[.leftShoulder, .leftElbow, .leftWrist], [.rightShoulder, .rightElbow, .rightWrist],
                                 [.leftHip, .leftKnee, .leftAnkle], [.rightHip, .rightKnee, .rightAnkle], [.neck, .nose]]
        for chain in chains {
            for k in 1..<chain.count {
                let maxLen = chain[0] == .leftHip || chain[0] == .rightHip ? 1.5 : 1.15
                if let len = d(chain[k - 1], chain[k]), len > maxLen * t {
                    for r in chain[k...] { j[r] = nil }
                    break
                }
            }
        }
        guard j.count >= 5 else { return nil }
    }
    let xs = j.values.map { Double($0.x) * aspect }, ys = j.values.map { Double($0.y) }
    let bw = xs.max()! - xs.min()!, bh = ys.max()! - ys.min()!
    if bw > 0.15 && bw > 1.25 * bh { return nil }
    return j
}

private func poseBox(_ j: [Joint: CGPoint], aspect: Double) -> [Double] {
    let xs = j.values.map { Double($0.x) }, ys = j.values.map { Double($0.y) }
    var r = [xs.min()!, ys.min()!, xs.max()! - xs.min()!, ys.max()! - ys.min()!]
    let t = torso(j, aspect: aspect) ?? max(r[3] * 0.35, 0.02)
    let padX = 0.18 * t / aspect
    r = [r[0] - padX, r[1] - 0.22 * t, r[2] + 2 * padX, r[3] + 0.27 * t]
    return clampRect(r)
}

private func detectPeople(_ image: CGImage, aspect: Double, faces: [FaceReport]) -> [Candidate] {
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    // Upper-body mode finds far more people than full-body mode in street frames (crowds, cropped figures).
    let humans = VNDetectHumanRectanglesRequest()
    humans.upperBodyOnly = true
    let pose = VNDetectHumanBodyPoseRequest()
    try? handler.perform([humans, pose])

    var cands: [Candidate] = (humans.results ?? []).filter { $0.confidence >= 0.5 }.map {
        let r = topLeft($0.boundingBox)
        return Candidate(rect: r, source: "body", upperRect: r)
    }
    let poses = (pose.results ?? []).compactMap { cleanPose(joints($0), aspect: aspect) }
    if streetDebug { FileHandle.standardError.write("  humans \(cands.map { $0.rect.map(round3) })\n  poses \(poses.map { poseBox($0, aspect: aspect).map(round3) })\n".data(using: .utf8)!) }

    for j in poses {
        let anchor = j[.neck] ?? j[.leftShoulder] ?? j[.rightShoulder]!
        let pb = poseBox(j, aspect: aspect)
        // Attach to an upper-body box only when the skeleton is about the same person's size.
        let fits = { (r: [Double]) in pb[3] <= 2.8 * r[3] + 0.03 && pb[2] <= 2.5 * r[2] + 0.03 && contains(r, anchor, pad: 0.1) }
        if let i = cands.indices.filter({ cands[$0].joints.isEmpty && fits(cands[$0].rect) })
            .max(by: { interArea(cands[$0].rect, pb) < interArea(cands[$1].rect, pb) }) {
            cands[i].joints = j
            cands[i].rect = union(cands[i].rect, pb)
        } else if j.count >= 6, let t = torso(j, aspect: aspect), t <= 0.28, pb[2] * aspect <= 0.9 * pb[3] {
            cands.append(Candidate(rect: pb, source: "pose", joints: j))
        }
    }

    // Second chance: re-run the pose model on the crop around each sizeable person it missed
    // (whole-frame pose often skips people who overlap others or are cut by the frame).
    var retries = 0
    for i in cands.indices where cands[i].joints.isEmpty && cands[i].rect[3] >= 0.12 && retries < 4 {
        let r = cands[i].rect
        let x0 = max(0, r[0] - r[2] * 0.35), x1 = min(1, r[0] + r[2] * 1.35)
        let y0 = max(0, r[1] - r[3] * 0.1), y1 = min(1, r[1] + r[3] * 2.3)
        let roi = CGRect(x: x0, y: 1 - y1, width: x1 - x0, height: y1 - y0)   // Vision: bottom-left origin
        let req = VNDetectHumanBodyPoseRequest()
        req.regionOfInterest = roi
        try? handler.perform([req])
        retries += 1
        let found = (req.results ?? []).compactMap { cleanPose(joints($0, roi: roi), aspect: aspect) }
            .filter { j in (j[.neck] ?? j[.leftShoulder] ?? j[.rightShoulder]).map { contains(r, $0, pad: 0.15) } ?? false }
        if let j = found.max(by: { $0.count < $1.count }) {
            cands[i].joints = j
            let pb = poseBox(j, aspect: aspect)
            if pb[3] <= 2.8 * r[3] + 0.03 && pb[2] <= 2.5 * r[2] + 0.03 { cands[i].rect = union(r, pb) }
        }
        if streetDebug { FileHandle.standardError.write("  roi-pose \(r.map(round3)) -> \(found.count) \(found.first.map { poseBox($0, aspect: aspect).map(round3) } ?? [])\n".data(using: .utf8)!) }
    }

    // Faces: attach to a person, or add a person for a face nobody else found.
    for f in faces where f.rect[3] >= 0.015 {
        let c = CGPoint(x: f.rect[0] + f.rect[2] / 2, y: f.rect[1] + f.rect[3] / 2)
        if let i = cands.indices.filter({ cands[$0].face == nil && contains(cands[$0].rect, c, pad: 0.05) })
            .min(by: { cands[$0].rect[2] * cands[$0].rect[3] < cands[$1].rect[2] * cands[$1].rect[3] }) {
            cands[i].face = f
        } else {
            let r = clampRect([f.rect[0] - f.rect[2] * 1.2, f.rect[1] - f.rect[3] * 0.3, f.rect[2] * 3.4, f.rect[3] * 7.5])
            cands.append(Candidate(rect: r, source: "face", face: f))
        }
    }
    // Merge near-duplicates.
    var out: [Candidate] = []
    for c in cands.sorted(by: { $0.rect[2] * $0.rect[3] > $1.rect[2] * $1.rect[3] }) {
        if let k = out.firstIndex(where: { interArea($0.rect, c.rect) > 0.6 * min($0.rect[2] * $0.rect[3], c.rect[2] * c.rect[3]) && ($0.joints.isEmpty || c.joints.isEmpty) }) {
            if out[k].joints.isEmpty { out[k].joints = c.joints }
            if out[k].face == nil { out[k].face = c.face }
            continue
        }
        out.append(c)
    }
    return out
}

/// Torso length (neck to root/hips) in frame-height units, x scaled by aspect.
private func torso(_ j: [Joint: CGPoint], aspect: Double) -> Double? {
    func d(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(Double(a.x - b.x) * aspect, Double(a.y - b.y)) }
    let hip = j[.root] ?? mid(j[.leftHip], j[.rightHip])
    let neck = j[.neck] ?? mid(j[.leftShoulder], j[.rightShoulder])
    if let hip, let neck { return d(hip, neck) }
    if let l = j[.leftShoulder], let r = j[.rightShoulder] { return d(l, r) * 1.5 }
    return nil
}

private func mid(_ a: CGPoint?, _ b: CGPoint?) -> CGPoint? {
    guard let a, let b else { return nil }
    return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
}

/// Gesture, stance and facing from the body-pose joints (and the face, when Vision found one).
private func readPose(_ j: [Joint: CGPoint], face: FaceReport?, aspect: Double) -> StreetPose? {
    guard !j.isEmpty, let t = torso(j, aspect: aspect), t > 0.01 else {
        if let face { return StreetPose(stride: nil, lean: nil, gestures: [], facing: facing(nil, face: face, aspect: aspect), turn: nil, energy: 0) }
        return nil
    }
    func X(_ p: CGPoint) -> Double { Double(p.x) * aspect }
    func Y(_ p: CGPoint) -> Double { Double(p.y) }
    var gestures: [String] = []
    var energy = 0.0

    var stride: Double? = nil
    if let la = j[.leftAnkle], let ra = j[.rightAnkle] {
        stride = round2(hypot(X(la) - X(ra), Y(la) - Y(ra)) / t)
    } else if let lk = j[.leftKnee], let rk = j[.rightKnee] {
        stride = round2(hypot(X(lk) - X(rk), Y(lk) - Y(rk)) / t * 0.8)
    }
    if let s = stride, s >= 0.6 {
        gestures.append("mid-stride")
        energy += min(0.5, 0.25 + (s - 0.6) * 0.6)
    } else if let s = stride, s >= 0.42 {
        gestures.append("walking")
        energy += 0.15
    }

    let shoulderY = [j[.leftShoulder], j[.rightShoulder], j[.neck]].compactMap { $0 }.map(Y).min()!
    let head = j[.nose] ?? j[.leftEye] ?? j[.rightEye] ?? j[.leftEar] ?? j[.rightEar]
    let headY = head.map(Y) ?? (shoulderY - 0.3 * t)
    let neck = j[.neck] ?? mid(j[.leftShoulder], j[.rightShoulder])
    var raisedHigh = false, raised = false, toHead = false, reach = false
    for (w, e) in [(j[.leftWrist], j[.leftElbow]), (j[.rightWrist], j[.rightElbow])] {
        guard let w else {
            // Elbow clearly above the shoulder with the hand lost: still an arm up.
            if let e, Y(e) < shoulderY - 0.1 * t { raised = true }
            continue
        }
        let nearHead = head.map { hypot(X($0) - X(w), Y($0) - Y(w)) < 0.45 * t } ?? false
        if nearHead && Y(w) < shoulderY { toHead = true }
        else if Y(w) < headY - 0.1 * t { raisedHigh = true }
        else if Y(w) < shoulderY - 0.05 * t { raised = true }
        if let n = neck, abs(X(w) - X(n)) > 0.95 * t, Y(w) < shoulderY + 0.9 * t { reach = true }
    }
    if raisedHigh { gestures.append("arm raised high"); energy += 0.6 }
    else if toHead { gestures.append("hands to head"); energy += 0.45 }
    else if raised { gestures.append("arm raised"); energy += 0.45 }
    if reach { gestures.append("reaching"); energy += 0.25 }

    var lean: Double? = nil
    let hip = j[.root] ?? mid(j[.leftHip], j[.rightHip])
    if let n = neck, let hip {
        let l = atan2(X(n) - X(hip), Y(hip) - Y(n)) * 180 / .pi
        lean = round1(l)
        if abs(l) >= 40 { gestures.append("bent over"); energy += 0.45 }
        else if abs(l) >= 17 { gestures.append("leaning"); energy += 0.2 }
    }
    // Head direction: nose offset from the neck, relative to the shoulder width.
    var turn: String? = nil
    if let nose = j[.nose], let n = neck {
        let sw = (j[.leftShoulder] != nil && j[.rightShoulder] != nil) ? abs(X(j[.leftShoulder]!) - X(j[.rightShoulder]!)) : 0
        let off = (X(nose) - X(n)) / max(sw, 0.35 * t)
        if off > 0.3 { turn = "right" } else if off < -0.3 { turn = "left" }
    }
    return StreetPose(stride: stride, lean: lean, gestures: gestures, facing: facing(j, face: face, aspect: aspect), turn: turn,
                      energy: round2(min(1, energy)))
}

private func facing(_ j: [Joint: CGPoint]?, face: FaceReport?, aspect: Double) -> String {
    if let face {
        if let y = face.yaw { return abs(y) >= 50 ? "profile" : "toward" }
        return "toward"
    }
    guard let j else { return "unknown" }
    let nose = j[.nose] != nil, le = j[.leftEye] != nil, re = j[.rightEye] != nil
    let ears = (j[.leftEar] != nil ? 1 : 0) + (j[.rightEar] != nil ? 1 : 0)
    if nose && le && re { return "toward" }
    if nose && (le || re) { return "profile" }
    if !nose && !le && !re && ears >= 1 {
        // Shoulders: the subject's left shoulder sits on image-left only when seen from behind.
        if let l = j[.leftShoulder], let r = j[.rightShoulder], l.x > r.x + 0.005 { return "unknown" }
        return "away"
    }
    if !nose && !le && !re, let l = j[.leftShoulder], let r = j[.rightShoulder] {
        return l.x < r.x - 0.005 ? "away" : "unknown"
    }
    return "unknown"
}

// MARK: - Analysis

/// Entry point, called from analyzePhoto with the 2560 px Vision image, the 1024 px Lab plane, the Vision result
/// (saliency) and the face reports it already computed. Runs two extra Vision requests (upper-body people,
/// body pose) once, plus a body-pose retry on up to four person crops.
func analyzeStreet(image: CGImage, lab: [Lab], labW: Int, labH: Int, vision v: VisionResult, faces: [FaceReport]) -> StreetReport {
    let aspect = Double(image.width) / Double(image.height)
    let maps = StreetMaps(lab: lab, labW: labW, labH: labH)
    let n = maps.w * maps.h

    // ---------------- People ----------------
    let cands = detectPeople(image, aspect: aspect, faces: faces)
    var people: [StreetPerson] = []
    for c in cands {
        var est: [Double] = []
        let hasFeet = c.joints[.leftAnkle] != nil || c.joints[.rightAnkle] != nil
        let hasHead = c.joints[.nose] != nil || c.joints[.neck] != nil || c.face != nil || c.upperRect != nil
        if hasFeet && hasHead { est.append(c.rect[3]) }
        if let u = c.upperRect { est.append(u[3] / 0.5) }
        if let f = c.face { est.append(f.rect[3] * 7.5) }
        if let t = torso(c.joints, aspect: aspect) { est.append(t * 3.1) }
        if est.isEmpty { est.append(c.rect[3]) }
        let height = hasFeet && hasHead ? max(c.rect[3], est.max()! * 0.8) : est.max()!
        // Cut by the bottom edge: the figure is at least as near as what is visible.
        let tier = height >= 0.62 ? "near" : height >= 0.2 ? "mid" : "far"
        let pose = readPose(c.joints, face: c.face, aspect: aspect)
        let inner = [c.rect[0] + c.rect[2] * 0.2, c.rect[1] + c.rect[3] * 0.1, c.rect[2] * 0.6, c.rect[3] * 0.8]
        let looking = (c.face?.yaw).map { abs($0) <= 20 } ?? false && (c.face?.rect[3] ?? 0) >= 0.03
        people.append(StreetPerson(rect: c.rect.map(round3), tier: tier, height: round2(height), source: c.source, pose: pose,
                                   faceYaw: c.face?.yaw, lookingAtCamera: looking, luminance: round1(maps.mean(inner).L),
                                   hands: [c.joints[.leftWrist], c.joints[.rightWrist]].compactMap { $0 }.map { [round3(Double($0.x)), round3(Double($0.y))] }))
    }
    // Drop tiny, low-evidence detections (single far upper-body boxes are often signage or mannequins).
    people = people.filter { $0.height >= 0.06 }
    people.sort { $0.rect[2] * $0.rect[3] > $1.rect[2] * $1.rect[3] }
    var tiers = ["near": 0, "mid": 0, "far": 0]
    for p in people { tiers[p.tier, default: 0] += 1 }

    // Saliency.
    func saliencyMean(_ r: [Double]) -> Double {
        guard !v.saliency.isEmpty else { return 0 }
        let W = v.saliencyW, H = v.saliencyH
        let x0 = max(0, Int(r[0] * Double(W))), x1 = min(W, max(x0 + 1, Int(((r[0] + r[2]) * Double(W)).rounded(.up))))
        let y0 = max(0, Int(r[1] * Double(H))), y1 = min(H, max(y0 + 1, Int(((r[1] + r[3]) * Double(H)).rounded(.up))))
        var s = 0.0, k = 0.0
        for y in y0..<y1 { for x in x0..<x1 { s += Double(v.saliency[y * W + x]); k += 1 } }
        return k > 0 ? s / k : 0
    }
    // Main subject: biggest, most salient person, favouring faces and visible gesture.
    var main: Int? = nil
    var best = 0.0
    for (i, p) in people.enumerated() {
        let size = (p.rect[2] * p.rect[3]).squareRoot() * min(1.6, p.height / 0.4 + 0.2)
        let s = size * (0.5 + saliencyMean(p.rect)) * (p.lookingAtCamera ? 1.3 : 1) * (1 + 0.5 * (p.pose?.energy ?? 0))
        if s > best { best = s; main = i }
    }
    // A crowd has no single subject: a distant main figure among many, or a mid-distance one that does nothing.
    if let m = main {
        let p = people[m], closeCount = people.filter { $0.tier != "far" }.count
        if p.tier == "far" && people.count > 4 { main = nil }
        else if p.tier == "mid" && closeCount >= 5 && (p.pose?.energy ?? 0) < 0.2 && !p.lookingAtCamera { main = nil }
    }
    var subjectRect: [Double]? = main.map { people[$0].rect }
    var subjectKind = main == nil ? "none" : "person"
    // The attention peak: the connected saliency region around the hottest cell (≥ 45% of the peak).
    // (Vision's salientObjects boxes cover most of the frame in busy street scenes, so they are not used.)
    var peakRect: [Double]? = nil, peakShare = 0.0
    if !v.saliency.isEmpty {
        let W = v.saliencyW, H = v.saliencyH
        let mx = v.saliency.indices.max(by: { v.saliency[$0] < v.saliency[$1] })!
        let thr = v.saliency[mx] * 0.45
        var inR = [Bool](repeating: false, count: W * H)
        var stack = [mx]; inR[mx] = true
        var x0 = W, y0 = H, x1 = 0, y1 = 0, mass = 0.0
        while let i = stack.popLast() {
            let x = i % W, y = i / W
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y); mass += Double(v.saliency[i])
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < W && ny < H {
                let j = ny * W + nx
                if !inR[j] && v.saliency[j] >= thr { inR[j] = true; stack.append(j) }
            }
        }
        let tot = v.saliency.reduce(0) { $0 + Double($1) }
        peakShare = tot > 0 ? mass / tot : 0
        peakRect = [Double(x0) / Double(W), Double(y0) / Double(H), Double(x1 - x0 + 1) / Double(W), Double(y1 - y0 + 1) / Double(H)]
    }
    if streetDebug { FileHandle.standardError.write("  peak \(peakRect?.map(round3) ?? []) share \(round2(peakShare))\n".data(using: .utf8)!) }
    let compactPeak = peakRect.map { $0[2] * $0[3] <= 0.25 && $0[2] <= 0.5 && $0[3] <= 0.7 } ?? false
    // With no usable person, a compact attention peak can anchor the frame (a sign, a structure, a shadow).
    if main == nil, people.filter({ $0.tier != "far" }).count < 4, compactPeak, let pr = peakRect, peakShare >= 0.3 { subjectRect = pr; subjectKind = "object" }
    // A large attention peak that no detected person covers: often a figure too close or cropped to detect.
    var unexplainedPeak: [Double]? = nil
    if let pr = peakRect, pr[2] * pr[3] >= 0.08, pr[2] * pr[3] <= 0.5, pr[2] <= 0.75, peakShare >= 0.25 {
        let covered = people.contains {
            interArea($0.rect, pr) > 0.35 * pr[2] * pr[3] || contains(pr, CGPoint(x: $0.rect[0] + $0.rect[2] / 2, y: $0.rect[1] + $0.rect[3] / 2))
        }
        let mainA = main.map { people[$0].rect[2] * people[$0].rect[3] } ?? 0
        if !covered && pr[2] * pr[3] > 1.5 * mainA { unexplainedPeak = pr }
    }

    // Placement.
    func placeOf(_ r: [Double]) -> String {
        let cx = r[0] + r[2] / 2
        var s = cx < 0.3 ? "on the left" : cx > 0.7 ? "on the right" : abs(cx - 0.5) < 0.08 ? "centred" : cx < 0.5 ? "left of centre" : "right of centre"
        if r[0] < 0.01 || r[0] + r[2] > 0.99 { s += ", cut by the frame edge" }
        return s
    }
    let placement = subjectRect.map(placeOf)

    // Figure-ground, surround clutter and overlap.
    func busyShare(_ r: [Double], excluding hole: [Double]? = nil) -> Double {
        let (x0, y0, x1, y1) = maps.cells(r)
        var hx0 = -1, hy0 = -1, hx1 = -1, hy1 = -1
        if let hole { (hx0, hy0, hx1, hy1) = maps.cells(hole) }
        var b = 0.0, k = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 where !(x >= hx0 && x < hx1 && y >= hy0 && y < hy1) {
                let i = y * maps.w + x
                if maps.sky[i] { continue }
                k += 1; if maps.grad[i] >= 6 { b += 1 }
            }
        }
        return k > 0 ? b / k : 0
    }
    var fg: Double? = nil, surround: Double? = nil, overlap = false
    if let r = subjectRect {
        let inner = [r[0] + r[2] * 0.2, r[1] + r[3] * 0.1, r[2] * 0.6, r[3] * 0.8]
        let ring = clampRect([r[0] - r[2] * 0.35, r[1] - r[3] * 0.15, r[2] * 1.7, r[3] * 1.3])
        let a = maps.mean(inner), b = maps.mean(ring, excluding: r)
        if b.n > 4 {
            fg = round1(((a.L - b.L) * (a.L - b.L) + (a.a - b.a) * (a.a - b.a) + (a.b - b.b) * (a.b - b.b)).squareRoot())
            surround = round2(busyShare(ring, excluding: r))
        }
        if let m = main {
            // Overlap at a similar depth reads as a merger; a near figure in front of far ones is layering.
            overlap = people.indices.contains { i in
                i != m && people[i].tier != "far" && min(people[i].height, people[m].height) / max(people[i].height, people[m].height) > 0.6 &&
                    interArea(people[i].rect, r) > 0.2 * min(r[2] * r[3], people[i].rect[2] * people[i].rect[3])
            }
        }
    }

    // Moment.
    var energy = 0.0
    for p in people {
        let w = p.tier == "near" ? 1.0 : p.tier == "mid" ? 0.85 : 0.35
        energy = max(energy, (p.pose?.energy ?? 0) * w)
    }
    let eye = people.contains { $0.lookingAtCamera && $0.tier != "far" }
    var interaction: String? = nil
    let close = people.filter { $0.tier != "far" }
    var juxtaposed = false
    outer: for i in close.indices {
        for k in close.indices where k != i {
            let a = close[i], b = close[k]
            guard a.rect[0] < b.rect[0] else { continue }
            guard min(a.height, b.height) / max(a.height, b.height) > 0.55 else { continue }
            let gap = b.rect[0] - (a.rect[0] + a.rect[2])
            guard gap < 0.6 * (a.rect[2] + b.rect[2]) / 2 else { continue }
            // Hands meet: a wrist of one close to a wrist of the other (handshake, passing something).
            let reachD = 0.12 * min(a.height, b.height)
            let meet = (a.hands ?? []).contains { p in (b.hands ?? []).contains { q in hypot((p[0] - q[0]) * aspect, p[1] - q[1]) < reachD } }
            if meet { interaction = "hands meet"; break outer }
            if a.pose?.turn == "right" && b.pose?.turn == "left" { interaction = "facing each other"; break outer }
            if interArea(a.rect, b.rect) > 0 && (a.pose?.gestures.contains("reaching") == true || b.pose?.gestures.contains("reaching") == true) {
                interaction = "reaching toward"; break outer
            }
            if a.lookingAtCamera && b.lookingAtCamera { interaction = "side by side" }
            // Two separate figures at the same distance, not in a crowd: a juxtaposition.
            if gap >= -0.01 && min(a.height, b.height) / max(a.height, b.height) > 0.7 && close.count <= 4 { juxtaposed = true }
        }
    }
    if interaction == nil && juxtaposed { interaction = "juxtaposed" }

    // ---------------- Light ----------------
    var hist = [Int](repeating: 0, count: 101)
    for l in maps.L { hist[max(0, min(100, Int(l)))] += 1 }
    var bestT = 50, bestVar = -1.0
    let total = Double(n)
    var cumN = 0.0, cumS = 0.0
    let allS = (0...100).reduce(0.0) { $0 + Double($1) * Double(hist[$1]) }
    for t in 0..<100 {
        cumN += Double(hist[t]); cumS += Double(t) * Double(hist[t])
        guard cumN > 0, cumN < total else { continue }
        let m0 = cumS / cumN, m1 = (allS - cumS) / (total - cumN)
        let bv = cumN * (total - cumN) * (m0 - m1) * (m0 - m1)
        if bv > bestVar { bestVar = bv; bestT = t }
    }
    var dark = 0.0, darkS = 0.0, lit = 0.0, litS = 0.0, deep = 0, bright = 0
    for l in maps.L {
        if Int(l) <= bestT { dark += 1; darkS += Double(l) } else { lit += 1; litS += Double(l) }
        if l < 22 { deep += 1 }
        if l > 70 { bright += 1 }
    }
    let sep = dark > 0 && lit > 0 ? litS / lit - darkS / dark : 0
    // Crispness: how sharply the lit/shadow boundary steps at this scale.
    var boundary = 0.0, crisp = 0.0
    for y in 1..<(maps.h - 1) {
        for x in 1..<(maps.w - 1) {
            let i = y * maps.w + x
            let c = maps.L[i] > Float(bestT)
            if (maps.L[i + 1] > Float(bestT)) != c || (maps.L[i + maps.w] > Float(bestT)) != c {
                boundary += 1
                if maps.grad[i] >= 9 { crisp += 1 }
            }
        }
    }
    let crispness = boundary > 0 ? crisp / boundary : 0
    // Large connected shadow shapes (L* < 25).
    var seen = [Bool](repeating: false, count: n)
    var shapeArea = 0
    for s in 0..<n where !seen[s] && maps.L[s] < 25 {
        var stack = [s]; seen[s] = true; var area = 0
        while let i = stack.popLast() {
            area += 1
            let x = i % maps.w, y = i / maps.w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < maps.w && ny < maps.h {
                let j = ny * maps.w + nx
                if !seen[j] && maps.L[j] < 25 { seen[j] = true; stack.append(j) }
            }
        }
        if Double(area) >= 0.004 * total { shapeArea += area }
    }
    let shadowFrac = Double(deep) / total * 100, litFrac = Double(bright) / total * 100
    let darkClass = dark / total * 100
    let skyFracEarly = Double(maps.sky.filter { $0 }.count) / total * 100
    let shapes = Double(shapeArea) / total * 100

    // Light on the subject: share of its pixels on the lit side of the frame's light/shadow split.
    // (A share, not a mean, so dark clothing in sun still counts as lit: skin and folds catch the light.)
    func litShare(_ r: [Double], excluding hole: [Double]? = nil) -> Double {
        let (x0, y0, x1, y1) = maps.cells(r)
        var hx0 = -1, hy0 = -1, hx1 = -1, hy1 = -1
        if let hole { (hx0, hy0, hx1, hy1) = maps.cells(hole) }
        var l = 0.0, k = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 where !(x >= hx0 && x < hx1 && y >= hy0 && y < hy1) {
                k += 1; if maps.L[y * maps.w + x] > Float(bestT + 8) { l += 1 }
            }
        }
        return k > 0 ? l / k : 0
    }
    var subjectLight: String? = nil
    if let r = subjectRect, subjectKind == "person" {
        let inner = [r[0] + r[2] * 0.2, r[1] + r[3] * 0.1, r[2] * 0.6, r[3] * 0.8]
        let ringR = clampRect([r[0] - r[2] * 0.5, r[1] - r[3] * 0.2, r[2] * 2, r[3] * 1.4])
        let inL = maps.mean(inner).L, ringL = maps.mean(ringR, excluding: r).L
        let ls = litShare(inner), rs = litShare(ringR, excluding: r)
        if inL < 16 && ringL > inL + 25 && ls < 0.08 { subjectLight = "silhouette" }
        else if ls < 0.12 && rs > 0.35 && sep > 30 { subjectLight = "in shadow" }
        else if ls >= 0.3 && sep > 30 { subjectLight = "lit" }
        else { subjectLight = "even" }
    }
    // Backlight: several close figures rendered almost black while the frame has bright areas.
    let closeN = people.filter { $0.tier != "far" }.count
    let darkPeople = people.filter { $0.tier != "far" && $0.luminance < 14 }.count
    let backlit = subjectLight == "silhouette" || (darkPeople >= 2 && Double(darkPeople) >= 0.4 * Double(closeN) && litFrac >= 8)
    var kind: String
    if backlit { kind = "backlit" }
    else if sep >= 38 && crispness >= 0.6 && darkClass >= 15 { kind = "hard sun" }
    else if sep >= 30 || (skyFracEarly >= 15 && litFrac >= 8) { kind = "sun, few shadows" }
    else if sep < 26 && crispness < 0.5 { kind = "soft / flat" }
    else { kind = "mixed" }
    let light = StreetLight(kind: kind, separation: round1(sep), shadowFraction: round1(shadowFrac), litFraction: round1(litFrac),
                            crispness: round2(crispness), shadowShapes: round1(shapes), subject: subjectLight)

    // ---------------- Colour ----------------
    let names = ["pink", "red", "orange", "yellow", "green", "cyan", "blue"]
    func family(_ hue: Float) -> Int {
        switch hue {
        case 15..<52: return 1
        case 52..<75: return 2
        case 75..<110: return 3
        case 110..<170: return 4
        case 170..<235: return 5
        case 235..<315: return 6
        default: return 0
        }
    }
    var fam = [Double](repeating: 0, count: 7), strongF = fam
    var hueX = fam, hueY = fam
    var nonSky = 0.0, skyN = 0.0, chromaN = 0.0
    for i in 0..<n {
        if maps.sky[i] { skyN += 1; continue }
        nonSky += 1
        let C = (maps.A[i] * maps.A[i] + maps.B[i] * maps.B[i]).squareRoot()
        guard C >= 25 else { continue }
        var hue = atan2(maps.B[i], maps.A[i]) * 180 / .pi
        if hue < 0 { hue += 360 }
        let f = family(hue)
        fam[f] += 1; chromaN += 1
        if C >= 40 { strongF[f] += 1 }
        hueX[f] += Double(cos(hue * .pi / 180)); hueY[f] += Double(sin(hue * .pi / 180))
    }
    let ns = max(1, nonSky)
    let famPct = fam.map { $0 / ns * 100 }, strongPct = strongF.map { $0 / ns * 100 }
    let chromatic = chromaN / ns * 100
    let skyPct = skyN / total * 100
    func meanHue(_ f: Int) -> Double { (atan2(hueY[f], hueX[f]) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360) }
    func hueDiff(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 360); return min(d, 360 - d) }
    // Complementary: two families each ≥ 2.5% of the non-sky frame, ≥ 130° apart; or a strong warm colour against the blue sky.
    var compPair: [String]? = nil
    var bestPair = 0.0
    for a in 0..<7 {
        for b in (a + 1)..<7 where famPct[a] >= 2.5 && famPct[b] >= 2.5 && hueDiff(meanHue(a), meanHue(b)) >= 130 {
            let s = min(famPct[a], famPct[b])
            if s > bestPair { bestPair = s; compPair = [names[a], names[b]] }
        }
    }
    let warm = [0, 1, 2].max(by: { strongPct[$0] < strongPct[$1] })!
    var againstSky = false
    if compPair == nil && skyPct >= 15 && strongPct[warm] >= 3.5 { compPair = [names[warm], "blue sky"]; againstSky = true }
    // Accent: one strong colour on a small part of an otherwise quieter frame.
    var accent: String? = nil
    let strongSorted = strongPct.indices.sorted { strongPct[$0] > strongPct[$1] }
    var field: String? = nil
    if let top = famPct.indices.max(by: { famPct[$0] < famPct[$1] }), famPct[top] >= 15 { field = names[top] }
    if field == nil, compPair == nil || againstSky, chromatic >= 4, chromatic < 15, let top = strongSorted.first, strongPct[top] >= 1.5, strongPct[top] <= 6,
       strongPct[strongSorted[1]] < strongPct[top] * 0.4, chromatic - famPct[top] < 8 {
        accent = names[top]
    }
    let busyFamilies = famPct.filter { $0 >= 3 }.count
    let character = chromatic < 4 ? "muted" : busyFamilies >= 4 ? "busy" : chromatic >= 20 ? "rich" : "moderate"
    var famDict: [String: Double] = [:], strongDict: [String: Double] = [:]
    for i in 0..<7 where famPct[i] >= 0.5 { famDict[names[i]] = round1(famPct[i]) }
    for i in 0..<7 where strongPct[i] >= 0.3 { strongDict[names[i]] = round1(strongPct[i]) }
    let color = StreetColor(families: famDict, strong: strongDict, skyFraction: round1(skyPct), chromatic: round1(chromatic),
                            complementary: compPair, accent: accent, field: field, character: character)

    // ---------------- Composition ----------------
    var busy = 0.0, cnt = 0.0
    for i in 0..<n where !maps.sky[i] { cnt += 1; if maps.grad[i] >= 6 { busy += 1 } }
    let clutter = cnt > 0 ? busy / cnt : 0
    var darkFrame: [String] = []
    func darkShare(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Double {
        var d = 0.0, k = 0.0
        for y in y0..<y1 { for x in x0..<x1 { k += 1; if maps.L[y * maps.w + x] < 18 { d += 1 } } }
        return k > 0 ? d / k : 0
    }
    let bx = max(1, maps.w / 12), by = max(1, maps.h / 12)
    if darkShare(0, 0, maps.w, by) > 0.7 { darkFrame.append("top") }
    if darkShare(0, maps.h - by, maps.w, maps.h) > 0.7 { darkFrame.append("bottom") }
    if darkShare(0, 0, bx, maps.h) > 0.7 { darkFrame.append("left") }
    if darkShare(maps.w - bx, 0, maps.w, maps.h) > 0.7 { darkFrame.append("right") }

    var report = StreetReport(
        people: people, mainSubject: main, subjectRect: subjectRect?.map(round3), subjectKind: subjectKind, subjectPlacement: placement,
        tiers: tiers, gestureEnergy: round2(energy), eyeContact: eye, interaction: interaction, figureGround: fg, overlap: overlap,
        clutter: round2(clutter), surroundClutter: surround, saliencyFocus: round2(peakShare), unexplainedPeak: unexplainedPeak?.map(round3), darkFrame: darkFrame,
        light: light, color: color, read: [], strengths: [], weaknesses: [],
        score: StreetScore(total: 0, subject: 0, moment: 0, layering: 0, light: 0, color: 0, composition: 0))
    report.score = streetScore(report, againstSky: againstSky)
    writeRead(&report, againstSky: againstSky)
    return report
}

private func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
private func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

// MARK: - Score

private func surroundBusy(_ r: StreetReport) -> Bool {
    guard let s = r.surroundClutter, let m = r.mainSubject, r.people[m].tier != "far" else { return false }
    return s >= max(0.5, r.clutter + 0.1)
}

private func streetScore(_ r: StreetReport, againstSky: Bool) -> StreetScore {
    let main = r.mainSubject.map { r.people[$0] }
    let close = r.people.filter { $0.tier != "far" }

    // Subject: is there something to look at, and does it stand out?
    var subject: Double
    if let m = main {
        subject = m.tier == "near" ? 55 : m.tier == "mid" ? 45 : 20
        subject += clamp01(((r.figureGround ?? 0) - 8) / 30) * 20
        subject += r.overlap ? 0 : 10
        subject += m.pose?.facing == "away" ? 0 : m.lookingAtCamera ? 15 : 8
        if close.count >= 6 && m.tier != "near" { subject -= 15 }   // one face in a crowd
    } else if r.subjectKind == "object" {
        subject = 20 + clamp01((r.saliencyFocus - 0.3) / 0.4) * 20 + clamp01(((r.figureGround ?? 0) - 8) / 30) * 10
    } else {
        subject = r.people.isEmpty ? 5 : 15
    }
    if r.unexplainedPeak != nil && !r.people.isEmpty { subject = max(subject, 50) }

    // Moment / gesture.
    var moment: Double
    if r.people.isEmpty { moment = 5 }
    else {
        moment = 15 + r.gestureEnergy * 50
        if r.eyeContact { moment += 20 }
        if let i = r.interaction { moment += i == "side by side" ? 10 : i == "juxtaposed" ? 6 : 20 }
        let facings = close.prefix(3).compactMap { $0.pose?.facing }.filter { $0 != "unknown" }
        if facings.count >= 2 && Set(facings).count >= 2 { moment += 8 }   // figures doing different things
        if let m = main, m.pose?.facing == "away", (m.pose?.energy ?? 0) < 0.1 { moment -= 10 }
        if close.isEmpty { moment = min(moment, 25) }
    }

    // Layering: figures in several depth tiers spread across the frame.
    var layering = 0.0
    let tierCount = r.tiers.values.filter { $0 > 0 }.count
    if !r.people.isEmpty {
        layering = tierCount >= 3 ? 75 : tierCount == 2 ? 50 : (r.tiers["far"] ?? 0) == r.people.count ? 12 : 25
        let xs = r.people.map { $0.rect[0] + $0.rect[2] / 2 }
        layering += clamp01(((xs.max() ?? 0) - (xs.min() ?? 0) - 0.2) / 0.5) * 15
        if (r.tiers["near"] ?? 0) >= 1 && tierCount >= 2 { layering += 10 }
        if r.overlap && tierCount < 2 { layering -= 10 }
    }

    // Light.
    let l = r.light
    var light: Double
    switch l.kind {
    case "hard sun": light = 60 + clamp01((l.shadowShapes - 10) / 25) * 15
    case "backlit": light = 70
    case "sun, few shadows": light = 45
    case "mixed": light = 40
    default: light = 25
    }
    if l.subject == "lit" { light += 15 } else if l.subject == "in shadow" { light -= 15 } else if l.subject == "silhouette" { light += 10 }
    if l.kind == "backlit" && !r.darkFrame.isEmpty { light += 15 }      // silhouettes inside a dark frame: graphic light

    // Colour (the Kodachrome school: saturated, contrasting, purposeful).
    let c = r.color
    var color = clamp01(c.chromatic / 20) * 40
    if c.complementary != nil { color += againstSky ? 12 : 25 }
    if c.accent != nil { color += 15 }
    if c.field != nil { color += 15 }
    if c.character == "busy" { color -= 5 }
    if c.character == "muted" { color = min(color, 25) }

    // Composition energy.
    var comp = 85.0
    comp -= clamp01((r.clutter - 0.38) / 0.25) * 30
    if surroundBusy(r) { comp -= 10 }
    if r.subjectKind == "none" { comp -= 30 }
    if c.skyFraction > 45 && (r.subjectRect == nil || main?.tier == "far") { comp -= 15 }
    if main?.tier == "far" { comp -= 10 }
    if let p = r.subjectPlacement, p.contains("cut by"), main?.tier != "near" { comp -= 10 }
    if !r.darkFrame.isEmpty && r.subjectKind != "none" { comp += 10 }     // frame within the frame

    let parts = [subject, moment, layering, light, color, comp].map { min(100, max(0, $0)) }
    let total = zip(parts, streetWeights.map { $0.1 }).reduce(0) { $0 + $1.0 * $1.1 }
    return StreetScore(total: round1(total), subject: round1(parts[0]), moment: round1(parts[1]), layering: round1(parts[2]),
                       light: round1(parts[3]), color: round1(parts[4]), composition: round1(parts[5]))
}

// MARK: - Plain-language read

private func joinList(_ xs: [String]) -> String {
    if xs.count <= 1 { return xs.first ?? "" }
    return xs.dropLast().joined(separator: ", ") + " and " + xs.last!
}

private func gesturePhrase(_ g: String) -> String {
    switch g {
    case "mid-stride": return "mid-stride"
    case "walking": return "walking"
    case "arm raised high": return "an arm raised above the head"
    case "hands to head": return "a hand up at the head or face"
    case "arm raised": return "an arm raised"
    case "reaching": return "an arm reaching out"
    case "leaning": return "leaning"
    case "bent over": return "bent over"
    default: return g
    }
}

private func gestureClause(_ g: String) -> String {
    switch g {
    case "mid-stride": return "is mid-stride"
    case "walking": return "appears to be walking"
    case "arm raised high": return "has an arm raised above the head"
    case "hands to head": return "has a hand up at the head or face"
    case "arm raised": return "has an arm raised"
    case "reaching": return "reaches out with an arm"
    case "leaning": return "leans"
    case "bent over": return "is bent over"
    default: return g
    }
}

private func placeText(_ r: [Double]) -> String {
    let cx = r[0] + r[2] / 2, cy = r[1] + r[3] / 2
    let h = cx < 0.3 ? "left" : cx > 0.7 ? "right" : "centre"
    let v = cy < 0.33 ? "top" : cy > 0.67 ? "bottom" : ""
    if h == "centre" { return v.isEmpty ? "in the centre" : "at the \(v) centre" }
    return v.isEmpty ? "on the \(h)" : "at the \(v) \(h)"
}

private func writeRead(_ r: inout StreetReport, againstSky: Bool) {
    var read: [String] = [], good: [String] = [], bad: [String] = []
    let main = r.mainSubject.map { r.people[$0] }
    let near = r.tiers["near"] ?? 0, mid = r.tiers["mid"] ?? 0, far = r.tiers["far"] ?? 0
    let place = r.subjectPlacement ?? ""

    // 1. Subject and moment.
    if let m = main {
        let dist = m.tier == "near" ? "close to the camera" : m.tier == "mid" ? "at mid-distance" : "small and far away"
        var where_ = place
        if let k = where_.range(of: ", cut by the frame edge") { where_.removeSubrange(k); where_ += " (cut by the frame edge)" }
        let gs = m.pose?.gestures ?? []
        let ges = gs.map(gesturePhrase)
        let facing = m.pose?.facing ?? "unknown"
        var clauses = gs.map(gestureClause)
        switch facing {
        case "toward": clauses.append(m.lookingAtCamera ? "appears to look into the lens" : m.pose?.turn.map { "turns toward the \($0)" } ?? "faces the camera")
        case "away": clauses.append("has the back to the camera")
        case "profile": clauses.append("is seen in profile")
        default: break
        }
        let desc = "the main figure, \(dist) \(where_)" + (clauses.isEmpty ? "" : ", " + joinList(clauses))
        let energy = m.pose?.energy ?? 0
        let exchange = r.interaction != nil && r.interaction != "side by side" && r.interaction != "juxtaposed"
        if energy >= 0.45 {
            read.append("Strong gesture: \(desc).")
            good.append("Gesture: " + (ges.first(where: { $0 != "walking" }) ?? ges.first ?? "a body in motion"))
        } else if m.lookingAtCamera {
            read.append("Eye contact: \(desc).")
            good.append("Eye contact with the lens")
        } else if exchange {
            read.append("Exchange: \(desc).")
        } else if energy >= 0.15 {
            read.append("Some movement: \(desc).")
        } else if facing == "away" {
            read.append("Static: \(desc), and gives little away.")
            bad.append("Main figure has the back to the camera and is static")
        } else {
            read.append("Quiet moment: \(desc), with no clear gesture.")
            if m.tier != "far" { bad.append("No strong gesture or expression") }
        }
        // A strong gesture elsewhere in the frame.
        if energy < 0.45, r.gestureEnergy >= 0.45,
           let other = r.people.first(where: { ($0.pose?.energy ?? 0) >= 0.45 && $0.tier != "far" }) {
            let g = (other.pose?.gestures ?? []).filter { $0 != "walking" }.map(gesturePhrase)
            if !g.isEmpty {
                read.append("Another figure \(placeText(other.rect)) is caught \(joinList(g)).")
                good.append("Gesture: " + g[0])
            }
        }
        if m.tier == "far" { bad.append("The main figure is small in the frame") }
    } else if r.subjectKind == "object" {
        let p = r.subjectRect.map(placeText) ?? ""
        if r.people.isEmpty {
            read.append("No people: the eye goes to one shape \(p), likely a sign or structure, so it reads as a picture of the place rather than a moment.")
        } else {
            read.append("The eye goes to a shape \(p) rather than to the people, who are small or scattered.")
        }
        bad.append("No human moment")
    } else if r.people.isEmpty {
        read.append("No clear subject: no people and no single shape to anchor the eye; a view of the place rather than a moment.")
        bad.append("No subject or moment")
    } else {
        read.append("No clear subject: \(r.people.count >= 5 ? "a crowd" : "scattered figures") with nobody standing out to anchor the eye.")
        bad.append("No clear subject")
    }
    if let u = r.unexplainedPeak, !r.people.isEmpty || main != nil {
        read.append("The eye goes first to a large shape \(placeText(u)) that is not a detected person: a sign or object, or a figure too close or cropped for the detector, whose gesture is not read.")
    }
    if let i = r.interaction {
        switch i {
        case "facing each other": read.append("Two figures appear to turn toward each other, a likely exchange between them."); good.append("Interaction between two people")
        case "hands meet": read.append("Two figures' hands meet between them: holding hands, a handshake or something passing hand to hand."); good.append("Interaction between two people")
        case "reaching toward": read.append("Two figures are close with an arm reaching between them, a likely exchange."); good.append("Interaction between two people")
        case "juxtaposed": read.append("Two separate figures at a similar distance invite a comparison between them."); good.append("Juxtaposition of two figures")
        default: read.append("Two figures face the camera together.")
        }
    }

    // 2. Layering / depth.
    let tierCount = [near, mid, far].filter { $0 > 0 }.count
    let xs = r.people.map { $0.rect[0] + $0.rect[2] / 2 }
    let spread = (xs.max() ?? 0) - (xs.min() ?? 0)
    if tierCount >= 3 {
        read.append("Layered depth: figures near, at mid-distance and far away" + (spread >= 0.45 && r.people.count >= 4 ? " spread across the frame, in the Alex Webb manner." : "."))
        good.append("Layering across three depths")
    } else if tierCount == 2 && r.people.count >= 3 {
        read.append("Two layers of people (\(near > 0 ? "a near figure" : "mid-distance figures") against \(far > 0 ? "smaller figures behind" : "others at mid-distance")) give the frame some depth.")
        good.append("Depth from two layers of figures")
    } else if r.people.count >= 6 && tierCount == 1 {
        read.append("The people sit on one plane, so the crowd reads as a flat band rather than layers.")
        bad.append("Figures on a single plane")
    }
    if r.overlap, main != nil {
        read.append("The main figure overlaps another person at the same depth, so their shapes partly merge.")
        bad.append("Main figure merges with another person")
    } else if let fg = r.figureGround, main != nil {
        if fg < 10 { read.append("The main figure blends, in tone and colour, with what is behind it."); bad.append("Weak figure–ground separation") }
        else if fg >= 30 { good.append("Subject separates clearly from the background") }
    }

    // 3. Light.
    let l = r.light
    switch l.kind {
    case "hard sun":
        var s = "Hard, direct sunlight: crisp edges between light and deep shadow"
        if l.shadowShapes >= 30 { s += ", with large dark masses that give the frame graphic weight" }
        if l.subject == "lit" { s += "; the subject is in the light" } else if l.subject == "in shadow" { s += ", but the subject sits in shadow" }
        read.append(s + ".")
        good.append("Hard light and shadow")
    case "backlit":
        read.append(l.subject == "silhouette" ? "Backlit: the subject falls into silhouette against a bright background." : "Backlit: close figures go almost black against a bright background, reading as silhouettes.")
        good.append("Backlight / silhouettes")
    case "sun, few shadows":
        read.append("Bright sun, but few shadows to shape the scene" + (l.subject == "in shadow" ? "; the subject is in shade." : l.subject == "lit" ? "; the subject is in the light." : "."))
    case "soft / flat":
        read.append("Soft, flat light with little shadow structure.")
        bad.append("Flat light")
    default:
        if l.subject == "in shadow" { read.append("Mixed light; the subject sits in shade against brighter surroundings.") }
    }
    if l.subject == "in shadow" { bad.append("Subject in shadow") }
    if !r.darkFrame.isEmpty {
        if r.subjectKind != "none" { good.append("Dark foreground framing") }
        read.append("A dark foreground shape frames the \(joinList(r.darkFrame)) edge\(r.darkFrame.count > 1 ? "s" : "").")
    }

    // 4. Colour.
    let c = r.color
    if let pair = c.complementary {
        if againstSky { read.append("Colour: saturated \(pair[0]) against the blue sky.") }
        else { read.append("Complementary colour contrast: \(pair[0]) against \(pair[1]).") }
        good.append("Colour contrast (\(pair[0]) / \(pair[1]))")
    }
    if let a = c.accent, c.complementary?.contains(a) != true || c.field == nil {
        if c.complementary?.contains(a) != true { read.append("A single \(a) accent stands out in a quieter frame.") }
        good.append("\(a.capitalized) accent")
    }
    if let f = c.field {
        read.append("A large field of \(f) dominates the frame" + (f == "blue" ? "." : ", in the Gruyaert manner."))
        good.append("Large \(f) colour field")
    }
    if c.character == "muted" {
        read.append("Colour is muted: little saturated colour outside the sky.")
        bad.append("Little colour to work with")
    } else if c.character == "busy" && c.field == nil {
        read.append("Many competing colours; nothing dominates.")
        bad.append("Colour is busy rather than organised")
    }

    // 5. Composition.
    let busyAround = surroundBusy(r)
    if r.clutter >= 0.48 { read.append("The frame is busy with detail; the background competes with the subject."); bad.append("Cluttered frame") }
    else if busyAround { read.append("The background right around the main figure is busy."); bad.append("Busy background behind the subject") }
    else if r.clutter <= 0.32 && main != nil && main?.tier != "far" { good.append("Clean, uncluttered frame") }
    if c.skyFraction > 45 && (main == nil || main?.tier == "far") { read.append("Much of the frame is empty sky."); bad.append("Large empty sky") }
    if place.contains("cut by"), let m = main, m.tier == "near" { good.append("Close figure cropped by the edge pulls the viewer in") }

    if read.count > 6 { read = Array(read.prefix(6)) }
    r.read = read
    r.strengths = good
    r.weaknesses = bad
}
