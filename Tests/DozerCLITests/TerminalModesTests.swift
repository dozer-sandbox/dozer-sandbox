import Foundation
import XCTest
@testable import DozerCLI

/// 594 (W13): what the attach client writes to put the outer terminal back after a session set its modes.
final class TerminalModesTests: XCTestCase {
    private let esc = "\u{1B}"

    func testEverythingOffIsAlwaysSaidAndTheSGRResetIsLast() {
        let s = TerminalModes().restoreSequence
        for m in ["?1000l", "?1002l", "?1003l", "?1005l", "?1006l", "?1015l", "?1004l", "?2004l", "?2026l", "?25h", "?1l"] {
            XCTAssertTrue(s.contains("\(esc)[\(m)"), m)
        }
        XCTAssertTrue(s.contains("\(esc)>"), "keypad normal")
        XCTAssertTrue(s.hasSuffix("\(esc)[0m"))
        XCTAssertFalse(s.contains("1049l"), "the alternate screen is left only when the session entered it")
        XCTAssertFalse(s.contains("u"), "no kitty pop when nothing was pushed")
    }

    func testTheModesAClaudeCodeSessionSetsAreUndone() {
        var m = TerminalModes()
        // What a TUI does on start: alt screen, cursor hidden, SGR any-motion mouse, focus events,
        // bracketed paste, kitty keyboard pushed twice, keypad application — split across chunks.
        let stream = "\(esc)[?1049h\(esc)[?25l\(esc)[?1003;1006h\(esc)[?1004h\(esc)[?2004h\(esc)[>1u\(esc)[>3u\(esc)=hello"
        let bytes = Array(stream.utf8)
        m.feed(bytes[..<7])
        m.feed(bytes[7...])
        XCTAssertTrue(m.dec.isSuperset(of: [1049, 1003, 1006, 1004, 2004]))
        XCTAssertFalse(m.dec.contains(25))
        XCTAssertEqual(m.kittyPushed, 2)
        XCTAssertTrue(m.keypadApplication)
        let s = m.restoreSequence
        XCTAssertTrue(s.contains("\(esc)[?1049l"))
        XCTAssertTrue(s.contains("\(esc)[<2u"), "every kitty entry pushed is popped")
        XCTAssertTrue(s.contains("\(esc)[?1003l") && s.contains("\(esc)[?1006l") && s.contains("\(esc)[?25h"))
    }

    func testWhatTheSessionUndidItselfIsNotUndoneAgain() {
        var m = TerminalModes()
        m.feed(Array("\(esc)[?1049h\(esc)[>1u\(esc)[?1049l\(esc)[<u\(esc)[?47h".utf8))
        XCTAssertFalse(m.dec.contains(1049))
        XCTAssertEqual(m.kittyPushed, 0)
        let s = m.restoreSequence
        XCTAssertFalse(s.contains("1049l"))
        XCTAssertTrue(s.contains("\(esc)[?47l"))
        m.feed(Array("\(esc)[=5;1u".utf8))
        XCTAssertTrue(m.restoreSequence.contains("\(esc)[=0;1u"), "kitty flags set directly are reset")
        m.feed(Array("\(esc)c".utf8))
        XCTAssertEqual(m, TerminalModes(), "RIS resets everything")
    }

    // MARK: W16 — the detach key in every keyboard encoding

    private func scan(_ s: String, key: UInt8 = 0x1D) -> DetachKeyScanner.Result {
        var sc = DetachKeyScanner(key: key)
        return sc.scan(Array(s.utf8))
    }

    func testCtrlBracketDetachesInEveryEncodingOnTheFirstPress() {
        XCTAssertEqual(scan("ab\u{1D}cd"), .detach(forwardFirst: Array("ab".utf8), after: Array("cd".utf8)), "legacy 0x1D (599: what follows is kept for the menu)")
        for enc in ["\(esc)[93;5u",           // kitty, flags 1 (disambiguate) — Claude Code's
                    "\(esc)[93;5:1u",         // flags 3: event type press
                    "\(esc)[93;5:2u",         // a repeat
                    "\(esc)[93:125;5u",       // flags 4: alternate keys (shifted '}')
                    "\(esc)[93;5;29u",        // flags 16: associated text
                    "\(esc)[93;69u",          // caps lock on (64 + ctrl 4 + 1)
                    "\(esc)[27;5;93~"] {      // xterm modifyOtherKeys 2
            XCTAssertEqual(scan("x" + enc + "y"), .detach(forwardFirst: Array("x".utf8), after: Array("y".utf8)), enc.debugDescription)
        }
    }

    func testAReleaseIsSwallowedAndOtherKeysPassUntouched() {
        XCTAssertEqual(scan("\(esc)[93;5:3u"), .forward([]), "a release: never a detach, never forwarded")
        for other in ["\(esc)[93;6u",        // ctrl+shift
                      "\(esc)[93;3u",        // alt
                      "\(esc)[91;5u",        // ctrl+[
                      "\(esc)[27;5;91~",
                      "\(esc)[A", "\(esc)[1;5C", "\(esc)[<64;10;3M", "\(esc)[200~pasted\(esc)[201~", "\(esc)", "plain"] {
            XCTAssertEqual(scan(other), .forward(Array(other.utf8)), other.debugDescription)
        }
    }

