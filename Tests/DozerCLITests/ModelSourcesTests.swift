import Foundation
@testable import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost

/// 617 (models@1, owner: "add OpenAI and Anthropic AND gateway support"): a recipe says which API shapes it speaks; Dozer
/// offers every provider and gateway that serves one, maps the choice onto the tool's own settings, and keeps the key's
/// destination its own — without a VM, a real keychain or the network. ShellGPT (OpenAI's chat shape) is the example.
final class ModelSourcesTests: XCTestCase {
    private var root: URL!
    let keychain = FakeKeychain()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-models-\(UUID().uuidString.prefix(8))")
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

    var sgpt: AgentRecipe { AgentRecipes.recipe("shell-gpt")! }

    // MARK: the data

    func testEveryProviderAndGatewayIsAModelSourceWithEndpoints() throws {
        XCTAssertEqual(ModelSources.ids, ["anthropic", "openai", "xai", "google", "google-stitch", "openrouter", "vercel-ai-gateway"])
        XCTAssertEqual(ModelSources.ids.filter(ModelSources.isGateway), ["openrouter", "vercel-ai-gateway"])
        // Google Stitch's key is a service's (a hosted design tool), not a model's: it serves no shape, so no recipe is
        // ever offered it as a model source — only the Stitch CLI, whose credential it is.
        XCTAssertTrue(ModelSources.endpoints("google-stitch").isEmpty)
        XCTAssertEqual(AgentRecipes.all.filter { $0.offeredSources.contains("google-stitch") }.map(\.id), ["stitch"])
        for id in ModelSources.ids where id != "google-stitch" {
            XCTAssertFalse(ModelSources.endpoints(id).isEmpty, "\(id) serves a shape")
            for e in ModelSources.endpoints(id) {
                let host = try XCTUnwrap(URL(string: e.baseUrl)?.host)
                XCTAssertTrue(ModelSources.hosts(id).contains(host), "\(id)'s base URL is on its own hosts — its key goes nowhere else")
                XCTAssertTrue(ModelSelection.isModelID(e.defaultModel ?? ""), "\(id) has a default model")
            }
        }
        // A gateway's model ids are creator/name; the coding-agent variants are not offered to recipes.
        XCTAssertTrue(ModelSources.endpoints("openrouter").allSatisfy { $0.defaultModel!.contains("/") })
        XCTAssertFalse(ModelSources.endpoints("vercel-ai-gateway").contains { $0.id == "claude-code" || $0.id == "codex" })
        // The key kinds: never a subscription.
        XCTAssertEqual(ModelSources.accountKind("anthropic"), "api-key")
        XCTAssertEqual(ModelSources.accountKind("openai"), "openai-key")
        XCTAssertEqual(ModelSources.accountKind("openrouter"), "key")
    }

    func testWhatARecipeIsOfferedAndWhatAChoiceDoes() throws {
        XCTAssertEqual(sgpt.offeredSources, ["xai", "openai", "google", "openrouter", "vercel-ai-gateway"],
                       "its default first; Anthropic serves no OpenAI shape, so it is not offered")
        let or = try XCTUnwrap(sgpt.selection(source: "openrouter"))
        XCTAssertEqual(or.shape, "openai-chat")
        XCTAssertEqual(or.env, ["API_BASE_URL": "https://openrouter.ai/api/v1", "DEFAULT_MODEL": "openai/gpt-5.4-mini"])
        XCTAssertEqual(or.keyEnv, ["OPENAI_API_KEY"])
        XCTAssertEqual(sgpt.selection(source: "google")?.env["API_BASE_URL"], "https://generativelanguage.googleapis.com/v1beta/openai",
                       "Google through its OpenAI-compatible endpoint")
        XCTAssertEqual(sgpt.selection(source: "vercel-ai-gateway", model: "anthropic/claude-sonnet-4.6")?.env["DEFAULT_MODEL"], "anthropic/claude-sonnet-4.6")
        XCTAssertNil(sgpt.selection(source: "anthropic"), "not offered")
        // An agent without models@1: its one provider, no selection (the built-in three included).
        for id in ["claude-code", "codex", "gemini"] {
            let r = try XCTUnwrap(AgentRecipes.recipe(id))
            XCTAssertNil(r.models)
            XCTAssertEqual(r.offeredSources, r.credentials.map(\.provider))
            XCTAssertNil(r.selection(source: r.credentials[0].provider))
        }
    }

