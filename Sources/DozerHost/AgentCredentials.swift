import Foundation
import DozerKit

// 594 (owner, 2026-09-30: "creating a Pi sandbox should have pre-requisites for things like API key so
// that this is not the first experience"): each agent says which credentials it can use
// (`AgentImages.credentials`), and a sandbox is checked against it BEFORE it is created — the CLI, New
// sandbox, the wizard, Duplicate — and an existing one whose account does not fit says so (and the
// account is not handed to an agent that cannot use it: a Claude subscription never reaches pi).
// 617: the kinds come from the agent's recipe. A recipe agent takes an API key of a MODEL SOURCE it is offered
// (`AgentRecipe.offeredSources`, models@1 — providers and gateways): a `key` account of that provider, an Anthropic
// API key (`api-key`) or an OpenAI one (`openai-key`) — never a subscription (a Claude login, a ChatGPT sign-in, this
// Mac's Codex). The built-in three keep their own flows (`codexFlow` is Codex's).

public enum AgentCredentials {
    /// 617: the model sources a recipe agent of `image` can use (its default first); nil: a built-in agent or none.
    public static func sources(_ image: String?) -> [String]? {
        guard let image, let r = ImageChoice.parse(image)?.agent.recipe, !r.isBuiltin else { return nil }
        return r.offeredSources
    }

    /// 617: the source an account's key belongs to — nil for a subscription or a login (never a recipe agent's).
    public static func source(of kind: AccountKind, provider: String?) -> String? {
        switch kind {
        case .apiKey: "anthropic"
        case .openaiKey: "openai"
        case .key: provider
        default: nil
        }
    }

    public static func source(of a: AccountRecord) -> String? { source(of: a.kind, provider: a.provider) }

    /// 617: Codex's own account flow (this Mac's Codex login, a ChatGPT sign-in, an OpenAI key) — the built-in Codex
    /// only, never a recipe agent that is offered OpenAI.
    public static func codexFlow(_ image: String?) -> Bool {
        guard let image, let r = ImageChoice.parse(image)?.agent.recipe else { return false }
        return r.isBuiltin && r.credentials.first?.provider == "openai"
    }

    /// The account kinds the agent of `image` (an image spec's name: claude-code, pi) can use; nil: no
    /// agent there (the lab), so any account fits.
    public static func kinds(_ image: String?) -> Set<AccountKind>? {
        if let s = sources(image) { return Set(s.compactMap { AccountKind(rawValue: ModelSources.accountKind($0)) }) }
        guard let image, let c = AgentImages.credentials(image) else { return nil }
        return Set(c.flatMap(\.accountKinds).compactMap(AccountKind.init(rawValue:)))
    }

    /// 617: whether the agent of `image` can use an account of `kind` from `provider` (only a `key` account has one).
    public static func accepts(_ image: String?, _ kind: AccountKind, provider: String? = nil) -> Bool {
        if let s = sources(image) { return source(of: kind, provider: provider).map(s.contains) ?? false }
        guard let k = kinds(image) else { return true }
        guard k.contains(kind) else { return false }
        return kind != .key || provider == Self.provider(image)
    }

    public static func accepts(_ image: String?, _ a: AccountRecord) -> Bool { accepts(image, a.kind, provider: a.provider) }

    /// An agent that has no way to work without one of its accounts (pi, Codex, the recipe agents); Claude Code may
    /// be created with none, as before.
    public static func needsAccount(_ image: String?) -> Bool {
        guard let k = kinds(image) else { return false }
        return !k.contains(.mac)
    }

    /// 617: the recipe agent's DEFAULT source's key provider (`xai`, `google`, … `anthropic`, `openai`); nil for the
    /// built-in three.
    public static func keyProvider(_ image: String?) -> KeyProvider? {
        guard let s = sources(image)?.first else { return nil }
        return KeyProviders.provider(s)
    }

    /// 617: "an xAI key", "an OpenAI API key", "an OpenRouter key".
    static func keyPhrase(_ source: String) -> String {
        let t = ModelSources.title(source)
        let article = ["A", "E", "I", "O", "U", "x"].contains(where: t.hasPrefix) ? "an" : "a"
        return "\(article) \(t) \(t.contains("API") ? "key" : (ModelSources.isGateway(source) ? "key" : "API key"))"
    }

