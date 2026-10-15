import Darwin
import Foundation
import XCTest
@testable import DozerKit
@testable import DozerHost

/// 617 (owner: "I couldn't use its clipboard"): a program that copies with xclip / xsel / wl-copy — Gemini CLI's
/// clipboardy, Grok Build's command-line route, a script — reaches the Mac's clipboard through the session's terminal
/// as OSC 52; reading is refused; xclip's default PRIMARY selection is not the Mac's clipboard. The real shim runs under
/// /bin/sh in a new session (no controlling terminal), `$DOZ_TTY` a file standing in for the session's terminal.
final class CopyShimTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("copyshim-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try GuestCommand.copyShim.write(to: dir.appendingPathComponent("doz-copy"), atomically: true, encoding: .utf8)
        for n in GuestCommand.copyShimAliases {
            try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent(n).path, withDestinationPath: "doz-copy")
        }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    struct Run { var code: Int32; var out: String; var err: String; var tty: String }

    func run(_ name: String, _ args: [String], input: String = "", env extra: [String] = []) throws -> Run {
        let inFile = dir.appendingPathComponent("in").path, out = dir.appendingPathComponent("out").path
        let err = dir.appendingPathComponent("err").path, tty = dir.appendingPathComponent("tty").path
        try input.write(toFile: inFile, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: tty, contents: Data())
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_addopen(&fa, 0, inFile, O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, out, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&fa, 2, err, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        defer { posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr) }
        let env = ["PATH=\(dir.path):/usr/bin:/bin", "DOZ_TTY=" + tty] + extra
        let argv = (["/bin/sh", dir.appendingPathComponent(name).path] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        XCTAssertEqual(posix_spawn(&pid, "/bin/sh", &fa, &attr, argv, envp), 0)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        func text(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
        return Run(code: (status >> 8) & 0xFF, out: text(out), err: text(err), tty: text(tty))
    }

    func osc52(_ s: String) -> String { "\u{1B}]52;c;" + Data(s.utf8).base64EncodedString() + "\u{07}" }

    func testACopyBecomesOSC52OnTheSessionsTerminal() throws {
        // clipboardy (Gemini CLI) on Linux: xsel --clipboard --input; Grok's CLI route: xclip -selection clipboard -i.
        var r = try run("xsel", ["--clipboard", "--input"], input: "hello from gemini\n")
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(r.tty, osc52("hello from gemini\n"), "the text exactly, trailing newline kept")
        XCTAssertEqual(r.out + r.err, "", "nothing a person sees")
        r = try run("xclip", ["-selection", "clipboard", "-i"], input: "ünïcode ✓")
        XCTAssertEqual(r.tty, osc52("ünïcode ✓"))
        r = try run("wl-copy", [], input: "piped")
        XCTAssertEqual(r.tty, osc52("piped"))
        r = try run("wl-copy", ["as", "arguments"])
        XCTAssertEqual(r.tty, osc52("as arguments"), "wl-copy TEXT…")
        let f = dir.appendingPathComponent("note.txt")
        try "from a file".write(to: f, atomically: true, encoding: .utf8)
        r = try run("xclip", ["-sel", "c", f.path])
        XCTAssertEqual(r.tty, osc52("from a file"), "xclip FILE")
        r = try run("xclip", ["-selection", "clipboard"], input: "in tmux", env: ["TMUX=/tmp/tmux-0/x,1,0"])
        XCTAssertEqual(r.tty, osc52("in tmux"), "inside tmux: to the session's own terminal")
    }

    func testReadingIsRefusedAndPrimaryIsNotTheMacsClipboard() throws {
        for (n, a) in [("xclip", ["-o"]), ("xclip", ["-selection", "clipboard", "-out"]), ("xsel", ["--output"]), ("wl-paste", [])] {
            let r = try run(n, a)
            XCTAssertEqual(r.code, 1, "\(n) \(a)")
            XCTAssertTrue(r.err.contains("cannot read your Mac's clipboard"), r.err)
            XCTAssertEqual(r.tty, "")
        }
        // xclip's default selection is PRIMARY; xsel/wl-copy --primary: not the Mac's clipboard — nothing sent, no failure.
        for (n, a) in [("xclip", []), ("xclip", ["-i"]), ("xsel", ["--primary", "-i"]), ("wl-copy", ["--primary"])] {
            let r = try run(n, a, input: "primary")
            XCTAssertEqual(r.code, 0, "\(n) \(a): \(r.err)")
            XCTAssertEqual(r.tty, "", "\(n) \(a)")
        }
        XCTAssertEqual(try run("xsel", ["--clear"]).tty, "")
        XCTAssertEqual(try run("xclip", ["-version"]).code, 0, "a preflight (--version) answers")
    }

    func testNoTerminalIsRefusedAndAStampMovesWithTheScript() throws {
        let r = try run("wl-copy", [], input: "x", env: ["DOZ_TTY=/nonexistent/tty"])
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.err.contains("no terminal of a Dozer session"), r.err)
        XCTAssertTrue(GuestCommand.copyShim.contains("# doz:clipboard-shim:v1"), "a change to the shim bumps its stamp (a wake re-installs it)")
        XCTAssertTrue(GuestCommand.openShimInstall.contains(GuestCommand.copyShimInstall), "installed wherever the open shim is: boot, wake, session")
        for n in GuestCommand.copyShimAliases { XCTAssertTrue(GuestCommand.copyShimInstall.contains("'\(GuestCommand.openShimDirectory)/\(n)'")) }
    }

    func testASessionIsAnOSC52SinkWhileTheBridgeIsOn() {
        XCTAssertEqual(HostCore.withClipboardSink([:], on: true)["GROK_OSC52_SINK"], "1")
        XCTAssertNil(HostCore.withClipboardSink([:], on: false)["GROK_OSC52_SINK"], "off: no claim")
        XCTAssertEqual(HostCore.withClipboardSink(["GROK_OSC52_SINK": "0"], on: true)["GROK_OSC52_SINK"], "0", "never over the caller's own")
    }
}
