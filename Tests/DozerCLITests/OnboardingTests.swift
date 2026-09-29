import Foundation
import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost

/// 594 — onboarding without a VM: the project file's closed schema, the environment prompt's layers
/// and closed variables, the onboarding's checks / account step / settings-only-when-missing, the
/// onboarding record, the host's single-flight preparations (joined, replayed, cancelled — with a
/// substitute for the work), and `doz uninstall`'s idea of an installation.
final class OnboardingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-onb-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: D9 — doz_project.yaml

    func testAProjectFileParses() throws {
        let p = try DozerProject.parse("""
        version: 1
        name: webapp
        image: claude-code
        cpus: 4
        memory: 4G
        network: open
        account: default
        sessions:
          - claude
          - name: server
            command: npm run dev
          - name: tests
            command: [make, test]
        agent_prompt: |
          The tests run with make test.
        agent_prompt_mode: replace
        """)
        XCTAssertEqual(p.name, "webapp")
        XCTAssertEqual(p.image, "claude-code")
        XCTAssertEqual(p.cpus, 4)
        XCTAssertEqual(p.memoryMiB, 4096)
        XCTAssertEqual(p.network, "open")
        XCTAssertEqual(p.account, "default")
        XCTAssertEqual(p.sessions, [.init(name: "claude", command: nil), .init(name: "server", command: ["npm", "run", "dev"]),
                                    .init(name: "tests", command: ["make", "test"])])
        XCTAssertEqual(p.agentPrompt, "The tests run with make test.\n")
        XCTAssertEqual(p.agentPromptMode, "replace")
        let o = p.createOptions(folder: root, file: root.appendingPathComponent(DozerProject.fileName))
        XCTAssertEqual(o.workspace, root.path, "the folder is the workspace")
        XCTAssertEqual(o.project, root.appendingPathComponent(DozerProject.fileName).path)
        XCTAssertEqual(o.agentPromptMode, "replace")
    }

    func testTheSchemaIsClosedAndErrorsNameTheLine() {
        func fails(_ text: String, _ contains: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try DozerProject.parse(text), file: file, line: line) { e in
                XCTAssertTrue(e.localizedDescription.contains(contains), "\(e.localizedDescription) — wanted \(contains)", file: file, line: line)
            }
        }
        fails("name: a\nimage: lab\ncolour: blue\n", "line 3: unknown key colour")
        fails("name: a\nimage: lab\nname: b\n", "given twice")
        fails("image: lab\n", "name is required")
        fails("name: a\n", "image is required")
        fails("name: A_B\nimage: lab\n", "name: 1–40")
        fails("name: a\nimage: ./Dockerfile\n", "Dockerfile is not supported")
        fails("name: a\nimage: lab\ncpus: 100\n", "cpus")
        fails("name: a\nimage: lab\ncpus: two\n", "cpus")
        fails("name: a\nimage: lab\nmemory: lots\n", "memory")
        fails("name: a\nimage: lab\nnetwork: host\n", "network")
        fails("name: a\nimage: lab\nversion: 2\n", "version is 1")
        fails("name: a\nimage: lab\nagent_prompt_mode: prepend\n", "append or replace")
        fails("name: a\nimage: lab\nsessions: claude\n", "sessions is a list")
        fails("name: a\nimage: lab\nsessions:\n  - name: x\n    shell: true\n", "not shell")
        fails("name: a\nimage: lab\nsessions: [a, a]\n", "each name once")
        fails("- a\n- b\n", "mapping")
        fails("name: &n a\nimage: *n\n", "aliases")
        fails("name: a\nimage: lab\n---\nname: b\n", "one YAML document")
        fails("name: [unclosed\n", "not valid YAML")
    }

    func testWhatInitWritesReadsBack() throws {
        var p = DozerProject(name: "my-proj", image: "pi")
        let bare = try DozerProject.parse(p.render())
        XCTAssertEqual(bare, p, "every optional key commented out = its default")
        p.cpus = 3
        p.memoryMiB = 1536
        p.network = "locked"
        p.account = "none"
        p.sessions = [.init(name: "pi", command: nil), .init(name: "srv", command: ["python3", "-m", "http.server"])]
        p.agentPrompt = "line one\nline two"
        p.agentPromptMode = "append"
        let back = try DozerProject.parse(p.render())
        XCTAssertEqual(back.cpus, 3)
        XCTAssertEqual(back.memoryMiB, 1536)
        XCTAssertEqual(back.sessions, p.sessions)
        XCTAssertEqual(back.agentPrompt, "line one\nline two\n")
        XCTAssertEqual(DozerProject.suggestedName(for: URL(fileURLWithPath: "/x/My Project_2")), "my-project-2")
        XCTAssertEqual(DozerProject.suggestedName(for: URL(fileURLWithPath: "/x/___")), "project")
    }

    // MARK: D15/D16 — the environment prompt

    func config(workspace: String?, network: NetworkMode = .proxied(.agent), image: String = "claude-code") throws -> SandboxConfig {
        var o = CreateOptions(image: image, workspace: workspace)
        o.network = DozerImages.networkName(network)
        let (spec, img) = try DozerImages.spec(name: "p1", options: o, store: DozerStore(root: root), environment: [:])
        return SandboxConfig(name: "p1", image: img, spec: spec, workspace: workspace)
    }

    func env(_ extra: [String: String] = [:]) -> [String: String] {
        ["XDG_CONFIG_HOME": root.appendingPathComponent("xdg").path].merging(extra) { _, b in b }
    }

    func testTheFactsSayWhereTheWorkspaceIsOrThatItIsNotShared() throws {
        let shared = try XCTUnwrap(AgentPrompt.report(config: try config(workspace: root.path), policy: .agent, account: "mac", version: "9.9",
                                                      settings: DozerSettings.load(environment: env()), hostname: "Mac-1"))
        XCTAssertEqual(shared.agent, "claude-code")
        XCTAssertNil(shared.error)
        let text = try XCTUnwrap(shared.text)
        XCTAssertTrue(text.contains("user's Mac folder \(root.path), shared live"), text)
        XCTAssertTrue(text.contains("Linux virtual machine (not a container)"))
        XCTAssertTrue(text.contains("Mac-1"))
        XCTAssertTrue(text.contains("deny by default"))
        XCTAssertTrue(text.contains("never log in"))
        XCTAssertLessThan(text.split(separator: "\n").count, 12, "the facts block is short (D15a)")
        XCTAssertTrue(shared.skill?.hasPrefix("---\nname: dozer\n") == true)
        XCTAssertEqual(shared.skillPath, "/home/agent/.claude/skills/dozer/SKILL.md")
        XCTAssertEqual(shared.layers, ["built-in"])

        let private_ = try XCTUnwrap(AgentPrompt.report(config: try config(workspace: nil), policy: .agent, account: nil, version: "9.9",
                                                        settings: DozerSettings.load(environment: env()), hostname: "Mac-1"))
        XCTAssertTrue(private_.text!.contains("/workspace is NOT shared with the Mac"), private_.text!)
        XCTAssertTrue(private_.text!.contains("no account is attached"))

        let pi = try XCTUnwrap(AgentPrompt.report(config: try config(workspace: nil, image: "pi"), policy: .agent, account: nil, version: "9.9",
                                                  settings: DozerSettings.load(environment: env()), hostname: "m"))
        XCTAssertEqual(pi.skillPath, "/home/agent/.pi/agent/skills/dozer/SKILL.md")
        XCTAssertNil(AgentPrompt.report(config: try config(workspace: nil, network: .nat, image: "lab"), policy: nil, account: nil, version: "1",
                                        settings: DozerSettings.load(environment: env())), "the lab runs no agent")
    }

    func testUnknownVariablesAreAnErrorNeverBlank() {
        XCTAssertEqual(try AgentPrompt.render("a {{ sandbox.name }} b", ["sandbox.name": "x"], source: "t"), "a x b")
        XCTAssertThrowsError(try AgentPrompt.render("{{sandbox.nmae}}", ["sandbox.name": "x"], source: "my file")) { e in
            XCTAssertTrue(e.localizedDescription.contains("my file: {{sandbox.nmae}} is not a variable"), e.localizedDescription)
        }
        XCTAssertThrowsError(try AgentPrompt.render("{{ open", [:], source: "t"))
        // Every variable the templates use is on the closed list, and every one has a value.
        let v = AgentPrompt.values(name: "n", image: "pi", cpus: 1, memoryMiB: 1536, workspace: nil, network: .none, account: nil, version: "1", hostname: "h")
        XCTAssertEqual(Set(v.keys), Set(AgentPrompt.variables.map(\.name)))
        XCTAssertEqual(v["sandbox.memory"], "1536 MiB")
        XCTAssertNoThrow(try AgentPrompt.render(AgentPrompt.builtInTemplate, v, source: "b"))
        XCTAssertNoThrow(try AgentPrompt.render(AgentPrompt.skillTemplate, v, source: "s"))
    }

    func testTheLayersUserTemplateAndSandboxAppendOrReplaceAndOff() throws {
        let dir = root.appendingPathComponent("xdg/dozer-sandbox")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tpl = dir.appendingPathComponent("agent-prompt.md")
        // The starter onboarding writes is all comment: it changes nothing.
        try AgentPrompt.userTemplateStarter.write(to: tpl, atomically: true, encoding: .utf8)
        XCTAssertNil(AgentPrompt.stripComments(AgentPrompt.userTemplateStarter))
        var cfg = try config(workspace: root.path)
        var r = try XCTUnwrap(AgentPrompt.report(config: cfg, policy: .agent, account: "mac", version: "1", settings: DozerSettings.load(environment: env())))
        XCTAssertEqual(r.layers, ["built-in"])
        // A template of the user's own replaces the built-in one.
        try "<!-- mine -->\nYou are in {{sandbox.name}}; the Mac's folder is {{workspace.host_path}}.".write(to: tpl, atomically: true, encoding: .utf8)
        r = try XCTUnwrap(AgentPrompt.report(config: cfg, policy: .agent, account: "mac", version: "1", settings: DozerSettings.load(environment: env())))
        XCTAssertEqual(r.text, "You are in p1; the Mac's folder is \(root.path).")
        XCTAssertEqual(r.layers, ["user template \(tpl.path)"])
        // The sandbox's own: appended, or replacing.
        cfg.agentPrompt = "Tests: make test."
        r = try XCTUnwrap(AgentPrompt.report(config: cfg, policy: .agent, account: "mac", version: "1", settings: DozerSettings.load(environment: env())))
        XCTAssertEqual(r.text, "You are in p1; the Mac's folder is \(root.path).\n\nTests: make test.")
        cfg.agentPromptMode = "replace"
        r = try XCTUnwrap(AgentPrompt.report(config: cfg, policy: .agent, account: "mac", version: "1", settings: DozerSettings.load(environment: env())))
        XCTAssertEqual(r.text, "Tests: make test.")
        XCTAssertEqual(r.layers.last, "sandbox (replace)")
        // An unknown variable in the sandbox's layer: an error that names it.
        cfg.agentPrompt = "{{nope}}"
        r = try XCTUnwrap(AgentPrompt.report(config: cfg, policy: .agent, account: "mac", version: "1", settings: DozerSettings.load(environment: env())))
        XCTAssertNil(r.text)
        XCTAssertTrue(r.error?.contains("p1's own prompt: {{nope}} is not a variable") == true, r.error ?? "")
        // agent.prompt = false: off (and the guest's files are removed).
        try "[agent]\nprompt = false\n".write(to: dir.appendingPathComponent("doz.toml"), atomically: true, encoding: .utf8)
        r = try XCTUnwrap(AgentPrompt.report(config: cfg, policy: .agent, account: "mac", version: "1", settings: DozerSettings.load(environment: env())))
        XCTAssertFalse(r.enabled)
        XCTAssertNil(r.text)
        let script = AgentPrompt.deliveryScript(r, user: "agent")
        XCTAssertTrue(script.contains("rm -f '/run/dozer/agent-prompt.md'"), script)
        XCTAssertTrue(script.contains("rm -rf '/home/agent/.claude/skills/dozer'"), script)
    }

    func testTheDeliveryWritesOnlyDozersFiles() throws {
        let r = try XCTUnwrap(AgentPrompt.report(config: try config(workspace: nil), policy: .agent, account: nil, version: "1",
                                                 settings: DozerSettings.load(environment: env())))
        let s = AgentPrompt.deliveryScript(r, user: "agent")
        XCTAssertTrue(s.contains("> '/run/dozer/agent-prompt.md.tmp'"))
        XCTAssertTrue(s.contains("'/home/agent/.claude/skills/dozer/SKILL.md'"))
        XCTAssertFalse(s.contains("CLAUDE.md"), "never the agent's own memory files")
        XCTAssertFalse(s.contains("settings.json"))
        // The contents travel base64-encoded: nothing of the text is interpreted by the shell.
        XCTAssertTrue(s.contains(Data((r.text! + "\n").utf8).base64EncodedString()))
    }

    // MARK: D5/D6/D7 — checks, the account step, settings only when missing

    func testHardChecksStopSoftOnesWarn() {
        let doctor: [(check: String, status: String, detail: String)] = [
            ("macOS", "ok", "27"), ("chip", "fail", "x86_64"), ("claude", "warn", "not installed"), ("vmnet", "ok", ""),
            ("claude login", "warn", "signed out"), ("store", "warn", "ignored here"),
        ]
        let checks = Onboarding.checks(doctor: doctor, store: DozerStore(root: root), chosen: ["claude-code"], prepared: [])
        XCTAssertEqual(checks.filter(\.blocks).map(\.check), ["chip"])
        XCTAssertFalse(checks.first { $0.check == "claude" }!.hard)
        XCTAssertFalse(checks.first { $0.check == "claude login" }!.hard)
        XCTAssertTrue(checks.first { $0.check == "store" }!.hard, "the store's own check is replaced by APFS + disk")
        XCTAssertEqual(checks.first { $0.check == "store" }?.status, "ok", "the temporary directory is on APFS")
        XCTAssertEqual(checks.first { $0.check == "disk" }?.status, "ok")
        XCTAssertEqual(Onboarding.requiredBytes(["claude-code"], prepared: ["claude-code"]), 0, "prepared: nothing to download")
        XCTAssertGreaterThan(Onboarding.requiredBytes(["claude-code", "pi"], prepared: []), Onboarding.requiredBytes(["claude-code"], prepared: []))
    }

    func testTheAccountStepOffersWhatIsThereAndNeverAddsASecret() {
        XCTAssertEqual(Onboarding.accountOptions(macSignedIn: true).preferred, .mac)
        XCTAssertEqual(Onboarding.accountOptions(macSignedIn: false).preferred, .skip)
        XCTAssertEqual(Set(Onboarding.accountOptions(macSignedIn: false).options), [.apiKey, .setupToken, .mac, .none, .skip])
        XCTAssertEqual(Onboarding.defaultAccount(for: .mac), "mac")
        XCTAssertEqual(Onboarding.defaultAccount(for: .none), "none")
        XCTAssertNil(Onboarding.defaultAccount(for: .skip))
        XCTAssertNil(Onboarding.defaultAccount(for: .apiKey), "a key is added later, with the CLI")
        XCTAssertTrue(Onboarding.accountCommands(.setupToken).contains { $0.hasPrefix("doz account add work --setup-token") })
        XCTAssertTrue(Onboarding.accountCommands(.mac).isEmpty)
    }

    func testTheSettingsFileIsWrittenOnlyWhenMissing() throws {
        let e = env()
        let (first, path) = try Onboarding.writeSettingsIfMissing(defaultImage: "pi", account: "none", environment: e)
        XCTAssertEqual(first, .written)
        let s = DozerSettings.load(environment: e)
        XCTAssertEqual(s.string(SettingKey.defaultImage), "pi")
        XCTAssertEqual(s.string(SettingKey.defaultAccount), "none")
        XCTAssertEqual(s.fileValues.count, 2, "the onboarding's answers are the only values set")
        let before = try String(contentsOfFile: try XCTUnwrap(path), encoding: .utf8)
        let (again, _) = try Onboarding.writeSettingsIfMissing(defaultImage: "lab", account: "mac", environment: e)
        XCTAssertEqual(again, .kept)
        XCTAssertEqual(try String(contentsOfFile: path!, encoding: .utf8), before, "an existing file is never touched")
        XCTAssertEqual(try Onboarding.writePromptTemplateIfMissing(environment: e).0, .written)
        XCTAssertEqual(try Onboarding.writePromptTemplateIfMissing(environment: e).0, .kept)
        XCTAssertEqual(try Onboarding.writeSettingsIfMissing(defaultImage: "pi", account: nil, environment: [:]).0, .unavailable)
    }

    func testAStoreWithoutAccountsFollowsTheSettingsDefaultAccount() throws {
        let store = DozerStore(root: root)
        XCTAssertEqual(AccountStore(store: store, newStoreDefault: "none").load().defaultAccount, "none")
        var f = AccountStore(store: store).load()
        f.defaultAccount = "mac"
        try AccountStore(store: store).save(f)
        XCTAssertEqual(AccountStore(store: store, newStoreDefault: "none").load().defaultAccount, "mac", "a store's own choice wins")
    }

    func testTheOnboardingRecordAddsImages() throws {
        let store = DozerStore(root: root)
        XCTAssertNil(OnboardingRecord.read(store))
        try OnboardingRecord.record(store, version: "1", images: ["claude-code"])
        let r = try OnboardingRecord.record(store, version: "2", images: ["lab", "claude-code"])
        XCTAssertEqual(r.images, ["claude-code", "lab"])
        XCTAssertEqual(OnboardingRecord.read(store)?.dozVersion, "2")
        XCTAssertEqual(OnboardingRecord.url(store).lastPathComponent, "onboarded.json", "never state.json — the image store's index")
    }

    // MARK: D3/D4 — preparations in the host: single-flight, joined, replayed, cancelled

    /// The work stands in for kernel + pull + bake: a step, a transfer, then waits for `release`.
    final class Gate: @unchecked Sendable {
        let lock = NSLock()
        var runs: [String] = []
        var released = false
        var fail = false
        func add(_ i: String) { lock.withLock { runs.append(i) } }
        var isReleased: Bool { lock.withLock { released } }
    }

    func core(_ gate: Gate) async -> HostCore {
        let c = HostCore(store: DozerStore(root: root), readOnly: false, version: "t", newStoreDefaultAccount: "mac")
        await c.setPreparationRunner({ image, _, emit in
            gate.add(image)
            emit(HostEvent(kind: .started, sandbox: image, text: "pulled the base image node"))
            emit(HostEvent(kind: .progress, sandbox: image, text: "pulling node@1234", completedBytes: 10, totalBytes: 100))
            while !gate.isReleased { try await Task.sleep(for: .milliseconds(20)) }
            if gate.fail { throw HostError(.failed, "no network") }
            emit(HostEvent(kind: .step, sandbox: image, text: "pulled the base image node", milliseconds: 1500))
        }, prepared: { _, _ in false })
        return c
    }

    final class Events: @unchecked Sendable {
        let lock = NSLock()
        var list: [HostEvent] = []
        func add(_ e: HostEvent) { lock.withLock { list.append(e) } }
        var texts: [String] { lock.withLock { list.compactMap(\.text) } }
    }

    func testOnePreparationPerImageAndAJoinerSeesItFromTheStart() async throws {
        let gate = Gate()
        let c = await core(gate)
        var r = HostRequest(.onboard)
        r.images = ["claude-code"]
        r.requestedBy = "doz onboard"
        r.follow = false
        let first = try await c.handle(r).result!.decode(PrepareResult.self)
        XCTAssertEqual(first.preparations.map(\.state), ["running"])
        XCTAssertNil(first.onboarded, "not onboarded until the image is ready")
        try await Task.sleep(for: .milliseconds(100))
        // A second asker (an image bake here; a start does the same) joins: same preparation, one run.
        let joiner = Events()
        let bake = Task { () -> HostMessage in
            var b = HostRequest(.imageBake)
            b.image = "claude-code"
            return await c.handle(b) { joiner.add($0) }
        }
        try await Task.sleep(for: .milliseconds(200))
        let st = try await c.handle(HostRequest(.prepareStatus)).result!.decode(PrepareStatus.self)
        XCTAssertEqual(st.preparations.count, 1)
        XCTAssertEqual(st.preparations[0].id, first.preparations[0].id)
        XCTAssertEqual(st.preparations[0].requestedBy, ["doz onboard", "image bake"])
        XCTAssertEqual(st.preparations[0].step, "pulled the base image node", "the step under way")
        XCTAssertEqual(st.preparations[0].transfer?.completedBytes, 10)
        XCTAssertTrue(joiner.texts.contains("pulled the base image node"), "the joiner got the events so far: \(joiner.texts)")
        let running = await c.runningPreparations()
        XCTAssertEqual(running, ["claude-code"], "it keeps the host up")
        gate.lock.withLock { gate.released = true }
        _ = await bake.value
        XCTAssertEqual(gate.runs, ["claude-code"], "one download, one bake")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(OnboardingRecord.read(DozerStore(root: root))?.images, ["claude-code"], "the host records the onboarding when it is ready")
        let after = try await c.handle(HostRequest(.prepareStatus)).result!.decode(PrepareStatus.self)
        XCTAssertEqual(after.preparations.first?.state, "done")
        XCTAssertTrue(after.preparations.first?.lines.contains { $0.contains("pulled the base image node") } == true)
    }

    func testAFailedPreparationRecordsNoOnboardingAndCancelCancels() async throws {
        let gate = Gate()
        gate.fail = true
        let c = await core(gate)
        var r = HostRequest(.onboard)
        r.images = ["pi"]
        r.follow = false
        _ = await c.handle(r)
        gate.lock.withLock { gate.released = true }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(OnboardingRecord.read(DozerStore(root: root)))
        let failed = try await c.handle(HostRequest(.prepareStatus)).result!.decode(PrepareStatus.self)
        XCTAssertEqual(failed.preparations.first?.state, "failed")
        XCTAssertEqual(failed.preparations.first?.error, "no network")

        let gate2 = Gate()
        let c2 = await core(gate2)
        var p = HostRequest(.prepare)
        p.images = ["lab"]
        p.follow = false
        _ = await c2.handle(p)
        try await Task.sleep(for: .milliseconds(100))
        let cancelled = try await c2.handle(HostRequest(.prepareCancel)).result!.decode([PreparationInfo].self)
        XCTAssertEqual(cancelled.map(\.image), ["lab"])
        try await Task.sleep(for: .milliseconds(300))
        let st = try await c2.handle(HostRequest(.prepareStatus)).result!.decode(PrepareStatus.self)
        XCTAssertEqual(st.preparations.first?.state, "cancelled")
        let left = await c2.runningPreparations()
        XCTAssertEqual(left, [])
        let again = await c2.handle(HostRequest(.prepareCancel))
        XCTAssertEqual(again.error?.code, .notFound, "nothing left to cancel")
    }

    func testAnImageAlreadyPreparedIsNotPreparedAgainAndNoImagesOnboardsAtOnce() async throws {
        let gate = Gate()
        let c = HostCore(store: DozerStore(root: root), readOnly: false, version: "t", newStoreDefaultAccount: "mac")
        await c.setPreparationRunner({ i, _, _ in gate.add(i) }, prepared: { i, _ in i == "claude-code" })
        let events = Events()
        var r = HostRequest(.onboard)
        r.images = ["claude-code"]
        let res = try await c.handle(r) { events.add($0) }.result!.decode(PrepareResult.self)
        XCTAssertTrue(res.preparations.isEmpty)
        XCTAssertEqual(res.onboarded?.images, ["claude-code"])
        XCTAssertTrue(events.texts.contains { $0.contains("already prepared") })
        XCTAssertEqual(gate.runs, [], "re-running prepares nothing")
        var none = HostRequest(.onboard)
        none.images = []
        let noneResult = try await c.handle(none).result!.decode(PrepareResult.self)
        XCTAssertNotNil(noneResult.onboarded)
        var bad = HostRequest(.onboard)
        bad.images = ["ubuntu"]
        let badResult = await c.handle(bad)
        XCTAssertEqual(badResult.error?.code, .invalid)
        let ro = HostCore(store: DozerStore(root: root), readOnly: true, version: "t")
        let roOnboard = await ro.handle(r)
        XCTAssertEqual(roOnboard.error?.code, .unavailable, "preparing needs the host")
        let roStatus = await ro.handle(HostRequest(.prepareStatus))
        XCTAssertNotNil(roStatus.result, "looking does not")
    }

    // MARK: D13 — uninstall

    func testUninstallKnowsAnInstallationAndAStore() throws {
        let prefix = root.appendingPathComponent("prefix")
        let libexec = prefix.appendingPathComponent("libexec/doz")
        try FileManager.default.createDirectory(at: libexec, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let exe = libexec.appendingPathComponent("doz")
        FileManager.default.createFile(atPath: exe.path, contents: Data("x".utf8))
        try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("bin/doz").path, withDestinationPath: exe.path)
        let inst = try XCTUnwrap(Uninstall.installation(executable: exe.path))
        XCTAssertEqual(inst.libexec.path, libexec.standardizedFileURL.path)
        XCTAssertEqual(inst.link?.lastPathComponent, "doz")
        XCTAssertNil(Uninstall.installation(executable: "/x/.build/debug/doz"), "a build is not an installation")
        // A store: empty, or with a store's own entries — never an arbitrary folder.
        let s = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        XCTAssertTrue(Uninstall.looksLikeStore(s))
        FileManager.default.createFile(atPath: s.appendingPathComponent("thesis.pdf").path, contents: Data())
        XCTAssertFalse(Uninstall.looksLikeStore(s))
        try FileManager.default.createDirectory(at: s.appendingPathComponent("sandboxes"), withIntermediateDirectories: true)
        XCTAssertTrue(Uninstall.looksLikeStore(s))
    }
}
