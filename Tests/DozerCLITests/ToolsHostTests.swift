import Foundation
import XCTest
@testable import DozerKit
@testable import DozerHost

/// 599h: the tools layer in the host — the facts line says what is installed (folded into the GitHub line),
/// and Resources accounts for the Mac's tools cache.
final class ToolsHostTests: XCTestCase {
    private func facts(_ g: GitHubAccess.Mode?, ssh: Bool = false, tools: ToolsReport?) -> String {
        AgentPrompt.values(name: "n", image: "pi", cpus: 1, memoryMiB: 1024, workspace: "/w", network: .none, account: nil, version: "1",
                           hostname: "h", github: g, sshAgent: ssh, tools: tools)["github.facts"] ?? ""
    }
    private func result(_ id: String, _ state: String, _ detail: String = "") -> ToolResult {
        ToolResult(id: id, title: id, reason: "", state: state, detail: detail)
    }

    func testTheFactsLineSaysWhatIsInstalled() {
        let ok = ToolsReport(results: [result("gh", "installed"), result("ssh", "ok"), result("github-known-hosts", "installed")], first: true)
        var f = facts(.read, ssh: true, tools: ok)
        XCTAssertTrue(f.contains("`git` and `gh` (installed by Dozer) are signed in as the user on github.com, read-only"), f)
        XCTAssertTrue(f.contains("the ssh client and github.com's host keys are installed"), f)
        XCTAssertEqual(f.components(separatedBy: "GitHub:").count, 2, "ONE line")
        // gh not there: said, with why — git still works.
        let noGh = ToolsReport(results: [result("gh", "skipped", "refused the gh download: …")], first: true)
        f = facts(.push, tools: noGh)
        XCTAssertTrue(f.contains("`git` is signed in as the user on github.com (`gh` is not installed: refused the gh download: …), with push"), f)
        // Before any apply: as 599d said it.
        XCTAssertTrue(facts(.read, tools: nil).contains("`git` and `gh` are signed in as the user"))
        XCTAssertEqual(facts(nil, tools: ok), "", "nothing on: no line")
        XCTAssertTrue(facts(nil, ssh: true, tools: ok).contains("host keys are installed"))
    }

    func testResourcesAccountForTheToolsCache() {
        XCTAssertEqual(Resources.classify(["tools", "gh", ToolsLayer.ghVersion, "gh"], currentLabKey: nil), "cache:tools")
        XCTAssertEqual(Resources.classify(["access.json"], currentLabKey: nil), "store", "599e's record is the store's, not stray")
        XCTAssertTrue(Resources.isValidID("cache:tools"))
    }
}
