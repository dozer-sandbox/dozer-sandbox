import ArgumentParser
import Darwin
import Foundation
import Security
import DozerKit
import DozerHost
import DozerWeb

// 606 — `doz serve`: the dashboard for the OTHER browsers of a home lab (owner rulings at the end of
// changes/606-*/606.01-DESIGN.md, plan 606.02-PLAN.md — workspace). A separate process from `doz ui` (which stays
// on 127.0.0.1): its own lock, socket, port (serve.port, 7443) and devices. Plain HTTP out of the box; HTTPS through
// the person's own reverse proxy (serve.public_origins, serve.trusted_proxies).

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve",
        abstract: "The dashboard for your other computers, tablets and phones: http://<this Mac>.local:7443 on your network.",
        discussion: """
        doz serve (doz serve start) serves this store's dashboard to the other browsers of your network — every network \
        interface of this Mac and Tailscale, never a sandbox's network (a sandbox cannot reach it) — until Ctrl-C (or doz \
        serve stop). With --detach it runs in the background, detached from the terminal, until doz serve stop. Nothing \
        listens beyond this Mac until you run it; doz ui stays this Mac's own dashboard. Its links work from this Mac's \
        own browser too, and are printed by name (<this Mac>.local) and by address.

        A browser gets in ONCE, with an invite: doz serve prints one when it starts (on a terminal), doz serve share makes \
        another, and any browser already in can make one (Devices › Add another browser). An invite is a QR code, a short \
        code and a link — whichever is used first admits one browser, within five minutes. A browser then stays in until \
        it is removed: doz serve devices lists them, doz serve revoke removes one (so can the Devices page, on any of \
        them or on this Mac's doz ui).

        Over plain HTTP everything the dashboard does works, except typing a key or token (the network could read it). \
        Behind your own reverse proxy (Caddy, Traefik, nginx, a Cloudflare tunnel) it is HTTPS: set serve.public_origins \
        and serve.trusted_proxies (and serve.bind loopback for a proxy on this Mac) — doz serve prints what to set, and \
        doz doctor checks it. Remote actions are kept in an audit log: doz serve log. Announced with Bonjour \
        (serve.advertise).
        """,
        subcommands: [ServeStart.self, ServeShare.self, ServeDevices.self, ServeRevoke.self, ServeRename.self, ServeStatus.self,
                      ServeLog.self, ServeStop.self],
        defaultSubcommand: ServeStart.self)
}

/// The store's root as a URL.
private func root(_ g: GlobalOptions) -> URL { g.dozerStore.root }

