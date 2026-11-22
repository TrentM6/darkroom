import Foundation

// Onboarding and Settings: the critique panel, the AI provider (and its key), where My Look starts, and
// whether onboarding has been done. GET/POST /api/setup.

extension Studio {
    /// The look learning starts from and falls back to: the onboarding choice, else Kodachrome.
    var starterLook: LookParams { sync { lib.starter ?? .kodachrome } }

    /// The panel critiques use (caller holds the lock). nil (the original brief) only for a library from before
    /// panels could be chosen; any other library without a choice yet gets the first ready-made group.
    func effectivePanelLocked() -> [String]? {
        if let p = lib.ai.panel { return p }
        let legacy = lib.onboarded == nil && !(lib.projects.isEmpty && lib.sources.isEmpty)
        return legacy ? nil : StudioPanel.groups[0].ids
    }

    /// A library made before onboarding existed, with projects in it, counts as onboarded.
    var needsOnboarding: Bool { sync { lib.onboarded != true && lib.projects.isEmpty && lib.sources.isEmpty } }

    public func setupJSON() -> [String: Any] {
        let (ai, starter) = sync { (lib.ai, lib.starter) }
        let s = secrets
        let none: Any = NSNull()
        let aiSetup: [String: Any] = [
            "enabled": ai.isEnabled,
            "provider": ai.activeProvider,
            "model": ai.model ?? none,
            "ready": aiReady == nil,
            "problem": aiReady ?? none,
            "claudeCode": ["installed": StudioAI.cli != nil, "account": ai.allowedAccount.isEmpty ? none : ai.allowedAccount] as [String: Any],
            "anthropic": ["hasKey": s.get("anthropic") != nil, "hint": s.hint("anthropic") ?? none, "defaultModel": StudioProviders.anthropicDefault] as [String: Any],
            "openai": ["hasKey": s.get("openai") != nil, "hint": s.hint("openai") ?? none, "defaultModel": StudioProviders.openAIDefault] as [String: Any],
        ]
        let legacy = sync { lib.onboarded == nil && !(lib.projects.isEmpty && lib.sources.isEmpty) }
        let starterId = starter.flatMap { st in StudioStarter.all.first { $0.look.clamped(lutRoot: lutRoot) == st }?.id } ?? (starter == nil ? "kodachrome" : "custom")
        return [
            "needsOnboarding": needsOnboarding,
            "panel": [
                "ids": ai.panel ?? StudioPanel.defaultIds,
                "isDefault": StudioPanel.isDefault(sync { effectivePanelLocked() }),
                // A panel picked in setup, or a library from before panels could be picked (it has the original six).
                "chosen": ai.panel != nil || legacy,
                "group": StudioPanel.groupId(ai.panel ?? StudioPanel.defaultIds) ?? NSNull(),
                "max": StudioPanel.maxPanel,
                "seats": StudioPanel.seatsJSON(ai.panel),
            ] as [String: Any],
            "catalog": StudioPanel.catalogJSON(),
            "groups": StudioPanel.groups.map { g in
                ["id": g.id, "name": g.name, "note": g.note, "ids": g.ids, "seats": g.seats,
                 "film": StudioPanel.suggestedStarter(g.ids)] as [String: Any] },
            "genres": StudioPanel.genres.map { ["id": $0.id, "label": $0.label] },
            "seats": StudioPanel.seats.map { ["id": $0.id, "label": $0.label, "question": $0.question] },
            "ai": aiSetup,
            "starters": StudioStarter.all.map { ["id": $0.id, "name": $0.name, "note": $0.note, "film": $0.look.film] },
            "starter": starterId,
            // rawTherapee: its CLI was found and actually runs (a probe, cached per file), not just that a file exists.
            "checks": ["rawTherapee": rawTherapeeProblem == nil, "rawTherapeeProblem": rawTherapeeProblem ?? none,
                       "films": lutRoot != nil, "library": root.path] as [String: Any],
        ]
    }

    /// Why RawTherapee can't render: nil, "notInstalled" (no /Applications/RawTherapee.app) or "broken" (no copy
    /// of its CLI runs, or it kept crashing on launch).
    public var rawTherapeeProblem: String? { StudioPaths.rawTherapeeProblem(rt) }

