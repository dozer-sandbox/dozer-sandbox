import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import SnoozeHost

/// `snooze ui`'s HTTP server (590): swift-nio's own HTTP/1.1 codec (`NIOHTTP1`, an apple/* module
/// the package already resolves) on 127.0.0.1 and an OS-assigned port — nothing else is
/// representable. Every request goes: Host check → closed route table → session → typed read.
///
/// Serving is structured concurrency over `NIOAsyncChannel`: one child task per connection
/// (bounded by `WebLimits.maximumConnections`), requests on a connection one at a time.
public final class SnoozeWebServer: @unchecked Sendable {
    public let origin: WebOrigin
    public let serverRun = UUID().uuidString.lowercased()
    public let version: String
    let limits: WebLimits
    let sessions: WebSessionStore
    let assets: WebAssets
    let data: SnoozeWebData
    let hub: SSEHub
    let monitor: WebMonitor
    let operations: WebOperations
    private let capability: WebBootstrapCapability
    private let listener: NIOAsyncChannel<NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>, Never>
    private let lock = NSLock()
    private var children: [ObjectIdentifier: Channel] = [:]
    private var closing = false

    public typealias Connection = NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>

    private init(origin: WebOrigin, version: String, limits: WebLimits, assets: WebAssets, data: SnoozeWebData,
                 capability: WebBootstrapCapability, pollInterval: Duration,
                 listener: NIOAsyncChannel<Connection, Never>) {
        self.origin = origin
        self.version = version
        self.limits = limits
        self.assets = assets
        self.data = data
        self.capability = capability
        self.listener = listener
        sessions = WebSessionStore(bootstrap: capability, limits: limits)
        hub = SSEHub(maxClients: limits.maximumSSEClients, capacity: limits.maximumBufferedSSEEvents)
        monitor = WebMonitor(data: data, hub: hub, pollInterval: pollInterval)
        operations = WebOperations(data: data, hub: hub, monitor: monitor)
    }

