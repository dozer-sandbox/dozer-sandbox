import Foundation

// 617 (owner: "one YAML file per recipe", "align as close as we can right now with our own format so that export /
// generating a sandboxkit YAML is straightforward", "we need a JSON Schema and spec doc for our new YAML format") —
// the recipe FILE format, `schema: 2`: Docker Sandbox Kit v3's layout (its top-level fields, a `capabilities:` list
// with Kit's own types and config shapes where Kit has them, Dozer's extras under `dozer:` keys and in
// `com.dozersandbox/*@1` types, `${{ kit.args.version }}` / `${{ dozer.* }}` templating). docs/recipes/RECIPE-FORMAT.md
// is the spec; schema/dozer-recipe-2.schema.json the contract (RecipeSchemaTests: every recipe valid, and the decoder
// refuses what the schema refuses).
//
// The files: `Recipes/agents/VENDOR/PRODUCT.yaml` (the source a person edits), compiled by DozerCLI's Yams to
// `Recipes/compiled/PRODUCT.json` — the same tree, canonical JSON, committed and embedded (DozerKit has no YAML
// parser; `make recipes` writes it, RecipeSourceTests fails when it drifts). `RecipeDocument.recipe()` maps a document
// to the `AgentRecipe` everything else uses — one for one, lossless (`RecipeDocument(recipe)` is the inverse).
//
// Strict, as Kit is: an unknown key anywhere is an error; the Kit parts that are DERIVED (the network policy's allow
// and deny lists, a credential's apiKey) must equal what Dozer derives, so they cannot drift.

public struct RecipeDocument: Codable, Sendable, Equatable {
    public static let schemaVersion = 2
    /// The guest home a Kit path (absolute) maps `~/` to.
    public static let guestHome = "/home/agent/"

    /// Dozer's format version (export writes Kit's `schemaVersion: "3"`).
    public var schema: Int
    /// Kit's kind: `workload` (the agent a sandbox runs).
    public var kind: String
    /// `VENDOR/PRODUCT` (the file's path); PRODUCT is the agent's id.
    public var id: String
    public var displayName: String
    public var description: String
    /// Kit's `author`: the publisher's name.
    public var author: String
    public var sourceUrl: String
    /// SPDX identifiers (`LicenseRef-…` for one without).
    public var licenses: [String]
    public var args: Args
    public var provides: [String]
    public var capabilities: [RecipeCapability]

    public struct Args: Codable, Sendable, Equatable {
        public var version: KitArg
    }

    /// Kit's arg (§6): here only the version, resolved at build (`buildArg`).
    public struct KitArg: Codable, Sendable, Equatable {
        public var `default`: String
        public var pattern: String
        public var buildArg: String
        public var description: String?
    }

    // MARK: the capabilities

    public enum Types {
        public static let networkPolicy = "com.docker.sandbox/network-policy@1"
        public static let credential = "com.docker.sandbox/credential@1"
        public static let volume = "com.docker.sandbox/volume@1"
        public static let agentContext = "com.docker.sandbox/agent-context@1"
        public static let install = "com.dozersandbox/install@1"
        public static let launch = "com.dozersandbox/launch@1"
        public static let auth = "com.dozersandbox/auth@1"
        public static let gateways = "com.dozersandbox/gateways@1"
        public static let currency = "com.dozersandbox/currency@1"
        public static let models = "com.dozersandbox/models@1"
        public static let directory = "com.dozersandbox/directory@1"
        /// 617 (RP-1): the web ports its program serves.
        public static let ports = "com.dozersandbox/ports@1"
        /// 617.11: its guide (intro, first steps, tips, docs).
        public static let guide = "com.dozersandbox/guide@1"
        /// Kit's own types (exported as they are, `dozer:` keys removed).
        public static let kit = [networkPolicy, credential, volume, agentContext]
        public static let dozer = [install, launch, auth, gateways, currency, directory, models, ports, guide]
    }

    /// Kit's network-policy@1 (`install`/`runtime` × `allow`/`deny`), Dozer's whole network under `dozer`.
    public struct NetworkPolicy: Codable, Sendable, Equatable {
        public var install: Rules?
        public var runtime: Rules?
        public var dozer: AgentRecipe.Network
        public struct Rules: Codable, Sendable, Equatable {
            public var allow: [String]?
            public var deny: [String]?
        }
    }

