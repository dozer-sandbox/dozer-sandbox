import XCTest
@testable import DozerKit

/// 580 — policy matching: hosts, wildcards, CIDR, ports, method + path, DNS gating, presets.
final class NetworkPolicyTests: XCTestCase {
    func testDefaultDenyAndExactHost() {
        let p = NetworkPolicy(rules: [EgressRule(host: "api.example.com")])
        XCTAssertEqual(p.evaluateConnection(host: "api.example.com", port: 443).kind, .allow)
        XCTAssertEqual(p.evaluateConnection(host: "API.Example.com", port: 443).kind, .allow, "names are case-insensitive")
        XCTAssertEqual(p.evaluateConnection(host: "evil.com", port: 443).kind, .deny)
        XCTAssertEqual(p.evaluateConnection(host: "evil.com", port: 443).rule, "default deny")
        XCTAssertEqual(p.evaluateConnection(host: "x.api.example.com", port: 443).kind, .deny, "exact is exact")
    }

    func testWildcardMatchesSubdomainsOnly() {
        let r = EgressRule(host: "*.npmjs.org")
        XCTAssertTrue(r.matches(host: "registry.npmjs.org", port: 443))
        XCTAssertTrue(r.matches(host: "a.b.npmjs.org", port: 443))
        XCTAssertFalse(r.matches(host: "npmjs.org", port: 443), "the apex is not a subdomain")
        XCTAssertFalse(r.matches(host: "evilnpmjs.org", port: 443))
        XCTAssertTrue(EgressRule(host: "*").matches(host: "anything.test", port: 1))
    }

    func testCIDRMatchesIPLiteralsOnly() {
        let r = EgressRule(host: "10.0.0.0/8")
        XCTAssertTrue(r.matches(host: "10.1.2.3", port: 5432))
        XCTAssertFalse(r.matches(host: "11.0.0.1", port: 5432))
        XCTAssertFalse(r.matches(host: "ten.example", port: 5432))
        XCTAssertTrue(EgressRule(host: "1.2.3.4").matches(host: "1.2.3.4", port: 1))
        XCTAssertFalse(EgressRule(host: "1.2.3.4").matches(host: "1.2.3.5", port: 1))
        XCTAssertNil(IPv4CIDR("1.2.3/8"))
        XCTAssertNil(IPv4CIDR("1.2.3.4/33"))
        XCTAssertNil(IPv4CIDR.parseAddress("256.1.1.1"))
    }

    func testPortsAndOrder() {
        let p = NetworkPolicy(rules: [EgressRule(.deny, host: "db.internal", ports: [5432]), EgressRule(host: "db.internal")])
        XCTAssertEqual(p.evaluateConnection(host: "db.internal", port: 5432).kind, .deny, "first match wins")
        XCTAssertEqual(p.evaluateConnection(host: "db.internal", port: 443).kind, .allow)
    }

    func testMethodAndPathNarrowing() {
        // Read-only GitHub API: the connection must be inspected, each request judged.
        let p = NetworkPolicy(rules: [EgressRule(host: "api.github.com", methods: ["GET", "HEAD"], pathPrefixes: ["/repos/"])])
        XCTAssertEqual(p.evaluateConnection(host: "api.github.com", port: 443).kind, .inspect)
        XCTAssertEqual(p.evaluate(host: "api.github.com", port: 443, method: "GET", path: "/repos/a/b").action, .allow)
        XCTAssertEqual(p.evaluate(host: "api.github.com", port: 443, method: "get", path: "/repos/a/b").action, .allow)
        XCTAssertEqual(p.evaluate(host: "api.github.com", port: 443, method: "POST", path: "/repos/a/b").action, .deny)
        XCTAssertEqual(p.evaluate(host: "api.github.com", port: 443, method: "GET", path: "/user").action, .deny)
        XCTAssertEqual(p.evaluate(host: "api.github.com", port: 443).action, .deny, "unknown method/path never matches a conditioned rule")
        // A conditional deny under an allowing default also needs inspection.
        let open = NetworkPolicy(defaultAction: .allow, rules: [EgressRule(.deny, host: "api.github.com", methods: ["DELETE"])])
        XCTAssertEqual(open.evaluateConnection(host: "api.github.com", port: 443).kind, .inspect)
        XCTAssertEqual(open.evaluate(host: "api.github.com", port: 443, method: "DELETE", path: "/x").action, .deny)
        XCTAssertEqual(open.evaluate(host: "api.github.com", port: 443, method: "GET", path: "/x").action, .allow)
        XCTAssertEqual(open.evaluateConnection(host: "example.com", port: 443).kind, .allow)
    }

    func testDNSGating() {
        let p = NetworkPolicy(rules: [EgressRule(host: "registry.npmjs.org"), EgressRule(host: "db.internal", ports: [5432]),
                                      EgressRule(.deny, host: "*.blocked.test")])
        XCTAssertTrue(p.allowsName("registry.npmjs.org"))
        XCTAssertTrue(p.allowsName("db.internal"), "allowed on SOME port → resolves")
        XCTAssertFalse(p.allowsName("example.com"))
        XCTAssertFalse(p.allowsName("a.blocked.test"))
        XCTAssertTrue(NetworkPolicy.open.allowsName("anything.test"))
        XCTAssertFalse(NetworkPolicy.locked.allowsName("registry.npmjs.org"))
    }

