import Foundation
import Darwin
import DozerKit

// 608 — End session / Restart session (owner: "a control in the ui to restart the codex session").
//
// `session-end` ends a session's program the way a terminal hangup does, then harder (`Sandbox.endSession`:
// HUP → TERM → KILL of its process group). `session-restart` ends it and opens the SAME session again —
// same name, same program, same folder and user — from what the host RECORDED when it opened it
// (`SessionRecords`, `<sandbox>/sessions.json`: deckhold's own command line is space-joined, so it cannot be
// split back). An agent's default session resumes its conversation (`SessionResume`), so only the turn in
// progress is lost. Both are serialised with `open-session` (`HostCore.sessionGate`) and need a RUNNING
// sandbox: ending a program is never a reason to wake one.

/// What the host opened a session with — never an environment VALUE (a key given to a session becomes a
/// placeholder minted for that session only; values may be secrets), only the variables' names.
public struct SessionRecord: Codable, Equatable, Sendable {
    public var argv: [String]
    public var workdir: String?
    public var user: String?
    /// The names of the variables the opener gave (their values are not kept: a restart says so).
    public var environmentKeys: [String]?
    public var openedAt: Date
    public init(argv: [String], workdir: String?, user: String?, environmentKeys: [String]?, openedAt: Date = Date()) {
        self.argv = argv; self.workdir = workdir; self.user = user
        self.environmentKeys = environmentKeys?.isEmpty == true ? nil : environmentKeys?.sorted()
        self.openedAt = openedAt
    }
}

/// `<store>/sandboxes/<name>/sessions.json` (0600) — fields only ever added. Survives a host restart; cleared
/// with the sessions (shutdown, reset, a host that died with the VM).
public struct SessionRecords: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var sessions: [String: SessionRecord] = [:]
    public init() {}

    public static func url(_ store: DozerStore, _ name: String) -> URL {
        store.layout(name).sandboxDirectory.appendingPathComponent("sessions.json")
    }

    public static func read(_ store: DozerStore, _ name: String) -> SessionRecords {
        guard let d = try? Data(contentsOf: url(store, name)), let r = try? HostWire.decoder.decode(SessionRecords.self, from: d) else { return SessionRecords() }
        return r
    }

    /// Write atomically (0600), and only into a sandbox `doz create` made. nil / empty removes the file.
    public static func write(_ records: SessionRecords?, _ store: DozerStore, _ name: String) {
        let url = url(store, name)
        guard FileManager.default.fileExists(atPath: store.configFile(name).path) else { return }
        guard let r = records, !r.sessions.isEmpty, let data = try? HostWire.encoder.encode(r) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".sessions.\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        close(fd)
        if written != data.count || rename(tmp.path, url.path) != 0 { unlink(tmp.path) }
    }

    /// Record one session (the most sessions a sandbox keeps a record of: 64, the oldest dropped first).
    public static func record(_ session: String, _ rec: SessionRecord, _ store: DozerStore, _ name: String) {
        var r = read(store, name)
        r.sessions[session] = rec
        while r.sessions.count > 64, let oldest = r.sessions.min(by: { $0.value.openedAt < $1.value.openedAt })?.key { r.sessions[oldest] = nil }
        write(r, store, name)
    }
}

/// 608: how an agent's default session resumes its conversation after a restart — pure, unit-tested.
public enum SessionResume {
    /// What is appended to the agent's own argv (the image's launcher passes it through):
    /// Claude Code `--continue` (the newest conversation in the folder); Codex `resume --last` (0.160.1:
    /// the newest session recorded in the folder — `--all` would ignore the folder — or a new one when there
    /// is none); pi `--continue` (the newest session in the folder, else a new one).
    public static func arguments(for agent: AgentKind?) -> [String] {
        switch agent {
        case .claudeCode?: ["--continue"]
        case .codex?: ["resume", "--last"]
        case .pi?: ["--continue"]
        default: []
        }
    }

    /// A guest check (as the session's user, in its folder) that there IS a conversation to continue, for an
    /// agent that refuses `--continue` without one (Claude Code: "No conversation found to continue" and
    /// exits). nil: the agent starts a new conversation by itself when there is none (Codex, pi).
    /// Claude Code keeps a folder's conversations in ~/.claude/projects/<the folder, every non-alphanumeric
    /// character a '-'>/*.jsonl.
    public static func check(for agent: AgentKind?) -> String? {
        switch agent {
        case .claudeCode?:
            return #"d="$HOME/.claude/projects/$(pwd -P | sed 's/[^A-Za-z0-9]/-/g')"; ls "$d"/*.jsonl >/dev/null 2>&1 && echo resumable || echo none"#
        default: return nil
        }
    }
}

/// `session-end`'s answer.
public struct SessionEnded: Codable, Equatable, Sendable {
    public var name: String
    public var session: String
    /// hangup | terminate | kill | not-running | stuck (`Sandbox.SessionEnd`).
    public var how: String
    public init(name: String, session: String, how: String) { self.name = name; self.session = session; self.how = how }
}

/// `session-restart`'s answer.
public struct SessionRestarted: Codable, Equatable, Sendable {
    public var name: String
    public var session: String
    /// How the old program ended (`SessionEnded.how`).
    public var ended: String
    /// The agent's conversation is continued (its resume arguments were given).
    public var resumed: Bool
    /// The program it runs now (the argv, joined — what `doz sessions` shows).
    public var command: String
    /// Something the person should know (no conversation to continue; variables not kept; tmux).
    public var notice: String?
    public init(name: String, session: String, ended: String, resumed: Bool, command: String, notice: String? = nil) {
        self.name = name; self.session = session; self.ended = ended; self.resumed = resumed; self.command = command; self.notice = notice
    }
}

