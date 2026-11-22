import Foundation

/// Where Baseline Darkroom keeps its catalog and cache, and finds RawTherapee and the film LUTs.
public enum StudioPaths {
    public static let appName = "Baseline Darkroom"
    static let legacyName = "PhotoLab"

    /// ~/Library/Application Support/Baseline Darkroom (catalog; also holds luts/ and bin/ for the app).
    public static var support: URL { library("Application Support") }
    /// ~/Library/Caches/Baseline Darkroom (disposable previews).
    public static var cache: URL { library("Caches") }
    /// ~/Library/Logs/Baseline Darkroom.
    public static var logs: URL { library("Logs") }

    /// ~/Library/<area>/Baseline Darkroom. The app was called PhotoLab: on first use the old
    /// ~/Library/<area>/PhotoLab folder is renamed in place (same volume, atomic), so the catalog,
    /// edits, marks and My Look carry over untouched. Never while another process holds the old
    /// catalog's lock (an old build still running), and never over an existing new folder; if the
    /// rename can't happen, the old folder keeps being used, so nothing is ever lost or split.
    static func library(_ area: String) -> URL {
        // Testing: $PHOTOLAB_LIBRARY_ROOT puts the catalog, cache and logs under <root>/<area>/Baseline Darkroom,
        // e.g. to see a brand-new user's empty library next to your own. No migration happens there.
        if let root = ProcessInfo.processInfo.environment["PHOTOLAB_LIBRARY_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root).appendingPathComponent(area).appendingPathComponent(appName)
        }
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/\(area)")
        let new = base.appendingPathComponent(appName), old = base.appendingPathComponent(legacyName)
        let fm = FileManager.default
        if fm.fileExists(atPath: new.path) || !fm.fileExists(atPath: old.path) { return new }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if catalogInUse(home.appendingPathComponent("Library/Application Support/\(legacyName)")) { return old }
        do { try fm.moveItem(at: old, to: new); return new } catch { return old }
    }

    /// True when another process holds the catalog lock in `root` (see Studio.takeLock).
    static func catalogInUse(_ root: URL) -> Bool {
        let lock = root.appendingPathComponent(".lock").path
        guard FileManager.default.fileExists(atPath: lock) else { return false }
        let fd = open(lock, O_RDWR)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { return true }
        flock(fd, LOCK_UN)
        return false
    }

    /// The support folder's copy of rawtherapee-cli (made by install.sh, or repaired here).
    public static var supportCLI: URL { support.appendingPathComponent("bin/rawtherapee-cli") }

    /// rawtherapee-cli: $PHOTOLAB_RT, the app bundle, the support folder, <package>/bin, PATH locations; the first
    /// one that actually runs (RawTherapeeCLI.runs, cached). Never /Applications/RawTherapee.app's own CLI: the
    /// official build is sandbox-entitled and crashes when started by another program. When nothing runs, the
    /// support-folder copy is repaired from /Applications/RawTherapee.app (copied and signed ad hoc), unless it
    /// already runs. It links against /Applications/RawTherapee.app, so that must be installed too.
    public static func rawTherapee(repair: Bool = true, log: ((String) -> Void)? = nil) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: "/Applications/RawTherapee.app") || ProcessInfo.processInfo.environment["PHOTOLAB_RT"] != nil else { return nil }
        let app = RawTherapeeCLI.appCLI.standardizedFileURL.path
        var c: [String] = []
        if let env = ProcessInfo.processInfo.environment["PHOTOLAB_RT"], !env.isEmpty { c.append(env) }
        if let aux = Bundle.main.url(forAuxiliaryExecutable: "rawtherapee-cli") { c.append(aux.path) }
        c.append(supportCLI.path)
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        c.append(exe.appendingPathComponent("../../../bin/rawtherapee-cli").standardizedFileURL.path)   // <package>/.build/<cfg>/x
        c.append(exe.appendingPathComponent("../../../../bin/rawtherapee-cli").standardizedFileURL.path) // <package>/.build/<triple>/<cfg>/x
        c.append(exe.appendingPathComponent("rawtherapee-cli").path)
        c += ["/usr/local/bin/rawtherapee-cli", "/opt/homebrew/bin/rawtherapee-cli"]
        var seen = Set<String>()
        for path in c where seen.insert(path).inserted && URL(fileURLWithPath: path).standardizedFileURL.path != app {
            guard fm.isExecutableFile(atPath: path) else { continue }
            if RawTherapeeCLI.runs(URL(fileURLWithPath: path)) { return URL(fileURLWithPath: path) }
            log?("rawtherapee-cli at \(path) doesn't run; skipped")
        }
        guard repair, fm.isExecutableFile(atPath: app) else { return nil }
        // Nothing runs: repair the support-folder copy (missing, or broken: it can't be in use).
        return RawTherapeeCLI.install(from: RawTherapeeCLI.appCLI, to: supportCLI, log: log) ? supportCLI : nil
    }

    /// Why RawTherapee can't render, for Setup and Settings: nil (fine), "notInstalled" (no
    /// /Applications/RawTherapee.app), "broken" (it's there but no copy of its CLI runs).
    public static func rawTherapeeProblem(_ rt: URL?) -> String? {
        if let rt, !RawTherapeeCLI.isDisabled(rt), RawTherapeeCLI.runs(rt) { return nil }
        return FileManager.default.fileExists(atPath: "/Applications/RawTherapee.app") ? "broken" : "notInstalled"
    }

    /// Film LUT root (…/HaldCLUT/Color): $PHOTOLAB_LUTS, the support folder, <package>/luts.
    public static func luts() -> URL? {
        let fm = FileManager.default
        var c: [String] = []
        if let env = ProcessInfo.processInfo.environment["PHOTOLAB_LUTS"] { c.append(env) }
        c.append(support.appendingPathComponent("luts/HaldCLUT/Color").path)
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        c.append(exe.appendingPathComponent("../../../luts/HaldCLUT/Color").standardizedFileURL.path)
        c.append(exe.appendingPathComponent("../../../../luts/HaldCLUT/Color").standardizedFileURL.path)
        return c.first { fm.fileExists(atPath: $0 + "/Kodak") }.map { URL(fileURLWithPath: $0) }
    }
}
