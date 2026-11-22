import CoreGraphics
import Foundation
import ImageIO

// "Analysis by Claude": a critique of one photo by Claude, through the photographer's own Claude Code
// login (the installed `claude` CLI, headless). On demand only, one call at a time, never in the
// background. Claude gets two files (the unedited camera JPEG and the current edit, 1600 px each) and the
// edit settings as text; it judges the picture (seeing) and the print (finish) separately and links
// every problem it names to a remedy (slider changes, a crop, a straighten or a reshoot note). The call
// runs in a temp folder with just the Read tool, no MCP servers, no saved session and a clean
// environment, and only for the allowed account. Results are validated against the photo (valid params,
// in-range values, sane crops), cached per photo and params; a cached critique of older params is `stale`.

public struct AICriterion: Codable, Equatable {
    public var score: Int
    public var note: String
}

/// One slider change. `change` is in the slider's units; `from`/`to` are filled in by the server from
/// the photo's current params (the change is clamped so `to` stays in range).
public struct AIParamChange: Codable, Equatable {
    public var param: String
    public var change: Double
    public var from: Double?
    public var to: Double?
    public var why: String?
}

public struct AIRect: Codable, Equatable {
    public var x: Double, y: Double, w: Double, h: Double
}

/// The remedy for one criterion: type "params" | "crop" | "straighten" | "reshoot".
public struct AIFix: Codable, Equatable {
    public var type: String
    public var changes: [AIParamChange]?
    public var aspect: String?
    public var rect: AIRect?
    public var degrees: Double?
    public var to: Double?            // straighten: the resulting rotate value
    public var note: String?
    public var why: String?
}

public struct AIItem: Codable, Equatable {
    public var score: Int
    public var note: String
    public var fix: AIFix?
    /// The panel member whose standard this criterion applies (set by the server, see StudioAI.judges).
    public var judge: String?
}

public struct AIPicture: Codable, Equatable {
    public var moment: AIItem?
    public var wit: AIItem?
    public var composition: AIItem?
    public var light: AIItem?
    public var subject: AIItem?
}

public struct AIPrint: Codable, Equatable {
    public var color: AIItem?
    public var saturation: AIItem?
    public var density: AIItem?
    public var contrast: AIItem?
    public var vignette: AIItem?
    public var crispness: AIItem?
}

public struct AICritique: Codable, Equatable {
    public var version: Int?
    public var panel: [String]?
    public var verdict: String
    public var summary: String
    public var picture: AIPicture?
    public var print: AIPrint?
    public var editVsOriginal: String?
    public var fixes: [AIParamChange]?
    public var reshoot: String?
    /// Criteria scored 3 or lower that came back without a usable fix (should be empty).
    public var unfixed: [String]?
    // v1 fields, still filled for older UI code: light/subject/moment/composition from the picture,
    // color from the print, intangibles = wit, suggestion = reshoot or the first fix.
    public var light: AICriterion?
    public var color: AICriterion?
    public var subject: AICriterion?
    public var moment: AICriterion?
    public var composition: AICriterion?
    public var intangibles: String?
    public var suggestion: String?
    // bookkeeping
    public var model: String?
    public var paramsHash: String?
    public var createdAt: String?
    public var ms: Int?
}

enum StudioAI {
    static let version = 2