    func testTheKeyBindingIsTheSourcesOwnWithTheToolsName() throws {
        let b = sgpt.keyBinding(try XCTUnwrap(KeyProviders.provider("openrouter")))
        XCTAssertEqual(b.id, "key:openrouter")
        XCTAssertEqual(b.hosts, ["openrouter.ai"], "a recipe never adds a host for a key")
        XCTAssertEqual(b.placeholderVariables, ["OPENROUTER_API_KEY", "OPENAI_API_KEY"])
        let o = sgpt.keyBinding(try XCTUnwrap(KeyProviders.provider("openai")))
        XCTAssertEqual(o.hosts, ["api.openai.com"])
        XCTAssertEqual(o.placeholderVariables, ["OPENAI_API_KEY"], "the tool's name is the source's own: once")
    }

    func testAccountsBySource() {
        XCTAssertTrue(AgentCredentials.accepts("shell-gpt", .key, provider: "openrouter"))
        XCTAssertTrue(AgentCredentials.accepts("shell-gpt", .openaiKey))
        XCTAssertFalse(AgentCredentials.accepts("shell-gpt", .apiKey), "Anthropic is not offered to it")
        XCTAssertFalse(AgentCredentials.accepts("shell-gpt", .chatgpt), "never a ChatGPT sign-in")
        XCTAssertFalse(AgentCredentials.accepts("shell-gpt", .codexMac))
        XCTAssertFalse(AgentCredentials.accepts("shell-gpt", .mac), "never a Claude subscription")
        XCTAssertFalse(AgentCredentials.accepts("shell-gpt", .key, provider: "anthropic"))
        // Codex keeps its own flow; Claude Code and pi theirs.
        XCTAssertTrue(AgentCredentials.codexFlow("codex"))
        XCTAssertFalse(AgentCredentials.codexFlow("shell-gpt"))
        XCTAssertTrue(AgentCredentials.accepts("codex", .chatgpt))
        XCTAssertTrue(AgentCredentials.accepts("claude-code", .mac))
        XCTAssertFalse(AgentCredentials.accepts("pi", .mac))
        XCTAssertEqual(AgentCredentials.requirement("shell-gpt"),
                       "ShellGPT needs an xAI API key, an OpenAI API key, a Google AI (Gemini API) key, an OpenRouter key or a Vercel AI Gateway key")
    }

    func testTheAccountAChosenSourceUses() {
        var f = AccountsFile()
        var r = AgentCredentials.account(forSource: "openrouter", image: "shell-gpt", account: nil, file: f)
        XCTAssertNil(r.name)
        XCTAssertEqual(r.problem?.text, "there is no OpenRouter key yet")
        XCTAssertEqual(r.problem?.fix, "doz account add NAME --provider openrouter")
        var or1 = AccountRecord(name: "or1", kind: .key, plan: nil)
        or1.provider = "openrouter"
        f.accounts.append(or1)
        XCTAssertEqual(AgentCredentials.account(forSource: "openrouter", image: "shell-gpt", account: nil, file: f).name, "or1", "its only key")
        var or2 = or1
        or2.name = "or2"
        f.accounts.append(or2)
        r = AgentCredentials.account(forSource: "openrouter", image: "shell-gpt", account: nil, file: f)
        XCTAssertEqual(r.problem?.fix, "--account or1 | --account or2")
        f.providerDefaults = ["openrouter": "or2"]
        XCTAssertEqual(AgentCredentials.account(forSource: "openrouter", image: "shell-gpt", account: nil, file: f).name, "or2", "its default")
        f.accounts.append(AccountRecord(name: "oa", kind: .openaiKey, plan: nil))
        f.openaiDefault = "oa"
        XCTAssertEqual(AgentCredentials.account(forSource: "openai", image: "shell-gpt", account: nil, file: f).name, "oa", "the OpenAI default, an OpenAI key")
        XCTAssertEqual(AgentCredentials.account(forSource: "openrouter", image: "shell-gpt", account: "oa", file: f).problem?.text,
                       "the account oa does not hold an OpenRouter key")
        XCTAssertTrue(AgentCredentials.account(forSource: "anthropic", image: "shell-gpt", account: nil, file: f).problem?.text.contains("cannot use Anthropic") == true)
        XCTAssertTrue(AgentCredentials.account(forSource: "nope", image: "shell-gpt", account: nil, file: f).problem?.text.contains("not a provider or gateway") == true)
        XCTAssertNotNil(AgentCredentials.account(forSource: "openrouter", model: "x; rm -rf /", image: "shell-gpt", account: nil, file: f).problem, "a model id only")
        XCTAssertNotNil(AgentCredentials.account(forSource: "xai", image: "grok", account: nil, file: f).problem, "Grok Build has no choice of source")
    }

