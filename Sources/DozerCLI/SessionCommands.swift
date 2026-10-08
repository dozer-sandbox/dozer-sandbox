import ArgumentParser
import Darwin
import Foundation
import DozerKit
import DozerHost

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List the sandboxes: phase, RAM held, disk, sessions, network.")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let rows = try decode(try await query(HostRequest(.ls), g), [SandboxInfo].self, g)
        if g.json { Out.json(rows); return }
        if rows.isEmpty { Out.stdout("no sandboxes — doz up NAME --image lab|claude-code|pi\n"); return }
        var t = [["NAME", "IMAGE", "PHASE", "RAM", "DISK", "SESSIONS", "NETWORK", "ACCOUNT", "WORKSPACE"]]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for r in rows {
            var phase = Out.phaseLabel(r.phase) + (r.busy ? "…" : "")
            if r.diedWithHost == true { phase += " (died with host)" }
            var net = r.network + ((r.deniedConnections ?? 0) > 0 ? " (\(r.deniedConnections!) denied)" : "")
            if let n = r.foreignCredentials, n > 0 { net += " · own key" + (n > 1 ? " ×\(n)" : "") }
            var account = r.account ?? "—"
            if let s = r.credentialState, s != "ok" { account += " (\(s))" }
            if r.credentialPolicy == "strict" { account += " · strict" }
            // 594 (D17): no workspace is said, not left blank.
            let ws = r.workspace.map { $0.hasPrefix(home + "/") ? "~" + $0.dropFirst(home.count) : $0 } ?? "isolated"
            t.append([r.name, r.image, phase, Out.mib(r.ramHeldMiB), DozerImages.formatBytes(r.diskBytes),
                      r.sessions.map(String.init) ?? "—", net, account, ws])
        }
        Out.stdout(Out.table(t, rightAligned: [3, 4, 5]))
        // 594 W28: a sandbox whose system disk came from an image an older doz made.
        for r in rows { if let line = r.olderImageLine { Out.stdout("\(r.name): \(line)\n") } }
    }
}

struct Inspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Everything about a sandbox, as JSON (--prompt: the agent's environment prompt, as its next session gets it).")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Flag(name: .long, help: "Print the environment prompt the agent gets at its next session (the facts block; --json adds the dozer skill).") var prompt = false

    func run() async throws {
        if prompt {
            let r = try decode(try await query(HostRequest(.agentPrompt, name: name), g), AgentPromptReport.self, g)
            if g.json { Out.json(r); return }
            Out.stdout(Self.render(r, name: name))
            if r.enabled, r.error != nil { throw ExitCode(DozerExit.failed) }
            return
        }
        let v = try await query(HostRequest(.inspect, name: name), g)
        Out.json(try decode(v, SandboxDetail.self, g))
    }

    static func render(_ r: AgentPromptReport, name: String) -> String {
        guard r.enabled else {
            return "the environment prompt is off (agent.prompt = false) — \(name)'s agent gets no facts block and no dozer skill\n"
        }
        if let e = r.error {
            return "the environment prompt of \(name) does not render: \(e)\nits sessions do not start until it does (or: doz config set agent.prompt false)\n"
        }
        let how = r.agent == "pi" ? "pi's --append-system-prompt \(r.promptPath)"
            : r.agent == "codex" ? "Codex's developer instructions (-c developer_instructions — the launcher reads \(r.promptPath))"
            : "Claude Code's --append-system-prompt (the launcher reads \(r.promptPath))"
        return "the environment prompt of \(name) (\(r.layers.joined(separator: " + "))) — \(how), written at every session start:\n\n"
            + (r.text ?? "") + "\n\nand the dozer skill, \(r.skillPath) (\((r.skill ?? "").split(separator: "\n").count) lines; --json has its text)\n"
    }
}

/// `doz sessions NAME` (the list — the default) and, since 0.30.0, `doz sessions end|restart NAME SESSION`.
struct Sessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The sandbox's terminal sessions: list them (the default), end one, or restart one.",
        subcommands: [SessionsList.self, SessionsEnd.self, SessionsRestart.self], defaultSubcommand: SessionsList.self)
}

