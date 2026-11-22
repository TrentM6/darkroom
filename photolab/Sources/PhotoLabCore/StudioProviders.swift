import Foundation

// The critique's AI providers besides Claude Code: the Anthropic API and the OpenAI API, each with the
// photographer's own key. Both get the same brief and prompt as Claude Code, with the two photos attached
// as images instead of opened with the Read tool, and answer with the same JSON.

/// API keys, kept out of library.json in their own file (owner-only permissions) in the catalog folder.
/// Never logged, never returned by the API (only whether one is set, and its last four characters).
struct StudioSecrets {
    let url: URL
    init(root: URL) { url = root.appendingPathComponent("secrets.json") }

    func all() -> [String: String] {
        guard let d = FileManager.default.contents(atPath: url.path),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: String] else { return [:] }
        return o
    }
    func get(_ name: String) -> String? { all()[name].flatMap { $0.isEmpty ? nil : $0 } }
    func set(_ name: String, _ value: String?) {
        var o = all()
        let v = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if v.isEmpty { o[name] = nil } else { o[name] = v }
        let fm = FileManager.default
        if o.isEmpty { try? fm.removeItem(at: url); return }
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        let tmp = url.appendingPathExtension("tmp")
        fm.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600])
        _ = try? fm.replaceItemAt(url, withItemAt: tmp)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func hint(_ name: String) -> String? { get(name).map { "…" + String($0.suffix(4)) } }
}

enum StudioProviders {
    static let anthropicDefault = "claude-opus-5-5"
    /// OpenAI's flagship as of this writing; editable in Settings if OpenAI renames it.
    static let openAIDefault = "gpt-6.2-astra"
    static func defaultModel(_ provider: String) -> String? {
        provider == "anthropic" ? anthropicDefault : provider == "openai" ? openAIDefault : nil
    }

    /// Models that take the server-side refusal fallback ("default" routing).
    static let fallbackModels: Set<String> = ["claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    /// One HTTPS request, waited for (the critique runs on its own queue).
    static func send(_ req: URLRequest, timeout: TimeInterval) -> (Int, Data, Error?) {
        var r = req
        r.timeoutInterval = timeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout; cfg.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        var out: (Int, Data, Error?) = (0, Data(), nil)
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: r) { d, resp, e in
            out = ((resp as? HTTPURLResponse)?.statusCode ?? 0, d ?? Data(), e)
            done.signal()
        }.resume()
        done.wait()
        return out
    }

    static func json(_ d: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }

    static func b64(_ url: URL) -> String? { (try? Data(contentsOf: url))?.base64EncodedString() }

    // MARK: Anthropic

    static func anthropicRequest(_ path: String, key: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.anthropic.com" + path)!)
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        return r
    }

    static func anthropicError(_ status: Int, _ d: Data, _ e: Error?) -> StudioAI.Failure {
        if let e { return StudioAI.Failure(message: "Couldn't reach Anthropic: \(e.localizedDescription)") }
        let err = json(d)?["error"] as? [String: Any]
        let type = err?["type"] as? String ?? "", msg = err?["message"] as? String ?? ""
        let detail = "\(status) \(type): \(msg)"
        switch (status, type) {
        case (401, _), (_, "authentication_error"): return .init(message: "That Anthropic API key isn't valid. Check it in Settings.", detail: detail)
        case (402, _), (_, "billing_error"): return .init(message: "Your Anthropic account needs credit (console.anthropic.com).", detail: detail)
        case (403, _), (_, "permission_error"): return .init(message: "This Anthropic API key isn't allowed to use that model.", detail: detail)
        case (404, _), (_, "not_found_error"): return .init(message: "That Claude model isn't available to this API key. Check the model in Settings.", detail: detail)
        case (413, _): return .init(message: "The photo was too large to send.", detail: detail)
        case (429, _): return .init(message: "Your Anthropic rate or spend limit is reached. Try again later.", detail: detail)
        case (500...599, _): return .init(message: "Claude is busy right now. Try again in a minute.", detail: detail, retryable: true)
        default: return .init(message: "Anthropic reported an error: \(msg.isEmpty ? "HTTP \(status)" : String(msg.prefix(160)))", detail: detail)
        }
    }

