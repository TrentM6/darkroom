import CoreGraphics
import Foundation
import ImageIO
import Vision

// "Things worth a second look": 0-4 short observations about a frame, from Apple's on-device Vision
// (text, body pose, rectangles, animals) on the 2560 px proxy, the stored street read and the edited
// render's colour. Rules only, deterministic. A cue is emitted only when its signal is strong; no cue
// is better than a weak one. They describe what is there; they never claim it is funny.

enum StudioCues {
    static let version = 4

    /// Real words, not OCR fragments: most words (3+ letters) are in the system word list
    /// (/usr/share/dict/words; plurals and possessives allowed).
    static let dictionary: Set<String> = {
        guard let t = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(t.split(separator: "\n").map { $0.lowercased() })
    }()

    static let shortWords: Set<String> = ["a", "an", "of", "to", "at", "in", "on", "by", "my", "we", "us", "no", "go", "is", "it", "be", "do", "me", "&", "or", "so", "up"]

    /// Real words, not OCR fragments: every word is in the system word list (/usr/share/dict/words;
    /// plurals and possessives allowed), short words only from a common list, and either two or more
    /// words or one word of 5+ letters.
    static func wellSpelled(_ s: String) -> Bool {
        let tokens = s.split { !$0.isLetter && $0 != "'" }.map { $0.lowercased() }
        guard !tokens.isEmpty, !dictionary.isEmpty else { return false }
        func known(_ w: String) -> Bool {
            if w.count <= 2 { return shortWords.contains(w) }
            var w = w
            if w.hasSuffix("'s") { w = String(w.dropLast(2)) }
            return dictionary.contains(w) || (w.hasSuffix("s") && dictionary.contains(String(w.dropLast())))
                || (w.hasSuffix("es") && dictionary.contains(String(w.dropLast(2))))
        }
        guard tokens.allSatisfy(known) else { return false }
        return tokens.count >= 2 || (tokens.first?.count ?? 0) >= 7
    }

    struct Pose { var rect: CGRect; var angles: [Int: Double] }   // limb index -> angle (radians)

    static func topLeft(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }

