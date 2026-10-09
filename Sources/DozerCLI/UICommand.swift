import ArgumentParser
import CoreServices
import Darwin
import Foundation
import DozerKit
import DozerHost
import DozerWeb

// 590 — `doz ui`: a local web UI for the whole store, served by THIS process (a client of the
// store's host, like every other command) on 127.0.0.1 and a port the OS picks. Phase 1 is a
// read-only dashboard. The security design is changes/590-*/590.01-DESIGN.md (workspace).

struct UICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ui",
        abstract: "A local web dashboard for this store: sandboxes, sessions, terminals, images, restore points, network, accounts, metrics, events.",
        discussion: """
        doz ui (doz ui start) serves http://127.0.0.1:<port> — this Mac only — until Ctrl-C, and opens it in your browser \
        with a link that works ONCE, for five minutes. The link signs the browser in (for 14 days without use, renewed \
        while a page is open); nothing else can. The port is the setting ui.port: 0 = automatic (the port this store's \
        last doz ui had, when it is free, so an open page reconnects; else one the system picks) or a fixed port. \
        The dashboard can be installed as an app (Chrome: Install; Safari: Add to Dock); while doz ui is not running \
        it shows a page that reconnects by itself. \
        A page left open by the last doz ui reconnects by itself, still signed in (same port), and then no new tab \
        opens (ui.open_browser: auto | always | never; --open, --no-open). Running `doz ui` while one runs reuses it: \
        a tab opens only when none of its pages is open. `doz ui link` opens another browser (or tab); \
        `doz ui restart` restarts the running one (open pages and their terminals carry on by themselves); \
        --new-link (or doz ui link --rotate) signs every page out for a new link.
        """,
        subcommands: [UIStart.self, UILink.self, UIRestart.self, UIServe.self],
        defaultSubcommand: UIStart.self)
}

/// How a link is handed over.
struct LinkDelivery: ParsableArguments {
    @Flag(name: .long, help: "Open a browser tab, even when a page is already open.") var open = false
    @Flag(name: .customLong("no-open"), help: "Never open a browser tab (doz ui link opens one later).") var noOpen = false
    @Flag(name: .customLong("print-url"), help: "Print the link on this terminal instead of opening it. The link is a one-use key to the UI: do not paste it anywhere else.") var printURL = false

    func validate(json: Bool) throws {
        if open && printURL { throw ValidationError("--open or --print-url, not both") }
        if open && noOpen { throw ValidationError("--open or --no-open, not both") }
        if printURL && json { throw ValidationError("--print-url prints a key to the UI for a person to use; it is not part of --json output") }
        if printURL && isatty(STDOUT_FILENO) == 0 { throw ValidationError("--print-url prints only to a terminal (stdout is redirected) — the link is a key to the UI") }
    }

    /// 594 W19: when a tab opens — `--open` always, `--no-open` never, else the setting
    /// `ui.open_browser` (auto: only when no page of this UI is open).
    func openMode(_ settings: DozerSettings) -> String {
        if open { return "always" }
        if noOpen { return "never" }
        return settings.string(SettingKey.openBrowser) ?? "auto"
    }

    /// Open (LaunchServices — the link never becomes a process argument) or print it on the TTY.
    func deliver(_ url: URL, _ g: GlobalOptions) throws {
        if printURL {
            Out.stdout("open this link once (it expires in a few minutes; it is a key to the UI — do not share it):\n  \(url.absoluteString)\n")
            return
        }
        // 594 W19: a TEST seam (the probes count the tabs `doz ui` opens): record that a tab would
        // open, and on which origin — never the link itself (it is a key).
        if let log = ProcessInfo.processInfo.environment["DOZ_TEST_BROWSER_LOG"], !log.isEmpty {
            let line = "open \(url.scheme ?? "http")://\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")\n"
            if let h = FileHandle(forWritingAtPath: log) ?? { FileManager.default.createFile(atPath: log, contents: nil); return FileHandle(forWritingAtPath: log) }() {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            }
            return
        }
        let status = LSOpenCFURLRef(url as CFURL, nil)
        guard status == noErr else {
            throw fail(HostError(.failed, "could not open a browser (LaunchServices \(status)) — try doz ui link --print-url"), g)
        }
    }
}

