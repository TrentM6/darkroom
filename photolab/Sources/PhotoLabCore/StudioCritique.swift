import Foundation

// "Analysis in the editor": a short read of one frame against the colour street tradition (light, colour,
// subject, moment, composition), built deterministically from the street read and the analysis. Scores
// map the street read's sub-scores (0-100) to 1-5 using cut points set on the photographer's own shoots
// (about 360 frames). Words only name what was measured: gestures and interactions come from the pose
// detector, never guessed. Empty streets are judged on light, colour and geometry, with no moment
// penalty. Small figures and silhouettes are scored conservatively, with fewer words.

public struct CritiqueCriterion: Codable, Equatable {
    public var key: String        // light | color | subject | moment | composition
    public var score: Int         // 1...5
    public var phrase: String     // <= 6 words
    public var detail: String     // one short sentence
}

public struct Critique: Codable, Equatable {
    public var verdict: String    // Keeper | Strong | Workable | Weak
    public var summary: String
    public var criteria: [CritiqueCriterion]
    public var reference: String?
}

/// What the critique needs from the analysis (stored per photo, so it can be rebuilt with the render's colour).
public struct CritiqueContext: Codable {
    var score: StreetScore
    var light: StreetLight
    var color: StreetColor
    var subjectKind: String
    var subjectRect: [Double]?
    var overlap: Bool
    var clutter: Double
    var interaction: String?
    var people: [PersonLite]
    var silhouette: Bool
    var badTech: Bool
    var techFlaw: String? = nil     // eyes-closed | out-of-focus | motion-blur (bad severity)
    struct PersonLite: Codable { var rect: [Double]; var height: Double; var tier: String; var gestures: [String]; var facing: String; var turn: String?; var faceYaw: Double? }
}

/// Colour measured on the edited render (the camera JPEG under-reads colour; the look adds it back).
struct RenderColor {
    var strongPct: Double          // % of non-sky pixels with chroma > 40
    var accent: String?            // hue family of a small, very saturated patch
}

enum StudioCritique {
    static let version = 4

    static func context(_ p: PhotoReport) -> CritiqueContext? {
        guard let st = p.street else { return nil }
        return CritiqueContext(score: st.score, light: st.light, color: st.color, subjectKind: st.subjectKind, subjectRect: st.subjectRect,
                               overlap: st.overlap, clutter: st.clutter, interaction: st.interaction,
                               people: st.people.map { .init(rect: $0.rect, height: $0.height, tier: $0.tier, gestures: $0.pose?.gestures ?? [],
                                                             facing: $0.pose?.facing ?? "unknown", turn: $0.pose?.turn, faceYaw: $0.faceYaw) },
                               silhouette: p.tone.silhouette == true || st.light.subject == "silhouette" || st.light.kind == "backlit",
                               badTech: p.flags.contains { ["eyes-closed", "out-of-focus", "motion-blur"].contains($0.code) && $0.severity == "bad" },
                               techFlaw: ["eyes-closed", "out-of-focus", "motion-blur"].first { c in p.flags.contains { $0.code == c && $0.severity == "bad" } })
    }

    static func make(_ p: PhotoReport) -> Critique? { context(p).map { make($0, render: nil) } }

    static func band(_ v: Double, _ cuts: [Double]) -> Int {   // cuts: 4 ascending thresholds -> 1...5
        var s = 1
        for c in cuts where v >= c { s += 1 }
        return s
    }

