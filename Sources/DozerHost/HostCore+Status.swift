import Foundation
import DozerKit

/// 612: the agents' status — what each session's program says it is doing (OSC 7501).
///
/// deckhold (in the guest) answers the protocol's query, keeps each session's records and pushes the ROOT
/// record to a status WATCHER (`Sandbox.watchStatus` — `deckhold pipe` + WATCH: no size, no screen, not a
/// viewer). The host holds one watcher per session of a RUNNING sandbox: opened when a session is opened or
/// attached and, after the sandbox comes to run (a boot, a wake, a resume), for every session `deckhold ls`
/// lists; dropped when it sleeps or stops (the library detaches every connection), re-opened at the next run.
/// What they report is kept in memory (`statuses`) — `ls` reads it, never the guest (a poller never runs a
/// guest command) — and each change is ONE `session-status` event, deduplicated. host.log gets the metadata
/// (state, kind, app), never the program's text.
///
/// Lifetimes (the spec's): `working` and `blocked` end when the program does; `done` and `error` survive it
/// (until the session is opened again, or the sandbox stops). A holder older than this build (a session that
/// was started before an update keeps its own deckhold) drops a WATCH: that session is not asked again until
/// it restarts or the sandbox runs again.
extension HostCore {
    private static func key(_ sandbox: String, _ session: String) -> String { sandbox + "\u{0}" + session }

    /// Open a watcher on `session` unless one runs, is being opened, or its holder cannot answer.
    func watchStatus(_ name: String, session: String) async {
        guard !readOnly, let m = managed[name] else { return }
        let key = Self.key(name, session)
        guard statusWatches[key] == nil, !statusOpening.contains(key), !statusUnsupported.contains(key) else { return }
        guard await m.sandbox.phase == .running else { return }
        statusOpening.insert(key)
        defer { statusOpening.remove(key) }
        let conn: SessionConnection
        do { conn = try await m.sandbox.watchStatus(session) } catch { return }
        statusWatches[key] = conn
        Task.detached { [weak self] in
            var last: SessionOutput?
            for await out in conn.output {
                switch out {
                case .status(let p): await self?.statusReported(name, session: session, p)
                case .ended, .detached: last = out
                case .snapshot, .data: break
                }
            }
            await self?.statusWatchEnded(name, session: session, conn, last)
        }
    }

    /// The sandbox came to run: watch every live session (one `deckhold ls`, once per transition — never on a poll).
    func refreshStatusWatches(_ name: String) async {
        guard !readOnly, let m = managed[name] else { return }
        for k in statusUnsupported where k.hasPrefix(name + "\u{0}") { statusUnsupported.remove(k) }
        // Wait out the operation that made it run (a wake's guest fixes), at most a minute.
        for _ in 0..<300 {
            if !(await m.sandbox.status.busy) { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard await m.sandbox.phase == .running, let list = try? await m.sandbox.sessions() else { return }
        let live = Set(list.filter { !$0.isEnded }.map(\.name))
        // A program that ended while nobody watched: what ends with it is over.
        for (session, s) in statuses[name] ?? [:] where !live.contains(session) && s.state.endsWithProgram {
            setStatus(name, session: session, nil)
        }
        for s in list where !s.isEnded { await watchStatus(name, session: s.name) }
    }

    func statusReported(_ name: String, session: String, _ p: ProgramStatus?) {
        guard managed[name] != nil else { return }
        statusRetries[Self.key(name, session)] = nil
        setStatus(name, session: session, p.map { SessionStatus(session: session, $0) })
    }

    /// Keep `s` (nil: none) and tell it — once per change of the report (its age is not a change).
    func setStatus(_ name: String, session: String, _ s: SessionStatus?) {
        let old = statuses[name]?[session]
        switch (old, s) {
        case (nil, nil): return
        case (let o?, let n?) where o.sameReport(as: n): return
        default: break
        }
        statuses[name, default: [:]][session] = s
        if statuses[name]?.isEmpty == true { statuses[name] = nil }
        var e = HostEvent(kind: .sessionStatus, sandbox: name, text: s?.logLine ?? "session \(session): no status")
        e.session = session
        e.sessionStatus = s
        hub.yield(e)
        if !readOnly { HostLog.line(e.line) }
    }

    private func statusWatchEnded(_ name: String, session: String, _ conn: SessionConnection, _ last: SessionOutput?) async {
        let key = Self.key(name, session)
        if statusWatches[key] === conn { statusWatches[key] = nil }
        switch last {
        case .ended:
            // The program exited (or there is no such session): working/blocked end with it.
            if let s = statuses[name]?[session], s.state.endsWithProgram { setStatus(name, session: session, nil) }
        case .detached(.sandboxStopped):
            clearStatuses(name)
        case .detached(.transportLost):
            if !conn.sawStatus {
                statusUnsupported.insert(key)          // an older holder: it dropped the WATCH
                return
            }
            // The pipe died under a running sandbox: once more, a moment later.
            let tries = (statusRetries[key] ?? 0) + 1
            statusRetries[key] = tries
            guard tries <= 3 else { return }
            try? await Task.sleep(for: .seconds(1))
            await watchStatus(name, session: session)
        case .detached(.sandboxSleeping), .detached(.closedByClient), .status, .snapshot, .data, nil:
            break                                      // kept: the next run's watcher says what is current
        }
    }

    /// The sandbox stopped (or was deleted): its programs are gone, and so is what they said.
    func clearStatuses(_ name: String) {
        statuses[name] = nil
        for k in statusUnsupported where k.hasPrefix(name + "\u{0}") { statusUnsupported.remove(k) }
        for k in statusRetries.keys where k.hasPrefix(name + "\u{0}") { statusRetries[k] = nil }
    }

    /// `ls`'s fields, from memory.
    func statusFields(_ name: String, into i: inout SandboxInfo) {
        guard let all = statuses[name]?.values, !all.isEmpty else { return }
        let list = all.sorted { $0.session < $1.session }
        i.sessionStatuses = list
        i.agentStatus = SessionStatus.mostUrgent(list)
        i.agentWorking = list.contains { $0.state == .working }
    }

    /// `sessions`' rows: a live session's status as deckhold says it now (the INFO line), an ended or saved
    /// one's as the host kept it (`done`/`error` survive the program).
    func withStatuses(_ name: String, _ rows: [SessionRow], live: [SessionInfo]?) -> [SessionRow] {
        let infos = Dictionary((live ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return rows.map { row in
            var r = row
            if let info = infos[row.name], !info.isEnded, r.saved != true {
                r.status = info.status.map { SessionStatus(session: row.name, $0) }
                // The host's own copy, when it has the same report, keeps its time.
                if let kept = statuses[name]?[row.name], let now = r.status, kept.sameReport(as: now) { r.status = kept }
            } else {
                r.status = statuses[name]?[row.name]
            }
            return r
        }
    }
}
