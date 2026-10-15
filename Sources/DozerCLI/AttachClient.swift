// The terminal client of `doz attach` / `run` / `up` — SandboxLab's `attach` (576.03/581) ported:
// the tty in raw mode, bytes relayed to the host (which relays them to the guest's deckhold
// session), window resizes as RESIZE frames, and REATTACH: hibernating closes the connection
// while the session lives on in the guest, so the client reconnects and the host holds it until the
// sandbox runs again. When the host says the session is over (`ClientWire` notice) it exits with
// the program's exit code. Ctrl-] (or --detach-key) detaches; so does closing the terminal, or
// SIGTERM / SIGINT. A stdin that is not a terminal is typed until it ends, then the client keeps
// showing the session until the program exits (so `doz run NAME -- CMD < /dev/null` works).
import ArgumentParser
import Darwin
import Foundation
import DozerKit
import DozerHost

nonisolated(unsafe) private var savedTermios = termios()
nonisolated(unsafe) private var rawMode = false
nonisolated(unsafe) private var socketFD: Int32 = -1
/// Keys typed before the FIRST connection is up (typing ahead of `up`/`run`): sent once it is.
/// After that nothing is queued — a held client's keys are dropped (never typed into a frozen guest).
nonisolated(unsafe) private var typedAhead: Data? = Data()
private let socketLock = NSLock()

private func setSocket(_ fd: Int32) {
    socketLock.lock()
    socketFD = fd
    let early = fd >= 0 ? typedAhead : nil
    if fd >= 0 { typedAhead = nil }
    socketLock.unlock()
    if let early, !early.isEmpty { UnixSocket.writeAll(fd, early) }
}
private func currentSocket() -> Int32 { socketLock.lock(); defer { socketLock.unlock() }; return socketFD }

/// 594 (W17): the session attached and the sandbox's default session, as the host said.
nonisolated(unsafe) private var _attached: (session: String, defaultSession: String?)?
private func setAttached(_ s: String, _ d: String?) { socketLock.lock(); _attached = (s, d); socketLock.unlock() }
private var attachedSession: (session: String, defaultSession: String?)? { socketLock.lock(); defer { socketLock.unlock() }; return _attached }

/// Send keys, or keep them for the first connection (bounded).
private func typeOrKeep(_ bytes: Data) {
    socketLock.lock()
    if socketFD < 0, typedAhead != nil {
        if typedAhead!.count + bytes.count <= 65536 { typedAhead!.append(bytes) }
        socketLock.unlock()
        return
    }
    let fd = socketFD
    socketLock.unlock()
    if fd >= 0 { UnixSocket.writeAll(fd, bytes) }
}

/// 594 (W13): the modes the session's bytes left set in the OUTER terminal, and whether they were
/// undone. `outputLock` orders the session's bytes and the restore: once restored, nothing more of the
/// session is written (the restore is always after its last byte).
nonisolated(unsafe) private var outerModes = TerminalModes()
nonisolated(unsafe) private var outerRestored = false
private let outputLock = NSLock()

/// Write session bytes to the terminal (following the modes they set) — unless it was restored, or the
/// Ctrl-] menu is up (599: its line stays; the repaint that closes it brings the screen up to date).
private func writeSession(_ bytes: ArraySlice<UInt8>) {
    guard !bytes.isEmpty else { return }
    outputLock.lock(); defer { outputLock.unlock() }
    guard !outerRestored, !menuOpen else { return }
    // 599 (594.B4): while doz owns the title, the session's own title sequences are taken out.
    let out = titleFilter != nil ? titleFilter!.feed(bytes) : Array(bytes)
    outerModes.feed(out)
    UnixSocket.writeAll(STDOUT_FILENO, Data(out))
}

// MARK: 599 (594.B4) — the terminal's title (`ui.terminal_title`), under `outputLock`

nonisolated(unsafe) private var titleTemplate: String?
nonisolated(unsafe) private var titleFilter: TitleFilter?
nonisolated(unsafe) private var titlePushed = false
nonisolated(unsafe) private var titleVars: (sandbox: String, session: String, image: String?, phase: String?) = ("", "", nil, nil)

