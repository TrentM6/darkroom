import Foundation

/// Whether a rawtherapee-cli actually runs, and repairing the support-folder copy.
///
/// The official RawTherapee 5.11 macOS build signs `rawtherapee-cli` with the App Sandbox entitlement and the
/// hardened runtime. Run as a plain child process it dies before `main` (SIGTRAP, exit 133). A copy re-signed
/// ad hoc (`codesign --force --sign -`) drops those entitlements and runs normally; its libraries are loaded
/// from /Applications/RawTherapee.app by absolute path, so the copy works outside the bundle.
public enum RawTherapeeCLI {
    static let lock = NSLock()
    /// Probe results per path, valid while the file's size and modification date are unchanged.
    static var probes: [String: (stamp: String, ok: Bool)] = [:]
    /// Consecutive launch crashes per path (reset by any run that gets past launch).
    static var crashes: [String: Int] = [:]
    /// Paths given up on after repeated launch crashes: renders fail at once instead of starting a process.
    static var disabled = Set<String>()
    /// Launch crashes in a row before a CLI is treated as unavailable.
    static let crashLimit = 3
    /// Where "given up on" is reported (the studio's log).
    public static var logger: ((String) -> Void)? = nil

    public static let appCLI = URL(fileURLWithPath: "/Applications/RawTherapee.app/Contents/MacOS/rawtherapee-cli")

    static func stamp(_ path: String) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (a[.size] as? NSNumber)?.intValue ?? -1
        let date = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(date)"
    }

    /// True when `cli -v` prints RawTherapee's version (about 0.2 s; cached per file).
    public static func runs(_ url: URL) -> Bool {
        let path = url.path
        guard FileManager.default.isExecutableFile(atPath: path), let st = stamp(path) else { return false }
        lock.lock()
        if let p = probes[path], p.stamp == st { lock.unlock(); return p.ok }
        lock.unlock()
        let ok = probe(url)
        lock.lock()
        probes[path] = (st, ok)
        if ok { disabled.remove(path); crashes[path] = 0 }
        lock.unlock()
        return ok
    }

    /// Runs `cli -v` uncached. `-v` exits 255 after printing the version; a sandbox crash prints nothing and
    /// dies on a signal.
    static func probe(_ url: URL, timeout: TimeInterval = 15) -> Bool {
        let proc = Process()
        proc.executableURL = url
        proc.arguments = ["-v"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        guard (try? proc.run()) != nil else { return false }
        // Read while it runs (the version text is small, but a full pipe would block it).
        var data = Data()
        let reader = DispatchQueue.global(qos: .userInitiated)
        let readDone = DispatchSemaphore(value: 0)
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); readDone.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut { kill(proc.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 2) }
            _ = readDone.wait(timeout: .now() + 2)
            return false
        }
        _ = readDone.wait(timeout: .now() + 2)
        guard proc.terminationReason == .exit else { return false }
        return String(decoding: data, as: UTF8.self).contains("RawTherapee")
    }

    /// Copies `src` to `dst`, re-signs the copy ad hoc (dropping the sandbox entitlement) and replaces `dst`
    /// only if the copy runs. A working `dst` is never replaced by a broken one.
    @discardableResult
    public static func install(from src: URL, to dst: URL, log: ((String) -> Void)? = nil) -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: src.path) else { return false }
        let dir = dst.deletingLastPathComponent()
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { log?("rawtherapee-cli repair: can't create \(dir.path): \(error)"); return false }
        let tmp = dir.appendingPathComponent(".rawtherapee-cli-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: tmp) }
        do { try fm.copyItem(at: src, to: tmp) } catch { log?("rawtherapee-cli repair: copy failed: \(error)"); return false }
        chmod(tmp.path, 0o755)
        // A RawTherapee downloaded in a browser is quarantined, and copyItem keeps that; a quarantined copy signed
        // ad hoc is killed by macOS on launch. The copy is Darkroom's own (RawTherapee.app is left as it is).
        removexattr(tmp.path, "com.apple.quarantine", 0)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", tmp.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        guard (try? sign.run()) != nil else { log?("rawtherapee-cli repair: codesign didn't start"); return false }
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { log?("rawtherapee-cli repair: codesign failed (\(sign.terminationStatus))"); return false }
        guard probe(tmp) else { log?("rawtherapee-cli repair: the re-signed copy of \(src.path) doesn't run either"); return false }
        guard rename(tmp.path, dst.path) == 0 else { log?("rawtherapee-cli repair: couldn't move it into place at \(dst.path)"); return false }
        forget(dst)
        log?("rawtherapee-cli repaired: \(dst.path) (copied from \(src.path), signed ad hoc)")
        return true
    }

    /// Drops what is known about `url` (after a repair, or when the user asks to check again).
    public static func forget(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        probes[url.path] = nil; crashes[url.path] = nil; disabled.remove(url.path)
    }

    /// Called by every rawtherapee-cli run: `crashed` when it died on a signal right after launch.
    static func noteLaunch(_ url: URL, crashed: Bool) {
        lock.lock()
        let path = url.path
        if !crashed {
            crashes[path] = 0
            lock.unlock()
            return
        }
        let n = (crashes[path] ?? 0) + 1
        crashes[path] = n
        let newlyDisabled = n >= crashLimit && disabled.insert(path).inserted
        if newlyDisabled, let st = stamp(path) { probes[path] = (st, false) }
        lock.unlock()
        if newlyDisabled { logger?("rawtherapee-cli crashed on launch \(n) times in a row; treating RawTherapee as unavailable (\(path))") }
    }

    /// True after repeated launch crashes, until the file changes or is repaired.
    public static func isDisabled(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard disabled.contains(url.path) else { return false }
        // Replaced on disk (e.g. the installer ran again): give it another chance.
        if let p = probes[url.path], let st = stamp(url.path), p.stamp != st {
            disabled.remove(url.path); crashes[url.path] = 0; probes[url.path] = nil
            return false
        }
        return true
    }
}
