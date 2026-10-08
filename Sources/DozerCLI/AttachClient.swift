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
        for sig in [SIGTERM, SIGHUP, SIGINT] where !(sig == SIGINT && rawMode) {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            s.setEventHandler { finish(0) }
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

        func detachNow(_ before: [UInt8]) -> Never {
            let fd = currentSocket()
            if fd >= 0, !before.isEmpty { UnixSocket.writeAll(fd, Data(before)) }
            restoreTerminal()
            if !quiet {
                // 594 (W17): the shortest command that reattaches from here.
                let again = attachedSession.map { reattachCommand(sandbox: sandbox, session: $0.session, defaultSession: $0.defaultSession) }
                    ?? "doz attach \(sandbox)\(session.map { " \($0)" } ?? "")"
                say("detached — the session keeps running (\(again))")
            }
            finish(0)
        }

        // Keyboard → host, for the whole life of the client. Dropped while disconnected or held.
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 4096)
            var scanner = detachKey.map(DetachKeyScanner.init(key:))
            // 599 (594.B4): Ctrl-] opens a one-line menu (a terminal on both ends); a second press detaches.
            let menuAllowed = rawMode && isatty(STDOUT_FILENO) != 0
            var lastPress = Date.distantPast
            while true {
                let n = read(STDIN_FILENO, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 {
                    // A terminal that went away: detach. A pipe or file that ran out: stop typing,
                    // keep showing the session until it ends (SIGTERM / Ctrl-C detaches).
                    if rawMode { finish(0) }
                    return
                }
                var bytes = Array(buf[0..<n])
                if menuIsOpen() {
                    // At the menu: the detach key (any encoding) detaches; the rest are menu keys.
                    if scanner != nil, case .detach(let before, _) = scanner!.scan(bytes) { detachNow(before) }
                    if menuKey(bytes, store: store, sandbox: sandbox) { detachNow([]) }
                    continue
                }
                // 594 (W16): the detach key in every encoding the session may have put the terminal in
                // (legacy byte, kitty CSI-u, modifyOtherKeys) — found on the FIRST press, never forwarded.
                if scanner != nil {
                    switch scanner!.scan(bytes) {
                    case .forward(let b):
                        bytes = b
                    case .detach(let before, let after):
                        guard menuAllowed else { detachNow(before) }
                        // A quick double press is a plain detach.
                        if Date().timeIntervalSince(lastPress) < 0.5 { detachNow(before) }
                        lastPress = Date()
                        let fd = currentSocket()
                        if fd >= 0, !before.isEmpty { UnixSocket.writeAll(fd, Data(before)) }
                        openMenu()
                        if !after.isEmpty {
                            if case .detach(let b2, _) = scanner!.scan(after) { detachNow(b2) }
                            if menuKey(after, store: store, sandbox: sandbox) { detachNow([]) }
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
            let client: HostClient
            do { client = try HostClient.connect(store: store, autostart: true) } catch {
                if first { sayLast(error.localizedDescription); finish(DozerExit.dozerFailed) }
                sleep(1)
                continue
            }
            var req = HostRequest(.attach, name: sandbox)
            req.session = resolvedSession
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
                if first { sayLast("the host closed the connection"); finish(DozerExit.dozerFailed) }
                usleep(500_000)
                continue
            }
            if reply.ok == false {
                let e = reply.error ?? HostError(.failed, "attach failed")
                sayLast(e.message)
                finish(first ? DozerExit.code(for: e) == DozerExit.failed ? DozerExit.dozerFailed : DozerExit.code(for: e) : DozerExit.failed)
            }
            first = false
            resolvedSession = reply.result?["session"]?.stringValue ?? resolvedSession
            if let s = resolvedSession { setAttached(s, reply.result?["defaultSession"]?.stringValue) }
            // 599 (594.B4): the title follows the session (a switch, a hold, a wake).
            let held = reply.result?["state"]?.stringValue == "held"
            setTitle(session: resolvedSession, image: reply.result?["image"]?.stringValue,
                     phase: held ? reply.result?["phase"]?.stringValue ?? "asleep" : "running")
            if held {
                if !announcedHeld && !quiet {
                    let phase = reply.result?["phase"]?.stringValue.map { Out.phaseLabel($0) } ?? "not running"
                    say("\(sandbox) is \(phase) — waiting for it to run (\(detachKey.map(describeKey) ?? "close the terminal") to detach)")
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
            while true {
                // 599: a bridge's notice (removed from the bytes; drawn once they are written).
                let step = stream.feed(chunk)
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
            // 599 (594.B4): the menu switched sessions — attach there (the same client, the same terminal).
            if ending == nil, let target = takeSwitch() {
                resolvedSession = target
                announcedHeld = false
                continue
            }
            if let ending {
                switch ending {
                case .exited(let c): finish(c)
                case .noSession: finish(DozerExit.notFound)
                case .stopped: finish(DozerExit.failed)
                }
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
