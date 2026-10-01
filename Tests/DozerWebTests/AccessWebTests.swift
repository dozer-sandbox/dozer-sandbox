import Foundation
import DozerKit
import DozerHost
import XCTest
@testable import DozerWeb

/// 599e: the Access routes' bodies — strict, the default GitHub key redacted — and the closed route table.
final class AccessWebTests: XCTestCase {
    func testTheWebBodiesAreStrictAndTheKeyRedacted() throws {
        let c = try WebAccessCheck.decode(Data(#"{"items":["github"],"choices":{"github":"read","githubSource":"gh","ssh":"on"}}"#.utf8))
        XCTAssertEqual(c.items, ["github"])
        XCTAssertEqual(c.choices?.dictionary, ["github": "read", "githubSource": "gh", "ssh": "on"])
        XCTAssertEqual(try WebAccessCheck.decode(Data("{}".utf8)).items, nil)
        for bad in [#"{"items":["root"]}"#, #"{"choices":{"github":"admin"}}"#, #"{"choices":{"web":"on"}}"#, #"{"extra":1}"#, #"{"items":[]}"#, "[]"] {
            XCTAssertThrowsError(try WebAccessCheck.decode(Data(bad.utf8)), bad)
        }
        let token = "github_pat_FAKE599eWEB" + String(repeating: "w", count: 30)
        let k = try WebAccessGitHubKey.decode(Data(#"{"secret":"\#(token)"}"#.utf8))
        XCTAssertEqual(k.secret, token)
        XCTAssertFalse("\(k)".contains(token) || String(reflecting: k).contains(token) || "\(Mirror(reflecting: k).children.map(\.value))".contains(token))
        XCTAssertEqual(k.scrub("refused " + token), "refused …")
        XCTAssertNil(try WebAccessGitHubKey.decode(Data(#"{"remove":true}"#.utf8)).secret)
        for bad in [#"{"secret":"short"}"#, #"{"secret":"two words here and more words"}"#, #"{"secret":"x","remove":true}"#, #"{"remove":false}"#] {
            XCTAssertThrowsError(try WebAccessGitHubKey.decode(Data(bad.utf8)), bad)
        }
        let o = try WebOnboardingConfig.decode(Data(#"{"defaultImage":"lab","account":"later","access":{"github":"push","ssh":"off"}}"#.utf8))
        XCTAssertEqual(o.access, WebAccessChoices(github: "push", ssh: "off"))
        XCTAssertNil(try WebOnboardingConfig.decode(Data(#"{"defaultImage":"lab","account":"later"}"#.utf8)).access)
        XCTAssertThrowsError(try WebOnboardingConfig.decode(Data(#"{"defaultImage":"lab","account":"later","access":{"github":"yes"}}"#.utf8)))
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/access"), .access)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/access/check"), .accessCheck)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/access/github-key"), .accessGithubKey)
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/access/github-key"))
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/access"))
    }
}
