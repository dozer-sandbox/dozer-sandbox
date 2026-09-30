// 594 (owner's walkthrough W13): after Ctrl-] detached `doz up` from Claude Code, moving the mouse typed
// `35;44;37M…` into the Mac's shell — the session had turned SGR mouse reporting on in the OUTER
// terminal and the attach client never turned it off. These checks run the real signed `doz` on a
// PSEUDO-TERMINAL (its stdin, stdout and stderr), start a session that turns every such mode on, then
// leave it three ways — Ctrl-] (detach), the session ending, SIGHUP — and assert, each time, that the
// restore bytes come after the session's last byte (and before the client's last line), and that the
// tty's termios is what it was before `doz` put it in raw mode.
// A scratch store under /tmp (seeded from the vmtest store) with one lab sandbox; nobody's store.
import Darwin
import Foundation
import DozerKit
import DozerHost

/// `doz …` on a pseudo-terminal: the parent holds the master (what a terminal emulator would).
final class PTYClient: @unchecked Sendable {
    let process: Process
    let master: Int32
    let slave: Int32
    private let lock = NSLock()
    private var collected: [UInt8] = []
    private var reader: Thread?

    init(_ h: CLIHarness, _ args: [String], in folder: URL? = nil) throws {
        var m: Int32 = -1, s: Int32 = -1
        var ws = winsize(ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&m, &s, nil, nil, &ws) == 0 else { throw POSIXError(.EIO) }
        master = m
        slave = s
        process = h.process(args)
        if let folder { process.currentDirectoryURL = folder }
        let handle = FileHandle(fileDescriptor: s, closeOnDealloc: false)
        process.standardInput = handle
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let fd = m
        let t = Thread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = read(fd, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return }                                  // EIO once every slave fd is closed
                self?.lock.withLock { self?.collected += buf[0..<n] }
            }
        }
        reader = t
        t.start()
    }

    var bytes: [UInt8] { lock.withLock { collected } }
    var text: String { String(decoding: bytes, as: UTF8.self) }
    func type(_ s: String) { _ = s.withCString { Darwin.write(master, $0, strlen($0)) } }
    func type(byte b: UInt8) { var x = b; _ = Darwin.write(master, &x, 1) }

    func wait(_ seconds: Double, _ pred: (PTYClient) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if pred(self) { return true }; usleep(50_000) }
        return pred(self)
    }

    func exited(within seconds: Double) -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        return process.isRunning ? nil : process.terminationStatus
    }

    /// The slave's termios now (the parent holds the slave open too).
    var termios: Darwin.termios {
        var t = Darwin.termios()
        tcgetattr(slave, &t)
        return t
    }

    /// The client killed if still running; the slave closed first (the reader's read then ends), then
    /// the master once the reader has returned (closing a pty master under a blocked read hangs).
    func close() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        Darwin.close(slave)
        let deadline = Date().addingTimeInterval(3)
        while reader?.isFinished == false && Date() < deadline { usleep(20_000) }
        if reader?.isFinished != false { Darwin.close(master) }
    }
}

/// What a TUI turns on (Claude Code: the alt screen, the cursor hidden, SGR any-motion mouse, focus
/// events, bracketed paste, the kitty keyboard protocol, the application keypad, synchronized output).
private let modesOn = #"\033[?1049h\033[?25l\033[?1000;1002;1003;1006h\033[?1004h\033[?2004h\033[?2026h\033[>1u\033="#

/// The same termios, but for PENDIN — the kernel's own "retype pending input" flag, which it sets when a
/// tty goes back to canonical mode with input queued (not a mode `doz` sets).
private func sameTermios(_ a: termios, _ b: termios) -> Bool {
    let pendin = tcflag_t(PENDIN)
    return (a.c_lflag & ~pendin) == (b.c_lflag & ~pendin) && a.c_iflag == b.c_iflag && a.c_oflag == b.c_oflag && a.c_cflag == b.c_cflag
}

