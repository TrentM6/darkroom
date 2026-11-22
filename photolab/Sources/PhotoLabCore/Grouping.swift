import Foundation
import Vision

/// Thresholds for grouping. Feature-print distances come from Vision (revision 2 is ~0...1.5).
struct GroupingRules {
    static let burstSeconds = 3.0
    static let burstDistance: Float = 0.45
    // Same-subject sequence: the same person/moment re-framed a few seconds later (e.g. 8087 -> 8088).
    static let sequenceSeconds = 6.0
    static let sequenceDistance: Float = 0.65
    static let duplicateDistance: Float = 0.40
    // Scenes: a pause over 5 min always splits; a pause over 90 s splits when the content changed
    // (feature distance to the scene's last frames > 0.62); a 30 s pause only on a bigger change (> 0.78).
    static let sceneGap = 300.0
    static let sceneGapContent = 90.0
    static let sceneDistance: Float = 0.62
    static let sceneMinGapForContent = 30.0
    static let sceneDistanceShortGap: Float = 0.78
    static let bestTie = 3.0                // best-of-burst needs a lead of more than this
    static let commonTagShare = 0.4         // tags on more than 40% of the shoot's frames don't title scenes
}

/// Burst ranking: subject sharpness first, then eyes, edge cuts, motion and exposure.
func burstQuality(_ r: PhotoReport) -> Double {
    let frame = sharpnessScore(r.sharpness.frameWidth ?? SharpnessScale.missed)
    var q = r.sharpness.subjectWidth.map { (frame + sharpnessScore($0)) / 2 } ?? frame
    if r.faces.contains(where: { $0.isSubject == true && $0.eyesState == "closed" }) { q -= 30 }
    if r.flags.contains(where: { $0.code == "face-cut" }) { q -= 15 }
    if r.flags.contains(where: { $0.code == "motion-blur" }) { q -= 10 }
    q -= (100 - (r.score?.exposure ?? 100)) * 0.3
    return q
}