/// What `doz ui start` takes (and the hidden `serve` it was called before).
struct UIStartOptions: ParsableArguments {
    @OptionGroup var g: GlobalOptions
    @OptionGroup var delivery: LinkDelivery
    @Flag(name: .customLong("new-link"), help: "End every signed-in page's session (each is told to use the new link) and make a new link — on the running UI, or for the one this starts.") var newLink = false
    @Option(name: .long, help: "The port, on 127.0.0.1 only: 1024–65535, or 0 = automatic (default: the setting ui.port, $DOZ_UI_PORT).") var port: Int?
    /// `doz ui restart`'s own re-start (no tab, no printed link: the open pages reconnect by themselves).
    @Flag(name: .customLong("restarted"), help: .hidden) var restarted = false

    func validate() throws {
        try delivery.validate(json: g.json)
        if let port, port != 0, !(1024...65_535).contains(port) { throw ValidationError("--port is 0 (automatic) or a port 1024–65535") }
    }

    /// The settings flags this command gives (the store, the port).
    var flags: [String: TOMLValue] {
        var f = configFlags(g)
        if let port { f[SettingKey.uiPort] = .int(port) }
        return f
    }
}

struct UIStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start the UI (the default) — or, when one runs for this store, open a new link to it.")
    @OptionGroup var o: UIStartOptions

    func validate() throws { try o.validate() }

    func run() async throws { try await UIRunner(o: o).run() }
}

/// The command's earlier name (before `doz serve`, the dashboard for other machines, took the word).
struct UIServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve", abstract: "The earlier name of doz ui start.", shouldDisplay: false)
    @OptionGroup var o: UIStartOptions

    func validate() throws { try o.validate() }

    func run() async throws {
        if !o.g.json && !o.g.quiet { Out.stderr("doz: `doz ui serve` is now `doz ui start` (or just `doz ui`)\n") }
        try await UIRunner(o: o).run()
    }
}

/// `doz ui restart`: the running UI stops (its pages told it is restarting) and starts again as the doz
/// on your PATH now — after an upgrade, the new one — on the same port (or the one ui.port now names: the
/// open pages follow). Sessions are kept; open terminals reattach by themselves.
struct UIRestart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart",
        abstract: "Restart the running UI of this store — the same port (or a changed ui.port), open pages stay signed in and reconnect by themselves.")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let store = g.dozerStore
        guard let r = WebControl.requestRestart(store) else {
            throw fail(HostError(.unavailable, WebControl.holderNote(store) ?? "no doz ui is running for \(store.root.path) — start one: doz ui"), g)
        }
        let old: String
        switch r {
        case .failure(let e): throw fail(e, g)
        case .success(let o): old = o
        }
        if !g.json && !g.quiet { Out.stderr("doz ui at \(old) is restarting…\n") }
        // The old one goes (its control socket with it), then the new one answers.
        let end = Date().addingTimeInterval(20)
        var gone = false
        var back: (origin: String, pages: Int)?
        while Date() < end {
            let s = WebControl.requestStatus(store)
            if s == nil { gone = true } else if gone { back = s; break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard let back else {
            throw fail(HostError(.failed, "doz ui did not come back within 20 s — its terminal says why; start it again: doz ui"), g)
        }
        if g.json {
            Out.jsonLine(["origin": back.origin, "previous": old])
        } else {
            Out.stdout("doz ui restarted on \(back.origin)\(back.origin == old ? "" : " (it was \(old) — the pages there say where it went; it opens the dashboard here)")\n")
        }
    }
}

/// The body of `doz ui start` (and `serve`).
struct UIRunner {
    let o: UIStartOptions
    var g: GlobalOptions { o.g }
    var delivery: LinkDelivery { o.delivery }

