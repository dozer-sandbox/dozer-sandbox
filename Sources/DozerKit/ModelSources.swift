import Foundation

// 617 (owner: "add OpenAI and Anthropic AND gateway support"): a recipe can be tried with any MODEL SOURCE — a provider
// (Anthropic, OpenAI, xAI, Google) or a gateway (OpenRouter, Vercel AI Gateway) — whose API shape it speaks. The idea is
// DeckStack's model binding (a selection → the agent's native settings; a downloaded recipe may ask for a model binding
// but never chooses where a secret goes), re-done here and stricter: the recipe says only which shapes it speaks and how
// a choice reaches its own settings (`models@1`); Dozer owns the key — its binding, its hosts, its placeholder — and the
// proxy swaps the real key only into requests to that source's own hosts. A recipe-chosen base URL is therefore harmless.
// docs/recipes/RECIPE-FORMAT.md, "Model sources".

extension AgentRecipe {
    /// models@1.
    public struct Models: Codable, Sendable, Equatable {
        /// The source a try uses when none is chosen.
        public var `default`: String
        /// Shapes it speaks to ANY source's base URL, preferred first.
        public var shapes: [ShapeEntry]?
        /// Sources it reaches through its own client (no base URL).
        public var native: [NativeEntry]?
        /// Sources a shape would offer that it is not offered.
        public var except: [String]?
        /// A default model per source, over the source endpoint's own.
        public var models: [String: String]?

        public init(default: String, shapes: [ShapeEntry]? = nil, native: [NativeEntry]? = nil, except: [String]? = nil, models: [String: String]? = nil) {
            self.default = `default`; self.shapes = shapes; self.native = native; self.except = except; self.models = models
        }

        public struct ShapeEntry: Codable, Sendable, Equatable {
            public var shape: String
            /// Set at every session open and exec (never over the caller's own value); `{base_url}`, `{model}`.
            public var env: [String: String]
            /// Where the tool reads the key for this shape — the placeholder is put there too.
            public var keyEnv: [String]?
            /// Where the tool documents taking this shape's base URL, key and model (an https page) — what makes a gateway
            /// it offers count as `documented` without a gateways@1 entry of its own.
            public var source: String?
            enum CodingKeys: String, CodingKey { case shape, env, keyEnv = "key_env", source }
            public init(shape: String, env: [String: String], keyEnv: [String]? = nil, source: String? = nil) {
                self.shape = shape; self.env = env; self.keyEnv = keyEnv; self.source = source
            }
        }

        public struct NativeEntry: Codable, Sendable, Equatable {
            public var source: String
            /// `{model}` only (a native client has no base URL).
            public var env: [String: String]
            public var keyEnv: [String]?
            /// Where the tool documents this source (an https page), as `ShapeEntry.source`.
            public var docs: String?
            enum CodingKeys: String, CodingKey { case source, env, keyEnv = "key_env", docs }
            public init(source: String, env: [String: String], keyEnv: [String]? = nil, docs: String? = nil) {
                self.source = source; self.env = env; self.keyEnv = keyEnv; self.docs = docs
            }
        }
    }

    /// 617: the sources this agent can be tried with — its default first, then the providers.json order. A recipe without
    /// models@1: its credential's provider (a built-in agent's included).
    public var offeredSources: [String] {
        guard let m = models else { return credentials.map(\.provider) }
        let except = Set(m.except ?? [])
        var out: [String] = []
        for s in ModelSources.ids where !except.contains(s) {
            if (m.native ?? []).contains(where: { $0.source == s }) { out.append(s); continue }
            // 618: a key-less source is a tool's own (OpenCode Zen's free models): offered by a native entry only.
            if ModelSources.isKeyless(s) { continue }
            let eps = ModelSources.endpoints(s)
            if (m.shapes ?? []).contains(where: { e in eps.contains { $0.shapes.contains(e.shape) } }) { out.append(s) }
        }
        guard out.contains(m.default) else { return out }
        return [m.default] + out.filter { $0 != m.default }
    }