/// Set the terminal's title from the template (the first time, the terminal's own is pushed first:
/// `CSI 22;0 t` — popped on every way out).
private func setTitle(session: String? = nil, image: String? = nil, phase: String? = nil) {
    outputLock.lock(); defer { outputLock.unlock() }
    guard let t = titleTemplate, !outerRestored else { return }
    if let session { titleVars.session = session }
    if let image { titleVars.image = image }
    if let phase { titleVars.phase = phase }
    var s = ""
    if !titlePushed { s += "\u{1B}[22;0t"; titlePushed = true }
    s += "\u{1B}]2;" + TerminalTitle.render(t, sandbox: titleVars.sandbox, session: titleVars.session, image: titleVars.image, phase: titleVars.phase) + "\u{07}"
    UnixSocket.writeAll(STDOUT_FILENO, Data(s.utf8))
}

// MARK: 599 (594.B4) — the Ctrl-] menu

/// Guarded by `outputLock` (it gates the session's bytes).
nonisolated(unsafe) private var menuOpen = false
/// The live sessions the menu's `s` listed (nil: the main line).
nonisolated(unsafe) private var menuSessions: [String]?
/// A session the menu switched to — the main loop reattaches there (under `socketLock`).
nonisolated(unsafe) private var switchTarget: String?
nonisolated(unsafe) private var pendingNotices: [BridgeNotice] = []
private let menuLine = "d detach · n next · p prev · s sessions · Esc back"

private func menuIsOpen() -> Bool { outputLock.withLock { menuOpen } }

private func openMenu() {
    outputLock.withLock { menuOpen = true; menuSessions = nil }
    socketLock.lock(); overlayGeneration += 1; let mine = overlayGeneration; socketLock.unlock()
    drawBottomLine("doz: " + menuLine)
    // Nobody at the keyboard: the menu goes by itself (the screen was held while it showed).
    DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
        socketLock.lock(); let current = overlayGeneration == mine; socketLock.unlock()
        if current, menuIsOpen() { closeMenu() }
    }
}

/// Close the menu: a clean redraw from deckhold's snapshot (and any notice that came meanwhile).
private func closeMenu(repaint: Bool = true) {
    let notices: [BridgeNotice] = outputLock.withLock {
        menuOpen = false
        menuSessions = nil
        defer { pendingNotices = [] }
        return pendingNotices
    }
    socketLock.lock(); overlayGeneration += 1; socketLock.unlock()
    if repaint { requestRepaint() }
    if !notices.isEmpty {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { for n in notices { showNotice(n) } }
    }
}

/// The live sessions of `sandbox`, in the guest's order (empty when they cannot be read).
private func liveSessions(store: DozerStore, sandbox: String) -> [String] {
    guard let m = try? HostClient.request(HostRequest(.sessions, name: sandbox), store: store, autostart: false),
          m.ok == true, let rows = try? m.result?.decode([SessionRow].self) else { return [] }
    return rows.filter { !$0.ended && $0.saved != true }.map(\.name)
}

/// Reattach this client to `target` (the main loop does, once the current connection is closed).
private func switchSession(to target: String) {
    socketLock.lock(); switchTarget = target; let fd = socketFD; socketLock.unlock()
    closeMenu(repaint: false)                          // the new session's snapshot is the redraw
    if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
}

private func takeSwitch() -> String? {
    socketLock.lock(); defer { socketLock.unlock() }
    let t = switchTarget
    switchTarget = nil
    return t
}

/// A key at the menu. True: detach.
private func menuKey(_ bytes: [UInt8], store: DozerStore, sandbox: String) -> Bool {
    let listed: [String]? = outputLock.withLock { menuSessions }
    switch MenuKey.decode(bytes) {
    case .release:
        return false
    case .char("d"), .char("D"):
        return true
    case .char(let c) where listed == nil && (c == "n" || c == "p"):
        let all = liveSessions(store: store, sandbox: sandbox)
        let current = attachedSession?.session
        guard all.count > 1, let at = all.firstIndex(where: { $0 == current }) ?? (all.isEmpty ? nil : 0) else {
            drawBottomLine("doz: no other session in \(sandbox) — " + menuLine)
            return false
        }
        switchSession(to: all[(at + (c == "n" ? 1 : all.count - 1)) % all.count])
    case .char("s") where listed == nil:
        let all = liveSessions(store: store, sandbox: sandbox)
        outputLock.withLock { menuSessions = Array(all.prefix(9)) }
        let current = attachedSession?.session
        let items = all.prefix(9).enumerated().map { "\($0.offset + 1) \($0.element)\($0.element == current ? "*" : "")" }
        drawBottomLine("doz: " + (items.isEmpty ? "no sessions" : items.joined(separator: " · ")) + " — 1–9 switch · Esc back")
    case .char(let c) where listed != nil && c.isNumber:
        let i = (c.wholeNumberValue ?? 0) - 1
        guard let list = listed, list.indices.contains(i) else { return false }
        if list[i] == attachedSession?.session { closeMenu() } else { switchSession(to: list[i]) }
    default:
        closeMenu()                                    // Esc, or any other key: back to the session
    }
    return false
}