    /// The user-facing line for `rawTherapeeProblem` (the part before ";" is the short form).
    var rawTherapeeError: String? {
        switch rawTherapeeProblem {
        case "notInstalled"?: return "RawTherapee isn't installed (/Applications/RawTherapee.app); previews and export are unavailable"
        case "broken"?: return "RawTherapee can't run; previews and export are unavailable until it's repaired in Settings"
        default: return nil
        }
    }

    /// Repair (Settings, onboarding): copies rawtherapee-cli from /Applications/RawTherapee.app into the support
    /// folder again, signed ad hoc, if no copy runs; then renders what failed. True when RawTherapee now runs.
    @discardableResult
    public func repairRawTherapee() -> Bool {
        let old = rt, gaveUp = old.map { RawTherapeeCLI.isDisabled($0) } ?? false
        if let cur = old { RawTherapeeCLI.forget(cur) }
        var found = StudioPaths.rawTherapee(log: log)
        // The CLI given up on answers `-v` but crashed in renders: make a fresh copy instead of choosing it again.
        if found == nil || (gaveUp && found == old) {
            found = RawTherapeeCLI.install(from: RawTherapeeCLI.appCLI, to: StudioPaths.supportCLI, log: log) ? StudioPaths.supportCLI : nil
        }
        rtLock.lock(); _rt = found; rtLock.unlock()
        sync { renderFailures.removeAll(); failingRenders = 0 }
        log("RawTherapee \(found.map { "now at \($0.path)" } ?? "still unavailable")")
        if found != nil { scanQueue.async { [weak self] in self?.rescanAll() } }
        return found != nil
    }

    /// Who Claude Code is signed in as (runs `claude auth status`, about 0.2 s; no model call).
    public func claudeCodeStatus() -> [String: Any] {
        guard let cli = StudioAI.cli else { return ["installed": false, "signedIn": false] }
        switch StudioAI.signedInAccount(cli: cli) {
        case .signedIn(let e): return ["installed": true, "signedIn": true, "account": e]
        case .signedOut: return ["installed": true, "signedIn": false]
        case .unknown: return ["installed": true, "signedIn": true, "account": NSNull() as Any]
        }
    }

    /// Applies any of {enabled, panel, provider, model, keys:{anthropic, openai}, starter, onboarded}.
    public func applySetup(_ b: [String: Any]) throws {
        if let raw = b["panel"] {
            guard let ids = raw as? [String] else { throw StudioError.bad("panel must be an array of photographer ids") }
            let clean = StudioPanel.clean(ids)
            guard !clean.isEmpty else { throw StudioError.bad("choose at least one photographer") }
            // The original six, in any order, get the original brief word for word (StudioPanel.isDefault).
            sync { lib.ai.panel = clean; markDirty("") }
        }
        if let keys = b["keys"] as? [String: Any] {
            for name in ["anthropic", "openai"] where keys.keys.contains(name) { secrets.set(name, keys[name] as? String) }
        }
        if let p = b["provider"] as? String {
            guard AISettings.providers.contains(p) else { throw StudioError.bad("provider must be one of \(AISettings.providers.joined(separator: ", "))") }
            sync { lib.ai.provider = p; markDirty("") }
        }
        if b.keys.contains("model") {
            let m = (b["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            sync { lib.ai.model = m.isEmpty ? nil : String(m.prefix(80)); markDirty("") }
        }
        if let id = b["starter"] as? String {
            guard let look = StudioStarter.look(id) else { throw StudioError.bad("unknown starter \(id)") }
            // Where My Look starts is chosen once, in onboarding, before there are photos to change.
            guard sync({ lib.projects.isEmpty }) else { throw StudioError.bad("the starting look can only be chosen before the first folder is attached") }
            let l = look.clamped(lutRoot: lutRoot)
            sync { lib.starter = id == "kodachrome" ? nil : l; markDirty("") }
            // Only before there's learning to keep: a fresh library takes the starter as its look.
            if sync({ lib.learned == nil && !lib.lookPinned }) { _ = setLook(l) }
        }
        if let on = b["enabled"] as? Bool { sync { lib.ai.enabled = on; markDirty("") } }
        if let done = b["onboarded"] as? Bool { sync { lib.onboarded = done; markDirty("") } }
    }
}