    func run() async throws {
        let store = g.dozerStore
        guard store.socketPathFits else {
            throw fail(HostError(.unavailable, UnixSocket.Failure.pathTooLong(store.socket.path).localizedDescription), g)
        }
        let env = ProcessInfo.processInfo.environment
        let mode = delivery.openMode(WebSettingsStore(environment: env, flags: o.flags).current)
        // 594 W19: one UI per store — a running one is reused, never a second started; and a tab is
        // opened only when none of its pages is open (owner: "a new web page opening up every time").
        if let running = WebControl.requestStatus(store) {
            if o.newLink, let url = WebControl.requestRotate(store) {
                if mode == "never" && !delivery.printURL {
                    Out.stdout("doz ui is running at \(running.origin) — every page signed out; open a page: doz ui link\(g.store.map { " --store \($0)" } ?? "")\n")
                } else {
                    try delivery.deliver(url, g)
                    if !g.quiet { Out.stderr("doz ui at \(running.origin): every page's session ended — \(delivery.printURL ? "here is" : "opened") the new link\n") }
                }
                return
            }
            if delivery.printURL || mode == "always" || (mode == "auto" && running.pages == 0), let url = WebControl.requestLink(store) {
                try delivery.deliver(url, g)
                if !g.quiet { Out.stderr("a doz ui is already running for \(store.root.path) — \(delivery.printURL ? "here is" : "opened") a new link to it\n") }
                return
            }
            let pages = running.pages == 1 ? "1 page is open" : "\(running.pages) pages are open"
            Out.stdout("doz ui is already running at \(running.origin) — \(pages)\(mode == "auto" ? "; not opening another (--open does)" : "; doz ui link opens one")\n")
            return
        }
        // 605: the kept sessions end as "a new link was made" (their pages are told why), not silently.
        if o.newLink { WebSessionStore.revokeKept(sessions: WebControl.sessionsFile(store), revoked: WebControl.revokedFile(store)) }
        let lockFD: Int32
        do {
            guard let fd = try WebControl.takeLock(store) else {
                throw fail(HostError(.unavailable, WebControl.holderNote(store) ?? "another doz ui is starting for this store — try doz ui link"), g)
            }
            lockFD = fd
        } catch let e as HostError { throw fail(e, g) }
        let assets: WebAssets
        do { assets = try WebAssets.load() } catch {
            throw fail(HostError(.failed, "the web UI's resources are missing or altered (\(error)) — \(WebAssets.bundleName) must sit beside the doz executable (make install-cli copies it)"), g)
        }
        let data = UIRunner.webData(store, env)
        // 591: the Settings page edits the settings file this process's environment names.
        let settings = WebSettingsStore(environment: env, flags: o.flags)
        // 605 (owner Q10): `ui.port` — 0: 594 W18's reuse (the port this store's last UI had, when free —
        // an open page then reconnects by itself — else the OS's pick, said below); N: exactly N, never a
        // silent move (an installed app belongs to its port).
        let configured = settings.int(SettingKey.uiPort)
        let address: WebLoopbackAddress
        if configured != 0 {
            guard let a = WebLoopbackAddress(reusing: configured) else {
                WebControl.cleanUp(store, listenFD: -1, lockFD: lockFD)
                throw fail(HostError(.unavailable, "ui.port is \(configured), and \(PortHolder.describe(configured) ?? "another program") listens on 127.0.0.1:\(configured) — stop it, or choose another port: doz config set ui.port N (0 = automatic)"), g)
            }
            address = a
        } else {
            address = WebControl.address(store)
        }
        let remembered = WebControl.rememberedPort(store)
        // 605: `doz ui restart` onto another port (ui.port changed): the open pages cannot follow.
        let server: DozerWebServer
        do {
            server = try await DozerWebServer.bind(data: data, assets: assets, version: DozerCommand.version, settings: settings,
                                                   address: address, fixedPort: configured != 0, sessionsFile: WebControl.sessionsFile(store),
                                                   revokedFile: WebControl.revokedFile(store), operationsFile: WebControl.operationsFile(store))
        } catch {
            WebControl.cleanUp(store, listenFD: -1, lockFD: lockFD)
            throw fail(HostError(.unavailable, "could not listen on 127.0.0.1\(configured != 0 ? ":\(configured)" : ""): \(error)"), g)
        }
        if configured == 0, let remembered, remembered != server.origin.port, !g.json {
            Out.stderr("doz ui: this store's last port, 127.0.0.1:\(remembered), is taken (by \(PortHolder.describe(remembered) ?? "another program")) — listening on 127.0.0.1:\(server.origin.port) instead. A page or an installed app of the old port needs a new link (doz ui link); a fixed port: doz config set ui.port N\n")
        }
        WebControl.rememberPort(store, server.origin.port)
        let fds = ControlFDs(lock: lockFD)
        let flags = o.flags, json = g.json
        let restarter = WebControl.Restarter(check: {
            // Where the new process will listen: ui.port as the file says NOW (a flag or variable still wins).
            let next = WebSettingsStore(environment: env, flags: flags).int(SettingKey.uiPort)
            guard next != 0, next != server.origin.port else { return nil }
            guard !WebLoopbackAddress.inUse(next) else {
                return "ui.port is \(next), and \(PortHolder.describe(next) ?? "another program") listens on 127.0.0.1:\(next) — doz ui stays on \(server.origin.port)"
            }
            return nil
        }, restart: {
            fds.restarting = true
            Task {
                let next = WebSettingsStore(environment: env, flags: flags).int(SettingKey.uiPort)
                if next != 0, next != server.origin.port, let to = try? WebOrigin(port: next) {
                    await server.close(.moving(to))
                } else {
                    await server.close(.restarting)
                }
                WebControl.cleanUp(store, listenFD: fds.listen, lockFD: fds.lock)
                if !json { Out.stderr("\ndoz ui restarting…\n") }
                UIRunner.reexec()
            }
        })
        let listenFD: Int32
        do { listenFD = try WebControl.serve(store, server: server, restarter: restarter) } catch {
            throw fail(HostError(.unavailable, "could not create \(WebControl.socket(store).path): \(error.localizedDescription)"), g)
        }
        fds.listen = listenFD
        setvbuf(stdout, nil, _IOLBF, 0)
        signal(SIGPIPE, SIG_IGN)
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler {
                Task {
                    await server.close()
                    WebControl.cleanUp(store, listenFD: listenFD, lockFD: lockFD)
                    Out.stderr("\ndoz ui stopped\n")
                    Darwin.exit(0)
                }
            }
            src.resume()
            sources.append(src)
        }
        if g.json {
            Out.jsonLine(["origin": server.origin.value, "store": store.root.path, "pid": String(getpid())])
        } else {
            // The origin, never the link: the link is a key (a browser gets it, or --print-url's TTY).
            Out.stdout("doz ui on \(server.origin.value) — store \(store.root.path)\n")
            Out.stdout("Ctrl-C stops it. Another browser or tab: doz ui link\(g.store.map { " --store \($0)" } ?? "")\n")
        }
        let serving = Task { try await server.run() }
        // 611: doz ui looks for an update when it starts (whatever the day's check said), then once a day while it runs;
        // the dashboard's banner reads what was found (UpdateChecker.remembered) — the page never asks the network.
        Task.detached {
            var force = true
            while true {
                let ctx = UpdateContext.current(version: DozerCommand.version, executable: HostLauncher.executablePath)
                if ctx.disabledReason(manual: false) == nil { _ = await UpdateChecker.check(ctx, force: force) }
                force = false
                try? await Task.sleep(nanoseconds: UInt64(UpdateChecker.interval * 1_000_000_000))
            }
        }
        // 594 W19: a page left open by the last doz ui reconnects by itself (same port, same session)
        // within a second or two — then no new tab: it is told this UI restarted. Otherwise one tab.
        // 605: after `doz ui restart` never a tab or a printed link — the open pages come back by themselves.
        if o.restarted, let remembered, remembered != server.origin.port {
            // The pages of the old port were told where doz ui went; a browser rule keeps them from
            // following by themselves — so open the dashboard here (as doz ui does with no page open).
            if mode == "never" {
                if !g.json { Out.stdout("restarted on another port — the open pages cannot follow it: doz ui link opens one here\n") }
            } else {
                try delivery.deliver(server.launchURL, g)
                if !g.json { Out.stdout("restarted on another port — opened the dashboard there (the old pages say where it went)\n") }
            }
        } else if o.restarted {
            if await server.waitForPage(seconds: 6) {
                server.tellPages("doz ui restarted — \(DozerCommand.version)")
                if !g.json { Out.stdout("restarted — the open pages reconnected\n") }
            }
        } else if delivery.printURL {
            try delivery.deliver(server.launchURL, g)
        } else if mode == "always" {
            try delivery.deliver(server.launchURL, g)
        } else if mode == "never" {
            if !g.json { Out.stdout("Not opening a browser (ui.open_browser = never, or --no-open): doz ui link opens a page.\n") }
        } else if await server.hasSessions(), await server.waitForPage(seconds: 2.5) {
            server.tellPages("doz ui restarted — \(DozerCommand.version)")
            if !g.json { Out.stdout("reconnected to the open page — no new tab (doz ui --open opens one)\n") }
        } else {
            try delivery.deliver(server.launchURL, g)
        }
        do { try await serving.value } catch {
            if !fds.restarting {
                WebControl.cleanUp(store, listenFD: listenFD, lockFD: lockFD)
                throw fail(HostError(.failed, "the UI server stopped: \(error)"), g)
            }
        }
        // 605: the listener closed for `doz ui restart` — the restart replaces this process (exec); never
        // return (that would exit before it does).
        while fds.restarting { try? await Task.sleep(for: .seconds(1)) }
        withExtendedLifetime(sources) {}
    }

    /// The dashboard's data source (shared by doz ui and doz serve).
    static func webData(_ store: DozerStore, _ env: [String: String]) -> HostWebData {
        // 594: a TEST seam (the headless-browser probes): the UI then never looks at the Mac's Claude
        // Code login (no keychain read, no `claude --version`) — the wizard shows "not signed in".
        let probeClaude = env["DOZ_TEST_NO_MAC_LOGIN"] != "1"
        let data = HostWebData(store: store, version: DozerCommand.version, macLogin: {
            // 594: the onboarding wizard's account step — is Claude Code signed in on this Mac (read-only).
            probeClaude && ClaudeLoginStatus.check(configDir: nil, keychain: SystemKeychain(), probeBinary: false).state == .signedIn
        }) {
            Doctor.checks(store: store, claude: probeClaude).map { WebDoctorCheck(check: $0.check, status: $0.status.rawValue, detail: $0.detail) }
        }
        // 599f: the New Sandbox wizard reads project files with the CLI's own parser (Yams stays here).
        WebProjectFiles.install { text, file in try DozerProject.parse(text, file: file) }
        return data
    }

    /// The control socket's and the lock's descriptors, for the restart (the socket's is known only
    /// once it listens).
    final class ControlFDs: @unchecked Sendable {
        var listen: Int32 = -1
        /// `doz ui restart` is under way: the server's end is not the command's.
        var restarting = false
        let lock: Int32
        init(lock: Int32) { self.lock = lock }
    }

    /// 605: become `doz ui start` again — the same arguments (but never a tab, a printed link or a new
    /// link), through the PATH when started by name, so an upgrade's new `doz` is the one that runs.
    /// The same process (pid, terminal); every descriptor but stdin/stdout/stderr is closed by the exec.
    static func reexec() -> Never {
        var args = CommandLine.arguments
        args.removeAll { ["--open", "--print-url", "--new-link", "--restarted"].contains($0) }
        if let i = args.firstIndex(of: "ui") {
            if i + 1 < args.count, args[i + 1] == "start" || args[i + 1] == "serve" { args[i + 1] = "start" } else { args.insert("start", at: i + 1) }
        }
        args.append("--restarted")
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] { signal(sig, SIG_DFL) }
        fflush(stdout)
        fflush(stderr)
        for fd in 3..<max(3, Int32(getdtablesize())) { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        execvp(args[0], &cargs)
        Out.stderr("doz ui could not restart itself (\(String(cString: strerror(errno)))) — start it again: doz ui\n")
        Darwin.exit(1)
    }
}

