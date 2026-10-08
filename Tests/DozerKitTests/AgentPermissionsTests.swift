import Foundation
import XCTest
@testable import DozerKit

/// 597: the permission catalogue, presets per base, and a policy that stores permissions by name.
final class AgentPermissionsTests: XCTestCase {
    override func tearDown() { AgentPermissions.addedForTests = [:] }

    func testTheCatalogueSaysWhatTheAgentMayDoInPlainWords() {
        let ids = AgentPermissions.all.map(\.id)
        XCTAssertEqual(ids.first, "model")
        XCTAssertEqual(Set(ids).count, ids.count, "unique ids")
        for id in ["model", "sign-in", "update", "install:system", "install:node", "install:python", "install:go", "install:rust",
                   "install:java", "install:ruby", "install:dotnet", "github", "error-reports", "web"] {
            XCTAssertTrue(AgentPermissions.isValid(id), id)
        }
        XCTAssertEqual(AgentPermissions.permission("model")?.title, "Talk to its AI model")
        XCTAssertTrue(AgentPermissions.permission("model")!.locked)
        XCTAssertEqual(AgentPermissions.all.filter(\.locked).map(\.id), ["model"])
        XCTAssertNotNil(AgentPermissions.permission("web")?.warning, "the web warns before it is switched on")
        XCTAssertEqual(AgentPermissions.all.filter { $0.group == "install" }.count, AgentPermissions.ecosystems.count)
        for p in AgentPermissions.all {
            XCTAssertFalse(p.summary.isEmpty)
            XCTAssertFalse(p.phrase.isEmpty)
            // 599d: "Push to GitHub" adds no host — it lifts read-only on the hosts "Use GitHub as you" has.
            XCTAssertFalse(p.hosts.isEmpty && p.id != AgentPermissions.gitHubPush, p.id)
        }
    }

    func testPresetsAreCombinationsOfPermissionsForTheBase() {
        XCTAssertEqual(AgentPermissions.preset("locked", base: "python"), ["model"])
        XCTAssertEqual(AgentPermissions.preset("agent", base: "python"), ["model", "update", "install:system", "install:python", "github", "error-reports"])
        XCTAssertEqual(AgentPermissions.preset("standard", base: "go"), ["model", "update", "install:system", "install:go", "github", "error-reports"])
        XCTAssertEqual(AgentPermissions.preset("agent", base: nil), ["model", "update", "install:system", "github", "error-reports"],
                       "a Dockerfile's: system packages only")
        XCTAssertEqual(AgentPermissions.preset("agent", base: "debian"), ["model", "update", "install:system", "github", "error-reports"])
        // 599d: Open is everything but the user's GitHub login. 599i: and an agent's own model permission (Codex's).
        XCTAssertEqual(AgentPermissions.preset("open", base: nil), AgentPermissions.all.map(\.id).filter { !$0.hasPrefix("github:") && $0 != "model:openai" })
        XCTAssertNil(AgentPermissions.preset("bake", base: nil), "bake stays a preset of rules")
        XCTAssertEqual(AgentPermissions.presetName(["model"], base: "go"), "locked")
        XCTAssertEqual(AgentPermissions.presetName(AgentPermissions.preset("agent", base: "go")!.reversed(), base: "go"), "agent")
        XCTAssertNil(AgentPermissions.presetName(["model", "web"], base: "go"), "Custom")
        XCTAssertNil(AgentPermissions.presetName(AgentPermissions.preset("agent", base: "go")!, base: "python"), "Standard differs per base")
        XCTAssertEqual(AgentPermissions.normalized(["web", "nope", "update"]), ["model", "update", "web"], "canonical, model forced, unknown dropped")
    }

    func testClaudeCodesOwnHostsBelongToItsPermissionsAndKeepWorking() {
        let p = NetworkPolicy.permissions(AgentPermissions.preset("agent", base: "node")!, preset: "agent")
        for host in ["api.anthropic.com", "statsig.anthropic.com", "downloads.claude.ai", "http-intake.logs.us5.datadoghq.com",
                     "browser-intake-us5-datadoghq.com", "github.com", "raw.githubusercontent.com", "codeload.github.com",
                     "objects.githubusercontent.com", "pi.dev", "registry.npmjs.org", "deb.debian.org"] {
            XCTAssertEqual(p.evaluateConnection(host: host, port: 443).kind, .allow, host)
        }
        XCTAssertEqual(AgentPermissions.permission(forHost: "downloads.claude.ai")?.id, "update")
        XCTAssertEqual(AgentPermissions.permission(forHost: "http-intake.logs.us5.datadoghq.com")?.id, "error-reports")
        XCTAssertEqual(AgentPermissions.permission(forHost: "github.com")?.id, "github")
        XCTAssertEqual(AgentPermissions.permission(forHost: "pi.dev")?.id, "update")
        XCTAssertEqual(AgentPermissions.permission(forHost: "pypi.org")?.id, "install:python")
        XCTAssertEqual(AgentPermissions.permission(forHost: "registry.npmjs.org")?.id, "install:node", "npm is offered as Install, not Update")
        XCTAssertEqual(AgentPermissions.permission(forHost: "archive.ubuntu.com")?.id, "install:system", "a pattern")
        XCTAssertNil(AgentPermissions.permission(forHost: "api.example.com"))
        // Sign in, the web, other registries: refused in Standard.
        for host in ["claude.ai", "console.anthropic.com", "pypi.org", "example.com"] {
            XCTAssertEqual(p.evaluateConnection(host: host, port: 443).kind, .deny, host)
        }
        XCTAssertFalse(p.allowsName("example.com"))
        XCTAssertTrue(p.allowsName("downloads.claude.ai"))
    }

