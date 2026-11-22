import Foundation

// On-disk model of the Baseline Darkroom catalog. Baseline Darkroom never copies, moves or writes next to originals:
// photos are referenced by absolute path in the user's own (connected) folders.
//
//   Catalog (small, permanent): ~/Library/Application Support/Baseline Darkroom/
//     library.json                    LibraryFile: sources, projects, My Look, frame/export settings, bestOrder
//     exported.json                   files Baseline Darkroom exported: path -> "<projectId>/<photoId>" (overwrite safety)
//     .lock                           held (flock) by the process that owns the catalog
//     projects/<id>.json (+ .bak)     ProjectFile: per photo path, analysis summary, params, marks
//     projects/<id>.analysis.json     the full analysis (ShootReport), not sent to the UI
//     projects/<id>.migration/        (migrated projects) untouched copies of the original params files
//
//   Preview cache (disposable, LRU-capped, regenerated on demand): ~/Library/Caches/Baseline Darkroom/<id>/
//     proxies/<photo>.jpg             1600 px upright copies of the originals (render input)
//     renders/<photo>.jpg             1600 px edited previews
//     thumbs/<photo>.jpg              480 px edited thumbnails
//     clip/<photo>.png                clipping overlays
//     analysis/previews|thumbs|overlays  analysis artefacts
//     sidecars/<FILE> + <FILE>.pp3    link to the original + generated RawTherapee profile (render/export input)

public struct FrameSettings: Codable, Equatable {
    public var enabled: Bool = true
    public var side: Double = 1          // % of the long edge
    public var topBottom: Double = 0.5   // % of the long edge
    public var color: String = "#FFFFFF"
    public init() {}
    enum CodingKeys: String, CodingKey { case enabled, side, topBottom, color }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ k: CodingKeys) -> Double? {
            if let v = try? c.decodeIfPresent(Double.self, forKey: k) { return v }
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return Double(s) }
            return nil
        }
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        side = d(.side) ?? 1
        topBottom = d(.topBottom) ?? 0.5
        color = (try? c.decodeIfPresent(String.self, forKey: .color)) ?? "#FFFFFF"
    }
    var export: ExportSettings {
        var s = ExportSettings()
        s.frame = enabled; s.side = side; s.topBottom = topBottom; s.color = color
        return s.clamped()
    }
    func clamped() -> FrameSettings {
        let s = export
        var f = self
        f.side = s.side; f.topBottom = s.topBottom; f.color = s.color
        return f
    }
}

/// A connected folder. kind "folder": the folder holds images itself (one project).
/// kind "source": its subfolders holding images each become a project automatically.
public struct SourceRef: Codable, Equatable {
    public var id: String
    public var path: String
    public var kind: String
    public var added: String
    public var excluded: [String] = []    // project folders the user removed (not re-created by rescans)
}

public struct ProjectRef: Codable, Equatable {
    public var id: String
    public var name: String
    public var folder: String
    public var sourceId: String?
    public var created: String
}

public struct ItemRef: Codable, Equatable, Hashable {
    public var projectId: String
    public var id: String
}

