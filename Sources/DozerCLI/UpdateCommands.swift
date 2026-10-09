import ArgumentParser
import Darwin
import DozerHost
import DozerKit
import Foundation

// 611 — `doz update [--check] [--channel X]`, the after-command notice/auto-update, and `doz host restart`.

struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update",
        abstract: "Look for a newer doz on your channel and install it (Homebrew: brew upgrade; a tarball install: the signed download). --check only looks; --channel switches channel.",
        discussion: """
        The feed is signed with Dozer's own key, and doz installs only what verifies — never an older build. \
        Channels: stable, beta (beta and stable releases), canary (every build first). A Homebrew install has one \
        formula per channel (doz, doz-beta, doz-canary): --channel switches formulas — Homebrew uninstalls one and \
        installs the other; your store, sandboxes and settings stay. A running host keeps its build until \
        doz host restart. The setting updates.mode decides what doz does by itself: notify (default), auto or off. \
        Exit codes: 0 · 10 with --check when an update is available.
        """)

    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "Only look: say whether a newer doz is available (exit 10 when it is).") var check = false
    @Option(name: .long, help: "Switch to this channel: stable, beta or canary (asks first; --yes skips the question).") var channel: String?
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false

    struct Answer: Encodable {
        var current: String
        var channel: String
        var mode: String
        var install: String
        var available: UpdateEntry?
        var upToDate: Bool
        var disabled: String?
        var problem: String?
        var installed: String?
        var note: String?
    }

    func validate() throws {
        if let c = channel, UpdateChannel(rawValue: c) == nil { throw ValidationError("--channel: stable, beta or canary") }
        if check && channel != nil { throw ValidationError("--check only looks; --channel switches — one at a time") }
    }

    func run() async throws {
        if let c = channel.flatMap(UpdateChannel.init(rawValue:)) { return try await switchChannel(c) }
        let ctx = UpdateContext.current(version: DozerCommand.version, executable: HostLauncher.executablePath)
        let r = await UpdateChecker.check(ctx, manual: true)
        var a = Answer(current: ctx.current, channel: ctx.channel.rawValue, mode: ctx.mode.rawValue, install: UpdateHook.describe(ctx.method),
                       available: r.available, upToDate: r.available == nil && r.disabled == nil && !r.offline, disabled: r.disabled, problem: r.problem)
        if let d = r.disabled {
            if g.json { Out.json(a) } else { Out.stdout("doz \(ctx.current): updates — \(d)\n") }
            return
        }
        if let p = r.problem, !g.json { Out.stderr("doz: \(p)\n") }
        if r.offline && r.available == nil {
            a.note = "the update feed could not be reached"
            if g.json { Out.json(a) } else { Out.stdout("doz \(ctx.current): the update feed could not be reached (\(ctx.feedURL.absoluteString)) — try again later\n") }
            return
        }
        guard let e = r.available else {
            if g.json { Out.json(a) } else { Out.stdout("doz \(ctx.current) is the newest on the \(ctx.channel.rawValue) channel\n") }
            return
        }
        if check {
            if g.json { Out.json(a) } else { Out.stdout(UpdateChecker.noticeLine(e, ctx) + "\n") }
            throw ExitCode(10)
        }
        do {
            let line = try await UpdateHook.install(e, ctx, store: g.dozerStore, quiet: g.json)
            a.installed = e.version
            if g.json { Out.json(a) } else { Out.stdout(line + "\n") }
        } catch {
            throw fail(HostError(.failed, "\(error)"), g)
        }
    }

    /// `--channel X`: the setting, and for a Homebrew install the formula of that channel — never an older build.
    func switchChannel(_ c: UpdateChannel) async throws {
        let before = UpdateContext.current(version: DozerCommand.version, executable: HostLauncher.executablePath)
        try confirm("Switch doz to the \(c.rawValue) channel?", yes: yes, g)
        do { try DozerSettings.load().writing(SettingKey.updatesChannel, .string(c.rawValue)) } catch {
            throw fail(HostError(.failed, "could not save updates.channel: \(error)"), g)
        }
        var ctx = before
        ctx.channel = c
        guard case .homebrew(let formula) = before.method, formula != c.formula else {
            let r = await UpdateChecker.check(ctx, manual: true)
            let tail = r.available.map { " — " + UpdateChecker.noticeLine($0, ctx) } ?? ""
            if g.json { Out.json(["channel": c.rawValue]) } else { Out.stdout("updates.channel = \(c.rawValue)\(tail)\n") }
            return
        }
        // The newest build of the new channel must not be older than this doz (never a downgrade).
        let r = await UpdateChecker.check(ctx, manual: true)
        let newest = r.available?.version
        if newest == nil {
            Out.stdout("updates.channel = \(c.rawValue). The \(c.rawValue) channel has nothing newer than doz \(before.current), so "
                       + "\(formula) stays installed for now (doz never installs an older build); doz offers the switch "
                       + "(doz update --channel \(c.rawValue)) once \(c.rawValue) passes \(before.current).\n")
            return
        }
        guard let brew = UpdateInstaller.brew() else { throw fail(HostError(.failed, "Homebrew's brew was not found"), g) }
        if let busy = UpdateInstaller.busyReason(store: g.dozerStore) {
            Out.stderr("note: \(busy) — they keep running on doz \(before.current) until doz host restart\n")
        }
        Out.stderr("switching Homebrew formulas: \(formula) → \(c.formula) (\(Distribution.tap)/\(c.formula)); your store and settings stay\n")
        do {
            try UpdateInstaller.switchFormula(from: formula, to: c.formula, brew: brew) { Out.stderr($0) }
        } catch {
            throw fail(HostError(.failed, "\(error)"), g)
        }
        UpdateHook.recordInstalled(newest!, ctx)
        Out.stdout("doz is now \(c.formula) (\(c.rawValue)) — \(UpdateHook.afterInstallLine(newest!, store: g.dozerStore))\n")
    }
}

