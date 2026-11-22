import Foundation
import ImageIO
import Network

/// `photolab serve`: a minimal local HTTP/1.1 server (127.0.0.1 only) for the report and the editor API.
///
///   GET  /api/ping                  -> {ok, films, look}
///   GET  /api/photo/<id>            -> {params, recommended, steps, preview, thumb, modified, ...}
///   POST /api/photo/<id>/render     body {params} -> clamp, save params + sidecar, render 1600 px preview
///   POST /api/photo/<id>/reset      -> params = recommended, render
///   POST /api/photo/<id>/export     -> full-res JPEG q95 4:4:4 at <report>/export/<id>.jpg
///   POST /api/export-all            -> export every photo
///   anything else                   -> static file from the report folder
public final class PhotoLabServer {
    let dir: URL
    let engine: EditEngine
    private var report: ShootReport
    private var index: [String: Int] = [:]
    private let state = NSLock()          // guards report, latest, committed
    private let writeLock = NSLock()      // serializes report.json/report.js writes
    private var latest: [String: Int] = [:]      // newest render request per photo
    private var committed: [String: Int] = [:]   // newest render that reached disk per photo
    private var seq = 0
    private let renderSlots: DispatchSemaphore
    private let exportSlots = DispatchSemaphore(value: 2)
    private let queue = DispatchQueue(label: "photolab.server", qos: .userInitiated, attributes: .concurrent)
    private var listener: NWListener?
    private var originals = "checking"   // can this process read the originals? ok | waiting | denied
    let log: (String) -> Void