public struct LibraryFile: Codable {
    public var version: Int = 2
    public var sources: [SourceRef] = []
    public var projects: [ProjectRef] = []
    public var cacheLimitGB: Double = 5
    public var look: LookParams = .kodachrome
    public var frame: FrameSettings = FrameSettings()
    public var exportRoot: String = "~/Desktop"
    public var projectFolders: Bool = false      // "Put each project in its own folder"
    public var bestOrder: [ItemRef] = []
    public var aliases: [String: String] = [:]   // old project id -> current id (ids became ASCII-only)
    public var lookPinned: Bool = false          // learning from Best Work paused
    public var learned: LearnedLook? = nil
    public var ai: AISettings = AISettings()     // critique: provider, panel, taste, account lock
    /// Onboarding finished (or skipped). Libraries from before onboarding count as onboarded when they have projects.
    public var onboarded: Bool? = nil
    /// Where My Look starts before Best Work teaches it (onboarding); nil = Kodachrome.
    public var starter: LookParams? = nil
    /// Bodies of work put together by hand (StudioCollections.swift).
    public var collections: [CollectionFile] = []
    /// The camera film scans were shot with, for scans whose roll folder doesn't say (edge print).
    public var scanCamera: String? = nil
    /// Project list order: "custom" | "newest" | "oldest" | "name". `projectOrder` holds the custom order
    /// (project ids); projects missing from it (new ones) go to the top, unknown ids are ignored.
    public var projectSort: String = "newest"
    public var projectOrder: [String] = []
    public static let projectSorts = ["custom", "newest", "oldest", "name"]
    public init() {}
    enum CodingKeys: String, CodingKey { case version, sources, projects, cacheLimitGB, look, frame, exportRoot, projectFolders, bestOrder, aliases, lookPinned, learned, ai, projectSort, projectOrder, onboarded, starter, collections, scanCamera }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 2
        sources = (try? c.decodeIfPresent([SourceRef].self, forKey: .sources)) ?? []
        projects = (try? c.decodeIfPresent([ProjectRef].self, forKey: .projects)) ?? []
        cacheLimitGB = (try? c.decodeIfPresent(Double.self, forKey: .cacheLimitGB)) ?? 5
        look = (try? c.decodeIfPresent(LookParams.self, forKey: .look)) ?? .kodachrome
        frame = (try? c.decodeIfPresent(FrameSettings.self, forKey: .frame)) ?? FrameSettings()
        exportRoot = (try? c.decodeIfPresent(String.self, forKey: .exportRoot)) ?? "~/Desktop"
        projectFolders = (try? c.decodeIfPresent(Bool.self, forKey: .projectFolders)) ?? false
        bestOrder = (try? c.decodeIfPresent([ItemRef].self, forKey: .bestOrder)) ?? []
        aliases = (try? c.decodeIfPresent([String: String].self, forKey: .aliases)) ?? [:]
        lookPinned = (try? c.decodeIfPresent(Bool.self, forKey: .lookPinned)) ?? false
        learned = try? c.decodeIfPresent(LearnedLook.self, forKey: .learned)
        ai = (try? c.decodeIfPresent(AISettings.self, forKey: .ai)) ?? AISettings()
        let sort = (try? c.decodeIfPresent(String.self, forKey: .projectSort)) ?? nil
        projectSort = sort.flatMap { Self.projectSorts.contains($0) ? $0 : nil } ?? "newest"
        projectOrder = (try? c.decodeIfPresent([String].self, forKey: .projectOrder)) ?? []
        onboarded = (try? c.decodeIfPresent(Bool.self, forKey: .onboarded)) ?? nil
        starter = (try? c.decodeIfPresent(LookParams.self, forKey: .starter)) ?? nil
        collections = (try? c.decodeIfPresent([CollectionFile].self, forKey: .collections)) ?? []
        scanCamera = (try? c.decodeIfPresent(String.self, forKey: .scanCamera)) ?? nil
    }
}

