import Foundation
import DozerKit
import XCTest
@testable import DozerHost

/// 597 — Agent Permissions in the host: edits by permission or site, the checklist and suggestions,
/// the default for new sandboxes, `--allow`, a pre-597 policy shown as permissions, the facts block.
final class PermissionsHostTests: XCTestCase {
    var root: URL!
    var store: DozerStore { DozerStore(root: root.appendingPathComponent("store")) }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/dzpm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("store"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    let standardPy = AgentPermissions.preset("agent", base: "python")!

    func testEditsByPermissionOrSite() throws {
        let p = NetworkPolicy.permissions(standardPy, preset: "agent")
        var e = try PermissionPolicy.edited(p, grant: ["web"], revoke: ["error-reports"], base: "python")
        XCTAssertEqual(e.permissions, AgentPermissions.normalized(standardPy + ["web"]).filter { $0 != "error-reports" })
        XCTAssertNil(e.preset, "Custom")
        XCTAssertTrue(e.rules.isEmpty)
        e = try PermissionPolicy.edited(e, grant: ["error-reports"], revoke: ["web"], base: "python")
        XCTAssertEqual(e.preset, "agent", "back to Standard")
        e = try PermissionPolicy.edited(e, grant: ["site:api.example.com"], revoke: [], base: "python")
        XCTAssertEqual(e.sites, ["api.example.com"])
        XCTAssertNil(e.preset, "a site makes it Custom")
        XCTAssertEqual(e.evaluateConnection(host: "api.example.com", port: 443).kind, .allow)
        e = try PermissionPolicy.edited(e, grant: [], revoke: ["site:api.example.com"], base: "python")
        XCTAssertEqual(e.evaluateConnection(host: "api.example.com", port: 443).kind, .deny)
        XCTAssertTrue(e.sites.isEmpty)
        let all = try PermissionPolicy.edited(p, grant: ["install"], revoke: [], base: "python")
        XCTAssertTrue(AgentPermissions.ecosystems.allSatisfy { all.permissions!.contains("install:" + $0.id) }, "install = every ecosystem")
        let none = try PermissionPolicy.edited(p, grant: [], revoke: ["install"], base: "python")
        XCTAssertFalse(none.permissions!.contains { $0.hasPrefix("install:") })
        XCTAssertThrowsError(try PermissionPolicy.edited(p, grant: [], revoke: ["model"], base: "python")) { e in
            XCTAssertTrue(HostError.from(e).message.contains("cannot be switched off"))
        }
        XCTAssertThrowsError(try PermissionPolicy.edited(p, grant: ["telepathy"], revoke: [], base: nil))
        XCTAssertThrowsError(try PermissionPolicy.edited(p, grant: ["site:not a host"], revoke: [], base: nil))
        XCTAssertThrowsError(try PermissionPolicy.edited(p, grant: ["site:localhost"], revoke: [], base: nil), "a dotted name")
    }

    func testAPresetEditUsesTheBaseAndBakeStaysRules() throws {
        var r = HostRequest(.netPolicy, name: "a")
        r.preset = "standard"
        let std = try HostCore.editedPolicy(.locked, r, base: "go")
        XCTAssertEqual(std.permissions, AgentPermissions.preset("agent", base: "go"))
        XCTAssertEqual(std.preset, "agent")
        r.preset = "open"
        XCTAssertEqual(try HostCore.editedPolicy(.locked, r, base: "go").effectiveDefault, .allow)
        r.preset = "bake"
        let bake = try HostCore.editedPolicy(std, r, base: "go")
        XCTAssertNil(bake.permissions)
        XCTAssertEqual(bake, NetworkPolicy.presets["bake"])
        var g = HostRequest(.netPolicy, name: "a")
        g.grant = ["install:rust"]
        g.allow = ["extra.example.com"]
        let both = try HostCore.editedPolicy(std, g, base: "go")
        XCTAssertTrue(both.permissions!.contains("install:rust"))
        XCTAssertEqual(both.evaluateConnection(host: "extra.example.com", port: 443).kind, .allow)
    }

    func testAPre597PolicyIsShownAsPermissionsAndConvertedOnItsFirstChange() throws {
        let old = NetworkPolicy.agent
        let (names, rest) = PermissionPolicy.inferred(old)
        XCTAssertTrue(names.contains("model"))
        XCTAssertTrue(names.contains("github"))
        XCTAssertTrue(names.contains("error-reports"))
        XCTAssertTrue(names.contains("sign-in"), "the old agent preset allowed sign-in")
        XCTAssertFalse(names.contains("web"))
        XCTAssertFalse(rest.contains { $0.host == "github.com" }, "covered hosts are not kept as rules")
        let conv = try PermissionPolicy.edited(old, grant: ["web"], revoke: [], base: nil)
        XCTAssertNotNil(conv.permissions)
        // What the old one allowed stays allowed.
        for r in old.rules where r.action == .allow && !r.hasHTTPConditions {
            let h = r.host.hasPrefix("*.") ? "x" + r.host.dropFirst(1) : r.host
            XCTAssertNotEqual(conv.evaluateConnection(host: h, port: r.ports?.first ?? 443).kind, .deny, r.host)
        }
        let rep = PermissionPolicy.report(name: "a", policy: old, base: nil, log: [])
        XCTAssertTrue(rep.inferred)
    }

    func testTheReportTurnsRefusalsIntoOneClickSuggestions() {
        let p = NetworkPolicy.permissions(AgentPermissions.preset("agent", base: "node")!, preset: "agent")
        let log = [
            ConnectionRecord(kind: .connect, host: "pypi.org", port: 443, verdict: .denied, rule: "default deny"),
            ConnectionRecord(kind: .connect, host: "files.pythonhosted.org", port: 443, verdict: .denied, rule: "default deny"),
            ConnectionRecord(kind: .connect, host: "pypi.org", port: 443, verdict: .denied, rule: "default deny"),
            ConnectionRecord(kind: .connect, host: "api.example.com", port: 443, verdict: .denied, rule: "default deny"),
            ConnectionRecord(kind: .connect, host: "github.com", port: 443, verdict: .allowed, rule: "permission: Use GitHub"),
        ]
        let r = PermissionPolicy.report(name: "a", policy: p, base: "node", log: log)
        XCTAssertEqual(r.preset, "agent")
        XCTAssertFalse(r.inferred)
        // 599i: an agent's own model permission ("Talk to OpenAI") is listed only where it is on.
        XCTAssertEqual(r.permissions.count, AgentPermissions.all.count - 1)
        XCTAssertNil(r.permissions.first { $0.id == AgentPermissions.openAIModel })
        XCTAssertEqual(r.permissions.first { $0.id == "install:node" }?.on, true)
        XCTAssertEqual(r.permissions.first { $0.id == "install:node" }?.standard, true)
        XCTAssertEqual(r.permissions.first { $0.id == "web" }?.on, false)
        XCTAssertTrue(r.permissions.first { $0.id == "update" }!.hosts.contains("registry.npmjs.org (the agent's own package)"))
        XCTAssertEqual(r.suggestions.count, 2)
        XCTAssertEqual(r.suggestions[0].grant, "install:python")
        XCTAssertEqual(r.suggestions[0].count, 3)
        XCTAssertEqual(Set(r.suggestions[0].hosts), ["pypi.org", "files.pythonhosted.org"])
        XCTAssertEqual(r.suggestions[0].what, "install Python packages (PyPI)")
        XCTAssertEqual(r.suggestions[1].grant, "site:api.example.com")
        XCTAssertNil(r.suggestions[1].permission)
        XCTAssertEqual(r.denied, ["api.example.com", "files.pythonhosted.org", "pypi.org"])
        // A permission that is on but a user's rule denied: no suggestion to switch it on.
        var q = p
        q.rules = [EgressRule(.deny, host: "github.com", note: "site you denied")]
        let r2 = PermissionPolicy.report(name: "a", policy: q, base: "node",
                                         log: [ConnectionRecord(kind: .connect, host: "github.com", port: 443, verdict: .denied, rule: "x")])
        XCTAssertTrue(r2.suggestions.isEmpty)
    }

    func testTheFactsListThePermissionsInPlainWords() {
        var p = NetworkPolicy.permissions(standardPy, preset: "agent")
        p.rules = [EgressRule(host: "api.example.com", note: "site you allowed")]
        let s = PermissionPolicy.facts(p, sandbox: "box")
        XCTAssertTrue(s.hasPrefix("You may talk to your AI model, update yourself, install system packages (apt/apk), install Python packages (PyPI)"), s)
        XCTAssertTrue(s.contains("Sites the user allowed: api.example.com."))
        XCTAssertTrue(s.contains("You may not sign in to Claude inside the sandbox"), s)
        XCTAssertTrue(s.contains("browse the web (any site)"))
        XCTAssertTrue(s.contains("`doz net allow box sign-in`"))
        XCTAssertTrue(s.contains("site:HOST"))
        let open = PermissionPolicy.facts(.permissions(AgentPermissions.all.map(\.id)), sandbox: "box")
        XCTAssertFalse(open.contains("You may not"))
    }

    func testNewSandboxesGetPermissionsFromTheFlagTheSettingOrTheForm() throws {
        // The default: Standard for the base.
        let (py, _) = try DozerImages.spec(name: "a1", options: CreateOptions(image: "python-claude-code"), store: store, environment: [:])
        XCTAssertEqual(py.network.policy?.permissions, standardPy)
        XCTAssertEqual(py.network.policy?.preset, "agent")
        // --network locked.
        let (lk, _) = try DozerImages.spec(name: "a2", options: CreateOptions(image: "go-claude-code", network: "locked"), store: store, environment: [:])
        XCTAssertEqual(lk.network.policy?.permissions, ["model"])
        // --allow words on top, and a site.
        var o = CreateOptions(image: "python-claude-code")
        o.allow = ["web", "-error-reports", "site:api.example.com"]
        let (al, _) = try DozerImages.spec(name: "a3", options: o, store: store, environment: [:])
        let alp = try XCTUnwrap(al.network.policy)
        XCTAssertTrue(alp.permissions!.contains("web"))
        XCTAssertFalse(alp.permissions!.contains("error-reports"))
        XCTAssertEqual(alp.sites, ["api.example.com"])
        XCTAssertNil(alp.preset)
        o.allow = ["telepathy"]
        XCTAssertThrowsError(try DozerImages.spec(name: "a4", options: o, store: store, environment: [:]))
        // The form: exactly these.
        var f = CreateOptions(image: "go-pi")
        f.permissions = ["github"]
        let (fm, _) = try DozerImages.spec(name: "a5", options: f, store: store, environment: [:])
        XCTAssertEqual(fm.network.policy?.permissions, ["model", "github"], "model forced on")
        // The setting.
        let xdg = root.appendingPathComponent("xdg")
        try FileManager.default.createDirectory(at: xdg.appendingPathComponent("dozer-sandbox"), withIntermediateDirectories: true)
        try "[defaults]\npermissions = \"+web,-github\"\n".write(to: xdg.appendingPathComponent("dozer-sandbox/doz.toml"), atomically: true, encoding: .utf8)
        let (st, _) = try DozerImages.spec(name: "a6", options: CreateOptions(image: "python-claude-code"), store: store,
                                            environment: ["XDG_CONFIG_HOME": xdg.path])
        let stp = try XCTUnwrap(st.network.policy?.permissions)
        XCTAssertTrue(stp.contains("web"))
        XCTAssertFalse(stp.contains("github"))
        XCTAssertTrue(stp.contains("install:python"))
        // The lab and a bake policy stay rules (596's registries).
        let (bk, _) = try DozerImages.spec(name: "a7", options: CreateOptions(image: "go", network: "bake"), store: store, environment: [:])
        XCTAssertNil(bk.network.policy?.permissions)
    }

    func testTheSettingIsCheckedAndTyped() throws {
        XCTAssertEqual(SettingType.permissionWords("standard"), ["standard"])
        XCTAssertEqual(SettingType.permissionWords("open"), ["open"])
        XCTAssertEqual(SettingType.permissionWords(" +web , -error-reports "), ["+web", "-error-reports"])
        XCTAssertEqual(SettingType.permissionWords("install:python"), ["install:python"])
        XCTAssertNil(SettingType.permissionWords("+telepathy"))
        XCTAssertNil(SettingType.permissionWords(""))
        let s = DozerSettings(text: nil)
        XCTAssertEqual(s.string(SettingKey.permissions), "standard")
        XCTAssertEqual(PermissionPolicy.names(from: ["locked", "+github"], base: "go"), ["model", "github"])
        XCTAssertEqual(PermissionPolicy.names(from: ["standard"], base: nil), AgentPermissions.preset("agent", base: nil))
    }
}

/// The live host: a change by permission applies at once and is stored by name; the checklist op.
extension AccountTests {
    func testPermissionEditsApplyLiveAndAreStoredByName() async throws {
        let c = await core()
        try await create(c, "pm")
        var r = HostRequest(.netPermissions, name: "pm")
        var m = await c.handle(r)
        XCTAssertNil(m.error)
        var rep = try XCTUnwrap(m.result).decode(PermissionReport.self)
        XCTAssertEqual(rep.preset, "agent")
        XCTAssertEqual(rep.base, "node")
        XCTAssertFalse(rep.inferred)
        XCTAssertTrue(HostOp.netPermissions.isReadOnly)
        var g = HostRequest(.netPolicy, name: "pm")
        g.grant = ["install:python", "site:api.example.com"]
        g.revoke = ["github"]
        m = await c.handle(g)
        XCTAssertNil(m.error)
        let pol = try await XCTUnwrapAsync(await c.effectiveNetworkPolicy(of: "pm"))
        XCTAssertEqual(pol.evaluateConnection(host: "pypi.org", port: 443).kind, .allow, "live, the next connection")
        XCTAssertEqual(pol.evaluateConnection(host: "api.example.com", port: 443).kind, .allow)
        XCTAssertEqual(pol.evaluateConnection(host: "github.com", port: 443).kind, .deny)
        XCTAssertEqual(pol.evaluateConnection(host: "downloads.claude.ai", port: 443).kind, .allow, "Claude Code's update host")
        XCTAssertEqual(pol.evaluateConnection(host: "http-intake.logs.us5.datadoghq.com", port: 443).kind, .allow)
        let kept = try await XCTUnwrapAsync(await c.config(of: "pm"))
        let cfg = String(decoding: try JSONEncoder().encode(kept), as: UTF8.self)
        XCTAssertTrue(cfg.contains("install:python"), "stored by name")
        XCTAssertFalse(cfg.contains("pypi.org"), "no hosts stored")
        r = HostRequest(.netPermissions, name: "pm")
        m = await c.handle(r)
        rep = try XCTUnwrap(m.result).decode(PermissionReport.self)
        XCTAssertNil(rep.preset, "Custom")
        XCTAssertEqual(rep.sites, ["api.example.com"])
        var bad = HostRequest(.netPolicy, name: "pm")
        bad.revoke = ["model"]
        m = await c.handle(bad)
        XCTAssertEqual(m.error?.code, .invalid)
    }
}
