import AppKit
import PhotoLabCore
import WebKit

// Baseline Darkroom.app: a native window around the studio UI. The studio server runs in-process on a random
// free port (127.0.0.1); the window is a WKWebView on it. If another Baseline Darkroom process already owns
// the catalog (e.g. a `photolab studio` dev server), the window attaches to that server instead.

let logURL = StudioPaths.logs.appendingPathComponent("Baseline Darkroom.log")
let logLock = NSLock()
func appLog(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date())) \(s)\n"
    logLock.lock(); defer { logLock.unlock() }
    FileHandle.standardError.write(line.data(using: .utf8)!)
    try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.data(using: .utf8)!.write(to: logURL)
    }
}

/// Folders dropped on the window are connected natively (the page only gets file names).
final class DropWebView: WKWebView {
    var onFolders: (([URL]) -> Void)?

    static func folders(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.folders(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.folders(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let f = Self.folders(sender)
        if f.isEmpty { return super.performDragOperation(sender) }
        onFolders?(f)
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    var window: NSWindow!
    var web: DropWebView!
    var studio: Studio?
    var server: StudioServer?
    var base = URL(string: "http://127.0.0.1/")!
    var loadAttempts = 0
    // Watchdog: reload the page when the server restarts or the UI files change (never show a stale UI).
    var lastInstance: String? = nil
    var lastUIHash: String? = nil
    var unreachable = 0
    var watchdog: Timer? = nil

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenus()
        startServer()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkServer() }
        }
    }

    func applicationDidBecomeActive(_ note: Notification) { handlePendingReload() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ note: Notification) { studio?.flush(); appLog("quit") }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Server

    /// `takeover`: called by the watchdog after the attached server went away; if the catalog is still
    /// locked (that server is alive but busy), keep waiting instead of giving up.
    func startServer(takeover: Bool = false) {
        let rt = StudioPaths.rawTherapee(log: appLog), luts = StudioPaths.luts()
        appLog("launch: RawTherapee \(rt?.path ?? "NOT FOUND"), LUTs \(luts?.path ?? "NOT FOUND")")
        do {
            let s = try Studio(rt: rt, lutRoot: luts, log: appLog)
            let srv = StudioServer(studio: s, uiDir: StudioServer.resolveUIDir(), log: appLog)
            let port = try srv.start(port: 0)
            s.start()
            studio = s; server = srv
            base = URL(string: "http://127.0.0.1:\(port)/")!
        } catch StudioError.locked(let msg) {
            if takeover { return }
            if let port = Studio.lockHolderPort(), ping(port) {
                appLog("\(msg); attaching to the Baseline Darkroom server on port \(port)")
                base = URL(string: "http://127.0.0.1:\(port)/")!
            } else {
                fatal("Baseline Darkroom is already open", msg)
            }
        } catch {
            if takeover { appLog("couldn't take over the catalog: \(error)"); return }
            fatal("Baseline Darkroom couldn't open its catalog", "\(error)")
        }
    }

