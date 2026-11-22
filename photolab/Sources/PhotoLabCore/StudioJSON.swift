import Foundation
import ImageIO

// API payloads (dictionaries for JSONSerialization). Image URLs are absolute paths on the server,
// versioned (?v=N) so the browser can cache them.

extension Studio {
    static func dict<T: Encodable>(_ v: T) -> Any {
        guard let d = try? Store.encoder.encode(v), let o = try? JSONSerialization.jsonObject(with: d) else { return NSNull() }
        return o
    }

    func paramsDict(_ e: EditParams, lookAmount: Double) -> [String: Any] {
        var d = (Self.dict(e) as? [String: Any]) ?? [:]
        d["lookAmount"] = lookAmount
        d["crop"] = e.crop.map { Self.dict($0) } ?? NSNull()
        d["grain"] = e.grain
        d["grainSize"] = e.grainSize
        return d
    }

    func fileURL(_ pid: String, _ sub: String, _ name: String, v: Int? = nil) -> String {
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? s }
        return "/files/\(enc(pid))/\(sub)/\(enc(name))" + (v.map { "?v=\($0)" } ?? "")
    }

    /// Grid thumbnail: the edited render, else the unedited analysis thumbnail (while rendering).
    /// Grid thumbnail: the edited thumbnail (made on request if missing); for a photo still being analysed,
    /// its quick unedited thumbnail.
    func thumbURL(_ pid: String, _ ph: PhotoEntry) -> String? {
        if ph.analyzed { return fileURL(pid, "thumbs", ph.id + ".jpg", v: ph.version) }
        if FileManager.default.fileExists(atPath: projectDir(pid).appendingPathComponent("analysis/thumbs/\(ph.id).jpg").path) {
            return fileURL(pid, "analysis/thumbs", ph.id + ".jpg")
        }
        return nil
    }

    func aspect(_ ph: PhotoEntry) -> Double {
        guard ph.w > 0, ph.h > 0 else { return 1.5 }
        let c = ph.params.crop
        let w = Double(ph.w) * (c?.w ?? 1), h = Double(ph.h) * (c?.h ?? 1)
        return (w / h * 1000).rounded() / 1000
    }

    func visibleHints(_ ph: PhotoEntry) -> [StudioHint] { Array(ph.hints.prefix(2)) }

    func projectSummary(_ p: ProjectFile) -> [String: Any] {
        let visible = p.photos.filter { !$0.gone }
        let picks = visible.filter { $0.flag == "pick" }
        let cover = picks.first ?? visible.first
        let st = statusDict(p)
        let missing = !FileManager.default.fileExists(atPath: p.folder)
        let (date, dateSource) = projectDate(p)
        return ["id": p.id, "name": p.name, "date": date ?? NSNull(), "dateSource": dateSource, "count": visible.count,
                "picks": picks.count, "favorites": visible.filter { $0.favorite }.count, "edited": visible.filter { $0.edited }.count,
                "cover": cover.flatMap { thumbURL(p.id, $0) } ?? NSNull(),
                "status": st["state"] ?? "ready", "done": st["done"] ?? 0, "total": st["total"] ?? 0,
                "folder": p.folder, "path": p.folder, "source": p.folder, "sourceId": p.sourceId ?? NSNull(), "missing": missing,
                "migrated": p.migratedFrom != nil, "linked": Self.isLinkFolder(p.folder)]
    }

    func sourceDict(_ s: SourceRef) -> [String: Any] {
        ["id": s.id, "path": s.path, "kind": s.kind, "name": URL(fileURLWithPath: s.path).lastPathComponent,
         "missing": !FileManager.default.fileExists(atPath: s.path), "added": s.added,
         "projects": projectsOrdered().filter { $0.sourceId == s.id }.map { $0.id }, "excluded": s.excluded]
    }

    public func libraryJSON() -> [String: Any] {
        sync {
            let ps = projectsOrdered()
            var all = 0, edited = 0
            for p in ps { for ph in p.photos where !ph.gone { all += 1; if ph.edited { edited += 1 } } }
            var analyzing: Any = NSNull()
            if let pid = analysisRunning, let imp = imports[pid] { analyzing = ["projectId": pid, "done": imp.analyzed, "total": imp.total] }
            let dir = (try? exportDir(projectName: nil))?.path
            return [
                "projects": ps.map { projectSummary($0) },
                "collections": lib.collections.map { collectionSummary($0) },
                "projectSort": lib.projectSort,
                "projectOrder": lib.projectSort == "custom" ? ps.map { $0.id } : lib.projectOrder.filter { projects[$0] != nil },
                "sources": lib.sources.map { sourceDict($0) },
                "look": Self.dict(lib.look),
                "lookStats": ["photos": all, "edited": edited],
                "frame": Self.dict(lib.frame),
                "exportRoot": lib.exportRoot,
                "exportDir": dir ?? NSNull(),
                "projectFolders": lib.projectFolders,
                "films": filmsJSON(),
                "engine": ["rawTherapee": rt != nil, "luts": lutRoot != nil,
                           "error": rt == nil ? "RawTherapee isn't installed (/Applications/RawTherapee.app); previews and export are unavailable" as Any : NSNull(),
                           // Analysis waits (rechecking every 30 s, resuming by itself) while free disk < needBytes.
                           "paused": diskWait ? "low-disk" as Any : NSNull(),
                           "freeBytes": Self.freeBytes(cache), "needBytes": Self.minFreeForAnalysis,
                           "waiting": analysisJobs.count],
                "rendering": bgPending.count + firstPending.count,
                "analyzing": analyzing,
                "queued": analysisJobs.map { $0.pid },
                "bestCount": bestItems().count,
                "cacheLimitGB": lib.cacheLimitGB,
                "diskFreeGB": (Double(Self.freeBytes(cache)) / 1e8).rounded() / 10,
                "analysisPaused": diskWait ? "disk nearly full" : NSNull(),
                "catalog": root.path, "cache": cache.path,
            ]
        }
    }

    func lightPhoto(_ pid: String, _ ph: PhotoEntry) -> [String: Any] {
        let hint = ph.hints.first { $0.grid }?.text
        return ["id": ph.id, "file": ph.file, "w": ph.w, "h": ph.h, "aspect": aspect(ph), "time": ph.time ?? NSNull(),
                "thumb": thumbURL(pid, ph) ?? NSNull(), "rating": ph.rating, "flag": ph.flag ?? NSNull(), "favorite": ph.favorite,
                "edited": ph.edited, "burst": ph.burst ?? NSNull(), "best": ph.best, "moment": ph.moment,
                "hint": hint ?? NSNull(), "streetScore": ph.streetScore ?? NSNull(), "version": ph.version,
                "missing": !FileManager.default.fileExists(atPath: ph.path), "analyzed": ph.analyzed,
                "edge": edgePrintResolved(pid, ph)]
    }

    /// Film-edge style caption for the contact sheet, read from the photos' own EXIF: the camera, plus the
    /// film simulation on a Fuji ("FUJIFILM X-PRO3 · CLASSIC NEG"); TIFFs without a camera: "FILM SCAN".
    /// Each photo carries its own (`edge`); the project's is its most common camera and simulation.
    func edgePrint(_ p: ProjectFile) -> String {
        let photos = p.photos.filter { !$0.gone }
        func mostCommon(_ v: [String]) -> String? {
            var c: [String: Int] = [:]
            for x in v where !x.isEmpty { c[x, default: 0] += 1 }
            return c.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        }
        let isTiff = photos.contains { Self.isTiff($0.file) }
        return Self.edgeLabel(camera: mostCommon(photos.compactMap { $0.info["camera"] }),
                              simulation: mostCommon(photos.compactMap { $0.facts?.filmSimulation }), scan: isTiff)
    }

    static func edgePrint(_ ph: PhotoEntry) -> String {
        edgeLabel(camera: ph.info["camera"], simulation: ph.facts?.filmSimulation, scan: isTiff(ph.file))
    }

    /// The edge print for one photo, looking past an export that lost its camera EXIF (Capture One, Lightroom and
    /// others can strip it): 1. the photo's own EXIF; 2. its original, a file with the same name in the same or
    /// the parent folder (e.g. Output/DSCF1171.jpg -> DSCF1171.RAF), read for make, model and Fuji film
    /// simulation, only if it's on disk (never an iCloud placeholder: reading one downloads the whole file);
    /// 3. the most common print among the rest of its project; 4. the camera used most across the library.
    /// A TIFF scan with no camera stays "FILM SCAN". Called inside sync (lightPhoto); originals are read once.
    func edgePrintResolved(_ pid: String, _ ph: PhotoEntry) -> String {
        let own = Self.edgePrint(ph)
        // A film scan names the scanner, not the camera: read the roll folder instead ("Roll 1 - Portra 400 - M6"),
        // else the camera the photographer scans with (settings scanCamera).
        if Self.isScanner(own) { return Self.filmScanEdge(ph.path) ?? lib.scanCamera.map { Self.edgeCamera($0) } ?? "FILM SCAN" }
        if !own.isEmpty, own != "FILM SCAN" { return own }
        let found = originalEdge(ph)
        if !found.isEmpty { return found }
        if own == "FILM SCAN" { return own }
        let project = projectEdgePrint(pid)
        return project.isEmpty ? libraryEdgePrint() : project
    }

    func originalEdge(_ ph: PhotoEntry) -> String {
        if let cached = EdgeCache.shared.originals[ph.path] { return cached }
        let found = Self.edgeFromOriginal(ph.path) ?? ""
        EdgeCache.shared.originals[ph.path] = found
        return found
    }

    /// The most common print among a project's photos that have one of their own or from an on-disk original.
    func projectEdgePrint(_ pid: String) -> String {
        guard let p = projects[pid] else { return "" }
        let photos = p.photos.filter { !$0.gone }
        if let c = EdgeCache.shared.projects[pid], c.count == photos.count { return c.label }
        var n: [String: Int] = [:]
        for ph in photos {
            var l = Self.edgePrint(ph)
            if l.isEmpty || l == "FILM SCAN" { l = originalEdge(ph) }
            if !l.isEmpty { n[l, default: 0] += 1 }
        }
        let label = n.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? ""
        EdgeCache.shared.projects[pid] = (photos.count, label)
        return label
    }

    static func edgeFromOriginal(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path), fm = FileManager.default
        let base = url.deletingPathExtension().lastPathComponent
        let dirs = [url.deletingLastPathComponent(), url.deletingLastPathComponent().deletingLastPathComponent()]
        let exts = ["raf", "dng", "cr3", "cr2", "nef", "arw", "orf", "rw2", "pef", "jpg", "jpeg"]
        for dir in dirs {
            for ext in exts {
                for e in [ext, ext.uppercased()] {
                    let c = dir.appendingPathComponent(base + "." + e)
                    guard c.path.lowercased() != url.path.lowercased(), fm.fileExists(atPath: c.path), !isDataless(c.path),
                          let label = edgeFromFile(c) else { continue }   // case-insensitive: .JPG is the same file
                    return label
                }
            }
        }
        return nil
    }

    /// Edge print from one file's own metadata (make, model; Fuji film simulation from the maker notes, also in a RAF).
    static func edgeFromFile(_ url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return nil }
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let make = (tiff[kCGImagePropertyTIFFMake as String] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel as String] as? String)?.trimmingCharacters(in: .whitespaces)
        let camera = [make, model].compactMap { $0 }.joined(separator: " ")
        guard !camera.isEmpty else { return nil }
        let sim = camera.uppercased().contains("FUJI")
            ? fujiSettings(tags: readFujiMakerNotes(url: url), pictureStyle: nil)?.filmSimulation : nil
        return edgeLabel(camera: camera, simulation: sim == "Unknown" ? nil : sim, scan: false)
    }

    /// For `photolab edge <file>`: what the contact sheet prints for a file, and where it came from.
    public static func edgeReport(path: String) -> String {
        if isDataless(path) { return "\t(an iCloud placeholder: not read, so it isn't downloaded)" }
        if let own = edgeFromFile(URL(fileURLWithPath: path)), isScanner(own) {
            return filmScanEdge(path).map { "\($0)\t(scanned by \(own); camera and film from the roll folder)" } ?? "\(own)\t(a scanner; the app uses settings scanCamera)"
        }
        if let own = edgeFromFile(URL(fileURLWithPath: path)) { return "\(own)\t(own EXIF)" }
        if let orig = edgeFromOriginal(path) { return "\(orig)\t(from the original beside it)" }
        return "\t(no camera in this file or an on-disk original; the app uses its project's most common print, else the library's)"
    }

    /// The most common edge print across every project (photos with their own camera EXIF), recomputed when the
    /// number of photos changes.
    func libraryEdgePrint() -> String {
        let all = projects.values.flatMap { $0.photos.filter { !$0.gone } }
        if let c = EdgeCache.shared.library, c.count == all.count { return c.label }
        var n: [String: Int] = [:]
        for ph in all { let l = Self.edgePrint(ph); if !l.isEmpty, l != "FILM SCAN" { n[l, default: 0] += 1 } }
        let label = n.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? ""
        EdgeCache.shared.library = (all.count, label)
        return label
    }

    /// Film scanners name themselves in EXIF; the camera that took the picture isn't in the file.
    static func isScanner(_ label: String) -> Bool {
        let l = label.uppercased()
        return ["PLUSTEK", "OPTICFILM", "COOLSCAN", "NORITSU", "FRONTIER", "PACIFIC IMAGE", "REFLECTA", "FLEXTIGHT", "IMACON", "EPSON PERFECTION", "EPSON GT-"]
            .contains { l.contains($0) }
    }

    /// Camera and film from a roll folder named like "Roll 1 - Portra 400 - M6" (the folder the file really lives
    /// in, past any link): "LEICA M6 · PORTRA 400". Short camera names a photographer writes are spelled out.
    static func filmScanEdge(_ path: String) -> String? {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let folder = real.deletingLastPathComponent().lastPathComponent
        let parts = folder.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count >= 3, parts[0].lowercased().hasPrefix("roll") else { return nil }
        let camera = parts.last!, film = parts[1..<(parts.count - 1)].joined(separator: " ")
        let known: [String: String] = ["M6": "LEICA M6", "M3": "LEICA M3", "M4": "LEICA M4", "MP": "LEICA MP", "M2": "LEICA M2",
                                       "STYLUS": "OLYMPUS STYLUS", "MJU": "OLYMPUS MJU", "TVS": "CONTAX TVS", "T2": "CONTAX T2"]
        let cam = known[camera.uppercased()] ?? camera.uppercased()
        return film.isEmpty ? cam : "\(cam) · \(film.uppercased())"
    }

    static func isTiff(_ file: String) -> Bool { ["tif", "tiff"].contains((file as NSString).pathExtension.lowercased()) }

    static func edgeLabel(camera: String?, simulation: String?, scan: Bool) -> String {
        guard let cam = camera.map(edgeCamera), !cam.isEmpty else { return scan ? "FILM SCAN" : "" }
        guard let s = simulation?.lowercased(), !s.isEmpty, cam.contains("FUJI") else { return cam }
        let table: [(String, String)] = [
            ("classic neg", "CLASSIC NEG"), ("classic chrome", "CLASSIC CHROME"), ("nostalgic", "NOSTALGIC NEG"),
            ("reala", "REALA ACE"), ("eterna", "ETERNA"), ("bleach", "ETERNA BLEACH BYPASS"), ("acros", "ACROS"),
            ("monochrome", "MONOCHROME"), ("sepia", "SEPIA"), ("pro neg. hi", "PRO NEG HI"), ("pro neg hi", "PRO NEG HI"),
            ("pro neg. std", "PRO NEG STD"), ("pro neg std", "PRO NEG STD"), ("pro neg", "PRO NEG"),
            ("velvia", "VELVIA"), ("vivid", "VELVIA"), ("provia", "PROVIA"), ("standard", "PROVIA"), ("astia", "ASTIA"), ("soft", "ASTIA"),
        ]
        let film = table.first { s.contains($0.0) }?.1 ?? s.uppercased()
        return "\(cam) · \(film)"
    }

    /// EXIF make + model as it would read on a film edge: "Canon Canon EOS R5" -> "CANON EOS R5",
    /// "NIKON CORPORATION NIKON Z 6" -> "NIKON Z 6", "RICOH IMAGING COMPANY, LTD. RICOH GR III" -> "RICOH GR III".
    static func edgeCamera(_ raw: String) -> String {
        let corporate: Set<String> = ["CORPORATION", "CORP", "CO", "LTD", "INC", "IMAGING", "COMPANY", "OPTICAL"]
        var words = raw.uppercased().replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
            .filter { !corporate.contains($0.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
        if words.count > 1, words[0] == words[1] { words.removeFirst() }
        return words.joined(separator: " ")
    }

    public func projectJSON(_ pid: String) throws -> [String: Any] {
        try sync {
            guard let p = projects[pid] else { throw StudioError.notFound("no project \(pid)") }
            let moments: [[String: Any]] = p.moments.map { m in
                ["id": m.id, "time": m.start.map { String($0.dropFirst(11).prefix(5)) } ?? NSNull(), "start": m.start ?? NSNull(), "end": m.end ?? NSNull(), "count": m.count]
            }
            var d = projectSummary(p)
            d["status"] = statusDict(p)
            d["state"] = (statusDict(p)["state"] as? String) ?? "ready"
            d["moments"] = moments
            d["bursts"] = p.bursts
            d["edgePrint"] = edgePrint(p)
            d["photos"] = p.photos.filter { !$0.gone }.map { lightPhoto(pid, $0) }
            return d
        }
    }

    public func photoJSON(_ pid: String, _ id: String) throws -> [String: Any] {
        try sync {
            guard let p = projects[pid], let i = photoIndex(pid, id) else { throw StudioError.notFound("no photo \(id) in \(pid)") }
            let ph = p.photos[i]
            let eng = engine(pid)
            let fm = FileManager.default
            lastOpened[pid] = Date()
            let rendered = ph.rendered && fm.fileExists(atPath: eng.previewURL(ph.ref).path)
            if !rendered && ph.analyzed { enqueueRender(pid, id, upgrade: true, urgent: true) }
            // Previews made from a proxy older than the 2560 px preview size are re-rendered when opened.
            // (Skipped while the disk is nearly full: the upgrade reads the original, maybe from iCloud.)
            if rendered, ph.analyzed, Self.freeBytes(cache) > Self.minFreeForAnalysis, let (w, h) = EditEngine.pixelSize(eng.proxyURL(ph.ref)),
               max(w, h) < min(eng.previewLong, max(ph.w, ph.h)) - 2 {
                enqueueRender(pid, id, upgrade: true)
            }
            var a = auto(ph)
            a.crop = nil
            let preview: Any = rendered ? fileURL(pid, "renders", id + ".jpg", v: ph.version) : fileURL(pid, "proxies", id + ".jpg")
            let hints = visibleHints(ph)
            var out: [String: Any] = [
                "id": ph.id, "projectId": pid, "projectName": p.name, "file": ph.file, "path": ph.path, "w": ph.w, "h": ph.h,
                "aspect": aspect(ph), "time": ph.time ?? NSNull(),
                "params": paramsDict(ph.params, lookAmount: ph.lookAmount),
                "auto": paramsDict(a, lookAmount: ph.lookAmount),
                "reset": paramsDict(auto(ph, amount: 100), lookAmount: 100),
                "preview": preview, "rendered": rendered,
                "previewParams": paramsDict(rendered ? (ph.renderedParams ?? ph.params) : ph.params, lookAmount: ph.lookAmount),
                "previewFull": ph.params.crop != nil ? fileURL(pid, "full", id + ".jpg", v: ph.version) as Any : NSNull(),
                "thumb": thumbURL(pid, ph) ?? NSNull(),
                "original": fileURL(pid, "proxies", id + ".jpg"),
                "proxyW": (EditEngine.pixelSize(eng.proxyURL(ph.ref))?.0 ?? NSNull()) as Any,
                "proxyH": (EditEngine.pixelSize(eng.proxyURL(ph.ref))?.1 ?? NSNull()) as Any,
                "pipeline": pipelineDict(pid, ph),
                "full": fileURL(pid, "fullres", id + ".jpg", v: ph.version),
                "clip": fileURL(pid, "clip", id + ".png", v: ph.version),
                "hints": hints.map { $0.text }, "hintCodes": hints.map { $0.code },
                "notes": ph.notes, "info": ph.info,
                "edited": ph.edited, "rating": ph.rating, "flag": ph.flag ?? NSNull(), "favorite": ph.favorite,
                "version": ph.version, "missing": !fm.fileExists(atPath: ph.path),
                "filmName": ph.params.film.isEmpty ? "None" : filmName(ph.params.film),
                "streetScore": ph.streetScore ?? NSNull(),
                "autoFit": ph.corrections.fit.map { Self.dict($0) } ?? NSNull(),
                "critique": critiqueDict(pid, ph),
                "redGuard": ph.corrections.redGuard,
            ]
            out.merge(aiFields(pid, ph)) { _, new in new }
            return out
        }
    }

    func critiqueDict(_ pid: String, _ ph: PhotoEntry) -> Any {
        guard let c = critique(pid, ph) else { return NSNull() }
        var d = (Self.dict(c) as? [String: Any]) ?? [:]
        d["reference"] = c.reference ?? NSNull()
        d["compare"] = compareLine(pid, ph) ?? NSNull()
        d["cues"] = cues(pid, ph) ?? NSNull()      // null = still being computed; [] = nothing worth noting
        return d
    }

    func collectionItem(_ pid: String, _ p: ProjectFile, _ ph: PhotoEntry) -> [String: Any] {
        var d = lightPhoto(pid, ph)
        d["projectId"] = pid
        d["projectName"] = p.name
        d["projectDate"] = projectDate(p).0 ?? NSNull()
        return d
    }

    public func selectsJSON() -> [String: Any] {
        sync {
            var out: [[String: Any]] = []
            var groups: [[String: Any]] = []
            for p in projectsNewestFirst() {
                let picks = p.photos.filter { !$0.gone && $0.flag == "pick" }
                if picks.isEmpty { continue }
                groups.append(["projectId": p.id, "projectName": p.name, "date": projectDate(p).0 ?? NSNull(), "count": picks.count])
                out += picks.map { withCollections(collectionItem(p.id, p, $0), p.id, $0.id) }
            }
            return ["photos": out, "projects": groups]
        }
    }

    public func bestJSON() -> [String: Any] {
        sync {
            let items = bestItems()
            return ["photos": items.compactMap { r -> [String: Any]? in
                guard let p = projects[r.projectId], let i = photoIndex(r.projectId, r.id) else { return nil }
                return withCollections(collectionItem(r.projectId, p, p.photos[i]), r.projectId, r.id)
            }]
        }
    }

    public var bestRefs: [ItemRef] { sync { bestItems() } }

    public func legacyParamsJSON(_ pid: String, _ id: String) throws -> Data {
        try sync {
            guard let i = photoIndex(pid, id), let ph = projects[pid]?.photos[i] else { throw StudioError.notFound("no photo \(id) in \(pid)") }
            return try Store.pretty.encode(ph.params)
        }
    }

    /// Ids for an export selector: "picks" | "all" | "favorites" | [ids].
    public func exportIds(_ pid: String, _ sel: Any?) throws -> [String] {
        try sync {
            guard let p = projects[pid] else { throw StudioError.notFound("no project \(pid)") }
            let visible = p.photos.filter { !$0.gone }
            if let ids = sel as? [String] { let set = Set(ids); return visible.filter { set.contains($0.id) }.map { $0.id } }
            switch (sel as? String) ?? "picks" {
            case "all": return visible.map { $0.id }
            case "favorites": return visible.filter { $0.favorite }.map { $0.id }
            case "picks": return visible.filter { $0.flag == "pick" }.map { $0.id }
            default: throw StudioError.bad("ids must be a list of photo ids, \"picks\", \"favorites\" or \"all\"")
            }
        }
    }

    public func projectName(_ pid: String) -> String? { sync { projects[pid]?.name } }
    public func projectFolder(_ pid: String) -> String? { sync { projects[pid]?.folder } }
    public func hasPhoto(_ pid: String, _ id: String) -> Bool { sync { photoIndex(pid, id) != nil } }
    public func photoRef(_ pid: String, _ id: String) -> (PhotoRef, Int)? {
        sync { photoIndex(pid, id).flatMap { i in projects[pid].map { ($0.photos[i].ref, $0.photos[i].version) } } }
    }
}

/// Edge prints found on originals (path -> label, "" when none), and the library-wide fallback.
/// Only touched inside Studio's sync, so it needs no lock of its own.
final class EdgeCache {
    static let shared = EdgeCache()
    var originals: [String: String] = [:]
    var projects: [String: (count: Int, label: String)] = [:]
    var library: (count: Int, label: String)? = nil
}
