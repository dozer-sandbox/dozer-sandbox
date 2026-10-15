import Foundation
@testable import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost

/// 617: Gemini CLI and Grok Build in the host, without a VM, a real keychain or the network — names, settings,
/// sessions, `key` accounts per provider, the vault of a new sandbox (never an Anthropic binding), D5's policy, the
/// environment prompt's context file, versions — and acceptance 9: a test-only recipe gets all of it with no Swift.
final class RecipeHostTests: XCTestCase {
    private var root: URL!
    let keychain = FakeKeychain()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-recipe-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func core() async -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: DozerStore(root: root), readOnly: false, version: "test", services: s)
        await c.load()
        return c
    }

    func create(_ c: HostCore, _ name: String, image: String, account: String? = nil, network: String? = nil) async -> HostMessage {
        var r = HostRequest(.create, name: name)
        r.create = CreateOptions(image: image, network: network, account: account)
        return await c.handle(r)
    }

    // MARK: names, settings, sessions

    func testTheNewAgentsHaveNamesSettingsAndSessions() throws {
        XCTAssertEqual(ImageChoice.parse("gemini"), ImageChoice(base: "node", agent: AgentKind(rawValue: "gemini")!))
        XCTAssertEqual(ImageChoice.parse("grok"), ImageChoice(base: "debian", agent: AgentKind(rawValue: "grok")!))
        XCTAssertEqual(ImageChoice.parse("debian-grok")?.name, "grok", "the long form of the default pair")
        XCTAssertEqual(Workspace.baseName(image: "grok"), "grok-sandbox")
        XCTAssertEqual(Workspace.baseName(image: "python-gemini"), "python-gemini-sandbox")
        XCTAssertEqual(DozerSettings.imageSection(imageSpecName: "python-grok"), "grok")
        XCTAssertEqual(SettingKey.agentVersion("gemini"), "images.gemini_version")
        for k in ["images.gemini_version", "images.grok_version", "gemini.permissions", "grok.permissions", "images.grok.memory_mib", "images.gemini.network"] {
            XCTAssertNotNil(DozerSettings.definition(k), k)
        }
        let ask = DozerSettings(text: "[gemini]\npermissions = \"ask\"\n")
        XCTAssertEqual(HostCore.withClaudePermissions([:], imageSpec: "python-gemini", settings: ask), ["DOZ_GEMINI_PERMISSIONS": "ask"])
        XCTAssertEqual(HostCore.withClaudePermissions(["DOZ_GEMINI_PERMISSIONS": "skip"], imageSpec: "gemini", settings: ask), ["DOZ_GEMINI_PERMISSIONS": "skip"],
                       "never over the caller's own")
        XCTAssertEqual(HostCore.withClaudePermissions([:], imageSpec: "grok", settings: ask), [:])
        XCTAssertEqual(SessionResume.arguments(for: AgentKind(rawValue: "gemini")), ["--resume", "latest"])
        XCTAssertEqual(SessionResume.arguments(for: AgentKind(rawValue: "grok")), [])
        func project(_ agent: String, base: String? = nil) -> DozerProject {
            var p = DozerProject(name: "x", image: "lab")
            p.agent = agent
            p.base = base
            return p
        }
        XCTAssertEqual(project("grok").chosenImage, "grok", "the agent's own default base")
        XCTAssertEqual(project("gemini", base: "python").chosenImage, "python-gemini")
        XCTAssertNil(project("grok").problem())
        XCTAssertEqual(project("nope").problem(), "agent: " + DozerProject.agentWords)
        XCTAssertTrue(DozerProject.agentWords.hasPrefix("claude-code, pi, codex, antigravity, gemini, grok"))
    }

    func testCreateArgumentsTakeTheNewAgentsAndTheirDefaultBase() throws {
        func image(_ args: [String]) throws -> String? { try Create.parse(["x"] + args).create.chosenImage() }
        XCTAssertEqual(try image(["--agent", "grok"]), "grok")
        XCTAssertEqual(try image(["--agent", "gemini"]), "gemini")
        XCTAssertEqual(try image(["--agent", "grok", "--base", "alpine"]), "alpine-grok")
        XCTAssertEqual(try image(["--agent", "claude"]), "claude-code", "an alias, as before")
        XCTAssertEqual(try image(["--agent", "pi"]), "pi", "Node, as before")
        XCTAssertThrowsError(try image(["--agent", "grokk"]))
    }

    /// The statistics' closed list has every agent (the Worker's matches it — 617.01 §5.1).
    func testEveryAgentIsInTheUsageVocabulary() {
        for a in AgentKind.allCases { XCTAssertTrue(UsageSchema.agents.contains(a.rawValue), a.rawValue) }
    }

    // MARK: accounts

    func testAKeyAccountPerProvider() async throws {
        let c = await core()
        var m = await c.handle(HostRequest.keyAccountAdd(name: "work-xai", provider: "xai", secret: "xai-FAKE-0123456789abcdef"))
        XCTAssertNil(m.error, m.error?.message ?? "")
        m = await c.handle(HostRequest.keyAccountAdd(name: "g", provider: "google", secret: "AIzaFAKE0123456789abcdef"))
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertEqual(keychain.read(service: "doz-xai:work-xai", account: Keychain.user).value, "xai-FAKE-0123456789abcdef")
        XCTAssertEqual(keychain.read(service: "doz-google:g", account: Keychain.user).value, "AIzaFAKE0123456789abcdef")
        let file = try String(contentsOf: root.appendingPathComponent("accounts.json"), encoding: .utf8)
        XCTAssertFalse(file.contains("FAKE"), "accounts.json holds no secret")
        let accounts = AccountStore(store: DozerStore(root: root)).load()
        XCTAssertEqual(accounts.providerDefaults, ["xai": "work-xai", "google": "g"], "the first key of a provider is its default")
        let rows = try XCTUnwrap(m.result).decode([AccountRow].self)
        XCTAssertEqual(rows.first { $0.name == "work-xai" }?.provider, "xai")
        XCTAssertEqual(rows.first { $0.name == "work-xai" }?.isDefault, true)
        XCTAssertEqual(accounts.defaultAccount, "mac", "the Anthropic default is untouched")
        // A provider that is not a key provider, and none at all, are refused.
        m = await c.handle(HostRequest.keyAccountAdd(name: "x", provider: "anthropic", secret: "sk-ant-FAKE0123456789abcdef"))
        XCTAssertNotNil(m.error)
        // Removing it removes its keychain item and its default.
        var rm = HostRequest(.accountRemove)
        rm.account = "g"
        m = await c.handle(rm)
        XCTAssertNil(m.error)
        XCTAssertNil(keychain.read(service: "doz-google:g", account: Keychain.user).value)
        XCTAssertNil(AccountStore(store: DozerStore(root: root)).load().providerDefaults?["google"])
    }

    func testAnOldAccountsFileDecodesUnchanged() throws {
        let old = #"{"version":1,"defaultAccount":"work","keepalive":false,"accounts":[{"name":"work","kind":"api-key","keychainService":"doz-anthropic:work","addedAt":"2026-09-01T00:00:00Z"}]}"#
        try Data(old.utf8).write(to: root.appendingPathComponent("accounts.json"))
        let f = AccountStore(store: DozerStore(root: root)).load()
        XCTAssertEqual(f.defaultAccount, "work")
        XCTAssertNil(f.providerDefaults)
        XCTAssertNil(f.accounts.first { $0.name == "work" }?.provider)
        XCTAssertEqual(f.accounts.first { $0.name == "work" }?.binding, .anthropic)
    }

    func testCreateProblemsSayWhatToRun() {
        let kinds: [String: AccountKind] = ["mac": .mac, "work": .apiKey, "x1": .key, "g1": .key]
        let providers = ["x1": "xai", "g1": "google"]
        let none = AgentCredentials.createProblem(image: "grok", account: nil, defaultAccount: "mac", kinds: kinds)
        XCTAssertEqual(none, "Grok Build needs an xAI API key — the store has no default xAI account. Add one: doz account add NAME --provider xai (then create with --account NAME)")
        XCTAssertNil(AgentCredentials.createProblem(image: "grok", account: nil, defaultAccount: "mac", kinds: kinds, providers: providers, providerDefaults: ["xai": "x1"]))
        XCTAssertNil(AgentCredentials.createProblem(image: "grok", account: "x1", defaultAccount: "mac", kinds: kinds, providers: providers))
        let wrong = AgentCredentials.createProblem(image: "grok", account: "g1", defaultAccount: "mac", kinds: kinds, providers: providers)
        XCTAssertEqual(wrong, "Grok Build can't use the account g1 (a Google AI (Gemini API) key) — Grok Build needs an xAI API key. Use one: --account x1 — or add one: doz account add NAME --provider xai")
        XCTAssertNotNil(AgentCredentials.createProblem(image: "gemini", account: "work", defaultAccount: "mac", kinds: kinds, providers: providers),
                        "an Anthropic key is never Gemini's")
        XCTAssertNotNil(AgentCredentials.createProblem(image: "python-gemini", account: "mac", defaultAccount: "mac", kinds: kinds, providers: providers))
        XCTAssertNotNil(AgentCredentials.createProblem(image: "claude-code", account: "x1", defaultAccount: "mac", kinds: kinds, providers: providers),
                        "a key is never Claude Code's")
        XCTAssertEqual(AgentCredentials.requirement("gemini"), "Gemini CLI needs a Google AI (Gemini API) key")
    }

    // MARK: a sandbox of a key agent

    func testAGrokSandboxGetsItsKeyOnlyAndReachesOnlyItsModel() async throws {
        let c = await core()
        _ = await c.handle(HostRequest.keyAccountAdd(name: "work-xai", provider: "xai", secret: "xai-FAKE-0123456789abcdef"))
        _ = await c.handle(HostRequest.accountAdd(name: "work", kind: .apiKey, plan: nil, secret: "sk-ant-api03-FAKE0123456789abcdef"))
        let m = await create(c, "gk", image: "grok", network: "locked")
        XCTAssertNil(m.error, m.error?.message ?? "")
        let v = try await XCTUnwrapAsync(await c.vault(of: "gk"))
        XCTAssertTrue(v.hasSecret("key:xai"))
        let env = v.sessionEnvironment()
        XCTAssertEqual(Set(env.keys), ["XAI_API_KEY"], "never an Anthropic binding in a Grok sandbox")
        XCTAssertTrue(env["XAI_API_KEY"]!.hasPrefix("doz_cred_"))
        let pol = try await XCTUnwrapAsync(await c.effectiveNetworkPolicy(of: "gk"))
        XCTAssertEqual(pol.permissions, ["model:xai"], "D5: Locked = its own model only")
        XCTAssertEqual(pol.evaluateConnection(host: "api.anthropic.com", port: 443).kind, .deny)
        XCTAssertEqual(pol.evaluateConnection(host: "x.ai", port: 443).kind, .allow, "xAI's own site: its release notes at start-up")
        XCTAssertEqual(pol.evaluateConnection(host: "auth.x.ai", port: 443).kind, .deny, "its sign-in stays kept out")
        // The default network (Standard): its own model, no Anthropic model, its exclusions.
        let s = await create(c, "gk2", image: "grok")
        XCTAssertNil(s.error, s.error?.message ?? "")
        let std = try await XCTUnwrapAsync(await c.effectiveNetworkPolicy(of: "gk2"))
        XCTAssertTrue(std.permissions?.contains("model:xai") == true)
        XCTAssertFalse(std.permissions?.contains("model") == true)
        XCTAssertEqual(std.preset, "agent")
        // A Google key is refused for it.
        _ = await c.handle(HostRequest.keyAccountAdd(name: "g", provider: "google", secret: "AIzaFAKE0123456789abcdef"))
        let bad = await create(c, "gk3", image: "grok", account: "g")
        XCTAssertTrue(bad.error?.message.contains("can't use the account g") == true, bad.error?.message ?? "")
    }

    func testAKeySandboxWithNoKeyIsRefusedAtCreate() async throws {
        let c = await core()
        let m = await create(c, "gm", image: "gemini")
        XCTAssertTrue(m.error?.message.contains("Gemini CLI needs a Google AI (Gemini API) key") == true, m.error?.message ?? "")
        let ok = await create(c, "gm", image: "gemini", account: "none")
        XCTAssertNil(ok.error, "--account none on purpose is allowed")
        let v = try await XCTUnwrapAsync(await c.vault(of: "gm"))
        XCTAssertFalse(v.hasSecret("key:google"))
        XCTAssertNil(v.sessionEnvironment()["ANTHROPIC_API_KEY"])
    }

    func testGrantsAnExcludedSiteOrAnthropicsModelAreRefused() throws {
        let grok = try XCTUnwrap(AgentKind(rawValue: "grok"))
        let p = NetworkPolicy.permissions(AgentPermissions.normalized(["model:xai", "update"]))
        XCTAssertThrowsError(try PermissionPolicy.edited(p, grant: ["site:auth.x.ai"], revoke: [], base: "debian", agent: grok))
        XCTAssertThrowsError(try PermissionPolicy.edited(p, grant: ["model"], revoke: [], base: "debian", agent: grok))
        XCTAssertThrowsError(try PermissionPolicy.edited(p, grant: [], revoke: ["model:xai"], base: "debian", agent: grok))
        let e = try PermissionPolicy.edited(p, grant: ["web"], revoke: [], base: "debian", agent: grok)
        XCTAssertEqual(e.evaluateConnection(host: "cli-chat-proxy.grok.com", port: 443).kind, .deny, "kept out, the web or not")
        // The checklist and the facts: no Anthropic model, no hidden update:<id>, the agent's own model shown.
        let report = PermissionPolicy.report(name: "gk", policy: e, base: "debian",
                                             log: [ConnectionRecord(kind: .connect, host: "auth.x.ai", port: 443, verdict: .denied, rule: "x")])
        XCTAssertFalse(report.permissions.contains { $0.id == "model" || $0.id.hasPrefix("update:") })
        XCTAssertTrue(report.permissions.contains { $0.id == "model:xai" && $0.on })
        XCTAssertTrue(report.suggestions.isEmpty, "an excluded host is never suggested")
        let facts = PermissionPolicy.facts(e, sandbox: "gk")
        XCTAssertTrue(facts.contains("talk to your AI model (xAI)"), facts)
        XCTAssertFalse(facts.contains("talk to your AI model,"), facts)
    }

    // MARK: the environment prompt

    func testTheFactsGoToTheAgentsOwnContextFile() throws {
        for (agent, path) in [("gemini", "/home/agent/.gemini/extensions/dozer/DOZER.md"), ("grok", "/home/agent/.grok/rules/dozer.md")] {
            XCTAssertEqual(AgentPrompt.contextFile(agent: agent, home: "/home/agent")?.path, path)
            let on = AgentPromptReport(enabled: true, agent: agent, text: "FACTS", error: nil, layers: [], skill: "SKILL", promptPath: AgentPrompt.guestPromptPath, skillPath: path)
            let s = AgentPrompt.deliveryScript(on, user: "agent")
            XCTAssertTrue(s.contains("cp '/run/dozer/agent-prompt.md' '\(path)'"), s)
            XCTAssertTrue(s.contains("install -d -o 'agent' -g 'agent'"), "folders it makes are the user's")
            XCTAssertFalse(s.contains("/workspace"), "never the workspace")
            let off = AgentPromptReport(enabled: false, agent: agent, text: nil, error: nil, layers: [], skill: nil, promptPath: AgentPrompt.guestPromptPath, skillPath: path)
            let o = AgentPrompt.deliveryScript(off, user: "agent")
            XCTAssertFalse(o.contains("rm -rf"), "off removes only Dozer's own files: \(o)")
            XCTAssertTrue(o.contains("'\(path)'"))
        }
        let g = AgentPrompt.deliveryScript(AgentPromptReport(enabled: true, agent: "gemini", text: "F", error: nil, layers: [], skill: nil,
                                                             promptPath: AgentPrompt.guestPromptPath, skillPath: "/home/agent/.gemini/extensions/dozer/DOZER.md"), user: "agent")
        XCTAssertTrue(g.contains("/home/agent/.gemini/extensions/dozer/gemini-extension.json"), "Gemini loads an extension only with its manifest")
        let manifest = try XCTUnwrap(AgentPrompt.contextFile(agent: "gemini", home: "/home/agent")?.manifest?.text)
        XCTAssertTrue(manifest.contains("\"contextFileName\" : \"DOZER.md\""), manifest)
        // The credentials sentence names the provider and its placeholder variable.
        let v = AgentPrompt.values(name: "gk", image: "grok", cpus: 2, memoryMiB: 2048, workspace: nil, network: .proxied(.permissions(["model:xai"])),
                                   account: "work-xai", version: "t", hostname: "mac", agent: "grok")
        XCTAssertEqual(v["credentials.description"], "the Mac's proxy puts the account's key (work-xai) into your requests to xAI on the way out; the value in XAI_API_KEY is a placeholder — that is expected; never log in, and never ask the user for a key.")
        XCTAssertEqual(v["agent.state"], "`~/.grok`")
    }

    // MARK: versions

    func testGrokResolvesItsVersionFromTheMainPackage() async throws {
        let store = DozerStore(root: root)
        let asked = Box()
        let registry = NpmRegistry(lookup: { p, tag in
            asked.append("\(p)@\(tag)")
            if p == "@xai-official/grok" && tag == "latest" { return AgentRelease(version: "1.0.60", integrity: "sha512-TUFJTg==") }
            if p == "@xai-official/grok-linux-arm64" && tag == "1.0.60" { return AgentRelease(version: "1.0.60", integrity: "sha512-UExBVA==") }
            throw HostError(.notFound, "unexpected \(p)@\(tag)")
        })
        let f = await AgentVersions.refresh("grok", store: store, settings: DozerSettings(text: ""), registry: registry, force: true)
        XCTAssertNil(f.error, f.error ?? "")
        XCTAssertEqual(asked.items, ["@xai-official/grok@latest", "@xai-official/grok-linux-arm64@1.0.60"], "never the platform package's own (stale) latest")
        XCTAssertEqual(AgentVersions.all(store)["grok"]?.latest, AgentRelease(version: "1.0.60", integrity: "sha512-UExBVA=="))
        let spec = try XCTUnwrap(try AgentVersions.spec("grok", purpose: .prepare, store: store, settings: DozerSettings(text: "")))
        XCTAssertEqual(spec.agent, AgentPackage(package: "@xai-official/grok", version: "1.0.60", integrity: "sha512-UExBVA=="))
        XCTAssertEqual(AgentVersions.known("grok", version: "1.0.52", store: store), AgentRecipes.recipe("grok")?.pinnedRelease, "the pin is known")
    }

    // MARK: acceptance 9 — a recipe and no Swift

    func testATestOnlyRecipeGetsEverythingWithNoSwiftChange() throws {
        let data = try Data(contentsOf: Pins.packageRoot.appendingPathComponent("Tests/Fixtures/agents/echo-agent.json"))
        let r = try AgentRecipes.decode(data)
        try AgentRecipes.registerForTests(r)
        defer { AgentRecipes.unregisterForTests("echo-agent") }
        let a = try XCTUnwrap(AgentKind(rawValue: "echo-agent"))
        XCTAssertTrue(AgentKind.allCases.contains(a))
        // An image on its default base, and on another.
        let spec = try XCTUnwrap(AgentImages.spec("echo-agent", release: try XCTUnwrap(r.pinnedRelease)))
        XCTAssertEqual(spec.name, "echo-agent")
        XCTAssertTrue(spec.steps.contains { $0.name == "install the doz echo-agent launcher" })
        XCTAssertNoThrow(try ImageComposer.spec(name: "python-echo-agent", base: BaseCatalogue.base("python")!.source(), agent: a, release: r.pinnedRelease, native: nil))
        // A credential binding (its provider's), a model permission, settings keys, a default session.
        XCTAssertEqual(AgentCredentials.keyProvider("echo-agent")?.id, "xai")
        XCTAssertEqual(AgentPermissions.agentPermissions(a), ["model:echo"])
        XCTAssertNotNil(AgentPermissions.permission("model:echo"))
        XCTAssertNotNil(DozerSettings.definition("images.echo-agent.memory_mib"))
        XCTAssertNotNil(DozerSettings.definition("images.echo_agent_version"))
        XCTAssertNotNil(DozerSettings.definition("echo-agent.permissions"))
        let (s, _) = try DozerImages.spec(name: "e", options: CreateOptions(image: "echo-agent", network: "locked"), store: DozerStore(root: root), environment: [:])
        XCTAssertEqual(SandboxConfig(name: "e", image: "echo-agent", spec: s, workspace: nil).defaultSession.argv, ["echo-agent"])
        XCTAssertEqual(s.network.policy?.permissions, ["model:echo"])
        XCTAssertEqual(r.capabilityTags.first { $0.tag == "multi-vendor-models" }?.level, "unknown")
        // Gone when unregistered.
        AgentRecipes.unregisterForTests("echo-agent")
        XCTAssertNil(AgentKind(rawValue: "echo-agent"))
        XCTAssertNil(DozerSettings.definition("echo-agent.permissions"))
    }
}

/// A thread-safe list (a fake registry's calls).
final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [String] = []
    var items: [String] { lock.withLock { _items } }
    func append(_ s: String) { lock.withLock { _items.append(s) } }
}
