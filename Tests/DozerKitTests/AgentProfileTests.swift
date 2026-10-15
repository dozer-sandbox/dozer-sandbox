import Foundation
import XCTest
@testable import DozerKit

/// 617 (owner: "profile all the recipes by running them and recording their network requests and then make a
/// determination"): every recipe's committed network profile (`profiles/AGENT.json`, written by `make profile-agents`)
/// has a determination for EVERY endpoint it saw, and the recipe's permissions agree with each one under a fresh try's
/// policy (Locked + the agent's own permissions): allow / allow-path → allowed (allow-path: by its path only),
/// off-by-setting → refused and its setting is one the recipe sets, refuse → refused QUIETLY (never counted). A new
/// endpoint (null) fails here until a person decides it — the profiler never allows anything.
final class AgentProfileTests: XCTestCase {
    struct Profile: Decodable {
        var agent: String
        var version: String
        var profiled: String
        var how: String
        var endpoints: [Endpoint]
    }
    struct Endpoint: Decodable {
        var host: String
        var method: String
        var path: String?
        var determination: String?
        var reason: String?
        var setting: String?
        var seen: Bool?
    }

    static func profiles() throws -> [Profile] {
        let dir = AgentRecipeTests.packageRoot.appendingPathComponent("profiles")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") && $0 != "currency.json" }.sorted()
        return try files.map { try JSONDecoder().decode(Profile.self, from: Data(contentsOf: dir.appendingPathComponent($0))) }
    }

    /// The path a profile's pattern stands for (an id or a version replaced by a sample).
    static func sample(_ p: String?) -> String {
        (p ?? "/").replacingOccurrences(of: "{version}", with: "1.2.3").replacingOccurrences(of: "{id}", with: "0123456789abcdef0123")
            .replacingOccurrences(of: "{model}", with: "a-model")
    }

    func testEveryRecipeHasAProfileAndEveryEndpointADetermination() throws {
        let profiles = try Self.profiles()
        XCTAssertEqual(Set(profiles.map(\.agent)), Set(AgentRecipes.all.map(\.id)), "every recipe is profiled (make profile-agents)")
        for p in profiles {
            XCTAssertFalse(p.version.isEmpty, p.agent)
            XCTAssertNotNil(ISO8601DateFormatter().date(from: p.profiled + "T00:00:00Z"), "\(p.agent): profiled date")
            XCTAssertFalse(p.how.isEmpty, "\(p.agent): how it was profiled")
            for e in p.endpoints {
                let what = "\(p.agent): \(e.method) \(e.host)\(e.path ?? "")"
                XCTAssertTrue(["allow", "allow-path", "off-by-setting", "refuse"].contains(e.determination ?? ""), "\(what) has no determination — decide it")
                XCTAssertFalse((e.reason ?? "").isEmpty, "\(what): its reason")
            }
        }
    }

    func testTheRecipesAgreeWithEveryDetermination() throws {
        for p in try Self.profiles() {
            guard let agent = AgentKind(rawValue: p.agent), let r = agent.recipe else { XCTFail("no recipe \(p.agent)"); continue }
            let names = AgentPermissions.normalized((AgentPermissions.preset("locked", base: r.defaultBase, agent: agent) ?? [])
                                                    + AgentPermissions.agentPermissions(agent))
            let policy = NetworkPolicy.permissions(names)
            let quiet = Set(AgentPermissions.quietHosts(names))
            for e in p.endpoints where e.seen != false {
                let what = "\(p.agent): \(e.method) \(e.host)\(e.path ?? "") (\(e.determination ?? "-"))"
                let connect = policy.evaluateConnection(host: e.host, port: 443).kind
                let request = e.method == "CONNECT" ? nil : policy.evaluate(host: e.host, port: 443, method: e.method, path: Self.sample(e.path)).action
                let allowed = connect != .deny && (request ?? .allow) == .allow
                switch e.determination {
                case "allow":
                    XCTAssertTrue(allowed, "\(what) must be allowed in a fresh try")
                case "allow-path":
                    XCTAssertTrue(allowed, "\(what) must be allowed in a fresh try")
                    XCTAssertEqual(policy.evaluate(host: e.host, port: 443, method: "GET", path: "/doz-profile-unlisted").action, .deny,
                                   "\(what): by its path only — the rest of the host stays refused")
                case "off-by-setting":
                    XCTAssertFalse(allowed, "\(what): refused when the setting is not honoured")
                    let set = (r.launch.env.keys.map { $0 }) + (r.launch.sessionEnv ?? [:]).keys + (r.network.offWithout ?? []).flatMap(\.env.keys)
                        + r.state.env.keys + (r.launch.firstRun ?? []).flatMap { $0.set.keys }
                    XCTAssertTrue(e.setting.map { set.contains($0) } ?? false, "\(what): its setting \(e.setting ?? "-") is one the recipe sets")
                case "refuse":
                    XCTAssertFalse(allowed, "\(what) must be refused")
                    XCTAssertTrue(quiet.contains(e.host), "\(what): a refusal at a normal first run is QUIET (the recipe's quiet list) — a fresh try shows none")
                default:
                    break   // the test above fails it
                }
            }
        }
    }
}
