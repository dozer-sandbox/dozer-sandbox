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

    func testOddBytesDoNotConfuseIt() {
        var m = TerminalModes()
        m.feed(Array("\(esc)[?\(String(repeating: "9", count: 200))h plain text \(esc)[31m red \(esc)[?1006h".utf8))
        XCTAssertTrue(m.dec.contains(1006))
        m.feed([0x1B, 0x1B, UInt8(ascii: "["), UInt8(ascii: "?"), UInt8(ascii: "1"), UInt8(ascii: "0"), UInt8(ascii: "0"), UInt8(ascii: "0"), UInt8(ascii: "h")])
        XCTAssertTrue(m.dec.contains(1000))
    }
}
