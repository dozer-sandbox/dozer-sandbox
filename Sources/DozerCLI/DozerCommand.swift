import ArgumentParser
import Darwin
import Foundation
import DozerKit
import DozerHost

/// `doz` — Dozer Sandbox's command-line tool: pausable Linux sandboxes on a Mac (585). Every command is a thin client of the store's
/// host (`doz host`), which the first command that needs it starts and which exits when nothing
/// has run for a while; read-only commands answer from the store when no host is running.
public struct DozerCommand: AsyncParsableCommand {
    /// The release this build ships as — the package's semver tag. Bump it with the tag (it was left
    /// at 0.5.0 through v0.6.0 and v0.7.0; `doz ui`'s host card showed it, 590). The host and
    /// `doctor` compare it to the running host's.
    public static let version = "0.10.0"

    public static let configuration = CommandConfiguration(
        commandName: "doz",
        abstract: "Dozer Sandbox — fast, suspendable micro-VMs for your Mac: pause in a millisecond, deep-sleep to disk, wake in a third of a second.",
        discussion: """
        Lifecycle (aliases in brackets): start [cold-boot] · pause [suspend] · resume · sleep · \
        deep-sleep [hibernate] · wake · shutdown · reset · rm. `doz up NAME` creates, starts or \
        wakes, and attaches. Every command takes --json and --store (or $DOZ_STORE).

        Exit codes: 0 ok · 1 failed · 2 not found · 3 not possible in this phase · 4 already exists · \
        5 not confirmed · 6 host unavailable · 7 not implemented yet · 64 usage. exec, run and attach \
        exit with the program's own code, and 125 when doz itself fails.
        """,
        version: version,
        subcommands: [
            Create.self, Up.self, Start.self, Pause.self, Resume.self, SleepCommand.self, DeepSleep.self, Wake.self,
            Shutdown.self, Reset.self, Remove.self,
            List.self, Inspect.self, Sessions.self, Attach.self, Run.self, Exec.self,
            ImageCommand.self, TemplateCommand.self, Duplicate.self, PointCommand.self, NetCommand.self, KeyCommand.self, AccountCommand.self,
            MetricsCommand.self, Doctor.self, HostCommand.self, Events.self, Console.self, UICommand.self, ConfigCommand.self,
        ]
    )

    public init() {}
}

/// 593: `--progress auto|plain`.
public enum ProgressFlag: String, ExpressibleByArgument, Sendable {
    case auto, plain
}

/// Options every command takes.
public struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "The store directory (default $DOZ_STORE, else the settings' store.path, else ~/Library/Application Support/dozer-sandbox).")
    public var store: String?

    @Flag(name: .long, help: "Machine-readable output (JSON on stdout).")
    public var json = false

    @Flag(name: [.short, .long], help: "Print every progress step (by default only an operation slower than a second shows them).")
    public var verbose = false

    @Flag(name: [.short, .long], help: "Print no progress.")
    public var quiet = false

    @Option(name: .long, help: "How progress shows on a terminal: auto (animated: a spinner, download bars) or plain (one line per step). Default $DOZ_PROGRESS, else the settings' ui.progress. Not a terminal, --json or NO_COLOR: always plain.")
    public var progress: ProgressFlag?

    public init() {}

    /// The progress rendering this command uses on stderr.
    public var progressMode: ProgressMode {
        guard isatty(STDERR_FILENO) == 1, !json, ProcessInfo.processInfo.environment["NO_COLOR"] == nil else { return .plain }
        return DozerSettings.load().progressMode(flag: progress?.rawValue)
    }

    public var dozerStore: DozerStore { DozerStore.resolve(store) }
}

/// The CLI's exit codes (README "Exit codes").
public enum DozerExit {
    public static let failed: Int32 = 1
    public static let notFound: Int32 = 2
    public static let invalidPhase: Int32 = 3
    public static let exists: Int32 = 4
    public static let declined: Int32 = 5
    public static let unavailable: Int32 = 6
    public static let notImplemented: Int32 = 7
    public static let usage: Int32 = 64
    /// exec / run / attach: doz itself failed (the program's own codes pass through).
    public static let dozerFailed: Int32 = 125

    public static func code(for e: HostError) -> Int32 {
        switch e.code {
        case .failed: failed
        case .notFound: notFound
        case .invalidPhase: invalidPhase
        case .exists: exists
        case .invalid: usage
        case .notImplemented: notImplemented
        case .version, .unavailable: unavailable
        }
    }
}