/// The checks and installs every command shares.
enum UpdateHook {
    static func describe(_ m: InstallMethod) -> String {
        switch m {
        case .homebrew(let f): "homebrew (\(f))"
        case .tarball(let p): "tarball (\(p.path))"
        case .development: "development build"
        }
    }

    /// Install `e` the way this doz was installed. Returns the line to show.
    static func install(_ e: UpdateEntry, _ ctx: UpdateContext, store: DozerStore, quiet: Bool) async throws -> String {
        let say: @Sendable (String) -> Void = { text in if !quiet { Out.stderr(text) } }
        switch ctx.method {
        case .development:
            throw UpdateInstaller.Failure("this doz is a development build — it is not updated (a release install is: Homebrew, or the release tarball)")
        case .homebrew(let formula):
            if let f = ctx.method.formulaChannel, f != ctx.channel {
                throw UpdateInstaller.Failure("this doz is the \(f.rawValue) formula (\(formula)) and updates.channel is \(ctx.channel.rawValue) — doz update --channel \(ctx.channel.rawValue) switches")
            }
            guard let brew = UpdateInstaller.brew() else { throw UpdateInstaller.Failure("Homebrew's brew was not found — upgrade with: brew upgrade \(formula)") }
            say("updating doz to \(e.version): brew upgrade \(formula)\n")
            UpdateInstaller.refreshTap(brew: brew, output: say)
            guard UpdateInstaller.runBrew(brew, ["upgrade", formula], output: say) == 0 else {
                throw UpdateInstaller.Failure("brew upgrade \(formula) failed — doz \(ctx.current) is unchanged")
            }
        case .tarball(let prefix):
            say("updating doz to \(e.version): downloading \(e.archiveName) (\(e.size / 1_048_576) MiB) — checked against its signature before anything changes\n")
            let env = ProcessInfo.processInfo.environment
            let adhoc = env["DOZ_TEST_UPDATE_ALLOW_ADHOC"] == "1" && TestSafety.guarded(env)
            _ = try await UpdateInstaller.installTarball(e, prefix: prefix, allowAdhoc: adhoc, download: UpdateInstaller.urlSessionDownload)
        }
        recordInstalled(e.version, ctx)
        return afterInstallLine(e.version, store: store)
    }

    static func recordInstalled(_ version: String, _ ctx: UpdateContext) {
        var s = UpdateState.load(ctx.stateURL)
        s.installed = version
        s.installedAt = Date()
        s.save(ctx.stateURL)
    }

    /// "Updated to X — restart to apply: doz host restart" while a host (of the previous build) runs; else just done.
    static func afterInstallLine(_ version: String, store: DozerStore) -> String {
        store.hostIsRunning() ? UpdateChecker.installedLine(version) : "Updated to \(version) — the next doz command runs it"
    }

