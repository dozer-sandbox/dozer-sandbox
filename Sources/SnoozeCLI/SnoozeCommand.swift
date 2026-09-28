import ArgumentParser
import Darwin
import Foundation
import SnoozeContainerKit
import SnoozeHost

/// `snooze` — pausable Linux sandboxes on a Mac (585). Every command is a thin client of the store's
/// host (`snooze host`), which the first command that needs it starts and which exits when nothing
/// has run for a while; read-only commands answer from the store when no host is running.
public struct SnoozeCommand: AsyncParsableCommand {
    /// The release this build ships as — the package's semver tag. Bump it with the tag (it was left
    /// at 0.5.0 through v0.6.0 and v0.7.0; `snooze ui`'s host card showed it, 590). The host and
    /// `doctor` compare it to the running host's.
    public static let version = "0.9.0"

    public static let configuration = CommandConfiguration(
        commandName: "snooze",
        abstract: "Pausable Linux sandboxes on your Mac: pause in a millisecond, deep-sleep to disk, wake in a third of a second.",
        discussion: """
        Lifecycle (aliases in brackets): start [cold-boot] · pause [suspend] · resume · sleep · \
        deep-sleep [hibernate] · wake · shutdown · reset · rm. `snooze up NAME` creates, starts or \
        wakes, and attaches. Every command takes --json and --store (or $SNOOZE_STORE).

        Exit codes: 0 ok · 1 failed · 2 not found · 3 not possible in this phase · 4 already exists · \
        5 not confirmed · 6 host unavailable · 7 not implemented yet · 64 usage. exec, run and attach \
        exit with the program's own code, and 125 when snooze itself fails.
        """,
        version: version,
        subcommands: [
            Create.self, Up.self, Start.self, Pause.self, Resume.self, SleepCommand.self, DeepSleep.self, Wake.self,
            Shutdown.self, Reset.self, Remove.self,
            List.self, Inspect.self, Sessions.self, Attach.self, Run.self, Exec.self,
            ImageCommand.self, PointCommand.self, NetCommand.self, KeyCommand.self, AccountCommand.self,
            MetricsCommand.self, Doctor.self, HostCommand.self, Events.self, Console.self, UICommand.self, ConfigCommand.self,
        ]
    )

    public init() {}
}

/// Options every command takes.
public struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "The store directory (default $SNOOZE_STORE, else the settings' store.path, else ~/Library/Application Support/SnoozeContainerKit).")
    public var store: String?

    @Flag(name: .long, help: "Machine-readable output (JSON on stdout).")
    public var json = false

    @Flag(name: [.short, .long], help: "Print every progress step (by default only an operation slower than a second shows them).")
    public var verbose = false

    @Flag(name: [.short, .long], help: "Print no progress.")
    public var quiet = false

    public init() {}

    public var snoozeStore: SnoozeStore { SnoozeStore.resolve(store) }
}

/// The CLI's exit codes (README "Exit codes").
public enum SnoozeExit {
    public static let failed: Int32 = 1
    public static let notFound: Int32 = 2
    public static let invalidPhase: Int32 = 3
    public static let exists: Int32 = 4
    public static let declined: Int32 = 5
    public static let unavailable: Int32 = 6
    public static let notImplemented: Int32 = 7
    public static let usage: Int32 = 64
    /// exec / run / attach: snooze itself failed (the program's own codes pass through).
    public static let snoozeFailed: Int32 = 125

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
        Out.stderr("snooze: \(e.message)\n")
    }
    return ExitCode(code ?? SnoozeExit.code(for: e))
}

/// Progress lines on stderr: held back for the first second, so a quick operation prints nothing
/// but its result; `-v` prints them all, `-q` none.
final class Progress {
    let verbose: Bool, quiet: Bool
    let started = Date()
    private var held: [String] = []
    private var flowing = false

    init(_ g: GlobalOptions) {
        verbose = g.verbose
        quiet = g.quiet
    }

    func handle(_ e: HostEvent) {
        guard !quiet else { return }
        let line = "  · " + e.line
        if verbose || flowing { Out.stderr(line + "\n"); return }
        held.append(line)
        if Date().timeIntervalSince(started) > 1 {
            flowing = true
            for l in held { Out.stderr(l + "\n") }
            held = []
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
    do {
        return try HostClient.request(r, store: g.snoozeStore, autostart: autostart) { progress.handle($0) }
    } catch let e as HostError {
        throw fail(e, g)
    } catch {
        throw fail(HostError(.unavailable, error.localizedDescription), g)
    }
}

/// A read-only request: through the host when one runs (or when the store needs the recovery only
/// a host does), else answered from the store in this process — so looking never starts a daemon.
func query(_ r: HostRequest, _ g: GlobalOptions) async throws -> JSONValue {
    let store = g.snoozeStore
    if store.hostIsRunning() || !store.needsRecovery().isEmpty {
        return try call(r, g)
    }
    let core = HostCore(store: store, readOnly: true, version: SnoozeCommand.version)
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
        throw fail(HostError(.failed, "\(question) — there is no terminal to ask; pass --yes"), g, code: SnoozeExit.declined)
    }
    defer { close(fd) }
    let prompt = "\(question) [y/N] "
    _ = prompt.withCString { write(fd, $0, strlen($0)) }
    var buf = [UInt8](repeating: 0, count: 64)
    let n = read(fd, &buf, buf.count)
    let answer = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
    guard answer == "y" || answer == "yes" else {
        throw fail(HostError(.failed, "not confirmed — nothing done"), g, code: SnoozeExit.declined)
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