struct ServeStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start serving (the default) — or, when doz serve runs for this store, say where.")
    @OptionGroup var g: GlobalOptions
    @Option(name: .long, help: "The port, 1024–65535 (default: the setting serve.port, $DOZ_SERVE_PORT; 7443).") var port: Int?
    @Option(name: .long, help: "Where to listen: lan, loopback, or this Mac's addresses separated by commas (default: the setting serve.bind, $DOZ_SERVE_BIND).") var bind: String?
    @Flag(name: .customLong("no-invite"), help: "Do not print an invite at start (doz serve share makes one).") var noInvite = false
    @Flag(name: [.customShort("d"), .long], help: "Start it in the background, detached from this terminal (its log: <store>/serve/serve.log) — print where it listens and an invite, then return. Stop it with doz serve stop.") var detach = false
    /// The detached start's intermediate (its own session): spawn the detached doz serve, print its pid, exit.
    @Flag(name: .customLong("launch-detached"), help: .hidden) var launchDetached = false
    /// The detached doz serve itself (its parent is launchd; no terminal).
    @Flag(name: .customLong("launched"), help: .hidden) var launched = false

    /// The flags a detached start passes on (the settings it was given on its command line).
    var passthrough: [String] {
        var a: [String] = []
        if let port { a += ["--port", String(port)] }
        if let bind { a += ["--bind", bind] }
        return a
    }

    func validate() throws {
        if let port, !(1024...65_535).contains(port) { throw ValidationError("--port is 1024–65535") }
        if let bind, !ServeSettingValues.isBind(bind) { throw ValidationError("--bind is lan, loopback, or this Mac's own addresses separated by commas") }
    }

    func run() async throws {
        let store = g.dozerStore
        let rootURL = store.root
        guard store.socketPathFits else {
            throw fail(HostError(.unavailable, UnixSocket.Failure.pathTooLong(store.socket.path).localizedDescription), g)
        }
        if launchDetached {
            // The intermediate: the detached doz serve in a session of its own; its pid on stdout; exit (its parent → launchd).
            let log = DetachedLauncher.serveLog(rootURL)
            let pid = try DetachedLauncher.spawnDetached(
                DetachedLauncher.serveProcessArgs(executable: HostLauncher.executablePath, store: rootURL.path, extra: passthrough), log: log)
            Out.stdout("\(pid)\n")
            return
        }
        if let r = WebServeControl.request(rootURL, "status", as: WebServeStatus.self), case .success(let st) = r {
            if g.json { Out.jsonLine(st) } else {
                Out.stdout("doz serve is already running for \(rootURL.path) — \(st.origins.first ?? "")\(st.pid.map { " (pid \($0))" } ?? "")\n")
                Out.stdout("Another browser: doz serve share. Its browsers: doz serve devices. Stop it: doz serve stop\n")
            }
            return
        }
        if detach { try await startDetached(rootURL); return }
        let env = ProcessInfo.processInfo.environment
        var flags = configFlags(g)
        if let port { flags[SettingKey.servePort] = .int(port) }
        if let bind { flags[SettingKey.serveBind] = .string(bind) }
        let settings = WebSettingsStore(environment: env, flags: flags)
        let config = WebServeConfig(settings: settings)
        let lockFD: Int32
        do {
            guard let fd = try WebServeControl.takeLock(rootURL) else {
                throw fail(HostError(.unavailable, "another doz serve is starting for this store — try doz serve status"), g)
            }
            lockFD = fd
        } catch let e as HostError { throw fail(e, g) }
        // The port never moves silently: an installed app and a bookmark belong to it.
        if let holder = PortHolder.describe(config.port) {
            WebServeControl.releaseLock(lockFD)
            throw fail(HostError(.unavailable, "serve.port is \(config.port), and \(holder) listens there — stop it, or choose another port: doz config set serve.port N"), g)
        }
        let assets: WebAssets
        do { assets = try WebAssets.load() } catch {
            WebServeControl.releaseLock(lockFD)
            throw fail(HostError(.failed, "the web UI's resources are missing or altered (\(error)) — \(WebAssets.bundleName) must sit beside the doz executable"), g)
        }
        let data = UIRunner.webData(store, env)
        let names = WebMacNames.current()
        let devices = WebDeviceStore(file: WebServeControl.devicesFile(rootURL))
        let audit = WebServeAudit(file: WebServeControl.auditFile(rootURL))
        let state = WebServeState(config: config, names: names, devices: devices, audit: audit,
                                  natSubnet: settings.current.string(SettingKey.natSubnet))
        state.detached = launched
        state.logPath = launched ? DetachedLauncher.serveLog(rootURL).path : nil
        state.responsibleApp = HostCore.responsibleAppDescription
        let server: DozerWebServer
        do {
            server = try await DozerWebServer.bindServe(data: data, assets: assets, version: DozerCommand.version,
                                                        limits: try WebLimits(maximumConnections: 256), settings: settings, serve: state)
        } catch {
            WebServeControl.releaseLock(lockFD)
            throw fail(HostError(.unavailable, "could not listen on port \(config.port): \(error)"), g)
        }
        WebServeControl.writePort(rootURL, state.port)
        let stopping = StopOnce()
        let stop: @Sendable () -> Void = {
            guard stopping.first() else { return }
            Task {
                audit.record(WebAuditEntry(kind: "stop"))
                await server.close()
                WebServeControl.cleanUp(rootURL, listenFD: stopping.listenFD, lockFD: lockFD)
                Out.stderr("\ndoz serve stopped\n")
                Darwin.exit(0)
            }
        }
        do { stopping.listenFD = try WebServeControl.serve(rootURL, server: server, onStop: stop) } catch {
            WebServeControl.releaseLock(lockFD)
            throw fail(HostError(.unavailable, "could not create \(WebServeControl.socket(rootURL).path): \(error.localizedDescription)"), g)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        signal(SIGPIPE, SIG_IGN)
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { stop() }
            src.resume()
            sources.append(src)
        }
        audit.record(WebAuditEntry(kind: "start", outcome: "\(state.origins.first ?? "") \(DozerCommand.version)"))
        var bonjour: WebBonjour?
        if config.advertise && config.bind != .loopback {
            let name = "Dozer on \(names.localHostName ?? "this Mac")"
            let json = g.json
            bonjour = WebBonjour.advertise(name: name, port: state.port) { error, registered in
                if error == 0 {
                    server.advertised = registered ?? name
                } else if !json {
                    Out.stderr("doz serve: not announced with Bonjour — \(WebBonjour.explain(error)). Browsers still reach it by address.\n")
                }
            }
        }
        if launched {
            Out.stdout("doz serve \(DozerCommand.version) (pid \(getpid()), detached: parent \(getppid())) — \(state.origins.joined(separator: "  ")) — store \(rootURL.path)\n")
            Out.stdout("responsible app (Local Network privacy, Bonjour): \(state.responsibleApp ?? "unknown")\n")
        } else if g.json {
            Out.jsonLine(ServeStarted(origins: state.origins, publicOrigins: config.publicOrigins.map(\.description), store: rootURL.path,
                                      port: state.port, pid: Int(getpid())))
        } else {
            Out.stdout(startText(state: state, config: config, rootURL: rootURL))
            if let fw = Firewall.note() { Out.stdout(fw + "\n") }
            if !noInvite {
                if isatty(STDOUT_FILENO) == 1 {
                    let inv = await server.share(by: "the Mac").answer(origin: state.preferredOrigin, alsoAt: state.addressOrigins)
                    Out.stdout("\n" + ServeShare.render(inv) + "\n")
                } else {
                    Out.stdout("To let a browser in: doz serve share (on a terminal — an invite is a key).\n")
                }
            }
            Out.stdout("Ctrl-C stops it. Its browsers: doz serve devices. What they did: doz serve log.\n")
        }
        do { try await server.run() } catch {
            throw fail(HostError(.failed, "doz serve stopped: \(error)"), g)
        }
        while true { try? await Task.sleep(for: .seconds(3600)) }
        withExtendedLifetime((sources, bonjour)) {}
    }

    /// `--detach`: the double spawn (the host's way), wait until it answers, say where, print an invite (a terminal only).
    func startDetached(_ rootURL: URL) async throws {
        let config = WebServeConfig(settings: WebSettingsStore(environment: ProcessInfo.processInfo.environment, flags: {
            var f = configFlags(g)
            if let port { f[SettingKey.servePort] = .int(port) }
            if let bind { f[SettingKey.serveBind] = .string(bind) }
            return f
        }()))
        if let holder = PortHolder.describe(config.port) {
            throw fail(HostError(.unavailable, "serve.port is \(config.port), and \(holder) listens there — stop it, or choose another port: doz config set serve.port N"), g)
        }
        let log = DetachedLauncher.serveLog(rootURL)
        let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
        let pid: pid_t
        do {
            pid = try DetachedLauncher.spawnViaIntermediate(
                DetachedLauncher.serveIntermediateArgs(executable: HostLauncher.executablePath, store: rootURL.path, extra: passthrough), log: log)
        } catch let e as HostError { throw fail(e, g) }
        var st: WebServeStatus?
        let end = Date().addingTimeInterval(20)
        while Date() < end {
            if case .success(let s)? = WebServeControl.request(rootURL, "status", as: WebServeStatus.self), s.state == "running" { st = s; break }
            if kill(pid, 0) != 0 { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard let st else {
            let tail = (try? String(contentsOf: log, encoding: .utf8)).map { String($0.dropFirst(min(size, $0.utf8.count))) }?
                .split(separator: "\n").suffix(3).joined(separator: " / ") ?? ""
            throw fail(HostError(.unavailable, "doz serve did not start\(tail.isEmpty ? "" : ": \(tail)") — its log: \(log.path)"), g)
        }
        if g.json { Out.jsonLine(st); return }
        Out.stdout("doz serve is running in the background (pid \(st.pid ?? Int(pid))) — store \(rootURL.path)\n")
        for o in st.origins.filter({ !$0.contains("[") }) { Out.stdout("  \(o)\n") }
        Out.stdout("  its log: \(log.path)\n")
        if !noInvite {
            if isatty(STDOUT_FILENO) == 1, case .success(let inv)? = WebServeControl.request(rootURL, "share", as: WebServeInviteAnswer.self) {
                Out.stdout("\n" + ServeShare.render(inv) + "\n")
            } else {
                Out.stdout("To let a browser in: doz serve share (on a terminal — an invite is a key).\n")
            }
        }
        Out.stdout("Stop it with doz serve stop. Its browsers: doz serve devices. Where it is: doz serve status.\n")
    }

    struct ServeStarted: Encodable { let origins: [String]; let publicOrigins: [String]; let store: String; let port: Int; let pid: Int }

    final class StopOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var listenFD: Int32 = -1
        func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    func startText(state: WebServeState, config: WebServeConfig, rootURL: URL) -> String {
        var t = "doz serve on \(state.origins.first ?? "port \(state.port)") — store \(rootURL.path)\n"
        let more = state.origins.dropFirst()
        let v6 = more.filter { $0.contains("[") }
        if !more.isEmpty {
            t += "  also: \(more.filter { !$0.contains("[") }.joined(separator: "  "))" + (v6.isEmpty ? "" : " (and \(v6.count) IPv6 address\(v6.count == 1 ? "" : "es"): doz serve status)") + "\n"
        }
        switch config.bind {
        case .lan: t += "  listening on this Mac's network interfaces and Tailscale (never a sandbox's network)\n"
        case .loopback: t += "  listening on 127.0.0.1 and ::1 only — for a reverse proxy on this Mac\n"
        case .addresses(let ips): t += "  listening on \(ips.map(\.description).joined(separator: ", ")) only\n"
        }
        if config.publicOrigins.isEmpty {
            t += "  plain HTTP: everything works except typing keys and tokens. For HTTPS behind your reverse proxy:\n"
            t += "    doz config set serve.public_origins https://doz.example.home   (the address your proxy serves)\n"
            t += "    doz config set serve.trusted_proxies 127.0.0.1,::1             (the proxy's address)\n"
            t += "    doz config set serve.bind loopback                             (a proxy on this Mac)\n"
        } else {
            t += "  behind your proxy: \(config.publicOrigins.map(\.description).joined(separator: ", "))\n"
            t += "    the proxy's upstream: http://\(config.bind == .loopback ? "127.0.0.1" : (state.names.names.first ?? "this-mac")):\(state.port) — pass Host (or X-Forwarded-Host),\n"
            t += "    X-Forwarded-Proto and X-Forwarded-For; allow WebSocket upgrades; do not buffer responses (live updates)\n"
            if config.trustedProxies.isEmpty {
                t += "    ! serve.trusted_proxies is empty: no proxy is believed, so the public address is refused — set it to the proxy's address\n"
            }
            t += "    check it: doz doctor\n"
        }
        return t
    }
}

/// The Application Firewall, read only (`socketfilterfw`): a line when incoming connections to doz would be blocked.
enum Firewall {
    static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }

    static func note() -> String? {
        guard let state = run(["--getglobalstate"]), state.contains("enabled") else { return nil }
        let exe = URL(fileURLWithPath: HostLauncher.executablePath).resolvingSymlinksInPath().path
        let blocked = run(["--getappblocked", exe]) ?? ""
        if blocked.contains("permitted") { return nil }
        let block = run(["--getblockall"]) ?? ""
        if block.contains("ENABLED") || block.contains("enabled") {
            return "  ! the macOS firewall blocks all incoming connections (System Settings › Network › Firewall › Options) — other browsers cannot reach doz serve until you allow it"
        }
        return "  ! the macOS firewall is on: macOS asks whether doz may accept incoming connections — answer Allow (or add \(exe) in System Settings › Network › Firewall › Options)"
    }
}

struct ServeShare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "share",
        abstract: "An invite for one more browser: a QR code, a short code and a link (each works once, for five minutes). Printed only on a terminal.")
    @OptionGroup var g: GlobalOptions

    func validate() throws {
        if g.json { throw ValidationError("an invite is a key for one browser — it is printed for a person, not as --json") }
        if isatty(STDOUT_FILENO) == 0 { throw ValidationError("doz serve share prints only to a terminal (stdout is redirected) — an invite is a key") }
    }

    func run() async throws {
        guard let r = WebServeControl.request(root(g), "share", as: WebServeInviteAnswer.self) else {
            throw fail(HostError(.unavailable, "doz serve is not running for \(root(g).path) — start it: doz serve"), g)
        }
        switch r {
        case .failure(let e): throw fail(e, g)
        case .success(let inv): Out.stdout(Self.render(inv))
        }
    }

    /// The QR code (black on white, whatever the terminal's colours), the code, the link, when it expires.
    static func render(_ inv: WebServeInviteAnswer) -> String {
        var t = ""
        if let rows = inv.qr?.rows, let qr = WebQR(rows: rows) {
            t += qr.terminalText(ansi: ProcessInfo.processInfo.environment["NO_COLOR"] == nil)
        }
        let mins = max(1, Int((inv.expiresAt.timeIntervalSinceNow / 60).rounded()))
        t += "Let one more browser in (whichever is used first, within \(mins) min):\n"
        t += "  scan the QR code with a phone or tablet, or\n"
        t += "  type the code \(inv.code) on the dashboard's sign-in page (\(inv.link.components(separatedBy: "/#").first ?? "")), or\n"
        t += "  open the link: \(inv.link)\n"
        for alt in inv.alternates ?? [] { t += "     or by address: \(alt)\n" }
        t += "It is a key for one browser: do not paste it anywhere else.\n"
        return t
    }
}

