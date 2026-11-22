import Foundation
import ImageIO

public enum StudioError: Error, CustomStringConvertible {
    case locked(String), bad(String), notFound(String), failed(String)
    public var description: String {
        switch self {
        case .locked(let m), .bad(let m), .notFound(let m), .failed(let m): return m
        }
    }
    var status: Int {
        switch self {
        case .bad: return 400
        case .notFound: return 404
        case .locked: return 409
        case .failed: return 500
        }
    }
}

/// Curated film stocks for the studio (8). Stocks used by existing edits keep working even if not listed.
public let studioFilmStocks: [(path: String, name: String)] = [
    ("Kodak/Kodak Kodachrome 64.png", "Kodachrome 64"),
    ("Kodak/Kodak Kodachrome 200.png", "Kodachrome 200"),
    ("Kodak/Kodak Ektachrome 100 VS.png", "Ektachrome 100 VS"),
    ("Kodak/Kodak Ektar 100.png", "Ektar 100"),
    ("Kodak/Kodak Portra 400 2.png", "Portra 400"),
    ("Kodak/Kodak Portra 400 VC 2.png", "Portra 400 VC"),
    ("Fuji/Fuji Superia 400 2.png", "Superia 400"),
    ("Fuji/Fuji 400H 2.png", "Fuji 400H"),
    // Black and white lives beside the colour root (…/HaldCLUT/Black-and-White); served at /luts-bw/.
    ("../Black-and-White/Ilford/Ilford HP5 Plus 400.png", "Ilford HP5 Plus 400"),
]

struct ImportProgress {
    var total = 0
    var analyzed = 0
    var failed = 0
    var finished = false
    var cancelled = false
    var error: String? = nil
}

struct ExportProgress {
    var state = "idle"   // idle | running | done
    var done = 0
    var total = 0
    var failed: [String] = []
    var dir: String? = nil
}

/// The Baseline Darkroom catalog: connected folders, their projects, My Look, frame + export settings. Thread-safe.
public final class Studio {
    public let root: URL          // catalog (small JSON only)
    public let cache: URL         // disposable previews
    /// rawtherapee-cli (nil: not installed or broken). Replaced by repairRawTherapee().
    public var rt: URL? { rtLock.lock(); defer { rtLock.unlock() }; return _rt }
    var _rt: URL?
    let rtLock = NSLock()
    public let lutRoot: URL?
    let log: (String) -> Void

    let lock = NSRecursiveLock()
    var lib = LibraryFile()
    var projects: [String: ProjectFile] = [:]
    var index: [String: [String: Int]] = [:]
    var imports: [String: ImportProgress] = [:]
    var exports: [String: ExportProgress] = [:]
    var owned: [String: String] = [:]          // exported file path -> "<projectId>/<photoId>"