    /// Kit's credential@1: `service` is the key provider; `apiKey` is derived from it (providers.json).
    public struct Credential: Codable, Sendable, Equatable {
        public var service: String
        public var phase: String
        public var apiKey: ApiKey
        public var dozer: CredentialDozer
        public struct ApiKey: Codable, Sendable, Equatable {
            public var name: String
            public var proxyManaged: Bool
            public var inject: [Inject]
        }
        public struct Inject: Codable, Sendable, Equatable {
            public var domain: String
            public var header: String
            public var format: String
        }
        public struct CredentialDozer: Codable, Sendable, Equatable {
            /// The Dozer account kinds that serve it (`mac`, `setup-token`, `api-key`, `key`, …).
            public var accounts: [String]
            /// 617: more guest variables that hold the same placeholder (a tool that reads its key under another name:
            /// OPENAI_API_KEY for an OpenAI-compatible base URL, LLM_GEMINI_KEY).
            public var envAliases: [String]? = nil
            enum CodingKeys: String, CodingKey { case accounts, envAliases = "env_aliases" }
        }
    }

    /// Kit's volume@1: one persisted path, absolute in the guest.
    public struct Volume: Codable, Sendable, Equatable {
        public var path: String
    }

    /// Kit's agent-context@1: where Dozer's facts go (`directory` + `filename`); how, under `dozer`.
    public struct AgentContext: Codable, Sendable, Equatable {
        public var directory: String
        public var filename: String
        public var dozer: AgentContextDozer
        public struct AgentContextDozer: Codable, Sendable, Equatable {
            /// `skill` (a SKILL.md) | `context-file`.
            public var kind: String
            public var manifest: AgentRecipe.Manifest?
            public var launcherArg: [String]?
            enum CodingKeys: String, CodingKey { case kind, manifest, launcherArg = "launcher_arg" }
        }
    }

    /// com.dozersandbox/install@1 — how Dozer installs it (the version is `args.version`).
    public struct Install: Codable, Sendable, Equatable {
        public var kind: String
        /// true: Dozer's own Swift installs and launches it (Claude Code, pi, Codex).
        public var builtin: Bool?
        public var package: String?
        public var platformPackage: String?
        public var payload: String?
        public var compression: String?
        public var binary: String
        public var needsNode: String?
        public var npmArgs: [String]?
        public var manifest: String?
        /// A template: `${{ dozer.build }}` is the release's `<version>-<build>` path segment.
        public var url: String?
        public var bakeHosts: [String]?
        /// The pinned release's sha512 (npm's integrity form).
        public var integrity: String?
        /// 617 (pypi): every distribution the venv holds, `name==version --hash=sha256:<hex>`.
        public var requirements: [String]? = nil
        /// 617.11: file sets beside the program, each from a sha256-pinned archive (`${{ kit.args.version }}` in url and path).
        public var extras: [AgentRecipe.Install.Extra]? = nil
        enum CodingKeys: String, CodingKey {
            case kind, builtin, package, payload, compression, binary, manifest, url, integrity, requirements, extras
            case platformPackage = "platform_package", needsNode = "needs_node", npmArgs = "npm_args", bakeHosts = "bake_hosts"
        }
    }

    /// com.dozersandbox/launch@1 — how Dozer runs it.
    public struct Launch: Codable, Sendable, Equatable {
        public var command: [String]
        public var noPromptsArgs: [String]
        public var noPromptsEnv: [String: String]? = nil
        public var passthrough: [String]
        public var env: [String: String]
        /// The environment of its state folders (baked).
        public var stateEnv: [String: String]
        public var firstRun: [AgentRecipe.FirstRun]?
        public var sessionEnv: [String: String]?
        /// 617: `shell` — the default session is a login shell (a tool that answers and exits).
        public var session: String? = nil
        public var status: String
        public var resume: [String]?
        public var resumeCheck: String?
        /// `expect` is a template: `${{ kit.args.version }}` (compared without a release's `+build`).
        public var verify: [AgentRecipe.Check]
        /// The smoke turn `make recipe-check` runs (required: `check()` refuses a file without one).
        public var check: AgentRecipe.Smoke?
        public var settings: AgentRecipe.SettingKeys?
        enum CodingKeys: String, CodingKey {
            case command, passthrough, env, status, resume, verify, check, settings, session
            case noPromptsArgs = "no_prompts_args", stateEnv = "state_env", firstRun = "first_run", sessionEnv = "session_env",
                 resumeCheck = "resume_check", noPromptsEnv = "no_prompts_env"
        }
    }