struct ServeDevices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "devices", abstract: "The browsers let in: name, when first and last seen, from where, which browser.")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let list: WebServeDevices
        if let r = WebServeControl.request(root(g), "devices", as: WebServeDevices.self) {
            switch r { case .failure(let e): throw fail(e, g); case .success(let l): list = l }
        } else {
            list = WebServeControl.offlineDevices(root(g))
        }
        if g.json { Out.json(list.devices); return }
        guard !list.devices.isEmpty else {
            Out.stdout("No browsers are let in\(list.running ? "" : " (doz serve is not running)") — an invite: doz serve share\n")
            return
        }
        var rows = [["ID", "NAME", "FIRST SEEN", "LAST SEEN", "FROM", "BROWSER"]]
        for d in list.devices {
            rows.append([d.id, d.name, Out.ago(d.created), Out.ago(d.lastSeen), d.lastAddress, String(d.userAgent.prefix(48))])
        }
        Out.stdout(Out.table(rows))
        if !list.running { Out.stdout("(doz serve is not running)\n") }
    }
}

struct ServeRevoke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "revoke",
        abstract: "Remove a browser (by its ID from doz serve devices), or --all: it is signed out at once and needs a new invite.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The device's ID (doz serve devices).") var id: String?
    @Flag(name: .long, help: "Every browser.") var all = false

    func validate() throws {
        if all == (id != nil) { throw ValidationError("name one device's ID, or --all") }
        if let id, !WebRoute.isDeviceID(id) { throw ValidationError("a device's ID is six letters and digits (doz serve devices)") }
    }

    func run() async throws {
        let gone: [WebDeviceView]
        if let r = WebServeControl.request(root(g), "revoke \(all ? "--all" : id!)", as: WebServeControl.Revoked.self) {
            switch r { case .failure(let e): throw fail(HostError(.notFound, e.message), g); case .success(let v): gone = v.revoked }
        } else {
            do { gone = try WebServeControl.offlineRevoke(root(g), id: all ? nil : id, by: "the Mac") } catch let r as WebRejection {
                throw fail(HostError(r == .notFound ? .notFound : .failed, r == .notFound ? "no device \(id ?? "") — doz serve devices lists them" : r.message), g)
            }
        }
        if g.json { Out.json(gone); return }
        Out.stdout(gone.isEmpty ? "No browsers were let in.\n" : gone.map { "removed \($0.name) (\($0.id))\n" }.joined())
    }
}

