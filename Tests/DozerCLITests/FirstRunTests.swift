import Foundation
import XCTest
@testable import DozerKit
@testable import DozerHost

/// 617 (owner: "allow them; otherwise it looks like it's broken"): a fresh try of every agent opens with no refusal.
/// What each agent calls on its own vendor's sites at a normal start is a hidden `vendor:<id>` added at create; its
/// self-update check and what a permission that is off would refuse are turned off by the agent's own switches. The VM
/// proof is probes/617-*/stageD/firstrun-netlog.sh (0 refusals for all five; example.com from the guest still counted).
final class FirstRunTests: XCTestCase {
    func kind(_ id: String) throws -> AgentKind { try XCTUnwrap(AgentKind(rawValue: id)) }

    func testEveryAgentGetsItsOwnSitesAtCreateAndTheyAreNeverASwitch() throws {
        XCTAssertEqual(AgentPermissions.agentPermissions(try kind("claude-code")), ["vendor:claude-code"])
        XCTAssertEqual(AgentPermissions.agentPermissions(try kind("pi")), ["vendor:pi"])
        XCTAssertEqual(AgentPermissions.agentPermissions(try kind("codex")), [AgentPermissions.openAIModel, "vendor:codex"])
        for id in ["vendor:claude-code", "vendor:pi", "vendor:codex"] {
            let p = try XCTUnwrap(AgentPermissions.permission(id))
            XCTAssertEqual(p.hidden, true)
            XCTAssertTrue(AgentPermissions.isAgentOwn(id))
            for preset in ["locked", "agent", "open"] { XCTAssertFalse(AgentPermissions.preset(preset, base: "node")!.contains(id), "\(id) in \(preset)") }
            XCTAssertTrue(p.hosts.allSatisfy { $0.reason?.isEmpty == false }, "\(id): every host says why")
        }
        // A preset is still that preset with them on (the checklist and the facts never list them).
        XCTAssertEqual(AgentPermissions.presetName(["model", "vendor:claude-code"], base: "node"), "locked")
        XCTAssertNil(AgentPermissions.permission(forHost: "files.openai.com"), "never suggested")
    }

    func testClaudeCodesStartUpIsAllowedByPathAndNothingMore() throws {
        let pol = NetworkPolicy.permissions(AgentPermissions.normalized(["model"] + AgentPermissions.agentPermissions(try kind("claude-code"))))
        XCTAssertEqual(pol.evaluate(host: "downloads.claude.ai", port: 443, method: "GET", path: "/model-catalog/v1/catalog.json").action, .allow)
        XCTAssertEqual(pol.evaluate(host: "downloads.claude.ai", port: 443, method: "GET", path: "/claude-code-releases/plugins/claude-plugins-official/latest").action, .allow)
        XCTAssertEqual(pol.evaluate(host: "downloads.claude.ai", port: 443, method: "GET", path: "/claude-code-releases/2.1.300/linux-arm64/claude").action, .deny,
                       "its update stays Update itself's")
        XCTAssertEqual(pol.evaluate(host: "raw.githubusercontent.com", port: 443, method: "GET", path: "/anthropics/claude-code/refs/heads/main/CHANGELOG.md").action, .allow)
        XCTAssertEqual(pol.evaluate(host: "raw.githubusercontent.com", port: 443, method: "GET", path: "/anthropics/claude-code/refs/heads/main/x.sh").action, .deny)
        XCTAssertEqual(pol.evaluateConnection(host: "github.com", port: 443).kind, .deny, "never GitHub whole")
        XCTAssertEqual(pol.evaluateConnection(host: "http-intake.logs.us5.datadoghq.com", port: 443).kind, .deny, "error reports stay off in Locked")
        XCTAssertEqual(pol.evaluateConnection(host: "example.com", port: 443).kind, .deny, "an unexpected host still counts")
    }

