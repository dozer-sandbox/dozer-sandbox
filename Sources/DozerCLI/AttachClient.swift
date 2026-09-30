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

/// Write session bytes to the terminal (following the modes they set) — unless it was restored.
private func writeSession(_ bytes: ArraySlice<UInt8>) {
    guard !bytes.isEmpty else { return }
    outputLock.lock(); defer { outputLock.unlock() }
    guard !outerRestored else { return }
    outerModes.feed(bytes)
    UnixSocket.writeAll(STDOUT_FILENO, Data(bytes))
}

/// Put the outer terminal back (once): its modes, when stdout is a terminal, then the saved termios.
private func restoreTerminal() {
    outputLock.lock()
    if !outerRestored {
        outerRestored = true
        if isatty(STDOUT_FILENO) != 0 { UnixSocket.writeAll(STDOUT_FILENO, Data(outerModes.restoreSequence.utf8)) }
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

        // Keyboard → host, for the whole life of the client. Dropped while disconnected or held.
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 4096)
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
                if let k = detachKey, let i = bytes.firstIndex(of: k) {
                    bytes = Array(bytes[..<i])
                    let fd = currentSocket()
                    if fd >= 0, !bytes.isEmpty { UnixSocket.writeAll(fd, Data(bytes)) }
                    restoreTerminal()
                    if !quiet { say("detached — the session keeps running (doz attach \(sandbox)\(session.map { " \($0)" } ?? ""))") }
                    finish(0)
                }
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
            if reply.result?["state"]?.stringValue == "held" {
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
            var pending = [UInt8](client.reader.takeRemainder())
            var buf = [UInt8](repeating: 0, count: 65536)
            var ending: ClientWire.Ending?
            while true {
                if let (e, start) = ClientWire.findEnding(in: pending) {
                    writeOut(pending[..<start])
                    let rest = pending[start...]
                    // The session is over: the terminal is put back before the host's last word.
                    restoreTerminal()
                    if let bel = rest.firstIndex(of: 0x07) {
                        let text = String(decoding: rest[(bel + 1)...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !quiet && !text.isEmpty { say(text.replacingOccurrences(of: "[doz] ", with: "")) }
                    }
                    ending = e
                    break
                }
                let hold = holdBack(pending)
                writeOut(pending[..<(pending.count - hold)])
                pending = Array(pending.suffix(hold))
                let n = read(client.fd, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                pending += buf[0..<n]
            }
            setSocket(-1)
            if let ending {
                switch ending {
                case .exited(let c): finish(c)
                case .noSession: finish(DozerExit.notFound)
                case .stopped: finish(DozerExit.failed)
                }
            }
            writeOut(pending[...])
            if !quiet && !announcedHeld { say("connection closed (\(sandbox) is asleep or stopping) — reattaching when it runs…") }
            announcedHeld = true
            usleep(300_000)
        }
    }

    nonisolated(unsafe) private static var retained: [DispatchSourceSignal] = []

    private static func writeOut(_ bytes: ArraySlice<UInt8>) { writeSession(bytes) }

    /// How many trailing bytes might be the start of the ended notice (hold them for the next read).
    static func holdBack(_ bytes: [UInt8]) -> Int {
        let prefix = Array(ClientWire.sentinelPrefix.utf8)
        let window = min(bytes.count, prefix.count + 24)
        guard window > 0 else { return 0 }
        for i in (bytes.count - window)..<bytes.count where bytes[i] == 0x1B {
            let tail = Array(bytes[i...])
            let n = min(tail.count, prefix.count)
            if Array(tail.prefix(n)) == Array(prefix.prefix(n)) { return bytes.count - i }
        }
        return 0
    }
}