    /// com.dozersandbox/gateways@1 — one entry per gateway; `how` values are templates (`${{ dozer.placeholder }}`,
    /// `${{ dozer.model }}`, `${{ dozer.gateway.endpoint.ID }}`).
    public struct Gateways: Codable, Sendable, Equatable {
        public var entries: [AgentRecipe.GatewaySupport]
    }

    /// com.dozersandbox/currency@1 — where it stands with its maker, and when the recipe was last checked.
    public struct Currency: Codable, Sendable, Equatable {
        public var checked: String?
        public var lifecycle: AgentLifecycle?
    }

    /// com.dozersandbox/directory@1 — what the directory index, `doz search` and the Quick try show.
    public struct Directory: Codable, Sendable, Equatable {
        public var aliases: [String]?
        public var icon: String?
        public var defaultBase: String
        public var platforms: AgentRecipe.Platforms
        public var limits: [AgentRecipe.Limit]?
        public var tags: [RecipeTag]
        /// Shown where an account is chosen.
        public var terms: String?
        /// The licence in words, when it is not just the SPDX id (`Proprietary (Google Antigravity terms)`).
        public var licence: String?
        /// 617 (owner): `coding-agent` | `ai-tool`, and its categories (tags.json's vocabulary) — declared.
        public var kind: String?
        public var categories: [String]?
        enum CodingKeys: String, CodingKey {
            case aliases, icon, platforms, limits, tags, terms, licence, kind, categories
            case defaultBase = "default_base"
        }
    }
}

/// One entry of `capabilities:` — Kit's `{type, name?, optional?, description?, config}`; the config decoded by type.
public struct RecipeCapability: Codable, Sendable, Equatable {
    public var type: String
    public var name: String?
    public var optional: Bool?
    public var description: String?
    public var config: Config

    public enum Config: Sendable, Equatable {
        case networkPolicy(RecipeDocument.NetworkPolicy)
        case credential(RecipeDocument.Credential)
        case volume(RecipeDocument.Volume)
        case agentContext(RecipeDocument.AgentContext)
        case install(RecipeDocument.Install)
        case launch(RecipeDocument.Launch)
        case auth(AgentRecipe.Auth)
        case gateways(RecipeDocument.Gateways)
        case currency(RecipeDocument.Currency)
        case directory(RecipeDocument.Directory)
        case models(AgentRecipe.Models)
        case ports(AgentRecipe.WebPorts)
        case guide(AgentRecipe.Guide)
    }

    enum CodingKeys: String, CodingKey { case type, name, optional, description, config }

    public init(type: String, description: String? = nil, config: Config) {
        self.type = type; self.description = description; self.config = config
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        optional = try c.decodeIfPresent(Bool.self, forKey: .optional)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        typealias T = RecipeDocument.Types
        switch type {
        case T.networkPolicy: config = .networkPolicy(try c.decode(RecipeDocument.NetworkPolicy.self, forKey: .config))
        case T.credential: config = .credential(try c.decode(RecipeDocument.Credential.self, forKey: .config))
        case T.volume: config = .volume(try c.decode(RecipeDocument.Volume.self, forKey: .config))
        case T.agentContext: config = .agentContext(try c.decode(RecipeDocument.AgentContext.self, forKey: .config))
        case T.install: config = .install(try c.decode(RecipeDocument.Install.self, forKey: .config))
        case T.launch: config = .launch(try c.decode(RecipeDocument.Launch.self, forKey: .config))
        case T.auth: config = .auth(try c.decode(AgentRecipe.Auth.self, forKey: .config))
        case T.gateways: config = .gateways(try c.decode(RecipeDocument.Gateways.self, forKey: .config))
        case T.currency: config = .currency(try c.decode(RecipeDocument.Currency.self, forKey: .config))
        case T.directory: config = .directory(try c.decode(RecipeDocument.Directory.self, forKey: .config))
        case T.models: config = .models(try c.decode(AgentRecipe.Models.self, forKey: .config))
        case T.ports: config = .ports(try c.decode(AgentRecipe.WebPorts.self, forKey: .config))
        case T.guide: config = .guide(try c.decode(AgentRecipe.Guide.self, forKey: .config))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "capability type \(type) is not one this build knows")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(optional, forKey: .optional)
        try c.encodeIfPresent(description, forKey: .description)
        switch config {
        case .networkPolicy(let v): try c.encode(v, forKey: .config)
        case .credential(let v): try c.encode(v, forKey: .config)
        case .volume(let v): try c.encode(v, forKey: .config)
        case .agentContext(let v): try c.encode(v, forKey: .config)
        case .install(let v): try c.encode(v, forKey: .config)
        case .launch(let v): try c.encode(v, forKey: .config)
        case .auth(let v): try c.encode(v, forKey: .config)
        case .gateways(let v): try c.encode(v, forKey: .config)
        case .currency(let v): try c.encode(v, forKey: .config)
        case .directory(let v): try c.encode(v, forKey: .config)
        case .models(let v): try c.encode(v, forKey: .config)
        case .ports(let v): try c.encode(v, forKey: .config)
        case .guide(let v): try c.encode(v, forKey: .config)
        }
    }
}

