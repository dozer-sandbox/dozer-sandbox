import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import SnoozeHost

/// `snooze ui`'s HTTP server (590): swift-nio's own HTTP/1.1 codec (`NIOHTTP1`, an apple/* module
/// the package already resolves) on 127.0.0.1 and an OS-assigned port — nothing else is
/// representable. Every request goes: Host check → closed route table → session → typed read.
///
/// Serving is structured concurrency over `NIOAsyncChannel`: one child task per connection
/// (bounded by `WebLimits.maximumConnections`), requests on a connection one at a time.
///
/// 591: a connection's FIRST request may upgrade to a WebSocket — only the terminal socket, only
/// with a one-use ticket (`admitTerminal`). NIOWebSocket is part of swift-nio (no new package).
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
    let tickets: WebTerminalTicketStore
    let terminals: WebTerminalHub
    private let gate: UpgradeGate
    private let capability: WebBootstrapCapability
    private let listener: NIOAsyncChannel<Accepted, Never>
    private let lock = NSLock()
    private var children: [ObjectIdentifier: Channel] = [:]
    private var closing = false

    public typealias Connection = NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>
    typealias Socket = NIOAsyncChannel<WebSocketFrame, WebSocketFrame>

    /// What a new connection became: plain HTTP, or (first request only) a terminal socket.
    enum Upgrade: Sendable {
        case http(Connection)
        case websocket(Socket, WebTerminalGrant)
    }

    struct Accepted: Sendable {
        let channel: Channel
        let upgrade: EventLoopFuture<Upgrade>
    }

    /// Carries the upgrade decision from NIO's `shouldUpgrade` (which runs the checks) to the
    /// pipeline handler (the grant) or to the HTTP path (the refusal, answered with its status).
    final class UpgradeGate: @unchecked Sendable {
        weak var server: SnoozeWebServer?
        private let lock = NSLock()
        private var grants: [ObjectIdentifier: WebTerminalGrant] = [:]
        private var refusals: [ObjectIdentifier: WebRejection] = [:]

        func shouldUpgrade(_ channel: Channel, _ head: HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?> {
            let id = ObjectIdentifier(channel)
            let promise = channel.eventLoop.makePromise(of: HTTPHeaders?.self)
            promise.completeWithTask { [self] in
                guard let server else { return nil }
                do {
                    let grant = try await server.admitTerminal(head)
                    lock.withLock { grants[id] = grant }
                    var h = HTTPHeaders()
                    for (k, v) in WebSecurity.responseHeaders { h.add(name: k, value: v) }
                    h.add(name: "Sec-WebSocket-Protocol", value: WebSecurity.terminalProtocol)
                    return h
                } catch {
                    lock.withLock { refusals[id] = (error as? WebRejection) ?? .notFound }
                    return nil
                }
            }
            return promise.futureResult
        }

        func takeGrant(_ id: ObjectIdentifier) -> WebTerminalGrant? { lock.withLock { grants.removeValue(forKey: id) } }
        func takeRefusal(_ id: ObjectIdentifier) -> WebRejection? { lock.withLock { refusals.removeValue(forKey: id) } }
        func forget(_ id: ObjectIdentifier) { lock.withLock { grants[id] = nil; refusals[id] = nil } }
    }

    private init(origin: WebOrigin, version: String, limits: WebLimits, assets: WebAssets, data: SnoozeWebData,
                 capability: WebBootstrapCapability, pollInterval: Duration, gate: UpgradeGate,
                 listener: NIOAsyncChannel<Accepted, Never>) {
        self.origin = origin
        self.version = version
        self.limits = limits
        self.assets = assets
        self.data = data
        self.capability = capability
        self.listener = listener
        self.gate = gate
        sessions = WebSessionStore(bootstrap: capability, limits: limits)
        hub = SSEHub(maxClients: limits.maximumSSEClients, capacity: limits.maximumBufferedSSEEvents)
        tickets = WebTerminalTicketStore()
        terminals = WebTerminalHub()
        monitor = WebMonitor(data: data, hub: hub, terminals: terminals, pollInterval: pollInterval)
        operations = WebOperations(data: data, hub: hub, monitor: monitor)
        let (terminals, monitor) = (self.terminals, self.monitor)
        terminals.operations = operations
        terminals.onOpen = { Task { await monitor.streamOpened() } }
        operations.onChange = { ops in terminals.operationsChanged(ops) }
    }

    /// Bind the listener (loopback, ephemeral). `run()` then serves.
    public static func bind(data: SnoozeWebData, assets: WebAssets, version: String, limits: WebLimits = .standard,
                            capability: WebBootstrapCapability = .make(), pollInterval: Duration = .seconds(3),
                            group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> SnoozeWebServer {
        let address = WebLoopbackAddress()
        let gate = UpgradeGate()
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: false)
            .bind(host: address.host, port: address.port) { child in
                child.eventLoop.makeCompletedFuture {
                    let upgrader = NIOTypedWebSocketServerUpgrader<Upgrade>(
                        maxFrameSize: WebTerminalWire.maximumFrameBytes,
                        shouldUpgrade: { ch, head in gate.shouldUpgrade(ch, head) },
                        upgradePipelineHandler: { ch, _ in
                            ch.eventLoop.makeCompletedFuture {
                                guard let grant = gate.takeGrant(ObjectIdentifier(ch)) else { throw WebRejection.ticketMissing }
                                // A fragmented message is reassembled, up to the same cap as one frame.
                                try ch.pipeline.syncOperations.addHandler(NIOWebSocketFrameAggregator(
                                    minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: 256,
                                    maxAccumulatedFrameSize: WebTerminalWire.maximumFrameBytes))
                                return .websocket(try Socket(wrappingChannelSynchronously: ch), grant)
                            }
                        })
                    let upgrades = NIOTypedHTTPServerUpgradeConfiguration<Upgrade>(upgraders: [upgrader]) { ch in
                        ch.eventLoop.makeCompletedFuture { .http(try Connection(wrappingChannelSynchronously: ch)) }
                    }
                    let result = try child.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                        configuration: NIOUpgradableHTTPServerPipelineConfiguration(upgradeConfiguration: upgrades))
                    return Accepted(channel: child, upgrade: result)
                }
            }
        guard let port = listener.channel.localAddress?.port else {
            try? await listener.channel.close()
            throw WebConfigurationError.invalidOrigin
        }
        let server = SnoozeWebServer(origin: try WebOrigin(port: port), version: version, limits: limits, assets: assets, data: data,
                                     capability: capability, pollInterval: pollInterval, gate: gate, listener: listener)
        gate.server = server
        return server
    }

    /// 591 — the terminal socket's upgrade, in order (591.01-DESIGN.md §4.2): exact Host, Origin
    /// required and exact, Fetch Metadata, the route, the one cookie → a live session, the ticket
    /// in the subprotocol → consumed against that session and this sandbox, then room for one more.
    func admitTerminal(_ head: HTTPRequestHead) async throws -> WebTerminalGrant {
        guard let method = WebHTTPMethod(rawValue: head.method.rawValue) else { throw WebRejection.methodNotAllowed }
        let md = metadata(head, method: method, bodyBytes: 0)
        try WebSecurity.checkListener(md, origin, originRequired: true)
        if head.headers["origin"].count > 1 { throw WebRejection.originRejected }
        guard case .terminalSocket(let name)? = WebRoute.parse(method: method, target: head.uri) else { throw WebRejection.notFound }
        let (cookie, ticket) = try WebSecurity.validateTerminalUpgrade(md, origin, subprotocols: head.headers["sec-websocket-protocol"])
        _ = try await sessions.authenticate(cookie)
        let grant = try await tickets.consume(ticket, cookie: cookie, sandbox: name)
        guard terminals.hasRoom() else { throw WebRejection.tooManyTerminals }
        return grant
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
                for try await accepted in inbound {
                    let channel = accepted.channel
                    let admitted: Bool = lock.withLock {
                        guard !closing, children.count < limits.maximumConnections else { return false }
                        children[ObjectIdentifier(channel)] = channel
                        return true
                    }
                    guard admitted else {
                        channel.close(promise: nil)
                        continue
                    }
                    group.addTask {
                        await self.serve(accepted)
                        _ = self.lock.withLock { self.children.removeValue(forKey: ObjectIdentifier(channel)) }
                    }
                }
            }
        }
    }

    /// Stop: no new connections, every stream told `shutdown`, every terminal closed (1001), every
    /// connection closed. Sessions and links die with the process.
    public func close() async {
        let open: [Channel] = lock.withLock {
            closing = true
            return Array(children.values)
        }
        hub.finishAll(.shutdown)
        await terminals.closeAll()
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

    /// A new connection: plain HTTP, or a terminal socket its first request upgraded to.
    private func serve(_ accepted: Accepted) async {
        let id = ObjectIdentifier(accepted.channel)
        defer { gate.forget(id) }
        do {
            switch try await accepted.upgrade.get() {
            case .http(let conn):
                // A refused upgrade: NIO's typed upgrader does not pass the refused request's head on
                // (only what followed it), so the refusal is answered here, from the decision itself,
                // and the connection closed (its decoder has stopped parsing after an upgrade request).
                if let r = gate.takeRefusal(id) { await refuse(conn, r) } else { await serve(conn) }
            case .websocket(let socket, let grant):
                await terminal(socket, grant)
            }
        } catch {
            try? await accepted.channel.close()
        }
    }

    private func refuse(_ conn: Connection, _ r: WebRejection) async {
        try? await conn.executeThenClose { _, outbound in
            try await write(outbound, HTTPRequestHead(version: .http1_1, method: .GET, uri: "/"), error(r), isHead: false, keepAlive: false)
        }
    }

    /// 591 — one browser terminal, for as long as the socket lives.
    private func terminal(_ socket: Socket, _ grant: WebTerminalGrant) async {
        try? await socket.executeThenClose { inbound, outbound in
            let bridge = WebTerminalBridge(grant: grant, data: data, hub: terminals, sessions: sessions, channel: socket.channel, outbound: outbound)
            guard terminals.add(bridge) else {
                await bridge.end(.policyViolation, "too-many-terminals")
                return
            }
            defer { terminals.remove(bridge) }
            await bridge.run(inbound)
        }
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
                    switch await respond(head, body: Data(body.readableBytesView), connection: ObjectIdentifier(conn.channel)) {
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

    func respond(_ head: HTTPRequestHead, body: Data, connection: ObjectIdentifier? = nil) async -> Reply {
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
            // 591: the terminal socket over plain HTTP (no upgrade, or not the connection's first
            // request) is not a terminal. (A refused upgrade is answered in serve(_: Accepted).)
            if case .terminalSocket = route {
                throw connection.flatMap { gate.takeRefusal($0) } ?? WebRejection.upgradeRequired
            }
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
            terminals.closeAll(cookie: cookie)
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
        case .terminalTicket(let name):
            // 591: CSRF-checked (an unsafe method), then a one-use ticket bound to this session.
            try Self.requireJSONBody(md)
            let r = try WebTerminalTicketRequest.decode(body)
            let t = try await tickets.mint(cookie: cookie, sandbox: name, session: r.session, mode: r.mode, size: r.size)
            return json(WebTerminalTicketInfo(ticket: t, expiresInSeconds: Int(tickets.lifetime), session: r.session, mode: r.mode))
        case .terminalSocket:
            throw WebRejection.upgradeRequired            // answered in respond(); never dispatched
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
