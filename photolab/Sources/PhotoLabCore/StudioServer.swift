import AppKit
import Foundation
import ImageIO

/// Baseline Darkroom's local server: the JSON API (see work/studio-api.md), the preview cache under
/// /files/, and the UI. The UI is served live from $PHOTOLAB_UI_DIR (or `uiDir`) when set, so it can
/// be edited without rebuilding; otherwise from the bundled Resources/studio.
public final class StudioServer {
    public let studio: Studio
    let uiDir: URL?
    let http: HTTPServer
    let log: (String) -> Void
    public var port: UInt16 { http.port }
    /// Set by the Mac app: shows a folder picker (main thread) and returns the chosen path.
    public var chooseFolder: (() -> String?)? = nil
    /// Random per process start: a client seeing it change knows the server was restarted.
    public let instanceId = UUID().uuidString.prefix(12).lowercased()
    let started = Store.iso()
    private var uiHashCache: (String, Date) = ("", .distantPast)
    private let uiHashLock = NSLock()

    /// The UI's version: the newest id in changelog.json (every UI change adds an entry). Content-based on
    /// purpose: on an iCloud Desktop, file sizes and dates flicker while files sync, which made a stat hash
    /// report a "change" every few minutes. A read that fails or doesn't parse keeps the last value.
    /// Rechecked at most every 2 s.
    public var uiHash: String {
        uiHashLock.lock(); defer { uiHashLock.unlock() }
        if Date().timeIntervalSince(uiHashCache.1) < 2 { return uiHashCache.0 }
        var v = uiHashCache.0
        if let dir = uiDir, let d = try? Data(contentsOf: dir.appendingPathComponent("changelog.json")),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            let ids = arr.compactMap { $0["id"] as? String }
            if let newest = ids.max(), newest > v || v.isEmpty { v = newest }
        }
        uiHashCache = (v, Date())
        return v
    }

    public init(studio: Studio, uiDir: URL?, log: @escaping (String) -> Void) {
        self.studio = studio
        self.uiDir = uiDir?.standardizedFileURL
        self.log = log
        var me: StudioServer? = nil
        http = HTTPServer(log: log) { req in me?.route(req) ?? .error(503, "starting") }
        me = self
    }

    /// The UI folder: $PHOTOLAB_UI_DIR, else the given folder, else the bundled one next to the app or
    /// the build products.
    public static func resolveUIDir(_ explicit: String? = nil) -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["PHOTOLAB_UI_DIR"], !env.isEmpty { return URL(fileURLWithPath: (env as NSString).expandingTildeInPath) }
        if let e = explicit { return URL(fileURLWithPath: (e as NSString).expandingTildeInPath) }
        if let r = Bundle.main.resourceURL?.appendingPathComponent("studio"), fm.fileExists(atPath: r.appendingPathComponent("index.html").path) { return r }
        // SwiftPM build products: <build>/PhotoLab_PhotoLabCore.bundle/studio (checked by path, never via
        // Bundle.module, which aborts the process when the bundle is missing).
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for b in [exe.appendingPathComponent("PhotoLab_PhotoLabCore.bundle/studio"), exe.appendingPathComponent("PhotoLab_PhotoLabCore.bundle/Contents/Resources/studio")]
        where fm.fileExists(atPath: b.path) { return b }
        return nil
    }

    @discardableResult
    public func start(port: UInt16) throws -> UInt16 {
        let p = try http.start(port: port)
        studio.announce(port: p)
        log("Baseline Darkroom at http://127.0.0.1:\(p)/ (UI: \(uiDir?.path ?? "not installed"))")
        return p
    }

    public func stop() { http.stop() }

    typealias Req = HTTPServer.Request
    typealias Resp = HTTPServer.Response

    func route(_ req: Req) -> Resp {
        let parts = req.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.first == "api" {
            let t0 = Date()
            let r: Resp
            do { r = try api(req, Array(parts.dropFirst())) } catch let e as StudioError { r = .error(e.status, e.description) } catch { r = .error(500, "\(error)") }
            if req.method != "GET" || r.status >= 400 { log(String(format: "%@ %@ -> %d (%.0f ms)", req.method, req.path, r.status, Date().timeIntervalSince(t0) * 1000)) }
            return r
        }
        guard req.method == "GET" || req.method == "HEAD" else { return .error(405, "method not allowed") }
        if parts.first == "files" { return cacheFile(Array(parts.dropFirst()), req) }
        if parts.first == "luts" { return lutFile(Array(parts.dropFirst())) }   // also /files/luts/…
        if parts.first == "luts-bw" { return lutFile(Array(parts.dropFirst()), bw: true) }
        return uiFile(req.path)
    }

    // MARK: API

    func body(_ req: Req) -> [String: Any] { req.json ?? [:] }

    func api(_ req: Req, _ p: [String]) throws -> Resp {
        let m = req.method
        switch (m, p.first ?? "", p.count) {
        case ("GET", "ping", 1):
            return .json(["ok": true, "app": "Baseline Darkroom", "port": Int(port), "pid": Int(getpid()),
                          "instance": String(instanceId), "uiHash": uiHash, "started": started])
        case ("GET", "library", 1):
            return .json(studio.libraryJSON())
        case ("PUT", "library", 2) where p[1] == "order", ("POST", "library", 2) where p[1] == "order":
            let b = body(req)
            let sort = b["projectSort"] as? String
            var order: [String]? = nil
            if let raw = b["projectOrder"] {
                guard let a = raw as? [Any], a.allSatisfy({ $0 is String }) else { throw StudioError.bad("projectOrder must be an array of project ids") }
                order = a as? [String]
            }
            guard sort != nil || order != nil else { throw StudioError.bad("body must be {projectSort?, projectOrder?}") }
            let ignored = try studio.setProjectOrder(sort: sort, order: order)
            var d = studio.libraryJSON()
            d["ignored"] = ignored
            return .json(d)
        case ("GET", "films", 1):
            return .json(studio.filmsJSON())

        // Connected folders
        case ("GET", "sources", 1):
            return .json(["sources": studio.libraryJSON()["sources"] ?? []])
        case ("POST", "sources", 1), ("POST", "import", 1):
            guard let path = body(req)["path"] as? String, !path.isEmpty else { throw StudioError.bad("body must be {path}") }
            let r = try studio.attach(path)
            let lib = studio.libraryJSON()
            let projects = ((lib["projects"] as? [[String: Any]]) ?? []).filter { r.projects.contains(($0["id"] as? String) ?? "") }
            let src = ((lib["sources"] as? [[String: Any]]) ?? []).first { ($0["id"] as? String) == r.source.id } ?? [:]
            return .json(["source": src, "projects": projects, "projectId": r.projects.first ?? NSNull(), "existing": r.existing])
        case ("DELETE", "sources", 2):
            try studio.detachSource(p[1])
            return .ok

        // Look
        case ("GET", "look", 1):
            return .json(studio.lookJSON())
        case ("POST", "look", 2) where p[1] == "pin":
            guard let pinned = body(req)["pinned"] as? Bool else { throw StudioError.bad("body must be {pinned: true|false}") }
            studio.setPinned(pinned)
            return .json(studio.lookJSON())
        case ("POST", "look", 2) where p[1] == "relearn":
            studio.relearn()
            return .json(studio.lookJSON())
        case ("POST", "look", 1):
            let b = body(req)
            var look = studio.currentLook
            if let from = b["fromPhoto"] as? [String: Any], let pid = from["projectId"] as? String, let id = from["id"] as? String {
                look = try studio.look(fromPhoto: pid, id)
            } else if let raw = b["params"] as? [String: Any] ?? (b["look"] as? [String: Any]) {
                look = try mergeLook(look, raw)
            } else { throw StudioError.bad("body must be {params} or {fromPhoto:{projectId,id}}") }
            if b["dryRun"] as? Bool == true {
                let i = studio.lookImpact(look)
                return .json(["look": Studio.dict(look), "unedited": i.unedited, "all": i.all, "edited": i.edited, "photos": i.photos])
            }
            // Setting the look by hand ("Update My Look from This Photo") pins it: learning stops overriding it.
            studio.setPinned(true)
            let r = studio.setLook(look)
            var d = studio.lookJSON()
            d["look"] = Studio.dict(studio.currentLook); d["changed"] = r.changed; d["queued"] = r.queued
            return .json(d)
        case ("POST", "look", 2) where p[1] == "apply":
            let b = body(req)
            let scope = (b["scope"] as? String) ?? "unedited"
            if scope == "everything" {
                // The starter look (or {look:{...}} merged onto it) for every photo; backup first unless backup:false.
                var look = studio.starterLook
                if let raw = b["look"] as? [String: Any] { look = try mergeLook(look, raw) }
                let only = (b["only"] as? [[String: Any]]).map { Set($0.compactMap { o in (o["projectId"] as? String).flatMap { p in (o["id"] as? String).map { p + "/" + $0 } } }) }
                return .json(try studio.applyLookEverywhere(look, backup: b["backup"] as? Bool != false, dryRun: b["dryRun"] as? Bool == true, only: only))
            }
            guard scope == "unedited" || scope == "all" else { throw StudioError.bad("scope must be \"unedited\", \"all\" or \"everything\"") }
            let r = studio.applyLook(scope: scope, dryRun: b["dryRun"] as? Bool == true)
            return .json(["changed": r.changed, "queued": r.queued, "scope": scope])

        // Settings
        case ("GET", "settings", 1):
            return .json(settingsJSON())
        case ("PUT", "settings", 1), ("POST", "settings", 1):
            let b = body(req)
            try studio.updateSettings(frame: b["frame"] as? [String: Any], exportRoot: b["exportRoot"] as? String, projectFolders: b["projectFolders"] as? Bool)
            if let gb = Studio.number(b["cacheLimitGB"]) { studio.setCacheLimit(gb) }
            // ai.taste is editable; ai.allowedAccount is not (only by editing library.json).
            if let ai = b["ai"] as? [String: Any], let t = ai["taste"] as? String { studio.setAITaste(t) }
            if b.keys.contains("scanCamera") { studio.setScanCamera(b["scanCamera"] as? String) }
            return .json(settingsJSON())

        // Onboarding and Settings: panel, AI provider and key, starting look
        case ("GET", "setup", 1):
            return .json(studio.setupJSON())
        case ("GET", "setup", 2) where p[1] == "claude":
            return .json(studio.claudeCodeStatus())
        case ("POST", "setup", 1), ("PUT", "setup", 1):
            try studio.applySetup(body(req))
            return .json(studio.setupJSON())
        case ("POST", "setup", 2) where p[1] == "test":
            let b = body(req)
            guard let provider = b["provider"] as? String, provider == "anthropic" || provider == "openai" else { throw StudioError.bad("provider must be anthropic or openai") }
            guard let key = (b["key"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? studio.secrets.get(provider) else { throw StudioError.bad("no key to test") }
            let r = StudioProviders.test(provider: provider, key: key)
            return .json(["ok": r.ok, "message": r.message])

        case ("POST", "reveal", 1):
            return try reveal(body(req))

        // Collections
        case ("GET", "collections", 2) where p[1] == "selects":
            return .json(studio.selectsJSON())
        case ("GET", "collections", 2) where p[1] == "best":
            return .json(studio.bestJSON())
        case ("PUT", "collections", 3) where p[1] == "best" && p[2] == "order", ("POST", "collections", 3) where p[1] == "best" && p[2] == "order":
            guard let items = body(req)["items"] as? [[String: Any]] else { throw StudioError.bad("body must be {items:[{projectId,id}]}") }
            let refs = items.compactMap { d -> ItemRef? in
                guard let pid = d["projectId"] as? String, let id = d["id"] as? String else { return nil }
                return ItemRef(projectId: studio.resolveId(pid), id: id)
            }
            let order = studio.setBestOrder(refs)
            return .json(["items": order.map { ["projectId": $0.projectId, "id": $0.id] }])
        case ("POST", "collections", 3) where p[1] == "best" && p[2] == "export":
            var items = studio.bestRefs
            if let sel = body(req)["items"] as? [[String: Any]] {
                let want = Set(sel.compactMap { d -> ItemRef? in (d["projectId"] as? String).flatMap { pid in (d["id"] as? String).map { ItemRef(projectId: pid, id: $0) } } })
                items = items.filter { want.contains($0) }
            }
            let b = body(req)
            return .json(try studio.export(items: items, key: "best", projectName: "Best Work", dest: b["dest"] as? String, frame: b["frame"] as? Bool))
        case ("GET", "collections", 4) where p[1] == "best" && p[2] == "export" && p[3] == "status":
            return .json(studio.exportStatus("best"))

        case ("GET", "cache", 1):
            return .json(["bytes": studio.cacheBytes, "limitGB": studio.libraryJSON()["cacheLimitGB"] ?? 5, "path": studio.cache.path])
        case ("POST", "cache", 2) where p[1] == "evict":
            let r = studio.evictCache(limitBytes: Studio.number(body(req)["limitBytes"]).map { Int64($0) })
            return .json(["before": r.before, "after": r.after, "removed": r.removed])

        // Collections made by hand: /api/collections, /api/collections/<id>[/add|/remove|/order|/export]
        case ("GET", "collections", 1):
            return .json(["collections": studio.collectionsJSON()])
        case ("POST", "collections", 1):
            let b = body(req)
            guard let name = b["name"] as? String else { throw StudioError.bad("body must be {name, items?}") }
            return .json(try studio.createCollection(name, items: refs(b["items"])))
        case (_, "collections", 2...) where p[1].hasPrefix("col-"):
            return try collectionAPI(req, p[1], Array(p.dropFirst(2)))

        case (_, "project", 2...):
            return try projectAPI(req, studio.resolveId(p[1]), Array(p.dropFirst(2)))
        default:
            return .error(404, "unknown endpoint \(m) /api/\(p.joined(separator: "/"))")
        }
    }

    func refs(_ raw: Any?) -> [ItemRef] {
        ((raw as? [[String: Any]]) ?? []).compactMap { d in
            guard let pid = d["projectId"] as? String, let id = d["id"] as? String else { return nil }
            return ItemRef(projectId: studio.resolveId(pid), id: id)
        }
    }

    func collectionAPI(_ req: Req, _ cid: String, _ rest: [String]) throws -> Resp {
        let b = body(req)
        switch (req.method, rest.first ?? "", rest.count) {
        case ("GET", "", 0):
            return .json(try studio.collectionJSON(cid))
        case ("PATCH", "", 0), ("PUT", "", 0):
            guard let name = b["name"] as? String else { throw StudioError.bad("body must be {name}") }
            return .json(try studio.renameCollection(cid, name))
        case ("DELETE", "", 0):
            try studio.deleteCollection(cid)
            return .ok
        case ("POST", "add", 1):
            let r = try studio.addToCollection(cid, refs(b["items"]))
            var d = r.summary; d["added"] = r.added
            return .json(d)
        case ("POST", "remove", 1):
            return .json(try studio.removeFromCollection(cid, refs(b["items"])))
        case ("PUT", "order", 1), ("POST", "order", 1):
            let order = try studio.setCollectionOrder(cid, refs(b["items"]))
            return .json(["items": order.map { ["projectId": $0.projectId, "id": $0.id] }])
        case ("POST", "export", 1):
            let c = try studio.collectionRefs(cid)
            var items = c.items
            if b["items"] != nil { let want = Set(refs(b["items"])); items = items.filter { want.contains($0) } }
            return .json(try studio.export(items: items, key: cid, projectName: c.name, dest: b["dest"] as? String, frame: b["frame"] as? Bool))
        case ("GET", "export", 2) where rest[1] == "status":
            return .json(studio.exportStatus(cid))
        default:
            return .error(404, "unknown endpoint")
        }
    }

    func mergeLook(_ base: LookParams, _ raw: [String: Any]) throws -> LookParams {
        var l = base
        for k in scaledLookKeys { if let v = Studio.number(raw[k]) { l[k] = v } }
        if raw.keys.contains("film") { l.film = (raw["film"] as? String) ?? "" }
        if let g = raw["grainSize"] as? String { l.grainSize = g }
        return l
    }

    func settingsJSON() -> [String: Any] {
        let lib = studio.libraryJSON()
        return ["frame": lib["frame"] ?? [:], "exportRoot": lib["exportRoot"] ?? "~/Desktop", "exportDir": lib["exportDir"] ?? NSNull(),
                "projectFolders": lib["projectFolders"] ?? false, "cacheLimitGB": lib["cacheLimitGB"] ?? 5, "scanCamera": studio.scanCamera ?? NSNull(),
                "ai": ["allowedAccount": studio.aiAllowedAccount, "taste": studio.aiTaste]]
    }

    func projectAPI(_ req: Req, _ pid: String, _ rest: [String]) throws -> Resp {
        let m = req.method
        let b = body(req)
        switch (m, rest.first ?? "", rest.count) {
        case ("GET", "", 0):
            let d = try studio.projectJSON(pid)
            studio.projectOpened(pid)
            return .json(d)
        case ("PATCH", "", 0), ("PUT", "", 0):
            guard let name = b["name"] as? String else { throw StudioError.bad("body must be {name}") }
            try studio.rename(pid, name)
            return .json(["id": pid, "name": studio.projectName(pid) ?? name])
        case ("DELETE", "", 0):
            try studio.remove(pid)
            return .ok
        case ("GET", "status", 1):
            return .json(try studio.status(pid))
        case ("POST", "locate", 1):
            guard let path = b["path"] as? String else { throw StudioError.bad("body must be {path}") }
            try studio.locate(pid, path)
            return .json(try studio.projectJSON(pid))
        case ("POST", "rescan", 1):
            studio.scanProject(pid)
            return .json(try studio.status(pid))
        case ("POST", "reanalyze", 1):
            try studio.reanalyze(pid)
            return .json(try studio.status(pid))
        case ("POST", "rate", 1):
            guard let ids = b["ids"] as? [String] ?? (b["id"] as? String).map({ [$0] }) else { throw StudioError.bad("body must be {ids, rating?, flag?, favorite?}") }
            let rating = Studio.number(b["rating"]).map { Int($0) }
            var flag: String?? = nil
            if b.keys.contains("flag") {
                let f = b["flag"]
                if f is NSNull { flag = .some(nil) }
                else if let s = f as? String { flag = .some(s == "pick" || s == "reject" ? s : nil) }
                else if let n = Studio.number(f) { flag = .some(n > 0 ? "pick" : n < 0 ? "reject" : nil) }
            }
            let fav = b["favorite"] as? Bool
            let photos = try studio.rate(pid, ids: ids, rating: rating, flag: flag, favorite: fav, seq: Studio.number(b["seq"]).map { Int($0) })
            return .json(["ok": true, "photos": photos])
        case ("POST", "paste", 1):
            guard let ids = b["ids"] as? [String], let params = b["params"] as? [String: Any] else { throw StudioError.bad("body must be {ids, params}") }
            let done = try studio.paste(pid, ids: ids, raw: params, geometry: b["geometry"] as? Bool == true)
            studio.renderMany(pid, done)
            let photos = done.compactMap { id -> [String: Any]? in
                guard let d = try? studio.photoJSON(pid, id) else { return nil }
                return ["id": id, "thumb": d["thumb"] ?? NSNull(), "preview": d["preview"] ?? NSNull(), "edited": d["edited"] ?? false,
                        "version": d["version"] ?? 0, "params": d["params"] ?? [:], "pipeline": d["pipeline"] ?? NSNull(),
                        "previewParams": d["previewParams"] ?? NSNull()]
            }
            return .json(["ok": true, "photos": photos])
        case ("POST", "export", 1):
            let sel = b["ids"] ?? b["scope"] ?? req.jsonAny
            let ids = try studio.exportIds(pid, sel is [String: Any] ? nil : sel)
            return .json(try studio.export(items: ids.map { ItemRef(projectId: pid, id: $0) }, key: pid, projectName: studio.projectName(pid)))
        case ("GET", "export", 2) where rest[1] == "status":
            return .json(studio.exportStatus(pid))
        case (_, "photo", 2...):
            return try photoAPI(req, pid, rest[1], Array(rest.dropFirst(2)))
        default:
            return .error(404, "unknown endpoint")
        }
    }

    func photoAPI(_ req: Req, _ pid: String, _ id: String, _ rest: [String]) throws -> Resp {
        let b = body(req)
        switch (req.method, rest.first ?? "") {
        case ("GET", ""):
            return .json(try studio.photoJSON(pid, id))
        case ("POST", "params"), ("PUT", "params"):
            let t0 = Date()
            guard let params = b["params"] as? [String: Any] ?? (b.isEmpty ? nil : b) else { throw StudioError.bad("body must be {params}") }
            let applied = try studio.setParams(pid, id, raw: params, seq: Studio.number(b["seq"]).map { Int($0) })
            if !applied {
                var d = try studio.photoJSON(pid, id)
                d["stale"] = true; d["ignored"] = "older seq"; d["renderError"] = NSNull(); d["ms"] = 0
                return .json(d)
            }
            let outcome = studio.renderInteractive(pid, id, displayLong: Self.displayLong(req, b))
            var d = try studio.photoJSON(pid, id)
            d["stale"] = outcome == .stale
            d["renderError"] = outcome == .failed ? (studio.rt == nil ? "RawTherapee isn't available" : "the preview couldn't be rendered") : NSNull()
            d["ms"] = Int(Date().timeIntervalSince(t0) * 1000)
            return .json(d)
        case ("POST", "neutralize"):
            return .json(try studio.neutralize(pid, id))
        case ("POST", "reset"):
            try studio.reset(pid, id)
            let outcome = studio.renderInteractive(pid, id, displayLong: Self.displayLong(req, b))
            var d = try studio.photoJSON(pid, id)
            d["stale"] = outcome == .stale
            return .json(d)
        case ("POST", "export"):
            return .json(try studio.export(items: [ItemRef(projectId: pid, id: id)], key: pid, projectName: studio.projectName(pid)))
        case ("POST", "critique"):
            // Claude's critique of the current edit: starts it (or returns the cached one). `wait: true`
            // blocks until it's done (up to 2 minutes); otherwise poll the photo JSON (aiState).
            var d = try studio.requestAICritique(pid, id, force: b["force"] as? Bool == true)
            if b["wait"] as? Bool == true {
                let t0 = Date()
                while (d["aiState"] as? String) == "running" && Date().timeIntervalSince(t0) < 300 {
                    Thread.sleep(forTimeInterval: 0.5)
                    let p = try studio.photoJSON(pid, id)
                    d = ["aiAvailable": p["aiAvailable"] ?? false, "aiCritique": p["aiCritique"] ?? NSNull(), "aiState": p["aiState"] ?? "idle", "aiError": p["aiError"] ?? NSNull()]
                }
            }
            return .json(d)
        case ("GET", "params.json"):
            // The photo's params exactly as the old per-photo params files were written (verification/debugging).
            return Resp(status: 200, type: "application/json; charset=utf-8", body: try studio.legacyParamsJSON(pid, id))
        default:
            return .error(404, "unknown endpoint")
        }
    }

    /// `w` (body or query): the long edge, in device pixels, the editor shows the preview at.
    static func displayLong(_ req: Req, _ b: [String: Any]) -> Int? {
        (Studio.number(b["w"]) ?? req.query["w"].flatMap(Double.init)).map { Int($0) }
    }

    func reveal(_ b: [String: Any]) throws -> Resp {
        var path = (b["path"] as? String).map { ($0 as NSString).expandingTildeInPath }
        if path == nil, let pid = b["projectId"] as? String {
            if let id = b["id"] as? String { path = studio.photoRef(pid, id)?.0.path } else { path = studio.projectFolder(pid) }
        }
        guard let p = path, p.hasPrefix("/") else { throw StudioError.bad("body must be {path} or {projectId, id?}") }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: p, isDirectory: &isDir) else { throw StudioError.notFound("\(p) doesn't exist") }
        DispatchQueue.main.async {
            if isDir.boolValue { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p) }
            else { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
        }
        return .json(["ok": true, "path": p])
    }

    // MARK: Preview cache files

    /// /files/<pid>/<kind>/<photo>.<ext>, kinds: thumbs, renders, proxies, clip, analysis/thumbs,
    /// analysis/previews, analysis/overlays. Missing cache files are regenerated on demand.
    func cacheFile(_ parts: [String], _ req: Req) -> Resp {
        if parts.first == "luts" { return lutFile(Array(parts.dropFirst())) }
        guard parts.count >= 3 else { return .error(404, "not found") }
        let pid = studio.resolveId(parts[0]), name = parts.last!, kind = parts.dropFirst().dropLast().joined(separator: "/")
        let id = (name as NSString).deletingPathExtension.replacingOccurrences(of: "-clip", with: "")
        guard !name.hasPrefix("."), !name.contains("/"), let (ref, version) = studio.photoRef(pid, id) else { return .error(404, "not found") }
        let eng = studio.engine(pid)
        let dir = studio.projectDir(pid)
        let fm = FileManager.default
        var file: URL
        var fallback: URL? = nil
        switch kind {
        case "thumbs":
            // Missing (evicted or never made): made now, from the render or a small RawTherapee render.
            file = studio.ensureThumb(pid, id) ?? eng.thumbURL(ref)
            fallback = dir.appendingPathComponent("analysis/thumbs/\(id).jpg")
        case "renders":
            file = eng.previewURL(ref)
            if !fm.fileExists(atPath: file.path) { studio.renderNow(pid, id, interactive: false) }
            fallback = fm.fileExists(atPath: eng.proxyURL(ref).path) ? eng.proxyURL(ref) : eng.thumbURL(ref)
        case "full":
            guard let f = studio.renderFull(pid, id) else { return .error(404, "not found") }
            file = f
        case "fullres":
            guard let f = studio.renderFullRes(pid, id) else { return .error(404, "not found") }
            file = f
        case "proxies":
            file = eng.proxyURL(ref)
            if !fm.fileExists(atPath: file.path) { eng.ensureProxy(ref) }
        case "clip":
            file = dir.appendingPathComponent("clip/\(id)-\(version).png")
            if !fm.fileExists(atPath: file.path) {
                if !fm.fileExists(atPath: eng.previewURL(ref).path) { studio.renderNow(pid, id, interactive: false) }
                Self.writeClipOverlay(from: eng.previewURL(ref), to: file)
            }
        case "analysis/thumbs", "analysis/previews", "analysis/overlays":
            file = dir.appendingPathComponent(kind).appendingPathComponent(name)
        default:
            return .error(404, "not found")
        }
        var real = true
        if !fm.fileExists(atPath: file.path), let fb = fallback, fm.fileExists(atPath: fb.path) { file = fb; real = false }
        guard let data = try? Data(contentsOf: file) else {
            // Never a 404 for a photo that exists: a neutral placeholder, not cached by the browser.
            log("couldn't make \(kind)/\(name) for \(pid); served a placeholder")
            var r = Resp(status: 200, type: "image/jpeg", body: Self.placeholderJPEG)
            r.cache = "no-store"
            return r
        }
        studio.touchCached(file)
        var r = Resp(status: 200, type: HTTPServer.types[file.pathExtension.lowercased()] ?? "application/octet-stream", body: data)
        r.cache = real && req.query["v"] != nil ? "max-age=86400" : "no-store"
        return r
    }

    /// A small neutral grey JPEG (placeholder when an image can't be made).
    static let placeholderJPEG: Data = {
        let w = 48, h = 32
        let px = [UInt8](repeating: 46, count: w * h * 4)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("photolab-placeholder-\(UUID().uuidString).jpg")
        var data = px
        let cg: CGImage? = data.withUnsafeMutableBytes { ptr in
            CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
        if let cg { Pixels.writeJPEG(cg, to: tmp, quality: 0.8) }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return (try? Data(contentsOf: tmp)) ?? Data()
    }()

    /// /files/luts/<path inside the LUT root>: Hald CLUT PNGs as they are, cacheable for a long time.
    func lutFile(_ rel: [String], bw: Bool = false) -> Resp {
        let base = bw ? studio.lutRoot?.deletingLastPathComponent().appendingPathComponent("Black-and-White") : studio.lutRoot
        guard let root = base?.standardizedFileURL, !rel.isEmpty,
              !rel.contains(where: { $0.hasPrefix(".") || $0.contains("\0") }), rel.last!.lowercased().hasSuffix(".png") else { return .error(404, "not found") }
        let url = rel.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"), let data = Store.readAll(url) else { return .error(404, "not found") }
        var r = Resp(status: 200, type: "image/png", body: data)
        r.cache = "public, max-age=31536000, immutable"
        return r
    }

    /// Clipping overlay of the edited preview: red where a channel clips white, blue where all
    /// channels are black, transparent elsewhere.
    static func writeClipOverlay(from src: URL, to out: URL) {
        guard let s = CGImageSourceCreateWithURL(src as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return }
        let px = Pixels.rgba(img)
        var o = [UInt8](repeating: 0, count: px.width * px.height * 4)
        for i in 0..<(px.width * px.height) {
            let r = px.data[i * 4], g = px.data[i * 4 + 1], b = px.data[i * 4 + 2]
            if r >= 254 || g >= 254 || b >= 254 { o[i * 4] = 255; o[i * 4 + 1] = 40; o[i * 4 + 2] = 40; o[i * 4 + 3] = 255 }
            else if r <= 1 && g <= 1 && b <= 1 { o[i * 4] = 40; o[i * 4 + 1] = 110; o[i * 4 + 2] = 255; o[i * 4 + 3] = 255 }
        }
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = out.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).png")
        Pixels.writePNG(rgba: o, width: px.width, height: px.height, to: tmp)
        try? FileManager.default.moveItem(at: tmp, to: out)
    }

    // MARK: UI files

    func uiFile(_ path: String) -> Resp {
        var rel = path
        while rel.hasPrefix("/") { rel.removeFirst() }
        if rel.isEmpty || rel.hasSuffix("/") { rel += "index.html" }
        guard let dir = uiDir else { return fallbackPage() }
        let url = dir.appendingPathComponent(rel).standardizedFileURL
        guard url.path.hasPrefix(dir.path + "/"), !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return .error(404, "not found") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue, let data = Store.readAll(url) else {
            return rel == "index.html" ? fallbackPage() : .error(404, "not found")
        }
        return Resp(status: 200, type: HTTPServer.types[url.pathExtension.lowercased()] ?? "application/octet-stream", body: data)
    }

    func fallbackPage() -> Resp {
        let html = "<!doctype html><meta charset=utf-8><title>Baseline Darkroom</title><body style=\"background:#1e1e1e;color:#aaa;font:14px -apple-system;padding:40px\">Baseline Darkroom is running, but its UI isn't installed.</body>"
        return Resp(status: 200, type: "text/html; charset=utf-8", body: Data(html.utf8))
    }
}

extension Studio {
    public func setCacheLimit(_ gb: Double) {
        sync { lib.cacheLimitGB = max(0.5, min(500, gb)); markDirty("") }
    }
}