// MARK: - decoding, strictly

extension RecipeDocument {
    /// A document from its JSON (the compiled form of the YAML): decoded, refused when it carries a key this build does
    /// not know, and checked (`check()`).
    public static func decode(_ data: Data) throws -> RecipeDocument {
        let d = try JSONDecoder().decode(RecipeDocument.self, from: data)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let back = try JSONSerialization.jsonObject(with: try enc.encode(d))
        let original = try JSONSerialization.jsonObject(with: data)
        if let unknown = AgentRecipes.unknownKey(original, back, path: "") { throw SandboxError.invalidSpec("\(d.id): unknown key \(unknown)") }
        try d.check()
        return d
    }

    /// The rules the schema states, and the ones only Dozer can check (the derived Kit parts).
    public func check() throws {
        func bad(_ s: String) -> Error { SandboxError.invalidSpec("recipe \(id): \(s)") }
        guard schema == Self.schemaVersion else { throw bad("schema \(schema) — this build reads \(Self.schemaVersion)") }
        guard kind == "workload" else { throw bad("kind is workload") }
        guard id.range(of: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?/[a-z][a-z0-9-]*$", options: .regularExpression) != nil else { throw bad("id is VENDOR/PRODUCT") }
        guard !licenses.isEmpty, licenses.allSatisfy({ $0.range(of: "^(LicenseRef-[A-Za-z0-9.-]+|[A-Za-z0-9.+-]+)$", options: .regularExpression) != nil }) else {
            throw bad("licenses: at least one SPDX id (LicenseRef-… for one SPDX has no id for)")
        }
        let v = args.version
        guard v.default.range(of: "^(?:" + v.pattern + ")$", options: .regularExpression) != nil else { throw bad("args.version.default does not match its pattern") }
        guard v.buildArg.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { throw bad("args.version.buildArg") }
        guard provides == ["com.dozersandbox/\(product)@${{ kit.args.version }}"] else {
            throw bad("provides is [\"com.dozersandbox/\(product)@${{ kit.args.version }}\"]")
        }
        let types = capabilities.map(\.type)
        for t in [Types.networkPolicy, Types.install, Types.launch, Types.auth, Types.gateways, Types.directory] where types.filter({ $0 == t }).count != 1 {
            throw bad("exactly one \(t)")
        }
        for t in [Types.agentContext, Types.currency, Types.models, Types.ports, Types.guide] where types.filter({ $0 == t }).count > 1 { throw bad("at most one \(t)") }
        for c in capabilities where c.optional != nil || c.name != nil { throw bad("\(c.type): optional and name are export's, not the recipe's") }
        guard launch.check != nil else { throw bad("launch@1 has no check (the smoke turn make recipe-check runs)") }
        let recipe = try recipeUnchecked()
        // The Kit parts Dozer derives: equal, or the file is out of date.
        let want = Self.networkRules(recipe)
        guard networkPolicy.install == nil, networkPolicy.runtime == want else {
            throw bad("network-policy@1 runtime must be \(Self.describe(want)) (derived from config.dozer and the key provider) — and no install phase")
        }
        for c in credentials {
            guard c.phase == "runtime" else { throw bad("credential@1 \(c.service): phase runtime") }
            guard let k = Self.apiKey(c.service) else { throw bad("credential@1 \(c.service): no such key provider") }
            guard c.apiKey == k else { throw bad("credential@1 \(c.service): apiKey must be \(k) (derived from providers.json)") }
        }
        for vol in volumes where !vol.path.hasPrefix(Self.guestHome) { throw bad("volume@1 \(vol.path): a path under \(Self.guestHome)") }
        if let a = agentContext {
            guard a.directory.hasPrefix(Self.guestHome) else { throw bad("agent-context@1 directory under \(Self.guestHome)") }
            guard a.filename.range(of: #"^[^/\\]+$"#, options: .regularExpression) != nil, a.filename != ".", a.filename != ".." else { throw bad("agent-context@1 filename") }
            if a.dozer.kind == "skill", a.filename != "SKILL.md" { throw bad("agent-context@1: a skill's filename is SKILL.md") }
        }
        for s in templateStrings {
            for name in Self.templateNames(s) where !Self.allowedTemplate(name) { throw bad("\(s): ${{ \(name) }} is not a template a recipe has") }
            if Self.bareTemplate(s) { throw bad("\(s): templates are ${{ … }} (Kit's syntax), not {…}") }
        }
        // 617 (models@1): the check turn may name the selection's model and base URL (`make recipe-check` fills them in).
        for s in launch.check?.argv ?? [] {
            for name in Self.templateNames(s) where !["dozer.model", "dozer.base_url"].contains(name) { throw bad("\(s): ${{ \(name) }} is not a template a check has") }
            if !Self.templateNames(s).isEmpty, models == nil { throw bad("\(s): ${{ dozer.model }} and ${{ dozer.base_url }} need models@1") }
        }
    }

    static func describe(_ r: NetworkPolicy.Rules) -> String {
        "allow \(r.allow ?? []) deny \(r.deny ?? [])"
    }

    var product: String { String(id.split(separator: "/").last ?? "") }

    func one<T>(_ f: (RecipeCapability.Config) -> T?) -> T? { for c in capabilities { if let v = f(c.config) { return v } }; return nil }
    func all<T>(_ f: (RecipeCapability.Config) -> T?) -> [T] { capabilities.compactMap { f($0.config) } }

    var networkPolicy: NetworkPolicy { one { if case .networkPolicy(let v) = $0 { v } else { nil } }! }
    var credentials: [Credential] { all { if case .credential(let v) = $0 { v } else { nil } } }
    var volumes: [Volume] { all { if case .volume(let v) = $0 { v } else { nil } } }
    var agentContext: AgentContext? { one { if case .agentContext(let v) = $0 { v } else { nil } } }
    var install: Install { one { if case .install(let v) = $0 { v } else { nil } }! }
    var launch: Launch { one { if case .launch(let v) = $0 { v } else { nil } }! }
    var auth: AgentRecipe.Auth { one { if case .auth(let v) = $0 { v } else { nil } }! }
    var gateways: Gateways { one { if case .gateways(let v) = $0 { v } else { nil } }! }
    var currency: Currency? { one { if case .currency(let v) = $0 { v } else { nil } } }
    var models: AgentRecipe.Models? { one { if case .models(let v) = $0 { v } else { nil } } }
    var directory: Directory { one { if case .directory(let v) = $0 { v } else { nil } }! }
    var ports: AgentRecipe.WebPorts? { one { if case .ports(let v) = $0 { v } else { nil } } }
    var guide: AgentRecipe.Guide? { one { if case .guide(let v) = $0 { v } else { nil } } }

    /// Every string that is a template.
    var templateStrings: [String] {
        var out = [install.url].compactMap { $0 } + launch.verify.compactMap(\.expect)
        for e in models?.shapes ?? [] { out += e.env.values.sorted() }
        for e in models?.native ?? [] { out += e.env.values.sorted() }
        for g in gateways.entries {
            guard let h = g.how else { continue }
            out += (h.env ?? [:]).values.sorted() + (h.args ?? []) + (h.modelArgs ?? [])
            for c in h.config ?? [] { for v in c.set.values { if case .string(let s) = v { out.append(s) } } }
        }
        return out
    }
}

// MARK: - templating

extension RecipeDocument {
    static let templatePattern = #"\$\{\{\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*\}\}"#

    /// The names in `${{ … }}` references.
    static func templateNames(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: templatePattern)
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    static func allowedTemplate(_ name: String) -> Bool {
        name == "kit.args.version" || name == "dozer.build" || name == "dozer.placeholder" || name == "dozer.model" || name == "dozer.base_url"
            || name.range(of: #"^dozer\.gateway\.endpoint\.[a-z0-9-]+$"#, options: .regularExpression) != nil
    }

    /// A `{name}` left in the old syntax.
    static func bareTemplate(_ s: String) -> Bool {
        let stripped = s.replacingOccurrences(of: templatePattern, with: "", options: .regularExpression)
        return stripped.range(of: #"\{[a-z][a-z0-9.-]*\}"#, options: .regularExpression) != nil
    }

    /// `${{ kit.args.version }}` → `{version}`, `${{ dozer.NAME }}` → `{NAME}` — the model's own syntax.
    static func toModel(_ s: String) -> String {
        let re = try! NSRegularExpression(pattern: templatePattern)
        let ns = s as NSString
        var out = "", last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            out += "{" + (name == "kit.args.version" ? "version" : String(name.dropFirst("dozer.".count))) + "}"
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// `{version}` → `${{ kit.args.version }}`, `{NAME}` → `${{ dozer.NAME }}`.
    static func toFile(_ s: String) -> String {
        let re = try! NSRegularExpression(pattern: #"\{([a-z][a-z0-9._-]*)\}"#)
        let ns = s as NSString
        var out = "", last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            out += "${{ " + (name == "version" ? "kit.args.version" : "dozer." + name) + " }}"
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// 617: models@1's env values between the file's templates and the model's.
    static func mapModels(_ m: AgentRecipe.Models, _ f: @escaping (String) -> String) -> AgentRecipe.Models {
        var x = m
        x.shapes = m.shapes?.map { var e = $0; e.env = e.env.mapValues(f); return e }
        x.native = m.native?.map { var e = $0; e.env = e.env.mapValues(f); return e }
        return x
    }

    static func mapGateway(_ g: AgentRecipe.GatewaySupport, _ f: @escaping (String) -> String) -> AgentRecipe.GatewaySupport {
        var x = g
        guard var h = g.how else { return x }
        h.env = h.env?.mapValues(f)
        h.args = h.args?.map(f)
        h.modelArgs = h.modelArgs?.map(f)
        h.config = h.config?.map { c in
            var y = c
            y.set = c.set.mapValues { v in if case .string(let s) = v { return .string(f(s)) }; return v }
            return y
        }
        x.how = h
        return x
    }

    static func toGuest(_ p: String) -> String { p.hasPrefix("~/") ? guestHome + p.dropFirst(2) : p }
    static func toModelPath(_ p: String) -> String { p.hasPrefix(guestHome) ? "~/" + p.dropFirst(guestHome.count) : p }
}

// MARK: - the derived Kit parts

extension RecipeDocument {
    /// network-policy@1's runtime lists: allow its model's hosts (the recipe's, else its key provider's) and its
    /// vendor's start-up hosts; deny what it keeps out (`excluded`, `quiet`). `host:443`, in order, once each.
    public static func networkRules(_ r: AgentRecipe) -> NetworkPolicy.Rules {
        func uniq(_ a: [String]) -> [String] { var seen = Set<String>(); return a.filter { seen.insert($0).inserted } }
        let model = r.network.model.hosts.map { $0.map(\.host) } ?? (r.provider.flatMap { KeyProviders.provider($0)?.hosts } ?? [])
        let allow = uniq(model + (r.network.vendor ?? []).map(\.host)).map { $0 + ":443" }
        let deny = uniq(r.network.excluded + (r.network.quiet ?? []).map(\.host)).map { $0 + ":443" }
        return NetworkPolicy.Rules(allow: allow.isEmpty ? nil : allow, deny: deny.isEmpty ? nil : deny)
    }

    /// credential@1's apiKey for a key provider: its variable, proxy-managed, injected on each of its hosts.
    public static func apiKey(_ provider: String) -> Credential.ApiKey? {
        guard let p = KeyProviders.provider(provider) else { return nil }
        return Credential.ApiKey(name: p.env, proxyManaged: true,
                                 inject: p.hosts.map { Credential.Inject(domain: $0, header: p.inject.header, format: p.inject.format) })
    }
}

// MARK: - document ⇄ model

extension RecipeDocument {
    /// The model everything else uses (validated by `AgentRecipes.validate` as before).
    public func recipe() throws -> AgentRecipe {
        try check()
        return try recipeUnchecked()
    }

    func recipeUnchecked() throws -> AgentRecipe {
        let i = install, l = launch, d = directory
        let prompt = agentContext.map { a in
            AgentRecipe.Prompt(kind: a.dozer.kind, dir: Self.toModelPath(a.directory), file: a.dozer.kind == "skill" ? nil : a.filename,
                               manifest: a.dozer.manifest, launcherArg: a.dozer.launcherArg)
        }
        return AgentRecipe(
            schema: 1, id: product, title: displayName, description: description, publisher: author, licence: d.licence ?? licenses[0], homepage: sourceUrl,
            aliases: d.aliases, builtin: i.builtin, defaultBase: d.defaultBase, platforms: d.platforms, limits: d.limits,
            install: AgentRecipe.Install(kind: i.kind, manifest: i.manifest, url: i.url.map(Self.toModel), package: i.package,
                                         platformPackage: i.platformPackage, payload: i.payload, compression: i.compression, binary: i.binary,
                                         needsNode: i.needsNode, npmArgs: i.npmArgs,
                                         pinned: AgentRecipe.Pin(version: args.version.default, integrity: i.integrity), bakeHosts: i.bakeHosts,
                                         requirements: i.requirements,
                                         extras: i.extras?.map { var e = $0; e.url = Self.toModel(e.url); e.path = Self.toModel(e.path); return e }),
            launch: AgentRecipe.Launch(command: l.command, noPromptsArgs: l.noPromptsArgs, noPromptsEnv: l.noPromptsEnv, passthrough: l.passthrough,
                                       env: l.env, firstRun: l.firstRun, sessionEnv: l.sessionEnv, session: l.session),
            state: AgentRecipe.State(persist: volumes.map { Self.toModelPath($0.path) }, env: l.stateEnv),
            credentials: credentials.map { AgentRecipe.CredentialUse(provider: $0.service, accounts: $0.dozer.accounts, envAliases: $0.dozer.envAliases) },
            network: networkPolicy.dozer, status: l.status, prompt: prompt, resume: l.resume, resumeCheck: l.resumeCheck,
            verify: l.verify.map { AgentRecipe.Check(argv: $0.argv, expect: $0.expect.map(Self.toModel)) }, smoke: l.check,
            terms: d.terms, lifecycle: currency?.lifecycle, icon: d.icon, checked: currency?.checked, settings: l.settings, auth: auth,
            gateways: gateways.entries.map { Self.mapGateway($0, Self.toModel) }, tags: d.tags, catalogKind: d.kind, categories: d.categories, guide: guide,
            models: models.map { Self.mapModels($0, Self.toModel) }, ports: ports)
    }

    /// The file a model would be written as (the inverse of `recipe()`): what the recipe says, plus what only the file
    /// has — its vendor, its description, its SPDX licences and its version's pattern and build arg.
    public init(_ r: AgentRecipe, vendor: String, description: String? = nil, licenses: [String],
                versionPattern: String = #"[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?"#) {
        schema = Self.schemaVersion
        kind = "workload"
        id = vendor + "/" + r.id
        displayName = r.title
        self.description = description ?? r.description ?? r.title
        author = r.publisher
        sourceUrl = r.homepage
        self.licenses = licenses
        args = Args(version: KitArg(default: r.install.pinned.version, pattern: versionPattern,
                                    buildArg: r.id.uppercased().replacingOccurrences(of: "-", with: "_") + "_VERSION",
                                    description: "The \(r.title) release Dozer installs (its pin)."))
        provides = ["com.dozersandbox/\(r.id)@${{ kit.args.version }}"]
        typealias T = Types
        var caps: [RecipeCapability] = [
            RecipeCapability(type: T.networkPolicy, config: .networkPolicy(NetworkPolicy(install: nil, runtime: Self.networkRules(r), dozer: r.network))),
        ]
        for c in r.credentials {
            caps.append(RecipeCapability(type: T.credential, description: (KeyProviders.provider(c.provider)?.title ?? c.provider) + " API access",
                                         config: .credential(Credential(service: c.provider, phase: "runtime",
                                                                        apiKey: Self.apiKey(c.provider) ?? Credential.ApiKey(name: "", proxyManaged: true, inject: []),
                                                                        dozer: Credential.CredentialDozer(accounts: c.accounts, envAliases: c.envAliases)))))
        }
        for p in r.state.persist { caps.append(RecipeCapability(type: T.volume, config: .volume(Volume(path: Self.toGuest(p))))) }
        if let p = r.prompt {
            caps.append(RecipeCapability(type: T.agentContext, config: .agentContext(AgentContext(
                directory: Self.toGuest(p.dir ?? ""), filename: p.file ?? "SKILL.md",
                dozer: AgentContext.AgentContextDozer(kind: p.kind, manifest: p.manifest, launcherArg: p.launcherArg)))))
        }
        let i = r.install
        caps.append(RecipeCapability(type: T.install, config: .install(Install(
            kind: i.kind, builtin: r.builtin, package: i.package, platformPackage: i.platformPackage, payload: i.payload, compression: i.compression,
            binary: i.binary, needsNode: i.needsNode, npmArgs: i.npmArgs, manifest: i.manifest, url: i.url.map(Self.toFile), bakeHosts: i.bakeHosts,
            integrity: i.pinned.integrity, requirements: i.requirements,
            extras: i.extras?.map { var e = $0; e.url = Self.toFile(e.url); e.path = Self.toFile(e.path); return e }))))
        let l = r.launch
        caps.append(RecipeCapability(type: T.launch, config: .launch(Launch(
            command: l.command, noPromptsArgs: l.noPromptsArgs, noPromptsEnv: l.noPromptsEnv, passthrough: l.passthrough, env: l.env, stateEnv: r.state.env,
            firstRun: l.firstRun, sessionEnv: l.sessionEnv, session: l.session, status: r.status, resume: r.resume, resumeCheck: r.resumeCheck,
            verify: r.verify.map { AgentRecipe.Check(argv: $0.argv, expect: $0.expect.map(Self.toFile)) }, check: r.smoke, settings: r.settings))))
        caps.append(RecipeCapability(type: T.auth, config: .auth(r.auth)))
        caps.append(RecipeCapability(type: T.gateways, config: .gateways(Gateways(entries: r.gateways.map { Self.mapGateway($0, Self.toFile) }))))
        if let m = r.models { caps.append(RecipeCapability(type: T.models, config: .models(Self.mapModels(m, Self.toFile)))) }
        if r.checked != nil || r.lifecycle != nil {
            caps.append(RecipeCapability(type: T.currency, config: .currency(Currency(checked: r.checked, lifecycle: r.lifecycle))))
        }
        caps.append(RecipeCapability(type: T.directory, config: .directory(Directory(
            aliases: r.aliases, icon: r.icon, defaultBase: r.defaultBase, platforms: r.platforms, limits: r.limits, tags: r.tags, terms: r.terms,
            licence: licenses == [r.licence] ? nil : r.licence, kind: r.catalogKind, categories: r.categories))))
        if let p = r.ports { caps.append(RecipeCapability(type: T.ports, config: .ports(p))) }
        if let g = r.guide { caps.append(RecipeCapability(type: T.guide, config: .guide(g))) }
        capabilities = caps
    }
}

// MARK: - the Kit view

extension RecipeDocument {
    /// The recipe as a Docker Sandbox Kit v3 descriptor (a JSON object): `schemaVersion: "3"`, Kit's top-level fields,
    /// Kit's own capabilities with every `dozer:` key removed, Dozer's types kept as `optional: true` (a Kit host skips
    /// an optional type it does not know, §7.3) with `${{ dozer.* }}` written as `{dozer.*}` (inert to Kit). The
    /// install-and-launch part (a Dockerfile, its ENTRYPOINT) is `doz recipe export --kit`'s, later. RecipeSchemaTests
    /// checks this view against Kit's own published JSON Schema.
    public func kitDescriptor() throws -> [String: Any] {
        let enc = JSONEncoder()
        guard let me = try JSONSerialization.jsonObject(with: try enc.encode(self)) as? [String: Any] else { return [:] }
        func inert(_ v: Any) -> Any {
            if let s = v as? String {
                let re = try! NSRegularExpression(pattern: #"\$\{\{\s*(dozer\.[A-Za-z0-9_.-]+)\s*\}\}"#)
                return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "{$1}")
            }
            if let a = v as? [Any] { return a.map(inert) }
            if let o = v as? [String: Any] { return o.mapValues(inert) }
            return v
        }
        var out: [String: Any] = ["schemaVersion": "3", "kind": kind, "displayName": displayName, "description": description,
                                  "author": author, "sourceUrl": sourceUrl, "licenses": licenses, "provides": provides]
        out["args"] = me["args"]
        var caps: [[String: Any]] = []
        for c in (me["capabilities"] as? [[String: Any]]) ?? [] {
            var e = c
            let type = c["type"] as? String ?? ""
            if Types.kit.contains(type) {
                var cfg = c["config"] as? [String: Any] ?? [:]
                cfg["dozer"] = nil
                e["config"] = cfg
            } else {
                e["optional"] = true
                e["config"] = inert(c["config"] ?? [:])
            }
            caps.append(e)
        }
        out["capabilities"] = caps
        return out
    }
}
