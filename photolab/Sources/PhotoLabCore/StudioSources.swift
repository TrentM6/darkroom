import CoreServices
import ImageIO
import Foundation

// Connected folders: attach, discover projects, rescan (launch, project open, FSEvents), analyse new
// photos in the background, locate moved folders, and keep the preview cache under its size cap.

struct AnalysisJob {
    var pid: String
    var files: [URL]?      // nil = the project's first, full analysis
    var legacy: URL? = nil // migrate this `photolab analyze` report instead of analysing
    var size: Int = 0      // photos to analyse (for scheduling)
}

/// FSEvents on a set of folders (directory-level events, 2 s latency).
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init?(paths: [String], queue: DispatchQueue, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        guard !paths.isEmpty else { return nil }
        var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        ctx.info = Unmanaged.passUnretained(self).toOpaque()
        let cb: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            me.handler(list)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }
    deinit { stop() }
}

extension Studio {
    static let imageExts: Set<String> = ["jpg", "jpeg", "tif", "tiff"]
    /// Folders never searched for shoots (catalogs, caches, Capture One/Lightroom internals, trash).
    static let skipFolders: Set<String> = ["captureone", "cache", "caches", "trash", "proxies", "thumbnails", "previews", "lightroom", "photolab library"]
    static let skipSuffixes = [".cosessiondb", ".lrdata", ".lrlibrary", ".photoslibrary", ".app", ".lrcat", ".bundle", ".cocatalog"]
    /// Folder names that describe a role, not a shoot: the project takes the parent's name.
    static let genericNames: Set<String> = ["output", "outputs", "capture", "selects", "export", "exports", "jpg", "jpgs", "jpeg", "jpegs", "edits", "processed", "final", "finals"]

    // MARK: Start