    /// 618 (owner: "openrouter can behave as an openai compatible model API"): how it works through each catalogue
    /// gateway — THE list the plan's offer, `doz search`, the tags and the Quick try's "Through a gateway" read. A gateway
    /// models@1 offers (a shape the gateway serves, or a native entry) needs no gateways@1 entry: it is derived, as
    /// `documented` from the entry's own `source`. A gateways@1 entry overrides it — `verified` once `make recipe-check`
    /// has run the tool through it (its evidence), or the levels of a tool without models@1. Catalogue order.
    public var gatewaySupport: [GatewaySupport] {
        Gateways.all.compactMap { g in
            if let e = gateways.first(where: { $0.gateway == g.id }) { return e }
            return derivedGateway(g.id)
        }
    }

    /// True when a try can go through `gateway` (models@1 offers it).
    public func offersGateway(_ gateway: String) -> Bool { models != nil && offeredSources.contains(gateway) }

    /// A try through some gateway is possible — the Quick try's "Through a gateway".
    public var throughGateway: Bool { Gateways.all.contains { offersGateway($0.id) } }

    /// The entry models@1 implies for an offered gateway (nil: not offered, or no source to cite).
    func derivedGateway(_ gateway: String) -> GatewaySupport? {
        guard offersGateway(gateway), let m = models else { return nil }
        if let n = m.native?.first(where: { $0.source == gateway }) {
            guard let d = n.docs else { return nil }
            return GatewaySupport(gateway: gateway, level: "documented", evidence: "offered through its own client (models@1)", source: d, checked: checked)
        }
        for e in m.shapes ?? [] {
            guard let ep = ModelSources.endpoints(gateway).first(where: { $0.shapes.contains(e.shape) }) else { continue }
            guard let d = e.source else { return nil }
            return GatewaySupport(gateway: gateway, level: "documented", shape: e.shape, endpoint: ep.id,
                                  evidence: "offered through its \(e.shape) base URL (models@1)", source: d, checked: checked)
        }
        return nil
    }

    /// 617: what a choice of `source` (and `model`, else the default) does — nil when the source is not offered, or the
    /// recipe has no models@1.
    public func selection(source: String, model: String? = nil) -> ModelSelection? {
        guard let m = models, offeredSources.contains(source) else { return nil }
        if let n = m.native?.first(where: { $0.source == source }) {
            let chosen = model ?? m.models?[source] ?? ModelSources.endpoints(source).first?.defaultModel ?? ""
            return ModelSelection(source: source, shape: nil, baseURL: nil, model: chosen,
                                  env: ModelSelection.fill(n.env, baseURL: nil, model: chosen), keyEnv: n.keyEnv ?? [])
        }
        for e in m.shapes ?? [] where !ModelSources.isKeyless(source) {
            guard let ep = ModelSources.endpoints(source).first(where: { $0.shapes.contains(e.shape) }) else { continue }
            let chosen = model ?? m.models?[source] ?? ep.defaultModel ?? ""
            return ModelSelection(source: source, shape: e.shape, baseURL: ep.baseUrl, model: chosen,
                                  env: ModelSelection.fill(e.env, baseURL: ep.baseUrl, model: chosen), keyEnv: e.keyEnv ?? [])
        }
        return nil
    }

