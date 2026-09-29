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
        Serves http://127.0.0.1:<port> (loopback only, a port the OS picks) until Ctrl-C, and opens it in your browser \
        with a link that works ONCE, for five minutes. The link signs the browser in; nothing else can. \
        `doz ui link` opens another browser (or tab) on a running UI; running `doz ui` again does the same.
        """,
        subcommands: [UIServe.self, UILink.self],
        defaultSubcommand: UIServe.self)
}

/// How a link is handed over.
struct LinkDelivery: ParsableArguments {
    @Flag(name: .long, help: "Open it in the default browser (the default).") var open = false
    @Flag(name: .customLong("print-url"), help: "Print the link on this terminal instead of opening it. The link is a one-use key to the UI: do not paste it anywhere else.") var printURL = false

    func validate(json: Bool) throws {
        if open && printURL { throw ValidationError("--open or --print-url, not both") }
        if printURL && json { throw ValidationError("--print-url prints a key to the UI for a person to use; it is not part of --json output") }
        if printURL && isatty(STDOUT_FILENO) == 0 { throw ValidationError("--print-url prints only to a terminal (stdout is redirected) — the link is a key to the UI") }
    }

    /// Open (LaunchServices — the link never becomes a process argument) or print it on the TTY.
    func deliver(_ url: URL, _ g: GlobalOptions) throws {
        if printURL {
            Out.stdout("open this link once (it expires in a few minutes; it is a key to the UI — do not share it):\n  \(url.absoluteString)\n")
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

    func validate() throws { try delivery.validate(json: g.json) }

    func run() async throws {
        let store = g.dozerStore
        guard store.socketPathFits else {
            throw fail(HostError(.unavailable, UnixSocket.Failure.pathTooLong(store.socket.path).localizedDescription), g)
        }
        if let url = WebControl.requestLink(store) {
            try delivery.deliver(url, g)
            if !g.quiet { Out.stderr("a doz ui is already running for \(store.root.path) — \(delivery.printURL ? "here is" : "opened") a new link to it\n") }
            return
        }
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
        do { server = try await DozerWebServer.bind(data: data, assets: assets, version: DozerCommand.version, settings: settings) } catch {
            throw fail(HostError(.unavailable, "could not listen on 127.0.0.1: \(error)"), g)
        }
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
        try delivery.deliver(server.launchURL, g)
        do { try await server.run() } catch {
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

    func validate() throws { try delivery.validate(json: g.json) }

    func run() async throws {
        guard let url = WebControl.requestLink(g.dozerStore) else {
            throw fail(HostError(.unavailable, "no doz ui is running for \(g.dozerStore.root.path) — start one: doz ui"), g)
        }
        try delivery.deliver(url, g)
    }
}
