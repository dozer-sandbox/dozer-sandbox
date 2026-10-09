import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import DozerHost

/// `doz ui`'s HTTP server (590): swift-nio's own HTTP/1.1 codec (`NIOHTTP1`, an apple/* module
/// the package already resolves) on 127.0.0.1 and an OS-assigned port — nothing else is
/// representable. Every request goes: Host check → closed route table → session → typed read.
///
/// Serving is structured concurrency over `NIOAsyncChannel`: one child task per connection
/// (bounded by `WebLimits.maximumConnections`), requests on a connection one at a time.
///
/// 591: a connection's FIRST request may upgrade to a WebSocket — only the terminal socket, only
/// with a one-use ticket (`admitTerminal`). NIOWebSocket is part of swift-nio (no new package).
public final class DozerWebServer: @unchecked Sendable {
    public let origin: WebOrigin
    public let serverRun = UUID().uuidString.lowercased()
    public let version: String
    let limits: WebLimits
    let sessions: WebSessionStore
    let assets: WebAssets
    let data: DozerWebData
    let hub: SSEHub
    let monitor: WebMonitor
    let operations: WebOperations
    let tickets: WebTerminalTicketStore
    let terminals: WebTerminalHub
    /// 591: doz.toml as this process sees it.
    public let settings: WebSettingsStore
    /// 594: the Mac's folder picker (one at a time; DOZ_TEST_FOLDER_PICKER in tests).
    public let folderPicker: WebFolderPicker
    /// 596: the Mac's file picker for a Dockerfile (one at a time; DOZ_TEST_FILE_PICKER in tests).
    public let dockerfilePicker: WebDockerfilePicker
    private let gate: UpgradeGate
    private let capability: WebBootstrapCapability
    private let listeners: [NIOAsyncChannel<Accepted, Never>]
    /// 606: how a request signs in — doz ui's browser sessions, or doz serve's devices.
    let auth: WebAuth
    /// 606: doz serve's own state (nil: doz ui, loopback — 590).
    public let serveState: WebServeState?
    private let lock = NSLock()
    private var children: [ObjectIdentifier: Channel] = [:]
    private var closing = false
    /// 606: doz serve's connections answered with a refusal instead of served (never a silent drop but a sandbox's).
    private var refusedConnections: [ObjectIdentifier: WebRejection] = [:]
    func connectionRefusal(_ id: ObjectIdentifier) -> WebRejection? { lock.withLock { refusedConnections[id] } }
    private var _advertised: String?
    /// 606: doz serve's Bonjour name once registered (said by `GET /api/v1/serve`).
    public var advertised: String? {
        get { lock.withLock { _advertised } }
        set { lock.withLock { _advertised = newValue } }
    }

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
        weak var server: DozerWebServer?
        private let lock = NSLock()
        private var grants: [ObjectIdentifier: WebTerminalGrant] = [:]
        private var refusals: [ObjectIdentifier: WebRejection] = [:]