    // MARK: the plan and the CLI

    func testThePlanSaysTheSourceAndModelAndTheCommandReadsBack() throws {
        var f = AccountsFile()
        var or1 = AccountRecord(name: "or1", kind: .key, plan: nil)
        or1.provider = "openrouter"
        f.accounts.append(or1)
        let facts = PlanFacts(settings: DozerSettings(text: ""), accounts: f, taken: [], images: [], store: DozerStore(root: root),
                              projectsDir: "/tmp/617-pin-projects")
        let choices = try ChoiceOptions.from(["--agent", "shell-gpt", "--gateway", "openrouter", "--model", "anthropic/claude-sonnet-4.6"]).planChoices()
        let p = CreatePlanner.plan(PlanRequest(purpose: "try", create: choices), facts: facts)
        XCTAssertEqual(p.problems.map(\.text), [])
        XCTAssertEqual(p.account?.name, "or1")
        XCTAssertEqual(p.model?.source, "openrouter")
        XCTAssertEqual(p.model?.model, "anthropic/claude-sonnet-4.6")
        XCTAssertEqual(p.model?.offered.map(\.id), ["xai", "openai", "google", "openrouter", "vercel-ai-gateway"])
        XCTAssertEqual(p.reach.first?.text, "Model: anthropic/claude-sonnet-4.6 through OpenRouter (openrouter.ai) — its key only ever goes there")
        XCTAssertEqual(p.command, "doz try shell-gpt --gateway openrouter --model anthropic/claude-sonnet-4.6")
        let back = try ChoiceOptions.from(Array(p.argv.dropFirst(3)) + ["--agent", "shell-gpt"]).planChoices()
        XCTAssertEqual(back.modelSource, "openrouter")
        XCTAssertEqual(back.model, "anthropic/claude-sonnet-4.6")
        // 618: pi on a gateway: its key goes to that gateway; Anthropic's hosts stay reachable with no key; on Anthropic the line is as before.
        let model = AgentPermissions.permission("model")!.title
        let pg = CreatePlanner.plan(PlanRequest(purpose: "try", create: try ChoiceOptions.from(["--agent", "pi", "--gateway", "openrouter",
                                                                                                 "--model", "anthropic/claude-sonnet-4.5"]).planChoices()), facts: facts)
        XCTAssertEqual(pg.reach.first?.text, "Model: anthropic/claude-sonnet-4.5 through OpenRouter (openrouter.ai) — its key only ever goes there")
        XCTAssertFalse(pg.reach.contains { $0.text.hasPrefix(model) }, pg.reach.map(\.text).joined(separator: " | "))
        XCTAssertTrue(pg.reach.contains { $0.kind == "model" && $0.text == "Anthropic, pi's default provider (api.anthropic.com, statsig.anthropic.com): reachable; no key goes there on this run" },
                      "still reachable (the permission stays), and said so")
        let pa = CreatePlanner.plan(PlanRequest(purpose: "try", create: try ChoiceOptions.from(["--agent", "pi"]).planChoices()), facts: facts)
        XCTAssertTrue(pa.reach.contains { $0.text.hasPrefix(model) }, pa.reach.map(\.text).joined(separator: " | "))
        // No key of the chosen source: no account, the problem names the fix.
        let none = CreatePlanner.plan(PlanRequest(purpose: "try", create: try ChoiceOptions.from(["--agent", "shell-gpt", "--provider", "openai"]).planChoices()),
                                      facts: facts)
        XCTAssertEqual(none.account?.name, nil)
        XCTAssertEqual(none.account?.provider, "openai")
        XCTAssertEqual(none.problems.map(\.code), ["key"])
        XCTAssertEqual(none.model?.model, "gpt-5.4-mini")
        // The flags are checked: a gateway by --gateway, a provider by --provider.
        XCTAssertThrowsError(try ChoiceOptions.from(["--agent", "shell-gpt", "--provider", "openrouter"]).planChoices())
        XCTAssertThrowsError(try ChoiceOptions.from(["--agent", "shell-gpt", "--gateway", "xai"]).planChoices())
        XCTAssertThrowsError(try ChoiceOptions.from(["--agent", "shell-gpt", "--gateway", "openrouter", "--provider", "xai"]).planChoices())
    }