struct SessionsEnd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "end",
        abstract: "End a session's program: it is hung up (as when its terminal closes), then terminated, then killed if it must be. Its viewers see it end.",
        discussion: "A running sandbox only — this never wakes one. What the program was doing is lost.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument var session: String
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    func run() async throws {
        try await requireSandbox(name, g)
        try confirm("End session \(session) in \(name)? Its program stops; what it is doing now is lost.", yes: yes || g.json, g)
        var r = HostRequest(.sessionEnd, name: name)
        r.session = session
        let e = try decode(try call(r, g), SessionEnded.self, g)
        if g.json { Out.json(e); return }
        Out.stdout(e.how == "not-running" ? "session \(session) in \(name) was not running\n"
                   : "ended session \(session) in \(name) (\(SessionsEnd.howText(e.how)))\n")
    }

    static func howText(_ how: String) -> String {
        switch how {
        case "hangup": "it hung up"
        case "terminate": "it did not hang up — terminated"
        case "kill": "it ignored hangup and terminate — killed"
        default: how
        }
    }
}

struct SessionsRestart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart",
        abstract: "Restart a session: end its program and start the same one again, in the same folder. An agent's own session continues its last conversation (Claude Code, Codex, pi) — only the turn in progress is lost.",
        discussion: """
            A running sandbox only — this never wakes one. --fresh starts a new conversation instead. \
            Afterwards it attaches, as doz run does, when stdin and stdout are a terminal; from a script \
            (no terminal), with --json or with -d it restarts the session and returns. --attach attaches \
            even without a terminal.
            """)
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument var session: String
    @Flag(name: .long, help: "A new conversation instead of continuing the last one (agent sessions).") var fresh = false
    @Flag(name: [.short, .customLong("detach")], help: "Restart it and return; attach later.") var detach = false
    @Flag(name: .long, help: "Attach afterwards even when stdin or stdout is not a terminal.") var attach = false
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    @Option(name: .long, help: "The key that detaches: ctrl-] (default), ctrl-<letter>, or none.") var detachKey = "ctrl-]"
    func validate() throws {
        if attach && detach { throw ValidationError("--attach and -d/--detach contradict each other — pick one") }
        if attach && g.json { throw ValidationError("--attach and --json contradict each other — --json answers and returns") }
    }

    /// Whether the restart attaches afterwards (610, issue 609.B2: a script's `doz sessions restart … --yes` attached and
    /// never returned). Only on a terminal — stdin AND stdout — unless asked for with --attach; never with -d or --json.
    static func attaches(detach: Bool, attach: Bool, json: Bool, stdinTTY: Bool, stdoutTTY: Bool) -> Bool {
        if detach || json { return false }
        return attach || (stdinTTY && stdoutTTY)
    }

    func run() async throws {
        let key = try parseDetachKey(detachKey)
        try await requireSandbox(name, g)
        try confirm("Restart session \(session) in \(name)? Its program stops and starts again; what it is doing now is lost.", yes: yes || g.json, g)
        var r = HostRequest(.sessionRestart, name: name)
        r.session = session
        r.fresh = fresh ? true : nil
        let size = terminalSize()
        r.cols = size.cols
        r.rows = size.rows
        let s = try decode(try call(r, g), SessionRestarted.self, g)
        if g.json { Out.json(s); return }
        if let n = s.notice { Out.stderr("[doz] \(n)\n") }
        Out.stdout("restarted session \(session) in \(name)" + (s.resumed ? " — its conversation continues" : "") + "\n")
        guard Self.attaches(detach: detach, attach: attach, json: g.json,
                            stdinTTY: isatty(STDIN_FILENO) != 0, stdoutTTY: isatty(STDOUT_FILENO) != 0) else { return }
        AttachClient.run(store: g.dozerStore, sandbox: name, session: session, wake: false, detachKey: key, quiet: g.quiet)
    }
}