        func shouldUpgrade(_ channel: Channel, _ head: HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?> {
            let id = ObjectIdentifier(channel)
            let promise = channel.eventLoop.makePromise(of: HTTPHeaders?.self)
            promise.completeWithTask { [self] in
                guard let server else { return nil }
                do {
                    if let r = server.connectionRefusal(id) { throw r }      // 606: a refused doz serve connection
                    let grant = try await server.admitTerminal(head, peer: channel.remoteAddress)
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

    private init(origin: WebOrigin, version: String, limits: WebLimits, assets: WebAssets, data: DozerWebData,
                 capability: WebBootstrapCapability, pollInterval: Duration, gate: UpgradeGate,
                 listeners: [NIOAsyncChannel<Accepted, Never>], settings: WebSettingsStore, sessionsFile: URL?,
                 revokedFile: URL?, operationsFile: URL?, serveState: WebServeState? = nil) {
        self.origin = origin
        self.settings = settings
        folderPicker = WebFolderPicker(environment: settings.environment)
        dockerfilePicker = WebDockerfilePicker(environment: settings.environment)
        self.version = version
        self.limits = limits
        self.assets = assets
        self.data = data
        self.capability = capability
        self.listeners = listeners
        self.gate = gate
        self.serveState = serveState
        sessions = WebSessionStore(bootstrap: capability, limits: limits, persist: sessionsFile, port: origin.port, revoked: revokedFile)
        auth = serveState.map { .devices($0.devices) } ?? .browser(sessions)
        hub = SSEHub(maxClients: limits.maximumSSEClients, capacity: limits.maximumBufferedSSEEvents)
        tickets = WebTerminalTicketStore()
        terminals = WebTerminalHub()
        monitor = WebMonitor(data: data, hub: hub, terminals: terminals, pollInterval: pollInterval)
        operations = WebOperations(data: data, hub: hub, monitor: monitor, file: operationsFile)
        let ops = operations
        monitor.overviewHook.set { ops.reconcile($0) }
        let (terminals, monitor) = (self.terminals, self.monitor)
        terminals.operations = operations
        terminals.onOpen = { Task { await monitor.streamOpened() } }
        operations.onChange = { ops in terminals.operationsChanged(ops) }
    }

    /// Bind the listener (loopback; the OS's port, or `address`'s reused one — 594 W18 — falling
    /// back to the OS's when it is taken, unless `fixedPort`: 605's `ui.port` set to a port, which never
    /// moves silently). `run()` then serves. `settings`: the settings file this UI reads and writes
    /// (591) — `doz ui` passes its own environment; the default reads no file (every setting at its
    /// default: tests that do not test settings never see a real one). 605: `revokedFile` keeps why a
    /// cookie no longer signs in; `operationsFile` the operations ring across a restart.
    public static func bind(data: DozerWebData, assets: WebAssets, version: String, limits: WebLimits = .standard,
                            settings: WebSettingsStore = WebSettingsStore(environment: [:]),
                            capability: WebBootstrapCapability = .make(), pollInterval: Duration = .seconds(3),
                            address: WebLoopbackAddress = WebLoopbackAddress(), fixedPort: Bool = false, sessionsFile: URL? = nil,
                            revokedFile: URL? = nil, operationsFile: URL? = nil,
                            group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> DozerWebServer {
        let gate = UpgradeGate()
        let listener: NIOAsyncChannel<Accepted, Never>
        do {
            listener = try await listen(host: address.host, port: address.port, gate: gate, group: group)
        } catch where address.port != 0 && !fixedPort {
            // 594 W18: the last port is taken after all (a race with its check): the OS picks.
            listener = try await listen(host: WebLoopbackAddress.host, port: 0, gate: gate, group: group)
        }
        guard let port = listener.channel.localAddress?.port else {
            try? await listener.channel.close()
            throw WebConfigurationError.invalidOrigin
        }
        let server = DozerWebServer(origin: try WebOrigin(port: port), version: version, limits: limits, assets: assets, data: data,
                                     capability: capability, pollInterval: pollInterval, gate: gate, listeners: [listener],
                                     settings: settings, sessionsFile: sessionsFile, revokedFile: revokedFile, operationsFile: operationsFile)
        gate.server = server
        return server
    }

    /// 606: `doz serve` — the same server on the LAN (`serve.bind`: the wildcard, each connection's local address
    /// checked; loopback; or the Mac's own addresses), signed in by devices (`WebDeviceStore`), every request
    /// judged by `WebServeRules` and `WebExposure`. `serve.port` 0 is a test's ephemeral port.
    public static func bindServe(data: DozerWebData, assets: WebAssets, version: String, limits: WebLimits, settings: WebSettingsStore,
                                 serve: WebServeState, pollInterval: Duration = .seconds(3), operationsFile: URL? = nil,
                                 group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> DozerWebServer {
        let gate = UpgradeGate()
        let hosts: [String] = switch serve.config.bind {
        case .lan: ["::"]
        case .loopback: ["127.0.0.1", "::1"]
        case .addresses(let ips): ips.map(\.description)
        }
        var listeners: [NIOAsyncChannel<Accepted, Never>] = []
        var port = serve.config.port
        do {
            for h in hosts {
                let l: NIOAsyncChannel<Accepted, Never>
                do {
                    l = try await listen(host: h, port: port, gate: gate, group: group)
                } catch where h == "::1" && !listeners.isEmpty {
                    continue                                   // no IPv6 loopback on this Mac: 127.0.0.1 serves
                }
                listeners.append(l)
                if port == 0 { port = l.channel.localAddress?.port ?? 0 }
            }
        } catch {
            for l in listeners { try? await l.channel.close() }
            throw error
        }
        serve.port = port
        let server = DozerWebServer(origin: try WebOrigin(port: port), version: version, limits: limits, assets: assets, data: data,
                                     capability: .make(), pollInterval: pollInterval, gate: gate, listeners: listeners,
                                     settings: settings, sessionsFile: nil, revokedFile: nil, operationsFile: operationsFile, serveState: serve)
        gate.server = server
        return server
    }

    private static func listen(host: String, port: Int, gate: UpgradeGate, group: EventLoopGroup) async throws -> NIOAsyncChannel<Accepted, Never> {
        try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: false)
            .bind(host: host, port: port) { child in
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
    }

    /// 591 — the terminal socket's upgrade, in order (591.01-DESIGN.md §4.2): exact Host, Origin
    /// required and exact, Fetch Metadata, the route, the one cookie → a live session, the ticket
    /// in the subprotocol → consumed against that session and this sandbox, then room for one more.
    func admitTerminal(_ head: HTTPRequestHead, peer: SocketAddress? = nil) async throws -> WebTerminalGrant {
        guard let method = WebHTTPMethod(rawValue: head.method.rawValue) else { throw WebRejection.methodNotAllowed }
        let md = metadata(head, method: method, bodyBytes: 0)
        let ctx = requestContext(head, md, peer: peer)
        do {
            try WebSecurity.checkListener(md, ctx.view, originRequired: true)
            if head.headers["origin"].count > 1 { throw WebRejection.originRejected }
            guard case .terminalSocket(let name)? = WebRoute.parse(method: method, target: head.uri) else { throw WebRejection.notFound }
            let (cookie, ticket) = try WebSecurity.validateTerminalUpgrade(md, ctx.view, subprotocols: head.headers["sec-websocket-protocol"])
            _ = try await auth.authenticate(cookie)
            if let r = WebExposure.decide(.terminalSocket(name), ctx.principal) { throw r }
            let grant = try await tickets.consume(ticket, cookie: cookie, sandbox: name)
            guard terminals.hasRoom() else { throw WebRejection.tooManyTerminals }
            if let s = serveState, case .devices(let d) = auth, let dev = try? await d.authenticate(cookie).1 {
                s.audit.record(WebAuditEntry(kind: "terminal-open", device: dev.id, deviceName: dev.name, address: ctx.client,
                                             sandbox: name, outcome: grant.mode.rawValue))
            }
            return grant
        } catch let r as WebRejection {
            serveState?.audit.record(WebAuditEntry(kind: "refused", address: ctx.client, route: "terminal-socket", outcome: r.rawValue))
            throw r
        }
    }

    /// The start-up link (its capability works once, for `limits.bootstrapLifetime`). Hand it to a
    /// browser or a TTY — never to a log, a file or a process argument.
    public var launchURL: URL { capability.launchURL(origin: origin) }

    /// A fresh one-use link for this running server (`doz ui link`).
    public func newLink() async -> URL { await sessions.issue().launchURL(origin: origin) }

    /// 594 W19: pages connected now (their event streams).
    public var openPages: Int { hub.count }

    /// 594 W19: a live session was kept from the last UI (a page of it may be open, retrying).
    public func hasSessions() async -> Bool { await sessions.liveSessionCount > 0 }

    /// 594 W19: wait up to `seconds` for a page to (re)connect its event stream; whether one did.
    public func waitForPage(seconds: Double) async -> Bool {
        let end = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < end {
            if hub.count > 0 { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return hub.count > 0
    }

    /// 594 W19: a line every open page shows as a toast ("doz ui restarted — 0.12.0-rc.4").
    public func tellPages(_ text: String) { hub.broadcast("notice", ["text": text]) }

    /// 594 W19: `doz ui link --rotate` / `doz ui --new-link` on a running UI — every session ends (each
    /// open page is told to use the new link), then a fresh one-use link.
    public func rotate() async -> URL {
        await sessions.revokeAll()
        for c in hub.all { c.finish(.rotated) }
        // 605: the page keeps its terminals and reattaches them after it signs in again.
        await terminals.closeAll(reason: "session-ended")
        return await newLink()
    }

    /// 605: how this server stops.
    public enum Stop: Sendable, Equatable {
        /// doz ui stops (Ctrl-C, a signal): pages say doz ui stopped.
        case shutdown
        /// `doz ui restart` on the same port: pages stay calm and reconnect (sessions kept).
        case restarting
        /// `doz ui restart` onto another port: each open page is told where it went.
        case moving(WebOrigin)
    }

    /// Serve until `close()`.
    public func run() async throws {
        try await withThrowingDiscardingTaskGroup { outer in
            for l in listeners { outer.addTask { try await self.accept(l) } }
        }
    }

    private func accept(_ listener: NIOAsyncChannel<Accepted, Never>) async throws {
        try await withThrowingDiscardingTaskGroup { group in
            try await listener.executeThenClose { inbound in
                for try await accepted in inbound {
                    let channel = accepted.channel
                    // 606: doz serve drops a sandbox's connection (and one that reached an address it does not
                    // serve) before a byte is read, and caps each address's connections.
                    var address: String?
                    var refusal: WebRejection?
                    if let s = serveState {
                        let peer = channel.remoteAddress?.ipAddress.flatMap(WebIP.init)?.description ?? "?"
                        switch s.admit(peer: channel.remoteAddress, local: channel.localAddress) {
                        case .sandbox?:
                            // A sandbox (Dozer's untrusted party) gets nothing at all: dropped before a byte is read.
                            s.audit.record(WebAuditEntry(kind: "dropped", address: peer, outcome: WebServeRules.Drop.sandbox.rawValue))
                            channel.close(promise: nil)
                            continue
                        case .notServed?:
                            // Anyone else is TOLD why (rc.1: a silent drop looked like "no response" in the browser).
                            s.audit.record(WebAuditEntry(kind: "refused", address: peer, outcome: WebServeRules.Drop.notServed.rawValue))
                            refusal = .notServedAddress
                        case nil:
                            if s.open(peer) { address = peer } else {
                                s.audit.record(WebAuditEntry(kind: "refused", address: peer, outcome: WebRejection.tooManyConnections.rawValue))
                                refusal = .tooManyConnections
                            }
                        }
                    }
                    let admitted: Bool = lock.withLock {
                        guard !closing else { return false }
                        if let refusal {
                            // Answered once, then closed — not counted against the server's cap.
                            refusedConnections[ObjectIdentifier(channel)] = refusal
                            return true
                        }
                        guard children.count < limits.maximumConnections else {
                            if serveState != nil {
                                refusedConnections[ObjectIdentifier(channel)] = .tooManyConnections
                                return true
                            }
                            return false
                        }
                        children[ObjectIdentifier(channel)] = channel
                        return true
                    }
                    guard admitted else {
                        if let address { serveState?.closed(address) }
                        channel.close(promise: nil)
                        continue
                    }
                    group.addTask {
                        await self.serve(accepted)
                        _ = self.lock.withLock {
                            self.children.removeValue(forKey: ObjectIdentifier(channel))
                            self.refusedConnections.removeValue(forKey: ObjectIdentifier(channel))
                        }
                        if let address { self.serveState?.closed(address) }
                    }
                }
            }
        }
    }

    /// Stop: no new connections, every stream told `shutdown`, every terminal closed (1001), every
    /// connection closed. Links die with the process; sessions too, unless kept for the next UI on
    /// the same port (594 W19, `WebSessionStore`'s `persist`).
    public func close(_ how: Stop = .shutdown) async {
        let open: [Channel] = lock.withLock {
            closing = true
            return Array(children.values)
        }
        switch how {
        case .shutdown:
            hub.finishAll(.shutdown)
            await terminals.closeAll()
        case .restarting:
            hub.finishAll(.restarting)
            await terminals.closeAll(reason: "restarting")
        case .moving(let to):
            hub.finishAll(.moved(to.value))
            await terminals.closeAll(reason: "restarting")
        }
        await monitor.stop()
        if case .devices(let d) = auth { await d.flush() }
        try? await Task.sleep(for: .milliseconds(100))           // let the streams write their last frame
        for l in listeners { try? await l.channel.close() }
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
                if let r = gate.takeRefusal(id) ?? connectionRefusal(id) { await refuse(conn, r) } else { await serve(conn, peer: accepted.channel.remoteAddress) }
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
            // 593: the boot view's progress as this UI's settings say (ui.progress; $DOZ_PROGRESS in its environment).
            let bridge = WebTerminalBridge(grant: grant, data: data, hub: terminals, sessions: auth, channel: socket.channel, outbound: outbound,
                                           progressMode: settings.current.progressMode())
            guard terminals.add(bridge) else {
                await bridge.end(.policyViolation, "too-many-terminals")
                return
            }
            defer { terminals.remove(bridge) }
            await bridge.run(inbound)
            if let s = serveState {
                s.audit.record(WebAuditEntry(kind: "terminal-close", address: socket.channel.remoteAddress?.ipAddress.flatMap(WebIP.init)?.description,
                                             sandbox: grant.sandbox))
            }
        }
    }

    private func serve(_ conn: Connection, peer: SocketAddress? = nil) async {
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
                    switch await respond(head, body: Data(body.readableBytesView), connection: ObjectIdentifier(conn.channel), peer: peer) {
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
        // A response's own header REPLACES a default of that name (591: the frame's CSP and XFO,
        // the frame assets' CORP) — never a second, conflicting copy.
        for (k, v) in r.1 { h.replaceOrAdd(name: k, value: v) }
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
                                  contentType: Self.header(h, "content-type"), bodyByteCount: bodyBytes,
                                  probeToken: Self.header(h, "x-doz-probe"))
    }

    /// 606: the request's view of this server — doz ui: 590's exact loopback origin; doz serve: `WebServeRules`.
    func requestContext(_ head: HTTPRequestHead, _ md: WebRequestMetadata, peer: SocketAddress?) -> WebRequestContext {
        if let s = serveState { return s.context(HTTPHeadersView(pairs: head.headers.map { ($0.name, $0.value) }), peer: peer) }
        return WebRequestContext(view: .loopback(md, origin), principal: .mac, client: WebLoopbackAddress.host, userAgent: nil)
    }

    func respond(_ head: HTTPRequestHead, body: Data, connection: ObjectIdentifier? = nil, peer: SocketAddress? = nil) async -> Reply {
        guard let method = WebHTTPMethod(rawValue: head.method.rawValue) else {
            let e = error(.methodNotAllowed)
            return .response(e.0, e.1, e.2)
        }
        let md = metadata(head, method: method, bodyBytes: body.count)
        var ctx = requestContext(head, md, peer: peer)
        var route: WebRoute?
        var device: WebDeviceView?
        let reply: Reply
        do {
            // 591: the sandboxed terminal frame (an opaque origin) loads its script, style and the
            // engine: exact Host, GET/HEAD, no body — the Origin and Fetch-Metadata checks cannot apply
            // to an opaque origin, and these files are public and static.
            if ctx.view.ownOrigin != nil, case .asset(let p)? = WebRoute.parse(method: method, target: head.uri), WebAssets.isFrameAsset(p) {
                guard md.bodyByteCount == 0 else { throw WebRejection.bodyTooLarge }
                guard let a = assets.assets[p] else { throw WebRejection.notFound }
                return .response(200, [("Content-Type", a.mimeType), ("Cache-Control", a.cachePolicy)] + WebSecurity.frameAssetHeaders, a.data)
            }
            // A duplicated Host or Origin header is not "the" header: `header()` gives nil, refused here.
            try WebSecurity.checkListener(md, ctx.view, originRequired: false)
            if head.headers["origin"].count > 1 { throw WebRejection.originRejected }
            guard let r = WebRoute.parse(method: method, target: head.uri) else { throw WebRejection.notFound }
            route = r
            // 591: the terminal socket over plain HTTP (no upgrade, or not the connection's first
            // request) is not a terminal. (A refused upgrade is answered in serve(_: Accepted).)
            if case .terminalSocket = r {
                throw connection.flatMap { gate.takeRefusal($0) } ?? WebRejection.upgradeRequired
            }
            reply = try await dispatch(r, md, body: body, ctx: &ctx, device: &device)
        } catch let r as WebRejection {
            if serveState != nil, r != .notAdmitted || !md.method.isSafe, route != .sessionBootstrap || r == .hostRejected || r == .originRejected {
                serveState?.audit.record(WebAuditEntry(kind: "refused", device: device?.id, deviceName: device?.name, address: ctx.client,
                                                       route: route.map(Self.routeLabel), outcome: r.rawValue))
            }
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
            auditChange(route, md, body, ctx, device, outcome: e.code.rawValue)
            return .response(status, [("Content-Type", "application/json; charset=utf-8")], Self.errorBody(e.code.rawValue, e.message))
        } catch {
            return .response(500, [("Content-Type", "application/json; charset=utf-8")], Self.errorBody("failed", "the request failed"))
        }
        if case .response(let status, _, _) = reply { auditChange(route, md, body, ctx, device, outcome: status < 400 ? "ok" : String(status)) }
        return reply
    }

    /// 606: a route as the audit log names it (no value from the request but the route's own words).
    static func routeLabel(_ r: WebRoute) -> String {
        let m = Mirror(reflecting: r)
        return m.children.first?.label ?? String(describing: r)
    }

    /// 606: every change a remote browser asked for, in the audit log — the route, the action and its sandbox
    /// (decoded by the closed action types already), the outcome. Never a body.
    private func auditChange(_ route: WebRoute?, _ md: WebRequestMetadata, _ body: Data, _ ctx: WebRequestContext, _ device: WebDeviceView?, outcome: String) {
        guard let s = serveState, let route, !md.method.isSafe else { return }
        if case .sessionRenew = route { return }
        if case .sessionBootstrap = route { return }                     // admissions are their own lines
        var action: String?, sandbox: String?
        if case .actions = route, let d = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            action = (d["action"] as? String).flatMap { WebRoute.isActionWord($0) ? $0 : nil }
            sandbox = (d["sandbox"] as? String).flatMap { WebRoute.isSandboxName($0) ? $0 : nil }
        }
        switch route {
        case .policyPreview(let n), .terminalTicket(let n), .sandboxKey(let n), .terminalLayoutSet(let n), .terminal(let n): sandbox = n
        default: break
        }
        s.audit.record(WebAuditEntry(kind: "change", device: device?.id, deviceName: device?.name, address: ctx.client,
                                     route: Self.routeLabel(route), action: action, sandbox: sandbox, outcome: outcome))
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

    /// 611: the banner — what the last update check found (read from its state file; no network).
    var updateNotice: WebUpdateNotice? {
        let ctx = UpdateContext.current(version: version, executable: HostLauncher.executablePath)
        let (available, installed) = UpdateChecker.remembered(ctx)
        if let v = installed {
            return WebUpdateNotice(kind: "installed", version: v, command: "doz host restart", notes: nil,
                                   text: UpdateChecker.installedLine(v) + " (this dashboard: doz ui restart)")
        }
        guard let e = available else { return nil }
        let line = UpdateChecker.noticeLine(e, ctx)
        let command = line.components(separatedBy: "upgrade: ").last.map { $0.components(separatedBy: " (notes:").first ?? $0 } ?? "doz upgrade -y"
        return WebUpdateNotice(kind: "available", version: e.version, command: command, notes: e.notes,
                               text: "doz \(e.version) is available")
    }

    func sessionInfo(_ s: WebSession, _ ctx: WebRequestContext, _ device: WebDeviceView?) -> WebSessionInfo {
        var info = WebSessionInfo(csrf: s.csrfToken, expiresAt: s.expiresAt, serverRun: serverRun, store: data.storePath, version: version)
        info.chatgptSignIn = BuildFlavor.current.chatgptSignIn          // 611
        info.update = updateNotice
        if let st = serveState, let device {
            info.serve = WebServeSessionInfo(exposure: "remote", secure: ctx.secure, secretsAllowed: ctx.secure && settings.secretEntryAllowed,
                                             mac: st.names.localHostName, device: device)
        }
        return info
    }

    /// The session cookie as this request should receive it (doz serve: the device's, `Secure` over https).
    func sessionCookieHeader(_ s: WebSession, _ ctx: WebRequestContext) -> (String, String) {
        if serveState != nil {
            return ("Set-Cookie", WebSecurity.setCookie(s.cookieValue, name: ctx.view.cookieName, maxAge: WebDeviceStore.cookieMaxAge, secure: ctx.secure))
        }
        return ("Set-Cookie", WebSecurity.setCookie(s.cookieValue, name: ctx.view.cookieName, maxAge: s.expiresAt.timeIntervalSinceNow))
    }

    private func dispatch(_ route: WebRoute, _ md: WebRequestMetadata, body: Data, ctx: inout WebRequestContext,
                          device: inout WebDeviceView?) async throws -> Reply {
        let view = ctx.view
        switch route {
        case .index, .asset:
            try WebSecurity.validateStatic(md, view)
            let path = if case .asset(let p) = route { p } else { "/" }
            guard let a = assets.assets[path] else { throw WebRejection.notFound }
            return .response(200, [("Content-Type", a.mimeType), ("Cache-Control", a.cachePolicy)], a.data)
        case .terminalFrame:
            try WebSecurity.validateStatic(md, view)
            guard let a = assets.assets[WebAssets.frameDocument] else { throw WebRejection.notFound }
            return .response(200, [("Content-Type", a.mimeType), ("Cache-Control", a.cachePolicy)] + WebSecurity.frameHeaders, a.data)
        case .offline:
            try WebSecurity.validateStatic(md, view)
            guard let a = assets.assets[WebAssets.offlineDocument] else { throw WebRejection.notFound }
            return .response(200, [("Content-Type", a.mimeType), ("Cache-Control", a.cachePolicy)], a.data)
        case .serviceWorker:
            try WebSecurity.validateStatic(md, view)
            guard let a = assets.assets[WebAssets.serviceWorker] else { throw WebRejection.notFound }
            return .response(200, [("Content-Type", a.mimeType), ("Cache-Control", a.cachePolicy)] + WebSecurity.serviceWorkerHeaders, a.data)
        case .sessionBootstrap:
            if let st = serveState { return try await admit(md, body: body, ctx: ctx, serve: st, device: &device) }
            let cap = try WebSecurity.validateBootstrap(md, view, limit: limits.maximumRequestBodyBytes)
            let s = try await sessions.exchange(cap)
            return json(sessionInfo(s, ctx, nil), extra: [sessionCookieHeader(s, ctx)])
        case .serveProbe:
            // 606: `doz doctor`'s round trip — no session; a one-use token doz serve issued over serve.sock. 404
            // otherwise (and always on doz ui). Answers how the request arrived, nothing else.
            guard let st = serveState else { throw WebRejection.notFound }
            try WebSecurity.validateStatic(md, view)
            guard st.consumeProbe(md.probeToken) else { throw WebRejection.notFound }
            return json(["scheme": ctx.secure ? "https" : "http", "viaProxy": ctx.view.ownOrigin.map { o in st.config.publicOrigins.contains { $0.description == o } } == true ? "yes" : "no",
                         "origin": ctx.view.ownOrigin ?? ""])
        default:
            break
        }
        let cookie = try WebSecurity.validateAuthenticated(md, view, limit: limits.maximumRequestBodyBytes)
        let session: WebSession
        if case .devices(let d) = auth {
            let (s, dev) = md.method.isSafe ? try await d.authenticate(cookie) : try await d.authenticateMutation(cookie, csrf: md.csrfToken)
            session = s
            device = dev
            await d.touch(cookie, address: ctx.client, userAgent: ctx.userAgent)
        } else {
            session = md.method.isSafe ? try await sessions.authenticate(cookie)
                                       : try await sessions.authenticateMutation(cookie, csrf: md.csrfToken)
        }
        // 606: who may do what (WebExposure — the server is the wall; the page only hides).
        if let r = WebExposure.decide(route, ctx.principal) { throw r }
        switch route {
        case .index, .asset, .sessionBootstrap, .terminalFrame, .offline, .serviceWorker, .serveProbe:
            throw WebRejection.notFound
        case .sessionInfo:
            return json(sessionInfo(session, ctx, device))
        case .sessionRenew:
            let s = try await auth.renew(cookie)
            return json(sessionInfo(s, ctx, device), extra: [sessionCookieHeader(s, ctx)])
        case .sessionEnd:
            await auth.signOut(cookie)
            if let st = serveState, let device {
                st.audit.record(WebAuditEntry(kind: "sign-out", device: device.id, deviceName: device.name, address: ctx.client))
            }
            for c in hub.all where c.cookie == cookie { c.finish(.sessionEnded) }
            terminals.closeAll(cookie: cookie)
            return .response(204, [("Set-Cookie", WebSecurity.clearCookie(name: view.cookieName, secure: ctx.secure))], Data())
        case .serveStatus:
            return json(try await serveStatus())
        case .serveDevices:
            return json(try await serveDevices(current: serveState != nil ? cookie : nil))
        case .serveShare:
            try Self.requireJSONBody(md)
            return json(try await serveShare(by: device?.name ?? "the Mac", origin: serveState != nil ? ctx.view.ownOrigin : nil, ctx: ctx, device: device))
        case .serveRevoke(let id):
            try Self.requireJSONBody(md)
            return json(try await serveRevoke(id, by: device?.name ?? "the Mac", ctx: ctx, asker: device))
        case .serveRename(let id):
            try Self.requireJSONBody(md)
            guard let d = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], Set(d.keys) == ["name"], let name = d["name"] as? String,
                  (1...60).contains(name.count) else { throw WebAction.Invalid("the body is {name} (1–60 characters)") }
            return json(try await serveRename(id, to: name, ctx: ctx, asker: device))
        case .overview:
            return json(try await data.overview())
        case .sandbox(let name):
            return json(try await data.sandbox(name))
        case .sandboxSessions(let name):
            return json(try await data.sessions(name))
        case .sandboxNetwork(let name):
            return json(try await data.network(name))
        case .sandboxTools(let name):
            return json(try await data.tools(name))
        case .images:
            return json(try await data.images())
        case .imageTree:
            return json(try await data.imageTree())
        case .accounts:
            return json(try await data.accounts())
        case .metrics(let q):
            return json(try await data.metrics(q))
        case .metricsCSV(let q):
            return .response(200, [("Content-Type", "text/csv; charset=utf-8"),
                                   ("Content-Disposition", "attachment; filename=\"doz-metrics.csv\"")], try await data.metricsCSV(q))
        case .operations:
            return json(operations.recent)
        case .actions:
            try Self.requireJSONBody(md)
            // 599f: `project-create` {folder} — the sandbox the folder's project file describes, made with
            // the options `doz up` gives it.
            if let d = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], d["action"] as? String == "project-create" {
                guard Set(d.keys) == ["action", "folder"], let folder = d["folder"] as? String, folder.count <= 1024 else {
                    throw WebAction.Invalid("project-create: only folder")
                }
                return json(try operations.start(try WebProject.createAction(folder: folder, settings: settings.current)), status: 202)
            }
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
            guard settings.terminalsEnabled else { throw WebRejection.terminalsOff }
            let r = try WebTerminalTicketRequest.decode(body)
            let t = try await tickets.mint(cookie: cookie, sandbox: name, session: r.session, mode: r.mode, size: r.size, reattach: r.reattach)
            return json(WebTerminalTicketInfo(ticket: t, expiresInSeconds: Int(tickets.lifetime), session: r.session, mode: r.mode))
        case .terminalSocket:
            throw WebRejection.upgradeRequired            // answered in respond(); never dispatched
        case .settings:
            return json(settings.report())
        case .settingsChange:
            try Self.requireJSONBody(md)
            return json(try settings.apply(try WebSettingChange.decode(body)))
        case .sessionScreen(let name, let session):
            return json(try await data.sessionScreen(name, session: session))
        case .terminalLayout(let name):
            return json(try await data.terminalLayout(name))
        case .bootLogs(let name):
            return json(try await data.bootLogs(name))
        case .bootLog(let name, let n):
            return json(try await data.bootLog(name, number: n))
        case .terminalLayoutSet(let name):
            try Self.requireJSONBody(md)
            return json(try await data.setTerminalLayout(name, try WebTerminalLayout.decode(body)))
        case .onboarding:
            var o = try await data.onboarding()
            let f = settings.onboardingFiles()
            o.settingsPath = f.settings
            o.settingsExists = f.settingsExists
            o.promptTemplatePath = f.template
            o.promptTemplateExists = f.templateExists
            o.defaultImage = settings.current.string(SettingKey.defaultImage) ?? "lab"
            return json(o)
        case .onboardingConfig:
            try Self.requireJSONBody(md)
            return json(try settings.writeOnboardingConfig(try WebOnboardingConfig.decode(body)))
        case .preparations:
            return json(try await data.preparations())
        case .accountAdd:
            // CSRF-checked (an unsafe method, above), then the setting, then a strict body. The
            // secret is in this request's body only; a failure's message is scrubbed of it.
            try Self.requireJSONBody(md)
            guard settings.secretEntryAllowed else { throw WebRejection.secretEntryOff }
            let a = try WebAccountAdd.decode(body)
            do {
                return json(try await data.addAccount(a))
            } catch let e as HostError {
                throw HostError(e.code, a.scrub(e.message))
            } catch {
                throw HostError(.failed, a.scrub(error.localizedDescription))
            }
        case .sandboxKey(let name):
            // The same model as accountAdd: CSRF (above), the setting, a strict body, scrubbed errors.
            try Self.requireJSONBody(md)
            guard settings.secretEntryAllowed else { throw WebRejection.secretEntryOff }
            let k = try WebKeySet.decode(body, sandbox: name)
            do {
                return json(try await data.setKey(k))
            } catch let e as HostError {
                throw HostError(e.code, k.scrub(e.message))
            } catch {
                throw HostError(.failed, k.scrub(error.localizedDescription))
            }
        case .access:
            return json(try await data.access(check: nil))
        case .accessCheck:
            // 599e: changes no setting (the record of the last check only); POST (CSRF, above) — it starts
            // the host and carries the choices to confirm before they are written.
            try Self.requireJSONBody(md)
            return json(try await data.access(check: try WebAccessCheck.decode(body)))
        case .accessGithubKey:
            // The model of accountAdd: CSRF (above), the setting, a strict body, scrubbed errors.
            try Self.requireJSONBody(md)
            guard settings.secretEntryAllowed else { throw WebRejection.secretEntryOff }
            let k = try WebAccessGitHubKey.decode(body)
            do {
                return json(try await data.setAccessGitHubKey(k))
            } catch let e as HostError {
                throw HostError(e.code, k.scrub(e.message))
            } catch {
                throw HostError(.failed, k.scrub(error.localizedDescription))
            }
        case .workspaceCheck:
            // Changes nothing; POST (CSRF, above) because it carries a typed path.
            try Self.requireJSONBody(md)
            let q = try WebWorkspaceQuery.decode(body)
            let taken = Set(((try? await data.overview())?.sandboxes ?? []).map(\.name))
            return json(WebWorkspaceCheck.check(q, taken: taken, settings: settings.current, store: data.storePath))
        case .workspaceChoose:
            try Self.requireJSONBody(md)
            let start = try WebFolderPicker.decodeStart(body)
            let projects = (Workspace.defaultPath(name: "x", settings: settings.current) as NSString).deletingLastPathComponent
            return json(try await folderPicker.choose(start: WebFolderPicker.startFolder(start, projectsDir: projects)))
        case .quickAdd:
            // 599c: changes nothing; POST (CSRF, above) like the workspace check.
            try Self.requireJSONBody(md)
            let q = try WebQuickAddQuery.decode(body)
            async let overview = data.overview()
            async let images = data.images()
            async let accounts = data.accounts()
            let taken = Set(((try? await overview)?.sandboxes ?? []).map(\.name))
            return json(try q.plan(taken: taken, settings: settings.current, images: (try? await images) ?? [],
                                   accounts: (try? await accounts) ?? WebAccounts(accounts: [], defaultAccount: "none", keepalive: false)))
        case .projectOpen:
            // 599f: changes nothing; POST (CSRF, above) because it carries a path.
            try Self.requireJSONBody(md)
            let q = try WebProjectRequest.decode(body, allowed: ["folder"])
            return json(WebProject.open(q, settings: settings.current, store: data.storePath))
        case .projectPreview, .projectWrite:
            try Self.requireJSONBody(md)
            let writing = route == .projectWrite
            let q = try WebProjectRequest.decode(body, allowed: writing ? ["folder", "form", "explicit", "replace"] : ["folder", "form", "explicit"])
            let taken = Set(((try? await data.overview())?.sandboxes ?? []).map(\.name))
            if writing { return json(try WebProject.write(q, settings: settings.current, store: data.storePath, taken: taken)) }
            return json(try WebProject.preview(q, settings: settings.current, store: data.storePath, taken: taken).0)
        case .projectsDirChoose:
            // 599c: the Mac's picker; what the person chose there is written here — never a path from the page.
            try Self.requireJSONBody(md)
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], obj.isEmpty else {
                throw WebAction.Invalid("the body is {}")
            }
            let projects = (Workspace.defaultPath(name: "x", settings: settings.current) as NSString).deletingLastPathComponent
            let c = try await folderPicker.choose(start: WebFolderPicker.startFolder(projects, projectsDir: projects), prompt: WebFolderPicker.projectsPrompt)
            guard let path = c.path, !c.cancelled else { return json(WebProjectsDirChoice(path: nil, cancelled: true, report: settings.report())) }
            let report = try settings.applyProjectsDir(path, store: data.storePath)
            return json(WebProjectsDirChoice(path: (try? Workspace.normalize(path)) ?? path, cancelled: false, report: report))
        case .bases:
            return json(try await data.bases())
        case .dockerfileChoose:
            // The MAC's file picker (CSRF above); opened at the field's folder, else the projects folder.
            try Self.requireJSONBody(md)
            let start = try WebFolderPicker.decodeStart(body)
            let projects = (Workspace.defaultPath(name: "x", settings: settings.current) as NSString).deletingLastPathComponent
            let from = start.map { s -> String in
                let e = (s as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: e, isDirectory: &isDir) && !isDir.boolValue ? (e as NSString).deletingLastPathComponent : s
            }
            return json(try await dockerfilePicker.choose(start: WebFolderPicker.startFolder(from, projectsDir: projects)))
        case .resources:
            return json(try await data.resources())
        case .resourcesPreview:
            // Changes nothing (a dry run); POST (CSRF, above) because it carries ids.
            try Self.requireJSONBody(md)
            return json(try await data.resourcesPreview(try WebResourcePreview.decode(body)))
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
        // `hello` first: the page (re)fetches everything on it — every (re)connect is a resync. 605: with
        // this build's page script and style, so a page of an older build offers a reload.
        let hello = (try? WebJSON.encoder.encode(WebHello(serverRun: serverRun, version: version, script: assets.pageScript,
                                                          style: assets.pageStyle))) ?? Data()
        try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: SSEFrame(event: "hello", id: hub.nextSeq(), json: hello).bytes))))
        conn.channel.closeFuture.whenComplete { _ in client.finish(.clientGone) }
        let auth = self.auth, cookie = client.cookie, beat = limits.heartbeatInterval, channel = conn.channel
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
                guard await auth.isValid(cookie) else { client.finish(.sessionEnded); return }
                client.send(SSEFrame(comment: "ping"))
            }
        }
        defer { heartbeat.cancel() }
        for await f in client.frames {
            try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: f.bytes))))
        }
        var movedTo: String?
        let last: String? = switch client.end {
        case .overflow: "resync"
        case .sessionEnded: "session-ended"
        case .shutdown: "shutdown"
        case .rotated: "rotated"
        case .replaced: "replaced"
        case .restarting: "restarting"
        case .moved(let o): { movedTo = o; return "moved" }()
        case .revoked: "revoked"
        case .clientGone, nil: nil
        }
        if let last {
            // 605: `moved` says where doz ui went (an origin — no key).
            var body = ["reason": last]
            if let movedTo { body["origin"] = movedTo }
            let d = (try? WebJSON.encoder.encode(body)) ?? Data()
            try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: SSEFrame(event: last == "resync" ? "resync" : "end", id: hub.nextSeq(), json: d).bytes))))
        }
        try await outbound.write(.end(nil))
    }
}
