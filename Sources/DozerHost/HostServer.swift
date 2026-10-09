import Darwin
import Foundation
import DozerKit

/// `doz host` (585, owner ruling (b): a lazy per-user host). One process per store owns every
/// running VM, the egress proxies, the metrics writer and the shared event-loop group, and serves
/// `<store>/host.sock`.
///
/// Life:
///   · started by the first CLI call that needs it (a detached child, `HostLauncher`), or by hand;
///   · holds `<store>/host.lock` (flock) for its whole life — there is never a second host for a store,
///     and a new one waits for the old one to finish exiting before it loads anything;
///   · exits by itself once NO sandbox has a VM (booting, running, paused, asleep) and no client is
///     connected for `idleTimeoutMinutes` (default 5; 0 = never) — so no daemon runs when nothing does;
///   · `doz host stop`, SIGTERM or SIGINT: Hibernate everything (quit = Hibernate) and exit;
///   · after a crash (kill -9): the next CLI call starts a new host, which restores what was asleep
///     and reports what died (`HostCore.recoverAfterStart`). Hibernated sandboxes wake on demand.
public final class HostServer: @unchecked Sendable {
    public let store: DozerStore
    public let idleTimeoutMinutes: Double
    public let version: String
    let core: HostCore
    let startedAt = Date()

    private let lock = NSLock()
    private var connections = 0
    private var idleSince: Date?
    private var listenFD: Int32 = -1
    private var lockFD: Int32 = -1
    private var stopping = false
    private var signalSources: [DispatchSourceSignal] = []

    init(store: DozerStore, idleTimeoutMinutes: Double, version: String) {
        self.store = store
        self.idleTimeoutMinutes = idleTimeoutMinutes
        self.version = version
        // 591: the settings' keep-alive for a store that has not chosen (read once, at start).
        let settings = DozerSettings.load()
        core = HostCore(store: store, readOnly: false, version: version, services: .forHost(),
                        newStoreKeepalive: settings.bool(SettingKey.keepalive),
                        newStoreDefaultAccount: settings.string(SettingKey.defaultAccount) ?? "mac",
                        // 594: `latest` agent versions are asked of the npm registry (DOZ_TEST_NPM_REGISTRY: a stub).
                        agentRegistry: .fromEnvironment())
    }

    public enum StartError: Error, LocalizedError {
        case alreadyRunning(Int32?)
        case socket(String)
        public var errorDescription: String? {
            switch self {
            case .alreadyRunning(let pid): "a host is already running for this store" + (pid.map { " (pid \($0))" } ?? "")
            case .socket(let s): s
            }
        }
    }

    /// 593: this host was started by `HostLauncher` (fully detached), not by a person's `--foreground`.
    nonisolated(unsafe) public static var launchedDetached: Bool = false

