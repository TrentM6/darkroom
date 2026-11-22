import Foundation

/// Exposure rules (percent of frame unless noted).
enum ExposureRules {
    static let blownBad = 3.0, blownWarn = 0.75, blownInfo = 0.15   // largest white (all-channel) region
    static let channelClip = 1.0                                     // one channel at 255 on this much of the frame
    static let shadowWarn = 10.0, shadowInfo = 1.5                    // pure black
    // Silhouette / deliberate low-key: lots of near-black with bright areas behind it.
    static let silhouetteDark = 20.0, silhouetteP95 = 75.0, silhouetteRegion = 3.0
}

/// Score penalties per flag severity, so the score always matches what the flags say.
enum ScorePenalty {
    static let exposure: [String: Double] = ["bad": 35, "warn": 12, "info": 0]
    static let composition: [String: Double] = ["bad": 30, "warn": 15, "info": 0]
    static let eyesClosed = 15.0
    static let weights = (sharpness: 0.5, exposure: 0.3, composition: 0.2)
}

/// Turns measurements into flags, plain-language findings and a technical score.
/// Every rule is a fixed threshold, so the same file always gets the same verdict.
func assess(_ p: inout PhotoReport) {
    var flags: [Flag] = []
    var notes: [String] = []
    let t = p.tone, c = p.capture, f = p.fuji
    func add(_ code: String, _ sev: String, _ area: String, _ msg: String) { flags.append(Flag(code: code, severity: sev, area: area, message: msg)) }

    // Exposure ------------------------------------------------------------
    let blown = t.largestHighlightRegion
    let hiBad = blown >= ExposureRules.blownBad
    let hiWarn = !hiBad && blown >= ExposureRules.blownWarn
    let hiInfo = !hiBad && !hiWarn && blown >= ExposureRules.blownInfo
    if hiBad {
        add("highlights-blown", "bad", "exposure", String(format: "Highlights blown to pure white over %.1f%% of the frame in one area. That detail can't be recovered from a JPEG.", blown))
    } else if hiWarn {
        add("highlights-clipping", "warn", "exposure", String(format: "A white area is clipped (%.1f%% of the frame). Check it isn't on the subject.", blown))
    } else if hiInfo {
        add("highlights-clipping", "info", "exposure", String(format: "Small clipped white area (%.2f%% of the frame), likely sky, a light or a reflection.", blown))
    }
    let chans = t.highlightClipChannels
    if let m = chans.max(), m >= ExposureRules.channelClip, m > 3 * max(0.01, t.highlightClipAll) {
        let name = ["red", "green", "blue"][chans.firstIndex(of: m)!]
        add("channel-clip", "info", "color", String(format: "The %@ channel reaches 255 on %.1f%% of the frame (saturated %@ tones, not white), so fine texture in them is flattened.", name, m, name))
    }
    let dark = t.darkFraction ?? 0, p95 = t.lstarP95 ?? 100
    let silhouette = dark >= ExposureRules.silhouetteDark && p95 >= ExposureRules.silhouetteP95 && t.largestShadowRegion >= ExposureRules.silhouetteRegion
    p.tone.silhouette = silhouette
    if silhouette {
        add("silhouette", "info", "exposure", String(format: "Low-key / silhouette: %.0f%% of the frame is near-black against bright areas (L* p95 %.0f). Reads as deliberate, so there's no exposure penalty.", dark, p95))
    } else if t.shadowClip >= ExposureRules.shadowWarn {
        add("shadows-crushed", "warn", "exposure", String(format: "Shadows crushed: %.1f%% of the frame is pure black.", t.shadowClip))
    } else if t.shadowClip >= ExposureRules.shadowInfo {
        add("shadows-clipping", "info", "exposure", String(format: "%.1f%% of the frame is pure black (deep shadow, e.g. a doorway).", t.shadowClip))
    }
    if (hiBad || hiWarn) && t.shadowClip >= ExposureRules.shadowInfo && !silhouette {
        add("range-exceeded", "info", "exposure", String(format: "Clipped at both ends: the scene's contrast exceeded what this JPEG holds (%.1f stops used).", t.tonalRangeStops))
    }
    if hiBad || hiWarn, let f {
        if f.dynamicRange?.hasPrefix("DR100") == true {
            var msg = "Shot at \(f.dynamicRange!)."
            if let iso = c.iso {
                msg += iso >= 640 ? " DR400 was available at ISO \(iso) and holds about 2 more stops of highlights."
                    : iso >= 320 ? " DR200 was available at ISO \(iso) (about 1 more stop of highlights)."
                    : " DR200 needs ISO 320+ and DR400 needs ISO 640+ on the X-Pro3 (this was ISO \(iso))."
            }
            add("dr-suggestion", "info", "camera", msg)
        }
        if let ht = f.highlightTone, ht > 0 {
            add("highlight-tone", "info", "camera", String(format: "Highlight Tone was +%g, which adds highlight contrast and makes clipping more likely.", ht))
        }
    }
    if !silhouette && t.medianLstar < 18 && p95 < 55 {
        add("dark", "warn", "exposure", String(format: "Underexposed: median L* %.0f and even the bright tones stop at L* %.0f.", t.medianLstar, p95))
    }
    notes.append(String(format: "Exposure: median L* %.0f, bright tones (p95) L* %.0f (%@)%@. %.1f stops of tonal range used.", t.medianLstar, p95, t.key, silhouette ? ", silhouette" : "", t.tonalRangeStops))

    // Focus ---------------------------------------------------------------
    let s = p.sharpness
    let subjectFaces = p.faces.filter { $0.isSubject == true }
    if let fw = s.frameWidth {
        let b = s.bestWidth ?? fw
        let what = "the sharpest fifth of the frame"
        let moving = s.motionHint != nil && fw > SharpnessScale.sharp
        if fw > SharpnessScale.soft {
            add(moving ? "motion-blur" : "out-of-focus", "bad", "focus", moving
                ? String(format: "Blurred by motion: even %@ takes %.1f px to rise at 100%% (crisp ≈ 3), smeared %@ly across %.0f%% of the frame. Camera or subject movement, not focus.", what, fw, s.motionHint!, (s.motionFraction ?? 0) * 100)
                : String(format: "Nothing is sharp: even %@ takes %.1f px to rise at 100%% (crisp ≈ 3).", what, fw))
        } else if fw > SharpnessScale.slight {
            if moving {
                add("motion-blur", "warn", "focus", String(format: "Motion blur: %@ takes %.1f px to rise at 100%% (crisp ≈ 3), wider %@ly in %.0f%% of the frame. Camera shake or movement.", what, fw, s.motionHint!, (s.motionFraction ?? 0) * 100))
            } else {
                add("soft", "warn", "focus", String(format: "Soft at 100%%: %@ takes %.1f px to rise (crisp ≈ 3). Fine at web size.", what, fw))
            }
        } else if fw > SharpnessScale.sharp {
            add("soft", "info", "focus", String(format: "Slightly soft at 100%%: %@ takes %.1f px to rise (crisp ≈ 3). Not visible at normal viewing size.", what, fw))
        }
        // Focus off the subject (faces only; Vision's attention map often lands on naturally soft
        // things like shadows or haze). Faces read 0.5-1 px wider than flat detail even when crisp,
        // hence the 1.5 px margin. With several main faces, the sharpest one counts.
        let faceWs = subjectFaces.compactMap { f in f.edgeWidth.map { (f, $0) } }
        if let sharpest = faceWs.min(by: { $0.1 < $1.1 }), fw <= SharpnessScale.sharp {
            if sharpest.1 > SharpnessScale.slight, sharpest.1 > fw + 1.5 {
                add("focus-off-subject", "warn", "focus", String(format: "Focus missed the %@: the eye area takes %.1f px to rise vs %.1f px in the sharp part of the frame, so focus landed elsewhere.", faceWs.count > 1 ? "main faces" : "main face", sharpest.1, fw))
            } else if faceWs.count > 1, let softest = faceWs.max(by: { $0.1 < $1.1 }), softest.1 > SharpnessScale.slight, softest.1 > sharpest.1 + 1.2 {
                let side = softest.0.rect[0] + softest.0.rect[2] / 2 < 0.5 ? "left" : "right"
                add("face-soft", "info", "focus", String(format: "The %@ face is softer than the other (%.1f vs %.1f px): it sits outside the depth of field.", side, softest.1, sharpest.1))
            }
        }
        notes.append(String(format: "Sharpness: %@ (sharpest fifth of the frame %.1f px at 100%%, whole-frame median %.1f px%@).", s.level, fw, s.globalWidth ?? fw,
                            s.subjectWidth.map { String(format: ", subject %.1f px", $0) } ?? ""))
    } else {
        notes.append("Sharpness: no measurable edges (featureless or very dark frame).")
    }
    if s.shakeRisk, let sh = c.shutter, let lim = s.handheldLimit {
        let fw = s.frameWidth ?? 0
        let soft = fw > SharpnessScale.slight
        add("shake-risk", soft ? "warn" : "info", "focus", "\(sh) is slower than the \(lim) handheld guideline for this focal length (the X-Pro3 has no stabilisation)"
            + (soft ? String(format: ", and the frame is %@ (%.1f px).", s.level, fw) : String(format: ", but the frame still measures %@ (%.1f px).", s.level, fw)))
    }

    // Faces ---------------------------------------------------------------
    let closedFaces = subjectFaces.filter { $0.eyesState == "closed" }
    if !closedFaces.isEmpty {
        add("eyes-closed", "bad", "faces", subjectFaces.count == 1 ? "Eyes closed or mid-blink on the main face." : "\(closedFaces.count) of \(subjectFaces.count) main faces have eyes closed or mid-blink.")
    }
    let hidden = subjectFaces.filter { $0.eyesState == "hidden" }
    if !hidden.isEmpty {
        add("eyes-hidden", "info", "faces", hidden.count == 1 ? "Eyes hidden behind sunglasses, so open/closed isn't judged." : "\(hidden.count) main faces wear sunglasses, so their eyes aren't judged.")
    }
    if subjectFaces.contains(where: { $0.touchesEdge && $0.rect[2] * $0.rect[3] > 0.01 }) {
        add("face-cut", "warn", "composition", "A main face is cut off by the frame edge.")
    }
    if let sf = subjectFaces.max(by: { $0.rect[2] * $0.rect[3] < $1.rect[2] * $1.rect[3] }), let off = sf.skinOffset, abs(off) > 12 {
        add("skin-off", "info", "color", String(format: "Skin sits %.0f° %@ the skin-tone line (vectorscope %.0f° vs 123°); film simulations shift it on purpose.", abs(off), off > 0 ? "toward yellow/green from" : "toward red/magenta from", sf.skinAngle ?? 0))
    }

    // Composition ---------------------------------------------------------
    let comp = p.composition
    if let tilt = comp.horizonTilt, abs(tilt) >= TiltRules.flagDegrees, (comp.tiltConfidence ?? 0) >= TiltRules.flagConfidence {
        add("tilted", "warn", "composition", String(format: "Frame is rotated %.1f° %@ (from %@, confidence %.0f%%). Rotate %.1f° %@ to level, unless the cant is deliberate.", abs(tilt), tilt > 0 ? "clockwise" : "counter-clockwise", comp.tiltSource ?? "lines", (comp.tiltConfidence ?? 0) * 100, abs(tilt), tilt > 0 ? "counter-clockwise" : "clockwise"))
    }
    if let k = comp.keystone, k >= 2 {
        add("keystone", "info", "composition", String(format: "Verticals converge toward the top (about %.0f° each side): the camera was tipped up. Lightroom's Upright / Transform can correct it if you want straight verticals.", k))
    }
    if !comp.brightEdges.isEmpty {
        add("bright-edge", "info", "composition", "A small bright patch touches the \(comp.brightEdges.joined(separator: " and ")) edge and can pull the eye out of the frame.")
    }
    var tiltNote = ""
    if let tilt = comp.horizonTilt {
        let flagged = abs(tilt) >= TiltRules.flagDegrees && (comp.tiltConfidence ?? 0) >= TiltRules.flagConfidence
        tiltNote = flagged ? String(format: " Rotated %.1f°.", tilt) : abs(tilt) < TiltRules.flagDegrees ? " Level within 1.5°." : String(format: " Possible %.1f° tilt, low confidence.", tilt)
    }
    notes.append("Composition: subject (\(comp.subjectSource)) \(comp.placement)." + tiltNote)

    // Colour --------------------------------------------------------------
    // No cast verdict: film simulations (Classic Negative here) shift neutrals on purpose.
    let col = p.color
    if col.saturationClip >= 1 {
        add("sat-clip", "info", "color", String(format: "%.1f%% of pixels are saturated to the edge of sRGB, so fine colour detail is lost there.", col.saturationClip))
    }
    notes.append(String(format: "Colour: mean chroma %.0f%@.", col.meanChroma, f.map { ", \($0.filmSimulation)" } ?? ""))

    // Noise ---------------------------------------------------------------
    let grainOn = (f?.grainEffect ?? "Off") != "Off"
    if grainOn, let f {
        p.noise.level = "Grain Effect \(f.grainEffect) (film grain, not sensor noise)"
        notes.append("Grain: Grain Effect \(f.grainEffect), intentional; sharpness is measured through it.")
    } else if let n = p.noise.lumaSigma {
        if n >= 4 { add("noise-high", "warn", "noise", String(format: "Heavy noise (σ %.1f levels in flat midtones).", n)) }
        notes.append(String(format: "Noise: %@ (σ %.2f levels).", p.noise.level, n))
    }

    if let f, !f.cameraWarnings.isEmpty {
        add("camera-warning", "info", "camera", "The camera recorded: \(f.cameraWarnings.joined(separator: ", ")).")
    }

    p.flags = flags.sorted { rank($0.severity) < rank($1.severity) }
    p.summary = notes
}