    /// Every 3 s (off the main thread): has the server restarted, changed its UI, or gone away?
    func checkServer() {
        guard let url = URL(string: base.absoluteString + "api/ping") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let j = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let inst = j?["instance"] as? String, hash = j?["uiHash"] as? String
            Task { @MainActor in self.serverStatus(ok: j?["ok"] as? Bool == true, instance: inst, uiHash: hash) }
        }.resume()
    }

    func serverStatus(ok: Bool, instance: String?, uiHash: String?) {
        guard ok else {
            // One missed ping means nothing: in the background macOS naps the app and a ping can time out
            // while the server is fine. Only a run of misses counts.
            unreachable += 1
            if unreachable == 3 { appLog("server at \(base.absoluteString) not answering") }
            // Attached to another Baseline Darkroom's server that has gone away: open the catalog here instead.
            if studio == nil && unreachable >= 4 {
                startServer(takeover: true)
                if studio != nil { appLog("took over the catalog; now at \(base.absoluteString)"); reloadKeepingRoute() }
            }
            return
        }
        // Only a new server instance is a restart. The same server answering again after a pause (busy, or
        // this app napped in the background) keeps the page as it is: reloading it was the black flash.
        var restarted = false
        if unreachable >= 3 { appLog("server is back") }
        unreachable = 0
        if let i = instance, let last = lastInstance, i != last { appLog("server restarted (instance \(i))"); restarted = true }
        let uiChanged = uiHash != nil && lastUIHash != nil && uiHash != lastUIHash
        if uiChanged { appLog("UI files changed") }
        lastInstance = instance ?? lastInstance
        lastUIHash = uiHash ?? lastUIHash
        if restarted { pendingReload = .restart; pendingSince = Date() }
        else if uiChanged && pendingReload == nil { pendingReload = .ui; pendingSince = Date() }
        handlePendingReload()
    }

    enum PendingReload { case restart, ui }
    var pendingReload: PendingReload? = nil
    var pendingSince = Date()
    var toastShown = false

    /// Never reload under the user's hands. 5 s after a change: a server restart reloads once the page has
    /// been idle for 10 s (else a toast); a UI change only offers "Update available — Reload".
    func handlePendingReload() {
        guard let kind = pendingReload, Date().timeIntervalSince(pendingSince) >= 5 else { return }
        // Never reload a window nobody is looking at; it reloads when the app comes forward.
        guard NSApp.isActive, window?.isVisible == true, window?.isMiniaturized == false else { return }
        web.evaluateJavaScript("window.__plIdleMs ? window.__plIdleMs() : 999999") { [weak self] r, _ in
            guard let self else { return }
            let idle = (r as? Double) ?? Double((r as? Int) ?? 999999)
            if kind == .restart && idle >= 10000 {
                appLog("reloading (server restarted; page idle \(Int(idle / 1000)) s)")
                self.pendingReload = nil; self.toastShown = false
                self.reloadKeepingRoute()
            } else if !self.toastShown {
                self.toastShown = true
                let msg = kind == .ui ? "Update available" : "Baseline Darkroom restarted"
                self.web.evaluateJavaScript("window.__plShowUpdate && window.__plShowUpdate('\(msg)')", completionHandler: nil)
            }
        }
    }

    /// Reloads the page on the current base, keeping the hash route (e.g. #/p/<id>).
    func reloadKeepingRoute() {
        let frag = web.url?.fragment
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.fragment = frag
        web.load(URLRequest(url: c.url ?? base, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    func ping(_ port: UInt16) -> Bool {
        guard let u = URL(string: "http://127.0.0.1:\(port)/api/ping"), let d = try? Data(contentsOf: u),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return j["ok"] as? Bool == true
    }

    func fatal(_ title: String, _ msg: String) -> Never {
        appLog("fatal: \(title): \(msg)")
        let a = NSAlert()
        a.messageText = title
        a.informativeText = msg
        a.runModal()
        exit(1)
    }

    // MARK: Window

    func buildWindow() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let ucc = WKUserContentController()
        ucc.addScriptMessageHandler(self, contentWorld: .page, name: "photolab")
        // The UI's contract: attachFolder()/locateFolder(pid) resolve to the chosen folder path (or null);
        // the page then calls the API itself. Drops and File > Attach Folder… call window.studio.attachPath(path).
        let bridge = """
        window.photolab = {
          isApp: true,
          attachFolder: () => window.webkit.messageHandlers.photolab.postMessage({action: 'chooseFolder', title: 'Attach Folder', prompt: 'Attach'}),
          importFolder: () => window.webkit.messageHandlers.photolab.postMessage({action: 'chooseFolder', title: 'Attach Folder', prompt: 'Attach'}),
          locateFolder: (projectId) => window.webkit.messageHandlers.photolab.postMessage({action: 'chooseFolder', title: 'Locate Folder', prompt: 'Locate'}),
          chooseFolder: () => window.webkit.messageHandlers.photolab.postMessage({action: 'chooseFolder', title: 'Choose Folder', prompt: 'Choose'}),
          reveal: (path) => window.webkit.messageHandlers.photolab.postMessage({action: 'reveal', path}),
        };
        """
        ucc.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Activity tracking (the shell never reloads under the user's hands) and the update toast.
        let shell = """
        window.__plActive = Date.now();
        ['pointerdown','pointermove','keydown','wheel','touchstart'].forEach(t => window.addEventListener(t, () => { window.__plActive = Date.now(); }, {capture: true, passive: true}));
        window.__plIdleMs = () => Date.now() - (window.__plActive || 0);
        window.__plShowUpdate = (msg) => {
          if (window.studio && typeof window.studio.updateAvailable === 'function') { window.studio.updateAvailable(msg); return; }
          let t = document.getElementById('__pl_update');
          if (!t) {
            t = document.createElement('div'); t.id = '__pl_update';
            t.style.cssText = 'position:fixed;right:16px;bottom:16px;z-index:2147483647;background:#2a2a2c;color:#ddd;font:13px -apple-system,system-ui;padding:9px 12px;border-radius:8px;box-shadow:0 4px 16px rgba(0,0,0,.4);display:flex;gap:10px;align-items:center';
            const s = document.createElement('span'); s.id = '__pl_update_msg'; t.appendChild(s);
            const b = document.createElement('button'); b.textContent = 'Reload';
            b.style.cssText = 'background:#3d6fd8;color:#fff;border:0;border-radius:5px;padding:4px 10px;font:inherit;cursor:pointer';
            b.onclick = () => location.reload(); t.appendChild(b);
            const x = document.createElement('button'); x.textContent = '×'; x.title = 'Later';
            x.style.cssText = 'background:none;border:0;color:#999;font:16px -apple-system;cursor:pointer'; x.onclick = () => t.remove(); t.appendChild(x);
            document.body.appendChild(t);
          }
          document.getElementById('__pl_update_msg').textContent = msg || 'Update available';
        };
        """
        ucc.addUserScript(WKUserScript(source: shell, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = ucc
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")

        web = DropWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), configuration: cfg)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isInspectable = true
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = NSColor(white: 0.12, alpha: 1)
        web.onFolders = { [weak self] urls in self?.attach(urls.map { $0.path }) }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Baseline Darkroom"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.12, alpha: 1)
        window.minSize = NSSize(width: 900, height: 600)
        window.contentView = web
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("PhotoLabMainWindow")
        window.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: base))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { retryLoad(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { retryLoad(error) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadAttempts = 0; pendingReload = nil; toastShown = false
        appLog("UI loaded: \(webView.url?.absoluteString ?? "")")
    }
    func retryLoad(_ error: Error) {
        appLog("UI load failed: \(error.localizedDescription)")
        loadAttempts += 1
        guard loadAttempts < 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.web.load(URLRequest(url: self.base))
        }
    }

    // Links to other sites open in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let u = action.request.url, let host = u.host, host != "127.0.0.1" && host != "localhost", u.scheme?.hasPrefix("http") == true {
            NSWorkspace.shared.open(u)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        appLog("web content process ended; reloading")
        reloadKeepingRoute()
    }

    // JavaScript alert / confirm / prompt / file inputs as native panels.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "OK")
        a.beginSheetModal(for: window) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { r in completionHandler(r == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let a = NSAlert(); a.messageText = prompt; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); field.stringValue = defaultText ?? ""
        a.accessoryView = field
        a.beginSheetModal(for: window) { r in completionHandler(r == .alertFirstButtonReturn ? field.stringValue : nil) }
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = parameters.allowsDirectories; p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.beginSheetModal(for: window) { r in completionHandler(r == .OK ? p.urls : nil) }
    }

    // MARK: Native bridge (window.photolab.*)

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        let body = message.body as? [String: Any] ?? [:]
        switch body["action"] as? String ?? "" {
        case "chooseFolder", "attachFolder", "importFolder":
            chooseFolder(title: body["title"] as? String ?? "Attach Folder", prompt: body["prompt"] as? String ?? "Attach") { path in
                replyHandler(path ?? NSNull(), nil)
            }
        case "locate", "locateFolder":
            chooseFolder(title: "Locate Folder", prompt: "Locate") { path in replyHandler(path ?? NSNull(), nil) }
        case "reveal":
            if let p = body["path"] as? String { reveal(p) }
            replyHandler(true, nil)
        default:
            replyHandler(nil, "unknown action")
        }
    }

    /// NSOpenPanel for a folder. Choosing it also gives Baseline Darkroom (and the RawTherapee it runs)
    /// macOS access to it, e.g. on the Desktop.
    func chooseFolder(title: String, prompt: String, _ done: @escaping (String?) -> Void) {
        let p = NSOpenPanel()
        p.title = title
        p.prompt = prompt
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = false
        p.beginSheetModal(for: window) { r in done(r == .OK ? p.url?.path : nil) }
    }

    /// Folders from File > Attach Folder… or a drop: handed to the page (window.studio.attachPath), which
    /// attaches them and shows progress; without the page hooks, attached directly through the API.
    func attach(_ paths: [String]) {
        guard let first = paths.first else { return }
        let arg = (try? JSONSerialization.data(withJSONObject: [first], options: [.fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let js = "(window.studio && typeof window.studio.attachPath === 'function') ? (window.studio.attachPath(\(arg)[0]), true) : false"
        web.evaluateJavaScript(js) { [weak self] r, _ in
            guard let self else { return }
            let handled = (r as? Bool) == true
            let rest = handled ? Array(paths.dropFirst()) : paths
            guard !rest.isEmpty else { return }
            self.attachPaths(rest) { result, error in
                if let error { self.toastError(error); return }
                let detail = result.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
                self.web.evaluateJavaScript("window.studio && window.studio.attached ? window.studio.attached(\(detail)) : location.reload()", completionHandler: nil)
            }
        }
    }

    /// Connects folders through the server (in-process or attached) and returns {projectId, source, projects}.
    func attachPaths(_ paths: [String], _ done: @escaping @MainActor ([String: Any]?, String?) -> Void) {
        var last: [String: Any]? = nil
        var error: String? = nil
        func next(_ i: Int) {
            guard i < paths.count else { done(last, last == nil ? error : nil); return }
            post("api/sources", ["path": paths[i]]) { r, e in
                if let r { last = r } else { error = e }
                next(i + 1)
            }
        }
        next(0)
    }

    func post(_ path: String, _ body: [String: Any], _ done: @escaping @MainActor ([String: Any]?, String?) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 600
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let j = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let msg = status == 200 ? nil : ((j?["error"] as? String) ?? err?.localizedDescription ?? "HTTP \(status)")
            Task { @MainActor in done(status == 200 ? j : nil, msg) }
        }.resume()
    }

    func toastError(_ msg: String) {
        let a = NSAlert()
        a.messageText = "Couldn't attach that folder"
        a.informativeText = msg
        a.beginSheetModal(for: window, completionHandler: nil)
    }

    func reveal(_ path: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }
        if isDir.boolValue { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
        else { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }

    // MARK: Menus

    @objc func attachFolderMenu(_ sender: Any?) {
        chooseFolder(title: "Attach Folder", prompt: "Attach") { [weak self] path in
            if let path { self?.attach([path]) }
        }
    }
    @objc func revealCatalog(_ sender: Any?) { reveal(StudioPaths.support.path) }
    @objc func revealExports(_ sender: Any?) {
        guard let u = URL(string: base.absoluteString + "api/settings"), let d = try? Data(contentsOf: u),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let dir = j["exportDir"] as? String else { return }
        reveal(dir)
    }
    @objc func reloadPage(_ sender: Any?) { web.reload() }
    @objc func showLog(_ sender: Any?) { NSWorkspace.shared.open(logURL) }

    func buildMenus() {
        let main = NSMenu()
        func item(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            if let target { i.target = target }
            menu.addItem(i)
        }
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        item(app, "About Baseline Darkroom", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
        app.addItem(.separator())
        item(app, "Hide Baseline Darkroom", #selector(NSApplication.hide(_:)), "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "")
        app.addItem(.separator())
        item(app, "Quit Baseline Darkroom", #selector(NSApplication.terminate(_:)), "q")
        appItem.submenu = app

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "File")
        item(file, "Attach Folder…", #selector(attachFolderMenu(_:)), "o", target: self)
        item(file, "Import Shoot…", #selector(attachFolderMenu(_:)), "i", target: self)
        file.addItem(.separator())
        item(file, "Show Exports in Finder", #selector(revealExports(_:)), "", target: self)
        item(file, "Show Catalog in Finder", #selector(revealCatalog(_:)), "", target: self)
        file.addItem(.separator())
        item(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        fileItem.submenu = file

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        item(edit, "Undo", Selector(("undo:")), "z")
        item(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        editItem.submenu = edit

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        item(view, "Reload", #selector(reloadPage(_:)), "r", target: self)
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        viewItem.submenu = view

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        item(win, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(win, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        winItem.submenu = win
        NSApp.windowsMenu = win

        let helpItem = NSMenuItem(); main.addItem(helpItem)
        let help = NSMenu(title: "Help")
        item(help, "Show Log", #selector(showLog(_:)), "", target: self)
        helpItem.submenu = help

        NSApp.mainMenu = main
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