extension HostCore {
    /// Ends, never wakes: the sandbox must be running now.
    private func requireRunningForSession(_ m: Managed, _ verb: String) async throws {
        let phase = await effectivePhase(m)
        guard phase == .running else {
            throw HostError(.invalidPhase, "\(m.name) is \(phase.label) — \(verb) needs it running (doz wake \(m.name) first; this never wakes it by itself)")
        }
        if await m.sandbox.status.busy { throw HostError(.invalidPhase, "\(m.name) is busy — try again in a moment") }
    }

    func sessionEnd(_ r: HostRequest) async throws -> SessionEnded {
        let m = try get(r.name)
        guard let session = r.session else { throw HostError(.invalid, "which session? doz sessions end NAME SESSION") }
        try GuestCommand.validateSessionName(session)
        await sessionGate.lock(m.name)
        defer { sessionGate.unlock(m.name) }
        try await requireRunningForSession(m, "ending a session")
        let how: Sandbox.SessionEnd
        do { how = try await m.sandbox.endSession(session) } catch { throw HostError.from(error) }
        if how == .notRunning, !(try await m.sandbox.sessions()).contains(where: { $0.name == session }) {
            throw HostError(.notFound, "no session \(session) in \(m.name) (doz sessions \(m.name))")
        }
        if how == .stuck { throw HostError(.failed, "session \(session) in \(m.name) did not end, even after SIGKILL — a program stuck in the kernel; doz shutdown \(m.name) ends everything") }
        metrics?.record(run: metricsRun, action: "session end", sandbox: m.name, image: m.config.image, phaseBefore: "running",
                        phaseAfter: "running", startedAt: Date(), durationMs: nil, detail: ["session": session, "how": how.rawValue])
        return SessionEnded(name: m.name, session: session, how: how.rawValue)
    }

    func sessionRestart(_ r: HostRequest) async throws -> SessionRestarted {
        let m = try get(r.name)
        guard let session = r.session else { throw HostError(.invalid, "which session? doz sessions restart NAME SESSION") }
        try GuestCommand.validateSessionName(session)
        await sessionGate.lock(m.name)
        defer { sessionGate.unlock(m.name) }
        try await requireRunningForSession(m, "restarting a session")
        // What it was opened with: the record, else the default session's program.
        let record = SessionRecords.read(store, m.name).sessions[session]
        let isDefault = session == m.config.defaultSession.name
        guard let argv = record?.argv ?? (isDefault ? m.config.defaultSession.argv : nil) else {
            throw HostError(.notFound, "session \(session) was not opened by this doz (or before 0.30.0), so its program is not known — doz sessions end \(m.name) \(session), then doz run \(m.name) --session \(session) -- CMD")
        }
        let previous = (try? await m.sandbox.sessions())?.first { $0.name == session }
        // The agent's default session continues its conversation (unless asked for a fresh one).
        var resume: [String] = []
        var notes: [String] = []
        let agent = m.config.imageChoice?.agent
        if isDefault, argv == m.config.defaultSession.argv, r.fresh != true {
            resume = SessionResume.arguments(for: agent)
            if !resume.isEmpty, let check = SessionResume.check(for: agent) {
                let ctx = Self.execContext(config: m.config, environment: [:], workdir: record?.workdir, user: record?.user)
                let out = try? await m.sandbox.exec(["sh", "-c", check], environment: ctx.environment, workingDirectory: ctx.workdir,
                                                    user: ctx.user, timeoutSeconds: 10)
                if out?.output.contains("resumable") != true {
                    resume = []
                    notes.append("no earlier conversation in this folder — \(agent?.title ?? "the agent") starts a new one")
                }
            }
        }
        if let keys = record?.environmentKeys, !keys.isEmpty {
            notes.append("the variables it was opened with (\(keys.joined(separator: ", "))) are not kept — it runs without them")
        }
        let how: Sandbox.SessionEnd
        do { how = try await m.sandbox.endSession(session) } catch { throw HostError.from(error) }
        if how == .stuck { throw HostError(.failed, "session \(session) in \(m.name) did not end, even after SIGKILL — doz shutdown \(m.name) ends everything") }
        var o = HostRequest(.openSession, name: m.name)
        o.session = session
        o.argv = record != nil ? argv : nil          // the default session without a record: as `doz up` opens it
        o.workdir = record?.workdir
        o.user = record?.user
        o.cols = r.cols ?? previous?.size.map { $0.cols }
        o.rows = r.rows ?? previous?.size.map { $0.rows }
        let opened = try await openSessionLocked(o, extraArguments: resume)
        if let n = opened.notice { notes.append(n) }
        metrics?.record(run: metricsRun, action: "session restart", sandbox: m.name, image: m.config.image, phaseBefore: "running",
                        phaseAfter: "running", startedAt: Date(), durationMs: nil, detail: ["session": session, "how": how.rawValue, "resumed": resume.isEmpty ? "no" : "yes"])
        note(m.name, "session \(session) restarted" + (resume.isEmpty ? "" : " — its conversation continues"))
        return SessionRestarted(name: m.name, session: session, ended: how.rawValue, resumed: !resume.isEmpty,
                                command: (argv + resume).joined(separator: " "), notice: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }
}