// MARK: 599 — a line drawn over the bottom row (a bridge's notice; B4's Ctrl-] menu), removed by a repaint

/// Bumped by every drawing: a repaint scheduled for an older one is skipped.
nonisolated(unsafe) private var overlayGeneration = 0

/// Draw `text` over the bottom row (cursor and attributes saved and restored around it). False when
/// stdout is not a terminal (nothing is drawn).
@discardableResult
private func drawBottomLine(_ text: String) -> Bool {
    guard rawMode, isatty(STDOUT_FILENO) != 0 else { return false }
    let size = terminalSize()
    let width = max(10, Int(size.cols) - 2)
    let shown = text.count > width ? String(text.prefix(width - 1)) + "…" : text
    let pad = String(repeating: " ", count: max(0, Int(size.cols) - shown.count - 1))
    outputLock.lock(); defer { outputLock.unlock() }
    guard !outerRestored else { return false }
    // DECSC, bottom row, clear it, reverse video, DECRC. Written to the terminal, not the session model.
    UnixSocket.writeAll(STDOUT_FILENO, Data("\u{1B}7\u{1B}[\(size.rows);1H\u{1B}[2K\u{1B}[7m \(shown)\(pad)\u{1B}[0m\u{1B}8".utf8))
    return true
}

/// Ask the host for a fresh snapshot of the session's screen (what removes a drawn line).
private func requestRepaint() {
    let fd = currentSocket()
    if fd >= 0 { UnixSocket.writeAll(fd, Data(ClientWire.repaint)) }
}

/// 599 (594.B1/B2): what the host did for this session — shown every time: over the bottom row for 3 s
/// (then a repaint), or as a line on stderr when this is not a terminal.
private func showNotice(_ n: BridgeNotice) {
    // At the Ctrl-] menu: shown once it closes (never lost, never over the menu).
    let held: Bool = outputLock.withLock { if menuOpen { pendingNotices.append(n) }; return menuOpen }
    if held { return }
    socketLock.lock(); overlayGeneration += 1; let mine = overlayGeneration; socketLock.unlock()
    guard drawBottomLine("doz: " + n.text) else {
        FileHandle.standardError.write(Data("[doz] \(n.text)\n".utf8))
        return
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
        socketLock.lock(); let current = overlayGeneration == mine; socketLock.unlock()
        if current { requestRepaint() }
    }
}

/// 617 (owner: attaching briefly flashed an earlier program's screen): the session's SNAPSHOT leaves the alternate
/// screen, resets and clears the PRIMARY screen and scrollback, then — for a program in the alternate screen — enters
/// it again with CSI ?1049h and paints only the rows that hold text. A terminal whose alternate buffer still holds an
/// earlier program's frame (one that does not clear it on ?1049h, or a reattach where the ?1049l uncovers the other
/// buffer for a moment) showed that frame until the paint. So before a connection's first byte BOTH buffers are
/// cleared: enter the alternate screen and clear it, leave it, clear the primary screen and its scrollback (which the
/// snapshot clears next anyway — nothing a person had is lost that the snapshot would keep). A terminal on stdout only.
public enum AttachScreen {
    public static let clearBoth = "\u{1B}[?1049h\u{1B}[H\u{1B}[2J\u{1B}[?1049l\u{1B}[H\u{1B}[2J\u{1B}[3J"
}