    /// Run the host in this process until it exits (never returns). `launched`: started by
    /// `HostLauncher` (its parent is launchd); false: a person ran `doz host start --foreground`.
    public static func run(store: DozerStore, idleTimeoutMinutes: Double, version: String, launched: Bool = false) async throws -> Never {
        TestSafety.checkStore(store.root)          // 611
        launchedDetached = launched
        setvbuf(stdout, nil, _IOLBF, 0)
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        try store.ensureDirectory()
        guard store.socketPathFits else { throw StartError.socket(UnixSocket.Failure.pathTooLong(store.socket.path).localizedDescription) }
        let server = HostServer(store: store, idleTimeoutMinutes: idleTimeoutMinutes, version: version)
        try server.takeLock(waitSeconds: 60)
        // 606: the proxy never connects a sandbox to one of Dozer's own dashboards on this Mac.
        LocalDashboards.protect(DashboardPorts(store: store).current)
        HostLog.enabled = true
        HostLog.line("doz host \(version) (pid \(getpid())) — store \(store.root.path), idle timeout \(idleTimeoutMinutes) min")
        HostLog.line(launched ? "detached: parent \(getppid())\(getppid() == 1 ? " (launchd)" : " — NOT launchd"), session \(getsid(0))"
                              : "in the foreground (parent \(getppid())): it lives in that terminal's process tree")
        // EXPERIMENTAL (604): which app macOS asks about the microphone for, for this host's audio sandboxes.
        HostLog.line("microphone (audio sandboxes, experimental): macOS asks on behalf of "
                     + (HostCore.microphoneApp.map { "\($0.description) — \($0.path)" } ?? "an app it could not name"))
        if ProcessInfo.processInfo.environment["DOZ_TEST_CREDENTIALS"] == "memory" {
            HostLog.line("TEST: DOZ_TEST_CREDENTIALS=memory — accounts' secrets live in this host's memory, never the keychain; nothing is verified")
        }
        // 599i: a test's fake OpenAI — said, so a test can check its host has it before anything reaches OpenAI.
        if let o = OpenAISeam.upstream() {
            HostLog.line("TEST: DOZ_TEST_OPENAI_UPSTREAM — OpenAI's hosts (sign-in, refresh, the proxy's leg) go to \(o.host):\(o.port), trusting only its CA")
        }
        // 591: the VM layouts this host records name it; and it remembers the file it runs from, to
        // tell a later "Internal Virtualization error" caused by an update underneath it.
        VMLayout.recorder = "doz \(version)"
        let exe = ExecutableIdentity.of(path: HostLauncher.executablePath)
        await server.core.setExecutable(exe)
        HostLog.line("running from \(exe?.path ?? HostLauncher.executablePath)\(exe?.cdhash.map { " (cdhash \($0.prefix(12)))" } ?? "")")
        await server.core.load()
        do {
            server.listenFD = try UnixSocket.listen(store.socket.path)
        } catch {
            throw StartError.socket(error.localizedDescription)
        }
        let lfd = server.listenFD
        Thread.detachNewThread { server.acceptLoop(lfd) }
        server.installSignalHandlers()
        Task.detached { await server.core.recoverAfterStart() }
        Task.detached { await server.idleLoop() }
        // 593 §9 (S2): the periodic screen capture (read once, at start — like the idle timeout).
        let captureMinutes = DozerSettings.load().int(SettingKey.screenCapture)
        HostLog.line(captureMinutes > 0 ? "saving session screens every \(captureMinutes) min while a sandbox runs (host.screen_capture_minutes)"
                                        : "periodic screen capture off (host.screen_capture_minutes = 0)")
        if captureMinutes > 0 {
            Task.detached {
                while true {
                    try? await Task.sleep(for: .seconds(Double(captureMinutes) * 60))
                    await server.core.captureScreensPeriodically()
                }
            }
        }
        HostLog.line("listening on \(store.socket.path)")
        while true { try? await Task.sleep(for: .seconds(3600)) }
    }

