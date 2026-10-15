import Foundation
import XCTest
@testable import DozerHost

/// 617: how a Mac path is SHOWN — `~/…` under the Mac user's home (the dashboard's `core/paths.js` does the same with
/// the homes the session info carries). Display only; the seam `DOZ_TEST_HOME` counts only in a guarded run.
final class DisplayPathTests: XCTestCase {
    func testAPathUnderHomeReadsTilde() {
        let homes = ["/Users/me"]
        XCTAssertEqual(DisplayPath.tilde("/Users/me/dozer-sandbox-workspaces/try-fabric", homes: homes), "~/dozer-sandbox-workspaces/try-fabric")
        XCTAssertEqual(DisplayPath.tilde("/Users/me", homes: homes), "~")
        XCTAssertEqual(DisplayPath.tilde("/Users/meet/x", homes: homes), "/Users/meet/x", "a longer name is another folder")
        XCTAssertEqual(DisplayPath.tilde("/opt/x", homes: homes), "/opt/x")
        XCTAssertEqual(DisplayPath.tilde("/private/tmp/h/a", homes: ["/tmp/h", "/private/tmp/h"]), "~/a", "either spelling")
    }

    func testInsideALineOnlyWhereAPathStarts() {
        let homes = ["/Users/me"]
        XCTAssertEqual(DisplayPath.tildeIn("/workspace = /Users/me/projects/a", homes: homes), "/workspace = ~/projects/a")
        XCTAssertEqual(DisplayPath.tildeIn("A new empty folder /Users/me/w/try-x (not one of yours)", homes: homes),
                       "A new empty folder ~/w/try-x (not one of yours)")
        XCTAssertEqual(DisplayPath.tildeIn("/x/Users/me/a and /Users/meet/b", homes: homes), "/x/Users/me/a and /Users/meet/b")
        XCTAssertEqual(DisplayPath.tildeIn("home is /Users/me.", homes: homes), "home is /Users/me.", "a sentence's full stop is not a path")
        XCTAssertEqual(DisplayPath.tildeIn("(/Users/me) and '/Users/me/a'", homes: homes), "(~) and '~/a'")
    }

    func testTheSeamCountsOnlyInAGuardedRun() {
        let real = TestSafety.realHome.standardizedFileURL.path
        XCTAssertEqual(DisplayPath.homes(["DOZ_TEST_HOME": "/tmp/617-shots-home"]).first, real, "not guarded: the real home")
        let guarded = DisplayPath.homes(["DOZ_TEST_HOME": "/tmp/617-shots-home", "DOZ_TEST_GUARD": "1"])
        XCTAssertEqual(guarded.first, "/tmp/617-shots-home")
        XCTAssertTrue(guarded.contains("/private/tmp/617-shots-home"), "and its resolved spelling")
        XCTAssertEqual(DisplayPath.homes(["DOZ_TEST_HOME": "relative", "DOZ_TEST_GUARD": "1"]).first, real, "only an absolute path")
        XCTAssertEqual(DisplayPath.homes([:]).first, real)
    }
}