struct ServeRename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename", abstract: "Give a browser a name you will recognise (\"Kitchen iPad\").")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The device's ID (doz serve devices).") var id: String
    @Argument(help: "Its new name (1–60 characters).") var name: String

    func validate() throws {
        if !WebRoute.isDeviceID(id) { throw ValidationError("a device's ID is six letters and digits (doz serve devices)") }
        if !(1...60).contains(name.count) { throw ValidationError("a name is 1–60 characters") }
    }

    func run() async throws {
        let d: WebDeviceView
        let clean = name.replacingOccurrences(of: "\n", with: " ")
        if let r = WebServeControl.request(root(g), "rename \(id) \(clean)", as: WebDeviceView.self) {
            switch r { case .failure(let e): throw fail(HostError(.notFound, e.message), g); case .success(let v): d = v }
        } else {
            do { d = try WebServeControl.offlineRename(root(g), id: id, to: clean) } catch {
                throw fail(HostError(.notFound, "no device \(id) — doz serve devices lists them"), g)
            }
        }
        if g.json { Out.json(d) } else { Out.stdout("\(d.id) is now \(d.name)\n") }
    }
}

struct ServeStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Whether doz serve runs for this store, where, and how many browsers are let in.")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let st: WebServeStatus
        if let r = WebServeControl.request(root(g), "status", as: WebServeStatus.self) {
            switch r { case .failure(let e): throw fail(e, g); case .success(let s): st = s }
        } else {
            st = WebServeStatus(state: "stopped", origins: [], publicOrigins: [], port: nil, bind: nil,
                                devices: WebDeviceStore.listFile(WebServeControl.devicesFile(root(g))).count, openInvites: nil, advertised: nil)
        }
        if g.json { Out.json(st); return }
        if st.state != "running" {
            Out.stdout("doz serve is not running for \(root(g).path) (\(st.devices) browser\(st.devices == 1 ? "" : "s") let in) — start it: doz serve\n")
            return
        }
        Out.stdout("doz serve is running — \(st.origins.joined(separator: "  "))\n")
        var facts: [String] = []
        if let pid = st.pid { facts.append("pid \(pid)") }
        if let since = st.since { facts.append("since \(Out.ago(since))") }
        if let v = st.version { facts.append("doz \(v)") }
        if st.detached == true { facts.append("detached") }
        if !facts.isEmpty { Out.stdout("  " + facts.joined(separator: " · ") + "\n") }
        if let log = st.log { Out.stdout("  its log: \(log)\n") }
        if let app = st.responsibleApp { Out.stdout("  on behalf of: \(app) (what macOS asks about Local Network access)\n") }
        if !st.publicOrigins.isEmpty { Out.stdout("  behind your proxy: \(st.publicOrigins.joined(separator: ", "))\n") }
        Out.stdout("  \(st.devices) browser\(st.devices == 1 ? "" : "s") let in, \(st.openInvites ?? 0) open invite\((st.openInvites ?? 0) == 1 ? "" : "s")")
        Out.stdout(st.advertised.map { "; announced as \"\($0)\"\n" } ?? "\n")
    }
}