    // MARK: the host: the vault and the session environment

    func testASandboxOnAGatewayKeyGetsThatKeyOnlyAndTheSettings() async throws {
        let c = await core()
        _ = await c.handle(HostRequest.keyAccountAdd(name: "work-xai", provider: "xai", secret: "xai-FAKE-0123456789abcdef"))
        _ = await c.handle(HostRequest.keyAccountAdd(name: "or", provider: "openrouter", secret: "sk-or-v1-FAKE0123456789abcdef"))
        var r = HostRequest(.create, name: "sg")
        r.create = CreateOptions(image: "shell-gpt", network: "locked")
        r.create?.modelSource = "openrouter"
        r.create?.model = "anthropic/claude-sonnet-4.6"
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
        let v = try await XCTUnwrapAsync(await c.vault(of: "sg"))
        XCTAssertTrue(v.hasSecret("key:openrouter"))
        XCTAssertFalse(v.hasSecret("key:xai"), "the default source's key is not there")
        let env = v.sessionEnvironment()
        XCTAssertEqual(Set(env.keys), ["OPENROUTER_API_KEY", "OPENAI_API_KEY"])
        XCTAssertEqual(env["OPENROUTER_API_KEY"], env["OPENAI_API_KEY"], "one placeholder, the tool's name too")
        let e = try await c.selectionEnvironment("sg")
        XCTAssertEqual(e["API_BASE_URL"], "https://openrouter.ai/api/v1")
        XCTAssertEqual(e["DEFAULT_MODEL"], "anthropic/claude-sonnet-4.6")
        // Every model source's hosts are watched by the leak guard; its key goes to openrouter.ai only.
        let hosts = try await XCTUnwrapAsync(await c.leakGuardHosts(of: "sg"))
        XCTAssertTrue(hosts.isSuperset(of: ["api.x.ai", "api.openai.com", "openrouter.ai", "ai-gateway.vercel.sh", "api.anthropic.com"]))
        // The default sandbox: its xAI key, xAI's settings.
        let d = await RecipeHostTests.createIn(c, "sg2", image: "shell-gpt")
        XCTAssertNil(d.error, d.error?.message ?? "")
        let e2 = try await c.selectionEnvironment("sg2")
        XCTAssertEqual(e2["API_BASE_URL"], "https://api.x.ai/v1")
        XCTAssertEqual(e2["DEFAULT_MODEL"], "grok-4-1-fast")
        // Switching the account switches the source (and drops the other model: it was OpenRouter's).
        _ = await c.handle(HostRequest.accountAdd(name: "oa", kind: .openaiKey, plan: nil, secret: "sk-proj-FAKE0123456789abcdef"))
        var use = HostRequest(.accountUse, name: "sg")
        use.account = "oa"
        let u = await c.handle(use)
        XCTAssertNil(u.error, u.error?.message ?? "")
        let e3 = try await c.selectionEnvironment("sg")
        XCTAssertEqual(e3["API_BASE_URL"], "https://api.openai.com/v1")
        XCTAssertEqual(e3["DEFAULT_MODEL"], "gpt-5.4-mini")
        let v3 = try await XCTUnwrapAsync(await c.vault(of: "sg"))
        XCTAssertTrue(v3.hasSecret("openai"))
        XCTAssertFalse(v3.hasSecret("key:openrouter"))
        // A caller's own value wins.
        let mine = try await c.selectionEnvironment("sg", ["DEFAULT_MODEL": "mine"])
        XCTAssertEqual(mine["DEFAULT_MODEL"], "mine")
    }

