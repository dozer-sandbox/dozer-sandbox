import Foundation
import XCTest
@testable import DozerKit
@testable import DozerCLI

/// 617: `doz try`'s and `doz search`'s second line. A tool installed from a pinned release download or a hash-locked
/// PyPI set is never looked up, so its line says the pin — never "not checked yet", which no check would ever change.
final class LatestLineTests: XCTestCase {
    func testAPinnedOnlyToolSaysItsPin() throws {
        let tau = try XCTUnwrap(AgentRecipes.recipe("tau"))
        XCTAssertTrue(AgentRecipe.pinnedOnlyKinds.contains(tau.install.kind))
        XCTAssertEqual(latestLine(nil, agent: "tau"),
                       "pinned \(tau.install.pinned.version) — Dozer installs exactly this release; a newer one comes with a Dozer update")
        XCTAssertEqual(latestLine(nil, agent: "grok"), "latest: not checked yet (the host checks hourly while it runs)", "a looked-up agent waits for its check")
        XCTAssertEqual(latestLine(nil), "latest: not checked yet (the host checks hourly while it runs)")
        let checked = latestLine(DirectoryIndex.Latest(version: "9.9.9", released: nil, freshness: "active", deprecated: nil), agent: "tau")
        XCTAssertTrue(checked.hasPrefix("latest 9.9.9"), "a measured latest wins: " + checked)
    }
}