func groupShoot(_ items: inout [Analyzed], log: (String) -> Void) -> [SceneGroup] {
    guard !items.isEmpty else { return [] }
    func dist(_ a: Int, _ b: Int) -> Float? {
        guard let pa = items[a].print, let pb = items[b].print else { return nil }
        var d: Float = 0
        do { try pa.computeDistance(&d, to: pb) } catch { return nil }
        return d
    }

    // Consecutive gaps and distances.
    var gaps: [Double] = [], dists: [Float?] = []
    for i in 1..<items.count {
        let t0 = items[i - 1].report.capture.timestamp ?? 0, t1 = items[i].report.capture.timestamp ?? 0
        gaps.append(t1 - t0)
        dists.append(dist(i - 1, i))
    }
    let medGap = percentile(gaps, 0.5) ?? 60
    let sceneGap = GroupingRules.sceneGap
    let ds = dists.compactMap { $0 }.map { Double($0) }
    log(String(format: "Grouping: median gap %.0fs, scene gap %.0fs, feature distance p10 %.2f / p50 %.2f / p90 %.2f",
               medGap, sceneGap, percentile(ds, 0.1) ?? 0, percentile(ds, 0.5) ?? 0, percentile(ds, 0.9) ?? 0))

    for i in 1..<items.count where gaps[i - 1] <= 20 {
        log(String(format: "  %@ -> %@  gap %.0fs  distance %.3f", items[i - 1].report.id, items[i].report.id, gaps[i - 1], dists[i - 1] ?? -1))
    }

    // Bursts: consecutive frames close in time and content.
    var burstId = 0
    var inBurst = false
    for i in 1..<items.count {
        let d = dists[i - 1] ?? 9
        let close = (gaps[i - 1] <= GroupingRules.burstSeconds && d <= GroupingRules.burstDistance)
            || (gaps[i - 1] <= GroupingRules.sequenceSeconds && d <= GroupingRules.sequenceDistance)
        if close {
            if !inBurst { burstId += 1; items[i - 1].report.burstId = burstId; inBurst = true }
            items[i].report.burstId = burstId
        } else {
            inBurst = false
        }
    }
    var bursts: [Int: [Int]] = [:]
    for (i, it) in items.enumerated() { if let b = it.report.burstId { bursts[b, default: []].append(i) } }
    for (b, idx) in bursts.sorted(by: { $0.key < $1.key }) {
        let ranked = idx.map { ($0, burstQuality(items[$0].report)) }.sorted { $0.1 > $1.1 }
        let desc = ranked.map { String(format: "%@ %.1f", items[$0.0].report.id, $0.1) }.joined(separator: ", ")
        if ranked.count >= 2, ranked[0].1 - ranked[1].1 <= GroupingRules.bestTie {
            log("  burst \(b): \(desc) -> tie, no best")
        } else if let top = ranked.first {
            items[top.0].report.bestInBurst = true
            log("  burst \(b): \(desc) -> best \(items[top.0].report.id)")
        }
    }

    // Near-duplicates (same moment re-shot, not necessarily a burst), within a 2-minute window.
    for i in items.indices {
        var j = i - 1
        while j >= 0, (items[i].report.capture.timestamp ?? 0) - (items[j].report.capture.timestamp ?? 0) <= 120 {
            if items[i].report.burstId == nil || items[i].report.burstId != items[j].report.burstId,
               let d = dist(i, j), d <= GroupingRules.duplicateDistance {
                items[i].report.nearDuplicateOf = items[j].report.id
                break
            }
            j -= 1
        }
    }

    // Scenes: split on long gaps, or on a content change with a pause.
    var groups: [[Int]] = [[0]]
    for i in 1..<items.count {
        let gap = gaps[i - 1]
        var newScene = gap >= sceneGap
        if !newScene, gap > GroupingRules.sceneMinGapForContent, let last = groups.last {
            // Compare against the scene so far (closest member), so one odd frame doesn't split it.
            let ds = last.suffix(6).compactMap { dist($0, i) }
            if let m = ds.min() {
                if ProcessInfo.processInfo.environment["PHOTOLAB_DEBUG"] != nil {
                    log(String(format: "  scene check %@: gap %.0fs, distance to scene %.3f", items[i].report.id, gap, m))
                }
                if gap > GroupingRules.sceneGapContent && m > GroupingRules.sceneDistance { newScene = true }
                if m > GroupingRules.sceneDistanceShortGap { newScene = true }
            }
        }
        if newScene { groups.append([i]) } else { groups[groups.count - 1].append(i) }
    }

    // Tags on most frames of the shoot ("outdoor", "sky", "people"...) say nothing about a scene.
    var tagFrames: [String: Int] = [:]
    for it in items { for t in Set(it.report.scene.tags.map { $0.label }) { tagFrames[t, default: 0] += 1 } }
    let common = Set(tagFrames.filter { Double($0.value) > GroupingRules.commonTagShare * Double(items.count) }.map { $0.key })

    let timeFmt = DateFormatter()
    timeFmt.dateFormat = "HH:mm"
    return groups.enumerated().map { gi, idx in
        for i in idx { items[i].report.groupId = gi }
        var tagScore: [String: Double] = [:]
        for i in idx { for t in items[i].report.scene.tags.prefix(6) { tagScore[t.label, default: 0] += t.confidence } }
        let generic: Set<String> = ["outdoor", "structure", "people", "adult", "material", "textile", "clothing", "wood processed", "sky"]
        let top = tagScore.sorted { $0.value > $1.value }.map { $0.key }
        let titleTags = top.filter { !generic.contains($0) && !common.contains($0) }.prefix(2)
        let first = items[idx.first!].report.capture.timestamp.map { Date(timeIntervalSince1970: $0) }
        let last = items[idx.last!].report.capture.timestamp.map { Date(timeIntervalSince1970: $0) }
        let range = [first, last].compactMap { $0 }.map { timeFmt.string(from: $0) }
        var title = titleTags.isEmpty ? "Scene \(gi + 1)" : titleTags.joined(separator: " · ").capitalized
        if let a = range.first, let b = range.last { title += a == b ? "  \(a)" : "  \(a)–\(b)" }
        var bs: [[String]] = []
        var seen = Set<Int>()
        for i in idx { if let b = items[i].report.burstId, !seen.contains(b) { seen.insert(b); bs.append(bursts[b]!.map { items[$0].report.id }) } }
        return SceneGroup(id: gi, title: title, start: items[idx.first!].report.capture.dateTimeOriginal,
                          end: items[idx.last!].report.capture.dateTimeOriginal,
                          photoIds: idx.map { items[$0].report.id }, bursts: bs, topTags: Array(top.prefix(6)))
    }
}
