import Foundation
import XCTest
@testable import DozerHost

/// A program the guest does not have, said plainly (owner, after `doz exec rules-demo -- sudo cat …`
/// printed the guest agent's error wrapped three deep).
final class MissingProgramTests: XCTestCase {
    /// What the guest agent said, verbatim, from the demo.
    let raw = #"failed to start process (cause: "internalError: "startProcess: failed to start process: internalError: "vmexec error: internalError: "failed to find target executable sudo"""")"#

    func testSudoAsRootSaysItIsNotNeeded() {
        let s = HostCore.missingProgramMessage(raw, argv: ["sudo", "cat", "/workspace/x"], runsAs: nil)
        XCTAssertEqual(s, "`sudo` is not installed in this sandbox's image (not on its PATH) — and it is not needed: doz exec already runs as root unless --user names another user")
        XCTAssertFalse(s?.contains("internalError") ?? true)
    }

    func testSudoAsAnotherUserSaysHowToBeRoot() {
        let s = HostCore.missingProgramMessage(raw, argv: ["sudo", "true"], runsAs: "user")
        XCTAssertEqual(s, "`sudo` is not installed in this sandbox's image (not on its PATH) — doz exec runs this sandbox's commands as user; --user root runs one as root")
    }

    func testAnyOtherProgram() {
        let other = raw.replacingOccurrences(of: "executable sudo", with: "executable rg")
        XCTAssertEqual(HostCore.missingProgramMessage(other, argv: ["rg", "x"], runsAs: nil),
                       "`rg` is not installed in this sandbox's image (not on its PATH)")
    }

    func testAPathThatDoesNotExist() {
        let other = raw.replacingOccurrences(of: "executable sudo", with: "executable /opt/tool/bin/x")
        XCTAssertEqual(HostCore.missingProgramMessage(other, argv: ["/opt/tool/bin/x"], runsAs: nil),
                       "`/opt/tool/bin/x` does not exist in this sandbox (or is not a program it can run)")
    }

    func testNoReportedNameFallsBackToTheCommand() {
        XCTAssertEqual(HostCore.missingProgramMessage("vmexec error: failed to find target executable", argv: ["fdfind"], runsAs: nil),
                       "`fdfind` is not installed in this sandbox's image (not on its PATH)")
    }

    func testOtherErrorsPassThrough() {
        XCTAssertNil(HostCore.missingProgramMessage("failed to start process (cause: \"permission denied\")", argv: ["x"], runsAs: nil))
        XCTAssertNil(HostCore.missingProgramMessage(HostError(.failed, "timed out"), argv: ["x"], runsAs: nil))
    }

    func testRunWording() {
        XCTAssertEqual(HostCore.missingProgram("sudo", runsAs: nil, command: "doz run"),
                       "`sudo` is not installed in this sandbox's image (not on its PATH) — and it is not needed: doz run already runs as root unless --user names another user")
    }
}
