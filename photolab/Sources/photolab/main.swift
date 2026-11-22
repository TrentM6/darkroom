import Foundation
import PhotoLabCore

func usage() -> Never {
    print("""
    photolab \(engineVersion): deterministic, on-device photo analysis + RawTherapee editing

    Usage:
      photolab analyze <folder> [--out <dir>] [--jobs <n>] [--no-edit] [--reset-edits]
          Analyze every JPEG/TIFF, write a recommended RawTherapee edit per photo and render it.
      photolab render <report-dir> [--jobs <n>]
          Re-render previews after you change edits in RawTherapee (open <report-dir>/edit).
      photolab export <report-dir> [--out <dir>] [--jobs <n>]
          Full-resolution JPEGs (quality 95, 4:4:4) of every photo with its current edit, framed per the
          shoot's export settings, into ~/Desktop/<shoot> edits (or the folder set in the editor / --out).
      photolab serve <report-dir> [--port <n>]
          Open the report with in-app editing at http://127.0.0.1:<port>/index.html (default 8765).
      photolab tags <file>
          Dump raw Fujifilm maker-note tags.
      photolab edge <file>...
          The contact-sheet edge print for each file, from its own EXIF or its original (skips iCloud placeholders).
      photolab studio [--port <n>] [--ui <dir>]
          Baseline Darkroom server (the catalog in ~/Library/Application Support/Baseline Darkroom) at
          http://127.0.0.1:<port>/ (default 8765). --ui (or $PHOTOLAB_UI_DIR) serves the UI live from a folder.

    Originals are never modified. Edits live in <report-dir>/edit: RawTherapee sidecars (.pp3)
    generated from edit/.photolab/<FILE>.params.json.
    """)
    exit(2)
}

nonisolated(unsafe) var keep: [Any] = []
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

/// rawtherapee-cli and the film LUTs: $PHOTOLAB_RT / $PHOTOLAB_LUTS, the app bundle,
/// ~/Library/Application Support/Baseline Darkroom/{bin,luts}, or <package>/{bin,luts} (see StudioPaths).
func findRT() -> URL? { StudioPaths.rawTherapee() }
func findLUTs() -> URL? { StudioPaths.luts() }

func loadReport(_ dir: URL) throws -> ShootReport {
    try JSONDecoder().decode(ShootReport.self, from: Data(contentsOf: dir.appendingPathComponent("report.json")))
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }
if cmd == "tags", args.count >= 2 { for line in dumpFujiTags(path: args[1]) { print(line) }; exit(0) }
if cmd == "edge", args.count >= 2 { for f in args.dropFirst() { print("\((f as NSString).lastPathComponent)\t\(Studio.edgeReport(path: f))") }; exit(0) }
if cmd == "studio" {
    var port: UInt16 = 8765
    var ui: String? = nil
    var j = 1
    while j < args.count {
        switch args[j] {
        case "--port" where j + 1 < args.count: port = UInt16(args[j + 1]) ?? 8765; j += 2
        case "--ui" where j + 1 < args.count: ui = args[j + 1]; j += 2
        default: usage()
        }
    }
    let log: (String) -> Void = { s in
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        FileHandle.standardError.write(("\(f.string(from: Date())) \(s)\n").data(using: .utf8)!)
    }
    do {
        let rt = StudioPaths.rawTherapee(log: log), luts = StudioPaths.luts()
        if rt == nil { log("rawtherapee-cli not found: previews and export are unavailable") }
        if luts == nil { log("film LUTs not found: film simulation is off") }
        let studio = try Studio(rt: rt, lutRoot: luts, log: log)
        let server = StudioServer(studio: studio, uiDir: StudioServer.resolveUIDir(ui), log: log)
        try server.start(port: port)
        studio.start()
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        for sig in [SIGTERM, SIGINT] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { studio.flush(); exit(0) }
            src.resume()
            keep.append(src)
        }
        withExtendedLifetime((studio, server)) { dispatchMain() }
    } catch {
        err("error: \(error)")
        exit(1)
    }
}
guard args.count >= 2 else { usage() }
let target = URL(fileURLWithPath: args[1]).standardizedFileURL
var out: URL? = nil
var jobs = 3
var edit = true, reset = false
var port: UInt16 = 8765
var i = 2
while i < args.count {
    switch args[i] {
    case "--out" where i + 1 < args.count: out = URL(fileURLWithPath: args[i + 1]).standardizedFileURL; i += 2
    case "--jobs" where i + 1 < args.count: jobs = Int(args[i + 1]) ?? 3; i += 2
    case "--no-edit": edit = false; i += 1
    case "--reset-edits": reset = true; i += 1
    case "--port" where i + 1 < args.count: port = UInt16(args[i + 1]) ?? 8765; i += 2
    default: usage()
    }
}

do {
    switch cmd {
    case "analyze":
        let dir = out ?? URL(fileURLWithPath: "reports").appendingPathComponent(target.lastPathComponent).standardizedFileURL
        var report = try runShoot(RunOptions(input: target, output: dir, jobs: jobs), log: err)
        if edit {
            guard let rt = findRT() else { err("rawtherapee-cli not found; set PHOTOLAB_RT or use --no-edit"); exit(1) }
            try prepareEdits(&report, reportDir: dir, reset: reset, lutRoot: findLUTs())
            try renderEdits(&report, reportDir: dir, opt: EditOptions(rawTherapeeCLI: rt, jobs: jobs, reset: reset), lutRoot: findLUTs(), log: err)
        }
        try writeReport(report, to: dir)
        print("Report: \(dir.appendingPathComponent("index.html").path)")
        if edit { print("Edit in RawTherapee: open \(dir.appendingPathComponent("edit").path)") }
    case "render":
        guard let rt = findRT() else { err("rawtherapee-cli not found"); exit(1) }
        var report = try loadReport(target)
        try prepareEdits(&report, reportDir: target, reset: false, lutRoot: findLUTs())
        try renderEdits(&report, reportDir: target, opt: EditOptions(rawTherapeeCLI: rt, jobs: jobs, reset: false), lutRoot: findLUTs(), log: err)
        try writeReport(report, to: target)
        let mine = report.photos.filter { $0.edit?.userModified == true }.count
        print("Rendered. \(mine) photo(s) carry your own RawTherapee changes.")
    case "export":
        guard let rt = findRT() else { err("rawtherapee-cli not found"); exit(1) }
        let report = try loadReport(target)
        let dest = try exportEdits(report, reportDir: target, to: out, opt: EditOptions(rawTherapeeCLI: rt, jobs: jobs, reset: false), log: err)
        print("Exported to \(dest.path)")
    case "serve":
        guard let rt = findRT() else { err("rawtherapee-cli not found"); exit(1) }
        let server = try PhotoLabServer(reportDir: target, rt: rt, lutRoot: findLUTs(), log: err)
        try server.start(port: port)
        withExtendedLifetime(server) { dispatchMain() }
    default:
        usage()
    }
} catch {
    err("error: \(error)")
    exit(1)
}