struct ServeLog: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "log", abstract: "What the other browsers did (the audit log): admissions, changes, terminals, refusals.")
    @OptionGroup var g: GlobalOptions
    @Option(name: [.customShort("n"), .customLong("lines")], help: "How many lines (newest last).") var lines = 50

    func run() async throws {
        let entries = Array(WebServeAudit.recent(WebServeControl.auditFile(root(g)), limit: max(1, min(lines, 10_000))).reversed())
        if g.json { Out.json(entries); return }
        guard !entries.isEmpty else { Out.stdout("Nothing yet.\n"); return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for e in entries {
            var parts = [f.string(from: e.time), e.kind]
            if let n = e.deviceName { parts.append(n + (e.device.map { " (\($0))" } ?? "")) }
            if let a = e.address { parts.append("from \(a)") }
            if let r = e.route { parts.append(r) }
            if let a = e.action { parts.append(a) }
            if let s = e.sandbox { parts.append(s) }
            if let o = e.outcome { parts.append("→ \(o)") }
            if let c = e.count { parts.append("×\(c)") }
            Out.stdout(parts.joined(separator: "  ") + "\n")
        }
    }
}

struct ServeStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop the running doz serve of this store (its browsers stay let in for the next one).")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        guard WebServeControl.ask(root(g), "stop") != nil else {
            throw fail(HostError(.unavailable, "doz serve is not running for \(root(g).path)"), g)
        }
        for _ in 0..<50 where FileManager.default.fileExists(atPath: WebServeControl.socket(root(g)).path) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !g.json { Out.stdout("doz serve stopped\n") }
    }
}

