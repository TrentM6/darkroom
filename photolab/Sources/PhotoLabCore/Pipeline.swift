import Foundation
import ImageIO
import Vision

public let engineVersion = "0.1.0"

struct Analyzed {
    var report: PhotoReport
    var print: VNFeaturePrintObservation?
}

func analyzePhoto(url: URL, outDir: URL) -> Analyzed? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return nil }
    let pw = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
    let ph = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
    guard let full = Pixels.load(src, maxPixel: max(pw, ph)) else { return nil }
    let id = url.deletingPathExtension().lastPathComponent

    // Previews for the report.
    let preview = Pixels.load(src, maxPixel: 2048) ?? full
    Pixels.writeJPEG(preview, to: outDir.appendingPathComponent("previews/\(id).jpg"), quality: 0.86)
    if let thumb = Pixels.load(src, maxPixel: 480) {
        Pixels.writeJPEG(thumb, to: outDir.appendingPathComponent("thumbs/\(id).jpg"), quality: 0.8)
    }

    var capture = readCapture(props)
    let fuji = (capture.make ?? "").uppercased().contains("FUJI")
        ? fujiSettings(tags: readFujiMakerNotes(url: url), pictureStyle: props["{PictureStyle}"] as? [String: Any]) : nil
    if let fm = fuji?.focusMode { capture.focusMode = fm }
    // The AF frame is only meaningful when the camera focused (not with a manual/adapted lens).
    if fuji == nil || capture.manualLens || capture.focusMode == "Manual focus" { capture.afPoint = nil }

    // Pixel planes.
    let rgba = Pixels.rgba(full)
    let small = Pixels.downscaled(full, longEdge: 1024)
    let lab = labPlane(small)
    let (tone, overlay) = analyzeTone(rgba, lab1024: lab, labW: small.width, labH: small.height)
    Pixels.writePNG(rgba: overlay.rgba, width: overlay.width, height: overlay.height, to: outDir.appendingPathComponent("overlays/\(id)-clip.png"))

    let luma = Pixels.luma(rgba)
    let (cb, cr) = Pixels.chromaHalf(rgba)
    let noise = analyzeNoise(luma: luma, lumaHalf: Pixels.half(luma), cb: cb, cr: cr)
    var (sharp, sharpPlane) = analyzeSharpness(SharpnessContext(luma: luma, capture: capture))
    let color = analyzeColor(small, lab: lab)

    // Vision on a 2560 px version.
    let visionImage = Pixels.load(src, maxPixel: 2560) ?? full
    let v = runVision(visionImage)
    let visionWidth = Double(visionImage.width)
    var faces: [FaceReport] = []
    for (i, fo) in v.faces.enumerated() {
        let r = topLeft(fo.boundingBox)
        let quality = i < v.qualities.count ? v.qualities[i] : nil
        let le = eyeOpenness(fo.landmarks?.leftEye), re = eyeOpenness(fo.landmarks?.rightEye)
        // Eyes are judged only on faces big and clear enough for the landmarks to mean something.
        var closed: Bool? = nil
        var state = "not judged"
        if r[2] * visionWidth >= FaceRules.minEyeFacePixels, (quality ?? 0) >= FaceRules.minEyeQuality, let le, let re {
            if max(le, re) > 1.0 {
                state = "not judged"          // openness above 1 = landmark failure
            } else if wearsSunglasses(luma, face: fo) {
                state = "hidden"
            } else {
                closed = max(le, re) < FaceRules.closedOpenness
                state = closed! ? "closed" : "open"
            }
        }
        let skin = skinAngle(small, rect: r)
        var fr = FaceReport(
            rect: r.map { ($0 * 1000).rounded() / 1000 },
            captureQuality: quality.map(round2),
            leftEyeOpenness: le, rightEyeOpenness: re, eyesClosed: closed,
            edgeWidth: faceEdgeWidth(sharpPlane, rect: r),
            skinAngle: skin?.angle, skinOffset: skin?.offset,
            roll: fo.roll.map { round1($0.doubleValue * 180 / .pi) }, yaw: fo.yaw.map { round1($0.doubleValue * 180 / .pi) },
            touchesEdge: r[0] < 0.005 || r[1] < 0.005 || r[0] + r[2] > 0.995 || r[1] + r[3] > 0.995
        )
        fr.eyesState = state
        fr.isSubject = false
        faces.append(fr)
    }
    // Subject faces: the largest face if it covers at least 0.3% of the frame, plus any face at least
    // 40% of its size (a pair or group posing together).
    if let mi = faces.indices.max(by: { faces[$0].rect[2] * faces[$0].rect[3] < faces[$1].rect[2] * faces[$1].rect[3] }) {
        let big = faces[mi].rect[2] * faces[mi].rect[3]
        if big >= FaceRules.subjectArea {
            for i in faces.indices where faces[i].rect[2] * faces[i].rect[3] >= 0.4 * big { faces[i].isSubject = true }
        }
    }

    // Subject sharpness (for the focus-off-subject check and best-of-burst): the subject faces with
    // head and shoulders, else the most salient tiles of Vision's attention map.
    let subjectFaces = faces.filter { $0.isSubject == true }
    if !subjectFaces.isEmpty {
        let rects = subjectFaces.map { f in [f.rect[0] - 0.6 * f.rect[2], f.rect[1] - 0.2 * f.rect[3], 2.2 * f.rect[2], 3.0 * f.rect[3]] }
        if let rw = regionWidth(sharp, rects: rects, minTiles: 2) { sharp.subjectWidth = rw.width; sharp.subjectSource = "face" }
    } else if !v.saliency.isEmpty {
        let tileSal = tileSaliency(v, cols: sharp.cols, rows: sharp.rows)
        let mx = tileSal.max() ?? 0
        if mx > 0 {
            let sel = Set(tileSal.indices.filter { tileSal[$0] >= 0.6 * mx })
            if let rw = regionWidth(sharp, minTiles: 3, inside: { cx, cy in
                sel.contains(min(sharp.rows - 1, Int(cy * Double(sharp.rows))) * sharp.cols + min(sharp.cols - 1, Int(cx * Double(sharp.cols))))
            }) { sharp.subjectWidth = rw.width; sharp.subjectSource = "saliency" }
        }
    }
    if ProcessInfo.processInfo.environment["PHOTOLAB_DEBUG"] != nil {
        FileHandle.standardError.write(String(format: "%@ sharp frame %.2f (%@) best %.2f global %.2f tiles %d motion %@ %.2f aniso %.2f grain %.2f\n",
            id, sharp.frameWidth ?? -1, String(format: "subj %.2f %@", sharp.subjectWidth ?? -1, sharp.subjectSource ?? "-"), sharp.bestWidth ?? -1, sharp.globalWidth ?? -1, sharp.texturedTiles ?? 0,
            sharp.motionHint ?? "-", sharp.motionFraction ?? -1, sharp.anisotropy ?? -1, sharp.grainSigma ?? -1).data(using: .utf8)!)
    }
    let tilt = estimateTilt(luma, visionHorizon: v.horizonDegrees)
    if ProcessInfo.processInfo.environment["PHOTOLAB_DEBUG"] != nil {
        FileHandle.standardError.write("\(id) tilt \(tilt.debug) -> \(tilt.tilt.map { String($0) } ?? "-") c \(tilt.confidence.map { String($0) } ?? "-")\n".data(using: .utf8)!)
    }
    let comp = analyzeComposition(vision: v, tilt: tilt, faces: faces, lab: lab, labW: small.width, labH: small.height,
                                  aspect: Double(rgba.width) / Double(rgba.height))

    var report = PhotoReport(
        id: id, file: url.lastPathComponent, path: url.path, width: rgba.width, height: rgba.height,
        preview: "previews/\(id).jpg", thumb: "thumbs/\(id).jpg", clipOverlay: "overlays/\(id)-clip.png",
        capture: capture, fuji: fuji, tone: tone, noise: noise, sharpness: sharp, color: color, faces: faces,
        composition: comp, scene: SceneReport(tags: v.tags, faceCount: faces.count, peopleCount: max(v.people, faces.count))
    )
    assess(&report)
    report.score = score(report)
    report.street = analyzeStreet(image: visionImage, lab: lab, labW: small.width, labH: small.height, vision: v, faces: faces)
    return Analyzed(report: report, print: v.featurePrint)
}