    /// The store's lock, for the life of the process. A host that is exiting still holds it: wait.
    private func takeLock(waitSeconds: Double) throws {
        let fd = open(store.lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StartError.socket("cannot open \(store.lockFile.path): \(String(cString: strerror(errno)))") }
        let deadline = Date().addingTimeInterval(waitSeconds)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // A live host that is not exiting answers its socket: then this one is not needed.
            if Date() > deadline || UnixSocket.connect(store.socket.path).map({ close($0); return true }) == true {
                close(fd)
                throw StartError.alreadyRunning(store.hostPID())
            }
            usleep(100_000)
        }
        lockFD = fd
        try? "\(getpid())\n".write(to: store.pidFile, atomically: true, encoding: .utf8)
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { [weak self] in
                guard let self else { return }
                HostLog.line("signal \(sig): hibernating every sandbox, then exiting")
                Task.detached { await self.shutdown(prepare: true, reply: nil) }
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: idle

    func idleLoop() async {
        let timeout = idleTimeoutMinutes * 60
        let interval = timeout <= 0 ? 30.0 : min(15, max(0.5, timeout / 4))
        while true {
            try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
            guard timeout > 0 else { continue }
            // 594: an image being prepared keeps the host up like a live sandbox (nobody need be attached).
            let live = await core.liveSandboxes() + (await core.runningPreparations()).map { "prepare \($0)" }
            let now = Date()
            // 591: its program changed under it — once nothing is live and nobody is connected, exit, so
            // the next command starts a host of the build now installed. (Nothing is lost: no VM runs;
            // sandboxes asleep keep their snapshots — a failed wake's too, e1af862.)
            if let change = await core.executableChange(), live.isEmpty, lock.withLock({ connections == 0 && !stopping }) {
                HostLog.line("my program changed (\(change.rawValue)) and nothing is running — exiting so the next command runs the installed build")
                await shutdown(prepare: false, reply: nil)
            }
            let exit: Bool = lock.withLock {
                guard !stopping else { return false }
                if live.isEmpty && connections == 0 {
                    if let s = idleSince { return now.timeIntervalSince(s) >= timeout }
                    idleSince = now
                } else {
                    idleSince = nil
                }
                return false
            }
            if exit {
                HostLog.line("idle for \(idleTimeoutMinutes.formatted()) min with nothing running — exiting")
                await shutdown(prepare: false, reply: nil)
            }
        }
    }

    var idleSeconds: Double? { lock.withLock { idleSince.map { Date().timeIntervalSince($0) } } }
    var connectionCount: Int { lock.withLock { connections } }

    /// Stop serving, (optionally) Hibernate everything, answer the `host stop` that asked, exit.
    func shutdown(prepare: Bool, reply: HostConnection?) async {
        let first: Bool = lock.withLock {
            if stopping { return false }
            stopping = true
            return true
        }
        guard first else { return }
        // New clients start a new host, which waits for this one's lock before it loads anything.
        let fd = lock.withLock { () -> Int32 in let f = listenFD; listenFD = -1; return f }
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR); close(fd) }
        unlink(store.socket.path)
        // 594 W22: the caller of `host stop` sees each sandbox hibernate (and the host's last step) as
        // it happens, then what was done — the progress every stopping client shows.
        let t0 = ContinuousClock.now
        var rows: [HostStopRow] = []
        if prepare {
            rows = await core.prepareAllForExit { e in
                if let reply { reply.send(HostMessage(event: e)) }
                HostLog.line(e.line)
            }
        }
        if let reply {
            let d = ContinuousClock.now - t0
            let result = HostStopResult(sandboxes: rows, milliseconds: Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15,
                                        version: version)
            reply.send((try? JSONValue(encoding: result)).map { HostMessage.success($0) } ?? .success(.string("stopped")))
            reply.close()
        }
        try? FileManager.default.removeItem(at: store.pidFile)
        HostLog.line("host exiting")
        if lockFD >= 0 { flock(lockFD, LOCK_UN) }
        exit(0)
    }

    // MARK: connections

    private func acceptLoop(_ lfd: Int32) {
        while true {
            let c = accept(lfd, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                return                                       // the listener was closed
            }
            _ = fcntl(c, F_SETFD, FD_CLOEXEC)
            let conn = HostConnection(fd: c)
            let accepted: Bool = lock.withLock {
                if stopping { return false }
                // Counted while open (an attach or a stream keeps the host up); a short request that
                // came and went — `ls`, `host status` — does not restart the idle clock.
                connections += 1
                return true
            }
            guard accepted else { conn.close(); continue }
            Thread.detachNewThread { [self] in self.serve(conn) }
        }
    }

    private func finished(_ conn: HostConnection) {
        conn.close()
        lock.withLock { connections -= 1 }
    }

    /// One connection: its request line, then the operation.
    private func serve(_ conn: HostConnection) {
        let reader = LineReader(fd: conn.fd)
        guard let line = reader.readLine(limit: 1 << 20) else { finished(conn); return }
        let req: HostRequest
        do { req = try HostWire.decoder.decode(HostRequest.self, from: line) } catch {
            conn.send(.failure(HostError(.invalid, "a request this host cannot read (\(error.localizedDescription)) — is the CLI newer than the host? (doz host stop)")))
            finished(conn)
            return
        }
        switch req.op {
        case .attach:
            attach(conn, reader: reader, request: req)
        case .events:
            stream(conn, reader: reader) { [core] in
                let name = req.name
                // 612: `session-status` only to a client that asked (an older one cannot decode the kind).
                let statuses = req.sessionStatus == true
                return core.subscribe().filter { (name == nil || $0.sandbox == name) && (statuses || $0.kind != .sessionStatus) }
                    .map { HostMessage(event: $0) }
            }
        case .netLog where req.follow == true:
            netLogFollow(conn, reader: reader, request: req)
        case .console where req.follow == true:
            consoleFollow(conn, reader: reader, request: req)
        case .hostStop:
            // 594 W18: the web UI reads why the last host exited from this log (`HostExitReason`).
            HostLog.line("host stop requested: hibernating every sandbox, then exiting")
            Task.detached { [self] in await self.shutdown(prepare: true, reply: conn) }
        case .ping:
            Task.detached { [self] in
                let st = await core.status(connections: connectionCount, idleSeconds: idleSeconds,
                                           idleTimeoutMinutes: idleTimeoutMinutes, startedAt: startedAt)
                conn.send((try? JSONValue(encoding: st)).map { HostMessage.success($0) } ?? .failure(HostError(.failed, "status")))
                finished(conn)
            }
        default:
            Task.detached { [self] in
                let msg = await core.handle(req) { e in conn.send(HostMessage(event: e)) }
                conn.send(msg)
                finished(conn)
            }
        }
    }

    /// Stream messages until the client hangs up.
    private func stream<S: AsyncSequence & Sendable>(_ conn: HostConnection, reader: LineReader,
                                                     _ make: @escaping @Sendable () -> S) where S.Element == HostMessage {
        let task = Task.detached {
            do { for try await m in make() { if !conn.send(m) { break } } } catch {}
        }
        watchHangup(conn, reader: reader) { task.cancel() }
    }

    /// Blocks this connection's thread until the peer closes (or shutdownIO), then cleans up.
    private func watchHangup(_ conn: HostConnection, reader: LineReader, _ onHangup: () -> Void) {
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = read(conn.fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
        }
        onHangup()
        finished(conn)
    }

    private func netLogFollow(_ conn: HostConnection, reader: LineReader, request req: HostRequest) {
        Task.detached { [core] in
            do {
                let (log, name) = try await core.connectionLog(req.name)
                let denied = req.deniedOnly == true
                let live = log.stream()
                for r in log.records where !denied || r.verdict == .denied {
                    conn.send(HostMessage(event: HostEvent(kind: .connection, sandbox: name, connection: r, time: r.time)))
                }
                for await r in live where !r.open && (!denied || r.verdict == .denied) {
                    if !conn.send(HostMessage(event: HostEvent(kind: .connection, sandbox: name, connection: r, time: r.time))) { break }
                }
            } catch {
                conn.send(.failure(HostError.from(error)))
                conn.shutdownIO()
            }
        }
        watchHangup(conn, reader: reader) {}
    }

    /// 591 `console --follow`: the boot console's lines (its newest 256 KiB first), then each new
    /// line as it is written — across a cold boot's recreated log — until the client hangs up.
    private func consoleFollow(_ conn: HostConnection, reader: LineReader, request req: HostRequest) {
        let task = Task.detached { [core] in
            do {
                let (url, name) = try await core.bootLogURL(req.name)
                var tail = BootConsoleTail(url: url)
                while !Task.isCancelled {
                    for line in tail.poll() {
                        if !conn.send(HostMessage(event: HostEvent(kind: .console, sandbox: name, text: line))) { return }
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            } catch {
                conn.send(.failure(HostError.from(error)))
                conn.shutdownIO()
            }
        }
        watchHangup(conn, reader: reader) { task.cancel() }
    }

    // MARK: attach relay

    /// One attached (or held) terminal. Identity is this object — never its fd.
    final class AttachState: @unchecked Sendable {
        private let lock = NSLock()
        private var _size: TermSize
        private var _session: SessionConnection?
        private var _key: String?
        private var _gone = false
        init(size: TermSize) { _size = size }
        var size: TermSize { lock.withLock { _size } }
        var gone: Bool { lock.withLock { _gone } }
        var session: SessionConnection? { lock.withLock { _session } }
        /// 609: "sandbox|session" once attached (the size registry's key).
        var key: String? { lock.withLock { _key } }
        func setSize(_ s: TermSize) -> SessionConnection? { lock.withLock { _size = s; return _session } }
        /// False when the client left meanwhile.
        func adopt(_ c: SessionConnection, key: String) -> Bool {
            lock.withLock { if _gone { return false }; _session = c; _key = key; return true }
        }
        func release(_ c: SessionConnection) { lock.withLock { if _session === c { _session = nil } } }
        func markGone() -> SessionConnection? { lock.withLock { _gone = true; let s = _session; _session = nil; return s } }
    }

    /// `attach`: answer `{state: attached|held}`, then relay the terminal. A client that attaches
    /// while the sandbox is not running (and did not ask to wake it) is HELD until it runs, then
    /// attached with the size it last sent. Hibernate closes the connection (the guest session
    /// survives; the client reconnects and is held); the end of the session sends the notice.
    private func attach(_ conn: HostConnection, reader: LineReader, request req: HostRequest) {
        let state = AttachState(size: TermSize(cols: req.cols ?? 80, rows: req.rows ?? 24))
        let core = self.core
        let t0 = ContinuousClock.now
        Task.detached {
            let sandbox: Sandbox, session: String
            do {
                (sandbox, session) = try await core.sandboxForAttach(req.name, session: req.session, wake: req.wake ?? true)
            } catch {
                conn.send(.failure(await core.explain(error)))
                conn.shutdownIO()
                return
            }
            let name = sandbox.spec.name
            // 594 (W17): the client's detach line names the shortest command that reattaches.
            let defaultSession: JSONValue = (await core.defaultSessionName(name)).map { .string($0) } ?? .null
            // 599 (594.B4): the terminal title's {image}.
            let imageName: JSONValue = (await core.imageName(of: name)).map { .string($0) } ?? .null
            var announced = false
            while !state.gone {
                guard let phase = await core.phase(of: name) else {
                    if announced { conn.write(ClientWire.endedNotice(.stopped, text: "\(name) was removed")) }
                    else { conn.send(.failure(HostError(.notFound, "no sandbox \(name)"))) }
                    conn.shutdownIO()
                    return
                }
                let busy = await core.busy(name)
                if phase == .running && !busy {
                    if !announced {
                        // The first attach checks the session is there (a later one gets `ended` from deckhold).
                        let list = (try? await sandbox.sessions()) ?? []
                        if let s = list.first(where: { $0.name == session }), s.isEnded {
                            conn.send(.failure(HostError(.notFound, "session \(session) in \(name) has ended (exit \(s.exitCode.map(String.init) ?? "?"))")))
                            conn.shutdownIO()
                            return
                        } else if !list.contains(where: { $0.name == session }) {
                            let live = list.filter { !$0.isEnded }.map(\.name)
                            conn.send(.failure(HostError(.notFound, "no session \(session) in \(name)" + (live.isEmpty ? "" : " — sessions: \(live.joined(separator: ", "))"))))
                            conn.shutdownIO()
                            return
                        }
                    }
                    do {
                        let c = try await sandbox.attach(session, size: state.size)
                        // Adopted BEFORE the answer: the client sends what it typed ahead as soon as it reads it.
                        guard state.adopt(c, key: name + "|" + session) else { c.close(); return }
                        // 609: its HELLO sized the session (a watcher's 0×0 keeps the size — it never owns it).
                        if state.size.cols > 0, state.size.rows > 0 { core.sizeOwners.claim(name + "|" + session, ObjectIdentifier(state)) }
                        if !announced {
                            conn.send(.success(.object(["state": .string("attached"), "session": .string(session), "sandbox": .string(name),
                                                        "defaultSession": defaultSession, "image": imageName])))
                            announced = true
                        }
                        await core.sessionAttached(name, session: session, ms: ms(since: t0))
                        await Self.pump(c, to: conn, state: state, core: core, sandbox: name, session: session)
                        return
                    } catch {
                        let nowPhase = await core.phase(of: name)
                        let nowBusy = await core.busy(name)
                        if nowPhase == .running && !nowBusy {
                            if !announced { conn.send(.failure(HostError.from(error))) }
                            conn.shutdownIO()
                            return
                        }
                        continue                                  // it went to sleep under us: hold
                    }
                }
                switch phase {
                case .off, .failed:
                    if announced { conn.write(ClientWire.endedNotice(.stopped, text: "\(name) is \(PhaseName.label(phase)) — the session is gone")) }
                    else { conn.send(.failure(HostError(.invalidPhase, "\(name) is \(PhaseName.label(phase)) — `doz start \(name)` boots it"))) }
                    conn.shutdownIO()
                    return
                default:
                    if !announced {
                        conn.send(.success(.object(["state": .string("held"), "session": .string(session), "sandbox": .string(name),
                                                    "defaultSession": defaultSession, "image": imageName,
                                                    "phase": .string(phase.rawValue)])))
                        announced = true
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
        // Client → session, on this thread, for the life of the connection.
        var parser = ClientWire.Parser()
        func feed(_ bytes: [UInt8]) {
            for f in parser.feed(bytes) {
                switch f {
                case .hello(let s), .resize(let s):
                    let c = state.setSize(s)
                    c?.resize(s)
                    if c != nil, s.cols > 0, s.rows > 0, let key = state.key { core.sizeOwners.claim(key, ObjectIdentifier(state)) }
                case .input(let d):
                    // 609: a session has ONE size — the last viewer to send one set it. When another viewer
                    // (`doz attach` from another terminal, another pane) resized it since this one did, this
                    // viewer's keys would reach a program drawing for the OTHER size: an agent's TUI then
                    // draws past this screen's edge and leaves stale glyphs where it means blanks (the web
                    // pane's "space doesn't work"). The viewer a person types in owns the size: re-apply it.
                    let size = state.size
                    if let c = state.session, size.cols > 0, size.rows > 0, let key = state.key,
                       core.sizeOwners.takeForInput(key, ObjectIdentifier(state)) {
                        c.resize(size)
                    }
                    state.session?.send(d)       // dropped while held: nobody to type to
                case .repaint: state.session?.repaint()           // 599: a fresh snapshot (a notice or menu drawn over it)
                }
            }
        }
        let early = reader.takeRemainder()
        if !early.isEmpty { feed(Array(early)) }
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(conn.fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            feed(Array(buf[0..<n]))
        }
        state.markGone()?.close()
        finished(conn)
    }

    /// Session → client, until the session connection ends.
    private static func pump(_ c: SessionConnection, to conn: HostConnection, state: AttachState, core: HostCore,
                             sandbox: String, session: String) async {
        // 599 (594.B1/B2): the bridges' sequences are read here, once for every kind of viewer, and removed.
        var scanner = SessionBridgeScanner()
        // 599d: this terminal hears the notices that come from elsewhere (the GitHub login, the SSH agent).
        core.bridgeState.addViewer(sandbox, conn)
        defer { core.bridgeState.removeViewer(sandbox, conn) }
        for await out in c.output {
            switch out {
            case .snapshot(let d):
                scanner.reset()                     // a replayed screen never copies or opens anything
                conn.write(d)
            case .data(let d):
                let (bytes, events) = scanner.feed(d)
                if !bytes.isEmpty { conn.write(Data(bytes)) }
                for e in events {
                    if let n = await core.bridge(e, sandbox: sandbox, session: session) { conn.write(ClientWire.notice(n)) }
                }
            case .ended(let code):
                let text = code.map { "the \(session) session has ended (exit \($0))" } ?? "there is no \(session) session in \(sandbox)"
                conn.write(ClientWire.endedNotice(code.map { .exited($0) } ?? .noSession, text: text))
                await core.sessionEnded(sandbox, session: session, exitCode: code)
                conn.shutdownIO()
            case .detached(.sandboxStopped):
                conn.write(ClientWire.endedNotice(.stopped, text: "\(sandbox) shut down — the \(session) session is gone"))
                conn.shutdownIO()
            case .detached(.sandboxSleeping), .detached(.transportLost):
                // The guest session lives on: close; the client reconnects and is held until it runs.
                conn.shutdownIO()
            case .detached(.closedByClient):
                break
            case .status:
                break                               // 612: a viewer never gets one (only a status watcher)
            }
        }
        state.release(c)
    }
}

extension HostCore {
    /// The proxy's log of a sandbox (for `net log --follow`).
    func connectionLog(_ name: String?) throws -> (ConnectionLog, String) {
        let m = try get(name)
        guard let log = m.sandbox.egress?.log else {
            throw HostError(.invalid, "\(m.name) is not proxied (network \(m.config.networkName)) — it has no connection log")
        }
        return (log, m.name)
    }
}


/// 606: the ports Dozer's dashboards listen on — `doz ui`'s (`<store>/ui.port`), `doz serve`'s (`<store>/serve/port`
/// while it runs) and the setting `serve.port` (another store's doz serve) — re-read at most every 5 s.
final class DashboardPorts: @unchecked Sendable {
    let store: DozerStore
    private let lock = NSLock()
    private var cached: (at: Date, ports: Set<UInt16>) = (.distantPast, [])
    init(store: DozerStore) { self.store = store }

    @Sendable func current() -> Set<UInt16> {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(cached.at) < 5 { return cached.ports }
        var p = Set<UInt16>()
        for f in [store.root.appendingPathComponent("ui.port"), store.root.appendingPathComponent("serve/port")] {
            if let s = try? String(contentsOf: f, encoding: .utf8), let n = UInt16(s.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 { p.insert(n) }
        }
        let sp = DozerSettings.load().int(SettingKey.servePort)
        if (1...65_535).contains(sp) { p.insert(UInt16(sp)) }
        cached = (Date(), p)
        return p
    }
}
