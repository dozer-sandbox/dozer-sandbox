import Foundation
import XCTest
@testable import DozerCLI
@testable import DozerKit
@testable import DozerHost
@testable import DozerWeb

/// 599g: workspace rules on the host — the setting and the project key, the facts line, the warnings,
/// `workspace-rules` answered in-process (no VM), SandboxInfo and its web projection.
final class WorkspaceRulesHostTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-wr-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ rel: String, _ text: String, in dir: URL) throws {
        let u = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }

    // MARK: the setting and the project key

    func testTheSettingIsOneClosedPerSandboxChoice() throws {
        let d = try XCTUnwrap(DozerSettings.definition("workspace.ignore_mode"))
        XCTAssertEqual(d.type, .choice(["lock", "hide"]))
        XCTAssertEqual(d.defaultValue, .string("lock"))
        XCTAssertEqual(d.flag, "doz create --ignore-mode lock|hide")
        XCTAssertTrue(DozerSettings.perSandbox.contains(SettingKey.ignoreMode))
        XCTAssertThrowsError(try d.parse("open"))
        XCTAssertTrue(d.summary.contains("not a security boundary"), "said where a person reads it")
        // its source: the sandbox's own choice wins over the file
        var cfg = try sandboxConfig(workspace: nil)
        XCTAssertEqual(HostCore.ruleMode(cfg, settings: DozerSettings(text: "")).mode, .lock)
        cfg.settings = [SettingKey.ignoreMode: .string("hide")]
        XCTAssertEqual(HostCore.ruleMode(cfg).mode, .hide)
        XCTAssertEqual(HostCore.ruleMode(cfg).source, "sandbox")
    }

    func testTheProjectFileCarriesIgnoreMode() throws {
        XCTAssertTrue(DozerProject.settingKeys.contains { $0.key == "ignore_mode" && $0.setting == SettingKey.ignoreMode })
        let p = try DozerProject.parse("version: 1\nname: demo\nimage: lab\nignore_mode: hide\n")
        XCTAssertEqual(p.settings[SettingKey.ignoreMode], .string("hide"))
        XCTAssertThrowsError(try DozerProject.parse("version: 1\nname: demo\nimage: lab\nignore_mode: maybe\n"))
        let back = try DozerProject.parse(p.render())
        XCTAssertEqual(back.settings[SettingKey.ignoreMode], .string("hide"), "rendered and read back")
        // the dashboard's wizard model round-trips it too
        let form = WebProjectForm(p)
        XCTAssertEqual(form.ignoreMode, "hide")
        XCTAssertEqual(try form.project().settings[SettingKey.ignoreMode], .string("hide"))
    }

    // MARK: the facts

    func testTheFactsSayTheRulesOnlyWhileAViewServesThem() throws {
        func facts(_ m: WorkspaceRuleMode?) -> String {
            AgentPrompt.values(name: "n", image: "pi", cpus: 1, memoryMiB: 1024, workspace: "/w", network: .none, account: nil, version: "1",
                               hostname: "h", workspaceRules: m)["workspace.rules"] ?? "?"
        }
        XCTAssertEqual(facts(nil), "")
        XCTAssertTrue(facts(.lock).contains("listed with no permissions"))
        XCTAssertTrue(facts(.lock).contains("do not try to read, overwrite or recreate them"))
        XCTAssertTrue(facts(.hide).contains("not there for you"))
        XCTAssertTrue(AgentPrompt.variables.contains { $0.name == "workspace.rules" })
        let none = AgentPrompt.values(name: "n", image: "pi", cpus: 1, memoryMiB: 1024, workspace: "/w", network: .none, account: nil, version: "1", hostname: "h")
        let rendered = try AgentPrompt.render(AgentPrompt.builtInTemplate, none, source: "t")
        XCTAssertFalse(rendered.contains("Workspace rules"), "no rules: no line (an empty bullet is dropped)")
        XCTAssertFalse(rendered.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "-" })
    }

    // MARK: the warnings

    func testTheWarnings() throws {
        let dir = root.appendingPathComponent("proj")
        try write(".git/HEAD", "ref: refs/heads/main\n", in: dir)
        try write("secret.env", "S\n", in: dir)
        try write("src/a.log", "l\n", in: dir)
        try write("web/node_modules/x.js", "x\n", in: dir)
        try write("config/app.yaml", "c\n", in: dir)
        let rules = WorkspaceRules(ignoreText: "secret.env\nnode_modules\n*.log\nbad[\n", readOnlyText: "config\n", mode: .lock, fold: true)
        let w = WorkspaceWarnings.compute(folder: dir, rules: rules, gitFiles: ["secret.env", "src/a.log", "config/app.yaml", "README.md"])
        XCTAssertTrue(w.contains { $0.hasPrefix(".dozignore line 4 (`bad[`) is not a valid pattern") }, "\(w)")
        XCTAssertTrue(w.contains { $0.hasPrefix("1 git-tracked file is locked by .dozignore (secret.env)") && $0.contains("shows it as deleted") }, "\(w)")
        XCTAssertTrue(w.contains { $0.hasPrefix("1 git-tracked file is read-only by .dozreadonly (config/app.yaml)") }, "\(w)")
        XCTAssertTrue(w.contains { $0.hasPrefix("`node_modules` (.dozignore line 2) matches only at the top") && $0.contains("web/node_modules") && $0.contains("**/node_modules") }, "\(w)")
        XCTAssertTrue(w.contains { $0.hasPrefix("`*.log` (.dozignore line 3) matches only at the top") && $0.contains("src/a.log") }, "\(w)")
        // .git itself
        let g = WorkspaceWarnings.compute(folder: dir, rules: WorkspaceRules(ignoreText: ".git\n", readOnlyText: nil), gitFiles: [])
        XCTAssertTrue(g.contains { $0.hasPrefix("`.git` is locked by .dozignore line 1 (`.git`) — git cannot work") }, "\(g)")
        let gro = WorkspaceWarnings.compute(folder: dir, rules: WorkspaceRules(ignoreText: nil, readOnlyText: ".git\n"), gitFiles: [])
        XCTAssertTrue(gro.contains { $0.contains("`.git` is read-only by .dozreadonly line 1") }, "\(gro)")
        // covered at every depth: no anchoring warning; the implicit read-only never warns
        let ok = WorkspaceWarnings.compute(folder: dir, rules: WorkspaceRules(ignoreText: "**/node_modules\n**/*.log\n", readOnlyText: nil),
                                           gitFiles: ["doz_project.yaml", "README.md"])
        XCTAssertEqual(ok, [])
    }

    // MARK: the host op, in-process

    private func sandboxConfig(workspace: URL?) throws -> SandboxConfig {
        let store = DozerStore(root: root)
        var o = CreateOptions(image: "lab")
        o.workspace = workspace?.path
        let (s, n) = try DozerImages.spec(name: "x", options: o, store: store, environment: [:])
        return SandboxConfig(name: "x", image: n, spec: s, workspace: workspace?.path)
    }

    func testWorkspaceRulesAnsweredFromTheMacWithoutAHost() async throws {
        let dir = root.appendingPathComponent("ws")
        try write("secret.env", "S\n", in: dir)
        try write("config/app.yaml", "c\n", in: dir)
        try write("logs/keep.txt", "k\n", in: dir)
        let store = DozerStore(root: root)
        try sandboxConfig(workspace: dir).write(store.configFile("x"))
        let core = HostCore(store: store, readOnly: true, version: "test")
        await core.load()
        XCTAssertTrue(HostOp.workspaceRules.isReadOnly, "looking never starts a host")
        // no rule file
        let m0 = await core.handle(HostRequest(.workspaceRules, name: "x"))
        var none = try XCTUnwrap(m0.result).decode(WorkspaceRulesReport.self)
        XCTAssertFalse(none.active)
        XCTAssertEqual(none.view, "off")
        let m1 = await core.handle(HostRequest(.ls))
        var ls = try XCTUnwrap(m1.result).decode([SandboxInfo].self)
        XCTAssertNil(ls.first?.workspaceRules)
        // rules
        try write(".dozignore", "secret.env\nlogs\n!logs/keep.txt\n", in: dir)
        try write(".dozreadonly", "config\n", in: dir)
        var r = HostRequest(.workspaceRules, name: "x")
        r.paths = ["secret.env", "/workspace/config/app.yaml", dir.appendingPathComponent("logs/keep.txt").path, "logs/other.log", "SECRET.ENV", ".dozignore", "src/new.c"]
        r.warnings = true
        let m2 = await core.handle(r)
        let rep = try XCTUnwrap(m2.result).decode(WorkspaceRulesReport.self)
        XCTAssertTrue(rep.active)
        XCTAssertEqual(rep.mode, "lock")
        XCTAssertEqual(rep.view, "stopped")
        XCTAssertEqual(rep.ignore.count, 3)
        XCTAssertEqual(rep.checks?.map(\.verdict), [.locked, .readOnly, .visible, .locked, .locked, .readOnly, .visible])
        XCTAssertEqual(rep.checks?.map(\.path), ["secret.env", "config/app.yaml", "logs/keep.txt", "logs/other.log", "SECRET.ENV", ".dozignore", "src/new.c"])
        XCTAssertEqual(IgnoreText.why(rep.checks![0], mode: "lock"), ".dozignore line 1 (`secret.env`)")
        XCTAssertEqual(IgnoreText.why(rep.checks![3], mode: "lock"), ".dozignore line 2 (`logs`) — through logs")
        XCTAssertTrue(IgnoreText.why(rep.checks![4], mode: "lock").hasSuffix("matched case-insensitively"))
        XCTAssertNotNil(rep.warnings)
        // outside the folder: refused, never decided
        var outside = HostRequest(.workspaceRules, name: "x")
        outside.paths = ["/etc/passwd"]
        let o1 = await core.handle(outside)
        XCTAssertEqual(o1.error?.code, .invalid)
        outside.paths = ["a/../../b"]
        let o2 = await core.handle(outside)
        XCTAssertEqual(o2.error?.code, .invalid)
        // SandboxInfo and its web projection
        let m3 = await core.handle(HostRequest(.ls))
        ls = try XCTUnwrap(m3.result).decode([SandboxInfo].self)
        let info = try XCTUnwrap(ls.first?.workspaceRules)
        XCTAssertEqual(info.ignorePatterns, 3)
        XCTAssertEqual(info.readOnlyPatterns, 1)
        XCTAssertEqual(info.view, "stopped")
        XCTAssertEqual(info.line, ".dozignore: 3 patterns (lock) · .dozreadonly: 1 pattern — when it runs")
        let row = WebSandboxRow(ls[0])
        XCTAssertEqual(row.workspaceRules, info.line)
        XCTAssertEqual(row.workspaceRulesView, "stopped")
        // an isolated sandbox has nothing to rule
        try sandboxConfig(workspace: nil).write(store.configFile("x"))
        let core2 = HostCore(store: store, readOnly: true, version: "test")
        await core2.load()
        let m4 = await core2.handle(HostRequest(.workspaceRules, name: "x"))
        none = try XCTUnwrap(m4.result).decode(WorkspaceRulesReport.self)
        XCTAssertNil(none.workspace)
        XCTAssertFalse(none.active)
        let m5 = await core2.handle(r)
        XCTAssertEqual(m5.error?.code, .invalid, "a path to check in an isolated sandbox is refused")
    }

    func testPathsAPersonTypes() throws {
        let f = root.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        XCTAssertEqual(try HostCore.relativeWorkspacePath("/workspace/a/b", folder: f, guestPath: "/workspace"), "a/b")
        XCTAssertEqual(try HostCore.relativeWorkspacePath("/workspace", folder: f, guestPath: "/workspace"), "")
        XCTAssertEqual(try HostCore.relativeWorkspacePath("./a/", folder: f, guestPath: "/workspace"), "a")
        XCTAssertEqual(try HostCore.relativeWorkspacePath(f.appendingPathComponent("x/y").path, folder: f, guestPath: "/workspace"), "x/y")
        XCTAssertThrowsError(try HostCore.relativeWorkspacePath("/tmp", folder: f, guestPath: "/workspace"))
        XCTAssertThrowsError(try HostCore.relativeWorkspacePath("a/../b", folder: f, guestPath: "/workspace"))
    }

    // MARK: the onboarding's and the New Sandbox wizard's step (owner A1/A2)

    func testTheGuideSaysWhatItDoesAndWhatItIsNot() {
        XCTAssertEqual(WorkspaceRulesGuide.modes.map(\.value), ["lock", "hide"], "the setting's own choices, in order")
        XCTAssertEqual(WorkspaceRulesGuide.modes.filter(\.recommended).map(\.value), ["lock"])
        XCTAssertEqual(WorkspaceRulesGuide.points.compactMap(\.term), [".dozignore", ".dozreadonly"])
        let all = ([WorkspaceRulesGuide.intro, WorkspaceRulesGuide.question, WorkspaceRulesGuide.noRules, WorkspaceRulesGuide.howToAdd]
                   + WorkspaceRulesGuide.points.map(\.text) + WorkspaceRulesGuide.modes.map(\.detail)).joined(separator: " ")
        for words in ["not a security boundary", "without moving anything", "shared exactly as it is", "a little slower", "cannot be opened", "not there at all"] {
            XCTAssertTrue(all.contains(words), "says: \(words)")
        }
        XCTAssertEqual(WebRulesGuide().modes.map(\.value), ["lock", "hide"], "the web serves the same words")
        XCTAssertEqual(WebRulesGuide().intro, WorkspaceRulesGuide.intro)
    }

    func testAFoldersRuleFilesAsTheWizardShowsThem() throws {
        XCTAssertEqual(WorkspaceRulesGuide.folderFiles(root.appendingPathComponent("not-made-yet")), [])
        XCTAssertEqual(WorkspaceRulesGuide.folderFiles(root), [], "no rule file: none")
        try write(".dozignore", "# secrets\nsecrets.env\n**/*.key\nlogs\n!logs/keep.txt\nbuild/*.tmp\n", in: root)
        var f = WorkspaceRulesGuide.folderFiles(root)
        XCTAssertEqual(f.map(\.name), [".dozignore"])
        XCTAssertEqual(f[0].patterns, 5)
        XCTAssertEqual(f[0].first, ["secrets.env", "**/*.key", "logs", "!logs/keep.txt"], "the first four, comments left out")
        XCTAssertEqual(WorkspaceRulesGuide.count(f[0]), "5 patterns")
        try write(".dozreadonly", "config\n", in: root)
        f = WorkspaceRulesGuide.folderFiles(root)
        XCTAssertEqual(f.map(\.name), [".dozignore", ".dozreadonly"])
        XCTAssertEqual(f[1].patterns, 1, "the implicit read-only paths are not the file's")
        XCTAssertEqual(WebRuleFile(f[1]).count, "1 pattern")
        // A rule file may have been written from inside a sandbox: what is shown is inert.
        try write(".dozignore", "a\u{1b}]52;c;eA==\u{07}b\u{1b}[31mred\n", in: root)
        XCTAssertFalse(WorkspaceRulesGuide.folderFiles(root)[0].first.joined().unicodeScalars.contains { $0.value < 0x20 })
    }

    func testTheOnboardingWritesTheDefaultModeOnlyWhenChosen() throws {
        let env = ["XDG_CONFIG_HOME": root.appendingPathComponent("xdg").path]
        let file = root.appendingPathComponent("xdg/dozer-sandbox/doz.toml")
        XCTAssertEqual(try Onboarding.writeIgnoreMode("hide", environment: env), ["workspace.ignore_mode = hide"])
        XCTAssertEqual(DozerSettings.load(environment: env).string(SettingKey.ignoreMode), "hide")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(try Onboarding.writeIgnoreMode("hide", environment: env), [], "the file already says so: untouched")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
        XCTAssertEqual(try Onboarding.writeIgnoreMode("lock", environment: env), ["workspace.ignore_mode = lock"])
        XCTAssertThrowsError(try Onboarding.writeIgnoreMode("open", environment: env))
        // The dashboard's body: ignoreMode is optional, lock or hide, never anything else.
        XCTAssertEqual(try WebOnboardingConfig.decode(Data(#"{"defaultImage":"lab","account":"later","ignoreMode":"hide"}"#.utf8)).ignoreMode, "hide")
        XCTAssertNil(try WebOnboardingConfig.decode(Data(#"{"defaultImage":"lab","account":"later"}"#.utf8)).ignoreMode)
        for bad in [#"{"defaultImage":"lab","account":"later","ignoreMode":"open"}"#, #"{"defaultImage":"lab","account":"later","ignoreMode":true}"#,
                    #"{"defaultImage":"lab","ignoreMode":"lock"}"#, #"{"defaultImage":"lab","account":"later","ignore_mode":"lock"}"#] {
            XCTAssertThrowsError(try WebOnboardingConfig.decode(Data(bad.utf8)), bad)
        }
    }
}
