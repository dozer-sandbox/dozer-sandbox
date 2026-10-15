import Foundation
import XCTest
@testable import DozerCLI
@testable import DozerHost

/// 617 (owner: attaching flashed an earlier program's alternate screen): before a connection's snapshot the attach
/// client clears BOTH buffers — the alternate one (entered, cleared, left) and the primary one with its scrollback.
/// The real-pty check (the order against the snapshot, the history kept, the detach) is
/// probes/617-*/stageC/altscreen-run.sh.
final class AttachScreenTests: XCTestCase {
    func testBothScreensAreClearedAndTheTerminalEndsOnThePrimaryOne() {
        let s = AttachScreen.clearBoth
        XCTAssertEqual(s, "\u{1B}[?1049h\u{1B}[H\u{1B}[2J\u{1B}[?1049l\u{1B}[H\u{1B}[2J\u{1B}[3J")
        let enter = s.range(of: "\u{1B}[?1049h")!, leave = s.range(of: "\u{1B}[?1049l")!
        XCTAssertTrue(enter.upperBound < leave.lowerBound, "the alternate buffer is cleared while in it")
        XCTAssertTrue(s.hasSuffix("\u{1B}[2J\u{1B}[3J"), "the primary screen and its scrollback last: the snapshot's own ?1049l then uncovers nothing")
        XCTAssertFalse(s.contains("\u{1B}c"), "no full reset here (the snapshot does it; a reset would also drop the pushed title)")
    }

    /// 617 (owner: `doz create … --start`, then `doz attach NAME` hung): with no session named, `doz attach` asks the
    /// host to open the image's own session when it is not running (`openDefault`); a client that does not ask (the
    /// dashboard's panes) never gets one opened by arriving. The VM proof: probes/617-*/stageC/attach-nosession-run.sh.
    func testAnAttachWithNoSessionAsksForTheImagesOwn() throws {
        var r = HostRequest(.attach, name: "demo")
        r.openDefault = true
        let back = try HostWire.decoder.decode(HostRequest.self, from: HostWire.encoder.encode(r))
        XCTAssertEqual(back.openDefault, true)
        XCTAssertNil(try HostWire.decoder.decode(HostRequest.self, from: HostWire.encoder.encode(HostRequest(.attach, name: "demo"))).openDefault,
                     "an older client (and the web) never sends it")
    }
}