/// 605: which program listens on a loopback port (for "it is taken by …") — `lsof`, read-only.
enum PortHolder {
    static func describe(_ port: Int) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var pid: String?, name: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("p"), pid == nil { pid = String(line.dropFirst()) }
            if line.hasPrefix("c"), name == nil { name = String(line.dropFirst()) }
        }
        guard let pid else { return nil }
        return "\(name ?? "a program") (pid \(pid))"
    }
}

struct UILink: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "link",
        abstract: "A new one-use link to the running UI of this store (opened, or printed with --print-url).")
    @OptionGroup var g: GlobalOptions
    @OptionGroup var delivery: LinkDelivery
    @Flag(name: .long, help: "First end every signed-in page's session (each is told to use the new link).") var rotate = false

    func validate() throws {
        try delivery.validate(json: g.json)
        if delivery.noOpen && !delivery.printURL { throw ValidationError("doz ui link hands a link over: --no-open would drop it (--print-url prints it)") }
    }

    func run() async throws {
        guard let url = rotate ? WebControl.requestRotate(g.dozerStore) : WebControl.requestLink(g.dozerStore) else {
            throw fail(HostError(.unavailable, WebControl.holderNote(g.dozerStore) ?? "no doz ui is running for \(g.dozerStore.root.path) — start one: doz ui"), g)
        }
        try delivery.deliver(url, g)
    }
}