private func rank(_ s: String) -> Int { s == "bad" ? 0 : s == "warn" ? 1 : 2 }

/// Technical score only, not taste. Sharpness comes from the frame width; exposure and composition
/// lose points only for their flags (info costs nothing), so the score always agrees with the flags.
func score(_ p: PhotoReport) -> ScoreBreakdown {
    let sharp = sharpnessScore(p.sharpness.frameWidth ?? SharpnessScale.missed)
    var expo = 100.0, comp = 100.0
    for f in p.flags {
        if f.area == "exposure" { expo -= ScorePenalty.exposure[f.severity] ?? 0 }
        if f.area == "composition" { comp -= ScorePenalty.composition[f.severity] ?? 0 }
    }
    expo = max(0, expo); comp = max(0, comp)
    let w = ScorePenalty.weights
    var total = sharp * w.sharpness + expo * w.exposure + comp * w.composition
    var eyes: Double? = nil
    let subj = p.faces.filter { $0.isSubject == true }
    if subj.contains(where: { $0.eyesState == "closed" }) { eyes = 20; total -= ScorePenalty.eyesClosed }
    else if subj.contains(where: { $0.eyesState == "open" }) { eyes = 100 }
    return ScoreBreakdown(total: round1(max(0, total)), sharpness: round1(sharp), exposure: round1(expo), composition: round1(comp), eyes: eyes)
}
