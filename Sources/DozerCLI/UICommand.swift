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
        abstract: "A local web dashboard for this store: sandboxes, sessions, images, restore points, network, accounts, metrics, events (read-only for now).",
        discussion: """
        Serves http://127.0.0.1:<port> (loopback only; the port this store's last UI had when it is free, so an open page \
        reconnects, else one the OS picks) until Ctrl-C, and opens it in your browser \
        with a link that works ONCE, for five minutes. The link signs the browser in; nothing else can. \
        A page left open by the last doz ui reconnects by itself, still signed in (same port), and then no new tab \
        opens (ui.open_browser: auto | always | never; --open, --no-open). Running `doz ui` while one runs reuses it: \
        a tab opens only when none of its pages is open. `doz ui link` opens another browser (or tab); \
        --new-link (or doz ui link --rotate) signs every page out for a new link.
        """,
        subcommands: [UIServe.self, UILink.self],
        defaultSubcommand: UIServe.self)
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

struct UIServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve", abstract: "Start the UI (the default) — or, when one runs for this store, open a new link to it.")
    @OptionGroup var g: GlobalOptions
    @OptionGroup var delivery: LinkDelivery
    @Flag(name: .customLong("new-link"), help: "End every signed-in page's session (each is told to use the new link) and make a new link — on the running UI, or for the one this starts.") var newLink = false

    func validate() throws { try delivery.validate(json: g.json) }

    func run() async throws {
        let store = g.dozerStore
        guard store.socketPathFits else {
            throw fail(HostError(.unavailable, UnixSocket.Failure.pathTooLong(store.socket.path).localizedDescription), g)
        }
        let mode = delivery.openMode(WebSettingsStore(environment: ProcessInfo.processInfo.environment, flags: configFlags(g)).current)
        // 594 W19: one UI per store — a running one is reused, never a second started; and a tab is
        // opened only when none of its pages is open (owner: "a new web page opening up every time").
        if let running = WebControl.requestStatus(store) {
            if newLink, let url = WebControl.requestRotate(store) {
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
        if newLink { unlink(WebControl.sessionsFile(store).path) }
        let lockFD: Int32
        do {
            guard let fd = try WebControl.takeLock(store) else {
                throw fail(HostError(.unavailable, "another doz ui is starting for this store — try doz ui link"), g)
            }
            lockFD = fd
        } catch let e as HostError { throw fail(e, g) }
        let assets: WebAssets
        do { assets = try WebAssets.load() } catch {
            throw fail(HostError(.failed, "the web UI's resources are missing or altered (\(error)) — \(WebAssets.bundleName) must sit beside the doz executable (make install-cli copies it)"), g)
        }
        // 594: a TEST seam (the headless-browser probes): the UI then never looks at the Mac's Claude
        // Code login (no keychain read, no `claude --version`) — the wizard shows "not signed in".
        let probeClaude = ProcessInfo.processInfo.environment["DOZ_TEST_NO_MAC_LOGIN"] != "1"
        let data = HostWebData(store: store, version: DozerCommand.version, macLogin: {
            // 594: the onboarding wizard's account step — is Claude Code signed in on this Mac (read-only).
            probeClaude && ClaudeLoginStatus.check(configDir: nil, keychain: SystemKeychain(), probeBinary: false).state == .signedIn
        }) {
            Doctor.checks(store: store, claude: probeClaude).map { WebDoctorCheck(check: $0.check, status: $0.status.rawValue, detail: $0.detail) }
        }
        let server: DozerWebServer
        // 591: the Settings page edits the settings file this process's environment names.
        let settings = WebSettingsStore(environment: ProcessInfo.processInfo.environment, flags: configFlags(g))
        // 594 W18: the port this store's last UI had, when free — an open page then reconnects by itself.
        // W19: with the sessions that UI's pages had (cookie digests; kept only for the same port).
        do {
            server = try await DozerWebServer.bind(data: data, assets: assets, version: DozerCommand.version, settings: settings,
                                                   address: WebControl.address(store), sessionsFile: WebControl.sessionsFile(store))
        } catch {
            throw fail(HostError(.unavailable, "could not listen on 127.0.0.1: \(error)"), g)
        }
        WebControl.rememberPort(store, server.origin.port)
        let listenFD: Int32
        do { listenFD = try WebControl.serve(store, server: server) } catch {
            throw fail(HostError(.unavailable, "could not create \(WebControl.socket(store).path): \(error.localizedDescription)"), g)
        }
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
        // 594 W19: a page left open by the last doz ui reconnects by itself (same port, same session)
        // within a second or two — then no new tab: it is told this UI restarted. Otherwise one tab.
        if delivery.printURL {
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
            WebControl.cleanUp(store, listenFD: listenFD, lockFD: lockFD)
            throw fail(HostError(.failed, "the UI server stopped: \(error)"), g)
        }
        withExtendedLifetime(sources) {}
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
            throw fail(HostError(.unavailable, "no doz ui is running for \(g.dozerStore.root.path) — start one: doz ui"), g)
        }
        try delivery.deliver(url, g)
    }
}