private func clearBothScreens() {
    guard isatty(STDOUT_FILENO) != 0 else { return }
    outputLock.lock(); defer { outputLock.unlock() }
    guard !outerRestored else { return }
    UnixSocket.writeAll(STDOUT_FILENO, Data(AttachScreen.clearBoth.utf8))
}

/// Put the outer terminal back (once): its modes, when stdout is a terminal, then the saved termios.
private func restoreTerminal() {
    outputLock.lock()
    if !outerRestored {
        outerRestored = true
        // 599 (594.B4): and the terminal's own title back (pushed when doz first set one).
        if isatty(STDOUT_FILENO) != 0 { UnixSocket.writeAll(STDOUT_FILENO, Data((outerModes.restoreSequence + (titlePushed ? "\u{1B}[23;0t" : "")).utf8)) }
    }
    outputLock.unlock()
    restoreTTY()
}

private func restoreTTY() { if rawMode { tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios) } }

/// A notice on stderr (with \r\n: the tty is raw).
private func say(_ s: String) {
    let line = rawMode ? "\r\n\u{1B}[2m[doz] \(s)\u{1B}[0m\r\n" : "[doz] \(s)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

/// The last line of an attach: the terminal is put back first, so the line is read in a normal terminal.
private func sayLast(_ s: String) {
    restoreTerminal()
    say(s)
}

private func finish(_ code: Int32) -> Never {
    restoreTerminal()
    exit(code)
}

// MARK: 617 — a RETURNING attach (`doz try`'s "Keep this try?" after it)

/// How an attach ended.
enum AttachEnd: Equatable {
    /// Ctrl-] (or the terminal went away, a signal).
    case detached
    /// The session's program exited with this code.
    case ended(Int32)
    /// No session, the sandbox stopped, or the connection could not be made (the exit code `run` would use).
    case lost(Int32)

    var exitCode: Int32 {
        switch self {
        case .detached: 0
        case .ended(let c), .lost(let c): c
        }
    }
}

/// true while `AttachClient.attach` runs: every way out is RECORDED (once) instead of `exit`, the relay loop is woken
/// (its socket shut down) and the keyboard thread is stopped (the self-pipe) — so the next prompt gets its first key.
nonisolated(unsafe) private var returning = false
nonisolated(unsafe) private var recordedEnd: AttachEnd?
nonisolated(unsafe) private var stopPipe: [Int32] = [-1, -1]
private let endLock = NSLock()

private func takeEnd() -> AttachEnd? { endLock.withLock { recordedEnd } }

/// End the attach: `exit` (doz attach/run/up/new), or — returning — record it and wake both threads.
private func endAttach(_ e: AttachEnd) {
    restoreTerminal()
    guard returning else { exit(e.exitCode) }
    let first: Bool = endLock.withLock {
        guard recordedEnd == nil else { return false }
        recordedEnd = e
        return true
    }
    guard first else { return }
    if stopPipe[1] >= 0 { var b: UInt8 = 1; _ = write(stopPipe[1], &b, 1) }
    let fd = currentSocket()
    if fd >= 0 { shutdown(fd, SHUT_RDWR) }
}

/// The keyboard thread's read: stdin, unless the self-pipe says stop (nil). -1: EOF/error, as `read`.
func stoppableRead(_ buf: inout [UInt8], stop: Int32, input: Int32 = STDIN_FILENO) -> Int? {
    while true {
        var fds = [pollfd(fd: input, events: Int16(POLLIN), revents: 0)]
        if stop >= 0 { fds.append(pollfd(fd: stop, events: Int16(POLLIN), revents: 0)) }
        let n = poll(&fds, nfds_t(fds.count), -1)
        if n < 0 { if errno == EINTR { continue }; return -1 }
        if fds.count > 1, fds[1].revents != 0 { return nil }
        if fds[0].revents != 0 {
            let r = read(input, &buf, buf.count)
            if r < 0 && errno == EINTR { continue }
            return r
        }
    }
}

/// `ctrl-]` → 0x1D, `ctrl-x` → 0x18, `none` → nil.
func parseDetachKey(_ s: String) throws -> UInt8? {
    let t = s.lowercased()
    if t == "none" || t.isEmpty { return nil }
    guard t.hasPrefix("ctrl-"), t.count == 6, let c = t.last?.asciiValue else {
        throw ValidationError("--detach-key: ctrl-<key> (e.g. ctrl-], ctrl-q) or none")
    }
    let upper = c >= 0x61 && c <= 0x7A ? c - 0x20 : c
    guard (0x40...0x5F).contains(upper) else { throw ValidationError("--detach-key: ctrl-<key> (e.g. ctrl-], ctrl-q) or none") }
    return upper & 0x1F
}

func describeKey(_ k: UInt8) -> String {
    let c = Character(UnicodeScalar(k | 0x40))
    return "Ctrl-\(c)"
}

enum AttachClient {
    /// Attach to `session` in `sandbox` and relay until it ends or the user detaches. Never returns.
    static func run(store: DozerStore, sandbox: String, session: String?, wake: Bool, detachKey: UInt8?, quiet: Bool = false) -> Never {
        let e = relay(store: store, sandbox: sandbox, session: session, wake: wake, detachKey: detachKey, quiet: quiet)
        finish(e.exitCode)
    }

    /// 617: the same attach, RETURNING how it ended — with the terminal put back, the signal handlers and timers
    /// gone and the keyboard thread stopped, so the caller can ask its next question (`doz try`).
    static func attach(store: DozerStore, sandbox: String, session: String?, wake: Bool, detachKey: UInt8?, quiet: Bool = false) -> AttachEnd {
        returning = true
        endLock.withLock { recordedEnd = nil }
        var p: [Int32] = [-1, -1]
        if pipe(&p) == 0 { stopPipe = p; for fd in p { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) } }
        let e = relay(store: store, sandbox: sandbox, session: session, wake: wake, detachKey: detachKey, quiet: quiet)
        // Every way back: the terminal, the signals, the timers, the keyboard thread (the self-pipe stays written).
        restoreTerminal()
        for s in retained { s.cancel() }
        retained.removeAll()
        retainedTimer?.cancel()
        retainedTimer = nil
        retainedWinch?.cancel()
        retainedWinch = nil
        for sig in [SIGTERM, SIGHUP, SIGINT, SIGWINCH] { signal(sig, SIG_DFL) }
        _ = keyboardDone.wait(timeout: .now() + 1)
        if stopPipe[0] >= 0 { close(stopPipe[0]); close(stopPipe[1]) }
        stopPipe = [-1, -1]
        returning = false
        return e
    }

    /// The keyboard thread has left its loop (signalled once).
    private static let keyboardDone = DispatchSemaphore(value: 0)
    nonisolated(unsafe) private static var retainedWinch: DispatchSourceSignal?

    private static func relay(store: DozerStore, sandbox: String, session: String?, wake: Bool, detachKey: UInt8?, quiet: Bool) -> AttachEnd {
        signal(SIGPIPE, SIG_IGN)
        if isatty(STDIN_FILENO) != 0 {
            tcgetattr(STDIN_FILENO, &savedTermios)
            var raw = savedTermios
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
            rawMode = true
            atexit { restoreTerminal() }
        }
        // Window resizes → RESIZE frames.
        signal(SIGWINCH, SIG_IGN)
        let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        winch.setEventHandler {
            let fd = currentSocket()
            if fd >= 0 { UnixSocket.writeAll(fd, Data(ClientWire.resize(terminalSize()))) }
        }
        winch.resume()
        retainedWinch = winch
        for sig in [SIGTERM, SIGHUP, SIGINT] where !(sig == SIGINT && rawMode) {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            s.setEventHandler { endAttach(.detached) }
            s.resume()
            retained.append(s)
        }

        // 599 (594.B4): the terminal's title, while attached (a terminal on stdout, a template set).
        if isatty(STDOUT_FILENO) != 0, case .string(let t) = DozerSettings.load().resolve(SettingKey.terminalTitle).value, !t.isEmpty {
            outputLock.withLock {
                titleTemplate = t
                titleFilter = TitleFilter()
                titleVars = (sandbox, session ?? "", nil, nil)
            }
            let tick = DispatchSource.makeTimerSource(queue: .global())
            tick.schedule(deadline: .now() + TerminalTitle.secondsToNextMinute(), repeating: 60)
            tick.setEventHandler { setTitle() }
            tick.resume()
            retainedTimer = tick
        }

        @Sendable func detachNow(_ before: [UInt8]) {
            let fd = currentSocket()
            if fd >= 0, !before.isEmpty { UnixSocket.writeAll(fd, Data(before)) }
            restoreTerminal()
            if !quiet {
                // 594 (W17): the shortest command that reattaches from here.
                let again = attachedSession.map { reattachCommand(sandbox: sandbox, session: $0.session, defaultSession: $0.defaultSession) }
                    ?? "doz attach \(sandbox)\(session.map { " \($0)" } ?? "")"
                say("detached — the session keeps running (\(again))")
            }
            endAttach(.detached)
        }

        // Keyboard → host, for the whole life of the client. Dropped while disconnected or held.
        // 617: stoppable (poll + the self-pipe) — a returning attach must not leave it waiting for a key.
        let stop = stopPipe[0]
        let done = keyboardDone
        Thread.detachNewThread {
            defer { done.signal() }
            var buf = [UInt8](repeating: 0, count: 4096)
            var scanner = detachKey.map(DetachKeyScanner.init(key:))
            // 599 (594.B4): Ctrl-] opens a one-line menu (a terminal on both ends); a second press detaches.
            let menuAllowed = rawMode && isatty(STDOUT_FILENO) != 0
            var lastPress = Date.distantPast
            while true {
                guard let n = stoppableRead(&buf, stop: stop) else { return }
                if n <= 0 {
                    // A terminal that went away: detach. A pipe or file that ran out: stop typing,
                    // keep showing the session until it ends (SIGTERM / Ctrl-C detaches).
                    if rawMode { endAttach(.detached) }
                    return
                }
                var bytes = Array(buf[0..<n])
                if menuIsOpen() {
                    // At the menu: the detach key (any encoding) detaches; the rest are menu keys.
                    if scanner != nil, case .detach(let before, _) = scanner!.scan(bytes) { detachNow(before); return }
                    if menuKey(bytes, store: store, sandbox: sandbox) { detachNow([]); return }
                    continue
                }
                // 594 (W16): the detach key in every encoding the session may have put the terminal in
                // (legacy byte, kitty CSI-u, modifyOtherKeys) — found on the FIRST press, never forwarded.
                if scanner != nil {
                    switch scanner!.scan(bytes) {
                    case .forward(let b):
                        bytes = b
                    case .detach(let before, let after):
                        guard menuAllowed else { detachNow(before); return }
                        // A quick double press is a plain detach.
                        if Date().timeIntervalSince(lastPress) < 0.5 { detachNow(before); return }
                        lastPress = Date()
                        let fd = currentSocket()
                        if fd >= 0, !before.isEmpty { UnixSocket.writeAll(fd, Data(before)) }
                        openMenu()
                        if !after.isEmpty {
                            if case .detach(let b2, _) = scanner!.scan(after) { detachNow(b2); return }
                            if menuKey(after, store: store, sandbox: sandbox) { detachNow([]); return }
                        }
                        continue
                    }
                }
                if bytes.isEmpty { continue }
                typeOrKeep(Data(bytes))
            }
        }

        var first = true
        var announcedHeld = false
        var resolvedSession = session
        while true {
            if let e = takeEnd() { return e }
            let client: HostClient
            do { client = try HostClient.connect(store: store, autostart: true) } catch {
                if first { sayLast(error.localizedDescription); endAttach(.lost(DozerExit.dozerFailed)); return takeEnd() ?? .lost(DozerExit.dozerFailed) }
                sleep(1)
                continue
            }
            var req = HostRequest(.attach, name: sandbox)
            req.session = resolvedSession
            if resolvedSession == nil { req.openDefault = true }     // 617: no session named — its own, opened if needed
            let size = terminalSize()
            req.cols = size.cols
            req.rows = size.rows
            req.wake = first ? wake : false
            let reply: HostMessage?
            do {
                try client.send(req)
                reply = try client.next()
            } catch {
                reply = nil
            }
            guard let reply, reply.ok != nil else {
                if first { sayLast("the host closed the connection"); endAttach(.lost(DozerExit.dozerFailed)); return takeEnd() ?? .lost(DozerExit.dozerFailed) }
                usleep(500_000)
                continue
            }
            if reply.ok == false {
                let e = reply.error ?? HostError(.failed, "attach failed")
                sayLast(e.message)
                let code = first ? DozerExit.code(for: e) == DozerExit.failed ? DozerExit.dozerFailed : DozerExit.code(for: e) : DozerExit.failed
                endAttach(.lost(code))
                return takeEnd() ?? .lost(code)
            }
            first = false
            resolvedSession = reply.result?["session"]?.stringValue ?? resolvedSession
            if reply.result?["opened"] == .bool(true), !quiet, let s = resolvedSession {
                say("\(sandbox)'s session \(s) was not running — opened it")
            }
            if let s = resolvedSession { setAttached(s, reply.result?["defaultSession"]?.stringValue) }
            // 599 (594.B4): the title follows the session (a switch, a hold, a wake).
            let held = reply.result?["state"]?.stringValue == "held"
            setTitle(session: resolvedSession, image: reply.result?["image"]?.stringValue,
                     phase: held ? reply.result?["phase"]?.stringValue ?? "asleep" : "running")
            if held {
                if !announcedHeld && !quiet {
                    let raw = reply.result?["phase"]?.stringValue
                    let phase = raw.map { Out.phaseLabel($0) } ?? "not running"
                    // 617: running but busy (a start finishing, a snapshot being taken): said as such, not "waiting to run".
                    let what = raw == "running" ? "\(sandbox) is busy (an operation is finishing) — waiting for it"
                                                : "\(sandbox) is \(phase) — waiting for it to run"
                    say("\(what) (\(detachKey.map(describeKey) ?? "close the terminal") to detach)")
                }
                announcedHeld = true
            } else {
                announcedHeld = false
            }
            setSocket(client.fd)
            UnixSocket.writeAll(client.fd, Data(ClientWire.resize(terminalSize())))
            // 609: the host → client stream as every viewer reads it (`ClientWire.ViewerStream`, shared with
            // each web pane): notices out, the end found, a notice's start held for the next read.
            var stream = ClientWire.ViewerStream()
            var chunk = [UInt8](client.reader.takeRemainder())
            var buf = [UInt8](repeating: 0, count: 65536)
            var ending: ClientWire.Ending?
            var cleared = false                          // 617: both screens cleared before this connection's snapshot
            while true {
                // 599: a bridge's notice (removed from the bytes; drawn once they are written).
                let step = stream.feed(chunk)
                if !cleared, !step.screen.isEmpty { clearBothScreens(); cleared = true }
                if let e = step.ending {
                    writeOut(step.screen[...])
                    // The session is over: the terminal is put back before the host's last word.
                    restoreTerminal()
                    for n in step.notices { say(n.text) }
                    if !quiet && !step.endingText.isEmpty { say(step.endingText) }
                    ending = e
                    break
                }
                writeOut(step.screen[...])
                for n in step.notices { showNotice(n) }
                let n = read(client.fd, &buf, buf.count)
                if n < 0 && errno == EINTR { chunk = []; continue }
                if n <= 0 { break }
                chunk = Array(buf[0..<n])
            }
            setSocket(-1)
            if let e = takeEnd() { return e }
            // 599 (594.B4): the menu switched sessions — attach there (the same client, the same terminal).
            if ending == nil, let target = takeSwitch() {
                resolvedSession = target
                announcedHeld = false
                continue
            }
            if let ending {
                let e: AttachEnd
                switch ending {
                case .exited(let c): e = .ended(c)
                case .noSession: e = .lost(DozerExit.notFound)
                case .stopped: e = .lost(DozerExit.failed)
                }
                endAttach(e)
                return takeEnd() ?? e
            }
            writeOut(stream.flush()[...])
            if !quiet && !announcedHeld { say("connection closed (\(sandbox) is asleep or stopping) — reattaching when it runs…") }
            announcedHeld = true
            usleep(300_000)
        }
    }

    nonisolated(unsafe) private static var retained: [DispatchSourceSignal] = []
    nonisolated(unsafe) private static var retainedTimer: DispatchSourceTimer?

    private static func writeOut(_ bytes: ArraySlice<UInt8>) { writeSession(bytes) }

    /// How many trailing bytes might be the start of either host notice (hold them for the next read).
    /// 609: the one rule every viewer uses (`ClientWire.holdBack`).
    static func holdBack(_ bytes: [UInt8]) -> Int { ClientWire.holdBack(bytes) }
}