    /// "pi needs an Anthropic API key"; 617: "llm needs an xAI API key, an OpenAI API key or an OpenRouter key".
    public static func requirement(_ image: String) -> String {
        let name = AgentImages.agentName(image) ?? image
        guard let k = kinds(image) else { return "" }
        if let s = sources(image), !s.isEmpty {
            let phrases = s.map(keyPhrase)
            return "\(name) needs " + (phrases.count == 1 ? phrases[0] : phrases.dropLast().joined(separator: ", ") + " or " + phrases.last!)
        }
        if k == [.apiKey] { return "\(name) needs an Anthropic API key" }
        // 599i: Codex — an OpenAI account.
        if codexFlow(image) { return "\(name) needs an OpenAI account: this Mac's Codex login, a ChatGPT sign-in or an OpenAI API key" }
        return "\(name) needs an Anthropic account: " + k.map(\.label).sorted().joined(separator: ", ")
    }

    /// 599i: whose accounts the agent of `image` uses — `anthropic` (Claude Code, pi), `openai` (Codex), 617: a recipe
    /// agent's default source; nil: no agent.
    public static func provider(_ image: String?) -> String? {
        guard let image else { return nil }
        return AgentImages.credentials(image)?.first?.provider
    }

    /// 599i: the store default that applies to `image` — the OpenAI default (none until one is chosen)
    /// for Codex, 617: for a recipe agent the default account of the FIRST source it is offered that has one (its own
    /// default source first) — an Anthropic or OpenAI default that is a subscription or a login is skipped (`kinds`:
    /// each account's kind, when known); the store's default account otherwise. Never one provider's account for
    /// another's agent.
    public static func defaultAccount(for image: String?, anthropic: String, openai: String?, providers: [String: String] = [:],
                                      kinds accountKinds: [String: AccountKind] = [:]) -> String {
        if let s = sources(image) {
            for src in s {
                let d: String? = src == "anthropic" ? anthropic : src == "openai" ? openai : providers[src]
                guard let d, d != "none", d != "mac" else { continue }
                if let k = accountKinds[d], source(of: k, provider: k == .key ? src : nil) != src { continue }
                return d
            }
            return "none"
        }
        return codexFlow(image) ? (openai ?? "none") : anthropic
    }

    /// 617 (models@1): a new sandbox of `image` told which model SOURCE to use (`--provider`/`--gateway`, the try setup's
    /// choice) — the account it then uses: the one given, which must hold a key of that source, else that source's
    /// default (the per-provider default; the Anthropic or OpenAI default when it is such a key), else its only key.
    /// `model`, when given, must be a model id. The account's name, or what is wrong and the flag that fixes it.
    public static func account(forSource source: String, model: String? = nil, image: String?, account: String?,
                               file: AccountsFile) -> (name: String?, problem: (text: String, fix: String)?) {
        let agent = image.flatMap(AgentImages.agentName) ?? image ?? "this agent"
        guard let offered = sources(image), ImageChoice.parse(image ?? "")?.agent.recipe?.models != nil else {
            return (nil, ("\(agent) has no choice of model provider (only an agent whose recipe says which APIs it speaks)", "leave out --provider/--gateway/--model"))
        }
        guard offered.contains(source) else {
            let known = ModelSources.ids.contains(source)
            return (nil, ((known ? "\(agent) cannot use \(ModelSources.title(source))" : "\(source) is not a provider or gateway")
                          + " — it can use " + offered.joined(separator: ", "), "--provider \(offered[0])"))
        }
        if let model, !ModelSelection.isModelID(model) {
            return (nil, ("that is not a model id (letters, digits and . _ : / @ + -, at most 128)", "--model creator/name"))
        }
        let add = "doz account add NAME --provider \(source)"
        if let a = account, a != "default" {
            guard a != "none" else { return (nil, nil) }
            guard let rec = file.accounts.first(where: { $0.name == a }) else { return (nil, ("no account \(a)", add)) }
            guard Self.source(of: rec) == source else {
                return (nil, ("the account \(a) does not hold \(keyPhrase(source))", "an account of \(ModelSources.title(source)), or \(add)"))
            }
            return (a, nil)
        }
        let d: String? = source == "anthropic" ? file.defaultAccount : source == "openai" ? file.openaiDefault : file.providerDefaults?[source]
        if let d, let rec = file.accounts.first(where: { $0.name == d }), Self.source(of: rec) == source { return (d, nil) }
        // No default of that source: its only key, when there is exactly one.
        let keys = file.accounts.filter { Self.source(of: $0) == source }
        if keys.count == 1 { return (keys[0].name, nil) }
        return (nil, (keys.isEmpty ? "there is no \(ModelSources.title(source)) key yet" : "several \(ModelSources.title(source)) keys and none is the default",
                      keys.isEmpty ? add : "--account " + keys.map(\.name).joined(separator: " | --account ")))
    }

    /// The command that adds an account `image`'s agent can use.
    static func addCommand(_ image: String) -> String {
        if let p = keyProvider(image) { return "doz account add NAME --provider \(p.id)" }
        return codexFlow(image) ? "doz account add NAME --chatgpt (or --openai-key)" : "doz account add NAME --api-key"
    }