struct SessionsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls",
        abstract: "The sandbox's terminal sessions (they survive pause, sleep and hibernate).",
        discussion: """
            While the sandbox is paused, asleep or hibernated, its sessions are listed from their saved screens \
            (saved when it pauses, sleeps or hibernates, and every host.screen_capture_minutes while it runs) — \
            nothing is woken. A shut-down sandbox has no sessions (Start boots it fresh). --screen SESSION \
            prints that session's last saved screen as text; add --vt to write the terminal bytes instead (to \
            a file or a pipe — never to a terminal).
            """)
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Option(name: .long, help: "Print this session's last saved screen (text).") var screen: String?
    @Flag(name: .long, help: "With --screen: write the saved VT bytes (redraw with `cat` in a terminal) — only to a file or a pipe.") var vt = false

    func run() async throws {
        if let screen { try await printScreen(screen); return }
        if vt { throw fail(HostError(.invalid, "--vt goes with --screen SESSION"), g, code: DozerExit.usage) }
        let rows = try decode(try await query(HostRequest(.sessions, name: name), g), [SessionRow].self, g)
        if g.json { Out.json(rows); return }
        if rows.isEmpty {
            var ls = HostRequest(.ls)
            ls.withSessions = false
            let phase = (try? decode(try await query(ls, g), [SandboxInfo].self, g))?.first { $0.name == name }?.phase
            if phase == Phase.off.rawValue || phase == Phase.failed.rawValue {
                Out.stdout("no sessions — \(name) is \(phase == Phase.off.rawValue ? "shut down" : "failed") (doz start \(name) boots it fresh, with new sessions)\n")
            } else {
                Out.stdout("no sessions — doz run \(name) -- CMD, or doz up \(name)\n")
            }
            return
        }
        var t = [["SESSION", "PID", "SIZE", "CLIENTS", "STATE", "COMMAND"]]
        for s in rows {
            let state: String
            if s.saved == true {
                state = "screen saved" + (s.savedAt.map { " " + Out.ago($0) } ?? "")
            } else {
                state = s.ended ? "ended (exit \(s.exitCode.map(String.init) ?? "?"))" : "running"
            }
            t.append([s.name, s.pid.map(String.init) ?? "—", s.cols.map { "\($0)×\(s.rows ?? 0)" } ?? "—", "\(s.clients)", state, s.command])
        }
        if rows.contains(where: { $0.saved == true }) {
            Out.stderr("\(name) is not running: its sessions as last saved (doz sessions \(name) --screen SESSION shows one)\n")
        }
        Out.stdout(Out.table(t))
    }

    /// S5: the last saved screen — text (inert) by default; the VT bytes only off a terminal.
    private func printScreen(_ session: String) async throws {
        var r = HostRequest(.sessionScreen, name: name)
        r.session = session
        let s = try decode(try await query(r, g), SessionScreen.self, g)
        if vt {
            guard isatty(STDOUT_FILENO) == 0 else {
                throw fail(HostError(.invalid, "--vt writes the guest's terminal bytes: send them to a file or a pipe, not a terminal"), g, code: DozerExit.usage)
            }
            FileHandle.standardOutput.write(s.vt)
            return
        }
        if g.json { Out.json(s); return }
        let size = s.cols.map { " · \($0)×\(s.rows ?? 0)" } ?? ""
        Out.stderr("\(name) · \(s.session) — saved \(Out.ago(s.savedAt)) (\(s.reason))\(size)\(s.truncated ? " · oldest scrollback dropped" : "")\n")
        Out.stdout(s.text.isEmpty ? "" : s.text + "\n")
    }
}