    /// 618: pi (built-in) on another source — that source's key only, its hosts through the hidden `sources:pi`, its
    /// model on the session's command line; on Anthropic it keeps its own path and its own model pick.
    func testPiOnAGatewayKey() async throws {
        let c = await core()
        _ = await c.handle(HostRequest.keyAccountAdd(name: "or", provider: "openrouter", secret: "sk-or-v1-FAKE0123456789abcdef"))
        var r = HostRequest(.create, name: "p")
        r.create = CreateOptions(image: "pi", network: "locked")
        r.create?.modelSource = "openrouter"
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
        let v = try await XCTUnwrapAsync(await c.vault(of: "p"))
        XCTAssertTrue(v.hasSecret("key:openrouter"))
        XCTAssertFalse(v.hasSecret("anthropic"))
        XCTAssertEqual(Set(v.sessionEnvironment().keys), ["OPENROUTER_API_KEY"], "pi reads OPENROUTER_API_KEY itself")
        // Anthropic's hosts stay reachable (its shared model permission) but no key goes there: no Anthropic binding, and
        // the OpenRouter placeholder sent there is refused by the leak guard.
        let guarded = try await XCTUnwrapAsync(await c.leakGuardHosts(of: "p"))
        XCTAssertTrue(guarded.contains("api.anthropic.com"))
        let perms = try await c.permissionsOf("p")
        XCTAssertTrue(perms?.contains("sources:pi") == true)
        let args = try await c.builtinModelArguments(of: "p")
        XCTAssertEqual(args, ["--model", "openrouter/openai/gpt-5.4-mini"])
        let pe = try await c.selectionEnvironment("p")
        XCTAssertEqual(pe["DOZ_MODEL"], "openrouter/openai/gpt-5.4-mini")
        // On Anthropic (its default): its own path and its own model — nothing on its command line.
        _ = await c.handle(HostRequest.accountAdd(name: "ak", kind: .apiKey, plan: nil, secret: "sk-ant-api03-FAKE0123456789abcdef"))
        var use = HostRequest(.accountUse, name: "p")
        use.account = "ak"
        let u = await c.handle(use)
        XCTAssertNil(u.error, u.error?.message ?? "")
        let v2 = try await XCTUnwrapAsync(await c.vault(of: "p"))
        XCTAssertTrue(v2.hasSecret("anthropic"))
        XCTAssertFalse(v2.hasSecret("key:openrouter"))
        let none = try await c.builtinModelArguments(of: "p")
        XCTAssertEqual(none, [])
        let watched = try await XCTUnwrapAsync(await c.leakGuardHosts(of: "p"))
        XCTAssertTrue(watched.contains("openrouter.ai"), "its other sources are watched: an Anthropic placeholder sent there is refused")
        // Claude Code and Codex: never.
        XCTAssertNil(AgentCredentials.sources("claude-code"))
        XCTAssertNil(AgentCredentials.sources("codex"))
    }

    func testCreateRefusesASourceItCannotUse() async throws {
        let c = await core()
        var r = HostRequest(.create, name: "sg")
        r.create = CreateOptions(image: "shell-gpt", network: "locked")
        r.create?.modelSource = "openrouter"
        var m = await c.handle(r)
        XCTAssertTrue(m.error?.message.contains("there is no OpenRouter key yet") == true, m.error?.message ?? "")
        r.create?.modelSource = "anthropic"
        m = await c.handle(r)
        XCTAssertTrue(m.error?.message.contains("cannot use Anthropic") == true, m.error?.message ?? "")
        r.create = CreateOptions(image: "gemini", network: "locked")
        r.create?.modelSource = "openai"
        m = await c.handle(r)
        XCTAssertTrue(m.error?.message.contains("no choice of model provider") == true, m.error?.message ?? "")
    }

    // MARK: the recipe's own rules

    func testModelsAreValidated() throws {
        func refused(_ change: (inout AgentRecipe) -> Void, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
            var r = sgpt
            change(&r)
            XCTAssertThrowsError(try r.validate(), why, file: file, line: line) { e in
                XCTAssertTrue("\(e)".contains("models") || "\(e)".contains("model permission"), "\(e)", file: file, line: line)
            }
        }
        XCTAssertNoThrow(try sgpt.validate())
        refused({ $0.models?.default = "openai" }, "the default is its credential's provider")
        refused({ $0.models?.shapes?[0].shape = "smoke-signals" }, "a known shape")
        refused({ $0.models?.shapes?[0].env["OPENAI_API_KEY"] = "x" }, "env names no credential")
        refused({ $0.models?.shapes?[0].env["X"] = "{nope}" }, "only {base_url} and {model}")
        refused({ $0.models?.shapes?[0].keyEnv = ["HOME"] }, "key_env is credential-shaped")
        refused({ $0.models?.except = ["mars"] }, "except names a source")
        refused({ $0.models?.models = ["openrouter": "bad model"] }, "a model id")
        refused({ $0.network.model.hosts?.removeAll { $0.host == "openrouter.ai" } }, "the model permission reaches every offered source")
        refused({ $0.models?.native = [AgentRecipe.Models.NativeEntry(source: "google", env: ["U": "{base_url}"])] }, "a native client has no base URL")
        var b = try XCTUnwrap(AgentRecipes.recipe("claude-code"))
        b.models = AgentRecipe.Models(default: "anthropic", native: [.init(source: "anthropic", env: [:])])
        XCTAssertThrowsError(try b.validate(), "Claude Code and Codex keep their own accounts")
        // 618: pi declares its sources — native only (nothing baked: its image is Dozer's own).
        var pi = try XCTUnwrap(AgentRecipes.recipe("pi"))
        XCTAssertNoThrow(try pi.validate())
        XCTAssertEqual(pi.offeredSources, ["anthropic", "openai", "xai", "google", "openrouter", "vercel-ai-gateway"])
        pi.models?.shapes = [.init(shape: "openai-chat", env: ["X": "{base_url}"])]
        XCTAssertThrowsError(try pi.validate(), "a built-in agent's sources are native only")
    }