    func testCodexReadsOpenAIsPluginsAndCannotPush() throws {
        let pol = NetworkPolicy.permissions(AgentPermissions.normalized(["model"] + AgentPermissions.agentPermissions(try kind("codex"))))
        XCTAssertEqual(pol.evaluate(host: "github.com", port: 443, method: "GET", path: "/openai/plugins.git/info/refs").action, .allow)
        XCTAssertEqual(pol.evaluate(host: "github.com", port: 443, method: "POST", path: "/openai/plugins.git/git-upload-pack").action, .allow)
        XCTAssertEqual(pol.evaluate(host: "github.com", port: 443, method: "POST", path: "/openai/plugins.git/git-receive-pack").action, .deny, "read only")
        XCTAssertEqual(pol.evaluate(host: "github.com", port: 443, method: "GET", path: "/openai/other.git/info/refs").action, .deny)
        XCTAssertEqual(pol.evaluate(host: "raw.githubusercontent.com", port: 443, method: "GET", path: "/openai/codex/main/announcement_tip.toml").action, .allow)
        XCTAssertEqual(pol.evaluateConnection(host: "files.openai.com", port: 443).kind, .allow)
        XCTAssertEqual(pol.evaluateConnection(host: "api.github.com", port: 443).kind, .deny)
    }

    func testARecipesVendorHostsAreChecked() throws {
        var r = try XCTUnwrap(try kind("codex").recipe)
        XCTAssertNoThrow(try r.validate())
        r.network.vendor = [AgentRecipe.Host(host: "github.com", paths: nil, exactPaths: nil, reason: "its plugins")]
        XCTAssertThrowsError(try r.validate(), "GitHub whole is never a vendor host")
        r.network.vendor = [AgentRecipe.Host(host: "files.openai.com", paths: nil, exactPaths: nil, reason: nil)]
        XCTAssertThrowsError(try r.validate(), "a vendor host says why")
        r.network.vendor = nil
        r.network.offWithout = [AgentRecipe.OffWithout(permission: "telepathy", env: ["X": "1"], says: "x")]
        XCTAssertThrowsError(try r.validate(), "off_without names a permission")
    }

    func testTheAgentsOwnSwitchesFollowThePermissions() {
        let locked = ["model", "vendor:claude-code"]
        let e = HostCore.withRecipeEnvironment([:], imageSpec: "claude-code", permissions: locked)
        XCTAssertEqual(e["DISABLE_ERROR_REPORTING"], "1")
        XCTAssertEqual(e["DISABLE_TELEMETRY"], "1")
        let standard = AgentPermissions.preset("agent", base: "node")!
        XCTAssertNil(HostCore.withRecipeEnvironment([:], imageSpec: "claude-code", permissions: standard)["DISABLE_TELEMETRY"], "Standard unchanged")
        XCTAssertNil(HostCore.withRecipeEnvironment([:], imageSpec: "claude-code", permissions: nil)["DISABLE_TELEMETRY"], "a policy of rules: as before")
        XCTAssertEqual(HostCore.withRecipeEnvironment(["DISABLE_TELEMETRY": "0"], imageSpec: "claude-code", permissions: locked)["DISABLE_TELEMETRY"], "0",
                       "never over the caller's value")
        XCTAssertEqual(HostCore.withRecipeEnvironment([:], imageSpec: "pi", permissions: standard)["PI_SKIP_VERSION_CHECK"], "1", "pi's update check is off")
        XCTAssertEqual(HostCore.withRecipeEnvironment([:], imageSpec: "lab", permissions: locked), [:])
    }

    func testEverySessionIsTrueColourAndNoImageChanges() throws {
        XCTAssertEqual(HostCore.withTrueColour([:])["COLORTERM"], "truecolor")
        XCTAssertEqual(HostCore.withTrueColour(["COLORTERM": "24bit"])["COLORTERM"], "24bit", "never over the caller's")
        // Set at session open, never baked: no image spec names it (bake keys unchanged — RecipePinTests).
        for r in AgentRecipes.all {
            XCTAssertNil(r.launch.env["COLORTERM"], r.id)
            XCTAssertNil(r.state.env["COLORTERM"], r.id)
        }
    }

    func testThePlanSaysEachSiteAndWhatIsTurnedOff() {
        let pol = NetworkPolicy.permissions(["model", "vendor:claude-code"], preset: "locked")
        let reach = CreatePlanner.reach(.proxied(pol), policy: pol, workspace: nil, account: nil, keys: [], accounts: AccountsFile(),
                                        agent: AgentKind(rawValue: "claude-code"))
        let text = reach.map(\.text)
        XCTAssertTrue(text.contains { $0.hasPrefix("downloads.claude.ai — Claude Code reads Anthropic's list of models") }, "\(text)")
        XCTAssertTrue(text.contains { $0.hasPrefix("raw.githubusercontent.com (/anthropics/claude-code/refs/heads/main/CHANGELOG.md only) — ") })
        XCTAssertTrue(text.contains("Claude Code's error reports and usage data are turned off (Send error reports is off)"))
    }
}