/// Assert the restore came after the session's last byte, before `lastLine` (when given).
private func checkRestored(_ c: PTYClient, marker: String, lastLine: String?, _ what: String) {
    let out = c.text
    let esc = "\u{1B}"
    guard let mark = out.range(of: marker, options: .backwards) else { check(false, "\(what): the session's output (\(marker)) was seen"); return }
    guard let restore = out.range(of: "\(esc)[?1000l\(esc)[?1002l\(esc)[?1003l", options: .backwards), restore.lowerBound >= mark.upperBound else {
        check(false, "\(what): the restore sequence came after the session's output — tail: \(out.suffix(200).debugDescription)")
        return
    }
    let tail = String(out[restore.lowerBound...])
    let need = ["?1006l", "?1004l", "?2004l", "?2026l", "?1049l", "?25h", "?1l", "[<1u", "[0m"].map { esc + ($0.hasPrefix("[") ? "" : "[") + $0 }
    let missing = need.filter { !tail.contains($0) } + (tail.contains("\(esc)>") ? [] : ["ESC >"])
    check(missing.isEmpty, "\(what): mouse, focus, paste, sync off; alt screen left; cursor shown; keys normal; kitty popped; SGR reset"
          + (missing.isEmpty ? "" : " — missing \(missing.map(\.debugDescription))"))
    // Nothing of the session after the restore: only the restore itself, then the client's line.
    let afterReset = tail.range(of: "\(esc)[0m").map { String(tail[$0.upperBound...]) } ?? tail
    if let lastLine {
        check(afterReset.contains(lastLine) && !afterReset.contains(marker), "\(what): then \"\(lastLine)\" — and no session byte after the restore")
    } else {
        check(!afterReset.contains(marker), "\(what): no session byte after the restore")
    }
}