    /// 618: an OpenAI-compatible shape is offered the gateways without listing them; what a try can do and what the
    /// gateway entries say never disagree; `verified` only from an entry that says its evidence.
    func testTheGatewaysFollowFromTheShapes() throws {
        var r = sgpt
        r.gateways = []
        r.models?.shapes?[0].source = "https://example.com/docs#base-url"
        XCTAssertNoThrow(try r.validate(), "an offered gateway needs no entry")
        XCTAssertEqual(r.gatewaySupport.map(\.gateway), ["openrouter", "vercel-ai-gateway"])
        XCTAssertEqual(r.gatewaySupport.map(\.level), ["documented", "documented"], "documented, never verified, without evidence")
        XCTAssertEqual(r.gatewaySupport.first?.source, "https://example.com/docs#base-url")
        XCTAssertEqual(r.gatewaySupport.first?.endpoint, "v1")
        XCTAssertTrue(r.throughGateway)
        XCTAssertTrue(r.capabilityTags.contains { $0.tag == "gateway:openrouter" && $0.level == "documented" })
        // An entry overrides (the evidence of a recipe-check run).
        r.gateways = [AgentRecipe.GatewaySupport(gateway: "openrouter", level: "verified", evidence: "make recipe-check", checked: "2026-10-16")]
        XCTAssertNoThrow(try r.validate(), "an override needs no how: models@1 says it")
        XCTAssertEqual(r.gatewaySupport.map(\.level), ["verified", "documented"])
        // Never a contradiction.
        r.gateways = [AgentRecipe.GatewaySupport(gateway: "openrouter", level: "no", reason: "x")]
        XCTAssertThrowsError(try r.validate(), "offered, so not no")
        r.gateways = []
        r.models?.shapes?[0].source = nil
        XCTAssertThrowsError(try r.validate(), "an offered gateway with nothing to cite") { XCTAssertTrue("\($0)".contains("cite"), "\($0)") }
        r.models?.shapes?[0].source = "http://example.com"
        XCTAssertThrowsError(try r.validate(), "an https source")
        // A tool with models@1 that is not offered a gateway says so; it cannot claim one.
        var n = sgpt
        n.models?.except = ["openrouter"]
        n.network.model.hosts?.removeAll { $0.host == "openrouter.ai" }
        n.gateways = sgpt.gateways
        XCTAssertThrowsError(try n.validate(), "verified, but not offered")
        XCTAssertFalse(n.offersGateway("openrouter"))
        // Without models@1 nothing is offered, whatever the entries document (the built-ins).
        let cc = try XCTUnwrap(AgentRecipes.recipe("claude-code"))
        XCTAssertFalse(cc.throughGateway)
    }
}

extension HostCore {
    /// The environment a session of `name` gets from its recipe (models@1 included), over `env`.
    func selectionEnvironment(_ name: String, _ env: [String: String] = [:]) throws -> [String: String] {
        recipeEnvironment(env, try get(name))
    }

    func leakGuardHosts(of name: String) -> Set<String>? { (try? get(name))?.sandbox.egress?.leakGuardHosts }
    func builtinModelArguments(of name: String) throws -> [String] { builtinModelArguments(try get(name)) }
    func permissionsOf(_ name: String) throws -> [String]? { try get(name).config.spec.network.policy?.permissions }
}

extension RecipeHostTests {
    static func createIn(_ c: HostCore, _ name: String, image: String) async -> HostMessage {
        var r = HostRequest(.create, name: name)
        r.create = CreateOptions(image: image)
        return await c.handle(r)
    }
}
