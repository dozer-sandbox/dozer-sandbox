import Foundation
import XCTest
@testable import DozerCLI
@testable import DozerHost

/// 599 (594.B4): the terminal title from ui.terminal_title, the session's own titles kept out while doz
/// sets it, and the Ctrl-] menu's keys in every encoding.
final class TitleAndMenuTests: XCTestCase {
    private let esc = "\u{1B}"

    func testTheTitleIsRenderedFromTheClosedVariables() {
        let noon = Date(timeIntervalSince1970: 1_800_000_000)          // a fixed instant
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(TerminalTitle.time(noon, timeZone: utc), "08:00")
        XCTAssertEqual(TerminalTitle.render("{sandbox} · {session} · {time}", sandbox: "hello", session: "claude", image: "claude-code",
                                            phase: "running", now: noon, timeZone: utc), "hello · claude · 08:00")
        XCTAssertEqual(TerminalTitle.render("{image}/{session} ({phase})", sandbox: "a", session: "s", image: "pi", phase: "hibernated"),
                       "pi/s (hibernated)")
        XCTAssertEqual(TerminalTitle.render("{x} {sandbox", sandbox: "a", session: "s", image: nil, phase: nil), "{x} {sandbox",
                       "an unknown or open variable is left as written")
        XCTAssertEqual(TerminalTitle.render("a\u{07}b{session}", sandbox: "a", session: "s\u{1B}", image: nil, phase: nil), "abs",
                       "never a control character")
        XCTAssertLessThanOrEqual(TerminalTitle.secondsToNextMinute(Date(timeIntervalSince1970: 59.5)), 0.6)
    }

    func testTheTemplateSettingIsChecked() throws {
        let d = try XCTUnwrap(DozerSettings.definition(SettingKey.terminalTitle))
        XCTAssertEqual(d.defaultValue, .string("{sandbox} · {session} · {time}"))
        XCTAssertEqual(try d.parse("{sandbox} — {time} "), .string("{sandbox} — {time} "), "its spaces are kept")
        XCTAssertEqual(try d.parse(""), .string(""))
        for bad in ["{bogus}", "{sandbox", "sandbox}", "a\u{07}", String(repeating: "x", count: 121)] {
            XCTAssertThrowsError(try d.parse(bad), bad.debugDescription)
        }
    }

    func testTheSessionsOwnTitleIsKeptOutAndNothingElse() {
        var f = TitleFilter()
        let input = "a\(esc)]2;own\u{07}b\(esc)]0;x\(esc)\\c\(esc)]1;icon\u{07}d\(esc)]10;?\u{07}e\(esc)]52;c;aGk=\u{07}\(esc)[31mf\(esc)]8;;u\(esc)\\g"
        XCTAssertEqual(String(decoding: f.feed(Array(input.utf8)), as: UTF8.self), "abcd\(esc)]10;?\u{07}e\(esc)]52;c;aGk=\u{07}\(esc)[31mf\(esc)]8;;u\(esc)\\g")
        // Cut at every offset.
        let whole = Array("x\(esc)]2;title\u{07}y\(esc)]22;z\u{07}".utf8)
        for cut in 1..<whole.count {
            var g = TitleFilter()
            let out = g.feed(whole[..<cut]) + g.feed(whole[cut...])
            XCTAssertEqual(String(decoding: out, as: UTF8.self), "xy\(esc)]22;z\u{07}", "cut \(cut)")
        }
    }

    func testMenuKeysInEveryEncoding() {
        XCTAssertEqual(MenuKey.decode(Array("n".utf8)), .char("n"))
        XCTAssertEqual(MenuKey.decode([0x1B]), .escape)
        XCTAssertEqual(MenuKey.decode(Array("\(esc)[27u".utf8)), .escape, "kitty Esc")
        XCTAssertEqual(MenuKey.decode(Array("\(esc)[27;1:1u".utf8)), .escape)
        XCTAssertEqual(MenuKey.decode(Array("\(esc)[110u".utf8)), .char("n"), "kitty, all keys as escapes")
        XCTAssertEqual(MenuKey.decode(Array("\(esc)[110;1:3u".utf8)), .release, "a release is not a press")
        XCTAssertEqual(MenuKey.decode(Array("\(esc)[27;1;115~".utf8)), .char("s"), "modifyOtherKeys")
        XCTAssertEqual(MenuKey.decode(Array("\(esc)[A".utf8)), .other)
        XCTAssertEqual(MenuKey.decode(Array("2".utf8)), .char("2"))
    }
}