    static var cli: URL? {
        let fm = FileManager.default
        var c: [String] = []
        if let e = ProcessInfo.processInfo.environment["PHOTOLAB_CLAUDE"] { c.append(e) }
        c += [NSHomeDirectory() + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", NSHomeDirectory() + "/.claude/local/claude"]
        return c.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    /// The model asked for first; "sonnet" is the fallback when it isn't available on the plan.
    static var model: String { ProcessInfo.processInfo.environment["PHOTOLAB_CRITIQUE_MODEL"] ?? "opus" }
    static let fallbackModel = "sonnet"
    static var effort: String { ProcessInfo.processInfo.environment["PHOTOLAB_CRITIQUE_EFFORT"] ?? "high" }

    /// Slider ranges and steps (the editor's units) for the params Claude may change.
    static let ranges: [(key: String, lo: Double, hi: Double, step: Double, meaning: String)] = [
        ("exposure", -2, 2, 0.05, "EV; + = brighter"),
        ("contrast", 0, 100, 1, "global tone-curve contrast"),
        ("highlights", -100, 100, 1, "+ = recover/darken highlights, - = brighten them"),
        ("shadows", -100, 100, 1, "+ = lift/open shadows, - = deepen them"),
        ("blacks", -50, 50, 1, "- = deeper/crushed blacks, + = lifted/matte blacks"),
        ("punch", 0, 100, 1, "local contrast/clarity; high values look crunchy or HDR"),
        ("vibrance", -100, 100, 1, "saturation of the muted colours"),
        ("saturation", -100, 100, 1, "saturation of all colours"),
        ("warmth", -50, 50, 1, "+ = warmer/yellower, - = cooler/bluer"),
        ("tint", -50, 50, 1, "+ = magenta, - = green"),
        ("filmStrength", 0, 100, 1, "strength of the film look (LUT)"),
        ("vignette", 0, 100, 1, "darkening of the corners; 0 = none"),
        ("sharpen", 0, 100, 1, "capture sharpening"),
        ("grain", 0, 100, 1, "added film grain; 0 = none"),
    ]
    static func range(_ key: String) -> (lo: Double, hi: Double, step: Double)? {
        ranges.first { $0.key == key }.map { ($0.lo, $0.hi, $0.step) }
    }
    static let cropAspects = ["original", "3:2", "4:5", "1:1", "16:9"]

    /// The photographer's panel (work/studio-spec.md, "The panel") and whose standard each criterion applies.
    static let panel = ["Meyerowitz", "Levitt", "Davidson", "Eggleston", "Leiter", "Webb"]
    static let judges: [String: String] = [
        "picture.light": "Meyerowitz", "picture.wit": "Levitt", "picture.moment": "Levitt",
        "picture.composition": "Webb", "picture.subject": "Webb",
        "print.color": "Eggleston", "print.saturation": "Eggleston", "print.crispness": "Eggleston",
        "print.density": "Davidson", "print.contrast": "Davidson", "print.vignette": "Leiter",
    ]

    /// The starting taste for a new library (anyone's photography); the photographer rewrites it in their own words.
    static let genericTaste = """
    What makes a picture good:
    - Something is happening, or something is seen: a gesture, an expression, an encounter, a quality of light, caught at its best.
    - Wit and surprise matter: coincidence, juxtaposition, things that line up by chance, a frame that makes you look twice.
    - A clear subject: you know what the picture is about.
    - Deliberate composition: clean edges, nothing cut off awkwardly, no clutter that fights the subject.
    - Light that does something.
    What makes a print good:
    - True, balanced colour (or tone), rich but never garish.
    - Readable shadows and highlights; weight without murk.
    - Natural contrast; no visible effects, heavy vignettes or HDR look.
    - Crisp where it matters.
    What the critique is for: honest reassurance about what already works, and a clear way to fix every problem.
    """

    /// Earlier built-in defaults, replaced by the general taste when found in a catalog (a taste the photographer
    /// wrote is always kept).
    static let legacyTastePrefixes = ["Restrained, accurate colour in the Kodachrome tradition"]

    static let system = """
    You are the picture editor and master colour printer this street photographer trusts most. You speak for a panel of six photographers they chose. You know their work well, and you hold every frame to what made their photographs great.

    THE PANEL: what made their work great, and what each judges here.

    Joel Meyerowitz judges LIGHT. He took colour into the street when serious photographers still worked in black and white, on Fifth Avenue in the 1960s and 70s, with a Leica and Kodachrome. His pictures are about the whole field, not one subject: several unrelated things happening at once, held together by the light. Light is his subject: a hard edge of sun, a glow in shade, light turning ordinary colour into an event. He asks whether the light is doing something, and whether the colour is true and alive without being forced.

    Helen Levitt judges WIT and the MOMENT. On the streets of New York she caught everyday life as theatre: children playing, gestures between strangers, bodies doing something funny or tender, always with affection, never mockery. Her colour work of the 1970s kept the same eye. She asks whether something is happening, whether it is caught at its peak, and whether there is wit: a visual joke, a coincidence, a juxtaposition, a gesture that becomes more than itself.

    Alex Webb judges COMPOSITION and SUBJECT. His frames are built in layers: hard light and deep shadow carve the picture into compartments, each with a figure or event, and every edge is active. Complex but never confused. He asks whether the frame is balanced and controlled to its edges, whether the layers work or just clutter, and whether the picture is clearly about something.

    William Eggleston judges the print's COLOUR, SATURATION and CRISPNESS. He found the extraordinary in ordinary things and made colour itself the subject, printed by dye transfer: deep, rich, exact colour that is never garish. He asks whether the colour is balanced and true (whites, skin, sky, neutrals), whether it is rich without tipping into neon, and whether detail holds where it matters.

    Bruce Davidson judges the print's DENSITY and CONTRAST. His Subway pictures of 1980s New York are dense, dark, saturated and tough, with weight in the shadows, but you can always read the people. He asks whether the print has weight and grit while staying readable, or whether it is crushed, muddy, overcooked or too dark.

    Saul Leiter judges RESTRAINT, in the VIGNETTE and in any effect. His New York colour is quiet and painterly: small accents of colour, soft layers of glass, snow and shadow, nothing forced. He asks whether anything in the print calls attention to itself: darkened corners, extra punch, extra saturation, an edit you can see.

    Their shared standard: gritty and dense like New York, but true colour, readable shadows, natural local contrast and no visible effects. Not Davidson-crushed, not Eggleston-neon, not over-vignetted.

    HOW YOU JUDGE

    You judge two things separately. The picture is what was seen and caught at the moment of exposure; no edit can change it. The print is how the edit renders it. For the print, restraint is the standard: more saturation, contrast, punch or vignette is not an improvement. You never praise colour that is oversaturated, garish or neon; you name it. You say plainly when an edit is too dark, too punchy, too saturated or too heavily vignetted.

    You look hard before you speak. Go edge to edge. Then look at hands, heads, faces and gestures; what overlaps what; signs and words; reflections; what is cut by the frame edge; and every place where the edit differs from the camera original. Look actively for wit, because in street photography it is often the whole point. It takes many forms: overlaps and alignments that change what a body or object seems to be, signs or images that comment on the people near them, coincidences of shape, colour or line, figures that echo or mirror each other, odd scale, gestures that read as something else. Never invent wit that is not there.

    HOW YOU WRITE

    Write each note as that judge's standard applied to this frame, concretely and in plain words: what Eggleston would do to these colours, what Davidson would keep or open up here. A judge is never named as praise in itself or to flatter.

    Every remark is about something visible in this frame; if a sentence could describe another photo, rewrite it. Never use stock phrases such as "vibrant", "striking", "draws the eye", "sense of place", "adds depth", "tells a story", "nicely composed", "pops" or "works well". No flattery, no hedging, no jargon.

    Be demanding, exact and honest, and on the photographer's side. Say clearly what already works, so they can trust it. Give every problem its remedy. Answer with one JSON object and nothing else.
    """

    static let template = """
    {
      "verdict": "Keeper | Strong | Workable | Weak",
      "summary": "two short sentences: the main strength, then the main problem",
      "picture": {
        "moment":      {"score": 1-5, "note": "...", "fix": null | FIX},
        "wit":         null | {"score": 1-5, "note": "what the wit is, where it is in the frame, and whether it is the point", "fix": null | FIX},
        "composition": {"score": 1-5, "note": "...", "fix": null | FIX},
        "light":       {"score": 1-5, "note": "...", "fix": null | FIX},
        "subject":     {"score": 1-5, "note": "...", "fix": null | FIX}
      },
      "print": {
        "color":      {"score": 1-5, "note": "...", "fix": null | FIX},
        "saturation": {"score": 1-5, "note": "...", "fix": null | FIX},
        "density":    {"score": 1-5, "note": "...", "fix": null | FIX},
        "contrast":   {"score": 1-5, "note": "...", "fix": null | FIX},
        "vignette":   {"score": 1-5, "note": "...", "fix": null | FIX},
        "crispness":  {"score": 1-5, "note": "...", "fix": null | FIX}
      },
      "editVsOriginal": "one sentence",
      "fixes": [{"param": "saturation", "change": -15, "why": "short"}],
      "reshoot": null | "one sentence"
    }

    FIX is exactly one of:
      {"type": "params", "changes": [{"param": "<slider>", "change": <signed number>}], "why": "short"}
      {"type": "crop", "aspect": "original | 3:2 | 4:5 | 1:1 | 16:9", "rect": {"x": 0-1, "y": 0-1, "w": 0-1, "h": 0-1}, "why": "short"}
      {"type": "straighten", "degrees": <signed number, + = counter-clockwise>, "why": "short"}
      {"type": "reshoot", "note": "what to do differently when shooting, for what no edit can fix"}
    """

    static func prompt(original: String, edit: String, settings: [String], facts: [String], taste: String,
                       judges j: [String: String] = judges, defaultPanel: Bool = true, attached: Bool = false) -> String {
        let sliders = ranges.map { "\($0.key)" }.joined(separator: ", ")
        func w(_ k: String) -> String { j[k] ?? "the panel" }
        let files = attached ? """
        Two images show the same photograph:
        1. ORIGINAL (the first image): the camera's own JPEG, unedited, full frame.
        2. EDIT (the second image): the photographer's current edit, exactly as it will print (cropped if a crop is set).

        Study them closely and compare them before you write anything.
        """ : """
        Two files show the same photograph:
        1. ORIGINAL: the camera's own JPEG, unedited, full frame: \(original)
        2. EDIT: the photographer's current edit, exactly as it will print (cropped if a crop is set): \(edit)

        Open both with the Read tool. Study them closely and compare them before you write anything.
        """
        let standard = defaultPanel ? "hold it to the restrained, accurate colour of Kodachrome and dye-transfer prints."
            : "hold it to the photographer's standard above, through the panel's eyes."
        return """
        \(files)

        The panel judges this frame, each on their part, as described in your brief.

        THE PHOTOGRAPHER, in their own terms (hold both the picture and the print to this):
        \(taste.isEmpty ? "(none given)" : taste)

        CURRENT EDIT SETTINGS (slider units; range in brackets):
        \(settings.map { "- " + $0 }.joined(separator: "\n"))

        FACTS MEASURED BY THE SOFTWARE (may be wrong; trust your eyes over them):
        \(facts.isEmpty ? "- none" : facts.map { "- " + $0 }.joined(separator: "\n"))

        Judge two things separately.

        A. THE PICTURE (seeing). Judge it from both images; editing can't change it.
        - moment (\(w("picture.moment"))): gesture, timing, expression. Is something happening, and is it caught at its peak?
        - wit (\(w("picture.wit"))): look for it actively, as described in your brief. If there is one, say exactly what it is, \
        where it is in the frame and whether it is the point of the picture. If there is none, wit is null; \
        never invent one.
        - subject (\(w("picture.subject"))): what the picture is of, and whether that is clear.
        - composition (\(w("picture.composition"))): balance, placement, edges, layering, clutter, tilt.
        - light (\(w("picture.light"))): the quality and direction of the light on the subject.

        B. THE PRINT (finish). Judge the EDIT, compare it with the ORIGINAL, and \(standard)
        - color (\(w("print.color"))): overall balance and casts: skin, whites, neutrals, sky.
        - saturation (\(w("print.saturation"))): say plainly if it is oversaturated, garish or neon, or if it is right.
        - density (\(w("print.density"))): too dark, too bright, blocked shadows, crushed blacks, blown highlights?
        - contrast (\(w("print.contrast"))): global contrast and punch (local contrast). Is it over-processed, crunchy, \
        haloed or HDR-looking?
        - vignette (\(w("print.vignette"))): is darkening toward the edges visible? Heavy or obvious vignetting is a flaw.
        - crispness (\(w("print.crispness"))): sharpness and detail where it matters; grain; softness.

        SCORES are 1 to 5. For the print, 5 means that aspect is right as it is; 3 or lower means it needs work.

        HARD RULE: every criterion scored 3 or lower must name its problem in the note and carry a fix that \
        remedies it. Choose the fix that really addresses the problem:
        - "params": slider changes from the current values above, in those units, keeping the result inside \
        the range. Allowed sliders: \(sliders). Make each change big enough to see and no bigger than needed.
        - "crop": rect is normalized 0 to 1 to the full ORIGINAL frame (x, y = top-left corner), covers at \
        least 40% of the frame, and matches the aspect.
        - "straighten": degrees to rotate (+ = counter-clockwise); only for a visible tilt.
        - "reshoot": for what no edit can fix (the moment, a gesture, a subject facing away, the background).
        A criterion scored 4 or 5 may have a fix, or null.

        verdict needs both the picture and the print. Keeper: a picture that will last, printed right. A strong \
        picture with a flawed print is at most Strong until the print is fixed. A weak picture can't be \
        rescued by the print.
        summary: exactly two short sentences (at most 45 words in all), specific to this frame: the main \
        strength, then the main problem. No flattery, no description for its own sake.
        editVsOriginal: one sentence on what the edit improved and what it harmed, compared with the ORIGINAL.
        fixes: all slider changes from the "params" fixes above, combined into one list, one entry per slider \
        (0 to 5 entries).
        reshoot: one sentence on what to do differently next time, or null.

        Reply with only this JSON (no markdown fences, no text before or after):
        \(template)
        """
    }

    /// The child's whole environment. Built from scratch, so ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN,
    /// CLAUDE_CODE_OAUTH_TOKEN, CLAUDE_CONFIG_DIR, Bedrock/Vertex switches and the like never reach the CLI:
    /// it can only use the claude.ai login stored for this Mac user (the one the account check reads).
    static func childEnvironment() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        var clean: [String: String] = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
                                       "LANG": env["LANG"] ?? "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
        if let u = env["USER"] { clean["USER"] = u }          // needed for the login in the keychain
        if let l = env["LOGNAME"] { clean["LOGNAME"] = l }
        for k in clean.keys where k.hasPrefix("ANTHROPIC_") || k.hasPrefix("CLAUDE_") || k.hasPrefix("AWS_") || k.hasPrefix("GOOGLE_") { clean[k] = nil }
        return clean
    }

    enum Account: Equatable { case signedIn(String), signedOut, unknown }

    /// Who the CLI is signed in as, from `claude auth status --json` (run with the same environment as the
    /// critique call, ~0.2 s, no model call). Falls back to the email in the CLI's config file. Only the
    /// login state, method and email are read; nothing else from either source is kept or logged.
    static func signedInAccount(cli: URL) -> Account {
        let proc = Process()
        proc.executableURL = cli
        proc.arguments = ["auth", "status", "--json"]
        proc.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        proc.environment = childEnvironment()
        let out = Pipe()
        proc.standardOutput = out; proc.standardError = FileHandle.nullDevice; proc.standardInput = FileHandle.nullDevice
        var data = Data()
        let lock = NSLock()
        out.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; lock.lock(); data.append(d); lock.unlock() }
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        var status: [String: Any]?
        if (try? proc.run()) != nil {
            if done.wait(timeout: .now() + 15) == .timedOut { proc.terminate(); _ = done.wait(timeout: .now() + 2) }
            else {
                out.fileHandleForReading.readabilityHandler = nil
                lock.lock(); data.append(out.fileHandleForReading.readDataToEndOfFile()); let d = data; lock.unlock()
                status = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            }
        }
        if let st = status, let loggedIn = st["loggedIn"] as? Bool {
            guard loggedIn else { return .signedOut }
            // Only a claude.ai subscription login counts; an API key or a cloud provider is never accepted.
            guard (st["authMethod"] as? String) == "claude.ai", (st["apiProvider"] as? String ?? "firstParty") == "firstParty",
                  let e = st["email"] as? String, e.contains("@") else { return .unknown }
            return .signedIn(e)
        }
        // Older CLIs without `auth status --json`: read oauthAccount.emailAddress from the config file the
        // child uses (CLAUDE_CONFIG_DIR is not passed to it, so that is always ~/.claude.json).
        let path = ProcessInfo.processInfo.environment["PHOTOLAB_CLAUDE_CONFIG_FILE"] ?? NSHomeDirectory() + "/.claude.json"
        guard let d = FileManager.default.contents(atPath: path), let cfg = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return .unknown }
        if cfg["primaryApiKey"] != nil { return .unknown }   // an API key is configured: can't be sure it isn't used
        guard let e = (cfg["oauthAccount"] as? [String: Any])?["emailAddress"] as? String, e.contains("@") else { return .unknown }
        return .signedIn(e)
    }

    /// nil when the signed-in account is the allowed one; otherwise the message to show (and Claude isn't called).
    static func accountRefusal(cli: URL, allowed: String) -> String? {
        let lock = allowed.trimmingCharacters(in: .whitespaces)
        if lock.isEmpty {
            // No account lock: any login will do; only a missing one stops the call here.
            return signedInAccount(cli: cli) == .signedOut ? "Claude Code isn't signed in. Open Terminal, run claude and sign in." : nil
        }
        switch signedInAccount(cli: cli) {
        case .signedIn(let e) where e.caseInsensitiveCompare(allowed.trimmingCharacters(in: .whitespaces)) == .orderedSame: return nil
        case .signedIn(let e): return "Claude is signed in as \(e). Darkroom only uses \(allowed)."
        case .signedOut: return "Claude Code isn't signed in. Open Terminal, run claude and sign in as \(allowed)."
        case .unknown: return "Couldn't confirm the Claude account."
        }
    }


    struct Failure: Error {
        var message: String
        var detail: String = ""
        var retryable: Bool = false
        var modelUnavailable: Bool = false
    }

    /// Runs the CLI once. Returns the parsed critique, or a plain-language failure.
    static func run(original: URL, edit: URL, settings: [String], facts: [String], taste: String, model: String,
                    allowedAccount: String, panel: [String]? = nil, timeout: TimeInterval = 240) -> Result<AICritique, Failure> {
        guard let cli else { return .failure(Failure(message: "Claude Code isn't installed on this Mac.")) }
        // Account lock: checked before every call. On a mismatch or doubt, Claude is not called.
        if let refusal = accountRefusal(cli: cli, allowed: allowedAccount) { return .failure(Failure(message: refusal)) }
        let dir = edit.deletingLastPathComponent()
        let proc = Process()
        proc.executableURL = cli
        proc.currentDirectoryURL = dir
        let p = prompt(original: original.path, edit: edit.path, settings: settings, facts: facts, taste: taste,
                       judges: StudioPanel.judges(panel), defaultPanel: StudioPanel.isDefault(panel))
        proc.arguments = ["-p", p,
                          "--output-format", "json", "--model", model, "--effort", effort,
                          "--tools", "Read", "--allowedTools", "Read", "--add-dir", dir.path,
                          "--strict-mcp-config", "--no-session-persistence", "--setting-sources", "project",
                          "--system-prompt", StudioPanel.system(panel)]
        // (No --json-schema: with --tools Read its structured-output tool isn't available, and the model loops
        // asking for it. The template goes in the prompt instead; parse() reads the JSON from the text answer.)
        proc.environment = childEnvironment()
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out; proc.standardError = err; proc.standardInput = FileHandle.nullDevice
        var outData = Data(), errData = Data()
        let lock = NSLock()
        out.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; lock.lock(); outData.append(d); lock.unlock() }
        err.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; lock.lock(); errData.append(d); lock.unlock() }
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do { try proc.run() } catch { return .failure(Failure(message: "Couldn't start Claude Code: \(error.localizedDescription)")) }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            if done.wait(timeout: .now() + 3) == .timedOut { kill(proc.processIdentifier, SIGKILL) }
            return .failure(Failure(message: "Claude took too long to answer. Try again."))
        }
        out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        outData.append(out.fileHandleForReading.readDataToEndOfFile()); errData.append(err.fileHandleForReading.readDataToEndOfFile())
        let stdout = String(data: outData, encoding: .utf8) ?? "", stderr = String(data: errData, encoding: .utf8) ?? ""
        lock.unlock()
        return parse(stdout: stdout, stderr: stderr, status: proc.terminationStatus)
    }

    static func parse(stdout: String, stderr: String, status: Int32) -> Result<AICritique, Failure> {
        let envelope = (try? JSONSerialization.jsonObject(with: Data(stdout.utf8))) as? [String: Any]
        let resultText = (envelope?["result"] as? String) ?? ""
        // Classify only the CLI's message (result text / stderr), never the whole envelope: it always carries
        // a "usage" object and other words that would match loosely.
        let msg = (resultText + "\n" + stderr).lowercased()
        let raw = String((resultText.isEmpty ? stderr.isEmpty ? stdout : stderr : resultText).prefix(600))
        let failed = envelope?["is_error"] as? Bool == true || status != 0 || envelope == nil
        if failed {
            if msg.contains("not logged in") || msg.contains("please run /login") || msg.contains("invalid api key")
                || msg.contains("oauth token") || msg.contains("authentication_error") || msg.contains("log in") {
                return .failure(Failure(message: "Claude Code isn't signed in. Open Terminal, run claude and sign in.", detail: raw))
            }
            if msg.contains("model") && ["not available", "not found", "invalid model", "does not have access", "not supported",
                                         "unavailable", "no access", "isn't available", "not_found"].contains(where: { msg.contains($0) }) {
                return .failure(Failure(message: "That Claude model isn't available on this plan.", detail: raw, modelUnavailable: true))
            }
            if msg.contains("usage limit") || msg.contains("limit reached") || msg.contains("rate limit") || msg.contains("rate_limit")
                || msg.contains("quota") || msg.contains("credit balance") || msg.contains("limit will reset") || msg.contains("overloaded") {
                return .failure(Failure(message: "Your Claude plan's usage limit is reached. Try again later.", detail: raw))
            }
        }
        var candidates: [Any] = []
        if let s = envelope?["structured_output"] { candidates.append(s) }
        if let r = envelope?["result"] as? String { candidates += jsonCandidates(r) }
        if let v = decode(candidates) { return .success(v) }
        if failed {
            var firstLine = raw.split(separator: "\n").first.map(String.init) ?? "exit \(status)"
            if let e = envelope, resultText.isEmpty {
                let denied = (e["permission_denials"] as? [[String: Any]])?.compactMap { $0["tool_name"] as? String } ?? []
                firstLine = "\(e["subtype"] as? String ?? "error")" + (denied.isEmpty ? "" : " (tools refused: \(Set(denied).sorted().joined(separator: ", ")))")
            }
            return .failure(Failure(message: "Claude Code reported an error: \(firstLine.prefix(160))", detail: raw))
        }
        return .failure(Failure(message: "Claude's answer couldn't be read.", detail: raw, retryable: true))
    }

    /// The answer as JSON: the whole text, or from its first "{" to its last "}".
    static func jsonCandidates(_ r: String) -> [Any] {
        var out: [Any] = []
        if let o = try? JSONSerialization.jsonObject(with: Data(r.utf8)) { out.append(o) }
        if let a = r.firstIndex(of: "{"), let b = r.lastIndex(of: "}"), a < b,
           let o = try? JSONSerialization.jsonObject(with: Data(r[a...b].utf8)) { out.append(o) }
        return out
    }

    /// The first candidate that is a complete critique, with empty items and a "null" reshoot cleaned up.
    static func decode(_ candidates: [Any]) -> AICritique? {
        for c in candidates {
            guard let d = try? JSONSerialization.data(withJSONObject: c), var v = try? JSONDecoder().decode(AICritique.self, from: d),
                  ["Keeper", "Strong", "Workable", "Weak"].contains(v.verdict), v.picture != nil, v.print != nil else { continue }
            v.picture = v.picture.map { p in
                var p = p
                for k in [\AIPicture.moment, \.wit, \.composition, \.light, \.subject] { p[keyPath: k] = clean(p[keyPath: k]) }
                return p
            }
            v.print = v.print.map { p in
                var p = p
                for k in [\AIPrint.color, \.saturation, \.density, \.contrast, \.vignette, \.crispness] { p[keyPath: k] = clean(p[keyPath: k]) }
                return p
            }
            if let r = v.reshoot, r.trimmingCharacters(in: .whitespaces).isEmpty || r.lowercased() == "null" { v.reshoot = nil }
            return v
        }
        return nil
    }

    /// Scores into 1...5; an item with an empty note is dropped.
    static func clean(_ i: AIItem?) -> AIItem? {
        guard var i, !i.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        i.score = max(1, min(5, i.score))
        return i
    }

    static func value(_ p: EditParams, _ key: String) -> Double? {
        switch key {
        case "exposure": return p.exposure
        case "contrast": return p.contrast
        case "highlights": return p.highlights
        case "shadows": return p.shadows
        case "blacks": return p.blacks
        case "punch": return p.punch
        case "vibrance": return p.vibrance
        case "saturation": return p.saturation
        case "warmth": return p.warmth
        case "tint": return p.tint
        case "filmStrength": return p.filmStrength
        case "vignette": return p.vignette
        case "sharpen": return p.sharpen
        case "grain": return p.grain
        default: return nil
        }
    }

    /// A valid change for these params: known slider, finite, rounded to the slider's step, result in
    /// range. nil when nothing is left to change.
    static func cleanChange(_ c: AIParamChange, _ p: EditParams) -> AIParamChange? {
        let key = c.param.trimmingCharacters(in: .whitespaces)
        guard let r = range(key), let from = value(p, key), c.change.isFinite else { return nil }
        let to = (min(r.hi, max(r.lo, from + c.change)) / r.step).rounded() * r.step
        let change = ((to - from) / r.step).rounded() * r.step
        guard abs(change) >= r.step * 0.5 else { return nil }
        func q(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        return AIParamChange(param: key, change: q(change), from: q(from), to: q(to), why: c.why?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
    }

    /// Validates a fix against the photo; nil when it isn't usable.
    static func cleanFix(_ f: AIFix?, _ ph: PhotoEntry) -> AIFix? {
        guard let f else { return nil }
        let p = ph.params
        let why = f.why?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch f.type.lowercased() {
        case "params":
            let ch = (f.changes ?? []).compactMap { cleanChange($0, p) }
            guard !ch.isEmpty else { return nil }
            return AIFix(type: "params", changes: ch, why: why)
        case "crop":
            guard let r = f.rect, [r.x, r.y, r.w, r.h].allSatisfy({ $0.isFinite }) else { return nil }
            let aspect = cropAspects.contains(f.aspect ?? "") ? f.aspect! : "original"
            let x = max(0, min(1, r.x)), y = max(0, min(1, r.y))
            let w = min(r.w, 1 - x), h = min(r.h, 1 - y)
            guard w > 0.05, h > 0.05 else { return nil }
            var c = CropRect(aspect: aspect, x: x, y: y, w: w, h: h)
            if aspect == "original" {
                // same shape as the frame: equal normalized sides, kept around the centre
                let s = min(1, (w * h).squareRoot()), cx = x + w / 2, cy = y + h / 2
                c.w = s; c.h = s; c.x = min(1 - s, max(0, cx - s / 2)); c.y = min(1 - s, max(0, cy - s / 2))
            } else if let n = StudioLook.normalizeCrop(c, width: ph.w, height: ph.h, rectGiven: true) { c = n }
            let area = c.w * c.h
            guard area >= 0.4, area <= 0.985 else { return nil }
            func q(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
            return AIFix(type: "crop", aspect: c.aspect, rect: AIRect(x: q(c.x), y: q(c.y), w: q(c.w), h: q(c.h)), why: why)
        case "straighten":
            guard let d = f.degrees, d.isFinite else { return nil }
            let to = (min(10, max(-10, p.rotate + d)) * 10).rounded() / 10
            let deg = ((to - p.rotate) * 10).rounded() / 10
            guard abs(deg) >= 0.1 else { return nil }
            return AIFix(type: "straighten", degrees: deg, to: to, why: why)
        case "reshoot":
            guard let n = (f.note ?? f.why)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
            return AIFix(type: "reshoot", note: n)
        default:
            return nil
        }
    }

    /// Cleans every fix, merges all slider changes into `fixes` (one per slider: same direction = the
    /// larger change, opposite directions = their sum), lists criteria scored ≤ 3 left without a fix and
    /// fills the v1 fields.
    static func validate(_ c0: AICritique, _ ph: PhotoEntry, panel ids: [String]? = nil) -> AICritique {
        var c = c0
        let judges = StudioPanel.judges(ids)
        var all: [AIParamChange] = []
        var unfixed: [String] = []
        if var p = c.picture {
            for (name, k) in [("moment", \AIPicture.moment), ("wit", \.wit), ("composition", \.composition), ("light", \.light), ("subject", \.subject)] {
                guard var item = p[keyPath: k] else { continue }
                item.fix = cleanFix(item.fix, ph)
                item.judge = judges["picture." + name]
                if item.fix == nil && item.score <= 3 && name != "wit" { unfixed.append("picture." + name) }
                all += item.fix?.changes ?? []
                p[keyPath: k] = item
            }
            c.picture = p
        }
        if var p = c.print {
            for (name, k) in [("color", \AIPrint.color), ("saturation", \.saturation), ("density", \.density), ("contrast", \.contrast), ("vignette", \.vignette), ("crispness", \.crispness)] {
                guard var item = p[keyPath: k] else { continue }
                item.fix = cleanFix(item.fix, ph)
                item.judge = judges["print." + name]
                if item.fix == nil && item.score <= 3 { unfixed.append("print." + name) }
                all += item.fix?.changes ?? []
                p[keyPath: k] = item
            }
            c.print = p
        }
        all += (c.fixes ?? []).compactMap { cleanChange($0, ph.params) }
        var merged: [String: AIParamChange] = [:]
        var order: [String] = []
        for ch in all {
            guard var m = merged[ch.param] else { merged[ch.param] = ch; order.append(ch.param); continue }
            if (m.change < 0) == (ch.change < 0) { if abs(ch.change) > abs(m.change) { m.change = ch.change } }
            else { m.change += ch.change }
            if m.why == nil { m.why = ch.why }
            merged[ch.param] = m
        }
        c.fixes = order.compactMap { merged[$0].flatMap { cleanChange($0, ph.params) } }
            .sorted { a, b in
                let ra = range(a.param).map { $0.hi - $0.lo } ?? 1, rb = range(b.param).map { $0.hi - $0.lo } ?? 1
                return abs(a.change) / ra > abs(b.change) / rb
            }
        c.unfixed = unfixed
        c.version = version
        c.panel = StudioPanel.names(ids)
        func v1(_ i: AIItem?) -> AICriterion? { i.map { AICriterion(score: $0.score, note: $0.note) } }
        c.light = v1(c.picture?.light); c.subject = v1(c.picture?.subject); c.moment = v1(c.picture?.moment)
        c.composition = v1(c.picture?.composition); c.color = v1(c.print?.color)
        c.intangibles = c.picture?.wit?.note
        c.suggestion = c.reshoot ?? c.fixes?.first.flatMap { f in f.why.map { "\(f.param) \(f.change > 0 ? "+" : "")\(fmt(f.change)): \($0)" } }
        return c
    }

    static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }

    /// The edit settings as plain lines for the prompt.
    static func settingsText(_ ph: PhotoEntry) -> [String] {
        let p = ph.params
        func signed(_ v: Double) -> String { (v > 0 ? "+" : "") + fmt(v) }
        var out: [String] = []
        for r in ranges {
            guard let v = value(p, r.key) else { continue }
            let shown = r.lo < 0 ? signed(v) : fmt(v)
            let unit = r.key == "exposure" ? " EV" : ""
            out.append("\(r.key) \(shown)\(unit) [\(fmt(r.lo))…\(fmt(r.hi))]: \(r.meaning)")
        }
        out.append(p.film.isEmpty ? "film look: none" : "film look: \(filmName(p.film)) at filmStrength \(fmt(p.filmStrength))")
        if p.grain > 0 { out.append("grain size: \(p.grainSize)") }
        out.append("straighten (rotate): \(signed(p.rotate))° [-10…10], + = counter-clockwise")
        if let c = p.crop {
            out.append(String(format: "crop: aspect %@, x %.3f y %.3f w %.3f h %.3f (normalized to the full frame)", c.aspect, c.x, c.y, c.w, c.h))
        } else { out.append("crop: none (full frame)") }
        out.append("The photographer's look is blended in at \(fmt(ph.lookAmount))%; the values above already include it.")
        return out
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty || lowercased() == "null" ? nil : self }
}

extension Studio {
    public var aiAllowedAccount: String { sync { lib.ai.allowedAccount } }
    public var aiTaste: String { sync { lib.ai.taste } }
    var secrets: StudioSecrets { StudioSecrets(root: root) }

    /// nil when the chosen provider can be called; otherwise why not, in plain words.
    var aiReady: String? { sync { aiReadyLocked() } }
    /// aiReady for a caller already holding the lock.
    func aiReadyLocked() -> String? {
        if !lib.ai.isEnabled { return "Photo analysis is off. Turn it on in Settings." }
        switch lib.ai.activeProvider {
        case "none": return "No AI is connected. Connect one in Settings."
        case "anthropic": return secrets.get("anthropic") == nil ? "Add your Anthropic API key in Settings." : nil
        case "openai": return secrets.get("openai") == nil ? "Add your OpenAI API key in Settings." : nil
        default: return StudioAI.cli == nil ? "Claude Code isn't installed on this Mac." : nil
        }
    }
    public func setAITaste(_ t: String) {
        sync {
            lib.ai.taste = String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
            markDirty("")
        }
    }

    func aiCacheURL(_ pid: String, _ id: String) -> URL { projectDir(pid).appendingPathComponent("critique/\(id).json") }

    static func paramsHash(_ ph: PhotoEntry) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        let d = (try? Store.encoder.encode(ph.params)) ?? Data()
        for b in d { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        for b in "\(ph.lookAmount)".utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    func aiCached(_ pid: String, _ ph: PhotoEntry) -> AICritique? { Store.read(AICritique.self, from: aiCacheURL(pid, ph.id)) }

    /// Fresh = made for the current params by the current critique version.
    func aiFresh(_ c: AICritique, _ ph: PhotoEntry) -> Bool { c.paramsHash == Self.paramsHash(ph) && (c.version ?? 1) >= StudioAI.version }

    /// For the photo JSON: {aiAvailable, aiCritique (with stale), aiState, aiError}.
    func aiFields(_ pid: String, _ ph: PhotoEntry) -> [String: Any] {
        let key = pid + "/" + ph.id
        // Analysis off: nothing about it in the photo JSON, so the UI shows no Analysis button.
        guard lib.ai.isEnabled else { return ["aiEnabled": false, "aiCritique": NSNull()] }
        var d: [String: Any] = ["aiEnabled": true, "aiAvailable": aiReadyLocked() == nil, "aiProvider": lib.ai.activeProvider, "aiState": aiStates[key] ?? "idle", "aiError": aiErrors[key] ?? NSNull()]
        if let c = aiCached(pid, ph), var o = Self.dict(c) as? [String: Any] {
            o["stale"] = !aiFresh(c, ph)
            d["aiCritique"] = o
        } else { d["aiCritique"] = NSNull() }
        return d
    }

    /// Facts the software measured, offered to Claude as context.
    func aiFacts(_ ph: PhotoEntry) -> [String] {
        var f: [String] = []
        if let r = ph.info["recipe"] { f.append("Camera recipe: \(r)") }
        if let cam = ph.info["camera"] { f.append("Camera: \(cam)\(ph.info["lens"].map { ", " + $0 } ?? "")\(ph.info["shutter"].map { ", " + $0 } ?? "")") }
        if let c = ph.critiqueContext {
            f.append(c.people.isEmpty ? "People detected: none" : "People detected: \(c.people.count)")
            f.append("Light read: \(c.light.kind)\(c.light.subject.map { ", subject \($0)" } ?? "")")
        }
        if let cues = ph.cues, !cues.isEmpty { f.append("Noticed: " + cues.joined(separator: "; ")) }
        if !ph.hints.isEmpty { f.append("Technical flags: " + ph.hints.map { $0.text }.joined(separator: ", ")) }
        return f
    }

    /// Starts (or joins) a critique of the photo's current edit. Returns immediately; the result shows up
    /// in the photo JSON (aiState: running -> idle, aiCritique or aiError). One call at a time.
    public func requestAICritique(_ pid: String, _ id: String, force: Bool) throws -> [String: Any] {
        guard let ph = sync({ photoIndex(pid, id).flatMap { projects[pid]?.photos[$0] } }) else { throw StudioError.notFound("no photo \(id) in \(pid)") }
        let key = pid + "/" + id
        if let c = aiCached(pid, ph), aiFresh(c, ph), !force { return sync { aiFields(pid, ph) } }
        if let why = aiReady { throw StudioError.failed(why) }
        let started: Bool = sync {
            if aiStates[key] == "running" { return false }
            aiStates[key] = "running"; aiErrors[key] = nil
            return true
        }
        if started {
            aiQueue.async { [weak self] in self?.runAICritique(pid, id) }
        }
        return sync { aiFields(pid, ph) }
    }

    func runAICritique(_ pid: String, _ id: String) {
        let key = pid + "/" + id
        defer { _ = sync { aiStates[key] = "idle" } }
        guard let ph = sync({ photoIndex(pid, id).flatMap { projects[pid]?.photos[$0] } }) else { return }
        let eng = engine(pid)
        let fm = FileManager.default
        if !fm.fileExists(atPath: eng.previewURL(ph.ref).path) { renderNow(pid, id, interactive: false) }
        let dir = projectDir(pid).appendingPathComponent(".tmp/claude-\(UUID().uuidString.prefix(8))")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        // 1600 px sRGB JPEGs: the current edit (its render) and the unedited camera JPEG (the proxy, or the
        // original file when the proxy was evicted; read only).
        let editURL = dir.appendingPathComponent("edit.jpg"), origURL = dir.appendingPathComponent("original.jpg")
        guard let es = CGImageSourceCreateWithURL(eng.previewURL(ph.ref) as CFURL, nil), let ecg = Pixels.load(es, maxPixel: 1600) else {
            sync { aiErrors[key] = "The photo's preview isn't available yet." }; return
        }
        let proxy = eng.proxyURL(ph.ref)
        let origSource = fm.fileExists(atPath: proxy.path) ? proxy : URL(fileURLWithPath: ph.path)
        guard let os = CGImageSourceCreateWithURL(origSource as CFURL, nil), let ocg = Pixels.load(os, maxPixel: 1600) else {
            sync { aiErrors[key] = "The original photo couldn't be read." }; return
        }
        Pixels.writeJPEG(ecg, to: editURL, quality: 0.9)
        Pixels.writeJPEG(ocg, to: origURL, quality: 0.9)
        let settings = StudioAI.settingsText(ph), facts = aiFacts(ph)
        let hash = Self.paramsHash(ph)
        let (allowed, taste, panel, provider, apiModel) = sync { (lib.ai.allowedAccount, lib.ai.taste, effectivePanelLocked(), lib.ai.activeProvider, lib.ai.model) }
        let t0 = Date()
        var model = provider == "claude-code" ? StudioAI.model : (apiModel ?? StudioProviders.defaultModel(provider) ?? "")
        let apiKey = provider == "claude-code" ? nil : secrets.get(provider)
        func call() -> Result<AICritique, StudioAI.Failure> {
            if provider == "claude-code" {
                return StudioAI.run(original: origURL, edit: editURL, settings: settings, facts: facts, taste: taste, model: model, allowedAccount: allowed, panel: panel)
            }
            guard let apiKey else { return .failure(.init(message: "Add your API key in Settings.")) }
            let system = StudioPanel.system(panel)
            let prompt = StudioAI.prompt(original: "", edit: "", settings: settings, facts: facts, taste: taste,
                                         judges: StudioPanel.judges(panel), defaultPanel: StudioPanel.isDefault(panel), attached: true)
            return provider == "anthropic"
                ? StudioProviders.runAnthropic(key: apiKey, model: model, system: system, prompt: prompt, original: origURL, edit: editURL)
                : StudioProviders.runOpenAI(key: apiKey, model: model, system: system, prompt: prompt, original: origURL, edit: editURL)
        }
        var result = call()
        if provider == "claude-code", case .failure(let f) = result, f.modelUnavailable, model != StudioAI.fallbackModel {
            log("\(key): \(model) isn't available on this plan; using \(StudioAI.fallbackModel)")
            model = StudioAI.fallbackModel
            result = call()
        }
        if case .failure(let f) = result, f.retryable {
            log("\(key): unreadable answer from Claude; retrying once")
            result = call()
        }
        switch result {
        case .success(let raw):
            var c = StudioAI.validate(raw, ph, panel: panel)
            c.model = model; c.paramsHash = hash; c.createdAt = Store.iso(); c.ms = Int(Date().timeIntervalSince(t0) * 1000)
            try? Store.write(c, to: aiCacheURL(pid, id), pretty: true)
            sync { aiErrors[key] = nil }
            log("\(key): critique by \(provider) (\(model)) in \(c.ms ?? 0) ms" + ((c.unfixed ?? []).isEmpty ? "" : "; no fix for \(c.unfixed!.joined(separator: ", "))"))
        case .failure(let f):
            sync { aiErrors[key] = f.message }
            log("\(key): critique failed (\(provider)): \(f.message) | raw: \(f.detail.replacingOccurrences(of: "\n", with: " ").prefix(600))")
        }
    }
}