    /// Bind the listener (loopback, ephemeral). `run()` then serves.
    public static func bind(data: SnoozeWebData, assets: WebAssets, version: String, limits: WebLimits = .standard,
                            capability: WebBootstrapCapability = .make(), pollInterval: Duration = .seconds(3),
                            group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> SnoozeWebServer {
        let address = WebLoopbackAddress()
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: false)
            .bind(host: address.host, port: address.port) { child in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: true, withErrorHandling: true)
                    return try Connection(wrappingChannelSynchronously: child)
                }
            }
        guard let port = listener.channel.localAddress?.port else {
            try? await listener.channel.close()
            throw WebConfigurationError.invalidOrigin
        }
        return SnoozeWebServer(origin: try WebOrigin(port: port), version: version, limits: limits, assets: assets, data: data,
                               capability: capability, pollInterval: pollInterval, listener: listener)
    }

    /// The start-up link (its capability works once, for `limits.bootstrapLifetime`). Hand it to a
    /// browser or a TTY — never to a log, a file or a process argument.
    public var launchURL: URL { capability.launchURL(origin: origin) }

    /// A fresh one-use link for this running server (`snooze ui link`).
    public func newLink() async -> URL { await sessions.issue().launchURL(origin: origin) }

    /// Serve until `close()`.
    public func run() async throws {
        try await withThrowingDiscardingTaskGroup { group in
            try await listener.executeThenClose { inbound in
                for try await conn in inbound {
                    let admitted: Bool = lock.withLock {
                        guard !closing, children.count < limits.maximumConnections else { return false }
                        children[ObjectIdentifier(conn.channel)] = conn.channel
                        return true
                    }
                    guard admitted else {
                        conn.channel.close(promise: nil)
                        continue
                    }
                    group.addTask {
                        await self.serve(conn)
                        _ = self.lock.withLock { self.children.removeValue(forKey: ObjectIdentifier(conn.channel)) }
                    }
                }
            }
        }
    }

    /// Stop: no new connections, every stream told `shutdown`, every connection closed. Sessions
    /// and links die with the process.
    public func close() async {
        let open: [Channel] = lock.withLock {
            closing = true
            return Array(children.values)
        }
        hub.finishAll(.shutdown)
        await monitor.stop()
        try? await Task.sleep(for: .milliseconds(100))           // let the streams write their last frame
        try? await listener.channel.close()
        for c in open { c.close(promise: nil) }
    }

    var openConnections: Int { lock.withLock { children.count } }

    // MARK: connections

    enum Reply {
        case response(Int, [(String, String)], Data)
        case stream(SSEClient)
    }

    private func serve(_ conn: Connection) async {
        do {
            try await conn.executeThenClose { inbound, outbound in
                var it = inbound.makeAsyncIterator()
                while let part = try await it.next() {
                    guard case .head(let head) = part else { continue }
                    var body = ByteBuffer()
                    var tooLarge = head.headers["content-length"].contains { (Int($0) ?? Int.max) > limits.maximumRequestBodyBytes }
                    if !tooLarge {
                        reading: while let p = try await it.next() {
                            switch p {
                            case .body(var b):
                                if body.readableBytes + b.readableBytes > limits.maximumRequestBodyBytes { tooLarge = true; break reading }
                                body.writeBuffer(&b)
                            case .end, .head:
                                break reading
                            }
                        }
                    }
                    let isHead = head.method == .HEAD
                    if tooLarge {
                        try await write(outbound, head, error(.bodyTooLarge), isHead: isHead, keepAlive: false)
                        return
                    }
                    switch await respond(head, body: Data(body.readableBytesView)) {
                    case .stream(let client):
                        try await stream(client, conn: conn, outbound: outbound, head: head)
                        return
                    case .response(let status, let headers, let data):
                        try await write(outbound, head, (status, headers, data), isHead: isHead, keepAlive: head.isKeepAlive)
                        if !head.isKeepAlive { return }
                    }
                }
            }
        } catch {
            // A peer that went away mid-response: nothing to tell anyone.
        }
    }

    private func write(_ out: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>, _ req: HTTPRequestHead,
                       _ r: (Int, [(String, String)], Data), isHead: Bool, keepAlive: Bool) async throws {
        var h = HTTPHeaders()
        for (k, v) in WebSecurity.responseHeaders { h.add(name: k, value: v) }
        for (k, v) in r.1 { h.add(name: k, value: v) }
        if !h.contains(name: "cache-control") { h.add(name: "Cache-Control", value: "no-store") }
        h.add(name: "Content-Length", value: String(r.2.count))
        if !keepAlive { h.add(name: "Connection", value: "close") }
        try await out.write(.head(HTTPResponseHead(version: req.version, status: HTTPResponseStatus(statusCode: r.0), headers: h)))
        if !isHead && !r.2.isEmpty { try await out.write(.body(.byteBuffer(ByteBuffer(bytes: r.2)))) }
        try await out.write(.end(nil))
    }

    // MARK: routing

    static func header(_ h: HTTPHeaders, _ name: String) -> String? {
        let v = h[name]
        return v.count == 1 ? v[0] : nil
    }

    func error(_ r: WebRejection) -> (Int, [(String, String)], Data) {
        (r.status, [("Content-Type", "application/json; charset=utf-8")], Self.errorBody(r.rawValue, r.message))
    }

    static func errorBody(_ code: String, _ message: String) -> Data {
        (try? WebJSON.encoder.encode(["error": ["code": code, "message": message]])) ?? Data()
    }

    func json<T: Encodable>(_ v: T, status: Int = 200, extra: [(String, String)] = []) -> Reply {
        guard let d = try? WebJSON.encoder.encode(v) else { return .response(500, [], Self.errorBody("failed", "encoding")) }
        return .response(status, [("Content-Type", "application/json; charset=utf-8")] + extra, d)
    }

    func metadata(_ head: HTTPRequestHead, method: WebHTTPMethod, bodyBytes: Int) -> WebRequestMetadata {
        let h = head.headers
        // Several Cookie headers are legal (HTTP/2 → 1 proxies split them); join them so a duplicate
        // session cookie is still seen as a duplicate.
        let cookie = h["cookie"].isEmpty ? nil : h["cookie"].joined(separator: "; ")
        return WebRequestMetadata(method: method, host: Self.header(h, "host"), origin: Self.header(h, "origin"),
                                  secFetchSite: Self.header(h, "sec-fetch-site"), authorization: Self.header(h, "authorization"),
                                  cookie: cookie, csrfToken: Self.header(h, WebSecurity.csrfHeader),
                                  contentType: Self.header(h, "content-type"), bodyByteCount: bodyBytes)
    }

    func respond(_ head: HTTPRequestHead, body: Data) async -> Reply {
        guard let method = WebHTTPMethod(rawValue: head.method.rawValue) else {
            let e = error(.methodNotAllowed)
            return .response(e.0, e.1, e.2)
        }
        let md = metadata(head, method: method, bodyBytes: body.count)
        do {
            // A duplicated Host or Origin header is not "the" header: `header()` gives nil, refused here.
            try WebSecurity.checkListener(md, origin, originRequired: false)
            if head.headers["origin"].count > 1 { throw WebRejection.originRejected }
            guard let route = WebRoute.parse(method: method, target: head.uri) else { throw WebRejection.notFound }
            return try await dispatch(route, md, body: body)
        } catch let r as WebRejection {
            let e = error(r)
            return .response(e.0, e.1, e.2)
        } catch let e as WebAction.Invalid {
            return .response(400, [("Content-Type", "application/json; charset=utf-8")], Self.errorBody("invalid", e.message))
        } catch let e as TerminalHandoff.Failure {
            return .response(502, [("Content-Type", "application/json; charset=utf-8")], Self.errorBody("terminal", e.message))
        } catch let e as HostError {
            let status = switch e.code {
            case .notFound: 404
            case .invalidPhase: 409
            case .invalid: 400
            case .unavailable, .version: 503
            case .exists: 409
            case .failed, .notImplemented: 500
            }
            return .response(status, [("Content-Type", "application/json; charset=utf-8")], Self.errorBody(e.code.rawValue, e.message))
        } catch {
            return .response(500, [("Content-Type", "application/json; charset=utf-8")], Self.errorBody("failed", "the request failed"))
        }
    }

    /// Actions, the preview and the terminal take a JSON object, always — never a form, never empty.
    static func requireJSONBody(_ md: WebRequestMetadata) throws {
        guard md.bodyByteCount > 0 else { throw WebAction.Invalid("a JSON body is required") }
        guard let t = md.contentType?.lowercased(), t == "application/json" || t.hasPrefix("application/json;") else {
            throw WebRejection.unsupportedMediaType
        }
    }

    /// A sub-route's body (only the action's own fields) as the action it is: `action` and `sandbox`
    /// come from the route, never from the body.
    static func withAction(_ action: String, sandbox: String, _ body: Data) throws -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: body), var d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        guard d["action"] == nil, d["sandbox"] == nil else { throw WebAction.Invalid("action and sandbox come from the path") }
        d["action"] = action
        d["sandbox"] = sandbox
        return try JSONSerialization.data(withJSONObject: d)
    }

    private func sessionInfo(_ s: WebSession) -> WebSessionInfo {
        WebSessionInfo(csrf: s.csrfToken, expiresAt: s.expiresAt, serverRun: serverRun, store: data.storePath, version: version)
    }

    private func dispatch(_ route: WebRoute, _ md: WebRequestMetadata, body: Data) async throws -> Reply {
        let cookieName = WebSecurity.cookieName(origin)
        switch route {
        case .index, .asset:
            try WebSecurity.validateStatic(md, origin)
            let path = if case .asset(let p) = route { p } else { "/" }
            guard let a = assets.assets[path] else { throw WebRejection.notFound }
            return .response(200, [("Content-Type", a.mimeType), ("Cache-Control", a.cachePolicy)], a.data)
        case .sessionBootstrap:
            let cap = try WebSecurity.validateBootstrap(md, origin, limit: limits.maximumRequestBodyBytes)
            let s = try await sessions.exchange(cap)
            return json(sessionInfo(s), extra: [("Set-Cookie", WebSecurity.setCookie(s.cookieValue, name: cookieName,
                                                                                     maxAge: s.expiresAt.timeIntervalSinceNow))])
        default:
            break
        }
        let cookie = try WebSecurity.validateAuthenticated(md, origin, limit: limits.maximumRequestBodyBytes)
        let session = md.method.isSafe ? try await sessions.authenticate(cookie)
                                       : try await sessions.authenticateMutation(cookie, csrf: md.csrfToken)
        switch route {
        case .index, .asset, .sessionBootstrap:
            throw WebRejection.notFound
        case .sessionInfo:
            return json(sessionInfo(session))
        case .sessionRenew:
            let s = try await sessions.renew(cookie)
            return json(sessionInfo(s), extra: [("Set-Cookie", WebSecurity.setCookie(s.cookieValue, name: cookieName,
                                                                                     maxAge: s.expiresAt.timeIntervalSinceNow))])
        case .sessionEnd:
            await sessions.revoke(cookie)
            for c in hub.all where c.cookie == cookie { c.finish(.sessionEnded) }
            return .response(204, [("Set-Cookie", WebSecurity.clearCookie(name: cookieName))], Data())
        case .overview:
            return json(try await data.overview())
        case .sandbox(let name):
            return json(try await data.sandbox(name))
        case .sandboxSessions(let name):
            return json(try await data.sessions(name))
        case .sandboxNetwork(let name):
            return json(try await data.network(name))
        case .images:
            return json(try await data.images())
        case .accounts:
            return json(try await data.accounts())
        case .metrics(let q):
            return json(try await data.metrics(q))
        case .metricsCSV(let q):
            return .response(200, [("Content-Type", "text/csv; charset=utf-8"),
                                   ("Content-Disposition", "attachment; filename=\"snooze-metrics.csv\"")], try await data.metricsCSV(q))
        case .operations:
            return json(operations.recent)
        case .actions:
            try Self.requireJSONBody(md)
            let action = try WebAction.decode(body)
            return json(try operations.start(action), status: 202)
        case .policyPreview(let name):
            try Self.requireJSONBody(md)
            guard case .netPolicy(_, let edit) = try WebAction.decode(Self.withAction("net-policy", sandbox: name, body)) else {
                throw WebRejection.notFound
            }
            return json(try await data.policyPreview(name, edit))
        case .terminal(let name):
            try Self.requireJSONBody(md)
            guard case .openSession(_, let session, nil) = try WebAction.decode(Self.withAction("open-session", sandbox: name, body)) else {
                throw WebAction.Invalid("terminal: only a session may be given")
            }
            return json(["message": try await data.openTerminal(name, session: session)])
        case .events:
            return json(await monitor.recent)
        case .doctor:
            return json(try await data.doctor())
        case .stream:
            guard let client = hub.add(cookie: cookie) else { throw WebRejection.tooManyStreams }
            await monitor.streamOpened()
            return .stream(client)
        }
    }

    // MARK: server-sent events

    private func stream(_ client: SSEClient, conn: Connection, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>,
                        head: HTTPRequestHead) async throws {
        defer { hub.remove(client) }
        var h = HTTPHeaders()
        for (k, v) in WebSecurity.responseHeaders { h.add(name: k, value: v) }
        h.add(name: "Content-Type", value: "text/event-stream; charset=utf-8")
        h.add(name: "Cache-Control", value: "no-store")
        try await outbound.write(.head(HTTPResponseHead(version: head.version, status: .ok, headers: h)))
        // `hello` first: the page (re)fetches everything on it — every (re)connect is a resync.
        let hello = (try? WebJSON.encoder.encode(["serverRun": serverRun])) ?? Data()
        try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: SSEFrame(event: "hello", id: hub.nextSeq(), json: hello).bytes))))
        conn.channel.closeFuture.whenComplete { _ in client.finish(.clientGone) }
        let sessions = self.sessions, cookie = client.cookie, beat = limits.heartbeatInterval, channel = conn.channel
        let heartbeat = Task {
            var overflowSince: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int(beat * 1000)))
                if Task.isCancelled { return }
                if client.end == .overflow {
                    // Ended for overflow but the writer is stuck on a peer that reads nothing: close it.
                    if let t = overflowSince, Date().timeIntervalSince(t) > max(1, beat) { channel.close(promise: nil); return }
                    overflowSince = overflowSince ?? Date()
                    continue
                }
                guard await sessions.isValid(cookie) else { client.finish(.sessionEnded); return }
                client.send(SSEFrame(comment: "ping"))
            }
        }
        defer { heartbeat.cancel() }
        for await f in client.frames {
            try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: f.bytes))))
        }
        let last: String? = switch client.end {
        case .overflow: "resync"
        case .sessionEnded: "session-ended"
        case .shutdown: "shutdown"
        case .replaced: "replaced"
        case .clientGone, nil: nil
        }
        if let last {
            let d = (try? WebJSON.encoder.encode(["reason": last])) ?? Data()
            try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: SSEFrame(event: last == "resync" ? "resync" : "end", id: hub.nextSeq(), json: d).bytes))))
        }
        try await outbound.write(.end(nil))
    }
}
