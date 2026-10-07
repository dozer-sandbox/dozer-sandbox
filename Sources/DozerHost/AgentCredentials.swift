import Foundation
import DozerKit

// 594 (owner, 2026-09-30: "creating a Pi sandbox should have pre-requisites for things like API key so
// that this is not the first experience"): each agent says which credentials it can use
// (`AgentImages.credentials`), and a sandbox is checked against it BEFORE it is created — the CLI, New
// sandbox, the wizard, Duplicate — and an existing one whose account does not fit says so (and the
// account is not handed to an agent that cannot use it: a Claude subscription never reaches pi).

public enum AgentCredentials {
    /// The account kinds the agent of `image` (an image spec's name: claude-code, pi) can use; nil: no
    /// agent there (the lab), so any account fits.
    public static func kinds(_ image: String?) -> Set<AccountKind>? {
        guard let image, let c = AgentImages.credentials(image) else { return nil }
        return Set(c.flatMap(\.accountKinds).compactMap(AccountKind.init(rawValue:)))
    }

    public static func accepts(_ image: String?, _ kind: AccountKind) -> Bool {
        kinds(image)?.contains(kind) ?? true
    }

    /// An agent that has no way to work without one of its accounts (pi); Claude Code may be created
    /// with none, as before.
    public static func needsAccount(_ image: String?) -> Bool {
        guard let k = kinds(image) else { return false }
        return !k.contains(.mac)
    }

    /// "pi needs an Anthropic API key".
    public static func requirement(_ image: String) -> String {
        let name = AgentImages.agentName(image) ?? image
        guard let k = kinds(image) else { return "" }
        if k == [.apiKey] { return "\(name) needs an Anthropic API key" }
        // 599i: Codex — an OpenAI account.
        if provider(image) == "openai" { return "\(name) needs an OpenAI account: this Mac's Codex login, a ChatGPT sign-in or an OpenAI API key" }
        return "\(name) needs an Anthropic account: " + k.map(\.label).sorted().joined(separator: ", ")
    }

    /// 599i: whose accounts the agent of `image` uses — `anthropic` (Claude Code, pi), `openai` (Codex);
    /// nil: no agent.
    public static func provider(_ image: String?) -> String? {
        guard let image else { return nil }
        return AgentImages.credentials(image)?.first?.provider
    }

    /// 599i: the store default that applies to `image` — the OpenAI default (none until one is chosen)
    /// for Codex, the store's default account otherwise. Never one provider's account for the other's agent.
    public static func defaultAccount(for image: String?, anthropic: String, openai: String?) -> String {
        provider(image) == "openai" ? (openai ?? "none") : anthropic
    }

    /// The command that adds an account `image`'s agent can use.
    static func addCommand(_ image: String) -> String {
        provider(image) == "openai" ? "doz account add NAME --chatgpt (or --openai-key)" : "doz account add NAME --api-key"
    }

    /// What is wrong with `account` (a name, `none`, or nil = the store default) for a new sandbox of
    /// `image` — nil when it fits. `explicitNone`: `--account none` said on purpose is allowed (the
    /// sandbox then says it has no credential); the default resolving to none is not.
    /// 599i: `openaiDefault` — the store's OpenAI default (Codex follows it, never the Anthropic one).
    /// rc.3: `codexMac` — this Mac's Codex is signed in, so `mac` is a Codex account.
    public static func createProblem(image: String?, account: String?, defaultAccount: String, kinds accountKinds: [String: AccountKind],
                                     openaiDefault: String? = nil, codexMac: Bool = false) -> String? {
        guard let image, let _ = kinds(image) else { return nil }
        let requested = account ?? "default"
        if requested == "none" { return nil }
        let name = requested == "default" ? Self.defaultAccount(for: image, anthropic: defaultAccount, openai: openaiDefault) : requested
        let openai = provider(image) == "openai"
        if openai, name == "mac" {
            return codexMac ? nil : "Codex can't use mac: this Mac's Codex is not signed in (run codex login on the Mac) — or add an account: \(addCommand(image))"
        }
        let compatible = (accountKinds.filter { accepts(image, $0.value) && !(openai && $0.key == "mac") }.keys.sorted()) + (openai && codexMac ? ["mac"] : [])
        let fix = compatible.isEmpty
            ? "add one: \(addCommand(image)) (then create with --account NAME)"
            : "use one: --account \(compatible.joined(separator: " | --account ")) — or add one: \(addCommand(image))"
        if name == "none" {
            guard needsAccount(image) else { return nil }
            let which = provider(image) == "openai" ? "the store's default OpenAI account is none" : "the store's default account is none"
            return "\(requirement(image)) — \(which). \(fix.prefix(1).uppercased() + fix.dropFirst())"
        }
        let kind = accountKinds[name] ?? (name == "mac" ? .mac : nil)
        guard let kind else { return nil }                          // an unknown account: the create says so itself
        guard !accepts(image, kind) else { return nil }
        return "\(AgentImages.agentName(image) ?? image) can't use the account \(name) (\(kind.label)) — \(requirement(image)). "
            + fix.prefix(1).uppercased() + fix.dropFirst()
    }

    /// An existing sandbox whose account does not fit its agent (or which has none, when the agent
    /// needs one): the banner's text. nil: it fits.
    public static func sandboxProblem(image: String?, account: AccountRecord?, missing: String?) -> String? {
        guard let image, let k = kinds(image) else { return nil }
        let agent = AgentImages.agentName(image) ?? image
        let choose = k == [.apiKey] ? "choose an API-key account"
            : provider(image) == "openai" ? "choose an OpenAI account (mac, a ChatGPT sign-in or an OpenAI API key)" : "choose an account \(agent) can use"
        if let missing { return "\(agent) has no credential: the account \(missing) no longer exists — \(choose)" }
        guard let a = account else {
            return needsAccount(image) ? "\(agent) has no credential — \(requirement(image)); \(choose)" : nil
        }
        guard !accepts(image, a.kind) else { return nil }
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
        }
    }
}
