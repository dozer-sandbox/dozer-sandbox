import Foundation
import DozerKit
import DozerHost
import XCTest
@testable import DozerWeb

/// 597 — the permission actions: net-policy grant/revoke and New Sandbox's switches, decoded strictly.
final class WebPermissionsTests: XCTestCase {
    func decode(_ json: String) throws -> WebAction { try WebAction.decode(Data(json.utf8)) }

    func testGrantAndRevokeAreOneNetPolicyRequest() throws {
        let a = try decode(#"{"action":"net-policy","sandbox":"a","grant":["install:python","site:api.example.com"],"revoke":["error-reports"]}"#)
        guard case .netPolicy(let name, let e) = a else { return XCTFail("\(a)") }
        XCTAssertEqual(name, "a")
        XCTAssertEqual(e.grant, ["install:python", "site:api.example.com"])
        XCTAssertEqual(e.revoke, ["error-reports"])
        let r = a.hostRequest
        XCTAssertEqual(r.op, .netPolicy)
        XCTAssertEqual(r.grant, ["install:python", "site:api.example.com"])
        XCTAssertEqual(r.revoke, ["error-reports"])
        XCTAssertEqual(try decode(#"{"action":"net-policy","sandbox":"a","revoke":["install"]}"#).hostRequest.revoke, ["install"])
        for bad in [#"{"action":"net-policy","sandbox":"a","grant":["telepathy"]}"#,
                    #"{"action":"net-policy","sandbox":"a","grant":["site:not a host"]}"#,
                    #"{"action":"net-policy","sandbox":"a","grant":["web","web"]}"#,
                    #"{"action":"net-policy","sandbox":"a","grant":"web"}"#,
                    #"{"action":"net-policy","sandbox":"a","grant":[],"revoke":[]}"#] {
            XCTAssertThrowsError(try decode(bad), bad)
        }
        // The preview shows exactly what the host will do.
        let live = NetworkPolicy.permissions(AgentPermissions.preset("agent", base: "node")!, preset: "agent")
        let after = try HostCore.editedPolicy(live, r, base: "node")
        XCTAssertTrue(after.permissions!.contains("install:python"))
        XCTAssertFalse(after.permissions!.contains("error-reports"))
    }

    func testNewSandboxSwitchesAndSites() throws {
        let a = try decode(#"{"action":"create","sandbox":"n1","image":"python-claude-code","permissions":["model","update","install:python"],"sites":["site:api.example.com"]}"#)
        let o = try XCTUnwrap(a.hostRequest.create)
        XCTAssertEqual(o.permissions, ["model", "update", "install:python"])
        XCTAssertEqual(o.allow, ["site:api.example.com"])
        XCTAssertNil(try decode(#"{"action":"create","sandbox":"n1","image":"lab"}"#).hostRequest.create?.permissions, "absent: the default")
        XCTAssertThrowsError(try decode(#"{"action":"create","sandbox":"n1","image":"lab","permissions":["site:x.example.com"]}"#))
        XCTAssertThrowsError(try decode(#"{"action":"create","sandbox":"n1","image":"lab","sites":["web"]}"#))
    }

    func testTheBasesAnswerCarriesTheSwitchesAndStandardPerBase() {
        let rows = WebBases.permissionRows
        XCTAssertEqual(rows.map(\.id), AgentPermissions.all.map(\.id))
        XCTAssertTrue(rows.first { $0.id == "model" }!.locked)
        XCTAssertNotNil(rows.first { $0.id == "web" }!.warning)
        XCTAssertEqual(WebBases.standardByBase["python"], AgentPermissions.preset("agent", base: "python"))
        XCTAssertEqual(WebBases.standardByBase[""], AgentPermissions.preset("agent", base: nil))
    }
}