    /// models@1's own rules (from `validate()`).
    func validateModels(_ bad: (String) -> SandboxError) throws {
        guard let m = models else { return }
        // 618: a built-in agent (pi) may declare its sources — native only, at session time (nothing baked: its image is
        // Dozer's own); Claude Code and Codex keep their own accounts.
        if isBuiltin, (id == "claude-code" || id == "codex" || !(m.shapes ?? []).isEmpty) {
            throw bad("models@1 of a built-in agent: pi's only, native sources only (Claude Code and Codex keep their own accounts)")
        }
        let ids = Set(ModelSources.ids)
        guard ids.contains(m.default) else { throw bad("models default \(m.default) is not a provider or gateway") }
        guard credentials.first?.provider == m.default else { throw bad("models default \(m.default) is its credential's provider") }
        var shapes = Set<String>()
        for e in m.shapes ?? [] {
            guard Gateway.shapes.contains(e.shape), shapes.insert(e.shape).inserted else { throw bad("models shape \(e.shape): a known shape, once") }
            if let u = e.source, !u.hasPrefix("https://") { throw bad("models shape \(e.shape): source is an https URL") }
            try Self.validateSelectionEnv(e.env, keyEnv: e.keyEnv, baseURL: true, recipe: self, bad)
        }
        var natives = Set<String>()
        for n in m.native ?? [] {
            guard ids.contains(n.source), natives.insert(n.source).inserted else { throw bad("models native \(n.source): a provider or gateway, once") }
            if let u = n.docs, !u.hasPrefix("https://") { throw bad("models native \(n.source): docs is an https URL") }
            try Self.validateSelectionEnv(n.env, keyEnv: n.keyEnv, baseURL: false, recipe: self, bad)
        }
        for x in m.except ?? [] where !ids.contains(x) { throw bad("models except \(x) is not a provider or gateway") }
        let offered = offeredSources
        guard offered.first == m.default else { throw bad("models default \(m.default) is not offered by its shapes or native entries") }
        for (s, v) in m.models ?? [:] {
            guard offered.contains(s), ModelSelection.isModelID(v) else { throw bad("models.\(s): an offered source and a model id") }
        }
        // Its model permission reaches every source it is offered (the key still goes only to the source chosen) — a
        // built-in agent's other sources through its hidden `sources:` permission (AgentPermissions.sourcesPermission).
        let reach = Set((network.model.hosts ?? []).map(\.host))
        for s in offered where !isBuiltin {
            for h in ModelSources.hosts(s) where !reach.contains(h) { throw bad("its model permission does not reach \(h) (\(s))") }
        }
    }

    static func validateSelectionEnv(_ env: [String: String], keyEnv: [String]?, baseURL: Bool, recipe: AgentRecipe, _ bad: (String) -> SandboxError) throws {
        let safe = { (s: String) in !s.contains("'") && !s.contains("\n") && !s.contains("\\") && !s.contains("$(") && !s.contains("`") }
        for (k, v) in env {
            guard k.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil, !BakeEnvironment.isCredential(k), safe(v) else {
                throw bad("models env \(k): a variable name that names no credential, and a plain value")
            }
            if !baseURL, v.contains("{base_url}") { throw bad("models native env \(k): no {base_url} (a native client has none)") }
            let stripped = v.replacingOccurrences(of: "{base_url}", with: "").replacingOccurrences(of: "{model}", with: "")
            // 618: a JSON value may hold braces (Mistral Vibe's VIBE_PROVIDERS); a template other than these two may not.
            if stripped.range(of: "\\{[A-Za-z_][A-Za-z0-9_.]*\\}", options: .regularExpression) != nil { throw bad("models env \(k): only {base_url} and {model}") }
        }
        var seen = Set<String>()
        for a in keyEnv ?? [] {
            guard a.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil, BakeEnvironment.isCredential(a) || a.hasSuffix("_KEY"),
                  !recipe.everyEnvName(a), env[a] == nil, seen.insert(a).inserted else {
                throw bad("models key_env \(a): a credential-shaped variable (…_KEY), once, not one the recipe sets")
            }
        }
    }
}

/// 617: one choice of model source for a recipe agent, resolved — what its sessions and execs get.
public struct ModelSelection: Sendable, Equatable {
    public var source: String
    /// The shape spoken (nil: its native client).
    public var shape: String?
    public var baseURL: String?
    public var model: String
    /// The recipe's entry with `{base_url}` and `{model}` filled in.
    public var env: [String: String]
    /// The tool's own names for the key (the placeholder rides there too, beside the source's own variable).
    public var keyEnv: [String]

    public init(source: String, shape: String?, baseURL: String?, model: String, env: [String: String], keyEnv: [String]) {
        self.source = source; self.shape = shape; self.baseURL = baseURL; self.model = model; self.env = env; self.keyEnv = keyEnv
    }