struct Attach: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Attach this terminal to a session (a paused or sleeping sandbox is woken).",
        discussion: "Ctrl-] opens a one-line menu (d detach · n next · p prev · s sessions · Esc back); Ctrl-] twice detaches (the session keeps running). The terminal's title is ui.terminal_title while attached. Hibernating disconnects you; the client waits and reattaches when the sandbox runs again.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument(help: "The session (default: the image's own — claude, pi or shell).") var session: String?
    @Flag(name: .long, help: "Do not wake a sleeping sandbox; wait for it instead.") var noWake = false
    @Option(name: .long, help: "The key that detaches: ctrl-] (default), ctrl-<letter>, or none.") var detachKey = "ctrl-]"

    func run() async throws {
        let key = try parseDetachKey(detachKey)
        noteHostBuild(g)                // W33: before the terminal is taken over
        AttachClient.run(store: g.dozerStore, sandbox: name, session: session, wake: !noWake, detachKey: key, quiet: g.quiet)
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a NEW session running a program, and attach to it. Exits with the program's exit code.",
        discussion: "doz run NAME -- top. The program starts without a shell in front of it; say `-- bash -lc '…'` for one.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Option(name: .long, help: "The session's name (default: the program's).") var session: String?
    @Option(name: .long, help: "Working directory in the guest.") var workdir: String?
    @Option(name: .long, help: "Run as this guest user (agent images default to their user).") var user: String?
    @Option(name: [.short, .customLong("env")], help: "KEY=VALUE for the program (repeatable).") var env: [String] = []
    @Flag(name: [.short, .customLong("detach")], help: "Start it and return; attach later.") var detach = false
    @Option(name: .long, help: "The key that detaches: ctrl-] (default), ctrl-<letter>, or none.") var detachKey = "ctrl-]"
    @Flag(name: .long, help: "Fail instead of starting (cold-booting) a sandbox that is off.") var noStart = false
    @Argument(parsing: .postTerminator, help: "The program and its arguments, after --.") var command: [String] = []

    func validate() throws {
        if command.isEmpty { throw ValidationError("which program? doz run NAME -- CMD…") }
    }

    func run() async throws {
        let key = try parseDetachKey(detachKey)
        var r = HostRequest(.openSession, name: name)
        r.start = !noStart      // 594 W27: an off sandbox boots first
        r.session = session
        r.argv = command
        r.workdir = workdir
        r.user = user
        r.environment = try parseEnv(env)
        let size = terminalSize()
        r.cols = size.cols
        r.rows = size.rows
        // A program the sandbox does not have is doz's failure, not the program's: 125, like exec.
        let m = try rawCall(r, g)
        guard m.ok == true else {
            let e = m.error ?? HostError(.failed, "the host gave no reason")
            throw fail(e, g, code: e.code == .notFound && r.argv != nil ? DozerExit.dozerFailed : nil)
        }
        let opened = try decode(m.result ?? .null, SessionOpened.self, g)
        if !g.json, let n = opened.notice { Out.stderr("[doz] \(n)\n") }
        if detach || g.json {
            if g.json { Out.json(opened) } else {
                Out.stdout("session \(opened.session) \(opened.created ? "started" : "is already running") in \(name) — \(reattachCommand(sandbox: name, session: opened.session, defaultSession: opened.defaultSession))\n")
            }
            return
        }
        AttachClient.run(store: g.dozerStore, sandbox: name, session: opened.session, wake: true, detachKey: key, quiet: g.quiet)
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
        discussion: "doz exec NAME -- CMD…. No terminal, no stdin; for an interactive program use run. A paused or sleeping sandbox is woken first, and one that is off is started (--no-wake, --no-start refuse instead).")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Option(name: .long, help: "Working directory in the guest (default: the session's).") var workdir: String?
    @Option(name: .long, help: "Run as this guest user (agent images default to their user; `root` for root).") var user: String?
    @Option(name: [.short, .customLong("env")], help: "KEY=VALUE (repeatable).") var env: [String] = []
    @Option(name: .long, help: "Give up after this many seconds (default 120).") var timeout: Int64 = 120
    @Flag(name: .long, help: "Fail instead of waking a sleeping sandbox.") var noWake = false
    @Flag(name: .long, help: "Fail instead of starting (cold-booting) a sandbox that is off.") var noStart = false
    @Argument(parsing: .postTerminator, help: "The command and its arguments, after --.") var command: [String] = []

    func validate() throws {
        if command.isEmpty { throw ValidationError("which command? doz exec NAME -- CMD…") }
    }

    func run() async throws {
        var r = HostRequest(.exec, name: name)
        r.argv = command
        r.workdir = workdir
        r.user = user
        r.environment = try parseEnv(env)
        r.timeoutSeconds = timeout
        r.wake = !noWake
        r.start = !noStart      // 594 W27: an off sandbox boots first (its progress on stderr)
        let m = try rawCall(r, g)
        guard m.ok == true, let v = m.result else {
            throw fail(m.error ?? HostError(.failed, "exec failed"), g, code: DozerExit.dozerFailed)
        }
        let out = try decode(v, ExecOutput.self, g)
        if g.json {
            var j: [String: JSONValue] = ["exitCode": .number(Double(out.exitCode)), "stdout": .string(String(decoding: out.stdout, as: UTF8.self)),
                                          "stderr": .string(String(decoding: out.stderr, as: UTF8.self)), "milliseconds": .number(out.milliseconds),
                                          // 594 W27: what had to happen first.
                                          "started": .bool(out.started == true), "woke": .bool(out.woke == true)]
            if let b = out.bootMilliseconds { j["bootMilliseconds"] = .number(b) }
            Out.json(j)
        } else {
            FileHandle.standardOutput.write(out.stdout)
            FileHandle.standardError.write(out.stderr)
        }
        if out.exitCode != 0 { throw ExitCode(out.exitCode) }
    }
}
