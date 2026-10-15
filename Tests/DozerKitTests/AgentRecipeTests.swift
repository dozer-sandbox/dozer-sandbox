import Foundation
import XCTest
@testable import DozerKit

/// 617: the compiled-in agent recipes, key providers and model gateways — they decode, they validate, and every rule
/// a recipe can never break is refused with a reason.
final class AgentRecipeTests: XCTestCase {
    static var packageRoot: URL {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" {
            u.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("Package.swift").path) { return u }
        }
        fatalError("no Package.swift")
    }

    /// A recipe's MODEL as JSON (617: the files are schema-2 YAML now — Recipes/agents/VENDOR/PRODUCT.yaml — and these
    /// tests mutate the model it maps to, which `AgentRecipes.decode` reads).
    static func json(_ id: String) throws -> [String: Any] {
        let r = try XCTUnwrap(AgentRecipes.recipe(id))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
    }

    static func data(_ o: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: o) }

    func test_everyCompiledRecipeDecodesAndValidates() throws {
        XCTAssertEqual(AgentRecipes.all.map(\.id), ["claude-code", "pi", "codex", "antigravity", "gemini", "grok", "fabric", "openclaw", "nanobot", "gptme", "llm", "shell-gpt", "zeroclaw", "aichat", "tgpt", "opencode", "smolagents", "adk", "promptfoo", "clai", "copilot", "qwen-code", "goose", "kilo", "mistral-vibe", "droid", "dirac", "kimi-code", "cline", "openhands", "letta-code", "docker-agent", "nanocoder", "mini-swe-agent", "open-interpreter", "crush", "mimo-code", "codewhale", "maki", "omp", "tau", "stitch", "opencode2"])
        XCTAssertNoThrow(try AgentRecipes.validate(AgentRecipes.all))
        XCTAssertNoThrow(try KeyProviders.validate(KeyProviders.all))
        XCTAssertNoThrow(try Gateways.validate(Gateways.all))
        XCTAssertEqual(KeyProviders.all.map(\.id), ["anthropic", "openai", "xai", "google", "google-stitch", "openrouter", "vercel-ai-gateway"])
        XCTAssertEqual(Gateways.all.map(\.id), ["openrouter", "vercel-ai-gateway"])
        XCTAssertEqual(AgentRecipes.all.filter(\.isBuiltin).map(\.id), ["claude-code", "pi", "codex"])
    }

    /// D1: every file under Recipes/ is one `.embedInCode` line in Package.swift and decoded — never silently left out
    /// (and the basenames are unique: the identifier is the basename).
    func test_recipesFolderMatchesPackageSwift() throws {
        let root = Self.packageRoot.appendingPathComponent("Sources/DozerKit/Recipes")
        let files = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path)).compactMap { $0 as? String }.filter { $0.hasSuffix(".json") }.sorted()
        let manifest = try String(contentsOf: Self.packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        for f in files { XCTAssertTrue(manifest.contains(".embedInCode(\"Recipes/\(f)\")"), "\(f) is not embedded") }
        let basenames = files.map { ($0 as NSString).lastPathComponent }
        XCTAssertEqual(Set(basenames).count, basenames.count, "basenames must be unique across Recipes/")
        XCTAssertEqual(files.filter { $0.hasPrefix("compiled/") }.map { ($0 as NSString).lastPathComponent }.sorted(), AgentRecipes.compiledFiles.sorted())
    }

    func test_newAgentsAreTheSpikesValues() throws {
        let g = try XCTUnwrap(AgentRecipes.recipe("gemini")), k = try XCTUnwrap(AgentRecipes.recipe("grok"))
        XCTAssertEqual(g.install.pinned.version, "0.63.0")
        XCTAssertEqual(g.launch.noPromptsArgs, ["--approval-mode=yolo"])
        XCTAssertEqual(g.launch.env["GEMINI_CLI_TRUST_WORKSPACE"], "true")
        XCTAssertEqual(g.prompt?.manifest?.file, "gemini-extension.json")
        XCTAssertEqual(g.resume, ["--resume", "latest"])
        XCTAssertEqual(k.install.kind, "npm-platform-binary")
        XCTAssertEqual(k.install.platformPackage, "@xai-official/grok-linux-arm64")
        XCTAssertEqual(k.install.compression, "brotli")
        XCTAssertTrue(k.platforms.musl)
        XCTAssertEqual(k.launch.noPromptsArgs, ["--always-approve"])
        XCTAssertNil(k.resume, "Grok restarts fresh until --continue with no session is checked")
        XCTAssertFalse(k.network.excluded.contains("storage.googleapis.com"), "Go's module downloads host is not Grok's to exclude")
        XCTAssertEqual(KeyProviders.provider("xai")?.check?.rejected, [400, 401, 403])
        XCTAssertEqual(KeyProviders.provider("google")?.binding.header, .apiKey(name: "x-goog-api-key"))
        XCTAssertEqual(KeyProviders.provider("xai")?.binding.header, .bearer)
        XCTAssertEqual(KeyProviders.provider("anthropic")?.binding, .anthropic)
        XCTAssertEqual(KeyProviders.provider("openai")?.binding, .openai)
        XCTAssertEqual(g.permissionsVariable, "DOZ_GEMINI_PERMISSIONS")
        XCTAssertEqual(AgentRecipes.recipe("claude-code")?.permissionsVariable, "DOZ_CLAUDE_PERMISSIONS")
        XCTAssertEqual(g.versionSettingKey, "images.gemini_version")
        XCTAssertEqual(k.permissionsSettingKey, "grok.permissions")
        XCTAssertNil(AgentRecipes.recipe("pi")?.permissionsSettingKey)
    }

    // MARK: auth (owner, 617)

    func test_everyRecipeSaysHowToGetIn() throws {
        for r in AgentRecipes.all {
            XCTAssertFalse(r.auth.methods.isEmpty, r.id)
            for m in r.auth.methods {
                if let u = m.keysPage { XCTAssertTrue(u.hasPrefix("https://"), r.id) }
                if let p = m.provider { XCTAssertNotNil(KeyProviders.provider(p), r.id) }
                if let d = m.checked { XCTAssertTrue(AgentRecipe.isISODate(d), r.id) }
                XCTAssertNil(m.freeTier, "\(r.id): no free tier is claimed without a cited, dated source")
            }
        }
        XCTAssertEqual(AgentRecipes.recipe("gemini")?.auth.methods.map(\.kind), ["api-key"], "Gemini: API key only")
        XCTAssertEqual(AgentRecipes.recipe("grok")?.auth.methods.map(\.kind), ["api-key", "vendor-sign-in"])
        XCTAssertEqual(AgentRecipes.recipe("pi")?.auth.methods.map(\.kind), ["api-key", "gateway"])
        XCTAssertEqual(AgentRecipes.recipe("claude-code")?.auth.methods.first?.accounts, ["mac", "setup-token"])
    }

    func test_authRefusals() throws {
        var o = try Self.json("gemini")
        o["auth"] = ["methods": []]
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)))
        o["auth"] = ["methods": [["kind": "api-key", "provider": "nowhere", "keys_page": "https://x.example"]]]
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)))
        o["auth"] = ["methods": [["kind": "api-key", "provider": "google", "keys_page": "http://x.example"]]]
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)))
        o["auth"] = ["methods": [["kind": "api-key", "provider": "google", "keys_page": "https://x.example", "checked": "12 Oct 2026"]]]
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)))
        o["auth"] = ["methods": [["kind": "api-key", "provider": "google", "keys_page": "https://x.example", "free_tier": true]]]
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)), "a free tier without its date")
        o["auth"] = ["methods": [["kind": "vendor-sign-in"]]]
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)))
        o["auth"] = ["methods": [["kind": "gateway", "gateways": []]]]
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)))
        o["auth"] = ["methods": [["kind": "magic"]]]
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)))
    }

    // MARK: gateways (owner, 617)

    func test_everyRecipeHasAnEntryForEveryGateway() {
        for r in AgentRecipes.all {
            // 618: an entry, or derived from models@1 (gatewaySupport).
            XCTAssertEqual(r.gatewaySupport.map(\.gateway).sorted(), Gateways.all.map(\.id).sorted(), r.id)
        }
    }

    /// Every applicable entry's templates resolve against the catalogue with no unknown placeholder.
    func test_everyApplicableHowResolves() throws {
        for r in AgentRecipes.all {
            for s in r.gatewaySupport where s.isApplicable {
                // 618: a gateway models@1 offers needs no how — models@1 says it.
                guard let how = try s.resolved(placeholder: "doz_cred_PLACEHOLDER", model: "anthropic/claude-x") else {
                    XCTAssertTrue(r.offersGateway(s.gateway), "\(r.id) × \(s.gateway): a how, or offered by models@1")
                    XCTAssertNotNil(s.checked, "\(r.id) × \(s.gateway)")
                    continue
                }
                let strings = (how.env.map { Array($0.values) } ?? []) + (how.args ?? []) + (how.modelArgs ?? [])
                    + (how.config ?? []).flatMap { $0.set.values.flatMap(\.strings) }
                for v in strings { XCTAssertFalse(v.contains("{"), "\(r.id) × \(s.gateway): \(v)") }
                XCTAssertNotNil(s.checked, "\(r.id) × \(s.gateway)")
                if s.level == "documented" { XCTAssertNotNil(s.source) } else { XCTAssertNotNil(s.evidence) }
            }
        }
        // The documented Claude Code pairs point at the endpoints the gateways' own docs name.
        let cc = try XCTUnwrap(AgentRecipes.recipe("claude-code")?.gateways.first { $0.gateway == "vercel-ai-gateway" })
        XCTAssertEqual(try cc.resolved(placeholder: "P", model: "m")?.env?["ANTHROPIC_BASE_URL"], "https://ai-gateway.vercel.sh/claude-code")
        XCTAssertEqual(try cc.resolved(placeholder: "P", model: "m")?.env?["ANTHROPIC_AUTH_TOKEN"], "P")
    }

    /// The pairs not yet looked at / only experimental — listed here so each is resolved on purpose (a change to this
    /// list is a decision, made in the recipe and here together).
    func test_unresolvedGatewayPairs() {
        var unknown: [String] = [], experimental: [String] = []
        // 617 (models@1): a recipe that declares its model sources says yes or no to every gateway (checked below).
        for r in AgentRecipes.all where r.models != nil {
            for s in r.gatewaySupport {
                XCTAssertNotEqual(s.level, "unknown", "\(r.id) × \(s.gateway)")
                XCTAssertEqual(s.isApplicable, r.offeredSources.contains(s.gateway), "\(r.id) × \(s.gateway): verified exactly when offered")
            }
        }
        for r in AgentRecipes.all where r.models == nil {
            for s in r.gateways {
                if s.level == "unknown" { unknown.append("\(r.id) × \(s.gateway)") }
                if s.level == "experimental" { experimental.append("\(r.id) × \(s.gateway)") }
            }
        }
        // Antigravity CLI names undocumented AGY_LLM_GATEWAY_* settings — not checked yet.
        XCTAssertEqual(unknown, ["antigravity × openrouter", "antigravity × vercel-ai-gateway", "tgpt × openrouter", "tgpt × vercel-ai-gateway", "adk × openrouter", "adk × vercel-ai-gateway", "clai × openrouter", "clai × vercel-ai-gateway", "goose × vercel-ai-gateway", "kilo × vercel-ai-gateway", "droid × openrouter", "droid × vercel-ai-gateway", "dirac × openrouter", "dirac × vercel-ai-gateway", "cline × openrouter", "cline × vercel-ai-gateway", "letta-code × openrouter", "letta-code × vercel-ai-gateway", "docker-agent × openrouter", "docker-agent × vercel-ai-gateway", "nanocoder × openrouter", "nanocoder × vercel-ai-gateway", "mini-swe-agent × openrouter", "mini-swe-agent × vercel-ai-gateway", "open-interpreter × openrouter", "open-interpreter × vercel-ai-gateway", "crush × openrouter", "crush × vercel-ai-gateway", "mimo-code × openrouter", "mimo-code × vercel-ai-gateway", "codewhale × openrouter", "codewhale × vercel-ai-gateway", "maki × openrouter", "maki × vercel-ai-gateway", "omp × openrouter", "omp × vercel-ai-gateway", "tau × openrouter", "tau × vercel-ai-gateway"])
        XCTAssertEqual(experimental, ["grok × openrouter"])
    }

    func test_gatewayRefusals() throws {
        var o = try Self.json("grok")
        var gws = try XCTUnwrap(o["gateways"] as? [[String: Any]])
        // Missing an entry for a gateway.
        o["gateways"] = [gws[0]]
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)))
        // An unknown template.
        var bad = gws[1]
        bad["how"] = ["env": ["X": "{gateway.secret}"]]
        o["gateways"] = [gws[0], bad]
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)))
        // An endpoint the gateway does not have.
        bad = gws[1]; bad["endpoint"] = "nowhere"
        o["gateways"] = [gws[0], bad]
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)))
        // Experimental without evidence; documented without a source; no without a reason; a made-up level.
        bad = gws[0]; bad["evidence"] = nil
        o["gateways"] = [bad, gws[1]]
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)))
        bad = gws[1]; bad["source"] = nil
        o["gateways"] = [gws[0], bad]
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)))
        gws[1] = ["gateway": "vercel-ai-gateway", "level": "no"]
        o["gateways"] = gws
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)))
        gws[1] = ["gateway": "vercel-ai-gateway", "level": "yes"]
        o["gateways"] = gws
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)))
        gws[1] = ["gateway": "vercel-ai-gateway", "level": "unknown"]
        o["gateways"] = gws
        XCTAssertNoThrow(try AgentRecipes.decode(Self.data(o)), "unknown is allowed — said explicitly")
    }

    // MARK: capability tags (owner, 617)

    func test_tagVocabularyAndEveryRecipesTags() throws {
        XCTAssertNoThrow(try CapabilityTags.validate(CapabilityTags.all))
        for r in AgentRecipes.all {
            XCTAssertEqual(r.capabilityTags.map(\.tag), CapabilityTags.all.map(\.id), "\(r.id): every tag of the vocabulary, in order")
            for t in r.capabilityTags { XCTAssertTrue(AgentRecipe.GatewaySupport.levels.contains(t.level), "\(r.id) \(t.tag)") }
        }
        func level(_ r: String, _ t: String) -> String? { AgentRecipes.recipe(r)?.capabilityTags.first { $0.tag == t }?.level }
        // Derived, so they follow the data.
        XCTAssertEqual(level("gemini", "multi-vendor-models"), "no")
        XCTAssertEqual(level("gemini", "gateway:openrouter"), "no")
        XCTAssertEqual(level("grok", "gateway:openrouter"), "experimental")
        XCTAssertEqual(level("grok", "multi-vendor-models"), "documented")
        XCTAssertEqual(level("pi", "gateway:openrouter"), "documented")
        XCTAssertEqual(level("claude-code", "vendor-sign-in"), "documented")
        XCTAssertEqual(level("gemini", "vendor-sign-in"), "no")
        XCTAssertEqual(level("claude-code", "open-source"), "no")
        XCTAssertEqual(level("grok", "open-source"), "documented")
        XCTAssertEqual(level("grok", "resume"), "unknown")
        XCTAssertEqual(level("claude-code", "status"), "verified")
        XCTAssertEqual(level("gemini", "free-tier"), "unknown")
        XCTAssertEqual(level("grok", "headless"), "verified")
        XCTAssertTrue(AgentRecipes.recipe("codex")!.hasTag("multi-vendor-models"))
        XCTAssertFalse(AgentRecipes.recipe("gemini")!.hasTag("multi-vendor-models"))
        XCTAssertEqual(AgentRecipes.all.filter { $0.models == nil && $0.hasTag("gateway:openrouter") }.map(\.id), ["claude-code", "pi", "codex", "opencode", "copilot", "goose", "kilo"])
        XCTAssertEqual(AgentRecipes.all.filter { $0.models != nil }.filter { $0.hasTag("gateway:openrouter") }.map(\.id),
                       AgentRecipes.all.filter { $0.offeredSources.contains("openrouter") && $0.models != nil }.map(\.id), "617: offered = the tag")
    }

    func test_tagRefusals() throws {
        var o = try Self.json("gemini")
        o["tags"] = []
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)), "a declared tag missing")
        o["tags"] = [["tag": "headless", "level": "unknown"], ["tag": "musl", "level": "documented", "source": "https://x.example"]]
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)), "a derivable tag declared")
        o["tags"] = [["tag": "headless", "level": "unknown"], ["tag": "telepathy", "level": "unknown"]]
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)), "a tag outside the vocabulary")
        o["tags"] = [["tag": "headless", "level": "documented"]]
        XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)), "documented with no source")
        o["tags"] = [["tag": "headless", "level": "unknown"]]
        XCTAssertNoThrow(try AgentRecipes.decode(Self.data(o)))
    }

    // MARK: the recipe rules

    func test_refusals() throws {
        func refused(_ id: String, _ change: (inout [String: Any]) -> Void, _ why: String, file: StaticString = #filePath, line: UInt = #line) throws {
            var o = try Self.json(id)
            change(&o)
            XCTAssertThrowsError(try AgentRecipes.decode(Self.data(o)), why, file: file, line: line)
        }
        XCTAssertNoThrow(try AgentRecipes.decode(Self.data(Self.json("grok"))))
        try refused("grok", { $0["surprise"] = 1 }, "an unknown key")
        try refused("grok", { o in var l = o["launch"] as! [String: Any]; l["env"] = ["XAI_API_KEY": "x"]; o["launch"] = l }, "a credential-shaped env var")
        try refused("grok", { o in var s = o["state"] as! [String: Any]; s["env"] = ["MY_TOKEN": "x"]; o["state"] = s }, "a credential-shaped state env var")
        try refused("grok", { $0["id"] = "python" }, "a base id")
        try refused("grok", { $0["id"] = "lab" }, "a reserved name")
        try refused("grok", { o in var n = o["network"] as! [String: Any]; n["excluded"] = ["api.x.ai"]; o["network"] = n }, "an excluded host it may reach")
        try refused("grok", { o in var n = o["network"] as! [String: Any]; n["excluded"] = ["github.com"]; o["network"] = n }, "an excluded host in a permission")
        try refused("grok", { o in var i = o["install"] as! [String: Any]; i["pinned"] = ["version": "latest", "integrity": "sha512-A"]; o["install"] = i }, "a malformed pin")
        try refused("grok", { o in var i = o["install"] as! [String: Any]; i["pinned"] = ["version": "1.0.0", "integrity": "md5-abc"]; o["install"] = i }, "a malformed integrity")
        try refused("grok", { o in var l = o["launch"] as! [String: Any]; l["no_prompts_args"] = ["--x='y'"]; o["launch"] = l }, "a quote in an argument")
        try refused("grok", { o in var n = o["network"] as! [String: Any]; n["model"] = ["id": "model", "shared": true]; o["network"] = n }, "a recipe agent on the shared model")
        try refused("grok", { $0["default_base"] = "cobol" }, "an unknown default base")
        try refused("grok", { o in o["credentials"] = [["provider": "xai", "accounts": ["mac"]]] }, "a recipe agent takes key accounts only")
        try refused("gemini", { o in var l = o["launch"] as! [String: Any]; l["first_run"] = [["file": "/etc/x.json", "set": ["a": true]]]; o["launch"] = l }, "a first-run file outside ~/")
        try refused("grok", { o in var l = o["launch"] as! [String: Any]; l["first_run"] = [["file": "~/.grok/config.toml", "set": ["flat": ["a": 1]]]]; o["launch"] = l }, "a TOML value that is a table (617: a key with no table is a top-level key now)")
        // Between recipes: an alias that is another's id.
        var g = try AgentRecipes.decode(Self.data(Self.json("gemini")))
        g.aliases = ["grok"]
        XCTAssertThrowsError(try AgentRecipes.validate(AgentRecipes.all.filter { $0.id != "gemini" } + [g]))
        // A provider whose host is another's.
        var p = KeyProviders.all
        p[3].hosts = ["api.x.ai"]
        XCTAssertThrowsError(try KeyProviders.validate(p))
    }
}
