import Foundation
import XCTest
@testable import DozerWeb
@testable import DozerHost
import DozerKit

/// 617 stage D: the Quick try page's server half — `POST /api/v1/plan` (strict), `GET /api/v1/try`, the create action's
/// `trial`, a provider's key on `POST /api/v1/accounts`, and the review's plan.
final class WebTryTests: XCTestCase {
    func q(_ json: String) throws -> WebPlanQuery { try WebPlanQuery.decode(Data(json.utf8)) }

    func testThePlanQuestionIsStrict() throws {
        let t = try q(#"{"purpose":"try","agent":"grok"}"#)
        XCTAssertEqual(t.request.purpose, "try")
        XCTAssertEqual(t.request.create.image, "grok", "the agent's own base (Debian for Grok) names the image as the CLI does")
        XCTAssertEqual(try q(#"{"agent":"gemini","base":"python"}"#).request.create.image, "python-gemini")
        XCTAssertEqual(try q(#"{"agent":"claude"}"#).request.create.image, "claude-code", "an alias")
        XCTAssertEqual(try q(#"{"agent":"grok","isolated":true}"#).request.create.isolated, true)
        XCTAssertEqual(try q(#"{"purpose":"new"}"#).request.create.image, "", "new with no agent: the defaults decide")
        for bad in [#"{"agent":"grok","shell":"rm -rf /"}"#, #"{"purpose":"create","agent":"grok"}"#, #"{"agent":"nope"}"#,
                    #"{"agent":"grok","base":"windows"}"#, #"{"agent":"grok","name":"Bad Name"}"#, #"{"agent":"grok","isolated":"yes"}"#,
                    #"{"purpose":"try"}"#, #"[1]"#] {
            XCTAssertThrowsError(try q(bad), bad)
        }
    }

    func testTheRoutesAreTypedAndAllowed() {
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/plan"), .plan)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/try"), .tryCatalog)
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/plan"), "the plan is a POST (CSRF)")
        XCTAssertEqual(WebExposure.kind(.plan), .change)
        XCTAssertEqual(WebExposure.kind(.tryCatalog), .read)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/try/list"), .tryList)
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/try/list"))
        XCTAssertEqual(WebExposure.kind(.tryList), .read)
    }

    /// 617 (owner: "a blank modal with a considerable delay"): the list alone is the recipes' — the same agents as the
    /// whole catalog, no plan, nothing ready yet (the page draws its cards from it while the plans are read).
    func testTheListAloneHasEveryAgentAndNoPlan() async throws {
        let list = WebTryCatalog.list(secretEntry: true)
        let whole = await WebTryCatalog.build(plan: { r in WebPlan(CreatePlan.sample(name: "try-" + r.create.image, image: r.create.image)) }, secretEntry: true)
        XCTAssertEqual(list.agents.map(\.id), whole.agents.map(\.id))
        XCTAssertEqual(list.coming.map(\.id), whole.coming.map(\.id))
        XCTAssertTrue(list.agents.allSatisfy { $0.plan == nil && $0.card == nil && !$0.ready && $0.usableAccounts.isEmpty })
        XCTAssertTrue(whole.agents.allSatisfy { $0.plan != nil })
        let grok = try XCTUnwrap(list.agents.first { $0.id == "grok" })
        XCTAssertEqual(grok.title, "Grok Build")
        XCTAssertNotNil(grok.icon)
        XCTAssertEqual(list.kinds.map(\.id), ["coding-agent", "ai-tool"], "the page's first draw names these two before the list arrives")
        let json = String(decoding: try JSONEncoder().encode(list), as: UTF8.self)
        XCTAssertFalse(json.contains("\"plan\":{"), "no plan in the list")
    }

    /// The whole catalog asks for every agent's plan in ONE call (the host's `plans`: one reading of the store).
    func testTheWholeCatalogPlansEveryAgentInOneCall() async {
        var calls: [[PlanRequest]] = []
        let catalog = await WebTryCatalog.build(plans: { rs in
            calls.append(rs)
            return rs.map { r in r.create.image == "grok" ? nil : WebPlan(CreatePlan.sample(name: "try-" + r.create.image, image: r.create.image)) }
        }, secretEntry: false)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.count, WebTryCatalog.list(secretEntry: false).agents.count)
        XCTAssertTrue(calls.first?.allSatisfy { $0.purpose == "try" } == true)
        XCTAssertFalse(catalog.agents.contains { $0.id == "grok" }, "one that could not be planned is left out, as before")
    }

    func testTheCatalogComesFromThePlansAndTheRecipes() async throws {
        var asked: [PlanRequest] = []
        let catalog = await WebTryCatalog.build(plan: { r in
            asked.append(r)
            var p = CreatePlan.sample(name: "try-" + r.create.image, image: r.create.image)
            // Grok has no key in this store; the others have one.
            p.problems = r.create.image == "grok"
                ? [PlanProblem(code: "key", text: "Grok Build needs an xAI API key", fix: "doz account add NAME --provider xai")] : []
            return WebPlan(p)
        }, secretEntry: true)
        XCTAssertTrue(asked.allSatisfy { $0.purpose == "try" })
        let ids = catalog.agents.map(\.id)
        XCTAssertTrue(ids.contains("grok") && ids.contains("gemini") && ids.contains("claude-code"), "\(ids)")
        XCTAssertFalse(ids.contains("none"))
        let grok = try XCTUnwrap(catalog.agents.first { $0.id == "grok" })
        XCTAssertEqual(grok.providerTitle, "xAI")
        XCTAssertEqual(grok.base, "Debian")
        let card = try XCTUnwrap(grok.card, "no key: the card")
        XCTAssertEqual(card.title, "What you need — Grok Build talks to xAI")
        XCTAssertEqual(card.options.map(\.kind), ["paste", "source"])
        XCTAssertEqual(card.addCommand, "doz account add NAME --provider xai")
        XCTAssertTrue(card.notOffered.first?.contains("an x.ai or X account") == true, "the vendor sign-in: labelled, not offered")
        XCTAssertNil(catalog.agents.first { $0.id == "gemini" }?.card, "a key there: no card")
        XCTAssertFalse(catalog.coming.isEmpty)
        XCTAssertTrue(catalog.coming.allSatisfy { !$0.reason.isEmpty }, "each coming agent says why")
        XCTAssertTrue(catalog.secretEntry)
    }

    func testATryIsMadeByTheOrdinaryCreateAction() throws {
        let a = try WebAction.decode(Data(#"{"action":"create","sandbox":"try-grok","image":"grok","network":"locked","trial":true}"#.utf8))
        guard case .create(let name, let o) = a else { return XCTFail("not create") }
        XCTAssertEqual(name, "try-grok")
        XCTAssertEqual(o.trial, true)
        XCTAssertEqual(a.hostOp, .create, "one HostOp, as ever")
        XCTAssertThrowsError(try WebAction.decode(Data(#"{"action":"create","sandbox":"x","image":"grok","trial":"yes"}"#.utf8)))
    }

    func testAProvidersKeyMayBePastedNeverACustomOne() throws {
        let k = try WebAccountAdd.decode(Data(#"{"name":"xai","kind":"key","provider":"xai","secret":"xai-0123456789abcdefghijkl"}"#.utf8))
        XCTAssertEqual(k.provider, "xai")
        XCTAssertFalse("\(k)".contains("xai-0123"), "redacted")
        for bad in [#"{"name":"x","kind":"key","secret":"xai-0123456789abcdefghijkl"}"#,
                    #"{"name":"x","kind":"key","provider":"custom","secret":"xai-0123456789abcdefghijkl"}"#,
                    #"{"name":"x","kind":"key","provider":"anthropic","secret":"xai-0123456789abcdefghijkl"}"#,
                    #"{"name":"x","kind":"api-key","provider":"xai","secret":"sk-ant-0123456789abcdefghijkl"}"#] {
            XCTAssertThrowsError(try WebAccountAdd.decode(Data(bad.utf8)), bad)
        }
    }

    /// `doz try --ui`: the control socket's `show` line points open pages at the Quick try — that page only.
    func testTheShowLineNamesOnlyTheQuickTry() {
        XCTAssertEqual(WebControl.showPage("show try"), "try")
        XCTAssertEqual(WebControl.showPage("show try/grok"), "try/grok")
        for bad in ["show settings", "show try/../x", "show try/Grok", "show #/try", "show try/grok?x", "try", "show try/", "link"] {
            XCTAssertNil(WebControl.showPage(bad), bad)
        }
    }

    func testNoPlanFieldIsSecretShaped() throws {
        let catalog = WebTryCatalog(agents: [], coming: [], secretEntry: false)
        let p = WebPlan(CreatePlan.sample(name: "try-grok", image: "grok"))
        for v in [try JSONEncoder().encode(catalog), try JSONEncoder().encode(p)] {
            let s = String(decoding: v, as: UTF8.self).lowercased()
            // Field NAMES only (a reach line may well say "1Password" — a word a person reads).
            for word in ["\"secret\"", "\"token\"", "\"password\"", "\"apikey\"", "\"key\":"] { XCTAssertFalse(s.contains(word), "\(word) in \(s.prefix(300))") }
        }
    }

    func testTheQuickTryShowsTheLatestAndTheStanding() async throws {
        let cur = ["gemini": AgentCurrency.make(agent: "gemini", record: nil, lifecycle: AgentRecipes.recipe("gemini")!.lifecycle!, now: Date())]
        let catalog = await WebTryCatalog.build(plan: { _ in WebPlan(CreatePlan.sample(name: "try-x", image: "grok")) }, secretEntry: true, currency: cur)
        let ids = catalog.agents.map(\.id)
        XCTAssertLessThan(ids.firstIndex(of: "antigravity")!, ids.firstIndex(of: "gemini")!, "Google's lead agent first among the Google ones")
        XCTAssertEqual(ids.last, "gemini", "superseded: below the others, still listed")
        let g = try XCTUnwrap(catalog.agents.last)
        XCTAssertEqual(g.supersededBy, "antigravity")
        XCTAssertTrue(g.standing?.hasPrefix("Superseded by Antigravity CLI") == true)
        XCTAssertEqual(g.latest, "latest: not checked yet")
    }

    /// The redesign (617 item 5): each agent carries its registry mark (drawn from its path — never fetched), what the
    /// search matches, and the pills' facts; a coming one its mark too.
    func testTheCatalogCarriesMarksAndThePillsFacts() async throws {
        let catalog = await WebTryCatalog.build(plan: { r in
            var p = CreatePlan.sample(name: "try-" + r.create.image, image: r.create.image)
            p.problems = r.create.image == "grok" ? [PlanProblem(code: "key", text: "needs a key", fix: "doz account add NAME --provider xai")] : []
            return WebPlan(p)
        }, secretEntry: true)
        let by = Dictionary(uniqueKeysWithValues: catalog.agents.map { ($0.id, $0) })
        for a in catalog.agents {
            let m = try XCTUnwrap(a.icon, a.id)
            XCTAssertEqual(m.kind, "product", a.id)
            XCTAssertFalse(m.d.isEmpty)
            XCTAssertNotNil(a.version, a.id)
        }
        XCTAssertEqual(by["grok"]?.icon?.id, "grok-build")
        XCTAssertEqual(by["antigravity"]?.aliases, ["agy"], "the search finds it by its alias")
        XCTAssertEqual(by["codex"]?.openSource, true)
        XCTAssertEqual(by["claude-code"]?.openSource, false)
        XCTAssertEqual(by["antigravity"]?.headless, true)
        XCTAssertEqual(by["gemini"]?.current, false, "superseded")
        XCTAssertEqual(by["antigravity"]?.current, true)
        XCTAssertEqual(by["grok"]?.ready, false, "no key: not ready")
        XCTAssertEqual(by["codex"]?.ready, true)
        XCTAssertEqual(by["antigravity"]?.version, "1.3.4", "the pinned version, without its build")
        XCTAssertTrue(catalog.coming.allSatisfy { $0.icon != nil }, "a coming agent has a mark (its vendor's, or a lettermark)")
        XCTAssertEqual(WebTryCatalog.age(0), "today")
        XCTAssertEqual(WebTryCatalog.age(1), "1 day")
        XCTAssertEqual(WebTryCatalog.age(12), "12 days")
        XCTAssertEqual(WebTryCatalog.age(35), "5 weeks")
        XCTAssertEqual(WebTryCatalog.age(100), "3 months")
    }

    /// 617 (owner: a key added in "What you need" did not work — pi, whose Anthropic default is the Mac's Claude Code
    /// login, takes API keys only): the catalog lists the accounts each agent can use, and the plan takes the one the
    /// setup chose.
    func testTheSetupPlansWithAKeyTheAgentCanUse() async throws {
        func acct(_ name: String, _ kind: String, provider: String? = nil, isDefault: Bool = false) -> WebAccount {
            var w = WebAccount(AccountRow(name: name, kind: kind, isDefault: isDefault, usedBy: [], state: "ok"))
            w.provider = provider
            return w
        }
        let accounts = [acct("mac", "mac", isDefault: true), acct("anthropic", "api-key"), acct("oai", "openai-key"),
                        acct("xai1", "key", provider: "xai"), acct("google", "key", provider: "google")]
        let catalog = await WebTryCatalog.build(plan: { r in WebPlan(CreatePlan.sample(name: "try-" + r.create.image, image: r.create.image)) },
                                                secretEntry: true, accounts: accounts)
        let by = Dictionary(uniqueKeysWithValues: catalog.agents.map { ($0.id, $0) })
        XCTAssertEqual(by["pi"]?.usableAccounts.map(\.name), ["anthropic"], "pi: an API key, never the Mac's login")
        XCTAssertEqual(by["claude-code"]?.usableAccounts.map(\.name), ["mac", "anthropic"])
        XCTAssertEqual(by["codex"]?.usableAccounts.map(\.name), ["oai"])
        XCTAssertEqual(by["grok"]?.usableAccounts.map(\.name), ["xai1"], "a key of its own provider only")
        XCTAssertEqual(by["antigravity"]?.usableAccounts.map(\.name), ["google"])
        XCTAssertEqual(by["grok"]?.description, "xAI's coding agent, on an xAI API key.", "the recipe's description")
        // The plan question takes the account (a name), strictly.
        let q = try WebPlanQuery.decode(Data(#"{"purpose":"try","agent":"pi","account":"anthropic"}"#.utf8))
        XCTAssertEqual(q.account, "anthropic")
        XCTAssertEqual(q.request.create.account, "anthropic")
        for bad in [#"{"purpose":"try","agent":"pi","account":"Bad Name"}"#, #"{"purpose":"try","agent":"pi","account":7}"#] {
            XCTAssertThrowsError(try WebPlanQuery.decode(Data(bad.utf8)), bad)
        }
    }

    /// 617 (models@1): the setup's provider/gateway and model — strict on the way in, carried to the create action, and
    /// the accounts a recipe agent can use are the keys of its sources (a gateway's included), never a subscription.
    func testTheSetupChoosesAProviderOrGatewayAndAModel() async throws {
        let q = try WebPlanQuery.decode(Data(#"{"purpose":"try","agent":"shell-gpt","source":"openrouter","model":"anthropic/claude-sonnet-4.6"}"#.utf8))
        XCTAssertEqual(q.request.create.modelSource, "openrouter")
        XCTAssertEqual(q.request.create.model, "anthropic/claude-sonnet-4.6")
        for bad in [#"{"purpose":"try","agent":"shell-gpt","source":"mars"}"#, #"{"purpose":"try","agent":"shell-gpt","model":"a b"}"#,
                    #"{"purpose":"try","agent":"shell-gpt","model":"$(rm -rf /)"}"#, #"{"purpose":"try","agent":"shell-gpt","source":3}"#] {
            XCTAssertThrowsError(try WebPlanQuery.decode(Data(bad.utf8)), bad)
        }
        let a = try WebAction.decode(Data(#"{"action":"create","sandbox":"try-sgpt","image":"shell-gpt","trial":true,"modelSource":"vercel-ai-gateway","model":"openai/gpt-5.4-mini"}"#.utf8))
        guard case .create(_, let o) = a else { return XCTFail("not create") }
        XCTAssertEqual(o.modelSource, "vercel-ai-gateway")
        XCTAssertEqual(o.model, "openai/gpt-5.4-mini")
        XCTAssertEqual(a.hostOp, .create, "still one HostOp")
        XCTAssertThrowsError(try WebAction.decode(Data(#"{"action":"create","sandbox":"x","image":"shell-gpt","modelSource":"nope"}"#.utf8)))
        XCTAssertThrowsError(try WebAction.decode(Data(#"{"action":"create","sandbox":"x","image":"shell-gpt","model":"x;y"}"#.utf8)))
        // The plan's projection: the source, the model and every offered source with its default model and key kind.
        var f = AccountsFile()
        var or1 = AccountRecord(name: "or1", kind: .key, plan: nil)
        or1.provider = "openrouter"
        f.accounts.append(or1)
        let facts = PlanFacts(settings: DozerSettings(text: ""), accounts: f, taken: [], images: [], store: DozerStore(root: FileManager.default.temporaryDirectory))
        let p = WebPlan(CreatePlanner.plan(q.request, facts: facts))
        XCTAssertEqual(p.model?.source, "openrouter")
        XCTAssertEqual(p.model?.model, "anthropic/claude-sonnet-4.6")
        XCTAssertEqual(p.model?.offered.map(\.id), ["xai", "openai", "google", "openrouter", "vercel-ai-gateway"])
        XCTAssertEqual(p.model?.offered.first { $0.id == "openai" }?.accountKind, "openai-key")
        XCTAssertEqual(p.create?.modelSource, "openrouter")
        XCTAssertEqual(p.account?.name, "or1")
        // The usable accounts carry their source; a recipe agent's chooser data (New Sandbox) lists its sources.
        func acct(_ name: String, _ kind: String, provider: String? = nil, isDefault: Bool = false) -> WebAccount {
            var w = WebAccount(AccountRow(name: name, kind: kind, isDefault: isDefault, usedBy: [], state: "ok"))
            w.provider = provider
            return w
        }
        let accounts = [acct("mac", "mac", isDefault: true), acct("anthropic", "api-key"), acct("oai", "openai-key"), acct("cg", "chatgpt"),
                        acct("xai1", "key", provider: "xai"), acct("or1", "key", provider: "openrouter")]
        let catalog = await WebTryCatalog.build(plan: { r in WebPlan(CreatePlan.sample(name: "try-" + r.create.image, image: r.create.image)) },
                                                secretEntry: true, accounts: accounts)
        let sg = try XCTUnwrap(catalog.agents.first { $0.id == "shell-gpt" })
        XCTAssertEqual(sg.usableAccounts.map(\.name), ["oai", "xai1", "or1"], "keys of its sources — never mac, a ChatGPT sign-in or Anthropic")
        XCTAssertEqual(sg.usableAccounts.map(\.modelSource), ["openai", "xai", "openrouter"])
        let w = WebAccounts(accounts: accounts, defaultAccount: "mac", keepalive: false, openaiDefault: "oai", providerDefaults: ["xai": "xai1"])
        XCTAssertEqual(w.sources["shell-gpt"], ["xai", "openai", "google", "openrouter", "vercel-ai-gateway"])
        XCTAssertEqual(w.agents["shell-gpt"], ["key", "openai-key"])
        XCTAssertEqual(w.recipeDefaults["shell-gpt"], "xai1", "its default source's default")
        XCTAssertEqual(w.agents["grok"], ["key"])
        XCTAssertEqual(w.sources["grok"], ["xai"])
        XCTAssertNil(w.sources["claude-code"], "the built-in three keep their own table")
        XCTAssertEqual(w.sourceTitles["vercel-ai-gateway"], "Vercel AI Gateway")
    }

    /// 617 (owner: "split them"): the sections and categories reach the page.
    func testTheDashboardGetsTheSectionsAndCategories() async throws {
        let catalog = await WebTryCatalog.build(plan: { r in WebPlan(CreatePlan.sample(name: "try-" + r.create.image, image: r.create.image)) },
                                                secretEntry: true, accounts: [])
        XCTAssertEqual(catalog.kinds.map(\.id), ["coding-agent", "ai-tool"])
        XCTAssertEqual(catalog.categories.map(\.id), Categories.all.map(\.id))
        XCTAssertEqual(catalog.agents.first { $0.id == "shell-gpt" }?.catalogKind, "ai-tool")
        XCTAssertEqual(catalog.agents.first { $0.id == "shell-gpt" }?.categories, ["terminal-tool"])
        XCTAssertEqual(catalog.coming.first { $0.id == "n8n" }?.categories, ["workflow"])
        XCTAssertTrue(catalog.agents.allSatisfy { $0.catalogKind != nil } && catalog.coming.allSatisfy { $0.catalogKind != nil })
        // New Sandbox: every agent and tool with its section, its own base and whether it runs on Alpine.
        let c = WebBases.catalogAgents
        XCTAssertEqual(c.map(\.id), AgentRecipes.all.map(\.id))
        XCTAssertEqual(c.first { $0.id == "grok" }.map { [$0.kind, $0.defaultBase] }, ["coding-agent", "debian"])
        XCTAssertEqual(c.first { $0.id == "llm" }?.musl, false)
    }

    /// A start's progress for the terminal area: steps in plain words, the one under way, a short tail — raw build output
    /// never becomes the operation's one-line text (the header strip).
    func testAStartsProgressIsStepsInPlainWordsAndATail() {
        var p = WebOpProgress()
        p.apply(HostEvent(kind: .started, sandbox: "s", text: "booted the bake VM"))
        XCTAssertEqual(p.current, "Starting a VM to prepare the image")
        XCTAssertNotNil(p.since)
        for i in 1...5 { p.apply(HostEvent(kind: .output, sandbox: "s", text: "Get:\(i) http://deb.debian.org/debian bookworm\u{1b}[0m")) }
        XCTAssertEqual(p.tail.count, 3, "a short tail")
        XCTAssertEqual(p.tail.last, "Get:5 http://deb.debian.org/debian bookworm", "inert text")
        p.apply(HostEvent(kind: .step, sandbox: "s", text: "booted the bake VM", milliseconds: 500))
        XCTAssertEqual(p.steps.last?.text, "Started a VM to prepare the image")
        XCTAssertEqual(p.steps.last?.seconds, 0.5)
        XCTAssertNil(p.current)
    }

    /// `doz try --ui` with no page open opens the plain origin only when a browser is still signed in for that port.
    func testKeptSessionsDecideWhetherAPlainPageSignsIn() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("uisessions-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertEqual(WebSessionStore.keptSessions(file: f, port: 4321), 0, "no file")
        try Data(#"{"port":4321,"sessions":{"d1":{"csrf":"c","expiresAt":"2099-01-01T00:00:00Z"},"d2":{"csrf":"c","expiresAt":"2001-01-01T00:00:00Z"}}}"#.utf8).write(to: f)
        XCTAssertEqual(WebSessionStore.keptSessions(file: f, port: 4321), 1, "the expired one does not count")
        XCTAssertEqual(WebSessionStore.keptSessions(file: f, port: 9999), 0, "another port's cookie is never presented")
    }

    /// 617 (the 0.34 screenshots): a card says the version a try INSTALLS — Claude Code at the latest the host resolved,
    /// not its frozen fallback pin — and a release date only when it belongs to that version.
    func testTheCardSaysWhatATryInstallsAndItsOwnDate() throws {
        let root = URL(fileURLWithPath: "/private/tmp/webtry-installs-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DozerStore(root: root), now = Date()
        let integrity = "sha512-" + Data(repeating: 7, count: 64).base64EncodedString()
        var claude = AgentVersionRecord(latest: AgentRelease(version: "2.1.299", integrity: integrity), checkedAt: now)
        claude.latestReleased = now
        claude.infoVersion = "2.1.299"
        let codex = AgentVersionRecord(latest: AgentRelease(version: "0.162.1", integrity: integrity), checkedAt: now)
        AgentVersions.save(["claude-code": claude, "codex": codex], store)

        let installs = WebTryCatalog.installs(store: store, settings: DozerSettings(text: nil))
        XCTAssertEqual(installs["claude-code"], "2.1.299", "latest (the default setting): the version last resolved")
        XCTAssertEqual(installs["codex"], "0.162.1")
        XCTAssertEqual(installs["pi"], AgentImages.pinned("pi")?.version, "never looked up: the pin")
        let exact = WebTryCatalog.installs(store: store, settings: DozerSettings(text: "[images]\nclaude_code_version = \"2.1.227\"\n"))
        XCTAssertEqual(exact["claude-code"], "2.1.227", "an exact setting: that version")

        let currency = AgentCurrency.all(store: store, now: now)
        let by = Dictionary(uniqueKeysWithValues: WebTryCatalog.list(secretEntry: true, currency: currency, installs: installs).agents.map { ($0.id, $0) })
        XCTAssertEqual(by["claude-code"]?.version, "2.1.299")
        XCTAssertEqual(by["claude-code"]?.age, "today", "the latest's date, for the latest")
        XCTAssertEqual(by["codex"]?.version, "0.162.1")
        XCTAssertNil(by["codex"]?.age, "no release date looked up for it: none shown")

        let older = Dictionary(uniqueKeysWithValues: WebTryCatalog.list(secretEntry: true, currency: currency, installs: exact).agents.map { ($0.id, $0) })
        XCTAssertEqual(older["claude-code"]?.version, "2.1.227")
        XCTAssertNil(older["claude-code"]?.age, "2.1.299's date is never shown beside 2.1.227")
        XCTAssertTrue(older["claude-code"]?.latest?.contains("2.1.299") == true, "the newest is said on its own line")
    }
}

extension CreatePlan {
    /// A plan as the planner makes one (for the page's projections).
    static func sample(name: String, image: String) -> CreatePlan {
        let r = PlanRequest(purpose: "try", name: name, create: CreateOptions(image: image))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("webtry-\(UUID().uuidString.prefix(6))")
        return CreatePlanner.plan(r, facts: PlanFacts(settings: DozerSettings(text: ""), accounts: AccountsFile(), taken: [], images: [],
                                                     store: DozerStore(root: root), projectsDir: "/tmp/617-webtry"))
    }
}
