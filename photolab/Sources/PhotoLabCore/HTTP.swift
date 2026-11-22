import Foundation
import Network

/// A minimal HTTP/1.1 server on 127.0.0.1 (one request per connection).
/// Safety for a local server: requests whose Host isn't 127.0.0.1/localhost (DNS rebinding) or whose
/// Origin is another site (cross-site requests from a web page) are refused.
public final class HTTPServer {
    public struct Request {
        public var method: String
        public var path: String
        public var query: [String: String]
        public var headers: [String: String]
        public var body: Data
        public var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
        public var jsonAny: Any? { body.isEmpty ? nil : try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) }
    }

    public struct Response {
        public var status: Int
        public var type: String
        public var body: Data
        public var cache: String = "no-store"
        public var headers: [String: String] = [:]
        public static func json(_ obj: Any, status: Int = 200) -> Response {
            // JSONSerialization raises (uncatchable) on invalid objects: check first and answer 500 instead of crashing.
            guard JSONSerialization.isValidJSONObject(obj) || obj is String || obj is NSNumber || obj is NSNull else {
                FileHandle.standardError.write(Data("[http] invalid JSON object for response\n".utf8))
                return Response(status: 500, type: "application/json; charset=utf-8", body: Data("{\"error\":\"internal: invalid JSON\"}".utf8))
            }
            let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .fragmentsAllowed])) ?? Data("{}".utf8)
            return Response(status: status, type: "application/json; charset=utf-8", body: d)
        }
        public static func error(_ status: Int, _ msg: String) -> Response { json(["error": msg], status: status) }
        public static let ok = json(["ok": true])
    }

    let handler: (Request) -> Response
    let queue = DispatchQueue(label: "photolab.http", qos: .userInitiated, attributes: .concurrent)
    var listener: NWListener?
    public private(set) var port: UInt16 = 0
    let log: (String) -> Void

    public init(log: @escaping (String) -> Void, handler: @escaping (Request) -> Response) {
        self.handler = handler
        self.log = log
    }

    /// Starts listening (port 0 = any free port) and returns the port once ready.
    @discardableResult
    public func start(port requested: UInt16) throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: requested == 0 ? .any : NWEndpoint.Port(rawValue: requested)!)
        let l = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { st in
            switch st {
            case .ready: ready.signal()
            case .failed(let e): failure = e; ready.signal()
            default: break
            }
        }
        l.start(queue: queue)
        listener = l
        if ready.wait(timeout: .now() + 10) == .timedOut { throw StudioError.failed("the server didn't start") }
        if let failure { throw StudioError.failed("can't listen on 127.0.0.1:\(requested): \(failure)") }
        port = l.port?.rawValue ?? requested
        return port
    }

    public func stop() { listener?.cancel(); listener = nil }

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
                let resp = self.guarded(req)
                self.send(c, resp, head: req.method == "HEAD")
            case .some(.none):
                self.send(c, .error(400, "bad request"), head: false)
            case .none:
                if complete || error != nil || buf.count > 16 << 20 { c.cancel() } else { self.receive(c, buf) }
            }
        }
    }

    private func guarded(_ req: Request) -> Response {
        let host = (req.headers["host"] ?? "").lowercased()
        let hostName = host.split(separator: ":").first.map(String.init) ?? ""
        guard ["127.0.0.1", "localhost", "[::1]"].contains(hostName) else { return .error(403, "forbidden host") }
        if let origin = req.headers["origin"]?.lowercased(), origin != "null" {
            let ok = ["http://127.0.0.1", "http://localhost"].contains { origin == $0 + ":\(port)" || origin == $0 }
            if !ok { return .error(403, "cross-origin requests are not allowed") }
        }
        return handler(req)
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
        guard length >= 0, length <= 16 << 20 else { return .some(nil) }
        let bodyStart = end.upperBound
        if buf.count - (bodyStart - buf.startIndex) < length { return nil }
        let target = String(first[1])
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        var query: [String: String] = [:]
        if parts.count > 1 {
            for kv in parts[1].split(separator: "&") {
                let p = kv.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                query[p[0]] = p.count > 1 ? p[1] : ""
            }
        }
        return .some(Request(method: String(first[0]).uppercased(), path: path, query: query,
                             headers: headers, body: Data(buf[bodyStart..<(bodyStart + length)])))
    }

    static let reasons = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                          409: "Conflict", 500: "Internal Server Error", 503: "Service Unavailable"]

    private func send(_ c: NWConnection, _ r: Response, head: Bool) {
        var h = "HTTP/1.1 \(r.status) \(Self.reasons[r.status] ?? "OK")\r\nContent-Type: \(r.type)\r\nContent-Length: \(r.body.count)\r\n"
        h += "Cache-Control: \(r.cache)\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n"
        for (k, v) in r.headers { h += "\(k): \(v)\r\n" }
        h += "\r\n"
        var out = Data(h.utf8)
        if !head { out.append(r.body) }
        c.send(content: out, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }

    public static let types: [String: String] = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8", "css": "text/css; charset=utf-8", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "png": "image/png", "svg": "image/svg+xml", "webp": "image/webp", "gif": "image/gif", "ico": "image/x-icon",
        "txt": "text/plain; charset=utf-8", "woff2": "font/woff2", "woff": "font/woff", "map": "application/json; charset=utf-8",
    ]
}