    /// Rescans everything, resumes analysis, watches the folders. (The first folder is attached in onboarding.)
    public func start() {
        Thread.detachNewThread { [weak self] in self?.analysisWorker(0) }
        Thread.detachNewThread { [weak self] in self?.analysisWorker(1) }
        // A look set before learning existed (custom) starts pinned: learning never silently replaces it.
        sync { if lib.learned == nil && lib.look != starterLook.clamped(lutRoot: lutRoot) && !lib.lookPinned { lib.lookPinned = true; markDirty("") } }
        scheduleRelearn()
        scanQueue.async { [weak self] in
            guard let self else { return }
            self.rescanAll()
            self.watchFolders()
            self.regenerateMissingThumbs()
            // edited previews lost to an earlier cache eviction come back while the app is idle, if there's room
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) { [weak self] in self?.restoreEvictedPreviews() }
            // cues for everything later and quietly; photos being opened get theirs first
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 90) { [weak self] in self?.sweepCues() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak self] in self?.cacheMaintenance() }
    }

    func rescanAll() {
        let (sids, standalone): ([String], [String]) = sync {
            (lib.sources.map { $0.id }, projects.values.filter { p in p.sourceId == nil || !lib.sources.contains(where: { s in s.id == p.sourceId }) }.map { $0.id })
        }
        for sid in sids { scanSource(sid) }
        for pid in standalone { scanProject(pid) }
        // Photos that never got a render (or lost it to cache eviction) render in the background.
        let missing: [(String, String)] = sync {
            var out: [(String, String)] = []
            for (pid, p) in projects where p.state != "importing" {
                let eng = engine(pid)
                for ph in p.photos where !ph.gone && ph.analyzed && (!ph.rendered || !FileManager.default.fileExists(atPath: eng.thumbURL(ph.ref).path)) {
                    out.append((pid, ph.id))
                }
            }
            return out
        }
        for (pid, id) in missing { enqueueRender(pid, id) }
    }

    // MARK: Attach / detach

    /// Connects a folder. A folder holding images is one project; a folder of shoot folders is a
    /// source whose subfolders become projects. Returns the source and its project ids.
    public func attach(_ rawPath: String) throws -> (source: SourceRef, projects: [String], existing: Bool) {
        let path = (rawPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw StudioError.bad("choose a folder (a full path)") }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { throw StudioError.bad("that folder doesn't exist") }
        for r in [root, cache] where url.path == r.path || url.path.hasPrefix(r.path + "/") || r.path.hasPrefix(url.path + "/") && url.path == "/" {
            throw StudioError.bad("that folder belongs to Baseline Darkroom itself")
        }
        if url.path == "/" || url.path == NSHomeDirectory() { throw StudioError.bad("choose a photo folder, not your whole disk or home folder") }
        guard FileManager.default.isReadableFile(atPath: url.path), (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else {
            throw StudioError.bad("Baseline Darkroom can't read that folder (macOS privacy settings?)")
        }

        // Already connected (as a source, or as a project inside one)?
        if let s = sync({ lib.sources.first { $0.path == url.path } }) {
            scanSource(s.id)
            return (s, sync { projects.values.filter { $0.sourceId == s.id }.map { $0.id } }, true)
        }
        if let p = sync({ projects.values.first { $0.folder == url.path } }), let sid = p.sourceId, let s = sync({ lib.sources.first { $0.id == sid } }) {
            scanProject(p.id)
            return (s, [p.id], true)
        }

        let direct = Self.listImages(url)
        let kind: String
        if !direct.stable.isEmpty || !direct.unstable.isEmpty {
            kind = "folder"
        } else {
            guard !Self.discoverProjects(url).isEmpty else { throw StudioError.bad("no JPEG or TIFF photos in that folder or its subfolders") }
            kind = "source"
        }
        let src = SourceRef(id: "src-" + String(UUID().uuidString.prefix(8)).lowercased(), path: url.path, kind: kind, added: Store.iso())
        sync {
            lib.sources.append(src)
            // Projects already in the catalog under this folder join the new source.
            for (pid, p) in projects where p.folder == url.path || p.folder.hasPrefix(url.path + "/") {
                if let old = p.sourceId, let i = lib.sources.firstIndex(where: { $0.id == old }), lib.sources[i].kind == "folder", lib.sources[i].id != src.id {
                    lib.sources.remove(at: i)
                }
                projects[pid]!.sourceId = src.id
                if let i = lib.projects.firstIndex(where: { $0.id == pid }) { lib.projects[i].sourceId = src.id }
                markDirty(pid)
            }
            markDirty("")
        }
        log("connected \(url.path) (\(kind))")
        scanSource(src.id)
        watchFolders()
        let ids = sync { projects.values.filter { $0.sourceId == src.id }.sorted { $0.folder < $1.folder }.map { $0.id } }
        return (src, ids, false)
    }

    /// Disconnects a source: its projects leave the catalog (edits included; catalog files are kept
    /// aside in projects/.removed/), caches are deleted. Originals are never touched.
    public func detachSource(_ sid: String) throws {
        let pids: [String] = try sync {
            guard lib.sources.contains(where: { $0.id == sid }) else { throw StudioError.notFound("no source \(sid)") }
            let ids = projects.values.filter { $0.sourceId == sid }.map { $0.id }
            for pid in ids {
                imports[pid]?.cancelled = true
                analysisJobs.removeAll { $0.pid == pid }
                projects[pid] = nil; index[pid] = nil
                lib.projects.removeAll { $0.id == pid }
                lib.bestOrder.removeAll { $0.projectId == pid }
                lib.projectOrder.removeAll { $0 == pid }
                dirty.remove(pid)
            }
            lib.sources.removeAll { $0.id == sid }
            markDirty("")
            return ids
        }
        for pid in pids { discardFiles(pid) }
        scheduleRelearn()
        flush()
        watchFolders()
    }

    // MARK: Discovery

    static func listImages(_ dir: URL) -> (stable: [URL], unstable: [URL]) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return ([], []) }
        var stable: [URL] = [], unstable: [URL] = []
        let cutoff = Date().addingTimeInterval(-3)
        for u in items where imageExts.contains(u.pathExtension.lowercased()) {
            var v = try? u.resourceValues(forKeys: Set(keys))
            // A link (e.g. a folder of links to scans on another drive) counts when it points at an image file;
            // a broken link, or one to a folder, is skipped. The photo keeps the link's path.
            if v?.isRegularFile != true, (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                v = try? u.resolvingSymlinksInPath().resourceValues(forKeys: Set(keys))
            }
            guard v?.isRegularFile == true else { continue }
            if let m = v?.contentModificationDate, m > cutoff { unstable.append(u) } else { stable.append(u) }
        }
        return (stable.sorted { $0.lastPathComponent < $1.lastPathComponent }, unstable)
    }

    /// Folders under `root` that hold images directly (not searching inside a project folder).
    static func discoverProjects(_ root: URL, depth: Int = 4) -> [URL] {
        var out: [URL] = []
        func walk(_ d: URL, _ level: Int) {
            guard level <= depth else { return }
            // (no isPackageKey: it can consult LaunchServices, which may wait on the main thread)
            guard let subs = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for s in subs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let v = try? s.resourceValues(forKeys: [.isDirectoryKey])
                guard v?.isDirectory == true else { continue }
                let n = s.lastPathComponent.lowercased()
                if skipFolders.contains(n) || n.hasPrefix("settings") || skipSuffixes.contains(where: { n.hasSuffix($0) }) { continue }
                let imgs = listImages(s)
                if !imgs.stable.isEmpty || !imgs.unstable.isEmpty { out.append(s.standardizedFileURL) } else { walk(s, level + 1) }
            }
        }
        walk(root, 1)
        return out
    }

    static func projectName(_ folder: URL) -> String {
        var name = folder.lastPathComponent.trimmingCharacters(in: .whitespaces)
        if genericNames.contains(name.lowercased()) {
            name = folder.deletingLastPathComponent().lastPathComponent.trimmingCharacters(in: .whitespaces)
        }
        return name.isEmpty ? "Shoot" : name
    }

    // MARK: Scanning

    func scheduleScan(_ key: String, after: Double = 2) {
        let fresh: Bool = sync { scanScheduled.insert(key).inserted }
        guard fresh else { return }
        scanQueue.asyncAfter(deadline: .now() + after) { [weak self] in
            guard let self else { return }
            _ = self.sync { self.scanScheduled.remove(key) }
            if key.hasPrefix("s:") { self.scanSource(String(key.dropFirst(2))) } else { self.scanProject(String(key.dropFirst(2))) }
        }
    }

    func scanSource(_ sid: String) {
        guard let src = sync({ lib.sources.first { $0.id == sid } }) else { return }
        let url = URL(fileURLWithPath: src.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }   // shown as missing
        let folders: [URL] = src.kind == "folder" ? [url] : Self.discoverProjects(url)
        for f in folders {
            let path = f.path
            if let pid = sync({ projects.values.first { $0.folder == path }?.id }) { scanProject(pid); continue }
            if src.excluded.contains(path) { continue }
            // A missing project of this source with the same files = the folder was renamed or moved.
            if let pid = relinkCandidate(sid, f) {
                log("\(path) looks like the moved folder of \(pid); relinking")
                try? locate(pid, path)
                continue
            }
            createProject(f, sourceId: sid)
        }
    }

    func relinkCandidate(_ sid: String, _ folder: URL) -> String? {
        let names = Set((Self.listImages(folder).stable + Self.listImages(folder).unstable).map { $0.lastPathComponent })
        guard !names.isEmpty else { return nil }
        return sync {
            projects.values.filter { $0.sourceId == sid && !FileManager.default.fileExists(atPath: $0.folder) }
                .first { p in
                    let known = Set(p.photos.map { $0.file })
                    let common = known.intersection(names).count
                    return common > 0 && Double(common) >= 0.6 * Double(max(known.count, 1))
                }?.id
        }
    }

    @discardableResult
    func createProject(_ folder: URL, sourceId: String?) -> String {
        let name = Self.projectName(folder)
        let n = Self.listImages(folder).stable.count
        let pid: String = sync {
            let id = newProjectId(name)
            var p = ProjectFile(id: id, name: name, folder: folder.path, sourceId: sourceId, created: Store.iso())
            p.state = "importing"
            projects[id] = p
            reindex(id)
            lib.projects.insert(ProjectRef(id: id, name: name, folder: folder.path, sourceId: sourceId, created: p.created), at: 0)
            if !lib.projectOrder.isEmpty { lib.projectOrder.insert(id, at: 0) }   // new projects go on top
            imports[id] = ImportProgress(total: n)
            markDirty(id); markDirty("")
            return id
        }
        log("new project \(pid): \(folder.path) (\(n) photos)")
        if let legacy = Self.findLegacyReport(for: folder) {
            queueAnalysis(AnalysisJob(pid: pid, files: nil, legacy: legacy, size: n), front: true)
        } else {
            placeholderQueue.async { [weak self] in self?.addPlaceholders(pid, Self.listImages(folder).stable) }
            queueAnalysis(AnalysisJob(pid: pid, files: nil, size: n), front: true)
        }
        return pid
    }

    /// Compares the folder with the project: new photos are analysed in the background, removed ones
    /// disappear (their edits are kept in case they come back).
    public func scanProject(_ pid: String) {
        guard let (folder, state) = sync({ projects[pid].map { ($0.folder, $0.state) } }) else { return }
        let url = URL(fileURLWithPath: folder)
        guard FileManager.default.fileExists(atPath: folder) else { return }
        sync { lastScan[pid] = Date() }
        let (stable, unstable) = Self.listImages(url)
        if !unstable.isEmpty { scheduleScan("p:" + pid, after: 5) }
        let present = Set((stable + unstable).map { $0.lastPathComponent })
        var newFiles: [URL] = []
        sync {
            guard projects[pid] != nil else { return }
            var changed = false
            for i in projects[pid]!.photos.indices {
                let ph = projects[pid]!.photos[i]
                let isGone = !present.contains(ph.file)
                if ph.gone != isGone { projects[pid]!.photos[i].gone = isGone; changed = true }
                if !isGone && ph.path != url.appendingPathComponent(ph.file).path {
                    projects[pid]!.photos[i].path = url.appendingPathComponent(ph.file).path; changed = true
                }
                // Photos analysed before sizes were recorded: take the current file as the analysed one.
                if !isGone && ph.analyzed && ph.fileSize == nil, let st = Self.fileStat(projects[pid]!.photos[i].path) {
                    projects[pid]!.photos[i].fileSize = st.size; projects[pid]!.photos[i].fileMtime = st.mtime; changed = true
                }
            }
            if changed { markDirty(pid) }
            if state == "importing" {
                // first analysis not finished (e.g. the app quit): make sure it's queued
                if !runningAnalyses.contains(pid) && !analysisJobs.contains(where: { $0.pid == pid }) {
                    analysisJobs.insert(AnalysisJob(pid: pid, files: nil, size: stable.count), at: 0); analysisSignal.signal(); analysisSignal.signal()
                }
                return
            }
            var known: [String: PhotoEntry] = [:]
            for ph in projects[pid]!.photos where ph.analyzed { known[ph.file] = ph }
            let busy = runningAnalyses.contains(pid) || analysisJobs.contains { $0.pid == pid }
            if !busy {
                let unreadable = projects[pid]!.unreadable ?? [:]
                let now = Date().timeIntervalSince1970
                newFiles = stable.filter { u in
                    let st = Self.fileStat(u.path)
                    if let ph = known[u.lastPathComponent] {
                        // changed since it was analysed (e.g. re-exported, or was half-written)
                        guard let size = ph.fileSize, let m = ph.fileMtime, let st else { return false }
                        return st.size != size || abs(st.mtime - m) > 0.5
                    }
                    if let bad = unreadable[u.lastPathComponent], let st, st.size == bad.size, abs(st.mtime - bad.mtime) < 0.5 {
                        return now >= bad.next
                    }
                    return true
                }
            }
        }
        if !newFiles.isEmpty {
            log("\(pid): \(newFiles.count) new or changed photo(s) in \(folder)")
            let files = newFiles
            placeholderQueue.async { [weak self] in self?.addPlaceholders(pid, files) }
            queueAnalysis(AnalysisJob(pid: pid, files: newFiles), front: true)
        }
    }

    /// Called when the UI opens a project: rescan (at most every 10 s) and analyse it first.
    func projectOpened(_ pid: String) {
        let due: Bool = sync {
            lastOpened[pid] = Date()
            if let i = analysisJobs.firstIndex(where: { $0.pid == pid }), i > 0 { analysisJobs.insert(analysisJobs.remove(at: i), at: 0) }
            return Date().timeIntervalSince(lastScan[pid] ?? .distantPast) > 10
        }
        if due { scanQueue.async { [weak self] in self?.scanProject(pid) } }
    }

    // MARK: Locate

    /// Re-points a project whose folder moved. Edits, marks and analysis are kept.
    public func locate(_ pid: String, _ rawPath: String) throws {
        let path = (rawPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { throw StudioError.bad("that folder doesn't exist") }
        let names = Set((Self.listImages(url).stable + Self.listImages(url).unstable).map { $0.lastPathComponent })
        try sync {
            guard var p = projects[pid] else { throw StudioError.notFound("no project \(pid)") }
            if let other = projects.values.first(where: { $0.folder == url.path && $0.id != pid }) {
                throw StudioError.bad("that folder is already the project \(other.name)")
            }
            let known = Set(p.photos.map { $0.file })
            if !known.isEmpty && known.intersection(names).isEmpty { throw StudioError.bad("none of this project's photos are in that folder") }
            p.folder = url.path
            for i in p.photos.indices { p.photos[i].path = url.appendingPathComponent(p.photos[i].file).path }
            if let sid = p.sourceId, let si = lib.sources.firstIndex(where: { $0.id == sid }), lib.sources[si].kind == "folder" {
                lib.sources[si].path = url.path
            }
            projects[pid] = p
            if let i = lib.projects.firstIndex(where: { $0.id == pid }) { lib.projects[i].folder = url.path }
            markDirty(pid); markDirty("")
        }
        log("\(pid) now points at \(url.path)")
        scanQueue.async { [weak self] in self?.scanProject(pid) }
        watchFolders()
    }

    // MARK: FSEvents

    func watchFolders() {
        let paths: [String] = sync {
            var set = Set(lib.sources.map { $0.path })
            for p in projects.values where !set.contains(where: { p.folder == $0 || p.folder.hasPrefix($0 + "/") }) { set.insert(p.folder) }
            return set.filter { FileManager.default.fileExists(atPath: $0) }.sorted()
        }
        // Events arrive on their own queue (never the scan queue, which may be busy for a while) and are
        // handed to the scan queue asynchronously.
        let w = FolderWatcher(paths: paths, queue: watchQueue) { [weak self] changed in
            self?.scanQueue.async { self?.foldersChanged(changed) }
        }
        sync { watcher?.stop(); watcher = w }
    }

    func foldersChanged(_ changed: [String]) {
        let (ps, ss): ([(String, String)], [SourceRef]) = sync { (projects.values.map { ($0.id, $0.folder) }, lib.sources) }
        for raw in changed {
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            var inProject = false
            for (pid, folder) in ps where path == folder || path.hasPrefix(folder + "/") || folder.hasPrefix(path + "/") {
                scheduleScan("p:" + pid); inProject = inProject || path == folder || path.hasPrefix(folder + "/")
            }
            if !inProject {
                for s in ss where path == s.path || path.hasPrefix(s.path + "/") || s.path.hasPrefix(path + "/") { scheduleScan("s:" + s.id) }
            }
        }
    }

    // MARK: Analysis queue (one project at a time, 3 photos in parallel)

    /// Priority: new shoots and new photos go first (`front`); re-analysis of a whole project last.
    func queueAnalysis(_ job: AnalysisJob, front: Bool = false) {
        var job = job
        if job.size == 0 {
            job.size = job.files?.count ?? sync({ projects[job.pid]?.folder }).map { Self.listImages(URL(fileURLWithPath: $0)).stable.count } ?? 0
        }
        sync {
            if let i = analysisJobs.firstIndex(where: { $0.pid == job.pid }) {
                // merge into the queued job
                if analysisJobs[i].legacy != nil { return }
                if job.files == nil { analysisJobs[i].files = nil }
                else if let f = analysisJobs[i].files { analysisJobs[i].files = Array(Set(f + job.files!)) }
                return
            }
            if front { analysisJobs.insert(job, at: 0) } else { analysisJobs.append(job) }
        }
        analysisSignal.signal(); analysisSignal.signal()
    }

    /// Jobs of at most this many photos can run on the second worker, next to a big analysis, so a
    /// small new shoot becomes cullable within seconds.
    static let smallJob = 40

    /// Two workers share the queue: worker 0 takes any job, worker 1 only small ones.
    func analysisWorker(_ worker: Int = 0) {
        while true {
            _ = analysisSignal.wait(timeout: .now() + 30)
            while sync({ analysisJobs.contains { worker == 0 || $0.size <= Self.smallJob } }) {
                // Analysis reads (and may download from iCloud) the originals: wait while the disk is nearly full.
                if Self.freeBytes(cache) < Self.minFreeForAnalysis {
                    if !sync({ diskWait }) { log("disk nearly full (\(Self.freeBytes(cache) / 1_000_000) MB free): analysis paused until \(Self.minFreeForAnalysis / 1_000_000_000) GB is free") }
                    sync { diskWait = true }
                    Thread.sleep(forTimeInterval: 30)
                    continue
                }
                if sync({ diskWait }) { log("disk space is back (\(Self.freeBytes(cache) / 1_000_000) MB free): analysis resumes") }
                sync { diskWait = false }
                guard let job: AnalysisJob = sync({ () -> AnalysisJob? in
                    guard let i = analysisJobs.firstIndex(where: { (worker == 0 || $0.size <= Self.smallJob) && !runningAnalyses.contains($0.pid) }) else { return nil }
                    let j = analysisJobs.remove(at: i)
                    runningAnalyses.insert(j.pid)
                    bgQueue.isSuspended = true      // re-renders of existing photos wait while shoots are analysed
                    return j
                }) else { break }
                autoreleasepool { runAnalysis(job) }
                sync {
                    runningAnalyses.remove(job.pid)
                    if runningAnalyses.isEmpty && analysisJobs.isEmpty { bgQueue.isSuspended = false }
                }
            }
            sync { if runningAnalyses.isEmpty && analysisJobs.isEmpty { bgQueue.isSuspended = false } }
            // Queue emptied (e.g. the waiting project was removed): no longer paused.
            if worker == 0 {
                if sync({ diskWait && analysisJobs.isEmpty }) { log("analysis queue empty; no longer waiting for disk space") }
                sync { if analysisJobs.isEmpty { diskWait = false } }
            }
        }
    }

    /// Free disk needed for analysis (default 2 GB; $PHOTOLAB_MIN_FREE_BYTES overrides, for testing).
    static var minFreeForAnalysis: Int64 {
        ProcessInfo.processInfo.environment["PHOTOLAB_MIN_FREE_BYTES"].flatMap { Int64($0) } ?? 2_000_000_000
    }

    /// Free space now. (A fresh URL each time: URL caches resource values, so reusing one would keep
    /// returning the first sample.)
    static func freeBytes(_ u: URL) -> Int64 {
        let fresh = URL(fileURLWithPath: u.path)
        let v = try? fresh.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? Int64(v?.volumeAvailableCapacity ?? Int.max)
    }

    /// iCloud "dataless" placeholder (content not on this Mac)?
    static func isDataless(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_flags & 0x40000000) != 0   // SF_DATALESS
    }

    /// After Baseline Darkroom had to download an iCloud original (analysis, proxy, export), give the space back:
    /// the file returns to the cloud-only state it was in. Content is never changed.
    /// Not done for originals downloaded for an export within the last hour (likely needed again), nor
    /// with $PHOTOLAB_NO_EVICT (tests). Failures are logged once per folder.
    func releaseDownloaded(_ path: String, wasDataless: Bool) {
        guard wasDataless, ProcessInfo.processInfo.environment["PHOTOLAB_NO_EVICT"] == nil else { return }
        if let t = sync({ exportDownloads[path] }), Date().timeIntervalSince(t) < 3600 { return }
        do { try FileManager.default.evictUbiquitousItem(at: URL(fileURLWithPath: path)) } catch {
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
            let first: Bool = sync { evictionFailures.insert(folder).inserted }
            if first { log("could not return some originals in \(folder) to iCloud-only (\(error.localizedDescription)); they stay downloaded") }
        }
    }

    /// The proxy (1600 px render input), downloading the original only if needed.
    /// `upgrade`: replace a proxy smaller than the current preview size (needs the original). Without it
    /// an existing proxy is reused as is (background renders don't download every original again).
    @discardableResult
    func ensureProxy(_ pid: String, _ ref: PhotoRef, upgrade: Bool = true) -> URL? {
        let eng = engine(pid)
        let dl = Self.isDataless(ref.path)
        let u = eng.ensureProxy(ref, upgrade: upgrade)
        releaseDownloaded(ref.path, wasDataless: dl && !Self.isDataless(ref.path))
        return u
    }

    func runAnalysis(_ job: AnalysisJob) {
        if let legacy = job.legacy {
            do {
                try migrateLegacy(reportDir: legacy, into: job.pid)
                scanProject(job.pid)
                return
            } catch {
                log("migration of \(legacy.path) failed (\(error)); analyzing instead")
            }
        }
        guard let folder = sync({ projects[job.pid]?.folder }) else { return }
        let url = URL(fileURLWithPath: folder)
        guard FileManager.default.fileExists(atPath: folder) else { return }
        let files = job.files ?? Self.listImages(url).stable
        guard !files.isEmpty else {
            if job.files == nil { scheduleScan("p:" + job.pid, after: 5) }   // folder still being copied
            return
        }
        let full = job.files == nil
        sync {
            var prog = imports[job.pid] ?? ImportProgress()
            prog.total = files.count; prog.analyzed = 0; prog.failed = 0; prog.finished = false; prog.error = nil
            imports[job.pid] = prog
        }
        var opt = RunOptions(input: url, output: projectDir(job.pid).appendingPathComponent("analysis"), jobs: 3)
        opt.files = files
        let dataless = Set(files.map { $0.path }.filter { Self.isDataless($0) })
        opt.onPhoto = { [weak self] done, total, report in
            guard let self else { return }
            let cancelled: Bool = self.sync {
                self.imports[job.pid]?.total = total
                self.imports[job.pid]?.analyzed = done
                if report == nil { self.imports[job.pid]?.failed += 1 }
                return (self.imports[job.pid]?.cancelled ?? true) || self.projects[job.pid] == nil
            }
            if !cancelled, let r = report {
                // Make the proxy while the original is on disk, then give iCloud's space back.
                _ = self.engine(job.pid).ensureProxy(r.ref)
                self.releaseDownloaded(r.path, wasDataless: dataless.contains(r.path))
                // The analysis' 2048 px preview and clip overlay aren't used by the studio (the proxy and
                // the edited render are): free the space right away.
                let a = self.projectDir(job.pid).appendingPathComponent("analysis")
                try? FileManager.default.removeItem(at: a.appendingPathComponent("previews/\(r.id).jpg"))
                try? FileManager.default.removeItem(at: a.appendingPathComponent("overlays/\(r.id)-clip.png"))
                self.addAnalyzed(job.pid, r)
            }
        }
        let t0 = Date()
        do {
            let shoot = try runShoot(opt, log: { _ in })
            if sync({ projects[job.pid] == nil }) { return }
            finishAnalysis(job.pid, shoot, full: full)
            noteUnreadable(job.pid, tried: files, analyzed: Set(shoot.photos.map { $0.file }))
            log(String(format: "%@: analyzed %d photo(s) in %.0fs", job.pid, shoot.photos.count, Date().timeIntervalSince(t0)))
        } catch {
            sync {
                imports[job.pid]?.error = "\(error)"
                if full { projects[job.pid]?.state = "error"; projects[job.pid]?.error = "\(error)" }
                markDirty(job.pid)
            }
            log("analysis of \(job.pid) failed: \(error)")
        }
        sync { imports[job.pid]?.finished = true }
    }

    static func fileStat(_ path: String) -> (size: Int64, mtime: Double)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (a[.size] as? NSNumber)?.int64Value, let m = a[.modificationDate] as? Date else { return nil }
        return (size, m.timeIntervalSince1970)
    }

    /// Files analysis couldn't read get exponential backoff; files that now worked leave the list.
    func noteUnreadable(_ pid: String, tried: [URL], analyzed: Set<String>) {
        sync {
            guard projects[pid] != nil else { return }
            var u = projects[pid]!.unreadable ?? [:]
            let now = Date().timeIntervalSince1970
            var newlyBad: [String] = []
            for f in tried {
                let name = f.lastPathComponent
                if analyzed.contains(name) { u[name] = nil; continue }
                let st = Self.fileStat(f.path) ?? (0, 0)
                let attempts = (u[name]?.attempts ?? 0) + 1
                u[name] = UnreadableFile(attempts: attempts, next: now + min(86400, 60 * pow(2, Double(attempts - 1))), size: st.size, mtime: st.mtime)
                newlyBad.append(name)
            }
            projects[pid]!.unreadable = u.isEmpty ? nil : u
            markDirty(pid)
            if !newlyBad.isEmpty { log("\(pid): couldn't read \(newlyBad.joined(separator: ", ")); will retry later") }
        }
    }

    /// New photos are shown (and can be picked/rejected) right away, before analysis: size and capture
    /// time from the header and a quick 480 px unedited thumbnail. Analysis then fills them in, keeping marks.
    func addPlaceholders(_ pid: String, _ files: [URL]) {
        let thumbs = projectDir(pid).appendingPathComponent("analysis/thumbs")
        try? FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        for f in files {
            let id = f.deletingPathExtension().lastPathComponent
            if sync({ photoIndex(pid, id) != nil }) { continue }
            guard let src = CGImageSourceCreateWithURL(f as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { continue }
            var w = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
            if let o = props[kCGImagePropertyOrientation as String] as? Int, (5...8).contains(o) { swap(&w, &h) }
            let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
            let dto = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String
            if let img = Pixels.load(src, maxPixel: 480) { Pixels.writeJPEG(img, to: thumbs.appendingPathComponent(id + ".jpg"), quality: 0.8) }
            sync {
                guard projects[pid] != nil, photoIndex(pid, id) == nil else { return }
                var e = PhotoEntry(id: id, file: f.lastPathComponent, path: f.path, w: w, h: h)
                e.analyzed = false
                if let dto { e.time = Self.isoFromExif(dto) }
                if let t = e.time, let d = ISO8601DateFormatter.local.date(from: t) { e.timestamp = d.timeIntervalSince1970 }
                e.moment = nearestMoment(pid, e.timestamp) ?? ((projects[pid]!.photos.map { $0.moment }.max() ?? -1) + 1)
                recompute(&e)
                projects[pid]!.photos.append(e)
                sortPhotos(pid)
                markDirty(pid)
            }
        }
    }

    func entry(from r: PhotoReport, keeping old: PhotoEntry?) -> PhotoEntry {
        var e = old ?? PhotoEntry(id: r.id, file: r.file, path: r.path, w: r.width, h: r.height)
        e.file = r.file; e.path = r.path; e.w = r.width; e.h = r.height
        e.time = StudioAnalysis.isoTime(r)
        e.timestamp = r.capture.timestamp
        let f = StudioAnalysis.facts(r)
        e.facts = f
        e.corrections = StudioLook.corrections(f)
        e.corrections.redGuard = old?.corrections.redGuard ?? 0     // measured on renders; survive re-analysis
        e.corrections.fit = old?.corrections.fit
        e.hints = StudioAnalysis.hints(r)
        e.critiqueContext = StudioCritique.context(r)
        e.cueTags = r.scene.tags.filter { $0.confidence >= 0.3 }.map { $0.label.lowercased() }
        if old?.cuesVersion != nil { e.cues = nil; e.cuesVersion = nil }    // re-analysed: cues recomputed
        e.notes = StudioAnalysis.notes(r)
        e.streetScore = StudioAnalysis.streetScore(r)
        e.techScore = StudioAnalysis.techScore(r)
        e.info = StudioAnalysis.info(r)
        e.analyzed = true
        e.gone = false
        if old?.analyzed == false { e.moment = old!.moment }
        if let st = Self.fileStat(r.path) { e.fileSize = st.size; e.fileMtime = st.mtime }
        return e
    }

    func sortPhotos(_ pid: String) {
        projects[pid]?.photos.sort { ($0.timestamp ?? 0, $0.file) < ($1.timestamp ?? 0, $1.file) }
        reindex(pid)
    }

    /// One photo analyzed: it is visible right away (unedited analysis thumbnail until its render lands).
    func addAnalyzed(_ pid: String, _ r: PhotoReport) {
        sync {
            guard projects[pid] != nil else { return }
            let old = photoIndex(pid, r.id).map { projects[pid]!.photos[$0] }
            var e = entry(from: r, keeping: old)
            if old == nil {
                // provisional moment until the batch is grouped: nearest earlier photo within 5 minutes
                e.moment = nearestMoment(pid, e.timestamp) ?? ((projects[pid]!.photos.map { $0.moment }.max() ?? -1) + 1)
            }
            if e.edited { freeze(&e) } else { recompute(&e) }
            if let i = photoIndex(pid, r.id) { projects[pid]!.photos[i] = e } else { projects[pid]!.photos.append(e) }
            sortPhotos(pid)
            markDirty(pid)
        }
        enqueueRender(pid, r.id)
    }

    func nearestMoment(_ pid: String, _ t: Double?, excluding: Set<String> = []) -> Int? {
        guard let t else { return nil }
        let near = projects[pid]?.photos.filter { !excluding.contains($0.id) && $0.timestamp != nil && abs($0.timestamp! - t) <= 300 }
            .min { abs($0.timestamp! - t) < abs($1.timestamp! - t) }
        return near?.moment
    }

    /// After a batch: bursts/moments/ranks from the batch's grouping, then the project consistency pass.
    func finishAnalysis(_ pid: String, _ shoot: ShootReport, full: Bool) {
        var toRender: [String] = []
        sync {
            guard var p = projects[pid] else { return }
            let batch = Set(shoot.photos.map { $0.id })
            var byId: [String: Int] = [:]
            for (i, ph) in p.photos.enumerated() { byId[ph.id] = i }
            let burstOffset = full ? 0 : ((p.photos.filter { !batch.contains($0.id) }.compactMap { $0.burst }.max() ?? -1) + 1)
            var momentMap: [Int: Int] = [:]
            var nextMoment = full ? 0 : ((p.photos.filter { !batch.contains($0.id) }.map { $0.moment }.max() ?? -1) + 1)
            projects[pid] = p
            for r in shoot.photos {
                let old = byId[r.id].map { p.photos[$0] }
                var e = entry(from: r, keeping: old)
                e.burst = r.burstId.map { $0 + burstOffset }
                e.best = r.bestInBurst
                if full {
                    e.moment = r.groupId
                } else if let m = momentMap[r.groupId] {
                    e.moment = m
                } else {
                    let m = nearestMoment(pid, e.timestamp, excluding: batch) ?? { nextMoment += 1; return nextMoment - 1 }()
                    momentMap[r.groupId] = m
                    e.moment = m
                }
                if let i = byId[r.id] { p.photos[i] = e } else { byId[r.id] = p.photos.count; p.photos.append(e) }
            }
            // Photos whose analysis failed stay out; known-but-unanalysed entries are dropped in a full pass.
            if full { p.photos.removeAll { !batch.contains($0.id) && !$0.edited && $0.rating == 0 && $0.flag == nil } }
            var cs = p.photos.map { $0.corrections }
            StudioLook.projectPass(&cs)
            for i in p.photos.indices {
                let before = p.photos[i].params
                p.photos[i].corrections = cs[i]
                if p.photos[i].edited { freeze(&p.photos[i]) } else { recompute(&p.photos[i]) }
                if p.photos[i].params != before || !p.photos[i].rendered || (!full && batch.contains(p.photos[i].id)) { toRender.append(p.photos[i].id) }
            }
            p.state = "ready"
            p.error = nil
            p.hintsVersion = StudioAnalysis.hintsVersion
            p.critiqueVersion = StudioCritique.version
            projects[pid] = p
            sortPhotos(pid)
            rebuildMoments(pid)
            markDirty(pid)
        }
        // Full analysis on disk (compact JSON in the catalog).
        var all = shoot
        if !full, var existing = Store.read(ShootReport.self, from: analysisURL(pid)) {
            let ids = Set(shoot.photos.map { $0.id })
            existing.photos = existing.photos.filter { !ids.contains($0.id) } + shoot.photos
            existing.photoCount = existing.photos.count
            existing.groups += shoot.groups
            all = existing
        }
        all.photos = all.photos.map { var x = $0; x.tone.histogram = Histograms(r: [], g: [], b: [], l: []); return x }
        do { try Store.write(all, to: analysisURL(pid)) } catch { log("could not save the analysis of \(pid): \(error)") }
        // New and changed photos render ahead of library re-renders.
        let batch = Set(shoot.photos.map { $0.id })
        for id in toRender { enqueueRender(pid, id, urgent: batch.contains(id)) }
    }

    func rebuildMoments(_ pid: String) {
        guard var p = projects[pid] else { return }
        var groups: [Int: [PhotoEntry]] = [:]
        for ph in p.photos where !ph.gone { groups[ph.moment, default: []].append(ph) }
        p.moments = groups.keys.sorted().map { k in
            let times = groups[k]!.compactMap { $0.time }.sorted()
            return MomentEntry(id: k, start: times.first, end: times.last, count: groups[k]!.count)
        }
        var bursts: [Int: [String]] = [:]
        for ph in p.photos where !ph.gone { if let b = ph.burst { bursts[b, default: []].append(ph.id) } }
        p.bursts = bursts.keys.sorted().map { bursts[$0]! }
        p.date = p.photos.compactMap { $0.time }.min().map { String($0.prefix(10)) }
        projects[pid] = p
    }

    // MARK: Legacy reports (photolab analyze) -> migration

    /// A `photolab analyze` report of this folder, if one exists in a known reports folder
    /// ($PHOTOLAB_REPORTS, colon-separated, then ~/Desktop/PhotoLab/reports).
    /// (Read once per process: the reports may sit in iCloud, and each report.json is large.)
    static func findLegacyReport(for folder: URL) -> URL? {
        let target = folder.standardizedFileURL.resolvingSymlinksInPath().path
        legacyLock.lock(); defer { legacyLock.unlock() }
        if legacyReports == nil {
            var dirs = (ProcessInfo.processInfo.environment["PHOTOLAB_REPORTS"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            dirs.append(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/PhotoLab/reports"))
            struct Head: Decodable { var sourcePath: String }
            var found: [String: URL] = [:]
            for d in dirs {
                guard let subs = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for s in subs {
                    let rj = s.appendingPathComponent("report.json")
                    guard FileManager.default.fileExists(atPath: rj.path), let h = Store.read(Head.self, from: rj) else { continue }
                    found[URL(fileURLWithPath: h.sourcePath).standardizedFileURL.resolvingSymlinksInPath().path] = s
                }
            }
            legacyReports = found
        }
        return legacyReports?[target]
    }
    nonisolated(unsafe) static var legacyReports: [String: URL]? = nil
    static let legacyLock = NSLock()

    // MARK: Cache

    public var cacheBytes: Int64 { Self.folderSize(cache) }

    static func folderSize(_ u: URL) -> Int64 {
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileAllocatedSizeKey, .isRegularFileKey])
        while let f = e?.nextObject() as? URL {
            let v = try? f.resourceValues(forKeys: [.fileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileAllocatedSize ?? 0) }
        }
        return total
    }

    /// Marks a cached file as used (LRU by modification date; touched at most every 5 minutes).
    func touchCached(_ url: URL) {
        let fm = FileManager.default
        guard let m = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, Date().timeIntervalSince(m) > 300 else { return }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    // Cache policy. Thumbnails (thumbs/, analysis/thumbs/) and sidecars are never evicted. Eviction starts
    // only when free disk < 1.5 GB, frees until free >= 2.0 GB (hysteresis), then waits at least 10 min.
    // Never evicted: the open project (opened in the last 30 min) and any file used in the last 30 min.
    // Order: least recently opened projects first; full-size and zoom renders, then sized proxies, previews,
    // proxies. The cache never goes below 1.5 GB unless the disk is nearly full (< 750 MB free).
    static let keepFreeBytes: Int64 = 1_500_000_000
    static let evictHysteresis: Int64 = 500_000_000
    static let cacheFloor: Int64 = 1_500_000_000
    static let emergencyFree: Int64 = 750_000_000
    static let protectSeconds: TimeInterval = 1800

    /// Every 30 s: free-space check (cheap); eviction only per the policy above.
    func cacheMaintenance() {
        let free = Self.freeBytes(cache)
        let held = Date() < sync { evictionHold }
        if (free < Self.keepFreeBytes && !held) || free < Self.emergencyFree { evictCache() }
        else if Date().timeIntervalSince(lastEviction) > 600 && !held { evictCache(capOnly: true) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak self] in self?.cacheMaintenance() }
    }

    @discardableResult
    public func evictCache(limitBytes: Int64? = nil, capOnly: Bool = false) -> (before: Int64, after: Int64, removed: Int) {
        lastEviction = Date()
        let configured = Int64(sync { lib.cacheLimitGB } * 1_000_000_000)
        let free = Self.freeBytes(cache)
        let keys: [URLResourceKey] = [.fileAllocatedSizeKey, .isRegularFileKey, .contentModificationDateKey]
        struct F { var url: URL; var size: Int64; var mtime: Date; var pid: String; var rank: Int }
        var files: [F] = []
        var total: Int64 = 0
        let opened: [String: Date] = sync { lastOpened }
        let now = Date()
        let e = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: keys)
        while let f = e?.nextObject() as? URL {
            guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let size = Int64(v.fileAllocatedSize ?? 0)
            total += size
            let rel = String(f.path.dropFirst(cache.path.count + 1))
            let parts = rel.split(separator: "/")
            guard parts.count >= 3 else { continue }
            let pid = String(parts[0]), kind = parts.dropFirst().dropLast().joined(separator: "/")
            // never: thumbnails, sidecars, temp
            if kind.hasSuffix("thumbs") || kind.hasPrefix("sidecars") || kind.hasPrefix(".tmp") { continue }
            let ext = f.pathExtension.lowercased()
            guard ext == "jpg" || ext == "png" || ext == "tif" else { continue }
            let mtime = v.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(mtime) < Self.protectSeconds { continue }                   // used recently
            if let o = opened[pid], now.timeIntervalSince(o) < Self.protectSeconds { continue }  // open project
            let name = f.lastPathComponent
            let rank = kind == "fullres" ? 0 : kind == "full" ? 1 : kind == "clip" ? 2 : kind.hasPrefix("analysis") ? 3
                : (kind == "proxies" && name.contains("@")) ? 4 : kind == "renders" ? 5 : 6
            files.append(F(url: f, size: size, mtime: mtime, pid: pid, rank: rank))
        }
        var need: Int64 = 0
        if !capOnly && free < Self.keepFreeBytes { need = Self.keepFreeBytes + Self.evictHysteresis - free }
        if total > configured { need = max(need, total - configured) }
        if let l = limitBytes { need = max(need, total - l) }
        if limitBytes == nil {
            let floor = free < Self.emergencyFree ? 0 : Self.cacheFloor
            need = min(need, max(0, total - floor))
        }
        guard need > 0 else { return (total, total, 0) }
        files.sort { a, b in
            let oa = opened[a.pid] ?? .distantPast, ob = opened[b.pid] ?? .distantPast
            if oa != ob { return oa < ob }
            if a.rank != b.rank { return a.rank < b.rank }
            return a.mtime < b.mtime
        }
        var freed: Int64 = 0, removed = 0
        for f in files where freed < need {
            if (try? FileManager.default.removeItem(at: f.url)) != nil { freed += f.size; removed += 1 }
        }
        if removed > 0 {
            sync { evictionHold = Date().addingTimeInterval(600) }
            log("cache: \(total / 1_000_000) MB -> \((total - freed) / 1_000_000) MB (\(removed) files evicted; free disk was \(free / 1_000_000) MB; thumbnails kept)")
            regenerateMissingThumbs()
        }
        return (total, total - freed, removed)
    }

    /// Re-renders, in the background, the edited previews that an earlier cache eviction removed (when the disk
    /// was nearly full): without them, opening such a photo waits for a RawTherapee render. Only while the disk
    /// has room (well above the eviction threshold) and only up to 80% of the cache limit, so it can't make the
    /// cache evict again; only from proxies already on disk, so no original is downloaded from iCloud.
    /// Most recently opened projects first; on the background render queue (one at a time, below edits).
    func restoreEvictedPreviews() {
        let free = Self.freeBytes(cache)
        let limit = Int64(sync { lib.cacheLimitGB } * 1_000_000_000)
        let roomOnDisk = free - (Self.keepFreeBytes + 3_000_000_000)
        let roomInCache = limit * 8 / 10 - cacheBytes
        let perRender: Int64 = 1_500_000
        let budget = Int(max(0, min(roomOnDisk, roomInCache)) / perRender)
        guard budget > 0 else { log("previews: not restoring evicted previews (disk or cache too full)"); return }
        let fm = FileManager()
        let jobs: [(String, String)] = sync {
            let order = projects.keys.sorted { (lastOpened[$0] ?? .distantPast, projects[$0]?.date ?? "", $0) > (lastOpened[$1] ?? .distantPast, projects[$1]?.date ?? "", $1) }
            var out: [(String, String)] = []
            for pid in order {
                guard let p = projects[pid], p.state != "importing" else { continue }
                let eng = engine(pid)
                for ph in p.photos where !ph.gone && ph.analyzed && ph.rendered {
                    guard !fm.fileExists(atPath: eng.previewURL(ph.ref).path) else { continue }
                    let proxy = eng.proxyURL(ph.ref).path
                    guard fm.fileExists(atPath: proxy), !Self.isDataless(proxy) else { continue }
                    out.append((pid, ph.id))
                    if out.count >= budget { return out }
                }
            }
            return out
        }
        guard !jobs.isEmpty else { return }
        log("previews: restoring \(jobs.count) edited preview(s) lost to cache eviction, in the background")
        for (pid, id) in jobs { enqueueRender(pid, id) }
    }

    /// Queues (high priority) a thumbnail for every photo that has none, most recently opened projects first.
    /// Thumbnails are tiny, so this runs even when the disk is short.
    func regenerateMissingThumbs() {
        let jobs: [(String, String)] = sync {
            let order = projects.keys.sorted { (lastOpened[$0] ?? .distantPast, projects[$0]?.date ?? "", $0) > (lastOpened[$1] ?? .distantPast, projects[$1]?.date ?? "", $1) }
            var out: [(String, String)] = []
            for pid in order {
                let eng = engine(pid)
                for ph in projects[pid]?.photos ?? [] where ph.analyzed && !ph.gone && !FileManager.default.fileExists(atPath: eng.thumbURL(ph.ref).path) {
                    out.append((pid, ph.id))
                }
            }
            return out
        }
        if !jobs.isEmpty { log("regenerating \(jobs.count) missing thumbnail(s)") }
        for (pid, id) in jobs { thumbQueue.addOperation { [weak self] in _ = self?.ensureThumb(pid, id) } }
    }

    /// The edited 480 px thumbnail, made if missing: from the preview render if there is one, else rendered
    /// by RawTherapee at a small size (from the proxy, else from the original). Returns its file.
    @discardableResult
    func ensureThumb(_ pid: String, _ id: String) -> URL? {
        guard let (ref, params) = sync({ photoIndex(pid, id).flatMap { i in projects[pid]?.photos[i] }.map { ($0.ref, $0.params) } }) else { return nil }
        let eng = engine(pid)
        let thumb = eng.thumbURL(ref)
        let fm = FileManager.default
        if fm.fileExists(atPath: thumb.path) { return thumb }
        try? fm.createDirectory(at: thumb.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmpDir = projectDir(pid).appendingPathComponent(".tmp/thumb")
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let token = UUID().uuidString.prefix(8)
        let tmpThumb = tmpDir.appendingPathComponent("\(id)-\(token)-t.jpg")
        defer { try? fm.removeItem(at: tmpThumb) }
        let preview = eng.previewURL(ref)
        if fm.fileExists(atPath: preview.path), let src = CGImageSourceCreateWithURL(preview as CFURL, nil), let img = Pixels.load(src, maxPixel: 480) {
            Pixels.writeJPEG(img, to: tmpThumb, quality: 0.8)
        } else {
            // small source image (temp, not cached): proxy if present, else the original
            let base = fm.fileExists(atPath: eng.proxyURL(ref).path) ? eng.proxyURL(ref) : URL(fileURLWithPath: ref.path)
            let small = tmpDir.appendingPathComponent("\(id)-\(token)-src.jpg"), out = tmpDir.appendingPathComponent("\(id)-\(token)-r.jpg")
            defer { try? fm.removeItem(at: small); try? fm.removeItem(at: out) }
            let dl = Self.isDataless(base.path)
            guard let src = CGImageSourceCreateWithURL(base as CFURL, nil), let img = Pixels.load(src, maxPixel: 960) else { return nil }
            if base.path == ref.path { releaseDownloaded(ref.path, wasDataless: dl) }
            Pixels.writeJPEG(img, to: small, quality: 0.92)
            thumbSlots.wait(); defer { thumbSlots.signal() }
            guard eng.renderPreview(ref, params: params, to: out, thumbOut: tmpThumb, upgradeProxy: false, proxyOverride: small) else { return nil }
        }
        guard fm.fileExists(atPath: tmpThumb.path) else { return nil }
        if !fm.fileExists(atPath: thumb.path) { try? fm.moveItem(at: tmpThumb, to: thumb) }
        return fm.fileExists(atPath: thumb.path) ? thumb : nil
    }
}