    // rendering
    var latest: [String: Int] = [:]
    var committed: [String: Int] = [:]
    /// Failed background renders per photo ("<pid>/<id>"), so the same edit isn't retried every second.
    var renderFailures: [String: RenderFailure] = [:]
    /// Render failures since the last successful render (any photo): the UI warns when renders keep failing.
    var failingRenders = 0
    var bgPending = Set<String>()
    var firstPending = Set<String>()
    var upgradePending = Set<String>()
    var fullResGates: [String: NSLock] = [:]
    var folderDates: [String: String?] = [:]
    var exportDownloads: [String: Date] = [:]   // originals downloaded from iCloud for an export
    var evictionFailures = Set<String>()
    var lastSeq: [String: Int] = [:]            // "pid/id/field" -> newest client sequence number applied
    var relearnToken = 0
    var renderStatsCache: [String: RenderStats] = [:]
    var cuesPending = Set<String>()
    var aiStates: [String: String] = [:]        // "pid/id" -> running
    var aiErrors: [String: String] = [:]
    let aiQueue = DispatchQueue(label: "photolab.studio.claude")   // serial: one Claude call at a time
    let cuesQueue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.qualityOfService = .background; return q }()
    var lastOpened: [String: Date] = [:]        // project -> last opened/viewed (cache protection, priorities)
    var evictionHold = Date.distantPast
    let thumbQueue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 2; q.qualityOfService = .userInitiated; return q }()
    let thumbSlots = DispatchSemaphore(value: 3)
    /// Render priorities: interactive edits (renderSlots, 3) > first renders of new photos and the
    /// full-size follow-up of an edit (firstQueue, 2) > re-renders of existing photos after look changes
    /// or proxy upgrades (bgQueue, 1; suspended while shoots are being analysed).
    let firstQueue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 2; q.qualityOfService = .userInitiated; return q }()
    let bgQueue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.qualityOfService = .utility; return q }()
    let renderSlots = DispatchSemaphore(value: 3)
    let exportSlots = DispatchSemaphore(value: 2)

    // analysis + folder watching (StudioSources.swift)
    var analysisJobs: [AnalysisJob] = []
    var runningAnalyses = Set<String>()
    var analysisRunning: String? { runningAnalyses.first }
    let analysisSignal = DispatchSemaphore(value: 0)
    var lastScan: [String: Date] = [:]
    var scanScheduled = Set<String>()
    var watcher: FolderWatcher? = nil
    let scanQueue = DispatchQueue(label: "photolab.studio.scan")
    let watchQueue = DispatchQueue(label: "photolab.studio.fsevents")
    let placeholderQueue = DispatchQueue(label: "photolab.studio.placeholders", qos: .userInitiated)
    var lastEviction = Date.distantPast

    // persistence
    var dirty = Set<String>()                 // project ids, "" = library.json, "#exported" = exported.json
    var saveScheduled = false
    let saveQueue = DispatchQueue(label: "photolab.studio.save")
    var backedUp = Set<String>()
    var lockFD: Int32 = -1
    var firstLaunch = false
    var diskWait = false

    public static var defaultRoot: URL {
        if let env = ProcessInfo.processInfo.environment["PHOTOLAB_CATALOG"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        return StudioPaths.support
    }
    public static var defaultCache: URL {
        if let env = ProcessInfo.processInfo.environment["PHOTOLAB_CACHE"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        return StudioPaths.cache
    }

    /// Opens (or creates) the catalog and takes its lock. Throws `.locked` if another process owns it.
    /// Call `start()` afterwards to rescan folders, resume analysis and watch for changes.
    public init(root: URL = Studio.defaultRoot, cache: URL = Studio.defaultCache, rt: URL?, lutRoot: URL?, log: @escaping (String) -> Void) throws {
        self.root = root.standardizedFileURL
        self.cache = cache.standardizedFileURL
        self._rt = rt
        self.lutRoot = lutRoot
        self.log = log
        RawTherapeeCLI.logger = log
        let fm = FileManager.default
        try fm.createDirectory(at: self.root.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try fm.createDirectory(at: self.cache, withIntermediateDirectories: true)
        try takeLock()
        if let l = Store.read(LibraryFile.self, from: libraryURL) {
            lib = l
        } else if fm.fileExists(atPath: libraryURL.path) {
            // Unreadable library.json: keep it aside, never overwrite it silently.
            let aside = self.root.appendingPathComponent("library.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? fm.copyItem(at: libraryURL, to: aside)
            log("library.json could not be read; a copy was kept at \(aside.path)")
            if let l = Store.read(LibraryFile.self, from: libraryURL.appendingPathExtension("bak")) { lib = l }
        } else {
            firstLaunch = true
        }
        lib.look = lib.look.clamped(lutRoot: lutRoot)
        lib.frame = lib.frame.clamped()
        owned = Store.read([String: String].self, from: self.root.appendingPathComponent("exported.json")) ?? [:]
        // Project files the library doesn't list (e.g. after a lost library.json) are re-adopted.
        let onDisk = ((try? fm.contentsOfDirectory(atPath: self.root.appendingPathComponent("projects").path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".analysis.json") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(5)) }
        for id in onDisk where !lib.projects.contains(where: { $0.id == id }) {
            if let p = loadProjectFile(id) { lib.projects.append(ProjectRef(id: p.id, name: p.name, folder: p.folder, sourceId: p.sourceId, created: p.created)) }
        }
        for ref in lib.projects {
            if var p = loadProjectFile(ref.id) {
                if (p.hintsVersion ?? 1) < StudioAnalysis.hintsVersion { refreshHints(&p) }
                if (p.critiqueVersion ?? 0) < StudioCritique.version { refreshCritiques(&p) }
                projects[ref.id] = p
                reindex(ref.id)
            } else {
                log("project \(ref.id) (\(ref.name)) could not be loaded")
            }
            try? fm.removeItem(at: projectDir(ref.id).appendingPathComponent(".tmp"))
        }
        for id in Array(projects.keys) where !id.unicodeScalars.allSatisfy({ $0.isASCII }) { renameProjectId(id) }
        markDirty("")
    }

    /// Resolves an old (pre-ASCII) project id.
    public func resolveId(_ pid: String) -> String { sync { projects[pid] != nil ? pid : (lib.aliases[pid] ?? pid) } }

    /// Gives a project with a non-ASCII id an ASCII one; the old id keeps working through `aliases`.
    func renameProjectId(_ old: String) {
        guard var p = projects[old] else { return }
        let new = newProjectId(p.name)
        let fm = FileManager.default
        let dir = root.appendingPathComponent("projects")
        for (a, b) in [("\(old).json", "\(new).json"), ("\(old).json.bak", "\(new).json.bak"), ("\(old).analysis.json", "\(new).analysis.json"), ("\(old).migration", "\(new).migration")] {
            let src = dir.appendingPathComponent(a)
            if fm.fileExists(atPath: src.path) { try? fm.moveItem(at: src, to: dir.appendingPathComponent(b)) }
        }
        if fm.fileExists(atPath: cache.appendingPathComponent(old).path) { try? fm.moveItem(at: cache.appendingPathComponent(old), to: cache.appendingPathComponent(new)) }
        p.id = new
        projects[old] = nil; projects[new] = p
        index[old] = nil; reindex(new)
        if let i = lib.projects.firstIndex(where: { $0.id == old }) { lib.projects[i].id = new }
        lib.bestOrder = lib.bestOrder.map { $0.projectId == old ? ItemRef(projectId: new, id: $0.id) : $0 }
        lib.projectOrder = lib.projectOrder.map { $0 == old ? new : $0 }
        for (k, v) in owned where v.hasPrefix(old + "/") { owned[k] = new + v.dropFirst(old.count) }
        for (k, v) in lib.aliases where v == old { lib.aliases[k] = new }
        lib.aliases[old] = new
        dirty.insert(new); dirty.insert("#exported")
        log("project id \(old) is now \(new) (old id kept as an alias)")
    }

    deinit { if lockFD >= 0 { close(lockFD) } }

    /// Recomputes stored hints from the project's saved analysis (after the hint rules changed).
    func refreshHints(_ p: inout ProjectFile) {
        struct Slim: Decodable { struct Ph: Decodable { var id: String; var flags: [Flag] }; var photos: [Ph] }
        guard let a = Store.read(Slim.self, from: analysisURL(p.id)) else { return }
        var flags: [String: [Flag]] = [:]
        for ph in a.photos { flags[ph.id] = ph.flags }
        for i in p.photos.indices { if let f = flags[p.photos[i].id] { p.photos[i].hints = StudioAnalysis.hints(flags: f) } }
        p.hintsVersion = StudioAnalysis.hintsVersion
        dirty.insert(p.id)
    }

    var libraryURL: URL { root.appendingPathComponent("library.json") }
    var lockURL: URL { root.appendingPathComponent(".lock") }
    /// The project's cache folder (proxies, renders, thumbs, sidecars): disposable.
    public func projectDir(_ pid: String) -> URL { cache.appendingPathComponent(pid) }
    func projectURL(_ pid: String) -> URL { root.appendingPathComponent("projects").appendingPathComponent(pid + ".json") }
    func analysisURL(_ pid: String) -> URL { root.appendingPathComponent("projects").appendingPathComponent(pid + ".analysis.json") }
    func engine(_ pid: String) -> EditEngine { EditEngine(studioProject: projectDir(pid), lutRoot: lutRoot, rt: rt) }

    func sync<T>(_ f: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try f() }

    // MARK: Lock

    private func takeLock() throws {
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw StudioError.failed("can't open \(lockURL.path)") }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let info = (try? String(contentsOf: lockURL, encoding: .utf8)) ?? ""
            close(fd)
            throw StudioError.locked("The Baseline Darkroom library is open in another Baseline Darkroom process (\(info.trimmingCharacters(in: .whitespacesAndNewlines)))")
        }
        lockFD = fd
        announce(port: nil)
    }

    /// Records who holds the library (and the port it serves on) in the lock file, so a second
    /// Baseline Darkroom (e.g. the app while a dev server runs) can attach to it instead.
    public func announce(port: UInt16?) {
        guard lockFD >= 0 else { return }
        let text = "pid=\(getpid()) port=\(port.map(String.init) ?? "") exe=\(CommandLine.arguments.first ?? "")\n"
        ftruncate(lockFD, 0)
        _ = text.withCString { pwrite(lockFD, $0, strlen($0), 0) }
    }

    /// Port of the process holding the library lock, if it published one.
    public static func lockHolderPort(root: URL = Studio.defaultRoot) -> UInt16? {
        guard let s = try? String(contentsOf: root.appendingPathComponent(".lock"), encoding: .utf8),
              let r = s.range(of: "port=") else { return nil }
        return UInt16(s[r.upperBound...].prefix { $0.isNumber })
    }

    // MARK: Persistence

    func loadProjectFile(_ id: String) -> ProjectFile? {
        if let p = Store.read(ProjectFile.self, from: projectURL(id)) { return p }
        let bak = projectURL(id).appendingPathExtension("bak")
        if let p = Store.read(ProjectFile.self, from: bak) {
            log("project.json of \(id) was unreadable; loaded the backup")
            return p
        }
        return nil
    }

    func reindex(_ pid: String) {
        guard let p = projects[pid] else { index[pid] = nil; return }
        var m: [String: Int] = [:]
        for (i, ph) in p.photos.enumerated() { m[ph.id] = i }
        index[pid] = m
    }

    func markDirty(_ pid: String) {
        sync {
            dirty.insert(pid)
            if saveScheduled { return }
            saveScheduled = true
            saveQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.flush() }
        }
    }

    /// Writes everything that changed (atomic writes). Called automatically ~0.4 s after a change,
    /// and by the app before it quits.
    public func flush() {
        let (ids, snapshot, l, own): (Set<String>, [String: ProjectFile], LibraryFile, [String: String]) = sync {
            let ids = dirty
            dirty.removeAll()
            saveScheduled = false
            var snap: [String: ProjectFile] = [:]
            for id in ids where !id.isEmpty && !id.hasPrefix("#") { if let p = projects[id] { snap[id] = p } }
            return (ids, snap, lib, owned)
        }
        let fm = FileManager.default
        for (id, p) in snapshot {
            let url = projectURL(id)
            if !backedUp.contains(id), fm.fileExists(atPath: url.path) {
                let bak = url.appendingPathExtension("bak")
                try? fm.removeItem(at: bak)
                try? fm.copyItem(at: url, to: bak)
                backedUp.insert(id)
            }
            do { try Store.write(p, to: url) } catch { log("could not save \(url.path): \(error)") }
        }
        if ids.contains("") {
            do { try Store.write(l, to: libraryURL, pretty: true) } catch { log("could not save library.json: \(error)") }
        }
        if ids.contains("#exported") {
            try? Store.write(own, to: root.appendingPathComponent("exported.json"), pretty: true)
        }
    }

    // MARK: Lookup helpers

    func photoIndex(_ pid: String, _ id: String) -> Int? { index[pid]?[id] }

    func withPhoto<T>(_ pid: String, _ id: String, _ f: (inout PhotoEntry) throws -> T) throws -> T {
        try sync {
            guard projects[pid] != nil else { throw StudioError.notFound("no project \(pid)") }
            guard let i = photoIndex(pid, id) else { throw StudioError.notFound("no photo \(id) in \(pid)") }
            let r = try f(&projects[pid]!.photos[i])
            markDirty(pid)
            return r
        }
    }

    // MARK: Edits

    /// Look + auto corrections for this photo at a Look Amount.
    func auto(_ ph: PhotoEntry, amount: Double? = nil, look: LookParams? = nil) -> EditParams {
        StudioLook.resolve(look ?? lib.look, ph.corrections, amount: amount ?? ph.lookAmount, lutRoot: lutRoot)
    }

    /// params = auto overlaid with manual; manual entries equal to auto are dropped.
    func recompute(_ ph: inout PhotoEntry, look: LookParams? = nil) {
        let a = auto(ph, look: look)
        var m = ph.manual
        for (k, v) in m.values where a[num: k] == v { m.values.removeValue(forKey: k) }
        if m.film == a.film { m.film = nil }
        if m.grainSize == a.grainSize { m.grainSize = nil }
        ph.manual = m
        ph.params = m.apply(to: a).clamped(lutRoot: lutRoot)
        ph.edited = ph.touched || !m.isEmpty || ph.lookAmount != 100
    }

    /// Keeps the params exactly as they are under a new look / new corrections (edited photos).
    func freeze(_ ph: inout PhotoEntry, look: LookParams? = nil) {
        let a = auto(ph, look: look)
        ph.manual = ManualOverrides.diff(ph.params, from: a)
        ph.edited = ph.touched || !ph.manual.isEmpty || ph.lookAmount != 100
    }

    static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.doubleValue
        }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func parseCrop(_ v: Any?) -> (CropRect?, Bool)? {
        if v == nil { return nil }
        if v is NSNull { return (nil, false) }
        if let s = v as? String { return (CropRect(aspect: s), false) }   // just a ratio label
        guard let d = v as? [String: Any] else { return nil }
        let given = d["x"] != nil || d["y"] != nil || d["w"] != nil || d["h"] != nil
        var c = CropRect()
        c.aspect = (d["aspect"] as? String) ?? "original"
        if let r = d["rect"] as? [Any], r.count == 4 {
            c.x = number(r[0]) ?? 0; c.y = number(r[1]) ?? 0; c.w = number(r[2]) ?? 1; c.h = number(r[3]) ?? 1
            return (c, true)
        }
        c.x = number(d["x"]) ?? 0; c.y = number(d["y"]) ?? 0; c.w = number(d["w"]) ?? 1; c.h = number(d["h"]) ?? 1
        return (c, given)
    }

    /// Applies posted values. Only keys present AND different from the photo's current value count as
    /// changes (so the UI can post its full params object). A change equal to the auto value means
    /// "follow auto" again. `skip` keys are ignored (paste without geometry).
    func applyEdit(_ ph: inout PhotoEntry, raw: [String: Any], skip: Set<String> = []) {
        let current = ph.params
        var amount = ph.lookAmount
        if !skip.contains("lookAmount"), let a = Self.number(raw["lookAmount"]), a.isFinite { amount = min(150, max(0, a.rounded())) }
        let a = auto(ph, amount: amount)
        var m = ph.manual
        for k in numericParamKeys where !skip.contains(k) {
            guard let v = Self.number(raw[k]) else { continue }
            var t = current
            t[num: k] = v
            let q = t.clamped(lutRoot: lutRoot)[num: k]
            if q == current[num: k] { continue }
            if q == a[num: k] { m.values.removeValue(forKey: k) } else { m.values[k] = q }
        }
        if !skip.contains("film"), raw.keys.contains("film") {
            var t = current
            t.film = (raw["film"] as? String) ?? ""
            let f = t.clamped(lutRoot: lutRoot).film
            if f != current.film { m.film = (f == a.film) ? nil : f }
        }
        if !skip.contains("grainSize"), let gs = raw["grainSize"] as? String {
            var t = current
            t.grainSize = gs
            let g = t.clamped(lutRoot: lutRoot).grainSize
            if g != current.grainSize { m.grainSize = (g == a.grainSize) ? nil : g }
        }
        if !skip.contains("crop"), let (c, given) = Self.parseCrop(raw["crop"]) {
            let n = StudioLook.normalizeCrop(c, width: ph.w, height: ph.h, rectGiven: given)
            if n != current.crop { m.crop = n }
        }
        if amount != ph.lookAmount || m != ph.manual { ph.touched = true }
        ph.lookAmount = amount
        ph.manual = m
        recompute(&ph)
    }

    /// Returns false when `seq` is older than an edit already applied to this photo (ignored).
    @discardableResult
    public func setParams(_ pid: String, _ id: String, raw: [String: Any], seq: Int? = nil) throws -> Bool {
        let (ok, fav): (Bool, Bool) = try withPhoto(pid, id) { ph in
            guard accept(pid + "/" + id + "/params", seq) else { return (false, ph.favorite) }
            applyEdit(&ph, raw: raw)
            return (true, ph.favorite)
        }
        if ok && fav { scheduleRelearn() }
        return ok
    }

    public func reset(_ pid: String, _ id: String) throws {
        if sync({ photoIndex(pid, id).flatMap { projects[pid]?.photos[$0].favorite } ?? false }) { scheduleRelearn() }
        try withPhoto(pid, id) { ph in
            ph.manual = ManualOverrides()
            ph.lookAmount = 100
            ph.touched = false
            recompute(&ph)
        }
    }

    public func paste(_ pid: String, ids: [String], raw: [String: Any], geometry: Bool) throws -> [String] {
        var done: [String] = []
        let skip: Set<String> = geometry ? [] : ["rotate", "crop"]
        for id in ids {
            if let fav = try? withPhoto(pid, id, { ph -> Bool in applyEdit(&ph, raw: raw, skip: skip); return ph.favorite }) {
                done.append(id)
                if fav { scheduleRelearn() }
            }
        }
        return done
    }

    // MARK: Culling

    /// `seq` (optional, from the client, increasing): a change older than one already applied to the same
    /// photo and field (rating / mark) is ignored, so quick P-then-U sequences can't end out of order.
    func accept(_ key: String, _ seq: Int?) -> Bool {
        guard let seq else { return true }
        if let last = lastSeq[key], seq <= last { return false }
        lastSeq[key] = seq
        return true
    }

    public func rate(_ pid: String, ids: [String], rating: Int?, flag: String??, favorite: Bool?, seq: Int? = nil) throws -> [[String: Any]] {
        try sync {
            guard projects[pid] != nil else { throw StudioError.notFound("no project \(pid)") }
            var out: [[String: Any]] = []
            for id in ids {
                guard let i = photoIndex(pid, id) else { continue }
                var ph = projects[pid]!.photos[i]
                let wasFav = ph.favorite
                let base = pid + "/" + id + "/"
                let rating = rating.flatMap { accept(base + "rating", seq) ? $0 : nil }
                let markOK = (flag != nil || favorite != nil) ? accept(base + "mark", seq) : false
                let flag = markOK ? flag : nil
                let favorite = markOK ? favorite : nil
                if let r = rating { ph.rating = max(0, min(5, r)) }
                if let f = flag {
                    switch f {
                    case "pick": ph.flag = "pick"
                    case "reject": ph.flag = "reject"; ph.favorite = false
                    default: ph.flag = nil; ph.favorite = false
                    }
                }
                if let fav = favorite {
                    ph.favorite = fav
                    if fav { ph.flag = "pick" }
                }
                if ph.favorite != wasFav { scheduleRelearn() }
                projects[pid]!.photos[i] = ph
                let ref = ItemRef(projectId: pid, id: id)
                if ph.favorite && !wasFav && !lib.bestOrder.contains(ref) { lib.bestOrder.append(ref); markDirty("") }
                if !ph.favorite && wasFav { lib.bestOrder.removeAll { $0 == ref }; markDirty("") }
                out.append(["id": id, "rating": ph.rating, "flag": ph.flag ?? NSNull(), "favorite": ph.favorite])
            }
            markDirty(pid)
            return out
        }
    }

    // MARK: Look

    /// Sets My Look. Unedited photos everywhere follow it (re-resolved + re-rendered in the
    /// background); edited photos keep their params exactly.
    public func setLook(_ look: LookParams, priorityOrder: Bool = false) -> (changed: Int, queued: Int) {
        let l = look.clamped(lutRoot: lutRoot)
        var changed: [(String, String)] = []
        sync {
            for pid in projects.keys {
                for i in projects[pid]!.photos.indices {
                    var ph = projects[pid]!.photos[i]
                    let before = ph.params
                    if ph.edited { freeze(&ph, look: l) } else { recompute(&ph, look: l) }
                    if ph.params != before { changed.append((pid, ph.id)) }
                    projects[pid]!.photos[i] = ph
                }
                markDirty(pid)
            }
            lib.look = l
            markDirty("")
        }
        if priorityOrder {
            let recent: [String: Date] = sync { lastOpened }
            changed.sort { (recent[$0.0] ?? .distantPast, $0.0, $0.1) > (recent[$1.0] ?? .distantPast, $1.0, $1.1) }
        }
        for (pid, id) in changed { enqueueRender(pid, id) }
        return (changed.count, changed.count)
    }

    /// scope "unedited": unedited photos follow My Look (normally already true).
    /// scope "all": also edited photos: their look-defining adjustments are replaced by My Look;
    /// their other adjustments (exposure, highlights, shadows, straighten, crop) are kept.
    public func applyLook(scope: String, dryRun: Bool) -> (changed: Int, queued: Int) {
        var changed: [(String, String)] = []
        sync {
            for pid in projects.keys {
                for i in projects[pid]!.photos.indices {
                    var ph = projects[pid]!.photos[i]
                    let before = ph.params
                    if scope == "all" {
                        ph.manual.dropLook()
                        recompute(&ph)
                    } else if !ph.edited {
                        recompute(&ph)
                    }
                    if ph.params != before {
                        changed.append((pid, ph.id))
                        if !dryRun { projects[pid]!.photos[i] = ph }
                    }
                }
                if !dryRun { markDirty(pid) }
            }
        }
        if !dryRun { for (pid, id) in changed { enqueueRender(pid, id) } }
        return (changed.count, dryRun ? 0 : changed.count)
    }

    /// Copies the catalog (library.json, exported.json and projects/: every project file and its analysis)
    /// to <catalog>/backups/<timestamp>/ after writing pending changes. Returns the backup folder.
    public func backupCatalog() throws -> URL {
        flush()
        let fm = FileManager.default
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HHmmss"
        let dest = root.appendingPathComponent("backups/\(f.string(from: Date()))")
        try fm.createDirectory(at: dest.appendingPathComponent("projects"), withIntermediateDirectories: true)
        for name in ["library.json", "exported.json"] where fm.fileExists(atPath: root.appendingPathComponent(name).path) {
            try fm.copyItem(at: root.appendingPathComponent(name), to: dest.appendingPathComponent(name))
        }
        let pdir = root.appendingPathComponent("projects")
        for name in (try? fm.contentsOfDirectory(atPath: pdir.path)) ?? [] where name.hasSuffix(".json") || name.hasSuffix(".json.bak") {
            try fm.copyItem(at: pdir.appendingPathComponent(name), to: dest.appendingPathComponent("projects/\(name)"))
        }
        log("catalog backed up to \(dest.path)")
        return dest
    }

    /// "Apply the new look to everything" (POST /api/look/apply {scope:"everything"}): every photo, edited
    /// ones, favorites and selects included, gets `look` for its look-defining params (film, film amount,
    /// contrast, blacks, punch, vibrance, saturation, warmth, tint, vignette, sharpen, grain, grain size) at
    /// Look Amount 100. Its own exposure/highlights/shadows corrections and overrides, crop, straighten,
    /// ratings, flags, favorites and notes are kept. My Look becomes `look`; unless pinned, it is then
    /// relearned from the favorites (which now carry it). Re-renders run in the background, most recently
    /// opened projects first.
    /// `only` (preview/testing): just these photos get the look; My Look and learning are left alone.
    public func applyLookEverywhere(_ look: LookParams, backup: Bool, dryRun: Bool, only: Set<String>? = nil) throws -> [String: Any] {
        let l = look.clamped(lutRoot: lutRoot)
        var backupPath: Any = NSNull()
        if backup && !dryRun { backupPath = try backupCatalog().path }
        var changed: [(String, String)] = []
        var amountsReset = 0, editedTouched = 0, total = 0
        var overwrites: [[String: Any]] = []    // hand-made look edits that get replaced
        sync {
            for pid in projects.keys {
                for i in projects[pid]!.photos.indices {
                    var ph = projects[pid]!.photos[i]
                    if let only, !only.contains(pid + "/" + ph.id) { continue }
                    let before = ph.params
                    total += 1
                    if ph.lookAmount != 100 { amountsReset += 1; ph.lookAmount = 100 }
                    if ph.edited { editedTouched += 1 }
                    var keys = ph.manual.values.keys.filter { lookKeys.contains($0) }.sorted()
                    if ph.manual.film != nil { keys.append("film") }
                    if ph.manual.grainSize != nil { keys.append("grainSize") }
                    if !keys.isEmpty {
                        var o: [String: Any] = ["projectId": pid, "id": ph.id, "keys": keys]
                        o["values"] = Dictionary(uniqueKeysWithValues: keys.compactMap { k -> (String, Any)? in
                            k == "film" ? ph.manual.film.map { ("film", $0) } : k == "grainSize" ? ph.manual.grainSize.map { ("grainSize", $0) } : ph.manual.values[k].map { (k, $0) } })
                        overwrites.append(o)
                    }
                    ph.manual.dropLook()
                    recompute(&ph, look: l)
                    if ph.params != before { changed.append((pid, ph.id)) }
                    if !dryRun { projects[pid]!.photos[i] = ph }
                }
                if !dryRun { markDirty(pid) }
            }
            if !dryRun && only == nil { lib.look = l; markDirty("") }
        }
        if !dryRun {
            let recent: [String: Date] = sync { lastOpened }
            changed.sort { (recent[$0.0] ?? .distantPast, $0.0, $0.1) > (recent[$1.0] ?? .distantPast, $1.0, $1.1) }
            for (pid, id) in changed { enqueueRender(pid, id) }
            flush()
            log("new look applied to \(changed.count) of \(total) photos (\(editedTouched) edited, \(amountsReset) Look Amounts reset to 100)")
            if only == nil { scheduleRelearnNow() }
        }
        return ["scope": "everything", "dryRun": dryRun, "photos": total, "changed": changed.count, "edited": editedTouched,
                "lookAmountsReset": amountsReset, "queued": dryRun ? 0 : changed.count, "backup": backupPath, "look": Self.dict(l),
                "handEditsReplaced": overwrites.count, "handEdits": overwrites]
    }

    /// How many photos a new look would change: (unedited, all).
    public func lookImpact(_ look: LookParams) -> (unedited: Int, all: Int, edited: Int, photos: Int) {
        let l = look.clamped(lutRoot: lutRoot)
        return sync {
            var u = 0, a = 0, e = 0, n = 0
            for p in projects.values {
                for ph in p.photos {
                    n += 1
                    if ph.edited { e += 1 }
                    var x = ph
                    if !x.edited { recompute(&x, look: l); if x.params != ph.params { u += 1; a += 1 } }
                    else { x.manual.dropLook(); recompute(&x, look: l); if x.params != ph.params { a += 1 } }
                }
            }
            return (u, a, e, n)
        }
    }

    public func look(fromPhoto pid: String, _ id: String) throws -> LookParams {
        try sync {
            guard let i = photoIndex(pid, id), let ph = projects[pid]?.photos[i] else { throw StudioError.notFound("no photo \(id) in \(pid)") }
            return StudioLook.lookFrom(ph.params, ph.corrections, amount: ph.lookAmount, current: lib.look, lutRoot: lutRoot)
        }
    }

    public var currentLook: LookParams { sync { lib.look } }

    // MARK: Settings

    public func updateSettings(frame: [String: Any]?, exportRoot: String?, projectFolders: Bool?) throws {
        try sync {
            if let f = frame {
                var fr = lib.frame
                if let e = f["enabled"] as? Bool { fr.enabled = e }
                if let s = Self.number(f["side"]) { fr.side = s }
                if let t = Self.number(f["topBottom"]) { fr.topBottom = t }
                if let c = f["color"] as? String { fr.color = c }
                lib.frame = fr.clamped()
            }
            if let r = exportRoot {
                let t = r.trimmingCharacters(in: .whitespacesAndNewlines)
                let expanded = (t as NSString).expandingTildeInPath
                guard expanded.hasPrefix("/"), expanded != "/" else { throw StudioError.bad("the export folder must be a full path, like ~/Desktop") }
                let url = URL(fileURLWithPath: expanded).standardizedFileURL
                for r in [root, cache] where url.path == r.path || url.path.hasPrefix(r.path + "/") { throw StudioError.bad("choose a folder outside Baseline Darkroom's own folders") }
                lib.exportRoot = t
            }
            if let p = projectFolders { lib.projectFolders = p }
            markDirty("")
        }
    }

    // MARK: Projects

    public func rename(_ pid: String, _ name: String) throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw StudioError.bad("the name can't be empty") }
        try sync {
            guard projects[pid] != nil else { throw StudioError.notFound("no project \(pid)") }
            projects[pid]!.name = String(n.prefix(120))
            if let i = lib.projects.firstIndex(where: { $0.id == pid }) { lib.projects[i].name = projects[pid]!.name }
            markDirty(pid); markDirty("")
        }
    }

    /// Removes the project from the catalog: its catalog file is kept aside in projects/.removed/
    /// (small JSON, so a mistake can be undone by hand) and its preview cache is deleted. Originals are
    /// never touched. A project discovered in a source folder is excluded from future rescans; a
    /// single-folder source goes with its project.
    public func remove(_ pid: String) throws {
        try sync {
            guard let p = projects[pid] ?? loadProjectFile(pid) else { throw StudioError.notFound("no project \(pid)") }
            imports[pid]?.cancelled = true
            analysisJobs.removeAll { $0.pid == pid }
            if let sid = p.sourceId, let si = lib.sources.firstIndex(where: { $0.id == sid }) {
                if lib.sources[si].kind == "source" {
                    if !lib.sources[si].excluded.contains(p.folder) { lib.sources[si].excluded.append(p.folder) }
                } else {
                    lib.sources.remove(at: si)
                }
            }
            projects[pid] = nil
            index[pid] = nil
            lib.projects.removeAll { $0.id == pid }
            lib.bestOrder.removeAll { $0.projectId == pid }
            lib.projectOrder.removeAll { $0 == pid }
            dirty.remove(pid)
            markDirty("")
        }
        scheduleRelearn()
        discardFiles(pid)
        flush()
        watchFolders()
    }

    /// Moves the catalog files aside and deletes the cache of a removed project.
    func discardFiles(_ pid: String) {
        let fm = FileManager.default
        let removed = root.appendingPathComponent("projects/.removed")
        try? fm.createDirectory(at: removed, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        for u in [projectURL(pid), analysisURL(pid)] where fm.fileExists(atPath: u.path) {
            try? fm.moveItem(at: u, to: removed.appendingPathComponent("\(stamp)-" + u.lastPathComponent))
        }
        try? fm.removeItem(at: projectURL(pid).appendingPathExtension("bak"))
        let dir = projectDir(pid)
        if dir.path.hasPrefix(cache.path + "/") { try? fm.removeItem(at: dir) }
    }

    /// ASCII-only ids: "Ünïcode shoot – 2 ☕" -> "unicode-shoot-2-1a2b" (the display name is unchanged).
    func newProjectId(_ name: String) -> String {
        let ascii = String(String.UnicodeScalarView(name.decomposedStringWithCompatibilityMapping.unicodeScalars.filter { $0.isASCII }))
        let slug = ascii.lowercased().map { ($0.isLetter || $0.isNumber) && $0.isASCII ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-").prefix(24)
        let base = slug.isEmpty ? "shoot" : String(slug)
        while true {
            let id = base + "-" + String(UUID().uuidString.prefix(4)).lowercased()
            if projects[id] == nil && !FileManager.default.fileExists(atPath: projectDir(id).path) { return id }
        }
    }

    // MARK: Rendering

    enum RenderOutcome { case ok, stale, failed }

    /// A photo whose render failed with these params: retried after `retryAt` (5 s, doubling to 5 min), and not
    /// at all after `renderGiveUp` failures, until the edit changes, a render succeeds or RawTherapee is repaired.
    struct RenderFailure { var params: EditParams; var count: Int; var retryAt: Date }
    static let renderGiveUp = 5

    /// Renders the photo's current params (1600 px preview + 480 px thumb) with latest-wins:
    /// a render reaches disk only if no newer one for the same photo already has; an interactive
    /// request still waiting for a render slot gives up as soon as a newer one arrives.
    @discardableResult
    func renderNow(_ pid: String, _ id: String, interactive: Bool, upgrade: Bool? = nil, displayLong: Int? = nil) -> RenderOutcome {
        let upgradeProxy = upgrade ?? interactive
        let key = pid + "/" + id
        guard let (gen, ref, params) = sync({ () -> (Int, PhotoRef, EditParams)? in
            guard let i = photoIndex(pid, id), let ph = projects[pid]?.photos[i] else { return nil }
            let g = (latest[key] ?? 0) + 1
            latest[key] = g
            return (g, ph.ref, ph.params)
        }) else { return .failed }
        func superseded() -> Bool { sync { (latest[key] ?? 0) > gen } }
        // The same edit failed before: background renders wait out its backoff and stop after a few tries.
        // (Edits from the editor always try; with RawTherapee given up on, they fail without starting it.)
        if !interactive, let f = sync({ renderFailures[key] }), f.params == params, f.count >= Self.renderGiveUp || Date() < f.retryAt {
            return .failed
        }
        let t0 = Date()
        if interactive {
            while renderSlots.wait(timeout: .now() + .milliseconds(40)) == .timedOut {
                if superseded() { return .stale }
            }
        }
        // (background renders are limited by their queues, not the interactive slots)
        defer { if interactive { renderSlots.signal() } }
        if superseded() { return .stale }
        let eng = engine(pid)
        try? eng.writeSidecar(params, for: ref)
        ensureProxy(pid, ref, upgrade: upgradeProxy)
        // Interactive renders at the editor's displayed size (from a smaller copy of the proxy): RawTherapee's
        // cost scales with pixels. The full-size preview follows once edits pause (renderInteractive).
        var small: URL? = nil
        if let w = displayLong, let b = Self.proxyBucket(w), b < eng.previewLong { small = eng.sizedProxy(ref, long: b) }
        let fm = FileManager()
        let tmp = projectDir(pid).appendingPathComponent(".tmp/out")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let token = "\(id)-\(gen)-\(UUID().uuidString.prefix(8))"
        let tp = tmp.appendingPathComponent(token + ".jpg"), tt = tmp.appendingPathComponent(token + "-t.jpg")
        defer { try? fm.removeItem(at: tp); try? fm.removeItem(at: tt) }
        let t1 = Date()
        let rendered = eng.renderPreview(ref, params: params, to: tp, thumbOut: tt, upgradeProxy: upgradeProxy, proxyOverride: small)
        if interactive {
            // Timing of every edit's render, to see where the wait goes: the queue for a render slot, the
            // proxy, RawTherapee itself (one process launch per render).
            let ms = { (a: Date, b: Date) in Int(b.timeIntervalSince(a) * 1000) }
            log("edit render \(pid)/\(id) at \(small == nil ? "\(eng.previewLong)" : "\(Self.proxyBucket(displayLong ?? 0) ?? 0)") px: slot \(ms(t0, t1)) ms, render \(ms(t1, Date())) ms\(rendered ? "" : " (failed)")")
        }
        guard rendered else {
            let n: Int = sync {
                var f = renderFailures[key].flatMap { $0.params == params ? $0 : nil } ?? RenderFailure(params: params, count: 0, retryAt: .distantPast)
                f.count += 1
                f.retryAt = Date().addingTimeInterval(min(300, 5 * pow(2, Double(f.count - 1))))
                renderFailures[key] = f
                failingRenders += 1
                return f.count
            }
            // Once RawTherapee is given up on, that is logged once (RawTherapeeCLI.noteLaunch), not per photo.
            if let cli = rt, RawTherapeeCLI.isDisabled(cli) {}
            else if n == 1 { log("render failed: \(pid)/\(id)") }
            else if n == Self.renderGiveUp { log("render failed \(n) times: \(pid)/\(id); not retrying until the edit changes") }
            return .failed
        }
        sync { renderFailures[key] = nil; failingRenders = 0 }
        let outcome: RenderOutcome = sync {
            if (committed[key] ?? 0) > gen { return .stale }
            guard let i = photoIndex(pid, id), projects[pid] != nil else { return .stale }
            committed[key] = gen
            func place(_ src: URL, _ dst: URL) {
                try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dst.path) { _ = try? fm.replaceItemAt(dst, withItemAt: src) } else { try? fm.moveItem(at: src, to: dst) }
            }
            place(tp, eng.previewURL(ref))
            place(tt, eng.thumbURL(ref))
            projects[pid]!.photos[i].version += 1
            projects[pid]!.photos[i].rendered = true
            projects[pid]!.photos[i].renderedParams = params
            markDirty(pid)
            return (latest[key] ?? 0) > gen ? .stale : .ok
        }
        if outcome == .ok && displayLong == nil { afterRender(pid, id, preview: eng.previewURL(ref)) }
        return outcome
    }

    /// The whole straightened frame without the crop (crop mode), rendered on request and cached per
    /// version. Returns the file, or nil if it can't be rendered.
    public func renderFull(_ pid: String, _ id: String) -> URL? {
        guard let (ref, params, version) = sync({ () -> (PhotoRef, EditParams, Int)? in
            guard let i = photoIndex(pid, id), let ph = projects[pid]?.photos[i] else { return nil }
            return (ph.ref, ph.params, ph.version)
        }) else { return nil }
        let dir = projectDir(pid).appendingPathComponent("full")
        let out = dir.appendingPathComponent("\(id)-\(version).jpg")
        let fm = FileManager.default
        if fm.fileExists(atPath: out.path) { return out }
        var e = params
        e.crop = nil
        renderSlots.wait()
        defer { renderSlots.signal() }
        ensureProxy(pid, ref)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(id)-\(UUID().uuidString).jpg")
        guard engine(pid).renderPreview(ref, params: e, to: tmp, thumbOut: nil) else { try? fm.removeItem(at: tmp); return nil }
        for old in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where old.hasPrefix(id + "-") { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
        try? fm.moveItem(at: tmp, to: out)
        return fm.fileExists(atPath: out.path) ? out : nil
    }

    /// After a committed (non-interactive-sized) render: red guard and the fit toward My Look's targets
    /// (unedited photos only); favorites' renders schedule a relearn.
    func afterRender(_ pid: String, _ id: String, preview: URL) {
        guard let (edited, favorite) = sync({ photoIndex(pid, id).flatMap { i in projects[pid]?.photos[i] }.map { ($0.edited, $0.favorite) } }) else { return }
        if favorite { scheduleRelearn() }             // its render feeds the learned targets
        guard !edited, let stats = RenderStats.measure(preview) else { return }
        // Favorites are the reference: red guard only, no fit.
        if fitToTargets(pid, id, stats: stats, fit: !favorite) { enqueueRender(pid, id, followUp: true) }
    }

    /// Size of the interactive render while a photo is being edited (nil = full size). Capped at 1600 px: on a
    /// Retina screen the photo is ~2400 device px, which used to mean a full 2560 px render on every edit
    /// (~650 ms). The full-size render follows 1.2 s after the last edit (renderInteractive).
    static func proxyBucket(_ w: Int) -> Int? {
        guard w > 0 else { return nil }
        return [1280, 1600].first { $0 >= w } ?? 1600
    }

    /// An edit from the editor: rendered now (at the displayed size when `displayLong` is given), and
    /// re-rendered at full preview size 1.2 s after the last edit of this photo.
    func renderInteractive(_ pid: String, _ id: String, displayLong: Int?) -> RenderOutcome {
        let r = renderNow(pid, id, interactive: true, displayLong: displayLong)
        if let w = displayLong, Self.proxyBucket(w) != nil {
            let key = pid + "/" + id
            let gen = sync { latest[key] ?? 0 }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.sync({ (self.latest[key] ?? 0) == gen }) else { return }
                self.enqueueRender(pid, id, upgrade: true, urgent: true)
            }
        }
        return r
    }

    /// Background render. `upgrade`: also bring a small (older) proxy up to the current preview size.
    /// `followUp`: the second render of the fit toward My Look's targets: runs ahead of the other queued
    /// background renders so a photo settles in one go.
    func enqueueRender(_ pid: String, _ id: String, upgrade: Bool = false, urgent: Bool = false, followUp: Bool = false) {
        let key = pid + "/" + id
        // First renders and urgent ones (photo opened, edit follow-up) go to the fast queue even if the same
        // photo already waits in the background queue (the newer render wins; the older one is then skipped).
        let (fresh, first): (Bool, Bool) = sync {
            if upgrade { upgradePending.insert(key) }
            let isFirst = urgent || photoIndex(pid, id).map { !(projects[pid]?.photos[$0].rendered ?? true) } ?? false
            let inserted = isFirst ? firstPending.insert(key).inserted : bgPending.insert(key).inserted
            return (inserted, isFirst)
        }
        guard fresh else { return }
        let op = BlockOperation { [weak self] in
            guard let self else { return }
            let (up, skip): (Bool, Bool) = self.sync {
                if first { self.firstPending.remove(key) } else { self.bgPending.remove(key) }
                // a background render made redundant by a newer urgent one for the same photo
                let skip = !first && self.firstPending.contains(key)
                return (self.upgradePending.remove(key) != nil, skip)
            }
            if skip { return }
            autoreleasepool { _ = self.renderNow(pid, id, interactive: false, upgrade: up) }
        }
        if followUp { op.queuePriority = .high }
        (first ? firstQueue : bgQueue).addOperation(op)
    }

    /// The edit at full resolution (1:1 zoom), cached per render version; one render per photo at a time.
    public func renderFullRes(_ pid: String, _ id: String) -> URL? {
        let key = pid + "/" + id
        let gate: NSLock = sync {
            if let g = fullResGates[key] { return g }
            let g = NSLock(); fullResGates[key] = g; return g
        }
        gate.lock(); defer { gate.unlock() }
        guard let (ref, params, version) = sync({ () -> (PhotoRef, EditParams, Int)? in
            guard let i = photoIndex(pid, id), let ph = projects[pid]?.photos[i] else { return nil }
            return (ph.ref, ph.params, ph.version)
        }) else { return nil }
        let dir = projectDir(pid).appendingPathComponent("fullres")
        let out = dir.appendingPathComponent("\(id)-\(version).jpg")
        let fm = FileManager.default
        if fm.fileExists(atPath: out.path) { return out }
        guard fm.fileExists(atPath: ref.path) else { return nil }
        exportSlots.wait()
        defer { exportSlots.signal() }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(id)-\(UUID().uuidString).jpg")
        let dl = Self.isDataless(ref.path)
        let ok = engine(pid).renderFullRes(ref, params: params, to: tmp)
        releaseDownloaded(ref.path, wasDataless: dl)
        guard ok else { try? fm.removeItem(at: tmp); log("full-size render failed: \(pid)/\(id)"); return nil }
        // Only the newest version is kept (params changed = new version = new file).
        for old in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where old.hasPrefix(id + "-") { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
        try? fm.moveItem(at: tmp, to: out)
        return fm.fileExists(atPath: out.path) ? out : nil
    }

    public var pendingRenders: Int { sync { bgPending.count + firstPending.count } }

    /// Renders several photos now (paste/reset), 3 at a time.
    func renderMany(_ pid: String, _ ids: [String]) {
        DispatchQueue.concurrentPerform(iterations: ids.count) { i in _ = renderNow(pid, ids[i], interactive: true) }
    }

    static func isoFromExif(_ s: String) -> String {
        guard s.count >= 19 else { return s }
        let c = Array(s)
        return String(c[0..<4]) + "-" + String(c[5..<7]) + "-" + String(c[8..<10]) + "T" + String(c[11..<19])
    }

    public func status(_ pid: String) throws -> [String: Any] {
        try sync {
            guard let p = projects[pid] else { throw StudioError.notFound("no project \(pid)") }
            return statusDict(p)
        }
    }

    func statusDict(_ p: ProjectFile) -> [String: Any] {
        let visible = p.photos.filter { !$0.gone }
        let rendered = visible.filter { $0.rendered }.count
        let imp = imports[p.id]
        var state = "ready"
        var done = visible.count, total = visible.count
        let queued = analysisJobs.contains { $0.pid == p.id }
        if !FileManager.default.fileExists(atPath: p.folder) {
            state = "missing"
        } else if runningAnalyses.contains(p.id), let imp {
            state = "analyzing"; done = imp.analyzed; total = imp.total
        } else if p.state == "importing" {
            state = queued ? "queued" : "analyzing"
            done = imp?.analyzed ?? 0; total = max(imp?.total ?? 0, visible.count)
        } else if p.state == "error" {
            state = "error"
        } else if rendered < visible.count && (bgPending.contains(where: { $0.hasPrefix(p.id + "/") }) || firstPending.contains(where: { $0.hasPrefix(p.id + "/") })) {
            state = "rendering"; done = rendered
        } else if queued || runningAnalyses.contains(p.id) {
            state = "updating"     // new photos found in the folder, being analyzed
        }
        var d: [String: Any] = ["state": state, "done": done, "total": total, "rendered": rendered, "photos": visible.count,
                                "failed": imp?.failed ?? 0]
        if diskWait && queued { d["paused"] = "low-disk" }
        if let u = p.unreadable, !u.isEmpty { d["unreadable"] = u.keys.sorted() }
        if let e = p.error ?? imp?.error { d["error"] = e }
        return d
    }

    // MARK: Export

    static func freshFolder(_ raw: String) throws -> URL {
        let path = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), path != "/" else { throw StudioError.bad("choose a folder to export to") }
        let want = URL(fileURLWithPath: path).standardizedFileURL
        let name = want.lastPathComponent.replacingOccurrences(of: ":", with: "-")
        guard !name.isEmpty, !name.hasPrefix(".") else { throw StudioError.bad("give the folder a name") }
        let parent = want.deletingLastPathComponent(), fm = FileManager.default
        var url = parent.appendingPathComponent(name), n = 2
        while let items = try? fm.contentsOfDirectory(atPath: url.path), !items.filter({ !$0.hasPrefix(".") }).isEmpty {
            url = parent.appendingPathComponent("\(name) \(n)"); n += 1
        }
        return url
    }

    func exportDir(projectName: String?) throws -> URL {
        let rootPath = (lib.exportRoot as NSString).expandingTildeInPath
        guard rootPath.hasPrefix("/") else { throw StudioError.bad("the export folder must be a full path") }
        var url = URL(fileURLWithPath: rootPath).standardizedFileURL
        if lib.projectFolders, let n = projectName {
            let safe = n.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
            url.appendPathComponent(safe.isEmpty || safe.hasPrefix(".") ? "Baseline Darkroom export" : safe)
        }
        return url
    }

    /// Folders exports may never go to: the originals' folders and the library itself.
    func checkDestination(_ dir: URL, pids: Set<String>) throws {
        let d = dir.resolvingSymlinksInPath().path
        var forbidden: Set<String> = [root.resolvingSymlinksInPath().path, cache.resolvingSymlinksInPath().path]
        for pid in pids {
            guard let p = projects[pid] else { continue }
            forbidden.insert(URL(fileURLWithPath: p.folder).standardizedFileURL.resolvingSymlinksInPath().path)
            if let sid = p.sourceId, let src = lib.sources.first(where: { $0.id == sid }), src.kind == "folder" {
                forbidden.insert(URL(fileURLWithPath: src.path).standardizedFileURL.resolvingSymlinksInPath().path)
            }
            for ph in p.photos { forbidden.insert(URL(fileURLWithPath: ph.path).deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path) }
        }
        for f in forbidden where d == f || d.hasPrefix(f + "/") {
            throw StudioError.bad("won't export into the originals' folder or the library (\(f)); choose another export folder")
        }
        if d == "/" { throw StudioError.bad("choose a folder, not /") }
    }

    /// Exports full-size framed JPEGs. Blocks until done; progress is visible via exportStatus(key).
    /// `dest`: export into this folder instead of the export root (a new folder: if one by that name already
    /// holds files, " 2", " 3"… is added, so nothing is ever mixed in). `frame`: this export only, over the setting.
    public func export(items: [ItemRef], key: String, projectName: String?, dest: String? = nil, frame: Bool? = nil) throws -> [String: Any] {
        let t0 = Date()
        let (dir, settings, jobs): (URL, ExportSettings, [(ItemRef, PhotoRef, EditParams)]) = try sync {
            if exports[key]?.state == "running" { throw StudioError.bad("an export is already running") }
            let dir = try dest.map { try Self.freshFolder($0) } ?? exportDir(projectName: projectName)
            try checkDestination(dir, pids: Set(items.map { $0.projectId }))
            var jobs: [(ItemRef, PhotoRef, EditParams)] = []
            for it in items {
                guard let i = photoIndex(it.projectId, it.id), let ph = projects[it.projectId]?.photos[i] else { continue }
                jobs.append((it, ph.ref, ph.params))
            }
            exports[key] = ExportProgress(state: "running", done: 0, total: jobs.count, failed: [], dir: dir.path)
            var s = lib.frame.export
            if let f = frame { s.frame = f }
            return (dir, s, jobs)
        }
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            sync { exports[key]?.state = "done" }
            throw StudioError.bad("can't create \(dir.path): \(error.localizedDescription)")
        }
        var ok = 0
        var failed: [String] = []
        var errors: [String: String] = [:]
        var files: [String] = []
        let lk = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let (it, ref, params) = jobs[i]
            let label = key == "best" ? "\(it.projectId)/\(it.id)" : it.id
            var err: String? = nil
            if !FileManager.default.fileExists(atPath: ref.path) {
                err = "the original is missing (\(ref.path))"
            } else {
                exportSlots.wait()
                let eng = engine(it.projectId)
                // Originals downloaded for an export stay on disk for an hour (likely exported again soon).
                if Self.isDataless(ref.path) { sync { exportDownloads[ref.path] = Date() } }
                do { try eng.writeSidecar(params, for: ref) } catch { err = "could not write the RawTherapee profile: \(error)" }
                if err == nil {
                    let owner = "\(it.projectId)/\(it.id)"
                    switch eng.export(ref, toDir: dir, settings: settings, grain: GrainSpec(params, id: it.id), owns: { [weak self] path in self?.owns(path, owner) ?? false }) {
                    case .success(let r):
                        let m = ((try? FileManager.default.attributesOfItem(atPath: r.path.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                        sync { owned[r.path.path] = owner + "|" + String(format: "%.3f", m); markDirty("#exported") }
                        lk.lock(); files.append(r.path.path); lk.unlock()
                    case .failure(let e): err = e.description
                    }
                }
                exportSlots.signal()
            }
            lk.lock()
            if let err { failed.append(label); errors[label] = err; log("export \(label) failed: \(err)") } else { ok += 1 }
            lk.unlock()
            sync { exports[key]?.done += 1; if let err { _ = err; exports[key]?.failed.append(label) } }
        }
        sync { exports[key]?.state = "done" }
        flush()
        return ["dir": dir.path, "count": ok, "failed": failed, "errors": errors, "files": files.sorted(),
                "frame": settings.frame, "ms": Int(Date().timeIntervalSince(t0) * 1000)]
    }

    /// An existing file may be overwritten only if this photo's earlier export wrote it and it hasn't
    /// changed since (same modification time). Anything else gets "name (2).jpg".
    func owns(_ path: String, _ owner: String) -> Bool {
        guard let rec = sync({ owned[path] }) else { return false }
        let parts = rec.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.first == owner else { return false }
        guard parts.count == 2, let t = Double(parts[1]) else { return true }   // migrated legacy entry
        let m = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return abs(m - t) < 0.01
    }

    public func exportStatus(_ key: String) -> [String: Any] {
        sync {
            let e = exports[key] ?? ExportProgress()
            return ["state": e.state, "done": e.done, "total": e.total, "failed": e.failed, "dir": e.dir ?? NSNull()]
        }
    }

    // MARK: Collections

    /// Favorites in the saved Best Work order (unknown/removed entries dropped, new ones appended).
    func bestItems() -> [ItemRef] {
        var seen = Set<ItemRef>()
        var out: [ItemRef] = []
        for r in lib.bestOrder {
            guard let i = photoIndex(r.projectId, r.id), projects[r.projectId]?.photos[i].favorite == true, seen.insert(r).inserted else { continue }
            out.append(r)
        }
        for ref in lib.projects {
            for ph in projects[ref.id]?.photos ?? [] where ph.favorite && !ph.gone {
                let r = ItemRef(projectId: ref.id, id: ph.id)
                if seen.insert(r).inserted { out.append(r) }
            }
        }
        return out
    }

    public func setBestOrder(_ items: [ItemRef]) -> [ItemRef] {
        sync {
            let current = bestItems()
            let valid = Set(current)
            var seen = Set<ItemRef>()
            var order = items.filter { valid.contains($0) && seen.insert($0).inserted }
            order += current.filter { !seen.contains($0) }
            lib.bestOrder = order
            markDirty("")
            return order
        }
    }

    /// Projects newest first (by capture date, then creation).
    func projectsNewestFirst() -> [ProjectFile] {
        lib.projects.compactMap { projects[$0.id] }.sorted { (projectDate($0).0 ?? $0.created, $0.created) > (projectDate($1).0 ?? $1.created, $1.created) }
    }

    /// The projects in the photographer's chosen order (`projectSort`). Custom: `projectOrder`, with
    /// projects not in it (new ones) on top, newest first; ids of removed projects are skipped.
    func projectsOrdered(_ mode: String? = nil) -> [ProjectFile] {
        let newest = projectsNewestFirst()
        switch mode ?? lib.projectSort {
        case "oldest": return newest.reversed()
        case "name":
            return newest.sorted {
                let r = $0.name.localizedStandardCompare($1.name)
                return r == .orderedSame ? $0.created > $1.created : r == .orderedAscending
            }
        case "custom":
            var pos: [String: Int] = [:]
            for (i, id) in lib.projectOrder.enumerated() where pos[id] == nil { pos[id] = i }
            let fresh = newest.filter { pos[$0.id] == nil }
            let known = newest.filter { pos[$0.id] != nil }.sorted { pos[$0.id]! < pos[$1.id]! }
            return fresh + known
        default: return newest
        }
    }

    /// PUT /api/library/order. `projectOrder` may list all projects or only some (e.g. one source's
    /// section): the listed projects are put in that order in the slots they occupy now, everything else
    /// keeps its place. Setting it switches to "custom". Switching to "custom" without an order brings back
    /// the saved custom order (the first time: the order currently shown). Returns ignored ids (unknown or repeated).
    public func setProjectOrder(sort: String?, order: [String]?) throws -> [String] {
        if let s = sort, !LibraryFile.projectSorts.contains(s) { throw StudioError.bad("projectSort must be custom, newest, oldest or name") }
        return sync {
            var ignored: [String] = []
            let current = projectsOrdered().map { $0.id }
            if let order {
                var seen = Set<String>(), listed: [String] = []
                for id0 in order {
                    let id = projects[id0] != nil ? id0 : (lib.aliases[id0] ?? id0)
                    if projects[id] == nil || seen.contains(id) { ignored.append(id0); continue }
                    seen.insert(id); listed.append(id)
                }
                var full = current, it = listed.makeIterator()
                for i in full.indices where seen.contains(full[i]) { full[i] = it.next()! }
                lib.projectOrder = full
                lib.projectSort = "custom"
            } else if let s = sort {
                // back to custom: the saved custom order; the first time, the order shown now
                if s == "custom" && lib.projectSort != "custom" && !lib.projectOrder.contains(where: { projects[$0] != nil }) { lib.projectOrder = current }
                lib.projectSort = s
            }
            markDirty("")
            return ignored
        }
    }
}