public struct RunOptions {
    public var input: URL
    public var output: URL
    public var jobs: Int
    /// Called after each photo is analyzed, with (done, total, report or nil if it failed). Lets a caller
    /// make photos available before the whole shoot is finished. Bursts/groups/shoot ranks come at the end.
    public var onPhoto: ((Int, Int, PhotoReport?) -> Void)? = nil
    /// Analyze only these files (default: every JPEG/TIFF in `input`).
    public var files: [URL]? = nil
    public init(input: URL, output: URL, jobs: Int) { self.input = input; self.output = output; self.jobs = jobs }
}

public func runShoot(_ opt: RunOptions, log: @escaping (String) -> Void) throws -> ShootReport {
    let fm = FileManager.default
    let exts: Set<String> = ["jpg", "jpeg", "tif", "tiff"]
    let files = try (opt.files ?? fm.contentsOfDirectory(at: opt.input, includingPropertiesForKeys: nil))
        .filter { exts.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix(".") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    for d in ["previews", "thumbs", "overlays"] {
        try fm.createDirectory(at: opt.output.appendingPathComponent(d), withIntermediateDirectories: true)
    }

    var results = [Analyzed?](repeating: nil, count: files.count)
    let lock = NSLock()
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = max(1, opt.jobs)
    var done = 0
    let start = Date()
    for (i, f) in files.enumerated() {
        queue.addOperation {
            // Decoding a 26 MP JPEG can fail transiently under memory pressure: retry once before giving up.
            var r = autoreleasepool { analyzePhoto(url: f, outDir: opt.output) }
            if r == nil { Thread.sleep(forTimeInterval: 2); r = autoreleasepool { analyzePhoto(url: f, outDir: opt.output) } }
            lock.lock()
            results[i] = r
            done += 1
            log(String(format: "[%d/%d] %@ %@", done, files.count, f.lastPathComponent, r == nil ? "FAILED" : ""))
            let n = done
            lock.unlock()
            opt.onPhoto?(n, files.count, r?.report)
        }
    }
    queue.waitUntilAllOperationsAreFinished()
    log(String(format: "Analyzed %d files in %.1fs", files.count, Date().timeIntervalSince(start)))

    var analyzed = results.compactMap { $0 }
    analyzed.sort { ($0.report.capture.timestamp ?? 0, $0.report.file) < ($1.report.capture.timestamp ?? 0, $1.report.file) }
    let groups = groupShoot(&analyzed, log: log)

    // Shoot-relative sharpness rank (lower width = sharper).
    let widths = analyzed.compactMap { $0.report.sharpness.frameWidth }.sorted()
    for i in analyzed.indices {
        if let w = analyzed[i].report.sharpness.frameWidth, !widths.isEmpty {
            let rank = widths.filter { $0 > w }.count
            analyzed[i].report.sharpness.shootPercentile = round1(Double(rank) / Double(max(1, widths.count - 1)) * 100)
        }
    }

    let photos = analyzed.map { $0.report }
    var cams: [String: Int] = [:], lenses: [String: Int] = [:], sims: [String: Int] = [:], flagCounts: [String: Int] = [:]
    for p in photos {
        cams[[p.capture.make, p.capture.model].compactMap { $0 }.joined(separator: " "), default: 0] += 1
        lenses[p.capture.lens ?? "Unknown", default: 0] += 1
        if let f = p.fuji { sims[f.filmSimulation, default: 0] += 1 }
        for f in p.flags { flagCounts[f.code, default: 0] += 1 }
    }
    let iso = ISO8601DateFormatter()
    return ShootReport(
        name: opt.input.lastPathComponent, sourcePath: opt.input.path, generatedAt: iso.string(from: Date()),
        engineVersion: engineVersion, photoCount: photos.count,
        stats: ShootStats(start: photos.first?.capture.dateTimeOriginal, end: photos.last?.capture.dateTimeOriginal,
                          cameras: cams, lenses: lenses, filmSimulations: sims, flagCounts: flagCounts,
                          medianEdgeWidth: percentile(widths, 0.5), calibration: [
                            // Thresholds behind the sharpness verdicts (frame width, px at 100%), for the report's tile colours.
                            "sharpIdeal": SharpnessScale.ideal, "sharpCritical": SharpnessScale.critical, "sharpSharp": SharpnessScale.sharp,
                            "sharpSlight": SharpnessScale.slight, "sharpSoft": SharpnessScale.soft, "sharpMissed": SharpnessScale.missed,
                            "tiltFlagDegrees": TiltRules.flagDegrees, "tiltFlagConfidence": TiltRules.flagConfidence,
                          ]),
        groups: groups, photos: photos
    )
}

public func writeReport(_ report: ShootReport, to out: URL) throws {
    try writeReportData(report, to: out)
    guard let html = Bundle.module.url(forResource: "report", withExtension: "html") else { throw NSError(domain: "photolab", code: 1) }
    let dest = out.appendingPathComponent("index.html")
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.copyItem(at: html, to: dest)
}

/// report.json + report.js only (the server updates these after every edit).
public func writeReportData(_ report: ShootReport, to out: URL) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let json = try enc.encode(report)
    try json.write(to: out.appendingPathComponent("report.json"), options: .atomic)
    var js = Data("window.REPORT = ".utf8)
    js.append(json)
    js.append(Data(";\n".utf8))
    try js.write(to: out.appendingPathComponent("report.js"), options: .atomic)
}

/// Mean of Vision's attention heatmap over each sharpness tile (row-major).
func tileSaliency(_ v: VisionResult, cols: Int, rows: Int) -> [Double] {
    var out = [Double](repeating: 0, count: cols * rows)
    var cnt = [Double](repeating: 0, count: cols * rows)
    for y in 0..<v.saliencyH {
        for x in 0..<v.saliencyW {
            let tx = min(cols - 1, x * cols / v.saliencyW), ty = min(rows - 1, y * rows / v.saliencyH)
            out[ty * cols + tx] += Double(v.saliency[y * v.saliencyW + x]); cnt[ty * cols + tx] += 1
        }
    }
    return out.indices.map { cnt[$0] > 0 ? out[$0] / cnt[$0] : 0 }
}
