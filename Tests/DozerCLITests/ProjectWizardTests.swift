import Foundation
import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost
@testable import DozerWeb

/// 599f — the New Sandbox wizard and the project file, without a VM: every choice round-trips through the
/// file (render → the CLI's parser), `.yml` is read too and both spellings at once is an error, the shared
/// whole-project check, what is left to the settings, the diff, the create options `doz up` gives, and the
/// dashboard's open / preview / write (with the CLI's own parser installed, as `doz ui` does).
final class ProjectWizardTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: "/private/tmp/dzpw-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        WebProjectFiles.install { text, file in try DozerProject.parse(text, file: file) }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func everything() -> DozerProject {
        var p = DozerProject(name: "shop", image: "python-claude-code")
        p.cpus = 4
        p.memoryMiB = 3072
        p.network = "agent"
        p.permissions = ["+web", "-error-reports"]
        p.account = "work"
        p.github = "push"
        p.agentSudo = false
        p.agentPrompt = "The tests run with `make test`.\nBe brief."
        p.agentPromptMode = "replace"
        p.sessions = [.init(name: "claude", command: nil), .init(name: "server", command: ["npm", "run", "dev"])]
        p.settings = [SettingKey.clipboard: .string("off"), SettingKey.browserBridge: .string("off"), SettingKey.openFiles: .string("off"),
                      SettingKey.sshAgent: .string("on"), SettingKey.tmux: .bool(true)]
        return p
    }

    /// Everything the wizard sets is in the file and reads back the same — the CLI's parser and the page's form.
    func testEveryChoiceRoundTripsThroughTheFile() throws {
        let p = everything()
        let back = try DozerProject.parse(p.render())
        XCTAssertEqual(back, p)
        XCTAssertTrue(p.render().contains("permissions: \"+web,-error-reports\""))
        XCTAssertEqual(try WebProjectForm(p).project(), p, "the page's form carries the same choices")
        // An agent + base project stays agent + base.
        var q = DozerProject(name: "go1", image: "")
        q.agent = "pi"; q.base = "go"; q.image = q.chosenImage
        XCTAssertEqual(try DozerProject.parse(q.render()), q)
        // A list of permission words reads too; a preset alone too.
        XCTAssertEqual(try DozerProject.parse("name: a\nimage: claude-code\npermissions: [+web, -github]\n").permissions, ["+web", "-github"])
        XCTAssertEqual(try DozerProject.parse("name: a\nimage: claude-code\npermissions: locked\n").permissions, ["locked"])
        XCTAssertThrowsError(try DozerProject.parse("name: a\nimage: claude-code\npermissions: +teleport\n"))
    }

    /// doz_project.yml is read; both spellings in one folder is an error that says so.
    func testTheYmlSpellingAndBothFiles() throws {
        XCTAssertNil(try DozerProject.find(in: dir))
        try "name: viayml\nimage: lab\n".write(to: dir.appendingPathComponent("doz_project.yml"), atomically: true, encoding: .utf8)
        let u = try XCTUnwrap(try DozerProject.find(in: dir))
        XCTAssertEqual(u.lastPathComponent, "doz_project.yml")
        XCTAssertEqual(try DozerProject.load(u).name, "viayml")
        try "name: viayaml\nimage: lab\n".write(to: dir.appendingPathComponent("doz_project.yaml"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DozerProject.find(in: dir)) { e in
            let m = (e as? DozerProject.Invalid)?.message ?? ""
            XCTAssertTrue(m.contains("both doz_project.yaml and doz_project.yml"), m)
        }
        // The dashboard says the same, and opens nothing.
        let o = WebProject.open(WebProjectRequest(folder: dir.path), settings: DozerSettings(text: ""), store: "/tmp/fake-store")
        XCTAssertTrue(o.error?.contains("both doz_project.yaml and doz_project.yml") == true, o.error ?? "")
    }

    /// The one whole-project check (the parser, doz init and the wizard): permissions and GitHub need a network with permissions.
    func testTheSharedCheck() {
        var p = DozerProject(name: "x", image: "claude-code")
        XCTAssertNil(p.problem())
        p.permissions = ["+web"]
        XCTAssertNil(p.problem(effectiveNetwork: "agent"))
        XCTAssertTrue(p.problem(effectiveNetwork: "bake")?.contains("not bake") == true)
        p.network = "nat"
        XCTAssertTrue(p.problem()?.contains("not nat") == true, "the file's own network decides")
        p = DozerProject(name: "x", image: "lab")
        p.github = "read"
        XCTAssertTrue(p.problem(effectiveNetwork: "bake")?.contains("github: read needs a network with permissions") == true)
        p.github = "off"
        XCTAssertNil(p.problem(effectiveNetwork: "bake"))
        p.permissions = ["github:as-you"]
        XCTAssertNotNil(p.problem(effectiveNetwork: "agent"), "GitHub is the github key")
        XCTAssertThrowsError(try DozerProject.parse("name: a\nimage: lab\nnetwork: none\npermissions: standard\n"))
        // The network a project gets without one: the image's setting.
        XCTAssertEqual(DozerProject(name: "a", image: "lab").effectiveNetwork(settings: DozerSettings(text: "")), "bake")
        XCTAssertEqual(DozerProject(name: "a", image: "python-pi").effectiveNetwork(settings: DozerSettings(text: "")), "agent")
    }

    /// Pre-filled defaults are left to the settings (commented in the file); what was set on purpose stays.
    func testDefaultsStayWithTheSettings() {
        let s = DozerSettings(text: "")
        var p = DozerProject(name: "x", image: "claude-code")
        p.cpus = s.int(SettingKey.cpus)
        p.memoryMiB = UInt64(s.int(SettingKey.memory("claude-code")))
        p.network = "agent"
        p.permissions = ["standard"]
        p.account = "default"
        p.github = "off"
        p.agentSudo = true
        p.settings = [SettingKey.clipboard: .string("write"), SettingKey.tmux: .bool(false)]
        var q = p
        q.dropDefaults(settings: s, explicit: [])
        XCTAssertEqual(q, DozerProject(name: "x", image: "claude-code"), "every pre-filled default left out")
        q = p
        q.dropDefaults(settings: s, explicit: ["cpus", "clipboard"])
        XCTAssertEqual(q.cpus, p.cpus)
        XCTAssertEqual(q.settings, [SettingKey.clipboard: .string("write")])
        XCTAssertTrue(DozerProject(name: "x", image: "claude-code").render().contains("# cpus: 2"), "a default is commented")
    }

    /// `doz up` gives the project's permissions on Standard (a preset alone replaces it) and its GitHub.
    func testCreateOptions() {
        var p = everything()
        var o = p.createOptions(folder: dir, file: dir.appendingPathComponent(DozerProject.fileName))
        XCTAssertEqual(o.allow, ["standard", "+web", "-error-reports", "+github:as-you", "+github:push"])
        XCTAssertEqual(o.settings?[SettingKey.sshAgent], .string("on"))
        XCTAssertEqual(o.workspace, dir.path)
        p.permissions = ["locked"]
        p.github = nil
        o = p.createOptions(folder: dir, file: dir, settings: DozerSettings(text: ""))
        XCTAssertEqual(o.allow, ["locked"])
        // 599e: permissions without a github key keep the Access step's default (defaults.github).
        o = p.createOptions(folder: dir, file: dir, settings: DozerSettings(text: "[defaults]\ngithub = \"read\"\n"))
        XCTAssertEqual(o.allow, ["locked", "+github:as-you", "-github:push"])
        var q = DozerProject(name: "x", image: "claude-code")
        q.github = "read"
        q.dropDefaults(settings: DozerSettings(text: "[defaults]\ngithub = \"read\"\n"), explicit: [])
        XCTAssertNil(q.github, "the Access step's default is left to the setting")
    }

    func testTheDiff() {
        XCTAssertEqual(DozerProject.lineDiff(old: "a\nb\nc", new: "a\nB\nc\nd"), ["  a", "- b", "+ B", "  c", "+ d"])
        XCTAssertEqual(DozerProject.lineDiff(old: "same", new: "same"), ["  same"])
    }

    /// The dashboard: open (defaults, or the file's choices), preview (the exact file, read back), write (an
    /// existing file only by its digest), and the action that makes the sandbox as `doz up` would.
    func testOpenPreviewWrite() throws {
        let settings = DozerSettings(text: "[defaults]\nimage = \"claude-code\"\n")
        let folder = dir.appendingPathComponent("my-app").path
        var o = WebProject.open(WebProjectRequest(folder: folder), settings: settings, store: "/tmp/fake-store")
        XCTAssertNil(o.error)
        XCTAssertFalse(o.exists)
        XCTAssertEqual(o.form.name, "my-app")
        XCTAssertEqual(o.form.image, "claude-code")
        XCTAssertEqual(o.steps.map(\.id), ["folder", "image", "account", "access", "rules", "permissions", "resources", "bridges", "session", "review"])
        XCTAssertEqual(o.rules, [], "a folder not made yet has no rules")
        XCTAssertEqual(o.rulesGuide, WebRulesGuide())

        var q = WebProjectRequest(folder: folder)
        var form = o.form
        form.github = "read"
        form.permissions = "+web"
        form.cpus = 2                                    // the default — not set on purpose: left out
        q.form = form
        q.explicit = ["github", "permissions"]
        let (pv, back) = try WebProject.preview(q, settings: settings, store: "/tmp/fake-store", taken: [])
        XCTAssertNil(pv.existing)
        XCTAssertTrue(pv.text.contains("github: read") && pv.text.contains("permissions: +web") || pv.text.contains("permissions: \"+web\""), pv.text)
        XCTAssertTrue(pv.text.contains("# cpus: 2"))
        XCTAssertEqual(back.github, "read")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder), "a preview makes nothing")
        XCTAssertThrowsError(try WebProject.preview(q, settings: settings, store: "/tmp/fake-store", taken: ["my-app"]), "a sandbox has the name")

        let w = try WebProject.write(q, settings: settings, store: "/tmp/fake-store", taken: [])
        XCTAssertEqual(w.written, true)
        XCTAssertEqual(try String(contentsOfFile: folder + "/doz_project.yaml", encoding: .utf8), pv.text, "the review is the file")

        // Opening the folder again pre-fills from the file.
        o = WebProject.open(WebProjectRequest(folder: folder), settings: settings, store: "/tmp/fake-store")
        XCTAssertEqual(o.file, "doz_project.yaml")
        XCTAssertEqual(o.form.github, "read")
        XCTAssertEqual(o.form.permissions, "+web")
        XCTAssertEqual(Set(o.explicit), ["github", "permissions"])
        XCTAssertEqual(o.rules, [], "no rule file: the folder is shared as is")
        try "secrets.env\n".write(toFile: folder + "/.dozignore", atomically: true, encoding: .utf8)
        o = WebProject.open(WebProjectRequest(folder: folder), settings: settings, store: "/tmp/fake-store")
        XCTAssertEqual(o.rules.map(\.name), [".dozignore"], "the Workspace rules step shows the folder's rule files")
        XCTAssertEqual(o.rules.first?.first, ["secrets.env"])
        try FileManager.default.removeItem(atPath: folder + "/.dozignore")

        // Replacing it: only with the digest of what is there (the page showed the diff).
        var q2 = q
        q2.form?.github = "push"
        let (pv2, _) = try WebProject.preview(q2, settings: settings, store: "/tmp/fake-store", taken: [])
        XCTAssertEqual(pv2.existing, pv.text)
        XCTAssertTrue(pv2.diff?.contains("- github: read") == true && pv2.diff?.contains("+ github: push") == true)
        XCTAssertThrowsError(try WebProject.write(q2, settings: settings, store: "/tmp/fake-store", taken: [])) { e in
            XCTAssertEqual((e as? HostError)?.code, .exists)
        }
        q2.replace = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try WebProject.write(q2, settings: settings, store: "/tmp/fake-store", taken: []))
        q2.replace = pv2.replace
        XCTAssertEqual(try WebProject.write(q2, settings: settings, store: "/tmp/fake-store", taken: []).written, true)
        XCTAssertTrue(try String(contentsOfFile: folder + "/doz_project.yaml", encoding: .utf8).contains("github: push"))

        // The action: the sandbox the file describes, with the options doz up gives it.
        guard case .create(let name, let opts) = try WebProject.createAction(folder: folder) else { return XCTFail("create") }
        XCTAssertEqual(name, "my-app")
        XCTAssertEqual(opts.workspace, folder)
        XCTAssertEqual(opts.allow, ["standard", "+web", "+github:as-you", "+github:push"])
        XCTAssertEqual(opts.project, folder + "/doz_project.yaml")
    }
}
