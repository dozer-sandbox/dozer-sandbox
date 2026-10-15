import Foundation
import DozerKit

// 617 (D14, 616.07, the owner's "try = a hybrid" ruling) — `doz try THING`'s own decisions, pure (the CLI asks the
// questions): the "What you need" card from the recipe's `auth`, and the answer to "Keep this try?".

/// One way in the card offers.
public struct TryCardOption: Equatable, Sendable {
    /// `paste` | `source` | `sign-in`.
    public var kind: String
    public var label: String
    /// What choosing it means (where the key lives, what the sandbox gets).
    public var consequence: String
}

/// "What you need" — the same shape for every agent, from its recipe's `auth`. nil when nothing is needed (a key of
/// its provider is there: the card is skipped entirely).
public struct TryCard: Equatable, Sendable {
    public var title: String
    public var options: [TryCardOption]
    /// Methods there are but Dozer does not offer here — each with why.
    public var notOffered: [String]
    /// "Get a key: https://console.x.ai/ (…)".
    public var getKey: String?

    /// The card for `recipe`'s try; `haveKey`: an account of its provider the try would use (nil: none).
    public static func build(_ recipe: AgentRecipe, haveKey: String?) -> TryCard? {
        guard haveKey == nil else { return nil }
        var options: [TryCardOption] = []
        var notOffered: [String] = []
        var getKey: String?
        for m in recipe.auth.methods {
            switch m.kind {
            case "api-key":
                let p = m.provider.flatMap { KeyProviders.provider($0) }
                let what = p.map { "\($0.title) " + ($0.title.contains("API") ? "key" : "API key") } ?? "API key"
                options.append(TryCardOption(kind: "paste", label: "Paste \(what.hasPrefix("A") || what.hasPrefix("x") ? "an" : "a") \(what) (hidden)",
                                             consequence: "kept in this Mac's login keychain; the sandbox only ever gets a placeholder"))
                options.append(TryCardOption(kind: "source", label: "A key you keep in 1Password, AWS Secrets Manager or a program",
                                             consequence: "read on this Mac when the agent needs it (op://…, aws:arn:…, or a command) — never stored"))
                if let page = m.keysPage {
                    getKey = "Get a key: \(page)" + (m.freeTier == true ? " — \(m.freeTierNote ?? "it has a free tier")" : "")
                }
            case "vendor-sign-in":
                if m.accounts != nil { continue }               // a sign-in Dozer holds on the Mac (Claude Code's mac): the account step
                if m.inSandbox == true {
                    options.append(TryCardOption(kind: "sign-in", label: "Sign in inside \(recipe.title)" + (m.account.map { " (\($0))" } ?? ""),
                                                 consequence: "the sign-in lives in this sandbox, not on the Mac — deleting the try deletes it"))
                } else {
                    notOffered.append("Signing in inside \(recipe.title)" + (m.account.map { " (\($0))" } ?? "") + ": " + (m.note ?? "not offered"))
                }
            case "none":
                options.append(TryCardOption(kind: "none", label: "No account", consequence: m.note ?? "it works without one"))
            default:
                if let n = m.note { notOffered.append(n) }          // gateway: phase 2
            }
        }
        let provider = recipe.provider.flatMap { KeyProviders.provider($0) }?.title ?? recipe.publisher
        return TryCard(title: "What you need — \(recipe.title) talks to \(provider)", options: options, notOffered: notOffered, getKey: getKey)
    }

    /// The card as a terminal shows it (numbered options).
    public var lines: [String] {
        var out = [title]
        for (i, o) in options.enumerated() { out.append("  \(i + 1). \(o.label) — \(o.consequence)") }
        for n in notOffered { out.append("  · \(n)") }
        if let g = getKey { out.append("  \(g)") }
        return out
    }
}

/// "Keep this try? [S]leep / [d]elete / [k]eep running".
public enum TryExitChoice: String, Equatable, Sendable {
    case sleep, delete, keep

    public static let question = "Keep this try? [S]leep / [d]elete / [k]eep running"

    /// An answer (Enter = Sleep); nil: not one of them (asked again).
    public static func parse(_ answer: String) -> TryExitChoice? {
        switch answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "s", "sleep": .sleep
        case "d", "delete", "rm": .delete
        case "k", "keep", "keep running": .keep
        default: nil
        }
    }

    /// What happens on exit: `--rm` / `--keep` decide without asking; off a terminal a try is kept.
    public static func decided(rm: Bool, keep: Bool, interactive: Bool) -> TryExitChoice? {
        if rm { return .delete }
        if keep || !interactive { return .keep }
        return nil
    }
}
