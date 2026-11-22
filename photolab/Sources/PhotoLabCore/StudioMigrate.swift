import Foundation

// Migration of a `photolab analyze` report folder (report.json + edit/.photolab/*.params.json) into a
// studio project: the analysis is reused (no re-analysis needed), a photo whose params differ from
// its old recommendation is a manual edit and keeps EXACTLY its params (marked edited), and the
// old previews/proxies seed the cache.

extension Studio {
    func migrateLegacy(reportDir: URL, into pid: String) throws {
        let fm = FileManager.default
        let rj = reportDir.appendingPathComponent("report.json")
        let report: ShootReport
        do { report = try JSONDecoder().decode(ShootReport.self, from: Store.readAll(rj) ?? Data()) } catch {
            throw StudioError.failed("can't read \(rj.path): \(error)")
        }
        let gen = reportDir.appendingPathComponent("edit/.photolab")
        guard let folder = sync({ projects[pid]?.folder }) else { throw StudioError.notFound("no project \(pid)") }
        let folderURL = URL(fileURLWithPath: folder)
        let backup = root.appendingPathComponent("projects/\(pid).migration")
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        let cacheDir = projectDir(pid)
        for d in ["proxies", "renders", "thumbs", "analysis/previews", "analysis/thumbs", "analysis/overlays"] {
            try fm.createDirectory(at: cacheDir.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        func copy(_ a: URL, _ b: URL) {
            guard fm.fileExists(atPath: a.path), let d = Store.readAll(a) else { return }
            try? fm.removeItem(at: b)
            try? d.write(to: b, options: .atomic)
        }

        var list: [PhotoEntry] = []
        var oldParams: [String: EditParams] = [:]
        var editedIds = Set<String>()
        for r in report.photos {
            var e = entry(from: r, keeping: nil)
            e.path = folderURL.appendingPathComponent(r.file).path
            e.burst = r.burstId
            e.best = r.bestInBurst
            e.moment = r.groupId
            let pURL = gen.appendingPathComponent(r.file + ".params.json")
            let recURL = gen.appendingPathComponent(r.file + ".recommended.json")
            copy(pURL, backup.appendingPathComponent(r.file + ".params.json"))
            copy(recURL, backup.appendingPathComponent(r.file + ".recommended.json"))
            func readParams(_ u: URL) -> EditParams? { Store.readAll(u).flatMap { try? JSONDecoder().decode(EditParams.self, from: $0) } }
            if FileManager.default.fileExists(atPath: pURL.path) && readParams(pURL) == nil {
                // Never treat an unreadable edit as "no edit": stop and let the caller retry/analyse.
                throw StudioError.failed("can't read \(pURL.path)")
            }
            if let old = readParams(pURL)?.clamped(lutRoot: lutRoot) {
                oldParams[r.id] = old
                let rec = readParams(recURL)?.clamped(lutRoot: lutRoot) ?? recommendParams(r).0.clamped(lutRoot: lutRoot)
                if old != rec { editedIds.insert(r.id) }
            }
            list.append(e)
        }
        var cs = list.map { $0.corrections }
        StudioLook.projectPass(&cs)
        for i in list.indices {
            list[i].corrections = cs[i]
            if editedIds.contains(list[i].id), let old = oldParams[list[i].id] {
                list[i].params = old
                list[i].lookAmount = 100
                list[i].touched = true
                freeze(&list[i])
            } else {
                recompute(&list[i])
            }
        }
        // Seed the cache. A previous render is reused only where the params didn't change.
        for i in list.indices {
            let id = list[i].id
            copy(gen.appendingPathComponent("proxy/\(id).jpg"), cacheDir.appendingPathComponent("proxies/\(id).jpg"))
            copy(reportDir.appendingPathComponent("thumbs/\(id).jpg"), cacheDir.appendingPathComponent("analysis/thumbs/\(id).jpg"))
            if let old = oldParams[id], old == list[i].params,
               fm.fileExists(atPath: reportDir.appendingPathComponent("edits/\(id).jpg").path) {
                copy(reportDir.appendingPathComponent("edits/\(id).jpg"), cacheDir.appendingPathComponent("renders/\(id).jpg"))
                copy(reportDir.appendingPathComponent("thumbs/\(id)-edit.jpg"), cacheDir.appendingPathComponent("thumbs/\(id).jpg"))
                list[i].rendered = fm.fileExists(atPath: cacheDir.appendingPathComponent("thumbs/\(id).jpg").path)
                list[i].version = 1
                list[i].renderedParams = list[i].params
            }
            // For verification: the migrated params, encoded exactly like the old params files.
            if editedIds.contains(id), let d = try? Store.pretty.encode(list[i].params) {
                try? d.write(to: backup.appendingPathComponent(list[i].file + ".params.migrated.json"), options: .atomic)
            }
        }
        // Export settings and the old export manifest.
        let legacySettings = Store.read(ExportSettings.self, from: gen.appendingPathComponent("export.json"))?.clamped() ?? ExportSettings()
        let legacyOwned = Store.readAll(gen.appendingPathComponent("exported.json")).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        sync {
            guard projects[pid] != nil else { return }
            projects[pid]!.photos = list
            projects[pid]!.state = "ready"
            projects[pid]!.migratedFrom = reportDir.path
            projects[pid]!.hintsVersion = StudioAnalysis.hintsVersion
            projects[pid]!.critiqueVersion = StudioCritique.version
            sortPhotos(pid)
            rebuildMoments(pid)
            imports[pid] = nil
            if lib.frame == FrameSettings() && lib.exportRoot == "~/Desktop" {
                var f = FrameSettings()
                f.enabled = legacySettings.frame; f.side = legacySettings.side; f.topBottom = legacySettings.topBottom; f.color = legacySettings.color
                lib.frame = f.clamped()
                if !legacySettings.dest.isEmpty {
                    let home = NSHomeDirectory()
                    lib.exportRoot = legacySettings.dest.hasPrefix(home) ? "~" + legacySettings.dest.dropFirst(home.count) : legacySettings.dest
                }
            }
            for path in legacyOwned {
                let base = (URL(fileURLWithPath: path).lastPathComponent as NSString).deletingPathExtension
                if let ph = list.first(where: { ($0.file as NSString).deletingPathExtension == base }) { owned[path] = "\(pid)/\(ph.id)" }
            }
            markDirty(pid); markDirty(""); markDirty("#exported")
        }
        var slim = report
        slim.photos = slim.photos.map { var x = $0; x.edit = nil; x.tone.histogram = Histograms(r: [], g: [], b: [], l: []); return x }
        try? Store.write(slim, to: analysisURL(pid))
        for ph in list where !ph.rendered { enqueueRender(pid, ph.id) }
        log("migrated \(reportDir.path) into \(pid): \(list.count) photos, \(editedIds.count) manual edits kept (\(editedIds.sorted().joined(separator: ", ")))")
    }

    /// Runs the current analysis again over the whole project, keeping marks and edits (edited
    /// photos keep their params exactly; unedited ones follow the new auto corrections).
    public func reanalyze(_ pid: String) throws {
        try sync { guard projects[pid] != nil else { throw StudioError.notFound("no project \(pid)") } }
        queueAnalysis(AnalysisJob(pid: pid, files: nil))   // behind new shoots
    }
}