/// Settings for critiques by Claude. Edited only in library.json (not through the API), so nothing in the
/// app can loosen the account lock.
public struct AISettings: Codable {
    /// The Claude account Claude Code must be signed in as; empty = any claude.ai login (only by editing library.json).
    public var allowedAccount: String = ""
    /// The photographer's taste, given to the AI with every critique (editable via PUT /api/settings ai.taste).
    public var taste: String = StudioAI.genericTaste
    /// The critique panel (StudioPanel catalog ids); nil = the original six.
    public var panel: [String]? = nil
    /// "claude-code" | "anthropic" | "openai" | "none"; nil = claude-code (libraries made before providers).
    public var provider: String? = nil
    /// Model for the API providers; nil = the provider's default.
    public var model: String? = nil
    /// Photo analysis on or off (Settings); nil = on (libraries made before the switch).
    public var enabled: Bool? = nil
    public init() {}
    enum CodingKeys: String, CodingKey { case allowedAccount, taste, panel, provider, model, enabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowedAccount = ((try? c.decodeIfPresent(String.self, forKey: .allowedAccount)) ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let t = ((try? c.decodeIfPresent(String.self, forKey: .taste)) ?? nil) ?? StudioAI.genericTaste
        // An old built-in default is replaced by the current one; a taste the photographer wrote is kept.
        taste = StudioAI.legacyTastePrefixes.contains { t.hasPrefix($0) } ? StudioAI.genericTaste : t
        panel = (try? c.decodeIfPresent([String].self, forKey: .panel)) ?? nil
        provider = (try? c.decodeIfPresent(String.self, forKey: .provider)) ?? nil
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil
    }
    public var isEnabled: Bool { enabled ?? true }
    public static let providers = ["claude-code", "anthropic", "openai", "none"]
    public var activeProvider: String { provider.flatMap { Self.providers.contains($0) ? $0 : nil } ?? "claude-code" }
}

public struct PhotoEntry: Codable {
    public var id: String
    public var file: String
    public var path: String
    public var w: Int
    public var h: Int
    public var time: String? = nil
    public var timestamp: Double? = nil
    // culling
    public var rating: Int = 0
    public var flag: String? = nil            // nil | "pick" | "reject"
    public var favorite: Bool = false
    // editing
    public var corrections: AutoCorrections = AutoCorrections()
    public var lookAmount: Double = 100
    public var manual: ManualOverrides = ManualOverrides()
    public var edited: Bool = false
    public var touched: Bool = false          // the user changed something by hand (cleared by Reset)
    public var params: EditParams = EditParams()
    public var version: Int = 0               // bumps on every committed render (cache busting)
    public var renderedParams: EditParams? = nil   // the params the current preview/thumb were rendered with
    public var rendered: Bool = false
    // analysis summary
    public var burst: Int? = nil
    public var best: Bool = false
    public var moment: Int = 0
    public var streetScore: Double? = nil
    public var techScore: Double? = nil
    public var hints: [StudioHint] = []
    public var notes: [String] = []
    public var info: [String: String] = [:]
    public var facts: PhotoFacts? = nil
    public var gone: Bool = false             // file no longer in the folder (edits kept in case it comes back)
    public var analyzed: Bool = true          // false = known file, analysis pending/failed
    public var critique: Critique? = nil      // (older field, unused once critiqueContext exists)
    public var critiqueContext: CritiqueContext? = nil   // "Analysis in the editor" inputs (StudioCritique.swift)
    public var cues: [String]? = nil          // observations from Vision on the proxy (StudioCues.swift), nil = not computed
    public var cuesVersion: Int? = nil
    public var cueTags: [String]? = nil       // scene labels (confidence >= 0.3) for the cues
    public var fileSize: Int64? = nil         // the original when it was analysed (changes = re-analyse)
    public var fileMtime: Double? = nil

    var ref: PhotoRef { PhotoRef(id: id, file: file, path: path, width: w, height: h) }

