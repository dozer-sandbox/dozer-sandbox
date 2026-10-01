import Foundation
import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost

/// 599c — Quick add / `doz new` without a VM: the name and the workspace it picks (from the settings,
/// past collisions with sandboxes and with folders that are not empty), a given name, isolated, and the
/// prerequisites one click cannot decide (the agent's account, an out-of-date image).
final class QuickAddTests: XCTestCase {
    private var projects: String!

    override func setUpWithError() throws {
        projects = "/private/tmp/dzqa-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: projects)
    }

    func settings(image: String? = nil, extra: String = "") -> DozerSettings {
        DozerSettings(text: "[defaults]\nprojects_dir = \"\(projects!)\"\n" + (image.map { "image = \"\($0)\"\n" } ?? "") + extra)
    }

    func testTheDefaults_nameAndFolder() throws {
        var p = try QuickAdd.plan(image: nil, name: nil, isolated: false, taken: [], settings: settings(image: "claude-code"))
        XCTAssertEqual(p.name, "claude-sandbox")
        XCTAssertEqual(p.image, "claude-code")
        XCTAssertEqual(p.workspace, projects + "/claude-sandbox")
        XCTAssertEqual(p.projectsDir, projects)
        XCTAssertNil(p.requirement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projects + "/claude-sandbox"), "a plan makes nothing")
        // defaults.image unset: lab, the setting's default.
        p = try QuickAdd.plan(image: nil, name: nil, isolated: false, taken: [], settings: settings())
        XCTAssertEqual(p.name, "lab-sandbox")
        // --image wins over the setting; a base × agent image names its own sandbox.
        p = try QuickAdd.plan(image: "pi", name: nil, isolated: false, taken: [], settings: settings(image: "claude-code"))
        XCTAssertEqual(p.name, "pi-sandbox")
        p = try QuickAdd.plan(image: "python-claude-code", name: nil, isolated: false, taken: [], settings: settings())
        XCTAssertEqual(p.name, "python-claude-sandbox")
        XCTAssertEqual(p.workspace, projects + "/python-claude-sandbox")
    }

    func testCollisions_aSandboxOrAFolderWithSomethingInIt() throws {
        let s = settings(image: "claude-code")
        // A sandbox has the name: -2; both: -3.
        XCTAssertEqual(try QuickAdd.plan(image: nil, name: nil, isolated: false, taken: ["claude-sandbox"], settings: s).name, "claude-sandbox-2")
        XCTAssertEqual(try QuickAdd.plan(image: nil, name: nil, isolated: false, taken: ["claude-sandbox", "claude-sandbox-2"], settings: s).name,
                       "claude-sandbox-3")
        // A folder there with something in it is someone's: skipped. An EMPTY one is free (it becomes the workspace).
        try FileManager.default.createDirectory(atPath: projects + "/claude-sandbox", withIntermediateDirectories: true)
        XCTAssertEqual(try QuickAdd.plan(image: nil, name: nil, isolated: false, taken: [], settings: s).name, "claude-sandbox")
        try Data("x".utf8).write(to: URL(fileURLWithPath: projects + "/claude-sandbox/README"))
        let p = try QuickAdd.plan(image: nil, name: nil, isolated: false, taken: [], settings: s)
        XCTAssertEqual(p.name, "claude-sandbox-2")
        XCTAssertEqual(p.workspace, projects + "/claude-sandbox-2")
    }

    func testAGivenNameAndIsolated() throws {
        let s = settings(image: "lab")
        var p = try QuickAdd.plan(image: nil, name: "my-box", isolated: false, taken: ["lab-sandbox"], settings: s)
        XCTAssertEqual(p.name, "my-box")
        XCTAssertEqual(p.workspace, projects + "/my-box")
        p = try QuickAdd.plan(image: nil, name: nil, isolated: true, taken: [], settings: s)
        XCTAssertNil(p.workspace, "isolated: nothing shared")
        XCTAssertEqual(p.line(), "lab-sandbox · lab · isolated")
        XCTAssertThrowsError(try QuickAdd.plan(image: nil, name: "lab-sandbox", isolated: false, taken: ["lab-sandbox"], settings: s)) { e in
            XCTAssertEqual((e as? HostError)?.code, .exists)
            XCTAssertTrue((e as? HostError)?.message.contains("doz up lab-sandbox") == true)
        }
        for bad in ["My Box", "-x", "", String(repeating: "a", count: 41)] {
            XCTAssertThrowsError(try QuickAdd.plan(image: nil, name: bad, isolated: false, taken: [], settings: s), bad)
        }
    }

    func testTheLine() {
        let p = QuickAddPlan(name: "claude-sandbox-2", image: "claude-code", workspace: "/Users/me/Developer/dozer-sandbox-projects/claude-sandbox-2",
                             projectsDir: "/Users/me/Developer/dozer-sandbox-projects")
        XCTAssertEqual(p.line(home: "/Users/me"), "claude-sandbox-2 · claude-code · ~/Developer/dozer-sandbox-projects/claude-sandbox-2")
        XCTAssertEqual(p.line(home: "/Users/other"), "claude-sandbox-2 · claude-code · /Users/me/Developer/dozer-sandbox-projects/claude-sandbox-2")
    }

    /// What one click cannot decide: the New Sandbox form opens with it said (the CLI asks, as create does).
    func testPrerequisiteFallbacks() {
        let none: [String: AccountKind] = ["mac": .mac]
        // pi with no API-key account (default none, or the Mac login): the account.
        var r = QuickAdd.requirement(image: "pi", network: nil, defaultAccount: "none", accountKinds: none, outOfDate: nil)
        XCTAssertEqual(r?.kind, "account")
        XCTAssertTrue(r?.text.contains("pi needs an Anthropic API key") == true, r?.text ?? "")
        r = QuickAdd.requirement(image: "pi", network: nil, defaultAccount: "mac", accountKinds: none, outOfDate: nil)
        XCTAssertEqual(r?.kind, "account")
        // pi with an API key as the default: fine. With nat/none networking no account applies at all.
        XCTAssertNil(QuickAdd.requirement(image: "pi", network: nil, defaultAccount: "work", accountKinds: ["mac": .mac, "work": .apiKey], outOfDate: nil))
        XCTAssertNil(QuickAdd.requirement(image: "pi", network: "nat", defaultAccount: "none", accountKinds: none, outOfDate: nil))
        // Claude Code may start with none, or the Mac login; lab has no agent.
        XCTAssertNil(QuickAdd.requirement(image: "claude-code", network: nil, defaultAccount: "none", accountKinds: none, outOfDate: nil))
        XCTAssertNil(QuickAdd.requirement(image: "claude-code", network: nil, defaultAccount: "mac", accountKinds: none, outOfDate: nil))
        XCTAssertNil(QuickAdd.requirement(image: "lab", network: nil, defaultAccount: "none", accountKinds: [:], outOfDate: nil))
        // An out-of-date image: use it or rebuild — a choice the form offers.
        r = QuickAdd.requirement(image: "claude-code", network: nil, defaultAccount: "mac", accountKinds: none,
                                 outOfDate: "an older recipe (missing: tmux) — rebuild when ready: doz image bake claude-code")
        XCTAssertEqual(r?.kind, "image")
        XCTAssertEqual(r?.text, "the claude-code image is out of date: an older recipe (missing: tmux) — use it as it is, or rebuild it first")
        // The account comes first (it blocks; the image is a choice).
        r = QuickAdd.requirement(image: "pi", network: nil, defaultAccount: "none", accountKinds: none, outOfDate: "older")
        XCTAssertEqual(r?.kind, "account")
        // The image's network setting decides whether an account applies.
        let s = settings(extra: "[images.pi]\nnetwork = \"none\"\n")
        XCTAssertEqual(QuickAdd.network(image: "pi", settings: s), "none")
        XCTAssertNil(QuickAdd.network(image: "lab", settings: s), "no agent: no account question")
    }

    /// `doz new` is a top-level command that clashes with nothing.
    func testDozNewIsACommand() throws {
        let names = DozerCommand.configuration.subcommands.map { $0._commandName }
        XCTAssertEqual(names.filter { $0 == "new" }.count, 1)
        let aliases = DozerCommand.configuration.subcommands.flatMap { $0.configuration.aliases }
        XCTAssertFalse(aliases.contains("new"))
        let n = try New.parse(["--image", "pi", "--name", "x1", "--isolated", "-d"])
        XCTAssertEqual(n.image, "pi")
        XCTAssertEqual(n.name, "x1")
        XCTAssertTrue(n.isolated && n.detach)
    }
}
