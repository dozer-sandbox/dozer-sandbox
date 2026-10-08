import Foundation
import XCTest
@testable import DozerCLI
@testable import DozerHost

/// W32: an image's STATUS is always a word; W33: a host of another build is said, older or newer.
final class StatusWordsTests: XCTestCase {
    func testAnImagesStatusIsAlwaysAWord() {
        var r = ImageRow(name: "claude-code", kind: "builtin", baked: true)
        XCTAssertEqual(r.computedStatus, "up to date")
        r.available = "2.1.300"
        XCTAssertEqual(r.computedStatus, "update available")
        r.olderRecipe = ["tmux"]
        XCTAssertEqual(r.computedStatus, "older recipe")
        r.preparing = true
        XCTAssertEqual(r.computedStatus, "preparing")
        XCTAssertEqual(ImageRow(name: "pi", kind: "builtin", baked: false).computedStatus, "not prepared")
        var tpl = ImageRow(name: "node-tools", kind: "custom", baked: true)
        tpl.fillStanding()
        XCTAssertEqual(tpl.status, "up to date", "a template is never a bare dash")
    }

    func testAHostOfAnotherBuildIsSaid() {
        XCTAssertNil(hostBuildNote(host: "0.12.0-rc.10", this: "0.12.0-rc.10"))
        XCTAssertEqual(hostBuildNote(host: "0.12.0-rc.8", this: "0.12.0-rc.10"),
                       "the doz host is 0.12.0-rc.8 (this doz is 0.12.0-rc.10) — `doz host stop` switches to 0.12.0-rc.10; sandboxes hibernate and wake")
        XCTAssertTrue(hostBuildNote(host: "0.13.0", this: "0.12.0")?.hasPrefix("the doz host is 0.13.0, newer than this doz (0.12.0) — upgrade this doz") == true)
    }
}
