import Foundation
import XCTest
import DozerKit
@testable import DozerHost
@testable import DozerCLI

/// 599 (594.B1/B2): the host's reader of a session's output — the two sequences a bridge owns are taken
/// out (whole, even when a read cuts them), everything else passes through unchanged.
final class SessionBridgeTests: XCTestCase {
    private func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testACopyIsTakenOutAndDecoded() {
        var s = SessionBridgeScanner()
        let (out, ev) = s.feed(bytes("before\u{1B}]52;c;\(b64("hello"))\u{07}after"))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "beforeafter")
        XCTAssertEqual(ev, [.copy(Data("hello".utf8))])
    }

    func testSTEndsItAndPaddingIsOptional() {
        var s = SessionBridgeScanner()
        let (out, ev) = s.feed(bytes("\u{1B}]52;;aGk\u{1B}\\x"))
        XCTAssertEqual(out, bytes("x"))
        XCTAssertEqual(ev, [.copy(Data("hi".utf8))])
    }

    func testASequenceCutByEveryPossibleReadIsStillWhole() {
        let whole = bytes("ab\u{1B}]52;c;\(b64("split me"))\u{07}cd\u{1B}]6340;doz-open;https://example.com/x\u{07}ef")
        for cut in 1..<whole.count {
            var s = SessionBridgeScanner()
            let a = s.feed(whole[..<cut]), b = s.feed(whole[cut...])
            XCTAssertEqual(String(decoding: a.out + b.out, as: UTF8.self), "abcdef", "cut at \(cut)")
            XCTAssertEqual(a.events + b.events, [.copy(Data("split me".utf8)), .openURL("https://example.com/x")], "cut at \(cut)")
        }
    }

    func testAReadIsNeverPassedOn() {
        var s = SessionBridgeScanner()
        let (out, ev) = s.feed(bytes("\u{1B}]52;c;?\u{07}"))
        XCTAssertTrue(out.isEmpty)
        XCTAssertEqual(ev, [.copyRead])
    }

    func testOtherSequencesPassThroughUnchanged() {
        let text = "\u{1B}]0;title\u{07}\u{1B}]8;;https://x\u{1B}\\link\u{1B}]8;;\u{1B}\\\u{1B}[31mred\u{1B}]5;x\u{07}\u{1B}]63;y\u{07}\u{1B}\u{1B}]52"
        var s = SessionBridgeScanner()
        let a = s.feed(bytes(text))
        let b = s.feed(bytes("x"))                  // `ESC ] 5 2` then `x`: not ours after all
        XCTAssertEqual(String(decoding: a.out + b.out, as: UTF8.self), text + "x")
        XCTAssertTrue(a.events.isEmpty && b.events.isEmpty)
    }

    func testTooLargeIsDroppedWholeAndSaid() {
        var s = SessionBridgeScanner()
        let big = String(repeating: "A", count: SessionBridgeScanner.maximumCopyEncoded + 100)
        let (out, ev) = s.feed(bytes("x\u{1B}]52;c;\(big)\u{07}y"))
        XCTAssertEqual(out, bytes("xy"))
        guard case .copyTooLarge = ev.first else { return XCTFail("\(ev)") }
        let (o2, e2) = s.feed(bytes("\u{1B}]6340;doz-open;https://\(String(repeating: "a", count: 3000))\u{07}z"))
        XCTAssertEqual(o2, bytes("z"))
        XCTAssertEqual(e2, [.openTooLong])
    }

    func testAnAbortedStringIsDroppedAndWhatFollowsIsKept() {
        var s = SessionBridgeScanner()
        let (out, ev) = s.feed(bytes("\u{1B}]52;c;aGk\u{1B}[1mB\u{1B}]52;c;aGk\u{18}C"))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "\u{1B}[1mBC")
        XCTAssertTrue(ev.isEmpty)
    }

    func testASnapshotStartsClean() {
        var s = SessionBridgeScanner()
        _ = s.feed(bytes("\u{1B}]52;c;aG"))
        s.reset()
        let (out, ev) = s.feed(bytes("k\u{07}plain"))
        XCTAssertEqual(out, bytes("k\u{07}plain"))
        XCTAssertTrue(ev.isEmpty)
    }

    func testOnlyDozOpenIsAnOpen() {
        var s = SessionBridgeScanner()
        let (out, ev) = s.feed(bytes("\u{1B}]6340;open-url;https://a\u{07}\u{1B}]6340;doz-open;http://b/c?d=e\u{07}"))
        XCTAssertTrue(out.isEmpty)
        XCTAssertEqual(ev, [.openURL("http://b/c?d=e")])
    }

    // MARK: the notices (host → viewer)

    func testNoticesAreTakenOutWhereverTheyAre() {
        var b = bytes("A") + [UInt8](ClientWire.notice(BridgeNotice("clipboard", "lab copied 5 chars"))) + bytes("B")
            + [UInt8](ClientWire.notice(BridgeNotice("open", "x;y"))) + bytes("C")
        let n = ClientWire.takeNotices(&b)
        XCTAssertEqual(n, [BridgeNotice("clipboard", "lab copied 5 chars"), BridgeNotice("open", "x;y")])
        XCTAssertEqual(b, bytes("ABC"))
    }

    func testANoticeCarriesNoControlCharacter() {
        let d = ClientWire.notice(BridgeNotice("k;ind\u{07}", "a\u{1B}]52;c;?\u{07}b\u{9B}"))
        var b = [UInt8](d)
        XCTAssertEqual(b.filter { $0 == 0x07 }.count, 1)
        XCTAssertEqual(b.filter { $0 == 0x1B }.count, 1)
        XCTAssertEqual(ClientWire.takeNotices(&b), [BridgeNotice("kind", "a]52;c;?b")])
    }

    func testAnUnfinishedNoticeIsHeldBack() {
        let full = [UInt8](ClientWire.notice(BridgeNotice("clipboard", String(repeating: "long text ", count: 30))))
        let cut = bytes("screen") + full.prefix(200)
        XCTAssertEqual(ClientWire.unfinishedNotice(cut), 200)
        XCTAssertEqual(AttachClient.holdBack(cut), 200)
        XCTAssertEqual(ClientWire.unfinishedNotice(bytes("screen") + full), 0)
        XCTAssertEqual(AttachClient.holdBack(bytes("x\u{1B}]77")), 4)
    }

    func testTheRepaintFrameIsParsed() {
        var p = ClientWire.Parser()
        XCTAssertEqual(p.feed(bytes("ab") + ClientWire.repaint + bytes("c")), [.input(Data("ab".utf8)), .repaint, .input(Data("c".utf8))])
    }

    // MARK: settings

    func testTheClipboardIsAPerSandboxSetting() throws {
        XCTAssertTrue(DozerSettings.perSandbox.contains(SettingKey.clipboard))
        let d = try XCTUnwrap(DozerSettings.definition(SettingKey.clipboard))
        XCTAssertEqual(d.defaultValue, .string("write"))
        XCTAssertThrowsError(try d.parse("maybe"))
        XCTAssertThrowsError(try HostCore.checkedSandboxSettings([SettingKey.theme: .string("dark")]))
        XCTAssertEqual(try HostCore.checkedSandboxSettings([SettingKey.clipboard: .string("off")]), [SettingKey.clipboard: .string("off")])
    }

    func testTheSandboxValueWinsOverTheSetting() throws {
        var cfg = SandboxConfig(name: "s", image: "lab", spec: SandboxSpec(name: "s", storeRoot: URL(fileURLWithPath: "/tmp/dzb")), workspace: nil)
        let empty = DozerSettings(text: "")
        XCTAssertEqual(HostCore.sandboxValue(cfg, SettingKey.clipboard, settings: empty), .string("write"))
        cfg.settings = [SettingKey.clipboard: .string("off")]
        XCTAssertEqual(HostCore.sandboxValue(cfg, SettingKey.clipboard, settings: empty), .string("off"))
    }

    func testTheProjectFileTakesClipboard() throws {
        let p = try DozerProject.parse("version: 1\nname: p\nimage: lab\nclipboard: off\n")
        XCTAssertEqual(p.settings[SettingKey.clipboard], .string("off"))
        XCTAssertEqual(p.createOptions(folder: URL(fileURLWithPath: "/tmp/p"), file: URL(fileURLWithPath: "/tmp/p/doz_project.yaml")).settings,
                       [SettingKey.clipboard: .string("off")])
        XCTAssertThrowsError(try DozerProject.parse("version: 1\nname: p\nimage: lab\nclipboard: maybe\n"))
        XCTAssertTrue(DozerProject(name: "p", image: "lab").render().contains("# clipboard: write"))
    }
}