    func testUpdateItselfAllowsOnlyTheAgentsOwnNpmPackage() {
        let p = NetworkPolicy.permissions(["model", "update"])
        XCTAssertEqual(p.evaluateConnection(host: "registry.npmjs.org", port: 443).kind, .inspect, "the proxy reads the path")
        XCTAssertEqual(p.evaluate(host: "registry.npmjs.org", port: 443, method: "GET", path: "/@anthropic-ai/claude-code").action, .allow)
        XCTAssertEqual(p.evaluate(host: "registry.npmjs.org", port: 443, method: "GET", path: "/left-pad").action, .deny)
        let withNode = NetworkPolicy.permissions(["model", "update", "install:node"])
        XCTAssertEqual(withNode.evaluate(host: "registry.npmjs.org", port: 443, method: "GET", path: "/left-pad").action, .allow)
    }

    func testTheWebIsAnAllowingDefaultAndTheUsersRulesWin() {
        var p = NetworkPolicy.permissions(["model", "web"])
        XCTAssertEqual(p.effectiveDefault, .allow)
        XCTAssertEqual(p.evaluateConnection(host: "example.com", port: 443).kind, .allow)
        p.rules = [EgressRule(.deny, host: "evil.example", note: "site you denied")]
        XCTAssertEqual(p.evaluateConnection(host: "evil.example", port: 443).kind, .deny)
        var q = NetworkPolicy.permissions(["model", "github"])
        q.rules = [EgressRule(.deny, host: "github.com", note: "test")]
        XCTAssertEqual(q.evaluateConnection(host: "github.com", port: 443).kind, .deny, "a user's deny wins over a permission")
        q.rules = [EgressRule(host: "api.example.com", note: "site you allowed")]
        XCTAssertEqual(q.sites, ["api.example.com"])
        XCTAssertEqual(q.evaluateConnection(host: "api.example.com", port: 443).kind, .allow)
    }

    /// P5: a policy stores NAMES; the hosts come from the running build — so a later Dozer that adds a
    /// host to "Update itself" reaches this stored sandbox with no edit.
    func testStoredByNameSoANewHostReachesEverySandboxThatHasThePermission() throws {
        let stored = try JSONEncoder().encode(NetworkPolicy.permissions(AgentPermissions.preset("agent", base: "python")!, preset: "agent"))
        let json = String(decoding: stored, as: UTF8.self)
        XCTAssertTrue(json.contains("\"permissions\""))
        XCTAssertFalse(json.contains("downloads.claude.ai"), "no hosts stored")
        let loaded = try JSONDecoder().decode(NetworkPolicy.self, from: stored)
        XCTAssertEqual(loaded.evaluateConnection(host: "updates.claude.example", port: 443).kind, .deny)
        AgentPermissions.addedForTests["update"] = [PermissionHost("updates.claude.example")]
        XCTAssertEqual(loaded.evaluateConnection(host: "updates.claude.example", port: 443).kind, .allow, "the new build's host, no edit")
        let without = try JSONDecoder().decode(NetworkPolicy.self, from: JSONEncoder().encode(NetworkPolicy.permissions(["model"])))
        XCTAssertEqual(without.evaluateConnection(host: "updates.claude.example", port: 443).kind, .deny, "only where the permission is on")
    }

    func testAPre597PolicyDecodesAndIsEvaluatedAsItsRules() throws {
        let old = NetworkPolicy.agent
        XCTAssertNil(old.permissions)
        XCTAssertEqual(old.effectiveRules, old.rules)
        let back = try JSONDecoder().decode(NetworkPolicy.self, from: JSONEncoder().encode(old))
        XCTAssertNil(back.permissions)
        XCTAssertEqual(back.evaluateConnection(host: "api.anthropic.com", port: 443).kind, .allow)
    }

    func testRuleIdsAreStable() {
        let a = AgentPermissions.rules(for: ["model", "github"]).map(\.id)
        let b = AgentPermissions.rules(for: ["github", "model"]).map(\.id)
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set(a).count, a.count)
        XCTAssertTrue(AgentPermissions.rules(for: ["web"]).isEmpty, "the web is the default, not a rule")
    }
}