// MARK: output

enum Out {
    static func stdout(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }
    static func stderr(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }

    static func json<T: Encodable>(_ v: T) {
        guard let d = try? HostWire.prettyEncoder.encode(v) else { return }
        FileHandle.standardOutput.write(d)
        stdout("\n")
    }

    static func jsonLine<T: Encodable>(_ v: T) {
        guard let d = try? HostWire.encoder.encode(v) else { return }
        FileHandle.standardOutput.write(d)
        stdout("\n")
    }

    /// An aligned table (the first row is the header).
    static func table(_ rows: [[String]], rightAligned: Set<Int> = []) -> String {
        guard let header = rows.first else { return "" }
        let widths = header.indices.map { c in rows.map { c < $0.count ? $0[c].count : 0 }.max() ?? 0 }
        var out = ""
        for row in rows {
            let cells = row.enumerated().map { c, s in
                rightAligned.contains(c) ? String(repeating: " ", count: widths[c] - s.count) + s
                                         : s.padding(toLength: widths[c], withPad: " ", startingAt: 0)
            }
            out += cells.joined(separator: "  ").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + "\n"
        }
        return out
    }

    static func phaseLabel(_ raw: String) -> String { Phase(rawValue: raw).map(PhaseName.label) ?? raw }

    static func mib(_ m: UInt64) -> String { m == 0 ? "—" : m >= 1024 && m % 1024 == 0 ? "\(m / 1024) GiB" : "\(m) MiB" }
}

/// Fail the command: the message on stderr (or as JSON on stdout with --json), then the exit code.
func fail(_ e: HostError, _ g: GlobalOptions, code: Int32? = nil) -> ExitCode {
    if g.json {
        Out.json(["error": ["code": e.code.rawValue, "message": e.message]])
    } else {
        Out.stderr("doz: \(e.message)\n")
    }
    return ExitCode(code ?? DozerExit.code(for: e))
}

/// Progress lines on stderr: held back for the first second, so a quick operation prints nothing
/// but its result; `-v` prints them all, `-q` none.
///
/// 593: on a terminal (and `ui.progress` animated) the same view as the web UI's boot view —
/// `ProgressTerminal`: a spinner on the step under way, a transfer's bar, the output's last lines,
/// finished lines above — ticking on its own timer while the request blocks. Elsewhere plain lines,
/// as before, plus each transfer's summary; the host's own lines (notes, phases) are kept as they were.
final class Progress: @unchecked Sendable {
    let verbose: Bool, quiet: Bool
    let started = Date()
    private let lock = NSLock()
    private var held: [String] = []
    private var flowing = false
    private let view: ProgressTerminal
    private var timer: DispatchSourceTimer?

    init(_ g: GlobalOptions) {
        verbose = g.verbose
        quiet = g.quiet
        view = ProgressTerminal(mode: g.progressMode, color: true, plainPrefix: "  · ")
    }

    func handle(_ e: HostEvent) {
        guard !quiet else { return }
        lock.withLock {
            view.width = Self.terminalWidth()
            if view.mode == .animated { animated(e) } else { plain(e) }
        }
    }

    /// stderr's width in columns (80 when it is not a terminal or does not say).
    static func terminalWidth() -> Int {
        var w = winsize()
        return ioctl(STDERR_FILENO, TIOCGWINSZ, &w) == 0 && w.ws_col > 0 ? Int(w.ws_col) : 80
    }

    /// Plain: the host's line per event as before; a started step, output and transfer ticks say
    /// nothing; a finished transfer says its summary.
    private func plain(_ e: HostEvent) {
        let finals = view.board.apply(e)
        var lines: [String] = []
        switch e.kind {
        case .started, .output, .progress: break
        default: lines.append("  · " + e.line)
        }
        for f in finals { if case .transferDone = f { lines.append(view.format(f).replacingOccurrences(of: "\r\n", with: "")) } }
        emitLines(lines)
    }

    private func emitLines(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        if verbose || flowing { for l in lines { Out.stderr(l + "\n") }; return }
        held += lines
        if Date().timeIntervalSince(started) > 1 {
            flowing = true
            for l in held { Out.stderr(l + "\n") }
            held = []
        }
    }