func cliTerminalRestoreSuite(binary: String) async {
    let t = onboardingHarness(binary, "t", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    defer {
        t.run(["host", "stop"])
        try? FileManager.default.removeItem(at: t.store)
    }
    print("cli: a detach puts the outer terminal back (W13) — on a pseudo-terminal")
    check(t.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    var r = t.run(["up", "tr", "--image", "lab", "--isolated", "--memory", "512M", "--detach"], timeout: 600)
    check(r.code == 0, "up tr --image lab --detach (exit \(r.code))")

    // 1. Ctrl-] — in a shell whose printf turns every mode on.
    do {
        let c = try PTYClient(t, ["run", "tr", "--session", "modes", "--", "bash", "--norc", "-i"])
        defer { c.close() }
        let before = c.termios
        check(c.wait(30) { $0.text.contains("$") || $0.text.contains("#") }, "run tr -- bash: a prompt on the pty")
        c.type("printf '\(modesOn)'; echo MODES-$((40+2))ON\r")
        check(c.wait(15) { $0.text.contains("MODES-42ON") }, "the session turned the modes on (MODES-42ON)")
        usleep(300_000)
        c.type(byte: 0x1D)
        let code = c.exited(within: 10)
        check(code == 0, "Ctrl-] detaches (exit \(code.map(String.init) ?? "still running"))")
        checkRestored(c, marker: "MODES-42ON", lastLine: "[doz] detached", "Ctrl-]")
        let after = c.termios
        check(sameTermios(after, before), "Ctrl-]: the termios is restored (lflag \(String(after.c_lflag, radix: 16)) = \(String(before.c_lflag, radix: 16)))")
    } catch { check(false, "pty: \(error)") }

    // 2. The session ends by itself.
    do {
        let c = try PTYClient(t, ["run", "tr", "--session", "ends", "--", "sh", "-c", "sleep 2; printf '\(modesOn)'; echo MODES-ENDED; sleep 1; exit 3"])
        defer { c.close() }
        let before = c.termios
        let code = c.exited(within: 30)
        check(code == 3, "the session ends: exit 3 passes through (\(code.map(String.init) ?? "still running"))")
        checkRestored(c, marker: "MODES-ENDED", lastLine: nil, "session ended")
        check(sameTermios(c.termios, before), "session ended: the termios is restored")
    } catch { check(false, "pty: \(error)") }

    // 3. SIGHUP (the terminal closed).
    do {
        let c = try PTYClient(t, ["run", "tr", "--session", "hup", "--", "sh", "-c", "sleep 2; printf '\(modesOn)'; echo MODES-HUP; sleep 600"])
        defer { c.close() }
        let before = c.termios
        check(c.wait(30) { $0.text.contains("MODES-HUP") }, "the session turned the modes on (MODES-HUP)")
        usleep(300_000)
        kill(c.process.processIdentifier, SIGHUP)
        let code = c.exited(within: 10)
        check(code != nil, "SIGHUP ends the client (\(code.map(String.init) ?? "still running"))")
        checkRestored(c, marker: "MODES-HUP", lastLine: nil, "SIGHUP")
        check(sameTermios(c.termios, before), "SIGHUP: the termios is restored")
    } catch { check(false, "pty: \(error)") }

    // 594 (W16): "detach seems to only happen now after twice sending CTRL-]" — Claude Code 2.1.285 pushes
    // the kitty keyboard protocol and modifyOtherKeys, and the terminal then sends Ctrl-] encoded. One
    // press, in each encoding, must detach — and nothing of it (or after it) reaches the session.
    print("cli: one Ctrl-] detaches in every keyboard encoding (W16)")
    let cases: [(String, String, String, [String])] = [
        ("kitty flags 1", #"\033[>1u"#, "\u{1B}[93;5u", []),
        ("kitty flags 3 (event types)", #"\033[>3u"#, "\u{1B}[93;5:1u", []),
        ("kitty flags 31 (all keys, text)", #"\033[>31u"#, "\u{1B}[93;5:1u", []),
        ("modifyOtherKeys 2", #"\033[>4;2m"#, "\u{1B}[27;5;93~", []),
        ("Claude Code 2.1.285's own sequence", #"\033[?1049h\033[<u\033[>5u\033[>4;2m\033[?1004h\033[?2004h"#, "\u{1B}[93;5u", []),
        ("--detach-key ctrl-q, kitty", #"\033[>1u"#, "\u{1B}[113;5u", ["--detach-key", "ctrl-q"]),
    ]
    for (i, (label, push, key, extra)) in cases.enumerated() {
        do {
            let log = "/tmp/keys-\(i).log"
            let c = try PTYClient(t, ["run", "tr", "--session", "k\(i)"] + extra
                                  + ["--", "sh", "-c", "sleep 1; printf '\(push)'; echo READY-K\(i); stty raw -echo; exec cat > \(log)"])
            defer { c.close() }
            check(c.wait(30) { $0.text.contains("READY-K\(i)") }, "\(label): the session pushed its keyboard mode")
            usleep(300_000)
            c.type("x")
            usleep(300_000)
            c.type(key)                                                         // ONE press
            let code = c.exited(within: 8)
            check(code == 0 && c.text.contains("[doz] detached"), "\(label): the first press detaches (exit \(code.map(String.init) ?? "still attached"))")
            let got = t.run(["exec", "tr", "--", "cat", log]).out
            check(got == "x", "\(label): the session got \"x\" and nothing of the detach key (\(got.debugDescription))")
        } catch { check(false, "pty: \(error)") }
    }

    // 594 (W17): the detach line names the SHORTEST command that reattaches from here.
    print("cli: the detach line names the shortest reattach command (W17)")
    func detachLine(_ args: [String], in folder: URL? = nil) -> String {
        guard let c = try? PTYClient(t, args, in: folder) else { return "" }
        defer { c.close() }
        _ = c.wait(30) { $0.text.contains("$") || $0.text.contains("#") || $0.text.contains("READY") }
        usleep(500_000)
        c.type(byte: 0x1D)
        _ = c.exited(within: 8)
        return c.text.components(separatedBy: "[doz] detached").last.map { String($0.prefix(120)) } ?? ""
    }
    let named = detachLine(["run", "tr", "--session", "server", "--", "sh", "-c", "echo READY; exec sleep 600"])
    check(named.contains("(doz attach tr server)"), "a named session: (doz attach tr server) — \(named.debugDescription)")
    let plain = detachLine(["attach", "tr"])
    check(plain.contains("(doz attach tr)"), "the default session: (doz attach tr) — \(plain.debugDescription)")
    let project = t.store.appendingPathComponent("proj-tr")
    try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try? "version: 1\nname: tr\nimage: lab\n".write(to: project.appendingPathComponent("doz_project.yaml"), atomically: true, encoding: .utf8)
    let inProject = detachLine(["attach", "tr"], in: project)
    check(inProject.contains("(doz up)"), "in its project folder: (doz up) — \(inProject.debugDescription)")
    // Each form reaches that same session: `doz up` there and `doz attach tr` open nothing new.
    let before = t.sessions("tr").map(\.name).sorted()
    _ = detachLine(["up"], in: project)
    check(t.sessions("tr").map(\.name).sorted() == before, "doz up (the hint) reattached the same session, opened none")
    r = t.run(["run", "tr", "--session", "bg", "--detach", "--", "sleep", "600"])
    check(r.out.contains("— doz attach tr bg"), "run --detach: the same hint (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    r = t.run(["up", "tr", "--detach"])
    check(r.out.contains("— doz attach tr\n") || r.out.hasSuffix("— doz attach tr"), "up --detach, the default session: doz attach tr (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")

    // A pipe is not a terminal: nothing is written to it.
    r = t.run(["run", "tr", "--session", "piped", "--", "sh", "-c", "sleep 2; printf '\(modesOn)'; echo PIPED; sleep 1"], timeout: 60)
    // (The session's own screen may carry mode resets; the client's restore is this exact run.)
    check(r.out.contains("PIPED") && !r.out.contains("\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1005l\u{1B}[?1006l\u{1B}[?1015l"),
          "stdout a pipe: no restore bytes added to it (exit \(r.code): \(r.out.suffix(160).debugDescription) \(r.err.suffix(160).debugDescription))")
    t.run(["rm", "tr", "--yes"])
}