    /// Cues for a photo. `image` is the upright proxy; `render` the edited preview (for colour rhymes).
    static func compute(image: CGImage, render: CGImage?, ctx: CritiqueContext, tags: [String]) -> [String] {
        var out: [(Double, String)] = []    // (strength, text)
        let people = ctx.people
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        let body = VNDetectHumanBodyPoseRequest()
        let rects = VNDetectRectanglesRequest()
        rects.minimumSize = 0.25; rects.maximumObservations = 8; rects.minimumConfidence = 0.7; rects.quadratureTolerance = 12
        rects.minimumAspectRatio = 0.2
        let animals = VNRecognizeAnimalsRequest()
        try? handler.perform([text, body, rects, animals])

        // 1. A legible sign in the frame with people.
        if !people.isEmpty, let obs = text.results {
            let signs: [(String, CGRect, Double)] = obs.compactMap { o in
                guard let c = o.topCandidates(1).first, c.confidence >= 0.9 else { return nil }
                let s = c.string.trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
                let letters = s.filter { $0.isLetter }.count
                let b = o.boundingBox
                // legible: big enough, not cut off by the frame edge, made of real words
                guard letters >= 4, Double(letters) >= 0.7 * Double(s.count), b.height >= 0.04, b.minX > 0.01, b.maxX < 0.99,
                      wellSpelled(s) else { return nil }
                // lettering on someone's clothes isn't a sign
                let tl = topLeft(b)
                if people.contains(where: { CGRect(x: $0.rect[0], y: $0.rect[1], width: $0.rect[2], height: $0.rect[3]).contains(CGPoint(x: tl.midX, y: tl.midY)) }) { return nil }
                return (s, tl, Double(b.width * b.height))
            }
            if let best = signs.max(by: { $0.2 < $1.2 }) {
                var s = best.0
                if s.count > 30 { s = String(s.prefix(30)); if let sp = s.lastIndex(of: " ") { s = String(s[..<sp]) } }
                let topOfPeople = people.map { $0.rect[1] }.min() ?? 1
                let above = best.1.maxY < topOfPeople + 0.02
                let crowd = people.count >= 3
                let place = above ? (crowd ? "sits above the crowd" : "sits above the figure\(people.count > 1 ? "s" : "")") : (crowd ? "sits among the crowd" : "is in the frame with them")
                out.append((0.9, "A sign reading \u{201C}\(s)\u{201D} \(place)"))
            }
        }

        // 2. Pose echo: two sizable people with matching limb angles.
        if let poses = body.results, poses.count >= 2 {
            let limbs: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
                (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist), (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
                (.leftHip, .leftKnee), (.leftKnee, .leftAnkle), (.rightHip, .rightKnee), (.rightKnee, .rightAnkle)]
            let ps: [Pose] = poses.compactMap { o in
                guard let pts = try? o.recognizedPoints(.all) else { return nil }
                var angles: [Int: Double] = [:]
                for (i, (a, b)) in limbs.enumerated() {
                    guard let pa = pts[a], let pb = pts[b], pa.confidence >= 0.3, pb.confidence >= 0.3 else { continue }
                    angles[i] = atan2(Double(pb.location.y - pa.location.y), Double(pb.location.x - pa.location.x))
                }
                let ys = pts.values.filter { $0.confidence >= 0.3 }.map { $0.location.y }
                guard angles.count >= 6, let lo = ys.min(), let hi = ys.max(), hi - lo >= 0.15 else { return nil }
                // a distinctive pose only: at least two limbs far (> 0.6 rad) from hanging straight down
                let off = angles.values.filter { abs(atan2(sin($0 + .pi / 2), cos($0 + .pi / 2))) > 0.6 }.count
                guard off >= 2 else { return nil }
                return Pose(rect: .zero, angles: angles)
            }
            var echo = 0
            for i in 0..<ps.count { for j in (i + 1)..<ps.count {
                let common = Set(ps[i].angles.keys).intersection(ps[j].angles.keys)
                guard common.count >= 6 else { continue }
                let sim = common.map { cos(ps[i].angles[$0]! - ps[j].angles[$0]!) }.reduce(0, +) / Double(common.count)
                if sim >= 0.95 { echo += 1 }
            } }
            if echo >= 1 { out.append((0.8, "Two figures echo each other\u{2019}s pose")) }
        }

        // 3. Gaze, from head direction (the street read) on people big enough to read.
        let readable = people.filter { $0.height >= 0.2 && $0.turn != nil && $0.faceYaw != nil }
        if readable.count >= 2 {
            let sorted = readable.sorted { $0.rect[0] < $1.rect[0] }
            var mutual = false
            for i in 0..<(sorted.count - 1) where sorted[i].turn == "right" && sorted[i + 1].turn == "left" { mutual = true }
            if mutual { out.append((0.75, "Two people look at each other")) }
            else if readable.count >= 3 {
                let rights = readable.filter { $0.turn == "right" }.count, lefts = readable.count - rights
                if Double(max(rights, lefts)) >= 0.85 * Double(readable.count) { out.append((0.6, "Everyone looks the same way")) }
            }
        }
        if let main = people.max(by: { $0.height < $1.height }), main.height >= 0.3, let t = main.turn, main.faceYaw != nil {
            let x0 = main.rect[0], x1 = main.rect[0] + main.rect[2]
            if (t == "left" && x0 < 0.1) || (t == "right" && x1 > 0.9) { out.append((0.55, "The subject looks out of the frame")) }
        }

        // 4. Scale contrast: a small figure against a big sign or shape.
        if let smallest = people.map({ $0.height }).min(), smallest < 0.08, smallest > 0.02 {
            let bigText = (text.results ?? []).contains { $0.boundingBox.width * $0.boundingBox.height >= 0.08 && ($0.topCandidates(1).first?.confidence ?? 0) >= 0.5 }
            let bigShape = ctx.subjectKind == "object" && (ctx.subjectRect.map { $0[2] * $0[3] } ?? 0) >= 0.35
            if bigText { out.append((0.7, "A small figure against a huge sign")) }
            else if bigShape { out.append((0.6, "A small figure against a huge shape")) }
        }

        // 5. Colour rhyme: three or more separate patches of the same strong colour, spread out.
        if let rhyme = colourRhyme(render ?? image) { out.append((0.65, "\(rhyme.capitalizedFirst) repeats across the frame")) }

        // 6. Frame within a frame: a large rectangle enclosing the main subject.
        if let s = ctx.subjectRect ?? people.max(by: { $0.height < $1.height })?.rect, let rs = rects.results {
            let subj = CGRect(x: s[0], y: s[1], width: s[2], height: s[3])
            let inner = rs.map { topLeft($0.boundingBox) }.filter { r in
                let area = r.width * r.height
                return area >= 0.12 && area <= 0.8 && r.insetBy(dx: -0.01, dy: -0.01).contains(subj)
                    && r.minX > 0.03 && r.maxX < 0.97 && r.minY > 0.03 && r.maxY < 0.97
            }
            if !inner.isEmpty { out.append((0.6, "Framed within the frame")) }
        }

        // 7. Spotlight: the subject lit while most of the frame is in shadow.
        if ctx.light.subject == "lit" && ctx.light.shadowFraction >= 60 { out.append((0.7, "The subject stands in the only patch of sun")) }

        // 8. Odd company: an animal among people; costumes or masks.
        if !people.isEmpty, let an = animals.results {
            if let a = an.compactMap({ $0.labels.first }).first(where: { $0.confidence >= 0.8 }) {
                let what = a.identifier.lowercased().hasPrefix("cat") ? "cat" : "dog"
                out.append((0.7, people.count >= 4 ? "A \(what) in the middle of the crowd" : "A \(what) among the people"))
            }
        }
        if !people.isEmpty {
            if tags.contains(where: { $0.contains("costume") }) { out.append((0.5, "Someone in costume")) }
            else if tags.contains(where: { $0 == "mask" || $0.hasPrefix("mask") }) { out.append((0.5, "A masked face in the crowd")) }
        }

        return Array(out.sorted { $0.0 > $1.0 }.prefix(4).map { $0.1 })
    }

