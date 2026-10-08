import Darwin
import Foundation
import XCTest
@testable import DozerKit
@testable import DozerHost
@testable import DozerCLI

/// 609 (issue #210): an agent's `xdg-open` must leave a session's screen alone. The guest shim writes ONLY its
/// private marker (never a line a person sees — written behind an agent's TUI it desynchronised the TUI's
/// cursor-relative redraw: stray text, and stale glyphs where the TUI drew spaces); the host takes the marker out
/// once for every viewer (`SessionBridgeScanner`); every viewer — `doz attach`, each web pane and All-sessions
/// tile — reads the host's stream through ONE `ClientWire.ViewerStream`, which never draws a piece of a notice
/// whatever a read cuts.
final class XdgOpenSilenceTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// Claude Code 2.1.227's own output (captured from a session in the web terminal): synchronised output, a
    /// title, SGR colours, cursor-forward and column jumps where it draws blanks, multi-byte glyphs.
    private let tuiA = "\u{1B}[?2026h\u{1B}[2D\u{1B}[4B\r\u{1B}[5C\u{1B}[7A(Bash completed\u{1B}[22Gwith\u{1B}[27Gno\u{1B}[30Goutput)\r\u{1B}[1B"
        + "\u{1B}[38;5;246m  ⎿  \u{1B}[38;5;211mNot logged in · Please run /login\r\u{1B}[1B\u{1B}[39m\u{1B}[K\r\n"
    private let tuiB = "\u{1B}]0;✳ Claude Code\u{07}\u{1B}[48;5;237m\u{1B}[38;5;239m❯\u{1B}[39m one\u{1B}[7Gtwo\u{1B}[11Gthree\u{1B}[7m \u{1B}[27m\r\r\n"
    private let tuiC = "\u{1B}[3G\u{1B}[38;5;211m⏵⏵\u{1B}[6Gbypass\u{1B}[13Gpermissions\u{1B}[39m\r\r\n\u{1B}[2C\u{1B}[4A\u{1B}[?2026l"
    private let oauth = "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        + "&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A37015%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile"
        + "&code_challenge=Xq3Yl0fE5gGQyqJmPp8b1V9vS2kQm6yJ8w7t4u2r1sA&code_challenge_method=S256&state=st-0123456789abcdef"

    /// What the v6 shim writes for one open — the marker, and nothing else.
    private func marker(_ body: String) -> String { "\u{1B}]6340;\(body)\u{07}" }

    // MARK: the host's scanner — the marker out of a TUI's output, wherever a read cuts it

    func testTheShimsMarkerIsTakenOutOfATUIsOutputAtEveryCut() {
        let session = bytes(tuiA + marker("doz-open;" + oauth) + tuiB + marker("doz-file;;/workspace/notes.md")
                            + tuiC + marker("doz-reveal;/workspace/dist/app.zip") + tuiA)
        let screen = bytes(tuiA + tuiB + tuiC + tuiA)
        let events: [BridgeEvent] = [.openURL(oauth), .openFile(path: "/workspace/notes.md", app: nil),
                                     .revealFile(path: "/workspace/dist/app.zip")]
        for cut in 1..<session.count {
            var s = SessionBridgeScanner()
            let a = s.feed(session[..<cut]), b = s.feed(session[cut...])
            XCTAssertEqual(a.out + b.out, screen, "cut at \(cut): the TUI's bytes, exactly, and no byte of a marker")
            XCTAssertEqual(a.events + b.events, events, "cut at \(cut)")
        }
        var s = SessionBridgeScanner()
        var out: [UInt8] = [], ev: [BridgeEvent] = []
        for byte in session { let r = s.feed([byte]); out += r.out; ev += r.events }
        XCTAssertEqual(out, screen, "one byte per read")
        XCTAssertEqual(ev, events)
    }

    // MARK: every viewer reads the host's stream alike — `ClientWire.ViewerStream`

    private func hostStream(ended: Bool) -> (stream: [UInt8], screen: [UInt8], notices: [BridgeNotice]) {
        let n1 = BridgeNotice("oauth", "cc opened https://claude.com/cai/oauth/authorize · sign-in callback localhost:37015 forwarded (10 min)")
        let n2 = BridgeNotice("file", "cc opened notes.md in BBEdit")
        var stream = bytes(tuiA) + Array(ClientWire.notice(n1)) + bytes(tuiB) + Array(ClientWire.notice(n2)) + bytes(tuiC + "\u{1B}[0m")
        if ended { stream += Array(ClientWire.endedNotice(.exited(0), text: "the claude session has ended (exit 0)")) }
        return (stream, bytes(tuiA + tuiB + tuiC + "\u{1B}[0m"), [n1, n2])
    }

    private struct Seen: Equatable {
        var screen: [UInt8] = []
        var notices: [BridgeNotice] = []
        var ending: ClientWire.Ending?
        var endingText = ""
    }
    private func read(_ chunks: [ArraySlice<UInt8>], closeWithoutEnd: Bool = false) -> Seen {
        var v = ClientWire.ViewerStream()
        var seen = Seen()
        for c in chunks {
            let step = v.feed(c)
            seen.screen += step.screen
            seen.notices += step.notices
            if let e = step.ending { seen.ending = e; seen.endingText = step.endingText; return seen }
        }
        if closeWithoutEnd { seen.screen += v.flush() }
        return seen
    }

    func testEveryViewerDrawsNoPieceOfANoticeWhereverAReadCutsIt() {
        let (stream, screen, notices) = hostStream(ended: true)
        let want = Seen(screen: screen, notices: notices, ending: .exited(0), endingText: "the claude session has ended (exit 0)")
        // The host's last word follows the ended notice's BEL; a read cut inside it ends the stream there (the
        // end is the BEL — what is drawn and the notices are exact; the line may come short).
        let lastBEL = stream.lastIndex(of: 0x07)!
        for cut in 1..<stream.count {
            var seen = read([stream[..<cut], stream[cut...]])
            if cut > lastBEL {
                XCTAssertTrue(want.endingText.hasPrefix(seen.endingText), "cut at \(cut): \(seen.endingText)")
                seen.endingText = want.endingText
            }
            XCTAssertEqual(seen, want, "cut at \(cut)")
        }
        var bytewise = read(stream.map { [$0][...] })
        XCTAssertEqual(bytewise.endingText, "", "one byte per read: the end is the BEL, before its line")
        bytewise.endingText = want.endingText
        XCTAssertEqual(bytewise, want, "one byte per read")
        // Three reads: every pair of cuts (a notice cut twice).
        for i in stride(from: 1, to: stream.count, by: 3) {
            for j in stride(from: i + 1, to: lastBEL + 1, by: 5) {
                XCTAssertEqual(read([stream[..<i], stream[i..<j], stream[j...]]), want, "cuts at \(i), \(j)")
            }
        }
    }

    func testAStreamThatClosesWithoutAnEndDrawsWhatWasHeld() {
        let (stream, screen, notices) = hostStream(ended: false)
        for cut in 1..<stream.count {
            let seen = read([stream[..<cut], stream[cut...]], closeWithoutEnd: true)
            XCTAssertEqual(seen.screen, screen, "cut at \(cut): the trailing SGR reset was held, then drawn")
            XCTAssertEqual(seen.notices, notices)
            XCTAssertNil(seen.ending)
        }
    }

    func testTheWholePathFromTheSessionToEveryViewer() {
        // The session's output, one byte per DATA frame (the scanner's worst case), through the host's pump —
        // the marker out, the host's notice in — then the viewers' stream cut at every offset.
        let session = bytes(tuiA + marker("doz-open;" + oauth) + tuiB)
        let notice = Array(ClientWire.notice(BridgeNotice("oauth", "cc opened https://claude.com/cai/oauth/authorize")))
        var s = SessionBridgeScanner()
        var hostOut: [UInt8] = []
        for byte in session {
            let r = s.feed([byte])
            hostOut += r.out
            for e in r.events { if case .openURL = e { hostOut += notice } }
        }
        for cut in 1..<hostOut.count {
            let seen = read([hostOut[..<cut], hostOut[cut...]], closeWithoutEnd: true)
            XCTAssertEqual(seen.screen, bytes(tuiA + tuiB), "cut at \(cut)")
            XCTAssertEqual(seen.notices.map(\.kind), ["oauth"], "cut at \(cut)")
        }
    }

    func testOneHoldBackRuleForEveryViewer() {
        for tail in ["x\u{1B}", "x\u{1B}[", "x\u{1B}[0m", "x\u{1B}[0m\u{1B}]777;d", "x\u{1B}]77", "x\u{1B}]777;doz;notice;open;half",
                     "x\u{1B}[1m", "x\u{1B}]0;t\u{07}", "plain"] {
            let b = bytes(tail)
            XCTAssertEqual(AttachClient.holdBack(b), ClientWire.holdBack(b), tail.debugDescription)
        }
        XCTAssertEqual(ClientWire.holdBack(bytes("x\u{1B}[0m")), 4, "the ended notice's SGR reset may start it")
        XCTAssertEqual(ClientWire.holdBack(bytes("x\u{1B}[1m")), 0, "another SGR is never held")
        XCTAssertEqual(ClientWire.holdBack(bytes("x\u{1B}]0;t\u{07}")), 0)
    }

    // MARK: the session's size — the viewer a person types in owns it

    func testTheViewerAPersonTypesInOwnsTheSessionsSize() {
        final class Viewer {}
        let owners = SessionSizeOwners()
        let pane = Viewer(), terminal = Viewer()
        let (p, t) = (ObjectIdentifier(pane), ObjectIdentifier(terminal))
        owners.claim("cc|claude", p)                                   // the web pane attached (78×44)
        XCTAssertFalse(owners.takeForInput("cc|claude", p), "its own size is in force: nothing to re-apply")
        owners.claim("cc|claude", t)                                   // `doz attach` from a 100×30 terminal
        XCTAssertFalse(owners.takeForInput("cc|claude", t))
        XCTAssertTrue(owners.takeForInput("cc|claude", p), "back in the pane: its size is re-applied before its keys")
        XCTAssertFalse(owners.takeForInput("cc|claude", p), "once")
        XCTAssertTrue(owners.takeForInput("cc|claude", t), "and the terminal's when its person types there again")
        XCTAssertTrue(owners.takeForInput("cc|shell", p), "per session: another session's size is its own")
        XCTAssertFalse(owners.takeForInput("cc|shell", p))
    }

    // MARK: the guest shim — nothing a person sees; the caller hears a refusal (stderr + exit 1)

    private var dir: URL!
    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dz609-\(getpid())-\(UInt32.random(in: 0 ... .max))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private struct Run { var code: Int32; var out: String; var err: String; var tty: String; var pty: String }

    /// The shim run as an opener does it: in a NEW session (`setsid` — no controlling terminal, so `/dev/tty`
    /// cannot be opened), stdin /dev/null. `dozTTY`: a file standing in for the session's terminal; `ptyOut`:
    /// stdout a pseudo-terminal (read back from its master).
    private func shim(_ args: [String], dozTTY: Bool = true, tmux: Bool = false, ptyOut: Bool = false) throws -> Run {
        let file = dir.appendingPathComponent("xdg-open")
        try GuestCommand.openShim.write(to: file, atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent("out").path, err = dir.appendingPathComponent("err").path
        let tty = dir.appendingPathComponent("doz-tty").path
        FileManager.default.createFile(atPath: tty, contents: Data())
        var master: Int32 = -1, slave: Int32 = -1
        if ptyOut { XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0) }
        defer { if master >= 0 { close(master) }; if slave >= 0 { close(slave) } }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        if ptyOut { posix_spawn_file_actions_adddup2(&fa, slave, 1) } else { posix_spawn_file_actions_addopen(&fa, 1, out, O_WRONLY | O_CREAT | O_TRUNC, 0o600) }
        posix_spawn_file_actions_addopen(&fa, 2, err, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        defer { posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr) }
        var env = ["PATH=/usr/bin:/bin"]
        if dozTTY { env.append("DOZ_TTY=" + tty) }
        if tmux { env.append("TMUX=/tmp/tmux-0/doz-shell,1,0") }
        let argv = (["/bin/sh", file.path] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        XCTAssertEqual(posix_spawn(&pid, "/bin/sh", &fa, &attr, argv, envp), 0)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        var fromPty = ""
        if ptyOut {
            _ = fcntl(master, F_SETFL, O_NONBLOCK)
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = Darwin.read(master, &buf, buf.count)
            if n > 0 { fromPty = String(decoding: buf[0..<n], as: UTF8.self) }
        }
        func text(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
        return Run(code: (status >> 8) & 0xFF, out: ptyOut ? "" : text(out), err: text(err), tty: text(tty), pty: fromPty)
    }

    func testTheShimWritesOnlyTheMarkerAndNothingAPersonSees() throws {
        XCTAssertTrue(GuestCommand.openShim.contains("# doz:open-url-shim:v6"), "609 changed the shim: a new stamp, so a wake re-installs it")
        XCTAssertFalse(GuestCommand.openShim.contains("Asking your Mac"), "no line for a person in the shim")
        // An opener in a new session (Claude Code's `open`): the marker reaches the session's terminal ($DOZ_TTY).
        var r = try shim([oauth])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(r.tty, marker("doz-open;" + oauth), "exactly the marker — no line, no newline")
        XCTAssertEqual(r.out, "", "nothing to the caller's output")
        XCTAssertEqual(r.err, "", "nothing to the caller's errors")
        // Inside tmux: the marker to $DOZ_TTY (tmux drops it), still nothing else.
        r = try shim(["https://example.com/a b"], tmux: true)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(r.tty, marker("doz-open;https://example.com/a b"))
        XCTAssertEqual(r.out + r.err, "")
        // No session terminal, stdout a terminal: the marker there — and only it.
        r = try shim(["https://example.com/x"], dozTTY: false, ptyOut: true)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(r.pty, marker("doz-open;https://example.com/x"), "only the marker on the terminal")
        XCTAssertEqual(r.err, "")
    }

    func testTheCallerHearsARefusalAndTheScreenNothing() throws {
        // No terminal at all (stdout a file, no $DOZ_TTY, no controlling terminal): refused, never a marker in
        // the caller's output (an agent's tool would show it, or echo it back into the session).
        var r = try shim(["https://example.com/x"], dozTTY: false)
        XCTAssertEqual(r.code, 1)
        XCTAssertEqual(r.out, "", "no marker in a captured output")
        XCTAssertTrue(r.err.contains("no terminal of a Dozer session"), r.err)
        // A refusal goes to the caller's stderr with exit 1; the session's terminal gets nothing.
        for (args, says) in [(["ftp://example.com/x"], "only http and https URLs go to the Mac"),
                             (["/workspace/notes.md"], "this sandbox is isolated"),
                             (["--app", "Typora", "https://example.com/"], "--app is for files")] {
            r = try shim(args)
            XCTAssertEqual(r.code, 1, args.description)
            XCTAssertTrue(r.err.contains(says), r.err)
            XCTAssertEqual(r.tty, "", "\(args): nothing on the session's terminal")
            XCTAssertEqual(r.out, "")
        }
        // A good URL and a refused one: the good one is sent, the status says one failed.
        r = try shim(["https://example.com/ok", "ftp://x/"])
        XCTAssertEqual(r.code, 1)
        XCTAssertEqual(r.tty, marker("doz-open;https://example.com/ok"))
        XCTAssertTrue(r.err.contains("only http and https"), r.err)
    }
}