    func testASequenceCutByTheReadIsHeldThenMatched() {
        var sc = DetachKeyScanner(key: 0x1D)
        XCTAssertEqual(sc.scan(Array("ok\(esc)[93;".utf8)), .forward(Array("ok".utf8)))
        XCTAssertEqual(sc.scan(Array("5u".utf8)), .detach(forwardFirst: []))
        var other = DetachKeyScanner(key: 0x1D)
        XCTAssertEqual(other.scan(Array("\(esc)[1;".utf8)), .forward([]))
        XCTAssertEqual(other.scan(Array("5A".utf8)), .forward(Array("\(esc)[1;5A".utf8)), "held, then forwarded whole")
    }

    func testTheOtherDetachKeys() {
        let q = try! XCTUnwrap(parseDetachKey("ctrl-q"))
        XCTAssertEqual(scan("\(esc)[113;5u", key: q), .detach(forwardFirst: []), "ctrl-q in kitty: code 113")
        XCTAssertEqual(scan("\(esc)[27;5;113~", key: q), .detach(forwardFirst: []))
        XCTAssertEqual(scan("\u{11}", key: q), .detach(forwardFirst: []))
        XCTAssertEqual(scan("\(esc)[93;5u", key: q), .forward(Array("\(esc)[93;5u".utf8)), "Ctrl-] is just a key then")
        let bs = try! XCTUnwrap(parseDetachKey("ctrl-\\"))
        XCTAssertEqual(scan("\(esc)[92;5u", key: bs), .detach(forwardFirst: []))
    }

    func testModifyOtherKeysIsResetAndTheKittyStackPoppedBeforeTheScreenIsLeft() {
        var m = TerminalModes()
        // Claude Code 2.1.285's own sequence: alt screen, pop, push 5, modifyOtherKeys 2.
        m.feed(Array("\(esc)[?1049h\(esc)[<u\(esc)[>5u\(esc)[>4;2m".utf8))
        let s = m.restoreSequence
        let pop = s.range(of: "\(esc)[<1u"), mok = s.range(of: "\(esc)[>4m"), leave = s.range(of: "\(esc)[?1049l")
        XCTAssertNotNil(pop)
        XCTAssertNotNil(mok)
        XCTAssertTrue(pop!.lowerBound < leave!.lowerBound && mok!.lowerBound < leave!.lowerBound)
        m.feed(Array("\(esc)[>4m".utf8))
        XCTAssertFalse(m.restoreSequence.contains("\(esc)[>4m"))
    }

    // MARK: W17 — the shortest reattach command

    func testTheShortestReattachCommand() throws {
        let dir = URL(fileURLWithPath: "/private/tmp/dzre-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(reattachCommand(sandbox: "hello-dozer", session: "claude", defaultSession: "claude", folder: dir), "doz attach hello-dozer")
        XCTAssertEqual(reattachCommand(sandbox: "hello-dozer", session: "server", defaultSession: "claude", folder: dir), "doz attach hello-dozer server")
        try "version: 1\nname: hello-dozer\nimage: claude-code\n".write(to: dir.appendingPathComponent("doz_project.yaml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(reattachCommand(sandbox: "hello-dozer", session: "claude", defaultSession: "claude", folder: dir), "doz up")
        XCTAssertEqual(reattachCommand(sandbox: "hello-dozer", session: "server", defaultSession: "claude", folder: dir), "doz attach hello-dozer server")
        XCTAssertEqual(reattachCommand(sandbox: "other", session: "claude", defaultSession: "claude", folder: dir), "doz attach other", "another sandbox's folder")
        try "version: 1\nname: hello-dozer\nimage: lab\nsessions:\n  - name: server\n    command: [sh]\n".write(to: dir.appendingPathComponent("doz_project.yaml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(reattachCommand(sandbox: "hello-dozer", session: "server", defaultSession: "shell", folder: dir), "doz up", "the project's first session")
        XCTAssertEqual(reattachCommand(sandbox: "hello-dozer", session: "shell", defaultSession: "shell", folder: dir), "doz attach hello-dozer")
    }

    func testOddBytesDoNotConfuseIt() {
        var m = TerminalModes()
        m.feed(Array("\(esc)[?\(String(repeating: "9", count: 200))h plain text \(esc)[31m red \(esc)[?1006h".utf8))
        XCTAssertTrue(m.dec.contains(1006))
        m.feed([0x1B, 0x1B, UInt8(ascii: "["), UInt8(ascii: "?"), UInt8(ascii: "1"), UInt8(ascii: "0"), UInt8(ascii: "0"), UInt8(ascii: "0"), UInt8(ascii: "h")])
        XCTAssertTrue(m.dec.contains(1000))
    }
}