    static func fill(_ env: [String: String], baseURL: String?, model: String) -> [String: String] {
        env.mapValues { $0.replacingOccurrences(of: "{base_url}", with: baseURL ?? "").replacingOccurrences(of: "{model}", with: model) }
    }

    /// A model id a person may give (`--model`): what providers and gateways name models with, nothing a shell reads.
    public static func isModelID(_ s: String) -> Bool {
        s.count <= 128 && s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$"#, options: .regularExpression) != nil
    }
}

/// 617: the model sources — every key provider of providers.json, in its order; a gateway's endpoints are gateways.json's.
/// 618: then the key-less sources (providers.json `keyless`: OpenCode Zen's free models) — no key, no account.
public enum ModelSources {
    public static var ids: [String] { KeyProviders.all.map(\.id) + KeyProviders.keyless.map(\.id) }

    /// The sources that take a key (an account of one is a key of it).
    public static var keyed: [String] { KeyProviders.all.map(\.id) }

    public static func isGateway(_ id: String) -> Bool { KeyProviders.provider(id)?.gateway == true }

    /// 618: a source that takes no key (nothing to add; a try with it has no account).
    public static func isKeyless(_ id: String) -> Bool { keyless(id) != nil }

    public static func keyless(_ id: String) -> KeylessSource? { KeyProviders.keyless.first { $0.id == id } }

    /// The endpoints offered to recipes (those with a default model; a gateway's coding-agent variants are not).
    public static func endpoints(_ id: String) -> [Gateway.Endpoint] {
        if let k = keyless(id) { return k.endpoints }
        guard let p = KeyProviders.provider(id) else { return [] }
        let all = p.gateway == true ? (Gateways.gateway(id)?.endpoints ?? []) : (p.endpoints ?? [])
        return all.filter { $0.defaultModel != nil }
    }

    /// The hosts its key may go to (the proxy's binding); a key-less source's, the hosts it answers on (no key goes there).
    public static func hosts(_ id: String) -> [String] { keyless(id)?.hosts ?? KeyProviders.provider(id)?.hosts ?? [] }

    /// The hosts a source's KEY may go to — none for a key-less source (the leak guard watches these).
    public static func keyHosts(_ id: String) -> [String] { KeyProviders.provider(id)?.hosts ?? [] }

    public static func title(_ id: String) -> String { keyless(id)?.title ?? KeyProviders.provider(id)?.title ?? id }

    /// The account kind a source's key comes in: Anthropic an API key (`api-key`), OpenAI an OpenAI key (`openai-key`),
    /// every other a `key` of that provider. Never a subscription (a Claude login, a ChatGPT sign-in, this Mac's Codex).
    /// 618: a key-less source, `none` — no account at all.
    public static func accountKind(_ id: String) -> String {
        if isKeyless(id) { return "none" }
        switch id {
        case "anthropic": return "api-key"
        case "openai": return "openai-key"
        default: return "key"
        }
    }
}

/// 618 (owner: "OpenCode Zen free models, no key"): a model source that takes no key — the tool reaches it with no
/// account (OpenCode 2 without a key uses OpenCode Zen's free models). Dozer adds nothing to its requests; its hosts are
/// reachable only through the recipe's model permission, path by path. The list of models is curated (the public model
/// list has no prices, so it cannot tell a free model from a paid one): the free models the docs list that the tool's
/// pinned release can use without a key (OpenCode 2.0.29 enables only its catalogue's zero-cost models when it has
/// none), each with its data terms as the docs state them.
public struct KeylessSource: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var hosts: [String]
    public var endpoints: [Gateway.Endpoint]
    public var models: [Model]
    /// Where the source documents its models and their terms (an https page).
    public var docs: String
    /// When the list and the terms were last checked against the docs (YYYY-MM-DD).
    public var checked: String

    public struct Model: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// Its data terms as the docs state them — short, the docs' own words where they have them.
        public var note: String?
    }
}