    /// The hue family that appears as 3+ separate strong patches (each >= 0.3% of the frame) spread across the frame.
    static func colourRhyme(_ img: CGImage) -> String? {
        let w = 192, h = max(1, Int(Double(img.height) / Double(img.width) * 192))
        let px = Pixels.rgba(img, width: w, height: h)
        var label = [Int8](repeating: -1, count: w * h)
        for i in 0..<(w * h) {
            let lab = ColorMath.lab(r: px.data[i * 4], g: px.data[i * 4 + 1], b: px.data[i * 4 + 2])
            let c = sqrtf(lab.a * lab.a + lab.b * lab.b)
            guard c > 45 else { continue }
            var hue = atan2f(lab.b, lab.a) * 180 / .pi; if hue < 0 { hue += 360 }
            let bin = hue < 45 || hue >= 345 ? 0 : hue < 70 ? 1 : hue < 105 ? 2 : hue < 165 ? 3 : hue < 215 ? 4 : hue < 290 ? 5 : hue < 320 ? 6 : 7
            if bin == 5 && lab.L > 45 && i / w < h / 2 { continue }      // sky
            label[i] = Int8(bin)
        }
        let names = ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"]
        var seen = [Bool](repeating: false, count: w * h)
        var patches: [Int: [(Double, Double)]] = [:]
        let minArea = Int(Double(w * h) * 0.003)
        for start in 0..<(w * h) where label[start] >= 0 && !seen[start] {
            let bin = label[start]
            var stack = [start], area = 0, sx = 0.0, sy = 0.0
            seen[start] = true
            while let i = stack.popLast() {
                area += 1; sx += Double(i % w); sy += Double(i / w)
                for j in [i - 1, i + 1, i - w, i + w] where j >= 0 && j < w * h && !seen[j] && label[j] == bin && abs(j % w - i % w) <= 1 {
                    seen[j] = true; stack.append(j)
                }
            }
            if area >= minArea { patches[Int(bin), default: []].append((sx / Double(area) / Double(w), sy / Double(area) / Double(h))) }
        }
        for (bin, ps) in patches.sorted(by: { $0.value.count > $1.value.count }) where ps.count >= 3 {
            var spread = 0.0
            for a in ps { for b in ps { spread = max(spread, hypot(a.0 - b.0, a.1 - b.1)) } }
            if spread >= 0.45 { return names[bin] }
        }
        return nil
    }
}

extension Studio {
    /// Cues for a photo: computed once (in the background) and stored; nil while not computed yet.
    func cues(_ pid: String, _ ph: PhotoEntry) -> [String]? {
        if ph.cuesVersion == StudioCues.version, let c = ph.cues { return c }
        queueCues(pid, ph.id)
        return nil
    }

    func queueCues(_ pid: String, _ id: String) {
        let key = pid + "/" + id
        let fresh: Bool = sync { cuesPending.insert(key).inserted }
        guard fresh else { return }
        cuesQueue.addOperation { [weak self] in
            guard let self else { return }
            defer { _ = self.sync { self.cuesPending.remove(key) } }
            guard let (ph, tags) = self.sync({ () -> (PhotoEntry, [String])? in
                guard let i = self.photoIndex(pid, id), let p = self.projects[pid]?.photos[i] else { return nil }
                return (p, p.cueTags ?? [])
            }), let ctx = ph.critiqueContext else { return }
            let eng = self.engine(pid)
            guard let proxyURL = self.ensureProxy(pid, ph.ref, upgrade: false),
                  let src = CGImageSourceCreateWithURL(proxyURL as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
            var render: CGImage? = nil
            if let rs = CGImageSourceCreateWithURL(eng.previewURL(ph.ref) as CFURL, nil) { render = Pixels.load(rs, maxPixel: 640) }
            let cues = autoreleasepool { StudioCues.compute(image: img, render: render, ctx: ctx, tags: tags) }
            self.sync {
                guard let i = self.photoIndex(pid, id), self.projects[pid] != nil else { return }
                self.projects[pid]!.photos[i].cues = cues
                self.projects[pid]!.photos[i].cuesVersion = StudioCues.version
                self.markDirty(pid)
            }
        }
    }

    /// After startup: compute missing cues for every analysed photo, quietly, most recently opened first.
    func sweepCues() {
        let jobs: [(String, String)] = sync {
            let order = projects.keys.sorted { (lastOpened[$0] ?? .distantPast, projects[$0]?.date ?? "", $0) > (lastOpened[$1] ?? .distantPast, projects[$1]?.date ?? "", $1) }
            return order.flatMap { pid in (projects[pid]?.photos ?? []).filter { $0.analyzed && !$0.gone && $0.critiqueContext != nil && $0.cuesVersion != StudioCues.version }.map { (pid, $0.id) } }
        }
        for (pid, id) in jobs { queueCues(pid, id) }
    }
}
