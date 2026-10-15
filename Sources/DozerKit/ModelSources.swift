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
            enum CodingKeys: String, CodingKey { case shape, env, keyEnv = "key_env" }
            public init(shape: String, env: [String: String], keyEnv: [String]? = nil) { self.shape = shape; self.env = env; self.keyEnv = keyEnv }
        }

        public struct NativeEntry: Codable, Sendable, Equatable {
            public var source: String
            /// `{model}` only (a native client has no base URL).
            public var env: [String: String]
            public var keyEnv: [String]?
            enum CodingKeys: String, CodingKey { case source, env, keyEnv = "key_env" }
            public init(source: String, env: [String: String], keyEnv: [String]? = nil) { self.source = source; self.env = env; self.keyEnv = keyEnv }
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
            let eps = ModelSources.endpoints(s)
            if (m.shapes ?? []).contains(where: { e in eps.contains { $0.shapes.contains(e.shape) } }) { out.append(s) }
        }
        guard out.contains(m.default) else { return out }
        return [m.default] + out.filter { $0 != m.default }
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
        for e in m.shapes ?? [] {
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
        guard !isBuiltin else { throw bad("models@1 is a recipe agent's (the built-in agents keep their own accounts)") }
        let ids = Set(ModelSources.ids)
        guard ids.contains(m.default) else { throw bad("models default \(m.default) is not a provider or gateway") }
        guard credentials.first?.provider == m.default else { throw bad("models default \(m.default) is its credential's provider") }
        var shapes = Set<String>()
        for e in m.shapes ?? [] {
            guard Gateway.shapes.contains(e.shape), shapes.insert(e.shape).inserted else { throw bad("models shape \(e.shape): a known shape, once") }
            try Self.validateSelectionEnv(e.env, keyEnv: e.keyEnv, baseURL: true, recipe: self, bad)
        }
        var natives = Set<String>()
        for n in m.native ?? [] {
            guard ids.contains(n.source), natives.insert(n.source).inserted else { throw bad("models native \(n.source): a provider or gateway, once") }
            try Self.validateSelectionEnv(n.env, keyEnv: n.keyEnv, baseURL: false, recipe: self, bad)
        }
        for x in m.except ?? [] where !ids.contains(x) { throw bad("models except \(x) is not a provider or gateway") }
        let offered = offeredSources
        guard offered.first == m.default else { throw bad("models default \(m.default) is not offered by its shapes or native entries") }
        for (s, v) in m.models ?? [:] {
            guard offered.contains(s), ModelSelection.isModelID(v) else { throw bad("models.\(s): an offered source and a model id") }
        }
        // Its model permission reaches every source it is offered (the key still goes only to the source chosen).
        let reach = Set((network.model.hosts ?? []).map(\.host))
        for s in offered {
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
            if stripped.contains("{") { throw bad("models env \(k): only {base_url} and {model}") }
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
public enum ModelSources {
    public static var ids: [String] { KeyProviders.all.map(\.id) }

    public static func isGateway(_ id: String) -> Bool { KeyProviders.provider(id)?.gateway == true }

    /// The endpoints offered to recipes (those with a default model; a gateway's coding-agent variants are not).
    public static func endpoints(_ id: String) -> [Gateway.Endpoint] {
        guard let p = KeyProviders.provider(id) else { return [] }
        let all = p.gateway == true ? (Gateways.gateway(id)?.endpoints ?? []) : (p.endpoints ?? [])
        return all.filter { $0.defaultModel != nil }
    }

    /// The hosts its key may go to (the proxy's binding).
    public static func hosts(_ id: String) -> [String] { KeyProviders.provider(id)?.hosts ?? [] }

    public static func title(_ id: String) -> String { KeyProviders.provider(id)?.title ?? id }

    /// The account kind a source's key comes in: Anthropic an API key (`api-key`), OpenAI an OpenAI key (`openai-key`),
    /// every other a `key` of that provider. Never a subscription (a Claude login, a ChatGPT sign-in, this Mac's Codex).
    public static func accountKind(_ id: String) -> String {
        switch id {
        case "anthropic": "api-key"
        case "openai": "openai-key"
        default: "key"
        }
    }
}
