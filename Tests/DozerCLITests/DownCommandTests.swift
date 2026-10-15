import Foundation
import XCTest
import ArgumentParser
@testable import DozerCLI
@testable import DozerHost

/// 617 (owner: "yes queue doz down"): `doz down` — hibernate by default, `--sleep`, `--shutdown` (asked) — is only a
/// choice among the existing lifecycle requests (no new host op), placed next to `up` in --help.
final class DownCommandTests: XCTestCase {
    func parse(_ a: [String]) throws -> Down {
        guard let d = try DozerCommand.parseAsRoot(["down"] + a) as? Down else { throw ValidationError("not down") }
        return d
    }

    func testDownChoosesAnExistingVerb() throws {
        XCTAssertEqual(try parse(["my-app"]).op, .hibernate, "the default: RAM returned, sessions kept")
        XCTAssertEqual(try parse(["my-app", "--sleep"]).op, .sleep)
        XCTAssertEqual(try parse(["my-app", "--shutdown"]).op, .shutdown)
        XCTAssertEqual(try parse(["my-app", "--shutdown", "-y"]).yes, true)
        XCTAssertThrowsError(try parse(["my-app", "--sleep", "--shutdown"]), "one of them")
        XCTAssertThrowsError(try parse([]), "a NAME")
    }

    func testItSitsNextToUp() {
        let names = DozerCommand.configuration.subcommands.map { $0._commandName }
        let up = names.firstIndex(of: "up"), down = names.firstIndex(of: "down")
        XCTAssertNotNil(down)
        XCTAssertEqual(down, up.map { $0 + 1 }, "after up in --help")
    }
}