    public init(reportDir: URL, rt: URL, lutRoot: URL?, renders: Int = 3, log: @escaping (String) -> Void) throws {
        dir = reportDir.standardizedFileURL
        engine = EditEngine(reportDir: dir, lutRoot: lutRoot, rt: rt)
        renderSlots = DispatchSemaphore(value: max(1, renders))
        self.log = log
        // Temp files left by a server that was stopped mid-render.
        for sub in ["edits/.tmp", "edit/.photolab/render", "export/.tmp"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(sub)) }
        var r = try JSONDecoder().decode(ShootReport.self, from: Data(contentsOf: dir.appendingPathComponent("report.json")))
        // Make sure every photo has recommended/current params and a sidecar (older reports lack them).
        try prepareEdits(&r, reportDir: dir, reset: false, lutRoot: lutRoot)
        report = r
        for (i, p) in r.photos.enumerated() { index[p.id] = i }
        seq = r.photos.compactMap { $0.edit?.version }.max() ?? 0
        try writeReportData(r, to: dir)
        // Proxies make preview renders fast; build any that are missing in the background.
        let photos = r.photos, eng = engine
        DispatchQueue.global(qos: .utility).async { DispatchQueue.concurrentPerform(iterations: photos.count) { _ = eng.ensureProxy(photos[$0]) } }
        probeOriginals()
    }

    /// Full-size export reads the originals. When they sit in a privacy-protected folder (Desktop,
    /// Documents, Downloads) and this process was started by an app without access, macOS holds
    /// the first read behind a permission prompt. Probe once at startup so the prompt appears early
    /// and the UI can say why an export is waiting.
    private func probeOriginals() {
        guard let first = report.photos.first else { originals = "ok"; return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fd = open(first.path, O_RDONLY)
            let st = fd >= 0 ? "ok" : (errno == EPERM || errno == EACCES ? "denied" : "ok")
            if fd >= 0 { close(fd) }
            guard let self else { return }
            self.state.lock(); self.originals = st; self.state.unlock()
            if st != "ok" { self.log("cannot read the originals (\(first.path)): permission denied. Full-size export will fail; previews still work.") }
            else { self.log("originals readable") }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.state.lock(); let waiting = self.originals == "checking"; if waiting { self.originals = "waiting" }; self.state.unlock()
            if waiting { self.log("reading the originals is waiting on macOS (a privacy prompt for \(URL(fileURLWithPath: first.path).deletingLastPathComponent().path)?). Allow it for full-size export.") }
        }
    }

    public func start(port: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: self?.log("photolab serving \(self?.dir.path ?? "") at http://127.0.0.1:\(port)/index.html")
            case .failed(let e): self?.log("server failed: \(e)"); exit(1)
            default: break
            }
        }
        l.start(queue: queue)
        listener = l
    }

    // MARK: HTTP plumbing

    struct Request {
        var method: String
        var path: String
        var query: String
        var headers: [String: String]
        var body: Data
    }

    struct Response: Error {
        var status: Int
        var type: String
        var body: Data
        var cache: String = "no-store"
        static func json(_ obj: Any, status: Int = 200) -> Response {
            let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
            return Response(status: status, type: "application/json; charset=utf-8", body: d)
        }
        static func error(_ status: Int, _ msg: String) -> Response { json(["error": msg], status: status) }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            switch Self.parse(buf) {
            case .some(.some(let req)):
                let resp = self.route(req)
                self.send(c, resp, head: req.method == "HEAD")
            case .some(.none):
                self.send(c, .error(400, "bad request"), head: false)
            case .none:
                if complete || error != nil || buf.count > 8 << 20 { c.cancel() } else { self.receive(c, buf) }
            }
        }
    }

    /// nil = need more bytes; .some(nil) = malformed.
    static func parse(_ buf: Data) -> Request?? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return buf.count > 64 << 10 ? .some(nil) : nil }
        guard let head = String(data: buf[buf.startIndex..<end.lowerBound], encoding: .utf8) else { return .some(nil) }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return .some(nil) }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        if buf.count - (bodyStart - buf.startIndex) < length { return nil }
        let target = String(first[1])
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        return .some(Request(method: String(first[0]).uppercased(), path: path, query: parts.count > 1 ? String(parts[1]) : "",
                             headers: headers, body: buf[bodyStart..<(bodyStart + length)]))
    }

    private func send(_ c: NWConnection, _ r: Response, head: Bool) {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 500: "Internal Server Error"][r.status] ?? "OK"
        var h = "HTTP/1.1 \(r.status) \(reason)\r\nContent-Type: \(r.type)\r\nContent-Length: \(r.body.count)\r\n"
        h += "Cache-Control: \(r.cache)\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        var out = Data(h.utf8)
        if !head { out.append(r.body) }
        c.send(content: out, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: Routing

    private func route(_ req: Request) -> Response {
        let parts = req.path.split(separator: "/").map(String.init)
        if parts.first == "api" {
            let t0 = Date()
            let r = api(req, Array(parts.dropFirst()))
            if req.method == "POST" { log(String(format: "%@ %@ -> %d (%.0f ms)", req.method, req.path, r.status, Date().timeIntervalSince(t0) * 1000)) }
            return r
        }
        guard req.method == "GET" || req.method == "HEAD" else { return .error(405, "method not allowed") }
        return staticFile(req.path)
    }

    private func api(_ req: Request, _ p: [String]) -> Response {
        switch (req.method, p.count) {
        case ("GET", 1) where p[0] == "ping":
            state.lock(); let orig = originals; state.unlock()
            return .json(["ok": true, "look": lookName, "originals": orig, "films": filmStocks.map { ["path": $0.path, "name": $0.name] }])
        case ("POST", 1) where p[0] == "export-all":
            return exportAll(req.body)
        case ("GET", 1) where p[0] == "export-settings":
            return .json(settingsJSON(exportSettings()))
        case ("POST", 1) where p[0] == "export-settings":
            switch takeSettings(req.body) {
            case .failure(let e): return .error(400, e.description)
            case .success(let s): return .json(settingsJSON(s))
            }
        case (_, 2...3) where p[0] == "photo":
            guard let photo = photo(p[1]) else { return .error(404, "no photo \(p[1])") }
            if p.count == 2 {
                guard req.method == "GET" else { return .error(405, "method not allowed") }
                return .json(photoJSON(photo.id))
            }
            guard req.method == "POST" else { return .error(405, "method not allowed") }
            switch p[2] {
            case "render":
                guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else { return .error(400, "body must be JSON {params}") }
                let raw = obj["params"] ?? obj
                guard let d = try? JSONSerialization.data(withJSONObject: raw), let e = try? JSONDecoder().decode(EditParams.self, from: d) else {
                    return .error(400, "params must be an object")
                }
                return render(photo, e.clamped(lutRoot: engine.lutRoot))
            case "reset":
                return render(photo, engine.loadRecommended(photo))
            case "export":
                return export(photo, req.body)
            default: return .error(404, "unknown action")
            }
        default:
            return .error(404, "unknown endpoint")
        }
    }

    private func photo(_ id: String) -> PhotoReport? {
        state.lock(); defer { state.unlock() }
        return index[id].map { report.photos[$0] }
    }

    private func photoJSON(_ id: String, extra: [String: Any] = [:]) -> [String: Any] {
        state.lock()
        let p = report.photos[index[id]!]
        state.unlock()
        let e = p.edit
        let v = e?.version ?? 0
        let enc = JSONEncoder()
        func obj<T: Encodable>(_ x: T?) -> Any {
            guard let x, let d = try? enc.encode(x), let o = try? JSONSerialization.jsonObject(with: d) else { return NSNull() }
            return o
        }
        var out: [String: Any] = [
            "id": p.id,
            "params": obj(e?.params), "recommended": obj(e?.recommended), "steps": obj(e?.steps),
            "preview": e?.preview.map { "\($0)?v=\(v)" } ?? NSNull(), "thumb": e?.thumb.map { "\($0)?v=\(v)" } ?? NSNull(),
            "modified": e?.modified ?? false, "userModified": e?.userModified ?? false, "version": v,
        ]
        for (k, x) in extra { out[k] = x }
        return out
    }

    /// Save + render with latest-request-wins per photo: a render only reaches disk if no newer one
    /// for the same photo already has; a queued render is skipped if a newer one is waiting behind it.
    private func render(_ photo: PhotoReport, _ e: EditParams) -> Response {
        let id = photo.id
        let t0 = Date()
        state.lock()
        let gen = (latest[id] ?? 0) + 1
        latest[id] = gen
        // Persist right away so params.json/sidecar always hold the newest request.
        do { try engine.save(e, for: photo) } catch { state.unlock(); return .error(500, "could not save: \(error)") }
        let i = index[id]!
        report.photos[i].edit?.params = e
        report.photos[i].edit?.modified = e != report.photos[i].edit?.recommended
        report.photos[i].edit?.userModified = false
        state.unlock()

        renderSlots.wait()
        defer { renderSlots.signal() }
        state.lock(); let superseded = (latest[id] ?? 0) > gen; state.unlock()
        if superseded { return .json(photoJSON(id, extra: ["stale": true, "ms": ms(t0)])) }

        let tmpDir = dir.appendingPathComponent("edits/.tmp")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmpPreview = tmpDir.appendingPathComponent("\(id)-\(gen)-\(UUID().uuidString).jpg")
        let tmpThumb = tmpDir.appendingPathComponent("\(id)-\(gen)-\(UUID().uuidString)-thumb.jpg")
        let ok = engine.renderPreview(photo, params: e, to: tmpPreview, thumbOut: tmpThumb)
        let renderMs = ms(t0)
        defer { try? FileManager.default.removeItem(at: tmpPreview); try? FileManager.default.removeItem(at: tmpThumb) }
        guard ok else { return .error(500, "RawTherapee render failed") }

        state.lock()
        if (committed[id] ?? 0) > gen { state.unlock(); return .json(photoJSON(id, extra: ["stale": true, "ms": renderMs])) }
        committed[id] = gen
        let fm = FileManager.default
        func place(_ src: URL, _ dst: URL) {
            if fm.fileExists(atPath: dst.path) { _ = try? fm.replaceItemAt(dst, withItemAt: src) } else { try? fm.moveItem(at: src, to: dst) }
        }
        place(tmpPreview, engine.previewURL(photo))
        place(tmpThumb, engine.thumbURL(photo))
        seq += 1
        report.photos[i].edit?.preview = "edits/\(id).jpg"
        report.photos[i].edit?.thumb = "thumbs/\(id)-edit.jpg"
        report.photos[i].edit?.version = seq
        state.unlock()
        saveReport()
        state.lock(); let newer = (latest[id] ?? 0) > gen; state.unlock()
        return .json(photoJSON(id, extra: ["stale": newer, "ms": renderMs]))
    }

    private func ms(_ t0: Date) -> Int { Int(Date().timeIntervalSince(t0) * 1000) }

    private func saveReport() {
        writeLock.lock(); defer { writeLock.unlock() }
        state.lock(); let snapshot = report; state.unlock()
        do { try writeReportData(snapshot, to: dir) } catch { log("could not write report: \(error)") }
    }

    // MARK: Export

    private var exportSettingsCache: ExportSettings?
    // Files this shoot's exports wrote (edit/.photolab/exported.json): only these may be overwritten.
    private lazy var exported: Set<String> = {
        let url = dir.appendingPathComponent("edit/.photolab/exported.json")
        return Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: url))) ?? [])
    }()
    private func owns(_ path: String) -> Bool { state.lock(); defer { state.unlock() }; return exported.contains(path) }
    private func remember(_ path: String) {
        state.lock(); exported.insert(path); let list = exported.sorted(); state.unlock()
        writeLock.lock(); defer { writeLock.unlock() }
        try? JSONEncoder().encode(list).write(to: dir.appendingPathComponent("edit/.photolab/exported.json"), options: .atomic)
    }
    private func exportSettings() -> ExportSettings {
        state.lock(); defer { state.unlock() }
        if exportSettingsCache == nil { exportSettingsCache = loadExportSettings(reportDir: dir) }
        return exportSettingsCache!
    }

    private func settingsJSON(_ s: ExportSettings) -> [String: Any] {
        state.lock(); let r = report; state.unlock()
        let resolved = (try? resolveExportDir(s, report: r, reportDir: dir, create: false))?.path
        return ["settings": ["frame": s.frame, "side": s.side, "topBottom": s.topBottom, "color": s.color, "dest": s.dest],
                "dest": resolved ?? NSNull(), "defaultDest": defaultExportDir(shoot: r.name)]
    }

    /// Validates (incl. the destination) and saves settings from a request body {settings}; nil body = saved settings.
    private func takeSettings(_ body: Data) -> Result<ExportSettings, ExportError> {
        var s = exportSettings()
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let raw = obj["settings"],
           let d = try? JSONSerialization.data(withJSONObject: raw), let ns = try? JSONDecoder().decode(ExportSettings.self, from: d) {
            s = ns.clamped()
        }
        state.lock(); let r = report; state.unlock()
        do { _ = try resolveExportDir(s, report: r, reportDir: dir, create: false) } catch let e as ExportError { return .failure(e) } catch { return .failure(.badDestination("\(error)")) }
        if s != exportSettings() {
            try? saveExportSettings(s, reportDir: dir)
            state.lock(); exportSettingsCache = s; state.unlock()
        }
        return .success(s)
    }

    private func exportPhoto(_ p: PhotoReport, _ s: ExportSettings, _ dest: URL) -> Result<ExportResult, ExportError> {
        exportSlots.wait(); defer { exportSlots.signal() }
        let r = engine.export(p, toDir: dest, settings: s, owns: { [unowned self] in owns($0) })
        if case .success(let x) = r { remember(x.path.path) }
        return r
    }

    private func originalsHint(_ e: ExportError, _ p: PhotoReport) -> String {
        state.lock(); let orig = originals; state.unlock()
        if case .render = e, orig != "ok" {
            return "could not read the original (macOS file permission for \(URL(fileURLWithPath: p.path).deletingLastPathComponent().lastPathComponent) is \(orig == "denied" ? "denied" : "pending")); run photolab serve from Terminal or allow access"
        }
        return e.description
    }

    private func prepareExport(_ body: Data) -> Result<(ExportSettings, URL), Response> {
        switch takeSettings(body) {
        case .failure(let e): return .failure(.error(400, e.description))
        case .success(let s):
            state.lock(); let r = report; state.unlock()
            do { return .success((s, try resolveExportDir(s, report: r, reportDir: dir))) } catch { return .failure(.error(400, "\(error)")) }
        }
    }

    private func export(_ photo: PhotoReport, _ body: Data) -> Response {
        let t0 = Date()
        let (s, dest): (ExportSettings, URL)
        switch prepareExport(body) { case .failure(let r): return r; case .success(let v): (s, dest) = v }
        switch exportPhoto(photo, s, dest) {
        case .failure(let e): return .error(500, originalsHint(e, photo))
        case .success(let r):
            return .json(["path": r.path.path, "dir": dest.path, "width": r.width, "height": r.height,
                          "imageWidth": r.imageWidth, "imageHeight": r.imageHeight, "frame": s.frame, "ms": ms(t0)])
        }
    }

    private func exportAll(_ body: Data) -> Response {
        let t0 = Date()
        let (s, dest): (ExportSettings, URL)
        switch prepareExport(body) { case .failure(let r): return r; case .success(let v): (s, dest) = v }
        state.lock(); let photos = report.photos; state.unlock()
        var ok = 0, failed: [String] = [], firstError: String?
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: photos.count) { i in
            let r = exportPhoto(photos[i], s, dest)
            lock.lock()
            switch r {
            case .success: ok += 1
            case .failure(let e): failed.append(photos[i].id); if firstError == nil { firstError = originalsHint(e, photos[i]) }
            }
            lock.unlock()
        }
        return .json(["count": ok, "failed": failed, "error": firstError ?? NSNull(), "dir": dest.path, "frame": s.frame, "ms": ms(t0)])
    }

    // MARK: Static files

    static let types: [String: String] = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "json": "application/json; charset=utf-8",
        "css": "text/css; charset=utf-8", "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "svg": "image/svg+xml",
        "webp": "image/webp", "gif": "image/gif", "ico": "image/x-icon", "txt": "text/plain; charset=utf-8", "pp3": "text/plain; charset=utf-8",
    ]

    private func staticFile(_ path: String) -> Response {
        var rel = path
        while rel.hasPrefix("/") { rel.removeFirst() }
        if rel.isEmpty { rel = "index.html" }
        let url = dir.appendingPathComponent(rel).standardizedFileURL
        guard url.path.hasPrefix(dir.path + "/"), !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return .error(404, "not found") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              let data = try? Data(contentsOf: url) else { return .error(404, "not found") }
        let ext = url.pathExtension.lowercased()
        var r = Response(status: 200, type: Self.types[ext] ?? "application/octet-stream", body: data)
        // Analysis artefacts never change while serving; edits, report data and the page do.
        let immutable = rel.hasPrefix("previews/") || rel.hasPrefix("overlays/") || (rel.hasPrefix("thumbs/") && !rel.hasSuffix("-edit.jpg"))
        r.cache = immutable ? "max-age=600" : "no-store"
        return r
    }
}
