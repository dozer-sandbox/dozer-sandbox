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
        fails("name: a\nimage: ./Dockerfile\n", "(a Dockerfile: dockerfile: ./Dockerfile)")
        // 596 (B10): agent + base or dockerfile, never beside image, never both bases.
        fails("name: a\nimage: lab\nagent: pi\n", "not both")
        fails("name: a\nbase: python\ndockerfile: ./Dockerfile\n", "base or dockerfile")
        fails("name: a\nbase: cobol\n", "base: node, python")
        fails("name: a\nagent: gemini\nbase: go\n", "agent: claude-code, pi, codex or none")
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
        XCTAssertEqual(back.agentPrompt, "line one\nline two", "599f: exactly as written (`|-`)")
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
        XCTAssertTrue(private_.text!.contains("This sandbox is isolated (no folder is shared with the Mac)"), private_.text!)
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

    func testTheAccountStepOffersWhatIsThere() {
        XCTAssertEqual(Onboarding.accountOptions(macSignedIn: true).options, [.mac, .apiKey, .setupToken, .later])
        XCTAssertEqual(Onboarding.accountOptions(macSignedIn: true).preferred, .mac)
        XCTAssertEqual(Onboarding.accountOptions(macSignedIn: false).options, [.apiKey, .setupToken, .mac, .later])
        XCTAssertEqual(Onboarding.accountOptions(macSignedIn: false).preferred, .later)
        XCTAssertEqual(Onboarding.Account.later.label, "Decide later", "owner ruling: one option for 'none' and 'skip'")
        XCTAssertEqual(Onboarding.defaultAccount(for: .mac), "mac")
        XCTAssertNil(Onboarding.defaultAccount(for: .later))
        XCTAssertNil(Onboarding.defaultAccount(for: .apiKey), "the account added becomes the default, once it is")
        XCTAssertTrue(Onboarding.accountCommands(.setupToken).contains { $0.hasPrefix("doz account add work --setup-token") })
        XCTAssertTrue(Onboarding.accountCommands(.mac).isEmpty)
    }

    /// 594: a sandbox's own key — `doz key set NAME --anthropic`'s request, which the web UI builds too:
    /// held in the host's vault (memory), a placeholder for the guest, never on disk.
    func testASandboxKeyGoesTheKeySetWay() async throws {
        let core = HostCore(store: DozerStore(root: root), readOnly: false, version: "t",
                            services: .forHost(environment: ["DOZ_TEST_CREDENTIALS": "memory"]), newStoreDefaultAccount: "mac")
        var c = HostRequest(.create, name: "kb")
        c.create = CreateOptions(image: "lab", network: "agent", account: "none")
        let created = await core.handle(c)
        XCTAssertEqual(created.ok, true, created.error?.message ?? "")
        let key = "sk-ant-api03-" + String(repeating: "V", count: 40)
        let r = HostRequest.keySet(name: "kb", secret: "  " + key + "\n", source: "browser")
        XCTAssertEqual(r.op, .keySet)
        XCTAssertEqual(r.binding, CredentialBinding.anthropic.id)
        XCTAssertEqual(r.secret, key, "trimmed, as doz key set trims it")
        let m = await core.handle(r)
        XCTAssertEqual(m.ok, true, m.error?.message ?? "")
        let rows = try XCTUnwrap(m.result?.decode([CredentialRow].self))
        let row = try XCTUnwrap(rows.first { $0.binding == CredentialBinding.anthropic.id })
        XCTAssertTrue(row.set)
        XCTAssertEqual(row.source, "browser")
        let cfg = try String(contentsOf: DozerStore(root: root).configFile("kb"), encoding: .utf8)
        XCTAssertFalse(cfg.contains(key), "doz.json holds the source, never the key")
        XCTAssertTrue(cfg.contains("\"browser\""))
    }

    /// 594: the ONE request a secret takes into an account — `doz account add`'s, which onboarding
    /// and the web UI build too — through the host, into an IN-MEMORY keychain (never the real one).
    func testAnAccountFromAKeyGoesTheAccountAddWayIntoTheMemoryKeychain() async throws {
        let services = CredentialServices.forHost(environment: ["DOZ_TEST_CREDENTIALS": "memory"])
        XCTAssertTrue(services.keychain is MemoryKeychain)
        XCTAssertTrue(CredentialServices.forHost(environment: [:]).keychain is SystemKeychain)
        let core = HostCore(store: DozerStore(root: root), readOnly: false, version: "t", services: services, newStoreDefaultAccount: "mac")
        let key = "sk-ant-api03-" + String(repeating: "Z", count: 40)
        let r = HostRequest.accountAdd(name: "work", kind: .apiKey, plan: nil, secret: key)
        XCTAssertEqual(r.op, .accountAdd)
        XCTAssertEqual(r.verify, true)
        let m = await core.handle(r)
        XCTAssertEqual(m.ok, true, m.error?.message ?? "")
        let rows = try XCTUnwrap(m.result?.decode([AccountRow].self))
        let row = try XCTUnwrap(rows.first { $0.name == "work" })
        XCTAssertEqual(row.keychainService, "doz-anthropic:work")
        XCTAssertEqual(row.verification?.hasPrefix("unverified"), true, "the memory seam sends nothing")
        XCTAssertEqual(services.keychain.read(service: "doz-anthropic:work", account: nil), .found(key))
        let file = try String(contentsOf: root.appendingPathComponent("accounts.json"), encoding: .utf8)
        XCTAssertFalse(file.contains(key), "accounts.json never holds the secret")
        let token = "sk-ant-oat01-" + String(repeating: "Y", count: 40)
        let t = await core.handle(HostRequest.accountAdd(name: "sub", kind: .setupToken, plan: "max", secret: token))
        XCTAssertEqual(t.ok, true)
        XCTAssertEqual(try t.result?.decode([AccountRow].self).first { $0.name == "sub" }?.plan, "max")
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
        bad.images = ["cobol"]            // 596: ubuntu is a base now — cobol is not
        let badResult = await c.handle(bad)
        XCTAssertEqual(badResult.error?.code, .invalid)
        let ro = HostCore(store: DozerStore(root: root), readOnly: true, version: "t")
        let roOnboard = await ro.handle(r)
        XCTAssertEqual(roOnboard.error?.code, .unavailable, "preparing needs the host")
        let roStatus = await ro.handle(HostRequest(.prepareStatus))
        XCTAssertNotNil(roStatus.result, "looking does not")
    }

    /// 594 (owner: "more progress detail"): step N of M, the output's last 6 lines, the finished steps as
    /// data, and — only from this store's last run — per-step and overall estimates; a failed step keeps
    /// its last output.
    func testAPreparationSaysStepNOfMItsTailAndLastRunsEstimates() async throws {
        let gate = Gate()
        let c = HostCore(store: DozerStore(root: root), readOnly: false, version: "t", newStoreDefaultAccount: "mac")
        await c.setPreparationRunner({ image, _, emit in
            func ev(_ k: HostEvent.Kind, _ t: String, ms: Double? = nil) { emit(HostEvent(kind: k, sandbox: image, text: t, milliseconds: ms)) }
            ev(.started, "kernel ready (vmlinux, cached)"); ev(.step, "kernel ready (vmlinux, cached)", ms: 2000)
            ev(.started, "step: install things (a b c)")
            for i in 1...8 { ev(.output, "line \(i)") }
            while !gate.isReleased { try await Task.sleep(for: .milliseconds(20)) }
            if gate.fail { ev(.failed, "step: install things (a b c)", ms: 3000); throw HostError(.failed, "exit 1") }
            ev(.step, "step: install things (a b c)", ms: 30_000)
        }, prepared: { _, _ in false })
        func status() async throws -> PreparationInfo {
            try await c.handle(HostRequest(.prepareStatus)).result!.decode(PrepareStatus.self).preparations.first!
        }
        func start() async {
            var r = HostRequest(.prepare)
            r.images = ["lab"]
            r.follow = false
            _ = await c.handle(r)
            try? await Task.sleep(for: .milliseconds(200))
        }
        // The first run: a plan, no estimate.
        await start()
        var p = try await status()
        XCTAssertEqual(p.stepIndex, 2, "the kernel done, the install under way")
        XCTAssertEqual(p.plannedSteps, HostCore.plannedSteps("lab"))
        XCTAssertEqual(p.output, (3...8).map { "line \($0)" }, "the last 6 lines")
        XCTAssertEqual(p.steps?.map(\.label), ["kernel ready (vmlinux, cached)"])
        XCTAssertNil(p.remainingSeconds)
        XCTAssertNil(p.stepUsualSeconds)
        XCTAssertEqual(p.estimateBasis, "first time: no estimate yet")
        gate.lock.withLock { gate.released = true }
        try await Task.sleep(for: .milliseconds(300))
        let rec = try XCTUnwrap(PreparationRecord.all(DozerStore(root: root))["lab"])
        XCTAssertEqual(rec.steps.map(\.key), ["kernel", "step: install things"])
        XCTAssertEqual(rec.steps.map(\.seconds), [2, 30])
        // The second run: M from the last run, estimates from its times.
        gate.lock.withLock { gate.released = false }
        await start()
        p = try await status()
        XCTAssertEqual(p.plannedSteps, 2)
        XCTAssertEqual(p.stepIndex, 2)
        XCTAssertEqual(p.stepUsualSeconds, 30)
        let left = try XCTUnwrap(p.remainingSeconds)
        XCTAssertTrue(left > 29 && left <= 30, "about the install's 30 s, less what it has run: \(left)")
        XCTAssertEqual(p.steps?.first?.usualSeconds, 2)
        XCTAssertTrue(p.estimateBasis?.hasPrefix("from this store's last preparation of lab") == true)
        // A failed step: ✕ with its last output.
        gate.lock.withLock { gate.fail = true; gate.released = true }
        try await Task.sleep(for: .milliseconds(300))
        p = try await status()
        XCTAssertEqual(p.state, "failed")
        let failed = try XCTUnwrap(p.steps?.last)
        XCTAssertEqual(failed.kind, "failed")
        XCTAssertEqual(failed.output?.count, 6)
        XCTAssertEqual(failed.output?.last, "line 8")
        XCTAssertEqual(PreparationRecord.all(DozerStore(root: root))["lab"]?.steps.count, 2, "a failed run does not replace the record")
        XCTAssertEqual(PreparationRecord.key("base image node (cached)"), PreparationRecord.key("pulled the base image node"))
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
        XCTAssertEqual(inst.libexec.path, libexec.resolvingSymlinksInPath().path)
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

    /// 594 W28: the facts never claim sudo the guest lacks (a system disk from an older image).
    func testTheFactsFollowTheSudoBinary() throws {
        var spec = SandboxSpec(name: "s", storeRoot: root)
        spec.imageSpec = AgentImages.claudeCode
        let cfg = SandboxConfig(name: "s", image: "claude-code", spec: spec, workspace: nil)
        let on = DozerSettings(text: nil)
        let has = try XCTUnwrap(AgentPrompt.report(config: cfg, policy: nil, account: nil, version: "1", settings: on, hostname: "h", sudoInstalled: true)?.text)
        XCTAssertTrue(has.contains("- System: you have passwordless sudo"))
        let lacks = try XCTUnwrap(AgentPrompt.report(config: cfg, policy: nil, account: nil, version: "1", settings: on, hostname: "h", sudoInstalled: false)?.text)
        XCTAssertTrue(lacks.contains("- System: no sudo: this sandbox's system disk was made from an older claude-code image that has no sudo"), lacks)
        XCTAssertTrue(lacks.contains("doz image bake claude-code") && lacks.contains("doz reset s"))
        XCTAssertFalse(lacks.contains("passwordless sudo in this sandbox"))
        let off = DozerSettings(text: "[sandbox]\nagent_sudo = false\n")
        let no = try XCTUnwrap(AgentPrompt.report(config: cfg, policy: nil, account: nil, version: "1", settings: off, hostname: "h", sudoInstalled: true)?.text)
        XCTAssertTrue(no.contains("- System: no sudo: you run as an unprivileged user"))
    }

    /// 594 W12: doz_project.yaml says when each key applies and what each network means, and still parses.
    func testTheProjectFileSaysWhenEachKeyApplies() throws {
        let p = DozerProject(name: "web", image: "claude-code", cpus: 4, memoryMiB: 4096, network: "agent")
        let text = p.render()
        for s in ["image (agent, base, dockerfile), cpus, memory, network nat/none: when the sandbox is MADE", "network agent/bake/locked/open: at the next doz up, live",
                  "account: doz account use NAME ACCOUNT", "sessions: every doz up", "#   locked — proxied: nothing leaves the sandbox",
                  "#   nat    — a real network interface", "cpus: 4                     # when made"] {
            XCTAssertTrue(text.contains(s), s)
        }
        let back = try DozerProject.parse(text)
        XCTAssertEqual(back.cpus, 4)
        XCTAssertEqual(back.memoryMiB, 4096)
        XCTAssertEqual(back.image, "claude-code")
        XCTAssertEqual(try DozerProject.parse(DozerProject(name: "a", image: "lab").render()).image, "lab")
    }

    /// 594 W10: the sandboxes' time zone — the Mac's (read now) or the setting's; the facts say it.
    func testTheTimeZoneFollowsTheMacOrTheSetting() throws {
        let none = DozerSettings(text: nil)
        XCTAssertEqual(HostCore.guestTimeZone(settings: none, environment: ["DOZ_TEST_MAC_TIMEZONE": "Australia/Sydney"])?.name, "Australia/Sydney")
        let file = root.appendingPathComponent("tz")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "America/New_York\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(HostCore.guestTimeZone(settings: none, environment: ["DOZ_TEST_MAC_TIMEZONE": file.path])?.name, "America/New_York",
                       "the seam's file is read at each look (a wake after the Mac changed zone)")
        XCTAssertEqual(HostCore.guestTimeZone(settings: none, environment: [:])?.name, NSTimeZone.system.identifier, "mac: this Mac's")
        let tokyo = DozerSettings(text: "[sandbox]\ntimezone = \"Asia/Tokyo\"\n")
        XCTAssertEqual(HostCore.guestTimeZone(settings: tokyo, environment: ["DOZ_TEST_MAC_TIMEZONE": "Australia/Sydney"])?.name, "Asia/Tokyo")
        XCTAssertThrowsError(try DozerSettings.definition("sandbox.timezone")!.parse("Mars/Olympus"))
        XCTAssertThrowsError(try DozerSettings.definition("sandbox.timezone")!.parse("../x"))
        XCTAssertNoThrow(try DozerSettings.definition("sandbox.timezone")!.parse("mac"))
        let v = AgentPrompt.values(name: "n", image: "pi", cpus: 1, memoryMiB: 1024, workspace: nil, network: .none, account: nil, version: "1",
                                   hostname: "h", timeZone: "Australia/Sydney")
        XCTAssertTrue(try AgentPrompt.render(AgentPrompt.builtInTemplate, v, source: "b").contains("- Time zone: Australia/Sydney (the Mac's"))
    }

    /// 594 W6: the Images list says what WILL be installed — never a stale pin.
    func testTheImagesListSaysWhatWillBeInstalled() throws {
        let store = DozerStore(root: root)
        try store.ensureDirectory()
        let none = DozerSettings(text: nil)
        XCTAssertEqual(Onboarding.agentVersionText("claude-code", store: store, settings: none), "latest", "never asked: latest")
        XCTAssertNil(Onboarding.agentVersionText("lab", store: store, settings: none))
        AgentVersions.update("claude-code", store) { $0.latest = AgentRelease(version: "2.1.285", integrity: "sha512-x") }
        XCTAssertEqual(Onboarding.agentVersionText("claude-code", store: store, settings: none), "latest (2.1.285)")
        let exact = DozerSettings(text: "[images]\nclaude_code_version = \"2.1.227\"\n")
        XCTAssertEqual(Onboarding.agentVersionText("claude-code", store: store, settings: exact), "2.1.227")
        let opts = Onboarding.imageOptions([], versions: ["claude-code": "latest (2.1.285)"])
        XCTAssertEqual(opts.first?.summary, "Claude Code — latest (2.1.285) — on Debian (node), with git, ripgrep, python3 and the usual tools")
        XCTAssertTrue(opts[1].summary.hasPrefix("the pi coding agent — latest — "))
        XCTAssertFalse(opts.map(\.summary).joined().contains("{version}"))
    }

    /// 594 W23: the agent's passwordless sudo — the setting (default on), a sandbox's own choice over
    /// it, the facts text both ways, doz_project.yaml's agent_sudo, and create's flags.
    func testAgentSudoSettingFactsProjectAndFlags() throws {
        XCTAssertTrue(DozerSettings(text: nil).bool(SettingKey.agentSudo), "on by default (owner ruling)")
        let off = DozerSettings(text: "[sandbox]\nagent_sudo = false\n")
        XCTAssertFalse(off.bool(SettingKey.agentSudo))
        var cfg = SandboxConfig(name: "a", image: "pi", spec: SandboxSpec(name: "a", storeRoot: root), workspace: nil)
        XCTAssertTrue(HostCore.agentSudo(cfg, settings: DozerSettings(text: nil)))
        XCTAssertFalse(HostCore.agentSudo(cfg, settings: off), "nil follows the setting")
        cfg.agentSudo = true
        XCTAssertTrue(HostCore.agentSudo(cfg, settings: off), "the sandbox's own choice wins")
        cfg.agentSudo = false
        XCTAssertFalse(HostCore.agentSudo(cfg, settings: DozerSettings(text: nil)))

        let yes = AgentPrompt.values(name: "n", image: "pi", cpus: 1, memoryMiB: 1024, workspace: nil, network: .proxied(.agent), account: nil, version: "1", hostname: "h")
        XCTAssertEqual(yes["sandbox.sudo"], "yes")
        XCTAssertTrue(yes["sudo.description"]!.hasPrefix("you have passwordless sudo in this sandbox"))
        XCTAssertTrue(yes["sudo.description"]!.contains("The network policy and the credential rules still apply to root"))
        XCTAssertTrue(yes["sudo.description"]!.contains("`doz reset n` or a restore point"))
        let facts = try AgentPrompt.render(AgentPrompt.builtInTemplate, yes, source: "b")
        XCTAssertTrue(facts.contains("- System: you have passwordless sudo"))
        let no = AgentPrompt.values(name: "n", image: "pi", cpus: 1, memoryMiB: 1024, workspace: nil, network: .none, account: nil, version: "1",
                                    hostname: "h", agentSudo: false)
        XCTAssertEqual(no["sandbox.sudo"], "no")
        XCTAssertTrue(no["sudo.description"]!.hasPrefix("no sudo:"))
        XCTAssertTrue(try AgentPrompt.render(AgentPrompt.skillTemplate, no, source: "s").contains("Sudo: no — no sudo:"))

        let p = try DozerProject.parse("version: 1\nname: a\nimage: pi\nagent_sudo: false\n")
        XCTAssertEqual(p.agentSudo, false)
        XCTAssertEqual(p.createOptions(folder: root, file: root.appendingPathComponent("doz_project.yaml")).agentSudo, false)
        XCTAssertNil(try DozerProject.parse("version: 1\nname: a\nimage: pi\n").agentSudo)
        XCTAssertThrowsError(try DozerProject.parse("version: 1\nname: a\nimage: pi\nagent_sudo: maybe\n"))
        XCTAssertTrue(p.render().contains("agent_sudo: false\n"))
        XCTAssertTrue(DozerProject(name: "a", image: "pi").render().contains("# agent_sudo: true"))
        XCTAssertEqual(try DozerProject.parse(p.render()).agentSudo, false, "render → parse round-trips")

        let c = try XCTUnwrap(try DozerCommand.parseAsRoot(["create", "b", "--image", "pi", "--no-agent-sudo"]) as? Create)
        XCTAssertEqual(try c.create.options().agentSudo, false)
        let d = try XCTUnwrap(try DozerCommand.parseAsRoot(["create", "b", "--image", "pi"]) as? Create)
        XCTAssertNil(try d.create.options().agentSudo, "no flag: the setting decides")
    }
}