    /// What is wrong with `account` (a name, `none`, or nil = the store default) for a new sandbox of
    /// `image` — nil when it fits. `explicitNone`: `--account none` said on purpose is allowed (the
    /// sandbox then says it has no credential); the default resolving to none is not.
    /// 599i: `openaiDefault` — the store's OpenAI default (Codex follows it, never the Anthropic one).
    /// rc.3: `codexMac` — this Mac's Codex is signed in, so `mac` is a Codex account.
    /// 617: `providers` — each `key` account's provider; `providerDefaults` — each provider's default.
    public static func createProblem(image: String?, account: String?, defaultAccount: String, kinds accountKinds: [String: AccountKind],
                                     openaiDefault: String? = nil, codexMac: Bool = false,
                                     providers: [String: String] = [:], providerDefaults: [String: String] = [:]) -> String? {
        guard let image, let _ = kinds(image) else { return nil }
        let requested = account ?? "default"
        if requested == "none" { return nil }
        let name = requested == "default"
            ? Self.defaultAccount(for: image, anthropic: defaultAccount, openai: openaiDefault, providers: providerDefaults, kinds: accountKinds) : requested
        let openai = codexFlow(image)
        let key = keyProvider(image)
        if openai, name == "mac" {
            return codexMac ? nil : "Codex can't use mac: this Mac's Codex is not signed in (run codex login on the Mac) — or add an account: \(addCommand(image))"
        }
        let compatible = (accountKinds.filter { accepts(image, $0.value, provider: providers[$0.key]) && !((openai || key != nil) && $0.key == "mac") }.keys.sorted())
            + (openai && codexMac ? ["mac"] : [])
        let fix = compatible.isEmpty
            ? "add one: \(addCommand(image)) (then create with --account NAME)"
            : "use one: --account \(compatible.joined(separator: " | --account ")) — or add one: \(addCommand(image))"
        if name == "none" {
            guard needsAccount(image) else { return nil }
            let which = (sources(image)?.count ?? 0) > 1 ? "the store has no default key for any of them"
                : key.map { "the store has no default \($0.title) account" }
                ?? (openai ? "the store's default OpenAI account is none" : "the store's default account is none")
            return "\(requirement(image)) — \(which). \(fix.prefix(1).uppercased() + fix.dropFirst())"
        }
        let kind = accountKinds[name] ?? (name == "mac" ? .mac : nil)
        guard let kind else { return nil }                          // an unknown account: the create says so itself
        guard !accepts(image, kind, provider: providers[name]) else { return nil }
        let label = kind == .key ? (providers[name].flatMap(KeyProviders.provider).map { "a \($0.title) key" } ?? "a key") : kind.label
        return "\(AgentImages.agentName(image) ?? image) can't use the account \(name) (\(label)) — \(requirement(image)). "
            + fix.prefix(1).uppercased() + fix.dropFirst()
    }

    /// An existing sandbox whose account does not fit its agent (or which has none, when the agent
    /// needs one): the banner's text. nil: it fits.
    public static func sandboxProblem(image: String?, account: AccountRecord?, missing: String?) -> String? {
        guard let image, let k = kinds(image) else { return nil }
        let agent = AgentImages.agentName(image) ?? image
        let choose: String
        if let s = sources(image), s.count > 1 {
            choose = "choose a key account of " + s.map(ModelSources.title).joined(separator: ", ") + " (doz account add NAME --provider \(s[0]))"
        } else {
            choose = keyProvider(image).map { "choose a \($0.title) key account (doz account add NAME --provider \($0.id))" }
                ?? (k == [.apiKey] ? "choose an API-key account"
                    : codexFlow(image) ? "choose an OpenAI account (mac, a ChatGPT sign-in or an OpenAI API key)" : "choose an account \(agent) can use")
        }
        if let missing { return "\(agent) has no credential: the account \(missing) no longer exists — \(choose)" }
        guard let a = account else {
            return needsAccount(image) ? "\(agent) has no credential — \(requirement(image)); \(choose)" : nil
        }
        guard !accepts(image, a) else { return nil }
        return "\(agent) can't use the account \(a.name) — \(choose)"
    }
}

extension AccountKind {
    /// As a person reads it.
    public var label: String {
        switch self {
        case .mac: "this Mac's Claude login"
        case .setupToken: "a Claude setup token"
        case .apiKey: "an Anthropic API key"
        case .openaiKey: "an OpenAI API key"
        case .chatgpt: "a ChatGPT sign-in"
        case .codexMac: "this Mac's Codex login"
        case .key: "an API key"
        }
    }
}
