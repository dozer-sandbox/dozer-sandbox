import ArgumentParser
import Darwin
import Foundation
import SnoozeContainerKit
import SnoozeHost

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List the sandboxes: phase, RAM held, disk, sessions, network.")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let rows = try decode(try await query(HostRequest(.ls), g), [SandboxInfo].self, g)
        if g.json { Out.json(rows); return }
        if rows.isEmpty { Out.stdout("no sandboxes — snooze up NAME --image lab|claude-code|pi\n"); return }
        var t = [["NAME", "IMAGE", "PHASE", "RAM", "DISK", "SESSIONS", "NETWORK", "ACCOUNT"]]
        for r in rows {
            var phase = Out.phaseLabel(r.phase) + (r.busy ? "…" : "")
            if r.diedWithHost == true { phase += " (died with host)" }
            var net = r.network + ((r.deniedConnections ?? 0) > 0 ? " (\(r.deniedConnections!) denied)" : "")
            if let n = r.foreignCredentials, n > 0 { net += " · own key" + (n > 1 ? " ×\(n)" : "") }
            var account = r.account ?? "—"
            if let s = r.credentialState, s != "ok" { account += " (\(s))" }
            if r.credentialPolicy == "strict" { account += " · strict" }
            t.append([r.name, r.image, phase, Out.mib(r.ramHeldMiB), SnoozeImages.formatBytes(r.diskBytes),
                      r.sessions.map(String.init) ?? "—", net, account])
        }
        Out.stdout(Out.table(t, rightAligned: [3, 4, 5]))
    }
}

struct Inspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Everything about a sandbox, as JSON.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String

    func run() async throws {
        let v = try await query(HostRequest(.inspect, name: name), g)
        Out.json(try decode(v, SandboxDetail.self, g))
    }
}

struct Sessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "The sandbox's terminal sessions (they survive pause, sleep and deep sleep).")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String

    func run() async throws {
        let rows = try decode(try await query(HostRequest(.sessions, name: name), g), [SessionRow].self, g)
        if g.json { Out.json(rows); return }
        if rows.isEmpty { Out.stdout("no sessions — snooze run \(name) -- CMD, or snooze up \(name)\n"); return }
        var t = [["SESSION", "PID", "SIZE", "CLIENTS", "STATE", "COMMAND"]]
        for s in rows {
            t.append([s.name, s.pid.map(String.init) ?? "—", s.cols.map { "\($0)×\(s.rows ?? 0)" } ?? "—", "\(s.clients)",
                      s.ended ? "ended (exit \(s.exitCode.map(String.init) ?? "?"))" : "running", s.command])
        }
        Out.stdout(Out.table(t))
    }
}

struct Attach: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Attach this terminal to a session (a paused or sleeping sandbox is woken).",
        discussion: "Ctrl-] detaches (the session keeps running). A Deep Sleep disconnects you; the client waits and reattaches when the sandbox runs again.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument(help: "The session (default: the image's own — claude, pi or shell).") var session: String?
    @Flag(name: .long, help: "Do not wake a sleeping sandbox; wait for it instead.") var noWake = false
    @Option(name: .long, help: "The key that detaches: ctrl-] (default), ctrl-<letter>, or none.") var detachKey = "ctrl-]"

    func run() async throws {
        let key = try parseDetachKey(detachKey)
        AttachClient.run(store: g.snoozeStore, sandbox: name, session: session, wake: !noWake, detachKey: key, quiet: g.quiet)
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a NEW session running a program, and attach to it. Exits with the program's exit code.",
        discussion: "snooze run NAME -- top. The program starts without a shell in front of it; say `-- bash -lc '…'` for one.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Option(name: .long, help: "The session's name (default: the program's).") var session: String?
    @Option(name: .long, help: "Working directory in the guest.") var workdir: String?
    @Option(name: .long, help: "Run as this guest user (agent images default to their user).") var user: String?
    @Option(name: [.short, .customLong("env")], help: "KEY=VALUE for the program (repeatable).") var env: [String] = []
    @Flag(name: [.short, .customLong("detach")], help: "Start it and return; attach later.") var detach = false
    @Option(name: .long, help: "The key that detaches: ctrl-] (default), ctrl-<letter>, or none.") var detachKey = "ctrl-]"
    @Argument(parsing: .postTerminator, help: "The program and its arguments, after --.") var command: [String] = []

    func validate() throws {
        if command.isEmpty { throw ValidationError("which program? snooze run NAME -- CMD…") }
    }

    func run() async throws {
        let key = try parseDetachKey(detachKey)
        var r = HostRequest(.openSession, name: name)
        r.session = session
        r.argv = command
        r.workdir = workdir
        r.user = user
        r.environment = try parseEnv(env)
        let size = terminalSize()
        r.cols = size.cols
        r.rows = size.rows
        let opened = try decode(try call(r, g), SessionOpened.self, g)
        if detach || g.json {
            if g.json { Out.json(opened) } else {
                Out.stdout("session \(opened.session) \(opened.created ? "started" : "is already running") in \(name) — snooze attach \(name) \(opened.session)\n")
            }
            return
        }
        AttachClient.run(store: g.snoozeStore, sandbox: name, session: opened.session, wake: true, detachKey: key, quiet: g.quiet)
    }
}

func parseEnv(_ pairs: [String]) throws -> [String: String]? {
    guard !pairs.isEmpty else { return nil }
    var out: [String: String] = [:]
    for p in pairs {
        guard let eq = p.firstIndex(of: "="), eq != p.startIndex else { throw ValidationError("--env \(p): KEY=VALUE") }
        out[String(p[..<eq])] = String(p[p.index(after: eq)...])
    }
    return out
}

struct Exec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command in the sandbox, non-interactively; its output and exit code pass through.",
        discussion: "snooze exec NAME -- CMD…. No terminal, no stdin; for an interactive program use run. A paused or sleeping sandbox is woken first.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Option(name: .long, help: "Working directory in the guest (default: the session's).") var workdir: String?
    @Option(name: .long, help: "Run as this guest user (agent images default to their user; `root` for root).") var user: String?
    @Option(name: [.short, .customLong("env")], help: "KEY=VALUE (repeatable).") var env: [String] = []
    @Option(name: .long, help: "Give up after this many seconds (default 120).") var timeout: Int64 = 120
    @Flag(name: .long, help: "Fail instead of waking a sleeping sandbox.") var noWake = false
    @Argument(parsing: .postTerminator, help: "The command and its arguments, after --.") var command: [String] = []

    func validate() throws {
        if command.isEmpty { throw ValidationError("which command? snooze exec NAME -- CMD…") }
    }

    func run() async throws {
        var r = HostRequest(.exec, name: name)
        r.argv = command
        r.workdir = workdir
        r.user = user
        r.environment = try parseEnv(env)
        r.timeoutSeconds = timeout
        r.wake = !noWake
        let m = try rawCall(r, g)
        guard m.ok == true, let v = m.result else {
            throw fail(m.error ?? HostError(.failed, "exec failed"), g, code: SnoozeExit.snoozeFailed)
        }
        let out = try decode(v, ExecOutput.self, g)
        if g.json {
            Out.json(["exitCode": .number(Double(out.exitCode)), "stdout": .string(String(decoding: out.stdout, as: UTF8.self)),
                      "stderr": .string(String(decoding: out.stderr, as: UTF8.self)), "milliseconds": .number(out.milliseconds)] as [String: JSONValue])
        } else {
            FileHandle.standardOutput.write(out.stdout)
            FileHandle.standardError.write(out.stderr)
        }
        if out.exitCode != 0 { throw ExitCode(out.exitCode) }
    }
}