    init(id: String, file: String, path: String, w: Int, h: Int) {
        self.id = id; self.file = file; self.path = path; self.w = w; self.h = h
    }
    enum CodingKeys: String, CodingKey {
        case id, file, path, w, h, time, timestamp, rating, flag, favorite, corrections, lookAmount, manual, edited, touched, params, version, rendered, renderedParams
        case burst, best, moment, streetScore, techScore, hints, notes, info, facts, gone, analyzed, fileSize, fileMtime, critique, critiqueContext, cues, cuesVersion, cueTags
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        file = try c.decode(String.self, forKey: .file)
        path = try c.decode(String.self, forKey: .path)
        w = (try? c.decode(Int.self, forKey: .w)) ?? 0
        h = (try? c.decode(Int.self, forKey: .h)) ?? 0
        time = try? c.decodeIfPresent(String.self, forKey: .time)
        timestamp = try? c.decodeIfPresent(Double.self, forKey: .timestamp)
        rating = (try? c.decodeIfPresent(Int.self, forKey: .rating)) ?? 0
        flag = try? c.decodeIfPresent(String.self, forKey: .flag)
        favorite = (try? c.decodeIfPresent(Bool.self, forKey: .favorite)) ?? false
        corrections = (try? c.decodeIfPresent(AutoCorrections.self, forKey: .corrections)) ?? AutoCorrections()
        lookAmount = (try? c.decodeIfPresent(Double.self, forKey: .lookAmount)) ?? 100
        manual = (try? c.decodeIfPresent(ManualOverrides.self, forKey: .manual)) ?? ManualOverrides()
        edited = (try? c.decodeIfPresent(Bool.self, forKey: .edited)) ?? false
        touched = (try? c.decodeIfPresent(Bool.self, forKey: .touched)) ?? edited
        params = (try? c.decodeIfPresent(EditParams.self, forKey: .params)) ?? EditParams()
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 0
        rendered = (try? c.decodeIfPresent(Bool.self, forKey: .rendered)) ?? false
        renderedParams = try? c.decodeIfPresent(EditParams.self, forKey: .renderedParams)
        burst = try? c.decodeIfPresent(Int.self, forKey: .burst)
        best = (try? c.decodeIfPresent(Bool.self, forKey: .best)) ?? false
        moment = (try? c.decodeIfPresent(Int.self, forKey: .moment)) ?? 0
        streetScore = try? c.decodeIfPresent(Double.self, forKey: .streetScore)
        techScore = try? c.decodeIfPresent(Double.self, forKey: .techScore)
        hints = (try? c.decodeIfPresent([StudioHint].self, forKey: .hints)) ?? []
        notes = (try? c.decodeIfPresent([String].self, forKey: .notes)) ?? []
        info = (try? c.decodeIfPresent([String: String].self, forKey: .info)) ?? [:]
        facts = try? c.decodeIfPresent(PhotoFacts.self, forKey: .facts)
        gone = (try? c.decodeIfPresent(Bool.self, forKey: .gone)) ?? false
        analyzed = (try? c.decodeIfPresent(Bool.self, forKey: .analyzed)) ?? true
        fileSize = try? c.decodeIfPresent(Int64.self, forKey: .fileSize)
        critique = try? c.decodeIfPresent(Critique.self, forKey: .critique)
        critiqueContext = try? c.decodeIfPresent(CritiqueContext.self, forKey: .critiqueContext)
        cues = try? c.decodeIfPresent([String].self, forKey: .cues)
        cuesVersion = try? c.decodeIfPresent(Int.self, forKey: .cuesVersion)
        cueTags = try? c.decodeIfPresent([String].self, forKey: .cueTags)
        fileMtime = try? c.decodeIfPresent(Double.self, forKey: .fileMtime)
    }
}

public struct MomentEntry: Codable {
    public var id: Int
    public var start: String?
    public var end: String?
    public var count: Int
}

/// A file analysis couldn't read: retried with exponential backoff (1 min, 2, 4 … up to a day), or at once
/// when the file changes.
public struct UnreadableFile: Codable, Equatable {
    public var attempts: Int
    public var next: Double        // epoch seconds
    public var size: Int64
    public var mtime: Double
}

public struct ProjectFile: Codable {
    public var version: Int = 2
    public var id: String
    public var name: String
    public var folder: String
    public var sourceId: String? = nil
    public var created: String
    public var date: String? = nil                 // first capture day, yyyy-MM-dd
    public var state: String = "ready"             // importing (first analysis) | ready | error
    public var error: String? = nil
    public var migratedFrom: String? = nil
    public var hintsVersion: Int? = nil
    public var critiqueVersion: Int? = nil
    public var unreadable: [String: UnreadableFile]? = nil   // file name -> retry state
    public var photos: [PhotoEntry] = []
    public var moments: [MomentEntry] = []
    public var bursts: [[String]] = []

    init(id: String, name: String, folder: String, sourceId: String?, created: String) {
        self.id = id; self.name = name; self.folder = folder; self.sourceId = sourceId; self.created = created
    }
}

enum Store {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()

    /// Atomic replace (write to a temp file in the same folder, then rename).
    static func write<T: Encodable>(_ v: T, to url: URL, pretty: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try (pretty ? Store.pretty : Store.encoder).encode(v)
        try data.write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ t: T.Type, from url: URL) -> T? {
        guard let d = readAll(url) else { return nil }
        return try? JSONDecoder().decode(t, from: d)
    }

    /// Reads a file to EOF. Files in iCloud-synced folders can report a stale size while evicted, so
    /// size-based reads (Data(contentsOf:)) may come back truncated; two identical reads are required.
    static func readAll(_ url: URL) -> Data? {
        func once() -> Data? {
            guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? h.close() }
            return try? h.readToEnd() ?? Data()
        }
        for _ in 0..<4 {
            guard let a = once() else { return nil }
            if let b = once(), a == b { return a }
        }
        return once()
    }

    static func iso(_ d: Date = Date()) -> String { ISO8601DateFormatter().string(from: d) }
}