    /// Animated: nothing for the first second (a quick operation prints nothing but its result),
    /// then the view — finished lines and the live block — and a tick every 100 ms.
    private func animated(_ e: HostEvent) {
        let finals = view.board.apply(e)
        let host: [ProgressFinal] = switch e.kind {
        case .phase: [.raw("  · " + e.line)]
        default: []
        }
        let out = finals + host
        guard verbose || flowing || Date().timeIntervalSince(started) > 1 else {
            held += out.map { view.format($0) }
            return
        }
        if !flowing {
            flowing = true
            Out.stderr(view.write(held.map { .raw($0) }))
            held = []
            startTimer()
        }
        Out.stderr(view.write(out))
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                self.view.width = Self.terminalWidth()
                Out.stderr(self.view.tick())
            }
        }
        t.resume()
        timer = t
    }

    /// The request ended: nothing stays live on the terminal.
    func finish() {
        lock.withLock {
            timer?.cancel()
            timer = nil
            guard !quiet else { return }
            if view.mode == .animated, flowing { Out.stderr(view.finish()) }
            else if view.mode == .plain {
                let s = view.finish()
                if !s.isEmpty, flowing || verbose { Out.stderr(s.replacingOccurrences(of: "\r\n", with: "\n")) }
            }
        }
    }
}

/// Send one request to the host (starting it when needed) and return the result.
func call(_ r: HostRequest, _ g: GlobalOptions, autostart: Bool = true) throws -> JSONValue {
    let m = try rawCall(r, g, autostart: autostart)
    if m.ok == true { return m.result ?? .null }
    throw fail(m.error ?? HostError(.failed, "the host gave no reason"), g)
}

/// The host's final message, whatever it says (a failure to REACH the host is thrown, printed).
func rawCall(_ r: HostRequest, _ g: GlobalOptions, autostart: Bool = true) throws -> HostMessage {
    let progress = Progress(g)
    defer { progress.finish() }
    do {
        return try HostClient.request(r, store: g.dozerStore, autostart: autostart) { progress.handle($0) }
    } catch let e as HostError {
        throw fail(e, g)
    } catch {
        throw fail(HostError(.unavailable, error.localizedDescription), g)
    }
}

/// A read-only request: through the host when one runs (or when the store needs the recovery only
/// a host does), else answered from the store in this process — so looking never starts a daemon.
func query(_ r: HostRequest, _ g: GlobalOptions) async throws -> JSONValue {
    let store = g.dozerStore
    if store.hostIsRunning() || !store.needsRecovery().isEmpty {
        return try call(r, g)
    }
    let core = HostCore(store: store, readOnly: true, version: DozerCommand.version)
    await core.load()
    let m = await core.handle(r)
    if m.ok == true { return m.result ?? .null }
    throw fail(m.error ?? HostError(.failed, "no reason"), g)
}

func decode<T: Decodable>(_ v: JSONValue, _ t: T.Type, _ g: GlobalOptions) throws -> T {
    do { return try v.decode(T.self) } catch {
        throw fail(HostError(.failed, "an answer this CLI cannot read: \(error.localizedDescription)"), g)
    }
}

/// Ask on the terminal (never stdin, which may carry data). No terminal and no --yes: refuse.
func confirm(_ question: String, yes: Bool, _ g: GlobalOptions) throws {
    if yes { return }
    let fd = open("/dev/tty", O_RDWR)
    guard fd >= 0 else {
        throw fail(HostError(.failed, "\(question) — there is no terminal to ask; pass --yes"), g, code: DozerExit.declined)
    }
    defer { close(fd) }
    let prompt = "\(question) [y/N] "
    _ = prompt.withCString { write(fd, $0, strlen($0)) }
    var buf = [UInt8](repeating: 0, count: 64)
    let n = read(fd, &buf, buf.count)
    let answer = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
    guard answer == "y" || answer == "yes" else {
        throw fail(HostError(.failed, "not confirmed — nothing done"), g, code: DozerExit.declined)
    }
}

/// The current terminal's size (80×24 when stdin is not a terminal).
func terminalSize() -> TermSize {
    var ws = winsize()
    for fd in [STDIN_FILENO, STDOUT_FILENO] where ioctl(fd, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 && ws.ws_row > 0 {
        return TermSize(cols: ws.ws_col, rows: ws.ws_row)
    }
    return TermSize(cols: 80, rows: 24)
}