    /// The command words (the first ones that are not options).
    static func words(_ args: [String]) -> [String] {
        var out: [String] = []
        var skip = false
        for a in args {
            if skip { skip = false; continue }
            if ["--store", "--progress"].contains(a) { skip = true; continue }
            if a.hasPrefix("-") { continue }
            out.append(a)
        }
        return out
    }

    /// Whether a command's run may be followed by the update check: a person at a terminal (stdout AND stderr),
    /// never --json or -q, never the commands that are about doz itself or run unattended.
    static func applies(_ args: [String], env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if args.contains(where: { ["--json", "-q", "--quiet", "--help", "-h", "--version"].contains($0) }) { return false }
        let tty = env["DOZ_TEST_UPDATE_TTY"] == "1" || (isatty(STDOUT_FILENO) == 1 && isatty(STDERR_FILENO) == 1)
        guard tty else { return false }
        let first = words(args).first ?? ""
        return !["update", "host", "serve", "uninstall", "help", "config"].contains(first)
    }

    /// After a command: the daily check, and what its mode says to do — one line (notify), or an install when
    /// nothing would be disturbed (auto; else the line, with why). Never fails the command; offline is silent.
    static func afterCommand(_ args: [String]) async {
        guard applies(args) else { return }
        let ctx = UpdateContext.current(version: DozerCommand.version, executable: HostLauncher.executablePath)
        guard ctx.disabledReason(manual: false) == nil else { return }
        let r = await UpdateChecker.check(ctx)
        if let p = r.problem, r.reportNow { Out.stderr("doz: \(p)\n") }
        guard let e = r.available else { return }
        if ctx.mode == .auto {
            guard UpdateChecker.shouldNotify(e, ctx) || r.fetched else { return }
            let store = storeOf(args)
            if let busy = UpdateInstaller.busyReason(store: store) {
                Out.stderr(UpdateChecker.noticeLine(e, ctx) + " — not installed automatically now: \(busy)\n")
                return
            }
            do { Out.stderr(try await install(e, ctx, store: store, quiet: false) + "\n") } catch {
                Out.stderr("doz: the automatic update to \(e.version) did not happen: \(error)\n")
            }
            return
        }
        guard UpdateChecker.shouldNotify(e, ctx) else { return }
        Out.stderr(UpdateChecker.noticeLine(e, ctx) + "\n")
    }

    /// The store a command used (`--store S`, else the environment and settings).
    static func storeOf(_ args: [String]) -> DozerStore {
        var prev = ""
        for a in args {
            if prev == "--store" { return DozerStore.resolve(a) }
            prev = a
        }
        return DozerStore.resolve(nil)
    }
}

struct HostRestart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart",
        abstract: "Stop the host (running sandboxes hibernate) and start it again — on this doz's build (after an update).")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let store = g.dozerStore
        if store.hostIsRunning() {
            switch try stopHostShowingProgress(store, g) {
            case .done(let r): if !g.json { Out.stdout(HostStopView.summary(r) + "\n") }
            case .older: break
            case .exited(let seen): throw fail(HostError(.failed, HostStopView.seen(seen)), g)
            }
        }
        do { try HostLauncher.spawn(store: store, extra: []) } catch let e as HostError { throw fail(e, g) }
        guard HostClient.waitForHost(store: store) else {
            throw fail(HostError(.unavailable, "the host did not start — see \(store.logFile.path)"), g)
        }
        let st = try decode(try call(HostRequest(.ping), g, autostart: false), HostStatus.self, g)
        if g.json { Out.json(st) } else { Out.stdout(describe(st) + "sandboxes that were running are hibernated: doz wake NAME (or use them) brings each back\n") }
    }
}

/// The program's entry (`doz`): ArgumentParser's own parse-and-run, then the update hook after a command that
/// finished normally.
public enum DozerEntry {
    public static func main() async -> Never {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            var command = try DozerCommand.parseAsRoot(args)
            if var a = command as? AsyncParsableCommand { try await a.run() } else { try command.run() }
            await UpdateHook.afterCommand(args)
            DozerCommand.exit()
        } catch {
            DozerCommand.exit(withError: error)
        }
    }
}