/// `doz doctor`'s doz serve lines: whether it runs, and that each configured public origin (your reverse proxy)
/// comes back to THIS doz serve — over https, through a trusted proxy. The proof is a one-use token doz serve
/// issues over serve.sock and answers on `GET /api/v1/serve/probe` only once.
enum ServeDoctor {
    static func checks(store: DozerStore, settings: DozerSettings) -> [DoctorCheck] {
        let root = store.root
        let configured = (settings.string(SettingKey.servePublicOrigins) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard case .success(let st)? = WebServeControl.request(root, "status", as: WebServeStatus.self) else {
            if configured.isEmpty {
                return [DoctorCheck(check: "doz serve", status: .ok, detail: "not running — the dashboard for your other browsers: doz serve")]
            }
            return [DoctorCheck(check: "doz serve", status: .warn,
                                detail: "not running, so serve.public_origins (\(configured.joined(separator: ", "))) cannot be checked — start it: doz serve")]
        }
        var out = [DoctorCheck(check: "doz serve", status: .ok,
                               detail: "running — \(st.origins.first ?? "") · \(st.devices) browser\(st.devices == 1 ? "" : "s") let in")]
        for o in st.publicOrigins { out.append(probe(root, origin: o)) }
        return out
    }

    static func probe(_ root: URL, origin: String) -> DoctorCheck {
        let name = "doz serve via \(origin)"
        guard case .success(let p)? = WebServeControl.request(root, "probe", as: WebServeControl.Probe.self),
              let url = URL(string: origin + "/api/v1/serve/probe") else {
            return DoctorCheck(check: name, status: .warn, detail: "doz serve did not give a probe token — is it another version?")
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        var req = URLRequest(url: url)
        req.setValue(p.token, forHTTPHeaderField: "X-Doz-Probe")
        final class Box: @unchecked Sendable { var data: Data?; var response: HTTPURLResponse?; var error: Error? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        // TEST seam (the proxy probe): DOZ_TEST_SERVE_CA=<pem> — the proxy's certificate is trusted ONLY when it chains to
        // that CA (a scratch one; never the keychain). Without it: the system's trust, as a browser would.
        let anchors = ProcessInfo.processInfo.environment["DOZ_TEST_SERVE_CA"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .map(TestAnchors.certificates) ?? []
        URLSession(configuration: cfg, delegate: anchors.isEmpty ? nil : TestAnchors(anchors), delegateQueue: nil).dataTask(with: req) { d, r, e in
            box.data = d; box.response = r as? HTTPURLResponse; box.error = e
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 8)
        if let e = box.error {
            return DoctorCheck(check: name, status: .fail, detail: "could not reach it from this Mac: \(e.localizedDescription)")
        }
        guard let r = box.response else { return DoctorCheck(check: name, status: .fail, detail: "no answer within 8 s") }
        let body = (box.data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let code = ((body["error"] as? [String: Any])?["code"] as? String) ?? ""
        switch r.statusCode {
        case 200:
            let scheme = body["scheme"] as? String ?? "?"
            if origin.hasPrefix("https:"), scheme != "https" {
                return DoctorCheck(check: name, status: .fail,
                                   detail: "it reached this doz serve, but as plain http — make the proxy send X-Forwarded-Proto: https (and keys stay refused there)")
            }
            return DoctorCheck(check: name, status: .ok, detail: "reaches this doz serve as \(scheme), through a trusted proxy")
        case 403 where code == "host-rejected":
            return DoctorCheck(check: name, status: .fail,
                               detail: "doz serve refused that address — put the proxy's address in serve.trusted_proxies, and make the proxy pass Host (or X-Forwarded-Host) and X-Forwarded-Proto")
        case 404:
            return DoctorCheck(check: name, status: .fail, detail: "something answered, but not this doz serve — check the proxy's upstream (http://<this Mac>:<serve.port>)")
        default:
            return DoctorCheck(check: name, status: .fail, detail: "answered HTTP \(r.statusCode)\(code.isEmpty ? "" : " (\(code))")")
        }
    }
}

/// `DOZ_TEST_SERVE_CA` (tests only): trust exactly these anchors for the doctor's probe.
final class TestAnchors: NSObject, URLSessionDelegate, @unchecked Sendable {
    let anchors: [SecCertificate]
    init(_ anchors: [SecCertificate]) { self.anchors = anchors }

    static func certificates(_ pem: String) -> [SecCertificate] {
        pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().compactMap { part in
            let b64 = part.components(separatedBy: "-----END CERTIFICATE-----")[0].filter { !$0.isWhitespace }
            return Data(base64Encoded: b64).flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        if SecTrustEvaluateWithError(trust, nil) { completionHandler(.useCredential, URLCredential(trust: trust)) } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}