    static func runAnthropic(key: String, model: String, system: String, prompt: String, original: URL, edit: URL) -> Result<AICritique, StudioAI.Failure> {
        guard let o = b64(original), let e = b64(edit) else { return .failure(.init(message: "The photo couldn't be read.")) }
        var body: [String: Any] = [
            "model": model, "max_tokens": 16000, "system": system,
            "messages": [["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": o]],
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": e]],
                ["type": "text", "text": prompt],
            ]]],
        ]
        if !model.contains("haiku-4") { body["output_config"] = ["effort": "high"] }
        var r = anthropicRequest("/v1/messages", key: key)
        if fallbackModels.contains(model) {
            body["fallbacks"] = "default"
            r.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        r.httpMethod = "POST"
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (status, d, err) = send(r, timeout: 300)
        guard status == 200, let j = json(d) else { return .failure(anthropicError(status, d, err)) }
        if j["stop_reason"] as? String == "refusal" { return .failure(.init(message: "Claude declined to critique this photo.")) }
        let text = ((j["content"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        if let c = StudioAI.decode(StudioAI.jsonCandidates(text)) { return .success(c) }
        let cut = j["stop_reason"] as? String == "max_tokens"
        return .failure(.init(message: cut ? "Claude's answer was cut off. Try again." : "Claude's answer couldn't be read.", detail: String(text.prefix(600)), retryable: true))
    }

    // MARK: OpenAI

    static func openAIRequest(_ path: String, key: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.openai.com" + path)!)
        r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }

    static func openAIError(_ status: Int, _ d: Data, _ e: Error?) -> StudioAI.Failure {
        if let e { return .init(message: "Couldn't reach OpenAI: \(e.localizedDescription)") }
        let err = json(d)?["error"] as? [String: Any]
        let code = (err?["code"] as? String) ?? (err?["type"] as? String) ?? "", msg = err?["message"] as? String ?? ""
        let detail = "\(status) \(code): \(msg)"
        switch (status, code) {
        case (401, _), (_, "invalid_api_key"): return .init(message: "That OpenAI API key isn't valid. Check it in Settings.", detail: detail)
        case (_, "insufficient_quota"): return .init(message: "Your OpenAI account is out of credit (platform.openai.com).", detail: detail)
        case (404, _), (_, "model_not_found"): return .init(message: "That OpenAI model isn't available to this key. Check the model in Settings.", detail: detail)
        case (429, _): return .init(message: "Your OpenAI rate limit is reached. Try again later.", detail: detail)
        case (500...599, _): return .init(message: "OpenAI is busy right now. Try again in a minute.", detail: detail, retryable: true)
        default: return .init(message: "OpenAI reported an error: \(msg.isEmpty ? "HTTP \(status)" : String(msg.prefix(160)))", detail: detail)
        }
    }

    static func runOpenAI(key: String, model: String, system: String, prompt: String, original: URL, edit: URL) -> Result<AICritique, StudioAI.Failure> {
        guard let o = b64(original), let e = b64(edit) else { return .failure(.init(message: "The photo couldn't be read.")) }
        let body: [String: Any] = [
            "model": model, "instructions": system,
            "input": [["role": "user", "content": [
                ["type": "input_image", "image_url": "data:image/jpeg;base64," + o],
                ["type": "input_image", "image_url": "data:image/jpeg;base64," + e],
                ["type": "input_text", "text": prompt],
            ]]],
        ]
        var r = openAIRequest("/v1/responses", key: key)
        r.httpMethod = "POST"
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (status, d, err) = send(r, timeout: 300)
        guard status == 200, let j = json(d) else { return .failure(openAIError(status, d, err)) }
        var text = (j["output_text"] as? String) ?? ""
        if text.isEmpty {
            for item in (j["output"] as? [[String: Any]]) ?? [] where item["type"] as? String == "message" {
                for c in (item["content"] as? [[String: Any]]) ?? [] {
                    if c["type"] as? String == "refusal" { return .failure(.init(message: "The model declined to critique this photo.")) }
                    if c["type"] as? String == "output_text", let t = c["text"] as? String { text += t }
                }
            }
        }
        if let c = StudioAI.decode(StudioAI.jsonCandidates(text)) { return .success(c) }
        return .failure(.init(message: "The model's answer couldn't be read.", detail: String(text.prefix(600)), retryable: true))
    }

    // MARK: Key check (lists models: costs nothing)

    static func test(provider: String, key: String) -> (ok: Bool, message: String) {
        let r = provider == "anthropic" ? anthropicRequest("/v1/models?limit=1", key: key) : openAIRequest("/v1/models", key: key)
        let (status, d, err) = send(r, timeout: 20)
        if status == 200 { return (true, "Connected") }
        let f = provider == "anthropic" ? anthropicError(status, d, err) : openAIError(status, d, err)
        return (false, f.message)
    }
}