    func testPresets() {
        XCTAssertEqual(NetworkPolicy.bake.evaluateConnection(host: "registry.npmjs.org", port: 443).kind, .allow)
        XCTAssertEqual(NetworkPolicy.bake.evaluateConnection(host: "deb.debian.org", port: 80).kind, .allow)
        XCTAssertEqual(NetworkPolicy.bake.evaluateConnection(host: "dl-cdn.alpinelinux.org", port: 443).kind, .allow)
        XCTAssertEqual(NetworkPolicy.bake.evaluateConnection(host: "api.anthropic.com", port: 443).kind, .deny, "a bake reaches registries only")
        XCTAssertEqual(NetworkPolicy.bake.evaluateConnection(host: "example.com", port: 443).kind, .deny)
        XCTAssertEqual(NetworkPolicy.agent.evaluateConnection(host: "api.anthropic.com", port: 443).kind, .allow)
        XCTAssertEqual(NetworkPolicy.agent.evaluateConnection(host: "registry.npmjs.org", port: 443).kind, .allow)
        XCTAssertEqual(NetworkPolicy.agent.evaluateConnection(host: "example.com", port: 443).kind, .deny)
        XCTAssertEqual(NetworkPolicy.locked.evaluateConnection(host: "registry.npmjs.org", port: 443).kind, .deny)
        XCTAssertEqual(NetworkPolicy.open.evaluateConnection(host: "example.com", port: 22).kind, .allow)
        XCTAssertEqual(Set(NetworkPolicy.presets.keys), ["locked", "bake", "agent", "open"])
    }

    /// 594 (owner: "there are some legit requests that should be allowed"): what Claude Code reaches on
    /// its own — its updates, its two US5 Datadog intakes (exact hosts, never the domain), GitHub.
    func testTheAgentPresetAllowsWhatClaudeCodeItselfReaches() {
        let agent = NetworkPolicy.agent
        for host in ["downloads.claude.ai", "http-intake.logs.us5.datadoghq.com", "browser-intake-us5-datadoghq.com", "pi.dev",
                     "github.com", "raw.githubusercontent.com", "codeload.github.com", "objects.githubusercontent.com"] {
            XCTAssertEqual(agent.evaluateConnection(host: host, port: 443).kind, .allow, host)
            XCTAssertEqual(agent.evaluateConnection(host: host, port: 22).kind, .deny, "\(host): HTTPS only")
            XCTAssertEqual(NetworkPolicy.bake.evaluateConnection(host: host, port: 443).kind, .deny, "a bake needs no \(host)")
        }
        for host in ["datadoghq.com", "api.datadoghq.com", "http-intake.logs.datadoghq.com", "http-intake.logs.datadoghq.eu",
                     "evil.us5.datadoghq.com", "api.github.com", "gist.githubusercontent.com", "claude.ai.example.com"] {
            XCTAssertEqual(agent.evaluateConnection(host: host, port: 443).kind, .deny, host)
        }
        XCTAssertEqual(agent.rules.filter { $0.host == "github.com" }.map(\.note), ["GitHub (git, Claude Code plugins)"])
        XCTAssertEqual(agent.rules.filter { $0.host.contains("datadoghq") }.map(\.note), ["Claude Code error reporting", "Claude Code error reporting"])
        XCTAssertEqual(agent.rules.first { $0.host == "downloads.claude.ai" }?.note, "Claude Code updates")
        // 594: pi's own host; never api.github.com (pi's tools are baked: fd, rg).
        XCTAssertEqual(agent.rules.first { $0.host == "pi.dev" }?.note, "pi updates")
        XCTAssertEqual(agent.evaluateConnection(host: "api.github.com", port: 443).kind, .deny)
        XCTAssertEqual(agent.rules.count, 5 + 4 + 4 + 7)
    }

    func testAllowThisHost() {
        var p = NetworkPolicy.agent
        XCTAssertEqual(p.evaluateConnection(host: "example.com", port: 443).kind, .deny)
        p.allow(host: "example.com")
        XCTAssertEqual(p.evaluateConnection(host: "example.com", port: 443).kind, .allow)
        XCTAssertNil(p.preset, "an edited preset is no longer the preset")
        let n = p.rules.count
        p.allow(host: "example.com")
        XCTAssertEqual(p.rules.count, n, "idempotent")
        var d = NetworkPolicy(rules: [EgressRule(.deny, host: "x.test")])
        d.allow(host: "x.test")
        XCTAssertEqual(d.evaluateConnection(host: "x.test", port: 443).kind, .allow, "an explicit deny is replaced")
    }

    func testSpecNetworkModeAndCodable() throws {
        let root = URL(fileURLWithPath: "/tmp/x")
        var s = SandboxSpec(name: "n", storeRoot: root, network: .proxied(.agent))
        XCTAssertTrue(s.isProxied)
        XCTAssertFalse(s.networking, "a proxied sandbox has no NIC")
        XCTAssertNoThrow(try s.validate())
        s.network = .nat
        XCTAssertTrue(s.networking)
        // An older persisted spec (no networkMode) keeps meaning what it meant.
        let legacy = SandboxSpec(name: "n", storeRoot: root)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        json["networkMode"] = nil
        let decoded = try JSONDecoder().decode(SandboxSpec.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.network, .nat)
        let p = SandboxSpec(name: "n", storeRoot: root, network: .proxied(.bake))
        XCTAssertEqual(try JSONDecoder().decode(SandboxSpec.self, from: JSONEncoder().encode(p)).network, .proxied(.bake))
        var bad = p
        bad.networking = true
        XCTAssertThrowsError(try bad.validate())
    }
}