    static func make(_ st: CritiqueContext, render: RenderColor?) -> Critique {
        let sc = st.score, L = st.light, C = st.color
        let people = st.people
        let hasPeople = !people.isEmpty && st.subjectKind != "none" || people.count >= 2
        let silhouette = st.silhouette
        let allSmall = !people.isEmpty && people.allSatisfy { $0.height < 0.18 }
        let gestures = people.flatMap { $0.gestures }
        func has(_ g: String) -> Bool { gestures.contains(g) }
        var crit: [CritiqueCriterion] = []

        // Light
        var light = band(sc.light, [35, 50, 66, 80])
        var lp: String, ld: String
        if silhouette {
            light = max(light, 3)
            lp = "Backlit, figures in silhouette"; ld = "The light comes from behind, so shapes read as dark outlines."
        } else if L.kind == "hard sun" && L.subject == "lit" {
            lp = "Hard sun on the subject"; ld = "Direct light picks out the subject against the scene."
        } else if L.kind == "hard sun" && L.shadowShapes >= 15 {
            lp = "Hard sun, strong shadow shapes"; ld = "Bold shadows give the frame its structure."
        } else if L.kind == "hard sun" && L.subject == "in shadow" {
            lp = "Hard sun, subject in shade"; ld = "The light is strong, but the subject sits in shadow."
        } else if L.kind == "hard sun" {
            lp = "Hard, direct sun"; ld = "Strong daylight with clean contrast."
        } else if L.kind == "sun, few shadows" {
            lp = "Bright but shapeless light"; ld = "There is sun, but few shadows to shape the scene."
            light = min(light, 3)
        } else if L.kind == "soft / flat" {
            lp = "Flat, even light"; ld = "Soft light without direction; little to shape the frame."
            light = min(light, 2)
        } else {
            lp = "Mixed light"; ld = "Patches of sun and shade compete."
        }
        crit.append(CritiqueCriterion(key: "light", score: light, phrase: lp, detail: ld))

        // Colour: the street read's score, raised (never lowered) by what the edited render shows.
        var color = band(sc.color, [8, 20, 38, 55])
        if let r = render { color = max(color, band(r.strongPct, [1, 2.5, 6, 10])) }
        var cp: String, cd: String
        if let comp = C.complementary, comp.count == 2 {
            cp = "\(comp[0].capitalized)/\(comp[1]) clash"; cd = "Opposite colours play against each other."
        } else if let f = C.field {
            cp = "Bold \(f) colour field"; cd = "A large block of \(f) holds the frame together."
        } else if let a = C.accent {
            cp = "A single \(a) accent"; cd = "One spot of \(a) draws the eye."
        } else if let a = render?.accent {
            cp = "A small \(a) accent"; cd = "A patch of \(a) gives the eye somewhere to land."
            color = max(color, 2)
        } else if C.character == "busy" {
            cp = "Busy, scattered colour"; cd = "Many colours compete; none leads."
        } else if C.character == "rich" || color >= 4 {
            cp = "Rich colour"; cd = "Saturated colour across the frame."
        } else if C.character == "muted" && color <= 2 {
            cp = "Muted colour"; cd = "Little strong colour outside the sky."
        } else {
            cp = "Some colour, no clear lead"; cd = "Colour is present but nothing stands out."
        }
        crit.append(CritiqueCriterion(key: "color", score: color, phrase: cp, detail: cd))

        // Subject
        var subject = band(sc.subject, [20, 40, 62, 78])
        var sp: String, sd: String
        if st.subjectKind == "person" {
            if allSmall { subject = min(subject, 3); sp = "Small figures"; sd = "The people are small in the frame." }
            else if subject >= 4 { sp = "Clear subject, well separated"; sd = "The subject stands apart from the background." }
            else if st.overlap { sp = "Subject merges with others"; sd = "Figures overlap, so the subject doesn't stand out." }
            else { sp = "Subject present, not dominant"; sd = "There is a subject, but it doesn't hold the eye." }
        } else if st.subjectKind == "object" {
            sp = subject >= 3 ? "A shape anchors the eye" : "A shape, nothing more"
            sd = "No people; an object or sign is the focal point."
        } else {
            subject = min(subject, 2)
            sp = "Nothing anchors the eye"; sd = "There's no clear subject."
        }
        crit.append(CritiqueCriterion(key: "subject", score: subject, phrase: sp, detail: sd))

        // Moment
        var moment: Int, mp: String, md: String
        if !hasPeople {
            // empty street: no penalty, judged on the scene
            moment = 3   // neutral: an empty street isn't penalised (and the moment doesn't count in its verdict)
            mp = "No people; the scene carries it"; md = "There's no moment to read; light and colour have to do the work."
        } else {
            moment = band(sc.moment, [10, 25, 42, 58])
            if let i = st.interaction, i == "facing each other" || i == "hands meet" {
                mp = i == "hands meet" ? "Hands meet" : "Two people face each other"; md = "An exchange between people gives the frame a moment."
            } else if has("mid-stride") {
                mp = "Caught mid-stride"; md = "A step in progress gives the frame energy."
            } else if has("arm raised high") || has("arm raised") {
                mp = "Arm raised"; md = "A raised arm gives the frame a gesture."
            } else if has("hands to head") {
                mp = "Hands to head"; md = "A clear gesture, though it may read as posed."
            } else if has("reaching") {
                mp = "Reaching"; md = "A reach gives the frame some action."
            } else if people.allSatisfy({ $0.facing == "away" }) {
                moment = min(moment, 2); mp = "Backs to the camera"; md = "Faces turned away give little to read."
            } else if moment <= 2 {
                mp = "Static"; md = "Nothing is happening yet."
            } else {
                mp = "Some movement"; md = "People in motion, without a peak instant."
            }
            if silhouette { moment = min(moment, 3); mp = "Gestures hidden in silhouette"; md = "In silhouette, gestures are hard to read." }
            else if allSmall { moment = min(moment, 3); md = "Figures are small; gestures are hard to read." }
        }
        crit.append(CritiqueCriterion(key: "moment", score: moment, phrase: mp, detail: md))

        // Composition
        var compS = band(sc.composition, [40, 55, 75, 90])
        if sc.layering >= 70 { compS = min(5, compS + 1) }
        if st.clutter > 0.35 { compS = max(1, compS - 1) }
        var kp: String, kd: String
        if sc.layering >= 70 && people.count >= 3 { kp = "Layered near, mid and far"; kd = "Depth from figures at several distances." }
        else if st.clutter > 0.35 { kp = "Cluttered edges"; kd = "Busy detail around the edges pulls the eye away." }
        else if st.overlap && hasPeople { kp = "Figures merge"; kd = "Overlapping figures muddy the shapes." }
        else if compS >= 4 { kp = "Clean, balanced frame"; kd = "Edges are clear and the weight is balanced." }
        else { kp = "Loose framing"; kd = "The frame could be tighter or cleaner." }
        crit.append(CritiqueCriterion(key: "composition", score: compS, phrase: kp, detail: kd))

        // Verdict
        let w: [String: Double] = hasPeople
            ? ["subject": 0.25, "moment": 0.25, "light": 0.2, "color": 0.15, "composition": 0.15]
            : ["light": 0.35, "color": 0.35, "composition": 0.2, "subject": 0.1]
        let avg = crit.reduce(0.0) { $0 + Double($1.score) * (w[$1.key] ?? 0) } / w.values.reduce(0, +)
        var verdict = avg >= 4.0 ? "Keeper" : avg >= 3.4 ? "Strong" : avg >= 2.6 ? "Workable" : "Weak"
        let badTech = st.badTech
        if badTech && (verdict == "Keeper" || verdict == "Strong") { verdict = "Workable" }

        // Summary: what carries it, and the main weakness.
        func noun(_ c: CritiqueCriterion) -> String {
            switch c.key {
            case "light": return silhouette ? "the backlight" : (L.kind == "hard sun" ? "hard light" : "the light")
            case "color": return C.complementary != nil ? "the colour clash" : C.field != nil ? "the colour field" : C.accent != nil ? "the \(C.accent!) accent" : render?.accent.map { "the \($0) accent" } ?? "the colour"
            case "subject": return "a clear subject"
            case "moment":
                guard hasPeople else { return "the scene" }
                switch c.phrase {
                case "Arm raised": return "the raised arm"
                case "Caught mid-stride": return "the stride"
                case "Two people face each other", "Hands meet": return "the exchange"
                case "Hands to head": return "the gesture"
                case "Reaching": return "the reach"
                default: return "the movement"
                }
            default: return sc.layering >= 70 ? "the layering" : "the framing"
            }
        }
        func weakness(_ c: CritiqueCriterion) -> String {
            switch c.key {
            case "light": return L.kind == "soft / flat" ? "the light is flat" : "the light lacks shape"
            case "color": return c.phrase == "Muted colour" ? "colour is muted" : "there's little colour"
            case "subject": return st.subjectKind == "none" ? "nothing anchors the eye" : allSmall ? "the subject is small" : "the subject doesn't stand out"
            case "moment": return silhouette ? "gestures are lost in silhouette" : people.allSatisfy({ $0.facing == "away" }) ? "backs are turned" : "the moment is static"
            default: return st.clutter > 0.35 ? "the edges are cluttered" : "the framing is loose"
            }
        }
        let considered = crit.filter { hasPeople || $0.key != "moment" }
        let strong = considered.filter { $0.score >= 4 }.sorted { ($0.score, w[$0.key] ?? 0) > ($1.score, w[$1.key] ?? 0) }
        let weakest = considered.filter { $0.score <= 2 }.sorted { ($0.score, -(w[$0.key] ?? 0)) < ($1.score, -(w[$1.key] ?? 0)) }
        var summary = "\(verdict) frame."
        if verdict == "Weak", let a = weakest.first {
            // a weak frame: name what holds it back, not what "carries" it
            summary += " " + weakness(a).capitalizedFirst + (weakest.count > 1 ? ", and \(weakness(weakest[1]))." : ".")
        } else if let a = strong.first {
            let carry = strong.count >= 2 ? "\(noun(a).capitalizedFirst) and \(noun(strong[1])) carry it" : "\(noun(a).capitalizedFirst) carries it"
            summary += " " + carry + (weakest.first.map { "; \(weakness($0))." } ?? ".")
        } else if let a = weakest.first {
            summary += " " + weakness(a).capitalizedFirst + (weakest.count > 1 ? ", and \(weakness(weakest[1]))." : ".")
        } else {
            summary += " Solid throughout; nothing stands out."
        }
        if badTech {
            switch st.techFlaw {
            case "eyes-closed": summary += " Closed eyes hold it back."
            case "out-of-focus": summary += " Missed focus holds it back."
            default: summary += " Motion blur holds it back."
            }
        }

        // Reference: at most one, only when the hallmark is measured strongly.
        var reference: String? = nil
        if sc.layering >= 90 && people.count >= 3 && Set(people.map { $0.tier }).count >= 3 { reference = "Webb-like layering" }
        else if sc.color >= 65 && C.field != nil { reference = "Gruyaert colour field" }
        else if sc.light >= 88 && L.kind == "hard sun" && L.crispness >= 0.6 && sc.color >= 38 { reference = "Meyerowitz light" }

        return Critique(verdict: verdict, summary: summary, criteria: crit, reference: reference)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension Studio {
    /// Recomputes stored critiques from the project's saved analysis (when the critique rules change).
    func refreshCritiques(_ p: inout ProjectFile) {
        guard let a = Store.read(ShootReport.self, from: analysisURL(p.id)) else { return }
        var byId: [String: PhotoReport] = [:]
        for r in a.photos { byId[r.id] = r }
        for i in p.photos.indices {
            if let r = byId[p.photos[i].id] {
                p.photos[i].critiqueContext = StudioCritique.context(r)
                p.photos[i].cueTags = r.scene.tags.filter { $0.confidence >= 0.3 }.map { $0.label.lowercased() }
            }
        }
        p.critiqueVersion = StudioCritique.version
        dirty.insert(p.id)
    }

    /// One line comparing the frame's render with the learned targets of Best Work (from 5 favorites).
    /// Stats of the photo's current render (cached per render version).
    func renderStats(_ pid: String, _ ph: PhotoEntry) -> RenderStats? {
        let key = "\(pid)/\(ph.id)/\(ph.version)"
        if let c = renderStatsCache[key] { return c }
        let url = engine(pid).previewURL(ph.ref)
        guard FileManager.default.fileExists(atPath: url.path), let m = RenderStats.measure(url) else { return nil }
        renderStatsCache[key] = m
        return m
    }

    /// The critique of the frame as it looks now (colour from the edited render).
    func critique(_ pid: String, _ ph: PhotoEntry) -> Critique? {
        guard let ctx = ph.critiqueContext else { return ph.critique }
        let rc = renderStats(pid, ph).map { RenderColor(strongPct: $0.strongPct, accent: $0.accent) }
        return StudioCritique.make(ctx, render: rc)
    }

    func compareLine(_ pid: String, _ ph: PhotoEntry) -> String? {
        guard let l = lib.learned, l.favorites >= 5, l.measured >= 3, let s = renderStats(pid, ph) else { return nil }
        let t = l.targets
        func sp(_ k: String) -> Double { max(2, t.spread[k] ?? 3) }
        let dSpread = ((s.p95 - s.p5) - (t.p95 - t.p5)) / (sp("p95") + sp("p5"))
        let dChroma = (s.chroma - t.chroma) / sp("chroma")
        let dTone = (s.medianL - t.medianL) / sp("medianL")
        let biggest = [("spread", dSpread), ("chroma", dChroma), ("tone", dTone)].max { abs($0.1) < abs($1.1) }!
        if abs(biggest.1) < 1 { return "In line with your best work in light, colour and tone." }
        switch biggest.0 {
        case "spread": return biggest.1 < 0 ? "Flatter light than your best work." : "More contrast than your best work."
        case "chroma": return biggest.1 < 0 ? "Less colour than your best work." : "Richer colour than your best work."
        default: return biggest.1 < 0 ? "Darker than your best work." : "Brighter than your best work."
        }
    }
}
